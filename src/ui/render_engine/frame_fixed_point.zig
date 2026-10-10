const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const frame_layout = @import("frame_layout.zig");
const frame_scroll_plan = @import("frame_scroll_plan.zig");

pub const CandidatePreparation = struct {
    inline_advance_rows: u16,
    occupied_transcript_rows: u16,
};

pub const CandidateResolution = struct {
    occupied_transcript_rows: u16,
};

pub const FramePlan = struct {
    layout: frame_layout.FrameLayout,
    scroll_plan: frame_scroll_plan.FrameScrollPlan,
    iterations: usize,
};

pub fn solve(
    comptime Context: type,
    ctx: *Context,
    input: frame_layout.SolveInput,
    prepare_candidate: *const fn (*Context, frame_layout.FrameLayout) anyerror!CandidatePreparation,
    resolve_candidate: *const fn (*Context, frame_layout.FrameLayout, frame_scroll_plan.FrameScrollPlan) anyerror!CandidateResolution,
) !FramePlan {
    var release_floor_rows: u16 = 0;
    var candidate_input = input;
    var previous_candidate: ?struct {
        owned_top: u16,
        effective_transcript_rows: u16,
    } = null;
    var iteration: usize = 0;

    while (true) {
        iteration += 1;
        const layout_release = frame_layout.solveWithPreservedRowRelease(candidate_input, release_floor_rows);
        const candidate = layout_release.layout;
        if (previous_candidate) |previous| {
            const owner_released = candidate.owned_top < previous.owned_top;
            const extent_reduced = candidate_input.transcript.natural_visual_rows < previous.effective_transcript_rows;
            if (candidate.owned_top > previous.owned_top or
                candidate_input.transcript.natural_visual_rows > previous.effective_transcript_rows or
                (!owner_released and !extent_reduced))
            {
                return error.InvalidFrameScrollPlan;
            }
        }
        const preparation = try prepare_candidate(ctx, candidate);
        const scroll_plan = frame_scroll_plan.merge(
            candidate_input.terminal.rows,
            candidate_input.owned_top,
            layout_release.released_rows,
            preparation.inline_advance_rows,
        );
        const prepared_projection_is_shorter = preparation.occupied_transcript_rows > 0 and
            preparation.occupied_transcript_rows < candidate.transcript_area.height();
        const resolution = if (prepared_projection_is_shorter)
            CandidateResolution{ .occupied_transcript_rows = preparation.occupied_transcript_rows }
        else
            try resolve_candidate(ctx, candidate, scroll_plan);
        debug_trace.logf(
            "frame_layout",
            "fixed_point iteration={d} requested_release={d} requested_inline={d} emitted_scroll={d} remaining_inline={d} prior_owned_top={d} post_scroll_owned_top={d}",
            .{
                iteration,
                scroll_plan.requested_release_rows,
                scroll_plan.requested_inline_advance_rows,
                scroll_plan.terminal_scroll_rows,
                scroll_plan.remaining_inline_advance_rows,
                scroll_plan.prior_owned_top,
                scroll_plan.post_scroll_owned_top,
            },
        );
        const projection_is_shorter = resolution.occupied_transcript_rows > 0 and
            resolution.occupied_transcript_rows < candidate.transcript_area.height();
        if (candidate.owned_top == scroll_plan.post_scroll_owned_top and !projection_is_shorter) {
            return .{
                .layout = candidate,
                .scroll_plan = scroll_plan,
                .iterations = iteration,
            };
        }
        previous_candidate = .{
            .owned_top = candidate.owned_top,
            .effective_transcript_rows = candidate_input.transcript.natural_visual_rows,
        };
        if (projection_is_shorter) {
            candidate_input.transcript.natural_visual_rows = resolution.occupied_transcript_rows;
        }
        release_floor_rows = scroll_plan.preserved_release_rows;
    }
}

const FixedPointTestContext = struct {
    inline_advance_rows: u16 = 0,
    prepared_occupied_rows: ?u16 = null,
    resolved_occupied_rows: ?u16 = null,
    candidate_tops: [8]u16 = @splat(0),
    candidate_transcript_rows: [8]u16 = @splat(0),
    resolved_inline_rows: [8]u32 = @splat(0),
    calls: usize = 0,
    resolution_calls: usize = 0,

    fn prepareCandidate(
        self: *FixedPointTestContext,
        layout: frame_layout.FrameLayout,
    ) !CandidatePreparation {
        self.candidate_tops[self.calls] = layout.owned_top;
        self.candidate_transcript_rows[self.calls] = layout.transcript_area.height();
        self.calls += 1;
        return .{
            .inline_advance_rows = self.inline_advance_rows,
            .occupied_transcript_rows = self.prepared_occupied_rows orelse layout.transcript_area.height(),
        };
    }

    fn resolveCandidate(
        self: *FixedPointTestContext,
        layout: frame_layout.FrameLayout,
        scroll_plan: frame_scroll_plan.FrameScrollPlan,
    ) !CandidateResolution {
        self.resolved_inline_rows[self.resolution_calls] = scroll_plan.requested_inline_advance_rows;
        self.resolution_calls += 1;
        return .{
            .occupied_transcript_rows = self.resolved_occupied_rows orelse layout.transcript_area.height(),
        };
    }
};

fn fixedPointTestInput(
    terminal_rows: u16,
    owned_top: u16,
    transcript_rows: u16,
    footer_rows: u16,
    body_mode: frame_layout.BodyMode,
) frame_layout.SolveInput {
    return .{
        .terminal = .{
            .rows = terminal_rows,
            .cols = 80,
            .content_bottom = terminal_rows -| 4,
            .divider_top_row = terminal_rows -| 3,
            .input_row = terminal_rows -| 2,
            .divider_bottom_row = terminal_rows -| 1,
            .hint_row = terminal_rows,
        },
        .owned_top = owned_top,
        .footer = .{
            .natural_rows = footer_rows,
            .min_rows = footer_rows,
            .max_rows = footer_rows,
        },
        .transcript = .{ .natural_visual_rows = transcript_rows },
        .body_mode = body_mode,
    };
}

fn solveFixedPointForTest(
    ctx: *FixedPointTestContext,
    input: frame_layout.SolveInput,
) !FramePlan {
    return solve(
        FixedPointTestContext,
        ctx,
        input,
        FixedPointTestContext.prepareCandidate,
        FixedPointTestContext.resolveCandidate,
    );
}

test "frame fixed point releases footer only growth" {
    var ctx = FixedPointTestContext{};
    const fixed_point = try solveFixedPointForTest(&ctx, fixedPointTestInput(12, 8, 0, 6, .transcript));

    try std.testing.expectEqual(@as(usize, 1), fixed_point.iterations);
    try std.testing.expectEqual(@as(u16, 7), fixed_point.layout.owned_top);
    try std.testing.expectEqual(@as(u16, 1), fixed_point.scroll_plan.preserved_release_rows);
    try std.testing.expectEqual(@as(u16, 0), fixed_point.scroll_plan.requested_inline_advance_rows);
}

test "frame fixed point releases preserved rows before inline advancement" {
    var ctx = FixedPointTestContext{ .inline_advance_rows = 3 };
    const fixed_point = try solveFixedPointForTest(&ctx, fixedPointTestInput(12, 5, 1, 3, .transcript));

    try std.testing.expectEqual(@as(usize, 3), fixed_point.iterations);
    try std.testing.expectEqualSlices(u16, &.{ 5, 2, 1 }, ctx.candidate_tops[0..ctx.calls]);
    try std.testing.expectEqual(@as(u16, 1), fixed_point.layout.owned_top);
    try std.testing.expectEqual(@as(u16, 7), fixed_point.scroll_plan.terminal_scroll_rows);
}

test "frame fixed point compacts a same-owner prepared projection" {
    var ctx = FixedPointTestContext{ .prepared_occupied_rows = 9 };
    const fixed_point = try solveFixedPointForTest(&ctx, fixedPointTestInput(20, 1, 15, 4, .transcript));

    try std.testing.expectEqual(@as(usize, 2), fixed_point.iterations);
    try std.testing.expectEqualSlices(u16, &.{ 1, 1 }, ctx.candidate_tops[0..ctx.calls]);
    try std.testing.expectEqualSlices(u16, &.{ 15, 9 }, ctx.candidate_transcript_rows[0..ctx.calls]);
    try std.testing.expectEqual(frame_layout.FrameRect{ .top = 1, .bottom = 9 }, fixed_point.layout.transcript_area);
    try std.testing.expectEqual(@as(u16, 10), fixed_point.layout.footer_area.top);
    try std.testing.expectEqual(@as(u16, 0), fixed_point.scroll_plan.requested_inline_advance_rows);
}

test "frame fixed point resolves final extent after merging scroll plan" {
    var ctx = FixedPointTestContext{
        .inline_advance_rows = 3,
        .resolved_occupied_rows = 9,
    };
    const fixed_point = try solveFixedPointForTest(
        &ctx,
        fixedPointTestInput(20, 1, 15, 4, .transcript),
    );

    try std.testing.expectEqual(@as(usize, 2), fixed_point.iterations);
    try std.testing.expectEqual(ctx.calls, ctx.resolution_calls);
    try std.testing.expectEqualSlices(
        u32,
        &.{ 3, 3 },
        ctx.resolved_inline_rows[0..ctx.resolution_calls],
    );
    try std.testing.expectEqual(@as(u16, 9), fixed_point.layout.transcript_area.height());
}

test "frame fixed point compacts prepared extent before target resolution" {
    var ctx = FixedPointTestContext{ .prepared_occupied_rows = 9 };
    const fixed_point = try solveFixedPointForTest(
        &ctx,
        fixedPointTestInput(20, 1, 15, 4, .transcript),
    );

    try std.testing.expectEqual(@as(usize, 2), fixed_point.iterations);
    try std.testing.expectEqual(@as(usize, 2), ctx.calls);
    try std.testing.expectEqual(@as(usize, 1), ctx.resolution_calls);
    try std.testing.expectEqualSlices(u16, &.{ 15, 9 }, ctx.candidate_transcript_rows[0..ctx.calls]);
}

test "frame fixed point permits document movement beyond terminal height" {
    var ctx = FixedPointTestContext{ .inline_advance_rows = 7 };
    const fixed_point = try solveFixedPointForTest(&ctx, fixedPointTestInput(4, 1, 1, 2, .transcript));

    try std.testing.expectEqual(@as(usize, 1), fixed_point.iterations);
    try std.testing.expectEqual(@as(u16, 7), fixed_point.scroll_plan.terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), fixed_point.scroll_plan.remaining_inline_advance_rows);
}

test "frame fixed point shared footer growth paths use fixed point release" {
    const footer_rows = [_]u16{ 6, 7, 8, 9, 10 };
    for (footer_rows) |rows| {
        var ctx = FixedPointTestContext{};
        const fixed_point = try solveFixedPointForTest(&ctx, fixedPointTestInput(12, 8, 0, rows, .transcript));
        try std.testing.expect(fixed_point.scroll_plan.preserved_release_rows > 0);
        try std.testing.expectEqual(fixed_point.layout.owned_top, fixed_point.scroll_plan.post_scroll_owned_top);
    }
}

test "frame fixed point subagent growth uses fixed point release" {
    var ctx = FixedPointTestContext{};
    const fixed_point = try solveFixedPointForTest(&ctx, fixedPointTestInput(12, 8, 8, 4, .subagent_panel));

    try std.testing.expect(fixed_point.scroll_plan.preserved_release_rows > 0);
    try std.testing.expectEqual(fixed_point.layout.owned_top, fixed_point.scroll_plan.post_scroll_owned_top);
}

test "frame fixed point eager row one path never requests progressive release" {
    var ctx = FixedPointTestContext{};
    const fixed_point = try solveFixedPointForTest(&ctx, fixedPointTestInput(12, 1, 12, 6, .transcript));

    try std.testing.expectEqual(@as(u16, 1), fixed_point.layout.owned_top);
    try std.testing.expectEqual(@as(u16, 0), fixed_point.scroll_plan.requested_release_rows);
    try std.testing.expectEqual(@as(u16, 0), fixed_point.scroll_plan.preserved_release_rows);
}
