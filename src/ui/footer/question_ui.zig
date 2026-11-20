const std = @import("std");
const question_prompt = @import("../../core/agent/question_prompt.zig");
const display_width = @import("../../core/shared/display_width.zig");
const shared_theme = @import("../../core/shared/theme.zig");
const types = @import("../../core/shared/types.zig");
const ui_render = @import("../render.zig");
const render_engine = @import("../render_engine.zig");
const question_freeform_layout = @import("question_freeform_layout.zig");

const markdown_document = render_engine.markdown_document;

const Allocator = std.mem.Allocator;

/// Rows the footer spends around the question panel: the gap above it, both
/// dividers, and the hint row. One more row stays with the transcript.
const panel_chrome_rows: u16 = 5;

/// Fewest panel rows a short terminal still gets: one question row, a gap,
/// and the selected option between two scroll markers.
const min_panel_rows: u16 = 5;

/// Most rows the question panel may take in a terminal of `terminal_rows`, so
/// its dividers and hint row stay on screen.
pub fn questionPanelRowBudget(terminal_rows: u16, banner_rows: u16) u16 {
    return @max(terminal_rows -| panel_chrome_rows -| banner_rows, min_panel_rows);
}

pub fn questionPanelRowsForLayout(
    alloc: Allocator,
    projection: question_prompt.Projection,
    cols: u16,
    max_rows: u16,
) !u16 {
    const entry = projection.current_entry orelse return 1;
    const question = try composeQuestionRows(alloc, entry, cols);
    defer alloc.free(question);
    var options = try OptionRows.init(alloc, entry, cols);
    defer options.deinit(alloc);
    return @min(questionPanelRowCount(rowCount(question), options.total), @max(max_rows, 1));
}

/// Rows of the whole panel: the question, a blank row, the options, and a
/// blank row.
fn questionPanelRowCount(question_rows: usize, option_rows: usize) u16 {
    return @intCast(@min(2 +| question_rows +| option_rows, std.math.maxInt(u16)));
}

/// Every option's rows as they are drawn, each ended by a line break.
const OptionRows = struct {
    text: []u8,
    /// The first row of each option.
    starts: []usize,
    total: usize,

    fn init(alloc: Allocator, entry: question_prompt.EntryProjection, row_budget: usize) !OptionRows {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        const starts = try alloc.alloc(usize, entry.options.len);
        errdefer alloc.free(starts);

        var counted: usize = 0;
        var total: usize = 0;
        for (entry.options, starts, 0..) |opt, *start, index| {
            start.* = total;
            try writeQuestionPanelOptionLine(alloc, &out.writer, entry, opt, index, row_budget);
            total += std.mem.countScalar(u8, out.written()[counted..], '\n');
            counted = out.written().len;
        }
        return .{ .text = try out.toOwnedSlice(), .starts = starts, .total = total };
    }

    fn deinit(self: *OptionRows, alloc: Allocator) void {
        alloc.free(self.text);
        alloc.free(self.starts);
    }
};

pub fn nextPanelLine(text: []const u8, start: *usize) []const u8 {
    if (start.* >= text.len) return "";
    var line_end = start.*;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
    const line = text[start.*..line_end];
    start.* = if (line_end < text.len) line_end + 1 else text.len;
    return line;
}

/// Composes the panel as newline-terminated rows. A panel taller than
/// `max_rows` shows a window of its options that follows the selection.
/// The caller owns the returned slice.
pub fn composeQuestionPanelText(
    alloc: Allocator,
    projection: question_prompt.Projection,
    cols: u16,
    max_rows: u16,
) ![]u8 {
    const row_budget: usize = cols;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const entry = projection.current_entry orelse {
        try out.writer.writeByte('\n');
        return out.toOwnedSlice();
    };

    const question = try composeQuestionRows(alloc, entry, cols);
    defer alloc.free(question);
    const question_rows = rowCount(question);
    var options = try OptionRows.init(alloc, entry, row_budget);
    defer options.deinit(alloc);

    if (questionPanelRowCount(question_rows, options.total) > max_rows) {
        try writeWindowedQuestionPanel(alloc, &out.writer, entry, question, options, row_budget, max_rows);
        return out.toOwnedSlice();
    }

    // The question is its own header; batch progress lives in the hint row.
    try writeQuestionRows(&out.writer, question, question_rows, row_budget);
    try out.writer.writeByte('\n');
    try out.writer.writeAll(options.text);
    try out.writer.writeByte('\n');

    return out.toOwnedSlice();
}

/// Rows in text that `composeQuestionRows` returned.
fn rowCount(rows: []const u8) usize {
    return std.mem.countScalar(u8, rows, '\n') + 1;
}

/// The question as finished rows no wider than `cols`, joined by line
/// breaks; there is always one row. Plain text, and a Markdown question of
/// one line, is the panel's heading: bold, wrapped under a two-column indent.
/// A Markdown question of several lines shows as the transcript shows a
/// reply, so its lists, code, and tables keep their shape. The caller owns
/// the returned slice.
fn composeQuestionRows(
    alloc: Allocator,
    entry: question_prompt.EntryProjection,
    cols: u16,
) ![]u8 {
    if (entry.question_markdown) {
        const rendered = try markdown_document.renderRows(alloc, entry.question, cols, markdownStyles());
        if (rendered.len > 0 and std.mem.findScalar(u8, entry.question, '\n') != null) return rendered;
        defer alloc.free(rendered);
        if (rendered.len > 0) return composeHeadingRows(alloc, rendered);
        // Markdown that draws nothing, such as a footnote nothing refers
        // to, shows as it was written.
    }
    return composePlainQuestionRows(alloc, entry.question, cols);
}

/// Styles for Markdown shown outside the transcript, in the active theme.
fn markdownStyles() render_engine.transcript_blocks.Styles {
    return .{
        .reset_style = ui_render.reset_style,
        .dim_style = ui_render.dim_style,
        .code_highlight_theme = if (ui_render.is_light) .light else .dark,
    };
}

fn composePlainQuestionRows(alloc: Allocator, question: []const u8, cols: u16) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const content_width = questionTextWidth(cols);
    var start: usize = 0;
    var first = true;
    while (first or start < question.len) {
        const line = if (question.len == 0)
            WrappedTextLine{ .content_end = 0, .next_start = 0 }
        else
            nextWrappedTextLine(question, start, content_width);
        if (!first) try out.writer.writeByte('\n');
        try out.writer.writeAll("  ");
        try out.writer.writeAll(ui_render.bold_style);
        try out.writer.writeAll(question[start..line.content_end]);
        try out.writer.writeAll(ui_render.reset_style);
        if (question.len == 0) break;
        first = false;
        start = line.next_start;
    }
    return out.toOwnedSlice();
}

/// Makes rendered Markdown rows bold from end to end.
fn composeHeadingRows(alloc: Allocator, rendered: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var rows = std.mem.splitScalar(u8, rendered, '\n');
    var first = true;
    while (rows.next()) |row| {
        if (!first) try out.writer.writeByte('\n');
        first = false;
        try writeRowOnBaseStyle(&out.writer, row, ui_render.bold_style, .bold);
    }
    return out.toOwnedSlice();
}

/// What a base style sets, and so which sequences take it away.
const BaseStyle = enum {
    bold,
    foreground,

    fn endParameter(self: BaseStyle) []const u8 {
        return switch (self) {
            .bold => "22",
            .foreground => "39",
        };
    }
};

/// Writes a rendered Markdown row on top of `base`, then resets. The
/// Markdown's own styles stay, and `base` comes back after each sequence
/// that ends it, so plain text between styled words keeps the base style.
fn writeRowOnBaseStyle(
    writer: *std.Io.Writer,
    row: []const u8,
    base: []const u8,
    kind: BaseStyle,
) !void {
    try writer.writeAll(base);
    var index: usize = 0;
    while (index < row.len) {
        if (row[index] != 0x1b) {
            const next = std.mem.findScalarPos(u8, row, index, 0x1b) orelse row.len;
            try writer.writeAll(row[index..next]);
            index = next;
            continue;
        }
        const end = display_width.ansiSequenceEnd(row, index);
        try writer.writeAll(row[index..end]);
        if (sgrEnds(row[index..end], kind)) try writer.writeAll(base);
        index = end;
    }
    try writer.writeAll(ui_render.reset_style);
}

/// True when the escape sequence is an SGR that turns off what `kind` sets:
/// a reset, or the parameter that ends it.
fn sgrEnds(sequence: []const u8, kind: BaseStyle) bool {
    return shared_theme.sgrHasParam(sequence, "") or
        shared_theme.sgrHasParam(sequence, "0") or
        shared_theme.sgrHasParam(sequence, kind.endParameter());
}

/// Writes the first `shown` rows of `question`, each ended by a line break.
/// When rows are left out, the last row written ends with an ellipsis.
fn writeQuestionRows(
    writer: *std.Io.Writer,
    question: []const u8,
    shown: usize,
    row_budget: usize,
) !void {
    const truncated = shown < rowCount(question);
    var rows = std.mem.splitScalar(u8, question, '\n');
    var written: usize = 0;
    while (written < shown) : (written += 1) {
        const row = rows.next() orelse break;
        if (truncated and written + 1 == shown) {
            try writeRowWithEllipsis(writer, row, row_budget);
        } else {
            try writer.writeAll(row);
        }
        try writer.writeByte('\n');
    }
}

const hyperlink_open = "\x1b]8;";
const hyperlink_close = "\x1b]8;;\x1b\\";

/// Writes `row` cut to leave one column for an ellipsis, in the style the
/// row has at the cut. Spaces before the cut are dropped.
fn writeRowWithEllipsis(writer: *std.Io.Writer, row: []const u8, row_budget: usize) !void {
    const width = row_budget -| 1;
    var visible: usize = 0;
    var cut: usize = 0;
    var text_end: usize = 0;
    while (cut < row.len) {
        if (row[cut] == 0x1b) {
            cut = display_width.ansiSequenceEnd(row, cut);
            continue;
        }
        const unit = display_width.displayUnitAt(row, cut);
        if (unit.byte_len == 0 or visible + unit.cell_width > width) break;
        visible += unit.cell_width;
        cut += unit.byte_len;
        if (row[cut - unit.byte_len] != ' ') text_end = cut;
    }

    if (text_end == 0) {
        // On a blank row the ellipsis stands at the question's indent.
        try writer.writeAll("  ");
    } else {
        try writer.writeAll(row[0..text_end]);
    }
    // The sequences up to the cut still apply; the spaces between them go.
    var index = text_end;
    while (index < cut) {
        if (row[index] == 0x1b) {
            const end = display_width.ansiSequenceEnd(row, index);
            try writer.writeAll(row[index..end]);
            index = end;
        } else {
            index += 1;
        }
    }
    try writer.writeAll("…");
    try writer.writeAll(ui_render.reset_style);
    if (std.mem.find(u8, row, hyperlink_open) != null) try writer.writeAll(hyperlink_close);
}

/// Draws the cursor cell of a typed answer. The windowed panel finds the
/// cursor row by it.
const reverse_style = "\x1b[7m";

const OptionWindow = struct {
    /// First visible option row.
    top: usize,
    /// Option rows shown, not counting the scroll markers.
    len: usize,
};

/// Picks the option rows to show when `total` rows must fit in `rows`. The
/// window stays at the top while the focused rows `focus_start..focus_end` fit
/// there; otherwise the focus sits at its bottom. `option_starts` holds each
/// option's first row, so the window opens on a whole option when it can.
fn solveOptionWindow(
    total: usize,
    rows: usize,
    focus_start: usize,
    focus_end: usize,
    option_starts: []const usize,
) OptionWindow {
    std.debug.assert(total > rows and rows >= 3);
    // One row goes to each scroll marker the window needs.
    if (focus_end <= rows - 1) return .{ .top = 0, .len = rows - 1 };

    var top = focus_end - (rows - 2);
    if (top > focus_start) {
        top = focus_start;
    } else for (option_starts) |start| {
        if (start < top) continue;
        if (start <= focus_start) top = start;
        break;
    }
    if (top + rows - 1 >= total) return .{ .top = total - (rows - 1), .len = rows - 1 };
    return .{ .top = top, .len = if (top == 0) rows - 1 else rows - 2 };
}

fn writeWindowedQuestionPanel(
    alloc: Allocator,
    writer: *std.Io.Writer,
    entry: question_prompt.EntryProjection,
    question: []const u8,
    options: OptionRows,
    row_budget: usize,
    max_rows: usize,
) !void {
    const option_starts = options.starts;
    const total = options.total;
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    try lines.ensureTotalCapacity(alloc, total);
    var line_start: usize = 0;
    while (line_start < options.text.len) {
        lines.appendAssumeCapacity(nextPanelLine(options.text, &line_start));
    }

    // The options keep at least three rows, the selected one between two
    // scroll markers; the question takes what is left, and the gap under it
    // stays only when a row is spare.
    const question_lines = rowCount(question);
    const min_body: usize = @min(total, 3);
    const question_shown = @min(question_lines, @max(max_rows -| (min_body + 1), 1));
    const gap: usize = @intFromBool(max_rows -| question_shown > min_body);
    const body_rows = max_rows -| question_shown -| gap;

    try writeQuestionRows(writer, question, question_shown, row_budget);
    if (gap > 0) try writer.writeByte('\n');

    if (total <= body_rows or body_rows < 3) {
        for (lines.items[0..@min(total, body_rows)]) |line| {
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
        return;
    }

    const selected = @min(entry.choice_index, entry.options.len - 1);
    var focus_start = option_starts[selected];
    var focus_end = if (selected + 1 < option_starts.len) option_starts[selected + 1] else total;
    if (entry.options[selected].is_freeform_slot) {
        // A long draft keeps its cursor row in view.
        for (lines.items[focus_start..focus_end], focus_start..) |line, row| {
            if (std.mem.find(u8, line, reverse_style) == null) continue;
            focus_start = row;
            focus_end = row + 1;
            break;
        }
    }

    const window = solveOptionWindow(total, body_rows, focus_start, focus_end, option_starts);
    const window_end = window.top + window.len;
    // Each marker counts the options whose first row, the one with the
    // label, is outside the window.
    var above: usize = 0;
    var below: usize = 0;
    for (option_starts) |start| {
        above += @intFromBool(start < window.top);
        below += @intFromBool(start >= window_end);
    }
    if (window.top > 0) try writeScrollMarker(writer, "↑", above);
    for (lines.items[window.top..window_end]) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
    if (window_end < total) try writeScrollMarker(writer, "↓", below);
}

/// A dim row that stands for the option rows scrolled out of the window.
/// `count` is 0 when only the rest of a visible option is hidden.
fn writeScrollMarker(writer: *std.Io.Writer, arrow: []const u8, count: usize) !void {
    try writer.writeAll(ui_render.dim_style);
    try writer.writeAll(question_freeform_layout.option_row_indent);
    if (count > 0) {
        try writer.print("{s} {d} more", .{ arrow, count });
    } else {
        try writer.print("{s} more", .{arrow});
    }
    try writer.writeAll(ui_render.reset_style);
    try writer.writeByte('\n');
}

fn questionTextWidth(row_budget: usize) usize {
    return @max(row_budget -| 2, 1);
}

fn writeQuestionPanelOptionLine(
    alloc: Allocator,
    writer: *std.Io.Writer,
    entry: question_prompt.EntryProjection,
    opt: question_prompt.OwnedQuestionOption,
    index: usize,
    row_budget: usize,
) !void {
    const selected = index == entry.choice_index;
    // No caret: selection reads purely from the white-vs-gray contrast.
    const option_style = if (selected) ui_render.selected_completion_style else ui_render.dim_style;

    var ordinal_buf: [16]u8 = undefined;
    const ordinal = std.mem.print(&ordinal_buf, "{d}) ", .{index + 1}) catch "";
    const prefix_width = question_freeform_layout.optionPrefixWidth(index);

    if (selected and opt.is_freeform_slot) {
        try writeSelectedFreeformOptionLines(writer, entry, ordinal, prefix_width, row_budget);
        return;
    }

    const label = questionOptionLabel(entry, opt);
    const description = opt.description orelse "";
    const has_description = description.len > 0;
    const description_col = if (has_description) questionDescriptionColumn(row_budget) else 0;
    const widths = questionOptionLabelWidths(index, row_budget, has_description);

    // The description sits in its own column beside the label, or under the
    // label when the terminal is too narrow for two columns.
    const description_width = @max(row_budget -| (if (description_col > 0) description_col else prefix_width), 1);
    const description_rows = if (has_description)
        try composeDescriptionRows(alloc, description, entry.question_markdown, description_width)
    else
        "";
    defer if (has_description) alloc.free(description_rows);
    var descriptions = std.mem.splitScalar(u8, description_rows, '\n');
    var description_row: ?[]const u8 = if (has_description) descriptions.next() else null;

    if (description_col > 0) {
        const description_indent = description_col - 1;
        var label_start: usize = 0;
        var row_index: usize = 0;
        while (row_index == 0 or label_start < label.len or description_row != null) : (row_index += 1) {
            const label_available = row_index == 0 or label_start < label.len;
            const label_line = if (!label_available or label.len == 0)
                WrappedTextLine{ .content_end = label_start, .next_start = label_start }
            else
                nextWrappedTextLine(label, label_start, if (row_index == 0) widths.first else widths.continuation);

            if (row_index == 0) {
                try writer.writeAll(option_style);
                try writer.writeAll(question_freeform_layout.option_row_indent);
                try writer.writeAll(ordinal);
            } else {
                try writer.splatByteAll(' ', prefix_width);
                try writer.writeAll(option_style);
            }
            if (label_available) try writer.writeAll(label[label_start..label_line.content_end]);
            try writer.writeAll(ui_render.reset_style);

            if (description_row) |row| {
                const visible = prefix_width + if (label_available)
                    display_width.visibleWidth(label[label_start..label_line.content_end])
                else
                    0;
                if (visible < description_indent) {
                    try writer.splatByteAll(' ', description_indent - visible);
                } else {
                    try writer.writeByte(' ');
                }
                try writer.writeAll(row);
                description_row = descriptions.next();
            }
            try writer.writeByte('\n');

            if (label_available) label_start = label_line.next_start;
        }
        return;
    }

    var start: usize = 0;
    var first = true;
    while (first or start < label.len) {
        const line = if (label.len == 0)
            WrappedTextLine{ .content_end = 0, .next_start = 0 }
        else
            nextWrappedTextLine(label, start, if (first) widths.first else widths.continuation);

        if (first) {
            try writer.writeAll(option_style);
            try writer.writeAll(question_freeform_layout.option_row_indent);
            try writer.writeAll(ordinal);
        } else {
            try writer.splatByteAll(' ', prefix_width);
            try writer.writeAll(option_style);
        }
        try writer.writeAll(label[start..line.content_end]);
        try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');
        if (label.len == 0) break;
        first = false;
        start = line.next_start;
    }

    while (description_row) |row| : (description_row = descriptions.next()) {
        try writer.splatByteAll(' ', prefix_width);
        try writer.writeAll(row);
        try writer.writeByte('\n');
    }
}

/// A description as finished rows no wider than `width`, joined by line
/// breaks, in the dim style; there is always one row. Markdown shows as the
/// transcript shows it, without blank rows, so an option's rows stay
/// together; plain text wraps at word boundaries. The caller owns the
/// returned slice.
fn composeDescriptionRows(
    alloc: Allocator,
    description: []const u8,
    markdown: bool,
    width: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    // Rendered rows start after the transcript's gutter, which the
    // description's own indent takes the place of.
    const gutter: usize = 2;
    const render_cols = std.math.cast(u16, width + gutter);
    if (markdown and render_cols != null and markdown_document.gutterWidth(render_cols.?) == gutter) {
        const rendered = try markdown_document.renderRows(alloc, description, render_cols.?, markdownStyles());
        defer alloc.free(rendered);
        var rows = std.mem.splitScalar(u8, rendered, '\n');
        while (rows.next()) |row| {
            if (markdown_document.isBlankRow(row)) continue;
            if (out.written().len > 0) try out.writer.writeByte('\n');
            const text = if (std.mem.startsWith(u8, row, "  ")) row[gutter..] else row;
            try writeRowOnBaseStyle(&out.writer, text, ui_render.dim_style, .foreground);
        }
        if (out.written().len > 0) return out.toOwnedSlice();
        // Markdown that draws nothing shows as it was written.
    }

    var start: usize = 0;
    while (start < description.len) {
        const line = nextWrappedTextLine(description, start, width);
        if (start > 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(ui_render.dim_style);
        try out.writer.writeAll(description[start..line.content_end]);
        try out.writer.writeAll(ui_render.reset_style);
        start = line.next_start;
    }
    return out.toOwnedSlice();
}

fn questionOptionLabel(
    entry: question_prompt.EntryProjection,
    opt: question_prompt.OwnedQuestionOption,
) []const u8 {
    if (!opt.is_freeform_slot) return opt.label;
    return if (entry.freeform_buffer.len == 0)
        opt.label
    else
        entry.freeform_buffer;
}

const QuestionOptionLabelWidths = struct {
    first: usize,
    continuation: usize,
};

fn questionOptionLabelWidths(
    index: usize,
    row_budget: usize,
    has_description: bool,
) QuestionOptionLabelWidths {
    const prefix_width = question_freeform_layout.optionPrefixWidth(index);
    const description_col = if (has_description) questionDescriptionColumn(row_budget) else 0;
    const label_end = if (description_col > prefix_width + 2) description_col - 2 else row_budget;
    const first = @max(label_end -| prefix_width, 1);
    return .{
        .first = first,
        .continuation = if (description_col > 0)
            first
        else
            @max(row_budget -| prefix_width, 1),
    };
}

const WrappedTextLine = struct {
    content_end: usize,
    next_start: usize,
};

fn nextWrappedTextLine(text: []const u8, start: usize, content_width: usize) WrappedTextLine {
    if (start >= text.len) return .{ .content_end = text.len, .next_start = text.len };

    const newline = std.mem.findScalar(u8, text[start..], '\n');
    const segment_end = if (newline) |relative| start + relative else text.len;
    const segment = text[start..segment_end];
    const prefix = display_width.wrapCutIgnoringAnsi(segment, content_width);
    if (prefix.len < segment.len) {
        if (prefix.len > 0) {
            const content_end = start + prefix.len;
            var next_start = content_end;
            while (next_start < segment_end and
                (text[next_start] == ' ' or text[next_start] == '\t'))
            {
                next_start += 1;
            }
            return .{ .content_end = content_end, .next_start = next_start };
        }

        const unit = display_width.displayUnitAt(text, start);
        const end = @min(start + unit.byte_len, segment_end);
        return .{ .content_end = end, .next_start = end };
    }

    return .{
        .content_end = segment_end,
        .next_start = if (segment_end < text.len) segment_end + 1 else segment_end,
    };
}

fn writeSelectedFreeformOptionLines(
    writer: *std.Io.Writer,
    entry: question_prompt.EntryProjection,
    ordinal: []const u8,
    prefix_width: usize,
    row_budget: usize,
) !void {
    const reverse = reverse_style;
    const buffer = entry.freeform_buffer;
    const cursor = question_freeform_layout.normalizedCursor(buffer, entry.freeform_cursor);
    const content_width = question_freeform_layout.contentWidth(entry.choice_index, row_budget);

    if (buffer.len == 0) {
        try writer.writeAll(ui_render.selected_completion_style);
        try writer.writeAll(question_freeform_layout.option_row_indent);
        try writer.writeAll(ordinal);
        try writer.writeAll(ui_render.reset_style);
        try writer.writeAll(reverse);
        try writer.writeByte(' ');
        try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');
        return;
    }

    var start: usize = 0;
    var first = true;
    var last_width: usize = 0;
    var trailing_hard_break = false;
    while (start < buffer.len) {
        const line = question_freeform_layout.nextLine(buffer, start, content_width);
        const end = line.content_end;
        last_width = display_width.visibleWidth(buffer[start..end]);
        trailing_hard_break = line.hard_break and line.next_start == buffer.len;

        if (first) {
            try writer.writeAll(ui_render.selected_completion_style);
            try writer.writeAll(question_freeform_layout.option_row_indent);
            try writer.writeAll(ordinal);
        } else {
            try writer.splatByteAll(' ', prefix_width);
            try writer.writeAll(ui_render.selected_completion_style);
        }

        if (cursor >= start and cursor < end) {
            try writer.writeAll(buffer[start..cursor]);
            try writer.writeAll(ui_render.reset_style);
            try writer.writeAll(reverse);
            const cursor_unit = display_width.displayUnitAt(buffer, cursor);
            const cursor_end = @min(cursor + cursor_unit.byte_len, end);
            try writer.writeAll(buffer[cursor..cursor_end]);
            try writer.writeAll(ui_render.reset_style);
            if (cursor_end < end) {
                try writer.writeAll(ui_render.selected_completion_style);
                try writer.writeAll(buffer[cursor_end..end]);
            }
        } else {
            try writer.writeAll(buffer[start..end]);
        }

        if (cursor == end and line.hard_break) {
            try writer.writeAll(ui_render.reset_style);
            try writer.writeAll(reverse);
            try writer.writeByte(' ');
        } else if (line.next_start == buffer.len and !line.hard_break and cursor == buffer.len and last_width < content_width) {
            try writer.writeAll(ui_render.reset_style);
            try writer.writeAll(reverse);
            try writer.writeByte(' ');
        }
        try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');

        first = false;
        start = line.next_start;
    }

    if (trailing_hard_break or (cursor == buffer.len and last_width == content_width)) {
        try writer.splatByteAll(' ', prefix_width);
        try writer.writeAll(reverse);
        try writer.writeByte(' ');
        try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');
    }
}

fn questionDescriptionColumn(row_budget: usize) usize {
    if (row_budget >= 72) return 38;
    if (row_budget >= 52) return 30;
    return 0;
}

/// Terminal block rendered after an entire question batch resolves.
/// All answered → each entry's question wraps under its batch ordinal with
/// the muted answer hanging beneath. Cancelled → single `▪ Cancelled\n`.
pub fn composeQuestionResolutions(
    alloc: Allocator,
    prompt: *const question_prompt.QuestionPrompt,
    cancelled: bool,
    cols: u16,
) ![]u8 {
    if (cancelled) {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try writeCancelledResolution(&out.writer);
        return out.toOwnedSlice();
    }

    var answers: std.ArrayList(types.QuestionAnswer) = .empty;
    defer answers.deinit(alloc);
    try answers.ensureTotalCapacity(alloc, prompt.entries.items.len);
    for (prompt.entries.items) |entry| {
        answers.appendAssumeCapacity(.{
            .question = entry.question,
            .answer = entry.answer orelse "",
        });
    }

    return composeResolvedQuestionAnswers(alloc, answers.items, cols);
}

/// Terminal block rendered after a completed question batch resolves.
/// The answer pairs are borrowed and must outlive this call.
pub fn composeResolvedQuestionAnswers(
    alloc: Allocator,
    answers: []const types.QuestionAnswer,
    cols: u16,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    for (answers, 0..) |answer, index| {
        try writeQuestionAnswerResolution(alloc, &out.writer, answer.question, answer.answer, index + 1, cols);
    }

    return out.toOwnedSlice();
}

fn writeQuestionAnswerResolution(
    alloc: Allocator,
    writer: *std.Io.Writer,
    question: []const u8,
    answer: []const u8,
    number: usize,
    cols: u16,
) !void {
    // The question is numbered by its position in the batch; the muted
    // answer hangs beneath, aligned under the question text. Pure
    // typography, so the block never reads as a tool group.
    var prefix_buf: [16]u8 = undefined;
    const question_prefix = std.mem.print(&prefix_buf, "  {d}) ", .{number}) catch "  ";
    var indent_buf: [16]u8 = undefined;
    const indent = blk: {
        const width = @min(display_width.visibleWidth(question_prefix), indent_buf.len);
        @memset(indent_buf[0..width], ' ');
        break :blk indent_buf[0..width];
    };
    if (!try writeResolutionMarkdown(alloc, writer, question_prefix, indent, question, cols)) {
        try writeResolutionField(writer, question_prefix, indent, question, cols, null);
    }
    try writeResolutionField(writer, indent, indent, answer, cols, ui_render.statusline_style);
}

/// Writes the question as Markdown, as the prompt showed it, with its rows
/// hanging under the first text column. Returns false, with nothing written,
/// when the Markdown draws nothing or the terminal is too narrow for it.
fn writeResolutionMarkdown(
    alloc: Allocator,
    writer: *std.Io.Writer,
    first_prefix: []const u8,
    indent: []const u8,
    question: []const u8,
    cols: u16,
) !bool {
    // Rendered rows start after the transcript's gutter, which the ordinal
    // prefix takes the place of.
    const gutter: usize = 2;
    if (indent.len < gutter or cols < indent.len + 4) return false;
    const render_cols: u16 = @intCast(cols - (indent.len - gutter));
    if (markdown_document.gutterWidth(render_cols) != gutter) return false;

    const rendered = try markdown_document.renderRows(alloc, question, render_cols, markdownStyles());
    defer alloc.free(rendered);
    if (rendered.len == 0) return false;

    var rows = std.mem.splitScalar(u8, rendered, '\n');
    var first = true;
    while (rows.next()) |row| {
        if (!markdown_document.isBlankRow(row)) {
            try writer.writeAll(if (first) first_prefix else indent);
            try writer.writeAll(if (std.mem.startsWith(u8, row, "  ")) row[gutter..] else row);
        }
        try writer.writeByte('\n');
        first = false;
    }
    return true;
}

// Wraps like the main transcript: soft wrap at word boundaries inside each
// hard line, with continuation rows hanging under the field's first text
// column. Long fields never trail off with an ellipsis.
fn writeResolutionField(
    writer: *std.Io.Writer,
    first_prefix: []const u8,
    continuation_prefix: []const u8,
    text: []const u8,
    cols: u16,
    style: ?[]const u8,
) !void {
    var start: usize = 0;
    var first = true;
    while (first or start < text.len) {
        const prefix = if (first) first_prefix else continuation_prefix;
        const budget = @as(usize, cols) -| display_width.visibleWidth(prefix);
        const line = nextWrappedTextLine(text, start, budget);

        if (style) |row_style| try writer.writeAll(row_style);
        try writer.writeAll(prefix);
        try writer.writeAll(text[start..line.content_end]);
        if (style != null) try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');

        if (text.len == 0) break;
        first = false;
        start = line.next_start;
    }
}

fn writeCancelledResolution(writer: *std.Io.Writer) !void {
    try writer.writeAll(ui_render.red_style);
    try writer.writeAll("▪");
    try writer.writeAll(ui_render.reset_style);
    try writer.writeAll(" Cancelled");
    try writer.writeByte('\n');
}

const unbounded_rows = std.math.maxInt(u16);

test "question footer composes prompt inside decision panel" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = "go ahead" },
        .{ .label = "No", .description = null },
        .{ .label = "Maybe", .description = "decide later" },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Should we proceed?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 80, unbounded_rows);
    defer std.testing.allocator.free(text);

    const question_hint = "Use numbers, Up/Down, or tab to choose, enter to confirm, esc to cancel";
    try std.testing.expect(std.mem.find(u8, text, "Should we proceed?") != null);
    try std.testing.expect(std.mem.find(u8, text, "Yes") != null);
    try std.testing.expect(std.mem.find(u8, text, "go ahead") != null);
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next();
    try std.testing.expect(display_width.visibleWidthIgnoringAnsi(lines.next().?) == 0);
    try std.testing.expect(std.mem.find(u8, text, question_hint) == null);
}

test "long question text wraps into measured continuation rows" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Run tests", .description = null },
        .{ .label = "Skip tests", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{
            .question = "Which verification steps should run before this branch is pushed?",
            .options = &options,
        },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    const width: u16 = 42;
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width, unbounded_rows);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "Which verification steps should run") != null);
    try expectVisibleIndentBefore(text, "before this branch is pushed?", 2);
    try std.testing.expect(std.mem.find(u8, text, "Which verification steps should run…") == null);
    try expectQuestionPanelRowsMatch(&prompt, width);
}

test "question footer clips composed rows to solved footer band" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Inspect repository state", .description = "Look around the workspace and report back" },
        .{ .label = "Run unit tests", .description = "Execute zig build test" },
        .{ .label = "Build binary", .description = "Execute zig build" },
        .{ .label = "Review branch", .description = "Check the local diff" },
        .{ .label = "Ship branch", .description = "Push and open a PR" },
        .{ .label = "Something else", .description = "Use freeform input" },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "What should happen first?", .options = &options },
        .{ .question = "What should happen second?", .options = &options },
        .{ .question = "What should happen third?", .options = &options },
        .{ .question = "What should happen fourth?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 80, unbounded_rows);
    defer std.testing.allocator.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 80);
    }
}

test "compose question panel renders only the current paginated entry" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "One", .description = null },
        .{ .label = "Two", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Q0?", .options = &options },
        .{ .question = "Q1?", .options = &options },
        .{ .question = "Q2?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    _ = try prompt.apply(std.testing.allocator, .submit);
    try std.testing.expectEqual(@as(u8, 1), prompt.current_index);

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 60, unbounded_rows);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "Question 2 of 3") == null);
    try std.testing.expect(std.mem.find(u8, text, "Input needed") == null);
    try std.testing.expect(std.mem.find(u8, text, "Q0?") == null);
    try std.testing.expect(std.mem.find(u8, text, "Q1?") != null);
    try std.testing.expect(std.mem.find(u8, text, "Q2?") == null);
    // No caret: the selected option is the one carrying the white style.
    try std.testing.expect(std.mem.find(u8, text, "❯") == null);
    try std.testing.expect(std.mem.find(u8, text, "[✓]") == null);
    var sel_buf: [64]u8 = undefined;
    const selected_one = try std.mem.print(&sel_buf, "{s}    1) One", .{ui_render.selected_completion_style});
    try std.testing.expect(std.mem.find(u8, text, selected_one) != null);
    var unsel_buf: [64]u8 = undefined;
    const unselected_two = try std.mem.print(&unsel_buf, "{s}    2) Two", .{ui_render.dim_style});
    try std.testing.expect(std.mem.find(u8, text, unselected_two) != null);
}

const tall_test_description =
    "The relay follows each session and passes its events on, so every pane keeps updating while the app is closed.";

fn syncTallTestQuestion(prompt: *question_prompt.QuestionPrompt, question: []const u8) !void {
    const options = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = tall_test_description },
        .{ .label = "Bravo", .description = tall_test_description },
        .{ .label = "Charlie", .description = tall_test_description },
        .{ .label = "Delta", .description = tall_test_description },
        .{ .label = "Echo", .description = tall_test_description },
        .{ .label = "Foxtrot", .description = tall_test_description },
    };
    const entries = [_]types.QuestionBatchEntry{.{ .question = question, .options = &options }};
    try prompt.syncFrom(std.testing.allocator, &entries);
}

fn expectPanelRows(text: []const u8, width: u16, rows: u16) !void {
    var line_start: usize = 0;
    var serialized: u16 = 0;
    while (line_start < text.len) : (serialized += 1) {
        const line = nextPanelLine(text, &line_start);
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
    }
    try std.testing.expectEqual(rows, serialized);
}

test "tall question panel fits its row budget and follows the selection" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTallTestQuestion(&prompt, "Who should relay events?");

    const labels = [_][]const u8{ "1) Alpha", "2) Bravo", "3) Charlie", "4) Delta", "5) Echo", "6) Foxtrot", "7) " };
    for ([_]u16{ 40, 60, 90 }) |width| {
        for ([_]u16{ 5, 6, 9, 14 }) |max_rows| {
            for (labels, 0..) |label, index| {
                const projection = prompt.projection().?;
                try std.testing.expectEqual(index, projection.current_entry.?.choice_index);
                const text = try composeQuestionPanelText(std.testing.allocator, projection, width, max_rows);
                defer std.testing.allocator.free(text);

                try std.testing.expectEqual(max_rows, try questionPanelRowsForLayout(std.testing.allocator, projection, width, max_rows));
                try expectPanelRows(text, width, max_rows);
                try std.testing.expect(std.mem.find(u8, text, "Who should relay events?") != null);
                try std.testing.expect(std.mem.find(u8, text, label) != null);
                // A marker stands in for every option the window leaves out.
                const has_above = std.mem.find(u8, text, "↑ ") != null;
                const has_below = std.mem.find(u8, text, "↓ ") != null;
                try std.testing.expect(has_above or std.mem.find(u8, text, labels[0]) != null);
                try std.testing.expect(has_below or std.mem.find(u8, text, labels[labels.len - 1]) != null);
                if (index == 0) try std.testing.expect(!has_above);
                if (index + 1 == labels.len) try std.testing.expect(!has_below);
                prompt.moveChoice(1);
            }
        }
    }
}

test "tall question panel counts the options outside its window" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTallTestQuestion(&prompt, "Who should relay events?");
    prompt.moveChoice(3);

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 90, 9);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "↑ 3 more") != null);
    try std.testing.expect(std.mem.find(u8, text, "4) Delta") != null);
    try std.testing.expect(std.mem.find(u8, text, "5) Echo") != null);
    try std.testing.expect(std.mem.find(u8, text, "↓ 2 more") != null);
    try std.testing.expect(std.mem.find(u8, text, "3) Charlie") == null);
    try std.testing.expect(std.mem.find(u8, text, "6) Foxtrot") == null);
}

test "tall question panel shortens a long question before it hides the options" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTallTestQuestion(
        &prompt,
        "Who should relay events to the chat panes when the app is closed and the user comes back later to a long thread that has many unread events?",
    );

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 40, 6);
    defer std.testing.allocator.free(text);
    try expectPanelRows(text, 40, 6);
    try std.testing.expect(std.mem.find(u8, text, "Who should relay events") != null);
    try std.testing.expect(std.mem.find(u8, text, "…") != null);
    try std.testing.expect(std.mem.find(u8, text, "unread events?") == null);
    try std.testing.expect(std.mem.find(u8, text, "1) Alpha") != null);
}

test "tall question panel keeps the cursor row of a long typed answer in view" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncTallTestQuestion(&prompt, "Who should relay events?");
    prompt.moveChoice(-1);
    for (0..12) |_| {
        for ("typed answer row ") |byte| _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = byte });
    }
    for ("FINISHED") |byte| _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = byte });

    const projection = prompt.projection().?;
    const text = try composeQuestionPanelText(std.testing.allocator, projection, 40, 6);
    defer std.testing.allocator.free(text);
    try expectPanelRows(text, 40, 6);
    try std.testing.expect(std.mem.find(u8, text, "FINISHED") != null);
    try std.testing.expect(std.mem.find(u8, text, reverse_style) != null);

    for (0..12 * 17 + 8) |_| _ = try prompt.apply(std.testing.allocator, .{ .edit_freeform = .cursor_left });
    const home = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 40, 6);
    defer std.testing.allocator.free(home);
    try expectPanelRows(home, 40, 6);
    try std.testing.expect(std.mem.find(u8, home, "7) ") != null);
    try std.testing.expect(std.mem.find(u8, home, reverse_style) != null);
    try std.testing.expect(std.mem.find(u8, home, "FINISHED") == null);
}

test "question panel row budget leaves the footer chrome on screen" {
    try std.testing.expectEqual(@as(u16, 35), questionPanelRowBudget(40, 0));
    try std.testing.expectEqual(@as(u16, 9), questionPanelRowBudget(14, 0));
    try std.testing.expectEqual(@as(u16, 7), questionPanelRowBudget(14, 2));
    try std.testing.expectEqual(min_panel_rows, questionPanelRowBudget(6, 0));
    try std.testing.expectEqual(min_panel_rows, questionPanelRowBudget(0, 0));
}

const markdown_test_question =
    "The migration can run in **two** ways:\n" ++
    "\n" ++
    "- `online`: no downtime, about two hours of slow writes\n" ++
    "- `offline`: ten minutes of downtime\n" ++
    "\n" ++
    "```sh\n" ++
    "fx migrate --mode online\n" ++
    "```\n" ++
    "\n" ++
    "Which one do you want?";

fn syncMarkdownTestQuestion(prompt: *question_prompt.QuestionPrompt, question: []const u8) !void {
    const options = [_]types.QuestionOption{
        .{ .label = "Online", .description = "No downtime." },
        .{ .label = "Offline", .description = "Ten minutes of downtime." },
    };
    const entries = [_]types.QuestionBatchEntry{.{ .question = question, .markdown = true, .options = &options }};
    try prompt.syncFrom(std.testing.allocator, &entries);
}

test "markdown question of several lines shows as the transcript shows a reply" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncMarkdownTestQuestion(&prompt, markdown_test_question);

    for ([_]u16{ 24, 44, 72, 120 }) |width| {
        const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width, unbounded_rows);
        defer std.testing.allocator.free(text);

        var line_start: usize = 0;
        var serialized: u16 = 0;
        while (line_start < text.len) : (serialized += 1) {
            const line = nextPanelLine(text, &line_start);
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
        }
        try std.testing.expectEqual(
            serialized,
            try questionPanelRowsForLayout(std.testing.allocator, prompt.projection().?, width, unbounded_rows),
        );

        // The first line is body text, not a bold heading, and its emphasis shows.
        try std.testing.expect(std.mem.startsWith(u8, text, "  The migration can run"));
        try std.testing.expect(std.mem.find(u8, text, "\x1b[1mtwo\x1b[22m") != null);
        inline for (.{ "• ", "online", "offline", "fx", "migrate", "─ sh ─" }) |shown| {
            try std.testing.expect(std.mem.find(u8, text, shown) != null);
        }
        inline for (.{ "**", "`", "\n- " }) |syntax| {
            try std.testing.expect(std.mem.find(u8, text, syntax) == null);
        }

        // The options follow the question after one blank row.
        const question_end = std.mem.find(u8, text, "want?").?;
        const first_option = std.mem.find(u8, text, "1) Online").?;
        try std.testing.expect(question_end < first_option);
        try std.testing.expectEqual(@as(usize, 2), std.mem.countScalar(u8, text[question_end..first_option], '\n'));
    }
}

test "markdown question of one line stays the bold heading with its inline styles" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncMarkdownTestQuestion(
        &prompt,
        "Should the build use `pnpm` or **npm** for the workspace install step in every package?",
    );

    const width: u16 = 40;
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width, unbounded_rows);
    defer std.testing.allocator.free(text);
    try expectQuestionPanelRowsMatch(&prompt, width);

    var line_start: usize = 0;
    var question_rows: usize = 0;
    while (line_start < text.len) {
        const line = nextPanelLine(text, &line_start);
        if (line.len == 0) break;
        question_rows += 1;
        try std.testing.expect(std.mem.startsWith(u8, line, ui_render.bold_style ++ "  "));
        try std.testing.expect(std.mem.endsWith(u8, line, ui_render.reset_style));
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
    }
    try std.testing.expect(question_rows >= 3);
    try std.testing.expect(std.mem.find(u8, text, "pnpm") != null);
    try std.testing.expect(std.mem.find(u8, text, "`") == null);
    try std.testing.expect(std.mem.find(u8, text, "**") == null);
    // Bold comes back after the emphasis closes it.
    try std.testing.expect(std.mem.find(u8, text, "npm\x1b[22m" ++ ui_render.bold_style) != null);
}

test "plain question text is never read as markdown" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    const options = [_]types.QuestionOption{
        .{ .label = "Accept", .description = null },
        .{ .label = "Decline", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Server asks for **token** in `field_name`", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 80, unbounded_rows);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(
        u8,
        text,
        "  " ++ ui_render.bold_style ++ "Server asks for **token** in `field_name`" ++ ui_render.reset_style ++ "\n",
    ));
}

test "markdown question that draws nothing shows as it was written" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncMarkdownTestQuestion(&prompt, "[^note]: unused");

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 60, unbounded_rows);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "  " ++ ui_render.bold_style ++ "[^note]: unused" ++ ui_render.reset_style ++ "\n"));
    try expectQuestionPanelRowsMatch(&prompt, 60);
}

test "tall markdown question gives up rows before the options do" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncMarkdownTestQuestion(&prompt, markdown_test_question);
    prompt.moveChoice(1);

    const width: u16 = 60;
    const full = try questionPanelRowsForLayout(std.testing.allocator, prompt.projection().?, width, unbounded_rows);
    for ([_]u16{ 5, 8, 12 }) |max_rows| {
        try std.testing.expect(full > max_rows);
        const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width, max_rows);
        defer std.testing.allocator.free(text);
        try expectPanelRows(text, width, max_rows);
        try std.testing.expectEqual(max_rows, try questionPanelRowsForLayout(std.testing.allocator, prompt.projection().?, width, max_rows));

        try std.testing.expect(std.mem.startsWith(u8, text, "  The migration can run"));
        try std.testing.expect(std.mem.find(u8, text, "…") != null);
        try std.testing.expect(std.mem.find(u8, text, "Which one do you want?") == null);
        try std.testing.expect(std.mem.find(u8, text, "2) Offline") != null);
    }
}

test "a cut question row closes its link and keeps its indent" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeRowWithEllipsis(&out.writer, "  See \x1b]8;id=fx-1;https://fx.sh\x1b\\\x1b[4mthe long docs page\x1b[24m\x1b]8;;\x1b\\", 12);
    try std.testing.expectEqualStrings(
        "  See \x1b]8;id=fx-1;https://fx.sh\x1b\\\x1b[4mthe l…" ++ ui_render.reset_style ++ hyperlink_close,
        out.written(),
    );

    out.clearRetainingCapacity();
    try writeRowWithEllipsis(&out.writer, "  short   ", 40);
    try std.testing.expectEqualStrings("  short…" ++ ui_render.reset_style, out.written());

    out.clearRetainingCapacity();
    try writeRowWithEllipsis(&out.writer, "", 40);
    try std.testing.expectEqualStrings("  …" ++ ui_render.reset_style, out.written());

    out.clearRetainingCapacity();
    try writeRowWithEllipsis(&out.writer, "    ", 40);
    try std.testing.expectEqualStrings("  …" ++ ui_render.reset_style, out.written());
}

test "a base style comes back only after a sequence that ends it" {
    inline for (.{ "\x1b[m", "\x1b[0m", "\x1b[22m", "\x1b[1;22m", "\x1b[22;39m", "\x1b[0;38;5;245m" }) |sequence| {
        try std.testing.expect(sgrEnds(sequence, .bold));
    }
    inline for (.{
        "\x1b[1m",
        "\x1b[39m",
        "\x1b[24m",
        "\x1b[38;5;22m",
        "\x1b[48;5;0m",
        "\x1b[38;2;22;0;22m",
        "\x1b[38:5:22m",
        "\x1b]8;;\x1b\\",
        "\x1b[2K",
    }) |sequence| {
        try std.testing.expect(!sgrEnds(sequence, .bold));
    }

    inline for (.{ "\x1b[m", "\x1b[0m", "\x1b[39m", "\x1b[22;39m", "\x1b[39;49m" }) |sequence| {
        try std.testing.expect(sgrEnds(sequence, .foreground));
    }
    inline for (.{ "\x1b[22m", "\x1b[24m", "\x1b[49m", "\x1b[38;5;39m", "\x1b[38;2;39;39;39m", "\x1b[4m" }) |sequence| {
        try std.testing.expect(!sgrEnds(sequence, .foreground));
    }
}

fn syncMarkdownDescriptionQuestion(prompt: *question_prompt.QuestionPrompt, markdown: bool) !void {
    const options = [_]types.QuestionOption{
        .{ .label = "pnpm", .description = "Uses `pnpm install --frozen-lockfile`.\n**Fastest** in CI, see [docs](https://fx.sh/docs)." },
        .{ .label = "npm", .description = "Steps:\n- run `npm ci`\n- no new tool" },
    };
    const entries = [_]types.QuestionBatchEntry{.{
        .question = "Which package manager?",
        .markdown = markdown,
        .options = &options,
    }};
    try prompt.syncFrom(std.testing.allocator, &entries);
}

test "markdown descriptions render in their column on the dim base style" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncMarkdownDescriptionQuestion(&prompt, true);

    // Two columns at 96 and 60, the description under the label at 40.
    for ([_]u16{ 96, 60, 40 }) |width| {
        const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width, unbounded_rows);
        defer std.testing.allocator.free(text);
        try expectQuestionPanelRowsMatch(&prompt, width);

        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(std.testing.allocator);
        try appendWithoutAnsi(&plain, text);
        inline for (.{ "`", "**", "](", "\n- ", "- run" }) |syntax| {
            try std.testing.expect(std.mem.find(u8, plain.items, syntax) == null);
        }
        inline for (.{ "Fastest", "docs", "• run npm ci", "• no new tool", "Steps:" }) |shown| {
            try std.testing.expect(std.mem.find(u8, plain.items, shown) != null);
        }

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
        }

        // Emphasis shows, and the grey base returns after each styled word.
        const bold_then_dim = try std.testing.allocator.print("\x1b[1mFastest\x1b[22m in CI", .{});
        defer std.testing.allocator.free(bold_then_dim);
        try std.testing.expect(std.mem.find(u8, text, bold_then_dim) != null);
        const code_then_dim = try std.testing.allocator.print("\x1b[39m{s}", .{ui_render.dim_style});
        defer std.testing.allocator.free(code_then_dim);
        try std.testing.expect(std.mem.find(u8, text, code_then_dim) != null);
        const dim_start = try std.testing.allocator.print("{s}Uses ", .{ui_render.dim_style});
        defer std.testing.allocator.free(dim_start);
        try std.testing.expect(std.mem.find(u8, text, dim_start) != null);
    }

    // In two columns, each description row starts in the description column.
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 96, unbounded_rows);
    defer std.testing.allocator.free(text);
    const column = questionDescriptionColumn(96) - 1;
    try expectVisibleIndentBefore(text, "Uses ", column);
    try expectVisibleIndentBefore(text, "Fastest", column);
    try expectVisibleIndentBefore(text, "Steps:", column);
    try expectVisibleIndentBefore(text, "• ", column);
}

test "plain descriptions stay as written" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncMarkdownDescriptionQuestion(&prompt, false);

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 96, unbounded_rows);
    defer std.testing.allocator.free(text);
    try expectQuestionPanelRowsMatch(&prompt, 96);
    inline for (.{ "Uses `pnpm install --frozen-lockfile`.", "**Fastest** in CI, see [docs](https://fx.sh/docs).", "- run `npm ci`" }) |literal| {
        try std.testing.expect(std.mem.find(u8, text, literal) != null);
    }
}

test "tall markdown descriptions scroll with the selection in a short panel" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    try syncMarkdownDescriptionQuestion(&prompt, true);

    const width: u16 = 40;
    for ([_][]const u8{ "1) pnpm", "2) npm", "3) " }) |label| {
        const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width, 6);
        defer std.testing.allocator.free(text);
        try expectPanelRows(text, width, 6);
        try std.testing.expectEqual(@as(u16, 6), try questionPanelRowsForLayout(std.testing.allocator, prompt.projection().?, width, 6));
        try std.testing.expect(std.mem.find(u8, text, label) != null);
        prompt.moveChoice(1);
    }
}

test "resolved markdown question keeps its shape under the ordinal" {
    const answers = [_]types.QuestionAnswer{
        .{ .question = markdown_test_question, .answer = "Online" },
        .{ .question = "Push `main` after the checks **pass**?", .answer = "Yes" },
    };
    for ([_]u16{ 30, 60, 100 }) |cols| {
        const text = try composeResolvedQuestionAnswers(std.testing.allocator, &answers, cols);
        defer std.testing.allocator.free(text);

        try std.testing.expect(std.mem.startsWith(u8, text, "  1) The migration can run"));
        try std.testing.expect(std.mem.find(u8, text, "\n  2) Push ") != null);
        inline for (.{ "**", "`", "\n     - " }) |syntax| {
            try std.testing.expect(std.mem.find(u8, text, syntax) == null);
        }
        inline for (.{ "     \x1b[2m• \x1b[22m", "─ sh ─", "migrate", "\x1b[1mpass\x1b[22m" }) |shown| {
            try std.testing.expect(std.mem.find(u8, text, shown) != null);
        }
        // Each answer hangs under the last row of its question.
        const first_answer = try std.testing.allocator.print("want?\n{s}     Online", .{ui_render.statusline_style});
        defer std.testing.allocator.free(first_answer);
        try std.testing.expect(std.mem.find(u8, text, first_answer) != null);
        const last_answer = try std.testing.allocator.print("{s}     Yes{s}\n", .{ ui_render.statusline_style, ui_render.reset_style });
        defer std.testing.allocator.free(last_answer);
        try std.testing.expect(std.mem.endsWith(u8, text, last_answer));

        var rows: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| : (rows += 1) {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
            if (line.len == 0) continue;
            var plain: std.ArrayList(u8) = .empty;
            defer plain.deinit(std.testing.allocator);
            try appendWithoutAnsi(&plain, line);
            const numbered = std.mem.startsWith(u8, plain.items, "  1) ") or std.mem.startsWith(u8, plain.items, "  2) ");
            try std.testing.expect(numbered or std.mem.startsWith(u8, plain.items, "     "));
        }
    }
}

test "resolved question falls back to plain text when markdown cannot fit" {
    const answers = [_]types.QuestionAnswer{.{ .question = "Use **bold**?", .answer = "Yes" }};
    const text = try composeResolvedQuestionAnswers(std.testing.allocator, &answers, 8);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "  1) Use"));
    try std.testing.expect(std.mem.find(u8, text, "**") != null);
}

test "question panel row measurement matches serialized panel rows" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "One", .description = null },
        .{ .label = "Two", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Q0?", .options = &options },
        .{ .question = "Q1?", .options = &options },
        .{ .question = "Q2?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);
    try expectQuestionPanelRowsMatch(&prompt, 50);

    _ = try prompt.apply(std.testing.allocator, .submit);
    try expectQuestionPanelRowsMatch(&prompt, 50);

    prompt.moveChoice(-1);
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'x' });
    try expectQuestionPanelRowsMatch(&prompt, 16);

    _ = try prompt.apply(std.testing.allocator, .submit);
    _ = try prompt.apply(std.testing.allocator, .submit);
    try expectQuestionPanelRowsMatch(&prompt, 50);
}

fn expectQuestionPanelRowsMatch(
    prompt: *const question_prompt.QuestionPrompt,
    width: u16,
) !void {
    const projection = prompt.projection().?;
    const text = try composeQuestionPanelText(std.testing.allocator, projection, width, unbounded_rows);
    defer std.testing.allocator.free(text);

    var line_start: usize = 0;
    var serialized_rows: u16 = 0;
    while (line_start < text.len) {
        _ = nextPanelLine(text, &line_start);
        serialized_rows += 1;
    }

    const measured_rows = try questionPanelRowsForLayout(std.testing.allocator, projection, width, unbounded_rows);
    try std.testing.expectEqual(serialized_rows, measured_rows);
}

test "compose question resolutions emits answered summary block" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
        .{ .label = "Beta", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Q0?", .options = &options },
        .{ .question = "Q1?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    _ = try prompt.apply(std.testing.allocator, .submit);
    prompt.moveChoice(1);
    _ = try prompt.apply(std.testing.allocator, .submit);

    const text = try composeQuestionResolutions(std.testing.allocator, &prompt, false, 60);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.startsWith(u8, text, "  1) Q0?\n"));
    try std.testing.expect(std.mem.find(u8, text, "     Alpha") != null);
    try std.testing.expect(std.mem.find(u8, text, "\n  2) Q1?\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "     Beta") != null);
    try std.testing.expect(std.mem.find(u8, text, "User answered") == null);

    const cancelled_text = try composeQuestionResolutions(std.testing.allocator, &prompt, true, 60);
    defer std.testing.allocator.free(cancelled_text);
    const expected_cancelled = try std.testing.allocator.print(
        "{s}▪{s} Cancelled\n",
        .{ ui_render.red_style, ui_render.reset_style },
    );
    defer std.testing.allocator.free(expected_cancelled);
    try std.testing.expectEqualStrings(expected_cancelled, cancelled_text);
}

test "resolved question answers use the live resolution layout at every width" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Thorough", .description = null },
        .{ .label = "Fast", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Which verification depth should I use?", .options = &options },
        .{ .question = "Should I ship it?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);
    _ = try prompt.apply(std.testing.allocator, .submit);
    _ = try prompt.apply(std.testing.allocator, .submit);

    const answers = [_]types.QuestionAnswer{
        .{ .question = "Which verification depth should I use?", .answer = "Thorough" },
        .{ .question = "Should I ship it?", .answer = "Thorough" },
    };
    for ([_]u16{ 60, 12 }) |cols| {
        const live = try composeQuestionResolutions(std.testing.allocator, &prompt, false, cols);
        defer std.testing.allocator.free(live);
        const replay = try composeResolvedQuestionAnswers(std.testing.allocator, &answers, cols);
        defer std.testing.allocator.free(replay);
        try std.testing.expectEqualStrings(live, replay);
    }
}

test "resolved multiline question fields keep every row inside the transcript rail" {
    const answers = [_]types.QuestionAnswer{.{
        .question = "Choose one\ncarefully",
        .answer = "line-one\nline-two\nline-three",
    }};
    const text = try composeResolvedQuestionAnswers(std.testing.allocator, &answers, 60);
    defer std.testing.allocator.free(text);

    const expected = try std.testing.allocator.print(
        "  1) Choose one\n" ++
            "     carefully\n" ++
            "{s}     line-one{s}\n" ++
            "{s}     line-two{s}\n" ++
            "{s}     line-three{s}\n",
        .{
            ui_render.statusline_style, ui_render.reset_style,
            ui_render.statusline_style, ui_render.reset_style,
            ui_render.statusline_style, ui_render.reset_style,
        },
    );
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, text);
}

test "resolved long question and answer wrap into hanging continuation rows" {
    const answers = [_]types.QuestionAnswer{.{
        .question = "Should the background summary cover only the assistant's written reply, or its entire completed turn including tool calls and results?",
        .answer = "Cover the entire completed turn including tool calls and results while keeping the latest user context visible",
    }};
    const width: u16 = 40;
    const text = try composeResolvedQuestionAnswers(std.testing.allocator, &answers, width);
    defer std.testing.allocator.free(text);

    // Nothing trails off: every word survives and no ellipsis is emitted.
    try std.testing.expect(std.mem.find(u8, text, "…") == null);
    try std.testing.expect(std.mem.find(u8, text, "results?") != null);
    try std.testing.expect(std.mem.find(u8, text, "context visible") != null);

    // Continuation rows hang under the question text ("  1) " is 5 wide).
    try std.testing.expect(std.mem.startsWith(u8, text, "  1) Should the background summary"));

    var rows: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| : (rows += 1) {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
        if (rows == 0 or line.len == 0) continue;
        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(std.testing.allocator);
        try appendWithoutAnsi(&plain, line);
        try std.testing.expect(std.mem.startsWith(u8, plain.items, "     "));
        try std.testing.expect(plain.items[5] != ' ');
    }
    try std.testing.expect(rows > 6);
}

fn appendWithoutAnsi(out: *std.ArrayList(u8), text: []const u8) !void {
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            index = display_width.ansiSequenceEnd(text, index);
            continue;
        }
        try out.append(std.testing.allocator, text[index]);
        index += 1;
    }
}

test "resolved multiline answers use the same live and replay layout" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Alpha", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Choose one?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);
    prompt.moveChoice(-1);
    try std.testing.expectEqual(
        question_prompt.FreeformInsertResult.inserted,
        try prompt.insertFreeformSlice(std.testing.allocator, "line-one\nline-two", 64),
    );
    try std.testing.expectEqual(
        question_prompt.QuestionInputEvent.all_decided,
        try prompt.apply(std.testing.allocator, .submit),
    );

    const answers = [_]types.QuestionAnswer{.{
        .question = "Choose one?",
        .answer = "line-one\nline-two",
    }};
    for ([_]u16{ 60, 12 }) |cols| {
        const live = try composeQuestionResolutions(std.testing.allocator, &prompt, false, cols);
        defer std.testing.allocator.free(live);
        const replay = try composeResolvedQuestionAnswers(std.testing.allocator, &answers, cols);
        defer std.testing.allocator.free(replay);
        try std.testing.expectEqualStrings(live, replay);
    }
}

test "compose question panel hides placeholder when freeform slot is selected" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = "go ahead" },
        .{ .label = "No", .description = null },
        .{ .label = "Maybe", .description = "decide later" },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Should we proceed?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);
    prompt.moveChoice(-1);

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 60, unbounded_rows);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, question_prompt.freeform_option_label) == null);
    try std.testing.expect(std.mem.find(u8, text, "\x1b[7m") != null);
}

test "compose question panel shows dim placeholder when freeform slot is not selected" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = "go ahead" },
        .{ .label = "No", .description = null },
        .{ .label = "Maybe", .description = "decide later" },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Should we proceed?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 60, unbounded_rows);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, question_prompt.freeform_option_label) != null);
    try std.testing.expect(std.mem.find(u8, text, ui_render.dim_style) != null);
}

test "compose question panel renders typed buffer in place of placeholder" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = "go ahead" },
        .{ .label = "No", .description = null },
        .{ .label = "Maybe", .description = "decide later" },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Should we proceed?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);
    prompt.moveChoice(-1);
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'h' });
    _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = 'i' });

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 60, unbounded_rows);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "hi") != null);
    try std.testing.expect(std.mem.find(u8, text, "\x1b[7m") != null);
}

test "selected freeform answer wraps into measured continuation rows" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = "go ahead" },
        .{ .label = "No", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Should we proceed?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);
    prompt.moveChoice(-1);

    const answer = "abcdefghijklmnopqrstuvwxyz0123456789";
    for (answer) |byte| _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = byte });

    const width: u16 = 24;
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width, unbounded_rows);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "abcdefghijklmnopq") != null);
    try std.testing.expect(std.mem.find(u8, text, "rstuvwxyz01234567") != null);
    try std.testing.expect(std.mem.find(u8, text, "89") != null);
    try std.testing.expect(std.mem.find(u8, text, "…") == null);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
    }

    const measured_rows = try questionPanelRowsForLayout(std.testing.allocator, prompt.projection().?, width, unbounded_rows);
    try std.testing.expectEqual(@as(u16, 9), measured_rows);
    try expectQuestionPanelRowsMatch(&prompt, width);
}

test "long predefined answer labels wrap into measured continuation rows" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Run the complete verification suite before pushing", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Which action should I take?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    const width: u16 = 32;
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width, unbounded_rows);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "  1) Run the complete") != null);
    try std.testing.expect(std.mem.find(u8, text, "❯") == null);
    try expectVisibleIndentBefore(text, "verification suite", 7);
    try expectVisibleIndentBefore(text, "before pushing", 7);
    try std.testing.expect(std.mem.find(u8, text, "Run the complete…") == null);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
    }

    try expectQuestionPanelRowsMatch(&prompt, width);
}

test "long answer descriptions wrap in their measured column" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{
            .label = "Thorough",
            .description = "Run the complete verification suite before pushing this branch",
        },
        .{ .label = "Skip", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Which action should I take?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    const width: u16 = 60;
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width, unbounded_rows);
    defer std.testing.allocator.free(text);
    const description_indent = questionDescriptionColumn(width) - 1;

    try expectVisibleIndentBefore(text, "Run the complete verification", description_indent);
    try expectVisibleIndentBefore(text, "suite before pushing this", description_indent);
    try expectVisibleIndentBefore(text, "branch", description_indent);
    try std.testing.expect(std.mem.find(u8, text, "Run the complete verification…") == null);
    try expectQuestionPanelRowsMatch(&prompt, width);
}

fn expectVisibleIndentBefore(text: []const u8, needle: []const u8, expected: usize) !void {
    const needle_start = std.mem.find(u8, text, needle) orelse return error.TestExpectedEqual;
    const line_start = if (std.mem.findScalarLast(u8, text[0..needle_start], '\n')) |newline|
        newline + 1
    else
        0;
    try std.testing.expectEqual(
        expected,
        display_width.visibleWidthIgnoringAnsi(text[line_start..needle_start]),
    );
}

test "freeform cursor moves to a continuation row at an exact wrap boundary" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = null },
        .{ .label = "No", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Should we proceed?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);
    prompt.moveChoice(-1);

    // Exactly the freeform content width at 24 cols (24 - 7 prefix), so the
    // cursor lands on a synthetic continuation row.
    const answer = "abcdefghijklmnopq";
    for (answer) |byte| _ = try prompt.apply(std.testing.allocator, .{ .insert_ascii = byte });

    const width: u16 = 24;
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width, unbounded_rows);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "\n       \x1b[7m ") != null);
    try std.testing.expectEqual(@as(u16, 7), try questionPanelRowsForLayout(std.testing.allocator, prompt.projection().?, width, unbounded_rows));
    try expectQuestionPanelRowsMatch(&prompt, width);
}

test "pasted freeform newlines render as measured continuation rows" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = null },
        .{ .label = "No", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Should we proceed?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);
    prompt.moveChoice(-1);
    try std.testing.expectEqual(
        question_prompt.FreeformInsertResult.inserted,
        try prompt.insertFreeformSlice(std.testing.allocator, "first line\nsecond line", 128),
    );

    const width: u16 = 24;
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width, unbounded_rows);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "first line") != null);
    try std.testing.expect(std.mem.find(u8, text, "second line") != null);
    try std.testing.expectEqual(@as(u16, 7), try questionPanelRowsForLayout(std.testing.allocator, prompt.projection().?, width, unbounded_rows));
    try expectQuestionPanelRowsMatch(&prompt, width);
}
