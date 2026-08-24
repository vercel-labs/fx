const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const record_tape = @import("../core/workspace/record_tape.zig");
const types = @import("../core/shared/types.zig");
const transcript_runtime = @import("transcript/runtime.zig");
const cursor_probe = @import("terminal/cursor_probe.zig");
const ui_terminal = @import("terminal/terminal.zig");
const paint_plan = @import("render_engine/paint_plan.zig");

const Layout = types.Layout;
const Metrics = types.Metrics;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const ResizeObservation = transcript_runtime.ResizeObservation;
const ResizeObservationPhase = transcript_runtime.ResizeObservationPhase;
const ResizeObservationResult = transcript_runtime.ResizeObservationResult;

pub const CursorPosition = cursor_probe.Position;

pub const FrameCommit = enum {
    none,
    light,
    reset,
};

pub const supports_resize_signal = switch (builtin.os.tag) {
    .linux,
    .plan9,
    .illumos,
    .netbsd,
    .openbsd,
    .haiku,
    .macos,
    .ios,
    .watchos,
    .tvos,
    .visionos,
    .dragonfly,
    .freebsd,
    .serenity,
    => true,
    else => false,
};

pub const ResizeApprovalInterlock = struct {
    const resize_pending_bit: u8 = 1 << 0;
    const affirmative_claimed_bit: u8 = 1 << 1;
    const clear_resize_pending_mask: u8 = ~resize_pending_bit;
    const clear_affirmative_claimed_mask: u8 = ~affirmative_claimed_bit;

    // The signal handler only sets resize_pending_bit; event-loop code owns all clears.
    state: std.atomic.Value(u8) = .init(0),

    pub fn noteResizeSignal(self: *ResizeApprovalInterlock) void {
        _ = self.state.fetchOr(resize_pending_bit, .monotonic);
    }

    pub fn takeResizePending(self: *ResizeApprovalInterlock) bool {
        const previous = self.state.fetchAnd(
            clear_resize_pending_mask,
            .acq_rel,
        );
        return previous & resize_pending_bit != 0;
    }

    pub fn claimAffirmative(self: *ResizeApprovalInterlock) bool {
        return self.state.cmpxchgStrong(
            0,
            affirmative_claimed_bit,
            .acq_rel,
            .acquire,
        ) == null;
    }

    pub fn releaseAffirmative(self: *ResizeApprovalInterlock) void {
        const previous = self.state.fetchAnd(
            clear_affirmative_claimed_mask,
            .release,
        );
        std.debug.assert(previous & affirmative_claimed_bit != 0);
    }

    pub fn resizePending(self: *const ResizeApprovalInterlock) bool {
        return self.state.load(.acquire) & resize_pending_bit != 0;
    }

    fn affirmativeClaimed(self: *const ResizeApprovalInterlock) bool {
        return self.state.load(.acquire) & affirmative_claimed_bit != 0;
    }
};

pub const RedrawMode = enum {
    resize_light,
    replay_viewport,
    reanchor_top,
};

test "resize pending wins before an affirmative claim" {
    var interlock = ResizeApprovalInterlock{};

    interlock.noteResizeSignal();

    try std.testing.expect(!interlock.claimAffirmative());
    try std.testing.expect(interlock.resizePending());
    try std.testing.expect(interlock.takeResizePending());
    try std.testing.expect(!interlock.resizePending());
}

test "affirmative claim preserves a later resize through release" {
    var interlock = ResizeApprovalInterlock{};

    try std.testing.expect(interlock.claimAffirmative());
    try std.testing.expect(interlock.affirmativeClaimed());
    interlock.noteResizeSignal();
    interlock.releaseAffirmative();

    try std.testing.expect(!interlock.affirmativeClaimed());
    try std.testing.expect(interlock.resizePending());
    try std.testing.expect(interlock.takeResizePending());
}

fn measuredCursorRowDelta(expected_row: u32, actual_row: u16) i32 {
    const expected: i64 = @intCast(expected_row);
    const actual: i64 = actual_row;
    return @intCast(std.math.clamp(
        expected - actual,
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
}

fn expectedResizeCursorRow(shell: *const TranscriptRuntime, new_layout: Layout) ?u32 {
    if (shell.owned_top_row != 1 or
        (new_layout.cols == shell.layout.cols and new_layout.rows == shell.layout.rows))
    {
        return null;
    }
    return shell.estimatedReflowedCursorRow(new_layout.cols);
}

pub fn requestRedraw(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    mode: RedrawMode,
) !void {
    debug_trace.logf("resize", "request_redraw mode={s} layout={d}x{d} viewport_top={d} content_bottom={d} cursor={d},{d}", .{ @tagName(mode), shell.layout.cols, shell.layout.rows, shell.viewport_top_row, shell.layout.content_bottom, shell.cursor_row, shell.cursor_col });
    switch (mode) {
        .resize_light, .replay_viewport => {
            if (shell.cursor_row > shell.layout.content_bottom) {
                shell.cursor_row = shell.layout.content_bottom;
            }
            shell.viewport_clear_pending = true;
            shell.markTranscriptDirty();
            if (mode == .replay_viewport) {
                shell.reserveVisibleViewportRows(shell.min_visible_viewport_rows);
            }
            shell.footer_viewport.invalidateAfterExternalClear();
            try recordOwnedBandInvalidation(shell, .resize);
        },
        .reanchor_top => try reanchorTopForFrame(shell, metrics),
    }
    shell.render_requests.request(.footer);
}

fn reanchorTopForFrame(shell: *TranscriptRuntime, metrics: *Metrics) !void {
    metrics.full_redraws += 1;
    shell.cursor_row = shell.owned_top_row;
    shell.cursor_col = 1;
    shell.viewport_top_row = shell.owned_top_row;
    shell.pending_scroll_compact = false;
    shell.invalidateTranscriptAnchor("reanchor_top_frame");
    shell.markTranscriptDirty();
    shell.footer_viewport.invalidateAfterExternalClear();
    try recordOwnedBandInvalidation(shell, .viewport_reanchor);
    debug_trace.logf(
        "frame_plan",
        "reanchor_top_frame_deferred owned_top={d} rows={d}",
        .{ shell.owned_top_row, shell.layout.rows },
    );
}

pub fn collectResizeFacts(
    terminal: anytype,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    probe: *cursor_probe.Parser,
    resize_interlock: *ResizeApprovalInterlock,
    footer_rows: u16,
    debounce_ms: i64,
    cursor_probe_allowed: bool,
) !void {
    const now = io_mod.milliTimestamp();

    if (supports_resize_signal or builtin.os.tag == .windows) {
        if (cursor_probe_allowed) resumeResizeCursorProbeAfterPaste(probe, now);
        switch (probe.poll(now)) {
            .none => {},
            .probe_timed_out => {
                debug_trace.logf("resize", "cursor_measure_failed err=Timeout", .{});
                finishPendingResizeProbe(shell, null);
            },
            .late_window_expired => {
                debug_trace.logf("resize", "cursor_measure_late_window_expired", .{});
            },
        }

        _ = admitResizeSignal(
            shell,
            resize_interlock,
            now,
            debounce_ms,
            "facts",
        );

        if (resizeObservationAwaiting(shell.pending_resize_observation)) return;

        if (shell.render_requests.resize_dirty) {
            if (queuedObservationMatchesDeadline(shell)) {
                if (now < shell.render_requests.resize_apply_after_ms) return;
                try settlePendingResize(
                    terminal,
                    shell,
                    metrics,
                    probe,
                    footer_rows,
                    debounce_ms,
                    cursor_probe_allowed,
                    now,
                );
                return;
            }
            // Position replies are indistinguishable from pasted bytes, so
            // leave live geometry pending until bracketed paste releases input
            // ownership and the shared parser can begin.
            if (!cursor_probe_allowed or !probe.canBegin()) return;
            try observeDirtyResize(
                terminal,
                shell,
                metrics,
                probe,
                footer_rows,
                now,
            );
            return;
        }
        if (!shell.render_requests.pending_settled_width_reflow or
            now < shell.render_requests.resize_apply_after_ms)
        {
            return;
        }
        try settlePendingResize(
            terminal,
            shell,
            metrics,
            probe,
            footer_rows,
            debounce_ms,
            cursor_probe_allowed,
            now,
        );
        return;
    }

    const next_layout = terminal.queryLayout(footer_rows) catch |err| {
        try handleInvalidResize(shell, err);
        return;
    };
    if (next_layout.rows == shell.layout.rows and next_layout.cols == shell.layout.cols and !shell.terminal_dimensions_invalid) {
        return;
    }

    shell.layout = next_layout;
    shell.terminal_dimensions_invalid = false;
    try recordOwnedBandInvalidation(shell, .resize);
    metrics.debounced_resizes += 1;
    try requestRedraw(shell, metrics, .replay_viewport);
}

pub fn admitResizeSignal(
    shell: *TranscriptRuntime,
    resize_interlock: *ResizeApprovalInterlock,
    now_ms: i64,
    debounce_ms: i64,
    source: []const u8,
) bool {
    if (comptime !supports_resize_signal and builtin.os.tag != .windows) return false;
    if (!resize_interlock.takeResizePending()) return false;
    shell.render_requests.observeResizeSignal(now_ms, debounce_ms);
    debug_trace.logf(
        "frame_schedule",
        "resize_block begin source={s} apply_after_ms={d} pending_reason_count={d}",
        .{
            source,
            shell.render_requests.resize_apply_after_ms,
            shell.render_requests.pendingReasonCount(),
        },
    );
    return true;
}

pub fn lifecycleIdle(shell: anytype) bool {
    return !shell.render_requests.resizeLifecyclePending() and
        shell.pending_resize_observation == null and
        !shell.terminal_dimensions_invalid;
}

pub fn blocksFrameCommit(shell: anytype) bool {
    return shell.render_requests.blocksFrameCommit() or
        resizeObservationAwaiting(shell.pending_resize_observation) or
        resizeLightCommitted(shell.pending_resize_observation);
}

fn resizeLightReady(shell: anytype) bool {
    const observation = shell.pending_resize_observation orelse return false;
    return observation.phase == .live and
        !resizeObservationAwaiting(observation) and
        shell.render_requests.pending_settled_width_reflow and
        !shell.terminal_reset_pending;
}

fn resizeResetQueued(shell: anytype) bool {
    const observation = shell.pending_resize_observation orelse return false;
    return observation.phase == .reset_queued and shell.terminal_reset_pending;
}

pub fn pendingFrameCommit(shell: anytype, resize_reason: bool) FrameCommit {
    if (resizeResetQueued(shell)) return .reset;
    if (resize_reason and resizeLightReady(shell)) return .light;
    return .none;
}

pub fn acknowledgeFrameCommit(shell: anytype, commit: FrameCommit) void {
    switch (commit) {
        .none => {},
        .light => {
            const observation = shell.pending_resize_observation orelse return;
            if (observation.phase != .live) return;
            shell.pending_resize_observation.?.phase = .settle_pending;
        },
        .reset => {
            const observation = shell.pending_resize_observation orelse return;
            if (observation.phase != .reset_queued) return;
            shell.pending_resize_observation = null;
            shell.resize_history_row_delta = null;
            shell.render_requests.acknowledgeSettledResizeCommit();
            debug_trace.logf("resize", "settled_reset_committed", .{});
        },
    }
}

fn resizeObservationAwaiting(observation: ?ResizeObservation) bool {
    const pending = observation orelse return false;
    return switch (pending.result) {
        .awaiting => true,
        .measured, .unavailable => false,
    };
}

fn resizeLightCommitted(observation: ?ResizeObservation) bool {
    const pending = observation orelse return false;
    return pending.phase == .settle_pending;
}

fn queuedObservationMatchesDeadline(shell: *const TranscriptRuntime) bool {
    const observation = shell.pending_resize_observation orelse return false;
    return observation.phase == .reset_queued and
        observation.apply_after_ms == shell.render_requests.resize_apply_after_ms;
}

fn observeDirtyResize(
    terminal: anytype,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    probe: *cursor_probe.Parser,
    footer_rows: u16,
    now_ms: i64,
) !void {
    const next_layout = terminal.queryLayout(footer_rows) catch |err| {
        try handleInvalidResize(shell, err);
        if (!shell.render_requests.pending_settled_width_reflow) {
            shell.pending_resize_observation = null;
        } else if (shell.pending_resize_observation) |*observation| {
            observation.result = .unavailable;
            observation.apply_after_ms = shell.render_requests.resize_apply_after_ms;
        }
        shell.render_requests.completeResizeGeometry(false);
        logResizeBlockEnd(shell);
        return;
    };

    const recovering_invalid_dimensions = shell.terminal_dimensions_invalid;
    const size_changed = next_layout.rows != shell.layout.rows or
        next_layout.cols != shell.layout.cols;
    const queued_reset = if (shell.pending_resize_observation) |observation|
        observation.phase == .reset_queued
    else
        shell.terminal_reset_pending and
            shell.render_requests.pending_settled_width_reflow;

    if (!size_changed) {
        if (recovering_invalid_dimensions) {
            try applyResizeWithLayoutResolved(shell, metrics, next_layout, true, null);
        }
        if (shell.render_requests.pending_settled_width_reflow) {
            const phase: ResizeObservationPhase = if (queued_reset)
                .reset_queued
            else if (resizeLightCommitted(shell.pending_resize_observation))
                .settle_pending
            else
                .live;
            shell.pending_resize_observation = .{
                .layout = next_layout,
                .apply_after_ms = shell.render_requests.resize_apply_after_ms,
                .expected_row = null,
                .result = .unavailable,
                .phase = phase,
            };
            if (queued_reset) return;
        } else {
            shell.pending_resize_observation = null;
        }
        shell.render_requests.completeResizeGeometry(false);
        logResizeBlockEnd(shell);
        return;
    }

    const phase: ResizeObservationPhase = if (queued_reset) .reset_queued else .live;
    try prepareResizeObservation(
        terminal,
        shell,
        probe,
        next_layout,
        phase,
        now_ms,
    );
    if (queued_reset) return;

    try applyResizeWithLayoutResolved(shell, metrics, next_layout, false, null);
    logResizeBlockEnd(shell);
}

fn prepareResizeObservation(
    terminal: anytype,
    shell: *TranscriptRuntime,
    probe: *cursor_probe.Parser,
    next_layout: Layout,
    phase: ResizeObservationPhase,
    now_ms: i64,
) !void {
    if (phase == .live) shell.resize_history_row_delta = null;
    const expected_row = expectedResizeCursorRow(shell, next_layout);
    var result: ResizeObservationResult = .unavailable;
    if (expected_row != null and next_layout.cols >= cursor_probe.confirmation_tag_column and probe.canBegin()) {
        const protocol = resizeCursorProbeProtocol();
        const deadline_ms = addMillis(now_ms, cursor_probe.response_idle_timeout_ms);
        try probe.begin(protocol, deadline_ms);
        terminal.requestResizeCursorPosition(protocol) catch |err| {
            probe.cancel();
            debug_trace.logf("resize", "cursor_measure_failed err={s}", .{@errorName(err)});
            shell.pending_resize_observation = .{
                .layout = next_layout,
                .apply_after_ms = shell.render_requests.resize_apply_after_ms,
                .expected_row = expected_row,
                .result = .unavailable,
                .phase = phase,
            };
            return;
        };
        result = .awaiting;
        debug_trace.logf(
            "resize",
            "cursor_measure_requested protocol={s} expected_reflow_row={d} apply_after_ms={d} deadline_ms={d} phase={s}",
            .{
                @tagName(protocol),
                expected_row.?,
                shell.render_requests.resize_apply_after_ms,
                deadline_ms,
                @tagName(phase),
            },
        );
    } else if (expected_row != null and next_layout.cols < cursor_probe.confirmation_tag_column) {
        debug_trace.logf(
            "resize",
            "cursor_measure_skipped reason=terminal_too_narrow cols={d}",
            .{next_layout.cols},
        );
    }
    shell.pending_resize_observation = .{
        .layout = next_layout,
        .apply_after_ms = shell.render_requests.resize_apply_after_ms,
        .expected_row = expected_row,
        .result = result,
        .phase = phase,
    };
}

fn settlePendingResize(
    terminal: anytype,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    probe: *cursor_probe.Parser,
    footer_rows: u16,
    debounce_ms: i64,
    cursor_probe_allowed: bool,
    now_ms: i64,
) !void {
    const observation = shell.pending_resize_observation orelse ResizeObservation{
        .layout = shell.layout,
        .apply_after_ms = shell.render_requests.resize_apply_after_ms,
        .expected_row = null,
        .result = .unavailable,
        .phase = .live,
    };
    if (resizeObservationAwaiting(observation)) return;

    const next_layout = terminal.queryLayout(footer_rows) catch |err| {
        try handleInvalidResize(shell, err);
        shell.render_requests.completeResizeGeometry(false);
        logResizeBlockEnd(shell);
        return;
    };
    if (next_layout.rows != observation.layout.rows or
        next_layout.cols != observation.layout.cols)
    {
        shell.render_requests.observeResizeSignal(now_ms, debounce_ms);
        const phase: ResizeObservationPhase = if (observation.phase == .reset_queued)
            .reset_queued
        else
            .live;
        if (!cursor_probe_allowed) return;
        try prepareResizeObservation(
            terminal,
            shell,
            probe,
            next_layout,
            phase,
            now_ms,
        );
        if (phase == .reset_queued) return;
        try applyResizeWithLayoutResolved(shell, metrics, next_layout, false, null);
        logResizeBlockEnd(shell);
        return;
    }

    const history_row_delta: ?i32 = switch (observation.result) {
        .measured => |delta| delta,
        .awaiting, .unavailable => null,
    };
    shell.pending_resize_observation = observation;
    shell.pending_resize_observation.?.phase = .reset_queued;
    try applyResizeWithLayoutResolved(
        shell,
        metrics,
        next_layout,
        true,
        history_row_delta,
    );
    shell.render_requests.completeResizeGeometry(false);
    logResizeBlockEnd(shell);
}

pub fn completeResizeCursorProbe(
    shell: *TranscriptRuntime,
    position: CursorPosition,
) void {
    finishPendingResizeProbe(shell, position);
}

pub fn suspendResizeCursorProbeForPaste(probe: *cursor_probe.Parser) void {
    if (!probe.suspendForPaste()) return;
    debug_trace.logf("resize", "cursor_measure_paused reason=paste_start", .{});
}

pub fn resumeResizeCursorProbeAfterPaste(probe: *cursor_probe.Parser, now_ms: i64) void {
    if (!probe.resumeAfterPaste(now_ms)) return;
    debug_trace.logf("resize", "cursor_measure_resumed reason=paste_end", .{});
}

fn finishPendingResizeProbe(
    shell: *TranscriptRuntime,
    position: ?CursorPosition,
) void {
    const observation = shell.pending_resize_observation orelse {
        debug_trace.logf("resize", "cursor_measure_orphan_response", .{});
        return;
    };
    if (!resizeObservationAwaiting(observation)) {
        debug_trace.logf("resize", "cursor_measure_orphan_response", .{});
        return;
    }

    if (shell.render_requests.resize_apply_after_ms != observation.apply_after_ms) {
        shell.pending_resize_observation.?.result = .unavailable;
        shell.pending_resize_observation.?.apply_after_ms =
            shell.render_requests.resize_apply_after_ms;
        debug_trace.logf(
            "resize",
            "cursor_measure_stale probe_apply_after_ms={d} current_apply_after_ms={d}",
            .{
                observation.apply_after_ms,
                shell.render_requests.resize_apply_after_ms,
            },
        );
        return;
    }

    const row_delta = if (position) |actual|
        if (observation.expected_row) |expected_row|
            measuredCursorRowDelta(expected_row, actual.row)
        else
            null
    else
        null;
    shell.pending_resize_observation.?.result = if (row_delta) |delta|
        .{ .measured = delta }
    else
        .unavailable;
    shell.resize_history_row_delta = row_delta;
    debug_trace.logf(
        "resize",
        "cursor_measure expected_reflow_row={d} actual_row={d} actual_col={d} history_row_delta={d} valid={s}",
        .{
            observation.expected_row orelse 0,
            if (position) |actual| actual.row else 0,
            if (position) |actual| actual.col else 0,
            row_delta orelse 0,
            if (row_delta != null) "true" else "false",
        },
    );
}

fn logResizeBlockEnd(shell: *const TranscriptRuntime) void {
    debug_trace.logf(
        "frame_schedule",
        "resize_block end pending_reason_count={d} invalidations={d}",
        .{
            shell.render_requests.pendingReasonCount(),
            shell.render_requests.pendingInvalidations().len,
        },
    );
}

fn addMillis(now_ms: i64, duration_ms: i64) i64 {
    return std.math.add(i64, now_ms, duration_ms) catch std.math.maxInt(i64);
}

fn resizeCursorProbeProtocol() cursor_probe.Protocol {
    return if (io_mod.getenv("TMUX") != null) .ansi_tagged else .private;
}

fn handleInvalidResize(shell: *TranscriptRuntime, err: anyerror) !void {
    if (!ui_terminal.isInvalidLayoutError(err)) return err;
    if (!shell.has_committed_frame) return err;
    shell.terminal_dimensions_invalid = true;
    try recordOwnedBandInvalidation(shell, .resize);
    shell.footer_viewport.invalidateAfterExternalClear();
    debug_trace.logf(
        "resize",
        "invalid_dimensions err={s} prior_layout={d}x{d} owned_top={d} pending_invalidations={d}",
        .{ @errorName(err), shell.layout.cols, shell.layout.rows, shell.owned_top_row, shell.render_requests.pendingInvalidations().len },
    );
}

fn recordOwnedBandInvalidation(
    shell: *TranscriptRuntime,
    reason: paint_plan.FrameInvalidationReason,
) !void {
    if (shell.layout.rows == 0) return;
    var top = shell.owned_top_row;
    if (top == 0 or top > shell.layout.rows) top = 1;
    try shell.recordFrameInvalidation(.{
        .reason = reason,
        .top = top,
        .bottom = shell.layout.rows,
    });
}

/// Resize-path worker that is pure in terms of I/O (no fd access, no
/// ioctl). Tests drive this directly with a constructed `Layout` so
/// the resize decision tree can be exercised deterministically.
pub fn applyResizeWithLayout(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    new_layout: Layout,
    settled: bool,
) !void {
    return applyResizeWithLayoutResolved(shell, metrics, new_layout, settled, null);
}

fn applyResizeWithLayoutResolved(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    new_layout: Layout,
    settled: bool,
    history_row_delta: ?i32,
) !void {
    const size_changed = new_layout.rows != shell.layout.rows or new_layout.cols != shell.layout.cols;
    const recovering_invalid_dimensions = shell.terminal_dimensions_invalid;
    if (size_changed) record_tape.recordResize(new_layout.cols, new_layout.rows);
    const picked_mode = resizeModeForSignalPass(
        shell.layout,
        new_layout,
        shell.render_requests.pending_settled_width_reflow or recovering_invalid_dimensions,
        settled,
    );

    debug_trace.logf("resize", "apply old={d}x{d} new={d}x{d} size_changed={s} settled={s} pending_width_reflow={s} mode={s}", .{
        shell.layout.cols,                                                           shell.layout.rows,
        new_layout.cols,                                                             new_layout.rows,
        if (size_changed) "true" else "false",                                       if (settled) "true" else "false",
        if (shell.render_requests.pending_settled_width_reflow) "true" else "false", if (picked_mode) |m| @tagName(m) else "null",
    });

    const mode = picked_mode orelse return;
    const needs_owned_band_invalidation = size_changed or recovering_invalid_dimensions;

    if (!settled) {
        // .resize_light is the only unsettled mode, so the size changed here.
        std.debug.assert(size_changed);
        shell.layout = new_layout;
        shell.terminal_dimensions_invalid = false;
        try recordOwnedBandInvalidation(shell, .resize);
        metrics.debounced_resizes += 1;
        shell.render_requests.completeResizeGeometry(true);
        // Shadow-grid reconciliation is part of the next frame commit.
        // Resizing the shadow here would make it describe terminal
        // reflow that has not yet been committed.
        try requestRedraw(shell, metrics, mode);
        return;
    }

    if (needs_owned_band_invalidation) {
        shell.layout = new_layout;
        shell.terminal_dimensions_invalid = false;
        try recordOwnedBandInvalidation(shell, .resize);
    }
    metrics.debounced_resizes += 1;

    if (shell.render_requests.pending_settled_width_reflow) {
        if (shell.pending_resize_observation) |*observation| {
            observation.phase = .reset_queued;
        } else {
            shell.pending_resize_observation = .{
                .layout = new_layout,
                .apply_after_ms = shell.render_requests.resize_apply_after_ms,
                .expected_row = null,
                .result = if (history_row_delta) |delta|
                    .{ .measured = delta }
                else
                    .unavailable,
                .phase = .reset_queued,
            };
        }
    }
    if (shell.render_requests.pending_settled_width_reflow or size_changed) {
        try shell.requestTerminalResetAfterResize(metrics, history_row_delta);
    }
    try requestRedraw(shell, metrics, mode);
}

fn resizeModeForSignalPass(old_layout: Layout, new_layout: Layout, pending_replay: bool, settled: bool) ?RedrawMode {
    const size_changed = new_layout.rows != old_layout.rows or new_layout.cols != old_layout.cols;
    if (!settled) {
        return if (size_changed) .resize_light else null;
    }

    const should_replay = pending_replay or size_changed;
    if (!should_replay) return null;
    return .replay_viewport;
}

fn launchTestLayout() Layout {
    return .{
        .rows = 24,
        .cols = 120,
        .content_bottom = 21,
        .divider_top_row = 22,
        .input_row = 23,
        .divider_bottom_row = 24,
        .hint_row = 22,
    };
}

const InvalidLayoutTerminal = struct {
    fn queryLayout(_: InvalidLayoutTerminal, _: u16) !Layout {
        return error.UnableToReadTerminalSize;
    }

    fn requestResizeCursorPosition(_: InvalidLayoutTerminal, _: cursor_probe.Protocol) !void {
        return error.TestResizeCursorPositionUnavailable;
    }
};

const LiveResizeTerminal = struct {
    layout: Layout,

    fn queryLayout(self: LiveResizeTerminal, _: u16) !Layout {
        return self.layout;
    }

    fn requestResizeCursorPosition(_: LiveResizeTerminal, _: cursor_probe.Protocol) !void {
        return error.TestUnexpectedCursorProbe;
    }
};

const ProbeOrderingTerminal = struct {
    layout: Layout,
    shell: *TranscriptRuntime,
    requested: *bool,
    layout_cols_at_request: *u16,

    fn queryLayout(self: ProbeOrderingTerminal, _: u16) !Layout {
        return self.layout;
    }

    fn requestResizeCursorPosition(
        self: ProbeOrderingTerminal,
        _: cursor_probe.Protocol,
    ) !void {
        self.requested.* = true;
        self.layout_cols_at_request.* = self.shell.layout.cols;
    }
};

test "changed live resize requests cursor position before applying geometry" {
    const alloc = std.testing.allocator;
    const next_layout: Layout = .{
        .rows = 40,
        .cols = 100,
        .content_bottom = 36,
        .divider_top_row = 37,
        .input_row = 38,
        .divider_bottom_row = 39,
        .hint_row = 40,
    };
    var shell = TranscriptRuntime{
        .layout = launchTestLayout(),
        .owned_top_row = 1,
        .has_committed_frame = true,
    };
    defer shell.deinit(alloc);
    try shell.enableShadowVt(alloc);
    var requested = false;
    var layout_cols_at_request: u16 = 0;
    var metrics = Metrics{};
    var probe = cursor_probe.Parser{};
    var resize_interlock = ResizeApprovalInterlock{};
    resize_interlock.noteResizeSignal();

    try collectResizeFacts(
        ProbeOrderingTerminal{
            .layout = next_layout,
            .shell = &shell,
            .requested = &requested,
            .layout_cols_at_request = &layout_cols_at_request,
        },
        &shell,
        &metrics,
        &probe,
        &resize_interlock,
        4,
        80,
        true,
    );

    try std.testing.expect(requested);
    try std.testing.expectEqual(@as(u16, 120), layout_cols_at_request);
    try std.testing.expectEqual(next_layout, shell.layout);
    try std.testing.expect(probe.interceptsInput());
    try std.testing.expect(blocksFrameCommit(&shell));
}

test "signal fact pass applies changed geometry before the settle deadline" {
    const next_layout: Layout = .{
        .rows = 40,
        .cols = 120,
        .content_bottom = 36,
        .divider_top_row = 37,
        .input_row = 38,
        .divider_bottom_row = 39,
        .hint_row = 40,
    };
    var shell = TranscriptRuntime{
        .layout = launchTestLayout(),
        .owned_top_row = 2,
        .has_committed_frame = true,
    };
    defer shell.deinit(std.testing.allocator);
    var metrics = Metrics{};
    var probe = cursor_probe.Parser{};
    var resize_interlock = ResizeApprovalInterlock{};
    resize_interlock.noteResizeSignal();

    try collectResizeFacts(
        LiveResizeTerminal{ .layout = next_layout },
        &shell,
        &metrics,
        &probe,
        &resize_interlock,
        4,
        80,
        true,
    );

    try std.testing.expectEqual(next_layout, shell.layout);
    try std.testing.expect(!shell.render_requests.resize_dirty);
    try std.testing.expect(shell.render_requests.pending_settled_width_reflow);
    try std.testing.expect(shell.render_requests.hasReason(.resize));
}

test "committed light phase blocks intervening frames until reset is queued" {
    var shell = TranscriptRuntime{};
    defer shell.deinit(std.testing.allocator);
    shell.render_requests.completeResizeGeometry(true);
    shell.pending_resize_observation = .{
        .layout = launchTestLayout(),
        .apply_after_ms = 100,
        .expected_row = 13,
        .result = .{ .measured = 3 },
        .phase = .live,
    };

    try std.testing.expectEqual(FrameCommit.light, pendingFrameCommit(&shell, true));
    try std.testing.expect(!blocksFrameCommit(&shell));

    acknowledgeFrameCommit(&shell, .light);

    try std.testing.expectEqual(
        ResizeObservationPhase.settle_pending,
        shell.pending_resize_observation.?.phase,
    );
    try std.testing.expect(blocksFrameCommit(&shell));

    shell.pending_resize_observation.?.phase = .reset_queued;
    shell.terminal_reset_pending = true;
    try std.testing.expect(!blocksFrameCommit(&shell));
}

test "pre-paint cursor delta survives live apply until reset commit" {
    const alloc = std.testing.allocator;
    const next_layout: Layout = .{
        .rows = 40,
        .cols = 100,
        .content_bottom = 36,
        .divider_top_row = 37,
        .input_row = 38,
        .divider_bottom_row = 39,
        .hint_row = 40,
    };
    var shell = TranscriptRuntime{
        .layout = launchTestLayout(),
        .owned_top_row = 1,
        .has_committed_frame = true,
    };
    defer shell.deinit(alloc);
    try shell.enableShadowVt(alloc);
    shell.shadow_vt.?.cursor_row = 12;
    var requested = false;
    var layout_cols_at_request: u16 = 0;
    const terminal = ProbeOrderingTerminal{
        .layout = next_layout,
        .shell = &shell,
        .requested = &requested,
        .layout_cols_at_request = &layout_cols_at_request,
    };
    var metrics = Metrics{};
    var probe = cursor_probe.Parser{};
    var resize_interlock = ResizeApprovalInterlock{};
    resize_interlock.noteResizeSignal();

    try collectResizeFacts(
        terminal,
        &shell,
        &metrics,
        &probe,
        &resize_interlock,
        4,
        0,
        true,
    );
    const expected_row = shell.pending_resize_observation.?.expected_row.?;
    try std.testing.expect(expected_row > 3);
    const actual_row: u16 = @intCast(expected_row - 3);
    probe.cancel();
    completeResizeCursorProbe(&shell, .{ .row = actual_row, .col = 1 });
    try std.testing.expect(!blocksFrameCommit(&shell));

    try std.testing.expectEqual(
        @as(i32, 3),
        shell.pending_resize_observation.?.result.measured,
    );
    try std.testing.expectEqual(@as(?i32, 3), shell.resize_history_row_delta);

    try collectResizeFacts(
        terminal,
        &shell,
        &metrics,
        &probe,
        &resize_interlock,
        4,
        0,
        true,
    );

    try std.testing.expect(shell.terminal_reset_pending);
    try std.testing.expectEqual(
        transcript_runtime.ResizeObservationPhase.reset_queued,
        shell.pending_resize_observation.?.phase,
    );
    try std.testing.expectEqual(@as(?i32, 3), shell.resize_history_row_delta);
    try std.testing.expect(shell.render_requests.pending_settled_width_reflow);

    try std.testing.expectEqual(FrameCommit.reset, pendingFrameCommit(&shell, true));
    acknowledgeFrameCommit(&shell, .reset);

    try std.testing.expectEqual(@as(?ResizeObservation, null), shell.pending_resize_observation);
    try std.testing.expectEqual(@as(?i32, null), shell.resize_history_row_delta);
    try std.testing.expect(!shell.render_requests.resizeLifecyclePending());
}

test "new signal rebases a queued reset without committing an intermediate light frame" {
    const alloc = std.testing.allocator;
    const old_layout = launchTestLayout();
    const next_layout: Layout = .{
        .rows = 40,
        .cols = 100,
        .content_bottom = 36,
        .divider_top_row = 37,
        .input_row = 38,
        .divider_bottom_row = 39,
        .hint_row = 40,
    };
    var shell = TranscriptRuntime{
        .layout = old_layout,
        .owned_top_row = 1,
        .has_committed_frame = true,
        .terminal_reset_pending = true,
        .resize_history_row_delta = 7,
    };
    defer shell.deinit(alloc);
    try shell.enableShadowVt(alloc);
    shell.shadow_vt.?.cursor_row = 12;
    shell.render_requests.completeResizeGeometry(true);
    shell.render_requests.resize_apply_after_ms = 1;
    shell.pending_resize_observation = .{
        .layout = old_layout,
        .apply_after_ms = 1,
        .expected_row = 20,
        .result = .{ .measured = 7 },
        .phase = .reset_queued,
    };
    var requested = false;
    var layout_cols_at_request: u16 = 0;
    const terminal = ProbeOrderingTerminal{
        .layout = next_layout,
        .shell = &shell,
        .requested = &requested,
        .layout_cols_at_request = &layout_cols_at_request,
    };
    var metrics = Metrics{};
    var probe = cursor_probe.Parser{};
    var resize_interlock = ResizeApprovalInterlock{};
    resize_interlock.noteResizeSignal();

    try collectResizeFacts(
        terminal,
        &shell,
        &metrics,
        &probe,
        &resize_interlock,
        4,
        0,
        true,
    );

    try std.testing.expect(requested);
    try std.testing.expectEqual(old_layout, shell.layout);
    try std.testing.expectEqual(@as(?i32, 7), shell.resize_history_row_delta);
    try std.testing.expectEqual(@as(usize, 0), metrics.debounced_resizes);
    try std.testing.expect(shell.render_requests.blocksFrameCommit());
    try std.testing.expectEqual(next_layout, shell.pending_resize_observation.?.layout);
    try std.testing.expectEqual(
        ResizeObservationPhase.reset_queued,
        shell.pending_resize_observation.?.phase,
    );

    const expected_row = shell.pending_resize_observation.?.expected_row.?;
    try std.testing.expect(expected_row > 3);
    probe.cancel();
    completeResizeCursorProbe(
        &shell,
        .{ .row = @intCast(expected_row - 3), .col = 1 },
    );
    try collectResizeFacts(
        terminal,
        &shell,
        &metrics,
        &probe,
        &resize_interlock,
        4,
        0,
        true,
    );

    try std.testing.expectEqual(next_layout, shell.layout);
    try std.testing.expectEqual(@as(?i32, 3), shell.resize_history_row_delta);
    try std.testing.expectEqual(@as(usize, 1), metrics.debounced_resizes);
    try std.testing.expect(shell.terminal_reset_pending);
    try std.testing.expect(!shell.render_requests.blocksFrameCommit());
    try std.testing.expect(shell.render_requests.pending_settled_width_reflow);
}

test "matching resize cursor probe retains pre-paint delta after live apply" {
    var shell = TranscriptRuntime{};
    defer shell.deinit(std.testing.allocator);
    shell.layout = .{
        .rows = 24,
        .cols = 120,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    const next_layout: Layout = .{
        .rows = 20,
        .cols = 80,
        .content_bottom = 16,
        .divider_top_row = 17,
        .input_row = 18,
        .divider_bottom_row = 19,
        .hint_row = 20,
    };
    shell.layout = next_layout;
    shell.render_requests.resize_apply_after_ms = 100;
    shell.render_requests.completeResizeGeometry(true);
    shell.pending_resize_observation = .{
        .layout = next_layout,
        .apply_after_ms = 100,
        .expected_row = 13,
        .result = .awaiting,
        .phase = .live,
    };

    completeResizeCursorProbe(&shell, .{ .row = 10, .col = 1 });

    try std.testing.expectEqual(next_layout, shell.layout);
    try std.testing.expect(!shell.render_requests.blocksFrameCommit());
    try std.testing.expectEqual(
        @as(i32, 3),
        shell.pending_resize_observation.?.result.measured,
    );
    try std.testing.expectEqual(@as(?i32, 3), shell.resize_history_row_delta);
    try std.testing.expect(shell.render_requests.pending_settled_width_reflow);
}

test "paste pauses an active resize cursor probe with its layout pending" {
    var shell = TranscriptRuntime{};
    defer shell.deinit(std.testing.allocator);
    shell.layout = .{
        .rows = 24,
        .cols = 120,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    const next_layout: Layout = .{
        .rows = 20,
        .cols = 80,
        .content_bottom = 16,
        .divider_top_row = 17,
        .input_row = 18,
        .divider_bottom_row = 19,
        .hint_row = 20,
    };
    shell.render_requests.observeResizeSignal(100, 0);
    shell.pending_resize_observation = .{
        .layout = next_layout,
        .apply_after_ms = 100,
        .expected_row = 13,
        .result = .awaiting,
        .phase = .live,
    };

    var probe = cursor_probe.Parser{};
    try probe.begin(.ansi_tagged, 200);
    suspendResizeCursorProbeForPaste(&probe);

    try std.testing.expectEqual(@as(u16, 120), shell.layout.cols);
    try std.testing.expect(shell.render_requests.blocksFrameCommit());
    try std.testing.expectEqual(next_layout, shell.pending_resize_observation.?.layout);
    try std.testing.expect(probe.interceptsInput());
}

test "stale resize cursor probe does not apply an obsolete layout" {
    var shell = TranscriptRuntime{};
    defer shell.deinit(std.testing.allocator);
    const original_layout: Layout = .{
        .rows = 24,
        .cols = 120,
        .content_bottom = 20,
        .divider_top_row = 21,
        .input_row = 22,
        .divider_bottom_row = 23,
        .hint_row = 24,
    };
    shell.layout = original_layout;
    shell.render_requests.observeResizeSignal(100, 0);
    shell.pending_resize_observation = .{
        .layout = .{
            .rows = 20,
            .cols = 80,
            .content_bottom = 16,
            .divider_top_row = 17,
            .input_row = 18,
            .divider_bottom_row = 19,
            .hint_row = 20,
        },
        .apply_after_ms = 100,
        .expected_row = 13,
        .result = .awaiting,
        .phase = .live,
    };
    shell.render_requests.observeResizeSignal(150, 0);

    completeResizeCursorProbe(&shell, .{ .row = 10, .col = 1 });

    try std.testing.expectEqual(original_layout, shell.layout);
    try std.testing.expect(shell.render_requests.blocksFrameCommit());
    try std.testing.expectEqual(
        ResizeObservationResult.unavailable,
        shell.pending_resize_observation.?.result,
    );
}

test "measured cursor displacement reports rows entering and leaving history" {
    try std.testing.expectEqual(@as(i32, 8), measuredCursorRowDelta(28, 20));
    try std.testing.expectEqual(@as(i32, -8), measuredCursorRowDelta(20, 28));
}

test "request owner triggers deferred resize after debounce" {
    var shell = TranscriptRuntime{};
    defer shell.deinit(std.testing.allocator);
    shell.render_requests.observeResizeSignal(100, 80);

    try std.testing.expect(shell.render_requests.blocksFrameCommit());
    try std.testing.expect(!shell.render_requests.shouldApplyDeferredResize(179));
    try std.testing.expect(shell.render_requests.shouldApplyDeferredResize(180));
    shell.render_requests.completeResizeGeometry(false);
    try std.testing.expect(!shell.render_requests.blocksFrameCommit());
}

test "signal resize mode stays light during live resize" {
    const old_layout: Layout = .{
        .rows = 24,
        .cols = 120,
        .content_bottom = 21,
        .divider_top_row = 22,
        .input_row = 23,
        .divider_bottom_row = 24,
        .hint_row = 22,
    };
    const new_layout: Layout = .{
        .rows = 24,
        .cols = 100,
        .content_bottom = 21,
        .divider_top_row = 22,
        .input_row = 23,
        .divider_bottom_row = 24,
        .hint_row = 22,
    };

    try std.testing.expectEqual(RedrawMode.resize_light, resizeModeForSignalPass(old_layout, new_layout, false, false).?);
}

test "signal resize mode replays on settled width repair" {
    const old_layout: Layout = .{
        .rows = 24,
        .cols = 120,
        .content_bottom = 21,
        .divider_top_row = 22,
        .input_row = 23,
        .divider_bottom_row = 24,
        .hint_row = 22,
    };
    const settled_layout: Layout = .{
        .rows = 24,
        .cols = 120,
        .content_bottom = 21,
        .divider_top_row = 22,
        .input_row = 23,
        .divider_bottom_row = 24,
        .hint_row = 22,
    };

    try std.testing.expectEqual(RedrawMode.replay_viewport, resizeModeForSignalPass(old_layout, settled_layout, true, true).?);
}

test "invalid resize query after committed frame records state without painting" {
    var shell = TranscriptRuntime{
        .layout = launchTestLayout(),
        .owned_top_row = 5,
        .has_committed_frame = true,
    };
    defer shell.deinit(std.testing.allocator);
    shell.footer_viewport.has_frame = true;

    var metrics = Metrics{};
    var probe = cursor_probe.Parser{};
    var resize_interlock = ResizeApprovalInterlock{};
    resize_interlock.noteResizeSignal();
    try collectResizeFacts(
        InvalidLayoutTerminal{},
        &shell,
        &metrics,
        &probe,
        &resize_interlock,
        4,
        80,
        true,
    );

    try std.testing.expect(shell.terminal_dimensions_invalid);
    try std.testing.expect(shell.footer_viewport.externally_invalidated);
    try std.testing.expect(shell.render_requests.hasReason(.resize));
}

test "TerminalTooSmall after committed frame records resize invalidation and recovers same layout" {
    var shell = TranscriptRuntime{
        .layout = launchTestLayout(),
        .owned_top_row = 5,
        .has_committed_frame = true,
    };
    defer shell.deinit(std.testing.allocator);
    shell.footer_viewport.has_frame = true;

    try handleInvalidResize(&shell, error.TerminalTooSmall);

    try std.testing.expect(shell.terminal_dimensions_invalid);
    try std.testing.expect(shell.has_committed_frame);
    try std.testing.expect(shell.footer_viewport.externally_invalidated);
    const pending = shell.render_requests.pendingInvalidations();
    try std.testing.expectEqual(@as(u8, 1), pending.len);
    try std.testing.expectEqual(paint_plan.FrameInvalidationReason.resize, pending.ranges()[0].reason);
    try std.testing.expectEqual(@as(u16, 5), pending.ranges()[0].top);
    try std.testing.expectEqual(@as(u16, 24), pending.ranges()[0].bottom);

    const recovered_layout = launchTestLayout();
    var metrics = Metrics{};
    try applyResizeWithLayout(
        &shell,
        &metrics,
        recovered_layout,
        true,
    );

    try std.testing.expect(!shell.terminal_dimensions_invalid);
    try std.testing.expect(shell.has_committed_frame);
    try std.testing.expectEqual(@as(u16, 120), shell.layout.cols);
    try std.testing.expect(shell.render_requests.hasReason(.footer));
    try std.testing.expect(!shell.terminal_reset_pending);
}

test "invalid resize before committed frame preserves startup error path" {
    var shell = TranscriptRuntime{
        .layout = launchTestLayout(),
        .owned_top_row = 5,
    };
    defer shell.deinit(std.testing.allocator);

    try std.testing.expectError(error.UnableToReadTerminalSize, handleInvalidResize(&shell, error.UnableToReadTerminalSize));
    try std.testing.expect(!shell.terminal_dimensions_invalid);
    try std.testing.expect(shell.render_requests.pendingInvalidations().isEmpty());
}
