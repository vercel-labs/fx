// Host contract:
// - fields: entries, transcript, layout, cursor_row, cursor_col, viewport_top_row,
//   owned_top_row, pending_scroll_compact,
//   min_visible_viewport_rows, reflow_clear_guard_rows, viewport_clear_pending,
//   resize_history_row_delta,
//   has_painted_transcript,
//   last_viewport_selection, last_visible_transcript_*, last_paint_bottom_reserved_rows,
//   replaceable_row, extra_input_rows, footer_reserved_base_rows
// - methods: invalidateTranscriptAnchor, recordFrameInvalidation
// This module owns viewport anchoring and footer-gap coordination helpers.

const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const render_engine = @import("../render_engine.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;
const transcript_blocks = render_engine.transcript_blocks;
const viewport_selection = render_engine.viewport_selection;

const TranscriptBlockKind = transcript_blocks.TranscriptBlockKind;
const ViewportSelection = viewport_selection.ViewportSelection;
const blockKindForRawClass = transcript_blocks.blockKindForRawClass;
const compactTailVisibleBlockKind = transcript_blocks.compactTailVisibleBlockKind;
const default_block_gap_policy = transcript_blocks.default_block_gap_policy;
const rowForLineIndex = viewport_selection.rowForLineIndex;
const trimBlockTail = transcript_blocks.trimBlockTail;

fn requestTranscriptPaint(self: anytype) void {
    const Runtime = @TypeOf(self.*);
    if (comptime @hasDecl(Runtime, "markTranscriptDirty")) {
        self.markTranscriptDirty();
    } else {
        self.transcript_band_dirty = true;
    }
}

fn idleFooterGapAppliesTo(kind: ?TranscriptBlockKind) bool {
    return transcript_blocks.footerBoundaryGapRowsForTail(kind) > 0;
}

pub fn initViewport(self: anytype, metrics: *Metrics, requested_start_row: u16) !void {
    try self.initViewportWithReservedRows(metrics, requested_start_row, 0);
}

pub fn initViewportWithReservedRows(self: anytype, metrics: *Metrics, requested_start_row: u16, min_body_rows: u16) !void {
    _ = metrics;
    self.min_visible_viewport_rows = min_body_rows;

    var start_row = requested_start_row;
    if (start_row < 1) start_row = 1;
    if (start_row > self.layout.rows) start_row = self.layout.rows;

    const reserve_rows = @min(min_body_rows, self.layout.content_bottom);
    const max_start_row = @max(@as(u16, 1), if (reserve_rows > 0)
        self.layout.content_bottom - reserve_rows + 1
    else
        self.layout.content_bottom);
    debug_trace.logf("render", "initViewport requested={d} clamped={d} reserve_rows={d} target_start={d} layout={d}x{d} content_bottom={d} has_painted={s}", .{ requested_start_row, start_row, reserve_rows, max_start_row, self.layout.cols, self.layout.rows, self.layout.content_bottom, if (self.has_painted_transcript) "true" else "false" });
    if (start_row > max_start_row) {
        debug_trace.logf("render", "initViewport clamp_to_frame start={d} target={d}", .{ start_row, max_start_row });
        start_row = max_start_row;
    }

    self.cursor_row = start_row;
    self.cursor_col = 1;
    self.viewport_top_row = start_row;
    self.owned_top_row = start_row;
    self.pending_scroll_compact = false;
    self.invalidateTranscriptAnchor("init_viewport_frame_reanchor");
    requestTranscriptPaint(self);
    recordViewportInvalidation(self, .viewport_reanchor, start_row, self.layout.rows);
    debug_trace.logf("frame_plan", "init_viewport_frame_deferred start={d} rows={d}", .{ start_row, self.layout.rows });
    debug_trace.logf("render", "initViewport exit viewport_top={d} cursor={d},{d} has_painted={s}", .{ self.viewport_top_row, self.cursor_row, self.cursor_col, if (self.has_painted_transcript) "true" else "false" });
}

pub fn reserveVisibleViewportRows(self: anytype, min_body_rows: u16) void {
    if (min_body_rows == 0 or self.layout.content_bottom == 0) return;

    const reserve_rows = @min(min_body_rows, self.layout.content_bottom);
    if (reserve_rows == 0) return;

    const desired_top = self.layout.content_bottom - reserve_rows + 1;
    const target_top = @max(desired_top, self.owned_top_row);
    if (self.viewport_top_row <= target_top) return;

    const scroll_rows = self.viewport_top_row - target_top;
    self.reflow_clear_guard_rows = @max(self.reflow_clear_guard_rows, 1);
    self.viewport_clear_pending = true;
    debug_trace.logf("render", "viewport reserve_resize_reanchor rows={d} from={d} to={d} reserve_rows={d} owned_top={d} layout={d}x{d} content_bottom={d}", .{ scroll_rows, self.viewport_top_row, target_top, reserve_rows, self.owned_top_row, self.layout.cols, self.layout.rows, self.layout.content_bottom });
    self.viewport_top_row = target_top;
    self.recordFrameInvalidation(.{
        .reason = .viewport_reanchor,
        .top = target_top,
        .bottom = self.layout.rows,
    }) catch |err| {
        debug_trace.logf(
            "frame_plan",
            "viewport_reserve_invalidation_drop top={d} bottom={d} err={s}",
            .{ target_top, self.layout.rows, @errorName(err) },
        );
    };
}

pub fn reanchorTop(self: anytype, alloc: Allocator, metrics: *Metrics) !void {
    _ = alloc;
    debug_trace.logf("render", "reanchorTop layout={d}x{d} content_bottom={d} viewport_top={d} transcript_bytes={d}", .{ self.layout.cols, self.layout.rows, self.layout.content_bottom, self.viewport_top_row, self.transcript.items.len });
    metrics.full_redraws += 1;
    self.cursor_row = self.owned_top_row;
    self.cursor_col = 1;
    self.viewport_top_row = self.owned_top_row;
    self.pending_scroll_compact = false;
    self.invalidateTranscriptAnchor("reanchor_top_frame");
    requestTranscriptPaint(self);
    recordViewportInvalidation(self, .viewport_reanchor, self.owned_top_row, self.layout.rows);
    debug_trace.logf("frame_plan", "reanchor_top_runtime_frame_deferred owned_top={d} rows={d}", .{ self.owned_top_row, self.layout.rows });
}

fn recordViewportInvalidation(
    self: anytype,
    reason: render_engine.paint_plan.FrameInvalidationReason,
    top: u16,
    bottom: u16,
) void {
    if (top == 0 or bottom == 0 or bottom < top) return;
    const Shell = @TypeOf(self.*);
    if (comptime @hasDecl(Shell, "recordFrameInvalidation")) {
        self.recordFrameInvalidation(.{ .reason = reason, .top = top, .bottom = bottom }) catch |err| {
            debug_trace.logf(
                "frame_plan",
                "viewport_runtime_invalidation_drop reason={s} top={d} bottom={d} err={s}",
                .{ @tagName(reason), top, bottom, @errorName(err) },
            );
        };
    }
}

pub fn rowForEntryId(self: anytype, entry_id: u32) ?u16 {
    const selection = self.last_viewport_selection orelse ViewportSelection{
        .top_row = self.last_visible_transcript_top_row,
        .bottom_row = self.layout.content_bottom,
        .start_line = self.last_visible_transcript_start_line,
        .partial_skip_rows = self.last_visible_transcript_partial_skip_rows,
        .line_count = 0,
        .last_visible_row = self.last_visible_transcript_last_row,
        .last_visible_row_blank = self.last_visible_transcript_last_row_blank,
        .tail_kind = self.last_visible_transcript_tail_kind,
        .replaceable_start_row = self.replaceable_row,
        .split_active = self.last_visible_transcript_split_active,
        .split_prefix_lines = self.last_visible_transcript_split_prefix_lines,
        .split_suffix_start_line = self.last_visible_transcript_split_suffix_start_line,
    };
    return rowForEntryIdInSelection(
        self,
        std.heap.c_allocator,
        entry_id,
        selection,
    ) catch null;
}

pub fn rowForEntryIdInSelection(
    self: anytype,
    alloc: Allocator,
    entry_id: u32,
    selection: ViewportSelection,
) !?u16 {
    const entry_line = try transcript_blocks.renderedEntryStartLine(
        alloc,
        self.notebook.entries.items,
        entry_id,
        self.layout.cols,
        self.command_output_render.styles,
    ) orelse return null;
    return rowForLineIndex(.{
        .selection = selection,
        .bytes = self.notebook.transcript.items,
        .line_index = entry_line,
        .cols = self.layout.cols,
        .max_row = selection.bottom_row,
    });
}

pub fn transientAssistantGapRows(self: anytype) u16 {
    var index = self.notebook.entries.items.len;
    while (index > 0) {
        index -= 1;
        const entry = self.notebook.entries.items[index];
        if (!transcript_blocks.isEntryVisibleInCompactPresentation(entry)) continue;
        switch (entry) {
            .raw_bytes => |e| {
                if (trimBlockTail(e.bytes).len == 0) continue;
                const kind = blockKindForRawClass(e.class);
                if (kind == .tool_status) return default_block_gap_policy.default_gap_rows;
                return default_block_gap_policy.gapBetween(kind, .assistant_turn);
            },
            .user_turn => return default_block_gap_policy.gapBetween(.user_turn, .assistant_turn),
            .assistant_turn => |e| {
                if (e.segments.text.items.len == 0) continue;
                return default_block_gap_policy.default_gap_rows;
            },
            .assistant_table => return default_block_gap_policy.default_gap_rows,
            .assistant_code_block => return default_block_gap_policy.default_gap_rows,
            .assistant_thematic_rule => return default_block_gap_policy.default_gap_rows,
            .semantic_notice => |e| return default_block_gap_policy.gapBetween(
                transcript_blocks.blockKindForNoticeTone(e.tone),
                .assistant_turn,
            ),
        }
    }
    return 0;
}

pub fn needsIdleFooterBottomReservation(self: anytype) bool {
    if (self.pending_scroll_compact) return false;
    if (self.last_paint_bottom_reserved_rows > 0) return false;
    if (self.last_visible_transcript_last_row == 0) return false;
    if (self.last_visible_transcript_last_row_blank) return false;
    if (!idleFooterGapAppliesTo(self.last_visible_transcript_tail_kind)) return false;
    return self.last_visible_transcript_last_row >= self.layout.content_bottom;
}

pub fn idleFooterGapOffset(self: anytype) u16 {
    if (self.last_visible_transcript_last_row == 0) return 0;
    if (!idleFooterGapAppliesTo(self.last_visible_transcript_tail_kind)) return 0;
    return footerGapOffsetForVisibleTail(self);
}

pub fn bannerFooterGapOffset(self: anytype) u16 {
    if (self.last_visible_transcript_last_row == 0) return 0;
    if (self.last_visible_transcript_tail_kind != .tool_status and
        !idleFooterGapAppliesTo(self.last_visible_transcript_tail_kind))
    {
        return 0;
    }
    return footerGapOffsetForVisibleTail(self);
}

fn footerGapOffsetForVisibleTail(self: anytype) u16 {
    const base_top = self.footerTopRowForExtra(self.extra_input_rows);
    if (self.last_visible_transcript_last_row_blank) {
        return if (@as(u32, base_top) <= @as(u32, self.last_visible_transcript_last_row)) 1 else 0;
    }
    const adjacent_top: u32 = @as(u32, self.last_visible_transcript_last_row) + 1;
    return if (@as(u32, base_top) <= adjacent_top) 1 else 0;
}

pub fn preservedBottomReservationRows(self: anytype) u16 {
    if (self.last_paint_bottom_reserved_rows == 0) return 0;
    if (self.pending_scroll_compact) return 0;
    if (!idleFooterGapAppliesTo(compactTailVisibleBlockKind(self.notebook.entries.items))) return 0;
    return self.last_paint_bottom_reserved_rows;
}

pub fn footerTopRowForExtra(self: anytype, extra: u16) u16 {
    const max_top: u16 = if (@as(u32, self.layout.rows) > @as(u32, self.footer_reserved_base_rows) + extra)
        @intCast(@as(u32, self.layout.rows) - @as(u32, self.footer_reserved_base_rows) - extra)
    else
        1;
    const after_content: u16 = if (self.cursor_col > 1)
        @min(self.cursor_row +| 1, max_top)
    else
        self.cursor_row;
    return @min(after_content, max_top);
}

test "footer top row uses committed reserved base rows when present" {
    const layout = types.Layout{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    const Host = struct {
        layout: types.Layout,
        cursor_row: u16,
        cursor_col: u16,
        footer_reserved_base_rows: u16,
    };

    var tint_host = Host{
        .layout = layout,
        .cursor_row = 100,
        .cursor_col = 1,
        .footer_reserved_base_rows = 2,
    };
    try std.testing.expectEqual(@as(u16, 22), footerTopRowForExtra(tint_host, 0));

    tint_host.footer_reserved_base_rows = 3;
    try std.testing.expectEqual(@as(u16, 21), footerTopRowForExtra(tint_host, 0));
}
