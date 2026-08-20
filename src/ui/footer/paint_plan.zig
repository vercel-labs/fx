const std = @import("std");
const question_state = @import("../../core/agent/question_prompt.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const display_width = @import("../../core/shared/display_width.zig");
const permission_request = @import("../../core/permissions/permission_request.zig");
const approval_prompt = @import("../../core/permissions/approval_prompt.zig");
const file_index = @import("../../core/workspace/file_index.zig");
const types = @import("../../core/shared/types.zig");
const activity_runtime = @import("../../core/output/activity_runtime.zig");
const core_input_runtime = @import("../../core/input/runtime.zig");
const visual_layout = @import("../input/visual_layout.zig");
const user_message_card = @import("../assistant/user_message_card.zig");
const ui_render = @import("../render.zig");
const render_engine = @import("../render_engine.zig");
const transcript_runtime = @import("../transcript/runtime.zig");
const footer_viewport = @import("viewport.zig");
const approval_ui = @import("approval_ui.zig");
const appearance_menu_presentation = @import("appearance_menu_presentation.zig");
const compact_command_menu_presentation = @import("compact_command_menu_presentation.zig");
const input_presentation = @import("input_presentation.zig");
const interaction_state = @import("interaction_state.zig");
const picker_presentation = @import("picker_presentation.zig");
const question_ui = @import("question_ui.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const activity_overlay = render_engine.activity_overlay;
const footer_layout = render_engine.footer_layout;
const engine_paint_plan = render_engine.paint_plan;
const transcript_blocks = render_engine.transcript_blocks;
const viewport_selection = render_engine.viewport_selection;
const Layout = types.Layout;
const Metrics = types.Metrics;
const ActivityProjection = activity_runtime.ActivityProjection;
const ActivityPlacement = activity_overlay.ActivityPlacement;
const FooterRows = footer_layout.FooterRows;
const PaintPlan = engine_paint_plan.PaintPlan;
const TranscriptBlockKind = transcript_blocks.TranscriptBlockKind;
const ViewportSelection = viewport_selection.ViewportSelection;
const InputRuntime = core_input_runtime.Runtime;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const ApprovalPrompt = approval_prompt.ApprovalPrompt;
const ApprovalProjection = approval_prompt.Projection;

const BottomReservationReason = enum {
    none,
    transient_midline,
    idle_footer_gap,
};

pub const FooterTranscriptState = struct {
    selection: ViewportSelection,
    cursor_row: u16,
    cursor_col: u16,
    replaceable_row: u16,
    bottom_reserved_rows: u16,
};

pub const FooterPlannerInput = struct {
    active_label: ?[]const u8,
    activity_projection: ActivityProjection = .none,
    ctx: render_input.RenderContext,
    place_mid_line_active: bool,
    input_extra: u16,
    input_visible: bool = true,
    composer_top_chrome_rows: u16 = 1,
    picker_rows: u16,
    footer_gap_active: bool = false,
    banner_active: bool,
    banner_rows: u16 = 0,
    footer_extra_rows: ?u16 = null,
    allocated_rows: ?u16 = null,
    applied_bottom_reserved_rows: u16 = 0,
    approval: ?ApprovalProjection = null,
    input_display: []const u8 = "",
    input_cursor: usize = 0,
    input_summary: visual_layout.Summary = .{
        .total_rows = 1,
        .cursor = .{ .raw_offset = 0, .row_index = 0, .content_column = 0 },
        .anchor = null,
    },
    input_window: visual_layout.VisibleWindow = .{ .first_row = 0, .row_count = 1 },
    total_lines: u16 = 1,
    show_picker: bool = false,
    picker_kind: input_presentation.PickerKind = .model_stage,
    picker_items: []const []const u8 = &.{},
    file_picker_items: []const file_index.SearchResult = &.{},
    picker_selection_index: usize = 0,
    picker_window_start: usize = 0,
    picker_loading: bool = false,
    picker_failed: bool = false,
    slash_completion_count: usize = 0,
    slash_menu_layout: ?picker_presentation.SlashMenuLayout = null,
    picker_start_col: u16 = 1,
    transcript_state: ?FooterTranscriptState = null,
};

pub const FooterFramePlan = struct {
    paint: PaintPlan,
    resolved_activity: ActivityPlacement,
    banner_activity: ActivityPlacement,
    bottom_reservation_reason: BottomReservationReason,
    overlay_suppressed: bool,
};

const FooterReservationPlan = struct {
    bottom_reserved_rows: u16,
    reason: BottomReservationReason,
    transient_rows: u16,
    activity_offset: u16,

    fn reserveForSuppressedTransient(
        self: *FooterReservationPlan,
        shell: *const TranscriptRuntime,
        input: FooterPlannerInput,
        suppressed: bool,
    ) void {
        if (!suppressed) return;
        if (self.reason != .none) return;
        if (input.applied_bottom_reserved_rows != 0) return;
        if (input.active_label == null) return;
        if (shell.layout.content_bottom <= self.transient_rows) return;

        self.bottom_reserved_rows = self.transient_rows;
        self.reason = .transient_midline;
    }

    fn reserveForActivity(self: *FooterReservationPlan, activity_reserved_rows: u16) void {
        if (activity_reserved_rows <= self.bottom_reserved_rows) return;
        self.bottom_reserved_rows = activity_reserved_rows;
        if (self.reason == .none) self.reason = .transient_midline;
    }
};

fn transientActivityOverlapsFooter(activity: ActivityPlacement, rows: FooterRows) bool {
    return switch (activity) {
        .transient_row => |transient| transient.row >= rows.top,
        .none, .overlay_entry => false,
    };
}

fn activityFooterOffset(activity: ActivityPlacement, footer_top_for_extra: u16) u16 {
    const required_top = activity.requiredFooterTop() orelse return 0;
    return if (required_top > footer_top_for_extra) required_top - footer_top_for_extra else 0;
}

noinline fn idleFooterGapAppliesTo(kind: ?TranscriptBlockKind) bool {
    return transcript_blocks.footerBoundaryGapRowsForTail(kind) > 0;
}

fn bannerFooterGapAppliesTo(kind: ?TranscriptBlockKind) bool {
    if (kind == .tool_status) return true;
    return idleFooterGapAppliesTo(kind);
}

fn plannerCursorRow(shell: *const TranscriptRuntime, input: FooterPlannerInput) u16 {
    return if (input.transcript_state) |state| state.cursor_row else shell.cursor_row;
}

fn plannerCursorCol(shell: *const TranscriptRuntime, input: FooterPlannerInput) u16 {
    return if (input.transcript_state) |state| state.cursor_col else shell.cursor_col;
}

pub noinline fn composerTopChromeRows(input_visible: bool, appearance: render_input.InputAppearance, maxxing_mode: render_input.MaxxingMode) u16 {
    if (maxxing_mode == .minimal) return 0;
    return if (input_visible and appearance == .lines) 1 else 0;
}

test "minimal maxxing suppresses composer chrome regardless of stored appearance" {
    try std.testing.expectEqual(@as(u16, 0), composerTopChromeRows(true, .lines, .minimal));
    try std.testing.expectEqual(@as(u16, 0), composerTopChromeRows(true, .tint, .minimal));
}

fn plannerFooterReservedBaseRows(input: FooterPlannerInput) u16 {
    return footer_layout.reservedBaseRows(input.input_visible, input.composer_top_chrome_rows);
}

fn maxFooterTopForExtra(shell: *const TranscriptRuntime, input: FooterPlannerInput, extra: u16) u16 {
    const reserved: u32 = @as(u32, plannerFooterReservedBaseRows(input)) + @as(u32, extra);
    return if (@as(u32, shell.layout.rows) > reserved)
        @intCast(@as(u32, shell.layout.rows) - reserved)
    else
        1;
}

fn footerTopRowForCursor(shell: *const TranscriptRuntime, input: FooterPlannerInput, extra: u16, cursor_row: u16, cursor_col: u16) u16 {
    const max_top = maxFooterTopForExtra(shell, input, extra);
    const after_content: u16 = if (cursor_col > 1)
        @min(cursor_row +| 1, max_top)
    else
        cursor_row;
    return @min(after_content, max_top);
}

fn plannerFooterTopForExtra(shell: *const TranscriptRuntime, input: FooterPlannerInput, extra: u16) u16 {
    const cursor_top = footerTopRowForCursor(shell, input, extra, plannerCursorRow(shell, input), plannerCursorCol(shell, input));
    const state = input.transcript_state orelse return cursor_top;
    if (state.selection.last_visible_row == 0) return cursor_top;

    const max_top = maxFooterTopForExtra(shell, input, extra);
    const transcript_clearance = state.selection.last_visible_row +| state.bottom_reserved_rows +| 1;
    return @max(cursor_top, @min(transcript_clearance, max_top));
}

fn plannerFooterExtraRows(shell: *const TranscriptRuntime, input: FooterPlannerInput) u16 {
    return input.footer_extra_rows orelse shell.extra_input_rows;
}

fn plannerLastReservedRows(shell: *const TranscriptRuntime, input: FooterPlannerInput) u16 {
    return if (input.transcript_state) |state| state.bottom_reserved_rows else shell.last_paint_bottom_reserved_rows;
}

fn plannerGapOffset(
    shell: *const TranscriptRuntime,
    input: FooterPlannerInput,
    extra: u16,
    comptime include_banner_tail: bool,
) u16 {
    if (input.transcript_state) |state| {
        if (state.selection.last_visible_row == 0) return 0;
        if (include_banner_tail) {
            if (!bannerFooterGapAppliesTo(state.selection.tail_kind)) return 0;
        } else if (!idleFooterGapAppliesTo(state.selection.tail_kind)) {
            return 0;
        }

        const base_top = plannerFooterTopForExtra(shell, input, extra);
        if (state.selection.last_visible_row_blank) {
            return if (@as(u32, base_top) <= @as(u32, state.selection.last_visible_row)) 1 else 0;
        }
        const adjacent_top: u32 = @as(u32, state.selection.last_visible_row) + 1;
        return if (@as(u32, base_top) <= adjacent_top) 1 else 0;
    }

    if (shell.last_visible_transcript_last_row == 0) return 0;
    if (include_banner_tail) {
        if (!bannerFooterGapAppliesTo(shell.last_visible_transcript_tail_kind)) return 0;
    } else if (!idleFooterGapAppliesTo(shell.last_visible_transcript_tail_kind)) {
        return 0;
    }

    const base_top = plannerFooterTopForExtra(shell, input, extra);
    if (shell.last_visible_transcript_last_row_blank) {
        return if (@as(u32, base_top) <= @as(u32, shell.last_visible_transcript_last_row)) 1 else 0;
    }
    const adjacent_top: u32 = @as(u32, shell.last_visible_transcript_last_row) + 1;
    return if (@as(u32, base_top) <= adjacent_top) 1 else 0;
}

fn plannerNeedsIdleFooterBottomReservation(shell: *const TranscriptRuntime, input: FooterPlannerInput) bool {
    if (input.transcript_state) |state| {
        if (shell.pending_scroll_compact) return false;
        if (state.bottom_reserved_rows > 0) return false;
        if (state.selection.last_visible_row == 0) return false;
        if (state.selection.last_visible_row_blank) return false;
        if (!idleFooterGapAppliesTo(state.selection.tail_kind)) return false;
        return state.selection.last_visible_row >= shell.layout.content_bottom;
    }
    return shell.needsIdleFooterBottomReservation();
}

fn resolvePlannerFooterRows(
    shell: *const TranscriptRuntime,
    input: FooterPlannerInput,
    footer_top_for_extra: u16,
    footer_extra_rows: u16,
    activity_offset: u16,
) FooterRows {
    return footer_layout.resolve(.{
        .footer_top_for_extra = footer_top_for_extra,
        .terminal_rows = shell.layout.rows,
        .activity_offset = activity_offset,
        .extra_input_rows = footer_extra_rows,
        .input_extra = input.input_extra,
        .input_visible = input.input_visible,
        .composer_top_chrome_rows = input.composer_top_chrome_rows,
        .picker_rows = input.picker_rows,
        .banner_active = input.banner_active,
        .banner_rows = input.banner_rows,
        .allocated_rows = input.allocated_rows,
    });
}

fn initialFooterReservation(
    shell: *const TranscriptRuntime,
    input: FooterPlannerInput,
    resolved_activity: ActivityPlacement,
    banner_activity: ActivityPlacement,
    footer_top_for_extra: u16,
    footer_extra_rows: u16,
    cursor_col: u16,
) FooterReservationPlan {
    const transient_rows = shell.transientAssistantGapRows() +| 1;
    const needs_transient_reservation = input.applied_bottom_reserved_rows == 0 and
        render_input.activityProjectionLabel(input.activity_projection) != null and
        cursor_col != 1 and
        transient_rows > 0 and
        shell.layout.content_bottom > transient_rows and
        switch (resolved_activity) {
            .none => true,
            .transient_row, .overlay_entry => false,
        };

    const idle_activity = switch (banner_activity) {
        .none, .overlay_entry => true,
        .transient_row => false,
    };
    const idle_reservation_rows: u16 = switch (banner_activity) {
        .overlay_entry => if (input.footer_gap_active) 2 else 1,
        .none => if (input.footer_gap_active) 2 else 1,
        .transient_row => 0,
    };
    const banner_idle_gap_offset: u16 = switch (banner_activity) {
        .none => if (input.footer_gap_active) plannerGapOffset(shell, input, footer_extra_rows, true) else 0,
        .overlay_entry, .transient_row => 0,
    };
    const banner_idle_needs_reservation = input.applied_bottom_reserved_rows == 0 and switch (banner_activity) {
        .none => input.footer_gap_active and
            plannerLastReservedRows(shell, input) == 0 and
            banner_idle_gap_offset > 0 and
            resolvePlannerFooterRows(
                shell,
                input,
                footer_top_for_extra,
                footer_extra_rows,
                banner_idle_gap_offset,
            ).top ==
                footer_top_for_extra,
        .overlay_entry, .transient_row => false,
    };
    const idle_bottom_needs_reservation = input.applied_bottom_reserved_rows == 0 and switch (banner_activity) {
        .none => plannerNeedsIdleFooterBottomReservation(shell, input),
        .overlay_entry, .transient_row => false,
    };
    const overlay_banner_needs_reservation = input.applied_bottom_reserved_rows == 0 and switch (banner_activity) {
        .overlay_entry => |row| blk: {
            if (!input.footer_gap_active) break :blk false;
            break :blk @as(u32, footer_top_for_extra) <= @as(u32, row) + 1;
        },
        .none, .transient_row => false,
    };

    var bottom_reserved_rows = input.applied_bottom_reserved_rows;
    var reason: BottomReservationReason = .none;
    if (needs_transient_reservation) {
        bottom_reserved_rows = transient_rows;
        reason = .transient_midline;
    } else if (idle_activity and
        (idle_bottom_needs_reservation or banner_idle_needs_reservation or overlay_banner_needs_reservation) and
        shell.layout.content_bottom > idle_reservation_rows)
    {
        bottom_reserved_rows = idle_reservation_rows;
        reason = .idle_footer_gap;
    }

    const idle_gap_offset: u16 = switch (banner_activity) {
        .none => if (input.footer_gap_active) banner_idle_gap_offset else plannerGapOffset(shell, input, footer_extra_rows, false),
        .overlay_entry => plannerGapOffset(shell, input, footer_extra_rows, false),
        .transient_row => 0,
    };
    const overlay_banner_gap: u16 = switch (banner_activity) {
        .overlay_entry => |row| blk: {
            if (!input.footer_gap_active) break :blk 0;
            break :blk if (@as(u32, footer_top_for_extra) <= @as(u32, row) + 1) 1 else 0;
        },
        .none, .transient_row => 0,
    };

    return .{
        .bottom_reserved_rows = bottom_reserved_rows,
        .reason = reason,
        .transient_rows = transient_rows,
        .activity_offset = activityFooterOffset(banner_activity, footer_top_for_extra) +| idle_gap_offset +| overlay_banner_gap,
    };
}

pub noinline fn planFooterPaint(shell: *TranscriptRuntime, input: FooterPlannerInput) FooterFramePlan {
    const cursor_row = plannerCursorRow(shell, input);
    const cursor_col = plannerCursorCol(shell, input);
    const footer_extra_rows = plannerFooterExtraRows(shell, input);
    const footer_top_for_extra = plannerFooterTopForExtra(shell, input, footer_extra_rows);
    const resolved_activity = activity_overlay.resolve(render_input.activityOverlayInput(
        shell,
        input.activity_projection,
        input.place_mid_line_active,
        cursor_row,
        cursor_col,
        footer_top_for_extra,
    ));

    var banner_activity = resolved_activity;
    activity_overlay.suppressEntryOverlayForBanner(&banner_activity, input.footer_gap_active);

    var reservation = initialFooterReservation(
        shell,
        input,
        resolved_activity,
        banner_activity,
        footer_top_for_extra,
        footer_extra_rows,
        cursor_col,
    );
    const rows = resolvePlannerFooterRows(shell, input, footer_top_for_extra, footer_extra_rows, reservation.activity_offset);

    const transient_suppressed = transientActivityOverlapsFooter(banner_activity, rows);
    reservation.reserveForSuppressedTransient(shell, input, transient_suppressed);

    const overlay_suppressed = switch (banner_activity) {
        .overlay_entry => |row| row >= rows.top,
        .none, .transient_row => false,
    };
    var activity: ActivityPlacement = if (overlay_suppressed or transient_suppressed) .none else banner_activity;
    reservation.reserveForActivity(activity.transcriptReservationRows());
    const viewport = if (input.transcript_state) |state| state.selection else currentViewportSelection(shell);
    const preserved_band: engine_paint_plan.FrameBand = if (shell.owned_top_row > 1)
        .{ .top = 1, .bottom = shell.owned_top_row - 1, .owner = .preserved_shell }
    else
        engine_paint_plan.FrameBand.empty(.preserved_shell);
    const transcript_bottom_limit = engine_paint_plan.transcriptBottomLimit(rows.top, activity, reservation.bottom_reserved_rows);
    const transcript_bottom = if (transcript_bottom_limit > 0) @min(viewport.bottom_row, transcript_bottom_limit) else 0;
    const transcript_band = if (transcript_bottom >= viewport.top_row)
        engine_paint_plan.FrameBand{ .top = viewport.top_row, .bottom = transcript_bottom, .owner = .transcript }
    else
        engine_paint_plan.FrameBand.empty(.transcript);
    suppressOverlayOutsideTranscript(&activity, transcript_band);
    const activity_band = engine_paint_plan.activityBand(activity);
    const footer_band = engine_paint_plan.FrameBand{
        .top = rows.top,
        .bottom = @min(rows.hint, shell.layout.rows),
        .owner = .footer,
    };
    const gap_bands = reservedGapBands(shell.owned_top_row, transcript_band, activity_band, footer_band);
    var invalidation = engine_paint_plan.FrameInvalidationSet.empty();
    if (shell.footer_viewport.externally_invalidated) {
        appendFooterFrameInvalidation(&invalidation, .{
            .reason = .external_clear,
            .top = rows.top,
            .bottom = @min(rows.hint, shell.layout.rows),
        });
    }
    const footer_reservation_source: engine_paint_plan.FooterReservationSource = switch (reservation.reason) {
        .none => .footer_layout,
        .transient_midline => .transient_activity,
        .idle_footer_gap => .idle_footer_gap,
    };

    return .{
        .paint = .{
            .layout = shell.layout,
            .viewport = viewport,
            .footer = rows,
            .activity = activity,
            .preserved_band = preserved_band,
            .transcript_band = transcript_band,
            .blank_band = gap_bands.before_activity,
            .activity_band = activity_band,
            .footer_gap_band = gap_bands.after_activity,
            .footer_band = footer_band,
            .invalidation = invalidation,
            .footer_clean_allowed = invalidation.isEmpty(),
            .synchronized_update = true,
            .cursor_target = .{ .row = cursor_row, .col = cursor_col, .visible = input.input_visible },
            .footer_reservation_source = footer_reservation_source,
            .bottom_reserved_rows = reservation.bottom_reserved_rows,
            .preserve_scrollback = !shell.pending_scroll_compact,
            .reset_terminal = shell.terminal_reset_pending,
        },
        .resolved_activity = resolved_activity,
        .banner_activity = banner_activity,
        .bottom_reservation_reason = reservation.reason,
        .overlay_suppressed = overlay_suppressed,
    };
}

const ReservedGapBands = struct {
    before_activity: engine_paint_plan.FrameBand = engine_paint_plan.FrameBand.empty(.gap),
    after_activity: engine_paint_plan.FrameBand = engine_paint_plan.FrameBand.empty(.gap),
};

fn reservedGapBands(
    owned_top: u16,
    transcript_band: engine_paint_plan.FrameBand,
    activity_band: engine_paint_plan.FrameBand,
    footer_band: engine_paint_plan.FrameBand,
) ReservedGapBands {
    if (footer_band.isEmpty()) return .{};
    const top = if (transcript_band.isEmpty()) owned_top else transcript_band.bottom +| 1;
    const bottom = footer_band.top - 1;
    if (top == 0 or bottom < top) return .{};
    if (activity_band.isEmpty() or activity_band.bottom < top or activity_band.top > bottom) {
        return .{ .before_activity = .{ .top = top, .bottom = bottom, .owner = .gap } };
    }

    return .{
        .before_activity = if (top < activity_band.top)
            .{ .top = top, .bottom = activity_band.top - 1, .owner = .gap }
        else
            engine_paint_plan.FrameBand.empty(.gap),
        .after_activity = if (activity_band.bottom < bottom)
            .{ .top = activity_band.bottom + 1, .bottom = bottom, .owner = .gap }
        else
            engine_paint_plan.FrameBand.empty(.gap),
    };
}

fn suppressOverlayOutsideTranscript(activity: *ActivityPlacement, transcript_band: engine_paint_plan.FrameBand) void {
    switch (activity.*) {
        .overlay_entry => |row| {
            if (!transcript_band.containsRow(row)) activity.* = .none;
        },
        .none, .transient_row => {},
    }
}

pub fn appendFooterFrameInvalidation(
    invalidation: *engine_paint_plan.FrameInvalidationSet,
    range: engine_paint_plan.FrameInvalidationRange,
) void {
    if (invalidation.appendOrCollapse(range)) |collapsed| {
        debug_trace.logf(
            "frame_plan",
            "footer_plan_invalidation_collapse incoming_reason={s} collapsed_reason={s} top={d} bottom={d}",
            .{ @tagName(range.reason), @tagName(collapsed.reason), collapsed.top, collapsed.bottom },
        );
    }
}

pub fn currentViewportSelection(shell: *const TranscriptRuntime) ViewportSelection {
    if (shell.last_viewport_selection) |selection| return clampViewportSelectionToLayout(selection, shell.layout);
    const top_row = @max(if (shell.viewport_top_row < 1) 1 else shell.viewport_top_row, shell.owned_top_row);
    return clampViewportSelectionToLayout(.{
        .top_row = top_row,
        .bottom_row = shell.layout.content_bottom,
        .start_line = shell.last_visible_transcript_start_line,
        .partial_skip_rows = shell.last_visible_transcript_partial_skip_rows,
        .line_count = 0,
        .last_visible_row = shell.last_visible_transcript_last_row,
        .last_visible_row_blank = shell.last_visible_transcript_last_row_blank,
        .tail_kind = shell.last_visible_transcript_tail_kind,
        .replaceable_start_row = shell.replaceable_row,
        .split_active = shell.last_visible_transcript_split_active,
        .split_prefix_lines = shell.last_visible_transcript_split_prefix_lines,
        .split_suffix_start_line = shell.last_visible_transcript_split_suffix_start_line,
    }, shell.layout);
}

fn clampViewportSelectionToLayout(selection: ViewportSelection, layout: Layout) ViewportSelection {
    if (layout.rows == 0 or layout.content_bottom == 0) return selection;

    const max_row = @min(layout.content_bottom, layout.rows);
    var clamped = selection;
    if (clamped.top_row == 0) clamped.top_row = 1;
    if (clamped.top_row > max_row) clamped.top_row = max_row;
    if (clamped.bottom_row < clamped.top_row) clamped.bottom_row = clamped.top_row;
    if (clamped.bottom_row > max_row) clamped.bottom_row = max_row;
    if (clamped.last_visible_row > max_row) clamped.last_visible_row = max_row;
    if (clamped.last_visible_row != 0 and clamped.last_visible_row < clamped.top_row) clamped.last_visible_row = clamped.top_row;
    if (clamped.replaceable_start_row > max_row) clamped.replaceable_start_row = max_row;
    return clamped;
}

const InputCursorPlacement = struct {
    row: u16,
    col: u16,
};

fn pushQueuedPromptBannerRows(
    alloc: Allocator,
    frame: *footer_viewport.ComposedFooterFrame,
    plan: PaintPlan,
    ctx: render_input.RenderContext,
    width: u16,
) !?InputCursorPlacement {
    if (ctx.queued_count == 0 or !plan.footer.banner_active or plan.footer.banner_rows == 0) return null;

    if (ctx.queued_prompt_cards.len == 0) {
        var painted: u16 = 0;
        var summary = try input_presentation.composeQueuedSummaryRow(
            alloc,
            ctx.queued_count,
            ctx.queued_paused,
            width,
        );
        try pushFooterBandRow(alloc, frame, plan, plan.footer.banner, &summary);
        painted +|= 1;
        if (ctx.queued_paused and painted < plan.footer.banner_rows) {
            var hint = try input_presentation.composeQueueReviewHintRow(
                alloc,
                width,
                false,
                ctx.queued_cancel_all_available,
            );
            try pushFooterBandRow(alloc, frame, plan, plan.footer.banner +| painted, &hint);
            painted +|= 1;
        }
        // A narrow footer spends its rows on content before this breathing room.
        if (painted < plan.footer.banner_rows) {
            var gap: std.ArrayList(u8) = .empty;
            try pushFooterBandRow(alloc, frame, plan, plan.footer.banner +| painted, &gap);
        }
        return null;
    }

    const hint_rows: u16 = @intFromBool(ctx.queued_paused);
    // A clamped band spends every row on prompts: the spacers are all or nothing.
    const wanted_spacer_rows = render_input.queuedCardSpacerRows(ctx);
    const spacer_rows: u16 = if (plan.footer.banner_rows >=
        render_input.queuedCardContentRows(ctx) +| hint_rows +| wanted_spacer_rows)
        wanted_spacer_rows
    else
        0;
    const card_row_budget = plan.footer.banner_rows -| hint_rows -| spacer_rows;
    var painted_card_rows: u16 = 0;
    var editor_cursor: ?InputCursorPlacement = null;
    for (ctx.queued_prompt_cards, 0..) |card, card_index| {
        if (card_index > 0) {
            if (painted_card_rows >= card_row_budget) break;
            var gap: std.ArrayList(u8) = .empty;
            try pushFooterBandRow(
                alloc,
                frame,
                plan,
                plan.footer.banner +| painted_card_rows,
                &gap,
            );
            painted_card_rows +|= 1;
        }
        if (card.editing) {
            const source = visual_layout.Source{
                .input = ctx.input.edit_state.input.items,
                .cursor = ctx.input.edit_state.cursor,
                .terminal_cols = width,
                .images = ctx.pending_images,
                .pasted_blocks = ctx.input.entities.pasted_blocks.items,
                .image_tokens = ctx.input.entities.image_tokens.items,
                .skill_tokens = ctx.input.entities.skill_tokens.items,
                .selection = if (ctx.input.edit_state.selectionRange()) |selection| .{
                    .start = selection.start,
                    .end = selection.end,
                } else null,
            };
            const summary = visual_layout.summarize(source, null);
            const remaining_rows = card_row_budget - painted_card_rows;
            const window = visual_layout.visibleWindow(
                summary.cursor.row_index,
                summary.total_rows,
                remaining_rows,
            );
            var input_rows = try input_presentation.composeVisibleInputRows(
                alloc,
                source,
                window,
                if (ctx.maxxing_mode == .minimal) .lines else ctx.input_appearance,
                if (ctx.maxxing_mode == .minimal) .rail else .arrow,
            );
            defer input_rows.deinit(alloc);

            for (input_rows.rows.items, 0..) |*input_row, row_index| {
                if (painted_card_rows >= card_row_budget) break;
                const target_row = plan.footer.banner +| painted_card_rows;
                try pushFooterBandRow(alloc, frame, plan, target_row, input_row);
                if (window.first_row + row_index == summary.cursor.row_index) {
                    editor_cursor = .{
                        .row = target_row,
                        .col = visual_layout.terminalColumn(summary.cursor, width),
                    };
                }
                painted_card_rows +|= 1;
            }
            if (painted_card_rows >= card_row_budget) break;
            continue;
        }

        var start: usize = 0;
        while (start < card.bytes.len and painted_card_rows < card_row_budget) {
            const remaining = card.bytes[start..];
            const newline = std.mem.findScalar(u8, remaining, '\n') orelse remaining.len;
            if (newline > 0) {
                var row: std.ArrayList(u8) = .empty;
                try row.appendSlice(alloc, remaining[0..newline]);
                try pushFooterBandRow(
                    alloc,
                    frame,
                    plan,
                    plan.footer.banner +| painted_card_rows,
                    &row,
                );
                painted_card_rows +|= 1;
            }
            if (newline == remaining.len) break;
            start += newline + 1;
        }
        if (painted_card_rows >= card_row_budget) break;
    }

    const band_last_row = plan.footer.banner +| plan.footer.banner_rows -| 1;
    const closing_rows: u16 = @intFromBool(spacer_rows > 0);
    if (closing_rows > 0) {
        var gap: std.ArrayList(u8) = .empty;
        try pushFooterBandRow(alloc, frame, plan, band_last_row, &gap);
    }

    if (ctx.queued_paused) {
        const hint_row = band_last_row -| closing_rows;
        if (spacer_rows > closing_rows and hint_row > plan.footer.banner) {
            var gap: std.ArrayList(u8) = .empty;
            try pushFooterBandRow(alloc, frame, plan, hint_row -| 1, &gap);
        }
        const empty_draft = ctx.queued_editor_active and
            ctx.input.edit_state.input.items.len == 0 and
            ctx.pending_images.len == 0;
        var hint = try input_presentation.composeQueueReviewHintRow(
            alloc,
            width,
            empty_draft,
            ctx.queued_cancel_all_available,
        );
        try pushFooterBandRow(alloc, frame, plan, hint_row, &hint);
    }
    return editor_cursor;
}

pub fn composeFooterFrame(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    input: FooterPlannerInput,
    plan: PaintPlan,
) !footer_viewport.ComposedFooterFrame {
    const rows = plan.footer;
    const ctx = input.ctx;
    const approval_active = input.approval != null;
    const question_projection = if (!approval_active) ctx.question else null;
    const question_active = question_projection != null;
    const appearance_active = !approval_active and !question_active and ctx.appearance_menu.active;
    const compact_command_menu = if (!approval_active and !question_active and !appearance_active)
        render_input.activeCompactCommandMenu(ctx)
    else
        null;
    const compact_command_active = compact_command_menu != null;

    if (approval_active) {
        if (input.approval.?.request.file) |file_request| {
            return composeFileApprovalFooterFrame(alloc, shell, input, plan, file_request);
        }
    }

    if (ctx.transcript_depth.active()) {
        return composeTranscriptViewerFooterFrame(alloc, shell, input, plan);
    }

    var frame = footer_viewport.ComposedFooterFrame{};
    errdefer frame.deinit(alloc);

    const queued_editor_cursor = try pushQueuedPromptBannerRows(alloc, &frame, plan, ctx, shell.layout.cols);

    const needs_top_divider = !input.input_visible or input.composer_top_chrome_rows > 0;
    if (needs_top_divider) {
        var top_divider_row = try composeComposerTopDividerRow(alloc, shell.layout.cols);
        try pushFooterBandRow(alloc, &frame, plan, rows.top_divider, &top_divider_row);
    }

    const base_row = rows.input_base;
    var cursor_row: u16 = base_row;
    var cursor_col: u16 = 1;

    if (input.input_visible) {
        const standalone_input: []const u8 = if (ctx.queued_editor_active) "" else ctx.input.edit_state.input.items;
        const standalone_cursor: usize = if (ctx.queued_editor_active) 0 else ctx.input.edit_state.cursor;
        const standalone_images: []const types.ImageAttachment = if (ctx.queued_editor_active) &.{} else ctx.pending_images;
        const standalone_pasted_blocks = if (ctx.queued_editor_active) &.{} else ctx.input.entities.pasted_blocks.items;
        const standalone_image_tokens: []const visual_layout.ImageTokenSpan = if (ctx.queued_editor_active) &.{} else ctx.input.entities.image_tokens.items;
        const standalone_skill_tokens: []const visual_layout.SkillTokenSpan = if (ctx.queued_editor_active) &.{} else ctx.input.entities.skill_tokens.items;
        const standalone_selection: ?visual_layout.RawRange = if (ctx.queued_editor_active)
            null
        else if (ctx.input.edit_state.selectionRange()) |selection| .{
            .start = selection.start,
            .end = selection.end,
        } else null;
        const cursor = try composeAndPushVisibleInputRows(alloc, &frame, plan, base_row, input.input_summary, input.input_window, .{
            .input = standalone_input,
            .cursor = standalone_cursor,
            .terminal_cols = shell.layout.cols,
            .images = standalone_images,
            .pasted_blocks = standalone_pasted_blocks,
            .image_tokens = standalone_image_tokens,
            .skill_tokens = standalone_skill_tokens,
            .selection = standalone_selection,
        }, if (ctx.maxxing_mode == .minimal) .lines else ctx.input_appearance, if (ctx.maxxing_mode == .minimal) .rail else .arrow, ctx.inline_completion_suffix);
        cursor_row = cursor.row;
        cursor_col = cursor.col;
    }
    if (queued_editor_cursor) |cursor| {
        cursor_row = cursor.row;
        cursor_col = cursor.col;
    }

    if (approval_active or question_active or appearance_active or compact_command_active or input.show_picker) {
        if (input.input_visible) {
            var picker_divider = try row_text.composeDividerRow(alloc, shell.layout.cols);
            try pushFooterBandRow(alloc, &frame, plan, rows.picker_divider, &picker_divider);
        }

        if (approval_active) {
            var approval_row_index: u16 = 0;
            while (approval_row_index < input.picker_rows) : (approval_row_index += 1) {
                var approval_row = try approval_ui.composeInlineApprovalPanelRow(
                    alloc,
                    input.approval.?,
                    shell.layout.cols,
                    shell.layout.rows,
                    approval_row_index,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + approval_row_index, &approval_row);
            }
        } else if (question_projection) |projection| {
            try pushQuestionPanelRows(alloc, &frame, plan, rows.picker_start, input.picker_rows, projection, shell.layout.cols);
        } else if (appearance_active) {
            var appearance_row_index: u16 = 0;
            while (appearance_row_index < input.picker_rows) : (appearance_row_index += 1) {
                var appearance_row = try appearance_menu_presentation.composeAppearanceMenuRow(
                    alloc,
                    ctx.appearance_menu,
                    appearance_row_index,
                    input.picker_rows,
                    shell.layout.cols,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + appearance_row_index, &appearance_row);
            }
        } else if (compact_command_menu) |menu| {
            var menu_row_index: u16 = 0;
            while (menu_row_index < input.picker_rows) : (menu_row_index += 1) {
                var menu_row = try compact_command_menu_presentation.composeCompactCommandMenuRow(
                    alloc,
                    menu,
                    menu_row_index,
                    input.picker_rows,
                    shell.layout.cols,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + menu_row_index, &menu_row);
            }
        } else if (input.picker_kind == .auth and ctx.auth_picker.active) {
            var auth_row_index: u16 = 0;
            while (auth_row_index < input.picker_rows) : (auth_row_index += 1) {
                var auth_row = try picker_presentation.composeAuthPickerRow(
                    alloc,
                    ctx.auth_picker,
                    auth_row_index,
                    input.picker_rows,
                    shell.layout.cols,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + auth_row_index, &auth_row);
            }
            if (picker_presentation.authPickerQueryCursorColumn(ctx.auth_picker, shell.layout.cols)) |column| {
                cursor_row = rows.picker_start;
                cursor_col = column;
            }
        } else if (input.picker_kind == .slash) {
            const slash_prefix = input_presentation.slashInputPrefix(ctx.slash_registry, ctx.input.edit_state.input.items);
            const count = picker_presentation.mixedSlashCompletionCount(ctx.slash_registry, slash_prefix, ctx.skills_menu.items);
            if (count > 0) {
                if (input.slash_menu_layout) |layout| {
                    var row = rows.picker_start;
                    if (layout.show_header) {
                        var header = try picker_presentation.composeSlashMenuHeaderRow(alloc, slash_prefix, layout, shell.layout.cols);
                        try pushFooterBandRow(alloc, &frame, plan, row, &header);
                        row += 1;

                        var gap: std.ArrayList(u8) = .empty;
                        try pushFooterBandRow(alloc, &frame, plan, row, &gap);
                        row += 1;
                    }

                    const column_widths = try picker_presentation.mixedSlashMenuColumnWidths(
                        ctx.slash_registry,
                        slash_prefix,
                        ctx.skills_menu.items,
                        layout.window,
                        ctx.input.slash_menu_categories,
                        ctx.auth_picker.auth_service_label,
                    );
                    var match_idx = layout.window.start;
                    while (match_idx < layout.window.end) : (match_idx += 1) {
                        var slash_row = try picker_presentation.composeSlashMenuOptionRow(
                            alloc,
                            ctx.slash_registry,
                            slash_prefix,
                            ctx.skills_menu.items,
                            match_idx,
                            match_idx == layout.selected,
                            column_widths,
                            shell.layout.cols,
                            ctx.input.slash_menu_categories,
                            ctx.auth_picker.auth_service_label,
                        );
                        try pushFooterBandRow(alloc, &frame, plan, row, &slash_row);
                        row += 1;
                    }
                } else {
                    const selected = input.picker_selection_index % count;
                    const window_start = picker_presentation.updateEdgeScrollPickerWindowStart(input.picker_window_start, count, selected, input.picker_rows);
                    const window = picker_presentation.edgeScrollPickerWindowFromStart(count, window_start, input.picker_rows);
                    const command_width = picker_presentation.mixedSlashCompletionCommandColumnWidth(ctx.slash_registry, slash_prefix, ctx.skills_menu.items, window);
                    var row = rows.picker_start;
                    var match_idx = window.start;
                    while (match_idx < window.end) : (match_idx += 1) {
                        var slash_row = try picker_presentation.composeMixedSlashCompletionOptionRow(alloc, ctx.slash_registry, slash_prefix, ctx.skills_menu.items, match_idx, match_idx == selected, input.picker_start_col, command_width, shell.layout.cols, ctx.auth_picker.auth_service_label);
                        try pushFooterBandRow(alloc, &frame, plan, row, &slash_row);
                        row += 1;
                    }
                }
            } else {
                var status_row = try picker_presentation.composePickerStatusRow(alloc, .slash, ctx.model_picker_stage, false, false, input.picker_start_col, shell.layout.cols);
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start, &status_row);
            }
        } else if (input.picker_kind == .file and input.file_picker_items.len > 0) {
            const selected = input.picker_selection_index % input.file_picker_items.len;
            const window_start = picker_presentation.updateEdgeScrollPickerWindowStart(input.picker_window_start, input.file_picker_items.len, selected, input.picker_rows);
            const window = picker_presentation.edgeScrollPickerWindowFromStart(input.file_picker_items.len, window_start, input.picker_rows);
            var row = rows.picker_start;
            for (input.file_picker_items[window.start..window.end], window.start..) |item, i| {
                var picker_row = try picker_presentation.composeFilePickerOptionRow(alloc, input.picker_start_col, item, i == selected, shell.layout.cols);
                try pushFooterBandRow(alloc, &frame, plan, row, &picker_row);
                row += 1;
            }
        } else if (input.picker_items.len > 0) {
            const selected = input.picker_selection_index % input.picker_items.len;
            const window_start = picker_presentation.updateEdgeScrollPickerWindowStart(input.picker_window_start, input.picker_items.len, selected, input.picker_rows);
            const window = picker_presentation.edgeScrollPickerWindowFromStart(input.picker_items.len, window_start, input.picker_rows);
            var row = rows.picker_start;
            for (input.picker_items[window.start..window.end], window.start..) |item, i| {
                var picker_row = try picker_presentation.composePickerOptionRow(alloc, input.picker_kind, input.picker_start_col, item, i == selected, shell.layout.cols);
                try pushFooterBandRow(alloc, &frame, plan, row, &picker_row);
                row += 1;
            }
        } else {
            var status_row = try picker_presentation.composePickerStatusRow(alloc, input.picker_kind, ctx.model_picker_stage, input.picker_loading, input.picker_failed, input.picker_start_col, shell.layout.cols);
            try pushFooterBandRow(alloc, &frame, plan, rows.picker_start, &status_row);
        }
    }

    const needs_bottom_divider = ctx.maxxing_mode == .legacy or
        !input.input_visible or approval_active or question_active or appearance_active or compact_command_active or input.show_picker;
    var bottom_row: std.ArrayList(u8) = if (needs_bottom_divider)
        try row_text.composeDividerRow(alloc, shell.layout.cols)
    else
        .empty;
    try pushFooterBandRow(alloc, &frame, plan, rows.bottom_divider, &bottom_row);

    var danger_status_visible = false;
    var hint_row = if (approval_active)
        try approval_ui.composeInlineApprovalHintRow(
            alloc,
            input.approval.?,
            shell.layout.cols,
        )
    else if (appearance_active)
        try input_presentation.composeAppearanceMenuHintRow(alloc, shell.layout.cols)
    else if (compact_command_menu) |menu|
        switch (menu) {
            .statusline => try input_presentation.composeHintRow(
                alloc,
                false,
                input.active_label,
                ctx,
                shell.layout.cols,
            ),
            else => try input_presentation.composeCompactCommandMenuHintRow(alloc, shell.layout.cols, menu),
        }
    else if (input.show_picker and input.picker_kind == .slash and input.slash_menu_layout != null)
        try input_presentation.composeSlashMenuHintRow(alloc, shell.layout.cols)
    else blk: {
        danger_status_visible = input_presentation.dangerStatusText(
            approval_active,
            ctx,
            shell.layout.cols,
        ).len > 0;
        break :blk try input_presentation.composeHintRow(
            alloc,
            approval_active,
            input.active_label,
            ctx,
            shell.layout.cols,
        );
    };
    frame.danger_status_visible = danger_status_visible;
    try pushFooterBandRow(alloc, &frame, plan, rows.hint, &hint_row);

    frame.cursor = .{ .row = cursor_row, .col = cursor_col };
    if (!input.input_visible) frame.cursor_visible = false;
    return frame;
}

fn composeTranscriptViewerFooterFrame(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    input: FooterPlannerInput,
    plan: PaintPlan,
) !footer_viewport.ComposedFooterFrame {
    var frame = footer_viewport.ComposedFooterFrame{};
    errdefer frame.deinit(alloc);
    const width = shell.layout.cols;
    const navigation = switch (input.ctx.transcript_depth) {
        .review => "Review · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close",
        .full => "Full detail · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close",
        .inline_mode => unreachable,
    };

    var navigation_row: std.ArrayList(u8) = .empty;
    try navigation_row.appendSlice(alloc, user_message_card.minimalMarkerStyle());
    try row_text.appendClipped(alloc, &navigation_row, "┃", width);
    try navigation_row.appendSlice(alloc, ui_render.reset_style);
    if (width > 1) {
        try navigation_row.append(alloc, ' ');
        try navigation_row.appendSlice(alloc, ui_render.statusline_style);
        try row_text.appendSingleLineEllipsized(alloc, &navigation_row, navigation, width - 2);
        try navigation_row.appendSlice(alloc, ui_render.reset_style);
    }
    try pushFooterBandRow(
        alloc,
        &frame,
        plan,
        plan.footer.top_divider,
        &navigation_row,
    );

    var gap_row: std.ArrayList(u8) = .empty;
    try pushFooterBandRow(
        alloc,
        &frame,
        plan,
        plan.footer.bottom_divider,
        &gap_row,
    );

    var status_row = try input_presentation.composeHintRow(
        alloc,
        false,
        null,
        input.ctx,
        width,
    );
    try pushFooterBandRow(
        alloc,
        &frame,
        plan,
        plan.footer.hint,
        &status_row,
    );

    frame.cursor = .{ .row = plan.footer.hint, .col = 1 };
    frame.cursor_visible = false;
    return frame;
}

fn composeComposerTopDividerRow(
    alloc: Allocator,
    width: u16,
) !std.ArrayList(u8) {
    return row_text.composeDividerRow(alloc, width);
}

fn composeAndPushVisibleInputRows(
    alloc: Allocator,
    frame: *footer_viewport.ComposedFooterFrame,
    plan: PaintPlan,
    base_row: u16,
    summary: visual_layout.Summary,
    window: visual_layout.VisibleWindow,
    source: visual_layout.Source,
    appearance: render_input.InputAppearance,
    prefix_style: input_presentation.ComposerPrefixStyle,
    inline_completion_suffix: []const u8,
) !InputCursorPlacement {
    const visible_count_u16: u16 = @intCast(@min(window.row_count, std.math.maxInt(u16)));
    var placement = InputCursorPlacement{ .row = base_row, .col = visual_layout.terminalColumn(summary.cursor, source.terminal_cols) };
    if (summary.cursor.row_index >= window.first_row and summary.cursor.row_index < window.first_row + window.row_count) {
        const cursor_index: u16 = @intCast(summary.cursor.row_index - window.first_row);
        placement.row = base_row - (visible_count_u16 - 1 - cursor_index);
    }

    var rows = try input_presentation.composeVisibleInputRows(alloc, source, window, appearance, prefix_style);
    defer rows.deinit(alloc);
    if (inline_completion_suffix.len > 0 and
        summary.cursor.row_index >= window.first_row and
        summary.cursor.row_index < window.first_row + window.row_count)
    {
        const cursor_index = summary.cursor.row_index - window.first_row;
        try input_presentation.appendInlineCompletionSuffix(
            alloc,
            &rows.rows.items[cursor_index],
            source.terminal_cols,
            inline_completion_suffix,
            appearance,
        );
    }

    var line_idx: u16 = 0;
    for (rows.rows.items) |*input_row| {
        const row = base_row - (visible_count_u16 - 1 - line_idx);
        try pushFooterBandRow(alloc, frame, plan, row, input_row);
        line_idx += 1;
    }
    return placement;
}

fn composeInputRowsSnapshot(
    alloc: Allocator,
    input: []const u8,
    cursor: usize,
    images: []const types.ImageAttachment,
    width: u16,
    row_limit: usize,
) ![]u8 {
    const source = visual_layout.Source{ .input = input, .cursor = cursor, .terminal_cols = width, .images = images };
    const summary = visual_layout.summarize(source, null);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, row_limit);
    var rows = try input_presentation.composeVisibleInputRows(alloc, source, window, .lines, .arrow);
    defer rows.deinit(alloc);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (rows.rows.items, 0..) |row, i| {
        if (i > 0) try out.append(alloc, '\n');
        try out.appendSlice(alloc, row.items);
    }
    return try out.toOwnedSlice(alloc);
}

fn pushFooterBandRow(
    alloc: Allocator,
    frame: *footer_viewport.ComposedFooterFrame,
    plan: PaintPlan,
    row: u16,
    text: *std.ArrayList(u8),
) !void {
    if (!plan.footer_band.isEmpty() and !plan.footer_band.containsRow(row)) {
        text.deinit(alloc);
        text.* = .empty;
        return;
    }
    try frame.pushComposedRow(alloc, row, text);
}

fn composeFileApprovalFooterFrame(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    input: FooterPlannerInput,
    plan: PaintPlan,
    request: permission_request.FileApprovalRequest,
) !footer_viewport.ComposedFooterFrame {
    var frame = footer_viewport.ComposedFooterFrame{};
    errdefer frame.deinit(alloc);

    _ = try pushQueuedPromptBannerRows(alloc, &frame, plan, input.ctx, shell.layout.cols);

    const profile_top = plan.footer.top_divider;
    const allocated_rows = plan.footer.hint - profile_top + 1;
    const projection = approval_ui.projectFileApproval(request, input.approval.?.choice_index, shell.layout.cols, allocated_rows);
    for (projection.slice(), 0..) |kind, row_index| {
        var row = try approval_ui.composeFileApprovalRow(
            alloc,
            request,
            &projection,
            input.approval.?.choice_index,
            input.approval,
            shell.layout.cols,
            kind,
        );
        try pushFooterBandRow(alloc, &frame, plan, profile_top + @as(u16, @intCast(row_index)), &row);
    }

    frame.cursor = .{ .row = plan.footer.hint, .col = 1 };
    frame.cursor_visible = false;
    return frame;
}

fn pushQuestionPanelRows(
    alloc: Allocator,
    frame: *footer_viewport.ComposedFooterFrame,
    plan: PaintPlan,
    start_row: u16,
    row_count: u16,
    projection: question_state.Projection,
    width: u16,
) !void {
    const text = try question_ui.composeQuestionPanelText(alloc, projection, width);
    defer alloc.free(text);

    var line_start: usize = 0;
    var row_index: u16 = 0;
    while (row_index < row_count) : (row_index += 1) {
        const line = question_ui.nextPanelLine(text, &line_start);
        var row: std.ArrayList(u8) = .empty;
        try row_text.appendClipped(alloc, &row, line, width);
        try row.appendSlice(alloc, ui_render.reset_style);
        try pushFooterBandRow(alloc, frame, plan, start_row + row_index, &row);
    }
}

fn testContext(input: *const InputRuntime) render_input.RenderContext {
    return .{
        .stream = .{},
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .input = input,
    };
}

const test_tint_style = "\x1b[48;5;238m\x1b[38;5;250m";
const test_tint_bg = vt_emulator.Color{ .indexed = 238 };

fn withTestInputBarStyle() []const u8 {
    const previous = ui_render.input_bar_style;
    ui_render.input_bar_style = test_tint_style;
    return previous;
}

fn expectRowBackground(row_bytes: []const u8, width: u16, expected_bg: vt_emulator.Color) !void {
    var grid = try vt_emulator.Grid.init(std.testing.allocator, width, 2);
    defer grid.deinit();
    try grid.feed(row_bytes);

    var col: u16 = 1;
    while (col <= width) : (col += 1) {
        const cell = grid.cellAt(1, col) orelse return error.TestUnexpectedResult;
        try std.testing.expect(cell.style.bg.eql(expected_bg));
    }
}

fn expectRowDefaultBackground(row_bytes: []const u8, width: u16) !void {
    try expectRowBackground(row_bytes, width, .default);
}

fn expectFrameRowBackground(frame: *const footer_viewport.ComposedFooterFrame, row_number: u16, width: u16, expected_bg: vt_emulator.Color) !void {
    for (frame.rows.items) |row| {
        if (row.row == row_number) {
            try expectRowBackground(row.text.items, width, expected_bg);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

fn expectFrameRowDefaultBackground(frame: *const footer_viewport.ComposedFooterFrame, row_number: u16, width: u16) !void {
    try expectFrameRowBackground(frame, row_number, width, .default);
}

fn expectFrameRowTextTrimmed(frame: *const footer_viewport.ComposedFooterFrame, row_number: u16, width: u16, expected: []const u8) !void {
    for (frame.rows.items) |row| {
        if (row.row == row_number) {
            var grid = try vt_emulator.Grid.init(std.testing.allocator, width, 1);
            defer grid.deinit();
            try grid.feed(row.text.items);

            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(std.testing.allocator);
            try grid.rowTextTrimmed(1, &text);
            try std.testing.expectEqualStrings(expected, text.items);
            return;
        }
    }
    return error.TestUnexpectedResult;
}

fn expectFrameCellForeground(frame: *const footer_viewport.ComposedFooterFrame, row_number: u16, width: u16, col: u16, expected: vt_emulator.Color) !void {
    for (frame.rows.items) |row| {
        if (row.row == row_number) {
            var grid = try vt_emulator.Grid.init(std.testing.allocator, width, 1);
            defer grid.deinit();
            try grid.feed(row.text.items);

            const cell = grid.cellAt(1, col) orelse return error.TestUnexpectedResult;
            try std.testing.expect(cell.style.fg.eql(expected));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "transcript viewer footer keeps navigation blank row and aligns main status" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 12,
            .cols = 80,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 8,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);
    var ctx = testContext(&input);
    ctx.transcript_depth = .review;
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .input_visible = false,
        .composer_top_chrome_rows = 0,
        .picker_rows = 0,
        .banner_active = false,
    };
    const frame_plan = planFooterPaint(&shell, planner_input);
    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    try expectFrameRowTextTrimmed(
        &frame,
        frame_plan.paint.footer.top_divider,
        shell.layout.cols,
        "┃ Review · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close",
    );
    try expectFrameRowTextTrimmed(
        &frame,
        frame_plan.paint.footer.bottom_divider,
        shell.layout.cols,
        "",
    );
    try expectFrameRowTextTrimmed(
        &frame,
        frame_plan.paint.footer.hint,
        shell.layout.cols,
        "ask · gpt-5.1",
    );
    try std.testing.expect(!frame.cursor_visible);

    ctx.transcript_depth = .full;
    const full_input = FooterPlannerInput{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .input_visible = false,
        .composer_top_chrome_rows = 0,
        .picker_rows = 0,
        .banner_active = false,
    };
    const full_plan = planFooterPaint(&shell, full_input);
    var full_frame = try composeFooterFrame(alloc, &shell, full_input, full_plan.paint);
    defer full_frame.deinit(alloc);
    try expectFrameRowTextTrimmed(
        &full_frame,
        full_plan.paint.footer.top_divider,
        shell.layout.cols,
        "┃ Full detail · ←/→ switch · ctrl o close · PgUp/PgDn scroll · Esc close",
    );
}

test "input appearance tint colors only composed input row cells" {
    const alloc = std.testing.allocator;
    const previous_style = withTestInputBarStyle();
    defer ui_render.input_bar_style = previous_style;

    const source = visual_layout.Source{
        .input = "abc",
        .cursor = 3,
        .terminal_cols = 10,
    };
    const summary = visual_layout.summarize(source, null);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, 1);

    var line_rows = try input_presentation.composeVisibleInputRows(alloc, source, window, .lines, .arrow);
    defer line_rows.deinit(alloc);
    try expectRowDefaultBackground(line_rows.rows.items[0].items, source.terminal_cols);

    var tint_rows = try input_presentation.composeVisibleInputRows(alloc, source, window, .tint, .arrow);
    defer tint_rows.deinit(alloc);
    try expectRowBackground(tint_rows.rows.items[0].items, source.terminal_cols, test_tint_bg);

    var reset_grid = try vt_emulator.Grid.init(alloc, 10, 2);
    defer reset_grid.deinit();
    try reset_grid.feed(tint_rows.rows.items[0].items);
    try reset_grid.feed("\x1b[2;1Hz");
    const reset_cell = reset_grid.cellAt(2, 1) orelse return error.TestUnexpectedResult;
    try std.testing.expect(reset_cell.style.bg.eql(.default));
}

test "input appearance tint avoids clear-to-eol on exact-width rows" {
    const alloc = std.testing.allocator;
    const previous_style = withTestInputBarStyle();
    defer ui_render.input_bar_style = previous_style;

    const source = visual_layout.Source{
        .input = "123456",
        .cursor = 6,
        .terminal_cols = 8,
    };
    const summary = visual_layout.summarize(source, null);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, 1);

    var rows = try input_presentation.composeVisibleInputRows(alloc, source, window, .tint, .arrow);
    defer rows.deinit(alloc);

    try std.testing.expect(std.mem.indexOf(u8, rows.rows.items[0].items, "\x1b[K") == null);
    try expectRowBackground(rows.rows.items[0].items, source.terminal_cols, test_tint_bg);
}

test "input appearance tint restores row background after skill tokens" {
    const alloc = std.testing.allocator;
    const previous_style = withTestInputBarStyle();
    defer ui_render.input_bar_style = previous_style;

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "run review now");
    const start = "run ".len;
    try input.skillBindingState().bindSkillToken(alloc, start, start + "review".len, "review", "/tmp/review.md", null);

    const source = visual_layout.Source{
        .input = input.edit_state.input.items,
        .cursor = input.edit_state.input.items.len,
        .terminal_cols = 24,
        .skill_tokens = input.entities.skill_tokens.items,
    };
    const summary = visual_layout.summarize(source, null);
    const window = visual_layout.visibleWindow(summary.cursor.row_index, summary.total_rows, 1);

    var rows = try input_presentation.composeVisibleInputRows(alloc, source, window, .tint, .arrow);
    defer rows.deinit(alloc);
    try expectRowBackground(rows.rows.items[0].items, source.terminal_cols, test_tint_bg);
}

test "footer paints an inline completion suffix without moving the composer cursor" {
    const alloc = std.testing.allocator;
    ui_render.initTheme(false, null);
    defer ui_render.initTheme(false, null);

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.textReplacementState().replace(alloc, "explain $man");

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 18,
            .cols = 40,
            .content_bottom = 12,
            .divider_top_row = 13,
            .input_row = 14,
            .divider_bottom_row = 15,
            .hint_row = 16,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 8,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    var ctx = testContext(&input);
    ctx.inline_completion_suffix = "aged-menu";
    const geometry = input_presentation.measureRawInputGeometry(
        ctx,
        shell.layout.cols,
        shell.layout.content_bottom,
        true,
        false,
        false,
        false,
    );
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = geometry.input_extra,
        .input_visible = true,
        .composer_top_chrome_rows = composerTopChromeRows(true, ctx.input_appearance, ctx.maxxing_mode),
        .picker_rows = 0,
        .banner_active = false,
        .input_summary = geometry.summary,
        .input_window = geometry.window,
        .total_lines = geometry.total_lines,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    try expectFrameRowTextTrimmed(
        &frame,
        frame_plan.paint.footer.input_base,
        shell.layout.cols,
        "❯ explain $managed-menu",
    );
    try std.testing.expectEqualStrings("explain $man", input.edit_state.input.items);
    try std.testing.expectEqual(
        visual_layout.terminalColumn(geometry.summary.cursor, shell.layout.cols),
        frame.cursor.col,
    );
    try expectFrameCellForeground(
        &frame,
        frame_plan.paint.footer.input_base,
        shell.layout.cols,
        frame.cursor.col,
        .{ .indexed = 245 },
    );
}

test "input appearance tint leaves picker divider and hint rows untinted" {
    const alloc = std.testing.allocator;
    const previous_style = withTestInputBarStyle();
    defer ui_render.input_bar_style = previous_style;

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "/input ");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 18,
            .cols = 40,
            .content_bottom = 12,
            .divider_top_row = 13,
            .input_row = 14,
            .divider_bottom_row = 15,
            .hint_row = 16,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    var ctx = testContext(&input);
    ctx.input_appearance = .tint;
    const geometry = input_presentation.measureRawInputGeometry(ctx, shell.layout.cols, shell.layout.content_bottom, true, false, false, false);
    try std.testing.expect(geometry.show_slash_query);

    const picker_rows: u16 = @intCast(@min(geometry.slash_completion_count, input_presentation.max_model_picker_rows));
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = geometry.input_extra,
        .input_visible = true,
        .composer_top_chrome_rows = composerTopChromeRows(true, ctx.input_appearance, ctx.maxxing_mode),
        .picker_rows = picker_rows,
        .banner_active = false,
        .show_picker = true,
        .picker_kind = .slash,
        .slash_completion_count = geometry.slash_completion_count,
        .picker_start_col = geometry.picker_start_col,
        .input_summary = geometry.summary,
        .input_window = geometry.window,
        .total_lines = geometry.total_lines,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();

    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    try std.testing.expectEqual(frame_plan.paint.footer.top_divider, frame_plan.paint.footer.input_base);
    try expectFrameRowBackground(&frame, frame_plan.paint.footer.input_base, shell.layout.cols, test_tint_bg);
    try expectFrameRowDefaultBackground(&frame, frame_plan.paint.footer.picker_divider, shell.layout.cols);
    try expectFrameRowDefaultBackground(&frame, frame_plan.paint.footer.picker_start, shell.layout.cols);
    try expectFrameRowDefaultBackground(&frame, frame_plan.paint.footer.bottom_divider, shell.layout.cols);
    try expectFrameRowDefaultBackground(&frame, frame_plan.paint.footer.hint, shell.layout.cols);
}

test "input appearance tint collapses composer top divider row" {
    const alloc = std.testing.allocator;
    const previous_style = withTestInputBarStyle();
    defer ui_render.input_bar_style = previous_style;

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.textReplacementState().replace(alloc, "tinted");

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 18,
            .cols = 16,
            .content_bottom = 12,
            .divider_top_row = 13,
            .input_row = 14,
            .divider_bottom_row = 15,
            .hint_row = 16,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    var ctx = testContext(&input);
    ctx.input_appearance = .tint;
    const geometry = input_presentation.measureRawInputGeometry(ctx, shell.layout.cols, shell.layout.content_bottom, true, false, false, false);
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = geometry.input_extra,
        .input_visible = true,
        .composer_top_chrome_rows = composerTopChromeRows(true, ctx.input_appearance, ctx.maxxing_mode),
        .picker_rows = 0,
        .banner_active = false,
        .input_summary = geometry.summary,
        .input_window = geometry.window,
        .total_lines = geometry.total_lines,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();

    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    try std.testing.expectEqual(frame_plan.paint.footer.top_divider, frame_plan.paint.footer.input_base);
    try std.testing.expectEqual(@as(u16, 3), frame_plan.paint.footer.total_rows);
    try expectFrameRowBackground(&frame, frame_plan.paint.footer.input_base, shell.layout.cols, test_tint_bg);
    try expectFrameRowTextTrimmed(&frame, frame_plan.paint.footer.bottom_divider, shell.layout.cols, "────────────────");
}

test "input appearance tint keeps multiline input rows contiguous" {
    const alloc = std.testing.allocator;
    const previous_style = withTestInputBarStyle();
    defer ui_render.input_bar_style = previous_style;

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.textReplacementState().replace(alloc, "first\nsecond");

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 18,
            .cols = 24,
            .content_bottom = 12,
            .divider_top_row = 13,
            .input_row = 14,
            .divider_bottom_row = 15,
            .hint_row = 16,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    var ctx = testContext(&input);
    ctx.input_appearance = .tint;
    const geometry = input_presentation.measureRawInputGeometry(ctx, shell.layout.cols, shell.layout.content_bottom, true, false, false, false);
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = geometry.input_extra,
        .input_visible = true,
        .composer_top_chrome_rows = composerTopChromeRows(true, ctx.input_appearance, ctx.maxxing_mode),
        .picker_rows = 0,
        .footer_extra_rows = geometry.input_extra,
        .banner_active = false,
        .input_summary = geometry.summary,
        .input_window = geometry.window,
        .total_lines = geometry.total_lines,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();

    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    try std.testing.expectEqual(@as(u16, 0), frame_plan.paint.footer.composer_top_chrome_rows);
    try std.testing.expectEqual(frame_plan.paint.footer.top_divider + 1, frame_plan.paint.footer.input_base);
    try expectFrameRowBackground(&frame, frame_plan.paint.footer.top_divider, shell.layout.cols, test_tint_bg);
    try expectFrameRowBackground(&frame, frame_plan.paint.footer.input_base, shell.layout.cols, test_tint_bg);
    try expectFrameRowTextTrimmed(&frame, frame_plan.paint.footer.bottom_divider, shell.layout.cols, "────────────────────────");
}

test "input appearance tint places queued banner directly above input" {
    const alloc = std.testing.allocator;
    const previous_style = withTestInputBarStyle();
    defer ui_render.input_bar_style = previous_style;

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.textReplacementState().replace(alloc, "queued");

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 18,
            .cols = 24,
            .content_bottom = 12,
            .divider_top_row = 13,
            .input_row = 14,
            .divider_bottom_row = 15,
            .hint_row = 16,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    var ctx = testContext(&input);
    ctx.input_appearance = .tint;
    ctx.queued_count = 1;
    const geometry = input_presentation.measureRawInputGeometry(ctx, shell.layout.cols, shell.layout.content_bottom, true, false, false, false);
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = geometry.input_extra,
        .input_visible = true,
        .composer_top_chrome_rows = composerTopChromeRows(true, ctx.input_appearance, ctx.maxxing_mode),
        .picker_rows = 0,
        .footer_extra_rows = geometry.input_extra + 1,
        .banner_active = true,
        .banner_rows = 1,
        .footer_gap_active = true,
        .input_summary = geometry.summary,
        .input_window = geometry.window,
        .total_lines = geometry.total_lines,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();

    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    try std.testing.expectEqual(frame_plan.paint.footer.banner + 1, frame_plan.paint.footer.input_base);
    try std.testing.expectEqual(frame_plan.paint.footer.top_divider, frame_plan.paint.footer.input_base);
    try expectFrameRowDefaultBackground(&frame, frame_plan.paint.footer.banner, shell.layout.cols);
    try expectFrameRowBackground(&frame, frame_plan.paint.footer.input_base, shell.layout.cols, test_tint_bg);
}

test "queued prompts collapse to a single summary row until the review opens" {
    const alloc = std.testing.allocator;

    var input = InputRuntime{};
    defer input.deinit(alloc);

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 18,
            .cols = 40,
            .content_bottom = 12,
            .divider_top_row = 13,
            .input_row = 14,
            .divider_bottom_row = 15,
            .hint_row = 16,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 8,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    var ctx = testContext(&input);
    ctx.queued_count = 2;
    const banner_rows = render_input.queuedBannerRows(ctx);
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .input_visible = true,
        .composer_top_chrome_rows = composerTopChromeRows(true, ctx.input_appearance, ctx.maxxing_mode),
        .picker_rows = 0,
        .footer_extra_rows = banner_rows,
        .banner_active = true,
        .banner_rows = banner_rows,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();
    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    const banner = frame_plan.paint.footer.banner;
    try std.testing.expectEqual(@as(u16, 2), frame_plan.paint.footer.banner_rows);
    try expectFrameRowTextTrimmed(&frame, banner, shell.layout.cols, "2 queued messages · ↑ to edit");
    try expectFrameRowTextTrimmed(&frame, banner + 1, shell.layout.cols, "");
    try std.testing.expect(frame_plan.paint.footer.input_base >= banner + 2);
}

test "a hidden paused review keeps the summary row above its hint" {
    const alloc = std.testing.allocator;

    var input = InputRuntime{};
    defer input.deinit(alloc);

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 18,
            .cols = 80,
            .content_bottom = 12,
            .divider_top_row = 13,
            .input_row = 14,
            .divider_bottom_row = 15,
            .hint_row = 16,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 8,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    var ctx = testContext(&input);
    ctx.queued_count = 1;
    ctx.queued_paused = true;
    ctx.queued_cancel_all_available = true;
    const banner_rows = render_input.queuedBannerRows(ctx);
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .input_visible = true,
        .composer_top_chrome_rows = composerTopChromeRows(true, ctx.input_appearance, ctx.maxxing_mode),
        .picker_rows = 0,
        .footer_extra_rows = banner_rows,
        .banner_active = true,
        .banner_rows = banner_rows,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();
    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    const banner = frame_plan.paint.footer.banner;
    try std.testing.expectEqual(@as(u16, 3), frame_plan.paint.footer.banner_rows);
    try expectFrameRowTextTrimmed(&frame, banner, shell.layout.cols, "1 queued message");
    try expectFrameRowTextTrimmed(
        &frame,
        banner + 1,
        shell.layout.cols,
        "paused · enter to send · press esc to cancel all queued",
    );
    try expectFrameRowTextTrimmed(&frame, banner + 2, shell.layout.cols, "");
}

test "queued prompt cards stack above the composer with a paused hint" {
    const alloc = std.testing.allocator;

    var input = InputRuntime{};
    defer input.deinit(alloc);

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 30,
            .cols = 24,
            .content_bottom = 20,
            .divider_top_row = 25,
            .input_row = 26,
            .divider_bottom_row = 27,
            .hint_row = 28,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 8,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    const first = try user_message_card.buildUserPromptCard(alloc, "first queued", &.{}, shell.layout.cols);
    defer alloc.free(first);
    const second = try user_message_card.buildUserPromptCard(alloc, "second queued\ncontinued", &.{}, shell.layout.cols);
    defer alloc.free(second);
    const cards = [_]render_input.QueuedPromptCard{
        .{ .bytes = first, .row_count = 1 },
        .{ .bytes = second, .row_count = 2 },
    };

    var ctx = testContext(&input);
    ctx.queued_count = 2;
    ctx.queued_paused = true;
    ctx.queued_prompt_cards = &cards;
    ctx.queued_prompt_card_rows = 3;
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .input_visible = true,
        .composer_top_chrome_rows = composerTopChromeRows(true, ctx.input_appearance, ctx.maxxing_mode),
        .picker_rows = 0,
        .footer_extra_rows = 7,
        .banner_active = true,
        .banner_rows = 7,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();
    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    const banner = frame_plan.paint.footer.banner;
    try expectFrameRowTextTrimmed(&frame, banner, shell.layout.cols, "❯ first queued");
    try expectFrameRowTextTrimmed(&frame, banner + 1, shell.layout.cols, "");
    try expectFrameRowTextTrimmed(&frame, banner + 2, shell.layout.cols, "❯ second queued");
    try expectFrameRowTextTrimmed(&frame, banner + 3, shell.layout.cols, "  continued");
    try expectFrameRowTextTrimmed(&frame, banner + 4, shell.layout.cols, "");
    try expectFrameRowTextTrimmed(&frame, banner + 5, shell.layout.cols, "paused · enter to send");
    try expectFrameRowTextTrimmed(&frame, banner + 6, shell.layout.cols, "");
}

test "queued editor paints and owns the cursor on its original card row" {
    const alloc = std.testing.allocator;

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.textReplacementState().replace(alloc, "second queued");

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 30,
            .cols = 24,
            .content_bottom = 20,
            .divider_top_row = 25,
            .input_row = 26,
            .divider_bottom_row = 27,
            .hint_row = 28,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 8,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    const first = try user_message_card.buildUserPromptCard(alloc, "first queued", &.{}, shell.layout.cols);
    defer alloc.free(first);
    const editing_bytes = try alloc.dupe(u8, "");
    defer alloc.free(editing_bytes);
    const cards = [_]render_input.QueuedPromptCard{
        .{ .bytes = first, .row_count = 1 },
        .{ .bytes = editing_bytes, .row_count = 1, .editing = true },
    };

    var ctx = testContext(&input);
    ctx.queued_count = 2;
    ctx.queued_paused = true;
    ctx.queued_prompt_cards = &cards;
    ctx.queued_prompt_card_rows = 2;
    ctx.queued_editor_active = true;
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .input_visible = true,
        .composer_top_chrome_rows = 0,
        .picker_rows = 0,
        .footer_extra_rows = 6,
        .banner_active = true,
        .banner_rows = 6,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();
    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    const banner = frame_plan.paint.footer.banner;
    try expectFrameRowTextTrimmed(&frame, banner, shell.layout.cols, "❯ first queued");
    try expectFrameRowTextTrimmed(&frame, banner + 1, shell.layout.cols, "");
    try expectFrameRowTextTrimmed(&frame, banner + 2, shell.layout.cols, "❯ second queued");
    try expectFrameRowTextTrimmed(&frame, banner + 3, shell.layout.cols, "");
    try expectFrameRowTextTrimmed(&frame, banner + 4, shell.layout.cols, "paused · enter to send");
    try expectFrameRowTextTrimmed(&frame, banner + 5, shell.layout.cols, "");
    try expectFrameRowTextTrimmed(&frame, frame_plan.paint.footer.input_base, shell.layout.cols, "❯");
    try std.testing.expectEqual(banner + 2, frame.cursor.row);
    try std.testing.expectEqual(@as(u16, 16), frame.cursor.col);
    try std.testing.expect(frame.cursor_visible);
    try std.testing.expect(frame.cursor.row != frame_plan.paint.footer.input_base);
}

test "queued editor follows the cursor when its draft exceeds the card budget" {
    const alloc = std.testing.allocator;

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.textReplacementState().replace(
        alloc,
        "first line\nsecond line\nthird line\nfourth line\nfifth line tail",
    );

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 30,
            .cols = 24,
            .content_bottom = 20,
            .divider_top_row = 25,
            .input_row = 26,
            .divider_bottom_row = 27,
            .hint_row = 28,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 8,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    const editing_bytes = try alloc.dupe(u8, "");
    defer alloc.free(editing_bytes);
    const cards = [_]render_input.QueuedPromptCard{
        .{ .bytes = editing_bytes, .row_count = 1, .editing = true },
    };

    var ctx = testContext(&input);
    ctx.queued_count = 1;
    ctx.queued_paused = true;
    ctx.queued_prompt_cards = &cards;
    ctx.queued_prompt_card_rows = 5;
    ctx.queued_editor_active = true;
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .input_visible = true,
        .composer_top_chrome_rows = 0,
        .picker_rows = 0,
        .footer_extra_rows = 5,
        .banner_active = true,
        .banner_rows = 5,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();
    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    // A clamped band drops the spacers and spends every row on queued content.
    const banner = frame_plan.paint.footer.banner;
    try expectFrameRowTextTrimmed(&frame, banner, shell.layout.cols, "↑ second line");
    try expectFrameRowTextTrimmed(&frame, banner + 1, shell.layout.cols, "  third line");
    try expectFrameRowTextTrimmed(&frame, banner + 2, shell.layout.cols, "  fourth line");
    try expectFrameRowTextTrimmed(&frame, banner + 3, shell.layout.cols, "  fifth line tail");
    try expectFrameRowTextTrimmed(&frame, banner + 4, shell.layout.cols, "paused · enter to send");
    try std.testing.expectEqual(banner + 3, frame.cursor.row);
    try std.testing.expectEqual(@as(u16, 18), frame.cursor.col);
    try std.testing.expect(frame.cursor_visible);
}

test "input appearance lines keeps both composer dividers" {
    const alloc = std.testing.allocator;
    const previous_style = withTestInputBarStyle();
    defer ui_render.input_bar_style = previous_style;

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "plain");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 18,
            .cols = 12,
            .content_bottom = 12,
            .divider_top_row = 13,
            .input_row = 14,
            .divider_bottom_row = 15,
            .hint_row = 16,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    var ctx = testContext(&input);
    ctx.input_appearance = .lines;
    const geometry = input_presentation.measureRawInputGeometry(ctx, shell.layout.cols, shell.layout.content_bottom, true, false, false, false);
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = geometry.input_extra,
        .input_visible = true,
        .picker_rows = 0,
        .banner_active = false,
        .input_summary = geometry.summary,
        .input_window = geometry.window,
        .total_lines = geometry.total_lines,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();

    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    try expectFrameRowTextTrimmed(&frame, frame_plan.paint.footer.top_divider, shell.layout.cols, "────────────");
    try expectFrameRowDefaultBackground(&frame, frame_plan.paint.footer.input_base, shell.layout.cols);
    try expectFrameRowTextTrimmed(&frame, frame_plan.paint.footer.bottom_divider, shell.layout.cols, "────────────");
}

test "minimal maxxing renders a white connected rail across composer rows" {
    const alloc = std.testing.allocator;
    ui_render.initTheme(false, null);
    defer ui_render.initTheme(false, null);
    const previous_style = withTestInputBarStyle();
    defer ui_render.input_bar_style = previous_style;

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "one\ntwo\nthree");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 18,
            .cols = 12,
            .content_bottom = 12,
            .divider_top_row = 13,
            .input_row = 14,
            .divider_bottom_row = 15,
            .hint_row = 16,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    var ctx = testContext(&input);
    ctx.input_appearance = .tint;
    ctx.maxxing_mode = .minimal;
    const geometry = input_presentation.measureRawInputGeometry(ctx, shell.layout.cols, shell.layout.content_bottom, true, false, false, false);
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = geometry.input_extra,
        .input_visible = true,
        .composer_top_chrome_rows = composerTopChromeRows(true, ctx.input_appearance, ctx.maxxing_mode),
        .picker_rows = 0,
        .banner_active = false,
        .input_summary = geometry.summary,
        .input_window = geometry.window,
        .total_lines = geometry.total_lines,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    try std.testing.expectEqual(core_input_runtime.InputAppearance.tint, ctx.input_appearance);
    try std.testing.expectEqual(@as(u16, 0), frame_plan.paint.footer.composer_top_chrome_rows);
    const first_input_row = frame_plan.paint.footer.input_base - 2;
    try expectFrameRowTextTrimmed(&frame, first_input_row, shell.layout.cols, "┃ one");
    try expectFrameRowTextTrimmed(&frame, first_input_row + 1, shell.layout.cols, "┃ two");
    try expectFrameRowTextTrimmed(&frame, frame_plan.paint.footer.input_base, shell.layout.cols, "┃ three");
    try expectFrameCellForeground(&frame, first_input_row, shell.layout.cols, 1, .{ .indexed = 255 });
    try expectFrameCellForeground(&frame, first_input_row + 1, shell.layout.cols, 1, .{ .indexed = 255 });
    try expectFrameCellForeground(&frame, frame_plan.paint.footer.input_base, shell.layout.cols, 1, .{ .indexed = 255 });
    try expectFrameCellForeground(&frame, first_input_row, shell.layout.cols, 3, .default);
    try expectFrameRowDefaultBackground(&frame, frame_plan.paint.footer.input_base, shell.layout.cols);
    try expectFrameRowTextTrimmed(&frame, frame_plan.paint.footer.bottom_divider, shell.layout.cols, "");
    try std.testing.expectEqual(@as(u16, 8), frame.cursor.col);
}

fn expectGenericPickerSelectionAtRow(
    kind: input_presentation.PickerKind,
    selection_index: usize,
    window_start: usize,
    relative_row: u16,
) !void {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 100,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    const items: []const []const u8 = &.{
        "picker item 0",
        "picker item 1",
        "picker item 2",
        "picker item 3",
        "picker item 4",
        "picker item 5",
        "picker item 6",
        "picker item 7",
        "picker item 8",
        "picker item 9",
        "picker item 10",
    };
    var file_items: [11]file_index.SearchResult = undefined;
    for (items, 0..) |item, index| {
        file_items[index] = .{ .path = item, .kind = .file, .matched_spans = &.{} };
    }
    const ctx = testContext(&input);
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .input_visible = true,
        .picker_rows = 6,
        .banner_active = false,
        .show_picker = true,
        .picker_kind = kind,
        .picker_items = if (kind == .file) &.{} else items,
        .file_picker_items = if (kind == .file) &file_items else &.{},
        .picker_selection_index = selection_index,
        .picker_window_start = window_start,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();

    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    const selected_row = frame_plan.paint.footer.picker_start + relative_row;
    const selected_style = switch (kind) {
        .model_stage => ui_render.selected_completion_style,
        else => ui_render.approval_button_inactive_style,
    };
    var saw_selected_bottom = false;
    for (frame.rows.items) |row| {
        if (row.row != selected_row) continue;
        saw_selected_bottom = saw_selected_bottom or
            std.mem.find(u8, row.text.items, selected_style) != null and
                std.mem.find(u8, row.text.items, items[selection_index]) != null;
    }
    try std.testing.expect(saw_selected_bottom);
}

fn expectGenericPickerSelectionAtBottom(kind: input_presentation.PickerKind) !void {
    try expectGenericPickerSelectionAtRow(kind, 5, 0, 5);
}

test "footer generic picker selection reaches bottom before scrolling" {
    try expectGenericPickerSelectionAtBottom(.model_stage);
    try expectGenericPickerSelectionAtBottom(.file);
}

test "footer generic picker selection moves up before reverse scrolling" {
    try expectGenericPickerSelectionAtRow(.model_stage, 5, 1, 4);
    try expectGenericPickerSelectionAtRow(.file, 5, 1, 4);
}

test "footer picker status frame owns unused reserved picker rows" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 14,
            .cols = 80,
            .content_bottom = 10,
            .divider_top_row = 11,
            .input_row = 12,
            .divider_bottom_row = 13,
            .hint_row = 14,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = testContext(&input),
        .place_mid_line_active = false,
        .input_extra = 0,
        .input_visible = true,
        .picker_rows = input_presentation.max_model_picker_rows,
        .footer_extra_rows = input_presentation.max_model_picker_rows + 1,
        .banner_active = false,
        .show_picker = true,
        .picker_kind = .model_stage,
        .picker_items = &.{},
        .picker_loading = false,
        .picker_failed = false,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();

    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    var shadow = try vt_emulator.Grid.init(alloc, shell.layout.cols, shell.layout.rows);
    defer shadow.deinit();
    try shadow.feed("\x1b[8;1Hstale picker row");

    var surface = try render_engine.frame_surface.FrameSurface.initFromShadow(alloc, frame_plan.paint, shadow);
    defer surface.deinit();
    _ = try footer_viewport.paintFooterIntoSurface(&surface, &frame);

    var target = try surface.copyToTargetGrid(alloc);
    defer target.deinit();

    var row_buf: std.ArrayList(u8) = .empty;
    defer row_buf.deinit(alloc);

    try target.rowTextTrimmed(frame_plan.paint.footer.picker_start, &row_buf);
    try std.testing.expect(std.mem.find(u8, row_buf.items, "no matching models") != null);

    var row = frame_plan.paint.footer.picker_start + 1;
    while (row < frame_plan.paint.footer.bottom_divider) : (row += 1) {
        row_buf.clearRetainingCapacity();
        try target.rowTextTrimmed(row, &row_buf);
        try std.testing.expectEqual(@as(usize, 0), row_buf.items.len);
        const cell = surface.cellAt(row, 1) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(engine_paint_plan.CellOwner.footer, cell.owner);
    }
}

test "footer paint plan keeps cursor visible during transient activity when input is visible" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    var shell = TranscriptRuntime{
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
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
    defer shell.deinit(std.testing.allocator);

    const ctx: render_input.RenderContext = .{
        .stream = .{ .active = true },
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .input = &input,
    };

    const frame_plan = planFooterPaint(&shell, .{
        .active_label = "thinking",
        .activity_projection = .{ .turn_thinking = .{ .label = "thinking" } },
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .input_visible = true,
        .picker_rows = 0,
        .banner_active = false,
    });

    switch (frame_plan.paint.activity) {
        .transient_row => {},
        .none, .overlay_entry => return error.TestUnexpectedResult,
    }
    try frame_plan.paint.validate();
    try std.testing.expectEqual(frame_plan.paint.activity.transcriptReservationRows(), frame_plan.paint.bottom_reserved_rows);
    try std.testing.expect(frame_plan.paint.cursor_target != null);
    try std.testing.expect(frame_plan.paint.cursor_target.?.visible);
}

test "approval footer composition hides cursor while rendering command prompt" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    var approval = ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, .{ .label = "terminal.exec echo permission test" }));

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 40,
            .cols = 80,
            .content_bottom = 36,
            .divider_top_row = 37,
            .input_row = 38,
            .divider_bottom_row = 39,
            .hint_row = 40,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    const ctx: render_input.RenderContext = .{
        .stream = .{},
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .input = &input,
    };
    const request = approval.request.?.view();
    const picker_rows = try approval_ui.inlineApprovalPanelRowsForCommand(
        alloc,
        request.label,
        request.command,
        shell.layout.cols,
        shell.layout.rows,
    );
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .input_visible = false,
        .picker_rows = picker_rows,
        .banner_active = false,
        .approval = approval.projection(),
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    try frame_plan.paint.validate();

    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

    try std.testing.expect(!frame.cursor_visible);

    var saw_prompt = false;
    var saw_default_reason = false;
    var saw_selected_choice = false;
    var prompt_row: ?usize = null;
    var command_row: ?usize = null;
    var choice_three_row: ?u16 = null;
    var controls_row: ?u16 = null;
    var controls_count: u8 = 0;
    for (frame.rows.items, 0..) |row, row_index| {
        saw_prompt = saw_prompt or std.mem.find(u8, row.text.items, "Would you like to run the following command?") != null;
        saw_default_reason = saw_default_reason or std.mem.find(u8, row.text.items, "fx needs your approval before running this shell command") != null;
        saw_selected_choice = saw_selected_choice or std.mem.find(u8, row.text.items, "1. Yes") != null;
        if (std.mem.find(u8, row.text.items, "Would you like to run the following command?") != null) {
            prompt_row = row_index;
        }
        if (std.mem.find(u8, row.text.items, "$ echo permission test") != null) {
            command_row = row_index;
        }
        if (std.mem.find(u8, row.text.items, "3. No") != null) {
            choice_three_row = row.row;
        }
        if (std.mem.find(u8, row.text.items, "1–3 Choose") != null) {
            controls_row = row.row;
            controls_count += 1;
            try std.testing.expect(std.mem.find(u8, row.text.items, "gpt-5.1") == null);
        }
    }
    try std.testing.expect(saw_prompt);
    try std.testing.expect(!saw_default_reason);
    try std.testing.expect(saw_selected_choice);
    try std.testing.expectEqual(prompt_row.? + 2, command_row.?);
    try std.testing.expectEqual(@as(u8, 1), controls_count);
    try std.testing.expectEqual(frame_plan.paint.footer.hint, controls_row.?);
    try std.testing.expectEqual(choice_three_row.? + 2, frame_plan.paint.footer.bottom_divider);
}

test "footer paint plan keeps compact transient activity adjacent to footer" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 46,
            .cols = 167,
            .content_bottom = 42,
            .divider_top_row = 43,
            .input_row = 44,
            .divider_bottom_row = 45,
            .hint_row = 46,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
        .last_visible_transcript_tail_kind = .user_turn,
    };
    defer shell.deinit(std.testing.allocator);
    const prompt = try std.testing.allocator.dupe(u8, "tell me a story in 200 words\n");
    try shell.entries.append(std.testing.allocator, .{
        .raw_bytes = .{ .id = 1, .bytes = prompt, .class = .unknown_raw },
    });

    const ctx: render_input.RenderContext = .{
        .stream = .{ .active = true },
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .input = &input,
    };
    const selection: ViewportSelection = .{
        .top_row = 1,
        .bottom_row = 9,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = 9,
        .last_visible_row = 9,
        .last_visible_row_blank = false,
        .tail_kind = .user_turn,
    };

    const frame_plan = planFooterPaint(&shell, .{
        .active_label = "thinking",
        .activity_projection = .{ .turn_thinking = .{ .label = "thinking" } },
        .ctx = ctx,
        .place_mid_line_active = true,
        .input_extra = 0,
        .picker_rows = 0,
        .banner_active = false,
        .applied_bottom_reserved_rows = 2,
        .transcript_state = .{
            .selection = selection,
            .cursor_row = 10,
            .cursor_col = 1,
            .replaceable_row = 10,
            .bottom_reserved_rows = 2,
        },
    });

    try frame_plan.paint.validate();
    try std.testing.expectEqual(@as(u16, 9), frame_plan.paint.transcript_band.bottom);
    try std.testing.expectEqual(@as(u16, 11), frame_plan.paint.activity_band.top);
    try std.testing.expectEqual(@as(u16, 13), frame_plan.paint.footer_band.top);
    try std.testing.expect(frame_plan.paint.invalidation.isEmpty());
}

test "footer paint plan owns reserved idle gap row without invalidation" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 45,
            .cols = 168,
            .content_bottom = 41,
            .divider_top_row = 42,
            .input_row = 43,
            .divider_bottom_row = 44,
            .hint_row = 45,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 41,
        .cursor_col = 1,
        .last_visible_transcript_last_row = 40,
        .last_visible_transcript_tail_kind = .assistant_turn,
        .last_viewport_selection = .{
            .top_row = 1,
            .bottom_row = 40,
            .start_line = 3,
            .partial_skip_rows = 0,
            .line_count = 43,
            .last_visible_row = 40,
            .tail_kind = .assistant_turn,
        },
    };
    defer shell.deinit(std.testing.allocator);

    const ctx: render_input.RenderContext = .{
        .stream = .{},
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .input = &input,
    };

    const frame_plan = planFooterPaint(&shell, .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .picker_rows = 0,
        .banner_active = false,
        .applied_bottom_reserved_rows = 1,
    });

    try frame_plan.paint.validate();
    try std.testing.expectEqual(@as(u16, 40), frame_plan.paint.transcript_band.bottom);
    try std.testing.expectEqual(
        engine_paint_plan.FrameBand{ .top = 41, .bottom = 41, .owner = .gap },
        frame_plan.paint.blank_band,
    );
    try std.testing.expectEqual(@as(u16, 42), frame_plan.paint.footer_band.top);
    try std.testing.expect(frame_plan.paint.invalidation.isEmpty());
}

test "footer paint plan uses transcript preview for idle reservation" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 45,
            .cols = 168,
            .content_bottom = 41,
            .divider_top_row = 42,
            .input_row = 43,
            .divider_bottom_row = 44,
            .hint_row = 45,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
        .last_visible_transcript_last_row = 10,
        .last_visible_transcript_tail_kind = .user_turn,
    };
    defer shell.deinit(std.testing.allocator);

    const ctx: render_input.RenderContext = .{
        .stream = .{},
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .input = &input,
    };

    const preview_selection: ViewportSelection = .{
        .top_row = 1,
        .bottom_row = 41,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = 41,
        .last_visible_row = 41,
        .last_visible_row_blank = false,
        .tail_kind = .assistant_turn,
    };
    const frame_plan = planFooterPaint(&shell, .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .picker_rows = 0,
        .banner_active = false,
        .transcript_state = .{
            .selection = preview_selection,
            .cursor_row = 41,
            .cursor_col = 1,
            .replaceable_row = 41,
            .bottom_reserved_rows = 0,
        },
    });

    try frame_plan.paint.validate();
    try std.testing.expectEqual(BottomReservationReason.idle_footer_gap, frame_plan.bottom_reservation_reason);
    try std.testing.expectEqual(@as(u16, 1), frame_plan.paint.bottom_reserved_rows);
    try std.testing.expectEqual(@as(u16, 41), frame_plan.paint.viewport.last_visible_row);
}

test "footer paint plan keeps active tool in the transient band" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 12,
            .cols = 80,
            .content_bottom = 8,
            .divider_top_row = 9,
            .input_row = 10,
            .divider_bottom_row = 11,
            .hint_row = 12,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 8,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    var metrics = Metrics{};
    try shell.writeTranscript(alloc, &metrics, "one\ntwo\nthree\nfour\n", true);
    const status_id = try shell.appendRawTranscriptEntryClassified(alloc, "running read-only tools\n", .tool_status);

    const selection: ViewportSelection = .{
        .top_row = 1,
        .bottom_row = 8,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = 8,
        .last_visible_row = 8,
        .tail_kind = .assistant_turn,
    };
    shell.last_viewport_selection = selection;

    const ctx: render_input.RenderContext = .{
        .stream = .{},
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .activity = .{ .tool_slot = .{
            .entry_id = status_id,
            .fallback_label = "running read-only tools",
            .active = true,
            .kind = .read,
        } },
        .input = &input,
    };

    const frame_plan = planFooterPaint(&shell, .{
        .active_label = null,
        .activity_projection = ctx.activity,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .picker_rows = 0,
        .banner_active = false,
        .applied_bottom_reserved_rows = 4,
        .transcript_state = .{
            .selection = selection,
            .cursor_row = 8,
            .cursor_col = 1,
            .replaceable_row = 8,
            .bottom_reserved_rows = 4,
        },
    });

    switch (frame_plan.resolved_activity) {
        .transient_row => {},
        .none, .overlay_entry => return error.TestUnexpectedResult,
    }
    switch (frame_plan.paint.activity) {
        .transient_row => {},
        .none, .overlay_entry => return error.TestUnexpectedResult,
    }
    try frame_plan.paint.validate();
}

test "footer paint plan suppresses transient activity when footer clamps into its row" {
    var input = InputRuntime{};
    defer input.deinit(std.testing.allocator);

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 8,
            .cols = 80,
            .content_bottom = 5,
            .divider_top_row = 6,
            .input_row = 7,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 5,
        .cursor_col = 1,
    };
    defer shell.deinit(std.testing.allocator);

    const ctx: render_input.RenderContext = .{
        .stream = .{ .active = true },
        .has_credential = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .input = &input,
    };

    const frame_plan = planFooterPaint(&shell, .{
        .active_label = "thinking",
        .activity_projection = .{ .turn_thinking = .{ .label = "thinking" } },
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = 0,
        .picker_rows = 0,
        .banner_active = false,
    });

    try frame_plan.paint.validate();
    switch (frame_plan.resolved_activity) {
        .transient_row => |activity| try std.testing.expectEqual(@as(u16, 5), activity.row),
        .none, .overlay_entry => return error.TestUnexpectedResult,
    }
    switch (frame_plan.paint.activity) {
        .none => {},
        .transient_row, .overlay_entry => return error.TestUnexpectedResult,
    }
    try std.testing.expect(frame_plan.paint.activity_band.isEmpty());
    try std.testing.expectEqual(BottomReservationReason.transient_midline, frame_plan.bottom_reservation_reason);
    try std.testing.expectEqual(@as(u16, 1), frame_plan.paint.bottom_reserved_rows);
}
