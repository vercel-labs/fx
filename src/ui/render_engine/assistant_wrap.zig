const std = @import("std");
const build_checkpoint = @import("build_checkpoint.zig");
const display_width = @import("../../core/shared/display_width.zig");
const assistant_pacer = @import("../assistant/pacer.zig");

const Allocator = std.mem.Allocator;

/// A pathological combining-mark run gets a physical row boundary at this
/// byte count. The source bytes remain exact while every retained row stays
/// bounded for compact and full-view projection.
pub const literal_command_zero_width_row_byte_limit: usize = 256;

const WordBreak = struct {
    start: usize,
    end: usize,
    sgr: assistant_pacer.SgrState,
    hyperlink: ?[]const u8,
    has_preceding_word: bool,
};

/// The last two space runs on the current row, kept as reflow points for
/// overflow wrapping and orphan avoidance.
const WordBreaks = struct {
    last: ?WordBreak = null,
    previous: ?WordBreak = null,

    /// Extends `last` when adjacent; otherwise demotes it to `previous`.
    fn record(self: *WordBreaks, word_break: WordBreak) void {
        if (self.last) |*last| {
            if (last.end == word_break.start) {
                last.end = word_break.end;
                return;
            }
            self.previous = last.*;
        }
        self.last = word_break;
    }
};

const Osc8Update = union(enum) {
    open: []const u8,
    close,
};

const AssistantContinuation = union(enum) {
    list_indent: usize,
    blockquote: struct {
        indent: usize,
        depth: usize,
    },
};

/// Reflow assistant text to fit within `cols` while preserving inline
/// SGR attributes and OSC 8 links across wrap boundaries. Paragraphs wrap at whitespace
/// and move a preceding word down when that avoids a single-word tail.
/// Pre-existing hard newlines in `text` are honoured. The returned slice is
/// owned by the caller and freed with `alloc`.
pub fn wrapAssistantText(alloc: Allocator, text: []const u8, cols: u16) ![]u8 {
    return wrapAssistantTextWithBaseGutter(alloc, text, cols, 0, false, false, null, null);
}

fn wrapAssistantTextWithBaseGutter(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
    base_gutter: u16,
    replace_wide_runes_at_one_content_col: bool,
    literal_command: bool,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
    finalized_prefix_bytes: ?*usize,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (finalized_prefix_bytes) |bytes| bytes.* = 0;
    var finalized_source_end: usize = 0;
    if (finalized_prefix_bytes != null) {
        if (std.mem.findScalarLast(u8, text, '\n')) |newline| {
            finalized_source_end = newline + 1;
        }
    }

    if (cols == 0) {
        return out.toOwnedSlice(alloc);
    }
    if (text.len == 0) {
        if (literal_command) {
            try appendAssistantRowStart(
                alloc,
                &out,
                base_gutter,
                .{},
                null,
                true,
            );
        }
        return out.toOwnedSlice(alloc);
    }

    var sgr: assistant_pacer.SgrState = .{};
    var hyperlink: ?[]const u8 = null;
    const content_cols = cols -| base_gutter;
    var col: u16 = base_gutter + 1;
    var continuation = if (literal_command) null else assistantContinuation(text, 0);
    var word_breaks: WordBreaks = .{};
    var has_word_on_row = false;
    var row_has_content = false;
    var zero_width_run_bytes: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        try build_checkpoint.tick(checkpoint);
        if (!row_has_content and !literal_command) {
            if (infeasibleMarkerEnd(text, i, base_gutter, cols)) |marker_end| {
                i = marker_end;
                continue;
            }
        }

        const ch = text[i];

        if (ch == 0x1b) {
            const end = display_width.ansiSequenceEnd(text, i);
            if (end <= i) {
                // Preserve an incomplete trailing escape without stalling the loop.
                try out.appendSlice(alloc, text[i..]);
                break;
            }
            const seq = text[i..end];
            sgr.apply(seq);
            if (osc8Update(seq)) |update| switch (update) {
                .open => |open| hyperlink = open,
                .close => hyperlink = null,
            };
            if (base_gutter == 0 or row_has_content) try out.appendSlice(alloc, seq);
            i = end;
            continue;
        }

        if (ch == '\r' or ch == '\n') {
            if (literal_command and !row_has_content) {
                try appendAssistantRowStart(alloc, &out, base_gutter, sgr, hyperlink, true);
            }
            if (base_gutter > 0 and row_has_content) try closeAssistantRowStyles(alloc, &out, sgr, hyperlink);
            try out.append(alloc, ch);
            col = base_gutter + 1;
            i += 1;
            if (finalized_prefix_bytes) |bytes| {
                if (i == finalized_source_end) bytes.* = out.items.len;
            }
            continuation = if (literal_command) null else assistantContinuation(text, i);
            word_breaks = .{};
            has_word_on_row = false;
            row_has_content = false;
            zero_width_run_bytes = 0;
            continue;
        }
        if (ch == '\t') {
            if (base_gutter > 0 and !row_has_content) {
                try appendAssistantRowStart(alloc, &out, base_gutter, sgr, hyperlink, literal_command);
                row_has_content = true;
            }
            const next_col = display_width.nextTabStopColumn(col, cols);
            try out.appendNTimes(alloc, ' ', next_col -| col);
            col = @max(col, next_col);
            i += 1;
            zero_width_run_bytes = 0;
            continue;
        }
        if (ch < 32) {
            if (base_gutter == 0 or row_has_content) try out.append(alloc, ch);
            i += 1;
            continue;
        }

        const unit = display_width.displayUnitAt(text, i);
        const w_usize = unit.cell_width;
        if (w_usize == 0) {
            if (literal_command and
                zero_width_run_bytes +| unit.byte_len > literal_command_zero_width_row_byte_limit)
            {
                col = try appendAssistantContinuation(
                    alloc,
                    &out,
                    sgr,
                    hyperlink,
                    continuation,
                    cols,
                    base_gutter,
                    1,
                    true,
                );
                word_breaks = .{};
                has_word_on_row = false;
                row_has_content = true;
                zero_width_run_bytes = 0;
            }
            if (base_gutter > 0 and !row_has_content) {
                try appendAssistantRowStart(alloc, &out, base_gutter, sgr, hyperlink, literal_command);
                row_has_content = true;
            }
            try out.appendSlice(alloc, text[i .. i + unit.byte_len]);
            if (literal_command) zero_width_run_bytes += unit.byte_len;
            i += unit.byte_len;
            continue;
        } else if (literal_command) {
            zero_width_run_bytes = 0;
        }
        const replace_wide_unit = replace_wide_runes_at_one_content_col and content_cols == 1 and w_usize == 2;
        const w: u16 = if (replace_wide_unit) 1 else @intCast(w_usize);

        if (ch == ' ' and display_width.shouldWrapAt(col, w, cols)) {
            var moved_for_orphan = false;
            if (word_breaks.last) |word_break| {
                const next_word_start = i + unit.byte_len;
                if (remainingWordWidth(text, next_word_start) > 0 and
                    isFinalWordOnLine(text, next_word_start) and
                    wordBreakFits(out.items[word_break.end..], text, next_word_start, continuation, cols, base_gutter))
                {
                    const next_width = firstVisibleWidth(text[next_word_start..]) orelse w;
                    if (try reflowAtWordBreak(
                        alloc,
                        &out,
                        word_break,
                        continuation,
                        cols,
                        base_gutter,
                        next_width,
                        literal_command,
                    )) |reflowed_col| {
                        col = reflowed_col;
                        word_breaks = .{};
                        has_word_on_row = true;
                        row_has_content = true;
                        moved_for_orphan = true;
                    }
                }
            }
            if (!moved_for_orphan) {
                col = try appendAssistantContinuation(
                    alloc,
                    &out,
                    sgr,
                    hyperlink,
                    continuation,
                    cols,
                    base_gutter,
                    w,
                    literal_command,
                );
                word_breaks = .{};
                has_word_on_row = false;
                row_has_content = true;
                i += unit.byte_len;
                continue;
            }
        }

        if (display_width.shouldWrapAt(col, w, cols)) {
            if (word_breaks.last) |word_break| {
                var break_to_use = word_break;
                if (word_breaks.previous) |previous| {
                    if (previous.has_preceding_word and
                        isFinalWordOnLine(text, i) and
                        wordBreakFits(out.items[previous.end..], text, i, continuation, cols, base_gutter))
                    {
                        break_to_use = previous;
                    }
                }

                if (try reflowAtWordBreak(
                    alloc,
                    &out,
                    break_to_use,
                    continuation,
                    cols,
                    base_gutter,
                    w,
                    literal_command,
                )) |reflowed_col| {
                    col = reflowed_col;
                    word_breaks = .{};
                    row_has_content = true;
                }
            }
        }

        if (display_width.shouldWrapAt(col, w, cols)) {
            col = try appendAssistantContinuation(
                alloc,
                &out,
                sgr,
                hyperlink,
                continuation,
                cols,
                base_gutter,
                w,
                literal_command,
            );
            word_breaks = .{};
            has_word_on_row = false;
            row_has_content = true;
        }

        if (base_gutter > 0 and !row_has_content) {
            try appendAssistantRowStart(alloc, &out, base_gutter, sgr, hyperlink, literal_command);
            row_has_content = true;
        }

        const space_start = out.items.len;
        if (replace_wide_unit) {
            try out.append(alloc, '?');
        } else {
            try out.appendSlice(alloc, text[i .. i + unit.byte_len]);
        }
        col += w;
        if (ch == ' ' and has_word_on_row and !isContinuationMarkerSeparator(col - 1, continuation, base_gutter)) {
            word_breaks.record(.{
                .start = space_start,
                .end = out.items.len,
                .sgr = sgr,
                .hyperlink = hyperlink,
                .has_preceding_word = word_breaks.last != null,
            });
        } else if (ch != ' ') {
            has_word_on_row = true;
        }
        i += unit.byte_len;
    }

    if (literal_command and !row_has_content) {
        try appendAssistantRowStart(alloc, &out, base_gutter, sgr, hyperlink, true);
    }

    return out.toOwnedSlice(alloc);
}

fn closeAssistantRowStyles(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    sgr: assistant_pacer.SgrState,
    hyperlink: ?[]const u8,
) !void {
    if (sgr.isActive()) try out.appendSlice(alloc, "\x1b[0m");
    if (hyperlink != null) try out.appendSlice(alloc, "\x1b]8;;\x1b\\");
}

fn appendAssistantRowStart(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    base_gutter: u16,
    sgr: assistant_pacer.SgrState,
    hyperlink: ?[]const u8,
    literal_command: bool,
) !void {
    if (literal_command and base_gutter >= 2) {
        try out.appendSlice(alloc, "│ ");
        try out.appendNTimes(alloc, ' ', base_gutter - 2);
    } else {
        try out.appendNTimes(alloc, ' ', base_gutter);
    }
    if (sgr.isActive()) {
        var reopen: [64]u8 = undefined;
        const n = sgr.writeOpens(reopen[0..]);
        try out.appendSlice(alloc, reopen[0..n]);
    }
    if (hyperlink) |open| try out.appendSlice(alloc, open);
}

pub fn gutterWidth(cols: u16) u16 {
    return if (cols >= 3) 2 else if (cols == 2) 1 else 0;
}

pub fn prefixStructuralRows(alloc: Allocator, bytes: []const u8, gutter: u16) ![]u8 {
    if (gutter == 0 or bytes.len == 0) return alloc.dupe(u8, bytes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var line_start: usize = 0;
    while (line_start < bytes.len) {
        const newline = std.mem.indexOfScalarPos(u8, bytes, line_start, '\n');
        const line_end = newline orelse bytes.len;
        if (firstVisibleWidth(bytes[line_start..line_end]) != null) {
            try out.appendNTimes(alloc, ' ', gutter);
        }
        try out.appendSlice(alloc, bytes[line_start..line_end]);
        if (newline) |_| try out.append(alloc, '\n');
        line_start = line_end + 1;
    }
    return out.toOwnedSlice(alloc);
}

pub fn wrapTranscriptAssistantTextInterruptible(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) ![]u8 {
    return wrapAssistantTextWithBaseGutter(
        alloc,
        text,
        cols,
        gutterWidth(cols),
        true,
        false,
        checkpoint,
        null,
    );
}

/// `bytes` is owned by the caller. `finalized_prefix_bytes` ends after the
/// last source hard newline and excludes soft wraps from the unfinished line.
pub const TranscriptAssistantWrap = struct {
    bytes: []u8,
    finalized_prefix_bytes: usize,
};

pub fn wrapTranscriptAssistantTextWithFinalityInterruptible(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) !TranscriptAssistantWrap {
    var finalized_prefix_bytes: usize = 0;
    const bytes = try wrapAssistantTextWithBaseGutter(
        alloc,
        text,
        cols,
        gutterWidth(cols),
        true,
        false,
        checkpoint,
        &finalized_prefix_bytes,
    );
    return .{
        .bytes = bytes,
        .finalized_prefix_bytes = finalized_prefix_bytes,
    };
}

/// Reflow canonical command output as literal terminal text. Every physical
/// row owns its gutter; Markdown continuation markers are deliberately not
/// interpreted, and tabs advance to the terminal's absolute eight-column
/// stops. The returned slice is owned by the caller.
pub fn wrapLiteralCommandOutput(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
) ![]u8 {
    if (cols == 0) return alloc.alloc(u8, 0);
    const gutter = if (cols >= 3) @as(u16, 2) else @as(u16, 0);
    return wrapAssistantTextWithBaseGutter(
        alloc,
        text,
        cols,
        gutter,
        true,
        true,
        null,
        null,
    );
}

/// Reflows literal tool detail with the three-cell rail used by Ctrl-O.
pub fn wrapLiteralToolOutput(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
) ![]u8 {
    return wrapLiteralToolOutputInterruptible(alloc, text, cols, null) catch |err| switch (err) {
        error.InputPending => unreachable,
        else => |other| return other,
    };
}

pub fn wrapLiteralToolOutputInterruptible(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
    checkpoint: ?*build_checkpoint.BuildCheckpoint,
) ![]u8 {
    if (cols == 0) return alloc.alloc(u8, 0);
    const gutter = if (cols >= 4) @as(u16, 3) else if (cols >= 3) @as(u16, 2) else @as(u16, 0);
    return wrapAssistantTextWithBaseGutter(
        alloc,
        text,
        cols,
        gutter,
        true,
        true,
        checkpoint,
        null,
    );
}

pub const LiteralCommandOutputPrefix = struct {
    bytes: []u8,
    has_more: bool,

    pub fn deinit(self: *LiteralCommandOutputPrefix, alloc: Allocator) void {
        alloc.free(self.bytes);
        self.* = undefined;
    }
};

/// Bounded compact projection. It retains three rows of lookahead so the
/// assistant wrapper's word/orphan decision for the admitted rows is stable,
/// but never scans or allocates in proportion to an oversized record.
pub fn wrapLiteralCommandOutputPrefix(
    alloc: Allocator,
    text: []const u8,
    cols: u16,
    row_limit: usize,
) !LiteralCommandOutputPrefix {
    if (row_limit == 0 or cols == 0) {
        return .{
            .bytes = try alloc.alloc(u8, 0),
            .has_more = text.len > 0,
        };
    }

    const lookahead_rows = row_limit +| 3;
    const source_end = literalLookaheadEnd(text, cols, lookahead_rows);
    const wrapped = try wrapLiteralCommandOutput(alloc, text[0..source_end], cols);
    defer alloc.free(wrapped);
    const prefix = literalPhysicalRowPrefix(wrapped, row_limit);
    return .{
        .bytes = try alloc.dupe(u8, prefix),
        .has_more = source_end < text.len or
            literalHardLineCount(wrapped) > row_limit,
    };
}

fn literalLookaheadEnd(text: []const u8, cols: u16, row_limit: usize) usize {
    const gutter: u16 = if (cols >= 3) 2 else 0;
    var col: u16 = gutter + 1;
    var rows: usize = 1;
    var zero_width_run_bytes: usize = 0;
    var index: usize = 0;
    while (index < text.len and rows <= row_limit) {
        const byte = text[index];
        if (byte == '\r' or byte == '\n') {
            rows += 1;
            col = gutter + 1;
            zero_width_run_bytes = 0;
            index += 1;
            continue;
        }
        if (byte == '\t') {
            col = display_width.nextTabStopColumn(col, cols);
            zero_width_run_bytes = 0;
            index += 1;
            continue;
        }
        const unit = display_width.displayUnitAt(text, index);
        const width_usize = unit.cell_width;
        if (width_usize == 0) {
            if (zero_width_run_bytes +| unit.byte_len > literal_command_zero_width_row_byte_limit) {
                rows += 1;
                col = gutter + 1;
                zero_width_run_bytes = 0;
                if (rows > row_limit) break;
            }
            zero_width_run_bytes += unit.byte_len;
            index += unit.byte_len;
            continue;
        }
        zero_width_run_bytes = 0;
        const width: u16 = @intCast(width_usize);
        if (display_width.shouldWrapAt(col, width, cols)) {
            rows += 1;
            col = gutter + 1;
            if (rows > row_limit) break;
        }
        col +|= width;
        index += unit.byte_len;
    }
    return index;
}

fn literalHardLineCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    return std.mem.count(u8, bytes, "\n") + 1;
}

fn literalPhysicalRowPrefix(bytes: []const u8, row_count: usize) []const u8 {
    if (row_count == 0) return bytes[0..0];
    var rows: usize = 1;
    for (bytes, 0..) |byte, index| {
        if (byte != '\n') continue;
        if (rows == row_count) return bytes[0..index];
        rows += 1;
    }
    return bytes;
}

fn appendAssistantContinuation(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    sgr: assistant_pacer.SgrState,
    hyperlink: ?[]const u8,
    continuation: ?AssistantContinuation,
    cols: u16,
    base_gutter: u16,
    next_width: u16,
    literal_command: bool,
) !u16 {
    try closeAssistantRowStyles(alloc, out, sgr, hyperlink);
    try out.append(alloc, '\n');

    if (literal_command and base_gutter >= 2) {
        try out.appendSlice(alloc, "│ ");
        try out.appendNTimes(alloc, ' ', base_gutter - 2);
    } else {
        try out.appendNTimes(alloc, ' ', base_gutter);
    }
    var col: u16 = base_gutter + 1;
    if (continuation) |prefix| {
        const indent = continuationWidth(prefix);
        const width: usize = cols;
        const total_indent = @as(usize, base_gutter) + indent;
        if (total_indent < width and @as(usize, next_width) <= width - total_indent) {
            switch (prefix) {
                .list_indent => try out.appendNTimes(alloc, ' ', indent),
                .blockquote => |blockquote| {
                    try out.appendNTimes(alloc, ' ', blockquote.indent);
                    for (0..blockquote.depth) |_| {
                        try out.appendSlice(alloc, "\x1b[2m\xe2\x94\x82 \x1b[22m");
                    }
                },
            }
            col = @intCast(total_indent + 1);
        }
    }
    if (sgr.isActive()) {
        var reopen: [64]u8 = undefined;
        const n = sgr.writeOpens(reopen[0..]);
        try out.appendSlice(alloc, reopen[0..n]);
    }
    if (hyperlink) |open| try out.appendSlice(alloc, open);
    return col;
}

fn reflowAtWordBreak(
    alloc: Allocator,
    out: *std.ArrayList(u8),
    word_break: WordBreak,
    continuation: ?AssistantContinuation,
    cols: u16,
    base_gutter: u16,
    next_width: u16,
    literal_command: bool,
) !?u16 {
    const suffix = out.items[word_break.end..];
    const suffix_width = display_width.visibleWidthIgnoringAnsi(suffix);
    const first_width = firstVisibleWidth(suffix) orelse next_width;
    const local_indent = if (continuation) |prefix| continuationWidth(prefix) else 0;
    const indent = @as(usize, base_gutter) + local_indent;
    if (indent >= cols or suffix_width + next_width > @as(usize, cols) - indent) return null;

    var replacement: std.ArrayList(u8) = .empty;
    defer replacement.deinit(alloc);
    const col = try appendAssistantContinuation(
        alloc,
        &replacement,
        word_break.sgr,
        word_break.hyperlink,
        continuation,
        cols,
        base_gutter,
        first_width,
        literal_command,
    );
    try out.replaceRange(alloc, word_break.start, word_break.end - word_break.start, replacement.items);
    return col + @as(u16, @intCast(suffix_width));
}

fn osc8Update(seq: []const u8) ?Osc8Update {
    if (!std.mem.startsWith(u8, seq, "\x1b]8;")) return null;
    const terminator_len: usize = if (seq.len > 0 and seq[seq.len - 1] == 0x07)
        1
    else if (seq.len >= 2 and seq[seq.len - 2] == 0x1b and seq[seq.len - 1] == '\\')
        2
    else
        return null;
    const payload = seq[4 .. seq.len - terminator_len];
    const separator = std.mem.indexOfScalar(u8, payload, ';') orelse return null;
    return if (separator + 1 == payload.len) .close else .{ .open = seq };
}

fn firstVisibleWidth(text: []const u8) ?u16 {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const end = display_width.ansiSequenceEnd(text, i);
            if (end <= i) return null;
            i = end;
            continue;
        }
        if (text[i] < 32) return null;
        const unit = display_width.displayUnitAt(text, i);
        if (unit.cell_width > 0) return @intCast(unit.cell_width);
        i += unit.byte_len;
    }
    return null;
}

/// Returns the end of a row-leading footnote or definition marker that cannot
/// fit within `cols` together with the next visible rune.
fn infeasibleMarkerEnd(text: []const u8, start: usize, base_gutter: u16, cols: u16) ?usize {
    const marker: MarkerPrefix = if (footnotePrefix(text, start)) |prefix|
        prefix
    else if (definitionPrefixEnd(text, start)) |end|
        .{ .end = end, .indent = 2 }
    else
        return null;
    const next_width = firstVisibleWidth(text[marker.end..]) orelse 1;
    if (@as(usize, base_gutter) + marker.indent + next_width <= cols) return null;
    return marker.end;
}

fn isContinuationMarkerSeparator(
    col_before_space: u16,
    continuation: ?AssistantContinuation,
    base_gutter: u16,
) bool {
    const prefix = continuation orelse return false;
    return col_before_space == base_gutter + continuationWidth(prefix);
}

fn wordBreakFits(
    suffix: []const u8,
    text: []const u8,
    word_start: usize,
    continuation: ?AssistantContinuation,
    cols: u16,
    base_gutter: u16,
) bool {
    const indent = @as(usize, base_gutter) + if (continuation) |prefix| continuationWidth(prefix) else 0;
    if (indent >= cols) return false;
    const available = @as(usize, cols) - indent;
    return display_width.visibleWidthIgnoringAnsi(suffix) + remainingWordWidth(text, word_start) <= available;
}

fn remainingWordWidth(text: []const u8, start: usize) usize {
    var width: usize = 0;
    var i = start;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const end = display_width.ansiSequenceEnd(text, i);
            if (end <= i) break;
            i = end;
            continue;
        }
        if (text[i] == ' ' or text[i] == '\r' or text[i] == '\n') break;
        const unit = display_width.displayUnitAt(text, i);
        width += unit.cell_width;
        i += unit.byte_len;
    }
    return width;
}

fn isFinalWordOnLine(text: []const u8, start: usize) bool {
    var i = start;
    var passed_current_word = false;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            const end = display_width.ansiSequenceEnd(text, i);
            if (end <= i) return true;
            i = end;
            continue;
        }
        if (text[i] == '\r' or text[i] == '\n') return true;
        if (text[i] == ' ') {
            passed_current_word = true;
            i += 1;
            continue;
        }
        if (passed_current_word) return false;
        const rune = display_width.decodeNextRune(text, i);
        i += rune.len;
    }
    return true;
}

fn continuationWidth(continuation: AssistantContinuation) usize {
    return switch (continuation) {
        .list_indent => |indent| indent,
        .blockquote => |blockquote| blockquote.indent + 2 * blockquote.depth,
    };
}

/// Recognizes MarkdownProcessor's list, definition, and blockquote prefixes, including
/// pacer-inserted dim reassertions between visible marker characters.
fn assistantContinuation(text: []const u8, line_start: usize) ?AssistantContinuation {
    if (listContinuationIndentWidth(text, line_start)) |indent| {
        return .{ .list_indent = indent };
    }
    if (definitionPrefixEnd(text, line_start) != null) {
        return .{ .list_indent = 2 };
    }
    if (footnotePrefix(text, line_start)) |prefix| {
        return .{ .list_indent = prefix.indent };
    }
    if (footnoteContinuationIndent(text, line_start)) |indent| {
        return .{ .list_indent = indent };
    }

    var i = line_start;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    const indent = i - line_start;
    var depth: usize = 0;
    while (blockquoteMarkerEnd(text, i)) |end| {
        depth += 1;
        i = end;
    }
    if (depth > 0) return .{ .blockquote = .{ .indent = indent, .depth = depth } };
    return if (proseIndent(text, line_start)) |width| .{ .list_indent = width } else null;
}

fn proseIndent(text: []const u8, line_start: usize) ?usize {
    var i = line_start;
    var width: usize = 0;
    var line_end: ?usize = null;
    while (i < text.len) {
        switch (text[i]) {
            ' ' => {
                width += 1;
                i += 1;
            },
            0x1b => {
                // Bound control parsing to this logical line, including incomplete tails.
                if (line_end == null) {
                    var end = i;
                    while (end < text.len and text[end] != '\r' and text[end] != '\n') : (end += 1) {}
                    line_end = end;
                }
                const sequence_end = display_width.ansiSequenceEnd(text[0..line_end.?], i);
                const seq = text[i..sequence_end];
                if (seq.len < 3) return null;
                const sgr = std.mem.startsWith(u8, seq, "\x1b[") and seq[seq.len - 1] == 'm';
                if (!sgr and osc8Update(seq) == null) return null;
                i = sequence_end;
            },
            0...8, 9...13, 14...26, 28...31, 127 => return null,
            else => return if (width > 0) width else null,
        }
    }
    return null;
}

fn definitionPrefixEnd(text: []const u8, start: usize) ?usize {
    const dim_open = "\x1b[2m";
    const dim_close = "\x1b[22m";

    var i = start;
    if (!std.mem.startsWith(u8, text[i..], dim_open)) return null;
    i += dim_open.len;
    i = skipPacerDimReassertions(text, i);
    if (i >= text.len or text[i] != ' ') return null;
    i += 1;
    i = skipPacerDimReassertions(text, i);
    if (i >= text.len or text[i] != ' ') return null;
    i += 1;
    i = skipPacerDimReassertions(text, i);
    if (!std.mem.startsWith(u8, text[i..], dim_close)) return null;
    return i + dim_close.len;
}

const MarkerPrefix = struct {
    end: usize,
    indent: usize,
};

fn footnotePrefix(text: []const u8, start: usize) ?MarkerPrefix {
    var i = footnoteDimOpenEnd(text, start) orelse return null;
    i = skipPacerDimReassertions(text, i);
    if (i >= text.len or text[i] != '[') return null;
    i += 1;
    i = skipPacerDimReassertions(text, i);

    var digits: usize = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') {
        digits += 1;
        i += 1;
        i = skipPacerDimReassertions(text, i);
    }
    if (digits == 0 or i >= text.len or text[i] != ']') return null;
    i += 1;
    i = skipPacerDimReassertions(text, i);
    if (i >= text.len or text[i] != ' ') return null;
    i += 1;
    const close_end = footnotePrefixBoundaryEnd(text, i) orelse return null;
    return .{ .end = close_end, .indent = digits + 3 };
}

fn footnoteContinuationIndent(text: []const u8, start: usize) ?usize {
    var i = footnoteDimOpenEnd(text, start) orelse return null;

    var indent: usize = 0;
    while (true) {
        i = skipPacerDimReassertions(text, i);
        if (i >= text.len or text[i] != ' ') break;
        indent += 1;
        i += 1;
    }
    if (indent < 4) return null;
    _ = footnotePrefixBoundaryEnd(text, i) orelse return null;
    return indent;
}

fn footnotePrefixBoundaryEnd(text: []const u8, start: usize) ?usize {
    if (dimCloseEnd(text, start)) |end| return end;
    const reassert = "\x1b[0m\x1b[2m";
    if (std.mem.startsWith(u8, text[start..], reassert)) return start + reassert.len;
    return null;
}

fn footnoteDimOpenEnd(text: []const u8, start: usize) ?usize {
    const reset = "\x1b[0m";
    const dim_open = "\x1b[2m";

    var i = start;
    if (std.mem.startsWith(u8, text[i..], reset)) i += reset.len;
    if (!std.mem.startsWith(u8, text[i..], dim_open)) return null;
    while (std.mem.startsWith(u8, text[i..], dim_open)) : (i += dim_open.len) {}
    return i;
}

fn dimCloseEnd(text: []const u8, start: usize) ?usize {
    if (std.mem.startsWith(u8, text[start..], "\x1b[22m")) return start + "\x1b[22m".len;
    if (std.mem.startsWith(u8, text[start..], "\x1b[0m")) return start + "\x1b[0m".len;
    return null;
}

fn blockquoteMarkerEnd(text: []const u8, start: usize) ?usize {
    const dim_open = "\x1b[2m";
    const dim_close = "\x1b[22m";
    const vertical_rule = "\xe2\x94\x82";

    var i = start;
    if (!std.mem.startsWith(u8, text[i..], dim_open)) return null;
    i += dim_open.len;
    i = skipPacerDimReassertions(text, i);
    if (!std.mem.startsWith(u8, text[i..], vertical_rule)) return null;
    i += vertical_rule.len;
    i = skipPacerDimReassertions(text, i);
    if (i >= text.len or text[i] != ' ') return null;
    i += 1;
    i = skipPacerDimReassertions(text, i);
    if (!std.mem.startsWith(u8, text[i..], dim_close)) return null;
    return i + dim_close.len;
}

/// Recognizes MarkdownProcessor's list prefix and pacer dim reassertions.
fn listContinuationIndentWidth(text: []const u8, line_start: usize) ?usize {
    const dim_open = "\x1b[2m";
    const dim_close = "\x1b[22m";
    const bullet = "\xe2\x80\xa2";

    var i = line_start;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    const indent = i - line_start;
    if (taskMarkerWidth(text, i)) |task_width| return indent + task_width;
    if (!std.mem.startsWith(u8, text[i..], dim_open)) return null;
    i += dim_open.len;
    i = skipPacerDimReassertions(text, i);

    if (dimTaskMarkerWidth(text, i)) |task_width| return indent + task_width;

    if (std.mem.startsWith(u8, text[i..], bullet)) {
        i += bullet.len;
        i = skipPacerDimReassertions(text, i);
        if (i >= text.len or text[i] != ' ') return null;
        i += 1;
        i = skipPacerDimReassertions(text, i);
        if (!std.mem.startsWith(u8, text[i..], dim_close)) return null;
        return indent + 2;
    }

    var marker_width: usize = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') {
        i += 1;
        marker_width += 1;
        i = skipPacerDimReassertions(text, i);
    }
    if (marker_width == 0 or i >= text.len or text[i] != '.') return null;
    i += 1;
    marker_width += 1;
    i = skipPacerDimReassertions(text, i);
    if (!std.mem.startsWith(u8, text[i..], dim_close)) return null;
    i += dim_close.len;
    if (i >= text.len or text[i] != ' ') return null;
    i += 1;

    if (taskMarkerWidth(text, i)) |task_width| return indent + marker_width + 1 + task_width;

    return indent + marker_width + 1;
}

fn dimTaskMarkerWidth(text: []const u8, start: usize) ?usize {
    const dim_close = "\x1b[22m";
    const pending = "\xe2\x98\x90";

    var i = skipPacerDimReassertions(text, start);
    if (!std.mem.startsWith(u8, text[i..], pending)) return null;
    i += pending.len;
    i = skipPacerDimReassertions(text, i);

    var width: usize = 1;
    if (i < text.len and text[i] == ' ') {
        i += 1;
        width += 1;
        i = skipPacerDimReassertions(text, i);
    }
    if (!std.mem.startsWith(u8, text[i..], dim_close)) return null;
    return width;
}

fn taskMarkerWidth(text: []const u8, start: usize) ?usize {
    const dim_open = "\x1b[2m";
    const completed_opens = [_][]const u8{ "\x1b[38;5;252m", "\x1b[38;5;238m" };
    const completed_close = "\x1b[39m";
    const completed = "\xe2\x9c\x93";

    if (std.mem.startsWith(u8, text[start..], dim_open)) {
        return dimTaskMarkerWidth(text, start + dim_open.len);
    }

    var i = start;
    const open_len = for (completed_opens) |open| {
        if (std.mem.startsWith(u8, text[i..], open)) break open.len;
    } else return null;
    i += open_len;
    if (!std.mem.startsWith(u8, text[i..], completed)) return null;
    i += completed.len;
    if (!std.mem.startsWith(u8, text[i..], completed_close)) return null;
    i += completed_close.len;

    var width: usize = 1;
    if (i < text.len and text[i] == ' ') {
        i += 1;
        width += 1;
    }
    return width;
}

fn skipPacerDimReassertions(text: []const u8, start: usize) usize {
    const reassert = "\x1b[0m\x1b[2m";
    var i = start;
    while (std.mem.startsWith(u8, text[i..], reassert)) : (i += reassert.len) {}
    return i;
}

test "wrapAssistantText preserves explicit paragraph indentation" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(alloc, "1. Heading\n   alpha beta gamma delta\n\n  alpha beta gamma delta\nalpha beta gamma delta", 16);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "1. Heading\n   alpha beta\n   gamma delta\n\n  alpha beta\n  gamma delta\nalpha beta\ngamma delta",
        out,
    );
}

test "wrapAssistantText preserves paced paragraph indentation and links" {
    const alloc = std.testing.allocator;
    const prefix = "\x1b[1m \x1b[0m\x1b[1m  ";
    const link = "\x1b]8;;https://example.com\x1b\\";
    const close = "\x1b]8;;\x1b\\";
    const out = try wrapAssistantText(alloc, prefix ++ link ++ "alpha beta gamma delta" ++ close ++ "\x1b[0m", 16);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(prefix ++ link ++ "alpha beta\x1b[0m" ++ close ++ "\n   \x1b[1m" ++ link ++ "gamma delta" ++ close ++ "\x1b[0m", out);
}

test "paragraph indentation ignores blank incomplete and non-prose prefixes" {
    for ([_][]const u8{ "   ", "   \nnext", "   \rnext", "  \ttext", "  \x1b[", "  \x1b[\ntext", "  \x1b]8;;unfinished", "  \x1b[Atext" }) |text| {
        try std.testing.expectEqual(@as(?usize, null), proseIndent(text, 0));
    }
    try std.testing.expectEqual(@as(?usize, 3), proseIndent("\x1b[2m \x1b[0m  text", 0));
    try std.testing.expectEqual(@as(?usize, 2), proseIndent(" \x1b]8;;https://example.com\x07 text", 0));
}

test "wrapAssistantText explicit indentation respects narrow widths and wide units" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(alloc, "   abcdef", 3);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("   \nabc\ndef", out);
    const wide = try wrapAssistantText(alloc, "  界界界", 4);
    defer alloc.free(wide);
    try std.testing.expectEqualStrings("  界\n  界\n  界", wide);
}

test "paragraph indentation preserves finalized source boundaries" {
    const alloc = std.testing.allocator;
    const text = "   alpha beta gamma delta\n  unfinished";
    const partial = try wrapTranscriptAssistantTextWithFinalityInterruptible(alloc, text, 18, null);
    defer alloc.free(partial.bytes);
    const finished = try wrapTranscriptAssistantTextWithFinalityInterruptible(alloc, text ++ "\n", 18, null);
    defer alloc.free(finished.bytes);
    try std.testing.expectEqualStrings("     alpha beta\n     gamma delta\n", partial.bytes[0..partial.finalized_prefix_bytes]);
    try std.testing.expectEqualStrings(partial.bytes, finished.bytes[0 .. finished.bytes.len - 1]);
    try std.testing.expectEqual(finished.bytes.len, finished.finalized_prefix_bytes);
}

test "wrapAssistantText wraps plain ascii at cols" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(alloc, "abcdefghij", 5);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("abcde\nfghij", out);
}

test "wrapAssistantText keeps paragraph words together and avoids a final orphan" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(alloc, "alpha beta gamma delta", 16);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("alpha beta\ngamma delta", out);
}

test "wrapAssistantText avoids an orphan after a fitting separator" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(alloc, "aaaa bbbb cccc dddd", 16);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("aaaa bbbb\ncccc dddd", out);
}

test "wrapAssistantText keeps word-aware list continuations aligned" {
    const alloc = std.testing.allocator;
    const input = "\x1b[2m\xe2\x80\xa2 \x1b[22malpha beta gamma delta";
    const out = try wrapAssistantText(alloc, input, 18);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x80\xa2 \x1b[22malpha beta\n  gamma delta",
        out,
    );
}

test "wrapAssistantText repeats every styled nested blockquote rule on word-aware continuations" {
    const alloc = std.testing.allocator;
    const input = "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[1malpha beta gamma delta\x1b[22m";
    const out = try wrapAssistantText(alloc, input, 18);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[1malpha beta\x1b[0m\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[1mgamma delta\x1b[22m",
        out,
    );
}

test "wrapAssistantText repeats paced nested blockquote rules" {
    const alloc = std.testing.allocator;
    const paced_rule = "\x1b[2m\xe2\x94\x82\x1b[0m\x1b[2m \x1b[0m\x1b[2m\x1b[22m";
    const input = paced_rule ++ paced_rule ++ "abcdefghijkl";
    const out = try wrapAssistantText(alloc, input, 9);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        paced_rule ++ paced_rule ++ "abcde\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22mfghij\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22mkl",
        out,
    );
}

test "wrapAssistantText preserves bold SGR across wrap boundary" {
    const alloc = std.testing.allocator;
    const input = "\x1b[1mabcdef\x1b[22m";
    const out = try wrapAssistantText(alloc, input, 3);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\x1b[1mabc\x1b[0m\n\x1b[1mdef\x1b[22m", out);
}

test "wrapAssistantText preserves inline code foreground across wrap boundary" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{
            .input = "\x1b[38;5;245mabcdef\x1b[39m",
            .expected = "\x1b[38;5;245mabc\x1b[0m\n\x1b[38;5;245mdef\x1b[39m",
        },
        .{
            .input = "\x1b[38;5;247mabcdef\x1b[39m",
            .expected = "\x1b[38;5;247mabc\x1b[0m\n\x1b[38;5;247mdef\x1b[39m",
        },
    };

    for (cases) |case| {
        const out = try wrapAssistantText(alloc, case.input, 3);
        defer alloc.free(out);
        try std.testing.expectEqualStrings(case.expected, out);
    }
}

test "wrapAssistantText preserves heading underline across wrap boundary" {
    const alloc = std.testing.allocator;
    const input = "\x1b[1m\x1b[4mabcdef\x1b[24m\x1b[22m";
    const out = try wrapAssistantText(alloc, input, 3);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[4mabc\x1b[0m\n\x1b[1m\x1b[4mdef\x1b[24m\x1b[22m",
        out,
    );
}

test "wrapAssistantText preserves an underlined OSC 8 link across a wrap" {
    const alloc = std.testing.allocator;
    const input =
        "\x1b]8;id=fx-1;https://example.com\x1b\\\x1b[4mabcdef\x1b[24m\x1b]8;;\x1b\\ tail";
    const out = try wrapAssistantText(alloc, input, 3);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "\x1b]8;id=fx-1;https://example.com\x1b\\\x1b[4mabc\x1b[0m\x1b]8;;\x1b\\\n" ++
            "\x1b[4m\x1b]8;id=fx-1;https://example.com\x1b\\def\x1b[24m\x1b]8;;\x1b\\\ntai\nl",
        out,
    );
}

test "wrapAssistantText reopens an OSC 8 link after a word-balanced wrap" {
    const alloc = std.testing.allocator;
    const input =
        "\x1b]8;id=fx-1;https://example.com\x1b\\\x1b[4malpha beta\x1b[24m\x1b]8;;\x1b\\";
    const out = try wrapAssistantText(alloc, input, 6);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "\x1b]8;id=fx-1;https://example.com\x1b\\\x1b[4malpha\x1b[0m\x1b]8;;\x1b\\\n" ++
            "\x1b[4m\x1b]8;id=fx-1;https://example.com\x1b\\beta\x1b[24m\x1b]8;;\x1b\\",
        out,
    );
}

test "wrapAssistantText honours hard newlines without extra reset" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(alloc, "ab\ncd", 10);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("ab\ncd", out);
}

test "wrapAssistantText with cols=0 returns empty" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(alloc, "foo", 0);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "wrapAssistantText with empty text returns empty" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(alloc, "", 80);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "wrapAssistantText passes non-SGR ANSI through without counting for width" {
    const alloc = std.testing.allocator;
    const input = "a\x1b[Ab";
    const out = try wrapAssistantText(alloc, input, 2);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a\x1b[Ab", out);
}

test "wrapAssistantText indents unordered list continuations" {
    const alloc = std.testing.allocator;
    const input = "\x1b[2m\xe2\x80\xa2 \x1b[22mabcdefghijkl";
    const out = try wrapAssistantText(alloc, input, 7);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\x1b[2m\xe2\x80\xa2 \x1b[22mabcde\n  fghij\n  kl", out);
}

test "wrapAssistantText recognizes paced list markers" {
    const alloc = std.testing.allocator;

    const unordered = try wrapAssistantText(
        alloc,
        "\x1b[2m\xe2\x80\xa2\x1b[0m\x1b[2m \x1b[0m\x1b[2m\x1b[22mabcdefghij",
        7,
    );
    defer alloc.free(unordered);
    try std.testing.expectEqualStrings("\x1b[2m\xe2\x80\xa2\x1b[0m\x1b[2m \x1b[0m\x1b[2m\x1b[22mabcde\n  fghij", unordered);

    const ordered = try wrapAssistantText(
        alloc,
        "\x1b[2m1\x1b[0m\x1b[2m2\x1b[0m\x1b[2m.\x1b[0m\x1b[2m\x1b[22m abcdefgh",
        10,
    );
    defer alloc.free(ordered);
    try std.testing.expectEqualStrings("\x1b[2m1\x1b[0m\x1b[2m2\x1b[0m\x1b[2m.\x1b[0m\x1b[2m\x1b[22m abcdef\n    gh", ordered);

    const blockquote = try wrapAssistantText(
        alloc,
        "\x1b[2m\xe2\x94\x82\x1b[0m\x1b[2m \x1b[0m\x1b[2m\x1b[22mabcdefghij",
        7,
    );
    defer alloc.free(blockquote);
    try std.testing.expectEqualStrings("\x1b[2m\xe2\x94\x82\x1b[0m\x1b[2m \x1b[0m\x1b[2m\x1b[22mabcde\n\x1b[2m\xe2\x94\x82 \x1b[22mfghij", blockquote);
}

test "wrapAssistantText indents ordered and nested list continuations" {
    const alloc = std.testing.allocator;

    const ordered = try wrapAssistantText(alloc, "  \x1b[2m12.\x1b[22m abcdefghij", 10);
    defer alloc.free(ordered);
    try std.testing.expectEqualStrings("  \x1b[2m12.\x1b[22m abcd\n      efgh\n      ij", ordered);

    const nested = try wrapAssistantText(alloc, "  \x1b[2m\xe2\x80\xa2 \x1b[22mabcdefgh", 8);
    defer alloc.free(nested);
    try std.testing.expectEqualStrings("  \x1b[2m\xe2\x80\xa2 \x1b[22mabcd\n    efgh", nested);
}

test "wrapAssistantText indents dim definition continuations" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(alloc, "\x1b[2m  \x1b[22malpha beta gamma delta", 14);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[2m  \x1b[22malpha beta\n  gamma delta",
        out,
    );
}

test "wrapAssistantText recognizes paced dim definition prefixes" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(
        alloc,
        "\x1b[2m \x1b[0m\x1b[2m \x1b[0m\x1b[2m\x1b[22malpha beta gamma delta",
        14,
    );
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[2m \x1b[0m\x1b[2m \x1b[0m\x1b[2m\x1b[22malpha beta\n  gamma delta",
        out,
    );
}

test "wrapAssistantText indents dim footnote continuations" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(alloc, "\x1b[2m[1] \x1b[22mabcdefghijkl", 8);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[2m[1] \x1b[22mabcd\n    efgh\n    ijkl",
        out,
    );
}

test "wrapAssistantText recognizes reset-closed dim footnote prefixes" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(alloc, "\x1b[2m[1] \x1b[0mabcdefghijkl", 8);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[2m[1] \x1b[0mabcd\n    efgh\n    ijkl",
        out,
    );
}

test "wrapAssistantText recognizes paced dim footnote prefixes" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(
        alloc,
        "\x1b[2m[1] \x1b[0m\x1b[2mabcdefghijkl\x1b[22m",
        8,
    );
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        "\x1b[2m[1] \x1b[0m\x1b[2mabcd\x1b[0m\n" ++
            "    \x1b[2mefgh\x1b[0m\n" ++
            "    \x1b[2mijkl\x1b[22m",
        out,
    );
}

test "wrapAssistantText recognizes a leading paced footnote reassertion" {
    const alloc = std.testing.allocator;
    const out = try wrapAssistantText(
        alloc,
        "\x1b[0m\x1b[2m[2] \x1b[0mThis definition appears before its reference.",
        32,
    );
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n    before its reference.") != null);
}

test "wrapTranscriptAssistantText retains reset-closed footnote indentation after prose" {
    const alloc = std.testing.allocator;
    const out = try wrapTranscriptAssistantTextInterruptible(
        alloc,
        "Forward reference.\n\n" ++
            "\x1b[2m[2] \x1b[0mThis definition appears before its reference and ends with FOOTNOTE_DONE.",
        32,
        null,
    );
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n      before its reference") != null);
}

test "wrapTranscriptAssistantText retains footnote indentation through character-paced markers" {
    const alloc = std.testing.allocator;
    const input =
        "Forward reference\n\n" ++
        "\x1b[2m[\x1b[0m\x1b[2m1\x1b[0m\x1b[2m]\x1b[0m\x1b[2m \x1b[0m\x1b[2m\x1b[22m" ++
        "The deferred body wraps through a narrow terminal.";
    try std.testing.expect(footnotePrefix(input, "Forward reference\n\n".len) != null);
    try std.testing.expect(assistantContinuation(input, "Forward reference\n\n".len) != null);
    const out = try wrapTranscriptAssistantTextInterruptible(
        alloc,
        input,
        32,
        null,
    );
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n      through a narrow terminal.") != null);
}

test "wrapAssistantText elides infeasible dim footnote markers at narrow widths" {
    const alloc = std.testing.allocator;
    const ascii = "\x1b[2m[1] \x1b[22malphabet";
    var cols: u16 = 1;
    while (cols <= 7) : (cols += 1) {
        const out = try wrapAssistantText(alloc, ascii, cols);
        defer alloc.free(out);

        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) > 0);
        }
        if (cols <= 4) {
            try std.testing.expect(std.mem.indexOf(u8, out, "[1]") == null);
        } else {
            try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[2m[1] \x1b[22m"));
        }
    }

    const wide = "\x1b[2m[1] \x1b[22m\xe6\xbc\xa2" ++ "\xe5\xad\x97" ++ "abc";
    cols = 2;
    while (cols <= 7) : (cols += 1) {
        const out = try wrapAssistantText(alloc, wide, cols);
        defer alloc.free(out);

        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) > 0);
        }
    }
}

test "wrapAssistantText reopens a definition link after a wrap" {
    const alloc = std.testing.allocator;
    const link_open = "\x1b]8;id=fx-definition;https://example.com\x1b\\";
    const link_close = "\x1b]8;;\x1b\\";
    const input =
        "\x1b[2m  \x1b[22m" ++
        link_open ++ "\x1b[4malpha beta\x1b[24m" ++ link_close;
    const out = try wrapAssistantText(alloc, input, 8);
    defer alloc.free(out);

    try std.testing.expect(std.mem.startsWith(u8, out, "\x1b[2m  \x1b[22m" ++ link_open ++ "\x1b[4malpha"));
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "\x1b[0m" ++ link_close ++ "\n  \x1b[4m" ++ link_open ++ "beta\x1b[24m" ++ link_close,
    ) != null);
}

test "wrapAssistantText indents pending and completed task list continuations" {
    const alloc = std.testing.allocator;

    const pending = try wrapAssistantText(alloc, "\x1b[2m\xe2\x98\x90 \x1b[22malpha beta gamma delta", 18);
    defer alloc.free(pending);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x98\x90 \x1b[22malpha beta\n  gamma delta",
        pending,
    );

    const completed = try wrapAssistantText(alloc, "\x1b[38;5;252m\xe2\x9c\x93\x1b[39m alpha beta gamma delta", 18);
    defer alloc.free(completed);
    try std.testing.expectEqualStrings(
        "\x1b[38;5;252m\xe2\x9c\x93\x1b[39m alpha beta\n  gamma delta",
        completed,
    );

    const ordered = try wrapAssistantText(alloc, "\x1b[2m12.\x1b[22m \x1b[2m\xe2\x98\x90 \x1b[22malpha beta gamma", 20);
    defer alloc.free(ordered);
    try std.testing.expectEqualStrings(
        "\x1b[2m12.\x1b[22m \x1b[2m\xe2\x98\x90 \x1b[22malpha\n      beta gamma",
        ordered,
    );

    const nested = try wrapAssistantText(alloc, "  \x1b[38;5;252m\xe2\x9c\x93\x1b[39m abcdefghij", 10);
    defer alloc.free(nested);
    try std.testing.expectEqualStrings(
        "  \x1b[38;5;252m\xe2\x9c\x93\x1b[39m abcdef\n    ghij",
        nested,
    );
}

test "wrapAssistantText keeps narrow task list rows within terminal width" {
    const alloc = std.testing.allocator;
    const task_rows = [_][]const u8{
        "\x1b[2m\xe2\x98\x90 \x1b[22malphabet",
        "\x1b[38;5;252m\xe2\x9c\x93\x1b[39m alphabet",
    };

    for (task_rows) |task_row| {
        var cols: u16 = 1;
        while (cols <= 5) : (cols += 1) {
            const out = try wrapAssistantText(alloc, task_row, cols);
            defer alloc.free(out);
            var lines = std.mem.splitScalar(u8, out, '\n');
            while (lines.next()) |line| {
                try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
            }
        }
    }
}

test "wrapAssistantText keeps styled list continuations unstyled at indentation" {
    const alloc = std.testing.allocator;
    const input = "\x1b[2m\xe2\x80\xa2 \x1b[22m\x1b[1mabcdefghij\x1b[22m";
    const out = try wrapAssistantText(alloc, input, 7);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("\x1b[2m\xe2\x80\xa2 \x1b[22m\x1b[1mabcde\x1b[0m\n  \x1b[1mfghij\x1b[22m", out);
}

test "wrapAssistantText keeps narrow list rows within terminal width" {
    const alloc = std.testing.allocator;
    const single_cell = "\x1b[2m\xe2\x80\xa2 \x1b[22mabcdefghijkl";
    const two_cell = "\x1b[2m\xe2\x80\xa2 \x1b[22m\xe6\xbc\xa2\xe5\xad\x97abcdef";

    var cols: u16 = 1;
    while (cols <= 5) : (cols += 1) {
        const out = try wrapAssistantText(alloc, single_cell, cols);
        defer alloc.free(out);
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
        }
    }

    cols = 2;
    while (cols <= 5) : (cols += 1) {
        const out = try wrapAssistantText(alloc, two_cell, cols);
        defer alloc.free(out);
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
        }
    }
}

test "wrapAssistantText keeps Unicode display units intact at row boundaries" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "\u{2600}\u{FE0E}",
        "\u{1F44D}\u{1F3FD}",
        "\u{1F1FA}\u{1F1F8}",
        "#\u{FE0F}\u{20E3}",
        "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
        "\u{1F469}\u{200D}\u{1F4BB}",
    };

    for (cases) |unit| {
        const input = try std.fmt.allocPrint(alloc, "a{s}b", .{unit});
        defer alloc.free(input);
        const out = try wrapAssistantText(alloc, input, 3);
        defer alloc.free(out);

        try std.testing.expect(std.mem.indexOf(u8, out, unit) != null);
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= 3);
        }
    }
}

test "wrapAssistantText keeps narrow blockquote rows within terminal width" {
    const alloc = std.testing.allocator;
    const prefix = "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22m";
    const single_cell = prefix ++ "abcdefghijkl";
    const two_cell = prefix ++ "\xe6\xbc\xa2\xe5\xad\x97abcdef";

    var cols: u16 = 1;
    while (cols <= 7) : (cols += 1) {
        const out = try wrapAssistantText(alloc, single_cell, cols);
        defer alloc.free(out);
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
        }
    }

    cols = 2;
    while (cols <= 7) : (cols += 1) {
        const out = try wrapAssistantText(alloc, two_cell, cols);
        defer alloc.free(out);
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
        }
    }
}

test "wrapLiteralCommandOutput repeats gutters and uses absolute tab stops" {
    const alloc = std.testing.allocator;
    const out = try wrapLiteralCommandOutput(
        alloc,
        "paragraph words\n\n\tvalue",
        16,
    );
    defer alloc.free(out);

    try std.testing.expectEqualStrings(
        "│ paragraph\n" ++
            "│ words\n" ++
            "│ \n" ++
            "│       value",
        out,
    );
}

test "wrapLiteralToolOutput repeats the tool detail rail on physical rows" {
    const alloc = std.testing.allocator;
    const out = try wrapLiteralToolOutput(
        alloc,
        "alpha beta gamma delta",
        16,
    );
    defer alloc.free(out);

    try std.testing.expectEqualStrings(
        "│  alpha beta\n│  gamma delta",
        out,
    );
}

test "wrapLiteralCommandOutputPrefix bounds oversized record work" {
    const alloc = std.testing.allocator;
    const input = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(input);
    @memset(input, 'x');

    var prefix = try wrapLiteralCommandOutputPrefix(alloc, input, 20, 5);
    defer prefix.deinit(alloc);
    try std.testing.expect(prefix.has_more);
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, prefix.bytes, "\n") + 1);
    try std.testing.expect(prefix.bytes.len < 256);
}

test "wrapLiteralCommandOutput preserves and rows a pathological zero width run" {
    const alloc = std.testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    try input.append(alloc, 'a');
    const combining_count = literal_command_zero_width_row_byte_limit + 512;
    for (0..combining_count) |_| {
        try input.appendSlice(alloc, "\xcc\x81");
    }

    const out = try wrapLiteralCommandOutput(alloc, input.items, 80);
    defer alloc.free(out);
    try std.testing.expectEqual(combining_count, std.mem.count(u8, out, "\xcc\x81"));
    try std.testing.expect(std.mem.count(u8, out, "\n") > 1);
}
