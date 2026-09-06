const std = @import("std");
const diff_mod = @import("../core/output/diff.zig");
const input_action = @import("../core/input/input_action.zig");
const display_width = @import("../core/shared/display_width.zig");
const permission_request = @import("../core/permissions/permission_request.zig");
const text_utils = @import("../core/shared/text_utils.zig");
const types = @import("../core/shared/types.zig");
const approval_readiness = @import("footer/approval_readiness.zig");
const approval_ui = @import("footer/approval_ui.zig");
const interaction_state = @import("footer/interaction_state.zig");
const approval_prompt = @import("../core/permissions/approval_prompt.zig");
const surface_frame = @import("footer/surface_frame.zig");
const render_request = @import("render_request.zig");
const transcript_blocks = @import("render_engine/transcript_blocks.zig");
const vt_emulator = @import("../core/terminal/engine.zig");
const transcript_painter = @import("transcript/painter.zig");
const ui_render = @import("render.zig");

const Allocator = std.mem.Allocator;
const Layout = types.Layout;
const skipVisualRowsInLine = transcript_blocks.skipVisualRowsInLine;
const visualRowsForLine = transcript_blocks.visualRowsForLine;

const file_screen_min_rows: u16 = 8;
const file_screen_spaced_controls_min_rows: u16 = 15;
const command_screen_spaced_controls_min_rows: u16 = 13;
const review_line_number_min_width: usize = 5;
const document_scroll_wheel_rows: i32 = 3;
const transcript_review_separator_rows: usize = 2;
const progressive_transcript_entry_threshold: usize = 128;
const progressive_transcript_byte_threshold: usize = 32 * 1024;
const progressive_review_row_threshold: usize = 512;
const transcript_layout_checkpoint_lines: usize = 64;
const solid_divider_glyph = "\xe2\x94\x80";
const dotted_divider_glyph = "\xe2\x94\x84";

pub const Paint = struct {
    bytes: []u8,
    file_identity_visible: bool,
    all_decision_controls_visible: bool,
    changed_or_notice_visible: bool,
    document_scrollable: bool,
    needs_full_file_projection: bool,

    pub fn deinit(self: Paint, alloc: Allocator) void {
        alloc.free(self.bytes);
    }
};

pub const TranscriptDocumentPlan = union(enum) {
    none,
    progressive: bool,
    projected,
};

pub const TranscriptDocument = union(enum) {
    none,
    progressive: bool,
    projected: []const u8,
};

const ReviewPaintResult = struct {
    changed_or_notice_visible: bool,
    painted_rows: u16,
};

const FileDocumentWindow = struct {
    start: usize,
    end: usize,
};

const TranscriptLayoutCheckpoint = struct {
    byte_start: usize,
    visual_start: usize,
};

const TranscriptDocumentLayout = struct {
    checkpoints: []TranscriptLayoutCheckpoint,
    total_rows: usize,

    fn init(alloc: Allocator, bytes: []const u8, width: u16) !TranscriptDocumentLayout {
        var checkpoints: std.ArrayList(TranscriptLayoutCheckpoint) = .empty;
        errdefer checkpoints.deinit(alloc);
        const physical_lines = std.mem.count(u8, bytes, "\n") +
            @intFromBool(bytes.len > 0 and bytes[bytes.len - 1] != '\n');
        try checkpoints.ensureTotalCapacity(
            alloc,
            (physical_lines +| transcript_layout_checkpoint_lines - 1) /
                transcript_layout_checkpoint_lines,
        );

        var line_start: usize = 0;
        var visual_start: usize = 0;
        var line_index: usize = 0;
        while (line_start < bytes.len) {
            if (line_index % transcript_layout_checkpoint_lines == 0) {
                checkpoints.appendAssumeCapacity(.{
                    .byte_start = line_start,
                    .visual_start = visual_start,
                });
            }
            const relative_newline = std.mem.findScalar(u8, bytes[line_start..], '\n');
            const line_end = if (relative_newline) |offset| line_start + offset else bytes.len;
            visual_start += visualRowsForLine(bytes[line_start..line_end], width);
            line_index += 1;
            if (relative_newline == null) break;
            line_start = line_end + 1;
        }
        return .{
            .checkpoints = try checkpoints.toOwnedSlice(alloc),
            .total_rows = visual_start,
        };
    }

    fn deinit(self: TranscriptDocumentLayout, alloc: Allocator) void {
        alloc.free(self.checkpoints);
    }

    fn checkpointForVisualRow(self: TranscriptDocumentLayout, visual_row: usize) usize {
        std.debug.assert(self.checkpoints.len > 0);
        var low: usize = 0;
        var high = self.checkpoints.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.checkpoints[middle].visual_start <= visual_row) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return low -| 1;
    }
};

const FileDocumentLayout = struct {
    transcript_rows: usize,
    review_start: usize,
    chrome_start: usize,
    document_rows: usize,
    start_row: u16,
    visible_rows: u16,
    width: u16,

    fn maxScrollRows(self: FileDocumentLayout) usize {
        return self.document_rows -| @as(usize, self.visible_rows);
    }

    fn visibleWindow(self: FileDocumentLayout, scroll_rows: usize) FileDocumentWindow {
        const tail_start = self.document_rows -| @as(usize, self.visible_rows);
        const start = tail_start -| scroll_rows;
        return .{
            .start = start,
            .end = @min(self.document_rows, start + @as(usize, self.visible_rows)),
        };
    }
};

const FileScreenLayout = struct {
    document_start_row: u16,
    document_rows: u16,
    chrome_rows: []const FileApprovalChromeRow,
};

const CommandScreenLayout = struct {
    divider_row: ?u16,
    header_row: ?u16,
    question_row: ?u16,
    reason_row: ?u16,
    command_start_row: u16,
    command_rows: u16,
    choice_start_row: u16,
    choice_count: u16,
    footer_divider_row: ?u16,
    hint_row: ?u16,
};

const FileApprovalChromeRow = union(enum) {
    spacer,
    dotted_divider,
    row: approval_ui.FileApprovalScreenRowKind,
};

const compact_file_approval_chrome_rows = [_]FileApprovalChromeRow{
    .dotted_divider,
    .{ .row = .header },
    .{ .row = .question },
    .{ .row = .{ .choice = 0 } },
    .{ .row = .{ .choice = 1 } },
    .{ .row = .{ .choice = 2 } },
    .{ .row = .divider },
    .{ .row = .hint },
};

const spaced_file_approval_chrome_rows = [_]FileApprovalChromeRow{
    .dotted_divider,
    .{ .row = .header },
    .spacer,
    .{ .row = .question },
    .spacer,
    .{ .row = .{ .choice = 0 } },
    .{ .row = .{ .choice = 1 } },
    .{ .row = .{ .choice = 2 } },
    .spacer,
    .{ .row = .divider },
    .{ .row = .hint },
};

pub fn needsScreen(
    alloc: Allocator,
    request: permission_request.PermissionRequest,
    layout: Layout,
    queued_rows: usize,
) !bool {
    if (request.file != null) return true;
    const command = approvalCommand(request) orelse return false;
    return !(try surface_frame.commandApprovalFitsInline(
        alloc,
        request.label,
        command,
        layout,
        queued_rows,
    ));
}

pub fn transcriptDocumentPlan(
    approval: approval_prompt.Projection,
    screen_state: *const interaction_state.ApprovalScreenState,
    entries: []const transcript_blocks.TranscriptEntry,
    layout: Layout,
) !TranscriptDocumentPlan {
    if (approval.request.file == null or layout.rows < file_screen_min_rows) return .none;
    const review = try fileReviewSource(approval);
    if (!screen_state.file_document_hydrated and
        screen_state.document_scroll_rows == 0 and
        fileDocumentNeedsProgressiveFirstFrame(entries, review))
    {
        return .{ .progressive = entries.len > 0 };
    }
    return .projected;
}

pub fn paint(
    alloc: Allocator,
    approval: approval_prompt.Projection,
    screen_state: *interaction_state.ApprovalScreenState,
    transcript_document: TranscriptDocument,
    layout: Layout,
    clear_display: bool,
) !Paint {
    const request = approval.request;
    if (request.file == null) {
        return paintCommandApproval(alloc, approval, screen_state, layout, clear_display);
    }
    return paintFileApproval(alloc, approval, screen_state, transcript_document, layout, clear_display);
}

fn paintFileApproval(
    alloc: Allocator,
    approval: approval_prompt.Projection,
    screen_state: *interaction_state.ApprovalScreenState,
    transcript_document: TranscriptDocument,
    layout: Layout,
    clear_display: bool,
) !Paint {
    const request = approval.request;
    const file_request = request.file orelse return error.MissingFileApprovalRequest;
    if (layout.rows == 0 or layout.cols == 0) return error.InvalidApprovalScreenLayout;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("\x1b[?25l\x1b[H");
    // A normal file review rewrites every visible row. Avoid clearing the
    // alternate buffer on wheel and arrow redraws so unchanged chrome does
    // not flash before the review is repainted.
    if (clear_display or layout.rows < file_screen_min_rows) {
        try out.writer.writeAll("\x1b[2J");
    }

    var file_identity_visible = false;
    var changed_or_notice_visible = false;
    var all_decision_controls_visible = false;
    var document_scrollable = false;
    var needs_full_file_projection = false;
    if (layout.rows < file_screen_min_rows) {
        try paintCompactFileApproval(
            &out.writer,
            alloc,
            approval,
            file_request,
            layout.rows,
            layout.cols,
        );
    } else {
        const screen_layout = fileScreenLayout(layout.rows);
        const review = try fileReviewSource(approval);
        const progressive = transcript_document == .progressive;
        const document_result = if (progressive) blk: {
            needs_full_file_projection = true;
            break :blk try writeProgressiveFileDocumentRows(
                &out.writer,
                alloc,
                transcript_document.progressive,
                review,
                file_request,
                approval.choice_index,
                approval,
                screen_state.changed_or_notice_observed,
                screen_layout,
                layout.cols,
            );
        } else blk: {
            const transcript = switch (transcript_document) {
                .projected => |bytes| bytes,
                .none, .progressive => return error.MissingTranscriptProjection,
            };
            const transcript_layout = try TranscriptDocumentLayout.init(
                alloc,
                transcript,
                layout.cols,
            );
            defer transcript_layout.deinit(alloc);

            const document_layout = try fileDocumentLayout(
                alloc,
                transcript_layout.total_rows,
                review,
                screen_layout.chrome_rows.len,
                screen_layout.document_start_row,
                screen_layout.document_rows,
                layout.cols,
            );
            screen_state.clampDocumentScroll(document_layout.maxScrollRows());

            break :blk try writeDocumentRows(
                &out.writer,
                alloc,
                transcript,
                transcript_layout,
                review,
                file_request,
                approval.choice_index,
                approval,
                screen_state.changed_or_notice_observed,
                screen_layout.chrome_rows,
                screen_state.document_scroll_rows,
                document_layout,
            );
        };
        if (progressive) {
            screen_state.markFileDocumentHydrated();
        } else {
            screen_state.clampDocumentScroll(document_result.max_scroll_rows);
        }
        file_identity_visible = document_result.file_identity_visible;
        all_decision_controls_visible = document_result.all_decision_controls_visible;
        changed_or_notice_visible = document_result.changed_or_notice_visible;
        document_scrollable = document_result.max_scroll_rows > 0;
    }

    return .{
        .bytes = try out.toOwnedSlice(),
        .file_identity_visible = file_identity_visible,
        .all_decision_controls_visible = all_decision_controls_visible,
        .changed_or_notice_visible = changed_or_notice_visible,
        .document_scrollable = document_scrollable,
        .needs_full_file_projection = needs_full_file_projection,
    };
}

fn paintCommandApproval(
    alloc: Allocator,
    approval: approval_prompt.Projection,
    screen_state: *interaction_state.ApprovalScreenState,
    layout: Layout,
    clear_display: bool,
) !Paint {
    const request = approval.request;
    const command = approvalCommand(request) orelse return error.MissingCommandApprovalRequest;
    if (layout.rows == 0 or layout.cols == 0) return error.InvalidApprovalScreenLayout;

    var encoded = try approval_ui.projectCommandText(alloc, command);
    defer encoded.deinit(alloc);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("\x1b[?25l\x1b[H");
    if (clear_display) try out.writer.writeAll("\x1b[2J");

    const screen_layout = commandScreenLayout(layout.rows);
    if (screen_layout.divider_row) |row| {
        try writeCommandDivider(&out.writer, row, layout.cols);
    }
    if (screen_layout.header_row) |row| {
        try writeApprovalPanelScreenRow(&out.writer, alloc, approval, layout.cols, row, 0);
    }
    if (screen_layout.question_row) |row| {
        try writeApprovalPanelScreenRow(&out.writer, alloc, approval, layout.cols, row, 1);
    }
    if (screen_layout.reason_row) |row| {
        try writeApprovalPanelScreenRow(&out.writer, alloc, approval, layout.cols, row, 2);
    }

    const max_scroll_rows = try writeCommandRows(
        &out.writer,
        encoded.bytes,
        screen_state.document_scroll_rows,
        screen_layout.command_start_row,
        screen_layout.command_rows,
        layout.cols,
    );
    screen_state.clampDocumentScroll(max_scroll_rows);

    var choice: u16 = 0;
    while (choice < screen_layout.choice_count) : (choice += 1) {
        try writeApprovalPanelScreenRow(
            &out.writer,
            alloc,
            approval,
            layout.cols,
            screen_layout.choice_start_row + choice,
            4 + choice,
        );
    }
    if (screen_layout.footer_divider_row) |row| {
        try writeCommandDivider(&out.writer, row, layout.cols);
    }
    if (screen_layout.hint_row) |row| {
        try writeCommandReviewHint(
            &out.writer,
            row,
            layout.cols,
            approval.can_amend_selected_choice(),
        );
    }

    return .{
        .bytes = try out.toOwnedSlice(),
        .file_identity_visible = false,
        .all_decision_controls_visible = screen_layout.choice_count == 3,
        .changed_or_notice_visible = false,
        .document_scrollable = max_scroll_rows > 0,
        .needs_full_file_projection = false,
    };
}

fn approvalCommand(request: anytype) ?[]const u8 {
    return approval_ui.commandTargetForApproval(request.label, request.command);
}

fn commandScreenLayout(rows: u16) CommandScreenLayout {
    if (rows >= command_screen_spaced_controls_min_rows) {
        const choice_start_row = rows - 5;
        return .{
            .divider_row = 1,
            .header_row = 2,
            .question_row = 3,
            .reason_row = 4,
            .command_start_row = 6,
            .command_rows = choice_start_row - 6,
            .choice_start_row = choice_start_row,
            .choice_count = 3,
            .footer_divider_row = rows - 1,
            .hint_row = rows,
        };
    }

    const choice_count = @min(rows, @as(u16, 3));
    const choice_start_row = rows - choice_count + 1;
    return .{
        .divider_row = null,
        .header_row = null,
        .question_row = null,
        .reason_row = null,
        .command_start_row = 1,
        .command_rows = choice_start_row - 1,
        .choice_start_row = choice_start_row,
        .choice_count = choice_count,
        .footer_divider_row = null,
        .hint_row = null,
    };
}

fn writeCommandDivider(writer: *std.Io.Writer, row: u16, width: u16) !void {
    try writer.print("\x1b[{d};1H", .{row});
    var col: u16 = 0;
    while (col < width) : (col += 1) try writer.writeAll(solid_divider_glyph);
    try writer.writeAll(ui_render.reset_style);
    try writer.writeAll("\x1b[K");
}

fn writeApprovalPanelScreenRow(
    writer: *std.Io.Writer,
    alloc: Allocator,
    approval: approval_prompt.Projection,
    width: u16,
    row: u16,
    panel_row: u16,
) !void {
    var composed = try approval_ui.composeApprovalPanelRow(
        alloc,
        approval,
        width,
        panel_row,
        interaction_state.approval_panel_rows_compact,
    );
    defer composed.deinit(alloc);
    try writeComposedRow(writer, row, composed.items);
}

fn writeCommandRows(
    writer: *std.Io.Writer,
    command: []const u8,
    scroll_rows: usize,
    start_row: u16,
    row_count: u16,
    width: u16,
) !usize {
    const content_width = @as(usize, width) -|
        (display_width.visibleWidth("  $ ") + 1);
    if (row_count == 0 or content_width == 0) return 0;

    const max_scroll_rows = commandMaxScrollRows(command, content_width, row_count) orelse
        return error.CommandReviewLineDoesNotFit;
    const clamped_scroll_rows = @min(scroll_rows, max_scroll_rows);
    var segments = approval_ui.CommandSegmentIterator.initContentWidth(
        command,
        content_width,
    );
    var visual_row: usize = 0;
    var painted_rows: u16 = 0;
    while (try segments.next()) |segment| {
        if (visual_row >= clamped_scroll_rows and painted_rows < row_count) {
            try writer.print("\x1b[{d};1H", .{start_row + painted_rows});
            try writer.writeAll(ui_render.tag_style);
            try writer.writeAll(if (visual_row == 0) "  $ " else "    ");
            try writer.writeAll(segment);
            try writer.writeAll(ui_render.reset_style);
            try writer.writeAll("\x1b[K");
            painted_rows += 1;
        }
        visual_row += 1;
    }
    try clearRows(writer, start_row + painted_rows, row_count - painted_rows);
    return max_scroll_rows;
}

fn commandMaxScrollRows(command: []const u8, content_width: usize, row_count: u16) ?usize {
    var segments = approval_ui.CommandSegmentIterator.initContentWidth(
        command,
        content_width,
    );
    var visual_rows: usize = 0;
    while (segments.next() catch return null) |_| {
        visual_rows += 1;
    }
    return visual_rows -| @as(usize, row_count);
}

// The wider tiers keep the wheel-scroll notice as long as it fits (it is the
// only cue that the review scrolls); the tail tiers reuse the shared approval
// ladder so reworded copy cannot drift.
const command_review_amendment_hints = [_][]const u8{
    "1–3 Choose now    ↑↓ Options    Tab Amend    Wheel Scroll    Enter Confirm    Esc Cancel",
    "1–3 Choose now    ↑↓ Options    Wheel Scroll    Enter Confirm    Esc Cancel",
    "1–3 Choose    Wheel Scroll    Enter Confirm    Esc Cancel",
    interaction_state.approval_hint_compact,
    interaction_state.approval_hint_minimal,
};

const command_review_navigation_hints = [_][]const u8{
    "1–3 Choose now    ↑↓ or Tab Options    Wheel Scroll    Enter Confirm    Esc Cancel",
    "1–3 Choose now    ↑↓ Options    Wheel Scroll    Enter Confirm    Esc Cancel",
    "1–3 Choose    Wheel Scroll    Enter Confirm    Esc Cancel",
    interaction_state.approval_hint_compact,
    interaction_state.approval_hint_minimal,
};

fn writeCommandReviewHint(
    writer: *std.Io.Writer,
    row: u16,
    width: u16,
    can_amend_selected_choice: bool,
) !void {
    const variants: []const []const u8 = if (can_amend_selected_choice)
        &command_review_amendment_hints
    else
        &command_review_navigation_hints;
    const hint = display_width.widestFitting(variants, width -| 2);
    var line_buf: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "  {s}", .{hint}) catch hint;
    const clipped = text_utils.prefixTerminalSafeByWidth(line, width);
    try writer.print("\x1b[{d};1H", .{row});
    try writer.writeAll(ui_render.dim_style);
    try writer.writeAll(clipped);
    try writer.writeAll(ui_render.reset_style);
    try writer.writeAll("\x1b[K");
}

pub fn fileApprovalAffirmativeReady(
    shell: anytype,
    approval: approval_prompt.Projection,
    screen_state: *const interaction_state.ApprovalScreenState,
) bool {
    const settled = approval_readiness.settledFileApproval(shell, approval) orelse return false;
    return approval_readiness.screenCommitSupportsAffirmative(settled, screen_state);
}

pub fn documentWheelDelta(direction: input_action.MouseWheel) i32 {
    return switch (direction) {
        .up => document_scroll_wheel_rows,
        .down => -document_scroll_wheel_rows,
    };
}

fn fileScreenLayout(rows: u16) FileScreenLayout {
    std.debug.assert(rows >= file_screen_min_rows);

    return .{
        .document_start_row = 1,
        .document_rows = rows,
        .chrome_rows = if (rows >= file_screen_spaced_controls_min_rows)
            &spaced_file_approval_chrome_rows
        else
            &compact_file_approval_chrome_rows,
    };
}

fn fileDocumentLayout(
    alloc: Allocator,
    transcript_rows: usize,
    review: FileReviewSource,
    chrome_row_count: usize,
    start_row: u16,
    visible_rows: u16,
    width: u16,
) !FileDocumentLayout {
    const review_rows = try reviewVisualRowCount(alloc, review, width);
    const review_start = transcript_rows +
        transcriptReviewSeparatorRowCount(transcript_rows, review_rows);
    const chrome_start = review_start + review_rows;
    return .{
        .transcript_rows = transcript_rows,
        .review_start = review_start,
        .chrome_start = chrome_start,
        .document_rows = chrome_start + chrome_row_count,
        .start_row = start_row,
        .visible_rows = visible_rows,
        .width = width,
    };
}

fn fileDocumentNeedsProgressiveFirstFrame(
    entries: []const transcript_blocks.TranscriptEntry,
    review: FileReviewSource,
) bool {
    if (entries.len > progressive_transcript_entry_threshold or
        review.rowCount() > progressive_review_row_threshold)
    {
        return true;
    }
    for (entries) |entry| switch (entry) {
        .raw_bytes => |value| {
            if (value.bytes.len > progressive_transcript_byte_threshold) return true;
        },
        .semantic_notice => |value| {
            if (value.topic.len +| value.body.len > progressive_transcript_byte_threshold) {
                return true;
            }
        },
        .user_turn => |value| {
            if (value.turn.text.len > progressive_transcript_byte_threshold) return true;
        },
        .assistant_turn => |value| {
            if (value.segments.text.items.len > progressive_transcript_byte_threshold) return true;
        },
        else => {},
    };
    return false;
}

fn paintCompactFileApproval(
    writer: *std.Io.Writer,
    alloc: Allocator,
    approval: approval_prompt.Projection,
    request: permission_request.FileApprovalRequest,
    rows: u16,
    width: u16,
) !void {
    const choice_rows = @min(@as(u16, 3), rows);
    for (0..choice_rows) |index| {
        _ = try writeFileChromeRow(
            writer,
            alloc,
            request,
            approval.choice_index,
            width,
            @intCast(index + 1),
            .{ .choice = @intCast(index) },
            false,
            false,
            approval,
        );
    }
}

fn writeFileChromeRow(
    writer: *std.Io.Writer,
    alloc: Allocator,
    request: permission_request.FileApprovalRequest,
    selected_choice: u8,
    width: u16,
    row: u16,
    kind: approval_ui.FileApprovalScreenRowKind,
    affirmative_visible: bool,
    document_scrollable: bool,
    amendment: approval_prompt.Projection,
) !bool {
    var composed = try approval_ui.composeFileApprovalScreenRow(
        alloc,
        request,
        amendment.request.origin,
        selected_choice,
        width,
        kind,
        affirmative_visible,
        document_scrollable,
        amendment,
    );
    defer composed.text.deinit(alloc);
    try writeComposedRow(writer, row, composed.text.items);
    return composed.complete;
}

/// Walks the review exactly as it is painted: chunked viewport reads,
/// terminal-safe encoding, prefix-aware wrapping. Measurement and painting
/// must share this walk so the document layout cannot drift from the painted
/// rows. Returns the total visual row count.
const FileReviewSource = union(enum) {
    full: *const diff_mod.FileReview,
    preview: diff_mod.FileChangePreview,

    fn rowCount(self: FileReviewSource) usize {
        return switch (self) {
            .full => |review| review.rowCount(),
            .preview => |value| @max(value.lines.len, 1),
        };
    }

    fn viewport(
        self: FileReviewSource,
        alloc: Allocator,
        start_row: usize,
        max_rows: usize,
    ) Allocator.Error!diff_mod.ReviewViewport {
        return switch (self) {
            .full => |review| review.viewport(alloc, start_row, max_rows),
            .preview => |value| blk: {
                const total_rows = @max(value.lines.len, 1);
                const start = @min(start_row, total_rows);
                const count = @min(max_rows, total_rows - start);
                const lines = try alloc.alloc(diff_mod.ReviewLine, count);
                if (value.lines.len == 0) {
                    if (count == 1) {
                        lines[0] = .{ .op = .notice, .text = "No content changes" };
                    }
                } else {
                    for (value.lines[start..][0..count], lines) |source, *line| {
                        line.* = .{
                            .op = if (source.op == .elision) .notice else source.op,
                            .old_line = source.old_line,
                            .new_line = source.new_line,
                            .text = source.text,
                        };
                    }
                }
                break :blk .{ .lines = lines, .total_rows = total_rows };
            },
        };
    }
};

fn fileReviewSource(approval: approval_prompt.Projection) !FileReviewSource {
    if (approval.currentReview()) |review| return .{ .full = review };
    const file_request = approval.request.file orelse return error.MissingFileApprovalRequest;
    return switch (approval.request.origin) {
        .active_session => return error.MissingFileReview,
        .subagent => .{ .preview = file_request.preview },
    };
}

fn walkReviewRows(
    alloc: Allocator,
    review: FileReviewSource,
    width: u16,
    visitor: anytype,
) !usize {
    return walkReviewRowsRange(alloc, review, 0, review.rowCount(), width, visitor);
}

fn walkReviewRowsRange(
    alloc: Allocator,
    review: FileReviewSource,
    first_logical_row: usize,
    logical_row_count: usize,
    width: u16,
    visitor: anytype,
) !usize {
    var logical_start = @min(first_logical_row, review.rowCount());
    var visual_row: usize = 0;
    const logical_end = @min(review.rowCount(), logical_start +| logical_row_count);
    while (logical_start < logical_end) {
        const logical_count = @min(@as(usize, 64), logical_end - logical_start);
        const viewport = try review.viewport(alloc, logical_start, logical_count);
        defer viewport.deinit(alloc);
        logical_start += viewport.lines.len;

        for (viewport.lines) |line| {
            var elision_text: [64]u8 = undefined;
            const text = try reviewLineText(line, &elision_text);
            var encoded = try text_utils.encodeTerminalSafe(
                alloc,
                text,
                std.math.maxInt(usize),
            );
            defer encoded.deinit(alloc);
            if (encoded.truncated) return error.TruncatedReviewLine;

            var encoded_offset: usize = 0;
            var first_segment = true;
            while (first_segment or encoded_offset < encoded.bytes.len) {
                const available_width: usize =
                    @as(usize, width) -| reviewPrefixWidth(line, first_segment);
                const segment = if (available_width > 0)
                    text_utils.prefixTerminalSafeByWidth(
                        encoded.bytes[encoded_offset..],
                        available_width,
                    )
                else
                    "";
                if (encoded_offset < encoded.bytes.len and segment.len == 0) {
                    return error.ReviewLineDoesNotFit;
                }
                try visitor.visitRow(line, segment, first_segment, visual_row);
                visual_row += 1;
                encoded_offset += segment.len;
                first_segment = false;
            }
        }
    }
    return visual_row;
}

fn reviewVisualRowCount(
    alloc: Allocator,
    review: FileReviewSource,
    width: u16,
) !usize {
    const counter = struct {
        fn visitRow(_: @This(), _: diff_mod.ReviewLine, _: []const u8, _: bool, _: usize) !void {}
    }{};
    return walkReviewRows(alloc, review, width, counter);
}

fn reviewVisualRowCountRange(
    alloc: Allocator,
    review: FileReviewSource,
    first_logical_row: usize,
    logical_row_count: usize,
    width: u16,
) !usize {
    const counter = struct {
        fn visitRow(_: @This(), _: diff_mod.ReviewLine, _: []const u8, _: bool, _: usize) !void {}
    }{};
    return walkReviewRowsRange(
        alloc,
        review,
        first_logical_row,
        logical_row_count,
        width,
        counter,
    );
}

const DocumentPaintResult = struct {
    file_identity_visible: bool,
    all_decision_controls_visible: bool,
    changed_or_notice_visible: bool,
    max_scroll_rows: usize,
};

const ChromePaintResult = struct {
    file_identity_visible: bool = false,
    all_decision_controls_visible: bool = false,
    painted_rows: u16 = 0,
};

fn writeProgressiveFileDocumentRows(
    writer: *std.Io.Writer,
    alloc: Allocator,
    transcript_present: bool,
    review: FileReviewSource,
    request: permission_request.FileApprovalRequest,
    selected_choice: u8,
    amendment: approval_prompt.Projection,
    changed_or_notice_observed: bool,
    screen_layout: FileScreenLayout,
    width: u16,
) !DocumentPaintResult {
    const visible_rows: usize = screen_layout.document_rows;
    const chrome_visible_rows = @min(screen_layout.chrome_rows.len, visible_rows);
    const available_review_rows = visible_rows - chrome_visible_rows;
    const review_logical_rows = @min(review.rowCount(), available_review_rows);
    const review_logical_start = review.rowCount() - review_logical_rows;
    const review_visual_rows = try reviewVisualRowCountRange(
        alloc,
        review,
        review_logical_start,
        review_logical_rows,
        width,
    );
    const review_visible_rows = @min(review_visual_rows, available_review_rows);
    const leading_blank_rows = available_review_rows - review_visible_rows;
    const document_scrollable = transcript_present or
        review_logical_start > 0 or
        review_visual_rows > review_visible_rows;

    try clearRows(
        writer,
        screen_layout.document_start_row,
        @intCast(leading_blank_rows),
    );
    const review_result = try writeReviewRowsRange(
        writer,
        alloc,
        review,
        review_logical_start,
        review_logical_rows,
        review_visual_rows - review_visible_rows,
        screen_layout.document_start_row + @as(u16, @intCast(leading_blank_rows)),
        review_visible_rows,
        width,
    );
    const chrome_start_offset = screen_layout.chrome_rows.len - chrome_visible_rows;
    const chrome_result = try writeFileChromeRows(
        writer,
        alloc,
        request,
        selected_choice,
        amendment,
        changed_or_notice_observed,
        screen_layout.chrome_rows,
        chrome_start_offset,
        screen_layout.chrome_rows.len,
        screen_layout.document_start_row +
            @as(u16, @intCast(leading_blank_rows)) +
            review_result.painted_rows,
        width,
        review_result.changed_or_notice_visible,
        document_scrollable,
    );
    return .{
        .file_identity_visible = chrome_result.file_identity_visible,
        .all_decision_controls_visible = chrome_result.all_decision_controls_visible,
        .changed_or_notice_visible = review_result.changed_or_notice_visible,
        .max_scroll_rows = @intFromBool(document_scrollable),
    };
}

fn writeDocumentRows(
    writer: *std.Io.Writer,
    alloc: Allocator,
    transcript: []const u8,
    transcript_layout: TranscriptDocumentLayout,
    review: FileReviewSource,
    request: permission_request.FileApprovalRequest,
    selected_choice: u8,
    amendment: approval_prompt.Projection,
    changed_or_notice_observed: bool,
    chrome_rows: []const FileApprovalChromeRow,
    scroll_rows: usize,
    document_layout: FileDocumentLayout,
) !DocumentPaintResult {
    if (document_layout.visible_rows == 0) {
        return .{
            .file_identity_visible = false,
            .all_decision_controls_visible = false,
            .changed_or_notice_visible = false,
            .max_scroll_rows = 0,
        };
    }

    const window = document_layout.visibleWindow(scroll_rows);
    const max_scroll_rows = document_layout.maxScrollRows();

    var painted_rows: u16 = 0;
    if (window.start < document_layout.transcript_rows) {
        const transcript_end = @min(window.end, document_layout.transcript_rows);
        painted_rows = try writeTranscriptRows(
            writer,
            alloc,
            transcript,
            transcript_layout,
            window.start,
            transcript_end,
            document_layout.start_row,
            document_layout.width,
        );
    }

    var changed_or_notice_visible = false;
    if (window.end > document_layout.transcript_rows and
        window.start < document_layout.review_start)
    {
        const separator_start = window.start -| document_layout.transcript_rows;
        const separator_end = @min(window.end, document_layout.review_start) -
            document_layout.transcript_rows;
        painted_rows += try writeTranscriptReviewSeparatorRows(
            writer,
            separator_start,
            separator_end,
            document_layout.start_row + painted_rows,
            document_layout.width,
        );
    }

    if (window.end > document_layout.review_start and
        window.start < document_layout.chrome_start)
    {
        const review_start = window.start -| document_layout.review_start;
        const review_end = @min(window.end, document_layout.chrome_start) -
            document_layout.review_start;
        const review_result = try writeReviewRows(
            writer,
            alloc,
            review,
            review_start,
            document_layout.start_row + painted_rows,
            review_end - review_start,
            document_layout.width,
        );
        painted_rows += review_result.painted_rows;
        changed_or_notice_visible = review_result.changed_or_notice_visible;
    }

    var chrome_result = ChromePaintResult{};
    if (window.end > document_layout.chrome_start) {
        const chrome_start_offset = window.start -| document_layout.chrome_start;
        const chrome_end_offset = window.end - document_layout.chrome_start;
        chrome_result = try writeFileChromeRows(
            writer,
            alloc,
            request,
            selected_choice,
            amendment,
            changed_or_notice_observed,
            chrome_rows,
            chrome_start_offset,
            chrome_end_offset,
            document_layout.start_row + painted_rows,
            document_layout.width,
            changed_or_notice_visible,
            max_scroll_rows > 0,
        );
        painted_rows += chrome_result.painted_rows;
    }

    try clearRows(
        writer,
        document_layout.start_row + painted_rows,
        document_layout.visible_rows - painted_rows,
    );
    return .{
        .file_identity_visible = chrome_result.file_identity_visible,
        .all_decision_controls_visible = chrome_result.all_decision_controls_visible,
        .changed_or_notice_visible = changed_or_notice_visible,
        .max_scroll_rows = max_scroll_rows,
    };
}

fn transcriptReviewSeparatorRowCount(transcript_rows: usize, review_rows: usize) usize {
    return if (transcript_rows > 0 and review_rows > 0)
        transcript_review_separator_rows
    else
        0;
}

fn writeTranscriptReviewSeparatorRows(
    writer: *std.Io.Writer,
    start_offset: usize,
    end_offset: usize,
    start_row: u16,
    width: u16,
) !u16 {
    var painted_rows: u16 = 0;
    for (start_offset..end_offset) |offset| {
        const row = start_row + painted_rows;
        if (offset == 0)
            try writeComposedRow(writer, row, "")
        else
            try writeDocumentDividerRow(writer, row, width, solid_divider_glyph);
        painted_rows += 1;
    }
    return painted_rows;
}

fn writeFileChromeRows(
    writer: *std.Io.Writer,
    alloc: Allocator,
    request: permission_request.FileApprovalRequest,
    selected_choice: u8,
    amendment: approval_prompt.Projection,
    changed_or_notice_observed: bool,
    chrome_rows: []const FileApprovalChromeRow,
    start_offset: usize,
    end_offset: usize,
    start_row: u16,
    width: u16,
    changed_or_notice_visible: bool,
    document_scrollable: bool,
) !ChromePaintResult {
    var result = ChromePaintResult{};
    var choices_visible: u8 = 0;
    var choices_complete = true;
    var affirmative_visible = false;

    for (chrome_rows[start_offset..end_offset]) |chrome_row| {
        const row = start_row + result.painted_rows;
        switch (chrome_row) {
            .spacer => try writeComposedRow(writer, row, ""),
            .dotted_divider => try writeDocumentDividerRow(
                writer,
                row,
                width,
                dotted_divider_glyph,
            ),
            .row => |kind| {
                const complete = try writeFileChromeRow(
                    writer,
                    alloc,
                    request,
                    selected_choice,
                    width,
                    row,
                    kind,
                    affirmative_visible,
                    document_scrollable,
                    amendment,
                );
                switch (kind) {
                    .header => {
                        result.file_identity_visible = complete;
                        affirmative_visible = complete and
                            (changed_or_notice_visible or changed_or_notice_observed);
                    },
                    .choice => {
                        choices_visible += 1;
                        choices_complete = choices_complete and complete;
                    },
                    else => {},
                }
            },
        }
        result.painted_rows += 1;
    }
    result.all_decision_controls_visible = choices_visible == 3 and choices_complete;
    return result;
}

fn writeTranscriptRows(
    writer: *std.Io.Writer,
    alloc: Allocator,
    bytes: []const u8,
    transcript_layout: TranscriptDocumentLayout,
    document_start: usize,
    document_end: usize,
    start_row: u16,
    width: u16,
) !u16 {
    if (transcript_layout.checkpoints.len == 0) return 0;
    var painted_rows: u16 = 0;
    var control_cursor = try transcript_painter.TranscriptDocumentControlCursor.init(
        alloc,
        bytes,
        width,
    );
    defer control_cursor.deinit();
    const checkpoint = transcript_layout.checkpoints[
        transcript_layout.checkpointForVisualRow(document_start)
    ];
    var line_start = checkpoint.byte_start;
    var line_visual_start = checkpoint.visual_start;
    while (line_start < bytes.len and line_visual_start < document_end) {
        const relative_newline = std.mem.findScalar(u8, bytes[line_start..], '\n');
        const line_end = if (relative_newline) |offset| line_start + offset else bytes.len;
        const line = bytes[line_start..line_end];
        const line_visual_rows = visualRowsForLine(line, width);
        const line_visual_end = line_visual_start + line_visual_rows;
        const local_start: u16 = @intCast(document_start -| line_visual_start);
        const local_end: u16 = @intCast(
            @min(document_end, line_visual_end) - line_visual_start,
        );
        var local_row = local_start;
        while (local_row < local_end) : (local_row += 1) {
            const raw_start = line_start + skipVisualRowsInLine(line, width, local_row);
            const raw_end = line_start + skipVisualRowsInLine(line, width, local_row + 1);
            const prepared = try control_cursor.prepareAppendBytes(
                alloc,
                raw_start,
                raw_end,
                true,
            );
            defer if (prepared.len > 0) alloc.free(prepared);
            const row_bytes = if (prepared.len > 0) prepared else bytes[raw_start..raw_end];
            try writeComposedRow(writer, start_row + painted_rows, row_bytes);
            painted_rows += 1;
        }
        line_visual_start = line_visual_end;
        if (relative_newline == null) break;
        line_start = line_end + 1;
    }
    return painted_rows;
}

const ReviewRowPainter = struct {
    writer: *std.Io.Writer,
    alloc: Allocator,
    scroll_rows: usize,
    start_row: u16,
    max_rows: usize,
    painted_rows: u16 = 0,
    changed_or_notice_visible: bool = false,

    fn visitRow(
        self: *ReviewRowPainter,
        line: diff_mod.ReviewLine,
        segment: []const u8,
        first_segment: bool,
        visual_row: usize,
    ) !void {
        if (visual_row < self.scroll_rows) return;
        if (@as(usize, self.painted_rows) >= self.max_rows) return;

        var line_out: std.Io.Writer.Allocating = .init(self.alloc);
        defer line_out.deinit();
        try appendReviewPrefix(&line_out.writer, line, first_segment);
        try line_out.writer.writeAll(reviewStyle(line.op));
        try line_out.writer.writeAll(segment);
        try writeComposedRow(
            self.writer,
            self.start_row + self.painted_rows,
            line_out.written(),
        );
        if (reviewLineQualifies(line.op)) {
            self.changed_or_notice_visible = true;
        }
        self.painted_rows += 1;
    }
};

fn writeReviewRows(
    writer: *std.Io.Writer,
    alloc: Allocator,
    review: FileReviewSource,
    scroll_rows: usize,
    start_row: u16,
    max_rows: usize,
    width: u16,
) !ReviewPaintResult {
    return writeReviewRowsRange(
        writer,
        alloc,
        review,
        0,
        review.rowCount(),
        scroll_rows,
        start_row,
        max_rows,
        width,
    );
}

fn writeReviewRowsRange(
    writer: *std.Io.Writer,
    alloc: Allocator,
    review: FileReviewSource,
    first_logical_row: usize,
    logical_row_count: usize,
    scroll_rows: usize,
    start_row: u16,
    max_rows: usize,
    width: u16,
) !ReviewPaintResult {
    if (max_rows == 0) {
        return .{
            .changed_or_notice_visible = false,
            .painted_rows = 0,
        };
    }

    var painter = ReviewRowPainter{
        .writer = writer,
        .alloc = alloc,
        .scroll_rows = scroll_rows,
        .start_row = start_row,
        .max_rows = max_rows,
    };
    _ = try walkReviewRowsRange(
        alloc,
        review,
        first_logical_row,
        logical_row_count,
        width,
        &painter,
    );
    return .{
        .changed_or_notice_visible = painter.changed_or_notice_visible,
        .painted_rows = painter.painted_rows,
    };
}

fn writeComposedRow(
    writer: *std.Io.Writer,
    row: u16,
    text: []const u8,
) !void {
    try writer.print("\x1b[{d};1H", .{row});
    // Clear before writing so a full-width transcript row cannot erase itself after a wrap reset.
    try writer.writeAll(ui_render.reset_style);
    try writer.writeAll("\x1b[K");
    try writer.writeAll(text);
    try writer.writeAll(ui_render.reset_style);
}

fn writeDocumentDividerRow(
    writer: *std.Io.Writer,
    row: u16,
    width: u16,
    glyph: []const u8,
) !void {
    try writer.print("\x1b[{d};1H", .{row});
    try writer.writeAll(ui_render.reset_style);
    try writer.writeAll("\x1b[K");
    try writer.writeAll(ui_render.divider_style);
    for (0..width) |_| try writer.writeAll(glyph);
    try writer.writeAll(ui_render.reset_style);
}

fn clearRows(writer: *std.Io.Writer, start_row: u16, count: u16) !void {
    var offset: u16 = 0;
    while (offset < count) : (offset += 1) {
        try writeComposedRow(writer, start_row + offset, "");
    }
}

fn reviewPrefixWidth(line: diff_mod.ReviewLine, first_segment: bool) usize {
    if (!first_segment) return review_line_number_min_width + 5;
    if (line.op == .notice) return review_line_number_min_width + 4;
    return reviewNumberWidth(line) + 5;
}

fn reviewLineText(
    line: diff_mod.ReviewLine,
    elision_text: *[64]u8,
) std.fmt.BufPrintError![]const u8 {
    if (line.op != .elision) return line.text;
    return try std.fmt.bufPrint(
        elision_text,
        "{d} unchanged lines ⋯",
        .{line.elision_count},
    );
}

fn reviewNumberWidth(line: diff_mod.ReviewLine) usize {
    const number = line.new_line orelse line.old_line orelse return review_line_number_min_width;
    return @max(review_line_number_min_width, decimalDigits(number));
}

fn decimalDigits(value: u32) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (digits += 1) {
        remaining /= 10;
    }
    return digits;
}

fn appendReviewPrefix(
    writer: *std.Io.Writer,
    line: diff_mod.ReviewLine,
    first_segment: bool,
) !void {
    if (!first_segment) {
        try writeSpaces(writer, review_line_number_min_width + 5);
        return;
    }

    try writeSpaces(writer, 2);
    if (line.op == .notice) {
        try writeSpaces(writer, review_line_number_min_width + 2);
        return;
    }

    var number_buf: [16]u8 = undefined;
    const number_text = if (line.new_line orelse line.old_line) |number|
        std.fmt.bufPrint(&number_buf, "{d}", .{number}) catch ""
    else
        "";
    try writeSpaces(
        writer,
        reviewNumberWidth(line) -| display_width.visibleWidth(number_text),
    );
    // The number and +/- sign carry the marker accent (green/red); the line
    // text stays neutral. Falls back to the neutral statusline color when no
    // marker style is set.
    const marker_style = reviewMarkerStyle(line.op);
    try writer.writeAll(if (marker_style.len != 0) marker_style else ui_render.statusline_style);
    try writer.writeAll(number_text);
    try writer.writeAll(ui_render.reset_style);
    try writer.writeAll(" ");

    const op = switch (line.op) {
        .addition => "+",
        .deletion => "-",
        .context => " ",
        .elision => "⋯",
        .notice => unreachable,
    };
    try writer.writeAll(if (marker_style.len != 0) marker_style else reviewStyle(line.op));
    try writer.writeAll(op);
    try writer.writeAll(ui_render.reset_style);
    try writer.writeAll(" ");
}

fn writeSpaces(writer: *std.Io.Writer, count: usize) !void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        try writer.writeAll(" ");
    }
}

fn reviewStyle(op: diff_mod.PreviewOp) []const u8 {
    return switch (op) {
        .addition => ui_render.diff_added_style,
        .deletion => ui_render.diff_removed_style,
        .notice, .context, .elision => ui_render.dim_style,
    };
}

fn reviewMarkerStyle(op: diff_mod.PreviewOp) []const u8 {
    return switch (op) {
        .addition => ui_render.diff_added_marker_style,
        .deletion => ui_render.diff_removed_marker_style,
        .notice, .context, .elision => "",
    };
}

fn reviewLineQualifies(op: diff_mod.PreviewOp) bool {
    return switch (op) {
        .addition, .deletion, .notice => true,
        .context, .elision => false,
    };
}

test "review prefix accents the marker and falls back to neutral" {
    const alloc = std.testing.allocator;

    var added: std.Io.Writer.Allocating = .init(alloc);
    defer added.deinit();
    try appendReviewPrefix(&added.writer, .{ .op = .addition, .new_line = 79, .text = "x" }, true);
    try std.testing.expect(std.mem.find(u8, added.written(), ui_render.diff_added_marker_style) != null);

    var removed: std.Io.Writer.Allocating = .init(alloc);
    defer removed.deinit();
    try appendReviewPrefix(&removed.writer, .{ .op = .deletion, .old_line = 80, .text = "y" }, true);
    try std.testing.expect(std.mem.find(u8, removed.written(), ui_render.diff_removed_marker_style) != null);

    const saved_added = ui_render.diff_added_marker_style;
    defer ui_render.diff_added_marker_style = saved_added;
    ui_render.diff_added_marker_style = "";
    var neutral: std.Io.Writer.Allocating = .init(alloc);
    defer neutral.deinit();
    try appendReviewPrefix(&neutral.writer, .{ .op = .addition, .new_line = 1, .text = "z" }, true);
    try std.testing.expect(std.mem.find(u8, neutral.written(), ui_render.statusline_style) != null);
}

fn testLayout(rows: u16, cols: u16) Layout {
    return .{
        .rows = rows,
        .cols = cols,
        .content_bottom = 1,
        .divider_top_row = 1,
        .input_row = 1,
        .divider_bottom_row = 1,
        .hint_row = 1,
    };
}

fn paintTest(
    alloc: Allocator,
    approval: approval_prompt.Projection,
    screen_state: *interaction_state.ApprovalScreenState,
    entries: []const transcript_blocks.TranscriptEntry,
    styles: transcript_blocks.Styles,
    layout: Layout,
    clear_display: bool,
) !Paint {
    return switch (try transcriptDocumentPlan(approval, screen_state, entries, layout)) {
        .none => paint(alloc, approval, screen_state, .none, layout, clear_display),
        .progressive => |present| paint(
            alloc,
            approval,
            screen_state,
            .{ .progressive = present },
            layout,
            clear_display,
        ),
        .projected => {
            const transcript = try transcript_blocks.renderEntriesToBytes(
                alloc,
                entries,
                layout.cols,
                styles,
            );
            defer alloc.free(transcript);
            return paint(
                alloc,
                approval,
                screen_state,
                .{ .projected = transcript },
                layout,
                clear_display,
            );
        },
    };
}

const test_preview_lines = [_]diff_mod.PreviewLine{
    .{
        .op = .addition,
        .new_line = 1,
        .text = "changed",
    },
};

fn testFileRequest() permission_request.PermissionRequest {
    return .{
        .id = 44,
        .label = "edit_file note.txt",
        .file = .{
            .kind = .edit,
            .intent = .mutation,
            .preview = .{
                .path = "note.txt",
                .lines = &test_preview_lines,
                .additions = 1,
                .deletions = 0,
                .truncated = false,
            },
            .scope = .workspace_files,
        },
    };
}

test "command approval screen wraps and scrolls a complete command review" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(alloc);
    try label.appendSlice(alloc, "shell.run printf '%s' 'LONG_COMMAND_APPROVAL_START");
    try label.appendNTimes(alloc, 'x', 2048);
    try label.appendSlice(alloc, "LONG_COMMAND_APPROVAL_END'");

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, .{ .label = label.items }));
    try std.testing.expect(try needsScreen(
        alloc,
        approval.request.?.view(),
        testLayout(12, 32),
        0,
    ));

    var first = try paintTest(alloc, approval.projection().?, &screen_state, &.{}, .{}, testLayout(12, 32), true);
    defer first.deinit(alloc);
    try std.testing.expect(first.document_scrollable);
    try std.testing.expectEqual(@as(usize, 0), screen_state.document_scroll_rows);

    screen_state.scrollDocument(100_000);
    var last = try paintTest(alloc, approval.projection().?, &screen_state, &.{}, .{}, testLayout(12, 32), false);
    defer last.deinit(alloc);
    try std.testing.expect(last.document_scrollable);
    try std.testing.expect(screen_state.document_scroll_rows > 0);

    var grid = try vt_emulator.Grid.init(alloc, 32, 12);
    defer grid.deinit();
    try grid.feed(last.bytes);

    var visible_command: std.ArrayList(u8) = .empty;
    defer visible_command.deinit(alloc);
    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    const screen_layout = commandScreenLayout(12);
    var row = screen_layout.command_start_row;
    while (row < screen_layout.choice_start_row) : (row += 1) {
        row_text.clearRetainingCapacity();
        try grid.rowTextTrimmed(row, &row_text);
        try visible_command.appendSlice(alloc, std.mem.trimStart(u8, row_text.items, " "));
    }
    try std.testing.expect(std.mem.find(u8, visible_command.items, "LONG_COMMAND_APPROVAL_END") != null);
}

test "command approval screen preserves raw command newlines as rows" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, .{
        .label = "shell.run cat <<'EOF'...",
        .command = "cat <<'EOF'\nline one\nEOF",
    }));

    var rendered = try paintTest(
        alloc,
        approval.projection().?,
        &screen_state,
        &.{},
        .{},
        testLayout(16, 80),
        true,
    );
    defer rendered.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 80, 16);
    defer grid.deinit();
    try grid.feed(rendered.bytes);

    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    const screen_layout = commandScreenLayout(16);
    try grid.rowTextTrimmed(screen_layout.command_start_row, &row_text);
    try std.testing.expectEqualStrings("  $ cat <<'EOF'", row_text.items);
    row_text.clearRetainingCapacity();
    try grid.rowTextTrimmed(screen_layout.command_start_row + 1, &row_text);
    try std.testing.expectEqualStrings("    line one", row_text.items);
    row_text.clearRetainingCapacity();
    try grid.rowTextTrimmed(screen_layout.command_start_row + 2, &row_text);
    try std.testing.expectEqualStrings("    EOF", row_text.items);
}

test "command approval screen includes compact permission header" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    const label = "shell.run printf '%s' '" ++ ("x" ** 256) ++ "'";

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, .{ .label = label }));

    var rendered = try paintTest(alloc, approval.projection().?, &screen_state, &.{}, .{}, testLayout(16, 80), true);
    defer rendered.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, rendered.bytes, "Permission needed · Choose one") != null);
    try std.testing.expect(std.mem.find(u8, rendered.bytes, "Command") != null);

    var grid = try vt_emulator.Grid.init(alloc, 80, 16);
    defer grid.deinit();
    try grid.feed(rendered.bytes);

    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(alloc);
    var choice_three_row: ?u16 = null;
    var hint_row: ?u16 = null;
    var row: u16 = 1;
    while (row <= 16) : (row += 1) {
        row_text.clearRetainingCapacity();
        try grid.rowTextTrimmed(row, &row_text);
        if (std.mem.find(u8, row_text.items, "3. No") != null) choice_three_row = row;
        if (std.mem.find(u8, row_text.items, "1–3 Choose") != null) hint_row = row;
    }

    const choice_row = choice_three_row orelse return error.TestMissingChoice;
    const controls_row = hint_row orelse return error.TestMissingHint;
    row_text.clearRetainingCapacity();
    try grid.rowTextTrimmed(choice_row + 1, &row_text);
    try std.testing.expectEqualStrings("", row_text.items);
    const bottom_divider = grid.cellAt(choice_row + 2, 1) orelse return error.TestMissingBottomDivider;
    try std.testing.expectEqual(@as(u21, 0x2500), bottom_divider.codepoint);
    try std.testing.expectEqual(choice_row + 3, controls_row);
}

test "command approval screen wraps commands at word boundaries" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, .{
        .label = "shell.run curl --header alpha --header bravo",
    }));

    var rendered = try paintTest(alloc, approval.projection().?, &screen_state, &.{}, .{}, testLayout(13, 32), true);
    defer rendered.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 32, 13);
    defer grid.deinit();
    try grid.feed(rendered.bytes);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try grid.rowTextTrimmed(6, &row);
    try std.testing.expectEqualStrings("  $ curl --header alpha", row.items);
    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(7, &row);
    try std.testing.expectEqualStrings("    --header bravo", row.items);
}

test "bounded command approval previews route by complete command fit" {
    const command = "printf '" ++ ("x" ** 160) ++ "'";
    const request: permission_request.PermissionRequest = .{
        .label = "shell.run printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx...",
        .command = command,
    };

    try std.testing.expect(!try needsScreen(
        std.testing.allocator,
        request,
        testLayout(40, 160),
        0,
    ));
    try std.testing.expect(try needsScreen(
        std.testing.allocator,
        request,
        testLayout(10, 160),
        0,
    ));
}

test "command and file approval screen routing preserves short inline and file review behavior" {
    try std.testing.expect(!try needsScreen(
        std.testing.allocator,
        .{
            .label = "shell.run printf short",
            .command = "printf short",
        },
        testLayout(24, 80),
        0,
    ));
    try std.testing.expect(try needsScreen(
        std.testing.allocator,
        testFileRequest(),
        testLayout(24, 80),
        0,
    ));
}

test "subagent file approval renders its bounded preview without a live review" {
    const alloc = std.testing.allocator;
    var active_screen = interaction_state.ApprovalScreenState{};
    var screen_state = interaction_state.ApprovalScreenState{};
    var active = approval_prompt.ApprovalPrompt{};
    defer active.deinit(alloc);
    try std.testing.expect(try active.syncRequest(alloc, testFileRequest()));
    try std.testing.expectError(
        error.MissingFileReview,
        paintTest(alloc, active.projection().?, &active_screen, &.{}, .{}, testLayout(24, 96), true),
    );

    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    var request = testFileRequest();
    request.origin = .{ .subagent = "approval-child" };
    try std.testing.expect(try approval.syncRequest(alloc, request));
    try std.testing.expect(approval.currentReview() == null);

    var rendered = try paintTest(
        alloc,
        approval.projection().?,
        &screen_state,
        &.{},
        .{},
        testLayout(24, 96),
        true,
    );
    defer rendered.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        rendered.bytes,
        "Subagent approval-child needs permission",
    ) != null);
    try std.testing.expect(std.mem.find(u8, rendered.bytes, "note.txt") != null);
    try std.testing.expect(std.mem.find(u8, rendered.bytes, "changed") != null);
    try std.testing.expect(rendered.file_identity_visible);
    try std.testing.expect(rendered.changed_or_notice_visible);
    try std.testing.expect(rendered.all_decision_controls_visible);
}

test "spaced file approval separates the header, question, and choices" {
    const layout = fileScreenLayout(file_screen_spaced_controls_min_rows);
    try std.testing.expect(layout.chrome_rows.len >= 11);
    switch (layout.chrome_rows[1]) {
        .row => |kind| switch (kind) {
            .header => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    switch (layout.chrome_rows[2]) {
        .spacer => {},
        else => return error.TestUnexpectedResult,
    }
    switch (layout.chrome_rows[3]) {
        .row => |kind| switch (kind) {
            .question => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    switch (layout.chrome_rows[4]) {
        .spacer => {},
        else => return error.TestUnexpectedResult,
    }
    switch (layout.chrome_rows[5]) {
        .row => |kind| switch (kind) {
            .choice => |choice_index| try std.testing.expectEqual(@as(u8, 0), choice_index),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    switch (layout.chrome_rows[8]) {
        .spacer => {},
        else => return error.TestUnexpectedResult,
    }
    switch (layout.chrome_rows[9]) {
        .row => |kind| switch (kind) {
            .divider => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    switch (layout.chrome_rows[10]) {
        .row => |kind| switch (kind) {
            .hint => {},
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "file approval screen exposes a scrollable full review" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    var source: std.Io.Writer.Allocating = .init(alloc);
    defer source.deinit();
    for (1..31) |line| try source.writer.print("line-{d:0>2}\n", .{line});
    const text = try source.toOwnedSlice();
    defer alloc.free(text);

    var review = try diff_mod.FileReview.init(alloc, "", text);
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, testFileRequest()));
    try std.testing.expect(approval.syncReview(&review));

    var first = try paintTest(alloc, approval.projection().?, &screen_state, &.{}, .{}, testLayout(12, 32), true);
    defer first.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "line-01") == null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "line-30") != null);
    try std.testing.expect(first.document_scrollable);

    screen_state.scrollDocument(1024);
    var last = try paintTest(alloc, approval.projection().?, &screen_state, &.{}, .{}, testLayout(12, 32), false);
    defer last.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, last.bytes, "line-01") != null);
    try std.testing.expect(last.changed_or_notice_visible);
}

test "file approval screen anchors transcript and review at the document tail" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    var entries: std.ArrayList(transcript_blocks.TranscriptEntry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }

    var transcript: std.Io.Writer.Allocating = .init(alloc);
    defer transcript.deinit();
    for (1..3001) |line| {
        try transcript.writer.print("approval-history-{d:0>4}\n", .{line});
    }
    try entries.append(alloc, .{ .raw_bytes = .{
        .id = 1,
        .bytes = try transcript.toOwnedSlice(),
        .class = .subagent_status,
    } });

    var review = try diff_mod.FileReview.init(alloc, "", "review-tail\n");
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, testFileRequest()));
    try std.testing.expect(approval.syncReview(&review));

    var tail = try paintTest(alloc, approval.projection().?, &screen_state, entries.items, .{}, testLayout(14, 100), true);
    defer tail.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, tail.bytes, "review-tail") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail.bytes, "approval-history-0001") == null);
    try std.testing.expect(tail.document_scrollable);

    var shell = struct {
        render_requests: render_request.RenderRequestState = .{},
        layout: Layout = testLayout(14, 100),
        terminal_dimensions_invalid: bool = false,
        pending_resize_observation: ?u8 = null,
    }{};
    screen_state.recordScreenCommit(approval.request.?.id, .{
        .request_id = approval.request.?.id,
        .rows = shell.layout.rows,
        .cols = shell.layout.cols,
        .file_identity_visible = tail.file_identity_visible,
        .all_decision_controls_visible = tail.all_decision_controls_visible,
        .changed_or_notice_visible = tail.changed_or_notice_visible,
        .document_scrollable = tail.document_scrollable,
    });
    try std.testing.expect(fileApprovalAffirmativeReady(&shell, approval.projection().?, &screen_state));

    screen_state.scrollDocument(10_000);
    var head = try paintTest(alloc, approval.projection().?, &screen_state, entries.items, .{}, testLayout(14, 100), false);
    defer head.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, head.bytes, "approval-history-0001") != null);
    try std.testing.expect(std.mem.indexOf(u8, head.bytes, "review-tail") == null);
    try std.testing.expect(std.mem.indexOf(u8, head.bytes, "Apply this change?") == null);
    try std.testing.expect(!head.file_identity_visible);
    try std.testing.expect(!head.all_decision_controls_visible);
    try std.testing.expect(!head.changed_or_notice_visible);
    screen_state.recordScreenCommit(approval.request.?.id, .{
        .request_id = approval.request.?.id,
        .rows = shell.layout.rows,
        .cols = shell.layout.cols,
        .file_identity_visible = head.file_identity_visible,
        .all_decision_controls_visible = head.all_decision_controls_visible,
        .changed_or_notice_visible = head.changed_or_notice_visible,
        .document_scrollable = head.document_scrollable,
    });
    try std.testing.expect(!fileApprovalAffirmativeReady(&shell, approval.projection().?, &screen_state));

    screen_state.scrollDocument(-10_000);
    var returned = try paintTest(alloc, approval.projection().?, &screen_state, entries.items, .{}, testLayout(14, 100), false);
    defer returned.deinit(alloc);
    screen_state.recordScreenCommit(approval.request.?.id, .{
        .request_id = approval.request.?.id,
        .rows = shell.layout.rows,
        .cols = shell.layout.cols,
        .file_identity_visible = returned.file_identity_visible,
        .all_decision_controls_visible = returned.all_decision_controls_visible,
        .changed_or_notice_visible = returned.changed_or_notice_visible,
        .document_scrollable = returned.document_scrollable,
    });
    try std.testing.expect(fileApprovalAffirmativeReady(&shell, approval.projection().?, &screen_state));
}

test "large file approval paints a bounded tail before hydrating the full document" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    var entries: std.ArrayList(transcript_blocks.TranscriptEntry) = .empty;
    defer {
        for (entries.items) |*entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }

    var transcript: std.ArrayList(u8) = .empty;
    try transcript.appendSlice(alloc, "PROGRESSIVE_TRANSCRIPT_HEAD_SENTINEL ");
    try transcript.appendNTimes(alloc, 't', 128 * 1024);
    try transcript.appendSlice(alloc, "\nPROGRESSIVE_TRANSCRIPT_TAIL_SENTINEL\n");
    try entries.append(alloc, .{ .raw_bytes = .{
        .id = 1,
        .bytes = try transcript.toOwnedSlice(alloc),
        .class = .unknown_raw,
    } });

    var changed: std.ArrayList(u8) = .empty;
    defer changed.deinit(alloc);
    try changed.appendSlice(alloc, "PROGRESSIVE_DIFF_HEAD_SENTINEL ");
    try changed.appendNTimes(alloc, 'd', 128 * 1024);
    try changed.append(alloc, '\n');
    for (1..65) |line| {
        var line_buf: [64]u8 = undefined;
        try changed.appendSlice(
            alloc,
            try std.fmt.bufPrint(&line_buf, "progressive-tail-{d:0>2}\n", .{line}),
        );
    }
    try changed.appendSlice(alloc, "PROGRESSIVE_DIFF_TAIL_SENTINEL\n");

    var review = try diff_mod.FileReview.init(alloc, "", changed.items);
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, testFileRequest()));
    try std.testing.expect(approval.syncReview(&review));

    var first_frame_storage: [64 * 1024]u8 = undefined;
    var first_frame_allocator = std.heap.FixedBufferAllocator.init(&first_frame_storage);
    var first = try paintTest(
        first_frame_allocator.allocator(),
        approval.projection().?,
        &screen_state,
        entries.items,
        .{},
        testLayout(40, 80),
        true,
    );
    defer first.deinit(first_frame_allocator.allocator());
    try std.testing.expect(first.needs_full_file_projection);
    try std.testing.expect(std.mem.find(u8, first.bytes, "PROGRESSIVE_DIFF_TAIL_SENTINEL") != null);
    try std.testing.expect(std.mem.find(u8, first.bytes, "PROGRESSIVE_TRANSCRIPT_HEAD_SENTINEL") == null);
    try std.testing.expect(first.file_identity_visible);
    try std.testing.expect(first.all_decision_controls_visible);
    try std.testing.expect(first.changed_or_notice_visible);

    screen_state.scrollDocument(std.math.maxInt(i32));
    var hydrated = try paintTest(
        alloc,
        approval.projection().?,
        &screen_state,
        entries.items,
        .{},
        testLayout(40, 80),
        false,
    );
    defer hydrated.deinit(alloc);
    try std.testing.expect(!hydrated.needs_full_file_projection);
    try std.testing.expect(std.mem.find(u8, hydrated.bytes, "PROGRESSIVE_TRANSCRIPT_HEAD_SENTINEL") != null);
}

test "transcript document layout keeps sparse checkpoints for large histories" {
    const alloc = std.testing.allocator;
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(alloc);
    for (0..50_000) |_| try transcript.appendSlice(alloc, "history row\n");

    var layout_storage: [64 * 1024]u8 = undefined;
    var layout_allocator = std.heap.FixedBufferAllocator.init(&layout_storage);
    const document = try TranscriptDocumentLayout.init(
        layout_allocator.allocator(),
        transcript.items,
        80,
    );
    defer document.deinit(layout_allocator.allocator());
    try std.testing.expectEqual(@as(usize, 50_000), document.total_rows);
    try std.testing.expect(document.checkpoints.len < 1_000);
}

test "file approval document separates transcript, diff, and controls" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    const transcript_text = try alloc.dupe(u8, "transcript-boundary-marker\n");
    var entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .bytes = transcript_text,
            .class = .unknown_raw,
        } },
    };
    defer entries[0].deinit(alloc);

    var review = try diff_mod.FileReview.init(alloc, "", "review-boundary-marker\n");
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, testFileRequest()));
    try std.testing.expect(approval.syncReview(&review));

    var screen = try paintTest(alloc, approval.projection().?, &screen_state, &entries, .{}, testLayout(14, 48), true);
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 48, 14);
    defer grid.deinit();
    try grid.feed(screen.bytes);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try grid.rowTextTrimmed(1, &row);
    try std.testing.expect(std.mem.indexOf(u8, row.items, "transcript-boundary-marker") != null);

    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(2, &row);
    try std.testing.expectEqualStrings("", row.items);

    const transcript_divider = grid.cellAt(3, 1) orelse return error.TestMissingTranscriptDivider;
    try std.testing.expectEqual(@as(u21, 0x2500), transcript_divider.codepoint);

    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(4, &row);
    try std.testing.expect(std.mem.indexOf(u8, row.items, "review-boundary-marker") != null);

    const approval_divider = grid.cellAt(5, 1) orelse return error.TestMissingApprovalDivider;
    try std.testing.expectEqual(@as(u21, 0x2504), approval_divider.codepoint);
}

test "file approval transcript uses the current rail presentation" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    var entries = [_]transcript_blocks.TranscriptEntry{
        .{ .user_turn = .{
            .id = 1,
            .turn = .{ .text = try alloc.dupe(u8, "approval-current-prompt") },
        } },
    };
    defer entries[0].deinit(alloc);

    var review = try diff_mod.FileReview.init(alloc, "", "review-current-prompt\n");
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, testFileRequest()));
    try std.testing.expect(approval.syncReview(&review));

    var screen = try paintTest(
        alloc,
        approval.projection().?,
        &screen_state,
        &entries,
        .{},
        testLayout(24, 80),
        true,
    );
    defer screen.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, screen.bytes, "approval-current-prompt") != null);
    try std.testing.expect(std.mem.find(u8, screen.bytes, "┃") != null);
    try std.testing.expect(std.mem.find(u8, screen.bytes, "❯ approval-current-prompt") == null);
}

test "file approval top-aligns a fitting welcome document and clears below" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    const welcome = try ui_render.welcomeMessage(alloc);
    var entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .bytes = welcome,
            .class = .welcome,
        } },
    };
    defer entries[0].deinit(alloc);

    var previous_review = try diff_mod.FileReview.init(
        alloc,
        "",
        "stale-01\nstale-02\nstale-03\nstale-04\nstale-05\nstale-06\nstale-07\nstale-08\nstale-09\nstale-10\nstale-11\nstale-12\n",
    );
    defer previous_review.deinit(alloc);
    var review = try diff_mod.FileReview.init(alloc, "", "short review\n");
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, testFileRequest()));

    var grid = try vt_emulator.Grid.init(alloc, 80, 24);
    defer grid.deinit();
    try std.testing.expect(approval.syncReview(&previous_review));
    var previous = try paintTest(alloc, approval.projection().?, &screen_state, &entries, .{}, testLayout(24, 80), true);
    defer previous.deinit(alloc);
    try grid.feed(previous.bytes);

    try std.testing.expect(approval.syncReview(&review));
    var screen = try paintTest(alloc, approval.projection().?, &screen_state, &entries, .{}, testLayout(24, 80), false);
    defer screen.deinit(alloc);
    try grid.feed(screen.bytes);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try grid.rowTextTrimmed(1, &row);
    try std.testing.expect(std.mem.indexOf(u8, row.items, "Run /help for commands") != null);

    const transcript_divider = grid.cellAt(4, 1) orelse return error.TestMissingTranscriptDivider;
    try std.testing.expectEqual(@as(u21, 0x2500), transcript_divider.codepoint);

    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(5, &row);
    try std.testing.expect(std.mem.indexOf(u8, row.items, "+ short review") != null);

    const approval_divider = grid.cellAt(6, 1) orelse return error.TestMissingApprovalDivider;
    try std.testing.expectEqual(@as(u21, 0x2504), approval_divider.codepoint);

    const bottom_divider = grid.cellAt(15, 1) orelse return error.TestMissingBottomDivider;
    try std.testing.expectEqual(@as(u21, 0x2500), bottom_divider.codepoint);

    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(16, &row);
    try std.testing.expect(std.mem.indexOf(u8, row.items, "1–3 Choose") != null);
    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(17, &row);
    try std.testing.expectEqualStrings("", row.items);
    row.clearRetainingCapacity();
    try grid.rowTextTrimmed(24, &row);
    try std.testing.expectEqualStrings("", row.items);
}

test "file approval transcript viewport resumes styled links without leaking into review chrome" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    const linked = "\x1b[1m\x1b]8;;https://example.com\x1b\\styled-link-continuation-marker\x1b]8;;\x1b\\\x1b[0m";
    const owned_linked = try alloc.dupe(u8, linked);
    var entries = [_]transcript_blocks.TranscriptEntry{
        .{ .raw_bytes = .{
            .id = 1,
            .bytes = owned_linked,
            .class = .unknown_raw,
        } },
    };
    defer entries[0].deinit(alloc);

    var review = try diff_mod.FileReview.init(alloc, "", "x\n");
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, testFileRequest()));
    try std.testing.expect(approval.syncReview(&review));

    var screen = try paintTest(alloc, approval.projection().?, &screen_state, &entries, .{}, testLayout(14, 12), true);
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 12, 14);
    defer grid.deinit();
    try grid.feed(screen.bytes);

    const continuation = grid.cellAt(1, 1) orelse return error.TestMissingContinuation;
    const review_cell = grid.cellAt(6, 1) orelse return error.TestMissingReviewCell;
    const footer_cell = grid.cellAt(7, 1) orelse return error.TestMissingFooterCell;
    try std.testing.expect(continuation.style.flags.bold);
    try std.testing.expect(continuation.style.hyperlink_id != 0);
    try std.testing.expectEqualStrings(
        "https://example.com",
        grid.hyperlinkUrl(continuation.style.hyperlink_id).?,
    );

    var review_row: std.ArrayList(u8) = .empty;
    defer review_row.deinit(alloc);
    try grid.rowTextTrimmed(6, &review_row);
    try std.testing.expect(std.mem.indexOf(u8, review_row.items, "+ x") != null);
    try std.testing.expectEqual(@as(u32, 0), review_cell.style.hyperlink_id);

    try std.testing.expectEqual(@as(u32, 0), footer_cell.style.hyperlink_id);
}

test "file approval screen wraps changed source without omitting bytes" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    var review = try diff_mod.FileReview.init(alloc, "", "abcdefgh\n");
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, testFileRequest()));
    try std.testing.expect(approval.syncReview(&review));

    var first = try paintTest(alloc, approval.projection().?, &screen_state, &.{}, .{}, testLayout(12, 12), true);
    defer first.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "gh") != null);

    screen_state.scrollDocument(3);
    var last = try paintTest(alloc, approval.projection().?, &screen_state, &.{}, .{}, testLayout(12, 12), false);
    defer last.deinit(alloc);
    try std.testing.expect(std.mem.indexOf(u8, last.bytes, "ab") != null);
}

test "file approval renders exact unchanged-line elision markers" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    const before =
        "lead-01\nlead-02\nlead-03\nlead-04\nlead-05\nlead-06\nlead-07\nlead-08\n" ++
        "old\n" ++
        "tail-01\ntail-02\ntail-03\ntail-04\ntail-05\ntail-06\ntail-07\ntail-08\n";
    const after =
        "lead-01\nlead-02\nlead-03\nlead-04\nlead-05\nlead-06\nlead-07\nlead-08\n" ++
        "new\n" ++
        "tail-01\ntail-02\ntail-03\ntail-04\ntail-05\ntail-06\ntail-07\ntail-08\n";
    var review = try diff_mod.FileReview.init(alloc, before, after);
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    try std.testing.expect(try approval.syncRequest(alloc, testFileRequest()));
    try std.testing.expect(approval.syncReview(&review));

    var screen = try paintTest(alloc, approval.projection().?, &screen_state, &.{}, .{}, testLayout(40, 80), true);
    defer screen.deinit(alloc);
    var grid = try vt_emulator.Grid.init(alloc, 80, 40);
    defer grid.deinit();
    try grid.feed(screen.bytes);
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    var marker_found = false;
    var numbered_elision_found = false;
    for (1..41) |row_number| {
        row.clearRetainingCapacity();
        try grid.rowTextTrimmed(@intCast(row_number), &row);
        marker_found = marker_found or
            std.mem.indexOf(u8, row.items, "⋯ 3 unchanged lines ⋯") != null;
        numbered_elision_found = numbered_elision_found or
            std.mem.indexOf(u8, row.items, "0 ⋯ 3 unchanged lines ⋯") != null;
    }
    try std.testing.expect(marker_found);
    try std.testing.expect(!numbered_elision_found);
}

test "file approval readiness retains an observed change for the same request" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    var review = try diff_mod.FileReview.init(alloc, "", "changed\n");
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    const request = testFileRequest();
    try std.testing.expect(try approval.syncRequest(alloc, request));
    try std.testing.expect(approval.syncReview(&review));

    var shell = struct {
        render_requests: render_request.RenderRequestState = .{},
        layout: Layout = testLayout(24, 80),
        terminal_dimensions_invalid: bool = false,
        pending_resize_observation: ?u8 = null,
    }{};

    screen_state.recordScreenCommit(approval.request.?.id, .{
        .request_id = request.id,
        .rows = shell.layout.rows,
        .cols = shell.layout.cols,
        .file_identity_visible = false,
        .all_decision_controls_visible = false,
        .changed_or_notice_visible = true,
        .document_scrollable = true,
    });
    try std.testing.expect(!fileApprovalAffirmativeReady(&shell, approval.projection().?, &screen_state));

    screen_state.recordScreenCommit(approval.request.?.id, .{
        .request_id = request.id,
        .rows = shell.layout.rows,
        .cols = shell.layout.cols,
        .file_identity_visible = true,
        .all_decision_controls_visible = true,
        .changed_or_notice_visible = false,
        .document_scrollable = true,
    });
    try std.testing.expect(fileApprovalAffirmativeReady(&shell, approval.projection().?, &screen_state));

    var replacement = testFileRequest();
    replacement.id += 1;
    try std.testing.expect(try approval.syncRequest(alloc, replacement));
    screen_state.clear();
    try std.testing.expect(approval.syncReview(&review));
    screen_state.recordScreenCommit(approval.request.?.id, .{
        .request_id = replacement.id,
        .rows = shell.layout.rows,
        .cols = shell.layout.cols,
        .file_identity_visible = true,
        .all_decision_controls_visible = true,
        .changed_or_notice_visible = false,
        .document_scrollable = true,
    });
    try std.testing.expect(!fileApprovalAffirmativeReady(&shell, approval.projection().?, &screen_state));
}

test "file approval renders controls ready after inspecting a changed row" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    const before =
        "lead-01\nlead-02\nlead-03\nlead-04\nlead-05\nlead-06\nlead-07\nlead-08\n" ++
        "old\n" ++
        "tail-01\ntail-02\ntail-03\ntail-04\ntail-05\ntail-06\ntail-07\ntail-08\n";
    const after =
        "lead-01\nlead-02\nlead-03\nlead-04\nlead-05\nlead-06\nlead-07\nlead-08\n" ++
        "new\n" ++
        "tail-01\ntail-02\ntail-03\ntail-04\ntail-05\ntail-06\ntail-07\ntail-08\n";
    var review = try diff_mod.FileReview.init(alloc, before, after);
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    const request = testFileRequest();
    try std.testing.expect(try approval.syncRequest(alloc, request));
    try std.testing.expect(approval.syncReview(&review));
    screen_state.recordScreenCommit(approval.request.?.id, .{
        .request_id = request.id,
        .rows = 14,
        .cols = 80,
        .file_identity_visible = false,
        .all_decision_controls_visible = false,
        .changed_or_notice_visible = true,
        .document_scrollable = true,
    });

    var screen = try paintTest(alloc, approval.projection().?, &screen_state, &.{}, .{}, testLayout(14, 80), true);
    defer screen.deinit(alloc);
    try std.testing.expect(!screen.changed_or_notice_visible);

    var grid = try vt_emulator.Grid.init(alloc, 80, 14);
    defer grid.deinit();
    try grid.feed(screen.bytes);
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    var ready_choice_visible = false;
    var blocked_choice_visible = false;
    for (1..15) |row_number| {
        row.clearRetainingCapacity();
        try grid.rowTextTrimmed(@intCast(row_number), &row);
        ready_choice_visible = ready_choice_visible or
            std.mem.indexOf(u8, row.items, "❯ 1  Apply once") != null;
        blocked_choice_visible = blocked_choice_visible or
            std.mem.indexOf(u8, row.items, "❯ ! 1  Apply once") != null;
    }
    try std.testing.expect(ready_choice_visible);
    try std.testing.expect(!blocked_choice_visible);
}

test "file approval readiness requires a committed matching screen" {
    const alloc = std.testing.allocator;
    var screen_state = interaction_state.ApprovalScreenState{};
    var review = try diff_mod.FileReview.init(alloc, "", "changed\n");
    defer review.deinit(alloc);
    var approval = approval_prompt.ApprovalPrompt{};
    defer approval.deinit(alloc);
    const request = testFileRequest();
    try std.testing.expect(try approval.syncRequest(alloc, request));
    try std.testing.expect(approval.syncReview(&review));

    var shell = struct {
        render_requests: render_request.RenderRequestState = .{},
        layout: Layout = testLayout(24, 80),
        terminal_dimensions_invalid: bool = false,
        pending_resize_observation: ?u8 = null,
    }{};
    try std.testing.expect(!fileApprovalAffirmativeReady(&shell, approval.projection().?, &screen_state));

    screen_state.recordScreenCommit(approval.request.?.id, .{
        .request_id = request.id,
        .rows = shell.layout.rows,
        .cols = shell.layout.cols,
        .file_identity_visible = true,
        .all_decision_controls_visible = true,
        .changed_or_notice_visible = true,
        .document_scrollable = false,
    });
    try std.testing.expect(fileApprovalAffirmativeReady(&shell, approval.projection().?, &screen_state));

    shell.render_requests.request(.resize);
    try std.testing.expect(!fileApprovalAffirmativeReady(&shell, approval.projection().?, &screen_state));
}

test "command review hint keeps enter and esc guidance at narrow widths" {
    const alloc = std.testing.allocator;
    var wide: std.Io.Writer.Allocating = .init(alloc);
    defer wide.deinit();
    try writeCommandReviewHint(&wide.writer, 5, 100, true);
    try std.testing.expect(std.mem.find(u8, wide.written(), "Wheel Scroll") != null);
    try std.testing.expect(std.mem.find(u8, wide.written(), "Tab Amend") != null);
    try std.testing.expect(std.mem.find(u8, wide.written(), "Esc Cancel") != null);

    var navigation: std.Io.Writer.Allocating = .init(alloc);
    defer navigation.deinit();
    try writeCommandReviewHint(&navigation.writer, 5, 100, false);
    try std.testing.expect(std.mem.find(u8, navigation.written(), "Tab Options") != null);
    try std.testing.expect(std.mem.find(u8, navigation.written(), "Tab Amend") == null);

    var narrow: std.Io.Writer.Allocating = .init(alloc);
    defer narrow.deinit();
    try writeCommandReviewHint(&narrow.writer, 5, 60, true);
    try std.testing.expect(std.mem.find(u8, narrow.written(), "Wheel Scroll") != null);
    try std.testing.expect(std.mem.find(u8, narrow.written(), "Enter Confirm") != null);
    try std.testing.expect(std.mem.find(u8, narrow.written(), "Esc Cancel") != null);
    try std.testing.expect(std.mem.find(u8, narrow.written(), "Options") == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(narrow.written()) <= 60);

    var minimal: std.Io.Writer.Allocating = .init(alloc);
    defer minimal.deinit();
    try writeCommandReviewHint(&minimal.writer, 5, 40, true);
    try std.testing.expect(std.mem.find(u8, minimal.written(), "Enter Confirm") != null);
    try std.testing.expect(std.mem.find(u8, minimal.written(), "Esc Cancel") != null);
    try std.testing.expect(std.mem.find(u8, minimal.written(), "Wheel Scroll") == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(minimal.written()) <= 40);
}
