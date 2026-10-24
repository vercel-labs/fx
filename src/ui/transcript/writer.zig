// Host contract:
// - fields: transcript, entries, max_transcript_bytes, replaceable_last_line,
//   replaceable_start, cursor_row, cursor_col, layout, viewport_top_row,
//   owned_top_row, pending_scroll_compact,
//   has_painted_transcript, transcript_band_dirty, last_rendered_cols,
//   transcript_cache_origin_untrimmed
// - methods: forgetShimmer, assertCanMutateTranscript, advanceCursor,
//   ensurePaintReservation, rebuildTranscriptCacheFromEntries,
//   recomputeCursorFromTranscript
// This module owns transcript writes plus scroll coordination during writes.

const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const render_engine = @import("../render_engine.zig");
const transcript_store = @import("store.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;
const transcript_blocks = render_engine.transcript_blocks;
const RawEntryClass = transcript_blocks.RawEntryClass;

fn requestTranscriptPaint(
    self: anytype,
    content_changed: bool,
    dirty_entry_id: ?u32,
) void {
    const Runtime = @TypeOf(self.*);
    if (content_changed) {
        if (dirty_entry_id) |entry_id| {
            if (comptime @hasDecl(Runtime, "markTranscriptContentDirtyFrom")) {
                self.markTranscriptContentDirtyFrom(entry_id);
                return;
            }
        }
        if (comptime @hasDecl(Runtime, "markTranscriptContentDirty")) {
            self.markTranscriptContentDirty();
            return;
        }
    }
    if (comptime @hasDecl(Runtime, "markTranscriptDirty")) {
        self.markTranscriptDirty();
    } else {
        self.transcript_band_dirty = true;
    }
}

pub fn writeTranscriptBytes(self: anytype, alloc: Allocator, metrics: *Metrics, text: []const u8, record: bool) !void {
    return writeTranscriptBytesInternal(self, alloc, metrics, text, record, null);
}

pub fn writeTranscriptBytesFrom(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    text: []const u8,
    record: bool,
    entry_id: u32,
) !void {
    return writeTranscriptBytesInternal(self, alloc, metrics, text, record, entry_id);
}

fn writeTranscriptBytesInternal(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    text: []const u8,
    record: bool,
    dirty_entry_id: ?u32,
) !void {
    if (text.len == 0) return;

    _ = metrics;
    self.forgetShimmer();

    // `record` gates transcript-buffer and replaceable-state
    // bookkeeping only. Cursor geometry still advances so frame
    // preparation sees the same pending layout as recorded writes.
    if (record) {
        try self.assertCanMutateTranscript();
        self.notebook.transcript_cache_origin_untrimmed = false;
        _ = try transcript_store.appendCappedWithinCapacity(
            &self.notebook.transcript,
            alloc,
            text,
            self.notebook.max_transcript_bytes,
            &self.notebook.replaceable_last_line,
            &self.notebook.replaceable_start,
        );
        if (self.notebook.replaceable_last_line) {
            debug_trace.logf("transcript.replaceable_flip", "writeTranscriptBytes appended non-replaceable, text_bytes={d}", .{text.len});
        }
        self.notebook.replaceable_last_line = false;
        self.notebook.replaceable_start = 0;
    }

    // Cursor tracking stays so the pre-paint heuristics in main.zig
    // (e.g. the `cursor_col != 1` leading-newline test) still see
    // sensible values between ticks. The paint pass will
    // authoritatively overwrite these when it runs.
    const cursor_row_before: u32 = @as(u32, self.cursor_row);
    const walk = self.advanceCursor(text);
    std.debug.assert(walk.end_row >= cursor_row_before);

    // Viewport selection converts overflow into frame-owned scroll.
    const content_bottom_u32: u32 = @as(u32, self.layout.content_bottom);
    if (walk.end_row > content_bottom_u32) {
        const total_scroll_u32 = walk.end_row - content_bottom_u32;
        const total_scroll: u16 = @intCast(@min(total_scroll_u32, @as(u32, std.math.maxInt(u16))));
        self.cursor_row = self.layout.content_bottom;
        debug_trace.logf(
            "scroll",
            "cursor_overflow_deferred_to_selection total_scroll={d} viewport_top={d} owned_top={d} cursor_row_after={d} walk_end_row={d} text_bytes={d} has_painted={s}",
            .{ total_scroll, self.viewport_top_row, self.owned_top_row, self.cursor_row, walk.end_row, text.len, if (self.has_painted_transcript) "true" else "false" },
        );
    }

    requestTranscriptPaint(self, record, dirty_entry_id);
}

fn recordTranscriptFrameInvalidation(self: anytype, reason: render_engine.paint_plan.FrameInvalidationReason) void {
    if (self.layout.rows == 0) return;
    const Shell = @TypeOf(self.*);
    if (comptime !@hasDecl(Shell, "recordFrameInvalidation")) return;
    const top = if (self.owned_top_row == 0 or self.owned_top_row > self.layout.rows) @as(u16, 1) else self.owned_top_row;
    self.recordFrameInvalidation(.{
        .reason = reason,
        .top = top,
        .bottom = self.layout.rows,
    }) catch |err| {
        debug_trace.logf(
            "frame_plan",
            "transcript_invalidation_drop reason={s} top={d} bottom={d} err={s}",
            .{ @tagName(reason), top, self.layout.rows, @errorName(err) },
        );
    };
}

pub fn writeTranscript(self: anytype, alloc: Allocator, metrics: *Metrics, text: []const u8, record: bool) !void {
    _ = try writeTranscriptReturningEntryIdClassified(self, alloc, metrics, text, record, .unknown_raw);
}

pub fn writeTranscriptClassified(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    text: []const u8,
    record: bool,
    class: RawEntryClass,
) !void {
    _ = try writeTranscriptReturningEntryIdClassified(self, alloc, metrics, text, record, class);
}

pub fn writeTranscriptReturningEntryIdClassified(
    self: anytype,
    alloc: Allocator,
    metrics: *Metrics,
    text: []const u8,
    record: bool,
    class: RawEntryClass,
) !u32 {
    if (text.len == 0) return 0;

    if (!record) {
        try self.writeTranscriptBytes(alloc, metrics, text, false);
        return 0;
    }

    const entry_id = try transcript_store.writeRecordedTranscriptClassifiedAtomic(
        self,
        alloc,
        metrics,
        text,
        class,
    );
    self.forgetShimmer();
    return entry_id;
}

pub fn reconstructivePaint(self: anytype, alloc: Allocator, metrics: *Metrics) !void {
    _ = metrics;
    debug_trace.logf("reconstructive", "enter cols={d} rows={d} content_bottom={d} entries={d} cap={d}", .{ self.layout.cols, self.layout.rows, self.layout.content_bottom, self.notebook.entries.items.len, self.notebook.max_transcript_bytes });
    try self.ensurePaintReservation(alloc);
    try self.rebuildTranscriptCacheFromEntries(alloc, "reconstructive paint");
    self.recomputeCursorFromTranscript();
    self.pending_scroll_compact = false;
    self.invalidateTranscriptAnchor("reconstructive_paint");
    self.viewport_clear_pending = true;
    requestTranscriptPaint(self, false, null);
    recordTranscriptFrameInvalidation(self, .diagnostic_wipe);
    debug_trace.logf(
        "frame_plan",
        "reconstructive_paint_frame_deferred rows={d} entries={d}",
        .{ self.layout.rows, self.notebook.entries.items.len },
    );
    debug_trace.logf("reconstructive", "exit cursor={d},{d} viewport_top={d} transcript_bytes={d} replaceable={s}", .{ self.cursor_row, self.cursor_col, self.viewport_top_row, self.notebook.transcript.items.len, if (self.notebook.replaceable_last_line) "true" else "false" });
}
