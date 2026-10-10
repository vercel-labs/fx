const std = @import("std");
const testing_allocator = @import("../../core/shared/testing_allocator.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const types = @import("../../core/shared/types.zig");
const render_engine = @import("../render_engine.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const Metrics = types.Metrics;
const frame_surface = render_engine.frame_surface;
const paint_plan = render_engine.paint_plan;
const terminal_diff = render_engine.terminal_diff;

pub const Geometry = struct {
    /// Outer top of the fx-owned footer band. Every paint clears this
    /// row and everything below it, so stale rows from a previous
    /// frame (collapsed banner, dismissed picker, footer that moved
    /// up after a scroll) are wiped before the new frame diffs in.
    top: u16,
    top_divider: u16,
    input_base: u16,
    /// First physical row and first logical visual row of the committed
    /// primary composer window. Zero `input_first` means the composer was
    /// not visible in the committed frame.
    input_first: u16 = 0,
    input_window_first: usize = 0,
    bottom_divider: u16,
    hint: u16,
    activity_row: ?u16 = null,

    pub fn inputPointerPosition(
        self: Geometry,
        row: u16,
        column: u16,
        prefix_cells: u16,
    ) ?InputPointerPosition {
        if (self.input_first == 0 or
            row < self.input_first or
            row > self.input_base or
            column == 0)
        {
            return null;
        }
        return .{
            .row_index = self.input_window_first + row - self.input_first,
            .content_column = (column - 1) -| prefix_cells,
        };
    }
};

pub const InputPointerPosition = struct {
    row_index: usize,
    content_column: usize,
};

pub const Cursor = struct {
    row: u16,
    col: u16,
};

pub const ComposedFooterRow = struct {
    row: u16,
    text: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *ComposedFooterRow, alloc: Allocator) void {
        self.text.deinit(alloc);
    }
};

pub const ComposedFooterFrame = struct {
    rows: std.ArrayList(ComposedFooterRow) = .empty,
    cursor: Cursor = .{ .row = 1, .col = 1 },
    cursor_visible: bool = true,
    danger_status_visible: bool = false,

    pub fn deinit(self: *ComposedFooterFrame, alloc: Allocator) void {
        for (self.rows.items) |*row| row.deinit(alloc);
        self.rows.deinit(alloc);
    }

    pub fn pushComposedRow(self: *ComposedFooterFrame, alloc: Allocator, row: u16, text: *std.ArrayList(u8)) !void {
        try self.rows.append(alloc, .{
            .row = row,
            .text = text.*,
        });
        text.* = .empty;
    }
};

/// Composes the footer band into a cell grid and emits the minimal
/// ANSI delta against the shell's shadow grid. The shadow is the
/// single source of truth for what is on the terminal — there is no
/// private prev-row state here, so the footer cannot disagree with
/// the transcript about row ownership.
pub const FooterViewport = struct {
    geometry: Geometry = .{
        .top = 1,
        .top_divider = 1,
        .input_base = 1,
        .bottom_divider = 1,
        .hint = 1,
    },
    rows: std.ArrayList(ComposedFooterRow) = .empty,
    cursor: Cursor = .{ .row = 1, .col = 1 },
    cursor_visible: bool = true,
    /// True after `beginFrame` establishes valid footer geometry. Erasing
    /// earlier would start at row 1 and wipe pre-fx shell scrollback.
    has_frame: bool = false,
    /// Set when transcript/body rendering emits a clear that can touch
    /// the footer band. A later footer render must repaint even when
    /// geometry is unchanged, because the terminal cells may have been
    /// blanked.
    externally_invalidated: bool = false,
    /// One-frame diagnostic flag set by the footer runtime when the
    /// footer geometry or activity placement changed enough to be worth
    /// logging under the low-volume `paint` scope.
    trace_paint_frame: bool = false,

    pub fn deinit(self: *FooterViewport, alloc: Allocator) void {
        self.clearRows(alloc);
        self.rows.deinit(alloc);
    }

    fn clearRows(self: *FooterViewport, alloc: Allocator) void {
        for (self.rows.items) |*row| row.deinit(alloc);
        self.rows.clearRetainingCapacity();
    }

    pub fn beginFrame(self: *FooterViewport, alloc: Allocator, geometry: Geometry) void {
        self.clearRows(alloc);
        self.geometry = geometry;
        self.cursor = .{ .row = geometry.input_base, .col = 1 };
        self.cursor_visible = true;
        self.has_frame = true;
    }

    pub fn installComposedFrame(
        self: *FooterViewport,
        alloc: Allocator,
        geometry: Geometry,
        composed: *ComposedFooterFrame,
    ) void {
        var previous_rows = self.rows;
        self.rows = composed.rows;
        composed.rows = .empty;
        self.geometry = geometry;
        self.cursor = composed.cursor;
        self.cursor_visible = composed.cursor_visible;
        self.has_frame = true;

        for (previous_rows.items) |*row| row.deinit(alloc);
        previous_rows.deinit(alloc);
    }

    pub fn invalidateAfterExternalClear(self: *FooterViewport) void {
        if (self.has_frame) self.externally_invalidated = true;
    }

    pub fn clearExternalInvalidation(self: *FooterViewport) void {
        self.externally_invalidated = false;
    }

    pub fn pushOwnedRow(self: *FooterViewport, alloc: Allocator, row: u16, text: *std.ArrayList(u8)) !void {
        try self.rows.append(alloc, .{
            .row = row,
            .text = text.*,
        });
        text.* = .empty;
    }

    pub fn setCursor(self: *FooterViewport, row: u16, col: u16) void {
        self.cursor = .{ .row = row, .col = col };
        self.cursor_visible = true;
    }

    pub fn hideCursor(self: *FooterViewport) void {
        self.cursor_visible = false;
    }

    pub fn eraseCurrentFrame(self: *FooterViewport, shell: anytype, metrics: *Metrics) !void {
        _ = metrics;
        if (!self.has_frame) return;
        debug_trace.logf(
            "frame_plan",
            "footer_erase_current_frame_deferred top={d} rows={d}",
            .{ self.geometry.top, shell.layout.rows },
        );
        self.invalidateAfterExternalClear();
        // Keep has_frame set so shutdownCleanupRow still targets the footer
        // top (clearing it here made exit wipe from cursor_row and erase
        // transcript like "cancelled"). requestTerminalReset clears frame
        // state when a full reanchor follows job-control resume.
        recordFooterBandInvalidation(shell, self.geometry.top, shell.layout.rows, .external_clear);
    }
};

fn recordFooterBandInvalidation(
    shell: anytype,
    top: u16,
    bottom: u16,
    reason: paint_plan.FrameInvalidationReason,
) void {
    if (top == 0 or bottom == 0 or bottom < top) return;
    const Shell = @TypeOf(shell.*);
    if (comptime @hasDecl(Shell, "recordFrameInvalidation")) {
        shell.recordFrameInvalidation(.{
            .reason = reason,
            .top = top,
            .bottom = bottom,
        }) catch |err| {
            debug_trace.logf(
                "frame_plan",
                "footer_invalidation_drop reason={s} top={d} bottom={d} err={s}",
                .{ @tagName(reason), top, bottom, @errorName(err) },
            );
        };
    }
}

pub fn paintFooterIntoSurface(
    surface: *frame_surface.FrameSurface,
    frame: *const ComposedFooterFrame,
) !paint_plan.FooterPaintResult {
    var painted_rows: u16 = 0;
    var top_row: u16 = 0;

    for (frame.rows.items) |row| {
        if (!surface.plan.footer_band.containsRow(row.row)) return error.WriteOutsideBand;
        const result = try surface.writeAnsiBandNoWrap(row.row, 1, row.text.items, .footer, .same_owner);
        if (result.rows_touched > 1) return error.AnsiBandOverflow;
        if (top_row == 0 or row.row < top_row) top_row = row.row;
        painted_rows += 1;
    }

    const plan_cursor_visible = if (surface.plan.cursor_target) |cursor| cursor.visible else true;
    const cursor_visible = frame.cursor_visible and plan_cursor_visible;
    surface.cursor_target = .{
        .row = frame.cursor.row,
        .col = frame.cursor.col,
        .visible = cursor_visible,
    };

    return .{
        .painted_rows = painted_rows,
        .top_row = top_row,
        .cursor_row = frame.cursor.row,
        .cursor_col = frame.cursor.col,
    };
}

test "footer viewport installs composed frame without allocation" {
    const backing = testing_allocator.no_resize;
    var failing = std.testing.FailingAllocator.init(backing, .{});
    const alloc = failing.allocator();
    var viewport = FooterViewport{};
    defer viewport.deinit(alloc);
    var previous: std.ArrayList(u8) = .empty;
    try previous.appendSlice(alloc, "old");
    try viewport.pushOwnedRow(alloc, 4, &previous);

    var composed = ComposedFooterFrame{};
    defer composed.deinit(alloc);
    var next: std.ArrayList(u8) = .empty;
    try next.appendSlice(alloc, "new");
    try composed.pushComposedRow(alloc, 5, &next);
    composed.cursor = .{ .row = 5, .col = 4 };
    composed.cursor_visible = false;

    failing.fail_index = failing.alloc_index;
    viewport.installComposedFrame(
        alloc,
        .{
            .top = 5,
            .top_divider = 5,
            .input_base = 5,
            .bottom_divider = 5,
            .hint = 5,
        },
        &composed,
    );

    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), viewport.rows.items.len);
    try std.testing.expectEqualStrings("new", viewport.rows.items[0].text.items);
    try std.testing.expectEqual(@as(u16, 5), viewport.cursor.row);
    try std.testing.expectEqual(@as(u16, 4), viewport.cursor.col);
    try std.testing.expect(!viewport.cursor_visible);
    try std.testing.expectEqual(@as(usize, 0), composed.rows.items.len);
}

test "committed footer geometry maps pointer cells into its input window" {
    const geometry = Geometry{
        .top = 4,
        .top_divider = 4,
        .input_first = 5,
        .input_window_first = 7,
        .input_base = 7,
        .bottom_divider = 8,
        .hint = 9,
    };

    try std.testing.expectEqual(
        InputPointerPosition{ .row_index = 7, .content_column = 0 },
        geometry.inputPointerPosition(5, 1, 2).?,
    );
    try std.testing.expectEqual(
        InputPointerPosition{ .row_index = 9, .content_column = 3 },
        geometry.inputPointerPosition(7, 6, 2).?,
    );
    try std.testing.expect(geometry.inputPointerPosition(4, 3, 2) == null);
    try std.testing.expect(geometry.inputPointerPosition(8, 3, 2) == null);
    try std.testing.expect(geometry.inputPointerPosition(5, 0, 2) == null);
}

const FrameSink = struct {
    output: std.ArrayList(u8) = .empty,

    fn deinit(self: *FrameSink, alloc: Allocator) void {
        self.output.deinit(alloc);
    }

    fn frameSink(self: *FrameSink) terminal_diff.FrameSink {
        return .{ .ctx = self, .write_frame = writeFrame };
    }

    fn writeFrame(ctx: *anyopaque, metrics: *Metrics, bytes: []const u8) terminal_diff.FrameSinkWriteResult {
        const self: *FrameSink = @ptrCast(@alignCast(ctx));
        self.output.appendSlice(std.testing.allocator, bytes) catch |err| {
            return .{ .partial = .{ .accepted_bytes = 0, .err = err } };
        };
        metrics.ansi_bytes += bytes.len;
        return .complete;
    }
};

fn footerSurfaceTestPlan(cols: u16) paint_plan.PaintPlan {
    return .{
        .layout = .{
            .rows = 6,
            .cols = cols,
            .content_bottom = 3,
            .divider_top_row = 4,
            .input_row = 5,
            .divider_bottom_row = 5,
            .hint_row = 6,
        },
        .viewport = .{
            .top_row = 2,
            .bottom_row = 3,
            .start_line = 0,
            .partial_skip_rows = 0,
            .line_count = 1,
            .last_visible_row = 2,
        },
        .footer = .{
            .top = 4,
            .top_divider = 4,
            .banner = 4,
            .banner_active = false,
            .input_base = 5,
            .picker_divider = 5,
            .picker_start = 6,
            .bottom_divider = 5,
            .hint = 6,
            .total_rows = 3,
        },
        .activity = .none,
        .preserved_band = .{ .top = 1, .bottom = 1, .owner = .preserved_shell },
        .transcript_band = .{ .top = 2, .bottom = 3, .owner = .transcript },
        .activity_band = paint_plan.FrameBand.empty(.activity),
        .footer_band = .{ .top = 4, .bottom = 6, .owner = .footer },
        .invalidation = paint_plan.FrameInvalidationSet.empty(),
        .footer_clean_allowed = true,
        .synchronized_update = true,
        .cursor_target = .{ .row = 5, .col = 1, .visible = true },
        .bottom_reserved_rows = 0,
        .preserve_scrollback = true,
    };
}

test "paint footer into surface writes footer owners cursor and remaps hyperlinks" {
    var shadow = try vt_emulator.Grid.init(std.testing.allocator, 16, 6);
    defer shadow.deinit();
    var surface = try frame_surface.FrameSurface.initFromShadow(std.testing.allocator, footerSurfaceTestPlan(16), shadow);
    defer surface.deinit();

    var frame = ComposedFooterFrame{};
    defer frame.deinit(std.testing.allocator);

    var divider: std.ArrayList(u8) = .empty;
    try divider.appendSlice(std.testing.allocator, "top");
    try frame.pushComposedRow(std.testing.allocator, 4, &divider);

    var input: std.ArrayList(u8) = .empty;
    try input.appendSlice(std.testing.allocator, "\x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\");
    try frame.pushComposedRow(std.testing.allocator, 5, &input);
    frame.cursor = .{ .row = 5, .col = 2 };

    const result = try paintFooterIntoSurface(&surface, &frame);
    try std.testing.expectEqual(@as(u16, 2), result.painted_rows);
    try std.testing.expectEqual(@as(u16, 4), result.top_row);
    try std.testing.expectEqual(@as(u16, 5), result.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), result.cursor_col);
    try std.testing.expectEqual(@as(?paint_plan.FrameCursorTarget, .{ .row = 5, .col = 2, .visible = true }), surface.cursor_target);

    var row: u16 = 4;
    while (row <= 6) : (row += 1) {
        var col: u16 = 1;
        while (col <= 16) : (col += 1) {
            try std.testing.expectEqual(paint_plan.CellOwner.footer, surface.cellAt(row, col).?.owner);
        }
    }

    const linked_cell = surface.cellAt(5, 1).?;
    try std.testing.expect(linked_cell.style.hyperlink_id != 0);
    try std.testing.expectEqualStrings("https://example.com", surface.hyperlinkUrl(linked_cell.style.hyperlink_id).?);
    try surface.validate();
}

test "paint footer into surface preserves planned hidden cursor visibility" {
    var shadow = try vt_emulator.Grid.init(std.testing.allocator, 16, 6);
    defer shadow.deinit();
    var plan = footerSurfaceTestPlan(16);
    plan.cursor_target = .{ .row = 5, .col = 1, .visible = false };
    var surface = try frame_surface.FrameSurface.initFromShadow(std.testing.allocator, plan, shadow);
    defer surface.deinit();
    surface.cursor_target = .{ .row = 2, .col = 1, .visible = true };

    var frame = ComposedFooterFrame{};
    defer frame.deinit(std.testing.allocator);

    var input: std.ArrayList(u8) = .empty;
    try input.appendSlice(std.testing.allocator, ">");
    try frame.pushComposedRow(std.testing.allocator, 5, &input);
    frame.cursor = .{ .row = 5, .col = 2 };

    _ = try paintFooterIntoSurface(&surface, &frame);

    try std.testing.expectEqual(@as(?paint_plan.FrameCursorTarget, .{ .row = 5, .col = 2, .visible = false }), surface.cursor_target);
}

test "paint footer into surface preserves composed hidden cursor visibility" {
    var shadow = try vt_emulator.Grid.init(std.testing.allocator, 16, 6);
    defer shadow.deinit();
    var surface = try frame_surface.FrameSurface.initFromShadow(std.testing.allocator, footerSurfaceTestPlan(16), shadow);
    defer surface.deinit();

    var frame = ComposedFooterFrame{};
    defer frame.deinit(std.testing.allocator);

    var approval_title: std.ArrayList(u8) = .empty;
    try approval_title.appendSlice(std.testing.allocator, "  Bash command");
    try frame.pushComposedRow(std.testing.allocator, 4, &approval_title);
    frame.cursor = .{ .row = 4, .col = 1 };
    frame.cursor_visible = false;

    _ = try paintFooterIntoSurface(&surface, &frame);

    try std.testing.expectEqual(@as(?paint_plan.FrameCursorTarget, .{ .row = 4, .col = 1, .visible = false }), surface.cursor_target);
}

test "composed approval cursor stays hidden through terminal frame flush" {
    const alloc = std.testing.allocator;
    var previous = try vt_emulator.Grid.init(alloc, 16, 6);
    defer previous.deinit();

    var surface = try frame_surface.FrameSurface.initFromShadow(alloc, footerSurfaceTestPlan(16), previous);
    defer surface.deinit();

    var frame = ComposedFooterFrame{};
    defer frame.deinit(alloc);

    var title: std.ArrayList(u8) = .empty;
    try title.appendSlice(alloc, "  Bash command");
    try frame.pushComposedRow(alloc, 4, &title);

    var question: std.ArrayList(u8) = .empty;
    try question.appendSlice(alloc, "  Do you want to proceed?");
    try frame.pushComposedRow(alloc, 5, &question);

    var choice: std.ArrayList(u8) = .empty;
    try choice.appendSlice(alloc, "    1. Yes");
    try frame.pushComposedRow(alloc, 6, &choice);
    frame.cursor = .{ .row = 4, .col = 1 };
    frame.cursor_visible = false;

    _ = try paintFooterIntoSurface(&surface, &frame);

    var sink = FrameSink{};
    defer sink.deinit(alloc);
    var metrics: Metrics = .{};
    const result = try terminal_diff.flushFrame(.{
        .previous = &previous,
        .surface = &surface,
        .repaint_window = paint_plan.FrameRepaintWindow.fromPlan(surface.plan, .{ .include_transcript = true }),
        .synchronized_update = true,
        .scroll_plan = render_engine.frame_scroll_plan.FrameScrollPlan.none(surface.plan.layout.rows, 1),
        .sink = sink.frameSink(),
        .metrics = &metrics,
    });

    try std.testing.expectEqual(terminal_diff.ShadowCommitState.committed, result.shadow_state);
    try std.testing.expectEqual(@as(u16, 4), previous.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), previous.cursor_col);
    try std.testing.expect(!previous.cursor_visible);
    try std.testing.expect(std.mem.find(u8, sink.output.items, "Bash command") != null);
    try std.testing.expect(std.mem.find(u8, sink.output.items, "\x1b[?25l") != null);
    try std.testing.expect(std.mem.find(u8, sink.output.items, "\x1b[?25h") == null);
}

test "paint footer into surface rejects rows outside footer band" {
    var shadow = try vt_emulator.Grid.init(std.testing.allocator, 16, 6);
    defer shadow.deinit();
    var surface = try frame_surface.FrameSurface.initFromShadow(std.testing.allocator, footerSurfaceTestPlan(16), shadow);
    defer surface.deinit();

    var frame = ComposedFooterFrame{};
    defer frame.deinit(std.testing.allocator);
    var row_text: std.ArrayList(u8) = .empty;
    try row_text.appendSlice(std.testing.allocator, "bad");
    try frame.pushComposedRow(std.testing.allocator, 3, &row_text);

    try std.testing.expectError(error.WriteOutsideBand, paintFooterIntoSurface(&surface, &frame));
}

test "paint footer into surface clamps a composed row that exceeds the footer width" {
    var shadow = try vt_emulator.Grid.init(std.testing.allocator, 4, 6);
    defer shadow.deinit();
    var surface = try frame_surface.FrameSurface.initFromShadow(std.testing.allocator, footerSurfaceTestPlan(4), shadow);
    defer surface.deinit();

    var frame = ComposedFooterFrame{};
    defer frame.deinit(std.testing.allocator);
    var row_text: std.ArrayList(u8) = .empty;
    try row_text.appendSlice(std.testing.allocator, "abcde");
    try frame.pushComposedRow(std.testing.allocator, 4, &row_text);

    _ = try paintFooterIntoSurface(&surface, &frame);
    try std.testing.expectEqual(@as(u21, 'a'), surface.cellAt(4, 1).?.codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), surface.cellAt(4, 4).?.codepoint);
}
