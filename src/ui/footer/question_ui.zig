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
    var count: usize = 2 + wrappedTextLineCount(entry.question, question_width, question_width);
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
            nextWrappedTextLine(question, start, content_width);
        try writer.writeAll("  ");
        try writer.writeAll(ui_render.bold_style);
        try writer.writeAll(question[start..line.content_end]);
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
                nextWrappedTextLine(label, label_start, if (row_index == 0) widths.first else widths.continuation);
            const description_available = description_start < description.len;
            const description_line = if (description_available)
                nextWrappedTextLine(description, description_start, description_width)
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
            if (label_available) try writer.writeAll(label[label_start..label_line.content_end]);
            try writer.writeAll(ui_render.reset_style);

            if (description_available) {
                const visible = prefix_width + if (label_available)
                    display_width.visibleWidth(label[label_start..label_line.content_end])
                else
                    0;
                if (visible < description_indent) {
                    try writer.splatByteAll(' ', description_indent - visible);
                } else {
                    try writer.writeByte(' ');
                }
                try writer.writeAll(ui_render.dim_style);
                try writer.writeAll(description[description_start..description_line.content_end]);
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

    if (has_description) {
        const description_width = @max(row_budget -| prefix_width, 1);
        var description_start: usize = 0;
        while (description_start < description.len) {
            const line = nextWrappedTextLine(description, description_start, description_width);
            try writer.splatByteAll(' ', prefix_width);
            try writer.writeAll(ui_render.dim_style);
            try writer.writeAll(description[description_start..line.content_end]);
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
    const label_lines = wrappedTextLineCount(questionOptionLabel(entry, opt), widths.first, widths.continuation);
    if (!has_description) return label_lines;

    const description_col = questionDescriptionColumn(row_budget);
    const description_width = if (description_col > 0)
        @max(row_budget -| description_col, 1)
    else
        @max(row_budget -| question_freeform_layout.optionPrefixWidth(index), 1);
    const description_lines = wrappedTextLineCount(description, description_width, description_width);
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

fn wrappedTextLineCount(text: []const u8, first_width: usize, continuation_width: usize) usize {
    if (text.len == 0) return 1;

    var count: usize = 0;
    var start: usize = 0;
    while (start < text.len) : (count += 1) {
        const line = nextWrappedTextLine(text, start, if (count == 0) first_width else continuation_width);
        start = line.next_start;
    }
    return @max(count, 1);
}

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
/// the muted answer hanging beneath. Cancelled → single `■ Cancelled\n`.
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
    try writer.writeAll("■");
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
        "{s}■{s} Cancelled\n",
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
