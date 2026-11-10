const std = @import("std");
const question_prompt = @import("../../core/agent/question_prompt.zig");
const display_width = @import("../../core/shared/display_width.zig");
const types = @import("../../core/shared/types.zig");
const ui_render = @import("../render.zig");
const question_freeform_layout = @import("question_freeform_layout.zig");

const Allocator = std.mem.Allocator;

pub fn questionPanelRowsForLayout(
    _: Allocator,
    projection: question_prompt.Projection,
    cols: u16,
) !u16 {
    return questionPanelRowCount(projection, cols);
}

fn questionPanelRowCount(
    projection: question_prompt.Projection,
    row_budget: usize,
) u16 {
    const entry = projection.current_entry orelse return 1;
    const question_width = questionTextWidth(row_budget);
    var count: usize = 2 + wrappedRowLineCount(entry.question, question_width, question_width);
    for (entry.options, 0..) |opt, index| {
        count +|= questionOptionLineCount(entry, opt, index, row_budget);
    }
    return @intCast(@min(count, std.math.maxInt(u16)));
}

pub fn nextPanelLine(text: []const u8, start: *usize) []const u8 {
    if (start.* >= text.len) return "";
    var line_end = start.*;
    while (line_end < text.len and text[line_end] != '\n') : (line_end += 1) {}
    const line = text[start.*..line_end];
    start.* = if (line_end < text.len) line_end + 1 else text.len;
    return line;
}

pub fn composeQuestionPanelText(
    alloc: Allocator,
    projection: question_prompt.Projection,
    cols: u16,
) ![]u8 {
    const row_budget: usize = cols;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const entry = projection.current_entry orelse {
        try out.writer.writeByte('\n');
        return out.toOwnedSlice();
    };

    // The question is its own header; batch progress lives in the hint row.
    try writeQuestionPanelQuestion(&out.writer, entry.question, row_budget);
    try out.writer.writeByte('\n');

    for (entry.options, 0..) |opt, j| {
        try writeQuestionPanelOptionLine(&out.writer, entry, opt, j, row_budget);
    }

    try out.writer.writeByte('\n');

    return out.toOwnedSlice();
}

fn writeQuestionPanelQuestion(
    writer: *std.Io.Writer,
    question: []const u8,
    row_budget: usize,
) !void {
    const content_width = questionTextWidth(row_budget);
    var start: usize = 0;
    var first = true;
    while (first or start < question.len) {
        const line = if (question.len == 0)
            WrappedTextLine{ .content_end = 0, .next_start = 0 }
        else
            nextWrappedRowLine(question, start, content_width);
        try writer.writeAll("  ");
        try writer.writeAll(ui_render.bold_style);
        // The header draws after an indent, which is no base for a mark, so a
        // mark that starts the row is drawn on a circle of its own.
        var at_row_start = true;
        try display_width.writeRowPart(writer, question[start..line.content_end], &at_row_start);
        try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');
        if (question.len == 0) break;
        first = false;
        start = line.next_start;
    }
}

fn questionTextWidth(row_budget: usize) usize {
    return @max(row_budget -| 2, 1);
}

fn writeQuestionPanelOptionLine(
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

    if (description_col > 0) {
        const description_width = @max(row_budget -| description_col, 1);
        const description_indent = description_col - 1;
        var label_start: usize = 0;
        var description_start: usize = 0;
        var row_index: usize = 0;
        while (row_index == 0 or label_start < label.len or description_start < description.len) : (row_index += 1) {
            const label_available = row_index == 0 or label_start < label.len;
            const label_line = if (!label_available or label.len == 0)
                WrappedTextLine{ .content_end = label_start, .next_start = label_start }
            else
                nextWrappedRowLine(label, label_start, if (row_index == 0) widths.first else widths.continuation);
            const description_available = description_start < description.len;
            const description_line = if (description_available)
                nextWrappedRowLine(description, description_start, description_width)
            else
                WrappedTextLine{ .content_end = description_start, .next_start = description_start };

            if (row_index == 0) {
                try writer.writeAll(option_style);
                try writer.writeAll(question_freeform_layout.option_row_indent);
                try writer.writeAll(ordinal);
            } else {
                try writer.splatByteAll(' ', prefix_width);
                try writer.writeAll(option_style);
            }
            // The label's row draws after the ordinal, which is no base for a
            // mark, so a mark that starts it is drawn on a circle of its own.
            var at_row_start = true;
            if (label_available) try display_width.writeRowPart(writer, label[label_start..label_line.content_end], &at_row_start);
            try writer.writeAll(ui_render.reset_style);

            if (description_available) {
                const visible = prefix_width + if (label_available)
                    display_width.rowWidth(label[label_start..label_line.content_end])
                else
                    0;
                if (visible < description_indent) {
                    try writer.splatByteAll(' ', description_indent - visible);
                } else {
                    try writer.writeByte(' ');
                }
                try writer.writeAll(ui_render.dim_style);
                // The padding before the column is no base for a mark either.
                var description_at_row_start = true;
                try display_width.writeRowPart(writer, description[description_start..description_line.content_end], &description_at_row_start);
                try writer.writeAll(ui_render.reset_style);
            }
            try writer.writeByte('\n');

            if (label_available) label_start = label_line.next_start;
            if (description_available) description_start = description_line.next_start;
        }
        return;
    }

    var start: usize = 0;
    var first = true;
    while (first or start < label.len) {
        const line = if (label.len == 0)
            WrappedTextLine{ .content_end = 0, .next_start = 0 }
        else
            nextWrappedRowLine(label, start, if (first) widths.first else widths.continuation);

        if (first) {
            try writer.writeAll(option_style);
            try writer.writeAll(question_freeform_layout.option_row_indent);
            try writer.writeAll(ordinal);
        } else {
            try writer.splatByteAll(' ', prefix_width);
            try writer.writeAll(option_style);
        }
        var at_row_start = true;
        try display_width.writeRowPart(writer, label[start..line.content_end], &at_row_start);
        try writer.writeAll(ui_render.reset_style);
        try writer.writeByte('\n');
        if (label.len == 0) break;
        first = false;
        start = line.next_start;
    }

    if (has_description) {
        const description_width = @max(row_budget -| prefix_width, 1);
        var description_start: usize = 0;
        while (description_start < description.len) {
            const line = nextWrappedRowLine(description, description_start, description_width);
            try writer.splatByteAll(' ', prefix_width);
            try writer.writeAll(ui_render.dim_style);
            var at_row_start = true;
            try display_width.writeRowPart(writer, description[description_start..line.content_end], &at_row_start);
            try writer.writeAll(ui_render.reset_style);
            try writer.writeByte('\n');
            description_start = line.next_start;
        }
    }
}

fn questionOptionLineCount(
    entry: question_prompt.EntryProjection,
    opt: question_prompt.OwnedQuestionOption,
    index: usize,
    row_budget: usize,
) usize {
    if (index == entry.choice_index and opt.is_freeform_slot) {
        return question_freeform_layout.lineCount(
            entry.freeform_buffer,
            entry.freeform_cursor,
            question_freeform_layout.contentWidth(entry.choice_index, row_budget),
        );
    }

    const description = opt.description orelse "";
    const has_description = description.len > 0;
    const widths = questionOptionLabelWidths(index, row_budget, has_description);
    const label_lines = wrappedRowLineCount(questionOptionLabel(entry, opt), widths.first, widths.continuation);
    if (!has_description) return label_lines;

    const description_col = questionDescriptionColumn(row_budget);
    const description_width = if (description_col > 0)
        @max(row_budget -| description_col, 1)
    else
        @max(row_budget -| question_freeform_layout.optionPrefixWidth(index), 1);
    const description_lines = wrappedRowLineCount(description, description_width, description_width);
    return if (description_col > 0)
        @max(label_lines, description_lines)
    else
        label_lines +| description_lines;
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

/// The rows `text` takes in rows of `first_width` and then `continuation_width`
/// cells. Every row draws after a prefix cell, such as an indent or an option's
/// ordinal, which is no base for a mark, so a mark that starts a row takes the
/// cell of its circle: see `nextWrappedRowLine`.
fn wrappedRowLineCount(text: []const u8, first_width: usize, continuation_width: usize) usize {
    if (text.len == 0) return 1;

    var count: usize = 0;
    var start: usize = 0;
    while (start < text.len) : (count += 1) {
        const line = nextWrappedRowLine(text, start, if (count == 0) first_width else continuation_width);
        start = line.next_start;
    }
    return @max(count, 1);
}

/// The row of `text` that starts at `start`, for a row that draws after a
/// prefix cell. A mark that starts the row has no base, so it takes the cell of
/// its circle, and the row wraps after it. The painter draws the circle with
/// `display_width.writeRowPart`.
fn nextWrappedRowLine(text: []const u8, start: usize, content_width: usize) WrappedTextLine {
    if (start >= text.len) return .{ .content_end = text.len, .next_start = text.len };

    const newline = std.mem.findScalar(u8, text[start..], '\n');
    const segment_end = if (newline) |relative| start + relative else text.len;
    const segment = text[start..segment_end];
    const prefix = display_width.rowWrapCutIgnoringAnsi(segment, content_width);
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
    const reverse = "\x1b[7m";
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
        last_width = display_width.rowWidth(buffer[start..end]);
        trailing_hard_break = line.hard_break and line.next_start == buffer.len;

        if (first) {
            try writer.writeAll(ui_render.selected_completion_style);
            try writer.writeAll(question_freeform_layout.option_row_indent);
            try writer.writeAll(ordinal);
        } else {
            try writer.splatByteAll(' ', prefix_width);
            try writer.writeAll(ui_render.selected_completion_style);
        }

        // The line starts a row of cells, so a mark at its start with no base
        // before it is drawn on a circle of its own, which the cursor on the
        // mark highlights with it.
        var at_row_start = true;
        if (cursor >= start and cursor < end) {
            try display_width.writeRowPart(writer, buffer[start..cursor], &at_row_start);
            try writer.writeAll(ui_render.reset_style);
            try writer.writeAll(reverse);
            const cursor_unit = display_width.rowUnitAt(
                buffer,
                cursor,
                display_width.rowWidth(buffer[start..cursor]),
            );
            const cursor_end = @min(cursor + cursor_unit.byte_len, end);
            try display_width.writeRowPart(writer, buffer[cursor..cursor_end], &at_row_start);
            try writer.writeAll(ui_render.reset_style);
            if (cursor_end < end) {
                try writer.writeAll(ui_render.selected_completion_style);
                try display_width.writeRowPart(writer, buffer[cursor_end..end], &at_row_start);
            }
        } else {
            try display_width.writeRowPart(writer, buffer[start..end], &at_row_start);
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
        try writeQuestionAnswerResolution(&out.writer, answer.question, answer.answer, index + 1, cols);
    }

    return out.toOwnedSlice();
}

fn writeQuestionAnswerResolution(
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
    try writeResolutionField(writer, question_prefix, indent, question, cols, null);
    try writeResolutionField(writer, indent, indent, answer, cols, ui_render.statusline_style);
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
        const line = nextWrappedRowLine(text, start, budget);

        if (style) |row_style| try writer.writeAll(row_style);
        try writer.writeAll(prefix);
        // The row draws after a prefix or an indent, which is no base for a
        // mark, so a mark that starts it is drawn on a circle of its own.
        var at_row_start = true;
        try display_width.writeRowPart(writer, text[start..line.content_end], &at_row_start);
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

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 80);
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
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width);
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

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 80);
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

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 60);
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
    const text = try composeQuestionPanelText(std.testing.allocator, projection, width);
    defer std.testing.allocator.free(text);

    var line_start: usize = 0;
    var serialized_rows: u16 = 0;
    while (line_start < text.len) {
        _ = nextPanelLine(text, &line_start);
        serialized_rows += 1;
    }

    const measured_rows = try questionPanelRowsForLayout(std.testing.allocator, projection, width);
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
    try expectVisibleIndentBefore(text, "cover only the assistant's written", 5);
    try expectVisibleIndentBefore(text, "results?", 5);
    try expectVisibleIndentBefore(text, "context visible", 5);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
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

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 60);
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

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 60);
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

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 60);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "hi") != null);
    try std.testing.expect(std.mem.find(u8, text, "\x1b[7m") != null);
}

test "selected freeform answer draws a bare mark on a dotted circle in a cell of its own" {
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

    // A mark that starts the answer has no base: the prompt's space cell is
    // not one, so the mark is drawn on a circle of its own.
    try std.testing.expectEqual(
        question_prompt.FreeformInsertResult.inserted,
        try prompt.insertFreeformSlice(std.testing.allocator, "\u{0E49}abc", 128),
    );
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 40);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "3) \u{25CC}\u{0E49}abc") != null);

    // The cursor on the mark highlights the circle and the mark together.
    _ = try prompt.apply(std.testing.allocator, .{ .edit_freeform = .cursor_home });
    const on_mark = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 40);
    defer std.testing.allocator.free(on_mark);
    try std.testing.expect(std.mem.find(u8, on_mark, "\x1b[7m\u{25CC}\u{0E49}") != null);

    // A zero-width character before the mark leaves it bare.
    _ = try prompt.apply(std.testing.allocator, .{ .edit_freeform = .cursor_end });
    for (0..4) |_| _ = try prompt.apply(std.testing.allocator, .backspace);
    try std.testing.expectEqual(
        question_prompt.FreeformInsertResult.inserted,
        try prompt.insertFreeformSlice(std.testing.allocator, "\u{200B}\u{0E49}abc", 128),
    );
    const spaced = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 40);
    defer std.testing.allocator.free(spaced);
    try std.testing.expect(std.mem.find(u8, spaced, "3) \u{200B}\u{25CC}\u{0E49}abc") != null);
}

test "selected freeform answer counts a bare mark's circle in its rows at every width" {
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
        try prompt.insertFreeformSlice(std.testing.allocator, "\u{0E49}abcdefghijklmnop", 128),
    );

    // The circle takes the first cell of the first row, so each row keeps
    // inside the width, and the measured rows match the composed ones.
    var width: u16 = 16;
    while (width <= 30) : (width += 1) {
        const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width);
        defer std.testing.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
        }
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\u{25CC}"));
        try expectQuestionPanelRowsMatch(&prompt, width);
    }
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
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "abcdefghijklmnopq") != null);
    try std.testing.expect(std.mem.find(u8, text, "rstuvwxyz01234567") != null);
    try std.testing.expect(std.mem.find(u8, text, "89") != null);
    try std.testing.expect(std.mem.find(u8, text, "…") == null);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
    }

    const measured_rows = try questionPanelRowsForLayout(std.testing.allocator, prompt.projection().?, width);
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
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width);
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
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width);
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
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "\n       \x1b[7m ") != null);
    try std.testing.expectEqual(@as(u16, 7), try questionPanelRowsForLayout(std.testing.allocator, prompt.projection().?, width));
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
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.find(u8, text, "first line") != null);
    try std.testing.expect(std.mem.find(u8, text, "second line") != null);
    try std.testing.expectEqual(@as(u16, 7), try questionPanelRowsForLayout(std.testing.allocator, prompt.projection().?, width));
    try expectQuestionPanelRowsMatch(&prompt, width);
}

test "option label that starts with a bare mark is drawn on a dotted circle in a cell of its own" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    // A mark that starts a label has no base: the space after "1)" is not
    // one, so the mark is drawn on a circle that takes a cell of its own. A
    // mark on a base, and the marks of a Thai cluster, get no circle.
    const options = [_]types.QuestionOption{
        .{ .label = "\u{0E49}abc", .description = null },
        .{ .label = "\u{0E49}\u{0E48}abc", .description = null },
        .{ .label = "a\u{0E49}bc", .description = null },
        .{ .label = "\u{0E01}\u{0E31}\u{0E49}\u{0E07}", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Pick one?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 40);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "1) \u{25CC}\u{0E49}abc") != null);
    try std.testing.expect(std.mem.find(u8, text, "2) \u{25CC}\u{0E49}\u{0E48}abc") != null);
    try std.testing.expect(std.mem.find(u8, text, "3) a\u{0E49}bc") != null);
    try std.testing.expect(std.mem.find(u8, text, "4) \u{0E01}\u{0E31}\u{0E49}\u{0E07}") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, "\u{25CC}"));
}

test "option label counts a bare mark's circle in its rows at every width" {
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);

    const options = [_]types.QuestionOption{
        .{ .label = "\u{0E49}abcdefghij klmnopqrst", .description = null },
        .{ .label = "No", .description = null },
    };
    const entries = [_]types.QuestionBatchEntry{
        .{ .question = "Pick one?", .options = &options },
    };
    try prompt.syncFrom(std.testing.allocator, &entries);

    // The circle takes the first cell of the first row, so each row keeps
    // inside the width, the circle is drawn once, and the measured rows match
    // the composed ones.
    var width: u16 = 12;
    while (width <= 40) : (width += 1) {
        const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width);
        defer std.testing.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
        }
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\u{25CC}"));
        try expectQuestionPanelRowsMatch(&prompt, width);
    }

    // The description column starts where it does for a label of the same
    // cells: the circle's cell is counted in the label's width.
    const described = [_]types.QuestionOption{
        .{ .label = "\u{0E49}abc", .description = "described" },
        .{ .label = "No", .description = null },
    };
    const described_entries = [_]types.QuestionBatchEntry{
        .{ .question = "Pick one?", .options = &described },
    };
    var described_prompt = question_prompt.QuestionPrompt{};
    defer described_prompt.deinit(std.testing.allocator);
    try described_prompt.syncFrom(std.testing.allocator, &described_entries);
    const text = try composeQuestionPanelText(std.testing.allocator, described_prompt.projection().?, 60);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "1) \u{25CC}\u{0E49}abc") != null);
    try expectVisibleIndentBefore(text, "described", questionDescriptionColumn(60) - 1);
    try expectQuestionPanelRowsMatch(&described_prompt, 60);
}

test "resolved answer that starts with a bare mark is drawn on a dotted circle in a cell of its own" {
    // The question and the answer draw after a prefix and a five-cell indent,
    // which are no base for a mark. A mark that starts a row after a newline
    // or a soft break has none either; a mark on a base gets no circle.
    const answers = [_]types.QuestionAnswer{
        .{ .question = "\u{0E49}Which?", .answer = "\u{0E49}abc" },
        .{ .question = "Plain?", .answer = "ab\n\u{0E49}cd\na\u{0E49}e" },
        .{ .question = "Soft?", .answer = "aaaa \u{0E49}bbb" },
    };
    const text = try composeResolvedQuestionAnswers(std.testing.allocator, &answers, 40);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "  1) \u{25CC}\u{0E49}Which?\n") != null);
    try std.testing.expect(std.mem.find(u8, text, "     \u{25CC}\u{0E49}abc") != null);
    try std.testing.expect(std.mem.find(u8, text, "     \u{25CC}\u{0E49}cd") != null);
    try std.testing.expect(std.mem.find(u8, text, "     a\u{0E49}e") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, text, "\u{25CC}"));

    // A soft break at the space starts the next row with the mark, which gets
    // its circle there.
    const soft = try composeResolvedQuestionAnswers(std.testing.allocator, answers[2..], 10);
    defer std.testing.allocator.free(soft);
    try std.testing.expect(std.mem.find(u8, soft, "     aaaa") != null);
    try std.testing.expect(std.mem.find(u8, soft, "     \u{25CC}\u{0E49}bbb") != null);
}

test "resolved answer wraps after the circle of a bare mark" {
    var answer: std.ArrayList(u8) = .empty;
    defer answer.deinit(std.testing.allocator);
    try answer.appendSlice(std.testing.allocator, "\u{0E49}");
    try answer.appendNTimes(std.testing.allocator, 'a', 40);
    const answers = [_]types.QuestionAnswer{.{ .question = "Q?", .answer = answer.items }};

    // The circle takes one of the cells after the indent, so the first row
    // holds fewer letters than the rows after it, and no row passes the width.
    var cols: u16 = 7;
    while (cols <= 30) : (cols += 1) {
        const text = try composeResolvedQuestionAnswers(std.testing.allocator, &answers, cols);
        defer std.testing.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
        }
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\u{25CC}"));
        try std.testing.expectEqual(@as(usize, 40), std.mem.count(u8, text, "a"));
    }
}

test "question header that starts with a bare mark is drawn on a dotted circle in a cell of its own" {
    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = null },
        .{ .label = "No", .description = null },
    };

    // The header draws after a two-cell indent, which is no base for a mark,
    // so a mark that starts it takes a circle of its own. A zero-width
    // character before the mark leaves it bare; a mark on a base gets none.
    const cases = [_]struct { question: []const u8, expected: []const u8 }{
        .{ .question = "\u{0E49}Which?", .expected = "  " ++ ui_render.bold_style ++ "\u{25CC}\u{0E49}Which?" },
        .{ .question = "\u{200B}\u{0E49}Which?", .expected = "  " ++ ui_render.bold_style ++ "\u{200B}\u{25CC}\u{0E49}Which?" },
        .{ .question = "Which\u{0E49}?", .expected = "  " ++ ui_render.bold_style ++ "Which\u{0E49}?" },
        .{ .question = "ab\n\u{0E49}cd", .expected = "  " ++ ui_render.bold_style ++ "\u{25CC}\u{0E49}cd" },
    };
    for (cases) |case| {
        var prompt = question_prompt.QuestionPrompt{};
        defer prompt.deinit(std.testing.allocator);
        const entries = [_]types.QuestionBatchEntry{.{ .question = case.question, .options = &options }};
        try prompt.syncFrom(std.testing.allocator, &entries);

        const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 40);
        defer std.testing.allocator.free(text);
        try std.testing.expect(std.mem.find(u8, text, case.expected) != null);
        try expectQuestionPanelRowsMatch(&prompt, 40);
    }

    // A soft break at a space starts the next row with the mark, which gets
    // its circle there.
    var soft = question_prompt.QuestionPrompt{};
    defer soft.deinit(std.testing.allocator);
    const soft_entries = [_]types.QuestionBatchEntry{.{ .question = "aaaa \u{0E49}bbb", .options = &options }};
    try soft.syncFrom(std.testing.allocator, &soft_entries);
    const soft_text = try composeQuestionPanelText(std.testing.allocator, soft.projection().?, 8);
    defer std.testing.allocator.free(soft_text);
    try std.testing.expect(std.mem.find(u8, soft_text, "  " ++ ui_render.bold_style ++ "aaaa") != null);
    try std.testing.expect(std.mem.find(u8, soft_text, "  " ++ ui_render.bold_style ++ "\u{25CC}\u{0E49}bbb") != null);
    try expectQuestionPanelRowsMatch(&soft, 8);
}

test "question header counts a bare mark's circle in its rows at every width" {
    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = null },
        .{ .label = "No", .description = null },
    };
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    const entries = [_]types.QuestionBatchEntry{.{
        .question = "\u{0E49}abcdefghijklmnopqrstuvwxyz0123456789",
        .options = &options,
    }};
    try prompt.syncFrom(std.testing.allocator, &entries);

    // The circle takes one of the cells after the indent, so each row keeps
    // inside the width, the circle is drawn once, no letter is lost, and the
    // measured rows match the composed ones.
    var width: u16 = 8;
    while (width <= 44) : (width += 1) {
        const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width);
        defer std.testing.allocator.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
        }
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\u{25CC}"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "a"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "z"));
        try expectQuestionPanelRowsMatch(&prompt, width);
    }
}

test "option description that starts with a bare mark is drawn on a dotted circle in the stacked layout" {
    const options = [_]types.QuestionOption{
        .{ .label = "Yes", .description = "\u{0E49}abc" },
        .{ .label = "No", .description = "\u{200B}\u{0E49}\u{0E48}abc" },
        .{ .label = "Maybe", .description = "a\u{0E49}bc" },
        .{ .label = "Later", .description = "aaaa \u{0E49}bbb" },
    };
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    const entries = [_]types.QuestionBatchEntry{.{ .question = "Pick one?", .options = &options }};
    try prompt.syncFrom(std.testing.allocator, &entries);

    // Under 52 columns a description draws on rows of its own after the
    // seven cells of the option's indent and ordinal, which are no base for a
    // mark, so a mark that starts a row takes a circle of its own. A mark on a
    // base gets none, and a soft break at a space starts the next row with
    // the mark, which gets its circle there.
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, 14);
    defer std.testing.allocator.free(text);
    try expectVisibleIndentBefore(text, "\u{25CC}\u{0E49}abc", 7);
    try expectVisibleIndentBefore(text, "\u{200B}\u{25CC}\u{0E49}\u{0E48}abc", 7);
    try expectVisibleIndentBefore(text, "a\u{0E49}bc", 7);
    try expectVisibleIndentBefore(text, "\u{25CC}\u{0E49}bbb", 7);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, text, "\u{25CC}"));
    try expectQuestionPanelRowsMatch(&prompt, 14);

    // The circle takes one of the cells of a long description's first row at
    // every width: no row passes the width, no letter is lost, and the
    // measured rows match the composed ones.
    const long = [_]types.QuestionOption{.{
        .label = "Yes",
        .description = "\u{0E49}abcdefghijklmnopqrstuvwxyz0123456789",
    }};
    var long_prompt = question_prompt.QuestionPrompt{};
    defer long_prompt.deinit(std.testing.allocator);
    const long_entries = [_]types.QuestionBatchEntry{.{ .question = "Pick one?", .options = &long }};
    try long_prompt.syncFrom(std.testing.allocator, &long_entries);
    var width: u16 = 9;
    while (width <= 51) : (width += 1) {
        const rows = try composeQuestionPanelText(std.testing.allocator, long_prompt.projection().?, width);
        defer std.testing.allocator.free(rows);
        var lines = std.mem.splitScalar(u8, rows, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= width);
        }
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rows, "\u{25CC}"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rows, "z"));
        try expectQuestionPanelRowsMatch(&long_prompt, width);
    }
}

test "option description that starts with a bare mark is drawn on a dotted circle in the description column" {
    const options = [_]types.QuestionOption{
        .{ .label = "Thorough", .description = "\u{0E49}abc" },
        .{ .label = "Skip", .description = "a\u{0E49}bc" },
        .{ .label = "Later", .description = "aaaa \u{0E49}bbb" },
    };
    var prompt = question_prompt.QuestionPrompt{};
    defer prompt.deinit(std.testing.allocator);
    const entries = [_]types.QuestionBatchEntry{.{ .question = "Pick one?", .options = &options }};
    try prompt.syncFrom(std.testing.allocator, &entries);

    // From 52 columns a description draws in a column after its label, which
    // pads with spaces, so a mark that starts it has no base and takes a
    // circle of its own at the column.
    const width: u16 = 60;
    const text = try composeQuestionPanelText(std.testing.allocator, prompt.projection().?, width);
    defer std.testing.allocator.free(text);
    try expectVisibleIndentBefore(text, "\u{25CC}\u{0E49}abc", questionDescriptionColumn(width) - 1);
    try expectVisibleIndentBefore(text, "a\u{0E49}bc", questionDescriptionColumn(width) - 1);
    try expectVisibleIndentBefore(text, "aaaa \u{0E49}bbb", questionDescriptionColumn(width) - 1);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\u{25CC}"));
    try expectQuestionPanelRowsMatch(&prompt, width);

    // A description that wraps keeps the circle in its first row and starts
    // each later row at the column.
    const long = [_]types.QuestionOption{
        .{ .label = "Thorough", .description = "\u{0E49}abcdefghij klmnopqrst uvwxyz0123456789" },
        .{ .label = "Skip", .description = null },
    };
    var long_prompt = question_prompt.QuestionPrompt{};
    defer long_prompt.deinit(std.testing.allocator);
    const long_entries = [_]types.QuestionBatchEntry{.{ .question = "Pick one?", .options = &long }};
    try long_prompt.syncFrom(std.testing.allocator, &long_entries);
    var cols: u16 = 52;
    while (cols <= 90) : (cols += 1) {
        const rows = try composeQuestionPanelText(std.testing.allocator, long_prompt.projection().?, cols);
        defer std.testing.allocator.free(rows);
        var lines = std.mem.splitScalar(u8, rows, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
        }
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rows, "\u{25CC}"));
        try expectVisibleIndentBefore(rows, "\u{25CC}", questionDescriptionColumn(cols) - 1);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rows, "z"));
        try expectQuestionPanelRowsMatch(&long_prompt, cols);
    }
}
