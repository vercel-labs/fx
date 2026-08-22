//! Grid-level resize tests that replay `TranscriptRuntime` output through
//! `vt_emulator.Grid` without a TTY or signals.

const std = @import("std");

const question_prompt = @import("../core/agent/question_prompt.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const display_width = @import("../core/shared/display_width.zig");
const diff_mod = @import("../core/output/diff.zig");
const io_mod = @import("../core/shared/io.zig");
const skill_runtime = @import("../core/skills/skill_runtime.zig");
const types = @import("../core/shared/types.zig");
const assistant_presentation = @import("../core/agent/assistant_presentation.zig");
const builtin_commands = @import("../builtins/commands.zig");

const surface_frame = @import("footer/surface_frame.zig");
const surface_invalidation = @import("footer/surface_invalidation.zig");
const interaction_state = @import("footer/interaction_state.zig");
const approval_prompt = @import("../core/permissions/approval_prompt.zig");
const render_input = @import("footer/render_input.zig");
const footer_viewport = @import("footer/viewport.zig");
const activity_runtime = @import("../core/output/activity_runtime.zig");
const core_input_runtime = @import("../core/input/runtime.zig");
const ui_render = @import("render.zig");
const render_engine = @import("render_engine.zig");
const render_request = @import("render_request.zig");
const shell_runtime = @import("shell_runtime.zig");
const shimmer_runtime = @import("transcript/shimmer_runtime.zig");
const transcript_painter = @import("transcript/painter.zig");
const transcript_runtime = @import("transcript/runtime.zig");
const full_transcript_screen = @import("full_transcript_screen.zig");
const vt_emulator = @import("../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const Layout = types.Layout;
const Metrics = types.Metrics;
const TranscriptPreparationSource = transcript_runtime.TranscriptPreparationSource;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const Grid = vt_emulator.Grid;
const InputRuntime = core_input_runtime.Runtime;

const TestBodyDisposition = enum {
    paint,
    retain,
};

const TestFrameObservation = struct {
    shadow_state: render_engine.terminal_diff.ShadowCommitState = .committed,
    body_disposition: TestBodyDisposition = .paint,
    body_paints: usize = 0,
    retained_transcript_changed_cells: usize = 0,
    document_append_bytes: usize = 0,
    document_append_clear_rows: ?u16 = null,
    transcript_history_floor_respected: bool = true,
    planned_scroll_rows: u16 = 0,
    committed_scroll_rows: u16 = 0,
    unplanned_scroll_rows: u16 = 0,
    changed_cells: usize = 0,
};

/// Test harness that captures every byte `TranscriptRuntime` emits and
/// replays it through a virtual terminal.
pub const Harness = struct {
    alloc: Allocator,
    tmp: std.testing.TmpDir,
    file: std.Io.File,
    path: []u8,
    read_offset: u64 = 0,
    vt: Grid,
    shell: TranscriptRuntime,
    metrics: Metrics = .{},
    frame_redraw: bool = false,
    last_frame: TestFrameObservation = .{},

    pub fn init(alloc: Allocator, cols: u16, rows: u16, footer_rows: u16) !Harness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const filename = "ansi.log";
        var file = try tmp.dir.createFile(std.testing.io, filename, .{ .read = true });
        errdefer file.close(io_mod.getIo());

        const path = try alloc.dupe(u8, filename);
        errdefer alloc.free(path);

        const layout = layoutFor(cols, rows, footer_rows);

        var harness: Harness = .{
            .alloc = alloc,
            .tmp = tmp,
            .file = file,
            .path = path,
            .vt = try Grid.init(alloc, cols, rows),
            .shell = .{
                .stdout_file = file,
                .layout = layout,
            },
        };
        harness.vt.cursor_row = layout.content_bottom;
        harness.vt.cursor_col = 1;
        try harness.shell.initBacking(alloc);
        try harness.shell.enableShadowVt(alloc);
        return harness;
    }

    pub fn deinit(self: *Harness) void {
        self.shell.deinit(self.alloc);
        self.file.close(io_mod.getIo());
        self.tmp.cleanup();
        self.alloc.free(self.path);
        self.vt.deinit();
    }

    /// Pull any bytes written since the last flush into the VT grid.
    pub fn flush(self: *Harness) !void {
        const total = try self.file.length(io_mod.getIo());
        if (total <= self.read_offset) return;
        const want: usize = @intCast(total - self.read_offset);
        const buf = try self.alloc.alloc(u8, want);
        defer self.alloc.free(buf);
        const n = try self.file.readPositionalAll(io_mod.getIo(), buf, self.read_offset);
        try self.vt.feed(buf[0..n]);
        self.read_offset += n;
    }

    pub fn driveResize(self: *Harness, cols: u16, rows: u16, footer_rows: u16, settled: bool) !void {
        const new_layout = layoutFor(cols, rows, footer_rows);
        try self.vt.resize(cols, rows);
        try shell_runtime.applyResizeWithLayout(
            &self.shell,
            &self.metrics,
            new_layout,
            settled,
        );
        try self.renderTranscriptFrameIfDirty();
        try self.flush();
    }

    pub fn renderTranscriptFrame(self: *Harness) !void {
        try self.renderTranscriptFrameWithOptions(0, null);
    }

    pub fn renderTranscriptFrameOmittingEntry(self: *Harness, entry_id: u32) !void {
        try self.renderTranscriptFrameWithOptions(0, entry_id);
    }

    pub fn renderTranscriptFrameIfDirty(self: *Harness) !void {
        if (!self.shell.transcript_band_dirty and !self.shell.render_requests.hasPending()) return;
        try self.renderTranscriptFrame();
    }

    pub fn initStartupViewport(self: *Harness, requested_start_row: u16, min_body_rows: u16) !void {
        const reserve_rows = @min(min_body_rows, self.shell.layout.content_bottom);
        const max_start_row = if (reserve_rows > 0)
            self.shell.layout.content_bottom - reserve_rows + 1
        else
            self.shell.layout.content_bottom;
        if (requested_start_row > max_start_row) {
            var cursor_buf: [32]u8 = undefined;
            const cursor = try std.fmt.bufPrint(&cursor_buf, "\x1b[{d};1H", .{self.shell.layout.rows});
            try self.file.writeStreamingAll(io_mod.getIo(), cursor);
            var row: u16 = 0;
            while (row < requested_start_row - max_start_row) : (row += 1) {
                try self.file.writeStreamingAll(io_mod.getIo(), "\n");
            }
        }
        try self.shell.initViewportWithReservedRows(&self.metrics, requested_start_row, min_body_rows);
    }

    pub fn renderTranscriptFrameWithBottomReservation(self: *Harness, bottom_reserved_rows: u16) !void {
        try self.renderTranscriptFrameWithOptions(bottom_reserved_rows, null);
    }

    fn renderTranscriptFrameWithOptions(
        self: *Harness,
        bottom_reserved_rows: u16,
        omitted_entry_id: ?u32,
    ) !void {
        if (!self.shell.render_requests.hasPending()) self.shell.render_requests.request(.transcript);
        var attempt = (try self.shell.render_requests.beginAttempt()).?;
        defer attempt.deinit();
        const snapshot = attempt.snapshot;
        var source = if (self.shell.fullTranscriptActive())
            try self.prepareFullTranscriptSource()
        else if (omitted_entry_id) |entry_id|
            try self.shell.prepareTranscriptSourceOmittingEntry(self.alloc, entry_id)
        else
            try self.shell.prepareTranscriptSource(self.alloc, null);
        defer source.deinit(self.alloc);
        const reserved_rows = @min(bottom_reserved_rows, self.shell.layout.content_bottom -| 1);
        const footer_height = self.shell.layout.rows - self.shell.layout.divider_top_row + 1;
        var prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
        defer if (prepared) |*paint| paint.deinit(self.alloc);
        var fixed_point_ctx = ReservedTranscriptSolveContext{
            .h = self,
            .source = &source,
            .prepared = &prepared,
            .reserved_rows = reserved_rows,
        };
        const fixed_point = try render_engine.frame_fixed_point.solve(
            ReservedTranscriptSolveContext,
            &fixed_point_ctx,
            .{
                .terminal = self.shell.layout,
                .owned_top = self.shell.owned_top_row,
                .footer = .{
                    .natural_rows = footer_height +| reserved_rows,
                    .min_rows = footer_height +| reserved_rows,
                    .max_rows = footer_height +| reserved_rows,
                },
                .transcript = source.preview,
                .prior = self.shell.committed_frame_layout,
            },
            ReservedTranscriptSolveContext.prepareCandidate,
            ReservedTranscriptSolveContext.resolveCandidate,
        );

        var invalidations = snapshot.invalidations;
        self.shell.normalizeFrameInvalidations(&invalidations);
        const paint = &prepared.?;
        var plan = transcriptOnlyPlan(&self.shell, paint, fixed_point.layout.owned_top, invalidations);
        var transition = try resolveAndSealTranscriptTransitionForTest(
            &self.shell,
            self.alloc,
            &source,
            paint,
            &plan,
            fixed_point.scroll_plan,
        );
        defer transition.deinit(self.alloc);
        var paint_ctx = TestFramePaintContext{
            .h = self,
            .prepared = paint,
        };
        const result = try commitTestFrame(
            self,
            plan,
            paint,
            null,
            null,
            fixed_point.scroll_plan,
            &transition,
            &paint_ctx,
        );
        if (result == .committed) {
            attempt.commit(0, render_request.animation_interval_ms, false);
        } else {
            attempt.restore();
        }
    }

    pub fn renderFooterFrame(
        self: *Harness,
        approval: *const approval_prompt.ApprovalPrompt,
        force_redraw: *bool,
        ctx: render_input.RenderContext,
    ) !void {
        if (!self.shell.render_requests.hasPending()) self.shell.render_requests.request(.footer);
        var attempt = (try self.shell.render_requests.beginAttempt()).?;
        defer attempt.deinit();
        const snapshot = attempt.snapshot;
        var invalidations = snapshot.invalidations;
        self.shell.normalizeFrameInvalidations(&invalidations);
        var measurement = try surface_frame.measureSurfaceFooter(self.alloc, &self.shell, approval.projection(), ctx);
        defer measurement.deinit(self.alloc);
        const footer_reservation_changed = measurement.changesFooterReservation(&self.shell);
        const replay_displaced_footer_history =
            measurement.replaysDisplacedTranscriptHistory(&self.shell);
        var prepared: ?transcript_painter.PreparedTranscriptSurfacePaint = null;
        defer if (prepared) |*paint| paint.deinit(self.alloc);
        var resolved_target: ?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget = null;
        const activity = frameActivityState(self, &measurement);
        const tracked_entry_id = switch (measurement.activity_projection) {
            .tool_slot => |slot| slot.entry_id,
            .none, .turn_thinking => null,
        };
        const omitted_entry_id = switch (measurement.activity_projection) {
            .tool_slot => |slot| if (slot.thinking_label != null) slot.entry_id else null,
            .none, .turn_thinking => null,
        };
        var source = if (self.shell.fullTranscriptActive())
            try self.prepareFullTranscriptSource()
        else if (omitted_entry_id) |entry_id|
            try self.shell.prepareTranscriptSourceOmittingEntry(self.alloc, entry_id)
        else
            try self.shell.prepareTranscriptSource(self.alloc, tracked_entry_id);
        defer source.deinit(self.alloc);
        const fixed_point = try solveTestFrame(
            self,
            &measurement,
            activity,
            &source,
            &prepared,
            &resolved_target,
            footer_reservation_changed,
            replay_displaced_footer_history,
            invalidations,
        );

        const footer_rows = measurement.frameLayoutRows(self.shell.layout.rows, fixed_point.layout.footer_area.top);
        const activity_placement = render_engine.activity_placement.resolve(
            measurement.activity_projection,
            activity,
            fixed_point.layout,
        );
        const activity_hides_cursor = switch (activity_placement) {
            .transient_row => true,
            .none, .overlay_entry => false,
        };
        const viewport = if (resolved_target) |target|
            target.selection()
        else if (prepared) |*paint|
            paint.selection
        else
            surface_frame.currentSurfaceFooterTranscriptState(&self.shell).selection;
        const cursor_target = if (resolved_target) |target|
            render_engine.paint_plan.FrameCursorTarget{
                .row = target.cursorRow(),
                .col = target.cursorCol(),
                .visible = !activity_hides_cursor,
            }
        else if (prepared) |*paint|
            render_engine.paint_plan.FrameCursorTarget{
                .row = paint.cursor.cursor_row,
                .col = paint.cursor.cursor_col,
                .visible = !activity_hides_cursor,
            }
        else
            render_engine.paint_plan.FrameCursorTarget{
                .row = footer_rows.input_base,
                .col = 1,
                .visible = !activity_hides_cursor,
            };
        const plan = fixed_point.layout.toPaintPlan(.{
            .footer_rows = footer_rows,
            .viewport = viewport,
            .activity = activity_placement,
            .cursor_target = cursor_target,
            .reset_terminal = self.shell.terminal_reset_pending,
            .preserve_scrollback = !self.shell.pending_scroll_compact,
        });
        var footer_frame = try surface_frame.prepareMeasuredSurfaceFooterFrameForPlan(
            self.alloc,
            &self.shell,
            force_redraw,
            approval.projection(),
            ctx,
            &measurement,
            plan,
            invalidations,
        );
        defer footer_frame.deinit(self.alloc);
        var transition: ?transcript_runtime.TranscriptTransition = null;
        defer if (transition) |*value| value.deinit(self.alloc);
        if (prepared) |*paint| {
            const target = resolved_target orelse return error.MissingResolvedTranscriptTarget;
            transition = try self.shell.sealTranscriptTransition(
                self.alloc,
                &source,
                paint,
                &footer_frame.paint,
                target,
            );
        }

        var paint_ctx = TestFramePaintContext{
            .h = self,
            .prepared = if (prepared) |*paint| paint else null,
            .footer_frame = &footer_frame,
        };
        const result = try commitTestFrame(
            self,
            footer_frame.paint,
            if (prepared) |*paint| paint else null,
            &footer_frame,
            &measurement,
            fixed_point.scroll_plan,
            if (transition) |*value| value else null,
            &paint_ctx,
        );
        if (result == .committed) {
            attempt.commit(0, render_request.animation_interval_ms, paint_ctx.activity_result.painted);
            force_redraw.* = false;
        } else {
            attempt.restore();
        }
    }

    fn prepareFullTranscriptSource(self: *Harness) !TranscriptPreparationSource {
        var projection = try full_transcript_screen.buildProjection(
            self.alloc,
            self.shell.entries.items,
            self.shell.tool_details.items,
            self.shell.command_output_blocks.items,
            self.shell.command_output_render.styles,
            self.shell.layout.cols,
            self.shell.fullTranscriptAnchorEntryId(),
        );
        defer projection.deinit(self.alloc);
        const measurement = try full_transcript_screen.measureProjectionInterruptible(
            self.alloc,
            &projection,
            null,
            self.shell.layout.cols,
            null,
        );
        const visible_rows: u16 = @intCast(@max(@min(measurement.total_rows, std.math.maxInt(u16)), 1));
        const bytes = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
            self.alloc,
            &projection,
            null,
            self.shell.layout.cols,
            visible_rows,
            0,
            null,
        );
        return self.shell.prepareFullTranscriptViewportSource(self.alloc, bytes);
    }
};

const ReservedTranscriptSolveContext = struct {
    h: *Harness,
    source: *const TranscriptPreparationSource,
    prepared: *?transcript_painter.PreparedTranscriptSurfacePaint,
    reserved_rows: u16,

    fn prepareCandidate(
        self: *ReservedTranscriptSolveContext,
        candidate: render_engine.frame_layout.FrameLayout,
    ) !render_engine.frame_fixed_point.CandidatePreparation {
        if (self.prepared.*) |*paint| {
            paint.deinit(self.h.alloc);
            self.prepared.* = null;
        }
        const target_bottom = self.h.shell.layout.content_bottom - self.reserved_rows;
        if (target_bottom < candidate.owned_top) return error.InvalidFrameScrollPlan;
        self.prepared.* = try self.h.shell.prepareTranscriptSurfacePaintFromSourceForArea(
            self.h.alloc,
            &self.h.metrics,
            self.source,
            .{ .top = candidate.owned_top, .bottom = target_bottom },
        );
        self.prepared.*.?.bottom_reserved_rows = self.reserved_rows;
        return .{
            .inline_advance_rows = self.h.shell.planTranscriptScroll(&self.prepared.*.?).planned_rows,
            .occupied_transcript_rows = candidate.transcript_area.height(),
        };
    }

    fn resolveCandidate(
        self: *ReservedTranscriptSolveContext,
        candidate: render_engine.frame_layout.FrameLayout,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
    ) !render_engine.frame_fixed_point.CandidateResolution {
        _ = self;
        _ = scroll_plan;
        return .{ .occupied_transcript_rows = candidate.transcript_area.height() };
    }
};

fn solveTestFrame(
    h: *Harness,
    measurement: *const surface_frame.SurfaceFooterMeasurement,
    activity: render_engine.frame_layout.ActivityState,
    source: *const TranscriptPreparationSource,
    prepared: *?transcript_painter.PreparedTranscriptSurfacePaint,
    resolved_target: *?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget,
    footer_reservation_changed: bool,
    replay_displaced_footer_history: bool,
    attempt_invalidations: render_engine.paint_plan.FrameInvalidationSet,
) !render_engine.frame_fixed_point.FramePlan {
    var ctx = TestFrameSolveContext{
        .h = h,
        .source = source,
        .prepared = prepared,
        .resolved_target = resolved_target,
        .measurement = measurement,
        .activity = activity,
        .footer_reservation_changed = footer_reservation_changed,
        .replay_displaced_footer_history = replay_displaced_footer_history,
        .attempt_invalidations = attempt_invalidations,
    };
    return render_engine.frame_fixed_point.solve(
        TestFrameSolveContext,
        &ctx,
        .{
            .terminal = h.shell.layout,
            .owned_top = h.shell.owned_top_row,
            .footer = measurement.frameLayoutMeasurement(),
            .transcript = source.preview,
            .activity = activity,
            .prior = h.shell.committed_frame_layout,
        },
        TestFrameSolveContext.prepareCandidate,
        TestFrameSolveContext.resolveCandidate,
    );
}

const TestFrameSolveContext = struct {
    h: *Harness,
    source: *const TranscriptPreparationSource,
    prepared: *?transcript_painter.PreparedTranscriptSurfacePaint,
    resolved_target: *?transcript_runtime.TranscriptRuntime.ResolvedTranscriptTarget,
    measurement: *const surface_frame.SurfaceFooterMeasurement,
    activity: render_engine.frame_layout.ActivityState,
    footer_reservation_changed: bool,
    replay_displaced_footer_history: bool,
    attempt_invalidations: render_engine.paint_plan.FrameInvalidationSet,
    scroll_facts: ?transcript_runtime.TranscriptScrollFacts = null,

    fn prepareCandidate(
        self: *TestFrameSolveContext,
        candidate: render_engine.frame_layout.FrameLayout,
    ) !render_engine.frame_fixed_point.CandidatePreparation {
        if (self.prepared.*) |*paint| {
            paint.deinit(self.h.alloc);
            self.prepared.* = null;
        }
        self.resolved_target.* = null;
        self.scroll_facts = null;
        var inline_advance_rows: u16 = 0;
        var occupied_transcript_rows = candidate.transcript_area.height();
        if (!candidate.transcript_area.isEmpty()) {
            self.prepared.* = try self.h.shell.prepareTranscriptSurfacePaintFromSourceForFrame(
                self.h.alloc,
                &self.h.metrics,
                self.source,
                candidate.transcript_area,
                self.footer_reservation_changed,
            );
            const scroll_facts = try self.h.shell.prepareTranscriptScrollFactsForFrame(
                self.h.alloc,
                self.source,
                &self.prepared.*.?,
                self.footer_reservation_changed,
                self.replay_displaced_footer_history,
            );
            self.scroll_facts = scroll_facts;
            inline_advance_rows = scroll_facts.planned_rows;
            if (self.prepared.*.?.selection.last_visible_row >= candidate.transcript_area.top) {
                occupied_transcript_rows = self.prepared.*.?.selection.last_visible_row - candidate.transcript_area.top + 1;
            } else {
                occupied_transcript_rows = 0;
            }
        }
        return .{
            .inline_advance_rows = inline_advance_rows,
            .occupied_transcript_rows = occupied_transcript_rows,
        };
    }

    fn resolveCandidate(
        self: *TestFrameSolveContext,
        candidate: render_engine.frame_layout.FrameLayout,
        scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
    ) !render_engine.frame_fixed_point.CandidateResolution {
        if (candidate.transcript_area.isEmpty()) {
            return .{ .occupied_transcript_rows = 0 };
        }
        const prepared = if (self.prepared.*) |*value| value else return error.MissingTranscriptPaint;
        const scroll_facts = self.scroll_facts orelse return error.MissingTranscriptScrollFacts;
        const activity = render_engine.activity_placement.resolve(
            self.measurement.activity_projection,
            self.activity,
            candidate,
        );
        var candidate_plan = candidate.toPaintPlan(.{
            .footer_rows = self.measurement.frameLayoutRows(
                self.h.shell.layout.rows,
                candidate.footer_area.top,
            ),
            .viewport = prepared.selection,
            .activity = activity,
            .cursor_target = .{
                .row = prepared.cursor.cursor_row,
                .col = prepared.cursor.cursor_col,
                .visible = true,
            },
        });
        candidate_plan.invalidation = try surface_invalidation.resolveCandidateFrameInvalidations(
            &self.h.shell,
            candidate_plan,
            self.measurement.frameInvalidationUpdate(),
            self.attempt_invalidations,
        );
        const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
            self.h.shell.committed_frame_layout.transcript_area,
            candidate_plan.invalidation,
        );
        const target = try self.h.shell.resolveTranscriptTransitionTargetForFrame(
            self.h.alloc,
            self.source,
            prepared,
            render_engine.frame_layout.CommittedLayoutSnapshot.fromLayout(candidate),
            scroll_plan,
            scroll_facts,
            destructive_invalidation,
            activity == .overlay_entry,
        );
        self.resolved_target.* = target;
        return .{ .occupied_transcript_rows = target.occupiedTranscriptRows() };
    }
};

fn frameActivityState(
    h: *const Harness,
    measurement: *const surface_frame.SurfaceFooterMeasurement,
) render_engine.frame_layout.ActivityState {
    return switch (measurement.activity_projection) {
        .none => .none,
        .tool_slot => |slot| if (slot.active)
            transientActivityState(h, measurement.activity_projection, slot.thinking_label != null)
        else
            .none,
        .turn_thinking => transientActivityState(h, measurement.activity_projection, false),
    };
}

fn transientActivityState(
    h: *const Harness,
    projection: activity_runtime.ActivityProjection,
    tool_before_activity: bool,
) render_engine.frame_layout.ActivityState {
    return .{ .thinking = .{
        .gap_above_activity = h.shell.transientAssistantGapRows(),
        .activity_rows = render_input.activityProjectionRows(projection, h.shell.layout.cols),
        .footer_gap_after_activity = render_engine.transcript_blocks.footerBoundaryGapRowsForTail(.turn_summary),
        .tool_before_activity = tool_before_activity,
    } };
}

const TestFramePaintContext = struct {
    h: *Harness,
    prepared: ?*const transcript_painter.PreparedTranscriptSurfacePaint,
    footer_frame: ?*const surface_frame.SurfaceFooterFrame = null,
    activity_result: render_engine.paint_plan.ActivityPaintResult = .{
        .painted = false,
        .row = 0,
        .overlay = false,
    },

    fn paintBody(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
        const self: *TestFramePaintContext = @ptrCast(@alignCast(ctx));
        if (surface.plan.transcript_band.isEmpty()) return;
        const prepared = self.prepared orelse return;
        _ = try self.h.shell.paintPreparedTranscriptIntoSurface(self.h.alloc, surface, prepared);
    }

    fn paintFooter(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
        const self: *TestFramePaintContext = @ptrCast(@alignCast(ctx));
        const frame = self.footer_frame orelse return;
        _ = try footer_viewport.paintFooterIntoSurface(surface, &frame.composed);
    }

    fn paintActivity(ctx: *anyopaque, surface: *render_engine.frame_surface.FrameSurface) anyerror!void {
        const self: *TestFramePaintContext = @ptrCast(@alignCast(ctx));
        const frame = self.footer_frame orelse return;
        self.activity_result = try shimmer_runtime.paintActivityIntoSurface(surface, .{
            .label = frame.label(),
            .tool_label = frame.toolLabel(),
            .shimmer_pos = frame.shimmer_pos,
        });
    }
};

fn commitTestFrame(
    h: *Harness,
    plan: render_engine.paint_plan.PaintPlan,
    prepared: ?*const transcript_painter.PreparedTranscriptSurfacePaint,
    footer_frame: ?*surface_frame.SurfaceFooterFrame,
    footer_measurement: ?*const surface_frame.SurfaceFooterMeasurement,
    scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
    transition: ?*transcript_runtime.TranscriptTransition,
    paint_ctx: *TestFramePaintContext,
) !render_engine.terminal_diff.ShadowCommitState {
    if (prepared != null and transition == null) return error.MissingTranscriptTransition;
    const document_append = if (transition) |value|
        value.document_append
    else
        render_engine.frame_scroll_plan.FrameDocumentAppend{};
    const transcript_body: render_engine.frame_builder.TranscriptBodyDisposition =
        if (transition) |value| switch (value.body_disposition) {
            .paint => .paint,
            .retain_committed => |retained| .{ .retain = retained },
        } else .paint;
    const body_disposition: TestBodyDisposition = switch (transcript_body) {
        .paint => .paint,
        .retain => .retain,
    };
    const resize_commit =
        shell_runtime.pendingResizeFrameCommit(&h.shell, false);
    var counters: render_engine.frame_builder.TraceCounters = .{};
    const result = try render_engine.frame_builder.buildAndFlushFrame(
        h.alloc,
        &h.shell,
        &h.metrics,
        .{
            .plan = plan,
            .body = .transcript,
            .transcript_body = transcript_body,
            .scroll_plan = scroll_plan,
            .document_append = document_append,
            .body_painter = .{ .ctx = paint_ctx, .paint = TestFramePaintContext.paintBody },
            .footer_painter = if (footer_frame != null)
                .{ .ctx = paint_ctx, .paint = TestFramePaintContext.paintFooter }
            else
                null,
            .activity_painter = if (footer_frame != null)
                .{ .ctx = paint_ctx, .paint = TestFramePaintContext.paintActivity }
            else
                null,
            .trace_counters = &counters,
        },
    );
    h.last_frame = .{
        .shadow_state = result.state(),
        .body_disposition = body_disposition,
        .body_paints = counters.body_paints,
        .retained_transcript_changed_cells = counters.retained_transcript_changed_cells,
        .document_append_bytes = document_append.bytes.len,
        .document_append_clear_rows = switch (document_append.clear) {
            .remainder => null,
            .rows => |rows| rows,
        },
        .transcript_history_floor_respected = if (transition) |value|
            value.visual_offset >= value.history_visual_offset
        else
            true,
        .planned_scroll_rows = scroll_plan.terminal_scroll_rows,
        .committed_scroll_rows = result.terminal_scroll_rows_applied(),
        .unplanned_scroll_rows = result.scrollCommit(scroll_plan).unplanned_terminal_scroll_rows,
        .changed_cells = result.changed_cells,
    };

    h.shell.consumeFrameScrollCommit(h.alloc, scroll_plan, result, transition);
    if (result.is_committed()) {
        h.shell.has_committed_frame = true;
        h.shell.terminal_reset_pending = false;
        shell_runtime.acknowledgeResizeFrameCommit(&h.shell, resize_commit);
        if (transition == null) {
            h.shell.committed_frame_layout =
                render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan);
            h.shell.invalidateTranscriptAnchor("empty_test_frame_transcript");
        }
        if (footer_frame) |frame| {
            surface_frame.commitSurfaceFooterFrame(h.alloc, &h.shell, frame, footer_measurement);
        }
        h.shell.shimmer_active = paint_ctx.activity_result.painted;
        h.shell.shimmer_row = if (paint_ctx.activity_result.painted) paint_ctx.activity_result.row else 1;
        h.shell.shimmer_is_overlay = paint_ctx.activity_result.overlay;
        if (paint_ctx.activity_result.overlay) {
            h.shell.invalidateTranscriptAnchor("test_transcript_activity_overlay_commit");
        }
        h.shell.transcript_band_dirty = false;
        h.shell.footer_viewport.clearExternalInvalidation();
    }
    return result.state();
}

fn transcriptOnlyPlan(
    shell: *TranscriptRuntime,
    prepared: *const transcript_painter.PreparedTranscriptSurfacePaint,
    target_owned_top: u16,
    invalidation: render_engine.paint_plan.FrameInvalidationSet,
) render_engine.paint_plan.PaintPlan {
    const selection = prepared.selection;
    const preserved_band = if (target_owned_top > 1)
        render_engine.paint_plan.FrameBand{
            .top = 1,
            .bottom = target_owned_top - 1,
            .owner = .preserved_shell,
        }
    else
        render_engine.paint_plan.FrameBand.empty(.preserved_shell);
    const blank_band = if (selection.top_row > target_owned_top)
        render_engine.paint_plan.FrameBand{
            .top = target_owned_top,
            .bottom = selection.top_row - 1,
            .owner = .gap,
        }
    else
        render_engine.paint_plan.FrameBand.empty(.gap);
    const footer_gap_band = if (selection.bottom_row + 1 < shell.layout.divider_top_row)
        render_engine.paint_plan.FrameBand{
            .top = selection.bottom_row + 1,
            .bottom = shell.layout.divider_top_row - 1,
            .owner = .gap,
        }
    else
        render_engine.paint_plan.FrameBand.empty(.gap);
    return .{
        .layout = shell.layout,
        .viewport = selection,
        .footer = footerRowsForLayout(shell.layout),
        .activity = .none,
        .preserved_band = preserved_band,
        .transcript_band = .{
            .top = selection.top_row,
            .bottom = selection.bottom_row,
            .owner = .transcript,
        },
        .blank_band = blank_band,
        .activity_band = render_engine.paint_plan.FrameBand.empty(.activity),
        .footer_gap_band = footer_gap_band,
        .footer_band = .{
            .top = shell.layout.divider_top_row,
            .bottom = shell.layout.rows,
            .owner = .footer,
        },
        .invalidation = invalidation,
        .footer_clean_allowed = invalidation.isEmpty(),
        .synchronized_update = true,
        .cursor_target = .{
            .row = prepared.cursor.cursor_row,
            .col = prepared.cursor.cursor_col,
            .visible = true,
        },
        .footer_reservation_source = .none,
        .bottom_reserved_rows = prepared.bottom_reserved_rows,
        .preserve_scrollback = !shell.pending_scroll_compact,
        .reset_terminal = shell.terminal_reset_pending,
    };
}

fn resolveAndSealTranscriptTransitionForTest(
    shell: *TranscriptRuntime,
    alloc: Allocator,
    source: *TranscriptPreparationSource,
    prepared: *transcript_painter.PreparedTranscriptSurfacePaint,
    plan: *render_engine.paint_plan.PaintPlan,
    scroll_plan: render_engine.frame_scroll_plan.FrameScrollPlan,
) !transcript_runtime.TranscriptTransition {
    const scroll_facts = try shell.prepareTranscriptScrollFactsForFrame(
        alloc,
        source,
        prepared,
        false,
        false,
    );
    const destructive_invalidation = render_engine.frame_retention.transcriptAreaHasDestructiveInvalidation(
        shell.committed_frame_layout.transcript_area,
        plan.invalidation,
    );
    const resolved = try shell.resolveTranscriptTransitionTargetForFrame(
        alloc,
        source,
        prepared,
        render_engine.frame_layout.CommittedLayoutSnapshot.fromPaintPlan(plan.*),
        scroll_plan,
        scroll_facts,
        destructive_invalidation,
        plan.activity == .overlay_entry,
    );
    resolved.applyToPaintPlan(plan);
    return shell.sealTranscriptTransition(
        alloc,
        source,
        prepared,
        plan,
        resolved,
    );
}

fn footerRowsForLayout(layout: Layout) render_engine.footer_layout.FooterRows {
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

fn layoutFor(cols: u16, rows: u16, footer_rows: u16) Layout {
    std.debug.assert(rows > footer_rows);
    return .{
        .rows = rows,
        .cols = cols,
        .content_bottom = rows - footer_rows,
        .divider_top_row = rows - 3,
        .input_row = rows - 2,
        .divider_bottom_row = rows - 1,
        .hint_row = rows,
    };
}

fn renderTestFooter(
    h: *Harness,
    input: *const InputRuntime,
    approval: *const approval_prompt.ApprovalPrompt,
    force_redraw: *bool,
) !void {
    var ctx = defaultFooterContext(input);
    ctx.transcript_depth = h.shell.transcriptPresentationDepth();
    try renderTestFooterWithContext(h, approval, force_redraw, ctx);
}

fn defaultFooterContext(input: *const InputRuntime) render_input.RenderContext {
    return .{
        .slash_registry = builtin_commands.slash_registry,
        .stream = .{},
        .has_api_key = true,
        .model = "test-model",
        .queued_count = 0,
        .subagent_count = 0,
        .subagent_view_active = false,
        .selected_subagent_id = null,
        .selected_subagent_label = null,
        .selected_subagent_status = null,
        .input = input,
    };
}

fn setToolActivity(
    ctx: *render_input.RenderContext,
    entry_id: u32,
    label: []const u8,
) void {
    ctx.activity = activity_runtime.ActivityProjection{ .tool_slot = .{
        .entry_id = entry_id,
        .fallback_label = label,
        .active = true,
        .kind = .read,
    } };
}

fn appendCompletedToolStatus(h: *Harness, label: []const u8) !u32 {
    const id = types.ToolLifecycleId{ .turn_id = 1, .call_id = label };
    _ = try h.shell.applyToolLifecycle(h.alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "test_tool",
        .activity_kind = .read,
        .arguments_json = "{}",
    } });
    _ = try h.shell.applyToolLifecycle(h.alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = label },
    } });
    return h.shell.toolActivityRecord(id).?.entry_id;
}

fn renderTestFooterWithContext(
    h: *Harness,
    approval: *const approval_prompt.ApprovalPrompt,
    force_redraw: *bool,
    ctx: render_input.RenderContext,
) !void {
    try h.renderFooterFrame(approval, force_redraw, ctx);
}

fn expectRowPrefix(h: *Harness, row: u16, prefix: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    try h.vt.rowText(row, &buf);
    if (buf.items.len < prefix.len or !std.mem.eql(u8, buf.items[0..prefix.len], prefix)) {
        std.debug.print("row {d} did not start with '{s}': '{s}'\n", .{ row, prefix, buf.items });
        var dump_row: u16 = 1;
        while (dump_row <= h.vt.rows) : (dump_row += 1) {
            buf.clearRetainingCapacity();
            try h.vt.rowTextTrimmed(dump_row, &buf);
            if (buf.items.len > 0) {
                std.debug.print("row {d}: '{s}'\n", .{ dump_row, buf.items });
            }
        }
        return error.TestExpectedPrefix;
    }
}

fn expectGridContains(h: *Harness, needle: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var r: u16 = 1;
    while (r <= h.vt.rows) : (r += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(r, &buf);
        if (std.mem.find(u8, buf.items, needle) != null) return;
    }

    std.debug.print("grid did not contain '{s}'\n", .{needle});
    r = 1;
    while (r <= h.vt.rows) : (r += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowTextTrimmed(r, &buf);
        if (buf.items.len > 0) {
            std.debug.print("row {d}: '{s}'\n", .{ r, buf.items });
        }
    }
    return error.TestExpectedGridText;
}

fn expectGridNotContains(h: *Harness, needle: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var r: u16 = 1;
    while (r <= h.vt.rows) : (r += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(r, &buf);
        if (std.mem.find(u8, buf.items, needle) != null) {
            std.debug.print("grid unexpectedly contained '{s}' on row {d}: '{s}'\n", .{ needle, r, buf.items });
            return error.TestUnexpectedGridText;
        }
    }
}

fn countGridOccurrences(h: *Harness, needle: []const u8) !usize {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var count: usize = 0;
    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(row, &buf);
        count += std.mem.count(u8, buf.items, needle);
    }
    return count;
}

fn expectRowEmpty(h: *Harness, row: u16) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    try h.vt.rowTextTrimmed(row, &buf);
    if (buf.items.len != 0) {
        std.debug.print("expected row {d} empty, got: '{s}'\n", .{ row, buf.items });
        return error.TestExpectedEmptyRow;
    }
}

fn expectRowTrimmedEquals(h: *Harness, row: u16, expected: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    try h.vt.rowTextTrimmed(row, &buf);
    if (!std.mem.eql(u8, buf.items, expected)) {
        std.debug.print("expected row {d} to equal '{s}', got: '{s}'\n", .{ row, expected, buf.items });
        return error.TestExpectedRowText;
    }
}

fn findRowContaining(h: *Harness, needle: []const u8) !u16 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(row, &buf);
        if (std.mem.find(u8, buf.items, needle) != null) return row;
    }

    std.debug.print("grid did not contain row text '{s}'\n", .{needle});
    row = 1;
    while (row <= h.vt.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowTextTrimmed(row, &buf);
        if (buf.items.len > 0) {
            std.debug.print("row {d}: '{s}'\n", .{ row, buf.items });
        }
    }
    return error.TestExpectedGridText;
}

fn expectMarkerBackground(h: *Harness, marker: u21, expected: vt_emulator.Color) !void {
    var count: usize = 0;
    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        var col: u16 = 1;
        while (col <= h.vt.cols) : (col += 1) {
            const cell = h.vt.cellAt(row, col) orelse continue;
            if (cell.codepoint != marker) continue;
            try std.testing.expect(cell.style.bg.eql(expected));
            count += 1;
        }
    }
    try std.testing.expect(count > 0);
}

fn findFirstDividerRowAfter(h: *Harness, after_row: u16) !u16 {
    const horizontal = "\xe2\x94\x80";
    const composer_rail = "┃";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var committed_footer_row: ?u16 = null;
    for (h.shell.footer_viewport.rows.items) |row| {
        if (row.row <= after_row) continue;
        if (std.mem.find(u8, row.text.items, horizontal) == null and
            std.mem.find(u8, row.text.items, composer_rail) == null) continue;
        committed_footer_row = @min(committed_footer_row orelse row.row, row.row);
    }
    if (committed_footer_row) |row| return row;

    var row: u16 = after_row + 1;
    while (row <= h.vt.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(row, &buf);
        if (std.mem.find(u8, buf.items, horizontal) != null) return row;
    }

    std.debug.print("grid did not contain footer chrome after row {d}\n", .{after_row});
    return error.TestExpectedGridText;
}

fn firstNonEmptyRows(h: *Harness, alloc: Allocator) ![]u16 {
    var rows: std.ArrayList(u16) = .empty;
    errdefer rows.deinit(alloc);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowTextTrimmed(row, &buf);
        if (buf.items.len > 0) try rows.append(alloc, row);
    }

    return rows.toOwnedSlice(alloc);
}

fn captureTrimmedGrid(h: *Harness, alloc: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var row_buf: std.ArrayList(u8) = .empty;
    defer row_buf.deinit(alloc);

    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        row_buf.clearRetainingCapacity();
        try h.vt.rowTextTrimmed(row, &row_buf);
        try out.appendSlice(alloc, row_buf.items);
        try out.append(alloc, '\n');
    }

    return out.toOwnedSlice(alloc);
}

fn buildLargeSkillListFixture(alloc: Allocator, count: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.print("Visible skills ({d}):\n", .{count});
    for (0..count) |index| {
        try out.writer.print(
            "- skill-{d:0>3}: deterministic fixed width description segment " ++
                "for transcript resize and append validation repeated three times " ++
                "without credentials or network access.\n",
            .{index},
        );
    }
    try out.writer.print("Managed installs ({d}):\n", .{count});
    for (0..count) |index| {
        try out.writer.print(
            "- managed-{d:0>3}: deterministic fixed width installation description " ++
                "for transcript resize and append validation repeated three times " ++
                "without credentials or network access.\n",
            .{index},
        );
    }
    return out.toOwnedSlice();
}

fn expectExactlyOneBlankRowBetween(h: *Harness, content_row: u16, footer_row: u16) !void {
    try std.testing.expectEqual(content_row + 2, footer_row);
    try expectRowEmpty(h, content_row + 1);
}

fn expectAtLeastOneBlankRowBetween(h: *Harness, content_row: u16, footer_row: u16) !void {
    try std.testing.expect(footer_row >= content_row + 2);
    try expectRowEmpty(h, content_row + 1);
}

fn expectOnlyBlankRowsBetween(h: *Harness, content_row: u16, next_row: u16) !void {
    try std.testing.expect(next_row >= content_row + 2);
    var row = content_row + 1;
    while (row < next_row) : (row += 1) {
        try expectRowEmpty(h, row);
    }
}

fn expectCommittedFooterContains(
    h: *const Harness,
    needle: []const u8,
) !void {
    for (h.shell.footer_viewport.rows.items) |row| {
        var plain: [8192]u8 = undefined;
        var plain_len: usize = 0;
        var index: usize = 0;
        while (index < row.text.items.len) {
            if (row.text.items[index] == 0x1b) {
                index = display_width.ansiSequenceEnd(
                    row.text.items,
                    index,
                );
                continue;
            }
            if (plain_len == plain.len) break;
            plain[plain_len] = row.text.items[index];
            plain_len += 1;
            index += 1;
        }
        if (std.mem.find(u8, plain[0..plain_len], needle) != null) {
            return;
        }
    }
    return error.TestExpectedEqual;
}

fn expectActiveInputSurvivesResize(
    input_text: []const u8,
    target_height: u16,
    expected_pre_resize_extra: u16,
) !void {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, input_text);
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 15);
    // Tiny targets require the committed frame to own the full terminal.
    h.shell.owned_top_row = 1;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(expected_pre_resize_extra, h.shell.extra_input_rows);
    try std.testing.expect(h.shell.footer_viewport.has_frame);

    try h.vt.resize(8, target_height);
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(8, target_height, 4),
        true,
    );

    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try expectGridContains(&h, "test-mod");
}

test "active hard-newline footer survives every valid tiny height" {
    for ([_]u16{ 5, 6, 7, 8 }) |target_height| {
        try expectActiveInputSurvivesResize("a\nb", target_height, 1);
    }
}

test "active soft-wrapped footer survives every valid tiny height" {
    const input = "FX_SOFT_START " ++ ("filler " ** 16) ++ "FX_SOFT_END";
    for ([_]u16{ 5, 6, 7, 8 }) |target_height| {
        try expectActiveInputSurvivesResize(input, target_height, 1);
    }
}

test "empty input survives valid tiny height" {
    try expectActiveInputSurvivesResize("", 6, 0);
}

test "single-row input survives valid tiny height" {
    try expectActiveInputSurvivesResize("single row", 6, 0);
}

test "active hard-newline footer renders normally at height nine" {
    try expectActiveInputSurvivesResize("a\nb", 9, 1);
}

test "active file approval resize preserves request selection and priority projection" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 96, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    const preview_lines = [_]diff_mod.PreviewLine{
        .{ .op = .deletion, .old_line = 2, .text = "before" },
        .{ .op = .addition, .new_line = 2, .text = "after" },
    };
    try std.testing.expect(try approval.syncRequest(alloc, .{
        .label = "edit_file note.txt",
        .file = .{
            .kind = .edit,
            .intent = .mutation,
            .preview = .{
                .path = "note.txt",
                .lines = &preview_lines,
                .additions = 1,
                .deletions = 1,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    }));
    approval.decision.choice_index = 2;
    const request_ptr = approval.request.?.label.ptr;

    try h.shell.initViewport(&h.metrics, 4);
    h.shell.owned_top_row = 1;

    for ([_]u16{ 8, 9, 11, 8 }) |height| {
        try h.vt.resize(80, height);
        try shell_runtime.applyResizeWithLayout(
            &h.shell,
            &h.metrics,
            layoutFor(80, height, 4),
            true,
        );
        h.frame_redraw = true;
        try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
        try h.flush();

        try std.testing.expect(approval.isActive());
        try std.testing.expectEqual(request_ptr, approval.request.?.label.ptr);
        try std.testing.expectEqual(@as(u8, 2), approval.decision.choice_index);
        try expectCommittedFooterContains(&h, "note.txt");
        try expectCommittedFooterContains(&h, "- before");
        try expectCommittedFooterContains(&h, "+ after");
        try expectCommittedFooterContains(&h, "1  Apply once");
        try expectCommittedFooterContains(
            &h,
            "2  Apply + allow workspace file access for this session",
        );
        try expectCommittedFooterContains(&h, "❯ 3  Don't apply");
    }
}

test "double trailing newline renders one blank row before footer" {
    var h = try Harness.init(std.testing.allocator, 80, 22, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 15);
    try h.shell.writeTranscript(h.alloc, &h.metrics, "hello\n\n", true);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const hello_row = try findRowContaining(&h, "hello");
    const footer_row = try findFirstDividerRowAfter(&h, hello_row);
    try expectExactlyOneBlankRowBetween(&h, hello_row, footer_row);
}

test "bottom blank assistant row remains visible before footer" {
    var h = try Harness.init(std.testing.allocator, 96, 10, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, "one\ntwo\nthree\nfour\nfive\nsix\n\n");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const tail_row = try findRowContaining(&h, "six");
    const footer_row = try findFirstDividerRowAfter(&h, tail_row);
    try expectExactlyOneBlankRowBetween(&h, tail_row, footer_row);
}

test "dirty assistant repaint preserves reserved footer gap" {
    var h = try Harness.init(std.testing.allocator, 96, 10, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, "one\ntwo\nthree\nfour\nfive\nsix");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, " plus");
    try h.renderTranscriptFrameIfDirty();

    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const tail_row = try findRowContaining(&h, "six plus");
    const footer_row = try findFirstDividerRowAfter(&h, tail_row);
    try expectExactlyOneBlankRowBetween(&h, tail_row, footer_row);
}

test "semantic notice tail keeps one block gap before footer" {
    var h = try Harness.init(std.testing.allocator, 40, 10, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.appendSemanticNotice(h.alloc, .{ .topic = "system", .tone = .information, .body = "one" });
    _ = try h.shell.appendSemanticNotice(h.alloc, .{ .topic = "system", .tone = .information, .body = "two" });
    _ = try h.shell.appendSemanticNotice(h.alloc, .{ .topic = "system", .tone = .information, .body = "three" });
    _ = try h.shell.appendSemanticNotice(h.alloc, .{ .topic = "system", .tone = .information, .body = "four" });
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const content_row = try findRowContaining(&h, "four");
    const footer_row = try findFirstDividerRowAfter(&h, content_row);
    try expectExactlyOneBlankRowBetween(&h, content_row, footer_row);
}

test "tool status update keeps surrounding row geometry stable" {
    var h = try Harness.init(std.testing.allocator, 80, 22, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 12);
    try h.shell.writeTranscript(h.alloc, &h.metrics, "prompt\n\n", true);
    const status_id = try h.shell.appendRawTranscriptEntry(h.alloc, "running tests\n");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const before_rows = try firstNonEmptyRows(&h, h.alloc);
    defer h.alloc.free(before_rows);
    const before_status_row = try findRowContaining(&h, "running tests");
    const before_footer_row = try findFirstDividerRowAfter(&h, before_status_row);

    _ = try h.shell.updateRawBytesEntry(h.alloc, status_id, "tests passed\n");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const after_rows = try firstNonEmptyRows(&h, h.alloc);
    defer h.alloc.free(after_rows);
    const after_status_row = try findRowContaining(&h, "tests passed");
    const after_footer_row = try findFirstDividerRowAfter(&h, after_status_row);

    try std.testing.expectEqualSlices(u16, before_rows, after_rows);
    try std.testing.expectEqual(before_status_row, after_status_row);
    try std.testing.expectEqual(before_footer_row, after_footer_row);
}

test "assistant chunking does not change final row geometry" {
    var one = try Harness.init(std.testing.allocator, 60, 24, 4);
    defer one.deinit();
    var many = try Harness.init(std.testing.allocator, 60, 24, 4);
    defer many.deinit();
    var one_input = InputRuntime{};
    defer one_input.deinit(one.alloc);
    var many_input = InputRuntime{};
    defer many_input.deinit(many.alloc);
    var one_approval: approval_prompt.ApprovalPrompt = .{};
    defer one_approval.deinit(one.alloc);
    var many_approval: approval_prompt.ApprovalPrompt = .{};
    defer many_approval.deinit(many.alloc);

    try one.shell.initViewport(&one.metrics, 10);
    try many.shell.initViewport(&many.metrics, 10);

    try one.shell.writeTranscript(one.alloc, &one.metrics, "prompt\n\n", true);
    try many.shell.writeTranscript(many.alloc, &many.metrics, "prompt\n\n", true);

    _ = try one.shell.streamAssistantChunk(one.alloc, &one.metrics, "alpha beta gamma");

    _ = try many.shell.streamAssistantChunk(many.alloc, &many.metrics, "alpha ");
    _ = try many.shell.streamAssistantChunk(many.alloc, &many.metrics, "beta ");
    _ = try many.shell.streamAssistantChunk(many.alloc, &many.metrics, "gamma");

    try one.renderTranscriptFrame();
    try many.renderTranscriptFrame();
    one.frame_redraw = true;
    many.frame_redraw = true;
    try renderTestFooter(&one, &one_input, &one_approval, &one.frame_redraw);
    try renderTestFooter(&many, &many_input, &many_approval, &many.frame_redraw);
    try one.flush();
    try many.flush();

    const one_footer = try findFirstDividerRowAfter(&one, 1);
    const many_footer = try findFirstDividerRowAfter(&many, 1);
    try std.testing.expectEqual(one_footer, many_footer);

    const one_grid = try captureTrimmedGrid(&one, one.alloc);
    defer one.alloc.free(one_grid);
    const many_grid = try captureTrimmedGrid(&many, many.alloc);
    defer many.alloc.free(many_grid);

    try std.testing.expectEqualStrings(one_grid, many_grid);
}

test "streamed markdown lists reflow through shrink and grow" {
    var h = try Harness.init(std.testing.allocator, 20, 40, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);

    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(h.alloc);
    var formatted: std.ArrayList(u8) = .empty;
    defer formatted.deinit(h.alloc);
    try processor.push(
        h.alloc,
        "- first-abcdefghijklmnopqrstuvwxyzabcdefghijklmnop\n" ++
            "1. second-abcdefghijklmnopqrstuvwxyzabcdefghijklmnop\n" ++
            "  - third-abcdefghijklmnopqrstuvwxyzabcdefghijklmnop\n",
        &formatted,
    );
    try processor.flush(h.alloc, &formatted);

    const first_line_end = std.mem.findScalar(u8, formatted.items, '\n').? + 1;
    const second_line_end = first_line_end + std.mem.findScalar(u8, formatted.items[first_line_end..], '\n').? + 1;
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, formatted.items[0..first_line_end]);
    try h.renderTranscriptFrame();
    try h.flush();

    const first_initial = try findRowContaining(&h, "first-");
    try expectRowPrefix(&h, first_initial, "  • first-");
    try expectRowPrefix(&h, first_initial + 1, "    ");

    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, formatted.items[first_line_end..second_line_end]);
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, formatted.items[second_line_end..]);
    try h.renderTranscriptFrame();
    try h.flush();

    const ordered_initial = try findRowContaining(&h, "second-");
    const nested_initial = try findRowContaining(&h, "third-");
    try std.testing.expect(first_initial < ordered_initial and ordered_initial < nested_initial);
    try expectRowPrefix(&h, ordered_initial, "  1. second-");
    try expectRowPrefix(&h, ordered_initial + 1, "     ");
    try expectRowPrefix(&h, nested_initial, "    • third-");
    try expectRowPrefix(&h, nested_initial + 1, "      ");

    try h.driveResize(15, 40, 4, true);

    const first_narrow = try findRowContaining(&h, "first-");
    const ordered_narrow = try findRowContaining(&h, "second-");
    const nested_narrow = try findRowContaining(&h, "third-");
    try std.testing.expect(first_narrow < ordered_narrow and ordered_narrow < nested_narrow);
    try expectRowPrefix(&h, first_narrow + 1, "    ");
    try expectRowPrefix(&h, ordered_narrow + 1, "     ");
    try expectRowPrefix(&h, nested_narrow + 1, "      ");

    try h.driveResize(26, 40, 4, true);

    const first_wide = try findRowContaining(&h, "first-");
    const ordered_wide = try findRowContaining(&h, "second-");
    const nested_wide = try findRowContaining(&h, "third-");
    try std.testing.expect(first_wide < ordered_wide and ordered_wide < nested_wide);
    try expectRowPrefix(&h, first_wide + 1, "    ");
    try expectRowPrefix(&h, ordered_wide + 1, "     ");
    try expectRowPrefix(&h, nested_wide + 1, "      ");
}

test "streamed markdown definitions reflow through shrink and grow" {
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };

    var h = try Harness.init(std.testing.allocator, 20, 40, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);

    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(h.alloc);
    var formatted: std.ArrayList(u8) = .empty;
    defer formatted.deinit(h.alloc);
    var capture: u8 = 0;
    var completion = assistant_presentation.ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };
    try processor.pushWithCompletions(
        h.alloc,
        "Status\n: first-abcdefghijklmnopqrstuvwxyzabcdefghijklmnop\n",
        &formatted,
        .{ .thematic_rule = &completion },
    );
    try processor.flushWithCompletions(h.alloc, &formatted, .{ .thematic_rule = &completion });

    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, formatted.items);
    try h.renderTranscriptFrame();
    try h.flush();

    const initial = try findRowContaining(&h, "first-");
    try expectRowPrefix(&h, initial, "    first-");
    try expectRowPrefix(&h, initial + 1, "    ");

    try h.driveResize(15, 40, 4, true);

    const narrow = try findRowContaining(&h, "first-");
    try expectRowPrefix(&h, narrow, "    first-");
    try expectRowPrefix(&h, narrow + 1, "    ");

    try h.driveResize(26, 40, 4, true);

    const wide = try findRowContaining(&h, "first-");
    try expectRowPrefix(&h, wide, "    first-");
    try expectRowPrefix(&h, wide + 1, "    ");
}

test "streamed markdown footnotes reflow through shrink and grow" {
    var h = try Harness.init(std.testing.allocator, 20, 40, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);

    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(h.alloc);
    var formatted: std.ArrayList(u8) = .empty;
    defer formatted.deinit(h.alloc);
    try processor.push(
        h.alloc,
        "The cache is scoped to this request.[^cache]\n" ++
            "[^cache]: first-abcdefghijklmnopqrstuvwxyzabcdefghijklmnop\n",
        &formatted,
    );
    try processor.flush(h.alloc, &formatted);

    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, formatted.items);
    try h.renderTranscriptFrame();
    try h.flush();

    const initial = try findRowContaining(&h, "first-");
    try expectRowPrefix(&h, initial, "  [1] first-");
    try expectRowPrefix(&h, initial + 1, "      ");

    try h.driveResize(15, 40, 4, true);

    const narrow = try findRowContaining(&h, "first-");
    try expectRowPrefix(&h, narrow, "  [1] first-");
    try expectRowPrefix(&h, narrow + 1, "      ");

    try h.driveResize(26, 40, 4, true);

    const wide = try findRowContaining(&h, "first-");
    try expectRowPrefix(&h, wide, "  [1] first-");
    try expectRowPrefix(&h, wide + 1, "      ");
}

test "paced footnote marker reflows after its following chunk" {
    var h = try Harness.init(std.testing.allocator, 32, 40, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);

    _ = try h.shell.streamAssistantChunk(
        h.alloc,
        &h.metrics,
        "Forward reference.\n\n\x1b[2m[2] ",
    );
    try h.renderTranscriptFrame();
    try h.flush();

    _ = try h.shell.streamAssistantChunk(
        h.alloc,
        &h.metrics,
        "\x1b[0m\x1b[2mThis definition appears before its reference and ends with FOOTNOTE_DONE.\x1b[22m",
    );
    try h.renderTranscriptFrame();
    try h.flush();

    const marker = try findRowContaining(&h, "This definition appears");
    try expectRowPrefix(&h, marker, "  [2] This definition appears");
    try expectRowPrefix(&h, marker + 1, "      before its reference");
}

test "streamed markdown task lists reflow through shrink and grow" {
    var h = try Harness.init(std.testing.allocator, 20, 40, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);

    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(h.alloc);
    var formatted: std.ArrayList(u8) = .empty;
    defer formatted.deinit(h.alloc);
    try processor.push(
        h.alloc,
        "- [ ] first-abcdefghijklmnopqrstuvwxyzabcdefghijklmnop\n" ++
            "1. [x] completed-abcdefghijklmnopqrstuvwxyzabcdefghijklmnop\n" ++
            "  - [X] nested-abcdefghijklmnopqrstuvwxyzabcdefghijklmnop\n",
        &formatted,
    );
    try processor.flush(h.alloc, &formatted);

    const first_line_end = std.mem.findScalar(u8, formatted.items, '\n').? + 1;
    const second_line_end = first_line_end + std.mem.findScalar(u8, formatted.items[first_line_end..], '\n').? + 1;
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, formatted.items[0..first_line_end]);
    try h.renderTranscriptFrame();
    try h.flush();

    const first_initial = try findRowContaining(&h, "first-");
    try expectRowPrefix(&h, first_initial, "  \xe2\x98\x90 first-");
    try expectRowPrefix(&h, first_initial + 1, "    ");

    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, formatted.items[first_line_end..second_line_end]);
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, formatted.items[second_line_end..]);
    try h.renderTranscriptFrame();
    try h.flush();

    const completed_initial = try findRowContaining(&h, "complete");
    const nested_initial = try findRowContaining(&h, "nested-");
    try std.testing.expect(first_initial < completed_initial and completed_initial < nested_initial);
    try expectRowPrefix(&h, completed_initial + 1, "       ");
    try expectRowPrefix(&h, nested_initial + 1, "      ");
    try expectGridNotContains(&h, "[ ]");
    try expectGridNotContains(&h, "[x]");
    try expectGridNotContains(&h, "[X]");

    const completed_marker = h.vt.cellAt(completed_initial, 6) orelse return error.TestMissingTaskMarker;
    try std.testing.expectEqual(@as(u21, '\u{2713}'), completed_marker.codepoint);
    try std.testing.expect(completed_marker.style.fg.eql(.{ .indexed = 252 }));
    const completed_body = h.vt.cellAt(completed_initial, 8) orelse return error.TestMissingTaskBody;
    try std.testing.expectEqual(@as(u21, 'c'), completed_body.codepoint);
    try std.testing.expect(completed_body.style.fg.eql(.default));

    try h.driveResize(15, 40, 4, true);

    const first_narrow = try findRowContaining(&h, "first-");
    const completed_narrow = try findRowContaining(&h, "complete");
    const nested_narrow = try findRowContaining(&h, "nested-");
    try std.testing.expect(first_narrow < completed_narrow and completed_narrow < nested_narrow);
    try expectRowPrefix(&h, first_narrow + 1, "    ");
    try expectRowPrefix(&h, completed_narrow + 1, "       ");
    try expectRowPrefix(&h, nested_narrow + 1, "      ");

    const completed_narrow_marker = h.vt.cellAt(completed_narrow, 6) orelse return error.TestMissingTaskMarker;
    try std.testing.expect(completed_narrow_marker.style.fg.eql(.{ .indexed = 252 }));
    const completed_narrow_body = h.vt.cellAt(completed_narrow, 8) orelse return error.TestMissingTaskBody;
    try std.testing.expect(completed_narrow_body.style.fg.eql(.default));

    try h.driveResize(26, 40, 4, true);

    const first_wide = try findRowContaining(&h, "first-");
    const completed_wide = try findRowContaining(&h, "complete");
    const nested_wide = try findRowContaining(&h, "nested-");
    try std.testing.expect(first_wide < completed_wide and completed_wide < nested_wide);
    try expectRowPrefix(&h, first_wide + 1, "    ");
    try expectRowPrefix(&h, completed_wide + 1, "       ");
    try expectRowPrefix(&h, nested_wide + 1, "      ");

    const completed_wide_marker = h.vt.cellAt(completed_wide, 6) orelse return error.TestMissingTaskMarker;
    try std.testing.expect(completed_wide_marker.style.fg.eql(.{ .indexed = 252 }));
    const completed_wide_body = h.vt.cellAt(completed_wide, 8) orelse return error.TestMissingTaskBody;
    try std.testing.expect(completed_wide_body.style.fg.eql(.default));
}

test "streamed depth-three markdown blockquotes reflow through shrink and grow" {
    var h = try Harness.init(std.testing.allocator, 20, 40, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);
    var frame_redraw = true;

    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(h.alloc);
    var formatted: std.ArrayList(u8) = .empty;
    defer formatted.deinit(h.alloc);
    try processor.push(
        h.alloc,
        "> > > first-abcdefghijklmnopqrstuvwxyzabcdefghijklmnop\n" ++
            "lazy-abcdefghijklmnopqrstuvwxyzabcdefghijklmnop\n",
        &formatted,
    );
    try processor.flush(h.alloc, &formatted);

    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, formatted.items);
    try h.renderTranscriptFrame();
    try h.flush();

    const initial = try findRowContaining(&h, "first-");
    const initial_lazy = try findRowContaining(&h, "lazy-");
    try expectRowPrefix(&h, initial, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 first-");
    try expectRowPrefix(&h, initial + 1, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 ");
    try expectRowPrefix(&h, initial_lazy, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 lazy-");
    try expectRowPrefix(&h, initial_lazy + 1, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 ");
    try expectGridNotContains(&h, "> > > first-");

    try h.driveResize(15, 40, 4, true);

    const narrow = try findRowContaining(&h, "first-");
    const narrow_lazy = try findRowContaining(&h, "lazy-");
    try expectRowPrefix(&h, narrow, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 first-");
    try expectRowPrefix(&h, narrow + 1, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 ");
    try expectRowPrefix(&h, narrow_lazy, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 lazy-");
    try expectRowPrefix(&h, narrow_lazy + 1, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 ");

    try h.driveResize(26, 40, 4, true);

    const wide = try findRowContaining(&h, "first-");
    const wide_lazy = try findRowContaining(&h, "lazy-");
    try expectRowPrefix(&h, wide, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 first-");
    try expectRowPrefix(&h, wide + 1, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 ");
    try expectRowPrefix(&h, wide_lazy, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 lazy-");
    try expectRowPrefix(&h, wide_lazy + 1, "  \xe2\x94\x82 \xe2\x94\x82 \xe2\x94\x82 ");

    try renderTestFooter(&h, &input, &approval, &frame_redraw);
    try h.flush();
    _ = try findFirstDividerRowAfter(&h, wide);
}

test "streamed H1 keeps bold underline through shrink and grow" {
    var h = try Harness.init(std.testing.allocator, 30, 40, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);

    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(h.alloc);
    var formatted: std.ArrayList(u8) = .empty;
    defer formatted.deinit(h.alloc);
    try processor.push(
        h.alloc,
        "# Heading alpha beta gamma delta epsilon zeta\n",
        &formatted,
    );

    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, formatted.items);
    try h.renderTranscriptFrame();
    try h.flush();

    const initial = try findRowContaining(&h, "Heading");
    const initial_cell = h.vt.cellAt(initial, 3) orelse return error.TestMissingHeadingCell;
    try std.testing.expect(initial_cell.style.flags.bold);
    try std.testing.expect(initial_cell.style.flags.underline);
    try expectGridNotContains(&h, "# Heading");

    try h.driveResize(12, 40, 4, true);
    const narrow = try findRowContaining(&h, "Heading");
    const narrow_cell = h.vt.cellAt(narrow, 3) orelse return error.TestMissingHeadingCell;
    try std.testing.expect(narrow_cell.style.flags.bold);
    try std.testing.expect(narrow_cell.style.flags.underline);

    try h.driveResize(30, 40, 4, true);
    const wide = try findRowContaining(&h, "Heading");
    const wide_cell = h.vt.cellAt(wide, 3) orelse return error.TestMissingHeadingCell;
    try std.testing.expect(wide_cell.style.flags.bold);
    try std.testing.expect(wide_cell.style.flags.underline);
}

test "streamed inline code color survives shrink and grow" {
    const cases = [_]struct { light: bool, fg: u8 }{
        .{ .light = false, .fg = 245 },
        .{ .light = true, .fg = 247 },
    };
    defer assistant_presentation.setInlineCodeTheme(false);

    for (cases) |case| {
        assistant_presentation.setInlineCodeTheme(case.light);

        var h = try Harness.init(std.testing.allocator, 40, 40, 4);
        defer h.deinit();
        try h.shell.initViewport(&h.metrics, 1);

        var processor = assistant_presentation.MarkdownProcessor{};
        defer processor.deinit(h.alloc);
        var formatted: std.ArrayList(u8) = .empty;
        defer formatted.deinit(h.alloc);
        try processor.push(h.alloc, "`inline code spans multiple rows` Q\n", &formatted);

        _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, formatted.items);
        try h.renderTranscriptFrame();
        try h.flush();

        var code_row = try findRowContaining(&h, "inline code spans multiple rows Q");
        var code_cell = h.vt.cellAt(code_row, 3) orelse return error.TestMissingInlineCodeCell;
        try std.testing.expect(code_cell.style.fg.eql(.{ .indexed = case.fg }));
        try std.testing.expect(code_cell.style.bg.eql(.default));
        try expectMarkerBackground(&h, 'Q', .default);

        try h.driveResize(12, 40, 4, true);
        code_row = try findRowContaining(&h, "inline");
        code_cell = h.vt.cellAt(code_row, 3) orelse return error.TestMissingInlineCodeCell;
        try std.testing.expect(code_cell.style.fg.eql(.{ .indexed = case.fg }));
        try std.testing.expect(code_cell.style.bg.eql(.default));
        try expectMarkerBackground(&h, 'Q', .default);

        try h.driveResize(40, 40, 4, true);
        code_row = try findRowContaining(&h, "inline code spans multiple rows Q");
        code_cell = h.vt.cellAt(code_row, 3) orelse return error.TestMissingInlineCodeCell;
        try std.testing.expect(code_cell.style.fg.eql(.{ .indexed = case.fg }));
        try std.testing.expect(code_cell.style.bg.eql(.default));
        try expectMarkerBackground(&h, 'Q', .default);
    }
}

test "semantic code block colors source and keeps current footer rail styled through resize" {
    var h = try Harness.init(std.testing.allocator, 40, 40, 4);
    defer h.deinit();
    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);
    var frame_redraw = true;
    try h.shell.initViewport(&h.metrics, 1);

    {
        var block = assistant_presentation.CodeBlockPayload{
            .language = try h.alloc.dupe(u8, ""),
            .code = try h.alloc.dupe(u8, "const hook = await resumeHook(token, { cleanup: true } as CleanupSignal);\n"),
        };
        errdefer block.deinit(h.alloc);
        _ = try h.shell.appendAssistantCodeBlockOwned(h.alloc, block);
    }
    {
        var block = assistant_presentation.CodeBlockPayload{
            .language = try h.alloc.dupe(u8, "python"),
            .code = try h.alloc.dupe(u8, "def ready():\n    return True\n"),
        };
        errdefer block.deinit(h.alloc);
        _ = try h.shell.appendAssistantCodeBlockOwned(h.alloc, block);
    }
    try h.renderTranscriptFrame();
    try renderTestFooter(&h, &input, &approval, &frame_redraw);
    try h.flush();

    var code_row = try findRowContaining(&h, "const hook");
    var code_cell = h.vt.cellAt(code_row, 5) orelse return error.TestMissingCodeCell;
    try std.testing.expectEqual(@as(u21, 'c'), code_cell.codepoint);
    try std.testing.expect(code_cell.style.fg.eql(.{ .indexed = 252 }));
    const code_border = h.vt.cellAt(code_row, 3) orelse return error.TestMissingCodeBorder;
    try std.testing.expect(code_border.style.fg.eql(.default));
    var python_row = try findRowContaining(&h, "def ready");
    var python_cell = h.vt.cellAt(python_row, 5) orelse return error.TestMissingCodeCell;
    try std.testing.expectEqual(@as(u21, 'd'), python_cell.codepoint);
    try std.testing.expect(python_cell.style.fg.eql(.{ .indexed = 252 }));
    const initial_footer = try findFirstDividerRowAfter(&h, code_row);
    const initial_footer_cell = h.vt.cellAt(initial_footer, 1) orelse return error.TestMissingFooterCell;
    try std.testing.expectEqual(@as(u21, '┃'), initial_footer_cell.codepoint);
    try std.testing.expect(initial_footer_cell.style.fg.eql(.{ .indexed = 255 }));

    try h.driveResize(20, 40, 4, true);
    frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &frame_redraw);
    try h.flush();

    code_row = try findRowContaining(&h, "const hook");
    code_cell = h.vt.cellAt(code_row, 5) orelse return error.TestMissingCodeCell;
    try std.testing.expectEqual(@as(u21, 'c'), code_cell.codepoint);
    try std.testing.expect(code_cell.style.fg.eql(.{ .indexed = 252 }));
    const resized_border = h.vt.cellAt(code_row, 3) orelse return error.TestMissingCodeBorder;
    try std.testing.expect(resized_border.style.fg.eql(.default));
    python_row = try findRowContaining(&h, "def ready");
    python_cell = h.vt.cellAt(python_row, 3) orelse return error.TestMissingCodeCell;
    try std.testing.expectEqual(@as(u21, 'd'), python_cell.codepoint);
    try std.testing.expect(python_cell.style.fg.eql(.{ .indexed = 252 }));
    const resized_footer = try findFirstDividerRowAfter(&h, code_row);
    const resized_footer_cell = h.vt.cellAt(resized_footer, 1) orelse return error.TestMissingFooterCell;
    try std.testing.expectEqual(@as(u21, '┃'), resized_footer_cell.codepoint);
    try std.testing.expect(resized_footer_cell.style.fg.eql(.{ .indexed = 255 }));
}

test "semantic code block keeps readable light theme colors through resize" {
    var h = try Harness.init(std.testing.allocator, 40, 40, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);
    h.shell.setCommandOutputRenderPolicy(.{ .code_highlight_theme = .light });

    {
        var block = assistant_presentation.CodeBlockPayload{
            .language = try h.alloc.dupe(u8, "zig"),
            .code = try h.alloc.dupe(u8, "const value = \"ready\"; // comment\n"),
        };
        errdefer block.deinit(h.alloc);
        _ = try h.shell.appendAssistantCodeBlockOwned(h.alloc, block);
    }
    try h.renderTranscriptFrame();
    try h.flush();

    var code_row = try findRowContaining(&h, "const value");
    var keyword_cell = h.vt.cellAt(code_row, 5) orelse return error.TestMissingCodeCell;
    try std.testing.expectEqual(@as(u21, 'c'), keyword_cell.codepoint);
    try std.testing.expect(keyword_cell.style.fg.eql(.{ .indexed = 238 }));

    try h.driveResize(20, 40, 4, true);
    code_row = try findRowContaining(&h, "const value");
    keyword_cell = h.vt.cellAt(code_row, 5) orelse return error.TestMissingCodeCell;
    try std.testing.expectEqual(@as(u21, 'c'), keyword_cell.codepoint);
    try std.testing.expect(keyword_cell.style.fg.eql(.{ .indexed = 238 }));
}

test "semantic code block drops its frame before wrapping source that fits" {
    var h = try Harness.init(std.testing.allocator, 44, 40, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);

    {
        var block = assistant_presentation.CodeBlockPayload{
            .language = try h.alloc.dupe(u8, "text"),
            .code = try h.alloc.dupe(
                u8,
                "    ┌────────────────────────────────┐\n" ++
                    "    │ ROOT                           │\n" ++
                    "    └────────────────────────────────┘\n",
            ),
        };
        errdefer block.deinit(h.alloc);
        _ = try h.shell.appendAssistantCodeBlockOwned(h.alloc, block);
    }
    try h.renderTranscriptFrame();
    try h.flush();
    try expectGridContains(&h, "┌ text");

    try h.driveResize(40, 40, 4, true);
    try expectGridNotContains(&h, "┌ text");
    const first_source_row = try findRowContaining(&h, "┌────────────────────────────────┐");
    try expectRowTrimmedEquals(&h, first_source_row, "      ┌────────────────────────────────┐");
    try expectRowTrimmedEquals(&h, first_source_row + 1, "      │ ROOT                           │");
    try expectRowTrimmedEquals(&h, first_source_row + 2, "      └────────────────────────────────┘");

    try h.driveResize(39, 40, 4, true);
    try expectGridContains(&h, "┌ text");

    try h.driveResize(44, 40, 4, true);
    try expectGridContains(&h, "┌ text");
}

test "streamed paragraphs keep words together through shrink and grow" {
    var h = try Harness.init(std.testing.allocator, 32, 24, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);

    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, "alpha beta gamma delta epsilon");
    try h.renderTranscriptFrame();
    try h.flush();
    _ = try findRowContaining(&h, "alpha beta gamma delta epsilon");

    try h.driveResize(16, 24, 4, true);
    const narrow_first = try findRowContaining(&h, "alpha beta");
    try expectRowPrefix(&h, narrow_first + 1, "  gamma");

    try h.driveResize(32, 24, 4, true);
    _ = try findRowContaining(&h, "alpha beta gamma delta epsilon");
}

test "entry-bound shimmer resolves to the painted status row without moving footer" {
    var h = try Harness.init(std.testing.allocator, 80, 22, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 12);
    _ = try h.shell.appendRawTranscriptEntry(h.alloc, "first\n\n");
    const status_id = try h.shell.appendRawTranscriptEntry(h.alloc, "Writing index.html\n");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const painted_status_row = try findRowContaining(&h, "Writing index.html");
    try std.testing.expectEqual(painted_status_row, h.shell.rowForEntryId(status_id).?);
    const footer_before = try findFirstDividerRowAfter(&h, 1);

    var ctx = defaultFooterContext(&input);
    setToolActivity(&ctx, status_id, "Writing index.html");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const shimmer_row = try findRowContaining(&h, "Writing index.html");
    const footer_after = try findFirstDividerRowAfter(&h, 1);
    try std.testing.expectEqual(painted_status_row, shimmer_row);
    try std.testing.expectEqual(footer_before, footer_after);
}

test "entry-bound shimmer overlays status row without moving footer" {
    var h = try Harness.init(std.testing.allocator, 80, 22, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 12);
    const status_id = try appendCompletedToolStatus(&h, "running tests");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const footer_before = try findFirstDividerRowAfter(&h, 1);

    var ctx = defaultFooterContext(&input);
    setToolActivity(&ctx, status_id, "running tests");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const footer_during = try findFirstDividerRowAfter(&h, 1);
    try std.testing.expectEqual(footer_before, footer_during);
}

test "moving entry-bound shimmer restores the previous transcript row" {
    var h = try Harness.init(std.testing.allocator, 80, 22, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 12);
    const first_id = try appendCompletedToolStatus(&h, "status-one complete");
    const second_id = try appendCompletedToolStatus(&h, "status-two pending");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const first_row = try findRowContaining(&h, "status-one complete");
    const second_row = try findRowContaining(&h, "status-two pending");

    var ctx = defaultFooterContext(&input);
    setToolActivity(&ctx, first_id, "Reading alpha");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    try std.testing.expectEqual(first_row, try findRowContaining(&h, "status-one complete"));
    try expectGridNotContains(&h, "Reading alpha");

    setToolActivity(&ctx, second_id, "Reading beta");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    try std.testing.expectEqual(first_row, try findRowContaining(&h, "status-one complete"));
    try std.testing.expectEqual(second_row, try findRowContaining(&h, "status-two pending"));
    try expectGridNotContains(&h, "Reading beta");
}

test "clearing entry-bound shimmer restores the transcript row" {
    var h = try Harness.init(std.testing.allocator, 80, 22, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 12);
    const status_id = try appendCompletedToolStatus(&h, "status survives overlay");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const status_row = try findRowContaining(&h, "status survives overlay");

    var ctx = defaultFooterContext(&input);
    setToolActivity(&ctx, status_id, "Loading overlay");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    try std.testing.expectEqual(status_row, try findRowContaining(&h, "status survives overlay"));
    try expectGridNotContains(&h, "Loading overlay");

    ctx.activity = .none;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    try std.testing.expectEqual(status_row, try findRowContaining(&h, "status survives overlay"));
    try expectGridNotContains(&h, "Loading overlay");
}

test "entry-bound shimmer is suppressed when footer banner covers its row" {
    var h = try Harness.init(std.testing.allocator, 80, 12, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, h.shell.layout.content_bottom);
    const status_id = try appendCompletedToolStatus(&h, "bottom status row");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const status_row = try findRowContaining(&h, "bottom status row");
    try std.testing.expect(status_row < try findFirstDividerRowAfter(&h, status_row));

    var ctx = defaultFooterContext(&input);
    setToolActivity(&ctx, status_id, "Overlay should fit");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    try std.testing.expectEqual(status_row, try findRowContaining(&h, "bottom status row"));
    try expectGridNotContains(&h, "Overlay should fit");

    ctx.queued_count = 1;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    try expectGridContains(&h, "1 queued message");
    try expectGridNotContains(&h, "Overlay should fit");
    try std.testing.expect(!h.shell.shimmer_active);
}

test "footer banner keeps a gap after entry-bound activity" {
    var h = try Harness.init(std.testing.allocator, 96, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 6);
    const status_id = try appendCompletedToolStatus(&h, "Opening file");
    try h.renderTranscriptFrame();

    var ctx = defaultFooterContext(&input);
    setToolActivity(&ctx, status_id, "Overlay should be hidden by banner");
    ctx.queued_count = 1;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const activity_row = try findRowContaining(&h, "Opening file");
    const banner_row = try findRowContaining(&h, "1 queued message");
    try expectExactlyOneBlankRowBetween(&h, activity_row, banner_row);
    try expectGridNotContains(&h, "Overlay should be hidden by banner");
    try std.testing.expect(!h.shell.shimmer_active);
}

test "footer banner reserves blank row after bottom entry-bound activity" {
    var h = try Harness.init(std.testing.allocator, 96, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    var filler: std.ArrayList(u8) = .empty;
    defer filler.deinit(h.alloc);
    var line: u16 = 0;
    while (line < h.shell.layout.content_bottom - 2) : (line += 1) {
        try filler.appendSlice(h.alloc, "paragraph line\n");
    }
    _ = try h.shell.appendRawTranscriptEntryClassified(h.alloc, filler.items, .subagent_status);
    const status_id = try appendCompletedToolStatus(&h, "Creating project");
    try h.renderTranscriptFrame();
    try h.flush();

    const bottom_activity_row = try findRowContaining(&h, "Creating project");
    try std.testing.expectEqual(h.shell.layout.content_bottom, bottom_activity_row);

    var ctx = defaultFooterContext(&input);
    setToolActivity(&ctx, status_id, "Creating project");
    ctx.queued_count = 1;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const activity_row = try findRowContaining(&h, "Creating project");
    const banner_row = try findRowContaining(&h, "1 queued message");
    try expectExactlyOneBlankRowBetween(&h, activity_row, banner_row);
    try std.testing.expect(!h.shell.shimmer_active);

    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const activity_row_after = try findRowContaining(&h, "Creating project");
    const banner_row_after = try findRowContaining(&h, "1 queued message");
    try expectExactlyOneBlankRowBetween(&h, activity_row_after, banner_row_after);
    try std.testing.expect(!h.shell.shimmer_active);
}

test "banner-suppressed overlay restore keeps reserved footer gap" {
    var h = try Harness.init(std.testing.allocator, 96, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    var filler: std.ArrayList(u8) = .empty;
    defer filler.deinit(h.alloc);
    var line: u16 = 0;
    while (line < h.shell.layout.content_bottom - 2) : (line += 1) {
        try filler.appendSlice(h.alloc, "paragraph line\n");
    }
    _ = try h.shell.appendRawTranscriptEntryClassified(h.alloc, filler.items, .subagent_status);
    const status_id = try appendCompletedToolStatus(&h, "Creating project");
    try h.renderTranscriptFrame();
    try h.flush();

    var ctx = defaultFooterContext(&input);
    setToolActivity(&ctx, status_id, "Creating project");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    try std.testing.expect(!h.shell.shimmer_active);

    ctx.queued_count = 1;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const activity_row = try findRowContaining(&h, "Creating project");
    const banner_row = try findRowContaining(&h, "1 queued message");
    try expectExactlyOneBlankRowBetween(&h, activity_row, banner_row);
    try std.testing.expect(!h.shell.shimmer_active);
}

test "thinking shimmer reserves assistant-gap rows and clears back to stable footer" {
    var h = try Harness.init(std.testing.allocator, 80, 22, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 12);
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, "prompt\n", true, .subagent_status);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const footer_idle = try findFirstDividerRowAfter(&h, 1);

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    const footer_thinking = try findFirstDividerRowAfter(&h, 1);
    const thinking_row = try findRowContaining(&h, "Thinking");
    try std.testing.expect(footer_thinking > footer_idle);
    try expectExactlyOneBlankRowBetween(&h, thinking_row, footer_thinking);

    ctx.stream.active = false;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    const footer_after = try findFirstDividerRowAfter(&h, 1);
    try std.testing.expectEqual(footer_idle, footer_after);
}

test "completed presentation tail keeps thinking slot until turn summary" {
    var h = try Harness.init(std.testing.allocator, 80, 22, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 4);
    const prompt = try h.alloc.dupe(u8, "explain the renderer");
    _ = try h.shell.appendUserTurnOwned(h.alloc, .{ .text = prompt, .images = &.{} });
    try h.renderTranscriptFrame();

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const user_row = try findRowContaining(&h, "explain the renderer");
    const thinking_row = try findRowContaining(&h, "Thinking");
    try expectOnlyBlankRowsBetween(&h, user_row, thinking_row);
    const footer_during_thinking = try findFirstDividerRowAfter(&h, thinking_row);
    try expectExactlyOneBlankRowBetween(&h, thinking_row, footer_during_thinking);

    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, "assistant starts here");
    try h.renderTranscriptFrame();
    ctx.stream.active = false;
    ctx.completed_assistant_presentation_tail = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const assistant_row = try findRowContaining(&h, "assistant starts here");
    const thinking_after_provider_finish = try findRowContaining(&h, "Thinking");
    try std.testing.expect(thinking_after_provider_finish > thinking_row);
    try expectExactlyOneBlankRowBetween(&h, assistant_row, thinking_after_provider_finish);
    const footer_after_assistant = try findFirstDividerRowAfter(&h, thinking_after_provider_finish);
    try expectExactlyOneBlankRowBetween(&h, thinking_after_provider_finish, footer_after_assistant);

    _ = try h.shell.appendTurnSummaryEntry(h.alloc, .{
        .thinking_duration_ms = 1_000,
        .turn_duration_ms = 4_000,
        .token_progress = .{ .input_tokens = 200, .output_tokens = 118 },
    });
    try h.renderTranscriptFrame();
    ctx.completed_assistant_presentation_tail = false;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    try expectGridNotContains(&h, "Thinking");
    const summary_row = try findRowContaining(&h, "  4s (↑200 ↓118)");
    const footer_after_summary = try findFirstDividerRowAfter(&h, summary_row);
    try expectExactlyOneBlankRowBetween(&h, summary_row, footer_after_summary);
}

test "thinking shimmer keeps a gap after completed tool status" {
    var h = try Harness.init(std.testing.allocator, 96, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 6);
    _ = try appendCompletedToolStatus(&h, "Listed src");
    try h.renderTranscriptFrame();

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const status_row = try findRowContaining(&h, "Listed src");
    const thinking_row = try findRowContaining(&h, "Thinking");
    try expectExactlyOneBlankRowBetween(&h, status_row, thinking_row);
}

test "active tool status stays above the thinking slot" {
    var h = try Harness.init(std.testing.allocator, 96, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 6);
    const status_id = try appendCompletedToolStatus(&h, "Running read_file");
    try h.renderTranscriptFrame();

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    setToolActivity(&ctx, status_id, "Running read_file");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const status_row = try findRowContaining(&h, "Running read_file");
    const thinking_row = try findRowContaining(&h, "Thinking");
    try std.testing.expect(status_row < thinking_row);
    try expectExactlyOneBlankRowBetween(&h, status_row, thinking_row);
    const footer_row = try findFirstDividerRowAfter(&h, thinking_row);
    try expectExactlyOneBlankRowBetween(&h, thinking_row, footer_row);
}

test "assistant paragraph keeps a gap after completed tool status" {
    var h = try Harness.init(std.testing.allocator, 96, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 6);
    _ = try appendCompletedToolStatus(&h, "Listed project");
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, "assistant paragraph");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const status_row = try findRowContaining(&h, "Listed project");
    const assistant_row = try findRowContaining(&h, "assistant paragraph");
    try expectExactlyOneBlankRowBetween(&h, status_row, assistant_row);
}

test "assistant paragraph replaces thinking gap after completed tool status" {
    var h = try Harness.init(std.testing.allocator, 96, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 6);
    _ = try appendCompletedToolStatus(&h, "Inspected file");
    try h.renderTranscriptFrame();

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const status_row = try findRowContaining(&h, "Inspected file");
    const thinking_row = try findRowContaining(&h, "Thinking");
    try expectExactlyOneBlankRowBetween(&h, status_row, thinking_row);

    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, "\nassistant paragraph after inspect");
    try h.renderTranscriptFrameIfDirty();

    ctx.stream.active = false;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const status_after = try findRowContaining(&h, "Inspected file");
    const assistant_row = try findRowContaining(&h, "assistant paragraph after inspect");
    try expectExactlyOneBlankRowBetween(&h, status_after, assistant_row);
    try expectGridNotContains(&h, "Thinking");
}

test "assistant paragraph and next tool keep one gap after inspected tool" {
    var h = try Harness.init(std.testing.allocator, 96, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 6);
    _ = try appendCompletedToolStatus(&h, "Inspected file");
    try h.renderTranscriptFrame();

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const inspected_row = try findRowContaining(&h, "Inspected file");
    const thinking_row = try findRowContaining(&h, "Thinking");
    try expectExactlyOneBlankRowBetween(&h, inspected_row, thinking_row);

    _ = try h.shell.streamAssistantChunk(
        h.alloc,
        &h.metrics,
        "\nassistant paragraph after inspect\nwith more detail\nand a final line",
    );
    const creating_id = try appendCompletedToolStatus(&h, "Creating project");
    try h.renderTranscriptFrameIfDirty();

    ctx.stream.active = false;
    setToolActivity(&ctx, creating_id, "Creating project");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const inspected_after = try findRowContaining(&h, "Inspected file");
    const assistant_row = try findRowContaining(&h, "assistant paragraph after inspect");
    const creating_row = try findRowContaining(&h, "Creating project");
    try expectExactlyOneBlankRowBetween(&h, inspected_after, assistant_row);
    try expectRowEmpty(&h, assistant_row + 3);
    try expectRowTrimmedEquals(&h, assistant_row + 4, "● 1 tool call · 1 read");
    try std.testing.expectEqual(assistant_row + 5, creating_row);
    try expectGridNotContains(&h, "Thinking");
}

test "thinking shimmer keeps a gap after assistant text" {
    var h = try Harness.init(std.testing.allocator, 96, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 6);
    const assistant_id = try h.shell.appendAssistantTurnEntry(h.alloc);
    const segs = h.shell.lookupAssistantSegments(assistant_id) orelse unreachable;
    try segs.text.appendSlice(h.alloc, "assistant text\n");
    try h.renderTranscriptFrame();

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const assistant_row = try findRowContaining(&h, "assistant text");
    const thinking_row = try findRowContaining(&h, "Thinking");
    try expectExactlyOneBlankRowBetween(&h, assistant_row, thinking_row);
}

test "thinking shimmer appears after bottom assistant text ending mid-row" {
    var h = try Harness.init(std.testing.allocator, 80, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(h.alloc);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "filler line {d}\n", .{i});
        defer h.alloc.free(line);
        try body.appendSlice(h.alloc, line);
    }
    try body.appendSlice(h.alloc, "final assistant tail");
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, body.items);
    try h.renderTranscriptFrame();

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const final_row = try findRowContaining(&h, "final assistant tail");
    const thinking_row = try findRowContaining(&h, "Thinking");
    try expectOnlyBlankRowsBetween(&h, final_row, thinking_row);
    const footer_row = try findFirstDividerRowAfter(&h, thinking_row);
    try expectExactlyOneBlankRowBetween(&h, thinking_row, footer_row);
}

test "thinking shimmer does not erase user row reclaimed from stale footer" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 6);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const prompt = try h.alloc.dupe(u8, "stale footer row repro");
    _ = try h.shell.appendUserTurnOwned(h.alloc, .{ .text = prompt, .images = &.{} });
    try h.renderTranscriptFrame();
    try h.flush();
    const user_row_before = try findRowContaining(&h, "stale footer row repro");

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const user_row_after = try findRowContaining(&h, "stale footer row repro");
    try std.testing.expectEqual(user_row_before, user_row_after);
    const thinking_row = try findRowContaining(&h, "Thinking");
    try std.testing.expect(thinking_row > user_row_after);
}

test "thinking shimmer reserves space when submitted user card ends at viewport bottom" {
    var h = try Harness.init(std.testing.allocator, 80, 14, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.appendRawTranscriptEntryClassified(
        h.alloc,
        "history 1\nhistory 2\nhistory 3\nhistory 4\nhistory 5\nhistory 6\nhistory 7\nhistory 8\n",
        .subagent_status,
    );
    const prompt = try h.alloc.dupe(u8, "bottom prompt");
    _ = try h.shell.appendUserTurnOwned(h.alloc, .{ .text = prompt, .images = &.{} });
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const user_row_before = try findRowContaining(&h, "bottom prompt");
    try std.testing.expectEqual(h.shell.layout.content_bottom, user_row_before);

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const user_row_after = try findRowContaining(&h, "bottom prompt");
    const thinking_row = try findRowContaining(&h, "Thinking");
    try std.testing.expectEqual(user_row_after + 2, thinking_row);
    try expectRowEmpty(&h, user_row_after + 1);
}

test "footer repaint is not skipped after transcript repaint clears footer rows" {
    var h = try Harness.init(std.testing.allocator, 80, 22, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 12);
    const body_id = try h.shell.appendRawTranscriptEntryClassified(h.alloc, "body\n", .subagent_status);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const first_footer_row = try findFirstDividerRowAfter(&h, 1);
    try expectGridContains(&h, "test-model");

    try std.testing.expect(try h.shell.updateRawBytesEntry(h.alloc, body_id, "copy\n"));
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const second_footer_row = try findFirstDividerRowAfter(&h, 1);
    try std.testing.expectEqual(first_footer_row, second_footer_row);
    try expectGridContains(&h, "test-model");
    try std.testing.expect(!h.shell.footer_viewport.externally_invalidated);
}

test "footer clean path repaints when external invalidation is set" {
    var h = try Harness.init(std.testing.allocator, 80, 22, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 12);
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, "body\n", true, .subagent_status);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    h.shell.footer_viewport.invalidateAfterExternalClear();
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(!h.shell.footer_viewport.externally_invalidated);
    try expectGridContains(&h, "test-model");
}

test "image badge stays inside user card block without extra gap" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    const text = try h.alloc.dupe(u8, "describe this [Image #1]");
    var turn_handed_off = false;
    errdefer if (!turn_handed_off) h.alloc.free(text);

    const images = try h.alloc.alloc(types.ImageAttachment, 1);
    errdefer if (!turn_handed_off) h.alloc.free(images);
    images[0] = .{
        .id = 1,
        .path = try h.alloc.dupe(u8, "/tmp/test-image.png"),
        .media_type = try h.alloc.dupe(u8, "image/png"),
    };
    errdefer if (!turn_handed_off) h.alloc.free(images[0].path);
    errdefer if (!turn_handed_off) h.alloc.free(images[0].media_type);

    const turn: types.UserTurn = .{
        .text = text,
        .images = images,
    };

    try h.shell.initViewport(&h.metrics, 10);
    _ = try h.shell.appendUserTurnOwned(h.alloc, turn);
    turn_handed_off = true;
    _ = try h.shell.appendRawTranscriptEntryClassified(h.alloc, "assistant follows\n", .subagent_status);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const prompt_row = try findRowContaining(&h, "describe this");
    const image_row = try findRowContaining(&h, "[Image 1]");
    const assistant_row = try findRowContaining(&h, "assistant follows");
    try std.testing.expectEqual(prompt_row, image_row);
    try std.testing.expect(assistant_row > prompt_row);
    try std.testing.expectEqual(prompt_row + 2, assistant_row);
    try expectRowEmpty(&h, prompt_row + 1);
    const footer_row = try findFirstDividerRowAfter(&h, assistant_row);
    try std.testing.expect(footer_row == assistant_row + 1 or footer_row == assistant_row + 2);
    if (footer_row == assistant_row + 2) try expectRowEmpty(&h, assistant_row + 1);
}

fn appendImageTurn(h: *Harness, id: usize, path: []const u8, label: []const u8) !void {
    const text = try std.fmt.allocPrint(h.alloc, "[Image #{d}] {s}", .{ id, label });
    errdefer h.alloc.free(text);
    const images = try h.alloc.alloc(types.ImageAttachment, 1);
    errdefer h.alloc.free(images);
    const image_path = try h.alloc.dupe(u8, path);
    errdefer h.alloc.free(image_path);
    const media_type = try h.alloc.dupe(u8, "image/png");
    errdefer h.alloc.free(media_type);
    images[0] = .{ .id = id, .path = image_path, .media_type = media_type };
    _ = try h.shell.appendUserTurnOwned(h.alloc, .{ .text = text, .images = images });
}

test "user card image badges keep their ids across a resize" {
    var h = try Harness.init(std.testing.allocator, 120, 36, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 10);
    try appendImageTurn(&h, 1, "/tmp/one.png", "first turn");
    try appendImageTurn(&h, 2, "/tmp/two.png", "second turn");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try expectGridContains(&h, "[Image 1] first turn");
    try expectGridContains(&h, "[Image 2] second turn");

    try h.driveResize(88, 24, 4, true);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try expectGridContains(&h, "[Image 1] first turn");
    try expectGridContains(&h, "[Image 2] second turn");
}

test "subagent background and error notices use one normalized gap each" {
    var h = try Harness.init(std.testing.allocator, 80, 26, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 8);
    _ = try h.shell.appendRawTranscriptEntryClassified(h.alloc, "subagent started\n", .subagent_status);
    _ = try h.shell.appendSemanticNotice(h.alloc, .{
        .topic = "background",
        .tone = .success,
        .body = "background task ready",
    });
    _ = try h.shell.appendSemanticNotice(h.alloc, .{
        .topic = "system",
        .tone = .@"error",
        .body = "HTTP 500: failed",
    });
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, "assistant recovered");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const subagent = try findRowContaining(&h, "subagent started");
    const background = try findRowContaining(&h, "background task ready");
    const error_row = try findRowContaining(&h, "HTTP 500");
    const assistant = try findRowContaining(&h, "assistant recovered");

    try expectExactlyOneBlankRowBetween(&h, subagent, background);
    try expectExactlyOneBlankRowBetween(&h, background, error_row);
    try expectExactlyOneBlankRowBetween(&h, error_row, assistant);
}

test "subagent result keeps one blank row before idle footer" {
    var h = try Harness.init(std.testing.allocator, 80, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 4);
    _ = try h.shell.appendRawTranscriptEntryClassified(
        h.alloc,
        "\x1b[2m  │ subagent done | reviewed files\n\x1b[0m",
        .subagent_status,
    );
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const result_row = try findRowContaining(&h, "subagent done");
    const footer_row = try findFirstDividerRowAfter(&h, result_row);
    try expectExactlyOneBlankRowBetween(&h, result_row, footer_row);
}

test "completed subagent tool status keeps one blank row before idle footer" {
    var h = try Harness.init(std.testing.allocator, 96, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 4);
    _ = try appendCompletedToolStatus(&h, "Ran subagent: Verify 3d-world-10 code correctness");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const result_row = try findRowContaining(&h, "Ran subagent:");
    const footer_row = try findFirstDividerRowAfter(&h, result_row);
    try expectExactlyOneBlankRowBetween(&h, result_row, footer_row);
}

test "subagent status sequence stays contiguous before idle footer" {
    var h = try Harness.init(std.testing.allocator, 80, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 4);
    _ = try h.shell.appendRawTranscriptEntryClassified(
        h.alloc,
        "\x1b[2m  │ subagent started | Explore existing 3d-world projects\n\x1b[0m",
        .subagent_status,
    );
    _ = try h.shell.appendRawTranscriptEntryClassified(
        h.alloc,
        "\x1b[2m  │ subagent | 1 tools | Listing 3d-world\n\x1b[0m",
        .subagent_status,
    );
    _ = try h.shell.appendRawTranscriptEntryClassified(
        h.alloc,
        "\x1b[2m  │ subagent done | 3 tools | 4s | Found existing examples.\n\x1b[0m",
        .subagent_status,
    );
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const started_row = try findRowContaining(&h, "subagent started");
    const progress_row = try findRowContaining(&h, "Listing 3d-world");
    const done_row = try findRowContaining(&h, "subagent done");
    const footer_row = try findFirstDividerRowAfter(&h, done_row);

    try std.testing.expectEqual(started_row + 1, progress_row);
    try std.testing.expectEqual(progress_row + 1, done_row);
    try expectExactlyOneBlankRowBetween(&h, done_row, footer_row);
}

test "cancel notice keeps one blank row before idle footer" {
    var h = try Harness.init(std.testing.allocator, 80, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 4);
    _ = try h.shell.appendRawTranscriptEntryClassified(h.alloc, "before cancel\n", .subagent_status);
    _ = try h.shell.appendRawTranscriptEntryClassified(h.alloc, "\x1b[2mcancelled\x1b[0m\n", .question_resolution);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const before_row = try findRowContaining(&h, "before cancel");
    const cancel_row = try findRowContaining(&h, "cancelled");
    const footer_row = try findFirstDividerRowAfter(&h, cancel_row);
    try expectExactlyOneBlankRowBetween(&h, before_row, cancel_row);
    try expectExactlyOneBlankRowBetween(&h, cancel_row, footer_row);
}

test "settled cancel projection keeps the retained transcript aligned with the footer" {
    var h = try Harness.init(std.testing.allocator, 125, 37, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.appendRawTranscriptEntryClassified(
        h.alloc,
        "line 01\nline 02\nline 03\nline 04\nline 05\nline 06\nline 07\n" ++
            "line 08\nline 09\nline 10\nline 11\nline 12\nline 13\nline 14\n" ++
            "line 15\nline 16\nline 17\nline 18\nline 19\nline 20\nline 21\n" ++
            "line 22\nline 23\nline 24\nline 25\nline 26\nline 27\nline 28\n" ++
            "line 29\nline 30\nline 31\nline 32\nline 33\nline 34\n",
        .subagent_status,
    );
    try input.textReplacementState().replace(h.alloc, "/");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    _ = try h.shell.appendRawTranscriptEntryClassified(
        h.alloc,
        "cancelled\n",
        .question_resolution,
    );
    input.picker.dismissInlinePicker(.slash);
    input.inputResetState().clearCurrent(h.alloc);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const cancel_row = try findRowContaining(&h, "cancelled");
    const initial_footer_row = try findFirstDividerRowAfter(&h, cancel_row);
    try expectExactlyOneBlankRowBetween(&h, cancel_row, initial_footer_row);

    h.shell.render_requests.request(.footer);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const settled_footer_row = try findFirstDividerRowAfter(&h, cancel_row);
    try std.testing.expectEqual(TestBodyDisposition.retain, h.last_frame.body_disposition);
    try std.testing.expectEqual(initial_footer_row, settled_footer_row);
    try expectExactlyOneBlankRowBetween(&h, cancel_row, settled_footer_row);
}

test "question prompt footer state does not mutate transcript gaps" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 10);
    _ = try h.shell.appendSemanticNotice(h.alloc, .{
        .topic = "system",
        .tone = .information,
        .body = "before question",
    });
    _ = try h.shell.appendSemanticNotice(h.alloc, .{
        .topic = "system",
        .tone = .information,
        .body = "after question",
    });
    try h.renderTranscriptFrame();

    var ctx = defaultFooterContext(&input);
    ctx.question = .{
        .current_entry = null,
        .current_index = 0,
        .entry_count = 0,
    };
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const before = try findRowContaining(&h, "before question");
    const after = try findRowContaining(&h, "after question");
    try expectExactlyOneBlankRowBetween(&h, before, after);

    ctx.question = null;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const before_after_clear = try findRowContaining(&h, "before question");
    const after_after_clear = try findRowContaining(&h, "after question");
    try expectExactlyOneBlankRowBetween(&h, before_after_clear, after_after_clear);
}

test "question modal replays displaced transcript rows into history" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 100, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    var question = question_prompt.QuestionPrompt{};
    defer question.deinit(alloc);

    const options = [_]types.QuestionOption{
        .{ .label = "Stop here", .description = "End the inspection." },
        .{ .label = "Trace deeper", .description = "Read the surrounding runtime." },
        .{ .label = "Run tests", .description = "Exercise the focused regressions." },
        .{ .label = "Summarize", .description = "Report the findings." },
    };
    const entries = [_]types.QuestionBatchEntry{.{
        .question = "How should the inspection proceed?",
        .options = &options,
    }};
    try question.syncFrom(alloc, &entries);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.streamAssistantChunk(
        alloc,
        &h.metrics,
        "question context 01\nquestion context 02\nquestion context 03\nquestion context 04\n" ++
            "question context 05\nquestion context 06\nquestion context 07\nquestion context 08\n" ++
            "question context 09\nquestion context 10\nquestion context 11\nquestion context 12\n" ++
            "question context 13\nquestion context 14\nquestion context 15\nquestion context 16\n" ++
            "question context 17\nquestion context 18\nquestion context 19\nquestion context 20\n" ++
            "question context 21\nquestion context 22\nquestion context 23\nquestion context 24\n",
    );
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    var ctx = defaultFooterContext(&input);
    ctx.question = question.projection();
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const displaced_rows = h.last_frame.planned_scroll_rows;
    try std.testing.expect(displaced_rows > 0);
    try std.testing.expectEqual(displaced_rows, h.last_frame.committed_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expect(h.last_frame.document_append_bytes > 0);
    try std.testing.expectEqual(
        @as(?u16, displaced_rows),
        h.last_frame.document_append_clear_rows,
    );
    try expectGridContains(&h, "question context 24");
    try expectGridContains(&h, "How should the inspection proceed?");
}

test "resized question cancellation keeps the idle footer bottom anchored" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 120, 36, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    var question = question_prompt.QuestionPrompt{};
    defer question.deinit(alloc);

    const options = [_]types.QuestionOption{
        .{ .label = "Alpha" },
        .{ .label = "Beta" },
    };
    const entries = [_]types.QuestionBatchEntry{.{
        .question = "Which harmless label do you prefer?",
        .options = &options,
    }};
    try question.syncFrom(alloc, &entries);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.appendRawTranscriptEntry(
        alloc,
        "QUESTION_ANCHOR_01\nQUESTION_ANCHOR_02\nQUESTION_ANCHOR_03\n" ++
            "QUESTION_ANCHOR_04\nQUESTION_ANCHOR_05\nQUESTION_ANCHOR_06\n" ++
            "QUESTION_ANCHOR_07\nQUESTION_ANCHOR_08\nQUESTION_ANCHOR_09\n",
    );

    var ctx = defaultFooterContext(&input);
    ctx.question = question.projection();
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    try h.vt.resize(60, 12);
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(60, 12, 4),
        true,
    );
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    _ = try h.shell.appendReplaceableTranscriptLineClassified(
        alloc,
        &h.metrics,
        "\x1b[2m■ Cancelled\x1b[0m\n",
        .question_resolution,
    );
    question.discard(alloc, "test_cleanup");
    ctx.question = null;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    h.shell.render_requests.requestInvalidation(.{
        .reason = .external_clear,
        .top = h.shell.committed_frame_layout.transcript_area.top,
        .bottom = h.shell.layout.rows,
    });
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const cancelled_row = try findRowContaining(&h, "■ Cancelled");
    const footer_row = try findFirstDividerRowAfter(&h, cancelled_row);
    try expectExactlyOneBlankRowBetween(&h, cancelled_row, footer_row);
    try std.testing.expectEqual(
        h.shell.layout.rows,
        h.shell.committed_frame_layout.footer_area.bottom,
    );
    const footer_before_edit = h.shell.committed_frame_layout.footer_area;

    try input.insertionState().insertByte(alloc, 'x', .clear);
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    try std.testing.expectEqual(
        footer_before_edit,
        h.shell.committed_frame_layout.footer_area,
    );
    try std.testing.expect(h.last_frame.transcript_history_floor_respected);
}

test "live command output chunks remain one block outside the compact transcript" {
    var h = try Harness.init(std.testing.allocator, 80, 26, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 8);
    try h.shell.writeCommandOutputChunk(h.alloc, &h.metrics, commandOutputStyles(), .stdout, "one\n", true);
    try h.shell.writeCommandOutputChunk(h.alloc, &h.metrics, commandOutputStyles(), .stdout, "two\n", true);
    try h.shell.flushCommandOutputSummary(h.alloc, &h.metrics, commandOutputStyles(), true);
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, "assistant after command");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    _ = try findRowContaining(&h, "assistant after command");
    try expectGridNotContains(&h, "│ one");
    try expectGridNotContains(&h, "│ two");
    try std.testing.expectEqual(@as(usize, 1), h.shell.command_output_blocks.items.len);
    try std.testing.expectEqualStrings("one", h.shell.command_output_blocks.items[0].lines.items[0].text);
    try std.testing.expectEqualStrings("two", h.shell.command_output_blocks.items[0].lines.items[1].text);
}

test "structured command-output rewrite materializes committed transcript scroll rows" {
    var h = try Harness.init(std.testing.allocator, 80, 12, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);
    const prompt = try h.alloc.dupe(u8, "give me a table of my system information");
    _ = try h.shell.appendUserTurnOwned(h.alloc, .{
        .text = prompt,
        .images = &.{},
    });

    for (0..18) |index| {
        var line: [48]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "SYSTEM OUTPUT {d:0>2}\\n", .{index + 1});
        const bytes = try h.alloc.dupe(u8, text);
        _ = try h.shell.appendRawBytesEntryClassified(
            h.alloc,
            bytes,
            .unknown_raw,
        );
    }

    const first_assistant_id = try h.shell.appendAssistantTurnEntry(h.alloc);
    const first_assistant = h.shell.lookupAssistantSegments(first_assistant_id) orelse
        return error.TestExpectedAssistantSegments;
    for (0..24) |index| {
        var line: [48]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "assistant table row {d}\n", .{index + 1});
        try first_assistant.text.appendSlice(h.alloc, text);
    }
    // Assistant content is complete before each frame; report producer
    // closure so the finality floor does not hold the tail.
    h.shell.transcript_release = h.shell.transcript_release.with_assistant_tail_writable(false);

    try h.renderTranscriptFrame();
    try h.flush();
    try std.testing.expectEqual(transcript_runtime.TranscriptCommitDiagnosticState.stable, h.shell.transcriptCommitDiagnostic().state);

    var follow_up: std.Io.Writer.Allocating = .init(h.alloc);
    defer follow_up.deinit();
    for (0..60) |index| {
        try follow_up.writer.print("follow-up retained row {d}\n", .{index + 1});
    }
    const retained_before = h.shell.retainedStructuredBytesForCommandOutput();
    h.shell.max_retained_transcript_bytes = retained_before + follow_up.written().len / 2;
    {
        var block = assistant_presentation.CodeBlockPayload{
            .language = try h.alloc.dupe(u8, "zig"),
            .code = try h.alloc.dupe(u8, "const retained_boundary = true;\n"),
        };
        errdefer block.deinit(h.alloc);
        _ = try h.shell.appendAssistantCodeBlockOwned(h.alloc, block);
    }
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, follow_up.written());
    try std.testing.expect(
        h.shell.retainedStructuredBytesForCommandOutput() <=
            h.shell.max_retained_transcript_bytes,
    );
    var retained_source = try h.shell.prepareTranscriptSource(h.alloc, null);
    defer retained_source.deinit(h.alloc);
    try std.testing.expect(std.mem.find(
        u8,
        retained_source.bytes,
        "SYSTEM OUTPUT 02",
    ) == null);

    try h.renderTranscriptFrame();
    try h.flush();
    // The retention rewrite is byte-incompatible with the committed anchor.
    // This frame re-anchors in place and records same-epoch recovery debt.
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    const held_diagnostic = h.shell.transcriptCommitDiagnostic();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        held_diagnostic.state,
    );
    switch (h.shell.transcript_commit_state) {
        .stable => |anchor| try std.testing.expect(anchor.normal_buffer_recovery_pending),
        .invalid, .recovering => return error.TestExpectedStableTranscript,
    }

    // The following compatible frame settles the held rows with final bytes.
    try h.renderTranscriptFrame();
    try h.flush();
    try std.testing.expect(h.last_frame.planned_scroll_rows > 0);
    try std.testing.expectEqual(
        h.last_frame.planned_scroll_rows,
        h.last_frame.committed_scroll_rows,
    );
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    switch (h.shell.transcript_commit_state) {
        .stable => |anchor| try std.testing.expect(!anchor.normal_buffer_recovery_pending),
        .invalid, .recovering => return error.TestExpectedStableTranscript,
    }
}

fn applyCompletedReadForGroupFinalityResizeTest(
    h: *Harness,
    turn_id: u64,
    call_id: []const u8,
    group_id: types.ToolPresentationGroupId,
) !void {
    const id = types.ToolLifecycleId{ .turn_id = turn_id, .call_id = call_id };
    _ = try h.shell.applyToolLifecycle(h.alloc, .{ .authoritative_started = .{
        .id = id,
        .presentation_group_id = group_id,
        .reconciles_provisional_call_id = null,
        .tool_name = "read_file",
        .activity_kind = .read,
    } });
    _ = try h.shell.applyToolLifecycle(h.alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Read fixed-point fixture" },
    } });
}

test "closed tool group finality flows through fixed point resolution and sealing" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 14, 3);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 8);
    for (0..4) |index| {
        var line: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "startup row {d}\n", .{index});
        _ = try h.shell.appendRawTranscriptEntry(alloc, text);
    }
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const group_a = types.ToolPresentationGroupId{ .turn_id = 92, .anchor_step_id = 1 };
    var group_a_call_ids: [18][20]u8 = undefined;
    for (0..group_a_call_ids.len) |index| {
        const call_id = try std.fmt.bufPrint(
            &group_a_call_ids[index],
            "fixed-a-{d:0>2}",
            .{index},
        );
        try applyCompletedReadForGroupFinalityResizeTest(&h, 92, call_id, group_a);
    }
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    var held_source = try h.shell.prepareTranscriptSource(alloc, null);
    defer held_source.deinit(alloc);
    const held = h.shell.stableTranscriptProjectionForFlow(held_source.bytes) orelse
        return error.TestExpectedStableTranscript;
    try std.testing.expect(held.visual_offset > held.history_visual_offset);

    _ = try h.shell.appendRawTranscriptEntry(alloc, "SECOND_GROUP_INTRO\n");
    const group_b = types.ToolPresentationGroupId{ .turn_id = 92, .anchor_step_id = 2 };
    try applyCompletedReadForGroupFinalityResizeTest(&h, 92, "fixed-b-1", group_b);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(h.last_frame.planned_scroll_rows > 0);
    try std.testing.expect(h.last_frame.committed_scroll_rows > 0);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);

    var released_source = try h.shell.prepareTranscriptSource(alloc, null);
    defer released_source.deinit(alloc);
    const released = h.shell.stableTranscriptProjectionForFlow(released_source.bytes) orelse
        return error.TestExpectedStableTranscript;
    try std.testing.expect(released.history_visual_offset > held.history_visual_offset);
    try std.testing.expect(released.visual_offset >= released.history_visual_offset);
    try expectGridContains(&h, "SECOND_GROUP_INTRO");
}

test "hidden auto approval lifecycle reposition adds no compact scroll rows" {
    var h = try Harness.init(std.testing.allocator, 80, 12, 4);
    defer h.deinit();

    h.shell.max_transcript_bytes = 64;
    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscriptClassified(
        h.alloc,
        &h.metrics,
        "TRANSCRIPT MARKER 01\n" ++
            "TRANSCRIPT MARKER 02\n" ++
            "TRANSCRIPT MARKER 03\n" ++
            "TRANSCRIPT MARKER 04\n" ++
            "TRANSCRIPT MARKER 05\n" ++
            "TRANSCRIPT MARKER 06\n" ++
            "TRANSCRIPT MARKER 07\n" ++
            "TRANSCRIPT MARKER 08\n" ++
            "TRANSCRIPT MARKER 09\n" ++
            "TRANSCRIPT MARKER 10\n" ++
            "TRANSCRIPT MARKER 11\n" ++
            "TRANSCRIPT MARKER 12\n",
        true,
        .subagent_status,
    );
    try h.renderTranscriptFrame();
    try h.flush();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        h.shell.transcriptCommitDiagnostic().state,
    );
    var committed_source = try h.shell.prepareTranscriptSource(h.alloc, null);
    defer committed_source.deinit(h.alloc);
    try std.testing.expect(committed_source.bytes.len > h.shell.transcript.items.len);

    const id = types.ToolLifecycleId{
        .turn_id = 91,
        .call_id = "coalesced-command",
    };
    _ = try h.shell.applyToolLifecycle(h.alloc, .{ .provisional = .{
        .id = id,
        .tool_name = "run_command",
        .activity_kind = .command,
    } });
    _ = try h.shell.appendSemanticNotice(h.alloc, .{
        .topic = "permissions",
        .tone = .success,
        .body = "Auto agent approved this request: Running command.",
        .visibility = .full_only,
    });
    _ = try h.shell.applyToolLifecycle(h.alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"seq 1 1\"}",
        .place_after_current_transcript = true,
    } });
    const status_entry_id = h.shell.toolActivityRecord(id).?.entry_id;
    var canonical_source = try h.shell.prepareTranscriptSource(h.alloc, null);
    defer canonical_source.deinit(h.alloc);
    try std.testing.expect(std.mem.find(u8, canonical_source.bytes, "Auto agent approved") == null);
    try std.testing.expect(std.mem.find(
        u8,
        canonical_source.bytes,
        "run_command",
    ) != null);

    var projection = try h.shell.buildFullTranscriptProjection(h.alloc, null);
    defer projection.deinit(h.alloc);
    const full_source = try full_transcript_screen.renderProjectionViewportSourceInterruptible(
        h.alloc,
        &projection,
        null,
        h.shell.layout.cols,
        64,
        0,
        null,
    );
    defer h.alloc.free(full_source);
    const notice_index = std.mem.find(u8, full_source, "Auto agent approved") orelse
        return error.TestExpectedEqual;
    const status_index = std.mem.find(u8, full_source, "run_command") orelse
        return error.TestExpectedEqual;
    try std.testing.expect(notice_index < status_index);

    try h.renderTranscriptFrameOmittingEntry(status_entry_id);
    try h.flush();

    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        h.shell.transcriptCommitDiagnostic().state,
    );
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.committed_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try expectGridNotContains(&h, "Auto agent approved");
    try expectGridNotContains(&h, "run_command");
}

test "completed replay tool entries fit a constrained terminal" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 4);
    _ = try appendCompletedToolStatus(&h, "Ran pwd");
    try h.shell.writeCommandOutputChunk(
        h.alloc,
        &h.metrics,
        commandOutputStyles(),
        .stdout,
        "/workspace\n",
        true,
    );
    try h.shell.flushCommandOutputSummary(
        h.alloc,
        &h.metrics,
        commandOutputStyles(),
        true,
    );
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, "TOOL_REPLAY_FINISHED");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try expectGridContains(&h, "Ran pwd");
    try expectGridNotContains(&h, "/workspace");
    try expectGridContains(&h, "TOOL_REPLAY_FINISHED");
    try std.testing.expect(h.shell.last_visible_transcript_last_row <= h.shell.layout.rows);

    try std.testing.expect(try h.shell.setTranscriptPresentationDepth(h.alloc, .review));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try expectGridContains(&h, "/workspace");
}

test "long live command output keeps running tool visible with stable footer" {
    var h = try Harness.init(std.testing.allocator, 80, 14, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    const prompt = try h.alloc.dupe(u8, "run the streaming command");
    _ = try h.shell.appendUserTurnOwned(h.alloc, .{ .text = prompt, .images = &.{} });
    const status_id = try appendCompletedToolStatus(&h, "Running python stream");

    var line_index: usize = 1;
    while (line_index <= 18) : (line_index += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "line-{d}\n", .{line_index});
        defer h.alloc.free(line);
        try h.shell.writeCommandOutputChunk(h.alloc, &h.metrics, commandOutputAnsiStyles(), .stdout, line, true);
    }

    var ctx = defaultFooterContext(&input);
    ctx.stream = .{ .active = true, .command_count = 1, .last_activity_kind = .command };
    setToolActivity(&ctx, status_id, "Running python stream");
    ctx.activity.tool_slot.kind = .command;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    try expectGridContains(&h, "Thinking");
    try expectGridOccurrenceCount(&h, "Running python stream", 1);
    _ = try findRowContaining(&h, "Running python stream");
    try expectGridNotContains(&h, "line-2");
    const footer_after_first_batch = try findFirstDividerRowAfter(&h, 1);

    while (line_index <= 30) : (line_index += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "line-{d}\n", .{line_index});
        defer h.alloc.free(line);
        try h.shell.writeCommandOutputChunk(h.alloc, &h.metrics, commandOutputAnsiStyles(), .stdout, line, true);
    }

    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    try expectGridContains(&h, "Thinking");
    try expectGridOccurrenceCount(&h, "Running python stream", 1);
    const footer_after_second_batch = try findFirstDividerRowAfter(&h, 1);
    try std.testing.expectEqual(footer_after_first_batch, footer_after_second_batch);
}

test "resize keeps transcript-owned active command above output and thinking" {
    var h = try Harness.init(std.testing.allocator, 80, 14, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    const prompt = try h.alloc.dupe(u8, "resize the active tool");
    _ = try h.shell.appendUserTurnOwned(h.alloc, .{ .text = prompt, .images = &.{} });
    const status_id = try appendCompletedToolStatus(&h, "Resize activity active");
    var line_index: usize = 1;
    while (line_index <= 18) : (line_index += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "resize-line-{d}\n", .{line_index});
        defer h.alloc.free(line);
        try h.shell.writeCommandOutputChunk(
            h.alloc,
            &h.metrics,
            commandOutputAnsiStyles(),
            .stdout,
            line,
            true,
        );
    }

    var ctx = defaultFooterContext(&input);
    ctx.stream = .{
        .active = true,
        .command_count = 1,
        .last_activity_kind = .command,
    };
    setToolActivity(&ctx, status_id, "Resize activity active");
    ctx.activity.tool_slot.kind = .command;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    try expectGridOccurrenceCount(&h, "Thinking", 1);
    try expectGridOccurrenceCount(&h, "Resize activity active", 1);
    const status_row = try findRowContaining(&h, "Resize activity active");
    const thinking_row = try findRowContaining(&h, "Thinking");
    try std.testing.expect(status_row < thinking_row);
    try expectGridNotContains(&h, "resize-line-2");
    try std.testing.expect(h.shell.shimmer_active);
    try std.testing.expect(!h.shell.shimmer_is_overlay);

    try h.driveResize(80, 40, 4, true);
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const resized_status_row = try findRowContaining(&h, "Resize activity active");
    const resized_thinking_row = try findRowContaining(&h, "Thinking");
    try std.testing.expect(resized_status_row < resized_thinking_row);
    try expectGridNotContains(&h, "resize-line-1");
    try expectGridOccurrenceCount(&h, "Thinking", 1);
    try expectGridOccurrenceCount(&h, "Resize activity active", 1);
    try std.testing.expect(h.shell.shimmer_active);
    try std.testing.expect(!h.shell.shimmer_is_overlay);
}

test "resize preserves normalized gaps across mixed block types" {
    var h = try Harness.init(std.testing.allocator, 100, 30, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 8);
    _ = try appendCompletedToolStatus(&h, "tool done");
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, "assistant response with enough words to wrap when the terminal gets narrow");
    _ = try h.shell.appendRawTranscriptEntryClassified(h.alloc, "system notice\n", .subagent_status);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try h.driveResize(50, 24, 4, true);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const tool = try findRowContaining(&h, "tool done");
    const assistant = try findRowContaining(&h, "assistant response");
    const notice = try findRowContaining(&h, "system notice");

    try std.testing.expect(assistant > tool);
    try std.testing.expect(notice > assistant);
    try expectExactlyOneBlankRowBetween(&h, tool, assistant);
}

test "bottom assistant line ending mid-row keeps one blank row before footer" {
    var h = try Harness.init(std.testing.allocator, 80, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(h.alloc);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "filler line {d}\n", .{i});
        defer h.alloc.free(line);
        try body.appendSlice(h.alloc, line);
    }
    try body.appendSlice(h.alloc, "final assistant tail");
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, body.items);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const final_row = try findRowContaining(&h, "final assistant tail");
    const footer_row = try findFirstDividerRowAfter(&h, final_row);
    try expectAtLeastOneBlankRowBetween(&h, final_row, footer_row);
}

test "approval banner keeps one blank row after bottom assistant line" {
    var h = try Harness.init(std.testing.allocator, 80, 30, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(h.alloc);
    var i: usize = 0;
    while (i < 14) : (i += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "filler line {d}\n", .{i});
        defer h.alloc.free(line);
        try body.appendSlice(h.alloc, line);
    }
    try body.appendSlice(h.alloc, "final assistant tail");
    _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, body.items);
    _ = try approval.syncRequest(h.alloc, .{ .label = "open_file" });
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const final_row = try findRowContaining(&h, "final assistant tail");
    const footer_row = try findFirstDividerRowAfter(&h, final_row);
    try expectAtLeastOneBlankRowBetween(&h, final_row, footer_row);
    try expectGridContains(&h, "Would you like to allow this action?");
}

test "approval banner frames prompt after completed tool status" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(h.alloc);
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "filler line {d}\n", .{i});
        defer h.alloc.free(line);
        try body.appendSlice(h.alloc, line);
    }
    _ = try h.shell.appendRawTranscriptEntryClassified(h.alloc, body.items, .subagent_status);
    _ = try appendCompletedToolStatus(&h, "Listed project");
    _ = try approval.syncRequest(h.alloc, .{ .label = "open_file" });
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const status_row = try findRowContaining(&h, "Listed project");
    const top_divider_row = try findFirstDividerRowAfter(&h, status_row);
    const header_row = try findRowContaining(&h, "Permission needed · Choose one");
    const question_row = try findRowContaining(&h, "Would you like to allow this action?");
    const reason_row = try findRowContaining(&h, "Reason:");
    try expectExactlyOneBlankRowBetween(&h, status_row, top_divider_row);
    try std.testing.expectEqual(top_divider_row + 1, header_row);
    try std.testing.expectEqual(top_divider_row + 2, question_row);
    try std.testing.expectEqual(question_row + 1, reason_row);
    try expectGridContains(&h, "1. Yes");
    try expectGridContains(&h, "2. Yes, and don't ask again");
    try expectGridContains(&h, "3. No");
}

test "welcome logo stays pinned while middle transcript rows overflow" {
    var h = try Harness.init(std.testing.allocator, 96, 43, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewportWithReservedRows(&h.metrics, 6, ui_render.welcome_message_reserved_rows);
    const welcome = try ui_render.welcomeMessage(h.alloc);
    defer h.alloc.free(welcome);
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, welcome, true, .welcome);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(h.alloc);
    var i: usize = 0;
    while (i < 45) : (i += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "content line {d}\n", .{i});
        defer h.alloc.free(line);
        try body.appendSlice(h.alloc, line);
    }
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, body.items, true, .subagent_status);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try expectGridContains(&h, "Run /help for commands");
    try expectGridContains(&h, "𝒇x v");
    try expectGridNotContains(&h, "content line 0");
    try expectGridContains(&h, "content line 44");
}

test "welcome logo stays pinned during footer-reserved overflow" {
    var h = try Harness.init(std.testing.allocator, 96, 43, 4);
    defer h.deinit();

    try h.shell.initViewportWithReservedRows(&h.metrics, 6, ui_render.welcome_message_reserved_rows);
    const welcome = try ui_render.welcomeMessage(h.alloc);
    defer h.alloc.free(welcome);
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, welcome, true, .welcome);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(h.alloc);
    var i: usize = 0;
    while (i < 45) : (i += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "content line {d}\n", .{i});
        defer h.alloc.free(line);
        try body.appendSlice(h.alloc, line);
    }
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, body.items, true, .subagent_status);

    try h.renderTranscriptFrameWithBottomReservation(3);
    try h.flush();

    try std.testing.expect(h.shell.last_visible_transcript_split_active);
    try std.testing.expect(h.shell.last_visible_transcript_split_suffix_start_line > h.shell.last_visible_transcript_split_prefix_lines);
    try expectGridContains(&h, "𝒇x v");
    try expectGridContains(&h, "Run /help for commands");
    try expectGridNotContains(&h, "content line 0");
    try expectGridContains(&h, "content line 44");
}

test "welcome pinning does not hide submitted user prompt" {
    var h = try Harness.init(std.testing.allocator, 82, 47, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewportWithReservedRows(&h.metrics, 10, ui_render.welcome_message_reserved_rows);
    const welcome = try ui_render.welcomeMessage(h.alloc);
    defer h.alloc.free(welcome);
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, welcome, true, .welcome);

    const prompt = try h.alloc.dupe(u8, "PLEASE KEEP THIS PROMPT VISIBLE");
    _ = try h.shell.appendUserTurnOwned(h.alloc, .{ .text = prompt, .images = &.{} });

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(h.alloc);
    var i: usize = 0;
    while (i < 28) : (i += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "assistant tail line {d}\n", .{i});
        defer h.alloc.free(line);
        try body.appendSlice(h.alloc, line);
    }
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, body.items, true, .subagent_status);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(!h.shell.last_visible_transcript_split_active);
    try expectGridContains(&h, "PLEASE KEEP THIS PROMPT VISIBLE");
    try expectGridContains(&h, "assistant tail line 27");
}

test "render engine preserves transcript footer activity behavior" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 96, 43, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewportWithReservedRows(&h.metrics, 6, ui_render.welcome_message_reserved_rows);
    const welcome = try ui_render.welcomeMessage(alloc);
    defer alloc.free(welcome);
    try h.shell.writeTranscriptClassified(alloc, &h.metrics, welcome, true, .welcome);

    _ = try appendCompletedToolStatus(&h, "Listed src/ui");
    _ = try h.shell.streamAssistantChunk(alloc, &h.metrics, "The renderer should preserve exactly one paragraph gap after tools.");
    _ = try appendCompletedToolStatus(&h, "Ran subagent: Verify render behavior");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const welcome_row = try findRowContaining(&h, "Run /help");
    const tool_row = try findRowContaining(&h, "Listed src/ui");
    const assistant_row = try findRowContaining(&h, "preserve exactly one paragraph gap");
    const subagent_row = try findRowContaining(&h, "Ran subagent:");
    const idle_footer_row = try findFirstDividerRowAfter(&h, subagent_row);

    try std.testing.expect(welcome_row >= h.shell.viewport_top_row);
    try std.testing.expect(tool_row < assistant_row);
    try std.testing.expect(assistant_row < subagent_row);
    try expectExactlyOneBlankRowBetween(&h, subagent_row, idle_footer_row);
    try std.testing.expect(h.shell.last_visible_transcript_last_row >= subagent_row);
    try std.testing.expect(h.shell.last_visible_transcript_last_row <= h.shell.layout.content_bottom);

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    const cursor_reserved_rows: u16 = if (h.shell.cursor_col == 1) 1 else 2;
    const expected_thinking_reserved_rows = h.shell.transientAssistantGapRows() +| cursor_reserved_rows;
    const idle_gap_rows = h.shell.idleFooterGapOffset();
    const expected_thinking_footer_delta = if (expected_thinking_reserved_rows > idle_gap_rows)
        expected_thinking_reserved_rows - idle_gap_rows
    else
        0;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    const thinking_row = try findRowContaining(&h, "Thinking");
    const thinking_footer_row = try findFirstDividerRowAfter(&h, thinking_row);
    try std.testing.expect(expected_thinking_footer_delta > 0);
    try std.testing.expectEqual(idle_footer_row + expected_thinking_footer_delta, thinking_footer_row);
    try std.testing.expect(thinking_row < thinking_footer_row);

    ctx.stream.active = false;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    try expectGridNotContains(&h, "Thinking");
    const restored_footer_row = try findFirstDividerRowAfter(&h, subagent_row);
    try std.testing.expectEqual(idle_footer_row, restored_footer_row);

    const non_empty_rows = try firstNonEmptyRows(&h, alloc);
    defer alloc.free(non_empty_rows);
    for (non_empty_rows) |row| {
        try std.testing.expect(row >= h.shell.viewport_top_row);
    }

    var filler: std.ArrayList(u8) = .empty;
    defer filler.deinit(alloc);
    var filler_line: usize = 0;
    while (filler_line < 45) : (filler_line += 1) {
        const line = try std.fmt.allocPrint(alloc, "overflow filler line {d}\n", .{filler_line});
        defer alloc.free(line);
        try filler.appendSlice(alloc, line);
    }
    try h.shell.writeTranscriptClassified(alloc, &h.metrics, filler.items, true, .subagent_status);

    _ = try h.shell.appendRawTranscriptEntryClassified(alloc, "\x1b[2m  │ subagent done | checked rendering\n\x1b[0m", .subagent_status);

    const status_id = try appendCompletedToolStatus(&h, "Writing render-engine-plan");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const status_only_row = try findRowContaining(&h, "Writing render-engine-plan");
    const status_only_footer_row = try findFirstDividerRowAfter(&h, status_only_row);

    try std.testing.expect(!h.shell.last_visible_transcript_split_active);
    try expectGridNotContains(&h, "overflow filler line 0");
    try expectGridContains(&h, "overflow filler line 44");
    try expectExactlyOneBlankRowBetween(&h, status_only_row, status_only_footer_row);

    try h.shell.writeCommandOutputChunk(
        alloc,
        &h.metrics,
        commandOutputStyles(),
        .stdout,
        "line one\n",
        true,
    );
    try h.shell.writeCommandOutputChunk(
        alloc,
        &h.metrics,
        commandOutputStyles(),
        .stdout,
        "line two\n",
        true,
    );
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const subagent_done_row = try findRowContaining(&h, "subagent done");
    const status_row = try findRowContaining(&h, "Writing render-engine-plan");
    const footer_row = try findFirstDividerRowAfter(&h, status_row);

    try std.testing.expect(subagent_done_row < status_row);
    try expectGridNotContains(&h, "│ line one");
    try expectGridNotContains(&h, "│ line two");
    try std.testing.expect(status_row < footer_row);
    try std.testing.expect(!h.shell.last_visible_transcript_split_active);

    ctx = defaultFooterContext(&input);
    setToolActivity(&ctx, status_id, "Overlay writing render-engine-plan");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    try std.testing.expect(!h.shell.shimmer_active);
    try expectGridNotContains(&h, "Overlay writing render-engine-plan");
    try std.testing.expectEqual(status_row, try findRowContaining(&h, "Writing render-engine-plan"));

    ctx.queued_count = 1;
    setToolActivity(&ctx, status_id, "Overlay hidden by banner");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    try expectGridNotContains(&h, "Overlay hidden by banner");
    try expectGridNotContains(&h, "Overlay writing render-engine-plan");
    try std.testing.expect(!h.shell.shimmer_active);
    const restored_status_row = try findRowContaining(&h, "Writing render-engine-plan");
    const banner_row = try findRowContaining(&h, "1 queued message");
    try expectGridNotContains(&h, "│ line two");
    try std.testing.expect(restored_status_row < banner_row);
    try std.testing.expect(banner_row < h.shell.layout.rows);

    try h.driveResize(72, 24, 4, false);
    try h.driveResize(96, 43, 4, true);
    try h.renderTranscriptFrame();
    h.frame_redraw = true;
    ctx = defaultFooterContext(&input);
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    try std.testing.expect(h.shell.cursor_row >= h.shell.viewport_top_row);
    try std.testing.expect(h.shell.cursor_row <= h.shell.layout.rows);
    try std.testing.expect(h.shell.cursor_col >= 1);
    try std.testing.expect(h.shell.cursor_col <= h.shell.layout.cols);
    try std.testing.expect(h.shell.last_visible_transcript_last_row <= h.shell.layout.rows);
}

test "runtime decomposition preserves command output state and replaceable paint state" {
    var h = try Harness.init(std.testing.allocator, 96, 36, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 4);
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, "header\n", true, .subagent_status);
    try h.shell.writeCommandOutputChunk(h.alloc, &h.metrics, commandOutputStyles(), .stdout, "visible\n", true);
    try h.shell.writeCommandOutputChunk(h.alloc, &h.metrics, commandOutputStyles(), .stdout, "hidden\n", true);
    try h.shell.flushCommandOutputSummary(h.alloc, &h.metrics, commandOutputStyles(), true);
    const status_id = try h.shell.appendReplaceableTranscriptLineClassified(h.alloc, &h.metrics, "Running tests\n", .subagent_status);
    try std.testing.expect(try h.shell.replaceTrailingTranscriptLine(h.alloc, &h.metrics, "Tests passed\n"));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try expectGridContains(&h, "Tests passed");
    try expectGridNotContains(&h, "│ visible");
    try expectGridNotContains(&h, "│ hidden");
    try expectGridNotContains(&h, "ctrl o to view");
    try std.testing.expect(h.shell.replaceable_last_line);
    try std.testing.expectEqual(status_id, h.shell.replaceableEntryId().?);

    try std.testing.expect(try h.shell.setTranscriptPresentationDepth(h.alloc, .review));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try expectGridContains(&h, "Tests passed");
    try expectGridContains(&h, "│ visible");
    try expectGridContains(&h, "│ hidden");
    try expectGridNotContains(&h, "command lines folded");

    try h.driveResize(72, 24, 4, false);
    try h.driveResize(96, 36, 4, true);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try expectGridContains(&h, "Tests passed");
    try expectGridContains(&h, "│ visible");
    try expectGridContains(&h, "│ hidden");
    try expectGridNotContains(&h, "command lines folded");

    try std.testing.expect(try h.shell.setTranscriptPresentationDepth(h.alloc, .inline_mode));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try expectGridContains(&h, "Tests passed");
    try expectGridNotContains(&h, "│ visible");
    try expectGridNotContains(&h, "│ hidden");
    try expectGridNotContains(&h, "ctrl o to view");
    try std.testing.expect(h.shell.replaceable_last_line);
    try std.testing.expectEqual(status_id, h.shell.replaceableEntryId().?);
    try std.testing.expect(h.shell.replaceable_start <= h.shell.transcript.items.len);
    try std.testing.expectEqual(@as(usize, 1), h.shell.command_output_blocks.items.len);
    try std.testing.expectEqualStrings("visible", h.shell.command_output_blocks.items[0].lines.items[0].text);
    try std.testing.expectEqualStrings("hidden", h.shell.command_output_blocks.items[0].lines.items[1].text);
}

fn checkQueuedPromptAdmissionPreservesCommittedHistory(resize_before_cancel: bool) !void {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 124, 36, 4);
    defer h.deinit();
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(alloc);

    const response =
        "SCROLLBACK_LINE_01\nSCROLLBACK_LINE_02\nSCROLLBACK_LINE_03\n" ++
        "SCROLLBACK_LINE_04\nSCROLLBACK_LINE_05\nSCROLLBACK_LINE_06\n" ++
        "SCROLLBACK_LINE_07\nSCROLLBACK_LINE_08\nSCROLLBACK_LINE_09\n" ++
        "SCROLLBACK_LINE_10\nSCROLLBACK_LINE_11\nSCROLLBACK_LINE_12\n" ++
        "SCROLLBACK_LINE_13\nSCROLLBACK_LINE_14\nSCROLLBACK_LINE_15\n" ++
        "SCROLLBACK_LINE_16\nSCROLLBACK_LINE_17\nSCROLLBACK_LINE_18\n" ++
        "SCROLLBACK_LINE_19\nSCROLLBACK_LINE_20\nSCROLLBACK_LINE_21\n" ++
        "SCROLLBACK_LINE_22\nSCROLLBACK_LINE_23\n" ++
        "\x1b[1mSCROLLBACK_LINE_24";
    const draft = "unsent composer draft " ** 8;

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.streamAssistantChunk(alloc, &h.metrics, response);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try input.edit_state.input.appendSlice(alloc, draft);
    input.edit_state.cursor = input.edit_state.input.items.len;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(try h.shell.setTranscriptPresentationDepth(alloc, .review));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expect(try h.shell.setTranscriptPresentationDepth(alloc, .inline_mode));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    if (resize_before_cancel) {
        try h.driveResize(68, 18, 4, true);
        h.frame_redraw = true;
        try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
        try h.flush();
    }

    _ = try h.shell.streamAssistantChunk(
        alloc,
        &h.metrics,
        " CONTINUED\x1b[0m\n",
    );
    _ = try h.shell.appendSemanticNotice(alloc, .{
        .topic = "response",
        .tone = .cancelled,
        .body = "Interrupted by user",
    });
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        h.shell.transcriptCommitDiagnostic().state,
    );

    _ = try h.shell.writeUserPromptCard(
        alloc,
        &h.metrics,
        .{ .text = @constCast("QUEUE_SCROLL_FIRST"), .images = &.{} },
        true,
        &.{},
    );
    if (h.shell.transcriptCommitDiagnostic().state != .stable) {
        std.debug.print(
            "queued prompt invalidated committed history resize={} diagnostic={any}\n",
            .{ resize_before_cancel, h.shell.transcriptCommitDiagnostic() },
        );
        return error.TestExpectedStableTranscript;
    }
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(h.last_frame.transcript_history_floor_respected);
    try std.testing.expectEqual(
        h.last_frame.planned_scroll_rows,
        h.last_frame.committed_scroll_rows,
    );
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        h.shell.transcriptCommitDiagnostic().state,
    );
    try expectGridContains(&h, "SCROLLBACK_LINE_24");
    try expectGridContains(&h, "QUEUE_SCROLL_FIRST");
}

test "queued prompt admission preserves committed history at stable geometry" {
    try checkQueuedPromptAdmissionPreservesCommittedHistory(false);
}

test "queued prompt admission preserves committed history after a settled resize" {
    try checkQueuedPromptAdmissionPreservesCommittedHistory(true);
}

test "long context notice survives full transcript growth and later compact resizes" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 123, 34, 4);
    defer h.deinit();
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    const notice_body = ("x" ** 377) ++ "\n";
    h.shell.setCommandOutputRenderPolicy(commandOutputAnsiStyles());
    _ = try h.shell.appendSemanticNotice(alloc, .{
        .topic = "context",
        .tone = .warning,
        .body = notice_body,
        .visibility = .full_only,
    });
    try std.testing.expectEqual(@as(usize, 1), h.shell.entries.items.len);
    try std.testing.expect(h.shell.entries.items[0] == .semantic_notice);
    try std.testing.expectEqualStrings("context", h.shell.entries.items[0].semantic_notice.topic);
    try std.testing.expectEqualStrings(notice_body, h.shell.entries.items[0].semantic_notice.body);
    try std.testing.expectEqual(types.NoticeVisibility.full_only, h.shell.entries.items[0].semantic_notice.visibility);
    const rendered_notice = try render_engine.transcript_blocks.renderSemanticNotice(
        alloc,
        .{
            .topic = h.shell.entries.items[0].semantic_notice.topic,
            .tone = h.shell.entries.items[0].semantic_notice.tone,
            .body = h.shell.entries.items[0].semantic_notice.body,
            .visibility = h.shell.entries.items[0].semantic_notice.visibility,
        },
        commandOutputAnsiStyles(),
        123,
    );
    defer alloc.free(rendered_notice);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, rendered_notice, "\n") + 1);
    try std.testing.expectEqualStrings("", h.shell.transcript.items);

    try h.shell.writeTranscriptClassified(
        alloc,
        &h.metrics,
        "compact marker\n",
        true,
        .subagent_status,
    );
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try expectGridContains(&h, "compact marker");
    try expectGridNotContains(&h, "xxxxxxxx");

    try std.testing.expect(try h.shell.setTranscriptPresentationDepth(alloc, .review));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try expectGridContains(&h, "xxxxxxxx");

    const assistant_id = try h.shell.appendAssistantTurnEntry(alloc);
    const assistant = h.shell.lookupAssistantSegments(assistant_id) orelse
        return error.TestExpectedAssistantSegments;
    for (0..25) |index| {
        var line: [48]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "later response row {d}\n", .{index + 1});
        try assistant.text.appendSlice(alloc, text);
    }
    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    try expectGridContains(&h, "Thinking");

    try std.testing.expect(try h.shell.setTranscriptPresentationDepth(alloc, .inline_mode));
    try h.shell.writeTranscriptClassified(
        alloc,
        &h.metrics,
        "second prompt marker\n",
        true,
        .subagent_status,
    );
    _ = try h.shell.streamAssistantChunk(alloc, &h.metrics, "second response\n");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try expectGridContains(&h, "second response");
    try expectGridNotContains(&h, "xxxxxxxx");

    try h.driveResize(119, 32, 4, true);
    try h.driveResize(123, 34, 4, true);
    try expectGridContains(&h, "second response");
    try expectGridNotContains(&h, "xxxxxxxx");
}

test "folded command output survives canonical resize repaint" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 96, 30, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(alloc);
    const styles = commandOutputStyles();

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "prefix 00\nprefix 01\nprefix 02\nprefix 03\nprefix 04\nprefix 05\n" ++
            "prefix 06\nprefix 07\nprefix 08\nprefix 09\nprefix 10\nprefix 11\n",
        true,
    );
    try h.shell.writeCommandOutputChunk(
        alloc,
        &h.metrics,
        styles,
        .stdout,
        "fold-visible\n",
        true,
    );
    try h.shell.writeCommandOutputChunk(
        alloc,
        &h.metrics,
        styles,
        .stdout,
        "fold-hidden-one\n",
        true,
    );
    try h.shell.writeCommandOutputChunk(
        alloc,
        &h.metrics,
        styles,
        .stderr,
        "fold-hidden-two\n",
        true,
    );
    try h.shell.flushCommandOutputSummary(
        alloc,
        &h.metrics,
        styles,
        true,
    );
    try std.testing.expect(
        try h.shell.setTranscriptPresentationDepth(alloc, .review),
    );
    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "tail 00\ntail 01\ntail 02\ntail 03\ntail 04\ntail 05\n" ++
            "tail 06\ntail 07\ntail 08\ntail 09\ntail 10\ntail 11\n" ++
            "tail 12\ntail 13\ntail 14\ntail 15\ntail 16\ntail 17\n" ++
            "tail 18\ntail 19\n",
        true,
    );
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try h.vt.resize(54, 20);
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(54, 20, 4),
        true,
    );
    h.shell.resize_history_row_delta = 4;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    h.shell.resize_history_row_delta = null;
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try std.testing.expect(!h.shell.terminal_reset_pending);
    try h.shell.writeCommandOutputChunk(
        alloc,
        &h.metrics,
        styles,
        .stdout,
        "compatible-live-output\n",
        true,
    );
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try h.vt.resize(96, 30);
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(96, 30, 4),
        true,
    );
    h.shell.resize_history_row_delta = 0;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try std.testing.expect(!h.shell.terminal_reset_pending);
    if (std.mem.count(u8, h.shell.transcript.items, "fold-hidden-one") != 1) {
        return error.TestExpectedOneFoldedStdoutMarker;
    }
    if (std.mem.count(u8, h.shell.transcript.items, "fold-hidden-two") != 1) {
        return error.TestExpectedOneFoldedStderrMarker;
    }
    if (std.mem.count(u8, h.shell.transcript.items, "compatible-live-output") != 1) {
        return error.TestExpectedOneCompatibleOutputMarker;
    }
    try expectGridContains(&h, "fold-hidden-one");
    try expectGridContains(&h, "fold-hidden-two");

    h.shell.resize_history_row_delta = null;
    try h.shell.writeCommandOutputChunk(
        alloc,
        &h.metrics,
        styles,
        .stdout,
        "post-restore-output\n",
        true,
    );
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expect(
        h.last_frame.document_append_bytes > 0 or
            h.shell.transcriptCommitDiagnostic().state ==
                transcript_runtime.TranscriptCommitDiagnosticState.recovering,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, h.shell.transcript.items, "post-restore-output"),
    );
}

test "conversation tail takes priority over pinned welcome" {
    var h = try Harness.init(std.testing.allocator, 96, 22, 4);
    defer h.deinit();

    try h.shell.initViewportWithReservedRows(&h.metrics, 6, ui_render.welcome_message_reserved_rows);
    const welcome = try ui_render.welcomeMessage(h.alloc);
    defer h.alloc.free(welcome);
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, welcome, true, .welcome);

    const prompt = try h.alloc.dupe(u8, "user message must stay visible");
    _ = try h.shell.appendUserTurnOwned(h.alloc, .{ .text = prompt, .images = &.{} });
    const assistant_id = try h.shell.appendAssistantTurnEntry(h.alloc);
    const segs = h.shell.lookupAssistantSegments(assistant_id) orelse unreachable;
    try segs.text.appendSlice(h.alloc, "assistant response line 1\nassistant response line 2\nassistant response line 3\nassistant response line 4");

    try h.renderTranscriptFrame();
    try h.flush();

    try std.testing.expect(!h.shell.last_visible_transcript_split_active);
    try expectGridContains(&h, "user message must stay visible");
    try expectGridContains(&h, "assistant response line 4");
}

test "entry-bound shimmer resolves inside pinned welcome tail selection" {
    var h = try Harness.init(std.testing.allocator, 96, 43, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewportWithReservedRows(&h.metrics, 6, ui_render.welcome_message_reserved_rows);
    const welcome = try ui_render.welcomeMessage(h.alloc);
    defer h.alloc.free(welcome);
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, welcome, true, .welcome);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(h.alloc);
    var i: usize = 0;
    while (i < 28) : (i += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "content line {d}\n", .{i});
        defer h.alloc.free(line);
        try body.appendSlice(h.alloc, line);
    }
    try h.shell.writeTranscriptClassified(h.alloc, &h.metrics, body.items, true, .subagent_status);
    const status_id = try appendCompletedToolStatus(&h, "tail status line");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const status_row = try findRowContaining(&h, "tail status line");
    try expectGridContains(&h, "𝒇x v");

    var ctx = defaultFooterContext(&input);
    setToolActivity(&ctx, status_id, "Reading pinned tail");
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    try std.testing.expectEqual(status_row, try findRowContaining(&h, "tail status line"));
    try expectGridNotContains(&h, "Reading pinned tail");
}

test "long transcript overflow does not start or end on orphan gap rows" {
    var h = try Harness.init(std.testing.allocator, 60, 14, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval: approval_prompt.ApprovalPrompt = .{};
    defer approval.deinit(h.alloc);

    try h.shell.initViewport(&h.metrics, 1);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const line = try std.fmt.allocPrint(h.alloc, "block-{d}\n", .{i});
        defer h.alloc.free(line);
        _ = try h.shell.appendSemanticNotice(h.alloc, .{
            .topic = "system",
            .tone = .information,
            .body = std.mem.trimEnd(u8, line, "\n"),
        });
    }
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const footer_row = try findFirstDividerRowAfter(&h, 1);
    try std.testing.expect(footer_row > 2);

    var first_content_row: ?u16 = null;
    var row: u16 = 1;
    while (row < footer_row) : (row += 1) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(h.alloc);
        try h.vt.rowTextTrimmed(row, &buf);
        if (std.mem.find(u8, buf.items, "block-") != null) {
            first_content_row = row;
            break;
        }
    }

    try std.testing.expect(first_content_row != null);
    try std.testing.expect(first_content_row.? < footer_row);
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(h.alloc);
    try h.vt.rowTextTrimmed(footer_row - 1, &tail);
    if (tail.items.len == 0) {
        var before_gap: std.ArrayList(u8) = .empty;
        defer before_gap.deinit(h.alloc);
        try h.vt.rowTextTrimmed(footer_row - 2, &before_gap);
        try std.testing.expect(std.mem.find(u8, before_gap.items, "block-") != null);
    } else {
        try std.testing.expect(std.mem.find(u8, tail.items, "block-") != null);
    }
}

test "settled resize emits a replay_viewport pass" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 4);
    try h.shell.writeTranscript(h.alloc, &h.metrics, "hello\n", true);
    try h.flush();

    const before_replays = h.metrics.debounced_resizes;
    try h.driveResize(60, 20, 4, true);

    try std.testing.expectEqual(before_replays + 1, h.metrics.debounced_resizes);
}

test "settled resize reflows recorded entries instead of a poisoned cache" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 48, 16, 4);
    defer h.deinit();
    try h.initStartupViewport(1, 4);

    _ = try h.shell.appendRawTranscriptEntryClassified(
        alloc,
        "committed before resize\n",
        .subagent_status,
    );
    try h.renderTranscriptFrame();
    try h.flush();

    _ = try h.shell.appendRawTranscriptEntryClassified(
        alloc,
        "recorded after poison wraps across the resized viewport\n",
        .subagent_status,
    );
    h.shell.transcript.clearRetainingCapacity();
    try h.shell.transcript.appendSlice(alloc, "poisoned resize cache\n");
    h.shell.transcript_cache_origin_untrimmed = false;

    try h.driveResize(24, 16, 4, true);

    try expectGridContains(&h, "recorded after poison");
    try expectGridNotContains(&h, "poisoned resize cache");
    try std.testing.expect(
        std.mem.find(u8, h.shell.transcript.items, "recorded after poison") != null,
    );
}

test "live resize keeps pending_settled_width_reflow set" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 4);
    try h.driveResize(60, 24, 4, false);
    try std.testing.expect(h.shell.render_requests.pending_settled_width_reflow);

    try h.driveResize(60, 24, 4, true);
    try std.testing.expect(!h.shell.render_requests.pending_settled_width_reflow);
}

test "no-op resize at settled pass is a noop" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 4);

    const before = h.metrics.debounced_resizes;
    try h.driveResize(80, 24, 4, true);
    try std.testing.expectEqual(before, h.metrics.debounced_resizes);
}

test "resize clips cursor_row into the new content band" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 4);

    h.shell.cursor_row = 18;
    try h.driveResize(60, 12, 4, true);
    try std.testing.expect(h.shell.cursor_row <= h.shell.layout.content_bottom);
}

test "shrink grows the VT grid and matches emitted width" {
    var h = try Harness.init(std.testing.allocator, 120, 30, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 10);
    try h.shell.writeTranscript(h.alloc, &h.metrics, "banner\n", true);
    try h.flush();

    try h.driveResize(80, 24, 4, true);
    try std.testing.expectEqual(@as(u16, 80), h.vt.cols);
    try std.testing.expectEqual(@as(u16, 24), h.vt.rows);
    try std.testing.expectEqual(@as(u16, 80), h.shell.layout.cols);
    try std.testing.expectEqual(@as(u16, 24), h.shell.layout.rows);
}

test "reanchorTop preserves rows above launch-owned row" {
    var h = try Harness.init(std.testing.allocator, 20, 10, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 3);
    try h.vt.feed("\x1b[2;1HPRE-FX");
    try h.shell.writeTranscript(h.alloc, &h.metrics, "line one\nline two\n", true);
    try h.flush();

    try shell_runtime.requestRedraw(&h.shell, &h.metrics, .reanchor_top);
    try h.renderTranscriptFrame();
    try h.flush();

    try expectRowPrefix(&h, 2, "PRE-FX");
    try expectRowPrefix(&h, 3, "line one");
    try expectRowPrefix(&h, 4, "line two");
}

test "updateExtraInputRows shrink repaints transcript into freed rows" {
    var h = try Harness.init(std.testing.allocator, 40, 16, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 8);
    try h.shell.writeTranscript(h.alloc, &h.metrics, "alpha\nbeta\n", true);
    try h.flush();

    try h.shell.updateExtraInputRows(h.alloc, &h.metrics, 3);
    try h.renderTranscriptFrame();
    try h.flush();
    try h.shell.updateExtraInputRows(h.alloc, &h.metrics, 0);
    try h.renderTranscriptFrame();
    try h.flush();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    var found_alpha = false;
    var found_beta = false;
    var r: u16 = 1;
    while (r <= h.vt.rows) : (r += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(r, &buf);
        if (std.mem.find(u8, buf.items, "alpha") != null) found_alpha = true;
        if (std.mem.find(u8, buf.items, "beta") != null) found_beta = true;
    }
    try std.testing.expect(found_alpha);
    try std.testing.expect(found_beta);
}

test "clean footer frame skips repaint when nothing is dirty" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(h.alloc);

    var frame_redraw = true;
    try h.shell.initViewport(&h.metrics, 15);
    try renderTestFooter(&h, &input, &approval, &frame_redraw);

    const bytes_after_first = try h.file.length(io_mod.getIo());
    const updates_after_first = h.metrics.footer_line_updates;

    try renderTestFooter(&h, &input, &approval, &frame_redraw);

    try std.testing.expectEqual(bytes_after_first, try h.file.length(io_mod.getIo()));
    try std.testing.expectEqual(updates_after_first, h.metrics.footer_line_updates);
}

test "clean footer frame does not spam trace on idle ticks" {
    var h = try Harness.init(std.testing.allocator, 80, 24, 4);
    defer h.deinit();

    const root = try io_mod.dirRealpathAlloc(h.alloc, h.tmp.dir, ".");
    defer h.alloc.free(root);
    const trace_path = try std.fs.path.join(h.alloc, &.{ root, "trace.log" });
    defer h.alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(h.alloc, trace_path, "footer.clean");

    var input = InputRuntime{};
    defer input.deinit(h.alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(h.alloc);

    var frame_redraw = true;
    try h.shell.initViewport(&h.metrics, 15);
    try renderTestFooter(&h, &input, &approval, &frame_redraw);
    try renderTestFooter(&h, &input, &approval, &frame_redraw);
    try renderTestFooter(&h, &input, &approval, &frame_redraw);

    const zio = io_mod.getIo();
    var trace_file = try std.Io.Dir.openFileAbsolute(zio, trace_path, .{});
    defer trace_file.close(zio);
    const trace = try io_mod.readFileToEnd(h.alloc, &trace_file, 4096);
    defer h.alloc.free(trace);

    try std.testing.expect(std.mem.find(u8, trace, "footer.clean") == null);
}

test "startup reservation scrolls to fit first paint without wiping pre-fx rows" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.vt.feed("\x1b[1;1H");
    try h.vt.feed("PRE01\n");
    try h.vt.feed("PRE02\n");
    try h.vt.feed("PRE03\n");
    try h.vt.feed("PRE04\n");
    try h.vt.feed("PRE05\n");
    try h.vt.feed("PRE06\n");
    try h.vt.feed("PRE07\n");
    try h.vt.feed("PRE08\n");
    try h.vt.feed("PRE09\n");
    try h.vt.feed("PRE10\n");
    try h.vt.feed("PRE11\n");
    try h.vt.feed("PRE12\n");
    try h.vt.feed("PRE13\n");
    try h.vt.feed("PRE14\n");
    try h.vt.feed("PRE15\n");
    try h.vt.feed("PRE16\n");
    try h.vt.feed("PRE17\n");
    try h.vt.feed("PRE18\n");
    try h.vt.feed("PRE19\n");
    try h.vt.feed("$ fx");

    try h.initStartupViewport(24, 11);
    try std.testing.expectEqual(@as(u16, 10), h.shell.viewport_top_row);
    try h.flush();

    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "FX01\nFX02\nFX03\nFX04\nFX05\nFX06\nFX07\nFX08\nFX09\nFX10\n",
        true,
    );
    try h.renderTranscriptFrameIfDirty();
    try h.flush();

    try expectRowPrefix(&h, 1, "PRE15");
    try expectRowPrefix(&h, 6, "$ fx");
    try expectRowPrefix(&h, 10, "FX01");
    try expectRowPrefix(&h, 19, "FX10");
}

test "post-paint overflow waits for synchronized paint before scrolling" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.initStartupViewport(24, 11);
    try h.flush();

    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "FX01\nFX02\nFX03\nFX04\nFX05\nFX06\nFX07\nFX08\nFX09\nFX10\n",
        true,
    );
    try h.renderTranscriptFrameIfDirty();
    try h.flush();
    try std.testing.expect(h.shell.has_painted_transcript);

    const before_write = try h.file.length(io_mod.getIo());
    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "LIVE01\nLIVE02\nLIVE03\nLIVE04\nLIVE05\nLIVE06\nLIVE07\nLIVE08\nLIVE09\nLIVE10\nLIVE11\nLIVE12\nLIVE13\nLIVE14\nLIVE15\n",
        true,
    );
    const after_write = try h.file.length(io_mod.getIo());
    try std.testing.expectEqual(before_write, after_write);

    try h.renderTranscriptFrameIfDirty();
    const after_paint = try h.file.length(io_mod.getIo());
    try std.testing.expect(after_paint > after_write);
}

test "first post-paint overflow releases wrapped launch rows through frame scroll" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.vt.feed("\x1b[1;1H");
    try h.vt.feed("PRE01\n");
    try h.vt.feed("PRE02\n");
    try h.vt.feed("PRE03\n");
    try h.vt.feed("PRE04\n");
    try h.vt.feed("PRE05\n");
    try h.vt.feed("PRE06\n");
    try h.vt.feed("PRE07\n");
    try h.vt.feed("PRE08\n");
    try h.vt.feed("PRE09\n");
    try h.vt.feed("PRE10\n");
    try h.vt.feed("PRE11\n");
    try h.vt.feed("PRE12\n");
    try h.vt.feed("PRE13\n");
    try h.vt.feed("PRE14\n");
    try h.vt.feed("CMD01\n");
    try h.vt.feed("CMD02\n");
    try h.vt.feed("CMD03\n");
    try h.vt.feed("CMD04\n");
    try h.vt.feed("CMD05\n");
    try h.vt.feed("CMD06\n");
    try h.vt.feed("CMD07\n");
    try h.vt.feed("CMD08\n");
    try h.vt.feed("CMD09");

    try h.initStartupViewport(24, 11);
    try h.flush();
    try expectRowPrefix(&h, 9, "CMD09");

    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "FX01\nFX02\nFX03\nFX04\nFX05\nFX06\nFX07\nFX08\nFX09\nFX10\n",
        true,
    );
    try h.renderTranscriptFrameIfDirty();
    try h.flush();
    try std.testing.expect(h.shell.has_painted_transcript);

    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "LIVE01\nLIVE02\nLIVE03\nLIVE04\nLIVE05\nLIVE06\nLIVE07\nLIVE08\n",
        true,
    );
    const before_overflow_frame = try h.file.length(io_mod.getIo());
    try h.renderTranscriptFrameIfDirty();
    try h.flush();

    const emitted = try readEmittedSince(&h, before_overflow_frame);
    defer alloc.free(emitted);
    try std.testing.expect(std.mem.find(u8, emitted, "\x1b[3J") == null);
    try std.testing.expectEqual(h.shell.owned_top_row, h.shell.viewport_top_row);
    try std.testing.expect(h.shell.owned_top_row < 10);
    try expectGridContains(&h, "LIVE08");
}

test "settled resize reserves welcome rows before replaying viewport" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.initStartupViewport(24, 11);
    try std.testing.expectEqual(@as(u16, 10), h.shell.viewport_top_row);
    try h.flush();

    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "FX01\nFX02\nFX03\nFX04\nFX05\nFX06\nFX07\nFX08\nFX09\nFX10\nFX11",
        true,
    );
    try h.renderTranscriptFrameIfDirty();
    try h.flush();

    try expectRowPrefix(&h, 10, "FX01");
    try expectRowPrefix(&h, 20, "FX11");

    try h.driveResize(80, 23, 4, true);

    try std.testing.expectEqual(h.shell.owned_top_row, h.shell.viewport_top_row);
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try std.testing.expectEqual(@as(u16, 11), h.shell.min_visible_viewport_rows);
    try expectRowPrefix(&h, 1, "FX01");
    try expectRowPrefix(&h, 11, "FX11");

    try h.driveResize(80, 22, 4, true);
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try std.testing.expectEqual(@as(u16, 11), h.shell.min_visible_viewport_rows);
}

test "settled resize clears reflowed rows above the launch-owned viewport" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.initStartupViewport(24, 11);
    try h.flush();

    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "FX01\nFX02\nFX03\nFX04\nFX05\nFX06\nFX07\nFX08\nFX09\nFX10\nFX11",
        true,
    );
    try h.renderTranscriptFrameIfDirty();
    try h.flush();

    try h.vt.resize(80, 23);
    try h.vt.feed("\x1b[9;1HPRE-FX-ROW");
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(80, 23, 4),
        true,
    );
    try h.renderTranscriptFrame();
    try h.flush();

    try expectGridNotContains(&h, "PRE-FX-ROW");
    try expectRowPrefix(&h, 1, "FX01");
    try expectRowPrefix(&h, 11, "FX11");
}

test "recovering from collapsed resize scroll-compacts stale viewport rows" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.vt.feed("\x1b[1;1HPRE-FX");
    try h.shell.initViewport(&h.metrics, 5);

    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "FX01\nFX02\nFX03\nFX04\nFX05\nFX06\nFX07\nFX08\nFX09",
        true,
    );
    try h.renderTranscriptFrameIfDirty();
    try h.flush();

    try expectRowPrefix(&h, 1, "PRE-FX");
    try expectRowPrefix(&h, 5, "FX01");

    try h.driveResize(80, 5, 4, true);
    try h.driveResize(80, 24, 4, true);

    try std.testing.expectEqual(@as(u16, 1), h.shell.owned_top_row);
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try expectGridNotContains(&h, "PRE-FX");
    try expectRowPrefix(&h, 1, "FX01");
    try expectRowPrefix(&h, 9, "FX09");
}

test "empty pre-paint defers scrolling until first content frame" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.vt.feed("\x1b[1;1H");
    try h.vt.feed("PRE01\n");
    try h.vt.feed("PRE02\n");
    try h.vt.feed("PRE03\n");
    try h.vt.feed("PRE04\n");
    try h.vt.feed("PRE05\n");
    try h.vt.feed("PRE06\n");
    try h.vt.feed("PRE07\n");
    try h.vt.feed("PRE08\n");
    try h.vt.feed("PRE09\n");
    try h.vt.feed("PRE10\n");
    try h.vt.feed("PRE11\n");
    try h.vt.feed("PRE12\n");
    try h.vt.feed("PRE13\n");
    try h.vt.feed("PRE14\n");
    try h.vt.feed("PRE15\n");
    try h.vt.feed("PRE16\n");
    try h.vt.feed("PRE17\n");
    try h.vt.feed("PRE18\n");
    try h.vt.feed("PRE19\n");
    try h.vt.feed("$ fx");

    try h.shell.initViewport(&h.metrics, 24);
    try h.renderTranscriptFrame();
    try std.testing.expect(!h.shell.has_painted_transcript);

    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "FX01\nFX02\nFX03\nFX04\nFX05\nFX06\nFX07\nFX08\nFX09\nFX10\nFX11\nFX12\n",
        true,
    );
    try std.testing.expectEqual(@as(u16, 20), h.shell.viewport_top_row);

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    const before_frame = try h.file.length(io_mod.getIo());
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const emitted = try readEmittedSince(&h, before_frame);
    defer alloc.free(emitted);
    try std.testing.expect(std.mem.find(u8, emitted, "\x1b[3J") == null);
    try expectRowPrefix(&h, 1, "PRE11");
    try expectRowPrefix(&h, 9, "PRE19");
    try expectRowPrefix(&h, 10, "FX01");
    try expectRowPrefix(&h, 21, "FX12");
}

test "slash picker dismissal releases reserved picker rows" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 100, 20, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "line 01\nline 02\nline 03\nline 04\nline 05\nline 06\nline 07\nline 08\n" ++
            "line 09\nline 10\nline 11\nline 12\nline 13\nline 14\nline 15\n",
        true,
    );

    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const idle_footer_top = h.shell.committed_frame_layout.footer_area.top;

    try input.edit_state.input.appendSlice(alloc, "/");
    input.edit_state.cursor = input.edit_state.input.items.len;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(h.last_frame.planned_scroll_rows > 0);
    try std.testing.expectEqual(
        h.last_frame.planned_scroll_rows,
        h.last_frame.committed_scroll_rows,
    );
    try std.testing.expectEqual(@as(u16, 9), h.shell.committed_frame_layout.footer_area.top);
    const picker_anchor = h.shell.stableTranscriptProjectionForFlow(
        h.shell.transcript.items,
    ) orelse return error.TestExpectedStableTranscript;
    try std.testing.expectEqual(
        picker_anchor.visual_offset,
        picker_anchor.history_visual_offset,
    );

    try std.testing.expect(input.deletionState(null).delete(
        alloc,
        .character_left,
        .clear,
    ));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.committed_scroll_rows);
    const dismissed_anchor = h.shell.stableTranscriptProjectionForFlow(
        h.shell.transcript.items,
    ) orelse return error.TestExpectedStableTranscript;
    try std.testing.expect(
        dismissed_anchor.history_visual_offset >= picker_anchor.history_visual_offset,
    );
    try std.testing.expect(h.shell.committed_frame_layout.footer_area.top < idle_footer_top);
    try std.testing.expectEqual(
        h.shell.last_visible_transcript_last_row + 1,
        h.shell.committed_frame_layout.footer_area.top,
    );

    var tall = try Harness.init(alloc, 100, 32, 4);
    defer tall.deinit();
    try tall.shell.initViewport(&tall.metrics, 1);
    try tall.shell.writeTranscript(
        alloc,
        &tall.metrics,
        "line 01\nline 02\nline 03\nline 04\nline 05\nline 06\nline 07\nline 08\n" ++
            "line 09\nline 10\nline 11\nline 12\nline 13\nline 14\nline 15\n",
        true,
    );
    var tall_input = InputRuntime{};
    defer tall_input.deinit(alloc);
    var tall_approval = approval_prompt.ApprovalPrompt{};
    defer tall_approval.deinit(alloc);

    try renderTestFooter(&tall, &tall_input, &tall_approval, &tall.frame_redraw);
    try tall.flush();
    try tall_input.edit_state.input.appendSlice(alloc, "/");
    tall_input.edit_state.cursor = tall_input.edit_state.input.items.len;
    tall.frame_redraw = true;
    try renderTestFooter(&tall, &tall_input, &tall_approval, &tall.frame_redraw);
    try tall.flush();
    try std.testing.expectEqual(@as(u16, 0), tall.last_frame.committed_scroll_rows);
    try std.testing.expect(tall_input.deletionState(null).delete(
        alloc,
        .character_left,
        .clear,
    ));
    tall.frame_redraw = true;
    try renderTestFooter(&tall, &tall_input, &tall_approval, &tall.frame_redraw);
    try tall.flush();
    try std.testing.expectEqual(@as(u16, 0), tall.last_frame.committed_scroll_rows);
    try expectRowPrefix(&tall, 15, "line 15");
    try std.testing.expectEqual(@as(u16, 16), tall.shell.committed_frame_layout.footer_area.top);
}

test "slash picker dismissal resolves transcript extent before layout convergence" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 124, 75, 3);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(alloc);
    for (0..82) |line_number| {
        var line_buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buf,
            "ATOMIC_RENDER_LINE_{d:0>3} carries deterministic resumed transcript geometry.",
            .{line_number},
        );
        try transcript.appendSlice(alloc, line);
        if (line_number + 1 < 82) try transcript.append(alloc, '\n');
    }

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.appendUserTurnOwned(alloc, .{
        .text = try alloc.dupe(u8, "Create the deterministic long transcript."),
        .images = &.{},
    });
    _ = try h.shell.streamAssistantChunk(alloc, &h.metrics, transcript.items);
    h.shell.transcript_release = h.shell.transcript_release.with_assistant_tail_writable(false);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expectEqual(@as(u16, 71), h.shell.last_visible_transcript_last_row);

    try input.textReplacementState().replace(alloc, "/");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expectEqual(@as(u16, 62), h.shell.last_visible_transcript_last_row);
    try std.testing.expectEqual(@as(u16, 64), try findRowContaining(&h, "┃ /"));

    input.picker.dismissInlinePicker(.slash);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 62), h.shell.last_visible_transcript_last_row);
    try std.testing.expectEqual(@as(u16, 64), try findRowContaining(&h, "┃ /"));
    try std.testing.expectEqual(@as(u16, 64), h.shell.committed_frame_layout.footer_area.top);
    try std.testing.expectEqual(@as(u16, 66), h.shell.committed_frame_layout.footer_area.bottom);
    try std.testing.expectEqual(
        @as(usize, 1),
        try countGridOccurrences(&h, "ATOMIC_RENDER_LINE_080"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countGridOccurrences(&h, "ATOMIC_RENDER_LINE_081"),
    );

    try input.insertionState().insertByte(alloc, 'x', .clear);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(@as(u16, 62), h.shell.last_visible_transcript_last_row);
    try std.testing.expectEqual(@as(u16, 64), try findRowContaining(&h, "┃ /x"));
    try std.testing.expectEqual(@as(u16, 64), h.shell.committed_frame_layout.footer_area.top);
    try std.testing.expectEqual(@as(u16, 66), h.shell.committed_frame_layout.footer_area.bottom);
    try std.testing.expectEqual(
        @as(usize, 1),
        try countGridOccurrences(&h, "ATOMIC_RENDER_LINE_080"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countGridOccurrences(&h, "ATOMIC_RENDER_LINE_081"),
    );
}

test "slash picker dismissal after resize restores the short transcript boundary" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 72, 16, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "recording path wraps at the resized terminal width\n" ++
            "visible terminal content\n" ++
            "including typed prompt text\n" ++
            "is recorded\n",
        true,
    );
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try h.driveResize(60, 12, 4, true);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const resized_footer_top = h.shell.committed_frame_layout.footer_area.top;
    const resized_transcript_last_row = h.shell.last_visible_transcript_last_row;

    try input.textReplacementState().replace(alloc, "/mod");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expect(h.shell.extra_input_rows > 0);

    input.picker.dismissInlinePicker(.slash);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.committed_scroll_rows);
    try std.testing.expectEqual(
        resized_transcript_last_row,
        h.shell.last_visible_transcript_last_row,
    );
    try std.testing.expectEqual(
        resized_footer_top,
        h.shell.committed_frame_layout.footer_area.top,
    );
}

test "footer reservation release and cleanup invalidation keep the held transcript projection aligned" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 100, 20, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "line 01\nline 02\nline 03\nline 04\nline 05\nline 06\nline 07\nline 08\n",
        true,
    );
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try input.textReplacementState().replace(alloc, "/");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try h.shell.writeNotice(
        alloc,
        &h.metrics,
        .{
            .topic = "statusline",
            .tone = .information,
            .body = "Status line: on",
        },
        true,
    );
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    input.picker.dismissInlinePicker(.slash);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    h.shell.render_requests.requestInvalidation(.{
        .reason = .external_clear,
        .top = h.shell.committed_frame_layout.footer_area.top,
        .bottom = h.shell.layout.rows,
    });
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const released_footer_top = h.shell.committed_frame_layout.footer_area.top;

    try input.insertionState().insertByte(alloc, 'x', .clear);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(h.shell.committed_frame_layout.footer_area.top, released_footer_top);
}

test "compact picker dismissal preserves committed history floor" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 60, 12, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "startup 01\nstartup 02\nstartup 03\nstartup 04\n" ++
            "startup 05\nstartup 06\nstartup 07\n",
        true,
    );
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try input.textReplacementState().replace(alloc, "/status");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const picker_anchor = h.shell.stableTranscriptProjectionForFlow(
        h.shell.transcript.items,
    ) orelse return error.TestExpectedStableTranscript;
    try std.testing.expectEqual(
        picker_anchor.visual_offset,
        picker_anchor.history_visual_offset,
    );

    try h.shell.writeNotice(
        alloc,
        &h.metrics,
        .{
            .topic = "status",
            .tone = .information,
            .body = "model=test-model\n" ++
                "auth=AI_GATEWAY_API_KEY\n" ++
                "auth_refreshable=false\n" ++
                "permission_mode=auto\n" ++
                "workspace=/tmp/fx\n" ++
                "history_turns=0\n" ++
                "session_permission_grants=0\n" ++
                "agent_step_limit=0",
        },
        true,
    );
    input.inputResetState().clearCurrent(alloc);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(h.last_frame.planned_scroll_rows > 0);
    try std.testing.expectEqual(
        h.last_frame.planned_scroll_rows,
        h.last_frame.committed_scroll_rows,
    );
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expect(h.last_frame.document_append_bytes > 0);
    try std.testing.expectEqual(
        @as(?u16, h.last_frame.planned_scroll_rows),
        h.last_frame.document_append_clear_rows,
    );
    const dismissed_anchor = h.shell.stableTranscriptProjectionForFlow(
        h.shell.transcript.items,
    ) orelse return error.TestExpectedStableTranscript;
    try std.testing.expect(
        dismissed_anchor.history_visual_offset >= picker_anchor.history_visual_offset,
    );
}

test "short notice after picker selection keeps footer compact" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 125, 37, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(alloc);
    for (1..71) |line_number| {
        var line_buf: [24]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "history line {d}\n", .{line_number});
        try transcript.appendSlice(alloc, line);
    }

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(alloc, &h.metrics, transcript.items, true);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const idle_footer_top = h.shell.committed_frame_layout.footer_area.top;

    try input.textReplacementState().replace(alloc, "/");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expect(h.shell.committed_frame_layout.footer_area.top < idle_footer_top);

    const notice = "Switched to openai/gpt-5 (fast)";
    try h.shell.writeNotice(
        alloc,
        &h.metrics,
        .{
            .topic = "model",
            .tone = .information,
            .body = notice,
        },
        true,
    );
    input.inputResetState().clearCurrent(alloc);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.committed_scroll_rows);
    try std.testing.expect(h.shell.committed_frame_layout.footer_area.top < idle_footer_top);
    try std.testing.expectEqual(
        h.shell.last_visible_transcript_last_row + 2,
        h.shell.committed_frame_layout.footer_area.top,
    );
    try std.testing.expectEqual(@as(usize, 1), try countGridOccurrences(&h, notice));
}

test "long transcript picker filtering keeps footer anchored and close releases reservation" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 100, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "line 01\nline 02\nline 03\nline 04\nline 05\nline 06\nline 07\nline 08\n" ++
            "line 09\nline 10\nline 11\nline 12\nline 13\nline 14\nline 15\nline 16\n" ++
            "line 17\nline 18\nline 19\nline 20\nline 21\nline 22\nline 23\nline 24\n" ++
            "line 25\nline 26\nline 27\nline 28\nline 29\nline 30\nline 31\nline 32\n",
        true,
    );

    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const idle_footer_top = h.shell.committed_frame_layout.footer_area.top;
    try std.testing.expectEqual(h.shell.layout.rows, h.shell.committed_frame_layout.footer_area.bottom);

    try input.edit_state.input.appendSlice(alloc, "/");
    input.edit_state.cursor = input.edit_state.input.items.len;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const open_footer_top = h.shell.committed_frame_layout.footer_area.top;
    try std.testing.expect(open_footer_top < idle_footer_top);

    input.inputResetState().clearCurrent(alloc);
    try input.edit_state.input.appendSlice(alloc, "/fe");
    input.edit_state.cursor = input.edit_state.input.items.len;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expectEqual(open_footer_top, h.shell.committed_frame_layout.footer_area.top);

    input.inputResetState().clearCurrent(alloc);
    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "┃ /login\n\n",
        true,
    );
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(h.shell.committed_frame_layout.footer_area.top < idle_footer_top);
    try std.testing.expectEqual(
        h.shell.last_visible_transcript_last_row + 2,
        h.shell.committed_frame_layout.footer_area.top,
    );
    try std.testing.expect(h.shell.committed_frame_layout.footer_area.bottom < h.shell.layout.rows);

    h.shell.terminal_reset_pending = true;
    try h.shell.writeNotice(
        alloc,
        &h.metrics,
        .{
            .topic = "auth",
            .tone = .information,
            .body = "Starting Vercel sign-in",
        },
        true,
    );
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try expectGridContains(&h, "Starting Vercel sign-in");
}

test "picker growth advances history while shrink and dismissal do not" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 125, 37, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(alloc);
    for (1..71) |line_number| {
        var line_buf: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{d}.\n", .{line_number});
        try transcript.appendSlice(alloc, line);
    }

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(alloc, &h.metrics, transcript.items, true);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const idle_footer_top = h.shell.committed_frame_layout.footer_area.top;

    try input.textReplacementState().replace(alloc, "/");
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const slash_footer_top = h.shell.committed_frame_layout.footer_area.top;
    try std.testing.expect(slash_footer_top < idle_footer_top);
    try std.testing.expect(h.last_frame.planned_scroll_rows > 0);
    try std.testing.expectEqual(
        h.last_frame.planned_scroll_rows,
        h.last_frame.committed_scroll_rows,
    );
    const slash_anchor = h.shell.stableTranscriptProjectionForFlow(
        h.shell.transcript.items,
    ) orelse return error.TestExpectedStableTranscript;
    try std.testing.expectEqual(
        slash_anchor.visual_offset,
        slash_anchor.history_visual_offset,
    );

    try input.textReplacementState().replace(alloc, "/model ");
    var model_ctx = defaultFooterContext(&input);
    model_ctx.model_query_active = true;
    model_ctx.model_completions_failed = true;
    model_ctx.model_completion_anchor = "/model ".len;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, model_ctx);
    try h.flush();

    try std.testing.expectEqual(
        slash_footer_top,
        h.shell.committed_frame_layout.footer_area.top,
    );
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);

    input.picker.dismissInlinePicker(.model);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.committed_scroll_rows);
    const dismissed_anchor = h.shell.stableTranscriptProjectionForFlow(
        h.shell.transcript.items,
    ) orelse return error.TestExpectedStableTranscript;
    try std.testing.expect(
        dismissed_anchor.history_visual_offset >= slash_anchor.history_visual_offset,
    );
    try std.testing.expect(h.shell.committed_frame_layout.footer_area.top < idle_footer_top);
    try std.testing.expectEqual(
        h.shell.last_visible_transcript_last_row + 1,
        h.shell.committed_frame_layout.footer_area.top,
    );
}

test "slash main page renders header categories selection range and contextual controls" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 100, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "/");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 15);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try expectGridContains(&h, "Commands 38 · Type to filter");
    try expectGridContains(&h, "1–6");
    try expectGridContains(&h, "/help");
    try expectGridContains(&h, "General");
    try expectGridContains(&h, "↑↓ Navigate     Enter Use     Esc Close");

    input.picker.slash_completion_index = 6;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try expectGridContains(&h, "2–7");

    input.inputResetState().clearCurrent(alloc);
    try input.edit_state.input.appendSlice(alloc, "/permissions ");
    input.edit_state.cursor = input.edit_state.input.items.len;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try expectGridContains(&h, "ask");
    try expectGridContains(&h, "test-model");
    try expectGridNotContains(&h, "Commands 38");
    try expectGridNotContains(&h, "↑↓ Navigate");
}

test "slash main page drops categories and ellipsizes descriptions when narrow" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 42, 18, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "/mo");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 12);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try expectGridContains(&h, "Commands 2");
    try expectGridContains(&h, "/model");
    try expectGridContains(&h, "…");
    try expectGridNotContains(&h, "Model");
}

test "footer renders slash completions while stream is active" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "/mo");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    var frame_redraw = true;
    var ctx = defaultFooterContext(&input);
    ctx.stream = .{ .active = true, .command_count = 1, .last_activity_kind = .command };

    try h.shell.initViewport(&h.metrics, 15);
    try renderTestFooterWithContext(&h, &approval, &frame_redraw, ctx);
    try h.flush();

    try expectGridContains(&h, "/mo");
    try expectGridContains(&h, "/model");
}

test "footer keeps model picker suppressed while stream is active" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "/model g");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    var frame_redraw = true;
    var ctx = defaultFooterContext(&input);
    ctx.stream = .{ .active = true, .command_count = 1, .last_activity_kind = .command };
    ctx.model_query_active = true;
    ctx.model_completions = &.{"gpt-test-model"};
    ctx.model_completion_anchor = "/model ".len;

    try h.shell.initViewport(&h.metrics, 15);
    try renderTestFooterWithContext(&h, &approval, &frame_redraw, ctx);
    try h.flush();

    try expectGridContains(&h, "/model g");
    try expectGridNotContains(&h, "gpt-test-model");
}

test "footer suppresses slash skill rows for streaming model-shaped input" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    const skills = [_]skill_runtime.Skill{.{
        .name = "model-helper",
        .description = "model helper",
        .path = "/tmp/model-helper/SKILL.md",
        .source = .global_fx,
    }};

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "/model ");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    var frame_redraw = true;
    var ctx = defaultFooterContext(&input);
    ctx.stream = .{ .active = true, .command_count = 1, .last_activity_kind = .command };
    ctx.model_query_active = true;
    ctx.skills_menu = .{ .items = &skills };

    try h.shell.initViewport(&h.metrics, 15);
    try renderTestFooterWithContext(&h, &approval, &frame_redraw, ctx);
    try h.flush();

    try expectGridContains(&h, "/model");
    try expectGridNotContains(&h, "model-helper");
}

test "footer keeps file picker suppressed while stream is active" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "@sr");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    var frame_redraw = true;
    var ctx = defaultFooterContext(&input);
    ctx.stream = .{ .active = true, .command_count = 1, .last_activity_kind = .command };
    ctx.file_query_active = true;
    ctx.file_completions = &.{.{ .path = "src/main.zig", .kind = .file, .matched_spans = &.{} }};
    ctx.file_completion_anchor = 0;

    try h.shell.initViewport(&h.metrics, 15);
    try renderTestFooterWithContext(&h, &approval, &frame_redraw, ctx);
    try h.flush();

    try expectGridContains(&h, "@sr");
    try expectGridNotContains(&h, "src/main.zig");
}

test "typed file picker survives one hundred tiny and wide resize oscillations with selection intact" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    try input.edit_state.input.appendSlice(alloc, "@tail");
    input.edit_state.cursor = input.edit_state.input.items.len;

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    const file_index = @import("../core/workspace/file_index.zig");
    const combining_path = "docs/Cafe\u{0301}-tail.txt";
    const combining_start = std.mem.find(u8, combining_path, "e").?;
    const combining_spans = [_]file_index.MatchSpan{.{
        .byte_start = @intCast(combining_start),
        .byte_end = @intCast(combining_start + "e\u{0301}".len),
    }};
    const completions = [_]file_index.SearchResult{
        .{ .path = "first/very-long-shared-prefix-tail-alpha.zig", .kind = .file, .matched_spans = &.{} },
        .{ .path = combining_path, .kind = .file, .matched_spans = &combining_spans },
        .{ .path = "emoji/界-tail-wide.txt", .kind = .file, .matched_spans = &.{} },
        .{ .path = "deep/尾-tail-dir", .kind = .directory, .matched_spans = &.{} },
    };

    var frame_redraw = true;
    var ctx = defaultFooterContext(&input);
    ctx.file_query_active = true;
    ctx.file_completions = &completions;
    ctx.file_completion_index = completions.len - 1;
    ctx.file_completion_window_start = completions.len - 1;
    ctx.file_completion_anchor = 0;

    try h.shell.initViewport(&h.metrics, 15);
    for (0..100) |cycle| {
        const dims: struct { cols: u16, rows: u16 } = switch (cycle % 3) {
            0 => .{ .cols = 20, .rows = 8 },
            1 => .{ .cols = 42, .rows = 14 },
            else => .{ .cols = 160, .rows = 60 },
        };
        try h.driveResize(dims.cols, dims.rows, 4, true);
        frame_redraw = true;
        try renderTestFooterWithContext(&h, &approval, &frame_redraw, ctx);
        try h.flush();
        try expectGridContains(&h, "@tail");
        try expectGridContains(&h, "tail");
    }

    try h.driveResize(160, 60, 4, true);
    frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &frame_redraw, ctx);
    try h.flush();
    try expectGridContains(&h, "deep/尾-tail-dir/");
    try std.testing.expectEqual(@as(usize, 3), ctx.file_completion_index);
    try std.testing.expectEqual(@as(usize, 3), ctx.file_completion_window_start);
}

test "approval footer growth preserves raw status row over stale footer frame" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 30, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    var frame_redraw = true;

    try h.shell.initViewport(&h.metrics, 15);

    try renderTestFooter(&h, &input, &approval, &frame_redraw);
    try h.flush();

    const status_row = h.shell.cursor_row;
    try std.testing.expectEqual(status_row, h.shell.footer_viewport.geometry.top);

    const status_line = "\xe2\x96\xb8 Loading skill next-best-practices";
    _ = try h.shell.appendRawTranscriptEntry(alloc, status_line ++ "\n");
    _ = try approval.syncRequest(alloc, .{ .label = "skill next-best-practices" });

    // Footer growth follows transcript paint; its stale clear must preserve the status row.
    try renderTestFooter(&h, &input, &approval, &frame_redraw);
    try h.flush();

    try expectGridContains(&h, "Would you like to run this skill?");
    try expectGridContains(&h, "Reason:");
    try expectGridContains(&h, "1. Yes");
    try expectGridContains(&h, "2. Yes, and don't ask again");
    try expectGridContains(&h, "3. No");
    try expectGridContains(&h, status_line);
}

const approval_scrollback_transcript =
    "APPROVAL_SCROLLBACK_01\nAPPROVAL_SCROLLBACK_02\nAPPROVAL_SCROLLBACK_03\n" ++
    "APPROVAL_SCROLLBACK_04\nAPPROVAL_SCROLLBACK_05\nAPPROVAL_SCROLLBACK_06\n" ++
    "APPROVAL_SCROLLBACK_07\nAPPROVAL_SCROLLBACK_08\nAPPROVAL_SCROLLBACK_09\n" ++
    "APPROVAL_SCROLLBACK_10\nAPPROVAL_SCROLLBACK_11\nAPPROVAL_SCROLLBACK_12\n" ++
    "APPROVAL_SCROLLBACK_13\nAPPROVAL_SCROLLBACK_14\nAPPROVAL_SCROLLBACK_15\n" ++
    "APPROVAL_SCROLLBACK_16\nAPPROVAL_SCROLLBACK_17\nAPPROVAL_SCROLLBACK_18\n" ++
    "APPROVAL_SCROLLBACK_19\nAPPROVAL_SCROLLBACK_20\nAPPROVAL_SCROLLBACK_21\n" ++
    "APPROVAL_SCROLLBACK_22\nAPPROVAL_SCROLLBACK_23\nAPPROVAL_SCROLLBACK_24\n" ++
    "APPROVAL_SCROLLBACK_25\nAPPROVAL_SCROLLBACK_26\nAPPROVAL_SCROLLBACK_27\n" ++
    "APPROVAL_SCROLLBACK_28\nAPPROVAL_SCROLLBACK_29\nAPPROVAL_SCROLLBACK_30\n" ++
    "APPROVAL_SCROLLBACK_31\nAPPROVAL_SCROLLBACK_32\nAPPROVAL_SCROLLBACK_33\n" ++
    "APPROVAL_SCROLLBACK_34\nAPPROVAL_SCROLLBACK_35\nAPPROVAL_SCROLLBACK_36\n" ++
    "APPROVAL_SCROLLBACK_37\nAPPROVAL_SCROLLBACK_38\nAPPROVAL_SCROLLBACK_39\n" ++
    "APPROVAL_SCROLLBACK_40\n";

test "compact command completion keeps restored history footer stable" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 173, 39, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.appendRawTranscriptEntry(alloc, "history\n" ** 30);
    const id = types.ToolLifecycleId{ .turn_id = 1, .call_id = "command" };
    _ = try h.shell.applyToolLifecycle(alloc, .{ .authoritative_started = .{
        .id = id,
        .reconciles_provisional_call_id = null,
        .tool_name = "run_command",
        .activity_kind = .command,
        .arguments_json = "{\"command\":\"sleep 5\"}",
    } });
    try std.testing.expect(try approval.syncRequest(alloc, .{
        .label = "terminal.exec sleep 5",
        .command = "sleep 5",
    }));

    var ctx = defaultFooterContext(&input);
    ctx.stream.active = true;
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();
    approval.clear(alloc);
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const running_row = try findRowContaining(&h, "run_command");
    const running_thinking_row = try findRowContaining(&h, "Thinking");
    const running_footer_row = try findFirstDividerRowAfter(&h, running_thinking_row);
    try std.testing.expect(h.shell.transcriptCommitDiagnostic().visual_offset > 0);
    try expectExactlyOneBlankRowBetween(&h, running_row, running_thinking_row);
    try expectExactlyOneBlankRowBetween(&h, running_thinking_row, running_footer_row);

    _ = try h.shell.applyToolLifecyclePreservingNormalBufferAnchor(alloc, .{ .terminal = .{
        .id = id,
        .outcome = .{ .kind = .completed, .summary = "Ran sleep 5" },
        .result = "",
    } });
    h.frame_redraw = true;
    try renderTestFooterWithContext(&h, &approval, &h.frame_redraw, ctx);
    try h.flush();

    const completed_row = try findRowContaining(&h, "Ran sleep 5");
    const completed_thinking_row = try findRowContaining(&h, "Thinking");
    const completed_footer_row = try findFirstDividerRowAfter(&h, completed_thinking_row);
    try std.testing.expectEqual(running_row, completed_row);
    try std.testing.expectEqual(running_thinking_row, completed_thinking_row);
    try std.testing.expectEqual(running_footer_row, completed_footer_row);
    try expectExactlyOneBlankRowBetween(&h, completed_row, completed_thinking_row);
    try expectExactlyOneBlankRowBetween(&h, completed_thinking_row, completed_footer_row);
}

test "inline approval footer reflow replays displaced transcript history" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 120, 36, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.appendRawTranscriptEntry(
        alloc,
        approval_scrollback_transcript,
    );
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const transcript_before = try alloc.dupe(u8, h.shell.transcript.items);
    defer alloc.free(transcript_before);
    const idle_footer_top = h.shell.committed_frame_layout.footer_area.top;
    const idle_footer_extra = h.shell.extra_input_rows;
    const idle_footer_base_rows = h.shell.footer_reserved_base_rows;

    try std.testing.expect(try approval.syncRequest(alloc, .{
        .label = "terminal.exec printf approval-scrollback",
        .command = "printf approval-scrollback",
    }));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(h.shell.committed_frame_layout.footer_area.top < idle_footer_top);
    try std.testing.expect(
        h.shell.extra_input_rows != idle_footer_extra or
            h.shell.footer_reserved_base_rows != idle_footer_base_rows,
    );
    try expectGridContains(&h, "Would you like to run the following command?");
    try std.testing.expectEqualStrings(transcript_before, h.shell.transcript.items);
    const footer_history_rows = h.last_frame.planned_scroll_rows;
    try std.testing.expect(footer_history_rows > 0);
    try std.testing.expectEqual(footer_history_rows, h.last_frame.committed_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expect(h.last_frame.document_append_bytes > 0);
    try std.testing.expectEqual(
        @as(?u16, footer_history_rows),
        h.last_frame.document_append_clear_rows,
    );

    approval.clear(alloc);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqualStrings(transcript_before, h.shell.transcript.items);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.committed_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        h.last_frame.shadow_state,
    );
    try std.testing.expectEqual(idle_footer_extra, h.shell.extra_input_rows);
    try std.testing.expectEqual(idle_footer_base_rows, h.shell.footer_reserved_base_rows);
    try expectGridNotContains(&h, "Would you like to run the following command?");
}

test "footer reflow rebases a same-height transcript rewrite without history scroll" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 120, 36, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.appendRawTranscriptEntry(
        alloc,
        approval_scrollback_transcript,
    );
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    var source = try h.shell.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    source.bytes[0] = 'R';

    var reduced_area = h.shell.committed_frame_layout.transcript_area;
    reduced_area.bottom -|= 8;
    var prepared = try h.shell.prepareTranscriptSurfacePaintFromSourceForFrame(
        alloc,
        &h.metrics,
        &source,
        reduced_area,
        true,
    );
    defer prepared.deinit(alloc);

    const facts = h.shell.planTranscriptScrollForFrame(&prepared, true, true);
    try std.testing.expect(!facts.source_compatible);
    try std.testing.expect(facts.geometry_rebase);
    try std.testing.expectEqual(@as(u32, 0), facts.semantic_rows);
    try std.testing.expectEqual(@as(u16, 0), facts.planned_rows);
}

test "footer reflow replays an unchanged displaced prefix across a later rewrite" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 120, 36, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.appendRawTranscriptEntry(
        alloc,
        approval_scrollback_transcript,
    );
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    var source = try h.shell.prepareTranscriptSource(alloc, null);
    defer source.deinit(alloc);
    var reduced_area = h.shell.committed_frame_layout.transcript_area;
    reduced_area.bottom -|= 8;

    const replay_flow_end = replay_boundary: {
        var compatible = try h.shell.prepareTranscriptSurfacePaintFromSourceForFrame(
            alloc,
            &h.metrics,
            &source,
            reduced_area,
            true,
        );
        defer compatible.deinit(alloc);
        const compatible_facts = h.shell.planTranscriptScrollForFrame(
            &compatible,
            true,
            true,
        );
        break :replay_boundary transcript_painter.preparedTranscriptFlowOffsetForVisualOffset(
            &compatible,
            h.shell.layout.cols,
            compatible_facts.target_visual_offset,
        ) orelse return error.TestMissingReplayBoundary;
    };

    var rewrite_offset = replay_flow_end;
    while (rewrite_offset < source.bytes.len) : (rewrite_offset += 1) {
        const byte = source.bytes[rewrite_offset];
        if ((byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z')) break;
    }
    if (rewrite_offset == source.bytes.len) return error.TestMissingRewriteByte;
    source.bytes[rewrite_offset] = if (source.bytes[rewrite_offset] == 'Z') 'Y' else 'Z';

    var prepared = try h.shell.prepareTranscriptSurfacePaintFromSourceForFrame(
        alloc,
        &h.metrics,
        &source,
        reduced_area,
        true,
    );
    defer prepared.deinit(alloc);

    const facts = h.shell.planTranscriptScrollForFrame(&prepared, true, true);
    try std.testing.expect(!facts.source_compatible);
    try std.testing.expect(facts.geometry_rebase);
    try std.testing.expect(facts.semantic_rows > 0);
    try std.testing.expect(facts.planned_rows > 0);
}

test "inline approval footer reflow preserves concurrent transcript progress" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 20, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.streamAssistantChunk(
        alloc,
        &h.metrics,
        approval_scrollback_transcript,
    );
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const idle_footer_top = h.shell.committed_frame_layout.footer_area.top;
    const append_one = "APPROVAL_MIXED_APPEND_01";
    const append_two = "APPROVAL_MIXED_APPEND_02";
    try std.testing.expect(try approval.syncRequest(alloc, .{
        .label = "terminal.exec printf approval-mixed",
        .command = "printf approval-mixed",
    }));
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(h.shell.committed_frame_layout.footer_area.top < idle_footer_top);
    const footer_history_rows =
        idle_footer_top - h.shell.committed_frame_layout.footer_area.top;
    try std.testing.expectEqual(footer_history_rows, h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(footer_history_rows, h.last_frame.committed_scroll_rows);
    try std.testing.expect(h.last_frame.document_append_bytes > 0);
    try std.testing.expectEqual(
        @as(?u16, footer_history_rows),
        h.last_frame.document_append_clear_rows,
    );
    _ = try h.shell.streamAssistantChunk(
        alloc,
        &h.metrics,
        append_one ++ "\n" ++ append_two ++ "\n",
    );
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    // The assistant producer is still open, so the streamed rows are not
    // final: the viewport follows them through an in-place repaint and no
    // transcript row is released into scrollback.
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.committed_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, h.shell.transcript.items, append_one),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, h.shell.transcript.items, append_two),
    );
    try std.testing.expectEqual(@as(usize, 1), try countGridOccurrences(&h, append_one));
    try std.testing.expectEqual(@as(usize, 1), try countGridOccurrences(&h, append_two));

    // Closing the producer finalizes the tail; the held rows settle through
    // the catch-up replay, possibly across frames.
    h.shell.transcript_release = h.shell.transcript_release.with_assistant_tail_writable(false);
    var settle_frames: usize = 0;
    var settled_scroll_rows: u32 = 0;
    while (settle_frames < 8) : (settle_frames += 1) {
        h.frame_redraw = true;
        try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
        try h.flush();
        try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
        if (h.last_frame.planned_scroll_rows == 0) break;
        settled_scroll_rows += h.last_frame.planned_scroll_rows;
    }
    try std.testing.expect(settled_scroll_rows > 0);
    try std.testing.expectEqual(@as(usize, 1), try countGridOccurrences(&h, append_one));
    try std.testing.expectEqual(@as(usize, 1), try countGridOccurrences(&h, append_two));

    approval.clear(alloc);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.committed_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        h.last_frame.shadow_state,
    );
    try std.testing.expect(h.last_frame.transcript_history_floor_respected);
    try std.testing.expect(h.shell.committed_frame_layout.footer_area.top < idle_footer_top);
    try std.testing.expectEqual(
        h.shell.last_visible_transcript_last_row + 2,
        h.shell.committed_frame_layout.footer_area.top,
    );
    try std.testing.expectEqual(@as(usize, 1), try countGridOccurrences(&h, append_one));
    try std.testing.expectEqual(@as(usize, 1), try countGridOccurrences(&h, append_two));
}

test "slash picker release keeps concurrent transcript progress single-painted" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 120, 36, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.streamAssistantChunk(
        alloc,
        &h.metrics,
        approval_scrollback_transcript,
    );
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const idle_footer_top = h.shell.committed_frame_layout.footer_area.top;

    try input.edit_state.input.appendSlice(alloc, "/");
    input.edit_state.cursor = input.edit_state.input.items.len;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expect(h.shell.committed_frame_layout.footer_area.top < idle_footer_top);
    const picker_anchor = h.shell.stableTranscriptProjectionForFlow(
        h.shell.transcript.items,
    ) orelse return error.TestExpectedStableTranscript;

    const append_one = "SLASH_RELEASE_APPEND_01";
    const append_two = "SLASH_RELEASE_APPEND_02";
    _ = try h.shell.streamAssistantChunk(
        alloc,
        &h.metrics,
        append_one ++ "\n" ++ append_two ++ "\n",
    );
    input.inputResetState().clearCurrent(alloc);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.committed_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expectEqual(@as(usize, 0), h.last_frame.document_append_bytes);
    const dismissed_anchor = h.shell.stableTranscriptProjectionForFlow(
        h.shell.transcript.items,
    ) orelse return error.TestExpectedStableTranscript;
    try std.testing.expect(
        dismissed_anchor.history_visual_offset >= picker_anchor.history_visual_offset,
    );
    try std.testing.expect(h.shell.committed_frame_layout.footer_area.top < idle_footer_top);
    try std.testing.expectEqual(
        h.shell.last_visible_transcript_last_row + 2,
        h.shell.committed_frame_layout.footer_area.top,
    );
    try std.testing.expectEqual(@as(usize, 1), try countGridOccurrences(&h, append_one));
    try std.testing.expectEqual(@as(usize, 1), try countGridOccurrences(&h, append_two));
}

test "slash picker release does not scroll transcript growth that still fits" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 120, 36, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscriptBytes(alloc, &h.metrics, "FIT_RELEASE_BASE\n", true);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try input.edit_state.input.appendSlice(alloc, "/");
    input.edit_state.cursor = input.edit_state.input.items.len;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const append_one = "FIT_RELEASE_APPEND_01";
    const append_two = "FIT_RELEASE_APPEND_02";
    try h.shell.writeTranscriptBytes(
        alloc,
        &h.metrics,
        append_one ++ "\n" ++ append_two ++ "\n",
        true,
    );
    input.inputResetState().clearCurrent(alloc);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.committed_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expectEqual(@as(usize, 0), h.last_frame.document_append_bytes);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, h.shell.transcript.items, append_one),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, h.shell.transcript.items, append_two),
    );
}

test "replaceable line survives a replay_viewport pass" {
    var h = try Harness.init(std.testing.allocator, 40, 12, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 6);
    try h.shell.writeTranscript(h.alloc, &h.metrics, "start\n", true);
    _ = try h.shell.appendReplaceableTranscriptLine(h.alloc, &h.metrics, "progress one\n");
    try h.flush();

    try h.driveResize(40, 10, 4, true);

    try std.testing.expect(
        try h.shell.replaceTrailingTranscriptLine(h.alloc, &h.metrics, "progress two\n"),
    );
    try std.testing.expectEqualStrings(
        "start\n\nprogress two\n",
        h.shell.transcript.items,
    );
}

test "settled resize reanchors viewport_top_row at row one" {
    var h = try Harness.init(std.testing.allocator, 40, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 8);
    try std.testing.expectEqual(@as(u16, 8), h.shell.viewport_top_row);

    try h.driveResize(40, 22, 4, true);
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
}

test "grow after shrink-overflow restores transcript inside fx's viewport band" {
    var h = try Harness.init(std.testing.allocator, 80, 30, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(h.alloc, &h.metrics, "header one\nheader two\nheader three\n", true);
    try h.flush();

    try h.driveResize(80, 7, 4, true);

    try h.driveResize(80, 30, 4, true);

    try expectRowPrefix(&h, 1, "header one");
    try expectRowPrefix(&h, 2, "header two");
    try expectRowPrefix(&h, 3, "header three");
}

test "large transcript preserves direct append across shrink grow and footer settle" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 120, 34, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    const fixture = try buildLargeSkillListFixture(alloc, 72);
    defer alloc.free(fixture);

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(alloc, &h.metrics, fixture, true);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        h.shell.transcriptCommitDiagnostic().state,
    );

    try h.vt.resize(70, 24);
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(70, 24, 4),
        true,
    );
    h.shell.resize_history_row_delta = 6;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expect(h.last_frame.committed_scroll_rows > 0);
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        h.shell.transcriptCommitDiagnostic().state,
    );
    h.shell.resize_history_row_delta = null;

    try h.vt.resize(120, 34);
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(120, 34, 4),
        true,
    );
    h.shell.resize_history_row_delta = 0;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    h.shell.resize_history_row_delta = null;

    const before_settle = h.shell.stableTranscriptProjectionForFlow(
        h.shell.transcript.items,
    ) orelse return error.TestExpectedStableTranscript;
    const before_layout_id = h.shell.transcriptCommitDiagnostic().layout_id;
    h.shell.render_requests.request(.footer);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expectEqual(TestBodyDisposition.retain, h.last_frame.body_disposition);
    try std.testing.expectEqual(@as(usize, 0), h.last_frame.body_paints);
    try std.testing.expectEqual(
        @as(usize, 0),
        h.last_frame.retained_transcript_changed_cells,
    );
    try std.testing.expectEqual(@as(usize, 0), h.last_frame.document_append_bytes);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.committed_scroll_rows);
    try std.testing.expectEqual(@as(usize, 0), h.last_frame.changed_cells);

    const after_settle = h.shell.stableTranscriptProjectionForFlow(
        h.shell.transcript.items,
    ) orelse return error.TestExpectedStableTranscript;
    try std.testing.expectEqualDeep(before_settle.selection, after_settle.selection);
    try std.testing.expectEqual(before_settle.visual_offset, after_settle.visual_offset);
    try std.testing.expectEqual(before_settle.total_visual_rows, after_settle.total_visual_rows);
    try std.testing.expectEqual(before_settle.cursor_row, after_settle.cursor_row);
    try std.testing.expectEqual(before_settle.cursor_col, after_settle.cursor_col);
    try std.testing.expectEqual(before_settle.occupied_last_row, after_settle.occupied_last_row);
    try std.testing.expectEqual(
        before_settle.occupied_last_row_blank,
        after_settle.occupied_last_row_blank,
    );
    try std.testing.expect(h.shell.transcriptCommitDiagnostic().layout_id >= before_layout_id);

    try h.shell.writeTranscript(alloc, &h.metrics, fixture, true);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try std.testing.expect(h.last_frame.document_append_bytes > 0);
    try std.testing.expect(h.last_frame.planned_scroll_rows > 0);
    try std.testing.expectEqual(
        h.last_frame.planned_scroll_rows,
        h.last_frame.committed_scroll_rows,
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        h.last_frame.shadow_state,
    );
    try std.testing.expectEqual(
        transcript_runtime.TranscriptCommitDiagnosticState.stable,
        h.shell.transcriptCommitDiagnostic().state,
    );
    try std.testing.expect(h.shell.footer_viewport.has_frame);
    try expectCommittedFooterContains(&h, "test-model");
}

test "rapid settled resizes retain the four-skill transcript" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 120, 34, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    const fixture = try buildLargeSkillListFixture(alloc, 4);
    defer alloc.free(fixture);

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "history 00\nhistory 01\nhistory 02\nhistory 03\nhistory 04\nhistory 05\n" ++
            "history 06\nhistory 07\nhistory 08\nhistory 09\nhistory 10\nhistory 11\n" ++
            "history 12\nhistory 13\nhistory 14\nhistory 15\n",
        true,
    );
    try h.shell.writeTranscript(alloc, &h.metrics, fixture, true);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    try h.vt.resize(70, 24);
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(70, 24, 4),
        true,
    );
    h.shell.resize_history_row_delta = 3;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try std.testing.expect(!h.shell.terminal_reset_pending);

    try h.vt.resize(120, 34);
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(120, 34, 4),
        true,
    );
    h.shell.resize_history_row_delta = 0;
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try std.testing.expect(!h.shell.terminal_reset_pending);

    h.shell.resize_history_row_delta = null;
    try h.shell.writeTranscript(alloc, &h.metrics, fixture, true);
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    if (h.last_frame.document_append_bytes == 0) {
        return error.TestExpectedDirectDocumentAppend;
    }
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, h.shell.transcript.items, "Visible skills (4):"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, h.shell.transcript.items, "Managed installs (4):"),
    );
    for (0..4) |index| {
        var marker_buf: [32]u8 = undefined;
        const skill_marker = try std.fmt.bufPrint(
            &marker_buf,
            "skill-{d:0>3}:",
            .{index},
        );
        try std.testing.expectEqual(
            @as(usize, 2),
            std.mem.count(u8, h.shell.transcript.items, skill_marker),
        );
    }
    try std.testing.expectEqual(
        h.last_frame.planned_scroll_rows,
        h.last_frame.committed_scroll_rows,
    );
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        h.last_frame.shadow_state,
    );
}

test "settled resize clears pre-fx shell history and reanchors at row one" {
    var h = try Harness.init(std.testing.allocator, 40, 20, 4);
    defer h.deinit();

    try h.vt.feed("\x1b[1;1H");
    try h.vt.feed("$ ls\n");
    try h.vt.feed("README.md  src  tests\n");
    try h.vt.feed("$ fx\n");

    try h.shell.initViewport(&h.metrics, 4);
    try h.shell.writeTranscript(h.alloc, &h.metrics, "first fx line\nsecond fx line\n", true);
    try h.flush();

    try h.driveResize(40, 24, 4, true);
    try h.driveResize(40, 16, 4, true);

    try expectGridNotContains(&h, "$ ls");
    try expectGridNotContains(&h, "README.md  src  tests");
    try expectGridNotContains(&h, "$ fx");
    try std.testing.expectEqual(@as(u16, 1), h.shell.owned_top_row);
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try expectRowPrefix(&h, 1, "first fx line");
    try expectRowPrefix(&h, 2, "second fx line");
}

test "settled width resize clears pre-fx shell rows and reanchors at row one" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.vt.feed("\x1b[1;1H");
    try h.vt.feed("$ git status\n");
    try h.vt.feed("On branch feature\n");
    try h.vt.feed("$ fx\n");

    try h.shell.initViewport(&h.metrics, 4);
    try h.shell.writeTranscript(alloc, &h.metrics, "first fx line\nsecond fx line\n", true);
    try h.flush();

    const before = try h.file.length(io_mod.getIo());
    try h.driveResize(40, 24, 4, true);
    const emitted = try readEmittedSince(&h, before);
    defer alloc.free(emitted);

    try expectGridNotContains(&h, "$ git status");
    try expectGridNotContains(&h, "On branch feature");
    try expectGridNotContains(&h, "$ fx");
    try std.testing.expectEqual(@as(u16, 1), h.shell.owned_top_row);
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try std.testing.expect(std.mem.find(u8, emitted, "\x1b[3J") != null);
}

test "visual epoch reset reanchors at row one and preserves viewport reservation" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewportWithReservedRows(&h.metrics, 6, 7);
    try h.shell.writeTranscript(alloc, &h.metrics, "old visual epoch\n", true);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const min_rows = h.shell.min_visible_viewport_rows;
    const before = try h.file.length(io_mod.getIo());

    try h.shell.resetVisualEpoch(alloc, "welcome after clear\n");
    try h.shell.requestTerminalReset(&h.metrics);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const emitted = try readEmittedSince(&h, before);
    defer alloc.free(emitted);
    try std.testing.expectEqual(min_rows, h.shell.min_visible_viewport_rows);
    try std.testing.expectEqual(@as(u16, 1), h.shell.owned_top_row);
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try std.testing.expect(!h.shell.terminal_reset_pending);
    try std.testing.expect(std.mem.find(u8, emitted, "\x1b[3J") != null);
    try expectGridContains(&h, "welcome after clear");
    try expectGridNotContains(&h, "old visual epoch");
}

test "multi-row replaceable line clears every old visual row on replace" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 40, 12, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 2);
    try h.shell.writeTranscript(alloc, &h.metrics, "header\n", true);
    _ = try h.shell.appendReplaceableTranscriptLine(alloc, &h.metrics, "line-alpha\nline-beta\nline-gamma\n");
    try h.flush();

    _ = try h.shell.replaceTrailingTranscriptLine(alloc, &h.metrics, "done\n");
    try h.flush();

    try std.testing.expectEqualStrings("header\ndone\n", h.shell.transcript.items);

    var r: u16 = 1;
    while (r <= h.vt.rows) : (r += 1) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try h.vt.rowText(r, &buf);
        if (std.mem.find(u8, buf.items, "line-beta") != null) {
            std.debug.print("orphan on row {d}: '{s}'\n", .{ r, buf.items });
            return error.ReplaceableOrphanBeta;
        }
        if (std.mem.find(u8, buf.items, "line-gamma") != null) {
            std.debug.print("orphan on row {d}: '{s}'\n", .{ r, buf.items });
            return error.ReplaceableOrphanGamma;
        }
    }
}

test "shrink preserves wrapped line content across visual rows" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 20, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(
        alloc,
        &h.metrics,
        "AAAAAAAAAA BBBBBBBBBB CCCCCCCCCC DDDDDDDDDD EEEEE\n",
        true,
    );
    try h.flush();

    try h.driveResize(40, 20, 4, true);

    var found_head = false;
    var found_tail = false;
    var r: u16 = 1;
    while (r <= h.shell.layout.content_bottom) : (r += 1) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try h.vt.rowText(r, &buf);
        if (std.mem.find(u8, buf.items, "AAAAAAAAAA") != null) found_head = true;
        if (std.mem.find(u8, buf.items, "EEEEE") != null) found_tail = true;
    }
    try std.testing.expect(found_head);
    try std.testing.expect(found_tail);
}

test "compact file diffs retain their gutter and color after resize" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 86, 22, 4);
    defer h.deinit();

    const source =
        "\x1b]9050;23\x07" ++
        "\x1b[38;5;252m  │ 3 + MUTATION_NEW_MARKER with a deliberately long replacement value that must wrap correctly in the diff preview\x1b[0m\n" ++
        "\x1b]9051;23\x07";
    try h.shell.initViewport(&h.metrics, 1);
    _ = try h.shell.appendRawTranscriptEntryClassified(h.alloc, source, .diff_block);
    try h.renderTranscriptFrame();
    try h.flush();

    try h.driveResize(64, 22, 4, true);

    const addition_row = try findRowContaining(&h, "MUTATION_NEW_MARKER");
    try expectRowPrefix(&h, addition_row, "  │ 3 + ");
    try expectRowPrefix(&h, addition_row + 1, "  │     ");
    try expectGridContains(&h, "diff preview");
    const continuation = h.vt.cellAt(addition_row + 1, 9) orelse return error.TestMissingDiffContinuation;
    try std.testing.expect(continuation.style.fg.eql(.{ .indexed = 252 }));
}

test "replay_viewport wipes content below the viewport band" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 40, 12, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 2);
    try h.shell.writeTranscript(alloc, &h.metrics, "alpha\n", true);
    try h.flush();

    try h.vt.feed("\x1b[10;1Horphan_below_footer");

    try shell_runtime.requestRedraw(&h.shell, &h.metrics, .replay_viewport);
    try h.renderTranscriptFrame();
    try h.flush();

    try expectRowEmpty(&h, 10);
}

test "large tabbed user turn keeps frame scroll plan aligned" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 72, 16, 4);
    defer h.deinit();

    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    const raw_prompt =
        "\tTAB_START_0001\tquoted=\"value 1\"\tansi_like=\\x1b[32mgreen\\x1b[0m\n" ++
        "LONGTOKEN_" ++ ("X" ** 220) ++ "_0003\n" ++
        "    indented code block tok0 tok1 tok2 tok3 tok4 tok5 tok6 tok7 tok8 tok9 tok10 tok11\n" ++
        "Pathish ~/tmp/example/nested/nested/nested/nested/nested/nested/nested/nested/file_12.txt\n" ++
        "MARKER_0013 " ++ ("word " ** 24) ++ "word\n" ++
        "\tTAB_START_0015\tquoted=\"value 15\"\tansi_like=\\x1b[32mgreen\\x1b[0m\n" ++
        "\tTAB_START_0029\tquoted=\"value 29\"\tansi_like=\\x1b[32mgreen\\x1b[0m\n" ++
        "\tTAB_START_0043\tquoted=\"value 43\"\tansi_like=\\x1b[32mgreen\\x1b[0m\n" ++
        "\tTAB_START_0057\tquoted=\"value 57\"\tansi_like=\\x1b[32mgreen\\x1b[0m\n" ++
        "\tTAB_START_0071\tquoted=\"value 71\"\tansi_like=\\x1b[32mgreen\\x1b[0m\n" ++
        "\tTAB_START_0085\tquoted=\"value 85\"\tansi_like=\\x1b[32mgreen\\x1b[0m\n";
    try std.testing.expectEqual(@as(usize, 1003), raw_prompt.len);
    try std.testing.expectEqual(@as(usize, 21), std.mem.count(u8, raw_prompt, "\t"));

    try h.shell.initViewport(&h.metrics, 12);
    try h.shell.writeTranscript(alloc, &h.metrics, "What would you like fx to do?\n", true);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();

    const owned_prompt = try alloc.dupe(u8, std.mem.trim(u8, raw_prompt, " \t\r\n"));
    _ = try h.shell.appendUserTurnOwned(alloc, .{ .text = owned_prompt, .images = &.{} });

    h.frame_redraw = true;
    renderTestFooter(&h, &input, &approval, &h.frame_redraw) catch |err| {
        std.debug.print("large tabbed user turn frame failed: {s}\n", .{@errorName(err)});
        return err;
    };
    try h.flush();

    try std.testing.expect(h.last_frame.document_append_bytes > 0);
    try std.testing.expect(h.last_frame.planned_scroll_rows > 0);
    try std.testing.expectEqual(
        h.last_frame.planned_scroll_rows,
        h.last_frame.committed_scroll_rows,
    );
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.unplanned_scroll_rows);
    try std.testing.expectEqual(
        render_engine.terminal_diff.ShadowCommitState.committed,
        h.last_frame.shadow_state,
    );
    _ = try findRowContaining(&h, "TAB_START_0085");
    try std.testing.expectEqual(h.shell.committed_frame_layout.footer_area.top, try findFirstDividerRowAfter(&h, 1));
    try expectCommittedFooterContains(&h, "test-model");
}

test "paint regenerates user card bytes at current cols" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);

    const text = try alloc.dupe(
        u8,
        "this is a reasonably long user prompt that should wrap at a narrow width but not at a wide one",
    );
    _ = try h.shell.appendUserTurnOwned(alloc, .{ .text = text, .images = &.{} });

    try h.renderTranscriptFrame();
    try std.testing.expectEqual(@as(u16, 80), h.shell.last_rendered_cols);
    const wide_bytes = try alloc.dupe(u8, h.shell.transcript.items);
    defer alloc.free(wide_bytes);
    try std.testing.expect(wide_bytes.len > 0);

    h.shell.layout = layoutFor(30, 24, 4);
    try h.renderTranscriptFrame();
    try std.testing.expectEqual(@as(u16, 30), h.shell.last_rendered_cols);

    try std.testing.expect(!std.mem.eql(u8, wide_bytes, h.shell.transcript.items));
    try std.testing.expect(h.shell.transcript.items.len > wide_bytes.len);
}

test "paint regenerates assistant text with wraps at current cols" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);

    const assistant_id = try h.shell.appendAssistantTurnEntry(alloc);
    const segs = h.shell.lookupAssistantSegments(assistant_id) orelse unreachable;
    const body = "abcdefghijklmnopqrstuvwxyz0123456789" ** 4;
    try segs.text.appendSlice(alloc, body[0..120]);

    try h.renderTranscriptFrame();
    const wide_newlines = std.mem.count(u8, h.shell.transcript.items, "\n");
    try std.testing.expect(std.mem.startsWith(u8, h.shell.transcript.items, "  "));

    h.shell.layout = layoutFor(30, 24, 4);
    try h.renderTranscriptFrame();
    const narrow_newlines = std.mem.count(u8, h.shell.transcript.items, "\n");

    try std.testing.expect(narrow_newlines > wide_newlines);
    try std.testing.expect(std.mem.startsWith(u8, h.shell.transcript.items, "  "));
    var lines = std.mem.splitScalar(u8, h.shell.transcript.items, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 30);
    }
}

test "paint refreshes replaceable_start to trailing raw_bytes entry" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);

    const text = try alloc.dupe(u8, "user prompt before spinner");
    _ = try h.shell.appendUserTurnOwned(alloc, .{ .text = text, .images = &.{} });
    _ = try h.shell.appendReplaceableTranscriptLineSilent(alloc, "\x1b[38;5;245mspinner\n\x1b[0m");

    try h.renderTranscriptFrame();

    try std.testing.expect(h.shell.replaceable_last_line);
    try std.testing.expectEqualStrings(
        "\x1b[38;5;245mspinner\x1b[0m",
        h.shell.transcript.items[h.shell.replaceable_start..],
    );
}

fn readEmittedSince(h: *Harness, since_offset: u64) ![]u8 {
    const total = try h.file.length(io_mod.getIo());
    const want: usize = @intCast(total - since_offset);
    const buf = try h.alloc.alloc(u8, want);
    _ = try h.file.readPositionalAll(io_mod.getIo(), buf, since_offset);
    return buf;
}

fn gridContains(grid: Grid, needle: []const u8) !void {
    var row: u16 = 1;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(grid.alloc);

    while (row <= grid.rows) : (row += 1) {
        buf.clearRetainingCapacity();
        try grid.rowTextTrimmed(row, &buf);
        if (std.mem.find(u8, buf.items, needle) != null) return;
    }
    return error.TestMissingMarker;
}

test "mid-drag resize does not emit scrollback wipe" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(alloc, &h.metrics, "hello world\n", true);
    try h.flush();

    const before = try h.file.length(io_mod.getIo());
    try h.driveResize(40, 24, 4, false);
    const emitted = try readEmittedSince(&h, before);
    defer alloc.free(emitted);

    try std.testing.expect(std.mem.find(u8, emitted, "\x1b[3J") == null);
}

test "settled resize with rows-only change resets terminal scrollback" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(alloc, &h.metrics, "hello world\n", true);
    try h.flush();

    const before = try h.file.length(io_mod.getIo());
    try h.driveResize(80, 30, 4, true);
    const emitted = try readEmittedSince(&h, before);
    defer alloc.free(emitted);

    try std.testing.expectEqual(@as(u16, 1), h.shell.owned_top_row);
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try std.testing.expect(std.mem.find(u8, emitted, "\x1b[3J") != null);
}

test "theme reset retints fx entries and replays the retained transcript once" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    ui_render.initTheme(false, null);
    defer ui_render.initTheme(false, null);

    try h.shell.initViewportWithReservedRows(&h.metrics, 8, 5);
    _ = try h.shell.appendRawTranscriptEntryClassified(
        alloc,
        "\x1b[1;38;5;255mFX THEME HEADER\x1b[0m\n",
        .welcome,
    );
    _ = try h.shell.appendRawTranscriptEntryClassified(
        alloc,
        "\x1b[38;5;252mFX THEME TOOL\x1b[0m\n",
        .tool_status,
    );
    _ = try h.shell.appendRawTranscriptEntryClassified(
        alloc,
        "\x1b[38;5;252mEXTERNAL COMMAND COLOR\x1b[0m\n",
        .command_output,
    );
    const assistant_id = try h.shell.appendAssistantTurnEntry(alloc);
    const assistant = h.shell.lookupAssistantSegments(assistant_id) orelse unreachable;
    try assistant.text.appendSlice(alloc, "\x1b[38;5;245mFX THEME INLINE CODE\x1b[39m\n");

    try h.renderTranscriptFrame();
    try h.flush();
    const min_visible_rows = h.shell.min_visible_viewport_rows;
    const before = try h.file.length(io_mod.getIo());

    try h.shell.retintEntriesForTheme(alloc, false, true);
    try h.shell.requestTerminalReset(&h.metrics);
    try std.testing.expect(h.shell.terminal_reset_pending);
    try std.testing.expectEqual(min_visible_rows, h.shell.min_visible_viewport_rows);

    try h.renderTranscriptFrame();
    try h.flush();
    const emitted = try readEmittedSince(&h, before);
    defer alloc.free(emitted);

    try std.testing.expect(std.mem.indexOf(u8, emitted, "\x1b[3J") != null);
    try std.testing.expect(!h.shell.terminal_reset_pending);
    try std.testing.expectEqual(@as(u16, 1), h.shell.viewport_top_row);
    try std.testing.expectEqual(min_visible_rows, h.shell.min_visible_viewport_rows);
    try std.testing.expectEqualStrings(
        "\x1b[38;5;238mFX THEME TOOL\x1b[0m\n",
        h.shell.entries.items[1].raw_bytes.bytes,
    );
    try std.testing.expectEqualStrings(
        "\x1b[38;5;252mEXTERNAL COMMAND COLOR\x1b[0m\n",
        h.shell.entries.items[2].raw_bytes.bytes,
    );
    try std.testing.expectEqualStrings(
        "\x1b[38;5;247mFX THEME INLINE CODE\x1b[39m\n",
        h.shell.lookupAssistantSegments(assistant_id).?.text.items,
    );
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, h.shell.transcript.items, "FX THEME HEADER"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, h.shell.transcript.items, "FX THEME TOOL"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, h.shell.transcript.items, "FX THEME INLINE CODE"));
    try expectGridContains(&h, "FX THEME HEADER");
    try expectGridContains(&h, "tool activity");
    try expectGridContains(&h, "FX THEME INLINE CODE");
}

pub fn testReconstructiveFullTranscriptReplay() !void {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();
    var input = InputRuntime{};
    defer input.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);

    try h.shell.initViewport(&h.metrics, 1);
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(alloc);
    for (0..60) |index| {
        try transcript.print(
            alloc,
            "REPLAY-MARKER-{d:0>3} stretches beyond the terminal viewport\n",
            .{index},
        );
    }
    try h.shell.writeTranscript(alloc, &h.metrics, transcript.items, true);
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    try std.testing.expect(h.shell.last_viewport_selection.?.start_line > 0);

    const before = try h.file.length(io_mod.getIo());
    try h.vt.resize(40, 24);
    try shell_runtime.applyResizeWithLayout(
        &h.shell,
        &h.metrics,
        layoutFor(40, 24, 4),
        true,
    );
    h.frame_redraw = true;
    try renderTestFooter(&h, &input, &approval, &h.frame_redraw);
    try h.flush();
    const emitted = try readEmittedSince(&h, before);
    defer alloc.free(emitted);

    const first_marker = "REPLAY-MARKER-000";
    const middle_marker = "REPLAY-MARKER-030";
    const final_marker = "REPLAY-MARKER-059";
    const reset_idx = std.mem.find(u8, emitted, "\x1b[3J") orelse return error.TestMissingTerminalReset;
    const replay_origin_idx = std.mem.indexOfPos(
        u8,
        emitted,
        reset_idx,
        "\x1b[1;1H",
    ) orelse return error.TestMissingTopOriginReplay;
    const first_idx = std.mem.find(u8, emitted, first_marker) orelse return error.TestMissingFirstEntry;
    const middle_idx = std.mem.find(u8, emitted, middle_marker) orelse return error.TestMissingMiddleEntry;
    const final_idx = std.mem.find(u8, emitted, final_marker) orelse return error.TestMissingFinalEntry;

    // Limit uniqueness checks to the reconstructive replay, before the final-tail paint.
    const replay = emitted[first_idx .. final_idx + final_marker.len];
    try std.testing.expect(reset_idx < first_idx);
    try std.testing.expect(reset_idx < replay_origin_idx);
    try std.testing.expect(replay_origin_idx < first_idx);
    try std.testing.expect(first_idx < middle_idx);
    try std.testing.expect(middle_idx < final_idx);
    var replay_index: usize = 0;
    while (replay_index < replay.len) : (replay_index += 1) {
        if (replay[replay_index] == '\n') {
            try std.testing.expect(replay_index > 0 and replay[replay_index - 1] == '\r');
        }
    }
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, replay, first_marker));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, replay, middle_marker));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, replay, final_marker));
    try std.testing.expect(h.shell.last_viewport_selection.?.start_line > 0);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, emitted, first_marker));
    try std.testing.expectEqual(@as(u16, 0), h.last_frame.planned_scroll_rows);
    try std.testing.expect(h.last_frame.committed_scroll_rows > 0);
}

test "turn ordering produces user → assistant → user entries with monotonic ids" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);

    const text_a = try alloc.dupe(u8, "prompt A");
    const id_a = try h.shell.appendUserTurnOwned(alloc, .{ .text = text_a, .images = &.{} });

    const id_assistant = try h.shell.appendAssistantTurnEntry(alloc);
    const segs = h.shell.lookupAssistantSegments(id_assistant) orelse unreachable;
    try segs.text.appendSlice(alloc, "streaming response");

    const text_b = try alloc.dupe(u8, "prompt B");
    const id_b = try h.shell.appendUserTurnOwned(alloc, .{ .text = text_b, .images = &.{} });

    try std.testing.expectEqual(@as(usize, 3), h.shell.entries.items.len);
    try std.testing.expect(h.shell.entries.items[0] == .user_turn);
    try std.testing.expect(h.shell.entries.items[1] == .assistant_turn);
    try std.testing.expect(h.shell.entries.items[2] == .user_turn);

    try std.testing.expect(id_a < id_assistant);
    try std.testing.expect(id_assistant < id_b);
}

test "streaming paint produces a minimal delta on unchanged rows" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 80, 24, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeTranscript(alloc, &h.metrics, "first line\n", true);
    try h.shell.writeTranscript(alloc, &h.metrics, "second line\n", true);

    h.shell.transcript_band_dirty = true;
    try h.renderTranscriptFrameIfDirty();
    try h.flush();
    const baseline_end = try h.file.length(io_mod.getIo());

    try h.shell.writeTranscript(alloc, &h.metrics, "x", true);
    h.shell.transcript_band_dirty = true;
    try h.renderTranscriptFrameIfDirty();
    const delta_end = try h.file.length(io_mod.getIo());

    const delta_bytes: usize = @intCast(delta_end - baseline_end);
    try std.testing.expect(delta_bytes < 1024);
}

test "partial-tail emission fills top rows when an entry overflows the band" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 30, 10, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);

    const assistant_id = try h.shell.appendAssistantTurnEntry(alloc);
    const segs = h.shell.lookupAssistantSegments(assistant_id) orelse unreachable;
    const body = "abcdefghijklmnopqrstuvwxyz0123456789" ** 6;
    try segs.text.appendSlice(alloc, body[0..200]);

    try h.renderTranscriptFrame();
    try h.flush();

    var r: u16 = 1;
    var filled_rows: u16 = 0;
    while (r <= h.shell.layout.content_bottom) : (r += 1) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try h.vt.rowTextTrimmed(r, &buf);
        if (buf.items.len > 0) filled_rows += 1;
    }
    try std.testing.expect(filled_rows >= h.shell.layout.content_bottom - 1);
}

test "partial-tail emission drops SGR state from the oldest-visible line" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 30, 10, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);

    const line = "\x1b[1m" ++ ("X" ** 200) ++ "\x1b[0m\n";
    try h.shell.writeTranscript(alloc, &h.metrics, line, true);
    try h.flush();

    try h.renderTranscriptFrame();
    try h.flush();

    var filled_rows: u16 = 0;
    var r: u16 = 1;
    while (r <= h.shell.layout.content_bottom) : (r += 1) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try h.vt.rowTextTrimmed(r, &buf);
        if (std.mem.find(u8, buf.items, "X") != null) filled_rows += 1;
    }
    try std.testing.expect(filled_rows >= h.shell.layout.content_bottom - 1);

    const top_cell = h.vt.cellAt(1, 1) orelse {
        std.debug.print("expected cell at row 1 col 1\n", .{});
        return error.TestMissingTopCell;
    };
    try std.testing.expectEqual(@as(u21, 'X'), top_cell.codepoint);
    try std.testing.expect(!top_cell.style.flags.bold);
}

test "assistant text preserves SGR across wrap boundaries at narrow cols" {
    const alloc = std.testing.allocator;

    const input = "\x1b[1mHELLO WORLD THIS IS A LONG LINE\x1b[0m";
    const wrapped = try transcript_runtime.wrapAssistantText(alloc, input, 10);
    defer alloc.free(wrapped);

    var line_it = std.mem.splitScalar(u8, wrapped, '\n');
    var first = true;
    var wrapped_lines: usize = 0;
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        if (!first) {
            if (std.mem.find(u8, line, "\x1b[1m") == null) {
                std.debug.print("wrapped line missing bold reopen: '{s}'\n", .{line});
                return error.TestMissingBoldReopen;
            }
        }
        first = false;
        wrapped_lines += 1;
    }
    try std.testing.expect(wrapped_lines > 1);
}

test "narrow-drag resize pins overflowing content to content_bottom" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc, 120, 40, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);

    try h.shell.writeTranscript(alloc, &h.metrics, ("A" ** 3000) ++ "\n", true);
    try h.shell.writeTranscript(alloc, &h.metrics, ("B" ** 3000) ++ "\n", true);
    try h.shell.writeTranscript(alloc, &h.metrics, ("C" ** 3000) ++ "\n", true);
    try h.flush();

    try h.driveResize(30, 40, 4, true);

    const band_top: u16 = 1;
    const band_bot: u16 = h.shell.layout.content_bottom;

    var last_content: ?u16 = null;
    var r: u16 = band_top;
    while (r <= band_bot) : (r += 1) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try h.vt.rowTextTrimmed(r, &buf);
        if (buf.items.len > 0) last_content = r;
    }
    if (last_content) |last| {
        if (last + 1 < band_bot) {
            std.debug.print("content not pinned: last content row={d}, content_bottom={d} (gap of {d})\n", .{ last, band_bot, band_bot - last });
            return error.ContentNotPinnedToBottom;
        }
    } else {
        std.debug.print("no content in band after resize\n", .{});
        return error.NoVisibleContent;
    }

    var state: enum { pre_content, in_content, post_content } = .pre_content;
    r = band_top;
    while (r <= band_bot) : (r += 1) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(alloc);
        try h.vt.rowTextTrimmed(r, &buf);
        const has_content = buf.items.len > 0;
        switch (state) {
            .pre_content => if (has_content) {
                state = .in_content;
            },
            .in_content => if (!has_content) {
                state = .post_content;
            },
            .post_content => if (has_content) {
                std.debug.print("phantom blank-row check: content resumed at row {d} after blank gap\n", .{r});
                return error.PhantomBlankRow;
            },
        }
    }
}

test "external transcript mutator is rejected during paint" {
    var h = try Harness.init(std.testing.allocator, 40, 12, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 5);
    try h.shell.writeTranscript(h.alloc, &h.metrics, "hello world\n", true);

    h.shell.painting = true;
    defer h.shell.painting = false;

    try std.testing.expectError(
        error.PaintGuardViolated,
        h.shell.writeTranscript(h.alloc, &h.metrics, "late write\n", true),
    );
}

test "snapshot paint survives direct-backing mutation after snapshot" {
    var baseline = try Harness.init(std.testing.allocator, 40, 12, 4);
    defer baseline.deinit();

    try baseline.shell.initViewport(&baseline.metrics, 5);
    try baseline.shell.writeTranscript(baseline.alloc, &baseline.metrics, "hello world\n", true);
    try baseline.renderTranscriptFrameIfDirty();
    try baseline.flush();
    const expected_row = baseline.shell.cursor_row;
    const expected_col = baseline.shell.cursor_col;

    var h = try Harness.init(std.testing.allocator, 40, 12, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 5);
    try h.shell.writeTranscript(h.alloc, &h.metrics, "hello world\n", true);

    h.shell.paint_test_mode = .mutate_backing_after_snapshot;
    defer h.shell.paint_test_mode = .none;

    try h.renderTranscriptFrameIfDirty();
    try h.flush();

    try std.testing.expectEqual(expected_row, h.shell.cursor_row);
    try std.testing.expectEqual(expected_col, h.shell.cursor_col);
}

const CapacityWritePath = enum {
    write_transcript,
    append_replaceable,
    replace_trailing,
    entries_rebuild,
    reconstructive_paint,
};

fn prepareCapacityHarness() !Harness {
    var h = try Harness.init(std.testing.allocator, 40, 12, 4);
    h.shell.transcript.clearAndFree(h.alloc);
    h.shell.max_transcript_bytes = 8 * 1024;
    try h.shell.initBacking(h.alloc);
    return h;
}

fn assertCapacityInvariantUnderWrites(path: CapacityWritePath) !void {
    var h = try prepareCapacityHarness();
    defer h.deinit();

    const cap = h.shell.max_transcript_bytes;
    try h.shell.initViewport(&h.metrics, 5);
    try std.testing.expect(h.shell.transcript.capacity >= cap);
    const initial_capacity = h.shell.transcript.capacity;

    const chunk = "x" ** 512 ++ "\n";
    var i: usize = 0;
    while (i < cap * 10 / chunk.len) : (i += 1) {
        switch (path) {
            .write_transcript => try h.shell.writeTranscript(h.alloc, &h.metrics, chunk, true),
            .append_replaceable => _ = try h.shell.appendReplaceableTranscriptLineSilent(h.alloc, chunk),
            .replace_trailing => {
                if (i == 0) _ = try h.shell.appendReplaceableTranscriptLineSilent(h.alloc, chunk);
                _ = try h.shell.replaceTrailingTranscriptLineSilent(h.alloc, chunk);
            },
            .entries_rebuild => {
                try h.shell.writeTranscript(h.alloc, &h.metrics, chunk, true);
                try h.renderTranscriptFrameIfDirty();
            },
            .reconstructive_paint => {
                try h.shell.writeTranscript(h.alloc, &h.metrics, chunk, true);
                try h.shell.reconstructivePaint(h.alloc, &h.metrics);
                try h.flush();
            },
        }
        try std.testing.expectEqual(initial_capacity, h.shell.transcript.capacity);
        try std.testing.expect(h.shell.transcript.items.len <= cap);
    }
}

test "transcript capacity stable across writeTranscript" {
    try assertCapacityInvariantUnderWrites(.write_transcript);
}

test "transcript capacity stable across appendReplaceableTranscriptLine" {
    try assertCapacityInvariantUnderWrites(.append_replaceable);
}

test "transcript capacity stable across replaceTrailingTranscriptLine" {
    try assertCapacityInvariantUnderWrites(.replace_trailing);
}

test "transcript capacity stable across entries-rebuild paint path" {
    try assertCapacityInvariantUnderWrites(.entries_rebuild);
}

test "transcript capacity stable across reconstructivePaint" {
    try assertCapacityInvariantUnderWrites(.reconstructive_paint);
}

test "transcript handles oversized single write without underflow" {
    var h = try prepareCapacityHarness();
    defer h.deinit();

    const cap = h.shell.max_transcript_bytes;
    const oversized = try std.testing.allocator.alloc(u8, cap + 1024);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'y');

    _ = try h.shell.appendReplaceableTranscriptLineSilent(h.alloc, oversized);
    try std.testing.expectEqual(cap, h.shell.transcript.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.shell.replaceable_start);
    try std.testing.expect(h.shell.replaceable_start <= h.shell.transcript.items.len);
}

test "transcript oversized-write leaves cursor and viewport valid" {
    var h = try prepareCapacityHarness();
    defer h.deinit();

    const cap = h.shell.max_transcript_bytes;
    try h.shell.initViewport(&h.metrics, 5);
    try h.shell.writeTranscript(h.alloc, &h.metrics, "prefix line\n", true);

    const oversized = try std.testing.allocator.alloc(u8, cap + 1024);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'z');
    const raw_cut = oversized.len - cap;
    oversized[raw_cut + 50] = '\n';
    const expected_retained_len = oversized.len - (raw_cut + 51);

    try h.shell.writeTranscript(h.alloc, &h.metrics, oversized, true);
    try h.renderTranscriptFrameIfDirty();
    try h.flush();

    try std.testing.expect(h.shell.transcript.items.len <= cap);
    try std.testing.expectEqual(expected_retained_len, h.shell.transcript.items.len);
    try std.testing.expect(h.shell.cursor_row >= 1);
    try std.testing.expect(h.shell.cursor_row <= h.shell.layout.content_bottom);
    try std.testing.expect(h.shell.cursor_col >= 1);
    try std.testing.expect(h.shell.cursor_col <= h.shell.layout.cols);
    try std.testing.expect(h.shell.viewport_top_row >= 1);
    try std.testing.expect(h.shell.viewport_top_row <= h.shell.layout.content_bottom);
}

fn commandOutputStyles() transcript_runtime.Styles {
    return .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "",
        .dim_style = "",
        .red_style = "",
    };
}

fn commandOutputAnsiStyles() transcript_runtime.Styles {
    return .{
        .system_notice_label_style = "",
        .system_notice_text_style = "",
        .reset_style = "\x1b[0m",
        .dim_style = "\x1b[2m",
        .red_style = "\x1b[31m",
    };
}

fn expectGridOccurrenceCount(h: *Harness, needle: []const u8, expected: usize) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);

    var count: usize = 0;
    var r: u16 = 1;
    while (r <= h.vt.rows) : (r += 1) {
        buf.clearRetainingCapacity();
        try h.vt.rowText(r, &buf);

        var offset: usize = 0;
        while (offset < buf.items.len) {
            const rel = std.mem.find(u8, buf.items[offset..], needle) orelse break;
            count += 1;
            offset += rel + needle.len;
        }
    }

    if (count != expected) {
        std.debug.print("expected '{s}' {d} time(s), found {d}\n", .{ needle, expected, count });
        return error.TestUnexpectedGridText;
    }
}

test "orphan command output does not leak into current compact rows" {
    var h = try Harness.init(std.testing.allocator, 64, 16, 4);
    defer h.deinit();

    try h.shell.initViewport(&h.metrics, 1);
    try h.shell.writeCommandOutputChunk(h.alloc, &h.metrics, commandOutputStyles(), .stdout, "dedupe-command-row\n", true);
    try h.renderTranscriptFrameIfDirty();
    try h.flush();
    try expectGridOccurrenceCount(&h, "dedupe-command-row", 0);
    try std.testing.expectEqualStrings("dedupe-command-row", h.shell.command_output_blocks.items[0].lines.items[0].text);

    try h.shell.flushCommandOutputSummary(h.alloc, &h.metrics, commandOutputStyles(), true);
    try h.renderTranscriptFrameIfDirty();
    try h.flush();
    try expectGridOccurrenceCount(&h, "dedupe-command-row", 0);

    try shell_runtime.requestRedraw(&h.shell, &h.metrics, .replay_viewport);
    try h.renderTranscriptFrame();
    try h.flush();
    try h.driveResize(58, 16, 4, true);

    try expectGridOccurrenceCount(&h, "dedupe-command-row", 0);
}
