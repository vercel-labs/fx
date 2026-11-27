const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const input_presentation = @import("input_presentation.zig");
const render_input = @import("render_input.zig");
const row_text = @import("row_text.zig");
const text_utils = @import("../../core/shared/text_utils.zig");
const ui_render = @import("../render.zig");
const vt_emulator = @import("../../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;
const ForkMenuProjection = render_input.ForkMenuProjection;

const header_rows: u16 = 1;
const roomy_top_gap_rows: u16 = 1;
/// Each prompt shows as at most this many wrapped lines.
const max_prompt_lines = render_input.max_message_layout_rows;
/// The subagent question wraps across at most this many lines on narrow terminals.
const max_question_lines: u16 = 3;
/// Header, top gap, and up to six prompts of three lines.
pub const max_inline_rows: u16 = header_rows + roomy_top_gap_rows + 6 * max_prompt_lines;

const header_subtitle = "Select a prompt to fork before";
const empty_prompt_label = "(empty prompt)";
/// Minimum text columns required before showing the prompt number gutter.
const min_text_cols_with_number: u16 = 4;

/// The keys the prompt list takes, strictly widest to narrowest.
pub const list_hint_variants = [_][]const u8{
    "↑↓ navigate     enter fork     esc close",
    "↑↓ navigate  enter fork  esc close",
    "↑↓ move  enter fork  esc",
    "enter fork  esc close",
    "enter esc",
};

/// The keys the question takes, widest first.
pub const question_hint_variants = [_][]const u8{
    "enter yes     n or esc no",
    "enter yes  n or esc no",
    "enter y  esc n",
    "enter esc",
};

const Columns = struct {
    indent: u16,
    number_digits: u16,
    number_col: u16,
    text_width: u16,
    question_width: u16,

    fn of(point_count: usize, width: u16) Columns {
        if (width == 0) return .{ .indent = 0, .number_digits = 0, .number_col = 0, .text_width = 0, .question_width = 0 };
        const indent: u16 = if (width > 4) 2 else 0;
        const right_margin: u16 = if (width > 8) 1 else 0;
        const digits = digitCount(@max(point_count, 1));
        const gutter = digits + 2;
        const number_col: u16 = if (width >= indent + gutter + min_text_cols_with_number + right_margin) gutter else 0;
        const text_width = @max(width -| indent -| number_col -| right_margin, 1);
        const question_width = @max(width -| indent -| right_margin, 1);
        return .{
            .indent = indent,
            .number_digits = digits,
            .number_col = number_col,
            .text_width = text_width,
            .question_width = question_width,
        };
    }
};

fn digitCount(n: usize) u16 {
    var value = n;
    var digits: u16 = 1;
    while (value >= 10) : (value /= 10) digits += 1;
    return digits;
}

const WrappedLines = struct {
    rows: [max_prompt_lines][]const u8 = @splat(""),
    row_count: u16 = 0,
    content_width: u16 = 0,
    truncated: bool = false,
};

fn isBlankSlice(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != ' ' and byte != '\t' and byte != '\r' and byte != '\n') return false;
    }
    return true;
}

fn trimTrailingSpaces(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == ' ' or bytes[end - 1] == '\t')) end -= 1;
    return bytes[0..end];
}

fn unitDisplayWidth(raw: []const u8, unit_cell_width: usize) usize {
    if (raw.len == 1 and raw[0] == '\t') return 1;
    if (text_utils.isTerminalSafe(raw)) return unit_cell_width;
    return text_utils.terminalSafeVisibleWidth(raw);
}

fn hasMoreNonBlankText(text: []const u8, start: usize, skip_blank_lines: bool) bool {
    if (start >= text.len) return false;
    if (!skip_blank_lines) return true;
    return !isBlankSlice(text[start..]);
}

/// Wraps `text` into at most `row_limit` visual lines of `max_width` cells.
/// When `skip_blank_lines` is true, blank-only physical lines are omitted so
/// prompts with empty lines show real text instead of empty rows and lone `…`.
fn wrapText(text: []const u8, max_width: u16, row_limit: u16, skip_blank_lines: bool) WrappedLines {
    const limit = @min(row_limit, max_prompt_lines);
    var layout: WrappedLines = .{ .content_width = max_width };
    if (max_width == 0 or limit == 0) return layout;

    var pos: usize = 0;
    while (pos <= text.len and layout.row_count < limit) {
        const nl = std.mem.findScalarPos(u8, text, pos, '\n') orelse text.len;
        const line_end = if (nl > pos and text[nl - 1] == '\r') nl - 1 else nl;
        const next_line_start = if (nl < text.len) nl + 1 else text.len;
        const line = text[pos..line_end];

        if (skip_blank_lines and isBlankSlice(line)) {
            if (nl == text.len) break;
            pos = next_line_start;
            continue;
        }

        if (line.len == 0) {
            layout.rows[layout.row_count] = "";
            layout.row_count += 1;
            if (nl == text.len) break;
            pos = next_line_start;
            continue;
        }

        var offset: usize = 0;
        while (offset < line.len and layout.row_count < limit) {
            const start = offset;
            var cells: usize = 0;
            var ellipsis_end = start;
            var last_space: ?usize = null;
            while (offset < line.len) {
                const unit = display_width.displayUnitAt(line, offset);
                if (unit.byte_len == 0) break;
                const raw = line[offset .. offset + unit.byte_len];
                const unit_width = unitDisplayWidth(raw, unit.cell_width);
                if (unit_width > max_width - cells) break;
                if (line[offset] == ' ' or line[offset] == '\t') last_space = offset;
                cells += unit_width;
                offset += unit.byte_len;
                if (cells < max_width) ellipsis_end = offset;
            }
            var end = offset;
            const soft_separator = offset < line.len and (line[offset] == ' ' or line[offset] == '\t');
            if (soft_separator) {
                while (offset < line.len and (line[offset] == ' ' or line[offset] == '\t')) offset += 1;
            } else if (offset < line.len) {
                if (last_space) |space| {
                    if (space > start) {
                        end = space;
                        offset = space + 1;
                    }
                }
            }
            const more_in_line = offset < line.len;
            const more_after = more_in_line or (nl < text.len and hasMoreNonBlankText(text, next_line_start, skip_blank_lines));
            const stalled = end == start and more_in_line;
            const is_last_row = layout.row_count + 1 == limit or stalled;

            if (is_last_row and more_after) {
                const cut = trimTrailingSpaces(line[start..@min(end, ellipsis_end)]);
                layout.rows[layout.row_count] = cut;
                layout.row_count += 1;
                layout.truncated = true;
                return layout;
            }

            layout.rows[layout.row_count] = line[start..end];
            layout.row_count += 1;
            if (!more_in_line) break;
        }

        if (nl == text.len) break;
        pos = next_line_start;
    }

    if (layout.row_count == 0) {
        layout.rows[0] = "";
        layout.row_count = 1;
    }
    return layout;
}

fn promptLayout(prompt: []const u8, text_width: u16, row_limit: u16) WrappedLines {
    const source = if (isBlankSlice(prompt)) empty_prompt_label else prompt;
    return wrapText(source, text_width, row_limit, true);
}

fn appendWrappedRow(alloc: Allocator, row: *std.ArrayList(u8), layout: WrappedLines, index: usize) !void {
    const slice = layout.rows[index];
    const normalized = try alloc.dupe(u8, slice);
    defer alloc.free(normalized);
    for (normalized) |*byte| {
        if (byte.* == '\t') byte.* = ' ';
    }
    var safe = try text_utils.encodeTerminalSafe(alloc, normalized, std.math.maxInt(usize));
    defer safe.deinit(alloc);
    const ellipsis = layout.truncated and index + 1 == layout.row_count and layout.content_width > 0;
    try row_text.appendClipped(alloc, row, safe.bytes, layout.content_width - @as(u16, @intFromBool(ellipsis)));
    if (ellipsis) try row.appendSlice(alloc, "…");
}

/// The menu's prompt lines in order, and where the selected prompt sits.
const Lines = struct {
    total: usize = 0,
    selected_start: usize = 0,
    selected_end: usize = 0,

    fn measure(projection: ForkMenuProjection, text_width: u16) Lines {
        var lines: Lines = .{};
        for (projection.points, 0..) |point, index| {
            if (index == projection.selected) lines.selected_start = lines.total;
            lines.total += promptLayout(point.prompt, text_width, max_prompt_lines).row_count;
            if (index == projection.selected) lines.selected_end = lines.total;
        }
        return lines;
    }
};

const ListLayout = struct {
    show_header: bool = false,
    first_item_row: u16 = 0,
    body_budget: u16 = 0,
    lines: Lines = .{},
    columns: Columns = .{ .indent = 0, .number_digits = 0, .number_col = 0, .text_width = 0, .question_width = 0 },
    row_count: u16 = 0,

    fn build(projection: ForkMenuProjection, width: u16, row_budget: u16) ListLayout {
        if (width == 0 or row_budget == 0 or projection.points.len == 0) return .{};
        const columns = Columns.of(projection.points.len, width);
        const lines = Lines.measure(projection, columns.text_width);
        const show_header = row_budget >= 2;
        const first_item_row: u16 = if (row_budget >= 3)
            header_rows + roomy_top_gap_rows
        else if (row_budget == 2)
            header_rows
        else
            0;
        const body_budget = row_budget - first_item_row;
        const body_rows: u16 = @intCast(@min(body_budget, lines.total));
        return .{
            .show_header = show_header,
            .first_item_row = first_item_row,
            .body_budget = body_budget,
            .lines = lines,
            .columns = columns,
            .row_count = first_item_row + body_rows,
        };
    }
};

const QuestionLayout = struct {
    show_header: bool = false,
    prompt_start: u16 = 0,
    prompt_rows: u16 = 0,
    question_start: u16 = 0,
    question_rows: u16 = 0,
    row_count: u16 = 0,
    columns: Columns = .{ .indent = 0, .number_digits = 0, .number_col = 0, .text_width = 0, .question_width = 0 },
    question_wrapped: WrappedLines = .{},

    fn build(projection: ForkMenuProjection, count: usize, width: u16, row_budget: u16) QuestionLayout {
        if (width == 0 or row_budget == 0 or projection.points.len == 0) return .{};
        const columns = Columns.of(projection.points.len, width);
        var q_buf: [64]u8 = undefined;
        const q_text = questionText(&q_buf, count);
        const q_wrapped = wrapText(q_text, columns.question_width, max_question_lines, false);
        const q_rows: u16 = @min(row_budget, q_wrapped.row_count);
        const rem = row_budget - q_rows;

        if (rem == 0) {
            return .{
                .question_start = 0,
                .question_rows = q_rows,
                .row_count = q_rows,
                .columns = columns,
                .question_wrapped = q_wrapped,
            };
        }

        const full_prompt = promptLayout(projection.points[projection.selected].prompt, columns.question_width, max_prompt_lines);
        if (rem == 1) {
            return .{
                .prompt_start = 0,
                .prompt_rows = 1,
                .question_start = 1,
                .question_rows = q_rows,
                .row_count = 1 + q_rows,
                .columns = columns,
                .question_wrapped = q_wrapped,
            };
        }

        const after_header = rem - header_rows;
        const prompt_rows: u16 = @min(full_prompt.row_count, after_header);
        const extra = after_header - prompt_rows;
        const mid_gap: u16 = if (extra >= 1) 1 else 0;
        const top_gap: u16 = if (extra >= 2) roomy_top_gap_rows else 0;
        const prompt_start = header_rows + top_gap;
        const question_start = prompt_start + prompt_rows + mid_gap;
        return .{
            .show_header = true,
            .prompt_start = prompt_start,
            .prompt_rows = prompt_rows,
            .question_start = question_start,
            .question_rows = q_rows,
            .row_count = question_start + q_rows,
            .columns = columns,
            .question_wrapped = q_wrapped,
        };
    }
};

pub fn menuRowCount(projection: ForkMenuProjection, width: u16, row_budget: u16) u16 {
    if (projection.question) |count| {
        return QuestionLayout.build(projection, count, width, row_budget).row_count;
    }
    return ListLayout.build(projection, width, row_budget).row_count;
}

/// The question after a prompt is chosen where the session had subagents.
fn questionText(buf: []u8, count: usize) []const u8 {
    if (count == 1) return "Bring 1 subagent into the fork?";
    return std.mem.print(buf, "Bring {d} subagents into the fork?", .{count}) catch "Bring the subagents into the fork?";
}

fn composeListHeaderRow(alloc: Allocator, point_count: usize, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    var title_buf: [32]u8 = undefined;
    const title = std.mem.print(&title_buf, "Fork {d}", .{point_count}) catch "Fork";
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    try row_text.appendClipped(alloc, &row, title, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    const title_width = display_width.visibleWidth(title);
    const subtitle_width = display_width.visibleWidth(header_subtitle);
    if (title_width + 2 + subtitle_width <= width) {
        try row.appendSlice(alloc, "  ");
        try row.appendSlice(alloc, ui_render.dim_style);
        try row.appendSlice(alloc, header_subtitle);
        try row.appendSlice(alloc, ui_render.reset_style);
    }
    return row;
}

fn composeQuestionHeaderRow(alloc: Allocator, width: u16) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.selected_completion_style);
    try row_text.appendClipped(alloc, &row, "Fork", width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

/// Row `row_index` of the subagent question: header, chosen prompt preview
/// (keeping the start with `…` when height is tight), gap, and wrapped question.
fn composeQuestionRow(
    alloc: Allocator,
    projection: ForkMenuProjection,
    count: usize,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    const layout = QuestionLayout.build(projection, count, width, row_budget);
    if (row_index >= layout.row_count) return .empty;
    if (layout.show_header and row_index == 0) return composeQuestionHeaderRow(alloc, width);

    if (layout.prompt_rows > 0 and row_index >= layout.prompt_start and row_index < layout.prompt_start + layout.prompt_rows) {
        const prompt_wrapped = promptLayout(
            projection.points[projection.selected].prompt,
            layout.columns.question_width,
            layout.prompt_rows,
        );
        const prompt_line = row_index - layout.prompt_start;
        if (prompt_line >= prompt_wrapped.row_count) return .empty;
        var row: std.ArrayList(u8) = .empty;
        errdefer row.deinit(alloc);
        try row.appendNTimes(alloc, ' ', layout.columns.indent);
        try row.appendSlice(alloc, ui_render.dim_style);
        try appendWrappedRow(alloc, &row, prompt_wrapped, prompt_line);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    if (row_index >= layout.question_start and row_index < layout.question_start + layout.question_rows) {
        var q_buf: [64]u8 = undefined;
        const q_text = questionText(&q_buf, count);
        const q_wrapped = wrapText(q_text, layout.columns.question_width, layout.question_rows, false);
        const q_line = row_index - layout.question_start;
        if (q_line >= q_wrapped.row_count) return .empty;
        var row: std.ArrayList(u8) = .empty;
        errdefer row.deinit(alloc);
        try row.appendNTimes(alloc, ' ', layout.columns.indent);
        try row.appendSlice(alloc, ui_render.selected_completion_style);
        try appendWrappedRow(alloc, &row, q_wrapped, q_line);
        try row.appendSlice(alloc, ui_render.reset_style);
        return row;
    }

    return .empty;
}

fn listWindowStart(projection: ForkMenuProjection, list: ListLayout) usize {
    if (list.lines.total == 0 or list.body_budget == 0) return 0;
    const height: usize = @min(list.body_budget, list.lines.total);
    var start = @min(projection.window_start, list.lines.total - height);
    if (list.lines.selected_start < start) start = list.lines.selected_start;
    if (list.lines.selected_end > start + height) start = @min(list.lines.selected_start, list.lines.selected_end - height);
    return start;
}

/// The first prompt line shown: `projection.window_start`, moved only as far as
/// it takes to show the whole selected prompt, so the list scrolls at its edges.
pub fn windowStart(projection: ForkMenuProjection, width: u16, row_budget: u16) usize {
    return listWindowStart(projection, ListLayout.build(projection, width, row_budget));
}

fn appendNumberGutter(alloc: Allocator, row: *std.ArrayList(u8), columns: Columns, index: usize, first_line: bool) !void {
    if (columns.number_col == 0) return;
    if (!first_line) {
        try row.appendNTimes(alloc, ' ', columns.number_col);
        return;
    }
    var num_buf: [24]u8 = undefined;
    const num_text = std.mem.print(&num_buf, "{d}", .{index + 1}) catch "";
    const pad = columns.number_digits -| @as(u16, @intCast(num_text.len));
    try row.appendNTimes(alloc, ' ', pad);
    try row.appendSlice(alloc, num_text);
    try row.appendSlice(alloc, "  ");
}

pub fn composeForkMenuRow(
    alloc: Allocator,
    projection: ForkMenuProjection,
    row_index: u16,
    width: u16,
    row_budget: u16,
) !std.ArrayList(u8) {
    if (width == 0 or row_index >= row_budget) return .empty;
    if (projection.question) |count| {
        return composeQuestionRow(alloc, projection, count, row_index, width, row_budget);
    }
    const list = ListLayout.build(projection, width, row_budget);
    if (row_index >= list.row_count) return .empty;
    if (list.show_header and row_index == 0) return composeListHeaderRow(alloc, projection.points.len, width);
    if (row_index < list.first_item_row) return .empty;

    const line = listWindowStart(projection, list) + (row_index - list.first_item_row);
    var first: usize = 0;
    for (projection.points, 0..) |point, index| {
        const layout = promptLayout(point.prompt, list.columns.text_width, max_prompt_lines);
        if (line < first + layout.row_count) {
            var row: std.ArrayList(u8) = .empty;
            errdefer row.deinit(alloc);
            const selected = index == projection.selected;
            try row.appendNTimes(alloc, ' ', list.columns.indent);
            try row.appendSlice(alloc, if (selected) ui_render.selected_completion_style else ui_render.dim_style);
            try appendNumberGutter(alloc, &row, list.columns, index, line == first);
            try appendWrappedRow(alloc, &row, layout, line - first);
            try row.appendSlice(alloc, ui_render.reset_style);
            return row;
        }
        first += layout.row_count;
    }
    return .empty;
}

const ForkPoint = std.meta.Child(@FieldType(ForkMenuProjection, "points"));

/// The visible text of row `row_index`, and whether it is selected. Caller owns the text.
fn testRow(projection: ForkMenuProjection, row_index: u16, width: u16, row_budget: u16) !struct { text: []u8, selected: bool } {
    const alloc = std.testing.allocator;
    var row = try composeForkMenuRow(alloc, projection, row_index, width, row_budget);
    defer row.deinit(alloc);
    const selected = std.mem.find(u8, row.items, ui_render.selected_completion_style) != null;
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var index: usize = 0;
    while (index < row.items.len) {
        if (row.items[index] == 0x1b) {
            index = std.mem.findScalarPos(u8, row.items, index, 'm').? + 1;
            continue;
        }
        try text.append(alloc, row.items[index]);
        index += 1;
    }
    return .{ .text = try text.toOwnedSlice(alloc), .selected = selected };
}

fn renderForkMenuToGrid(
    alloc: Allocator,
    projection: ForkMenuProjection,
    width: u16,
    row_budget: u16,
) !vt_emulator.Grid {
    const count = menuRowCount(projection, width, row_budget);
    var grid = try vt_emulator.Grid.init(alloc, @max(width, 1), @max(count, 1));
    errdefer grid.deinit();
    for (0..count) |row_index| {
        var row = try composeForkMenuRow(alloc, projection, @intCast(row_index), width, row_budget);
        defer row.deinit(alloc);
        var pos_buf: [32]u8 = undefined;
        const move = try std.mem.print(&pos_buf, "\x1b[{d};1H", .{row_index + 1});
        try grid.feed(move);
        try grid.feed(row.items);
    }
    return grid;
}

fn gridRow(grid: vt_emulator.Grid, alloc: Allocator, row_index: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try grid.rowTextTrimmed(@intCast(row_index + 1), &out);
    return out.toOwnedSlice(alloc);
}

test "fork menu shows each prompt in at most three lines, ending a cut one with an ellipsis" {
    const points = [_]ForkPoint{
        .{ .turn = 1, .prompt = @constCast("one two three four five six seven eight nine ten eleven twelve") },
        .{ .turn = 2, .prompt = @constCast("short\nsecond line") },
    };
    const projection: ForkMenuProjection = .{ .points = &points, .selected = 1, .window_start = 0 };
    // Width 20: indent 2, gutter 3 ("1  "), right margin 1 -> 14 text cols.
    try std.testing.expectEqual(@as(u16, 7), menuRowCount(projection, 20, max_inline_rows));
    const expected = [_][]const u8{
        "Fork 2",
        "",
        "  1  one two three",
        "     four five six",
        "     seven eight…",
        "  2  short",
        "     second line",
    };
    for (expected, 0..) |text, row_index| {
        const row = try testRow(projection, @intCast(row_index), 20, max_inline_rows);
        defer std.testing.allocator.free(row.text);
        try std.testing.expectEqualStrings(text, row.text);
        try std.testing.expectEqual(row_index == 0 or row_index >= 5, row.selected);
    }
}

test "fork menu lists prompts oldest first and opens on the newest at the bottom" {
    const points = [_]ForkPoint{
        .{ .turn = 1, .prompt = @constCast("first") },
        .{ .turn = 2, .prompt = @constCast("second") },
        .{ .turn = 3, .prompt = @constCast("third") },
    };
    // As the menu opens: the newest selected, the window past the end.
    var projection: ForkMenuProjection = .{ .points = &points, .selected = 2, .window_start = std.math.maxInt(usize) };
    const full = [_][]const u8{
        "Fork 3  Select a prompt to fork before",
        "",
        "  1  first",
        "  2  second",
        "  3  third",
    };
    for (full, 0..) |text, row_index| {
        const row = try testRow(projection, @intCast(row_index), 40, 5);
        defer std.testing.allocator.free(row.text);
        try std.testing.expectEqualStrings(text, row.text);
        try std.testing.expectEqual(row_index == 0 or row_index == 4, row.selected);
    }

    // Four rows give header, gap, and two body rows; moving up keeps them
    // until the selection passes the top, then the list scrolls by one.
    const steps = [_]struct { selected: usize, top: []const u8, bottom: []const u8 }{
        .{ .selected = 2, .top = "  2  second", .bottom = "  3  third" },
        .{ .selected = 1, .top = "  2  second", .bottom = "  3  third" },
        .{ .selected = 0, .top = "  1  first", .bottom = "  2  second" },
        .{ .selected = 1, .top = "  1  first", .bottom = "  2  second" },
    };
    for (steps) |step| {
        projection.selected = step.selected;
        projection.window_start = windowStart(projection, 40, 4);
        const top = try testRow(projection, 2, 40, 4);
        defer std.testing.allocator.free(top.text);
        const bottom = try testRow(projection, 3, 40, 4);
        defer std.testing.allocator.free(bottom.text);
        try std.testing.expectEqualStrings(step.top, top.text);
        try std.testing.expectEqualStrings(step.bottom, bottom.text);
    }
}

test "fork menu asks once about the subagents under the chosen prompt" {
    const points = [_]ForkPoint{
        .{ .turn = 1, .prompt = @constCast("first") },
        .{ .turn = 2, .prompt = @constCast("second") },
    };
    var projection: ForkMenuProjection = .{ .points = &points, .selected = 0, .window_start = 0, .question = 2 };
    try std.testing.expectEqual(@as(u16, 5), menuRowCount(projection, 40, max_inline_rows));
    const header = try testRow(projection, 0, 40, max_inline_rows);
    defer std.testing.allocator.free(header.text);
    try std.testing.expectEqualStrings("Fork", header.text);
    const prompt = try testRow(projection, 2, 40, max_inline_rows);
    defer std.testing.allocator.free(prompt.text);
    try std.testing.expectEqualStrings("  first", prompt.text);
    try std.testing.expect(!prompt.selected);
    const question = try testRow(projection, 4, 40, max_inline_rows);
    defer std.testing.allocator.free(question.text);
    try std.testing.expectEqualStrings("  Bring 2 subagents into the fork?", question.text);
    try std.testing.expect(question.selected);

    // One row shows only the question; one subagent reads in the singular.
    projection.question = 1;
    try std.testing.expectEqual(@as(u16, 1), menuRowCount(projection, 40, 1));
    const only = try testRow(projection, 0, 40, 1);
    defer std.testing.allocator.free(only.text);
    try std.testing.expectEqualStrings("  Bring 1 subagent into the fork?", only.text);
}

test "the fork question's hint keeps its keys at every width (D97)" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { width: u16, text: []const u8 }{
        .{ .width = 80, .text = "enter yes     n or esc no" },
        .{ .width = 24, .text = "enter yes  n or esc no" },
        .{ .width = 16, .text = "enter y  esc n" },
        .{ .width = 9, .text = "enter esc" },
    };
    for (cases) |case| {
        var row = try input_presentation.composeVariantHintRow(alloc, case.width, false, &question_hint_variants);
        defer row.deinit(alloc);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(alloc);
        var index: usize = 0;
        while (index < row.items.len) {
            if (row.items[index] == 0x1b) {
                index = std.mem.findScalarPos(u8, row.items, index, 'm').? + 1;
                continue;
            }
            try text.append(alloc, row.items[index]);
            index += 1;
        }
        try std.testing.expectEqualStrings(case.text, text.items);
    }
}

test "fork menu draws header, count, gap, and aligned prompt numbers on the VT grid" {
    const alloc = std.testing.allocator;
    const points = [_]ForkPoint{
        .{ .turn = 1, .prompt = @constCast("Fix login bug") },
        .{ .turn = 2, .prompt = @constCast("Line one of prompt two\nLine two of prompt two") },
        .{ .turn = 3, .prompt = @constCast("Update readme") },
    };
    const projection: ForkMenuProjection = .{ .points = &points, .selected = 2, .window_start = 0 };

    // Wide (80 cols): bold header with subtitle, blank gap, then numbered prompts with aligned continuations.
    var wide = try renderForkMenuToGrid(alloc, projection, 80, max_inline_rows);
    defer wide.deinit();
    try std.testing.expectEqual(@as(u16, 6), menuRowCount(projection, 80, max_inline_rows));
    const expected_wide = [_][]const u8{
        "Fork 3  Select a prompt to fork before",
        "",
        "  1  Fix login bug",
        "  2  Line one of prompt two",
        "     Line two of prompt two",
        "  3  Update readme",
    };
    for (expected_wide, 0..) |expected, row_index| {
        const line = try gridRow(wide, alloc, row_index);
        defer alloc.free(line);
        try std.testing.expectEqualStrings(expected, line);
    }

    // Narrow (32 cols): omits subtitle instead of truncating it, keeps count.
    var narrow = try renderForkMenuToGrid(alloc, projection, 32, max_inline_rows);
    defer narrow.deinit();
    const narrow_header = try gridRow(narrow, alloc, 0);
    defer alloc.free(narrow_header);
    try std.testing.expectEqualStrings("Fork 3", narrow_header);

    // Tiny vertical budget drops gap at 2 rows and header at 1 row.
    try std.testing.expectEqual(@as(u16, 2), menuRowCount(projection, 80, 2));
    const two_row_header = try testRow(projection, 0, 80, 2);
    defer alloc.free(two_row_header.text);
    try std.testing.expectEqualStrings("Fork 3  Select a prompt to fork before", two_row_header.text);
    const two_row_item = try testRow(projection, 1, 80, 2);
    defer alloc.free(two_row_item.text);
    try std.testing.expectEqualStrings("  3  Update readme", two_row_item.text);
    try std.testing.expect(two_row_item.selected);

    try std.testing.expectEqual(@as(u16, 1), menuRowCount(projection, 80, 1));
    const one_row = try testRow(projection, 0, 80, 1);
    defer alloc.free(one_row.text);
    try std.testing.expectEqualStrings("  3  Update readme", one_row.text);
    try std.testing.expect(one_row.selected);
}

test "fork menu skips blank lines and labels empty prompts" {
    const alloc = std.testing.allocator;
    const points = [_]ForkPoint{
        .{ .turn = 1, .prompt = @constCast("Line one\n\n\nLine four after blanks") },
        .{ .turn = 2, .prompt = @constCast("   \n\t\n  ") },
    };
    const projection: ForkMenuProjection = .{ .points = &points, .selected = 1, .window_start = 0 };
    var grid = try renderForkMenuToGrid(alloc, projection, 40, max_inline_rows);
    defer grid.deinit();
    try std.testing.expectEqual(@as(u16, 5), menuRowCount(projection, 40, max_inline_rows));
    const expected = [_][]const u8{
        "Fork 2  Select a prompt to fork before",
        "",
        "  1  Line one",
        "     Line four after blanks",
        "  2  (empty prompt)",
    };
    for (expected, 0..) |exp, row_index| {
        const line = try gridRow(grid, alloc, row_index);
        defer alloc.free(line);
        try std.testing.expectEqualStrings(exp, line);
    }
}

test "fork subagent question separates prompt, keeps prompt start when tight, and wraps when narrow" {
    const alloc = std.testing.allocator;
    const points = [_]ForkPoint{
        .{ .turn = 1, .prompt = @constCast("Second prompt with some extra words to see how it renders above the subagent question") },
    };
    const projection: ForkMenuProjection = .{ .points = &points, .selected = 0, .window_start = 0, .question = 1 };

    // Roomy 80 cols: header, gap, chosen prompt, gap, question.
    var wide = try renderForkMenuToGrid(alloc, projection, 80, max_inline_rows);
    defer wide.deinit();
    try std.testing.expectEqual(@as(u16, 6), menuRowCount(projection, 80, max_inline_rows));
    const expected_wide = [_][]const u8{
        "Fork",
        "",
        "  Second prompt with some extra words to see how it renders above the subagent",
        "  question",
        "",
        "  Bring 1 subagent into the fork?",
    };
    for (expected_wide, 0..) |exp, row_index| {
        const line = try gridRow(wide, alloc, row_index);
        defer alloc.free(line);
        try std.testing.expectEqualStrings(exp, line);
    }

    // Narrow 32 cols with 3-row budget: keeps the start of the prompt (with ellipsis) and wraps the full question.
    var narrow3 = try renderForkMenuToGrid(alloc, projection, 32, 3);
    defer narrow3.deinit();
    try std.testing.expectEqual(@as(u16, 3), menuRowCount(projection, 32, 3));
    const p0 = try gridRow(narrow3, alloc, 0);
    defer alloc.free(p0);
    try std.testing.expect(std.mem.startsWith(u8, p0, "  Second prompt"));
    try std.testing.expect(std.mem.endsWith(u8, p0, "…"));
    const q0 = try gridRow(narrow3, alloc, 1);
    defer alloc.free(q0);
    const q1 = try gridRow(narrow3, alloc, 2);
    defer alloc.free(q1);
    try std.testing.expectEqualStrings("  Bring 1 subagent into the", q0);
    try std.testing.expectEqualStrings("  fork?", q1);
}

test "fork menu aligns two-digit numbers and handles wide, combining, and escape-bearing prompts on VT grid" {
    const alloc = std.testing.allocator;
    var points: [10]ForkPoint = undefined;
    for (0..9) |i| points[i] = .{ .turn = i + 1, .prompt = @constCast("short") };
    points[9] = .{ .turn = 10, .prompt = @constCast("日本語 café\u{0301} \x1b[31mred\x1b[0m\nsecond line") };
    const projection: ForkMenuProjection = .{ .points = &points, .selected = 9, .window_start = 8 };

    var grid = try renderForkMenuToGrid(alloc, projection, 40, 6);
    defer grid.deinit();
    const row_8 = try gridRow(grid, alloc, 2);
    defer alloc.free(row_8);
    const row_9 = try gridRow(grid, alloc, 3);
    defer alloc.free(row_9);
    const row_10_a = try gridRow(grid, alloc, 4);
    defer alloc.free(row_10_a);
    const row_10_b = try gridRow(grid, alloc, 5);
    defer alloc.free(row_10_b);
    try std.testing.expectEqualStrings("   8  short", row_8);
    try std.testing.expectEqualStrings("   9  short", row_9);
    try std.testing.expect(std.mem.startsWith(u8, row_10_a, "  10  日本語"));
    try std.testing.expect(std.mem.find(u8, row_10_a, "\x1b[") == null);
    try std.testing.expectEqualStrings("      second line", row_10_b);
    try std.testing.expectEqual(@as(u16, 0), menuRowCount(projection, 0, max_inline_rows));
}

test "fork menu narrow hint keeps fork at 32 columns and reaches compact fork variant" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { width: u16, expected: []const u8 }{
        .{ .width = 80, .expected = "↑↓ navigate     enter fork     esc close" },
        .{ .width = 34, .expected = "↑↓ navigate  enter fork  esc close" },
        .{ .width = 32, .expected = "↑↓ move  enter fork  esc" },
        .{ .width = 21, .expected = "enter fork  esc close" },
        .{ .width = 9, .expected = "enter esc" },
    };
    for (cases) |case| {
        var row = try input_presentation.composeVariantHintRow(alloc, case.width, false, &list_hint_variants);
        defer row.deinit(alloc);
        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(alloc);
        var i: usize = 0;
        while (i < row.items.len) {
            if (row.items[i] == 0x1b) {
                i = std.mem.findScalarPos(u8, row.items, i, 'm').? + 1;
                continue;
            }
            try plain.append(alloc, row.items[i]);
            i += 1;
        }
        try std.testing.expectEqualStrings(case.expected, plain.items);
    }
}
