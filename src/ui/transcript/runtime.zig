const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const display_width = @import("../../core/shared/display_width.zig");
const input_action = @import("../../core/input/input_action.zig");
const io_mod = @import("../../core/shared/io.zig");
const activity_status = @import("../../core/output/activity_status.zig");
const activity_runtime = @import("../../core/output/activity_runtime.zig");
const transcript_release = @import("../../core/output/transcript_release.zig");
const transcript_presentation = @import("../../core/output/transcript_presentation.zig");
const full_transcript_page = @import("../../core/output/full_transcript_page.zig");
const diff_mod = @import("../../core/output/diff.zig");
const worker_status = @import("../../core/output/worker_status.zig");
const footer_viewport_runtime = @import("../footer/viewport.zig");
const render_request = @import("../render_request.zig");
const command_output_runtime = @import("command_output_runtime.zig");
const input_visual_layout = @import("../input/visual_layout.zig");
const user_message_card = @import("../assistant/user_message_card.zig");
const render_engine = @import("../render_engine.zig");
const build_checkpoint = @import("../render_engine/build_checkpoint.zig");
const transcript_io = @import("io.zig");
const transcript_painter = @import("painter.zig");
const source_preparation = @import("source_preparation.zig");
const full_transcript_worker = @import("full_transcript_worker.zig");
const tool_group_projection = @import("tool_group_projection.zig");
const transcript_store = @import("store.zig");
const full_transcript_screen = @import("../full_transcript_screen.zig");
const transcript_viewport_runtime = @import("viewport_runtime.zig");
const transcript_writer = @import("writer.zig");
const ui_render = @import("../render.zig");
const types = @import("../../core/shared/types.zig");
const command_output_content = @import("../../core/tooling/command_output_content.zig");
const captured_command = @import("../../core/tooling/captured_command.zig");
const tool_result_errors = @import("../../core/tooling/tool_result_errors.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");
const result_store = @import("../../core/session/result_store.zig");
const session_child_store = @import("../../core/session/session_child_store.zig");

const Allocator = std.mem.Allocator;
const Layout = types.Layout;
const Metrics = types.Metrics;
const transcript_blocks = render_engine.transcript_blocks;
const viewport_selection = render_engine.viewport_selection;

pub const CommandOutputDisplayState = transcript_blocks.CommandOutputDisplayState;
pub const Styles = transcript_blocks.Styles;
pub const AssistantTurnSegments = transcript_blocks.AssistantTurnSegments;
pub const RawEntryClass = transcript_blocks.RawEntryClass;
pub const TranscriptEntry = transcript_blocks.TranscriptEntry;
pub const TranscriptPreparationSource = source_preparation.TranscriptPreparationSource;

pub const VisibleTranscriptSnapshot = struct {
    text: []u8,
    terminal_rows: u16,
    terminal_cols: u16,
    complete: bool,

    pub fn deinit(self: *VisibleTranscriptSnapshot, alloc: Allocator) void {
        alloc.free(self.text);
        self.* = undefined;
    }
};

pub const ResizeObservationPhase = enum {
    live,
    settle_pending,
    reset_queued,
};

pub const ResizeObservationResult = union(enum) {
    awaiting,
    measured: i32,
    unavailable,
};

pub const ResizeObservation = struct {
    layout: types.Layout,
    apply_after_ms: i64,
    expected_row: ?u32,
    result: ResizeObservationResult,
    phase: ResizeObservationPhase,
};

const ViewportSelection = viewport_selection.ViewportSelection;

pub const TranscriptCommitDiagnosticState = enum {
    invalid,
    stable,
    recovering,
};

pub const TranscriptCommitDiagnostic = struct {
    state: TranscriptCommitDiagnosticState,
    stable_start_line: ?usize = null,
    visual_offset: u32 = 0,
    layout_id: u64 = 0,
    remaining_inline_rows: u32 = 0,
    remaining_unplanned_scroll_rows: u16 = 0,
};

pub const StableTranscriptProjection = struct {
    selection: ViewportSelection,
    visual_offset: u32,
    history_visual_offset: u32,
    total_visual_rows: u32,
    flow_unchanged: bool,
    cursor_row: u16,
    cursor_col: u16,
    occupied_last_row: u16,
    occupied_last_row_blank: bool,
    layout_id: u64,
    measured_history_origin: ?transcript_painter.MeasuredHistoryOrigin = null,
};

pub const MeasuredResizeProjection = union(enum) {
    stable,
    recovering: struct {
        accepted_visual_offset: u32,
        source_cols: u16,
    },
};

const CommittedTranscriptAnchor = struct {
    selection: ViewportSelection,
    visual_offset: u32,
    // Footer reflow can move the logical tail without advancing rows into
    // terminal history. The committed grid projection resumes from this offset.
    history_visual_offset: u32,
    total_visual_rows: u32,
    flow: []u8,
    cursor_row: u16,
    cursor_col: u16,
    occupied_last_row: u16,
    occupied_last_row_blank: bool,
    layout_id: u64,
    measured_history_origin: ?transcript_painter.MeasuredHistoryOrigin = null,
    row_provenance: []transcript_blocks.RowProvenance = &.{},
    normal_buffer_recovery_pending: bool = false,
    /// Stable-anchor settlement obligation. It is preserved while final rows
    /// remain ahead of history and cleared once history reaches the viewport.
    /// The offset gap alone is insufficient because footer displacement can
    /// create the same shape without content debt.
    history_catchup_pending: bool = false,

    fn deinit(self: *CommittedTranscriptAnchor, alloc: Allocator) void {
        if (self.flow.len > 0) alloc.free(self.flow);
        if (self.row_provenance.len > 0) alloc.free(self.row_provenance);
        self.* = undefined;
    }
};

fn committedProjectionVisualOffset(anchor: CommittedTranscriptAnchor) u32 {
    return if (anchor.normal_buffer_recovery_pending)
        anchor.history_visual_offset
    else
        anchor.visual_offset;
}

const TranscriptRecoveryReceipt = struct {
    accepted_visual_offset: u32 = 0,
    accepted_history_visual_offset: u32 = 0,
    attempt_visual_offset: u32 = 0,
    attempt_total_visual_rows: u32 = 0,
    materialized_visual_offset: u32 = 0,
    materialized_visual_rows: u16 = 0,
    materialized_flow_len: ?usize = null,
    remaining_resize_reflow_rows: u16 = 0,
    remaining_semantic_rows: u32 = 0,
    // Only this remaining semantic suffix may advance the current projection.
    remaining_semantic_progress_rows: u32 = 0,
    remaining_unplanned_scroll_rows: u16 = 0,
    attempt_cols: u16 = 0,
    attempt_resize_history_row_delta: ?i32 = null,
    attempt_resize_history_committed: bool = false,
    projection_rebase_pending: bool = false,
    tracks_semantic_progress: bool = false,
    flow: []u8 = &.{},
    flow_owned: bool = true,
    presentation_resume_bytes: []u8 = &.{},
    presentation_pending_wrap: bool = false,
    presentation_valid: bool = false,
    cursor_row: u16 = 1,
    cursor_col: u16 = 1,
    document_append_committed: bool = false,
    measured_history_origin: ?transcript_painter.MeasuredHistoryOrigin = null,
    row_provenance: []transcript_blocks.RowProvenance = &.{},
    normal_buffer_recovery_pending: bool = false,

    fn deinit(self: *TranscriptRecoveryReceipt, alloc: Allocator) void {
        if (self.flow_owned and self.flow.len > 0) alloc.free(self.flow);
        if (self.presentation_resume_bytes.len > 0) alloc.free(self.presentation_resume_bytes);
        if (self.row_provenance.len > 0) alloc.free(self.row_provenance);
        self.* = undefined;
    }
};

const TranscriptCommitState = union(enum) {
    invalid,
    stable: CommittedTranscriptAnchor,
    recovering: TranscriptRecoveryReceipt,

    fn deinit(self: *TranscriptCommitState, alloc: Allocator) void {
        switch (self.*) {
            .invalid => {},
            .stable => |*anchor| anchor.deinit(alloc),
            .recovering => |*receipt| receipt.deinit(alloc),
        }
        self.* = .invalid;
    }
};

fn recoveryAppendPrefixMatches(
    target_flow: []const u8,
    receipt: TranscriptRecoveryReceipt,
    materialized_flow_len: usize,
) bool {
    return materialized_flow_len <= receipt.flow.len and
        materialized_flow_len <= target_flow.len and
        std.mem.eql(
            u8,
            target_flow[0..materialized_flow_len],
            receipt.flow[0..materialized_flow_len],
        );
}

pub const TranscriptScrollFacts = struct {
    source_visual_offset: u32 = 0,
    target_visual_offset: u32 = 0,
    resize_reflow_rows: u16 = 0,
    semantic_rows: u32 = 0,
    semantic_progress_rows: u32 = 0,
    planned_rows: u16 = 0,
    source_compatible: bool = false,
    geometry_rebase: bool = false,
    recovery_rebase: bool = false,
    recovery_progress_compatible: bool = false,
    recovery_tracks_semantic_progress: bool = false,
    recovery_projection_deferred: bool = false,
    /// The finality floor withheld release this frame (mutable rows above
    /// the viewport top), or final rows remain to settle beyond what this
    /// frame planned. Routes into history_catchup_pending at commit so the
    /// existing catch-up machinery settles the debt; footer displacement
    /// (visual ahead of history with nothing to settle) stays unflagged.
    finality_hold: bool = false,
};

pub const RetainedTranscriptBody = render_engine.frame_retention.RetainedTranscriptBody;

pub const TranscriptBodyDisposition = union(enum) {
    paint,
    retain_committed: RetainedTranscriptBody,
};

fn nextResizeBottomAnchorPending(
    pending: bool,
    terminal_reset_commit: bool,
    resize_reset_commit: bool,
    tail_kind: ?TranscriptBlockKind,
    occupied_last_row: u16,
    content_bottom_row: u16,
) bool {
    const next = if (terminal_reset_commit)
        resize_reset_commit
    else
        pending;
    if (tail_kind == .cancel_notice and
        occupied_last_row == content_bottom_row)
    {
        return false;
    }
    return next;
}

test "resize bottom anchor remains pending until a cancel projection reaches it" {
    const Case = struct {
        pending: bool,
        terminal_reset_commit: bool,
        resize_reset_commit: bool,
        tail_kind: ?TranscriptBlockKind,
        occupied_last_row: u16,
        content_bottom_row: u16,
        expected: bool,
    };
    const cases = [_]Case{
        .{ .pending = false, .terminal_reset_commit = false, .resize_reset_commit = false, .tail_kind = null, .occupied_last_row = 4, .content_bottom_row = 8, .expected = false },
        .{ .pending = false, .terminal_reset_commit = true, .resize_reset_commit = true, .tail_kind = null, .occupied_last_row = 4, .content_bottom_row = 8, .expected = true },
        .{ .pending = true, .terminal_reset_commit = false, .resize_reset_commit = false, .tail_kind = .assistant_turn, .occupied_last_row = 4, .content_bottom_row = 8, .expected = true },
        .{ .pending = true, .terminal_reset_commit = false, .resize_reset_commit = false, .tail_kind = .cancel_notice, .occupied_last_row = 4, .content_bottom_row = 8, .expected = true },
        .{ .pending = true, .terminal_reset_commit = false, .resize_reset_commit = false, .tail_kind = .cancel_notice, .occupied_last_row = 8, .content_bottom_row = 8, .expected = false },
        .{ .pending = true, .terminal_reset_commit = true, .resize_reset_commit = false, .tail_kind = null, .occupied_last_row = 4, .content_bottom_row = 8, .expected = false },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            nextResizeBottomAnchorPending(
                case.pending,
                case.terminal_reset_commit,
                case.resize_reset_commit,
                case.tail_kind,
                case.occupied_last_row,
                case.content_bottom_row,
            ),
        );
    }
}

const MaterializedEndpoint = struct {
    visual_offset: u32 = 0,
    visual_rows: u16 = 0,
    flow_len: ?usize = null,
    cursor_row: u16 = 1,
    cursor_col: u16 = 1,
};

pub const TranscriptTransition = struct {
    scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
    document_append: render_engine.frame_scroll_plan.FrameDocumentAppend,
    /// Final rows exist beyond materialized history that this frame could
    /// not release; consuming the transition requests a follow-up frame so
    /// the debt settles promptly instead of waiting for outside activity.
    history_settle_pending: bool = false,
    /// Owns `document_append.bytes` when append preparation allocates wire bytes.
    document_append_bytes: []u8 = &.{},
    resize_reflow_rows: u16 = 0,
    semantic_rows: u32 = 0,
    semantic_progress_rows: u32 = 0,
    recovery_rebase: bool = false,
    recovery_progress_compatible: bool = false,
    recovery_tracks_semantic_progress: bool = false,
    recovery_projection_deferred: bool = false,
    body_disposition: TranscriptBodyDisposition = .paint,
    target_flow: []u8,
    target_flow_owned: bool = true,
    presentation_resume_bytes: []u8 = &.{},
    presentation_pending_wrap: bool = false,
    presentation_valid: bool = false,
    target_cache: std.ArrayList(u8),
    target_cache_unchanged: bool = false,
    target_cache_origin_untrimmed: bool = false,
    folded_summary_indices: []usize,
    target_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
    selection: ViewportSelection,
    visual_offset: u32,
    history_visual_offset: u32,
    source_endpoint_visual_offset: u32 = 0,
    total_visual_rows: u32,
    materialized: MaterializedEndpoint = .{},
    // The exact transcript endpoint if this frame appends no transcript bytes.
    materialized_without_append: MaterializedEndpoint,
    cursor_row: u16,
    cursor_col: u16,
    replaceable_last_line: bool,
    replaceable_start: usize,
    replaceable_row: u16,
    trace_transcript_frame: bool,
    trace_visible_rows: u16,
    measured_history_origin: ?transcript_painter.MeasuredHistoryOrigin = null,
    row_provenance: []transcript_blocks.RowProvenance = &.{},
    normal_buffer_recovery_pending: bool = false,
    history_catchup_pending: bool = false,
    consumed: bool = false,

    pub fn deinit(self: *TranscriptTransition, alloc: Allocator) void {
        if (self.target_flow_owned and self.target_flow.len > 0) alloc.free(self.target_flow);
        if (self.presentation_resume_bytes.len > 0) alloc.free(self.presentation_resume_bytes);
        if (self.document_append_bytes.len > 0) {
            alloc.free(self.document_append_bytes);
        }
        self.target_cache.deinit(alloc);
        if (self.folded_summary_indices.len > 0) alloc.free(self.folded_summary_indices);
        if (self.row_provenance.len > 0) alloc.free(self.row_provenance);
        self.* = undefined;
    }
};

const MaterializedTranscriptProjection = struct {
    raw_flow_exact: bool = false,
    visual_rows: u16 = 0,
};

const TranscriptBlockKind = transcript_blocks.TranscriptBlockKind;
const WalkResult = transcript_blocks.WalkResult;
const walkText = transcript_blocks.walkText;

fn formatDurationCompact(buf: []u8, duration_ms: u64) []const u8 {
    const total_seconds = duration_ms / std.time.ms_per_s;
    if (total_seconds < 60) {
        return std.fmt.bufPrint(buf, "{d}s", .{total_seconds}) catch "0s";
    }
    if (total_seconds < 60 * 60) {
        const minutes = total_seconds / 60;
        const seconds = total_seconds % 60;
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ minutes, seconds }) catch "1m 0s";
    }
    const hours = total_seconds / (60 * 60);
    const minutes = (total_seconds % (60 * 60)) / 60;
    return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ hours, minutes }) catch "1h 00m";
}

fn formatTurnSummaryLine(buf: []u8, summary: types.TurnSummary) []const u8 {
    var turn_buf: [24]u8 = undefined;
    const turn = formatDurationCompact(&turn_buf, summary.turn_duration_ms);
    var out: std.Io.Writer = .fixed(buf);
    out.print("  {s}", .{turn}) catch return "  ";
    activity_status.appendTokenProgressSuffix(&out, summary.token_progress) catch return out.buffered();
    return out.buffered();
}

fn lifecycleEventTurnId(event: types.ToolLifecycleEvent) u64 {
    return switch (event) {
        .provisional => |payload| payload.id.turn_id,
        .authoritative_started => |payload| payload.id.turn_id,
        .progress => |payload| payload.id.turn_id,
        .terminal => |payload| payload.id.turn_id,
        .turn_finished => |payload| payload.turn_id,
    };
}

fn admitLifecycleStart(
    state: *const activity_runtime.ToolActivityState,
    id: types.ToolLifecycleId,
) bool {
    return switch (state.admitStart(id)) {
        .accepted => true,
        .invalid_identity => false,
        .finalized => |fence| blk: {
            debug_trace.logf(
                "ui_activity",
                "lifecycle rejected by finalized fence turn_id={d} fence={d} kind=start",
                .{ id.turn_id, fence },
            );
            break :blk false;
        },
    };
}

fn traceLateLifecycleEvent(id: types.ToolLifecycleId, event_kind: []const u8) void {
    debug_trace.logf(
        "ui_activity",
        "late lifecycle event ignored turn_id={d} kind={s}",
        .{ id.turn_id, event_kind },
    );
}

fn lifecycleStartLine(
    alloc: Allocator,
    tool_name: ?[]const u8,
) ![]u8 {
    var label_buf: [512]u8 = undefined;
    const label = std.fmt.bufPrint(
        &label_buf,
        "● {s}",
        .{tool_name orelse "tool"},
    ) catch "● tool";
    return std.fmt.allocPrint(
        alloc,
        "{s}{s}\n",
        .{ label, ui_render.reset_style },
    );
}

fn lifecycleLine(alloc: Allocator, text: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, text, "\n")) return alloc.dupe(u8, text);
    return std.fmt.allocPrint(alloc, "{s}\n", .{text});
}

const LifecycleMarker = struct {
    style: []const u8,
    glyph: []const u8,
};

fn lifecycleMarker(kind: types.ToolOutcomeKind) LifecycleMarker {
    return switch (kind) {
        .completed => .{ .style = ui_render.system_notice_text_style, .glyph = "●" },
        .failed => .{ .style = ui_render.red_style, .glyph = "●" },
        .denied => .{ .style = ui_render.red_style, .glyph = "⊘" },
        .cancelled => .{ .style = ui_render.warning_style, .glyph = "■" },
        .deferred => .{ .style = ui_render.warning_style, .glyph = "↻" },
    };
}

fn leadingSgrPrefixEnd(text: []const u8) usize {
    var index: usize = 0;
    while (index + 2 <= text.len and text[index] == 0x1b and text[index + 1] == '[') {
        var end = index + 2;
        while (end < text.len and (text[end] < 0x40 or text[end] > 0x7e)) : (end += 1) {}
        if (end == text.len or text[end] != 'm') break;
        index = end + 1;
    }
    return index;
}

fn lifecycleTerminalLine(
    alloc: Allocator,
    kind: types.ToolOutcomeKind,
    summary: []const u8,
) ![]u8 {
    const marker = lifecycleMarker(kind);
    const prefix_end = leadingSgrPrefixEnd(summary);
    const has_marker = std.mem.startsWith(u8, summary[prefix_end..], "●");
    const cancelled = kind == .cancelled;
    const text_style = if (cancelled) ui_render.hint_style else "";
    const text_reset = if (cancelled) ui_render.reset_style else "";
    const follow_up = if (cancelled) " · What can fx do differently?" else "";
    const normalized = if (has_marker)
        try std.fmt.allocPrint(
            alloc,
            "{s}{s}{s}{s}{s}{s}{s}{s}",
            .{
                marker.style,
                marker.glyph,
                ui_render.reset_style,
                summary[0..prefix_end],
                text_style,
                summary[prefix_end + "●".len ..],
                text_reset,
                follow_up,
            },
        )
    else
        try std.fmt.allocPrint(
            alloc,
            "{s}{s}{s} {s}{s}{s}{s}",
            .{
                marker.style,
                marker.glyph,
                ui_render.reset_style,
                text_style,
                summary,
                text_reset,
                follow_up,
            },
        );
    defer alloc.free(normalized);
    return lifecycleLine(alloc, normalized);
}

/// Pure formatter shared by live lifecycle presentation and detached resume
/// projection. The caller owns the returned line.
pub fn formatHistoricalToolStatusLine(
    alloc: Allocator,
    kind: types.ToolOutcomeKind,
    summary: []const u8,
) ![]u8 {
    return lifecycleTerminalLine(alloc, kind, summary);
}

fn lifecycleFallbackLine(
    alloc: Allocator,
    outcome: types.TurnPresentationOutcome,
    was_provisional: bool,
) ![]u8 {
    return switch (outcome) {
        .completed => lifecycleLine(alloc, if (was_provisional)
            "● Tool was not executed"
        else
            "● Tool completion was not reported"),
        .interrupted => lifecycleTerminalLine(alloc, .cancelled, "Tool cancelled"),
        .failed => lifecycleTerminalLine(alloc, .failed, "Tool failed"),
        .paused => lifecycleLine(alloc, "● Tool state preserved for recovery"),
    };
}

fn lifecycleFallbackDisposition(
    outcome: types.TurnPresentationOutcome,
    was_provisional: bool,
) ?transcript_blocks.ToolFallbackDisposition {
    if (outcome != .completed) return null;
    return if (was_provisional) .not_executed else .completion_unreported;
}

fn traceLifecycleFailure(
    event_kind: []const u8,
    turn_id: u64,
    err: anyerror,
) void {
    debug_trace.logf(
        "ui_activity",
        "lifecycle transaction failed kind={s} turn_id={d} err={s}",
        .{ event_kind, turn_id, @errorName(err) },
    );
}

test "formatTurnSummaryLine renders total duration and tokens" {
    var buf: [128]u8 = undefined;
    const line = formatTurnSummaryLine(&buf, .{
        .thinking_duration_ms = 15_000,
        .turn_duration_ms = 130_000,
        .token_progress = .{ .input_tokens = 10_000, .output_tokens = 5_000 },
    });
    try std.testing.expectEqualStrings("  2m 10s (↑10k ↓5k)", line);
}

test "formatTurnSummaryLine renders only total duration without token estimate" {
    var buf: [128]u8 = undefined;
    const line = formatTurnSummaryLine(&buf, .{
        .thinking_duration_ms = 3_000,
        .turn_duration_ms = 3_600_000,
    });
    try std.testing.expectEqualStrings("  1h 00m", line);
}

test "appendTurnSummaryEntry stores classified dim transcript row" {
    const alloc = std.testing.allocator;
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
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendTurnSummaryEntry(alloc, .{
        .thinking_duration_ms = 15_000,
        .turn_duration_ms = 130_000,
        .token_progress = .{ .input_tokens = 10_000, .output_tokens = 5_000 },
    });

    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .raw_bytes);
    try std.testing.expectEqual(RawEntryClass.turn_summary, runtime.entries.items[0].raw_bytes.class);
    try std.testing.expect(std.mem.find(u8, runtime.entries.items[0].raw_bytes.bytes, "  2m 10s (↑10k ↓5k)") != null);

    const rendered = try renderEntriesToBytes(alloc, runtime.entries.items, runtime.layout.cols, .{});
    defer alloc.free(rendered);
    try std.testing.expectEqualStrings("\x1b[38;5;245m  2m 10s (↑10k ↓5k)\x1b[0m\n", rendered);
}

test "recovered route status is transient and final summary stays normal" {
    const alloc = std.testing.allocator;
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
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    runtime.worker_status.set_route_recovery(.{
        .kind = .auto_recovered,
        .succeeded_attempt = 3,
        .attempt_limit = 3,
    }, 1_000);

    switch (runtime.activityProjection()) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqual(activity_runtime.ActivityProjection.Tone.success, thinking.tone);
            try std.testing.expectEqualStrings("✓ recovered · attempt 3/3", thinking.label);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
    try std.testing.expect(!runtime.worker_status.expire_transient(2_499));
    try std.testing.expect(runtime.worker_status.expire_transient(2_500));
    try std.testing.expect(runtime.activityProjection() == .none);

    runtime.worker_status.set_route_recovery(.{
        .kind = .auto_recovered,
        .succeeded_attempt = 3,
        .attempt_limit = 3,
    }, 3_000);
    _ = try runtime.appendTurnSummaryEntry(alloc, .{
        .thinking_duration_ms = 15_000,
        .turn_duration_ms = 130_000,
        .token_progress = .{ .input_tokens = 10_000, .output_tokens = 5_000 },
    });

    try std.testing.expect(runtime.activityProjection() == .none);
    try std.testing.expect(std.mem.find(u8, runtime.entries.items[0].raw_bytes.bytes, ui_render.dim_style) != null);
    try std.testing.expect(std.mem.find(u8, runtime.entries.items[0].raw_bytes.bytes, "  2m 10s (↑10k ↓5k)") != null);
    try std.testing.expect(std.mem.find(u8, runtime.entries.items[0].raw_bytes.bytes, "✓ recovered") == null);
}

test "appendTurnSummaryEntry leaves terminal route status visible" {
    const alloc = std.testing.allocator;
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
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    runtime.worker_status.set_route_recovery(.{ .kind = .content_filter }, 0);
    _ = try runtime.appendTurnSummaryEntry(alloc, .{
        .thinking_duration_ms = 15_000,
        .turn_duration_ms = 130_000,
        .token_progress = .{ .input_tokens = 10_000, .output_tokens = 5_000 },
    });

    switch (runtime.activityProjection()) {
        .turn_thinking => |thinking| try std.testing.expectEqualStrings("⚠ blocked · content filter", thinking.label),
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
    try std.testing.expect(std.mem.find(u8, runtime.entries.items[0].raw_bytes.bytes, "  2m 10s (↑10k ↓5k)") != null);
}

test "full transcript projection opens without folded command output" {
    const alloc = std.testing.allocator;
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
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    try std.testing.expect(try runtime.setTranscriptPresentationDepth(alloc, .full));
    try std.testing.expect(runtime.fullTranscriptActive());
}

test "closing the full transcript resets bounded paging to the tail" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    try std.testing.expect(try runtime.setTranscriptPresentationDepth(alloc, .full));
    runtime.full_transcript_page_anchor = .{ .entry_index = 17 };

    try std.testing.expect(try runtime.setTranscriptPresentationDepth(alloc, .inline_mode));
    try std.testing.expect(std.meta.eql(
        @as(full_transcript_page.Anchor, .tail),
        runtime.full_transcript_page_anchor,
    ));
}

test "live full transcript content requests one frame per revision stride" {
    const alloc = std.testing.allocator;
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
        .full_transcript = .{ .depth = .full },
        .full_transcript_content_revision = 40,
        .command_output_display = .{ .open_command_block = 0 },
        .full_transcript_installed_page = .{
            .source = .{
                .request = .{
                    .content_revision = 40,
                    .cols = 80,
                    .anchor = .tail,
                },
                .range = .{ .start = 0, .end = 0 },
                .styles = .{},
            },
            .projection = .{ .styles = .{} },
        },
    };
    defer runtime.deinit(alloc);

    for (0..full_transcript_page.live_refresh_revision_stride - 1) |_| {
        runtime.markTranscriptContentDirty();
        try std.testing.expect(!runtime.render_requests.hasReason(.transcript));
    }
    runtime.markTranscriptContentDirty();
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
}

test "full transcript viewport snapshot restores reading position" {
    var source = TranscriptRuntime{
        .full_transcript = .{
            .depth = .full,
            .scroll_rows = 37,
            .follow_tail = false,
            .anchor_entry_id = 19,
            .anchor_pending = true,
        },
        .full_transcript_page_anchor = .{ .entry_index = 17 },
    };
    defer source.deinit(std.testing.allocator);
    const snapshot = source.snapshotFullTranscriptViewport();

    var restored = TranscriptRuntime{};
    defer restored.deinit(std.testing.allocator);
    restored.restoreFullTranscriptViewport(snapshot);

    try std.testing.expect(std.meta.eql(
        snapshot,
        restored.snapshotFullTranscriptViewport(),
    ));
    try std.testing.expect(std.meta.eql(
        source.full_transcript_page_anchor,
        restored.full_transcript_page_anchor,
    ));
}

test "full transcript page snapshot retains active command records" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    const entry_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "│ compact output\n",
        .command_output,
    );
    var block = CommandOutputBlock{
        .entry_id = entry_id,
        .total_lines = 1,
        .retained_text_bytes = "ACTIVE_SNAPSHOT_RECORD\n".len,
    };
    try block.lines.append(alloc, .{
        .stream = .stdout,
        .text = try alloc.dupe(u8, "ACTIVE_SNAPSHOT_RECORD\n"),
        .entry_id = entry_id,
        .terminated = true,
    });
    try block.source_entry_ids.append(alloc, entry_id);
    try runtime.command_output_blocks.append(alloc, block);

    var source = try runtime.snapshotFullTranscriptPage(.{
        .content_revision = runtime.full_transcript_content_revision,
        .cols = 80,
        .anchor = .tail,
    }, null, null);
    defer source.deinit(std.heap.c_allocator);

    try std.testing.expectEqual(@as(usize, 1), source.command_blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), source.command_blocks.items[0].lines.items.len);
    try std.testing.expectEqualStrings(
        "ACTIVE_SNAPSHOT_RECORD\n",
        source.command_blocks.items[0].lines.items[0].text,
    );
}

test "full transcript loading projection preserves restored viewport intent" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 12,
            .cols = 60,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .owned_top_row = 1,
        .full_transcript = .{
            .depth = .full,
            .scroll_rows = 56,
            .follow_tail = false,
        },
    };
    defer runtime.deinit(alloc);

    const loading = try runtime.fullTranscriptLoadingProjection(alloc);
    var metrics: Metrics = .{};
    var paint = try runtime.prepareFullTranscriptSurfacePaint(
        alloc,
        &metrics,
        loading,
        null,
        .{ .top = 1, .bottom = 8 },
    );
    defer paint.source.deinit(alloc);
    defer paint.prepared.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 56), runtime.full_transcript.scroll_rows);
    try std.testing.expect(!runtime.full_transcript.follow_tail);
}

test "full transcript page navigation preserves tail intent while the page loads" {
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 12,
            .cols = 60,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .full_transcript = .{ .depth = .full },
    };
    const task = try std.heap.c_allocator.create(full_transcript_worker.Task);
    task.* = .{ .source = .{
        .request = .{
            .content_revision = 0,
            .cols = 60,
            .anchor = .tail,
        },
        .range = .{ .start = 0, .end = 0 },
        .styles = .{},
    } };
    runtime.full_transcript_page_load.task = task;
    defer runtime.deinit(std.testing.allocator);

    runtime.scrollFullTranscript(.up, .page);

    try std.testing.expect(runtime.full_transcript.follow_tail);
    try std.testing.expectEqual(@as(u32, 0), runtime.full_transcript.scroll_rows);
}

test "cancelled full transcript page completion is never installed" {
    var runtime = TranscriptRuntime{ .layout = testLayoutWithRows(12) };
    runtime.layout.cols = 60;
    defer runtime.deinit(std.testing.allocator);

    const task = try std.heap.c_allocator.create(full_transcript_worker.Task);
    task.* = .{
        .source = .{
            .request = .{
                .content_revision = 0,
                .cols = 60,
                .anchor = .tail,
            },
            .range = .{ .start = 0, .end = 0 },
            .styles = .{},
        },
        .projection = .{ .styles = .{} },
    };
    task.cancel_requested.store(true, .release);
    task.done.store(true, .release);
    runtime.full_transcript_page_load.task = task;

    try std.testing.expect(!try runtime.pollFullTranscriptPageLoad());
    try std.testing.expect(runtime.full_transcript_installed_page == null);
}

test "full transcript page boundaries preserve monotonic navigation" {
    const alloc = std.testing.allocator;
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
        .owned_top_row = 1,
        .full_transcript = .{ .depth = .full, .follow_tail = false },
    };
    defer runtime.deinit(alloc);

    for (0..1_000) |_| {
        _ = try runtime.appendRawTranscriptEntryClassified(
            alloc,
            "row\n",
            .unknown_raw,
        );
    }

    const PageWindow = struct {
        fn install(
            current: *TranscriptRuntime,
            request: full_transcript_page.Request,
        ) !*InstalledFullTranscriptPage {
            const range = full_transcript_page.sourceRange(
                request,
                current.entries.items.len,
            );
            if (current.full_transcript_installed_page == null) {
                current.full_transcript_installed_page = .{
                    .source = .{
                        .request = request,
                        .range = range,
                        .styles = .{},
                    },
                    .projection = .{ .styles = .{} },
                };
            }
            const page = &current.full_transcript_installed_page.?;
            page.source.request = request;
            page.source.range = range;
            page.projection.measured_item_rows.clearRetainingCapacity();
            for (range.start..range.end) |entry_index| {
                try page.projection.measured_item_rows.append(std.heap.c_allocator, .{
                    .entry_id = current.entries.items[entry_index].id(),
                    .row = @intCast(entry_index - range.start),
                });
            }
            page.projection.measured_total_rows = @intCast(range.len());
            return page;
        }
    };

    const tail_request = full_transcript_page.Request{
        .content_revision = runtime.full_transcript_content_revision,
        .cols = runtime.layout.cols,
        .anchor = .tail,
    };
    var installed = try PageWindow.install(&runtime, tail_request);
    const tail_start = installed.source.range.start;

    runtime.scrollFullTranscript(.up, .page);
    const older_anchor = switch (runtime.full_transcript_page_anchor) {
        .entry_index => |index| index,
        .tail => return error.TestExpectedOlderPage,
    };
    try std.testing.expectEqual(@as(usize, 743), older_anchor);
    try std.testing.expect(runtime.full_transcript.bookmark_pending);
    try std.testing.expectEqual(
        @as(?u32, runtime.entries.items[older_anchor].id()),
        runtime.full_transcript.bookmark_entry_id,
    );

    var older_request = tail_request;
    older_request.anchor = .{ .entry_index = older_anchor };
    installed = try PageWindow.install(&runtime, older_request);
    var selected = runtime.full_transcript.select_visual_offset(
        installed.projection.measured_total_rows,
        20,
        installed.projection.measured_item_rows.items,
    );
    runtime.full_transcript = selected.state;
    const after_page_up = installed.source.range.start + @as(usize, @intCast(selected.offset));
    try std.testing.expectEqual(@as(usize, 743), after_page_up);
    try std.testing.expect(after_page_up < tail_start);

    const max_offset = installed.projection.measured_total_rows - 20;
    runtime.full_transcript.scroll_rows = max_offset;
    runtime.full_transcript.follow_tail = true;
    const before_page_down = installed.source.range.start + @as(usize, max_offset);
    runtime.scrollFullTranscript(.down, .page);
    const newer_anchor = switch (runtime.full_transcript_page_anchor) {
        .entry_index => |index| index,
        .tail => return error.TestExpectedNewerPage,
    };
    try std.testing.expectEqual(@as(usize, 871), newer_anchor);
    try std.testing.expect(runtime.full_transcript.bookmark_pending);
    try std.testing.expectEqual(
        @as(?u32, runtime.entries.items[newer_anchor].id()),
        runtime.full_transcript.bookmark_entry_id,
    );

    var newer_request = older_request;
    newer_request.anchor = .{ .entry_index = newer_anchor };
    installed = try PageWindow.install(&runtime, newer_request);
    selected = runtime.full_transcript.select_visual_offset(
        installed.projection.measured_total_rows,
        20,
        installed.projection.measured_item_rows.items,
    );
    const after_page_down = installed.source.range.start + @as(usize, @intCast(selected.offset));
    try std.testing.expectEqual(@as(usize, 871), after_page_down);
    try std.testing.expect(after_page_down > before_page_down);
}

test "opening the full transcript leaves compact command projection unchanged" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    var metrics: Metrics = .{};
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "first\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "second\n", true);
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    var compact_before = try runtime.prepareTranscriptSource(alloc, null);
    defer compact_before.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), compact_before.bytes.len);

    _ = try runtime.setTranscriptPresentationDepth(alloc, .full);
    var compact_after = try runtime.prepareTranscriptSource(alloc, null);
    defer compact_after.deinit(alloc);
    try std.testing.expectEqualStrings(compact_before.bytes, compact_after.bytes);
}

test "full transcript staging paints its selected wheel viewport without reselection" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 8,
            .cols = 40,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .owned_top_row = 1,
        .full_transcript = .{
            .depth = .full,
            .scroll_rows = 3,
            .follow_tail = false,
        },
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "row-0\nrow-1\nrow-2\nrow-3\nrow-4\nrow-5\nrow-6\nrow-7\n",
        .unknown_raw,
    );
    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    var metrics: Metrics = .{};
    var staged = try runtime.prepareFullTranscriptSurfacePaint(
        alloc,
        &metrics,
        &projection,
        null,
        .{ .top = 1, .bottom = 4 },
    );
    defer staged.source.deinit(alloc);
    defer staged.prepared.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 3), runtime.full_transcript.scroll_rows);
    try std.testing.expect(!runtime.full_transcript.follow_tail);
    try std.testing.expectEqual(@as(usize, 0), staged.prepared.selection.start_line);
    try std.testing.expect(std.mem.find(u8, staged.source.bytes, "row-3") != null);
    try std.testing.expect(std.mem.find(u8, staged.source.bytes, "row-0") == null);
}

test "compact transcript cache survives navigation and invalidates on content change" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 8,
            .cols = 40,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .owned_top_row = 1,
        .full_transcript = .{ .depth = .full },
    };
    defer runtime.deinit(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "row-0\nrow-1\nrow-2\nrow-3\nrow-4\n",
        .unknown_raw,
    );

    var compact = try runtime.cachedTranscriptSource(alloc);
    defer compact.deinit(alloc);
    const cached_compact = runtime.compact_transcript_source_cache.find(
        runtime.full_transcript_content_revision,
        runtime.layout.cols,
        runtime.has_committed_frame,
    ).?;
    const compact_bytes = cached_compact.bytes.ptr;
    try std.testing.expect(cached_compact.hard_line_starts.len > 0);
    try std.testing.expectEqual(
        cached_compact.hard_line_starts.len,
        cached_compact.transcript_visible_lines.len,
    );
    try std.testing.expectEqual(
        cached_compact.hard_line_starts.len,
        cached_compact.transcript_line_visual_rows.len,
    );
    try std.testing.expectEqual(
        cached_compact.transcript_visible_lines.len,
        compact.transcript_visible_lines.len,
    );
    runtime.markTranscriptDirty();
    var same_compact = try runtime.cachedTranscriptSource(alloc);
    defer same_compact.deinit(alloc);
    try std.testing.expectEqual(compact_bytes, runtime.compact_transcript_source_cache.find(
        runtime.full_transcript_content_revision,
        runtime.layout.cols,
        runtime.has_committed_frame,
    ).?.bytes.ptr);
    runtime.has_committed_frame = true;
    try std.testing.expectEqual(@as(?*TranscriptPreparationSource, null), runtime.compact_transcript_source_cache.find(
        runtime.full_transcript_content_revision,
        runtime.layout.cols,
        runtime.has_committed_frame,
    ));
    var committed_compact = try runtime.cachedTranscriptSource(alloc);
    committed_compact.deinit(alloc);
    runtime.has_committed_frame = false;

    runtime.markTranscriptContentDirty();
    var rebuilt_compact = try runtime.cachedTranscriptSource(alloc);
    defer rebuilt_compact.deinit(alloc);
    try std.testing.expect(compact_bytes != runtime.compact_transcript_source_cache.find(
        runtime.full_transcript_content_revision,
        runtime.layout.cols,
        runtime.has_committed_frame,
    ).?.bytes.ptr);
}

test "cached compact transcript refreshes after streamed assistant text" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 8,
            .cols = 40,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "existing transcript\n",
        .unknown_raw,
    );

    var before = try runtime.cachedTranscriptSource(alloc);
    defer before.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, before.bytes, "streamed assistant") == null);

    var metrics = Metrics{};
    _ = try runtime.streamAssistantChunk(alloc, &metrics, "streamed assistant\n");
    var after = try runtime.cachedTranscriptSource(alloc);
    defer after.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, after.bytes, "streamed assistant") != null);
}

test "clearing a transcript releases compact source and installed page" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 8,
            .cols = 40,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .owned_top_row = 1,
        .full_transcript = .{ .depth = .full },
    };
    defer runtime.deinit(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "old session transcript\n",
        .unknown_raw,
    );

    var compact = try runtime.cachedTranscriptSource(alloc);
    compact.deinit(alloc);
    const content_revision = runtime.full_transcript_content_revision;
    runtime.full_transcript_installed_page = .{
        .source = .{
            .request = .{
                .content_revision = content_revision,
                .cols = runtime.layout.cols,
                .anchor = .tail,
            },
            .range = .{ .start = 0, .end = 0 },
            .styles = .{},
        },
        .projection = .{ .styles = .{} },
    };
    try std.testing.expect(runtime.compact_transcript_source_cache.find(
        content_revision,
        runtime.layout.cols,
        runtime.has_committed_frame,
    ) != null);
    try std.testing.expect(runtime.full_transcript_installed_page != null);

    runtime.clearTranscript(alloc);

    try std.testing.expect(runtime.compact_transcript_source_cache.find(
        content_revision,
        runtime.layout.cols,
        runtime.has_committed_frame,
    ) == null);
    try std.testing.expect(runtime.full_transcript_installed_page == null);
}

test "cached compact transcript preserves pending resume flow" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 8,
            .cols = 40,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "retained tail only\n",
        .unknown_raw,
    );
    runtime.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, "full resume history\nretained tail only\n"),
    );

    var source = try runtime.cachedTranscriptSource(alloc);
    defer source.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, source.bytes, "full resume history") != null);
}

test "startup resume view release preserves later structured notices" {
    const alloc = std.testing.allocator;
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
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const resume_entry_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "cached resume view\n",
        .unknown_raw,
    );
    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "recording",
        .tone = .warning,
        .body = "terminal capture is active",
    });
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "cached resume view") != null);
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "terminal capture is active") != null);

    try std.testing.expect(try runtime.releaseStartupResumeViewEntry(alloc, resume_entry_id));

    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .semantic_notice);
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "cached resume view") == null);
    try std.testing.expect(std.mem.find(u8, runtime.transcript.items, "terminal capture is active") != null);
    try std.testing.expect(!try runtime.releaseStartupResumeViewEntry(alloc, resume_entry_id));
}

const PendingBuildProbe = struct {
    polls: usize = 0,
    pending_after: ?usize = null,

    fn pending(context: *anyopaque) bool {
        const self: *PendingBuildProbe = @ptrCast(@alignCast(context));
        self.polls += 1;
        return if (self.pending_after) |limit| self.polls >= limit else false;
    }
};

test "pending resume source publishes its line index once" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = testLayoutWithRows(8) };
    runtime.layout.cols = 40;
    defer runtime.deinit(alloc);

    var flow: std.ArrayList(u8) = .empty;
    defer flow.deinit(alloc);
    for (0..5_000) |_| try flow.appendSlice(alloc, "resume row\n");
    runtime.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try flow.toOwnedSlice(alloc),
    );
    const flow_ptr = runtime.pendingResumeFlow().ptr;

    var cancelled_probe = PendingBuildProbe{ .pending_after = 1 };
    var cancelled = build_checkpoint.BuildCheckpoint.init(
        &cancelled_probe,
        PendingBuildProbe.pending,
    );
    try std.testing.expectError(
        error.InputPending,
        runtime.pendingResumeSourceInterruptible(alloc, &cancelled),
    );
    try std.testing.expectEqual(@as(usize, 0), runtime.pending_resume_source.?.hard_line_starts.len);
    try std.testing.expectEqual(flow_ptr, runtime.pendingResumeFlow().ptr);

    var build_probe = PendingBuildProbe{};
    var build = build_checkpoint.BuildCheckpoint.init(&build_probe, PendingBuildProbe.pending);
    const source = (try runtime.pendingResumeSourceInterruptible(alloc, &build)).?;
    const source_ptr = source;
    const index_ptr = source.hard_line_starts.ptr;
    try std.testing.expect(source.hard_line_starts.len > 0);

    runtime.layout.cols = 41;
    var resize_probe = PendingBuildProbe{ .pending_after = 2 };
    var resize = build_checkpoint.BuildCheckpoint.init(&resize_probe, PendingBuildProbe.pending);
    try std.testing.expectError(
        error.InputPending,
        runtime.pendingResumeSourceInterruptible(alloc, &resize),
    );
    try std.testing.expectEqual(source_ptr, &runtime.pending_resume_source.?);
    try std.testing.expectEqual(@as(u16, 40), runtime.pending_resume_source.?.cols);
    runtime.layout.cols = 40;

    for (0..3) |_| {
        var reuse_probe = PendingBuildProbe{};
        var reuse = build_checkpoint.BuildCheckpoint.init(&reuse_probe, PendingBuildProbe.pending);
        const reused = (try runtime.pendingResumeSourceInterruptible(alloc, &reuse)).?;
        try std.testing.expectEqual(source_ptr, reused);
        try std.testing.expectEqual(index_ptr, reused.hard_line_starts.ptr);
        try std.testing.expectEqual(@as(usize, 1), reuse_probe.polls);
    }

    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        source,
        .{ .top = 1, .bottom = 4 },
    );
    defer prepared.deinit(alloc);
    try std.testing.expectEqual(source.transcript_visible_lines.ptr, prepared.sourceVisibleLines().ptr);
    try std.testing.expectEqual(source.transcript_line_visual_rows.ptr, prepared.sourceVisualRows().ptr);
    try std.testing.expectEqual(
        source.transcript_visual_row_offsets[source.transcript_visual_row_offsets.len - 1],
        prepared.sourceTotalVisualRows(),
    );
}

test "full transcript staging keeps its selected viewport visible during resize recovery" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 8,
            .cols = 40,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .owned_top_row = 1,
        .full_transcript = .{
            .depth = .full,
            .scroll_rows = 3,
            .follow_tail = false,
        },
        .resize_history_row_delta = 22,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "row-0\nrow-1\nrow-2\nrow-3\nrow-4\nrow-5\nrow-6\nrow-7\n",
        .unknown_raw,
    );
    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    var metrics: Metrics = .{};
    var staged = try runtime.prepareFullTranscriptSurfacePaint(
        alloc,
        &metrics,
        &projection,
        null,
        .{ .top = 1, .bottom = 4 },
    );
    defer staged.source.deinit(alloc);
    defer staged.prepared.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, staged.source.bytes, "row-3") != null);
    try std.testing.expect(std.mem.find(u8, staged.source.bytes, "row-0") == null);
    try std.testing.expectEqual(@as(?i32, 22), runtime.resize_history_row_delta);
    try std.testing.expectEqual(@as(usize, 0), staged.prepared.selection.start_line);
    try std.testing.expect(staged.prepared.selection.last_visible_row >= staged.prepared.selection.top_row);
}

test "auto permission notice is retained without changing compact transcript geometry" {
    const alloc = std.testing.allocator;
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
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;
    const viewport_before = runtime.viewport_top_row;

    _ = try runtime.appendSemanticNotice(alloc, .{
        .topic = "system",
        .tone = .information,
        .body = "Auto agent approved this request: Running command.",
        .visibility = .full_only,
    });

    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expect(runtime.entries.items[0] == .semantic_notice);
    try std.testing.expectEqualStrings("system", runtime.entries.items[0].semantic_notice.topic);
    try std.testing.expectEqual(types.NoticeTone.information, runtime.entries.items[0].semantic_notice.tone);
    try std.testing.expectEqualStrings(
        "Auto agent approved this request: Running command.",
        runtime.entries.items[0].semantic_notice.body,
    );
    try std.testing.expectEqual(types.NoticeVisibility.full_only, runtime.entries.items[0].semantic_notice.visibility);
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript.items.len);
    try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
    try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
    try std.testing.expectEqual(viewport_before, runtime.viewport_top_row);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "● Ran printf done\n",
        .tool_status,
    );
    var compact = try runtime.prepareTranscriptSource(alloc, null);
    defer compact.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "Auto agent approved") == null);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "1 tool call") != null);
    try std.testing.expect(std.mem.find(u8, compact.bytes, "Ran printf done") != null);

    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const full = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        20,
        0,
        null,
    );
    defer alloc.free(full);
    const notice_index = std.mem.find(u8, full, "Auto agent approved") orelse
        return error.TestExpectedAutoPermissionNotice;
    const status_index = std.mem.find(u8, full, "Ran printf done") orelse
        return error.TestExpectedToolStatus;
    try std.testing.expect(notice_index < status_index);
}

fn checkAutoPermissionNoticeAllocationFailures(alloc: Allocator) !void {
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
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);
    const cursor_row_before = runtime.cursor_row;
    const cursor_col_before = runtime.cursor_col;

    _ = runtime.appendSemanticNotice(alloc, .{
        .topic = "system",
        .tone = .information,
        .body = "Auto agent approved this request: Running command.",
        .visibility = .full_only,
    }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), runtime.entries.items.len);
        try std.testing.expectEqual(@as(usize, 0), runtime.transcript.items.len);
        try std.testing.expectEqual(cursor_row_before, runtime.cursor_row);
        try std.testing.expectEqual(cursor_col_before, runtime.cursor_col);
        return switch (err) {
            error.WriteFailed => error.OutOfMemory,
            else => err,
        };
    };

    try std.testing.expectEqual(@as(usize, 1), runtime.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.transcript.items.len);
}

test "auto permission notice write is atomic across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkAutoPermissionNoticeAllocationFailures,
        .{},
    );
}

test "full transcript opening follows the tail instead of consuming its compact anchor" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 8,
            .cols = 40,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "row-0\nrow-1\nrow-2\n",
        .unknown_raw,
    );
    const anchor_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "anchor\n",
        .unknown_raw,
    );
    runtime.full_transcript = runtime.full_transcript.capture_anchor(anchor_id).with_depth(.full);
    _ = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "row-4\nrow-5\nrow-6\nrow-7\n",
        .unknown_raw,
    );

    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const measurement = try full_transcript_screen.measureProjectionInterruptible(
        alloc,
        &projection,
        null,
        runtime.layout.cols,
        null,
    );
    var metrics: Metrics = .{};
    var staged = try runtime.prepareFullTranscriptSurfacePaint(
        alloc,
        &metrics,
        &projection,
        null,
        .{ .top = 1, .bottom = 4 },
    );
    defer staged.source.deinit(alloc);
    defer staged.prepared.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 0), staged.prepared.selection.start_line);
    try std.testing.expectEqual(
        measurement.total_rows -| 4,
        runtime.full_transcript.scroll_rows,
    );
    try std.testing.expect(runtime.full_transcript.follow_tail);
    try std.testing.expect(std.mem.find(u8, staged.source.bytes, "row-7") != null);
    try std.testing.expect(std.mem.find(u8, staged.source.bytes, "anchor") == null);
    try std.testing.expect(std.mem.find(u8, staged.source.bytes, "row-0") == null);
    try std.testing.expect(!runtime.full_transcript.anchor_pending);
}

test "full transcript primary restore repairs resize debt after geometry returns" {
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    runtime.full_transcript_open_content_revision = 7;
    runtime.full_transcript_content_revision = 7;
    runtime.full_transcript_open_cols = 80;
    runtime.full_transcript_open_rows = 24;

    try std.testing.expectEqual(FullTranscriptPrimaryRestore.exact, runtime.fullTranscriptPrimaryRestore());
    runtime.terminal_reset_pending = true;
    try std.testing.expectEqual(FullTranscriptPrimaryRestore.resized, runtime.fullTranscriptPrimaryRestore());
    runtime.full_transcript_content_revision = 8;
    try std.testing.expectEqual(FullTranscriptPrimaryRestore.changed_resized, runtime.fullTranscriptPrimaryRestore());
}

test "full transcript primary restore consumes the pending settled resize" {
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    runtime.render_requests.completeResizeGeometry(true);
    runtime.pending_resize_observation = .{
        .layout = runtime.layout,
        .apply_after_ms = 17,
        .expected_row = null,
        .result = .unavailable,
        .phase = .settle_pending,
    };
    runtime.terminal_reset_pending = true;
    runtime.resize_history_row_delta = 4;

    runtime.repaintRestoredPrimaryTranscriptAfterResize();

    try std.testing.expect(!runtime.render_requests.pending_settled_width_reflow);
    try std.testing.expectEqual(@as(?ResizeObservation, null), runtime.pending_resize_observation);
    try std.testing.expect(!runtime.terminal_reset_pending);
    try std.testing.expectEqual(@as(?i32, null), runtime.resize_history_row_delta);
}

test "full transcript recovery starts at closest visible entry before a hidden anchor" {
    const provenance = [_]transcript_blocks.LineProvenance{
        .{ .entry = .{ .entry_id = 10, .entry_class = .unknown_raw } },
        .{ .entry = .{ .entry_id = 10, .entry_class = .unknown_raw } },
        .block_separator,
        .{ .entry = .{ .entry_id = 14, .entry_class = .tool_status } },
        .{ .entry = .{ .entry_id = 14, .entry_class = .tool_status } },
        .{ .entry = .{ .entry_id = 22, .entry_class = .assistant_turn } },
    };

    try std.testing.expectEqual(
        @as(?usize, 3),
        TranscriptRuntime.fullTranscriptRecoveryPredecessorStartLine(&provenance, 18),
    );
    try std.testing.expectEqual(
        @as(?usize, 0),
        TranscriptRuntime.fullTranscriptRecoveryPredecessorStartLine(&provenance, 10),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        TranscriptRuntime.fullTranscriptRecoveryPredecessorStartLine(&provenance, 9),
    );
}

test "authoritative lifecycle detail is retained by its compact status entry" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    const id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "read-1" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .presentation_group_id = .{ .turn_id = 1, .anchor_step_id = 4 },
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
        .arguments_json = "{\"path\":\"README.md\"}",
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Read README.md" },
        .result = "# README\nfull result",
    } });

    const entry_id = runtime.toolActivityRecord(id).?.entry_id;
    const detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqual(types.ToolActivityKind.read, detail.activity_kind.?);
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", detail.arguments_json.?);
    try std.testing.expectEqualStrings("# README\nfull result", detail.result.?);
    try std.testing.expectEqual(@as(u64, 1), detail.lifecycle_id.?.turn_id);
    try std.testing.expectEqualStrings("read-1", detail.lifecycle_id.?.call_id);
    try std.testing.expect(detail.lifecycle_id.?.call_id.ptr != id.call_id.ptr);
    try std.testing.expectEqual(
        types.ToolPresentationGroupId{ .turn_id = 1, .anchor_step_id = 4 },
        detail.presentation_group_id.?,
    );

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, source.bytes, "Read README.md") != null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "input") == null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "full result") == null);
}

test "paused tool turn can resume the same lifecycle identity before finalization" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const id = types.ToolLifecycleId{ .turn_id = 41, .call_id = "resume-tool" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = id.turn_id,
        .outcome = .paused,
    } });
    try runtime.finishLifecycleBatch(alloc);

    try std.testing.expectEqual(@as(u64, 0), runtime.finalizedToolTurnWatermark());
    try std.testing.expect(runtime.toolActivityRecord(id) == null);
    var paused_source = try runtime.prepareTranscriptSource(alloc, null);
    defer paused_source.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        paused_source.bytes,
        "Tool state preserved for recovery",
    ) != null);

    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    try std.testing.expect(runtime.toolActivityRecord(id) != null);
    try std.testing.expectEqual(@as(usize, 1), runtime.activeToolActivityCount());

    _ = try runtime.applyToolLifecycle(alloc, .{ .turn_finished = .{
        .turn_id = id.turn_id,
        .outcome = .completed,
    } });
    try runtime.finishLifecycleBatch(alloc);
    try std.testing.expectEqual(id.turn_id, runtime.finalizedToolTurnWatermark());
}

test "provisional lifecycle owns semantic detail before authoritative reconciliation" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const id = types.ToolLifecycleId{ .turn_id = 7, .call_id = "provisional-command" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = id,
        .tool_name = null,
        .activity_kind = .command,
    } });

    const entry_id = runtime.toolActivityRecord(id).?.entry_id;
    const initial_detail = runtime.toolDetailForEntry(entry_id);
    try std.testing.expect(initial_detail != null);
    try std.testing.expectEqualStrings("tool", initial_detail.?.tool_name);
    try std.testing.expectEqual(types.ToolActivityKind.command, initial_detail.?.activity_kind.?);
    try std.testing.expectEqual(@as(u64, 7), initial_detail.?.lifecycle_id.?.turn_id);
    try std.testing.expectEqualStrings("provisional-command", initial_detail.?.lifecycle_id.?.call_id);
    try std.testing.expect(initial_detail.?.lifecycle_id.?.call_id.ptr != id.call_id.ptr);

    _ = try runtime.applyToolLifecycle(alloc, .{ .provisional = .{
        .id = id,
        .tool_name = "run_command",
        .activity_kind = .command,
    } });
    const updated_detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqualStrings("run_command", updated_detail.tool_name);
    try std.testing.expectEqual(@as(usize, 1), runtime.tool_details.items.len);
}

test "nonzero command remains Ran in the current compact projection" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    const id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "exit-7" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "terminal",
        .activity_kind = .command,
        .arguments_json = "{\"action\":\"exec\",\"command\":\"false\"}",
    } });
    try std.testing.expect(runtime.toolActivityRecord(id).?.captured_command);
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Ran false" },
        .result_memory = .{ .command_process_presentation = .{ .exit_code = 7 } },
    } });

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, source.bytes, "Ran false") != null);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source.bytes, "│ exit code 7"));
    try std.testing.expect(std.mem.find(u8, source.bytes, "Failed") == null);
}

test "terminal lifecycle records distinguish captured exec from durable actions" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);
    const exec_id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "exec" };
    const start_id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "start" };

    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = exec_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "terminal",
        .activity_kind = .command,
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf exec\"}",
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = start_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "terminal",
        .activity_kind = .command,
        .arguments_json = "{\"action\":\"start\",\"command\":\"printf start\"}",
    } });

    try std.testing.expect(runtime.toolActivityRecord(exec_id).?.captured_command);
    try std.testing.expect(!runtime.toolActivityRecord(start_id).?.captured_command);
}

test "nonzero streamed command reuses its active output block" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    const id = types.ToolLifecycleId{ .turn_id = 2, .call_id = "streamed-exit-7" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "terminal",
        .activity_kind = .command,
        .arguments_json = "{\"action\":\"exec\",\"command\":\"printf lines; exit 7\"}",
    } });
    const started_entry_id = runtime.toolActivityRecord(id).?.entry_id;
    try std.testing.expect(runtime.toolDetailForEntry(started_entry_id).?.isCapturedCommand());
    var metrics: Metrics = .{};
    try runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        id,
        .stdout,
        "line-1\nline-2\nline-3\nline-4\nline-5\nline-6\n",
        true,
    );
    try std.testing.expect(runtime.toolDetailForEntry(started_entry_id).?.isCapturedCommand());
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Ran printf lines; exit 7" },
        .result_memory = .{ .command_process_presentation = .{ .exit_code = 7 } },
    } });

    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    try runtime.flushCommandOutputSummaryForLifecycle(
        alloc,
        &metrics,
        styles,
        id,
        true,
    );

    const block = runtime.command_output_blocks.items[0];
    const status_entry_id = runtime.toolActivityRecord(id).?.entry_id;
    try std.testing.expect(runtime.toolDetailForEntry(status_entry_id).?.isCapturedCommand());
    try std.testing.expectEqual(
        block.entry_id,
        runtime.toolDetailForEntry(status_entry_id).?.command_output_entry_id,
    );
    try std.testing.expect(command_output_runtime.processPresentationForBlock(&runtime, block) != null);
    var projection = try command_output_runtime.renderCompactCommandOutputWithProcessPresentation(
        alloc,
        block,
        .{ .styles = styles },
        80,
        command_output_runtime.processPresentationForBlock(&runtime, block),
    );
    defer projection.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, command_output_runtime.compact_output_row_limit + 1),
        std.mem.count(u8, projection.bytes.items, "\n") + 1,
    );
    try std.testing.expect(std.mem.find(u8, projection.bytes.items, "│ line-4") != null);
    try std.testing.expect(std.mem.find(u8, projection.bytes.items, "│ line-5") == null);
    try std.testing.expect(std.mem.find(u8, projection.bytes.items, "│ … 2 lines more (ctrl o to view)") != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, projection.bytes.items, "│ exit code 7"),
    );

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, source.bytes, "Ran printf lines; exit 7") != null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "Failed") == null);
}

test "compact run command group stays width safe after resize" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 24,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    const id = types.ToolLifecycleId{ .turn_id = 3, .call_id = "long-command-header" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"printf a deliberately long command preview\"}",
    } });
    var metrics: Metrics = .{};
    try runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        id,
        .stdout,
        "payload\n",
        true,
    );
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{
            .kind = .completed,
            .summary = "Ran printf a deliberately long command preview that exceeds both narrow and normal transcript widths without losing its typed command identity",
        },
    } });
    try runtime.flushCommandOutputSummaryForLifecycle(
        alloc,
        &metrics,
        styles,
        id,
        true,
    );

    const status_entry_id = runtime.toolActivityRecord(id).?.entry_id;
    const output_entry_id = runtime.command_output_blocks.items[0].entry_id.?;
    for ([_]u16{ 24, 80 }) |cols| {
        runtime.layout.cols = cols;
        var source = try runtime.prepareTranscriptSource(alloc, null);
        defer source.deinit(alloc);

        var status_line: ?usize = null;
        var output_line: ?usize = null;
        var status_line_count: usize = 0;
        for (source.line_provenance, 0..) |provenance, line_index| {
            switch (provenance) {
                .entry => |entry| {
                    if (entry.entry_id == status_entry_id) {
                        if (status_line == null) status_line = line_index;
                        status_line_count += 1;
                    }
                    if (entry.entry_id == output_entry_id and output_line == null) {
                        output_line = line_index;
                    }
                },
                else => {},
            }
        }
        try std.testing.expectEqual(@as(usize, 2), status_line_count);
        try std.testing.expect(output_line == null);

        try std.testing.expect(status_line != null);
        var lines = std.mem.splitScalar(u8, source.bytes, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
        }
        try std.testing.expect(std.mem.find(u8, source.bytes, "…") != null);
    }
}

fn checkToolDetailResultReplacementAllocationFailures(alloc: Allocator) !void {
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    var tool_name: ?[]u8 = try alloc.dupe(u8, "read_file");
    errdefer if (tool_name) |value| alloc.free(value);
    var previous_result: ?[]u8 = try alloc.dupe(u8, "previous result");
    errdefer if (previous_result) |value| alloc.free(value);
    var previous_artifact: ?[]u8 = try alloc.dupe(u8, "fx-command-previous.log");
    errdefer if (previous_artifact) |value| alloc.free(value);
    try runtime.tool_details.append(alloc, .{
        .entry_id = 1,
        .tool_name = tool_name.?,
        .result = previous_result.?,
        .command_artifact_handle = previous_artifact.?,
    });
    tool_name = null;
    previous_result = null;
    previous_artifact = null;

    runtime.updateToolDetailTerminal(
        alloc,
        1,
        null,
        "read_file",
        .read,
        .completed,
        "replacement result",
        null,
        "fx-command-replacement.log",
        null,
    ) catch |err| {
        try std.testing.expectEqualStrings(
            "previous result",
            runtime.toolDetailForEntry(1).?.result.?,
        );
        try std.testing.expectEqualStrings(
            "fx-command-previous.log",
            runtime.toolDetailForEntry(1).?.command_artifact_handle.?,
        );
        return err;
    };
    try std.testing.expectEqualStrings(
        "replacement result",
        runtime.toolDetailForEntry(1).?.result.?,
    );
    try std.testing.expectEqualStrings(
        "fx-command-replacement.log",
        runtime.toolDetailForEntry(1).?.command_artifact_handle.?,
    );
}

test "tool detail result replacement preserves the prior allocation on failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkToolDetailResultReplacementAllocationFailures,
        .{},
    );
}

test "historical tool detail attaches to the exact replayed status entry" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    var metrics: Metrics = .{};
    const entry_id = try runtime.writeCompletedToolStatusReturningEntryId(
        alloc,
        &metrics,
        .completed,
        "Read README.md",
        true,
    );
    try runtime.attachHistoricalToolDetail(
        alloc,
        entry_id,
        .{ .id = "replayed-read", .name = "read_file", .arguments_json = "{\"path\":\"README.md\"}" },
        .read,
        .{
            .tool_call_id = @constCast("replayed-read"),
            .tool_name = @constCast("read_file"),
            .status = .success,
            .output = @constCast("# README\nfull replayed result"),
            .output_bytes = 29,
            .stored_output_bytes = 29,
            .created_at_ms = 123,
        },
    );

    const detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqualStrings("{\"path\":\"README.md\"}", detail.arguments_json.?);
    try std.testing.expectEqualStrings("# README\nfull replayed result", detail.result.?);
    try std.testing.expectEqual(types.ToolOutcomeKind.completed, detail.outcome.?);
    try std.testing.expectEqual(@as(i64, 123), detail.created_at_ms);
}

test "historical deferred tool detail keeps the call without result evidence" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    var metrics: Metrics = .{};
    const entry_id = try runtime.writeCompletedToolStatusReturningEntryId(
        alloc,
        &metrics,
        .deferred,
        "Context updated: Running cat nested/input.txt",
        true,
    );
    try runtime.attachHistoricalToolDetail(
        alloc,
        entry_id,
        .{
            .id = "deferred-command",
            .name = "run_command",
            .arguments_json = "{\"command\":\"cat nested/input.txt\"}",
        },
        .command,
        .{
            .tool_call_id = @constCast("deferred-command"),
            .tool_name = @constCast("run_command"),
            .status = .failure,
            .output = @constCast(types.context_deferred_tool_result_output),
            .output_handle = @constCast("should-not-be-exposed.txt"),
            .preview = @constCast("should not be exposed"),
            .output_bytes = types.context_deferred_tool_result_output.len,
            .stored_output_bytes = types.context_deferred_tool_result_output.len,
            .truncated = true,
            .command_output_replay = .unavailable,
            .command_process_presentation = .{ .exit_code = 7 },
        },
    );

    const detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqualStrings("run_command", detail.tool_name);
    try std.testing.expectEqualStrings("{\"command\":\"cat nested/input.txt\"}", detail.arguments_json.?);
    try std.testing.expectEqual(types.ToolOutcomeKind.deferred, detail.outcome.?);
    try std.testing.expect(detail.result == null);
    try std.testing.expect(detail.result_handle == null);
    try std.testing.expect(detail.command_artifact_handle == null);
    try std.testing.expect(detail.command_output_replay == null);
    try std.testing.expect(detail.command_process_presentation == null);
    try std.testing.expect(detail.command_output_entry_id == null);

    const legacy_entry_id = try runtime.writeCompletedToolStatusReturningEntryId(
        alloc,
        &metrics,
        .denied,
        "Not executed: Reading stale.txt",
        true,
    );
    try runtime.attachHistoricalToolDetail(
        alloc,
        legacy_entry_id,
        .{
            .id = "legacy-deferred-read",
            .name = "read_file",
            .arguments_json = "{\"path\":\"stale.txt\"}",
        },
        .read,
        .{
            .tool_call_id = @constCast("legacy-deferred-read"),
            .tool_name = @constCast("read_file"),
            .status = .failure,
            .output = @constCast(types.deferred_tool_result_output),
            .output_bytes = types.deferred_tool_result_output.len,
            .stored_output_bytes = types.deferred_tool_result_output.len,
        },
    );
    const legacy_detail = runtime.toolDetailForEntry(legacy_entry_id).?;
    try std.testing.expectEqual(types.ToolOutcomeKind.denied, legacy_detail.outcome.?);
    try std.testing.expect(legacy_detail.result == null);

    const failed_entry_id = try runtime.writeCompletedToolStatusReturningEntryId(
        alloc,
        &metrics,
        .failed,
        "Failed printf failure",
        true,
    );
    try runtime.attachHistoricalToolDetail(
        alloc,
        failed_entry_id,
        .{
            .id = "failed-command",
            .name = "run_command",
            .arguments_json = "{\"command\":\"printf failure; exit 7\"}",
        },
        .command,
        .{
            .tool_call_id = @constCast("failed-command"),
            .tool_name = @constCast("run_command"),
            .status = .failure,
            .output = @constCast("ordinary failure"),
            .output_handle = @constCast("ordinary-failure.txt"),
            .output_bytes = 16,
            .stored_output_bytes = 16,
        },
    );

    const failed_detail = runtime.toolDetailForEntry(failed_entry_id).?;
    try std.testing.expectEqual(types.ToolOutcomeKind.failed, failed_detail.outcome.?);
    try std.testing.expectEqualStrings("ordinary failure", failed_detail.result.?);
    try std.testing.expectEqualStrings("ordinary-failure.txt", failed_detail.result_handle.?);
}

test "historical permission denial keeps denied outcome without internal result detail" {
    const alloc = std.testing.allocator;
    const denial_output = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"auto_denied\"}}";
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    var metrics: Metrics = .{};
    const entry_id = try runtime.writeCompletedToolStatusReturningEntryId(
        alloc,
        &metrics,
        .denied,
        "Denied by auto agent pwd",
        true,
    );
    try runtime.attachHistoricalToolDetail(
        alloc,
        entry_id,
        .{
            .id = "denied-command",
            .name = "terminal",
            .arguments_json = "{\"action\":\"exec\",\"command\":\"pwd\"}",
        },
        .command,
        .{
            .tool_call_id = @constCast("denied-command"),
            .tool_name = @constCast("terminal"),
            .status = .failure,
            .output = @constCast(denial_output),
            .output_bytes = denial_output.len,
            .stored_output_bytes = denial_output.len,
        },
    );

    const detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqual(types.ToolOutcomeKind.denied, detail.outcome.?);
    try std.testing.expect(detail.result == null);
    try std.testing.expect(detail.result_handle == null);
    try std.testing.expect(detail.command_output_entry_id == null);
}

test "historical command detail keeps artifact handles after command block attaches" {
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
    const stored_result = "exit_code=0\n<stdout>\nRESUMED_EXACT_RESULT\n</stdout>\n";
    const result_handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "replayed-command",
        "run_command",
        stored_result,
    );
    defer alloc.free(result_handle);
    defer result_store.deleteManaged(&capability, result_handle) catch {};

    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    const raw_preview = "exit_code=0\ntruncated=true\nstdout_bytes=21\nstderr_bytes=0\noutput_file=/tmp/fx-command-replayed.log\n<stdout>RESUMED_EXACT_RESULT\n</stdout>";
    const raw_result = try std.fmt.allocPrint(
        alloc,
        "<tool_result_preview handle=\"{s}\" stored_bytes=\"{d}\">\n{s}\n</tool_result_preview>\n" ++
            "<tool_result_handle>{s}</tool_result_handle>",
        .{ result_handle, stored_result.len, raw_preview, result_handle },
    );
    defer alloc.free(raw_result);
    var metrics: Metrics = .{};
    const entry_id = try runtime.writeCompletedToolStatusReturningEntryId(
        alloc,
        &metrics,
        .completed,
        "Ran printf restored",
        true,
    );
    try runtime.attachHistoricalToolDetail(
        alloc,
        entry_id,
        .{ .id = "replayed-command", .name = "run_command", .arguments_json = "{\"command\":\"printf restored\"}" },
        .command,
        .{
            .tool_call_id = @constCast("replayed-command"),
            .tool_name = @constCast("run_command"),
            .status = .success,
            .output = @constCast(raw_result),
            .output_handle = result_handle,
            .preview = @constCast(raw_preview),
            .output_bytes = stored_result.len,
            .stored_output_bytes = stored_result.len,
            .truncated = true,
        },
    );

    runtime.attachHistoricalCommandOutput(alloc, entry_id);

    const fallback_detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expect(fallback_detail.command_output_entry_id == null);
    try std.testing.expectEqualStrings(raw_result, fallback_detail.result.?);
    try std.testing.expectEqualStrings(result_handle, fallback_detail.result_handle.?);
    try std.testing.expectEqualStrings("fx-command-replayed.log", fallback_detail.command_artifact_handle.?);

    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "RESUMED_EXACT_RESULT\n",
        true,
    );
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);

    runtime.attachHistoricalCommandOutput(alloc, entry_id);

    const command_detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expect(command_detail.command_output_entry_id != null);
    try std.testing.expectEqualStrings(raw_result, command_detail.result.?);
    try std.testing.expectEqualStrings(result_handle, command_detail.result_handle.?);
    try std.testing.expectEqualStrings("fx-command-replayed.log", command_detail.command_artifact_handle.?);

    runtime.full_transcript.depth = .full;
    var projection = try runtime.buildFullTranscriptProjection(alloc, null);
    defer projection.deinit(alloc);
    const full_source = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        alloc,
        &projection,
        &capability,
        runtime.layout.cols,
        10,
        0,
        null,
    );
    defer alloc.free(full_source);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, full_source, "RESUMED_EXACT_RESULT"),
    );
    try std.testing.expect(std.mem.find(u8, full_source, "exit_code=0") == null);
    try std.testing.expect(std.mem.find(u8, full_source, "<stdout>") == null);
    try std.testing.expect(std.mem.find(u8, full_source, "</stdout>") == null);
}

test "historical nonzero command keeps replay ownership outside compact sidebands" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    var metrics: Metrics = .{};
    const entry_id = try runtime.writeCompletedToolStatusReturningEntryId(
        alloc,
        &metrics,
        .completed,
        "Ran false",
        true,
    );
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "one\ntwo\nthree\nfour\nfive\nsix\n",
        true,
    );
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);
    const command_output_entry_id = runtime.latestCommandOutputEntryId().?;

    const replay_handle = "fx-command-replay-historical.bin";
    try runtime.attachHistoricalToolDetailAfterCommandOutput(
        alloc,
        entry_id,
        .{ .id = "historical-exit", .name = "run_command", .arguments_json = "{\"command\":\"false\"}" },
        .command,
        .{
            .tool_call_id = @constCast("historical-exit"),
            .tool_name = @constCast("run_command"),
            .status = .failure,
            .output = @constCast("exit_code=7\n(no output)\n"),
            .output_bytes = 24,
            .stored_output_bytes = 24,
            .command_output_replay = .{ .available = .{
                .handle = replay_handle,
                .framed_bytes = 123,
            } },
            .command_process_presentation = .{ .exit_code = 7 },
        },
    );
    runtime.attachHistoricalCommandOutput(alloc, entry_id);

    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    const detail = runtime.toolDetailForEntry(entry_id).?;
    try std.testing.expectEqual(types.ToolOutcomeKind.completed, detail.outcome.?);
    try std.testing.expectEqual(command_output_entry_id, detail.command_output_entry_id.?);
    try std.testing.expectEqual(
        types.CommandProcessPresentation{ .exit_code = 7 },
        detail.command_process_presentation.?,
    );
    const replay = detail.command_output_replay.?;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedReplay,
    };
    try std.testing.expectEqualStrings(replay_handle, descriptor.handle);
    try std.testing.expect(descriptor.handle.ptr != replay_handle.ptr);

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, source.bytes, "│ "));
    try std.testing.expect(std.mem.find(u8, source.bytes, "Ran false") != null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "│ exit code 7") == null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "│ … 2 lines more") == null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "│ five") == null);
    try std.testing.expect(std.mem.find(u8, source.bytes, "Failed") == null);
}

test "historical command detail ignores artifact-shaped command output" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);

    const raw_result = "exit_code=0\n<stdout>\noutput_file=/tmp/fx-command-other.log\n</stdout>\n";
    var metrics: Metrics = .{};
    const entry_id = try runtime.writeCompletedToolStatusReturningEntryId(
        alloc,
        &metrics,
        .completed,
        "Ran printf artifact-shaped-output",
        true,
    );
    try runtime.attachHistoricalToolDetail(
        alloc,
        entry_id,
        .{ .id = "replayed-command", .name = "run_command", .arguments_json = "{\"command\":\"printf artifact-shaped-output\"}" },
        .command,
        .{
            .tool_call_id = @constCast("replayed-command"),
            .tool_name = @constCast("run_command"),
            .status = .success,
            .output = @constCast(raw_result),
            .output_bytes = raw_result.len,
            .stored_output_bytes = raw_result.len,
        },
    );

    try std.testing.expect(runtime.toolDetailForEntry(entry_id).?.command_artifact_handle == null);
}

test "full transcript retains previews when stored result handles cannot be opened" {
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
    const handle = try result_store.storeLargeResultManaged(
        alloc,
        &capability,
        "detail",
        "read_file",
        "FULL_TRANSCRIPT_SIDECAR_BODY\n",
    );
    defer alloc.free(handle);
    defer result_store.deleteManaged(&capability, handle) catch {};

    var runtime = TranscriptRuntime{};
    defer runtime.deinit(alloc);
    try runtime.tool_details.append(alloc, .{
        .entry_id = 1,
        .tool_name = try alloc.dupe(u8, "read_file"),
        .result = try alloc.dupe(u8, "preview"),
        .result_handle = try alloc.dupe(u8, handle),
    });
    try runtime.tool_details.append(alloc, .{
        .entry_id = 2,
        .tool_name = try alloc.dupe(u8, "read_file"),
        .result_handle = try alloc.dupe(u8, "missing-result.txt"),
    });

    try std.testing.expect(runtime.hasStoredResultDetails());
    try std.testing.expectEqualStrings(
        "preview",
        runtime.toolDetailForEntry(1).?.result.?,
    );
    try std.testing.expect(runtime.toolDetailForEntry(2).?.result == null);
}

test "command terminal detail owns the consolidated command output entry" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    const id = types.ToolLifecycleId{ .turn_id = 9, .call_id = "command-9" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"printf demo\"}",
    } });
    var metrics: Metrics = .{};
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, id, .stdout, "first\n", true);
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, id, .stdout, "second\n", true);
    try runtime.flushCommandOutputSummaryForLifecycle(
        alloc,
        &metrics,
        styles,
        id,
        true,
    );
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Ran printf demo" },
        .command_artifact_handle = "fx-command-live.log",
    } });

    const status_entry_id = runtime.toolActivityRecord(id).?.entry_id;
    const detail = runtime.toolDetailForEntry(status_entry_id).?;
    try std.testing.expectEqual(runtime.command_output_blocks.items[0].entry_id, detail.command_output_entry_id);
    try std.testing.expectEqualStrings("fx-command-live.log", detail.command_artifact_handle.?);
}

test "late command output reopens its completed lifecycle block" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);
    var metrics: Metrics = .{};
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    const id = types.ToolLifecycleId{ .turn_id = 7, .call_id = "late-output" };

    try runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        id,
        .stdout,
        "one\ntwo\nthree\nfour\nfive\nsix\n",
        true,
    );
    try runtime.flushCommandOutputSummaryForLifecycle(
        alloc,
        &metrics,
        styles,
        id,
        true,
    );
    const entry_id = runtime.command_output_blocks.items[0].entry_id.?;

    try runtime.writeCommandOutputChunkForLifecycle(
        alloc,
        &metrics,
        styles,
        id,
        .stdout,
        "seven\neight\n",
        true,
    );

    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
    try std.testing.expectEqual(entry_id, runtime.command_output_blocks.items[0].entry_id.?);
    try std.testing.expectEqual(@as(usize, 8), runtime.command_output_blocks.items[0].total_lines);
    runtime.resetCommandOutputDisplay(alloc, "worker inactive");
    try std.testing.expectEqual(@as(usize, 1), runtime.command_output_blocks.items.len);
}

test "command terminal detail resolves split command output source rows" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    const id = types.ToolLifecycleId{ .turn_id = 9, .call_id = "command-split" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"printf demo\"}",
    } });

    var metrics: Metrics = .{};
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, id, .stdout, "first\n", true);
    _ = try runtime.appendRawTranscriptEntryClassified(alloc, "intervening\n", .unknown_raw);
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, id, .stdout, "second\n", true);
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, id, true);
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Ran printf demo" },
    } });

    const status_entry_id = runtime.toolActivityRecord(id).?.entry_id;
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 2), block.source_entry_ids.items.len);
    try std.testing.expectEqual(status_entry_id, runtime.detailEntryIdForCommandOutputSource(block.source_entry_ids.items[0]).?);
    try std.testing.expectEqual(status_entry_id, runtime.detailEntryIdForCommandOutputSource(block.source_entry_ids.items[1]).?);
}

test "command output consolidation preserves current compact ownership" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 32,
        .cols = 100,
        .content_bottom = 28,
        .divider_top_row = 29,
        .input_row = 30,
        .divider_bottom_row = 31,
        .hint_row = 32,
    } };
    defer runtime.deinit(alloc);

    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    const id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "streaming-command" };
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"stream\"}",
    } });
    const status_entry_id = runtime.toolActivityRecord(id).?.entry_id;

    var metrics: Metrics = .{};
    for (0..80) |index| {
        var line: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "STREAM {d:0>3}\n", .{index + 1});
        try runtime.writeCommandOutputChunkForLifecycle(
            alloc,
            &metrics,
            styles,
            id,
            .stdout,
            text,
            true,
        );
    }

    var live = try runtime.prepareTranscriptSourceOmittingEntry(alloc, status_entry_id);
    defer live.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), live.bytes.len);

    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, id, true);

    var compact = try runtime.prepareTranscriptSource(alloc, null);
    defer compact.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, compact.bytes, "STREAM 001") == null);
    try std.testing.expect(std.mem.indexOf(u8, compact.bytes, "1 tool call") != null);

    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Ran stream" },
    } });
    var completed = try runtime.prepareTranscriptSource(alloc, null);
    defer completed.deinit(alloc);

    const status_pos = std.mem.indexOf(u8, completed.bytes, "Ran stream") orelse
        return error.MissingCommandStatus;
    try std.testing.expect(std.mem.indexOf(u8, completed.bytes, "STREAM 001") == null);
    try std.testing.expect(status_pos < completed.bytes.len);

    const output_entry_id = runtime.command_output_blocks.items[0].entry_id.?;
    const output_index = entryIndex(&runtime, output_entry_id).?;
    const status_index = entryIndex(&runtime, status_entry_id).?;
    try std.testing.expect(status_index < output_index);
}

fn entryIndex(runtime: *const TranscriptRuntime, entry_id: u32) ?usize {
    for (runtime.entries.items, 0..) |entry, index| {
        if (entry.id() == entry_id) return index;
    }
    return null;
}

test "command output records span callbacks and keep first-byte ownership" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 40,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    var metrics: Metrics = .{};
    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "hel",
        true,
    );
    const first_entry_id = runtime.command_output_blocks.items[0].lines.items[0].entry_id.?;
    const intervening_entry_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "intervening\n",
        .unknown_raw,
    );
    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "lo\nnext\n",
        true,
    );

    const block = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 2), block.lines.items.len);
    try std.testing.expectEqualStrings("hello", block.lines.items[0].text);
    try std.testing.expectEqualStrings("next", block.lines.items[1].text);
    const second_entry_id = block.lines.items[1].entry_id.?;
    try std.testing.expect(entryIndex(&runtime, first_entry_id).? < entryIndex(&runtime, intervening_entry_id).?);
    try std.testing.expect(entryIndex(&runtime, intervening_entry_id).? < entryIndex(&runtime, second_entry_id).?);
}

test "split utf8 keeps cross-stream first-byte ownership and pure ansi is pruned" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 40,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    var metrics: Metrics = .{};

    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "\xe2\x82", true);
    const stdout_entry_id = runtime.command_output_blocks.items[0].lines.items[0].entry_id.?;
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stderr, "err\n", true);
    const stderr_entry_id = runtime.command_output_blocks.items[0].lines.items[1].entry_id.?;
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "\xac\n", true);
    try runtime.writeCommandOutputChunk(alloc, &metrics, styles, .stdout, "\x1b[31m", true);
    try runtime.flushCommandOutputSummary(alloc, &metrics, styles, true);

    const block = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 2), block.lines.items.len);
    try std.testing.expectEqualStrings("€", block.lines.items[0].text);
    try std.testing.expectEqualStrings("err", block.lines.items[1].text);
    try std.testing.expectEqual(@as(usize, 0), block.lines.items[0].record_ordinal);
    try std.testing.expectEqual(@as(usize, 1), block.lines.items[1].record_ordinal);
    try std.testing.expect(entryIndex(&runtime, stdout_entry_id).? < entryIndex(&runtime, stderr_entry_id).?);
}

test "prepared canonical command mutation stays bounded across twenty four thousand records" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 72,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    var metrics: Metrics = .{};
    for (0..24_000) |_| {
        try runtime.writeCommandOutputChunk(
            alloc,
            &metrics,
            styles,
            .stdout,
            "record\n",
            true,
        );
        try std.testing.expect(
            runtime.retainedStructuredBytesForCommandOutput() <=
                runtime.max_retained_transcript_bytes,
        );
    }
    const block = runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 24_000), block.total_lines);
    try std.testing.expect(block.retention_overflow);
    try std.testing.expect(block.lines.items.len < block.total_lines);
    for (block.lines.items, 0..) |line, record_ordinal| {
        try std.testing.expectEqual(record_ordinal, line.record_ordinal);
    }
}

test "oversized open command record stops growing after overflow" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 72,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .max_retained_transcript_bytes = 8 * 1024,
    };
    defer runtime.deinit(alloc);
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    var metrics: Metrics = .{};
    var fragment: [4096]u8 = undefined;
    @memset(&fragment, 'x');
    var retained_after_overflow: ?usize = null;
    var source_entry_id: ?u32 = null;
    for (0..256) |_| {
        try runtime.writeCommandOutputChunk(
            alloc,
            &metrics,
            styles,
            .stdout,
            &fragment,
            true,
        );
        const block = runtime.command_output_blocks.items[0];
        if (source_entry_id == null) source_entry_id = block.lines.items[0].entry_id;
        try std.testing.expectEqual(source_entry_id, block.lines.items[0].entry_id);
        try std.testing.expect(
            runtime.retainedStructuredBytesForCommandOutput() <=
                runtime.max_retained_transcript_bytes,
        );
        if (block.retention_overflow) {
            if (retained_after_overflow) |retained| {
                try std.testing.expectEqual(retained, block.retained_text_bytes);
            } else {
                retained_after_overflow = block.retained_text_bytes;
            }
        }
    }
    try std.testing.expect(retained_after_overflow != null);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try runtime.writeCommandOutputChunk(
        failing.allocator(),
        &metrics,
        styles,
        .stdout,
        &fragment,
        true,
    );
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "descriptor capped bare carriage return replaces one dropped record" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 72,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    };
    defer runtime.deinit(alloc);
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    var metrics: Metrics = .{};

    _ = try command_output_runtime.writeCommandOutputChunkUncommitted(
        &runtime,
        alloc,
        &metrics,
        styles,
        null,
        .stdout,
        "kept\n",
        true,
    );
    const kept_entry_id = runtime.command_output_blocks.items[0].lines.items[0].entry_id.?;
    runtime.max_retained_transcript_bytes = runtime.retainedStructuredBytesForCommandOutput();

    _ = try command_output_runtime.writeCommandOutputChunkUncommitted(
        &runtime,
        alloc,
        &metrics,
        styles,
        null,
        .stdout,
        "dropped\rreplacement",
        true,
    );
    var block = &runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 2), block.total_lines);
    try std.testing.expectEqual(@as(usize, 1), block.lines.items.len);
    try std.testing.expectEqual(kept_entry_id, block.lines.items[0].entry_id.?);
    try std.testing.expect(block.overflow_open_records[0]);
    try std.testing.expect(block.overflow_record_visible[0]);

    _ = try command_output_runtime.writeCommandOutputChunkUncommitted(
        &runtime,
        alloc,
        &metrics,
        styles,
        null,
        .stdout,
        "\n",
        true,
    );
    block = &runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 2), block.total_lines);
    try std.testing.expectEqual(@as(usize, 1), block.lines.items.len);
    try std.testing.expectEqual(kept_entry_id, block.lines.items[0].entry_id.?);
    try std.testing.expect(!block.overflow_open_records[0]);
}

test "descriptor capped ansi-only prefix keeps later visible overflow record" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 72,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    };
    defer runtime.deinit(alloc);
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    var metrics: Metrics = .{};

    _ = try command_output_runtime.writeCommandOutputChunkUncommitted(
        &runtime,
        alloc,
        &metrics,
        styles,
        null,
        .stdout,
        "kept\n",
        true,
    );
    runtime.max_retained_transcript_bytes = runtime.retainedStructuredBytesForCommandOutput();

    _ = try command_output_runtime.writeCommandOutputChunkUncommitted(
        &runtime,
        alloc,
        &metrics,
        styles,
        null,
        .stdout,
        "\x1b[31m",
        true,
    );
    var block = &runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 2), block.total_lines);
    try std.testing.expect(block.overflow_open_records[0]);
    try std.testing.expect(!block.overflow_record_visible[0]);
    try std.testing.expect(block.decoders[0].isIdle());

    _ = try command_output_runtime.writeCommandOutputChunkUncommitted(
        &runtime,
        alloc,
        &metrics,
        styles,
        null,
        .stdout,
        "visible",
        true,
    );
    block = &runtime.command_output_blocks.items[0];
    try std.testing.expect(block.overflow_record_visible[0]);
    runtime.max_retained_transcript_bytes = std.math.maxInt(usize);

    _ = try command_output_runtime.flushCommandOutputSummaryUncommitted(
        &runtime,
        alloc,
        &metrics,
        styles,
        null,
        true,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        runtime.command_output_blocks.items[0].total_lines,
    );

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), source.bytes.len);
}

test "descriptor capped split osc terminator preserves record boundaries" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 72,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
    };
    defer runtime.deinit(alloc);
    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    var metrics: Metrics = .{};

    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "kept\n",
        true,
    );
    runtime.max_retained_transcript_bytes = runtime.retainedStructuredBytesForCommandOutput();

    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "\x1b]0;title",
        true,
    );
    var block = &runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 2), block.total_lines);
    try std.testing.expect(block.overflow_open_records[0]);

    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "\x07",
        true,
    );
    try runtime.writeCommandOutputChunk(
        alloc,
        &metrics,
        styles,
        .stdout,
        "\nnext\n",
        true,
    );

    block = &runtime.command_output_blocks.items[0];
    try std.testing.expectEqual(@as(usize, 3), block.total_lines);
    try std.testing.expect(!block.overflow_open_records[0]);
}

test "command terminal detail resolves its lifecycle output instead of the latest block" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    const first = types.ToolLifecycleId{ .turn_id = 9, .call_id = "command-first" };
    const second = types.ToolLifecycleId{ .turn_id = 9, .call_id = "command-second" };
    for ([_]types.ToolLifecycleId{ first, second }) |id| {
        _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
            .id = id,
            .reconciles_provisional_call_id = null,
            .tool_name = "run_command",
            .activity_kind = .command,
            .arguments_json = "{\"command\":\"printf demo\"}",
        } });
    }

    var metrics: Metrics = .{};
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, first, .stdout, "first\n", true);
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, first, true);
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, second, .stdout, "second\n", true);
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, second, true);

    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = first,
        .outcome = .{ .kind = .completed, .summary = "Ran first" },
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = second,
        .outcome = .{ .kind = .completed, .summary = "Ran second" },
    } });

    const first_status = runtime.toolActivityRecord(first).?.entry_id;
    const second_status = runtime.toolActivityRecord(second).?.entry_id;
    try std.testing.expectEqual(runtime.command_output_blocks.items[0].entry_id, runtime.toolDetailForEntry(first_status).?.command_output_entry_id);
    try std.testing.expectEqual(runtime.command_output_blocks.items[1].entry_id, runtime.toolDetailForEntry(second_status).?.command_output_entry_id);
}

test "command output consolidation keeps compact tool order" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    const first = types.ToolLifecycleId{ .turn_id = 9, .call_id = "command-first" };
    const second = types.ToolLifecycleId{ .turn_id = 9, .call_id = "command-second" };

    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = first,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"printf first\"}",
    } });
    _ = try runtime.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = second,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"printf second\"}",
    } });

    var metrics: Metrics = .{};
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, first, .stdout, "FIRST_OUTPUT\n", true);
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = first,
        .outcome = .{ .kind = .completed, .summary = "Ran first" },
    } });
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, first, true);

    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, second, .stdout, "SECOND_OUTPUT\n", true);
    _ = try runtime.applyToolLifecycle(alloc, .{ .terminal = .{
        .id = second,
        .outcome = .{ .kind = .completed, .summary = "Ran second" },
    } });
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, second, true);

    var compact = try runtime.prepareTranscriptSource(alloc, null);
    defer compact.deinit(alloc);

    const first_status = std.mem.indexOf(u8, compact.bytes, "Ran first") orelse
        return error.MissingFirstStatus;
    const second_status = std.mem.indexOf(u8, compact.bytes, "Ran second") orelse
        return error.MissingSecondStatus;

    try std.testing.expect(first_status < second_status);
    try std.testing.expect(std.mem.indexOf(u8, compact.bytes, "FIRST_OUTPUT") == null);
    try std.testing.expect(std.mem.indexOf(u8, compact.bytes, "SECOND_OUTPUT") == null);

    const first_status_entry = runtime.toolActivityRecord(first).?.entry_id;
    const second_status_entry = runtime.toolActivityRecord(second).?.entry_id;
    try std.testing.expectEqual(runtime.command_output_blocks.items[0].entry_id, runtime.toolDetailForEntry(first_status_entry).?.command_output_entry_id);
    try std.testing.expectEqual(runtime.command_output_blocks.items[1].entry_id, runtime.toolDetailForEntry(second_status_entry).?.command_output_entry_id);
}

test "command output completion ignores mismatched lifecycle" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{ .layout = .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    } };
    defer runtime.deinit(alloc);

    const styles: Styles = .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
    const first = types.ToolLifecycleId{ .turn_id = 9, .call_id = "command-first" };
    const second = types.ToolLifecycleId{ .turn_id = 9, .call_id = "command-second" };

    var metrics: Metrics = .{};
    try runtime.writeCommandOutputChunkForLifecycle(alloc, &metrics, styles, first, .stdout, "first\n", true);
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, null, true);
    try std.testing.expect(runtime.command_output_display.open_command_block != null);
    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, second, true);
    try std.testing.expect(runtime.command_output_display.open_command_block != null);
    try std.testing.expect(runtime.command_output_blocks.items[0].entry_id == null);

    try runtime.flushCommandOutputSummaryForLifecycle(alloc, &metrics, styles, first, true);
    try std.testing.expect(runtime.command_output_display.open_command_block == null);
    try std.testing.expect(runtime.command_output_blocks.items[0].entry_id != null);
}

test "retintEntriesForTheme rewrites owned presentation without touching external raw bytes" {
    const alloc = std.testing.allocator;
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
        .owned_top_row = 1,
    };
    defer runtime.deinit(alloc);

    const owned_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "\x1b[38;5;252m■\x1b[38;5;255m cancelled\x1b[39m\n",
        .tool_status,
    );
    const command_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "\x1b[38;5;252mcommand\x1b[39m\n",
        .command_output,
    );
    const unknown_id = try runtime.appendRawTranscriptEntryClassified(
        alloc,
        "\x1b[38;5;252munknown\x1b[39m\n",
        .unknown_raw,
    );
    const assistant_id = try runtime.appendAssistantTurnEntry(alloc);
    const segments = runtime.lookupAssistantSegments(assistant_id).?;
    try segments.text.appendSlice(alloc, "\x1b[38;5;245mcode\x1b[39m \x1b[38;5;252m✓\x1b[39m\n");

    try runtime.retintEntriesForTheme(alloc, false, true);

    try std.testing.expectEqual(owned_id, runtime.entries.items[0].id());
    try std.testing.expectEqual(command_id, runtime.entries.items[1].id());
    try std.testing.expectEqual(unknown_id, runtime.entries.items[2].id());
    try std.testing.expectEqual(assistant_id, runtime.entries.items[3].id());
    try std.testing.expectEqualStrings(
        "\x1b[38;5;238m■\x1b[38;5;235m cancelled\x1b[39m\n",
        runtime.entries.items[0].raw_bytes.bytes,
    );
    try std.testing.expectEqualStrings(
        "\x1b[38;5;252mcommand\x1b[39m\n",
        runtime.entries.items[1].raw_bytes.bytes,
    );
    try std.testing.expectEqualStrings(
        "\x1b[38;5;252munknown\x1b[39m\n",
        runtime.entries.items[2].raw_bytes.bytes,
    );
    try std.testing.expectEqualStrings(
        "\x1b[38;5;247mcode\x1b[39m \x1b[38;5;238m✓\x1b[39m\n",
        runtime.entries.items[3].assistant_turn.segments.text.items,
    );
}

pub fn wrapAssistantText(alloc: Allocator, text: []const u8, cols: u16) ![]u8 {
    return transcript_blocks.wrapAssistantText(alloc, text, cols);
}

pub const PaintTestMode = enum {
    none,
    mutate_backing_after_snapshot,
};

const PaintTestModeField = if (@import("builtin").is_test) PaintTestMode else void;
const default_max_retained_transcript_bytes: usize = 1024 * 1024;
const resume_publication_rows_per_frame: u32 = 64;

pub const PaintTraceState = struct {
    transcript_top: u16 = 0,
    transcript_bottom: u16 = 0,
    transcript_start_line: usize = 0,
    transcript_total_lines: usize = 0,
    transcript_visible_rows: u16 = 0,
    transcript_partial_skip_rows: u16 = 0,
    transcript_entries: usize = 0,
    transcript_initialized: bool = false,
    transcript_log_frame: bool = false,

    shimmer_row: ?u16 = null,
    shimmer_over_footer: bool = false,
    shimmer_label_hash: u64 = 0,

    footer_top: u16 = 0,
    footer_input_base: u16 = 0,
    footer_hint: u16 = 0,
    footer_activity_row: ?u16 = null,
    footer_activity_reserved: u16 = 0,
    footer_activity_kind: u8 = 0,
    footer_initialized: bool = false,
};

const CommandOutputBlock = command_output_runtime.CommandOutputBlock;
const FoldedCommandBlock = command_output_runtime.FoldedCommandBlock;
const CommandOutputRenderPolicy = command_output_runtime.CommandOutputRenderPolicy;

pub const ToolDetailRecord = transcript_blocks.ToolDetailRecord;

const PendingToolDetailStart = struct {
    tool_name: ?[]u8 = null,
    captured_command: ?bool = null,
    activity_kind: ?types.ToolActivityKind = null,
    arguments_json: ?[]u8 = null,
    lifecycle_id: ?types.ToolLifecycleId = null,
    replace_lifecycle: bool = false,

    fn deinit(self: *PendingToolDetailStart, alloc: Allocator) void {
        const tool_name = self.tool_name;
        const arguments_json = self.arguments_json;
        const lifecycle_id = self.lifecycle_id;
        self.* = .{};
        if (tool_name) |value| alloc.free(value);
        if (arguments_json) |value| alloc.free(value);
        if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    }
};

const PendingToolDetailTerminal = struct {
    result: ?[]u8 = null,
    result_handle: ?[]u8 = null,
    command_artifact_handle: ?[]u8 = null,
    command_output_replay: ?types.CommandOutputReplay = null,
    command_process_presentation: ?types.CommandProcessPresentation = null,
    command_output_entry_id: ?u32 = null,
    command_process_entry: ?PendingCommandProcessEntry = null,

    fn deinit(self: *PendingToolDetailTerminal, alloc: Allocator) void {
        if (self.result) |value| alloc.free(value);
        if (self.result_handle) |value| alloc.free(value);
        if (self.command_artifact_handle) |value| alloc.free(value);
        if (self.command_output_replay) |replay| {
            types.freeCommandOutputReplay(alloc, replay);
        }
        if (self.command_process_entry) |*entry| entry.deinit(alloc);
        self.* = .{};
    }
};

const PendingCommandProcessEntry = struct {
    entry_id: u32,
    bytes: ?[]u8 = null,
    block: ?CommandOutputBlock = null,

    fn deinit(self: *PendingCommandProcessEntry, alloc: Allocator) void {
        if (self.bytes) |value| alloc.free(value);
        if (self.block) |*value| value.deinit(alloc);
        self.bytes = null;
        self.block = null;
    }
};

pub fn renderEntriesToBytes(
    alloc: Allocator,
    entries: []const TranscriptEntry,
    cols: u16,
    styles: Styles,
) ![]u8 {
    return transcript_blocks.renderEntriesToBytes(alloc, entries, cols, styles);
}

pub const FullTranscriptPrimaryRestore = enum {
    changed,
    changed_resized,
    exact,
    resized,
};

const InstalledFullTranscriptPage = struct {
    source: full_transcript_worker.Source,
    projection: full_transcript_screen.Projection,

    fn deinit(self: *InstalledFullTranscriptPage) void {
        self.projection.deinit(std.heap.c_allocator);
        self.source.deinit(std.heap.c_allocator);
        self.* = undefined;
    }
};

const CachedCompactTranscriptSource = struct {
    source: TranscriptPreparationSource,
    content_revision: u64,
    cols: u16,
    has_committed_frame: bool,
};

const CompactTranscriptSourceCache = struct {
    const capacity = 4;

    entries: [capacity]?CachedCompactTranscriptSource = .{null} ** capacity,
    next_replacement: usize = 0,

    fn deinit(self: *CompactTranscriptSourceCache, alloc: Allocator) void {
        for (&self.entries) |*entry| {
            if (entry.*) |*cached| cached.source.deinit(alloc);
        }
        self.* = .{};
    }

    fn find(
        self: *CompactTranscriptSourceCache,
        content_revision: u64,
        cols: u16,
        has_committed_frame: bool,
    ) ?*TranscriptPreparationSource {
        for (&self.entries) |*entry| {
            if (entry.*) |*cached| {
                if (cached.content_revision == content_revision and
                    cached.cols == cols and
                    cached.has_committed_frame == has_committed_frame)
                {
                    return &cached.source;
                }
            }
        }
        return null;
    }

    fn insert(
        self: *CompactTranscriptSourceCache,
        alloc: Allocator,
        replacement: CachedCompactTranscriptSource,
    ) *TranscriptPreparationSource {
        var index = self.next_replacement;
        for (self.entries, 0..) |entry, candidate| {
            if (entry == null) {
                index = candidate;
                break;
            }
        } else {
            self.next_replacement = (self.next_replacement + 1) % capacity;
        }
        if (self.entries[index]) |*cached| cached.source.deinit(alloc);
        self.entries[index] = replacement;
        return &self.entries[index].?.source;
    }
};

pub const TranscriptRuntime = struct {
    stdout_file: std.Io.File = std.Io.File.stdout(),
    sync_updates_enabled: bool = true,
    history_reset_uses_ris: bool = false,
    layout: Layout = undefined,
    cursor_row: u16 = 1,
    cursor_col: u16 = 1,
    /// Top terminal row owned by fx. Rows above this contain pre-fx scrollback
    /// and must not be touched by fx repaint logic.
    /// Initialized to the cursor row captured at `initViewport`, and
    /// decreased as the transcript scrolls until it reaches row 1.
    viewport_top_row: u16 = 1,
    /// First row fx is allowed to clear or repaint. This is set after
    /// launch-time reservation has created fx-owned rows. Rows above it
    /// belong to pre-fx terminal content and must not be touched by
    /// resize/layout repair.
    owned_top_row: u16 = 1,
    /// Set when a resize leaves no drawable rows below `owned_top_row`.
    /// The next successful repaint uses natural terminal scroll to
    /// compact older visible rows into scrollback before drawing the
    /// latest fx frame.
    pending_scroll_compact: bool = false,
    /// Minimum body rows fx should keep available for the visible
    /// viewport. Startup sets this to the welcome banner height so a
    /// later resize cannot leave the renderer with a partial banner
    /// band and stale resize-reflow cells above it.
    min_visible_viewport_rows: u16 = 0,
    /// Resize-only guard rows to clear above `viewport_top_row` on the
    /// next replay. Real terminals can reflow old fx cells just above
    /// the logical band during a drag; this lets the settled pass erase
    /// that residue without widening normal streaming paints.
    reflow_clear_guard_rows: u16 = 0,
    /// Signed cursor displacement measured across the current settled
    /// resize. Positive rows entered history; negative rows returned.
    resize_history_row_delta: ?i32 = null,
    /// Pre-paint cursor evidence retained from live geometry through the
    /// matching canonical reset commit.
    pending_resize_observation: ?ResizeObservation = null,
    /// Forces the next viewport diff paint to start from a real terminal
    /// clear. This is reserved for resize/reflow repair; normal streamed
    /// token paints must diff in place so cleared frames do not enter
    /// terminal scrollback.
    viewport_clear_pending: bool = false,
    /// A settled terminal resize needs a canonical repaint from row one.
    /// It remains pending until the reset frame commits successfully.
    terminal_reset_pending: bool = false,
    /// A committed resize reset established terminal-bottom ownership that
    /// the next cancellation projection must preserve.
    resize_bottom_anchor_pending: bool = false,
    render_requests: render_request.RenderRequestState = .{},
    /// Set after the frame commit path has successfully written and fed
    /// a frame. Resize-time invalid terminal dimensions before this point
    /// still use the startup error path.
    has_committed_frame: bool = false,
    committed_frame_layout: render_engine.frame_layout.CommittedLayoutSnapshot = .{},
    transcript_commit_state: TranscriptCommitState = .invalid,
    /// True while the terminal reports zero, unreadable, or too-small
    /// dimensions after the first committed frame. Normal painters stay
    /// idle until a valid resize clears this flag.
    terminal_dimensions_invalid: bool = false,
    transcript: std.ArrayList(u8) = .empty,
    /// Complete historical flow and its immutable line index, retained until
    /// the first successful terminal publication.
    pending_resume_source: ?TranscriptPreparationSource = null,
    folded_command_blocks: std.ArrayList(FoldedCommandBlock) = .empty,
    command_output_blocks: std.ArrayList(CommandOutputBlock) = .empty,
    /// Viewer state used only while Ctrl-O owns the alternate screen.
    /// The compact transcript keeps its independent viewport selection.
    full_transcript: transcript_presentation.State = .{},
    full_transcript_open_content_revision: ?u64 = null,
    full_transcript_open_cols: u16 = 0,
    full_transcript_open_rows: u16 = 0,
    full_transcript_primary_recovery_entry_id: ?u32 = null,
    full_transcript_page_load: full_transcript_worker.Load = .{},
    full_transcript_page_anchor: full_transcript_page.Anchor = .tail,
    full_transcript_installed_page: ?InstalledFullTranscriptPage = null,
    full_transcript_loading_projection: ?full_transcript_screen.Projection = null,
    full_transcript_content_revision: u64 = 0,
    compact_transcript_source_cache: CompactTranscriptSourceCache = .{},
    /// When enabled, compact transcript tool groups render only their summary
    /// header while the full transcript retains every individual tool call.
    collapse_tool_calls: bool = false,
    /// Structured-entry store used to regenerate transcript bytes at the
    /// current width while retaining the raw byte buffer for append paths
    /// that still write pre-rendered transcript content.
    entries: std.ArrayList(TranscriptEntry) = .empty,
    lifecycle_state: activity_runtime.ToolActivityState = .{},
    worker_status: worker_status.State = .none,
    /// Core-owned producer state and policy for native-history release.
    transcript_release: transcript_release.State = .{},
    /// Sorted by entry id so exact lookup stays bounded as history grows.
    tool_details: std.ArrayList(ToolDetailRecord) = .empty,
    /// Monotonically increasing id stamped onto each new entry by the
    /// `append*Entry` helpers. Starts at 1 so 0 can be reserved as a
    /// sentinel. Never reset on `clearTranscript` — even after a wipe,
    /// subsequent ids remain unique within the session, which keeps
    /// debug traces unambiguous across transcript resets.
    next_entry_id: u32 = 1,
    /// Cols at which the transcript byte buffer was last regenerated from
    /// entries. A cache-origin proof is valid only at this width.
    /// Zero before the first prepared transcript frame.
    last_rendered_cols: u16 = 0,
    /// True only when the visible cache was rebuilt from an untrimmed,
    /// canonical entry source at `last_rendered_cols`.
    transcript_cache_origin_untrimmed: bool = false,
    /// Visible byte-cache cap. This bounds `transcript.items`, which is
    /// the rendered tail used by viewport paint. Structured entries and
    /// folded command output are bounded separately by
    /// `max_retained_transcript_bytes` below.
    max_transcript_bytes: usize = 256 * 1024,
    /// Structured retention cap for raw/user/assistant entries plus
    /// folded command output lines. This model is the source of truth
    /// for reconstructive paint, resize, and diff restyling, so it gets
    /// its own conservative budget instead of borrowing the smaller
    /// visible byte-cache limit.
    max_retained_transcript_bytes: usize = default_max_retained_transcript_bytes,
    painting: bool = false,
    paint_test_mode: PaintTestModeField = if (@import("builtin").is_test) .none else {},
    /// Renderer-local cache state set by transcript mutations. The same
    /// mutation must request `.transcript`; this flag never authorizes a
    /// frame on its own.
    transcript_band_dirty: bool = false,
    /// False until the first non-empty viewport paint has established
    /// fx's transcript band. Before that point transcript writes are
    /// model updates only: emitting scroll newlines would move pre-fx
    /// shell rows before the renderer has had a chance to respect
    /// `viewport_top_row`.
    has_painted_transcript: bool = false,
    footer_viewport: footer_viewport_runtime.FooterViewport = .{},
    extra_input_rows: u16 = 0,
    footer_reserved_base_rows: u16 = 3,
    command_output_display: CommandOutputDisplayState = .{},
    command_output_render: CommandOutputRenderPolicy = .{},
    shimmer_active: bool = false,
    shimmer_row: u16 = 1,
    shimmer_is_overlay: bool = false,
    paint_trace: PaintTraceState = .{},
    last_visible_transcript_top_row: u16 = 1,
    last_visible_transcript_start_line: usize = 0,
    last_visible_transcript_partial_skip_rows: u16 = 0,
    last_visible_transcript_split_active: bool = false,
    last_visible_transcript_split_prefix_lines: usize = 0,
    last_visible_transcript_split_suffix_start_line: usize = 0,
    last_visible_transcript_last_row: u16 = 0,
    last_visible_transcript_last_row_blank: bool = false,
    last_visible_transcript_tail_kind: ?TranscriptBlockKind = null,
    last_viewport_selection: ?ViewportSelection = null,
    /// Detached alternate-screen views may request the ordinary compact
    /// transcript at a stable distance from its tail. Inline chat leaves this
    /// unset and keeps the existing viewport policy.
    tail_viewport_request: ?viewport_selection.TailViewportPolicy = null,
    tail_viewport_resolution: ?viewport_selection.TailOffsetResolution = null,
    last_paint_bottom_reserved_rows: u16 = 0,
    replaceable_last_line: bool = false,
    replaceable_row: u16 = 1,
    replaceable_start: usize = 0,
    /// In-process terminal shadow used as the previous state for cell diffs.
    /// Bootstrap enables it unconditionally; FX_TRACE dumps it at synchronized
    /// update boundaries.
    shadow_vt: ?*vt_emulator.Grid = null,
    shadow_vt_alloc: ?Allocator = null,
    /// Detached presentations share a physical terminal shadow with their
    /// owning surface, but retain independent transcript commit state.
    /// This allocator releases that commit state without claiming ownership
    /// of the shared shadow grid.
    detached_commit_alloc: ?Allocator = null,
    ui_observer: render_engine.ui_observer.UiObserver = .{},

    pub noinline fn init() TranscriptRuntime {
        var result: TranscriptRuntime = .{
            .compact_transcript_source_cache = undefined,
        };
        for (&result.compact_transcript_source_cache.entries) |*entry| {
            entry.* = null;
        }
        result.compact_transcript_source_cache.next_replacement = 0;
        return result;
    }

    pub fn enableShadowVt(self: *TranscriptRuntime, alloc: Allocator) !void {
        return transcript_io.enableShadowVt(self, alloc);
    }

    pub fn disableShadowVt(self: *TranscriptRuntime) void {
        return transcript_io.disableShadowVt(self);
    }

    pub fn bindDetachedCommitAllocator(
        self: *TranscriptRuntime,
        alloc: Allocator,
    ) void {
        std.debug.assert(self.shadow_vt == null);
        self.detached_commit_alloc = alloc;
    }

    pub fn deinit(self: *TranscriptRuntime, alloc: Allocator) void {
        self.disableShadowVt();
        self.full_transcript_page_load.deinit();
        if (self.full_transcript_installed_page) |*page| page.deinit();
        if (self.full_transcript_loading_projection) |*projection| {
            projection.deinit(alloc);
        }
        self.compact_transcript_source_cache.deinit(alloc);
        self.lifecycle_state.deinit(alloc);
        for (self.tool_details.items) |*detail| detail.deinit(alloc);
        self.tool_details.deinit(alloc);
        self.transcript.deinit(alloc);
        _ = self.releasePendingResumeSource(alloc);
        for (self.folded_command_blocks.items) |*block| block.deinit(alloc);
        self.folded_command_blocks.deinit(alloc);
        for (self.command_output_blocks.items) |*block| block.deinit(alloc);
        self.command_output_blocks.deinit(alloc);
        for (self.entries.items) |*entry| entry.deinit(alloc);
        self.entries.deinit(alloc);
        self.transcript_commit_state.deinit(alloc);
        self.footer_viewport.deinit(alloc);
        self.ui_observer.deinit(alloc);
    }

    fn releasePendingResumeSource(self: *TranscriptRuntime, alloc: Allocator) usize {
        var source = self.pending_resume_source orelse return 0;
        const released_bytes = source.bytes.len;
        source.deinit(alloc);
        self.pending_resume_source = null;
        return released_bytes;
    }

    pub fn pendingResumeFlow(self: *const TranscriptRuntime) []const u8 {
        return if (self.pending_resume_source) |*source| source.bytes else &.{};
    }

    pub fn committedRowProvenance(
        self: *const TranscriptRuntime,
    ) []const transcript_blocks.RowProvenance {
        return switch (self.transcript_commit_state) {
            .invalid => &.{},
            .stable => |anchor| anchor.row_provenance,
            .recovering => |receipt| receipt.row_provenance,
        };
    }

    pub fn beginPaint(self: *TranscriptRuntime) usize {
        std.debug.assert(!self.painting);
        self.painting = true;
        return self.transcript.items.len;
    }

    pub fn endPaint(self: *TranscriptRuntime, entry_len: usize) void {
        self.painting = false;
        const exit_len = self.transcript.items.len;
        if (exit_len != entry_len) {
            debug_trace.logf("paint", "transcript mutated during paint: entry_len={d} exit_len={d}", .{ entry_len, exit_len });
        }
    }

    pub fn beginPaintSilent(self: *TranscriptRuntime) void {
        std.debug.assert(!self.painting);
        self.painting = true;
    }

    pub fn endPaintSilent(self: *TranscriptRuntime) void {
        self.painting = false;
    }

    pub fn assertCanMutateTranscript(self: *TranscriptRuntime) !void {
        if (@import("builtin").is_test and self.painting) return error.PaintGuardViolated;
        std.debug.assert(!self.painting);
    }

    pub fn initBacking(self: *TranscriptRuntime, alloc: Allocator) !void {
        return transcript_store.initBacking(self, alloc);
    }

    pub fn ensurePaintReservation(self: *TranscriptRuntime, alloc: Allocator) !void {
        return transcript_store.ensurePaintReservation(self, alloc);
    }

    pub fn rebuildTranscriptFromRendered(self: *TranscriptRuntime, alloc: Allocator, bytes: []const u8, label: []const u8) !void {
        return transcript_store.rebuildTranscriptFromRendered(self, alloc, bytes, label);
    }

    pub fn replaceableEntryId(self: *const TranscriptRuntime) ?u32 {
        return transcript_store.replaceableEntryId(self);
    }

    pub fn refreshFoldedCommandSummaryIndices(self: *TranscriptRuntime, alloc: Allocator) !void {
        return transcript_store.refreshFoldedCommandSummaryIndices(self, alloc);
    }

    pub fn rebuildTranscriptCacheFromEntries(self: *TranscriptRuntime, alloc: Allocator, label: []const u8) !void {
        return transcript_store.rebuildTranscriptCacheFromEntries(self, alloc, label);
    }

    pub fn rebuildTranscriptCacheAfterStructuredRewrite(self: *TranscriptRuntime, alloc: Allocator, label: []const u8) !void {
        return transcript_store.rebuildTranscriptCacheAfterStructuredRewrite(self, alloc, label);
    }

    pub fn reconcileDetachedInstallSource(
        self: *TranscriptRuntime,
        source: []const u8,
    ) void {
        transcript_store.reconcileDetachedInstallSource(self, source);
    }

    pub fn enforceStructuredRetention(self: *TranscriptRuntime, alloc: Allocator, protected_id: ?u32) !void {
        return transcript_store.enforceStructuredRetention(self, alloc, protected_id);
    }

    pub fn enforceStructuredRetentionAndReport(
        self: *TranscriptRuntime,
        alloc: Allocator,
        protected_id: ?u32,
    ) !bool {
        return transcript_store.enforceStructuredRetentionAndReport(self, alloc, protected_id);
    }

    pub fn lifecyclePinCount(self: *const TranscriptRuntime) usize {
        return transcript_store.lifecyclePinCount(self);
    }

    pub fn isLifecyclePinned(self: *const TranscriptRuntime, entry_id: u32) bool {
        return transcript_store.isLifecyclePinned(self, entry_id);
    }

    pub fn applyToolLifecycle(
        self: *TranscriptRuntime,
        alloc: Allocator,
        event: types.ToolLifecycleEvent,
    ) !?types.ToolActivityKind {
        return self.applyToolLifecycleWithAnchorPolicy(alloc, event, false);
    }

    pub fn applyToolLifecyclePreservingNormalBufferAnchor(
        self: *TranscriptRuntime,
        alloc: Allocator,
        event: types.ToolLifecycleEvent,
    ) !?types.ToolActivityKind {
        return self.applyToolLifecycleWithAnchorPolicy(alloc, event, true);
    }

    fn applyToolLifecycleWithAnchorPolicy(
        self: *TranscriptRuntime,
        alloc: Allocator,
        event: types.ToolLifecycleEvent,
        preserve_normal_buffer_anchor: bool,
    ) !?types.ToolActivityKind {
        const result = switch (event) {
            .provisional => |provisional| self.applyProvisionalLifecycle(
                alloc,
                provisional.id,
                provisional.presentation_group_id,
                provisional.tool_name,
                provisional.activity_kind,
            ),
            .authoritative_started => |started| self.applyAuthoritativeLifecycle(
                alloc,
                started.id,
                started.presentation_group_id,
                started.reconciles_provisional_call_id,
                started.tool_name,
                started.activity_kind,
                started.arguments_json,
                started.place_after_current_transcript,
            ),
            .progress => |progress| self.applyProgressLifecycle(
                alloc,
                progress.id,
                progress.text,
            ),
            .terminal => |terminal| self.applyTerminalLifecycle(
                alloc,
                terminal.id,
                terminal.outcome,
                terminal.result,
                terminal.result_memory,
                terminal.command_artifact_handle,
            ),
            .turn_finished => |finished| self.applyTurnFinishedLifecycle(
                alloc,
                finished,
                preserve_normal_buffer_anchor,
            ),
        } catch |err| {
            traceLifecycleFailure(
                @tagName(event),
                lifecycleEventTurnId(event),
                err,
            );
            return err;
        };
        debug_trace.eventf(
            "ui_activity",
            "lifecycle_reduced",
            .{},
            "kind={s} turn_id={d} records={d}",
            .{
                @tagName(event),
                lifecycleEventTurnId(event),
                self.lifecycle_state.recordCount(),
            },
        );
        return result;
    }

    pub fn finishLifecycleBatch(
        self: *TranscriptRuntime,
        alloc: Allocator,
    ) !void {
        const watermark = self.lifecycle_state.batch_finalized_turn_watermark orelse return;
        const entry_ids = try self.lifecycle_state.cleanupEntryIds(alloc, watermark);
        defer alloc.free(entry_ids);
        transcript_store.clearLifecyclePinsAtomic(self, alloc, entry_ids) catch |err| {
            traceLifecycleFailure("batch_cleanup", watermark, err);
            return err;
        };
        self.lifecycle_state.commitCleanup(alloc, watermark);
    }

    pub fn activityProjection(
        self: *const TranscriptRuntime,
    ) activity_runtime.ActivityProjection {
        if (self.worker_status.projection()) |projection| return projection;
        const record = self.lifecycle_state.focusedRecord() orelse {
            return .none;
        };
        const label = transcript_store.toolStatusEntryLabel(self, record.entry_id) orelse {
            debug_trace.logf(
                "ui_activity",
                "focused lifecycle missing transcript entry turn_id={d} entry_id={d}",
                .{ record.id.turn_id, record.entry_id },
            );
            return .none;
        };
        return .{ .tool_slot = .{
            .entry_id = record.entry_id,
            .fallback_label = label,
            .active = record.phase != .terminal,
            .kind = record.activity_kind,
        } };
    }

    pub fn worker_status_state(self: *TranscriptRuntime) *worker_status.State {
        return &self.worker_status;
    }

    pub fn focusedToolEntryId(self: *const TranscriptRuntime) ?u32 {
        const record = self.lifecycle_state.focusedRecord() orelse return null;
        return record.entry_id;
    }

    pub fn focusedToolActivityKind(
        self: *const TranscriptRuntime,
    ) ?types.ToolActivityKind {
        const record = self.lifecycle_state.focusedRecord() orelse return null;
        return record.activity_kind;
    }

    pub fn toolActivityRecord(
        self: *const TranscriptRuntime,
        id: types.ToolLifecycleId,
    ) ?activity_runtime.ToolPresentationRecord {
        return self.lifecycle_state.record(id);
    }

    pub fn attachCommandOutputEntryForLifecycle(
        self: *TranscriptRuntime,
        lifecycle_id: ?types.ToolLifecycleId,
        command_output_entry_id: u32,
    ) void {
        const id = lifecycle_id orelse return;
        for (self.tool_details.items) |*detail| {
            if (!command_output_runtime.sameLifecycleId(detail.lifecycle_id, id)) continue;
            detail.command_output_entry_id = command_output_entry_id;
            return;
        }
    }

    pub fn toolActivityRecordCount(self: *const TranscriptRuntime) usize {
        return self.lifecycle_state.recordCount();
    }

    pub fn activeToolActivityCount(self: *const TranscriptRuntime) usize {
        return self.lifecycle_state.activeCount();
    }

    pub fn finalizedToolTurnWatermark(self: *const TranscriptRuntime) u64 {
        return self.lifecycle_state.finalized_turn_watermark;
    }

    pub fn clearTranscript(self: *TranscriptRuntime, alloc: Allocator) void {
        const pending_resume_bytes = self.releasePendingResumeSource(alloc);
        if (pending_resume_bytes > 0) {
            debug_trace.logf(
                "session",
                "dropping pending resume flow during transcript clear bytes={d}",
                .{pending_resume_bytes},
            );
        }
        self.lifecycle_state.deinit(alloc);
        self.worker_status.reset();
        self.clearToolDetails(alloc);
        return transcript_store.clearTranscript(self, alloc);
    }

    pub fn snapshotVisibleTranscriptText(
        self: *const TranscriptRuntime,
        alloc: Allocator,
        max_bytes: usize,
    ) !?VisibleTranscriptSnapshot {
        const grid = self.shadow_vt orelse return null;
        if (!self.has_painted_transcript or
            self.last_visible_transcript_top_row == 0 or
            self.last_visible_transcript_last_row < self.last_visible_transcript_top_row)
        {
            return null;
        }
        const footer_gap_rows = if (!self.committed_frame_layout.footer_area.isEmpty() and
            self.committed_frame_layout.footer_area.top > self.last_visible_transcript_last_row)
            self.committed_frame_layout.footer_area.top - self.last_visible_transcript_last_row - 1
        else
            0;
        if (footer_gap_rows >= max_bytes) return null;
        const text_byte_limit = max_bytes - footer_gap_rows;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var start_row = self.last_visible_transcript_top_row;
        const leading_welcome_visible = if (self.entries.items.len > 0 and
            self.entries.items[0] == .raw_bytes and
            self.entries.items[0].raw_bytes.class == .welcome and
            self.last_viewport_selection != null)
            self.last_viewport_selection.?.start_line == 0 or
                (self.last_viewport_selection.?.split_active and
                    self.last_viewport_selection.?.split_prefix_lines > 0)
        else
            false;
        if (leading_welcome_visible) {
            var saw_welcome_text = false;
            while (start_row <= self.last_visible_transcript_last_row) : (start_row += 1) {
                var line: std.ArrayList(u8) = .empty;
                defer line.deinit(grid.alloc);
                try grid.rowTextTrimmed(start_row, &line);
                if (line.items.len > 0) {
                    saw_welcome_text = true;
                } else if (saw_welcome_text) {
                    start_row += 1;
                    break;
                }
            }
            if (!saw_welcome_text or start_row > self.last_visible_transcript_last_row) return null;
        }
        var selected_start: ?u16 = null;
        var selected_bytes: usize = 0;
        var row = self.last_visible_transcript_last_row;
        while (true) {
            var line: std.Io.Writer.Allocating = .init(grid.alloc);
            defer line.deinit();
            try grid.rowStyledTextTrimmed(row, &line.writer);
            if (line.written().len >= text_byte_limit - selected_bytes) break;
            selected_bytes += line.written().len + 1;
            selected_start = row;
            if (row == start_row) break;
            row -= 1;
        }
        row = selected_start orelse return null;
        var has_content = false;
        while (row <= self.last_visible_transcript_last_row) : (row += 1) {
            var line: std.Io.Writer.Allocating = .init(grid.alloc);
            defer line.deinit();
            try grid.rowStyledTextTrimmed(row, &line.writer);
            has_content = has_content or line.written().len > 0;
            try out.appendSlice(alloc, line.written());
            try out.append(alloc, '\n');
        }
        if (!has_content) {
            out.deinit(alloc);
            return null;
        }
        try out.appendNTimes(alloc, '\n', footer_gap_rows);
        return .{
            .text = try out.toOwnedSlice(alloc),
            .terminal_rows = grid.rows,
            .terminal_cols = grid.cols,
            .complete = selected_start.? == start_row,
        };
    }

    pub fn resetVisualEpoch(self: *TranscriptRuntime, alloc: Allocator, welcome: []const u8) !void {
        return transcript_store.resetVisualEpoch(self, alloc, welcome);
    }

    fn replacePinnedLifecycleStatus(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        line: []const u8,
        place_after_current_transcript: bool,
    ) !bool {
        return if (place_after_current_transcript)
            transcript_store.replacePinnedToolStatusAtEndAtomic(
                self,
                alloc,
                entry_id,
                line,
            )
        else
            transcript_store.replacePinnedToolStatusAtomic(
                self,
                alloc,
                entry_id,
                line,
            );
    }

    fn applyProvisionalLifecycle(
        self: *TranscriptRuntime,
        alloc: Allocator,
        id: types.ToolLifecycleId,
        presentation_group_id: ?types.ToolPresentationGroupId,
        tool_name: ?[]const u8,
        activity_kind: types.ToolActivityKind,
    ) !?types.ToolActivityKind {
        if (!admitLifecycleStart(&self.lifecycle_state, id)) return null;
        if (self.lifecycle_state.recordPtr(id)) |record| {
            if (record.phase == .terminal) {
                traceLateLifecycleEvent(id, "provisional");
                return null;
            }
            const name = tool_name orelse return null;
            var detail_start = try self.prepareToolDetailStart(
                alloc,
                record.entry_id,
                id,
                name,
                activity_kind,
                null,
            );
            defer detail_start.deinit(alloc);
            const owned_name = try alloc.dupe(u8, name);
            errdefer alloc.free(owned_name);
            const line = try lifecycleStartLine(alloc, name);
            defer alloc.free(line);
            if (!try self.replacePinnedLifecycleStatus(
                alloc,
                record.entry_id,
                line,
                false,
            )) return error.MissingLifecycleTranscriptEntry;
            activity_runtime.replaceToolName(alloc, record, owned_name);
            record.activity_kind = activity_kind;
            self.commitLifecycleToolDetailStart(
                alloc,
                id,
                record.entry_id,
                &detail_start,
            );
            self.commitToolPresentationGroup(record.entry_id, id, presentation_group_id);
            return null;
        }
        var detail_start = try self.prepareToolDetailStart(
            alloc,
            null,
            id,
            tool_name orelse "tool",
            activity_kind,
            null,
        );
        defer detail_start.deinit(alloc);
        const entry_id = try self.createToolActivity(
            alloc,
            id,
            tool_name,
            activity_kind,
            .provisional,
        );
        self.commitLifecycleToolDetailStart(alloc, id, entry_id, &detail_start);
        self.commitToolPresentationGroup(entry_id, id, presentation_group_id);
        return null;
    }

    fn applyAuthoritativeLifecycle(
        self: *TranscriptRuntime,
        alloc: Allocator,
        id: types.ToolLifecycleId,
        presentation_group_id: ?types.ToolPresentationGroupId,
        reconciliation_alias: ?[]const u8,
        tool_name: []const u8,
        activity_kind: types.ToolActivityKind,
        arguments_json: ?[]const u8,
        place_after_current_transcript: bool,
    ) !?types.ToolActivityKind {
        if (!admitLifecycleStart(&self.lifecycle_state, id)) return null;

        const alias_id: ?types.ToolLifecycleId = if (reconciliation_alias) |call_id|
            if (call_id.len > 0)
                .{ .turn_id = id.turn_id, .call_id = call_id }
            else
                null
        else
            null;
        const alias_is_distinct = if (alias_id) |alias|
            alias.turn_id != id.turn_id or !std.mem.eql(u8, alias.call_id, id.call_id)
        else
            false;

        if (alias_is_distinct) {
            const alias = alias_id.?;
            if (self.lifecycle_state.record(alias)) |alias_record| {
                if (self.lifecycle_state.record(id) != null) {
                    debug_trace.logf(
                        "ui_activity",
                        "lifecycle identity collision turn_id={d} kind=authoritative_started",
                        .{id.turn_id},
                    );
                    return error.LifecycleReconciliationCollision;
                }
                if (alias_record.phase == .terminal) {
                    traceLateLifecycleEvent(alias, "authoritative_started");
                    return null;
                }
                var detail_start = try self.prepareToolDetailStart(
                    alloc,
                    alias_record.entry_id,
                    id,
                    tool_name,
                    activity_kind,
                    arguments_json,
                );
                defer detail_start.deinit(alloc);
                try self.lifecycle_state.ensureRecordCapacity(alloc);
                const owned_call_id = try alloc.dupe(u8, id.call_id);
                errdefer alloc.free(owned_call_id);
                const owned_tool_name = try alloc.dupe(u8, tool_name);
                errdefer alloc.free(owned_tool_name);
                const line = try lifecycleStartLine(alloc, tool_name);
                defer alloc.free(line);
                if (!try self.replacePinnedLifecycleStatus(
                    alloc,
                    alias_record.entry_id,
                    line,
                    place_after_current_transcript,
                )) return error.MissingLifecycleTranscriptEntry;
                self.lifecycle_state.rekeyOwned(
                    alloc,
                    alias,
                    .{ .turn_id = id.turn_id, .call_id = owned_call_id },
                    owned_tool_name,
                    activity_kind,
                );
                self.commitLifecycleToolDetailStart(
                    alloc,
                    id,
                    alias_record.entry_id,
                    &detail_start,
                );
                self.commitToolPresentationGroup(alias_record.entry_id, id, presentation_group_id);
                return activity_kind;
            }
        }

        if (self.lifecycle_state.recordPtr(id)) |record| {
            if (record.phase == .terminal) {
                traceLateLifecycleEvent(id, "authoritative_started");
                return null;
            }
            var detail_start = try self.prepareToolDetailStart(
                alloc,
                record.entry_id,
                id,
                tool_name,
                activity_kind,
                arguments_json,
            );
            defer detail_start.deinit(alloc);
            const owned_tool_name = try alloc.dupe(u8, tool_name);
            errdefer alloc.free(owned_tool_name);
            const line = try lifecycleStartLine(alloc, tool_name);
            defer alloc.free(line);
            if (!try self.replacePinnedLifecycleStatus(
                alloc,
                record.entry_id,
                line,
                place_after_current_transcript,
            )) return error.MissingLifecycleTranscriptEntry;
            const first_authoritative = self.lifecycle_state.promoteOwned(
                alloc,
                record,
                owned_tool_name,
                activity_kind,
            );
            self.commitLifecycleToolDetailStart(
                alloc,
                id,
                record.entry_id,
                &detail_start,
            );
            self.commitToolPresentationGroup(record.entry_id, id, presentation_group_id);
            return if (first_authoritative)
                activity_kind
            else
                null;
        }

        var detail_start = try self.prepareToolDetailStart(
            alloc,
            null,
            id,
            tool_name,
            activity_kind,
            arguments_json,
        );
        defer detail_start.deinit(alloc);
        const entry_id = try self.createToolActivity(
            alloc,
            id,
            tool_name,
            activity_kind,
            .authoritative,
        );
        self.commitLifecycleToolDetailStart(alloc, id, entry_id, &detail_start);
        self.commitToolPresentationGroup(entry_id, id, presentation_group_id);
        return activity_kind;
    }

    fn applyProgressLifecycle(
        self: *TranscriptRuntime,
        alloc: Allocator,
        id: types.ToolLifecycleId,
        text: []const u8,
    ) !?types.ToolActivityKind {
        const record = self.lifecycle_state.recordPtr(id) orelse {
            if (self.lifecycle_state.isFenced(id.turn_id)) {
                traceLateLifecycleEvent(id, "progress");
                return null;
            }
            debug_trace.logf(
                "ui_activity",
                "progress without lifecycle turn_id={d}",
                .{id.turn_id},
            );
            return error.UnknownToolLifecycleIdentity;
        };
        if (record.phase == .terminal) {
            traceLateLifecycleEvent(id, "progress");
            return null;
        }
        const line = try lifecycleLine(alloc, text);
        defer alloc.free(line);
        if (!try self.replacePinnedLifecycleStatus(
            alloc,
            record.entry_id,
            line,
            false,
        )) return error.MissingLifecycleTranscriptEntry;
        return null;
    }

    fn applyTerminalLifecycle(
        self: *TranscriptRuntime,
        alloc: Allocator,
        id: types.ToolLifecycleId,
        outcome: types.ToolOutcome,
        result: ?[]const u8,
        result_memory: ?types.ToolResultMemory,
        command_artifact_handle: ?[]const u8,
    ) !?types.ToolActivityKind {
        const record = self.lifecycle_state.recordPtr(id) orelse {
            if (self.lifecycle_state.isFenced(id.turn_id)) {
                traceLateLifecycleEvent(id, "terminal");
                return null;
            }
            debug_trace.logf(
                "ui_activity",
                "terminal without lifecycle turn_id={d}",
                .{id.turn_id},
            );
            return error.UnknownToolLifecycleIdentity;
        };
        const line = try lifecycleTerminalLine(alloc, outcome.kind, outcome.summary);
        defer alloc.free(line);
        var detail_start: ?PendingToolDetailStart = if (self.toolDetailPtr(record.entry_id) == null)
            try self.prepareToolDetailStart(
                alloc,
                record.entry_id,
                id,
                record.tool_name orelse "tool",
                record.activity_kind,
                null,
            )
        else
            null;
        defer if (detail_start) |*pending| pending.deinit(alloc);
        var detail_update = try self.prepareToolDetailTerminal(
            alloc,
            id,
            record.activity_kind,
            result,
            result_memory,
            command_artifact_handle,
            null,
        );
        defer detail_update.deinit(alloc);
        if (!try transcript_store.replacePinnedToolStatusForTerminalAtomic(
            self,
            alloc,
            record.entry_id,
            line,
            @intFromBool(detail_start != null),
            @intFromBool(detail_update.command_process_entry != null),
        )) return error.MissingLifecycleTranscriptEntry;
        record.phase = .terminal;
        if (detail_start) |*pending| {
            self.commitLifecycleToolDetailStart(
                alloc,
                id,
                record.entry_id,
                pending,
            );
        }
        self.commitToolDetailTerminal(
            alloc,
            record.entry_id,
            record.activity_kind,
            outcome.kind,
            &detail_update,
        );
        return null;
    }

    fn applyTurnFinishedLifecycle(
        self: *TranscriptRuntime,
        alloc: Allocator,
        finished: types.TurnFinished,
        preserve_normal_buffer_anchor: bool,
    ) !?types.ToolActivityKind {
        if (finished.turn_id == 0) return error.InvalidTurnId;
        if (!self.lifecycle_state.shouldApplyTurnFinished(finished.turn_id)) return null;

        const fallbacks = try self.lifecycle_state.collectFallbackRecords(
            alloc,
            finished.turn_id,
        );
        defer alloc.free(fallbacks);
        const updates = try alloc.alloc(
            transcript_store.LifecycleEntryUpdate,
            fallbacks.len,
        );
        defer alloc.free(updates);
        var lines: std.ArrayList([]u8) = .empty;
        defer {
            for (lines.items) |line| alloc.free(line);
            lines.deinit(alloc);
        }
        var detail_starts: std.ArrayList(PendingToolDetailStart) = .empty;
        defer {
            for (detail_starts.items) |*detail_start| detail_start.deinit(alloc);
            detail_starts.deinit(alloc);
        }
        var missing_detail_count: usize = 0;
        try lines.ensureTotalCapacity(alloc, fallbacks.len);
        try detail_starts.ensureTotalCapacity(alloc, fallbacks.len);
        for (fallbacks, 0..) |fallback, index| {
            if (self.toolDetailPtr(fallback.record.entry_id) == null) {
                missing_detail_count += 1;
            }
            detail_starts.appendAssumeCapacity(try self.prepareToolDetailStart(
                alloc,
                fallback.record.entry_id,
                fallback.record.id,
                fallback.record.tool_name orelse "tool",
                fallback.record.activity_kind,
                null,
            ));
            const line = try lifecycleFallbackLine(
                alloc,
                finished.outcome,
                fallback.was_provisional,
            );
            lines.append(alloc, line) catch |err| {
                alloc.free(line);
                return err;
            };
            updates[index] = .{
                .entry_id = fallback.record.entry_id,
                .bytes = line,
            };
        }
        const replace_result = if (preserve_normal_buffer_anchor)
            transcript_store.replacePinnedToolStatusesPreservingNormalBufferAnchorAtomic(
                self,
                alloc,
                updates,
                missing_detail_count,
            )
        else
            transcript_store.replacePinnedToolStatusesAtomic(
                self,
                alloc,
                updates,
                missing_detail_count,
            );
        replace_result catch |err| {
            traceLifecycleFailure("turn_finished", finished.turn_id, err);
            return err;
        };
        const fallback_outcome: ?types.ToolOutcomeKind = switch (finished.outcome) {
            .completed => .completed,
            .interrupted => .cancelled,
            .failed => .failed,
            .paused => null,
        };
        for (fallbacks, detail_starts.items) |fallback, *detail_start| {
            self.commitToolDetailStart(alloc, fallback.record.entry_id, detail_start);
            const detail = self.toolDetailPtr(fallback.record.entry_id).?;
            detail.outcome = fallback_outcome;
            detail.fallback_disposition = lifecycleFallbackDisposition(
                finished.outcome,
                fallback.was_provisional,
            );
        }
        if (finished.outcome == .paused) {
            const entry_ids = try self.lifecycle_state.pausedTurnEntryIds(
                alloc,
                finished.turn_id,
            );
            defer alloc.free(entry_ids);
            transcript_store.clearLifecyclePinsAtomic(self, alloc, entry_ids) catch |err| {
                traceLifecycleFailure("turn_paused", finished.turn_id, err);
                return err;
            };
            self.lifecycle_state.releasePausedTurn(alloc, finished.turn_id);
        } else {
            self.lifecycle_state.commitTurnFinished(finished.turn_id, fallbacks);
        }
        return null;
    }

    fn createToolActivity(
        self: *TranscriptRuntime,
        alloc: Allocator,
        id: types.ToolLifecycleId,
        tool_name: ?[]const u8,
        activity_kind: types.ToolActivityKind,
        phase: activity_runtime.ToolLifecyclePhase,
    ) !u32 {
        try self.lifecycle_state.ensureRecordCapacity(alloc);
        const owned_call_id = try alloc.dupe(u8, id.call_id);
        errdefer alloc.free(owned_call_id);
        const owned_tool_name = if (tool_name) |name|
            try alloc.dupe(u8, name)
        else
            null;
        errdefer if (owned_tool_name) |name| alloc.free(name);
        const line = try lifecycleStartLine(alloc, tool_name);
        defer alloc.free(line);
        const entry_id = try transcript_store.appendPinnedToolStatusAtomic(
            self,
            alloc,
            line,
        );
        self.lifecycle_state.putOwnedRecord(
            .{ .turn_id = id.turn_id, .call_id = owned_call_id },
            owned_tool_name,
            activity_kind,
            entry_id,
            phase,
        );
        return entry_id;
    }

    const ToolDetailSearch = struct {
        index: usize,
        found: bool,
    };

    fn toolDetailSearch(self: *const TranscriptRuntime, entry_id: u32) ToolDetailSearch {
        var low: usize = 0;
        var high = self.tool_details.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.tool_details.items[middle].entry_id < entry_id) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return .{
            .index = low,
            .found = low < self.tool_details.items.len and
                self.tool_details.items[low].entry_id == entry_id,
        };
    }

    pub fn toolDetailForEntry(self: *const TranscriptRuntime, entry_id: u32) ?*const ToolDetailRecord {
        const search = self.toolDetailSearch(entry_id);
        if (!search.found) return null;
        return &self.tool_details.items[search.index];
    }

    fn toolDetailPtr(self: *TranscriptRuntime, entry_id: u32) ?*ToolDetailRecord {
        const search = self.toolDetailSearch(entry_id);
        if (!search.found) return null;
        return &self.tool_details.items[search.index];
    }

    pub fn attachHistoricalToolDetail(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        call: types.ToolCall,
        activity_kind: types.ToolActivityKind,
        result: types.PersistedToolResult,
    ) !void {
        return self.attachHistoricalToolDetailResolved(
            alloc,
            entry_id,
            call,
            activity_kind,
            result,
            null,
            null,
        );
    }

    pub fn attachHistoricalToolDetailWithLifecycle(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        call: types.ToolCall,
        activity_kind: types.ToolActivityKind,
        result: types.PersistedToolResult,
        lifecycle_id: ?types.ToolLifecycleId,
    ) !void {
        return self.attachHistoricalToolDetailResolved(
            alloc,
            entry_id,
            call,
            activity_kind,
            result,
            lifecycle_id,
            null,
        );
    }

    pub fn attachHistoricalToolDetailAfterCommandOutput(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        call: types.ToolCall,
        activity_kind: types.ToolActivityKind,
        result: types.PersistedToolResult,
    ) !void {
        try self.attachHistoricalToolDetailResolved(
            alloc,
            entry_id,
            call,
            activity_kind,
            result,
            null,
            self.latestCommandOutputEntryId(),
        );
        if (try command_output_runtime.syncCommandOutputBlockEntries(self, alloc)) {
            try self.rebuildTranscriptCacheAfterStructuredRewrite(
                alloc,
                "historical command process presentation",
            );
            self.recomputeCursorFromTranscript();
            self.markTranscriptContentDirty();
        }
    }

    pub fn attachHistoricalToolDetailAfterCommandOutputDetached(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        call: types.ToolCall,
        activity_kind: types.ToolActivityKind,
        result: types.PersistedToolResult,
    ) !void {
        try self.attachHistoricalToolDetailResolved(
            alloc,
            entry_id,
            call,
            activity_kind,
            result,
            null,
            self.latestCommandOutputEntryId(),
        );
    }

    fn attachHistoricalToolDetailResolved(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        call: types.ToolCall,
        activity_kind: types.ToolActivityKind,
        result: types.PersistedToolResult,
        lifecycle_id: ?types.ToolLifecycleId,
        command_output_entry_id: ?u32,
    ) !void {
        const context_deferred = types.isContextDeferredToolResult(result);
        const deferred = types.isDeferredToolResult(result);
        const permission_denied = tool_result_errors.toolPermissionDenialReason(result.output) != null;
        const command_artifact_handle = if (!deferred and !permission_denied and activity_kind == .command)
            command_output_runtime.commandArtifactHandleFromResult(result.output)
        else
            null;
        try self.upsertToolDetailStart(alloc, entry_id, lifecycle_id, call.name, activity_kind, call.arguments_json);
        try self.updateToolDetailTerminal(
            alloc,
            entry_id,
            lifecycle_id,
            call.name,
            activity_kind,
            if (context_deferred)
                .deferred
            else if (deferred or permission_denied)
                .denied
            else if (result.terminal_action_presentation) |presentation|
                presentation.outcomeKind()
            else if (result.status == .success or
                (activity_kind == .command and
                    result.command_process_presentation != null))
                .completed
            else
                .failed,
            if (deferred or permission_denied) null else result.output,
            if (deferred or permission_denied) null else .{
                .output_handle = result.output_handle,
                .preview = result.preview,
                .output_bytes = result.output_bytes,
                .stored_output_bytes = result.stored_output_bytes,
                .truncated = result.truncated,
                .command_output_replay = result.command_output_replay,
                .command_process_presentation = result.command_process_presentation,
                .terminal_action_presentation = result.terminal_action_presentation,
            },
            command_artifact_handle,
            if (deferred or permission_denied) null else command_output_entry_id,
        );
        if (self.toolDetailPtr(entry_id)) |detail| {
            detail.created_at_ms = result.created_at_ms;
        }
    }

    pub fn attachHistoricalToolCallWithoutResult(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        call: types.ToolCall,
    ) !void {
        try self.upsertToolDetailStart(alloc, entry_id, null, call.name, null, call.arguments_json);
        if (self.toolDetailPtr(entry_id)) |detail| detail.outcome = .failed;
    }

    pub fn attachHistoricalCommandOutput(
        self: *TranscriptRuntime,
        _: Allocator,
        entry_id: u32,
    ) void {
        const detail = self.toolDetailPtr(entry_id) orelse return;
        const command_output_entry_id = self.latestCommandOutputEntryId() orelse return;
        detail.command_output_entry_id = command_output_entry_id;
    }

    pub fn attachHistoricalCancelledCommandDetail(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        call: types.ToolCall,
        command_artifact_handle: ?[]const u8,
        replayed_output: bool,
    ) !void {
        try self.upsertToolDetailStart(alloc, entry_id, null, call.name, .command, call.arguments_json);
        try self.updateToolDetailTerminal(
            alloc,
            entry_id,
            null,
            call.name,
            .command,
            .cancelled,
            null,
            null,
            command_artifact_handle,
            if (replayed_output) self.latestCommandOutputEntryId() else null,
        );
    }

    fn upsertToolDetailStart(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        lifecycle_id: ?types.ToolLifecycleId,
        tool_name: []const u8,
        activity_kind: ?types.ToolActivityKind,
        arguments_json: ?[]const u8,
    ) !void {
        var detail_start = try self.prepareToolDetailStart(
            alloc,
            entry_id,
            lifecycle_id,
            tool_name,
            activity_kind,
            arguments_json,
        );
        defer detail_start.deinit(alloc);
        self.commitToolDetailStart(alloc, entry_id, &detail_start);
    }

    fn prepareToolDetailStart(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: ?u32,
        lifecycle_id: ?types.ToolLifecycleId,
        tool_name: []const u8,
        activity_kind: ?types.ToolActivityKind,
        arguments_json: ?[]const u8,
    ) !PendingToolDetailStart {
        const existing = if (entry_id) |id| self.toolDetailPtr(id) else null;
        if (existing == null) try self.tool_details.ensureUnusedCapacity(alloc, 1);

        var pending: PendingToolDetailStart = .{};
        errdefer pending.deinit(alloc);
        pending.tool_name = try alloc.dupe(u8, tool_name);
        pending.activity_kind = activity_kind;
        if (arguments_json) |value| {
            pending.arguments_json = try alloc.dupe(u8, value);
            pending.captured_command = try captured_command.isToolCall(alloc, tool_name, value);
        } else if (std.mem.eql(u8, tool_name, "run_command")) {
            pending.captured_command = true;
        }
        if (lifecycle_id) |id| {
            if (existing == null or !command_output_runtime.sameLifecycleId(existing.?.lifecycle_id, id)) {
                const owned_call_id = try alloc.dupe(u8, id.call_id);
                pending.lifecycle_id = .{
                    .turn_id = id.turn_id,
                    .call_id = owned_call_id,
                };
                pending.replace_lifecycle = true;
            }
        }
        return pending;
    }

    fn commitToolDetailStart(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        pending: *PendingToolDetailStart,
    ) void {
        const search = self.toolDetailSearch(entry_id);
        if (search.found) {
            const detail = &self.tool_details.items[search.index];
            alloc.free(detail.tool_name);
            detail.tool_name = pending.tool_name.?;
            pending.tool_name = null;
            if (pending.captured_command) |value| detail.captured_command = value;
            if (pending.activity_kind) |kind| detail.activity_kind = kind;
            if (pending.arguments_json) |arguments_json| {
                if (detail.arguments_json) |old| alloc.free(old);
                detail.arguments_json = arguments_json;
                pending.arguments_json = null;
            }
            if (pending.replace_lifecycle) {
                if (detail.lifecycle_id) |previous| alloc.free(@constCast(previous.call_id));
                detail.lifecycle_id = pending.lifecycle_id;
                pending.lifecycle_id = null;
            }
            self.markTranscriptContentDirtyFrom(entry_id);
            return;
        }

        const detail = ToolDetailRecord{
            .entry_id = entry_id,
            .tool_name = pending.tool_name.?,
            .captured_command = pending.captured_command orelse false,
            .activity_kind = pending.activity_kind,
            .arguments_json = pending.arguments_json,
            .lifecycle_id = pending.lifecycle_id,
        };
        if (search.index == self.tool_details.items.len) {
            self.tool_details.appendAssumeCapacity(detail);
        } else {
            self.tool_details.insertAssumeCapacity(search.index, detail);
        }
        pending.tool_name = null;
        pending.arguments_json = null;
        pending.lifecycle_id = null;
        self.markTranscriptContentDirtyFrom(entry_id);
    }

    fn commitLifecycleToolDetailStart(
        self: *TranscriptRuntime,
        alloc: Allocator,
        lifecycle_id: types.ToolLifecycleId,
        entry_id: u32,
        pending: *PendingToolDetailStart,
    ) void {
        const classified = pending.captured_command;
        self.commitToolDetailStart(alloc, entry_id, pending);
        if (classified) |captured| {
            if (self.lifecycle_state.recordPtr(lifecycle_id)) |record| {
                record.captured_command = captured;
            }
        }
    }

    fn commitToolPresentationGroup(
        self: *TranscriptRuntime,
        entry_id: u32,
        lifecycle_id: types.ToolLifecycleId,
        presentation_group_id: ?types.ToolPresentationGroupId,
    ) void {
        const incoming = presentation_group_id orelse return;
        if (incoming.turn_id == 0 or
            incoming.anchor_step_id == 0 or
            incoming.turn_id != lifecycle_id.turn_id)
        {
            debug_trace.logf(
                "ui_activity",
                "invalid tool presentation group ignored turn_id={d} group_turn_id={d} anchor_step_id={d}",
                .{ lifecycle_id.turn_id, incoming.turn_id, incoming.anchor_step_id },
            );
            return;
        }
        const detail = self.toolDetailPtr(entry_id) orelse return;
        if (detail.presentation_group_id) |existing| {
            if (existing.turn_id != incoming.turn_id or
                existing.anchor_step_id != incoming.anchor_step_id)
            {
                debug_trace.logf(
                    "ui_activity",
                    "tool presentation group change ignored turn_id={d} existing_anchor_step_id={d} incoming_anchor_step_id={d}",
                    .{
                        lifecycle_id.turn_id,
                        existing.anchor_step_id,
                        incoming.anchor_step_id,
                    },
                );
            }
            return;
        }
        detail.presentation_group_id = incoming;
        self.markTranscriptContentDirtyFrom(entry_id);
    }

    fn updateToolDetailTerminal(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        lifecycle_id: ?types.ToolLifecycleId,
        tool_name: []const u8,
        activity_kind: types.ToolActivityKind,
        outcome: types.ToolOutcomeKind,
        result: ?[]const u8,
        result_memory: ?types.ToolResultMemory,
        command_artifact_handle: ?[]const u8,
        command_output_entry_id_override: ?u32,
    ) !void {
        var pending = try self.prepareToolDetailTerminal(
            alloc,
            lifecycle_id,
            activity_kind,
            result,
            result_memory,
            command_artifact_handle,
            command_output_entry_id_override,
        );
        defer pending.deinit(alloc);
        if (self.toolDetailPtr(entry_id) == null) {
            try self.upsertToolDetailStart(alloc, entry_id, lifecycle_id, tool_name, activity_kind, null);
        }
        self.commitToolDetailTerminal(alloc, entry_id, activity_kind, outcome, &pending);
    }

    fn prepareToolDetailTerminal(
        self: *TranscriptRuntime,
        alloc: Allocator,
        lifecycle_id: ?types.ToolLifecycleId,
        activity_kind: types.ToolActivityKind,
        result: ?[]const u8,
        result_memory: ?types.ToolResultMemory,
        command_artifact_handle: ?[]const u8,
        command_output_entry_id_override: ?u32,
    ) !PendingToolDetailTerminal {
        var pending: PendingToolDetailTerminal = .{};
        errdefer pending.deinit(alloc);
        if (result) |value| pending.result = try alloc.dupe(u8, value);
        const result_handle = if (result_memory) |memory| memory.output_handle else null;
        if (result_handle) |handle| pending.result_handle = try alloc.dupe(u8, handle);
        if (command_artifact_handle) |handle| {
            pending.command_artifact_handle = try alloc.dupe(u8, handle);
        }
        if (result_memory) |memory| {
            if (memory.command_output_replay) |replay| {
                pending.command_output_replay = try types.dupeCommandOutputReplay(alloc, replay);
            }
        }
        pending.command_process_presentation = if (result_memory) |memory|
            memory.command_process_presentation
        else
            null;
        pending.command_output_entry_id = if (activity_kind == .command)
            command_output_entry_id_override orelse
                self.commandOutputEntryIdForLifecycle(lifecycle_id)
        else
            null;
        if (activity_kind == .command and pending.command_process_presentation != null and
            pending.command_output_entry_id == null)
        {
            pending.command_process_entry = try self.prepareCommandProcessPresentationEntry(
                alloc,
                lifecycle_id,
            );
            pending.command_output_entry_id = pending.command_process_entry.?.entry_id;
        }
        return pending;
    }

    fn commitToolDetailTerminal(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        activity_kind: types.ToolActivityKind,
        outcome: types.ToolOutcomeKind,
        pending: *PendingToolDetailTerminal,
    ) void {
        if (pending.command_process_entry) |*entry| {
            self.commitCommandProcessPresentationEntry(entry);
            pending.command_process_entry = null;
        }
        const detail = self.toolDetailPtr(entry_id).?;
        detail.activity_kind = activity_kind;
        detail.outcome = outcome;
        detail.fallback_disposition = null;
        if (pending.result) |owned| {
            if (detail.result) |old| alloc.free(old);
            detail.result = owned;
            pending.result = null;
        }
        if (pending.result_handle) |owned| {
            if (detail.result_handle) |old| alloc.free(old);
            detail.result_handle = owned;
            pending.result_handle = null;
        }
        if (pending.command_artifact_handle) |owned| {
            if (detail.command_artifact_handle) |old| alloc.free(old);
            detail.command_artifact_handle = owned;
            pending.command_artifact_handle = null;
        }
        if (pending.command_output_replay) |owned| {
            if (detail.command_output_replay) |old| {
                types.freeCommandOutputReplay(alloc, old);
            }
            detail.command_output_replay = owned;
            pending.command_output_replay = null;
        }
        detail.command_process_presentation = pending.command_process_presentation;
        if (activity_kind == .command) {
            detail.command_output_entry_id = pending.command_output_entry_id;
        }
        self.markTranscriptContentDirtyFrom(entry_id);
    }

    pub fn hasStoredResultDetails(self: *const TranscriptRuntime) bool {
        for (self.tool_details.items) |detail| {
            if (detail.result_handle != null or
                detail.command_artifact_handle != null or
                detail.command_output_replay != null) return true;
        }
        return false;
    }

    fn commandOutputEntryIdForLifecycle(
        self: *const TranscriptRuntime,
        lifecycle_id: ?types.ToolLifecycleId,
    ) ?u32 {
        const id = lifecycle_id orelse return null;
        for (self.command_output_blocks.items) |block| {
            if (!command_output_runtime.sameLifecycleId(block.lifecycle_id, id)) continue;
            if (block.entry_id) |entry_id| return entry_id;
            if (block.live_entry_ids.items.len > 0) return block.live_entry_ids.items[0];
            if (block.source_entry_ids.items.len > 0) return block.source_entry_ids.items[0];
            for (block.lines.items) |line| {
                if (line.entry_id) |entry_id| return entry_id;
            }
            return null;
        }
        return null;
    }

    fn prepareCommandProcessPresentationEntry(
        self: *TranscriptRuntime,
        alloc: Allocator,
        lifecycle_id: ?types.ToolLifecycleId,
    ) !PendingCommandProcessEntry {
        var pending: PendingCommandProcessEntry = .{ .entry_id = self.next_entry_id };
        errdefer pending.deinit(alloc);
        pending.bytes = try alloc.alloc(u8, 0);

        const line_text = try alloc.alloc(u8, 0);
        var line_text_owned = true;
        errdefer if (line_text_owned) alloc.free(line_text);
        pending.block = .{ .entry_id = pending.entry_id };
        const block = &pending.block.?;
        if (lifecycle_id) |id| {
            const call_id = try alloc.dupe(u8, id.call_id);
            block.lifecycle_id = .{
                .turn_id = id.turn_id,
                .call_id = call_id,
            };
        }
        try block.lines.append(alloc, .{
            .stream = .stdout,
            .text = line_text,
            .entry_id = pending.entry_id,
            .visible = false,
        });
        line_text_owned = false;
        try block.source_entry_ids.append(alloc, pending.entry_id);
        try self.entries.ensureUnusedCapacity(alloc, 1);
        try self.command_output_blocks.ensureUnusedCapacity(alloc, 1);
        return pending;
    }

    fn commitCommandProcessPresentationEntry(
        self: *TranscriptRuntime,
        pending: *PendingCommandProcessEntry,
    ) void {
        std.debug.assert(self.next_entry_id == pending.entry_id);
        self.next_entry_id +%= 1;
        self.entries.appendAssumeCapacity(.{ .raw_bytes = .{
            .id = pending.entry_id,
            .created_at_ms = io_mod.milliTimestamp(),
            .bytes = pending.bytes.?,
            .class = .command_output,
        } });
        pending.bytes = null;
        self.command_output_blocks.appendAssumeCapacity(pending.block.?);
        pending.block = null;
        self.markTranscriptContentDirtyFrom(pending.entry_id);
    }

    fn latestCommandOutputEntryId(self: *const TranscriptRuntime) ?u32 {
        var index = self.command_output_blocks.items.len;
        while (index > 0) {
            index -= 1;
            if (self.command_output_blocks.items[index].entry_id) |entry_id| return entry_id;
        }
        return null;
    }

    pub fn detailEntryIdForCommandOutputSource(
        self: *const TranscriptRuntime,
        source_entry_id: u32,
    ) ?u32 {
        for (self.command_output_blocks.items) |block| {
            var owns_source = block.entry_id == source_entry_id;
            if (!owns_source) {
                for (block.source_entry_ids.items) |source_id| {
                    if (source_id == source_entry_id) {
                        owns_source = true;
                        break;
                    }
                }
            }
            if (!owns_source) {
                for (block.live_entry_ids.items) |live_entry_id| {
                    if (live_entry_id == source_entry_id) {
                        owns_source = true;
                        break;
                    }
                }
            }
            if (!owns_source) continue;
            const lifecycle_id = block.lifecycle_id orelse return null;
            for (self.tool_details.items) |detail| {
                if (command_output_runtime.sameLifecycleId(
                    detail.lifecycle_id,
                    lifecycle_id,
                )) return detail.entry_id;
            }
            return null;
        }
        return null;
    }

    fn clearToolDetails(self: *TranscriptRuntime, alloc: Allocator) void {
        for (self.tool_details.items) |*detail| detail.deinit(alloc);
        self.tool_details.clearRetainingCapacity();
    }

    pub fn pruneToolDetailsForRetainedEntries(
        self: *TranscriptRuntime,
        alloc: Allocator,
        retained_entry_ids: *const transcript_store.EntryIdSet,
    ) void {
        var write_index: usize = 0;
        for (self.tool_details.items, 0..) |detail, read_index| {
            if (!retained_entry_ids.contains(detail.entry_id)) {
                var removed = detail;
                removed.deinit(alloc);
                continue;
            }
            if (write_index != read_index) {
                self.tool_details.items[write_index] = detail;
            }
            write_index += 1;
        }
        self.tool_details.items.len = write_index;
    }

    pub fn clearFullTranscriptDetails(self: *TranscriptRuntime, alloc: Allocator) void {
        self.compact_transcript_source_cache.deinit(alloc);
        self.resetFullTranscriptPageNavigation();
        if (self.full_transcript_installed_page) |*page| page.deinit();
        self.full_transcript_installed_page = null;
        self.clearToolDetails(alloc);
        self.full_transcript = self.full_transcript.closed();
    }

    pub fn resetCommandOutputDisplay(self: *TranscriptRuntime, alloc: Allocator, reason: []const u8) void {
        return command_output_runtime.resetCommandOutputDisplay(self, alloc, reason);
    }

    pub fn retainedStructuredBytesForCommandOutput(
        self: *const TranscriptRuntime,
    ) usize {
        return transcript_store.retainedStructuredBytes(self);
    }

    /// Append a raw-bytes entry. Takes ownership of `bytes` — the slice
    /// must have been allocated by `alloc` and must not be freed by the
    /// caller; the entry is freed on `clearTranscript` or `deinit`.
    /// Returns the stamped entry id.
    pub fn appendRawBytesEntry(self: *TranscriptRuntime, alloc: Allocator, bytes: []const u8) !u32 {
        return transcript_store.appendRawBytesEntry(self, alloc, bytes);
    }

    pub fn appendRawBytesEntryClassified(
        self: *TranscriptRuntime,
        alloc: Allocator,
        bytes: []const u8,
        class: RawEntryClass,
    ) !u32 {
        return transcript_store.appendRawBytesEntryClassified(self, alloc, bytes, class);
    }

    pub fn appendRawBytesEntryClassifiedAt(
        self: *TranscriptRuntime,
        alloc: Allocator,
        bytes: []const u8,
        class: RawEntryClass,
        created_at_ms: i64,
    ) !u32 {
        return transcript_store.appendRawBytesEntryClassifiedAt(
            self,
            alloc,
            bytes,
            class,
            created_at_ms,
        );
    }

    pub fn insertRawBytesEntryClassifiedAfter(
        self: *TranscriptRuntime,
        alloc: Allocator,
        after_entry_id: u32,
        bytes: []const u8,
        class: RawEntryClass,
    ) !?u32 {
        return transcript_store.insertRawBytesEntryClassifiedAfter(self, alloc, after_entry_id, bytes, class);
    }

    pub fn insertRawBytesEntryClassifiedAt(
        self: *TranscriptRuntime,
        alloc: Allocator,
        index: usize,
        bytes: []const u8,
        class: RawEntryClass,
    ) !u32 {
        return transcript_store.insertRawBytesEntryClassifiedAt(self, alloc, index, bytes, class);
    }

    pub fn rowForEntryId(self: *TranscriptRuntime, entry_id: u32) ?u16 {
        return transcript_viewport_runtime.rowForEntryId(self, entry_id);
    }

    pub fn toolStatusEntryLabel(self: *const TranscriptRuntime, entry_id: u32) ?[]const u8 {
        return transcript_store.toolStatusEntryLabel(self, entry_id);
    }

    pub fn transientAssistantGapRows(self: *const TranscriptRuntime) u16 {
        return transcript_viewport_runtime.transientAssistantGapRows(self);
    }

    pub fn needsIdleFooterBottomReservation(self: *const TranscriptRuntime) bool {
        return transcript_viewport_runtime.needsIdleFooterBottomReservation(self);
    }

    pub fn idleFooterGapOffset(self: *const TranscriptRuntime) u16 {
        return transcript_viewport_runtime.idleFooterGapOffset(self);
    }

    pub fn bannerFooterGapOffset(self: *const TranscriptRuntime) u16 {
        return transcript_viewport_runtime.bannerFooterGapOffset(self);
    }

    pub fn preservedBottomReservationRows(self: *const TranscriptRuntime) u16 {
        return transcript_viewport_runtime.preservedBottomReservationRows(self);
    }

    pub fn trimTrailingBlankLines(self: *TranscriptRuntime) void {
        return transcript_store.trimTrailingBlankLines(self);
    }

    pub fn appendRawTranscriptEntry(self: *TranscriptRuntime, alloc: Allocator, text: []const u8) !u32 {
        return transcript_store.appendRawTranscriptEntry(self, alloc, text);
    }

    pub fn appendRawTranscriptEntryClassified(
        self: *TranscriptRuntime,
        alloc: Allocator,
        text: []const u8,
        class: RawEntryClass,
    ) !u32 {
        return transcript_store.appendRawTranscriptEntryClassified(self, alloc, text, class);
    }

    pub fn releaseStartupResumeViewEntry(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
    ) !bool {
        return transcript_store.releaseStartupResumeViewEntry(self, alloc, entry_id);
    }

    pub fn appendTurnSummaryEntry(self: *TranscriptRuntime, alloc: Allocator, summary: types.TurnSummary) !u32 {
        var line_buf: [128]u8 = undefined;
        const line = formatTurnSummaryLine(&line_buf, summary);
        const entry = try std.fmt.allocPrint(alloc, "{s}{s}{s}\n", .{ ui_render.dim_style, line, ui_render.reset_style });
        errdefer alloc.free(entry);
        const entry_id = try transcript_store.appendRawBytesEntryClassifiedAt(
            self,
            alloc,
            entry,
            .turn_summary,
            if (summary.completed_at_ms > 0) summary.completed_at_ms else io_mod.milliTimestamp(),
        );
        if (self.worker_status.clear_recovered_route()) self.render_requests.request(.footer);
        return entry_id;
    }

    /// Swap the bytes of the `raw_bytes` entry with `entry_id` to a dup of
    /// `new_bytes` and regenerate the transcript byte buffer. Returns false
    /// when no such entry exists (e.g. cleared by `clearTranscript`).
    pub fn updateRawBytesEntry(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        new_bytes: []const u8,
    ) !bool {
        return transcript_store.updateRawBytesEntry(self, alloc, entry_id, new_bytes);
    }

    pub fn setRawEntryClass(self: *TranscriptRuntime, entry_id: u32, class: RawEntryClass) bool {
        return transcript_store.setRawEntryClass(self, entry_id, class);
    }

    pub fn rawEntryClass(self: *const TranscriptRuntime, entry_id: u32) ?RawEntryClass {
        return transcript_store.rawEntryClass(self, entry_id);
    }

    /// Renders and records one borrowed user turn as a single transcript
    /// mutation. The caller retains ownership of `user` and `skill_tokens`
    /// on success and error.
    pub fn writeUserPromptCard(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        user: types.UserTurn,
        has_prior_turns: bool,
        skill_tokens: []const input_visual_layout.SkillTokenSpan,
    ) !u32 {
        return transcript_store.writeUserPromptCard(
            self,
            alloc,
            metrics,
            user,
            has_prior_turns,
            skill_tokens,
        );
    }

    /// Consumes `turn` regardless of outcome. All owned slices must use `alloc`;
    /// the entry owns them on success and this method frees them on failure.
    /// Returns the stamped entry id.
    pub fn appendUserTurnOwned(self: *TranscriptRuntime, alloc: Allocator, turn: types.UserTurn) !u32 {
        return transcript_store.appendUserTurnOwned(self, alloc, turn);
    }

    pub fn appendUserTurnOwnedWithSkillTokens(
        self: *TranscriptRuntime,
        alloc: Allocator,
        turn: types.UserTurn,
        skill_tokens: []const input_visual_layout.SkillTokenSpan,
    ) !u32 {
        return transcript_store.appendUserTurnOwnedWithSkillTokens(self, alloc, turn, skill_tokens);
    }

    /// Open a new assistant-turn entry and return its id. Callers that
    /// need to extend the segments text should re-resolve the pointer
    /// with `lookupAssistantSegments(id)` immediately before each use;
    /// a raw segments pointer held across any subsequent `entries`
    /// append is invalidated by ArrayList realloc.
    pub fn appendAssistantTurnEntry(self: *TranscriptRuntime, alloc: Allocator) !u32 {
        return transcript_store.appendAssistantTurnEntry(self, alloc);
    }

    /// Takes ownership of `table` only when it returns successfully.
    pub fn appendAssistantTableOwned(
        self: *TranscriptRuntime,
        alloc: Allocator,
        table: @import("../../core/agent/assistant_presentation.zig").TablePayload,
    ) !u32 {
        return transcript_store.appendAssistantTableOwned(self, alloc, table);
    }

    /// Takes ownership of `block` only when it returns successfully.
    pub fn appendAssistantCodeBlockOwned(
        self: *TranscriptRuntime,
        alloc: Allocator,
        block: @import("../../core/agent/assistant_presentation.zig").CodeBlockPayload,
    ) !u32 {
        return transcript_store.appendAssistantCodeBlockOwned(self, alloc, block);
    }

    pub fn appendAssistantThematicRule(self: *TranscriptRuntime, alloc: Allocator) !u32 {
        return transcript_store.appendAssistantThematicRule(self, alloc);
    }

    /// Walk `entries` and return a pointer to the segments of the
    /// assistant-turn entry with `id`, or null if no such entry exists
    /// (including when `id` belongs to a `raw_bytes` or `user_turn`
    /// entry). The returned pointer is stable only until the next
    /// `entries` append; resolve immediately before use.
    pub fn lookupAssistantSegments(self: *TranscriptRuntime, id: u32) ?*AssistantTurnSegments {
        return transcript_store.lookupAssistantSegments(self, id);
    }

    /// Return a pointer to the trailing entry's segments if that entry
    /// is an assistant turn; otherwise null. Used by the pacer to
    /// append to the in-progress response instead of opening a new
    /// turn when mid-stream.
    pub fn tailAssistantSegments(self: *TranscriptRuntime) ?*AssistantTurnSegments {
        return transcript_store.tailAssistantSegments(self);
    }

    /// Appends paced text to the trailing assistant entry, creating one if needed,
    /// and mirrors it into the transcript buffer. Using `writeTranscript` here
    /// would also create raw entries and double-count content during reflow.
    pub fn streamAssistantChunk(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        text: []const u8,
    ) !u32 {
        const transcript_was_pending = self.render_requests.hasReason(.transcript);
        const entry_id = try transcript_store.streamAssistantChunk(self, alloc, metrics, text);
        if (!transcript_was_pending and
            self.nativeHistoryActive() and
            std.mem.findScalar(u8, text, '\n') == null)
        {
            self.render_requests.clearReason(.transcript);
            debug_trace.logf(
                "scroll",
                "assistant_partial_paint_deferred bytes={d} entry_id={d}",
                .{ text.len, entry_id },
            );
        }
        return entry_id;
    }

    pub fn retintEntriesForTheme(
        self: *TranscriptRuntime,
        alloc: Allocator,
        from_light: bool,
        to_light: bool,
    ) !void {
        return transcript_store.retintEntriesForTheme(self, alloc, from_light, to_light);
    }

    pub fn setTranscriptPresentationDepth(
        self: *TranscriptRuntime,
        alloc: Allocator,
        depth: transcript_presentation.Depth,
    ) !bool {
        const current = self.full_transcript.depth;
        if (current == depth) return false;
        if (current == .inline_mode and depth != .inline_mode) {
            self.full_transcript_open_content_revision = self.full_transcript_content_revision;
            self.full_transcript_open_cols = self.layout.cols;
            self.full_transcript_open_rows = self.layout.rows;
            try self.captureFullTranscriptAnchor(alloc);
        }
        self.full_transcript = self.full_transcript.with_depth(depth);
        if (depth == .inline_mode) {
            self.full_transcript_open_content_revision = null;
            self.full_transcript_open_cols = 0;
            self.full_transcript_open_rows = 0;
            self.full_transcript_primary_recovery_entry_id = null;
            self.resetFullTranscriptPageNavigation();
        }
        self.markTranscriptDirty();
        return true;
    }

    pub fn fullTranscriptPrimaryRestore(self: *const TranscriptRuntime) FullTranscriptPrimaryRestore {
        const open_revision = self.full_transcript_open_content_revision orelse return .changed;
        const same_geometry = self.full_transcript_open_cols == self.layout.cols and
            self.full_transcript_open_rows == self.layout.rows;
        const needs_repair = !same_geometry or
            self.terminal_reset_pending or
            self.resize_history_row_delta != null;
        if (open_revision != self.full_transcript_content_revision) {
            return if (needs_repair) .changed_resized else .changed;
        }
        return if (needs_repair) .resized else .exact;
    }

    pub fn prepareRestoredPrimaryTranscriptRecovery(
        self: *TranscriptRuntime,
        alloc: Allocator,
    ) !?[]u8 {
        const anchor_entry_id = self.full_transcript_primary_recovery_entry_id orelse {
            debug_trace.logf(
                "full_transcript_cache",
                "primary recovery unavailable reason=missing_entry_id revision={d}",
                .{self.full_transcript_content_revision},
            );
            return null;
        };
        var source = try self.prepareTranscriptSourceWithFocusedEntry(
            alloc,
            anchor_entry_id,
        );
        defer source.deinit(alloc);
        try source.ensureLineIndex(alloc);
        const start_line = source.tracked_entry_start_line orelse
            fullTranscriptRecoveryPredecessorStartLine(
                source.line_provenance,
                anchor_entry_id,
            ) orelse {
            debug_trace.logf(
                "full_transcript_cache",
                "primary recovery unavailable reason=no_visible_predecessor entry_id={d} revision={d}",
                .{ anchor_entry_id, self.full_transcript_content_revision },
            );
            return null;
        };
        if (start_line >= source.transcript_visible_lines.len or
            source.transcript_visible_lines.len != source.transcript_line_visual_rows.len)
        {
            debug_trace.logf(
                "full_transcript_cache",
                "primary recovery unavailable reason=line_index entry_id={d} start_line={d} visible_lines={d} visual_rows={d}",
                .{
                    anchor_entry_id,
                    start_line,
                    source.transcript_visible_lines.len,
                    source.transcript_line_visual_rows.len,
                },
            );
            return null;
        }

        const replay = try transcript_painter.prepareResetReplayDocument(
            self,
            alloc,
            source.bytes,
            source.transcript_visible_lines[start_line..],
            source.transcript_line_visual_rows[start_line..],
            source.hard_lines_end_with_newline,
            self.layout.rows -| self.layout.content_bottom,
        );
        defer if (replay.len > 0) alloc.free(replay);

        const clear_visible = "\x1b[0m\x1b[2J\x1b[H";
        const recovery = try alloc.alloc(u8, clear_visible.len + replay.len);
        @memcpy(recovery[0..clear_visible.len], clear_visible);
        @memcpy(recovery[clear_visible.len..], replay);
        debug_trace.logf(
            "full_transcript_cache",
            "primary recovery prepared entry_id={d} start_line={d} total_lines={d} bytes={d}",
            .{ anchor_entry_id, start_line, source.transcript_visible_lines.len, recovery.len },
        );
        return recovery;
    }

    pub fn retainRestoredPrimaryTranscript(self: *TranscriptRuntime) void {
        self.transcript_band_dirty = false;
        self.render_requests.clearReason(.transcript);
        self.render_requests.request(.footer);
        debug_trace.logf(
            "full_transcript_cache",
            "close reused restored primary transcript revision={d}",
            .{self.full_transcript_content_revision},
        );
    }

    pub fn repaintRestoredPrimaryTranscriptAfterResize(self: *TranscriptRuntime) void {
        self.terminal_reset_pending = false;
        self.resize_history_row_delta = null;
        self.pending_resize_observation = null;
        self.render_requests.acknowledgeSettledResizeCommit();
        self.invalidateTranscriptAnchor("full transcript restored resized primary");
        debug_trace.logf(
            "full_transcript_cache",
            "close repaints restored resized primary revision={d} layout={d}x{d}",
            .{ self.full_transcript_content_revision, self.layout.cols, self.layout.rows },
        );
    }

    fn captureFullTranscriptAnchor(self: *TranscriptRuntime, alloc: Allocator) !void {
        _ = alloc;
        self.full_transcript = self.full_transcript.clear_anchor();
        const fallback_recovery_entry_id = self.primaryRecoveryFallbackEntryId();
        self.full_transcript_primary_recovery_entry_id = fallback_recovery_entry_id;
        const selection = self.last_viewport_selection orelse return;
        const provenance = self.committedRowProvenance();
        var source: ?transcript_blocks.LineProvenance = null;
        for (provenance) |row| {
            if (row.row < selection.top_row) continue;
            source = row.source;
            break;
        }
        const source_entry_id = switch (source orelse return) {
            .entry => |entry| entry.entry_id,
            .folded_command_output => |output| output.entry_id,
            else => null,
        };
        const anchor_entry_id = if (source_entry_id) |entry_id|
            self.detailEntryIdForCommandOutputSource(entry_id) orelse entry_id
        else
            null;
        self.full_transcript_primary_recovery_entry_id =
            source_entry_id orelse fallback_recovery_entry_id;
        self.full_transcript = self.full_transcript.capture_anchor(anchor_entry_id);
    }

    fn primaryRecoveryFallbackEntryId(self: *const TranscriptRuntime) ?u32 {
        if (self.entries.items.len == 0) return null;
        const retained_entries = @min(
            self.entries.items.len,
            @max(@as(usize, self.layout.rows), 1),
        );
        return self.entries.items[self.entries.items.len - retained_entries].id();
    }

    fn fullTranscriptRecoveryPredecessorStartLine(
        provenance: []const transcript_blocks.LineProvenance,
        target_entry_id: u32,
    ) ?usize {
        var candidate_entry_id: ?u32 = null;
        var candidate_start_line: ?usize = null;
        for (provenance, 0..) |source, line_index| {
            const entry_id = switch (source) {
                .entry => |entry| entry.entry_id,
                .folded_command_output => |output| output.entry_id orelse continue,
                else => continue,
            };
            if (entry_id > target_entry_id) continue;
            if (candidate_entry_id == null or entry_id > candidate_entry_id.?) {
                candidate_entry_id = entry_id;
                candidate_start_line = line_index;
            }
        }
        return candidate_start_line;
    }

    pub fn fullTranscriptActive(self: *const TranscriptRuntime) bool {
        return self.full_transcript.depth.active();
    }

    pub fn transcriptPresentationDepth(
        self: *const TranscriptRuntime,
    ) transcript_presentation.Depth {
        return self.full_transcript.depth;
    }

    pub const FullTranscriptViewportSnapshot = struct {
        presentation: transcript_presentation.Snapshot,
        page_anchor: full_transcript_page.Anchor,
    };

    pub fn snapshotFullTranscriptViewport(
        self: *const TranscriptRuntime,
    ) FullTranscriptViewportSnapshot {
        return .{
            .presentation = self.full_transcript.snapshot(),
            .page_anchor = self.full_transcript_page_anchor,
        };
    }

    pub fn restoreFullTranscriptViewport(
        self: *TranscriptRuntime,
        snapshot: FullTranscriptViewportSnapshot,
    ) void {
        self.full_transcript = .from_snapshot(snapshot.presentation);
        self.full_transcript_page_anchor = snapshot.page_anchor;
        self.markTranscriptDirty();
    }

    pub fn requestTailViewport(
        self: *TranscriptRuntime,
        request: viewport_selection.TailViewportPolicy,
    ) void {
        const changed = if (self.tail_viewport_request) |current|
            !std.meta.eql(current, request)
        else
            true;
        self.tail_viewport_request = request;
        self.tail_viewport_resolution = null;
        const has_committed_anchor = switch (self.transcript_commit_state) {
            .invalid => false,
            .stable, .recovering => true,
        };
        if (changed and has_committed_anchor) {
            self.invalidateTranscriptAnchor("tail viewport changed");
        }
    }

    pub fn resolvedTailViewport(
        self: *const TranscriptRuntime,
    ) ?viewport_selection.TailOffsetResolution {
        return self.tail_viewport_resolution;
    }

    pub fn closeFullTranscriptState(self: *TranscriptRuntime) void {
        self.full_transcript = self.full_transcript.closed();
        self.resetFullTranscriptPageNavigation();
    }

    fn resetFullTranscriptPageNavigation(self: *TranscriptRuntime) void {
        self.full_transcript_page_anchor = .tail;
        self.full_transcript_page_load.cancelActive();
    }

    pub fn fullTranscriptAnchorEntryId(self: *const TranscriptRuntime) ?u32 {
        return self.full_transcript.anchor_entry_id;
    }

    pub fn retargetFullTranscriptAnchor(self: *TranscriptRuntime, entry_id: u32) void {
        self.full_transcript = self.full_transcript.retarget_anchor(entry_id);
    }

    pub fn scrollFullTranscript(
        self: *TranscriptRuntime,
        direction: input_action.MouseWheel,
        unit: FullTranscriptScrollUnit,
    ) void {
        if (self.full_transcript_page_load.busy() and
            self.installedFullTranscriptPageProjection() == null)
        {
            debug_trace.logf(
                "full_transcript_cache",
                "scroll_ignored reason=page_loading direction={s} unit={s}",
                .{ @tagName(direction), @tagName(unit) },
            );
            return;
        }
        const rows = switch (unit) {
            .wheel => full_transcript_wheel_rows,
            .page => self.fullTranscriptPageRows(),
        };
        const before = self.full_transcript.scroll_rows;
        self.full_transcript = self.full_transcript.scroll(switch (direction) {
            .up => .up,
            .down => .down,
        }, rows);
        const local_visible_rows = @max(@as(u32, 1), self.layout.rows -| 4);
        const local_total_rows = if (self.full_transcript_installed_page) |*page|
            page.projection.measured_total_rows
        else
            0;
        const local_max_offset = local_total_rows -| local_visible_rows;
        const adjacent_anchor = switch (direction) {
            .up => if (before == 0 and self.full_transcript.scroll_rows == 0)
                if (self.full_transcript_installed_page) |*page|
                    full_transcript_page.previousAnchor(page.source.range)
                else
                    null
            else
                null,
            .down => if (before >= local_max_offset and
                self.full_transcript_installed_page != null)
                full_transcript_page.nextAnchor(
                    self.full_transcript_installed_page.?.source.range,
                    self.entries.items.len,
                )
            else
                null,
        };
        if (adjacent_anchor) |anchor| {
            const boundary_index = switch (anchor) {
                .entry_index => |index| index,
                .tail => unreachable,
            };
            if (boundary_index < self.entries.items.len) {
                self.full_transcript_page_anchor = anchor;
                self.full_transcript = self.full_transcript.select_page_boundary(
                    self.entries.items[boundary_index].id(),
                );
            }
        }
        debug_trace.logf(
            "full_transcript_cache",
            "scroll depth={s} direction={s} unit={s} rows={d} before={d} after={d}",
            .{
                @tagName(self.full_transcript.depth),
                @tagName(direction),
                @tagName(unit),
                rows,
                before,
                self.full_transcript.scroll_rows,
            },
        );
    }

    pub const FullTranscriptScrollUnit = enum {
        wheel,
        page,
    };

    const full_transcript_wheel_rows: u32 = 3;

    fn fullTranscriptPageRows(self: *const TranscriptRuntime) u32 {
        const first_row = if (self.owned_top_row == 0) 1 else self.owned_top_row;
        if (self.layout.content_bottom >= first_row) {
            return @max(@as(u32, 1), @as(u32, self.layout.content_bottom - first_row + 1));
        }
        return 1;
    }

    pub fn initViewport(self: *TranscriptRuntime, metrics: *Metrics, requested_start_row: u16) !void {
        return transcript_viewport_runtime.initViewport(self, metrics, requested_start_row);
    }

    pub fn initViewportWithReservedRows(self: *TranscriptRuntime, metrics: *Metrics, requested_start_row: u16, min_body_rows: u16) !void {
        return transcript_viewport_runtime.initViewportWithReservedRows(self, metrics, requested_start_row, min_body_rows);
    }

    pub fn requestTerminalReset(self: *TranscriptRuntime, metrics: *Metrics) !void {
        const min_body_rows = self.min_visible_viewport_rows;
        self.reflow_clear_guard_rows = 0;
        self.resize_history_row_delta = null;
        self.viewport_clear_pending = false;
        // Job-control resume (and other full resets) reanchor at row 1. Drop
        // pending clears recorded against the pre-reset footer geometry —
        // e.g. eraseCurrentFrame at owned_top mid-scrollback — or the first
        // post-reset plan validates them against the new compact bands and
        // aborts with InvalidInvalidationRange.
        self.render_requests.clearPendingInvalidations();
        self.footer_viewport.has_frame = false;
        self.footer_viewport.clearExternalInvalidation();
        self.terminal_reset_pending = true;
        try self.initViewportWithReservedRows(metrics, 1, min_body_rows);
    }

    pub fn requestTerminalResetAfterResize(
        self: *TranscriptRuntime,
        metrics: *Metrics,
        history_row_delta: ?i32,
    ) !void {
        try self.requestTerminalReset(metrics);
        self.resize_history_row_delta = history_row_delta;
    }

    pub fn reserveVisibleViewportRows(self: *TranscriptRuntime, min_body_rows: u16) void {
        return transcript_viewport_runtime.reserveVisibleViewportRows(self, min_body_rows);
    }

    pub fn reanchorTop(self: *TranscriptRuntime, alloc: Allocator, metrics: *Metrics) !void {
        return transcript_viewport_runtime.reanchorTop(self, alloc, metrics);
    }

    pub fn footerTopRowForExtra(self: TranscriptRuntime, extra: u16) u16 {
        return transcript_viewport_runtime.footerTopRowForExtra(self, extra);
    }

    pub fn forgetShimmer(self: *TranscriptRuntime) void {
        self.shimmer_active = false;
        self.shimmer_is_overlay = false;
        self.paint_trace.shimmer_row = null;
        self.paint_trace.shimmer_over_footer = false;
        self.paint_trace.shimmer_label_hash = 0;
    }

    pub fn transcriptCommitDiagnostic(self: *const TranscriptRuntime) TranscriptCommitDiagnostic {
        return switch (self.transcript_commit_state) {
            .invalid => .{ .state = .invalid },
            .stable => |anchor| .{
                .state = .stable,
                .stable_start_line = anchor.selection.start_line,
                .visual_offset = anchor.visual_offset,
                .layout_id = anchor.layout_id,
            },
            .recovering => |receipt| .{
                .state = .recovering,
                .visual_offset = receipt.accepted_visual_offset,
                .remaining_inline_rows = @as(u32, receipt.remaining_resize_reflow_rows) +
                    receipt.remaining_semantic_rows,
                .remaining_unplanned_scroll_rows = receipt.remaining_unplanned_scroll_rows,
            },
        };
    }

    pub fn stableTranscriptProjectionForFlow(
        self: *const TranscriptRuntime,
        rendered_flow: []const u8,
    ) ?StableTranscriptProjection {
        const anchor = switch (self.transcript_commit_state) {
            .stable => |value| value,
            .invalid, .recovering => return null,
        };
        if (!std.mem.startsWith(u8, rendered_flow, anchor.flow)) return null;
        return .{
            .selection = anchor.selection,
            .visual_offset = committedProjectionVisualOffset(anchor),
            .history_visual_offset = anchor.history_visual_offset,
            .total_visual_rows = anchor.total_visual_rows,
            .flow_unchanged = rendered_flow.len == anchor.flow.len,
            .cursor_row = anchor.cursor_row,
            .cursor_col = anchor.cursor_col,
            .occupied_last_row = anchor.occupied_last_row,
            .occupied_last_row_blank = anchor.occupied_last_row_blank,
            .layout_id = anchor.layout_id,
            .measured_history_origin = anchor.measured_history_origin,
        };
    }

    pub fn measuredResizeProjectionForFlow(
        self: *const TranscriptRuntime,
        rendered_flow: []const u8,
    ) ?MeasuredResizeProjection {
        return switch (self.transcript_commit_state) {
            .invalid => null,
            .stable => if (self.stableTranscriptProjectionForFlow(rendered_flow) != null)
                .stable
            else
                null,
            .recovering => |receipt| blk: {
                if (receipt.attempt_cols == 0 or
                    !std.mem.startsWith(u8, rendered_flow, receipt.flow))
                {
                    break :blk null;
                }
                break :blk .{ .recovering = .{
                    .accepted_visual_offset = receipt.accepted_visual_offset,
                    .source_cols = receipt.attempt_cols,
                } };
            },
        };
    }

    pub fn measuredHistoryOriginForFlow(
        self: *const TranscriptRuntime,
        rendered_flow: []const u8,
    ) ?transcript_painter.MeasuredHistoryOriginProjection {
        return switch (self.transcript_commit_state) {
            .invalid => null,
            .stable => |anchor| blk: {
                if (!std.mem.startsWith(u8, rendered_flow, anchor.flow)) {
                    break :blk null;
                }
                const origin = anchor.measured_history_origin orelse
                    break :blk null;
                break :blk .{
                    .origin = origin,
                    .current_cols = self.committed_frame_layout.terminal_cols,
                };
            },
            .recovering => |receipt| blk: {
                if (!std.mem.startsWith(u8, rendered_flow, receipt.flow)) {
                    break :blk null;
                }
                const origin = receipt.measured_history_origin orelse
                    break :blk null;
                break :blk .{
                    .origin = origin,
                    .current_cols = receipt.attempt_cols,
                };
            },
        };
    }

    pub fn invalidateTranscriptAnchor(self: *TranscriptRuntime, reason: []const u8) void {
        const diagnostic = self.transcriptCommitDiagnostic();
        if (diagnostic.state != .invalid) {
            debug_trace.logf(
                "scroll",
                "transcript_anchor_invalidate state={s} stable_start={d} visual_offset={d} reason={s}",
                .{
                    @tagName(diagnostic.state),
                    diagnostic.stable_start_line orelse 0,
                    diagnostic.visual_offset,
                    reason,
                },
            );
        }
        const alloc = self.shadow_vt_alloc orelse self.detached_commit_alloc orelse {
            std.debug.assert(self.transcript_commit_state == .invalid);
            return;
        };
        self.transcript_commit_state.deinit(alloc);
    }

    pub fn reconcileTranscriptCommitSource(
        self: *TranscriptRuntime,
        rendered_flow: []const u8,
        force_rebase: bool,
        reason: []const u8,
    ) void {
        self.reconcileTranscriptCommitSourceWithRewriteMode(
            rendered_flow,
            force_rebase,
            reason,
            .strict,
        );
    }

    pub fn reconcileTranscriptCommitSourceWithRewriteMode(
        self: *TranscriptRuntime,
        rendered_flow: []const u8,
        force_rebase: bool,
        reason: []const u8,
        mode: transcript_store.TranscriptSourceRewriteMode,
    ) void {
        switch (self.transcript_commit_state) {
            .invalid => {},
            .stable => |*anchor| {
                const source_compatible = std.mem.startsWith(u8, rendered_flow, anchor.flow);
                if (force_rebase or !source_compatible) {
                    if (!force_rebase and mode == .preserve_same_epoch) {
                        if (self.structuredRewritePreserveBlocker(anchor.*, rendered_flow)) |blocker| {
                            debug_trace.logf(
                                "scroll",
                                "transcript_anchor_structured_rewrite_fallback blocker={s} reason={s}",
                                .{ blocker, reason },
                            );
                        } else {
                            debug_trace.logf(
                                "scroll",
                                "transcript_anchor_structured_rewrite_preserve stable_start={d} visual_offset={d} reason={s}",
                                .{
                                    anchor.selection.start_line,
                                    anchor.visual_offset,
                                    reason,
                                },
                            );
                            anchor.normal_buffer_recovery_pending = true;
                            return;
                        }
                    }
                    self.invalidateTranscriptAnchor(reason);
                }
            },
            .recovering => |*receipt| {
                if (!force_rebase and
                    std.mem.startsWith(u8, rendered_flow, receipt.flow))
                {
                    return;
                }
                receipt.measured_history_origin = null;
                if (receipt.projection_rebase_pending and
                    !receipt.tracks_semantic_progress and
                    receipt.remaining_semantic_rows == 0 and
                    receipt.remaining_semantic_progress_rows == 0 and
                    !receipt.document_append_committed)
                {
                    return;
                }
                debug_trace.logf(
                    "scroll",
                    "transcript_recovery_source_rebase remaining_resize_reflow_rows={d} dropped_semantic_rows={d} append_committed={s} reason={s}",
                    .{
                        receipt.remaining_resize_reflow_rows,
                        receipt.remaining_semantic_rows,
                        if (receipt.document_append_committed) "true" else "false",
                        reason,
                    },
                );
                receipt.remaining_semantic_rows = 0;
                receipt.remaining_semantic_progress_rows = 0;
                receipt.projection_rebase_pending = true;
                receipt.tracks_semantic_progress = false;
                receipt.document_append_committed = false;
            },
        }
    }

    fn structuredRewritePreserveBlocker(
        self: *const TranscriptRuntime,
        anchor: CommittedTranscriptAnchor,
        rendered_flow: []const u8,
    ) ?[]const u8 {
        if (anchor.flow.len == 0) return "empty_anchor";
        if (rendered_flow.len == 0) return "empty_rendered_flow";
        if (self.resize_history_row_delta != null) return "resize_history_pending";
        if (self.layout.cols == 0 or self.layout.rows == 0) return "empty_runtime_layout";

        const committed = self.committed_frame_layout;
        if (anchor.layout_id != committed.layout_id) return "layout_epoch_mismatch";
        if (committed.terminal_cols == 0 or committed.terminal_rows == 0) {
            return "empty_committed_geometry";
        }
        if (committed.terminal_cols != self.layout.cols or
            committed.terminal_rows != self.layout.rows)
        {
            return "geometry_changed";
        }
        if (committed.transcript_area.isEmpty()) return "empty_transcript_area";
        if (anchor.visual_offset > anchor.total_visual_rows) return "invalid_visual_offset";
        if (anchor.history_visual_offset > anchor.total_visual_rows) {
            return "invalid_history_visual_offset";
        }

        return null;
    }

    fn materializedTranscriptProjection(
        self: *const TranscriptRuntime,
        source_visual_offset: u32,
        area: render_engine.frame_layout.FrameRect,
    ) ?MaterializedTranscriptProjection {
        const area_rows = if (area.isEmpty()) 0 else area.height();
        return switch (self.transcript_commit_state) {
            .invalid => null,
            .stable => |anchor| if (committedProjectionVisualOffset(anchor) != source_visual_offset)
                null
            else
                .{
                    .raw_flow_exact = true,
                    .visual_rows = projectionVisualRowsInArea(
                        anchor.total_visual_rows,
                        committedProjectionVisualOffset(anchor),
                        area,
                    ),
                },
            .recovering => |receipt| if (receipt.materialized_visual_offset !=
                source_visual_offset)
                null
            else
                .{
                    .raw_flow_exact = receipt.materialized_flow_len != null,
                    .visual_rows = @min(
                        receipt.materialized_visual_rows,
                        area_rows,
                    ),
                },
        };
    }

    fn plannedTranscriptRows(
        self: *const TranscriptRuntime,
        prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
        source_visual_offset: u32,
        resize_reflow_rows: u16,
        semantic_rows: u32,
        semantic_progress_rows: u32,
    ) u16 {
        const semantic_cap = if (self.pending_resume_source != null)
            resume_publication_rows_per_frame
        else
            std.math.maxInt(u32);
        const planned = frameInlineScrollBudgetCapped(
            resize_reflow_rows,
            semantic_rows,
            semantic_cap,
        );
        if (semantic_rows == 0) return planned;

        const materialized = self.materializedTranscriptProjection(
            source_visual_offset,
            prepared.projectionArea(),
        );
        if (materialized) |projection| {
            if (!projection.raw_flow_exact) {
                return frameInlineScrollBudgetCapped(
                    resize_reflow_rows,
                    semantic_rows,
                    @min(projection.visual_rows, semantic_cap),
                );
            }
        }

        const accepted = acceptedTranscriptRowsForInlineRows(
            planned,
            resize_reflow_rows,
            semantic_rows,
            semantic_progress_rows,
        );
        if (accepted.semantic_progress_rows == 0) return planned;

        const accepts_all_semantic_rows =
            accepted.semantic_rows == semantic_rows and
            accepted.semantic_progress_rows == semantic_progress_rows;
        if (accepts_all_semantic_rows) return planned;
        const exactness =
            transcript_painter.preparedTranscriptStagedFlowEndExactness(
                prepared,
                self.layout.cols,
                prepared.projectionArea(),
                source_visual_offset + accepted.semantic_progress_rows,
            );
        if (exactness == null or exactness.?) return planned;

        const projection = materialized orelse return planned;
        return frameInlineScrollBudgetCapped(
            resize_reflow_rows,
            semantic_rows,
            @min(projection.visual_rows, semantic_cap),
        );
    }

    pub fn planTranscriptScroll(
        self: *const TranscriptRuntime,
        prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
    ) TranscriptScrollFacts {
        return self.planTranscriptScrollForFrame(prepared, false, false);
    }

    /// Selects the finality floor in flow bytes from the prepared paint's
    /// activity-independent candidates plus the frame-fresh producer facts
    /// (lifecycle watermark, assistant-tail writability, replaceable tail).
    /// Null means the whole flow is final. Pure over its inputs, so repeated
    /// calls within one frame agree.
    fn finalityFloorBytes(
        self: *const TranscriptRuntime,
        prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
    ) ?usize {
        return self.transcript_release.finality_floor(
            prepared.finality_candidates,
            self.finalizedToolTurnWatermark(),
            if (prepared.replaceable_last_line) prepared.replaceable_start else null,
        );
    }

    /// Visual rows contributed by the flow prefix [0..flow_offset). The
    /// prefix boundary always lands on an entry start, which is a hard-line
    /// start; a mid-line offset rounds down to its line, the safe direction.
    fn preparedVisualRowsForFlowOffset(
        prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
        flow_offset: usize,
    ) u32 {
        if (flow_offset == 0) return 0;
        if (flow_offset >= prepared.bytes.len) return prepared.sourceTotalVisualRows();
        const lines = prepared.sourceVisibleLines();
        const visual_rows = prepared.sourceVisualRows();
        var rows: u32 = 0;
        for (lines, 0..) |line, index| {
            switch (line) {
                .transcript => |t| if (t.ref.ref.start >= flow_offset) return rows,
                .folded_line => {},
            }
            if (index < visual_rows.len) rows += visual_rows[index];
        }
        return rows;
    }

    /// The largest visual offset whose rows are all backed by final entries,
    /// clamped to the frame's target offset. Release permission never
    /// extends past this value.
    fn finalityReleasableOffset(
        self: *const TranscriptRuntime,
        prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
        target_offset: u32,
    ) u32 {
        const floor_bytes = self.finalityFloorBytes(prepared) orelse return target_offset;
        const floor_rows = preparedVisualRowsForFlowOffset(prepared, floor_bytes);
        return @min(target_offset, floor_rows);
    }

    pub fn planTranscriptScrollForFrame(
        self: *const TranscriptRuntime,
        prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
        footer_reservation_changed: bool,
        replay_displaced_footer_history: bool,
    ) TranscriptScrollFacts {
        const target_offset = prepared.sourceVisualOffset();
        const target_total_visual_rows = prepared.sourceTotalVisualRows();
        if (self.terminal_reset_pending) {
            debug_trace.logf(
                "scroll",
                "transcript_transition_plan source_state=reset target_visual_offset={d} target_total_visual_rows={d} planned_rows=0",
                .{ target_offset, target_total_visual_rows },
            );
            return .{
                .target_visual_offset = target_offset,
                .recovery_rebase = true,
            };
        }
        const anchor = switch (self.transcript_commit_state) {
            .stable => |value| value,
            .recovering => |receipt| {
                const source_equal = std.mem.eql(u8, prepared.bytes, receipt.flow);
                const source_prefix_growth = prepared.bytes.len > receipt.flow.len and
                    std.mem.startsWith(u8, prepared.bytes, receipt.flow);
                const source_compatible = source_equal or source_prefix_growth;
                const source_visual_compatible = if (source_equal)
                    target_total_visual_rows == receipt.attempt_total_visual_rows
                else if (source_prefix_growth)
                    target_total_visual_rows >= receipt.attempt_total_visual_rows
                else
                    false;
                const resize_history_compatible = self.resize_history_row_delta == null or
                    (!receipt.attempt_resize_history_committed and
                        self.resize_history_row_delta == receipt.attempt_resize_history_row_delta);
                const recovery_progress_compatible = source_compatible and
                    source_visual_compatible and
                    receipt.attempt_cols == self.layout.cols and
                    resize_history_compatible;
                const recovery_rebase =
                    receipt.projection_rebase_pending or !recovery_progress_compatible;
                const recovery_tracks_semantic_progress =
                    receipt.tracks_semantic_progress and source_compatible;
                const growth_rows: u32 = if (recovery_progress_compatible and
                    recovery_tracks_semantic_progress and
                    source_prefix_growth)
                    target_total_visual_rows - receipt.attempt_total_visual_rows
                else
                    0;
                const measured_resize_rebase =
                    self.resize_history_row_delta != null and
                    prepared.measured_resize_target_provenance == .recovering;
                const resize_reflow_rows = if (measured_resize_rebase)
                    0
                else
                    receipt.remaining_resize_reflow_rows;
                const retained_semantic_rows = if (source_compatible)
                    receipt.remaining_semantic_rows
                else
                    0;
                const retained_semantic_progress_rows =
                    if (recovery_progress_compatible and
                    recovery_tracks_semantic_progress)
                        receipt.remaining_semantic_progress_rows
                    else
                        0;
                const candidate_semantic_rows = retained_semantic_rows + growth_rows;
                const candidate_semantic_progress_rows =
                    retained_semantic_progress_rows + growth_rows;
                // Retained debt repairs the attempted frame. Only source
                // growth is a new content release that needs finality.
                const semantic_rows, const semantic_progress_rows = if (self.finalityFloorBytes(prepared) != null) bounded: {
                    const releasable_offset = self.finalityReleasableOffset(
                        prepared,
                        target_offset,
                    );
                    const bounded_growth_rows = @min(
                        growth_rows,
                        releasable_offset -| (receipt.accepted_history_visual_offset +
                            retained_semantic_rows),
                    );
                    const bounded_rows = retained_semantic_rows + bounded_growth_rows;
                    const bounded_progress_growth_rows = @min(
                        growth_rows,
                        releasable_offset -| (receipt.accepted_visual_offset +
                            retained_semantic_progress_rows),
                    );
                    break :bounded .{
                        bounded_rows,
                        @min(
                            retained_semantic_progress_rows + bounded_progress_growth_rows,
                            bounded_rows,
                        ),
                    };
                } else .{
                    candidate_semantic_rows,
                    candidate_semantic_progress_rows,
                };
                const acknowledged_visual_offset =
                    receipt.accepted_visual_offset + semantic_progress_rows;
                const recovery_projection_deferred = recovery_progress_compatible and
                    recovery_tracks_semantic_progress and
                    transcript_painter.preparedTranscriptProjectionExceedsArea(
                        prepared,
                        prepared.projectionArea(),
                        acknowledged_visual_offset,
                    );
                const planned_rows = if (recovery_projection_deferred)
                    0
                else
                    self.plannedTranscriptRows(
                        prepared,
                        receipt.accepted_visual_offset,
                        resize_reflow_rows,
                        semantic_rows,
                        semantic_progress_rows,
                    );
                debug_trace.logf(
                    "scroll",
                    "transcript_transition_plan source_state=recovering source_visual_offset={d} attempt_visual_offset={d} target_visual_offset={d} attempt_total_visual_rows={d} target_total_visual_rows={d} remaining_resize_reflow_rows={d} remaining_semantic_rows={d} remaining_semantic_progress_rows={d} growth_rows={d} semantic_progress_rows={d} planned_rows={d} source_compatible={s} recovery_progress_compatible={s} recovery_rebase={s} recovery_projection_deferred={s}",
                    .{
                        receipt.accepted_visual_offset,
                        receipt.attempt_visual_offset,
                        target_offset,
                        receipt.attempt_total_visual_rows,
                        target_total_visual_rows,
                        receipt.remaining_resize_reflow_rows,
                        receipt.remaining_semantic_rows,
                        receipt.remaining_semantic_progress_rows,
                        growth_rows,
                        semantic_progress_rows,
                        planned_rows,
                        if (source_compatible) "true" else "false",
                        if (recovery_progress_compatible) "true" else "false",
                        if (recovery_rebase) "true" else "false",
                        if (recovery_projection_deferred) "true" else "false",
                    },
                );
                return .{
                    .source_visual_offset = receipt.accepted_visual_offset,
                    .target_visual_offset = target_offset,
                    .resize_reflow_rows = resize_reflow_rows,
                    .semantic_rows = semantic_rows,
                    .semantic_progress_rows = semantic_progress_rows,
                    .planned_rows = planned_rows,
                    .source_compatible = source_compatible,
                    .recovery_rebase = recovery_rebase,
                    .recovery_progress_compatible = recovery_progress_compatible,
                    .recovery_tracks_semantic_progress = recovery_tracks_semantic_progress,
                    .recovery_projection_deferred = recovery_projection_deferred,
                };
            },
            .invalid => {
                // Materialize authoritative pre-viewport rows into native scrollback.
                if (self.pendingResumeFlow().len > 0) {
                    const semantic_rows: u32 = frameInlineScrollBudget(0, target_offset);
                    return .{
                        .target_visual_offset = target_offset,
                        .semantic_rows = semantic_rows,
                        .semantic_progress_rows = semantic_rows,
                        .planned_rows = self.plannedTranscriptRows(
                            prepared,
                            0,
                            0,
                            semantic_rows,
                            semantic_rows,
                        ),
                        .source_compatible = true,
                        .recovery_progress_compatible = true,
                        .recovery_tracks_semantic_progress = true,
                    };
                }
                return .{
                    .target_visual_offset = target_offset,
                    .recovery_rebase = true,
                };
            },
        };
        const source_equal = std.mem.eql(u8, prepared.bytes, anchor.flow);
        const source_prefix_growth = prepared.bytes.len > anchor.flow.len and
            std.mem.startsWith(u8, prepared.bytes, anchor.flow);
        const source_compatible = source_equal or source_prefix_growth;
        const source_visual_growth = source_prefix_growth and
            target_total_visual_rows > anchor.total_visual_rows;
        const width_stable = self.committed_frame_layout.terminal_cols == 0 or
            self.committed_frame_layout.terminal_cols == self.layout.cols;
        const geometry_rebase = footer_reservation_changed and
            width_stable and
            self.resize_history_row_delta == null;
        const displaced_history_replay = if (geometry_rebase and
            replay_displaced_footer_history)
            compatibleHistoryReplayRange(
                prepared,
                self.layout.cols,
                prepared.bytes,
                anchor.flow,
                anchor.history_visual_offset,
                target_offset,
            )
        else
            null;
        const recovery_rebase = (!source_compatible and !geometry_rebase) or
            !width_stable or
            self.resize_history_row_delta != null;
        // Release requires two independent facts: permission (the rows are
        // final, expressed by the finality floor) and ability (this frame
        // materializes their exact bytes, which an incompatible frame
        // cannot). Either fact missing forces zero release; the frame
        // re-anchors on the new flow and the derived history debt settles
        // on the next compatible frame through the existing replay.
        const releasable_offset = self.finalityReleasableOffset(prepared, target_offset);
        const releasable_advance = releasable_offset -| anchor.history_visual_offset;
        const committed_projection_offset = committedProjectionVisualOffset(anchor);
        const geometry_history_rows: u32 = if (geometry_rebase and
            ((source_compatible and source_visual_growth) or
                displaced_history_replay != null))
            target_offset -| anchor.history_visual_offset
        else
            0;
        // Geometry displacement (footer growth over transcript rows) keeps
        // its pre-existing semantics: displaced rows are preserved into
        // history even when mutable, because inline rendering has nowhere
        // else to keep them. The finality clamp governs content-driven
        // release only.
        const semantic_rows: u32 = if (geometry_rebase)
            geometry_history_rows
        else if (!recovery_rebase)
            // Normal-buffer recovery restores rows the takeover already
            // displaced into scrollback; that restore is display repair,
            // not a content release, so the finality clamp does not apply.
            if (anchor.normal_buffer_recovery_pending)
                target_offset -| anchor.history_visual_offset
            else if (anchor.history_catchup_pending)
                releasable_advance
            else
                // Rows leaving the screen top are [visual..visual+scroll);
                // the floor clamps that range, so the budget is measured
                // from the committed viewport, not from history.
                releasable_offset -| anchor.visual_offset
        else if (self.compatibleCommittedHistoryReplayRange(
            prepared,
            anchor,
            prepared.bytes,
            releasable_offset,
        ) != null)
            releasable_advance
        else
            0;
        // A finality hold is either the floor sitting below the viewport
        // (mutable rows above the top) or a same-geometry incompatible frame
        // that had permission to release but no ability to materialize;
        // geometry-driven recovery (resize, reflow) owns its own debt.
        const finality_hold = releasable_offset < target_offset or
            (recovery_rebase and
                width_stable and
                self.committed_frame_layout.terminal_rows == self.layout.rows and
                self.resize_history_row_delta == null and
                releasable_offset > anchor.history_visual_offset +| semantic_rows);
        const semantic_progress_rows: u32 = if (source_compatible or geometry_rebase)
            semantic_rows
        else
            0;
        const resize_reflow_candidate =
            self.calculateAnchorResizeReflowScrollRows(prepared.selection);
        const measured_boundary_row_pending =
            self.resize_history_row_delta != null and
            self.fullTranscriptActive() and
            resize_reflow_candidate == 1;
        const resize_reflow_rows = if (self.resize_history_row_delta == null or
            measured_boundary_row_pending)
            resize_reflow_candidate
        else
            0;
        const planned = self.plannedTranscriptRows(
            prepared,
            committed_projection_offset,
            resize_reflow_rows,
            semantic_rows,
            semantic_rows,
        );
        debug_trace.logf(
            "scroll",
            "transcript_transition_plan source_state=stable source_start={d} target_start={d} source_visual_offset={d} source_history_visual_offset={d} target_visual_offset={d} releasable_visual_offset={d} source_total_visual_rows={d} target_total_visual_rows={d} resize_reflow_candidate={d} resize_reflow_rows={d} semantic_rows={d} planned_rows={d} width_stable={s} source_compatible={s} footer_reservation_changed={s} replay_displaced_footer_history={s} geometry_rebase={s} recovery_rebase={s}",
            .{
                anchor.selection.start_line,
                prepared.selection.start_line,
                anchor.visual_offset,
                anchor.history_visual_offset,
                target_offset,
                releasable_offset,
                anchor.total_visual_rows,
                target_total_visual_rows,
                resize_reflow_candidate,
                resize_reflow_rows,
                semantic_rows,
                planned,
                if (width_stable) "true" else "false",
                if (source_compatible) "true" else "false",
                if (footer_reservation_changed) "true" else "false",
                if (replay_displaced_footer_history) "true" else "false",
                if (geometry_rebase) "true" else "false",
                if (recovery_rebase) "true" else "false",
            },
        );
        return .{
            .source_visual_offset = committed_projection_offset,
            .target_visual_offset = target_offset,
            .resize_reflow_rows = resize_reflow_rows,
            .semantic_rows = semantic_rows,
            .semantic_progress_rows = semantic_progress_rows,
            .planned_rows = planned,
            .source_compatible = source_compatible,
            .geometry_rebase = geometry_rebase,
            .recovery_rebase = recovery_rebase,
            .finality_hold = finality_hold,
            .recovery_progress_compatible = !recovery_rebase,
            .recovery_tracks_semantic_progress = source_compatible or geometry_rebase,
        };
    }

    fn calculateAnchorResizeReflowScrollRows(
        self: *const TranscriptRuntime,
        next_selection: ViewportSelection,
    ) u16 {
        const anchor = switch (self.transcript_commit_state) {
            .stable => |value| value,
            .invalid, .recovering => return 0,
        };
        const committed = self.committed_frame_layout;
        if (anchor.layout_id != committed.layout_id or
            !self.viewport_clear_pending or
            self.owned_top_row != 1 or
            committed.transcript_area.top != 1 or
            next_selection.top_row != 1 or
            next_selection.bottom_row < next_selection.top_row or
            self.layout.cols == 0 or
            self.layout.rows == 0 or
            committed.terminal_cols == 0 or
            committed.terminal_rows == 0 or
            self.layout.cols >= committed.terminal_cols)
        {
            return 0;
        }

        const shadow = self.shadow_vt orelse return 0;
        if (shadow.cols != committed.terminal_cols or
            shadow.rows != committed.terminal_rows or
            committed.transcript_area.isEmpty() or
            shadow.cursor_row <= committed.transcript_area.bottom)
        {
            return 0;
        }

        const cursor_reflowed_row = reflowedRows(
            shadow,
            1,
            shadow.cursor_row,
            self.layout.cols,
            true,
        );
        if (cursor_reflowed_row <= self.layout.rows) return 0;

        const chrome_rows = reflowedRows(
            shadow,
            committed.transcript_area.bottom + 1,
            shadow.cursor_row,
            self.layout.cols,
            true,
        );
        const physical_transcript_rows = @as(u32, self.layout.rows) -| chrome_rows;
        const target_transcript_rows =
            @as(u32, next_selection.bottom_row) - next_selection.top_row + 1;
        return @intCast(@min(
            physical_transcript_rows -| target_transcript_rows,
            @as(u32, std.math.maxInt(u16)),
        ));
    }

    const TransitionTarget = struct {
        body_disposition: TranscriptBodyDisposition = .paint,
        selection: ViewportSelection,
        visual_offset: u32,
        history_visual_offset: u32,
        source_endpoint_visual_offset: u32,
        total_visual_rows: u32,
        cursor_row: u16,
        cursor_col: u16,
        measured_history_origin: ?transcript_painter.MeasuredHistoryOrigin,
        normal_buffer_recovery_pending: bool = false,
        history_catchup_pending: bool = false,
        staged_flow_end: ?usize = null,
        projection_staged: bool = false,
        // The frame slides the viewport past withheld release with an
        // in-place repaint. Any document append is bounded separately to
        // the rows the frame may release.
        hold_staged: bool = false,

        fn init(
            prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
            scroll_facts: TranscriptScrollFacts,
        ) TransitionTarget {
            return .{
                .selection = prepared.selection,
                .visual_offset = scroll_facts.target_visual_offset,
                .history_visual_offset = scroll_facts.target_visual_offset,
                .source_endpoint_visual_offset = scroll_facts.target_visual_offset,
                .total_visual_rows = prepared.sourceTotalVisualRows(),
                .cursor_row = prepared.cursor.cursor_row,
                .cursor_col = prepared.cursor.cursor_col,
                .measured_history_origin = prepared.measured_history_origin,
            };
        }

        fn retainCommittedAnchor(
            self: *TransitionTarget,
            anchor: CommittedTranscriptAnchor,
            retained: RetainedTranscriptBody,
        ) void {
            self.body_disposition = .{ .retain_committed = retained };
            self.selection = anchor.selection;
            self.visual_offset = anchor.visual_offset;
            self.history_visual_offset = anchor.history_visual_offset;
            self.normal_buffer_recovery_pending = anchor.normal_buffer_recovery_pending;
            self.total_visual_rows = anchor.total_visual_rows;
            self.cursor_row = anchor.cursor_row;
            self.cursor_col = anchor.cursor_col;
        }

        fn usePreparedProjection(
            self: *TransitionTarget,
            prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
        ) void {
            self.selection = prepared.selection;
            self.cursor_row = prepared.cursor.cursor_row;
            self.cursor_col = prepared.cursor.cursor_col;
        }

        fn stagePreparedProjection(
            self: *TransitionTarget,
            alloc: Allocator,
            layout: Layout,
            prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
            target_area: render_engine.frame_layout.FrameRect,
            visual_offset: u32,
        ) !void {
            self.visual_offset = visual_offset;
            if (visual_offset == self.total_visual_rows) {
                try transcript_painter.reprojectPreparedTranscriptForVisualOffset(
                    alloc,
                    layout,
                    prepared,
                    target_area,
                    visual_offset,
                );
                self.staged_flow_end =
                    transcript_painter.preparedTranscriptFlowOffsetForVisualOffset(
                        prepared,
                        layout.cols,
                        visual_offset,
                    );
            } else {
                const staged = try transcript_painter.stagePreparedTranscriptForVisualOffset(
                    alloc,
                    layout,
                    prepared,
                    target_area,
                    visual_offset,
                );
                self.staged_flow_end = staged.flow_end;
            }
            self.projection_staged = true;
            self.usePreparedProjection(prepared);
        }

        fn stagePreparedHistoryProjection(
            self: *TransitionTarget,
            alloc: Allocator,
            layout: Layout,
            prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
            target_area: render_engine.frame_layout.FrameRect,
        ) !void {
            const logical_visual_offset = self.visual_offset;
            try self.stagePreparedProjection(
                alloc,
                layout,
                prepared,
                target_area,
                self.history_visual_offset,
            );
            self.visual_offset = logical_visual_offset;
            self.source_endpoint_visual_offset = self.history_visual_offset;
        }
    };

    pub const ResolvedTranscriptTarget = struct {
        target: TransitionTarget,
        target_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        scroll_facts: TranscriptScrollFacts,
        accepted: AcceptedTranscriptRows,
        source_endpoint_cursor_row: u16,
        source_endpoint_cursor_col: u16,
        destructive_invalidation: bool,
        activity_overlay_active: bool,
        borrows_pending_resume: bool,

        pub fn selection(self: ResolvedTranscriptTarget) ViewportSelection {
            return self.target.selection;
        }

        pub fn cursorRow(self: ResolvedTranscriptTarget) u16 {
            return self.target.cursor_row;
        }

        pub fn cursorCol(self: ResolvedTranscriptTarget) u16 {
            return self.target.cursor_col;
        }

        pub fn bodyDisposition(self: ResolvedTranscriptTarget) TranscriptBodyDisposition {
            return self.target.body_disposition;
        }

        pub fn occupiedTranscriptRows(self: ResolvedTranscriptTarget) u16 {
            const area = self.target_layout.transcript_area;
            if (area.isEmpty() or self.target.selection.last_visible_row < area.top) return 0;
            return self.target.selection.last_visible_row - area.top + 1;
        }

        pub fn applyToPaintPlan(
            self: ResolvedTranscriptTarget,
            plan: *render_engine.paint_plan.PaintPlan,
        ) void {
            plan.viewport = self.target.selection;
            if (plan.cursor_target) |*cursor| {
                cursor.row = self.target.cursor_row;
                cursor.col = self.target.cursor_col;
            }
        }
    };

    fn stableRetainedTransitionBody(
        self: *const TranscriptRuntime,
        anchor: CommittedTranscriptAnchor,
        source_bytes: []const u8,
        target_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        destructive_invalidation: bool,
        activity_overlay_active: bool,
    ) ?RetainedTranscriptBody {
        return render_engine.frame_retention.stableRetainedTranscriptBody(.{
            .full_transcript_active = self.fullTranscriptActive(),
            .committed_layout_id = anchor.layout_id,
            .committed_flow = anchor.flow,
            .committed_occupied_last_row = anchor.occupied_last_row,
            .source_layout = self.committed_frame_layout,
            .source_bytes = source_bytes,
            .target_layout = target_layout,
            .scroll_plan = scroll_plan,
            .destructive_invalidation = destructive_invalidation,
            .activity_overlay_active = activity_overlay_active,
        });
    }

    fn paintedStableTargetWouldRewind(
        self: *const TranscriptRuntime,
        target: TransitionTarget,
        anchor: CommittedTranscriptAnchor,
        scroll_facts: TranscriptScrollFacts,
        destructive_invalidation: bool,
    ) bool {
        const same_width = self.committed_frame_layout.terminal_cols == self.layout.cols;
        return !self.fullTranscriptActive() and
            target.body_disposition == .paint and
            scroll_facts.source_compatible and
            !scroll_facts.geometry_rebase and
            same_width and
            self.resize_history_row_delta == null and
            !destructive_invalidation and
            target.visual_offset >= target.history_visual_offset and
            scroll_facts.target_visual_offset < anchor.visual_offset;
    }

    fn semanticProgressNeedsStaging(
        target: TransitionTarget,
        scroll_facts: TranscriptScrollFacts,
        accepted_semantic_progress_rows: u32,
    ) bool {
        return target.body_disposition == .paint and
            !scroll_facts.recovery_rebase and
            scroll_facts.recovery_tracks_semantic_progress and
            accepted_semantic_progress_rows < scroll_facts.semantic_progress_rows;
    }

    fn stableHistoryFloor(
        self: *const TranscriptRuntime,
        target: TransitionTarget,
        anchor: CommittedTranscriptAnchor,
        scroll_facts: TranscriptScrollFacts,
    ) ?u32 {
        const stable_terminal_geometry =
            self.committed_frame_layout.terminal_cols == self.layout.cols and
            self.committed_frame_layout.terminal_rows == self.layout.rows;
        if (self.fullTranscriptActive() or
            target.body_disposition != .paint or
            !stable_terminal_geometry or
            self.resize_history_row_delta != null)
        {
            return null;
        }
        if (target.visual_offset < target.history_visual_offset) {
            return target.history_visual_offset;
        }
        const committed_offset = committedProjectionVisualOffset(anchor);
        if (!scroll_facts.source_compatible and
            target.visual_offset < committed_offset and
            target.total_visual_rows > committed_offset)
        {
            return committed_offset;
        }
        return null;
    }

    fn recoveringCanAdvanceSemanticProgress(scroll_facts: TranscriptScrollFacts) bool {
        return scroll_facts.recovery_progress_compatible and
            scroll_facts.recovery_tracks_semantic_progress and
            !scroll_facts.recovery_projection_deferred;
    }

    fn resolveTransitionTarget(
        self: *const TranscriptRuntime,
        alloc: Allocator,
        source_bytes: []const u8,
        prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
        target_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        scroll_facts: TranscriptScrollFacts,
        accepted_semantic_rows: u32,
        accepted_semantic_progress_rows: u32,
        destructive_invalidation: bool,
        activity_overlay_active: bool,
    ) !TransitionTarget {
        var target = TransitionTarget.init(prepared, scroll_facts);
        switch (self.transcript_commit_state) {
            .stable => |anchor| {
                target.history_visual_offset = @min(
                    target.total_visual_rows,
                    anchor.history_visual_offset +| accepted_semantic_rows,
                );
                target.normal_buffer_recovery_pending =
                    anchor.normal_buffer_recovery_pending;
                target.history_catchup_pending = anchor.history_catchup_pending;
                // A retained body advances only by the released rows. When
                // the finality clamp withholds release from the plan itself
                // (as opposed to a partial acceptance, which the recovery
                // debt machinery owns), the viewport must still follow the
                // flow, so the frame repaints instead of retaining.
                const plan_covers_advance =
                    scroll_facts.target_visual_offset -|
                    committedProjectionVisualOffset(anchor) <=
                    scroll_facts.semantic_rows;
                if (!scroll_facts.geometry_rebase and plan_covers_advance) {
                    if (self.stableRetainedTransitionBody(
                        anchor,
                        source_bytes,
                        target_layout,
                        scroll_plan,
                        destructive_invalidation,
                        activity_overlay_active,
                    )) |retained| {
                        target.retainCommittedAnchor(anchor, retained);
                    }
                }
                if (self.paintedStableTargetWouldRewind(
                    target,
                    anchor,
                    scroll_facts,
                    destructive_invalidation,
                )) {
                    return error.InvalidTranscriptTransition;
                }
                if (semanticProgressNeedsStaging(
                    target,
                    scroll_facts,
                    accepted_semantic_progress_rows,
                )) {
                    try target.stagePreparedProjection(
                        alloc,
                        self.layout,
                        prepared,
                        target_layout.transcript_area,
                        scroll_facts.source_visual_offset + accepted_semantic_progress_rows,
                    );
                }
                if (target.normal_buffer_recovery_pending and
                    scroll_facts.source_compatible and
                    target.visual_offset > target.history_visual_offset)
                {
                    try target.stagePreparedHistoryProjection(
                        alloc,
                        self.layout,
                        prepared,
                        target_layout.transcript_area,
                    );
                }
                if (target.normal_buffer_recovery_pending and
                    scroll_facts.geometry_rebase and
                    target.history_visual_offset >= target.visual_offset)
                {
                    target.normal_buffer_recovery_pending = false;
                }
                if (!target.projection_staged and
                    target.body_disposition == .paint and
                    !scroll_facts.geometry_rebase and
                    !scroll_facts.recovery_rebase and
                    !self.fullTranscriptActive() and
                    !prepared.selection.split_active and
                    !target_layout.transcript_area.isEmpty() and
                    scroll_facts.target_visual_offset -|
                        committedProjectionVisualOffset(anchor) >
                        scroll_facts.semantic_rows and
                    scroll_facts.target_visual_offset >= target.history_visual_offset)
                {
                    // The viewport advanced further than the plan may
                    // release: slide the window with an in-place repaint at
                    // the target offset. The rows passed over stay
                    // unreleased and settle later through the replay.
                    var projection_layout = self.layout;
                    projection_layout.content_bottom = target_layout.transcript_area.bottom;
                    try target.stagePreparedProjection(
                        alloc,
                        projection_layout,
                        prepared,
                        target_layout.transcript_area,
                        scroll_facts.target_visual_offset,
                    );
                    target.hold_staged = true;
                    debug_trace.logf(
                        "scroll",
                        "transcript_transition_hold_release target_visual_offset={d} history_visual_offset={d} semantic_rows={d}",
                        .{
                            scroll_facts.target_visual_offset,
                            target.history_visual_offset,
                            scroll_facts.semantic_rows,
                        },
                    );
                }
                if (self.stableHistoryFloor(target, anchor, scroll_facts)) |history_floor| {
                    var projection_layout = self.layout;
                    projection_layout.content_bottom = target_layout.transcript_area.bottom;
                    try target.stagePreparedProjection(
                        alloc,
                        projection_layout,
                        prepared,
                        target_layout.transcript_area,
                        history_floor,
                    );
                    target.source_endpoint_visual_offset = history_floor;
                    debug_trace.logf(
                        "scroll",
                        "transcript_transition_hold_history_floor source_visual_offset={d} target_visual_offset={d}",
                        .{ history_floor, scroll_facts.target_visual_offset },
                    );
                }
                if (scroll_facts.geometry_rebase) {
                    target.history_catchup_pending =
                        target.visual_offset > target.history_visual_offset;
                } else if (target.history_visual_offset >= target.visual_offset) {
                    target.history_catchup_pending = false;
                } else if (scroll_facts.finality_hold) {
                    // Finality withheld release. Preserve the obligation on
                    // stable anchors until history catches the viewport;
                    // footer displacement alone never creates one.
                    target.history_catchup_pending = true;
                }
            },
            .recovering => |receipt| {
                target.history_visual_offset = @min(
                    target.total_visual_rows,
                    receipt.accepted_history_visual_offset +| accepted_semantic_rows,
                );
                target.normal_buffer_recovery_pending =
                    receipt.normal_buffer_recovery_pending;
                if (recoveringCanAdvanceSemanticProgress(scroll_facts)) {
                    target.visual_offset =
                        scroll_facts.source_visual_offset +
                        accepted_semantic_progress_rows;
                    if (accepted_semantic_progress_rows <
                        scroll_facts.semantic_progress_rows)
                    {
                        try target.stagePreparedProjection(
                            alloc,
                            self.layout,
                            prepared,
                            target_layout.transcript_area,
                            target.visual_offset,
                        );
                    } else {
                        try transcript_painter.reprojectPreparedTranscriptForVisualOffset(
                            alloc,
                            self.layout,
                            prepared,
                            target_layout.transcript_area,
                            target.visual_offset,
                        );
                        target.usePreparedProjection(prepared);
                    }
                }
            },
            .invalid => if (semanticProgressNeedsStaging(
                target,
                scroll_facts,
                accepted_semantic_progress_rows,
            )) {
                try target.stagePreparedProjection(
                    alloc,
                    self.layout,
                    prepared,
                    target_layout.transcript_area,
                    accepted_semantic_progress_rows,
                );
            },
        }
        if (target.measured_history_origin == null and
            !prepared.measured_history_origin_consumed and
            scroll_facts.source_compatible and
            !destructive_invalidation)
        {
            target.measured_history_origin = switch (self.transcript_commit_state) {
                .invalid => null,
                .stable => |anchor| anchor.measured_history_origin,
                .recovering => |receipt| receipt.measured_history_origin,
            };
        }
        if (!scroll_facts.source_compatible) {
            target.measured_history_origin = null;
        }
        return target;
    }

    const TransitionHistoryReplay = struct {
        flow_start: usize,
        flow_end: usize,
        clear_rows: u16,
    };

    fn committedLayoutMatches(
        self: *const TranscriptRuntime,
        anchor: CommittedTranscriptAnchor,
    ) bool {
        return anchor.layout_id == self.committed_frame_layout.layout_id and
            self.committed_frame_layout.terminal_cols == self.layout.cols and
            self.committed_frame_layout.terminal_rows == self.layout.rows;
    }

    fn compatibleHistoryReplayRange(
        prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
        cols: u16,
        target_flow: []const u8,
        committed_flow: []const u8,
        source_history_visual_offset: u32,
        target_history_visual_offset: u32,
    ) ?TransitionHistoryReplay {
        if (target_history_visual_offset <= source_history_visual_offset) return null;
        const flow_start = transcript_painter.preparedTranscriptFlowOffsetForVisualOffset(
            prepared,
            cols,
            source_history_visual_offset,
        ) orelse return null;
        const flow_end = transcript_painter.preparedTranscriptFlowOffsetForVisualOffset(
            prepared,
            cols,
            target_history_visual_offset,
        ) orelse return null;
        if (flow_end <= flow_start or flow_start > committed_flow.len) return null;
        const overlap_end = @min(flow_end, committed_flow.len);
        if (overlap_end > target_flow.len or
            !std.mem.eql(
                u8,
                target_flow[0..overlap_end],
                committed_flow[0..overlap_end],
            ))
        {
            return null;
        }
        const clear_rows = std.math.cast(
            u16,
            target_history_visual_offset - source_history_visual_offset,
        ) orelse return null;
        return .{
            .flow_start = flow_start,
            .flow_end = flow_end,
            .clear_rows = clear_rows,
        };
    }

    fn compatibleCommittedHistoryReplayRange(
        self: *const TranscriptRuntime,
        prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
        anchor: CommittedTranscriptAnchor,
        target_flow: []const u8,
        target_history_visual_offset: u32,
    ) ?TransitionHistoryReplay {
        if (!self.committedLayoutMatches(anchor)) return null;
        if (self.resize_history_row_delta != null) return null;
        return compatibleHistoryReplayRange(
            prepared,
            self.layout.cols,
            target_flow,
            anchor.flow,
            anchor.history_visual_offset,
            target_history_visual_offset,
        );
    }

    const TransitionAppendBase = struct {
        flow_len: usize,
        history_replay: ?TransitionHistoryReplay = null,
        visual_offset: u32,
        visual_rows: u16,
        cursor_row: u16,
        cursor_col: u16,
    };

    fn resolveTransitionAppendBase(
        self: *const TranscriptRuntime,
        prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
        scroll_facts: TranscriptScrollFacts,
        destructive_invalidation: bool,
        target_flow: []const u8,
        target_history_visual_offset: u32,
    ) !?TransitionAppendBase {
        switch (self.transcript_commit_state) {
            .stable => |anchor| {
                if (!destructive_invalidation) {
                    const replay_from_history = target_history_visual_offset >
                        anchor.history_visual_offset and
                        (scroll_facts.geometry_rebase or
                            anchor.normal_buffer_recovery_pending or
                            anchor.history_catchup_pending);
                    if (replay_from_history) {
                        const replay = self.compatibleCommittedHistoryReplayRange(
                            prepared,
                            anchor,
                            target_flow,
                            target_history_visual_offset,
                        );
                        if (replay) |history_replay| {
                            return .{
                                .flow_len = history_replay.flow_start,
                                .history_replay = history_replay,
                                .visual_offset = anchor.history_visual_offset,
                                .visual_rows = projectionVisualRowsInArea(
                                    anchor.total_visual_rows,
                                    anchor.history_visual_offset,
                                    self.committed_frame_layout.transcript_area,
                                ),
                                .cursor_row = self.committed_frame_layout.transcript_area.top,
                                .cursor_col = 1,
                            };
                        }
                    }
                    if (self.committedLayoutMatches(anchor) and
                        target_flow.len >= anchor.flow.len and
                        std.mem.startsWith(u8, target_flow, anchor.flow))
                    {
                        return .{
                            .flow_len = anchor.flow.len,
                            .visual_offset = committedProjectionVisualOffset(anchor),
                            .visual_rows = projectionVisualRowsInArea(
                                anchor.total_visual_rows,
                                committedProjectionVisualOffset(anchor),
                                self.committed_frame_layout.transcript_area,
                            ),
                            .cursor_row = anchor.cursor_row,
                            .cursor_col = anchor.cursor_col,
                        };
                    }
                }
            },
            .recovering => |receipt| {
                if (scroll_facts.recovery_progress_compatible and
                    scroll_facts.recovery_tracks_semantic_progress and
                    !scroll_facts.recovery_rebase and
                    self.committed_frame_layout.terminal_cols == self.layout.cols and
                    self.committed_frame_layout.terminal_rows == self.layout.rows and
                    receipt.materialized_flow_len != null)
                {
                    const materialized_flow_len =
                        receipt.materialized_flow_len.?;
                    if (recoveryAppendPrefixMatches(
                        target_flow,
                        receipt,
                        materialized_flow_len,
                    )) {
                        return .{
                            .flow_len = materialized_flow_len,
                            .visual_offset = receipt.materialized_visual_offset,
                            .visual_rows = receipt.materialized_visual_rows,
                            .cursor_row = receipt.cursor_row,
                            .cursor_col = receipt.cursor_col,
                        };
                    }
                }
            },
            .invalid => if (self.pendingResumeFlow().len > 0 and
                !destructive_invalidation and
                self.committed_frame_layout.terminal_cols == self.layout.cols and
                self.committed_frame_layout.terminal_rows == self.layout.rows)
            {
                return .{
                    .flow_len = 0,
                    .visual_offset = 0,
                    .visual_rows = 0,
                    .cursor_row = prepared.projectionArea().top,
                    .cursor_col = 1,
                };
            },
        }
        return null;
    }

    const PlannedHistoryMaterialization = struct {
        visual_offset: u32,
        normal_buffer_recovery_pending: bool,
    };

    fn resolvePlannedHistoryMaterialization(
        source_visual_offset: u32,
        target_visual_offset: u32,
        target_projection_offset: u32,
        document_append_planned: bool,
        recovery_pending: bool,
    ) PlannedHistoryMaterialization {
        if (!recovery_pending) {
            return .{
                .visual_offset = target_visual_offset,
                .normal_buffer_recovery_pending = false,
            };
        }
        if (target_visual_offset <= source_visual_offset) {
            return .{
                .visual_offset = target_visual_offset,
                .normal_buffer_recovery_pending = recovery_pending,
            };
        }
        if (document_append_planned) {
            return .{
                .visual_offset = target_visual_offset,
                .normal_buffer_recovery_pending = recovery_pending and
                    target_visual_offset < target_projection_offset,
            };
        }
        return .{
            .visual_offset = source_visual_offset,
            .normal_buffer_recovery_pending = true,
        };
    }

    test "history offset advances only when transcript bytes are materialized" {
        const deferred = resolvePlannedHistoryMaterialization(
            4,
            12,
            12,
            false,
            true,
        );
        try std.testing.expectEqual(@as(u32, 4), deferred.visual_offset);
        try std.testing.expect(deferred.normal_buffer_recovery_pending);

        const caught_up = resolvePlannedHistoryMaterialization(
            4,
            12,
            12,
            true,
            true,
        );
        try std.testing.expectEqual(@as(u32, 12), caught_up.visual_offset);
        try std.testing.expect(!caught_up.normal_buffer_recovery_pending);

        const bounded = resolvePlannedHistoryMaterialization(
            4,
            8,
            12,
            true,
            true,
        );
        try std.testing.expectEqual(@as(u32, 8), bounded.visual_offset);
        try std.testing.expect(bounded.normal_buffer_recovery_pending);
    }

    fn resolveMaterializedEndpoint(
        target: TransitionTarget,
        source_endpoint_cursor_row: u16,
        source_endpoint_cursor_col: u16,
        append_base: ?TransitionAppendBase,
        projected_flow_end: ?usize,
        target_flow_len: usize,
        transcript_area: render_engine.frame_layout.FrameRect,
    ) MaterializedEndpoint {
        var endpoint: MaterializedEndpoint = .{
            .visual_offset = target.history_visual_offset,
            .visual_rows = projectionVisualRowsInArea(
                target.total_visual_rows,
                target.history_visual_offset,
                transcript_area,
            ),
            .flow_len = projected_flow_end,
            .cursor_row = target.cursor_row,
            .cursor_col = target.cursor_col,
        };
        const base = append_base orelse return endpoint;
        const flow_end = projected_flow_end orelse return endpoint;
        if (base.flow_len < flow_end) return endpoint;

        endpoint.flow_len = base.flow_len;
        if (base.flow_len == target_flow_len) {
            endpoint.visual_offset = target.source_endpoint_visual_offset;
            endpoint.visual_rows = projectionVisualRowsInArea(
                target.total_visual_rows,
                target.source_endpoint_visual_offset,
                transcript_area,
            );
            endpoint.cursor_row = source_endpoint_cursor_row;
            endpoint.cursor_col = source_endpoint_cursor_col;
        } else {
            endpoint.visual_offset = base.visual_offset;
            endpoint.visual_rows = base.visual_rows;
            endpoint.cursor_row = base.cursor_row;
            endpoint.cursor_col = base.cursor_col;
        }
        return endpoint;
    }

    fn materializedEndpointWithoutAppend(
        self: *const TranscriptRuntime,
        document_append: render_engine.frame_scroll_plan.FrameDocumentAppend,
        planned: MaterializedEndpoint,
    ) MaterializedEndpoint {
        return switch (self.transcript_commit_state) {
            .stable => |anchor| .{
                .visual_offset = committedProjectionVisualOffset(anchor),
                .visual_rows = projectionVisualRowsInArea(
                    anchor.total_visual_rows,
                    committedProjectionVisualOffset(anchor),
                    self.committed_frame_layout.transcript_area,
                ),
                .flow_len = anchor.flow.len,
                .cursor_row = anchor.cursor_row,
                .cursor_col = anchor.cursor_col,
            },
            .recovering => |receipt| .{
                .visual_offset = receipt.materialized_visual_offset,
                .visual_rows = receipt.materialized_visual_rows,
                .flow_len = receipt.materialized_flow_len,
                .cursor_row = receipt.cursor_row,
                .cursor_col = receipt.cursor_col,
            },
            .invalid => if (document_append.isEmpty()) planned else .{
                .visual_offset = 0,
                .visual_rows = 0,
                .flow_len = 0,
                .cursor_row = document_append.start_row,
                .cursor_col = document_append.start_col,
            },
        };
    }

    fn borrowsPendingResumeSource(
        self: *const TranscriptRuntime,
        source: *const TranscriptPreparationSource,
    ) bool {
        return if (self.pending_resume_source) |*pending| source == pending else false;
    }

    pub fn prepareTranscriptScrollFactsForFrame(
        self: *const TranscriptRuntime,
        alloc: Allocator,
        source: *const TranscriptPreparationSource,
        prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
        footer_reservation_changed: bool,
        replay_displaced_footer_history: bool,
    ) !TranscriptScrollFacts {
        if (self.borrowsPendingResumeSource(source)) switch (self.transcript_commit_state) {
            .invalid => try transcript_painter.seedPreparedPresentationBoundary(
                alloc,
                prepared,
                0,
                .{},
            ),
            .recovering => |receipt| if (receipt.presentation_valid and
                receipt.materialized_flow_len != null)
            {
                try transcript_painter.seedPreparedPresentationBoundary(
                    alloc,
                    prepared,
                    receipt.materialized_flow_len.?,
                    .{
                        .resume_bytes = receipt.presentation_resume_bytes,
                        .cursor_col = receipt.cursor_col,
                        .pending_wrap = receipt.presentation_pending_wrap,
                    },
                );
            },
            .stable => {},
        };
        return self.planTranscriptScrollForFrame(
            prepared,
            footer_reservation_changed,
            replay_displaced_footer_history,
        );
    }

    pub fn resolveTranscriptTransitionTargetForFrame(
        self: *const TranscriptRuntime,
        alloc: Allocator,
        source: *const TranscriptPreparationSource,
        prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
        target_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        scroll_facts: TranscriptScrollFacts,
        destructive_invalidation: bool,
        activity_overlay_active: bool,
    ) !ResolvedTranscriptTarget {
        try scroll_plan.validate(self.layout.rows);
        if (scroll_plan.requested_inline_advance_rows != scroll_facts.planned_rows) {
            return error.InvalidFrameScrollPlan;
        }
        const accepted = acceptedTranscriptRows(
            scroll_plan,
            scroll_plan.terminal_scroll_rows,
            scroll_facts.resize_reflow_rows,
            scroll_facts.semantic_rows,
            scroll_facts.semantic_progress_rows,
        );
        const source_endpoint_cursor_row = prepared.cursor.cursor_row;
        const source_endpoint_cursor_col = prepared.cursor.cursor_col;
        const target = self.resolveTransitionTarget(
            alloc,
            source.bytes,
            prepared,
            target_layout,
            scroll_plan,
            scroll_facts,
            accepted.semantic_rows,
            accepted.semantic_progress_rows,
            destructive_invalidation,
            activity_overlay_active,
        ) catch |err| {
            const normal_buffer_recovery_pending = switch (self.transcript_commit_state) {
                .stable => |anchor| anchor.normal_buffer_recovery_pending,
                .recovering => |receipt| receipt.normal_buffer_recovery_pending,
                .invalid => false,
            };
            debug_trace.logf(
                "scroll",
                "transcript_target_resolution_failed err={s} source_compatible={s} geometry_rebase={s} recovery_rebase={s} normal_buffer_recovery_pending={s} target_visual_offset={d}",
                .{
                    @errorName(err),
                    if (scroll_facts.source_compatible) "true" else "false",
                    if (scroll_facts.geometry_rebase) "true" else "false",
                    if (scroll_facts.recovery_rebase) "true" else "false",
                    if (normal_buffer_recovery_pending) "true" else "false",
                    scroll_facts.target_visual_offset,
                },
            );
            return err;
        };
        if (!target_layout.transcript_area.isEmpty() and
            target.selection.last_visible_row > target_layout.transcript_area.bottom)
        {
            debug_trace.logf(
                "scroll",
                "transcript_target_outside_candidate last_visible={d} target_area={d}..{d} body_disposition={s}",
                .{
                    target.selection.last_visible_row,
                    target_layout.transcript_area.top,
                    target_layout.transcript_area.bottom,
                    @tagName(target.body_disposition),
                },
            );
            return error.InvalidTranscriptTransition;
        }
        return .{
            .target = target,
            .target_layout = target_layout,
            .scroll_plan = scroll_plan,
            .scroll_facts = scroll_facts,
            .accepted = accepted,
            .source_endpoint_cursor_row = source_endpoint_cursor_row,
            .source_endpoint_cursor_col = source_endpoint_cursor_col,
            .destructive_invalidation = destructive_invalidation,
            .activity_overlay_active = activity_overlay_active,
            .borrows_pending_resume = self.borrowsPendingResumeSource(source),
        };
    }

    pub fn finalizeTranscriptTransitionForFrame(
        self: *TranscriptRuntime,
        alloc: Allocator,
        source: *TranscriptPreparationSource,
        prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
        target_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
        plan: *render_engine.paint_plan.PaintPlan,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        footer_reservation_changed: bool,
        replay_displaced_footer_history: bool,
    ) !TranscriptTransition {
        const scroll_facts = try self.prepareTranscriptScrollFactsForFrame(
            alloc,
            source,
            prepared,
            footer_reservation_changed,
            replay_displaced_footer_history,
        );
        const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
            self.committed_frame_layout.transcript_area,
            plan.invalidation,
        );
        const resolved = try self.resolveTranscriptTransitionTargetForFrame(
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
        return self.sealTranscriptTransition(
            alloc,
            source,
            prepared,
            plan,
            resolved,
        );
    }

    pub fn sealTranscriptTransition(
        self: *TranscriptRuntime,
        alloc: Allocator,
        source: *TranscriptPreparationSource,
        prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
        plan: *const render_engine.paint_plan.PaintPlan,
        resolved: ResolvedTranscriptTarget,
    ) !TranscriptTransition {
        try resolved.scroll_plan.validate(self.layout.rows);
        const plan_layout = render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan.*);
        if (!std.meta.eql(plan_layout, resolved.target_layout) or
            !std.meta.eql(plan.viewport, resolved.target.selection) or
            (plan.activity == .overlay_entry) != resolved.activity_overlay_active)
        {
            return error.InvalidTranscriptTransition;
        }
        const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
            self.committed_frame_layout.transcript_area,
            plan.invalidation,
        );
        if (destructive_invalidation != resolved.destructive_invalidation or
            self.borrowsPendingResumeSource(source) != resolved.borrows_pending_resume)
        {
            return error.InvalidTranscriptTransition;
        }
        switch (resolved.target.body_disposition) {
            .paint => if (!std.meta.eql(prepared.selection, resolved.target.selection) or
                prepared.cursor.cursor_row != resolved.target.cursor_row or
                prepared.cursor.cursor_col != resolved.target.cursor_col)
            {
                return error.InvalidTranscriptTransition;
            },
            .retain_committed => |retained| {
                const anchor = switch (self.transcript_commit_state) {
                    .stable => |value| value,
                    .invalid, .recovering => return error.InvalidTranscriptTransition,
                };
                if (!std.meta.eql(anchor.selection, resolved.target.selection) or
                    anchor.cursor_row != resolved.target.cursor_row or
                    anchor.cursor_col != resolved.target.cursor_col or
                    anchor.occupied_last_row != retained.occupied_last_row)
                {
                    return error.InvalidTranscriptTransition;
                }
            },
        }
        const borrows_pending_resume = resolved.borrows_pending_resume;
        const scroll_plan = resolved.scroll_plan;
        const scroll_facts = resolved.scroll_facts;
        const accepted = resolved.accepted;
        const target_layout = resolved.target_layout;
        const source_endpoint_cursor_row = resolved.source_endpoint_cursor_row;
        const source_endpoint_cursor_col = resolved.source_endpoint_cursor_col;
        var target = resolved.target;
        const source_diagnostic = self.transcriptCommitDiagnostic();
        debug_trace.logf(
            "scroll",
            "transcript_transition_finalize source_state={s} body_disposition={s} source_start={d} target_start={d} source_visual_offset={d} target_visual_offset={d} target_history_visual_offset={d} target_cursor={d},{d} source_layout_id={x} target_layout_id={x}",
            .{
                @tagName(source_diagnostic.state),
                @tagName(target.body_disposition),
                source_diagnostic.stable_start_line orelse 0,
                target.selection.start_line,
                source_diagnostic.visual_offset,
                target.visual_offset,
                target.history_visual_offset,
                target.cursor_row,
                target.cursor_col,
                source_diagnostic.layout_id,
                target_layout.layout_id,
            },
        );

        var target_cache: std.ArrayList(u8) = .empty;
        errdefer target_cache.deinit(alloc);
        const target_cache_start =
            transcript_store.cappedTailStart(source.bytes, self.max_transcript_bytes);
        const target_cache_bytes = source.bytes[target_cache_start..];
        if (!borrows_pending_resume) {
            try target_cache.ensureTotalCapacityPrecise(
                alloc,
                @max(target_cache_bytes.len, self.transcript.capacity),
            );
            try target_cache.appendSlice(alloc, target_cache_bytes);
        }
        const target_cache_origin_untrimmed =
            source.cache_origin_untrimmed and target_cache_start == 0;
        var transition_replaceable_last_line = prepared.replaceable_last_line;
        var transition_replaceable_start = prepared.replaceable_start;
        if (transition_replaceable_last_line) {
            if (target_cache_bytes.len == 0 or
                prepared.replaceable_start >= source.bytes.len)
            {
                transition_replaceable_last_line = false;
                transition_replaceable_start = 0;
            } else if (prepared.replaceable_start > target_cache_start) {
                transition_replaceable_start =
                    prepared.replaceable_start - target_cache_start;
            } else {
                transition_replaceable_start = 0;
            }
        }

        const target_flow = source.bytes;
        if (!borrows_pending_resume) source.bytes = &.{};
        errdefer if (!borrows_pending_resume and target_flow.len > 0) alloc.free(target_flow);

        const folded_summary_indices = source.folded_summary_indices;
        if (!borrows_pending_resume) source.folded_summary_indices = &.{};
        errdefer if (!borrows_pending_resume and folded_summary_indices.len > 0) {
            alloc.free(folded_summary_indices);
        };
        const source_row_provenance: []const transcript_blocks.RowProvenance =
            switch (target.body_disposition) {
                .paint => prepared.row_provenance.items,
                .retain_committed => switch (self.transcript_commit_state) {
                    .invalid => &.{},
                    .stable => |anchor| anchor.row_provenance,
                    .recovering => |receipt| receipt.row_provenance,
                },
            };
        const row_provenance = try alloc.dupe(
            transcript_blocks.RowProvenance,
            source_row_provenance,
        );
        errdefer if (row_provenance.len > 0) alloc.free(row_provenance);

        const append_base = try self.resolveTransitionAppendBase(
            prepared,
            scroll_facts,
            destructive_invalidation,
            target_flow,
            target.history_visual_offset,
        );
        const append_is_history_replay = if (append_base) |base|
            base.history_replay != null
        else
            false;

        const source_flow_end_exact = switch (self.transcript_commit_state) {
            .recovering => |receipt| receipt.materialized_flow_len != null,
            .invalid, .stable => true,
        };
        const natural_projected_flow_end: ?usize = if (target.projection_staged)
            target.staged_flow_end
        else if (source_flow_end_exact)
            target_flow.len
        else
            null;
        const held_projected_flow_end: ?usize = if (target.hold_staged)
            if (append_base) |base| held: {
                const base_visual_end = base.visual_offset + base.visual_rows;
                const target_base_flow_end =
                    transcript_painter.preparedTranscriptFlowOffsetForVisualOffset(
                        prepared,
                        self.layout.cols,
                        base_visual_end,
                    ) orelse break :held null;
                if (target_base_flow_end < base.flow_len) break :held null;
                // Target growth can terminate the committed line at its byte
                // endpoint. Charge that cursor movement before advancing into
                // the final rows this frame may release.
                const drift = walkText(
                    1,
                    base.cursor_col,
                    target_flow[base.flow_len..target_base_flow_end],
                    self.layout.cols,
                ).end_row - 1;
                if (drift > accepted.semantic_progress_rows) break :held base.flow_len;
                break :held transcript_painter.preparedTranscriptFlowOffsetForVisualOffset(
                    prepared,
                    self.layout.cols,
                    base_visual_end + accepted.semantic_progress_rows - drift,
                );
            } else null
        else
            null;
        const projected_flow_end: ?usize = if (append_base) |base|
            if (base.history_replay) |replay|
                replay.flow_end
            else
                held_projected_flow_end orelse natural_projected_flow_end
        else
            natural_projected_flow_end;
        var document_append = render_engine.frame_scroll_plan.FrameDocumentAppend{};
        var document_append_bytes: []u8 = &.{};
        var presentation_resume_bytes: []u8 = &.{};
        var presentation_pending_wrap = false;
        var presentation_valid = false;
        errdefer if (document_append_bytes.len > 0) {
            alloc.free(document_append_bytes);
        };
        errdefer if (presentation_resume_bytes.len > 0) {
            alloc.free(presentation_resume_bytes);
        };
        if (plan.reset_terminal) {
            const replay_padding_rows = target_layout.terminal_rows -| target.cursor_row;
            document_append_bytes = try transcript_painter.prepareResetReplayDocument(
                self,
                alloc,
                target_flow,
                prepared.sourceVisibleLines(),
                prepared.sourceVisualRows(),
                prepared.transcript_ends_with_newline,
                replay_padding_rows,
            );
            document_append = .{
                .bytes = document_append_bytes,
                .start_row = 1,
                .start_col = 1,
                .reset_replay = true,
            };
            debug_trace.logf(
                "scroll",
                "document_append_plan raw_bytes={d} wire_bytes={d} start={d},{d} source_visual_offset={d} target_visual_offset={d} planned_scroll_rows={d}",
                .{
                    target_flow.len,
                    document_append.bytes.len,
                    document_append.start_row,
                    document_append.start_col,
                    0,
                    target.visual_offset,
                    scroll_plan.terminal_scroll_rows,
                },
            );
        } else if (append_base != null and
            (!scroll_facts.recovery_rebase or append_is_history_replay) and
            !scroll_facts.recovery_projection_deferred and
            (if (append_is_history_replay)
                accepted.semantic_rows > 0
            else
                accepted.semantic_progress_rows > 0) and
            projected_flow_end != null and
            projected_flow_end.? > append_base.?.flow_len and
            scroll_plan.terminal_scroll_rows > 0)
        {
            const base = append_base.?;
            const raw_append =
                target_flow[base.flow_len..projected_flow_end.?];
            const resume_boundary: ?transcript_painter.PresentationBoundary = if (base.flow_len == 0)
                .{}
            else switch (self.transcript_commit_state) {
                .recovering => |receipt| if (receipt.presentation_valid and
                    receipt.materialized_flow_len == base.flow_len)
                    .{
                        .resume_bytes = receipt.presentation_resume_bytes,
                        .cursor_col = base.cursor_col,
                        .pending_wrap = receipt.presentation_pending_wrap,
                    }
                else
                    null,
                .invalid, .stable => null,
            };
            if (borrows_pending_resume and
                base.history_replay == null and
                resume_boundary != null)
            {
                var prepared_append = try transcript_painter.prepareResumeDocumentAppend(
                    alloc,
                    target_flow,
                    self.layout.cols,
                    base.flow_len,
                    projected_flow_end.?,
                    target.projection_staged,
                    resume_boundary.?,
                    true,
                );
                defer prepared_append.deinit(alloc);
                document_append_bytes = prepared_append.bytes;
                prepared_append.bytes = &.{};
                presentation_resume_bytes = prepared_append.endpoint_resume_bytes;
                prepared_append.endpoint_resume_bytes = &.{};
                presentation_pending_wrap = prepared_append.endpoint_pending_wrap;
                presentation_valid = true;
            } else {
                document_append_bytes = try transcript_painter.prepareTranscriptDocumentAppendBytes(
                    alloc,
                    target_flow,
                    self.layout.cols,
                    base.flow_len,
                    projected_flow_end.?,
                    target.projection_staged,
                );
            }
            document_append = .{
                .bytes = if (document_append_bytes.len > 0)
                    document_append_bytes
                else
                    raw_append,
                .start_row = base.cursor_row,
                .start_col = base.cursor_col,
                .clear = if (base.history_replay) |replay|
                    .{ .rows = replay.clear_rows }
                else
                    .remainder,
            };
            debug_trace.logf(
                "scroll",
                "document_append_plan raw_bytes={d} wire_bytes={d} start={d},{d} source_visual_offset={d} target_visual_offset={d} planned_scroll_rows={d}",
                .{
                    raw_append.len,
                    document_append.bytes.len,
                    document_append.start_row,
                    document_append.start_col,
                    base.visual_offset,
                    target.visual_offset,
                    scroll_plan.terminal_scroll_rows,
                },
            );
        }
        const source_history_visual_offset = switch (self.transcript_commit_state) {
            .invalid => 0,
            .stable => |anchor| anchor.history_visual_offset,
            .recovering => |receipt| receipt.accepted_history_visual_offset,
        };
        const planned_history = resolvePlannedHistoryMaterialization(
            source_history_visual_offset,
            target.history_visual_offset,
            target.visual_offset,
            plan.reset_terminal or !document_append.isEmpty(),
            target.normal_buffer_recovery_pending,
        );
        if (planned_history.visual_offset != target.history_visual_offset) {
            debug_trace.logf(
                "scroll",
                "transcript_history_materialization_deferred source_visual_offset={d} target_visual_offset={d}",
                .{ source_history_visual_offset, target.history_visual_offset },
            );
        }
        target.history_visual_offset = planned_history.visual_offset;
        target.normal_buffer_recovery_pending =
            planned_history.normal_buffer_recovery_pending;
        const materialized = resolveMaterializedEndpoint(
            target,
            source_endpoint_cursor_row,
            source_endpoint_cursor_col,
            append_base,
            projected_flow_end,
            target_flow.len,
            target_layout.transcript_area,
        );
        return .{
            .scroll_plan = scroll_plan,
            .document_append = document_append,
            .document_append_bytes = document_append_bytes,
            .history_settle_pending = scroll_facts.recovery_rebase and
                !self.fullTranscriptActive() and
                self.finalityReleasableOffset(
                    prepared,
                    scroll_facts.target_visual_offset,
                ) > target.history_visual_offset,
            .resize_reflow_rows = scroll_facts.resize_reflow_rows,
            .semantic_rows = scroll_facts.semantic_rows,
            .semantic_progress_rows = scroll_facts.semantic_progress_rows,
            .recovery_rebase = scroll_facts.recovery_rebase,
            .recovery_progress_compatible = scroll_facts.recovery_progress_compatible,
            .recovery_tracks_semantic_progress = scroll_facts.recovery_tracks_semantic_progress,
            .recovery_projection_deferred = scroll_facts.recovery_projection_deferred,
            .body_disposition = target.body_disposition,
            .target_flow = target_flow,
            .target_flow_owned = !borrows_pending_resume,
            .presentation_resume_bytes = presentation_resume_bytes,
            .presentation_pending_wrap = presentation_pending_wrap,
            .presentation_valid = presentation_valid,
            .target_cache = target_cache,
            .target_cache_unchanged = borrows_pending_resume,
            .target_cache_origin_untrimmed = target_cache_origin_untrimmed,
            .folded_summary_indices = folded_summary_indices,
            .target_layout = target_layout,
            .selection = target.selection,
            .visual_offset = target.visual_offset,
            .history_visual_offset = target.history_visual_offset,
            .source_endpoint_visual_offset = target.source_endpoint_visual_offset,
            .total_visual_rows = target.total_visual_rows,
            .materialized = materialized,
            .materialized_without_append = self.materializedEndpointWithoutAppend(
                document_append,
                materialized,
            ),
            .cursor_row = target.cursor_row,
            .cursor_col = target.cursor_col,
            .replaceable_last_line = transition_replaceable_last_line,
            .replaceable_start = transition_replaceable_start,
            .replaceable_row = prepared.cursor.replaceable_row,
            .trace_transcript_frame = prepared.trace_transcript_frame,
            .trace_visible_rows = prepared.trace_visible_rows,
            .measured_history_origin = target.measured_history_origin,
            .row_provenance = row_provenance,
            .normal_buffer_recovery_pending = target.normal_buffer_recovery_pending,
            .history_catchup_pending = target.history_catchup_pending,
        };
    }

    pub fn consumeTranscriptTransition(
        self: *TranscriptRuntime,
        alloc: Allocator,
        transition: *TranscriptTransition,
        result: render_engine.terminal_diff.FrameCommitResult,
    ) void {
        const scroll_commit = result.scrollCommit(transition.scroll_plan);
        self.consumeTranscriptTransitionWithCommit(alloc, transition, result, scroll_commit);
    }

    pub fn consumeFrameScrollCommit(
        self: *TranscriptRuntime,
        alloc: Allocator,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        result: render_engine.terminal_diff.FrameCommitResult,
        transition: ?*TranscriptTransition,
    ) void {
        const terminal_reset_commit =
            result.is_committed() and self.terminal_reset_pending;
        const resize_reset_commit =
            terminal_reset_commit and
            (self.pending_resize_observation != null or
                self.resize_history_row_delta != null);
        const scroll_commit = result.scrollCommit(scroll_plan);
        self.ackPreservedRowReleaseCommit(scroll_plan, scroll_commit);
        if (transition) |value| {
            std.debug.assert(std.meta.eql(scroll_plan, value.scroll_plan));
            self.consumeTranscriptTransitionWithCommit(alloc, value, result, scroll_commit);
        }
        const committed_selection = if (result.is_committed())
            if (transition) |value| value.selection else null
        else
            null;
        self.resize_bottom_anchor_pending = nextResizeBottomAnchorPending(
            self.resize_bottom_anchor_pending,
            terminal_reset_commit,
            resize_reset_commit,
            if (committed_selection) |selection| selection.tail_kind else null,
            if (committed_selection) |selection| selection.last_visible_row else 0,
            self.layout.content_bottom,
        );
    }

    fn consumeTranscriptTransitionWithCommit(
        self: *TranscriptRuntime,
        alloc: Allocator,
        transition: *TranscriptTransition,
        result: render_engine.terminal_diff.FrameCommitResult,
        scroll_commit: render_engine.frame_scroll_plan.FrameScrollCommit,
    ) void {
        std.debug.assert(!transition.consumed);
        const commit = resolveTranscriptTransitionCommit(transition, result, scroll_commit);
        if (commit.accepted.resize_reflow_rows > 0 and transition.measured_history_origin != null) {
            debug_trace.logf(
                "resize",
                "measured_history_endpoint_commit rows={d} before={s} after={s}",
                .{
                    commit.accepted.resize_reflow_rows,
                    if (transition.measured_history_origin.?.endpoint != null) "exact" else "unavailable",
                    if (commit.committed_measured_history_origin.?.endpoint != null) "exact" else "unavailable",
                },
            );
        }

        if (result.is_committed()) {
            self.committed_frame_layout = transition.target_layout;
        }

        const borrowed_resume_source = if (!transition.target_flow_owned)
            if (self.pending_resume_source) |*source|
                if (transition.target_flow.len == 0 or
                    source.bytes.ptr == transition.target_flow.ptr) source else null
            else
                null
        else
            null;
        if (commit.stable and !transition.target_flow_owned and borrowed_resume_source == null) {
            debug_trace.logf(
                "scroll",
                "transcript_transition_commit state=invalid reason=missing_borrowed_resume_source",
                .{},
            );
            transition.target_flow = &.{};
            var previous_state = self.transcript_commit_state;
            self.transcript_commit_state = .invalid;
            previous_state.deinit(alloc);
            self.markTranscriptDirty();
        } else if (commit.stable) {
            var previous_cache: std.ArrayList(u8) = .empty;
            if (!transition.target_cache_unchanged) {
                previous_cache = self.transcript;
                self.transcript = transition.target_cache;
                transition.target_cache = .empty;
                self.transcript_cache_origin_untrimmed =
                    transition.target_cache_origin_untrimmed;
            }
            const target_has_content = transition.target_flow.len > 0;
            const retained_body = transition.body_disposition == .retain_committed;

            const summary_count = @min(
                self.folded_command_blocks.items.len,
                transition.folded_summary_indices.len,
            );
            for (self.folded_command_blocks.items[0..summary_count], 0..) |*block, index| {
                block.summary_transcript_index = transition.folded_summary_indices[index];
            }

            const stable_flow = transition.target_flow;
            const pending_resume_bytes = if (transition.target_flow_owned)
                self.releasePendingResumeSource(alloc)
            else blk: {
                const pending = borrowed_resume_source.?;
                pending.bytes = &.{};
                const bytes = stable_flow.len;
                _ = self.releasePendingResumeSource(alloc);
                break :blk bytes;
            };
            transition.target_flow = &.{};

            var previous_state = self.transcript_commit_state;
            self.transcript_commit_state = .{ .stable = .{
                .selection = transition.selection,
                .visual_offset = transition.visual_offset,
                .history_visual_offset = transition.history_visual_offset,
                .total_visual_rows = transition.total_visual_rows,
                .flow = stable_flow,
                .cursor_row = transition.cursor_row,
                .cursor_col = transition.cursor_col,
                .occupied_last_row = transition.selection.last_visible_row,
                .occupied_last_row_blank = transition.selection.last_visible_row_blank,
                .layout_id = transition.target_layout.layout_id,
                .measured_history_origin = commit.committed_measured_history_origin,
                .row_provenance = transition.row_provenance,
                .normal_buffer_recovery_pending = transition.normal_buffer_recovery_pending,
                .history_catchup_pending = transition.history_catchup_pending,
            } };
            transition.row_provenance = &.{};

            self.last_rendered_cols = transition.target_layout.terminal_cols;
            if (pending_resume_bytes > 0) {
                self.invalidateTranscriptAnchor("resume publication retained source handoff");
                if (transition.target_flow_owned) {
                    debug_trace.logf(
                        "session",
                        "pending resume flow dropped reason=superseded bytes={d}",
                        .{pending_resume_bytes},
                    );
                } else {
                    debug_trace.logf(
                        "session",
                        "resume historical flow committed bytes={d}",
                        .{pending_resume_bytes},
                    );
                }
                self.markTranscriptDirty();
            }
            if (!retained_body and !self.fullTranscriptActive()) {
                self.last_visible_transcript_top_row = transition.selection.top_row;
                self.last_visible_transcript_start_line = transition.selection.start_line;
                self.last_visible_transcript_partial_skip_rows = transition.selection.partial_skip_rows;
                self.last_visible_transcript_split_active = transition.selection.split_active;
                self.last_visible_transcript_split_prefix_lines = transition.selection.split_prefix_lines;
                self.last_visible_transcript_split_suffix_start_line = transition.selection.split_suffix_start_line;
                self.last_visible_transcript_last_row = transition.selection.last_visible_row;
                self.last_visible_transcript_last_row_blank = transition.selection.last_visible_row_blank;
                self.last_visible_transcript_tail_kind = transition.selection.tail_kind;
                self.last_viewport_selection = transition.selection;
                self.cursor_row = transition.cursor_row;
                self.cursor_col = transition.cursor_col;
                self.replaceable_last_line = transition.replaceable_last_line;
                self.replaceable_start = transition.replaceable_start;
                self.replaceable_row = transition.replaceable_row;
                self.paint_trace.transcript_initialized = true;
                self.paint_trace.transcript_top = transition.selection.top_row;
                self.paint_trace.transcript_bottom = transition.selection.bottom_row;
                self.paint_trace.transcript_start_line = transition.selection.start_line;
                self.paint_trace.transcript_total_lines = transition.selection.line_count;
                self.paint_trace.transcript_visible_rows = transition.trace_visible_rows;
                self.paint_trace.transcript_partial_skip_rows = transition.selection.partial_skip_rows;
                self.paint_trace.transcript_entries = self.entries.items.len;
                self.paint_trace.transcript_log_frame = transition.trace_transcript_frame;
            }
            if (target_has_content and !self.has_painted_transcript) {
                self.has_painted_transcript = true;
            }

            previous_state.deinit(alloc);
            previous_cache.deinit(alloc);
            debug_trace.logf(
                "scroll",
                "transcript_transition_commit state=stable start={d} visual_offset={d} history_visual_offset={d} layout_id={x} cursor={d},{d}",
                .{
                    transition.selection.start_line,
                    transition.visual_offset,
                    transition.history_visual_offset,
                    transition.target_layout.layout_id,
                    transition.cursor_row,
                    transition.cursor_col,
                },
            );
            if (transition.normal_buffer_recovery_pending) {
                self.markTranscriptDirty();
            }
        } else {
            const recovery = resolveTranscriptRecoveryCommit(self, transition, result, commit);
            var previous_state = self.transcript_commit_state;
            var presentation_resume_bytes: []u8 = &.{};
            var presentation_pending_wrap = false;
            var presentation_valid = false;
            if (result.document_append_applied() and transition.presentation_valid) {
                presentation_resume_bytes = transition.presentation_resume_bytes;
                presentation_pending_wrap = transition.presentation_pending_wrap;
                presentation_valid = true;
                transition.presentation_resume_bytes = &.{};
                transition.presentation_valid = false;
            } else switch (previous_state) {
                .recovering => |*receipt| {
                    presentation_resume_bytes = receipt.presentation_resume_bytes;
                    presentation_pending_wrap = receipt.presentation_pending_wrap;
                    presentation_valid = receipt.presentation_valid;
                    receipt.presentation_resume_bytes = &.{};
                    receipt.presentation_valid = false;
                },
                .invalid, .stable => {},
            }
            self.transcript_commit_state = .{ .recovering = .{
                .accepted_visual_offset = recovery.accepted_visual_offset,
                .accepted_history_visual_offset = recovery.accepted_history_visual_offset,
                .attempt_visual_offset = transition.source_endpoint_visual_offset,
                .attempt_total_visual_rows = transition.total_visual_rows,
                .materialized_visual_offset = recovery.materialized_visual_offset,
                .materialized_visual_rows = recovery.materialized_visual_rows,
                .materialized_flow_len = recovery.materialized_flow_len,
                .remaining_resize_reflow_rows = commit.remaining_resize_reflow_rows,
                .remaining_semantic_rows = commit.remaining_semantic_rows,
                .remaining_semantic_progress_rows = commit.remaining_semantic_progress_rows,
                .remaining_unplanned_scroll_rows = commit.remaining_unplanned_scroll_rows,
                .attempt_cols = transition.target_layout.terminal_cols,
                .attempt_resize_history_row_delta = self.resize_history_row_delta,
                .attempt_resize_history_committed = result.is_committed(),
                .projection_rebase_pending = transition.recovery_rebase,
                .tracks_semantic_progress = transition.recovery_tracks_semantic_progress,
                .flow = transition.target_flow,
                .flow_owned = transition.target_flow_owned,
                .presentation_resume_bytes = presentation_resume_bytes,
                .presentation_pending_wrap = presentation_pending_wrap,
                .presentation_valid = presentation_valid,
                .cursor_row = recovery.materialized_cursor_row,
                .cursor_col = recovery.materialized_cursor_col,
                .document_append_committed = recovery.document_append_committed,
                .measured_history_origin = commit.committed_measured_history_origin,
                .row_provenance = transition.row_provenance,
                .normal_buffer_recovery_pending = transition.normal_buffer_recovery_pending,
            } };
            transition.target_flow = &.{};
            transition.row_provenance = &.{};
            previous_state.deinit(alloc);
            if (commit.complete and
                !transition.recovery_projection_deferred and
                (commit.remaining_resize_reflow_rows > 0 or commit.remaining_semantic_rows > 0))
            {
                self.markTranscriptDirty();
            }
            debug_trace.logf(
                "scroll",
                "transcript_transition_commit state=recovering accepted_resize_reflow_rows={d} accepted_semantic_rows={d} accepted_semantic_progress_rows={d} remaining_resize_reflow_rows={d} remaining_semantic_rows={d} remaining_semantic_progress_rows={d} remaining_unplanned_scroll_rows={d} recovery_rebase={s} recovery_projection_deferred={s} append_committed={s} shadow_state={s}",
                .{
                    commit.accepted.resize_reflow_rows,
                    commit.accepted.semantic_rows,
                    commit.accepted.semantic_progress_rows,
                    commit.remaining_resize_reflow_rows,
                    commit.remaining_semantic_rows,
                    commit.remaining_semantic_progress_rows,
                    commit.remaining_unplanned_scroll_rows,
                    if (transition.recovery_rebase) "true" else "false",
                    if (transition.recovery_projection_deferred) "true" else "false",
                    if (recovery.document_append_committed) "true" else "false",
                    @tagName(result.state()),
                },
            );
        }

        if (transition.folded_summary_indices.len > 0) {
            alloc.free(transition.folded_summary_indices);
            transition.folded_summary_indices = &.{};
        }
        if (transition.history_settle_pending) {
            // Final rows remain unmaterialized past this commit; guarantee a
            // follow-up frame so the debt settles without external activity.
            self.render_requests.request(.transcript);
        }
        transition.consumed = true;
    }

    /// Writes only to the byte buffer for callers that separately append a
    /// structured entry. Use `writeTranscript` when raw-entry mirroring is needed.
    pub fn writeTranscriptBytes(self: *TranscriptRuntime, alloc: Allocator, metrics: *Metrics, text: []const u8, record: bool) !void {
        return transcript_writer.writeTranscriptBytes(self, alloc, metrics, text, record);
    }

    pub fn estimatedReflowedCursorRow(self: *const TranscriptRuntime, target_cols: u16) ?u32 {
        const shadow = self.shadow_vt orelse return null;
        if (target_cols == 0 or shadow.cursor_row == 0) return null;
        return reflowedRows(shadow, 1, shadow.cursor_row, target_cols, true);
    }

    pub fn ackPreservedRowRelease(
        self: *TranscriptRuntime,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        committed_terminal_scroll_rows: u16,
    ) !void {
        try scroll_plan.validate(self.layout.rows);
        self.ackPreservedRowReleaseAssumeValid(scroll_plan, committed_terminal_scroll_rows);
    }

    pub fn ackPreservedRowReleaseAssumeValid(
        self: *TranscriptRuntime,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        committed_terminal_scroll_rows: u16,
    ) void {
        const scroll_commit = scroll_plan.commit(committed_terminal_scroll_rows);
        self.ackPreservedRowReleaseCommit(scroll_plan, scroll_commit);
    }

    fn ackPreservedRowReleaseCommit(
        self: *TranscriptRuntime,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
        scroll_commit: render_engine.frame_scroll_plan.FrameScrollCommit,
    ) void {
        const accepted = scroll_commit.accepted_rows;
        const raw_owned_top = self.owned_top_row;
        const raw_viewport_top = self.viewport_top_row;
        const normalized_viewport_top = render_engine.frame_scroll_plan.normalizeOwnedTop(
            self.viewport_top_row,
            self.layout.rows,
        );

        self.owned_top_row = scroll_plan.prior_owned_top -| accepted.preserved_release_rows;
        self.viewport_top_row = @max(
            self.owned_top_row,
            normalized_viewport_top -| accepted.preserved_release_rows,
        );
        debug_trace.logf(
            "scroll",
            "preserved_row_release requested={d} planned={d} committed_terminal={d} accepted_terminal={d} unplanned_terminal={d} accepted={d} raw_owned_top={d} raw_viewport_top={d} normalized_owned_top={d} normalized_viewport_top={d} owned_top={d} viewport_top={d}",
            .{
                scroll_plan.requested_release_rows,
                scroll_plan.preserved_release_rows,
                scroll_commit.physical_terminal_scroll_rows,
                scroll_commit.accepted_terminal_scroll_rows,
                scroll_commit.unplanned_terminal_scroll_rows,
                accepted.preserved_release_rows,
                raw_owned_top,
                raw_viewport_top,
                scroll_plan.prior_owned_top,
                normalized_viewport_top,
                self.owned_top_row,
                self.viewport_top_row,
            },
        );
    }

    /// Writes to the byte buffer and mirrors the content as a raw entry.
    /// Structured writers must use `writeTranscriptBytes` to avoid duplication.
    pub fn writeTranscript(self: *TranscriptRuntime, alloc: Allocator, metrics: *Metrics, text: []const u8, record: bool) !void {
        return transcript_writer.writeTranscript(self, alloc, metrics, text, record);
    }

    pub fn writeTranscriptClassified(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        text: []const u8,
        record: bool,
        class: RawEntryClass,
    ) !void {
        return transcript_writer.writeTranscriptClassified(self, alloc, metrics, text, record, class);
    }

    pub fn writeTranscriptBytesFrom(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        text: []const u8,
        record: bool,
        entry_id: u32,
    ) !void {
        return transcript_writer.writeTranscriptBytesFrom(
            self,
            alloc,
            metrics,
            text,
            record,
            entry_id,
        );
    }

    pub fn writeCompletedToolStatus(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        kind: types.ToolOutcomeKind,
        summary: []const u8,
        record: bool,
    ) !void {
        _ = try self.writeCompletedToolStatusReturningEntryId(
            alloc,
            metrics,
            kind,
            summary,
            record,
        );
    }

    pub fn writeCompletedToolStatusReturningEntryId(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        kind: types.ToolOutcomeKind,
        summary: []const u8,
        record: bool,
    ) !u32 {
        const line = try lifecycleTerminalLine(alloc, kind, summary);
        defer alloc.free(line);
        return transcript_writer.writeTranscriptReturningEntryIdClassified(
            self,
            alloc,
            metrics,
            line,
            record,
            .tool_status,
        );
    }

    /// Rebuild the transcript cache at the current width and request a
    /// diagnostic full-frame repaint. Terminal mutation remains owned
    /// by the frame commit path.
    pub fn reconstructivePaint(self: *TranscriptRuntime, alloc: Allocator, metrics: *Metrics) !void {
        return transcript_writer.reconstructivePaint(self, alloc, metrics);
    }

    pub fn appendReplaceableTranscriptLine(self: *TranscriptRuntime, alloc: Allocator, metrics: *Metrics, text: []const u8) !u32 {
        return transcript_store.appendReplaceableTranscriptLine(self, alloc, metrics, text);
    }

    pub fn appendReplaceableTranscriptLineClassified(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        text: []const u8,
        class: RawEntryClass,
    ) !u32 {
        return transcript_store.appendReplaceableTranscriptLineClassified(self, alloc, metrics, text, class);
    }

    pub fn replaceTrailingTranscriptLine(self: *TranscriptRuntime, alloc: Allocator, metrics: *Metrics, text: []const u8) !bool {
        return transcript_store.replaceTrailingTranscriptLine(self, alloc, metrics, text);
    }

    /// Returns the id of the mirrored `raw_bytes` entry, or `0` when
    /// `text` is empty (sentinel: `next_entry_id` starts at 1).
    pub fn appendReplaceableTranscriptLineSilent(self: *TranscriptRuntime, alloc: Allocator, text: []const u8) !u32 {
        return transcript_store.appendReplaceableTranscriptLineSilent(self, alloc, text);
    }

    pub fn appendReplaceableTranscriptLineSilentClassified(self: *TranscriptRuntime, alloc: Allocator, text: []const u8, class: RawEntryClass) !u32 {
        return transcript_store.appendReplaceableTranscriptLineSilentClassified(self, alloc, text, class);
    }

    pub fn replaceTrailingTranscriptLineSilent(self: *TranscriptRuntime, alloc: Allocator, text: []const u8) !bool {
        return transcript_store.replaceTrailingTranscriptLineSilent(self, alloc, text);
    }

    pub fn writeNotice(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        notice: types.SemanticNotice,
        record: bool,
    ) !void {
        return transcript_store.writeNotice(self, alloc, metrics, notice, record) catch |err| switch (err) {
            error.InputPending => unreachable,
            else => |other| return other,
        };
    }

    pub fn appendReplaceableSemanticNotice(
        self: *TranscriptRuntime,
        alloc: Allocator,
        notice: types.SemanticNotice,
    ) !u32 {
        return transcript_store.appendReplaceableSemanticNoticeAtomic(self, alloc, notice);
    }

    pub fn appendSemanticNotice(
        self: *TranscriptRuntime,
        alloc: Allocator,
        notice: types.SemanticNotice,
    ) !u32 {
        return transcript_store.appendSemanticNoticeAtomic(self, alloc, notice);
    }

    pub fn replaceSemanticNotice(
        self: *TranscriptRuntime,
        alloc: Allocator,
        entry_id: u32,
        notice: types.SemanticNotice,
    ) !bool {
        return transcript_store.replaceSemanticNoticeAtomic(self, alloc, entry_id, notice);
    }

    pub fn setCommandOutputRenderPolicy(self: *TranscriptRuntime, styles: Styles) void {
        return command_output_runtime.setCommandOutputRenderPolicy(self, styles);
    }

    pub fn retainedTranscriptStyles(self: *const TranscriptRuntime) Styles {
        return self.command_output_render.styles;
    }

    pub fn writeRecordedCommandOutputChunkAtomic(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        styles: Styles,
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_output_content.Stream,
        text: []const u8,
    ) !?u32 {
        return transcript_store.writeRecordedCommandOutputChunkAtomic(
            self,
            alloc,
            metrics,
            styles,
            lifecycle_id,
            stream,
            text,
        );
    }

    pub fn flushRecordedCommandOutputSummaryAtomic(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        styles: Styles,
        lifecycle_id: ?types.ToolLifecycleId,
    ) !void {
        return transcript_store.flushRecordedCommandOutputSummaryAtomic(
            self,
            alloc,
            metrics,
            styles,
            lifecycle_id,
        );
    }

    pub fn writeCommandOutputChunk(self: *TranscriptRuntime, alloc: Allocator, metrics: *Metrics, styles: Styles, stream: command_output_content.Stream, text: []const u8, record: bool) !void {
        return command_output_runtime.writeCommandOutputChunk(self, alloc, metrics, styles, stream, text, record);
    }

    pub fn writeCommandOutputChunkForLifecycle(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        styles: Styles,
        lifecycle_id: ?types.ToolLifecycleId,
        stream: command_output_content.Stream,
        text: []const u8,
        record: bool,
    ) !void {
        return command_output_runtime.writeCommandOutputChunkForLifecycle(
            self,
            alloc,
            metrics,
            styles,
            lifecycle_id,
            stream,
            text,
            record,
        );
    }

    pub fn flushCommandOutputSummary(self: *TranscriptRuntime, alloc: Allocator, metrics: *Metrics, styles: Styles, record: bool) !void {
        return command_output_runtime.flushCommandOutputSummary(self, alloc, metrics, styles, record);
    }

    pub fn flushCommandOutputSummaryForLifecycle(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        styles: Styles,
        lifecycle_id: ?types.ToolLifecycleId,
        record: bool,
    ) !void {
        return command_output_runtime.flushCommandOutputSummaryForLifecycle(
            self,
            alloc,
            metrics,
            styles,
            lifecycle_id,
            record,
        );
    }

    pub fn openCommandOutputLifecycleId(
        self: *const TranscriptRuntime,
    ) ?types.ToolLifecycleId {
        return command_output_runtime.openCommandOutputLifecycleId(self);
    }

    pub fn frameSink(self: *TranscriptRuntime) render_engine.terminal_diff.FrameSink {
        return transcript_io.frameSinkFrom(@ptrCast(self), writeFrameSink);
    }

    pub fn writeNotificationBell(
        self: *TranscriptRuntime,
        metrics: *Metrics,
    ) void {
        switch (transcript_io.writeFrameBytes(self, metrics, "\x07")) {
            .complete => {},
            .partial => |partial| debug_trace.logf(
                "notifications",
                "terminal bell write failed accepted_bytes={d} err={s}",
                .{ partial.accepted_bytes, @errorName(partial.err) },
            ),
        }
    }

    fn writeFrameSink(ctx: *anyopaque, metrics: *Metrics, bytes: []const u8) render_engine.terminal_diff.FrameSinkWriteResult {
        const self: *TranscriptRuntime = @ptrCast(@alignCast(ctx));
        return transcript_io.writeFrameBytes(self, metrics, bytes);
    }

    pub fn recomputeCursorFromTranscript(self: *TranscriptRuntime) void {
        self.resetCursorTracking();
        if (self.transcript.items.len == 0) return;
        _ = self.advanceCursor(self.transcript.items);
    }

    pub fn prepareTranscriptSurfacePaint(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        bottom_reserved_rows: u16,
    ) !transcript_painter.PreparedTranscriptSurfacePaint {
        return transcript_painter.prepareTranscriptSurfacePaint(self, alloc, metrics, bottom_reserved_rows);
    }

    pub fn prepareTranscriptSource(
        self: *TranscriptRuntime,
        alloc: Allocator,
        tracked_entry_id: ?u32,
    ) !TranscriptPreparationSource {
        if (self.pending_resume_source) |*source| {
            return source.clone(alloc);
        }
        return source_preparation.prepareTranscriptSource(self, alloc, tracked_entry_id);
    }

    pub fn cachedTranscriptSource(
        self: *TranscriptRuntime,
        alloc: Allocator,
    ) !TranscriptPreparationSource {
        return self.cachedTranscriptSourceInterruptible(alloc, null) catch |err| switch (err) {
            error.InputPending => unreachable,
            else => |other| return other,
        };
    }

    pub fn pendingResumeSourceInterruptible(
        self: *TranscriptRuntime,
        alloc: Allocator,
        checkpoint: ?*build_checkpoint.BuildCheckpoint,
    ) !?*TranscriptPreparationSource {
        var source = if (self.pending_resume_source) |*value| value else return null;
        if (source.cols != self.layout.cols) {
            debug_trace.logf(
                "full_transcript_cache",
                "pending_resume_rebuild old_cols={d} new_cols={d}",
                .{ source.cols, self.layout.cols },
            );
            try build_checkpoint.poll(checkpoint);
            const bytes = try alloc.dupe(u8, source.bytes);
            var replacement = try source_preparation.prepareFullTranscriptViewportSourceInterruptible(
                self,
                alloc,
                bytes,
                checkpoint,
            );
            errdefer replacement.deinit(alloc);
            try replacement.ensureLineIndexInterruptible(alloc, checkpoint);
            const previous_bytes = source.bytes;
            source.deinit(alloc);
            self.pending_resume_source = replacement;
            source = &self.pending_resume_source.?;
            switch (self.transcript_commit_state) {
                .recovering => |*receipt| if (!receipt.flow_owned) {
                    std.debug.assert(receipt.flow.ptr == previous_bytes.ptr);
                    receipt.flow = source.bytes;
                },
                .invalid, .stable => {},
            }
        } else if (source.hard_line_starts.len == 0) {
            try source.ensureLineIndexInterruptible(alloc, checkpoint);
        } else {
            try build_checkpoint.poll(checkpoint);
        }
        return source;
    }

    pub fn cachedTranscriptSourceInterruptible(
        self: *TranscriptRuntime,
        alloc: Allocator,
        checkpoint: ?*build_checkpoint.BuildCheckpoint,
    ) !TranscriptPreparationSource {
        if (self.pending_resume_source != null) {
            return self.prepareTranscriptSource(alloc, null);
        }
        if (self.compact_transcript_source_cache.find(
            self.full_transcript_content_revision,
            self.layout.cols,
            self.has_committed_frame,
        )) |source| {
            source.preview.cursor_row = self.cursor_row;
            source.preview.cursor_col = self.cursor_col;
            source.preview.replaceable_row = self.replaceable_row;
            source.replaceable_row = self.replaceable_row;
            return source.clone(alloc);
        }

        var source = try source_preparation.prepareTranscriptSourceInterruptible(
            self,
            alloc,
            null,
            null,
            null,
            checkpoint,
        );
        errdefer source.deinit(alloc);
        try source.ensureLineIndexInterruptible(alloc, checkpoint);
        const cached = self.compact_transcript_source_cache.insert(alloc, .{
            .source = source,
            .content_revision = self.full_transcript_content_revision,
            .cols = self.layout.cols,
            .has_committed_frame = self.has_committed_frame,
        });
        return cached.clone(alloc);
    }

    pub fn prepareTranscriptSourceForFrameInterruptible(
        self: *TranscriptRuntime,
        alloc: Allocator,
        focused_entry_id: ?u32,
        omitted_entry_id: ?u32,
        checkpoint: ?*build_checkpoint.BuildCheckpoint,
    ) !TranscriptPreparationSource {
        return source_preparation.prepareTranscriptSourceInterruptible(
            self,
            alloc,
            focused_entry_id,
            focused_entry_id,
            omitted_entry_id,
            checkpoint,
        );
    }

    pub fn prepareTranscriptSourceOmittingEntry(
        self: *TranscriptRuntime,
        alloc: Allocator,
        omitted_entry_id: u32,
    ) !TranscriptPreparationSource {
        return source_preparation.prepareTranscriptSourceOmittingEntry(self, alloc, omitted_entry_id);
    }

    pub fn prepareTranscriptSourceWithFocusedEntry(
        self: *TranscriptRuntime,
        alloc: Allocator,
        focused_entry_id: u32,
    ) !TranscriptPreparationSource {
        return source_preparation.prepareTranscriptSourceWithFocusedEntry(self, alloc, focused_entry_id);
    }

    pub fn prepareFullTranscriptViewportSource(
        self: *TranscriptRuntime,
        alloc: Allocator,
        bytes: []u8,
    ) !TranscriptPreparationSource {
        return source_preparation.prepareFullTranscriptViewportSource(self, alloc, bytes);
    }

    pub const FullTranscriptSurfacePaint = struct {
        source: TranscriptPreparationSource,
        prepared: transcript_painter.PreparedTranscriptSurfacePaint,
    };

    pub noinline fn buildFullTranscriptProjection(
        self: *TranscriptRuntime,
        alloc: Allocator,
        full_diff_resolver: ?full_transcript_screen.FullDiffResolver,
    ) !full_transcript_screen.Projection {
        self.prepareFullTranscriptProjectionLayout();
        return self.buildFullTranscriptProjectionUncached(
            alloc,
            full_diff_resolver,
            self.fullTranscriptAnchorEntryId(),
            null,
        ) catch |err| switch (err) {
            error.InputPending => unreachable,
            else => |other| return other,
        };
    }

    pub fn pollFullTranscriptPageLoad(
        self: *TranscriptRuntime,
    ) !bool {
        const task = self.full_transcript_page_load.takeCompleted() orelse
            return false;
        defer task.deinit();

        const request = task.source.request;
        const desired = self.desiredFullTranscriptPageRequest();
        var installed = false;
        if (task.failure) |failure| {
            if (failure != error.InputPending) {
                debug_trace.logf(
                    "full_transcript_cache",
                    "page_build_failed revision={d} cols={d} err={s}",
                    .{ request.content_revision, request.cols, @errorName(failure) },
                );
            }
        } else if (!task.cancel_requested.load(.acquire) and
            full_transcript_page.sameSurface(desired, request))
        {
            if (task.takeProjection()) |projection| {
                const source = task.takeSource();
                if (self.full_transcript_installed_page) |*page| page.deinit();
                self.full_transcript_installed_page = .{
                    .source = source,
                    .projection = projection,
                };
                installed = true;
            }
        }

        return installed or self.full_transcript.depth == .full;
    }

    pub fn preparedFullTranscriptPageProjectionInterruptible(
        self: *TranscriptRuntime,
        alloc: Allocator,
        full_diff_resolver: ?full_transcript_screen.FullDiffResolver,
        capability: ?*session_child_store.SessionChildCapability,
        checkpoint: ?*build_checkpoint.BuildCheckpoint,
    ) !*full_transcript_screen.Projection {
        try build_checkpoint.poll(checkpoint);
        std.debug.assert(self.full_transcript.depth == .full);

        try self.ensureFullTranscriptPageLoad(capability, full_diff_resolver);
        if (self.installedFullTranscriptPageProjection()) |projection| return projection;
        return try self.fullTranscriptLoadingProjection(alloc);
    }

    fn installedFullTranscriptPageProjection(
        self: *TranscriptRuntime,
    ) ?*full_transcript_screen.Projection {
        const page = if (self.full_transcript_installed_page) |*value| value else return null;
        return if (full_transcript_page.sameSurface(
            self.desiredFullTranscriptPageRequest(),
            page.source.request,
        )) &page.projection else null;
    }

    pub fn preparedFullTranscriptPageCapability(
        self: *TranscriptRuntime,
    ) ?*session_child_store.SessionChildCapability {
        const page = if (self.full_transcript_installed_page) |*value| value else return null;
        return if (page.source.capability) |*capability| capability else null;
    }

    fn desiredFullTranscriptPageRequest(
        self: *const TranscriptRuntime,
    ) full_transcript_page.Request {
        return .{
            .content_revision = self.full_transcript_content_revision,
            .cols = self.layout.cols,
            .anchor = self.full_transcript_page_anchor,
        };
    }

    fn ensureFullTranscriptPageLoad(
        self: *TranscriptRuntime,
        capability: ?*session_child_store.SessionChildCapability,
        full_diff_resolver: ?full_transcript_screen.FullDiffResolver,
    ) !void {
        const request = self.desiredFullTranscriptPageRequest();
        if (self.full_transcript_installed_page) |*page| {
            if (full_transcript_page.sameRequest(request, page.source.request)) return;
        }
        if (self.command_output_display.open_command_block != null) {
            if (self.full_transcript_installed_page) |*page| {
                if (full_transcript_page.sameSurface(request, page.source.request) and
                    !full_transcript_page.liveRefreshDue(
                        page.source.request.content_revision,
                        self.full_transcript_content_revision,
                    )) return;
            }
        }

        if (self.full_transcript_page_load.hasRequest(request)) return;
        if (self.full_transcript_page_load.busy()) {
            if (!self.full_transcript_page_load.hasCompatibleRequest(request)) {
                self.full_transcript_page_load.cancelActive();
            }
            return;
        }
        var source = try self.snapshotFullTranscriptPage(
            request,
            capability,
            full_diff_resolver,
        );
        var source_owned = true;
        errdefer if (source_owned) source.deinit(std.heap.c_allocator);
        try self.full_transcript_page_load.schedule(source);
        source_owned = false;
    }

    fn snapshotFullTranscriptPage(
        self: *const TranscriptRuntime,
        request: full_transcript_page.Request,
        capability: ?*session_child_store.SessionChildCapability,
        full_diff_resolver: ?full_transcript_screen.FullDiffResolver,
    ) !full_transcript_worker.Source {
        const alloc = std.heap.c_allocator;
        const range = full_transcript_page.sourceRange(
            request,
            self.entries.items.len,
        );
        var source = full_transcript_worker.Source{
            .request = request,
            .range = range,
            .styles = self.command_output_render.styles,
        };
        errdefer source.deinit(alloc);
        try source.entries.ensureTotalCapacity(alloc, range.len());
        try source.details.ensureTotalCapacity(alloc, range.len());
        try source.command_blocks.ensureTotalCapacity(
            alloc,
            @min(self.command_output_blocks.items.len, range.len()),
        );
        for (self.entries.items[range.start..range.end]) |entry| {
            source.entries.appendAssumeCapacity(
                try transcript_store.cloneEntryForSnapshot(alloc, entry),
            );
            if (self.toolDetailForEntry(entry.id())) |detail| {
                source.details.appendAssumeCapacity(
                    try transcript_store.cloneToolDetailForSnapshot(
                        alloc,
                        detail.*,
                    ),
                );
            }
        }
        const page_id_bounds = snapshotEntryIdBounds(source.entries.items);
        for (self.command_output_blocks.items) |block| {
            if (!snapshotCommandBlockIntersects(
                source.entries.items,
                page_id_bounds,
                block,
            )) continue;
            const block_index = try appendSnapshotCommandBlock(
                alloc,
                &source,
                block,
            );
            const snapshot_block = &source.command_blocks.items[block_index];
            if (page_id_bounds) |bounds| {
                try appendSnapshotEntryIds(
                    alloc,
                    &snapshot_block.source_entry_ids,
                    block.source_entry_ids.items,
                    bounds,
                );
                try appendSnapshotEntryIds(
                    alloc,
                    &snapshot_block.live_entry_ids,
                    block.live_entry_ids.items,
                    bounds,
                );
            }
            if (block.lifecycle_id) |lifecycle_id| {
                for (self.tool_details.items) |detail| {
                    if (!command_output_runtime.sameLifecycleId(
                        detail.lifecycle_id,
                        lifecycle_id,
                    )) continue;
                    try appendSnapshotToolDetail(alloc, &source, detail);
                    try appendSnapshotToolHeading(alloc, &source, detail);
                    break;
                }
            }
        }
        var detail_index: usize = 0;
        while (detail_index < source.details.items.len) : (detail_index += 1) {
            const detail = source.details.items[detail_index];
            for (self.command_output_blocks.items) |block| {
                const same_output_entry = detail.command_output_entry_id != null and
                    block.entry_id == detail.command_output_entry_id;
                const same_lifecycle = if (detail.lifecycle_id) |lifecycle_id|
                    command_output_runtime.sameLifecycleId(
                        block.lifecycle_id,
                        lifecycle_id,
                    )
                else
                    false;
                if (!same_output_entry and !same_lifecycle) continue;
                _ = try appendSnapshotCommandBlock(alloc, &source, block);
                break;
            }
        }
        if (full_diff_resolver) |resolver| {
            try appendSnapshotFullDiffs(alloc, &source, resolver);
        }
        if (capability) |current| {
            source.capability = try current.cloneReadOnly(alloc);
        }
        debug_trace.logf(
            "full_transcript_cache",
            "page_snapshot revision={d} cols={d} range={d}..{d} entries={d} details={d} blocks={d} diffs={d}",
            .{
                request.content_revision,
                request.cols,
                range.start,
                range.end,
                source.entries.items.len,
                source.details.items.len,
                source.command_blocks.items.len,
                source.full_diffs.items.len,
            },
        );
        return source;
    }

    fn appendSnapshotFullDiffs(
        alloc: Allocator,
        source: *full_transcript_worker.Source,
        resolver: full_transcript_screen.FullDiffResolver,
    ) !void {
        for (source.entries.items) |entry| {
            const raw = switch (entry) {
                .raw_bytes => |value| value,
                else => continue,
            };
            if (raw.class != .diff_block) continue;
            const marker_id = diff_mod.markedDiffBlockId(raw.bytes) orelse continue;
            var duplicate = false;
            for (source.full_diffs.items) |existing| {
                if (existing.marker_id == marker_id) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            const content = resolver.full_for_marker(
                resolver.context,
                marker_id,
            ) orelse continue;
            try source.appendFullDiff(alloc, marker_id, content);
        }

        for (source.details.items) |detail| {
            const lifecycle_id = detail.lifecycle_id orelse continue;
            if (!resolver.has_full_for_lifecycle(
                resolver.context,
                lifecycle_id,
            )) continue;
            var duplicate = false;
            for (source.full_diff_lifecycles.items) |existing| {
                if (command_output_runtime.sameLifecycleId(
                    existing,
                    lifecycle_id,
                )) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            try source.appendFullDiffLifecycle(alloc, lifecycle_id);
        }
    }

    fn snapshotContainsEntry(
        entries: []const TranscriptEntry,
        entry_id: u32,
    ) bool {
        for (entries) |entry| {
            if (entry.id() == entry_id) return true;
        }
        return false;
    }

    const SnapshotEntryIdBounds = struct {
        min: u32,
        max: u32,
    };

    fn snapshotEntryIdBounds(
        entries: []const TranscriptEntry,
    ) ?SnapshotEntryIdBounds {
        if (entries.len == 0) return null;
        var bounds = SnapshotEntryIdBounds{
            .min = entries[0].id(),
            .max = entries[0].id(),
        };
        for (entries[1..]) |entry| {
            bounds.min = @min(bounds.min, entry.id());
            bounds.max = @max(bounds.max, entry.id());
        }
        return bounds;
    }

    fn snapshotCommandBlockIntersects(
        entries: []const TranscriptEntry,
        bounds: ?SnapshotEntryIdBounds,
        block: CommandOutputBlock,
    ) bool {
        if (block.entry_id) |entry_id| {
            if (snapshotContainsEntry(entries, entry_id)) return true;
        }
        const page_bounds = bounds orelse return false;
        return sortedEntryIdsIntersect(block.source_entry_ids.items, page_bounds) or
            sortedEntryIdsIntersect(block.live_entry_ids.items, page_bounds);
    }

    fn sortedEntryIdsIntersect(
        ids: []const u32,
        bounds: SnapshotEntryIdBounds,
    ) bool {
        var low: usize = 0;
        var high = ids.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (ids[middle] < bounds.min) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low < ids.len and ids[low] <= bounds.max;
    }

    fn appendSnapshotEntryIds(
        alloc: Allocator,
        destination: *std.ArrayList(u32),
        ids: []const u32,
        bounds: SnapshotEntryIdBounds,
    ) !void {
        var low: usize = 0;
        var high = ids.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (ids[middle] < bounds.min) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        var index = low;
        while (index < ids.len and ids[index] <= bounds.max) : (index += 1) {
            try destination.append(alloc, ids[index]);
        }
    }

    fn appendSnapshotToolDetail(
        alloc: Allocator,
        source: *full_transcript_worker.Source,
        detail: ToolDetailRecord,
    ) !void {
        for (source.details.items) |existing| {
            if (existing.entry_id == detail.entry_id) return;
        }
        try source.details.append(
            alloc,
            try transcript_store.cloneToolDetailForSnapshot(alloc, detail),
        );
    }

    fn appendSnapshotToolHeading(
        alloc: Allocator,
        source: *full_transcript_worker.Source,
        detail: ToolDetailRecord,
    ) !void {
        if (snapshotContainsEntry(source.entries.items, detail.entry_id)) return;
        const bytes = try std.fmt.allocPrint(
            alloc,
            "● {s}\n",
            .{detail.tool_name},
        );
        errdefer alloc.free(bytes);
        var created_at_ms: i64 = 0;
        for (source.entries.items) |entry| {
            if (entry.createdAtMs() <= 0) continue;
            created_at_ms = entry.createdAtMs();
            break;
        }
        try source.entries.insert(alloc, 0, .{ .raw_bytes = .{
            .id = detail.entry_id,
            .created_at_ms = created_at_ms,
            .bytes = bytes,
            .class = .tool_status,
        } });
    }

    fn appendSnapshotCommandBlock(
        alloc: Allocator,
        source: *full_transcript_worker.Source,
        block: CommandOutputBlock,
    ) !usize {
        for (source.command_blocks.items, 0..) |existing, index| {
            if (existing.entry_id == block.entry_id and
                command_output_runtime.sameLifecycleId(
                    existing.lifecycle_id,
                    block.lifecycle_id,
                )) return index;
        }
        try source.command_blocks.append(
            alloc,
            try full_transcript_worker.cloneCommandBlockForPageSnapshot(alloc, block),
        );
        return source.command_blocks.items.len - 1;
    }

    fn fullTranscriptLoadingProjection(
        self: *TranscriptRuntime,
        alloc: Allocator,
    ) !*full_transcript_screen.Projection {
        if (self.full_transcript_loading_projection == null) {
            const entries = [_]TranscriptEntry{.{ .raw_bytes = .{
                .id = 0,
                .bytes = "Preparing full detail…\n",
                .class = .unknown_raw,
            } }};
            self.full_transcript_loading_projection = try full_transcript_screen.buildProjection(
                alloc,
                &entries,
                &.{},
                &.{},
                self.command_output_render.styles,
                self.layout.cols,
                null,
            );
        }
        return &self.full_transcript_loading_projection.?;
    }

    fn prepareFullTranscriptProjectionLayout(self: *TranscriptRuntime) void {
        self.full_transcript = self.full_transcript.prepare_projection(
            self.layout.cols,
        );
    }

    fn buildFullTranscriptProjectionUncached(
        self: *TranscriptRuntime,
        alloc: Allocator,
        full_diff_resolver: ?full_transcript_screen.FullDiffResolver,
        anchor_entry_id: ?u32,
        checkpoint: ?*build_checkpoint.BuildCheckpoint,
    ) !full_transcript_screen.Projection {
        return self.buildFullTranscriptProjectionUncachedFrom(
            alloc,
            full_diff_resolver,
            anchor_entry_id,
            0,
            checkpoint,
        );
    }

    fn buildFullTranscriptProjectionUncachedFrom(
        self: *TranscriptRuntime,
        alloc: Allocator,
        full_diff_resolver: ?full_transcript_screen.FullDiffResolver,
        anchor_entry_id: ?u32,
        start_index: usize,
        checkpoint: ?*build_checkpoint.BuildCheckpoint,
    ) !full_transcript_screen.Projection {
        var relationships = try tool_group_projection.buildExpandedRelationshipsInterruptible(
            alloc,
            self.entries.items,
            self.tool_details.items,
            checkpoint,
        );
        defer relationships.deinit(alloc);
        var entry_actions = try tool_group_projection.materializeExpandedRelationshipsRangeInterruptible(
            alloc,
            &relationships,
            start_index,
            self.layout.cols,
            .{
                .marker_style = user_message_card.promptMarkerStyle(),
                .text_style = ui_render.statusline_style,
                .reset_style = "\x1b[0m",
            },
            checkpoint,
        );
        defer entry_actions.deinit(alloc);
        return full_transcript_screen.buildProjectionWithEntryActionsInterruptible(
            alloc,
            self.entries.items[start_index..],
            self.tool_details.items,
            self.command_output_blocks.items,
            self.command_output_render.styles,
            self.layout.cols,
            anchor_entry_id,
            full_diff_resolver,
            entry_actions.entry_actions.items,
            checkpoint,
        );
    }

    pub noinline fn prepareFullTranscriptSurfacePaint(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        projection: *full_transcript_screen.Projection,
        capability: ?*session_child_store.SessionChildCapability,
        area: render_engine.frame_layout.FrameRect,
    ) !FullTranscriptSurfacePaint {
        return self.prepareFullTranscriptSurfacePaintInterruptible(
            alloc,
            metrics,
            projection,
            capability,
            area,
            null,
        ) catch |err| switch (err) {
            error.InputPending => unreachable,
            else => |other| return other,
        };
    }

    pub noinline fn prepareFullTranscriptSurfacePaintInterruptible(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        projection: *full_transcript_screen.Projection,
        capability: ?*session_child_store.SessionChildCapability,
        area: render_engine.frame_layout.FrameRect,
        checkpoint: ?*build_checkpoint.BuildCheckpoint,
    ) !FullTranscriptSurfacePaint {
        const source_bytes = if (self.fullTranscriptProjectionIsLoading(projection))
            try full_transcript_screen.renderProjectionViewportSourceInterruptible(
                alloc,
                projection,
                capability,
                self.layout.cols,
                area.height(),
                0,
                checkpoint,
            )
        else
            try full_transcript_screen.renderProjectionViewportSourceWithSelectorInterruptible(
                alloc,
                projection,
                capability,
                self.layout.cols,
                area.height(),
                .{ .context = self, .select_offset = selectProjectionViewportOffset },
                checkpoint,
            );
        var source = try self.prepareFullTranscriptViewportSource(alloc, source_bytes);
        errdefer source.deinit(alloc);
        const prepared = try transcript_painter.preparePreselectedTranscriptSurfacePaintFromSourceForArea(
            self,
            alloc,
            metrics,
            &source,
            area,
        );
        return .{ .source = source, .prepared = prepared };
    }

    fn fullTranscriptProjectionIsLoading(
        self: *TranscriptRuntime,
        projection: *const full_transcript_screen.Projection,
    ) bool {
        const loading = if (self.full_transcript_loading_projection) |*value|
            value
        else
            return false;
        return loading == projection;
    }

    fn selectProjectionViewportOffset(
        context: *anyopaque,
        measurement: full_transcript_screen.ProjectionMeasurement,
        visible_rows: u16,
    ) u32 {
        const self: *TranscriptRuntime = @ptrCast(@alignCast(context));
        const selection = self.full_transcript.select_visual_offset(
            measurement.total_rows,
            visible_rows,
            measurement.item_rows,
        );
        self.full_transcript = selection.state;
        return selection.offset;
    }

    pub fn prepareTranscriptSurfacePaintFromSourceForArea(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        source: *const TranscriptPreparationSource,
        area: render_engine.frame_layout.FrameRect,
    ) !transcript_painter.PreparedTranscriptSurfacePaint {
        return self.prepareTranscriptSurfacePaintFromSourceForFrame(
            alloc,
            metrics,
            source,
            area,
            false,
        );
    }

    pub fn prepareTranscriptSurfacePaintFromSourceForFrame(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        source: *const TranscriptPreparationSource,
        area: render_engine.frame_layout.FrameRect,
        footer_reservation_changed: bool,
    ) !transcript_painter.PreparedTranscriptSurfacePaint {
        return transcript_painter.prepareTranscriptSurfacePaintFromSourceForFrame(
            self,
            alloc,
            metrics,
            source,
            area,
            footer_reservation_changed,
        );
    }

    pub fn prepareTranscriptSurfacePaintForArea(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        area: render_engine.frame_layout.FrameRect,
    ) !transcript_painter.PreparedTranscriptSurfacePaint {
        return transcript_painter.prepareTranscriptSurfacePaintForArea(self, alloc, metrics, area);
    }

    pub fn prepareTranscriptSurfacePaintForAreaTrackingEntry(
        self: *TranscriptRuntime,
        alloc: Allocator,
        metrics: *Metrics,
        area: render_engine.frame_layout.FrameRect,
        entry_id: ?u32,
    ) !transcript_painter.PreparedTranscriptSurfacePaint {
        return transcript_painter.prepareTranscriptSurfacePaintForAreaTrackingEntry(
            self,
            alloc,
            metrics,
            area,
            entry_id,
        );
    }

    pub fn previewTranscriptFlow(
        self: *TranscriptRuntime,
        alloc: Allocator,
    ) !render_engine.frame_layout.TranscriptFlowPreview {
        return transcript_painter.previewTranscriptFlow(self, alloc);
    }

    pub fn paintPreparedTranscriptIntoSurface(
        self: *TranscriptRuntime,
        alloc: Allocator,
        surface: *render_engine.frame_surface.FrameSurface,
        prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
    ) !render_engine.paint_plan.TranscriptPaintResult {
        return transcript_painter.paintPreparedTranscriptIntoSurface(self, alloc, surface, prepared);
    }

    pub fn markTranscriptDirty(self: *TranscriptRuntime) void {
        self.transcript_band_dirty = true;
        self.render_requests.request(.transcript);
    }

    fn markTranscriptContentPaint(self: *TranscriptRuntime) void {
        self.transcript_band_dirty = true;
        if (self.deferLiveFullTranscriptRefresh()) return;
        self.render_requests.request(.transcript);
    }

    fn deferLiveFullTranscriptRefresh(self: *const TranscriptRuntime) bool {
        if (self.full_transcript.depth != .full or
            self.command_output_display.open_command_block == null)
        {
            return false;
        }
        if (self.full_transcript_page_load.busy()) return true;
        const page = if (self.full_transcript_installed_page) |*value| value else return false;
        if (page.source.request.cols != self.layout.cols or
            !std.meta.eql(page.source.request.anchor, self.full_transcript_page_anchor))
        {
            return false;
        }
        return !full_transcript_page.liveRefreshDue(
            page.source.request.content_revision,
            self.full_transcript_content_revision,
        );
    }

    pub fn nativeHistoryActive(self: *const TranscriptRuntime) bool {
        return switch (self.transcript_commit_state) {
            .invalid => false,
            .stable => |anchor| anchor.history_visual_offset > 0,
            .recovering => |receipt| receipt.accepted_history_visual_offset > 0,
        };
    }

    pub fn markTranscriptContentDirty(self: *TranscriptRuntime) void {
        self.full_transcript_content_revision +%= 1;
        debug_trace.logf(
            "full_transcript_cache",
            "content_dirty content_revision={d} command_open={s}",
            .{
                self.full_transcript_content_revision,
                if (self.command_output_display.open_command_block == null) "false" else "true",
            },
        );
        self.markTranscriptContentPaint();
    }

    pub fn markTranscriptStructureDirty(self: *TranscriptRuntime) void {
        self.full_transcript_content_revision +%= 1;
        debug_trace.logf(
            "full_transcript_cache",
            "structure_dirty content_revision={d}",
            .{self.full_transcript_content_revision},
        );
        self.markTranscriptDirty();
    }

    pub fn markTranscriptContentDirtyFrom(
        self: *TranscriptRuntime,
        entry_id: u32,
    ) void {
        self.full_transcript_content_revision +%= 1;
        debug_trace.logf(
            "full_transcript_cache",
            "content_dirty_from entry_id={d} content_revision={d} command_open={s}",
            .{
                entry_id,
                self.full_transcript_content_revision,
                if (self.command_output_display.open_command_block == null) "false" else "true",
            },
        );
        self.markTranscriptContentPaint();
    }

    pub fn markTranscriptCommandOutputDirty(self: *TranscriptRuntime) void {
        self.full_transcript_content_revision +%= 1;
        debug_trace.logf(
            "full_transcript_cache",
            "command_output_dirty content_revision={d}",
            .{self.full_transcript_content_revision},
        );
        self.markTranscriptContentPaint();
    }

    pub fn markTranscriptCommandOutputDirtyFrom(
        self: *TranscriptRuntime,
        entry_id: u32,
    ) void {
        self.full_transcript_content_revision +%= 1;
        debug_trace.logf(
            "full_transcript_cache",
            "command_output_dirty_from entry_id={d} content_revision={d}",
            .{
                entry_id,
                self.full_transcript_content_revision,
            },
        );
        self.markTranscriptContentPaint();
    }

    pub fn recordFrameInvalidation(
        shell: *TranscriptRuntime,
        range: render_engine.paint_plan.FrameInvalidationRange,
    ) !void {
        if (range.top == 0 or range.bottom == 0 or range.bottom < range.top) {
            return error.InvalidFrameInvalidationRange;
        }

        const request_invalidations = shell.render_requests.pendingInvalidations();
        if (request_invalidations.len >= render_engine.paint_plan.max_frame_invalidation_ranges) {
            var collapsed = request_invalidations.collapsedWith(range);
            const bottom = if (shell.layout.rows == 0) range.bottom else shell.layout.rows;
            var top = if (shell.owned_top_row == 0) @as(u16, 1) else shell.owned_top_row;
            if (bottom == 0) {
                top = range.top;
            } else if (top > bottom) {
                top = 1;
            }
            collapsed.top = top;
            collapsed.bottom = bottom;
            debug_trace.logf(
                "frame_plan",
                "collapse_pending_invalidations count={d} incoming_reason={s} collapsed_reason={s} top={d} bottom={d}",
                .{
                    request_invalidations.len,
                    @tagName(range.reason),
                    @tagName(collapsed.reason),
                    collapsed.top,
                    collapsed.bottom,
                },
            );
            shell.render_requests.replacePendingInvalidation(collapsed);
        } else {
            shell.render_requests.requestInvalidation(range);
        }
    }

    pub fn normalizeFrameInvalidations(
        shell: *const TranscriptRuntime,
        pending: *render_engine.paint_plan.FrameInvalidationSet,
    ) void {
        if (shell.layout.rows == 0) return;
        var i: usize = 0;
        while (i < pending.len) : (i += 1) {
            const range = &pending.items[i];
            if (range.bottom <= shell.layout.rows and range.top <= range.bottom) continue;
            range.top = if (shell.owned_top_row == 0 or shell.owned_top_row > shell.layout.rows) 1 else shell.owned_top_row;
            range.bottom = shell.layout.rows;
        }
    }

    /// Updates the capped terminal cursor and returns the uncapped text walk.
    /// Scroll calculations must use `result.end_row`, not `self.cursor_row`,
    /// which cannot represent overflow below the viewport. Wrap-exact walks may
    /// return `layout.cols + 1` in `end_col`.
    pub fn advanceCursor(self: *TranscriptRuntime, text: []const u8) WalkResult {
        const result = walkText(@as(u32, self.cursor_row), self.cursor_col, text, self.layout.cols);
        self.cursor_col = result.end_col;
        self.cursor_row = @intCast(@min(result.end_row, @as(u32, self.layout.rows)));
        return result;
    }

    pub fn updateExtraInputRows(self: *TranscriptRuntime, alloc: Allocator, metrics: *Metrics, new_extra: u16) !void {
        _ = alloc;
        _ = metrics;
        if (new_extra == self.extra_input_rows) return;
        const old_extra = self.extra_input_rows;
        self.extra_input_rows = new_extra;
        self.markTranscriptDirty();
        self.footer_viewport.invalidateAfterExternalClear();

        if (self.layout.rows > 0) {
            const top = if (self.owned_top_row == 0 or self.owned_top_row > self.layout.rows)
                @as(u16, 1)
            else
                self.owned_top_row;
            try self.recordFrameInvalidation(.{
                .reason = .external_clear,
                .top = top,
                .bottom = self.layout.rows,
            });
        }
        debug_trace.logf(
            "frame_plan",
            "footer_extra_update_frame_deferred old={d} new={d} owned_top={d} rows={d}",
            .{ old_extra, new_extra, self.owned_top_row, self.layout.rows },
        );
    }

    pub fn resetCursorTracking(self: *TranscriptRuntime) void {
        self.cursor_row = 1;
        self.cursor_col = 1;
    }
};

test "transcript runtime initializer preserves an empty compact source cache" {
    var runtime = TranscriptRuntime.init();
    defer runtime.deinit(std.testing.allocator);

    for (runtime.compact_transcript_source_cache.entries) |entry| {
        try std.testing.expect(entry == null);
    }
    try std.testing.expectEqual(
        @as(usize, 0),
        runtime.compact_transcript_source_cache.next_replacement,
    );
}

fn frameBandsEqual(a: render_engine.paint_plan.FrameBand, b: render_engine.paint_plan.FrameBand) bool {
    return a.top == b.top and a.bottom == b.bottom and a.owner == b.owner;
}

fn totalVisualRows(line_rows: []const u16) u32 {
    var total: u32 = 0;
    for (line_rows) |rows| {
        total += rows;
    }
    return total;
}

const AcceptedTranscriptRows = struct {
    resize_reflow_rows: u16,
    semantic_rows: u32,
    semantic_progress_rows: u32,
};

const TranscriptTransitionCommit = struct {
    accepted: AcceptedTranscriptRows,
    remaining_resize_reflow_rows: u16,
    remaining_semantic_rows: u32,
    remaining_semantic_progress_rows: u32,
    remaining_unplanned_scroll_rows: u16,
    complete: bool,
    stable: bool,
    committed_measured_history_origin: ?transcript_painter.MeasuredHistoryOrigin,
};

const TranscriptRecoveryCommit = struct {
    accepted_visual_offset: u32,
    accepted_history_visual_offset: u32,
    materialized_visual_offset: u32,
    materialized_visual_rows: u16,
    materialized_flow_len: ?usize,
    materialized_cursor_row: u16,
    materialized_cursor_col: u16,
    document_append_committed: bool,
};

fn resolveRecoveryMaterializedEndpoint(
    transition: *const TranscriptTransition,
    result: render_engine.terminal_diff.FrameCommitResult,
    commit: TranscriptTransitionCommit,
) MaterializedEndpoint {
    const planned = transition.materialized;
    if (commit.complete or
        result.document_append_applied() or
        !transition.recovery_progress_compatible or
        !transition.recovery_tracks_semantic_progress or
        transition.recovery_rebase)
    {
        return planned;
    }
    return transition.materialized_without_append;
}

fn resolveTranscriptTransitionCommit(
    transition: *const TranscriptTransition,
    result: render_engine.terminal_diff.FrameCommitResult,
    scroll_commit: render_engine.frame_scroll_plan.FrameScrollCommit,
) TranscriptTransitionCommit {
    const accepted = acceptedTranscriptRowsForInlineRows(
        scroll_commit.accepted_rows.inline_advance_rows,
        transition.resize_reflow_rows,
        transition.semantic_rows,
        transition.semantic_progress_rows,
    );
    const remaining_resize_reflow_rows =
        transition.resize_reflow_rows - accepted.resize_reflow_rows;
    const remaining_semantic_rows =
        transition.semantic_rows - accepted.semantic_rows;
    const remaining_semantic_progress_rows =
        transition.semantic_progress_rows - accepted.semantic_progress_rows;
    const remaining_unplanned_scroll_rows = scroll_commit.unplanned_terminal_scroll_rows;
    const complete = result.is_committed() and scroll_commit.complete();
    return .{
        .accepted = accepted,
        .remaining_resize_reflow_rows = remaining_resize_reflow_rows,
        .remaining_semantic_rows = remaining_semantic_rows,
        .remaining_semantic_progress_rows = remaining_semantic_progress_rows,
        .remaining_unplanned_scroll_rows = remaining_unplanned_scroll_rows,
        .complete = complete,
        .stable = complete and
            !transition.recovery_projection_deferred and
            remaining_resize_reflow_rows == 0 and
            remaining_semantic_rows == 0 and
            remaining_unplanned_scroll_rows == 0,
        .committed_measured_history_origin = transcript_painter.advanceMeasuredHistoryOriginForCommittedRows(
            transition.target_flow,
            transition.measured_history_origin,
            transition.target_layout.terminal_cols,
            accepted.resize_reflow_rows,
        ),
    };
}

fn resolveTranscriptRecoveryCommit(
    runtime: *const TranscriptRuntime,
    transition: *const TranscriptTransition,
    result: render_engine.terminal_diff.FrameCommitResult,
    commit: TranscriptTransitionCommit,
) TranscriptRecoveryCommit {
    const source_offset = switch (runtime.transcript_commit_state) {
        .stable => |anchor| anchor.visual_offset,
        .recovering => |receipt| receipt.accepted_visual_offset,
        .invalid => 0,
    };
    const source_history_offset = switch (runtime.transcript_commit_state) {
        .stable => |anchor| anchor.history_visual_offset,
        .recovering => |receipt| receipt.accepted_history_visual_offset,
        .invalid => 0,
    };
    const projection_base_offset = if (transition.recovery_rebase and
        !transition.recovery_progress_compatible)
        transition.visual_offset
    else
        source_offset;
    const accepted_visual_offset =
        projection_base_offset + commit.accepted.semantic_progress_rows;
    const materialized = resolveRecoveryMaterializedEndpoint(transition, result, commit);
    return .{
        .accepted_visual_offset = accepted_visual_offset,
        .accepted_history_visual_offset = @min(
            transition.total_visual_rows,
            source_history_offset +| commit.accepted.semantic_rows,
        ),
        .materialized_visual_offset = materialized.visual_offset,
        .materialized_visual_rows = materialized.visual_rows,
        .materialized_flow_len = materialized.flow_len,
        .materialized_cursor_row = materialized.cursor_row,
        .materialized_cursor_col = materialized.cursor_col,
        .document_append_committed = transition.recovery_tracks_semantic_progress and
            materialized.visual_offset > accepted_visual_offset,
    };
}

test "resume view snapshot captures visible transcript styling" {
    const alloc = std.testing.allocator;
    var runtime: TranscriptRuntime = .{};
    defer runtime.deinit(alloc);
    runtime.layout = .{
        .rows = 6,
        .cols = 12,
        .content_bottom = 3,
        .divider_top_row = 4,
        .input_row = 5,
        .divider_bottom_row = 5,
        .hint_row = 6,
    };
    try runtime.enableShadowVt(alloc);
    try runtime.shadow_vt.?.feed(
        "\x1b[1;1Hnot cached\x1b[2;1H" ++
            "\x1b]8;;https://example.com\x1b\\" ++
            "\x1b[1;3;38;2;1;2;3m\x1b[48;5;245mvisible one\x1b[0m" ++
            "\x1b]8;;\x1b\\\x1b[3;1H\x1b[31mvisible two\x1b[0m" ++
            "\x1b[4;1Hfooter",
    );
    runtime.has_painted_transcript = true;
    runtime.last_visible_transcript_top_row = 2;
    runtime.last_visible_transcript_last_row = 3;

    var snapshot = (try runtime.snapshotVisibleTranscriptText(alloc, 128)).?;
    defer snapshot.deinit(alloc);
    try std.testing.expect(snapshot.complete);
    try std.testing.expectEqual(@as(u16, 6), snapshot.terminal_rows);
    try std.testing.expectEqual(@as(u16, 12), snapshot.terminal_cols);
    try std.testing.expectEqualStrings(
        "\x1b[0m\x1b[1m\x1b[3m\x1b[38;2;1;2;3m" ++
            "\x1b[48;5;245mvisible one\x1b[0m\n" ++
            "\x1b[0m\x1b[31mvisible two\x1b[0m\n",
        snapshot.text,
    );
}

test "resume view snapshot preserves the committed footer gap" {
    const alloc = std.testing.allocator;
    var runtime: TranscriptRuntime = .{};
    defer runtime.deinit(alloc);
    runtime.layout.rows = 6;
    runtime.layout.cols = 12;
    runtime.committed_frame_layout.footer_area = .{ .top = 4, .bottom = 6 };
    try runtime.enableShadowVt(alloc);
    try runtime.shadow_vt.?.feed("\x1b[1;1Hvisible");
    runtime.has_painted_transcript = true;
    runtime.last_visible_transcript_top_row = 1;
    runtime.last_visible_transcript_last_row = 1;

    var snapshot = (try runtime.snapshotVisibleTranscriptText(alloc, 128)).?;
    defer snapshot.deinit(alloc);
    try std.testing.expect(snapshot.complete);
    try std.testing.expectEqualStrings("visible\n\n\n", snapshot.text);
}

test "resume view snapshot omits a visible leading welcome entry" {
    const alloc = std.testing.allocator;
    var runtime: TranscriptRuntime = .{};
    defer runtime.deinit(alloc);
    runtime.layout = .{
        .rows = 6,
        .cols = 40,
        .content_bottom = 4,
        .divider_top_row = 5,
        .input_row = 6,
        .divider_bottom_row = 6,
        .hint_row = 6,
    };
    var metrics: Metrics = .{};
    try runtime.writeTranscriptClassified(
        alloc,
        &metrics,
        "fx · Run /help for commands\n\n",
        true,
        .welcome,
    );
    try runtime.enableShadowVt(alloc);
    try runtime.shadow_vt.?.feed(
        "\x1b[1;1Hfx · Run /help for commands" ++
            "\x1b[3;1Hvisible one\x1b[4;1Hvisible two",
    );
    runtime.has_painted_transcript = true;
    runtime.last_visible_transcript_top_row = 1;
    runtime.last_visible_transcript_last_row = 4;
    runtime.last_viewport_selection = .{
        .top_row = 1,
        .bottom_row = 4,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = 4,
    };

    var snapshot = (try runtime.snapshotVisibleTranscriptText(alloc, 128)).?;
    defer snapshot.deinit(alloc);
    try std.testing.expect(snapshot.complete);
    try std.testing.expectEqualStrings("visible one\nvisible two\n", snapshot.text);
}

test "resume view snapshot keeps one complete UTF-8 row at the byte limit" {
    const alloc = std.testing.allocator;
    var runtime: TranscriptRuntime = .{};
    defer runtime.deinit(alloc);
    runtime.layout.rows = 6;
    runtime.layout.cols = 12;
    try runtime.enableShadowVt(alloc);
    try runtime.shadow_vt.?.feed("\x1b[1;1Hééé");
    runtime.has_painted_transcript = true;
    runtime.last_visible_transcript_top_row = 1;
    runtime.last_visible_transcript_last_row = 1;

    var snapshot = (try runtime.snapshotVisibleTranscriptText(alloc, 7)).?;
    defer snapshot.deinit(alloc);
    try std.testing.expect(snapshot.complete);
    try std.testing.expectEqualStrings("ééé\n", snapshot.text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(snapshot.text));
}

test "resume view snapshot drops oldest rows and retains the newest tail" {
    const alloc = std.testing.allocator;
    var runtime: TranscriptRuntime = .{};
    defer runtime.deinit(alloc);
    runtime.layout.rows = 6;
    runtime.layout.cols = 12;
    try runtime.enableShadowVt(alloc);
    try runtime.shadow_vt.?.feed(
        "\x1b[1;1Holdest\x1b[2;1Høø\x1b[3;1HTAIL",
    );
    runtime.has_painted_transcript = true;
    runtime.last_visible_transcript_top_row = 1;
    runtime.last_visible_transcript_last_row = 3;

    var snapshot = (try runtime.snapshotVisibleTranscriptText(alloc, 10)).?;
    defer snapshot.deinit(alloc);
    try std.testing.expect(!snapshot.complete);
    try std.testing.expectEqualStrings("øø\nTAIL\n", snapshot.text);
}

test "resume view snapshot returns no text for empty visible rows" {
    const alloc = std.testing.allocator;
    var runtime: TranscriptRuntime = .{};
    defer runtime.deinit(alloc);
    runtime.layout.rows = 6;
    runtime.layout.cols = 12;
    try runtime.enableShadowVt(alloc);
    runtime.has_painted_transcript = true;
    runtime.last_visible_transcript_top_row = 1;
    runtime.last_visible_transcript_last_row = 2;

    try std.testing.expect(
        try runtime.snapshotVisibleTranscriptText(alloc, 128) == null,
    );
}

fn acceptedTranscriptRows(
    scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
    committed_terminal_scroll_rows: u16,
    resize_reflow_rows: u16,
    semantic_rows: u32,
    semantic_progress_rows: u32,
) AcceptedTranscriptRows {
    const accepted_scroll_rows = scroll_plan.commit(committed_terminal_scroll_rows).accepted_rows;
    return acceptedTranscriptRowsForInlineRows(
        accepted_scroll_rows.inline_advance_rows,
        resize_reflow_rows,
        semantic_rows,
        semantic_progress_rows,
    );
}

fn acceptedTranscriptRowsForInlineRows(
    accepted_inline_rows: u32,
    resize_reflow_rows: u16,
    semantic_rows: u32,
    semantic_progress_rows: u32,
) AcceptedTranscriptRows {
    const accepted_resize_reflow_rows: u16 = @intCast(@min(
        accepted_inline_rows,
        @as(u32, resize_reflow_rows),
    ));
    const accepted_semantic_rows = @min(
        accepted_inline_rows - @as(u32, accepted_resize_reflow_rows),
        semantic_rows,
    );
    std.debug.assert(semantic_progress_rows <= semantic_rows);
    const unprojected_semantic_rows = semantic_rows - semantic_progress_rows;
    const accepted_unprojected_semantic_rows = @min(
        accepted_semantic_rows,
        unprojected_semantic_rows,
    );
    return .{
        .resize_reflow_rows = accepted_resize_reflow_rows,
        .semantic_rows = accepted_semantic_rows,
        .semantic_progress_rows = accepted_semantic_rows - accepted_unprojected_semantic_rows,
    };
}

fn resolveAndSealTranscriptTransitionForRuntimeTest(
    runtime: *TranscriptRuntime,
    alloc: Allocator,
    source: *TranscriptPreparationSource,
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
    target_layout: render_engine.frame_layout.CommittedLayoutSnapshot,
    plan: *render_engine.paint_plan.PaintPlan,
    scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
) !TranscriptTransition {
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

fn testFrameCommitResult(
    committed_rows: u16,
    shadow_state: render_engine.terminal_diff.ShadowCommitState,
) render_engine.terminal_diff.FrameCommitResult {
    return .{
        .bytes_written = 1,
        .changed_cells = 1,
        .full_repaint = false,
        .terminal_scroll_rows_committed = committed_rows,
        .document_append_committed = false,
        .committed_cursor_row = 1,
        .committed_cursor_col = 1,
        .shadow_state = shadow_state,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    };
}

test "transition commit snapshot derives accepted rows and stable state from frame result" {
    const scroll_plan = render_engine.frame_scroll_plan.merge(8, 1, 0, 2);
    var transition = TranscriptTransition{
        .scroll_plan = scroll_plan,
        .document_append = .{},
        .materialized_without_append = .{},
        .resize_reflow_rows = 1,
        .semantic_rows = 1,
        .semantic_progress_rows = 1,
        .target_flow = &.{},
        .target_cache = .empty,
        .folded_summary_indices = &.{},
        .target_layout = .{
            .terminal_rows = 8,
            .terminal_cols = 40,
        },
        .selection = .{
            .top_row = 1,
            .bottom_row = 4,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
        },
        .visual_offset = 0,
        .history_visual_offset = 0,
        .total_visual_rows = 2,
        .cursor_row = 4,
        .cursor_col = 1,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 4,
        .trace_transcript_frame = false,
        .trace_visible_rows = 4,
    };

    const partial_result = testFrameCommitResult(1, .terminal_partial_write);
    const partial = resolveTranscriptTransitionCommit(
        &transition,
        partial_result,
        scroll_plan.commit(partial_result.terminal_scroll_rows_committed),
    );
    try std.testing.expectEqual(@as(u16, 1), partial.accepted.resize_reflow_rows);
    try std.testing.expectEqual(@as(u32, 0), partial.accepted.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), partial.remaining_resize_reflow_rows);
    try std.testing.expectEqual(@as(u32, 1), partial.remaining_semantic_rows);
    try std.testing.expect(!partial.complete);
    try std.testing.expect(!partial.stable);

    const complete_result = testFrameCommitResult(2, .committed);
    const complete = resolveTranscriptTransitionCommit(
        &transition,
        complete_result,
        scroll_plan.commit(complete_result.terminal_scroll_rows_committed),
    );
    try std.testing.expectEqual(@as(u16, 1), complete.accepted.resize_reflow_rows);
    try std.testing.expectEqual(@as(u32, 1), complete.accepted.semantic_rows);
    try std.testing.expectEqual(@as(u32, 1), complete.accepted.semantic_progress_rows);
    try std.testing.expectEqual(@as(u16, 0), complete.remaining_resize_reflow_rows);
    try std.testing.expectEqual(@as(u32, 0), complete.remaining_semantic_rows);
    try std.testing.expect(complete.complete);
    try std.testing.expect(complete.stable);

    transition.recovery_projection_deferred = true;
    const deferred_result = testFrameCommitResult(2, .committed);
    const deferred = resolveTranscriptTransitionCommit(
        &transition,
        deferred_result,
        scroll_plan.commit(deferred_result.terminal_scroll_rows_committed),
    );
    try std.testing.expect(deferred.complete);
    try std.testing.expect(!deferred.stable);
}

test "resume recovery selects a safe materialized endpoint for every outcome" {
    var target_flow = [_]u8{ 'f', 'i', 'r', 's', 't', '\n', 's', 'e', 'c', 'o', 'n', 'd' };
    const scroll_plan = render_engine.frame_scroll_plan.merge(8, 1, 0, 1);
    var runtime = TranscriptRuntime{
        .layout = testLayoutWithRows(8),
        .committed_frame_layout = .{
            .terminal_rows = 8,
            .terminal_cols = 80,
            .transcript_area = .{ .top = 1, .bottom = 8 },
        },
    };
    defer runtime.deinit(std.testing.allocator);
    const document_append: render_engine.frame_scroll_plan.FrameDocumentAppend = .{
        .bytes = "first\n",
        .start_row = 2,
        .start_col = 3,
    };
    const planned: MaterializedEndpoint = .{
        .visual_offset = 1,
        .visual_rows = 1,
        .flow_len = 6,
        .cursor_row = 3,
        .cursor_col = 1,
    };
    var transition = TranscriptTransition{
        .scroll_plan = scroll_plan,
        .document_append = document_append,
        .semantic_rows = 2,
        .semantic_progress_rows = 2,
        .recovery_progress_compatible = true,
        .recovery_tracks_semantic_progress = true,
        .target_flow = &target_flow,
        .target_cache = .empty,
        .folded_summary_indices = &.{},
        .target_layout = .{
            .terminal_rows = 8,
            .terminal_cols = 80,
        },
        .selection = .{
            .top_row = 1,
            .bottom_row = 8,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 2,
        },
        .visual_offset = 1,
        .history_visual_offset = 1,
        .total_visual_rows = 2,
        .materialized = planned,
        .materialized_without_append = runtime.materializedEndpointWithoutAppend(
            document_append,
            planned,
        ),
        .cursor_row = 3,
        .cursor_col = 1,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 3,
        .trace_transcript_frame = false,
        .trace_visible_rows = 2,
    };
    const result = testFrameCommitResult(0, .terminal_partial_write);
    const commit = resolveTranscriptTransitionCommit(
        &transition,
        result,
        scroll_plan.commit(result.terminal_scroll_rows_committed),
    );

    const unapplied = resolveTranscriptRecoveryCommit(&runtime, &transition, result, commit);
    try std.testing.expectEqual(@as(u32, 0), unapplied.materialized_visual_offset);
    try std.testing.expectEqual(@as(u16, 0), unapplied.materialized_visual_rows);
    try std.testing.expectEqual(@as(?usize, 0), unapplied.materialized_flow_len);
    try std.testing.expectEqual(@as(u16, 2), unapplied.materialized_cursor_row);
    try std.testing.expectEqual(@as(u16, 3), unapplied.materialized_cursor_col);

    try std.testing.expectEqualDeep(
        transition.materialized_without_append,
        resolveRecoveryMaterializedEndpoint(&transition, result, commit),
    );

    var complete_commit = commit;
    complete_commit.complete = true;
    try std.testing.expectEqualDeep(
        planned,
        resolveRecoveryMaterializedEndpoint(&transition, result, complete_commit),
    );

    var appended_result = result;
    appended_result.document_append_committed = true;
    try std.testing.expectEqualDeep(
        planned,
        resolveRecoveryMaterializedEndpoint(&transition, appended_result, commit),
    );

    transition.recovery_progress_compatible = false;
    try std.testing.expectEqualDeep(
        planned,
        resolveRecoveryMaterializedEndpoint(&transition, result, commit),
    );
    transition.recovery_progress_compatible = true;

    transition.recovery_tracks_semantic_progress = false;
    try std.testing.expectEqualDeep(
        planned,
        resolveRecoveryMaterializedEndpoint(&transition, result, commit),
    );
    transition.recovery_tracks_semantic_progress = true;

    transition.recovery_rebase = true;
    try std.testing.expectEqualDeep(
        planned,
        resolveRecoveryMaterializedEndpoint(&transition, result, commit),
    );
    transition.recovery_rebase = false;

    transition.document_append = .{};
    transition.materialized_without_append = runtime.materializedEndpointWithoutAppend(
        .{},
        planned,
    );
    const absent = resolveTranscriptRecoveryCommit(&runtime, &transition, result, commit);
    try std.testing.expectEqual(@as(u32, 1), absent.materialized_visual_offset);
    try std.testing.expectEqual(@as(u16, 1), absent.materialized_visual_rows);
    try std.testing.expectEqual(@as(?usize, 6), absent.materialized_flow_len);
    try std.testing.expectEqual(@as(u16, 3), absent.materialized_cursor_row);
    try std.testing.expectEqual(@as(u16, 1), absent.materialized_cursor_col);
}

test "partial resume publication retains its cursor and requests the next frame" {
    const alloc = std.testing.allocator;
    const scroll_plan = render_engine.frame_scroll_plan.merge(8, 1, 0, 128);
    var runtime = TranscriptRuntime{ .layout = testLayoutWithRows(8) };
    defer runtime.deinit(alloc);
    runtime.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, "pending"),
    );
    var transition = TranscriptTransition{
        .scroll_plan = scroll_plan,
        .document_append = .{},
        .materialized_without_append = .{},
        .semantic_rows = 256,
        .semantic_progress_rows = 256,
        .recovery_progress_compatible = true,
        .recovery_tracks_semantic_progress = true,
        .target_flow = runtime.pending_resume_source.?.bytes,
        .target_flow_owned = false,
        .target_cache = .empty,
        .target_cache_unchanged = true,
        .folded_summary_indices = &.{},
        .target_layout = .{ .terminal_rows = 8, .terminal_cols = 40 },
        .selection = .{
            .top_row = 1,
            .bottom_row = 4,
            .start_line = 252,
            .partial_skip_rows = 0,
            .line_count = 256,
        },
        .visual_offset = 256,
        .history_visual_offset = 128,
        .source_endpoint_visual_offset = 256,
        .total_visual_rows = 256,
        .cursor_row = 4,
        .cursor_col = 1,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 4,
        .trace_transcript_frame = false,
        .trace_visible_rows = 4,
    };
    defer transition.deinit(alloc);

    runtime.consumeTranscriptTransition(
        alloc,
        &transition,
        testFrameCommitResult(128, .committed),
    );

    switch (runtime.transcript_commit_state) {
        .recovering => |receipt| {
            try std.testing.expectEqual(@as(u32, 128), receipt.accepted_visual_offset);
            try std.testing.expectEqual(@as(u32, 128), receipt.remaining_semantic_rows);
        },
        .invalid, .stable => return error.TestExpectedRecoveringTranscript,
    }
    try std.testing.expectEqualStrings("pending", runtime.pendingResumeFlow());
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
}

test "owned stable transition traces a superseded pending resume source" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "resume-source-drop.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "session");

    var runtime = TranscriptRuntime{ .layout = testLayoutWithRows(8) };
    defer runtime.deinit(alloc);
    runtime.bindDetachedCommitAllocator(alloc);
    runtime.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, "stale"),
    );
    var transition = TranscriptTransition{
        .scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(8, 1),
        .document_append = .{},
        .target_flow = try alloc.dupe(u8, "fresh"),
        .target_cache = .empty,
        .folded_summary_indices = &.{},
        .target_layout = .{ .terminal_rows = 8, .terminal_cols = 80 },
        .selection = .{
            .top_row = 1,
            .bottom_row = 1,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
        },
        .visual_offset = 0,
        .history_visual_offset = 0,
        .total_visual_rows = 1,
        .materialized_without_append = .{},
        .cursor_row = 1,
        .cursor_col = 6,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 1,
        .trace_transcript_frame = false,
        .trace_visible_rows = 1,
    };
    defer transition.deinit(alloc);

    runtime.consumeTranscriptTransition(
        alloc,
        &transition,
        testFrameCommitResult(0, .committed),
    );
    debug_trace.shutdown();

    var trace_file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer trace_file.close(std.testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 4096);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(
        u8,
        trace,
        "pending resume flow dropped reason=superseded bytes=5",
    ) != null);
}

test "stable resume publication starts a fresh retained source epoch" {
    const alloc = std.testing.allocator;
    const retained_flow =
        "tail-1\n" ++
        "tail-2\n" ++
        "tail-3\n" ++
        "tail-final";
    const full_flow =
        "old-1\nold-2\nold-3\nold-4\n" ++
        "old-5\nold-6\nold-7\nold-8\n" ++
        retained_flow;
    const layout: Layout = .{
        .rows = 8,
        .cols = 40,
        .content_bottom = 4,
        .divider_top_row = 5,
        .input_row = 6,
        .divider_bottom_row = 7,
        .hint_row = 8,
    };
    var runtime = TranscriptRuntime{
        .layout = layout,
        .owned_top_row = 1,
        .viewport_top_row = 1,
    };
    defer runtime.deinit(alloc);
    try runtime.enableShadowVt(alloc);
    runtime.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, full_flow),
    );
    try runtime.transcript.appendSlice(alloc, retained_flow);

    var transition = TranscriptTransition{
        .scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(
            layout.rows,
            runtime.owned_top_row,
        ),
        .document_append = .{},
        .materialized_without_append = .{},
        .target_flow = runtime.pending_resume_source.?.bytes,
        .target_flow_owned = false,
        .target_cache = .empty,
        .target_cache_unchanged = true,
        .folded_summary_indices = &.{},
        .target_layout = .{
            .layout_id = 17,
            .owned_top = 1,
            .owned_band = .{ .top = 1, .bottom = 8 },
            .body_area = .{ .top = 1, .bottom = 4 },
            .transcript_area = .{ .top = 1, .bottom = 4 },
            .footer_area = .{ .top = 5, .bottom = 8 },
            .solved_frame_height = 8,
            .terminal_rows = 8,
            .terminal_cols = 40,
        },
        .selection = .{
            .top_row = 1,
            .bottom_row = 4,
            .start_line = 8,
            .partial_skip_rows = 0,
            .line_count = 12,
            .last_visible_row = 4,
        },
        .visual_offset = 8,
        .history_visual_offset = 8,
        .total_visual_rows = 12,
        .cursor_row = 4,
        .cursor_col = 11,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 4,
        .trace_transcript_frame = false,
        .trace_visible_rows = 4,
    };
    defer transition.deinit(alloc);
    runtime.consumeTranscriptTransition(
        alloc,
        &transition,
        testFrameCommitResult(0, .committed),
    );

    try std.testing.expectEqual(@as(usize, 0), runtime.pendingResumeFlow().len);
    try std.testing.expectEqualStrings(retained_flow, runtime.transcript.items);
    try std.testing.expectEqual(
        TranscriptCommitDiagnosticState.invalid,
        runtime.transcriptCommitDiagnostic().state,
    );

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    try std.testing.expectEqualStrings(retained_flow, source.bytes);
    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        &source,
        .{ .top = 1, .bottom = 4 },
    );
    defer prepared.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), prepared.selection.start_line);
    try std.testing.expectEqual(@as(usize, 4), prepared.selection.line_count);
    try std.testing.expectEqual(@as(u16, 4), prepared.cursor.cursor_row);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 0), facts.planned_rows);
    try std.testing.expectEqual(@as(u32, 0), facts.target_visual_offset);
    try std.testing.expect(facts.recovery_rebase);
}

test "oversized resume publication retains bounded recovery progress" {
    const alloc = std.testing.allocator;
    const layout = invalidationTestLayout();
    var runtime = TranscriptRuntime{
        .layout = layout,
        .owned_top_row = 1,
        .committed_frame_layout = .{
            .terminal_rows = layout.rows,
            .terminal_cols = layout.cols,
        },
    };
    defer runtime.deinit(alloc);

    var flow: std.ArrayList(u8) = .empty;
    defer flow.deinit(alloc);
    for (0..@as(usize, std.math.maxInt(u16)) + 21) |_| {
        try flow.appendSlice(alloc, "row\n");
    }
    runtime.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, flow.items),
    );

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        &source,
        .{ .top = 1, .bottom = layout.content_bottom },
    );
    defer prepared.deinit(alloc);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(facts.target_visual_offset > std.math.maxInt(u16));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u16)), facts.semantic_rows);
    try std.testing.expectEqual(
        @as(u16, resume_publication_rows_per_frame),
        facts.planned_rows,
    );
    try std.testing.expect(facts.recovery_progress_compatible);
    try std.testing.expect(facts.recovery_tracks_semantic_progress);
    const scroll_plan = render_engine.frame_scroll_plan.merge(
        layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    const accepted = acceptedTranscriptRows(
        scroll_plan,
        scroll_plan.terminal_scroll_rows,
        facts.resize_reflow_rows,
        facts.semantic_rows,
        facts.semantic_progress_rows,
    );
    try std.testing.expectEqual(
        @as(u32, resume_publication_rows_per_frame),
        accepted.semantic_rows,
    );
    try std.testing.expect(accepted.semantic_rows < facts.semantic_rows);

    const append_base = (try runtime.resolveTransitionAppendBase(
        &prepared,
        facts,
        false,
        source.bytes,
        facts.target_visual_offset,
    )) orelse return error.TestExpectedResumeAppendBase;
    try std.testing.expectEqual(@as(usize, 0), append_base.flow_len);
}

test "transition commit keeps unplanned physical scroll as recovery debt" {
    const scroll_plan = render_engine.frame_scroll_plan.merge(8, 1, 0, 2);
    var transition = TranscriptTransition{
        .scroll_plan = scroll_plan,
        .document_append = .{},
        .materialized_without_append = .{},
        .semantic_rows = 2,
        .semantic_progress_rows = 2,
        .target_flow = &.{},
        .target_cache = .empty,
        .folded_summary_indices = &.{},
        .target_layout = .{
            .terminal_rows = 8,
            .terminal_cols = 40,
        },
        .selection = .{
            .top_row = 1,
            .bottom_row = 4,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 2,
        },
        .visual_offset = 0,
        .history_visual_offset = 0,
        .total_visual_rows = 2,
        .cursor_row = 4,
        .cursor_col = 1,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 4,
        .trace_transcript_frame = false,
        .trace_visible_rows = 4,
    };

    const result = testFrameCommitResult(scroll_plan.terminal_scroll_rows + 1, .committed);
    const commit = resolveTranscriptTransitionCommit(
        &transition,
        result,
        scroll_plan.commit(result.terminal_scroll_rows_committed),
    );
    try std.testing.expectEqual(@as(u32, 2), commit.accepted.semantic_rows);
    try std.testing.expectEqual(@as(u32, 0), commit.remaining_semantic_rows);
    try std.testing.expectEqual(@as(u16, 1), commit.remaining_unplanned_scroll_rows);
    try std.testing.expect(!commit.complete);
    try std.testing.expect(!commit.stable);

    var runtime = TranscriptRuntime{
        .layout = testLayoutWithRows(8),
        .owned_top_row = 1,
        .viewport_top_row = 1,
    };
    defer runtime.deinit(std.testing.allocator);
    runtime.consumeFrameScrollCommit(
        std.testing.allocator,
        scroll_plan,
        result,
        &transition,
    );
    const diagnostic = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(TranscriptCommitDiagnosticState.recovering, diagnostic.state);
    try std.testing.expectEqual(@as(u16, 1), diagnostic.remaining_unplanned_scroll_rows);
}

fn frameInlineScrollBudget(resize_reflow_rows: u16, semantic_rows: u32) u16 {
    return frameInlineScrollBudgetCapped(
        resize_reflow_rows,
        semantic_rows,
        std.math.maxInt(u32),
    );
}

test "pending resume publication yields after a bounded row batch" {
    const alloc = std.testing.allocator;
    var runtime: TranscriptRuntime = .{};
    defer runtime.deinit(alloc);
    const prepared = transcript_painter.PreparedTranscriptSurfacePaint{ .selection = .{
        .top_row = 1,
        .bottom_row = 1,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = 1,
    } };

    try std.testing.expectEqual(
        @as(u16, 1_000),
        runtime.plannedTranscriptRows(&prepared, 0, 0, 1_000, 0),
    );
    runtime.pending_resume_source = try source_preparation.prepareFullTranscriptViewportSource(
        &runtime,
        alloc,
        try alloc.dupe(u8, "pending"),
    );
    try std.testing.expectEqual(
        @as(u16, resume_publication_rows_per_frame),
        runtime.plannedTranscriptRows(&prepared, 0, 0, 1_000, 0),
    );
}

fn frameInlineScrollBudgetCapped(
    resize_reflow_rows: u16,
    semantic_rows: u32,
    semantic_cap: u32,
) u16 {
    const semantic_budget = @min(
        @min(semantic_rows, semantic_cap),
        @as(u32, std.math.maxInt(u16) - resize_reflow_rows),
    );
    return resize_reflow_rows + @as(u16, @intCast(semantic_budget));
}

fn projectionVisualRows(total_visual_rows: u32, visual_offset: u32) u16 {
    return @intCast(@min(
        total_visual_rows -| visual_offset,
        @as(u32, std.math.maxInt(u16)),
    ));
}

fn projectionVisualRowsInArea(
    total_visual_rows: u32,
    visual_offset: u32,
    area: render_engine.frame_layout.FrameRect,
) u16 {
    if (area.isEmpty()) return 0;
    return @min(
        projectionVisualRows(total_visual_rows, visual_offset),
        area.height(),
    );
}

fn visualOffsetForSelection(line_rows: []const u16, selection: ViewportSelection) u32 {
    var offset: u32 = 0;
    const end = @min(selection.start_line, line_rows.len);
    for (line_rows[0..end]) |rows| {
        offset += rows;
    }
    return offset + selection.partial_skip_rows;
}

fn reflowedRows(
    grid: *const vt_emulator.Grid,
    start_row: u16,
    end_row: u16,
    target_cols: u16,
    include_cursor: bool,
) u32 {
    if (target_cols == 0 or start_row == 0 or start_row > end_row or start_row > grid.rows) return 0;

    var total: u32 = 0;
    var row = start_row;
    const last_row = @min(end_row, grid.rows);
    while (row <= last_row) : (row += 1) {
        var occupied_col: u16 = 0;
        var col: u16 = 1;
        while (col <= grid.cols) : (col += 1) {
            const cell = grid.cellAt(row, col).?;
            if (cell.codepoint != ' ' or
                cell.combining_suffix_id != 0 or
                !cell.style.eql(.{}))
            {
                occupied_col = col;
            }
        }
        if (include_cursor and row == grid.cursor_row) {
            occupied_col = @max(occupied_col, grid.cursor_col);
        }
        total += if (occupied_col == 0)
            1
        else
            (@as(u32, occupied_col) - 1) / target_cols + 1;
    }
    return total;
}

test "reflowed rows count a combining suffix attached to a space" {
    var grid = try vt_emulator.Grid.init(std.testing.allocator, 4, 1);
    defer grid.deinit();
    try grid.feed("   \u{0301}");

    try std.testing.expectEqual(
        @as(u32, 2),
        reflowedRows(&grid, 1, 1, 2, false),
    );
}

fn invalidationTestLayout() Layout {
    return .{
        .rows = 24,
        .cols = 80,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
}

test "frame invalidations move into one request snapshot" {
    var runtime = TranscriptRuntime{ .layout = invalidationTestLayout(), .owned_top_row = 5 };
    defer runtime.deinit(std.testing.allocator);

    try runtime.recordFrameInvalidation(.{ .reason = .resize, .top = 5, .bottom = 24 });
    try runtime.recordFrameInvalidation(.{ .reason = .external_clear, .top = 21, .bottom = 24 });

    var attempt = (try runtime.render_requests.beginAttempt()).?;
    try std.testing.expectEqual(@as(u8, 2), attempt.snapshot.invalidations.len);
    try std.testing.expectEqual(render_engine.paint_plan.FrameInvalidationReason.resize, attempt.snapshot.invalidations.ranges()[0].reason);
    try std.testing.expectEqual(render_engine.paint_plan.FrameInvalidationReason.external_clear, attempt.snapshot.invalidations.ranges()[1].reason);
    attempt.commit(0, render_request.animation_interval_ms, false);
    try std.testing.expect((try runtime.render_requests.beginAttempt()) == null);
}

test "recording a frame invalidation schedules request-owned work" {
    var runtime = TranscriptRuntime{ .layout = invalidationTestLayout(), .owned_top_row = 5 };
    defer runtime.deinit(std.testing.allocator);

    try runtime.recordFrameInvalidation(.{ .reason = .external_clear, .top = 5, .bottom = 24 });

    try std.testing.expect(runtime.render_requests.hasReason(.external_damage));
}

test "terminal reset drops stale mid-scrollback footer clear before reanchor" {
    var metrics: Metrics = .{};
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 36,
            .cols = 120,
            .content_bottom = 32,
            .divider_top_row = 33,
            .input_row = 34,
            .divider_bottom_row = 35,
            .hint_row = 36,
        },
        .owned_top_row = 22,
        .viewport_top_row = 22,
        .has_painted_transcript = true,
        .min_visible_viewport_rows = 11,
    };
    defer runtime.deinit(std.testing.allocator);
    runtime.footer_viewport.has_frame = true;
    runtime.footer_viewport.geometry.top = 25;
    runtime.footer_viewport.externally_invalidated = true;

    try runtime.recordFrameInvalidation(.{
        .reason = .external_clear,
        .top = 25,
        .bottom = 36,
    });

    try runtime.requestTerminalReset(&metrics);

    try std.testing.expectEqual(@as(u16, 1), runtime.owned_top_row);
    try std.testing.expectEqual(@as(u16, 1), runtime.viewport_top_row);
    try std.testing.expect(!runtime.footer_viewport.has_frame);
    try std.testing.expect(!runtime.footer_viewport.externally_invalidated);

    const pending = runtime.render_requests.pendingInvalidations();
    try std.testing.expectEqual(@as(u8, 1), pending.len);
    try std.testing.expectEqual(
        render_engine.paint_plan.FrameInvalidationReason.viewport_reanchor,
        pending.ranges()[0].reason,
    );
    try std.testing.expectEqual(@as(u16, 1), pending.ranges()[0].top);
    try std.testing.expectEqual(@as(u16, 36), pending.ranges()[0].bottom);

    var plan = render_engine.paint_plan.PaintPlan{
        .layout = runtime.layout,
        .viewport = .{
            .top_row = 1,
            .bottom_row = 3,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 3,
            .last_visible_row = 3,
            .last_visible_row_blank = false,
            .tail_kind = null,
            .replaceable_start_row = 1,
            .split_active = false,
            .split_prefix_lines = 0,
            .split_suffix_start_line = 0,
        },
        .footer = .{
            .top = 4,
            .top_divider = 4,
            .banner = 4,
            .banner_active = false,
            .input_base = 5,
            .picker_divider = 6,
            .picker_start = 7,
            .bottom_divider = 6,
            .hint = 7,
            .total_rows = 4,
        },
        .activity = .none,
        .preserved_band = render_engine.paint_plan.FrameBand.empty(.preserved_shell),
        .transcript_band = .{ .top = 1, .bottom = 3, .owner = .transcript },
        .blank_band = render_engine.paint_plan.FrameBand.empty(.gap),
        .activity_band = render_engine.paint_plan.FrameBand.empty(.activity),
        .footer_gap_band = render_engine.paint_plan.FrameBand.empty(.gap),
        .footer_band = .{ .top = 4, .bottom = 7, .owner = .footer },
        .invalidation = pending,
        .footer_clean_allowed = false,
        .synchronized_update = false,
        .cursor_target = null,
        .footer_reservation_source = .none,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
    try plan.validate();

    try std.testing.expectError(
        error.InvalidInvalidationRange,
        render_engine.paint_plan.validateInvalidationRange(plan, .{
            .reason = .external_clear,
            .top = 25,
            .bottom = 36,
        }),
    );
}

test "marking transcript cache dirty also schedules transcript work" {
    var runtime = TranscriptRuntime{};
    defer runtime.deinit(std.testing.allocator);

    runtime.markTranscriptDirty();

    try std.testing.expect(runtime.transcript_band_dirty);
    try std.testing.expect(runtime.render_requests.hasReason(.transcript));
}

test "frame invalidation overflow collapses to owned band with dominant reason" {
    var runtime = TranscriptRuntime{ .layout = invalidationTestLayout(), .owned_top_row = 7 };
    defer runtime.deinit(std.testing.allocator);

    var i: u8 = 0;
    while (i < render_engine.paint_plan.max_frame_invalidation_ranges) : (i += 1) {
        const row: u16 = 7 + i;
        try runtime.recordFrameInvalidation(.{ .reason = .external_clear, .top = row, .bottom = row });
    }
    try runtime.recordFrameInvalidation(.{ .reason = .shadow_feed_failure, .top = 12, .bottom = 12 });

    const pending = runtime.render_requests.pendingInvalidations();
    try std.testing.expectEqual(@as(u8, 1), pending.len);
    try std.testing.expectEqual(render_engine.paint_plan.FrameInvalidationReason.shadow_feed_failure, pending.ranges()[0].reason);
    try std.testing.expectEqual(@as(u16, 7), pending.ranges()[0].top);
    try std.testing.expectEqual(@as(u16, 24), pending.ranges()[0].bottom);
}

test "preserved row acknowledgment lowers ownership and viewport boundaries" {
    var runtime = TranscriptRuntime{
        .layout = invalidationTestLayout(),
        .owned_top_row = 5,
        .viewport_top_row = 7,
    };
    defer runtime.deinit(std.testing.allocator);
    const scroll_plan = render_engine.frame_scroll_plan.merge(runtime.layout.rows, runtime.owned_top_row, 2, 0);

    try runtime.ackPreservedRowRelease(scroll_plan, 2);

    try std.testing.expectEqual(@as(u16, 3), runtime.owned_top_row);
    try std.testing.expectEqual(@as(u16, 5), runtime.viewport_top_row);
}

test "preserved row acknowledgment applies only committed rows inside the plan" {
    var partial = TranscriptRuntime{
        .layout = invalidationTestLayout(),
        .owned_top_row = 5,
        .viewport_top_row = 7,
    };
    defer partial.deinit(std.testing.allocator);
    const scroll_plan = render_engine.frame_scroll_plan.merge(partial.layout.rows, partial.owned_top_row, 2, 0);

    try partial.ackPreservedRowRelease(scroll_plan, 1);
    try std.testing.expectEqual(@as(u16, 4), partial.owned_top_row);
    try std.testing.expectEqual(@as(u16, 6), partial.viewport_top_row);

    var above_plan = TranscriptRuntime{
        .layout = invalidationTestLayout(),
        .owned_top_row = 5,
        .viewport_top_row = 7,
    };
    defer above_plan.deinit(std.testing.allocator);
    try above_plan.ackPreservedRowRelease(scroll_plan, 20);
    try std.testing.expectEqual(@as(u16, 3), above_plan.owned_top_row);
    try std.testing.expectEqual(@as(u16, 5), above_plan.viewport_top_row);
}

test "preserved row acknowledgment normalizes stale resize boundaries before release" {
    var full = TranscriptRuntime{
        .layout = testLayoutWithRows(5),
        .owned_top_row = 8,
        .viewport_top_row = 9,
    };
    defer full.deinit(std.testing.allocator);
    const full_plan = render_engine.frame_scroll_plan.merge(full.layout.rows, full.owned_top_row, 4, 0);
    try full.ackPreservedRowRelease(full_plan, 4);
    try std.testing.expectEqual(@as(u16, 1), full.owned_top_row);
    try std.testing.expectEqual(@as(u16, 1), full.viewport_top_row);

    var partial = TranscriptRuntime{
        .layout = testLayoutWithRows(5),
        .owned_top_row = 8,
        .viewport_top_row = 9,
    };
    defer partial.deinit(std.testing.allocator);
    const partial_plan = render_engine.frame_scroll_plan.merge(partial.layout.rows, partial.owned_top_row, 4, 0);
    try partial.ackPreservedRowRelease(partial_plan, 2);
    try std.testing.expectEqual(@as(u16, 3), partial.owned_top_row);
    try std.testing.expectEqual(@as(u16, 3), partial.viewport_top_row);
}

test "preserved row acknowledgment normalizes shrink boundaries even without accepted release" {
    var runtime = TranscriptRuntime{
        .layout = testLayoutWithRows(5),
        .owned_top_row = 8,
        .viewport_top_row = 9,
    };
    defer runtime.deinit(std.testing.allocator);
    const scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(runtime.layout.rows, runtime.owned_top_row);

    try runtime.ackPreservedRowRelease(scroll_plan, 0);

    try std.testing.expectEqual(@as(u16, 5), runtime.owned_top_row);
    try std.testing.expectEqual(@as(u16, 5), runtime.viewport_top_row);
}

test "preserved row acknowledgment keeps viewport at or below owned top boundary" {
    var runtime = TranscriptRuntime{
        .layout = invalidationTestLayout(),
        .owned_top_row = 5,
        .viewport_top_row = 2,
    };
    defer runtime.deinit(std.testing.allocator);
    const scroll_plan = render_engine.frame_scroll_plan.merge(runtime.layout.rows, runtime.owned_top_row, 4, 0);

    try runtime.ackPreservedRowRelease(scroll_plan, 4);

    try std.testing.expectEqual(@as(u16, 1), runtime.owned_top_row);
    try std.testing.expectEqual(@as(u16, 1), runtime.viewport_top_row);
}

test "transcript runtime owns render request state" {
    try std.testing.expect(@hasField(TranscriptRuntime, "render_requests"));
}

test "recovery append prefix requires exact materialized bytes" {
    const alloc = std.testing.allocator;
    const receipt_flow = try alloc.dupe(u8, "prefix-good");
    defer alloc.free(receipt_flow);
    const receipt = TranscriptRecoveryReceipt{
        .flow = receipt_flow,
        .materialized_flow_len = 7,
    };

    try std.testing.expect(recoveryAppendPrefixMatches("prefix-next", receipt, 7));
    try std.testing.expect(!recoveryAppendPrefixMatches("prefiy-next", receipt, 7));
    try std.testing.expect(!recoveryAppendPrefixMatches("short", receipt, 7));
}

test "measured recovery rebases from accepted projection before retiring resize debt" {
    const alloc = std.testing.allocator;
    const flow =
        "aaaaaaaaaaaaaaaaaaaa\n" ++
        "bbbbbbbbbbbbbbbbbbbb\n" ++
        "cccccccccccccccccccc\n" ++
        "dddddddddddddddddddd\n" ++
        "eeeeeeeeeeeeeeeeeeee\n" ++
        "ffffffffffffffffffff\n" ++
        "gggggggggggggggggggg\n" ++
        "hhhhhhhhhhhhhhhhhhhh\n";
    const layout: Layout = .{
        .rows = 8,
        .cols = 10,
        .content_bottom = 4,
        .divider_top_row = 5,
        .input_row = 6,
        .divider_bottom_row = 7,
        .hint_row = 8,
    };
    var runtime = TranscriptRuntime{
        .layout = layout,
        .owned_top_row = 1,
        .resize_history_row_delta = 2,
        .committed_frame_layout = .{
            .layout_id = 17,
            .owned_top = 1,
            .owned_band = .{ .top = 1, .bottom = 8 },
            .body_area = .{ .top = 1, .bottom = 4 },
            .transcript_area = .{ .top = 1, .bottom = 4 },
            .footer_area = .{ .top = 5, .bottom = 8 },
            .solved_frame_height = 8,
            .terminal_rows = 8,
            .terminal_cols = 20,
        },
    };
    defer runtime.deinit(alloc);
    try runtime.transcript.appendSlice(alloc, flow);
    runtime.transcript_commit_state = .{ .recovering = .{
        .accepted_visual_offset = 6,
        .accepted_history_visual_offset = 6,
        .attempt_visual_offset = 8,
        .attempt_total_visual_rows = 8,
        .materialized_visual_offset = 7,
        .materialized_visual_rows = 1,
        .materialized_flow_len = flow.len,
        .remaining_resize_reflow_rows = 3,
        .remaining_semantic_rows = 2,
        .remaining_semantic_progress_rows = 2,
        .attempt_cols = 20,
        .projection_rebase_pending = false,
        .tracks_semantic_progress = true,
        .flow = try alloc.dupe(u8, flow),
        .cursor_row = 4,
        .cursor_col = 1,
    } };
    const projection = runtime.measuredResizeProjectionForFlow(flow) orelse
        return error.TestExpectedMeasuredResizeProjection;
    switch (projection) {
        .stable => return error.TestExpectedRecoveringProjection,
        .recovering => |recovering| {
            try std.testing.expectEqual(
                @as(u32, 6),
                recovering.accepted_visual_offset,
            );
            try std.testing.expectEqual(@as(u16, 20), recovering.source_cols);
        },
    }

    var source = try runtime.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        &source,
        .{ .top = 1, .bottom = 4 },
    );
    defer prepared.deinit(alloc);

    try std.testing.expectEqual(
        transcript_painter.MeasuredResizeTargetProvenance.recovering,
        prepared.measured_resize_target_provenance,
    );
    const endpoint = prepared.measured_history_origin.?.endpoint orelse
        return error.TestExpectedMeasuredHistoryEndpoint;
    try std.testing.expectEqual(@as(usize, 147), endpoint.flow_offset);
    try std.testing.expectEqual(
        @as(u32, 14),
        visualOffsetForSelection(prepared.sourceVisualRows(), prepared.selection),
    );
    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expectEqual(@as(u16, 0), facts.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 2), facts.semantic_rows);
    try std.testing.expectEqual(@as(u32, 14), facts.target_visual_offset);

    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan: render_engine.paint_plan.PaintPlan = .{
        .layout = runtime.layout,
        .viewport = prepared.selection,
        .footer = .{
            .top = 5,
            .top_divider = 5,
            .banner = 5,
            .banner_active = false,
            .input_base = 6,
            .picker_divider = 7,
            .picker_start = 8,
            .bottom_divider = 7,
            .hint = 8,
            .total_rows = 4,
        },
        .activity = .none,
        .preserved_band = render_engine.paint_plan.FrameBand.empty(.preserved_shell),
        .transcript_band = .{ .top = 1, .bottom = 4, .owner = .transcript },
        .activity_band = render_engine.paint_plan.FrameBand.empty(.activity),
        .footer_band = .{ .top = 5, .bottom = 8, .owner = .footer },
        .invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{
            .row = prepared.cursor.cursor_row,
            .col = prepared.cursor.cursor_col,
            .visible = true,
        },
        .footer_reservation_source = .none,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
    var transition = try resolveAndSealTranscriptTransitionForRuntimeTest(
        &runtime,
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
        .committed_cursor_row = transition.cursor_row,
        .committed_cursor_col = transition.cursor_col,
        .shadow_state = .committed,
        .next_invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
    });

    const committed = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(TranscriptCommitDiagnosticState.recovering, committed.state);
    try std.testing.expectEqual(@as(u32, 14), committed.visual_offset);
    switch (runtime.transcript_commit_state) {
        .recovering => |receipt| {
            try std.testing.expectEqual(@as(u16, 0), receipt.remaining_resize_reflow_rows);
            try std.testing.expectEqual(@as(u32, 2), receipt.remaining_semantic_rows);
        },
        .invalid, .stable => return error.TestExpectedRecoveringTranscript,
    }

    runtime.resize_history_row_delta = null;
    var retry_source = try runtime.prepareTranscriptSource(alloc, null);
    defer retry_source.deinit(alloc);
    var retry_prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        &retry_source,
        .{ .top = 1, .bottom = 4 },
    );
    defer retry_prepared.deinit(alloc);
    const retry = runtime.planTranscriptScroll(&retry_prepared);
    try std.testing.expectEqual(@as(u16, 0), retry.resize_reflow_rows);
    try std.testing.expectEqual(@as(u16, 2), retry.semantic_rows);
}

test "source rewrite replays unchanged history prefix after footer projection rebase" {
    const alloc = std.testing.allocator;
    const target_flow =
        "rewrite-row-01\nrewrite-row-02\nrewrite-row-03\nrewrite-row-04\n" ++
        "rewrite-row-05\nrewrite-row-06\nrewrite-row-07\nrewrite-row-08\n" ++
        "rewrite-row-09\nrewrite-row-10\nrewrite-row-11\nrewrite-row-12\n";
    const layout: Layout = .{
        .rows = 8,
        .cols = 40,
        .content_bottom = 4,
        .divider_top_row = 5,
        .input_row = 6,
        .divider_bottom_row = 7,
        .hint_row = 8,
    };
    var runtime = TranscriptRuntime{
        .layout = layout,
        .owned_top_row = 1,
        .committed_frame_layout = .{
            .layout_id = 17,
            .owned_top = 1,
            .owned_band = .{ .top = 1, .bottom = 8 },
            .body_area = .{ .top = 1, .bottom = 4 },
            .transcript_area = .{ .top = 1, .bottom = 4 },
            .footer_area = .{ .top = 5, .bottom = 8 },
            .solved_frame_height = 8,
            .terminal_rows = 8,
            .terminal_cols = 40,
        },
    };
    defer runtime.deinit(alloc);

    var source = try runtime.prepareFullTranscriptViewportSource(
        alloc,
        try alloc.dupe(u8, target_flow),
    );
    defer source.deinit(alloc);
    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        &source,
        .{ .top = 1, .bottom = 4 },
    );
    defer prepared.deinit(alloc);

    const target_offset = visualOffsetForSelection(
        prepared.sourceVisualRows(),
        prepared.selection,
    );
    try std.testing.expect(target_offset > 5);
    const history_offset = target_offset - 5;
    const previous_flow = try alloc.dupe(u8, target_flow);
    previous_flow[previous_flow.len - 2] = 'X';
    runtime.transcript_commit_state = .{ .stable = .{
        .selection = prepared.selection,
        .visual_offset = target_offset,
        .history_visual_offset = history_offset,
        .total_visual_rows = totalVisualRows(prepared.sourceVisualRows()),
        .flow = previous_flow,
        .cursor_row = prepared.cursor.cursor_row,
        .cursor_col = prepared.cursor.cursor_col,
        .occupied_last_row = prepared.selection.last_visible_row,
        .occupied_last_row_blank = prepared.selection.last_visible_row_blank,
        .layout_id = 17,
        .normal_buffer_recovery_pending = true,
    } };

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(!facts.source_compatible);
    try std.testing.expect(facts.recovery_rebase);
    try std.testing.expectEqual(target_offset, facts.target_visual_offset);
    try std.testing.expectEqual(target_offset - history_offset, facts.semantic_rows);

    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        0,
        facts.planned_rows,
    );
    var plan: render_engine.paint_plan.PaintPlan = .{
        .layout = runtime.layout,
        .viewport = prepared.selection,
        .footer = .{
            .top = 5,
            .top_divider = 5,
            .banner = 5,
            .banner_active = false,
            .input_base = 6,
            .picker_divider = 7,
            .picker_start = 8,
            .bottom_divider = 7,
            .hint = 8,
            .total_rows = 4,
        },
        .activity = .none,
        .preserved_band = render_engine.paint_plan.FrameBand.empty(.preserved_shell),
        .transcript_band = .{ .top = 1, .bottom = 4, .owner = .transcript },
        .activity_band = render_engine.paint_plan.FrameBand.empty(.activity),
        .footer_band = .{ .top = 5, .bottom = 8, .owner = .footer },
        .invalidation = render_engine.paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{
            .row = prepared.cursor.cursor_row,
            .col = prepared.cursor.cursor_col,
            .visible = true,
        },
        .footer_reservation_source = .none,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
    var transition = try resolveAndSealTranscriptTransitionForRuntimeTest(
        &runtime,
        alloc,
        &source,
        &prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan),
        &plan,
        scroll_plan,
    );
    defer transition.deinit(alloc);
    try std.testing.expect(!transition.document_append.isEmpty());
    switch (transition.document_append.clear) {
        .rows => |rows| try std.testing.expectEqual(
            @as(u16, @intCast(facts.semantic_rows)),
            rows,
        ),
        .remainder => return error.TestExpectedHistoryReplay,
    }
}

test "history replay starts at committed source top and follows resize eligibility" {
    const alloc = std.testing.allocator;
    const committed_flow =
        "source-row-01\nsource-row-02\nsource-row-03\nsource-row-04\n";
    const target_flow = committed_flow ++
        "target-row-05\ntarget-row-06\ntarget-row-07\ntarget-row-08\n" ++
        "target-row-09\ntarget-row-10\ntarget-row-11\ntarget-row-12\n";
    const layout: Layout = .{
        .rows = 12,
        .cols = 40,
        .content_bottom = 8,
        .divider_top_row = 9,
        .input_row = 10,
        .divider_bottom_row = 11,
        .hint_row = 12,
    };
    var runtime = TranscriptRuntime{
        .layout = layout,
        .owned_top_row = 5,
        .viewport_top_row = 5,
        .committed_frame_layout = .{
            .layout_id = 17,
            .owned_top = 5,
            .owned_band = .{ .top = 5, .bottom = 12 },
            .body_area = .{ .top = 5, .bottom = 8 },
            .transcript_area = .{ .top = 5, .bottom = 8 },
            .footer_area = .{ .top = 9, .bottom = 12 },
            .solved_frame_height = 8,
            .terminal_rows = 12,
            .terminal_cols = 40,
        },
        .transcript_commit_state = .{ .stable = .{
            .selection = .{
                .top_row = 5,
                .bottom_row = 8,
                .start_line = 0,
                .partial_skip_rows = 0,
                .line_count = 4,
                .last_visible_row = 8,
            },
            .visual_offset = 0,
            .history_visual_offset = 0,
            .total_visual_rows = 4,
            .flow = try alloc.dupe(u8, committed_flow),
            .cursor_row = 8,
            .cursor_col = 1,
            .occupied_last_row = 8,
            .occupied_last_row_blank = true,
            .layout_id = 17,
            .history_catchup_pending = true,
        } },
    };
    defer runtime.deinit(alloc);

    var source = try runtime.prepareFullTranscriptViewportSource(
        alloc,
        try alloc.dupe(u8, target_flow),
    );
    defer source.deinit(alloc);
    var metrics: Metrics = .{};
    var prepared = try runtime.prepareTranscriptSurfacePaintFromSourceForArea(
        alloc,
        &metrics,
        &source,
        .{ .top = 1, .bottom = 8 },
    );
    defer prepared.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 1), prepared.projectionArea().top);

    const facts = runtime.planTranscriptScroll(&prepared);
    try std.testing.expect(facts.source_compatible);
    try std.testing.expectEqual(@as(u32, 4), facts.target_visual_offset);
    try std.testing.expectEqual(@as(u16, 4), facts.planned_rows);

    const append_base = (try runtime.resolveTransitionAppendBase(
        &prepared,
        facts,
        false,
        source.bytes,
        facts.target_visual_offset,
    )) orelse return error.TestExpectedHistoryReplay;
    try std.testing.expect(append_base.history_replay != null);
    try std.testing.expectEqual(
        runtime.committed_frame_layout.transcript_area.top,
        append_base.cursor_row,
    );
    try std.testing.expectEqual(@as(u16, 1), append_base.cursor_col);

    const scroll_plan = render_engine.frame_scroll_plan.merge(
        runtime.layout.rows,
        runtime.owned_top_row,
        runtime.owned_top_row - 1,
        facts.planned_rows,
    );
    try std.testing.expectEqual(@as(u16, 4), scroll_plan.preserved_release_rows);
    try std.testing.expectEqual(@as(u16, 8), scroll_plan.terminal_scroll_rows);

    runtime.resize_history_row_delta = 1;
    const resize_facts = runtime.planTranscriptScroll(&prepared);
    const resize_append_base = (try runtime.resolveTransitionAppendBase(
        &prepared,
        resize_facts,
        false,
        source.bytes,
        resize_facts.target_visual_offset,
    )) orelse return error.TestExpectedNaturalAppendBase;
    try std.testing.expect(resize_append_base.history_replay == null);
}

test "preserved source rewrite holds the normal buffer at committed history" {
    const alloc = std.testing.allocator;
    var runtime = TranscriptRuntime{
        .layout = .{
            .rows = 8,
            .cols = 40,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .committed_frame_layout = .{
            .layout_id = 17,
            .owned_top = 1,
            .owned_band = .{ .top = 1, .bottom = 8 },
            .body_area = .{ .top = 1, .bottom = 4 },
            .transcript_area = .{ .top = 1, .bottom = 4 },
            .footer_area = .{ .top = 5, .bottom = 8 },
            .solved_frame_height = 8,
            .terminal_rows = 8,
            .terminal_cols = 40,
        },
        .transcript_commit_state = .{ .stable = .{
            .selection = .{
                .top_row = 1,
                .bottom_row = 4,
                .start_line = 2,
                .partial_skip_rows = 0,
                .line_count = 6,
                .last_visible_row = 4,
            },
            .visual_offset = 5,
            .history_visual_offset = 2,
            .total_visual_rows = 6,
            .flow = try alloc.dupe(u8, "old source\n"),
            .cursor_row = 4,
            .cursor_col = 1,
            .occupied_last_row = 4,
            .occupied_last_row_blank = false,
            .layout_id = 17,
        } },
    };
    defer runtime.deinit(alloc);

    runtime.reconcileTranscriptCommitSourceWithRewriteMode(
        "rewritten source\n",
        false,
        "test rewrite",
        .preserve_same_epoch,
    );

    switch (runtime.transcript_commit_state) {
        .stable => |anchor| {
            try std.testing.expect(anchor.normal_buffer_recovery_pending);
            try std.testing.expectEqual(
                anchor.history_visual_offset,
                committedProjectionVisualOffset(anchor),
            );
        },
        .invalid, .recovering => return error.TestExpectedStableTranscript,
    }
}

test "frame scroll commit consumption releases rows before transition advancement" {
    var runtime = TranscriptRuntime{
        .layout = testLayoutWithRows(8),
        .owned_top_row = 4,
        .viewport_top_row = 4,
    };
    defer runtime.deinit(std.testing.allocator);

    const scroll_plan = render_engine.frame_scroll_plan.merge(8, 4, 3, 1);
    var transition = TranscriptTransition{
        .scroll_plan = scroll_plan,
        .document_append = .{},
        .materialized_without_append = .{},
        .semantic_rows = 1,
        .semantic_progress_rows = 1,
        .target_flow = &.{},
        .target_cache = .empty,
        .folded_summary_indices = &.{},
        .target_layout = .{
            .layout_id = 18,
            .owned_top = 1,
            .owned_band = .{ .top = 1, .bottom = 8 },
            .body_area = .{ .top = 1, .bottom = 4 },
            .transcript_area = .{ .top = 1, .bottom = 4 },
            .footer_area = .{ .top = 5, .bottom = 8 },
            .solved_frame_height = 8,
            .terminal_rows = 8,
            .terminal_cols = 80,
        },
        .selection = .{
            .top_row = 1,
            .bottom_row = 4,
            .start_line = 1,
            .partial_skip_rows = 0,
            .line_count = 4,
            .last_visible_row = 4,
        },
        .visual_offset = 1,
        .history_visual_offset = 1,
        .total_visual_rows = 5,
        .cursor_row = 4,
        .cursor_col = 1,
        .replaceable_last_line = false,
        .replaceable_start = 0,
        .replaceable_row = 4,
        .trace_transcript_frame = false,
        .trace_visible_rows = 4,
    };
    defer transition.deinit(std.testing.allocator);

    const result = testFrameCommitResult(scroll_plan.terminal_scroll_rows, .committed);
    runtime.consumeFrameScrollCommit(
        std.testing.allocator,
        scroll_plan,
        result,
        &transition,
    );

    try std.testing.expect(transition.consumed);
    try std.testing.expectEqual(@as(u16, 1), runtime.owned_top_row);
    try std.testing.expectEqual(@as(u16, 1), runtime.viewport_top_row);
    const committed = runtime.transcriptCommitDiagnostic();
    try std.testing.expectEqual(TranscriptCommitDiagnosticState.stable, committed.state);
    try std.testing.expectEqual(@as(u32, 1), committed.visual_offset);
}

fn testLayoutWithRows(rows: u16) Layout {
    return .{
        .rows = rows,
        .cols = 80,
        .content_bottom = rows,
        .divider_top_row = rows,
        .input_row = rows,
        .divider_bottom_row = rows,
        .hint_row = rows,
    };
}

test "notification bell writes standalone BEL bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "notification-bells.log", .{ .read = true });
    defer file.close(io_mod.getIo());

    var runtime = TranscriptRuntime{ .stdout_file = file };
    defer runtime.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    runtime.writeNotificationBell(&metrics);

    var bytes: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try file.readPositionalAll(io_mod.getIo(), &bytes, 0),
    );
    try std.testing.expectEqualSlices(u8, "\x07", &bytes);
}

test {
    _ = @import("runtime_tests.zig");
}
