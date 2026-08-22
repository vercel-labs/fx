const std = @import("std");
const activity_status = @import("../../core/output/activity_status.zig");
const command_specs = @import("../../core/slash_commands/command_specs.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const diff_mod = @import("../../core/output/diff.zig");
const io_mod = @import("../../core/shared/io.zig");
const permission_request = @import("../../core/permissions/permission_request.zig");
const approval_prompt = @import("../../core/permissions/approval_prompt.zig");
const file_index = @import("../../core/workspace/file_index.zig");
const types = @import("../../core/shared/types.zig");
const activity_runtime = @import("../../core/output/activity_runtime.zig");
const footer_viewport = @import("viewport.zig");
const approval_ui = @import("approval_ui.zig");
const compact_command_menu_presentation = @import("compact_command_menu_presentation.zig");
const input_presentation = @import("input_presentation.zig");
const interaction_state = @import("interaction_state.zig");
const picker_presentation = @import("picker_presentation.zig");
const question_ui = @import("question_ui.zig");
const render_input = @import("render_input.zig");
const surface_invalidation = @import("surface_invalidation.zig");
const footer_paint_plan = @import("paint_plan.zig");
const core_input_runtime = @import("../../core/input/runtime.zig");
const visual_layout = @import("../input/visual_layout.zig");
const render_engine = @import("../render_engine.zig");
const render_request = @import("../render_request.zig");
const transcript_runtime = @import("../transcript/runtime.zig");

const Allocator = std.mem.Allocator;
const activity_overlay = render_engine.activity_overlay;
const footer_layout = render_engine.footer_layout;
const paint_plan = render_engine.paint_plan;
const Metrics = types.Metrics;
const ActivityProjection = activity_runtime.ActivityProjection;
const ActivityPlacement = activity_overlay.ActivityPlacement;
const FooterRows = footer_layout.FooterRows;
const FrameInvalidationSet = paint_plan.FrameInvalidationSet;
const PaintPlan = paint_plan.PaintPlan;
const ApprovalPrompt = approval_prompt.ApprovalPrompt;
const ApprovalProjection = approval_prompt.Projection;
const InputRuntime = core_input_runtime.Runtime;
const PickerKind = input_presentation.PickerKind;
const RenderContext = render_input.RenderContext;
const FooterPlannerInput = footer_paint_plan.FooterPlannerInput;
const FooterTranscriptState = footer_paint_plan.FooterTranscriptState;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

pub const SurfaceFooterReservation = struct {
    bottom_reserved_rows: u16 = 0,
    place_mid_line_active: bool = false,
    precomputed: bool = false,
    transcript_state: ?FooterTranscriptState = null,
};

pub const SurfaceFooterFrame = struct {
    paint: PaintPlan,
    composed: footer_viewport.ComposedFooterFrame,
    activity_label: std.ArrayList(u8) = .empty,
    tool_activity_label: std.ArrayList(u8) = .empty,
    shimmer_pos: i16 = -render_request.animation_padding,
    thinking_blink: ?bool = null,
    trace_paint_frame: bool = false,

    pub fn deinit(self: *SurfaceFooterFrame, alloc: Allocator) void {
        self.composed.deinit(alloc);
        self.activity_label.deinit(alloc);
        self.tool_activity_label.deinit(alloc);
    }

    pub fn label(self: *const SurfaceFooterFrame) []const u8 {
        return self.activity_label.items;
    }

    pub fn toolLabel(self: *const SurfaceFooterFrame) ?[]const u8 {
        return if (self.tool_activity_label.items.len > 0) self.tool_activity_label.items else null;
    }
};

const FooterSurfaceProjectionMode = enum {
    measurement,
    reservation,
    frame,
};

const FooterSurfaceActivity = struct {
    projection: ActivityProjection,
    active_label: ?[]const u8,

    fn resolve(
        buf: []u8,
        shell: *TranscriptRuntime,
        approval: ?ApprovalProjection,
        ctx: RenderContext,
    ) FooterSurfaceActivity {
        const projection = render_input.frameOwnedActivityProjection(buf, shell, ctx, approval);
        return .{
            .projection = projection,
            .active_label = render_input.activityProjectionLabel(projection),
        };
    }
};

const FooterSurfaceProjection = struct {
    active_label: ?[]const u8,
    activity_projection: ActivityProjection,
    input_display: []const u8,
    input_cursor: usize,
    input_summary: visual_layout.Summary,
    input_window: visual_layout.VisibleWindow,
    input_extra: u16,
    input_visible: bool,
    composer_top_chrome_rows: u16,
    picker_rows: u16,
    top_gap_rows: u16,
    footer_gap_active: bool,
    banner_active: bool,
    banner_rows: u16,
    footer_extra: u16,
    total_lines: u16,
    show_picker: bool,
    picker_kind: PickerKind,
    picker_items: []const []const u8,
    file_picker_items: []const file_index.SearchResult,
    picker_selection_index: usize,
    picker_window_start: usize,
    picker_loading: bool,
    picker_failed: bool,
    slash_completion_count: usize,
    slash_menu_layout: ?picker_presentation.SlashMenuLayout,
    picker_start_col: u16,
    file_approval_active: bool,
    allocated_rows: ?u16,

    fn framePlannerInput(
        self: *const FooterSurfaceProjection,
        ctx: RenderContext,
        approval: ?ApprovalProjection,
        place_mid_line_active: bool,
        applied_bottom_reserved_rows: u16,
        transcript_state: ?FooterTranscriptState,
    ) FooterPlannerInput {
        return .{
            .active_label = self.active_label,
            .activity_projection = self.activity_projection,
            .ctx = ctx,
            .place_mid_line_active = place_mid_line_active,
            .input_extra = self.input_extra,
            .input_visible = self.input_visible,
            .composer_top_chrome_rows = self.composer_top_chrome_rows,
            .picker_rows = self.picker_rows,
            .footer_gap_active = self.footer_gap_active,
            .banner_active = self.banner_active,
            .banner_rows = self.banner_rows,
            .footer_extra_rows = self.footer_extra,
            .allocated_rows = self.allocated_rows,
            .applied_bottom_reserved_rows = applied_bottom_reserved_rows,
            .approval = approval,
            .input_display = self.input_display,
            .input_cursor = self.input_cursor,
            .input_summary = self.input_summary,
            .input_window = self.input_window,
            .total_lines = self.total_lines,
            .show_picker = self.show_picker,
            .picker_kind = self.picker_kind,
            .picker_items = self.picker_items,
            .file_picker_items = self.file_picker_items,
            .picker_selection_index = self.picker_selection_index,
            .picker_window_start = self.picker_window_start,
            .picker_loading = self.picker_loading,
            .picker_failed = self.picker_failed,
            .slash_completion_count = self.slash_completion_count,
            .slash_menu_layout = self.slash_menu_layout,
            .picker_start_col = self.picker_start_col,
            .transcript_state = transcript_state,
        };
    }

    fn reservationPlannerInput(
        self: *const FooterSurfaceProjection,
        ctx: RenderContext,
        place_mid_line_active: bool,
        applied_bottom_reserved_rows: u16,
        transcript_state: FooterTranscriptState,
    ) FooterPlannerInput {
        return .{
            .active_label = self.active_label,
            .activity_projection = self.activity_projection,
            .ctx = ctx,
            .place_mid_line_active = place_mid_line_active,
            .input_extra = self.input_extra,
            .input_visible = self.input_visible,
            .composer_top_chrome_rows = self.composer_top_chrome_rows,
            .picker_rows = self.picker_rows,
            .slash_completion_count = self.slash_completion_count,
            .banner_active = self.banner_active,
            .banner_rows = self.banner_rows,
            .allocated_rows = self.allocated_rows,
            .applied_bottom_reserved_rows = applied_bottom_reserved_rows,
            .transcript_state = transcript_state,
        };
    }
};

const BottomReservationState = struct {
    place_mid_line_active: bool = false,
    applied_bottom_reserved_rows: u16 = 0,
};

const BottomReservationTraceAnchor = struct {
    cursor_row: u16,
    cursor_col: u16,
    last_visible_row: u16,
};

fn bottomReservationTraceAnchorFromTranscript(state: FooterTranscriptState) BottomReservationTraceAnchor {
    return .{
        .cursor_row = state.cursor_row,
        .cursor_col = state.cursor_col,
        .last_visible_row = state.selection.last_visible_row,
    };
}

fn bottomReservationTraceAnchorFromShell(shell: *const TranscriptRuntime) BottomReservationTraceAnchor {
    return .{
        .cursor_row = shell.cursor_row,
        .cursor_col = shell.cursor_col,
        .last_visible_row = shell.last_visible_transcript_last_row,
    };
}

fn activeLabelHash(active_label: ?[]const u8) u64 {
    return if (active_label) |label| std.hash.Wyhash.hash(0, label) else 0;
}

fn activeLabelLen(active_label: ?[]const u8) usize {
    return if (active_label) |label| label.len else 0;
}

fn applyPreparedTransientReservation(
    bottom_reservation: *BottomReservationState,
    frame_plan: footer_paint_plan.FooterFramePlan,
    active_label: ?[]const u8,
    trace: BottomReservationTraceAnchor,
) void {
    if (frame_plan.bottom_reservation_reason != .transient_midline) return;
    debug_trace.logf(
        "frame_plan",
        "footer_reserve_transient_rows_prepared rows={d} cursor={d},{d} label_bytes={d} label_hash={x}",
        .{
            frame_plan.paint.bottom_reserved_rows,
            trace.cursor_row,
            trace.cursor_col,
            activeLabelLen(active_label),
            activeLabelHash(active_label),
        },
    );
    bottom_reservation.place_mid_line_active = true;
    bottom_reservation.applied_bottom_reserved_rows = frame_plan.paint.bottom_reserved_rows;
}

fn replanWithBottomReservation(
    shell: *TranscriptRuntime,
    frame_plan: *footer_paint_plan.FooterFramePlan,
    bottom_reservation: BottomReservationState,
    base_input: FooterPlannerInput,
) void {
    var replanned_input = base_input;
    replanned_input.place_mid_line_active = bottom_reservation.place_mid_line_active;
    replanned_input.applied_bottom_reserved_rows = bottom_reservation.applied_bottom_reserved_rows;
    frame_plan.* = footer_paint_plan.planFooterPaint(shell, replanned_input);
}

fn applyResolvedBottomReservation(
    shell: *TranscriptRuntime,
    frame_plan: *footer_paint_plan.FooterFramePlan,
    bottom_reservation: *BottomReservationState,
    active_label: ?[]const u8,
    trace: BottomReservationTraceAnchor,
    force_redraw: *bool,
    base_input: FooterPlannerInput,
) void {
    if (frame_plan.bottom_reservation_reason == .transient_midline) {
        debug_trace.logf(
            "frame_plan",
            "footer_reserve_transient_rows rows={d} cursor={d},{d} label_bytes={d} label_hash={x}",
            .{
                frame_plan.paint.bottom_reserved_rows,
                trace.cursor_row,
                trace.cursor_col,
                activeLabelLen(active_label),
                activeLabelHash(active_label),
            },
        );
        bottom_reservation.place_mid_line_active = true;
        bottom_reservation.applied_bottom_reserved_rows = frame_plan.paint.bottom_reserved_rows;
        replanWithBottomReservation(shell, frame_plan, bottom_reservation.*, base_input);
        force_redraw.* = true;
    }

    if (frame_plan.bottom_reservation_reason != .idle_footer_gap) return;
    debug_trace.logf(
        "frame_plan",
        "footer_reserve_idle_gap rows={d} cursor={d},{d} last_row={d}",
        .{
            frame_plan.paint.bottom_reserved_rows,
            trace.cursor_row,
            trace.cursor_col,
            trace.last_visible_row,
        },
    );
    bottom_reservation.applied_bottom_reserved_rows = frame_plan.paint.bottom_reserved_rows;
    replanWithBottomReservation(shell, frame_plan, bottom_reservation.*, base_input);
    force_redraw.* = true;
}

fn queuedBannerRowsForLayout(
    ctx: RenderContext,
    terminal_rows: u16,
    input_visible: bool,
    composer_top_chrome_rows: u16,
    input_extra: u16,
) u16 {
    const requested = render_input.queuedBannerRows(ctx);
    if (requested == 0) return 0;
    const non_banner_rows: u16 = if (input_visible)
        footer_layout.reservedBaseRows(true, composer_top_chrome_rows) +| 1 +| input_extra
    else
        3;
    return @min(requested, terminal_rows -| non_banner_rows);
}

fn buildFooterSurfaceProjection(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    approval: ?ApprovalProjection,
    ctx: RenderContext,
    activity: FooterSurfaceActivity,
    mode: FooterSurfaceProjectionMode,
) !FooterSurfaceProjection {
    const viewer_active = ctx.transcript_depth.active();
    const activity_projection: ActivityProjection = if (viewer_active) .none else activity.projection;
    const active_label = if (viewer_active) null else activity.active_label;
    const approval_active = approval != null;
    const question_projection = switch (mode) {
        .reservation => null,
        .measurement, .frame => if (!viewer_active and !approval_active) ctx.question else null,
    };
    const compact_command_menu = if (!viewer_active and !approval_active and question_projection == null)
        render_input.activeCompactCommandMenu(ctx)
    else
        null;
    const compact_command_active = compact_command_menu != null;
    const modal_active = !viewer_active and switch (mode) {
        .reservation => approval_active or compact_command_active,
        .measurement, .frame => approval_active or question_projection != null or compact_command_active,
    };
    const input_visible = ctx.composer_visible and !modal_active and !viewer_active;
    const composer_top_chrome_rows = footer_paint_plan.composerTopChromeRows();
    const show_auth_picker = !viewer_active and !modal_active and !ctx.stream.active and ctx.auth_picker.active;
    const stream_suppresses_file_query = ctx.stream.active and !ctx.queued_editor_active;
    const show_model_query = !viewer_active and !show_auth_picker and !modal_active and !ctx.stream.active and ctx.model_query_active;
    const show_file_query = !viewer_active and !modal_active and !stream_suppresses_file_query and ctx.file_query_active and !show_model_query;
    const geometry = input_presentation.measureRawInputGeometry(
        ctx,
        shell.layout.cols,
        shell.layout.content_bottom,
        input_visible,
        modal_active,
        show_model_query,
        show_file_query,
    );
    const show_slash_query = !show_auth_picker and geometry.show_slash_query;
    const show_picker = show_auth_picker or show_model_query or show_file_query or show_slash_query;
    const picker_items: []const []const u8 = if (show_model_query) ctx.model_completions else &.{};
    const file_picker_items: []const file_index.SearchResult = if (show_file_query) ctx.file_completions else &.{};
    const picker_selection_index: usize = if (show_slash_query)
        ctx.input.picker.slash_completion_index
    else if (show_auth_picker)
        ctx.auth_picker.selectedIndex()
    else if (show_model_query)
        ctx.model_completion_index
    else if (show_file_query)
        ctx.file_completion_index
    else
        0;
    const picker_window_start: usize = if (show_slash_query)
        ctx.input.picker.slash_completion_window_start
    else if (show_model_query)
        ctx.model_completion_window_start
    else if (show_file_query)
        ctx.file_completion_window_start
    else
        0;
    const picker_loading: bool = if (show_model_query)
        ctx.model_completions_loading
    else if (show_file_query)
        ctx.file_completions_loading
    else
        false;
    const picker_failed: bool = if (show_model_query)
        ctx.model_completions_failed
    else if (show_file_query)
        ctx.file_completions_failed
    else
        false;
    const picker_kind: PickerKind = if (show_slash_query)
        .slash
    else if (show_auth_picker)
        .auth
    else if (show_model_query)
        .model_stage
    else if (show_file_query)
        .file
    else
        .model_stage;
    const sizing_request = if (approval) |value| value.request else null;
    const file_request = if (sizing_request) |request| request.file else null;
    const banner_rows = if (viewer_active) 0 else queuedBannerRowsForLayout(
        ctx,
        shell.layout.rows,
        input_visible,
        composer_top_chrome_rows,
        geometry.input_extra,
    );
    const banner_active = switch (mode) {
        .reservation => modal_active or banner_rows > 0,
        .measurement, .frame => banner_rows > 0,
    };
    const list_picker_rows = picker_presentation.activeListPickerReservedRows(
        shell.layout.rows,
        geometry.input_extra,
        banner_rows,
    );
    const slash_menu_layout = if (show_slash_query)
        picker_presentation.slashMenuLayout(
            ctx.slash_registry,
            input_presentation.slashInputPrefix(ctx.slash_registry, ctx.input.edit_state.input.items),
            ctx.skills_menu.items,
            picker_selection_index,
            picker_window_start,
            shell.layout.rows,
            geometry.input_extra,
            banner_rows,
        )
    else
        null;
    const picker_rows: u16 = if (sizing_request) |request|
        if (request.file) |request_file|
            approval_ui.fileApprovalPickerRows(request_file)
        else
            try inlineApprovalPanelRowsForRequest(
                alloc,
                request,
                shell.layout.cols,
                shell.layout.rows,
            )
    else if (question_projection) |projection|
        try question_ui.questionPanelRowsForLayout(alloc, projection, shell.layout.cols)
    else if (compact_command_menu) |menu|
        @min(compact_command_menu_presentation.desiredRowCount(menu), shell.layout.rows -| 3)
    else if (show_auth_picker)
        picker_presentation.authPickerReservedRows(
            ctx.auth_picker,
            shell.layout.rows,
            geometry.input_extra,
            banner_rows,
        )
    else if (slash_menu_layout) |layout|
        layout.row_count
    else if (show_slash_query and geometry.slash_completion_count == 0)
        picker_presentation.pickerRowCount(0)
    else if (show_picker)
        list_picker_rows
    else
        0;
    const allocated_rows: ?u16 = switch (mode) {
        .measurement => null,
        .reservation, .frame => if (file_request) |request|
            approval_ui.fileApprovalDesiredRows(request.preview) +| banner_rows
        else
            null,
    };
    const picker_extra: u16 = if (modal_active) picker_rows else if (show_picker) picker_rows + 1 else 0;
    return .{
        .active_label = active_label,
        .activity_projection = activity_projection,
        .input_display = if (ctx.queued_editor_active) "" else ctx.input.edit_state.input.items,
        .input_cursor = if (ctx.queued_editor_active) 0 else ctx.input.edit_state.cursor,
        .input_summary = geometry.summary,
        .input_window = geometry.window,
        .input_extra = geometry.input_extra,
        .input_visible = input_visible,
        .composer_top_chrome_rows = composer_top_chrome_rows,
        .picker_rows = picker_rows,
        .top_gap_rows = if (viewer_active or modal_active) 1 else 0,
        .footer_gap_active = !viewer_active and (modal_active or ctx.queued_count > 0),
        .banner_active = banner_active,
        .banner_rows = banner_rows,
        .footer_extra = geometry.input_extra + banner_rows + picker_extra,
        .total_lines = geometry.total_lines,
        .show_picker = show_picker,
        .picker_kind = picker_kind,
        .picker_items = picker_items,
        .file_picker_items = file_picker_items,
        .picker_selection_index = picker_selection_index,
        .picker_window_start = picker_window_start,
        .picker_loading = picker_loading,
        .picker_failed = picker_failed,
        .slash_completion_count = geometry.slash_completion_count,
        .slash_menu_layout = slash_menu_layout,
        .picker_start_col = geometry.picker_start_col,
        .file_approval_active = file_request != null,
        .allocated_rows = allocated_rows,
    };
}

fn appendActivityLabels(
    alloc: Allocator,
    primary: *std.ArrayList(u8),
    tool: *std.ArrayList(u8),
    projection: ActivityProjection,
    ctx: RenderContext,
    cols: u16,
) !void {
    var primary_buf: [256]u8 = undefined;
    try primary.appendSlice(alloc, render_input.activityFallbackLabel(&primary_buf, projection, ctx));
    try render_input.appendActivityToolLabel(alloc, tool, projection, cols);
}

const FooterFrameTraceInput = struct {
    rows: FooterRows,
    activity: ActivityPlacement,
    footer_clean_allowed: bool,
    activity_projection: ActivityProjection,
    force_redraw: bool,
};

fn recordFooterFrameTrace(
    shell: *TranscriptRuntime,
    ctx: RenderContext,
    input: FooterFrameTraceInput,
) bool {
    const activity_kind_id: u8 = switch (input.activity) {
        .none => 0,
        .transient_row => 1,
        .overlay_entry => 2,
    };
    const trace_external_invalid = !input.footer_clean_allowed and
        shell.paint_trace.transcript_log_frame;
    const footer_trace_frame = !shell.paint_trace.footer_initialized or
        shell.paint_trace.footer_top != input.rows.top or
        shell.paint_trace.footer_input_base != input.rows.input_base or
        shell.paint_trace.footer_hint != input.rows.hint or
        shell.paint_trace.footer_activity_row != input.activity.row() or
        shell.paint_trace.footer_activity_reserved != input.activity.reservedFooterRows() or
        shell.paint_trace.footer_activity_kind != activity_kind_id or
        trace_external_invalid;
    shell.paint_trace.footer_initialized = true;
    shell.paint_trace.footer_top = input.rows.top;
    shell.paint_trace.footer_input_base = input.rows.input_base;
    shell.paint_trace.footer_hint = input.rows.hint;
    shell.paint_trace.footer_activity_row = input.activity.row();
    shell.paint_trace.footer_activity_reserved = input.activity.reservedFooterRows();
    shell.paint_trace.footer_activity_kind = activity_kind_id;

    if (footer_trace_frame) {
        const activity_kind: []const u8 = switch (input.activity) {
            .none => "none",
            .transient_row => "transient",
            .overlay_entry => "overlay_entry",
        };
        var fallback_label_buf: [256]u8 = undefined;
        const label = render_input.activityFallbackLabel(&fallback_label_buf, input.activity_projection, ctx);
        debug_trace.logf(
            "frame_plan",
            "footer_layout top={d} top_divider={d} input_base={d} bottom_divider={d} hint={d} activity_kind={s} activity_row={d} activity_reserved={d} force_redraw={s} external_invalid={s} cursor={d},{d} label_bytes={d} label_hash={x}",
            .{
                input.rows.top,
                input.rows.top_divider,
                input.rows.input_base,
                input.rows.bottom_divider,
                input.rows.hint,
                activity_kind,
                input.activity.row() orelse 0,
                input.activity.reservedFooterRows(),
                if (input.force_redraw) "true" else "false",
                if (!input.footer_clean_allowed) "true" else "false",
                shell.cursor_row,
                shell.cursor_col,
                label.len,
                std.hash.Wyhash.hash(0, label),
            },
        );
    }

    return footer_trace_frame;
}

const SurfaceFooterFrameAssembly = struct {
    paint: PaintPlan,
    planner_input: FooterPlannerInput,
    activity_projection: ActivityProjection,
    trace_paint_frame: bool,
};

fn assembleSurfaceFooterFrame(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    assembly: SurfaceFooterFrameAssembly,
) !SurfaceFooterFrame {
    var paint = assembly.paint;
    var composed = try footer_paint_plan.composeFooterFrame(
        alloc,
        shell,
        assembly.planner_input,
        paint,
    );
    errdefer composed.deinit(alloc);
    if (paint.cursor_target) |cursor| {
        paint.cursor_target = .{
            .row = composed.cursor.row,
            .col = composed.cursor.col,
            .visible = cursor.visible,
        };
    }
    try paint.validate();

    var activity_label: std.ArrayList(u8) = .empty;
    errdefer activity_label.deinit(alloc);
    var tool_activity_label: std.ArrayList(u8) = .empty;
    errdefer tool_activity_label.deinit(alloc);
    try appendActivityLabels(
        alloc,
        &activity_label,
        &tool_activity_label,
        assembly.activity_projection,
        assembly.planner_input.ctx,
        shell.layout.cols,
    );

    return .{
        .paint = paint,
        .composed = composed,
        .activity_label = activity_label,
        .tool_activity_label = tool_activity_label,
        .shimmer_pos = assembly.planner_input.ctx.shimmer_pos,
        .thinking_blink = activity_status.thinkingBlinkVisible(
            assembly.planner_input.ctx.stream,
            assembly.planner_input.ctx.now_ms,
        ),
        .trace_paint_frame = assembly.trace_paint_frame,
    };
}

pub fn retargetSurfaceFooterFrame(frame: *SurfaceFooterFrame, requested_plan: PaintPlan) void {
    var plan = requested_plan;
    const old_footer = frame.paint.footer;
    for (frame.composed.rows.items) |*row| {
        row.row = retargetFooterRow(row.row, old_footer, plan.footer);
    }
    frame.composed.cursor.row = retargetFooterRow(frame.composed.cursor.row, old_footer, plan.footer);
    if (plan.cursor_target) |cursor| {
        plan.cursor_target = .{
            .row = frame.composed.cursor.row,
            .col = frame.composed.cursor.col,
            .visible = cursor.visible,
        };
    }
    frame.paint = plan;
}

fn retargetFooterRow(row: u16, old_footer: footer_layout.FooterRows, new_footer: footer_layout.FooterRows) u16 {
    if (row < old_footer.top or row > old_footer.hint) return row;
    return new_footer.top + (row - old_footer.top);
}

pub const SurfaceFooterMeasurement = struct {
    active_label: std.ArrayList(u8) = .empty,
    active_label_present: bool = false,
    activity_projection: ActivityProjection = .none,
    input_display_owned: std.ArrayList(u8) = .empty,
    input_display: []const u8 = "",
    input_cursor: usize = 0,
    input_summary: visual_layout.Summary = .{
        .total_rows = 1,
        .cursor = .{ .raw_offset = 0, .row_index = 0, .content_column = 0 },
        .anchor = null,
    },
    input_window: visual_layout.VisibleWindow = .{ .first_row = 0, .row_count = 1 },
    input_extra: u16 = 0,
    input_visible: bool = true,
    composer_top_chrome_rows: u16 = 1,
    picker_rows: u16 = 0,
    top_gap_rows: u16 = 0,
    footer_gap_active: bool = false,
    banner_active: bool = false,
    banner_rows: u16 = 0,
    footer_extra: u16 = 0,
    total_lines: u16 = 1,
    show_picker: bool = false,
    picker_kind: PickerKind = .model_stage,
    picker_items: []const []const u8 = &.{},
    file_picker_items: []const file_index.SearchResult = &.{},
    picker_selection_index: usize = 0,
    picker_window_start: usize = 0,
    picker_loading: bool = false,
    picker_failed: bool = false,
    slash_completion_count: usize = 0,
    slash_menu_layout: ?picker_presentation.SlashMenuLayout = null,
    picker_start_col: u16 = 1,
    file_approval_active: bool = false,

    pub fn deinit(self: *SurfaceFooterMeasurement, alloc: Allocator) void {
        self.active_label.deinit(alloc);
        self.input_display_owned.deinit(alloc);
    }

    fn activeLabel(self: *const SurfaceFooterMeasurement) ?[]const u8 {
        return render_input.activityProjectionLabel(self.activity_projection);
    }

    pub fn changesFooterReservation(self: *const SurfaceFooterMeasurement, shell: *const TranscriptRuntime) bool {
        return self.footer_extra != shell.extra_input_rows or
            self.footerReservedBaseRows() != shell.footer_reserved_base_rows;
    }

    pub fn replaysDisplacedTranscriptHistory(
        self: *const SurfaceFooterMeasurement,
        shell: *const TranscriptRuntime,
    ) bool {
        const measured_rows = @as(u32, self.footer_extra) +
            @as(u32, self.footerReservedBaseRows());
        const committed_rows = @as(u32, shell.extra_input_rows) +
            @as(u32, shell.footer_reserved_base_rows);
        return measured_rows > committed_rows;
    }

    pub fn frameInvalidationUpdate(self: *const SurfaceFooterMeasurement) surface_invalidation.FooterExtraUpdate {
        return .{
            .footer_extra = self.footer_extra,
            .footer_reserved_base_rows = self.footerReservedBaseRows(),
            .input_extra = self.input_extra,
            .banner_active = self.banner_active,
            .picker_rows = self.picker_rows,
            .show_picker = self.show_picker,
        };
    }

    pub noinline fn footerReservedBaseRows(self: *const SurfaceFooterMeasurement) u16 {
        return footer_layout.reservedBaseRows(self.input_visible, self.composer_top_chrome_rows);
    }

    pub noinline fn frameLayoutMeasurement(self: *const SurfaceFooterMeasurement) render_engine.frame_layout.FooterMeasurement {
        const banner_rows: u16 = if (self.banner_rows > 0) self.banner_rows else if (self.banner_active) 1 else 0;
        const picker_block_rows: u16 = if (!self.input_visible)
            self.picker_rows
        else if (self.show_picker)
            self.picker_rows +| 1
        else
            0;
        const input_rows: u16 = if (self.input_visible)
            self.footerReservedBaseRows() +| 1 +| self.input_extra
        else
            3;
        const natural_rows = input_rows +| banner_rows +| picker_block_rows;
        return .{
            .natural_rows = natural_rows,
            .min_rows = 1,
            .max_rows = natural_rows,
            .top_gap_rows = self.top_gap_rows,
            .input_rows = if (self.input_visible) self.total_lines else 0,
            .picker_rows = self.picker_rows,
            .banner_rows = banner_rows,
        };
    }

    pub noinline fn frameLayoutRows(self: *const SurfaceFooterMeasurement, terminal_rows: u16, top: u16) FooterRows {
        const banner_rows: u16 = if (self.banner_rows > 0) self.banner_rows else if (self.banner_active) 1 else 0;
        const natural_rows = self.frameLayoutMeasurement().natural_rows;
        const available_rows = if (top > 0 and top <= terminal_rows)
            terminal_rows - top + 1
        else
            1;
        return footer_layout.resolve(.{
            .footer_top_for_extra = top,
            .terminal_rows = terminal_rows,
            .activity_offset = 0,
            .extra_input_rows = self.footer_extra,
            .input_extra = self.input_extra,
            .input_visible = self.input_visible,
            .composer_top_chrome_rows = self.composer_top_chrome_rows,
            .picker_rows = self.picker_rows,
            .banner_active = self.banner_active,
            .banner_rows = banner_rows,
            .allocated_rows = if (self.file_approval_active)
                @min(natural_rows, available_rows)
            else
                null,
        });
    }

    fn plannerInput(
        self: *const SurfaceFooterMeasurement,
        ctx: RenderContext,
        approval: ?ApprovalProjection,
        place_mid_line_active: bool,
        applied_bottom_reserved_rows: u16,
        transcript_state: ?FooterTranscriptState,
        banner_active: bool,
        input_extra: u16,
        picker_rows: u16,
    ) FooterPlannerInput {
        const banner_rows: u16 = if (self.banner_rows > 0) self.banner_rows else if (banner_active) 1 else 0;
        return .{
            .active_label = self.activeLabel(),
            .activity_projection = self.activity_projection,
            .ctx = ctx,
            .place_mid_line_active = place_mid_line_active,
            .input_extra = input_extra,
            .input_visible = self.input_visible,
            .composer_top_chrome_rows = self.composer_top_chrome_rows,
            .picker_rows = picker_rows,
            .footer_gap_active = self.footer_gap_active,
            .banner_active = banner_active,
            .banner_rows = banner_rows,
            .footer_extra_rows = self.footer_extra,
            .allocated_rows = if (self.file_approval_active)
                self.frameLayoutMeasurement().natural_rows
            else
                null,
            .applied_bottom_reserved_rows = applied_bottom_reserved_rows,
            .approval = approval,
            .input_display = self.input_display,
            .input_cursor = self.input_cursor,
            .input_summary = self.input_summary,
            .input_window = self.input_window,
            .total_lines = self.total_lines,
            .show_picker = self.show_picker,
            .picker_kind = self.picker_kind,
            .picker_items = self.picker_items,
            .file_picker_items = self.file_picker_items,
            .picker_selection_index = self.picker_selection_index,
            .picker_window_start = self.picker_window_start,
            .picker_loading = self.picker_loading,
            .picker_failed = self.picker_failed,
            .slash_completion_count = self.slash_completion_count,
            .slash_menu_layout = self.slash_menu_layout,
            .picker_start_col = self.picker_start_col,
            .transcript_state = transcript_state,
        };
    }

    fn actualPlannerInput(
        self: *const SurfaceFooterMeasurement,
        ctx: RenderContext,
        approval: ?ApprovalProjection,
        place_mid_line_active: bool,
        applied_bottom_reserved_rows: u16,
        transcript_state: ?FooterTranscriptState,
    ) FooterPlannerInput {
        return self.plannerInput(
            ctx,
            approval,
            place_mid_line_active,
            applied_bottom_reserved_rows,
            transcript_state,
            self.banner_active,
            self.input_extra,
            self.picker_rows,
        );
    }
};

pub fn commandApprovalFitsInline(
    alloc: Allocator,
    label: []const u8,
    command: ?[]const u8,
    layout: types.Layout,
    queued_rows: usize,
) !bool {
    const picker_rows = try approval_ui.inlineApprovalPanelRowsForCommand(
        alloc,
        label,
        command,
        layout.cols,
        layout.rows,
    );
    const banner_rows: u16 = @intCast(@min(queued_rows, std.math.maxInt(u16)));
    const measurement = SurfaceFooterMeasurement{
        .input_visible = false,
        .picker_rows = picker_rows,
        .banner_active = banner_rows > 0,
        .banner_rows = banner_rows,
    };
    return measurement.frameLayoutMeasurement().natural_rows <= layout.rows;
}

fn inlineApprovalPanelRowsForRequest(
    alloc: Allocator,
    request: anytype,
    width: u16,
    terminal_rows: u16,
) !u16 {
    return approval_ui.inlineApprovalPanelRowsForCommand(
        alloc,
        request.label,
        request.command,
        width,
        terminal_rows,
    );
}

pub noinline fn measureSurfaceFooter(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    approval: ?ApprovalProjection,
    ctx: RenderContext,
) !SurfaceFooterMeasurement {
    var measurement = SurfaceFooterMeasurement{};
    errdefer measurement.deinit(alloc);

    var active_buf: [256]u8 = undefined;
    const activity = FooterSurfaceActivity.resolve(&active_buf, shell, approval, ctx);
    const projection = try buildFooterSurfaceProjection(
        alloc,
        shell,
        approval,
        ctx,
        activity,
        .measurement,
    );
    switch (projection.activity_projection) {
        .none => {},
        .tool_slot => |slot| {
            var copied = slot;
            if (slot.thinking_label) |label| {
                try measurement.active_label.appendSlice(alloc, label);
                measurement.active_label_present = true;
                copied.thinking_label = measurement.active_label.items;
            }
            measurement.activity_projection = .{ .tool_slot = copied };
        },
        .turn_thinking => |thinking| {
            try measurement.active_label.appendSlice(alloc, thinking.label);
            measurement.active_label_present = true;
            measurement.activity_projection = .{ .turn_thinking = .{
                .label = measurement.active_label.items,
                .tone = thinking.tone,
            } };
        },
    }

    measurement.input_display = projection.input_display;
    measurement.input_cursor = projection.input_cursor;
    measurement.input_summary = projection.input_summary;
    measurement.input_window = projection.input_window;
    measurement.total_lines = projection.total_lines;
    measurement.input_extra = projection.input_extra;
    measurement.composer_top_chrome_rows = projection.composer_top_chrome_rows;
    measurement.slash_completion_count = projection.slash_completion_count;
    measurement.slash_menu_layout = projection.slash_menu_layout;
    measurement.input_visible = projection.input_visible;
    measurement.show_picker = projection.show_picker;
    measurement.picker_items = projection.picker_items;
    measurement.file_picker_items = projection.file_picker_items;
    measurement.picker_selection_index = projection.picker_selection_index;
    measurement.picker_window_start = projection.picker_window_start;
    measurement.picker_loading = projection.picker_loading;
    measurement.picker_failed = projection.picker_failed;
    measurement.picker_kind = projection.picker_kind;
    measurement.picker_start_col = projection.picker_start_col;
    measurement.file_approval_active = projection.file_approval_active;
    measurement.picker_rows = projection.picker_rows;
    measurement.top_gap_rows = projection.top_gap_rows;
    measurement.footer_gap_active = projection.footer_gap_active;
    measurement.banner_active = projection.banner_active;
    measurement.banner_rows = projection.banner_rows;
    if (measurement.footer_gap_active) {
        switch (measurement.activity_projection) {
            .tool_slot => measurement.activity_projection = .none,
            .none, .turn_thinking => {},
        }
    }
    measurement.footer_extra = projection.footer_extra;

    return measurement;
}

pub noinline fn prepareMeasuredSurfaceFooterFrameForPlan(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    force_redraw: *bool,
    approval: ?ApprovalProjection,
    ctx: RenderContext,
    measurement: *const SurfaceFooterMeasurement,
    plan: PaintPlan,
    attempt_invalidations: FrameInvalidationSet,
) !SurfaceFooterFrame {
    var paint = plan;
    const footer_reservation_changed = measurement.changesFooterReservation(shell);
    try surface_invalidation.appendMeasuredFooterExtraInvalidation(
        shell,
        &paint,
        force_redraw,
        measurement.frameInvalidationUpdate(),
    );
    surface_invalidation.mergeAttemptInvalidations(attempt_invalidations, &paint);
    if (footer_reservation_changed) paint.footer_clean_allowed = false;
    try paint.validate();

    const footer_trace_frame = recordFooterFrameTrace(shell, ctx, .{
        .rows = paint.footer,
        .activity = paint.activity,
        .footer_clean_allowed = paint.footer_clean_allowed,
        .activity_projection = measurement.activity_projection,
        .force_redraw = force_redraw.*,
    });

    return assembleSurfaceFooterFrame(alloc, shell, .{
        .paint = paint,
        .planner_input = measurement.actualPlannerInput(
            ctx,
            approval,
            false,
            0,
            null,
        ),
        .activity_projection = measurement.activity_projection,
        .trace_paint_frame = footer_trace_frame,
    });
}

pub fn commitSurfaceFooterFrame(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    frame: *SurfaceFooterFrame,
    measurement: ?*const SurfaceFooterMeasurement,
) void {
    var geometry = footerGeometryForRows(frame.paint.footer, frame.paint.activity);
    if (measurement) |measured| {
        shell.extra_input_rows = measured.footer_extra;
        shell.footer_reserved_base_rows = measured.footerReservedBaseRows();
        const input_row_count: u16 = @intCast(@min(
            measured.input_window.row_count,
            std.math.maxInt(u16),
        ));
        if (measured.input_visible and
            input_row_count > 0 and
            geometry.input_base >= input_row_count)
        {
            geometry.input_first = geometry.input_base - (input_row_count - 1);
            geometry.input_window_first = measured.input_window.first_row;
        }
    }
    shell.footer_viewport.installComposedFrame(
        alloc,
        geometry,
        &frame.composed,
    );
    shell.footer_viewport.trace_paint_frame = frame.trace_paint_frame;
}

pub noinline fn currentSurfaceFooterTranscriptState(shell: *const TranscriptRuntime) FooterTranscriptState {
    return .{
        .selection = footer_paint_plan.currentViewportSelection(shell),
        .cursor_row = shell.cursor_row,
        .cursor_col = shell.cursor_col,
        .replaceable_row = shell.replaceable_row,
        .bottom_reserved_rows = shell.last_paint_bottom_reserved_rows,
    };
}

pub noinline fn resolveSurfaceFooterReservation(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    force_redraw: *bool,
    approval: ?ApprovalProjection,
    ctx: RenderContext,
    transcript_state: FooterTranscriptState,
) !SurfaceFooterReservation {
    var active_buf: [256]u8 = undefined;
    const activity = FooterSurfaceActivity.resolve(&active_buf, shell, approval, ctx);
    const activity_projection = activity.projection;
    const active_label = activity.active_label;
    const trace = bottomReservationTraceAnchorFromTranscript(transcript_state);

    var bottom_reservation = BottomReservationState{};
    const input_visible_for_transient =
        ctx.composer_visible and approval == null;
    const composer_top_chrome_rows_for_transient = footer_paint_plan.composerTopChromeRows();
    const banner_rows_for_transient = queuedBannerRowsForLayout(
        ctx,
        shell.layout.rows,
        input_visible_for_transient,
        composer_top_chrome_rows_for_transient,
        0,
    );
    const banner_active_for_transient = approval != null or banner_rows_for_transient > 0;
    var frame_plan = footer_paint_plan.planFooterPaint(shell, .{
        .active_label = active_label,
        .activity_projection = activity_projection,
        .ctx = ctx,
        .place_mid_line_active = bottom_reservation.place_mid_line_active,
        .input_extra = 0,
        .input_visible = input_visible_for_transient,
        .composer_top_chrome_rows = composer_top_chrome_rows_for_transient,
        .picker_rows = 0,
        .banner_active = banner_active_for_transient,
        .banner_rows = banner_rows_for_transient,
        .transcript_state = transcript_state,
    });
    applyPreparedTransientReservation(&bottom_reservation, frame_plan, active_label, trace);

    const projection = try buildFooterSurfaceProjection(
        alloc,
        shell,
        approval,
        ctx,
        activity,
        .reservation,
    );
    if (try surface_invalidation.applyReservationFooterExtraUpdate(shell, force_redraw, .{
        .footer_extra = projection.footer_extra,
        .footer_reserved_base_rows = footer_layout.reservedBaseRows(projection.input_visible, projection.composer_top_chrome_rows),
        .input_extra = projection.input_extra,
        .banner_active = projection.banner_active,
        .picker_rows = projection.picker_rows,
        .show_picker = projection.show_picker,
    })) {
        bottom_reservation.applied_bottom_reserved_rows = 0;
    }

    const reservation_input = projection.reservationPlannerInput(
        ctx,
        bottom_reservation.place_mid_line_active,
        bottom_reservation.applied_bottom_reserved_rows,
        transcript_state,
    );
    frame_plan = footer_paint_plan.planFooterPaint(shell, reservation_input);
    applyResolvedBottomReservation(shell, &frame_plan, &bottom_reservation, active_label, trace, force_redraw, reservation_input);

    return .{
        .bottom_reserved_rows = bottom_reservation.applied_bottom_reserved_rows,
        .place_mid_line_active = bottom_reservation.place_mid_line_active,
        .precomputed = true,
    };
}

pub noinline fn prepareSurfaceFooterFrameWithReservation(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    force_redraw: *bool,
    approval: ?ApprovalProjection,
    ctx: RenderContext,
    reservation: SurfaceFooterReservation,
    attempt_invalidations: FrameInvalidationSet,
) !SurfaceFooterFrame {
    return prepareSurfaceFooterFrameInternal(alloc, shell, metrics, force_redraw, approval, ctx, reservation, attempt_invalidations);
}

fn prepareSurfaceFooterFrameInternal(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    force_redraw: *bool,
    approval: ?ApprovalProjection,
    ctx: RenderContext,
    reservation: SurfaceFooterReservation,
    attempt_invalidations: FrameInvalidationSet,
) !SurfaceFooterFrame {
    _ = metrics;
    var active_buf: [256]u8 = undefined;
    const activity = FooterSurfaceActivity.resolve(&active_buf, shell, approval, ctx);
    const activity_projection = activity.projection;
    const active_label = activity.active_label;
    const trace = bottomReservationTraceAnchorFromShell(shell);

    var bottom_reservation = BottomReservationState{
        .place_mid_line_active = reservation.place_mid_line_active,
        .applied_bottom_reserved_rows = reservation.bottom_reserved_rows,
    };
    var frame_plan: footer_paint_plan.FooterFramePlan = undefined;

    if (!reservation.precomputed) {
        const input_visible_for_transient =
            ctx.composer_visible and approval == null;
        const composer_top_chrome_rows_for_transient = footer_paint_plan.composerTopChromeRows();
        const banner_rows_for_transient = queuedBannerRowsForLayout(
            ctx,
            shell.layout.rows,
            input_visible_for_transient,
            composer_top_chrome_rows_for_transient,
            0,
        );
        const banner_active_for_transient = approval != null or banner_rows_for_transient > 0;
        const visible_banner_active_for_transient = banner_rows_for_transient > 0;
        frame_plan = footer_paint_plan.planFooterPaint(shell, .{
            .active_label = active_label,
            .activity_projection = activity_projection,
            .ctx = ctx,
            .place_mid_line_active = bottom_reservation.place_mid_line_active,
            .input_extra = 0,
            .input_visible = input_visible_for_transient,
            .composer_top_chrome_rows = composer_top_chrome_rows_for_transient,
            .picker_rows = 0,
            .footer_gap_active = banner_active_for_transient,
            .banner_active = visible_banner_active_for_transient,
            .banner_rows = banner_rows_for_transient,
        });
        bottom_reservation.applied_bottom_reserved_rows = 0;
        applyPreparedTransientReservation(&bottom_reservation, frame_plan, active_label, trace);
    }

    const projection = try buildFooterSurfaceProjection(
        alloc,
        shell,
        approval,
        ctx,
        activity,
        .frame,
    );
    const footer_extra_update: surface_invalidation.FooterExtraUpdate = .{
        .footer_extra = projection.footer_extra,
        .footer_reserved_base_rows = footer_layout.reservedBaseRows(projection.input_visible, projection.composer_top_chrome_rows),
        .input_extra = projection.input_extra,
        .banner_active = projection.footer_gap_active,
        .picker_rows = projection.picker_rows,
        .show_picker = projection.show_picker,
    };
    const footer_extra_invalidation = try surface_invalidation.frameFooterExtraInvalidation(shell, footer_extra_update);
    if (surface_invalidation.applyFrameFooterExtraUpdate(shell, force_redraw, footer_extra_update)) {
        if (!reservation.precomputed) bottom_reservation.applied_bottom_reserved_rows = 0;
    }

    const frame_input = projection.framePlannerInput(
        ctx,
        null,
        bottom_reservation.place_mid_line_active,
        bottom_reservation.applied_bottom_reserved_rows,
        reservation.transcript_state,
    );
    frame_plan = footer_paint_plan.planFooterPaint(shell, frame_input);
    if (!reservation.precomputed) {
        applyResolvedBottomReservation(shell, &frame_plan, &bottom_reservation, active_label, trace, force_redraw, frame_input);
    }

    if (footer_extra_invalidation) |range| {
        footer_paint_plan.appendFooterFrameInvalidation(&frame_plan.paint.invalidation, range);
    }
    surface_invalidation.mergeAttemptInvalidations(attempt_invalidations, &frame_plan.paint);
    var structural_plan = frame_plan.paint;
    structural_plan.cursor_target = null;
    try structural_plan.validate();

    const footer_trace_frame = recordFooterFrameTrace(shell, ctx, .{
        .rows = frame_plan.paint.footer,
        .activity = frame_plan.paint.activity,
        .footer_clean_allowed = frame_plan.paint.footer_clean_allowed,
        .activity_projection = projection.activity_projection,
        .force_redraw = force_redraw.*,
    });

    return assembleSurfaceFooterFrame(alloc, shell, .{
        .paint = frame_plan.paint,
        .planner_input = projection.framePlannerInput(
            ctx,
            approval,
            bottom_reservation.place_mid_line_active,
            bottom_reservation.applied_bottom_reserved_rows,
            null,
        ),
        .activity_projection = projection.activity_projection,
        .trace_paint_frame = footer_trace_frame,
    });
}

fn footerGeometryForRows(rows: FooterRows, activity: ActivityPlacement) footer_viewport.Geometry {
    return .{
        .top = rows.top,
        .top_divider = rows.top_divider,
        .input_base = rows.input_base,
        .bottom_divider = rows.bottom_divider,
        .hint = rows.hint,
        .activity_row = activity.row(),
        .activity_reserved_rows = activity.reservedFooterRows(),
    };
}

const surface_test_slash_specs = [_]command_specs.SlashSpec{
    .{ .kind = .help, .command = "/help", .help_entry = "/help", .completion_description = "show available slash commands", .presentation_category = .general },
    .{ .kind = .feedback, .command = "/feedback", .help_entry = "/feedback", .completion_description = "open the fx feedback form", .presentation_category = .product },
};
const surface_test_slash_registry = command_specs.SlashRegistry{ .commands = surface_test_slash_specs[0..] };

fn surfaceTestContext(input: *InputRuntime) RenderContext {
    return .{
        .slash_registry = surface_test_slash_registry,
        .stream = .{},
        .has_api_key = true,
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

test "surface footer frame snapshots the thinking blink from the frame clock" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    const approval = ApprovalPrompt{};

    const cases = [_]struct {
        now_ms: i64,
        expected: bool,
    }{
        .{ .now_ms = 1_000, .expected = true },
        .{ .now_ms = 1_500, .expected = false },
    };
    for (cases) |case| {
        var shell = surfaceTestShell(24, 80);
        defer shell.deinit(alloc);
        var metrics = Metrics{};
        var force_redraw = false;
        var ctx = surfaceTestContext(&input);
        ctx.stream = .{ .active = true, .turn_started_ms = 1_000 };
        ctx.now_ms = case.now_ms;

        var frame = try prepareSurfaceFooterFrameWithReservation(
            alloc,
            &shell,
            &metrics,
            &force_redraw,
            approval.projection(),
            ctx,
            .{},
            FrameInvalidationSet.empty(),
        );
        defer frame.deinit(alloc);

        try std.testing.expectEqual(@as(?bool, case.expected), frame.thinking_blink);
    }
}

fn surfaceTestShell(rows: u16, cols: u16) TranscriptRuntime {
    return .{
        .layout = .{
            .rows = rows,
            .cols = cols,
            .content_bottom = rows -| 4,
            .divider_top_row = rows -| 3,
            .input_row = rows -| 2,
            .divider_bottom_row = rows -| 1,
            .hint_row = rows,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
}

fn expectMeasuredPickerRows(
    alloc: Allocator,
    shell: *TranscriptRuntime,
    approval: ?ApprovalProjection,
    ctx: RenderContext,
    expected_kind: PickerKind,
    expected_rows: u16,
) !void {
    var measurement = try measureSurfaceFooter(alloc, shell, approval, ctx);
    defer measurement.deinit(alloc);

    try std.testing.expect(measurement.show_picker);
    try std.testing.expectEqual(expected_kind, measurement.picker_kind);
    try std.testing.expectEqual(expected_rows, measurement.picker_rows);
}

test "surface footer measurement preserves the narrow tool activity projection" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

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
        .last_visible_transcript_tail_kind = .tool_status,
    };
    defer shell.deinit(alloc);

    const approval = ApprovalPrompt{};
    const ctx: RenderContext = .{
        .stream = .{ .active = true, .last_activity_kind = .read, .read_count = 1 },
        .has_api_key = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .activity = .{ .tool_slot = .{
            .entry_id = 123,
            .fallback_label = "reading src/main.zig",
            .active = true,
            .kind = .read,
        } },
        .input = &input,
    };

    var measurement = try measureSurfaceFooter(alloc, &shell, approval.projection(), ctx);
    defer measurement.deinit(alloc);

    try std.testing.expect(measurement.active_label_present);
    switch (measurement.activity_projection) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqual(ActivityProjection.Tone.thinking, thinking.tone);
            try std.testing.expectEqualStrings("• Thinking", thinking.label);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "surface footer measurement preserves route recovery status tone" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    var shell = TranscriptRuntime{};
    defer shell.deinit(alloc);

    const approval = ApprovalPrompt{};
    const ctx = RenderContext{
        .stream = .{},
        .has_api_key = true,
        .model = "gpt-5.1",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .activity = .{ .turn_thinking = .{
            .label = "⚠ blocked · content filter",
            .tone = .danger,
        } },
        .input = &input,
    };

    var measurement = try measureSurfaceFooter(alloc, &shell, approval.projection(), ctx);
    defer measurement.deinit(alloc);

    try std.testing.expect(measurement.active_label_present);
    switch (measurement.activity_projection) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqual(ActivityProjection.Tone.danger, thinking.tone);
            try std.testing.expectEqualStrings("⚠ blocked · content filter", thinking.label);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "surface footer measurement keeps clipped command status transcript-owned" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

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
        .last_visible_transcript_tail_kind = .assistant_turn,
    };
    defer shell.deinit(alloc);

    var metrics = Metrics{};
    try shell.writeTranscript(alloc, &metrics, "one\ntwo\nthree\nfour\n", true);
    const status_id = try shell.appendRawTranscriptEntryClassified(alloc, "running read-only tools\n", .tool_status);
    shell.last_viewport_selection = .{
        .top_row = 1,
        .bottom_row = 20,
        .start_line = 6,
        .partial_skip_rows = 0,
        .line_count = 1,
        .last_visible_row = 1,
        .tail_kind = .assistant_turn,
    };
    try std.testing.expect(shell.rowForEntryId(status_id) == null);

    const approval = ApprovalPrompt{};
    const ctx: RenderContext = .{
        .stream = .{
            .active = true,
            .command_count = 1,
            .last_activity_kind = .command,
            .token_progress = .{ .input_tokens = 10, .output_tokens = 20 },
        },
        .has_api_key = true,
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
            .kind = .command,
        } },
        .input = &input,
    };

    var measurement = try measureSurfaceFooter(alloc, &shell, approval.projection(), ctx);
    defer measurement.deinit(alloc);

    try std.testing.expect(measurement.active_label_present);
    switch (measurement.activity_projection) {
        .turn_thinking => |thinking| {
            try std.testing.expectEqual(ActivityProjection.Tone.thinking, thinking.tone);
            try std.testing.expectEqualStrings("• Thinking (↑10 ↓20)", thinking.label);
        },
        .none, .tool_slot => return error.TestUnexpectedResult,
    }
}

test "surface footer measurement reserves rows for vertical slash completions" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "/");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = ApprovalPrompt{};
    defer approval.deinit(alloc);
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
    defer shell.deinit(alloc);

    var measurement = try measureSurfaceFooter(alloc, &shell, approval.projection(), surfaceTestContext(&input));
    defer measurement.deinit(alloc);

    try std.testing.expect(measurement.show_picker);
    try std.testing.expectEqual(PickerKind.slash, measurement.picker_kind);
    try std.testing.expect(measurement.picker_rows > 1);
    try std.testing.expect(measurement.footer_extra >= measurement.picker_rows + 1);
}

test "surface footer reserves one non-selectable row for zero slash results" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "/not-a-command");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = ApprovalPrompt{};
    defer approval.deinit(alloc);
    var shell = surfaceTestShell(24, 80);
    defer shell.deinit(alloc);

    var measurement = try measureSurfaceFooter(alloc, &shell, approval.projection(), surfaceTestContext(&input));
    defer measurement.deinit(alloc);

    try std.testing.expect(measurement.show_picker);
    try std.testing.expectEqual(PickerKind.slash, measurement.picker_kind);
    try std.testing.expectEqual(@as(usize, 0), measurement.slash_completion_count);
    try std.testing.expectEqual(@as(u16, 1), measurement.picker_rows);
    try std.testing.expect(measurement.slash_menu_layout == null);
}

test "surface footer measurement reserves capped picker rows for active list pickers" {
    const alloc = std.testing.allocator;
    var approval = ApprovalPrompt{};
    defer approval.deinit(alloc);

    const expected_rows = input_presentation.max_model_picker_rows;

    var slash_input = InputRuntime{};
    defer slash_input.deinit(alloc);
    try slash_input.edit_state.input.appendSlice(alloc, "/fe");
    slash_input.edit_state.cursor = slash_input.edit_state.input.items.len;
    var slash_shell = surfaceTestShell(24, 80);
    defer slash_shell.deinit(alloc);
    try expectMeasuredPickerRows(
        alloc,
        &slash_shell,
        approval.projection(),
        surfaceTestContext(&slash_input),
        .slash,
        input_presentation.max_model_picker_rows + 2,
    );

    var model_input = InputRuntime{};
    defer model_input.deinit(alloc);
    var model_shell = surfaceTestShell(24, 80);
    defer model_shell.deinit(alloc);
    var model_ctx = surfaceTestContext(&model_input);
    model_ctx.model_query_active = true;
    model_ctx.model_completions = &.{"gpt-test-model"};
    try expectMeasuredPickerRows(alloc, &model_shell, approval.projection(), model_ctx, .model_stage, expected_rows);

    var model_empty_shell = surfaceTestShell(24, 80);
    defer model_empty_shell.deinit(alloc);
    model_ctx.model_completions = &.{};
    model_ctx.model_completions_loading = true;
    try expectMeasuredPickerRows(alloc, &model_empty_shell, approval.projection(), model_ctx, .model_stage, expected_rows);

    var file_input = InputRuntime{};
    defer file_input.deinit(alloc);
    var file_shell = surfaceTestShell(24, 80);
    defer file_shell.deinit(alloc);
    var file_ctx = surfaceTestContext(&file_input);
    file_ctx.file_query_active = true;
    file_ctx.file_completions = &.{.{ .path = "src/main.zig", .kind = .file, .matched_spans = &.{} }};
    try expectMeasuredPickerRows(alloc, &file_shell, approval.projection(), file_ctx, .file, expected_rows);

    var file_empty_shell = surfaceTestShell(24, 80);
    defer file_empty_shell.deinit(alloc);
    file_ctx.file_completions = &.{};
    file_ctx.file_completions_failed = true;
    try expectMeasuredPickerRows(alloc, &file_empty_shell, approval.projection(), file_ctx, .file, expected_rows);
}

test "queued editor exposes only its file picker while a response streams" {
    const alloc = std.testing.allocator;
    var approval = ApprovalPrompt{};
    defer approval.deinit(alloc);
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var shell = surfaceTestShell(24, 80);
    defer shell.deinit(alloc);
    var ctx = surfaceTestContext(&input);
    ctx.stream.active = true;
    ctx.file_query_active = true;
    ctx.file_completions = &.{.{ .path = "src/main.zig", .kind = .file, .matched_spans = &.{} }};

    var hidden = try measureSurfaceFooter(alloc, &shell, approval.projection(), ctx);
    defer hidden.deinit(alloc);
    try std.testing.expect(!hidden.show_picker);

    ctx.queued_editor_active = true;
    var visible = try measureSurfaceFooter(alloc, &shell, approval.projection(), ctx);
    defer visible.deinit(alloc);
    try std.testing.expect(visible.show_picker);
    try std.testing.expectEqual(PickerKind.file, visible.picker_kind);
    try std.testing.expect(visible.picker_rows > 0);

    ctx.file_query_active = false;
    ctx.file_completions = &.{};
    ctx.model_query_active = true;
    ctx.model_completions = &.{"provider/queued-hidden-model"};
    var hidden_model = try measureSurfaceFooter(alloc, &shell, approval.projection(), ctx);
    defer hidden_model.deinit(alloc);
    try std.testing.expect(!hidden_model.show_picker);
}

test "surface footer measurement reserves only the compact auth picker rows" {
    const auth_runtime = @import("../../core/auth/auth_runtime.zig");
    const alloc = std.testing.allocator;
    var approval = ApprovalPrompt{};
    defer approval.deinit(alloc);
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var shell = surfaceTestShell(24, 80);
    defer shell.deinit(alloc);
    var ctx = surfaceTestContext(&input);
    ctx.auth_picker = auth_runtime.PickerView{
        .active = true,
        .available_sources = auth_runtime.SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login }),
        .selected_choice = .{ .source = .fx_login },
        .active_source = .fx_login,
        .include_skip = false,
    };

    try expectMeasuredPickerRows(
        alloc,
        &shell,
        approval.projection(),
        ctx,
        .auth,
        picker_presentation.authPickerReservedRows(ctx.auth_picker, 24, 0, 0),
    );
}

test "surface footer places the cursor after the Vercel team query" {
    const auth_runtime = @import("../../core/auth/auth_runtime.zig");
    const login_flow = @import("../../core/auth/login_flow.zig");
    const alloc = std.testing.allocator;
    var approval = ApprovalPrompt{};
    defer approval.deinit(alloc);
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var shell = surfaceTestShell(24, 80);
    defer shell.deinit(alloc);
    var team_id = "team_123".*;
    var team_slug = "example-internal-team".*;
    var team_name = "Example Internal Team".*;
    const teams = [_]login_flow.Team{.{
        .id = &team_id,
        .slug = &team_slug,
        .name = &team_name,
    }};
    var ctx = surfaceTestContext(&input);
    ctx.auth_picker = auth_runtime.PickerView{
        .active = true,
        .available_sources = auth_runtime.SourceSet.initOne(.fx_login),
        .selected_choice = .{ .team = 0 },
        .active_source = .fx_login,
        .include_skip = false,
        .stage = .change_team,
        .fx_login_session_available = true,
        .teams = &teams,
        .team_query = "play",
    };

    var metrics = Metrics{};
    var force_redraw = false;
    var frame = try prepareSurfaceFooterFrameWithReservation(
        alloc,
        &shell,
        &metrics,
        &force_redraw,
        approval.projection(),
        ctx,
        .{},
        FrameInvalidationSet.empty(),
    );
    defer frame.deinit(alloc);

    try std.testing.expectEqual(frame.paint.footer.picker_start, frame.composed.cursor.row);
    try std.testing.expectEqual(@as(u16, 39), frame.composed.cursor.col);
    try std.testing.expect(frame.composed.cursor_visible);
}

test "surface footer keeps the Vercel team query and cursor visible at minimum height" {
    const auth_runtime = @import("../../core/auth/auth_runtime.zig");
    const alloc = std.testing.allocator;
    var approval = ApprovalPrompt{};
    defer approval.deinit(alloc);
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var shell = surfaceTestShell(5, 80);
    defer shell.deinit(alloc);
    var ctx = surfaceTestContext(&input);
    ctx.auth_picker = auth_runtime.PickerView{
        .active = true,
        .available_sources = .empty,
        .selected_choice = null,
        .active_source = .fx_login,
        .include_skip = false,
        .stage = .change_team,
        .fx_login_session_available = true,
        .team_query = "play",
    };

    var measurement = try measureSurfaceFooter(alloc, &shell, approval.projection(), ctx);
    defer measurement.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 1), measurement.picker_rows);

    var metrics = Metrics{};
    var force_redraw = false;
    const reservation = try resolveSurfaceFooterReservation(
        alloc,
        &shell,
        &force_redraw,
        approval.projection(),
        ctx,
        currentSurfaceFooterTranscriptState(&shell),
    );
    var frame = try prepareSurfaceFooterFrameWithReservation(
        alloc,
        &shell,
        &metrics,
        &force_redraw,
        approval.projection(),
        ctx,
        reservation,
        FrameInvalidationSet.empty(),
    );
    defer frame.deinit(alloc);

    var query_visible = false;
    for (frame.composed.rows.items) |row| {
        if (row.row == frame.paint.footer.picker_start) {
            query_visible = std.mem.find(u8, row.text.items, "Search: play") != null;
            break;
        }
    }
    try std.testing.expect(query_visible);
    try std.testing.expectEqual(frame.paint.footer.picker_start, frame.composed.cursor.row);
    try std.testing.expectEqual(@as(u16, 39), frame.composed.cursor.col);
    try std.testing.expect(frame.composed.cursor_visible);
}

test "surface footer keeps the selected auth source visible at minimum height" {
    const auth_runtime = @import("../../core/auth/auth_runtime.zig");
    const alloc = std.testing.allocator;
    var approval = ApprovalPrompt{};
    defer approval.deinit(alloc);
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var ctx = surfaceTestContext(&input);
    ctx.auth_picker = auth_runtime.PickerView{
        .active = true,
        .available_sources = auth_runtime.SourceSet.initMany(&.{ .ai_gateway_api_key, .fx_login }),
        .selected_choice = .{ .source = .fx_login },
        .active_source = .ai_gateway_api_key,
        .include_skip = false,
    };

    var shell = surfaceTestShell(5, 80);
    defer shell.deinit(alloc);
    shell.cursor_row = 1;

    var measurement = try measureSurfaceFooter(alloc, &shell, approval.projection(), ctx);
    defer measurement.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 1), measurement.picker_rows);

    var metrics = Metrics{};
    var force_redraw = false;
    const reservation = try resolveSurfaceFooterReservation(
        alloc,
        &shell,
        &force_redraw,
        approval.projection(),
        ctx,
        currentSurfaceFooterTranscriptState(&shell),
    );
    var frame = try prepareSurfaceFooterFrameWithReservation(
        alloc,
        &shell,
        &metrics,
        &force_redraw,
        approval.projection(),
        ctx,
        reservation,
        FrameInvalidationSet.empty(),
    );
    defer frame.deinit(alloc);

    for (frame.composed.rows.items) |row| {
        if (std.mem.find(u8, row.text.items, "fx login") != null) return;
    }
    return error.SelectedAuthSourceNotVisible;
}

test "surface footer measurement caps active picker reservation in tiny terminals" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "/");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = ApprovalPrompt{};
    defer approval.deinit(alloc);
    var shell = surfaceTestShell(8, 80);
    defer shell.deinit(alloc);

    var measurement = try measureSurfaceFooter(alloc, &shell, approval.projection(), surfaceTestContext(&input));
    defer measurement.deinit(alloc);

    try std.testing.expect(measurement.show_picker);
    try std.testing.expectEqual(PickerKind.slash, measurement.picker_kind);
    try std.testing.expect(measurement.picker_rows < input_presentation.max_model_picker_rows);
    try std.testing.expectEqual(@as(u16, 1), measurement.picker_rows);
    try std.testing.expect(!measurement.slash_menu_layout.?.show_header);
    try std.testing.expect(measurement.frameLayoutMeasurement().natural_rows <= shell.layout.rows);

    const rows = measurement.frameLayoutRows(shell.layout.rows, 1);
    try std.testing.expect(rows.hint <= shell.layout.rows);
}

test "footer reservation traces stale off-screen external clear" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "frame_plan");

    var input = InputRuntime{};
    defer input.deinit(alloc);
    const approval = ApprovalPrompt{};
    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 6,
            .cols = 8,
            .content_bottom = 2,
            .divider_top_row = 3,
            .input_row = 4,
            .divider_bottom_row = 5,
            .hint_row = 6,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 1,
        .cursor_col = 1,
        .extra_input_rows = 1,
    };
    defer shell.deinit(alloc);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry.top = 9;

    var force_redraw = false;
    _ = try resolveSurfaceFooterReservation(
        alloc,
        &shell,
        &force_redraw,
        approval.projection(),
        surfaceTestContext(&input),
        currentSurfaceFooterTranscriptState(&shell),
    );

    try std.testing.expectEqual(@as(u16, 0), shell.extra_input_rows);
    try std.testing.expect(shell.footer_viewport.externally_invalidated);
    try std.testing.expect(shell.render_requests.pendingInvalidations().isEmpty());
    try std.testing.expect(force_redraw);

    var file = try std.Io.Dir.openFileAbsolute(std.testing.io, trace_path, .{});
    defer file.close(std.testing.io);
    const trace = try io_mod.readFileToEnd(alloc, &file, 4096);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "footer_extra_invalidation_skip reason=external_clear top=9 rows=6 skip=off_screen_stale_footer") != null);
}

test "measured footer preparation skips stale off-screen invalidation and stays dirty" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "a\nb");
    input.edit_state.cursor = input.edit_state.input.items.len;

    const approval = ApprovalPrompt{};
    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 6,
            .cols = 8,
            .content_bottom = 2,
            .divider_top_row = 3,
            .input_row = 4,
            .divider_bottom_row = 5,
            .hint_row = 6,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 1,
        .cursor_col = 1,
        .extra_input_rows = 1,
    };
    defer shell.deinit(alloc);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry.top = 9;

    const ctx = surfaceTestContext(&input);
    var measurement = try measureSurfaceFooter(alloc, &shell, approval.projection(), ctx);
    defer measurement.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 0), measurement.footer_extra);
    try std.testing.expectEqual(@as(u16, 2), measurement.footerReservedBaseRows());

    const solved = render_engine.frame_layout.solve(.{
        .terminal = shell.layout,
        .owned_top = shell.owned_top_row,
        .footer = measurement.frameLayoutMeasurement(),
        .transcript = .{ .natural_visual_rows = 0 },
    });
    const footer_rows = measurement.frameLayoutRows(shell.layout.rows, solved.footer_area.top);
    const plan = solved.toPaintPlan(.{
        .footer_rows = footer_rows,
        .viewport = currentSurfaceFooterTranscriptState(&shell).selection,
        .activity = .none,
        .cursor_target = .{ .row = footer_rows.input_base, .col = 1, .visible = true },
    });
    try plan.validate();

    var force_redraw = false;
    var frame = try prepareMeasuredSurfaceFooterFrameForPlan(
        alloc,
        &shell,
        &force_redraw,
        approval.projection(),
        ctx,
        &measurement,
        plan,
        FrameInvalidationSet.empty(),
    );
    defer frame.deinit(alloc);

    try std.testing.expect(frame.paint.invalidation.isEmpty());
    try std.testing.expect(!frame.paint.footer_clean_allowed);
    try std.testing.expectEqual(@as(u16, 3), shell.footer_reserved_base_rows);
    try std.testing.expect(force_redraw);
}

test "measured footer preparation propagates invalid zero geometry" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "a\nb");
    input.edit_state.cursor = input.edit_state.input.items.len;

    const approval = ApprovalPrompt{};
    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 6,
            .cols = 8,
            .content_bottom = 2,
            .divider_top_row = 3,
            .input_row = 4,
            .divider_bottom_row = 5,
            .hint_row = 6,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 1,
        .cursor_col = 1,
        .extra_input_rows = 1,
    };
    defer shell.deinit(alloc);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry.top = 0;

    const ctx = surfaceTestContext(&input);
    var measurement = try measureSurfaceFooter(alloc, &shell, approval.projection(), ctx);
    defer measurement.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 0), measurement.footer_extra);
    try std.testing.expectEqual(@as(u16, 2), measurement.footerReservedBaseRows());

    const solved = render_engine.frame_layout.solve(.{
        .terminal = shell.layout,
        .owned_top = shell.owned_top_row,
        .footer = measurement.frameLayoutMeasurement(),
        .transcript = .{ .natural_visual_rows = 0 },
    });
    const footer_rows = measurement.frameLayoutRows(shell.layout.rows, solved.footer_area.top);
    const plan = solved.toPaintPlan(.{
        .footer_rows = footer_rows,
        .viewport = currentSurfaceFooterTranscriptState(&shell).selection,
        .activity = .none,
        .cursor_target = .{ .row = footer_rows.input_base, .col = 1, .visible = true },
    });

    var force_redraw = false;
    try std.testing.expectError(
        error.InvalidFooterInvalidationGeometry,
        prepareMeasuredSurfaceFooterFrameForPlan(
            alloc,
            &shell,
            &force_redraw,
            approval.projection(),
            ctx,
            &measurement,
            plan,
            FrameInvalidationSet.empty(),
        ),
    );

    try std.testing.expectEqual(@as(u16, 1), shell.extra_input_rows);
    try std.testing.expectEqual(@as(u16, 3), shell.footer_reserved_base_rows);
    try std.testing.expect(shell.render_requests.pendingInvalidations().isEmpty());
    try std.testing.expect(!force_redraw);
}

test "surface footer reservation rejects zero invalidation geometry before mutation" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    const approval = ApprovalPrompt{};
    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 6,
            .cols = 8,
            .content_bottom = 2,
            .divider_top_row = 3,
            .input_row = 4,
            .divider_bottom_row = 5,
            .hint_row = 6,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 1,
        .cursor_col = 1,
        .extra_input_rows = 1,
    };
    defer shell.deinit(alloc);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry.top = 0;

    var force_redraw = false;
    const ctx = surfaceTestContext(&input);
    try std.testing.expectError(
        error.InvalidFooterInvalidationGeometry,
        resolveSurfaceFooterReservation(
            alloc,
            &shell,
            &force_redraw,
            approval.projection(),
            ctx,
            currentSurfaceFooterTranscriptState(&shell),
        ),
    );

    try std.testing.expectEqual(@as(u16, 1), shell.extra_input_rows);
    try std.testing.expectEqual(@as(u16, 3), shell.footer_reserved_base_rows);
    try std.testing.expect(!shell.footer_viewport.externally_invalidated);
    try std.testing.expect(shell.render_requests.pendingInvalidations().isEmpty());
    try std.testing.expect(!force_redraw);
}

test "surface footer preparation rejects zero invalidation geometry before mutation" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    const approval = ApprovalPrompt{};
    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 6,
            .cols = 8,
            .content_bottom = 2,
            .divider_top_row = 3,
            .input_row = 4,
            .divider_bottom_row = 5,
            .hint_row = 6,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 1,
        .cursor_col = 1,
        .extra_input_rows = 1,
    };
    defer shell.deinit(alloc);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry.top = 0;

    var metrics = Metrics{};
    var force_redraw = false;
    const ctx = surfaceTestContext(&input);
    const result = prepareSurfaceFooterFrameWithReservation(
        alloc,
        &shell,
        &metrics,
        &force_redraw,
        approval.projection(),
        ctx,
        .{ .precomputed = true },
        FrameInvalidationSet.empty(),
    );
    if (result) |frame_value| {
        var frame = frame_value;
        defer frame.deinit(alloc);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(error.InvalidFooterInvalidationGeometry, err);
    }

    try std.testing.expectEqual(@as(u16, 1), shell.extra_input_rows);
    try std.testing.expectEqual(@as(u16, 3), shell.footer_reserved_base_rows);
    try std.testing.expect(!shell.footer_viewport.externally_invalidated);
    try std.testing.expect(shell.render_requests.pendingInvalidations().isEmpty());
    try std.testing.expect(!force_redraw);
}

test "surface footer preparation retains stale and current footer invalidations" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);

    const approval = ApprovalPrompt{};
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
        .cursor_row = 1,
        .cursor_col = 1,
        .extra_input_rows = 1,
    };
    defer shell.deinit(alloc);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry.top = 3;

    var metrics = Metrics{};
    var force_redraw = false;
    var frame = try prepareSurfaceFooterFrameWithReservation(
        alloc,
        &shell,
        &metrics,
        &force_redraw,
        approval.projection(),
        surfaceTestContext(&input),
        .{ .precomputed = true },
        FrameInvalidationSet.empty(),
    );
    defer frame.deinit(alloc);

    try frame.paint.validate();
    try std.testing.expect(surfaceHasInvalidation(
        frame.paint.invalidation,
        .external_clear,
        1,
        3,
    ));
    try std.testing.expect(surfaceHasInvalidation(
        frame.paint.invalidation,
        .external_clear,
        3,
        24,
    ));
    try std.testing.expectEqual(@as(u16, 0), shell.extra_input_rows);
    try std.testing.expect(shell.footer_viewport.externally_invalidated);
    try std.testing.expect(force_redraw);
}

fn surfaceHasInvalidation(
    set: paint_plan.FrameInvalidationSet,
    reason: paint_plan.FrameInvalidationReason,
    top: u16,
    bottom: u16,
) bool {
    for (set.ranges()) |range| {
        if (range.reason == reason and range.top == top and range.bottom == bottom) return true;
    }
    return false;
}

test "surface footer measurement exposes neutral frame layout measurement" {
    const measurement = SurfaceFooterMeasurement{
        .input_extra = 2,
        .picker_rows = 3,
        .banner_active = true,
        .total_lines = 3,
        .show_picker = true,
    };

    const neutral = measurement.frameLayoutMeasurement();

    try std.testing.expectEqual(@as(u16, 11), neutral.natural_rows);
    try std.testing.expectEqual(@as(u16, 1), neutral.min_rows);
    try std.testing.expectEqual(@as(u16, 11), neutral.max_rows);
    try std.testing.expectEqual(@as(u16, 3), neutral.input_rows);
    try std.testing.expectEqual(@as(u16, 3), neutral.picker_rows);
    try std.testing.expectEqual(@as(u16, 1), neutral.banner_rows);
    try std.testing.expectEqual(@as(u16, 0), neutral.top_gap_rows);
}

test "surface footer measurement collapses tint top chrome only for visible input" {
    const lines = SurfaceFooterMeasurement{
        .input_extra = 0,
        .total_lines = 1,
        .composer_top_chrome_rows = 1,
    };
    const tint = SurfaceFooterMeasurement{
        .input_extra = 0,
        .total_lines = 1,
        .composer_top_chrome_rows = 0,
    };
    const multiline_tint = SurfaceFooterMeasurement{
        .input_extra = 1,
        .total_lines = 2,
        .composer_top_chrome_rows = 0,
        .show_picker = true,
        .picker_rows = 3,
        .footer_extra = 5,
    };
    const modal = SurfaceFooterMeasurement{
        .input_visible = false,
        .composer_top_chrome_rows = 0,
        .picker_rows = 7,
        .footer_extra = 7,
        .top_gap_rows = 1,
    };

    try std.testing.expectEqual(@as(u16, 4), lines.frameLayoutMeasurement().natural_rows);
    try std.testing.expectEqual(@as(u16, 3), tint.frameLayoutMeasurement().natural_rows);
    try std.testing.expectEqual(@as(u16, 8), multiline_tint.frameLayoutMeasurement().natural_rows);
    try std.testing.expectEqual(@as(u16, 10), modal.frameLayoutMeasurement().natural_rows);
    try std.testing.expectEqual(@as(u16, 1), modal.frameLayoutMeasurement().top_gap_rows);

    const tint_rows = tint.frameLayoutRows(24, 20);
    try std.testing.expectEqual(tint_rows.top_divider, tint_rows.input_base);
    try std.testing.expectEqual(@as(u16, 3), tint_rows.total_rows);

    const multiline_rows = multiline_tint.frameLayoutRows(24, 17);
    try std.testing.expectEqual(@as(u16, 17), multiline_rows.top_divider);
    try std.testing.expectEqual(@as(u16, 18), multiline_rows.input_base);
    try std.testing.expectEqual(@as(u16, 19), multiline_rows.picker_divider);

    const modal_rows = modal.frameLayoutRows(24, 14);
    try std.testing.expectEqual(@as(u16, 14), modal_rows.top_divider);
    try std.testing.expectEqual(@as(u16, 14), modal_rows.input_base);
    try std.testing.expectEqual(@as(u16, 15), modal_rows.picker_start);
}

test "approval surface footer measurement accounts for both divider rails" {
    const measurement = SurfaceFooterMeasurement{
        .input_visible = false,
        .picker_rows = interaction_state.approval_panel_rows_spacious,
    };

    const neutral = measurement.frameLayoutMeasurement();

    try std.testing.expectEqual(interaction_state.approval_panel_rows_spacious + 3, neutral.natural_rows);
    try std.testing.expectEqual(@as(u16, 1), neutral.min_rows);
    try std.testing.expectEqual(interaction_state.approval_panel_rows_spacious + 3, neutral.max_rows);
    try std.testing.expectEqual(@as(u16, 0), neutral.input_rows);
    try std.testing.expectEqual(interaction_state.approval_panel_rows_spacious, neutral.picker_rows);
}

test "command approval fit includes the queued prompt banner" {
    const layout: types.Layout = .{
        .rows = 11,
        .cols = 20,
        .content_bottom = 7,
        .divider_top_row = 8,
        .input_row = 9,
        .divider_bottom_row = 10,
        .hint_row = 11,
    };
    const label = "terminal.exec 12345678901234567";

    try std.testing.expect(try commandApprovalFitsInline(
        std.testing.allocator,
        label,
        null,
        layout,
        0,
    ));
    try std.testing.expect(!try commandApprovalFitsInline(
        std.testing.allocator,
        label,
        null,
        layout,
        1,
    ));
}

test "command approval footer sizing paths use the complete command" {
    const alloc = std.testing.allocator;
    const command = "printf 'SURFACE_COMMAND_START_" ++ ("x" ** 88) ++ "_SURFACE_COMMAND_END'";
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "terminal.exec printf 'SURFACE_COMMAND_START...",
        .command = command,
    }));

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 30,
            .cols = 80,
            .content_bottom = 26,
            .divider_top_row = 27,
            .input_row = 28,
            .divider_bottom_row = 29,
            .hint_row = 30,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 10,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    const request = prompt.request.?.view();
    const label_only_rows = try approval_ui.inlineApprovalPanelRows(
        alloc,
        request.label,
        shell.layout.cols,
        shell.layout.rows,
    );
    const expected_rows = try approval_ui.inlineApprovalPanelRowsForCommand(
        alloc,
        request.label,
        request.command,
        shell.layout.cols,
        shell.layout.rows,
    );
    try std.testing.expect(expected_rows > label_only_rows);

    try std.testing.expect(try commandApprovalFitsInline(
        alloc,
        request.label,
        request.command,
        shell.layout,
        0,
    ));

    const ctx = surfaceTestContext(&input);
    var measured = try measureSurfaceFooter(
        alloc,
        &shell,
        prompt.projection(),
        ctx,
    );
    defer measured.deinit(alloc);
    try std.testing.expect(!measured.input_visible);
    try std.testing.expectEqual(@as(u16, 3), measured.footerReservedBaseRows());
    try std.testing.expectEqual(expected_rows + 3, measured.frameLayoutMeasurement().natural_rows);
    try std.testing.expectEqual(expected_rows, measured.picker_rows);

    var force_redraw = false;
    _ = try resolveSurfaceFooterReservation(
        alloc,
        &shell,
        &force_redraw,
        prompt.projection(),
        ctx,
        currentSurfaceFooterTranscriptState(&shell),
    );
    try std.testing.expectEqual(expected_rows, shell.extra_input_rows);
    try std.testing.expectEqual(@as(u16, 3), shell.footer_reserved_base_rows);

    shell.extra_input_rows = 0;
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry = .{
        .top = 27,
        .top_divider = 27,
        .input_base = 28,
        .bottom_divider = 29,
        .hint = 30,
    };
    var metrics = Metrics{};
    var frame = try prepareSurfaceFooterFrameWithReservation(
        alloc,
        &shell,
        &metrics,
        &force_redraw,
        prompt.projection(),
        ctx,
        .{ .precomputed = true },
        FrameInvalidationSet.empty(),
    );
    defer frame.deinit(alloc);

    try std.testing.expectEqual(expected_rows, shell.extra_input_rows);
    try std.testing.expectEqual(@as(u16, 3), shell.footer_reserved_base_rows);
    var saw_end = false;
    for (frame.composed.rows.items) |row| {
        saw_end = saw_end or std.mem.find(u8, row.text.items, "SURFACE_COMMAND_END") != null;
    }
    try std.testing.expect(saw_end);
}

test "surface footer measurement rows do not reserve activity space" {
    const measurement = SurfaceFooterMeasurement{
        .active_label_present = true,
        .input_extra = 1,
        .footer_extra = 1,
    };

    const rows = measurement.frameLayoutRows(46, 38);

    try std.testing.expectEqual(@as(u16, 38), rows.top);
    try std.testing.expectEqual(@as(u16, 38), rows.top_divider);
    try std.testing.expectEqual(@as(u16, 40), rows.input_base);
    try std.testing.expectEqual(@as(u16, 42), rows.hint);
}

test "current footer transcript state clamps stale viewport selection after shrink" {
    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 8,
            .cols = 80,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .viewport_top_row = 1,
        .owned_top_row = 1,
        .last_visible_transcript_top_row = 1,
        .last_visible_transcript_last_row = 21,
        .last_viewport_selection = .{
            .top_row = 1,
            .bottom_row = 21,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 3,
            .last_visible_row = 21,
        },
    };
    defer shell.deinit(std.testing.allocator);

    const state = currentSurfaceFooterTranscriptState(&shell);

    try std.testing.expectEqual(@as(u16, 1), state.selection.top_row);
    try std.testing.expectEqual(@as(u16, 4), state.selection.bottom_row);
    try std.testing.expectEqual(@as(u16, 4), state.selection.last_visible_row);
}

test "retargetSurfaceFooterFrame moves composed rows to solved footer plan" {
    const alloc = std.testing.allocator;
    var first = std.ArrayList(u8).empty;
    try first.appendSlice(alloc, "top");
    var input = std.ArrayList(u8).empty;
    try input.appendSlice(alloc, "input");

    var frame = SurfaceFooterFrame{
        .paint = surfaceTestRetargetPaintPlan(10),
        .composed = .{},
    };
    defer frame.deinit(alloc);
    try frame.composed.pushComposedRow(alloc, 10, &first);
    try frame.composed.pushComposedRow(alloc, 11, &input);
    frame.composed.cursor = .{ .row = 11, .col = 4 };

    var solved_plan = surfaceTestRetargetPaintPlan(20);
    solved_plan.cursor_target = .{
        .row = 41,
        .col = 81,
        .visible = true,
    };
    retargetSurfaceFooterFrame(&frame, solved_plan);

    try std.testing.expectEqual(@as(u16, 20), frame.paint.footer.top);
    try std.testing.expectEqual(@as(u16, 20), frame.composed.rows.items[0].row);
    try std.testing.expectEqual(@as(u16, 21), frame.composed.rows.items[1].row);
    try std.testing.expectEqual(@as(u16, 21), frame.composed.cursor.row);
    try std.testing.expectEqual(
        paint_plan.FrameCursorTarget{
            .row = 21,
            .col = 4,
            .visible = true,
        },
        frame.paint.cursor_target.?,
    );
    try frame.paint.validate();
}

test "commitSurfaceFooterFrame can commit footer viewport without measurement" {
    const alloc = std.testing.allocator;
    var input = std.ArrayList(u8).empty;
    try input.appendSlice(alloc, "input");

    var frame = SurfaceFooterFrame{
        .paint = surfaceTestRetargetPaintPlan(20),
        .composed = .{},
    };
    defer frame.deinit(alloc);
    try frame.composed.pushComposedRow(alloc, 21, &input);
    frame.composed.cursor = .{ .row = 21, .col = 6 };

    var shell = TranscriptRuntime{
        .layout = frame.paint.layout,
        .owned_top_row = 1,
        .extra_input_rows = 7,
    };
    defer shell.deinit(alloc);

    commitSurfaceFooterFrame(alloc, &shell, &frame, null);

    try std.testing.expectEqual(@as(u16, 7), shell.extra_input_rows);
    try std.testing.expect(shell.footer_viewport.has_frame);
    try std.testing.expectEqual(@as(u16, 21), shell.footer_viewport.cursor.row);
    try std.testing.expectEqual(@as(u16, 6), shell.footer_viewport.cursor.col);
}

test "commitSurfaceFooterFrame commits measured reserved base rows" {
    const alloc = std.testing.allocator;
    var input = std.ArrayList(u8).empty;
    try input.appendSlice(alloc, "input");

    var frame = SurfaceFooterFrame{
        .paint = surfaceTestRetargetPaintPlan(20),
        .composed = .{},
    };
    defer frame.deinit(alloc);
    try frame.composed.pushComposedRow(alloc, 20, &input);

    var shell = TranscriptRuntime{
        .layout = frame.paint.layout,
        .owned_top_row = 1,
        .extra_input_rows = 4,
        .footer_reserved_base_rows = 3,
    };
    defer shell.deinit(alloc);

    const measurement = SurfaceFooterMeasurement{
        .footer_extra = 0,
        .composer_top_chrome_rows = 0,
    };

    commitSurfaceFooterFrame(alloc, &shell, &frame, &measurement);

    try std.testing.expectEqual(@as(u16, 0), shell.extra_input_rows);
    try std.testing.expectEqual(@as(u16, 2), shell.footer_reserved_base_rows);
    try std.testing.expect(shell.footer_viewport.has_frame);
}

test "commitSurfaceFooterFrame preserves hidden composed cursor" {
    const alloc = std.testing.allocator;
    var title = std.ArrayList(u8).empty;
    try title.appendSlice(alloc, "  Bash command");

    var frame = SurfaceFooterFrame{
        .paint = surfaceTestRetargetPaintPlan(20),
        .composed = .{},
    };
    defer frame.deinit(alloc);
    try frame.composed.pushComposedRow(alloc, 20, &title);
    frame.composed.cursor = .{ .row = 20, .col = 1 };
    frame.composed.cursor_visible = false;

    var shell = TranscriptRuntime{
        .layout = frame.paint.layout,
        .owned_top_row = 1,
        .extra_input_rows = 7,
    };
    defer shell.deinit(alloc);

    commitSurfaceFooterFrame(alloc, &shell, &frame, null);

    try std.testing.expect(shell.footer_viewport.has_frame);
    try std.testing.expect(!shell.footer_viewport.cursor_visible);
}

test "transcript viewer reserves a blank row above its navigation footer" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 96,
            .content_bottom = 20,
            .divider_top_row = 21,
            .input_row = 22,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 20,
        .cursor_col = 1,
    };
    defer shell.deinit(alloc);

    var ctx = surfaceTestContext(&input);
    ctx.transcript_depth = .review;
    var review = try measureSurfaceFooter(alloc, &shell, prompt.projection(), ctx);
    defer review.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 1), review.frameLayoutMeasurement().top_gap_rows);

    ctx.transcript_depth = .full;
    var full = try measureSurfaceFooter(alloc, &shell, prompt.projection(), ctx);
    defer full.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 1), full.frameLayoutMeasurement().top_gap_rows);
}

fn surfaceTestRetargetPaintPlan(top: u16) PaintPlan {
    const rows = footer_layout.FooterRows{
        .top = top,
        .top_divider = top,
        .banner = top,
        .banner_active = false,
        .input_base = top + 1,
        .picker_divider = top + 2,
        .picker_start = top + 3,
        .bottom_divider = top + 2,
        .hint = top + 3,
        .total_rows = 4,
    };
    return .{
        .layout = .{
            .rows = 40,
            .cols = 80,
            .content_bottom = top - 1,
            .divider_top_row = rows.top_divider,
            .input_row = rows.input_base,
            .divider_bottom_row = rows.bottom_divider,
            .hint_row = rows.hint,
        },
        .viewport = .{
            .top_row = 1,
            .bottom_row = top - 1,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 0,
        },
        .footer = rows,
        .activity = .none,
        .preserved_band = paint_plan.FrameBand.empty(.preserved_shell),
        .transcript_band = .{ .top = 1, .bottom = top - 1, .owner = .transcript },
        .activity_band = paint_plan.FrameBand.empty(.activity),
        .footer_band = .{ .top = top, .bottom = top + 3, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = top + 1, .col = 4, .visible = true },
        .footer_reservation_source = .none,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

fn surfaceTestApprovalProfilePreview() diff_mod.FileChangePreview {
    return .{
        .path = "src/profile.txt",
        .lines = &.{
            .{ .op = .deletion, .old_line = 1, .text = "old one" },
            .{ .op = .addition, .new_line = 1, .text = "new one" },
            .{ .op = .deletion, .old_line = 2, .text = "old two" },
            .{ .op = .addition, .new_line = 2, .text = "new two" },
            .{ .op = .deletion, .old_line = 3, .text = "old three" },
            .{ .op = .addition, .new_line = 3, .text = "new three" },
        },
        .additions = 3,
        .deletions = 3,
        .truncated = false,
    };
}

fn surfaceTestApprovalFileRequest(
    preview: diff_mod.FileChangePreview,
) permission_request.FileApprovalRequest {
    return .{
        .kind = .edit,
        .intent = .mutation,
        .preview = preview,
        .scope = .workspace_files,
    };
}

test "file approval reservation-only sizing matches measured subagent view" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "ignored",
        .file = surfaceTestApprovalFileRequest(surfaceTestApprovalProfilePreview()),
    }));

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 96,
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

    var ctx = surfaceTestContext(&input);
    ctx.subagent_count = 1;
    ctx.subagent_view_active = true;
    ctx.selected_subagent_id = 7;
    ctx.selected_subagent_label = "reviewer";
    ctx.selected_subagent_status = .running;

    var measured = try measureSurfaceFooter(
        alloc,
        &shell,
        prompt.projection(),
        ctx,
    );
    defer measured.deinit(alloc);
    var force_redraw = false;
    _ = try resolveSurfaceFooterReservation(
        alloc,
        &shell,
        &force_redraw,
        prompt.projection(),
        ctx,
        currentSurfaceFooterTranscriptState(&shell),
    );
    try std.testing.expectEqual(
        measured.footer_extra,
        shell.extra_input_rows,
    );
    try std.testing.expectEqual(
        approval_ui.fileApprovalPickerRows(prompt.request.?.file.?),
        measured.picker_rows,
    );
}

test "file approval preparation over active subagent view keeps a valid footer invalidation" {
    const alloc = std.testing.allocator;
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "ignored",
        .file = surfaceTestApprovalFileRequest(surfaceTestApprovalProfilePreview()),
    }));

    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 40,
            .cols = 120,
            .content_bottom = 36,
            .divider_top_row = 37,
            .input_row = 38,
            .divider_bottom_row = 39,
            .hint_row = 40,
        },
        .owned_top_row = 1,
        .viewport_top_row = 1,
        .cursor_row = 41,
        .cursor_col = 121,
    };
    defer shell.deinit(alloc);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry = .{
        .top = 37,
        .top_divider = 37,
        .input_base = 38,
        .bottom_divider = 39,
        .hint = 40,
    };

    var ctx = surfaceTestContext(&input);
    ctx.subagent_count = 1;
    ctx.subagent_view_active = true;
    ctx.selected_subagent_id = 7;
    ctx.selected_subagent_label = "reviewer";
    ctx.selected_subagent_status = .completed;

    var metrics = Metrics{};
    var force_redraw = false;
    var frame = try prepareSurfaceFooterFrameWithReservation(
        alloc,
        &shell,
        &metrics,
        &force_redraw,
        prompt.projection(),
        ctx,
        .{ .precomputed = true },
        FrameInvalidationSet.empty(),
    );
    defer frame.deinit(alloc);

    try frame.paint.validate();
    try std.testing.expect(surfaceHasInvalidation(
        frame.paint.invalidation,
        .reserved_gap_clear,
        37,
        40,
    ));
    try std.testing.expectEqual(
        approval_ui.fileApprovalPickerRows(prompt.request.?.file.?),
        shell.extra_input_rows,
    );
}
