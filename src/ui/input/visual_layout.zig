const std = @import("std");
const display_width = @import("../../core/shared/display_width.zig");
const image_attachments = @import("../../core/images/image_attachments.zig");
const entity_spans = @import("../../core/shared/entity_spans.zig");
const types = @import("../../core/shared/types.zig");
const paste_blocks = @import("../../core/input/pasted_blocks.zig");
const registered_entities = @import("../../core/input/registered_entities.zig");

pub const Direction = enum { up, down };
pub const BreakKind = enum { hard_newline, soft_wrap, input_end };
pub const InputPrefix = struct {
    bytes: []const u8,
    cell_width: usize,
};
pub const UnitKind = union(enum) {
    text,
    tab,
    paste_placeholder,
    skill_token: usize,
    image_badge: struct {
        attachment_index: usize,
    },
};

pub const SkillTokenSpan = registered_entities.SkillTokenSpan;

pub const RawRange = struct {
    start: usize,
    end: usize,
};

fn skillTokenVisibleWidth(token: SkillTokenSpan) usize {
    return display_width.visibleWidth(token.name);
}

pub const ImageTokenSpan = entity_spans.ImageTokenSpan;

pub const Source = struct {
    input: []const u8,
    cursor: usize,
    terminal_cols: u16,
    /// Production invariant: unique positive attachment IDs.
    images: []const types.ImageAttachment = &.{},
    /// Production invariant: sorted by span start and non-overlapping.
    pasted_blocks: []const paste_blocks.PastedBlock = &.{},
    /// Production invariant: sorted by raw_start and non-overlapping.
    image_tokens: []const ImageTokenSpan = &.{},
    /// Production invariant: sorted by raw_start and non-overlapping.
    skill_tokens: []const SkillTokenSpan = &.{},
    selection: ?RawRange = null,
};

pub const CursorPoint = struct {
    raw_offset: usize,
    row_index: usize,
    content_column: usize,
};

pub const Unit = struct {
    raw_start: usize,
    raw_end: usize,
    row_index: usize,
    content_column: usize,
    cell_width: usize,
    kind: UnitKind,
};

pub const Row = struct {
    index: usize,
    raw_start: usize,
    raw_end: usize,
    break_kind: BreakKind,
    prefix_cell_width: usize,
    content_width: usize,
    first_cursor_offset: usize,
    last_cursor_offset: usize,
};

pub const Summary = struct {
    total_rows: usize,
    cursor: CursorPoint,
    anchor: ?CursorPoint,
};

pub const VisibleWindow = struct {
    first_row: usize,
    row_count: usize,
};

pub const Event = union(enum) {
    unit: Unit,
    row_end: Row,
};

const RawUnit = struct {
    raw_start: usize,
    raw_end: usize,
    cell_width: usize,
    kind: UnitKind,
};

pub const Iterator = struct {
    source: Source,
    i: usize = 0,
    row_index: usize = 0,
    row_start: usize = 0,
    content_column: usize = 0,
    last_cursor_offset: usize = 0,
    previous_cursor_offset: usize = 0,
    force_next_positive_wrap: bool = false,
    at_word_start: bool = true,
    done: bool = false,

    pub fn next(self: *Iterator) ?Event {
        if (self.done) return null;

        if (self.i >= self.source.input.len) {
            return self.finishRow(.input_end, self.source.input.len);
        }

        if (self.source.input[self.i] == '\n') {
            return self.finishRow(.hard_newline, self.i);
        }

        const raw = self.peekRawUnit();
        if (self.shouldBreakBefore(raw)) {
            return self.finishRow(.soft_wrap, raw.raw_start);
        }

        return self.consumeRawUnit(raw);
    }

    /// Decides whether the current row soft-wraps before `raw`. Spaces never
    /// wrap; they hang past the right margin (painters clip them) so
    /// continuation rows start at the word itself, never a leading space.
    fn shouldBreakBefore(self: *const Iterator, raw: RawUnit) bool {
        if (raw.kind == .text and self.source.input[raw.raw_start] == ' ') return false;
        if (self.shouldSoftWrapWord(raw)) return true;
        return raw.cell_width > 0 and self.shouldSoftWrap(raw.cell_width);
    }

    fn finishRow(self: *Iterator, break_kind: BreakKind, raw_end: usize) Event {
        const prefix = inputPrefix(self.row_index);
        const last_cursor_offset = switch (break_kind) {
            .soft_wrap => if (self.last_cursor_offset == raw_end) self.previous_cursor_offset else self.last_cursor_offset,
            .hard_newline, .input_end => raw_end,
        };
        const row = Row{
            .index = self.row_index,
            .raw_start = self.row_start,
            .raw_end = raw_end,
            .break_kind = break_kind,
            .prefix_cell_width = prefix.cell_width,
            .content_width = self.content_column,
            .first_cursor_offset = self.row_start,
            .last_cursor_offset = last_cursor_offset,
        };

        switch (break_kind) {
            .input_end => self.done = true,
            .hard_newline => self.startNextRow(raw_end + 1),
            .soft_wrap => self.startNextRow(raw_end),
        }

        return .{ .row_end = row };
    }

    fn startNextRow(self: *Iterator, raw_start: usize) void {
        self.i = raw_start;
        self.row_index += 1;
        self.row_start = raw_start;
        self.content_column = 0;
        self.last_cursor_offset = raw_start;
        self.previous_cursor_offset = raw_start;
        self.force_next_positive_wrap = false;
        self.at_word_start = true;
    }

    fn peekRawUnit(self: *const Iterator) RawUnit {
        const input = self.source.input;
        const start = self.i;
        if (paste_blocks.registeredPlaceholderSpanStartingAt(
            input,
            start,
            self.source.pasted_blocks,
        )) |placeholder| {
            return .{
                .raw_start = placeholder.start,
                .raw_end = placeholder.end,
                .cell_width = display_width.visibleWidth(
                    input[placeholder.start..placeholder.end],
                ),
                .kind = .paste_placeholder,
            };
        }

        if (skillTokenStartingAt(self.source.skill_tokens, start, input.len)) |token_index| {
            const token = self.source.skill_tokens[token_index];
            return .{
                .raw_start = token.raw_start,
                .raw_end = token.raw_end,
                .cell_width = skillTokenVisibleWidth(token),
                .kind = .{ .skill_token = token_index },
            };
        }

        if (input[start] == '\t') {
            return .{
                .raw_start = start,
                .raw_end = start + 1,
                .cell_width = tabAdvance(inputPrefix(self.row_index).cell_width, self.content_column, self.source.terminal_cols),
                .kind = .tab,
            };
        }

        if (imageTokenStartingAt(self.source, start)) |token| {
            const attachment_index = image_attachments.findImageIndexById(
                self.source.images,
                token.id,
            ).?;
            return .{
                .raw_start = token.span.raw_start,
                .raw_end = token.span.raw_end,
                .cell_width = image_attachments.imageBadgeVisibleWidth(token.id),
                .kind = .{ .image_badge = .{ .attachment_index = attachment_index } },
            };
        }

        const display_unit = display_width.displayUnitAt(input, start);
        return .{
            .raw_start = start,
            .raw_end = start + display_unit.byte_len,
            .cell_width = display_unit.cell_width,
            .kind = .text,
        };
    }

    fn consumeRawUnit(self: *Iterator, raw: RawUnit) Event {
        const unit = Unit{
            .raw_start = raw.raw_start,
            .raw_end = raw.raw_end,
            .row_index = self.row_index,
            .content_column = self.content_column,
            .cell_width = raw.cell_width,
            .kind = raw.kind,
        };

        self.i = raw.raw_end;
        self.previous_cursor_offset = self.last_cursor_offset;
        self.last_cursor_offset = raw.raw_end;
        self.at_word_start = switch (raw.kind) {
            .text => isWordBreakByte(self.source.input[raw.raw_start]),
            .tab, .paste_placeholder, .skill_token, .image_badge => true,
        };
        const available = self.availableContentCells();
        const oversized_empty_row = available > 0 and self.content_column == 0 and raw.cell_width > available;
        self.content_column +|= raw.cell_width;
        if (oversized_empty_row) {
            self.force_next_positive_wrap = true;
        }

        return .{ .unit = unit };
    }

    /// Word-aware wrapping: when a word starts near the right margin and
    /// does not fit in the remaining cells of the current row, but would fit
    /// on a fresh continuation row, wrap the whole word instead of splitting
    /// it per character. Words wider than a full row still fall back to the
    /// per-character soft wrap.
    fn shouldSoftWrapWord(self: *const Iterator, raw: RawUnit) bool {
        if (raw.kind != .text) return false;
        if (!self.at_word_start) return false;
        if (self.content_column == 0) return false;
        if (self.force_next_positive_wrap) return false;

        const available = self.availableContentCells();
        if (self.content_column >= available) return false;

        const remaining = available - self.content_column;
        const next_available = nextRowAvailableCells(self.row_index, self.source.terminal_cols);
        if (next_available == 0) return false;

        const word_width = self.measureWordWidth(raw.raw_start, next_available);
        return word_width > remaining and word_width <= next_available;
    }

    /// Measures the cell width of the word starting at `start`, stopping at
    /// word breaks, atomic units, or once the width exceeds `cap`.
    fn measureWordWidth(self: *const Iterator, start: usize, cap: usize) usize {
        const input = self.source.input;
        var width: usize = 0;
        var i = start;
        while (i < input.len and !self.wordEndsAt(i)) {
            const display_unit = display_width.displayUnitAt(input, i);
            width +|= display_unit.cell_width;
            if (width > cap) break;
            i += display_unit.byte_len;
        }
        return width;
    }

    /// A word ends at a break byte or at the start of an atomic unit
    /// (paste, skill, or image), mirroring peekRawUnit's boundaries.
    fn wordEndsAt(self: *const Iterator, i: usize) bool {
        const input = self.source.input;
        if (isWordBreakByte(input[i])) return true;
        if (paste_blocks.registeredPlaceholderSpanStartingAt(
            input,
            i,
            self.source.pasted_blocks,
        ) != null) return true;
        if (skillTokenStartingAt(self.source.skill_tokens, i, input.len) != null) return true;
        if (imageTokenStartingAt(self.source, i) != null) return true;
        return false;
    }

    fn shouldSoftWrap(self: *const Iterator, cell_width: usize) bool {
        const available = self.availableContentCells();
        if (available == 0) return false;
        if (self.force_next_positive_wrap) return true;
        if (self.content_column == 0) return false;
        if (self.content_column >= available) return true;
        if (cell_width > std.math.maxInt(u16)) return true;

        const start_column = inputPrefix(self.row_index).cell_width + self.content_column + 1;
        return display_width.shouldWrapAt(@intCast(start_column), @intCast(cell_width), self.source.terminal_cols);
    }

    fn availableContentCells(self: *const Iterator) usize {
        const cols: usize = self.source.terminal_cols;
        const prefix_width = inputPrefix(self.row_index).cell_width;
        return if (cols > prefix_width) cols - prefix_width else 0;
    }
};

fn isWordBreakByte(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

fn nextRowAvailableCells(current_row_index: usize, terminal_cols: u16) usize {
    const cols: usize = terminal_cols;
    const prefix_width = inputPrefix(current_row_index + 1).cell_width;
    return if (cols > prefix_width) cols - prefix_width else 0;
}

fn skillTokenStartingAt(tokens: []const SkillTokenSpan, raw_start: usize, input_len: usize) ?usize {
    for (tokens, 0..) |token, index| {
        if (token.raw_start == raw_start and token.raw_end > token.raw_start and token.raw_end <= input_len) return index;
        if (token.raw_start > raw_start) return null;
    }
    return null;
}

fn imageTokenStartingAt(source: Source, raw_start: usize) ?ImageTokenSpan {
    for (source.image_tokens) |token| {
        if (token.span.raw_start < raw_start) continue;
        if (token.span.raw_start > raw_start) return null;
        if (!token.span.isValid(source.input.len)) return null;
        const match = image_attachments.matchImagePlaceholder(
            source.input,
            token.span.raw_start,
        ) orelse return null;
        if (match.id != token.id or token.span.raw_start + match.length != token.span.raw_end) {
            return null;
        }
        if (image_attachments.findImageIndexById(source.images, token.id) == null) return null;
        return token;
    }
    return null;
}

pub const VerticalScan = struct {
    target: ?CursorPoint,
    preferred_column: usize,
    total_rows: usize,
    cursor_row: usize,
};

pub fn iterator(source: Source) Iterator {
    return .{
        .source = source,
        .last_cursor_offset = 0,
        .previous_cursor_offset = 0,
    };
}

pub fn summarize(source: Source, raw_anchor: ?usize) Summary {
    return .{
        .total_rows = countRows(source),
        .cursor = cursorPointAt(source, source.cursor),
        .anchor = if (raw_anchor) |anchor| cursorPointAt(source, anchor) else null,
    };
}

fn pointAtUnitStart(unit: Unit) CursorPoint {
    return .{ .raw_offset = unit.raw_start, .row_index = unit.row_index, .content_column = unit.content_column };
}

fn pointAfterUnit(unit: Unit) CursorPoint {
    return .{
        .raw_offset = unit.raw_end,
        .row_index = unit.row_index,
        .content_column = unit.content_column +| unit.cell_width,
    };
}

fn pointAtRowEnd(row: Row) CursorPoint {
    return .{ .raw_offset = row.raw_end, .row_index = row.index, .content_column = row.content_width };
}

/// Offsets inside a unit snap to the unit start.
fn pointWithinUnit(unit: Unit, target: usize) ?CursorPoint {
    if (target == unit.raw_start or (target > unit.raw_start and target < unit.raw_end)) {
        return pointAtUnitStart(unit);
    }
    return null;
}

/// Soft-wrap boundary offsets belong to the following row.
fn pendingResolvesAt(point: CursorPoint, row: Row) bool {
    return point.raw_offset < row.raw_end or row.break_kind != .soft_wrap;
}

pub fn cursorPointAt(source: Source, raw_offset: usize) CursorPoint {
    const target = @min(raw_offset, source.input.len);
    var it = iterator(source);
    var pending_after: ?CursorPoint = null;

    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (pointWithinUnit(unit, target)) |point| return point;
            if (target == unit.raw_end) pending_after = pointAfterUnit(unit);
        },
        .row_end => |row| {
            if (target == row.raw_end) {
                switch (row.break_kind) {
                    .soft_wrap => pending_after = null,
                    .hard_newline, .input_end => return pointAtRowEnd(row),
                }
            } else if (pending_after) |point| {
                if (pendingResolvesAt(point, row)) return point;
            }
        },
    };

    return .{ .raw_offset = target, .row_index = 0, .content_column = 0 };
}

pub fn cursorPointAtPosition(
    source: Source,
    row_index: usize,
    content_column: usize,
) ?CursorPoint {
    var it = iterator(source);
    var target = TargetBuilder.init(content_column);

    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (unit.row_index == row_index) {
                target.consider(pointAtUnitStart(unit));
            } else if (unit.row_index > row_index) {
                return null;
            }
        },
        .row_end => |row| {
            if (row.index < row_index) continue;
            if (row.index > row_index) return null;
            if (row.break_kind != .soft_wrap) {
                target.consider(pointAtRowEnd(row));
            }
            return target.result();
        },
    };

    return null;
}

/// Finding the cursor freezes the preferred column and arms the target:
/// up resolves from the previous row, down collects from the next row.
const ScanState = struct {
    direction: Direction,
    preferred_column: ?usize,
    preferred: usize,
    cursor_found: bool = false,
    cursor_row: usize = 0,
    target: ?CursorPoint = null,
    target_row: ?usize = null,
    target_builder: TargetBuilder = .{ .preferred_column = 0 },

    fn init(direction: Direction, preferred_column: ?usize) ScanState {
        return .{
            .direction = direction,
            .preferred_column = preferred_column,
            .preferred = preferred_column orelse 0,
        };
    }

    fn foundCursor(
        self: *ScanState,
        point: CursorPoint,
        previous_row_checkpoint: ?Iterator,
        previous_row_target: ?CursorPoint,
    ) void {
        self.cursor_found = true;
        self.cursor_row = point.row_index;
        if (self.preferred_column == null) self.preferred = point.content_column;
        switch (self.direction) {
            .up => if (point.row_index > 0) {
                self.target = if (self.preferred_column == null)
                    targetPointInCheckpoint(previous_row_checkpoint.?, point.row_index - 1, self.preferred)
                else
                    previous_row_target;
            },
            .down => {
                self.target_row = point.row_index + 1;
                self.target_builder = TargetBuilder.init(self.preferred);
            },
        }
    }

    fn considerTargetUnit(self: *ScanState, unit: Unit) void {
        const row_index = self.target_row orelse return;
        if (row_index != unit.row_index) return;
        self.target_builder.consider(pointAtUnitStart(unit));
    }

    fn finishTargetRow(self: *ScanState, row: Row) void {
        const row_index = self.target_row orelse return;
        if (row_index != row.index) return;
        if (row.break_kind != .soft_wrap) self.target_builder.consider(pointAtRowEnd(row));
        self.target = self.target_builder.result();
        self.target_row = null;
    }
};

pub fn scanAdjacentRow(source: Source, direction: Direction, preferred_column: ?usize) VerticalScan {
    const target_offset = @min(source.cursor, source.input.len);
    var it = iterator(source);
    var current_row_checkpoint = it;
    var previous_row_checkpoint: ?Iterator = null;

    var total_rows: usize = 0;
    var pending_after: ?CursorPoint = null;
    var previous_row_target: ?CursorPoint = null;
    var scan = ScanState.init(direction, preferred_column);
    var row_builder = TargetBuilder.init(scan.preferred);

    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (preferred_column != null) row_builder.consider(pointAtUnitStart(unit));
            scan.considerTargetUnit(unit);
            if (!scan.cursor_found) {
                if (pointWithinUnit(unit, target_offset)) |point| {
                    scan.foundCursor(point, previous_row_checkpoint, previous_row_target);
                } else if (target_offset == unit.raw_end) {
                    pending_after = pointAfterUnit(unit);
                }
            }
        },
        .row_end => |row| {
            total_rows += 1;

            if (preferred_column != null and row.break_kind != .soft_wrap) {
                row_builder.consider(pointAtRowEnd(row));
            }

            scan.finishTargetRow(row);

            if (!scan.cursor_found) {
                if (target_offset == row.raw_end) {
                    switch (row.break_kind) {
                        .soft_wrap => pending_after = null,
                        .hard_newline, .input_end => scan.foundCursor(
                            pointAtRowEnd(row),
                            previous_row_checkpoint,
                            previous_row_target,
                        ),
                    }
                } else if (pending_after) |point| {
                    if (pendingResolvesAt(point, row)) {
                        scan.foundCursor(point, previous_row_checkpoint, previous_row_target);
                    }
                }
            }

            if (preferred_column != null) {
                previous_row_target = row_builder.result();
                row_builder = TargetBuilder.init(scan.preferred);
            }
            previous_row_checkpoint = current_row_checkpoint;
            current_row_checkpoint = it;
        },
    };

    return .{
        .target = scan.target,
        .preferred_column = scan.preferred,
        .total_rows = total_rows,
        .cursor_row = scan.cursor_row,
    };
}

pub fn scanRowDelta(
    source: Source,
    direction: Direction,
    row_count: usize,
    preferred_column: ?usize,
) VerticalScan {
    const summary = summarize(source, null);
    const preferred = preferred_column orelse summary.cursor.content_column;
    const target_row = switch (direction) {
        .up => summary.cursor.row_index -| row_count,
        .down => @min(
            summary.cursor.row_index +| row_count,
            summary.total_rows -| 1,
        ),
    };
    return .{
        .target = if (target_row == summary.cursor.row_index)
            null
        else
            cursorPointAtPosition(source, target_row, preferred),
        .preferred_column = preferred,
        .total_rows = summary.total_rows,
        .cursor_row = summary.cursor.row_index,
    };
}

fn countRows(source: Source) usize {
    var it = iterator(source);
    var rows: usize = 0;
    while (it.next()) |event| switch (event) {
        .row_end => rows += 1,
        else => {},
    };
    return rows;
}

const TargetBuilder = struct {
    preferred_column: usize,
    first: ?CursorPoint = null,
    best: ?CursorPoint = null,

    fn init(preferred_column: usize) TargetBuilder {
        return .{ .preferred_column = preferred_column };
    }

    fn consider(self: *TargetBuilder, point: CursorPoint) void {
        if (self.first == null) self.first = point;
        if (point.content_column > self.preferred_column) return;
        if (self.best) |current| {
            if (point.content_column > current.content_column or
                (point.content_column == current.content_column and point.raw_offset > current.raw_offset))
            {
                self.best = point;
            }
        } else {
            self.best = point;
        }
    }

    fn result(self: TargetBuilder) ?CursorPoint {
        return self.best orelse self.first;
    }
};

fn targetPointInCheckpoint(checkpoint: Iterator, row_index: usize, preferred_column: usize) ?CursorPoint {
    var it = checkpoint;
    var builder = TargetBuilder.init(preferred_column);

    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (unit.row_index != row_index) continue;
            builder.consider(pointAtUnitStart(unit));
        },
        .row_end => |row| {
            if (row.index != row_index) continue;
            if (row.break_kind != .soft_wrap) builder.consider(pointAtRowEnd(row));
            return builder.result();
        },
    };

    return builder.result();
}

pub fn visibleWindow(cursor_row: usize, total_rows: usize, row_limit: usize) VisibleWindow {
    if (total_rows == 0) return .{ .first_row = 0, .row_count = 0 };
    const count = @max(row_limit, 1);
    const clamped_cursor = @min(cursor_row, total_rows - 1);
    const first = (clamped_cursor + 1) -| count;
    return .{ .first_row = first, .row_count = @min(count, total_rows - first) };
}

pub fn inputPrefix(row_index: usize) InputPrefix {
    return if (row_index == 0)
        .{ .bytes = "❯ ", .cell_width = 2 }
    else
        .{ .bytes = "  ", .cell_width = 2 };
}

pub fn terminalColumn(point: CursorPoint, terminal_cols: u16) u16 {
    if (terminal_cols == 0) return 1;
    return @intCast(@min(
        @as(usize, terminal_cols),
        inputPrefix(point.row_index).cell_width +| point.content_column +| 1,
    ));
}

pub fn projectedAnchorColumn(summary: Summary, terminal_cols: u16) u16 {
    const anchor = summary.anchor orelse return 1;
    if (anchor.row_index == summary.cursor.row_index) return terminalColumn(anchor, terminal_cols);
    return terminalColumn(.{
        .raw_offset = summary.cursor.raw_offset,
        .row_index = summary.cursor.row_index,
        .content_column = 0,
    }, terminal_cols);
}

pub fn tabAdvance(prefix_cell_width: usize, content_column: usize, terminal_cols: u16) usize {
    if (terminal_cols == 0) return 0;
    const cols: usize = terminal_cols;
    const absolute_zero_based = prefix_cell_width +| content_column;
    const right_margin = cols - 1;
    const current_zero_based = @min(absolute_zero_based, right_margin);
    const current_col: u16 = @intCast(current_zero_based + 1);
    return display_width.nextTabStopColumn(current_col, terminal_cols) - current_col;
}

fn testSource(input: []const u8, cursor: usize, cols: u16) Source {
    return .{ .input = input, .cursor = cursor, .terminal_cols = cols };
}

fn expectPoint(point: CursorPoint, raw_offset: usize, row_index: usize, content_column: usize) !void {
    try std.testing.expectEqual(raw_offset, point.raw_offset);
    try std.testing.expectEqual(row_index, point.row_index);
    try std.testing.expectEqual(content_column, point.content_column);
}

fn expectCursor(input: []const u8, raw_offset: usize, cols: u16, row_index: usize, content_column: usize) !void {
    try expectPoint(cursorPointAt(testSource(input, raw_offset, cols), raw_offset), raw_offset, row_index, content_column);
}

fn rowAt(source: Source, index: usize) ?Row {
    var it = iterator(source);
    while (it.next()) |event| switch (event) {
        .row_end => |row| if (row.index == index) return row,
        else => {},
    };
    return null;
}

test "visual layout exposes exact input prefixes and terminal projection" {
    const first = inputPrefix(0);
    const continuation = inputPrefix(1);
    try std.testing.expectEqualStrings("❯ ", first.bytes);
    try std.testing.expectEqual(@as(usize, 4), first.bytes.len);
    try std.testing.expectEqual(@as(usize, 2), first.cell_width);
    try std.testing.expectEqual(first.cell_width, display_width.visibleWidth(first.bytes));
    try std.testing.expectEqualStrings("  ", continuation.bytes);
    try std.testing.expectEqual(@as(usize, 2), continuation.bytes.len);
    try std.testing.expectEqual(@as(usize, 2), continuation.cell_width);
    try std.testing.expectEqual(continuation.cell_width, display_width.visibleWidth(continuation.bytes));

    try std.testing.expectEqual(@as(u16, 3), terminalColumn(.{ .raw_offset = 0, .row_index = 0, .content_column = 0 }, 80));
    try std.testing.expectEqual(@as(u16, 3), terminalColumn(.{ .raw_offset = 0, .row_index = 1, .content_column = 0 }, 80));
    try std.testing.expectEqual(@as(u16, 6), terminalColumn(.{ .raw_offset = 3, .row_index = 0, .content_column = 3 }, 80));
    try std.testing.expectEqual(@as(u16, 1), terminalColumn(.{ .raw_offset = 3, .row_index = 0, .content_column = 3 }, 0));
}

test "visual layout preserves empty input hard newlines and trailing empty rows" {
    const empty = summarize(testSource("", 0, 80), null);
    try std.testing.expectEqual(@as(usize, 1), empty.total_rows);
    try expectPoint(empty.cursor, 0, 0, 0);
    try std.testing.expectEqual(BreakKind.input_end, rowAt(testSource("", 0, 80), 0).?.break_kind);

    try std.testing.expectEqual(@as(usize, 2), summarize(testSource("a\nb", 0, 80), null).total_rows);
    try expectCursor("a\nb", 1, 80, 0, 1);
    try expectCursor("a\nb", 2, 80, 1, 0);

    const multi = summarize(testSource("a\n\nb\n", 5, 80), null);
    try std.testing.expectEqual(@as(usize, 4), multi.total_rows);
    try expectPoint(multi.cursor, 5, 3, 0);
}

test "visual layout targets registered paste placeholders only at boundaries" {
    const input = "x\n[Pasted text #7, 1 line]";
    const blocks = [_]paste_blocks.PastedBlock{.{
        .id = 7,
        .text = @constCast("P" ** 1001),
        .line_count = 1,
        .span = .{
            .raw_start = "x\n".len,
            .raw_end = input.len,
        },
    }};
    const scan = scanAdjacentRow(.{
        .input = input,
        .cursor = "x".len,
        .terminal_cols = 80,
        .pasted_blocks = &blocks,
    }, .down, null);

    try std.testing.expect(scan.target != null);
    try std.testing.expectEqual(@as(usize, "x\n".len), scan.target.?.raw_offset);
}

test "visual layout assigns soft-wrap boundaries to the following row" {
    const source = testSource("abcd", 3, 5);
    const summary = summarize(source, null);
    try std.testing.expectEqual(@as(usize, 2), summary.total_rows);
    try expectPoint(summary.cursor, 3, 1, 0);

    const first = rowAt(source, 0).?;
    try std.testing.expectEqual(BreakKind.soft_wrap, first.break_kind);
    try std.testing.expectEqual(@as(usize, 0), first.raw_start);
    try std.testing.expectEqual(@as(usize, 3), first.raw_end);
    try std.testing.expect(first.last_cursor_offset < first.raw_end);
}

test "visual layout zero-capacity widths split only on hard newlines" {
    inline for (.{ @as(u16, 0), 1, 2 }) |cols| {
        const source = testSource("abc\ndef", "abc\ndef".len, cols);
        const summary = summarize(source, null);
        try std.testing.expectEqual(@as(usize, 2), summary.total_rows);
        try expectPoint(summary.cursor, "abc\ndef".len, 1, 3);
        try std.testing.expectEqual(BreakKind.hard_newline, rowAt(source, 0).?.break_kind);
    }
}

test "visual layout handles wide runes oversized rows combining marks and invalid utf8" {
    try expectCursor("a界", 1, 4, 1, 0);
    try expectPoint(cursorPointAt(testSource("a界", 2, 4), 2), 1, 1, 0);

    try std.testing.expectEqual(@as(usize, 2), summarize(testSource("界a", 0, 3), null).total_rows);
    inline for (.{ @as(u16, 0), 1, 2 }) |cols| {
        try std.testing.expectEqual(@as(usize, 1), summarize(testSource("界a", 0, cols), null).total_rows);
    }

    const combining = "a\xcc\x81\nb";
    try expectCursor(combining, "a\xcc\x81".len, 80, 0, 1);
    const down = scanAdjacentRow(testSource(combining, 0, 80), .down, null);
    try std.testing.expectEqual(@as(usize, 2), down.total_rows);
    try std.testing.expectEqual(@as(usize, 0), down.cursor_row);
    try expectPoint(down.target.?, "a\xcc\x81\n".len, 1, 0);

    const combining_target = scanAdjacentRow(testSource("x\na\xcc\x81\nz", "x".len, 80), .down, null);
    try std.testing.expectEqual(@as(usize, 3), combining_target.total_rows);
    try expectPoint(combining_target.target.?, "x\na\xcc\x81".len, 1, 1);

    try expectCursor("\xffx", 1, 80, 0, 1);

    const invalid = "\xff\xfex";
    var it = iterator(testSource(invalid, invalid.len, 80));
    var invalid_units: usize = 0;
    while (it.next()) |event| switch (event) {
        .unit => |unit| {
            if (invalid_units < 2) {
                try std.testing.expectEqual(invalid_units, unit.raw_start);
                try std.testing.expectEqual(invalid_units + 1, unit.raw_end);
                try std.testing.expectEqual(invalid_units, unit.content_column);
                try std.testing.expectEqual(@as(usize, 1), unit.cell_width);
            }
            invalid_units += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), invalid_units);
}

test "visual layout keeps Unicode display units atomic at the right margin" {
    const emoji = "\u{1F44D}\u{1F3FD}";
    const input = "a" ++ emoji ++ "b";
    const source = testSource(input, 0, 5);

    try std.testing.expectEqual(@as(usize, 2), summarize(source, null).total_rows);
    try expectPoint(cursorPointAt(source, 1), 1, 0, 1);
    try expectPoint(cursorPointAt(source, 2), 1, 0, 1);
    try expectPoint(cursorPointAt(source, 1 + emoji.len), 1 + emoji.len, 1, 0);
    try expectPoint(cursorPointAt(source, input.len), input.len, 1, 1);

    var it = iterator(source);
    while (it.next()) |event| switch (event) {
        .unit => |unit| if (unit.raw_start == 1) {
            try std.testing.expectEqual(@as(usize, 1 + emoji.len), unit.raw_end);
            try std.testing.expectEqual(@as(usize, 2), unit.cell_width);
            try std.testing.expectEqual(UnitKind.text, unit.kind);
            return;
        },
        else => {},
    };
    return error.TestExpectedEqual;
}

test "visual layout tab units use absolute stops and strict following overflow" {
    try std.testing.expectEqual(@as(usize, 6), tabAdvance(2, 0, 10));
    try std.testing.expectEqual(@as(usize, 1), tabAdvance(2, 6, 10));
    try std.testing.expectEqual(@as(usize, 0), tabAdvance(2, 7, 10));
    try std.testing.expectEqual(@as(usize, 0), tabAdvance(2, 0, 0));

    try std.testing.expectEqual(@as(usize, 1), summarize(testSource("\tX", 0, 10), null).total_rows);
    try std.testing.expectEqual(@as(usize, 2), summarize(testSource("aaaaaa\t界", 0, 10), null).total_rows);
    try std.testing.expectEqual(@as(usize, 2), summarize(testSource("aaaaaa\tXY", 0, 10), null).total_rows);
    try expectCursor("\tX", 1, 10, 0, 6);
}

test "visual layout treats only registered image placeholders as atomic badges" {
    const images = [_]types.ImageAttachment{
        .{ .id = 5, .path = @constCast("/tmp/five.png"), .media_type = @constCast("image/png") },
    };
    const input = "[Image #5][Image #5] [Image #6] [Image #999999999999999999999999999999999999]";
    const image_tokens = [_]ImageTokenSpan{.{
        .id = 5,
        .span = .{ .raw_start = "[Image #5]".len, .raw_end = "[Image #5][Image #5]".len },
    }};
    const source = Source{
        .input = input,
        .cursor = 3,
        .terminal_cols = 80,
        .images = &images,
        .image_tokens = &image_tokens,
    };
    try expectPoint(cursorPointAt(source, 3), 3, 0, 3);

    var it = iterator(source);
    var badges: usize = 0;
    while (it.next()) |event| switch (event) {
        .unit => |unit| switch (unit.kind) {
            .image_badge => |badge| {
                badges += 1;
                // Both placeholders name the same attachment, so both badges are identical.
                try std.testing.expectEqual(@as(usize, 0), badge.attachment_index);
                try std.testing.expectEqual(image_attachments.imageBadgeVisibleWidth(5), unit.cell_width);
            },
            else => {},
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), badges);
}

test "visual layout resolves each image placeholder to its own attachment by id" {
    const images = [_]types.ImageAttachment{
        .{ .id = 2, .path = @constCast("/tmp/two.png"), .media_type = @constCast("image/png") },
        .{ .id = 1, .path = @constCast("/tmp/one.png"), .media_type = @constCast("image/png") },
    };
    const image_tokens = [_]ImageTokenSpan{
        .{ .id = 2, .span = .{ .raw_start = 0, .raw_end = "[Image #2]".len } },
        .{
            .id = 1,
            .span = .{
                .raw_start = "[Image #2] ".len,
                .raw_end = "[Image #2] [Image #1]".len,
            },
        },
    };
    const expected_ids = [_]usize{ 2, 1 };
    var it = iterator(.{
        .input = "[Image #2] [Image #1]",
        .cursor = 0,
        .terminal_cols = 80,
        .images = &images,
        .image_tokens = &image_tokens,
    });
    var badges: usize = 0;
    while (it.next()) |event| switch (event) {
        .unit => |unit| switch (unit.kind) {
            .image_badge => |badge| {
                const id = expected_ids[badges];
                try std.testing.expectEqual(id, images[badge.attachment_index].id);
                try std.testing.expectEqual(image_attachments.imageBadgeVisibleWidth(id), unit.cell_width);
                badges += 1;
            },
            else => {},
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), badges);
}

test "visual layout measures a badge from the attachment id, not its appearance ordinal" {
    const images = [_]types.ImageAttachment{
        .{ .id = 10, .path = @constCast("/tmp/ten.png"), .media_type = @constCast("image/png") },
    };
    const image_tokens = [_]ImageTokenSpan{.{
        .id = 10,
        .span = .{ .raw_start = 0, .raw_end = "[Image #10]".len },
    }};
    var it = iterator(.{
        .input = "[Image #10]",
        .cursor = 0,
        .terminal_cols = 80,
        .images = &images,
        .image_tokens = &image_tokens,
    });
    var badges: usize = 0;
    while (it.next()) |event| switch (event) {
        .unit => |unit| switch (unit.kind) {
            .image_badge => |badge| {
                badges += 1;
                try std.testing.expectEqual(@as(usize, 10), images[badge.attachment_index].id);
                try std.testing.expectEqual(image_attachments.imageBadgeVisibleWidth(10), unit.cell_width);
            },
            else => {},
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), badges);
}

test "visual layout exposes zero-cell tab targets without forcing soft wraps" {
    const at_margin = testSource("\tX", 0, 3);
    try std.testing.expectEqual(@as(usize, 1), summarize(at_margin, null).total_rows);
    try expectPoint(cursorPointAt(at_margin, 0), 0, 0, 0);
    try expectPoint(cursorPointAt(at_margin, 1), 1, 0, 0);
    try expectPoint(cursorPointAt(at_margin, 2), 2, 0, 1);

    inline for (.{ @as(u16, 0), 1, 2 }) |cols| {
        const source = testSource("\tX", 2, cols);
        try std.testing.expectEqual(@as(usize, 1), summarize(source, null).total_rows);
        try expectPoint(cursorPointAt(source, 1), 1, 0, 0);
        try expectPoint(cursorPointAt(source, 2), 2, 0, 1);
    }
}

test "visual layout treats unknown and overflowing image placeholders as literal text" {
    const images = [_]types.ImageAttachment{
        .{ .id = 5, .path = @constCast("/tmp/five.png"), .media_type = @constCast("image/png") },
    };
    const unknown = Source{ .input = "[Image #6]", .cursor = "[Image #6]".len, .terminal_cols = 80, .images = &images };
    try std.testing.expectEqual(@as(usize, 1), summarize(unknown, null).total_rows);
    try expectPoint(cursorPointAt(unknown, 1), 1, 0, 1);
    try expectPoint(cursorPointAt(unknown, unknown.input.len), unknown.input.len, 0, unknown.input.len);

    const overflowing_input = "[Image #999999999999999999999999999999999999]";
    const overflowing = Source{ .input = overflowing_input, .cursor = overflowing_input.len, .terminal_cols = 80, .images = &images };
    try std.testing.expectEqual(@as(usize, 1), summarize(overflowing, null).total_rows);
    try expectPoint(cursorPointAt(overflowing, 1), 1, 0, 1);
}

test "visual layout badge width follows multi-digit image ids" {
    const images = [_]types.ImageAttachment{
        .{ .id = 1, .path = @constCast("/tmp/one.png"), .media_type = @constCast("image/png") },
        .{ .id = 10, .path = @constCast("/tmp/ten.png"), .media_type = @constCast("image/png") },
        .{ .id = 100, .path = @constCast("/tmp/hundred.png"), .media_type = @constCast("image/png") },
    };
    const input = "[Image #1][Image #10][Image #100]";
    const image_tokens = [_]ImageTokenSpan{
        .{ .id = 1, .span = .{ .raw_start = 0, .raw_end = "[Image #1]".len } },
        .{
            .id = 10,
            .span = .{
                .raw_start = "[Image #1]".len,
                .raw_end = "[Image #1][Image #10]".len,
            },
        },
        .{
            .id = 100,
            .span = .{
                .raw_start = "[Image #1][Image #10]".len,
                .raw_end = input.len,
            },
        },
    };
    const expected_ids = [_]usize{ 1, 10, 100 };
    var it = iterator(.{
        .input = input,
        .cursor = 0,
        .terminal_cols = 200,
        .images = &images,
        .image_tokens = &image_tokens,
    });
    var badges: usize = 0;
    while (it.next()) |event| switch (event) {
        .unit => |unit| switch (unit.kind) {
            .image_badge => |badge| {
                const id = expected_ids[badges];
                try std.testing.expectEqual(id, images[badge.attachment_index].id);
                try std.testing.expectEqual(image_attachments.imageBadgeVisibleWidth(id), unit.cell_width);
                badges += 1;
            },
            else => {},
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), badges);
}

test "visual layout oversized badges wrap only with positive capacity" {
    const images = [_]types.ImageAttachment{
        .{ .id = 1, .path = @constCast("/tmp/one.png"), .media_type = @constCast("image/png") },
    };
    const input = "[Image #1]x";
    const image_tokens = [_]ImageTokenSpan{.{
        .id = 1,
        .span = .{ .raw_start = 0, .raw_end = "[Image #1]".len },
    }};
    const positive = Source{
        .input = input,
        .cursor = input.len,
        .terminal_cols = 10,
        .images = &images,
        .image_tokens = &image_tokens,
    };
    try std.testing.expectEqual(@as(usize, 2), summarize(positive, null).total_rows);
    try std.testing.expectEqual(BreakKind.soft_wrap, rowAt(positive, 0).?.break_kind);
    try expectPoint(cursorPointAt(positive, "[Image #1]".len), "[Image #1]".len, 1, 0);

    inline for (.{ @as(u16, 0), 1, 2 }) |cols| {
        const clipped = Source{
            .input = input,
            .cursor = input.len,
            .terminal_cols = cols,
            .images = &images,
            .image_tokens = &image_tokens,
        };
        try std.testing.expectEqual(@as(usize, 1), summarize(clipped, null).total_rows);
        try expectPoint(cursorPointAt(clipped, "[Image #1]".len), "[Image #1]".len, 0, image_attachments.imageBadgeVisibleWidth(1));
    }
}

test "visual layout clamps cursor beyond input and short target rows" {
    try expectPoint(cursorPointAt(testSource("abc", 99, 80), 99), 3, 0, 3);

    const short = scanAdjacentRow(testSource("abcdef\nx", "abcdef".len, 80), .down, null);
    try std.testing.expectEqual(@as(usize, 6), short.preferred_column);
    try expectPoint(short.target.?, "abcdef\nx".len, 1, 1);
}

test "visual layout maps pointer cells to legal cursor boundaries" {
    const ascii = testSource("abc", 0, 80);
    try expectPoint(cursorPointAtPosition(ascii, 0, 0).?, 0, 0, 0);
    try expectPoint(cursorPointAtPosition(ascii, 0, 1).?, 1, 0, 1);
    try expectPoint(cursorPointAtPosition(ascii, 0, 99).?, 3, 0, 3);
    try std.testing.expect(cursorPointAtPosition(ascii, 1, 0) == null);

    const hard = testSource("ab\nc", 0, 80);
    try expectPoint(cursorPointAtPosition(hard, 0, 99).?, 2, 0, 2);
    try expectPoint(cursorPointAtPosition(hard, 1, 0).?, 3, 1, 0);

    const wrapped = testSource("abcdef", 0, 6);
    try expectPoint(cursorPointAtPosition(wrapped, 0, 99).?, 3, 0, 3);
    try expectPoint(cursorPointAtPosition(wrapped, 1, 0).?, 4, 1, 0);

    const wide = testSource("a界b", 0, 80);
    try expectPoint(cursorPointAtPosition(wide, 0, 1).?, 1, 0, 1);
    try expectPoint(cursorPointAtPosition(wide, 0, 2).?, 1, 0, 1);
    try expectPoint(cursorPointAtPosition(wide, 0, 3).?, 4, 0, 3);
}

test "visual layout pointer mapping keeps skill tokens atomic" {
    const token = SkillTokenSpan{
        .raw_start = 0,
        .raw_end = "$review".len,
        .name = "review",
        .path = "/tmp/review/SKILL.md",
    };
    const source = Source{
        .input = "$review x",
        .cursor = 0,
        .terminal_cols = 80,
        .skill_tokens = &.{token},
    };

    try expectPoint(cursorPointAtPosition(source, 0, 3).?, 0, 0, 0);
    try expectPoint(
        cursorPointAtPosition(source, 0, display_width.visibleWidth(token.name)).?,
        "$review".len,
        0,
        display_width.visibleWidth(token.name),
    );
}

test "visual layout soft-wrap target end stays owned by the source row" {
    const scan = scanAdjacentRow(testSource("abcd", "abcd".len, 5), .up, 99);
    try std.testing.expectEqual(@as(usize, 2), scan.total_rows);
    try std.testing.expectEqual(@as(usize, 1), scan.cursor_row);
    try expectPoint(scan.target.?, 2, 0, 2);
}

test "visual layout first vertical move captures source column with target" {
    const up = scanAdjacentRow(testSource("\nabcdef", "\nabcdef".len, 80), .up, null);
    try std.testing.expectEqual(@as(usize, 6), up.preferred_column);
    try expectPoint(up.target.?, 0, 0, 0);

    const down = scanAdjacentRow(testSource("abcdef\n", "abcdef".len, 80), .down, null);
    try std.testing.expectEqual(@as(usize, 6), down.preferred_column);
    try expectPoint(down.target.?, "abcdef\n".len, 1, 0);
}

test "visual layout target selection and vertical scan report complete row facts" {
    const hard = scanAdjacentRow(testSource("abc\nde", "abc\nde".len, 80), .up, null);
    try std.testing.expectEqual(@as(usize, 2), hard.total_rows);
    try std.testing.expectEqual(@as(usize, 1), hard.cursor_row);
    try expectPoint(hard.target.?, 2, 0, 2);
    try std.testing.expectEqual(hard.total_rows, summarize(testSource("abc\nde", "abc\nde".len, 80), null).total_rows);

    const soft = scanAdjacentRow(testSource("abcdefghij", 1, 5), .down, null);
    try std.testing.expect(soft.target != null);
    try std.testing.expectEqual(@as(usize, 4), soft.total_rows);
    try std.testing.expectEqual(@as(usize, 0), soft.cursor_row);
    try std.testing.expectEqual(soft.total_rows, summarize(testSource("abcdefghij", 1, 5), null).total_rows);

    const none = scanAdjacentRow(testSource("abc", 0, 80), .up, null);
    try std.testing.expect(none.target == null);
    try std.testing.expectEqual(@as(usize, 1), none.total_rows);
    try std.testing.expectEqual(@as(usize, 0), none.cursor_row);
}

test "visual layout row delta reuses the measured row coordinate model" {
    const source = testSource("one\ntwo\nthree\nfour", 1, 80);
    const down = scanRowDelta(source, .down, 2, null);
    try std.testing.expectEqual(@as(usize, 4), down.total_rows);
    try std.testing.expectEqual(@as(usize, 0), down.cursor_row);
    try std.testing.expectEqual(@as(usize, "one\ntwo\n".len + 1), down.target.?.raw_offset);
    try std.testing.expectEqual(@as(usize, 1), down.preferred_column);

    var bottom = source;
    bottom.cursor = bottom.input.len;
    const clamped = scanRowDelta(bottom, .down, 10, null);
    try std.testing.expect(clamped.target == null);
}

test "visual layout projects picker anchors relative to the cursor row" {
    const same = Summary{
        .total_rows = 1,
        .cursor = .{ .raw_offset = 10, .row_index = 0, .content_column = 10 },
        .anchor = .{ .raw_offset = 10, .row_index = 0, .content_column = 10 },
    };
    try std.testing.expectEqual(@as(u16, 13), projectedAnchorColumn(same, 80));

    const earlier = Summary{
        .total_rows = 2,
        .cursor = .{ .raw_offset = 8, .row_index = 1, .content_column = 3 },
        .anchor = .{ .raw_offset = 2, .row_index = 0, .content_column = 2 },
    };
    try std.testing.expectEqual(@as(u16, 3), projectedAnchorColumn(earlier, 80));
    try std.testing.expectEqual(@as(u16, 1), projectedAnchorColumn(earlier, 0));
}

test "visual layout visibleWindow is defensive and cursor-containing" {
    try std.testing.expectEqual(VisibleWindow{ .first_row = 0, .row_count = 0 }, visibleWindow(99, 0, 3));
    try std.testing.expectEqual(VisibleWindow{ .first_row = 7, .row_count = 3 }, visibleWindow(9, 10, 3));
    try std.testing.expectEqual(VisibleWindow{ .first_row = 7, .row_count = 3 }, visibleWindow(99, 10, 3));
    try std.testing.expectEqual(VisibleWindow{ .first_row = 0, .row_count = 1 }, visibleWindow(0, 5, 0));

    const max_rows = std.math.maxInt(usize);
    try std.testing.expectEqual(
        VisibleWindow{ .first_row = 0, .row_count = max_rows },
        visibleWindow(max_rows, max_rows, max_rows),
    );
}

test "visual layout wraps whole words at the soft margin" {
    // cols = 12, prefix = 2, so 10 content cells per row.
    // "hello brave world" splits per word: "hello " (6) + "brave" would end
    // past column 10, so "brave" moves whole to the next row, and "world"
    // (5 cells after "brave " = 6) wraps whole again.
    const input = "hello brave world";
    const source = testSource(input, input.len, 12);
    try std.testing.expectEqual(@as(usize, 3), summarize(source, null).total_rows);

    const first = rowAt(source, 0).?;
    try std.testing.expectEqual(BreakKind.soft_wrap, first.break_kind);
    try std.testing.expectEqualStrings("hello ", input[first.raw_start..first.raw_end]);

    const second = rowAt(source, 1).?;
    try std.testing.expectEqualStrings("brave ", input[second.raw_start..second.raw_end]);

    const third = rowAt(source, 2).?;
    try std.testing.expectEqualStrings("world", input[third.raw_start..third.raw_end]);

    // The first character of the wrapped word lands at column 0 of row 1.
    try expectPoint(cursorPointAt(source, "hello ".len), "hello ".len, 1, 0);
}

test "visual layout still splits words wider than a full row per character" {
    const input = "ab cdefghijklm";
    const source = testSource(input, input.len, 12);
    // "cdefghijklm" is 11 cells wide, wider than the 10 available content
    // cells, so it must fall back to character splitting instead of leaving
    // the first row almost empty.
    try std.testing.expectEqual(@as(usize, 2), summarize(source, null).total_rows);
    const first = rowAt(source, 0).?;
    try std.testing.expectEqual(BreakKind.soft_wrap, first.break_kind);
    try std.testing.expectEqual(@as(usize, 10), first.content_width);
}

test "visual layout hangs margin spaces so continuation rows never start with a space" {
    // cols = 12, prefix = 2, so 10 content cells. "abcdefghij" fills row 0
    // exactly; the following space hangs past the margin instead of wrapping,
    // so row 1 starts at "kl" with no leading space.
    const input = "abcdefghij kl";
    const source = testSource(input, input.len, 12);
    try std.testing.expectEqual(@as(usize, 2), summarize(source, null).total_rows);

    const first = rowAt(source, 0).?;
    try std.testing.expectEqual(BreakKind.soft_wrap, first.break_kind);
    try std.testing.expectEqualStrings("abcdefghij ", input[first.raw_start..first.raw_end]);

    const second = rowAt(source, 1).?;
    try std.testing.expectEqualStrings("kl", input[second.raw_start..second.raw_end]);

    // Multiple margin spaces all hang on the previous row.
    const multi = "abcdefghij   kl";
    const multi_source = testSource(multi, multi.len, 12);
    try std.testing.expectEqual(@as(usize, 2), summarize(multi_source, null).total_rows);
    const multi_second = rowAt(multi_source, 1).?;
    try std.testing.expectEqualStrings("kl", multi[multi_second.raw_start..multi_second.raw_end]);
}

test "visual layout word wrap keeps trailing space on the previous row" {
    // Typing "aaaa bbbb " at cols 12: after the wrap, continuing to type
    // starts words on the second row rather than mid-split.
    const input = "aaaa bbbbbb cc";
    const source = testSource(input, input.len, 12);
    try std.testing.expectEqual(@as(usize, 2), summarize(source, null).total_rows);
    const first = rowAt(source, 0).?;
    try std.testing.expectEqualStrings("aaaa ", input[first.raw_start..first.raw_end]);
    const second = rowAt(source, 1).?;
    try std.testing.expectEqualStrings("bbbbbb cc", input[second.raw_start..second.raw_end]);
}

test "visual layout handles direct-limit and longer restored input without allocation" {
    const direct = "x" ** 4096;
    const longer = "y" ** 5000;
    const direct_summary = summarize(testSource(direct, direct.len, 80), null);
    const longer_summary = summarize(testSource(longer, longer.len, 80), null);
    try std.testing.expect(direct_summary.total_rows > 1);
    try std.testing.expect(longer_summary.total_rows > direct_summary.total_rows);
    _ = visibleWindow(longer_summary.cursor.row_index, longer_summary.total_rows, 4);
    try std.testing.expectEqual(@as(usize, countRows(testSource(direct, direct.len, 80))), direct_summary.total_rows);
}

test "skill token width ignores internal source metadata" {
    const unique = SkillTokenSpan{
        .raw_start = 0,
        .raw_end = "$review".len,
        .name = "review",
        .path = "/tmp/review",
    };
    const ambiguous = SkillTokenSpan{
        .raw_start = 0,
        .raw_end = "$review".len,
        .name = "review",
        .path = "/tmp/review",
        .display_source = .workspace_codex,
    };

    try std.testing.expectEqual(@as(usize, "review".len), skillTokenVisibleWidth(unique));
    try std.testing.expectEqual(@as(usize, "review".len), skillTokenVisibleWidth(ambiguous));
}
