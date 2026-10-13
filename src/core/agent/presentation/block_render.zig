const std = @import("std");
const Allocator = std.mem.Allocator;
const display_width = @import("../../shared/display_width.zig");
const ansi = @import("ansi.zig");
const tu = @import("text_util.zig");
const bp = @import("block_parse.zig");
const payload = @import("payload.zig");
const inline_render = @import("inline_render.zig");

pub fn writeHeading(
    alloc: Allocator,
    level: usize,
    content: []const u8,
    out: *std.ArrayList(u8),
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !void {
    switch (level) {
        1 => {
            try out.appendSlice(alloc, ansi.bold_open);
            try out.appendSlice(alloc, ansi.underline_open);
        },
        2 => try out.appendSlice(alloc, ansi.bold_open),
        3 => try out.appendSlice(alloc, ansi.underline_open),
        4 => {
            try out.appendSlice(alloc, ansi.bold_open);
            try out.appendSlice(alloc, ansi.dim_open);
        },
        5 => {
            try out.appendSlice(alloc, ansi.dim_open);
            try out.appendSlice(alloc, ansi.underline_open);
        },
        6 => try out.appendSlice(alloc, ansi.dim_open),
        else => unreachable,
    }
    try inline_render.writeInlineNoBold(
        alloc,
        content,
        out,
        level == 1 or level == 3 or level == 5,
        footnotes,
        link_id,
    );
    switch (level) {
        1 => {
            try out.appendSlice(alloc, ansi.underline_close);
            try out.appendSlice(alloc, ansi.bold_close);
        },
        2, 4, 6 => try out.appendSlice(alloc, ansi.bold_close),
        3 => try out.appendSlice(alloc, ansi.underline_close),
        5 => {
            try out.appendSlice(alloc, ansi.underline_close);
            try out.appendSlice(alloc, ansi.dim_close);
        },
        else => unreachable,
    }
}

pub fn writeBlockquoteLine(
    alloc: Allocator,
    blockquote: bp.BlockquotePrefix,
    content: []const u8,
    line_has_lf: bool,
    out: *std.ArrayList(u8),
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !void {
    try out.appendNTimes(alloc, ' ', blockquote.indent);
    for (0..blockquote.depth) |_| try ansi.writeDim(alloc, out, ansi.vertical_rule_prefix);
    try writeQuotedBlockContent(alloc, content, line_has_lf, out, footnotes, link_id);
}

/// Renders headings and list items inside a blockquote with their usual
/// styling; everything else is inline prose.
fn writeQuotedBlockContent(
    alloc: Allocator,
    content: []const u8,
    line_has_lf: bool,
    out: *std.ArrayList(u8),
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !void {
    if (bp.parseHeader(tu.withoutTerminalHardBreakMarker(content, line_has_lf))) |header| {
        try writeHeading(alloc, header.level, header.content, out, footnotes, link_id);
        return;
    }
    if (try writeListLine(alloc, content, line_has_lf, out, footnotes, link_id)) return;
    try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(content, line_has_lf), out, false, footnotes, link_id);
}

/// Renders an unordered, ordered, or task list line without a trailing
/// newline. Returns false when `line` is not a list item.
pub fn writeListLine(
    alloc: Allocator,
    line: []const u8,
    line_has_lf: bool,
    out: *std.ArrayList(u8),
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !bool {
    if (bp.parseUnorderedList(line)) |parsed| {
        try out.appendSlice(alloc, parsed.indent);
        if (bp.parseTaskListItem(parsed.content)) |task| {
            try writeTaskListMarker(alloc, out, task);
            try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(task.content, line_has_lf), out, false, footnotes, link_id);
            return true;
        }
        try ansi.writeDim(alloc, out, ansi.bullet_marker);
        try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(parsed.content, line_has_lf), out, false, footnotes, link_id);
        return true;
    }
    if (bp.parseOrderedList(line)) |parsed| {
        try out.appendSlice(alloc, parsed.indent);
        try ansi.writeDim(alloc, out, parsed.marker);
        try out.append(alloc, ' ');
        if (bp.parseTaskListItem(parsed.content)) |task| {
            try writeTaskListMarker(alloc, out, task);
            try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(task.content, line_has_lf), out, false, footnotes, link_id);
            return true;
        }
        try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(parsed.content, line_has_lf), out, false, footnotes, link_id);
        return true;
    }
    return false;
}

pub fn writeDefinitionLine(
    alloc: Allocator,
    body: []const u8,
    line_has_lf: bool,
    out: *std.ArrayList(u8),
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !void {
    try ansi.writeDim(alloc, out, "  ");
    try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(body, line_has_lf), out, false, footnotes, link_id);
    try out.append(alloc, '\n');
}

pub fn writeTaskListMarker(alloc: Allocator, out: *std.ArrayList(u8), task: bp.ParsedTaskListItem) !void {
    if (task.completed) {
        try out.appendSlice(alloc, ansi.task_completed_open);
        try out.appendSlice(alloc, ansi.task_completed_marker);
        try out.appendSlice(alloc, ansi.task_completed_close);
        if (task.has_separator) try out.append(alloc, ' ');
        return;
    }

    try out.appendSlice(alloc, ansi.dim_open);
    try out.appendSlice(alloc, ansi.task_pending_marker);
    if (task.has_separator) try out.append(alloc, ' ');
    try out.appendSlice(alloc, ansi.dim_close);
}

// Width excludes ANSI escape bytes so table dividers stay aligned.
const RenderedCell = struct {
    bytes: std.ArrayList(u8),
    width: usize,
};

const RenderedRow = std.ArrayList(RenderedCell);
const RenderedTable = std.ArrayList(RenderedRow);

pub fn renderTable(
    alloc: Allocator,
    buf: []const u8,
    out: *std.ArrayList(u8),
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !void {
    var table: RenderedTable = .empty;
    defer deinitRenderedTable(alloc, &table);

    try parseAndRenderRows(alloc, buf, &table, footnotes, link_id);

    const col_count = maxRowLen(table.items);
    if (table.items.len == 0 or col_count == 0) return;

    const widths = try alloc.alloc(usize, col_count);
    defer alloc.free(widths);
    computeColumnWidths(table.items, widths);

    const alignments = try alloc.alloc(payload.TableColumnAlign, col_count);
    defer alloc.free(alignments);
    parseColumnAlignments(alloc, buf, alignments);

    for (table.items, 0..) |row, row_idx| {
        const is_header = row_idx == 0;
        try writeTableRow(alloc, row.items, widths, alignments, is_header, out);
        if (is_header) try writeTableSeparator(alloc, widths, out);
    }
}

fn parseAndRenderRows(
    alloc: Allocator,
    buf: []const u8,
    table: *RenderedTable,
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !void {
    var line_idx: usize = 0;
    var start: usize = 0;
    while (start < buf.len) {
        const end = std.mem.findScalarPos(u8, buf, start, '\n') orelse buf.len;
        defer {
            line_idx += 1;
            start = end + 1;
        }
        if (line_idx == 1) continue;

        var raw: std.ArrayList([]const u8) = .empty;
        defer raw.deinit(alloc);
        try splitCells(buf[start..end], alloc, &raw);

        var row = try renderRowCells(alloc, raw.items, footnotes, link_id);
        errdefer deinitRenderedRow(alloc, &row);
        try table.append(alloc, row);
    }
}

fn renderRowCells(
    alloc: Allocator,
    raw_cells: []const []const u8,
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !RenderedRow {
    var row: RenderedRow = .empty;
    errdefer deinitRenderedRow(alloc, &row);

    for (raw_cells) |raw_cell| {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(alloc);
        try inline_render.writeInline(alloc, raw_cell, &bytes, false, footnotes, link_id);
        const width = display_width.visibleWidthIgnoringAnsi(bytes.items);
        try row.append(alloc, .{ .bytes = bytes, .width = width });
    }
    return row;
}

fn splitCells(line: []const u8, alloc: Allocator, cells: *std.ArrayList([]const u8)) !void {
    var rest = tu.leftTrim(line);
    if (rest.len > 0 and rest[0] == '|') rest = rest[1..];
    while (rest.len > 0 and (rest[rest.len - 1] == ' ' or rest[rest.len - 1] == '\t')) {
        rest = rest[0 .. rest.len - 1];
    }
    if (rest.len > 0 and rest[rest.len - 1] == '|' and !tu.isEscapedPunctuationAt(rest, rest.len - 1)) {
        rest = rest[0 .. rest.len - 1];
    }

    var cell_start: usize = 0;
    var i: usize = 0;
    while (i <= rest.len) : (i += 1) {
        if (i == rest.len or (rest[i] == '|' and !tu.isEscapedPunctuationAt(rest, i))) {
            const cell = std.mem.trim(u8, rest[cell_start..i], " \t");
            try cells.append(alloc, cell);
            cell_start = i + 1;
        }
    }
}

fn computeColumnWidths(rows: []const RenderedRow, widths: []usize) void {
    @memset(widths, 0);
    for (rows) |row| {
        for (row.items, 0..) |cell, col| {
            if (cell.width > widths[col]) widths[col] = cell.width;
        }
    }
}

fn maxRowLen(rows: []const RenderedRow) usize {
    var max: usize = 0;
    for (rows) |row| {
        if (row.items.len > max) max = row.items.len;
    }
    return max;
}

// ANSI escape bytes do not contribute to table column width.
fn writeTableRow(
    alloc: Allocator,
    cells: []const RenderedCell,
    widths: []const usize,
    alignments: []const payload.TableColumnAlign,
    is_header: bool,
    out: *std.ArrayList(u8),
) !void {
    for (widths, 0..) |col_width, col| {
        if (col > 0) try out.appendSlice(alloc, ansi.table_column_sep);

        const col_align: payload.TableColumnAlign = if (is_header) .left else alignments[col];

        if (col < cells.len) {
            const cell = cells[col];
            const pad = col_width -| cell.width;
            const left_pad: usize = switch (col_align) {
                .left => 0,
                .right => pad,
                .center => pad / 2,
            };
            const right_pad: usize = pad - left_pad;

            try out.appendNTimes(alloc, ' ', left_pad);
            if (is_header) {
                try writeTableHeaderCell(alloc, out, cell.bytes.items);
            } else {
                try out.appendSlice(alloc, cell.bytes.items);
            }
            try out.appendNTimes(alloc, ' ', right_pad);
        } else {
            try out.appendNTimes(alloc, ' ', col_width);
        }
    }
    try out.append(alloc, '\n');
}

pub fn writeTableHeaderCell(alloc: Allocator, out: *std.ArrayList(u8), cell: []const u8) !void {
    try out.appendSlice(alloc, ansi.bold_open);
    var remaining = cell;
    while (std.mem.find(u8, remaining, ansi.bold_close)) |close_index| {
        try out.appendSlice(alloc, remaining[0..close_index]);
        try out.appendSlice(alloc, ansi.bold_close);
        try out.appendSlice(alloc, ansi.bold_open);
        remaining = remaining[close_index + ansi.bold_close.len ..];
    }
    try out.appendSlice(alloc, remaining);
    try out.appendSlice(alloc, ansi.bold_close);
}

fn writeTableSeparator(alloc: Allocator, widths: []const usize, out: *std.ArrayList(u8)) !void {
    for (widths, 0..) |col_width, col| {
        if (col > 0) try out.appendSlice(alloc, ansi.table_junction);
        var remaining = col_width;
        while (remaining > 0) : (remaining -= 1) try out.appendSlice(alloc, ansi.table_horiz);
    }
    try out.append(alloc, '\n');
}

fn parseColumnAlignments(alloc: Allocator, buf: []const u8, alignments: []payload.TableColumnAlign) void {
    @memset(alignments, .left);
    const sep_line = tu.nthLine(buf, 1) orelse return;

    var cells: std.ArrayList([]const u8) = .empty;
    defer cells.deinit(alloc);
    splitCells(sep_line, alloc, &cells) catch return;

    for (cells.items, 0..) |cell, col| {
        if (col >= alignments.len) break;
        const trimmed = std.mem.trim(u8, cell, " \t");
        if (trimmed.len == 0) continue;
        const starts = trimmed[0] == ':';
        const ends = trimmed[trimmed.len - 1] == ':';
        alignments[col] = if (starts and ends) .center else if (ends) .right else .left;
    }
}

pub fn renderTablePayload(alloc: Allocator, table: payload.TablePayload, out: *std.ArrayList(u8)) !void {
    if (table.rows.len == 0 or table.column_count == 0) return;

    const widths = try alloc.alloc(usize, table.column_count);
    defer alloc.free(widths);
    computeTablePayloadWidths(table.rows, widths);

    for (table.rows, 0..) |row, row_idx| {
        const is_header = row_idx == 0;
        try writeTablePayloadRow(alloc, row.cells, widths, table.alignments, is_header, out);
        if (is_header) try writeTableSeparator(alloc, widths, out);
    }
}

fn computeTablePayloadWidths(rows: []const payload.TableRow, widths: []usize) void {
    @memset(widths, 0);
    for (rows) |row| {
        for (row.cells, 0..) |cell, col| {
            widths[col] = @max(widths[col], display_width.visibleWidthIgnoringAnsi(cell));
        }
    }
}

fn writeTablePayloadRow(
    alloc: Allocator,
    cells: []const []u8,
    widths: []const usize,
    alignments: []const payload.TableColumnAlign,
    is_header: bool,
    out: *std.ArrayList(u8),
) !void {
    for (widths, 0..) |col_width, col| {
        if (col > 0) try out.appendSlice(alloc, ansi.table_column_sep);

        const col_align: payload.TableColumnAlign = if (is_header) .left else alignments[col];
        if (col < cells.len) {
            const cell = cells[col];
            const pad = col_width -| display_width.visibleWidthIgnoringAnsi(cell);
            const left_pad: usize = switch (col_align) {
                .left => 0,
                .right => pad,
                .center => pad / 2,
            };
            try out.appendNTimes(alloc, ' ', left_pad);
            if (is_header) {
                try writeTableHeaderCell(alloc, out, cell);
            } else {
                try out.appendSlice(alloc, cell);
            }
            try out.appendNTimes(alloc, ' ', pad - left_pad);
        } else {
            try out.appendNTimes(alloc, ' ', col_width);
        }
    }
    try out.append(alloc, '\n');
}

fn maxTablePayloadRowLen(rows: []const payload.TableRow) usize {
    var max: usize = 0;
    for (rows) |row| max = @max(max, row.cells.len);
    return max;
}

pub fn parseTablePayload(alloc: Allocator, buf: []const u8, link_id: *u32) !payload.TablePayload {
    return parseTablePayloadWithFootnotes(alloc, buf, null, link_id);
}

pub fn parseTablePayloadWithFootnotes(
    alloc: Allocator,
    buf: []const u8,
    footnotes: ?*const payload.FootnoteSink,
    link_id: *u32,
) !payload.TablePayload {
    var rows: std.ArrayList(payload.TableRow) = .empty;
    errdefer {
        payload.deinitTableRows(alloc, rows.items);
        rows.deinit(alloc);
    }

    var line_idx: usize = 0;
    var start: usize = 0;
    while (start < buf.len) {
        const end = std.mem.findScalarPos(u8, buf, start, '\n') orelse buf.len;
        defer {
            line_idx += 1;
            start = end + 1;
        }
        if (line_idx == 1) continue;

        var raw: std.ArrayList([]const u8) = .empty;
        defer raw.deinit(alloc);
        try splitCells(buf[start..end], alloc, &raw);

        var rendered_cells: std.ArrayList([]u8) = .empty;
        errdefer {
            for (rendered_cells.items) |cell| alloc.free(cell);
            rendered_cells.deinit(alloc);
        }
        try rendered_cells.ensureTotalCapacity(alloc, raw.items.len);
        for (raw.items) |raw_cell| {
            var rendered: std.ArrayList(u8) = .empty;
            errdefer rendered.deinit(alloc);
            try inline_render.writeInline(alloc, raw_cell, &rendered, false, footnotes, link_id);
            rendered_cells.appendAssumeCapacity(try rendered.toOwnedSlice(alloc));
        }

        const cells = try rendered_cells.toOwnedSlice(alloc);

        var handed_off = false;
        errdefer if (!handed_off) {
            for (cells) |cell| alloc.free(cell);
            alloc.free(cells);
        };
        try rows.append(alloc, .{ .cells = cells });
        handed_off = true;
    }

    const column_count = maxTablePayloadRowLen(rows.items);
    const alignments = try alloc.alloc(payload.TableColumnAlign, column_count);
    errdefer alloc.free(alignments);
    parseColumnAlignments(alloc, buf, alignments);
    return .{
        .rows = try rows.toOwnedSlice(alloc),
        .alignments = alignments,
        .column_count = column_count,
    };
}

fn deinitRenderedTable(alloc: Allocator, table: *RenderedTable) void {
    for (table.items) |*row| deinitRenderedRow(alloc, row);
    table.deinit(alloc);
}

fn deinitRenderedRow(alloc: Allocator, row: *RenderedRow) void {
    for (row.items) |*cell| cell.bytes.deinit(alloc);
    row.deinit(alloc);
}

pub fn writeFootnoteDefinitionMarker(alloc: Allocator, out: *std.ArrayList(u8), number: usize) !void {
    var marker: [32]u8 = undefined;
    const bytes = try std.mem.print(&marker, "[{d}] ", .{number});
    try ansi.writeDim(alloc, out, bytes);
}

pub fn writeFootnoteBody(
    alloc: Allocator,
    body: []const u8,
    out: *std.ArrayList(u8),
    sink: *const payload.FootnoteSink,
    number: usize,
    link_id: *u32,
) !void {
    var start: usize = 0;
    var is_first = true;
    while (start <= body.len) {
        const end = std.mem.findScalarPos(u8, body, start, '\n') orelse body.len;
        if (!is_first) {
            try out.append(alloc, '\n');
            var marker: [32]u8 = undefined;
            const marker_bytes = try std.mem.print(&marker, "[{d}] ", .{number});
            @memset(marker[0..marker_bytes.len], ' ');
            try ansi.writeDim(alloc, out, marker[0..marker_bytes.len]);
        }
        try inline_render.writeInline(alloc, body[start..end], out, false, sink, link_id);
        if (end == body.len) break;
        is_first = false;
        start = end + 1;
    }
    try out.append(alloc, '\n');
}

pub fn renderCodeBlockPayload(
    alloc: Allocator,
    block: payload.CodeBlockPayload,
    out: *std.ArrayList(u8),
) !void {
    var start: usize = 0;
    while (start < block.code.len) {
        const end = std.mem.findScalarPos(u8, block.code, start, '\n') orelse block.code.len;
        try ansi.writeDim(alloc, out, ansi.vertical_rule_prefix);
        try out.appendSlice(alloc, block.code[start..end]);
        try out.append(alloc, '\n');
        if (end == block.code.len) break;
        start = end + 1;
    }
}
