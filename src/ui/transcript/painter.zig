// Host contract:
// - fields: shadow_vt, transcript, entries, layout, viewport_top_row,
//   owned_top_row, pending_scroll_compact,
//   min_visible_viewport_rows, reflow_clear_guard_rows,
//   viewport_clear_pending,
//   replaceable_last_line, replaceable_row, replaceable_start,
//   last_rendered_cols, last_paint_bottom_reserved_rows,
//   last_visible_transcript_*, last_viewport_selection,
//   paint_trace, has_painted_transcript, resize_bottom_anchor_pending,
//   footer_viewport, full_transcript, folded_command_blocks
// - methods: ensurePaintReservation, beginPaint, endPaint,
//   resetCursorTracking, advanceCursor,
//   compactAfterCollapsedResize, footerTopRowForExtra

const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const command_output_content = @import("../../core/tooling/command_output_content.zig");
const render_engine = @import("../render_engine.zig");
const source_preparation = @import("source_preparation.zig");
const transcript_release = @import("../../core/output/transcript_release.zig");
const transcript_writer = @import("writer.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;
const frame_surface = render_engine.frame_surface;
const paint_plan = render_engine.paint_plan;
const transcript_blocks = render_engine.transcript_blocks;
const viewport_selection = render_engine.viewport_selection;

const HardLineStarts = viewport_selection.HardLineStarts;
const LineRef = viewport_selection.LineRef;
const TranscriptBuffer = viewport_selection.TranscriptBuffer;
const TranscriptRef = viewport_selection.TranscriptRef;
const VisibleTranscriptLine = viewport_selection.VisibleTranscriptLine;
const VisibleTranscriptBatch = viewport_selection.VisibleTranscriptBatch;
const ViewportSelection = viewport_selection.ViewportSelection;
const buildHardLineStarts = viewport_selection.buildHardLineStarts;
const hardLineRefAt = viewport_selection.hardLineRefAt;
const selectedSourceLineIndex = viewport_selection.selectedSourceLineIndex;
const visibleFromTranscript = viewport_selection.visibleFromTranscript;
const buildViewportSelection = viewport_selection.buildViewportSelection;
const isVisuallyBlankLine = transcript_blocks.isVisuallyBlankLine;
const nextCursorColForLine = transcript_blocks.nextCursorColForLine;
const skipVisualRowsInLine = transcript_blocks.skipVisualRowsInLine;
const stripTrailingNewline = transcript_blocks.stripTrailingNewline;
const visualRowsForLine = transcript_blocks.visualRowsForLine;

const blank_transcript_row_bytes = "\x1b[2K";

const ResizeHistoryPolicy = enum {
    apply,
    skip,
};

fn rowForVisibleLineIndex(
    selection: ViewportSelection,
    line_visual_rows: []const u16,
    target_line: usize,
    max_row: u16,
) ?u16 {
    if (target_line >= line_visual_rows.len) return null;

    if (selection.split_active) {
        const prefix_lines = selection.split_prefix_lines;
        const suffix_start = selection.split_suffix_start_line;
        var row = selection.top_row;
        var line_index: usize = 0;
        const target_visible = if (target_line < prefix_lines)
            target_line
        else blk: {
            if (target_line < suffix_start) return null;
            while (line_index < prefix_lines) : (line_index += 1) {
                row +|= line_visual_rows[line_index];
            }
            line_index = suffix_start;
            break :blk target_line;
        };

        while (line_index < target_visible) : (line_index += 1) {
            row +|= line_visual_rows[line_index];
        }
        if (row > max_row) return null;
        return row;
    }

    if (target_line < selection.start_line) return null;

    var row = selection.top_row;
    var line_index = selection.start_line;
    var skip_rows = selection.partial_skip_rows;
    while (line_index < target_line) : (line_index += 1) {
        const rows = line_visual_rows[line_index];
        if (skip_rows >= rows) {
            skip_rows -= rows;
            continue;
        }
        row +|= rows - skip_rows;
        skip_rows = 0;
    }
    if (row > max_row) return null;
    return row;
}

const RenderedTranscriptRow = struct {
    row: u16,
    line_index: usize,
    bytes: []const u8,
    rows_painted: u16,
    partial_skip_rows: u16,
    folded: bool,
    blank: bool,
};

const RenderedTranscriptRows = struct {
    rows: std.ArrayList(RenderedTranscriptRow) = .empty,
    owned_bytes: std.ArrayList([]u8) = .empty,
    first_row: u16 = 0,
    last_visible_line: []const u8 = "",
    last_visible_row: u16 = 0,
    last_visible_row_blank: bool = false,
    last_line_is_folded: bool = false,
    replaceable_start_row: u16 = 0,
    replaceable_line_index: usize = 0,
    painted_rows: u16 = 0,

    fn deinit(self: *RenderedTranscriptRows, alloc: Allocator) void {
        for (self.owned_bytes.items) |bytes| alloc.free(bytes);
        self.owned_bytes.deinit(alloc);
        self.rows.deinit(alloc);
    }

    fn rememberOwnedBytes(self: *RenderedTranscriptRows, alloc: Allocator, bytes: []u8) ![]const u8 {
        errdefer alloc.free(bytes);
        try self.owned_bytes.append(alloc, bytes);
        return bytes;
    }
};

fn applyRenderedRowsToSelection(selection: *ViewportSelection, rendered_rows: *const RenderedTranscriptRows) void {
    selection.last_visible_row = rendered_rows.last_visible_row;
    selection.last_visible_row_blank = rendered_rows.last_visible_row_blank;
    selection.replaceable_start_row = rendered_rows.replaceable_start_row;
    if (rendered_rows.last_visible_row > 0) {
        selection.bottom_row = rendered_rows.last_visible_row;
    }
}

const ViewportCursorResult = struct {
    cursor_row: u16,
    cursor_col: u16,
    replaceable_row: u16,
};

const TranscriptPreparationSource = source_preparation.TranscriptPreparationSource;

pub const MeasuredHistoryEndpoint = struct {
    span_start_flow_offset: usize,
    flow_offset: usize,
    hard_row_cols: u16,
};

pub const MeasuredHistoryOrigin = struct {
    source_cols: u16,
    source_visual_offset: u32,
    endpoint: ?MeasuredHistoryEndpoint = null,
};

pub const MeasuredHistoryOriginProjection = struct {
    origin: MeasuredHistoryOrigin,
    current_cols: u16,
};

pub const MeasuredResizeTargetProvenance = enum {
    none,
    stable,
    recovering,
};

fn renderTranscriptRows(
    self: anytype,
    alloc: Allocator,
    batch: VisibleTranscriptBatch,
    line_visual_rows: []const u16,
    total_lines: usize,
    start_line: usize,
    partial_skip_rows: u16,
    top_row: u16,
    bottom_row: u16,
    max_visual_rows: ?u16,
    projection_resume_bytes: []const u8,
    projection_start_flow_offset: ?usize,
) !RenderedTranscriptRows {
    var rendered: RenderedTranscriptRows = .{
        .first_row = top_row,
        .replaceable_start_row = top_row,
        .replaceable_line_index = total_lines,
    };
    errdefer rendered.deinit(alloc);

    var current_row: u32 = top_row;
    var line_index: usize = start_line;
    var remaining_visual_rows = max_visual_rows;
    if (remaining_visual_rows == null and projection_start_flow_offset != null) {
        remaining_visual_rows = bottom_row - top_row + 1;
    }
    while (line_index < total_lines and
        current_row <= @as(u32, bottom_row) and
        (remaining_visual_rows == null or remaining_visual_rows.? > 0)) : (line_index += 1)
    {
        const vis = batch.lines[line_index];
        const is_partial_tail = line_index == start_line and partial_skip_rows > 0;
        const line_rows = line_visual_rows[line_index];
        std.debug.assert(!is_partial_tail or partial_skip_rows < line_rows);
        const exact_tail = if (line_index == start_line) switch (vis) {
            .transcript => |line| projectionTailFromFlowOffset(
                batch,
                line.ref.ref,
                projection_start_flow_offset,
            ),
            .folded_line => null,
        } else null;
        const available_rows: u16 = if (exact_tail) |tail|
            visualRowsForLine(tail, self.layout.cols)
        else if (is_partial_tail)
            line_rows - partial_skip_rows
        else
            line_rows;
        const rows_painted = if (remaining_visual_rows) |remaining|
            @min(available_rows, remaining)
        else
            available_rows;
        const projection_truncates_line = rows_painted < available_rows;
        const paint_row: u16 = @intCast(current_row);

        switch (vis) {
            .transcript => |line| {
                const text = batch.resolve(vis);
                const tail = exact_tail orelse
                    transcriptRowBytes(self, text, is_partial_tail, partial_skip_rows);
                const visible_bytes = if (projection_truncates_line)
                    tail[0..skipVisualRowsInLine(tail, self.layout.cols, rows_painted)]
                else
                    tail;
                const paint_bytes = if (visible_bytes.len == 0)
                    blank_transcript_row_bytes
                else if (isVisuallyBlankLine(visible_bytes)) blk: {
                    const materialized = try std.mem.concat(
                        alloc,
                        u8,
                        &.{ visible_bytes, blank_transcript_row_bytes },
                    );
                    break :blk try rendered.rememberOwnedBytes(alloc, materialized);
                } else visible_bytes;
                var emitted_bytes = paint_bytes;
                if (line_index == start_line and projection_resume_bytes.len > 0) {
                    const resumed = try alloc.alloc(
                        u8,
                        projection_resume_bytes.len + paint_bytes.len,
                    );
                    @memcpy(resumed[0..projection_resume_bytes.len], projection_resume_bytes);
                    @memcpy(resumed[projection_resume_bytes.len..], paint_bytes);
                    emitted_bytes = try rendered.rememberOwnedBytes(alloc, resumed);
                }
                const cursor_line = if (projection_truncates_line or exact_tail != null)
                    visible_bytes
                else
                    text;
                const blank = isVisuallyBlankLine(if (exact_tail != null)
                    cursor_line
                else
                    text);
                logRenderedTranscriptRow(paint_row, rows_painted, line_index, "transcript", if (is_partial_tail) partial_skip_rows else 0, text);
                try rendered.rows.append(alloc, .{
                    .row = paint_row,
                    .line_index = line_index,
                    .bytes = emitted_bytes,
                    .rows_painted = rows_painted,
                    .partial_skip_rows = if (is_partial_tail) partial_skip_rows else 0,
                    .folded = false,
                    .blank = blank,
                });
                if (self.replaceable_last_line and line.ref.ref.start <= self.replaceable_start) {
                    rendered.replaceable_line_index = line_index;
                }
                rendered.last_visible_line = cursor_line;
                rendered.last_line_is_folded = false;
                rendered.last_visible_row_blank = blank;
            },
            .folded_line => |folded| {
                var folded_bytes = try foldedLineBytes(alloc, folded.text, folded.stream);
                var folded_bytes_needs_free = true;
                errdefer if (folded_bytes_needs_free) alloc.free(folded_bytes);
                const rows_touched = visualRowsForLine(folded_bytes, self.layout.cols);
                if (rows_touched < rows_painted) {
                    const padded = try padAnsiBytesToRows(alloc, folded_bytes, rows_painted - rows_touched);
                    alloc.free(folded_bytes);
                    folded_bytes = padded;
                }
                folded_bytes_needs_free = false;
                const owned = try rendered.rememberOwnedBytes(alloc, folded_bytes);
                const tail = if (is_partial_tail)
                    foldedPartialTailBytes(self, owned, partial_skip_rows)
                else
                    owned;
                const bytes = if (projection_truncates_line)
                    tail[0..skipVisualRowsInLine(tail, self.layout.cols, rows_painted)]
                else
                    tail;
                logRenderedTranscriptRow(
                    paint_row,
                    rows_painted,
                    line_index,
                    if (folded.stream == .stderr) "folded_stderr" else "folded_stdout",
                    if (is_partial_tail) partial_skip_rows else 0,
                    folded.text,
                );
                try rendered.rows.append(alloc, .{
                    .row = paint_row,
                    .line_index = line_index,
                    .bytes = if (bytes.len == 0) blank_transcript_row_bytes else bytes,
                    .rows_painted = rows_painted,
                    .partial_skip_rows = if (is_partial_tail) partial_skip_rows else 0,
                    .folded = true,
                    .blank = false,
                });
                rendered.last_visible_line = if (projection_truncates_line) bytes else "";
                rendered.last_line_is_folded = !projection_truncates_line;
                rendered.last_visible_row_blank = false;
            },
        }

        if (line_index == rendered.replaceable_line_index) {
            rendered.replaceable_start_row = paint_row;
        }
        rendered.last_visible_row = @intCast(
            current_row + @as(u32, rows_painted) - 1,
        );
        rendered.painted_rows += rows_painted;
        current_row += @as(u32, rows_painted);
        if (remaining_visual_rows) |*remaining| remaining.* -= rows_painted;
    }

    return rendered;
}

fn projectionTailFromFlowOffset(
    batch: VisibleTranscriptBatch,
    line: LineRef,
    flow_offset: ?usize,
) ?[]const u8 {
    const offset = flow_offset orelse return null;
    const start: usize = line.start;
    const end = start + @as(usize, line.len);
    if (offset < start or offset > end) return null;
    return batch.transcript.bytes[offset..end];
}

fn transcriptRowBytes(self: anytype, text: []const u8, is_partial_tail: bool, partial_skip_rows: u16) []const u8 {
    if (!is_partial_tail or text.len == 0) return text;

    const offset = skipVisualRowsInLine(text, self.layout.cols, partial_skip_rows);
    const tail_bytes: usize = if (offset < text.len) text.len - offset else 0;
    debug_trace.logf(
        "transcript.sgr_drop_partial_tail",
        "active sgr before skip offset not walked, rows_skipped={d} cols={d} tail_bytes={d}",
        .{ partial_skip_rows, self.layout.cols, tail_bytes },
    );
    return if (offset < text.len) text[offset..] else "";
}

fn foldedPartialTailBytes(self: anytype, bytes: []const u8, partial_skip_rows: u16) []const u8 {
    if (partial_skip_rows == 0 or bytes.len == 0) return bytes;
    const offset = skipVisualRowsInLine(bytes, self.layout.cols, partial_skip_rows);
    return if (offset < bytes.len) bytes[offset..] else "";
}

fn foldedLineBytes(alloc: Allocator, text: []const u8, stream: command_output_content.Stream) ![]u8 {
    const style = if (stream == .stderr) "\x1b[38;5;252m" else "\x1b[38;5;245m";
    const trimmed = stripTrailingNewline(text);
    const reset = "\x1b[0m";
    const bytes = try alloc.alloc(u8, style.len + "│ ".len + trimmed.len + reset.len);
    var offset: usize = 0;
    @memcpy(bytes[offset .. offset + style.len], style);
    offset += style.len;
    @memcpy(bytes[offset .. offset + "│ ".len], "│ ");
    offset += "│ ".len;
    @memcpy(bytes[offset .. offset + trimmed.len], trimmed);
    offset += trimmed.len;
    @memcpy(bytes[offset .. offset + reset.len], reset);
    return bytes;
}

fn padAnsiBytesToRows(alloc: Allocator, bytes: []const u8, missing_rows: u16) ![]u8 {
    std.debug.assert(missing_rows > 0);
    return std.fmt.allocPrint(alloc, "{s}\x1b[{d}B\x1b[2K", .{ bytes, missing_rows });
}

fn logRenderedTranscriptRow(row: u16, rows_painted: u16, line_index: usize, kind_name: []const u8, partial_skip_rows: u16, text: []const u8) void {
    debug_trace.logf(
        "paint.rows",
        "transcript_line row={d} rows={d} line_index={d} kind={s} partial_skip={d} bytes={d} hash={x}",
        .{
            row,
            rows_painted,
            line_index,
            kind_name,
            partial_skip_rows,
            text.len,
            std.hash.Wyhash.hash(0, text),
        },
    );
}

fn calculateViewportCursor(
    layout: types.Layout,
    bottom_row: u16,
    total_lines: usize,
    start_line: usize,
    repl_line_idx: usize,
    replaceable_start_row: u16,
    last_visible_line: []const u8,
    last_visible_row: u16,
    last_line_is_folded: bool,
    top_row: u16,
    transcript_ends_with_newline: bool,
    replaceable_last_line: bool,
    current_replaceable_row: u16,
) ViewportCursorResult {
    _ = bottom_row;
    var cursor_row = top_row;
    var cursor_col: u16 = 1;
    var replaceable_row = current_replaceable_row;
    if (total_lines == 0) return .{ .cursor_row = cursor_row, .cursor_col = cursor_col, .replaceable_row = replaceable_row };

    const treat_last_row_as_terminated = last_line_is_folded or transcript_ends_with_newline;
    if (treat_last_row_as_terminated and last_visible_row < layout.content_bottom) {
        cursor_row = last_visible_row + 1;
        cursor_col = 1;
    } else {
        cursor_row = last_visible_row;
        cursor_col = nextCursorColForLine(last_visible_line, layout.cols);
    }
    if (cursor_row < 1) cursor_row = 1;
    if (cursor_col < 1) cursor_col = 1;
    if (replaceable_last_line) {
        replaceable_row = if (repl_line_idx < start_line or repl_line_idx >= total_lines) top_row else replaceable_start_row;
    }
    return .{ .cursor_row = cursor_row, .cursor_col = cursor_col, .replaceable_row = replaceable_row };
}

fn recordPreFrameTranscriptInvalidation(
    self: anytype,
    reason: paint_plan.FrameInvalidationReason,
    top: u16,
    bottom: u16,
) void {
    if (top == 0 or bottom == 0 or bottom < top) return;
    const Shell = @TypeOf(self.*);
    if (comptime !@hasDecl(Shell, "recordFrameInvalidation")) return;
    self.recordFrameInvalidation(.{ .reason = reason, .top = top, .bottom = bottom }) catch |err| {
        debug_trace.logf(
            "frame_plan",
            "pre_frame_transcript_invalidation_drop reason={s} top={d} bottom={d} err={s}",
            .{ @tagName(reason), top, bottom, @errorName(err) },
        );
    };
}

fn compactAfterCollapsedResize(self: anytype, metrics: *Metrics) !void {
    _ = metrics;
    if (!self.pending_scroll_compact) return;
    self.pending_scroll_compact = false;
    if (self.owned_top_row <= 1) return;

    const scroll_rows = self.owned_top_row - 1;
    debug_trace.logf("render", "viewport_scroll_compact rows={d} owned_top={d} layout={d}x{d}", .{ scroll_rows, self.owned_top_row, self.layout.cols, self.layout.rows });

    self.owned_top_row = 1;
    self.viewport_top_row = 1;
    self.cursor_row = 1;
    self.cursor_col = 1;
    recordPreFrameTranscriptInvalidation(self, .viewport_reanchor, 1, self.layout.rows);
    debug_trace.logf(
        "scroll",
        "viewport_scroll_compact_frame_deferred rows={d} layout={d}x{d}",
        .{ scroll_rows, self.layout.cols, self.layout.rows },
    );
}

fn visualOffsetForSelection(line_visual_rows: []const u16, selection: ViewportSelection) u32 {
    var offset: u32 = 0;
    const end = @min(selection.start_line, line_visual_rows.len);
    for (line_visual_rows[0..end]) |rows| offset += rows;
    return offset + selection.partial_skip_rows;
}

fn totalVisualRows(line_visual_rows: []const u16) u32 {
    var total: u32 = 0;
    for (line_visual_rows) |rows| total += rows;
    return total;
}

const VisualRowPosition = struct {
    line: usize,
    intra_line_rows: u16,
};

fn compareVisualOffset(target: u32, offset: u32) std.math.Order {
    return std.math.order(target, offset);
}

fn sourceStartPosition(
    prepared: *const PreparedTranscriptSurfacePaint,
    visual_offset: u32,
) ?VisualRowPosition {
    const offsets = prepared.source_visual_row_offsets;
    if (offsets.len == prepared.sourceVisualRows().len + 1 and offsets.len > 0) {
        if (visual_offset > offsets[offsets.len - 1]) return null;
        const line = std.sort.upperBound(
            u32,
            offsets,
            visual_offset,
            compareVisualOffset,
        ) - 1;
        return .{
            .line = line,
            .intra_line_rows = if (line < prepared.sourceVisualRows().len)
                @intCast(visual_offset - offsets[line])
            else
                0,
        };
    }

    var remaining = visual_offset;
    for (prepared.sourceVisualRows(), 0..) |rows, line| {
        if (remaining < rows) return .{ .line = line, .intra_line_rows = @intCast(remaining) };
        remaining -= rows;
    }
    if (remaining == 0) return .{ .line = prepared.sourceVisualRows().len, .intra_line_rows = 0 };
    return null;
}

fn sourceEndPosition(
    prepared: *const PreparedTranscriptSurfacePaint,
    visual_end: u32,
) ?VisualRowPosition {
    if (visual_end == 0) return .{ .line = 0, .intra_line_rows = 0 };
    const offsets = prepared.source_visual_row_offsets;
    if (offsets.len == prepared.sourceVisualRows().len + 1 and offsets.len > 1) {
        if (visual_end > offsets[offsets.len - 1]) return null;
        const line = std.sort.lowerBound(
            u32,
            offsets[1..],
            visual_end,
            compareVisualOffset,
        );
        return .{
            .line = line,
            .intra_line_rows = @intCast(visual_end - offsets[line]),
        };
    }

    var remaining = visual_end;
    for (prepared.sourceVisualRows(), 0..) |rows, line| {
        if (remaining <= rows) return .{ .line = line, .intra_line_rows = @intCast(remaining) };
        remaining -= rows;
    }
    return null;
}

const MeasuredSourceRow = struct {
    start: usize,
    end: usize,
    next: usize,
};

fn selectionFlowOffset(
    batch: VisibleTranscriptBatch,
    selection: ViewportSelection,
    cols: u16,
) ?usize {
    if (selection.split_active or selection.start_line > batch.lines.len) return null;
    if (selection.start_line == batch.lines.len) return batch.transcript.bytes.len;
    const line = switch (batch.lines[selection.start_line]) {
        .transcript => |value| value,
        .folded_line => return null,
    };
    const text = line.ref.resolve(batch.transcript);
    return @as(usize, line.ref.ref.start) +
        skipVisualRowsInLine(text, cols, selection.partial_skip_rows);
}

fn nextTranscriptLineOffset(
    batch: VisibleTranscriptBatch,
    line_index: usize,
    fallback: usize,
) ?usize {
    if (line_index + 1 >= batch.lines.len) return fallback;
    return switch (batch.lines[line_index + 1]) {
        .transcript => |line| line.ref.ref.start,
        .folded_line => null,
    };
}

fn collectMeasuredSourceRows(
    alloc: Allocator,
    batch: VisibleTranscriptBatch,
    hard_row_cols: u16,
    span_start: usize,
    span_end: usize,
) !?[]MeasuredSourceRow {
    if (hard_row_cols == 0 or span_start > span_end or span_end > batch.transcript.bytes.len) {
        return null;
    }

    var groups: std.ArrayList(MeasuredSourceRow) = .empty;
    defer groups.deinit(alloc);
    for (batch.lines, 0..) |visible, line_index| {
        const line = switch (visible) {
            .transcript => |value| value,
            .folded_line => return null,
        };
        const text = line.ref.resolve(batch.transcript);
        const line_start: usize = line.ref.ref.start;
        const rows = visualRowsForLine(text, hard_row_cols);
        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            const local_start = skipVisualRowsInLine(text, hard_row_cols, row);
            const local_end = skipVisualRowsInLine(text, hard_row_cols, row + 1);
            const group_start = line_start + local_start;
            const group_end = line_start + local_end;
            const group_next = if (row + 1 == rows)
                nextTranscriptLineOffset(batch, line_index, group_end) orelse
                    return null
            else
                group_end;

            if (group_next <= span_start) continue;
            if (group_start >= span_end) break;
            const effective_start = @max(group_start, span_start);
            const effective_end = @min(group_end, span_end);
            const effective_next = @min(group_next, span_end);
            if (effective_start > effective_end or effective_end > effective_next) return null;
            try groups.append(alloc, .{
                .start = effective_start,
                .end = effective_end,
                .next = effective_next,
            });
            if (effective_next == span_end) {
                return try groups.toOwnedSlice(alloc);
            }
        }
    }
    if (span_start == span_end) return try groups.toOwnedSlice(alloc);
    return null;
}

/// Finds the byte offset after `rows` visual rows. Shared endpoint logic keeps
/// forward and reverse projection walks inverse.
fn flowOffsetAfterMeasuredRows(
    batch: VisibleTranscriptBatch,
    groups: []const MeasuredSourceRow,
    target_cols: u16,
    span_start: usize,
    rows: u32,
) ?usize {
    var remaining = rows;
    var offset = span_start;
    for (groups) |group| {
        const bytes = batch.transcript.bytes[group.start..group.end];
        const group_rows = visualRowsForLine(bytes, target_cols);
        if (remaining < group_rows) {
            return group.start + skipVisualRowsInLine(
                bytes,
                target_cols,
                @intCast(remaining),
            );
        }
        remaining -= group_rows;
        offset = group.next;
        if (remaining == 0) break;
    }
    return if (remaining == 0) offset else null;
}

fn advanceMeasuredHistoryEndpoint(
    alloc: Allocator,
    batch: VisibleTranscriptBatch,
    selection: ViewportSelection,
    source_cols: u16,
    target_cols: u16,
    rows: u32,
) !?MeasuredHistoryEndpoint {
    const span_start = selectionFlowOffset(batch, selection, source_cols) orelse return null;
    return advanceMeasuredHistoryEndpointFromFlowOffset(
        alloc,
        batch,
        source_cols,
        target_cols,
        span_start,
        batch.transcript.bytes.len,
        rows,
    );
}

fn advanceMeasuredHistoryEndpointFromFlowOffset(
    alloc: Allocator,
    batch: VisibleTranscriptBatch,
    source_cols: u16,
    target_cols: u16,
    span_start: usize,
    span_end: usize,
    rows: u32,
) !?MeasuredHistoryEndpoint {
    const groups = (try collectMeasuredSourceRows(
        alloc,
        batch,
        source_cols,
        span_start,
        span_end,
    )) orelse return null;
    defer alloc.free(groups);

    const flow_offset = flowOffsetAfterMeasuredRows(
        batch,
        groups,
        target_cols,
        span_start,
        rows,
    ) orelse return null;
    return .{
        .span_start_flow_offset = span_start,
        .flow_offset = flow_offset,
        .hard_row_cols = source_cols,
    };
}

fn measuredHistoryFlowOffsetForVisualOffset(
    alloc: Allocator,
    batch: VisibleTranscriptBatch,
    source_cols: u16,
    visual_offset: u32,
) !?usize {
    const span_end = measuredHistorySourceSpanEnd(batch);
    const groups = (try collectMeasuredSourceRows(
        alloc,
        batch,
        source_cols,
        0,
        span_end,
    )) orelse return null;
    defer alloc.free(groups);

    const index: usize = @intCast(visual_offset);
    if (index > groups.len) return null;
    if (index == groups.len) return span_end;
    return groups[index].start;
}

fn measuredHistorySourceSpanEnd(batch: VisibleTranscriptBatch) usize {
    const bytes = batch.transcript.bytes;
    return if (bytes.len > 0 and bytes[bytes.len - 1] == '\n')
        bytes.len - 1
    else
        bytes.len;
}

fn advanceMeasuredHistoryVisualOffset(
    alloc: Allocator,
    batch: VisibleTranscriptBatch,
    source_cols: u16,
    target_cols: u16,
    visual_offset: u32,
    rows: u32,
) !?MeasuredHistoryEndpoint {
    const span_start = (try measuredHistoryFlowOffsetForVisualOffset(
        alloc,
        batch,
        source_cols,
        visual_offset,
    )) orelse return null;
    return advanceMeasuredHistoryEndpointFromFlowOffset(
        alloc,
        batch,
        source_cols,
        target_cols,
        span_start,
        measuredHistorySourceSpanEnd(batch),
        rows,
    );
}

fn rewindMeasuredHistoryEndpoint(
    alloc: Allocator,
    batch: VisibleTranscriptBatch,
    endpoint: MeasuredHistoryEndpoint,
    target_cols: u16,
    rows: u32,
) !?usize {
    const groups = (try collectMeasuredSourceRows(
        alloc,
        batch,
        endpoint.hard_row_cols,
        endpoint.span_start_flow_offset,
        endpoint.flow_offset,
    )) orelse return null;
    defer alloc.free(groups);

    var total: u32 = 0;
    for (groups) |group| {
        const bytes = batch.transcript.bytes[group.start..group.end];
        total += visualRowsForLine(bytes, target_cols);
    }
    if (rows > total) return null;
    return flowOffsetAfterMeasuredRows(
        batch,
        groups,
        target_cols,
        endpoint.span_start_flow_offset,
        total - rows,
    );
}

pub fn advanceMeasuredHistoryOriginForCommittedRows(
    flow: []const u8,
    origin: ?MeasuredHistoryOrigin,
    target_cols: u16,
    rows: u16,
) ?MeasuredHistoryOrigin {
    var advanced = origin orelse return null;
    if (rows == 0) return advanced;
    const endpoint = advanced.endpoint orelse return advanced;
    advanced.endpoint = if (advanceFlowOffset(
        flow,
        endpoint,
        target_cols,
        rows,
    )) |flow_offset|
        .{
            .span_start_flow_offset = endpoint.span_start_flow_offset,
            .flow_offset = flow_offset,
            .hard_row_cols = endpoint.hard_row_cols,
        }
    else
        null;
    return advanced;
}

fn advanceFlowOffset(
    flow: []const u8,
    endpoint: MeasuredHistoryEndpoint,
    cols: u16,
    rows: u16,
) ?usize {
    if (cols == 0 or endpoint.hard_row_cols == 0 or
        endpoint.span_start_flow_offset > endpoint.flow_offset or
        endpoint.flow_offset > flow.len)
    {
        return null;
    }

    var offset = endpoint.flow_offset;
    var remaining: u32 = rows;
    var line_start: usize = 0;
    while (line_start < flow.len and remaining > 0) {
        const newline = std.mem.findScalar(u8, flow[line_start..], '\n');
        const line_end = if (newline) |index| line_start + index else flow.len;
        const line = flow[line_start..line_end];
        const source_rows = visualRowsForLine(line, endpoint.hard_row_cols);

        var source_row: u16 = 0;
        while (source_row < source_rows and remaining > 0) : (source_row += 1) {
            const local_start =
                skipVisualRowsInLine(line, endpoint.hard_row_cols, source_row);
            const local_end =
                skipVisualRowsInLine(line, endpoint.hard_row_cols, source_row + 1);
            const group_start = line_start + local_start;
            const group_end = line_start + local_end;
            const group_next = if (source_row + 1 == source_rows and line_end < flow.len)
                line_end + 1
            else
                group_end;

            if (group_next <= endpoint.span_start_flow_offset or group_next <= offset) {
                continue;
            }
            const clipped_start = @max(group_start, endpoint.span_start_flow_offset);
            if (group_start == group_end) {
                if (offset <= clipped_start) {
                    remaining -= 1;
                    offset = group_next;
                }
                continue;
            }
            const segment_start = @max(clipped_start, offset);
            if (segment_start >= group_end) {
                offset = @max(offset, group_next);
                continue;
            }

            const segment = flow[segment_start..group_end];
            const segment_rows = visualRowsForLine(segment, cols);
            if (remaining < segment_rows) {
                offset = segment_start +
                    skipVisualRowsInLine(segment, cols, @intCast(remaining));
                remaining = 0;
                break;
            }
            remaining -= segment_rows;
            offset = group_next;
        }

        if (newline == null) break;
        line_start = line_end + 1;
    }
    return if (remaining == 0) offset else null;
}

fn visualOffsetForExactFlowOffset(
    batch: VisibleTranscriptBatch,
    line_visual_rows: []const u16,
    cols: u16,
    flow_offset: usize,
) ?u32 {
    const projection = visualProjectionForFlowOffset(
        batch,
        line_visual_rows,
        cols,
        flow_offset,
    ) orelse return null;
    return if (projection.exact) projection.visual_offset else null;
}

const FlowOffsetProjection = struct {
    visual_offset: u32,
    exact: bool,
};

fn visualProjectionForFlowOffset(
    batch: VisibleTranscriptBatch,
    line_visual_rows: []const u16,
    cols: u16,
    flow_offset: usize,
) ?FlowOffsetProjection {
    if (line_visual_rows.len != batch.lines.len) return null;

    var visual_offset: u32 = 0;
    for (batch.lines, line_visual_rows) |visible, line_rows| {
        const line = switch (visible) {
            .transcript => |value| value,
            .folded_line => return null,
        };
        const text = line.ref.resolve(batch.transcript);
        const line_start: usize = line.ref.ref.start;
        const line_end = line_start + text.len;
        if (text.len == 0 and flow_offset == line_start) {
            return .{
                .visual_offset = visual_offset,
                .exact = true,
            };
        }
        if (flow_offset >= line_start and flow_offset < line_end) {
            var row: u16 = 0;
            while (row < line_rows) : (row += 1) {
                const row_start =
                    line_start + skipVisualRowsInLine(text, cols, row);
                const row_end =
                    line_start + skipVisualRowsInLine(text, cols, row + 1);
                if (flow_offset < row_start) return null;
                if (flow_offset < row_end) {
                    return .{
                        .visual_offset = visual_offset + row,
                        .exact = flow_offset == row_start,
                    };
                }
            }
            return null;
        }
        if (flow_offset == line_end and line_end == batch.transcript.bytes.len) {
            return .{
                .visual_offset = visual_offset + line_rows,
                .exact = true,
            };
        }
        visual_offset += line_rows;
    }
    return if (flow_offset == batch.transcript.bytes.len)
        .{ .visual_offset = visual_offset, .exact = true }
    else
        null;
}

fn normalizeSplitSelection(
    selection: *ViewportSelection,
    line_visual_rows: []const u16,
) void {
    if (selection.split_active) {
        selection.start_line = selection.split_suffix_start_line;
        selection.partial_skip_rows = 0;
        selection.split_active = false;
        selection.split_prefix_lines = 0;
        selection.split_suffix_start_line = 0;
    }
    selection.line_count = line_visual_rows.len;
}

fn setSelectionVisualOffset(
    selection: *ViewportSelection,
    line_visual_rows: []const u16,
    target_offset: u32,
) void {
    normalizeSplitSelection(selection, line_visual_rows);
    var remaining = @min(target_offset, totalVisualRows(line_visual_rows));
    var line_index: usize = 0;
    while (line_index < line_visual_rows.len and remaining >= line_visual_rows[line_index]) : (line_index += 1) {
        remaining -= line_visual_rows[line_index];
    }
    selection.start_line = line_index;
    selection.partial_skip_rows = if (line_index < line_visual_rows.len)
        @intCast(remaining)
    else
        0;
}

fn applyResizeHistoryOffset(
    selection: *ViewportSelection,
    line_visual_rows: []const u16,
    target_offset: u32,
) bool {
    if (target_offset == 0 or line_visual_rows.len == 0) return false;
    normalizeSplitSelection(selection, line_visual_rows);
    const current_offset = visualOffsetForSelection(line_visual_rows, selection.*);
    const applied_offset = @max(current_offset, target_offset);
    if (applied_offset == current_offset) return false;
    setSelectionVisualOffset(selection, line_visual_rows, applied_offset);
    return true;
}

fn offsetBySignedRows(base: u32, delta: i32) u32 {
    if (delta >= 0) {
        return base +| @as(u32, @intCast(delta));
    }
    return base -| @as(u32, @intCast(-@as(i64, delta)));
}

fn preserveWelcomeReplayBoundary(
    target_offset: u32,
    row_delta: i32,
    welcome_boundary: ?transcript_blocks.LeadingWelcomeBoundary,
    line_visual_rows: []const u16,
) u32 {
    if (target_offset == 0 or row_delta == 0) return target_offset;
    const boundary = welcome_boundary orelse return target_offset;
    var welcome_offset: u32 = 0;
    for (line_visual_rows[0..@min(boundary.full_cut_line, line_visual_rows.len)]) |rows| {
        welcome_offset += rows;
    }
    if (target_offset >= welcome_offset) return target_offset;
    if (row_delta > 0) return welcome_offset;

    var tail_offset: u32 = 0;
    for (line_visual_rows[0..@min(boundary.tail_replay_line, line_visual_rows.len)]) |rows| {
        tail_offset += rows;
    }
    return tail_offset;
}

fn unusedRowsForSelection(
    line_visual_rows: []const u16,
    selection: ViewportSelection,
    visible_rows: u16,
) u16 {
    if (selection.start_line >= line_visual_rows.len) return visible_rows;
    var remaining = visible_rows;
    var line_index = selection.start_line;
    var skip_rows = selection.partial_skip_rows;
    while (line_index < line_visual_rows.len) : (line_index += 1) {
        const rows = line_visual_rows[line_index] -| skip_rows;
        skip_rows = 0;
        if (rows > remaining) return 0;
        remaining -= rows;
    }
    return remaining;
}

pub const PreparedTranscriptSurfacePaint = struct {
    bytes: []u8 = &.{},
    owns_bytes: bool = true,
    visible_lines: std.ArrayList(VisibleTranscriptLine) = .empty,
    line_visual_rows: std.ArrayList(u16) = .empty,
    line_provenance: std.ArrayList(transcript_blocks.LineProvenance) = .empty,
    source_visible_lines: []const VisibleTranscriptLine = &.{},
    source_line_visual_rows: []const u16 = &.{},
    source_line_provenance: []const transcript_blocks.LineProvenance = &.{},
    source_visual_row_offsets: []const u32 = &.{},
    selected_visible_lines: std.ArrayList(VisibleTranscriptLine) = .empty,
    selected_line_visual_rows: std.ArrayList(u16) = .empty,
    selected_line_provenance: std.ArrayList(transcript_blocks.LineProvenance) = .empty,
    row_provenance: std.ArrayList(transcript_blocks.RowProvenance) = .empty,
    use_selected: bool = false,
    selection: ViewportSelection,
    projection_area: render_engine.frame_layout.FrameRect = .empty(),
    projection_visual_rows: ?u16 = null,
    projection_ends_with_newline: ?bool = null,
    projection_cursor: ?ViewportCursorResult = null,
    projection_resume_bytes: []u8 = &.{},
    projection_resume_flow_offset: ?usize = null,
    projection_resume_cursor_col: u16 = 1,
    projection_resume_pending_wrap: bool = false,
    projection_start_flow_offset: ?usize = null,
    total_lines: usize = 0,
    transcript_ends_with_newline: bool = false,
    bottom_reserved_rows: u16 = 0,
    tracked_entry_id: ?u32 = null,
    tracked_entry_row: ?u16 = null,
    replaceable_last_line: bool = false,
    replaceable_start: usize = 0,
    replaceable_row: u16 = 1,
    trace_transcript_frame: bool = false,
    trace_visible_rows: u16 = 0,
    measured_history_origin: ?MeasuredHistoryOrigin = null,
    measured_history_origin_consumed: bool = false,
    measured_resize_target_provenance: MeasuredResizeTargetProvenance = .none,
    // Owned copy of the source's finality boundary candidates; the scroll
    // planner selects the release floor from these against frame-fresh
    // producer facts. Empty candidates mean the whole flow is final.
    finality_candidates: transcript_release.Candidates = .{},
    cursor: ViewportCursorResult = .{ .cursor_row = 1, .cursor_col = 1, .replaceable_row = 1 },

    pub fn deinit(self: *PreparedTranscriptSurfacePaint, alloc: Allocator) void {
        self.finality_candidates.deinit(alloc);
        if (self.owns_bytes and self.bytes.len > 0) alloc.free(self.bytes);
        self.visible_lines.deinit(alloc);
        self.line_visual_rows.deinit(alloc);
        self.line_provenance.deinit(alloc);
        self.selected_visible_lines.deinit(alloc);
        self.selected_line_visual_rows.deinit(alloc);
        self.selected_line_provenance.deinit(alloc);
        self.row_provenance.deinit(alloc);
        if (self.projection_resume_bytes.len > 0) {
            alloc.free(self.projection_resume_bytes);
        }
    }

    fn batch(self: *const PreparedTranscriptSurfacePaint) VisibleTranscriptBatch {
        return .{
            .transcript = .{ .bytes = self.bytes },
            .lines = if (self.use_selected) self.selected_visible_lines.items else self.sourceVisibleLines(),
        };
    }

    pub fn sourceVisibleLines(self: *const PreparedTranscriptSurfacePaint) []const VisibleTranscriptLine {
        return if (self.source_visible_lines.len > 0)
            self.source_visible_lines
        else
            self.visible_lines.items;
    }

    pub fn visualRows(self: *const PreparedTranscriptSurfacePaint) []const u16 {
        return if (self.use_selected) self.selected_line_visual_rows.items else self.sourceVisualRows();
    }

    pub fn sourceVisualRows(self: *const PreparedTranscriptSurfacePaint) []const u16 {
        return if (self.source_line_visual_rows.len > 0)
            self.source_line_visual_rows
        else
            self.line_visual_rows.items;
    }

    pub fn sourceTotalVisualRows(self: *const PreparedTranscriptSurfacePaint) u32 {
        if (self.source_visual_row_offsets.len > 0) {
            return self.source_visual_row_offsets[self.source_visual_row_offsets.len - 1];
        }
        return totalVisualRows(self.sourceVisualRows());
    }

    pub fn sourceVisualOffset(self: *const PreparedTranscriptSurfacePaint) u32 {
        return self.sourceVisualOffsetFor(self.selection);
    }

    fn sourceVisualOffsetFor(
        self: *const PreparedTranscriptSurfacePaint,
        selection: ViewportSelection,
    ) u32 {
        if (!selection.split_active and
            self.source_visual_row_offsets.len == self.sourceVisualRows().len + 1 and
            selection.start_line < self.source_visual_row_offsets.len)
        {
            return self.source_visual_row_offsets[selection.start_line] +
                selection.partial_skip_rows;
        }
        return visualOffsetForSelection(self.sourceVisualRows(), selection);
    }

    fn lineProvenance(self: *const PreparedTranscriptSurfacePaint) []const transcript_blocks.LineProvenance {
        return if (self.use_selected)
            self.selected_line_provenance.items
        else if (self.source_line_provenance.len > 0)
            self.source_line_provenance
        else
            self.line_provenance.items;
    }

    pub fn rowProvenance(self: *const PreparedTranscriptSurfacePaint, row: u16) ?transcript_blocks.LineProvenance {
        for (self.row_provenance.items) |item| {
            if (item.row == row) return item.source;
        }
        return null;
    }

    pub fn projectionArea(self: *const PreparedTranscriptSurfacePaint) render_engine.frame_layout.FrameRect {
        if (!self.projection_area.isEmpty()) return self.projection_area;
        if (self.selection.top_row == 0 or self.selection.bottom_row < self.selection.top_row) {
            return .empty();
        }
        return .{
            .top = self.selection.top_row,
            .bottom = self.selection.bottom_row,
        };
    }
};

pub fn previewTranscriptFlow(
    self: anytype,
    alloc: Allocator,
) !render_engine.frame_layout.TranscriptFlowPreview {
    var source = try source_preparation.prepareTranscriptSource(self, alloc, null);
    defer source.deinit(alloc);
    return source.preview;
}

pub fn prepareTranscriptSurfacePaint(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    bottom_reserved_rows: u16,
) !PreparedTranscriptSurfacePaint {
    return prepareTranscriptSurfacePaintWithOwnedSource(
        self,
        alloc,
        metrics,
        bottom_reserved_rows,
        null,
        null,
    );
}

pub fn prepareTranscriptSurfacePaintForArea(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    area: render_engine.frame_layout.FrameRect,
) !PreparedTranscriptSurfacePaint {
    return prepareTranscriptSurfacePaintWithOwnedSource(
        self,
        alloc,
        metrics,
        0,
        area,
        null,
    );
}

pub fn prepareTranscriptSurfacePaintForAreaTrackingEntry(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    area: render_engine.frame_layout.FrameRect,
    entry_id: ?u32,
) !PreparedTranscriptSurfacePaint {
    return prepareTranscriptSurfacePaintWithOwnedSource(
        self,
        alloc,
        metrics,
        0,
        area,
        entry_id,
    );
}

fn prepareTranscriptSurfacePaintWithOwnedSource(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    bottom_reserved_rows: u16,
    solved_area: ?render_engine.frame_layout.FrameRect,
    tracked_entry_id: ?u32,
) !PreparedTranscriptSurfacePaint {
    var source = try source_preparation.prepareTranscriptSource(
        self,
        alloc,
        tracked_entry_id,
    );
    defer source.deinit(alloc);

    var prepared = try prepareTranscriptSurfacePaintInternal(
        self,
        alloc,
        metrics,
        bottom_reserved_rows,
        solved_area,
        &source,
        true,
        false,
        .apply,
        null,
    );
    if (source.bytes.len > 0) {
        prepared.owns_bytes = true;
        source.bytes = &.{};
    }
    return prepared;
}

pub fn prepareTranscriptSurfacePaintFromSourceForArea(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    source: *const TranscriptPreparationSource,
    area: render_engine.frame_layout.FrameRect,
) !PreparedTranscriptSurfacePaint {
    return prepareTranscriptSurfacePaintInternal(
        self,
        alloc,
        metrics,
        0,
        area,
        source,
        false,
        false,
        .apply,
        null,
    );
}

pub fn preparePreselectedTranscriptSurfacePaintFromSourceForArea(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    source: *const TranscriptPreparationSource,
    area: render_engine.frame_layout.FrameRect,
) !PreparedTranscriptSurfacePaint {
    return prepareTranscriptSurfacePaintInternal(
        self,
        alloc,
        metrics,
        0,
        area,
        source,
        false,
        false,
        .skip,
        null,
    );
}

pub fn prepareTranscriptSurfacePaintFromSourceForFrame(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    source: *const TranscriptPreparationSource,
    area: render_engine.frame_layout.FrameRect,
    allow_projection_rebase: bool,
) !PreparedTranscriptSurfacePaint {
    return prepareTranscriptSurfacePaintInternal(
        self,
        alloc,
        metrics,
        0,
        area,
        source,
        false,
        allow_projection_rebase,
        .apply,
        null,
    );
}

pub fn prepareIndexedFullTranscriptSurfacePaintForArea(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    source: *const TranscriptPreparationSource,
    area: render_engine.frame_layout.FrameRect,
    visual_offset: u32,
) !PreparedTranscriptSurfacePaint {
    return prepareTranscriptSurfacePaintInternal(
        self,
        alloc,
        metrics,
        0,
        area,
        source,
        false,
        false,
        .skip,
        visual_offset,
    );
}

const MeasuredEndpointMapping = struct {
    visual_offset: ?u32 = null,
    start_flow_offset: ?usize = null,
    trace_status: []const u8,
};

fn mapMeasuredEndpointTarget(
    prepared: *PreparedTranscriptSurfacePaint,
    cols: u16,
    endpoint: MeasuredHistoryEndpoint,
) MeasuredEndpointMapping {
    prepared.measured_history_origin.?.endpoint = endpoint;
    const projection = visualProjectionForFlowOffset(
        prepared.batch(),
        prepared.sourceVisualRows(),
        cols,
        endpoint.flow_offset,
    ) orelse return .{ .trace_status = "mapping_inexact" };
    if (projection.exact) {
        return .{ .visual_offset = projection.visual_offset, .trace_status = "exact" };
    }
    return .{
        .visual_offset = projection.visual_offset,
        .start_flow_offset = endpoint.flow_offset,
        .trace_status = "containing_row",
    };
}

fn resolveResizeHistoryTarget(
    self: anytype,
    alloc: Allocator,
    prepared: *PreparedTranscriptSurfacePaint,
    transcript_bytes: []const u8,
    source: *const TranscriptPreparationSource,
    start_flow_offset: *?usize,
) !?u32 {
    if (comptime !@hasField(@TypeOf(self.*), "resize_history_row_delta")) return null;
    const row_delta = self.resize_history_row_delta orelse return null;

    var committed_offset: u32 = 0;
    var exact_measured_target: ?u32 = null;
    var origin_projection: ?MeasuredHistoryOriginProjection = null;
    if (comptime @hasDecl(@TypeOf(self.*), "measuredHistoryOriginForFlow")) {
        origin_projection = self.measuredHistoryOriginForFlow(transcript_bytes);
    }
    var trace_endpoint_status: []const u8 = "none";
    var trace_origin_action: []const u8 = "signed_fallback";
    var trace_source_cols: u16 = 0;
    var trace_current_cols: u16 = 0;
    var trace_source_visual_offset: u32 = 0;
    var recovery_accepted_visual_offset: ?u32 = null;
    var recovery_source_cols: u16 = 0;
    if (comptime @hasDecl(@TypeOf(self.*), "measuredResizeProjectionForFlow")) {
        if (self.measuredResizeProjectionForFlow(transcript_bytes)) |projection| {
            switch (projection) {
                .stable => {},
                .recovering => |recovering| {
                    recovery_accepted_visual_offset =
                        recovering.accepted_visual_offset;
                    recovery_source_cols = recovering.source_cols;
                },
            }
        }
    }
    if (comptime @hasDecl(@TypeOf(self.*), "stableTranscriptProjectionForFlow")) {
        if (self.stableTranscriptProjectionForFlow(transcript_bytes)) |stable| {
            prepared.measured_resize_target_provenance = .stable;
            if (!stable.selection.split_active) {
                committed_offset = prepared.sourceVisualOffsetFor(stable.selection);
            }
            if (row_delta > 0 and self.committed_frame_layout.terminal_cols > 0) {
                prepared.measured_history_origin = .{
                    .source_cols = self.committed_frame_layout.terminal_cols,
                    .source_visual_offset = stable.visual_offset,
                };
                if (!stable.selection.split_active) {
                    if (try advanceMeasuredHistoryEndpoint(
                        alloc,
                        prepared.batch(),
                        stable.selection,
                        self.committed_frame_layout.terminal_cols,
                        self.layout.cols,
                        @intCast(row_delta),
                    )) |endpoint| {
                        const mapping = mapMeasuredEndpointTarget(prepared, self.layout.cols, endpoint);
                        exact_measured_target = mapping.visual_offset;
                        if (mapping.start_flow_offset) |flow_offset| start_flow_offset.* = flow_offset;
                        trace_endpoint_status = mapping.trace_status;
                    } else {
                        trace_endpoint_status = "unavailable";
                    }
                } else {
                    trace_endpoint_status = "unavailable";
                }
                trace_origin_action = "retain";
                trace_source_cols = self.committed_frame_layout.terminal_cols;
                trace_current_cols = self.committed_frame_layout.terminal_cols;
                trace_source_visual_offset = stable.visual_offset;
            } else if (row_delta < 0) {
                prepared.measured_history_origin_consumed = true;
                trace_origin_action = "consume";
                if (stable.measured_history_origin) |origin| {
                    trace_source_cols = origin.source_cols;
                    trace_current_cols = self.committed_frame_layout.terminal_cols;
                    trace_source_visual_offset = origin.source_visual_offset;
                    trace_endpoint_status = if (origin.endpoint != null)
                        "exact"
                    else
                        "unavailable";
                    if (!stable.selection.split_active) {
                        if (origin.endpoint) |endpoint| {
                            const flow_offset = try rewindMeasuredHistoryEndpoint(
                                alloc,
                                prepared.batch(),
                                endpoint,
                                self.layout.cols,
                                @intCast(-@as(i64, row_delta)),
                            );
                            if (flow_offset) |exact_flow_offset| {
                                exact_measured_target = visualOffsetForExactFlowOffset(
                                    prepared.batch(),
                                    prepared.sourceVisualRows(),
                                    self.layout.cols,
                                    exact_flow_offset,
                                );
                            }
                        }
                    }
                }
            }
        }
    }
    if (recovery_accepted_visual_offset) |accepted_visual_offset| {
        trace_origin_action = "recovery_rebase";
        trace_source_cols = recovery_source_cols;
        trace_current_cols = recovery_source_cols;
        trace_source_visual_offset = accepted_visual_offset;

        if (row_delta > 0) {
            prepared.measured_history_origin = .{
                .source_cols = recovery_source_cols,
                .source_visual_offset = accepted_visual_offset,
            };
            if (try advanceMeasuredHistoryVisualOffset(
                alloc,
                prepared.batch(),
                recovery_source_cols,
                self.layout.cols,
                accepted_visual_offset,
                @intCast(row_delta),
            )) |endpoint| {
                const mapping = mapMeasuredEndpointTarget(prepared, self.layout.cols, endpoint);
                exact_measured_target = mapping.visual_offset;
                if (mapping.start_flow_offset) |flow_offset| start_flow_offset.* = flow_offset;
                trace_endpoint_status = mapping.trace_status;
            } else {
                trace_endpoint_status = "unavailable";
            }
        }

        if (exact_measured_target == null) {
            if (try measuredHistoryFlowOffsetForVisualOffset(
                alloc,
                prepared.batch(),
                recovery_source_cols,
                accepted_visual_offset,
            )) |flow_offset| {
                if (visualOffsetForExactFlowOffset(
                    prepared.batch(),
                    prepared.sourceVisualRows(),
                    self.layout.cols,
                    flow_offset,
                )) |mapped_offset| {
                    committed_offset = mapped_offset;
                    trace_endpoint_status = "base_exact";
                }
            }
        }
        if (exact_measured_target != null or committed_offset != 0 or
            accepted_visual_offset == 0)
        {
            prepared.measured_resize_target_provenance = .recovering;
        }
    }
    if (row_delta == 0) {
        if (origin_projection) |projection| {
            const origin = projection.origin;
            trace_source_cols = origin.source_cols;
            trace_current_cols = projection.current_cols;
            trace_source_visual_offset = origin.source_visual_offset;
            trace_endpoint_status = if (origin.endpoint != null)
                "exact"
            else
                "unavailable";
            if (self.layout.cols == origin.source_cols and
                self.layout.cols > projection.current_cols)
            {
                prepared.measured_history_origin_consumed = true;
                const total_visual_rows = prepared.sourceTotalVisualRows();
                if (origin.source_visual_offset <= total_visual_rows) {
                    trace_origin_action = "restore";
                    debug_trace.logf(
                        "resize",
                        "viewport_history_origin row_delta={d} endpoint={s} action={s} source_cols={d} current_cols={d} target_cols={d} source_visual_offset={d} committed_offset={d}",
                        .{
                            row_delta,
                            trace_endpoint_status,
                            trace_origin_action,
                            trace_source_cols,
                            trace_current_cols,
                            self.layout.cols,
                            trace_source_visual_offset,
                            committed_offset,
                        },
                    );
                    return origin.source_visual_offset;
                }
                trace_origin_action = "rebase";
                debug_trace.logf(
                    "resize",
                    "viewport_history_origin row_delta={d} endpoint={s} action={s} source_cols={d} current_cols={d} target_cols={d} source_visual_offset={d} total_visual_rows={d}",
                    .{
                        row_delta,
                        trace_endpoint_status,
                        trace_origin_action,
                        trace_source_cols,
                        trace_current_cols,
                        self.layout.cols,
                        trace_source_visual_offset,
                        total_visual_rows,
                    },
                );
                return null;
            }
        }
    }
    if (recovery_accepted_visual_offset != null and
        prepared.measured_resize_target_provenance != .recovering)
    {
        return null;
    }
    const measured_target = exact_measured_target orelse
        offsetBySignedRows(committed_offset, row_delta);
    debug_trace.logf(
        "resize",
        "viewport_history_origin row_delta={d} endpoint={s} action={s} source_cols={d} current_cols={d} target_cols={d} source_visual_offset={d} committed_offset={d}",
        .{
            row_delta,
            trace_endpoint_status,
            trace_origin_action,
            trace_source_cols,
            trace_current_cols,
            self.layout.cols,
            trace_source_visual_offset,
            committed_offset,
        },
    );
    return preserveWelcomeReplayBoundary(
        measured_target,
        row_delta,
        source.welcome_boundary,
        prepared.sourceVisualRows(),
    );
}

fn prepareTranscriptSurfacePaintInternal(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    bottom_reserved_rows: u16,
    solved_area: ?render_engine.frame_layout.FrameRect,
    source: *const TranscriptPreparationSource,
    commit_runtime_state: bool,
    allow_projection_rebase: bool,
    resize_history_policy: ResizeHistoryPolicy,
    forced_visual_offset: ?u32,
) !PreparedTranscriptSurfacePaint {
    if (commit_runtime_state) try self.ensurePaintReservation(alloc);

    const tracked_entry_id = source.tracked_entry_id;
    const tracked_entry_start_line = source.tracked_entry_start_line;
    const transcript_bytes = source.bytes;
    const effective_replaceable_last_line = source.replaceable_last_line;
    const effective_replaceable_start = source.replaceable_start;
    const effective_replaceable_row = source.replaceable_row;

    const initial_top = if (solved_area) |area|
        area.top
    else
        @max(if (self.viewport_top_row < 1) 1 else self.viewport_top_row, self.owned_top_row);
    const max_reserved = if (self.layout.content_bottom > 1) self.layout.content_bottom - 1 else 0;
    const reserved_bottom_rows = if (solved_area != null) 0 else @min(bottom_reserved_rows, max_reserved);
    const reserved_bottom: u16 = if (solved_area) |area|
        @min(area.bottom, self.layout.rows)
    else
        self.layout.content_bottom - reserved_bottom_rows;
    const initial_bottom: u16 = reserved_bottom;
    const empty_selection: ViewportSelection = .{
        .top_row = initial_top,
        .bottom_row = if (initial_bottom >= initial_top) initial_bottom else initial_top,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = 0,
        .last_visible_row = 0,
        .last_visible_row_blank = false,
        .tail_kind = null,
        .replaceable_start_row = effective_replaceable_row,
        .split_active = false,
        .split_prefix_lines = 0,
        .split_suffix_start_line = 0,
    };

    if (transcript_bytes.len == 0) {
        if (commit_runtime_state) self.last_paint_bottom_reserved_rows = 0;
        if (commit_runtime_state and solved_area == null) {
            self.last_visible_transcript_last_row = 0;
            self.last_visible_transcript_last_row_blank = false;
            self.last_visible_transcript_tail_kind = null;
            self.last_viewport_selection = null;
        }
        return .{
            .selection = empty_selection,
            .projection_area = if (initial_bottom >= initial_top)
                .{ .top = initial_top, .bottom = initial_bottom }
            else
                .empty(),
            .bottom_reserved_rows = reserved_bottom_rows,
            .tracked_entry_id = tracked_entry_id,
            .replaceable_last_line = effective_replaceable_last_line,
            .replaceable_start = effective_replaceable_start,
            .replaceable_row = effective_replaceable_row,
            .cursor = .{
                .cursor_row = empty_selection.top_row,
                .cursor_col = 1,
                .replaceable_row = effective_replaceable_row,
            },
        };
    }

    const paint_entry_len = if (commit_runtime_state) self.beginPaint() else 0;
    defer if (commit_runtime_state) self.endPaint(paint_entry_len);

    var prepared = PreparedTranscriptSurfacePaint{
        .bytes = @constCast(transcript_bytes),
        .owns_bytes = false,
        .selection = empty_selection,
        .bottom_reserved_rows = reserved_bottom_rows,
        .tracked_entry_id = tracked_entry_id,
        .replaceable_last_line = effective_replaceable_last_line,
        .replaceable_start = effective_replaceable_start,
        .replaceable_row = effective_replaceable_row,
        .cursor = .{
            .cursor_row = empty_selection.top_row,
            .cursor_col = 1,
            .replaceable_row = effective_replaceable_row,
        },
    };
    errdefer prepared.deinit(alloc);
    prepared.finality_candidates = try source.finality.clone(alloc);
    const transcript_buf = TranscriptBuffer{ .bytes = prepared.bytes };

    debug_trace.logf("render", "viewport_enter layout={d}x{d} content_bottom={d} viewport_top={d} cursor={d},{d} replaceable={{last={s} row={d} start={d}}} transcript_bytes={d} entries={d}", .{ self.layout.cols, self.layout.rows, self.layout.content_bottom, self.viewport_top_row, self.cursor_row, self.cursor_col, if (effective_replaceable_last_line) "true" else "false", effective_replaceable_row, effective_replaceable_start, prepared.bytes.len, self.entries.items.len });

    var owned_hard_lines: ?HardLineStarts = null;
    const hard_lines = if (source.hard_line_starts.len > 0)
        HardLineStarts{
            .starts = source.hard_line_starts,
            .ends_with_newline = source.hard_lines_end_with_newline,
        }
    else blk: {
        owned_hard_lines = try buildHardLineStarts(alloc, transcript_buf.bytes);
        break :blk owned_hard_lines.?;
    };
    defer if (owned_hard_lines) |lines| lines.deinit(alloc);

    var top_row: u16 = initial_top;
    if (solved_area == null) {
        if (commit_runtime_state) {
            self.last_paint_bottom_reserved_rows = reserved_bottom_rows;
        }
    }
    const bottom_row: u16 = initial_bottom;
    if (bottom_row < top_row) {
        if (commit_runtime_state) self.pending_scroll_compact = true;
        debug_trace.logf("render", "viewport_skip bottom={d} < top={d} (band collapsed)", .{ bottom_row, top_row });
        if (solved_area == null) {
            try compactAfterCollapsedResize(self, metrics);
            top_row = @max(if (self.viewport_top_row < 1) 1 else self.viewport_top_row, self.owned_top_row);
        }
        if (bottom_row < top_row) return prepared;
    }
    if (solved_area == null) {
        try compactAfterCollapsedResize(self, metrics);
        top_row = @max(if (self.viewport_top_row < 1) 1 else self.viewport_top_row, self.owned_top_row);
    }
    prepared.projection_area = .{ .top = top_row, .bottom = bottom_row };

    const transcript_line_count = hard_lines.len();
    // This count sizes the appendAssumeCapacity walk below, which expands
    // folded blocks only through a source snapshot's summary indices.
    const expand_folded_summaries = !commit_runtime_state or
        source.recorded_entries_authoritative;
    const total_lines = if (expand_folded_summaries)
        source_preparation.visibleTranscriptLineCountFromSource(
            self,
            transcript_line_count,
            source.folded_summary_indices,
        )
    else
        transcript_line_count;
    var visible_rows: u16 = bottom_row - top_row + 1;

    const capture_line_provenance = source.line_provenance.len > 0;
    var repl_line_idx: usize = total_lines;
    var tracked_visible_line: ?usize = null;
    const precomputed_plain_lines =
        !effective_replaceable_last_line and
        tracked_entry_start_line == null and
        total_lines == transcript_line_count and
        source.transcript_visible_lines.len == transcript_line_count and
        source.transcript_line_visual_rows.len == transcript_line_count and
        (!capture_line_provenance or source.line_provenance.len == transcript_line_count);
    if (precomputed_plain_lines) {
        prepared.source_visible_lines = source.transcript_visible_lines;
        prepared.source_line_visual_rows = source.transcript_line_visual_rows;
        prepared.source_line_provenance = source.line_provenance;
        prepared.source_visual_row_offsets = source.transcript_visual_row_offsets;
    } else {
        try prepared.visible_lines.ensureTotalCapacity(alloc, total_lines);
        try prepared.line_visual_rows.ensureTotalCapacity(alloc, total_lines);
        if (capture_line_provenance) {
            try prepared.line_provenance.ensureTotalCapacity(alloc, total_lines);
        }
        var transcript_index: usize = 0;
        while (transcript_index < transcript_line_count) : (transcript_index += 1) {
            if (tracked_entry_start_line == transcript_index) {
                tracked_visible_line = prepared.visible_lines.items.len;
            }
            const matched_block = if (expand_folded_summaries)
                source_preparation.foldedBlockAtTranscriptLine(
                    self,
                    source.folded_summary_indices,
                    transcript_index,
                )
            else
                null;

            if (matched_block) |block| {
                const effective_cols: u16 = if (self.layout.cols > 2) self.layout.cols - 2 else self.layout.cols;
                for (block.lines.items) |line| {
                    const trimmed = stripTrailingNewline(line.text);
                    prepared.visible_lines.appendAssumeCapacity(.{ .folded_line = .{ .text = line.text, .stream = line.stream } });
                    prepared.line_visual_rows.appendAssumeCapacity(visualRowsForLine(trimmed, effective_cols));
                    if (capture_line_provenance) {
                        prepared.line_provenance.appendAssumeCapacity(.{
                            .folded_command_output = .{
                                .entry_id = block.summary_entry_id,
                                .stream = line.stream,
                            },
                        });
                    }
                }
                continue;
            }

            const ref = hardLineRefAt(hard_lines, transcript_buf.bytes.len, transcript_index);
            const transcript_ref = TranscriptRef{ .ref = ref };
            const text = transcript_ref.resolve(transcript_buf);
            const vr = if (source.transcript_line_visual_rows.len == transcript_line_count)
                source.transcript_line_visual_rows[transcript_index]
            else
                visualRowsForLine(text, self.layout.cols);
            const visible_index = prepared.visible_lines.items.len;
            prepared.visible_lines.appendAssumeCapacity(visibleFromTranscript(ref));
            prepared.line_visual_rows.appendAssumeCapacity(vr);
            if (capture_line_provenance) {
                prepared.line_provenance.appendAssumeCapacity(
                    if (transcript_index < source.line_provenance.len)
                        source.line_provenance[transcript_index]
                    else
                        .unattributed,
                );
            }

            if (effective_replaceable_last_line and hard_lines.starts[transcript_index] <= effective_replaceable_start) {
                repl_line_idx = visible_index;
            }
        }
    }

    const selection_result = buildViewportSelection(.{
        .top_row = top_row,
        .bottom_row = bottom_row,
        .line_visual_rows = prepared.sourceVisualRows(),
        .visible_rows = visible_rows,
        .welcome_cut_line = source.welcome_cut_line,
        .replaceable_line_index = repl_line_idx,
        .tail_kind = source.tail_kind,
    });
    var viewport_selection_snapshot = selection_result.selection;
    var rows_budget = selection_result.rows_budget_unused;
    var welcome_decision = selection_result.welcome_decision;
    var measured_start_flow_offset: ?usize = null;
    const resize_history_target: ?u32 = if (resize_history_policy == .apply)
        try resolveResizeHistoryTarget(
            self,
            alloc,
            &prepared,
            transcript_bytes,
            source,
            &measured_start_flow_offset,
        )
    else
        null;
    if (resize_history_target) |target_offset| {
        if (applyResizeHistoryOffset(
            &viewport_selection_snapshot,
            prepared.sourceVisualRows(),
            target_offset,
        )) {
            rows_budget = unusedRowsForSelection(
                prepared.sourceVisualRows(),
                viewport_selection_snapshot,
                visible_rows,
            );
            welcome_decision = .none;
            const row_delta = self.resize_history_row_delta.?;
            debug_trace.logf(
                "resize",
                "viewport_history_prefix_omitted target_offset={d} row_delta={d} start_line={d} partial_skip_rows={d}",
                .{
                    target_offset,
                    row_delta,
                    viewport_selection_snapshot.start_line,
                    viewport_selection_snapshot.partial_skip_rows,
                },
            );
        }
    }
    if (measured_start_flow_offset) |flow_offset| {
        prepared.projection_start_flow_offset = flow_offset;
        try replacePreparedProjectionResumeBytesForFlowOffset(
            alloc,
            &prepared,
            self.layout.cols,
            flow_offset,
        );
    }
    if (comptime @hasDecl(@TypeOf(self.*), "stableTranscriptProjectionForFlow")) {
        if (!viewport_selection_snapshot.split_active and
            self.resize_history_row_delta == null and
            self.committed_frame_layout.terminal_cols == self.layout.cols)
        {
            if (self.stableTranscriptProjectionForFlow(transcript_bytes)) |stable| {
                const exact_history_reflow =
                    stable.flow_unchanged and
                    stable.measured_history_origin != null and
                    stable.visual_offset == stable.history_visual_offset;
                const settled_history_reflow =
                    stable.flow_unchanged and
                    stable.visual_offset == stable.history_visual_offset and
                    source.tail_kind != .assistant_turn;
                const resize_anchored_cancel_growth =
                    !stable.flow_unchanged and
                    self.resize_bottom_anchor_pending and
                    source.tail_kind == .cancel_notice;
                const repaint_required = self.render_requests.attemptHasInvalidations();
                const invalidation_allows_preservation =
                    !repaint_required or
                    settled_history_reflow;
                const next_offset = prepared.sourceVisualOffsetFor(viewport_selection_snapshot);
                if (allow_projection_rebase and
                    !stable.flow_unchanged and
                    self.committed_frame_layout.terminal_rows == self.layout.rows and
                    invalidation_allows_preservation and
                    next_offset < stable.history_visual_offset)
                {
                    setSelectionVisualOffset(
                        &viewport_selection_snapshot,
                        prepared.sourceVisualRows(),
                        stable.history_visual_offset,
                    );
                    rows_budget = unusedRowsForSelection(
                        prepared.sourceVisualRows(),
                        viewport_selection_snapshot,
                        visible_rows,
                    );
                    welcome_decision = .none;
                    debug_trace.logf(
                        "scroll",
                        "transcript_projection_history_floor source_offset={d} natural_offset={d}",
                        .{ stable.history_visual_offset, next_offset },
                    );
                }
                if (resize_anchored_cancel_growth and
                    rows_budget > 0 and
                    rows_budget < visible_rows)
                {
                    top_row += rows_budget;
                    visible_rows -= rows_budget;
                    prepared.projection_area.top = top_row;
                    viewport_selection_snapshot.top_row = top_row;
                }
                if (invalidation_allows_preservation and
                    (!allow_projection_rebase or
                        exact_history_reflow or
                        settled_history_reflow))
                {
                    const committed = stable.selection;
                    if (!committed.split_active and
                        committed.start_line < viewport_selection_snapshot.line_count and
                        next_offset < stable.visual_offset)
                    {
                        viewport_selection_snapshot.start_line = committed.start_line;
                        viewport_selection_snapshot.partial_skip_rows = committed.partial_skip_rows;
                        const stable_occupied_rows =
                            stable.occupied_last_row -| stable.selection.top_row +| 1;
                        const align_stable_cancel_to_bottom =
                            (repaint_required or stable.occupied_last_row == bottom_row) and
                            settled_history_reflow and
                            source.tail_kind == .cancel_notice and
                            stable_occupied_rows > 0 and
                            stable_occupied_rows < visible_rows;
                        if (align_stable_cancel_to_bottom) {
                            top_row = bottom_row - stable_occupied_rows + 1;
                            visible_rows = stable_occupied_rows;
                            prepared.projection_area.top = top_row;
                            viewport_selection_snapshot.top_row = top_row;
                        }
                        debug_trace.logf(
                            "scroll",
                            "transcript_projection_preserved source_offset={d} natural_offset={d} start_line={d} partial_skip_rows={d}",
                            .{
                                stable.visual_offset,
                                next_offset,
                                committed.start_line,
                                committed.partial_skip_rows,
                            },
                        );
                    }
                }
            }
        }
    }
    if (comptime @hasField(@TypeOf(self.*), "tail_viewport_request")) {
        if (self.tail_viewport_request) |request| {
            const resolution = viewport_selection.resolveTailOffset(.{
                .total_rows = prepared.sourceTotalVisualRows(),
                .visible_rows = visible_rows,
                .policy = request,
            });
            setSelectionVisualOffset(
                &viewport_selection_snapshot,
                prepared.sourceVisualRows(),
                resolution.start_visual_row,
            );
            rows_budget = unusedRowsForSelection(
                prepared.sourceVisualRows(),
                viewport_selection_snapshot,
                visible_rows,
            );
            welcome_decision = .none;
            self.tail_viewport_resolution = resolution;
        }
    }
    if (forced_visual_offset) |visual_offset| {
        const remaining_visual_rows = projectionRemainingVisualRows(
            &prepared,
            visual_offset,
        ) orelse return error.InvalidTranscriptTransition;
        const projection_rows = @min(
            remaining_visual_rows,
            @as(u32, visible_rows),
        );
        if (projection_rows == 0) return error.InvalidTranscriptTransition;
        const visual_end = visual_offset + projection_rows;
        const start = sourceStartPosition(&prepared, visual_offset) orelse
            return error.InvalidTranscriptTransition;
        const boundary = preparedProjectionBoundary(
            &prepared,
            self.layout.cols,
            visual_end,
        ) orelse return error.InvalidTranscriptTransition;
        try replacePreparedProjectionResumeBytes(
            alloc,
            &prepared,
            self.layout.cols,
            visual_offset,
        );
        prepared.projection_visual_rows = @intCast(projection_rows);
        prepared.projection_ends_with_newline = boundary.line_terminated;
        viewport_selection_snapshot.start_line = start.line;
        viewport_selection_snapshot.partial_skip_rows = start.intra_line_rows;
        viewport_selection_snapshot.line_count = prepared.sourceVisibleLines().len;
        viewport_selection_snapshot.last_visible_row = 0;
        viewport_selection_snapshot.last_visible_row_blank = false;
        viewport_selection_snapshot.replaceable_start_row = top_row;
        rows_budget = visible_rows - @as(u16, @intCast(projection_rows));
        welcome_decision = .none;
    }
    const start_line = viewport_selection_snapshot.start_line;
    const partial_skip_rows = viewport_selection_snapshot.partial_skip_rows;
    const render_total_lines = viewport_selection_snapshot.line_count;

    if (viewport_selection_snapshot.split_active) {
        try prepared.selected_visible_lines.ensureTotalCapacity(alloc, render_total_lines);
        try prepared.selected_line_visual_rows.ensureTotalCapacity(alloc, render_total_lines);
        if (capture_line_provenance) {
            try prepared.selected_line_provenance.ensureTotalCapacity(alloc, render_total_lines);
        }
        var selected_index: usize = 0;
        while (selected_index < render_total_lines) : (selected_index += 1) {
            const source_index = selectedSourceLineIndex(viewport_selection_snapshot, selected_index).?;
            prepared.selected_visible_lines.appendAssumeCapacity(prepared.sourceVisibleLines()[source_index]);
            prepared.selected_line_visual_rows.appendAssumeCapacity(prepared.sourceVisualRows()[source_index]);
            if (capture_line_provenance) {
                prepared.selected_line_provenance.appendAssumeCapacity(
                    prepared.lineProvenance()[source_index],
                );
            }
        }
        prepared.use_selected = true;
    }

    switch (welcome_decision) {
        .none => {},
        .pinned_welcome => debug_trace.logf(
            "render",
            "viewport_pin_welcome cut_line={d} suffix_start={d} total_lines={d} selected_lines={d} rows_budget_unused={d}",
            .{
                viewport_selection_snapshot.split_prefix_lines,
                viewport_selection_snapshot.split_suffix_start_line,
                selection_result.original_total_lines,
                render_total_lines,
                rows_budget,
            },
        ),
        .dropped_partial_welcome => debug_trace.logf(
            "render",
            "viewport_drop_partial_welcome start_line={d} cut_line={d} total_lines={d}",
            .{
                selection_result.natural_start_line,
                selection_result.welcome_cut_line.?,
                selection_result.original_total_lines,
            },
        ),
    }

    debug_trace.logf("render", "viewport_select start_line={d} total_lines={d} visible_rows={d} rows_budget_unused={d} partial_skip_rows={d}", .{ start_line, render_total_lines, visible_rows, rows_budget, partial_skip_rows });
    const trace_transcript_frame = !self.paint_trace.transcript_initialized or
        self.paint_trace.transcript_top != top_row or
        self.paint_trace.transcript_bottom != bottom_row or
        self.paint_trace.transcript_start_line != start_line or
        self.paint_trace.transcript_total_lines != render_total_lines or
        self.paint_trace.transcript_visible_rows != visible_rows or
        self.paint_trace.transcript_partial_skip_rows != partial_skip_rows or
        self.paint_trace.transcript_entries != self.entries.items.len;
    prepared.trace_transcript_frame = trace_transcript_frame;
    prepared.trace_visible_rows = visible_rows;
    if (commit_runtime_state) {
        self.paint_trace.transcript_initialized = true;
        self.paint_trace.transcript_top = top_row;
        self.paint_trace.transcript_bottom = bottom_row;
        self.paint_trace.transcript_start_line = start_line;
        self.paint_trace.transcript_total_lines = render_total_lines;
        self.paint_trace.transcript_visible_rows = visible_rows;
        self.paint_trace.transcript_partial_skip_rows = partial_skip_rows;
        self.paint_trace.transcript_entries = self.entries.items.len;
        self.paint_trace.transcript_log_frame = trace_transcript_frame;
    }
    if (trace_transcript_frame) {
        debug_trace.logf(
            "paint",
            "transcript_select top={d} bottom={d} start_line={d} total_lines={d} visible_rows={d} partial_skip_rows={d} rows_budget_unused={d} hard_lines={d} entries={d} bytes={d}",
            .{
                top_row,
                bottom_row,
                start_line,
                render_total_lines,
                visible_rows,
                partial_skip_rows,
                rows_budget,
                transcript_line_count,
                self.entries.items.len,
                transcript_buf.bytes.len,
            },
        );
    }

    if (commit_runtime_state and solved_area == null) {
        self.last_visible_transcript_top_row = top_row;
        self.last_visible_transcript_start_line = start_line;
        self.last_visible_transcript_partial_skip_rows = partial_skip_rows;
        self.last_visible_transcript_split_active = viewport_selection_snapshot.split_active;
        self.last_visible_transcript_split_prefix_lines = viewport_selection_snapshot.split_prefix_lines;
        self.last_visible_transcript_split_suffix_start_line = viewport_selection_snapshot.split_suffix_start_line;
        self.last_visible_transcript_tail_kind = viewport_selection_snapshot.tail_kind;
        self.resetCursorTracking();
        self.cursor_row = top_row;
    }

    prepared.selection = viewport_selection_snapshot;
    prepared.total_lines = render_total_lines;
    prepared.transcript_ends_with_newline = hard_lines.ends_with_newline;
    const render_context = .{
        .layout = self.layout,
        .replaceable_last_line = effective_replaceable_last_line,
        .replaceable_start = effective_replaceable_start,
        .replaceable_row = effective_replaceable_row,
    };
    if (commit_runtime_state) {
        if (solved_area == null) {
            try refreshPreparedTranscriptState(self, alloc, &prepared, true);
        } else {
            try refreshPreparedTranscriptState(self, alloc, &prepared, false);
        }
    } else {
        try refreshPreparedTranscriptState(&render_context, alloc, &prepared, false);
    }
    if (tracked_visible_line) |line_index| {
        prepared.tracked_entry_row = rowForVisibleLineIndex(
            prepared.selection,
            prepared.sourceVisualRows(),
            line_index,
            prepared.selection.bottom_row,
        );
    }
    return prepared;
}

fn refreshPreparedTranscriptState(
    self: anytype,
    alloc: Allocator,
    prepared: *PreparedTranscriptSurfacePaint,
    comptime commit_runtime_state: bool,
) !void {
    if (prepared.total_lines == 0) return;

    const viewport = prepared.selection;
    var rendered_rows = try renderTranscriptRows(
        self,
        alloc,
        prepared.batch(),
        prepared.visualRows(),
        prepared.total_lines,
        viewport.start_line,
        viewport.partial_skip_rows,
        viewport.top_row,
        viewport.bottom_row,
        prepared.projection_visual_rows,
        prepared.projection_resume_bytes,
        prepared.projection_start_flow_offset,
    );
    defer rendered_rows.deinit(alloc);

    applyRenderedRowsToSelection(&prepared.selection, &rendered_rows);
    try updatePreparedRowProvenance(alloc, prepared, &rendered_rows);
    prepared.cursor = calculateViewportCursor(
        self.layout,
        viewport.bottom_row,
        prepared.total_lines,
        viewport.start_line,
        rendered_rows.replaceable_line_index,
        rendered_rows.replaceable_start_row,
        rendered_rows.last_visible_line,
        rendered_rows.last_visible_row,
        rendered_rows.last_line_is_folded,
        viewport.top_row,
        prepared.projection_ends_with_newline orelse
            prepared.transcript_ends_with_newline,
        self.replaceable_last_line,
        self.replaceable_row,
    );

    if (commit_runtime_state) {
        self.last_visible_transcript_last_row = rendered_rows.last_visible_row;
        self.last_visible_transcript_last_row_blank = rendered_rows.last_visible_row_blank;
        self.last_viewport_selection = prepared.selection;
        self.cursor_row = prepared.cursor.cursor_row;
        self.cursor_col = prepared.cursor.cursor_col;
        if (self.replaceable_last_line) self.replaceable_row = prepared.cursor.replaceable_row;
    }
    debug_trace.logf(
        "render",
        "viewport_prepared cursor={d},{d} last_visible_row={d} replaceable_row={d} reserved_rows={d}",
        .{ prepared.cursor.cursor_row, prepared.cursor.cursor_col, rendered_rows.last_visible_row, prepared.cursor.replaceable_row, prepared.bottom_reserved_rows },
    );
}

fn updatePreparedRowProvenance(
    alloc: Allocator,
    prepared: *PreparedTranscriptSurfacePaint,
    rendered_rows: *const RenderedTranscriptRows,
) !void {
    prepared.row_provenance.clearRetainingCapacity();
    const line_provenance = prepared.lineProvenance();
    if (line_provenance.len == 0) return;

    for (rendered_rows.rows.items) |rendered| {
        const source = if (rendered.line_index < line_provenance.len)
            line_provenance[rendered.line_index]
        else
            .unattributed;
        var offset: u16 = 0;
        while (offset < rendered.rows_painted) : (offset += 1) {
            try prepared.row_provenance.append(alloc, .{
                .row = rendered.row + offset,
                .source = source,
            });
        }
    }
}

pub fn reprojectPreparedTranscriptForVisualOffset(
    alloc: Allocator,
    layout: types.Layout,
    prepared: *PreparedTranscriptSurfacePaint,
    area: render_engine.frame_layout.FrameRect,
    visual_offset: u32,
) !void {
    if (prepared.selection.split_active or
        prepared.use_selected or
        area.isEmpty() or
        area.top == 0 or
        area.bottom > layout.content_bottom)
    {
        return error.InvalidTranscriptTransition;
    }

    prepared.projection_visual_rows = null;
    prepared.projection_ends_with_newline = null;
    prepared.projection_cursor = null;
    try replacePreparedProjectionResumeBytes(
        alloc,
        prepared,
        layout.cols,
        visual_offset,
    );
    const remaining_visual_rows =
        projectionRemainingVisualRows(prepared, visual_offset) orelse
        return error.InvalidTranscriptTransition;
    if (remaining_visual_rows > area.height()) {
        return error.InvalidTranscriptTransition;
    }

    const start = sourceStartPosition(prepared, visual_offset) orelse
        return error.InvalidTranscriptTransition;

    prepared.selection.top_row = area.top;
    prepared.selection.bottom_row = area.bottom;
    prepared.selection.start_line = start.line;
    prepared.selection.partial_skip_rows = start.intra_line_rows;
    prepared.selection.last_visible_row = 0;
    prepared.selection.last_visible_row_blank = false;
    prepared.selection.replaceable_start_row = area.top;

    if (prepared.total_lines == 0) {
        if (visual_offset != 0) return error.InvalidTranscriptTransition;
        prepared.cursor = .{
            .cursor_row = area.top,
            .cursor_col = 1,
            .replaceable_row = prepared.replaceable_row,
        };
        return;
    }

    const render_context = .{
        .layout = layout,
        .replaceable_last_line = prepared.replaceable_last_line,
        .replaceable_start = prepared.replaceable_start,
        .replaceable_row = prepared.replaceable_row,
    };
    try refreshPreparedTranscriptState(
        &render_context,
        alloc,
        prepared,
        false,
    );
    if (prepared.selection.last_visible_row > area.bottom) {
        return error.InvalidTranscriptTransition;
    }
}

pub const PreparedTranscriptProjection = struct {
    flow_end: ?usize,
};

pub fn preparedTranscriptStagedFlowEndExactness(
    prepared: *const PreparedTranscriptSurfacePaint,
    cols: u16,
    area: render_engine.frame_layout.FrameRect,
    visual_offset: u32,
) ?bool {
    if (prepared.selection.split_active or
        prepared.use_selected or
        area.isEmpty() or
        area.top == 0)
    {
        return null;
    }
    const remaining_visual_rows =
        projectionRemainingVisualRows(prepared, visual_offset) orelse return null;
    const projection_rows = @min(
        remaining_visual_rows,
        @as(u32, area.height()),
    );
    if (projection_rows == 0) return null;
    const boundary = preparedProjectionBoundary(
        prepared,
        cols,
        visual_offset + projection_rows,
    ) orelse return null;
    return boundary.flow_end != null;
}

pub fn preparedTranscriptFlowOffsetForVisualOffset(
    prepared: *const PreparedTranscriptSurfacePaint,
    cols: u16,
    visual_offset: u32,
) ?usize {
    const boundary = preparedProjectionBoundary(
        prepared,
        cols,
        visual_offset,
    ) orelse return null;
    return boundary.flow_end;
}

pub fn stagePreparedTranscriptForVisualOffset(
    alloc: Allocator,
    layout: types.Layout,
    prepared: *PreparedTranscriptSurfacePaint,
    area: render_engine.frame_layout.FrameRect,
    visual_offset: u32,
) !PreparedTranscriptProjection {
    if (prepared.selection.split_active or
        prepared.use_selected or
        area.isEmpty() or
        area.top == 0 or
        area.bottom > layout.content_bottom)
    {
        return error.InvalidTranscriptTransition;
    }

    const remaining_visual_rows =
        projectionRemainingVisualRows(prepared, visual_offset) orelse
        return error.InvalidTranscriptTransition;
    const projection_rows = @min(
        remaining_visual_rows,
        @as(u32, area.height()),
    );
    if (projection_rows == 0) return error.InvalidTranscriptTransition;
    const visual_end = visual_offset + projection_rows;

    const start = sourceStartPosition(prepared, visual_offset) orelse
        return error.InvalidTranscriptTransition;
    if (start.line == prepared.sourceVisualRows().len) {
        return error.InvalidTranscriptTransition;
    }

    const boundary = preparedProjectionBoundary(prepared, layout.cols, visual_end) orelse
        return error.InvalidTranscriptTransition;
    try replacePreparedProjectionResumeBytes(
        alloc,
        prepared,
        layout.cols,
        visual_offset,
    );
    prepared.projection_area = area;
    prepared.projection_visual_rows = @intCast(projection_rows);
    prepared.projection_ends_with_newline = boundary.line_terminated;
    prepared.projection_cursor = null;
    prepared.selection.top_row = area.top;
    prepared.selection.bottom_row = area.bottom;
    prepared.selection.start_line = start.line;
    prepared.selection.partial_skip_rows = start.intra_line_rows;
    prepared.selection.line_count = prepared.sourceVisibleLines().len;
    prepared.selection.last_visible_row = 0;
    prepared.selection.last_visible_row_blank = false;
    prepared.selection.replaceable_start_row = area.top;

    const render_context = .{
        .layout = layout,
        .replaceable_last_line = prepared.replaceable_last_line,
        .replaceable_start = prepared.replaceable_start,
        .replaceable_row = prepared.replaceable_row,
    };
    try refreshPreparedTranscriptState(
        &render_context,
        alloc,
        prepared,
        false,
    );
    if (prepared.selection.last_visible_row > area.bottom) {
        return error.InvalidTranscriptTransition;
    }
    if (remaining_visual_rows > projection_rows and
        prepared.selection.last_visible_row < layout.rows)
    {
        prepared.cursor = .{
            .cursor_row = prepared.selection.last_visible_row + 1,
            .cursor_col = 1,
            .replaceable_row = prepared.cursor.replaceable_row,
        };
        prepared.projection_cursor = prepared.cursor;
    }
    return .{
        .flow_end = boundary.flow_end,
    };
}

const PreparedProjectionBoundary = struct {
    flow_end: ?usize,
    line_terminated: bool,
};

const PreparedControlBoundary = struct {
    resume_bytes: []u8 = &.{},
    steady_bytes: []u8 = &.{},
    cursor_col: u16 = 1,
    pending_wrap: bool = false,

    fn deinit(self: *PreparedControlBoundary, alloc: Allocator) void {
        if (self.resume_bytes.len > 0) alloc.free(self.resume_bytes);
        if (self.steady_bytes.len > 0) alloc.free(self.steady_bytes);
    }
};

fn prepareControlBoundary(
    alloc: Allocator,
    bytes: []const u8,
    cols: u16,
    raw_offset: usize,
) !PreparedControlBoundary {
    if (raw_offset > bytes.len) return error.InvalidTranscriptTransition;

    var state = try vt_emulator.Grid.init(alloc, cols, 1);
    defer state.deinit();
    state.defer_sync_updates = false;
    try state.feed(bytes[0..raw_offset]);
    if (!state.atControlSequenceBoundary()) {
        return error.InvalidTranscriptTransition;
    }

    return captureControlBoundary(alloc, &state);
}

fn captureControlBoundary(
    alloc: Allocator,
    state: *const vt_emulator.Grid,
) !PreparedControlBoundary {
    var resume_writer: std.Io.Writer.Allocating = .init(alloc);
    defer resume_writer.deinit();
    try state.writePresentationResume(&resume_writer.writer);

    var steady_writer: std.Io.Writer.Allocating = .init(alloc);
    defer steady_writer.deinit();
    try state.writePresentationSteady(&steady_writer.writer);

    var result = PreparedControlBoundary{
        .cursor_col = state.cursor_col,
        .pending_wrap = state.pending_wrap,
    };
    errdefer result.deinit(alloc);
    if (resume_writer.written().len > 0) {
        result.resume_bytes = try resume_writer.toOwnedSlice();
    }
    if (steady_writer.written().len > 0) {
        result.steady_bytes = try steady_writer.toOwnedSlice();
    }
    return result;
}

pub const TranscriptDocumentControlCursor = struct {
    state: vt_emulator.Grid,
    bytes: []const u8,
    raw_offset: usize = 0,

    pub fn init(
        alloc: Allocator,
        bytes: []const u8,
        cols: u16,
    ) !TranscriptDocumentControlCursor {
        var state = try vt_emulator.Grid.init(alloc, cols, 1);
        state.defer_sync_updates = false;
        return .{
            .state = state,
            .bytes = bytes,
        };
    }

    pub fn deinit(self: *TranscriptDocumentControlCursor) void {
        self.state.deinit();
        self.* = undefined;
    }

    pub fn prepareAppendBytes(
        self: *TranscriptDocumentControlCursor,
        alloc: Allocator,
        raw_start: usize,
        raw_end: usize,
        close_endpoint: bool,
    ) ![]u8 {
        if (raw_start < self.raw_offset or raw_start > raw_end or raw_end > self.bytes.len) {
            return error.InvalidTranscriptTransition;
        }

        try self.state.feed(self.bytes[self.raw_offset..raw_start]);
        if (!self.state.atControlSequenceBoundary()) {
            return error.InvalidTranscriptTransition;
        }
        var start = try captureControlBoundary(alloc, &self.state);
        defer start.deinit(alloc);

        try self.state.feed(self.bytes[raw_start..raw_end]);
        self.raw_offset = raw_end;
        if (!self.state.atControlSequenceBoundary()) {
            return error.InvalidTranscriptTransition;
        }
        var end = if (close_endpoint)
            try captureControlBoundary(alloc, &self.state)
        else
            PreparedControlBoundary{};
        defer end.deinit(alloc);

        return assembleTranscriptDocumentAppendBytes(
            alloc,
            self.bytes[raw_start..raw_end],
            start,
            end,
        );
    }
};

fn assembleTranscriptDocumentAppendBytes(
    alloc: Allocator,
    raw_bytes: []const u8,
    start: PreparedControlBoundary,
    end: PreparedControlBoundary,
) ![]u8 {
    if (start.resume_bytes.len == 0 and
        end.steady_bytes.len == 0 and
        std.mem.findScalar(u8, raw_bytes, '\n') == null)
    {
        return &.{};
    }

    const parts = [_][]const u8{
        start.resume_bytes,
        raw_bytes,
        end.steady_bytes,
    };
    var extra_carriage_returns: usize = 0;
    var previous_was_carriage_return = false;
    for (parts) |part| {
        for (part) |byte| {
            if (byte == '\n' and !previous_was_carriage_return) {
                extra_carriage_returns += 1;
            }
            previous_was_carriage_return = byte == '\r';
        }
    }
    const result = try alloc.alloc(
        u8,
        start.resume_bytes.len + raw_bytes.len + end.steady_bytes.len +
            extra_carriage_returns,
    );
    var offset: usize = 0;
    previous_was_carriage_return = false;
    for (parts) |part| {
        for (part) |byte| {
            if (byte == '\n' and !previous_was_carriage_return) {
                result[offset] = '\r';
                offset += 1;
            }
            result[offset] = byte;
            offset += 1;
            previous_was_carriage_return = byte == '\r';
        }
    }
    return result;
}

fn replacePreparedProjectionResumeBytes(
    alloc: Allocator,
    prepared: *PreparedTranscriptSurfacePaint,
    cols: u16,
    visual_offset: u32,
) !void {
    const boundary = preparedProjectionBoundary(prepared, cols, visual_offset) orelse
        return error.InvalidTranscriptTransition;
    try replacePreparedProjectionResumeBytesForFlowOffset(
        alloc,
        prepared,
        cols,
        boundary.flow_end,
    );
}

fn replacePreparedProjectionResumeBytesForFlowOffset(
    alloc: Allocator,
    prepared: *PreparedTranscriptSurfacePaint,
    cols: u16,
    flow_offset: ?usize,
) !void {
    if (flow_offset) |offset| {
        if (prepared.projection_resume_flow_offset) |base_offset| {
            if (offset >= base_offset) {
                if (offset == base_offset) return;
                var advanced = try prepareResumeDocumentAppend(
                    alloc,
                    prepared.bytes,
                    cols,
                    base_offset,
                    offset,
                    false,
                    .{
                        .resume_bytes = prepared.projection_resume_bytes,
                        .cursor_col = prepared.projection_resume_cursor_col,
                        .pending_wrap = prepared.projection_resume_pending_wrap,
                    },
                    false,
                );
                defer advanced.deinit(alloc);
                if (prepared.projection_resume_bytes.len > 0) {
                    alloc.free(prepared.projection_resume_bytes);
                }
                prepared.projection_resume_bytes = advanced.endpoint_resume_bytes;
                advanced.endpoint_resume_bytes = &.{};
                prepared.projection_resume_flow_offset = offset;
                prepared.projection_resume_cursor_col = advanced.endpoint_cursor_col;
                prepared.projection_resume_pending_wrap = advanced.endpoint_pending_wrap;
                return;
            }
        }
    }

    var control = if (flow_offset) |offset|
        try prepareControlBoundary(alloc, prepared.bytes, cols, offset)
    else
        PreparedControlBoundary{};
    defer control.deinit(alloc);

    const resume_bytes = control.resume_bytes;
    control.resume_bytes = &.{};
    if (prepared.projection_resume_bytes.len > 0) {
        alloc.free(prepared.projection_resume_bytes);
    }
    prepared.projection_resume_bytes = resume_bytes;
    prepared.projection_resume_flow_offset = null;
    prepared.projection_resume_cursor_col = 1;
    prepared.projection_resume_pending_wrap = false;
}

pub const PresentationBoundary = struct {
    resume_bytes: []const u8 = &.{},
    cursor_col: u16 = 1,
    pending_wrap: bool = false,
};

pub fn seedPreparedPresentationBoundary(
    alloc: Allocator,
    prepared: *PreparedTranscriptSurfacePaint,
    flow_offset: usize,
    boundary: PresentationBoundary,
) !void {
    const owned = try alloc.dupe(u8, boundary.resume_bytes);
    if (prepared.projection_resume_bytes.len > 0) {
        alloc.free(prepared.projection_resume_bytes);
    }
    prepared.projection_resume_bytes = owned;
    prepared.projection_resume_flow_offset = flow_offset;
    prepared.projection_resume_cursor_col = boundary.cursor_col;
    prepared.projection_resume_pending_wrap = boundary.pending_wrap;
}

/// Returns allocator-owned terminal-wire bytes when boundary state or LF is
/// present. An empty slice means the raw source slice is LF-free and wire-safe.
pub fn prepareTranscriptDocumentAppendBytes(
    alloc: Allocator,
    bytes: []const u8,
    cols: u16,
    raw_start: usize,
    raw_end: usize,
    close_endpoint: bool,
) ![]u8 {
    if (raw_start > raw_end or raw_end > bytes.len) {
        return error.InvalidTranscriptTransition;
    }

    var start = try prepareControlBoundary(alloc, bytes, cols, raw_start);
    defer start.deinit(alloc);
    var append = try prepareResumeDocumentAppend(
        alloc,
        bytes,
        cols,
        raw_start,
        raw_end,
        close_endpoint,
        .{
            .resume_bytes = start.resume_bytes,
            .cursor_col = start.cursor_col,
            .pending_wrap = start.pending_wrap,
        },
        true,
    );
    defer append.deinit(alloc);
    const result = append.bytes;
    append.bytes = &.{};
    return result;
}

test "document append preparation emits terminal-ready newlines" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "one\ntwo\n", .expected = "one\r\ntwo\r\n" },
        .{ .input = "one\r\ntwo\r", .expected = "one\r\ntwo\r" },
    };
    for (cases) |case| {
        const prepared = try prepareTranscriptDocumentAppendBytes(
            std.testing.allocator,
            case.input,
            80,
            0,
            case.input.len,
            false,
        );
        defer std.testing.allocator.free(prepared);
        try std.testing.expectEqualStrings(case.expected, prepared);
    }

    const prepared = try prepareTranscriptDocumentAppendBytes(
        std.testing.allocator,
        "no newline",
        80,
        0,
        "no newline".len,
        false,
    );
    try std.testing.expectEqual(@as(usize, 0), prepared.len);
}

test "document append preparation preserves presentation boundaries" {
    const open = "\x1b]8;id=fx-42;https://example.com\x1b\\";
    const raw = "old\nnew";
    const close = "\x1b]8;;\x1b\\";
    const source = open ++ raw ++ close;
    const prepared = try prepareTranscriptDocumentAppendBytes(
        std.testing.allocator,
        source,
        80,
        open.len,
        open.len + raw.len,
        true,
    );
    defer std.testing.allocator.free(prepared);
    try std.testing.expectEqualStrings(open ++ "old\r\nnew" ++ close, prepared);
}

pub const PreparedResumeDocumentAppend = struct {
    bytes: []u8 = &.{},
    endpoint_resume_bytes: []u8 = &.{},
    endpoint_pending_wrap: bool = false,
    endpoint_cursor_col: u16 = 1,

    pub fn deinit(self: *PreparedResumeDocumentAppend, alloc: Allocator) void {
        if (self.bytes.len > 0) alloc.free(self.bytes);
        if (self.endpoint_resume_bytes.len > 0) alloc.free(self.endpoint_resume_bytes);
        self.* = undefined;
    }
};

pub fn prepareResumeDocumentAppend(
    alloc: Allocator,
    bytes: []const u8,
    cols: u16,
    raw_start: usize,
    raw_end: usize,
    close_endpoint: bool,
    start: PresentationBoundary,
    materialize_bytes: bool,
) !PreparedResumeDocumentAppend {
    if (raw_start > raw_end or raw_end > bytes.len) {
        return error.InvalidTranscriptTransition;
    }

    var state = try vt_emulator.Grid.init(alloc, cols, 1);
    defer state.deinit();
    state.defer_sync_updates = false;
    try state.restorePresentationBoundary(
        start.resume_bytes,
        start.cursor_col,
        start.pending_wrap,
    );

    const raw_bytes = bytes[raw_start..raw_end];
    try state.feed(raw_bytes);
    if (!state.atControlSequenceBoundary()) return error.InvalidTranscriptTransition;

    var resume_writer: std.Io.Writer.Allocating = .init(alloc);
    defer resume_writer.deinit();
    try state.writePresentationResume(&resume_writer.writer);
    var steady_writer: std.Io.Writer.Allocating = .init(alloc);
    defer steady_writer.deinit();
    if (close_endpoint) try state.writePresentationSteady(&steady_writer.writer);

    var result = PreparedResumeDocumentAppend{
        .endpoint_pending_wrap = state.pending_wrap,
        .endpoint_cursor_col = state.cursor_col,
    };
    errdefer result.deinit(alloc);
    if (resume_writer.written().len > 0) {
        result.endpoint_resume_bytes = try resume_writer.toOwnedSlice();
    }
    const steady_bytes = steady_writer.written();
    const parts = [_][]const u8{ start.resume_bytes, raw_bytes, steady_bytes };
    var extra_carriage_returns: usize = 0;
    var previous_was_carriage_return = false;
    for (parts) |part| {
        for (part) |byte| {
            if (byte == '\n' and !previous_was_carriage_return) {
                extra_carriage_returns += 1;
            }
            previous_was_carriage_return = byte == '\r';
        }
    }
    if (materialize_bytes and
        (start.resume_bytes.len > 0 or steady_bytes.len > 0 or
            std.mem.findScalar(u8, raw_bytes, '\n') != null))
    {
        result.bytes = try alloc.alloc(
            u8,
            start.resume_bytes.len + raw_bytes.len + steady_bytes.len +
                extra_carriage_returns,
        );
        var offset: usize = 0;
        previous_was_carriage_return = false;
        for (parts) |part| {
            for (part) |byte| {
                if (byte == '\n' and !previous_was_carriage_return) {
                    result.bytes[offset] = '\r';
                    offset += 1;
                }
                result.bytes[offset] = byte;
                offset += 1;
                previous_was_carriage_return = byte == '\r';
            }
        }
    }
    return result;
}

pub fn prepareResetReplayDocument(
    self: anytype,
    alloc: Allocator,
    transcript_bytes: []const u8,
    visible_lines: []const VisibleTranscriptLine,
    line_visual_rows: []const u16,
    transcript_ends_with_newline: bool,
    padding_rows: u16,
) ![]u8 {
    if (visible_lines.len != line_visual_rows.len) {
        return error.InvalidTranscriptTransition;
    }
    const visual_rows = totalVisualRows(line_visual_rows);
    if (visual_rows == 0) return &.{};

    const batch = VisibleTranscriptBatch{
        .transcript = .{ .bytes = transcript_bytes },
        .lines = visible_lines,
    };
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var presentation = try vt_emulator.Grid.init(alloc, self.layout.cols, 1);
    defer presentation.deinit();

    var remaining_visual_rows = visual_rows;
    var start_line: usize = 0;
    var partial_skip_rows: u16 = 0;
    while (remaining_visual_rows > 0) {
        const render_limit: u16 = @intCast(@min(
            remaining_visual_rows,
            @as(u32, std.math.maxInt(u16)),
        ));
        var rendered = try renderTranscriptRows(
            self,
            alloc,
            batch,
            line_visual_rows,
            visible_lines.len,
            start_line,
            partial_skip_rows,
            1,
            render_limit,
            render_limit,
            &.{},
            null,
        );
        defer rendered.deinit(alloc);
        if (rendered.painted_rows == 0) return error.InvalidTranscriptTransition;

        const rendered_visual_rows: u32 = rendered.painted_rows;
        if (rendered_visual_rows > remaining_visual_rows) {
            return error.InvalidTranscriptTransition;
        }
        const final_render = rendered_visual_rows == remaining_visual_rows;
        for (rendered.rows.items, 0..) |row, row_index| {
            try output.writer.writeAll(row.bytes);
            try presentation.feed(row.bytes);

            const line_rows = line_visual_rows[row.line_index];
            const line_complete = row.partial_skip_rows + row.rows_painted == line_rows;
            const final_source_line = final_render and
                row_index + 1 == rendered.rows.items.len and
                row.line_index + 1 == visible_lines.len;
            const terminate_line = line_complete and
                (!final_source_line or
                    transcript_ends_with_newline or
                    std.meta.activeTag(visible_lines[row.line_index]) == .folded_line);
            if (terminate_line) {
                try output.writer.writeAll("\r\n");
                try presentation.feed("\r\n");
            }
        }

        try advanceResetReplayDocumentCursor(
            line_visual_rows,
            &start_line,
            &partial_skip_rows,
            rendered.painted_rows,
        );
        remaining_visual_rows -= rendered_visual_rows;
    }

    var padding_row: u16 = 0;
    while (padding_row < padding_rows) : (padding_row += 1) {
        try output.writer.writeAll("\r\n");
        try presentation.feed("\r\n");
    }

    try presentation.writePresentationSteady(&output.writer);
    return output.toOwnedSlice();
}

fn advanceResetReplayDocumentCursor(
    line_visual_rows: []const u16,
    start_line: *usize,
    partial_skip_rows: *u16,
    rows: u16,
) !void {
    var remaining = rows;
    while (remaining > 0) {
        if (start_line.* >= line_visual_rows.len) return error.InvalidTranscriptTransition;
        const line_rows = line_visual_rows[start_line.*];
        if (line_rows == 0 or partial_skip_rows.* >= line_rows) {
            return error.InvalidTranscriptTransition;
        }
        const available_rows = line_rows - partial_skip_rows.*;
        if (remaining < available_rows) {
            partial_skip_rows.* += remaining;
            return;
        }
        remaining -= available_rows;
        start_line.* += 1;
        partial_skip_rows.* = 0;
    }
}

test "reset replay document preserves folded rows without filler" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "hidden raw source\ntail", 24);
    defer batch.deinit(alloc);
    batch.lines[0] = .{ .folded_line = .{ .text = "folded-prefix", .stream = .stdout } };
    batch.line_visual_rows[0] = 1;

    var host = TestTranscriptPainterHost.init(alloc, testLayout(24, 8, 4));
    defer host.deinit();
    const replay = try prepareResetReplayDocument(
        &host,
        alloc,
        batch.transcript_bytes,
        batch.lines,
        batch.line_visual_rows,
        false,
        0,
    );
    defer if (replay.len > 0) alloc.free(replay);

    try std.testing.expect(std.mem.indexOf(u8, replay, "│ folded-prefix") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay, "tail") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, replay, "\r\n"));

    var terminal = try vt_emulator.Grid.init(alloc, 24, 1);
    defer terminal.deinit();
    var stats: vt_emulator.FeedStats = .{};
    try terminal.feedWithStats(replay, &stats);
    try std.testing.expectEqual(@as(u16, 1), stats.scroll_rows);
}

test "reset replay document fills an unused terminal tail without scrolling blanks" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "head\ntail", 10);
    defer batch.deinit(alloc);

    var host = TestTranscriptPainterHost.init(alloc, testLayout(10, 8, 4));
    defer host.deinit();
    const replay = try prepareResetReplayDocument(
        &host,
        alloc,
        batch.transcript_bytes,
        batch.lines,
        batch.line_visual_rows,
        false,
        2,
    );
    defer if (replay.len > 0) alloc.free(replay);

    var terminal = try vt_emulator.Grid.init(alloc, 10, 4);
    defer terminal.deinit();
    var stats: vt_emulator.FeedStats = .{};
    try terminal.feedWithStats(replay, &stats);
    try std.testing.expectEqual(@as(u16, 0), stats.scroll_rows);
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try terminal.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("head", row.items);
    row.clearRetainingCapacity();
    try terminal.rowTextTrimmed(2, &row);
    try std.testing.expectEqualStrings("tail", row.items);
}

test "reset replay document crosses the u16 row chunk boundary" {
    const alloc = std.testing.allocator;
    const head = try alloc.alloc(u8, std.math.maxInt(u16));
    defer alloc.free(head);
    @memset(head, 'x');
    const transcript = try std.mem.concat(alloc, u8, &.{ head, "\ntail" });
    defer alloc.free(transcript);
    var batch = try transcriptTestBatch(alloc, transcript, 1);
    defer batch.deinit(alloc);
    try std.testing.expectEqual(
        @as(u32, std.math.maxInt(u16)) + 4,
        totalVisualRows(batch.line_visual_rows),
    );

    var host = TestTranscriptPainterHost.init(alloc, testLayout(1, 8, 4));
    defer host.deinit();
    const replay = try prepareResetReplayDocument(
        &host,
        alloc,
        batch.transcript_bytes,
        batch.lines,
        batch.line_visual_rows,
        false,
        0,
    );
    defer if (replay.len > 0) alloc.free(replay);

    try std.testing.expect(std.mem.indexOf(u8, replay, "tail") != null);
}

fn preparedProjectionBoundary(
    prepared: *const PreparedTranscriptSurfacePaint,
    cols: u16,
    visual_end: u32,
) ?PreparedProjectionBoundary {
    const line_visual_rows = prepared.sourceVisualRows();
    const visible_lines = prepared.sourceVisibleLines();
    if (line_visual_rows.len != visible_lines.len) return null;
    if (visual_end == 0) {
        return .{ .flow_end = 0, .line_terminated = false };
    }
    if (prepared.source_visual_row_offsets.len == line_visual_rows.len + 1) {
        const position = sourceEndPosition(prepared, visual_end) orelse return null;
        if (position.line >= visible_lines.len) return null;
        const line = switch (visible_lines[position.line]) {
            .transcript => |value| value,
            .folded_line => return null,
        };
        const text = line.ref.resolve(.{ .bytes = prepared.bytes });
        const start: usize = line.ref.ref.start;
        if (position.intra_line_rows < line_visual_rows[position.line]) {
            return .{
                .flow_end = start + skipVisualRowsInLine(
                    text,
                    cols,
                    position.intra_line_rows,
                ),
                .line_terminated = false,
            };
        }
        var end = start + line.ref.ref.len;
        if (end < prepared.bytes.len and prepared.bytes[end] == '\n') end += 1;
        return .{
            .flow_end = end,
            .line_terminated = end > start and prepared.bytes[end - 1] == '\n',
        };
    }

    var remaining = visual_end;
    var flow_exact = true;
    for (visible_lines, line_visual_rows) |visible, line_rows| {
        if (remaining > line_rows) {
            remaining -= line_rows;
            if (std.meta.activeTag(visible) == .folded_line) flow_exact = false;
            continue;
        }

        return switch (visible) {
            .transcript => |line| blk: {
                const text = line.ref.resolve(.{ .bytes = prepared.bytes });
                const start: usize = line.ref.ref.start;
                if (remaining < line_rows) {
                    const local_end = skipVisualRowsInLine(
                        text,
                        cols,
                        @intCast(remaining),
                    );
                    break :blk .{
                        .flow_end = if (flow_exact) start + local_end else null,
                        .line_terminated = false,
                    };
                }

                var end = start + line.ref.ref.len;
                if (end < prepared.bytes.len and prepared.bytes[end] == '\n') {
                    end += 1;
                }
                break :blk .{
                    .flow_end = if (flow_exact) end else null,
                    .line_terminated = end > start and
                        prepared.bytes[end - 1] == '\n',
                };
            },
            .folded_line => .{
                .flow_end = null,
                .line_terminated = remaining == line_rows,
            },
        };
    }
    if (remaining != 0) return null;
    return .{
        .flow_end = prepared.bytes.len,
        .line_terminated = prepared.transcript_ends_with_newline,
    };
}

fn projectionRemainingVisualRows(
    prepared: *const PreparedTranscriptSurfacePaint,
    visual_offset: u32,
) ?u32 {
    const total_rows = prepared.sourceTotalVisualRows();
    if (visual_offset > total_rows) return null;
    return total_rows - visual_offset;
}

pub fn preparedTranscriptProjectionExceedsArea(
    prepared: *const PreparedTranscriptSurfacePaint,
    area: render_engine.frame_layout.FrameRect,
    visual_offset: u32,
) bool {
    if (area.isEmpty()) return false;
    const remaining_visual_rows =
        projectionRemainingVisualRows(prepared, visual_offset) orelse return false;
    return remaining_visual_rows > area.height();
}

pub fn paintPreparedTranscriptIntoSurface(
    self: anytype,
    alloc: Allocator,
    surface: *frame_surface.FrameSurface,
    prepared: *const PreparedTranscriptSurfacePaint,
) !paint_plan.TranscriptPaintResult {
    const render_context = .{
        .layout = self.layout,
        .replaceable_last_line = prepared.replaceable_last_line,
        .replaceable_start = prepared.replaceable_start,
        .replaceable_row = prepared.replaceable_row,
    };
    const result = try paintTranscriptIntoSurfaceWithLimit(
        &render_context,
        alloc,
        surface,
        prepared.batch(),
        prepared.visualRows(),
        prepared.total_lines,
        prepared.projection_ends_with_newline orelse
            prepared.transcript_ends_with_newline,
        prepared.projection_visual_rows,
        prepared.projection_resume_bytes,
        prepared.projection_start_flow_offset,
    );
    if (prepared.projection_cursor) |cursor| {
        surface.cursor_target = .{
            .row = cursor.cursor_row,
            .col = cursor.cursor_col,
            .visible = true,
        };
    }
    return result;
}

pub fn paintTranscriptIntoSurface(
    self: anytype,
    alloc: Allocator,
    surface: *frame_surface.FrameSurface,
    batch: VisibleTranscriptBatch,
    line_visual_rows: []const u16,
    total_lines: usize,
    transcript_ends_with_newline: bool,
) !paint_plan.TranscriptPaintResult {
    return paintTranscriptIntoSurfaceWithLimit(
        self,
        alloc,
        surface,
        batch,
        line_visual_rows,
        total_lines,
        transcript_ends_with_newline,
        null,
        &.{},
        null,
    );
}

fn paintTranscriptIntoSurfaceWithLimit(
    self: anytype,
    alloc: Allocator,
    surface: *frame_surface.FrameSurface,
    batch: VisibleTranscriptBatch,
    line_visual_rows: []const u16,
    total_lines: usize,
    transcript_ends_with_newline: bool,
    max_visual_rows: ?u16,
    projection_resume_bytes: []const u8,
    projection_start_flow_offset: ?usize,
) !paint_plan.TranscriptPaintResult {
    const viewport = surface.plan.viewport;
    if (total_lines == 0) {
        return .{
            .painted_rows = 0,
            .first_row = 0,
            .last_row = 0,
            .replaceable_start_row = viewport.top_row,
        };
    }

    var rendered_rows = try renderTranscriptRows(
        self,
        alloc,
        batch,
        line_visual_rows,
        total_lines,
        viewport.start_line,
        viewport.partial_skip_rows,
        viewport.top_row,
        viewport.bottom_row,
        max_visual_rows,
        projection_resume_bytes,
        projection_start_flow_offset,
    );
    defer rendered_rows.deinit(alloc);

    for (rendered_rows.rows.items) |rendered| {
        const last_row = rendered.row + rendered.rows_painted - 1;
        if (!surface.plan.transcript_band.containsRow(rendered.row) or
            !surface.plan.transcript_band.containsRow(last_row))
        {
            return error.WriteOutsideBand;
        }
        const write_result = try surface.writeAnsiBand(rendered.row, rendered.rows_painted, rendered.bytes, .transcript, .same_owner);
        if (write_result.rows_touched != rendered.rows_painted or
            write_result.first_row != rendered.row or
            write_result.last_row != last_row)
        {
            return error.AnsiBandOverflow;
        }
    }

    const cursor = calculateViewportCursor(
        self.layout,
        viewport.bottom_row,
        total_lines,
        viewport.start_line,
        rendered_rows.replaceable_line_index,
        rendered_rows.replaceable_start_row,
        rendered_rows.last_visible_line,
        rendered_rows.last_visible_row,
        rendered_rows.last_line_is_folded,
        viewport.top_row,
        transcript_ends_with_newline,
        self.replaceable_last_line,
        self.replaceable_row,
    );
    surface.cursor_target = .{ .row = cursor.cursor_row, .col = cursor.cursor_col, .visible = true };

    return .{
        .painted_rows = rendered_rows.painted_rows,
        .first_row = if (rendered_rows.rows.items.len == 0) 0 else rendered_rows.rows.items[0].row,
        .last_row = rendered_rows.last_visible_row,
        .replaceable_start_row = rendered_rows.replaceable_start_row,
    };
}

const TestFullRepaintMode = enum {
    enabled,
    diagnostic_wipe_only,
};

const TestFooterGeometry = struct {
    top: u16 = 0,
};

const TestFooterViewport = struct {
    externally_invalidated: bool = false,
    has_frame: bool = false,
    geometry: TestFooterGeometry = .{},

    fn invalidateAfterExternalClear(self: *TestFooterViewport) void {
        self.externally_invalidated = true;
    }
};

const TestPaintTrace = struct {
    transcript_log_frame: bool = false,
};

const TestTranscriptPainterHost = struct {
    alloc: Allocator,
    layout: types.Layout,
    shadow: ?*vt_emulator.Grid = null,
    emitted: std.ArrayList(u8) = .empty,
    footer_viewport: TestFooterViewport = .{},
    paint_trace: TestPaintTrace = .{},
    reflow_clear_guard_rows: u16 = 0,
    viewport_clear_pending: bool = false,
    owned_top_row: u16 = 1,
    last_visible_transcript_last_row: u16 = 0,
    last_visible_transcript_last_row_blank: bool = false,
    cursor_row: u16 = 1,
    cursor_col: u16 = 1,
    extra_input_rows: u16 = 0,
    replaceable_last_line: bool = false,
    replaceable_start: usize = 0,
    replaceable_row: u16 = 1,

    fn init(alloc: Allocator, layout: types.Layout) TestTranscriptPainterHost {
        return .{
            .alloc = alloc,
            .layout = layout,
            .cursor_row = if (layout.content_bottom == 0) 1 else layout.content_bottom,
        };
    }

    fn deinit(self: *TestTranscriptPainterHost) void {
        self.emitted.deinit(self.alloc);
    }

    fn emit(self: *TestTranscriptPainterHost, _: *Metrics, bytes: []const u8) !void {
        try self.emitted.appendSlice(self.alloc, bytes);
        if (self.shadow) |shadow| try shadow.feed(bytes);
    }

    fn footerTopRowForExtra(self: *TestTranscriptPainterHost, _: u16) u16 {
        return self.layout.divider_top_row;
    }
};

const TestTranscriptBatch = struct {
    transcript_bytes: []u8,
    hard_lines: ?HardLineStarts = null,
    lines: []VisibleTranscriptLine,
    line_visual_rows: []u16,
    ends_with_newline: bool = false,

    fn deinit(self: *TestTranscriptBatch, alloc: Allocator) void {
        if (self.hard_lines) |hard_lines| hard_lines.deinit(alloc);
        alloc.free(self.transcript_bytes);
        alloc.free(self.lines);
        alloc.free(self.line_visual_rows);
    }

    fn batch(self: TestTranscriptBatch) VisibleTranscriptBatch {
        return .{
            .transcript = .{ .bytes = self.transcript_bytes },
            .lines = self.lines,
        };
    }
};

fn testLayout(cols: u16, rows: u16, content_bottom: u16) types.Layout {
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

fn transcriptTestBatch(alloc: Allocator, bytes: []const u8, cols: u16) !TestTranscriptBatch {
    const owned = try alloc.dupe(u8, bytes);
    errdefer alloc.free(owned);
    const hard_lines = try buildHardLineStarts(alloc, owned);
    errdefer hard_lines.deinit(alloc);
    const line_count = hard_lines.len();
    const lines = try alloc.alloc(VisibleTranscriptLine, line_count);
    errdefer alloc.free(lines);
    const line_visual_rows = try alloc.alloc(u16, line_count);
    errdefer alloc.free(line_visual_rows);

    var index: usize = 0;
    while (index < line_count) : (index += 1) {
        const ref = hardLineRefAt(hard_lines, owned.len, index);
        lines[index] = visibleFromTranscript(ref);
        line_visual_rows[index] = visualRowsForLine(ref.resolve(owned), cols);
    }

    return .{
        .transcript_bytes = owned,
        .hard_lines = hard_lines,
        .lines = lines,
        .line_visual_rows = line_visual_rows,
        .ends_with_newline = hard_lines.ends_with_newline,
    };
}

fn foldedTestBatch(
    alloc: Allocator,
    stdout_text: []const u8,
    stderr_text: []const u8,
    cols: u16,
) !TestTranscriptBatch {
    const lines = try alloc.alloc(VisibleTranscriptLine, 2);
    errdefer alloc.free(lines);
    const line_visual_rows = try alloc.alloc(u16, 2);
    errdefer alloc.free(line_visual_rows);
    lines[0] = .{ .folded_line = .{ .text = stdout_text, .stream = .stdout } };
    lines[1] = .{ .folded_line = .{ .text = stderr_text, .stream = .stderr } };
    const effective_cols: u16 = if (cols > 2) cols - 2 else cols;
    line_visual_rows[0] = visualRowsForLine(stripTrailingNewline(stdout_text), effective_cols);
    line_visual_rows[1] = visualRowsForLine(stripTrailingNewline(stderr_text), effective_cols);
    return .{
        .transcript_bytes = try alloc.dupe(u8, ""),
        .lines = lines,
        .line_visual_rows = line_visual_rows,
    };
}

fn testFooterRows(layout: types.Layout) render_engine.footer_layout.FooterRows {
    return .{
        .top = layout.divider_top_row,
        .top_divider = layout.divider_top_row,
        .banner = layout.divider_top_row,
        .banner_active = false,
        .input_base = layout.input_row,
        .picker_divider = layout.divider_bottom_row,
        .picker_start = layout.hint_row,
        .bottom_divider = layout.divider_bottom_row,
        .hint = layout.hint_row,
        .total_rows = layout.rows - layout.divider_top_row + 1,
    };
}

fn testPaintPlan(layout: types.Layout, selection: ViewportSelection) paint_plan.PaintPlan {
    const preserved_band = if (selection.top_row > 1)
        paint_plan.FrameBand{ .top = 1, .bottom = selection.top_row - 1, .owner = .preserved_shell }
    else
        paint_plan.FrameBand.empty(.preserved_shell);
    return .{
        .layout = layout,
        .viewport = selection,
        .footer = testFooterRows(layout),
        .activity = .none,
        .preserved_band = preserved_band,
        .transcript_band = .{ .top = selection.top_row, .bottom = selection.bottom_row, .owner = .transcript },
        .activity_band = paint_plan.FrameBand.empty(.activity),
        .footer_band = .{ .top = layout.divider_top_row, .bottom = layout.rows, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = false,
        .cursor_target = null,
        .footer_reservation_source = .none,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

fn expectTranscriptSurfacePaint(
    alloc: Allocator,
    layout: types.Layout,
    selection: ViewportSelection,
    batch: TestTranscriptBatch,
) !vt_emulator.Grid {
    var surface_shadow = try vt_emulator.Grid.init(alloc, layout.cols, layout.rows);
    defer surface_shadow.deinit();
    var surface = try frame_surface.FrameSurface.initFromShadow(alloc, testPaintPlan(layout, selection), surface_shadow);
    defer surface.deinit();
    var surface_host = TestTranscriptPainterHost.init(alloc, layout);
    defer surface_host.deinit();
    const result = try paintTranscriptIntoSurface(
        &surface_host,
        alloc,
        &surface,
        batch.batch(),
        batch.line_visual_rows,
        batch.lines.len,
        batch.ends_with_newline,
    );
    var target = try surface.copyToTargetGrid(alloc);
    errdefer target.deinit();

    try std.testing.expect(result.first_row >= selection.top_row);
    try std.testing.expect(result.last_row <= selection.bottom_row);
    try std.testing.expect(result.replaceable_start_row >= selection.top_row);
    try std.testing.expectEqual(@as(u16, @intCast(result.last_row - selection.top_row + 1)), result.painted_rows);
    const cursor = surface.cursor_target.?;
    try std.testing.expect(cursor.row >= selection.top_row);
    try std.testing.expect(cursor.row <= selection.bottom_row);
    try std.testing.expect(cursor.col >= 1);
    try surface.validate();

    return target;
}

fn expectGridContains(grid: *vt_emulator.Grid, alloc: Allocator, needle: []const u8) !void {
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    var row: u16 = 1;
    while (row <= grid.rows) : (row += 1) {
        row_text.clearRetainingCapacity();
        try grid.rowText(row, &row_text);
        if (std.mem.find(u8, row_text.items, needle) != null) return;
    }
    return error.ExpectedTextNotFound;
}

test "resize history offset preserves the measured intra-line endpoint" {
    const rows = [_]u16{ 1, 1, 2, 1 };
    var selection = ViewportSelection{
        .top_row = 1,
        .bottom_row = 8,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = rows.len,
    };

    try std.testing.expect(applyResizeHistoryOffset(&selection, &rows, 3));
    try std.testing.expectEqual(@as(usize, 2), selection.start_line);
    try std.testing.expectEqual(@as(u16, 1), selection.partial_skip_rows);
}

test "measured source rows release partial groups at a folded boundary" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "abcdefghij\nhidden", 5);
    defer batch.deinit(alloc);
    batch.lines[1] = .{ .folded_line = .{ .text = "folded", .stream = .stdout } };

    const groups = try collectMeasuredSourceRows(
        alloc,
        batch.batch(),
        5,
        0,
        batch.transcript_bytes.len,
    );
    try std.testing.expect(groups == null);
}

test "measured history endpoint is unavailable when selection starts on folded output" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "summary\ntail", 8);
    defer batch.deinit(alloc);
    batch.lines[0] = .{ .folded_line = .{ .text = "folded", .stream = .stdout } };

    const endpoint = try advanceMeasuredHistoryEndpoint(
        alloc,
        batch.batch(),
        .{
            .top_row = 1,
            .bottom_row = 2,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = batch.lines.len,
        },
        8,
        4,
        1,
    );
    try std.testing.expect(endpoint == null);
}

test "measured history endpoint advances through exact wrapped source rows" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(
        alloc,
        "abcdefghij\nklmnopqrst\nuvwxyz",
        10,
    );
    defer batch.deinit(alloc);

    const endpoint = (try advanceMeasuredHistoryEndpoint(
        alloc,
        batch.batch(),
        .{
            .top_row = 1,
            .bottom_row = 3,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = batch.lines.len,
        },
        10,
        5,
        1,
    )) orelse return error.TestExpectedMeasuredEndpoint;
    try std.testing.expectEqual(@as(usize, 5), endpoint.flow_offset);
    const target_rows = [_]u16{ 2, 2, 2 };
    try std.testing.expectEqual(
        @as(?u32, 1),
        visualOffsetForExactFlowOffset(
            batch.batch(),
            &target_rows,
            5,
            endpoint.flow_offset,
        ),
    );
}

test "rewinding a measured endpoint returns to the advance origin" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(
        alloc,
        "abcdefghij\nklmnopqrst\nuvwxyz",
        10,
    );
    defer batch.deinit(alloc);

    const endpoint = (try advanceMeasuredHistoryEndpoint(
        alloc,
        batch.batch(),
        .{
            .top_row = 1,
            .bottom_row = 3,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = batch.lines.len,
        },
        10,
        5,
        3,
    )) orelse return error.TestExpectedMeasuredEndpoint;
    try std.testing.expectEqual(@as(usize, 16), endpoint.flow_offset);

    const rewound = try rewindMeasuredHistoryEndpoint(
        alloc,
        batch.batch(),
        endpoint,
        5,
        3,
    );
    try std.testing.expectEqual(
        @as(?usize, endpoint.span_start_flow_offset),
        rewound,
    );

    const rewound_one = try rewindMeasuredHistoryEndpoint(
        alloc,
        batch.batch(),
        endpoint,
        5,
        1,
    );
    try std.testing.expectEqual(@as(?usize, 11), rewound_one);
}

test "empty hard line start maps to its exact visual row" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "head\n\ntail", 10);
    defer batch.deinit(alloc);

    const projection = visualProjectionForFlowOffset(
        batch.batch(),
        batch.line_visual_rows,
        10,
        5,
    ) orelse return error.TestExpectedFlowProjection;
    try std.testing.expectEqual(@as(u32, 1), projection.visual_offset);
    try std.testing.expect(projection.exact);
    try std.testing.expectEqual(
        @as(?u32, 1),
        visualOffsetForExactFlowOffset(
            batch.batch(),
            batch.line_visual_rows,
            10,
            5,
        ),
    );
}

test "inexact measured endpoint resumes from its containing target row" {
    const alloc = std.testing.allocator;
    const record = "a" ** 249;
    const flow =
        record ++ "\n" ++
        record ++ "\n" ++
        record ++ "\n" ++
        record ++ "\n" ++
        record ++ "\n" ++
        record;
    var batch = try transcriptTestBatch(alloc, flow, 70);
    defer batch.deinit(alloc);

    const endpoint = (try advanceMeasuredHistoryEndpoint(
        alloc,
        batch.batch(),
        .{
            .top_row = 1,
            .bottom_row = 30,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = batch.lines.len,
        },
        120,
        70,
        29,
    )) orelse return error.TestExpectedMeasuredEndpoint;
    try std.testing.expectEqual(@as(usize, 1490), endpoint.flow_offset);

    const projection = visualProjectionForFlowOffset(
        batch.batch(),
        batch.line_visual_rows,
        70,
        endpoint.flow_offset,
    ) orelse return error.TestExpectedFlowProjection;
    try std.testing.expectEqual(@as(u32, 23), projection.visual_offset);
    try std.testing.expect(!projection.exact);

    const layout = testLayout(70, 24, 20);
    var host = TestTranscriptPainterHost.init(alloc, layout);
    defer host.deinit();
    var rendered = try renderTranscriptRows(
        &host,
        alloc,
        batch.batch(),
        batch.line_visual_rows,
        batch.lines.len,
        5,
        3,
        1,
        20,
        null,
        &.{},
        endpoint.flow_offset,
    );
    defer rendered.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 9), rendered.rows.items[0].bytes.len);
    try std.testing.expectEqualStrings("a" ** 9, rendered.rows.items[0].bytes);
    try std.testing.expectEqual(@as(u16, 1), rendered.rows.items[0].rows_painted);
    try std.testing.expectEqualStrings("a" ** 9, rendered.last_visible_line);
    const cursor = calculateViewportCursor(
        layout,
        20,
        batch.lines.len,
        5,
        batch.lines.len,
        1,
        rendered.last_visible_line,
        rendered.last_visible_row,
        false,
        1,
        false,
        false,
        1,
    );
    try std.testing.expectEqual(@as(u16, 1), cursor.cursor_row);
    try std.testing.expectEqual(@as(u16, 10), cursor.cursor_col);
}

test "committed measured endpoint advances by source hard-row groups" {
    const flow = ("a" ** 21) ++ "\n" ++ ("b" ** 21) ++ "\n";
    const advanced = advanceMeasuredHistoryOriginForCommittedRows(
        flow,
        .{
            .source_cols = 10,
            .source_visual_offset = 0,
            .endpoint = .{
                .span_start_flow_offset = 0,
                .flow_offset = 0,
                .hard_row_cols = 10,
            },
        },
        6,
        5,
    ) orelse return error.TestExpectedMeasuredHistoryOrigin;
    try std.testing.expectEqual(@as(usize, 22), advanced.endpoint.?.flow_offset);
}

test "exact measured endpoint mapping is inexact when folded output precedes it" {
    const alloc = std.testing.allocator;
    var source = try transcriptTestBatch(alloc, "head\ntail", 8);
    defer source.deinit(alloc);
    const endpoint = (try advanceMeasuredHistoryEndpoint(
        alloc,
        source.batch(),
        .{
            .top_row = 1,
            .bottom_row = 2,
            .start_line = 1,
            .partial_skip_rows = 0,
            .line_count = source.lines.len,
        },
        8,
        4,
        1,
    )) orelse return error.TestExpectedMeasuredEndpoint;

    source.lines[0] = .{ .folded_line = .{ .text = "folded", .stream = .stdout } };
    try std.testing.expect(
        visualOffsetForExactFlowOffset(
            source.batch(),
            source.line_visual_rows,
            4,
            endpoint.flow_offset,
        ) == null,
    );
}

test "resize history offset drops a pinned welcome split" {
    const rows = [_]u16{ 1, 1, 1, 1, 1 };
    var selection = ViewportSelection{
        .top_row = 1,
        .bottom_row = 4,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = 4,
        .split_active = true,
        .split_prefix_lines = 2,
        .split_suffix_start_line = 3,
    };

    _ = applyResizeHistoryOffset(&selection, &rows, 2);
    try std.testing.expect(!selection.split_active);
    try std.testing.expectEqual(@as(usize, 3), selection.start_line);
}

test "resize history offset applies measured rows to the committed prefix" {
    try std.testing.expectEqual(@as(u32, 8), offsetBySignedRows(8, 0));
    try std.testing.expectEqual(@as(u32, 12), offsetBySignedRows(4, 8));
    try std.testing.expectEqual(@as(u32, 0), offsetBySignedRows(4, -10));
}

test "resize history offset replays the welcome tail when history returns" {
    const rows = [_]u16{ 1, 1, 1, 1, 2, 1, 1, 2 };
    const boundary = transcript_blocks.LeadingWelcomeBoundary{
        .full_cut_line = 7,
        .tail_replay_line = 5,
    };
    try std.testing.expectEqual(
        @as(u32, 8),
        preserveWelcomeReplayBoundary(4, 4, boundary, &rows),
    );
    try std.testing.expectEqual(
        @as(u32, 6),
        preserveWelcomeReplayBoundary(4, -2, boundary, &rows),
    );
}

test "transcript surface painter renders welcome plus user rows" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "fx welcome\n\n╭ user prompt\n╰ done", 24);
    defer batch.deinit(alloc);
    const layout = testLayout(24, 10, 6);
    var target = try expectTranscriptSurfacePaint(alloc, layout, .{
        .top_row = 1,
        .bottom_row = 6,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = batch.lines.len,
    }, batch);
    defer target.deinit();
    try expectGridContains(&target, alloc, "fx welcome");
    try expectGridContains(&target, alloc, "user prompt");
}

test "transcript surface painter renders assistant partial tail" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "abcdefghijklmnopqrst", 5);
    defer batch.deinit(alloc);
    const layout = testLayout(5, 8, 4);
    var target = try expectTranscriptSurfacePaint(alloc, layout, .{
        .top_row = 2,
        .bottom_row = 3,
        .start_line = 0,
        .partial_skip_rows = 2,
        .line_count = batch.lines.len,
    }, batch);
    defer target.deinit();
    try expectGridContains(&target, alloc, "klmno");
    try expectGridContains(&target, alloc, "pqrst");
}

test "transcript surface painter renders soft wrap across three rows" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "abcdefghijkl", 5);
    defer batch.deinit(alloc);
    const layout = testLayout(5, 8, 4);
    var target = try expectTranscriptSurfacePaint(alloc, layout, .{
        .top_row = 1,
        .bottom_row = 3,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = batch.lines.len,
    }, batch);
    defer target.deinit();
    try expectGridContains(&target, alloc, "abcde");
    try expectGridContains(&target, alloc, "fghij");
    try expectGridContains(&target, alloc, "kl");
}

test "transcript surface painter materializes an ANSI-only logical row" {
    const alloc = std.testing.allocator;
    const styled_notice = "\x1b[2m" ++ ("x" ** 391) ++ "\x1b[0m";
    try std.testing.expectEqual(@as(usize, 399), styled_notice.len);

    var batch = try transcriptTestBatch(alloc, styled_notice ++ "\n\x1b[0m", 123);
    defer batch.deinit(alloc);
    try std.testing.expectEqualSlices(u16, &.{ 4, 1 }, batch.line_visual_rows);

    const layout = testLayout(123, 34, 30);
    var target = try expectTranscriptSurfacePaint(alloc, layout, .{
        .top_row = 1,
        .bottom_row = 5,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = batch.lines.len,
    }, batch);
    defer target.deinit();
    try expectGridContains(&target, alloc, "xxxxxxxx");
}

test "ANSI-only transcript bytes retain controls and materialize their planned row" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "\x1b[0m", 123);
    defer batch.deinit(alloc);
    const layout = testLayout(123, 34, 30);
    var host = TestTranscriptPainterHost.init(alloc, layout);
    defer host.deinit();

    var rendered = try renderTranscriptRows(
        &host,
        alloc,
        batch.batch(),
        batch.line_visual_rows,
        batch.lines.len,
        0,
        0,
        1,
        1,
        null,
        &.{},
        null,
    );
    defer rendered.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 1), rendered.rows.items[0].rows_painted);
    try std.testing.expectEqualStrings("\x1b[0m\x1b[2K", rendered.rows.items[0].bytes);
}

test "transcript surface painter renders hard newline row boundaries" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "alpha\nbeta\n\ngamma", 20);
    defer batch.deinit(alloc);
    const layout = testLayout(20, 10, 6);
    var target = try expectTranscriptSurfacePaint(alloc, layout, .{
        .top_row = 1,
        .bottom_row = 6,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = batch.lines.len,
    }, batch);
    defer target.deinit();
    try expectGridContains(&target, alloc, "alpha");
    try expectGridContains(&target, alloc, "beta");
    try expectGridContains(&target, alloc, "gamma");
}

test "transcript surface painter renders folded stdout and stderr" {
    const alloc = std.testing.allocator;
    var batch = try foldedTestBatch(alloc, "stdout wraps here", "stderr wraps here", 10);
    defer batch.deinit(alloc);
    const layout = testLayout(10, 10, 6);
    var target = try expectTranscriptSurfacePaint(alloc, layout, .{
        .top_row = 1,
        .bottom_row = 6,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = batch.lines.len,
    }, batch);
    defer target.deinit();
    try expectGridContains(&target, alloc, "stdout");
    try expectGridContains(&target, alloc, "stderr");
}

test "transcript surface painter renders block gap rows" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "raw block\n\nassistant block\n\n╭ user block", 28);
    defer batch.deinit(alloc);
    const layout = testLayout(28, 10, 7);
    var target = try expectTranscriptSurfacePaint(alloc, layout, .{
        .top_row = 1,
        .bottom_row = 7,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = batch.lines.len,
    }, batch);
    defer target.deinit();
    try expectGridContains(&target, alloc, "raw block");
    try expectGridContains(&target, alloc, "assistant block");
    try expectGridContains(&target, alloc, "user block");
}

test "transcript surface painter preserves OSC 8 links through target-grid diff" {
    const alloc = std.testing.allocator;
    const linked = "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\";
    var batch = try transcriptTestBatch(alloc, linked, 20);
    defer batch.deinit(alloc);
    const layout = testLayout(20, 8, 4);
    var target = try expectTranscriptSurfacePaint(alloc, layout, .{
        .top_row = 1,
        .bottom_row = 4,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = batch.lines.len,
    }, batch);
    defer target.deinit();

    const target_cell = target.cellAt(1, 1).?;
    try std.testing.expect(target_cell.style.hyperlink_id != 0);
    try std.testing.expectEqualStrings("https://example.com", target.hyperlinkUrl(target_cell.style.hyperlink_id).?);

    var diff_prev = try vt_emulator.Grid.init(alloc, layout.cols, layout.rows);
    defer diff_prev.deinit();
    var diff_buf: std.ArrayList(u8) = .empty;
    defer diff_buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &diff_buf);
    try vt_emulator.Grid.diffBand(diff_prev, target, 1, 1, &writer.writer);
    diff_buf = writer.toArrayList();
    try diff_prev.feed(diff_buf.items);
    const diff_cell = diff_prev.cellAt(1, 1).?;
    try std.testing.expectEqualStrings("https://example.com", diff_prev.hyperlinkUrl(diff_cell.style.hyperlink_id).?);
}

test "resume document append matches full prefix replay" {
    const alloc = std.testing.allocator;
    const prefix = "\x1b[31mABCD";
    const middle = "\x1b[32mEFGH\nI";
    const flow = prefix ++ middle ++ "\x1b[0mJ";

    var start = try vt_emulator.Grid.init(alloc, 4, 1);
    defer start.deinit();
    try start.feed(prefix);
    var start_resume: std.Io.Writer.Allocating = .init(alloc);
    defer start_resume.deinit();
    try start.writePresentationResume(&start_resume.writer);

    var append = try prepareResumeDocumentAppend(
        alloc,
        flow,
        4,
        prefix.len,
        prefix.len + middle.len,
        true,
        .{
            .resume_bytes = start_resume.written(),
            .cursor_col = start.cursor_col,
            .pending_wrap = start.pending_wrap,
        },
        true,
    );
    defer append.deinit(alloc);
    const replay = try prepareTranscriptDocumentAppendBytes(
        alloc,
        flow,
        4,
        prefix.len,
        prefix.len + middle.len,
        true,
    );
    defer if (replay.len > 0) alloc.free(replay);

    try std.testing.expectEqualStrings(replay, append.bytes);
    var endpoint = try vt_emulator.Grid.init(alloc, 4, 1);
    defer endpoint.deinit();
    try endpoint.feed(flow[0 .. prefix.len + middle.len]);
    var endpoint_resume: std.Io.Writer.Allocating = .init(alloc);
    defer endpoint_resume.deinit();
    try endpoint.writePresentationResume(&endpoint_resume.writer);
    try std.testing.expectEqualStrings(endpoint_resume.written(), append.endpoint_resume_bytes);
    try std.testing.expectEqual(endpoint.cursor_col, append.endpoint_cursor_col);
    try std.testing.expectEqual(endpoint.pending_wrap, append.endpoint_pending_wrap);
}

test "transcript surface painter handles zero transcript lines" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "", 20);
    defer batch.deinit(alloc);
    const layout = testLayout(20, 8, 4);
    const selection: ViewportSelection = .{
        .top_row = 1,
        .bottom_row = 4,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = 0,
    };
    var shadow = try vt_emulator.Grid.init(alloc, layout.cols, layout.rows);
    defer shadow.deinit();
    var surface = try frame_surface.FrameSurface.initFromShadow(alloc, testPaintPlan(layout, selection), shadow);
    defer surface.deinit();
    var host = TestTranscriptPainterHost.init(alloc, layout);
    defer host.deinit();

    const result = try paintTranscriptIntoSurface(&host, alloc, &surface, batch.batch(), batch.line_visual_rows, 0, false);
    try std.testing.expectEqual(@as(u16, 0), result.painted_rows);
    try std.testing.expectEqual(@as(u16, 0), result.first_row);
    try std.testing.expectEqual(@as(u16, 0), result.last_row);
    try std.testing.expect(surface.cursor_target == null);
}

test "transcript selection bottom follows sparse rendered rows" {
    const alloc = std.testing.allocator;
    var batch = try transcriptTestBatch(alloc, "alpha\nbeta\n", 20);
    defer batch.deinit(alloc);
    const layout = testLayout(20, 12, 8);
    var host = TestTranscriptPainterHost.init(alloc, layout);
    defer host.deinit();

    var selection = buildViewportSelection(.{
        .top_row = 1,
        .bottom_row = 8,
        .line_visual_rows = batch.line_visual_rows,
        .visible_rows = 8,
        .replaceable_line_index = batch.lines.len,
    }).selection;
    try std.testing.expectEqual(@as(u16, 8), selection.bottom_row);

    var rendered_rows = try renderTranscriptRows(
        &host,
        alloc,
        batch.batch(),
        batch.line_visual_rows,
        batch.lines.len,
        selection.start_line,
        selection.partial_skip_rows,
        selection.top_row,
        selection.bottom_row,
        null,
        &.{},
        null,
    );
    defer rendered_rows.deinit(alloc);

    applyRenderedRowsToSelection(&selection, &rendered_rows);
    try std.testing.expectEqual(rendered_rows.last_visible_row, selection.last_visible_row);
    try std.testing.expectEqual(rendered_rows.last_visible_row, selection.bottom_row);
    try std.testing.expectEqual(@as(u16, 2), selection.bottom_row);
}

test "transcript document control cursor matches independent boundary preparation" {
    const alloc = std.testing.allocator;
    const bytes = "\x1b[31mred-red\nstill-red\x1b[0m\n" ++
        "\x1b]8;;https://example.com\x1b\\link\x1b]8;;\x1b\\\nplain";
    const ranges = [_][2]usize{
        .{ 5, 12 },
        .{ 13, 26 },
        .{ 27, 64 },
        .{ 65, 70 },
    };

    var cursor = try TranscriptDocumentControlCursor.init(alloc, bytes, 20);
    defer cursor.deinit();
    for (ranges) |range| {
        const expected = try prepareTranscriptDocumentAppendBytes(
            alloc,
            bytes,
            20,
            range[0],
            range[1],
            true,
        );
        defer if (expected.len > 0) alloc.free(expected);
        const actual = try cursor.prepareAppendBytes(
            alloc,
            range[0],
            range[1],
            true,
        );
        defer if (actual.len > 0) alloc.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "transcript paint row traces stay metadata only" {
    const source = @embedFile("painter.zig");
    const forbidden_preview = "pre" ++ "view=";
    try std.testing.expect(std.mem.find(u8, source, "transcript_line row=") != null);
    try std.testing.expect(std.mem.find(u8, source, forbidden_preview) == null);
}
