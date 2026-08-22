const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const ui_terminal = @import("../terminal/terminal.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");
const frame_cell_match = @import("frame_cell_match.zig");
const frame_scroll_plan = @import("frame_scroll_plan.zig");
const frame_surface = @import("frame_surface.zig");
const paint_plan = @import("paint_plan.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;

pub const ShadowCommitState = enum {
    committed,
    terminal_partial_write,
    shadow_feed_failed,

    pub fn is_committed(self: ShadowCommitState) bool {
        return self == .committed;
    }
};

pub const FrameSinkWriteResult = union(enum) {
    complete,
    partial: struct {
        accepted_bytes: usize,
        err: anyerror,
    },
};

pub const FrameSink = struct {
    ctx: *anyopaque,
    write_frame: *const fn (ctx: *anyopaque, metrics: *Metrics, bytes: []const u8) FrameSinkWriteResult,
};

pub const FrameTerminalTransition = union(enum) {
    none,
    restore_normal_screen: struct {
        mouse_tracking_active: bool,
    },

    fn sequence(self: FrameTerminalTransition) []const u8 {
        return switch (self) {
            .none => "",
            .restore_normal_screen => |restore| ui_terminal.alternateScreenFrameRestoreSequence(
                restore.mouse_tracking_active,
            ),
        };
    }
};

pub const FrameCommitInput = struct {
    previous: *vt_emulator.Grid,
    surface: *const frame_surface.FrameSurface,
    repaint_window: paint_plan.FrameRepaintWindow,
    synchronized_update: bool,
    history_reset_uses_ris: bool = false,
    scroll_plan: frame_scroll_plan.FrameScrollPlan,
    document_append: frame_scroll_plan.FrameDocumentAppend = .{},
    terminal_transition: FrameTerminalTransition = .none,
    prepared_movement: ?*const PreparedTerminalMovement = null,
    sink: FrameSink,
    metrics: *Metrics,
};

pub const TerminalMovementSegment = struct {
    start: usize = 0,
    end: usize = 0,
    scroll_rows: u16 = 0,

    pub fn hasBytes(self: TerminalMovementSegment) bool {
        return self.end > self.start;
    }

    fn absolute(self: TerminalMovementSegment, base: usize) TerminalMovementSegment {
        return .{
            .start = base + self.start,
            .end = base + self.end,
            .scroll_rows = self.scroll_rows,
        };
    }
};

pub const TerminalMovementSegments = struct {
    terminal_transition: TerminalMovementSegment = .{},
    document_append: TerminalMovementSegment = .{},
    alignment_scroll: TerminalMovementSegment = .{},
};

pub const FrameScrollAttribution = struct {
    control_prefix_scroll_rows: u16 = 0,
    document_append_scroll_rows: u16 = 0,
    alignment_scroll_rows: u16 = 0,
    movement_gap_scroll_rows: u16 = 0,
    paint_tail_scroll_rows: u16 = 0,

    pub fn movementScrollRows(self: FrameScrollAttribution) u16 {
        return self.document_append_scroll_rows +| self.alignment_scroll_rows;
    }

    pub fn neutralScrollRows(self: FrameScrollAttribution) u16 {
        return self.control_prefix_scroll_rows +|
            self.movement_gap_scroll_rows +|
            self.paint_tail_scroll_rows;
    }

    pub fn totalScrollRows(self: FrameScrollAttribution) u16 {
        return self.movementScrollRows() +| self.neutralScrollRows();
    }
};

pub const PreparedTerminalMovement = struct {
    bytes: []u8,
    post_movement: vt_emulator.Grid,
    document_append_start: usize = 0,
    document_append_end: usize = 0,
    segments: TerminalMovementSegments = .{},
    scroll_rows: frame_scroll_plan.TerminalMovementRows = .{
        .planned_scroll_rows = 0,
        .materialized_scroll_rows = 0,
        .alignment_scroll_rows = 0,
        .expected_scroll_rows = 0,
    },
    terminal_transition: FrameTerminalTransition = .none,
    reset_replay: bool = false,
    source_rows: u16,
    source_cols: u16,
    target_rows: u16,
    target_cols: u16,

    pub fn deinit(self: *PreparedTerminalMovement, alloc: Allocator) void {
        if (self.bytes.len > 0) alloc.free(self.bytes);
        self.post_movement.deinit();
        self.* = undefined;
    }

    pub fn hasDocumentAppend(self: PreparedTerminalMovement) bool {
        return self.segments.document_append.hasBytes();
    }

    fn validateForCommit(
        self: *const PreparedTerminalMovement,
        source: *const vt_emulator.Grid,
        target_cols: u16,
        target_rows: u16,
        planned_scroll_rows: u16,
        non_deferable_scroll_rows: u16,
        terminal_transition: FrameTerminalTransition,
        reset_replay: bool,
    ) !void {
        const expected_rows = try resolveTerminalMovementRows(
            planned_scroll_rows,
            self.scroll_rows.materialized_scroll_rows,
            non_deferable_scroll_rows,
            reset_replay,
            source.cols,
            source.rows,
            target_cols,
            target_rows,
        );
        if (self.source_rows != source.rows or
            self.source_cols != source.cols or
            self.target_rows != target_rows or
            self.target_cols != target_cols or
            !std.meta.eql(self.scroll_rows, expected_rows) or
            !std.meta.eql(self.terminal_transition, terminal_transition) or
            self.reset_replay != reset_replay or
            self.segments.terminal_transition.scroll_rows != 0 or
            self.segments.document_append.scroll_rows != self.scroll_rows.materialized_scroll_rows or
            self.segments.alignment_scroll.scroll_rows != self.scroll_rows.alignment_scroll_rows)
        {
            return error.InvalidFrameScrollPlan;
        }
    }

    fn validateCompleteWrite(
        self: *const PreparedTerminalMovement,
        accepted_bytes: usize,
        frame_bytes: usize,
        scroll_attribution: FrameScrollAttribution,
    ) !void {
        if (accepted_bytes != frame_bytes) return;
        if (scroll_attribution.neutralScrollRows() != 0 or
            scroll_attribution.document_append_scroll_rows != self.scroll_rows.materialized_scroll_rows or
            scroll_attribution.alignment_scroll_rows != self.scroll_rows.alignment_scroll_rows or
            scroll_attribution.totalScrollRows() != self.scroll_rows.emittedScrollRows())
        {
            return error.InvalidFrameScrollPlan;
        }
    }

    fn documentAppendWireRange(self: *const PreparedTerminalMovement, prefix_len: usize) DocumentAppendWireRange {
        if (!self.hasDocumentAppend()) return .{};
        return .{
            .start = prefix_len + self.document_append_start,
            .end = prefix_len + self.document_append_end,
        };
    }
};

pub const FrameCommitResult = struct {
    bytes_written: usize,
    changed_cells: usize,
    full_repaint: bool,
    terminal_scroll_rows_committed: u16 = 0,
    scroll_commit_receipt: ?frame_scroll_plan.FrameScrollCommit = null,
    scroll_attribution: FrameScrollAttribution = .{},
    document_append_committed: bool = false,
    committed_cursor_row: u16,
    committed_cursor_col: u16,
    committed_cursor_visible: bool = true,
    shadow_state: ShadowCommitState,
    next_invalidation: paint_plan.FrameInvalidationSet,

    pub fn state(self: FrameCommitResult) ShadowCommitState {
        return self.shadow_state;
    }

    pub fn is_committed(self: FrameCommitResult) bool {
        return self.state().is_committed();
    }

    pub fn terminal_scroll_rows_applied(self: FrameCommitResult) u16 {
        return self.terminal_scroll_rows_committed;
    }

    pub fn document_append_applied(self: FrameCommitResult) bool {
        return self.document_append_committed;
    }

    pub fn committed_cursor(self: FrameCommitResult) ?paint_plan.FrameCursorTarget {
        if (!self.is_committed()) return null;
        return .{
            .row = self.committed_cursor_row,
            .col = self.committed_cursor_col,
            .visible = self.committed_cursor_visible,
        };
    }

    pub fn retry_invalidation(self: FrameCommitResult) ?paint_plan.FrameInvalidationRange {
        if (self.is_committed()) return null;
        std.debug.assert(self.next_invalidation.len <= 1);
        if (self.next_invalidation.isEmpty()) return null;
        return self.next_invalidation.ranges()[0];
    }

    pub fn scrollCommit(
        self: FrameCommitResult,
        scroll_plan: frame_scroll_plan.FrameScrollPlan,
    ) frame_scroll_plan.FrameScrollCommit {
        if (self.scroll_commit_receipt) |receipt| {
            std.debug.assert(receipt.matchesPlan(scroll_plan));
            return receipt;
        }
        std.debug.assert(builtin.is_test);
        return scroll_plan.commit(self.terminal_scroll_rows_committed);
    }
};

const CleanupState = enum {
    none,
    complete,
    failed,
};

const DocumentAppendWireRange = struct {
    start: usize = 0,
    end: usize = 0,

    fn isEmpty(self: DocumentAppendWireRange) bool {
        return self.end == 0;
    }

    fn committed(self: DocumentAppendWireRange, accepted_bytes: usize) bool {
        return !self.isEmpty() and accepted_bytes >= self.end;
    }

    fn interrupted(self: DocumentAppendWireRange, accepted_bytes: usize) bool {
        return !self.isEmpty() and accepted_bytes > self.start and !self.committed(accepted_bytes);
    }
};

const AcceptedFrameWrite = struct {
    accepted_bytes: usize,
    applied_scroll_rows: u16,
    scroll_attribution: FrameScrollAttribution,
    document_append_committed: bool,
    document_append_interrupted: bool,
};

const DocumentAppendMovement = struct {
    segment: TerminalMovementSegment = .{},
};

const FrameMovementSegments = struct {
    movement_start: usize = 0,
    movement_end: usize = 0,
    document_append: TerminalMovementSegment = .{},
    alignment_scroll: TerminalMovementSegment = .{},

    fn none() FrameMovementSegments {
        return .{};
    }

    fn fromPreparedMovement(prefix_len: usize, movement: PreparedTerminalMovement) FrameMovementSegments {
        return .{
            .movement_start = prefix_len,
            .movement_end = prefix_len + movement.bytes.len,
            .document_append = movement.segments.document_append.absolute(prefix_len),
            .alignment_scroll = movement.segments.alignment_scroll.absolute(prefix_len),
        };
    }
};

const ScrollAttributionBucket = enum {
    control_prefix,
    document_append,
    alignment_scroll,
    movement_gap,
    paint_tail,
};

const ShadowTestFault = enum {
    none,
    normal_clone_feed,
    normal_clone_invalid,
    repair_resize,
    repair_canonical_feed,
};

var shadow_test_fault: if (builtin.is_test) ShadowTestFault else void = if (builtin.is_test) .none else {};

pub fn flushFrame(input: FrameCommitInput) !FrameCommitResult {
    try input.surface.plan.validate();
    try input.surface.validate();

    const alloc = input.surface.alloc;
    var target = try input.surface.copyToTargetGrid(alloc);
    defer target.deinit();
    try input.scroll_plan.validate(target.rows);
    try input.repaint_window.validate(input.surface.plan);

    const repaint_window = input.repaint_window;
    const terminal_scroll_rows = input.scroll_plan.terminal_scroll_rows;
    if (input.document_append.reset_replay and !input.surface.plan.reset_terminal) {
        return error.InvalidFrameScrollPlan;
    }
    var local_movement: ?PreparedTerminalMovement = null;
    defer if (local_movement) |*movement| movement.deinit(alloc);
    const movement = if (input.prepared_movement) |prepared|
        prepared
    else blk: {
        local_movement = try prepareTerminalMovementForFrame(
            alloc,
            input.previous,
            input.document_append,
            terminal_scroll_rows,
            input.scroll_plan.preserved_release_rows,
            target.cols,
            target.rows,
            0,
            input.terminal_transition,
        );
        break :blk &local_movement.?;
    };
    try movement.validateForCommit(
        input.previous,
        target.cols,
        target.rows,
        terminal_scroll_rows,
        input.scroll_plan.preserved_release_rows,
        input.terminal_transition,
        input.document_append.reset_replay,
    );
    const terminal_scroll_bytes = movement.bytes;
    if (terminal_scroll_rows > 0 or movement.hasDocumentAppend()) {
        debug_trace.logf(
            "frame_commit",
            "terminal_movement planned_rows={d} materialized_rows={d} alignment_rows={d} append_bytes={d} append_wire_bytes={d}",
            .{
                terminal_scroll_rows,
                movement.scroll_rows.materialized_scroll_rows,
                movement.scroll_rows.alignment_scroll_rows,
                input.document_append.bytes.len,
                movement.document_append_end -| movement.document_append_start,
            },
        );
    }

    const dimensions_changed = input.previous.rows != target.rows or input.previous.cols != target.cols;
    const previous_for_diff = movement.post_movement;
    const changed_cells = countChangedCells(previous_for_diff, target, repaint_window);
    const full_repaint = input.surface.plan.reset_terminal or dimensions_changed or terminal_scroll_rows > 0 or invalidationRequiresFullRepaint(input.surface.plan.invalidation);
    if (terminal_scroll_bytes.len == 0 and
        terminal_scroll_rows == 0 and
        !full_repaint and
        changed_cells == 0 and
        cursorMatches(previous_for_diff, target))
    {
        debug_trace.logf(
            "frame_commit",
            "skipped_noop bytes=0 changed_cells=0 band={d}..{d} cursor={d},{d}",
            .{ firstRepaintRow(repaint_window), lastRepaintRow(repaint_window), target.cursor_row, target.cursor_col },
        );
        return committed_result(
            0,
            0,
            false,
            input.scroll_plan.commit(0),
            .{},
            false,
            &target,
        );
    }

    var wire_frame: std.Io.Writer.Allocating = .init(alloc);
    defer wire_frame.deinit();
    const prefix_len = try composeWireFrame(
        &wire_frame,
        input,
        &previous_for_diff,
        &target,
        repaint_window,
        full_repaint,
        terminal_scroll_bytes,
    );
    const wire_frame_bytes = wire_frame.written();
    const document_append_range = movement.documentAppendWireRange(prefix_len);
    const frame_movement_segments = FrameMovementSegments.fromPreparedMovement(prefix_len, movement.*);
    const complete_scroll_attribution = try validateFrameScrollAttribution(
        alloc,
        input.previous,
        target.cols,
        target.rows,
        wire_frame_bytes,
        frame_movement_segments,
        movement.scroll_rows,
    );

    const sink_result = input.sink.write_frame(input.sink.ctx, input.metrics, wire_frame_bytes);
    const accepted_write = try acceptedFrameWrite(
        alloc,
        input.previous,
        target.cols,
        target.rows,
        wire_frame_bytes,
        sink_result,
        document_append_range,
        frame_movement_segments,
        complete_scroll_attribution,
    );
    try movement.validateCompleteWrite(
        accepted_write.accepted_bytes,
        wire_frame_bytes.len,
        accepted_write.scroll_attribution,
    );
    const scroll_commit = input.scroll_plan.commitWithExpectedRows(
        accepted_write.applied_scroll_rows,
        movement.scroll_rows.expected_scroll_rows,
    );
    switch (sink_result) {
        .complete => {},
        .partial => |partial| {
            debug_trace.logf(
                "frame_commit",
                "wire_frame bytes={d} accepted_bytes={d} applied_scroll_rows={d} cleanup={s} err={s}",
                .{ wire_frame_bytes.len, accepted_write.accepted_bytes, accepted_write.applied_scroll_rows, @tagName(CleanupState.none), @errorName(partial.err) },
            );
            return recoverPartialFrame(
                input,
                changed_cells,
                full_repaint,
                wire_frame_bytes,
                accepted_write,
                scroll_commit,
            );
        },
    }

    var fed_shadow = cloneAuthoritativeShadow(alloc, input.previous, target.cols, target.rows) catch |err| {
        return shadowFeedFailedWithRepair(input, changed_cells, full_repaint, accepted_write.accepted_bytes, scroll_commit, accepted_write.scroll_attribution, accepted_write.document_append_committed, err);
    };
    var fed_shadow_initialized = true;
    defer if (fed_shadow_initialized) fed_shadow.deinit();
    if (consumeShadowTestFault(.normal_clone_feed)) {
        return shadowFeedFailedWithRepair(
            input,
            changed_cells,
            full_repaint,
            accepted_write.accepted_bytes,
            scroll_commit,
            accepted_write.scroll_attribution,
            accepted_write.document_append_committed,
            error.TestShadowFeedFailure,
        );
    }
    fed_shadow.feed(wire_frame_bytes) catch |err| {
        return shadowFeedFailedWithRepair(input, changed_cells, full_repaint, accepted_write.accepted_bytes, scroll_commit, accepted_write.scroll_attribution, accepted_write.document_append_committed, err);
    };
    if (consumeShadowTestFault(.normal_clone_invalid)) fed_shadow.defer_sync_updates = true;

    if (!authoritativeShadowHasSteadyState(
        fed_shadow,
        previous_for_diff.autowrap,
        target.cursor_visible,
    )) {
        return shadowFeedFailedWithRepair(
            input,
            changed_cells,
            full_repaint,
            accepted_write.accepted_bytes,
            scroll_commit,
            accepted_write.scroll_attribution,
            accepted_write.document_append_committed,
            error.InvalidAuthoritativeShadowState,
        );
    }

    if (!targetMatches(fed_shadow, target, repaint_window)) {
        return shadowFeedFailedWithRepair(
            input,
            changed_cells,
            full_repaint,
            accepted_write.accepted_bytes,
            scroll_commit,
            accepted_write.scroll_attribution,
            accepted_write.document_append_committed,
            error.ShadowCrossCheckFailed,
        );
    }

    input.previous.deinit();
    input.previous.* = fed_shadow;
    fed_shadow_initialized = false;

    debug_trace.logf(
        "frame_commit",
        "wire_frame bytes={d} accepted_bytes={d} applied_scroll_rows={d} cleanup={s}",
        .{ wire_frame_bytes.len, accepted_write.accepted_bytes, accepted_write.applied_scroll_rows, @tagName(CleanupState.none) },
    );

    return committed_result(
        accepted_write.accepted_bytes,
        changed_cells,
        full_repaint,
        scroll_commit,
        accepted_write.scroll_attribution,
        accepted_write.document_append_committed,
        &target,
    );
}

fn committed_result(
    bytes_written: usize,
    changed_cells: usize,
    full_repaint: bool,
    scroll_commit: frame_scroll_plan.FrameScrollCommit,
    scroll_attribution: FrameScrollAttribution,
    document_append_committed: bool,
    target: *const vt_emulator.Grid,
) FrameCommitResult {
    return .{
        .bytes_written = bytes_written,
        .changed_cells = changed_cells,
        .full_repaint = full_repaint,
        .terminal_scroll_rows_committed = scroll_commit.physical_terminal_scroll_rows,
        .scroll_commit_receipt = scroll_commit,
        .scroll_attribution = scroll_attribution,
        .document_append_committed = document_append_committed,
        .committed_cursor_row = target.cursor_row,
        .committed_cursor_col = target.cursor_col,
        .committed_cursor_visible = target.cursor_visible,
        .shadow_state = .committed,
        .next_invalidation = paint_plan.FrameInvalidationSet.empty(),
    };
}

fn composeWireFrame(
    wire_frame: *std.Io.Writer.Allocating,
    input: FrameCommitInput,
    previous_for_diff: *const vt_emulator.Grid,
    target: *const vt_emulator.Grid,
    repaint_window: paint_plan.FrameRepaintWindow,
    full_repaint: bool,
    terminal_scroll_bytes: []const u8,
) !usize {
    if (input.surface.plan.reset_terminal and input.history_reset_uses_ris) {
        // RIS clears modes that fx enables at startup, so restore them before repainting.
        try wire_frame.writer.writeAll("\x1bc");
        try wire_frame.writer.writeAll(ui_terminal.interactive_mode_enable_sequence);
    }
    if (input.synchronized_update) try wire_frame.writer.writeAll("\x1b[?2026h");
    try wire_frame.writer.writeAll("\x1b[?25l");
    if (input.surface.plan.reset_terminal) {
        try wire_frame.writer.writeAll("\x1b[0m\x1b[2J\x1b[3J\x1b[H");
    }
    const prefix_len = wire_frame.written().len;
    try wire_frame.writer.writeAll(terminal_scroll_bytes);

    if (!repaint_window.isEmpty()) {
        if (full_repaint) {
            var clear_baseline = try cloneAuthoritativeShadow(
                input.surface.alloc,
                previous_for_diff,
                target.cols,
                target.rows,
            );
            defer clear_baseline.deinit();

            for (repaint_window.ranges()) |range| {
                const clear_start = wire_frame.written().len;
                try writeBandClears(&wire_frame.writer, range.top, range.bottom);
                const clear_bytes = wire_frame.written()[clear_start..];
                try clear_baseline.feed(clear_bytes);
                try vt_emulator.Grid.diffBand(clear_baseline, target.*, range.top, range.bottom, &wire_frame.writer);
            }
        } else {
            for (repaint_window.ranges()) |range| {
                try vt_emulator.Grid.diffBand(previous_for_diff.*, target.*, range.top, range.bottom, &wire_frame.writer);
            }
        }
    }

    try writeCursorPosition(&wire_frame.writer, target.*);
    if (input.synchronized_update) try wire_frame.writer.writeAll("\x1b[?2026l");
    if (target.cursor_visible) try wire_frame.writer.writeAll("\x1b[?25h");
    return prefix_len;
}

fn recoverPartialFrame(
    input: FrameCommitInput,
    changed_cells: usize,
    full_repaint: bool,
    wire_frame: []const u8,
    accepted_write: AcceptedFrameWrite,
    scroll_commit: frame_scroll_plan.FrameScrollCommit,
) !FrameCommitResult {
    const cleanup = recoveryBytes(input.synchronized_update, input.previous.autowrap);
    const cleanup_result = input.sink.write_frame(input.sink.ctx, input.metrics, cleanup);
    _ = acceptedBytesForSinkResult(cleanup, cleanup_result) catch {
        debug_trace.logf(
            "frame_commit",
            "wire_frame bytes={d} accepted_bytes={d} applied_scroll_rows={d} cleanup={s}",
            .{ wire_frame.len, accepted_write.accepted_bytes, accepted_write.applied_scroll_rows, @tagName(CleanupState.failed) },
        );
        return error.TerminalSyncRecoveryFailed;
    };
    switch (cleanup_result) {
        .complete => {},
        .partial => {
            debug_trace.logf(
                "frame_commit",
                "wire_frame bytes={d} accepted_bytes={d} applied_scroll_rows={d} cleanup={s}",
                .{ wire_frame.len, accepted_write.accepted_bytes, accepted_write.applied_scroll_rows, @tagName(CleanupState.failed) },
            );
            return error.TerminalSyncRecoveryFailed;
        },
    }
    try repairAcceptedScroll(
        input.surface.alloc,
        input.previous,
        input.surface.plan.layout.cols,
        input.surface.plan.layout.rows,
        scroll_commit.physical_terminal_scroll_rows,
    );
    if (accepted_write.document_append_interrupted) {
        return error.DocumentAppendInterrupted;
    }
    debug_trace.logf(
        "frame_commit",
        "wire_frame bytes={d} accepted_bytes={d} applied_scroll_rows={d} cleanup={s}",
        .{ wire_frame.len, accepted_write.accepted_bytes, accepted_write.applied_scroll_rows, @tagName(CleanupState.complete) },
    );
    return retry_result(
        .terminal_partial_write,
        input.surface.plan,
        scroll_commit,
        input.repaint_window,
        .partial_write,
        changed_cells,
        full_repaint,
        accepted_write.accepted_bytes + cleanup.len,
        accepted_write.scroll_attribution,
        accepted_write.document_append_committed,
    );
}

fn retry_result(
    state: ShadowCommitState,
    plan: paint_plan.PaintPlan,
    scroll_commit: frame_scroll_plan.FrameScrollCommit,
    repaint_window: paint_plan.FrameRepaintWindow,
    reason: paint_plan.FrameInvalidationReason,
    changed_cells: usize,
    full_repaint: bool,
    bytes_written: usize,
    scroll_attribution: FrameScrollAttribution,
    document_append_applied: bool,
) FrameCommitResult {
    std.debug.assert(!state.is_committed());
    var next_invalidation = repaint_window.retryInvalidations(reason);
    if (next_invalidation.isEmpty()) {
        const band = paint_plan.paintedContentBand(plan);
        std.debug.assert(!band.isEmpty());
        next_invalidation.replaceWith(.{
            .reason = reason,
            .top = band.top,
            .bottom = band.bottom,
        });
    }
    std.debug.assert(next_invalidation.len == 1);
    return .{
        .bytes_written = bytes_written,
        .changed_cells = changed_cells,
        .full_repaint = full_repaint,
        .terminal_scroll_rows_committed = scroll_commit.physical_terminal_scroll_rows,
        .scroll_commit_receipt = scroll_commit,
        .scroll_attribution = scroll_attribution,
        .document_append_committed = document_append_applied,
        .committed_cursor_row = 0,
        .committed_cursor_col = 0,
        .shadow_state = state,
        .next_invalidation = next_invalidation,
    };
}

fn recoveryBytes(synchronized_update: bool, expected_autowrap: bool) []const u8 {
    if (synchronized_update) {
        return if (expected_autowrap)
            "\x18\x1b]8;;\x1b\\\x1b[0m\x1b[?2026l\x1b[?25h"
        else
            "\x18\x1b]8;;\x1b\\\x1b[0m\x1b[?2026l\x1b[?7l\x1b[?25h";
    }
    return if (expected_autowrap)
        "\x18\x1b]8;;\x1b\\\x1b[0m\x1b[?25h"
    else
        "\x18\x1b]8;;\x1b\\\x1b[0m\x1b[?7l\x1b[?25h";
}

fn acceptedBytesForSinkResult(bytes: []const u8, result: FrameSinkWriteResult) !usize {
    return switch (result) {
        .complete => bytes.len,
        .partial => |partial| if (partial.accepted_bytes <= bytes.len)
            partial.accepted_bytes
        else
            error.InvalidFrameSinkProgress,
    };
}

fn acceptedFrameWrite(
    alloc: Allocator,
    authoritative: *const vt_emulator.Grid,
    target_cols: u16,
    target_rows: u16,
    wire_frame: []const u8,
    sink_result: FrameSinkWriteResult,
    document_append_range: DocumentAppendWireRange,
    frame_movement_segments: FrameMovementSegments,
    complete_scroll_attribution: ?FrameScrollAttribution,
) !AcceptedFrameWrite {
    const accepted_bytes = try acceptedBytesForSinkResult(wire_frame, sink_result);
    const scroll_attribution = if (complete_scroll_attribution != null and accepted_bytes == wire_frame.len)
        complete_scroll_attribution.?
    else
        try attributeAcceptedTerminalScrollRows(
            alloc,
            authoritative,
            target_cols,
            target_rows,
            wire_frame,
            accepted_bytes,
            frame_movement_segments,
        );
    return .{
        .accepted_bytes = accepted_bytes,
        .applied_scroll_rows = scroll_attribution.totalScrollRows(),
        .scroll_attribution = scroll_attribution,
        .document_append_committed = document_append_range.committed(accepted_bytes),
        .document_append_interrupted = document_append_range.interrupted(accepted_bytes),
    };
}

fn validateFrameScrollAttribution(
    alloc: Allocator,
    authoritative: *const vt_emulator.Grid,
    target_cols: u16,
    target_rows: u16,
    wire_frame: []const u8,
    frame_movement_segments: FrameMovementSegments,
    movement_rows: frame_scroll_plan.TerminalMovementRows,
) !FrameScrollAttribution {
    const attribution = try attributeAcceptedTerminalScrollRows(
        alloc,
        authoritative,
        target_cols,
        target_rows,
        wire_frame,
        wire_frame.len,
        frame_movement_segments,
    );
    if (attribution.neutralScrollRows() != 0 or
        attribution.document_append_scroll_rows != movement_rows.materialized_scroll_rows or
        attribution.alignment_scroll_rows != movement_rows.alignment_scroll_rows or
        attribution.totalScrollRows() != movement_rows.emittedScrollRows())
    {
        return error.InvalidFrameScrollPlan;
    }
    return attribution;
}

fn countAcceptedTerminalScrollRows(
    alloc: Allocator,
    authoritative: *const vt_emulator.Grid,
    target_cols: u16,
    target_rows: u16,
    wire_frame: []const u8,
    accepted_bytes: usize,
) !u16 {
    const attribution = try attributeAcceptedTerminalScrollRows(
        alloc,
        authoritative,
        target_cols,
        target_rows,
        wire_frame,
        accepted_bytes,
        FrameMovementSegments.none(),
    );
    return attribution.totalScrollRows();
}

fn attributeAcceptedTerminalScrollRows(
    alloc: Allocator,
    authoritative: *const vt_emulator.Grid,
    target_cols: u16,
    target_rows: u16,
    wire_frame: []const u8,
    accepted_bytes: usize,
    frame_movement_segments: FrameMovementSegments,
) !FrameScrollAttribution {
    const accepted_len = @min(accepted_bytes, wire_frame.len);
    if (accepted_len == 0) return .{};
    var simulated = try cloneAuthoritativeShadow(alloc, authoritative, target_cols, target_rows);
    defer simulated.deinit();
    var attribution: FrameScrollAttribution = .{};
    var cursor: usize = 0;

    const document_append = frame_movement_segments.document_append;
    if (document_append.hasBytes()) {
        const segment_start = @min(document_append.start, accepted_len);
        try feedNeutralAttributionRange(
            &simulated,
            wire_frame,
            cursor,
            segment_start,
            frame_movement_segments,
            &attribution,
        );
        cursor = segment_start;
        const segment_end = @min(document_append.end, accepted_len);
        try feedAttributionRange(
            &simulated,
            wire_frame,
            cursor,
            segment_end,
            .document_append,
            &attribution,
        );
        cursor = segment_end;
    }

    const alignment_scroll = frame_movement_segments.alignment_scroll;
    if (alignment_scroll.hasBytes()) {
        const segment_start = @min(alignment_scroll.start, accepted_len);
        try feedNeutralAttributionRange(
            &simulated,
            wire_frame,
            cursor,
            segment_start,
            frame_movement_segments,
            &attribution,
        );
        cursor = segment_start;
        const segment_end = @min(alignment_scroll.end, accepted_len);
        try feedAttributionRange(
            &simulated,
            wire_frame,
            cursor,
            segment_end,
            .alignment_scroll,
            &attribution,
        );
        cursor = segment_end;
    }

    try feedNeutralAttributionRange(
        &simulated,
        wire_frame,
        cursor,
        accepted_len,
        frame_movement_segments,
        &attribution,
    );
    return attribution;
}

fn feedNeutralAttributionRange(
    simulated: *vt_emulator.Grid,
    wire_frame: []const u8,
    start: usize,
    end: usize,
    frame_movement_segments: FrameMovementSegments,
    attribution: *FrameScrollAttribution,
) !void {
    var cursor = start;
    if (cursor < @min(end, frame_movement_segments.movement_start)) {
        const control_end = @min(end, frame_movement_segments.movement_start);
        try feedAttributionRange(simulated, wire_frame, cursor, control_end, .control_prefix, attribution);
        cursor = control_end;
    }
    if (cursor < @min(end, frame_movement_segments.movement_end)) {
        const movement_gap_end = @min(end, frame_movement_segments.movement_end);
        try feedAttributionRange(simulated, wire_frame, cursor, movement_gap_end, .movement_gap, attribution);
        cursor = movement_gap_end;
    }
    if (cursor < end) {
        try feedAttributionRange(simulated, wire_frame, cursor, end, .paint_tail, attribution);
    }
}

fn feedAttributionRange(
    simulated: *vt_emulator.Grid,
    wire_frame: []const u8,
    start: usize,
    end: usize,
    bucket: ScrollAttributionBucket,
    attribution: *FrameScrollAttribution,
) !void {
    if (end <= start) return;
    var stats: vt_emulator.FeedStats = .{};
    try simulated.feedWithStats(wire_frame[start..end], &stats);
    switch (bucket) {
        .control_prefix => attribution.control_prefix_scroll_rows +|= stats.scroll_rows,
        .document_append => attribution.document_append_scroll_rows +|= stats.scroll_rows,
        .alignment_scroll => attribution.alignment_scroll_rows +|= stats.scroll_rows,
        .movement_gap => attribution.movement_gap_scroll_rows +|= stats.scroll_rows,
        .paint_tail => attribution.paint_tail_scroll_rows +|= stats.scroll_rows,
    }
}

fn authoritativeShadowHasSteadyState(
    shadow: vt_emulator.Grid,
    expected_autowrap: bool,
    expected_cursor_visible: bool,
) bool {
    return !shadow.defer_sync_updates and
        !shadow.sync_active and
        shadow.autowrap == expected_autowrap and
        shadow.cursor_visible == expected_cursor_visible and
        shadow.current_style.eql(.{});
}

fn cloneAuthoritativeShadow(
    alloc: Allocator,
    authoritative: *const vt_emulator.Grid,
    target_cols: u16,
    target_rows: u16,
) !vt_emulator.Grid {
    var next = try authoritative.clone(alloc);
    errdefer next.deinit();
    try next.copySavedNormalScreenFrom(authoritative.*);
    try next.resize(target_cols, target_rows);
    next.defer_sync_updates = false;
    next.autowrap = authoritative.autowrap;
    next.cursor_row = @min(@max(authoritative.cursor_row, 1), target_rows);
    next.cursor_col = @min(@max(authoritative.cursor_col, 1), target_cols);
    next.cursor_visible = authoritative.cursor_visible;
    next.pending_wrap = authoritative.pending_wrap;
    try next.copyPresentationStateFrom(authoritative.*);
    return next;
}

fn blankResetReplayShadow(
    alloc: Allocator,
    authoritative: *const vt_emulator.Grid,
    target_cols: u16,
    target_rows: u16,
) !vt_emulator.Grid {
    var next = try vt_emulator.Grid.init(alloc, target_cols, target_rows);
    errdefer next.deinit();
    next.autowrap = authoritative.autowrap;
    next.cursor_visible = authoritative.cursor_visible;
    return next;
}

test "authoritative shadow clone retains the normal buffer during an alternate screen" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 12, 3);
    defer previous.deinit();

    try previous.feed("normal");
    try previous.feed("\x1b[?1049h");
    try previous.feed("alternate");

    var cloned = try cloneAuthoritativeShadow(std.testing.allocator, &previous, 12, 3);
    defer cloned.deinit();
    try cloned.feed("\x1b[?1049l");

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(std.testing.allocator);
    try cloned.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("normal", row.items);
}

test "normal-screen transition precedes document movement in the prepared shadow" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("normal");
    try previous.feed("\x1b[?1049h");
    try previous.feed("alternate");

    const document_append: frame_scroll_plan.FrameDocumentAppend = .{
        .bytes = "doc",
        .start_row = 2,
        .start_col = 1,
    };
    const transition: FrameTerminalTransition = .{
        .restore_normal_screen = .{ .mouse_tracking_active = true },
    };
    var movement = try prepareTerminalMovementForFrame(
        std.testing.allocator,
        &previous,
        document_append,
        0,
        0,
        8,
        4,
        0,
        transition,
    );
    defer movement.deinit(std.testing.allocator);

    const restore = ui_terminal.alternateScreenFrameRestoreSequence(true);
    try std.testing.expectEqualStrings(
        restore,
        movement.bytes[movement.segments.terminal_transition.start..movement.segments.terminal_transition.end],
    );
    try std.testing.expectEqual(
        movement.segments.terminal_transition.end,
        movement.segments.document_append.start,
    );

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(std.testing.allocator);
    try movement.post_movement.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("normal", row.items);
    row.clearRetainingCapacity();
    try movement.post_movement.rowTextTrimmed(2, &row);
    try std.testing.expectEqualStrings("doc", row.items);
}

fn feedCanonicalScroll(shadow: *vt_emulator.Grid, target_rows: u16, accepted_scroll_rows: u16) !void {
    var scroll: std.Io.Writer.Allocating = .init(shadow.alloc);
    defer scroll.deinit();
    try writeTerminalScroll(&scroll.writer, accepted_scroll_rows, target_rows);
    try shadow.feed(scroll.written());
}

fn repairAcceptedScroll(
    alloc: Allocator,
    authoritative: *vt_emulator.Grid,
    target_cols: u16,
    target_rows: u16,
    accepted_scroll_rows: u16,
) !void {
    if (accepted_scroll_rows == 0) return;
    if (consumeShadowTestFault(.repair_resize)) return error.ShadowScrollRepairFailed;

    var repaired = cloneAuthoritativeShadow(alloc, authoritative, target_cols, target_rows) catch
        return error.ShadowScrollRepairFailed;
    errdefer repaired.deinit();
    repaired.cursor_visible = true;
    repaired.sync_active = false;
    if (consumeShadowTestFault(.repair_canonical_feed)) return error.ShadowScrollRepairFailed;
    feedCanonicalScroll(&repaired, target_rows, accepted_scroll_rows) catch
        return error.ShadowScrollRepairFailed;
    if (!authoritativeShadowHasSteadyState(repaired, authoritative.autowrap, true)) {
        return error.ShadowScrollRepairFailed;
    }

    authoritative.deinit();
    authoritative.* = repaired;
}

fn shadowFeedFailedWithRepair(
    input: FrameCommitInput,
    changed_cells: usize,
    full_repaint: bool,
    bytes_written: usize,
    scroll_commit: frame_scroll_plan.FrameScrollCommit,
    scroll_attribution: FrameScrollAttribution,
    document_append_committed: bool,
    err: anyerror,
) !FrameCommitResult {
    debug_trace.logf(
        "frame_commit",
        "shadow_feed_failed bytes={d} changed_cells={d} full_repaint={s} err={s}",
        .{ bytes_written, changed_cells, if (full_repaint) "true" else "false", @errorName(err) },
    );
    try repairAcceptedScroll(
        input.surface.alloc,
        input.previous,
        input.surface.plan.layout.cols,
        input.surface.plan.layout.rows,
        scroll_commit.physical_terminal_scroll_rows,
    );
    return retry_result(
        .shadow_feed_failed,
        input.surface.plan,
        scroll_commit,
        input.repaint_window,
        .shadow_feed_failure,
        changed_cells,
        full_repaint,
        bytes_written,
        scroll_attribution,
        document_append_committed,
    );
}

fn consumeShadowTestFault(fault: ShadowTestFault) bool {
    if (!builtin.is_test) return false;
    if (shadow_test_fault != fault) return false;
    shadow_test_fault = .none;
    return true;
}

fn invalidationRequiresFullRepaint(set: paint_plan.FrameInvalidationSet) bool {
    for (set.ranges()) |range| {
        switch (range.reason) {
            .reserved_gap_clear, .owned_band_change => {},
            .resize,
            .viewport_reanchor,
            .terminal_scroll,
            .external_clear,
            .toggle_command_output,
            .partial_write,
            .shadow_feed_failure,
            .diagnostic_wipe,
            => return true,
        }
    }
    return false;
}

fn writeBandClears(out: *std.Io.Writer, top: u16, bottom: u16) !void {
    try out.writeAll("\x1b[0m");
    var row = top;
    while (row <= bottom) : (row += 1) {
        try out.print("\x1b[{d};1H\x1b[2K", .{row});
    }
}

fn writeTerminalScroll(out: *std.Io.Writer, scroll_rows: u16, bottom_row: u16) !void {
    if (scroll_rows == 0 or bottom_row == 0) return;
    try out.print("\x1b[{d};1H", .{bottom_row});
    var row: u16 = 0;
    while (row < scroll_rows) : (row += 1) {
        try out.writeByte('\n');
    }
}

fn writeDocumentAppendClear(
    out: *std.Io.Writer,
    start_row: u16,
    start_col: u16,
    target_cols: u16,
    target_rows: u16,
) !void {
    try out.writeAll("\x1b[0m");
    if (start_col < target_cols) {
        try out.writeAll("\x1b[0J");
        return;
    }
    if (start_row == target_rows) return;
    try out.print(
        "\x1b[{d};1H\x1b[0J\x1b[{d};{d}H",
        .{ start_row + 1, start_row, start_col },
    );
}

pub fn prepareTerminalMovement(
    alloc: Allocator,
    authoritative: *const vt_emulator.Grid,
    document_append: frame_scroll_plan.FrameDocumentAppend,
    planned_scroll_rows: u16,
    target_cols: u16,
    target_rows: u16,
) !PreparedTerminalMovement {
    return prepareTerminalMovementForFrame(
        alloc,
        authoritative,
        document_append,
        planned_scroll_rows,
        planned_scroll_rows,
        target_cols,
        target_rows,
        0,
        .none,
    );
}

pub fn prepareTerminalMovementForFrame(
    alloc: Allocator,
    authoritative: *const vt_emulator.Grid,
    document_append: frame_scroll_plan.FrameDocumentAppend,
    planned_scroll_rows: u16,
    non_deferable_scroll_rows: u16,
    target_cols: u16,
    target_rows: u16,
    alignment_clear_start_row: u16,
    terminal_transition: FrameTerminalTransition,
) !PreparedTerminalMovement {
    if (document_append.reset_replay and planned_scroll_rows != 0) {
        return error.InvalidFrameScrollPlan;
    }
    const reset_replay_starts_blank = document_append.reset_replay and switch (terminal_transition) {
        .none => true,
        .restore_normal_screen => false,
    };
    var post_movement = if (reset_replay_starts_blank)
        try blankResetReplayShadow(alloc, authoritative, target_cols, target_rows)
    else
        try cloneAuthoritativeShadow(alloc, authoritative, target_cols, target_rows);
    errdefer post_movement.deinit();

    var bytes: std.Io.Writer.Allocating = .init(alloc);
    defer bytes.deinit();

    const transition_segment = try appendTerminalTransition(
        &bytes,
        &post_movement,
        terminal_transition,
    );

    const document_movement = try appendDocumentMovement(
        &bytes,
        &post_movement,
        document_append,
        target_cols,
        target_rows,
    );

    const movement_rows = try resolveTerminalMovementRows(
        planned_scroll_rows,
        document_movement.segment.scroll_rows,
        non_deferable_scroll_rows,
        document_append.reset_replay,
        authoritative.cols,
        authoritative.rows,
        target_cols,
        target_rows,
    );
    const requested_alignment_rows =
        planned_scroll_rows -| document_movement.segment.scroll_rows;
    const deferred_alignment_rows =
        requested_alignment_rows -| movement_rows.alignment_scroll_rows;
    if (deferred_alignment_rows > 0) {
        debug_trace.logf(
            "frame_commit",
            "alignment_scroll_deferred rows={d} source={d}x{d} target={d}x{d}",
            .{
                deferred_alignment_rows,
                authoritative.cols,
                authoritative.rows,
                target_cols,
                target_rows,
            },
        );
    }
    const alignment_segment = try appendAlignmentScroll(
        &bytes,
        &post_movement,
        movement_rows.alignment_scroll_rows,
        target_rows,
        if (document_movement.segment.hasBytes()) 0 else alignment_clear_start_row,
    );

    return .{
        .bytes = try bytes.toOwnedSlice(),
        .post_movement = post_movement,
        .document_append_start = document_movement.segment.start,
        .document_append_end = document_movement.segment.end,
        .segments = .{
            .terminal_transition = transition_segment,
            .document_append = document_movement.segment,
            .alignment_scroll = alignment_segment,
        },
        .scroll_rows = movement_rows,
        .terminal_transition = terminal_transition,
        .reset_replay = document_append.reset_replay,
        .source_rows = authoritative.rows,
        .source_cols = authoritative.cols,
        .target_rows = target_rows,
        .target_cols = target_cols,
    };
}

fn appendTerminalTransition(
    bytes: *std.Io.Writer.Allocating,
    post_movement: *vt_emulator.Grid,
    transition: FrameTerminalTransition,
) !TerminalMovementSegment {
    const transition_start = bytes.written().len;
    try bytes.writer.writeAll(transition.sequence());
    const transition_segment = try feedMovementSegment(bytes, post_movement, transition_start);
    if (transition_segment.scroll_rows != 0) return error.InvalidFrameScrollPlan;
    return transition_segment;
}

fn resolveTerminalMovementRows(
    planned_scroll_rows: u16,
    materialized_scroll_rows: u16,
    non_deferable_scroll_rows: u16,
    reset_replay: bool,
    source_cols: u16,
    source_rows: u16,
    target_cols: u16,
    target_rows: u16,
) !frame_scroll_plan.TerminalMovementRows {
    if (non_deferable_scroll_rows > planned_scroll_rows) {
        return error.InvalidFrameScrollPlan;
    }
    var rows = try frame_scroll_plan.TerminalMovementRows.resolve(
        planned_scroll_rows,
        materialized_scroll_rows,
        reset_replay,
    );
    if (!reset_replay and
        (source_cols != target_cols or source_rows != target_rows))
    {
        rows.alignment_scroll_rows =
            non_deferable_scroll_rows -| materialized_scroll_rows;
    }
    return rows;
}

fn appendDocumentMovement(
    bytes: *std.Io.Writer.Allocating,
    post_movement: *vt_emulator.Grid,
    document_append: frame_scroll_plan.FrameDocumentAppend,
    target_cols: u16,
    target_rows: u16,
) !DocumentAppendMovement {
    if (document_append.isEmpty()) return .{};
    for (document_append.bytes, 0..) |byte, index| {
        if (byte == '\n' and (index == 0 or document_append.bytes[index - 1] != '\r'))
            return error.InvalidFrameScrollPlan;
    }

    const append_start = bytes.written().len;
    const start_col = try document_append.validatedStartCol(target_cols, target_rows);
    try bytes.writer.print(
        "\x1b[{d};{d}H",
        .{ document_append.start_row, start_col },
    );
    switch (document_append.clear) {
        .remainder => {
            // Ordinary appends replace everything after the transcript endpoint.
            // Clear it before append rows can promote footer cells into scrollback.
            try writeDocumentAppendClear(
                &bytes.writer,
                document_append.start_row,
                start_col,
                target_cols,
                target_rows,
            );
        },
        .rows => {
            const clear_bottom = (try document_append.validatedClearBottom(target_rows)).?;
            try writeBandClears(&bytes.writer, document_append.start_row, clear_bottom);
            try bytes.writer.print(
                "\x1b[{d};{d}H",
                .{ document_append.start_row, start_col },
            );
        },
    }
    const autowrap_was_enabled = post_movement.autowrap;
    if (!autowrap_was_enabled) try bytes.writer.writeAll("\x1b[?7h");
    try bytes.writer.writeAll(document_append.bytes);
    if (!autowrap_was_enabled) try bytes.writer.writeAll("\x1b[?7l");

    const append_segment = try feedMovementSegment(bytes, post_movement, append_start);
    return .{
        .segment = append_segment,
    };
}

fn appendAlignmentScroll(
    bytes: *std.Io.Writer.Allocating,
    post_movement: *vt_emulator.Grid,
    alignment_scroll_rows: u16,
    target_rows: u16,
    clear_start_row: u16,
) !TerminalMovementSegment {
    const alignment_start = bytes.written().len;
    if (alignment_scroll_rows > 0 and clear_start_row > 0) {
        if (clear_start_row > target_rows) return error.InvalidFrameScrollPlan;
        try writeBandClears(&bytes.writer, clear_start_row, target_rows);
    }
    try writeTerminalScroll(&bytes.writer, alignment_scroll_rows, target_rows);
    const alignment_segment = try feedMovementSegment(bytes, post_movement, alignment_start);
    if (!alignment_segment.hasBytes()) return alignment_segment;

    try validateAlignmentScrollRows(alignment_segment.scroll_rows, alignment_scroll_rows);
    return alignment_segment;
}

fn feedMovementSegment(
    bytes: *std.Io.Writer.Allocating,
    post_movement: *vt_emulator.Grid,
    start: usize,
) !TerminalMovementSegment {
    const end = bytes.written().len;
    if (end == start) return .{
        .start = start,
        .end = end,
        .scroll_rows = 0,
    };
    var stats: vt_emulator.FeedStats = .{};
    try post_movement.feedWithStats(bytes.written()[start..end], &stats);
    return .{
        .start = start,
        .end = end,
        .scroll_rows = stats.scroll_rows,
    };
}

fn validateAlignmentScrollRows(
    applied_scroll_rows: u16,
    requested_scroll_rows: u16,
) !void {
    if (applied_scroll_rows != requested_scroll_rows) {
        return error.InvalidFrameScrollPlan;
    }
}

fn writeCursorPosition(out: *std.Io.Writer, target: vt_emulator.Grid) !void {
    var buf: [32]u8 = undefined;
    const seq = try ui_terminal.moveCursorSequence(&buf, target.cursor_row, target.cursor_col);
    try out.writeAll(seq);
}

fn firstRepaintRow(repaint_window: paint_plan.FrameRepaintWindow) u16 {
    if (repaint_window.isEmpty()) return 0;
    return repaint_window.ranges()[0].top;
}

fn lastRepaintRow(repaint_window: paint_plan.FrameRepaintWindow) u16 {
    if (repaint_window.isEmpty()) return 0;
    return repaint_window.ranges()[repaint_window.ranges().len - 1].bottom;
}

fn countChangedCells(prev: vt_emulator.Grid, target: vt_emulator.Grid, repaint_window: paint_plan.FrameRepaintWindow) usize {
    if (repaint_window.isEmpty()) return 0;
    var changed: usize = 0;
    for (repaint_window.ranges()) |range| {
        var row = range.top;
        while (row <= range.bottom) : (row += 1) {
            var col: u16 = 1;
            while (col <= target.cols) : (col += 1) {
                const p = prev.cellAt(row, col) orelse continue;
                const n = target.cellAt(row, col) orelse continue;
                if (!frame_cell_match.gridCellsEqual(prev, p, target, n)) changed += 1;
            }
        }
    }
    return changed;
}

fn targetMatches(prev: vt_emulator.Grid, target: vt_emulator.Grid, repaint_window: paint_plan.FrameRepaintWindow) bool {
    if (prev.rows != target.rows or prev.cols != target.cols) return false;
    if (!cursorMatches(prev, target)) return false;
    if (repaint_window.isEmpty()) return true;
    for (repaint_window.ranges()) |range| {
        var row = range.top;
        while (row <= range.bottom) : (row += 1) {
            var col: u16 = 1;
            while (col <= target.cols) : (col += 1) {
                const p = prev.cellAt(row, col) orelse return false;
                const n = target.cellAt(row, col) orelse return false;
                if (!frame_cell_match.gridCellsEqual(prev, p, target, n)) return false;
            }
        }
    }
    return true;
}

fn cursorMatches(prev: vt_emulator.Grid, target: vt_emulator.Grid) bool {
    return prev.cursor_row == target.cursor_row and
        prev.cursor_col == target.cursor_col and
        prev.cursor_visible == target.cursor_visible;
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
        .activity = .none,
        .preserved_band = .{ .top = 1, .bottom = 1, .owner = .preserved_shell },
        .transcript_band = .{ .top = 2, .bottom = 2, .owner = .transcript },
        .activity_band = paint_plan.FrameBand.empty(.activity),
        .footer_band = .{ .top = 3, .bottom = 4, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = 3, .col = 1, .visible = true },
        .footer_reservation_source = .footer_layout,
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

const TestSink = struct {
    bytes: std.ArrayList(u8) = .empty,
    fail: bool = false,
    fail_after_prefix: ?usize = null,
    fail_after_scroll_rows: ?u16 = null,
    fail_on_call: ?usize = null,
    invalid_progress: bool = false,
    write_calls: usize = 0,

    fn deinit(self: *TestSink, alloc: Allocator) void {
        self.bytes.deinit(alloc);
    }

    fn frameSink(self: *TestSink) FrameSink {
        return .{ .ctx = self, .write_frame = writeFrame };
    }

    fn writeFrame(ctx: *anyopaque, _: *Metrics, bytes: []const u8) FrameSinkWriteResult {
        const self: *TestSink = @ptrCast(@alignCast(ctx));
        self.write_calls += 1;
        if (self.fail_on_call == self.write_calls) {
            return .{ .partial = .{ .accepted_bytes = 0, .err = error.TestFrameWriteFailure } };
        }
        if (self.write_calls == 1 and self.invalid_progress) {
            return .{ .partial = .{ .accepted_bytes = bytes.len + 1, .err = error.TestFrameWriteFailure } };
        }
        if (self.write_calls == 1) {
            if (self.fail_after_scroll_rows) |rows| {
                const start = std.mem.find(u8, bytes, "\x1b[4;1H") orelse 0;
                const accepted = @min(start + "\x1b[4;1H".len + rows, bytes.len);
                self.bytes.appendSlice(std.testing.allocator, bytes[0..accepted]) catch |err| {
                    return .{ .partial = .{ .accepted_bytes = 0, .err = err } };
                };
                return .{ .partial = .{ .accepted_bytes = accepted, .err = error.TestFrameWriteFailure } };
            }
            if (self.fail_after_prefix) |prefix| {
                const accepted = @min(prefix, bytes.len);
                self.bytes.appendSlice(std.testing.allocator, bytes[0..accepted]) catch |err| {
                    return .{ .partial = .{ .accepted_bytes = 0, .err = err } };
                };
                return .{ .partial = .{ .accepted_bytes = accepted, .err = error.TestFrameWriteFailure } };
            }
            if (self.fail) return .{ .partial = .{ .accepted_bytes = 0, .err = error.TestFrameWriteFailure } };
        }
        self.bytes.appendSlice(std.testing.allocator, bytes) catch |err| {
            return .{ .partial = .{ .accepted_bytes = 0, .err = err } };
        };
        return .complete;
    }
};

fn testScrollPlan(rows: u16) frame_scroll_plan.FrameScrollPlan {
    return frame_scroll_plan.merge(4, 1, 0, rows);
}

fn makeSurface(alloc: Allocator, previous: vt_emulator.Grid, plan: paint_plan.PaintPlan) !frame_surface.FrameSurface {
    var surface = try frame_surface.FrameSurface.initFromShadow(alloc, plan, previous);
    errdefer surface.deinit();
    _ = try surface.writeAnsiBand(plan.transcript_band.top, 1, "hi", .transcript, .same_owner);
    _ = try surface.writeAnsiBand(plan.footer_band.top, 1, ">", .footer, .same_owner);
    surface.cursor_target = .{ .row = plan.footer_band.top, .col = 2, .visible = true };
    return surface;
}

const TestFrameCommitOptions = struct {
    plan: ?paint_plan.PaintPlan = null,
    surface_shadow: ?vt_emulator.Grid = null,
    scroll_rows: u16 = 0,
    document_append: frame_scroll_plan.FrameDocumentAppend = .{},
    terminal_transition: FrameTerminalTransition = .none,
    prepared_movement: ?*const PreparedTerminalMovement = null,
    synchronized_update: ?bool = null,
};

fn flush_test_frame(
    authoritative: *vt_emulator.Grid,
    sink: *TestSink,
    options: TestFrameCommitOptions,
) !FrameCommitResult {
    const plan = options.plan orelse testPlan();
    const surface_shadow = options.surface_shadow orelse authoritative.*;
    var surface = try makeSurface(std.testing.allocator, surface_shadow, plan);
    defer surface.deinit();
    var metrics: Metrics = .{};

    return flushFrame(.{
        .previous = authoritative,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(
            surface.plan,
            .{ .include_transcript = true },
        ),
        .synchronized_update = options.synchronized_update orelse true,
        .scroll_plan = frame_scroll_plan.merge(
            plan.layout.rows,
            1,
            0,
            options.scroll_rows,
        ),
        .document_append = options.document_append,
        .terminal_transition = options.terminal_transition,
        .prepared_movement = options.prepared_movement,
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });
}

test "normal-screen restore and inline repaint commit in one sink write" {
    inline for ([_]bool{ false, true }) |synchronized_update| {
        var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
        defer previous.deinit();
        try previous.feed("normal");
        try previous.feed("\x1b[?1049h");
        try previous.feed("alternate");

        const transition: FrameTerminalTransition = .{
            .restore_normal_screen = .{ .mouse_tracking_active = true },
        };
        var movement = try prepareTerminalMovementForFrame(
            std.testing.allocator,
            &previous,
            .{},
            0,
            0,
            8,
            4,
            0,
            transition,
        );
        defer movement.deinit(std.testing.allocator);

        var plan = testPlan();
        plan.synchronized_update = synchronized_update;
        var sink = TestSink{};
        defer sink.deinit(std.testing.allocator);
        const result = try flush_test_frame(
            &previous,
            &sink,
            .{
                .plan = plan,
                .surface_shadow = movement.post_movement,
                .terminal_transition = transition,
                .prepared_movement = &movement,
                .synchronized_update = synchronized_update,
            },
        );

        try std.testing.expect(result.is_committed());
        try std.testing.expectEqual(@as(usize, 1), sink.write_calls);
        const restore_start = std.mem.find(
            u8,
            sink.bytes.items,
            ui_terminal.alternateScreenFrameRestoreSequence(true),
        ) orelse return error.TestExpectedNormalScreenRestore;
        if (synchronized_update) {
            const sync_start = std.mem.find(u8, sink.bytes.items, "\x1b[?2026h") orelse
                return error.TestExpectedSyncStart;
            const sync_end = std.mem.find(u8, sink.bytes.items, "\x1b[?2026l") orelse
                return error.TestExpectedSyncEnd;
            try std.testing.expect(sync_start < restore_start);
            try std.testing.expect(restore_start < sync_end);
        } else {
            try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[?2026h") == null);
            try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[?2026l") == null);
        }

        var row: std.ArrayList(u8) = .empty;
        defer row.deinit(std.testing.allocator);
        try previous.rowTextTrimmed(1, &row);
        try std.testing.expectEqualStrings("normal", row.items);
    }
}

test "normal-screen restore preserves saved modes through reset replay" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    previous.autowrap = false;
    try previous.feed("normal");
    try previous.feed("\x1b[?1049h");
    try previous.feed("alternate");

    const transition: FrameTerminalTransition = .{
        .restore_normal_screen = .{ .mouse_tracking_active = true },
    };
    const document_append: frame_scroll_plan.FrameDocumentAppend = .{
        .bytes = "result\r\n",
        .start_row = 1,
        .start_col = 1,
        .reset_replay = true,
    };
    var movement = try prepareTerminalMovementForFrame(
        std.testing.allocator,
        &previous,
        document_append,
        0,
        0,
        8,
        4,
        0,
        transition,
    );
    defer movement.deinit(std.testing.allocator);

    try std.testing.expect(!movement.post_movement.autowrap);
    try std.testing.expect(std.mem.find(u8, movement.bytes, "\x1b[?7l") != null);

    var plan = testPlan();
    plan.reset_terminal = true;
    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    const result = try flush_test_frame(
        &previous,
        &sink,
        .{
            .plan = plan,
            .surface_shadow = movement.post_movement,
            .document_append = document_append,
            .terminal_transition = transition,
            .prepared_movement = &movement,
        },
    );

    try std.testing.expect(result.is_committed());
    try std.testing.expect(!previous.autowrap);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, sink.bytes.items, ui_terminal.alternate_screen_leave_sequence),
    );
    const sync_start = std.mem.find(u8, sink.bytes.items, "\x1b[?2026h") orelse
        return error.TestExpectedSyncStart;
    const reset_clear = std.mem.find(u8, sink.bytes.items, "\x1b[0m\x1b[2J\x1b[3J\x1b[H") orelse
        return error.TestExpectedResetClear;
    const cursor_hide = std.mem.find(u8, sink.bytes.items, "\x1b[?25l") orelse
        return error.TestExpectedCursorHide;
    const restore = std.mem.find(
        u8,
        sink.bytes.items,
        ui_terminal.alternateScreenFrameRestoreSequence(true),
    ) orelse return error.TestExpectedNormalScreenRestore;
    try std.testing.expect(sync_start < cursor_hide);
    try std.testing.expect(cursor_hide < reset_clear);
    try std.testing.expect(reset_clear < restore);
}

test "normal-screen restore partial write retries to the committed frame" {
    const transition: FrameTerminalTransition = .{
        .restore_normal_screen = .{ .mouse_tracking_active = true },
    };

    var uninterrupted = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer uninterrupted.deinit();
    try uninterrupted.feed("normal");
    try uninterrupted.feed("\x1b[?1049h");
    try uninterrupted.feed("alternate");
    var uninterrupted_movement = try prepareTerminalMovementForFrame(
        std.testing.allocator,
        &uninterrupted,
        .{},
        0,
        0,
        8,
        4,
        0,
        transition,
    );
    defer uninterrupted_movement.deinit(std.testing.allocator);
    var uninterrupted_sink = TestSink{};
    defer uninterrupted_sink.deinit(std.testing.allocator);
    const uninterrupted_result = try flush_test_frame(
        &uninterrupted,
        &uninterrupted_sink,
        .{
            .surface_shadow = uninterrupted_movement.post_movement,
            .terminal_transition = transition,
            .prepared_movement = &uninterrupted_movement,
        },
    );
    try std.testing.expect(uninterrupted_result.is_committed());

    var authoritative = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer authoritative.deinit();
    try authoritative.feed("normal");
    try authoritative.feed("\x1b[?1049h");
    try authoritative.feed("alternate");
    var physical = try authoritative.clone(std.testing.allocator);
    defer physical.deinit();
    try physical.copySavedNormalScreenFrom(authoritative);

    var movement = try prepareTerminalMovementForFrame(
        std.testing.allocator,
        &authoritative,
        .{},
        0,
        0,
        8,
        4,
        0,
        transition,
    );
    defer movement.deinit(std.testing.allocator);
    const cut = "\x1b[?2026h".len + "\x1b[?25l".len +
        ui_terminal.alternateScreenFrameRestoreSequence(true).len + 3;
    var failing_sink = TestSink{ .fail_after_prefix = cut };
    defer failing_sink.deinit(std.testing.allocator);
    const failed = try flush_test_frame(
        &authoritative,
        &failing_sink,
        .{
            .surface_shadow = movement.post_movement,
            .terminal_transition = transition,
            .prepared_movement = &movement,
        },
    );
    try std.testing.expectEqual(ShadowCommitState.terminal_partial_write, failed.shadow_state);
    try physical.feed(failing_sink.bytes.items);

    var retry_plan = testPlan();
    try retry_plan.invalidation.append(failed.retry_invalidation().?);
    retry_plan.footer_clean_allowed = false;
    var retry_movement = try prepareTerminalMovementForFrame(
        std.testing.allocator,
        &authoritative,
        .{},
        0,
        0,
        8,
        4,
        0,
        transition,
    );
    defer retry_movement.deinit(std.testing.allocator);
    var retry_sink = TestSink{};
    defer retry_sink.deinit(std.testing.allocator);
    const retry = try flush_test_frame(
        &authoritative,
        &retry_sink,
        .{
            .plan = retry_plan,
            .surface_shadow = retry_movement.post_movement,
            .terminal_transition = transition,
            .prepared_movement = &retry_movement,
        },
    );
    try std.testing.expect(retry.is_committed());
    try physical.feed(retry_sink.bytes.items);
    try expect_grid_and_cursor_equal(uninterrupted, authoritative);
    try expect_grid_and_cursor_equal(uninterrupted, physical);
}

fn expect_grid_and_cursor_equal(expected: vt_emulator.Grid, actual: vt_emulator.Grid) !void {
    try std.testing.expectEqual(expected.cols, actual.cols);
    try std.testing.expectEqual(expected.rows, actual.rows);
    try std.testing.expectEqual(expected.cursor_row, actual.cursor_row);
    try std.testing.expectEqual(expected.cursor_col, actual.cursor_col);
    try std.testing.expectEqual(expected.cursor_visible, actual.cursor_visible);
    try std.testing.expectEqual(expected.autowrap, actual.autowrap);
    try std.testing.expectEqual(expected.pending_wrap, actual.pending_wrap);
    try std.testing.expectEqual(expected.sync_active, actual.sync_active);
    try std.testing.expect(expected.current_style.eql(actual.current_style));

    var row: u16 = 1;
    while (row <= expected.rows) : (row += 1) {
        var col: u16 = 1;
        while (col <= expected.cols) : (col += 1) {
            const expected_cell = expected.cellAt(row, col).?;
            const actual_cell = actual.cellAt(row, col).?;
            try std.testing.expect(frame_cell_match.gridCellsEqual(
                expected,
                expected_cell,
                actual,
                actual_cell,
            ));
        }
    }
}

const RecoveryScenario = enum {
    resize,
    external_clear,
    reset,
};

fn recovery_scenario_plan(scenario: RecoveryScenario) !paint_plan.PaintPlan {
    var plan = testPlan();
    switch (scenario) {
        .resize => {
            plan.layout.rows = 5;
            plan.layout.content_bottom = 3;
            plan.layout.divider_top_row = 4;
            plan.layout.input_row = 4;
            plan.layout.divider_bottom_row = 4;
            plan.layout.hint_row = 5;
            plan.viewport.bottom_row = 3;
            plan.viewport.last_visible_row = 3;
            plan.transcript_band.bottom = 3;
            plan.footer.top = 4;
            plan.footer.top_divider = 4;
            plan.footer.banner = 4;
            plan.footer.input_base = 4;
            plan.footer.picker_divider = 4;
            plan.footer.picker_start = 5;
            plan.footer.bottom_divider = 4;
            plan.footer.hint = 5;
            plan.footer_band = .{ .top = 4, .bottom = 5, .owner = .footer };
            plan.cursor_target = .{ .row = 4, .col = 2, .visible = true };
        },
        .external_clear => {
            try plan.invalidation.append(.{
                .reason = .external_clear,
                .top = 2,
                .bottom = 4,
            });
            plan.footer_clean_allowed = false;
        },
        .reset => plan.reset_terminal = true,
    }
    try plan.validate();
    return plan;
}

fn prepare_physical_grid_for_scenario(grid: *vt_emulator.Grid, scenario: RecoveryScenario) !void {
    try grid.feed("\x1b[1;1Hold\x1b[2;1Hstate");
    switch (scenario) {
        .resize => try grid.resize(8, 5),
        .external_clear => try grid.feed("\x1b[2;1H\x1b[2K\x1b[3;1H\x1b[2K\x1b[4;1H\x1b[2K"),
        .reset => {},
    }
}

fn makeCombiningSurface(alloc: Allocator, previous: vt_emulator.Grid, plan: paint_plan.PaintPlan) !frame_surface.FrameSurface {
    var surface = try frame_surface.FrameSurface.initFromShadow(alloc, plan, previous);
    errdefer surface.deinit();
    _ = try surface.writeAnsiBand(2, 1, "e\u{0301}", .transcript, .same_owner);
    _ = try surface.writeAnsiBand(3, 1, ">", .footer, .same_owner);
    surface.cursor_target = .{ .row = 3, .col = 2, .visible = true };
    return surface;
}

test "flushFrame writes one normal diff and feeds shadow after sink success" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    try std.testing.expect(result.is_committed());
    const committed_cursor = result.committed_cursor().?;
    try std.testing.expectEqual(@as(u16, 3), committed_cursor.row);
    try std.testing.expectEqual(@as(u16, 2), committed_cursor.col);
    try std.testing.expect(committed_cursor.visible);
    try std.testing.expect(result.bytes_written > 0);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "hi") != null);
    try std.testing.expectEqual(@as(u21, 'h'), previous.cellAt(2, 1).?.codepoint);
    try std.testing.expectEqual(@as(u16, 3), previous.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), previous.cursor_col);
    const cursor_hide = std.mem.find(u8, sink.bytes.items, "\x1b[?25l") orelse return error.TestExpectedCursorHide;
    const final_cursor = std.mem.findLast(u8, sink.bytes.items, "\x1b[3;2H") orelse return error.TestExpectedFinalCursor;
    const cursor_show = std.mem.find(u8, sink.bytes.items, "\x1b[?25h") orelse return error.TestExpectedCursorShow;
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[?2026h") == null);
    try std.testing.expect(cursor_hide < final_cursor);
    try std.testing.expect(final_cursor < cursor_show);
    try std.testing.expect(std.mem.endsWith(u8, sink.bytes.items, "\x1b[?25h"));
}

test "flushFrame commits hidden cursor coordinates after sink success" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var plan = testPlan();
    plan.cursor_target = .{ .row = 4, .col = 8, .visible = false };
    var surface = try makeSurface(std.testing.allocator, previous, plan);
    defer surface.deinit();
    surface.cursor_target = plan.cursor_target;

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    try std.testing.expectEqual(@as(u16, 4), previous.cursor_row);
    try std.testing.expectEqual(@as(u16, 8), previous.cursor_col);
    try std.testing.expect(!previous.cursor_visible);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[?25h") == null);
    try std.testing.expect(std.mem.endsWith(u8, sink.bytes.items, "\x1b[?2026l"));
}

test "flushFrame skips no-op frames without toggling cursor visibility" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var first_surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer first_surface.deinit();

    var first_sink = TestSink{};
    defer first_sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    _ = try flushFrame(.{
        .previous = &previous,
        .surface = &first_surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(first_surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(0),
        .sink = first_sink.frameSink(),
        .metrics = &metrics,
    });

    var no_op_surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer no_op_surface.deinit();

    var no_op_sink = TestSink{};
    defer no_op_sink.deinit(std.testing.allocator);
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &no_op_surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(no_op_surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(0),
        .sink = no_op_sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    try std.testing.expectEqual(@as(usize, 0), result.bytes_written);
    try std.testing.expectEqual(@as(usize, 0), result.changed_cells);
    try std.testing.expectEqual(@as(usize, 0), no_op_sink.write_calls);
    try std.testing.expectEqual(@as(usize, 0), no_op_sink.bytes.items.len);
    try std.testing.expectEqual(@as(u16, 3), previous.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), previous.cursor_col);
    try std.testing.expect(previous.cursor_visible);
}

test "flushFrame full repaint preserves combining suffix bytes" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var plan = testPlan();
    try plan.invalidation.append(.{ .reason = .external_clear, .top = 2, .bottom = 2 });
    plan.footer_clean_allowed = false;
    var surface = try makeCombiningSurface(std.testing.allocator, previous, plan);
    defer surface.deinit();

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expect(result.full_repaint);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "e\u{0301}") != null);
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(std.testing.allocator);
    try previous.rowTextTrimmed(2, &row_text);
    try std.testing.expectEqualStrings("e\u{0301}", row_text.items);
}

test "flushFrame skips unchanged combining suffix frame" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var first_surface = try makeCombiningSurface(std.testing.allocator, previous, testPlan());
    defer first_surface.deinit();
    var first_sink = TestSink{};
    defer first_sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    _ = try flushFrame(.{
        .previous = &previous,
        .surface = &first_surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(first_surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(0),
        .sink = first_sink.frameSink(),
        .metrics = &metrics,
    });

    var second_surface = try makeCombiningSurface(std.testing.allocator, previous, testPlan());
    defer second_surface.deinit();
    var second_sink = TestSink{};
    defer second_sink.deinit(std.testing.allocator);
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &second_surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(second_surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(0),
        .sink = second_sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(@as(usize, 0), result.bytes_written);
    try std.testing.expectEqual(@as(usize, 0), result.changed_cells);
    try std.testing.expectEqual(@as(usize, 0), second_sink.write_calls);
}

test "flushFrame writes nonempty zero-scroll document append even when target already matches" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    previous.cursor_row = 3;
    previous.cursor_col = 1;

    const append = frame_scroll_plan.FrameDocumentAppend{
        .bytes = "\x1b]8;;https://append.example\x1b\\\x1b]8;;\x1b\\",
        .start_row = 3,
        .start_col = 1,
    };
    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        append,
        0,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);
    try std.testing.expect(movement.bytes.len > 0);
    try std.testing.expectEqual(@as(u16, 0), movement.scroll_rows.materialized_scroll_rows);

    var plan = testPlan();
    plan.cursor_target = .{ .row = 3, .col = 1, .visible = true };
    var surface = try frame_surface.FrameSurface.initFromShadow(
        std.testing.allocator,
        plan,
        movement.post_movement,
    );
    defer surface.deinit();

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = testScrollPlan(0),
        .document_append = append,
        .prepared_movement = &movement,
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    try std.testing.expect(result.document_append_committed);
    try std.testing.expect(result.bytes_written > 0);
    try std.testing.expectEqual(@as(usize, 1), sink.write_calls);
    try std.testing.expect(
        std.mem.find(u8, sink.bytes.items, "https://append.example") != null,
    );
    try std.testing.expectEqualStrings(
        "https://append.example",
        previous.hyperlinkUrl(1).?,
    );
}

test "terminal movement clears only bounded history rows before alignment" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[1;1Hone\x1b[2;1Htwo\x1b[3;1Hthree\x1b[4;1Hfour");

    const append = frame_scroll_plan.FrameDocumentAppend{
        .bytes = "\r\n",
        .start_row = 1,
        .start_col = 1,
        .clear = .{ .rows = 1 },
    };
    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        append,
        1,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);

    try std.testing.expect(movement.hasDocumentAppend());
    try std.testing.expectEqual(@as(u16, 1), movement.scroll_rows.alignment_scroll_rows);
    try std.testing.expect(std.mem.find(u8, movement.bytes, "\x1b[0J") == null);
    try std.testing.expect(std.mem.find(u8, movement.bytes, "\x1b[1;1H\x1b[2K") != null);
    try std.testing.expect(std.mem.find(u8, movement.bytes, "\x1b[2;1H\x1b[2K") == null);
}

test "flushFrame restores visible cursor after synchronized update" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    const sync_begin = std.mem.find(u8, sink.bytes.items, "\x1b[?2026h") orelse return error.TestExpectedSyncBegin;
    const cursor_hide = std.mem.find(u8, sink.bytes.items, "\x1b[?25l") orelse return error.TestExpectedCursorHide;
    const final_cursor = std.mem.findLast(u8, sink.bytes.items, "\x1b[3;2H") orelse return error.TestExpectedFinalCursor;
    const sync_end = std.mem.find(u8, sink.bytes.items, "\x1b[?2026l") orelse return error.TestExpectedSyncEnd;
    const cursor_show = std.mem.find(u8, sink.bytes.items, "\x1b[?25h") orelse return error.TestExpectedCursorShow;
    try std.testing.expect(sync_begin < cursor_hide);
    try std.testing.expect(cursor_hide < final_cursor);
    try std.testing.expect(final_cursor < sync_end);
    try std.testing.expect(sync_end < cursor_show);
    try std.testing.expectEqual(@as(usize, 1), sink.write_calls);
    try std.testing.expect(std.mem.endsWith(u8, sink.bytes.items, "\x1b[?25h"));
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[3J") == null);
}

test "flushFrame clears display before scrollback inside synchronized repaint" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[1;1Hshell");

    var plan = testPlan();
    plan.reset_terminal = true;
    var surface = try makeSurface(std.testing.allocator, previous, plan);
    defer surface.deinit();

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    const sync_begin = std.mem.find(u8, sink.bytes.items, "\x1b[?2026h") orelse return error.TestExpectedSyncBegin;
    const cursor_hide = std.mem.find(u8, sink.bytes.items, "\x1b[?25l") orelse return error.TestExpectedCursorHide;
    const reset_style = std.mem.find(u8, sink.bytes.items, "\x1b[0m") orelse return error.TestExpectedResetStyle;
    const clear_scrollback = std.mem.find(u8, sink.bytes.items, "\x1b[3J") orelse return error.TestExpectedScrollbackClear;
    const clear_display = std.mem.find(u8, sink.bytes.items, "\x1b[2J") orelse return error.TestExpectedDisplayClear;
    const home = std.mem.find(u8, sink.bytes.items, "\x1b[H") orelse return error.TestExpectedHome;
    try std.testing.expect(sync_begin < cursor_hide);
    try std.testing.expect(cursor_hide < reset_style);
    try std.testing.expect(reset_style < clear_display);
    try std.testing.expect(clear_display < clear_scrollback);
    try std.testing.expect(clear_scrollback < home);
    try std.testing.expect(result.full_repaint);
    const sync_end = std.mem.find(u8, sink.bytes.items, "\x1b[?2026l") orelse return error.TestExpectedSyncEnd;
    const cursor_show = std.mem.find(u8, sink.bytes.items, "\x1b[?25h") orelse return error.TestExpectedCursorShow;
    try std.testing.expect(sync_end < cursor_show);
    try std.testing.expect(std.mem.endsWith(u8, sink.bytes.items, "\x1b[?25h"));
}

test "flushFrame uses RIS before a terminal history reset" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    previous.autowrap = false;
    try previous.feed("\x1b[1;1Hshell");

    var plan = testPlan();
    plan.reset_terminal = true;
    var surface = try makeSurface(std.testing.allocator, previous, plan);
    defer surface.deinit();

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    _ = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .history_reset_uses_ris = true,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    const ris = std.mem.find(u8, sink.bytes.items, "\x1bc") orelse return error.TestExpectedRis;
    const interactive_modes = std.mem.find(
        u8,
        sink.bytes.items,
        ui_terminal.interactive_mode_enable_sequence,
    ) orelse return error.TestExpectedInteractiveModes;
    const sync_begin = std.mem.find(u8, sink.bytes.items, "\x1b[?2026h") orelse return error.TestExpectedSyncBegin;
    const cursor_hide = std.mem.find(u8, sink.bytes.items, "\x1b[?25l") orelse return error.TestExpectedCursorHide;
    const clear_scrollback = std.mem.find(u8, sink.bytes.items, "\x1b[3J") orelse return error.TestExpectedScrollbackClear;
    try std.testing.expect(ris < sync_begin);
    try std.testing.expect(ris < interactive_modes);
    try std.testing.expect(interactive_modes < sync_begin);
    try std.testing.expect(sync_begin < cursor_hide);
    try std.testing.expect(cursor_hide < clear_scrollback);
}

test "flushFrame emits terminal scroll inside synchronized frame bytes" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[1;1Hone\x1b[2;1Htwo\x1b[3;1Hold");

    var plan = testPlan();
    try plan.invalidation.append(.{ .reason = .terminal_scroll, .top = 2, .bottom = 4 });
    plan.footer_clean_allowed = false;
    var surface = try makeSurface(std.testing.allocator, previous, plan);
    defer surface.deinit();

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(1),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    const sync_begin = std.mem.find(u8, sink.bytes.items, "\x1b[?2026h") orelse return error.TestExpectedSyncBegin;
    const hide = std.mem.find(u8, sink.bytes.items, "\x1b[?25l") orelse return error.TestExpectedCursorHide;
    const scroll = std.mem.find(u8, sink.bytes.items, "\x1b[4;1H\n") orelse return error.TestExpectedScroll;
    const clear = std.mem.find(u8, sink.bytes.items, "\x1b[2;1H\x1b[2K") orelse return error.TestExpectedClear;
    const sync_end = std.mem.find(u8, sink.bytes.items, "\x1b[?2026l") orelse return error.TestExpectedSyncEnd;
    try std.testing.expect(sync_begin < hide);
    try std.testing.expect(hide < scroll);
    try std.testing.expect(scroll < clear);
    try std.testing.expect(clear < sync_end);
    try std.testing.expectEqual(@as(usize, 1), sink.write_calls);
}

test "flushFrame attributes movement scroll and keeps repaint tail scroll neutral" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[1;1Ha\x1b[2;1Hb\x1b[3;1Hc\x1b[4;1Hd");

    const scroll_plan = testScrollPlan(2);
    const append = frame_scroll_plan.FrameDocumentAppend{
        .bytes = "x\r\n",
        .start_row = 4,
        .start_col = 1,
    };
    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        append,
        scroll_plan.terminal_scroll_rows,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 1), movement.scroll_rows.materialized_scroll_rows);
    try std.testing.expectEqual(@as(u16, 1), movement.scroll_rows.alignment_scroll_rows);

    var plan = testPlan();
    try plan.invalidation.append(.{ .reason = .terminal_scroll, .top = 2, .bottom = 4 });
    plan.footer_clean_allowed = false;
    var surface = try makeSurface(std.testing.allocator, movement.post_movement, plan);
    defer surface.deinit();

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = scroll_plan,
        .document_append = append,
        .prepared_movement = &movement,
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(@as(u16, 2), result.terminal_scroll_rows_committed);
    try std.testing.expectEqual(@as(u16, 1), result.scroll_attribution.document_append_scroll_rows);
    try std.testing.expectEqual(@as(u16, 1), result.scroll_attribution.alignment_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), result.scroll_attribution.paint_tail_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), result.scroll_attribution.neutralScrollRows());
    try std.testing.expectEqual(result.terminal_scroll_rows_committed, result.scroll_attribution.totalScrollRows());
}

test "flushFrame reports document movement beyond terminal height as committed" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var plan = testPlan();
    try plan.invalidation.append(.{ .reason = .terminal_scroll, .top = 2, .bottom = 4 });
    plan.footer_clean_allowed = false;
    var surface = try makeSurface(std.testing.allocator, previous, plan);
    defer surface.deinit();

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(99),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    try std.testing.expectEqual(@as(u16, 99), result.terminal_scroll_rows_committed);
}

test "flushFrame full repaints invalidated owned band" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var plan = testPlan();
    try plan.invalidation.append(.{ .reason = .external_clear, .top = 2, .bottom = 2 });
    plan.footer_clean_allowed = false;
    var surface = try makeSurface(std.testing.allocator, previous, plan);
    defer surface.deinit();

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    try std.testing.expect(result.full_repaint);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[2;1H\x1b[2K") != null);
}

test "flushFrame diffs reserved gap clears without full repaint wipe" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[3;1Hstale");

    var plan = testPlan();
    plan.footer = .{
        .top = 4,
        .top_divider = 4,
        .banner = 4,
        .banner_active = false,
        .input_base = 4,
        .picker_divider = 4,
        .picker_start = 4,
        .bottom_divider = 4,
        .hint = 4,
        .total_rows = 1,
    };
    plan.footer_band = .{ .top = 4, .bottom = 4, .owner = .footer };
    try plan.invalidation.append(.{ .reason = .reserved_gap_clear, .top = 3, .bottom = 3 });
    plan.footer_clean_allowed = false;

    var surface = try frame_surface.FrameSurface.initFromShadow(std.testing.allocator, plan, previous);
    defer surface.deinit();
    _ = try surface.writeAnsiBand(2, 1, "hi", .transcript, .same_owner);
    _ = try surface.writeAnsiBand(4, 1, ">", .footer, .same_owner);
    surface.cursor_target = .{ .row = 4, .col = 2, .visible = true };

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    try std.testing.expect(!result.full_repaint);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[3;1H\x1b[2K") == null);
    try std.testing.expectEqual(@as(u21, ' '), previous.cellAt(3, 1).?.codepoint);
}

test "flushFrame diffs owned band growth without full repaint wipe" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[4;1Hshell");

    var plan = testPlan();
    try plan.invalidation.append(.{ .reason = .owned_band_change, .top = 2, .bottom = 4 });
    plan.footer_clean_allowed = false;

    var surface = try frame_surface.FrameSurface.initFromShadow(std.testing.allocator, plan, previous);
    defer surface.deinit();
    _ = try surface.writeAnsiBand(2, 1, "hi", .transcript, .same_owner);
    _ = try surface.writeAnsiBand(4, 1, ">", .footer, .same_owner);
    surface.cursor_target = .{ .row = 4, .col = 2, .visible = true };

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    try std.testing.expect(!result.full_repaint);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[2J") == null);
}

test "flushFrame does not feed shadow after sink failure" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();

    var sink = TestSink{ .fail = true };
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.terminal_partial_write, result.shadow_state);
    try std.testing.expect(!result.is_committed());
    try std.testing.expect(result.committed_cursor() == null);
    try std.testing.expect(result.retry_invalidation() != null);
    try std.testing.expectEqual(@as(u8, 1), result.next_invalidation.len);
    try std.testing.expectEqual(paint_plan.FrameInvalidationReason.partial_write, result.next_invalidation.ranges()[0].reason);
    try std.testing.expectEqual(@as(u21, ' '), previous.cellAt(2, 1).?.codepoint);
    try std.testing.expectEqualStrings(recoveryBytes(false, true), sink.bytes.items);
}

test "flushFrame treats accepted byte prefix as partial write recovery" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();

    var sink = TestSink{ .fail_after_prefix = 4 };
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.terminal_partial_write, result.shadow_state);
    try std.testing.expect(sink.bytes.items.len > 0);
    try std.testing.expectEqual(@as(u21, ' '), previous.cellAt(2, 1).?.codepoint);
    try std.testing.expectEqual(@as(u8, 1), result.next_invalidation.len);
    try std.testing.expectEqual(paint_plan.FrameInvalidationReason.partial_write, result.next_invalidation.ranges()[0].reason);
    try std.testing.expectEqual(@as(u16, 2), result.next_invalidation.ranges()[0].top);
    try std.testing.expectEqual(@as(u16, 4), result.next_invalidation.ranges()[0].bottom);
}

test "flushFrame retries terminal sequence boundary cuts to the uninterrupted grid and cursor" {
    var uninterrupted = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer uninterrupted.deinit();
    var uninterrupted_sink = TestSink{};
    defer uninterrupted_sink.deinit(std.testing.allocator);
    const uninterrupted_result = try flush_test_frame(&uninterrupted, &uninterrupted_sink, .{});
    try std.testing.expect(uninterrupted_result.is_committed());

    const sync_enable_end = "\x1b[?2026h".len;
    const cursor_hide_end = sync_enable_end + "\x1b[?25l".len;
    const paint_cut = (std.mem.find(u8, uninterrupted_sink.bytes.items, "hi") orelse return error.TestUnexpectedResult) + 1;
    const sync_disable_start = std.mem.find(u8, uninterrupted_sink.bytes.items, "\x1b[?2026l") orelse return error.TestUnexpectedResult;
    const cuts = [_]usize{
        2,
        sync_enable_end,
        cursor_hide_end,
        paint_cut,
        sync_disable_start + 2,
        sync_disable_start + "\x1b[?2026l".len,
    };

    for (cuts) |cut| {
        var authoritative = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
        defer authoritative.deinit();
        var physical = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
        defer physical.deinit();
        var failing_sink = TestSink{ .fail_after_prefix = cut };
        defer failing_sink.deinit(std.testing.allocator);

        const failed = try flush_test_frame(&authoritative, &failing_sink, .{});
        try std.testing.expect(!failed.is_committed());
        try std.testing.expect(failed.committed_cursor() == null);
        try std.testing.expect(failed.retry_invalidation() != null);
        try std.testing.expect(std.mem.endsWith(u8, failing_sink.bytes.items, recoveryBytes(true, true)));
        try physical.feed(failing_sink.bytes.items);
        try std.testing.expect(!physical.sync_active);
        try std.testing.expect(physical.cursor_visible);
        try std.testing.expect(physical.current_style.eql(.{}));

        var retry_plan = testPlan();
        try retry_plan.invalidation.append(failed.retry_invalidation().?);
        retry_plan.footer_clean_allowed = false;
        var retry_sink = TestSink{};
        defer retry_sink.deinit(std.testing.allocator);
        const retry = try flush_test_frame(&authoritative, &retry_sink, .{ .plan = retry_plan });
        try std.testing.expect(retry.is_committed());
        try physical.feed(retry_sink.bytes.items);
        try expect_grid_and_cursor_equal(uninterrupted, authoritative);
        try expect_grid_and_cursor_equal(uninterrupted, physical);
    }
}

test "flushFrame shadow feed retry converges physical and authoritative grids" {
    var uninterrupted = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer uninterrupted.deinit();
    var uninterrupted_sink = TestSink{};
    defer uninterrupted_sink.deinit(std.testing.allocator);
    _ = try flush_test_frame(&uninterrupted, &uninterrupted_sink, .{});

    var authoritative = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer authoritative.deinit();
    var physical = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer physical.deinit();
    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    shadow_test_fault = .normal_clone_feed;
    defer shadow_test_fault = .none;

    const failed = try flush_test_frame(&authoritative, &sink, .{});
    try std.testing.expectEqual(ShadowCommitState.shadow_feed_failed, failed.state());
    try physical.feed(sink.bytes.items);

    var retry_plan = testPlan();
    try retry_plan.invalidation.append(failed.retry_invalidation().?);
    retry_plan.footer_clean_allowed = false;
    var retry_sink = TestSink{};
    defer retry_sink.deinit(std.testing.allocator);
    const retry = try flush_test_frame(&authoritative, &retry_sink, .{ .plan = retry_plan });
    try std.testing.expect(retry.is_committed());
    try physical.feed(retry_sink.bytes.items);
    try expect_grid_and_cursor_equal(uninterrupted, authoritative);
    try expect_grid_and_cursor_equal(uninterrupted, physical);
}

test "flushFrame retries resize external clear and reset to uninterrupted state" {
    inline for (std.meta.tags(RecoveryScenario)) |scenario| {
        const plan = try recovery_scenario_plan(scenario);

        var uninterrupted = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
        defer uninterrupted.deinit();
        try uninterrupted.feed("\x1b[1;1Hold\x1b[2;1Hstate");
        var uninterrupted_physical = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
        defer uninterrupted_physical.deinit();
        try prepare_physical_grid_for_scenario(&uninterrupted_physical, scenario);
        var uninterrupted_movement = try prepareTerminalMovement(
            std.testing.allocator,
            &uninterrupted,
            .{},
            0,
            plan.layout.cols,
            plan.layout.rows,
        );
        defer uninterrupted_movement.deinit(std.testing.allocator);
        var uninterrupted_sink = TestSink{};
        defer uninterrupted_sink.deinit(std.testing.allocator);
        const uninterrupted_result = try flush_test_frame(
            &uninterrupted,
            &uninterrupted_sink,
            .{
                .plan = plan,
                .surface_shadow = uninterrupted_movement.post_movement,
                .prepared_movement = &uninterrupted_movement,
            },
        );
        try std.testing.expect(uninterrupted_result.is_committed());
        try uninterrupted_physical.feed(uninterrupted_sink.bytes.items);
        try expect_grid_and_cursor_equal(uninterrupted, uninterrupted_physical);

        var authoritative = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
        defer authoritative.deinit();
        try authoritative.feed("\x1b[1;1Hold\x1b[2;1Hstate");
        var physical = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
        defer physical.deinit();
        try prepare_physical_grid_for_scenario(&physical, scenario);
        var movement = try prepareTerminalMovement(
            std.testing.allocator,
            &authoritative,
            .{},
            0,
            plan.layout.cols,
            plan.layout.rows,
        );
        defer movement.deinit(std.testing.allocator);
        var failing_sink = TestSink{ .fail_after_prefix = 3 };
        defer failing_sink.deinit(std.testing.allocator);
        const failed = try flush_test_frame(
            &authoritative,
            &failing_sink,
            .{
                .plan = plan,
                .surface_shadow = movement.post_movement,
                .prepared_movement = &movement,
            },
        );
        try std.testing.expect(!failed.is_committed());
        try physical.feed(failing_sink.bytes.items);

        var retry_plan = plan;
        try retry_plan.invalidation.append(failed.retry_invalidation().?);
        retry_plan.footer_clean_allowed = false;
        var retry_movement = try prepareTerminalMovement(
            std.testing.allocator,
            &authoritative,
            .{},
            0,
            retry_plan.layout.cols,
            retry_plan.layout.rows,
        );
        defer retry_movement.deinit(std.testing.allocator);
        var retry_sink = TestSink{};
        defer retry_sink.deinit(std.testing.allocator);
        const retry = try flush_test_frame(
            &authoritative,
            &retry_sink,
            .{
                .plan = retry_plan,
                .surface_shadow = retry_movement.post_movement,
                .prepared_movement = &retry_movement,
            },
        );
        try std.testing.expect(retry.is_committed());
        try physical.feed(retry_sink.bytes.items);
        try expect_grid_and_cursor_equal(uninterrupted, authoritative);
        try expect_grid_and_cursor_equal(uninterrupted, physical);
    }
}

test "flushFrame partial retry invalidation follows repaint window" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var plan = testPlan();
    try plan.invalidation.append(.{ .reason = .external_clear, .top = 3, .bottom = 4 });
    plan.footer_clean_allowed = false;
    var surface = try makeSurface(std.testing.allocator, previous, plan);
    defer surface.deinit();

    var sink = TestSink{ .fail = true };
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = false }),
        .synchronized_update = false,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.terminal_partial_write, result.shadow_state);
    try std.testing.expectEqual(@as(u8, 1), result.next_invalidation.len);
    try std.testing.expectEqual(paint_plan.FrameInvalidationReason.partial_write, result.next_invalidation.ranges()[0].reason);
    try std.testing.expectEqual(@as(u16, 3), result.next_invalidation.ranges()[0].top);
    try std.testing.expectEqual(@as(u16, 4), result.next_invalidation.ranges()[0].bottom);
}

test "flushFrame reports accepted scroll before later partial write" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    const plan = testPlan();
    var surface = try makeSurface(std.testing.allocator, previous, plan);
    defer surface.deinit();

    var sink = TestSink{ .fail_after_scroll_rows = 1 };
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(1),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.terminal_partial_write, result.shadow_state);
    try std.testing.expectEqual(@as(u16, 1), result.terminal_scroll_rows_committed);
    try std.testing.expect(result.bytes_written > 0);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[4;1H\n") != null);
    try std.testing.expectEqual(@as(u21, ' '), previous.cellAt(2, 1).?.codepoint);
}

test "flushFrame preserves OSC 8 hyperlink diff output" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 16, 4);
    defer previous.deinit();

    var plan = testPlan();
    plan.layout.cols = 16;
    var surface = try frame_surface.FrameSurface.initFromShadow(std.testing.allocator, plan, previous);
    defer surface.deinit();
    _ = try surface.writeAnsiBand(2, 1, "\x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\", .transcript, .same_owner);
    _ = try surface.writeAnsiBand(3, 1, ">", .footer, .same_owner);
    surface.cursor_target = .{ .row = 3, .col = 2, .visible = true };

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = frame_scroll_plan.FrameScrollPlan.none(surface.plan.layout.rows, 1),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b]8;;https://example.com\x1b\\") != null);
    const cell = previous.cellAt(2, 1).?;
    try std.testing.expect(cell.style.hyperlink_id != 0);
    try std.testing.expectEqualStrings("https://example.com", previous.hyperlinkUrl(cell.style.hyperlink_id).?);
}

test "recovery bytes restore disabled autowrap in unsynchronized steady state" {
    try std.testing.expectEqualStrings(
        "\x18\x1b]8;;\x1b\\\x1b[0m\x1b[?7l\x1b[?25h",
        recoveryBytes(false, false),
    );
}

test "recovery bytes restore disabled autowrap in synchronized steady state" {
    try std.testing.expectEqualStrings(
        "\x18\x1b]8;;\x1b\\\x1b[0m\x1b[?2026l\x1b[?7l\x1b[?25h",
        recoveryBytes(true, false),
    );
}

test "recovery bytes preserve enabled autowrap" {
    try std.testing.expectEqualStrings(
        "\x18\x1b]8;;\x1b\\\x1b[0m\x1b[?25h",
        recoveryBytes(false, true),
    );
    try std.testing.expectEqualStrings(
        "\x18\x1b]8;;\x1b\\\x1b[0m\x1b[?2026l\x1b[?25h",
        recoveryBytes(true, true),
    );
}

test "recovery bytes clear a stranded temporary autowrap mode" {
    var shadow = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer shadow.deinit();
    shadow.autowrap = false;
    shadow.defer_sync_updates = false;
    try shadow.feed("\x1b[?7h");
    try std.testing.expect(shadow.autowrap);

    try shadow.feed(recoveryBytes(false, false));
    try std.testing.expect(authoritativeShadowHasSteadyState(shadow, false, true));
}

test "authoritative shadow steady state rejects mode presentation and cursor drift" {
    var shadow = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer shadow.deinit();
    shadow.defer_sync_updates = false;
    shadow.autowrap = false;
    shadow.cursor_visible = true;

    try std.testing.expect(authoritativeShadowHasSteadyState(shadow, false, true));

    shadow.defer_sync_updates = true;
    try std.testing.expect(!authoritativeShadowHasSteadyState(shadow, false, true));
    shadow.defer_sync_updates = false;

    shadow.sync_active = true;
    try std.testing.expect(!authoritativeShadowHasSteadyState(shadow, false, true));
    shadow.sync_active = false;

    try std.testing.expect(!authoritativeShadowHasSteadyState(shadow, true, true));
    try std.testing.expect(!authoritativeShadowHasSteadyState(shadow, false, false));

    shadow.current_style.flags.bold = true;
    try std.testing.expect(!authoritativeShadowHasSteadyState(shadow, false, true));
    shadow.current_style.flags.bold = false;

    shadow.current_style.hyperlink_id = 1;
    try std.testing.expect(!authoritativeShadowHasSteadyState(shadow, false, true));
}

test "accepted scroll counting simulates the accepted wire prefix" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    const wire = "\x1b[4;1H\n\nbody";
    const move_len = "\x1b[4;1H".len;

    try std.testing.expectEqual(@as(u16, 0), try countAcceptedTerminalScrollRows(std.testing.allocator, &previous, 8, 4, wire, move_len));
    try std.testing.expectEqual(@as(u16, 1), try countAcceptedTerminalScrollRows(std.testing.allocator, &previous, 8, 4, wire, move_len + 1));
    try std.testing.expectEqual(@as(u16, 2), try countAcceptedTerminalScrollRows(std.testing.allocator, &previous, 8, 4, wire, wire.len));
}

test "frame scroll attribution rejects repaint tail scroll rows" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    try std.testing.expectError(
        error.InvalidFrameScrollPlan,
        validateFrameScrollAttribution(
            std.testing.allocator,
            &previous,
            8,
            4,
            "\x1b[4;1H\n",
            FrameMovementSegments.none(),
            .{
                .planned_scroll_rows = 0,
                .materialized_scroll_rows = 0,
                .alignment_scroll_rows = 0,
                .expected_scroll_rows = 0,
            },
        ),
    );
}

test "terminal movement materializes appended document rows before alignment scroll" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        .{ .bytes = "new1\r\nnew2\r\nnew3\r\n", .start_row = 3, .start_col = 1 },
        3,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);

    var terminal = try previous.clone(std.testing.allocator);
    defer terminal.deinit();
    var stats: vt_emulator.FeedStats = .{};
    try terminal.feedWithStats(movement.bytes, &stats);
    try std.testing.expectEqual(@as(u16, 3), stats.scroll_rows);
    try std.testing.expect(movement.document_append_end > 0);
    try std.testing.expectEqual(@as(u16, 2), movement.scroll_rows.materialized_scroll_rows);
    try std.testing.expectEqual(@as(u16, 1), movement.scroll_rows.alignment_scroll_rows);
    try std.testing.expect(std.mem.find(u8, movement.bytes, "new1\r\nnew2\r\nnew3\r\n") != null);
}

test "terminal movement records document append range relative to frame prefix" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        .{ .bytes = "next\r\n", .start_row = 4, .start_col = 1 },
        1,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);

    const frame_prefix_len: usize = 9;
    const range = movement.documentAppendWireRange(frame_prefix_len);
    try std.testing.expect(movement.document_append_end > movement.document_append_start);
    try std.testing.expectEqual(frame_prefix_len + movement.document_append_start, range.start);
    try std.testing.expectEqual(frame_prefix_len + movement.document_append_end, range.end);
    try std.testing.expect(!range.committed(range.start));
    try std.testing.expect(range.interrupted(range.start + 1));
    try std.testing.expect(range.committed(range.end));
    try std.testing.expect(!range.interrupted(range.end));
}

test "terminal movement rejects bare LF document bytes" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    try std.testing.expectError(
        error.InvalidFrameScrollPlan,
        prepareTerminalMovement(
            std.testing.allocator,
            &previous,
            .{ .bytes = "bad\n", .start_row = 4, .start_col = 1 },
            1,
            8,
            4,
        ),
    );
}

test "terminal movement plans decomposed text by display width" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 4, 4);
    defer previous.deinit();

    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        .{
            .bytes = "e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}",
            .start_row = 4,
            .start_col = 1,
        },
        1,
        4,
        4,
    );
    defer movement.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 1), movement.scroll_rows.materialized_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), movement.scroll_rows.alignment_scroll_rows);
}

test "terminal movement brackets document append with temporary autowrap restoration" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    previous.autowrap = false;

    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        .{
            .bytes = "wrapped\r\n",
            .start_row = 4,
            .start_col = 1,
        },
        1,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);

    const enable = std.mem.find(u8, movement.bytes, "\x1b[?7h") orelse return error.TestExpectedAutowrapEnable;
    const append = std.mem.find(u8, movement.bytes, "wrapped\r\n") orelse return error.TestExpectedAppendBytes;
    const disable = std.mem.find(u8, movement.bytes, "\x1b[?7l") orelse return error.TestExpectedAutowrapDisable;
    try std.testing.expect(enable < append);
    try std.testing.expect(append < disable);
    try std.testing.expect(!movement.post_movement.autowrap);
    try std.testing.expectEqual(@as(u16, 1), movement.scroll_rows.materialized_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), movement.scroll_rows.alignment_scroll_rows);
}

test "terminal movement clears stale rows after the exact append cursor" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[3;1Hprefix--\x1b[4;1Hfooter--");

    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        .{ .bytes = "\r\nnext\r\n", .start_row = 3, .start_col = 7 },
        1,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);

    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(std.testing.allocator);
    try movement.post_movement.rowTextTrimmed(2, &row_text);
    try std.testing.expectEqualStrings("prefix", row_text.items);
    row_text.clearRetainingCapacity();
    try movement.post_movement.rowTextTrimmed(3, &row_text);
    try std.testing.expectEqualStrings("next", row_text.items);
}

test "terminal movement preserves an occupied exact-width append endpoint" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[3;1H12345678\x1b[4;1Hfooter--");

    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        .{ .bytes = "\r\nnext\r\n", .start_row = 3, .start_col = 8 },
        1,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);

    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(std.testing.allocator);
    try movement.post_movement.rowTextTrimmed(2, &row_text);
    try std.testing.expectEqualStrings("12345678", row_text.items);
    row_text.clearRetainingCapacity();
    try movement.post_movement.rowTextTrimmed(3, &row_text);
    try std.testing.expectEqualStrings("next", row_text.items);
}

test "terminal movement rejects materialized rows beyond plan" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    try std.testing.expectError(
        error.InvalidFrameScrollPlan,
        prepareTerminalMovement(
            std.testing.allocator,
            &previous,
            .{
                .bytes = "one\r\ntwo\r\n",
                .start_row = 4,
                .start_col = 1,
            },
            1,
            8,
            4,
        ),
    );
}

test "flushFrame rejects stale prepared movement metadata" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        .{},
        0,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidFrameScrollPlan,
        movement.validateForCommit(&previous, 7, 4, 0, 0, .none, false),
    );
}

test "flushFrame rejects complete write with wrong applied rows" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        .{},
        1,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidFrameScrollPlan,
        movement.validateCompleteWrite(10, 10, .{}),
    );
}

test "reset replay uses materialized append rows as the complete write expectation" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[3;1HSTALE");
    var plan = testPlan();
    plan.reset_terminal = true;
    var surface = try makeSurface(std.testing.allocator, previous, plan);
    defer surface.deinit();

    const document_append: frame_scroll_plan.FrameDocumentAppend = .{
        .bytes = "replay\r\n",
        .start_row = 4,
        .start_col = 1,
        .reset_replay = true,
    };
    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        document_append,
        0,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(std.testing.allocator);
    var row_index: u16 = 1;
    while (row_index <= movement.post_movement.rows) : (row_index += 1) {
        row.clearRetainingCapacity();
        try movement.post_movement.rowTextTrimmed(row_index, &row);
        try std.testing.expect(std.mem.indexOf(u8, row.items, "STALE") == null);
    }
    try std.testing.expect(movement.scroll_rows.materialized_scroll_rows > 0);
    try std.testing.expectEqual(@as(u16, 0), movement.scroll_rows.alignment_scroll_rows);

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(0),
        .document_append = document_append,
        .prepared_movement = &movement,
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expect(result.terminal_scroll_rows_committed > 0);
    const receipt = result.scroll_commit_receipt orelse return error.TestExpectedScrollCommitReceipt;
    try std.testing.expectEqual(@as(u16, 0), receipt.planned_terminal_scroll_rows);
    try std.testing.expectEqual(result.terminal_scroll_rows_committed, receipt.expected_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), receipt.accepted_terminal_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), receipt.unplanned_terminal_scroll_rows);
    try std.testing.expect(receipt.complete());
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "\x1b[3J") != null);
}

test "reset replay permits an empty document append" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[3;1HSTALE");

    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        .{ .reset_replay = true },
        0,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 0), movement.scroll_rows.materialized_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), movement.scroll_rows.alignment_scroll_rows);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(std.testing.allocator);
    var row_index: u16 = 1;
    while (row_index <= movement.post_movement.rows) : (row_index += 1) {
        row.clearRetainingCapacity();
        try movement.post_movement.rowTextTrimmed(row_index, &row);
        try std.testing.expect(std.mem.indexOf(u8, row.items, "STALE") == null);
    }
}

test "terminal movement rejects append outside target geometry" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    try std.testing.expectError(
        error.InvalidFrameScrollPlan,
        prepareTerminalMovement(
            std.testing.allocator,
            &previous,
            .{ .bytes = "row\r\n", .start_row = 5, .start_col = 1 },
            0,
            8,
            4,
        ),
    );
}

test "terminal movement rejects alignment row mismatch" {
    try std.testing.expectError(
        error.InvalidFrameScrollPlan,
        validateAlignmentScrollRows(1, 2),
    );
}

test "prepared movement keeps scrolled-out and visible append links before painted links" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 16, 4);
    defer previous.deinit();
    try previous.feed("\x1b]8;;https://old.example\x1b\\\x1b]8;;\x1b\\");

    const append = frame_scroll_plan.FrameDocumentAppend{
        .bytes = "\x1b]8;;https://a.example\x1b\\a\x1b]8;;\x1b\\\r\n" ++
            "1\r\n2\r\n3\r\n4\r\n" ++
            "\x1b]8;;https://b.example\x1b\\b\x1b]8;;\x1b\\",
        .start_row = 4,
        .start_col = 1,
    };
    const scroll_plan = frame_scroll_plan.merge(4, 1, 0, 5);
    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        append,
        scroll_plan.terminal_scroll_rows,
        16,
        4,
    );
    defer movement.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 5), movement.scroll_rows.materialized_scroll_rows);
    try std.testing.expectEqualStrings("https://old.example", movement.post_movement.hyperlinkUrl(1).?);
    try std.testing.expectEqualStrings("https://a.example", movement.post_movement.hyperlinkUrl(2).?);
    try std.testing.expectEqualStrings("https://b.example", movement.post_movement.hyperlinkUrl(3).?);

    var plan = testPlan();
    plan.layout.cols = 16;
    var surface = try frame_surface.FrameSurface.initFromShadow(
        std.testing.allocator,
        plan,
        movement.post_movement,
    );
    defer surface.deinit();
    _ = try surface.writeAnsiBand(
        2,
        1,
        "\x1b]8;;https://b.example\x1b\\B\x1b]8;;\x1b\\",
        .transcript,
        .same_owner,
    );
    _ = try surface.writeAnsiBand(
        3,
        1,
        "\x1b]8;;https://c.example\x1b\\C\x1b]8;;\x1b\\",
        .footer,
        .same_owner,
    );
    surface.cursor_target = .{ .row = 3, .col = 2, .visible = true };
    try std.testing.expectEqualStrings("https://old.example", surface.hyperlinkUrl(1).?);
    try std.testing.expectEqualStrings("https://a.example", surface.hyperlinkUrl(2).?);
    try std.testing.expectEqualStrings("https://b.example", surface.hyperlinkUrl(3).?);
    try std.testing.expectEqualStrings("https://c.example", surface.hyperlinkUrl(4).?);

    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = scroll_plan,
        .document_append = append,
        .prepared_movement = &movement,
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.committed, result.shadow_state);
    try std.testing.expectEqual(@as(u16, 5), result.terminal_scroll_rows_committed);
    try std.testing.expect(result.document_append_committed);
    try std.testing.expectEqualStrings("https://old.example", previous.hyperlinkUrl(1).?);
    try std.testing.expectEqualStrings("https://a.example", previous.hyperlinkUrl(2).?);
    try std.testing.expectEqualStrings("https://b.example", previous.hyperlinkUrl(3).?);
    try std.testing.expectEqualStrings("https://c.example", previous.hyperlinkUrl(4).?);
}

test "flushFrame rejects retry after interrupted document append" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();
    var sink = TestSink{ .fail_after_prefix = 10 };
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};

    try std.testing.expectError(
        error.DocumentAppendInterrupted,
        flushFrame(.{
            .previous = &previous,
            .surface = &surface,
            .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
            .synchronized_update = false,
            .scroll_plan = testScrollPlan(1),
            .document_append = .{ .bytes = "x\r\n", .start_row = 4, .start_col = 1 },
            .sink = sink.frameSink(),
            .metrics = &metrics,
        }),
    );
}

test "flushFrame acknowledges complete document append before later repaint failure" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();
    const append = frame_scroll_plan.FrameDocumentAppend{
        .bytes = "x\r\n",
        .start_row = 4,
        .start_col = 1,
    };
    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        append,
        1,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);
    var sink = TestSink{
        .fail_after_prefix = "\x1b[?25l".len + movement.document_append_end,
    };
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};

    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = testScrollPlan(1),
        .document_append = append,
        .prepared_movement = &movement,
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.terminal_partial_write, result.shadow_state);
    try std.testing.expect(result.document_append_committed);
    try std.testing.expectEqual(@as(u16, 1), result.terminal_scroll_rows_committed);
}

test "flushFrame retry acknowledges document append and scroll exactly once" {
    const append = frame_scroll_plan.FrameDocumentAppend{
        .bytes = "x\r\n",
        .start_row = 4,
        .start_col = 1,
    };
    const scroll_plan = testScrollPlan(1);

    var uninterrupted = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer uninterrupted.deinit();
    var uninterrupted_physical = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer uninterrupted_physical.deinit();
    var uninterrupted_movement = try prepareTerminalMovement(
        std.testing.allocator,
        &uninterrupted,
        append,
        scroll_plan.terminal_scroll_rows,
        8,
        4,
    );
    defer uninterrupted_movement.deinit(std.testing.allocator);
    var uninterrupted_sink = TestSink{};
    defer uninterrupted_sink.deinit(std.testing.allocator);
    const uninterrupted_result = try flush_test_frame(
        &uninterrupted,
        &uninterrupted_sink,
        .{
            .surface_shadow = uninterrupted_movement.post_movement,
            .scroll_rows = scroll_plan.terminal_scroll_rows,
            .document_append = append,
            .prepared_movement = &uninterrupted_movement,
        },
    );
    try std.testing.expect(uninterrupted_result.is_committed());
    try uninterrupted_physical.feed(uninterrupted_sink.bytes.items);
    try expect_grid_and_cursor_equal(uninterrupted, uninterrupted_physical);

    var authoritative = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer authoritative.deinit();
    var physical = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer physical.deinit();
    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &authoritative,
        append,
        scroll_plan.terminal_scroll_rows,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);
    const frame_prefix_len = "\x1b[?2026h".len + "\x1b[?25l".len;
    var failing_sink = TestSink{
        .fail_after_prefix = frame_prefix_len + movement.document_append_end,
    };
    defer failing_sink.deinit(std.testing.allocator);
    const failed = try flush_test_frame(
        &authoritative,
        &failing_sink,
        .{
            .surface_shadow = movement.post_movement,
            .scroll_rows = scroll_plan.terminal_scroll_rows,
            .document_append = append,
            .prepared_movement = &movement,
        },
    );
    try std.testing.expect(!failed.is_committed());
    try std.testing.expect(failed.document_append_applied());
    try std.testing.expectEqual(@as(u16, 1), failed.scrollCommit(scroll_plan).physical_terminal_scroll_rows);
    try physical.feed(failing_sink.bytes.items);

    var retry_plan = testPlan();
    try retry_plan.invalidation.append(failed.retry_invalidation().?);
    retry_plan.footer_clean_allowed = false;
    var retry_movement = try prepareTerminalMovement(
        std.testing.allocator,
        &authoritative,
        .{},
        0,
        8,
        4,
    );
    defer retry_movement.deinit(std.testing.allocator);
    var retry_sink = TestSink{};
    defer retry_sink.deinit(std.testing.allocator);
    const retry = try flush_test_frame(
        &authoritative,
        &retry_sink,
        .{
            .plan = retry_plan,
            .surface_shadow = retry_movement.post_movement,
            .prepared_movement = &retry_movement,
        },
    );
    try std.testing.expect(retry.is_committed());
    try std.testing.expect(std.mem.find(u8, retry_sink.bytes.items, append.bytes) == null);
    try physical.feed(retry_sink.bytes.items);
    try expect_grid_and_cursor_equal(uninterrupted, authoritative);
    try expect_grid_and_cursor_equal(uninterrupted, physical);
}

test "sink progress validator rejects accepted bytes beyond supplied frame" {
    try std.testing.expectError(
        error.InvalidFrameSinkProgress,
        acceptedBytesForSinkResult("abc", .{ .partial = .{
            .accepted_bytes = 4,
            .err = error.TestFrameWriteFailure,
        } }),
    );
}

test "accepted frame write derives scroll and append state from accepted prefix" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    const prefix = "\x1b[?25l";
    const append_scroll_prefix = "\x1b[4;1H\n";
    const wire = prefix ++ append_scroll_prefix ++ "append";
    const append_range = DocumentAppendWireRange{
        .start = prefix.len,
        .end = wire.len,
    };

    const before_append = try acceptedFrameWrite(
        std.testing.allocator,
        &previous,
        8,
        4,
        wire,
        .{ .partial = .{
            .accepted_bytes = prefix.len,
            .err = error.TestFrameWriteFailure,
        } },
        append_range,
        FrameMovementSegments.none(),
        null,
    );
    try std.testing.expectEqual(prefix.len, before_append.accepted_bytes);
    try std.testing.expectEqual(@as(u16, 0), before_append.applied_scroll_rows);
    try std.testing.expect(!before_append.document_append_committed);
    try std.testing.expect(!before_append.document_append_interrupted);

    const during_append = try acceptedFrameWrite(
        std.testing.allocator,
        &previous,
        8,
        4,
        wire,
        .{ .partial = .{
            .accepted_bytes = prefix.len + append_scroll_prefix.len,
            .err = error.TestFrameWriteFailure,
        } },
        append_range,
        FrameMovementSegments.none(),
        null,
    );
    try std.testing.expectEqual(@as(u16, 1), during_append.applied_scroll_rows);
    try std.testing.expect(!during_append.document_append_committed);
    try std.testing.expect(during_append.document_append_interrupted);

    const complete = try acceptedFrameWrite(
        std.testing.allocator,
        &previous,
        8,
        4,
        wire,
        .complete,
        append_range,
        FrameMovementSegments.none(),
        null,
    );
    try std.testing.expectEqual(wire.len, complete.accepted_bytes);
    try std.testing.expectEqual(@as(u16, 1), complete.applied_scroll_rows);
    try std.testing.expect(complete.document_append_committed);
    try std.testing.expect(!complete.document_append_interrupted);
}

test "accepted frame write attributes partial scroll to the accepted movement segment" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();

    const append = frame_scroll_plan.FrameDocumentAppend{
        .bytes = "doc\r\n",
        .start_row = 4,
        .start_col = 1,
    };
    var movement = try prepareTerminalMovement(
        std.testing.allocator,
        &previous,
        append,
        2,
        8,
        4,
    );
    defer movement.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 1), movement.scroll_rows.materialized_scroll_rows);
    try std.testing.expectEqual(@as(u16, 1), movement.scroll_rows.alignment_scroll_rows);

    const prefix = "\x1b[?25l";
    const tail = "\x1b[2;1H\x1b[2K";
    var wire: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer wire.deinit();
    try wire.writer.writeAll(prefix);
    try wire.writer.writeAll(movement.bytes);
    try wire.writer.writeAll(tail);
    const wire_bytes = wire.written();

    const frame_segments = FrameMovementSegments.fromPreparedMovement(prefix.len, movement);
    const append_range = movement.documentAppendWireRange(prefix.len);
    const after_document = try acceptedFrameWrite(
        std.testing.allocator,
        &previous,
        8,
        4,
        wire_bytes,
        .{ .partial = .{
            .accepted_bytes = prefix.len + movement.segments.document_append.end,
            .err = error.TestFrameWriteFailure,
        } },
        append_range,
        frame_segments,
        null,
    );
    try std.testing.expectEqual(@as(u16, 1), after_document.applied_scroll_rows);
    try std.testing.expectEqual(@as(u16, 1), after_document.scroll_attribution.document_append_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), after_document.scroll_attribution.alignment_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), after_document.scroll_attribution.paint_tail_scroll_rows);

    const after_alignment = try acceptedFrameWrite(
        std.testing.allocator,
        &previous,
        8,
        4,
        wire_bytes,
        .{ .partial = .{
            .accepted_bytes = prefix.len + movement.bytes.len,
            .err = error.TestFrameWriteFailure,
        } },
        append_range,
        frame_segments,
        null,
    );
    try std.testing.expectEqual(@as(u16, 2), after_alignment.applied_scroll_rows);
    try std.testing.expectEqual(@as(u16, 1), after_alignment.scroll_attribution.document_append_scroll_rows);
    try std.testing.expectEqual(@as(u16, 1), after_alignment.scroll_attribution.alignment_scroll_rows);
    try std.testing.expectEqual(@as(u16, 0), after_alignment.scroll_attribution.neutralScrollRows());
}

test "flushFrame partial write before scroll reports zero applied rows after cleanup" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[1;1Hone\x1b[2;1Htwo");

    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();
    var sink = TestSink{ .fail_after_prefix = 2 };
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};

    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(1),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.terminal_partial_write, result.shadow_state);
    try std.testing.expectEqual(@as(u16, 0), result.terminal_scroll_rows_committed);
    try std.testing.expectEqual(@as(usize, 2), sink.write_calls);
    try std.testing.expectEqual(@as(u21, 'o'), previous.cellAt(1, 1).?.codepoint);
}

test "flushFrame partial write after all scroll rows repairs accepted physical scroll" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    try previous.feed("\x1b[1;1Hone\x1b[2;1Htwo\x1b[3;1Hthree");

    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();
    var sink = TestSink{ .fail_after_scroll_rows = 2 };
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};

    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(2),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.terminal_partial_write, result.shadow_state);
    try std.testing.expectEqual(@as(u16, 2), result.terminal_scroll_rows_committed);
    try std.testing.expectEqual(@as(u21, 't'), previous.cellAt(1, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), previous.cellAt(1, 2).?.codepoint);
}

test "flushFrame cloned shadow feed failure repairs accepted physical scroll only" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    previous.defer_sync_updates = false;
    previous.autowrap = false;
    try previous.feed("\x1b[1;1Hone\x1b[2;1Htwo\x1b[3;1Hthree");

    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();
    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    shadow_test_fault = .normal_clone_feed;
    defer shadow_test_fault = .none;

    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(2),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(ShadowCommitState.shadow_feed_failed, result.shadow_state);
    try std.testing.expectEqual(@as(u16, 2), result.terminal_scroll_rows_committed);
    try std.testing.expectEqual(@as(u21, 't'), previous.cellAt(1, 1).?.codepoint);
    try std.testing.expect(authoritativeShadowHasSteadyState(previous, false, true));
}

test "flushFrame cleanup rejection stops retry and row acknowledgment" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();
    var sink = TestSink{ .fail = true, .fail_on_call = 2 };
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};

    try std.testing.expectError(error.TerminalSyncRecoveryFailed, flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(1),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    }));
    try std.testing.expectEqual(@as(usize, 2), sink.write_calls);
}

test "flushFrame rejects impossible sink progress" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();
    var sink = TestSink{ .invalid_progress = true };
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};

    try std.testing.expectError(error.InvalidFrameSinkProgress, flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    }));
}

test "flushFrame committed authoritative clone preserves immediate apply and DECAWM off" {
    inline for (.{ false, true }) |synchronized_update| {
        var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
        defer previous.deinit();
        previous.defer_sync_updates = false;
        previous.autowrap = false;

        var surface = try makeSurface(std.testing.allocator, previous, testPlan());
        defer surface.deinit();
        var sink = TestSink{};
        defer sink.deinit(std.testing.allocator);
        var metrics: Metrics = .{};

        _ = try flushFrame(.{
            .previous = &previous,
            .surface = &surface,
            .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
            .synchronized_update = synchronized_update,
            .scroll_plan = testScrollPlan(0),
            .sink = sink.frameSink(),
            .metrics = &metrics,
        });

        try std.testing.expect(authoritativeShadowHasSteadyState(previous, false, true));
    }
}

test "flushFrame invalid authoritative clone returns retryable shadow recovery" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    previous.defer_sync_updates = false;
    var surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer surface.deinit();
    var sink = TestSink{};
    defer sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    shadow_test_fault = .normal_clone_invalid;
    defer shadow_test_fault = .none;

    const result = try flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = false,
        .scroll_plan = testScrollPlan(0),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });
    try std.testing.expectEqual(ShadowCommitState.shadow_feed_failed, result.shadow_state);
    try std.testing.expectEqual(@as(u8, 1), result.next_invalidation.len);
    try std.testing.expectEqual(
        paint_plan.FrameInvalidationReason.shadow_feed_failure,
        result.next_invalidation.ranges()[0].reason,
    );
    try std.testing.expectEqual(@as(u21, ' '), previous.cellAt(2, 1).?.codepoint);
}

test "CAN prefixed cleanup recovers cuts inside CSI and OSC state" {
    var csi = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer csi.deinit();
    csi.defer_sync_updates = false;
    try csi.feed("\x1b[?2026h\x1b[2;");
    try csi.feed(recoveryBytes(true, true));
    try std.testing.expect(authoritativeShadowHasSteadyState(csi, true, true));

    var osc = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer osc.deinit();
    osc.defer_sync_updates = false;
    try osc.feed("\x1b]8;;https://bad.example");
    try osc.feed(recoveryBytes(false, true));
    try osc.feed("plain");
    try std.testing.expect(authoritativeShadowHasSteadyState(osc, true, true));
    try std.testing.expectEqual(@as(u32, 0), osc.cellAt(1, 1).?.style.hyperlink_id);
}

test "checked cleanup closes active hyperlink and resets presentation before later text" {
    var shadow = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer shadow.deinit();
    shadow.defer_sync_updates = false;
    try shadow.feed("\x1b]8;;https://example.com\x1b\\\x1b[31mlinked");
    try shadow.feed(recoveryBytes(false, true));
    try shadow.feed("\x1b[2;1Hplain");

    const plain = shadow.cellAt(2, 1).?;
    try std.testing.expectEqual(@as(u32, 0), plain.style.hyperlink_id);
    try std.testing.expect(plain.style.fg.eql(.default));
}

test "repairAcceptedScroll resizes atomically and preserves authoritative modes" {
    var shrink = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer shrink.deinit();
    shrink.defer_sync_updates = false;
    shrink.autowrap = false;
    try shrink.feed("\x1b[1;1Hone\x1b[2;1Htwo\x1b[3;1Hthree");
    try repairAcceptedScroll(std.testing.allocator, &shrink, 8, 3, 1);
    try std.testing.expectEqual(@as(u16, 3), shrink.rows);
    try std.testing.expectEqual(@as(u21, 't'), shrink.cellAt(1, 1).?.codepoint);
    try std.testing.expect(authoritativeShadowHasSteadyState(shrink, false, true));

    var grow = try vt_emulator.Grid.init(std.testing.allocator, 8, 3);
    defer grow.deinit();
    grow.defer_sync_updates = false;
    try grow.feed("\x1b[1;1Hone\x1b[2;1Htwo");
    try repairAcceptedScroll(std.testing.allocator, &grow, 8, 5, 1);
    try std.testing.expectEqual(@as(u16, 5), grow.rows);
    try std.testing.expect(authoritativeShadowHasSteadyState(grow, true, true));
}

test "repairAcceptedScroll deterministic failures leave authoritative shadow unchanged" {
    inline for (.{ ShadowTestFault.repair_resize, ShadowTestFault.repair_canonical_feed }) |fault| {
        var shadow = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
        defer shadow.deinit();
        shadow.defer_sync_updates = false;
        try shadow.feed("\x1b[1;1Hone\x1b[2;1Htwo");
        shadow_test_fault = fault;
        defer shadow_test_fault = .none;

        try std.testing.expectError(
            error.ShadowScrollRepairFailed,
            repairAcceptedScroll(std.testing.allocator, &shadow, 8, 4, 1),
        );
        try std.testing.expectEqual(@as(u21, 'o'), shadow.cellAt(1, 1).?.codepoint);
    }
}

test "flushFrame accepted scroll repair preserves DECAWM off after successful commit" {
    var previous = try vt_emulator.Grid.init(std.testing.allocator, 8, 4);
    defer previous.deinit();
    previous.defer_sync_updates = false;
    previous.autowrap = false;

    var first_surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer first_surface.deinit();
    var first_sink = TestSink{};
    defer first_sink.deinit(std.testing.allocator);
    var metrics: Metrics = .{};
    _ = try flushFrame(.{
        .previous = &previous,
        .surface = &first_surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(first_surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(0),
        .sink = first_sink.frameSink(),
        .metrics = &metrics,
    });

    var second_surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer second_surface.deinit();
    var second_sink = TestSink{ .fail_after_scroll_rows = 1 };
    defer second_sink.deinit(std.testing.allocator);
    const partial = try flushFrame(.{
        .previous = &previous,
        .surface = &second_surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(second_surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(1),
        .sink = second_sink.frameSink(),
        .metrics = &metrics,
    });
    try std.testing.expectEqual(ShadowCommitState.terminal_partial_write, partial.shadow_state);
    try std.testing.expect(authoritativeShadowHasSteadyState(previous, false, true));

    var retry_surface = try makeSurface(std.testing.allocator, previous, testPlan());
    defer retry_surface.deinit();
    var retry_sink = TestSink{};
    defer retry_sink.deinit(std.testing.allocator);
    const retry = try flushFrame(.{
        .previous = &previous,
        .surface = &retry_surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(retry_surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = testScrollPlan(0),
        .sink = retry_sink.frameSink(),
        .metrics = &metrics,
    });
    try std.testing.expectEqual(ShadowCommitState.committed, retry.shadow_state);
    try std.testing.expect(authoritativeShadowHasSteadyState(previous, false, true));
}
