const std = @import("std");
const diff_mod = @import("../../core/output/diff.zig");
const approval_decision = @import("../../core/permissions/approval_decision.zig");
const approval_prompt = @import("../../core/permissions/approval_prompt.zig");
const display_width = @import("../../core/shared/display_width.zig");
const permission_request = @import("../../core/permissions/permission_request.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const ui_render = @import("../render.zig");
const transcript_runtime = @import("../transcript/runtime.zig");
const approval_readiness = @import("approval_readiness.zig");
const interaction_state = @import("interaction_state.zig");
const picker_presentation = @import("picker_presentation.zig");
const row_text = @import("row_text.zig");

const Allocator = std.mem.Allocator;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;
const ApprovalPrompt = approval_prompt.ApprovalPrompt;
const ApprovalProjection = approval_prompt.Projection;

const file_approval_hint = "1–3 Choose now    ↑↓ Options    Tab Amend    Enter Confirm    Esc Cancel";
const file_approval_navigation_hint = "1–3 Choose now    ↑↓ or Tab Options    Enter Confirm    Esc Cancel";
const file_approval_screen_hint = "1–3 Choose now    ↑↓ Options    Tab Amend    Wheel Scroll    Enter Confirm    Esc Cancel";
const file_approval_navigation_screen_hint = "1–3 Choose now    ↑↓ or Tab Options    Wheel Scroll    Enter Confirm    Esc Cancel";
const file_approval_hint_compact = "1–3 Choose now    Enter Confirm    Esc Cancel";
const file_approval_hint_minimal = "Enter Confirm    Esc Cancel";
// Ordered widest-first; every variant keeps the Enter/Esc controls so narrow
// terminals never lose the submit and cancel instructions.
const file_approval_hint_variants = [_][]const u8{ file_approval_hint, file_approval_hint_compact, file_approval_hint_minimal };
const file_approval_navigation_hint_variants = [_][]const u8{ file_approval_navigation_hint, file_approval_hint_compact, file_approval_hint_minimal };
// The scrollable ladder keeps the wheel-scroll notice as long as it fits; it
// is the only cue that the review document scrolls.
const file_approval_screen_hint_variants = [_][]const u8{
    file_approval_screen_hint,
    "1–3 Choose now    ↑↓ Options    Wheel Scroll    Enter Confirm    Esc Cancel",
    "1–3 Choose    Wheel Scroll    Enter Confirm    Esc Cancel",
    file_approval_hint_compact,
    file_approval_hint_minimal,
};
const file_approval_navigation_screen_hint_variants = [_][]const u8{
    file_approval_navigation_screen_hint,
    "1–3 Choose now    ↑↓ Options    Wheel Scroll    Enter Confirm    Esc Cancel",
    "1–3 Choose    Wheel Scroll    Enter Confirm    Esc Cancel",
    file_approval_hint_compact,
    file_approval_hint_minimal,
};

pub const FileApprovalScreenRowKind = union(enum) {
    divider,
    header,
    question,
    choice: u8,
    hint,
};

pub const ComposedFileApprovalScreenRow = struct {
    text: std.ArrayList(u8),
    complete: bool,
};

/// Reuses the footer's file-approval chrome in the alternate review screen.
/// The caller owns `text`.
pub fn composeFileApprovalScreenRow(
    alloc: Allocator,
    request: permission_request.FileApprovalRequest,
    origin: permission_request.RequestOrigin,
    selected_choice: u8,
    width: u16,
    kind: FileApprovalScreenRowKind,
    affirmative_visible: bool,
    document_scrollable: bool,
    amendment: ?ApprovalProjection,
) !ComposedFileApprovalScreenRow {
    return switch (kind) {
        .divider => .{
            .text = try row_text.composeDividerRow(alloc, width),
            .complete = true,
        },
        .header => {
            const header = projectFileApprovalHeader(request, width);
            return .{
                .text = try composeFileApprovalHeaderRow(
                    alloc,
                    request,
                    header,
                    origin,
                    width,
                ),
                .complete = header.action_visible and
                    header.path.complete_basename_visible,
            };
        },
        .question => .{
            .text = try composeFileApprovalQuestionRow(
                alloc,
                request,
                projectFileApprovalHeader(request, width),
                width,
            ),
            .complete = true,
        },
        .choice => |index| .{
            .text = try composeFileApprovalChoiceRowWithBlocked(
                alloc,
                request,
                selected_choice,
                index,
                amendment,
                width,
                index < 2 and !affirmative_visible,
            ),
            .complete = fileApprovalChoiceLabelFits(request, index, width),
        },
        .hint => .{
            .text = try composeFileApprovalHintRowWithText(
                alloc,
                width,
                display_width.widestFitting(
                    file_approval_hint_variants_for(
                        amendment,
                        document_scrollable,
                    ),
                    @as(usize, width) -| file_approval_left_inset,
                ),
            ),
            .complete = true,
        },
    };
}

pub fn approvalPanelRowsForLayout(shell: *const TranscriptRuntime) u16 {
    return approvalPanelRowsForTerminalRows(shell.layout.rows);
}

pub fn inlineApprovalPanelRows(
    alloc: Allocator,
    label: []const u8,
    width: u16,
    terminal_rows: u16,
) !u16 {
    return inlineApprovalPanelRowsForCommand(alloc, label, null, width, terminal_rows);
}

pub fn inlineApprovalPanelRowsForCommand(
    alloc: Allocator,
    label: []const u8,
    command: ?[]const u8,
    width: u16,
    terminal_rows: u16,
) !u16 {
    const generic_rows = approvalPanelRowsForTerminalRows(terminal_rows);
    var projection = (try projectInlineCommand(alloc, label, command, width)) orelse
        return generic_rows - 1;
    defer projection.deinit(alloc);
    return generic_rows - 2 + projection.rows;
}

pub fn composeInlineApprovalPanelRow(
    alloc: Allocator,
    approval: ApprovalProjection,
    width: u16,
    terminal_rows: u16,
    row_index: u16,
) !std.ArrayList(u8) {
    const generic_rows = approvalPanelRowsForTerminalRows(terminal_rows);
    const request = approval.request;
    var projection = (try projectInlineCommand(alloc, request.label, request.command, width)) orelse
        return composeApprovalPanelRow(
            alloc,
            approval,
            width,
            row_index,
            generic_rows,
        );
    defer projection.deinit(alloc);

    const action_row = approvalActionRowStart(generic_rows);
    if (row_index < action_row) {
        return composeApprovalPanelRow(alloc, approval, width, row_index, generic_rows);
    }
    if (row_index < action_row + projection.rows) {
        return composeInlineCommandRow(
            alloc,
            projection.encoded.bytes,
            width,
            row_index - action_row,
        );
    }
    return composeApprovalPanelRow(
        alloc,
        approval,
        width,
        row_index - projection.rows + 1,
        generic_rows,
    );
}

fn approvalPanelRowsForTerminalRows(terminal_rows: u16) u16 {
    return if (terminal_rows >= interaction_state.approval_spacious_min_terminal_rows)
        interaction_state.approval_panel_rows_spacious
    else
        interaction_state.approval_panel_rows_compact;
}

fn approvalActionRowStart(row_count: u16) u16 {
    return if (row_count >= interaction_state.approval_panel_rows_spacious) 4 else 3;
}

/// Shared measure/paint projection of an approval's wrapped command target.
/// The panel row count and the painted rows must agree exactly, so both
/// entry points derive from this single encoding and segmentation.
const InlineCommandProjection = struct {
    encoded: ProjectedCommandText,
    rows: u16,

    fn deinit(self: *InlineCommandProjection, alloc: Allocator) void {
        self.encoded.deinit(alloc);
    }
};

/// Terminal-safe command text for approval surfaces. LF is retained as a
/// structural row boundary; every other control and invalid byte follows the
/// shared terminal-safe encoding policy.
pub const ProjectedCommandText = struct {
    bytes: []u8,

    pub fn deinit(self: *ProjectedCommandText, alloc: Allocator) void {
        alloc.free(self.bytes);
    }
};

pub fn projectCommandText(
    alloc: Allocator,
    command: []const u8,
) !ProjectedCommandText {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    var encoder = text_utils.IncrementalTerminalSafeEncoder{};
    var line_start: usize = 0;
    for (command, 0..) |byte, index| {
        if (byte != '\n') continue;
        try encoder.append(&out.writer, command[line_start..index]);
        try encoder.finish(&out.writer);
        try out.writer.writeByte('\n');
        line_start = index + 1;
    }
    try encoder.append(&out.writer, command[line_start..]);
    try encoder.finish(&out.writer);

    return .{ .bytes = try out.toOwnedSlice() };
}

fn projectInlineCommand(
    alloc: Allocator,
    label: []const u8,
    command: ?[]const u8,
    width: u16,
) !?InlineCommandProjection {
    const target = commandTargetForApproval(label, command) orelse return null;
    var encoded = try projectCommandText(alloc, target);
    errdefer encoded.deinit(alloc);
    return .{
        .encoded = encoded,
        .rows = try inlineCommandRows(encoded.bytes, width),
    };
}

/// Walks the wrapped segments of an encoded command at the panel's content
/// width. Measurement and painting share this segmentation so the row count
/// cannot drift from the painted rows. Both inline and alternate review
/// prefer word boundaries and retain terminal-safe hard-cut fallback.
pub const CommandSegmentIterator = struct {
    remaining: []const u8,
    content_width: usize,
    trailing_empty_line: bool = false,

    fn init(encoded: []const u8, width: u16) CommandSegmentIterator {
        return initContentWidth(
            encoded,
            @as(usize, width) -| display_width.visibleWidth("  $ "),
        );
    }

    pub fn initContentWidth(
        encoded: []const u8,
        content_width: usize,
    ) CommandSegmentIterator {
        return .{
            .remaining = encoded,
            .content_width = content_width,
        };
    }

    pub fn next(self: *CommandSegmentIterator) !?[]const u8 {
        if (self.remaining.len == 0) {
            if (!self.trailing_empty_line) return null;
            self.trailing_empty_line = false;
            return "";
        }
        if (self.content_width == 0) return error.CommandDoesNotFit;

        const line_end = std.mem.findScalar(u8, self.remaining, '\n') orelse
            self.remaining.len;
        const line = self.remaining[0..line_end];
        if (line.len == 0) {
            self.consumeHardLine(line_end);
            return "";
        }

        const hard_cut = text_utils.prefixTerminalSafeByWidth(
            line,
            self.content_width,
        );
        if (hard_cut.len == 0) return error.CommandDoesNotFit;

        const segment = if (hard_cut.len < line.len) blk: {
            const soft_cut = display_width.wrapCutIgnoringAnsi(
                line,
                self.content_width,
            );
            break :blk if (soft_cut.len > 0 and soft_cut.len < hard_cut.len)
                soft_cut
            else
                hard_cut;
        } else hard_cut;
        if (segment.len == line.len) {
            self.consumeHardLine(line_end);
        } else {
            const untrimmed = line[segment.len..];
            const trimmed = display_width.trimBreakWhitespace(untrimmed);
            self.remaining = self.remaining[segment.len + untrimmed.len - trimmed.len ..];
        }
        return segment;
    }

    fn consumeHardLine(self: *CommandSegmentIterator, line_end: usize) void {
        if (line_end == self.remaining.len) {
            self.remaining = self.remaining[line_end..];
            return;
        }
        self.remaining = self.remaining[line_end + 1 ..];
        self.trailing_empty_line = self.remaining.len == 0;
    }
};

fn inlineCommandRows(encoded: []const u8, width: u16) !u16 {
    if (encoded.len == 0) return 1;
    var segments = CommandSegmentIterator.init(encoded, width);
    var rows: usize = 0;
    while (try segments.next()) |_| rows += 1;
    return @intCast(rows);
}

fn composeInlineCommandRow(
    alloc: Allocator,
    encoded: []const u8,
    width: u16,
    command_row: u16,
) !std.ArrayList(u8) {
    const segment = (try inlineCommandSegment(encoded, width, command_row)) orelse
        return error.CommandDoesNotFit;

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.tag_style);
    try row.appendSlice(alloc, if (command_row == 0) "  $ " else "    ");
    try row.appendSlice(alloc, segment);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn inlineCommandSegment(
    encoded: []const u8,
    width: u16,
    command_row: u16,
) !?[]const u8 {
    if (encoded.len == 0) return if (command_row == 0) "" else null;

    var segments = CommandSegmentIterator.init(encoded, width);
    var current_row: u16 = 0;
    while (try segments.next()) |segment| {
        if (current_row == command_row) return segment;
        current_row += 1;
    }
    return null;
}

const file_approval_static_rows: usize = 11;
const max_file_approval_projected_rows: usize =
    diff_mod.max_preview_lines + file_approval_static_rows + 1;
const file_approval_left_inset: usize = 2;
const file_approval_right_margin: usize = 2;
const file_approval_choice_prefix_width: usize = 7;
const file_approval_line_number_min_width: usize = 5;

pub const FileApprovalRowKind = union(enum) {
    top_divider,
    header,
    header_preview_spacer,
    preview: usize,
    hidden_preview,
    preview_question_spacer,
    question,
    choice: u8,
    choice_hint_spacer,
    hint,
    bottom_divider,
};

const FileApprovalPathProjection = struct {
    start: usize = 0,
    leading_ellipsis: bool = false,
    complete_basename_visible: bool = false,
};

const FileApprovalHeaderProjection = struct {
    action: []const u8,
    path: FileApprovalPathProjection = .{},
    show_stats: bool = false,
    stats_width: usize = 0,
    action_visible: bool = false,
};

pub const FileApprovalProjection = struct {
    rows: [max_file_approval_projected_rows]FileApprovalRowKind = undefined,
    row_count: usize = 0,
    header: FileApprovalHeaderProjection,
    complete_basename_visible: bool = false,
    all_choice_labels_visible: bool = false,
    changed_or_notice_visible: bool = false,
    hidden_preview_count: usize = 0,
    hidden_preview_disclosed: bool = false,
    preview_number_width: usize = file_approval_line_number_min_width,

    fn append(self: *FileApprovalProjection, row: FileApprovalRowKind) void {
        std.debug.assert(self.row_count < self.rows.len);
        self.rows[self.row_count] = row;
        self.row_count += 1;
    }

    pub fn slice(self: *const FileApprovalProjection) []const FileApprovalRowKind {
        return self.rows[0..self.row_count];
    }

    pub fn affirmativeEligible(self: FileApprovalProjection) bool {
        return self.complete_basename_visible and
            self.all_choice_labels_visible and
            self.changed_or_notice_visible and
            (self.hidden_preview_count == 0 or
                self.hidden_preview_disclosed);
    }
};

pub fn fileApprovalDesiredRows(preview: diff_mod.FileChangePreview) u16 {
    return @intCast(
        file_approval_static_rows +
            @min(preview.lines.len, diff_mod.max_preview_lines),
    );
}

pub fn fileApprovalPickerRows(
    request: permission_request.FileApprovalRequest,
) u16 {
    return fileApprovalDesiredRows(request.preview) -
        interaction_state.approval_chrome_rows;
}

pub fn projectFileApproval(
    request: permission_request.FileApprovalRequest,
    selected_choice: u8,
    width: u16,
    allocated_rows: u16,
) FileApprovalProjection {
    const preview_count = @min(
        request.preview.lines.len,
        diff_mod.max_preview_lines,
    );
    const target_count = @min(
        @as(usize, allocated_rows),
        @as(usize, fileApprovalDesiredRows(request.preview)),
    );
    var result = FileApprovalProjection{
        .header = projectFileApprovalHeader(request, width),
    };
    if (target_count == 0) return result;

    var remaining = target_count;
    var choice_selected = [_]bool{false} ** 3;
    const choice_rows = @min(@as(usize, 3), remaining);
    const choice_window = picker_presentation.pickerWindow(
        3,
        @min(@as(usize, selected_choice), 2),
        @intCast(choice_rows),
    );
    for (choice_window.start..choice_window.end) |index| {
        choice_selected[index] = true;
    }
    remaining -= choice_rows;

    const header_selected = remaining > 0;
    if (header_selected) remaining -= 1;
    const question_selected = remaining > 0;
    if (question_selected) remaining -= 1;

    var preview_selected =
        [_]bool{false} ** diff_mod.max_preview_lines;
    var selected_preview_count: usize = 0;
    if (remaining > 0) {
        for (request.preview.lines[0..preview_count], 0..) |line, index| {
            if (!fileApprovalPreviewLineQualifies(line)) continue;
            preview_selected[index] = true;
            selected_preview_count = 1;
            remaining -= 1;
            break;
        }
    }

    var disclosure_selected = false;
    const unselected_preview_count = preview_count - selected_preview_count;
    if (unselected_preview_count <= remaining) {
        for (0..preview_count) |index| {
            if (preview_selected[index]) continue;
            preview_selected[index] = true;
            selected_preview_count += 1;
            remaining -= 1;
        }
    } else if (remaining > 0) {
        disclosure_selected = true;
        remaining -= 1;
        for (0..preview_count) |index| {
            if (remaining == 0) break;
            if (preview_selected[index]) continue;
            preview_selected[index] = true;
            selected_preview_count += 1;
            remaining -= 1;
        }
    }

    const top_divider_selected = remaining > 0;
    if (top_divider_selected) remaining -= 1;
    const bottom_divider_selected = remaining > 0;
    if (bottom_divider_selected) remaining -= 1;
    const hint_selected = remaining > 0;
    if (hint_selected) remaining -= 1;
    const header_preview_spacer_selected = remaining > 0;
    if (header_preview_spacer_selected) remaining -= 1;
    const preview_question_spacer_selected = remaining > 0;
    if (preview_question_spacer_selected) remaining -= 1;
    const choice_hint_spacer_selected = remaining > 0;

    if (top_divider_selected) result.append(.top_divider);
    if (header_selected) result.append(.header);
    if (header_preview_spacer_selected) {
        result.append(.header_preview_spacer);
    }
    for (0..preview_count) |index| {
        if (!preview_selected[index]) continue;
        result.append(.{ .preview = index });
        if (fileApprovalPreviewLineQualifies(request.preview.lines[index])) {
            result.changed_or_notice_visible = true;
        }
        result.preview_number_width = @max(
            result.preview_number_width,
            previewLineNumberWidth(request.preview.lines[index]),
        );
    }
    if (disclosure_selected) result.append(.hidden_preview);
    if (preview_question_spacer_selected) {
        result.append(.preview_question_spacer);
    }
    if (question_selected) result.append(.question);
    for (choice_selected, 0..) |selected, index| {
        if (selected) result.append(.{ .choice = @intCast(index) });
    }
    if (choice_hint_spacer_selected) {
        result.append(.choice_hint_spacer);
    }
    if (hint_selected) result.append(.hint);
    if (bottom_divider_selected) result.append(.bottom_divider);

    result.hidden_preview_count = preview_count - selected_preview_count;
    result.hidden_preview_disclosed = disclosure_selected;
    result.complete_basename_visible =
        header_selected and
        result.header.action_visible and
        result.header.path.complete_basename_visible;
    result.all_choice_labels_visible =
        choice_rows == 3 and
        fileApprovalChoiceLabelFits(request, 0, width) and
        fileApprovalChoiceLabelFits(request, 1, width) and
        fileApprovalChoiceLabelFits(request, 2, width);
    return result;
}

pub fn fileApprovalAffirmativeReady(
    shell: anytype,
    approval: ApprovalProjection,
) bool {
    const settled = approval_readiness.settledFileApproval(shell, approval) orelse return false;
    const allocated_rows = approval_readiness.committedFooterApprovalRows(shell) orelse return false;
    return projectFileApproval(
        settled.file_request,
        approval.choice_index,
        settled.cols,
        allocated_rows,
    ).affirmativeEligible();
}

fn fileApprovalPreviewLineQualifies(line: diff_mod.PreviewLine) bool {
    return switch (line.op) {
        .addition, .deletion, .notice => true,
        .context, .elision => false,
    };
}

fn previewLineNumberWidth(line: diff_mod.PreviewLine) usize {
    const number = line.new_line orelse line.old_line orelse return 0;
    return decimalDigits(number);
}

fn decimalDigits(value: usize) usize {
    var remaining = value;
    var digits: usize = 1;
    while (remaining >= 10) : (digits += 1) {
        remaining /= 10;
    }
    return digits;
}

fn fileApprovalAction(
    request: permission_request.FileApprovalRequest,
) []const u8 {
    if (request.intent == .equality_disclosure) return "Check";
    return switch (request.kind) {
        .write => "Write",
        .edit => "Edit",
    };
}

fn fileApprovalVerb(
    request: permission_request.FileApprovalRequest,
) []const u8 {
    return if (request.intent == .equality_disclosure)
        "Reveal"
    else
        "Apply";
}

fn fileApprovalQuestion(
    request: permission_request.FileApprovalRequest,
) []const u8 {
    return if (request.intent == .equality_disclosure)
        "Reveal that this file already matches?"
    else
        "Apply this change?";
}

fn projectFileApprovalHeader(
    request: permission_request.FileApprovalRequest,
    width: u16,
) FileApprovalHeaderProjection {
    const action = fileApprovalAction(request);
    const action_width = display_width.visibleWidth(action);
    const outer_width: usize = width;
    const inner_width = outer_width -|
        (file_approval_left_inset + file_approval_right_margin);
    var result = FileApprovalHeaderProjection{
        .action = action,
        .action_visible = action_width <= inner_width,
    };
    if (!result.action_visible or inner_width <= action_width) return result;

    const stats_visible =
        request.preview.additions > 0 or request.preview.deletions > 0;
    const stats_width = if (stats_visible)
        4 +
            decimalDigits(request.preview.additions) +
            decimalDigits(request.preview.deletions)
    else
        0;
    if (stats_visible) {
        const fixed_width = action_width + 1 + 2 + stats_width;
        if (fixed_width <= inner_width) {
            const path_budget = inner_width - fixed_width;
            const path = projectFileApprovalPath(
                request.preview,
                path_budget,
            );
            if (path.complete_basename_visible) {
                result.path = path;
                result.show_stats = true;
                result.stats_width = stats_width;
                return result;
            }
        }
    }

    result.path = projectFileApprovalPath(
        request.preview,
        inner_width - action_width - 1,
    );
    return result;
}

fn projectFileApprovalPath(
    preview: diff_mod.FileChangePreview,
    width: usize,
) FileApprovalPathProjection {
    if (width == 0) return .{ .start = preview.path.len };
    const full_width = display_width.visibleWidth(preview.path);
    if (full_width <= width) {
        return .{
            .start = 0,
            .complete_basename_visible = true,
        };
    }

    const marker = "…";
    const marker_width = display_width.visibleWidth(marker);
    if (width <= marker_width) {
        return .{ .start = preview.path.len };
    }
    const suffix = text_utils.suffixTerminalSafeByWidth(
        preview.path,
        width - marker_width,
    );
    const start = preview.path.len - suffix.len;
    return .{
        .start = start,
        .leading_ellipsis = true,
        .complete_basename_visible = start <= preview.path_basename_start,
    };
}

fn fileApprovalChoiceLabelFits(
    request: permission_request.FileApprovalRequest,
    choice_index: u8,
    width: u16,
) bool {
    const outer_width: usize = width;
    if (outer_width < file_approval_choice_prefix_width) return false;
    return fileApprovalChoiceLabelWidth(request, choice_index) <=
        outer_width - file_approval_choice_prefix_width;
}

fn fileApprovalChoiceLabelWidth(
    request: permission_request.FileApprovalRequest,
    choice_index: u8,
) usize {
    const verb_width = display_width.visibleWidth(
        fileApprovalVerb(request),
    );
    return switch (choice_index) {
        0 => verb_width + " once".len,
        1 => verb_width + " + allow ".len +
            fileApprovalScopeSuffixWidth(request.scope),
        2 => if (request.intent == .equality_disclosure)
            "Don't reveal".len
        else
            "Don't apply".len,
        else => 0,
    };
}

fn fileApprovalScopeSuffixWidth(
    scope: permission_request.FileApprovalScope,
) usize {
    return switch (scope) {
        .workspace_files => "workspace file access for this session".len,
        .external_tree => |root_tail| "file changes under ".len +
            display_width.visibleWidth(root_tail) +
            " for this session".len,
    };
}

pub fn composeFileApprovalRow(
    alloc: Allocator,
    request: permission_request.FileApprovalRequest,
    projection: *const FileApprovalProjection,
    choice_index: u8,
    amendment: ?ApprovalProjection,
    width: u16,
    kind: FileApprovalRowKind,
) !std.ArrayList(u8) {
    return switch (kind) {
        .top_divider, .bottom_divider => row_text.composeDividerRow(alloc, width),
        .header => composeFileApprovalHeaderRow(
            alloc,
            request,
            projection.header,
            .active_session,
            width,
        ),
        .header_preview_spacer,
        .preview_question_spacer,
        .choice_hint_spacer,
        => .empty,
        .preview => |index| composeFileApprovalPreviewRow(
            alloc,
            request.preview.lines[index],
            projection.preview_number_width,
            width,
        ),
        .hidden_preview => composeFileApprovalHiddenPreviewRow(
            alloc,
            projection.hidden_preview_count,
            projection.preview_number_width,
            width,
        ),
        .question => composeFileApprovalQuestionRow(
            alloc,
            request,
            projection.header,
            width,
        ),
        .choice => |index| composeFileApprovalChoiceRow(
            alloc,
            request,
            projection.*,
            choice_index,
            index,
            amendment,
            width,
        ),
        .hint => composeFileApprovalHintRow(alloc, amendment, width),
    };
}

fn composeFileApprovalHeaderRow(
    alloc: Allocator,
    request: permission_request.FileApprovalRequest,
    projection: FileApprovalHeaderProjection,
    origin: permission_request.RequestOrigin,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    const active_title = if (request.intent == .equality_disclosure)
        "Permission needed · Review file"
    else
        "Permission needed · Review change";
    var title = try approvalTitle(alloc, origin, active_title);
    defer title.deinit(alloc);
    const title_width = display_width.visibleWidth(title.text);
    const action_width = display_width.visibleWidth(projection.action);
    const stats_width = if (projection.show_stats) projection.stats_width else 0;
    const right_width = action_width + if (stats_width > 0) 3 + stats_width else 0;
    const inner_width = @as(usize, width) -|
        (file_approval_left_inset + file_approval_right_margin);

    try appendSpaces(alloc, &row, @min(file_approval_left_inset, @as(usize, width)));
    try row.appendSlice(alloc, ui_render.bold_style);
    const title_full = try appendTerminalSafeClipped(
        alloc,
        &row,
        title.text,
        inner_width,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    if (!title_full or title_width + right_width + 1 > inner_width) return row;

    try appendSpaces(
        alloc,
        &row,
        inner_width - title_width - right_width,
    );
    try row.appendSlice(alloc, ui_render.statusline_style);
    try row.appendSlice(alloc, projection.action);
    try row.appendSlice(alloc, ui_render.reset_style);
    if (projection.show_stats) {
        try row.appendSlice(alloc, " · ");
        try row.appendSlice(alloc, ui_render.diff_added_style);
        var additions_buf: [32]u8 = undefined;
        const additions = std.fmt.bufPrint(
            &additions_buf,
            "+{d}",
            .{request.preview.additions},
        ) catch "";
        try row.appendSlice(alloc, additions);
        try row.appendSlice(alloc, ui_render.reset_style);
        try row.appendSlice(alloc, "  ");
        try row.appendSlice(alloc, ui_render.diff_removed_style);
        var deletions_buf: [32]u8 = undefined;
        const deletions = std.fmt.bufPrint(
            &deletions_buf,
            "-{d}",
            .{request.preview.deletions},
        ) catch "";
        try row.appendSlice(alloc, deletions);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeFileApprovalQuestionRow(
    alloc: Allocator,
    request: permission_request.FileApprovalRequest,
    projection: FileApprovalHeaderProjection,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var remaining: usize = width;
    try appendSpacesWithinWidth(
        alloc,
        &row,
        file_approval_left_inset,
        &remaining,
    );
    if (projection.path.start < request.preview.path.len and remaining > 0) {
        try row.appendSlice(alloc, ui_render.bold_style);
        if (projection.path.leading_ellipsis) {
            _ = try appendTerminalSafeClipped(alloc, &row, "…", remaining);
            remaining -|= 1;
        }
        const path = request.preview.path[projection.path.start..];
        _ = try appendTerminalSafeClipped(alloc, &row, path, remaining);
        remaining -|= @min(display_width.visibleWidth(path), remaining);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    if (remaining > 0) {
        const separator = "  ·  ";
        _ = try appendTerminalSafeClipped(alloc, &row, separator, remaining);
        remaining -|= @min(display_width.visibleWidth(separator), remaining);
    }
    _ = try appendTerminalSafeClipped(
        alloc,
        &row,
        fileApprovalQuestion(request),
        remaining,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeFileApprovalPreviewRow(
    alloc: Allocator,
    line: diff_mod.PreviewLine,
    number_width: usize,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var remaining: usize = width;
    try appendSpacesWithinWidth(
        alloc,
        &row,
        file_approval_left_inset,
        &remaining,
    );

    if (line.op == .elision or line.op == .notice) {
        try appendSpacesWithinWidth(
            alloc,
            &row,
            number_width + 2,
            &remaining,
        );
        try row.appendSlice(alloc, ui_render.statusline_style);
        _ = try appendTerminalSafeClipped(
            alloc,
            &row,
            line.text,
            remaining,
        );
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    const number = line.new_line orelse line.old_line orelse 0;
    var number_buf: [32]u8 = undefined;
    const number_text = std.fmt.bufPrint(
        &number_buf,
        "{d}",
        .{number},
    ) catch "";
    try appendSpacesWithinWidth(
        alloc,
        &row,
        number_width -| display_width.visibleWidth(number_text),
        &remaining,
    );
    try row.appendSlice(alloc, ui_render.statusline_style);
    _ = try appendTerminalSafeClipped(
        alloc,
        &row,
        number_text,
        remaining,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    remaining -|= display_width.visibleWidth(number_text);
    try appendSpacesWithinWidth(alloc, &row, 1, &remaining);

    const op: []const u8 = switch (line.op) {
        .addition => "+",
        .deletion => "-",
        .context => " ",
        .elision, .notice => unreachable,
    };
    const style = switch (line.op) {
        .addition => ui_render.diff_added_style,
        .deletion => ui_render.diff_removed_style,
        .context => ui_render.statusline_style,
        .elision, .notice => unreachable,
    };
    try row.appendSlice(alloc, style);
    _ = try appendTerminalSafeClipped(alloc, &row, op, remaining);
    remaining -|= display_width.visibleWidth(op);
    try appendSpacesWithinWidth(alloc, &row, 1, &remaining);
    _ = try appendTerminalSafeClipped(
        alloc,
        &row,
        line.text,
        remaining,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeFileApprovalHiddenPreviewRow(
    alloc: Allocator,
    hidden_count: usize,
    number_width: usize,
    width: u16,
) !std.ArrayList(u8) {
    var text_buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(
        &text_buf,
        "⋯ {d} preview {s} hidden · resize to review",
        .{
            hidden_count,
            if (hidden_count == 1) "row" else "rows",
        },
    ) catch "⋯ preview rows hidden · resize to review";
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var remaining: usize = width;
    try appendSpacesWithinWidth(
        alloc,
        &row,
        file_approval_left_inset + number_width + 2,
        &remaining,
    );
    try row.appendSlice(alloc, ui_render.statusline_style);
    _ = try appendTerminalSafeClipped(
        alloc,
        &row,
        text,
        remaining,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeFileApprovalChoiceRow(
    alloc: Allocator,
    request: permission_request.FileApprovalRequest,
    projection: FileApprovalProjection,
    selected_index: u8,
    row_index: u8,
    amendment: ?ApprovalProjection,
    width: u16,
) !std.ArrayList(u8) {
    const blocked =
        row_index < 2 and !projection.affirmativeEligible();
    return composeFileApprovalChoiceRowWithBlocked(
        alloc,
        request,
        selected_index,
        row_index,
        amendment,
        width,
        blocked,
    );
}

fn composeFileApprovalChoiceRowWithBlocked(
    alloc: Allocator,
    request: permission_request.FileApprovalRequest,
    selected_index: u8,
    row_index: u8,
    amendment: ?ApprovalProjection,
    width: u16,
    blocked: bool,
) !std.ArrayList(u8) {
    const selected = row_index == selected_index;
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var remaining: usize = width;
    try appendSpacesWithinWidth(
        alloc,
        &row,
        file_approval_left_inset,
        &remaining,
    );

    const row_style: []const u8 = if (blocked)
        ui_render.statusline_style
    else if (selected)
        ui_render.tag_style
    else
        "";
    if (row_style.len > 0) try row.appendSlice(alloc, row_style);

    const marker = if (selected) "❯ " else "  ";
    _ = try appendTerminalSafeClipped(
        alloc,
        &row,
        marker,
        remaining,
    );
    remaining -|= display_width.visibleWidth(marker);
    if (blocked) {
        _ = try appendTerminalSafeClipped(
            alloc,
            &row,
            "! ",
            remaining,
        );
        remaining -|= 2;
    }

    var number_buf: [2]u8 = .{ '1' + row_index, 0 };
    const number = number_buf[0..1];
    if (!blocked and !selected) {
        try row.appendSlice(alloc, ui_render.statusline_style);
    }
    _ = try appendTerminalSafeClipped(
        alloc,
        &row,
        number,
        remaining,
    );
    remaining -|= 1;
    if (!blocked and !selected) {
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    try appendSpacesWithinWidth(alloc, &row, 2, &remaining);

    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(alloc);
    try appendFileApprovalChoiceLabel(
        alloc,
        &label,
        request,
        row_index,
        amendment,
        remaining,
    );
    const label_width = display_width.visibleWidthIgnoringAnsi(label.items);
    if (label_width <= remaining) {
        try row.appendSlice(alloc, label.items);
    } else {
        _ = try appendTerminalSafeClipped(
            alloc,
            &row,
            label.items,
            remaining,
        );
    }
    if (blocked and selected) {
        remaining -|= @min(label_width, remaining);
        _ = try appendTerminalSafeClipped(
            alloc,
            &row,
            " · resize to review",
            remaining,
        );
    }
    if (row_style.len > 0 or !selected) {
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn appendFileApprovalChoiceLabel(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    request: permission_request.FileApprovalRequest,
    choice_index: u8,
    amendment: ?ApprovalProjection,
    max_width: usize,
) !void {
    if (amendment) |approval| {
        if (approval.amendmentChoice() == choice_index) {
            try appendFileApprovalAmendmentLabel(
                alloc,
                out,
                request,
                choice_index,
                approval.draftForChoice(choice_index),
                approval.draftCursorForChoice(choice_index),
                max_width,
            );
            return;
        }
    }
    const verb = fileApprovalVerb(request);
    switch (choice_index) {
        0 => {
            try out.appendSlice(alloc, verb);
            try out.appendSlice(alloc, " once");
        },
        1 => {
            try out.appendSlice(alloc, verb);
            try out.appendSlice(alloc, " + allow ");
            switch (request.scope) {
                .workspace_files => try out.appendSlice(
                    alloc,
                    "workspace file access for this session",
                ),
                .external_tree => |root_tail| {
                    try out.appendSlice(alloc, "file changes under ");
                    try out.appendSlice(alloc, root_tail);
                    try out.appendSlice(alloc, " for this session");
                },
            }
        },
        2 => try out.appendSlice(
            alloc,
            if (request.intent == .equality_disclosure)
                "Don't reveal"
            else
                "Don't apply",
        ),
        else => {},
    }
}

fn appendFileApprovalAmendmentLabel(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    request: permission_request.FileApprovalRequest,
    choice_index: u8,
    draft: []const u8,
    cursor: usize,
    max_width: usize,
) !void {
    if (draft.len == 0) {
        switch (choice_index) {
            0 => {
                try out.appendSlice(alloc, fileApprovalVerb(request));
                try out.appendSlice(alloc, " once, ");
                try appendApprovalPlaceholder(alloc, out, "and tell fx what to do next");
            },
            2 => {
                try appendFileApprovalDenialLabel(alloc, out, request);
                try out.appendSlice(alloc, ", ");
                try appendApprovalPlaceholder(alloc, out, "and tell fx what to do differently");
            },
            else => {},
        }
        return;
    }

    switch (choice_index) {
        0 => {
            try out.appendSlice(alloc, fileApprovalVerb(request));
            try out.appendSlice(alloc, " once, ");
        },
        2 => {
            try appendFileApprovalDenialLabel(alloc, out, request);
            try out.appendSlice(alloc, ", ");
        },
        else => return,
    }
    try appendApprovalDraftToList(
        alloc,
        out,
        draft,
        cursor,
        max_width -| display_width.visibleWidthIgnoringAnsi(out.items),
    );
}

fn appendFileApprovalDenialLabel(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    request: permission_request.FileApprovalRequest,
) !void {
    try out.appendSlice(
        alloc,
        if (request.intent == .equality_disclosure) "Don't reveal" else "Don't apply",
    );
}

fn appendApprovalDraftToList(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    draft: []const u8,
    cursor: usize,
    max_width: usize,
) !void {
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, out);
    errdefer out.* = writer.toArrayList();
    try writeApprovalDraft(&writer.writer, draft, cursor, max_width);
    out.* = writer.toArrayList();
}

fn appendApprovalPlaceholder(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    placeholder: []const u8,
) !void {
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, out);
    try writeApprovalPlaceholder(&writer.writer, placeholder);
    out.* = writer.toArrayList();
}

fn composeFileApprovalHintRow(
    alloc: Allocator,
    amendment: ?ApprovalProjection,
    width: u16,
) !std.ArrayList(u8) {
    return composeFileApprovalHintRowWithText(
        alloc,
        width,
        display_width.widestFitting(
            file_approval_hint_variants_for(amendment, false),
            @as(usize, width) -| file_approval_left_inset,
        ),
    );
}

fn file_approval_hint_variants_for(
    approval: ?ApprovalProjection,
    document_scrollable: bool,
) []const []const u8 {
    const can_amend = if (approval) |prompt|
        prompt.can_amend_selected_choice()
    else
        false;
    if (document_scrollable) {
        return if (can_amend)
            &file_approval_screen_hint_variants
        else
            &file_approval_navigation_screen_hint_variants;
    }
    return if (can_amend)
        &file_approval_hint_variants
    else
        &file_approval_navigation_hint_variants;
}

fn composeFileApprovalHintRowWithText(
    alloc: Allocator,
    width: u16,
    hint: []const u8,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var remaining: usize = width;
    try appendSpacesWithinWidth(
        alloc,
        &row,
        file_approval_left_inset,
        &remaining,
    );
    try row.appendSlice(alloc, ui_render.statusline_style);
    _ = try appendTerminalSafeClipped(
        alloc,
        &row,
        hint,
        remaining,
    );
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendTerminalSafeClipped(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
) !bool {
    const text_width = display_width.visibleWidth(text);
    if (text_width <= width) {
        try out.appendSlice(alloc, text);
        return true;
    }
    if (width == 0) return false;
    const marker = "…";
    const marker_width = display_width.visibleWidth(marker);
    if (width <= marker_width) {
        try out.appendSlice(alloc, marker);
        return false;
    }
    const prefix = text_utils.prefixTerminalSafeByWidth(
        text,
        width - marker_width,
    );
    try out.appendSlice(alloc, prefix);
    try out.appendSlice(alloc, marker);
    return false;
}

fn appendSpacesWithinWidth(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    count: usize,
    remaining: *usize,
) !void {
    const take = @min(count, remaining.*);
    try appendSpaces(alloc, out, take);
    remaining.* -= take;
}

fn appendSpaces(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    count: usize,
) !void {
    try out.appendNTimes(alloc, ' ', count);
}

pub fn composeApprovalPanelRow(alloc: Allocator, approval: ApprovalProjection, width: u16, row_index: u16, row_count: u16) !std.ArrayList(u8) {
    if (approvalChoiceIndexForPanelRow(row_index, row_count)) |choice| {
        if (approval.amendmentChoice() == choice) {
            return composeApprovalAmendmentPanelRow(alloc, approval, choice, width);
        }
    }

    var buf: [row_text.max_top_row_len]u8 = undefined;
    const raw_label = approval.request.label;
    var label = try text_utils.encodeTerminalSafe(
        alloc,
        raw_label,
        diff_mod.max_request_projection_bytes,
    );
    defer label.deinit(alloc);
    if (row_index == 0) {
        return composeApprovalHeaderRow(alloc, approval, label.bytes, width);
    }
    if (approvalActionRowIndex(row_index, row_count)) {
        var preview = if (approval.request.tool_arguments_preview) |raw_preview|
            try text_utils.encodeTerminalSafe(
                alloc,
                raw_preview,
                permission_request.max_tool_arguments_preview_bytes,
            )
        else
            null;
        defer if (preview) |*value| value.deinit(alloc);
        var action_line: std.Io.Writer.Allocating = .init(alloc);
        defer action_line.deinit();
        try writeApprovalActionLine(
            &action_line.writer,
            label.bytes,
            if (preview) |value| value.bytes else null,
            width,
        );

        var action_row: std.ArrayList(u8) = .empty;
        if (preview != null) {
            try row_text.appendSingleLineEllipsized(
                alloc,
                &action_row,
                action_line.written(),
                width,
            );
        } else {
            try row_text.appendClipped(
                alloc,
                &action_row,
                action_line.written(),
                width,
            );
        }
        try action_row.appendSlice(alloc, ui_render.reset_style);
        return action_row;
    }

    const line = buildApprovalPanelLineWithLabel(
        buf[0..],
        approval,
        label.bytes,
        row_index,
        row_count,
        width,
    );

    var row: std.ArrayList(u8) = .empty;
    try row_text.appendClipped(alloc, &row, line, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn approvalActionRowIndex(row_index: u16, row_count: u16) bool {
    return if (row_count >= interaction_state.approval_panel_rows_spacious)
        row_index == 4
    else
        row_index == 3;
}

fn buildApprovalPanelLine(buf: []u8, approval: ApprovalProjection, row_index: u16, row_count: u16, width: u16) []const u8 {
    const label = approval.request.label;
    return buildApprovalPanelLineWithLabel(buf, approval, label, row_index, row_count, width);
}

fn buildApprovalPanelLineWithLabel(
    buf: []u8,
    approval: ApprovalProjection,
    label: []const u8,
    row_index: u16,
    row_count: u16,
    width: u16,
) []const u8 {
    const b = ui_render.bold_style;
    const dim = ui_render.dim_style;
    const r = ui_render.reset_style;
    const target = approvalTarget(label);
    const explanation = approval.request.explanation;
    const dynamic_mcp = approval.request.tool_arguments_preview != null;

    if (row_count >= interaction_state.approval_panel_rows_spacious) {
        return switch (row_index) {
            0 => "  Permission needed · Choose one",
            1 => "",
            2 => std.fmt.bufPrint(buf, "  {s}{s}{s}", .{ b, approvalQuestion(label, dynamic_mcp), r }) catch "  Permission request",
            3 => approvalReasonLine(buf, label, target, explanation, dynamic_mcp),
            4 => approvalActionLine(buf, label, target),
            5 => "",
            6 => approvalChoiceLine(buf, approval.choice_index == 0, approvalChoiceLabel(approval, 0)),
            7 => approvalChoiceLine(buf, approval.choice_index == 1, approvalChoiceLabel(approval, 1)),
            8 => approvalChoiceLine(buf, approval.choice_index == 2, approvalChoiceLabel(approval, 2)),
            9 => "",
            10 => std.fmt.bufPrint(buf, "  {s}{s}{s}", .{ dim, approvalHint(approval, width -| 2), r }) catch interaction_state.approval_hint,
            else => "",
        };
    }

    return switch (row_index) {
        0 => "  Permission needed · Choose one",
        1 => std.fmt.bufPrint(buf, "  {s}{s}{s}", .{ b, approvalQuestion(label, dynamic_mcp), r }) catch "  Permission request",
        2 => approvalReasonLine(buf, label, target, explanation, dynamic_mcp),
        3 => approvalActionLine(buf, label, target),
        4 => approvalChoiceLine(buf, approval.choice_index == 0, approvalChoiceLabel(approval, 0)),
        5 => approvalChoiceLine(buf, approval.choice_index == 1, approvalChoiceLabel(approval, 1)),
        6 => approvalChoiceLine(buf, approval.choice_index == 2, approvalChoiceLabel(approval, 2)),
        7 => std.fmt.bufPrint(buf, "  {s}{s}{s}", .{ dim, approvalHint(approval, width -| 2), r }) catch interaction_state.approval_hint,
        else => "",
    };
}

fn approvalChoiceIndexForPanelRow(row_index: u16, row_count: u16) ?u8 {
    if (row_count >= interaction_state.approval_panel_rows_spacious) {
        return switch (row_index) {
            6 => 0,
            7 => 1,
            8 => 2,
            else => null,
        };
    }
    return switch (row_index) {
        4 => 0,
        5 => 1,
        6 => 2,
        else => null,
    };
}

fn composeApprovalAmendmentPanelRow(
    alloc: Allocator,
    approval: ApprovalProjection,
    choice: u8,
    width: u16,
) !std.ArrayList(u8) {
    var raw: std.Io.Writer.Allocating = .init(alloc);
    defer raw.deinit();

    try raw.writer.writeAll("  ❯ ");
    try raw.writer.writeAll(ui_render.tag_style);
    const draft = approval.draftForChoice(choice);
    const choice_prefix = approvalChoicePrefix(choice);
    try raw.writer.writeAll(choice_prefix);
    if (draft.len == 0) {
        try writeApprovalPlaceholder(&raw.writer, approvalAmendmentPlaceholder(choice));
    } else {
        try writeApprovalDraft(
            &raw.writer,
            draft,
            approval.draftCursorForChoice(choice),
            @as(usize, width) -|
                (display_width.visibleWidth("  ❯ ") +
                    display_width.visibleWidth(choice_prefix)),
        );
    }
    try raw.writer.writeAll(ui_render.reset_style);

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row_text.appendClipped(alloc, &row, raw.writer.buffered(), width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

const ApprovalDraftWindow = struct {
    before: []const u8,
    cursor_unit: []const u8,
    after: []const u8,
    cursor_visible: bool,
};

fn approvalDraftWindow(
    draft: []const u8,
    cursor: usize,
    max_width: usize,
) ApprovalDraftWindow {
    const safe_cursor = @min(cursor, draft.len);
    if (max_width == 0) {
        return .{
            .before = draft[safe_cursor..safe_cursor],
            .cursor_unit = draft[safe_cursor..safe_cursor],
            .after = draft[safe_cursor..safe_cursor],
            .cursor_visible = false,
        };
    }

    const unit = display_width.displayUnitAt(draft, safe_cursor);
    const show_cursor_unit =
        unit.byte_len > 0 and unit.cell_width > 0 and
        unit.cell_width <= max_width;
    const cursor_width = if (show_cursor_unit) unit.cell_width else 1;
    const cursor_end = if (show_cursor_unit)
        safe_cursor + unit.byte_len
    else
        safe_cursor;

    var before_start: usize = 0;
    var before_width = display_width.visibleWidth(draft[0..safe_cursor]);
    while (before_start < safe_cursor and
        before_width + cursor_width > max_width)
    {
        const leading_unit = display_width.displayUnitAt(draft, before_start);
        before_width -|= leading_unit.cell_width;
        before_start += leading_unit.byte_len;
    }

    const after_width = max_width -| (before_width + cursor_width);
    const after = display_width.prefixByWidth(
        draft[cursor_end..],
        after_width,
    );
    return .{
        .before = draft[before_start..safe_cursor],
        .cursor_unit = if (show_cursor_unit)
            draft[safe_cursor..cursor_end]
        else
            draft[safe_cursor..safe_cursor],
        .after = after,
        .cursor_visible = true,
    };
}

fn writeApprovalDraft(
    writer: *std.Io.Writer,
    draft: []const u8,
    cursor: usize,
    max_width: usize,
) !void {
    const window = approvalDraftWindow(draft, cursor, max_width);
    if (!window.cursor_visible) return;

    try writer.writeAll(window.before);
    try writer.writeAll("\x1b[7m");
    if (window.cursor_unit.len > 0) {
        try writer.writeAll(window.cursor_unit);
    } else {
        try writer.writeByte(' ');
    }
    try writer.writeAll(ui_render.reset_style);
    if (window.after.len > 0) {
        try writer.writeAll(ui_render.tag_style);
        try writer.writeAll(window.after);
    }
}

fn writeApprovalPlaceholder(writer: *std.Io.Writer, placeholder: []const u8) !void {
    if (placeholder.len == 0) return;
    try writer.writeAll(ui_render.reset_style);
    try writer.writeAll(ui_render.statusline_style);
    try writer.writeAll("\x1b[7m");
    try writer.writeByte(placeholder[0]);
    try writer.writeAll(ui_render.reset_style);
    if (placeholder.len > 1) {
        try writer.writeAll(ui_render.statusline_style);
        try writer.writeAll(placeholder[1..]);
    }
}

fn approvalChoiceLabel(approval: ApprovalProjection, choice: u8) []const u8 {
    if (approval.request.confirmation_only) return switch (choice) {
        0 => "1. Confirm",
        1 => "2. Cancel",
        else => "",
    };
    if (approval.amendmentChoice() == choice) return approvalAmendmentLabel(choice);
    if (approval.request.tool_arguments_preview != null) {
        return switch (choice) {
            0 => "1. Allow once",
            1 => approvalAlwaysChoice(approval, approval.request.label),
            2 => "3. Deny",
            else => "",
        };
    }
    return switch (choice) {
        0 => interaction_state.approval_once_label,
        1 => approvalAlwaysChoice(approval, approval.request.label),
        2 => interaction_state.approval_deny_label,
        else => "",
    };
}

fn approvalAmendmentLabel(choice: u8) []const u8 {
    return switch (choice) {
        0 => "1. Yes, and tell fx what to do next",
        2 => "3. No, and tell fx what to do differently",
        else => "",
    };
}

fn approvalAmendmentPlaceholder(choice: u8) []const u8 {
    return switch (choice) {
        0 => "and tell fx what to do next",
        2 => "and tell fx what to do differently",
        else => "",
    };
}

fn approvalChoicePrefix(choice: u8) []const u8 {
    return switch (choice) {
        0 => "1. Yes, ",
        2 => "3. No, ",
        else => "",
    };
}

fn approvalHint(approval: ApprovalProjection, width: u16) []const u8 {
    if (approval.request.confirmation_only) {
        const confirmation_variants = [_][]const u8{
            "1–2 Choose    Enter Confirm    Esc Cancel",
            "Enter Confirm    Esc Cancel",
        };
        return display_width.widestFitting(&confirmation_variants, width);
    }
    const variants: []const []const u8 = if (approval.can_amend_selected_choice())
        &interaction_state.approval_amendment_hint_variants
    else
        &interaction_state.approval_hint_variants;
    return display_width.widestFitting(variants, width);
}

pub fn composeInlineApprovalHintRow(
    alloc: Allocator,
    approval: ApprovalProjection,
    width: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row_text.appendClipped(alloc, &row, approvalHint(approval, width), width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn approvalChoiceLine(buf: []u8, selected: bool, label: []const u8) []const u8 {
    const marker: []const u8 = if (selected) "❯ " else "  ";
    const label_style = if (selected) ui_render.tag_style else "";
    const suffix_style = if (selected) ui_render.reset_style else "";
    return std.fmt.bufPrint(buf, "  {s}{s}{s}{s}", .{ marker, label_style, label, suffix_style }) catch label;
}

fn composeApprovalHeaderRow(
    alloc: Allocator,
    approval: ApprovalProjection,
    label: []const u8,
    width: u16,
) !std.ArrayList(u8) {
    var title = try approvalTitle(
        alloc,
        approval.request.origin,
        "Permission needed · Choose one",
    );
    defer title.deinit(alloc);
    const kind = approvalKind(
        label,
        approval.request.tool_arguments_preview != null,
    );
    const inset_width = 2;
    const right_margin = 2;
    const inner_width = @as(usize, width) -| (inset_width + right_margin);
    const title_width = display_width.visibleWidth(title.text);
    const kind_width = display_width.visibleWidth(kind);
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try appendSpaces(alloc, &row, @min(inset_width, @as(usize, width)));
    try row.appendSlice(alloc, ui_render.bold_style);
    _ = try appendTerminalSafeClipped(alloc, &row, title.text, inner_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    if (title_width + kind_width + 1 > inner_width) {
        return row;
    }
    const gap = inner_width - title_width - kind_width;
    try appendSpaces(alloc, &row, gap);
    try row.appendSlice(alloc, ui_render.statusline_style);
    try row.appendSlice(alloc, kind);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

const ApprovalTitle = struct {
    text: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: *ApprovalTitle, alloc: Allocator) void {
        if (self.owned) |value| alloc.free(value);
        self.* = undefined;
    }
};

fn approvalTitle(
    alloc: Allocator,
    origin: permission_request.RequestOrigin,
    active_title: []const u8,
) !ApprovalTitle {
    return switch (origin) {
        .active_session => .{ .text = active_title },
        .subagent => |child_name| blk: {
            var encoded = try text_utils.encodeTerminalSafe(
                alloc,
                child_name,
                diff_mod.max_request_projection_bytes,
            );
            defer encoded.deinit(alloc);
            const owned = try std.fmt.allocPrint(
                alloc,
                "Subagent {s} needs permission",
                .{encoded.bytes},
            );
            break :blk .{ .text = owned, .owned = owned };
        },
    };
}

fn approvalKind(label: []const u8, dynamic_mcp: bool) []const u8 {
    if (std.mem.startsWith(u8, label, "Remember ") or
        std.mem.startsWith(u8, label, "Revoke saved-session")) return "Permission rule";
    if (dynamic_mcp) return "MCP tool";
    if (commandLabelPrefix(label) != null) return "Command";
    if (std.mem.startsWith(u8, label, "write_file ")) return "Write file";
    if (std.mem.startsWith(u8, label, "edit_file ")) return "Edit file";
    if (std.mem.startsWith(u8, label, "task ")) return "Subagent";
    if (std.mem.startsWith(u8, label, "skill ")) return "Skill";
    return "Tool";
}

fn approvalQuestion(label: []const u8, dynamic_mcp: bool) []const u8 {
    if (std.mem.eql(u8, label, "Remember allow for this saved session")) {
        return "Remember allow for this saved session?";
    }
    if (std.mem.eql(u8, label, "Remember deny for this saved session")) {
        return "Remember deny for this saved session?";
    }
    if (std.mem.eql(u8, label, "Revoke saved-session permission rule")) {
        return "Revoke this saved-session permission rule?";
    }
    if (dynamic_mcp) return "Allow this MCP tool call?";
    if (commandLabelPrefix(label) != null) return "Would you like to run the following command?";
    if (std.mem.startsWith(u8, label, "write_file ")) return "Would you like to create or update this file?";
    if (std.mem.startsWith(u8, label, "edit_file ")) return "Would you like to edit this file?";
    if (std.mem.startsWith(u8, label, "task ")) return "Would you like to start this subagent task?";
    if (std.mem.startsWith(u8, label, "skill ")) return "Would you like to run this skill?";
    return "Would you like to allow this action?";
}

fn approvalTarget(label: []const u8) []const u8 {
    const prefixes = [_][]const u8{
        "shell.run ",
        "write_file ",
        "edit_file ",
        "task ",
        "skill ",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, label, prefix)) return label[prefix.len..];
    }
    return label;
}

fn approvalReasonLine(
    buf: []u8,
    label: []const u8,
    target: []const u8,
    explanation: ?[]const u8,
    dynamic_mcp: bool,
) []const u8 {
    const dim = ui_render.dim_style;
    const r = ui_render.reset_style;
    if (explanation) |text| {
        return std.fmt.bufPrint(buf, "  {s}{s}{s}", .{ dim, text, r }) catch "  Auto agent couldn’t approve because this request needs your review.";
    }
    if (approvalAnnotation(target)) |annotation| {
        return std.fmt.bufPrint(buf, "  {s}Reason:{s} {s}", .{ dim, r, annotation }) catch "  Reason: permission required";
    }
    if (dynamic_mcp) {
        return std.fmt.bufPrint(
            buf,
            "  {s}Reason:{s} This MCP tool needs approval before fx can send the request.",
            .{ dim, r },
        ) catch "  Reason: MCP tool approval required";
    }
    if (commandLabelPrefix(label) != null) {
        if (firstUrlHost(target)) |host| {
            return std.fmt.bufPrint(buf, "  {s}Reason:{s} This command may make a network request to {s}.", .{ dim, r, host }) catch "  Reason: shell command requires approval";
        }
        return "";
    }
    if (std.mem.startsWith(u8, label, "write_file ") or
        std.mem.startsWith(u8, label, "edit_file "))
    {
        return std.fmt.bufPrint(buf, "  {s}Reason:{s} This action changes files in your workspace.", .{ dim, r }) catch "  Reason: file change requires approval";
    }
    return std.fmt.bufPrint(buf, "  {s}Reason:{s} This action needs approval before fx can continue.", .{ dim, r }) catch "  Reason: permission required";
}

fn approvalActionLine(buf: []u8, label: []const u8, target: []const u8) []const u8 {
    const clean_target = approvalActionTarget(target);
    if (commandLabelPrefix(label) != null) {
        return std.fmt.bufPrint(buf, "  $ {s}", .{clean_target}) catch "  $";
    }
    return std.fmt.bufPrint(buf, "  {s}", .{clean_target}) catch "  permission request";
}

fn writeApprovalActionLine(
    writer: *std.Io.Writer,
    label: []const u8,
    tool_arguments_preview: ?[]const u8,
    width: u16,
) !void {
    const target = approvalActionTarget(approvalTarget(label));
    if (commandLabelPrefix(label) != null) {
        try writer.print("  $ {s}", .{target});
        return;
    }
    if (tool_arguments_preview) |preview| {
        const verbose_prefix_bytes = 2 + target.len + " · Arguments for this request: ".len;
        if (width < verbose_prefix_bytes + 16) {
            try writer.print("  {s} · {s}", .{ target, preview });
        } else {
            try writer.print(
                "  {s} · Arguments for this request: {s}",
                .{ target, preview },
            );
        }
        return;
    }
    try writer.print("  {s}", .{target});
}

pub fn commandTarget(label: []const u8) ?[]const u8 {
    if (commandLabelPrefix(label) == null) return null;
    return approvalActionTarget(approvalTarget(label));
}

pub fn commandTargetForApproval(label: []const u8, command: ?[]const u8) ?[]const u8 {
    return command orelse commandTarget(label);
}

fn approvalAlwaysChoice(approval: ApprovalProjection, label: []const u8) []const u8 {
    if (approval.request.tool_arguments_preview != null) {
        return "2. Allow this MCP tool for this session";
    }
    if (commandLabelPrefix(label) != null) return "2. Yes, and don't ask again for this exact command";
    return "2. Yes, and don't ask again for this request";
}

fn commandLabelPrefix(label: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, label, "shell.run ")) return "shell.run ";
    return null;
}

fn approvalActionTarget(target: []const u8) []const u8 {
    if (approvalAnnotationStart(target)) |start| return std.mem.trimEnd(u8, target[0..start], " ");
    return target;
}

fn approvalAnnotation(target: []const u8) ?[]const u8 {
    const start = approvalAnnotationStart(target) orelse return null;
    const annotation = target[start..];
    if (std.mem.startsWith(u8, annotation, " (risk: ")) {
        const body = annotation[" (risk: ".len..];
        if (std.mem.endsWith(u8, body, ")")) return body[0 .. body.len - 1];
        return body;
    }
    if (std.mem.startsWith(u8, annotation, " (network: ")) {
        const body = annotation[" (network: ".len..];
        if (std.mem.endsWith(u8, body, ")")) return body[0 .. body.len - 1];
        return body;
    }
    return null;
}

fn approvalAnnotationStart(target: []const u8) ?usize {
    var start: ?usize = null;
    for ([_][]const u8{ " (risk: ", " (network: " }) |marker| {
        const index = std.mem.find(u8, target, marker) orelse continue;
        if (start == null or index < start.?) start = index;
    }
    return start;
}

fn firstUrlHost(text: []const u8) ?[]const u8 {
    const schemes = [_][]const u8{ "https://", "http://" };
    for (schemes) |scheme| {
        if (std.mem.find(u8, text, scheme)) |idx| {
            var host_start = idx + scheme.len;
            if (host_start >= text.len) return null;
            while (host_start < text.len and text[host_start] == '/') host_start += 1;
            var host_end = host_start;
            while (host_end < text.len) : (host_end += 1) {
                switch (text[host_end]) {
                    '/', ':', '?', '#', ' ', '\t', '\n', '\r', '\'', '"', '`' => break,
                    else => {},
                }
            }
            if (host_end > host_start) return text[host_start..host_end];
        }
    }
    return null;
}

test "file approval full frame uses canonical vertical copy and spacing" {
    const preview = diff_mod.FileChangePreview{
        .path = "note.txt",
        .lines = &.{
            .{ .op = .deletion, .old_line = 2, .text = "before" },
            .{ .op = .addition, .new_line = 2, .text = "after" },
        },
        .additions = 1,
        .deletions = 1,
        .truncated = false,
    };
    const request: permission_request.FileApprovalRequest = .{ .kind = .edit, .intent = .mutation, .preview = preview, .scope = .workspace_files };
    const projection = projectFileApproval(request, 0, 96, fileApprovalDesiredRows(preview));
    try std.testing.expect(projection.affirmativeEligible());
    try std.testing.expectEqual(@as(usize, fileApprovalDesiredRows(preview)), projection.slice().len);
}

test "file approval constrained heights window canonical choices and disclose hidden preview" {
    const preview = diff_mod.FileChangePreview{
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
    const request: permission_request.FileApprovalRequest = .{ .kind = .edit, .intent = .mutation, .preview = preview, .scope = .workspace_files };
    const constrained = projectFileApproval(request, 0, 96, 8);
    try std.testing.expect(constrained.affirmativeEligible());
    try std.testing.expect(constrained.hidden_preview_count > 0);
    try std.testing.expect(constrained.hidden_preview_disclosed);
}

test "file approval modal fixed-width cell-grid golden preserves canonical geometry" {
    const alloc = std.testing.allocator;
    const preview = diff_mod.FileChangePreview{ .path = "note.txt", .lines = &.{}, .additions = 0, .deletions = 0, .truncated = false };
    const request: permission_request.FileApprovalRequest = .{ .kind = .edit, .intent = .mutation, .preview = preview, .scope = .workspace_files };
    var row = try composeFileApprovalScreenRow(alloc, request, .active_session, 0, 32, .header, true, false, null);
    defer row.text.deinit(alloc);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.text.items) <= 32);
}

test "file approval typed copy covers write equality and external scopes" {
    const alloc = std.testing.allocator;
    const preview = diff_mod.FileChangePreview{ .path = "…/external/private.txt", .path_basename_start = "…/external/".len, .lines = &.{.{ .op = .notice, .text = "no content changes" }}, .additions = 0, .deletions = 0, .truncated = false };
    const request: permission_request.FileApprovalRequest = .{ .kind = .write, .intent = .equality_disclosure, .preview = preview, .scope = .{ .external_tree = "…/external" } };
    var header = try composeFileApprovalScreenRow(alloc, request, .active_session, 0, 100, .header, true, false, null);
    defer header.text.deinit(alloc);
    var choice = try composeFileApprovalScreenRow(alloc, request, .active_session, 0, 100, .{ .choice = 1 }, true, false, null);
    defer choice.text.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, header.text.items, "Check") != null);
    try std.testing.expect(std.mem.find(u8, choice.text.items, "Reveal + allow") != null);
}

test "file approval keeps the amendment tail and cursor visible" {
    const alloc = std.testing.allocator;
    const preview = diff_mod.FileChangePreview{
        .path = "note.txt",
        .lines = &.{.{ .op = .addition, .new_line = 1, .text = "after" }},
        .additions = 1,
        .deletions = 0,
        .truncated = false,
    };
    const request: permission_request.FileApprovalRequest = .{
        .kind = .edit,
        .intent = .mutation,
        .preview = preview,
        .scope = .workspace_files,
    };
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "ignored",
        .file = request,
    }));
    _ = try prompt.decision.apply(alloc, .tab, prompt.request.?.amendment_allowed, null);
    try std.testing.expectEqual(
        approval_decision.InsertResult.inserted,
        try prompt.decision.insertAmendmentSlice(
            alloc,
            "BEGIN-012345678901234567890123456789-TAIL_MARKER",
            4096,
        ),
    );

    var row = try composeFileApprovalScreenRow(
        alloc,
        request,
        .active_session,
        0,
        32,
        .{ .choice = 0 },
        true,
        false,
        prompt.projection().?,
    );
    defer row.text.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, row.text.items, "TAIL_MARKER") != null);
    try std.testing.expect(std.mem.find(u8, row.text.items, "\x1b[7m ") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.text.items) <= 32);
}

test "file approval header preserves terminal-safe basename and atomic stats" {
    const alloc = std.testing.allocator;
    var encoded = try text_utils.encodeTerminalSafePathTail(alloc, "/unsafe-\x1b-wide-漢😀.txt", diff_mod.max_encoded_path_bytes);
    defer encoded.deinit(alloc);
    const preview = diff_mod.FileChangePreview{ .path = encoded.bytes, .path_basename_start = encoded.basename_start, .lines = &.{}, .additions = 12, .deletions = 345, .truncated = false };
    const request: permission_request.FileApprovalRequest = .{ .kind = .edit, .intent = .mutation, .preview = preview, .scope = .workspace_files };
    var row = try composeFileApprovalScreenRow(alloc, request, .active_session, 0, 96, .header, true, false, null);
    defer row.text.deinit(alloc);
    try std.testing.expect(std.mem.findScalar(u8, row.text.items, 0x1b) != null);
    try std.testing.expect(std.mem.find(u8, row.text.items, "+12") != null);
}

test "file approval style roles hold in light dark and blocked states" {
    const alloc = std.testing.allocator;
    defer ui_render.initTheme(false, null);
    const preview = diff_mod.FileChangePreview{ .path = "note.txt", .lines = &.{}, .additions = 0, .deletions = 0, .truncated = false };
    const request: permission_request.FileApprovalRequest = .{ .kind = .edit, .intent = .mutation, .preview = preview, .scope = .workspace_files };
    for ([_]bool{ false, true }) |light| {
        ui_render.initTheme(light, null);
        var row = try composeFileApprovalScreenRow(alloc, request, .active_session, 0, 96, .{ .choice = 0 }, false, false, null);
        defer row.text.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, row.text.items, ui_render.statusline_style) != null);
    }
}

test "file approval rows never overflow constrained width or height" {
    const alloc = std.testing.allocator;
    const preview = diff_mod.FileChangePreview{ .path = "src/profile.txt", .lines = &.{.{ .op = .addition, .new_line = 1, .text = "new" }}, .additions = 1, .deletions = 0, .truncated = false };
    const request: permission_request.FileApprovalRequest = .{ .kind = .edit, .intent = .mutation, .preview = preview, .scope = .workspace_files };
    for ([_]u16{ 1, 7, 32, 96 }) |width| {
        const projection = projectFileApproval(request, 0, width, 8);
        for (projection.slice()) |kind| {
            var row = try composeFileApprovalRow(alloc, request, &projection, 0, null, width, kind);
            defer row.deinit(alloc);
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
        }
    }
}

test "file approval projection gates basename choices preview and disclosure" {
    const preview = diff_mod.FileChangePreview{ .path = "src/profile.txt", .path_basename_start = "src/".len, .lines = &.{ .{ .op = .addition, .new_line = 1, .text = "new" }, .{ .op = .deletion, .old_line = 2, .text = "old" } }, .additions = 1, .deletions = 1, .truncated = false };
    const request: permission_request.FileApprovalRequest = .{ .kind = .edit, .intent = .mutation, .preview = preview, .scope = .workspace_files };
    try std.testing.expect(projectFileApproval(request, 0, 96, fileApprovalDesiredRows(preview)).affirmativeEligible());
    try std.testing.expect(!projectFileApproval(request, 0, 12, fileApprovalDesiredRows(preview)).affirmativeEligible());
}

test "file approval affirmative readiness requires settled committed geometry" {
    const alloc = std.testing.allocator;
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    const preview = diff_mod.FileChangePreview{ .path = "note.txt", .lines = &.{.{ .op = .addition, .new_line = 1, .text = "after" }}, .additions = 1, .deletions = 0, .truncated = false };
    try std.testing.expect(try prompt.syncRequest(alloc, .{ .id = 41, .label = "ignored", .file = .{ .kind = .edit, .intent = .mutation, .preview = preview, .scope = .workspace_files } }));
    var shell = TranscriptRuntime{ .layout = .{ .rows = 24, .cols = 96, .content_bottom = 20, .divider_top_row = 21, .input_row = 22, .divider_bottom_row = 23, .hint_row = 24 } };
    defer shell.deinit(alloc);
    try std.testing.expect(!fileApprovalAffirmativeReady(&shell, prompt.projection().?));
    shell.footer_viewport.has_frame = true;
    shell.footer_viewport.geometry = .{ .top = 1, .top_divider = 1, .input_base = 2, .bottom_divider = fileApprovalDesiredRows(preview), .hint = fileApprovalDesiredRows(preview) };
    try std.testing.expect(fileApprovalAffirmativeReady(&shell, prompt.projection().?));
}

test "approval panel renders request context and numbered choices" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{ .label = "shell.run curl -I https://example.com" }));
    var row = try composeApprovalPanelRow(std.testing.allocator, prompt.projection().?, 120, 4, interaction_state.approval_panel_rows_spacious);
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, row.items, "$ curl -I https://example.com") != null);
}

test "approval panel shows bounded terminal-safe tool arguments with ellipsis" {
    const alloc = std.testing.allocator;
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "mcp_fixture_echo",
        .tool_arguments_preview = "{\"text\":\"\x1b\n\xff sentinel\"}",
    }));

    var wide = try composeApprovalPanelRow(
        alloc,
        prompt.projection().?,
        120,
        4,
        interaction_state.approval_panel_rows_spacious,
    );
    defer wide.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        wide.items,
        "Arguments for this request: {\"text\":\"\\x1b\\x0a\\xff sentinel\"}",
    ) != null);

    const projection = prompt.projection().?;
    inline for ([_]struct { row: u16, expected: []const u8 }{
        .{ .row = 0, .expected = "MCP tool" },
        .{ .row = 2, .expected = "Allow this MCP tool call?" },
        .{ .row = 3, .expected = "This MCP tool needs approval" },
        .{ .row = 6, .expected = "Allow once" },
        .{ .row = 7, .expected = "Allow this MCP tool for this session" },
        .{ .row = 8, .expected = "Deny" },
    }) |expectation| {
        var row = try composeApprovalPanelRow(
            alloc,
            projection,
            120,
            expectation.row,
            interaction_state.approval_panel_rows_spacious,
        );
        defer row.deinit(alloc);
        try std.testing.expect(std.mem.find(u8, row.items, expectation.expected) != null);
    }

    var narrow = try composeApprovalPanelRow(
        alloc,
        prompt.projection().?,
        24,
        4,
        interaction_state.approval_panel_rows_spacious,
    );
    defer narrow.deinit(alloc);
    try std.testing.expectEqual(
        @as(usize, 24),
        display_width.visibleWidthIgnoringAnsi(narrow.items),
    );
    try std.testing.expect(std.mem.find(u8, narrow.items, "…") != null);
}

test "approval panel hint keeps enter and esc guidance at narrow widths" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{ .label = "shell.run echo hint" }));

    var wide = try composeApprovalPanelRow(std.testing.allocator, prompt.projection().?, 120, 10, interaction_state.approval_panel_rows_spacious);
    defer wide.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, wide.items, "1–3 Choose now") != null);
    try std.testing.expect(std.mem.find(u8, wide.items, "Tab Amend") != null);
    try std.testing.expect(std.mem.find(u8, wide.items, "Esc Cancel") != null);

    prompt.decision.choice_index = 1;
    var navigation = try composeApprovalPanelRow(std.testing.allocator, prompt.projection().?, 120, 10, interaction_state.approval_panel_rows_spacious);
    defer navigation.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, navigation.items, "Tab Options") != null);
    try std.testing.expect(std.mem.find(u8, navigation.items, "Tab Amend") == null);

    _ = try prompt.decision.apply(
        std.testing.allocator,
        .tab,
        prompt.request.?.amendment_allowed,
        null,
    );
    var denial = try composeApprovalPanelRow(std.testing.allocator, prompt.projection().?, 120, 10, interaction_state.approval_panel_rows_spacious);
    defer denial.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, denial.items, "Tab Amend") != null);

    var narrow = try composeApprovalPanelRow(std.testing.allocator, prompt.projection().?, 60, 10, interaction_state.approval_panel_rows_spacious);
    defer narrow.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, narrow.items, "Enter Confirm") != null);
    try std.testing.expect(std.mem.find(u8, narrow.items, "Esc Cancel") != null);
    try std.testing.expect(std.mem.find(u8, narrow.items, "Options") == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(narrow.items) <= 60);
}

test "file approval hint keeps Enter and Esc guidance at narrow widths" {
    const alloc = std.testing.allocator;
    var row = try composeFileApprovalHintRow(alloc, null, 40);
    defer row.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, row.items, "Enter Confirm") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "Esc Cancel") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "Tab Amend") == null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 40);
}

test "file approval hints follow the selected amendment capability" {
    const alloc = std.testing.allocator;
    const preview = diff_mod.FileChangePreview{ .path = "note.txt", .lines = &.{.{ .op = .addition, .new_line = 1, .text = "after" }}, .additions = 1, .deletions = 0, .truncated = false };
    const request: permission_request.FileApprovalRequest = .{ .kind = .edit, .intent = .mutation, .preview = preview, .scope = .workspace_files };
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{ .label = "edit_file note.txt", .file = request }));
    prompt.decision.choice_index = 1;

    const projection = projectFileApproval(request, prompt.decision.choice_index, 120, fileApprovalDesiredRows(preview));
    var inline_hint = try composeFileApprovalRow(alloc, request, &projection, prompt.decision.choice_index, prompt.projection().?, 120, .hint);
    defer inline_hint.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, inline_hint.items, "Tab Options") != null);
    try std.testing.expect(std.mem.find(u8, inline_hint.items, "Tab Amend") == null);

    var screen = try composeFileApprovalScreenRow(alloc, request, .active_session, prompt.decision.choice_index, 120, .hint, true, true, prompt.projection().?);
    defer screen.text.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, screen.text.items, "Tab Options") != null);
    try std.testing.expect(std.mem.find(u8, screen.text.items, "Wheel Scroll") != null);

    prompt.decision.choice_index = 2;
    var denial = try composeFileApprovalScreenRow(alloc, request, .active_session, prompt.decision.choice_index, 120, .hint, true, true, prompt.projection().?);
    defer denial.text.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, denial.text.items, "Tab Amend") != null);
}

test "scrollable file approval hint keeps the wheel notice and Esc at 80 columns" {
    const alloc = std.testing.allocator;
    const preview = diff_mod.FileChangePreview{ .path = "note.txt", .lines = &.{}, .additions = 0, .deletions = 0, .truncated = false };
    const request: permission_request.FileApprovalRequest = .{ .kind = .edit, .intent = .mutation, .preview = preview, .scope = .workspace_files };
    var row = try composeFileApprovalScreenRow(alloc, request, .active_session, 0, 80, .hint, true, true, null);
    defer row.text.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, row.text.items, "Wheel Scroll") != null);
    try std.testing.expect(std.mem.find(u8, row.text.items, "Esc Cancel") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.text.items) <= 80);
}

test "approval panel renders the shared auto-permission explanation as its reason row" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{
        .label = "shell.run git reset --hard (risk: command may discard version-control state)",
        .explanation = "Auto agent couldn’t approve because deterministic test decision",
    }));
    var reason_buf: [512]u8 = undefined;
    const reason = buildApprovalPanelLine(
        &reason_buf,
        prompt.projection().?,
        3,
        interaction_state.approval_panel_rows_spacious,
        120,
    );
    var action_buf: [512]u8 = undefined;
    const action = buildApprovalPanelLine(
        &action_buf,
        prompt.projection().?,
        4,
        interaction_state.approval_panel_rows_spacious,
        120,
    );

    try std.testing.expect(std.mem.find(u8, reason, "Auto agent couldn’t approve because deterministic test decision") != null);
    try std.testing.expect(std.mem.find(u8, reason, "Reason:") == null);
    try std.testing.expectEqualStrings("  $ git reset --hard", action);
}

test "ordinary command approval leaves the reason row blank" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{
        .label = "shell.run zig build test",
        .command = "zig build test",
    }));

    var reason_buf: [512]u8 = undefined;
    const reason = buildApprovalPanelLine(
        &reason_buf,
        prompt.projection().?,
        3,
        interaction_state.approval_panel_rows_spacious,
        120,
    );

    try std.testing.expectEqualStrings("", reason);
}

test "inline command panel wraps the complete target before its controls" {
    const alloc = std.testing.allocator;
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "shell.run printf 'INLINE_COMMAND_START " ++ "x" ** 55 ++ " INLINE_COMMAND_END'",
    }));

    const request = prompt.request.?.view();
    const row_count = try inlineApprovalPanelRows(alloc, request.label, 32, 24);
    try std.testing.expect(row_count > interaction_state.approval_panel_rows_compact);

    var panel: std.ArrayList(u8) = .empty;
    defer panel.deinit(alloc);
    var row_index: u16 = 0;
    while (row_index < row_count) : (row_index += 1) {
        var row = try composeInlineApprovalPanelRow(
            alloc,
            prompt.projection().?,
            32,
            24,
            row_index,
        );
        defer row.deinit(alloc);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 32);
        try panel.appendSlice(alloc, row.items);
        try panel.append(alloc, '\n');
    }

    try std.testing.expect(std.mem.find(u8, panel.items, "INLINE_COMMAND_START") != null);
    try std.testing.expect(std.mem.find(u8, panel.items, "INLINE_COMMAND_END") != null);
    try std.testing.expect(std.mem.find(u8, panel.items, interaction_state.approval_once_label) != null);
    try std.testing.expect(std.mem.find(u8, panel.items, "Enter Confirm") == null);
    try std.testing.expect(std.mem.find(u8, panel.items, "Esc Cancel") == null);
}

test "inline command panel uses full command when label is bounded" {
    const alloc = std.testing.allocator;
    const command = "printf 'INLINE_FULL_COMMAND_START_" ++ ("x" ** 80) ++ "_INLINE_FULL_COMMAND_END'";
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "shell.run printf 'INLINE_FULL_COMMAND_START...",
        .command = command,
    }));

    const request = prompt.request.?.view();
    const clipped_rows = try inlineApprovalPanelRows(alloc, request.label, 80, 24);
    const full_rows = try inlineApprovalPanelRowsForCommand(alloc, request.label, request.command, 80, 24);
    try std.testing.expect(full_rows > clipped_rows);

    var panel: std.ArrayList(u8) = .empty;
    defer panel.deinit(alloc);
    var row_index: u16 = 0;
    while (row_index < full_rows) : (row_index += 1) {
        var row = try composeInlineApprovalPanelRow(
            alloc,
            prompt.projection().?,
            80,
            24,
            row_index,
        );
        defer row.deinit(alloc);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 80);
        try panel.appendSlice(alloc, row.items);
        try panel.append(alloc, '\n');
    }

    try std.testing.expect(std.mem.find(u8, panel.items, "INLINE_FULL_COMMAND_START") != null);
    try std.testing.expect(std.mem.find(u8, panel.items, "INLINE_FULL_COMMAND_END") != null);
}

test "inline command panel preserves hard newlines from the raw command" {
    const alloc = std.testing.allocator;
    const command = "cat <<'EOF'\nline one\nEOF";

    var projection = (try projectInlineCommand(
        alloc,
        "shell.run cat <<'EOF'...",
        command,
        120,
    )).?;
    defer projection.deinit(alloc);

    try std.testing.expectEqual(@as(u16, 3), projection.rows);
    try std.testing.expectEqualStrings(
        "cat <<'EOF'",
        (try inlineCommandSegment(projection.encoded.bytes, 120, 0)).?,
    );
    try std.testing.expectEqualStrings(
        "line one",
        (try inlineCommandSegment(projection.encoded.bytes, 120, 1)).?,
    );
    try std.testing.expectEqualStrings(
        "EOF",
        (try inlineCommandSegment(projection.encoded.bytes, 120, 2)).?,
    );
    try std.testing.expect(std.mem.find(u8, projection.encoded.bytes, "\\x0a") == null);
}

test "approval command projection keeps literal escapes and encodes controls" {
    var projection = try projectCommandText(
        std.testing.allocator,
        "printf '\\x0a'\nprintf '\x1b[31m'\r",
    );
    defer projection.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(
        "printf '\\x0a'\nprintf '\\x1b[31m'\\x0d",
        projection.bytes,
    );
}

test "command segments retain empty hard lines" {
    var segments = CommandSegmentIterator.initContentWidth("one\n\nthree\n", 80);

    try std.testing.expectEqualStrings("one", (try segments.next()).?);
    try std.testing.expectEqualStrings("", (try segments.next()).?);
    try std.testing.expectEqualStrings("three", (try segments.next()).?);
    try std.testing.expectEqualStrings("", (try segments.next()).?);
    try std.testing.expect((try segments.next()) == null);
}

test "inline command panel wraps commands at word boundaries" {
    const command = "curl --header alpha --header bravo";

    try std.testing.expectEqualStrings(
        "curl --header alpha",
        (try inlineCommandSegment(command, 28, 0)).?,
    );
    try std.testing.expectEqualStrings(
        "--header bravo",
        (try inlineCommandSegment(command, 28, 1)).?,
    );
    try std.testing.expect((try inlineCommandSegment(command, 28, 2)) == null);
}

test "inline command panel never truncates the complete command" {
    const alloc = std.testing.allocator;
    const command = "printf 'INLINE_UNBOUNDED_COMMAND_START_" ++
        ("x" ** (diff_mod.max_request_projection_bytes + 64)) ++
        "_INLINE_UNBOUNDED_COMMAND_END'";
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "shell.run printf 'INLINE_UNBOUNDED_COMMAND_START...",
        .command = command,
    }));

    const request = prompt.request.?.view();
    const row_count = try inlineApprovalPanelRowsForCommand(
        alloc,
        request.label,
        request.command,
        4096,
        40,
    );

    var panel: std.ArrayList(u8) = .empty;
    defer panel.deinit(alloc);
    var row_index: u16 = 0;
    while (row_index < row_count) : (row_index += 1) {
        var row = try composeInlineApprovalPanelRow(
            alloc,
            prompt.projection().?,
            4096,
            40,
            row_index,
        );
        defer row.deinit(alloc);
        try panel.appendSlice(alloc, row.items);
        try panel.append(alloc, '\n');
    }

    try std.testing.expect(std.mem.find(
        u8,
        panel.items,
        "INLINE_UNBOUNDED_COMMAND_END",
    ) != null);
}

test "approval panel renders typed amendment in the selected choice row" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);

    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{
        .label = "shell.run printf done",
    }));
    _ = try prompt.decision.apply(
        std.testing.allocator,
        .tab,
        prompt.request.?.amendment_allowed,
        null,
    );
    for ("summarize it") |byte| {
        _ = try prompt.decision.apply(
            std.testing.allocator,
            .{ .insert_ascii = byte },
            prompt.request.?.amendment_allowed,
            null,
        );
    }

    var row = try composeApprovalPanelRow(
        std.testing.allocator,
        prompt.projection().?,
        120,
        6,
        interaction_state.approval_panel_rows_spacious,
    );
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, row.items, "1. Yes, summarize it") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 120);
}

test "approval panel keeps the amendment tail and cursor visible" {
    const alloc = std.testing.allocator;
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);

    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "shell.run printf done",
    }));
    _ = try prompt.decision.apply(alloc, .tab, prompt.request.?.amendment_allowed, null);
    try std.testing.expectEqual(
        approval_decision.InsertResult.inserted,
        try prompt.decision.insertAmendmentSlice(
            alloc,
            "BEGIN-012345678901234567890123456789-TAIL_MARKER",
            4096,
        ),
    );

    var row = try composeApprovalPanelRow(
        alloc,
        prompt.projection().?,
        32,
        6,
        interaction_state.approval_panel_rows_spacious,
    );
    defer row.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, row.items, "TAIL_MARKER") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b[7m ") != null);
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= 32);
}

test "approval amendment window follows the cursor by display units" {
    const exact = approvalDraftWindow("abc", 1, 3);
    try std.testing.expectEqualStrings("a", exact.before);
    try std.testing.expectEqualStrings("b", exact.cursor_unit);
    try std.testing.expectEqualStrings("c", exact.after);
    try std.testing.expect(exact.cursor_visible);

    const at_end = approvalDraftWindow("abc", 3, 3);
    try std.testing.expectEqualStrings("bc", at_end.before);
    try std.testing.expectEqualStrings("", at_end.cursor_unit);
    try std.testing.expectEqualStrings("", at_end.after);

    const at_start = approvalDraftWindow("abcdef", 0, 3);
    try std.testing.expectEqualStrings("", at_start.before);
    try std.testing.expectEqualStrings("a", at_start.cursor_unit);
    try std.testing.expectEqualStrings("bc", at_start.after);

    const in_middle = approvalDraftWindow("abcdef", 3, 3);
    try std.testing.expectEqualStrings("bc", in_middle.before);
    try std.testing.expectEqualStrings("d", in_middle.cursor_unit);
    try std.testing.expectEqualStrings("", in_middle.after);

    const unicode = approvalDraftWindow("ab漢cd", 2, 3);
    try std.testing.expectEqualStrings("b", unicode.before);
    try std.testing.expectEqualStrings("漢", unicode.cursor_unit);
    try std.testing.expectEqualStrings("", unicode.after);

    const tiny = approvalDraftWindow("ab漢cd", 2, 1);
    try std.testing.expectEqualStrings("", tiny.before);
    try std.testing.expectEqualStrings("", tiny.cursor_unit);
    try std.testing.expectEqualStrings("", tiny.after);
    try std.testing.expect(tiny.cursor_visible);

    const hidden = approvalDraftWindow("abc", 1, 0);
    try std.testing.expect(!hidden.cursor_visible);
}

test "approval panel amendment starts with a dim placeholder and cursor" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{
        .label = "shell.run printf done",
    }));
    _ = try prompt.decision.apply(
        std.testing.allocator,
        .tab,
        prompt.request.?.amendment_allowed,
        null,
    );

    var row = try composeApprovalPanelRow(
        std.testing.allocator,
        prompt.projection().?,
        120,
        6,
        interaction_state.approval_panel_rows_spacious,
    );
    defer row.deinit(std.testing.allocator);

    const cursor_start = std.mem.indexOf(u8, row.items, "\x1b[7ma") orelse return error.TestExpectedEqual;
    const placeholder_remainder = std.mem.indexOf(u8, row.items, "nd tell fx what to do next") orelse return error.TestExpectedEqual;
    try std.testing.expect(cursor_start < placeholder_remainder);
    try std.testing.expect(std.mem.find(u8, row.items, ui_render.statusline_style) != null);
}

test "approval panel encodes terminal controls in generic labels" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{ .label = "shell.run curl https://example.com\x1b[31m\n(risk: external)" }));
    var row = try composeApprovalPanelRow(std.testing.allocator, prompt.projection().?, 120, 4, interaction_state.approval_panel_rows_spacious);
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.find(u8, row.items, "\\x1b[31m") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "\x1b[31m") == null);
}

test "approval panel target row is single-line for heredoc command labels" {
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expect(try prompt.syncRequest(std.testing.allocator, .{ .label = "shell.run cat > ~/Desktop/hello-world.html <<'EOF'\n<!doctype html>\nEOF" }));
    var row = try composeApprovalPanelRow(std.testing.allocator, prompt.projection().?, 200, 4, interaction_state.approval_panel_rows_spacious);
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.findScalar(u8, row.items, '\n') == null);
    try std.testing.expect(std.mem.find(u8, row.items, "cat > ~/Desktop/hello-world.html") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "EOF") != null);
}

test "inline command rows account for terminal-safe escape width" {
    const alloc = std.testing.allocator;
    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(alloc);
    try label.appendSlice(alloc, "shell.run ");
    try label.appendNTimes(alloc, 'x', 75);
    try label.append(alloc, '\n');

    try std.testing.expectEqual(
        interaction_state.approval_panel_rows_compact,
        try inlineApprovalPanelRows(alloc, label.items, 80, 12),
    );
}

test "approval panel preserves a command beyond the fixed row buffer" {
    const alloc = std.testing.allocator;
    var label: std.ArrayList(u8) = .empty;
    defer label.deinit(alloc);
    try label.appendSlice(alloc, "shell.run printf '%s' 'LONG_COMMAND_APPROVAL_START");
    try label.appendNTimes(alloc, 'x', row_text.max_top_row_len + 64);
    try label.appendSlice(alloc, "LONG_COMMAND_APPROVAL_END'");

    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{ .label = label.items }));
    var row = try composeApprovalPanelRow(
        alloc,
        prompt.projection().?,
        2048,
        4,
        interaction_state.approval_panel_rows_spacious,
    );
    defer row.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, row.items, "LONG_COMMAND_APPROVAL_START") != null);
    try std.testing.expect(std.mem.find(u8, row.items, "LONG_COMMAND_APPROVAL_END") != null);
}

test "generic approval uses compact permission header and pointer marker" {
    const alloc = std.testing.allocator;
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "shell.run zig build test",
    }));

    var header = try composeApprovalPanelRow(
        alloc,
        prompt.projection().?,
        80,
        0,
        interaction_state.approval_panel_rows_spacious,
    );
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        header.items,
        "Permission needed · Choose one",
    ) != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Command") != null);

    var choice = try composeApprovalPanelRow(
        alloc,
        prompt.projection().?,
        80,
        6,
        interaction_state.approval_panel_rows_spacious,
    );
    defer choice.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, choice.items, "❯ ") != null);
    try std.testing.expect(std.mem.find(u8, choice.items, "1. Yes") != null);
    try std.testing.expect(std.mem.find(u8, choice.items, "›") == null);
}

test "subagent approval header identifies requester and preserves command kind" {
    const alloc = std.testing.allocator;
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "shell.run touch child-marker",
        .origin = .{ .subagent = "approval-child" },
    }));

    var header = try composeApprovalPanelRow(
        alloc,
        prompt.projection().?,
        120,
        0,
        interaction_state.approval_panel_rows_spacious,
    );
    defer header.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        header.items,
        "Subagent approval-child needs permission",
    ) != null);
    try std.testing.expect(std.mem.find(u8, header.items, "Command") != null);

    var target = try composeApprovalPanelRow(
        alloc,
        prompt.projection().?,
        120,
        4,
        interaction_state.approval_panel_rows_spacious,
    );
    defer target.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        target.items,
        "$ touch child-marker",
    ) != null);
}

test "file approval uses compact review header path question and pointer marker" {
    const alloc = std.testing.allocator;
    const preview = diff_mod.FileChangePreview{
        .path = "src/ui/footer/approval_ui.zig",
        .lines = &.{
            .{ .op = .deletion, .old_line = 1, .text = "old" },
            .{ .op = .addition, .new_line = 1, .text = "new" },
        },
        .additions = 1,
        .deletions = 1,
        .truncated = false,
    };
    const request: permission_request.FileApprovalRequest = .{
        .kind = .edit,
        .intent = .mutation,
        .preview = preview,
        .scope = .workspace_files,
    };

    var header = try composeFileApprovalScreenRow(
        alloc,
        request,
        .active_session,
        0,
        96,
        .header,
        true,
        true,
        null,
    );
    defer header.text.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        header.text.items,
        "Permission needed · Review change",
    ) != null);
    try std.testing.expect(std.mem.find(u8, header.text.items, "Edit") != null);
    try std.testing.expect(std.mem.find(u8, header.text.items, "+1") != null);
    try std.testing.expect(std.mem.find(u8, header.text.items, "-1") != null);

    var child_header = try composeFileApprovalScreenRow(
        alloc,
        request,
        .{ .subagent = "approval-child" },
        0,
        96,
        .header,
        true,
        true,
        null,
    );
    defer child_header.text.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        child_header.text.items,
        "Subagent approval-child needs permission",
    ) != null);
    try std.testing.expect(
        std.mem.find(u8, child_header.text.items, "Edit") != null,
    );

    var question = try composeFileApprovalScreenRow(
        alloc,
        request,
        .active_session,
        0,
        96,
        .question,
        true,
        true,
        null,
    );
    defer question.text.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        question.text.items,
        "src/ui/footer/approval_ui.zig",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        question.text.items,
        "Apply this change?",
    ) != null);

    var choice = try composeFileApprovalScreenRow(
        alloc,
        request,
        .active_session,
        0,
        96,
        .{ .choice = 0 },
        true,
        true,
        null,
    );
    defer choice.text.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, choice.text.items, "❯ ") != null);
    try std.testing.expect(std.mem.find(
        u8,
        choice.text.items,
        "1  Apply once",
    ) != null);
    try std.testing.expect(std.mem.find(u8, choice.text.items, "›") == null);
}

test "permission hints use compact ask modal language" {
    const alloc = std.testing.allocator;
    var prompt = ApprovalPrompt{};
    defer prompt.deinit(alloc);
    try std.testing.expect(try prompt.syncRequest(alloc, .{
        .label = "shell.run zig build test",
    }));

    var generic = try composeApprovalPanelRow(
        alloc,
        prompt.projection().?,
        120,
        10,
        interaction_state.approval_panel_rows_spacious,
    );
    defer generic.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        generic.items,
        "1–3 Choose now",
    ) != null);
    try std.testing.expect(std.mem.find(u8, generic.items, "Tab Amend") != null);
    try std.testing.expect(std.mem.find(
        u8,
        generic.items,
        "Enter Confirm",
    ) != null);
    try std.testing.expect(std.mem.find(u8, generic.items, "Esc Cancel") != null);

    const preview = diff_mod.FileChangePreview{
        .path = "note.txt",
        .lines = &.{},
        .additions = 0,
        .deletions = 0,
        .truncated = false,
    };
    const request: permission_request.FileApprovalRequest = .{
        .kind = .edit,
        .intent = .mutation,
        .preview = preview,
        .scope = .workspace_files,
    };
    var file = try composeFileApprovalScreenRow(
        alloc,
        request,
        .active_session,
        0,
        120,
        .hint,
        true,
        true,
        prompt.projection().?,
    );
    defer file.text.deinit(alloc);
    try std.testing.expect(std.mem.find(
        u8,
        file.text.items,
        "1–3 Choose now",
    ) != null);
    try std.testing.expect(std.mem.find(u8, file.text.items, "Wheel Scroll") != null);
    try std.testing.expect(std.mem.find(u8, file.text.items, "Tab Amend") != null);
}
