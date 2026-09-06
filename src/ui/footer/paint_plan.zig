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
const compact_command_menu_presentation = @import("compact_command_menu_presentation.zig");
const input_presentation = @import("input_presentation.zig");
const interaction_state = @import("interaction_state.zig");
const picker_presentation = @import("picker_presentation.zig");
const model_menu_presentation = @import("model_menu_presentation.zig");
const skills_menu_presentation = @import("skills_menu_presentation.zig");
const help_menu_presentation = @import("help_menu_presentation.zig");
const settings_menu_presentation = @import("settings_menu_presentation.zig");
const mcp_menu_presentation = @import("mcp_menu_presentation.zig");
const resume_menu_presentation = @import("resume_menu_presentation.zig");
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
    picker_annotations: []const []const u8 = &.{},
    file_picker_items: []const file_index.SearchResult = &.{},
    picker_selection_index: usize = 0,
    picker_window_start: usize = 0,
    picker_loading: bool = false,
    picker_failed: bool = false,
    slash_completion_count: usize = 0,
    slash_menu_layout: ?picker_presentation.SlashMenuLayout = null,
    prepared_slash_menu: ?*const picker_presentation.PreparedSlashMenu = null,
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

pub noinline fn composerTopChromeRows() u16 {
    return 0;
}

test "current composer suppresses top chrome" {
    try std.testing.expectEqual(@as(u16, 0), composerTopChromeRows());
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

fn pushSteeringRows(
    alloc: Allocator,
    frame: *footer_viewport.ComposedFooterFrame,
    plan: PaintPlan,
    ctx: render_input.RenderContext,
    width: u16,
) !void {
    if (ctx.steering_messages.len == 0 or
        !plan.footer.banner_active or
        plan.footer.banner_rows == 0) return;

    const gap_rows: u16 = @intFromBool(plan.footer.banner_rows > 1);
    const steering_row_budget = plan.footer.banner_rows -| gap_rows;
    var visible_start = ctx.steering_messages.len;
    var remaining_rows = steering_row_budget;
    var oldest_row_limit: u16 = 0;
    while (visible_start > 0 and remaining_rows > 0) {
        const candidate = visible_start - 1;
        const candidate_rows = render_input.steering_message_layout(
            ctx.steering_messages[candidate],
            width,
            ctx.steering_waits_for_tool,
            render_input.max_steering_message_rows,
        ).row_count;
        visible_start = candidate;
        oldest_row_limit = @min(candidate_rows, remaining_rows);
        if (candidate_rows >= remaining_rows) break;
        remaining_rows -= candidate_rows;
    }

    var painted: u16 = 0;
    for (ctx.steering_messages[visible_start..], visible_start..) |message, index| {
        if (painted >= steering_row_budget) break;
        const row_limit = if (index == visible_start)
            oldest_row_limit
        else
            render_input.max_steering_message_rows;
        var rows = try input_presentation.composeSteeringMessageRows(
            alloc,
            message,
            width,
            row_limit,
            ctx.steering_waits_for_tool,
        );
        defer rows.deinit(alloc);
        for (rows.rows.items) |*row| {
            if (painted >= steering_row_budget) break;
            try pushFooterBandRow(
                alloc,
                frame,
                plan,
                plan.footer.banner +| painted,
                row,
            );
            painted +|= 1;
        }
    }

    if (painted < plan.footer.banner_rows) {
        var gap: std.ArrayList(u8) = .empty;
        try pushFooterBandRow(
            alloc,
            frame,
            plan,
            plan.footer.banner +| painted,
            &gap,
        );
    }
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
    const compact_command_menu = if (!approval_active and !question_active)
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

    try pushSteeringRows(alloc, &frame, plan, ctx, shell.layout.cols);

    const needs_top_divider = !input.input_visible or input.composer_top_chrome_rows > 0;
    if (needs_top_divider) {
        var top_divider_row = try composeComposerTopDividerRow(alloc, shell.layout.cols);
        try pushFooterBandRow(alloc, &frame, plan, rows.top_divider, &top_divider_row);
    }

    const base_row = rows.input_base;
    var cursor_row: u16 = base_row;
    var cursor_col: u16 = 1;

    if (input.input_visible) {
        const standalone_selection: ?visual_layout.RawRange = if (ctx.input.edit_state.selectionRange()) |selection| .{
            .start = selection.start,
            .end = selection.end,
        } else null;
        const cursor = try composeAndPushVisibleInputRows(alloc, &frame, plan, base_row, input.input_summary, input.input_window, .{
            .input = ctx.input.edit_state.input.items,
            .cursor = ctx.input.edit_state.cursor,
            .terminal_cols = shell.layout.cols,
            .images = ctx.pending_images,
            .pasted_blocks = ctx.input.entities.pasted_blocks.items,
            .image_tokens = ctx.input.entities.image_tokens.items,
            .skill_tokens = ctx.input.entities.skill_tokens.items,
            .selection = standalone_selection,
        }, ctx.inline_completion_suffix);
        cursor_row = cursor.row;
        cursor_col = cursor.col;
    }

    if (approval_active or question_active or compact_command_active or input.show_picker) {
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
        } else if (input.picker_kind == .settings and ctx.settings_menu.active) {
            var menu_row_index: u16 = 0;
            while (menu_row_index < input.picker_rows) : (menu_row_index += 1) {
                var menu_row = try settings_menu_presentation.composeSettingsMenuRow(
                    alloc,
                    ctx.settings_menu,
                    menu_row_index,
                    shell.layout.cols,
                    input.picker_rows,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + menu_row_index, &menu_row);
            }
        } else if (input.picker_kind == .mcp and ctx.mcp_menu.state.active) {
            var menu_row_index: u16 = 0;
            while (menu_row_index < input.picker_rows) : (menu_row_index += 1) {
                var menu_row = try mcp_menu_presentation.composeMcpMenuRow(
                    alloc,
                    ctx.mcp_menu,
                    menu_row_index,
                    shell.layout.cols,
                    input.picker_rows,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + menu_row_index, &menu_row);
            }
        } else if (input.picker_kind == .help and ctx.help_menu.active) {
            var menu_row_index: u16 = 0;
            while (menu_row_index < input.picker_rows) : (menu_row_index += 1) {
                var menu_row = try help_menu_presentation.composeHelpMenuRow(
                    alloc,
                    ctx.help_menu,
                    menu_row_index,
                    shell.layout.cols,
                    input.picker_rows,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + menu_row_index, &menu_row);
            }
        } else if (input.picker_kind == .sessions and ctx.session_menu.active) {
            var menu_row_index: u16 = 0;
            while (menu_row_index < input.picker_rows) : (menu_row_index += 1) {
                var menu_row = try resume_menu_presentation.composeSessionMenuRow(
                    alloc,
                    ctx.session_menu,
                    menu_row_index,
                    shell.layout.cols,
                    input.picker_rows,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + menu_row_index, &menu_row);
            }
        } else if (input.picker_kind == .models and ctx.model_menu.active) {
            var menu_row_index: u16 = 0;
            while (menu_row_index < input.picker_rows) : (menu_row_index += 1) {
                var menu_row = try model_menu_presentation.composeModelMenuRow(
                    alloc,
                    ctx.model_menu,
                    menu_row_index,
                    shell.layout.cols,
                    input.picker_rows,
                );
                try pushFooterBandRow(alloc, &frame, plan, rows.picker_start + menu_row_index, &menu_row);
            }
        } else if (input.picker_kind == .skills and ctx.skills_menu.active) {
            var prepared = try skills_menu_presentation.prepareInlineSkillsMenu(
                alloc,
                ctx.skills_menu,
                input.picker_rows,
            );
            defer prepared.deinit(alloc);
            var menu_row_index: u16 = 0;
            while (menu_row_index < prepared.rowCount()) : (menu_row_index += 1) {
                var menu_row = try skills_menu_presentation.composeSkillsMenuRow(
                    alloc,
                    prepared,
                    menu_row_index,
                    shell.layout.cols,
                );
                try pushFooterBandRow(
                    alloc,
                    &frame,
                    plan,
                    rows.picker_start + menu_row_index,
                    &menu_row,
                );
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
            const count = if (input.prepared_slash_menu) |prepared|
                prepared.resultCount()
            else
                picker_presentation.mixedSlashCompletionCount(ctx.slash_registry, slash_prefix, ctx.skills_menu.items);
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

                    const column_widths = if (input.prepared_slash_menu) |prepared|
                        picker_presentation.preparedSlashMenuColumnWidths(
                            prepared,
                            layout.window,
                            ctx.input.slash_menu_categories,
                        )
                    else
                        picker_presentation.mixedSlashMenuColumnWidths(
                            ctx.slash_registry,
                            slash_prefix,
                            ctx.skills_menu.items,
                            layout.window,
                            ctx.input.slash_menu_categories,
                        );
                    var match_idx = layout.window.start;
                    while (match_idx < layout.window.end) : (match_idx += 1) {
                        var slash_row = if (input.prepared_slash_menu) |prepared|
                            try picker_presentation.composePreparedSlashMenuOptionRow(
                                alloc,
                                prepared,
                                match_idx,
                                match_idx == layout.selected,
                                column_widths,
                                shell.layout.cols,
                                ctx.input.slash_menu_categories,
                            )
                        else
                            try picker_presentation.composeSlashMenuOptionRow(
                                alloc,
                                ctx.slash_registry,
                                slash_prefix,
                                ctx.skills_menu.items,
                                match_idx,
                                match_idx == layout.selected,
                                column_widths,
                                shell.layout.cols,
                                ctx.input.slash_menu_categories,
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
                        var slash_row = try picker_presentation.composeMixedSlashCompletionOptionRow(alloc, ctx.slash_registry, slash_prefix, ctx.skills_menu.items, match_idx, match_idx == selected, input.picker_start_col, command_width, shell.layout.cols);
                        try pushFooterBandRow(alloc, &frame, plan, row, &slash_row);
                        row += 1;
                    }
                }
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
                const annotation = if (i < input.picker_annotations.len) input.picker_annotations[i] else "";
                var picker_row = try picker_presentation.composePickerOptionRowAnnotated(alloc, input.picker_kind, input.picker_start_col, item, annotation, i == selected, shell.layout.cols);
                try pushFooterBandRow(alloc, &frame, plan, row, &picker_row);
                row += 1;
            }
        } else {
            var status_row = try picker_presentation.composePickerStatusRowWithProvider(alloc, input.picker_kind, ctx.model_picker_stage, ctx.provider_picker_stage, input.picker_loading, input.picker_failed, input.picker_start_col, shell.layout.cols);
            try pushFooterBandRow(alloc, &frame, plan, rows.picker_start, &status_row);
        }
    }

    const needs_bottom_divider = !input.input_visible or approval_active or question_active or compact_command_active or input.show_picker;
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
    else if (compact_command_menu) |menu|
        try input_presentation.composeCompactCommandMenuHintRow(alloc, shell.layout.cols, menu)
    else if (input.show_picker and input.picker_kind == .skills)
        try input_presentation.composeSkillsMenuHintRow(alloc, shell.layout.cols, ctx.ctrl_c_pending)
    else if (input.show_picker and input.picker_kind == .settings)
        try input_presentation.composeSettingsMenuHintRow(alloc, shell.layout.cols, ctx.ctrl_c_pending)
    else if (input.show_picker and input.picker_kind == .mcp)
        try input_presentation.composeMcpMenuHintRow(
            alloc,
            shell.layout.cols,
            ctx.ctrl_c_pending,
            ctx.mcp_menu,
        )
    else if (input.show_picker and input.picker_kind == .help)
        try input_presentation.composeHelpMenuHintRow(alloc, shell.layout.cols, ctx.ctrl_c_pending)
    else if (input.show_picker and input.picker_kind == .sessions)
        try input_presentation.composeResumeMenuHintRow(alloc, shell.layout.cols, ctx.ctrl_c_pending)
    else if (input.show_picker and input.picker_kind == .models)
        try input_presentation.composeModelsMenuHintRow(alloc, shell.layout.cols, ctx.ctrl_c_pending)
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
        .full => "Full detail · ctrl o close · PgUp/PgDn scroll · Esc close",
        .inline_mode => unreachable,
    };

    var navigation_row: std.ArrayList(u8) = .empty;
    try navigation_row.appendSlice(alloc, user_message_card.promptMarkerStyle());
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
    inline_completion_suffix: []const u8,
) !InputCursorPlacement {
    const visible_count_u16: u16 = @intCast(@min(window.row_count, std.math.maxInt(u16)));
    var placement = InputCursorPlacement{ .row = base_row, .col = visual_layout.terminalColumn(summary.cursor, source.terminal_cols) };
    if (summary.cursor.row_index >= window.first_row and summary.cursor.row_index < window.first_row + window.row_count) {
        const cursor_index: u16 = @intCast(summary.cursor.row_index - window.first_row);
        placement.row = base_row - (visible_count_u16 - 1 - cursor_index);
    }

    var rows = try input_presentation.composeVisibleInputRows(alloc, source, window);
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
    var rows = try input_presentation.composeVisibleInputRows(alloc, source, window);
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

    try pushSteeringRows(alloc, &frame, plan, input.ctx, shell.layout.cols);

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
        .has_api_key = true,
        .model = "gpt-5.1",
        .input = input,
    };
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

fn expectFrameRowContains(frame: *const footer_viewport.ComposedFooterFrame, row_number: u16, width: u16, expected: []const u8) !void {
    for (frame.rows.items) |row| {
        if (row.row == row_number) {
            var grid = try vt_emulator.Grid.init(std.testing.allocator, width, 1);
            defer grid.deinit();
            try grid.feed(row.text.items);

            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(std.testing.allocator);
            try grid.rowTextTrimmed(1, &text);
            try std.testing.expect(std.mem.find(u8, text.items, expected) != null);
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
    ctx.transcript_depth = .full;
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
        "┃ Full detail · ctrl o close · PgUp/PgDn scroll · Esc close",
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
        "┃ Full detail · ctrl o close · PgUp/PgDn scroll · Esc close",
    );
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
        .composer_top_chrome_rows = composerTopChromeRows(),
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
        "┃ explain $managed-menu",
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

test "steering banner keeps two clean lines and a composer gap in both delivery modes" {
    for ([_]bool{ false, true }) |waiting| {
        const alloc = std.testing.allocator;

        var input = InputRuntime{};
        defer input.deinit(alloc);

        var shell = TranscriptRuntime{
            .layout = .{
                .rows = 12,
                .cols = 48,
                .content_bottom = 6,
                .divider_top_row = 7,
                .input_row = 8,
                .divider_bottom_row = 9,
                .hint_row = 10,
            },
            .owned_top_row = 1,
            .viewport_top_row = 1,
            .cursor_row = 4,
            .cursor_col = 1,
        };
        defer shell.deinit(alloc);

        const messages = [_][]const u8{"FIRST_LINE\nSECOND_LINE\nHIDDEN_END"};
        var ctx = testContext(&input);
        ctx.steering_messages = &messages;
        ctx.steering_waits_for_tool = waiting;
        const planner_input: FooterPlannerInput = .{
            .active_label = null,
            .ctx = ctx,
            .place_mid_line_active = false,
            .input_extra = 0,
            .input_visible = true,
            .composer_top_chrome_rows = composerTopChromeRows(),
            .picker_rows = 0,
            .footer_extra_rows = 3,
            .banner_active = true,
            .banner_rows = 3,
        };

        const frame_plan = planFooterPaint(&shell, planner_input);
        var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
        defer frame.deinit(alloc);

        const banner = frame_plan.paint.footer.banner;
        try expectFrameRowContains(&frame, banner, shell.layout.cols, if (waiting) "┋ FIRST_LINE" else "FIRST_LINE");
        try expectFrameRowContains(&frame, banner + 1, shell.layout.cols, "SECOND_LINE…");
        try expectFrameRowTextTrimmed(&frame, banner + 2, shell.layout.cols, "");
        try expectFrameCellForeground(&frame, banner, shell.layout.cols, 1, .{ .indexed = if (waiting) 245 else 255 });
    }
}

test "current composer renders a white connected rail across its rows" {
    const alloc = std.testing.allocator;
    ui_render.initTheme(false, null);
    defer ui_render.initTheme(false, null);
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

    const ctx = testContext(&input);
    const geometry = input_presentation.measureRawInputGeometry(ctx, shell.layout.cols, shell.layout.content_bottom, true, false, false, false);
    const planner_input: FooterPlannerInput = .{
        .active_label = null,
        .ctx = ctx,
        .place_mid_line_active = false,
        .input_extra = geometry.input_extra,
        .input_visible = true,
        .composer_top_chrome_rows = composerTopChromeRows(),
        .picker_rows = 0,
        .banner_active = false,
        .input_summary = geometry.summary,
        .input_window = geometry.window,
        .total_lines = geometry.total_lines,
    };

    const frame_plan = planFooterPaint(&shell, planner_input);
    var frame = try composeFooterFrame(alloc, &shell, planner_input, frame_plan.paint);
    defer frame.deinit(alloc);

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
        .has_api_key = true,
        .model = "gpt-5.1",
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
    try std.testing.expect(try approval.syncRequest(alloc, .{ .label = "shell.run echo permission test" }));

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
        .has_api_key = true,
        .model = "gpt-5.1",
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
        .has_api_key = true,
        .model = "gpt-5.1",
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
        .has_api_key = true,
        .model = "gpt-5.1",
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
        .has_api_key = true,
        .model = "gpt-5.1",
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
        .has_api_key = true,
        .model = "gpt-5.1",
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
        .has_api_key = true,
        .model = "gpt-5.1",
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
