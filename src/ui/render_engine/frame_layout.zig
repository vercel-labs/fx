const std = @import("std");
const types = @import("../../core/shared/types.zig");
const activity_overlay = @import("activity_overlay.zig");
const footer_layout = @import("footer_layout.zig");
const paint_plan = @import("paint_plan.zig");
const transcript_blocks = @import("transcript_blocks.zig");
const viewport_selection = @import("viewport_selection.zig");

const Layout = types.Layout;

pub const FramePlacementPolicy = enum {
    compact_until_full,
};

pub const FrameRect = struct {
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn empty() FrameRect {
        return .{};
    }

    pub fn isEmpty(self: FrameRect) bool {
        return self.top == 0 and self.bottom == 0;
    }

    pub fn height(self: FrameRect) u16 {
        if (self.isEmpty()) return 0;
        return self.bottom - self.top + 1;
    }

    pub fn containsRow(self: FrameRect, row: u16) bool {
        return !self.isEmpty() and row >= self.top and row <= self.bottom;
    }

    pub fn toBand(self: FrameRect, owner: paint_plan.CellOwner) paint_plan.FrameBand {
        if (self.isEmpty()) return paint_plan.FrameBand.empty(owner);
        return .{ .top = self.top, .bottom = self.bottom, .owner = owner };
    }
};

pub const FooterMeasurement = struct {
    natural_rows: u16,
    min_rows: u16,
    max_rows: u16,
    top_gap_rows: u16 = 0,
    input_rows: u16 = 1,
    picker_rows: u16 = 0,
    banner_rows: u16 = 0,
};

pub const TranscriptFlowPreview = struct {
    natural_visual_rows: u16,
    trailing_boundary_blank_rows: u16 = 0,
    footer_boundary_gap_rows: u16 = 0,
    cursor_row: u16 = 1,
    cursor_col: u16 = 1,
    replaceable_row: u16 = 1,
    tail_kind: ?transcript_blocks.TranscriptBlockKind = null,
    replaceable_active: bool = false,
    welcome_split_active: bool = false,
    split_prefix_lines: usize = 0,
    split_suffix_start_line: usize = 0,
};

pub const ActivityState = union(enum) {
    none,
    thinking: Thinking,
    overlay_entry: u16,

    pub fn thinkingAfterUserTurn() ActivityState {
        return .{ .thinking = .{
            .gap_above_activity = transcript_blocks.blockGapRowsBetween(.user_turn, .assistant_turn),
            .footer_gap_after_activity = transcript_blocks.footerBoundaryGapRowsForTail(.turn_summary),
        } };
    }

    pub const Thinking = struct {
        gap_above_activity: u16,
        activity_rows: u16 = 1,
        footer_gap_after_activity: u16 = 0,
        tool_before_activity: bool = false,
    };
};

pub const BodyMode = enum {
    transcript,
    subagent_panel,
};

pub const CommittedLayoutSnapshot = struct {
    layout_id: u64 = 0,
    owned_top: u16 = 1,
    owned_band: FrameRect = .{},
    body_area: FrameRect = .{},
    transcript_area: FrameRect = .{},
    footer_area: FrameRect = .{},
    activity_row: ?u16 = null,
    activity_rows: u16 = 0,
    tool_activity_row: ?u16 = null,
    solved_frame_height: u16 = 0,
    terminal_rows: u16 = 0,
    terminal_cols: u16 = 0,

    pub fn fromLayout(layout: FrameLayout) CommittedLayoutSnapshot {
        return .{
            .layout_id = layout.layout_id,
            .owned_top = layout.owned_top,
            .owned_band = layout.owned_band,
            .body_area = layout.body_area,
            .transcript_area = layout.transcript_area,
            .footer_area = layout.footer_area,
            .activity_row = layout.activity_row,
            .activity_rows = layout.activity_rows,
            .tool_activity_row = layout.tool_activity_row,
            .solved_frame_height = layout.solved_frame_height,
            .terminal_rows = layout.terminal.rows,
            .terminal_cols = layout.terminal.cols,
        };
    }

    pub fn fromPaintPlan(plan: paint_plan.PaintPlan) CommittedLayoutSnapshot {
        const owned_top = if (!plan.preserved_band.isEmpty())
            plan.preserved_band.bottom + 1
        else
            firstOwnedRow(plan);
        const owned_bottom = lastOwnedRow(plan);
        const owned_band = if (owned_top > 0 and owned_bottom >= owned_top)
            FrameRect{ .top = owned_top, .bottom = owned_bottom }
        else
            FrameRect.empty();
        const footer_area = rectFromBand(plan.footer_band);
        const body_bottom = if (footer_area.isEmpty())
            owned_bottom
        else
            footer_area.top -| 1;
        const body_area = if (!owned_band.isEmpty() and body_bottom >= owned_top)
            FrameRect{ .top = owned_top, .bottom = body_bottom }
        else
            FrameRect.empty();

        var layout = FrameLayout{
            .layout_id = 0,
            .terminal = plan.layout,
            .owned_top = owned_top,
            .owned_band = owned_band,
            .body_area = body_area,
            .transcript_area = rectFromBand(plan.transcript_band),
            .footer_area = footer_area,
            .activity_row = plan.activity.row(),
            .activity_rows = plan.activity.primaryRowCount(),
            .tool_activity_row = plan.activity.toolRow(),
            .blank_area = rectFromBand(plan.blank_band),
            .footer_gap_area = rectFromBand(plan.footer_gap_band),
            .solved_frame_height = owned_band.height(),
            .placement_policy = .compact_until_full,
        };
        layout.layout_id = layoutId(layout);
        return fromLayout(layout);
    }
};

pub const PromptTurnReservation = struct {
    transcript_rows: u16 = 0,
    activity: ActivityState = .none,

    pub fn active(self: PromptTurnReservation) bool {
        return self.transcript_rows > 0 and self.activity != .none;
    }
};

pub const SolveInput = struct {
    terminal: Layout,
    owned_top: u16,
    footer: FooterMeasurement,
    transcript: TranscriptFlowPreview,
    activity: ActivityState = .none,
    prompt_turn: PromptTurnReservation = .{},
    body_mode: BodyMode = .transcript,
    prior: CommittedLayoutSnapshot = .{},
    placement_policy: FramePlacementPolicy = .compact_until_full,
};

pub const PreservedRowReleasePlan = struct {
    layout: FrameLayout,
    released_rows: u16,
};

pub const FrameLayout = struct {
    layout_id: u64,
    terminal: Layout,
    owned_top: u16,
    owned_band: FrameRect,
    body_area: FrameRect,
    transcript_area: FrameRect,
    footer_area: FrameRect,
    activity_row: ?u16,
    activity_rows: u16 = 0,
    tool_activity_row: ?u16 = null,
    blank_area: FrameRect,
    footer_gap_area: FrameRect,
    solved_frame_height: u16,
    placement_policy: FramePlacementPolicy,

    pub fn toPaintPlan(self: FrameLayout, options: PaintPlanOptions) paint_plan.PaintPlan {
        const footer_rows = shiftFooterRows(options.footer_rows, self.footer_area.top);
        const activity = shiftActivity(options.activity, self.activity_row, self.activity_rows, self.tool_activity_row, self.transcript_area);
        const preserved_band = if (self.owned_top > 1)
            paint_plan.FrameBand{ .top = 1, .bottom = self.owned_top - 1, .owner = .preserved_shell }
        else
            paint_plan.FrameBand.empty(.preserved_shell);
        const layout = Layout{
            .rows = self.terminal.rows,
            .cols = self.terminal.cols,
            .content_bottom = if (self.body_area.isEmpty()) self.owned_top else self.body_area.bottom,
            .divider_top_row = footer_rows.top_divider,
            .input_row = footer_rows.input_base,
            .divider_bottom_row = footer_rows.bottom_divider,
            .hint_row = footer_rows.hint,
        };

        return .{
            .layout = layout,
            .viewport = options.viewport,
            .footer = footer_rows,
            .activity = activity,
            .preserved_band = preserved_band,
            .transcript_band = self.transcript_area.toBand(.transcript),
            .blank_band = self.blank_area.toBand(.gap),
            .activity_band = paint_plan.activityBand(activity),
            .footer_gap_band = self.footer_gap_area.toBand(.gap),
            .footer_band = self.footer_area.toBand(.footer),
            .invalidation = options.invalidation,
            .footer_clean_allowed = options.invalidation.isEmpty(),
            .synchronized_update = options.synchronized_update,
            .cursor_target = options.cursor_target,
            .footer_reservation_source = .none,
            .bottom_reserved_rows = 0,
            .preserve_scrollback = options.preserve_scrollback,
            .reset_terminal = options.reset_terminal,
        };
    }
};

pub const PaintPlanOptions = struct {
    footer_rows: footer_layout.FooterRows,
    viewport: viewport_selection.ViewportSelection,
    activity: activity_overlay.ActivityPlacement = .none,
    invalidation: paint_plan.FrameInvalidationSet = paint_plan.FrameInvalidationSet.empty(),
    synchronized_update: bool = true,
    cursor_target: ?paint_plan.FrameCursorTarget = null,
    preserve_scrollback: bool = true,
    reset_terminal: bool = false,
};

pub fn solve(input: SolveInput) FrameLayout {
    const terminal_rows = input.terminal.rows;
    const owned_top = clampOwnedTop(input.owned_top, terminal_rows);
    const available_rows = rowsAvailableBelow(terminal_rows, owned_top);
    const footer_height = solveFooterHeight(input.footer, available_rows);
    const reservation = solveActivityReservation(input, footer_height, available_rows);

    const reserved_activity_rows = reservation.boundary_gap +| reservation.activity_rows +| reservation.footer_gap;
    const body_capacity = available_rows -| footer_height -| reserved_activity_rows;
    const natural_body_rows = switch (input.body_mode) {
        .transcript, .subagent_panel => input.transcript.natural_visual_rows,
    };
    const transcript_height = @min(natural_body_rows, body_capacity);
    const natural_content_rows = transcript_height +| reserved_activity_rows +| footer_height;
    const transition_rows = solvePromptTurnReservation(input, footer_height, available_rows);
    const solved_frame_height = @min(available_rows, @max(natural_content_rows, transition_rows));
    const neutral_rows = solved_frame_height -| natural_content_rows;
    const owned_band = rectFromTopHeight(owned_top, solved_frame_height);
    const transcript_area = rectFromTopHeight(owned_top, transcript_height);
    const blank_top = if (transcript_area.isEmpty()) owned_top else transcript_area.bottom + 1;
    const blank_area = rectFromTopHeight(blank_top, reservation.boundary_gap +| neutral_rows);
    const activity_row: ?u16 = if (reservation.activity_rows > 0)
        if (reservation.tool_before_activity)
            blank_top + reservation.boundary_gap + 2
        else
            blank_top + reservation.boundary_gap
    else
        null;
    const tool_activity_row: ?u16 = if (reservation.tool_before_activity)
        blank_top + reservation.boundary_gap
    else
        null;
    const footer_gap_top = if (activity_row) |row| row + reservation.primary_rows else blank_top + reservation.boundary_gap;
    const footer_gap_area = rectFromTopHeight(footer_gap_top, reservation.footer_gap);
    const footer_top = if (footer_height > 0 and !owned_band.isEmpty())
        owned_band.bottom - footer_height + 1
    else
        0;
    const footer_area = rectFromTopHeight(footer_top, footer_height);
    const body_bottom = if (footer_area.isEmpty()) owned_band.bottom else footer_area.top -| 1;
    const body_area = if (!owned_band.isEmpty() and body_bottom >= owned_band.top)
        FrameRect{ .top = owned_band.top, .bottom = body_bottom }
    else
        FrameRect.empty();

    var result = FrameLayout{
        .layout_id = 0,
        .terminal = input.terminal,
        .owned_top = owned_top,
        .owned_band = owned_band,
        .body_area = body_area,
        .transcript_area = transcript_area,
        .footer_area = footer_area,
        .activity_row = activity_row,
        .activity_rows = if (activity_row != null) reservation.primary_rows else 0,
        .tool_activity_row = tool_activity_row,
        .blank_area = blank_area,
        .footer_gap_area = footer_gap_area,
        .solved_frame_height = solved_frame_height,
        .placement_policy = input.placement_policy,
    };
    result.layout_id = layoutId(result);
    return result;
}

pub fn solveWithPreservedRowRelease(input: SolveInput, release_floor_rows: u16) PreservedRowReleasePlan {
    const initial = solve(input);
    if (input.terminal.rows == 0 or input.terminal.cols == 0) {
        return .{ .layout = initial, .released_rows = 0 };
    }

    var maximum_input = input;
    maximum_input.owned_top = 1;
    if (input.owned_top == 1) maximum_input.prompt_turn = .{};
    const maximum = solve(maximum_input);
    const geometry_top = if (maximum.solved_frame_height == 0)
        initial.owned_top
    else
        @min(initial.owned_top, input.terminal.rows - maximum.solved_frame_height + 1);
    const floor_top = @max(@as(u16, 1), initial.owned_top -| release_floor_rows);

    var final_input = input;
    final_input.owned_top = @min(geometry_top, floor_top);
    const final = solve(final_input);
    return .{
        .layout = final,
        .released_rows = initial.owned_top -| final.owned_top,
    };
}

fn solvePromptTurnReservation(input: SolveInput, footer_height: u16, available_rows: u16) u16 {
    if (input.activity != .none or !input.prompt_turn.active()) return 0;
    var prompt_turn_input = input;
    prompt_turn_input.transcript.natural_visual_rows = input.prompt_turn.transcript_rows;
    prompt_turn_input.activity = input.prompt_turn.activity;
    prompt_turn_input.prompt_turn = .{};
    const reservation = solveActivityReservation(prompt_turn_input, footer_height, available_rows);
    return input.prompt_turn.transcript_rows +|
        reservation.boundary_gap +|
        reservation.activity_rows +|
        reservation.footer_gap +|
        footer_height;
}

const ActivityReservation = struct {
    boundary_gap: u16 = 0,
    activity_rows: u16 = 0,
    primary_rows: u16 = 1,
    footer_gap: u16 = 0,
    tool_before_activity: bool = false,
};

fn solveActivityReservation(input: SolveInput, footer_height: u16, available_rows: u16) ActivityReservation {
    const min_body_rows: u16 = if (input.transcript.natural_visual_rows > 0) 1 else 0;
    switch (input.activity) {
        .thinking => |thinking| {
            const primary_rows = @max(thinking.activity_rows, 1);
            const full_rows: u16 = if (thinking.tool_before_activity) primary_rows +| 2 else primary_rows;
            const fixed_rows = footer_height +| min_body_rows +| thinking.gap_above_activity +| thinking.footer_gap_after_activity;
            if (available_rows >= fixed_rows +| full_rows) return .{
                .boundary_gap = thinking.gap_above_activity,
                .activity_rows = full_rows,
                .primary_rows = primary_rows,
                .footer_gap = thinking.footer_gap_after_activity,
                .tool_before_activity = thinking.tool_before_activity,
            };
            if (available_rows >= fixed_rows +| 1) return .{
                .boundary_gap = thinking.gap_above_activity,
                .activity_rows = 1,
                .footer_gap = thinking.footer_gap_after_activity,
            };
        },
        .overlay_entry, .none => {},
    }
    const transcript_gap = @max(
        input.transcript.trailing_boundary_blank_rows,
        input.transcript.footer_boundary_gap_rows,
    );
    const idle_gap = @max(transcript_gap, input.footer.top_gap_rows);
    if (idle_gap > 0 and footer_height > 0 and available_rows >= footer_height +| min_body_rows +| idle_gap) {
        return .{ .boundary_gap = idle_gap };
    }
    return .{};
}

fn clampOwnedTop(owned_top: u16, terminal_rows: u16) u16 {
    if (terminal_rows == 0) return 0;
    if (owned_top == 0) return 1;
    return @min(owned_top, terminal_rows);
}

fn rowsAvailableBelow(terminal_rows: u16, owned_top: u16) u16 {
    if (terminal_rows == 0 or owned_top == 0 or owned_top > terminal_rows) return 0;
    return terminal_rows - owned_top + 1;
}

fn rectFromBand(band: paint_plan.FrameBand) FrameRect {
    if (band.isEmpty()) return .empty();
    return .{ .top = band.top, .bottom = band.bottom };
}

fn firstOwnedRow(plan: paint_plan.PaintPlan) u16 {
    const bands = [_]paint_plan.FrameBand{
        plan.transcript_band,
        plan.blank_band,
        plan.activity_band,
        plan.footer_gap_band,
        plan.footer_band,
    };
    var first: u16 = 0;
    for (bands) |band| {
        if (band.isEmpty()) continue;
        if (first == 0 or band.top < first) first = band.top;
    }
    return first;
}

fn lastOwnedRow(plan: paint_plan.PaintPlan) u16 {
    const bands = [_]paint_plan.FrameBand{
        plan.transcript_band,
        plan.blank_band,
        plan.activity_band,
        plan.footer_gap_band,
        plan.footer_band,
    };
    var last: u16 = 0;
    for (bands) |band| {
        if (!band.isEmpty()) last = @max(last, band.bottom);
    }
    return last;
}

fn solveFooterHeight(measurement: FooterMeasurement, available_rows: u16) u16 {
    if (available_rows == 0) return 0;
    const max_rows = if (measurement.max_rows == 0) measurement.natural_rows else measurement.max_rows;
    const min_rows = @min(measurement.min_rows, max_rows);
    const natural = @min(@max(measurement.natural_rows, min_rows), max_rows);
    return @min(natural, available_rows);
}

fn rectFromTopHeight(top: u16, height_rows: u16) FrameRect {
    if (top == 0 or height_rows == 0) return FrameRect.empty();
    return .{ .top = top, .bottom = top + height_rows - 1 };
}

fn layoutId(layout: FrameLayout) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hashU16(&hasher, layout.terminal.rows);
    hashU16(&hasher, layout.terminal.cols);
    hashU16(&hasher, layout.owned_top);
    hashRect(&hasher, layout.owned_band);
    hashRect(&hasher, layout.body_area);
    hashRect(&hasher, layout.transcript_area);
    hashRect(&hasher, layout.footer_area);
    hashU16(&hasher, layout.activity_row orelse 0);
    hashU16(&hasher, layout.activity_rows);
    hashU16(&hasher, layout.tool_activity_row orelse 0);
    hashRect(&hasher, layout.blank_area);
    hashRect(&hasher, layout.footer_gap_area);
    hashU16(&hasher, layout.solved_frame_height);
    hashU16(&hasher, @intFromEnum(layout.placement_policy));
    const value = hasher.final();
    return if (value == 0) 1 else value;
}

fn hashRect(hasher: *std.hash.Wyhash, rect: FrameRect) void {
    hashU16(hasher, rect.top);
    hashU16(hasher, rect.bottom);
}

fn hashU16(hasher: *std.hash.Wyhash, value: u16) void {
    hasher.update(std.mem.asBytes(&value));
}

fn shiftFooterRows(rows: footer_layout.FooterRows, top: u16) footer_layout.FooterRows {
    if (top == 0 or rows.top == top) return rows;
    return .{
        .top = top,
        .top_divider = shiftRow(rows.top_divider, rows.top, top),
        .banner = shiftRow(rows.banner, rows.top, top),
        .banner_active = rows.banner_active,
        .input_base = shiftRow(rows.input_base, rows.top, top),
        .picker_divider = shiftRow(rows.picker_divider, rows.top, top),
        .picker_start = shiftRow(rows.picker_start, rows.top, top),
        .bottom_divider = shiftRow(rows.bottom_divider, rows.top, top),
        .hint = shiftRow(rows.hint, rows.top, top),
        .total_rows = rows.total_rows,
    };
}

fn shiftRow(row: u16, old_top: u16, new_top: u16) u16 {
    if (row <= old_top) return new_top;
    return new_top + (row - old_top);
}

fn shiftActivity(
    activity: activity_overlay.ActivityPlacement,
    row: ?u16,
    row_count: u16,
    tool_row: ?u16,
    transcript_area: FrameRect,
) activity_overlay.ActivityPlacement {
    return switch (activity) {
        .transient_row => |transient| if (row) |solved_row|
            .{ .transient_row = .{
                .row = solved_row,
                .row_count = @max(row_count, 1),
                .gap_above_rows = transient.gap_above_rows,
                .footer_clearance_rows = transient.footer_clearance_rows,
                .tool_row = tool_row,
            } }
        else
            .none,
        .overlay_entry => |overlay_row| blk: {
            break :blk if (transcript_area.containsRow(overlay_row))
                .{ .overlay_entry = overlay_row }
            else
                .none;
        },
        .none => .none,
    };
}

fn testLayout(rows: u16, cols: u16) Layout {
    return .{
        .rows = rows,
        .cols = cols,
        .content_bottom = if (rows > 4) rows - 4 else 1,
        .divider_top_row = if (rows > 3) rows - 3 else 1,
        .input_row = if (rows > 2) rows - 2 else 1,
        .divider_bottom_row = if (rows > 1) rows - 1 else 1,
        .hint_row = rows,
    };
}

fn testFooter(rows: u16) FooterMeasurement {
    return .{
        .natural_rows = rows,
        .min_rows = @min(rows, 1),
        .max_rows = rows,
    };
}

test "short transcript keeps compact inline layout with preserved rows below" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{ .natural_visual_rows = 2 },
    });

    try std.testing.expectEqual(@as(u16, 6), layout.solved_frame_height);
    try std.testing.expectEqual(FrameRect{ .top = 4, .bottom = 9 }, layout.owned_band);
    try std.testing.expectEqual(FrameRect{ .top = 4, .bottom = 5 }, layout.transcript_area);
    try std.testing.expectEqual(FrameRect{ .top = 6, .bottom = 9 }, layout.footer_area);
    try std.testing.expect(layout.owned_band.bottom < layout.terminal.rows);
}

test "footer reaches terminal bottom only when solved frame fills available rows" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{ .natural_visual_rows = 64 },
    });

    try std.testing.expectEqual(@as(u16, 21), layout.solved_frame_height);
    try std.testing.expectEqual(@as(u16, 24), layout.owned_band.bottom);
    try std.testing.expectEqual(FrameRect{ .top = 21, .bottom = 24 }, layout.footer_area);
}

test "content overflow no longer moves owned top from inside frame layout" {
    const layout = solve(.{
        .terminal = testLayout(10, 80),
        .owned_top = 5,
        .footer = testFooter(2),
        .transcript = .{ .natural_visual_rows = 32 },
    });

    try std.testing.expectEqual(@as(u16, 5), layout.owned_top);
    try std.testing.expectEqual(FrameRect{ .top = 5, .bottom = 10 }, layout.owned_band);
    try std.testing.expectEqual(FrameRect{ .top = 9, .bottom = 10 }, layout.footer_area);
}

test "content overflow does not create native terminal scroll after top is owned" {
    const layout = solve(.{
        .terminal = testLayout(10, 80),
        .owned_top = 1,
        .footer = testFooter(2),
        .transcript = .{ .natural_visual_rows = 32 },
    });

    try std.testing.expectEqual(@as(u16, 1), layout.owned_top);
    try std.testing.expectEqual(FrameRect{ .top = 1, .bottom = 10 }, layout.owned_band);
    try std.testing.expectEqual(FrameRect{ .top = 9, .bottom = 10 }, layout.footer_area);
}

test "solve uses caller provided post scroll owned top directly" {
    const layout = solve(.{
        .terminal = testLayout(10, 80),
        .owned_top = 2,
        .footer = testFooter(2),
        .transcript = .{ .natural_visual_rows = 32 },
    });

    try std.testing.expectEqual(@as(u16, 2), layout.owned_top);
    try std.testing.expectEqual(FrameRect{ .top = 2, .bottom = 10 }, layout.owned_band);
}

test "preserved row release planner keeps short frames inside the initial band" {
    const plan = solveWithPreservedRowRelease(.{
        .terminal = testLayout(10, 80),
        .owned_top = 5,
        .footer = testFooter(2),
        .transcript = .{ .natural_visual_rows = 2 },
    }, 0);

    try std.testing.expectEqual(@as(u16, 0), plan.released_rows);
    try std.testing.expectEqual(@as(u16, 5), plan.layout.owned_top);
}

test "preserved row release planner releases the minimum rows for moderate growth" {
    const plan = solveWithPreservedRowRelease(.{
        .terminal = testLayout(10, 80),
        .owned_top = 5,
        .footer = testFooter(2),
        .transcript = .{ .natural_visual_rows = 5 },
    }, 0);

    try std.testing.expectEqual(@as(u16, 1), plan.released_rows);
    try std.testing.expectEqual(@as(u16, 4), plan.layout.owned_top);
}

test "preserved row release planner releases through row one for long growth" {
    const plan = solveWithPreservedRowRelease(.{
        .terminal = testLayout(10, 80),
        .owned_top = 5,
        .footer = testFooter(2),
        .transcript = .{ .natural_visual_rows = 64 },
    }, 0);

    try std.testing.expectEqual(@as(u16, 4), plan.released_rows);
    try std.testing.expectEqual(@as(u16, 1), plan.layout.owned_top);
}

test "preserved row release planner releases rows for footer only expansion" {
    const plan = solveWithPreservedRowRelease(.{
        .terminal = testLayout(10, 80),
        .owned_top = 5,
        .footer = testFooter(7),
        .transcript = .{ .natural_visual_rows = 0 },
    }, 0);

    try std.testing.expectEqual(@as(u16, 1), plan.released_rows);
    try std.testing.expectEqual(@as(u16, 4), plan.layout.owned_top);
}

test "preserved row release planner uses footer picker geometry" {
    const plan = solveWithPreservedRowRelease(.{
        .terminal = testLayout(10, 80),
        .owned_top = 5,
        .footer = .{
            .natural_rows = 8,
            .min_rows = 1,
            .max_rows = 8,
            .input_rows = 1,
            .picker_rows = 4,
        },
        .transcript = .{ .natural_visual_rows = 0 },
    }, 0);

    try std.testing.expectEqual(@as(u16, 2), plan.released_rows);
    try std.testing.expectEqual(@as(u16, 3), plan.layout.owned_top);
}

test "preserved row release planner keeps row one unchanged" {
    const plan = solveWithPreservedRowRelease(.{
        .terminal = testLayout(10, 80),
        .owned_top = 1,
        .footer = testFooter(2),
        .transcript = .{ .natural_visual_rows = 64 },
    }, 4);

    try std.testing.expectEqual(@as(u16, 0), plan.released_rows);
    try std.testing.expectEqual(@as(u16, 1), plan.layout.owned_top);
}

test "preserved row release planner returns zero release for invalid dimensions" {
    const zero_rows = solveWithPreservedRowRelease(.{
        .terminal = testLayout(0, 80),
        .owned_top = 5,
        .footer = testFooter(2),
        .transcript = .{ .natural_visual_rows = 64 },
    }, 4);
    const zero_cols = solveWithPreservedRowRelease(.{
        .terminal = testLayout(10, 0),
        .owned_top = 5,
        .footer = testFooter(2),
        .transcript = .{ .natural_visual_rows = 64 },
    }, 4);

    try std.testing.expectEqual(@as(u16, 0), zero_rows.released_rows);
    try std.testing.expectEqual(@as(u16, 0), zero_cols.released_rows);
}

test "layout id ignores non layout-affecting cursor column changes" {
    const base = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{ .natural_visual_rows = 3, .cursor_col = 1 },
    });
    const repaint = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{ .natural_visual_rows = 3, .cursor_col = 18 },
    });

    try std.testing.expect(base.layout_id != 0);
    try std.testing.expectEqual(base.layout_id, repaint.layout_id);
}

test "prompt turn reservation aligns pending frames with thinking" {
    const idle = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 1,
        .footer = testFooter(3),
        .transcript = .{ .natural_visual_rows = 5 },
        .prompt_turn = .{ .transcript_rows = 7, .activity = .{ .thinking = .{ .gap_above_activity = 1, .footer_gap_after_activity = 1 } } },
    });
    const pending = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 1,
        .footer = testFooter(3),
        .transcript = .{ .natural_visual_rows = 8 },
        .prompt_turn = .{ .transcript_rows = 7, .activity = .{ .thinking = .{ .gap_above_activity = 1, .footer_gap_after_activity = 1 } } },
    });
    const adopted = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 1,
        .footer = testFooter(3),
        .transcript = .{ .natural_visual_rows = 7 },
        .prompt_turn = .{ .transcript_rows = 7, .activity = .{ .thinking = .{ .gap_above_activity = 1, .footer_gap_after_activity = 1 } } },
    });
    const thinking = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 1,
        .footer = testFooter(3),
        .transcript = .{ .natural_visual_rows = 7 },
        .activity = .{ .thinking = .{ .gap_above_activity = 1, .footer_gap_after_activity = 1 } },
    });

    inline for (.{ idle, pending, adopted, thinking }) |layout| {
        try std.testing.expectEqual(FrameRect{ .top = 11, .bottom = 13 }, layout.footer_area);
        try std.testing.expectEqual(@as(u16, 13), layout.solved_frame_height);
    }
    try std.testing.expectEqual(@as(?u16, null), idle.activity_row);
    try std.testing.expectEqual(@as(u16, 5), idle.blank_area.height());
    try std.testing.expectEqual(@as(?u16, null), pending.activity_row);
    try std.testing.expectEqual(@as(u16, 2), pending.blank_area.height());
    try std.testing.expectEqual(@as(?u16, null), adopted.activity_row);
    try std.testing.expectEqual(@as(u16, 3), adopted.blank_area.height());
    try std.testing.expectEqual(@as(?u16, 9), thinking.activity_row);
}

test "real activity supersedes prompt turn reservation" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 1,
        .footer = testFooter(3),
        .transcript = .{ .natural_visual_rows = 7 },
        .activity = .{ .thinking = .{ .gap_above_activity = 1, .footer_gap_after_activity = 1 } },
        .prompt_turn = .{ .transcript_rows = 20, .activity = .{ .thinking = .{ .gap_above_activity = 1, .footer_gap_after_activity = 1 } } },
    });

    try std.testing.expectEqual(@as(?u16, 9), layout.activity_row);
    try std.testing.expectEqual(FrameRect{ .top = 11, .bottom = 13 }, layout.footer_area);
    try std.testing.expectEqual(@as(u16, 13), layout.solved_frame_height);
}

test "prompt turn reservation participates in preserved row release" {
    const input = SolveInput{
        .terminal = testLayout(10, 80),
        .owned_top = 5,
        .footer = testFooter(3),
        .transcript = .{ .natural_visual_rows = 2 },
        .prompt_turn = .{ .transcript_rows = 7, .activity = .{ .thinking = .{ .gap_above_activity = 1, .footer_gap_after_activity = 1 } } },
    };
    const plan = solveWithPreservedRowRelease(input, 0);

    try std.testing.expectEqual(@as(u16, 1), plan.layout.owned_top);
    try std.testing.expectEqual(@as(u16, 4), plan.released_rows);
    try std.testing.expectEqual(FrameRect{ .top = 8, .bottom = 10 }, plan.layout.footer_area);
}

test "prompt turn reservation clamps to terminal height" {
    const layout = solve(.{
        .terminal = testLayout(8, 80),
        .owned_top = 1,
        .footer = testFooter(3),
        .transcript = .{ .natural_visual_rows = 6 },
        .prompt_turn = .{ .transcript_rows = 7, .activity = .{ .thinking = .{ .gap_above_activity = 1, .footer_gap_after_activity = 1 } } },
    });

    try std.testing.expectEqual(@as(u16, 8), layout.solved_frame_height);
    try std.testing.expectEqual(@as(u16, 5), layout.transcript_area.height());
    try std.testing.expectEqual(@as(u16, 0), layout.blank_area.height());
    try std.testing.expectEqual(FrameRect{ .top = 6, .bottom = 8 }, layout.footer_area);
}

test "thinking activity owns a deterministic leading blank gap without moving footer separately" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{ .natural_visual_rows = 2 },
        .activity = .{ .thinking = .{ .gap_above_activity = 1 } },
    });

    try std.testing.expectEqual(FrameRect{ .top = 4, .bottom = 5 }, layout.transcript_area);
    try std.testing.expectEqual(FrameRect{ .top = 6, .bottom = 6 }, layout.blank_area);
    try std.testing.expectEqual(@as(?u16, 7), layout.activity_row);
    try std.testing.expectEqual(FrameRect{ .top = 8, .bottom = 11 }, layout.footer_area);
}

test "thinking activity can reserve the future summary footer gap" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{ .natural_visual_rows = 2 },
        .activity = .{ .thinking = .{ .gap_above_activity = 1, .footer_gap_after_activity = 1 } },
    });

    try std.testing.expectEqual(FrameRect{ .top = 4, .bottom = 5 }, layout.transcript_area);
    try std.testing.expectEqual(FrameRect{ .top = 6, .bottom = 6 }, layout.blank_area);
    try std.testing.expectEqual(@as(?u16, 7), layout.activity_row);
    try std.testing.expectEqual(FrameRect{ .top = 8, .bottom = 8 }, layout.footer_gap_area);
    try std.testing.expectEqual(FrameRect{ .top = 9, .bottom = 12 }, layout.footer_area);
}

test "tool plus thinking falls back to the pinned tool row when space is short" {
    const layout = solve(.{
        .terminal = testLayout(9, 80),
        .owned_top = 1,
        .footer = testFooter(4),
        .transcript = .{ .natural_visual_rows = 1 },
        .activity = .{ .thinking = .{
            .gap_above_activity = 1,
            .footer_gap_after_activity = 1,
            .tool_before_activity = true,
        } },
    });

    try std.testing.expect(layout.activity_row != null);
    try std.testing.expectEqual(@as(?u16, null), layout.tool_activity_row);
    try std.testing.expectEqual(@as(u16, 1), layout.footer_gap_area.height());
}

test "wrapped status activity falls back to one row when full height is short" {
    const layout = solve(.{
        .terminal = testLayout(8, 80),
        .owned_top = 1,
        .footer = testFooter(4),
        .transcript = .{ .natural_visual_rows = 1 },
        .activity = .{ .thinking = .{
            .gap_above_activity = 1,
            .activity_rows = 3,
            .footer_gap_after_activity = 1,
        } },
    });

    try std.testing.expectEqual(@as(?u16, 3), layout.activity_row);
    try std.testing.expectEqual(@as(u16, 1), layout.activity_rows);
    try std.testing.expectEqual(@as(?u16, null), layout.tool_activity_row);
    try std.testing.expectEqual(FrameRect{ .top = 5, .bottom = 8 }, layout.footer_area);

    const plan = layout.toPaintPlan(.{
        .footer_rows = testFooterRows(1, 4),
        .viewport = .{
            .top_row = layout.transcript_area.top,
            .bottom_row = layout.transcript_area.bottom,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
            .last_visible_row = layout.transcript_area.bottom,
        },
        .activity = .{ .transient_row = .{ .row = layout.activity_row.?, .row_count = 3, .gap_above_rows = 1, .footer_clearance_rows = 1 } },
        .cursor_target = .{ .row = 1, .col = 1, .visible = false },
    });

    try std.testing.expectEqual(paint_plan.FrameBand{ .top = 3, .bottom = 3, .owner = .activity }, plan.activity_band);
    try std.testing.expectEqual(@as(u16, 1), switch (plan.activity) {
        .transient_row => |activity| activity.row_count,
        .none, .overlay_entry => 0,
    });
    try plan.validate();
}

test "thinking gap does not stack with transcript trailing boundary blank rows" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{
            .natural_visual_rows = 2,
            .trailing_boundary_blank_rows = 1,
        },
        .activity = .{ .thinking = .{ .gap_above_activity = 1 } },
    });

    try std.testing.expectEqual(FrameRect{ .top = 4, .bottom = 5 }, layout.transcript_area);
    try std.testing.expectEqual(FrameRect{ .top = 6, .bottom = 6 }, layout.blank_area);
    try std.testing.expectEqual(@as(?u16, 7), layout.activity_row);
    try std.testing.expectEqual(FrameRect{ .top = 8, .bottom = 11 }, layout.footer_area);
}

test "inactive response tail reserves one footer boundary gap" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{
            .natural_visual_rows = 2,
            .footer_boundary_gap_rows = 1,
        },
    });

    try std.testing.expectEqual(FrameRect{ .top = 4, .bottom = 5 }, layout.transcript_area);
    try std.testing.expectEqual(FrameRect{ .top = 6, .bottom = 6 }, layout.blank_area);
    try std.testing.expectEqual(@as(?u16, null), layout.activity_row);
    try std.testing.expectEqual(FrameRect{ .top = 7, .bottom = 10 }, layout.footer_area);
}

test "footer request reserves a boundary gap after a user tail" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = .{
            .natural_rows = 4,
            .min_rows = 1,
            .max_rows = 4,
            .top_gap_rows = 1,
        },
        .transcript = .{
            .natural_visual_rows = 2,
            .footer_boundary_gap_rows = 0,
        },
    });

    try std.testing.expectEqual(FrameRect{ .top = 4, .bottom = 5 }, layout.transcript_area);
    try std.testing.expectEqual(FrameRect{ .top = 6, .bottom = 6 }, layout.blank_area);
    try std.testing.expectEqual(FrameRect{ .top = 7, .bottom = 10 }, layout.footer_area);
}

test "thinking gap does not stack with semantic footer boundary gap" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{
            .natural_visual_rows = 2,
            .footer_boundary_gap_rows = 1,
        },
        .activity = .{ .thinking = .{ .gap_above_activity = 1 } },
    });

    try std.testing.expectEqual(FrameRect{ .top = 4, .bottom = 5 }, layout.transcript_area);
    try std.testing.expectEqual(FrameRect{ .top = 6, .bottom = 6 }, layout.blank_area);
    try std.testing.expectEqual(@as(?u16, 7), layout.activity_row);
    try std.testing.expectEqual(FrameRect{ .top = 8, .bottom = 11 }, layout.footer_area);
}

test "trailing boundary blanks do not add to thinking gap" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{
            .natural_visual_rows = 2,
            .trailing_boundary_blank_rows = 2,
        },
        .activity = .{ .thinking = .{ .gap_above_activity = 1 } },
    });

    try std.testing.expectEqual(FrameRect{ .top = 6, .bottom = 6 }, layout.blank_area);
    try std.testing.expectEqual(@as(?u16, 7), layout.activity_row);
    try std.testing.expectEqual(FrameRect{ .top = 8, .bottom = 11 }, layout.footer_area);
}

test "thinking gap clears exactly one solved blank row in frame surface" {
    const frame_surface = @import("frame_surface.zig");
    const vt_emulator = @import("../../core/terminal/engine.zig");
    const alloc = std.testing.allocator;
    const layout = solve(.{
        .terminal = testLayout(12, 40),
        .owned_top = 4,
        .footer = testFooter(2),
        .transcript = .{
            .natural_visual_rows = 2,
            .trailing_boundary_blank_rows = 1,
        },
        .activity = .{ .thinking = .{ .gap_above_activity = 1 } },
    });
    const plan = layout.toPaintPlan(.{
        .footer_rows = testFooterRows(1, 2),
        .viewport = .{
            .top_row = layout.transcript_area.top,
            .bottom_row = layout.transcript_area.bottom,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 2,
            .last_visible_row = layout.transcript_area.bottom,
        },
        .activity = .{ .transient_row = .{ .row = layout.activity_row.?, .gap_above_rows = 1 } },
        .cursor_target = .{ .row = 1, .col = 1, .visible = false },
    });
    try plan.validate();
    try std.testing.expectEqual(
        paint_plan.FrameBand{ .top = layout.blank_area.top, .bottom = layout.blank_area.bottom, .owner = .gap },
        plan.blank_band,
    );
    try std.testing.expect(plan.invalidation.isEmpty());

    var previous = try vt_emulator.Grid.init(alloc, plan.layout.cols, plan.layout.rows);
    defer previous.deinit();
    try previous.feed("\x1b[6;1Hstale gap");

    var surface = try frame_surface.FrameSurface.initFromShadow(alloc, plan, previous);
    defer surface.deinit();
    _ = try surface.writeAnsiBand(layout.transcript_area.top, layout.transcript_area.height(), "line one\nline two", .transcript, .same_owner);
    _ = try surface.writeAnsiBand(layout.activity_row.?, 1, "thinking", .activity, .same_owner);

    var target = try surface.copyToTargetGrid(alloc);
    defer target.deinit();
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);

    try target.rowText(layout.blank_area.top, &row_text);
    try std.testing.expectEqual(@as(usize, 0), std.mem.trim(u8, row_text.items, " ").len);

    row_text.clearRetainingCapacity();
    try target.rowText(layout.activity_row.?, &row_text);
    try std.testing.expect(std.mem.find(u8, row_text.items, "thinking") != null);
}

test "tiny terminal suppresses activity and clamps footer inside visible rows" {
    const layout = solve(.{
        .terminal = testLayout(3, 80),
        .owned_top = 1,
        .footer = .{
            .natural_rows = 5,
            .min_rows = 1,
            .max_rows = 5,
            .picker_rows = 3,
            .banner_rows = 1,
        },
        .transcript = .{ .natural_visual_rows = 4 },
        .activity = .{ .thinking = .{ .gap_above_activity = 1 } },
    });

    try std.testing.expectEqual(@as(?u16, null), layout.activity_row);
    try std.testing.expect(layout.footer_area.bottom <= 3);
    try std.testing.expect(layout.footer_area.height() >= 1);
    try std.testing.expectEqual(layout.owned_band.bottom, layout.footer_area.bottom);
}

test "toPaintPlan derives commit bands from solved layout" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{ .natural_visual_rows = 2 },
        .activity = .{ .thinking = .{ .gap_above_activity = 1 } },
    });
    const plan = layout.toPaintPlan(.{
        .footer_rows = testFooterRows(1, 4),
        .viewport = .{
            .top_row = 4,
            .bottom_row = 5,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 2,
            .last_visible_row = 5,
        },
        .activity = .{ .transient_row = .{ .row = 1, .gap_above_rows = 1 } },
        .cursor_target = .{ .row = 9, .col = 1, .visible = false },
        .reset_terminal = true,
    });

    try std.testing.expectEqual(FrameRect{ .top = 4, .bottom = 11 }, layout.owned_band);
    try std.testing.expectEqual(paint_plan.FrameBand{ .top = 1, .bottom = 3, .owner = .preserved_shell }, plan.preserved_band);
    try std.testing.expectEqual(paint_plan.FrameBand{ .top = 4, .bottom = 5, .owner = .transcript }, plan.transcript_band);
    try std.testing.expectEqual(paint_plan.FrameBand{ .top = 6, .bottom = 6, .owner = .gap }, plan.blank_band);
    try std.testing.expectEqual(paint_plan.FrameBand{ .top = 7, .bottom = 7, .owner = .activity }, plan.activity_band);
    try std.testing.expectEqual(paint_plan.FrameBand.empty(.gap), plan.footer_gap_band);
    try std.testing.expectEqual(paint_plan.FrameBand{ .top = 8, .bottom = 11, .owner = .footer }, plan.footer_band);
    try std.testing.expect(plan.invalidation.isEmpty());
    try std.testing.expectEqual(@as(u16, 8), plan.footer.top);
    try std.testing.expectEqual(@as(u16, 11), plan.footer.hint);
    try std.testing.expectEqual(@as(u16, 0), plan.bottom_reserved_rows);
    try std.testing.expect(plan.reset_terminal);
    try plan.validate();
}

test "toPaintPlan suppresses overlay activity outside solved transcript area" {
    const layout = solve(.{
        .terminal = testLayout(24, 80),
        .owned_top = 4,
        .footer = testFooter(4),
        .transcript = .{ .natural_visual_rows = 2 },
        .activity = .{ .overlay_entry = 9 },
    });
    const plan = layout.toPaintPlan(.{
        .footer_rows = testFooterRows(1, 4),
        .viewport = .{
            .top_row = 4,
            .bottom_row = 5,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 2,
            .last_visible_row = 5,
        },
        .activity = .{ .overlay_entry = 9 },
        .cursor_target = .{ .row = 8, .col = 1, .visible = true },
    });

    try std.testing.expectEqual(paint_plan.FrameBand{ .top = 4, .bottom = 5, .owner = .transcript }, plan.transcript_band);
    try std.testing.expect(plan.activity == .none);
    try plan.validate();
}

fn testFooterRows(top: u16, rows: u16) footer_layout.FooterRows {
    return .{
        .top = top,
        .top_divider = top,
        .banner = top,
        .banner_active = false,
        .input_base = top + 1,
        .picker_divider = top + 2,
        .picker_start = top + 3,
        .bottom_divider = top + rows - 2,
        .hint = top + rows - 1,
        .total_rows = rows,
    };
}
