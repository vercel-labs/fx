const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const render_engine = @import("../render_engine.zig");
const transcript_runtime = @import("../transcript/runtime.zig");
const footer_paint_plan = @import("paint_plan.zig");

const paint_plan = render_engine.paint_plan;
const FrameInvalidationSet = paint_plan.FrameInvalidationSet;
const PaintPlan = paint_plan.PaintPlan;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

pub const FooterExtraUpdate = struct {
    footer_extra: u16,
    footer_reserved_base_rows: u16,
    input_extra: u16,
    banner_active: bool,
    picker_rows: u16,
    show_picker: bool,

    fn changesFooterExtra(self: FooterExtraUpdate, shell: *const TranscriptRuntime) bool {
        return self.footer_extra != shell.extra_input_rows or
            self.footer_reserved_base_rows != shell.footer_reserved_base_rows;
    }
};

const GeometryError = error{
    InvalidFooterInvalidationGeometry,
};

const RecordError = GeometryError || error{
    InvalidFrameInvalidationRange,
};

const FooterExtraChange = struct {
    update: FooterExtraUpdate,
    top: u16,
};

fn detectFooterExtraChange(shell: *const TranscriptRuntime, update: FooterExtraUpdate) ?FooterExtraChange {
    if (!update.changesFooterExtra(shell)) return null;
    return .{
        .update = update,
        .top = footerExtraInvalidationTop(shell),
    };
}

fn logFooterExtraChange(shell: *const TranscriptRuntime, change: FooterExtraChange) void {
    debug_trace.logf(
        "frame_plan",
        "footer_extra_update old={d} new={d} old_base={d} new_base={d} input_extra={d} banner={s} picker_rows={d} show_picker={s}",
        .{
            shell.extra_input_rows,
            change.update.footer_extra,
            shell.footer_reserved_base_rows,
            change.update.footer_reserved_base_rows,
            change.update.input_extra,
            if (change.update.banner_active) "true" else "false",
            change.update.picker_rows,
            if (change.update.show_picker) "true" else "false",
        },
    );
}

fn applyFooterExtraChange(shell: *TranscriptRuntime, force_redraw: *bool, change: FooterExtraChange) void {
    shell.extra_input_rows = change.update.footer_extra;
    shell.footer_reserved_base_rows = change.update.footer_reserved_base_rows;
    shell.footer_viewport.invalidateAfterExternalClear();
    force_redraw.* = true;
}

fn footerExtraInvalidationTop(shell: *const TranscriptRuntime) u16 {
    return if (shell.footer_viewport.has_frame)
        shell.footer_viewport.geometry.top
    else
        shell.footerTopRowForExtra(shell.extra_input_rows);
}

fn visibleFooterInvalidation(
    reason: paint_plan.FrameInvalidationReason,
    top: u16,
    rows: u16,
) GeometryError!?paint_plan.FrameInvalidationRange {
    if (top == 0 or rows == 0) return error.InvalidFooterInvalidationGeometry;
    if (top > rows) return null;
    return .{ .reason = reason, .top = top, .bottom = rows };
}

fn logSkippedFooterInvalidation(
    reason: paint_plan.FrameInvalidationReason,
    top: u16,
    rows: u16,
) void {
    debug_trace.logf(
        "frame_plan",
        "footer_extra_invalidation_skip reason={s} top={d} rows={d} skip=off_screen_stale_footer",
        .{ @tagName(reason), top, rows },
    );
}

fn footerExtraInvalidationReason(
    shell: *const TranscriptRuntime,
    update: FooterExtraUpdate,
) paint_plan.FrameInvalidationReason {
    return if (update.footer_extra < shell.extra_input_rows)
        .external_clear
    else
        .reserved_gap_clear;
}

fn appendVisibleFooterInvalidation(
    plan: *PaintPlan,
    reason: paint_plan.FrameInvalidationReason,
    top: u16,
    rows: u16,
    trace_skips: bool,
) GeometryError!void {
    const range = try visibleFooterInvalidation(reason, top, rows) orelse {
        if (trace_skips) logSkippedFooterInvalidation(reason, top, rows);
        return;
    };
    if (reason == .external_clear and !paint_plan.invalidationIntersectsOwnedBand(plan.*, range)) {
        if (trace_skips) {
            debug_trace.logf(
                "frame_plan",
                "footer_extra_invalidation_skip reason={s} top={d} rows={d} skip=outside_current_owned_bands",
                .{ @tagName(reason), top, rows },
            );
        }
        return;
    }
    footer_paint_plan.appendFooterFrameInvalidation(&plan.invalidation, range);
}

fn recordVisibleExternalClearInvalidation(
    shell: *TranscriptRuntime,
    top: u16,
    rows: u16,
) RecordError!void {
    const range = try visibleFooterInvalidation(.external_clear, top, rows) orelse {
        logSkippedFooterInvalidation(.external_clear, top, rows);
        return;
    };
    try shell.recordFrameInvalidation(range);
}

pub fn appendMeasuredFooterExtraInvalidation(
    shell: *TranscriptRuntime,
    plan: *PaintPlan,
    force_redraw: *bool,
    update: FooterExtraUpdate,
) GeometryError!void {
    const change = detectFooterExtraChange(shell, update) orelse return;

    logFooterExtraChange(shell, change);
    try appendVisibleFooterInvalidation(
        plan,
        footerExtraInvalidationReason(shell, change.update),
        change.top,
        shell.layout.rows,
        true,
    );
    plan.footer_clean_allowed = false;
    force_redraw.* = true;
}

pub fn applyReservationFooterExtraUpdate(
    shell: *TranscriptRuntime,
    force_redraw: *bool,
    update: FooterExtraUpdate,
) RecordError!bool {
    const change = detectFooterExtraChange(shell, update) orelse return false;

    logFooterExtraChange(shell, change);
    try recordVisibleExternalClearInvalidation(shell, change.top, shell.layout.rows);
    applyFooterExtraChange(shell, force_redraw, change);
    return true;
}

pub fn frameFooterExtraInvalidation(
    shell: *const TranscriptRuntime,
    update: FooterExtraUpdate,
) GeometryError!?paint_plan.FrameInvalidationRange {
    const change = detectFooterExtraChange(shell, update) orelse return null;
    return try visibleFooterInvalidation(
        footerExtraInvalidationReason(shell, change.update),
        change.top,
        shell.layout.rows,
    );
}

pub fn applyFrameFooterExtraUpdate(
    shell: *TranscriptRuntime,
    force_redraw: *bool,
    update: FooterExtraUpdate,
) bool {
    const change = detectFooterExtraChange(shell, update) orelse return false;

    logFooterExtraChange(shell, change);
    applyFooterExtraChange(shell, force_redraw, change);
    return true;
}

pub fn mergeAttemptInvalidations(invalidations: FrameInvalidationSet, plan: *PaintPlan) void {
    for (invalidations.ranges()) |range| {
        if (mergeAttemptInvalidation(&plan.invalidation, range)) |collapsed| {
            debug_trace.logf(
                "frame_plan",
                "attempt_invalidation_collapse incoming_reason={s} collapsed_reason={s} top={d} bottom={d}",
                .{ @tagName(range.reason), @tagName(collapsed.reason), collapsed.top, collapsed.bottom },
            );
        }
    }
    plan.footer_clean_allowed = plan.invalidation.isEmpty();
}

pub fn resolveCandidateFrameInvalidations(
    shell: *const TranscriptRuntime,
    plan: PaintPlan,
    footer_update: ?FooterExtraUpdate,
    attempt_invalidations: FrameInvalidationSet,
) GeometryError!FrameInvalidationSet {
    var candidate = plan;
    if (footer_update) |update| {
        if (detectFooterExtraChange(shell, update)) |change| {
            try appendVisibleFooterInvalidation(
                &candidate,
                footerExtraInvalidationReason(shell, change.update),
                change.top,
                shell.layout.rows,
                false,
            );
        }
    }
    for (attempt_invalidations.ranges()) |range| {
        _ = mergeAttemptInvalidation(&candidate.invalidation, range);
    }
    return candidate.invalidation;
}

fn mergeAttemptInvalidation(
    invalidations: *FrameInvalidationSet,
    incoming: paint_plan.FrameInvalidationRange,
) ?paint_plan.FrameInvalidationRange {
    var merged = incoming;
    var consumed: [paint_plan.max_frame_invalidation_ranges]bool = @splat(false);
    var overlapped = false;

    var changed = true;
    while (changed) {
        changed = false;
        for (invalidations.ranges(), 0..) |existing, index| {
            if (consumed[index] or existing.bottom < merged.top or merged.bottom < existing.top) continue;
            consumed[index] = true;
            overlapped = true;
            changed = true;
            merged.reason = paint_plan.moreSevereFrameInvalidation(existing.reason, merged.reason);
            merged.top = @min(existing.top, merged.top);
            merged.bottom = @max(existing.bottom, merged.bottom);
        }
    }

    var next = FrameInvalidationSet.empty();
    for (invalidations.ranges(), 0..) |existing, index| {
        if (!consumed[index]) _ = next.appendOrCollapse(existing);
    }
    const collapsed = next.appendOrCollapse(merged);
    invalidations.* = next;
    return collapsed orelse if (overlapped) merged else null;
}

fn surfaceTestPlan() PaintPlan {
    return .{
        .layout = .{
            .rows = 8,
            .cols = 40,
            .content_bottom = 4,
            .divider_top_row = 5,
            .input_row = 6,
            .divider_bottom_row = 7,
            .hint_row = 8,
        },
        .viewport = .{
            .top_row = 2,
            .bottom_row = 4,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
            .last_visible_row = 2,
        },
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
        .preserved_band = .{ .top = 1, .bottom = 1, .owner = .preserved_shell },
        .transcript_band = .{ .top = 2, .bottom = 4, .owner = .transcript },
        .activity_band = paint_plan.FrameBand.empty(.activity),
        .footer_band = .{ .top = 5, .bottom = 8, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = 6, .col = 1, .visible = true },
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
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

test "visible footer invalidation skips only stale off-screen footer rows" {
    try std.testing.expect(try visibleFooterInvalidation(.reserved_gap_clear, 9, 6) == null);

    const visible = (try visibleFooterInvalidation(.reserved_gap_clear, 5, 6)).?;
    try std.testing.expectEqual(paint_plan.FrameInvalidationReason.reserved_gap_clear, visible.reason);
    try std.testing.expectEqual(@as(u16, 5), visible.top);
    try std.testing.expectEqual(@as(u16, 6), visible.bottom);

    const external = (try visibleFooterInvalidation(.external_clear, 5, 6)).?;
    try std.testing.expectEqual(paint_plan.FrameInvalidationReason.external_clear, external.reason);
    try std.testing.expectEqual(@as(u16, 5), external.top);
    try std.testing.expectEqual(@as(u16, 6), external.bottom);

    try std.testing.expectError(error.InvalidFooterInvalidationGeometry, visibleFooterInvalidation(.reserved_gap_clear, 0, 6));
    try std.testing.expectError(error.InvalidFooterInvalidationGeometry, visibleFooterInvalidation(.external_clear, 5, 0));
}

test "footer invalidation wrappers skip stale rows and record visible ranges" {
    var plan = surfaceTestPlan();
    try appendVisibleFooterInvalidation(&plan, .reserved_gap_clear, 9, 6, true);
    try std.testing.expect(plan.invalidation.isEmpty());

    try appendVisibleFooterInvalidation(&plan, .reserved_gap_clear, 5, 6, true);
    try std.testing.expect(surfaceHasInvalidation(plan.invalidation, .reserved_gap_clear, 5, 6));
    try std.testing.expectError(error.InvalidFooterInvalidationGeometry, appendVisibleFooterInvalidation(&plan, .reserved_gap_clear, 0, 6, true));

    var shell = TranscriptRuntime{};
    defer shell.deinit(std.testing.allocator);

    try recordVisibleExternalClearInvalidation(&shell, 9, 6);
    try std.testing.expect(shell.render_requests.pendingInvalidations().isEmpty());
    try std.testing.expectError(error.InvalidFooterInvalidationGeometry, recordVisibleExternalClearInvalidation(&shell, 5, 0));

    try recordVisibleExternalClearInvalidation(&shell, 5, 6);
    var merged_plan = surfaceTestPlan();
    mergeAttemptInvalidations(shell.render_requests.pendingInvalidations(), &merged_plan);
    try merged_plan.validate();
    try std.testing.expect(surfaceHasInvalidation(merged_plan.invalidation, .external_clear, 5, 6));
}

test "footer clear below a compact frame defers to owned band invalidation" {
    var plan = surfaceTestPlan();
    plan.layout.content_bottom = 1;
    plan.layout.divider_top_row = 2;
    plan.layout.input_row = 3;
    plan.layout.divider_bottom_row = 4;
    plan.layout.hint_row = 5;
    plan.viewport = .{
        .top_row = 1,
        .bottom_row = 1,
        .start_line = 0,
        .partial_skip_rows = 0,
        .line_count = 1,
        .last_visible_row = 1,
    };
    plan.footer = .{
        .top = 2,
        .top_divider = 2,
        .banner = 2,
        .banner_active = false,
        .input_base = 3,
        .picker_divider = 4,
        .picker_start = 5,
        .bottom_divider = 4,
        .hint = 5,
        .total_rows = 4,
    };
    plan.preserved_band = paint_plan.FrameBand.empty(.preserved_shell);
    plan.transcript_band = .{ .top = 1, .bottom = 1, .owner = .transcript };
    plan.footer_band = .{ .top = 2, .bottom = 5, .owner = .footer };
    plan.cursor_target = .{ .row = 3, .col = 1, .visible = true };
    try plan.validate();

    try appendVisibleFooterInvalidation(&plan, .external_clear, 6, plan.layout.rows, true);

    try std.testing.expect(plan.invalidation.isEmpty());
    try plan.validate();
}

test "attempt invalidations collapse instead of dropping when the plan is full" {
    var plan = surfaceTestPlan();
    var index: usize = 0;
    while (index < paint_plan.max_frame_invalidation_ranges) : (index += 1) {
        try plan.invalidation.append(.{
            .reason = .reserved_gap_clear,
            .top = 1,
            .bottom = 1,
        });
    }

    var attempt_invalidations = FrameInvalidationSet.empty();
    try attempt_invalidations.append(.{
        .reason = .shadow_feed_failure,
        .top = 2,
        .bottom = 8,
    });

    mergeAttemptInvalidations(attempt_invalidations, &plan);
    try plan.validate();
    try std.testing.expectEqual(@as(u8, 1), plan.invalidation.len);
    try std.testing.expectEqual(
        paint_plan.FrameInvalidationRange{
            .reason = .shadow_feed_failure,
            .top = 1,
            .bottom = 8,
        },
        plan.invalidation.ranges()[0],
    );
    try std.testing.expect(!plan.footer_clean_allowed);
}

test "attempt invalidation subsumes overlapping footer clear" {
    var plan = surfaceTestPlan();
    try plan.invalidation.append(.{
        .reason = .external_clear,
        .top = 5,
        .bottom = 8,
    });

    var attempt_invalidations = FrameInvalidationSet.empty();
    try attempt_invalidations.append(.{
        .reason = .resize,
        .top = 1,
        .bottom = 8,
    });

    mergeAttemptInvalidations(attempt_invalidations, &plan);

    try std.testing.expectEqual(@as(u8, 1), plan.invalidation.len);
    try std.testing.expectEqual(
        paint_plan.FrameInvalidationRange{
            .reason = .resize,
            .top = 1,
            .bottom = 8,
        },
        plan.invalidation.ranges()[0],
    );
}

test "footer growth invalidation collapses instead of dropping when the plan is full" {
    var plan = surfaceTestPlan();
    var index: usize = 0;
    while (index < paint_plan.max_frame_invalidation_ranges) : (index += 1) {
        try plan.invalidation.append(.{
            .reason = .reserved_gap_clear,
            .top = 1,
            .bottom = 1,
        });
    }

    footer_paint_plan.appendFooterFrameInvalidation(&plan.invalidation, .{
        .reason = .external_clear,
        .top = 5,
        .bottom = 8,
    });

    try plan.validate();
    try std.testing.expectEqual(@as(u8, 1), plan.invalidation.len);
    try std.testing.expectEqual(
        paint_plan.FrameInvalidationRange{
            .reason = .external_clear,
            .top = 1,
            .bottom = 8,
        },
        plan.invalidation.ranges()[0],
    );
}

test "reserved gap invalidation collapses instead of dropping when the plan is full" {
    var plan = surfaceTestPlan();
    var index: usize = 0;
    while (index < paint_plan.max_frame_invalidation_ranges) : (index += 1) {
        try plan.invalidation.append(.{
            .reason = .external_clear,
            .top = 5,
            .bottom = 5,
        });
    }

    try appendVisibleFooterInvalidation(&plan, .reserved_gap_clear, 1, 8, true);

    try plan.validate();
    try std.testing.expectEqual(@as(u8, 1), plan.invalidation.len);
    try std.testing.expectEqual(
        paint_plan.FrameInvalidationRange{
            .reason = .external_clear,
            .top = 1,
            .bottom = 8,
        },
        plan.invalidation.ranges()[0],
    );
}

test "footer shape invalidates when only composer top chrome changes" {
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
        .cursor_row = 7,
        .cursor_col = 1,
        .extra_input_rows = 0,
        .footer_reserved_base_rows = 3,
    };
    defer shell.deinit(std.testing.allocator);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry.top = 21;

    const update: FooterExtraUpdate = .{
        .footer_extra = 0,
        .footer_reserved_base_rows = 2,
        .input_extra = 0,
        .banner_active = false,
        .picker_rows = 0,
        .show_picker = false,
    };

    const invalidation = (try frameFooterExtraInvalidation(&shell, update)).?;
    try std.testing.expectEqual(paint_plan.FrameInvalidationReason.reserved_gap_clear, invalidation.reason);
    try std.testing.expectEqual(@as(u16, 21), invalidation.top);
    try std.testing.expectEqual(@as(u16, 24), invalidation.bottom);

    var force_redraw = false;
    try std.testing.expect(applyFrameFooterExtraUpdate(&shell, &force_redraw, update));
    try std.testing.expectEqual(@as(u16, 0), shell.extra_input_rows);
    try std.testing.expectEqual(@as(u16, 2), shell.footer_reserved_base_rows);
    try std.testing.expect(shell.footer_viewport.externally_invalidated);
    try std.testing.expect(force_redraw);
}

test "footer picker collapse destructively clears the previous footer band" {
    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 11,
            .divider_top_row = 12,
            .input_row = 13,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .cursor_row = 7,
        .cursor_col = 1,
        .extra_input_rows = 9,
        .footer_reserved_base_rows = 2,
    };
    defer shell.deinit(std.testing.allocator);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry.top = 12;

    const update: FooterExtraUpdate = .{
        .footer_extra = 0,
        .footer_reserved_base_rows = 2,
        .input_extra = 0,
        .banner_active = false,
        .picker_rows = 0,
        .show_picker = false,
    };

    const invalidation = (try frameFooterExtraInvalidation(&shell, update)).?;
    try std.testing.expectEqual(paint_plan.FrameInvalidationReason.external_clear, invalidation.reason);
    try std.testing.expectEqual(@as(u16, 12), invalidation.top);
    try std.testing.expectEqual(@as(u16, 24), invalidation.bottom);
}

test "candidate invalidations match final footer invalidations" {
    var shell = TranscriptRuntime{
        .layout = surfaceTestPlan().layout,
        .extra_input_rows = 3,
        .footer_reserved_base_rows = 2,
    };
    defer shell.deinit(std.testing.allocator);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry.top = 5;

    const update: FooterExtraUpdate = .{
        .footer_extra = 0,
        .footer_reserved_base_rows = 2,
        .input_extra = 0,
        .banner_active = false,
        .picker_rows = 0,
        .show_picker = false,
    };
    var attempt = FrameInvalidationSet.empty();
    try attempt.append(.{
        .reason = .owned_band_change,
        .top = 2,
        .bottom = 4,
    });

    const candidate = try resolveCandidateFrameInvalidations(
        &shell,
        surfaceTestPlan(),
        update,
        attempt,
    );

    var final_plan = surfaceTestPlan();
    var force_redraw = false;
    try appendMeasuredFooterExtraInvalidation(
        &shell,
        &final_plan,
        &force_redraw,
        update,
    );
    mergeAttemptInvalidations(attempt, &final_plan);

    try std.testing.expectEqualSlices(
        paint_plan.FrameInvalidationRange,
        candidate.ranges(),
        final_plan.invalidation.ranges(),
    );
}

test "measured footer picker collapse destructively clears the previous footer band" {
    var shell = TranscriptRuntime{
        .layout = .{
            .rows = 24,
            .cols = 80,
            .content_bottom = 11,
            .divider_top_row = 12,
            .input_row = 13,
            .divider_bottom_row = 23,
            .hint_row = 24,
        },
        .cursor_row = 7,
        .cursor_col = 1,
        .extra_input_rows = 9,
        .footer_reserved_base_rows = 2,
    };
    defer shell.deinit(std.testing.allocator);
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry.top = 12;

    var plan = surfaceTestPlan();
    plan.layout = shell.layout;
    plan.blank_band = .{ .top = 5, .bottom = 11, .owner = .gap };
    plan.footer = .{
        .top = 12,
        .top_divider = 12,
        .banner = 12,
        .banner_active = false,
        .input_base = 13,
        .picker_divider = 23,
        .picker_start = 24,
        .bottom_divider = 23,
        .hint = 24,
        .total_rows = 13,
    };
    plan.footer_band = .{ .top = 12, .bottom = 24, .owner = .footer };
    plan.cursor_target = .{ .row = 13, .col = 1, .visible = true };
    try plan.validate();
    var force_redraw = false;
    try appendMeasuredFooterExtraInvalidation(&shell, &plan, &force_redraw, .{
        .footer_extra = 0,
        .footer_reserved_base_rows = 2,
        .input_extra = 0,
        .banner_active = false,
        .picker_rows = 0,
        .show_picker = false,
    });

    try std.testing.expect(surfaceHasInvalidation(plan.invalidation, .external_clear, 12, 24));
    try std.testing.expect(!plan.footer_clean_allowed);
    try std.testing.expect(force_redraw);
    try plan.validate();
}

test "footer extra invalidation top prefers committed footer geometry" {
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
        .cursor_row = 7,
        .cursor_col = 1,
        .extra_input_rows = 1,
    };
    defer shell.deinit(std.testing.allocator);

    try std.testing.expectEqual(shell.footerTopRowForExtra(shell.extra_input_rows), footerExtraInvalidationTop(&shell));

    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry.top = 9;
    try std.testing.expectEqual(@as(u16, 9), footerExtraInvalidationTop(&shell));
}
