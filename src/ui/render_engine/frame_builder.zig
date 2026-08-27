const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const frame_layout = @import("frame_layout.zig");
const frame_retention = @import("frame_retention.zig");
const frame_scroll_plan = @import("frame_scroll_plan.zig");
const frame_surface = @import("frame_surface.zig");
const paint_plan = @import("paint_plan.zig");
const terminal_diff = @import("terminal_diff.zig");
const transcript_blocks = @import("transcript_blocks.zig");
const ui_observer = @import("ui_observer.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");
const activity_runtime = @import("../../core/output/activity_runtime.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;

pub const FrameBody = union(enum) {
    transcript,
    subagent_panel: []const u8,
    none,
};

pub const SurfacePainter = struct {
    ctx: *anyopaque,
    paint: *const fn (ctx: *anyopaque, surface: *frame_surface.FrameSurface) anyerror!void,
};

pub const TraceCounters = struct {
    body_paints: usize = 0,
    footer_paints: usize = 0,
    activity_paints: usize = 0,
    frame_commits: usize = 0,
    retained_transcript_changed_cells: usize = 0,
};

pub const RetainedTranscriptBody = frame_retention.RetainedTranscriptBody;
pub const TranscriptBodyDisposition = frame_retention.TranscriptBodyDisposition;

pub const FramePresentation = enum {
    styled,
    neutral,
};

pub const BuildFrameOptions = struct {
    plan: paint_plan.PaintPlan,
    committed_layout: ?frame_layout.CommittedLayoutSnapshot = null,
    body: FrameBody = .transcript,
    transcript_body: TranscriptBodyDisposition = .paint,
    captured_repaint: bool = false,
    scroll_plan: frame_scroll_plan.FrameScrollPlan,
    document_append: frame_scroll_plan.FrameDocumentAppend = .{},
    terminal_transition: terminal_diff.FrameTerminalTransition = .none,
    body_painter: ?SurfacePainter = null,
    /// Paints a bounded prompt tail after retained transcript rows and before
    /// footer/activity surfaces. It never replaces the transcript body owner.
    transcript_tail_painter: ?SurfacePainter = null,
    footer_painter: ?SurfacePainter = null,
    activity_painter: ?SurfacePainter = null,
    presentation: FramePresentation = .styled,
    trace_counters: ?*TraceCounters = null,
    observation: ?FrameObservation = null,
};

pub const FrameObservation = struct {
    observer: *ui_observer.UiObserver,
    row_provenance: []const transcript_blocks.RowProvenance,
    activity: activity_runtime.ActivityProjection,
    stream_active: bool,
    completed_assistant_presentation_tail: bool,
};

pub fn buildAndFlushFrame(
    alloc: Allocator,
    shell: anytype,
    metrics: *Metrics,
    options: BuildFrameOptions,
) !terminal_diff.FrameCommitResult {
    var plan = options.plan;
    const shadow = shell.shadow_vt orelse return error.ShadowVtDisabled;
    const committed_layout = options.committed_layout orelse shell.committed_frame_layout;
    const terminal_scroll_rows = try prepareFramePlan(
        &plan,
        shadow,
        committed_layout,
        &options,
    );
    const repaint_window = frameRepaintWindow(plan, options.transcript_body);
    logFrameBuildPlan(plan, options);

    var movement = try terminal_diff.prepareTerminalMovementForFrame(
        alloc,
        shadow,
        options.document_append,
        terminal_scroll_rows,
        options.scroll_plan.preserved_release_rows,
        plan.layout.cols,
        plan.layout.rows,
        alignmentClearStartRow(
            committed_layout,
            shadow,
            plan.layout,
        ),
        options.terminal_transition,
    );
    defer movement.deinit(alloc);

    var surface = try frame_surface.FrameSurface.initFromShadow(alloc, plan, movement.post_movement);
    defer surface.deinit();

    try paintFrameSurface(&surface, &movement, &options);
    if (options.presentation == .neutral) surface.neutralizeFxOwnedPresentation();
    traceRetainedTranscriptChanges(&surface, &movement, &options);

    try surface.validate();
    const result = try terminal_diff.flushFrame(.{
        .previous = shadow,
        .surface = &surface,
        .repaint_window = repaint_window,
        .synchronized_update = plan.synchronized_update,
        .history_reset_uses_ris = shell.history_reset_uses_ris,
        .scroll_plan = options.scroll_plan,
        .document_append = options.document_append,
        .terminal_transition = options.terminal_transition,
        .prepared_movement = &movement,
        .sink = shell.frameSink(),
        .metrics = metrics,
    });
    if (options.trace_counters) |counters| counters.frame_commits += 1;

    logFrameCommitResult(plan, result);
    observeCommittedFrame(alloc, &surface, &plan, result, &options);
    try record_retry_invalidation(shell, result);
    return result;
}

fn alignmentClearStartRow(
    committed_layout: frame_layout.CommittedLayoutSnapshot,
    shadow: *const vt_emulator.Grid,
    target: types.Layout,
) u16 {
    if (committed_layout.layout_id == 0 or
        committed_layout.terminal_rows != shadow.rows or
        committed_layout.terminal_cols != shadow.cols or
        target.rows != shadow.rows or
        target.cols != shadow.cols)
    {
        return 0;
    }
    if (committed_layout.transcript_area.isEmpty()) {
        const owned_top = committed_layout.owned_band.top;
        return if (owned_top > 0 and owned_top <= target.rows) owned_top else 0;
    }
    const transcript_bottom = committed_layout.transcript_area.bottom;
    return if (committed_layout.transcript_area.top > 0 and transcript_bottom < target.rows)
        transcript_bottom + 1
    else
        0;
}

fn frameRepaintWindow(
    plan: paint_plan.PaintPlan,
    transcript_body: TranscriptBodyDisposition,
) paint_plan.FrameRepaintWindow {
    return switch (transcript_body) {
        .paint => paint_plan.FrameRepaintWindow.fromPlan(plan, .{ .include_transcript = true }),
        .retain => |retained| paint_plan.FrameRepaintWindow.fromPlan(plan, .{
            .include_transcript = false,
            .retained_transcript_band = retained.source_area.toBand(.transcript),
        }),
    };
}

fn prepareFramePlan(
    plan: *paint_plan.PaintPlan,
    shadow: *const vt_emulator.Grid,
    committed_frame_layout: frame_layout.CommittedLayoutSnapshot,
    options: *const BuildFrameOptions,
) !u16 {
    try plan.validate();

    if (shadow.rows != plan.layout.rows or shadow.cols != plan.layout.cols) {
        invalidateCurrentOwnedBand(plan, .resize);
    }
    try options.scroll_plan.validate(plan.layout.rows);
    const terminal_scroll_rows = options.scroll_plan.terminal_scroll_rows;
    if (terminal_scroll_rows > 0) {
        invalidateCurrentOwnedBand(plan, .terminal_scroll);
    }
    if (committed_frame_layout.layout_id != 0) {
        invalidateOwnedBandChange(
            plan,
            committed_frame_layout.owned_band.toBand(.transcript),
        );
    }
    return terminal_scroll_rows;
}

fn logFrameBuildPlan(plan: paint_plan.PaintPlan, options: BuildFrameOptions) void {
    debug_trace.logf(
        "frame_plan",
        "build layout={d}x{d} transcript={d}..{d} footer={d}..{d} activity={d}..{d} invalidations={d} body={s} transcript_body={s} captured={s}",
        .{
            plan.layout.cols,
            plan.layout.rows,
            plan.transcript_band.top,
            plan.transcript_band.bottom,
            plan.footer_band.top,
            plan.footer_band.bottom,
            plan.activity_band.top,
            plan.activity_band.bottom,
            plan.invalidation.len,
            @tagName(options.body),
            @tagName(options.transcript_body),
            if (options.captured_repaint) "true" else "false",
        },
    );
}

fn paintFrameSurface(
    surface: *frame_surface.FrameSurface,
    movement: *const terminal_diff.PreparedTerminalMovement,
    options: *const BuildFrameOptions,
) !void {
    switch (options.transcript_body) {
        .paint => {
            if (options.body_painter) |painter| {
                try painter.paint(painter.ctx, surface);
                if (options.trace_counters) |counters| counters.body_paints += 1;
            }
        },
        .retain => |retained| {
            try frame_retention.validate(
                surface.plan,
                options.body == .transcript,
                movement.*,
                retained,
            );
            try surface.retainTranscriptBandFromGrid(
                movement.post_movement,
                retained.source_area,
            );
        },
    }
    if (options.transcript_tail_painter) |painter| {
        try painter.paint(painter.ctx, surface);
    }
    if (options.footer_painter) |painter| {
        try painter.paint(painter.ctx, surface);
        if (options.trace_counters) |counters| counters.footer_paints += 1;
    }
    if (options.activity_painter) |painter| {
        try painter.paint(painter.ctx, surface);
        if (options.trace_counters) |counters| counters.activity_paints += 1;
    }
}

fn traceRetainedTranscriptChanges(
    surface: *const frame_surface.FrameSurface,
    movement: *const terminal_diff.PreparedTerminalMovement,
    options: *const BuildFrameOptions,
) void {
    switch (options.transcript_body) {
        .paint => return,
        .retain => |retained| {
            const changed = frame_retention.countSurfaceChanges(
                movement.post_movement,
                surface.*,
                retained.source_area,
            );
            if (options.trace_counters) |counters| {
                counters.retained_transcript_changed_cells = changed;
            }
            debug_trace.logf(
                "frame_diff",
                "retained_transcript source={d}..{d} occupied_last_row={d} changed_cells={d}",
                .{
                    retained.source_area.top,
                    retained.source_area.bottom,
                    retained.occupied_last_row,
                    changed,
                },
            );
        },
    }
}

fn logFrameCommitResult(plan: paint_plan.PaintPlan, result: terminal_diff.FrameCommitResult) void {
    const retry_invalidation_count: u8 = if (result.retry_invalidation() != null) 1 else 0;
    debug_trace.logf(
        "frame_diff",
        "result state={s} bytes={d} changed_cells={d} full_repaint={s} invalidation={s} next_invalidations={d}",
        .{
            @tagName(result.state()),
            result.bytes_written,
            result.changed_cells,
            if (result.full_repaint) "true" else "false",
            firstInvalidationName(plan.invalidation),
            retry_invalidation_count,
        },
    );
}

fn observeCommittedFrame(
    alloc: Allocator,
    surface: *frame_surface.FrameSurface,
    plan: *const paint_plan.PaintPlan,
    result: terminal_diff.FrameCommitResult,
    options: *const BuildFrameOptions,
) void {
    if (!result.is_committed()) return;
    if (options.observation) |observation| {
        observation.observer.observeNormalFrame(alloc, .{
            .surface = surface,
            .plan = plan,
            .row_provenance = observation.row_provenance,
            .activity = observation.activity,
            .stream_active = observation.stream_active,
            .completed_assistant_presentation_tail = observation.completed_assistant_presentation_tail,
        });
    }
}

fn record_retry_invalidation(shell: anytype, result: terminal_diff.FrameCommitResult) !void {
    const range = result.retry_invalidation() orelse return;
    try shell.recordFrameInvalidation(range);
}

fn firstInvalidationName(set: paint_plan.FrameInvalidationSet) []const u8 {
    if (set.len == 0) return "none";
    return @tagName(set.ranges()[0].reason);
}

fn invalidateCurrentOwnedBand(
    plan: *paint_plan.PaintPlan,
    reason: paint_plan.FrameInvalidationReason,
) void {
    invalidateBand(plan, reason, paint_plan.paintedContentBand(plan.*));
}

fn invalidateOwnedBandChange(
    plan: *paint_plan.PaintPlan,
    previous: paint_plan.FrameBand,
) void {
    if (paint_plan.paintedBandChange(plan.*, previous)) |band| {
        invalidateBand(plan, .owned_band_change, band);
    }
}

fn invalidateBand(
    plan: *paint_plan.PaintPlan,
    reason: paint_plan.FrameInvalidationReason,
    band: paint_plan.FrameBand,
) void {
    if (band.isEmpty()) return;
    appendFrameInvalidation(plan, .{
        .reason = reason,
        .top = band.top,
        .bottom = band.bottom,
    });
    plan.footer_clean_allowed = false;
}

fn appendFrameInvalidation(plan: *paint_plan.PaintPlan, range: paint_plan.FrameInvalidationRange) void {
    if (plan.invalidation.appendOrCollapse(range)) |collapsed| {
        debug_trace.logf(
            "frame_plan",
            "build_invalidation_collapse incoming_reason={s} collapsed_reason={s} top={d} bottom={d}",
            .{ @tagName(range.reason), @tagName(collapsed.reason), collapsed.top, collapsed.bottom },
        );
    }
}

const TestShell = struct {
    shadow: vt_emulator.Grid,
    shadow_vt: ?*vt_emulator.Grid,
    history_reset_uses_ris: bool = false,
    recorded_invalidations: paint_plan.FrameInvalidationSet = paint_plan.FrameInvalidationSet.empty(),
    has_committed_frame: bool = false,
    committed_frame_layout: frame_layout.CommittedLayoutSnapshot = .{},
    sink: terminal_diff.FrameSink,

    fn init(alloc: Allocator, sink: terminal_diff.FrameSink) !TestShell {
        var shadow = try vt_emulator.Grid.init(alloc, 8, 4);
        errdefer shadow.deinit();
        return .{
            .shadow = shadow,
            .shadow_vt = undefined,
            .sink = sink,
        };
    }

    fn bind(self: *TestShell) void {
        self.shadow_vt = &self.shadow;
    }

    fn deinit(self: *TestShell) void {
        self.shadow.deinit();
    }

    fn frameSink(self: *TestShell) terminal_diff.FrameSink {
        return self.sink;
    }

    fn recordFrameInvalidation(self: *TestShell, range: paint_plan.FrameInvalidationRange) !void {
        try self.recorded_invalidations.append(range);
    }

    fn takeRecordedInvalidations(self: *TestShell) paint_plan.FrameInvalidationSet {
        const recorded = self.recorded_invalidations;
        self.recorded_invalidations = paint_plan.FrameInvalidationSet.empty();
        return recorded;
    }
};

const BuilderSink = struct {
    bytes: std.ArrayList(u8) = .empty,
    fail: bool = false,
    write_calls: usize = 0,

    fn deinit(self: *BuilderSink, alloc: Allocator) void {
        self.bytes.deinit(alloc);
    }

    fn sink(self: *BuilderSink) terminal_diff.FrameSink {
        return .{ .ctx = self, .write_frame = writeFrame };
    }

    fn writeFrame(ctx: *anyopaque, _: *Metrics, bytes: []const u8) terminal_diff.FrameSinkWriteResult {
        const self: *BuilderSink = @ptrCast(@alignCast(ctx));
        self.write_calls += 1;
        if (self.fail and self.write_calls == 1) return .{ .partial = .{ .accepted_bytes = 0, .err = error.TestFrameWriteFailure } };
        self.bytes.appendSlice(std.testing.allocator, bytes) catch |err| {
            return .{ .partial = .{ .accepted_bytes = 0, .err = err } };
        };
        return .complete;
    }
};

fn testScrollPlan(rows: u16) frame_scroll_plan.FrameScrollPlan {
    return frame_scroll_plan.merge(4, 1, 0, rows);
}

fn testPlan() paint_plan.PaintPlan {
    return .{
        .layout = .{
            .rows = 4,
            .cols = 8,
            .content_bottom = 2,
            .divider_top_row = 3,
            .input_row = 3,
            .divider_bottom_row = 3,
            .hint_row = 4,
        },
        .viewport = .{
            .top_row = 2,
            .bottom_row = 2,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
            .last_visible_row = 2,
        },
        .footer = .{
            .top = 3,
            .top_divider = 3,
            .banner = 3,
            .banner_active = false,
            .input_base = 3,
            .picker_divider = 3,
            .picker_start = 4,
            .bottom_divider = 3,
            .hint = 4,
            .total_rows = 2,
        },
        .activity = .{ .transient_row = .{ .row = 1, .gap_above_rows = 0 } },
        .preserved_band = paint_plan.FrameBand.empty(.preserved_shell),
        .transcript_band = .{ .top = 2, .bottom = 2, .owner = .transcript },
        .activity_band = .{ .top = 1, .bottom = 1, .owner = .activity },
        .footer_band = .{ .top = 3, .bottom = 4, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = false,
        .cursor_target = .{ .row = 3, .col = 1, .visible = true },
        .footer_reservation_source = .footer_layout,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

fn resizedTestPlan() paint_plan.PaintPlan {
    var plan = testPlan();
    plan.layout = .{
        .rows = 6,
        .cols = 4,
        .content_bottom = 4,
        .divider_top_row = 5,
        .input_row = 5,
        .divider_bottom_row = 5,
        .hint_row = 6,
    };
    plan.viewport.bottom_row = 4;
    plan.viewport.last_visible_row = 4;
    plan.footer = .{
        .top = 5,
        .top_divider = 5,
        .banner = 5,
        .banner_active = false,
        .input_base = 5,
        .picker_divider = 5,
        .picker_start = 6,
        .bottom_divider = 5,
        .hint = 6,
        .total_rows = 2,
    };
    plan.transcript_band.bottom = 4;
    plan.footer_band = .{ .top = 5, .bottom = 6, .owner = .footer };
    plan.cursor_target = .{ .row = 5, .col = 1, .visible = true };
    return plan;
}

const PaintCtx = struct {
    text: []const u8,
    owner: paint_plan.CellOwner,
    row: u16,

    fn painter(ctx: *anyopaque, surface: *frame_surface.FrameSurface) anyerror!void {
        const self: *PaintCtx = @ptrCast(@alignCast(ctx));
        _ = try surface.writeAnsiBand(self.row, 1, self.text, self.owner, .same_owner);
    }
};

test "frame preparation invalidations preserve owned band and clean flag semantics" {
    var resize_plan = testPlan();
    invalidateCurrentOwnedBand(&resize_plan, .resize);
    try std.testing.expect(!resize_plan.footer_clean_allowed);
    try std.testing.expectEqual(@as(u8, 1), resize_plan.invalidation.len);
    try std.testing.expectEqual(
        paint_plan.FrameInvalidationRange{
            .reason = .resize,
            .top = 1,
            .bottom = 4,
        },
        resize_plan.invalidation.ranges()[0],
    );

    var matching_plan = testPlan();
    invalidateOwnedBandChange(&matching_plan, .{ .top = 1, .bottom = 4, .owner = .transcript });
    try std.testing.expect(matching_plan.footer_clean_allowed);
    try std.testing.expect(matching_plan.invalidation.isEmpty());

    var changed_plan = testPlan();
    invalidateOwnedBandChange(&changed_plan, .{ .top = 2, .bottom = 3, .owner = .transcript });
    try std.testing.expect(!changed_plan.footer_clean_allowed);
    try std.testing.expectEqual(@as(u8, 1), changed_plan.invalidation.len);
    try std.testing.expectEqual(
        paint_plan.FrameInvalidationRange{
            .reason = .owned_band_change,
            .top = 1,
            .bottom = 4,
        },
        changed_plan.invalidation.ranges()[0],
    );

    var empty_band_plan = testPlan();
    empty_band_plan.transcript_band = paint_plan.FrameBand.empty(.transcript);
    empty_band_plan.activity_band = paint_plan.FrameBand.empty(.activity);
    empty_band_plan.footer_band = paint_plan.FrameBand.empty(.footer);
    invalidateCurrentOwnedBand(&empty_band_plan, .terminal_scroll);
    try std.testing.expect(empty_band_plan.footer_clean_allowed);
    try std.testing.expect(empty_band_plan.invalidation.isEmpty());
}

test "buildAndFlushFrame runs body footer activity painters and one commit" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();

    var body = PaintCtx{ .text = "b", .owner = .transcript, .row = 2 };
    var footer = PaintCtx{ .text = "f", .owner = .footer, .row = 3 };
    var activity = PaintCtx{ .text = "a", .owner = .activity, .row = 1 };
    var counters: TraceCounters = .{};
    var metrics: Metrics = .{};

    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = testPlan(),
        .scroll_plan = testScrollPlan(0),
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .activity_painter = .{ .ctx = &activity, .paint = PaintCtx.painter },
        .trace_counters = &counters,
    });

    try std.testing.expectEqual(terminal_diff.ShadowCommitState.committed, result.shadow_state);
    try std.testing.expectEqual(@as(usize, 1), counters.body_paints);
    try std.testing.expectEqual(@as(usize, 1), counters.footer_paints);
    try std.testing.expectEqual(@as(usize, 1), counters.activity_paints);
    try std.testing.expectEqual(@as(usize, 1), counters.frame_commits);
    try std.testing.expectEqual(@as(u21, 'a'), shell.shadow.cellAt(1, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), shell.shadow.cellAt(2, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), shell.shadow.cellAt(3, 1).?.codepoint);
}

test "alignment scroll clears prior replaceable rows before advancing history" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();
    try shell.shadow.feed(
        "\x1b[1;1Hfirst\x1b[2;1Hsecond\x1b[3;1Hqueued\x1b[4;1Hfooter",
    );

    var body = PaintCtx{ .text = "next", .owner = .transcript, .row = 2 };
    var footer = PaintCtx{ .text = "new", .owner = .footer, .row = 3 };
    var activity = PaintCtx{ .text = "active", .owner = .activity, .row = 1 };
    var metrics: Metrics = .{};
    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = testPlan(),
        .committed_layout = .{
            .layout_id = 1,
            .owned_top = 1,
            .owned_band = .{ .top = 1, .bottom = 4 },
            .body_area = .{ .top = 1, .bottom = 2 },
            .transcript_area = .{ .top = 1, .bottom = 2 },
            .footer_area = .{ .top = 3, .bottom = 4 },
            .terminal_rows = 4,
            .terminal_cols = 8,
        },
        .scroll_plan = testScrollPlan(2),
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .activity_painter = .{ .ctx = &activity, .paint = PaintCtx.painter },
    });

    try std.testing.expect(result.is_committed());
    const replaceable_clear = std.mem.find(
        u8,
        sink.bytes.items,
        "\x1b[3;1H\x1b[2K",
    ) orelse return error.TestExpectedReplaceableClear;
    const alignment_scroll = std.mem.find(
        u8,
        sink.bytes.items,
        "\x1b[4;1H\n\n",
    ) orelse return error.TestExpectedAlignmentScroll;
    try std.testing.expect(replaceable_clear < alignment_scroll);
}

test "resize frame defers alignment scroll until shadow geometry settles" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();
    try shell.shadow.feed(
        "\x1b[1;1Habcdefgh\x1b[2;1Hijklmnop\x1b[3;1Hqueued\x1b[4;1Hfooter",
    );

    var body = PaintCtx{ .text = "next", .owner = .transcript, .row = 2 };
    var footer = PaintCtx{ .text = "new", .owner = .footer, .row = 5 };
    var activity = PaintCtx{ .text = "busy", .owner = .activity, .row = 1 };
    var metrics: Metrics = .{};
    const plan = resizedTestPlan();
    const prior_layout: frame_layout.CommittedLayoutSnapshot = .{
        .layout_id = 1,
        .owned_top = 1,
        .owned_band = .{ .top = 1, .bottom = 4 },
        .body_area = .{ .top = 1, .bottom = 2 },
        .transcript_area = .{ .top = 1, .bottom = 2 },
        .footer_area = .{ .top = 3, .bottom = 4 },
        .terminal_rows = 4,
        .terminal_cols = 8,
    };
    const scroll_plan = frame_scroll_plan.merge(6, 1, 0, 2);
    const resize_result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = plan,
        .committed_layout = prior_layout,
        .scroll_plan = scroll_plan,
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .activity_painter = .{ .ctx = &activity, .paint = PaintCtx.painter },
    });

    try std.testing.expect(resize_result.is_committed());
    try std.testing.expectEqual(@as(u16, 0), resize_result.terminal_scroll_rows_committed);
    try std.testing.expectEqual(@as(u16, 0), resize_result.scroll_attribution.alignment_scroll_rows);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[6;1H\n") == null);
    const resize_receipt = resize_result.scroll_commit_receipt orelse
        return error.TestExpectedScrollCommitReceipt;
    try std.testing.expectEqual(@as(u16, 2), resize_receipt.planned_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 2), resize_receipt.expected_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), resize_receipt.accepted_terminal_scroll_rows);
    try std.testing.expect(!resize_receipt.complete());

    shell.committed_frame_layout =
        frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    sink.bytes.clearRetainingCapacity();
    const settled_result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = plan,
        .scroll_plan = scroll_plan,
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .activity_painter = .{ .ctx = &activity, .paint = PaintCtx.painter },
    });

    try std.testing.expect(settled_result.is_committed());
    try std.testing.expectEqual(@as(u16, 2), settled_result.terminal_scroll_rows_committed);
    try std.testing.expectEqual(@as(u16, 2), settled_result.scroll_attribution.alignment_scroll_rows);
    const replaceable_clear = std.mem.find(
        u8,
        sink.bytes.items,
        "\x1b[5;1H\x1b[2K",
    ) orelse return error.TestExpectedSettledReplaceableClear;
    const settled_scroll = std.mem.find(
        u8,
        sink.bytes.items,
        "\x1b[6;1H\n\n",
    ) orelse return error.TestExpectedSettledAlignmentScroll;
    try std.testing.expect(replaceable_clear < settled_scroll);
    const settled_receipt = settled_result.scroll_commit_receipt orelse
        return error.TestExpectedScrollCommitReceipt;
    try std.testing.expect(settled_receipt.complete());
}

test "resize frame releases preserved rows while deferring inline scroll" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();
    try shell.shadow.feed(
        "\x1b[1;1Hshell-A\x1b[2;1Hshell-B\x1b[3;1Htranscript\x1b[4;1Hfooter",
    );

    var body = PaintCtx{ .text = "next", .owner = .transcript, .row = 2 };
    var footer = PaintCtx{ .text = "new", .owner = .footer, .row = 5 };
    var activity = PaintCtx{ .text = "busy", .owner = .activity, .row = 1 };
    var metrics: Metrics = .{};
    const scroll_plan = frame_scroll_plan.merge(6, 3, 2, 2);
    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = resizedTestPlan(),
        .committed_layout = .{
            .layout_id = 1,
            .owned_top = 3,
            .owned_band = .{ .top = 3, .bottom = 4 },
            .body_area = .{ .top = 3, .bottom = 3 },
            .transcript_area = .{ .top = 3, .bottom = 3 },
            .footer_area = .{ .top = 4, .bottom = 4 },
            .terminal_rows = 4,
            .terminal_cols = 8,
        },
        .scroll_plan = scroll_plan,
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .activity_painter = .{ .ctx = &activity, .paint = PaintCtx.painter },
    });

    try std.testing.expect(result.is_committed());
    try std.testing.expectEqual(@as(u16, 2), result.terminal_scroll_rows_committed);
    try std.testing.expectEqual(@as(u16, 2), result.scroll_attribution.alignment_scroll_rows);
    const receipt = result.scroll_commit_receipt orelse
        return error.TestExpectedScrollCommitReceipt;
    try std.testing.expectEqual(@as(u16, 4), receipt.planned_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 2), receipt.accepted_rows.preserved_release_rows);
    try std.testing.expectEqual(@as(u32, 0), receipt.accepted_rows.inline_advance_rows);
    try std.testing.expect(!receipt.complete());
}

test "buildAndFlushFrame neutral presentation keeps repaint controls without style or hyperlink opens" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();

    var plan = testPlan();
    plan.synchronized_update = true;
    var body = PaintCtx{
        .text = "\x1b[31m\x1b]8;;https://example.com\x1b\\B\x1b]8;;\x1b\\\x1b[0m",
        .owner = .transcript,
        .row = 2,
    };
    var metrics: Metrics = .{};
    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = plan,
        .scroll_plan = testScrollPlan(0),
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .presentation = .neutral,
    });

    try std.testing.expect(result.is_committed());
    try std.testing.expect(std.mem.indexOf(u8, sink.bytes.items, "\x1b[?2026h") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.bytes.items, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.bytes.items, "\x1b[31m") == null);
    try std.testing.expect(std.mem.indexOf(u8, sink.bytes.items, "\x1b]8;") == null);
    try std.testing.expectEqual(@as(u21, 'B'), shell.shadow.cellAt(2, 1).?.codepoint);
    try std.testing.expect(shell.shadow.cellAt(2, 1).?.style.eql(.{}));
}

test "buildAndFlushFrame retains styled hyperlink body and appends footer namespace" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();
    try shell.shadow.feed("\x1b]8;;https://unused.example\x1b\\\x1b]8;;\x1b\\");
    try shell.shadow.feed(
        "\x1b[2;1H\x1b[31m\x1b]8;;https://body.example\x1b\\B\x1b]8;;\x1b\\\x1b[0m",
    );
    shell.shadow.cursor_row = 3;
    shell.shadow.cursor_col = 1;

    var body = PaintCtx{ .text = "wrong", .owner = .transcript, .row = 2 };
    var footer = PaintCtx{
        .text = "\x1b]8;;https://footer.example\x1b\\F\x1b]8;;\x1b\\",
        .owner = .footer,
        .row = 3,
    };
    var counters: TraceCounters = .{};
    var metrics: Metrics = .{};
    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = testPlan(),
        .transcript_body = .{ .retain = .{
            .source_area = .{ .top = 2, .bottom = 2 },
            .occupied_last_row = 2,
        } },
        .scroll_plan = testScrollPlan(0),
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .trace_counters = &counters,
    });

    try std.testing.expectEqual(terminal_diff.ShadowCommitState.committed, result.shadow_state);
    try std.testing.expectEqual(@as(usize, 0), counters.body_paints);
    try std.testing.expectEqual(@as(usize, 0), counters.retained_transcript_changed_cells);
    const body_cell = shell.shadow.cellAt(2, 1).?;
    try std.testing.expectEqual(@as(u21, 'B'), body_cell.codepoint);
    try std.testing.expect(body_cell.style.fg.eql(.{ .indexed = 1 }));
    try std.testing.expectEqual(@as(u32, 2), body_cell.style.hyperlink_id);
    try std.testing.expectEqualStrings("https://unused.example", shell.shadow.hyperlinkUrl(1).?);
    try std.testing.expectEqualStrings("https://body.example", shell.shadow.hyperlinkUrl(2).?);
    try std.testing.expectEqualStrings("https://footer.example", shell.shadow.hyperlinkUrl(3).?);
    try std.testing.expectEqual(@as(u32, 3), shell.shadow.cellAt(3, 1).?.style.hyperlink_id);
}

test "buildAndFlushFrame retains prior transcript and paints only a pending tail card" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();
    try shell.shadow.feed("\x1b[2;1HOLD");
    shell.shadow.cursor_row = 3;
    shell.shadow.cursor_col = 1;

    var plan = testPlan();
    plan.layout.content_bottom = 3;
    plan.layout.divider_top_row = 4;
    plan.layout.input_row = 4;
    plan.layout.divider_bottom_row = 4;
    plan.layout.hint_row = 4;
    plan.activity = .none;
    plan.activity_band = paint_plan.FrameBand.empty(.activity);
    plan.transcript_band = .{ .top = 2, .bottom = 3, .owner = .transcript };
    plan.viewport.bottom_row = 3;
    plan.viewport.last_visible_row = 3;
    plan.footer.top = 4;
    plan.footer.top_divider = 4;
    plan.footer.banner = 4;
    plan.footer.input_base = 4;
    plan.footer.picker_divider = 4;
    plan.footer.picker_start = 4;
    plan.footer.bottom_divider = 4;
    plan.footer.hint = 4;
    plan.footer.total_rows = 1;
    plan.footer_band = .{ .top = 4, .bottom = 4, .owner = .footer };
    plan.cursor_target = .{ .row = 4, .col = 1, .visible = true };

    var full_body = PaintCtx{ .text = "WRONG", .owner = .transcript, .row = 2 };
    var pending_card = PaintCtx{ .text = "PENDING", .owner = .transcript, .row = 3 };
    var footer = PaintCtx{ .text = ">", .owner = .footer, .row = 4 };
    var counters: TraceCounters = .{};
    var metrics: Metrics = .{};
    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = plan,
        .transcript_body = .{ .retain = .{
            .source_area = .{ .top = 2, .bottom = 2 },
            .occupied_last_row = 2,
        } },
        .scroll_plan = testScrollPlan(0),
        .body_painter = .{ .ctx = &full_body, .paint = PaintCtx.painter },
        .transcript_tail_painter = .{ .ctx = &pending_card, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .trace_counters = &counters,
    });

    try std.testing.expect(result.is_committed());
    try std.testing.expectEqual(@as(usize, 0), counters.body_paints);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "OLD") == null);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "WRONG") == null);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "PENDING") != null);
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(std.testing.allocator);
    try shell.shadow.rowTextTrimmed(2, &row_text);
    try std.testing.expectEqualStrings("OLD", row_text.items);
    row_text.clearRetainingCapacity();
    try shell.shadow.rowTextTrimmed(3, &row_text);
    try std.testing.expectEqualStrings("PENDING", row_text.items);
}

test "buildAndFlushFrame retains combining suffix without repainting body" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();
    try shell.shadow.feed("\x1b[2;1He\u{0301}");
    shell.shadow.cursor_row = 3;
    shell.shadow.cursor_col = 1;

    var body = PaintCtx{ .text = "wrong", .owner = .transcript, .row = 2 };
    var footer = PaintCtx{ .text = ">", .owner = .footer, .row = 3 };
    var counters: TraceCounters = .{};
    var metrics: Metrics = .{};
    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = testPlan(),
        .transcript_body = .{ .retain = .{
            .source_area = .{ .top = 2, .bottom = 2 },
            .occupied_last_row = 2,
        } },
        .scroll_plan = testScrollPlan(0),
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .trace_counters = &counters,
    });

    try std.testing.expectEqual(terminal_diff.ShadowCommitState.committed, result.shadow_state);
    try std.testing.expectEqual(@as(usize, 0), counters.body_paints);
    try std.testing.expectEqual(@as(usize, 0), counters.retained_transcript_changed_cells);
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(std.testing.allocator);
    try shell.shadow.rowTextTrimmed(2, &row_text);
    try std.testing.expectEqualStrings("e\u{0301}", row_text.items);
}

test "buildAndFlushFrame clips active full repaint away from retained transcript" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();
    try shell.shadow.feed("\x1b[2;1HB\x1b[3;1Hold");
    shell.shadow.cursor_row = 3;
    shell.shadow.cursor_col = 1;

    var plan = testPlan();
    try plan.invalidation.append(.{
        .reason = .owned_band_change,
        .top = 2,
        .bottom = 4,
    });
    try plan.invalidation.append(.{
        .reason = .external_clear,
        .top = 3,
        .bottom = 4,
    });
    plan.footer_clean_allowed = false;
    var body = PaintCtx{ .text = "wrong", .owner = .transcript, .row = 2 };
    var footer = PaintCtx{ .text = "f", .owner = .footer, .row = 3 };
    var counters: TraceCounters = .{};
    var metrics: Metrics = .{};

    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = plan,
        .transcript_body = .{ .retain = .{
            .source_area = .{ .top = 2, .bottom = 2 },
            .occupied_last_row = 2,
        } },
        .scroll_plan = testScrollPlan(0),
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .trace_counters = &counters,
    });

    try std.testing.expectEqual(terminal_diff.ShadowCommitState.committed, result.shadow_state);
    try std.testing.expect(result.full_repaint);
    try std.testing.expectEqual(@as(usize, 0), counters.body_paints);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[3;1H\x1b[2K") != null);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[2;1H\x1b[2K") == null);
    try std.testing.expectEqual(@as(u21, 'B'), shell.shadow.cellAt(2, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), shell.shadow.cellAt(3, 1).?.codepoint);
}

test "buildAndFlushFrame clears active transcript rows outside retained source" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();
    try shell.shadow.feed("\x1b[2;1HB\x1b[3;1Hstale\x1b[4;1Holdf");
    shell.shadow.cursor_row = 4;
    shell.shadow.cursor_col = 1;

    var plan = testPlan();
    plan.layout.content_bottom = 3;
    plan.layout.divider_top_row = 4;
    plan.layout.input_row = 4;
    plan.layout.divider_bottom_row = 4;
    plan.layout.hint_row = 4;
    plan.activity = .none;
    plan.activity_band = paint_plan.FrameBand.empty(.activity);
    plan.transcript_band = .{ .top = 2, .bottom = 3, .owner = .transcript };
    plan.viewport.bottom_row = 3;
    plan.viewport.last_visible_row = 2;
    plan.footer.top = 4;
    plan.footer.top_divider = 4;
    plan.footer.banner = 4;
    plan.footer.input_base = 4;
    plan.footer.picker_divider = 4;
    plan.footer.picker_start = 4;
    plan.footer.bottom_divider = 4;
    plan.footer.hint = 4;
    plan.footer.total_rows = 1;
    plan.footer_band = .{ .top = 4, .bottom = 4, .owner = .footer };
    plan.cursor_target = .{ .row = 4, .col = 1, .visible = true };
    try plan.invalidation.append(.{
        .reason = .external_clear,
        .top = 3,
        .bottom = 4,
    });
    plan.footer_clean_allowed = false;

    var body = PaintCtx{ .text = "wrong", .owner = .transcript, .row = 2 };
    var footer = PaintCtx{ .text = "f", .owner = .footer, .row = 4 };
    var counters: TraceCounters = .{};
    var metrics: Metrics = .{};

    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = plan,
        .transcript_body = .{ .retain = .{
            .source_area = .{ .top = 2, .bottom = 2 },
            .occupied_last_row = 2,
        } },
        .scroll_plan = testScrollPlan(0),
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .trace_counters = &counters,
    });

    try std.testing.expectEqual(terminal_diff.ShadowCommitState.committed, result.shadow_state);
    try std.testing.expect(result.full_repaint);
    try std.testing.expectEqual(@as(usize, 0), counters.body_paints);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[2;1H\x1b[2K") == null);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[3;1H\x1b[2K") != null);
    try std.testing.expectEqual(@as(u21, 'B'), shell.shadow.cellAt(2, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), shell.shadow.cellAt(3, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'f'), shell.shadow.cellAt(4, 1).?.codepoint);
}

test "buildAndFlushFrame rejects invalid retained hyperlink before sink" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();
    shell.shadow.cells[8].style.hyperlink_id = 1;

    var metrics: Metrics = .{};
    try std.testing.expectError(
        error.MissingHyperlinkResource,
        buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
            .plan = testPlan(),
            .transcript_body = .{ .retain = .{
                .source_area = .{ .top = 2, .bottom = 2 },
                .occupied_last_row = 2,
            } },
            .scroll_plan = testScrollPlan(0),
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), sink.write_calls);
}

test "buildAndFlushFrame compares painter-order hyperlink pools by URI" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();

    var footer = PaintCtx{
        .text = "\x1b]8;;https://footer.example\x1b\\F\x1b]8;;\x1b\\",
        .owner = .footer,
        .row = 3,
    };
    var activity = PaintCtx{
        .text = "\x1b]8;;https://activity.example\x1b\\A\x1b]8;;\x1b\\",
        .owner = .activity,
        .row = 1,
    };
    var metrics: Metrics = .{};
    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = testPlan(),
        .scroll_plan = testScrollPlan(0),
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .activity_painter = .{ .ctx = &activity, .paint = PaintCtx.painter },
    });

    try std.testing.expectEqual(terminal_diff.ShadowCommitState.committed, result.shadow_state);
    const activity_cell = shell.shadow.cellAt(1, 1).?;
    const footer_cell = shell.shadow.cellAt(3, 1).?;
    try std.testing.expectEqualStrings(
        "https://activity.example",
        shell.shadow.hyperlinkUrl(activity_cell.style.hyperlink_id).?,
    );
    try std.testing.expectEqualStrings(
        "https://footer.example",
        shell.shadow.hyperlinkUrl(footer_cell.style.hyperlink_id).?,
    );
}

test "buildAndFlushFrame rejects retained body across external clear" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();

    var plan = testPlan();
    try plan.invalidation.append(.{
        .reason = .external_clear,
        .top = 2,
        .bottom = 2,
    });
    var metrics: Metrics = .{};
    try std.testing.expectError(
        error.InvalidRetainedTranscriptBody,
        buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
            .plan = plan,
            .transcript_body = .{ .retain = .{
                .source_area = .{ .top = 2, .bottom = 2 },
                .occupied_last_row = 2,
            } },
            .scroll_plan = testScrollPlan(0),
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), sink.write_calls);
}

test "buildAndFlushFrame stores commit recovery invalidation by value" {
    var sink = BuilderSink{ .fail = true };
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();

    var body = PaintCtx{ .text = "b", .owner = .transcript, .row = 2 };
    var footer = PaintCtx{ .text = "f", .owner = .footer, .row = 3 };
    var metrics: Metrics = .{};

    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = testPlan(),
        .scroll_plan = testScrollPlan(0),
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
    });

    try std.testing.expectEqual(terminal_diff.ShadowCommitState.terminal_partial_write, result.shadow_state);
    const pending = shell.takeRecordedInvalidations();
    try std.testing.expectEqual(@as(u8, 1), pending.len);
    try std.testing.expectEqual(paint_plan.FrameInvalidationReason.partial_write, pending.ranges()[0].reason);
    try std.testing.expect(shell.takeRecordedInvalidations().isEmpty());
}

test "buildAndFlushFrame does not resize authoritative shadow when sink fails" {
    var sink = BuilderSink{ .fail = true };
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();

    var plan = testPlan();
    plan.layout.rows = 5;
    plan.layout.content_bottom = 3;
    plan.layout.divider_top_row = 4;
    plan.layout.input_row = 4;
    plan.layout.divider_bottom_row = 4;
    plan.layout.hint_row = 5;
    plan.viewport.bottom_row = 3;
    plan.viewport.last_visible_row = 3;
    plan.footer.top = 4;
    plan.footer.top_divider = 4;
    plan.footer.banner = 4;
    plan.footer.input_base = 4;
    plan.footer.picker_divider = 4;
    plan.footer.picker_start = 5;
    plan.footer.bottom_divider = 4;
    plan.footer.hint = 5;
    plan.footer_band = .{ .top = 4, .bottom = 5, .owner = .footer };
    plan.cursor_target = .{ .row = 4, .col = 1, .visible = true };

    var body = PaintCtx{ .text = "b", .owner = .transcript, .row = 2 };
    var footer = PaintCtx{ .text = "f", .owner = .footer, .row = 4 };
    var metrics: Metrics = .{};

    const result = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = plan,
        .scroll_plan = frame_scroll_plan.FrameScrollPlan.none(plan.layout.rows, 1),
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
    });

    try std.testing.expectEqual(terminal_diff.ShadowCommitState.terminal_partial_write, result.shadow_state);
    try std.testing.expectEqual(@as(u16, 8), shell.shadow.cols);
    try std.testing.expectEqual(@as(u16, 4), shell.shadow.rows);
}

test "buildAndFlushFrame clears stale rows from the caller-selected committed layout" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();

    var footer_tail = PaintCtx{ .text = "z", .owner = .footer, .row = 4 };
    var metrics: Metrics = .{};

    _ = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = testPlan(),
        .scroll_plan = testScrollPlan(0),
        .footer_painter = .{ .ctx = &footer_tail, .paint = PaintCtx.painter },
    });
    try std.testing.expectEqual(@as(u21, 'z'), shell.shadow.cellAt(4, 1).?.codepoint);
    shell.committed_frame_layout = .{
        .layout_id = 2,
        .owned_top = 1,
        .owned_band = .{ .top = 1, .bottom = 3 },
        .terminal_rows = 4,
        .terminal_cols = 8,
    };
    const alternate_frame_layout: frame_layout.CommittedLayoutSnapshot = .{
        .layout_id = 1,
        .owned_top = 1,
        .owned_band = .{ .top = 1, .bottom = 4 },
        .terminal_rows = 4,
        .terminal_cols = 8,
    };

    var shorter_plan = testPlan();
    shorter_plan.footer.hint = 3;
    shorter_plan.footer.total_rows = 1;
    shorter_plan.footer_band = .{ .top = 3, .bottom = 3, .owner = .footer };
    var footer = PaintCtx{ .text = "f", .owner = .footer, .row = 3 };

    _ = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = shorter_plan,
        .committed_layout = alternate_frame_layout,
        .scroll_plan = testScrollPlan(0),
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
    });

    try std.testing.expectEqual(@as(u21, 'f'), shell.shadow.cellAt(3, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), shell.shadow.cellAt(4, 1).?.codepoint);
    try std.testing.expectEqual(@as(u64, 2), shell.committed_frame_layout.layout_id);
}

test "buildAndFlushFrame clears the committed footer before alignment scroll" {
    var sink = BuilderSink{};
    defer sink.deinit(std.testing.allocator);
    var shell = try TestShell.init(std.testing.allocator, sink.sink());
    shell.bind();
    defer shell.deinit();
    try shell.shadow.feed(
        "\x1b[1;1Hactivity\x1b[2;1Hbody\x1b[3;1Hdraft\x1b[4;1Hhint",
    );

    const plan = testPlan();
    const committed_layout =
        frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
    var body = PaintCtx{ .text = "next", .owner = .transcript, .row = 2 };
    var footer = PaintCtx{ .text = "ready", .owner = .footer, .row = 3 };
    var activity = PaintCtx{ .text = "wait", .owner = .activity, .row = 1 };
    var metrics: Metrics = .{};

    _ = try buildAndFlushFrame(std.testing.allocator, &shell, &metrics, .{
        .plan = plan,
        .committed_layout = committed_layout,
        .scroll_plan = testScrollPlan(1),
        .body_painter = .{ .ctx = &body, .paint = PaintCtx.painter },
        .footer_painter = .{ .ctx = &footer, .paint = PaintCtx.painter },
        .activity_painter = .{ .ctx = &activity, .paint = PaintCtx.painter },
    });

    const footer_clear = std.mem.find(
        u8,
        sink.bytes.items,
        "\x1b[3;1H\x1b[2K",
    ) orelse return error.TestExpectedFooterClear;
    const alignment_scroll = std.mem.find(
        u8,
        sink.bytes.items,
        "\x1b[4;1H\n",
    ) orelse return error.TestExpectedAlignmentScroll;
    try std.testing.expect(footer_clear < alignment_scroll);
}
