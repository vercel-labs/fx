const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");
const command_output_content = @import("../../core/tooling/command_output_content.zig");
const full_transcript_screen = @import("../full_transcript_screen.zig");
const input_visual_layout = @import("../input/visual_layout.zig");
const render_engine = @import("../render_engine.zig");
const command_output_runtime = @import("command_output_runtime.zig");
const transcript_painter = @import("painter.zig");
const transcript_runtime = @import("runtime.zig");
const transcript_store = @import("store.zig");
const transcript_writer = @import("writer.zig");
const ui_render = @import("../render.zig");
const user_message_card = @import("../assistant/user_message_card.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const Layout = types.Layout;
const Metrics = types.Metrics;
const transcript_blocks = render_engine.transcript_blocks;
const viewport_selection = render_engine.viewport_selection;

const RawEntryClass = transcript_blocks.RawEntryClass;
const Styles = transcript_blocks.Styles;
const ToolDetailRecord = transcript_blocks.ToolDetailRecord;
const TranscriptPreparationSource = transcript_runtime.TranscriptPreparationSource;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const HardLineStarts = viewport_selection.HardLineStarts;
const TranscriptBuffer = viewport_selection.TranscriptBuffer;
const VisibleTranscriptLine = viewport_selection.VisibleTranscriptLine;
fn renderEntriesToBytes(alloc: Allocator, entries: []const transcript_blocks.TranscriptEntry, cols: u16) ![]u8 {
    return transcript_runtime.renderEntriesToBytes(alloc, entries, cols, .{});
}
const visualRowsForLine = transcript_blocks.visualRowsForLine;

fn resolveAndSealTranscriptTransitionForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    source: *TranscriptPreparationSource,
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
    target_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
    plan: *render_engine.paint_plan.PaintPlan,
    scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
) !transcript_runtime.TranscriptTransition {
    const scroll_facts = try runtime.prepareTranscriptScrollFactsForFrame(
        alloc,
        source,
        prepared,
        false,
        false,
    );
    const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
        runtime.committed_frame_layout.transcript_area,
        plan.invalidation,
    );
    const resolved = try runtime.resolveTranscriptTransitionTargetForFrame(
        alloc,
        source,
        prepared,
        target_layout,
        scroll_plan,
        scroll_facts,
        destructive_invalidation,
        plan.activity == .overlay_entry,
    );
    resolved.applyToPaintPlan(plan);
    return runtime.sealTranscriptTransition(
        alloc,
        source,
        prepared,
        plan,
        resolved,
    );
}

fn resolveVisibleLineForTest(line: VisibleTranscriptLine, buf: TranscriptBuffer) []const u8 {
    return switch (line) {
        .transcript => |t| t.ref.resolve(buf),
        .folded_line => |f| f.text,
    };
}

fn commandOutputTestRuntime(sink: std.Io.File) TranscriptRuntime {
    return .{
        .stdout_file = sink,
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 21,
            .divider_top_row = 22,
            .input_row = 23,
            .divider_bottom_row = 24,
            .hint_row = 22,
        },
    };
}

fn testSelection(start_line: usize) viewport_selection.ViewportSelection {
    return .{
        .top_row = 1,
        .bottom_row = 4,
        .start_line = start_line,
        .partial_skip_rows = 0,
        .line_count = 16,
    };
}

fn transcriptTestLayout(cols: u16, rows: u16, content_bottom: u16) Layout {
    return .{
        .rows = rows,
        .cols = cols,
        .content_bottom = content_bottom,
        .divider_top_row = content_bottom + 1,
        .input_row = content_bottom + 2,
        .divider_bottom_row = content_bottom + 3,
        .hint_row = rows,
    };
}

fn makeLongPastePrompt(alloc: Allocator, line_count: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("LONG_PASTE_FIRST_MARKER\n");
    var index: usize = 0;
    while (index < line_count) : (index += 1) {
        try out.writer.print("long-paste-line-{d}\n", .{index});
    }
    try out.writer.writeAll("LONG_PASTE_LAST_MARKER\n");
    return out.toOwnedSlice();
}

fn installStableAnchorWithOriginForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    flow: []const u8,
    selection: viewport_selection.ViewportSelection,
    visual_offset: u32,
    cursor_row: u16,
    cursor_col: u16,
    layout_id: u64,
    measured_history_origin: ?transcript_painter.MeasuredHistoryOrigin,
) !void {
    var target_cache: std.ArrayList(u8) = .empty;
    errdefer target_cache.deinit(alloc);
    try target_cache.appendSlice(alloc, flow);
    var transition = transcript_runtime.TranscriptTransition{
        .scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(
            runtime.layout.rows,
            runtime.owned_top_row,
        ),
        .document_append = .{},
        .materialized_without_append = .{},
        .target_flow = try alloc.dupe(u8, flow),
        .target_cache = target_cache,
        .target_cache_origin_untrimmed = runtime.transcript_cache_origin_untrimmed,
        .folded_summary_indices = &.{},
        .target_layout = .{
            .layout_id = layout_id,
            .owned_top = runtime.owned_top_row,
            .owned_band = .{ .top = runtime.owned_top_row, .bottom = runtime.layout.rows },
            .body_area = .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
            .transcript_area = .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
            .footer_area = .{ .top = runtime.layout.content_bottom + 1, .bottom = runtime.layout.rows },
            .solved_frame_height = runtime.layout.rows - runtime.owned_top_row + 1,
            .terminal_rows = runtime.layout.rows,
            .terminal_cols = runtime.layout.cols,
        },
        .selection = selection,
        .visual_offset = visual_offset,
        .history_visual_offset = visual_offset,
        .total_visual_rows = visual_offset + 64,
        .cursor_row = cursor_row,
        .cursor_col = cursor_col,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = cursor_row,
        .trace_transcript_frame = false,
        .trace_visible_rows = selection.bottom_row - selection.top_row + 1,
        .measured_history_origin = measured_history_origin,
    };
    defer transition.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 0,
        .changed_cells = 0,
        .full_repaint = false,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = cursor_row,
        .committed_cursor_col = cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
}

fn installStableAnchorForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    flow: []const u8,
    selection: viewport_selection.ViewportSelection,
    visual_offset: u32,
    cursor_row: u16,
    cursor_col: u16,
    layout_id: u64,
) !void {
    return installStableAnchorWithOriginForTest(
        runtime,
        alloc,
        flow,
        selection,
        visual_offset,
        cursor_row,
        cursor_col,
        layout_id,
        null,
    );
}

fn stableHistoryVisualOffsetForTest(runtime: *const TranscriptRuntime) !u32 {
    return switch (runtime.transcript_commit_state) {
        .stable => |anchor| anchor.history_visual_offset,
        .invalid, .recovering => error.TestExpectedStableTranscript,
    };
}

fn expectStableNormalBufferRecoveryForTest(
    runtime: *const TranscriptRuntime,
    expected_history_visual_offset: u32,
) !void {
    switch (runtime.transcript_commit_state) {
        .stable => |anchor| {
            try std.testing.expect(anchor.normal_buffer_recovery_pending);
            try std.testing.expectEqual(
                expected_history_visual_offset,
                anchor.history_visual_offset,
            );
        },
        .invalid, .recovering => return error.TestExpectedStableTranscript,
    }
}

fn testPaintPlan(
    runtime: *const TranscriptRuntime,
    selection: viewport_selection.ViewportSelection,
) render_engine.paint_plan.PaintPlan {
    const footer_top = runtime.layout.content_bottom + 1;
    return .{
        .layout = runtime.layout,
        .viewport = selection,
        .footer = .{
            .top = footer_top,
            .top_divider = footer_top,
            .banner = footer_top,
            .banner_active = false,
            .input_base = @min(footer_top + 1, runtime.layout.rows),
            .picker_divider = @min(footer_top + 2, runtime.layout.rows),
            .picker_start = runtime.layout.rows,
            .bottom_divider = @min(footer_top + 2, runtime.layout.rows),
            .hint = runtime.layout.rows,
            .total_rows = runtime.layout.rows - footer_top + 1,
        },
        .activity = .none,
        .preserved_band = if (runtime.owned_top_row > 1)
            .{ .top = 1, .bottom = runtime.owned_top_row - 1, .owner = .preserved_shell }
        else
            render_engine.paint_plan.FrameBand.empty(.preserved_shell),
        .transcript_band = .{
            .top = runtime.owned_top_row,
            .bottom = runtime.layout.content_bottom,
            .owner = .transcript,
        },
        .activity_band = render_engine.paint_plan.FrameBand.empty(.activity),
        .footer_band = .{
            .top = footer_top,
            .bottom = runtime.layout.rows,
            .owner = .footer,
        },
        .invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = selection.bottom_row, .col = 1, .visible = true },
        .footer_reservation_source = .none,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

const TestTranscriptFixedPointFrame = struct {
    layout: render_engine.frame_layout.FrameLayout,
    scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
};

fn solveTestTranscriptFixedPointFrame(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    metrics: *Metrics,
    source: *const TranscriptPreparationSource,
    footer_rows: u16,
    prepared: *?transcript_painter.PreparedTranscriptSurfacePaint,
) !TestTranscriptFixedPointFrame {
    var release_floor_rows: u16 = 0;
    var previous_candidate_owned_top: ?u16 = null;

    while (true) {
        const release = render_engine.frame_layout.solveWithPreservedRowRelease(.{
            .terminal = runtime.layout,
            .owned_top = runtime.owned_top_row,
            .footer = .{
                .natural_rows = footer_rows,
                .min_rows = footer_rows,
                .max_rows = footer_rows,
            },
            .transcript = source.preview,
            .prior = runtime.committed_frame_layout,
        }, release_floor_rows);
        const candidate = release.layout;
        if (previous_candidate_owned_top) |previous| {
            if (candidate.owned_top >= previous) return error.InvalidFrameScrollPlan;
        }

        if (prepared.*) |*paint| {
            paint.deinit(alloc);
            prepared.* = null;
        }
        var inline_advance_rows: u16 = 0;
        if (!candidate.transcript_area.isEmpty()) {
            prepared.* = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
                alloc,
                metrics,
                source,
                candidate.transcript_area,
            );
            inline_advance_rows = runtime.planTranscriptScroll(&prepared.*.?).planned_rows;
        }
        const scroll_plan = render_engine.frame_scroll_plan.merge(
            runtime.layout.rows,
            runtime.owned_top_row,
            release.released_rows,
            inline_advance_rows,
        );
        if (candidate.owned_top == scroll_plan.post_scroll_owned_top) {
            return .{
                .layout = candidate,
                .scroll_plan = scroll_plan,
            };
        }
        previous_candidate_owned_top = candidate.owned_top;
        release_floor_rows = scroll_plan.preserved_release_rows;
    }
}

fn testPaintPlanForFrame(
    layout: render_engine.frame_layout.FrameLayout,
    selection: viewport_selection.ViewportSelection,
    cursor_row: u16,
    cursor_col: u16,
) render_engine.paint_plan.PaintPlan {
    const footer_rows = render_engine.footer_layout.resolve(.{
        .footer_top_for_extra = layout.footer_area.top,
        .terminal_rows = layout.terminal.rows,
        .activity_offset = 0,
        .extra_input_rows = 0,
        .input_extra = 0,
        .picker_rows = 0,
        .banner_active = false,
        .allocated_rows = layout.footer_area.height(),
    });
    return layout.toPaintPlan(.{
        .footer_rows = footer_rows,
        .viewport = selection,
        .cursor_target = .{
            .row = cursor_row,
            .col = cursor_col,
            .visible = true,
        },
    });
}

fn testSource(
    alloc: Allocator,
    bytes: []const u8,
    cols: u16,
) !TranscriptPreparationSource {
    return .{
        .bytes = try alloc.dupe(u8, bytes),
        .folded_summary_indices = &.{},
        .preview = .{ .natural_visual_rows = 4 },
        .tail_kind = null,
        .tracked_entry_id = null,
        .tracked_entry_start_line = null,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 1,
        .welcome_cut_line = null,
        .welcome_boundary = null,
        .cols = cols,
    };
}

fn testFoldedSource(
    alloc: Allocator,
    bytes: []const u8,
    cols: u16,
    summary_transcript_index: usize,
) !TranscriptPreparationSource {
    var source = try testSource(alloc, bytes, cols);
    errdefer source.deinit(alloc);
    source.folded_summary_indices = try alloc.dupe(
        usize,
        &.{summary_transcript_index},
    );
    return source;
}

fn testSourceWithReplaceableTail(
    alloc: Allocator,
    bytes: []const u8,
    cols: u16,
    replaceable_start: usize,
) !TranscriptPreparationSource {
    var source = try testSource(alloc, bytes, cols);
    source.replaceable_last_line = true;
    source.replaceable_start = replaceable_start;
    return source;
}

fn appendFoldedLineForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    block_index: usize,
    text: []const u8,
) !void {
    const owned = try alloc.dupe(u8, text);
    errdefer alloc.free(owned);
    try runtime.folded_command_blocks.items[block_index].lines.append(alloc, .{
        .stream = .stdout,
        .text = owned,
    });
}

fn prepareTestSourceForCurrentArea(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    source: *const TranscriptPreparationSource,
) !transcript_painter.PreparedTranscriptSurfacePaint {
    var metrics: Metrics = .{};
    return runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        source,
        .{
            .top = runtime.owned_top_row,
            .bottom = runtime.layout.content_bottom,
        },
    );
}

fn preparedVisualOffsetForTest(
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
) u32 {
    var offset: u32 = 0;
    const end = @min(
        prepared.selection.start_line,
        prepared.sourceVisualRows().len,
    );
    for (prepared.sourceVisualRows()[0..end]) |rows| offset += rows;
    return offset + prepared.selection.partial_skip_rows;
}

test "unchanged transcript keeps stable projection during footer reflow" {
    const alloc = std.testing.allocator;
    const flow =
        "line 00\n" ++
        "line 01\n" ++
        "line 02\n" ++
        "line 03\n" ++
        "line 04\n" ++
        "line 05\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(60, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    var metrics = Metrics{};

    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var compact = try runtime.prepareTranscriptSurfacePaintFromSourceForFrame(
        alloc,
        &metrics,
        &source,
        .{ .top = 1, .bottom = 4 },
        false,
    );
    defer compact.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), compact.selection.start_line);
    try installStableAnchorWithOriginForTest(
        &runtime,
        alloc,
        flow,
        compact.selection,
        preparedVisualOffsetForTest(&compact),
        compact.cursor.cursor_row,
        compact.cursor.cursor_col,
        800,
        .{
            .source_cols = runtime.layout.cols,
            .source_visual_offset = preparedVisualOffsetForTest(&compact),
        },
    );

    var expanded = try runtime.prepareTranscriptSurfacePaintFromSourceForFrame(
        alloc,
        &metrics,
        &source,
        .{ .top = 1, .bottom = 6 },
        true,
    );
    defer expanded.deinit(alloc);

    try std.testing.expectEqual(compact.selection.start_line, expanded.selection.start_line);
    try std.testing.expectEqual(compact.selection.last_visible_row, expanded.selection.last_visible_row);
}

test "structured user turn source keeps full prompt beyond byte cache cap" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 18, 14),
        .owned_top_row = 1,
        .max_transcript_bytes = 256,
    };
    defer runtime.deinit(alloc);

    const prompt = try makeLongPastePrompt(alloc, 512);
    try std.testing.expect(prompt.len > runtime.max_transcript_bytes);
    _ = try runtime.appendUserTurnOwned(alloc, .{
        .text = prompt,
        .images = &.{},
    });
    const assistant_id = try runtime.appendAssistantTurnEntry(alloc);
    const assistant = runtime.lookupAssistantSegments(assistant_id) orelse unreachable;
    try assistant.text.appendSlice(alloc, "assistant after long prompt\n");

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);

    try std.testing.expect(source.bytes.len > runtime.max_transcript_bytes);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "LONG_PASTE_FIRST_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "LONG_PASTE_LAST_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "assistant after long prompt") != null);
}

test "large current user turn survives assistant retention pass" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 18, 14),
        .owned_top_row = 1,
        .max_transcript_bytes = 256,
        .max_retained_transcript_bytes = 128,
    };
    defer runtime.deinit(alloc);

    const prompt = try makeLongPastePrompt(alloc, 64);
    const user_id = try runtime.appendUserTurnOwned(alloc, .{
        .text = prompt,
        .images = &.{},
    });
    const assistant_id = try runtime.appendAssistantTurnEntry(alloc);
    const assistant = runtime.lookupAssistantSegments(assistant_id) orelse unreachable;
    try assistant.text.appendSlice(alloc, "assistant begins\n");

    try std.testing.expectEqual(@as(usize, 2), runtime.entries.items.len);
    try std.testing.expectEqual(user_id, runtime.entries.items[0].id());
    try std.testing.expectEqual(assistant_id, runtime.entries.items[1].id());

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "LONG_PASTE_FIRST_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "assistant begins") != null);
}

test "finalize transcript transition rejects frame inline row mismatch" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var source = try testSource(alloc, "line\n", runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &source,
    );
    defer prepared.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 0), runtime.planTranscriptScroll(&prepared).planned_rows);

    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        1,
    );
    var plan = testPaintPlan(&runtime, prepared.selection);
    try std.testing.expectError(
        error.InvalidFrameScrollPlan,
        resolveAndSealTranscriptTransitionForTest(
            &runtime,
            alloc,
            &source,
            &prepared,
            render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
            &plan,
            scroll_plan,
        ),
    );
}

test "child full transcript finalizer consumes one complete transition" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try std.testing.expect(
        try runtime.setTranscriptPresentationDepth(alloc, .full),
    );

    var source = try testSource(alloc, "child full transcript\n", runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &source,
    );
    defer prepared.deinit(alloc);
    const facts = runtime.planTranscriptScrollForFrame(&prepared, false, false);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(&runtime, prepared.selection);
    var transition = try runtime.finalizeTranscriptTransitionForFrame(
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
        false,
        false,
    );
    defer transition.deinit(alloc);

    runtime.consumeFrameScrollCommit(alloc, scroll_plan, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = scroll_plan.terminal_scroll_rows,
        .document_append_committed = !transition.document_append.isEmpty(),
        .committed_cursor_row = transition.cursor_row,
        .committed_cursor_col = transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    }, &transition);

    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    try std.testing.expectEqual(
        transition.target_layout.layout_id,
        runtime.committed_frame_layout.layout_id,
    );
}

fn commitPreparedForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    source: *TranscriptPreparationSource,
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
) !void {
    const facts = runtime.planTranscriptScroll(prepared);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        source,
        prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = scroll_plan.terminal_scroll_rows,
        .document_append_committed = !transition.document_append.isEmpty(),
        .committed_cursor_row = transition.cursor_row,
        .committed_cursor_col = transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
}

fn commitPreparedPartiallyForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    source: *TranscriptPreparationSource,
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
) !void {
    const facts = runtime.planTranscriptScroll(prepared);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        source,
        prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = transition.materialized.cursor_row,
        .committed_cursor_col = transition.materialized.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
}

fn setPreparedVisualOffsetForTest(
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
    target: u32,
) !void {
    var remaining = target;
    var line_index: usize = 0;
    while (line_index < prepared.sourceVisualRows().len and
        remaining >= prepared.sourceVisualRows()[line_index]) : (line_index += 1)
    {
        remaining -= prepared.sourceVisualRows()[line_index];
    }
    if (line_index >= prepared.sourceVisualRows().len) {
        return error.TestExpectedRepresentableVisualOffset;
    }
    prepared.selection.start_line = line_index;
    prepared.selection.partial_skip_rows = @intCast(remaining);
    prepared.selection.line_count = prepared.sourceVisualRows().len;
}

const MeasuredEndpointMode = enum {
    seeded_exact,
    natural_null,
    seeded_inexact,
};

fn expectZeroReverseRestoresSourceOrigin(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    wide_source: *TranscriptPreparationSource,
    narrow_source: *TranscriptPreparationSource,
    positive_delta: i32,
    endpoint_mode: MeasuredEndpointMode,
) !void {
    var wide_prepared = try prepareTestSourceForCurrentArea(
        runtime,
        alloc,
        wide_source,
    );
    defer wide_prepared.deinit(alloc);
    const source_origin = preparedVisualOffsetForTest(&wide_prepared);
    try std.testing.expect(source_origin > 0);
    try installStableAnchorForTest(
        runtime,
        alloc,
        wide_source.bytes,
        wide_prepared.selection,
        source_origin,
        wide_prepared.cursor.cursor_row,
        wide_prepared.cursor.cursor_col,
        700,
    );

    runtime.layout = transcriptTestLayout(narrow_source.cols, 8, 4);
    runtime.resize_history_row_delta = positive_delta;
    var narrow_prepared = try prepareTestSourceForCurrentArea(
        runtime,
        alloc,
        narrow_source,
    );
    defer narrow_prepared.deinit(alloc);
    const natural_endpoint = if (narrow_prepared.measured_history_origin) |origin|
        origin.endpoint
    else
        null;
    if (endpoint_mode == .seeded_inexact) {
        try std.testing.expect(natural_endpoint == null);
    }
    if (endpoint_mode != .natural_null) {
        narrow_prepared.measured_history_origin = .{
            .source_cols = wide_source.cols,
            .source_visual_offset = source_origin,
            .endpoint = .{
                .span_start_flow_offset = 0,
                .flow_offset = 0,
                .hard_row_cols = wide_source.cols,
            },
        };
    }
    try std.testing.expectEqual(
        endpoint_mode != .natural_null,
        if (narrow_prepared.measured_history_origin) |origin|
            origin.endpoint != null
        else
            false,
    );
    const narrow_origin = preparedVisualOffsetForTest(&narrow_prepared);
    try std.testing.expect(narrow_origin > source_origin);
    try commitPreparedForTest(runtime, alloc, narrow_source, &narrow_prepared);
    const narrowed = runtime.stableTranscriptProjectionForFlow(
        wide_source.bytes,
    ) orelse return error.TestExpectedStableTranscript;
    const retained_origin = narrowed.measured_history_origin orelse
        return error.TestExpectedMeasuredHistoryOrigin;
    try std.testing.expectEqual(source_origin, retained_origin.source_visual_offset);
    try std.testing.expectEqual(wide_source.cols, retained_origin.source_cols);
    try std.testing.expectEqual(
        endpoint_mode != .natural_null,
        retained_origin.endpoint != null,
    );

    runtime.layout = transcriptTestLayout(wide_source.cols, 12, 8);
    runtime.resize_history_row_delta = 0;
    var restored = try prepareTestSourceForCurrentArea(
        runtime,
        alloc,
        wide_source,
    );
    defer restored.deinit(alloc);
    try std.testing.expectEqual(
        source_origin,
        preparedVisualOffsetForTest(&restored),
    );
}

fn totalVisualRowsForTest(line_rows: []const u16) u32 {
    var total: u32 = 0;
    for (line_rows) |rows| total += rows;
    return total;
}

test "semantic row identity remains exact beyond 65535 rows" {
    const alloc = std.testing.allocator;
    const row_count: usize = 65_540;
    var flow_writer: std.Io.Writer.Allocating = .init(alloc);
    defer flow_writer.deinit();
    for (0..row_count) |index| {
        if (index > 0) try flow_writer.writer.writeByte('\n');
        try flow_writer.writer.print("semantic-row-{d}", .{index});
    }
    const flow = flow_writer.written();

    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &source,
    );
    defer prepared.deinit(alloc);

    try std.testing.expectEqual(row_count, prepared.sourceVisualRows().len);
    try std.testing.expectEqual(
        @as(u32, @intCast(row_count)),
        totalVisualRowsForTest(prepared.sourceVisualRows()),
    );
    try std.testing.expectEqual(row_count - 8, prepared.selection.start_line);
    try std.testing.expectEqual(@as(u16, 0), prepared.selection.partial_skip_rows);

    const boundary_indices = [_]usize{ 65_534, 65_535, 65_536, row_count - 1 };
    for (boundary_indices) |index| {
        var marker_buf: [32]u8 = undefined;
        const marker = try std.fmt.bufPrint(
            &marker_buf,
            "semantic-row-{d}",
            .{index},
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, flow, marker),
        );
        try std.testing.expectEqualStrings(
            marker,
            resolveVisibleLineForTest(
                prepared.visible_lines.items[index],
                .{ .bytes = prepared.bytes },
            ),
        );
    }

    try commitPreparedForTest(&runtime, alloc, &source, &prepared);
    const stable = runtime.stableTranscriptProjectionForFlow(flow) orelse
        return error.TestExpectedStableTranscript;
    try std.testing.expectEqual(row_count - 8, stable.selection.start_line);
    try std.testing.expectEqual(
        @as(u32, @intCast(row_count - 8)),
        stable.visual_offset,
    );
    try std.testing.expectEqual(
        @as(u32, @intCast(row_count)),
        stable.total_visual_rows,
    );
}

fn makeSyntheticPreparedRenderable(
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
    alloc: Allocator,
) !void {
    const line_count = prepared.line_visual_rows.items.len;
    try prepared.visible_lines.ensureTotalCapacity(alloc, line_count);
    while (prepared.visible_lines.items.len < line_count) {
        prepared.visible_lines.appendAssumeCapacity(.{
            .transcript = .{
                .ref = .{
                    .ref = .{ .start = 0, .len = 0 },
                },
            },
        });
    }
    prepared.selection.line_count = line_count;
    prepared.total_lines = line_count;
}

fn enterRendererDerivedSemanticRecovery(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    flow: []const u8,
    attempt_content_bottom: u16,
    accepted_semantic_rows: u16,
    replaceable_start: ?usize,
) !u32 {
    var stable_source = if (replaceable_start) |start|
        try testSourceWithReplaceableTail(alloc, flow, runtime.layout.cols, start)
    else
        try testSource(alloc, flow, runtime.layout.cols);
    defer stable_source.deinit(alloc);
    var stable_prepared = try prepareTestSourceForCurrentArea(
        runtime,
        alloc,
        &stable_source,
    );
    defer stable_prepared.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), stable_prepared.selection.start_line);
    try std.testing.expectEqual(@as(u16, 0), stable_prepared.selection.partial_skip_rows);
    try installStableAnchorForTest(
        runtime,
        alloc,
        flow,
        stable_prepared.selection,
        0,
        stable_prepared.cursor.cursor_row,
        stable_prepared.cursor.cursor_col,
        91,
    );

    runtime.layout = transcriptTestLayout(
        runtime.layout.cols,
        runtime.layout.rows,
        attempt_content_bottom,
    );
    var attempt_source = if (replaceable_start) |start|
        try testSourceWithReplaceableTail(alloc, flow, runtime.layout.cols, start)
    else
        try testSource(alloc, flow, runtime.layout.cols);
    defer attempt_source.deinit(alloc);
    var attempt_prepared = try prepareTestSourceForCurrentArea(
        runtime,
        alloc,
        &attempt_source,
    );
    defer attempt_prepared.deinit(alloc);

    const attempt_facts = runtime.planTranscriptScroll(&attempt_prepared);
    try std.testing.expect(attempt_facts.semantic_rows > accepted_semantic_rows);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        attempt_facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, attempt_prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &attempt_source,
        &attempt_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = if (accepted_semantic_rows > 0) 1 else 0,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = accepted_semantic_rows,
        .document_append_committed = false,
        .committed_cursor_row = attempt_prepared.cursor.cursor_row,
        .committed_cursor_col = attempt_prepared.cursor.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        runtime.transcriptCommitDiagnostic().state,
    );
    return attempt_facts.target_visual_offset;
}

fn expectFinalizedRecoveryProjectionPaintsCoherently(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    plan: render_engine.paint_plan.PaintPlan,
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
    transition: *const transcript_runtime.TranscriptTransition,
    expected_first_row_text: ?[]const u8,
) !void {
    var shadow = try vt_emulator.Grid.init(alloc, plan.layout.cols, plan.layout.rows);
    defer shadow.deinit();
    var surface = try render_engine.frame_surface.FrameSurface.initFromShadow(
        alloc,
        plan,
        shadow,
    );
    defer surface.deinit();

    const result = try runtime.paintPreparedTranscriptIntoSurface(
        alloc,
        &surface,
        prepared,
    );
    try std.testing.expectEqualDeep(transition.selection, surface.plan.viewport);
    try std.testing.expectEqual(
        transition.selection.last_visible_row,
        result.last_row,
    );
    try std.testing.expectEqual(
        transition.selection.replaceable_start_row,
        result.replaceable_start_row,
    );
    try std.testing.expectEqual(
        transition.cursor_row,
        surface.cursor_target.?.row,
    );
    try std.testing.expectEqual(
        transition.cursor_col,
        surface.cursor_target.?.col,
    );
    try std.testing.expectEqual(
        transition.replaceable_row,
        prepared.cursor.replaceable_row,
    );

    if (expected_first_row_text) |expected| {
        var target = try surface.copyToTargetGrid(alloc);
        defer target.deinit();
        var row_text: std.ArrayList(u8) = .empty;
        defer row_text.deinit(alloc);
        try target.rowText(plan.viewport.top_row, &row_text);
        try std.testing.expect(std.mem.startsWith(u8, row_text.items, expected));
    }
    if (transition.selection.last_visible_row_blank) {
        var col: u16 = 1;
        while (col <= surface.cols) : (col += 1) {
            const cell = surface.cellAt(
                transition.selection.last_visible_row,
                col,
            ).?;
            try std.testing.expectEqual(@as(u21, ' '), cell.codepoint);
        }
    }
}

const OwnedBandInvalidationProbe = struct {
    saw_owned_band_change: bool = false,

    fn paint(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
        const self: *OwnedBandInvalidationProbe = @ptrCast(@alignCast(ctx));
        for (surface.plan.invalidation.ranges()) |range| {
            if (range.reason == .owned_band_change) {
                self.saw_owned_band_change = true;
            }
        }
    }
};

const PreparedTranscriptFramePainter = struct {
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,

    fn paint(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
        const self: *PreparedTranscriptFramePainter = @ptrCast(@alignCast(ctx));
        _ = try self.runtime.paintPreparedTranscriptIntoSurface(
            self.alloc,
            surface,
            self.prepared,
        );
    }
};

fn appendGridRows(
    alloc: Allocator,
    grid: *const vt_emulator.Grid,
    first_row: u16,
    row_count: u16,
    history: *std.ArrayList(u8),
    row_text: *std.ArrayList(u8),
) !void {
    var row_offset: u16 = 0;
    while (row_offset < row_count) : (row_offset += 1) {
        row_text.clearRetainingCapacity();
        try grid.rowTextTrimmed(first_row + row_offset, row_text);
        try std.testing.expect(row_text.items.len > 0);
        if (history.items.len > 0) try history.append(alloc, '\n');
        try history.appendSlice(alloc, row_text.items);
    }
}

fn countExactHistoryLine(history: []const u8, expected: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, history, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, expected)) count += 1;
    }
    return count;
}

fn cloneRecoveryTransitionForTest(
    alloc: Allocator,
    source: *const transcript_runtime.TranscriptTransition,
) !transcript_runtime.TranscriptTransition {
    std.debug.assert(!source.consumed);
    std.debug.assert(source.document_append.isEmpty());
    std.debug.assert(source.document_append_bytes.len == 0);

    var clone = source.*;
    clone.document_append.bytes = &.{};
    clone.document_append_bytes = &.{};
    clone.target_flow = &.{};
    clone.target_cache = .empty;
    clone.folded_summary_indices = &.{};
    errdefer clone.deinit(alloc);

    clone.target_flow = try alloc.dupe(u8, source.target_flow);
    try clone.target_cache.appendSlice(alloc, source.target_cache.items);
    clone.folded_summary_indices = try alloc.dupe(
        usize,
        source.folded_summary_indices,
    );
    return clone;
}

fn createProductionCappedFoldedRecoveryTransition(
    alloc: Allocator,
    cols: u16,
    viewport_rows: u16,
) !transcript_runtime.TranscriptTransition {
    const stable_flow = "summary";
    const initial_owned_top = viewport_rows + 1;
    const content_bottom = initial_owned_top + viewport_rows - 1;
    const raw_line_count: usize = 3;
    const wrapped_rows_per_line: usize =
        (@as(usize, std.math.maxInt(u16)) + 1) / raw_line_count + 1;
    const raw_line_bytes = wrapped_rows_per_line * @as(usize, cols);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(
        std.testing.io,
        "production-folded-capped-attempt.log",
        .{ .read = true },
    );
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = transcriptTestLayout(
            cols,
            content_bottom + 4,
            content_bottom,
        ),
        .owned_top_row = initial_owned_top,
        .max_transcript_bytes = 2 * 1024 * 1024,
        .max_retained_transcript_bytes = 2 * 1024 * 1024,
        .full_transcript = .{ .depth = .full },
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try runtime.shadow_vt.?.feed("shell0\r\nshell1\r\nshell2\r\nshell3");

    try runtime.transcript.appendSlice(alloc, stable_flow);
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_transcript_index = 1,
    });
    var fold_index: usize = 0;
    while (fold_index < viewport_rows) : (fold_index += 1) {
        var fold_buf: [16]u8 = undefined;
        const fold = try std.fmt.bufPrint(&fold_buf, "fold{d}", .{fold_index});
        try appendFoldedLineForTest(&runtime, alloc, 0, fold);
    }

    var metrics: Metrics = .{};
    var stable_source = try runtime.prepareTranscriptSource(alloc, null);
    defer stable_source.deinit(alloc);
    try std.testing.expectEqualStrings(stable_flow, stable_source.bytes);
    try std.testing.expectEqual(@as(usize, 1), stable_source.folded_summary_indices.len);
    try std.testing.expectEqual(@as(usize, 1), stable_source.folded_summary_indices[0]);
    try std.testing.expectEqual(viewport_rows, stable_source.preview.natural_visual_rows);

    var stable_prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
    defer if (stable_prepared) |*paint| paint.deinit(alloc);
    const stable_frame = try solveTestTranscriptFixedPointFrame(
        &runtime,
        alloc,
        &metrics,
        &stable_source,
        4,
        &stable_prepared,
    );
    const stable_paint = &stable_prepared.?;
    try std.testing.expectEqual(
        stable_frame.layout.owned_top,
        stable_frame.scroll_plan.post_scroll_owned_top,
    );
    var stable_plan = testPaintPlanForFrame(
        stable_frame.layout,
        stable_paint.selection,
        stable_paint.cursor.cursor_row,
        stable_paint.cursor.cursor_col,
    );
    var stable_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &stable_source,
        stable_paint,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(stable_frame.layout),
        &stable_plan,
        stable_frame.scroll_plan,
    );
    defer stable_transition.deinit(alloc);
    try std.testing.expect(stable_transition.document_append.isEmpty());

    var stable_painter = PreparedTranscriptFramePainter{
        .runtime = &runtime,
        .alloc = alloc,
        .prepared = stable_paint,
    };
    const stable_result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = stable_plan,
            .scroll_plan = stable_frame.scroll_plan,
            .document_append = stable_transition.document_append,
            .body_painter = .{
                .ctx = &stable_painter,
                .paint = PreparedTranscriptFramePainter.paint,
            },
        },
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        stable_result.shadow_state,
    );
    runtime.ackPreservedRowReleaseAssumeValid(
        stable_frame.scroll_plan,
        stable_result.terminal_scroll_rows_committed,
    );
    runtime.consumeTranscriptTransition(alloc, &stable_transition, stable_result);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );

    var raw_line: std.ArrayList(u8) = .empty;
    defer raw_line.deinit(alloc);
    var raw_line_index: usize = 0;
    while (raw_line_index < raw_line_count) : (raw_line_index += 1) {
        try runtime.transcript.appendSlice(alloc, "\n");
        raw_line.clearRetainingCapacity();
        try raw_line.appendNTimes(
            alloc,
            'a' + @as(u8, @intCast(raw_line_index)),
            raw_line_bytes,
        );
        try std.testing.expectEqual(
            @as(u16, @intCast(wrapped_rows_per_line)),
            visualRowsForLine(raw_line.items, cols),
        );
        try runtime.transcript.appendSlice(alloc, raw_line.items);
    }

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(
        @as(u16, std.math.maxInt(u16)),
        source.preview.natural_visual_rows,
    );
    try std.testing.expectEqual(@as(usize, 1), source.folded_summary_indices.len);
    try std.testing.expectEqual(@as(usize, 1), source.folded_summary_indices[0]);

    var prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
    defer if (prepared) |*paint| paint.deinit(alloc);
    const frame = try solveTestTranscriptFixedPointFrame(
        &runtime,
        alloc,
        &metrics,
        &source,
        8,
        &prepared,
    );
    const paint = &prepared.?;
    const facts = runtime.planTranscriptScroll(paint);
    try std.testing.expect(facts.semantic_rows > std.math.maxInt(u16));
    try std.testing.expectEqual(viewport_rows, facts.planned_rows);
    try std.testing.expectEqual(
        frame.layout.owned_top,
        frame.scroll_plan.post_scroll_owned_top,
    );
    try std.testing.expectEqual(
        viewport_rows,
        frame.scroll_plan.acceptedInlineRows(
            frame.scroll_plan.terminal_scroll_rows,
        ),
    );

    var plan = testPaintPlanForFrame(
        frame.layout,
        paint.selection,
        paint.cursor.cursor_row,
        paint.cursor.cursor_col,
    );
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        paint,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(frame.layout),
        &plan,
        frame.scroll_plan,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(transition.document_append.isEmpty());
    try std.testing.expectEqual(@as(?usize, null), transition.materialized.flow_len);
    try std.testing.expectEqual(viewport_rows, transition.materialized.visual_rows);
    try std.testing.expectEqual(
        @as(u32, viewport_rows),
        transition.materialized.visual_offset,
    );
    var transition_template = try cloneRecoveryTransitionForTest(
        alloc,
        &transition,
    );
    errdefer transition_template.deinit(alloc);

    var painter = PreparedTranscriptFramePainter{
        .runtime = &runtime,
        .alloc = alloc,
        .prepared = paint,
    };
    const result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = plan,
            .scroll_plan = frame.scroll_plan,
            .document_append = transition.document_append,
            .body_painter = .{
                .ctx = &painter,
                .paint = PreparedTranscriptFramePainter.paint,
            },
        },
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        result.shadow_state,
    );
    try std.testing.expectEqual(
        frame.scroll_plan.terminal_scroll_rows,
        result.terminal_scroll_rows_committed,
    );
    try std.testing.expect(!result.document_append_committed);
    runtime.ackPreservedRowReleaseAssumeValid(
        frame.scroll_plan,
        result.terminal_scroll_rows_committed,
    );
    runtime.consumeTranscriptTransition(alloc, &transition, result);

    const diagnostic = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        diagnostic.state,
    );
    try std.testing.expectEqual(transition.visual_offset, diagnostic.visual_offset);
    try std.testing.expect(diagnostic.remaining_inline_rows > 0);
    try std.testing.expectEqual(
        facts.semantic_rows - facts.planned_rows,
        diagnostic.remaining_inline_rows,
    );

    return transition_template;
}

fn testSelectionInArea(
    start_line: usize,
    top_row: u16,
    bottom_row: u16,
) viewport_selection.ViewportSelection {
    var selection = testSelection(start_line);
    selection.top_row = top_row;
    selection.bottom_row = bottom_row;
    return selection;
}

fn enterSemanticAppendRecovery(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    stable_flow: []const u8,
    attempt_flow: []const u8,
    attempt_visual_rows: []const u16,
) !void {
    const stable_selection = testSelectionInArea(
        0,
        runtime.owned_top_row,
        runtime.layout.content_bottom,
    );
    try installStableAnchorForTest(
        runtime,
        alloc,
        stable_flow,
        stable_selection,
        0,
        runtime.layout.content_bottom,
        1,
        45,
    );

    var source = try testSource(alloc, attempt_flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(
            4,
            runtime.owned_top_row,
            runtime.layout.content_bottom,
        ),
        .cursor = .{
            .cursor_row = runtime.layout.content_bottom,
            .cursor_col = 1,
            .replaceable_row = runtime.layout.content_bottom,
        },
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, attempt_visual_rows);
    try makeSyntheticPreparedRenderable(&prepared, alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 0), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 4), facts.semantic_rows);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        3,
        facts.planned_rows,
    );
    try std.testing.expectEqual(@as(u16, 1), scroll_plan.remaining_inline_advance_rows);

    var plan = testPaintPlan(runtime, prepared.selection);
    const target_layout =
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(transition.document_append.isEmpty());

    runtime.ackPreservedRowReleaseAssumeValid(
        scroll_plan,
        scroll_plan.terminal_scroll_rows,
    );
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = false,
        .terminal_scroll_rows_committed = scroll_plan.terminal_scroll_rows,
        .document_append_committed = false,
        .committed_cursor_row = runtime.layout.content_bottom,
        .committed_cursor_col = 1,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u32, 3), recovery.visual_offset);
    try std.testing.expectEqual(@as(u16, 1), recovery.remaining_inline_rows);
}

fn consumeUnacceptedSemanticRecoveryRetry(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    flow: []const u8,
    visual_rows: []const u16,
    start_line: usize,
) !void {
    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(
            start_line,
            runtime.owned_top_row,
            runtime.layout.content_bottom,
        ),
        .cursor = .{
            .cursor_row = runtime.layout.content_bottom,
            .cursor_col = 1,
            .replaceable_row = runtime.layout.content_bottom,
        },
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, visual_rows);
    try makeSyntheticPreparedRenderable(&prepared, alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 0), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 1), facts.semantic_rows);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = runtime.layout.content_bottom,
        .committed_cursor_col = 1,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    const recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u32, 3), recovery.visual_offset);
    try std.testing.expectEqual(@as(u16, 1), recovery.remaining_inline_rows);
}

fn enterResizeReflowRecovery(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    resize_history_row_delta: ?i32,
    shadow_state: render_engine.terminal_diff.ShadowCommitState,
) !void {
    return enterResizeReflowRecoveryWithAcceptedRows(
        runtime,
        alloc,
        resize_history_row_delta,
        shadow_state,
        1,
    );
}

fn enterResizeReflowRecoveryWithAcceptedRows(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    resize_history_row_delta: ?i32,
    shadow_state: render_engine.terminal_diff.ShadowCommitState,
    accepted_rows: u16,
) !void {
    const flow = "stable\nbase\n";
    try runtime.enableShadowVt(alloc);
    try installStableAnchorForTest(
        runtime,
        alloc,
        flow,
        testSelectionInArea(0, 1, 4),
        0,
        4,
        1,
        46,
    );
    const shadow = runtime.shadow_vt.?;
    shadow.cells[19].codepoint = 'x';
    shadow.cursor_row = 8;
    shadow.cursor_col = 1;

    runtime.viewport_clear_pending = true;
    runtime.layout = transcriptTestLayout(10, 8, 2);
    runtime.resize_history_row_delta = resize_history_row_delta;

    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(runtime, alloc, &source);
    defer prepared.deinit(alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 2), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), facts.semantic_rows);
    try std.testing.expect(accepted_rows < facts.planned_rows);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, prepared.selection);
    const target_layout =
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(transition.document_append.isEmpty());

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = accepted_rows,
        .document_append_committed = false,
        .committed_cursor_row = 2,
        .committed_cursor_col = 1,
        .shadow_state = shadow_state,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(facts.target_visual_offset, recovery.visual_offset);
    try std.testing.expectEqual(
        facts.planned_rows - accepted_rows,
        recovery.remaining_inline_rows,
    );
}

test "committed resize deferral installs target layout before recovery" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    try enterResizeReflowRecoveryWithAcceptedRows(
        &runtime,
        alloc,
        null,
        .committed,
        0,
    );

    const expected_layout =
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(
            testPaintPlan(&runtime, testSelectionInArea(0, 1, 2)),
        );
    try std.testing.expectEqualDeep(expected_layout, runtime.committed_frame_layout);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        runtime.transcriptCommitDiagnostic().state,
    );
}

const RecoveryAttemptOutcome = struct {
    facts: transcript_runtime.TranscriptScrollFacts,
    visual_offset: u32,
};

fn consumeRendererRecoveryAttempt(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    flow: []const u8,
    committed_inline_rows: u16,
    shadow_state: render_engine.terminal_diff.ShadowCommitState,
) !RecoveryAttemptOutcome {
    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(runtime, alloc, &source);
    defer prepared.deinit(alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    try std.testing.expect(committed_inline_rows <= scroll_plan.terminal_scroll_rows);
    var plan = testPaintPlan(runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    const visual_offset = transition.visual_offset;

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = committed_inline_rows,
        .document_append_committed = !transition.document_append.isEmpty(),
        .committed_cursor_row = transition.cursor_row,
        .committed_cursor_col = transition.cursor_col,
        .shadow_state = shadow_state,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    return .{
        .facts = facts,
        .visual_offset = visual_offset,
    };
}

fn expectDocumentWireEqualsLogical(
    alloc: Allocator,
    logical: []const u8,
    wire: []const u8,
) !void {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(alloc);
    var index: usize = 0;
    while (index < wire.len) {
        if (wire[index] == '\n') return error.TestExpectedCarriageReturn;
        if (wire[index] == '\r' and index + 1 < wire.len and wire[index + 1] == '\n') {
            try decoded.append(alloc, '\n');
            index += 2;
        } else {
            try decoded.append(alloc, wire[index]);
            index += 1;
        }
    }
    try std.testing.expectEqualStrings(logical, decoded.items);
}

fn expectRendererAppendRestored(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    stable_flow: []const u8,
    grown_flow: []const u8,
) !void {
    var source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(runtime, alloc, &source);
    defer prepared.deinit(alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(!facts.recovery_rebase);
    try std.testing.expect(facts.semantic_rows > 0);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    try expectDocumentWireEqualsLogical(
        alloc,
        grown_flow[stable_flow.len..],
        transition.document_append.bytes,
    );
}

fn checkTranscriptTransitionStagingAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try installStableAnchorForTest(&runtime, alloc, "old\n", testSelection(0), 0, 3, 1, 71);
    const committed_before = runtime.transcriptCommitDiagnostic();

    var source = try testSource(alloc, "old\nnew\n", runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = source.bytes,
        .owns_bytes = false,
        .selection = testSelection(1),
        .cursor = .{ .cursor_row = 4, .cursor_col = 1, .replaceable_row = 4 },
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, &.{ 1, 1 });
    const scroll_plan = render_engine.frame_scroll_plan.merge(runtime.layout.rows, 1, 0, 1);
    var plan = testPaintPlan(&runtime, prepared.selection);
    const target_layout = render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    ) catch |err| {
        try std.testing.expectEqualDeep(committed_before, runtime.transcriptCommitDiagnostic());
        try std.testing.expect(runtime.stableTranscriptProjectionForFlow("old\n") != null);
        return err;
    };
    defer transition.deinit(alloc);

    try std.testing.expectEqualDeep(committed_before, runtime.transcriptCommitDiagnostic());
    try std.testing.expect(runtime.stableTranscriptProjectionForFlow("old\n") != null);
}

fn commandOutputTestStyles() Styles {
    return .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
}

fn commandOutputAnsiTestStyles() Styles {
    return .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "\x1b[0m",
        .dim_style = "\x1b[2m",
        .red_style = "\x1b[31m",
    };
}

fn semanticNoticePaletteA() Styles {
    return .{
        .system_notice_text_style = "\x1b[37m",
        .reset_style = "\x1b[0m",
        .notice_information_style = "\x1b[36m",
        .notice_success_style = "\x1b[32m",
        .notice_warning_style = "\x1b[33m",
        .notice_error_style = "\x1b[31m",
        .notice_cancelled_style = "\x1b[90m",
    };
}

fn semanticNoticePaletteB() Styles {
    return .{
        .system_notice_text_style = "\x1b[35m",
        .reset_style = "\x1b[0m",
        .notice_information_style = "\x1b[34m",
        .notice_success_style = "\x1b[92m",
        .notice_warning_style = "\x1b[93m",
        .notice_error_style = "\x1b[91m",
        .notice_cancelled_style = "\x1b[2m",
    };
}

test "semantic notice append and replacement preserve ownership identity and timestamp" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(32, 16, 12) };
    defer runtime.deinit(alloc);
    runtime.setCommandOutputRenderPolicy(semanticNoticePaletteA());

    const entry_id = try runtime.appendReplaceableSemanticNotice(alloc, .{
        .topic = "build",
        .tone = .warning,
        .body = "first body",
    });
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .semantic_notice);
    try std.testing.expect(runtime.entries.items[0].semantic_notice.pending_replacement);
    const created_at_ms = runtime.entries.items[0].createdAtMs();
    try std.testing.expectEqualStrings("build", runtime.entries.items[0].semantic_notice.topic);
    try std.testing.expectEqualStrings("first body", runtime.entries.items[0].semantic_notice.body);

    try std.testing.expect(try runtime.replaceSemanticNotice(alloc, entry_id, .{
        .topic = "deploy",
        .tone = .success,
        .body = "replacement body with /tmp/output/path",
        .visibility = .full_only,
    }));
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());
    try std.testing.expectEqual(created_at_ms, runtime.entries.items[0].createdAtMs());
    try std.testing.expectEqualStrings("deploy", runtime.entries.items[0].semantic_notice.topic);
    try std.testing.expectEqual(types.NoticeTone.success, runtime.entries.items[0].semantic_notice.tone);
    try std.testing.expectEqualStrings("replacement body with /tmp/output/path", runtime.entries.items[0].semantic_notice.body);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, runtime.entries.items[0].semantic_notice.visibility);
    try std.testing.expectEqualStrings("", runtime.transcript.items);
    // The finished replacement clears the pending-replacement pin, making
    // the entry immutable history: a second in-place replacement is refused.
    try std.testing.expect(!runtime.entries.items[0].semantic_notice.pending_replacement);
    try std.testing.expectError(
        error.MissingNoticeReplacementPin,
        runtime.replaceSemanticNotice(alloc, entry_id, .{
            .topic = "again",
            .tone = .information,
            .body = "must not apply",
        }),
    );
    try std.testing.expect(!(try runtime.replaceSemanticNotice(alloc, entry_id + 1, .{
        .topic = "missing",
        .tone = .information,
        .body = "unchanged",
    })));
}

fn checkSemanticNoticeAppendAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(32, 16, 12) };
    defer runtime.deinit(alloc);
    const entry_id = try runtime.appendSemanticNotice(alloc, .{
        .topic = "allocator",
        .tone = .@"error",
        .body = "owned topic and body",
    });
    try std.testing.expectEqual(@as(u32, 1), entry_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expectEqualStrings("allocator", runtime.entries.items[0].semantic_notice.topic);
    try std.testing.expectEqualStrings("owned topic and body", runtime.entries.items[0].semantic_notice.body);
}

test "semantic notice append is allocator safe" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSemanticNoticeAppendAllocationFailures,
        .{},
    );
}

fn checkSemanticNoticeReplacementAllocationFailures(alloc: Allocator) !void {
    const base = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(32, 16, 12) };
    defer runtime.deinit(base);
    const entry_id = try runtime.appendReplaceableSemanticNotice(base, .{
        .topic = "before",
        .tone = .information,
        .body = "stable body",
    });
    const created_at_ms = runtime.entries.items[0].createdAtMs();
    const next_entry_id = runtime.next_entry_id;

    const replaced = runtime.replaceSemanticNotice(alloc, entry_id, .{
        .topic = "after",
        .tone = .cancelled,
        .body = "replacement body",
    }) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
        try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());
        try std.testing.expectEqual(created_at_ms, runtime.entries.items[0].createdAtMs());
        try std.testing.expectEqualStrings("before", runtime.entries.items[0].semantic_notice.topic);
        try std.testing.expectEqualStrings("stable body", runtime.entries.items[0].semantic_notice.body);
        try std.testing.expectEqual(next_entry_id, runtime.next_entry_id);
        return err;
    };
    try std.testing.expect(replaced);
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());
    try std.testing.expectEqual(created_at_ms, runtime.entries.items[0].createdAtMs());
    try std.testing.expectEqualStrings("after", runtime.entries.items[0].semantic_notice.topic);
    try std.testing.expectEqualStrings("replacement body", runtime.entries.items[0].semantic_notice.body);
    try std.testing.expectEqual(next_entry_id, runtime.next_entry_id);
}

test "semantic notice replacement is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSemanticNoticeReplacementAllocationFailures,
        .{},
    );
}

test "one retained semantic notice reflows through compact and full projection with retained palettes" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(36, 24, 20) };
    defer runtime.deinit(alloc);
    const notice: types.SemanticNotice = .{
        .topic = "paths",
        .tone = .information,
        .body = "review /workspace/packages/terminal/rendering.zig before continuing",
    };
    const entry_id = try runtime.appendSemanticNotice(alloc, notice);

    const cases = [_]struct { cols: u16, styles: Styles }{
        .{ .cols = 36, .styles = semanticNoticePaletteA() },
        .{ .cols = 18, .styles = semanticNoticePaletteB() },
    };
    for (cases) |case| {
        runtime.layout = transcriptTestLayout(case.cols, 24, 20);
        runtime.setCommandOutputRenderPolicy(case.styles);
        const expected = try transcript_blocks.renderSemanticNotice(alloc, notice, case.styles, case.cols);
        defer alloc.free(expected);

        var compact = try runtime.prepareTranscriptSource(alloc, null);
        defer compact.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, compact.bytes, expected) != null);

        var projection = try runtime.buildFullTranscriptProjection(alloc, null);
        defer projection.deinit(alloc);
        const full = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
            alloc,
            &projection,
            null,
            case.cols,
            64,
            0,
            null,
        );
        defer alloc.free(full);
        try std.testing.expect(std.mem.find(u8, full, expected) != null);
        try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());
    }
}

test "visible overflow after committed frame leaves scroll planning to viewport selection" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 12,
            .cols = 40,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .viewport_top_row = 4,
        .owned_top_row = 4,
        .cursor_row = 8,
        .cursor_col = 1,
        .has_painted_transcript = true,
        .has_committed_frame = true,
    };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    try runtime.writeTranscript(alloc, &metrics, "overflow\n", true);

    try std.testing.expectEqual(@as(u16, 4), runtime.owned_top_row);
    try std.testing.expectEqual(@as(u16, 4), runtime.viewport_top_row);
}

test "neutral transcript flow preview reports natural rows without footer reservation" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 12,
            .cols = 40,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .viewport_top_row = 1,
        .owned_top_row = 1,
        .cursor_row = 8,
        .cursor_col = 1,
        .has_painted_transcript = true,
        .last_paint_bottom_reserved_rows = 3,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try runtime.transcript.appendSlice(alloc, "line 1\nline 2\nline 3\n");

    const preview = try runtime.previewTranscriptFlow(alloc);

    try std.testing.expectEqual(@as(u16, 3), preview.natural_visual_rows);
    try std.testing.expectEqual(@as(u16, 1), preview.cursor_col);
    try std.testing.expectEqual(@as(u16, 3), runtime.last_paint_bottom_reserved_rows);
}

test "stable transcript planning uses visual rows and partial skips" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try installStableAnchorForTest(&runtime, alloc, "stable", testSelection(0), 0, 3, 1, 41);

    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = try alloc.dupe(u8, "stable"),
        .selection = testSelection(1),
    };
    defer prepared.deinit(alloc);
    prepared.selection.partial_skip_rows = 2;
    try prepared.line_visual_rows.appendSlice(alloc, &.{ 3, 4, 2, 1 });

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expectEqual(@as(u32, 5), facts.target_visual_offset);
    try std.testing.expectEqual(@as(u16, 5), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 5), facts.planned_rows);
}

test "compatible growth beyond one frame retains exact semantic debt" {
    const alloc = std.testing.allocator;
    const stable_flow = "base\n";
    const extra_row_count: usize = @as(usize, std.math.maxInt(u16)) + 8;
    var grown_flow: std.ArrayList(u8) = .empty;
    defer grown_flow.deinit(alloc);
    try grown_flow.ensureTotalCapacity(
        alloc,
        stable_flow.len + extra_row_count * "x\n".len,
    );
    grown_flow.appendSliceAssumeCapacity(stable_flow);
    for (0..extra_row_count) |_| {
        grown_flow.appendSliceAssumeCapacity("x\n");
    }

    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        stable_flow,
        testSelection(0),
        0,
        2,
        1,
        411,
    );

    var probe_source = try testSource(alloc, grown_flow.items, runtime.layout.cols);
    defer probe_source.deinit(alloc);
    var probe_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &probe_source,
    );
    defer probe_prepared.deinit(alloc);
    const probe_facts = runtime.planTranscriptScroll(&probe_prepared);
    const exact_semantic_rows = probe_facts.target_visual_offset;
    try std.testing.expect(exact_semantic_rows > std.math.maxInt(u16));
    try std.testing.expectEqual(
        exact_semantic_rows,
        @as(u32, probe_facts.semantic_rows),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u16),
        probe_facts.planned_rows,
    );

    const accepted_rows = std.math.maxInt(u16);
    const initial = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        grown_flow.items,
        accepted_rows,
        .committed,
    );
    try std.testing.expectEqual(
        exact_semantic_rows,
        @as(u32, initial.facts.semantic_rows),
    );
    const remaining_after_cap = exact_semantic_rows - accepted_rows;
    try std.testing.expectEqual(
        remaining_after_cap,
        @as(u32, runtime.transcriptCommitDiagnostic().remaining_inline_rows),
    );
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;

    const repeated = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        grown_flow.items,
        1,
        .terminal_partial_write,
    );
    try std.testing.expectEqual(
        remaining_after_cap,
        @as(u32, repeated.facts.semantic_rows),
    );
    const remaining_semantic_rows = remaining_after_cap - 1;
    try std.testing.expectEqual(
        remaining_semantic_rows,
        @as(u32, runtime.transcriptCommitDiagnostic().remaining_inline_rows),
    );

    const complete = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        grown_flow.items,
        @intCast(remaining_semantic_rows),
        .committed,
    );
    try std.testing.expectEqual(
        remaining_semantic_rows,
        @as(u32, complete.facts.semantic_rows),
    );
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    const stable = runtime.stableTranscriptProjectionForFlow(grown_flow.items) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(exact_semantic_rows, stable.visual_offset);
}

test "oversized compatible growth materializes only each accepted projection" {
    const alloc = std.testing.allocator;
    const stable_flow = "base\n";
    const filler_row_count: usize = @as(usize, std.math.maxInt(u16)) - 1;
    const staged_tail =
        "cap 0\n" ++
        "cap 1\n" ++
        "cap 2\n" ++
        "cap 3\n" ++
        "gap\n" ++
        "tail 0\n" ++
        "tail 1\n" ++
        "tail 2\n" ++
        "tail 3";
    var grown_flow: std.ArrayList(u8) = .empty;
    defer grown_flow.deinit(alloc);
    try grown_flow.ensureTotalCapacity(
        alloc,
        stable_flow.len + filler_row_count * "x\n".len + staged_tail.len,
    );
    grown_flow.appendSliceAssumeCapacity(stable_flow);
    for (0..filler_row_count) |_| {
        grown_flow.appendSliceAssumeCapacity("x\n");
    }
    grown_flow.appendSliceAssumeCapacity(staged_tail);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(
        std.testing.io,
        "oversized-staged-projection.log",
        .{ .read = true },
    );
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try runtime.shadow_vt.?.feed(stable_flow);

    var stable_source = try testSource(alloc, stable_flow, runtime.layout.cols);
    defer stable_source.deinit(alloc);
    var stable_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &stable_source,
    );
    defer stable_prepared.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        stable_flow,
        stable_prepared.selection,
        0,
        stable_prepared.cursor.cursor_row,
        stable_prepared.cursor.cursor_col,
        412,
    );

    var materialized_append: std.ArrayList(u8) = .empty;
    defer materialized_append.deinit(alloc);

    var first_source = try testSource(alloc, grown_flow.items, runtime.layout.cols);
    defer first_source.deinit(alloc);
    var first_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &first_source,
    );
    defer first_prepared.deinit(alloc);
    const first_facts = runtime.planTranscriptScroll(&first_prepared);
    try std.testing.expectEqual(
        @as(u16, std.math.maxInt(u16)),
        first_facts.planned_rows,
    );
    try std.testing.expect(first_facts.semantic_rows > first_facts.planned_rows);
    const first_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        first_facts.planned_rows,
    );
    var first_plan = testPaintPlan(&runtime, first_prepared.selection);
    var first_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &first_source,
        &first_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(first_plan),
        &first_plan,
        first_scroll_plan,
    );
    defer first_transition.deinit(alloc);

    try std.testing.expectEqual(
        @as(u32, std.math.maxInt(u16)),
        first_transition.visual_offset,
    );
    try std.testing.expectEqual(
        first_facts.target_visual_offset + 4,
        first_transition.total_visual_rows,
    );
    try std.testing.expectEqual(@as(u16, 5), first_transition.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), first_transition.cursor_col);
    try std.testing.expect(!first_transition.document_append.isEmpty());
    try std.testing.expect(first_transition.materialized.flow_len.? < grown_flow.items.len);
    try materialized_append.appendSlice(
        alloc,
        first_transition.document_append.bytes,
    );

    var first_painter = PreparedTranscriptFramePainter{
        .runtime = &runtime,
        .alloc = alloc,
        .prepared = &first_prepared,
    };
    var metrics: Metrics = .{};
    const first_result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = first_plan,
            .scroll_plan = first_scroll_plan,
            .document_append = first_transition.document_append,
            .body_painter = .{
                .ctx = &first_painter,
                .paint = PreparedTranscriptFramePainter.paint,
            },
        },
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        first_result.shadow_state,
    );
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    try runtime.shadow_vt.?.rowTextTrimmed(1, &row_text);
    try std.testing.expectEqualStrings("cap 0", row_text.items);
    row_text.clearRetainingCapacity();
    try runtime.shadow_vt.?.rowTextTrimmed(4, &row_text);
    try std.testing.expectEqualStrings("cap 3", row_text.items);

    runtime.consumeTranscriptTransition(alloc, &first_transition, first_result);
    const after_first = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        after_first.state,
    );
    try std.testing.expectEqual(
        first_facts.semantic_rows - first_facts.planned_rows,
        after_first.remaining_inline_rows,
    );
    try std.testing.expectEqual(
        @as(u32, std.math.maxInt(u16)),
        after_first.visual_offset,
    );

    var retry_source = try testSource(alloc, grown_flow.items, runtime.layout.cols);
    defer retry_source.deinit(alloc);
    var retry_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &retry_source,
    );
    defer retry_prepared.deinit(alloc);
    const retry_facts = runtime.planTranscriptScroll(&retry_prepared);
    try std.testing.expectEqual(
        after_first.remaining_inline_rows,
        retry_facts.semantic_rows,
    );
    const retry_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        retry_facts.planned_rows,
    );
    var retry_plan = testPaintPlan(&runtime, retry_prepared.selection);
    var retry_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &retry_source,
        &retry_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(retry_plan),
        &retry_plan,
        retry_scroll_plan,
    );
    defer retry_transition.deinit(alloc);
    try std.testing.expectEqual(
        retry_facts.target_visual_offset,
        retry_transition.visual_offset,
    );
    try std.testing.expect(!retry_transition.document_append.isEmpty());
    try std.testing.expectEqual(
        first_transition.cursor_row,
        retry_transition.document_append.start_row,
    );
    try std.testing.expectEqual(
        first_transition.cursor_col,
        retry_transition.document_append.start_col,
    );
    try materialized_append.appendSlice(
        alloc,
        retry_transition.document_append.bytes,
    );
    try expectDocumentWireEqualsLogical(
        alloc,
        grown_flow.items[stable_flow.len..],
        materialized_append.items,
    );

    var retry_painter = PreparedTranscriptFramePainter{
        .runtime = &runtime,
        .alloc = alloc,
        .prepared = &retry_prepared,
    };
    const retry_result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = retry_plan,
            .scroll_plan = retry_scroll_plan,
            .document_append = retry_transition.document_append,
            .body_painter = .{
                .ctx = &retry_painter,
                .paint = PreparedTranscriptFramePainter.paint,
            },
        },
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        retry_result.shadow_state,
    );
    row_text.clearRetainingCapacity();
    try runtime.shadow_vt.?.rowTextTrimmed(1, &row_text);
    try std.testing.expectEqualStrings("tail 0", row_text.items);
    row_text.clearRetainingCapacity();
    try runtime.shadow_vt.?.rowTextTrimmed(4, &row_text);
    try std.testing.expectEqualStrings("tail 3", row_text.items);

    runtime.consumeTranscriptTransition(alloc, &retry_transition, retry_result);
    const stable = runtime.stableTranscriptProjectionForFlow(grown_flow.items) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(retry_facts.target_visual_offset, stable.visual_offset);
    try std.testing.expectEqual(retry_transition.cursor_row, stable.cursor_row);
    try std.testing.expectEqual(retry_transition.cursor_col, stable.cursor_col);
}

test "folded inexact growth advances only materialized viewport rows" {
    const alloc = std.testing.allocator;
    const cols: u16 = 16;
    const viewport_rows: u16 = 4;
    const growth_rows: usize = @as(usize, viewport_rows) * 2;
    const growth_rows_u32: u32 = @intCast(growth_rows);
    const initial_owned_top = viewport_rows + 1;
    const content_bottom = initial_owned_top + viewport_rows - 1;
    const stable_flow = "summary";
    var seed_transition = try createProductionCappedFoldedRecoveryTransition(
        alloc,
        cols,
        viewport_rows,
    );
    defer seed_transition.deinit(alloc);
    try std.testing.expectEqual(@as(?usize, null), seed_transition.materialized.flow_len);
    try std.testing.expect(
        seed_transition.semantic_rows >
            seed_transition.scroll_plan.requested_inline_advance_rows,
    );

    var grown_flow: std.ArrayList(u8) = .empty;
    defer grown_flow.deinit(alloc);
    try grown_flow.ensureTotalCapacity(
        alloc,
        stable_flow.len + growth_rows * "\ng00000".len,
    );
    grown_flow.appendSliceAssumeCapacity(stable_flow);
    var growth_index: usize = 0;
    while (growth_index < growth_rows) : (growth_index += 1) {
        var line_buf: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buf,
            "\ng{d:0>5}",
            .{growth_index},
        );
        grown_flow.appendSliceAssumeCapacity(line);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(
        std.testing.io,
        "folded-staged-projection.log",
        .{ .read = true },
    );
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = transcriptTestLayout(
            cols,
            content_bottom + 4,
            content_bottom,
        ),
        .owned_top_row = initial_owned_top,
        .full_transcript = .{ .depth = .full },
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try runtime.shadow_vt.?.feed("shell0\r\nshell1\r\nshell2\r\nshell3");
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_transcript_index = 1,
    });
    var fold_index: usize = 0;
    while (fold_index < viewport_rows) : (fold_index += 1) {
        var fold_buf: [16]u8 = undefined;
        const fold = try std.fmt.bufPrint(&fold_buf, "fold{d}", .{fold_index});
        try appendFoldedLineForTest(&runtime, alloc, 0, fold);
    }

    var metrics: Metrics = .{};
    var stable_source = try testFoldedSource(
        alloc,
        stable_flow,
        runtime.layout.cols,
        1,
    );
    defer stable_source.deinit(alloc);
    var stable_fixed_prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
    defer if (stable_fixed_prepared) |*prepared| prepared.deinit(alloc);
    const stable_frame = try solveTestTranscriptFixedPointFrame(
        &runtime,
        alloc,
        &metrics,
        &stable_source,
        4,
        &stable_fixed_prepared,
    );
    const stable_fixed = &stable_fixed_prepared.?;
    try std.testing.expectEqual(@as(u32, 0), preparedVisualOffsetForTest(stable_fixed));
    try std.testing.expectEqual(
        @as(u32, viewport_rows),
        totalVisualRowsForTest(stable_fixed.sourceVisualRows()),
    );
    try std.testing.expectEqual(
        stable_frame.layout.owned_top,
        stable_frame.scroll_plan.post_scroll_owned_top,
    );
    var stable_plan = testPaintPlanForFrame(
        stable_frame.layout,
        stable_fixed.selection,
        stable_fixed.cursor.cursor_row,
        stable_fixed.cursor.cursor_col,
    );
    var stable_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &stable_source,
        stable_fixed,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(stable_frame.layout),
        &stable_plan,
        stable_frame.scroll_plan,
    );
    defer stable_transition.deinit(alloc);
    var stable_painter = PreparedTranscriptFramePainter{
        .runtime = &runtime,
        .alloc = alloc,
        .prepared = stable_fixed,
    };
    const stable_result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = stable_plan,
            .scroll_plan = stable_frame.scroll_plan,
            .body_painter = .{
                .ctx = &stable_painter,
                .paint = PreparedTranscriptFramePainter.paint,
            },
        },
    );
    runtime.ackPreservedRowReleaseAssumeValid(
        stable_frame.scroll_plan,
        stable_result.terminal_scroll_rows_committed,
    );
    runtime.consumeTranscriptTransition(alloc, &stable_transition, stable_result);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );

    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    try runtime.shadow_vt.?.rowTextTrimmed(initial_owned_top, &row_text);
    try std.testing.expectEqualStrings("│ fold0", row_text.items);
    row_text.clearRetainingCapacity();
    try runtime.shadow_vt.?.rowTextTrimmed(content_bottom, &row_text);
    try std.testing.expectEqualStrings("│ fold3", row_text.items);

    var history: std.ArrayList(u8) = .empty;
    defer history.deinit(alloc);
    var seed_source = try testFoldedSource(
        alloc,
        grown_flow.items,
        runtime.layout.cols,
        1,
    );
    defer seed_source.deinit(alloc);
    seed_source.preview.natural_visual_rows =
        @intCast(@as(u32, viewport_rows) + growth_rows_u32);
    const seed_release = render_engine.frame_layout.solveWithPreservedRowRelease(.{
        .terminal = runtime.layout,
        .owned_top = runtime.owned_top_row,
        .footer = .{
            .natural_rows = 8,
            .min_rows = 8,
            .max_rows = 8,
        },
        .transcript = seed_source.preview,
        .prior = runtime.committed_frame_layout,
    }, 0);
    const compact_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        seed_release.released_rows,
        seed_transition.scroll_plan.requested_inline_advance_rows,
    );
    try std.testing.expectEqualDeep(seed_transition.scroll_plan, compact_scroll_plan);
    try std.testing.expectEqual(
        seed_release.layout.owned_top,
        seed_transition.scroll_plan.post_scroll_owned_top,
    );
    const seed_target_layout =
        render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(seed_release.layout);
    try std.testing.expectEqualDeep(seed_transition.target_layout, seed_target_layout);

    var seed_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &seed_source,
    );
    defer seed_prepared.deinit(alloc);
    const seed_target_offset = preparedVisualOffsetForTest(&seed_prepared);
    try std.testing.expectEqual(growth_rows_u32, seed_target_offset);
    const seed_total_visual_rows =
        totalVisualRowsForTest(seed_prepared.sourceVisualRows());
    try std.testing.expectEqual(
        @as(u32, viewport_rows) + growth_rows_u32,
        seed_total_visual_rows,
    );
    const seed_projection = try transcript_painter.stagePreparedTranscriptForVisualOffset(
        alloc,
        runtime.layout,
        &seed_prepared,
        seed_release.layout.transcript_area,
        seed_transition.visual_offset,
    );
    try std.testing.expectEqual(
        seed_transition.materialized.flow_len,
        seed_projection.flow_end,
    );
    try std.testing.expectEqual(
        seed_transition.materialized.visual_rows,
        seed_prepared.projection_visual_rows.?,
    );
    try std.testing.expectEqual(
        seed_transition.materialized.visual_offset,
        seed_transition.visual_offset,
    );

    var contract_selection = seed_prepared.selection;
    contract_selection.line_count = seed_transition.selection.line_count;
    contract_selection.tail_kind = seed_transition.selection.tail_kind;
    try std.testing.expectEqualDeep(seed_transition.selection, contract_selection);
    try std.testing.expectEqual(
        seed_transition.materialized.cursor_row,
        seed_prepared.cursor.cursor_row,
    );
    try std.testing.expectEqual(
        seed_transition.materialized.cursor_col,
        seed_prepared.cursor.cursor_col,
    );
    try std.testing.expectEqual(
        seed_transition.cursor_row,
        seed_prepared.cursor.cursor_row,
    );
    try std.testing.expectEqual(
        seed_transition.cursor_col,
        seed_prepared.cursor.cursor_col,
    );
    try std.testing.expectEqual(
        seed_transition.replaceable_last_line,
        seed_prepared.replaceable_last_line,
    );
    try std.testing.expectEqual(
        seed_transition.replaceable_start,
        seed_prepared.replaceable_start,
    );
    try std.testing.expectEqual(
        seed_transition.replaceable_row,
        seed_prepared.cursor.replaceable_row,
    );
    try std.testing.expectEqualSlices(
        usize,
        seed_transition.folded_summary_indices,
        seed_source.folded_summary_indices,
    );
    try std.testing.expect(seed_transition.document_append.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), seed_transition.document_append_bytes.len);

    const compact_target_flow = try alloc.dupe(u8, grown_flow.items);
    if (seed_transition.target_flow.len > 0) alloc.free(seed_transition.target_flow);
    seed_transition.target_flow = compact_target_flow;
    seed_transition.target_cache.clearRetainingCapacity();
    try seed_transition.target_cache.appendSlice(alloc, grown_flow.items);
    seed_transition.semantic_rows = growth_rows_u32;
    seed_transition.semantic_progress_rows = growth_rows_u32;
    seed_transition.selection = seed_prepared.selection;
    seed_transition.source_endpoint_visual_offset = seed_target_offset;
    seed_transition.total_visual_rows = seed_total_visual_rows;

    try appendGridRows(
        alloc,
        runtime.shadow_vt.?,
        1,
        seed_transition.scroll_plan.terminal_scroll_rows,
        &history,
        &row_text,
    );
    const seed_plan = testPaintPlanForFrame(
        seed_release.layout,
        seed_prepared.selection,
        seed_prepared.cursor.cursor_row,
        seed_prepared.cursor.cursor_col,
    );
    var seed_painter = PreparedTranscriptFramePainter{
        .runtime = &runtime,
        .alloc = alloc,
        .prepared = &seed_prepared,
    };
    const seed_result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = seed_plan,
            .scroll_plan = seed_transition.scroll_plan,
            .document_append = seed_transition.document_append,
            .body_painter = .{
                .ctx = &seed_painter,
                .paint = PreparedTranscriptFramePainter.paint,
            },
        },
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        seed_result.shadow_state,
    );
    try std.testing.expectEqual(
        seed_transition.scroll_plan.terminal_scroll_rows,
        seed_result.terminal_scroll_rows_committed,
    );
    try std.testing.expect(!seed_result.document_append_committed);
    runtime.ackPreservedRowReleaseAssumeValid(
        seed_transition.scroll_plan,
        seed_result.terminal_scroll_rows_committed,
    );
    runtime.consumeTranscriptTransition(alloc, &seed_transition, seed_result);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        runtime.transcriptCommitDiagnostic().state,
    );
    try std.testing.expectEqual(
        seed_transition.visual_offset,
        runtime.transcriptCommitDiagnostic().visual_offset,
    );
    try std.testing.expectEqual(
        growth_rows_u32 - seed_transition.scroll_plan.requested_inline_advance_rows,
        runtime.transcriptCommitDiagnostic().remaining_inline_rows,
    );

    var attempt_count: usize = 0;
    while (runtime.transcriptCommitDiagnostic().state == .recovering) : (attempt_count += 1) {
        var source = try testFoldedSource(
            alloc,
            grown_flow.items,
            runtime.layout.cols,
            1,
        );
        defer source.deinit(alloc);
        source.preview.natural_visual_rows =
            @intCast(@as(u32, viewport_rows) + growth_rows_u32);
        var prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
        defer if (prepared) |*paint| paint.deinit(alloc);
        const frame = try solveTestTranscriptFixedPointFrame(
            &runtime,
            alloc,
            &metrics,
            &source,
            8,
            &prepared,
        );
        const paint = &prepared.?;
        try std.testing.expectEqual(
            frame.layout.owned_top,
            frame.scroll_plan.post_scroll_owned_top,
        );
        try std.testing.expectEqual(
            viewport_rows,
            frame.scroll_plan.acceptedInlineRows(
                frame.scroll_plan.terminal_scroll_rows,
            ),
        );
        try appendGridRows(
            alloc,
            runtime.shadow_vt.?,
            1,
            frame.scroll_plan.terminal_scroll_rows,
            &history,
            &row_text,
        );

        var plan = testPaintPlanForFrame(
            frame.layout,
            paint.selection,
            paint.cursor.cursor_row,
            paint.cursor.cursor_col,
        );
        var transition = try resolveAndSealTranscriptTransitionForTest(
            &runtime,
            alloc,
            &source,
            paint,
            render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(frame.layout),
            &plan,
            frame.scroll_plan,
        );
        defer transition.deinit(alloc);
        try std.testing.expect(transition.document_append.isEmpty());
        try std.testing.expectEqual(
            @as(?usize, null),
            transition.materialized.flow_len,
        );
        try std.testing.expectEqual(
            viewport_rows,
            transition.materialized.visual_rows,
        );

        var painter = PreparedTranscriptFramePainter{
            .runtime = &runtime,
            .alloc = alloc,
            .prepared = paint,
        };
        const result = try render_engine.frame_builder.buildAndFlushFrame(
            alloc,
            &runtime,
            &metrics,
            .{
                .plan = plan,
                .scroll_plan = frame.scroll_plan,
                .document_append = transition.document_append,
                .body_painter = .{
                    .ctx = &painter,
                    .paint = PreparedTranscriptFramePainter.paint,
                },
            },
        );
        try std.testing.expectEqual(
            render_engine.terminal_diff.ShadowCommitState.committed,
            result.shadow_state,
        );
        try std.testing.expectEqual(
            frame.scroll_plan.terminal_scroll_rows,
            result.terminal_scroll_rows_committed,
        );
        runtime.ackPreservedRowReleaseAssumeValid(
            frame.scroll_plan,
            result.terminal_scroll_rows_committed,
        );
        runtime.consumeTranscriptTransition(alloc, &transition, result);
    }
    try std.testing.expectEqual(@as(usize, 1), attempt_count);

    const stable = runtime.stableTranscriptProjectionForFlow(grown_flow.items) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(growth_rows_u32, stable.visual_offset);
    try std.testing.expectEqual(@as(u16, 4), stable.cursor_row);
    try std.testing.expectEqual(@as(u16, 7), stable.cursor_col);
    try std.testing.expectEqual(runtime.shadow_vt.?.cursor_row, stable.cursor_row);
    try std.testing.expectEqual(runtime.shadow_vt.?.cursor_col, stable.cursor_col);

    const followup_rows: usize = 5;
    const followup_append = "\ng00008\ng00009\ng00010\ng00011\ng00012";
    var followup_flow: std.ArrayList(u8) = .empty;
    defer followup_flow.deinit(alloc);
    try followup_flow.appendSlice(alloc, grown_flow.items);
    try followup_flow.appendSlice(alloc, followup_append);
    var followup_source = try testFoldedSource(
        alloc,
        followup_flow.items,
        runtime.layout.cols,
        1,
    );
    defer followup_source.deinit(alloc);
    followup_source.preview.natural_visual_rows =
        @intCast(@as(usize, viewport_rows) + growth_rows + followup_rows);
    var followup_prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
    defer if (followup_prepared) |*paint| paint.deinit(alloc);
    const followup_frame = try solveTestTranscriptFixedPointFrame(
        &runtime,
        alloc,
        &metrics,
        &followup_source,
        4,
        &followup_prepared,
    );
    const followup_paint = &followup_prepared.?;
    try std.testing.expectEqual(
        followup_frame.layout.owned_top,
        followup_frame.scroll_plan.post_scroll_owned_top,
    );
    const followup_facts = runtime.planTranscriptScroll(followup_paint);
    try std.testing.expectEqual(@as(u32, 1), followup_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 1), followup_facts.planned_rows);
    try appendGridRows(
        alloc,
        runtime.shadow_vt.?,
        1,
        followup_frame.scroll_plan.terminal_scroll_rows,
        &history,
        &row_text,
    );
    var followup_plan = testPaintPlanForFrame(
        followup_frame.layout,
        followup_paint.selection,
        followup_paint.cursor.cursor_row,
        followup_paint.cursor.cursor_col,
    );
    var followup_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &followup_source,
        followup_paint,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(followup_frame.layout),
        &followup_plan,
        followup_frame.scroll_plan,
    );
    defer followup_transition.deinit(alloc);
    try expectDocumentWireEqualsLogical(
        alloc,
        followup_append,
        followup_transition.document_append.bytes,
    );
    try std.testing.expectEqual(
        followup_flow.items.len,
        followup_transition.materialized.flow_len.?,
    );
    try std.testing.expectEqual(@as(u16, 4), followup_transition.document_append.start_row);
    try std.testing.expectEqual(@as(u16, 7), followup_transition.document_append.start_col);

    var followup_painter = PreparedTranscriptFramePainter{
        .runtime = &runtime,
        .alloc = alloc,
        .prepared = followup_paint,
    };
    const followup_result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = followup_plan,
            .scroll_plan = followup_frame.scroll_plan,
            .document_append = followup_transition.document_append,
            .body_painter = .{
                .ctx = &followup_painter,
                .paint = PreparedTranscriptFramePainter.paint,
            },
        },
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        followup_result.shadow_state,
    );
    try std.testing.expect(followup_result.document_append_committed);
    try std.testing.expectEqual(
        @as(u16, 1),
        followup_result.terminal_scroll_rows_committed,
    );

    runtime.ackPreservedRowReleaseAssumeValid(
        followup_frame.scroll_plan,
        followup_result.terminal_scroll_rows_committed,
    );
    runtime.consumeTranscriptTransition(alloc, &followup_transition, followup_result);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );

    try appendGridRows(
        alloc,
        runtime.shadow_vt.?,
        followup_frame.layout.transcript_area.top,
        followup_frame.layout.transcript_area.height(),
        &history,
        &row_text,
    );
    const expected_history =
        "shell0\n" ++
        "shell1\n" ++
        "shell2\n" ++
        "shell3\n" ++
        "│ fold0\n" ++
        "│ fold1\n" ++
        "│ fold2\n" ++
        "│ fold3\n" ++
        "g00000\n" ++
        "g00001\n" ++
        "g00002\n" ++
        "g00003\n" ++
        "g00004\n" ++
        "g00005\n" ++
        "g00006\n" ++
        "g00007\n" ++
        "g00008\n" ++
        "g00009\n" ++
        "g00010\n" ++
        "g00011\n" ++
        "g00012";
    try std.testing.expectEqualStrings(expected_history, history.items);
    try std.testing.expect(std.mem.indexOf(u8, history.items, "\n\n") == null);

    fold_index = 0;
    while (fold_index < viewport_rows) : (fold_index += 1) {
        var expected_buf: [16]u8 = undefined;
        const expected = try std.fmt.bufPrint(
            &expected_buf,
            "│ fold{d}",
            .{fold_index},
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            countExactHistoryLine(history.items, expected),
        );
    }
    growth_index = 0;
    while (growth_index < growth_rows + followup_rows) : (growth_index += 1) {
        var expected_buf: [16]u8 = undefined;
        const expected = try std.fmt.bufPrint(
            &expected_buf,
            "g{d:0>5}",
            .{growth_index},
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            countExactHistoryLine(history.items, expected),
        );
    }
}

test "staged soft-wrapped presentation resumes across committed projections" {
    const alloc = std.testing.allocator;
    const cols: u16 = 8;
    const stable_flow = "base\n";
    const filler_row_count: usize = @as(usize, std.math.maxInt(u16)) - 3;
    const link_url = "https://staged.example";
    const link_params = "id=fx-42";
    const presentation_open =
        "\x1b[1;31m\x1b[9m" ++
        "\x1b]8;" ++ link_params ++ ";" ++ link_url ++ "\x1b\\";
    const presentation_close = "\x1b]8;;\x1b\\\x1b[29m\x1b[0m";
    const resume_bytes =
        "\x1b[0m\x1b[1m\x1b[9m\x1b[31m" ++
        "\x1b]8;" ++ link_params ++ ";" ++ link_url ++ "\x1b\\";
    const steady_bytes = "\x1b]8;;\x1b\\\x1b[0m\r";
    const linked_row_symbols = "0123456789A";

    var linked_text = try alloc.alloc(u8, linked_row_symbols.len * cols);
    defer alloc.free(linked_text);
    for (linked_row_symbols, 0..) |symbol, row| {
        @memset(linked_text[row * cols .. (row + 1) * cols], symbol);
    }

    var grown_flow: std.ArrayList(u8) = .empty;
    defer grown_flow.deinit(alloc);
    try grown_flow.ensureTotalCapacity(
        alloc,
        stable_flow.len +
            filler_row_count * "x\n".len +
            presentation_open.len +
            linked_text.len +
            presentation_close.len,
    );
    grown_flow.appendSliceAssumeCapacity(stable_flow);
    for (0..filler_row_count) |_| {
        grown_flow.appendSliceAssumeCapacity("x\n");
    }
    grown_flow.appendSliceAssumeCapacity(presentation_open);
    grown_flow.appendSliceAssumeCapacity(linked_text);
    grown_flow.appendSliceAssumeCapacity(presentation_close);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(
        std.testing.io,
        "staged-presentation.log",
        .{ .read = true },
    );
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = transcriptTestLayout(cols, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try runtime.shadow_vt.?.feed(stable_flow);

    var stable_source = try testSource(alloc, stable_flow, runtime.layout.cols);
    defer stable_source.deinit(alloc);
    var stable_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &stable_source,
    );
    defer stable_prepared.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        stable_flow,
        stable_prepared.selection,
        0,
        stable_prepared.cursor.cursor_row,
        stable_prepared.cursor.cursor_col,
        414,
    );

    var raw_append_bytes: std.ArrayList(u8) = .empty;
    defer raw_append_bytes.deinit(alloc);

    var first_source = try testSource(alloc, grown_flow.items, runtime.layout.cols);
    defer first_source.deinit(alloc);
    var first_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &first_source,
    );
    defer first_prepared.deinit(alloc);
    const first_facts = runtime.planTranscriptScroll(&first_prepared);
    try std.testing.expectEqual(
        @as(u16, std.math.maxInt(u16)),
        first_facts.planned_rows,
    );
    const first_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        first_facts.planned_rows,
    );
    var first_plan = testPaintPlan(&runtime, first_prepared.selection);
    var first_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &first_source,
        &first_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(first_plan),
        &first_plan,
        first_scroll_plan,
    );
    defer first_transition.deinit(alloc);

    const first_raw_end = first_transition.materialized.flow_len orelse
        return error.TestUnexpectedResult;
    const first_raw_append = grown_flow.items[stable_flow.len..first_raw_end];
    try std.testing.expect(first_raw_end < grown_flow.items.len);
    try std.testing.expect(std.mem.endsWith(
        u8,
        first_transition.document_append.bytes,
        steady_bytes,
    ));
    try expectDocumentWireEqualsLogical(
        alloc,
        first_raw_append,
        first_transition.document_append.bytes[0 .. first_transition.document_append.bytes.len - steady_bytes.len],
    );
    try raw_append_bytes.appendSlice(alloc, first_raw_append);

    var first_painter = PreparedTranscriptFramePainter{
        .runtime = &runtime,
        .alloc = alloc,
        .prepared = &first_prepared,
    };
    var metrics: Metrics = .{};
    const first_result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = first_plan,
            .scroll_plan = first_scroll_plan,
            .document_append = first_transition.document_append,
            .body_painter = .{
                .ctx = &first_painter,
                .paint = PreparedTranscriptFramePainter.paint,
            },
        },
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        first_result.shadow_state,
    );
    try std.testing.expect(runtime.shadow_vt.?.current_style.eql(.{}));
    try std.testing.expect(!runtime.shadow_vt.?.pending_wrap);

    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    for ("2345", 1..) |symbol, row| {
        row_text.clearRetainingCapacity();
        try runtime.shadow_vt.?.rowTextTrimmed(@intCast(row), &row_text);
        var expected_row: [cols]u8 = undefined;
        @memset(&expected_row, symbol);
        try std.testing.expectEqualStrings(&expected_row, row_text.items);
        const cell = runtime.shadow_vt.?.cellAt(@intCast(row), 1).?;
        try std.testing.expect(cell.style.flags.bold);
        try std.testing.expect(cell.style.flags.strike);
        try std.testing.expect(cell.style.fg.eql(.{ .indexed = 1 }));
        try std.testing.expect(cell.style.hyperlink_id != 0);
        try std.testing.expectEqualStrings(
            link_url,
            runtime.shadow_vt.?.hyperlinkUrl(cell.style.hyperlink_id).?,
        );
    }

    runtime.consumeTranscriptTransition(alloc, &first_transition, first_result);
    const after_first = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        after_first.state,
    );
    try std.testing.expect(after_first.remaining_inline_rows > 0);

    var retry_source = try testSource(alloc, grown_flow.items, runtime.layout.cols);
    defer retry_source.deinit(alloc);
    var retry_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &retry_source,
    );
    defer retry_prepared.deinit(alloc);
    const retry_facts = runtime.planTranscriptScroll(&retry_prepared);
    const retry_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        retry_facts.planned_rows,
    );
    var retry_plan = testPaintPlan(&runtime, retry_prepared.selection);
    var retry_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &retry_source,
        &retry_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(retry_plan),
        &retry_plan,
        retry_scroll_plan,
    );
    defer retry_transition.deinit(alloc);

    const retry_raw_append = grown_flow.items[first_raw_end..];
    try std.testing.expect(std.mem.startsWith(
        u8,
        retry_transition.document_append.bytes,
        resume_bytes,
    ));
    try expectDocumentWireEqualsLogical(
        alloc,
        retry_raw_append,
        retry_transition.document_append.bytes[resume_bytes.len..],
    );
    try raw_append_bytes.appendSlice(alloc, retry_raw_append);
    try std.testing.expectEqualStrings(
        grown_flow.items[stable_flow.len..],
        raw_append_bytes.items,
    );

    var retry_painter = PreparedTranscriptFramePainter{
        .runtime = &runtime,
        .alloc = alloc,
        .prepared = &retry_prepared,
    };
    const retry_result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = retry_plan,
            .scroll_plan = retry_scroll_plan,
            .document_append = retry_transition.document_append,
            .body_painter = .{
                .ctx = &retry_painter,
                .paint = PreparedTranscriptFramePainter.paint,
            },
        },
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        retry_result.shadow_state,
    );
    try std.testing.expect(runtime.shadow_vt.?.current_style.eql(.{}));
    try std.testing.expect(!runtime.shadow_vt.?.pending_wrap);

    for ("789A", 1..) |symbol, row| {
        row_text.clearRetainingCapacity();
        try runtime.shadow_vt.?.rowTextTrimmed(@intCast(row), &row_text);
        var expected_row: [cols]u8 = undefined;
        @memset(&expected_row, symbol);
        try std.testing.expectEqualStrings(&expected_row, row_text.items);
        const cell = runtime.shadow_vt.?.cellAt(@intCast(row), 1).?;
        try std.testing.expect(cell.style.flags.bold);
        try std.testing.expect(cell.style.flags.strike);
        try std.testing.expect(cell.style.fg.eql(.{ .indexed = 1 }));
        try std.testing.expect(cell.style.hyperlink_id != 0);
        try std.testing.expectEqualStrings(
            link_url,
            runtime.shadow_vt.?.hyperlinkUrl(cell.style.hyperlink_id).?,
        );
    }

    runtime.consumeTranscriptTransition(alloc, &retry_transition, retry_result);
    const stable = runtime.stableTranscriptProjectionForFlow(grown_flow.items) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(retry_facts.target_visual_offset, stable.visual_offset);
    try std.testing.expectEqual(
        @as(?usize, grown_flow.items.len),
        retry_transition.materialized.flow_len,
    );
}

test "uncommitted stable-origin append retries from the materialized source endpoint" {
    const alloc = std.testing.allocator;
    const stable_flow = "base\n";
    const grown_flow = stable_flow ++ "0\n1\n2\n3\n4";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var stable_source = try testSource(alloc, stable_flow, runtime.layout.cols);
    defer stable_source.deinit(alloc);
    var stable_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &stable_source,
    );
    defer stable_prepared.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        stable_flow,
        stable_prepared.selection,
        0,
        stable_prepared.cursor.cursor_row,
        stable_prepared.cursor.cursor_col,
        413,
    );

    var first_source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer first_source.deinit(alloc);
    var first_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &first_source,
    );
    defer first_prepared.deinit(alloc);
    const first_facts = runtime.planTranscriptScroll(&first_prepared);
    const first_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        first_facts.planned_rows,
    );
    var first_plan = testPaintPlan(&runtime, first_prepared.selection);
    var first_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &first_source,
        &first_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(first_plan),
        &first_plan,
        first_scroll_plan,
    );
    defer first_transition.deinit(alloc);
    try expectDocumentWireEqualsLogical(
        alloc,
        grown_flow[stable_flow.len..],
        first_transition.document_append.bytes,
    );

    runtime.consumeTranscriptTransition(alloc, &first_transition, .{
        .bytes_written = 1,
        .changed_cells = 0,
        .full_repaint = false,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = stable_prepared.cursor.cursor_row,
        .committed_cursor_col = stable_prepared.cursor.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    var retry_source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer retry_source.deinit(alloc);
    var retry_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &retry_source,
    );
    defer retry_prepared.deinit(alloc);
    const retry_facts = runtime.planTranscriptScroll(&retry_prepared);
    const retry_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        retry_facts.planned_rows,
    );
    var retry_plan = testPaintPlan(&runtime, retry_prepared.selection);
    var retry_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &retry_source,
        &retry_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(retry_plan),
        &retry_plan,
        retry_scroll_plan,
    );
    defer retry_transition.deinit(alloc);
    try expectDocumentWireEqualsLogical(
        alloc,
        grown_flow[stable_flow.len..],
        retry_transition.document_append.bytes,
    );
}

test "staged wrapped projection clips paint and flow at one renderer boundary" {
    const alloc = std.testing.allocator;
    const flow = "base\nabcdefghijklmnopqrst";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(5, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &source,
    );
    defer prepared.deinit(alloc);
    const projection = try transcript_painter.stagePreparedTranscriptForVisualOffset(
        alloc,
        runtime.layout,
        &prepared,
        .{ .top = 1, .bottom = 2 },
        2,
    );
    try std.testing.expectEqual(@as(?usize, "base\n".len + 15), projection.flow_end);
    try std.testing.expectEqual(@as(usize, 1), prepared.selection.start_line);
    try std.testing.expectEqual(@as(u16, 1), prepared.selection.partial_skip_rows);
    try std.testing.expectEqual(@as(u16, 3), prepared.cursor.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), prepared.cursor.cursor_col);

    var shadow = try vt_emulator.Grid.init(
        alloc,
        runtime.layout.cols,
        runtime.layout.rows,
    );
    defer shadow.deinit();
    var plan = testPaintPlan(&runtime, prepared.selection);
    plan.viewport = prepared.selection;
    var surface = try render_engine.frame_surface.FrameSurface.initFromShadow(
        alloc,
        plan,
        shadow,
    );
    defer surface.deinit();
    _ = try runtime.paintPreparedTranscriptIntoSurface(
        alloc,
        &surface,
        &prepared,
    );
    var target = try surface.copyToTargetGrid(alloc);
    defer target.deinit();
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    try target.rowTextTrimmed(1, &row_text);
    try std.testing.expectEqualStrings("fghij", row_text.items);
    row_text.clearRetainingCapacity();
    try target.rowTextTrimmed(2, &row_text);
    try std.testing.expectEqualStrings("klmno", row_text.items);
    try std.testing.expectEqual(@as(u16, 3), target.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), target.cursor_col);
}

test "width change does not compare semantic offsets across projections" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try installStableAnchorForTest(&runtime, alloc, "stable", testSelection(4), 4, 3, 1, 42);
    runtime.layout = transcriptTestLayout(10, 8, 4);

    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = try alloc.dupe(u8, "stable"),
        .selection = testSelection(9),
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, &([_]u16{1} ** 16));

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expectEqual(@as(u16, 0), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), facts.planned_rows);
}

test "stable origin projection rebase narrow to wide survives repeated partial and restores append" {
    const alloc = std.testing.allocator;
    const flow =
        "abcdefghijklmnopqrstuvwxyz0123456789\n" ++
        "one\n" ++
        "two\n" ++
        "three\n" ++
        "four\n" ++
        "five\n";
    const grown_flow = flow ++ "six\nseven\neight\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(5, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var stable_source = try testSource(alloc, flow, runtime.layout.cols);
    defer stable_source.deinit(alloc);
    var stable_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &stable_source,
    );
    defer stable_prepared.deinit(alloc);
    const narrow_offset = preparedVisualOffsetForTest(&stable_prepared);
    try std.testing.expect(narrow_offset > 0);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        flow,
        stable_prepared.selection,
        narrow_offset,
        stable_prepared.cursor.cursor_row,
        stable_prepared.cursor.cursor_col,
        420,
    );

    runtime.layout = transcriptTestLayout(20, 8, 4);
    var first_source = try testSource(alloc, flow, runtime.layout.cols);
    defer first_source.deinit(alloc);
    var first_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &first_source,
    );
    defer first_prepared.deinit(alloc);
    const wide_offset = preparedVisualOffsetForTest(&first_prepared);
    try std.testing.expect(wide_offset < narrow_offset);

    const first_facts = runtime.planTranscriptScroll(&first_prepared);
    try std.testing.expect(first_facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 0), first_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), first_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), first_facts.planned_rows);
    const first_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        first_facts.planned_rows,
    );
    var first_plan = testPaintPlan(&runtime, first_prepared.selection);
    var first_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &first_source,
        &first_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(first_plan),
        &first_plan,
        first_scroll_plan,
    );
    defer first_transition.deinit(alloc);
    try std.testing.expect(first_transition.recovery_rebase);
    try std.testing.expect(first_transition.document_append.isEmpty());

    runtime.consumeTranscriptTransition(alloc, &first_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = first_transition.cursor_row,
        .committed_cursor_col = first_transition.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    var recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(wide_offset, recovery.visual_offset);
    try std.testing.expectEqual(@as(u16, 0), recovery.remaining_inline_rows);
    try std.testing.expect(runtime.stableTranscriptProjectionForFlow(flow) == null);

    var repeated_source = try testSource(alloc, flow, runtime.layout.cols);
    defer repeated_source.deinit(alloc);
    var repeated_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &repeated_source,
    );
    defer repeated_prepared.deinit(alloc);
    const repeated_facts = runtime.planTranscriptScroll(&repeated_prepared);
    try std.testing.expect(repeated_facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 0), repeated_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), repeated_facts.planned_rows);
    const repeated_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        repeated_facts.planned_rows,
    );
    var repeated_plan = testPaintPlan(&runtime, repeated_prepared.selection);
    var repeated_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &repeated_source,
        &repeated_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(repeated_plan),
        &repeated_plan,
        repeated_scroll_plan,
    );
    defer repeated_transition.deinit(alloc);
    try std.testing.expect(repeated_transition.document_append.isEmpty());
    runtime.consumeTranscriptTransition(alloc, &repeated_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = repeated_transition.cursor_row,
        .committed_cursor_col = repeated_transition.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(wide_offset, recovery.visual_offset);

    var complete_source = try testSource(alloc, flow, runtime.layout.cols);
    defer complete_source.deinit(alloc);
    var complete_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &complete_source,
    );
    defer complete_prepared.deinit(alloc);
    const complete_facts = runtime.planTranscriptScroll(&complete_prepared);
    try std.testing.expect(complete_facts.recovery_rebase);
    const complete_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        complete_facts.planned_rows,
    );
    var complete_plan = testPaintPlan(&runtime, complete_prepared.selection);
    var complete_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &complete_source,
        &complete_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(complete_plan),
        &complete_plan,
        complete_scroll_plan,
    );
    defer complete_transition.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &complete_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = complete_scroll_plan.terminal_scroll_rows,
        .document_append_committed = false,
        .committed_cursor_row = complete_transition.cursor_row,
        .committed_cursor_col = complete_transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    const stable = runtime.stableTranscriptProjectionForFlow(flow) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(wide_offset, stable.visual_offset);

    var append_source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer append_source.deinit(alloc);
    var append_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &append_source,
    );
    defer append_prepared.deinit(alloc);
    const append_facts = runtime.planTranscriptScroll(&append_prepared);
    try std.testing.expect(!append_facts.recovery_rebase);
    try std.testing.expect(append_facts.semantic_rows > 0);
    const append_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        append_facts.planned_rows,
    );
    var append_plan = testPaintPlan(&runtime, append_prepared.selection);
    var append_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &append_source,
        &append_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(append_plan),
        &append_plan,
        append_scroll_plan,
    );
    defer append_transition.deinit(alloc);
    try expectDocumentWireEqualsLogical(
        alloc,
        grown_flow[flow.len..],
        append_transition.document_append.bytes,
    );
}

test "stable origin projection rebase wide to narrow retains debt until exhausted" {
    const alloc = std.testing.allocator;
    const flow = "stable\nbase\n";
    const grown_flow = flow ++ "next\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try enterResizeReflowRecovery(
        &runtime,
        alloc,
        null,
        .terminal_partial_write,
    );

    var repeated_source = try testSource(alloc, flow, runtime.layout.cols);
    defer repeated_source.deinit(alloc);
    var repeated_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &repeated_source,
    );
    defer repeated_prepared.deinit(alloc);
    const repeated_facts = runtime.planTranscriptScroll(&repeated_prepared);
    try std.testing.expect(repeated_facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 1), repeated_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), repeated_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 1), repeated_facts.planned_rows);
    const repeated_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        repeated_facts.planned_rows,
    );
    var repeated_plan = testPaintPlan(&runtime, repeated_prepared.selection);
    var repeated_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &repeated_source,
        &repeated_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(repeated_plan),
        &repeated_plan,
        repeated_scroll_plan,
    );
    defer repeated_transition.deinit(alloc);
    try std.testing.expect(repeated_transition.document_append.isEmpty());
    runtime.consumeTranscriptTransition(alloc, &repeated_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = repeated_transition.cursor_row,
        .committed_cursor_col = repeated_transition.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    var recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u16, 1), recovery.remaining_inline_rows);
    try std.testing.expect(runtime.stableTranscriptProjectionForFlow(flow) == null);

    var complete_source = try testSource(alloc, flow, runtime.layout.cols);
    defer complete_source.deinit(alloc);
    var complete_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &complete_source,
    );
    defer complete_prepared.deinit(alloc);
    const complete_facts = runtime.planTranscriptScroll(&complete_prepared);
    try std.testing.expect(complete_facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 1), complete_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 1), complete_facts.planned_rows);
    const complete_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        complete_facts.planned_rows,
    );
    var complete_plan = testPaintPlan(&runtime, complete_prepared.selection);
    var complete_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &complete_source,
        &complete_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(complete_plan),
        &complete_plan,
        complete_scroll_plan,
    );
    defer complete_transition.deinit(alloc);
    try std.testing.expect(complete_transition.document_append.isEmpty());
    runtime.consumeTranscriptTransition(alloc, &complete_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = complete_scroll_plan.terminal_scroll_rows,
        .document_append_committed = false,
        .committed_cursor_row = complete_transition.cursor_row,
        .committed_cursor_col = complete_transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u16, 0), recovery.remaining_inline_rows);

    var append_source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer append_source.deinit(alloc);
    var append_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &append_source,
    );
    defer append_prepared.deinit(alloc);
    const append_facts = runtime.planTranscriptScroll(&append_prepared);
    try std.testing.expect(!append_facts.recovery_rebase);
    try std.testing.expect(append_facts.semantic_rows > 0);
    const append_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        append_facts.planned_rows,
    );
    var append_plan = testPaintPlan(&runtime, append_prepared.selection);
    var append_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &append_source,
        &append_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(append_plan),
        &append_plan,
        append_scroll_plan,
    );
    defer append_transition.deinit(alloc);
    try expectDocumentWireEqualsLogical(
        alloc,
        grown_flow[flow.len..],
        append_transition.document_append.bytes,
    );
}

test "stable origin projection rebase measured history is not semantic debt" {
    const alloc = std.testing.allocator;
    const flow = "0\n1\n2\n3\n4\n5\n6\n7";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 10, 6),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var stable_source = try testSource(alloc, flow, runtime.layout.cols);
    defer stable_source.deinit(alloc);
    var stable_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &stable_source,
    );
    defer stable_prepared.deinit(alloc);
    const stable_offset = preparedVisualOffsetForTest(&stable_prepared);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        flow,
        stable_prepared.selection,
        stable_offset,
        stable_prepared.cursor.cursor_row,
        stable_prepared.cursor.cursor_col,
        421,
    );

    runtime.layout = transcriptTestLayout(20, 8, 4);
    runtime.resize_history_row_delta = 2;
    var first_source = try testSource(alloc, flow, runtime.layout.cols);
    defer first_source.deinit(alloc);
    var first_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &first_source,
    );
    defer first_prepared.deinit(alloc);
    const measured_offset = preparedVisualOffsetForTest(&first_prepared);
    try std.testing.expect(measured_offset > stable_offset);

    const first_facts = runtime.planTranscriptScroll(&first_prepared);
    try std.testing.expect(first_facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 0), first_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), first_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), first_facts.planned_rows);
    const first_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        first_facts.planned_rows,
    );
    var first_plan = testPaintPlan(&runtime, first_prepared.selection);
    var first_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &first_source,
        &first_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(first_plan),
        &first_plan,
        first_scroll_plan,
    );
    defer first_transition.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &first_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = first_transition.cursor_row,
        .committed_cursor_col = first_transition.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        runtime.transcriptCommitDiagnostic().state,
    );
    try std.testing.expect(runtime.stableTranscriptProjectionForFlow(flow) == null);

    var repeated_source = try testSource(alloc, flow, runtime.layout.cols);
    defer repeated_source.deinit(alloc);
    var repeated_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &repeated_source,
    );
    defer repeated_prepared.deinit(alloc);
    const repeated_facts = runtime.planTranscriptScroll(&repeated_prepared);
    try std.testing.expect(repeated_facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 0), repeated_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), repeated_facts.planned_rows);
    const repeated_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        repeated_facts.planned_rows,
    );
    var repeated_plan = testPaintPlan(&runtime, repeated_prepared.selection);
    var repeated_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &repeated_source,
        &repeated_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(repeated_plan),
        &repeated_plan,
        repeated_scroll_plan,
    );
    defer repeated_transition.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &repeated_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = repeated_scroll_plan.terminal_scroll_rows,
        .document_append_committed = false,
        .committed_cursor_row = repeated_transition.cursor_row,
        .committed_cursor_col = repeated_transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    runtime.resize_history_row_delta = null;

    const projection = runtime.stableTranscriptProjectionForFlow(flow) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(measured_offset, projection.visual_offset);
}

test "overlay frame retains an exact-end measured history floor after reset" {
    const alloc = std.testing.allocator;
    const flow = "0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 40, 36),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &source,
    );
    defer prepared.deinit(alloc);

    var history_offset: u32 = 0;
    for (prepared.sourceVisualRows()) |rows| history_offset += rows;
    var history_selection = prepared.selection;
    history_selection.start_line = prepared.sourceVisualRows().len;
    history_selection.partial_skip_rows = 0;
    history_selection.last_visible_row = 1;

    var plan = testPaintPlan(&runtime, prepared.selection);
    plan.activity = .{ .overlay_entry = 1 };
    const committed_layout =
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    runtime.committed_frame_layout = committed_layout;
    try installStableAnchorForTest(
        &runtime,
        alloc,
        flow,
        history_selection,
        history_offset,
        1,
        1,
        committed_layout.layout_id,
    );

    const facts = runtime.planTranscriptScroll(&prepared);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        committed_layout,
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    try std.testing.expectEqual(history_offset, transition.visual_offset);
    try std.testing.expectEqual(
        prepared.sourceVisualRows().len,
        transition.selection.start_line,
    );
}

test "zero measured reverse restores exact source origin" {
    const alloc = std.testing.allocator;
    const flow =
        "line 00 abcdefghij\n" ++
        "line 01 abcdefghij\n" ++
        "line 02 abcdefghij\n" ++
        "line 03 abcdefghij\n" ++
        "line 04 abcdefghij\n" ++
        "line 05 abcdefghij\n" ++
        "line 06 abcdefghij\n" ++
        "line 07 abcdefghij\n" ++
        "line 08 abcdefghij\n" ++
        "line 09 abcdefghij\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    var wide_source = try testSource(alloc, flow, runtime.layout.cols);
    defer wide_source.deinit(alloc);
    var narrow_source = try testSource(alloc, flow, 12);
    defer narrow_source.deinit(alloc);

    try expectZeroReverseRestoresSourceOrigin(
        &runtime,
        alloc,
        &wide_source,
        &narrow_source,
        2,
        .seeded_exact,
    );
}

test "zero measured reverse restores folded source origin without endpoint" {
    const alloc = std.testing.allocator;
    const flow =
        "head abcdefghij\n" ++
        "summary\n" ++
        "tail 00 abcdefghij\n" ++
        "tail 01 abcdefghij\n" ++
        "tail 02 abcdefghij\n" ++
        "tail 03 abcdefghij\n" ++
        "tail 04 abcdefghij\n" ++
        "tail 05 abcdefghij\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 12, 8),
        .owned_top_row = 1,
        .full_transcript = .{ .depth = .full },
    };
    defer runtime.deinit(alloc);
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_transcript_index = 2,
    });
    try appendFoldedLineForTest(&runtime, alloc, 0, "folded output alpha");
    try appendFoldedLineForTest(&runtime, alloc, 0, "folded output beta");

    var wide_source = try testFoldedSource(alloc, flow, runtime.layout.cols, 2);
    defer wide_source.deinit(alloc);
    var narrow_source = try testFoldedSource(alloc, flow, 12, 2);
    defer narrow_source.deinit(alloc);

    try expectZeroReverseRestoresSourceOrigin(
        &runtime,
        alloc,
        &wide_source,
        &narrow_source,
        2,
        .natural_null,
    );
}

test "zero measured reverse restores folded source origin with inexact endpoint mapping" {
    const alloc = std.testing.allocator;
    const flow =
        "head abcdefghij\n" ++
        "summary\n" ++
        "tail 00 abcdefghij\n" ++
        "tail 01 abcdefghij\n" ++
        "tail 02 abcdefghij\n" ++
        "tail 03 abcdefghij\n" ++
        "tail 04 abcdefghij\n" ++
        "tail 05 abcdefghij\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 12, 8),
        .owned_top_row = 1,
        .full_transcript = .{ .depth = .full },
    };
    defer runtime.deinit(alloc);
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_transcript_index = 2,
    });
    try appendFoldedLineForTest(&runtime, alloc, 0, "folded output alpha");
    try appendFoldedLineForTest(&runtime, alloc, 0, "folded output beta");

    var wide_source = try testFoldedSource(alloc, flow, runtime.layout.cols, 2);
    defer wide_source.deinit(alloc);
    var narrow_source = try testFoldedSource(alloc, flow, 12, 2);
    defer narrow_source.deinit(alloc);

    try expectZeroReverseRestoresSourceOrigin(
        &runtime,
        alloc,
        &wide_source,
        &narrow_source,
        2,
        .seeded_inexact,
    );
}

test "measured history origin matrix restores hard soft wide and folded sources" {
    const alloc = std.testing.allocator;
    const Case = struct {
        source_cols: u16,
        target_cols: u16,
        positive_delta: i32,
        flow: []const u8,
        folded: bool = false,
        endpoint_mode: MeasuredEndpointMode,
    };
    const cases = [_]Case{
        .{
            .source_cols = 24,
            .target_cols = 12,
            .positive_delta = 2,
            .flow = "hard 00\nhard 01\nhard 02\nhard 03\nhard 04\nhard 05\n" ++
                "hard 06\nhard 07\nhard 08\nhard 09\nhard 10\nhard 11\n",
            .endpoint_mode = .seeded_exact,
        },
        .{
            .source_cols = 20,
            .target_cols = 8,
            .positive_delta = 3,
            .flow = "soft-wrap-alpha-000\nsoft-wrap-beta-001\nsoft-wrap-gamma-002\n" ++
                "soft-wrap-delta-003\nsoft-wrap-epsilon-004\nsoft-wrap-zeta-005\n" ++
                "soft-wrap-eta-006\nsoft-wrap-theta-007\nsoft-wrap-iota-008\n" ++
                "soft-wrap-kappa-009\n",
            .endpoint_mode = .seeded_exact,
        },
        .{
            .source_cols = 16,
            .target_cols = 8,
            .positive_delta = 2,
            .flow = "wide 界界 00\nwide 界界 01\nwide 界界 02\nwide 界界 03\n" ++
                "wide 界界 04\nwide 界界 05\nwide 界界 06\nwide 界界 07\n" ++
                "wide 界界 08\nwide 界界 09\nwide 界界 10\nwide 界界 11\n",
            .endpoint_mode = .seeded_exact,
        },
        .{
            .source_cols = 24,
            .target_cols = 12,
            .positive_delta = 2,
            .flow = "head abcdefghij\nsummary\ntail 00 abcdefghij\n" ++
                "tail 01 abcdefghij\ntail 02 abcdefghij\ntail 03 abcdefghij\n" ++
                "tail 04 abcdefghij\ntail 05 abcdefghij\n",
            .folded = true,
            .endpoint_mode = .natural_null,
        },
        .{
            .source_cols = 30,
            .target_cols = 10,
            .positive_delta = 3,
            .flow = "head abcdefghij\nsummary\ntail 00 abcdefghij\n" ++
                "tail 01 abcdefghij\ntail 02 abcdefghij\ntail 03 abcdefghij\n" ++
                "tail 04 abcdefghij\ntail 05 abcdefghij\n",
            .folded = true,
            .endpoint_mode = .seeded_inexact,
        },
    };

    for (cases) |case| {
        var runtime = TranscriptRuntime{
            .layout = transcriptTestLayout(case.source_cols, 12, 8),
            .owned_top_row = 1,
            .full_transcript = .{ .depth = if (case.folded) .full else .inline_mode },
        };
        defer runtime.deinit(alloc);
        if (case.folded) {
            try runtime.folded_command_blocks.append(alloc, .{
                .summary_transcript_index = 2,
            });
            try appendFoldedLineForTest(&runtime, alloc, 0, "folded output alpha");
            try appendFoldedLineForTest(&runtime, alloc, 0, "folded output beta");
        }

        var wide_source = if (case.folded)
            try testFoldedSource(alloc, case.flow, case.source_cols, 2)
        else
            try testSource(alloc, case.flow, case.source_cols);
        defer wide_source.deinit(alloc);
        var narrow_source = if (case.folded)
            try testFoldedSource(alloc, case.flow, case.target_cols, 2)
        else
            try testSource(alloc, case.flow, case.target_cols);
        defer narrow_source.deinit(alloc);

        try expectZeroReverseRestoresSourceOrigin(
            &runtime,
            alloc,
            &wide_source,
            &narrow_source,
            case.positive_delta,
            case.endpoint_mode,
        );
    }
}

test "positive measured shrink retains split source origin without exact endpoint" {
    const alloc = std.testing.allocator;
    const flow =
        "line 00 abcdefghij\n" ++
        "line 01 abcdefghij\n" ++
        "line 02 abcdefghij\n" ++
        "line 03 abcdefghij\n" ++
        "line 04 abcdefghij\n" ++
        "line 05 abcdefghij\n" ++
        "line 06 abcdefghij\n" ++
        "line 07 abcdefghij\n" ++
        "line 08 abcdefghij\n" ++
        "line 09 abcdefghij\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    var wide_source = try testSource(alloc, flow, runtime.layout.cols);
    defer wide_source.deinit(alloc);
    var wide_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &wide_source,
    );
    defer wide_prepared.deinit(alloc);
    var split_selection = wide_prepared.selection;
    split_selection.split_active = true;
    split_selection.split_prefix_lines = 1;
    split_selection.split_suffix_start_line = split_selection.start_line;
    const source_origin = preparedVisualOffsetForTest(&wide_prepared);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        flow,
        split_selection,
        source_origin,
        wide_prepared.cursor.cursor_row,
        wide_prepared.cursor.cursor_col,
        705,
    );

    runtime.layout = transcriptTestLayout(12, 8, 4);
    runtime.resize_history_row_delta = 2;
    var narrow_source = try testSource(alloc, flow, runtime.layout.cols);
    defer narrow_source.deinit(alloc);
    var narrow_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &narrow_source,
    );
    defer narrow_prepared.deinit(alloc);
    const origin = narrow_prepared.measured_history_origin orelse
        return error.TestExpectedMeasuredHistoryOrigin;
    try std.testing.expectEqual(@as(u16, 24), origin.source_cols);
    try std.testing.expectEqual(source_origin, origin.source_visual_offset);
    try std.testing.expect(origin.endpoint == null);
}

test "zero measured history controls do not consume a nonqualifying origin" {
    const alloc = std.testing.allocator;
    const flow =
        "line 00 abcdefghij\n" ++
        "line 01 abcdefghij\n" ++
        "line 02 abcdefghij\n" ++
        "line 03 abcdefghij\n" ++
        "line 04 abcdefghij\n" ++
        "line 05 abcdefghij\n";

    {
        var runtime = TranscriptRuntime{
            .layout = transcriptTestLayout(12, 8, 4),
            .owned_top_row = 1,
        };
        defer runtime.deinit(alloc);
        var source = try testSource(alloc, flow, runtime.layout.cols);
        defer source.deinit(alloc);
        var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
        defer prepared.deinit(alloc);
        const offset = preparedVisualOffsetForTest(&prepared);
        try installStableAnchorForTest(
            &runtime,
            alloc,
            flow,
            prepared.selection,
            offset,
            prepared.cursor.cursor_row,
            prepared.cursor.cursor_col,
            706,
        );
        runtime.resize_history_row_delta = 0;
        var generic_zero = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
        defer generic_zero.deinit(alloc);
        try std.testing.expectEqual(offset, preparedVisualOffsetForTest(&generic_zero));
        try std.testing.expect(!generic_zero.measured_history_origin_consumed);
    }

    {
        var runtime = TranscriptRuntime{
            .layout = transcriptTestLayout(12, 8, 4),
            .owned_top_row = 1,
        };
        defer runtime.deinit(alloc);
        var narrow_source = try testSource(alloc, flow, runtime.layout.cols);
        defer narrow_source.deinit(alloc);
        var narrow_prepared = try prepareTestSourceForCurrentArea(
            &runtime,
            alloc,
            &narrow_source,
        );
        defer narrow_prepared.deinit(alloc);
        const narrow_offset = preparedVisualOffsetForTest(&narrow_prepared);
        try installStableAnchorWithOriginForTest(
            &runtime,
            alloc,
            flow,
            narrow_prepared.selection,
            narrow_offset,
            narrow_prepared.cursor.cursor_row,
            narrow_prepared.cursor.cursor_col,
            707,
            .{
                .source_cols = 24,
                .source_visual_offset = 1,
            },
        );

        runtime.resize_history_row_delta = 0;
        var same_width = try prepareTestSourceForCurrentArea(
            &runtime,
            alloc,
            &narrow_source,
        );
        defer same_width.deinit(alloc);
        try std.testing.expectEqual(
            narrow_offset,
            preparedVisualOffsetForTest(&same_width),
        );
        try std.testing.expect(!same_width.measured_history_origin_consumed);

        runtime.layout = transcriptTestLayout(18, 10, 6);
        var middle_source = try testSource(alloc, flow, runtime.layout.cols);
        defer middle_source.deinit(alloc);
        var non_source_width = try prepareTestSourceForCurrentArea(
            &runtime,
            alloc,
            &middle_source,
        );
        defer non_source_width.deinit(alloc);
        try std.testing.expect(!non_source_width.measured_history_origin_consumed);
    }
}

test "negative measured rewind consumes the retained exact origin" {
    const alloc = std.testing.allocator;
    const flow =
        "abcdefghijklmnopqrst\n" ++
        "abcdefghijklmnopqrst\n" ++
        "abcdefghijklmnopqrst\n" ++
        "abcdefghijklmnopqrst\n" ++
        "abcdefghijklmnopqrst\n" ++
        "abcdefghijklmnopqrst\n" ++
        "abcdefghijklmnopqrst\n" ++
        "abcdefghijklmnopqrst\n" ++
        "abcdefghijklmnopqrst\n" ++
        "abcdefghijklmnopqrst\n" ++
        "abcdefghijklmnopqrst\n" ++
        "abcdefghijklmnopqrst\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    var wide_source = try testSource(alloc, flow, runtime.layout.cols);
    defer wide_source.deinit(alloc);
    var wide_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &wide_source,
    );
    defer wide_prepared.deinit(alloc);
    try setPreparedVisualOffsetForTest(&wide_prepared, 10);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        flow,
        wide_prepared.selection,
        10,
        wide_prepared.cursor.cursor_row,
        wide_prepared.cursor.cursor_col,
        708,
    );

    runtime.layout = transcriptTestLayout(12, 8, 4);
    runtime.resize_history_row_delta = 2;
    var narrow_source = try testSource(alloc, flow, runtime.layout.cols);
    defer narrow_source.deinit(alloc);
    var narrow_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &narrow_source,
    );
    defer narrow_prepared.deinit(alloc);
    const origin = narrow_prepared.measured_history_origin orelse
        return error.TestExpectedMeasuredHistoryOrigin;
    narrow_prepared.measured_history_origin = .{
        .source_cols = origin.source_cols,
        .source_visual_offset = origin.source_visual_offset,
        .endpoint = .{
            .span_start_flow_offset = 210,
            .flow_offset = 231,
            .hard_row_cols = 24,
        },
    };
    try std.testing.expectEqual(@as(u32, 22), preparedVisualOffsetForTest(&narrow_prepared));
    try commitPreparedForTest(&runtime, alloc, &narrow_source, &narrow_prepared);

    runtime.layout = transcriptTestLayout(18, 10, 6);
    runtime.resize_history_row_delta = -1;
    var rewind_source = try testSource(alloc, flow, runtime.layout.cols);
    defer rewind_source.deinit(alloc);
    var rewound = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &rewind_source,
    );
    defer rewound.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 21), preparedVisualOffsetForTest(&rewound));
    try std.testing.expect(rewound.measured_history_origin_consumed);
    try commitPreparedForTest(&runtime, alloc, &rewind_source, &rewound);
    const stable = runtime.stableTranscriptProjectionForFlow(flow) orelse
        return error.TestExpectedStableTranscript;
    try std.testing.expect(stable.measured_history_origin == null);
}

test "incompatible transcript replacement clears the retained origin" {
    const alloc = std.testing.allocator;
    const flow = "stable 0\nstable 1\nstable 2\nstable 3\nstable 4\nstable 5\n";
    const replacement =
        "replacement 0\nreplacement 1\nreplacement 2\nreplacement 3\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(12, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    var stable_source = try testSource(alloc, flow, runtime.layout.cols);
    defer stable_source.deinit(alloc);
    var stable_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &stable_source,
    );
    defer stable_prepared.deinit(alloc);
    try installStableAnchorWithOriginForTest(
        &runtime,
        alloc,
        flow,
        stable_prepared.selection,
        preparedVisualOffsetForTest(&stable_prepared),
        stable_prepared.cursor.cursor_row,
        stable_prepared.cursor.cursor_col,
        709,
        .{
            .source_cols = 24,
            .source_visual_offset = 2,
        },
    );

    var replacement_source = try testSource(
        alloc,
        replacement,
        runtime.layout.cols,
    );
    defer replacement_source.deinit(alloc);
    var replacement_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &replacement_source,
    );
    defer replacement_prepared.deinit(alloc);
    try commitPreparedForTest(
        &runtime,
        alloc,
        &replacement_source,
        &replacement_prepared,
    );
    const stable = runtime.stableTranscriptProjectionForFlow(replacement) orelse
        return error.TestExpectedStableTranscript;
    try std.testing.expect(stable.measured_history_origin == null);
}

test "zero measured reverse restores source origin from recovery receipt" {
    const alloc = std.testing.allocator;
    const flow =
        "line 00 abcdefghij\n" ++
        "line 01 abcdefghij\n" ++
        "line 02 abcdefghij\n" ++
        "line 03 abcdefghij\n" ++
        "line 04 abcdefghij\n" ++
        "line 05 abcdefghij\n" ++
        "line 06 abcdefghij\n" ++
        "line 07 abcdefghij\n" ++
        "line 08 abcdefghij\n" ++
        "line 09 abcdefghij\n" ++
        "line 10 abcdefghij\n" ++
        "line 11 abcdefghij\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var wide_source = try testSource(alloc, flow, runtime.layout.cols);
    defer wide_source.deinit(alloc);
    var wide_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &wide_source,
    );
    defer wide_prepared.deinit(alloc);
    const natural_origin = preparedVisualOffsetForTest(&wide_prepared);
    const source_origin = natural_origin + 2;
    try setPreparedVisualOffsetForTest(&wide_prepared, source_origin);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        flow,
        wide_prepared.selection,
        source_origin,
        wide_prepared.cursor.cursor_row,
        wide_prepared.cursor.cursor_col,
        710,
    );

    runtime.layout = transcriptTestLayout(12, 8, 4);
    runtime.resize_history_row_delta = 2;
    var narrow_source = try testSource(alloc, flow, runtime.layout.cols);
    defer narrow_source.deinit(alloc);
    var narrow_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &narrow_source,
    );
    defer narrow_prepared.deinit(alloc);
    try commitPreparedPartiallyForTest(
        &runtime,
        alloc,
        &narrow_source,
        &narrow_prepared,
    );
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        runtime.transcriptCommitDiagnostic().state,
    );
    try std.testing.expect(runtime.stableTranscriptProjectionForFlow(flow) == null);
    const recovering_origin = runtime.measuredHistoryOriginForFlow(flow) orelse
        return error.TestExpectedMeasuredHistoryOrigin;
    try std.testing.expectEqual(
        source_origin,
        recovering_origin.origin.source_visual_offset,
    );

    runtime.layout = transcriptTestLayout(24, 12, 8);
    runtime.resize_history_row_delta = 0;
    var restored = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &wide_source,
    );
    defer restored.deinit(alloc);
    try std.testing.expectEqual(
        source_origin,
        preparedVisualOffsetForTest(&restored),
    );
    try commitPreparedForTest(&runtime, alloc, &wide_source, &restored);
    const recovered = runtime.stableTranscriptProjectionForFlow(flow) orelse
        return error.TestExpectedStableTranscript;
    try std.testing.expectEqual(source_origin, recovered.visual_offset);
    try std.testing.expect(recovered.measured_history_origin == null);
    runtime.resize_history_row_delta = null;
    try expectRendererAppendRestored(
        &runtime,
        alloc,
        flow,
        flow ++
            "recovered append 0\nrecovered append 1\nrecovered append 2\n" ++
            "recovered append 3\nrecovered append 4\nrecovered append 5\n",
    );
}

test "zero measured reverse restores source origin after compatible paint" {
    const alloc = std.testing.allocator;
    const flow =
        "line 00 abcdefghij\n" ++
        "line 01 abcdefghij\n" ++
        "line 02 abcdefghij\n" ++
        "line 03 abcdefghij\n" ++
        "line 04 abcdefghij\n" ++
        "line 05 abcdefghij\n" ++
        "line 06 abcdefghij\n" ++
        "line 07 abcdefghij\n" ++
        "line 08 abcdefghij\n" ++
        "line 09 abcdefghij\n" ++
        "line 10 abcdefghij\n" ++
        "line 11 abcdefghij\n";
    const grown_flow = flow ++ "compatible append\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var wide_source = try testSource(alloc, flow, runtime.layout.cols);
    defer wide_source.deinit(alloc);
    var wide_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &wide_source,
    );
    defer wide_prepared.deinit(alloc);
    const source_origin = preparedVisualOffsetForTest(&wide_prepared) + 2;
    try setPreparedVisualOffsetForTest(&wide_prepared, source_origin);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        flow,
        wide_prepared.selection,
        source_origin,
        wide_prepared.cursor.cursor_row,
        wide_prepared.cursor.cursor_col,
        720,
    );

    runtime.layout = transcriptTestLayout(12, 8, 4);
    runtime.resize_history_row_delta = 2;
    var narrow_source = try testSource(alloc, flow, runtime.layout.cols);
    defer narrow_source.deinit(alloc);
    var narrow_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &narrow_source,
    );
    defer narrow_prepared.deinit(alloc);
    try commitPreparedForTest(
        &runtime,
        alloc,
        &narrow_source,
        &narrow_prepared,
    );

    runtime.resize_history_row_delta = null;
    var grown_narrow_source = try testSource(
        alloc,
        grown_flow,
        runtime.layout.cols,
    );
    defer grown_narrow_source.deinit(alloc);
    var grown_narrow_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &grown_narrow_source,
    );
    defer grown_narrow_prepared.deinit(alloc);
    try commitPreparedForTest(
        &runtime,
        alloc,
        &grown_narrow_source,
        &grown_narrow_prepared,
    );
    const compatible = runtime.stableTranscriptProjectionForFlow(grown_flow) orelse
        return error.TestExpectedStableTranscript;
    const compatible_origin = compatible.measured_history_origin orelse
        return error.TestExpectedMeasuredHistoryOrigin;
    try std.testing.expectEqual(
        source_origin,
        compatible_origin.source_visual_offset,
    );

    runtime.layout = transcriptTestLayout(24, 12, 8);
    runtime.resize_history_row_delta = 0;
    var grown_wide_source = try testSource(
        alloc,
        grown_flow,
        runtime.layout.cols,
    );
    defer grown_wide_source.deinit(alloc);
    var restored = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &grown_wide_source,
    );
    defer restored.deinit(alloc);
    try std.testing.expectEqual(
        source_origin,
        preparedVisualOffsetForTest(&restored),
    );
    try commitPreparedForTest(
        &runtime,
        alloc,
        &grown_wide_source,
        &restored,
    );
    const restored_projection = runtime.stableTranscriptProjectionForFlow(
        grown_flow,
    ) orelse return error.TestExpectedStableTranscript;
    try std.testing.expectEqual(source_origin, restored_projection.visual_offset);
    try std.testing.expect(restored_projection.measured_history_origin == null);
    runtime.resize_history_row_delta = null;
    try expectRendererAppendRestored(
        &runtime,
        alloc,
        grown_flow,
        grown_flow ++
            "post-restore append 0\npost-restore append 1\n" ++
            "post-restore append 2\npost-restore append 3\n" ++
            "post-restore append 4\npost-restore append 5\n",
    );
}

test "unrepresentable zero reverse rebases to natural source projection" {
    const alloc = std.testing.allocator;
    const flow =
        "line 00\n" ++
        "line 01\n" ++
        "line 02\n" ++
        "line 03\n" ++
        "line 04\n" ++
        "line 05\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(12, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    var narrow_source = try testSource(alloc, flow, runtime.layout.cols);
    defer narrow_source.deinit(alloc);
    var narrow_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &narrow_source,
    );
    defer narrow_prepared.deinit(alloc);
    try installStableAnchorWithOriginForTest(
        &runtime,
        alloc,
        flow,
        narrow_prepared.selection,
        preparedVisualOffsetForTest(&narrow_prepared),
        narrow_prepared.cursor.cursor_row,
        narrow_prepared.cursor.cursor_col,
        730,
        .{
            .source_cols = 24,
            .source_visual_offset = 99,
        },
    );

    runtime.layout = transcriptTestLayout(24, 12, 8);
    runtime.resize_history_row_delta = null;
    var wide_source = try testSource(alloc, flow, runtime.layout.cols);
    defer wide_source.deinit(alloc);
    var natural = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &wide_source,
    );
    defer natural.deinit(alloc);
    const natural_offset = preparedVisualOffsetForTest(&natural);

    runtime.resize_history_row_delta = 0;
    var rebased = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &wide_source,
    );
    defer rebased.deinit(alloc);
    try std.testing.expectEqual(
        natural_offset,
        preparedVisualOffsetForTest(&rebased),
    );
    try std.testing.expect(rebased.measured_history_origin_consumed);
}

test "measured resize history excludes synthetic reflow fallback" {
    const alloc = std.testing.allocator;
    const flow =
        "stable 00\nstable 01\nstable 02\nstable 03\nstable 04\n" ++
        "stable 05\nstable 06\nstable 07\nstable 08\nstable 09\n" ++
        "stable 10\nstable 11\nstable 12\nstable 13\nstable 14\n" ++
        "stable 15\nstable 16\nstable 17\nstable 18\nstable 19\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        flow,
        testSelectionInArea(0, 1, 4),
        0,
        4,
        1,
        46,
    );

    const shadow = runtime.shadow_vt.?;
    shadow.cells[19].codepoint = 'x';
    shadow.cursor_row = 8;
    shadow.cursor_col = 1;
    runtime.viewport_clear_pending = true;
    runtime.layout = transcriptTestLayout(10, 8, 2);

    runtime.resize_history_row_delta = 2;
    var measured_source = try testSource(alloc, flow, runtime.layout.cols);
    defer measured_source.deinit(alloc);
    var measured_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &measured_source,
    );
    defer measured_prepared.deinit(alloc);
    const measured = runtime.planTranscriptScroll(&measured_prepared);
    try std.testing.expect(measured.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 0), measured.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), measured.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), measured.planned_rows);
    if (measured_prepared.measured_history_origin == null) {
        return error.TestExpectedMeasuredHistoryOrigin;
    }
    const prepared_endpoint = measured_prepared.measured_history_origin.?.endpoint;

    runtime.resize_history_row_delta = 0;
    var zero_source = try testSource(alloc, flow, runtime.layout.cols);
    defer zero_source.deinit(alloc);
    var zero_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &zero_source,
    );
    defer zero_prepared.deinit(alloc);
    const zero = runtime.planTranscriptScroll(&zero_prepared);
    try std.testing.expect(zero.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 0), zero.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), zero.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), zero.planned_rows);

    runtime.resize_history_row_delta = null;
    var fallback_source = try testSource(alloc, flow, runtime.layout.cols);
    defer fallback_source.deinit(alloc);
    var fallback_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &fallback_source,
    );
    defer fallback_prepared.deinit(alloc);
    const fallback = runtime.planTranscriptScroll(&fallback_prepared);
    try std.testing.expect(fallback.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 2), fallback.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), fallback.semantic_rows);
    try std.testing.expectEqual(@as(u16, 2), fallback.planned_rows);

    runtime.resize_history_row_delta = 2;
    try commitPreparedForTest(
        &runtime,
        alloc,
        &measured_source,
        &measured_prepared,
    );
    const committed = runtime.stableTranscriptProjectionForFlow(flow) orelse
        return error.TestExpectedStableTranscript;
    try std.testing.expectEqualDeep(
        prepared_endpoint,
        committed.measured_history_origin.?.endpoint,
    );
}

test "measured resize releases one physical boundary row" {
    const alloc = std.testing.allocator;
    const flow =
        "stable 00\nstable 01\nstable 02\nstable 03\nstable 04\n" ++
        "stable 05\nstable 06\nstable 07\nstable 08\nstable 09\n" ++
        "stable 10\nstable 11\nstable 12\nstable 13\nstable 14\n" ++
        "stable 15\nstable 16\nstable 17\nstable 18\nstable 19\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
        .full_transcript = .{ .depth = .full },
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        flow,
        testSelectionInArea(0, 1, 4),
        0,
        4,
        1,
        46,
    );

    const shadow = runtime.shadow_vt.?;
    shadow.cells[19].codepoint = 'x';
    shadow.cursor_row = 8;
    shadow.cursor_col = 1;
    runtime.viewport_clear_pending = true;
    runtime.layout = transcriptTestLayout(10, 8, 3);
    runtime.resize_history_row_delta = 2;

    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &source,
    );
    defer prepared.deinit(alloc);
    const facts = runtime.planTranscriptScroll(&prepared);

    try std.testing.expect(facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 1), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 1), facts.planned_rows);
}

test "same-source semantic debt survives narrow to wide projection rebase" {
    const alloc = std.testing.allocator;
    const flow =
        "abcdefghijk\n" ++
        "one\n" ++
        "two\n" ++
        "three\n" ++
        "four\n" ++
        "five\n";
    const grown_flow = flow ++ "six\nseven\n";
    const appended_flow = grown_flow ++ "eight\nnine\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(5, 10, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try enterRendererDerivedSemanticRecovery(
        &runtime,
        alloc,
        flow,
        4,
        1,
        null,
    );
    const retained_semantic_rows =
        runtime.transcriptCommitDiagnostic().remaining_inline_rows;
    try std.testing.expect(retained_semantic_rows > 0);

    runtime.layout = transcriptTestLayout(20, 10, 4);
    const first = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        flow,
        0,
        .terminal_partial_write,
    );
    try std.testing.expect(first.facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 0), first.facts.resize_reflow_rows);
    try std.testing.expectEqual(retained_semantic_rows, first.facts.semantic_rows);
    try std.testing.expectEqual(retained_semantic_rows, first.facts.planned_rows);
    try std.testing.expectEqual(
        retained_semantic_rows,
        runtime.transcriptCommitDiagnostic().remaining_inline_rows,
    );
    try std.testing.expectEqual(
        first.facts.target_visual_offset,
        first.visual_offset,
    );

    const growth = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        grown_flow,
        0,
        .terminal_partial_write,
    );
    try std.testing.expect(growth.facts.recovery_rebase);
    try std.testing.expect(growth.facts.semantic_rows > retained_semantic_rows);
    const growth_rows = growth.facts.semantic_rows - retained_semantic_rows;
    try std.testing.expectEqual(
        first.visual_offset + growth_rows,
        growth.visual_offset,
    );
    try std.testing.expect(
        runtime.stableTranscriptProjectionForFlow(grown_flow) == null,
    );

    const repeated = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        grown_flow,
        0,
        .terminal_partial_write,
    );
    try std.testing.expectEqual(
        growth.facts.semantic_rows,
        repeated.facts.semantic_rows,
    );
    try std.testing.expectEqual(growth.visual_offset, repeated.visual_offset);

    const complete = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        grown_flow,
        @intCast(repeated.facts.semantic_rows),
        .committed,
    );
    try std.testing.expectEqual(
        repeated.facts.semantic_rows,
        complete.facts.semantic_rows,
    );
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    const stable = runtime.stableTranscriptProjectionForFlow(grown_flow) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(growth.visual_offset, stable.visual_offset);
    try expectRendererAppendRestored(
        &runtime,
        alloc,
        grown_flow,
        appended_flow,
    );
}

test "same-source semantic and resize debt survive wide to narrow rebase in order" {
    const alloc = std.testing.allocator;
    const flow = "stable\nbase\n";
    const grown_flow = flow ++ "growth one\ngrowth two\n";
    const appended_flow = grown_flow ++ "after one\nafter two\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try enterResizeReflowRecoveryWithAcceptedRows(
        &runtime,
        alloc,
        null,
        .terminal_partial_write,
        0,
    );

    const growth = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        grown_flow,
        0,
        .terminal_partial_write,
    );
    try std.testing.expectEqual(@as(u16, 2), growth.facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 2), growth.facts.semantic_rows);

    runtime.layout = transcriptTestLayout(5, 8, 2);
    const first = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        grown_flow,
        1,
        .terminal_partial_write,
    );
    try std.testing.expect(first.facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 2), first.facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 2), first.facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 4), first.facts.planned_rows);
    try std.testing.expectEqual(
        @as(u16, 3),
        runtime.transcriptCommitDiagnostic().remaining_inline_rows,
    );

    const second = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        grown_flow,
        1,
        .terminal_partial_write,
    );
    try std.testing.expectEqual(@as(u16, 1), second.facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 2), second.facts.semantic_rows);
    try std.testing.expectEqual(
        @as(u16, 2),
        runtime.transcriptCommitDiagnostic().remaining_inline_rows,
    );
    try std.testing.expectEqual(first.visual_offset, second.visual_offset);

    const third = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        grown_flow,
        1,
        .terminal_partial_write,
    );
    try std.testing.expectEqual(@as(u16, 0), third.facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 2), third.facts.semantic_rows);
    try std.testing.expectEqual(
        @as(u16, 1),
        runtime.transcriptCommitDiagnostic().remaining_inline_rows,
    );
    try std.testing.expectEqual(first.visual_offset, third.visual_offset);

    const complete = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        grown_flow,
        1,
        .committed,
    );
    try std.testing.expectEqual(@as(u16, 0), complete.facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 1), complete.facts.semantic_rows);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    const stable = runtime.stableTranscriptProjectionForFlow(grown_flow) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(first.visual_offset, stable.visual_offset);
    try expectRendererAppendRestored(
        &runtime,
        alloc,
        grown_flow,
        appended_flow,
    );
}

test "same-source semantic debt survives measured history rebase" {
    const alloc = std.testing.allocator;
    const flow = "0\n1\n2\n3\n4\n5\n6\n7\n";
    const grown_flow = flow ++ "8\n9\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 10, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try enterRendererDerivedSemanticRecovery(
        &runtime,
        alloc,
        flow,
        4,
        1,
        null,
    );
    const retained_semantic_rows =
        runtime.transcriptCommitDiagnostic().remaining_inline_rows;
    try std.testing.expect(retained_semantic_rows > 1);

    runtime.resize_history_row_delta = 2;
    const measured = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        flow,
        0,
        .committed,
    );
    try std.testing.expect(measured.facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 0), measured.facts.resize_reflow_rows);
    try std.testing.expectEqual(
        retained_semantic_rows,
        measured.facts.semantic_rows,
    );
    try std.testing.expectEqual(
        retained_semantic_rows,
        runtime.transcriptCommitDiagnostic().remaining_inline_rows,
    );

    runtime.resize_history_row_delta = null;
    const repeated = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        flow,
        1,
        .terminal_partial_write,
    );
    try std.testing.expectEqual(
        retained_semantic_rows,
        repeated.facts.semantic_rows,
    );
    try std.testing.expectEqual(
        retained_semantic_rows - 1,
        runtime.transcriptCommitDiagnostic().remaining_inline_rows,
    );
    try std.testing.expectEqual(measured.visual_offset, repeated.visual_offset);
    try std.testing.expect(
        runtime.stableTranscriptProjectionForFlow(flow) == null,
    );

    const remaining = retained_semantic_rows - 1;
    const complete = try consumeRendererRecoveryAttempt(
        &runtime,
        alloc,
        flow,
        @intCast(remaining),
        .committed,
    );
    try std.testing.expectEqual(remaining, complete.facts.semantic_rows);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    const stable = runtime.stableTranscriptProjectionForFlow(flow) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(measured.visual_offset, stable.visual_offset);
    try expectRendererAppendRestored(&runtime, alloc, flow, grown_flow);
}

test "finalized transcript transition owns append suffix and commits one anchor" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try installStableAnchorForTest(&runtime, alloc, "old\n", testSelection(0), 0, 3, 1, 43);

    var source = try testSource(alloc, "old\nnew\n", runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = source.bytes,
        .owns_bytes = false,
        .selection = testSelection(1),
        .cursor = .{ .cursor_row = 4, .cursor_col = 1, .replaceable_row = 4 },
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, &.{ 1, 1 });
    const scroll_plan = render_engine.frame_scroll_plan.merge(runtime.layout.rows, 1, 0, 1);
    var plan = testPaintPlan(&runtime, prepared.selection);
    const target_layout = render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    try std.testing.expectEqualStrings("new\r\n", transition.document_append.bytes);
    try std.testing.expectEqual(@as(u16, 3), transition.document_append.start_row);
    try std.testing.expectEqual(@as(u16, 1), transition.document_append.start_col);

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = false,
        .terminal_scroll_rows_committed = 1,
        .document_append_committed = true,
        .committed_cursor_row = 4,
        .committed_cursor_col = 1,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const diagnostic = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(transcript_runtime.TranscriptCommitDiagnosticState.stable, diagnostic.state);
    try std.testing.expectEqual(@as(?usize, 1), diagnostic.stable_start_line);
    try std.testing.expectEqual(@as(u32, 1), diagnostic.visual_offset);
    const stable = runtime.stableTranscriptProjectionForFlow("old\nnew\n").?;
    try std.testing.expectEqual(@as(u16, 4), stable.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), stable.cursor_col);
}

test "transcript transition staging preserves prior commit across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkTranscriptTransitionStagingAllocationFailures,
        .{},
    );
}

test "committed transcript transition installation performs no allocation" {
    const backing = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(backing, .{});
    const alloc = failing.allocator();
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try installStableAnchorForTest(&runtime, alloc, "old\n", testSelection(0), 0, 3, 1, 72);

    var source = try testSource(alloc, "old\nnew\n", runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = source.bytes,
        .owns_bytes = false,
        .selection = testSelection(1),
        .cursor = .{ .cursor_row = 4, .cursor_col = 1, .replaceable_row = 4 },
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, &.{ 1, 1 });
    const scroll_plan = render_engine.frame_scroll_plan.merge(runtime.layout.rows, 1, 0, 1);
    var plan = testPaintPlan(&runtime, prepared.selection);
    const target_layout = render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    failing.fail_index = failing.alloc_index;
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = false,
        .terminal_scroll_rows_committed = 1,
        .document_append_committed = true,
        .committed_cursor_row = 4,
        .committed_cursor_col = 1,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
}

test "partial transcript transition records exact recovery debt" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try installStableAnchorForTest(&runtime, alloc, "stable", testSelection(0), 0, 3, 1, 44);

    var source = try testSource(alloc, "stable", runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = source.bytes,
        .owns_bytes = false,
        .selection = testSelection(5),
        .cursor = .{ .cursor_row = 4, .cursor_col = 1, .replaceable_row = 4 },
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, &([_]u16{1} ** 16));
    const scroll_plan = render_engine.frame_scroll_plan.merge(runtime.layout.rows, 1, 0, 5);
    var plan = testPaintPlan(&runtime, prepared.selection);
    const target_layout = render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = false,
        .terminal_scroll_rows_committed = 2,
        .document_append_committed = false,
        .committed_cursor_row = 3,
        .committed_cursor_col = 1,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const diagnostic = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(transcript_runtime.TranscriptCommitDiagnosticState.recovering, diagnostic.state);
    try std.testing.expectEqual(@as(u32, 2), diagnostic.visual_offset);
    try std.testing.expectEqual(@as(u16, 3), diagnostic.remaining_inline_rows);
    try std.testing.expect(runtime.stableTranscriptProjectionForFlow("stable") == null);
}

test "transcript recovery debt does not double count unmaterialized inline rows" {
    const alloc = std.testing.allocator;
    const flow =
        "00\n01\n02\n03\n04\n05\n06\n07\n" ++
        "08\n09\n10\n11\n12\n13\n14\n15";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var stable_source = try testSource(alloc, flow, runtime.layout.cols);
    defer stable_source.deinit(alloc);
    var stable_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &stable_source,
    );
    defer stable_prepared.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 8), stable_prepared.selection.start_line);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        flow,
        stable_prepared.selection,
        8,
        stable_prepared.cursor.cursor_row,
        stable_prepared.cursor.cursor_col,
        44,
    );

    runtime.owned_top_row = 5;
    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 12), prepared.selection.start_line);
    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 4), facts.semantic_rows);
    const scroll_plan = render_engine.frame_scroll_plan.merge(runtime.layout.rows, 5, 3, 4);
    try std.testing.expectEqual(@as(u16, 1), scroll_plan.remaining_inline_advance_rows);
    var plan = testPaintPlan(&runtime, prepared.selection);
    const target_layout = render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    runtime.ackPreservedRowReleaseAssumeValid(
        scroll_plan,
        scroll_plan.terminal_scroll_rows,
    );
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = false,
        .terminal_scroll_rows_committed = scroll_plan.terminal_scroll_rows,
        .document_append_committed = false,
        .committed_cursor_row = prepared.cursor.cursor_row,
        .committed_cursor_col = prepared.cursor.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const diagnostic = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(transcript_runtime.TranscriptCommitDiagnosticState.recovering, diagnostic.state);
    try std.testing.expectEqual(@as(u16, 1), diagnostic.remaining_inline_rows);
    try std.testing.expectEqual(@as(u32, 11), diagnostic.visual_offset);

    var recovery_source = try testSource(alloc, flow, runtime.layout.cols);
    defer recovery_source.deinit(alloc);
    var recovery_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &recovery_source,
    );
    defer recovery_prepared.deinit(alloc);
    const recovery_facts = runtime.planTranscriptScroll(&recovery_prepared);
    try std.testing.expectEqual(@as(u16, 1), recovery_facts.planned_rows);
    const recovery_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        recovery_facts.planned_rows,
    );
    var recovery_plan = testPaintPlan(&runtime, recovery_prepared.selection);
    const recovery_layout =
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(recovery_plan);
    var recovery_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &recovery_source,
        &recovery_prepared,
        recovery_layout,
        &recovery_plan,
        recovery_scroll_plan,
    );
    defer recovery_transition.deinit(alloc);
    try std.testing.expect(recovery_transition.document_append.isEmpty());

    runtime.consumeTranscriptTransition(alloc, &recovery_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 1,
        .document_append_committed = false,
        .committed_cursor_row = recovery_transition.cursor_row,
        .committed_cursor_col = recovery_transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    const settled = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(transcript_runtime.TranscriptCommitDiagnosticState.stable, settled.state);
    try std.testing.expectEqual(@as(u16, 0), settled.remaining_inline_rows);
    try std.testing.expectEqual(@as(u32, 12), settled.visual_offset);
}

test "recovery area-only endpoint movement preserves semantic debt" {
    const alloc = std.testing.allocator;
    const stable_flow = "stable\n";
    const attempt_flow = stable_flow ++ "attempt\n";
    const attempt_rows = [_]u16{1} ** 10;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 10, 6),
        .owned_top_row = 5,
    };
    defer runtime.deinit(alloc);
    try enterSemanticAppendRecovery(
        &runtime,
        alloc,
        stable_flow,
        attempt_flow,
        &attempt_rows,
    );

    var source = try testSource(alloc, attempt_flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(7, 1, runtime.layout.content_bottom),
        .cursor = .{ .cursor_row = 6, .cursor_col = 1, .replaceable_row = 6 },
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, &attempt_rows);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expectEqual(@as(u16, 0), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 1), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 1), facts.planned_rows);
}

test "recovery source growth plus area movement counts only source visual growth" {
    const alloc = std.testing.allocator;
    const stable_flow = "stable\n";
    const attempt_flow = stable_flow ++ "attempt\n";
    const grown_flow = attempt_flow ++ "growth one\ngrowth two\n";
    const attempt_rows = [_]u16{1} ** 10;
    const grown_rows = [_]u16{1} ** 12;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 10, 6),
        .owned_top_row = 5,
    };
    defer runtime.deinit(alloc);
    try enterSemanticAppendRecovery(
        &runtime,
        alloc,
        stable_flow,
        attempt_flow,
        &attempt_rows,
    );

    var source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(9, 1, runtime.layout.content_bottom),
        .cursor = .{ .cursor_row = 6, .cursor_col = 1, .replaceable_row = 6 },
    };
    defer prepared.deinit(alloc);
    try prepared.line_visual_rows.appendSlice(alloc, &grown_rows);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expectEqual(@as(u32, 3), facts.source_visual_offset);
    try std.testing.expectEqual(@as(u32, 9), facts.target_visual_offset);
    try std.testing.expectEqual(@as(u16, 0), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 3), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 3), facts.planned_rows);
}

test "recovery consumes resize reflow before semantic debt across partial results" {
    const alloc = std.testing.allocator;
    const grown_flow = "stable\nbase\n" ++ "growth one\ngrowth two\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try enterResizeReflowRecovery(
        &runtime,
        alloc,
        null,
        .terminal_partial_write,
    );

    var source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expectEqual(@as(u16, 1), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 2), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 3), facts.planned_rows);

    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(&runtime, prepared.selection);
    const target_layout =
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(transition.document_append.isEmpty());

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 2,
        .document_append_committed = false,
        .committed_cursor_row = 2,
        .committed_cursor_col = 1,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u32, 1), recovery.visual_offset);
    try std.testing.expectEqual(@as(u16, 1), recovery.remaining_inline_rows);

    var followup_source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer followup_source.deinit(alloc);
    var followup_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &followup_source,
    );
    defer followup_prepared.deinit(alloc);
    const followup_facts = runtime.planTranscriptScroll(&followup_prepared);
    try std.testing.expectEqual(@as(u16, 0), followup_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 1), followup_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 1), followup_facts.planned_rows);
}

test "committed resize cleanup retains fallback recovery reflow debt" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try enterResizeReflowRecovery(
        &runtime,
        alloc,
        null,
        .committed,
    );
    const recovery_offset = runtime.transcriptCommitDiagnostic().visual_offset;

    runtime.resize_history_row_delta = null;
    var source = try testSource(alloc, "stable\nbase\n", runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 1), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 1), facts.planned_rows);

    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(&runtime, prepared.selection);
    const target_layout =
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        target_layout,
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(transition.document_append.isEmpty());

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 0,
        .changed_cells = 0,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = 2,
        .committed_cursor_col = 1,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(recovery_offset, recovery.visual_offset);
    try std.testing.expectEqual(@as(u16, 1), recovery.remaining_inline_rows);

    var complete_source = try testSource(alloc, "stable\nbase\n", runtime.layout.cols);
    defer complete_source.deinit(alloc);
    var complete_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &complete_source,
    );
    defer complete_prepared.deinit(alloc);
    const complete_facts = runtime.planTranscriptScroll(&complete_prepared);
    try std.testing.expect(complete_facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 1), complete_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), complete_facts.semantic_rows);
    const complete_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        complete_facts.planned_rows,
    );
    var complete_plan = testPaintPlan(&runtime, complete_prepared.selection);
    var complete_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &complete_source,
        &complete_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(complete_plan),
        &complete_plan,
        complete_scroll_plan,
    );
    defer complete_transition.deinit(alloc);
    try std.testing.expectEqual(recovery_offset, complete_transition.visual_offset);
    runtime.consumeTranscriptTransition(alloc, &complete_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = complete_scroll_plan.terminal_scroll_rows,
        .document_append_committed = false,
        .committed_cursor_row = complete_transition.cursor_row,
        .committed_cursor_col = complete_transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const stable = runtime.stableTranscriptProjectionForFlow("stable\nbase\n") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(recovery_offset, stable.visual_offset);
}

test "incompatible recovery source stays on rebase path after partial repaint" {
    const alloc = std.testing.allocator;
    const stable_flow = "stable\n";
    const attempt_flow = stable_flow ++ "attempt\n";
    const replacement_flow = "replacement\n";
    const grown_replacement_flow = replacement_flow ++ "growth\n";
    const attempt_rows = [_]u16{1} ** 10;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 10, 6),
        .owned_top_row = 5,
    };
    defer runtime.deinit(alloc);
    try enterSemanticAppendRecovery(
        &runtime,
        alloc,
        stable_flow,
        attempt_flow,
        &attempt_rows,
    );

    var replacement_source = try testSource(
        alloc,
        replacement_flow,
        runtime.layout.cols,
    );
    defer replacement_source.deinit(alloc);
    var replacement_prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = replacement_source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(0, 1, runtime.layout.content_bottom),
        .cursor = .{ .cursor_row = 6, .cursor_col = 1, .replaceable_row = 6 },
    };
    defer replacement_prepared.deinit(alloc);
    try replacement_prepared.line_visual_rows.appendSlice(
        alloc,
        &.{ 1, 1, 1, 1, 1 },
    );
    const replacement_facts = runtime.planTranscriptScroll(&replacement_prepared);
    try std.testing.expect(!replacement_facts.source_compatible);
    try std.testing.expectEqual(@as(u16, 0), replacement_facts.planned_rows);

    const replacement_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        replacement_facts.planned_rows,
    );
    var replacement_plan = testPaintPlan(&runtime, replacement_prepared.selection);
    var replacement_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &replacement_source,
        &replacement_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(
            replacement_plan,
        ),
        &replacement_plan,
        replacement_scroll_plan,
    );
    defer replacement_transition.deinit(alloc);
    try std.testing.expect(replacement_transition.document_append.isEmpty());
    runtime.consumeTranscriptTransition(alloc, &replacement_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = 6,
        .committed_cursor_col = 1,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        runtime.transcriptCommitDiagnostic().state,
    );

    var grown_source = try testSource(
        alloc,
        grown_replacement_flow,
        runtime.layout.cols,
    );
    defer grown_source.deinit(alloc);
    var grown_prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = grown_source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(1, 1, runtime.layout.content_bottom),
        .cursor = .{ .cursor_row = 6, .cursor_col = 1, .replaceable_row = 6 },
    };
    defer grown_prepared.deinit(alloc);
    try grown_prepared.line_visual_rows.appendSlice(
        alloc,
        &.{ 1, 1, 1, 1, 1, 1 },
    );
    const grown_facts = runtime.planTranscriptScroll(&grown_prepared);
    try std.testing.expect(grown_facts.source_compatible);
    try std.testing.expectEqual(@as(u16, 0), grown_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), grown_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), grown_facts.planned_rows);
}

test "structured replacement preserves reflow debt and drops old semantic debt" {
    const alloc = std.testing.allocator;
    const stable_flow = "stable\nbase\n";
    const old_growth = "old growth\n";
    const replacement = "replacement\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntry(alloc, stable_flow);
    try enterResizeReflowRecoveryWithAcceptedRows(
        &runtime,
        alloc,
        null,
        .terminal_partial_write,
        0,
    );
    const growth_entry_id = try runtime.appendRawTranscriptEntry(
        alloc,
        old_growth,
    );

    var old_source = try runtime.prepareTranscriptSource(alloc, null);
    defer old_source.deinit(alloc);
    var old_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &old_source,
    );
    defer old_prepared.deinit(alloc);
    const old_facts = runtime.planTranscriptScroll(&old_prepared);
    try std.testing.expectEqual(@as(u16, 2), old_facts.resize_reflow_rows);
    try std.testing.expect(old_facts.semantic_rows > 0);
    try std.testing.expectEqual(
        old_facts.resize_reflow_rows + old_facts.semantic_rows,
        old_facts.planned_rows,
    );

    const old_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        old_facts.planned_rows,
    );
    var old_plan = testPaintPlan(&runtime, old_prepared.selection);
    var old_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &old_source,
        &old_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(old_plan),
        &old_plan,
        old_scroll_plan,
    );
    defer old_transition.deinit(alloc);
    try std.testing.expect(old_transition.document_append.isEmpty());
    runtime.consumeTranscriptTransition(alloc, &old_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = old_transition.cursor_row,
        .committed_cursor_col = old_transition.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    try std.testing.expectEqual(
        old_facts.planned_rows,
        runtime.transcriptCommitDiagnostic().remaining_inline_rows,
    );

    try std.testing.expect(try runtime.updateRawBytesEntry(
        alloc,
        growth_entry_id,
        replacement,
    ));
    var recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u16, 2), recovery.remaining_inline_rows);
    try std.testing.expect(
        std.mem.find(u8, runtime.transcript.items, replacement) != null,
    );

    var replacement_source = try runtime.prepareTranscriptSource(alloc, null);
    defer replacement_source.deinit(alloc);
    var replacement_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &replacement_source,
    );
    defer replacement_prepared.deinit(alloc);
    const replacement_facts = runtime.planTranscriptScroll(&replacement_prepared);
    try std.testing.expect(!replacement_facts.source_compatible);
    try std.testing.expect(replacement_facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 2), replacement_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), replacement_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 2), replacement_facts.planned_rows);

    const replacement_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        replacement_facts.planned_rows,
    );
    var replacement_plan = testPaintPlan(
        &runtime,
        replacement_prepared.selection,
    );
    var replacement_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &replacement_source,
        &replacement_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(
            replacement_plan,
        ),
        &replacement_plan,
        replacement_scroll_plan,
    );
    defer replacement_transition.deinit(alloc);
    try std.testing.expect(replacement_transition.document_append.isEmpty());
    runtime.consumeTranscriptTransition(alloc, &replacement_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 1,
        .document_append_committed = false,
        .committed_cursor_row = replacement_transition.cursor_row,
        .committed_cursor_col = replacement_transition.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u16, 1), recovery.remaining_inline_rows);

    var repeated_source = try runtime.prepareTranscriptSource(alloc, null);
    defer repeated_source.deinit(alloc);
    var repeated_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &repeated_source,
    );
    defer repeated_prepared.deinit(alloc);
    const repeated_facts = runtime.planTranscriptScroll(&repeated_prepared);
    try std.testing.expect(repeated_facts.source_compatible);
    try std.testing.expect(repeated_facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 1), repeated_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), repeated_facts.semantic_rows);
    const repeated_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        repeated_facts.planned_rows,
    );
    var repeated_plan = testPaintPlan(&runtime, repeated_prepared.selection);
    var repeated_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &repeated_source,
        &repeated_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(
            repeated_plan,
        ),
        &repeated_plan,
        repeated_scroll_plan,
    );
    defer repeated_transition.deinit(alloc);
    try std.testing.expect(repeated_transition.document_append.isEmpty());
    runtime.consumeTranscriptTransition(alloc, &repeated_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = repeated_transition.cursor_row,
        .committed_cursor_col = repeated_transition.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    try std.testing.expectEqual(
        @as(u16, 1),
        runtime.transcriptCommitDiagnostic().remaining_inline_rows,
    );

    var complete_source = try runtime.prepareTranscriptSource(alloc, null);
    defer complete_source.deinit(alloc);
    var complete_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &complete_source,
    );
    defer complete_prepared.deinit(alloc);
    const complete_facts = runtime.planTranscriptScroll(&complete_prepared);
    try std.testing.expectEqual(@as(u16, 1), complete_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), complete_facts.semantic_rows);
    const complete_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        complete_facts.planned_rows,
    );
    var complete_plan = testPaintPlan(&runtime, complete_prepared.selection);
    var complete_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &complete_source,
        &complete_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(
            complete_plan,
        ),
        &complete_plan,
        complete_scroll_plan,
    );
    defer complete_transition.deinit(alloc);
    try std.testing.expect(complete_transition.document_append.isEmpty());
    runtime.consumeTranscriptTransition(alloc, &complete_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = complete_scroll_plan.terminal_scroll_rows,
        .document_append_committed = false,
        .committed_cursor_row = complete_transition.cursor_row,
        .committed_cursor_col = complete_transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    var stable_replacement_source = try runtime.prepareTranscriptSource(
        alloc,
        null,
    );
    defer stable_replacement_source.deinit(alloc);
    try std.testing.expect(
        runtime.stableTranscriptProjectionForFlow(
            stable_replacement_source.bytes,
        ) != null,
    );
    const replacement_flow = try alloc.dupe(
        u8,
        stable_replacement_source.bytes,
    );
    defer alloc.free(replacement_flow);

    const append = "after\n";
    _ = try runtime.appendRawTranscriptEntry(alloc, append);
    var append_source = try runtime.prepareTranscriptSource(alloc, null);
    defer append_source.deinit(alloc);
    var append_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &append_source,
    );
    defer append_prepared.deinit(alloc);
    const append_facts = runtime.planTranscriptScroll(&append_prepared);
    try std.testing.expect(!append_facts.recovery_rebase);
    try std.testing.expect(append_facts.semantic_rows > 0);
    const append_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        append_facts.planned_rows,
    );
    var append_plan = testPaintPlan(&runtime, append_prepared.selection);
    var append_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &append_source,
        &append_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(
            append_plan,
        ),
        &append_plan,
        append_scroll_plan,
    );
    defer append_transition.deinit(alloc);
    try std.testing.expect(append_source.bytes.len == 0);
    try std.testing.expect(append_transition.target_flow.len > replacement_flow.len);
    try expectDocumentWireEqualsLogical(
        alloc,
        append_transition.target_flow[replacement_flow.len..],
        append_transition.document_append.bytes,
    );
}

test "structured retention preserves recovery reflow debt" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntry(alloc, "stable\n");
    _ = try runtime.appendRawTranscriptEntry(alloc, "base\n");
    try enterResizeReflowRecoveryWithAcceptedRows(
        &runtime,
        alloc,
        null,
        .terminal_partial_write,
        0,
    );

    runtime.max_retained_transcript_bytes = "base\n".len;
    try runtime.enforceStructuredRetention(alloc, null);
    try std.testing.expectEqualStrings("base\n", runtime.transcript.items);
    const recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u16, 2), recovery.remaining_inline_rows);

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &source,
    );
    defer prepared.deinit(alloc);
    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(!facts.source_compatible);
    try std.testing.expect(facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 2), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 2), facts.planned_rows);
}

test "invalid origin partial recovery rebases until complete repaint then appends" {
    const alloc = std.testing.allocator;
    const flow = "0\n1\n2\n3\n4\n5\n6\n7";
    const grown_flow = flow ++ "\n8\n9";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var first_source = try testSource(alloc, flow, runtime.layout.cols);
    defer first_source.deinit(alloc);
    var first_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &first_source,
    );
    defer first_prepared.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4), first_prepared.selection.start_line);

    const first_facts = runtime.planTranscriptScroll(&first_prepared);
    try std.testing.expect(first_facts.recovery_rebase);
    try std.testing.expect(!first_facts.recovery_projection_deferred);
    try std.testing.expectEqual(@as(u16, 0), first_facts.planned_rows);
    const first_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        first_facts.planned_rows,
    );
    var first_plan = testPaintPlan(&runtime, first_prepared.selection);
    var first_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &first_source,
        &first_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(first_plan),
        &first_plan,
        first_scroll_plan,
    );
    defer first_transition.deinit(alloc);
    try std.testing.expect(first_transition.recovery_rebase);
    try std.testing.expect(first_transition.document_append.isEmpty());
    try expectFinalizedRecoveryProjectionPaintsCoherently(
        &runtime,
        alloc,
        first_plan,
        &first_prepared,
        &first_transition,
        "4",
    );

    runtime.consumeTranscriptTransition(alloc, &first_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = first_transition.cursor_row,
        .committed_cursor_col = first_transition.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    var recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u16, 0), recovery.remaining_inline_rows);
    try std.testing.expect(runtime.stableTranscriptProjectionForFlow(flow) == null);

    var repeated_source = try testSource(alloc, flow, runtime.layout.cols);
    defer repeated_source.deinit(alloc);
    var repeated_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &repeated_source,
    );
    defer repeated_prepared.deinit(alloc);
    const repeated_facts = runtime.planTranscriptScroll(&repeated_prepared);
    try std.testing.expect(repeated_facts.source_compatible);
    try std.testing.expect(repeated_facts.recovery_rebase);
    try std.testing.expect(!repeated_facts.recovery_projection_deferred);
    try std.testing.expectEqual(@as(u16, 0), repeated_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 0), repeated_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), repeated_facts.planned_rows);

    const repeated_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        repeated_facts.planned_rows,
    );
    var repeated_plan = testPaintPlan(&runtime, repeated_prepared.selection);
    var repeated_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &repeated_source,
        &repeated_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(repeated_plan),
        &repeated_plan,
        repeated_scroll_plan,
    );
    defer repeated_transition.deinit(alloc);
    try std.testing.expect(repeated_transition.recovery_rebase);
    try std.testing.expect(repeated_transition.document_append.isEmpty());
    runtime.consumeTranscriptTransition(alloc, &repeated_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = repeated_transition.cursor_row,
        .committed_cursor_col = repeated_transition.cursor_col,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u16, 0), recovery.remaining_inline_rows);
    try std.testing.expect(runtime.stableTranscriptProjectionForFlow(flow) == null);

    var complete_source = try testSource(alloc, flow, runtime.layout.cols);
    defer complete_source.deinit(alloc);
    var complete_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &complete_source,
    );
    defer complete_prepared.deinit(alloc);
    const complete_facts = runtime.planTranscriptScroll(&complete_prepared);
    try std.testing.expect(complete_facts.recovery_rebase);
    try std.testing.expect(!complete_facts.recovery_projection_deferred);
    const complete_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        complete_facts.planned_rows,
    );
    var complete_plan = testPaintPlan(&runtime, complete_prepared.selection);
    var complete_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &complete_source,
        &complete_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(complete_plan),
        &complete_plan,
        complete_scroll_plan,
    );
    defer complete_transition.deinit(alloc);
    try std.testing.expect(complete_transition.document_append.isEmpty());
    runtime.consumeTranscriptTransition(alloc, &complete_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = complete_transition.cursor_row,
        .committed_cursor_col = complete_transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const settled = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        settled.state,
    );
    try std.testing.expectEqual(@as(u16, 0), settled.remaining_inline_rows);
    const stable = runtime.stableTranscriptProjectionForFlow(flow) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), stable.selection.start_line);
    try std.testing.expectEqual(@as(u32, 4), stable.visual_offset);

    var append_source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer append_source.deinit(alloc);
    var append_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &append_source,
    );
    defer append_prepared.deinit(alloc);
    const append_facts = runtime.planTranscriptScroll(&append_prepared);
    try std.testing.expect(append_facts.source_compatible);
    try std.testing.expectEqual(@as(u16, 2), append_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 2), append_facts.planned_rows);
    const append_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        append_facts.planned_rows,
    );
    var append_plan = testPaintPlan(&runtime, append_prepared.selection);
    var append_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &append_source,
        &append_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(append_plan),
        &append_plan,
        append_scroll_plan,
    );
    defer append_transition.deinit(alloc);
    try expectDocumentWireEqualsLogical(
        alloc,
        grown_flow[flow.len..],
        append_transition.document_append.bytes,
    );
    try std.testing.expectEqual(
        stable.cursor_row,
        append_transition.document_append.start_row,
    );
    try std.testing.expectEqual(
        stable.cursor_col,
        append_transition.document_append.start_col,
    );
}

test "recovery projection paints wrapped partial blank tail from acknowledged endpoint" {
    const alloc = std.testing.allocator;
    const flow = "abcdefghijklmno\nalpha\n\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(5, 10, 6),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const attempt_offset = try enterRendererDerivedSemanticRecovery(
        &runtime,
        alloc,
        flow,
        3,
        1,
        null,
    );
    try std.testing.expectEqual(@as(u32, 2), attempt_offset);
    runtime.layout = transcriptTestLayout(5, 10, 6);

    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), prepared.selection.start_line);
    try std.testing.expectEqual(@as(u16, 0), prepared.selection.partial_skip_rows);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 1), facts.semantic_rows);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(&runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 2), transition.visual_offset);
    try std.testing.expectEqual(@as(usize, 0), transition.selection.start_line);
    try std.testing.expectEqual(@as(u16, 2), transition.selection.partial_skip_rows);
    try std.testing.expectEqual(@as(u16, 3), transition.selection.last_visible_row);
    try std.testing.expect(transition.selection.last_visible_row_blank);
    try std.testing.expectEqual(@as(u16, 4), transition.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), transition.cursor_col);
    try expectFinalizedRecoveryProjectionPaintsCoherently(
        &runtime,
        alloc,
        plan,
        &prepared,
        &transition,
        "klmno",
    );
}

test "recovery projection moves cursor for zero-row trailing newline growth" {
    const alloc = std.testing.allocator;
    const attempt_flow = "a\nb\nc";
    const grown_flow = attempt_flow ++ "\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const attempt_offset = try enterRendererDerivedSemanticRecovery(
        &runtime,
        alloc,
        attempt_flow,
        2,
        0,
        null,
    );
    try std.testing.expectEqual(@as(u32, 1), attempt_offset);
    runtime.layout = transcriptTestLayout(20, 8, 3);

    var source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);
    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 1), facts.semantic_rows);
    try std.testing.expectEqual(@as(u32, 0), facts.target_visual_offset);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(&runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 1), transition.visual_offset);
    try std.testing.expectEqual(@as(usize, 1), transition.selection.start_line);
    try std.testing.expectEqual(@as(u16, 2), transition.selection.last_visible_row);
    try std.testing.expectEqual(@as(u16, 3), transition.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), transition.cursor_col);
    try expectFinalizedRecoveryProjectionPaintsCoherently(
        &runtime,
        alloc,
        plan,
        &prepared,
        &transition,
        "b",
    );
}

test "recovery projection relocates replaceable row through production painter" {
    const alloc = std.testing.allocator;
    const flow = "a\nb\nc\nreplace";
    const replaceable_start = std.mem.lastIndexOfScalar(u8, flow, '\n').? + 1;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 5),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const attempt_offset = try enterRendererDerivedSemanticRecovery(
        &runtime,
        alloc,
        flow,
        2,
        1,
        replaceable_start,
    );
    try std.testing.expectEqual(@as(u32, 2), attempt_offset);
    runtime.layout = transcriptTestLayout(20, 8, 6);

    var source = try testSourceWithReplaceableTail(
        alloc,
        flow,
        runtime.layout.cols,
        replaceable_start,
    );
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 4), prepared.cursor.replaceable_row);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 1), facts.semantic_rows);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(&runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 2), transition.visual_offset);
    try std.testing.expectEqual(@as(usize, 2), transition.selection.start_line);
    try std.testing.expectEqual(@as(u16, 2), transition.selection.replaceable_start_row);
    try std.testing.expectEqual(@as(u16, 2), transition.replaceable_row);
    try expectFinalizedRecoveryProjectionPaintsCoherently(
        &runtime,
        alloc,
        plan,
        &prepared,
        &transition,
        "c",
    );
}

test "row-only shrink defers wrapped recovery projection and later converges" {
    const alloc = std.testing.allocator;
    const flow = "abcdefghijklmno\nalpha\n\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(5, 10, 6),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const attempt_offset = try enterRendererDerivedSemanticRecovery(
        &runtime,
        alloc,
        flow,
        3,
        1,
        null,
    );
    try std.testing.expectEqual(@as(u32, 2), attempt_offset);
    runtime.layout = transcriptTestLayout(5, 10, 2);

    var source = try testSource(alloc, flow, runtime.layout.cols);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), prepared.selection.start_line);
    try std.testing.expectEqual(@as(u16, 0), prepared.selection.partial_skip_rows);
    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 1), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), facts.planned_rows);
    try std.testing.expect(facts.recovery_projection_deferred);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(&runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(transition.document_append.isEmpty());
    try std.testing.expect(transition.recovery_projection_deferred);
    try std.testing.expectEqual(@as(u32, 3), transition.visual_offset);
    try expectFinalizedRecoveryProjectionPaintsCoherently(
        &runtime,
        alloc,
        plan,
        &prepared,
        &transition,
        "alpha",
    );

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = transition.cursor_row,
        .committed_cursor_col = transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    var diagnostic = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        diagnostic.state,
    );
    try std.testing.expectEqual(@as(u16, 1), diagnostic.remaining_inline_rows);
    try std.testing.expectEqual(@as(u32, 1), diagnostic.visual_offset);

    runtime.layout = transcriptTestLayout(5, 10, 3);
    var recovery_source = try testSource(alloc, flow, runtime.layout.cols);
    defer recovery_source.deinit(alloc);
    var recovery_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &recovery_source,
    );
    defer recovery_prepared.deinit(alloc);
    const recovery_facts = runtime.planTranscriptScroll(&recovery_prepared);
    try std.testing.expectEqual(@as(u16, 1), recovery_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 1), recovery_facts.planned_rows);
    try std.testing.expect(!recovery_facts.recovery_projection_deferred);
    const recovery_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        recovery_facts.planned_rows,
    );
    var recovery_plan = testPaintPlan(&runtime, recovery_prepared.selection);
    var recovery_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &recovery_source,
        &recovery_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(recovery_plan),
        &recovery_plan,
        recovery_scroll_plan,
    );
    defer recovery_transition.deinit(alloc);
    try std.testing.expect(recovery_transition.document_append.isEmpty());
    try std.testing.expect(!recovery_transition.recovery_projection_deferred);
    try std.testing.expectEqual(@as(u32, 2), recovery_transition.visual_offset);
    try std.testing.expectEqual(@as(usize, 0), recovery_transition.selection.start_line);
    try std.testing.expectEqual(@as(u16, 2), recovery_transition.selection.partial_skip_rows);
    try expectFinalizedRecoveryProjectionPaintsCoherently(
        &runtime,
        alloc,
        recovery_plan,
        &recovery_prepared,
        &recovery_transition,
        "klmno",
    );

    runtime.consumeTranscriptTransition(alloc, &recovery_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = recovery_scroll_plan.terminal_scroll_rows,
        .document_append_committed = false,
        .committed_cursor_row = recovery_transition.cursor_row,
        .committed_cursor_col = recovery_transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    diagnostic = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        diagnostic.state,
    );
    try std.testing.expectEqual(@as(u16, 0), diagnostic.remaining_inline_rows);
    try std.testing.expectEqual(@as(u32, 2), diagnostic.visual_offset);
    const projection = runtime.stableTranscriptProjectionForFlow(flow) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), projection.selection.start_line);
    try std.testing.expectEqual(@as(u16, 2), projection.selection.partial_skip_rows);
    try std.testing.expectEqual(@as(u16, 3), projection.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), projection.cursor_col);
}

test "committed deferred shrink installs target geometry before recovery stabilizes" {
    const alloc = std.testing.allocator;
    const stable_flow = "0\n1\n2\n3";
    const attempt_flow = stable_flow ++ "\n4\n5\n6\n7\n8\n9";
    const visual_rows = [_]u16{1} ** 10;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(std.testing.io, "deferred-layout.log", .{ .read = true });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = transcriptTestLayout(5, 10, 8),
        .owned_top_row = 5,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        stable_flow,
        testSelectionInArea(0, 5, 8),
        0,
        8,
        1,
        401,
    );
    const stable_layout = runtime.committed_frame_layout;

    var attempt_source = try testSource(alloc, attempt_flow, runtime.layout.cols);
    defer attempt_source.deinit(alloc);
    var attempt_prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = attempt_source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(6, 5, 8),
        .cursor = .{ .cursor_row = 8, .cursor_col = 1, .replaceable_row = 8 },
    };
    defer attempt_prepared.deinit(alloc);
    try attempt_prepared.line_visual_rows.appendSlice(alloc, &visual_rows);
    try makeSyntheticPreparedRenderable(&attempt_prepared, alloc);

    const attempt_facts = runtime.planTranscriptScroll(&attempt_prepared);
    try std.testing.expectEqual(@as(u16, 6), attempt_facts.semantic_rows);
    const attempt_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        attempt_facts.planned_rows,
    );
    var attempt_plan = testPaintPlan(&runtime, attempt_prepared.selection);
    var attempt_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &attempt_source,
        &attempt_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(attempt_plan),
        &attempt_plan,
        attempt_scroll_plan,
    );
    defer attempt_transition.deinit(alloc);

    runtime.ackPreservedRowReleaseAssumeValid(attempt_scroll_plan, 5);
    runtime.consumeTranscriptTransition(alloc, &attempt_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 5,
        .document_append_committed = true,
        .committed_cursor_row = 8,
        .committed_cursor_col = 1,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    try std.testing.expectEqualDeep(stable_layout, runtime.committed_frame_layout);
    try std.testing.expectEqual(@as(u16, 1), runtime.owned_top_row);
    const partial_recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        partial_recovery.state,
    );
    try std.testing.expectEqual(@as(u16, 5), partial_recovery.remaining_inline_rows);
    try std.testing.expectEqual(@as(u32, 1), partial_recovery.visual_offset);

    runtime.layout = transcriptTestLayout(5, 10, 2);
    var deferred_source = try testSource(alloc, attempt_flow, runtime.layout.cols);
    defer deferred_source.deinit(alloc);
    var deferred_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &deferred_source,
    );
    defer deferred_prepared.deinit(alloc);

    const deferred_facts = runtime.planTranscriptScroll(&deferred_prepared);
    try std.testing.expectEqual(@as(u16, 5), deferred_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), deferred_facts.planned_rows);
    try std.testing.expect(deferred_facts.recovery_projection_deferred);
    const deferred_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        deferred_facts.planned_rows,
    );
    var deferred_plan = testPaintPlan(&runtime, deferred_prepared.selection);
    const target_layout =
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(deferred_plan);
    var deferred_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &deferred_source,
        &deferred_prepared,
        target_layout,
        &deferred_plan,
        deferred_scroll_plan,
    );
    defer deferred_transition.deinit(alloc);
    try std.testing.expect(deferred_transition.document_append.isEmpty());

    runtime.consumeTranscriptTransition(alloc, &deferred_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = deferred_transition.cursor_row,
        .committed_cursor_col = deferred_transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const recovering = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovering.state,
    );
    try std.testing.expectEqual(@as(u16, 5), recovering.remaining_inline_rows);
    try std.testing.expectEqual(@as(u32, 1), recovering.visual_offset);
    try std.testing.expectEqualStrings(stable_flow, runtime.transcript.items);
    try std.testing.expect(runtime.stableTranscriptProjectionForFlow(attempt_flow) == null);

    var invalidation_probe = OwnedBandInvalidationProbe{};
    var metrics: Metrics = .{};
    const next_result = try render_engine.frame_builder.buildAndFlushFrame(
        alloc,
        &runtime,
        &metrics,
        .{
            .plan = deferred_plan,
            .scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(
                runtime.layout.rows,
                runtime.owned_top_row,
            ),
            .body_painter = .{
                .ctx = &invalidation_probe,
                .paint = OwnedBandInvalidationProbe.paint,
            },
        },
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        next_result.shadow_state,
    );
    try std.testing.expectEqualDeep(target_layout, runtime.committed_frame_layout);
    try std.testing.expect(!invalidation_probe.saw_owned_band_change);
}

test "recovery forward area movement stabilizes at acknowledged semantic endpoint" {
    const alloc = std.testing.allocator;
    const stable_flow = "stable\n";
    const attempt_flow = stable_flow ++ "attempt\n";
    const grown_flow = attempt_flow ++ "growth one\ngrowth two\n";
    const attempt_rows = [_]u16{1} ** 10;
    const grown_rows = [_]u16{1} ** 12;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 10, 6),
        .owned_top_row = 5,
    };
    defer runtime.deinit(alloc);
    try enterSemanticAppendRecovery(
        &runtime,
        alloc,
        stable_flow,
        attempt_flow,
        &attempt_rows,
    );

    var first_source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer first_source.deinit(alloc);
    var first_prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = first_source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(6, 1, runtime.layout.content_bottom),
        .cursor = .{ .cursor_row = 6, .cursor_col = 1, .replaceable_row = 6 },
    };
    defer first_prepared.deinit(alloc);
    try first_prepared.line_visual_rows.appendSlice(alloc, &grown_rows);
    try makeSyntheticPreparedRenderable(&first_prepared, alloc);
    const first_facts = runtime.planTranscriptScroll(&first_prepared);
    try std.testing.expectEqual(@as(u16, 3), first_facts.semantic_rows);
    const first_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        first_facts.planned_rows,
    );
    var first_plan = testPaintPlan(&runtime, first_prepared.selection);
    var first_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &first_source,
        &first_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(first_plan),
        &first_plan,
        first_scroll_plan,
    );
    defer first_transition.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &first_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 1,
        .document_append_committed = false,
        .committed_cursor_row = 6,
        .committed_cursor_col = 1,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    var recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u32, 4), recovery.visual_offset);
    try std.testing.expectEqual(@as(u16, 2), recovery.remaining_inline_rows);

    var second_source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer second_source.deinit(alloc);
    var second_prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = second_source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(8, 1, runtime.layout.content_bottom),
        .cursor = .{ .cursor_row = 6, .cursor_col = 1, .replaceable_row = 6 },
    };
    defer second_prepared.deinit(alloc);
    try second_prepared.line_visual_rows.appendSlice(alloc, &grown_rows);
    try makeSyntheticPreparedRenderable(&second_prepared, alloc);
    const second_facts = runtime.planTranscriptScroll(&second_prepared);
    try std.testing.expectEqual(@as(u16, 2), second_facts.semantic_rows);
    const second_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        second_facts.planned_rows,
    );
    var second_plan = testPaintPlan(&runtime, second_prepared.selection);
    var second_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &second_source,
        &second_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(second_plan),
        &second_plan,
        second_scroll_plan,
    );
    defer second_transition.deinit(alloc);
    runtime.consumeTranscriptTransition(alloc, &second_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = 1,
        .document_append_committed = false,
        .committed_cursor_row = 6,
        .committed_cursor_col = 1,
        .shadow_state = .terminal_partial_write,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    recovery = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.recovering,
        recovery.state,
    );
    try std.testing.expectEqual(@as(u32, 5), recovery.visual_offset);
    try std.testing.expectEqual(@as(u16, 1), recovery.remaining_inline_rows);

    var final_source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer final_source.deinit(alloc);
    var final_prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = final_source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(7, 1, runtime.layout.content_bottom),
        .cursor = .{ .cursor_row = 5, .cursor_col = 1, .replaceable_row = 5 },
    };
    defer final_prepared.deinit(alloc);
    try final_prepared.line_visual_rows.appendSlice(alloc, &grown_rows);
    try makeSyntheticPreparedRenderable(&final_prepared, alloc);
    const final_facts = runtime.planTranscriptScroll(&final_prepared);
    try std.testing.expectEqual(@as(u16, 1), final_facts.semantic_rows);
    const final_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        final_facts.planned_rows,
    );
    var final_plan = testPaintPlan(&runtime, final_prepared.selection);
    var final_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &final_source,
        &final_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(final_plan),
        &final_plan,
        final_scroll_plan,
    );
    defer final_transition.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 6), final_transition.visual_offset);
    try std.testing.expectEqual(@as(usize, 6), final_transition.selection.start_line);
    try std.testing.expectEqual(@as(u16, 6), final_transition.selection.last_visible_row);
    try std.testing.expectEqual(@as(u16, 6), final_transition.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), final_transition.cursor_col);
    try std.testing.expectEqual(@as(usize, 6), final_plan.viewport.start_line);
    try std.testing.expectEqual(@as(u16, 6), final_plan.viewport.last_visible_row);
    try std.testing.expectEqual(@as(u16, 6), final_plan.cursor_target.?.row);
    try std.testing.expectEqual(@as(u16, 1), final_plan.cursor_target.?.col);
    final_prepared.selection = final_transition.selection;
    runtime.consumeTranscriptTransition(alloc, &final_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = final_scroll_plan.terminal_scroll_rows,
        .document_append_committed = !final_transition.document_append.isEmpty(),
        .committed_cursor_row = 6,
        .committed_cursor_col = 1,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const settled = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        settled.state,
    );
    try std.testing.expectEqual(@as(u32, 6), settled.visual_offset);
    const projection = runtime.stableTranscriptProjectionForFlow(grown_flow) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 6), projection.selection.start_line);
    try std.testing.expectEqual(@as(u16, 6), projection.occupied_last_row);
    try std.testing.expectEqual(@as(u16, 6), projection.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), projection.cursor_col);
    try std.testing.expectEqual(
        @as(u16, 0),
        runtime.planTranscriptScroll(&final_prepared).planned_rows,
    );
}

test "recovery backward area movement stabilizes at acknowledged semantic endpoint" {
    const alloc = std.testing.allocator;
    const stable_flow = "stable\n";
    const attempt_flow = stable_flow ++ "attempt\n";
    const attempt_rows = [_]u16{1} ** 10;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 10, 6),
        .owned_top_row = 5,
    };
    defer runtime.deinit(alloc);
    try enterSemanticAppendRecovery(
        &runtime,
        alloc,
        stable_flow,
        attempt_flow,
        &attempt_rows,
    );

    try consumeUnacceptedSemanticRecoveryRetry(
        &runtime,
        alloc,
        attempt_flow,
        &attempt_rows,
        8,
    );
    try consumeUnacceptedSemanticRecoveryRetry(
        &runtime,
        alloc,
        attempt_flow,
        &attempt_rows,
        2,
    );

    var final_source = try testSource(alloc, attempt_flow, runtime.layout.cols);
    defer final_source.deinit(alloc);
    var final_prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = final_source.bytes,
        .owns_bytes = false,
        .selection = testSelectionInArea(
            2,
            runtime.owned_top_row,
            runtime.layout.content_bottom,
        ),
        .cursor = .{
            .cursor_row = 2,
            .cursor_col = 9,
            .replaceable_row = 2,
        },
    };
    defer final_prepared.deinit(alloc);
    try final_prepared.line_visual_rows.appendSlice(alloc, &attempt_rows);
    try makeSyntheticPreparedRenderable(&final_prepared, alloc);
    const final_facts = runtime.planTranscriptScroll(&final_prepared);
    try std.testing.expectEqual(@as(u16, 0), final_facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 1), final_facts.semantic_rows);
    const final_scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        final_facts.planned_rows,
    );
    var final_plan = testPaintPlan(&runtime, final_prepared.selection);
    var final_transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &final_source,
        &final_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(final_plan),
        &final_plan,
        final_scroll_plan,
    );
    defer final_transition.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 4), final_transition.visual_offset);
    try std.testing.expectEqual(@as(usize, 4), final_transition.selection.start_line);
    try std.testing.expectEqual(@as(u16, 6), final_transition.selection.last_visible_row);
    try std.testing.expectEqual(@as(u16, 6), final_transition.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), final_transition.cursor_col);
    try std.testing.expectEqual(@as(usize, 4), final_plan.viewport.start_line);
    try std.testing.expectEqual(@as(u16, 6), final_plan.viewport.last_visible_row);
    try std.testing.expectEqual(@as(u16, 6), final_plan.cursor_target.?.row);
    try std.testing.expectEqual(@as(u16, 1), final_plan.cursor_target.?.col);

    runtime.consumeTranscriptTransition(alloc, &final_transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = final_scroll_plan.terminal_scroll_rows,
        .document_append_committed = !final_transition.document_append.isEmpty(),
        .committed_cursor_row = runtime.layout.content_bottom,
        .committed_cursor_col = 1,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    const settled = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        settled.state,
    );
    try std.testing.expectEqual(@as(u32, 4), settled.visual_offset);
    const projection = runtime.stableTranscriptProjectionForFlow(attempt_flow) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), projection.selection.start_line);
    try std.testing.expectEqual(@as(u16, 6), projection.occupied_last_row);
    try std.testing.expectEqual(@as(u16, 6), projection.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), projection.cursor_col);
}

test "same-width backward footer candidate retains one coherent stable anchor" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(120, 34, 30),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        "stable-flow",
        testSelection(88),
        368,
        19,
        120,
        1,
    );

    var prepared = transcript_painter.PreparedTranscriptSurfacePaint{
        .bytes = try alloc.dupe(u8, "stable-flow"),
        .selection = testSelection(85),
        .cursor = .{
            .cursor_row = 30,
            .cursor_col = 120,
            .replaceable_row = 30,
        },
    };
    defer prepared.deinit(alloc);
    var line_rows = [_]u16{4} ** 100;
    for (line_rows[0..17]) |*rows| rows.* = 5;
    line_rows[87] = 3;
    try prepared.line_visual_rows.appendSlice(alloc, &line_rows);

    try std.testing.expectEqual(@as(u16, 0), runtime.planTranscriptScroll(&prepared).planned_rows);
    var source = TranscriptPreparationSource{
        .bytes = try alloc.dupe(u8, "stable-flow"),
        .folded_summary_indices = &.{},
        .preview = .{ .natural_visual_rows = 30 },
        .tail_kind = null,
        .tracked_entry_id = null,
        .tracked_entry_start_line = null,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 30,
        .welcome_cut_line = null,
        .welcome_boundary = null,
        .cols = 120,
    };
    defer source.deinit(alloc);
    const layout = render_engine.frame_layout.solve(.{
        .terminal = runtime.layout,
        .owned_top = 1,
        .footer = .{ .natural_rows = 4, .min_rows = 4, .max_rows = 4 },
        .transcript = source.preview,
        .prior = runtime.committed_frame_layout,
    });
    var plan = layout.toPaintPlan(.{
        .footer_rows = .{
            .top = 31,
            .top_divider = 31,
            .banner = 31,
            .banner_active = false,
            .input_base = 32,
            .picker_divider = 33,
            .picker_start = 34,
            .bottom_divider = 33,
            .hint = 34,
            .total_rows = 4,
        },
        .viewport = prepared.selection,
        .cursor_target = .{ .row = 32, .col = 1, .visible = true },
    });
    const scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(
        runtime.layout.rows,
        1,
    );
    const scroll_facts = try runtime.prepareTranscriptScrollFactsForFrame(
        alloc,
        &source,
        &prepared,
        false,
        false,
    );
    const resolved = try runtime.resolveTranscriptTransitionTargetForFrame(
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(layout),
        scroll_plan,
        scroll_facts,
        false,
        false,
    );
    try std.testing.expectEqual(@as(usize, 85), prepared.selection.start_line);
    try std.testing.expectEqual(@as(u16, 30), prepared.cursor.cursor_row);
    try std.testing.expectEqual(@as(usize, 88), resolved.selection().start_line);
    try std.testing.expectEqual(@as(u16, 19), resolved.cursorRow());
    try std.testing.expect(resolved.bodyDisposition() == .retain_committed);
    resolved.applyToPaintPlan(&plan);
    var transition = try runtime.sealTranscriptTransition(
        alloc,
        &source,
        &prepared,
        &plan,
        resolved,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(transition.body_disposition == .retain_committed);
    try std.testing.expectEqual(@as(usize, 88), transition.selection.start_line);
    try std.testing.expectEqual(@as(u32, 368), transition.visual_offset);
    try std.testing.expectEqual(@as(u16, 19), transition.cursor_row);
    try std.testing.expectEqual(@as(u16, 120), transition.cursor_col);
    try std.testing.expectEqual(@as(u16, 30), transition.materialized.cursor_row);
    try std.testing.expectEqual(@as(u16, 120), transition.materialized.cursor_col);
    try std.testing.expectEqual(@as(usize, 88), plan.viewport.start_line);
    try std.testing.expectEqual(@as(u16, 19), plan.cursor_target.?.row);
    try std.testing.expectEqual(@as(u16, 120), plan.cursor_target.?.col);

    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 0,
        .changed_cells = 0,
        .full_repaint = false,
        .terminal_scroll_rows_committed = 0,
        .document_append_committed = false,
        .committed_cursor_row = 19,
        .committed_cursor_col = 120,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const diagnostic = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(transcript_runtime.TranscriptCommitDiagnosticState.stable, diagnostic.state);
    try std.testing.expectEqual(@as(?usize, 88), diagnostic.stable_start_line);
    try std.testing.expectEqual(@as(u32, 368), diagnostic.visual_offset);
    const stable = runtime.stableTranscriptProjectionForFlow("stable-flow").?;
    try std.testing.expectEqual(@as(u16, 19), stable.cursor_row);
    try std.testing.expectEqual(@as(u16, 120), stable.cursor_col);
}

test "attempt source projections leave transcript runtime and commit state unchanged" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 12, 8),
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .last_rendered_cols = 17,
        .last_paint_bottom_reserved_rows = 3,
        .pending_scroll_compact = true,
        .replaceable_last_line = true,
        .replaceable_row = 7,
        .replaceable_start = 2,
    };
    defer runtime.deinit(alloc);
    var metrics: Metrics = .{};
    try runtime.writeTranscript(
        alloc,
        &metrics,
        "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\n",
        true,
    );
    const entry_id = runtime.entries.items[0].id();
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_entry_id = entry_id,
        .summary_transcript_index = 777,
    });
    runtime.paint_trace.transcript_initialized = true;
    runtime.paint_trace.transcript_top = 9;
    runtime.paint_trace.transcript_bottom = 10;
    runtime.paint_trace.transcript_start_line = 42;
    runtime.paint_trace.transcript_total_lines = 43;
    runtime.paint_trace.transcript_visible_rows = 2;
    runtime.paint_trace.transcript_partial_skip_rows = 1;
    runtime.paint_trace.transcript_entries = 99;
    runtime.paint_trace.transcript_log_frame = true;
    try installStableAnchorForTest(
        &runtime,
        alloc,
        runtime.transcript.items,
        testSelection(2),
        2,
        6,
        1,
        9,
    );

    const transcript_ptr = runtime.transcript.items.ptr;
    const transcript_capacity = runtime.transcript.capacity;
    const transcript_snapshot = try alloc.dupe(u8, runtime.transcript.items);
    defer alloc.free(transcript_snapshot);
    const paint_trace_snapshot = runtime.paint_trace;
    const commit_snapshot = runtime.transcriptCommitDiagnostic();
    const cursor_row = runtime.cursor_row;
    const cursor_col = runtime.cursor_col;
    const replaceable_last_line = runtime.replaceable_last_line;
    const replaceable_row = runtime.replaceable_row;
    const replaceable_start = runtime.replaceable_start;
    const last_rendered_cols = runtime.last_rendered_cols;
    const last_paint_bottom_reserved_rows = runtime.last_paint_bottom_reserved_rows;

    var source = try runtime.prepareTranscriptSource(alloc, entry_id);
    defer source.deinit(alloc);
    var collapsed = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        &source,
        .{ .top = 4, .bottom = 3 },
    );
    collapsed.deinit(alloc);
    var compact = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        &source,
        .{ .top = 1, .bottom = 2 },
    );
    defer compact.deinit(alloc);
    var expanded = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        &source,
        .{ .top = 1, .bottom = 8 },
    );
    defer expanded.deinit(alloc);
    _ = runtime.planTranscriptScroll(&compact);
    _ = runtime.planTranscriptScroll(&expanded);

    try std.testing.expectEqual(transcript_ptr, runtime.transcript.items.ptr);
    try std.testing.expectEqual(transcript_capacity, runtime.transcript.capacity);
    try std.testing.expectEqualStrings(transcript_snapshot, runtime.transcript.items);
    try std.testing.expectEqual(@as(usize, 777), runtime.folded_command_blocks.items[0].summary_transcript_index);
    try std.testing.expectEqual(last_rendered_cols, runtime.last_rendered_cols);
    try std.testing.expectEqual(last_paint_bottom_reserved_rows, runtime.last_paint_bottom_reserved_rows);
    try std.testing.expect(runtime.pending_scroll_compact);
    try std.testing.expectEqualDeep(paint_trace_snapshot, runtime.paint_trace);
    try std.testing.expectEqualDeep(commit_snapshot, runtime.transcriptCommitDiagnostic());
    try std.testing.expectEqual(cursor_row, runtime.cursor_row);
    try std.testing.expectEqual(cursor_col, runtime.cursor_col);
    try std.testing.expectEqual(replaceable_last_line, runtime.replaceable_last_line);
    try std.testing.expectEqual(replaceable_row, runtime.replaceable_row);
    try std.testing.expectEqual(replaceable_start, runtime.replaceable_start);
}

fn checkPrepareTranscriptSourceAllocationFailures(alloc: Allocator) !void {
    const welcome =
        "fx welcome banner line one\n" ++
        "fx welcome banner line two\n";
    const summary = "● 2 command lines folded\n";
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 10, 6),
        .owned_top_row = 1,
        .max_transcript_bytes = 1024,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(alloc, welcome, .welcome);
    const summary_entry_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        summary,
        .subagent_status,
    );
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_entry_id = summary_entry_id,
    });
    try appendFoldedLineForTest(&runtime, alloc, 0, "command output line");

    var uncapped = try runtime.prepareTranscriptSource(alloc, summary_entry_id);
    defer uncapped.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 4), uncapped.folded_summary_indices[0]);
    try std.testing.expectEqual(@as(?usize, 3), uncapped.tracked_entry_start_line);
    try std.testing.expectEqual(@as(u16, 6), uncapped.preview.natural_visual_rows);
    try std.testing.expectEqual(
        transcript_blocks.LeadingWelcomeBoundary{
            .full_cut_line = 3,
            .tail_replay_line = 1,
        },
        uncapped.welcome_boundary.?,
    );
    try std.testing.expectEqual(@as(?usize, 3), uncapped.welcome_cut_line);

    runtime.max_transcript_bytes = summary.len;
    var source = try runtime.prepareTranscriptSource(alloc, summary_entry_id);
    defer source.deinit(alloc);

    try std.testing.expect(welcome.len + summary.len > runtime.max_transcript_bytes);
    try std.testing.expectEqualStrings(uncapped.bytes, source.bytes);
    try std.testing.expect(source.bytes.len > runtime.max_transcript_bytes);
    try std.testing.expectEqual(@as(usize, 1), source.folded_summary_indices.len);
    try std.testing.expectEqual(@as(usize, 4), source.folded_summary_indices[0]);
    try std.testing.expectEqual(@as(?usize, 3), source.tracked_entry_start_line);
    try std.testing.expectEqual(@as(u16, 6), source.preview.natural_visual_rows);
    try std.testing.expectEqual(
        transcript_blocks.LeadingWelcomeBoundary{
            .full_cut_line = 3,
            .tail_replay_line = 1,
        },
        source.welcome_boundary.?,
    );
    try std.testing.expectEqual(@as(?usize, 3), source.welcome_cut_line);
}

test "structured transcript source frees every partial allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkPrepareTranscriptSourceAllocationFailures,
        .{},
    );
}

fn checkPreviewPreparationFailureLeavesRuntimeUnchanged(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 10, 6),
        .owned_top_row = 1,
        .max_transcript_bytes = 128,
        .last_rendered_cols = 17,
    };
    defer runtime.deinit(alloc);
    try runtime.initBacking(alloc);

    const entry_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "recorded source\n",
        .subagent_status,
    );
    runtime.transcript.clearRetainingCapacity();
    try runtime.transcript.appendSlice(alloc, "poisoned cache\n");
    runtime.transcript_cache_origin_untrimmed = false;
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_entry_id = entry_id,
        .summary_transcript_index = 777,
    });
    runtime.transcript_band_dirty = false;
    runtime.paint_trace.transcript_initialized = true;
    runtime.paint_trace.transcript_start_line = 41;

    const entry_count = runtime.entries.items.len;
    const next_entry_id = runtime.next_entry_id;
    const commit_state = runtime.transcriptCommitDiagnostic();
    const paint_trace = runtime.paint_trace;
    const pending_repaints = runtime.render_requests.pendingReasonCount();

    _ = runtime.previewTranscriptFlow(alloc) catch |err| {
        try std.testing.expectEqualStrings("poisoned cache\n", runtime.transcript.items);
        try std.testing.expectEqual(entry_count, runtime.entries.items.len);
        try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());
        try std.testing.expectEqualStrings(
            "recorded source\n",
            runtime.entries.items[0].raw_bytes.bytes,
        );
        try std.testing.expectEqual(next_entry_id, runtime.next_entry_id);
        try std.testing.expectEqual(
            @as(usize, 777),
            runtime.folded_command_blocks.items[0].summary_transcript_index,
        );
        try std.testing.expectEqualDeep(commit_state, runtime.transcriptCommitDiagnostic());
        try std.testing.expectEqualDeep(paint_trace, runtime.paint_trace);
        try std.testing.expectEqual(
            pending_repaints,
            runtime.render_requests.pendingReasonCount(),
        );
        try std.testing.expect(!runtime.transcript_band_dirty);
        return err;
    };
}

test "preview preparation failure leaves cache entries anchors and repaint state unchanged" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkPreviewPreparationFailureLeavesRuntimeUnchanged,
        .{},
    );
}

test "tail-capped raw fallback rebases retained folded indices and invalidates removed summaries" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 10, 6),
        .owned_top_row = 1,
        .full_transcript = .{ .depth = .full },
    };
    defer runtime.deinit(alloc);

    try runtime.transcript.appendSlice(alloc, "removed-summary\nretained-summary");
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_transcript_index = 1,
    });
    try runtime.folded_command_blocks.append(alloc, .{
        .summary_transcript_index = 2,
    });
    try appendFoldedLineForTest(&runtime, alloc, 0, "removed-output");
    try appendFoldedLineForTest(&runtime, alloc, 1, "retained-output");

    runtime.max_transcript_bytes = "retained-summary".len + 1;
    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);

    try std.testing.expectEqualStrings("retained-summary", source.bytes);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 1 },
        source.folded_summary_indices,
    );

    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), prepared.total_lines);
    try std.testing.expectEqual(@as(usize, 1), prepared.visible_lines.items.len);
    try std.testing.expect(
        std.meta.activeTag(prepared.visible_lines.items[0]) == .folded_line,
    );
    try std.testing.expectEqualStrings(
        "retained-output",
        resolveVisibleLineForTest(
            prepared.visible_lines.items[0],
            .{ .bytes = prepared.bytes },
        ),
    );

    runtime.max_transcript_bytes = 4;
    var partial = try runtime.prepareTranscriptSource(alloc, null);
    defer partial.deinit(alloc);
    try std.testing.expectEqualStrings("mary", partial.bytes);
    try std.testing.expectEqualSlices(
        usize,
        &.{ 0, 0 },
        partial.folded_summary_indices,
    );

    var partial_paint = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &partial,
    );
    defer partial_paint.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), partial_paint.total_lines);
    try std.testing.expect(
        std.meta.activeTag(partial_paint.visible_lines.items[0]) == .transcript,
    );
    try std.testing.expectEqualStrings(
        "mary",
        resolveVisibleLineForTest(
            partial_paint.visible_lines.items[0],
            .{ .bytes = partial_paint.bytes },
        ),
    );
}

test "structured source keeps tracked entries before the cache tail" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 10, 6),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const removed_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "removed\n",
        .subagent_status,
    );
    const retained_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "tracked\n",
        .subagent_status,
    );
    runtime.max_transcript_bytes = "tracked".len + 1;

    var retained = try runtime.prepareTranscriptSource(alloc, retained_id);
    defer retained.deinit(alloc);
    try std.testing.expectEqualStrings("removed\ntracked", retained.bytes);
    try std.testing.expectEqual(@as(?usize, 1), retained.tracked_entry_start_line);

    var retained_paint = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &retained,
    );
    defer retained_paint.deinit(alloc);
    try std.testing.expectEqual(@as(?u16, 2), retained_paint.tracked_entry_row);

    var removed = try runtime.prepareTranscriptSource(alloc, removed_id);
    defer removed.deinit(alloc);
    try std.testing.expectEqual(@as(?usize, 0), removed.tracked_entry_start_line);

    var removed_paint = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &removed,
    );
    defer removed_paint.deinit(alloc);
    try std.testing.expectEqual(@as(?u16, 1), removed_paint.tracked_entry_row);

    runtime.max_transcript_bytes = 4;
    var partial = try runtime.prepareTranscriptSource(alloc, retained_id);
    defer partial.deinit(alloc);
    try std.testing.expectEqualStrings("removed\ntracked", partial.bytes);
    try std.testing.expectEqual(@as(?usize, 1), partial.tracked_entry_start_line);

    var partial_paint = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &partial,
    );
    defer partial_paint.deinit(alloc);
    try std.testing.expectEqual(@as(?u16, 2), partial_paint.tracked_entry_row);
}

test "structured source keeps welcome boundary before the cache tail" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 10, 6),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "welcome one\nwelcome two\n",
        .welcome,
    );
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "tail\n",
        .subagent_status,
    );

    var uncapped = try runtime.prepareTranscriptSource(alloc, null);
    defer uncapped.deinit(alloc);
    try std.testing.expectEqual(
        transcript_blocks.LeadingWelcomeBoundary{
            .full_cut_line = 3,
            .tail_replay_line = 1,
        },
        uncapped.welcome_boundary.?,
    );
    try std.testing.expectEqual(@as(?usize, 3), uncapped.welcome_cut_line);

    runtime.max_transcript_bytes = "tail".len + 1;
    var capped = try runtime.prepareTranscriptSource(alloc, null);
    defer capped.deinit(alloc);
    try std.testing.expectEqualStrings("welcome one\nwelcome two\n\ntail", capped.bytes);
    try std.testing.expectEqual(
        transcript_blocks.LeadingWelcomeBoundary{
            .full_cut_line = 3,
            .tail_replay_line = 1,
        },
        capped.welcome_boundary.?,
    );
    try std.testing.expectEqual(@as(?usize, 3), capped.welcome_cut_line);
}

test "structured source derives replaceable span from full bytes" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 5),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "prefix\n",
        .subagent_status,
    );
    _ = try runtime.appendReplaceableTranscriptLineSilentClassified(
        alloc,
        "0123456789",
        .subagent_status,
    );

    runtime.max_transcript_bytes = "0123456789".len + 1;
    var whole_tail = try runtime.prepareTranscriptSource(alloc, null);
    defer whole_tail.deinit(alloc);
    try std.testing.expectEqualStrings("prefix\n0123456789", whole_tail.bytes);
    try std.testing.expect(whole_tail.replaceable_last_line);
    try std.testing.expectEqual(@as(usize, "prefix\n".len), whole_tail.replaceable_start);

    runtime.max_transcript_bytes = 4;
    var partial_tail = try runtime.prepareTranscriptSource(alloc, null);
    defer partial_tail.deinit(alloc);
    try std.testing.expectEqualStrings("prefix\n0123456789", partial_tail.bytes);
    try std.testing.expect(partial_tail.replaceable_last_line);
    try std.testing.expectEqual(@as(usize, "prefix\n".len), partial_tail.replaceable_start);
    try std.testing.expect(partial_tail.preview.replaceable_active);

    var partial_paint = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &partial_tail,
    );
    defer partial_paint.deinit(alloc);
    try std.testing.expect(partial_paint.replaceable_last_line);
    try std.testing.expectEqual(@as(usize, "prefix\n".len), partial_paint.replaceable_start);
    try std.testing.expectEqual(@as(u16, 2), partial_paint.selection.replaceable_start_row);

    runtime.max_transcript_bytes = 0;
    var empty = try runtime.prepareTranscriptSource(alloc, null);
    defer empty.deinit(alloc);
    try std.testing.expectEqualStrings("prefix\n0123456789", empty.bytes);
    try std.testing.expect(empty.replaceable_last_line);
    try std.testing.expectEqual(@as(usize, "prefix\n".len), empty.replaceable_start);
    try std.testing.expectEqual(@as(u16, 2), empty.preview.natural_visual_rows);
    try std.testing.expectEqual(@as(u16, 0), empty.preview.trailing_boundary_blank_rows);
    try std.testing.expectEqual(@as(u16, 1), empty.preview.footer_boundary_gap_rows);
    try std.testing.expectEqual(
        @as(?transcript_blocks.TranscriptBlockKind, .subagent_status),
        empty.preview.tail_kind,
    );
    try std.testing.expect(empty.preview.replaceable_active);
}

test "structured source preview matches full paint geometry" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(4, 8, 5),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "removed-long\n",
        .subagent_status,
    );
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "tail\n\n",
        .subagent_status,
    );
    runtime.max_transcript_bytes = "tail".len + 1;

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqualStrings("removed-long\ntail", source.bytes);
    try std.testing.expectEqual(@as(u16, 4), source.preview.natural_visual_rows);
    try std.testing.expect(source.preview.trailing_boundary_blank_rows >= 1);
    try std.testing.expect(source.preview.footer_boundary_gap_rows >= 1);
    try std.testing.expectEqual(
        @as(?transcript_blocks.TranscriptBlockKind, .subagent_status),
        source.preview.tail_kind,
    );
    try std.testing.expect(!source.preview.replaceable_active);

    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);
    try std.testing.expect(prepared.total_lines >= 1);
    try std.testing.expect(prepared.sourceVisualRows().len > 0);

    const solved = render_engine.frame_layout.solve(.{
        .terminal = runtime.layout,
        .owned_top = runtime.owned_top_row,
        .footer = .{ .natural_rows = 2, .min_rows = 2, .max_rows = 2 },
        .transcript = source.preview,
    });
    try std.testing.expect(!solved.transcript_area.isEmpty());
}

test "hidden context notices do not change compact footer or activity tail policy" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    var metrics = Metrics{};
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "visible response");
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "context",
        .tone = .warning,
        .body = "hidden trailing context",
        .visibility = .full_only,
    });
    runtime.last_paint_bottom_reserved_rows = 2;

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, source.bytes, "hidden trailing context") == null);
    try std.testing.expectEqual(
        @as(?transcript_blocks.TranscriptBlockKind, .assistant_turn),
        source.preview.tail_kind,
    );
    try std.testing.expectEqual(@as(u16, 1), source.preview.footer_boundary_gap_rows);
    try std.testing.expectEqual(@as(u16, 1), runtime.transientAssistantGapRows());
    try std.testing.expectEqual(@as(u16, 2), runtime.preservedBottomReservationRows());

    var only_context = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 12, 8),
        .owned_top_row = 1,
    };
    defer only_context.deinit(alloc);
    _ = try only_context.appendSemanticNotice(alloc, .{
        .topic = "context",
        .tone = .warning,
        .body = "only hidden context",
        .visibility = .full_only,
    });
    only_context.last_paint_bottom_reserved_rows = 2;
    var empty_source = try only_context.prepareTranscriptSource(alloc, null);
    defer empty_source.deinit(alloc);
    try std.testing.expectEqualStrings("", empty_source.bytes);
    try std.testing.expectEqual(@as(?transcript_blocks.TranscriptBlockKind, null), empty_source.preview.tail_kind);
    try std.testing.expectEqual(@as(u16, 0), empty_source.preview.footer_boundary_gap_rows);
    try std.testing.expectEqual(@as(u16, 0), only_context.transientAssistantGapRows());
    try std.testing.expectEqual(@as(u16, 0), only_context.preservedBottomReservationRows());
}

test "recorded projection ignores a poisoned cache without rebuilding it" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "recorded first\n",
        .subagent_status,
    );
    const tracked_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "recorded tracked\n",
        .subagent_status,
    );
    runtime.transcript.clearRetainingCapacity();
    try runtime.transcript.appendSlice(alloc, "poisoned cache\n");
    runtime.transcript_cache_origin_untrimmed = false;

    const preview = try runtime.previewTranscriptFlow(alloc);
    try std.testing.expectEqual(@as(u16, 2), preview.natural_visual_rows);

    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintForAreaTrackingEntry(
        alloc,
        &metrics,
        .{ .top = 1, .bottom = 4 },
        tracked_id,
    );
    defer prepared.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, prepared.bytes, "recorded first") != null);
    try std.testing.expect(std.mem.find(u8, prepared.bytes, "recorded tracked") != null);
    try std.testing.expect(std.mem.find(u8, prepared.bytes, "poisoned cache") == null);
    try std.testing.expectEqual(@as(?u16, 2), prepared.tracked_entry_row);

    var shadow = try vt_emulator.Grid.init(
        alloc,
        runtime.layout.cols,
        runtime.layout.rows,
    );
    defer shadow.deinit();
    const plan = testPaintPlan(&runtime, prepared.selection);
    var surface = try render_engine.frame_surface.FrameSurface.initFromShadow(
        alloc,
        plan,
        shadow,
    );
    defer surface.deinit();
    _ = try runtime.paintPreparedTranscriptIntoSurface(
        alloc,
        &surface,
        &prepared,
    );
    var target = try surface.copyToTargetGrid(alloc);
    defer target.deinit();
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    try target.rowTextTrimmed(1, &row_text);
    try std.testing.expectEqualStrings("recorded first", row_text.items);
    row_text.clearRetainingCapacity();
    try target.rowTextTrimmed(2, &row_text);
    try std.testing.expectEqualStrings("recorded tracked", row_text.items);

    try std.testing.expectEqualStrings("poisoned cache\n", runtime.transcript.items);
}

test "cache-only paint excludes record false transient bytes" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 10, 6),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.transcript.appendSlice(alloc, "cache only\n");

    var metrics: Metrics = .{};
    try runtime.writeTranscript(alloc, &metrics, "transient only\n", false);
    try std.testing.expectEqual(@as(usize, 0), runtime.entries.items.len);
    try std.testing.expectEqualStrings("cache only\n", runtime.transcript.items);

    const preview = try runtime.previewTranscriptFlow(alloc);
    try std.testing.expectEqual(@as(u16, 1), preview.natural_visual_rows);
    var prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = 1, .bottom = 3 },
    );
    defer prepared.deinit(alloc);
    try std.testing.expectEqualStrings("cache only\n", prepared.bytes);
}

test "zero-column preparation uses cache fallback even when entries exist" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 10, 6),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "recorded source\n",
        .subagent_status,
    );
    runtime.transcript.clearRetainingCapacity();
    try runtime.transcript.appendSlice(alloc, "bootstrap cache\n");
    runtime.layout.cols = 0;

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqualStrings("bootstrap cache\n", source.bytes);
}

test "reconstructive paint repairs a poisoned cache from entries" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 10, 6),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "recorded reconstruction\n",
        .subagent_status,
    );
    runtime.transcript.clearRetainingCapacity();
    try runtime.transcript.appendSlice(alloc, "poisoned cache\n");

    var metrics: Metrics = .{};
    try runtime.reconstructivePaint(alloc, &metrics);

    try std.testing.expect(
        std.mem.find(u8, runtime.transcript.items, "recorded reconstruction") != null,
    );
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "poisoned cache") == null);
    try std.testing.expect(runtime.viewport_clear_pending);
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
}

test "append-only source remains compatible while tail replacement invalidates anchor" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    var metrics: Metrics = .{};
    try runtime.writeTranscript(alloc, &metrics, "stable", true);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        runtime.transcript.items,
        testSelection(0),
        0,
        1,
        7,
        19,
    );

    try runtime.writeTranscript(alloc, &metrics, " append", true);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    try std.testing.expect(runtime.stableTranscriptProjectionForFlow(runtime.transcript.items) != null);

    const tail_id = runtime.entries.items[runtime.entries.items.len - 1].id();
    try std.testing.expect(try runtime.updateRawBytesEntry(
        alloc,
        tail_id,
        " append extended",
    ));
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.invalid,
        runtime.transcriptCommitDiagnostic().state,
    );
}

test "prepared wrapped line delta creates visual-row inline scroll rows" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 8,
            .cols = 10,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .viewport_top_row = 1,
        .owned_top_row = 1,
        .cursor_row = 4,
        .cursor_col = 1,
        .has_painted_transcript = true,
        .has_committed_frame = true,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        "abcdefghijklmnopqrstuvwxyz\nshort\nend",
        testSelection(0),
        0,
        4,
        1,
        11,
    );

    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = 1, .bottom = 2 },
    );
    defer prepared.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), prepared.selection.start_line);
    try std.testing.expectEqual(@as(u16, 3), prepared.sourceVisualRows()[0]);

    const planned = runtime.planTranscriptScroll(&prepared).planned_rows;

    try std.testing.expectEqual(@as(u16, 3), planned);
}

test "prepareTranscriptSurfacePaintForArea keeps rows inside solved transcript rect" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 12,
            .cols = 40,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .viewport_top_row = 1,
        .owned_top_row = 1,
        .cursor_row = 8,
        .cursor_col = 1,
        .has_painted_transcript = true,
        .last_paint_bottom_reserved_rows = 3,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try runtime.transcript.appendSlice(alloc, "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\n");

    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = 3, .bottom = 5 },
    );
    defer prepared.deinit(alloc);

    try std.testing.expect(prepared.selection.top_row >= 3);
    try std.testing.expect(prepared.selection.bottom_row <= 5);
    try std.testing.expect(prepared.selection.last_visible_row <= 5);
    try std.testing.expectEqual(@as(u16, 0), prepared.bottom_reserved_rows);
    try std.testing.expectEqual(@as(u16, 3), runtime.last_paint_bottom_reserved_rows);
}

test "prepared transcript tracks an entry row without rerendering the selection" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 12,
            .cols = 40,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .viewport_top_row = 1,
        .owned_top_row = 1,
        .cursor_row = 8,
        .cursor_col = 1,
        .has_painted_transcript = true,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "first\n\n", .unknown_raw);
    const tracked_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "● Running command\x1b[0m\n",
        .tool_status,
    );

    var metrics: Metrics = .{};
    var visible = try runtime.prepareTranscriptSurfacePaintForAreaTrackingEntry(
        alloc,
        &metrics,
        .{ .top = 1, .bottom = 4 },
        tracked_id,
    );
    defer visible.deinit(alloc);
    try std.testing.expectEqual(@as(?u32, tracked_id), visible.tracked_entry_id);
    try std.testing.expectEqual(@as(?u16, 3), visible.tracked_entry_row);

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        _ = try runtime.appendRawTranscriptEntryClassified(alloc, "later\n", .unknown_raw);
    }

    var clipped = try runtime.prepareTranscriptSurfacePaintForAreaTrackingEntry(
        alloc,
        &metrics,
        .{ .top = 1, .bottom = 2 },
        tracked_id,
    );
    defer clipped.deinit(alloc);
    try std.testing.expectEqual(@as(?u32, tracked_id), clipped.tracked_entry_id);
    try std.testing.expectEqual(@as(?u16, null), clipped.tracked_entry_row);
}

test "prepared transcript source can omit one active entry without changing durable entries" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 12,
            .cols = 40,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "before\n", .subagent_status);
    const active_id = try runtime.appendRawTranscriptEntryClassified(alloc, "running\n", .subagent_status);
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "after\n", .subagent_status);

    var active = try runtime.prepareTranscriptSourceOmittingEntry(alloc, active_id);
    defer active.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, active.bytes, "running") == null);
    try std.testing.expect(std.mem.find(u8, active.bytes, "before") != null);
    try std.testing.expect(std.mem.find(u8, active.bytes, "after") != null);
    try std.testing.expect(!active.cache_origin_untrimmed);

    var terminal = try runtime.prepareTranscriptSource(alloc, null);
    defer terminal.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, terminal.bytes, "running") != null);
    try std.testing.expect(terminal.cache_origin_untrimmed);
}

test "prepareTranscriptSurfacePaintForArea does not update committed inline scroll baseline" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 12,
            .cols = 40,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .viewport_top_row = 4,
        .owned_top_row = 4,
        .cursor_row = 8,
        .cursor_col = 1,
        .has_painted_transcript = true,
        .has_committed_frame = true,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\n",
        testSelection(1),
        1,
        8,
        1,
        12,
    );
    const commit_before = runtime.transcriptCommitDiagnostic();

    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = 1, .bottom = 3 },
    );
    defer prepared.deinit(alloc);

    try std.testing.expectEqualDeep(commit_before, runtime.transcriptCommitDiagnostic());
    try std.testing.expectEqual(@as(u16, 4), runtime.owned_top_row);
    try std.testing.expectEqual(@as(u16, 4), runtime.viewport_top_row);
}

test "full transcript paint replaces the fold summary with captured lines" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 12, 8),
    };
    defer runtime.deinit(alloc);

    try runtime.transcript.appendSlice(alloc, "a\nsummary\nb\n");
    try runtime.folded_command_blocks.append(alloc, .{ .summary_transcript_index = 2 });
    try runtime.folded_command_blocks.items[0].lines.append(alloc, .{ .stream = .stdout, .text = try alloc.dupe(u8, "hidden-1") });
    try runtime.folded_command_blocks.items[0].lines.append(alloc, .{ .stream = .stderr, .text = try alloc.dupe(u8, "hidden-2") });
    runtime.full_transcript.depth = .full;

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        &source,
        .{ .top = 1, .bottom = 8 },
    );
    defer prepared.deinit(alloc);

    const source_buf = TranscriptBuffer{ .bytes = source.bytes };
    try std.testing.expectEqual(@as(usize, 4), prepared.visible_lines.items.len);
    try std.testing.expectEqualStrings("a", resolveVisibleLineForTest(prepared.visible_lines.items[0], source_buf));
    try std.testing.expect(std.meta.activeTag(prepared.visible_lines.items[1]) == .folded_line);
    try std.testing.expectEqualStrings("hidden-1", resolveVisibleLineForTest(prepared.visible_lines.items[1], source_buf));
    try std.testing.expect(std.meta.activeTag(prepared.visible_lines.items[2]) == .folded_line);
    try std.testing.expectEqualStrings("hidden-2", resolveVisibleLineForTest(prepared.visible_lines.items[2], source_buf));
    try std.testing.expectEqualStrings("b", resolveVisibleLineForTest(prepared.visible_lines.items[3], source_buf));
}

test "collapsed state still shows the fold summary" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 12, 8),
    };
    defer runtime.deinit(alloc);

    try runtime.transcript.appendSlice(alloc, "a\nsummary\nb\n");
    try runtime.folded_command_blocks.append(alloc, .{ .summary_transcript_index = 2 });
    try runtime.folded_command_blocks.items[0].lines.append(alloc, .{ .stream = .stdout, .text = try alloc.dupe(u8, "hidden-1") });

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        &source,
        .{ .top = 1, .bottom = 8 },
    );
    defer prepared.deinit(alloc);

    const source_buf = TranscriptBuffer{ .bytes = source.bytes };
    try std.testing.expectEqual(@as(usize, 3), prepared.visible_lines.items.len);
    try std.testing.expect(std.meta.activeTag(prepared.visible_lines.items[1]) == .transcript);
    try std.testing.expectEqualStrings("summary", resolveVisibleLineForTest(prepared.visible_lines.items[1], source_buf));
}

test "source-less surface paint keeps transcript lines one to one under full transcript" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    try runtime.transcript.appendSlice(alloc, "a\nsummary\nb\n");
    try runtime.folded_command_blocks.append(alloc, .{ .summary_transcript_index = 2 });
    runtime.full_transcript.depth = .full;

    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = 1, .bottom = 3 },
    );
    defer prepared.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), prepared.visible_lines.items.len);
    for (prepared.visible_lines.items) |line| {
        try std.testing.expect(std.meta.activeTag(line) == .transcript);
    }
}

test "record false command output remains transient" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(80, 12, 8) };
    defer runtime.deinit(alloc);
    var metrics = Metrics{};

    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        commandOutputTestStyles(),
        .stdout,
        "transient\n",
        false,
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    try std.testing.expectEqualStrings("transient", runtime.command_output_blocks.items[0].lines.items[0].text);
    try std.testing.expectEqual(@as(usize, 0), runtime.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript.items.len);

    try runtime.flushCommandOutputSummary(
        alloc,
        &metrics,
        commandOutputTestStyles(),
        false,
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.command_output_blocks.items.len);
    try std.testing.expect(runtime.command_output_display.open_command_block == null);
}

test "command output consolidation preserves committed prompt scrollback anchor" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const prompt = try alloc.dupe(u8, "give me a table of my system information");
    _ = try runtime.appendUserTurnOwned(alloc, .{
        .text = prompt,
        .images = &.{},
    });

    var live_entry_ids: [18]u32 = undefined;
    for (0..18) |index| {
        var line: [48]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "SYSTEM OUTPUT {d:0>2}\\n", .{index + 1});
        const bytes = try alloc.dupe(u8, text);
        live_entry_ids[index] = try runtime.appendRawBytesEntryClassified(
            alloc,
            bytes,
            .unknown_raw,
        );
    }

    const first_assistant_id = try runtime.appendAssistantTurnEntry(alloc);
    const first_assistant = runtime.lookupAssistantSegments(first_assistant_id) orelse
        return error.TestExpectedAssistantSegments;
    for (0..24) |index| {
        var line: [48]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "assistant table row {d}\n", .{index + 1});
        try first_assistant.text.appendSlice(alloc, text);
    }
    // The assistant content above is complete; report producer closure so
    // the finality floor does not hold the tail.
    runtime.transcript_release = runtime.transcript_release.with_assistant_tail_writable(false);

    var live_source = try runtime.prepareTranscriptSource(alloc, null);
    defer live_source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, live_source.bytes, "give me a table") != null);
    try std.testing.expect(std.mem.find(u8, live_source.bytes, "SYSTEM OUTPUT 01") != null);
    try std.testing.expect(std.mem.find(u8, live_source.bytes, "assistant table row 24") != null);
    var live_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &live_source,
    );
    defer live_prepared.deinit(alloc);
    try commitPreparedForTest(&runtime, alloc, &live_source, &live_prepared);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );

    try removeRawEntriesForTest(&runtime, alloc, &live_entry_ids);
    const compact_bytes = try alloc.dupe(
        u8,
        "SYSTEM OUTPUT 01\n... 16 command lines folded\nSYSTEM OUTPUT 18\n",
    );
    _ = try runtime.appendRawBytesEntryClassified(
        alloc,
        compact_bytes,
        .unknown_raw,
    );
    try runtime.rebuildTranscriptCacheAfterStructuredRewrite(
        alloc,
        "command output consolidation",
    );
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );

    var metrics = Metrics{};
    try runtime.writeTranscriptClassified(
        alloc,
        &metrics,
        "permission accepted\n",
        true,
        .subagent_status,
    );
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );

    const second_assistant_id = try runtime.appendAssistantTurnEntry(alloc);
    const second_assistant = runtime.lookupAssistantSegments(second_assistant_id) orelse
        return error.TestExpectedAssistantSegments;
    for (0..60) |index| {
        var line: [40]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "follow-up table row {d}\n", .{index + 1});
        try second_assistant.text.appendSlice(alloc, text);
    }

    var compact_source = try runtime.prepareTranscriptSource(alloc, null);
    defer compact_source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, compact_source.bytes, "give me a table") != null);
    try std.testing.expect(std.mem.find(u8, compact_source.bytes, "follow-up table row 60") != null);
    var compact_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &compact_source,
    );
    defer compact_prepared.deinit(alloc);
    const facts = runtime.planTranscriptScroll(&compact_prepared);
    try std.testing.expect(facts.target_visual_offset > facts.source_visual_offset);
    // The consolidation changed committed rows in place, so this frame has
    // no ability to materialize the held range: zero release, re-anchor on
    // the rewritten flow, and mark the finality debt.
    try std.testing.expect(!facts.source_compatible);
    try std.testing.expect(facts.recovery_rebase);
    try std.testing.expectEqual(@as(u32, 0), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), facts.planned_rows);
    try std.testing.expect(facts.finality_hold);
    try commitPreparedForTest(&runtime, alloc, &compact_source, &compact_prepared);

    // The following compatible frame settles the debt with final bytes.
    var settle_source = try runtime.prepareTranscriptSource(alloc, null);
    defer settle_source.deinit(alloc);
    var settle_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &settle_source,
    );
    defer settle_prepared.deinit(alloc);
    const settle_facts = runtime.planTranscriptScroll(&settle_prepared);
    try std.testing.expect(settle_facts.source_compatible);
    try std.testing.expect(settle_facts.semantic_rows > 0);
    try std.testing.expect(settle_facts.planned_rows > 0);
}

fn removeRawEntriesForTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    ids: []const u32,
) !void {
    for (ids) |id| {
        var index: usize = 0;
        while (index < runtime.entries.items.len) : (index += 1) {
            const entry = runtime.entries.items[index];
            if (entry == .raw_bytes and entry.raw_bytes.id == id) {
                var removed = runtime.entries.orderedRemove(index);
                removed.deinit(alloc);
                break;
            }
        } else return error.TestExpectedRawEntry;
    }
}

test "command output stores terminal-safe text for live consolidated and full transcript views" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();
    const raw = "\x1b[2JCSI_CLEAR_TOKEN\x1b[31mCSI_SGR_TOKEN\x1b[0m\r\x08\x07\x7f\n";
    const safe = "\\x08\\x07\\x7f";

    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, raw, true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stderr, "unterminated-final", true);

    try std.testing.expectEqualStrings(safe, runtime.command_output_blocks.items[0].lines.items[0].text);
    try std.testing.expectEqualStrings("unterminated-final", runtime.command_output_blocks.items[0].lines.items[1].text);

    const live = try renderEntriesToBytes(alloc, runtime.entries.items, 80);
    defer alloc.free(live);
    try std.testing.expect(std.mem.find(u8, live, safe) != null);
    try std.testing.expect(std.mem.find(u8, live, "\x1b[2JCSI_CLEAR_TOKEN") == null);

    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    const consolidated = try renderEntriesToBytes(alloc, runtime.entries.items, 80);
    defer alloc.free(consolidated);
    try std.testing.expect(std.mem.find(u8, consolidated, safe) != null);
    try std.testing.expect(std.mem.find(u8, consolidated, "\x1b[2JCSI_CLEAR_TOKEN") == null);

    runtime.has_committed_frame = true;
    runtime.owned_top_row = 5;
    try std.testing.expect(try runtime.setTranscriptPresentationDepth(alloc, .full));
    var projection = try full_transcript_screen.buildProjection(
        alloc,
        runtime.entries.items,
        runtime.tool_details.items,
        runtime.command_output_blocks.items,
        runtime.command_output_render.styles,
        runtime.layout.cols,
        runtime.fullTranscriptAnchorEntryId(),
    );
    defer projection.deinit(alloc);
    const source_bytes = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        16,
        0,
        null,
    );
    var source = try runtime.prepareFullTranscriptViewportSource(alloc, source_bytes);
    defer source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, source.bytes, safe) != null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "\x1b[2JCSI_CLEAR_TOKEN") == null);
}

test "command output keeps capped and folded transcript behavior" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();

    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "line-one\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stderr, "line-two\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "line-three\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "line-four\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "line-five\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "line-six\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "line-seven\n", true);
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);

    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 7), runtime.command_output_blocks.items[0].lines.items.len);
    try std.testing.expectEqualStrings("line-one", runtime.command_output_blocks.items[0].lines.items[0].text);
    try std.testing.expectEqualStrings("line-seven", runtime.command_output_blocks.items[0].lines.items[6].text);
}

test "command output state keeps one authoritative folded hint" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);
    var metrics = Metrics{};
    const styles = commandOutputTestStyles();

    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "fast-1\nfast-2\nfast-3\nfast-4\nfast-5\nfast-6\n",
        true,
    );
    const old_hint_entry_id = runtime.command_output_blocks.items[0].lines.items[5].entry_id.?;
    try expectRawEntryBytes(
        &runtime,
        old_hint_entry_id,
        "│ … 1 line more (ctrl o to view)",
    );

    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "fast-7\nfast-8\n",
        true,
    );
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 8), block.total_lines);
    try std.testing.expectEqual(@as(usize, 8), block.lines.items.len);
    const newest_entry_id = block.lines.items[7].entry_id.?;
    try expectRawEntryBytes(
        &runtime,
        old_hint_entry_id,
        "│ … 1 line more (ctrl o to view)",
    );
    try expectRawEntryBytes(&runtime, newest_entry_id, "");

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), source.bytes.len);
}

test "command output consolidation replaces live row before following transcript rows" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();

    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "before\n", .subagent_status);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "middle\n", true);
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "after\n", .subagent_status);

    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);

    const before_pos = std.mem.indexOf(u8, source.bytes, "before") orelse
        return error.MissingBeforeRow;
    const after_pos = std.mem.indexOf(u8, source.bytes, "after") orelse
        return error.MissingAfterRow;

    try std.testing.expect(before_pos < after_pos);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "middle") == null);
    try std.testing.expectEqualStrings("middle", runtime.command_output_blocks.items[0].lines.items[0].text);
}

test "command output consolidation preserves rows between noncontiguous live rows" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();

    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "before\n", .subagent_status);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "command-one\n", true);
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "intervening\n", .subagent_status);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "command-two\n", true);
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "after\n", .subagent_status);

    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);

    const before_pos = std.mem.indexOf(u8, source.bytes, "before") orelse
        return error.MissingBeforeRow;
    const intervening_pos = std.mem.indexOf(u8, source.bytes, "intervening") orelse
        return error.MissingInterveningRow;
    const after_pos = std.mem.indexOf(u8, source.bytes, "after") orelse
        return error.MissingAfterRow;

    try std.testing.expect(before_pos < intervening_pos);
    try std.testing.expect(intervening_pos < after_pos);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "command-one") == null);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "command-two") == null);
    try std.testing.expectEqualStrings("command-one", runtime.command_output_blocks.items[0].lines.items[0].text);
    try std.testing.expectEqualStrings("command-two", runtime.command_output_blocks.items[0].lines.items[1].text);
}

test "command output folding preserves rows between noncontiguous live rows" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();

    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "before\n", .subagent_status);
    for (0..5) |index| {
        var line: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "command-visible-{d}\n", .{index + 1});
        try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, text, true);
    }
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "intervening\n", .subagent_status);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "command-two\n", true);
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "after\n", .subagent_status);

    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);

    const before_pos = std.mem.indexOf(u8, source.bytes, "before") orelse
        return error.MissingBeforeRow;
    const intervening_pos = std.mem.indexOf(u8, source.bytes, "intervening") orelse
        return error.MissingInterveningRow;
    const after_pos = std.mem.indexOf(u8, source.bytes, "after") orelse
        return error.MissingAfterRow;

    try std.testing.expect(before_pos < intervening_pos);
    try std.testing.expect(intervening_pos < after_pos);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "command-visible-1") == null);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "ctrl o to view") == null);
    try std.testing.expectEqual(@as(usize, 6), runtime.command_output_blocks.items[0].lines.items.len);
}

test "partial command records remain durable across an intervening notice" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);
    runtime.layout.cols = 16;

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();
    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "first record wraps across many physical rows and remains intentionally long",
        true,
    );
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "intervening-notice\n", .subagent_status);
    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "\nlater-hidden-record\n",
        true,
    );

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    const notice_pos = std.mem.find(u8, source.bytes, "intervening-notice") orelse
        return error.MissingInterveningRow;
    try std.testing.expect(notice_pos < source.bytes.len);
    try std.testing.expect(std.mem.find(u8, source.bytes, "first record") == null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "later-hidden-record") == null);
    try std.testing.expectEqual(@as(usize, 2), runtime.command_output_blocks.items[0].lines.items.len);
    try std.testing.expect(std.mem.find(u8, runtime.command_output_blocks.items[0].lines.items[0].text, "first record") != null);
    try std.testing.expectEqualStrings("later-hidden-record", runtime.command_output_blocks.items[0].lines.items[1].text);
}

test "production command pruning preserves deferred replay around a notice" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);
    var metrics = Metrics{};
    const styles = commandOutputTestStyles();

    const status_entry_id = try transcript_store.appendPinnedToolStatusAtomic(
        &runtime,
        alloc,
        "● Ran printf ordered-output\n",
    );
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "output-0\n", true);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "intervening-notice\n",
        .subagent_status,
    );
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "output-1\n", true);
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    try runtime.attachHistoricalToolDetailAfterCommandOutput(
        alloc,
        status_entry_id,
        .{
            .id = "ordered-output",
            .name = "run_command",
            .arguments_json = "{\"command\":\"printf ordered-output\"}",
        },
        .command,
        .{
            .tool_call_id = @constCast("ordered-output"),
            .tool_name = @constCast("run_command"),
            .status = .success,
            .output = @constCast("exit_code=0\n<stdout>\noutput-0\noutput-1\n</stdout>\n"),
            .output_bytes = "exit_code=0\n<stdout>\noutput-0\noutput-1\n</stdout>\n".len,
            .stored_output_bytes = "exit_code=0\n<stdout>\noutput-0\noutput-1\n</stdout>\n".len,
        },
    );
    const pruned_source_entry_id = runtime.command_output_blocks.items[0].lines.items[1].entry_id.?;

    try std.testing.expect(try command_output_runtime.trimRetainedCommandOutputLine(
        &runtime,
        alloc,
        0,
        1,
    ));
    _ = try command_output_runtime.syncCommandOutputBlockEntries(&runtime, alloc);
    try runtime.rebuildTranscriptCacheAfterStructuredRewrite(alloc, "test command prune");
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items[0].pruned_ranges.items.len);
    try std.testing.expectEqual(
        pruned_source_entry_id,
        runtime.command_output_blocks.items[0].pruned_ranges.items[0].anchor_entry_id,
    );

    var compact = try runtime.prepareTranscriptSource(alloc, null);
    defer compact.deinit(alloc);
    const compact_notice_pos = std.mem.find(u8, compact.bytes, "intervening-notice") orelse
        return error.MissingInterveningRow;
    try std.testing.expect(compact_notice_pos < compact.bytes.len);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "output-0") == null);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "output-1") == null);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "ctrl o to view") == null);

    runtime.full_transcript.depth = .full;
    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const source = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        64,
        0,
        null,
    );
    defer alloc.free(source);
    const output_0_pos = std.mem.find(u8, source, "output-0") orelse
        return error.MissingFirstCommandOutputRow;
    const notice_pos = std.mem.find(u8, source, "intervening-notice") orelse
        return error.MissingInterveningRow;
    const output_1_pos = std.mem.find(u8, source, "output-1") orelse
        return error.MissingSecondCommandOutputRow;
    try std.testing.expect(output_0_pos < notice_pos);
    try std.testing.expect(notice_pos < output_1_pos);
}

test "production all-pruned command keeps process and hint at final anchor" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);
    var metrics = Metrics{};
    const styles = commandOutputTestStyles();

    const status_entry_id = try transcript_store.appendPinnedToolStatusAtomic(
        &runtime,
        alloc,
        "● Ran printf all-pruned\n",
    );
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "pruned-0\n", true);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "pruned-separator\n",
        .subagent_status,
    );
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "pruned-1\n", true);
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    try runtime.attachHistoricalToolDetailAfterCommandOutput(
        alloc,
        status_entry_id,
        .{
            .id = "all-pruned",
            .name = "run_command",
            .arguments_json = "{\"command\":\"printf all-pruned\"}",
        },
        .command,
        .{
            .tool_call_id = @constCast("all-pruned"),
            .tool_name = @constCast("run_command"),
            .status = .success,
            .output = @constCast("exit_code=7\n<stdout>\npruned-0\npruned-1\n</stdout>\n"),
            .output_bytes = "exit_code=7\n<stdout>\npruned-0\npruned-1\n</stdout>\n".len,
            .stored_output_bytes = "exit_code=7\n<stdout>\npruned-0\npruned-1\n</stdout>\n".len,
            .command_process_presentation = .{ .exit_code = 7 },
        },
    );
    const final_anchor = runtime.command_output_blocks.items[0].lines.items[1].entry_id.?;

    try std.testing.expect(try command_output_runtime.trimRetainedCommandOutputLine(
        &runtime,
        alloc,
        0,
        0,
    ));
    try std.testing.expect(try command_output_runtime.trimRetainedCommandOutputLine(
        &runtime,
        alloc,
        0,
        0,
    ));
    try std.testing.expectEqual(@as(usize, 0), runtime.command_output_blocks.items[0].lines.items.len);
    try std.testing.expectEqual(@as(usize, 2), runtime.command_output_blocks.items[0].pruned_ranges.items.len);
    _ = try command_output_runtime.syncCommandOutputBlockEntries(&runtime, alloc);
    try runtime.rebuildTranscriptCacheAfterStructuredRewrite(alloc, "test all-pruned command");

    var final_anchor_bytes: ?[]const u8 = null;
    for (runtime.entries.items) |entry| {
        if (entry.id() != final_anchor or entry != .raw_bytes) continue;
        final_anchor_bytes = entry.raw_bytes.bytes;
        break;
    }
    const final = final_anchor_bytes orelse return error.MissingFinalCommandAnchor;
    try std.testing.expect(std.mem.find(u8, final, "│ exit code 7") != null);
    try std.testing.expect(std.mem.find(u8, final, "│ … 2 lines more") != null);

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    const notice_pos = std.mem.find(u8, source.bytes, "pruned-separator") orelse
        return error.MissingInterveningRow;
    try std.testing.expect(notice_pos < source.bytes.len);
    try std.testing.expect(std.mem.find(u8, source.bytes, "│ exit code 7") == null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "│ … 2 lines more") == null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "pruned-0") == null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "pruned-1") == null);
}

test "pruned command ranges bridge after their separator is retained then removed" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);
    var metrics = Metrics{};
    const styles = commandOutputTestStyles();

    const status_entry_id = try transcript_store.appendPinnedToolStatusAtomic(
        &runtime,
        alloc,
        "● Ran printf ranges\n",
    );
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "range-0\nrange-1\n", true);
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "range-separator\n", .subagent_status);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "range-2\nrange-3\n", true);
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    try runtime.attachHistoricalToolDetailAfterCommandOutput(
        alloc,
        status_entry_id,
        .{ .id = "ranges", .name = "run_command", .arguments_json = "{\"command\":\"printf ranges\"}" },
        .command,
        .{
            .tool_call_id = @constCast("ranges"),
            .tool_name = @constCast("run_command"),
            .status = .success,
            .output = @constCast("exit_code=0\n<stdout>\nrange-0\nrange-1\nrange-2\nrange-3\n</stdout>\n"),
            .output_bytes = "exit_code=0\n<stdout>\nrange-0\nrange-1\nrange-2\nrange-3\n</stdout>\n".len,
            .stored_output_bytes = "exit_code=0\n<stdout>\nrange-0\nrange-1\nrange-2\nrange-3\n</stdout>\n".len,
        },
    );

    while (runtime.command_output_blocks.items[0].lines.items.len > 0) {
        try std.testing.expect(try command_output_runtime.trimRetainedCommandOutputLine(
            &runtime,
            alloc,
            0,
            0,
        ));
    }
    try std.testing.expectEqual(@as(usize, 2), runtime.command_output_blocks.items[0].pruned_ranges.items.len);

    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    runtime.max_retained_transcript_bytes = retained_before - 1;
    try runtime.enforceStructuredRetention(alloc, null);
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items[0].pruned_ranges.items.len);
    const range = runtime.command_output_blocks.items[0].pruned_ranges.items[0];
    try std.testing.expectEqual(@as(usize, 0), range.start_record);
    try std.testing.expectEqual(@as(usize, 4), range.end_record);
    try std.testing.expect(
        transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes,
    );
}

test "command output detail retargets when first split source row is pruned" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();
    const lifecycle_id = types.ToolLifecycleId{ .turn_id = 3, .call_id = "split-prune" };

    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = lifecycle_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"printf split\"}",
    } });
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, lifecycle_id, .stdout, "command-one\n", true);
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "intervening\n", .subagent_status);
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, lifecycle_id, .stdout, "command-two\n", true);
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, lifecycle_id, true);
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = lifecycle_id,
        .outcome = .{ .kind = .completed, .summary = "Ran printf split" },
    } });

    const status_entry_id = runtime.toolActivityRecord(lifecycle_id).?.entry_id;
    const first_source_id = runtime.command_output_blocks.items[0].source_entry_ids.items[0];
    const second_source_id = runtime.command_output_blocks.items[0].source_entry_ids.items[1];
    try std.testing.expectEqual(first_source_id, runtime.toolDetailForEntry(status_entry_id).?.command_output_entry_id.?);

    for (runtime.entries.items, 0..) |entry, entry_index| {
        if (entry.id() != first_source_id) continue;
        var removed = runtime.entries.orderedRemove(entry_index);
        removed.deinit(alloc);
        break;
    }

    try runtime.enforceStructuredRetention(alloc, second_source_id);

    try std.testing.expectEqual(second_source_id, runtime.command_output_blocks.items[0].entry_id.?);
    try std.testing.expectEqual(second_source_id, runtime.toolDetailForEntry(status_entry_id).?.command_output_entry_id.?);
    try std.testing.expectEqual(status_entry_id, runtime.detailEntryIdForCommandOutputSource(second_source_id).?);
}

test "command output retains records within the compact storage limit" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();

    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "retained-one\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stderr, "retained-two\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "retained-three\n", true);
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);

    try std.testing.expectEqual(@as(usize, 0), runtime.folded_command_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 3), runtime.entries.items.len);
    try std.testing.expectEqual(@as(usize, 3), runtime.command_output_blocks.items[0].lines.items.len);
    try std.testing.expectEqualStrings("retained-one", runtime.command_output_blocks.items[0].lines.items[0].text);
    try std.testing.expectEqualStrings("retained-two", runtime.command_output_blocks.items[0].lines.items[1].text);
    try std.testing.expectEqualStrings("retained-three", runtime.command_output_blocks.items[0].lines.items[2].text);
}

test "command output entries are classified" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();

    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "line one\n", true);
    try std.testing.expect(runtime.entries.items.len > 0);
    try std.testing.expectEqual(RawEntryClass.command_output, runtime.entries.items[runtime.entries.items.len - 1].raw_bytes.class);

    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);

    try std.testing.expect(runtime.entries.items.len > 0);
    try std.testing.expectEqual(RawEntryClass.command_output, runtime.entries.items[runtime.entries.items.len - 1].raw_bytes.class);
}

test "pre-flush live command output chunks match consolidated row geometry" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputAnsiTestStyles();

    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "one\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stderr, "two\n", true);

    const live = try renderEntriesToBytes(alloc, runtime.entries.items, 80);
    defer alloc.free(live);

    try std.testing.expect(std.mem.find(u8, live, "\x1b[2m│ one\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, live, "\x1b[2m│ two\x1b[0m") != null);
    try std.testing.expect(std.mem.find(u8, live, "\x1b[31m") == null);

    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    const consolidated = try renderEntriesToBytes(alloc, runtime.entries.items, 80);
    defer alloc.free(consolidated);

    try std.testing.expectEqualStrings(live, consolidated);
}

test "concurrent command output lifecycles remain isolated" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();
    const active_id = types.ToolLifecycleId{ .turn_id = 7, .call_id = "active-command" };
    const foreign_id = types.ToolLifecycleId{ .turn_id = 7, .call_id = "foreign-command" };

    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, active_id, .stdout, "active-one\n", true);
    try runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        foreign_id,
        .stderr,
        "foreign\n",
        true,
    );
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, foreign_id, true);

    try std.testing.expect(runtime.command_output_display.open_command_block == null);
    try std.testing.expectEqual(@as(usize, 2), runtime.command_output_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items[0].lines.items.len);
    try std.testing.expectEqualStrings("active-one", runtime.command_output_blocks.items[0].lines.items[0].text);
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items[1].lines.items.len);
    try std.testing.expectEqualStrings("foreign", runtime.command_output_blocks.items[1].lines.items[0].text);

    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, active_id, .stderr, "active-two\n", true);
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, active_id, true);

    try std.testing.expect(runtime.command_output_display.open_command_block == null);
    try std.testing.expectEqual(@as(usize, 2), runtime.command_output_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 2), runtime.command_output_blocks.items[0].lines.items.len);
    try std.testing.expectEqual(command_output_content.Stream.stdout, runtime.command_output_blocks.items[0].lines.items[0].stream);
    try std.testing.expectEqual(command_output_content.Stream.stderr, runtime.command_output_blocks.items[0].lines.items[1].stream);
    try std.testing.expectEqualStrings("active-one", runtime.command_output_blocks.items[0].lines.items[0].text);
    try std.testing.expectEqualStrings("active-two", runtime.command_output_blocks.items[0].lines.items[1].text);
    try std.testing.expectEqualStrings("foreign", runtime.command_output_blocks.items[1].lines.items[0].text);
}

test "command output display caps at five physical rows" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 21,
            .divider_top_row = 22,
            .input_row = 23,
            .divider_bottom_row = 24,
            .hint_row = 22,
        },
    };
    defer runtime.deinit(std.testing.allocator);

    var metrics = Metrics{};
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };

    var line_index: usize = 0;
    while (line_index < 26) : (line_index += 1) {
        const line = try std.fmt.allocPrint(std.testing.allocator, "line-{d}\n", .{line_index});
        defer std.testing.allocator.free(line);
        try runtime.writeCommandOutputChunk(std.testing.allocator, &metrics, styles, .stdout, line, true);
    }
    try runtime.flushCommandOutputSummary(std.testing.allocator, &metrics, styles, true);

    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 26), runtime.command_output_blocks.items[0].lines.items.len);
    var projection = try command_output_runtime.renderCompactCommandOutput(
        std.testing.allocator,
        runtime.command_output_blocks.items[0],
        .{ .styles = styles },
        80,
    );
    defer projection.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, projection.bytes.items, "│ line-"));
    try std.testing.expect(std.mem.find(u8, projection.bytes.items, "│ line-4") != null);
    try std.testing.expect(std.mem.find(u8, projection.bytes.items, "│ line-5") == null);
    try std.testing.expect(std.mem.find(u8, projection.bytes.items, "│ … 21 lines more (ctrl o to view)") != null);
}

test "structured retention prunes old raw transcript entries past cap" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
        .max_transcript_bytes = 128,
        .max_retained_transcript_bytes = 32,
    };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    try runtime.initViewport(&metrics, 1);
    try runtime.writeTranscript(alloc, &metrics, "raw-one-12345\n", true);
    try runtime.writeTranscript(alloc, &metrics, "raw-two-12345\n", true);
    try runtime.writeTranscript(alloc, &metrics, "raw-three-123\n", true);

    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes);
    try std.testing.expect(runtime.entries.items.len < 3);
    try std.testing.expect(std.mem.indexOf(u8, runtime.transcript.items, "raw-one") == null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.transcript.items, "raw-three") != null);
}

test "structured retention compacts a large pruning pass in entry order" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
        .max_transcript_bytes = 4096,
        .max_retained_transcript_bytes = std.math.maxInt(usize),
    };
    defer runtime.deinit(alloc);

    for (0..2048) |index| {
        const line = try std.fmt.allocPrint(alloc, "retained-entry-{d:0>4}\n", .{index});
        _ = runtime.appendRawBytesEntryClassified(alloc, line, .unknown_raw) catch |err| {
            alloc.free(line);
            return err;
        };
    }

    runtime.max_retained_transcript_bytes = 1024;
    try runtime.enforceStructuredRetention(alloc, null);

    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) <= 1024);
    try std.testing.expect(runtime.entries.items.len < 2048);
    try std.testing.expect(runtime.entries.items.len > 0);
    for (runtime.entries.items[1..], runtime.entries.items[0 .. runtime.entries.items.len - 1]) |entry, previous| {
        try std.testing.expect(previous.id() < entry.id());
    }
    try std.testing.expect(std.mem.indexOf(u8, runtime.transcript.items, "retained-entry-0000") == null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.transcript.items, "retained-entry-2047") != null);
}

test "assistant streaming retention trims active segment text" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
        .max_transcript_bytes = 128,
        .max_retained_transcript_bytes = 32,
    };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    try runtime.initViewport(&metrics, 1);
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "aaaaaaaaaaaaaaaa\n");
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "bbbbbbbbbbbbbbbb\n");
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "cccccccccccccccc\n");

    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .assistant_turn);
    const text = runtime.entries.items[0].assistant_turn.segments.text.items;
    try std.testing.expect(text.len <= runtime.max_retained_transcript_bytes);
    try std.testing.expect(std.mem.indexOf(u8, text, "cccccccc") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "aaaaaaaa") == null);
    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes);
}

test "hidden command output becomes count-only at the hard cap" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
        .max_transcript_bytes = 512,
    };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();
    const retained_lines = [_][]const u8{
        "line-00\n",
        "line-01\n",
        "line-02\n",
        "line-03\n",
        "line-04\n",
        "line-05\n",
    };
    for (retained_lines, 0..) |line, index| {
        const stream: command_output_content.Stream = if (index % 2 == 0) .stdout else .stderr;
        try runtime.writeCommandOutputChunk(alloc, &metrics, styles, stream, line, true);
    }

    runtime.max_retained_transcript_bytes = transcript_store.retainedStructuredBytes(&runtime);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "line-06\n", true);

    try std.testing.expectEqual(@as(usize, 6), runtime.command_output_blocks.items[0].lines.items.len);
    try std.testing.expectEqualStrings("line-00", runtime.command_output_blocks.items[0].lines.items[0].text);
    try std.testing.expect(std.mem.find(u8, runtime.command_output_blocks.items[0].lines.items[5].text, "line-06") == null);
    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try runtime.writeCommandOutputChunk(
        failing.allocator(),
        &metrics,
        styles,
        .stderr,
        "line-07\n",
        true,
    );
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);

    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 8), block.total_lines);
    const expected_summary = try std.fmt.allocPrint(
        alloc,
        "│ … {d} lines more (ctrl o to view)",
        .{block.total_lines - @min(@as(usize, 5), block.lines.items.len)},
    );
    defer alloc.free(expected_summary);
    var projection = try command_output_runtime.renderCompactCommandOutput(
        alloc,
        block,
        .{ .styles = styles },
        80,
    );
    defer projection.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, projection.bytes.items, expected_summary) != null);
    var retained_text_bytes: usize = 0;
    for (block.lines.items) |line| retained_text_bytes += line.text.len;
    try std.testing.expectEqual(retained_text_bytes, block.retained_text_bytes);

    _ = try runtime.streamAssistantChunk(alloc, &metrics, "assistant after cap");
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "assistant after cap") != null);
}

test "command output becomes count-only at the hard cap" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
        .max_transcript_bytes = 512,
    };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "line-00\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stderr, "line-01\n", true);

    runtime.max_retained_transcript_bytes = transcript_store.retainedStructuredBytes(&runtime);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "line-02\n", true);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try runtime.writeCommandOutputChunk(
        failing.allocator(),
        &metrics,
        styles,
        .stderr,
        "line-03\n",
        true,
    );

    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 4), block.total_lines);
    try std.testing.expect(block.lines.items.len < block.total_lines);
    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes);
}

test "blank hidden command output becomes count-only at the hard cap" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
        .max_transcript_bytes = 256,
        .max_retained_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();
    for (0..8) |_| {
        try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "\n", true);
    }

    const block = &runtime.command_output_blocks.items[0];
    try std.testing.expect(block.lines.items.len < block.total_lines);
    try std.testing.expectEqual(@as(usize, 8), block.total_lines);
    try std.testing.expectEqual(@as(usize, 0), block.retained_text_bytes);
    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try runtime.writeCommandOutputChunk(
        failing.allocator(),
        &metrics,
        styles,
        .stderr,
        "\n",
        true,
    );
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 9), block.total_lines);
}

test "command output lines count toward structured retention" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
        .max_transcript_bytes = 256,
        .max_retained_transcript_bytes = 512,
    };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "hidden-command-line\n", true);
    }
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);

    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    try std.testing.expect(runtime.command_output_blocks.items[0].entry_id != null);
    try std.testing.expect(runtime.command_output_blocks.items[0].lines.items.len < 6);
    try std.testing.expectEqual(@as(usize, 6), runtime.command_output_blocks.items[0].total_lines);
    var retained_text_bytes: usize = 0;
    for (runtime.command_output_blocks.items[0].lines.items) |line| retained_text_bytes += line.text.len;
    try std.testing.expectEqual(retained_text_bytes, runtime.command_output_blocks.items[0].retained_text_bytes);
    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes);
}

test "structured retention prunes old command output block state" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
        .max_transcript_bytes = 256,
        .max_retained_transcript_bytes = 260,
    };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles = commandOutputTestStyles();

    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "old-command-output-line-that-should-prune\n", true);
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);

    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "new-command-output-line-that-should-remain\n", true);
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);

    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items[0].lines.items.len);
    try std.testing.expect(std.mem.find(u8, runtime.command_output_blocks.items[0].lines.items[0].text, "new-command-output") != null);
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "old-command-output") == null);
    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes);
}

test "resize preparation uses retained entries after pruning without rewriting cache" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
        .max_transcript_bytes = 128,
        .max_retained_transcript_bytes = 40,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    var metrics = Metrics{};
    try runtime.initViewport(&metrics, 1);
    try runtime.writeTranscript(alloc, &metrics, "old-entry-that-will-prune\n", true);
    try runtime.writeTranscript(alloc, &metrics, "latest-entry-stays\n", true);

    const cache_before = try alloc.dupe(u8, runtime.transcript.items);
    defer alloc.free(cache_before);
    const rendered_cols_before = runtime.last_rendered_cols;

    runtime.layout.cols = 20;
    var prepared = try runtime.prepareTranscriptSurfacePaint(alloc, &metrics, 0);
    defer prepared.deinit(alloc);

    try std.testing.expectEqual(rendered_cols_before, runtime.last_rendered_cols);
    try std.testing.expectEqualStrings(cache_before, runtime.transcript.items);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "latest-entry-stays") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.bytes, "old-entry") == null);
}

test "clearTranscript after retention pruning frees retained entries and command output blocks" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{ .rows = 24, .cols = 80, .content_bottom = 21, .divider_top_row = 22, .input_row = 23, .divider_bottom_row = 24, .hint_row = 22 },
        .max_transcript_bytes = 128,
        .max_retained_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };

    try runtime.writeTranscript(alloc, &metrics, "first-entry-to-prune\n", true);
    try runtime.writeTranscript(alloc, &metrics, "second-entry-to-keep\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "hidden-command-line\n", true);
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes);

    runtime.clearTranscript(alloc);

    try std.testing.expectEqual(@as(usize, 0), runtime.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.folded_command_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.command_output_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), transcript_store.retainedStructuredBytes(&runtime));

    const after = try alloc.dupe(u8, "after-clear\n");
    const id = try runtime.appendRawBytesEntry(alloc, after);
    try std.testing.expect(id > 0);
}

test "recomputeCursorFromTranscript respects resized width" {
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 6,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    };
    defer runtime.deinit(std.testing.allocator);

    try runtime.transcript.appendSlice(std.testing.allocator, "hello world\nabc");
    runtime.cursor_row = 99;
    runtime.cursor_col = 99;

    runtime.recomputeCursorFromTranscript();

    try std.testing.expectEqual(@as(u16, 3), runtime.cursor_row);
    try std.testing.expectEqual(@as(u16, 4), runtime.cursor_col);
}

test "recomputeCursorFromTranscript skips ANSI in styled rows" {
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    };
    defer runtime.deinit(std.testing.allocator);

    const bar_row = "\x1b[48;5;235m\x1b[39m❯ hello\x1b[0m";
    try runtime.transcript.appendSlice(std.testing.allocator, bar_row);

    runtime.cursor_row = 99;
    runtime.cursor_col = 99;
    runtime.recomputeCursorFromTranscript();

    try std.testing.expectEqual(@as(u16, 8), runtime.cursor_col);
}

test "replaceTrailingTranscriptLine updates latest replaceable line" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 21,
            .divider_top_row = 22,
            .input_row = 23,
            .divider_bottom_row = 24,
            .hint_row = 22,
        },
    };
    defer runtime.deinit(std.testing.allocator);

    var metrics = Metrics{};
    try runtime.writeTranscript(std.testing.allocator, &metrics, "started\n", true);
    _ = try runtime.appendReplaceableTranscriptLine(std.testing.allocator, &metrics, "progress one\n");
    try std.testing.expect(try runtime.replaceTrailingTranscriptLine(std.testing.allocator, &metrics, "progress two\n"));
    try std.testing.expectEqualStrings("started\nprogress two\n", runtime.transcript.items);
}

test "replaceable line with ansi wrapper does not accumulate historical entries" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 21,
            .divider_top_row = 22,
            .input_row = 23,
            .divider_bottom_row = 24,
            .hint_row = 22,
        },
    };
    defer runtime.deinit(std.testing.allocator);

    var metrics = Metrics{};
    try runtime.writeTranscript(std.testing.allocator, &metrics, "start\n", true);
    _ = try runtime.appendReplaceableTranscriptLine(std.testing.allocator, &metrics, "\x1b[38;5;245mline one\n\x1b[0m");
    try std.testing.expect(try runtime.replaceTrailingTranscriptLine(std.testing.allocator, &metrics, "\x1b[38;5;245mline two\n\x1b[0m"));
    try std.testing.expectEqualStrings("start\n\x1b[38;5;245mline two\n\x1b[0m", runtime.transcript.items);
}

test "updateExtraInputRows shrink preserves pre-fx scrollback" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 40,
            .cols = 120,
            .content_bottom = 36,
            .divider_top_row = 37,
            .input_row = 38,
            .divider_bottom_row = 39,
            .hint_row = 40,
        },
    };
    defer runtime.deinit(std.testing.allocator);
    try runtime.enableShadowVt(std.testing.allocator);

    var metrics = Metrics{};
    try runtime.initViewport(&metrics, 12);

    try runtime.updateExtraInputRows(std.testing.allocator, &metrics, 7);
    try runtime.updateExtraInputRows(std.testing.allocator, &metrics, 0);

    try std.testing.expectEqual(@as(u16, 12), runtime.viewport_top_row);
}

test "updateExtraInputRows after committed frame only records invalidation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(std.testing.io, "post-frame-extra-rows.log", .{ .read = true });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .owned_top_row = 5,
        .viewport_top_row = 5,
        .has_committed_frame = true,
    };
    defer runtime.deinit(std.testing.allocator);
    runtime.footer_viewport.has_frame = true;
    runtime.footer_viewport.geometry = .{
        .top = 21,
        .top_divider = 21,
        .input_base = 22,
        .bottom_divider = 23,
        .hint = 24,
    };

    var metrics = Metrics{};
    try runtime.updateExtraInputRows(std.testing.allocator, &metrics, 3);

    try std.testing.expectEqual(@as(u16, 3), runtime.extra_input_rows);
    try std.testing.expect(runtime.transcript_band_dirty);
    try std.testing.expect(runtime.footer_viewport.externally_invalidated);
    try std.testing.expectEqual(@as(u64, 0), try sink.length(io_mod.getIo()));

    const pending = runtime.render_requests.pendingInvalidations();
    try std.testing.expectEqual(@as(u8, 1), pending.len);
    try std.testing.expectEqual(render_engine.paint_plan.FrameInvalidationReason.external_clear, pending.ranges()[0].reason);
    try std.testing.expectEqual(@as(u16, 5), pending.ranges()[0].top);
    try std.testing.expectEqual(@as(u16, 24), pending.ranges()[0].bottom);
}

test "resize reservation never moves viewport above launch-owned row" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 46,
            .cols = 131,
            .content_bottom = 42,
            .divider_top_row = 43,
            .input_row = 44,
            .divider_bottom_row = 45,
            .hint_row = 46,
        },
    };
    defer runtime.deinit(std.testing.allocator);

    var metrics = Metrics{};
    try runtime.initViewportWithReservedRows(&metrics, 45, 11);

    try std.testing.expectEqual(@as(u16, 32), runtime.viewport_top_row);

    runtime.layout = .{
        .rows = 44,
        .cols = 132,
        .content_bottom = 40,
        .divider_top_row = 41,
        .input_row = 42,
        .divider_bottom_row = 43,
        .hint_row = 44,
    };
    runtime.reserveVisibleViewportRows(11);

    try std.testing.expectEqual(@as(u16, 32), runtime.viewport_top_row);
}

test "clearTranscript preserves launch-owned row" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 21,
            .divider_top_row = 22,
            .input_row = 23,
            .divider_bottom_row = 24,
            .hint_row = 22,
        },
    };
    defer runtime.deinit(std.testing.allocator);

    var metrics = Metrics{};
    try runtime.initViewport(&metrics, 7);
    try runtime.writeTranscript(std.testing.allocator, &metrics, "hello\n", true);

    runtime.clearTranscript(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 7), runtime.owned_top_row);
    try std.testing.expectEqual(@as(u16, 7), runtime.viewport_top_row);
    try std.testing.expectEqual(@as(u16, 7), runtime.cursor_row);
}

test "writeTranscript overflow defers terminal scroll to frame selection delta" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 10,
            .cols = 80,
            .content_bottom = 7,
            .divider_top_row = 8,
            .input_row = 9,
            .divider_bottom_row = 10,
            .hint_row = 10,
        },
    };
    defer runtime.deinit(std.testing.allocator);

    var metrics = Metrics{};
    try runtime.initViewport(&metrics, 5);
    runtime.has_painted_transcript = true;
    try std.testing.expectEqual(@as(u16, 5), runtime.viewport_top_row);

    try runtime.writeTranscript(std.testing.allocator, &metrics, "a\nb\nc\nd\ne\nf\ng\nh\n", true);
    try std.testing.expectEqual(@as(u16, 5), runtime.viewport_top_row);
    try std.testing.expectEqual(@as(u16, 5), runtime.owned_top_row);
    try std.testing.expectEqual(@as(u16, 7), runtime.cursor_row);
}

test "appendRawBytesEntry stamps monotonic ids from 1" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const a = try alloc.dupe(u8, "first");
    const id_a = try runtime.appendRawBytesEntry(alloc, a);
    const b = try alloc.dupe(u8, "second");
    const id_b = try runtime.appendRawBytesEntry(alloc, b);

    try std.testing.expectEqual(@as(u32, 1), id_a);
    try std.testing.expectEqual(@as(u32, 2), id_b);
    try std.testing.expectEqual(@as(usize, 2), runtime.entries.items.len);
    try std.testing.expectEqual(@as(u32, 1), runtime.entries.items[0].id());
    try std.testing.expectEqualStrings("first", runtime.entries.items[0].raw_bytes.bytes);
}

test "append helpers cover all three variants with unique ids" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const raw = try alloc.dupe(u8, "banner");
    const raw_id = try runtime.appendRawBytesEntry(alloc, raw);

    const prompt = try alloc.dupe(u8, "hello");
    const user_id = try runtime.appendUserTurnOwned(alloc, .{ .text = prompt, .images = &.{} });

    const assistant_id = try runtime.appendAssistantTurnEntry(alloc);
    const segs = runtime.lookupAssistantSegments(assistant_id) orelse unreachable;
    try segs.text.appendSlice(alloc, "streaming");

    try std.testing.expectEqual(@as(u32, 1), raw_id);
    try std.testing.expectEqual(@as(u32, 2), user_id);
    try std.testing.expectEqual(@as(u32, 3), assistant_id);
    try std.testing.expectEqualStrings("streaming", runtime.entries.items[2].assistant_turn.segments.text.items);
}

test "appendRawTranscriptEntryClassified stores raw entry class" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const entry_id = try runtime.appendRawTranscriptEntryClassified(alloc, "running tests\n", .tool_status);

    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .raw_bytes);
    try std.testing.expectEqual(entry_id, runtime.entries.items[0].raw_bytes.id);
    try std.testing.expectEqual(RawEntryClass.tool_status, runtime.entries.items[0].raw_bytes.class);
    try std.testing.expectEqual(RawEntryClass.tool_status, runtime.rawEntryClass(entry_id).?);
}

test "appendRawTranscriptEntry defaults to unknown_raw class" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const entry_id = try runtime.appendRawTranscriptEntry(alloc, "raw entry\n");

    try std.testing.expectEqual(RawEntryClass.unknown_raw, runtime.rawEntryClass(entry_id).?);
}

test "updateRawBytesEntry preserves raw entry class" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const entry_id = try runtime.appendRawTranscriptEntryClassified(alloc, "running\n", .tool_status);
    try std.testing.expect(try runtime.updateRawBytesEntry(alloc, entry_id, "done\n"));

    try std.testing.expectEqual(RawEntryClass.tool_status, runtime.rawEntryClass(entry_id).?);
    try std.testing.expectEqualStrings("done\n", runtime.entries.items[0].raw_bytes.bytes);
}

test "setRawEntryClass updates only matching raw entry" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const raw_id = try runtime.appendRawTranscriptEntry(alloc, "raw entry\n");
    _ = try runtime.appendAssistantTurnEntry(alloc);

    try std.testing.expect(runtime.setRawEntryClass(raw_id, .subagent_status));
    try std.testing.expectEqual(RawEntryClass.subagent_status, runtime.rawEntryClass(raw_id).?);
    try std.testing.expect(!runtime.setRawEntryClass(999_999, .tool_status));
}

test "streamAssistantChunk opens a new assistant_turn when there is no trailing one" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());
    const alloc = std.testing.allocator;

    var runtime = TranscriptRuntime{ .stdout_file = sink, .layout = .{ .rows = 10, .cols = 80, .content_bottom = 7, .divider_top_row = 8, .input_row = 9, .divider_bottom_row = 10, .hint_row = 10 } };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    try runtime.initViewport(&metrics, 5);

    const id = try runtime.streamAssistantChunk(alloc, &metrics, "first chunk");

    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .assistant_turn);
    try std.testing.expectEqual(id, runtime.entries.items[0].id());
    try std.testing.expectEqualStrings("first chunk", runtime.entries.items[0].assistant_turn.segments.text.items);
    try std.testing.expect(std.mem.indexOf(u8, runtime.transcript.items, "first chunk") != null);
}

test "streamAssistantChunk extends the trailing assistant_turn on subsequent chunks" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());
    const alloc = std.testing.allocator;

    var runtime = TranscriptRuntime{ .stdout_file = sink, .layout = .{ .rows = 10, .cols = 80, .content_bottom = 7, .divider_top_row = 8, .input_row = 9, .divider_bottom_row = 10, .hint_row = 10 } };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    try runtime.initViewport(&metrics, 5);

    const id_a = try runtime.streamAssistantChunk(alloc, &metrics, "alpha ");
    const id_b = try runtime.streamAssistantChunk(alloc, &metrics, "beta");

    try std.testing.expectEqual(id_a, id_b);
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .assistant_turn);
    try std.testing.expectEqualStrings("alpha beta", runtime.entries.items[0].assistant_turn.segments.text.items);
}

test "recorded assistant stream slow path preserves a canonical anchor when retention rewrites its source" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    const old_prefix = "old retained prefix\n";
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        old_prefix,
        .subagent_status,
    );
    const long_prompt = try makeLongPastePrompt(alloc, 40);
    defer alloc.free(long_prompt);
    var metrics: Metrics = .{};
    const user_id = try runtime.writeUserPromptCard(
        alloc,
        &metrics,
        .{ .text = long_prompt, .images = &.{} },
        false,
        &.{},
    );

    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try std.testing.expect(committed_source.recorded_entries_authoritative);
    try std.testing.expect(committed_source.bytes.len > runtime.transcript.items.len);
    var committed_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer committed_prepared.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        committed_prepared.selection,
        preparedVisualOffsetForTest(&committed_prepared),
        committed_prepared.cursor.cursor_row,
        committed_prepared.cursor.cursor_col,
        1,
    );
    const committed_history_visual_offset = try stableHistoryVisualOffsetForTest(&runtime);

    const chunk = "trimmed assistant tail";
    runtime.max_retained_transcript_bytes =
        transcript_store.retainedStructuredBytes(&runtime) + chunk.len - old_prefix.len;
    const assistant_id = try runtime.streamAssistantChunk(alloc, &metrics, chunk);

    try expectStableNormalBufferRecoveryForTest(
        &runtime,
        committed_history_visual_offset,
    );
    try std.testing.expect(
        transcript_store.retainedStructuredBytes(&runtime) <=
            runtime.max_retained_transcript_bytes,
    );
    try std.testing.expect(runtime.lookupAssistantSegments(assistant_id) != null);
    var appended_source = try runtime.prepareTranscriptSource(alloc, null);
    defer appended_source.deinit(alloc);
    try std.testing.expect(!std.mem.startsWith(
        u8,
        appended_source.bytes,
        committed_source.bytes,
    ));
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, appended_source.bytes, old_prefix),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, appended_source.bytes, "LONG_PASTE_LAST_MARKER"),
    );
    try std.testing.expect(runtime.entries.items[0].id() == user_id);
}

const AssistantStreamFastPathCase = enum {
    opening,
    continuation,
};

const AssistantStreamFastPathFailureWitness = struct {
    target_failures: usize = 0,
};

fn checkOrdinaryAssistantStreamAllocationFailures(
    alloc: Allocator,
    test_case: AssistantStreamFastPathCase,
    witness: *AssistantStreamFastPathFailureWitness,
) !void {
    const continuation = [_]u8{'b'} ** 4096;
    const chunk: []const u8 = switch (test_case) {
        .opening => "first chunk",
        .continuation => &continuation,
    };

    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(24, 12, 8) };
    defer runtime.deinit(alloc);
    var metrics = Metrics{};

    const existing_entry_id: ?u32 = switch (test_case) {
        .opening => null,
        .continuation => try runtime.streamAssistantChunk(alloc, &metrics, "a"),
    };
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;

    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const assistant_before = if (existing_entry_id) |entry_id|
        try std.testing.allocator.dupe(
            u8,
            runtime.lookupAssistantSegments(entry_id).?.text.items,
        )
    else
        null;
    defer if (assistant_before) |text| std.testing.allocator.free(text);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const cache_origin_before = runtime.transcript_cache_origin_untrimmed;
    const repaint_count_before = runtime.render_requests.pendingReasonCount();

    try std.testing.expect(retained_before <= runtime.max_retained_transcript_bytes);
    try std.testing.expect(
        chunk.len <= runtime.max_retained_transcript_bytes - retained_before,
    );
    try std.testing.expect(
        chunk.len > runtime.transcript.capacity - runtime.transcript.items.len,
    );
    if (existing_entry_id) |entry_id| {
        const segments = runtime.lookupAssistantSegments(entry_id).?;
        try std.testing.expect(
            chunk.len > segments.text.capacity - segments.text.items.len,
        );
    } else {
        try std.testing.expectEqual(@as(usize, 0), runtime.entries.capacity);
    }

    const entry_id = runtime.streamAssistantChunk(alloc, &metrics, chunk) catch |err| {
        witness.target_failures += 1;
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        if (existing_entry_id) |prior_entry_id| {
            try std.testing.expectEqualStrings(
                assistant_before.?,
                runtime.lookupAssistantSegments(prior_entry_id).?.text.items,
            );
        }
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expectEqual(cache_origin_before, runtime.transcript_cache_origin_untrimmed);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    const opened_new_turn = test_case == .opening;
    const expected_entry_id = existing_entry_id orelse next_entry_id_before;
    try std.testing.expectEqual(expected_entry_id, entry_id);
    try std.testing.expectEqual(
        next_entry_id_before +% @intFromBool(opened_new_turn),
        runtime.next_entry_id,
    );
    try std.testing.expectEqual(
        entry_count_before + @intFromBool(opened_new_turn),
        runtime.entries.items.len,
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .assistant_turn);
    try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());

    const assistant_text = runtime.entries.items[0].assistant_turn.segments.text.items;
    switch (test_case) {
        .opening => try std.testing.expectEqualStrings(chunk, assistant_text),
        .continuation => {
            try std.testing.expectEqual(@as(usize, 1) + chunk.len, assistant_text.len);
            try std.testing.expectEqualStrings("a", assistant_text[0..1]);
            try std.testing.expectEqualStrings(chunk, assistant_text[1..]);
        },
    }
    try std.testing.expectEqualStrings(assistant_text, runtime.transcript.items);
    try std.testing.expectEqual(
        assistant_text.len,
        transcript_store.retainedStructuredBytes(&runtime),
    );
    try std.testing.expectEqual(repaint_count_before + 1, runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}

test "ordinary assistant stream admission is atomic across allocation failures" {
    var opening_witness = AssistantStreamFastPathFailureWitness{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkOrdinaryAssistantStreamAllocationFailures,
        .{ .opening, &opening_witness },
    );
    try std.testing.expectEqual(@as(usize, 3), opening_witness.target_failures);

    var continuation_witness = AssistantStreamFastPathFailureWitness{};
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkOrdinaryAssistantStreamAllocationFailures,
        .{ .continuation, &continuation_witness },
    );
    try std.testing.expectEqual(@as(usize, 2), continuation_witness.target_failures);
}

fn checkOpeningAssistantStreamAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(24, 12, 8) };
    defer runtime.deinit(alloc);
    var metrics = Metrics{};

    try runtime.writeTranscript(alloc, &metrics, "older transcript row\n", true);
    const prompt = try alloc.dupe(u8, "prompt");
    _ = try runtime.appendUserTurnOwned(alloc, .{ .text = prompt, .images = &.{} });
    runtime.max_retained_transcript_bytes = "prompt".len + "first chunk".len;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;

    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const cache_origin_before = runtime.transcript_cache_origin_untrimmed;
    const repaint_count_before = runtime.render_requests.pendingReasonCount();

    const entry_id = runtime.streamAssistantChunk(
        alloc,
        &metrics,
        "first chunk",
    ) catch |err| {
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expectEqual(cache_origin_before, runtime.transcript_cache_origin_untrimmed);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expectEqual(next_entry_id_before, entry_id);
    try std.testing.expectEqual(next_entry_id_before +% 1, runtime.next_entry_id);
    try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .user_turn);
    try std.testing.expect(runtime.entries.items[1] == .assistant_turn);
    try std.testing.expectEqual(entry_id, runtime.entries.items[1].id());
    try std.testing.expectEqualStrings(
        "first chunk",
        runtime.entries.items[1].assistant_turn.segments.text.items,
    );
    try std.testing.expectEqual(
        runtime.max_retained_transcript_bytes,
        transcript_store.retainedStructuredBytes(&runtime),
    );
    const rendered = try renderEntriesToBytes(
        std.testing.allocator,
        runtime.entries.items,
        runtime.layout.cols,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(rendered, runtime.transcript.items);
    try std.testing.expectEqual(repaint_count_before + 1, runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}

test "opening a recorded assistant stream is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkOpeningAssistantStreamAllocationFailures,
        .{},
    );
}

fn checkExtendingAssistantStreamAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(24, 12, 8) };
    defer runtime.deinit(alloc);
    var metrics = Metrics{};

    try runtime.writeTranscript(alloc, &metrics, "older transcript row\n", true);
    const entry_id = try runtime.streamAssistantChunk(alloc, &metrics, "alpha ");
    runtime.max_retained_transcript_bytes = "alpha beta".len;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;

    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const assistant_before = try std.testing.allocator.dupe(
        u8,
        runtime.lookupAssistantSegments(entry_id).?.text.items,
    );
    defer std.testing.allocator.free(assistant_before);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const cache_origin_before = runtime.transcript_cache_origin_untrimmed;
    const repaint_count_before = runtime.render_requests.pendingReasonCount();

    const continued_id = runtime.streamAssistantChunk(
        alloc,
        &metrics,
        "beta",
    ) catch |err| {
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        try std.testing.expectEqualStrings(
            assistant_before,
            runtime.lookupAssistantSegments(entry_id).?.text.items,
        );
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expectEqual(cache_origin_before, runtime.transcript_cache_origin_untrimmed);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expectEqual(entry_id, continued_id);
    try std.testing.expectEqual(entry_count_before - 1, runtime.entries.items.len);
    try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
    try std.testing.expect(runtime.entries.items[0] == .assistant_turn);
    try std.testing.expectEqual(entry_id, runtime.entries.items[0].id());
    try std.testing.expectEqualStrings(
        "alpha beta",
        runtime.entries.items[0].assistant_turn.segments.text.items,
    );
    try std.testing.expectEqual(
        runtime.max_retained_transcript_bytes,
        transcript_store.retainedStructuredBytes(&runtime),
    );
    const rendered = try renderEntriesToBytes(
        std.testing.allocator,
        runtime.entries.items,
        runtime.layout.cols,
    );
    defer std.testing.allocator.free(rendered);
    try std.testing.expectEqualStrings(rendered, runtime.transcript.items);
    try std.testing.expectEqual(repaint_count_before + 1, runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}

test "extending a recorded assistant stream is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkExtendingAssistantStreamAllocationFailures,
        .{},
    );
}

test "paced assistant continuations do not clone retained history per chunk" {
    const backing = std.testing.allocator;
    var counted = std.testing.FailingAllocator.init(backing, .{});
    const alloc = counted.allocator();
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 24, 20),
        .max_transcript_bytes = 4096,
    };
    defer runtime.deinit(alloc);
    try runtime.initBacking(alloc);

    for (0..48) |_| {
        _ = try runtime.appendRawTranscriptEntryClassified(
            alloc,
            "retained transcript history row\n",
            .subagent_status,
        );
    }

    var metrics = Metrics{};
    const entry_id = try runtime.streamAssistantChunk(alloc, &metrics, "a");
    const allocations_before = counted.allocations;
    for (0..256) |_| {
        try std.testing.expectEqual(
            entry_id,
            try runtime.streamAssistantChunk(alloc, &metrics, "b"),
        );
    }

    try std.testing.expect(counted.allocations - allocations_before <= 8);
    try std.testing.expectEqual(@as(usize, 49), runtime.entries.items.len);
    try std.testing.expectEqual(@as(usize, 257), runtime.lookupAssistantSegments(entry_id).?.text.items.len);
}

test "streamAssistantChunk opens a new assistant_turn after a user_turn" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());
    const alloc = std.testing.allocator;

    var runtime = TranscriptRuntime{ .stdout_file = sink, .layout = .{ .rows = 10, .cols = 80, .content_bottom = 7, .divider_top_row = 8, .input_row = 9, .divider_bottom_row = 10, .hint_row = 10 } };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    try runtime.initViewport(&metrics, 5);

    _ = try runtime.streamAssistantChunk(alloc, &metrics, "assistant A");
    const user_text = try alloc.dupe(u8, "next user prompt");
    _ = try runtime.appendUserTurnOwned(alloc, .{ .text = user_text, .images = &.{} });
    const id_after = try runtime.streamAssistantChunk(alloc, &metrics, "assistant B");

    try std.testing.expectEqual(@as(usize, 3), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .assistant_turn);
    try std.testing.expect(runtime.entries.items[1] == .user_turn);
    try std.testing.expect(runtime.entries.items[2] == .assistant_turn);
    try std.testing.expectEqual(id_after, runtime.entries.items[2].id());
    try std.testing.expectEqualStrings("assistant B", runtime.entries.items[2].assistant_turn.segments.text.items);
}

test "appendUserTurnOwned frees text, images, and image slices when entries.append OOMs" {
    const base = std.testing.allocator;
    // Fail after all transferred slices exist, when the entries list first grows.
    var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = 4 });
    const alloc = failing.allocator();

    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const text = try alloc.dupe(u8, "prompt");
    const images = try alloc.alloc(types.ImageAttachment, 1);
    images[0] = .{
        .path = try alloc.dupe(u8, "/tmp/image.png"),
        .media_type = try alloc.dupe(u8, "image/png"),
    };

    try std.testing.expectError(
        error.OutOfMemory,
        runtime.appendUserTurnOwned(alloc, .{ .text = text, .images = images }),
    );

    try std.testing.expectEqual(@as(usize, 0), runtime.entries.items.len);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "appendUserTurnOwnedWithSkillTokens stores selected skill metadata for reflow" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const prompt_text = "raw $review then $review";
    const prompt = try alloc.dupe(u8, prompt_text);
    var handed_off = false;
    errdefer if (!handed_off) alloc.free(prompt);

    const tokens = [_]input_visual_layout.SkillTokenSpan{.{
        .raw_start = "raw $review then ".len,
        .raw_end = prompt_text.len,
        .name = "review",
        .path = "/tmp/review",
    }};

    _ = try runtime.appendUserTurnOwnedWithSkillTokens(alloc, .{ .text = prompt, .images = &.{} }, &tokens);
    handed_off = true;

    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items[0].user_turn.skill_tokens.len);
    try std.testing.expectEqualStrings("review", runtime.entries.items[0].user_turn.skill_tokens[0].name);
    try std.testing.expectEqual(
        @as(usize, prompt_text.len + "review".len + "/tmp/review".len),
        transcript_store.retainedStructuredBytes(&runtime),
    );

    const rendered = try renderEntriesToBytes(alloc, runtime.entries.items, 80);
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "$review then ") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "\x1b[38;5;252mreview") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "$review then $review") == null);
}

const UserPromptCardAdmissionCase = enum {
    text_with_separator,
    image_with_skill_token,
};

const prompt_card_skill_tokens = [_]input_visual_layout.SkillTokenSpan{.{
    .raw_start = "inspect ".len,
    .raw_end = "inspect $review".len,
    .name = "review",
    .path = "/tmp/review",
}};

fn setup_user_prompt_card_admission_runtime(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    test_case: UserPromptCardAdmissionCase,
) !u32 {
    const seed_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "seed",
        .subagent_status,
    );
    runtime.cursor_row = 2;
    runtime.cursor_col = switch (test_case) {
        .text_with_separator => 5,
        .image_with_skill_token => 1,
    };
    runtime.replaceable_last_line = true;
    runtime.replaceable_start = 1;
    runtime.replaceable_row = 2;
    runtime.transcript_cache_origin_untrimmed = true;
    runtime.full_transcript.depth = .full;
    runtime.full_transcript.scroll_rows = 3;
    runtime.full_transcript.follow_tail = false;
    runtime.full_transcript.anchor_entry_id = seed_id;
    runtime.full_transcript.anchor_pending = true;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;
    return seed_id;
}

fn user_prompt_card_admission_input(
    test_case: UserPromptCardAdmissionCase,
    images: []types.ImageAttachment,
) struct {
    user: types.UserTurn,
    skill_tokens: []const input_visual_layout.SkillTokenSpan,
    has_prior_turns: bool,
} {
    return switch (test_case) {
        .text_with_separator => .{
            .user = .{ .text = @constCast("plain prompt"), .images = &.{} },
            .skill_tokens = &.{},
            .has_prior_turns = false,
        },
        .image_with_skill_token => .{
            .user = .{ .text = @constCast("inspect $review"), .images = images },
            .skill_tokens = &prompt_card_skill_tokens,
            .has_prior_turns = true,
        },
    };
}

fn check_user_prompt_card_admission_success(
    test_case: UserPromptCardAdmissionCase,
) !void {
    const alloc = std.testing.allocator;
    const layout = transcriptTestLayout(48, 12, 8);
    var actual = TranscriptRuntime{ .layout = layout };
    defer actual.deinit(alloc);
    const seed_id = try setup_user_prompt_card_admission_runtime(&actual, alloc, test_case);

    var images = [_]types.ImageAttachment{.{
        .id = 7,
        .path = @constCast("/tmp/prompt-card.png"),
        .media_type = @constCast("image/png"),
    }};
    const input = user_prompt_card_admission_input(test_case, &images);
    const input_images_ptr = input.user.images.ptr;
    const card = try user_message_card.buildUserPromptCardWithSkillTokens(
        alloc,
        input.user.text,
        input.user.images,
        actual.layout.cols,
        input.skill_tokens,
    );
    defer alloc.free(card);
    const separator = if (input.has_prior_turns) "" else "\n";
    const expected_transcript = try std.fmt.allocPrint(
        alloc,
        "seed{s}{s}",
        .{ separator, card },
    );
    defer alloc.free(expected_transcript);
    const expected_reconstructed = try std.fmt.allocPrint(
        alloc,
        "seed\n\n{s}",
        .{card},
    );
    defer alloc.free(expected_reconstructed);

    var actual_metrics = Metrics{};
    const actual_id = try actual.writeUserPromptCard(
        alloc,
        &actual_metrics,
        input.user,
        input.has_prior_turns,
        input.skill_tokens,
    );

    const expected_id = seed_id + @as(u32, if (input.has_prior_turns) 1 else 2);
    try std.testing.expectEqual(expected_id, actual_id);
    try std.testing.expectEqualStrings(expected_transcript, actual.transcript.items);
    try std.testing.expectEqual(
        @as(usize, if (input.has_prior_turns) 2 else 3),
        actual.entries.items.len,
    );
    try std.testing.expectEqual(expected_id +% 1, actual.next_entry_id);
    var expected_cursor = TranscriptRuntime{
        .layout = layout,
        .cursor_row = 2,
        .cursor_col = switch (test_case) {
            .text_with_separator => 5,
            .image_with_skill_token => 1,
        },
    };
    _ = expected_cursor.advanceCursor(expected_transcript["seed".len..]);
    try std.testing.expectEqual(expected_cursor.cursor_row, actual.cursor_row);
    try std.testing.expectEqual(expected_cursor.cursor_col, actual.cursor_col);
    try std.testing.expect(!actual.replaceable_last_line);
    try std.testing.expectEqual(@as(usize, 0), actual.replaceable_start);
    try std.testing.expectEqual(@as(u16, 2), actual.replaceable_row);
    try std.testing.expect(!actual.transcript_cache_origin_untrimmed);
    try std.testing.expect(actual.render_requests.hasReason(.transcript));
    try std.testing.expectEqual(@as(usize, 1), actual.render_requests.pendingReasonCount());
    try std.testing.expectEqual(@as(u32, 3), actual.full_transcript.scroll_rows);
    try std.testing.expect(!actual.full_transcript.follow_tail);
    try std.testing.expectEqual(@as(?u32, seed_id), actual.full_transcript.anchor_entry_id);
    try std.testing.expect(actual.full_transcript.anchor_pending);

    const actual_reconstructed = try renderEntriesToBytes(
        alloc,
        actual.entries.items,
        actual.layout.cols,
    );
    defer alloc.free(actual_reconstructed);
    try std.testing.expectEqualStrings(expected_reconstructed, actual_reconstructed);
    var expected_retained_bytes = "seed".len + separator.len + input.user.text.len;
    for (input.user.images) |image| {
        expected_retained_bytes += image.path.len + image.media_type.len;
    }
    for (input.skill_tokens) |token| {
        expected_retained_bytes += token.name.len + token.path.len;
    }
    try std.testing.expectEqual(
        expected_retained_bytes,
        transcript_store.retainedStructuredBytes(&actual),
    );
    try std.testing.expectEqualStrings(input.user.text, actual.entries.items[actual.entries.items.len - 1].user_turn.turn.text);
    try std.testing.expectEqual(input_images_ptr, input.user.images.ptr);
}

test "recorded user prompt card admission preserves immediate and reconstructive rendering" {
    try check_user_prompt_card_admission_success(.text_with_separator);
    try check_user_prompt_card_admission_success(.image_with_skill_token);
}

test "recorded user prompt card admission preserves an authoritative committed anchor" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 256,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    const long_tail = try makeLongPastePrompt(alloc, 80);
    defer alloc.free(long_tail);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        long_tail,
        .subagent_status,
    );
    try std.testing.expect(!runtime.transcript_cache_origin_untrimmed);

    var metrics = Metrics{};
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try std.testing.expect(committed_source.recorded_entries_authoritative);
    try std.testing.expect(committed_source.bytes.len > runtime.transcript.items.len);
    var committed_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer committed_prepared.deinit(alloc);
    const committed_offset = preparedVisualOffsetForTest(&committed_prepared);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        committed_prepared.selection,
        committed_offset,
        committed_prepared.cursor.cursor_row,
        committed_prepared.cursor.cursor_col,
        1,
    );
    const committed_diagnostic = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        committed_diagnostic.state,
    );

    _ = try runtime.writeUserPromptCard(
        alloc,
        &metrics,
        .{ .text = @constCast("run the prepared two commands"), .images = &.{} },
        true,
        &.{},
    );

    try std.testing.expectEqualDeep(
        committed_diagnostic,
        runtime.transcriptCommitDiagnostic(),
    );
    var appended_source = try runtime.prepareTranscriptSource(alloc, null);
    defer appended_source.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(
        u8,
        appended_source.bytes,
        committed_source.bytes,
    ));
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, appended_source.bytes, "LONG_PASTE_LAST_MARKER"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, appended_source.bytes, "run the prepared two commands"),
    );
    const appended_flow = try alloc.dupe(u8, appended_source.bytes);
    defer alloc.free(appended_flow);

    var appended_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer appended_prepared.deinit(alloc);
    const facts = runtime.planTranscriptScroll(&appended_prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expect(facts.semantic_rows > 0);
    try std.testing.expectEqual(committed_offset, facts.source_visual_offset);

    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(&runtime, appended_prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &appended_source,
        &appended_prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    const settled_offset = transition.visual_offset;
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = scroll_plan.terminal_scroll_rows,
        .document_append_committed = !transition.document_append.isEmpty(),
        .committed_cursor_row = transition.cursor_row,
        .committed_cursor_col = transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    const settled = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        settled.state,
    );
    try std.testing.expectEqual(settled_offset, settled.visual_offset);
    const projection = runtime.stableTranscriptProjectionForFlow(
        appended_flow,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(settled_offset, projection.visual_offset);
}

test "recorded user prompt card preserves a committed anchor after a non-prefix rewrite" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 10, 6),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    var metrics = Metrics{};
    _ = try runtime.streamAssistantChunk(
        alloc,
        &metrics,
        "alpha beta gamma delta epsilon zeta eta theta",
    );
    const committed_flow = try alloc.dupe(u8, runtime.transcript.items);
    defer alloc.free(committed_flow);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_flow,
        testSelection(0),
        0,
        runtime.cursor_row,
        runtime.cursor_col,
        1,
    );

    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "response",
        .tone = .cancelled,
        .body = "Interrupted by user",
    });
    var notice_source = try runtime.prepareTranscriptSource(alloc, null);
    defer notice_source.deinit(alloc);
    try std.testing.expect(!std.mem.startsWith(
        u8,
        notice_source.bytes,
        committed_flow,
    ));
    switch (runtime.transcript_commit_state) {
        .stable => |anchor| try std.testing.expect(anchor.normal_buffer_recovery_pending),
        .invalid, .recovering => return error.TestExpectedStableTranscript,
    }

    _ = try runtime.writeUserPromptCard(
        alloc,
        &metrics,
        .{ .text = @constCast("queued prompt"), .images = &.{} },
        true,
        &.{},
    );

    switch (runtime.transcript_commit_state) {
        .stable => |anchor| try std.testing.expect(anchor.normal_buffer_recovery_pending),
        .invalid, .recovering => return error.TestExpectedStableTranscript,
    }
    var appended_source = try runtime.prepareTranscriptSource(alloc, null);
    defer appended_source.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, appended_source.bytes, "queued prompt"),
    );
}

test "recorded user prompt card preserves an anchor when retention prunes its source" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "anchored transcript\n",
        .subagent_status,
    );
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        4,
        1,
        1,
    );
    const committed_history_visual_offset = try stableHistoryVisualOffsetForTest(&runtime);

    const prompt = "retained prompt";
    runtime.max_retained_transcript_bytes = prompt.len;
    var metrics = Metrics{};
    _ = try runtime.writeUserPromptCard(
        alloc,
        &metrics,
        .{ .text = @constCast(prompt), .images = &.{} },
        true,
        &.{},
    );

    try expectStableNormalBufferRecoveryForTest(
        &runtime,
        committed_history_visual_offset,
    );
    var retained_source = try runtime.prepareTranscriptSource(alloc, null);
    defer retained_source.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, retained_source.bytes, "anchored transcript"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, retained_source.bytes, prompt),
    );
}

test "recorded transcript append preserves an authoritative committed anchor" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    const long_tail = try makeLongPastePrompt(alloc, 40);
    defer alloc.free(long_tail);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        long_tail,
        .subagent_status,
    );

    var metrics = Metrics{};
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try std.testing.expect(committed_source.recorded_entries_authoritative);
    try std.testing.expect(committed_source.bytes.len > runtime.transcript.items.len);
    var committed_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer committed_prepared.deinit(alloc);
    const committed_offset = preparedVisualOffsetForTest(&committed_prepared);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        committed_prepared.selection,
        committed_offset,
        committed_prepared.cursor.cursor_row,
        committed_prepared.cursor.cursor_col,
        1,
    );
    const committed_diagnostic = runtime.transcriptCommitDiagnostic();

    const notice = "permission accepted\ncommand starting\n";
    try runtime.writeTranscriptClassified(
        alloc,
        &metrics,
        notice,
        true,
        .subagent_status,
    );

    try std.testing.expectEqualDeep(
        committed_diagnostic,
        runtime.transcriptCommitDiagnostic(),
    );
    var appended_source = try runtime.prepareTranscriptSource(alloc, null);
    defer appended_source.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(
        u8,
        appended_source.bytes,
        committed_source.bytes,
    ));
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, appended_source.bytes, "LONG_PASTE_FIRST_MARKER"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, appended_source.bytes, "LONG_PASTE_LAST_MARKER"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, appended_source.bytes, "permission accepted"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, appended_source.bytes, "command starting"),
    );

    var appended_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer appended_prepared.deinit(alloc);
    const facts = runtime.planTranscriptScroll(&appended_prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expect(facts.semantic_rows > 0);
    try std.testing.expectEqual(committed_offset, facts.source_visual_offset);
}

test "theme retint preserves a capped canonical anchor and visual geometry" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    const long_tail = try makeLongPastePrompt(alloc, 40);
    defer alloc.free(long_tail);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        long_tail,
        .subagent_status,
    );
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "\x1b[38;5;252mRETINT_THEME_MARKER\x1b[39m\n",
        .subagent_status,
    );

    var metrics: Metrics = .{};
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try std.testing.expect(committed_source.recorded_entries_authoritative);
    try std.testing.expect(committed_source.bytes.len > runtime.transcript.items.len);
    var committed_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer committed_prepared.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        committed_prepared.selection,
        preparedVisualOffsetForTest(&committed_prepared),
        committed_prepared.cursor.cursor_row,
        committed_prepared.cursor.cursor_col,
        1,
    );
    const committed_diagnostic = runtime.transcriptCommitDiagnostic();

    try runtime.retintEntriesForTheme(alloc, false, true);

    try std.testing.expectEqualDeep(
        committed_diagnostic,
        runtime.transcriptCommitDiagnostic(),
    );
    var retinted_source = try runtime.prepareTranscriptSource(alloc, null);
    defer retinted_source.deinit(alloc);
    const first_marker = std.mem.find(
        u8,
        retinted_source.bytes,
        "LONG_PASTE_FIRST_MARKER",
    ) orelse return error.TestUnexpectedResult;
    const last_marker = std.mem.find(
        u8,
        retinted_source.bytes,
        "LONG_PASTE_LAST_MARKER",
    ) orelse return error.TestUnexpectedResult;
    const theme_marker = std.mem.find(
        u8,
        retinted_source.bytes,
        "RETINT_THEME_MARKER",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_marker < last_marker);
    try std.testing.expect(last_marker < theme_marker);
    try std.testing.expect(std.mem.find(
        u8,
        retinted_source.bytes,
        "\x1b[38;5;238mRETINT_THEME_MARKER",
    ) != null);

    var retinted_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer retinted_prepared.deinit(alloc);
    try std.testing.expectEqualDeep(
        committed_prepared.selection,
        retinted_prepared.selection,
    );
    try std.testing.expectEqualSlices(
        u16,
        committed_prepared.sourceVisualRows(),
        retinted_prepared.sourceVisualRows(),
    );
    try std.testing.expectEqual(
        committed_prepared.cursor.cursor_row,
        retinted_prepared.cursor.cursor_row,
    );
    try std.testing.expectEqual(
        committed_prepared.cursor.cursor_col,
        retinted_prepared.cursor.cursor_col,
    );

    const retinted_diagnostic = runtime.transcriptCommitDiagnostic();
    const retinted_bytes = try alloc.dupe(u8, retinted_source.bytes);
    defer alloc.free(retinted_bytes);
    try runtime.retintEntriesForTheme(alloc, true, true);
    var unchanged_source = try runtime.prepareTranscriptSource(alloc, null);
    defer unchanged_source.deinit(alloc);
    try std.testing.expectEqualStrings(retinted_bytes, unchanged_source.bytes);
    try std.testing.expectEqualDeep(
        retinted_diagnostic,
        runtime.transcriptCommitDiagnostic(),
    );
}

test "light to dark theme retint preserves retention with equal-width tokens" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "OLDER_RETINT_ENTRY\n",
        .subagent_status,
    );
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "\x1b[38;5;238mRETINT_GROWTH_MARKER\x1b[39m\n",
        .subagent_status,
    );
    runtime.max_retained_transcript_bytes = transcript_store.retainedStructuredBytes(&runtime);
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        4,
        1,
        1,
    );

    try runtime.retintEntriesForTheme(alloc, true, false);

    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    try std.testing.expect(
        transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes,
    );
    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        source.bytes,
        "\x1b[38;5;252mRETINT_GROWTH_MARKER",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source.bytes, "OLDER_RETINT_ENTRY"),
    );
}

fn checkThemeRetintAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "ALLOCATION TRANSCRIPT 01\n" ++
            "ALLOCATION TRANSCRIPT 02\n" ++
            "ALLOCATION TRANSCRIPT 03\n" ++
            "\x1b[38;5;252mRETINT ALLOCATION MARKER\x1b[39m\n",
        .subagent_status,
    );
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        4,
        1,
        1,
    );

    var source_before = try runtime.prepareTranscriptSource(std.testing.allocator, null);
    defer source_before.deinit(std.testing.allocator);
    const cache_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(cache_before);
    const diagnostic_before = runtime.transcriptCommitDiagnostic();
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const pending_repaints_before = runtime.render_requests.pendingReasonCount();
    const cache_origin_before = runtime.transcript_cache_origin_untrimmed;

    runtime.retintEntriesForTheme(alloc, false, true) catch |err| {
        var source_after = try runtime.prepareTranscriptSource(std.testing.allocator, null);
        defer source_after.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(source_before.bytes, source_after.bytes);
        try std.testing.expectEqualStrings(cache_before, runtime.transcript.items);
        try std.testing.expectEqualDeep(
            diagnostic_before,
            runtime.transcriptCommitDiagnostic(),
        );
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(
            pending_repaints_before,
            runtime.render_requests.pendingReasonCount(),
        );
        try std.testing.expectEqual(
            cache_origin_before,
            runtime.transcript_cache_origin_untrimmed,
        );
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expectEqualDeep(
        diagnostic_before,
        runtime.transcriptCommitDiagnostic(),
    );
    var retinted_source = try runtime.prepareTranscriptSource(std.testing.allocator, null);
    defer retinted_source.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(
        u8,
        retinted_source.bytes,
        "\x1b[38;5;238mRETINT ALLOCATION MARKER",
    ) != null);
}

test "theme retint is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkThemeRetintAllocationFailures,
        .{},
    );
}

test "recorded transcript append preserves an anchor when retention prunes its source" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "anchored transcript\n",
        .subagent_status,
    );
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        4,
        1,
        1,
    );
    const committed_history_visual_offset = try stableHistoryVisualOffsetForTest(&runtime);

    const notice = "permission accepted\n";
    runtime.max_retained_transcript_bytes = notice.len;
    var metrics = Metrics{};
    try runtime.writeTranscriptClassified(
        alloc,
        &metrics,
        notice,
        true,
        .subagent_status,
    );

    try expectStableNormalBufferRecoveryForTest(
        &runtime,
        committed_history_visual_offset,
    );
    var retained_source = try runtime.prepareTranscriptSource(alloc, null);
    defer retained_source.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, retained_source.bytes, "anchored transcript"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, retained_source.bytes, "permission accepted"),
    );
}

fn check_user_prompt_card_admission_allocation_failures(
    alloc: Allocator,
    test_case: UserPromptCardAdmissionCase,
) !void {
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(48, 12, 8) };
    defer runtime.deinit(alloc);
    const seed_id = try setup_user_prompt_card_admission_runtime(&runtime, alloc, test_case);

    var images = [_]types.ImageAttachment{.{
        .id = 7,
        .path = @constCast("/tmp/prompt-card.png"),
        .media_type = @constCast("image/png"),
    }};
    const input = user_prompt_card_admission_input(test_case, &images);
    const input_images_ptr = input.user.images.ptr;
    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const reconstructed_before = try renderEntriesToBytes(
        std.testing.allocator,
        runtime.entries.items,
        runtime.layout.cols,
    );
    defer std.testing.allocator.free(reconstructed_before);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const replaceable_before = runtime.replaceable_last_line;
    const replaceable_start_before = runtime.replaceable_start;
    const replaceable_row_before = runtime.replaceable_row;
    const cache_origin_before = runtime.transcript_cache_origin_untrimmed;
    const repaint_count_before = runtime.render_requests.pendingReasonCount();
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        runtime.cursor_row,
        runtime.cursor_col,
        1,
    );
    const commit_before = runtime.transcriptCommitDiagnostic();
    const projection_before = runtime.stableTranscriptProjectionForFlow(
        committed_source.bytes,
    ) orelse return error.TestUnexpectedResult;
    const full_transcript_before = runtime.full_transcript;
    var metrics = Metrics{};

    _ = runtime.writeUserPromptCard(
        alloc,
        &metrics,
        input.user,
        input.has_prior_turns,
        input.skill_tokens,
    ) catch |err| {
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(seed_id, runtime.entries.items[0].id());
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        const reconstructed_after = try renderEntriesToBytes(
            std.testing.allocator,
            runtime.entries.items,
            runtime.layout.cols,
        );
        defer std.testing.allocator.free(reconstructed_after);
        try std.testing.expectEqualStrings(reconstructed_before, reconstructed_after);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expectEqual(replaceable_before, runtime.replaceable_last_line);
        try std.testing.expectEqual(replaceable_start_before, runtime.replaceable_start);
        try std.testing.expectEqual(replaceable_row_before, runtime.replaceable_row);
        try std.testing.expectEqual(cache_origin_before, runtime.transcript_cache_origin_untrimmed);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        try std.testing.expectEqualDeep(commit_before, runtime.transcriptCommitDiagnostic());
        const projection_after = runtime.stableTranscriptProjectionForFlow(
            committed_source.bytes,
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualDeep(projection_before, projection_after);
        try std.testing.expectEqual(full_transcript_before.scroll_rows, runtime.full_transcript.scroll_rows);
        try std.testing.expectEqual(full_transcript_before.follow_tail, runtime.full_transcript.follow_tail);
        try std.testing.expectEqual(full_transcript_before.anchor_entry_id, runtime.full_transcript.anchor_entry_id);
        try std.testing.expectEqual(full_transcript_before.anchor_pending, runtime.full_transcript.anchor_pending);
        try std.testing.expectEqualStrings(input.user.text, switch (test_case) {
            .text_with_separator => "plain prompt",
            .image_with_skill_token => "inspect $review",
        });
        try std.testing.expectEqual(input_images_ptr, input.user.images.ptr);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expectEqual(repaint_count_before + 1, runtime.render_requests.pendingReasonCount());
    try std.testing.expectEqualStrings(input.user.text, runtime.entries.items[runtime.entries.items.len - 1].user_turn.turn.text);
    try std.testing.expectEqual(input_images_ptr, input.user.images.ptr);
}

test "recorded user prompt card admission is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_user_prompt_card_admission_allocation_failures,
        .{UserPromptCardAdmissionCase.text_with_separator},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_user_prompt_card_admission_allocation_failures,
        .{UserPromptCardAdmissionCase.image_with_skill_token},
    );
}

test "tailAssistantSegments returns trailing assistant or null" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    try std.testing.expect(runtime.tailAssistantSegments() == null);

    const bytes = try alloc.dupe(u8, "banner");
    _ = try runtime.appendRawBytesEntry(alloc, bytes);
    try std.testing.expect(runtime.tailAssistantSegments() == null);

    const assistant_id = try runtime.appendAssistantTurnEntry(alloc);
    const segs = runtime.lookupAssistantSegments(assistant_id) orelse unreachable;
    try segs.text.appendSlice(alloc, "tok1");
    const tail = runtime.tailAssistantSegments();
    try std.testing.expect(tail != null);
    try std.testing.expectEqualStrings("tok1", tail.?.text.items);

    const trailing = try alloc.dupe(u8, "later");
    _ = try runtime.appendRawBytesEntry(alloc, trailing);
    try std.testing.expect(runtime.tailAssistantSegments() == null);
}

test "lookupAssistantSegments resolves assistant ids and rejects others" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const prompt = try alloc.dupe(u8, "hello");
    const user_id = try runtime.appendUserTurnOwned(alloc, .{ .text = prompt, .images = &.{} });

    const assistant_id = try runtime.appendAssistantTurnEntry(alloc);
    const segs = runtime.lookupAssistantSegments(assistant_id) orelse unreachable;
    try segs.text.appendSlice(alloc, "tok");

    const looked_up = runtime.lookupAssistantSegments(assistant_id);
    try std.testing.expect(looked_up != null);
    try std.testing.expectEqualStrings("tok", looked_up.?.text.items);

    const raw = try alloc.dupe(u8, "banner");
    const raw_id = try runtime.appendRawBytesEntry(alloc, raw);
    try std.testing.expect(runtime.lookupAssistantSegments(raw_id) == null);

    try std.testing.expect(runtime.lookupAssistantSegments(user_id) == null);

    try std.testing.expect(runtime.lookupAssistantSegments(std.math.maxInt(u32)) == null);
}

test "clearTranscript drops entries but preserves next_entry_id" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const first = try alloc.dupe(u8, "first");
    _ = try runtime.appendRawBytesEntry(alloc, first);
    const second = try alloc.dupe(u8, "second");
    _ = try runtime.appendRawBytesEntry(alloc, second);

    runtime.clearTranscript(alloc);
    try std.testing.expectEqual(@as(usize, 0), runtime.entries.items.len);

    const after = try alloc.dupe(u8, "after-clear");
    const id_after = try runtime.appendRawBytesEntry(alloc, after);
    try std.testing.expectEqual(@as(u32, 3), id_after);
}

test "writeTranscript auto-mirrors a raw_bytes entry" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());
    const alloc = std.testing.allocator;

    var runtime = TranscriptRuntime{ .stdout_file = sink, .layout = .{ .rows = 10, .cols = 80, .content_bottom = 7, .divider_top_row = 8, .input_row = 9, .divider_bottom_row = 10, .hint_row = 10 } };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    try runtime.initViewport(&metrics, 5);
    try runtime.writeTranscript(alloc, &metrics, "banner line\n", true);

    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .raw_bytes);
    try std.testing.expectEqualStrings("banner line\n", runtime.entries.items[0].raw_bytes.bytes);
}

test "writeTranscriptClassified records raw entry class" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);
    var metrics = Metrics{};

    try runtime.writeTranscriptClassified(alloc, &metrics, "cancelled\n", true, .question_resolution);

    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expectEqual(RawEntryClass.question_resolution, runtime.entries.items[0].raw_bytes.class);
}

const RecordedWriteToolDetailFixture = struct {
    entry_id: u32,
    tool_name: []const u8,
    arguments_json: []const u8,
    result: []const u8,
    result_handle: []const u8,
    turn_id: u64,
    call_id: []const u8,
    command_output_entry_id: u32,
};

fn appendRecordedWriteToolDetailFixture(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    fixture: RecordedWriteToolDetailFixture,
) !void {
    var detail: ToolDetailRecord = .{
        .entry_id = fixture.entry_id,
        .tool_name = try alloc.dupe(u8, fixture.tool_name),
    };
    errdefer detail.deinit(alloc);
    detail.arguments_json = try alloc.dupe(u8, fixture.arguments_json);
    detail.result = try alloc.dupe(u8, fixture.result);
    detail.result_handle = try alloc.dupe(u8, fixture.result_handle);
    detail.outcome = .completed;
    const lifecycle_call_id = try alloc.dupe(u8, fixture.call_id);
    detail.lifecycle_id = .{
        .turn_id = fixture.turn_id,
        .call_id = lifecycle_call_id,
    };
    detail.command_output_entry_id = fixture.command_output_entry_id;
    try runtime.tool_details.append(alloc, detail);
}

fn expectRecordedWriteToolDetailFixture(
    runtime: *const TranscriptRuntime,
    fixture: RecordedWriteToolDetailFixture,
) !void {
    const detail = runtime.toolDetailForEntry(fixture.entry_id);
    try std.testing.expect(detail != null);
    try std.testing.expectEqualStrings(fixture.tool_name, detail.?.tool_name);
    try std.testing.expectEqualStrings(fixture.arguments_json, detail.?.arguments_json.?);
    try std.testing.expectEqualStrings(fixture.result, detail.?.result.?);
    try std.testing.expectEqualStrings(fixture.result_handle, detail.?.result_handle.?);
    try std.testing.expectEqual(types.ToolOutcomeKind.completed, detail.?.outcome.?);
    try std.testing.expectEqual(fixture.turn_id, detail.?.lifecycle_id.?.turn_id);
    try std.testing.expectEqualStrings(fixture.call_id, detail.?.lifecycle_id.?.call_id);
    try std.testing.expectEqual(fixture.command_output_entry_id, detail.?.command_output_entry_id.?);
}

fn appendOwnedToolDetail(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    entry_id: u32,
    tool_name: []const u8,
) !void {
    var detail: ToolDetailRecord = .{
        .entry_id = entry_id,
        .tool_name = try alloc.dupe(u8, tool_name),
    };
    errdefer detail.deinit(alloc);
    try runtime.tool_details.append(alloc, detail);
}

test "historical tool detail insertion preserves entry id order" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    for ([_]u32{ 30, 10, 20 }) |entry_id| {
        try runtime.attachHistoricalToolDetail(
            alloc,
            entry_id,
            .{
                .id = "call",
                .name = "read_file",
                .arguments_json = "{}",
            },
            .read,
            .{
                .tool_call_id = @constCast("call"),
                .tool_name = @constCast("read_file"),
                .status = .success,
                .output = @constCast("result"),
                .output_bytes = 6,
                .stored_output_bytes = 6,
            },
        );
    }

    try std.testing.expectEqual(@as(usize, 3), runtime.tool_details.items.len);
    try std.testing.expectEqual(@as(u32, 10), runtime.tool_details.items[0].entry_id);
    try std.testing.expectEqual(@as(u32, 20), runtime.tool_details.items[1].entry_id);
    try std.testing.expectEqual(@as(u32, 30), runtime.tool_details.items[2].entry_id);
    try std.testing.expect(runtime.toolDetailForEntry(9) == null);
    try std.testing.expectEqual(@as(u32, 10), runtime.toolDetailForEntry(10).?.entry_id);
    try std.testing.expectEqual(@as(u32, 20), runtime.toolDetailForEntry(20).?.entry_id);
    try std.testing.expectEqual(@as(u32, 30), runtime.toolDetailForEntry(30).?.entry_id);
    try std.testing.expect(runtime.toolDetailForEntry(31) == null);

    try runtime.attachHistoricalToolDetail(
        alloc,
        20,
        .{
            .id = "updated-call",
            .name = "glob_files",
            .arguments_json = "{\"path\":\"src\"}",
        },
        .list,
        .{
            .tool_call_id = @constCast("updated-call"),
            .tool_name = @constCast("glob_files"),
            .status = .success,
            .output = @constCast("updated result"),
            .output_bytes = 14,
            .stored_output_bytes = 14,
        },
    );
    try std.testing.expectEqual(@as(usize, 3), runtime.tool_details.items.len);
    const updated = runtime.toolDetailForEntry(20).?;
    try std.testing.expectEqualStrings("glob_files", updated.tool_name);
    try std.testing.expectEqualStrings("{\"path\":\"src\"}", updated.arguments_json.?);
    try std.testing.expectEqualStrings("updated result", updated.result.?);
}

test "tool detail pruning preserves retained payload order and capacity" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    try appendOwnedToolDetail(&runtime, alloc, 1, "first");
    try appendOwnedToolDetail(&runtime, alloc, 2, "second");
    try appendOwnedToolDetail(&runtime, alloc, 3, "third");
    try appendOwnedToolDetail(&runtime, alloc, 4, "fourth");
    try appendOwnedToolDetail(&runtime, alloc, 5, "fifth");
    const initial_capacity = runtime.tool_details.capacity;

    var retained_entry_ids: transcript_store.EntryIdSet = .empty;
    defer retained_entry_ids.deinit(alloc);
    try retained_entry_ids.put(alloc, 2, {});
    try retained_entry_ids.put(alloc, 4, {});

    runtime.pruneToolDetailsForRetainedEntries(alloc, &retained_entry_ids);

    try std.testing.expectEqual(@as(usize, 2), runtime.tool_details.items.len);
    try std.testing.expectEqual(initial_capacity, runtime.tool_details.capacity);
    try std.testing.expectEqual(@as(u32, 2), runtime.tool_details.items[0].entry_id);
    try std.testing.expectEqualStrings("second", runtime.tool_details.items[0].tool_name);
    try std.testing.expectEqual(@as(u32, 4), runtime.tool_details.items[1].entry_id);
    try std.testing.expectEqualStrings("fourth", runtime.tool_details.items[1].tool_name);
}

test "tool detail pruning stays bounded at fifty thousand records" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const detail_count = 50_000;
    try runtime.tool_details.ensureTotalCapacity(alloc, detail_count);

    var retained_entry_ids: transcript_store.EntryIdSet = .empty;
    defer retained_entry_ids.deinit(alloc);
    try retained_entry_ids.ensureTotalCapacity(alloc, detail_count / 2);

    for (0..detail_count) |index| {
        const entry_id: u32 = @intCast(index + 1);
        try appendOwnedToolDetail(&runtime, alloc, entry_id, "read_file");
        if (index % 2 == 0) {
            retained_entry_ids.putAssumeCapacity(entry_id, {});
        }
    }

    const lookup_started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    for (0..detail_count) |index| {
        const entry_id: u32 = @intCast(index + 1);
        try std.testing.expect(runtime.toolDetailForEntry(entry_id) != null);
    }
    try std.testing.expect(runtime.toolDetailForEntry(
        @as(u32, @intCast(detail_count + 1)),
    ) == null);
    const lookup_elapsed_ms = lookup_started.durationTo(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
    ).raw.toMilliseconds();
    try std.testing.expect(lookup_elapsed_ms < 1_000);

    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    runtime.pruneToolDetailsForRetainedEntries(alloc, &retained_entry_ids);
    const elapsed_ms = started.durationTo(
        std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake),
    ).raw.toMilliseconds();

    try std.testing.expect(elapsed_ms < 1_000);
    try std.testing.expectEqual(detail_count / 2, runtime.tool_details.items.len);
    for (runtime.tool_details.items, 0..) |detail, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index * 2 + 1)), detail.entry_id);
        try std.testing.expectEqualStrings("read_file", detail.tool_name);
    }
}

const RecordedWriteCommandOutputFixture = struct {
    entry_id: u32,
    turn_id: u64,
    call_id: []const u8,
    line: []const u8,
};

fn appendRecordedWriteCommandOutputFixture(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    fixture: RecordedWriteCommandOutputFixture,
) !void {
    const Block = @TypeOf(runtime.command_output_blocks.items[0]);
    var block: Block = .{
        .entry_id = fixture.entry_id,
        .lifecycle_id = .{
            .turn_id = fixture.turn_id,
            .call_id = try alloc.dupe(u8, fixture.call_id),
        },
    };
    errdefer block.deinit(alloc);
    const line = try alloc.dupe(u8, fixture.line);
    block.lines.append(alloc, .{
        .stream = .stdout,
        .text = line,
    }) catch |err| {
        alloc.free(line);
        return err;
    };
    block.total_lines = 1;
    block.retained_text_bytes = line.len;
    try runtime.command_output_blocks.append(alloc, block);
}

fn expectRecordedWriteCommandOutputFixture(
    runtime: *const TranscriptRuntime,
    fixture: RecordedWriteCommandOutputFixture,
) !void {
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(fixture.entry_id, block.entry_id.?);
    try std.testing.expect(block.lifecycle_id != null);
    try std.testing.expectEqual(fixture.turn_id, block.lifecycle_id.?.turn_id);
    try std.testing.expectEqualStrings(fixture.call_id, block.lifecycle_id.?.call_id);
    try std.testing.expectEqual(@as(usize, 1), block.lines.items.len);
    try std.testing.expectEqual(command_output_content.Stream.stdout, block.lines.items[0].stream);
    try std.testing.expectEqualStrings(fixture.line, block.lines.items[0].text);
}

test "command output retention preserves its artifact detail owner" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .max_retained_transcript_bytes = 128 };
    defer runtime.deinit(alloc);

    const detail_entry_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "● Ran command\n",
        .tool_status,
    );
    const command_entry_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "│ ... command lines folded\n",
        .command_output,
    );
    const detail: RecordedWriteToolDetailFixture = .{
        .entry_id = detail_entry_id,
        .tool_name = "run_command",
        .arguments_json = "{\"command\":\"generate output\"}",
        .result = "output_file=/tmp/fx-command-retained.log\n",
        .result_handle = "result-run-command.txt",
        .turn_id = 1,
        .call_id = "retained-command",
        .command_output_entry_id = command_entry_id,
    };
    try appendRecordedWriteToolDetailFixture(&runtime, alloc, detail);
    try appendRecordedWriteCommandOutputFixture(&runtime, alloc, .{
        .entry_id = command_entry_id,
        .turn_id = 1,
        .call_id = "retained-command",
        .line = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    });
    runtime.command_output_blocks.items[0].total_lines = 2;

    try transcript_store.enforceStructuredRetention(&runtime, alloc, command_entry_id);

    try std.testing.expect(runtime.toolDetailForEntry(detail_entry_id) != null);
    try std.testing.expect(runtime.rawEntryClass(detail_entry_id) == .tool_status);
    try std.testing.expect(runtime.rawEntryClass(command_entry_id) == .command_output);
    try std.testing.expectEqual(@as(usize, 2), runtime.command_output_blocks.items[0].total_lines);
    try std.testing.expectEqual(@as(usize, 0), runtime.command_output_blocks.items[0].lines.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.command_output_blocks.items[0].retained_text_bytes);
    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes);
}

fn checkRecordedTranscriptWriteAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 2,
        .cursor_col = 4,
        .max_transcript_bytes = 8,
        .max_retained_transcript_bytes = 19 + @sizeOf(command_output_runtime.CommandOutputLine),
        .command_output_render = .{},
    };
    defer runtime.deinit(alloc);

    const existing_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "old\n",
        .subagent_status,
    );
    const replaceable_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "tail\n",
        .subagent_status,
    );
    const pruned_detail: RecordedWriteToolDetailFixture = .{
        .entry_id = existing_id,
        .tool_name = "read_file",
        .arguments_json = "{\"path\":\"old\"}",
        .result = "old result",
        .result_handle = "old-result.txt",
        .turn_id = 1,
        .call_id = "call-old",
        .command_output_entry_id = existing_id,
    };
    const retained_detail: RecordedWriteToolDetailFixture = .{
        .entry_id = replaceable_id,
        .tool_name = "write_file",
        .arguments_json = "{\"path\":\"tail\"}",
        .result = "tail result",
        .result_handle = "tail-result.txt",
        .turn_id = 2,
        .call_id = "call-tail",
        .command_output_entry_id = replaceable_id,
    };
    const retained_command_output: RecordedWriteCommandOutputFixture = .{
        .entry_id = replaceable_id,
        .turn_id = 3,
        .call_id = "call-command-tail",
        .line = "x",
    };
    try appendRecordedWriteToolDetailFixture(&runtime, alloc, pruned_detail);
    try appendRecordedWriteToolDetailFixture(&runtime, alloc, retained_detail);
    try appendRecordedWriteCommandOutputFixture(&runtime, alloc, retained_command_output);
    runtime.cursor_row = 2;
    runtime.cursor_col = 4;
    runtime.replaceable_last_line = true;
    runtime.replaceable_start = 0;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;

    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const replaceable_before = runtime.replaceable_last_line;
    const replaceable_start_before = runtime.replaceable_start;
    const repaint_count_before = runtime.render_requests.pendingReasonCount();
    const transcript_before = "tail\n";
    try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);

    var metrics = Metrics{};
    const entry_id = transcript_writer.writeTranscriptReturningEntryIdClassified(
        &runtime,
        alloc,
        &metrics,
        "first\nsecond\n",
        true,
        .question_resolution,
    ) catch |err| {
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(existing_id, runtime.entries.items[0].id());
        try std.testing.expectEqualStrings("old\n", runtime.entries.items[0].raw_bytes.bytes);
        try std.testing.expectEqual(replaceable_id, runtime.entries.items[1].id());
        try std.testing.expectEqualStrings("tail\n", runtime.entries.items[1].raw_bytes.bytes);
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(replaceable_before, runtime.replaceable_last_line);
        try std.testing.expectEqual(replaceable_start_before, runtime.replaceable_start);
        try std.testing.expectEqual(@as(usize, 2), runtime.tool_details.items.len);
        try expectRecordedWriteToolDetailFixture(&runtime, pruned_detail);
        try expectRecordedWriteToolDetailFixture(&runtime, retained_detail);
        try expectRecordedWriteCommandOutputFixture(&runtime, retained_command_output);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return err;
    };

    try std.testing.expectEqual(@as(u32, 3), entry_id);
    try std.testing.expectEqual(@as(u32, 4), runtime.next_entry_id);
    try std.testing.expectEqual(@as(usize, 2), runtime.entries.items.len);
    try std.testing.expectEqual(replaceable_id, runtime.entries.items[0].id());
    try std.testing.expectEqual(entry_id, runtime.entries.items[1].id());
    try std.testing.expectEqual(RawEntryClass.question_resolution, runtime.entries.items[1].raw_bytes.class);
    try std.testing.expectEqualStrings("first\nsecond\n", runtime.entries.items[1].raw_bytes.bytes);
    try std.testing.expectEqualStrings("second\n", runtime.transcript.items);
    try std.testing.expect(!runtime.replaceable_last_line);
    try std.testing.expectEqual(@as(usize, 0), runtime.replaceable_start);
    try std.testing.expectEqual(@as(usize, 1), runtime.tool_details.items.len);
    try std.testing.expect(runtime.toolDetailForEntry(existing_id) == null);
    try expectRecordedWriteToolDetailFixture(&runtime, retained_detail);
    try expectRecordedWriteCommandOutputFixture(&runtime, retained_command_output);
    try std.testing.expectEqual(@as(usize, 1), runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}

test "recorded transcript write is atomic across entry cache and retention allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRecordedTranscriptWriteAllocationFailures,
        .{},
    );
}

test "context notices stay canonical and ordered across compact and full projections" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(80, 24, 20) };
    defer runtime.deinit(alloc);
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "context",
        .tone = .warning,
        .body = "context-first",
        .visibility = .full_only,
    });
    try std.testing.expectEqualStrings("", runtime.transcript.items);
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "system",
        .tone = .information,
        .body = "ordinary-system",
    });
    const compact_before_open = try alloc.dupe(u8, runtime.transcript.items);
    defer alloc.free(compact_before_open);
    try std.testing.expect(std.mem.find(u8, compact_before_open, "context-first") == null);
    try std.testing.expect(std.mem.find(u8, compact_before_open, "ordinary-system") != null);

    try std.testing.expect(try runtime.setTranscriptPresentationDepth(alloc, .full));
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "context",
        .tone = .warning,
        .body = "context-second",
        .visibility = .full_only,
    });
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "system",
        .tone = .@"error",
        .body = "ordinary-error",
    });
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "context-first") == null);
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "context-second") == null);
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "ordinary-system") != null);
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "ordinary-error") != null);
    const compact_while_open = try alloc.dupe(u8, runtime.transcript.items);
    defer alloc.free(compact_while_open);

    try std.testing.expectEqual(@as(usize, 4), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .semantic_notice);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, runtime.entries.items[0].semantic_notice.visibility);
    try std.testing.expectEqualStrings("context-first", runtime.entries.items[0].semantic_notice.body);
    try std.testing.expect(runtime.entries.items[1] == .semantic_notice);
    try std.testing.expectEqual(types.NoticeVisibility.compact_and_full, runtime.entries.items[1].semantic_notice.visibility);
    try std.testing.expectEqualStrings("ordinary-system", runtime.entries.items[1].semantic_notice.body);
    try std.testing.expect(runtime.entries.items[2] == .semantic_notice);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, runtime.entries.items[2].semantic_notice.visibility);
    try std.testing.expectEqualStrings("context-second", runtime.entries.items[2].semantic_notice.body);
    try std.testing.expect(runtime.entries.items[3] == .semantic_notice);
    try std.testing.expectEqual(types.NoticeTone.@"error", runtime.entries.items[3].semantic_notice.tone);

    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const full = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        64,
        0,
        null,
    );
    defer alloc.free(full);
    const first_pos = std.mem.find(u8, full, "context-first") orelse
        return error.MissingFirstContextNotice;
    const system_pos = std.mem.find(u8, full, "ordinary-system") orelse
        return error.MissingOrdinarySystemNotice;
    const second_pos = std.mem.find(u8, full, "context-second") orelse
        return error.MissingSecondContextNotice;
    const error_pos = std.mem.find(u8, full, "ordinary-error") orelse
        return error.MissingOrdinaryErrorNotice;
    try std.testing.expect(first_pos < system_pos);
    try std.testing.expect(system_pos < second_pos);
    try std.testing.expect(second_pos < error_pos);

    try std.testing.expect(try runtime.setTranscriptPresentationDepth(alloc, .inline_mode));
    try std.testing.expect(!runtime.fullTranscriptActive());
    try std.testing.expectEqualStrings(compact_while_open, runtime.transcript.items);
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "context-first") == null);
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "context-second") == null);
}

fn checkContextNoticeAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(40, 12, 8) };
    defer runtime.deinit(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "visible-before\n",
        .subagent_status,
    );
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;

    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    _ = transcript_store.appendSemanticNoticeAtomic(
        &runtime,
        alloc,
        .{
            .topic = "context",
            .tone = .warning,
            .body = "hidden-context",
            .visibility = .full_only,
        },
    ) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
        try std.testing.expectEqual(RawEntryClass.subagent_status, runtime.entries.items[0].raw_bytes.class);
        try std.testing.expectEqualStrings("visible-before\n", runtime.entries.items[0].raw_bytes.bytes);
        try std.testing.expectEqualStrings("visible-before\n", runtime.transcript.items);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return err;
    };

    try std.testing.expectEqual(@as(usize, 2), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[1] == .semantic_notice);
    try std.testing.expectEqualStrings("context", runtime.entries.items[1].semantic_notice.topic);
    try std.testing.expectEqualStrings("hidden-context", runtime.entries.items[1].semantic_notice.body);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, runtime.entries.items[1].semantic_notice.visibility);
    try std.testing.expectEqualStrings("visible-before\n", runtime.transcript.items);
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}

test "context notice admission is atomic across entry cache and retention allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkContextNoticeAllocationFailures,
        .{},
    );
}

test "repeated recorded mutations keep tool detail capacity bounded" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(80, 12, 8) };
    defer runtime.deinit(alloc);

    const fixture: RecordedWriteToolDetailFixture = .{
        .entry_id = 1,
        .tool_name = "run_command",
        .arguments_json = "{\"command\":\"pwd\"}",
        .result = "workspace",
        .result_handle = "command-output.txt",
        .turn_id = 1,
        .call_id = "bounded-tool-detail",
        .command_output_entry_id = 1,
    };
    try appendRecordedWriteToolDetailFixture(&runtime, alloc, fixture);
    const initial_capacity = runtime.tool_details.capacity;
    var metrics = Metrics{};

    for (0..4) |_| {
        try runtime.writeTranscriptClassified(
            alloc,
            &metrics,
            "recorded\n",
            true,
            .subagent_status,
        );
    }

    try std.testing.expect(runtime.tool_details.capacity <= initial_capacity);
    try expectRecordedWriteToolDetailFixture(&runtime, fixture);
}

const RecordedCommandOutputAtomicFixture = struct {
    lifecycle_id: types.ToolLifecycleId,
    status_entry_id: u32,
};

fn setupRecordedCommandOutputAtomicFixture(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
) !RecordedCommandOutputAtomicFixture {
    const lifecycle_id = types.ToolLifecycleId{
        .turn_id = 71,
        .call_id = "atomic-command-output",
    };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = lifecycle_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"printf atomic\"}",
    } });
    const status_entry_id = runtime.toolActivityRecord(lifecycle_id).?.entry_id;
    runtime.full_transcript.depth = .full;
    runtime.full_transcript.scroll_rows = 3;
    runtime.full_transcript.follow_tail = false;
    runtime.full_transcript.anchor_entry_id = status_entry_id;
    runtime.full_transcript.anchor_pending = true;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;
    return .{
        .lifecycle_id = lifecycle_id,
        .status_entry_id = status_entry_id,
    };
}

fn expectRecordedCommandOutputAnchor(
    runtime: *const TranscriptRuntime,
    entry_id: u32,
) !void {
    try std.testing.expect(runtime.full_transcript.depth.active());
    try std.testing.expectEqual(@as(u32, 3), runtime.full_transcript.scroll_rows);
    try std.testing.expect(!runtime.full_transcript.follow_tail);
    try std.testing.expectEqual(entry_id, runtime.full_transcript.anchor_entry_id.?);
    try std.testing.expect(runtime.full_transcript.anchor_pending);
}

test "visible recorded command output preserves a capped canonical anchor without pruning" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    const status_entry_id = try transcript_store.appendPinnedToolStatusAtomic(
        &runtime,
        alloc,
        "canonical command status prefix extends beyond the capped cache\nretained status tail\n",
    );
    var metrics: Metrics = .{};
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try std.testing.expect(committed_source.recorded_entries_authoritative);
    try std.testing.expect(committed_source.bytes.len > runtime.transcript.items.len);
    var committed_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer committed_prepared.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        committed_prepared.selection,
        preparedVisualOffsetForTest(&committed_prepared),
        committed_prepared.cursor.cursor_row,
        committed_prepared.cursor.cursor_col,
        1,
    );
    const committed_diagnostic = runtime.transcriptCommitDiagnostic();

    const styles = commandOutputAnsiTestStyles();
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    runtime.max_retained_transcript_bytes = retained_before + 512;

    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "visible\n",
        true,
    );

    try std.testing.expectEqualDeep(
        committed_diagnostic,
        runtime.transcriptCommitDiagnostic(),
    );
    try std.testing.expectEqual(@as(usize, 2), runtime.entries.items.len);
    try std.testing.expectEqual(status_entry_id, runtime.entries.items[0].id());
    try std.testing.expect(runtime.entries.items[0].raw_bytes.lifecycle_pinned);
    try std.testing.expectEqual(RawEntryClass.command_output, runtime.entries.items[1].raw_bytes.class);
    try std.testing.expectEqualStrings(
        "\x1b[2m│ visible\x1b[0m",
        runtime.entries.items[1].raw_bytes.bytes,
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 1), block.total_lines);
    try std.testing.expectEqual(@as(usize, 1), block.lines.items.len);
    try std.testing.expectEqual(@as(usize, 1), block.live_entry_ids.items.len);
    try std.testing.expectEqual(runtime.entries.items[1].id(), block.live_entry_ids.items[0]);
    try std.testing.expect(
        transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes,
    );
    var appended_source = try runtime.prepareTranscriptSource(alloc, null);
    defer appended_source.deinit(alloc);
    try std.testing.expect(std.mem.startsWith(
        u8,
        appended_source.bytes,
        committed_source.bytes,
    ));
}

test "visible recorded command output survives consolidation" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);

    const fixture = try setupRecordedCommandOutputAtomicFixture(&runtime, alloc);
    var metrics: Metrics = .{};
    const styles = commandOutputAnsiTestStyles();
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    runtime.max_retained_transcript_bytes = retained_before + 512;

    try runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        .stdout,
        "visible\n",
        true,
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items[0].lines.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items[0].live_entry_ids.items.len);
    const live_entry_id = runtime.command_output_blocks.items[0].live_entry_ids.items[0];
    runtime.full_transcript.anchor_entry_id = live_entry_id;

    try runtime.flushCommandOutputSummaryForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        true,
    );

    const block = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 0), block.live_entry_ids.items.len);
    try std.testing.expectEqualSlices(u32, &.{live_entry_id}, block.source_entry_ids.items);
    try std.testing.expectEqual(live_entry_id, block.entry_id.?);
    try std.testing.expectEqual(
        live_entry_id,
        runtime.toolDetailForEntry(fixture.status_entry_id).?.command_output_entry_id.?,
    );
    try std.testing.expectEqual(live_entry_id, runtime.fullTranscriptAnchorEntryId().?);

    var consolidated_source = try runtime.prepareTranscriptSource(alloc, null);
    defer consolidated_source.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, consolidated_source.bytes, "visible"));

    runtime.setCommandOutputRenderPolicy(styles);
    _ = try command_output_runtime.syncCommandOutputBlockEntries(&runtime, alloc);
    var synchronized_source = try runtime.prepareTranscriptSource(alloc, null);
    defer synchronized_source.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, synchronized_source.bytes, "visible"));

    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const projected = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        32,
        0,
        null,
    );
    defer alloc.free(projected);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, projected, "visible"));
    try std.testing.expect((try full_transcript_screen.measureProjectionInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        null,
    )).anchor_row != null);
}

test "retention capped command output retargets a missing source anchor" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const missing_entry_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "│ pruned\n",
        .command_output,
    );
    const retained_entry_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "│ retained\n",
        .command_output,
    );
    try runtime.command_output_blocks.append(alloc, .{ .total_lines = 2 });
    try runtime.command_output_blocks.items[0].live_entry_ids.append(alloc, missing_entry_id);
    try runtime.command_output_blocks.items[0].live_entry_ids.append(alloc, retained_entry_id);
    runtime.command_output_display.open_command_block = 0;
    runtime.full_transcript.depth = .full;
    runtime.full_transcript.anchor_entry_id = missing_entry_id;
    try removeRawEntriesForTest(&runtime, alloc, &.{missing_entry_id});

    var metrics: Metrics = .{};
    const styles = commandOutputAnsiTestStyles();
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);

    try std.testing.expectEqual(retained_entry_id, runtime.command_output_blocks.items[0].entry_id.?);
    try std.testing.expectEqual(retained_entry_id, runtime.fullTranscriptAnchorEntryId().?);
    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const measurement = try full_transcript_screen.measureProjectionInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        null,
    );
    try std.testing.expect(measurement.anchor_row != null);
}

fn checkVisibleRecordedCommandOutputAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 12, 8),
    };
    defer runtime.deinit(alloc);
    const fixture = try setupRecordedCommandOutputAtomicFixture(&runtime, alloc);

    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const repaint_count_before = runtime.render_requests.pendingReasonCount();
    var metrics = Metrics{};
    const styles = commandOutputAnsiTestStyles();

    runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        .stdout,
        "visible\n",
        true,
    ) catch |err| {
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(@as(usize, 0), runtime.command_output_blocks.items.len);
        try std.testing.expect(runtime.command_output_display.open_command_block == null);
        try std.testing.expectEqualDeep(command_output_runtime.CommandOutputRenderPolicy{}, runtime.command_output_render);
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expect(runtime.toolDetailForEntry(fixture.status_entry_id).?.command_output_entry_id == null);
        try expectRecordedCommandOutputAnchor(&runtime, fixture.status_entry_id);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expectEqual(entry_count_before + 1, runtime.entries.items.len);
    try std.testing.expectEqual(next_entry_id_before +% 1, runtime.next_entry_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expect(command_output_runtime.sameLifecycleId(block.lifecycle_id, fixture.lifecycle_id));
    try std.testing.expectEqual(@as(usize, 1), block.lines.items.len);
    try std.testing.expectEqual(command_output_content.Stream.stdout, block.lines.items[0].stream);
    try std.testing.expectEqualStrings("visible", block.lines.items[0].text);
    try std.testing.expectEqual(@as(usize, 1), block.live_entry_ids.items.len);
    try std.testing.expectEqual(runtime.entries.items[entry_count_before].id(), block.live_entry_ids.items[0]);
    try std.testing.expectEqual(RawEntryClass.command_output, runtime.entries.items[entry_count_before].raw_bytes.class);
    try std.testing.expectEqualStrings("\x1b[2m│ visible\x1b[0m", runtime.entries.items[entry_count_before].raw_bytes.bytes);
    try std.testing.expectEqualDeep(styles, runtime.command_output_render.styles);
    try std.testing.expectEqual(@as(?usize, 0), runtime.command_output_display.open_command_block);
    try std.testing.expect(runtime.toolDetailForEntry(fixture.status_entry_id).?.command_output_entry_id == null);
    try expectRecordedCommandOutputAnchor(&runtime, fixture.status_entry_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}

fn checkVisibleRecordedCommandOutputAllocationFailures(alloc: Allocator) !void {
    return checkVisibleRecordedCommandOutputAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

test "visible recorded command output admission is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkVisibleRecordedCommandOutputAllocationFailures,
        .{},
    );
}

fn checkRecordedCommandOutputConsolidationAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 12, 8),
    };
    defer runtime.deinit(alloc);
    const fixture = try setupRecordedCommandOutputAtomicFixture(&runtime, alloc);
    var metrics = Metrics{};
    const styles = commandOutputAnsiTestStyles();

    runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        .stdout,
        "one\n",
        true,
    ) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
    runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        .stderr,
        "two\n",
        true,
    ) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };

    const first_live_entry_id = runtime.command_output_blocks.items[0].live_entry_ids.items[0];
    runtime.full_transcript.anchor_entry_id = first_live_entry_id;
    runtime.render_requests.clearReason(.transcript);
    runtime.transcript_band_dirty = false;
    const rendered_before = try renderEntriesToBytes(std.testing.allocator, runtime.entries.items, 80);
    defer std.testing.allocator.free(rendered_before);
    const transcript_before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(transcript_before);
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    const repaint_count_before = runtime.render_requests.pendingReasonCount();

    runtime.flushCommandOutputSummaryForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        true,
    ) catch |err| {
        const rendered_after_failure = try renderEntriesToBytes(
            std.testing.allocator,
            runtime.entries.items,
            80,
        );
        defer std.testing.allocator.free(rendered_after_failure);
        try std.testing.expectEqualStrings(rendered_before, rendered_after_failure);
        try std.testing.expectEqualStrings(transcript_before, runtime.transcript.items);
        try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
        try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
        const block = runtime.command_output_blocks.items[0];
        try std.testing.expect(block.entry_id == null);
        try std.testing.expectEqual(@as(usize, 2), block.live_entry_ids.items.len);
        try std.testing.expectEqual(@as(usize, 0), block.source_entry_ids.items.len);
        try std.testing.expectEqual(@as(?usize, 0), runtime.command_output_display.open_command_block);
        try std.testing.expect(runtime.toolDetailForEntry(fixture.status_entry_id).?.command_output_entry_id == null);
        try expectRecordedCommandOutputAnchor(&runtime, first_live_entry_id);
        try std.testing.expectEqual(repaint_count_before, runtime.render_requests.pendingReasonCount());
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
        try std.testing.expect(!runtime.transcript_band_dirty);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    const rendered_after = try renderEntriesToBytes(std.testing.allocator, runtime.entries.items, 80);
    defer std.testing.allocator.free(rendered_after);
    try std.testing.expectEqualStrings(rendered_before, rendered_after);
    try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
    try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
    try std.testing.expectEqual(retained_before, transcript_store.retainedStructuredBytes(&runtime));
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expect(block.entry_id != null);
    try std.testing.expectEqual(@as(usize, 0), block.live_entry_ids.items.len);
    try std.testing.expectEqual(@as(usize, 2), block.source_entry_ids.items.len);
    try std.testing.expectEqualStrings("one", block.lines.items[0].text);
    try std.testing.expectEqualStrings("two", block.lines.items[1].text);
    try std.testing.expect(runtime.command_output_display.open_command_block == null);
    try std.testing.expectEqual(block.entry_id, runtime.toolDetailForEntry(fixture.status_entry_id).?.command_output_entry_id);
    try expectRecordedCommandOutputAnchor(&runtime, first_live_entry_id);
    try std.testing.expectEqual(@as(usize, 1), runtime.render_requests.pendingReasonCount());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
    try std.testing.expect(runtime.transcript_band_dirty);
}

fn checkRecordedCommandOutputConsolidationAllocationFailures(alloc: Allocator) !void {
    return checkRecordedCommandOutputConsolidationAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

test "recorded command output consolidation is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRecordedCommandOutputConsolidationAllocationFailures,
        .{},
    );
}

test "recorded command output consolidation preserves a capped canonical anchor without recovery fallback" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    var metrics: Metrics = .{};
    try runtime.writeTranscript(
        alloc,
        &metrics,
        "canonical command output prefix extends beyond the capped cache\nretained command output prefix tail\n",
        true,
    );
    const fixture = try setupRecordedCommandOutputAtomicFixture(&runtime, alloc);
    const styles = commandOutputAnsiTestStyles();
    try runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        .stdout,
        "one\n",
        true,
    );
    try runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        .stderr,
        "two\n",
        true,
    );

    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try std.testing.expect(committed_source.recorded_entries_authoritative);
    try std.testing.expect(committed_source.bytes.len > runtime.transcript.items.len);
    var committed_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer committed_prepared.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        committed_prepared.selection,
        preparedVisualOffsetForTest(&committed_prepared),
        committed_prepared.cursor.cursor_row,
        committed_prepared.cursor.cursor_col,
        1,
    );
    const committed_diagnostic = runtime.transcriptCommitDiagnostic();
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);

    try runtime.flushCommandOutputSummaryForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        true,
    );

    try std.testing.expectEqualDeep(
        committed_diagnostic,
        runtime.transcriptCommitDiagnostic(),
    );
    try std.testing.expectEqual(
        retained_before,
        transcript_store.retainedStructuredBytes(&runtime),
    );
    try std.testing.expectEqual(@as(usize, 2), runtime.command_output_blocks.items[0].lines.items.len);
    var consolidated_source = try runtime.prepareTranscriptSource(alloc, null);
    defer consolidated_source.deinit(alloc);
    try std.testing.expectEqualStrings(committed_source.bytes, consolidated_source.bytes);
    switch (runtime.transcript_commit_state) {
        .stable => |anchor| try std.testing.expect(!anchor.normal_buffer_recovery_pending),
        .invalid, .recovering => return error.TestExpectedStableTranscript,
    }
}

test "recorded command output completion does not allocate without a matching block" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(80, 12, 8) };
    defer runtime.deinit(alloc);
    var metrics = Metrics{};
    const styles = commandOutputAnsiTestStyles();

    try runtime.writeTranscript(alloc, &metrics, "existing\n", true);
    var no_open_failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try runtime.flushCommandOutputSummaryForLifecycle(
        no_open_failing.allocator(),
        &metrics,
        styles,
        null,
        true,
    );
    try std.testing.expectEqualDeep(styles, runtime.command_output_render.styles);
    try std.testing.expect(runtime.command_output_display.open_command_block == null);

    const open_id = types.ToolLifecycleId{ .turn_id = 81, .call_id = "open-command" };
    try runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        open_id,
        .stdout,
        "open\n",
        true,
    );
    const entry_count_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;
    const display_before = runtime.command_output_display;
    const mismatch_id = types.ToolLifecycleId{ .turn_id = 82, .call_id = "other-command" };
    var mismatch_failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try runtime.flushCommandOutputSummaryForLifecycle(
        mismatch_failing.allocator(),
        &metrics,
        styles,
        mismatch_id,
        true,
    );

    try std.testing.expectEqualDeep(styles, runtime.command_output_render.styles);
    try std.testing.expectEqual(entry_count_before, runtime.entries.items.len);
    try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
    try std.testing.expectEqual(display_before.open_command_block, runtime.command_output_display.open_command_block);
}

test "recorded command output consolidation preserves its anchor when retention changes" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(80, 12, 8) };
    defer runtime.deinit(alloc);
    const fixture = try setupRecordedCommandOutputAtomicFixture(&runtime, alloc);
    var metrics = Metrics{};
    const styles = commandOutputAnsiTestStyles();

    try runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        .stdout,
        "one\n",
        true,
    );
    try runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        .stdout,
        "two\n",
        true,
    );
    const retained_before = transcript_store.retainedStructuredBytes(&runtime);
    runtime.max_retained_transcript_bytes = retained_before - 1;
    try runtime.enableShadowVt(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        "pre-retention source\n",
        testSelection(0),
        0,
        3,
        1,
        91,
    );
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    const committed_history_visual_offset = try stableHistoryVisualOffsetForTest(&runtime);

    try runtime.flushCommandOutputSummaryForLifecycle(
        alloc,
        &metrics,
        styles,
        fixture.lifecycle_id,
        true,
    );

    try std.testing.expect(transcript_store.retainedStructuredBytes(&runtime) <= runtime.max_retained_transcript_bytes);
    try std.testing.expect(runtime.command_output_blocks.items[0].lines.items.len < 2);
    try expectStableNormalBufferRecoveryForTest(
        &runtime,
        committed_history_visual_offset,
    );
}

test "writeTranscriptBytes does NOT append an entry" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());
    const alloc = std.testing.allocator;

    var runtime = TranscriptRuntime{ .stdout_file = sink, .layout = .{ .rows = 10, .cols = 80, .content_bottom = 7, .divider_top_row = 8, .input_row = 9, .divider_bottom_row = 10, .hint_row = 10 } };
    defer runtime.deinit(alloc);

    var metrics = Metrics{};
    try runtime.initViewport(&metrics, 5);
    try runtime.writeTranscriptBytes(alloc, &metrics, "structured writer bytes\n", true);

    try std.testing.expectEqual(@as(usize, 0), runtime.entries.items.len);
    try std.testing.expect(std.mem.indexOf(u8, runtime.transcript.items, "structured writer bytes") != null);
}

test "appendReplaceableTranscriptLineSilent mirrors a raw_bytes entry" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    _ = try runtime.appendReplaceableTranscriptLineSilent(alloc, "Thinking...\n");
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .raw_bytes);
    try std.testing.expectEqualStrings("Thinking...\n", runtime.entries.items[0].raw_bytes.bytes);
    try std.testing.expect(runtime.replaceable_last_line);
}

test "classified replaceable append stores raw entry class" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const entry_id = try runtime.appendReplaceableTranscriptLineSilentClassified(alloc, "Thinking...\n", .subagent_status);

    try std.testing.expectEqual(RawEntryClass.subagent_status, runtime.rawEntryClass(entry_id).?);
}

test "replaceTrailingTranscriptLineSilent swaps the trailing entry's bytes in place" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    _ = try runtime.appendReplaceableTranscriptLineSilent(alloc, "Thinking...\n");
    const initial_id = runtime.entries.items[0].id();

    const replaced = try runtime.replaceTrailingTranscriptLineSilent(alloc, "Thinking... done\n");
    try std.testing.expect(replaced);
    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expectEqual(initial_id, runtime.entries.items[0].id());
    try std.testing.expectEqualStrings("Thinking... done\n", runtime.entries.items[0].raw_bytes.bytes);
}

test "updateRawBytesEntry swaps bytes when entry is trailing" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const entry_id = try runtime.appendReplaceableTranscriptLineSilent(alloc, "modal v1\n");
    try std.testing.expect(entry_id != 0);
    try std.testing.expectEqualStrings("modal v1\n", runtime.entries.items[0].raw_bytes.bytes);

    const ok = try runtime.updateRawBytesEntry(alloc, entry_id, "modal v2\n");
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("modal v2\n", runtime.entries.items[0].raw_bytes.bytes);
    try std.testing.expectEqualStrings("modal v2\n", runtime.transcript.items);
    try std.testing.expect(runtime.replaceable_last_line);
    try std.testing.expectEqual(runtime.transcript.items.len - "modal v2\n".len, runtime.replaceable_start);
}

test "updateRawBytesEntry swaps bytes when entry is in middle" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const id_a = try runtime.appendReplaceableTranscriptLineSilent(alloc, "block A\n");
    const dup_b = try alloc.dupe(u8, "block B\n");
    _ = try runtime.appendRawBytesEntry(alloc, dup_b);
    try runtime.transcript.appendSlice(alloc, "block B\n");

    const ok = try runtime.updateRawBytesEntry(alloc, id_a, "block A updated\n");
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings("block A updated\n", runtime.entries.items[0].raw_bytes.bytes);
    try std.testing.expect(runtime.entries.items[1] == .raw_bytes);
    try std.testing.expectEqualStrings("block B\n", runtime.entries.items[1].raw_bytes.bytes);
    try std.testing.expect(std.mem.indexOf(u8, runtime.transcript.items, "block A updated\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.transcript.items, "block B\n") != null);
    try std.testing.expect(!runtime.replaceable_last_line);
}

test "updateRawBytesEntry returns false for unknown id" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    _ = try runtime.appendReplaceableTranscriptLineSilent(alloc, "existing\n");
    const ok = try runtime.updateRawBytesEntry(alloc, 9999, "nope\n");
    try std.testing.expect(!ok);
    try std.testing.expectEqualStrings("existing\n", runtime.entries.items[0].raw_bytes.bytes);
}

test "updateRawBytesEntry returns false for non-raw_bytes entry" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const text = try alloc.dupe(u8, "hello user");
    const user_id = try runtime.appendUserTurnOwned(alloc, .{ .text = text, .images = &.{} });
    const ok = try runtime.updateRawBytesEntry(alloc, user_id, "hijack\n");
    try std.testing.expect(!ok);
}

test "updateRawBytesEntry updates modal entry in place after intervening append" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const modal_id = try runtime.appendReplaceableTranscriptLineSilent(alloc, "modal v1\n");
    const stream_dup = try alloc.dupe(u8, "stream chunk\n");
    _ = try runtime.appendRawBytesEntry(alloc, stream_dup);
    try runtime.transcript.appendSlice(alloc, "stream chunk\n");

    const ok = try runtime.updateRawBytesEntry(alloc, modal_id, "modal v2\n");
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 2), runtime.entries.items.len);
    try std.testing.expectEqualStrings("modal v2\n", runtime.entries.items[0].raw_bytes.bytes);
    try std.testing.expect(std.mem.indexOf(u8, runtime.transcript.items, "modal v2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.transcript.items, "stream chunk\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.transcript.items, "modal v1") == null);
}

test "tool status raw entry updates after command output appends" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 21,
        .divider_top_row = 22,
        .input_row = 23,
        .divider_bottom_row = 24,
        .hint_row = 22,
    } };
    defer runtime.deinit(alloc);
    var metrics = Metrics{};

    const status_id = try runtime.appendRawTranscriptEntry(alloc, "Running npm test\n");
    try runtime.writeCommandOutputChunk(alloc, &metrics, .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    }, .stdout, "ok\n", true);

    const updated = try runtime.updateRawBytesEntry(alloc, status_id, "Ran npm test\n");
    try std.testing.expect(updated);
    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "Ran npm test") != null);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "│ ok") == null);
    try std.testing.expect(std.mem.indexOf(u8, source.bytes, "Running npm test") == null);

    runtime.full_transcript.depth = .full;
    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const full = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        64,
        0,
        null,
    );
    defer alloc.free(full);
    try std.testing.expect(std.mem.indexOf(u8, full, "│ ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, full, "Running npm test") == null);
}

test "advanceCursor row advance matches visualRowsForLine - 1 for wrap-exact content" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 40,
            .cols = 3,
            .content_bottom = 37,
            .divider_top_row = 38,
            .input_row = 39,
            .divider_bottom_row = 40,
            .hint_row = 40,
        },
    };
    defer runtime.deinit(std.testing.allocator);

    const text = "abcdef";
    try std.testing.expectEqual(@as(u16, 2), visualRowsForLine(text, 3));

    runtime.cursor_row = 1;
    runtime.cursor_col = 1;
    _ = runtime.advanceCursor(text);
    try std.testing.expectEqual(@as(u16, 2), runtime.cursor_row);
}

test "advanceCursor row advance matches visualRowsForLine - 1 across hard newlines" {
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 40,
            .cols = 3,
            .content_bottom = 37,
            .divider_top_row = 38,
            .input_row = 39,
            .divider_bottom_row = 40,
            .hint_row = 40,
        },
    };
    defer runtime.deinit(std.testing.allocator);

    const text = "abcdef\nghijkl";
    try std.testing.expectEqual(@as(u16, 4), visualRowsForLine(text, 3));

    runtime.cursor_row = 1;
    runtime.cursor_col = 1;
    _ = runtime.advanceCursor(text);
    try std.testing.expectEqual(@as(u16, 4), runtime.cursor_row);
}

test "writeTranscriptBytes mid-row continuation defers scroll after first paint" {
    const alloc = std.testing.allocator;
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 40,
            .cols = 80,
            .content_bottom = 35,
            .divider_top_row = 36,
            .input_row = 37,
            .divider_bottom_row = 38,
            .hint_row = 39,
        },
    };
    defer runtime.deinit(alloc);
    runtime.cursor_row = 35;
    runtime.cursor_col = 40;
    runtime.viewport_top_row = 35;
    runtime.has_painted_transcript = true;

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    var i: usize = 0;
    while (i < 1000) : (i += 1) try bytes.append(alloc, 'X');

    var metrics: Metrics = .{};
    try runtime.writeTranscriptBytes(alloc, &metrics, bytes.items, true);

    try std.testing.expectEqual(@as(u16, 35), runtime.viewport_top_row);
    try std.testing.expectEqual(@as(u16, 35), runtime.cursor_row);
}

test "appendReplaceableTranscriptLine does not emit scroll (buffer-only)" {
    const alloc = std.testing.allocator;
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());

    var runtime = TranscriptRuntime{
        .stdout_file = sink,
        .layout = .{
            .rows = 40,
            .cols = 10,
            .content_bottom = 35,
            .divider_top_row = 36,
            .input_row = 37,
            .divider_bottom_row = 38,
            .hint_row = 39,
        },
    };
    defer runtime.deinit(alloc);
    runtime.cursor_row = 35;
    runtime.cursor_col = 1;
    runtime.viewport_top_row = 35;

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    try bytes.appendSlice(alloc, "XXXXXXXXXX");
    var ln: u16 = 0;
    while (ln < 9) : (ln += 1) {
        try bytes.append(alloc, '\n');
        try bytes.appendSlice(alloc, "XXXXXXXXXX");
    }

    var metrics: Metrics = .{};
    _ = try runtime.appendReplaceableTranscriptLine(alloc, &metrics, bytes.items);

    try std.testing.expectEqual(@as(u16, 35), runtime.viewport_top_row);
    try std.testing.expectEqual(@as(u16, 40), runtime.cursor_row);
}

test "streamed chunk-split produces same viewport as single emission" {
    const alloc = std.testing.allocator;

    var sink1 = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink1.close(io_mod.getIo());
    var sink2 = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink2.close(io_mod.getIo());

    const layout: Layout = .{
        .rows = 40,
        .cols = 80,
        .content_bottom = 35,
        .divider_top_row = 36,
        .input_row = 37,
        .divider_bottom_row = 38,
        .hint_row = 39,
    };

    var single = TranscriptRuntime{ .stdout_file = sink1, .layout = layout };
    defer single.deinit(alloc);
    single.cursor_row = 35;
    single.cursor_col = 1;
    single.viewport_top_row = 35;

    var split = TranscriptRuntime{ .stdout_file = sink2, .layout = layout };
    defer split.deinit(alloc);
    split.cursor_row = 35;
    split.cursor_col = 1;
    split.viewport_top_row = 35;

    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(alloc);
    var i: usize = 0;
    while (i < 2000) : (i += 1) try full.append(alloc, 'X');

    var half: std.ArrayList(u8) = .empty;
    defer half.deinit(alloc);
    i = 0;
    while (i < 1000) : (i += 1) try half.append(alloc, 'X');

    var m1: Metrics = .{};
    var m2: Metrics = .{};
    try single.writeTranscriptBytes(alloc, &m1, full.items, true);
    try split.writeTranscriptBytes(alloc, &m2, half.items, true);
    try split.writeTranscriptBytes(alloc, &m2, half.items, true);

    try std.testing.expectEqual(single.viewport_top_row, split.viewport_top_row);
    try std.testing.expectEqual(single.cursor_row, split.cursor_row);
    try std.testing.expectEqual(single.cursor_col, split.cursor_col);
}

fn lifecycleTestRuntime(max_retained_bytes: ?usize) TranscriptRuntime {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 24, 20),
    };
    if (max_retained_bytes) |value| runtime.max_retained_transcript_bytes = value;
    return runtime;
}

fn lifecycleId(turn_id: u64, call_id: []const u8) types.ToolLifecycleId {
    return .{ .turn_id = turn_id, .call_id = call_id };
}

fn startLifecycle(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    turn_id: u64,
    call_id: []const u8,
) !u32 {
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = lifecycleId(turn_id, call_id),
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    return runtime.toolActivityRecord(lifecycleId(turn_id, call_id)).?.entry_id;
}

test "current compact projection groups tool rows without mutating entries" {
    const alloc = std.testing.allocator;
    defer user_message_card.setStyle(false, null);
    user_message_card.setStyle(false, null);
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);

    const read_id = lifecycleId(1, "read");
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = read_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = read_id,
        .outcome = .{ .kind = .completed, .summary = "Read file" },
    } });

    const edit_id = lifecycleId(1, "edit");
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = edit_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "edit_file",
        .activity_kind = .edit,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = edit_id,
        .outcome = .{ .kind = .failed, .summary = "Edit failed" },
    } });

    const entry_count = runtime.entries.items.len;
    var compact = try runtime.prepareTranscriptSource(alloc, null);
    defer compact.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        compact.bytes,
        "\x1b[38;5;255m●\x1b[0m \x1b[38;5;245m2 tool calls · 1 read · 1 edit · 1 failed\x1b[0m\n" ++
            "\x1b[38;5;245m├ Read file\x1b[0m\n" ++
            "\x1b[38;5;245m└ Edit failed\x1b[0m",
    ) != null);
    try std.testing.expectEqual(entry_count, runtime.entries.items.len);
}

test "current compact projection finalizes tool groups from turn finished fallbacks" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        call_id: []const u8,
        provisional: bool,
        turn_outcome: types.TurnPresentationOutcome,
        detail_outcome: types.ToolOutcomeKind,
        fallback_disposition: ?transcript_blocks.ToolFallbackDisposition,
        summary_text: []const u8,
    }{
        .{ .call_id = "unreported", .provisional = false, .turn_outcome = .completed, .detail_outcome = .completed, .fallback_disposition = .completion_unreported, .summary_text = "1 tool call · 1 read · 1 unreported" },
        .{ .call_id = "not-executed", .provisional = true, .turn_outcome = .completed, .detail_outcome = .completed, .fallback_disposition = .not_executed, .summary_text = "1 tool call · 1 read · 1 not executed" },
        .{ .call_id = "interrupted", .provisional = false, .turn_outcome = .interrupted, .detail_outcome = .cancelled, .fallback_disposition = null, .summary_text = "1 cancelled" },
        .{ .call_id = "failed", .provisional = false, .turn_outcome = .failed, .detail_outcome = .failed, .fallback_disposition = null, .summary_text = "Tool failed" },
    };

    for (cases) |case| {
        var runtime = lifecycleTestRuntime(null);
        defer runtime.deinit(alloc);

        const id = lifecycleId(1, case.call_id);
        if (case.provisional) {
            _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
                .id = id,
                .tool_name = "read_file",
                .activity_kind = .read,
            } });
        } else {
            _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
                .id = id,
                .reconciles_provisional_call_id = null,
                .tool_name = "read_file",
                .activity_kind = .read,
            } });
        }
        const entry_id = runtime.toolActivityRecord(id).?.entry_id;

        _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
            .turn_id = 1,
            .outcome = case.turn_outcome,
        } });

        var rendered = try runtime.prepareTranscriptSource(alloc, null);
        defer rendered.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, rendered.bytes, case.summary_text) != null);
        try std.testing.expect(std.mem.find(u8, rendered.bytes, "running") == null);
        try std.testing.expectEqual(
            case.detail_outcome,
            runtime.toolDetailForEntry(entry_id).?.outcome.?,
        );
        try std.testing.expectEqual(
            case.fallback_disposition,
            runtime.toolDetailForEntry(entry_id).?.fallback_disposition,
        );
    }
}

fn checkCompactParallelFallbackAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    const ids = [_]types.ToolLifecycleId{
        lifecycleId(1, "provisional-a"),
        lifecycleId(1, "provisional-b"),
    };
    var entry_ids: [ids.len]u32 = undefined;
    for (ids, 0..) |id, index| {
        _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
            .id = id,
            .tool_name = "read_file",
            .activity_kind = .read,
        } });
        entry_ids[index] = runtime.toolActivityRecord(id).?.entry_id;
    }

    var source_before = try runtime.prepareTranscriptSource(std.testing.allocator, null);
    defer source_before.deinit(std.testing.allocator);
    _ = runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = 1,
        .outcome = .completed,
    } }) catch |err| {
        var source_after = try runtime.prepareTranscriptSource(std.testing.allocator, null);
        defer source_after.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(source_before.bytes, source_after.bytes);
        for (ids) |id| {
            try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .provisional);
        }
        return err;
    };

    var rendered = try runtime.prepareTranscriptSource(alloc, null);
    defer rendered.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        rendered.bytes,
        "2 tool calls · 2 read · 2 not executed",
    ) != null);
    try std.testing.expect(std.mem.find(u8, rendered.bytes, "running") == null);
    for (entry_ids) |entry_id| {
        try std.testing.expectEqual(
            types.ToolOutcomeKind.completed,
            runtime.toolDetailForEntry(entry_id).?.outcome.?,
        );
        try std.testing.expectEqual(
            transcript_blocks.ToolFallbackDisposition.not_executed,
            runtime.toolDetailForEntry(entry_id).?.fallback_disposition.?,
        );
    }
}

fn checkCompactParallelFallbackAllocationFailures(alloc: Allocator) !void {
    return checkCompactParallelFallbackAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

test "compact parallel fallbacks are atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCompactParallelFallbackAllocationFailures,
        .{},
    );
}

fn prepareTurnFinishedAnchor(runtime: *TranscriptRuntime, alloc: Allocator) !void {
    try runtime.enableShadowVt(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "pre 0\npre 1\npre 2\npre 3\npre 4\npre 5\n",
        .subagent_status,
    );
    _ = try startLifecycle(runtime, alloc, 1, "unfinished");
    try installStableAnchorForTest(
        runtime,
        alloc,
        runtime.transcript.items,
        testSelection(0),
        0,
        4,
        1,
        1,
    );
}

test "preserving lifecycle policy keeps anchor for turn finished fallback rewrite" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try prepareTurnFinishedAnchor(&runtime, alloc);

    _ = try runtime.applyToolLifecyclePreservingNormalBufferAnchor(alloc, .{
        .turn_finished = .{
            .turn_id = 1,
            .outcome = .interrupted,
        },
    });

    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
}

test "preserving batch lifecycle rewrite keeps a capped canonical anchor" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    const long_tail = try makeLongPastePrompt(alloc, 40);
    defer alloc.free(long_tail);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        long_tail,
        .subagent_status,
    );
    const first_entry_id = try startLifecycle(&runtime, alloc, 1, "first");
    const second_entry_id = try startLifecycle(&runtime, alloc, 1, "second");

    var metrics: Metrics = .{};
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try std.testing.expect(committed_source.recorded_entries_authoritative);
    try std.testing.expect(committed_source.bytes.len > runtime.transcript.items.len);
    var committed_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer committed_prepared.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        committed_prepared.selection,
        preparedVisualOffsetForTest(&committed_prepared),
        committed_prepared.cursor.cursor_row,
        committed_prepared.cursor.cursor_col,
        1,
    );
    const committed_diagnostic = runtime.transcriptCommitDiagnostic();

    _ = try runtime.applyToolLifecyclePreservingNormalBufferAnchor(alloc, .{
        .turn_finished = .{
            .turn_id = 1,
            .outcome = .interrupted,
        },
    });

    try std.testing.expectEqualDeep(
        committed_diagnostic,
        runtime.transcriptCommitDiagnostic(),
    );
    try std.testing.expect(std.mem.find(
        u8,
        runtime.toolStatusEntryLabel(first_entry_id).?,
        "Tool cancelled",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        runtime.toolStatusEntryLabel(second_entry_id).?,
        "Tool cancelled",
    ) != null);
}

test "turn finished anchor preservation keeps a same-epoch retention rewrite" {
    const alloc = std.testing.allocator;

    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try prepareTurnFinishedAnchor(&runtime, alloc);
    const committed_history_visual_offset = try stableHistoryVisualOffsetForTest(&runtime);
    runtime.max_retained_transcript_bytes = 0;

    _ = try runtime.applyToolLifecyclePreservingNormalBufferAnchor(alloc, .{
        .turn_finished = .{ .turn_id = 1, .outcome = .interrupted },
    });

    try expectStableNormalBufferRecoveryForTest(
        &runtime,
        committed_history_visual_offset,
    );
}

test "turn finished anchor preservation falls back for strict mode or geometry blocker" {
    const alloc = std.testing.allocator;

    {
        var runtime = TranscriptRuntime{
            .layout = transcriptTestLayout(40, 8, 4),
            .owned_top_row = 1,
        };
        defer runtime.deinit(alloc);
        try prepareTurnFinishedAnchor(&runtime, alloc);
        runtime.max_transcript_bytes = 1;

        _ = try runtime.applyToolLifecycle(alloc, .{
            .turn_finished = .{ .turn_id = 1, .outcome = .interrupted },
        });

        try std.testing.expectEqual(
            transcript_runtime.TranscriptCommitDiagnosticState.invalid,
            runtime.transcriptCommitDiagnostic().state,
        );
    }

    {
        var runtime = TranscriptRuntime{
            .layout = transcriptTestLayout(40, 8, 4),
            .owned_top_row = 1,
        };
        defer runtime.deinit(alloc);
        try prepareTurnFinishedAnchor(&runtime, alloc);
        runtime.layout.cols = 39;

        _ = try runtime.applyToolLifecyclePreservingNormalBufferAnchor(alloc, .{
            .turn_finished = .{ .turn_id = 1, .outcome = .interrupted },
        });

        try std.testing.expectEqual(
            transcript_runtime.TranscriptCommitDiagnosticState.invalid,
            runtime.transcriptCommitDiagnostic().state,
        );
    }
}

test "untrimmed pinned status replacement preserves anchor through scroll transition" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "pre 0\npre 1\npre 2\npre 3\npre 4\npre 5\n",
        .subagent_status,
    );
    const entry_id = try transcript_store.appendPinnedToolStatusAtomic(
        &runtime,
        alloc,
        "pending\n",
    );
    try installStableAnchorForTest(
        &runtime,
        alloc,
        runtime.transcript.items,
        testSelection(0),
        0,
        4,
        1,
        1,
    );

    try std.testing.expect(try transcript_store.replacePinnedToolStatusAtomic(
        &runtime,
        alloc,
        entry_id,
        "running\n",
    ));
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);
    try setPreparedVisualOffsetForTest(&prepared, 2);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(!facts.source_compatible);
    try std.testing.expect(facts.recovery_rebase);
    try std.testing.expectEqual(@as(u16, 2), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), facts.semantic_progress_rows);
    try std.testing.expectEqual(@as(u16, 2), facts.planned_rows);

    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    try std.testing.expectEqual(@as(u16, 2), scroll_plan.terminal_scroll_rows);
    var plan = testPaintPlan(&runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(transition.document_append.isEmpty());
    runtime.consumeTranscriptTransition(alloc, &transition, .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = true,
        .terminal_scroll_rows_committed = scroll_plan.terminal_scroll_rows,
        .document_append_committed = false,
        .committed_cursor_row = transition.cursor_row,
        .committed_cursor_col = transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    try std.testing.expect(runtime.transcript_cache_origin_untrimmed);

    var next_source = try runtime.prepareTranscriptSource(alloc, null);
    defer next_source.deinit(alloc);
    try std.testing.expect(
        runtime.stableTranscriptProjectionForFlow(next_source.bytes) != null,
    );
}

test "command terminal replacement preserves committed scrollback anchor" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "pre 0\npre 1\npre 2\npre 3\npre 4\npre 5\n",
        .subagent_status,
    );
    const id = lifecycleId(1, "cancelled-command");
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"sleep 30\"}",
    } });
    try installStableAnchorForTest(
        &runtime,
        alloc,
        runtime.transcript.items,
        testSelection(0),
        0,
        4,
        1,
        1,
    );

    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .cancelled, .summary = "Command cancelled" },
        .result_memory = .{ .command_process_presentation = .{ .exit_code = 130 } },
    } });

    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
    const entry_id = runtime.toolActivityRecord(id).?.entry_id;
    try std.testing.expect(std.mem.find(
        u8,
        runtime.toolStatusEntryLabel(entry_id).?,
        "Command cancelled",
    ) != null);
    try std.testing.expect(runtime.toolDetailForEntry(entry_id).?.command_output_entry_id != null);
}

test "pinned status admission preserves an authoritative committed anchor" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 8, 4),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    const long_tail = try makeLongPastePrompt(alloc, 40);
    defer alloc.free(long_tail);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        long_tail,
        .subagent_status,
    );
    const first_status_id = try transcript_store.appendPinnedToolStatusAtomic(
        &runtime,
        alloc,
        "pending\n",
    );
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try std.testing.expect(committed_source.recorded_entries_authoritative);
    try std.testing.expect(committed_source.bytes.len > runtime.transcript.items.len);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        4,
        1,
        1,
    );
    const committed_before = runtime.transcriptCommitDiagnostic();

    try std.testing.expect(try transcript_store.replacePinnedToolStatusAtomic(
        &runtime,
        alloc,
        first_status_id,
        "running\n",
    ));
    try std.testing.expectEqualDeep(
        committed_before,
        runtime.transcriptCommitDiagnostic(),
    );

    _ = try transcript_store.appendPinnedToolStatusAtomic(
        &runtime,
        alloc,
        "pending\n",
    );

    try std.testing.expectEqualDeep(
        committed_before,
        runtime.transcriptCommitDiagnostic(),
    );
    var appended_source = try runtime.prepareTranscriptSource(alloc, null);
    defer appended_source.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, appended_source.bytes, "LONG_PASTE_LAST_MARKER"),
    );
    try std.testing.expect(std.mem.find(u8, runtime.toolStatusEntryLabel(first_status_id).?, "running") != null);
    try std.testing.expectEqual(@as(usize, 2), runtime.lifecyclePinCount());
}

test "pinned status admission preserves an anchor when retention prunes its source" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "anchored transcript\n",
        .subagent_status,
    );
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        4,
        1,
        1,
    );
    const committed_history_visual_offset = try stableHistoryVisualOffsetForTest(&runtime);
    runtime.max_retained_transcript_bytes = "pending\n".len;

    _ = try transcript_store.appendPinnedToolStatusAtomic(
        &runtime,
        alloc,
        "pending\n",
    );

    try expectStableNormalBufferRecoveryForTest(
        &runtime,
        committed_history_visual_offset,
    );
    var retained_source = try runtime.prepareTranscriptSource(alloc, null);
    defer retained_source.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, retained_source.bytes, "anchored transcript"),
    );
    try std.testing.expectEqual(@as(usize, 1), runtime.lifecyclePinCount());
}

test "pinned status replacement preserves authoritative cache changes and rebases retention or geometry" {
    const alloc = std.testing.allocator;

    {
        var runtime = TranscriptRuntime{
            .layout = transcriptTestLayout(40, 8, 4),
            .owned_top_row = 1,
        };
        defer runtime.deinit(alloc);
        try runtime.enableShadowVt(alloc);
        _ = try runtime.appendRawTranscriptEntryClassified(
            alloc,
            "ordinary retained entry\n",
            .subagent_status,
        );
        const entry_id = try transcript_store.appendPinnedToolStatusAtomic(
            &runtime,
            alloc,
            "pending\n",
        );
        runtime.max_retained_transcript_bytes = transcript_store.retainedStructuredBytes(&runtime);
        try installStableAnchorForTest(
            &runtime,
            alloc,
            runtime.transcript.items,
            testSelection(0),
            0,
            4,
            1,
            1,
        );
        try std.testing.expect(try transcript_store.replacePinnedToolStatusAtomic(
            &runtime,
            alloc,
            entry_id,
            "replacement that requires structured retention\n",
        ));
        try std.testing.expectEqual(
            transcript_runtime.TranscriptCommitDiagnosticState.invalid,
            runtime.transcriptCommitDiagnostic().state,
        );
    }

    {
        var runtime = TranscriptRuntime{
            .layout = transcriptTestLayout(40, 8, 4),
            .owned_top_row = 1,
        };
        defer runtime.deinit(alloc);
        try runtime.enableShadowVt(alloc);
        const entry_id = try transcript_store.appendPinnedToolStatusAtomic(
            &runtime,
            alloc,
            "old\n",
        );
        runtime.max_transcript_bytes = runtime.transcript.items.len;
        try installStableAnchorForTest(
            &runtime,
            alloc,
            runtime.transcript.items,
            testSelection(0),
            0,
            4,
            1,
            1,
        );
        const committed_before = runtime.transcriptCommitDiagnostic();

        try std.testing.expect(try transcript_store.replacePinnedToolStatusAtomic(
            &runtime,
            alloc,
            entry_id,
            "replacement that crosses the visible cache cap\n",
        ));
        try std.testing.expectEqualDeep(
            committed_before,
            runtime.transcriptCommitDiagnostic(),
        );
    }

    {
        var runtime = TranscriptRuntime{
            .layout = transcriptTestLayout(40, 8, 4),
            .owned_top_row = 1,
            .max_transcript_bytes = 5,
        };
        defer runtime.deinit(alloc);
        try runtime.enableShadowVt(alloc);
        const entry_id = try transcript_store.appendPinnedToolStatusAtomic(
            &runtime,
            alloc,
            "old\npinned\nstatus",
        );
        try std.testing.expect(runtime.transcript.items.len <= runtime.max_transcript_bytes);
        var committed_source = try runtime.prepareTranscriptSource(alloc, null);
        defer committed_source.deinit(alloc);
        try std.testing.expect(committed_source.recorded_entries_authoritative);
        try std.testing.expect(committed_source.bytes.len > runtime.transcript.items.len);
        try installStableAnchorForTest(
            &runtime,
            alloc,
            committed_source.bytes,
            testSelection(0),
            0,
            4,
            1,
            1,
        );
        const committed_before = runtime.transcriptCommitDiagnostic();

        try std.testing.expect(try transcript_store.replacePinnedToolStatusAtomic(
            &runtime,
            alloc,
            entry_id,
            "ok",
        ));
        try std.testing.expectEqualDeep(
            committed_before,
            runtime.transcriptCommitDiagnostic(),
        );
    }

    {
        var runtime = TranscriptRuntime{
            .layout = transcriptTestLayout(40, 8, 4),
            .owned_top_row = 1,
        };
        defer runtime.deinit(alloc);
        try runtime.enableShadowVt(alloc);
        const entry_id = try transcript_store.appendPinnedToolStatusAtomic(
            &runtime,
            alloc,
            "pending\n",
        );
        try installStableAnchorForTest(
            &runtime,
            alloc,
            runtime.transcript.items,
            testSelection(0),
            0,
            4,
            1,
            1,
        );

        runtime.layout.cols = 20;
        try std.testing.expect(try transcript_store.replacePinnedToolStatusAtomic(
            &runtime,
            alloc,
            entry_id,
            "running\n",
        ));
        try std.testing.expectEqual(
            transcript_runtime.TranscriptCommitDiagnosticState.invalid,
            runtime.transcriptCommitDiagnostic().state,
        );
    }
}

test "visual epoch retains full history across repeated clears and compact rebuilds" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "old welcome\n", .welcome);
    const old_id = try runtime.appendRawTranscriptEntryClassified(alloc, "retained answer\n", .subagent_status);
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "history",
        .tone = .information,
        .body = "retained notice",
    });
    const retained_bytes = runtime.entries.items[1].raw_bytes.bytes.ptr;

    for (0..3) |_| {
        try runtime.resetVisualEpoch(alloc, "current welcome\n");
        try std.testing.expectEqual(@as(usize, 3), runtime.entries.items.len);
        try std.testing.expectEqual(old_id, runtime.entries.items[1].id());
        try std.testing.expectEqual(retained_bytes, runtime.entries.items[1].raw_bytes.bytes.ptr);
        try std.testing.expect(runtime.entries.items[1].raw_bytes.inline_hidden);
        try std.testing.expect(runtime.entries.items[2].semantic_notice.inline_hidden);
        try std.testing.expectEqualStrings("current welcome\n", runtime.transcript.items);

        var compact = try runtime.prepareTranscriptSource(alloc, null);
        defer compact.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, compact.bytes, "retained") == null);

        var projection = try runtime.buildFullTranscriptProjection(alloc, null);
        defer projection.deinit(alloc);
        const full = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
            alloc,
            &projection,
            null,
            runtime.layout.cols,
            64,
            0,
            null,
        );
        defer alloc.free(full);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, full, "retained answer"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, full, "retained notice"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, full, "current welcome"));
        try std.testing.expect(std.mem.find(u8, full, "old welcome") == null);
    }

    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "new answer\n", .subagent_status);
    var compact = try runtime.prepareTranscriptSource(alloc, null);
    defer compact.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "new answer") != null);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "retained") == null);

    runtime.clearTranscript(alloc);
    try std.testing.expectEqual(@as(usize, 0), runtime.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript.items.len);
}

test "visual epoch preserves monotonic entry IDs across repeated clears" {
    const alloc = std.testing.allocator;
    for ([_]bool{ true, false }) |has_original_welcome| {
        var runtime = lifecycleTestRuntime(null);
        defer runtime.deinit(alloc);
        if (has_original_welcome) {
            _ = try runtime.appendRawTranscriptEntryClassified(alloc, "original welcome\n", .welcome);
            runtime.entries.items[0].raw_bytes.created_at_ms = 1234;
        }
        var ordinary_ids: [300]u32 = undefined;
        for (&ordinary_ids) |*id| {
            id.* = try runtime.appendRawTranscriptEntryClassified(alloc, "retained answer\n", .subagent_status);
        }
        const welcome_index: usize = if (has_original_welcome) 0 else ordinary_ids.len;
        const welcome_id = if (has_original_welcome) runtime.entries.items[0].id() else runtime.next_entry_id;
        var welcome_created_at: ?i64 = if (has_original_welcome) 1234 else null;
        const expected_next_id = runtime.next_entry_id + @as(u32, if (has_original_welcome) 0 else 1);

        for (0..3) |_| {
            try runtime.resetVisualEpoch(alloc, "current welcome\n");
            try std.testing.expectEqual(@as(usize, ordinary_ids.len + 1), runtime.entries.items.len);
            try std.testing.expectEqual(expected_next_id, runtime.next_entry_id);
            const welcome_entry = runtime.entries.items[welcome_index].raw_bytes;
            try std.testing.expectEqual(welcome_id, welcome_entry.id);
            try std.testing.expectEqualStrings("current welcome\n", welcome_entry.bytes);
            if (welcome_created_at) |created_at| {
                try std.testing.expectEqual(created_at, welcome_entry.created_at_ms);
            } else {
                welcome_created_at = welcome_entry.created_at_ms;
            }
            var welcome_count: usize = 0;
            var ordinary_index: usize = 0;
            for (runtime.entries.items, 0..) |entry, index| {
                if (index > 0) try std.testing.expect(runtime.entries.items[index - 1].id() < entry.id());
                if (entry == .raw_bytes and entry.raw_bytes.class == .welcome) {
                    welcome_count += 1;
                } else {
                    try std.testing.expectEqual(ordinary_ids[ordinary_index], entry.id());
                    try std.testing.expect(entry.raw_bytes.inline_hidden);
                    ordinary_index += 1;
                }
            }
            try std.testing.expectEqual(@as(usize, 1), welcome_count);
            try std.testing.expectEqual(ordinary_ids.len, ordinary_index);
            try std.testing.expectEqualStrings("current welcome\n", runtime.transcript.items);
        }
    }
}

fn checkVisualEpochAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "original welcome\n", .welcome);
    const old_id = try runtime.appendRawTranscriptEntryClassified(alloc, "borrowed answer\n", .subagent_status);
    const pinned_id = try transcript_store.appendPinnedToolStatusAtomic(&runtime, alloc, "running\n");
    const old_entries = runtime.entries.items.ptr;
    const old_payload = runtime.entries.items[1].raw_bytes.bytes.ptr;
    const old_next_id = runtime.next_entry_id;
    const before = try std.testing.allocator.dupe(u8, runtime.transcript.items);
    defer std.testing.allocator.free(before);

    runtime.resetVisualEpoch(alloc, "replacement welcome\n") catch |err| {
        try std.testing.expectEqual(old_entries, runtime.entries.items.ptr);
        try std.testing.expectEqual(@as(usize, 3), runtime.entries.items.len);
        try std.testing.expectEqual(old_next_id, runtime.next_entry_id);
        try std.testing.expectEqualStrings(before, runtime.transcript.items);
        try std.testing.expectEqual(old_payload, runtime.entries.items[1].raw_bytes.bytes.ptr);
        try std.testing.expect(!runtime.entries.items[1].raw_bytes.inline_hidden);
        try std.testing.expectEqualStrings("borrowed answer\n", runtime.entries.items[1].raw_bytes.bytes);
        try std.testing.expect(runtime.isLifecyclePinned(pinned_id));
        return err;
    };
    try std.testing.expectEqual(old_id, runtime.entries.items[1].id());
    try std.testing.expectEqual(old_payload, runtime.entries.items[1].raw_bytes.bytes.ptr);
    try std.testing.expect(runtime.entries.items[1].raw_bytes.inline_hidden);
    try std.testing.expect(runtime.isLifecyclePinned(pinned_id));
}

fn checkVisualEpochAllocationFailures(alloc: Allocator) !void {
    return checkVisualEpochAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

test "visual epoch starts a visible assistant tail without resurrecting cleared text" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    var metrics = Metrics{};
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "welcome\n", .welcome);
    const before_id = try runtime.streamAssistantChunk(alloc, &metrics, "before clear");
    try runtime.resetVisualEpoch(alloc, "welcome\n");
    const after_id = try runtime.streamAssistantChunk(alloc, &metrics, "after clear");
    try std.testing.expect(before_id != after_id);
    try std.testing.expectEqualStrings("before clear", runtime.lookupAssistantSegments(before_id).?.text.items);
    var compact = try runtime.prepareTranscriptSource(alloc, null);
    defer compact.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "before clear") == null);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "after clear") != null);
}

test "visual epoch reset is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkVisualEpochAllocationFailures,
        .{},
    );
}

test "visual epoch hides ordinary entries and preserves live tool identities through settlement" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "original welcome\n", .welcome);
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "old transcript\n", .subagent_status);
    const entry_id = try startLifecycle(&runtime, alloc, 7, "call-7");

    try runtime.resetVisualEpoch(alloc, "welcome\n");

    try std.testing.expect(std.mem.startsWith(u8, runtime.transcript.items, "welcome\n"));
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "old transcript") == null);
    try std.testing.expectEqual(entry_id, runtime.toolActivityRecord(lifecycleId(7, "call-7")).?.entry_id);
    try std.testing.expect(runtime.isLifecyclePinned(entry_id));

    _ = try runtime.applyToolLifecycle(alloc, .{ .progress = .{
        .id = lifecycleId(7, "call-7"),
        .text = "still running",
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = lifecycleId(7, "call-7"),
        .outcome = .{ .kind = .completed, .summary = "finished" },
    } });
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "finished") != null);
    try std.testing.expectEqual(@as(usize, 3), runtime.entries.items.len);
    try std.testing.expectEqual(entry_id, runtime.entries.items[2].id());
    try std.testing.expect(!runtime.entries.items[2].raw_bytes.inline_hidden);

    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = 7,
        .outcome = .completed,
    } });
    try runtime.finishLifecycleBatch(alloc);
    try std.testing.expect(!runtime.isLifecyclePinned(entry_id));
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "finished") != null);
    try runtime.resetVisualEpoch(alloc, "welcome again\n");
    try std.testing.expectEqual(@as(usize, 3), runtime.entries.items.len);
    try std.testing.expectEqual(entry_id, runtime.entries.items[2].id());
    try std.testing.expect(runtime.entries.items[2].raw_bytes.inline_hidden);
    try std.testing.expectEqualStrings("welcome again\n", runtime.transcript.items);

    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const full = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        64,
        0,
        null,
    );
    defer alloc.free(full);
    try std.testing.expect(std.mem.find(u8, full, "old transcript") != null);
    try std.testing.expect(std.mem.find(u8, full, "finished") != null);
}

test "visual epoch retains command output blocks and detail associations" {
    const alloc = std.testing.allocator;
    var sink = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{ .mode = .write_only });
    defer sink.close(io_mod.getIo());
    var runtime = commandOutputTestRuntime(sink);
    defer runtime.deinit(alloc);
    var metrics = Metrics{};
    const styles = commandOutputTestStyles();
    const id = lifecycleId(1, "retained-command");
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "shell",
        .activity_kind = .command,
        .arguments_json = "{\"request\":{\"action\":\"run\",\"command\":\"true\"}}",
    } });
    const entry_id = runtime.toolActivityRecord(id).?.entry_id;
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, id, .stdout, "retained command result\n", true);
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, id, true);
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Retained command complete" },
        .result = "retained command result\n",
        .result_memory = .{ .command_process_presentation = .{ .exit_code = 0 } },
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = 1,
        .outcome = .completed,
    } });
    try runtime.finishLifecycleBatch(alloc);
    const output_id = runtime.toolDetailForEntry(entry_id).?.command_output_entry_id.?;
    const block_count = runtime.command_output_blocks.items.len;
    try std.testing.expect(block_count > 0);
    const blocks_ptr = runtime.command_output_blocks.items.ptr;

    for (0..2) |_| {
        try runtime.resetVisualEpoch(alloc, "welcome\n");
        try std.testing.expectEqual(block_count, runtime.command_output_blocks.items.len);
        try std.testing.expectEqual(blocks_ptr, runtime.command_output_blocks.items.ptr);
        try std.testing.expectEqual(output_id, runtime.toolDetailForEntry(entry_id).?.command_output_entry_id.?);
        try std.testing.expect(transcriptContainsEntry(&runtime, output_id));
        try std.testing.expectEqualStrings("welcome\n", runtime.transcript.items);
        var projection = try runtime.buildFullTranscriptProjection(alloc, null);
        defer projection.deinit(alloc);
        const full = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
            alloc,
            &projection,
            null,
            runtime.layout.cols,
            64,
            0,
            null,
        );
        defer alloc.free(full);
        try std.testing.expect(std.mem.find(u8, full, "Retained command complete") != null);
        try std.testing.expect(std.mem.find(u8, full, "retained command result") != null);
    }
    runtime.clearTranscript(alloc);
    try std.testing.expectEqual(@as(usize, 0), runtime.command_output_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.tool_details.items.len);
}

test "transcript lifecycle identity updates are idempotent and atomic" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);

    for ([_]?[]const u8{ null, "read_file", "read_file" }) |tool_name| {
        _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
            .id = lifecycleId(1, "call"),
            .presentation_group_id = .{ .turn_id = 1, .anchor_step_id = 11 },
            .tool_name = tool_name,
            .activity_kind = .read,
        } });
    }
    const provisional_id = lifecycleId(1, "call");
    const entry_id = runtime.toolActivityRecord(provisional_id).?.entry_id;
    try std.testing.expectEqualStrings(
        "read_file",
        runtime.toolActivityRecord(provisional_id).?.tool_name.?,
    );
    // Force record-map growth so stale pointers fail deterministically.
    inline for ([_][]const u8{ "alias", "target", "fill-1", "fill-2", "fill-3" }) |call_id| {
        _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
            .id = lifecycleId(1, call_id),
            .tool_name = "read_file",
            .activity_kind = .read,
        } });
    }
    const authoritative_id = lifecycleId(1, "authoritative-" ++ ("x" ** 800));
    const record_capacity_before = runtime.lifecycle_state.records.capacity();
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = authoritative_id,
        .presentation_group_id = .{ .turn_id = 1, .anchor_step_id = 12 },
        .reconciles_provisional_call_id = "call",
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    try std.testing.expect(runtime.lifecycle_state.records.capacity() > record_capacity_before);
    try std.testing.expect(runtime.toolActivityRecord(provisional_id) == null);
    try std.testing.expectEqual(
        entry_id,
        runtime.toolActivityRecord(authoritative_id).?.entry_id,
    );
    try std.testing.expectEqual(
        types.ToolPresentationGroupId{ .turn_id = 1, .anchor_step_id = 11 },
        runtime.toolDetailForEntry(entry_id).?.presentation_group_id.?,
    );
    const alias_before = runtime.toolActivityRecord(lifecycleId(1, "alias")).?.entry_id;
    const target_before = runtime.toolActivityRecord(lifecycleId(1, "target")).?.entry_id;
    try std.testing.expectError(
        error.LifecycleReconciliationCollision,
        runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
            .id = lifecycleId(1, "target"),
            .reconciles_provisional_call_id = "alias",
            .tool_name = "glob_files",
            .activity_kind = .list,
        } }),
    );
    try std.testing.expectEqual(alias_before, runtime.toolActivityRecord(lifecycleId(1, "alias")).?.entry_id);
    try std.testing.expectEqual(target_before, runtime.toolActivityRecord(lifecycleId(1, "target")).?.entry_id);
    const records_before = runtime.toolActivityRecordCount();
    try std.testing.expectError(
        error.UnknownToolLifecycleIdentity,
        runtime.applyToolLifecycle(alloc, .{ .progress = .{
            .id = lifecycleId(1, "missing"),
            .text = "progress",
        } }),
    );
    try std.testing.expectError(
        error.UnknownToolLifecycleIdentity,
        runtime.applyToolLifecycle(alloc, .{ .terminal = .{
            .id = lifecycleId(1, "missing"),
            .outcome = .{ .kind = .failed, .summary = "failed" },
        } }),
    );
    try std.testing.expectEqual(records_before, runtime.toolActivityRecordCount());
    runtime.clearTranscript(alloc);
    try std.testing.expectEqual(@as(usize, 0), runtime.toolActivityRecordCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.lifecyclePinCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.entries.items.len);
}

test "authoritative lifecycle can place a provisional row after the latest transcript entry" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);

    const id = lifecycleId(1, "command");
    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = id,
        .tool_name = "run_command",
        .activity_kind = .command,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .progress = .{
        .id = id,
        .text = "Preparing command",
    } });
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "permissions",
        .tone = .success,
        .body = "Auto agent approved this request: Running command.",
        .visibility = .full_only,
    });

    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"printf approved\"}",
        .place_after_current_transcript = true,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .progress = .{
        .id = id,
        .text = "Running printf approved",
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Ran printf approved" },
    } });

    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "Auto agent approved") == null);
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "Ran printf approved") != null);

    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const full = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        64,
        0,
        null,
    );
    defer alloc.free(full);
    const notice_index = std.mem.find(u8, full, "Auto agent approved").?;
    const completed_index = std.mem.find(u8, full, "Ran printf approved").?;
    try std.testing.expect(notice_index < completed_index);
}

test "coalesced approval lifecycle reposition preserves an authoritative committed anchor" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    const long_tail = try makeLongPastePrompt(alloc, 40);
    defer alloc.free(long_tail);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        long_tail,
        .subagent_status,
    );

    var metrics = Metrics{};
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try std.testing.expect(committed_source.recorded_entries_authoritative);
    try std.testing.expect(committed_source.bytes.len > runtime.transcript.items.len);
    var committed_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer committed_prepared.deinit(alloc);
    const committed_offset = preparedVisualOffsetForTest(&committed_prepared);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        committed_prepared.selection,
        committed_offset,
        committed_prepared.cursor.cursor_row,
        committed_prepared.cursor.cursor_col,
        1,
    );
    const committed_diagnostic = runtime.transcriptCommitDiagnostic();

    const id = lifecycleId(91, "coalesced-command");
    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = id,
        .tool_name = "run_command",
        .activity_kind = .command,
    } });
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "permissions",
        .tone = .success,
        .body = "Auto agent approved this request: Running command.",
        .visibility = .full_only,
    });
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"seq 1 1\"}",
        .place_after_current_transcript = true,
    } });

    try std.testing.expectEqualDeep(
        committed_diagnostic,
        runtime.transcriptCommitDiagnostic(),
    );
    var repositioned_source = try runtime.prepareTranscriptSource(alloc, null);
    defer repositioned_source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, repositioned_source.bytes, "Auto agent approved") == null);
    try std.testing.expect(std.mem.find(
        u8,
        repositioned_source.bytes,
        "run_command",
    ) != null);
    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const full = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        64,
        0,
        null,
    );
    defer alloc.free(full);
    const notice_index = std.mem.find(u8, full, "Auto agent approved") orelse
        return error.TestExpectedEqual;
    const full_status_index = std.mem.find(u8, full, "run_command") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(notice_index < full_status_index);

    var repositioned_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer repositioned_prepared.deinit(alloc);
    const facts = runtime.planTranscriptScroll(&repositioned_prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expect(facts.semantic_rows > 0);
    try std.testing.expectEqual(committed_offset, facts.source_visual_offset);
}

test "coalesced approval lifecycle reposition preserves its anchor when retention prunes its source" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    const anchored = "anchored transcript\n";
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        anchored,
        .subagent_status,
    );
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        4,
        1,
        1,
    );
    const committed_history_visual_offset = try stableHistoryVisualOffsetForTest(&runtime);

    const id = lifecycleId(92, "retained-command");
    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = id,
        .tool_name = "run_command",
        .activity_kind = .command,
    } });
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "permissions",
        .tone = .success,
        .body = "Auto agent approved this request: Running command.",
        .visibility = .full_only,
    });
    runtime.max_retained_transcript_bytes =
        transcript_store.retainedStructuredBytes(&runtime) - anchored.len;

    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"seq 1 1\"}",
        .place_after_current_transcript = true,
    } });

    try expectStableNormalBufferRecoveryForTest(
        &runtime,
        committed_history_visual_offset,
    );
    var retained_source = try runtime.prepareTranscriptSource(alloc, null);
    defer retained_source.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, retained_source.bytes, "anchored transcript"),
    );
    try std.testing.expect(std.mem.find(u8, retained_source.bytes, "Auto agent approved") == null);
    try std.testing.expect(std.mem.find(
        u8,
        retained_source.bytes,
        "run_command",
    ) != null);
    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const full = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        64,
        0,
        null,
    );
    defer alloc.free(full);
    const notice_index = std.mem.find(u8, full, "Auto agent approved") orelse
        return error.TestExpectedEqual;
    const status_index = std.mem.find(u8, full, "run_command") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(notice_index < status_index);
}

test "transcript lifecycle preserves caller resolved activity metadata" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);

    const id = lifecycleId(1, "custom-browser");
    const started_kind = (try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "custom_probe_tool",
        .activity_kind = .open,
    } })) orelse return error.TestExpectedEqual;

    try std.testing.expectEqual(types.ToolActivityKind.open, started_kind);
    try std.testing.expectEqual(types.ToolActivityKind.open, runtime.toolActivityRecord(id).?.activity_kind);
    try std.testing.expectEqual(types.ToolActivityKind.open, runtime.focusedToolActivityKind().?);
    switch (runtime.activityProjection()) {
        .tool_slot => |slot| try std.testing.expectEqual(types.ToolActivityKind.open, slot.kind),
        else => return error.TestExpectedEqual,
    }
}

test "transcript lifecycle terminal and finalization transitions stay batch safe" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);

    const cases = [_]struct {
        call_id: []const u8,
        kind: types.ToolOutcomeKind,
        summary: []const u8,
        marker_style: []const u8,
        marker: []const u8,
    }{
        .{ .call_id = "completed", .kind = .completed, .summary = "completed", .marker_style = ui_render.system_notice_text_style, .marker = "●" },
        .{ .call_id = "denied", .kind = .denied, .summary = "denied", .marker_style = ui_render.red_style, .marker = "⊘" },
        .{ .call_id = "cancelled", .kind = .cancelled, .summary = "cancelled", .marker_style = ui_render.warning_style, .marker = "■" },
        .{ .call_id = "failed", .kind = .failed, .summary = "failed", .marker_style = ui_render.red_style, .marker = "●" },
    };
    for (cases) |case| {
        const id = lifecycleId(1, case.call_id);
        const entry_id = try startLifecycle(&runtime, alloc, 1, case.call_id);
        _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
            .id = id,
            .outcome = .{ .kind = case.kind, .summary = case.summary },
        } });
        var expected: [128]u8 = undefined;
        const expected_line = if (case.kind == .cancelled)
            try std.fmt.bufPrint(
                &expected,
                "{s}{s}{s} {s}{s}{s} · What can fx do differently?\n",
                .{
                    case.marker_style,
                    case.marker,
                    ui_render.reset_style,
                    ui_render.hint_style,
                    case.summary,
                    ui_render.reset_style,
                },
            )
        else
            try std.fmt.bufPrint(
                &expected,
                "{s}{s}{s} {s}\n",
                .{ case.marker_style, case.marker, ui_render.reset_style, case.summary },
            );
        try expectRawEntryBytes(&runtime, entry_id, expected_line);
    }
    try std.testing.expect(runtime.activityProjection() == .none);

    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = lifecycleId(2, "old"),
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    const old_entry_id = runtime.toolActivityRecord(lifecycleId(2, "old")).?.entry_id;
    _ = try startLifecycle(&runtime, alloc, 3, "new");

    for ([_]types.ToolLifecycleEvent{
        .{ .turn_finished = .{ .turn_id = 2, .outcome = .completed } },
        .{ .turn_finished = .{ .turn_id = 2, .outcome = .interrupted } },
        .{ .turn_finished = .{ .turn_id = 1, .outcome = .failed } },
    }) |event| _ = try runtime.applyToolLifecycle(alloc, event);
    try expectRawEntryBytes(&runtime, old_entry_id, "● Tool was not executed\n");

    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = lifecycleId(2, "old"),
        .outcome = .{ .kind = .completed, .summary = "● Late completion" },
    } });
    var late_completion_expected: [128]u8 = undefined;
    try expectRawEntryBytes(&runtime, old_entry_id, try std.fmt.bufPrint(
        &late_completion_expected,
        "{s}●{s} Late completion\n",
        .{ ui_render.system_notice_text_style, ui_render.reset_style },
    ));
    try std.testing.expectEqual(
        null,
        runtime.toolDetailForEntry(old_entry_id).?.fallback_disposition,
    );
    try std.testing.expect(runtime.isLifecyclePinned(old_entry_id));

    try runtime.finishLifecycleBatch(alloc);
    try std.testing.expectEqual(@as(u64, 2), runtime.finalizedToolTurnWatermark());
    try std.testing.expect(runtime.toolActivityRecord(lifecycleId(2, "old")) == null);
    try std.testing.expect(runtime.toolActivityRecord(lifecycleId(3, "new")) != null);
    try std.testing.expect(!runtime.isLifecyclePinned(old_entry_id));

    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = lifecycleId(2, "late-start"),
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    try std.testing.expect(runtime.toolActivityRecord(lifecycleId(2, "late-start")) == null);
}

test "completed tool status projection keeps lifecycle styling without activity state" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    var metrics: Metrics = .{};

    try runtime.writeCompletedToolStatus(
        alloc,
        &metrics,
        .completed,
        "● Ran pwd\x1b[0m \x1b[38;5;245mpwd\x1b[0m",
        true,
    );

    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expectEqual(RawEntryClass.tool_status, runtime.entries.items[0].raw_bytes.class);
    try expectRawEntryBytes(
        &runtime,
        runtime.entries.items[0].raw_bytes.id,
        "\x1b[38;5;250m●\x1b[0m Ran pwd\x1b[0m \x1b[38;5;245mpwd\x1b[0m\n",
    );
    try std.testing.expect(runtime.activityProjection() == .none);
    try std.testing.expectEqual(@as(usize, 0), runtime.toolActivityRecordCount());
}

test "transcript lifecycle terminal markers preserve ANSI summaries and normalize markerless failures" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);

    const styled_entry_id = try startLifecycle(&runtime, alloc, 1, "styled");
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = lifecycleId(1, "styled"),
        .outcome = .{
            .kind = .completed,
            .summary = "● Ran command\x1b[0m",
        },
    } });
    var styled_expected: [128]u8 = undefined;
    try expectRawEntryBytes(&runtime, styled_entry_id, try std.fmt.bufPrint(
        &styled_expected,
        "{s}●{s} Ran command\x1b[0m\n",
        .{ ui_render.system_notice_text_style, ui_render.reset_style },
    ));

    const styled_cancelled_entry_id = try startLifecycle(&runtime, alloc, 1, "styled-cancelled");
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = lifecycleId(1, "styled-cancelled"),
        .outcome = .{
            .kind = .cancelled,
            .summary = "● Cancelled\x1b[0m \x1b[38;5;245msleep 30\x1b[0m",
        },
    } });
    var styled_cancelled_expected: [256]u8 = undefined;
    try expectRawEntryBytes(&runtime, styled_cancelled_entry_id, try std.fmt.bufPrint(
        &styled_cancelled_expected,
        "{s}■{s}{s} Cancelled\x1b[0m \x1b[38;5;245msleep 30\x1b[0m{s}" ++
            " · What can fx do differently?\n",
        .{
            ui_render.warning_style,
            ui_render.reset_style,
            ui_render.hint_style,
            ui_render.reset_style,
        },
    ));

    const malformed_entry_id = try startLifecycle(&runtime, alloc, 1, "malformed");
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = lifecycleId(1, "malformed"),
        .outcome = .{
            .kind = .failed,
            .summary = "write_file failed: invalid JSON arguments",
        },
    } });
    var malformed_expected: [128]u8 = undefined;
    try expectRawEntryBytes(&runtime, malformed_entry_id, try std.fmt.bufPrint(
        &malformed_expected,
        "{s}●{s} write_file failed: invalid JSON arguments\n",
        .{ ui_render.red_style, ui_render.reset_style },
    ));

    const cancelled_entry_id = try startLifecycle(&runtime, alloc, 2, "cancelled");
    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = 2,
        .outcome = .interrupted,
    } });
    var cancelled_expected: [128]u8 = undefined;
    try expectRawEntryBytes(&runtime, cancelled_entry_id, try std.fmt.bufPrint(
        &cancelled_expected,
        "{s}■{s} {s}Tool cancelled{s} · What can fx do differently?\n",
        .{
            ui_render.warning_style,
            ui_render.reset_style,
            ui_render.hint_style,
            ui_render.reset_style,
        },
    ));

    const failed_entry_id = try startLifecycle(&runtime, alloc, 3, "failed");
    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = 3,
        .outcome = .failed,
    } });
    var failed_expected: [128]u8 = undefined;
    try expectRawEntryBytes(&runtime, failed_entry_id, try std.fmt.bufPrint(
        &failed_expected,
        "{s}●{s} Tool failed\n",
        .{ ui_render.red_style, ui_render.reset_style },
    ));
}

test "active tool cancellation is presented immediately without closing lifecycle state" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);

    const ids = [_]types.ToolLifecycleId{
        lifecycleId(1, "read"),
        lifecycleId(1, "command"),
    };
    for (ids) |id| {
        _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
            .id = id,
            .reconciles_provisional_call_id = null,
            .tool_name = if (std.mem.eql(u8, id.call_id, "read")) "read_file" else "run_command",
            .activity_kind = if (std.mem.eql(u8, id.call_id, "read")) .read else .command,
        } });
    }

    try std.testing.expect(try runtime.presentActiveToolCancellation(alloc));
    try std.testing.expectEqual(@as(usize, 2), runtime.activeToolActivityCount());

    var rendered = try runtime.prepareTranscriptSource(alloc, null);
    defer rendered.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, rendered.bytes, "What can fx do differently?"),
    );
    try std.testing.expect(std.mem.find(u8, rendered.bytes, "System:") == null);
    try std.testing.expect(std.mem.find(u8, rendered.bytes, "Cancelling") == null);

    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = ids[1],
        .outcome = .{ .kind = .cancelled, .summary = "Cancelled sleep 30" },
    } });
    try std.testing.expectEqual(@as(usize, 1), runtime.activeToolActivityCount());
}

test "late successful settlement preserves its result and one turn cancellation" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |finish_before_terminal| {
        var runtime = lifecycleTestRuntime(null);
        defer runtime.deinit(alloc);

        const id = lifecycleId(1, "late-success");
        _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
            .id = id,
            .reconciles_provisional_call_id = null,
            .tool_name = "read_file",
            .activity_kind = .read,
        } });

        try std.testing.expect(try runtime.presentActiveToolCancellation(alloc));
        if (finish_before_terminal) {
            _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
                .turn_id = id.turn_id,
                .outcome = .interrupted,
            } });
        }
        _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
            .id = id,
            .outcome = .{ .kind = .completed, .summary = "Read the file" },
            .result = "late result",
        } });
        if (!finish_before_terminal) {
            _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
                .turn_id = id.turn_id,
                .outcome = .interrupted,
            } });
        }

        var rendered = try runtime.prepareTranscriptSource(alloc, null);
        defer rendered.deinit(alloc);
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, rendered.bytes, "What can fx do differently?"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, rendered.bytes, "Read the file"),
        );
        try std.testing.expectEqual(
            RawEntryClass.turn_cancellation,
            runtime.entries.getLast().raw_bytes.class,
        );
        const detail = runtime.toolDetailForEntry(runtime.toolActivityRecord(id).?.entry_id).?;
        try std.testing.expectEqualStrings("late result", detail.result.?);
        try std.testing.expectEqual(types.ToolOutcomeKind.completed, detail.outcome.?);
    }
}

test "post-cancel sibling settlement preserves one turn cancellation" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |sibling_reports_terminal| {
        var runtime = lifecycleTestRuntime(null);
        defer runtime.deinit(alloc);

        const first = lifecycleId(1, "first");
        _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
            .id = first,
            .reconciles_provisional_call_id = null,
            .tool_name = "read_file",
            .activity_kind = .read,
        } });
        try std.testing.expect(try runtime.presentActiveToolCancellation(alloc));
        _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
            .id = first,
            .outcome = .{ .kind = .completed, .summary = "Read first" },
        } });

        const sibling = lifecycleId(1, "sibling");
        _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
            .id = sibling,
            .reconciles_provisional_call_id = null,
            .tool_name = "grep_files",
            .activity_kind = .read,
        } });
        if (sibling_reports_terminal) {
            _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
                .id = sibling,
                .outcome = .{ .kind = .cancelled, .summary = "Search cancelled" },
            } });
        }
        _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
            .turn_id = first.turn_id,
            .outcome = .interrupted,
        } });

        var rendered = try runtime.prepareTranscriptSource(alloc, null);
        defer rendered.deinit(alloc);
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, rendered.bytes, "What can fx do differently?"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, rendered.bytes, "Read first"),
        );
    }
}

test "late zero-output command settlement reserves distinct presentation entries" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |finish_before_terminal| {
        var runtime = lifecycleTestRuntime(null);
        defer runtime.deinit(alloc);

        const id = lifecycleId(1, "zero-output-command");
        _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
            .id = id,
            .reconciles_provisional_call_id = null,
            .tool_name = "shell",
            .activity_kind = .command,
            .arguments_json = "{\"request\":{\"action\":\"run\",\"command\":\"true\"}}",
        } });
        try std.testing.expect(try runtime.presentActiveToolCancellation(alloc));
        if (finish_before_terminal) {
            _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
                .turn_id = id.turn_id,
                .outcome = .interrupted,
            } });
        }
        _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
            .id = id,
            .outcome = .{ .kind = .completed, .summary = "Ran true" },
            .result = "exit_code=0\n",
            .result_memory = .{
                .command_process_presentation = .{ .exit_code = 0 },
            },
        } });
        if (!finish_before_terminal) {
            _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
                .turn_id = id.turn_id,
                .outcome = .interrupted,
            } });
        }

        var rendered = try runtime.prepareTranscriptSource(alloc, null);
        defer rendered.deinit(alloc);
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, rendered.bytes, "What can fx do differently?"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, rendered.bytes, "Ran true"),
        );
        const detail = runtime.toolDetailForEntry(runtime.toolActivityRecord(id).?.entry_id).?;
        try std.testing.expectEqual(types.ToolOutcomeKind.completed, detail.outcome.?);
        try std.testing.expectEqual(
            types.CommandProcessPresentation{ .exit_code = 0 },
            detail.command_process_presentation.?,
        );
        try std.testing.expectEqual(
            RawEntryClass.command_output,
            runtime.rawEntryClass(detail.command_output_entry_id.?).?,
        );
        for (runtime.entries.items, 0..) |entry, entry_index| {
            for (runtime.entries.items[entry_index + 1 ..]) |other| {
                try std.testing.expect(entry.id() != other.id());
            }
        }
    }
}

fn checkLateZeroOutputCommandCancellationAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);

    const id = lifecycleId(1, "allocation-command");
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "shell",
        .activity_kind = .command,
        .arguments_json = "{\"request\":{\"action\":\"run\",\"command\":\"true\"}}",
    } });
    try std.testing.expect(try runtime.presentActiveToolCancellation(alloc));
    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = id.turn_id,
        .outcome = .interrupted,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Ran true" },
        .result = "exit_code=0\n",
        .result_memory = .{
            .command_process_presentation = .{ .exit_code = 0 },
        },
    } });

    const detail = runtime.toolDetailForEntry(runtime.toolActivityRecord(id).?.entry_id).?;
    try std.testing.expectEqual(types.ToolOutcomeKind.completed, detail.outcome.?);
    try std.testing.expectEqual(
        RawEntryClass.command_output,
        runtime.rawEntryClass(detail.command_output_entry_id.?).?,
    );
    var rendered = try runtime.prepareTranscriptSource(alloc, null);
    defer rendered.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, rendered.bytes, "What can fx do differently?"),
    );
}

fn checkLateZeroOutputCommandCancellationAllocationFailures(alloc: Allocator) !void {
    return checkLateZeroOutputCommandCancellationAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

test "late zero-output command cancellation remains atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLateZeroOutputCommandCancellationAllocationFailures,
        .{},
    );
}

fn expectRawEntryBytes(
    runtime: *const TranscriptRuntime,
    entry_id: u32,
    expected: []const u8,
) !void {
    for (runtime.entries.items) |entry| {
        if (entry == .raw_bytes and entry.raw_bytes.id == entry_id) {
            try std.testing.expectEqualStrings(expected, entry.raw_bytes.bytes);
            return;
        }
    }
    return error.TestExpectedEqual;
}

fn transcriptContainsEntry(runtime: *const TranscriptRuntime, entry_id: u32) bool {
    for (runtime.entries.items) |entry| {
        if (entry.id() == entry_id) return true;
    }
    return false;
}

fn checkLifecycleRepositionAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "ALLOCATION TRANSCRIPT 01\n" ++
            "ALLOCATION TRANSCRIPT 02\n" ++
            "ALLOCATION TRANSCRIPT 03\n" ++
            "ALLOCATION TRANSCRIPT 04\n" ++
            "ALLOCATION TRANSCRIPT 05\n" ++
            "ALLOCATION TRANSCRIPT 06\n",
        .subagent_status,
    );
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        4,
        1,
        1,
    );

    const id = lifecycleId(93, "allocation-command");
    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = id,
        .tool_name = "run_command",
        .activity_kind = .command,
    } });
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "permissions",
        .tone = .success,
        .body = "Auto agent approved this request: Running command.",
        .visibility = .full_only,
    });

    var source_before = try runtime.prepareTranscriptSource(std.testing.allocator, null);
    defer source_before.deinit(std.testing.allocator);
    const diagnostic_before = runtime.transcriptCommitDiagnostic();
    _ = runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"seq 1 1\"}",
        .place_after_current_transcript = true,
    } }) catch |err| {
        var source_after = try runtime.prepareTranscriptSource(std.testing.allocator, null);
        defer source_after.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(source_before.bytes, source_after.bytes);
        try std.testing.expectEqualDeep(
            diagnostic_before,
            runtime.transcriptCommitDiagnostic(),
        );
        try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .provisional);
        return err;
    };

    try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .authoritative);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        runtime.transcriptCommitDiagnostic().state,
    );
}

fn checkLifecycleRepositionAllocationFailures(alloc: Allocator) !void {
    return checkLifecycleRepositionAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

test "coalesced approval lifecycle reposition is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLifecycleRepositionAllocationFailures,
        .{},
    );
}

test "lifecycle pin cleanup preserves a capped canonical anchor without pruning" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
        .max_transcript_bytes = 64,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    const long_tail = try makeLongPastePrompt(alloc, 40);
    defer alloc.free(long_tail);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        long_tail,
        .subagent_status,
    );
    const id = lifecycleId(94, "cleanup-command");
    _ = try startLifecycle(&runtime, alloc, id.turn_id, id.call_id);
    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = id.turn_id,
        .outcome = .completed,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Cleanup complete" },
    } });

    var metrics = Metrics{};
    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try std.testing.expect(committed_source.recorded_entries_authoritative);
    try std.testing.expect(committed_source.bytes.len > runtime.transcript.items.len);
    var committed_prepared = try runtime.prepareTranscriptSurfacePaintForArea(
        alloc,
        &metrics,
        .{ .top = runtime.owned_top_row, .bottom = runtime.layout.content_bottom },
    );
    defer committed_prepared.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        committed_prepared.selection,
        preparedVisualOffsetForTest(&committed_prepared),
        committed_prepared.cursor.cursor_row,
        committed_prepared.cursor.cursor_col,
        1,
    );
    const committed_diagnostic = runtime.transcriptCommitDiagnostic();

    try runtime.finishLifecycleBatch(alloc);

    try std.testing.expectEqualDeep(
        committed_diagnostic,
        runtime.transcriptCommitDiagnostic(),
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.lifecyclePinCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.toolActivityRecordCount());
    var cleaned_source = try runtime.prepareTranscriptSource(alloc, null);
    defer cleaned_source.deinit(alloc);
    try std.testing.expectEqualStrings(committed_source.bytes, cleaned_source.bytes);
}

test "lifecycle pin cleanup preserves a canonical anchor when retention prunes" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(48, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);

    const anchored = "anchored lifecycle cleanup transcript\n";
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        anchored,
        .subagent_status,
    );
    const id = lifecycleId(95, "pruning-cleanup-command");
    _ = try startLifecycle(&runtime, alloc, id.turn_id, id.call_id);
    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = id.turn_id,
        .outcome = .completed,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Cleanup complete" },
    } });

    var committed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer committed_source.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_source.bytes,
        testSelection(0),
        0,
        4,
        1,
        1,
    );
    const committed_history_visual_offset = try stableHistoryVisualOffsetForTest(&runtime);
    runtime.max_retained_transcript_bytes =
        transcript_store.retainedStructuredBytes(&runtime) - anchored.len;

    try runtime.finishLifecycleBatch(alloc);

    try expectStableNormalBufferRecoveryForTest(
        &runtime,
        committed_history_visual_offset,
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.lifecyclePinCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.toolActivityRecordCount());
    var retained_source = try runtime.prepareTranscriptSource(alloc, null);
    defer retained_source.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, retained_source.bytes, anchored),
    );
}

fn checkLifecycleAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(64);
    defer runtime.deinit(alloc);
    const existing = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "existing transcript state\n",
        .subagent_status,
    );
    const entry_id = startLifecycle(&runtime, alloc, 1, "transaction") catch |err| {
        try std.testing.expectEqual(@as(usize, 0), runtime.toolActivityRecordCount());
        try std.testing.expectEqual(@as(usize, 0), runtime.lifecyclePinCount());
        try expectRawEntryBytes(&runtime, existing, "existing transcript state\n");
        return err;
    };
    _ = runtime.applyToolLifecycle(alloc, .{ .progress = .{
        .id = lifecycleId(1, "transaction"),
        .text = "● Reading updated",
    } }) catch |err| {
        try std.testing.expect(runtime.isLifecyclePinned(entry_id));
        try std.testing.expect(std.mem.find(
            u8,
            runtime.toolStatusEntryLabel(entry_id).?,
            "updated",
        ) == null);
        return err;
    };
    _ = runtime.applyToolLifecycle(alloc, .{
        .turn_finished = .{ .turn_id = 1, .outcome = .completed },
    }) catch |err| {
        try expectRawEntryBytes(&runtime, entry_id, "● Reading updated\n");
        try std.testing.expect(runtime.isLifecyclePinned(entry_id));
        return err;
    };
    runtime.finishLifecycleBatch(alloc) catch |err| {
        try std.testing.expect(runtime.toolActivityRecord(lifecycleId(1, "transaction")) != null);
        try std.testing.expect(runtime.isLifecyclePinned(entry_id));
        return err;
    };
    try std.testing.expect(runtime.toolActivityRecord(lifecycleId(1, "transaction")) == null);
    try std.testing.expect(!runtime.isLifecyclePinned(entry_id));
}

fn checkLifecycleAllocationFailures(alloc: Allocator) !void {
    return checkLifecycleAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

test "transcript lifecycle transactions are atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLifecycleAllocationFailures,
        .{},
    );
}

fn checkLateTerminalFallbackAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    const id = lifecycleId(1, "late-terminal");

    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = id,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    const entry_id = runtime.toolActivityRecord(id).?.entry_id;
    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = 1,
        .outcome = .completed,
    } });

    _ = runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Late completion" },
        .result = "late result",
    } }) catch |err| {
        try expectRawEntryBytes(&runtime, entry_id, "● Tool was not executed\n");
        const detail = runtime.toolDetailForEntry(entry_id).?;
        try std.testing.expect(detail.result == null);
        try std.testing.expectEqual(
            transcript_blocks.ToolFallbackDisposition.not_executed,
            detail.fallback_disposition.?,
        );
        var compact = try runtime.prepareTranscriptSource(std.testing.allocator, null);
        defer compact.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.find(u8, compact.bytes, "1 not executed") != null);
        return err;
    };

    var expected: [128]u8 = undefined;
    try expectRawEntryBytes(&runtime, entry_id, try std.fmt.bufPrint(
        &expected,
        "{s}●{s} Late completion\n",
        .{ ui_render.system_notice_text_style, ui_render.reset_style },
    ));
    const detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqualStrings("late result", detail.result.?);
    try std.testing.expect(detail.fallback_disposition == null);
    var compact = try runtime.prepareTranscriptSource(std.testing.allocator, null);
    defer compact.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "1 not executed") == null);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "Late completion") != null);
}

fn checkLateTerminalFallbackAllocationFailures(alloc: Allocator) !void {
    return checkLateTerminalFallbackAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

test "late terminal fallback replacement is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkLateTerminalFallbackAllocationFailures,
        .{},
    );
}

fn checkProvisionalTerminalAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    const id = lifecycleId(1, "provisional-terminal");

    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = id,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    const entry_id = runtime.toolActivityRecord(id).?.entry_id;
    const entries_before = runtime.entries.items.len;
    const next_entry_id_before = runtime.next_entry_id;

    _ = runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Read provisional file" },
        .result = "provisional result",
    } }) catch |err| {
        try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .provisional);
        try std.testing.expectEqual(entries_before, runtime.entries.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        const detail = runtime.toolDetailForEntry(entry_id).?;
        try std.testing.expectEqualStrings("read_file", detail.tool_name);
        try std.testing.expectEqual(types.ToolActivityKind.read, detail.activity_kind.?);
        try std.testing.expect(detail.result == null);
        try std.testing.expect(detail.outcome == null);
        const status = runtime.toolStatusEntryLabel(entry_id).?;
        try std.testing.expect(std.mem.find(u8, status, "read_file") != null);
        try std.testing.expect(std.mem.find(u8, status, "Read provisional file") == null);
        return err;
    };

    try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .terminal);
    try std.testing.expectEqual(entries_before, runtime.entries.items.len);
    try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
    const detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqualStrings("read_file", detail.tool_name);
    try std.testing.expectEqualStrings("provisional result", detail.result.?);
    try std.testing.expectEqual(types.ToolOutcomeKind.completed, detail.outcome.?);
}

fn checkProvisionalTerminalAllocationFailures(alloc: Allocator) !void {
    return checkProvisionalTerminalAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

test "provisional terminal admission is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkProvisionalTerminalAllocationFailures,
        .{},
    );
}

fn checkCommandProcessTerminalAllocationFailuresImpl(alloc: Allocator) !void {
    var runtime = lifecycleTestRuntime(null);
    defer runtime.deinit(alloc);
    const id = lifecycleId(1, "command-process-terminal");

    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"true\"}",
    } });
    const entry_id = runtime.toolActivityRecord(id).?.entry_id;
    const entries_before = runtime.entries.items.len;
    const blocks_before = runtime.command_output_blocks.items.len;
    const next_entry_id_before = runtime.next_entry_id;

    _ = runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Ran true" },
        .result_memory = .{ .command_process_presentation = .{ .exit_code = 0 } },
    } }) catch |err| {
        try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .authoritative);
        try std.testing.expectEqual(entries_before, runtime.entries.items.len);
        try std.testing.expectEqual(blocks_before, runtime.command_output_blocks.items.len);
        try std.testing.expectEqual(next_entry_id_before, runtime.next_entry_id);
        const detail = runtime.toolDetailForEntry(entry_id).?;
        try std.testing.expect(detail.command_process_presentation == null);
        try std.testing.expect(detail.command_output_entry_id == null);
        const status = runtime.toolStatusEntryLabel(entry_id).?;
        try std.testing.expect(std.mem.find(u8, status, "run_command") != null);
        try std.testing.expect(std.mem.find(u8, status, "Ran true") == null);
        return err;
    };

    try std.testing.expect(runtime.toolActivityRecord(id).?.phase == .terminal);
    try std.testing.expectEqual(entries_before + 1, runtime.entries.items.len);
    try std.testing.expectEqual(blocks_before + 1, runtime.command_output_blocks.items.len);
    try std.testing.expectEqual(next_entry_id_before + 1, runtime.next_entry_id);
    const detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqual(
        types.CommandProcessPresentation{ .exit_code = 0 },
        detail.command_process_presentation.?,
    );
    try std.testing.expectEqual(next_entry_id_before, detail.command_output_entry_id.?);
    try std.testing.expectEqual(next_entry_id_before, runtime.command_output_blocks.items[0].entry_id.?);
}

fn checkCommandProcessTerminalAllocationFailures(alloc: Allocator) !void {
    return checkCommandProcessTerminalAllocationFailuresImpl(alloc) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => err,
    };
}

test "command process terminal admission is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkCommandProcessTerminalAllocationFailures,
        .{},
    );
}

test "capped parallel lifecycle progress keeps bounded allocations and pins" {
    const backing = std.testing.allocator;
    var counted = std.testing.FailingAllocator.init(backing, .{});
    const alloc = counted.allocator();
    var runtime = lifecycleTestRuntime(256);
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "unrelated output retained near the configured transcript cap\n",
        .subagent_status,
    );
    const first_entry_id = try startLifecycle(&runtime, alloc, 1, call_ids[0]);
    const second_entry_id = try startLifecycle(&runtime, alloc, 1, call_ids[1]);
    try std.testing.expectEqual(@as(usize, 2), runtime.tool_details.items.len);
    try std.testing.expect(runtime.toolDetailForEntry(first_entry_id) != null);
    try std.testing.expect(runtime.toolDetailForEntry(second_entry_id) != null);
    const capacity_after_start = runtime.tool_details.capacity;
    const progress_text = "● Reading progress " ++ ("x" ** 256);
    _ = try runtime.applyToolLifecycle(alloc, .{ .progress = .{
        .id = lifecycleId(1, call_ids[0]),
        .text = progress_text,
    } });
    try std.testing.expectEqual(@as(usize, 2), runtime.tool_details.items.len);
    try std.testing.expectEqual(capacity_after_start, runtime.tool_details.capacity);

    var allocations_before_progress = counted.allocations;
    for (0..120) |index| {
        if (index == 20) allocations_before_progress = counted.allocations;
        _ = try runtime.applyToolLifecycle(alloc, .{ .progress = .{
            .id = lifecycleId(1, call_ids[index % call_ids.len]),
            .text = "● Reading progress",
        } });
        try std.testing.expectEqual(capacity_after_start, runtime.tool_details.capacity);
    }
    try std.testing.expectEqual(@as(usize, 2), runtime.tool_details.items.len);
    try std.testing.expect(runtime.toolDetailForEntry(first_entry_id) != null);
    try std.testing.expect(runtime.toolDetailForEntry(second_entry_id) != null);
    try std.testing.expect(counted.allocations - allocations_before_progress <= 600);
    try std.testing.expectEqual(@as(usize, 2), runtime.lifecyclePinCount());
}

const call_ids = [_][]const u8{ "first", "second" };

test "lifecycle pins survive low cap until batch cleanup restores prune eligibility" {
    const alloc = std.testing.allocator;
    var runtime = lifecycleTestRuntime(48);
    defer runtime.deinit(alloc);

    const first = try startLifecycle(&runtime, alloc, 1, call_ids[0]);
    const second = try startLifecycle(&runtime, alloc, 1, call_ids[1]);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "ordinary output that creates retention pressure\n",
        .subagent_status,
    );

    try std.testing.expectEqual(@as(usize, 2), runtime.lifecyclePinCount());
    try std.testing.expect(transcriptContainsEntry(&runtime, first));
    try std.testing.expect(transcriptContainsEntry(&runtime, second));

    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = 1,
        .outcome = .completed,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = lifecycleId(1, "first"),
        .outcome = .{ .kind = .completed, .summary = "● First complete" },
    } });
    try std.testing.expectEqual(@as(usize, 2), runtime.lifecyclePinCount());
    var first_complete_expected: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(
            &first_complete_expected,
            "{s}●{s} First complete\n",
            .{ ui_render.system_notice_text_style, ui_render.reset_style },
        ),
        runtime.entries.items[0].raw_bytes.bytes,
    );

    try runtime.finishLifecycleBatch(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "next ordinary retention pass\n",
        .subagent_status,
    );

    try std.testing.expectEqual(@as(usize, 0), runtime.lifecyclePinCount());
    try std.testing.expectEqual(@as(usize, 0), runtime.toolActivityRecordCount());
    try std.testing.expect(
        !transcriptContainsEntry(&runtime, first) or
            !transcriptContainsEntry(&runtime, second),
    );
}

test "streaming assistant finality releases complete rows and holds only the partial tail" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 10, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var metrics: Metrics = .{};
    _ = try runtime.streamAssistantChunk(
        alloc,
        &metrics,
        "first finalized row\nsecond finalized row\npartial tail",
    );

    var partial_source = try runtime.prepareTranscriptSource(alloc, null);
    defer partial_source.deinit(alloc);
    const partial_start = std.mem.find(u8, partial_source.bytes, "  partial tail") orelse
        return error.TestExpectedPartialAssistantTail;
    try std.testing.expectEqual(
        @as(?usize, partial_start),
        runtime.transcript_release.finality_floor(
            partial_source.finality,
            runtime.finalizedToolTurnWatermark(),
            null,
        ),
    );

    _ = try runtime.streamAssistantChunk(alloc, &metrics, "\n");
    var completed_source = try runtime.prepareTranscriptSource(alloc, null);
    defer completed_source.deinit(alloc);
    try std.testing.expectEqual(
        @as(?usize, completed_source.bytes.len),
        runtime.transcript_release.finality_floor(
            completed_source.finality,
            runtime.finalizedToolTurnWatermark(),
            null,
        ),
    );
}

test "blank streaming assistant tail keeps finality inside the prepared source" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 10, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntry(alloc, "stable history\n");
    var metrics: Metrics = .{};
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "   ");

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(
        @as(?usize, source.bytes.len),
        runtime.transcript_release.finality_floor(
            source.finality,
            runtime.finalizedToolTurnWatermark(),
            null,
        ),
    );
}

test "empty assistant tail leaves the complete prepared source final" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 10, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntry(alloc, "stable history\n");
    _ = try runtime.appendAssistantTurnEntry(alloc);

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(
        @as(?usize, source.bytes.len),
        runtime.transcript_release.finality_floor(
            source.finality,
            runtime.finalizedToolTurnWatermark(),
            null,
        ),
    );
}

test "native history defers partial assistant paints but publishes hard lines" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(40, 10, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        "history\n",
        testSelection(1),
        1,
        4,
        1,
        1,
    );
    var metrics: Metrics = .{};
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "partial");
    try std.testing.expect(!runtime.render_requests.hasReason(.transcript));

    _ = try runtime.streamAssistantChunk(alloc, &metrics, " line\n");
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
}

test "streaming assistant finality keeps soft wraps of a partial hard line mutable" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(12, 10, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var metrics: Metrics = .{};
    _ = try runtime.streamAssistantChunk(
        alloc,
        &metrics,
        "finalized row\npartial tail wraps across several visual rows",
    );

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    const partial_start = std.mem.find(u8, source.bytes, "  partial") orelse
        return error.TestExpectedWrappedPartialAssistantTail;
    try std.testing.expectEqual(
        @as(?usize, partial_start),
        runtime.transcript_release.finality_floor(
            source.finality,
            runtime.finalizedToolTurnWatermark(),
            null,
        ),
    );
}

test "finality floor holds unfenced tool turn across quiet ticks and settles after the fence" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(60, 10, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    for (0..6) |index| {
        var line: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "final context {d:0>2}\n", .{index});
        _ = try runtime.appendRawTranscriptEntry(alloc, text);
    }
    var base_source = try runtime.prepareTranscriptSource(alloc, null);
    defer base_source.deinit(alloc);
    var base_prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &base_source);
    defer base_prepared.deinit(alloc);
    try commitPreparedForTest(&runtime, alloc, &base_source, &base_prepared);

    var turn_call_ids: [8][12]u8 = undefined;
    for (0..8) |index| {
        const call_id = try std.fmt.bufPrint(&turn_call_ids[index], "t2-call-{d:0>2}", .{index});
        const id = types.ToolLifecycleId{ .turn_id = 2, .call_id = call_id };
        _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
            .id = id,
            .presentation_group_id = .{ .turn_id = 2, .anchor_step_id = 1 },
            .reconciles_provisional_call_id = null,
            .tool_name = "read_file",
            .activity_kind = .read,
        } });
        _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
            .id = id,
            .outcome = .{ .kind = .completed, .summary = "Read one file" },
        } });
    }
    try runtime.finishLifecycleBatch(alloc);
    try std.testing.expectEqual(@as(u64, 0), runtime.finalizedToolTurnWatermark());

    var live_source = try runtime.prepareTranscriptSource(alloc, null);
    defer live_source.deinit(alloc);
    var live_prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &live_source);
    defer live_prepared.deinit(alloc);
    try commitPreparedForTest(&runtime, alloc, &live_source, &live_prepared);

    const held = runtime.transcript_commit_state.stable;
    try std.testing.expect(held.visual_offset > held.history_visual_offset);

    // Quiet ticks over the unchanged flow release nothing: byte stability
    // is not finality while the turn is unfenced.
    var quiet_source = try runtime.prepareTranscriptSource(alloc, null);
    defer quiet_source.deinit(alloc);
    var quiet_prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &quiet_source);
    defer quiet_prepared.deinit(alloc);
    const quiet_facts = runtime.planTranscriptScroll(&quiet_prepared);
    try std.testing.expect(quiet_facts.source_compatible);
    try std.testing.expectEqual(@as(u32, 0), quiet_facts.semantic_rows);
    try std.testing.expect(quiet_facts.finality_hold);

    // A later mutation of the same group still releases nothing.
    const late_call = types.ToolLifecycleId{ .turn_id = 2, .call_id = "t2-late" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = late_call,
        .presentation_group_id = .{ .turn_id = 2, .anchor_step_id = 1 },
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = late_call,
        .outcome = .{ .kind = .completed, .summary = "Read late file" },
    } });
    try runtime.finishLifecycleBatch(alloc);
    var mutated_source = try runtime.prepareTranscriptSource(alloc, null);
    defer mutated_source.deinit(alloc);
    var mutated_prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &mutated_source);
    defer mutated_prepared.deinit(alloc);
    const mutated_facts = runtime.planTranscriptScroll(&mutated_prepared);
    try std.testing.expectEqual(@as(u32, 0), mutated_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), mutated_facts.planned_rows);
    try commitPreparedForTest(&runtime, alloc, &mutated_source, &mutated_prepared);

    // The fence and the final mutation arrive in one batch: the first
    // post-fence frame is byte-incompatible and must hold (zero release),
    // re-anchoring on the final flow.
    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = 2,
        .outcome = .completed,
    } });
    try runtime.finishLifecycleBatch(alloc);
    try std.testing.expectEqual(@as(u64, 2), runtime.finalizedToolTurnWatermark());

    // The debt settles on the first eligible frame after the fence: the
    // same frame when the fence publication changed no bytes, or the frame
    // after a byte-incompatible publication re-anchors (Phase A then B).
    var released: u32 = 0;
    for (0..2) |frame_index| {
        var frame_source = try runtime.prepareTranscriptSource(alloc, null);
        defer frame_source.deinit(alloc);
        var frame_prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &frame_source);
        defer frame_prepared.deinit(alloc);
        const frame_facts = runtime.planTranscriptScroll(&frame_prepared);
        if (!frame_facts.source_compatible) {
            // Phase A: zero release while the anchor is stale.
            try std.testing.expectEqual(@as(u32, 0), frame_facts.semantic_rows);
            try std.testing.expectEqual(@as(u16, 0), frame_facts.planned_rows);
            try std.testing.expect(frame_facts.finality_hold);
            try std.testing.expectEqual(@as(usize, 0), frame_index);
        }
        released += frame_facts.semantic_rows;
        try commitPreparedForTest(&runtime, alloc, &frame_source, &frame_prepared);
    }
    try std.testing.expect(released > 0);
    const settled = runtime.transcript_commit_state.stable;
    try std.testing.expectEqual(settled.visual_offset, settled.history_visual_offset);
}

test "catch-up release materializes history before staging a larger finality hold" {
    const alloc = std.testing.allocator;
    const committed_flow =
        "row-00\nrow-01\nrow-02\nrow-03\n" ++
        "row-04\nrow-05\nrow-06\nrow-07\n";
    const target_flow = committed_flow ++
        "row-08\nrow-09\nrow-10\nrow-11\nrow-12\nrow-13\n";
    const finality_floor = "row-00\nrow-01\nrow-02\n".len;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var committed_source = try testSource(alloc, committed_flow, runtime.layout.cols);
    defer committed_source.deinit(alloc);
    var committed_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &committed_source,
    );
    defer committed_prepared.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_flow,
        committed_prepared.selection,
        preparedVisualOffsetForTest(&committed_prepared),
        committed_prepared.cursor.cursor_row,
        committed_prepared.cursor.cursor_col,
        1,
    );
    switch (runtime.transcript_commit_state) {
        .stable => |*anchor| {
            anchor.history_visual_offset = 0;
            anchor.history_catchup_pending = true;
        },
        .invalid, .recovering => return error.TestExpectedStableTranscript,
    }

    var source = try testSource(alloc, target_flow, runtime.layout.cols);
    defer source.deinit(alloc);
    source.finality.mutation_pin_start = finality_floor;
    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);
    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expectEqual(@as(u32, 3), facts.semantic_rows);
    try std.testing.expect(facts.semantic_rows > 0);
    try std.testing.expect(
        facts.target_visual_offset - facts.source_visual_offset > facts.semantic_rows,
    );
    try std.testing.expect(facts.finality_hold);

    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(&runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    try std.testing.expectEqualStrings(
        "row-00\r\nrow-01\r\nrow-02\r\n",
        transition.document_append.bytes,
    );
    switch (transition.document_append.clear) {
        .rows => |rows| try std.testing.expectEqual(@as(u16, 3), rows),
        .remainder => return error.TestExpectedHistoryReplay,
    }
}

test "partial finality release bounds append before staging withheld viewport" {
    const alloc = std.testing.allocator;
    const committed_flow =
        "row-00\nrow-01\nrow-02\nrow-03\n" ++
        "row-04\nrow-05\nrow-06\nrow-07\n";
    const target_flow = committed_flow ++
        "row-08\nrow-09\nrow-10\nrow-11\nrow-12\nrow-13\n";
    const finality_floor = "row-00\nrow-01\nrow-02\nrow-03\nrow-04\n".len;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    var committed_source = try testSource(alloc, committed_flow, runtime.layout.cols);
    defer committed_source.deinit(alloc);
    var committed_prepared = try prepareTestSourceForCurrentArea(
        &runtime,
        alloc,
        &committed_source,
    );
    defer committed_prepared.deinit(alloc);
    try installStableAnchorForTest(
        &runtime,
        alloc,
        committed_flow,
        committed_prepared.selection,
        preparedVisualOffsetForTest(&committed_prepared),
        committed_prepared.cursor.cursor_row,
        committed_prepared.cursor.cursor_col,
        1,
    );
    switch (runtime.transcript_commit_state) {
        .stable => |*anchor| anchor.total_visual_rows = 8,
        .invalid, .recovering => return error.TestExpectedStableTranscript,
    }

    var source = try testSource(alloc, target_flow, runtime.layout.cols);
    defer source.deinit(alloc);
    source.finality.mutation_pin_start = finality_floor;
    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);
    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expectEqual(@as(u32, 4), facts.source_visual_offset);
    try std.testing.expectEqual(@as(u32, 10), facts.target_visual_offset);
    try std.testing.expectEqual(@as(u32, 1), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 1), facts.planned_rows);
    try std.testing.expect(facts.finality_hold);

    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan = testPaintPlan(&runtime, prepared.selection);
    var transition = try resolveAndSealTranscriptTransitionForTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);

    try std.testing.expectEqualStrings(
        "row-08\r\n",
        transition.document_append.bytes,
    );
    try std.testing.expectEqual(@as(u32, 10), transition.visual_offset);
    try std.testing.expectEqual(@as(u32, 5), transition.history_visual_offset);
}

test "recovery growth does not release rows past the finality floor" {
    const alloc = std.testing.allocator;
    const attempt_flow =
        "row-00\nrow-01\nrow-02\nrow-03\n" ++
        "row-04\nrow-05\nrow-06\nrow-07\n";
    const grown_flow = attempt_flow ++
        "row-08\nrow-09\nrow-10\nrow-11\n";
    const finality_floor = "row-00\nrow-01\nrow-02\nrow-03\n".len;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(20, 8, 4),
        .owned_top_row = 1,
        .transcript_commit_state = .{ .recovering = .{
            .accepted_visual_offset = 4,
            .accepted_history_visual_offset = 4,
            .attempt_visual_offset = 4,
            .attempt_total_visual_rows = 8,
            .materialized_visual_offset = 4,
            .materialized_visual_rows = 4,
            .materialized_flow_len = attempt_flow.len,
            .attempt_cols = 20,
            .tracks_semantic_progress = true,
            .flow = try alloc.dupe(u8, attempt_flow),
            .cursor_row = 4,
            .cursor_col = 1,
        } },
    };
    defer runtime.deinit(alloc);

    var source = try testSource(alloc, grown_flow, runtime.layout.cols);
    defer source.deinit(alloc);
    source.finality.mutation_pin_start = finality_floor;
    var prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &source);
    defer prepared.deinit(alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expect(facts.recovery_progress_compatible);
    try std.testing.expectEqual(@as(u32, 8), facts.target_visual_offset);
    try std.testing.expectEqual(@as(u32, 0), facts.semantic_rows);
    try std.testing.expectEqual(@as(u32, 0), facts.semantic_progress_rows);
    try std.testing.expectEqual(@as(u16, 0), facts.planned_rows);
}

test "pending replacement notice holds release until the finished replacement settles" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(24, 10, 4),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    for (0..4) |index| {
        var line: [24]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "history {d:0>2}\n", .{index});
        _ = try runtime.appendRawTranscriptEntry(alloc, text);
    }
    var base_source = try runtime.prepareTranscriptSource(alloc, null);
    defer base_source.deinit(alloc);
    var base_prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &base_source);
    defer base_prepared.deinit(alloc);
    try commitPreparedForTest(&runtime, alloc, &base_source, &base_prepared);
    const notice_id = try runtime.appendReplaceableSemanticNotice(alloc, .{
        .topic = "feedback",
        .tone = .neutral,
        .body = "Preparing feedback report while external work is blocking",
    });
    for (0..6) |index| {
        var line: [24]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "later {d:0>2}\n", .{index});
        _ = try runtime.appendRawTranscriptEntry(alloc, text);
    }

    var live_source = try runtime.prepareTranscriptSource(alloc, null);
    defer live_source.deinit(alloc);
    var live_prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &live_source);
    defer live_prepared.deinit(alloc);
    try commitPreparedForTest(&runtime, alloc, &live_source, &live_prepared);
    const held = runtime.transcript_commit_state.stable;
    try std.testing.expect(held.visual_offset > held.history_visual_offset);

    // Quiet frames while the producer blocks release nothing.
    var quiet_source = try runtime.prepareTranscriptSource(alloc, null);
    defer quiet_source.deinit(alloc);
    var quiet_prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &quiet_source);
    defer quiet_prepared.deinit(alloc);
    const quiet_facts = runtime.planTranscriptScroll(&quiet_prepared);
    try std.testing.expect(quiet_facts.source_compatible);
    try std.testing.expectEqual(@as(u32, 0), quiet_facts.semantic_rows);
    try std.testing.expect(quiet_facts.finality_hold);

    // The finished replacement clears the pin; the incompatible frame
    // re-anchors with zero release and the next frame settles everything.
    try std.testing.expect(try runtime.replaceSemanticNotice(alloc, notice_id, .{
        .topic = "feedback",
        .tone = .success,
        .body = "Feedback report ready",
    }));
    var replaced_source = try runtime.prepareTranscriptSource(alloc, null);
    defer replaced_source.deinit(alloc);
    var replaced_prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &replaced_source);
    defer replaced_prepared.deinit(alloc);
    const replaced_facts = runtime.planTranscriptScroll(&replaced_prepared);
    try std.testing.expect(!replaced_facts.source_compatible);
    try std.testing.expectEqual(@as(u32, 0), replaced_facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), replaced_facts.planned_rows);
    try commitPreparedForTest(&runtime, alloc, &replaced_source, &replaced_prepared);

    var settle_source = try runtime.prepareTranscriptSource(alloc, null);
    defer settle_source.deinit(alloc);
    try std.testing.expect(
        std.mem.find(u8, settle_source.bytes, "report ready") != null,
    );
    var settle_prepared = try prepareTestSourceForCurrentArea(&runtime, alloc, &settle_source);
    defer settle_prepared.deinit(alloc);
    const settle_facts = runtime.planTranscriptScroll(&settle_prepared);
    try std.testing.expect(settle_facts.source_compatible);
    try std.testing.expect(settle_facts.semantic_rows > 0);
    try commitPreparedForTest(&runtime, alloc, &settle_source, &settle_prepared);
    const settled = runtime.transcript_commit_state.stable;
    try std.testing.expectEqual(settled.visual_offset, settled.history_visual_offset);
}

fn appendRecordedWriteForFinalityTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    lifecycle_id: ?types.ToolLifecycleId,
) !u32 {
    const entry_id = try runtime.appendRawTranscriptEntryClassified(alloc, "● Wrote receipt.txt\n", .tool_status);
    try runtime.attachHistoricalToolDetailWithLifecycle(
        alloc,
        entry_id,
        .{ .id = "saved-write", .name = "write_file", .arguments_json = "{\"path\":\"receipt.txt\"}" },
        .write,
        .{
            .tool_call_id = @constCast("saved-write"),
            .tool_name = @constCast("write_file"),
            .status = .success,
            .output = @constCast("saved result"),
            .output_bytes = 12,
            .stored_output_bytes = 12,
        },
        lifecycle_id,
    );
    return entry_id;
}

test "recorded tool finality does not depend on the current turn watermark" {
    const alloc = std.testing.allocator;
    for ([_]?u64{ null, 1, 2, 50_000 }) |turn_id| {
        var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(88, 24, 20) };
        defer runtime.deinit(alloc);
        const id = try appendRecordedWriteForFinalityTest(&runtime, alloc, if (turn_id) |turn|
            .{ .turn_id = turn, .call_id = "saved-write" }
        else
            null);
        var source = try runtime.prepareTranscriptSource(alloc, null);
        defer source.deinit(alloc);
        try std.testing.expectEqual(@as(?usize, null), runtime.transcript_release.finality_floor(source.finality, 0, null));
        if (turn_id) |turn| {
            const archived_id = runtime.toolDetailForEntry(id).?.lifecycle_id.?;
            try std.testing.expectEqual(turn, archived_id.turn_id);
            try std.testing.expectEqualStrings("saved-write", archived_id.call_id);
        }
    }
}

test "recorded tool finality stays independent of a live turn with the same number" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = transcriptTestLayout(88, 24, 20) };
    defer runtime.deinit(alloc);
    _ = try appendRecordedWriteForFinalityTest(&runtime, alloc, .{ .turn_id = 1, .call_id = "saved-write" });
    _ = try runtime.appendRawTranscriptEntry(alloc, "Saved response\n");
    const live_id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "live-write" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = live_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "write_file",
        .activity_kind = .write,
    } });
    for ([_]bool{ false, true }) |terminal| {
        if (terminal) _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
            .id = live_id,
            .outcome = .{ .kind = .completed, .summary = "Wrote live file" },
        } });
        var source = try runtime.prepareTranscriptSource(alloc, null);
        defer source.deinit(alloc);
        const floor = runtime.transcript_release.finality_floor(source.finality, 0, null) orelse return error.TestExpectedLiveFinalityFloor;
        try std.testing.expect(floor > 0);
        try std.testing.expect(std.mem.find(u8, source.bytes[0..floor], "Saved response") != null);
    }
    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{ .turn_id = 1, .outcome = .completed } });
    try runtime.finishLifecycleBatch(alloc);
    var finished = try runtime.prepareTranscriptSource(alloc, null);
    defer finished.deinit(alloc);
    try std.testing.expectEqual(@as(?usize, null), runtime.transcript_release.finality_floor(finished.finality, runtime.finalizedToolTurnWatermark(), null));
}

test "recorded tool finality survives an owned snapshot after source retirement" {
    const alloc = std.testing.allocator;
    var restored = TranscriptRuntime{ .layout = transcriptTestLayout(88, 24, 20) };
    defer restored.deinit(alloc);
    const entry_id = try restored.appendRawTranscriptEntryClassified(alloc, "● Wrote receipt.txt\n", .tool_status);
    {
        var original = TranscriptRuntime{ .layout = transcriptTestLayout(88, 24, 20) };
        defer original.deinit(alloc);
        const id = try appendRecordedWriteForFinalityTest(&original, alloc, .{ .turn_id = 2, .call_id = "saved-write" });
        var detail = try transcript_store.cloneToolDetailForSnapshot(alloc, original.toolDetailForEntry(id).?.*);
        errdefer detail.deinit(alloc);
        detail.entry_id = entry_id;
        try restored.tool_details.append(alloc, detail);
    }
    var source = try restored.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(@as(?usize, null), restored.transcript_release.finality_floor(source.finality, 0, null));
    const detail = restored.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqual(@as(u64, 2), detail.lifecycle_id.?.turn_id);
    try std.testing.expectEqualStrings("saved-write", detail.lifecycle_id.?.call_id);
    try std.testing.expectEqualStrings("saved result", detail.result.?);
}

test "finality candidates keep tool turn and replaceable tail offsets independent" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(60, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const id = types.ToolLifecycleId{ .turn_id = 5, .call_id = "boundary-call" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .presentation_group_id = .{ .turn_id = 5, .anchor_step_id = 1 },
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Read boundary file" },
    } });
    try runtime.finishLifecycleBatch(alloc);
    _ = try runtime.appendRawTranscriptEntry(alloc, "settled context line\n");
    _ = try transcript_store.appendReplaceableTranscriptLineSilent(
        &runtime,
        alloc,
        "working status line",
    );

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), source.finality.tool_turn_floors.len);
    const group_floor = source.finality.tool_turn_floors[0];
    try std.testing.expectEqual(@as(u64, 5), group_floor.turn_id);
    try std.testing.expect(group_floor.start_byte < source.bytes.len);
    // The replaceable-tail contract keeps its own offset; the finality
    // boundary does not repurpose it.
    try std.testing.expect(source.replaceable_last_line);
    try std.testing.expect(source.replaceable_start > group_floor.start_byte);
    try std.testing.expect(source.replaceable_start < source.bytes.len);
}

fn applyCompletedReadForFinalityTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    turn_id: u64,
    call_id: []const u8,
    presentation_group_id: ?types.ToolPresentationGroupId,
) !void {
    const id = types.ToolLifecycleId{ .turn_id = turn_id, .call_id = call_id };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .presentation_group_id = presentation_group_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Read finality fixture" },
    } });
}

test "finality candidates anchor a fully grouped turn at its newest rendered group" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 14, 10),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const group_a = types.ToolPresentationGroupId{ .turn_id = 9, .anchor_step_id = 1 };
    for ([_][]const u8{ "group-a-1", "group-a-2", "group-a-3" }) |call_id| {
        try applyCompletedReadForFinalityTest(&runtime, alloc, 9, call_id, group_a);
    }
    _ = try runtime.appendRawTranscriptEntry(alloc, "SECOND_GROUP_INTRO\n");
    const group_b = types.ToolPresentationGroupId{ .turn_id = 9, .anchor_step_id = 2 };
    try applyCompletedReadForFinalityTest(&runtime, alloc, 9, "group-b-1", group_b);

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), source.finality.tool_turn_floors.len);
    try std.testing.expect(source.finality.mutation_pin_start == null);

    const group_a_header = try std.fmt.allocPrint(
        alloc,
        "{s}●\x1b[0m {s}3 tool calls · 3 read\x1b[0m",
        .{ user_message_card.promptMarkerStyle(), ui_render.statusline_style },
    );
    defer alloc.free(group_a_header);
    const group_b_header = try std.fmt.allocPrint(
        alloc,
        "{s}●\x1b[0m {s}1 tool call · 1 read\x1b[0m",
        .{ user_message_card.promptMarkerStyle(), ui_render.statusline_style },
    );
    defer alloc.free(group_b_header);
    const group_a_start = std.mem.find(u8, source.bytes, group_a_header) orelse
        return error.TestExpectedGroupAHeader;
    const group_b_start = std.mem.find(u8, source.bytes, group_b_header) orelse
        return error.TestExpectedGroupBHeader;
    try std.testing.expect(group_a_start < group_b_start);

    const floor = source.finality.tool_turn_floors[0];
    try std.testing.expectEqual(@as(u64, 9), floor.turn_id);
    try std.testing.expectEqual(group_b_start, floor.start_byte);
}

test "finality candidates keep a mixed legacy turn at its earliest rendered tool row" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(80, 14, 10),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const group_a = types.ToolPresentationGroupId{ .turn_id = 10, .anchor_step_id = 1 };
    try applyCompletedReadForFinalityTest(&runtime, alloc, 10, "mixed-group-a", group_a);
    try applyCompletedReadForFinalityTest(&runtime, alloc, 10, "mixed-legacy", null);
    _ = try runtime.appendRawTranscriptEntry(alloc, "LATEST_GROUP_INTRO\n");
    const group_b = types.ToolPresentationGroupId{ .turn_id = 10, .anchor_step_id = 2 };
    try applyCompletedReadForFinalityTest(&runtime, alloc, 10, "mixed-group-b", group_b);

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), source.finality.tool_turn_floors.len);
    try std.testing.expect(source.finality.mutation_pin_start == null);

    const group_a_header = try std.fmt.allocPrint(
        alloc,
        "{s}●\x1b[0m {s}1 tool call · 1 read\x1b[0m",
        .{ user_message_card.promptMarkerStyle(), ui_render.statusline_style },
    );
    defer alloc.free(group_a_header);
    const earliest_tool_start = std.mem.find(u8, source.bytes, group_a_header) orelse
        return error.TestExpectedGroupAHeader;
    const floor = source.finality.tool_turn_floors[0];
    try std.testing.expectEqual(@as(u64, 10), floor.turn_id);
    try std.testing.expectEqual(earliest_tool_start, floor.start_byte);
}

test "finality candidates retain the global pin for an unidentified tool row" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = transcriptTestLayout(60, 12, 8),
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try transcript_store.appendPinnedToolStatusAtomic(
        &runtime,
        alloc,
        "● Running unidentified tool\n",
    );
    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), source.finality.tool_turn_floors.len);
    try std.testing.expect(source.finality.mutation_pin_start != null);
}
