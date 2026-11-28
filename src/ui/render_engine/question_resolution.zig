//! The block an answered question batch leaves in the transcript: each
//! question under its batch ordinal, with the muted answer hanging beneath.
//! The transcript keeps the answers and lays the block out at the width of
//! every paint, so it wraps like the text around it after a resize.

const std = @import("std");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const display_width = @import("../../core/shared/display_width.zig");
const types = @import("../../core/shared/types.zig");
const ui_render = @import("../render.zig");
const markdown_document = @import("markdown_document.zig");
const transcript_blocks = @import("transcript_blocks.zig");

const Allocator = std.mem.Allocator;

/// Copies `answers` and every string in them. The caller owns the result and
/// frees it with `freeAnswers`.
pub fn dupeAnswers(alloc: Allocator, answers: []const types.QuestionAnswer) ![]types.QuestionAnswer {
    const owned = try alloc.alloc(types.QuestionAnswer, answers.len);
    var copied: usize = 0;
    errdefer freeAnswers(alloc, owned[0..copied]);
    for (answers, owned) |answer, *slot| {
        const question = try alloc.dupe(u8, answer.question);
        errdefer alloc.free(question);
        slot.* = .{ .question = question, .answer = try alloc.dupe(u8, answer.answer) };
        copied += 1;
    }
    return owned;
}

pub fn freeAnswers(alloc: Allocator, answers: []const types.QuestionAnswer) void {
    for (answers) |answer| {
        alloc.free(answer.question);
        alloc.free(answer.answer);
    }
    alloc.free(answers);
}

pub fn answersRetainedBytes(answers: []const types.QuestionAnswer) usize {
    var total: usize = 0;
    for (answers) |answer| total += answer.question.len + answer.answer.len;
    return total;
}

/// Styles for Markdown shown outside the assistant's text, in the active theme.
pub fn markdownStyles() transcript_blocks.Styles {
    return .{
        .reset_style = ui_render.reset_style,
        .dim_style = ui_render.dim_style,
        .code_highlight_theme = if (ui_render.is_light) .light else .dark,
    };
}

/// Declared, not inferred: the transcript renderer calls `compose`, and the
/// Markdown renderer it calls renders transcript entries in turn.
pub const ComposeError = error{ OutOfMemory, WriteFailed };

/// The rows of `answers` at `cols`. The answer pairs are borrowed. The caller
/// owns the result.
pub fn compose(
    alloc: Allocator,
    answers: []const types.QuestionAnswer,
    cols: u16,
) ComposeError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    for (answers, 0..) |answer, index| {
        try writeQuestionAnswer(alloc, &out.writer, answer.question, answer.answer, index + 1, cols);
    }

    return out.toOwnedSlice();
}

fn writeQuestionAnswer(
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
    if (!try writeMarkdownQuestion(alloc, writer, question_prefix, indent, question, cols)) {
        try writeField(writer, question_prefix, indent, question, cols, null);
    }
    try writeField(writer, indent, indent, answer, cols, ui_render.statusline_style);
}

/// Writes the question as Markdown, as the prompt showed it, with its rows
/// hanging under the first text column. Returns false, with nothing written,
/// when the Markdown draws nothing or the terminal is too narrow for it.
fn writeMarkdownQuestion(
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

    const rendered = markdown_document.renderRows(alloc, question, render_cols, markdownStyles()) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // The question still shows, as plain text, as it does when the
        // terminal is too narrow for its Markdown.
        debug_trace.logf("question", "answered question markdown failed err={s}; drawn as plain text", .{@errorName(err)});
        return false;
    };
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
fn writeField(
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

pub const WrappedTextLine = struct {
    content_end: usize,
    next_start: usize,
};

/// The next row of `text` from `start` that fits `content_width` columns:
/// it breaks at a space when one fits, at a hard line break, or inside a word
/// only when the word alone is wider than the row.
pub fn nextWrappedTextLine(text: []const u8, start: usize, content_width: usize) WrappedTextLine {
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
