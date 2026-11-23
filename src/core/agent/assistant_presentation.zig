const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");
const Allocator = std.mem.Allocator;

const display_width = @import("../shared/display_width.zig");
const text_utils = @import("../shared/text_utils.zig");
const ansi = @import("presentation/ansi.zig");
const tu = @import("presentation/text_util.zig");
const bp = @import("presentation/block_parse.zig");
const payload = @import("presentation/payload.zig");
const inline_render = @import("presentation/inline_render.zig");
const block_render = @import("presentation/block_render.zig");

/// Prevents OSC 8 hyperlinks from coalescing across wrapped terminal rows.
var link_id_counter: u32 = 1;

pub const setInlineCodeTheme = ansi.setInlineCodeTheme;
pub const applyTheme = ansi.applyTheme;
pub const writeHorizontalRule = ansi.writeHorizontalRule;

pub const TableColumnAlign = payload.TableColumnAlign;
pub const TableRow = payload.TableRow;
pub const TablePayload = payload.TablePayload;
pub const CodeBlockPayload = payload.CodeBlockPayload;
pub const TableCompletion = payload.TableCompletion;
pub const CodeBlockCompletion = payload.CodeBlockCompletion;
pub const ThematicRuleCompletion = payload.ThematicRuleCompletion;
pub const MarkdownCompletions = payload.MarkdownCompletions;

/// Allocator-owned assistant output queued for root or child presentation.
pub const Event = union(enum) {
    text: []u8,
    table: TablePayload,
    code_block: CodeBlockPayload,
    thematic_rule,
    /// An answer attempt starts. It waits for earlier text to show, so the
    /// host knows where the attempt's output begins.
    attempt_start,
    /// The attempt broke off and the answer starts over. The host replaces
    /// what it showed of the attempt when it still can, and otherwise shows
    /// this line after it.
    attempt_restart: []u8,
    /// The unfinished tail of the answer, shown until the text it follows is
    /// committed. It replaces the tail sent before it.
    assistant_tail: []Event,

    pub fn clone(self: Event, alloc: Allocator) Allocator.Error!Event {
        return switch (self) {
            .text => |text| .{ .text = try alloc.dupe(u8, text) },
            .table => |table| .{ .table = try table.clone(alloc) },
            .code_block => |block| .{ .code_block = try block.clone(alloc) },
            .thematic_rule => .thematic_rule,
            .attempt_start => .attempt_start,
            .attempt_restart => |text| .{ .attempt_restart = try alloc.dupe(u8, text) },
            .assistant_tail => |events| .{ .assistant_tail = try cloneEventSlice(alloc, events) },
        };
    }

    pub fn requiresTextDrain(self: Event) bool {
        return switch (self) {
            .text, .attempt_restart, .assistant_tail => false,
            .table, .code_block, .thematic_rule, .attempt_start => true,
        };
    }

    pub fn retainedByteCount(self: Event) usize {
        return switch (self) {
            .text => |text| text.len,
            .table => |table| blk: {
                var total: usize = table.alignments.len;
                for (table.rows) |row| {
                    total +|= row.cells.len * @sizeOf([]u8);
                    for (row.cells) |cell| total +|= cell.len;
                }
                break :blk total;
            },
            .code_block => |block| block.language.len +| block.code.len,
            .thematic_rule, .attempt_start => 1,
            .attempt_restart => |text| text.len,
            .assistant_tail => |events| blk: {
                var total: usize = 0;
                for (events) |event| total +|= event.retainedByteCount();
                break :blk total;
            },
        };
    }

    pub fn deinit(self: *Event, alloc: Allocator) void {
        switch (self.*) {
            .text => |text| alloc.free(text),
            .table => |*table| table.deinit(alloc),
            .code_block => |*block| block.deinit(alloc),
            .thematic_rule, .attempt_start => {},
            .attempt_restart => |text| alloc.free(text),
            .assistant_tail => |events| freeEventSlice(alloc, events),
        }
        self.* = undefined;
    }
};

fn cloneEventSlice(alloc: Allocator, source: []const Event) Allocator.Error![]Event {
    const out = try alloc.alloc(Event, source.len);
    var cloned: usize = 0;
    errdefer {
        for (out[0..cloned]) |*event| event.deinit(alloc);
        alloc.free(out);
    }
    while (cloned < source.len) : (cloned += 1) {
        out[cloned] = try source[cloned].clone(alloc);
    }
    return out;
}

/// Frees every event in `events` and the slice itself.
pub fn freeEventSlice(alloc: Allocator, events: []Event) void {
    for (events) |*event| event.deinit(alloc);
    alloc.free(events);
}

pub const renderCodeBlockPayload = block_render.renderCodeBlockPayload;
pub const renderTablePayload = block_render.renderTablePayload;
pub const writeTableHeaderCell = block_render.writeTableHeaderCell;

pub fn parseTablePayload(alloc: Allocator, buf: []const u8) !payload.TablePayload {
    return block_render.parseTablePayload(alloc, buf, &link_id_counter);
}

test "assistant presentation event clone owns nested payloads" {
    const alloc = std.testing.allocator;

    var text_source = [_]u8{ 'o', 'k' };
    var text = try (Event{ .text = &text_source }).clone(alloc);
    defer text.deinit(alloc);
    text_source[0] = 'x';
    try std.testing.expectEqualStrings("ok", text.text);

    var block_source = [_]u8{ 'z', 'i', 'g' };
    var block = try (Event{ .code_block = .{
        .language = @constCast("zig"),
        .code = &block_source,
    } }).clone(alloc);
    defer block.deinit(alloc);
    block_source[0] = 'b';
    try std.testing.expectEqualStrings("zig", block.code_block.language);
    try std.testing.expectEqualStrings("zig", block.code_block.code);

    var table = try parseTablePayload(alloc, "| Name |\n|---|\n| api |\n");
    defer table.deinit(alloc);
    const source_cell = table.rows[1].cells[0].ptr;
    var table_event = try (Event{ .table = table }).clone(alloc);
    defer table_event.deinit(alloc);
    try std.testing.expectEqualStrings("api", table_event.table.rows[1].cells[0]);
    try std.testing.expect(table_event.table.rows[1].cells[0].ptr != source_cell);
    try std.testing.expect(!(Event{ .text = @constCast("text") }).requiresTextDrain());
    try std.testing.expect((Event{ .table = table }).requiresTextDrain());
    try std.testing.expect(@as(Event, .thematic_rule).requiresTextDrain());
    try std.testing.expectEqual(@as(usize, 1), @as(Event, .thematic_rule).retainedByteCount());
}

const isPipeLine = bp.isPipeLine;
const max_link_url_bytes = ansi.max_link_url_bytes;
const horizontal_rule_width = ansi.horizontal_rule_width;
const dim_open = ansi.dim_open;
const dim_close = ansi.dim_close;
const table_horiz = ansi.table_horiz;

const Footnote = struct {
    label: []u8,
    number: ?usize = null,
    body: std.ArrayList(u8) = .empty,
    has_definition: bool = false,

    fn deinit(self: *Footnote, alloc: Allocator) void {
        alloc.free(self.label);
        self.body.deinit(alloc);
    }
};

const ActiveFootnote = struct {
    index: usize,
    append_body: bool,
};

/// An ordered list item whose number was padded to right-align its marker.
/// Source lines indented to `content_column` belong to the item and move
/// right by `shift`, the padding of this item and the items it is nested in.
const OpenOrderedItem = struct {
    content_column: usize,
    shift: usize,
};

pub const MarkdownProcessor = struct {
    line_buf: std.ArrayList(u8) = .empty,
    /// The current line with its control sequences written as visible text.
    safe_line: std.ArrayList(u8) = .empty,
    pending_top_level_line: std.ArrayList(u8) = .empty,
    pipe_buf: std.ArrayList(u8) = .empty,
    code_buf: std.ArrayList(u8) = .empty,
    code_language: std.ArrayList(u8) = .empty,
    in_code_block: bool = false,
    /// Set for fenced blocks; null while inside an indented code block.
    code_fence: ?bp.CodeFence = null,
    in_pipe_block: bool = false,
    pipe_last_line_has_lf: bool = false,
    active_blockquote: ?bp.BlockquotePrefix = null,
    active_definition: bool = false,
    footnotes: std.ArrayList(Footnote) = .empty,
    active_footnote: ?ActiveFootnote = null,
    /// Preview clone only: how the open line renders. Committed text stays committed.
    open_line_mode: inline_render.Mode = .committed,
    /// Preview clone only: the footnote whose last body line is still open.
    open_body_note: ?usize = null,
    /// Preview clone only: the line index of a header row the preview completes while it is open.
    open_pipe_row: ?usize = null,
    /// Preview clone only: set when an open-end rule changes the open line.
    open_end_fired: bool = false,
    next_footnote_number: usize = 0,
    previous_line_was_blank: bool = true,
    /// Innermost last; each entry's shift already includes its parents'.
    open_ordered_items: std.ArrayList(OpenOrderedItem) = .empty,

    pub fn deinit(self: *MarkdownProcessor, alloc: Allocator) void {
        self.line_buf.deinit(alloc);
        self.safe_line.deinit(alloc);
        self.pending_top_level_line.deinit(alloc);
        self.pipe_buf.deinit(alloc);
        self.code_buf.deinit(alloc);
        self.code_language.deinit(alloc);
        self.deinitFootnotes(alloc);
        self.open_ordered_items.deinit(alloc);
    }

    pub fn reset(self: *MarkdownProcessor, alloc: Allocator) void {
        self.line_buf.clearAndFree(alloc);
        self.safe_line.clearAndFree(alloc);
        self.pending_top_level_line.clearAndFree(alloc);
        self.pipe_buf.clearAndFree(alloc);
        self.code_buf.clearAndFree(alloc);
        self.code_language.clearAndFree(alloc);
        self.deinitFootnotes(alloc);
        self.open_ordered_items.clearAndFree(alloc);
        self.in_code_block = false;
        self.code_fence = null;
        self.in_pipe_block = false;
        self.pipe_last_line_has_lf = false;
        self.active_blockquote = null;
        self.active_definition = false;
        self.active_footnote = null;
        self.next_footnote_number = 0;
        self.previous_line_was_blank = true;
    }

    /// A deep copy of the held state, so flushing the copy never touches this processor.
    fn cloneForPreview(self: *const MarkdownProcessor, alloc: Allocator) !MarkdownProcessor {
        var copy = MarkdownProcessor{
            .in_code_block = self.in_code_block,
            .code_fence = self.code_fence,
            .in_pipe_block = self.in_pipe_block,
            .pipe_last_line_has_lf = self.pipe_last_line_has_lf,
            .active_blockquote = self.active_blockquote,
            .active_definition = self.active_definition,
            .active_footnote = self.active_footnote,
            .next_footnote_number = self.next_footnote_number,
            .previous_line_was_blank = self.previous_line_was_blank,
        };
        errdefer copy.deinit(alloc);
        try copy.line_buf.appendSlice(alloc, self.line_buf.items);
        try copy.safe_line.appendSlice(alloc, self.safe_line.items);
        try copy.pending_top_level_line.appendSlice(alloc, self.pending_top_level_line.items);
        try copy.pipe_buf.appendSlice(alloc, self.pipe_buf.items);
        try copy.code_buf.appendSlice(alloc, self.code_buf.items);
        try copy.code_language.appendSlice(alloc, self.code_language.items);
        try copy.open_ordered_items.appendSlice(alloc, self.open_ordered_items.items);
        for (self.footnotes.items) |note| {
            const label = try alloc.dupe(u8, note.label);
            copy.footnotes.append(alloc, .{
                .label = label,
                .number = note.number,
                .has_definition = note.has_definition,
            }) catch |err| {
                alloc.free(label);
                return err;
            };
            const body = &copy.footnotes.items[copy.footnotes.items.len - 1].body;
            try body.appendSlice(alloc, note.body.items);
        }
        return copy;
    }

    /// Renders what the held text would commit, as the events a flush of this
    /// processor produces, without changing this processor
    /// (tests/tla/assistant_stream/StreamTail.tla CommittedIsPrefixOfFinal). The
    /// caller owns the events appended to `tail`.
    pub fn renderProvisional(
        self: *const MarkdownProcessor,
        alloc: Allocator,
        tail: *std.ArrayList(Event),
    ) !ProvisionalResult {
        // link_id_counter is a file global shared by every processor, so the preview restores it.
        const saved_link_id = link_id_counter;
        defer link_id_counter = saved_link_id;
        const first = tail.items.len;
        errdefer deinitEventsFrom(alloc, tail, first);
        var preview = try self.cloneForPreview(alloc);
        defer preview.deinit(alloc);
        preview.open_line_mode = .{ .open_end = &preview.open_end_fired };
        var result = ProvisionalResult{};
        if (!preview.in_code_block) {
            const held_bytes = preview.line_buf.items.len;
            dropIncompleteUtf8(&preview.line_buf);
            result.open_end_applied = preview.line_buf.items.len != held_bytes;
            if (preview.line_buf.items.len > 0 and opensWithBlockMarkersOnly(preview.line_buf.items)) {
                preview.line_buf.clearRetainingCapacity();
                result.open_end_applied = true;
            }
            result.table_header_completed = try completeOpenTableHeader(alloc, &preview);
        }
        var collector = EventCollector{ .alloc = alloc, .events = tail };
        const completions = collector.completions();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try preview.flushWithCompletions(alloc, &out, completions);
        try collector.appendPendingText(&out);
        result.open_end_applied = result.open_end_applied or preview.open_end_fired;
        return result;
    }

    /// The mode for a line: a finished line commits as it is, and the open line of the preview is open text.
    fn inlineMode(self: *const MarkdownProcessor, line_has_lf: bool) inline_render.Mode {
        return if (line_has_lf) .committed else self.open_line_mode;
    }

    /// Marks the footnote body whose last line is the open line, so the preview renders it as open text.
    fn markOpenBodyLine(self: *MarkdownProcessor, line_has_lf: bool) void {
        const active = self.active_footnote orelse return;
        if (!line_has_lf and active.append_body) self.open_body_note = active.index;
    }

    /// The held table rows that the stream has not finished. Committed text has none.
    fn openRows(self: *const MarkdownProcessor) block_render.OpenRows {
        if (!self.open_line_mode.isOpenEnd()) return .{};
        if (self.open_pipe_row) |first| return .{ .first = first, .mode = self.open_line_mode };
        if (self.pipe_last_line_has_lf) return .{};
        const lines = std.mem.count(u8, self.pipe_buf.items, "\n");
        return .{ .first = lines -| 1, .mode = self.open_line_mode };
    }

    pub fn push(self: *MarkdownProcessor, alloc: Allocator, input: []const u8, out: *std.ArrayList(u8)) !void {
        try self.pushWithCompletions(alloc, input, out, .{});
    }

    pub fn pushWithTableCompletion(
        self: *MarkdownProcessor,
        alloc: Allocator,
        input: []const u8,
        out: *std.ArrayList(u8),
        completion: ?*const payload.TableCompletion,
    ) !void {
        try self.pushWithCompletions(alloc, input, out, .{ .table = completion });
    }

    pub fn pushWithCompletions(
        self: *MarkdownProcessor,
        alloc: Allocator,
        input: []const u8,
        out: *std.ArrayList(u8),
        completions: payload.MarkdownCompletions,
    ) !void {
        for (input) |byte| {
            if (byte == '\n') {
                const line_end = self.line_buf.items.len - @intFromBool(
                    self.line_buf.items.len > 0 and self.line_buf.items[self.line_buf.items.len - 1] == '\r',
                );
                try self.handleModelLine(alloc, self.line_buf.items[0..line_end], true, out, completions);
                self.line_buf.clearRetainingCapacity();
            } else {
                try self.line_buf.append(alloc, byte);
            }
        }
    }

    pub fn flush(self: *MarkdownProcessor, alloc: Allocator, out: *std.ArrayList(u8)) !void {
        try self.flushWithCompletions(alloc, out, .{});
    }

    pub fn flushWithTableCompletion(
        self: *MarkdownProcessor,
        alloc: Allocator,
        out: *std.ArrayList(u8),
        completion: ?*const payload.TableCompletion,
    ) !void {
        try self.flushWithCompletions(alloc, out, .{ .table = completion });
    }

    pub fn flushWithCompletions(
        self: *MarkdownProcessor,
        alloc: Allocator,
        out: *std.ArrayList(u8),
        completions: payload.MarkdownCompletions,
    ) !void {
        defer self.active_blockquote = null;
        defer self.active_definition = false;
        defer self.active_footnote = null;
        defer self.open_ordered_items.clearRetainingCapacity();
        const had_partial_line = self.line_buf.items.len > 0;
        const len_before = out.items.len;
        if (self.line_buf.items.len > 0) {
            try self.handleModelLine(alloc, self.line_buf.items, false, out, completions);
            self.line_buf.clearRetainingCapacity();
        }
        try self.flushPendingTopLevelLine(alloc, out);
        if (had_partial_line and out.items.len > len_before and out.items[out.items.len - 1] == '\n') {
            out.items.len -= 1;
        }
        if (self.in_pipe_block) try self.finalizePipeBlock(alloc, out, completions.table);
        if (self.in_code_block) {
            try self.finalizeCodeBlock(alloc, out, completions.code);
            self.in_code_block = false;
            self.code_fence = null;
        }
        try self.flushFootnotes(alloc, out);
    }

    /// Renders one line of model text. Control bytes, C1 controls, and invalid
    /// UTF-8 become visible text such as `\x1b[2J` first, so a reply can never
    /// clear the screen, erase scrollback, or switch the terminal's screen.
    /// Joiners and other invisible format characters stay, since emoji
    /// sequences and some scripts need them.
    fn handleModelLine(
        self: *MarkdownProcessor,
        alloc: Allocator,
        line: []const u8,
        line_has_lf: bool,
        out: *std.ArrayList(u8),
        completions: payload.MarkdownCompletions,
    ) !void {
        self.safe_line.clearRetainingCapacity();
        try text_utils.appendTerminalSafeText(alloc, &self.safe_line, line);
        try self.handleLine(alloc, self.safe_line.items, line_has_lf, out, completions);
    }

    fn handleLine(
        self: *MarkdownProcessor,
        alloc: Allocator,
        line: []const u8,
        line_has_lf: bool,
        out: *std.ArrayList(u8),
        completions: payload.MarkdownCompletions,
    ) !void {
        const fs = self.footnoteSink();
        defer self.previous_line_was_blank = tu.isBlankMarkdownLine(line);

        if (self.in_code_block) {
            self.active_definition = false;
            if (self.code_fence) |fence| {
                if (bp.closesCodeFence(line, fence)) {
                    try self.finalizeCodeBlock(alloc, out, completions.code);
                    self.in_code_block = false;
                    self.code_fence = null;
                    return;
                }
            } else if (!tu.isBlankMarkdownLine(line) and !bp.hasIndentedCodePrefix(line)) {
                try self.finalizeCodeBlock(alloc, out, completions.code);
                self.in_code_block = false;
                try self.handleLine(alloc, line, line_has_lf, out, completions);
                return;
            }
            const code_line = if (self.code_fence) |fence|
                bp.stripFenceIndent(line, fence.indent)
            else if (!tu.isBlankMarkdownLine(line))
                bp.deindentCodeLine(line)
            else
                line;
            try self.appendCodeLine(alloc, code_line, line_has_lf, out, completions.code);
            return;
        }

        if (self.in_pipe_block) {
            self.active_definition = false;
            if (bp.isPipeLine(line) and self.pipe_buf.items.len + line.len + 1 <= ansi.max_pipe_buffer_bytes) {
                try self.pipe_buf.appendSlice(alloc, line);
                try self.pipe_buf.append(alloc, '\n');
                self.pipe_last_line_has_lf = line_has_lf;
                return;
            }
            try self.finalizePipeBlock(alloc, out, completions.table);
        }

        if (self.active_footnote) |active| {
            if (bp.footnoteContinuationBody(line)) |body| {
                if (active.append_body) {
                    var note = &self.footnotes.items[active.index];
                    try note.body.append(alloc, '\n');
                    try note.body.appendSlice(alloc, body);
                    self.markOpenBodyLine(line_has_lf);
                }
                return;
            }
            self.active_footnote = null;
        }

        if (bp.parseFootnoteDefinition(line)) |definition| {
            self.active_definition = false;
            try self.flushPendingTopLevelLine(alloc, out);
            try self.beginFootnoteDefinition(alloc, definition);
            self.markOpenBodyLine(line_has_lf);
            return;
        }

        if (completions.thematic_rule != null and self.pending_top_level_line.items.len > 0) {
            if (bp.parseSetextUnderline(line)) |level| {
                self.active_definition = false;
                try block_render.writeHeading(alloc, level, tu.withoutTerminalHardBreakMarker(self.pending_top_level_line.items, true), out, &fs, &link_id_counter, .committed);
                try out.append(alloc, '\n');
                self.pending_top_level_line.clearRetainingCapacity();
                return;
            }
            if (bp.definitionMarkerBody(line)) |body| {
                try self.flushPendingTopLevelLine(alloc, out);
                try block_render.writeDefinitionLine(alloc, body, line_has_lf, out, &fs, &link_id_counter, self.inlineMode(line_has_lf));
                self.active_definition = true;
                return;
            }
            self.active_definition = false;
            try self.flushPendingTopLevelLine(alloc, out);
        }

        if (self.active_blockquote) |blockquote| {
            self.active_definition = false;
            if (bp.isLazyBlockquoteContinuation(line)) {
                try block_render.writeBlockquoteLine(alloc, blockquote, line, line_has_lf, out, &fs, &link_id_counter, self.inlineMode(line_has_lf));
                try out.append(alloc, '\n');
                return;
            }
            self.active_blockquote = null;
        }

        // An indented list marker continues a list, except that a plus sign in
        // indented-code position stays code so diff-style lines are preserved.
        const indented_list_item = bp.hasIndentedCodePrefix(line) and
            (bp.parseUnorderedList(line) != null or bp.parseOrderedList(line) != null);
        const plus_in_code_position = indented_list_item and self.previous_line_was_blank and tu.leftTrim(line)[0] == '+';
        if (indented_list_item and !plus_in_code_position) {
            self.active_definition = false;
            try self.processLine(alloc, line, line_has_lf, out);
            try out.append(alloc, '\n');
            return;
        }

        if (self.previous_line_was_blank and bp.hasIndentedCodePrefix(line)) {
            self.active_definition = false;
            self.in_code_block = true;
            self.code_fence = null;
            self.code_language.clearRetainingCapacity();
            try self.appendCodeLine(alloc, bp.deindentCodeLine(line), line_has_lf, out, completions.code);
            return;
        }

        if (!self.in_code_block and bp.isPipeLine(line)) {
            self.active_definition = false;
            self.in_pipe_block = true;
            try self.pipe_buf.appendSlice(alloc, line);
            try self.pipe_buf.append(alloc, '\n');
            self.pipe_last_line_has_lf = line_has_lf;
            return;
        }

        if (bp.parseCodeFence(line)) |fence| {
            self.active_definition = false;
            self.in_code_block = true;
            self.code_fence = fence;
            self.code_language.clearRetainingCapacity();
            try self.code_language.appendSlice(alloc, bp.codeFenceLanguage(line));
            return;
        }

        if (self.active_definition) {
            if (bp.definitionMarkerBody(line)) |body| {
                try block_render.writeDefinitionLine(alloc, body, line_has_lf, out, &fs, &link_id_counter, self.inlineMode(line_has_lf));
                return;
            }
        }
        self.active_definition = false;

        if (line_has_lf and completions.thematic_rule != null and bp.isSetextCandidate(line)) {
            try self.pending_top_level_line.appendSlice(alloc, line);
            return;
        }

        if (bp.isHorizontalRule(line)) {
            if (completions.thematic_rule) |completion| {
                try completion.deliver(completion.ctx, out);
                return;
            }
        }

        try self.processLine(alloc, line, line_has_lf, out);
        try out.append(alloc, '\n');
    }

    fn appendCodeLine(
        self: *MarkdownProcessor,
        alloc: Allocator,
        line: []const u8,
        line_has_lf: bool,
        out: *std.ArrayList(u8),
        completion: ?*const payload.CodeBlockCompletion,
    ) !void {
        if (completion != null) {
            try self.code_buf.appendSlice(alloc, line);
            try self.code_buf.append(alloc, '\n');
            return;
        }
        try self.processLine(alloc, line, line_has_lf, out);
        try out.append(alloc, '\n');
    }

    fn flushPendingTopLevelLine(self: *MarkdownProcessor, alloc: Allocator, out: *std.ArrayList(u8)) !void {
        if (self.pending_top_level_line.items.len == 0) return;
        try self.processLine(alloc, self.pending_top_level_line.items, true, out);
        try out.append(alloc, '\n');
        self.pending_top_level_line.clearRetainingCapacity();
    }

    fn processLine(
        self: *MarkdownProcessor,
        alloc: Allocator,
        line: []const u8,
        line_has_lf: bool,
        out: *std.ArrayList(u8),
    ) !void {
        const fs = self.footnoteSink();
        if (self.in_code_block) {
            try ansi.writeDim(alloc, out, ansi.vertical_rule_prefix);
            try out.appendSlice(alloc, line);
            return;
        }

        const shift = self.orderedItemShift(line);

        if (bp.isHorizontalRule(line)) {
            try ansi.writeHorizontalRule(alloc, out);
            return;
        }

        if (bp.parseHeader(tu.withoutTerminalHardBreakMarker(line, line_has_lf))) |header| {
            try block_render.writeHeading(alloc, header.level, header.content, out, &fs, &link_id_counter, self.inlineMode(line_has_lf));
            return;
        }

        if (bp.parseBlockquote(line)) |parsed| {
            const blockquote = bp.BlockquotePrefix{
                .indent = shift + parsed.indent.len,
                .depth = parsed.depth,
            };
            self.active_blockquote = if (bp.isBlockquoteParagraph(parsed.content)) blockquote else null;
            try block_render.writeBlockquoteLine(alloc, blockquote, parsed.content, line_has_lf, out, &fs, &link_id_counter, self.inlineMode(line_has_lf));
            return;
        }

        try out.appendNTimes(alloc, ' ', shift);
        if (try block_render.writeListLine(alloc, line, line_has_lf, .right_aligned, out, &fs, &link_id_counter, self.inlineMode(line_has_lf))) {
            if (bp.parseOrderedList(line)) |item| {
                try self.open_ordered_items.append(alloc, .{
                    .content_column = item.indent.len + item.marker.len + 1,
                    .shift = shift + block_render.orderedMarkerPad(item.marker),
                });
            }
            return;
        }

        try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(line, line_has_lf), out, false, &fs, &link_id_counter, self.inlineMode(line_has_lf));
    }

    /// Returns how far padded ordered markers move `line`, first closing the
    /// open items it is not indented into. Blank lines keep items open.
    fn orderedItemShift(self: *MarkdownProcessor, line: []const u8) usize {
        if (tu.isBlankMarkdownLine(line)) return 0;
        const indent = line.len - tu.leftTrim(line).len;
        while (self.open_ordered_items.last()) |item| {
            if (indent >= item.content_column) return item.shift;
            _ = self.open_ordered_items.pop();
        }
        return 0;
    }

    fn finalizePipeBlock(
        self: *MarkdownProcessor,
        alloc: Allocator,
        out: *std.ArrayList(u8),
        completion: ?*const payload.TableCompletion,
    ) !void {
        const fs = self.footnoteSink();
        defer {
            self.pipe_buf.clearRetainingCapacity();
            self.in_pipe_block = false;
            self.pipe_last_line_has_lf = false;
        }

        if (bp.isValidTable(self.pipe_buf.items)) {
            if (completion) |sink| {
                var table = try block_render.parseTablePayloadWithFootnotes(alloc, self.pipe_buf.items, &fs, &link_id_counter, self.openRows());
                var delivered = false;
                errdefer if (!delivered) table.deinit(alloc);
                try sink.deliver(sink.ctx, table, out);
                delivered = true;
                return;
            }
            try block_render.renderTable(alloc, self.pipe_buf.items, out, &fs, &link_id_counter, self.openRows());
            return;
        }

        var start: usize = 0;
        while (start < self.pipe_buf.items.len) {
            const end = std.mem.findScalarPos(u8, self.pipe_buf.items, start, '\n') orelse self.pipe_buf.items.len;
            const line_has_lf = if (end + 1 == self.pipe_buf.items.len) self.pipe_last_line_has_lf else true;
            try self.processLine(alloc, self.pipe_buf.items[start..end], line_has_lf, out);
            if (line_has_lf) try out.append(alloc, '\n');
            start = end + 1;
        }
    }

    fn finalizeCodeBlock(
        self: *MarkdownProcessor,
        alloc: Allocator,
        out: *std.ArrayList(u8),
        completion: ?*const payload.CodeBlockCompletion,
    ) !void {
        defer {
            self.code_buf.clearRetainingCapacity();
            self.code_language.clearRetainingCapacity();
        }

        const sink = completion orelse return;
        var language: ?[]u8 = try alloc.dupe(u8, self.code_language.items);
        errdefer if (language) |owned| alloc.free(owned);
        const code = try alloc.dupe(u8, self.code_buf.items);
        var block = payload.CodeBlockPayload{
            .language = language.?,
            .code = code,
        };
        language = null;
        var delivered = false;
        errdefer if (!delivered) block.deinit(alloc);
        try sink.deliver(sink.ctx, block, out);
        delivered = true;
    }

    fn deinitFootnotes(self: *MarkdownProcessor, alloc: Allocator) void {
        for (self.footnotes.items) |*note| note.deinit(alloc);
        self.footnotes.clearAndFree(alloc);
    }

    fn findOrAppendFootnote(self: *MarkdownProcessor, alloc: Allocator, label: []const u8) !usize {
        for (self.footnotes.items, 0..) |note, index| {
            if (std.mem.eql(u8, note.label, label)) return index;
        }

        const owned_label = try alloc.dupe(u8, label);
        errdefer alloc.free(owned_label);
        try self.footnotes.append(alloc, .{ .label = owned_label });
        return self.footnotes.items.len - 1;
    }

    fn footnoteSink(self: *MarkdownProcessor) payload.FootnoteSink {
        return .{ .ctx = self, .register = registerFootnoteThunk };
    }

    fn registerFootnoteReference(self: *MarkdownProcessor, alloc: Allocator, label: []const u8) !usize {
        const index = try self.findOrAppendFootnote(alloc, label);
        if (self.footnotes.items[index].number == null) {
            self.next_footnote_number += 1;
            self.footnotes.items[index].number = self.next_footnote_number;
        }
        return self.footnotes.items[index].number.?;
    }

    fn beginFootnoteDefinition(
        self: *MarkdownProcessor,
        alloc: Allocator,
        definition: bp.ParsedFootnoteDefinition,
    ) !void {
        const index = try self.findOrAppendFootnote(alloc, definition.label);
        const note = &self.footnotes.items[index];
        if (note.has_definition) {
            self.active_footnote = .{ .index = index, .append_body = false };
            return;
        }
        try note.body.appendSlice(alloc, definition.body);
        note.has_definition = true;
        self.active_footnote = .{ .index = index, .append_body = true };
    }

    fn flushFootnotes(self: *MarkdownProcessor, alloc: Allocator, out: *std.ArrayList(u8)) !void {
        const fs = self.footnoteSink();
        defer self.deinitFootnotes(alloc);
        defer self.next_footnote_number = 0;

        var has_note = false;
        for (self.footnotes.items) |note| {
            if (note.number != null and note.has_definition) {
                has_note = true;
                break;
            }
        }
        if (!has_note) return;

        while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') {
            out.items.len -= 1;
        }
        if (out.items.len > 0) {
            try out.appendSlice(alloc, "\n\n");
        } else {
            try out.append(alloc, '\n');
        }

        var number: usize = 1;
        while (number <= self.next_footnote_number) : (number += 1) {
            for (self.footnotes.items, 0..) |*note, index| {
                if (note.number != number or !note.has_definition) continue;
                try block_render.writeFootnoteDefinitionMarker(alloc, out, number);
                const last_line_mode = if (self.open_body_note == index) self.open_line_mode else .committed;
                try block_render.writeFootnoteBody(alloc, note.body.items, out, &fs, number, &link_id_counter, last_line_mode);
                break;
            }
        }
    }
};

const pipe_byte: u8 = '|';
const delimiter_row_lead = "|";
const delimiter_cell = " --- |";
const max_utf8_sequence_bytes = 4;

const block_marker_bytes = "-=*#>|`_+~";

/// A line made only of block markers and spaces, or of one number and a dot or
/// a parenthesis, shows nothing until it has text. Such a line would otherwise
/// reach the block parser, which reads `** **` as a thematic break.
fn opensWithBlockMarkersOnly(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t");
    const digits = digitPrefixLength(trimmed);
    if (digits > 0 and digits < trimmed.len and (trimmed[digits] == '.' or trimmed[digits] == ')')) {
        return std.mem.trim(u8, trimmed[digits + 1 ..], " \t").len == 0;
    }
    for (trimmed) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        if (std.mem.findScalar(u8, block_marker_bytes, byte) == null) return false;
    }
    return true;
}

fn digitPrefixLength(text: []const u8) usize {
    var length: usize = 0;
    while (length < text.len and std.ascii.isDigit(text[length])) length += 1;
    return length;
}

/// What a provisional render found on the held text.
pub const ProvisionalResult = struct {
    /// An open-end rule, a hidden block-marker line, or split UTF-8 changed the open line.
    open_end_applied: bool = false,
    /// The held pipe row was completed with a display delimiter row.
    table_header_completed: bool = false,
};

/// Frees the events from `first` on, then removes them from `events`.
pub fn deinitEventsFrom(alloc: Allocator, events: *std.ArrayList(Event), first: usize) void {
    for (events.items[first..]) |*event| event.deinit(alloc);
    events.shrinkRetainingCapacity(first);
}

/// Frees every event in `events`, then the list.
pub fn deinitEvents(alloc: Allocator, events: *std.ArrayList(Event)) void {
    deinitEventsFrom(alloc, events, 0);
    events.deinit(alloc);
}

/// Collects a flush as events in stream order: the text before each table,
/// code block, or rule, then that block. Its completions are the ones the
/// stream uses for committed text.
const EventCollector = struct {
    alloc: Allocator,
    events: *std.ArrayList(Event),
    table_sink: TableCompletion = undefined,
    code_sink: CodeBlockCompletion = undefined,
    rule_sink: ThematicRuleCompletion = undefined,

    fn completions(self: *EventCollector) MarkdownCompletions {
        self.table_sink = .{ .ctx = self, .deliver = deliverTable };
        self.code_sink = .{ .ctx = self, .deliver = deliverCode };
        self.rule_sink = .{ .ctx = self, .deliver = deliverRule };
        return .{ .table = &self.table_sink, .code = &self.code_sink, .thematic_rule = &self.rule_sink };
    }

    fn appendPendingText(self: *EventCollector, out: *std.ArrayList(u8)) !void {
        if (out.items.len == 0) return;
        const text = try self.alloc.dupe(u8, out.items);
        errdefer self.alloc.free(text);
        try self.events.append(self.alloc, .{ .text = text });
        out.clearRetainingCapacity();
    }

    /// On error the caller still owns the payload and frees it.
    fn deliverTable(raw: *anyopaque, table: TablePayload, out: *std.ArrayList(u8)) anyerror!void {
        const self: *EventCollector = @ptrCast(@alignCast(raw));
        try self.appendPendingText(out);
        try self.events.append(self.alloc, .{ .table = table });
    }

    /// On error the caller still owns the payload and frees it.
    fn deliverCode(raw: *anyopaque, block: CodeBlockPayload, out: *std.ArrayList(u8)) anyerror!void {
        const self: *EventCollector = @ptrCast(@alignCast(raw));
        try self.appendPendingText(out);
        try self.events.append(self.alloc, .{ .code_block = block });
    }

    fn deliverRule(raw: *anyopaque, out: *std.ArrayList(u8)) anyerror!void {
        const self: *EventCollector = @ptrCast(@alignCast(raw));
        try self.appendPendingText(out);
        try self.events.append(self.alloc, .thematic_rule);
    }
};

/// A pipe row with no delimiter row yet is a table header the stream has not
/// finished. The preview adds a display-only delimiter row with the same
/// column count, so the header shows as a table and never as raw pipes.
fn completeOpenTableHeader(alloc: Allocator, preview: *MarkdownProcessor) !bool {
    if (preview.in_pipe_block) {
        if (!isSingleHeaderLine(preview.pipe_buf.items)) return false;
        if (!acceptsDelimiterNext(preview.line_buf.items)) return false;
        const header = std.mem.trimEnd(u8, preview.pipe_buf.items, "\n");
        try appendDelimiterRow(alloc, &preview.pipe_buf, tableColumnCount(header));
        preview.pipe_last_line_has_lf = true;
        return true;
    }
    const open = preview.line_buf.items;
    if (open.len == 0 or !bp.isPipeLine(open) or bp.isSeparatorLine(open)) return false;
    const columns = tableColumnCount(open);
    if (!try wouldFormTable(alloc, preview, columns)) return false;
    try preview.pipe_buf.appendSlice(alloc, open);
    try preview.pipe_buf.append(alloc, '\n');
    preview.open_pipe_row = std.mem.count(u8, preview.pipe_buf.items, "\n") - 1;
    preview.line_buf.clearRetainingCapacity();
    preview.in_pipe_block = true;
    try appendDelimiterRow(alloc, &preview.pipe_buf, columns);
    preview.pipe_last_line_has_lf = true;
    return true;
}

/// True when the committed path turns the open pipe row into a table once a
/// delimiter row follows it. It runs the committed path on a copy, so the context
/// the row sits in (a footnote, a quote, a list) decides, as it does for the commit.
fn wouldFormTable(alloc: Allocator, preview: *const MarkdownProcessor, columns: usize) !bool {
    // The copy's flush numbers links from the shared counter, so the counter is restored.
    const saved_link_id = link_id_counter;
    defer link_id_counter = saved_link_id;
    var copy = try preview.cloneForPreview(alloc);
    defer copy.deinit(alloc);
    var found: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &found);
    var collector = EventCollector{ .alloc = alloc, .events = &found };
    const completions = collector.completions();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var delimiter: std.ArrayList(u8) = .empty;
    defer delimiter.deinit(alloc);
    try delimiter.append(alloc, '\n');
    try delimiter.append(alloc, pipe_byte);
    for (0..columns) |_| try delimiter.appendSlice(alloc, "---|");
    try delimiter.append(alloc, '\n');
    try copy.pushWithCompletions(alloc, delimiter.items, &out, completions);
    try copy.flushWithCompletions(alloc, &out, completions);
    for (found.items) |event| {
        if (event == .table) return true;
    }
    return false;
}

fn isSingleHeaderLine(pipe_buf: []const u8) bool {
    return pipe_buf.len > 0 and std.mem.findScalar(u8, pipe_buf, '\n') == pipe_buf.len - 1;
}

/// The open line may be the delimiter row that is still arriving. Then the
/// preview waits for it, so it does not add a second one.
fn acceptsDelimiterNext(open: []const u8) bool {
    if (open.len == 0) return true;
    return bp.isPipeLine(open) and !bp.isSeparatorLine(open);
}

/// Counts the columns of a header row: the unescaped pipes between its outer pipes, plus one.
fn tableColumnCount(row: []const u8) usize {
    var body = std.mem.trim(u8, row, " \t");
    if (body.len > 0 and body[0] == pipe_byte) body = body[1..];
    if (body.len > 0 and body[body.len - 1] == pipe_byte and !tu.isEscapedPunctuationAt(body, body.len - 1)) {
        body = body[0 .. body.len - 1];
    }
    var pipes: usize = 0;
    for (body, 0..) |byte, index| {
        if (byte == pipe_byte and !tu.isEscapedPunctuationAt(body, index)) pipes += 1;
    }
    return pipes + 1;
}

fn appendDelimiterRow(alloc: Allocator, buf: *std.ArrayList(u8), columns: usize) !void {
    try buf.appendSlice(alloc, delimiter_row_lead);
    for (0..columns) |_| try buf.appendSlice(alloc, delimiter_cell);
    try buf.append(alloc, '\n');
}

/// Drops the bytes of a multi-byte character that has not finished arriving,
/// so the preview never shows them as escapes.
fn dropIncompleteUtf8(held: *std.ArrayList(u8)) void {
    held.shrinkRetainingCapacity(withoutIncompleteUtf8(held.items).len);
}

fn withoutIncompleteUtf8(text: []const u8) []const u8 {
    var index = text.len;
    var scanned: usize = 0;
    while (index > 0 and scanned < max_utf8_sequence_bytes) : (scanned += 1) {
        index -= 1;
        if (isUtf8Continuation(text[index])) continue;
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return text;
        return if (text.len - index < length) text[0..index] else text;
    }
    return text;
}

fn isUtf8Continuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

fn registerFootnoteThunk(ctx: *anyopaque, alloc: Allocator, label: []const u8) anyerror!usize {
    const self: *MarkdownProcessor = @ptrCast(@alignCast(ctx));
    return self.registerFootnoteReference(alloc, label);
}

test "markdown link is blue and underlined inside its OSC 8 scope" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(alloc, "see [docs](https://example.com) please\n", &out);

    var expected_buf: [256]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "see \x1b]8;id=fx-{d};https://example.com\x1b\\\x1b[38;5;75m\x1b[4mdocs\x1b[24m\x1b[39m\x1b]8;;\x1b\\ please\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "markdown link destination keeps balanced parentheses" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(alloc, "[w](https://en.wikipedia.org/wiki/Foo_(bar)) tail\n", &out);

    var expected_buf: [256]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "\x1b]8;id=fx-{d};https://en.wikipedia.org/wiki/Foo_(bar)\x1b\\\x1b[38;5;75m\x1b[4mw\x1b[24m\x1b[39m\x1b]8;;\x1b\\ tail\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "markdown link drops its title and unwraps angle destinations" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(
        alloc,
        "[t](https://example.com \"Title text\") [s](https://example.com/s 'single') [a](<https://example.com/a b>)\n",
        &out,
    );

    var expected_buf: [512]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "\x1b]8;id=fx-{d};https://example.com\x1b\\\x1b[38;5;75m\x1b[4mt\x1b[24m\x1b[39m\x1b]8;;\x1b\\ " ++
            "\x1b]8;id=fx-{d};https://example.com/s\x1b\\\x1b[38;5;75m\x1b[4ms\x1b[24m\x1b[39m\x1b]8;;\x1b\\ " ++
            "\x1b]8;id=fx-{d};https://example.com/a b\x1b\\\x1b[38;5;75m\x1b[4ma\x1b[24m\x1b[39m\x1b]8;;\x1b\\\n",
        .{ id_before, id_before + 1, id_before + 2 },
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "markdown link with unbalanced or spaced destination stays literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "[u](https://e.com/(x) [v](https://e.com/a b) [w](https://e.com \"open)\n", &out);
    try std.testing.expectEqualStrings("[u](https://e.com/(x) [v](https://e.com/a b) [w](https://e.com \"open)\n", out.items);
}

test "markdown image renders its alt text with an image marker inside one OSC 8 scope" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(alloc, "see ![architecture diagram](https://example.com/diagram.png) please\n", &out);

    var expected_buf: [512]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "see \x1b]8;id=fx-{d};https://example.com/diagram.png\x1b\\\x1b[38;5;75m\x1b[4m▧ architecture diagram\x1b[24m\x1b[39m\x1b]8;;\x1b\\ please\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "markdown image uses a stable fallback for empty alt text" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(alloc, "![](https://example.com/diagram.png)\n", &out);

    var expected_buf: [256]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "\x1b]8;id=fx-{d};https://example.com/diagram.png\x1b\\\x1b[38;5;75m\x1b[4m▧ image\x1b[24m\x1b[39m\x1b]8;;\x1b\\\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "markdown image unescapes alt punctuation through the existing link emitter" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(alloc, "![architecture \\*diagram\\*](https://example.com/diagram.png)\n", &out);

    var expected_buf: [256]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "\x1b]8;id=fx-{d};https://example.com/diagram.png\x1b\\\x1b[38;5;75m\x1b[4m▧ architecture *diagram*\x1b[24m\x1b[39m\x1b]8;;\x1b\\\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "escaped and malformed markdown images remain literal without OSC 8" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "\\![alt](https://example.com/diagram.png) and \\!\n", &out);
    try std.testing.expectEqualStrings("![alt](https://example.com/diagram.png) and !\n", out.items);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);

    out.clearRetainingCapacity();
    try processor.push(alloc, "![alt](https://example.com/diagram.png\n", &out);
    try std.testing.expectEqualStrings("![alt](https://example.com/diagram.png\n", out.items);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);

    var oversized_url: [max_link_url_bytes + 1]u8 = undefined;
    @memset(&oversized_url, 'a');
    var input_buf: [max_link_url_bytes + 16]u8 = undefined;
    const oversized = try std.mem.print(&input_buf, "![alt]({s})\n", .{oversized_url[0..]});
    out.clearRetainingCapacity();
    try processor.push(alloc, oversized, &out);
    try std.testing.expectEqualStrings(oversized, out.items);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);
}

test "model control sequences render as visible text while markdown keeps its own styling" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // A stream can split an escape sequence and a UTF-8 C1 control across chunks.
    try processor.push(alloc, "**bold** \x1b[2J \x1b[?10", &out);
    try processor.push(alloc, "49h \xc2", &out);
    try processor.push(alloc, "\x9b31m \x1b[3J end\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[1mbold\x1b[22m \\x1b[2J \\x1b[?1049h \\u{009b}31m \\x1b[3J end\n",
        out.items,
    );

    // A control byte inside a link target becomes text before the link is
    // parsed, so the OSC 8 hyperlink fx writes carries no raw control byte.
    out.clearRetainingCapacity();
    try processor.push(alloc, "![alt](https://example.com/\x1bdiagram.png)\n", &out);
    try std.testing.expect(std.mem.find(u8, out.items, "https://example.com/\\x1bdiagram.png") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "example.com/\x1b") == null);

    out.clearRetainingCapacity();
    try processor.push(alloc, "`https://example.com\x07`\n", &out);
    try std.testing.expect(std.mem.find(u8, out.items, "https://example.com\\x07") != null);
    try std.testing.expect(std.mem.findScalar(u8, out.items, 0x07) == null);

    // Joined emoji keep their zero-width joiner.
    out.clearRetainingCapacity();
    try processor.push(alloc, "team \u{1f469}\u{200d}\u{1f4bb}\n", &out);
    try std.testing.expectEqualStrings("team \u{1f469}\u{200d}\u{1f4bb}\n", out.items);

    // The last line has no newline and reaches the output through flush.
    out.clearRetainingCapacity();
    try processor.push(alloc, "last \x1b]0;title\x07 line", &out);
    try processor.flush(alloc, &out);
    try std.testing.expectEqualStrings("last \\x1b]0;title\\x07 line", out.items);
}

test "markdown images preserve code isolation, chunk buffering, and heading underline" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "`![literal](https://example.com/literal.png)`\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[38;5;255m![literal](https://example.com/literal.png)\x1b[39m\n",
        out.items,
    );
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);

    out.clearRetainingCapacity();
    try processor.push(alloc, "![architecture", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try processor.push(alloc, "](https://example.com/diagram.png)\n", &out);
    try std.testing.expect(std.mem.find(u8, out.items, "▧ architecture") != null);

    out.clearRetainingCapacity();
    const id_before = link_id_counter;
    try processor.push(alloc, "### before ![diagram](https://example.com/diagram.png) after\n", &out);
    var expected_buf: [512]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "\x1b[4mbefore \x1b]8;id=fx-{d};https://example.com/diagram.png\x1b\\\x1b[38;5;75m\x1b[4m▧ diagram\x1b[24m\x1b[39m\x1b]8;;\x1b\\\x1b[4m after\x1b[24m\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "table payload measures markdown images by their visible label" {
    const alloc = std.testing.allocator;
    var table = try parseTablePayload(
        alloc,
        "| Asset | Status |\n" ++
            "| --- | --- |\n" ++
            "| ![diagram](https://example.com/diagram.png) | ready |\n",
    );
    defer table.deinit(alloc);

    const cell = table.rows[1].cells[0];
    try std.testing.expect(std.mem.find(u8, cell, "▧ diagram") != null);
    try std.testing.expect(std.mem.find(u8, cell, "![diagram]") == null);
    try std.testing.expectEqual(
        display_width.visibleWidthIgnoringAnsi("▧ diagram"),
        display_width.visibleWidthIgnoringAnsi(cell),
    );
}

test "table payload links use the shared OSC 8 identifier sequence" {
    const alloc = std.testing.allocator;
    const id_before = link_id_counter;

    var first = try parseTablePayload(
        alloc,
        "| Link |\n" ++
            "|------|\n" ++
            "| [first](https://first.example) |\n",
    );
    defer first.deinit(alloc);

    var second = try parseTablePayload(
        alloc,
        "| Link |\n" ++
            "|------|\n" ++
            "| [second](https://second.example) |\n",
    );
    defer second.deinit(alloc);

    var first_id_buf: [64]u8 = undefined;
    const first_id = try std.mem.print(&first_id_buf, "\x1b]8;id=fx-{d};https://first.example", .{id_before});
    try std.testing.expect(std.mem.find(u8, first.rows[1].cells[0], first_id) != null);

    var second_id_buf: [64]u8 = undefined;
    const second_id = try std.mem.print(&second_id_buf, "\x1b]8;id=fx-{d};https://second.example", .{id_before +% 1});
    try std.testing.expect(std.mem.find(u8, second.rows[1].cells[0], second_id) != null);
}

test "bare URL is underlined and leaves sentence punctuation literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(alloc, "visit https://example.com/docs, now\n", &out);

    var expected_buf: [256]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "visit \x1b]8;id=fx-{d};https://example.com/docs\x1b\\\x1b[38;5;75m\x1b[4mhttps://example.com/docs\x1b[24m\x1b[39m\x1b]8;;\x1b\\, now\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "bare URL is recognized after streamed input chunks" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(alloc, "visit https", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try processor.push(alloc, "://example.com/docs\n", &out);

    var expected_buf: [256]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "visit \x1b]8;id=fx-{d};https://example.com/docs\x1b\\\x1b[38;5;75m\x1b[4mhttps://example.com/docs\x1b[24m\x1b[39m\x1b]8;;\x1b\\\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "angle autolinks use literal URI and email labels" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(
        alloc,
        "see <https://example.com/docs\\_literal> and <dev@example.com> plus <git+ssh://example.com/repo>\n",
        &out,
    );

    var expected_buf: [1024]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "see \x1b]8;id=fx-{d};https://example.com/docs\\_literal\x1b\\\x1b[38;5;75m\x1b[4mhttps://example.com/docs\\_literal\x1b[24m\x1b[39m\x1b]8;;\x1b\\ and " ++
            "\x1b]8;id=fx-{d};mailto:dev@example.com\x1b\\\x1b[38;5;75m\x1b[4mdev@example.com\x1b[24m\x1b[39m\x1b]8;;\x1b\\ plus " ++
            "\x1b]8;id=fx-{d};git+ssh://example.com/repo\x1b\\\x1b[38;5;75m\x1b[4mgit+ssh://example.com/repo\x1b[24m\x1b[39m\x1b]8;;\x1b\\\n",
        .{ id_before, id_before +% 1, id_before +% 2 },
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "rejected angle candidates suppress nested link emission" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "<not-an-autolink https://inner.example>\n" ++
        "\\<not-an-autolink https://inner.example>\n" ++
        "<<https://inner.example>>\n" ++
        "<[inner](https://inner.example)>\n" ++
        "<[inner](https://one.example) https://two.example>\n" ++
        "\\<https://escaped.example>\n" ++
        "<a:x> <dev@bad-.example> <https://has space>\n" ++
        "<not-an-autolink https://unterminated.example\n" ++
        "`<https://code.example>`\n";
    const expected =
        "<not-an-autolink https://inner.example>\n" ++
        "<not-an-autolink https://inner.example>\n" ++
        "<<https://inner.example>>\n" ++
        "<[inner](https://inner.example)>\n" ++
        "<[inner](https://one.example) https://two.example>\n" ++
        "<https://escaped.example>\n" ++
        "<a:x> <dev@bad-.example> <https://has space>\n" ++
        "<not-an-autolink https://unterminated.example\n" ++
        "\x1b[38;5;255m<https://code.example>\x1b[39m\n";

    try processor.push(alloc, input, &out);
    try std.testing.expectEqualStrings(expected, out.items);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);
}

test "angle email autolink applies the destination cap including mailto" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const suffix = "@a.com";
    var local: [max_link_url_bytes]u8 = undefined;
    @memset(&local, 'a');
    const local_len = max_link_url_bytes - "mailto:".len - suffix.len + 1;
    var input_buf: [max_link_url_bytes + 32]u8 = undefined;
    const input = try std.mem.print(&input_buf, "<{s}{s}>\n", .{ local[0..local_len], suffix });

    try processor.push(alloc, input, &out);
    try std.testing.expectEqualStrings(input, out.items);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);
}

test "standalone URL in code is linked while excluded boundaries stay literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(
        alloc,
        "`https://code.example` wordhttps://word.example <<https://angle.example>>\n",
        &out,
    );
    var expected_buf: [512]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "\x1b[38;5;255m\x1b]8;id=fx-{d};https://code.example\x1b\\https://code.example\x1b]8;;\x1b\\\x1b[39m wordhttps://word.example <<https://angle.example>>\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "inline code URLs keep literal bytes and trailing punctuation outside links" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(alloc, "See `https://example.com/path_~*.` and `https://example.com/a\\_b`.\n", &out);
    var expected_buf: [1024]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "See \x1b[38;5;255m\x1b]8;id=fx-{d};https://example.com/path_~*\x1b\\https://example.com/path_~*\x1b]8;;\x1b\\.\x1b[39m and " ++
            "\x1b[38;5;255m\x1b]8;id=fx-{d};https://example.com/a\\_b\x1b\\https://example.com/a\\_b\x1b]8;;\x1b\\\x1b[39m.\n",
        .{ id_before, id_before +% 1 },
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "inline code URLs preserve literal trailing URI punctuation" {
    const alloc = std.testing.allocator;
    const urls = [_][]const u8{
        "https://example.com/a!",
        "https://example.com/a?",
        "https://example.com/a;",
        "https://example.com/a:",
        "https://example.com/a,",
    };
    for (urls) |url| {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        var input_buf: [128]u8 = undefined;
        const input = try std.mem.print(&input_buf, "Open `{s}`\n", .{url});
        const id_before = link_id_counter;
        try processor.push(alloc, input, &out);
        var expected_buf: [256]u8 = undefined;
        const expected = try std.mem.print(
            &expected_buf,
            "Open \x1b[38;5;255m\x1b]8;id=fx-{d};{s}\x1b\\{s}\x1b]8;;\x1b\\\x1b[39m\n",
            .{ id_before, url, url },
        );
        try std.testing.expectEqualStrings(expected, out.items);
    }
}

test "non-URL and unsafe inline code stays literal" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "`not a URL`\n",
        "`curl https://example.com`\n",
        "`https://example.com more`\n",
        "`http://`\n",
        "`<https://example.com>`\n",
    };
    for (cases) |input| {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        try processor.push(alloc, input, &out);
        try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);
    }

    var oversized: [max_link_url_bytes + 1]u8 = undefined;
    @memset(&oversized, 'a');
    var input_buf: [max_link_url_bytes + 32]u8 = undefined;
    const input = try std.mem.print(&input_buf, "`https://{s}`\n", .{oversized[0..]});
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try processor.push(alloc, input, &out);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);
}

test "unsafe bare URL renders literally" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var oversized: [max_link_url_bytes + 1]u8 = undefined;
    @memset(&oversized, 'a');
    var input_buf: [max_link_url_bytes + 16]u8 = undefined;
    const input = try std.mem.print(&input_buf, "https://{s}\n", .{oversized[0..]});

    try processor.push(alloc, input, &out);
    try std.testing.expectEqualStrings(input, out.items);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);
}

test "bare URLs leave closing emphasis delimiters for the inline scanner" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(
        alloc,
        "**https://bold.example** *https://italic.example* ~~https://strike.example~~ tail\n",
        &out,
    );

    var expected_buf: [1024]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "\x1b[1m\x1b]8;id=fx-{d};https://bold.example\x1b\\\x1b[38;5;75m\x1b[4mhttps://bold.example\x1b[24m\x1b[39m\x1b]8;;\x1b\\\x1b[22m " ++
            "\x1b[3m\x1b]8;id=fx-{d};https://italic.example\x1b\\\x1b[38;5;75m\x1b[4mhttps://italic.example\x1b[24m\x1b[39m\x1b]8;;\x1b\\\x1b[23m " ++
            "\x1b[9m\x1b]8;id=fx-{d};https://strike.example\x1b\\\x1b[38;5;75m\x1b[4mhttps://strike.example\x1b[24m\x1b[39m\x1b]8;;\x1b\\\x1b[29m tail\n",
        .{ id_before, id_before +% 1, id_before +% 2 },
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "malformed formatted link suppresses bare URL recognition" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "see [docs](https://example.com missing close\n", &out);
    try std.testing.expectEqualStrings("see [docs](https://example.com missing close\n", out.items);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);
}

test "heading underline resumes after a link closes its local underline" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(alloc, "### before [link](https://example.com) after\nbody\n", &out);

    var expected_buf: [512]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "\x1b[4mbefore \x1b]8;id=fx-{d};https://example.com\x1b\\\x1b[38;5;75m\x1b[4mlink\x1b[24m\x1b[39m\x1b]8;;\x1b\\\x1b[4m after\x1b[24m\nbody\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "two markdown links get distinct ids" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "[a](https://a.example) and [b](https://b.example)\n", &out);
    var seq_buf: [32]u8 = undefined;
    const first_marker = try std.mem.print(&seq_buf, "id=fx-", .{});
    var occurrences: usize = 0;
    var idx: usize = 0;
    while (std.mem.find(u8, out.items[idx..], first_marker)) |off| : (idx += off + first_marker.len) {
        occurrences += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), occurrences);
}

test "url over OSC 8 size cap renders literally" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var oversized_buf: [3000]u8 = undefined;
    @memset(&oversized_buf, 'a');
    const url = oversized_buf[0 .. max_link_url_bytes + 1];
    var input_buf: [4000]u8 = undefined;
    const input = try std.mem.print(&input_buf, "see [x]({s}) end\n", .{url});

    try processor.push(alloc, input, &out);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);
    try std.testing.expect(std.mem.find(u8, out.items, "[x](") != null);
}

test "unmatched bracket renders literally" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "list [1, 2, 3] of items\n", &out);
    try std.testing.expectEqualStrings("list [1, 2, 3] of items\n", out.items);
}

test "link with empty url renders literally" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "see [docs]() now\n", &out);
    try std.testing.expectEqualStrings("see [docs]() now\n", out.items);
}

test "plain text passes through unchanged" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "hello world\n", &out);
    try std.testing.expectEqualStrings("hello world\n", out.items);
}

test "backslash escapes keep inline punctuation literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "literal \\*em\\* \\*\\*bold\\*\\* \\_italic\\_ \\_\\_strong\\_\\_ \\~\\~strike\\~\\~ \\`code\\` \\[docs](https://example.com) \\\\ \\| \\! \\# \\>\n",
        &out,
    );

    try std.testing.expectEqualStrings(
        "literal *em* **bold** _italic_ __strong__ ~~strike~~ `code` [docs](https://example.com) \\ | ! # >\n",
        out.items,
    );
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b") == null);
}

test "backslash escapes survive heading preprocessing and code spans" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "## \\*\\*literal bold\\*\\* and `\\*code\\*`\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[1m**literal bold** and \x1b[38;5;255m\\*code\\*\x1b[39m\x1b[22m\n",
        out.items,
    );
}

test "completed Markdown lines consume one terminal hard-break backslash" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "plain\\\n" ++
            "# heading\\\n" ++
            "- list\\\n" ++
            "> quote\\\n" ++
            "two\\\\\n" ++
            "three\\\\\\\n",
        &out,
    );

    try std.testing.expectEqualStrings(
        "plain\n" ++
            "\x1b[1m\x1b[4mheading\x1b[24m\x1b[22m\n" ++
            "\x1b[2m\xe2\x80\xa2 \x1b[22mlist\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mquote\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mtwo\\\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mthree\\\n",
        out.items,
    );
}

test "terminal hard-break backslashes preserve EOF and code content" {
    const alloc = std.testing.allocator;

    {
        const Capture = struct {
            fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
        };
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        var capture: u8 = 0;
        var completion = ThematicRuleCompletion{
            .ctx = &capture,
            .deliver = Capture.deliver,
        };

        try processor.pushWithCompletions(alloc, "eof\\", &out, .{ .thematic_rule = &completion });
        try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });
        try std.testing.expectEqualStrings("eof\\", out.items);
    }

    {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        try processor.push(alloc, "```\ncode\\\n```\n", &out);
        try std.testing.expectEqualStrings("\x1b[2m\xe2\x94\x82 \x1b[22mcode\\\n", out.items);
    }
}

test "Setext and invalid pipe fallback retain source line completion" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        calls: usize = 0,

        fn deliver(raw: *anyopaque, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        var capture = Capture{};
        var completion = ThematicRuleCompletion{
            .ctx = &capture,
            .deliver = Capture.deliver,
        };

        try processor.pushWithCompletions(
            alloc,
            "Setext\\\n---\n",
            &out,
            .{ .thematic_rule = &completion },
        );
        try std.testing.expectEqualStrings("\x1b[1mSetext\x1b[22m\n", out.items);
        try std.testing.expectEqual(@as(usize, 0), capture.calls);
    }

    {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        try processor.push(alloc, "| prior\\\n| eof\\", &out);
        try processor.flush(alloc, &out);
        try std.testing.expectEqualStrings("| prior\n| eof\\", out.items);
    }
}

test "link labels unescape visible punctuation" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(alloc, "[docs \\*literal\\*](https://example.com)\n", &out);

    var expected_buf: [256]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "\x1b]8;id=fx-{d};https://example.com\x1b\\\x1b[38;5;75m\x1b[4mdocs *literal*\x1b[24m\x1b[39m\x1b]8;;\x1b\\\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "backslash escapes stay literal in Setext headings" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        calls: usize = 0,

        fn deliver(raw: *anyopaque, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "\\*\\*literal bold\\*\\*\n---\n",
        &out,
        .{ .thematic_rule = &completion },
    );

    try std.testing.expectEqualStrings("\x1b[1m**literal bold**\x1b[22m\n", out.items);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
}

test "bold double-asterisk wraps with ANSI" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "hi **there** friend\n", &out);
    try std.testing.expectEqualStrings("hi \x1b[1mthere\x1b[22m friend\n", out.items);
}

test "italic single-asterisk wraps with ANSI" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "use *this* quickly\n", &out);
    try std.testing.expectEqualStrings("use \x1b[3mthis\x1b[23m quickly\n", out.items);
}

test "underscore emphasis styles valid spans and preserves invalid markers" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "paragraph _italic_ and __bold__ with snake_case, snake__case, _ spaced_, and __ spaced__.\n",
        &out,
    );
    try std.testing.expectEqualStrings(
        "paragraph \x1b[3mitalic\x1b[23m and \x1b[1mbold\x1b[22m with snake_case, snake__case, _ spaced_, and __ spaced__.\n",
        out.items,
    );
}

test "underscore emphasis renders in list, blockquote, and table cells" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "- _item_\n> __quote__\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[2m• \x1b[22m\x1b[3mitem\x1b[23m\n" ++
            "\x1b[2m│ \x1b[22m\x1b[1mquote\x1b[22m\n",
        out.items,
    );

    var table = try parseTablePayload(
        alloc,
        "| Name | Value |\n" ++
            "|------|-------|\n" ++
            "| _row_ | __cell__ |\n",
    );
    defer table.deinit(alloc);
    out.clearRetainingCapacity();
    try renderTablePayload(alloc, table, &out);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b[3mrow\x1b[23m") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b[1mcell\x1b[22m") != null);
}

test "underscore formatted bare URLs retain path underscores and matching closers" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const id_before = link_id_counter;
    try processor.push(
        alloc,
        "_https://example.com/snake_case_ tail __https://example.com/snake_case__ tail\n",
        &out,
    );

    var expected_buf: [1024]u8 = undefined;
    const expected = try std.mem.print(
        &expected_buf,
        "\x1b[3m\x1b]8;id=fx-{d};https://example.com/snake_case\x1b\\\x1b[38;5;75m\x1b[4mhttps://example.com/snake_case\x1b[24m\x1b[39m\x1b]8;;\x1b\\\x1b[23m tail " ++
            "\x1b[1m\x1b]8;id=fx-{d};https://example.com/snake_case\x1b\\\x1b[38;5;75m\x1b[4mhttps://example.com/snake_case\x1b[24m\x1b[39m\x1b]8;;\x1b\\\x1b[22m tail\n",
        .{ id_before, id_before +% 1 },
    );
    try std.testing.expectEqualStrings(expected, out.items);
}

test "underscore formatted URLs require exact active markers" {
    const alloc = std.testing.allocator;
    const no_link_inputs = [_][]const u8{
        "snake_https://example.com\n",
        "snake__https://example.com\n",
        "_prefix__https://example.com\n",
        "__prefix__https://example.com\n",
    };

    for (no_link_inputs) |input| {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        try processor.push(alloc, input, &out);
        try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;") == null);
    }

    // Trailing underscores are outside the URL, as in GFM autolinks, so the
    // mismatched runs pair on their shared length and the extra underscore
    // stays literal next to the styled link.
    const mismatched_run_cases = [_]struct {
        input: []const u8,
        url: []const u8,
        prefix: []const u8,
        tail: []const u8,
    }{
        .{ .input = "_https://example.com/path__ tail\n", .url = ";https://example.com/path\x1b\\", .prefix = "\x1b[3m\x1b]8;", .tail = "\x1b[23m_ tail\n" },
        .{ .input = "__https://example.com/path_ tail\n", .url = ";https://example.com/path\x1b\\", .prefix = "_\x1b[3m\x1b]8;", .tail = "\x1b[23m tail\n" },
    };

    for (mismatched_run_cases) |case| {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        try processor.push(alloc, case.input, &out);
        try std.testing.expect(std.mem.find(u8, out.items, case.url) != null);
        try std.testing.expect(std.mem.startsWith(u8, out.items, case.prefix));
        try std.testing.expect(std.mem.endsWith(u8, out.items, case.tail));
    }
}

test "underscore emphasis preserves code literals and keeps unpaired markers literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "_unclosed\n__unclosed\n`_literal_ __literal__`\n", &out);
    try std.testing.expectEqualStrings(
        "_unclosed\n" ++
            "__unclosed\n" ++
            "\x1b[38;5;255m_literal_ __literal__\x1b[39m\n",
        out.items,
    );
}

test "headings preserve literal underscores and suppress valid double-underscore strong markers" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "## __Strong__ snake__case __ spaced__\n", &out);
    try std.testing.expectEqualStrings("\x1b[1mStrong snake__case __ spaced__\x1b[22m\n", out.items);
}

test "cross-form nested strong spans reassert the remaining bold style" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "**outer __inner__ suffix** __outer **inner** suffix__\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[1mouter \x1b[1minner\x1b[22m\x1b[1m suffix\x1b[22m " ++
            "\x1b[1mouter \x1b[1minner\x1b[22m\x1b[1m suffix\x1b[22m\n",
        out.items,
    );
}

test "cross-form nested italic spans reassert the remaining italic style" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "*outer _inner_ suffix* _outer *inner* suffix_\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[3mouter \x1b[3minner\x1b[23m\x1b[3m suffix\x1b[23m " ++
            "\x1b[3mouter \x1b[3minner\x1b[23m\x1b[3m suffix\x1b[23m\n",
        out.items,
    );
}

test "table payload headers reassert outer bold after inline strong closes" {
    const alloc = std.testing.allocator;
    var table = try parseTablePayload(
        alloc,
        "| prefix __strong__ suffix |\n" ++
            "|------|\n" ++
            "| value |\n",
    );
    defer table.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try renderTablePayload(alloc, table, &out);
    try std.testing.expect(std.mem.find(
        u8,
        out.items,
        "\x1b[1mprefix \x1b[1mstrong\x1b[22m\x1b[1m suffix\x1b[22m",
    ) != null);
}

test "double backtick code span keeps inner backticks and trims one padding space" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "use `` a ` b `` and ``x`` here\n", &out);
    try std.testing.expectEqualStrings(
        "use \x1b[38;5;255ma ` b\x1b[39m and \x1b[38;5;255mx\x1b[39m here\n",
        out.items,
    );
}

test "code span closes only on a backtick run of the same length" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "`a``b` and ``` lonely **bold**\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[38;5;255ma``b\x1b[39m and ``` lonely \x1b[1mbold\x1b[22m\n",
        out.items,
    );
}

test "numeric entities for control characters stay literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "x&#27;[2Ky &#x1b;[31m &#7; &#127;&#x9b; &#0; &#x41;\n", &out);
    try std.testing.expectEqualStrings("x&#27;[2Ky &#x1b;[31m &#7; &#127;&#x9b; \xef\xbf\xbd A\n", out.items);
    try std.testing.expect(std.mem.findScalar(u8, out.items, 0x1b) == null);
}

test "entity lookup is bounded and a long ampersand line renders in bounded time" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // A semicolon farther than the longest accepted name never forms an entity.
    try processor.push(alloc, "&ampersand; &amp;\n", &out);
    try std.testing.expectEqualStrings("&ampersand; &\n", out.items);

    out.clearRetainingCapacity();
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    try line.appendNTimes(alloc, '&', 64 * 1024);
    try line.append(alloc, '\n');
    const io_mod = @import("../shared/io.zig");
    const started = io_mod.nanoTimestamp();
    try processor.push(alloc, line.items, &out);
    try std.testing.expect(@divTrunc(io_mod.nanoTimestamp() - started, std.time.ns_per_ms) < 500);
    try std.testing.expectEqualStrings(line.items, out.items);
}

test "code span content is not entity decoded but prose is" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "a &amp; b &lt;c&gt; &quot;d&quot; &#39;e&#39; &#x2192; `&amp;` &unknown; &amp\n", &out);
    try std.testing.expectEqualStrings(
        "a & b <c> \"d\" 'e' \xe2\x86\x92 \x1b[38;5;255m&amp;\x1b[39m &unknown; &amp\n",
        out.items,
    );
}

test "heading strips emphasis markers around a multi backtick code span" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "## Run ``**raw**`` now\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[1mRun \x1b[38;5;255m**raw**\x1b[39m now\x1b[22m\n",
        out.items,
    );
}

test "inline code backticks wrap with ANSI" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "run `zig build` now\n", &out);
    try std.testing.expectEqualStrings("run \x1b[38;5;255mzig build\x1b[39m now\n", out.items);
}

test "inline code uses the selected light background" {
    const alloc = std.testing.allocator;
    setInlineCodeTheme(true);
    defer setInlineCodeTheme(false);

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "run `zig build` now\n", &out);
    try std.testing.expectEqualStrings("run \x1b[38;5;235mzig build\x1b[39m now\n", out.items);
}

test "stray asterisk between spaces stays literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "3 * 5 = 15\n", &out);
    try std.testing.expectEqualStrings("3 * 5 = 15\n", out.items);
}

test "headings use level-specific ANSI styles" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "# Workspace overview\n", .expected = "\x1b[1m\x1b[4mWorkspace overview\x1b[24m\x1b[22m\n" },
        .{ .input = "## Installation\n", .expected = "\x1b[1mInstallation\x1b[22m\n" },
        .{ .input = "### macOS\n", .expected = "\x1b[4mmacOS\x1b[24m\n" },
        .{ .input = "#### Shell setup\n", .expected = "\x1b[1m\x1b[2mShell setup\x1b[22m\n" },
        .{ .input = "##### Optional tools\n", .expected = "\x1b[2m\x1b[4mOptional tools\x1b[24m\x1b[22m\n" },
        .{ .input = "###### Troubleshooting\n", .expected = "\x1b[2mTroubleshooting\x1b[22m\n" },
    };

    for (cases) |case| {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        try processor.push(alloc, case.input, &out);
        try std.testing.expectEqualStrings(case.expected, out.items);
        try std.testing.expect(std.mem.find(u8, out.items, "\x1b[1;4m") == null);
    }
}

test "setext headings use ATX styles and bypass thematic rule completion" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        calls: usize = 0,

        fn deliver(raw: *anyopaque, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(alloc, "Workspace *overview*\n", &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    try processor.pushWithCompletions(
        alloc,
        "===\nInstallation **guide**\n---\n",
        &out,
        .{ .thematic_rule = &completion },
    );
    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[4mWorkspace \x1b[3moverview\x1b[23m\x1b[24m\x1b[22m\n" ++
            "\x1b[1mInstallation guide\x1b[22m\n",
        out.items,
    );
    try std.testing.expectEqual(@as(usize, 0), capture.calls);

    try processor.pushWithCompletions(alloc, "\n---\n", &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "setext candidate flushes at EOF and reset discards it" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        calls: usize = 0,

        fn deliver(raw: *anyopaque, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(alloc, "ordinary title\n", &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqualStrings("ordinary title\n", out.items);

    out.clearRetainingCapacity();
    try processor.pushWithCompletions(alloc, "discarded title\n", &out, .{ .thematic_rule = &completion });
    processor.reset(alloc);
    try processor.pushWithCompletions(alloc, "---\n", &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "definition lists render adjacent markers through thematic completion" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "Status\n: **Running**\n: second definition\n",
        &out,
        .{ .thematic_rule = &completion },
    );
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });

    try std.testing.expectEqualStrings(
        "Status\n" ++
            "\x1b[2m  \x1b[22m\x1b[1mRunning\x1b[22m\n" ++
            "\x1b[2m  \x1b[22msecond definition\n",
        out.items,
    );
}

test "definition state stops before a fenced code block" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "Status\n: accepted\n```\ncode\n```\n: stale\n",
        &out,
        .{ .thematic_rule = &completion },
    );
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });

    try std.testing.expect(std.mem.find(u8, out.items, "\x1b[2m  \x1b[22maccepted\n") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\n: stale\n") != null);
}

test "definition state stops before a pipe table" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "Status\n: accepted\n| Name |\n| --- |\n| value |\n: stale\n",
        &out,
        .{ .thematic_rule = &completion },
    );
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });

    try std.testing.expect(std.mem.find(u8, out.items, "\x1b[2m  \x1b[22maccepted\n") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\n: stale\n") != null);
}

test "definition marker cannot skip a fenced code block" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "Status\n```\ncode\n```\n: stale\n",
        &out,
        .{ .thematic_rule = &completion },
    );
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });

    try std.testing.expect(std.mem.find(u8, out.items, "Status\n") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\n: stale\n") != null);
}

test "definition marker cannot skip a pipe table" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "Status\n| Name |\n| --- |\n| value |\n: stale\n",
        &out,
        .{ .thematic_rule = &completion },
    );
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });

    try std.testing.expect(std.mem.find(u8, out.items, "Status\n") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\n: stale\n") != null);
}

test "definition markers without a term stay literal" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        ": orphan\n: second marker\n",
        &out,
        .{ .thematic_rule = &completion },
    );
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });

    try std.testing.expectEqualStrings(": orphan\n: second marker\n", out.items);
}

test "definition markers require a separator and adjacency" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        try processor.pushWithCompletions(
            alloc,
            "Status\n:no-space\nEmpty\n: \t\nSeparated\n\n: body\n",
            &out,
            .{ .thematic_rule = &completion },
        );
        try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });
        try std.testing.expectEqualStrings(
            "Status\n:no-space\nEmpty\n: \t\nSeparated\n\n: body\n",
            out.items,
        );
    }

    {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        try processor.push(alloc, "Direct\n: body\n", &out);
        try std.testing.expectEqualStrings("Direct\n: body\n", out.items);
    }
}

test "definition bodies preserve LF and EOF hard-break behavior" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "Status\n: line\\\n: eof\\",
        &out,
        .{ .thematic_rule = &completion },
    );
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });

    try std.testing.expectEqualStrings(
        "Status\n" ++
            "\x1b[2m  \x1b[22mline\n" ++
            "\x1b[2m  \x1b[22meof\\",
        out.items,
    );
}

test "definition state resets with the processor" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(alloc, "Status\n: accepted\n", &out, .{ .thematic_rule = &completion });
    processor.reset(alloc);
    out.clearRetainingCapacity();
    try processor.pushWithCompletions(alloc, ": stale\n", &out, .{ .thematic_rule = &completion });
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });

    try std.testing.expectEqualStrings(": stale\n", out.items);
}

test "setext lookahead leaves structural predecessors as standalone rules" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        calls: usize = 0,

        fn deliver(raw: *anyopaque, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "# ATX heading\n---\n- list item\n---\n> quoted text\n---\nordinary prose\n___\n",
        &out,
        .{ .thematic_rule = &completion },
    );

    try std.testing.expectEqual(@as(usize, 4), capture.calls);
    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[4mATX heading\x1b[24m\x1b[22m\n" ++
            "\x1b[2m\xe2\x80\xa2 \x1b[22mlist item\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mquoted text\n" ++
            "ordinary prose\n",
        out.items,
    );
}

fn checkSetextLookaheadAllocationFailures(alloc: Allocator) !void {
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(alloc, "allocation title\n---\n", &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqualStrings("\x1b[1mallocation title\x1b[22m\n", out.items);
}

test "setext lookahead frees allocation failures" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkSetextLookaheadAllocationFailures,
        .{},
    );
}

fn checkDefinitionListAllocationFailures(alloc: Allocator) !void {
    const Capture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "Status\n: **Running**\n: second definition\n",
        &out,
        .{ .thematic_rule = &completion },
    );
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqualStrings(
        "Status\n" ++
            "\x1b[2m  \x1b[22m\x1b[1mRunning\x1b[22m\n" ++
            "\x1b[2m  \x1b[22msecond definition\n",
        out.items,
    );
}

test "definition lists free allocation failures" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkDefinitionListAllocationFailures,
        .{},
    );
}

test "footnote references emit dim markers and defer definitions" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "The cache is scoped to this request.[^cache]\n" ++
            "[^cache]: It is discarded after the request completes.\n",
        &out,
    );
    try processor.flush(alloc, &out);

    try std.testing.expectEqualStrings(
        "The cache is scoped to this request.\x1b[2m[1]\x1b[22m\n\n" ++
            "\x1b[2m[1] \x1b[22mIt is discarded after the request completes.\n",
        out.items,
    );
}

test "table cell footnote references project deferred definitions" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "| Component | State |\n" ++
            "| --- | --- |\n" ++
            "| api | [^state] |\n" ++
            "[^state]: The state comes from the deployment record.\n",
        &out,
    );
    try processor.flush(alloc, &out);

    try std.testing.expect(std.mem.find(u8, out.items, "[^state]") == null);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b[2m[1] \x1b[22m") != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        out.items,
        "\n\n\x1b[2m[1] \x1b[22mThe state comes from the deployment record.\n",
    ));
}

test "footnotes normalize the final separator after blank source lines" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "The cache is scoped to this request.[^cache]\n\n" ++
            "[^cache]: It is discarded after the request completes.\n",
        &out,
    );
    try processor.flush(alloc, &out);

    try std.testing.expectEqualStrings(
        "The cache is scoped to this request.\x1b[2m[1]\x1b[22m\n\n" ++
            "\x1b[2m[1] \x1b[22mIt is discarded after the request completes.\n",
        out.items,
    );
}

test "footnotes use first reference order and keep the first definition" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "[^second]: The second definition arrives first.\n" ++
            "[^first]: The first definition arrives second.\n" ++
            "First[^first], second[^second], and first again[^first].\n" ++
            "[^first]: This duplicate definition is ignored.\n",
        &out,
    );
    try processor.flush(alloc, &out);

    try std.testing.expectEqualStrings(
        "First\x1b[2m[1]\x1b[22m, second\x1b[2m[2]\x1b[22m, and first again\x1b[2m[1]\x1b[22m.\n\n" ++
            "\x1b[2m[1] \x1b[22mThe first definition arrives second.\n" ++
            "\x1b[2m[2] \x1b[22mThe second definition arrives first.\n",
        out.items,
    );
}

test "footnote definitions format multiline bodies and retain EOF separators" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "[^cache]: First **formatted** line.\n" ++
            "  Second continuation line.\n" ++
            "\tThird continuation line.\n" ++
            "The cache is scoped to this request.[^cache]",
        &out,
    );
    try processor.flush(alloc, &out);

    try std.testing.expectEqualStrings(
        "The cache is scoped to this request.\x1b[2m[1]\x1b[22m\n\n" ++
            "\x1b[2m[1] \x1b[22mFirst \x1b[1mformatted\x1b[22m line.\n" ++
            "\x1b[2m    \x1b[22mSecond continuation line.\n" ++
            "\x1b[2m    \x1b[22mThird continuation line.\n",
        out.items,
    );
}

test "escaped malformed and code footnote candidates remain literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "\\[^escaped] \x60[^code]\x60 [^] [^missing]:\n\n" ++
            "    [^block]: literal code\n",
        &out,
    );
    try processor.flush(alloc, &out);

    try std.testing.expect(std.mem.find(u8, out.items, "[1]") == null);
    try std.testing.expect(std.mem.find(u8, out.items, "[^escaped]") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "[^code]") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "[^missing]:") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "[^block]: literal code") != null);
}

fn checkFootnoteAllocationFailures(alloc: Allocator) !void {
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "The cache is scoped to this request.[^cache]\n" ++
            "[^cache]: First **formatted** line.\n" ++
            "  Second continuation line.\n",
        &out,
    );
    try processor.flush(alloc, &out);
}

test "footnotes free allocation failures" {
    try std.testing.checkAllAllocationFailures(
        testing_allocator.no_resize,
        checkFootnoteAllocationFailures,
        .{},
    );
}

test "heading keeps inline emphasis without nested bold markers" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "# **Strong** *emphasis*\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[4mStrong \x1b[3memphasis\x1b[23m\x1b[24m\x1b[22m\n",
        out.items,
    );
}

test "hash without trailing space is literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "#notATag\n", &out);
    try std.testing.expectEqualStrings("#notATag\n", out.items);
}

test "unordered list dash gets bullet" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "- first item\n", &out);
    try std.testing.expectEqualStrings("\x1b[2m\xe2\x80\xa2 \x1b[22mfirst item\n", out.items);
}

test "unordered list asterisk gets bullet" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "* second item\n", &out);
    try std.testing.expectEqualStrings("\x1b[2m\xe2\x80\xa2 \x1b[22msecond item\n", out.items);
}

test "unordered list literal bullet gets dim marker" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "\xe2\x80\xa2 third item\n  \xe2\x80\xa2 nested\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x80\xa2 \x1b[22mthird item\n" ++
            "  \x1b[2m\xe2\x80\xa2 \x1b[22mnested\n",
        out.items,
    );
}

test "unordered list plus marker and tab separator get bullet" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "+ plus item\n-\ttabbed item\n+not a list\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x80\xa2 \x1b[22mplus item\n" ++
            "\x1b[2m\xe2\x80\xa2 \x1b[22mtabbed item\n" ++
            "+not a list\n",
        out.items,
    );
}

test "ordered list accepts paren markers and rejects long numbers" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "1) first\n12) twelfth\n1234567890. too long\n", &out);
    try std.testing.expectEqualStrings(
        "  \x1b[2m1)\x1b[22m first\n" ++
            " \x1b[2m12)\x1b[22m twelfth\n" ++
            "1234567890. too long\n",
        out.items,
    );
}

test "atx heading strips closing hashes and allows small indent" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "## Title ##\n   ## Indented\n## Keep#\n## Trail ##   \n    ## code\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[1mTitle\x1b[22m\n" ++
            "\x1b[1mIndented\x1b[22m\n" ++
            "\x1b[1mKeep#\x1b[22m\n" ++
            "\x1b[1mTrail\x1b[22m\n" ++
            "    ## code\n",
        out.items,
    );
}

test "longer code fence contains shorter fences" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "````md\n```zig\ninner\n```\n````\nafter\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x94\x82 \x1b[22m```zig\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22minner\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m```\n" ++
            "after\n",
        out.items,
    );
    try std.testing.expectEqual(@as(?bp.CodeFence, null), processor.code_fence);
}

test "code fence language skips the whole marker run" {
    try std.testing.expectEqualStrings("md", bp.codeFenceLanguage("````md"));
    try std.testing.expectEqualStrings("zig", bp.codeFenceLanguage("```   zig extra"));
    try std.testing.expectEqualStrings("", bp.codeFenceLanguage("~~~"));
}

test "closing fence needs matching marker length and nothing after it" {
    const open = bp.CodeFence{ .marker = '`', .run = 4, .indent = 0 };
    try std.testing.expect(bp.closesCodeFence("````", open));
    try std.testing.expect(bp.closesCodeFence("`````  ", open));
    try std.testing.expect(!bp.closesCodeFence("```", open));
    try std.testing.expect(!bp.closesCodeFence("~~~~", open));
    try std.testing.expect(!bp.closesCodeFence("```` trailing", open));
}

test "fenced code inside a list item drops the item indentation" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "1. step\n   ```sh\n   ls -la\n     nested\n   ```\n- next\n", &out);
    try std.testing.expectEqualStrings(
        "  \x1b[2m1.\x1b[22m step\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mls -la\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m  nested\n" ++
            "\x1b[2m\xe2\x80\xa2 \x1b[22mnext\n",
        out.items,
    );
}

test "tab indented fence inside a list item closes on a tab indented fence" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "1. item\n\t```\n\tcode\n\t```\n\tprose after\n", &out);
    try std.testing.expectEqualStrings(
        "  \x1b[2m1.\x1b[22m item\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mcode\n" ++
            "\tprose after\n",
        out.items,
    );
}

// Known cost of the plus rule: a loose nested list written as "- a", a blank
// line, then "    + nested" renders the nested line as indented code, while
// "-" or "*" at the same indent still become list items.
test "indented plus line after a blank stays indented code" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "    + value\n    second\ntext\n- a\n    + nested\n", &out);
    try processor.flush(alloc, &out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x94\x82 \x1b[22m+ value\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22msecond\n" ++
            "text\n" ++
            "\x1b[2m\xe2\x80\xa2 \x1b[22ma\n" ++
            "    \x1b[2m\xe2\x80\xa2 \x1b[22mnested\n",
        out.items,
    );
}

test "heading keeps a backslash exposed by removing closing hashes" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "## C:\\ ###\n## trailing\\\n> ## C:\\ ###\n> ## quoted\\\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[1mC:\\\x1b[22m\n" ++
            "\x1b[1mtrailing\x1b[22m\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[1mC:\\\x1b[22m\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[1mquoted\x1b[22m\n",
        out.items,
    );
}

test "blockquote renders headings and list items inside the quote" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "> ## Note\n> - one\n> 2. two\n> - [x] done\n> plain\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[1mNote\x1b[22m\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x80\xa2 \x1b[22mone\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m2.\x1b[22m two\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[38;5;252m\xe2\x9c\x93\x1b[39m done\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mplain\n",
        out.items,
    );
}

test "ordered lists inside a quote keep their markers as written" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "> 9. nine\n>    - child\n> 10. ten\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m9.\x1b[22m nine\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m   \x1b[2m\xe2\x80\xa2 \x1b[22mchild\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m10.\x1b[22m ten\n",
        out.items,
    );
}

test "literal bullet without trailing space stays prose" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "\xe2\x80\xa2item\n\xe2\x80\xa2\n", &out);
    try std.testing.expectEqualStrings("\xe2\x80\xa2item\n\xe2\x80\xa2\n", out.items);
}

test "ordered list keeps number marker" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "1. step one\n", &out);
    try std.testing.expectEqualStrings("  \x1b[2m1.\x1b[22m step one\n", out.items);
}

test "ordered list markers end in one column through 999" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "9. nine\n10. ten\n100. hundred\n1000. thousand\n", &out);
    try std.testing.expectEqualStrings(
        "  \x1b[2m9.\x1b[22m nine\n" ++
            " \x1b[2m10.\x1b[22m ten\n" ++
            "\x1b[2m100.\x1b[22m hundred\n" ++
            "\x1b[2m1000.\x1b[22m thousand\n",
        out.items,
    );
}

test "content nested in an ordered item moves with its padded marker" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "1. Parent\n" ++
            "   - child\n" ++
            "   continuation\n" ++
            "   > quoted\n" ++
            "   lazy\n" ++
            "\n" ++
            "   after blank\n" ++
            "   1. nested\n" ++
            "      - grandchild\n" ++
            "after list\n" ++
            "   indented prose\n",
        &out,
    );
    try std.testing.expectEqualStrings(
        "  \x1b[2m1.\x1b[22m Parent\n" ++
            "     \x1b[2m\xe2\x80\xa2 \x1b[22mchild\n" ++
            "     continuation\n" ++
            "     \x1b[2m\xe2\x94\x82 \x1b[22mquoted\n" ++
            "     \x1b[2m\xe2\x94\x82 \x1b[22m   lazy\n" ++
            "\n" ++
            "     after blank\n" ++
            "       \x1b[2m1.\x1b[22m nested\n" ++
            "          \x1b[2m\xe2\x80\xa2 \x1b[22mgrandchild\n" ++
            "after list\n" ++
            "   indented prose\n",
        out.items,
    );
}

test "flushing assistant text closes open ordered items" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "1. item\n", &out);
    try processor.flush(alloc, &out);
    try processor.push(alloc, "   prose\n", &out);
    try std.testing.expectEqualStrings("  \x1b[2m1.\x1b[22m item\n   prose\n", out.items);
}

const fuzz_markdown_list_pieces = [_][]const u8{
    "1. ",   "9. ",      "10. ",  "100) ", "1000. ", "123456789. ", "1234567890. ", "1.",
    "- ",    "* ",       "+ ",    "[x] ",  "[ ] ",   " ",           "   ",          "    ",
    "\t",    "\n",       "\n\n",  "\r\n",  "> ",     ">> ",         "```",          "~~~",
    "|a|\n", "---\n",    "===\n", "# ",    "[^1]: ", ": ",          "word",         "**b**",
    "`c`",   "\u{754c}",
};

/// Open items nest strictly inward, and each level pads by at most two.
fn expectOpenOrderedItemsNested(processor: *const MarkdownProcessor) !void {
    const items = processor.open_ordered_items.items;
    for (items, 0..) |item, i| {
        try std.testing.expect(item.shift <= 2 * (i + 1));
        if (i == 0) continue;
        try std.testing.expect(items[i - 1].content_column < item.content_column);
        try std.testing.expect(items[i - 1].shift <= item.shift);
    }
}

fn fuzzMarkdownLists(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    for (0..smith.valueRangeAtMost(u8, 0, 64)) |_| {
        try source.appendSlice(alloc, fuzz_markdown_list_pieces[smith.index(fuzz_markdown_list_pieces.len)]);
    }

    var whole = MarkdownProcessor{};
    defer whole.deinit(alloc);
    var whole_out: std.ArrayList(u8) = .empty;
    defer whole_out.deinit(alloc);
    try whole.push(alloc, source.items, &whole_out);
    try expectOpenOrderedItemsNested(&whole);
    try whole.flush(alloc, &whole_out);
    try std.testing.expectEqual(@as(usize, 0), whole.open_ordered_items.items.len);

    var split = MarkdownProcessor{};
    defer split.deinit(alloc);
    var split_out: std.ArrayList(u8) = .empty;
    defer split_out.deinit(alloc);
    var start: usize = 0;
    while (start < source.items.len) {
        const len: usize = smith.valueRangeAtMost(u16, 1, @intCast(source.items.len - start));
        try split.push(alloc, source.items[start..][0..len], &split_out);
        try expectOpenOrderedItemsNested(&split);
        start += len;
    }
    try split.flush(alloc, &split_out);
    try std.testing.expectEqualStrings(whole_out.items, split_out.items);
}

test "Markdown lists render the same however assistant text is split" {
    try std.testing.fuzz({}, fuzzMarkdownLists, .{
        .corpus = &(.{""} ++ @import("fuzz_corpus").markdown_lists.*),
    });
}

test "task list items render static pending and completed markers" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "- [ ] pending **task**\n" ++
            "- [x] done\n" ++
            "  * [X] nested done\n" ++
            "- [ ]\n",
        &out,
    );
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x98\x90 \x1b[22mpending \x1b[1mtask\x1b[22m\n" ++
            "\x1b[38;5;252m\xe2\x9c\x93\x1b[39m done\n" ++
            "  \x1b[38;5;252m\xe2\x9c\x93\x1b[39m nested done\n" ++
            "\x1b[2m\xe2\x98\x90\x1b[22m\n",
        out.items,
    );
}

test "ordered task list items retain their number markers" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "1. [ ] first\n2. [X] done\n", &out);
    try std.testing.expectEqualStrings(
        "  \x1b[2m1.\x1b[22m \x1b[2m\xe2\x98\x90 \x1b[22mfirst\n" ++
            "  \x1b[2m2.\x1b[22m \x1b[38;5;252m\xe2\x9c\x93\x1b[39m done\n",
        out.items,
    );
}

test "task list syntax remains literal outside its bounded grammar" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "- [x]done\n" ++
            "- [-] unsupported\n" ++
            "- [ ]pending\n" ++
            "ordinary [x] prose\n" ++
            "```text\n" ++
            "- [x] literal code\n" ++
            "```\n",
        &out,
    );
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x80\xa2 \x1b[22m[x]done\n" ++
            "\x1b[2m\xe2\x80\xa2 \x1b[22m[-] unsupported\n" ++
            "\x1b[2m\xe2\x80\xa2 \x1b[22m[ ]pending\n" ++
            "ordinary [x] prose\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m- [x] literal code\n",
        out.items,
    );
}

test "task list prefix is retained across streamed input chunks" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "- [x]", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try processor.push(alloc, " streamed task\n", &out);
    try std.testing.expectEqualStrings("\x1b[38;5;252m\xe2\x9c\x93\x1b[39m streamed task\n", out.items);
}

test "blockquote gets a dim vertical rule and renders inline markdown" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "  > **important** note\n", &out);
    try std.testing.expectEqualStrings("  \x1b[2m\xe2\x94\x82 \x1b[22m\x1b[1mimportant\x1b[22m note\n", out.items);
}

test "lazy nested blockquote continuations retain their rules" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "> > first **quoted** line\n", &out);
    try processor.push(alloc, "lazy second line\n> > explicit third line\nlazy fourth line\n\noutside\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22mfirst \x1b[1mquoted\x1b[22m line\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22mlazy second line\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22mexplicit third line\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22mlazy fourth line\n\n" ++
            "outside\n",
        out.items,
    );
}

test "lazy blockquote continuations retain inline links" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "> source\nlazy [link](https://example.com/lazy)\n", &out);
    try std.testing.expect(std.mem.find(u8, out.items, "\n\x1b[2m\xe2\x94\x82 \x1b[22mlazy ") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b]8;id=fx-") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "https://example.com/lazy") != null);
}

test "lazy blockquotes stop before structural rows and preserve EOF backslashes" {
    const alloc = std.testing.allocator;
    const RuleCapture = struct {
        calls: usize = 0,

        fn deliver(raw: *anyopaque, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = RuleCapture{};
    var rule_completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = RuleCapture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "> quote\nlazy continuation\n===\n---\noutside\n> quote again\n- list item\n> quote at EOF\nlazy EOF\\",
        &out,
        .{ .thematic_rule = &rule_completion },
    );
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &rule_completion });
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x94\x82 \x1b[22mquote\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mlazy continuation\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m===\n" ++
            "outside\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mquote again\n" ++
            "\x1b[2m\xe2\x80\xa2 \x1b[22mlist item\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mquote at EOF\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mlazy EOF\\",
        out.items,
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
}

test "lazy blockquotes end before headings and fences" {
    const alloc = std.testing.allocator;
    const RuleCapture = struct {
        fn deliver(_: *anyopaque, _: *std.ArrayList(u8)) !void {}
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture: u8 = 0;
    var rule_completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = RuleCapture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "> quote before heading\n# heading\nheading outside\n> quote before fence\n```zig\ncode\n```\nafter fence\n",
        &out,
        .{ .thematic_rule = &rule_completion },
    );
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &rule_completion });
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x94\x82 \x1b[22mquote before heading\n" ++
            "\x1b[1m\x1b[4mheading\x1b[24m\x1b[22m\n" ++
            "heading outside\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mquote before fence\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22mcode\n" ++
            "after fence\n",
        out.items,
    );
}

test "reset clears lazy blockquote state" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "> quote\n", &out);
    processor.reset(alloc);
    try processor.push(alloc, "next turn\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x94\x82 \x1b[22mquote\nnext turn\n",
        out.items,
    );
}

test "flushing ends lazy blockquote state" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "> quote\n", &out);
    try processor.flush(alloc, &out);
    try processor.push(alloc, "next stream\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x94\x82 \x1b[22mquote\nnext stream\n",
        out.items,
    );
}

test "nested blockquotes render every valid marker and preserve malformed inner syntax" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "  > > **deep** note\n" ++
            "> > > third depth\n" ++
            "> >\n" ++
            ">> compact\n" ++
            "> >not\n",
        &out,
    );
    try std.testing.expectEqualStrings(
        "  \x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[1mdeep\x1b[22m note\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22mthird depth\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22m\n" ++
            ">> compact\n" ++
            "\x1b[2m\xe2\x94\x82 \x1b[22m>not\n",
        out.items,
    );
}

test "nested blockquote remains buffered until its terminating newline" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "> > **chunked", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try processor.push(alloc, " nested**\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[2m\xe2\x94\x82 \x1b[22m\x1b[1mchunked nested\x1b[22m\n",
        out.items,
    );
}

test "blockquote without a marker separator stays literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, ">not a blockquote\n", &out);
    try std.testing.expectEqualStrings(">not a blockquote\n", out.items);
}

test "code fence toggles block state" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "```zig\nconst x = 1;\n```\n", &out);
    const expected = "\x1b[2m\xe2\x94\x82 \x1b[22mconst x = 1;\n";
    try std.testing.expectEqualStrings(expected, out.items);
    try std.testing.expect(!processor.in_code_block);
}

test "code block preserves inline markers literally" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "```\nfoo **bar** baz\n```\n", &out);
    const expected = "\x1b[2m\xe2\x94\x82 \x1b[22mfoo **bar** baz\n";
    try std.testing.expectEqualStrings(expected, out.items);
}

test "tilde code fence keeps literal code and ignores backtick fence" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "~~~zig\nconst value = **1**;\n```\n~~~\n", &out);

    const expected =
        "\x1b[2m\xe2\x94\x82 \x1b[22mconst value = **1**;\n" ++
        "\x1b[2m\xe2\x94\x82 \x1b[22m```\n";
    try std.testing.expectEqualStrings(expected, out.items);
    try std.testing.expect(!processor.in_code_block);
}

test "tilde code fence completion retains language and literal source" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        block: ?CodeBlockPayload = null,

        fn deinit(self: *@This()) void {
            if (self.block) |*block| block.deinit(alloc);
        }

        fn deliver(raw: *anyopaque, block: CodeBlockPayload, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.block = block;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    defer capture.deinit();
    var completion = CodeBlockCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "Before block.\n~~~  Zig example\n  const value = **1**;\n```\n~~~\nAfter block.\n",
        &out,
        .{ .code = &completion },
    );

    try std.testing.expectEqualStrings("Before block.\nAfter block.\n", out.items);
    const block = capture.block orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Zig", block.language);
    try std.testing.expectEqualStrings("  const value = **1**;\n```\n", block.code);
}

test "unterminated tilde code fence flushes its semantic payload" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        block: ?CodeBlockPayload = null,

        fn deinit(self: *@This()) void {
            if (self.block) |*block| block.deinit(alloc);
        }

        fn deliver(raw: *anyopaque, block: CodeBlockPayload, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.block = block;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    defer capture.deinit();
    var completion = CodeBlockCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(alloc, "~~~text\nlast line", &out, .{ .code = &completion });
    try processor.flushWithCompletions(alloc, &out, .{ .code = &completion });

    const block = capture.block orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("text", block.language);
    try std.testing.expectEqualStrings("last line\n", block.code);
}

test "markdown completion normalizes CRLF across chunks before capturing code fences" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        block: ?CodeBlockPayload = null,

        fn deinit(self: *@This()) void {
            if (self.block) |*block| block.deinit(alloc);
        }

        fn deliver(raw: *anyopaque, block: CodeBlockPayload, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.block = block;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    defer capture.deinit();
    var completion = CodeBlockCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "Before block.\r\n```  Zig example\r",
        &out,
        .{ .code = &completion },
    );
    try processor.pushWithCompletions(
        alloc,
        "\n  const value = **1**;\r\n```\r\nAfter block.\r\n",
        &out,
        .{ .code = &completion },
    );

    try std.testing.expectEqualStrings("Before block.\nAfter block.\n", out.items);
    const block = capture.block orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Zig", block.language);
    try std.testing.expectEqualStrings("  const value = **1**;\n", block.code);
}

test "indented code completion deindents literal lines and reprocesses its terminator" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        block: ?CodeBlockPayload = null,

        fn deinit(self: *@This()) void {
            if (self.block) |*block| block.deinit(alloc);
        }

        fn deliver(raw: *anyopaque, block: CodeBlockPayload, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.block = block;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    defer capture.deinit();
    var completion = CodeBlockCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "\n    | literal | pipe |\n    ```zig\n    const value = **1**;\n        nested\nplain text\n",
        &out,
        .{ .code = &completion },
    );

    const block = capture.block orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", block.language);
    try std.testing.expectEqualStrings(
        "| literal | pipe |\n```zig\nconst value = **1**;\n    nested\n",
        block.code,
    );
    try std.testing.expectEqualStrings("\nplain text\n", out.items);
    try std.testing.expect(!processor.in_code_block);
}

test "indented code completion accepts a response-leading tab and flushes at EOF" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        block: ?CodeBlockPayload = null,

        fn deinit(self: *@This()) void {
            if (self.block) |*block| block.deinit(alloc);
        }

        fn deliver(raw: *anyopaque, block: CodeBlockPayload, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.block = block;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    defer capture.deinit();
    var completion = CodeBlockCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(alloc, "\t  tail", &out, .{ .code = &completion });
    try processor.flushWithCompletions(alloc, &out, .{ .code = &completion });

    const block = capture.block orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", block.language);
    try std.testing.expectEqualStrings("  tail\n", block.code);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "indented code requires a blank boundary and yields to list and lazy quote content" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        block: ?CodeBlockPayload = null,

        fn deinit(self: *@This()) void {
            if (self.block) |*block| block.deinit(alloc);
        }

        fn deliver(raw: *anyopaque, block: CodeBlockPayload, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.block = block;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    defer capture.deinit();
    var completion = CodeBlockCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(
        alloc,
        "paragraph\n    continuation\n\n   three spaces\n\n    - list item\n> quote\n    lazy continuation\n\nafter quote\n",
        &out,
        .{ .code = &completion },
    );

    try std.testing.expect(capture.block == null);
    try std.testing.expect(std.mem.find(u8, out.items, "    continuation") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "   three spaces") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b[2m\xe2\x94\x82 \x1b[22m    lazy continuation") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b[2m\xe2\x94\x82 \x1b[22m- list item") == null);
}

test "reset clears an unfinished indented code block" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "    stale code\n", &out);
    try std.testing.expect(processor.in_code_block);

    processor.reset(alloc);
    try std.testing.expect(!processor.in_code_block);
    try processor.push(alloc, "after reset\n", &out);

    try std.testing.expectEqualStrings("\x1b[2m\xe2\x94\x82 \x1b[22mstale code\nafter reset\n", out.items);
}

test "code block payload clone frees language if code allocation fails" {
    const alloc = testing_allocator.no_resize;
    var source = CodeBlockPayload{
        .language = try alloc.dupe(u8, "zig"),
        .code = try alloc.dupe(u8, "const value = 1;\n"),
    };
    defer source.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, source.clone(failing.allocator()));
}

test "markdown completion flushes an unterminated code fence" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        block: ?CodeBlockPayload = null,

        fn deinit(self: *@This()) void {
            if (self.block) |*block| block.deinit(alloc);
        }

        fn deliver(raw: *anyopaque, block: CodeBlockPayload, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.block = block;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    defer capture.deinit();
    var completion = CodeBlockCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(alloc, "```text\nlast line", &out, .{ .code = &completion });
    try processor.flushWithCompletions(alloc, &out, .{ .code = &completion });

    const block = capture.block orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("text", block.language);
    try std.testing.expectEqualStrings("last line\n", block.code);
}

test "line intake buffers partial lines and shows standalone carriage returns as text" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, ">", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    try processor.push(alloc, "\n", &out);
    try std.testing.expectEqualStrings("\x1b[2m\xe2\x94\x82 \x1b[22m\n", out.items);

    out.clearRetainingCapacity();
    try processor.push(alloc, "**bol", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try processor.push(alloc, "d** rest\n", &out);
    try std.testing.expectEqualStrings("\x1b[1mbold\x1b[22m rest\n", out.items);

    out.clearRetainingCapacity();
    try processor.push(alloc, "run `zig", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try processor.push(alloc, " build` now\n", &out);
    try std.testing.expectEqualStrings("run \x1b[38;5;255mzig build\x1b[39m now\n", out.items);

    out.clearRetainingCapacity();
    // Only a line feed ends a line. A carriage return inside one would move the
    // cursor back over the line's gutter, so it shows as text.
    try processor.push(alloc, "left\rright\n", &out);
    try std.testing.expectEqualStrings("left\\x0dright\n", out.items);
}

test "flush emits pending line without newline" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "partial", &out);
    try processor.flush(alloc, &out);
    try std.testing.expectEqualStrings("partial", out.items);
}

test "flush keeps an unmatched emphasis opener literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "oops **never closed", &out);
    try processor.flush(alloc, &out);
    try std.testing.expectEqualStrings("oops **never closed", out.items);
}

test "flush keeps an unpaired backtick literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "run `zig build", &out);
    try processor.flush(alloc, &out);
    try std.testing.expectEqualStrings("run `zig build", out.items);
}

test "emphasis pairs by the delimiter stack and unmatched runs stay literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "*not a list item\n" ++
            "**bold** then **open\n" ++
            "~~gone~~ and ~~stays\n" ++
            "a ` b **bold**\n" ++
            "**bold with `code` inside** *it*\n" ++
            "***both*** and **`code`**\n" ++
            "See *italic** plain\n" ++
            "text **** here **bold** and ~~~~ then ~~gone~~ and *** end\n" ++
            "**a __b__ c** and *x _y_ z*\n" ++
            "foo*bar*baz and snake_case_name and 3 * 5 = 15\n",
        &out,
    );
    try std.testing.expectEqualStrings(
        "*not a list item\n" ++
            "\x1b[1mbold\x1b[22m then **open\n" ++
            "\x1b[9mgone\x1b[29m and ~~stays\n" ++
            "a ` b \x1b[1mbold\x1b[22m\n" ++
            "\x1b[1mbold with \x1b[38;5;255mcode\x1b[39m inside\x1b[22m \x1b[3mit\x1b[23m\n" ++
            "\x1b[3m\x1b[1mboth\x1b[22m\x1b[23m and \x1b[1m\x1b[38;5;255mcode\x1b[39m\x1b[22m\n" ++
            "See \x1b[3mitalic\x1b[23m* plain\n" ++
            "text **** here \x1b[1mbold\x1b[22m and ~~~~ then \x1b[9mgone\x1b[29m and *** end\n" ++
            "\x1b[1ma \x1b[1mb\x1b[22m\x1b[1m c\x1b[22m and \x1b[3mx \x1b[3my\x1b[23m\x1b[3m z\x1b[23m\n" ++
            "foo\x1b[3mbar\x1b[23mbaz and snake_case_name and 3 * 5 = 15\n",
        out.items,
    );
}

test "emphasis lookahead agrees with links, code spans, and bare URLs" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // A backtick inside link text is not a code opener and a star inside a
    // code span is not a closer.
    try processor.push(alloc, "[use `](https://example.com) **bold** `code`\n[use `](https://example.com) *open `code*`\n", &out);
    try std.testing.expect(std.mem.endsWith(u8, tu.nthLine(out.items, 0).?, " \x1b[1mbold\x1b[22m \x1b[38;5;255mcode\x1b[39m"));
    try std.testing.expect(std.mem.endsWith(u8, tu.nthLine(out.items, 1).?, " *open \x1b[38;5;255mcode*\x1b[39m"));

    // Emphasis around a multi backtick code span still pairs.
    out.clearRetainingCapacity();
    try processor.push(alloc, "See _a ``b`c`` d_ end\n", &out);
    try std.testing.expectEqualStrings("See \x1b[3ma \x1b[38;5;255mb`c\x1b[39m d\x1b[23m end\n", out.items);

    // URL punctuation is never read as markup, and a delimiter that ends a
    // URL still closes the span around it.
    out.clearRetainingCapacity();
    try processor.push(alloc, "https://example.com/`x*y` **bold** `code`\n", &out);
    try std.testing.expect(std.mem.find(u8, out.items, ";https://example.com/`x*y`\x1b\\") != null);
    try std.testing.expect(std.mem.endsWith(u8, out.items, " \x1b[1mbold\x1b[22m \x1b[38;5;255mcode\x1b[39m\n"));
    // A trailing delimiter is trimmed from the URL and closes the span.
    out.clearRetainingCapacity();
    try processor.push(alloc, "*see https://example.com/a* and `code`\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "\x1b[3msee \x1b]8;id=fx-"));
    try std.testing.expect(std.mem.endsWith(
        u8,
        out.items,
        ";https://example.com/a\x1b\\\x1b[38;5;75m\x1b[4mhttps://example.com/a\x1b[24m\x1b[39m\x1b]8;;\x1b\\\x1b[23m and \x1b[38;5;255mcode\x1b[39m\n",
    ));
    // Like a GFM autolink, a URL extends to the next whitespace regardless of
    // active styles, so interior punctuation belongs to the URL and the rest
    // of the line is read after it.
    out.clearRetainingCapacity();
    try processor.push(alloc, "*https://example.com/a*`some code` **bold** `x`\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "*\x1b]8;"));
    try std.testing.expect(std.mem.find(u8, out.items, ";https://example.com/a*`some\x1b\\") != null);
    try std.testing.expect(std.mem.endsWith(u8, out.items, " code\x1b[38;5;255m**bold**\x1b[39mx`\n"));
    out.clearRetainingCapacity();
    try processor.push(alloc, "text **** https://example.com\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "text **** \x1b]8;"));
}

test "emphasis flanking reads neighbouring code points not bytes" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // An em dash, curly quotes, and a fullwidth comma are punctuation, so the
    // marker beside them opens or closes; CJK letters are word characters,
    // so a star still delimits between them while an underscore does not.
    // Letters outside ASCII such as the micro sign are still letters, so an
    // underscore between them stays intraword.
    try processor.push(alloc, "a\xc2\xb5_b_ and x\xc2\xaa_y_ and \xe3\x80\xb1_z_\n", &out);
    try std.testing.expectEqualStrings("a\xc2\xb5_b_ and x\xc2\xaa_y_ and \xe3\x80\xb1_z_\n", out.items);
    out.clearRetainingCapacity();
    try processor.push(alloc, "a\xe2\x80\x94_b_ \xe2\x80\x9c*q*\xe2\x80\x9d \xe4\xb8\xad*\xe5\xbc\xb7*\xe8\xaa\xbf \xe4\xb8\xad_\xe5\xbc\xb7_\xe8\xaa\xbf **x**\xef\xbc\x8c\n", &out);
    try std.testing.expectEqualStrings(
        "a\xe2\x80\x94\x1b[3mb\x1b[23m \xe2\x80\x9c\x1b[3mq\x1b[23m\xe2\x80\x9d \xe4\xb8\xad\x1b[3m\xe5\xbc\xb7\x1b[23m\xe8\xaa\xbf \xe4\xb8\xad_\xe5\xbc\xb7_\xe8\xaa\xbf \x1b[1mx\x1b[22m\xef\xbc\x8c\n",
        out.items,
    );
}

test "heading with unmatched strong marker keeps it literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "## 2 ** 8 and **strong** and __also__\n", &out);
    try std.testing.expectEqualStrings("\x1b[1m2 ** 8 and strong and also\x1b[22m\n", out.items);
}

test "long lines of unmatched or unbalanced delimiters render in linear time" {
    const alloc = std.testing.allocator;
    const io_mod = @import("../shared/io.zig");
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);

    const shapes = [_]struct { prefix: []const u8, unit: []const u8, repeat: usize, suffix: []const u8 }{
        .{ .prefix = "", .unit = "*a _b ~~c ", .repeat = 40_000, .suffix = "\n" },
        .{ .prefix = "", .unit = "a* b_ c~~ ", .repeat = 40_000, .suffix = "\n" },
        .{ .prefix = "", .unit = "*a https://example.com/b _c ~~d ", .repeat = 20_000, .suffix = "\n" },
        .{ .prefix = "text ", .unit = "*", .repeat = 64 * 1024, .suffix = "x\n" },
        .{ .prefix = "https://example.com ", .unit = "*", .repeat = 64 * 1024, .suffix = "\n" },
        .{ .prefix = "*a", .unit = "*", .repeat = 64 * 1024, .suffix = "x\n" },
        .{ .prefix = "", .unit = "[", .repeat = 64 * 1024, .suffix = "\n" },
        .{ .prefix = "", .unit = "![", .repeat = 32 * 1024, .suffix = "\n" },
        .{ .prefix = "", .unit = "[", .repeat = 64 * 1024, .suffix = "]\n" },
        .{ .prefix = "", .unit = "![", .repeat = 32 * 1024, .suffix = "]\n" },
        .{ .prefix = "", .unit = "[^", .repeat = 32 * 1024, .suffix = "]\n" },
    };
    // Deeply nested successful pairs must not re-walk consumed ranges.
    out.clearRetainingCapacity();
    line.clearRetainingCapacity();
    for (0..32_000) |_| try line.appendSlice(alloc, "*a ");
    for (0..32_000) |_| try line.appendSlice(alloc, "b* ");
    try line.append(alloc, '\n');
    const nested_started = io_mod.nanoTimestamp();
    try processor.push(alloc, line.items, &out);
    try std.testing.expect(@divTrunc(io_mod.nanoTimestamp() - nested_started, std.time.ns_per_ms) < 500);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "\x1b[3ma \x1b[3ma "));
    // A closer that matches part of its run and then fails to place the rest
    // must cache that failed remainder instead of rescanning other openers.
    out.clearRetainingCapacity();
    line.clearRetainingCapacity();
    for (0..32_000) |_| try line.appendSlice(alloc, "*a ");
    for (0..32_000) |_| try line.appendSlice(alloc, "_b c__ ");
    try line.append(alloc, '\n');
    const residual_started = io_mod.nanoTimestamp();
    try processor.push(alloc, line.items, &out);
    try std.testing.expect(@divTrunc(io_mod.nanoTimestamp() - residual_started, std.time.ns_per_ms) < 500);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b[3mb c\x1b[23m_ ") != null);
    for (shapes) |shape| {
        out.clearRetainingCapacity();
        line.clearRetainingCapacity();
        try line.appendSlice(alloc, shape.prefix);
        for (0..shape.repeat) |_| try line.appendSlice(alloc, shape.unit);
        try line.appendSlice(alloc, shape.suffix);
        const started = io_mod.nanoTimestamp();
        try processor.push(alloc, line.items, &out);
        const elapsed_ms = @divTrunc(io_mod.nanoTimestamp() - started, std.time.ns_per_ms);
        try std.testing.expect(elapsed_ms < 500);
    }
}

test "header with inline markdown" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "## Using `fx` in CI\n", &out);
    try std.testing.expectEqualStrings("\x1b[1mUsing \x1b[38;5;255mfx\x1b[39m in CI\x1b[22m\n", out.items);
}

test "inline code ignores bold markers inside" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "use `**literal**` here\n", &out);
    try std.testing.expectEqualStrings("use \x1b[38;5;255m**literal**\x1b[39m here\n", out.items);
}

test "pipe table header separator has junction aligned with column pipes" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "| Name | Age |\n" ++
        "|------|-----|\n" ++
        "| Ana  | 30  |\n" ++
        "| Bob  | 7   |\n";
    try processor.push(alloc, input, &out);
    try processor.flush(alloc, &out);

    const expected =
        "\x1b[1mName\x1b[22m \xe2\x94\x82 \x1b[1mAge\x1b[22m\n" ++
        "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n" ++
        "Ana  \xe2\x94\x82 30 \n" ++
        "Bob  \xe2\x94\x82 7  \n";
    try std.testing.expectEqualStrings(expected, out.items);
}

test "single-column pipe table has no junction on separator" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "| Header |\n" ++
        "|--------|\n" ++
        "| data   |\n";
    try processor.push(alloc, input, &out);
    try processor.flush(alloc, &out);

    try std.testing.expect(std.mem.find(u8, out.items, "\xe2\x94\xbc") == null);
    try std.testing.expect(std.mem.find(u8, out.items, "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80") != null);
}

test "pipe table with markdown in cells aligns dividers across all rows" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "| Aspect | Value |\n" ++
        "|--------|-------|\n" ++
        "| **bold** | x |\n" ++
        "| plain    | y |\n";
    try processor.push(alloc, input, &out);
    try processor.flush(alloc, &out);

    const expected =
        "\x1b[1mAspect\x1b[22m \xe2\x94\x82 \x1b[1mValue\x1b[22m\n" ++
        "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n" ++
        "\x1b[1mbold\x1b[22m   \xe2\x94\x82 x    \n" ++
        "plain  \xe2\x94\x82 y    \n";
    try std.testing.expectEqualStrings(expected, out.items);
}

test "escaped pipes stay inside table cells while even backslashes retain delimiters" {
    const alloc = std.testing.allocator;
    var table = try parseTablePayload(
        alloc,
        "| Command | Result |\n" ++
            "| --- | --- |\n" ++
            "| printf \\| grep | works |\n",
    );
    defer table.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), table.column_count);
    try std.testing.expectEqualStrings("printf | grep", table.rows[1].cells[0]);
    try std.testing.expect(!isPipeLine("literal \\| pipe"));
    try std.testing.expect(isPipeLine("literal \\\\| delimiter"));
}

test "three-column pipe table aligns junctions with every column pipe" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "| A | B  | C   |\n" ++
        "|---|----|-----|\n" ++
        "| 1 | 22 | 333 |\n";
    try processor.push(alloc, input, &out);
    try processor.flush(alloc, &out);

    const expected_separator =
        "\xe2\x94\x80\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n";
    try std.testing.expect(std.mem.find(u8, out.items, expected_separator) != null);
    try std.testing.expect(std.mem.find(u8, out.items, "1 \xe2\x94\x82 22 \xe2\x94\x82 333\n") != null);
}

test "pipe table without separator falls back to plain lines" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input = "| just one |\n| stray pipes |\n";
    try processor.push(alloc, input, &out);
    try processor.flush(alloc, &out);
    try std.testing.expectEqualStrings("| just one |\n| stray pipes |\n", out.items);
}

test "pipe table preceded by paragraph and followed by paragraph" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "Before table.\n" ++
        "| a | b |\n" ++
        "|---|---|\n" ++
        "| 1 | 2 |\n" ++
        "After table.\n";
    try processor.push(alloc, input, &out);

    try std.testing.expect(std.mem.startsWith(u8, out.items, "Before table.\n"));
    try std.testing.expect(std.mem.endsWith(u8, out.items, "After table.\n"));
}

test "borderless GFM table (no leading/trailing pipes) is detected and rendered" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "Name | Age\n" ++
        "-----|-----\n" ++
        "Ana  | 30\n" ++
        "Bob  | 7\n";
    try processor.push(alloc, input, &out);
    try processor.flush(alloc, &out);

    try std.testing.expect(std.mem.find(u8, out.items, "\xe2\x94\x82") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\xe2\x94\xbc") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\x1b[1mName\x1b[22m") != null);
}

test "borderless separator with spaces around pipe is accepted" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "Característica | Vercel | Cloudflare\n" ++
        "-------------- | ------ | ----------\n" ++
        "Enfoque principal | Frontend | Edge compute\n";
    try processor.push(alloc, input, &out);
    try processor.flush(alloc, &out);

    try std.testing.expect(std.mem.find(u8, out.items, "\xe2\x94\x82") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\xe2\x94\xbc") != null);
}

test "paragraph with single inline pipe falls back to plain (no separator)" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "Use cmd | grep foo to filter.\n" ++
        "Then review the output.\n";
    try processor.push(alloc, input, &out);

    try std.testing.expect(std.mem.find(u8, out.items, "\xe2\x94\x82") == null);
    try std.testing.expect(std.mem.find(u8, out.items, "Use cmd | grep foo") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "Then review the output.") != null);
}

test "header with nested **bold** stays fully bold across the whole line" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "## **Directory** Structure\n", &out);
    try std.testing.expectEqualStrings("\x1b[1mDirectory Structure\x1b[22m\n", out.items);
}

test "header keeps italic and code inline" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "# *note* about `fx`\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[1m\x1b[4m\x1b[3mnote\x1b[23m about \x1b[38;5;255mfx\x1b[39m\x1b[24m\x1b[22m\n",
        out.items,
    );
}

test "strikethrough wraps with ANSI" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "was ~~wrong~~ now right\n", &out);
    try std.testing.expectEqualStrings("was \x1b[9mwrong\x1b[29m now right\n", out.items);
}

test "stray tildes between spaces stay literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "path is ~~ /tmp\n", &out);
    try std.testing.expectEqualStrings("path is ~~ /tmp\n", out.items);
}

test "horizontal rule with dashes renders dim line" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "---\n", &out);
    try std.testing.expect(std.mem.startsWith(u8, out.items, dim_open));
    try std.testing.expect(std.mem.endsWith(u8, out.items, dim_close ++ "\n"));
    const glyphs = std.mem.count(u8, out.items, table_horiz);
    try std.testing.expectEqual(@as(usize, horizontal_rule_width), glyphs);
}

test "thematic rule completion handles newline and EOF without matching H6 content" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        calls: usize = 0,

        fn deliver(raw: *anyopaque, _: *std.ArrayList(u8)) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
        }
    };

    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var capture = Capture{};
    var completion = ThematicRuleCompletion{
        .ctx = &capture,
        .deliver = Capture.deliver,
    };

    try processor.pushWithCompletions(alloc, "---\n", &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    try processor.pushWithCompletions(alloc, "___", &out, .{ .thematic_rule = &completion });
    try processor.flushWithCompletions(alloc, &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    var h6: std.ArrayList(u8) = .empty;
    defer h6.deinit(alloc);
    try h6.appendSlice(alloc, "###### ");
    var i: usize = 0;
    while (i < horizontal_rule_width) : (i += 1) try h6.appendSlice(alloc, table_horiz);
    try h6.append(alloc, '\n');
    try processor.pushWithCompletions(alloc, h6.items, &out, .{ .thematic_rule = &completion });
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expect(out.items.len > 0);
}

test "horizontal rule with asterisks and spaces also renders" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "* * *\n", &out);
    try std.testing.expect(std.mem.find(u8, out.items, table_horiz) != null);
    try std.testing.expect(std.mem.find(u8, out.items, "*") == null);
}

test "hyphen-space line is a list, not a rule" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "- item\n", &out);
    try std.testing.expect(std.mem.find(u8, out.items, "\xe2\x80\xa2") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "\xe2\x94\x80") == null);
}

test "nested unordered list preserves indent" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "  - nested item\n", &out);
    try std.testing.expectEqualStrings("  \x1b[2m\xe2\x80\xa2 \x1b[22mnested item\n", out.items);
}

test "nested ordered list preserves indent" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "    1. sub-step\n", &out);
    try std.testing.expectEqualStrings("      \x1b[2m1.\x1b[22m sub-step\n", out.items);
}

test "right-aligned GFM column pads cell on the left" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "| Name | Score |\n" ++
        "|:-----|------:|\n" ++
        "| Ana  |     5 |\n";
    try processor.push(alloc, input, &out);
    try processor.flush(alloc, &out);

    try std.testing.expect(std.mem.find(u8, out.items, "    5\n") != null);
}

test "center-aligned GFM column pads both sides" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "| Name | Note |\n" ++
        "|------|:----:|\n" ++
        "| Ana  | ok   |\n";
    try processor.push(alloc, input, &out);
    try processor.flush(alloc, &out);

    try std.testing.expect(std.mem.find(u8, out.items, " ok \n") != null);
}

test "pipe table parsing retains styled cells alignment and ragged rows" {
    const alloc = std.testing.allocator;
    var table = try parseTablePayload(
        alloc,
        "| Name | State | Count |\n" ++
            "|:-----|:-----:|------:|\n" ++
            "| **api** | ready | 7 | extra |\n" ++
            "| worker | |\n",
    );
    defer table.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 4), table.column_count);
    try std.testing.expectEqual(@as(usize, 3), table.rows.len);
    try std.testing.expectEqual(TableColumnAlign.center, table.alignments[1]);
    try std.testing.expectEqual(TableColumnAlign.right, table.alignments[2]);
    try std.testing.expectEqualStrings("\x1b[1mapi\x1b[22m", table.rows[1].cells[0]);
    try std.testing.expectEqualStrings("extra", table.rows[1].cells[3]);
    try std.testing.expectEqual(@as(usize, 2), table.rows[2].cells.len);
}

test "pipe table inside code block stays literal" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const input =
        "```\n" ++
        "| not | a |\n" ++
        "|-----|---|\n" ++
        "| table | really |\n" ++
        "```\n";
    try processor.push(alloc, input, &out);

    try std.testing.expect(std.mem.find(u8, out.items, "| not | a |") != null);
    try std.testing.expect(std.mem.find(u8, out.items, "| table | really |") != null);
}

const PreviewDoc = struct { name: []const u8, source: []const u8 };

const preview_docs = [_]PreviewDoc{
    .{ .name = "s1-reply", .source = "Streaming **bold words** and `inline code` with a [link](https://example.com) here.\n\n## Heading\n\n- item one\n- item two\n\n```zig\nconst x = 1;\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nTitle line\n===\n\nEnd *italic* text.\n" },
    .{ .name = "setext-thematic", .source = "Workspace *overview*\n===\nInstallation **guide**\n---\n\n---\n" },
    .{ .name = "setext-eof", .source = "ordinary title\n" },
    .{ .name = "definition-list", .source = "Status\n: **Running**\n: second definition\n" },
    .{ .name = "footnote", .source = "The cache is scoped to this request.[^cache]\n[^cache]: It is discarded after the request completes.\n" },
    .{ .name = "nested-fence", .source = "````md\n```zig\ninner\n```\n````\nafter\n" },
    .{ .name = "blockquote", .source = "> ## Note\n> - one\n> 2. two\n> - [x] done\n> plain\n" },
    .{ .name = "list-with-fence", .source = "1. step\n   ```sh\n   ls -la\n     nested\n   ```\n- next\n" },
    .{ .name = "ordered-list", .source = "1. step one\n" },
    .{ .name = "bold-italic", .source = "hi **there** friend\nuse *this* quickly\n" },
    .{ .name = "nested-strong", .source = "**outer __inner__ suffix** __outer **inner** suffix__\n" },
    .{ .name = "heading-code-span", .source = "## Run ``**raw**`` now\n" },
    .{ .name = "link-osc8", .source = "see [docs](https://example.com) please\n" },
    .{ .name = "link-parens", .source = "[w](https://en.wikipedia.org/wiki/Foo_(bar)) tail\n" },
    .{ .name = "image", .source = "![](https://example.com/diagram.png)\n" },
    .{ .name = "autolinks", .source = "see <https://example.com/docs\\_literal> and <dev@example.com> plus <git+ssh://example.com/repo>\n" },
    .{ .name = "table", .source = "Before table.\n| Name | Age |\n|------|-----|\n| Ana  | 30  |\n| Bob  | 7   |\nAfter table.\n" },
    .{ .name = "table-links", .source = "| Link |\n|------|\n| [first](https://first.example) |\n" },
    .{ .name = "s4-table-code", .source = "Before the table.\n\n| Key | Value |\n|-----|-------|\n| mode | **fast** |\n\n```sh\nls -la\n```\n\nAfter the code.\n" },
};

const equal_docs = [_]PreviewDoc{
    .{ .name = "tall-table", .source = "| Item | Count | Note |\n|------|------:|------|\n| item-1 | 3 | **note 1** |\n| item-2 | 6 | **note 2** |\n| item-3 | 9 | **note 3** |\n| item-4 | 12 | **note 4** |\n| item-5 | 15 | **note 5** |\n| item-6 | 18 | **note 6** |\n| item-7 | 21 | **note 7** |\n| item-8 | 24 | **note 8** |\n| item-9 | 27 | **note 9** |\n| item-10 | 30 | **note 10** |\n| item-11 | 33 | **note 11** |\n| item-12 | 36 | **note 12** |\n| item-13 | 39 | **note 13** |\n| item-14 | 42 | **note 14** |\n| item-15 | 45 | **note 15** |\n| item-16 | 48 | **note 16** |\n| item-17 | 51 | **note 17** |\n| item-18 | 54 | **note 18** |\n| item-19 | 57 | **note 19** |\n| item-20 | 60 | **note 20** |\n| item-21 | 63 | **note 21** |\n| item-22 | 66 | **note 22** |\n| item-23 | 69 | **note 23** |\n| item-24 | 72 | **note 24** |\n| item-25 | 75 | **note 25** |\n| item-26 | 78 | **note 26** |\n| item-27 | 81 | **note 27** |\n| item-28 | 84 | **note 28** |\n| item-29 | 87 | **note 29** |\n| item-30 | 90 | **note 30** |\n| item-31 | 93 | **note 31** |\n| item-32 | 96 | **note 32** |\n| item-33 | 99 | **note 33** |\n| item-34 | 102 | **note 34** |\n| item-35 | 105 | **note 35** |\n| item-36 | 108 | **note 36** |\n| item-37 | 111 | **note 37** |\n| item-38 | 114 | **note 38** |\n| item-39 | 117 | **note 39** |\n| item-40 | 120 | **note 40** |\n" },
    .{ .name = "table-marks-links", .source = "| `code` | [link](https://a.example) | **bold** |\n|---|---|---|\n| x | y | z |\n" },
    .{ .name = "table-then-text", .source = "| A | B |\n|---|---|\n| 1 | 2 |\nAfter the table.\n" },
    .{ .name = "table-alignment", .source = "| Left | Center | Right |\n|:-----|:------:|------:|\n| a | b | c |\n" },
    .{ .name = "table-ragged", .source = "| a | b |\n|---|---|\n| c |\n| d | e | f |\n" },
    .{ .name = "table-escaped-pipe", .source = "| a | b \\| c |\n|---|---|\n| 1 | 2 |\n" },
    .{ .name = "two-tables", .source = "| a |\n|---|\n| 1 |\n\n| b |\n|---|\n| 2 |\n" },
    .{ .name = "table-header-only", .source = "| Only | Header |\n|------|--------|\n" },
    .{ .name = "table-then-code", .source = "| a |\n|---|\n| 1 |\n```sh\nls\n```\n" },
    .{ .name = "fence-language", .source = "```zig\nconst x = 1;\n```\n" },
    .{ .name = "fence-unclosed", .source = "```sh\nls -la\necho **raw**\n" },
    .{ .name = "fence-tall", .source = "```txt\nline 1 of the block\nline 2 of the block\nline 3 of the block\nline 4 of the block\nline 5 of the block\nline 6 of the block\nline 7 of the block\nline 8 of the block\nline 9 of the block\nline 10 of the block\nline 11 of the block\nline 12 of the block\nline 13 of the block\nline 14 of the block\nline 15 of the block\nline 16 of the block\nline 17 of the block\nline 18 of the block\nline 19 of the block\nline 20 of the block\nline 21 of the block\nline 22 of the block\nline 23 of the block\nline 24 of the block\nline 25 of the block\nline 26 of the block\nline 27 of the block\nline 28 of the block\nline 29 of the block\nline 30 of the block\nline 31 of the block\nline 32 of the block\nline 33 of the block\nline 34 of the block\nline 35 of the block\nline 36 of the block\nline 37 of the block\nline 38 of the block\nline 39 of the block\nline 40 of the block\n```\n" },
    .{ .name = "fence-after-text", .source = "Intro text.\n\n```py\nprint('hi')\n```\nOutro.\n" },
    .{ .name = "indented-code", .source = "    indented one\n    indented two\n" },
    .{ .name = "fence-marks", .source = "```md\n**not bold** `x` [a](b)\n```\n" },
    .{ .name = "fence-empty", .source = "```\n```\n" },
    .{ .name = "tilde-fence", .source = "~~~js\nlet y = 2\n~~~\n" },
};

/// Every document the commit checks use: the reply documents, then tables and code.
const commit_documents = preview_docs ++ equal_docs;

const Chunking = enum { byte1, byte3, word, whole };

const PreviewCheck = enum { none, state, marks, words };

const PreviewTally = struct {
    renders: usize = 0,
    marks_checked: usize = 0,
    marks_skipped: usize = 0,
    words_checked: usize = 0,
};

fn nextChunkEnd(source: []const u8, start: usize, chunking: Chunking) usize {
    return switch (chunking) {
        .byte1 => start + 1,
        .byte3 => @min(start + 3, source.len),
        .whole => source.len,
        .word => blk: {
            var end = start;
            while (end < source.len) {
                end += 1;
                if (source[end - 1] == ' ' or source[end - 1] == '\n') break;
            }
            break :blk end;
        },
    };
}

/// Pushes `bytes`, or flushes when null, and collects the events it commits.
fn commitCollect(alloc: Allocator, processor: *MarkdownProcessor, bytes: ?[]const u8, events: *std.ArrayList(Event)) !void {
    var collector = EventCollector{ .alloc = alloc, .events = events };
    const completions = collector.completions();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    if (bytes) |input| {
        try processor.pushWithCompletions(alloc, input, &out, completions);
    } else {
        try processor.flushWithCompletions(alloc, &out, completions);
    }
    try collector.appendPendingText(&out);
}

/// Renders the provisional tail of `processor` as the text a reader sees.
fn renderPreviewDisplay(alloc: Allocator, processor: *const MarkdownProcessor, out: *std.ArrayList(u8)) !void {
    var tail: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &tail);
    _ = try processor.renderProvisional(alloc, &tail);
    for (tail.items) |event| try appendEventDisplay(alloc, event, out);
}

fn displayOf(alloc: Allocator, events: []const Event) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (events) |event| try appendEventDisplay(alloc, event, &out);
    return out.toOwnedSlice(alloc);
}

fn appendEventDisplay(alloc: Allocator, event: Event, out: *std.ArrayList(u8)) !void {
    switch (event) {
        .text => |text| try out.appendSlice(alloc, text),
        .attempt_restart => |text| try out.appendSlice(alloc, text),
        .table => |table| try renderTablePayload(alloc, table, out),
        .code_block => |block| try renderCodeBlockPayload(alloc, block, out),
        .thematic_rule => try writeHorizontalRule(alloc, out),
        .attempt_start, .assistant_tail => {},
    }
}

/// The shown text of `events` with ANSI removed: text, then table cells. Code
/// lines count only with `with_code`, since code may show marks on purpose.
fn plainOf(alloc: Allocator, events: []const Event, with_code: bool) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    for (events) |event| switch (event) {
        .text => |text| try raw.appendSlice(alloc, text),
        .table => |table| try appendTableCells(alloc, &raw, table),
        .code_block => |block| if (with_code) try raw.appendSlice(alloc, block.code),
        else => {},
    };
    if (with_code) return stripEscapes(alloc, raw.items);
    const unlinked = try withoutInlineCode(alloc, raw.items);
    defer alloc.free(unlinked);
    return stripEscapes(alloc, unlinked);
}

/// Removes inline code spans, whose marks show on purpose.
fn withoutInlineCode(alloc: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest = bytes;
    while (std.mem.find(u8, rest, ansi.inline_code_open)) |start| {
        try out.appendSlice(alloc, rest[0..start]);
        const after = rest[start + ansi.inline_code_open.len ..];
        const end = std.mem.find(u8, after, ansi.inline_code_close) orelse after.len;
        rest = after[@min(end + ansi.inline_code_close.len, after.len)..];
    }
    try out.appendSlice(alloc, rest);
    return out.toOwnedSlice(alloc);
}

fn appendTableCells(alloc: Allocator, raw: *std.ArrayList(u8), table: TablePayload) !void {
    for (table.rows) |row| {
        for (row.cells) |cell| {
            try raw.appendSlice(alloc, cell);
            try raw.append(alloc, ' ');
        }
        try raw.append(alloc, '\n');
    }
}

/// A copy of `events` with adjacent text merged and empty text dropped, so two
/// runs that split text differently compare equal.
fn normalizedEvents(alloc: Allocator, events: []const Event) !std.ArrayList(Event) {
    var out: std.ArrayList(Event) = .empty;
    errdefer deinitEvents(alloc, &out);
    for (events) |event| {
        if (event == .text and event.text.len == 0) continue;
        if (event == .text and out.items.len > 0 and std.meta.activeTag(out.items[out.items.len - 1]) == .text) {
            const last = &out.items[out.items.len - 1];
            const old_len = last.text.len;
            const merged = try alloc.realloc(last.text, old_len + event.text.len);
            @memcpy(merged[old_len..], event.text);
            last.text = merged;
            continue;
        }
        var copy = try event.clone(alloc);
        errdefer copy.deinit(alloc);
        try out.append(alloc, copy);
    }
    return out;
}

fn expectSameEvents(alloc: Allocator, expected: []const Event, actual: []const Event) !void {
    var want = try normalizedEvents(alloc, expected);
    defer deinitEvents(alloc, &want);
    var got = try normalizedEvents(alloc, actual);
    defer deinitEvents(alloc, &got);
    try std.testing.expectEqualDeep(want.items, got.items);
}

fn countTag(events: []const Event, tag: std.meta.Tag(Event)) usize {
    var count: usize = 0;
    for (events) |event| count += @intFromBool(std.meta.activeTag(event) == tag);
    return count;
}

/// Feeds `source` in `chunking` pieces and returns the committed events. With
/// `check`, every push also renders a provisional tail and checks it.
fn runPreviewDocument(alloc: Allocator, source: []const u8, chunking: Chunking, check: PreviewCheck, tally: *PreviewTally) !std.ArrayList(Event) {
    link_id_counter = 1;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var events: std.ArrayList(Event) = .empty;
    errdefer deinitEvents(alloc, &events);
    var pos: usize = 0;
    while (pos < source.len) {
        const end = nextChunkEnd(source, pos, chunking);
        try commitCollect(alloc, &processor, source[pos..end], &events);
        pos = end;
        if (check != .none) try checkPreview(alloc, &processor, check, tally);
    }
    try commitCollect(alloc, &processor, null, &events);
    return events;
}

fn checkPreview(alloc: Allocator, processor: *const MarkdownProcessor, check: PreviewCheck, tally: *PreviewTally) !void {
    const before = try heldState(alloc, processor);
    defer alloc.free(before);
    const counter_before = link_id_counter;
    var tail: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &tail);
    _ = try processor.renderProvisional(alloc, &tail);
    const after = try heldState(alloc, processor);
    defer alloc.free(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expectEqual(counter_before, link_id_counter);
    tally.renders += 1;
    if (check == .state) return;
    if (check == .marks) {
        const shown = try plainOf(alloc, tail.items, false);
        defer alloc.free(shown);
        tally.marks_checked += 1;
        try expectNoRawMarks(shown);
        return;
    }
    const shown = try plainOf(alloc, tail.items, true);
    defer alloc.free(shown);
    tally.words_checked += try expectHeldWordsShown(processor, shown);
}

/// Everything the processor holds, so a preview that changes any of it fails.
fn heldState(alloc: Allocator, p: *const MarkdownProcessor) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    const parts = [_][]const u8{ p.line_buf.items, p.pending_top_level_line.items, p.pipe_buf.items, p.code_buf.items, p.code_language.items };
    for (parts) |part| {
        try buf.appendSlice(alloc, part);
        try buf.append(alloc, 0);
    }
    try buf.append(alloc, @intFromBool(p.in_code_block));
    try buf.append(alloc, @intFromBool(p.in_pipe_block));
    try buf.append(alloc, @intFromBool(p.active_definition));
    try buf.append(alloc, @intFromBool(p.previous_line_was_blank));
    const footnote_count = p.footnotes.items.len;
    try buf.appendSlice(alloc, std.mem.asBytes(&footnote_count));
    try buf.appendSlice(alloc, std.mem.asBytes(&p.next_footnote_number));
    for (p.footnotes.items) |note| {
        try buf.appendSlice(alloc, note.label);
        try buf.append(alloc, 0);
        try buf.appendSlice(alloc, note.body.items);
        try buf.append(alloc, 0);
    }
    return buf.toOwnedSlice(alloc);
}

fn stripEscapes(alloc: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] != 0x1b) {
            try out.append(alloc, bytes[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= bytes.len) break;
        if (bytes[i] == '[') {
            i += 1;
            while (i < bytes.len and (bytes[i] < 0x40 or bytes[i] > 0x7e)) i += 1;
            i += 1;
            continue;
        }
        if (bytes[i] == ']') {
            i += 1;
            while (i < bytes.len and bytes[i] != 0x07 and bytes[i] != 0x1b) i += 1;
            if (i < bytes.len and bytes[i] == 0x1b) {
                i += 2;
            } else {
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// Checks the shown preview text: no raw `**`, `~~`, or `](`, no unpaired
/// backtick, no line that starts with a pipe, and no visible byte escape.
fn expectNoRawMarks(plain: []const u8) !void {
    for ([_][]const u8{ "**", "~~", "](", "\\x" }) |needle| {
        if (std.mem.find(u8, plain, needle) != null) {
            std.debug.print("raw {s} in provisional text: {s}\n", .{ needle, plain });
            return error.RawMarkShown;
        }
    }
    var ticks: usize = 0;
    for (plain) |byte| ticks += @intFromBool(byte == '`');
    if (ticks % 2 == 1) {
        std.debug.print("unpaired backtick in provisional text: {s}\n", .{plain});
        return error.RawMarkShown;
    }
    var lines = std.mem.splitScalar(u8, plain, '\n');
    while (lines.next()) |line| {
        if (std.mem.trimStart(u8, line, " \t").len > 0 and std.mem.trimStart(u8, line, " \t")[0] == pipe_byte) {
            std.debug.print("raw pipe row in provisional text: {s}\n", .{line});
            return error.RawPipeShown;
        }
    }
}

/// Counts the held words and checks each is in the preview. A line that
/// rule 4 hides, such as "1.", holds a digit but shows nothing.
fn expectHeldWordsShown(p: *const MarkdownProcessor, plain: []const u8) !usize {
    var checked: usize = 0;
    const open_line_hidden = p.line_buf.items.len > 0 and opensWithBlockMarkersOnly(p.line_buf.items);
    const parts = [_][]const u8{ p.pending_top_level_line.items, if (open_line_hidden) "" else p.line_buf.items, p.pipe_buf.items, p.code_buf.items };
    for (parts) |held| {
        var i: usize = 0;
        while (i < held.len) {
            if (held[i] == '[' and i + 1 < held.len and held[i + 1] == '^') {
                i = (std.mem.findScalarPos(u8, held, i, ']') orelse held.len - 1) + 1;
                continue;
            }
            if (held[i] == ']' and i + 1 < held.len and held[i + 1] == '(') {
                i = (std.mem.findScalarPos(u8, held, i, ')') orelse held.len - 1) + 1;
                continue;
            }
            if (held[i] == '[' and i + 2 < held.len and held[i + 2] == ']' and
                std.mem.findScalar(u8, " xX", held[i + 1]) != null and
                (i + 3 == held.len or held[i + 3] == ' '))
            {
                i += 3;
                continue;
            }
            if (!std.ascii.isAlphanumeric(held[i])) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < held.len and std.ascii.isAlphanumeric(held[i])) i += 1;
            const word = held[start..i];
            checked += 1;
            if (std.mem.find(u8, plain, word) == null) {
                std.debug.print("word {s} not shown; provisional text: {s}\n", .{ word, plain });
                return error.WordNotShown;
            }
        }
    }
    return checked;
}

test "provisional render never changes committed output" {
    const alloc = std.testing.allocator;
    var tally = PreviewTally{};
    for (preview_docs) |doc| {
        var whole = try runPreviewDocument(alloc, doc.source, .whole, .none, &tally);
        defer deinitEvents(alloc, &whole);
        for ([_]Chunking{ .byte1, .byte3, .word }) |chunking| {
            var plain = try runPreviewDocument(alloc, doc.source, chunking, .none, &tally);
            defer deinitEvents(alloc, &plain);
            expectSameEvents(alloc, whole.items, plain.items) catch |err| {
                std.debug.print("doc {s} chunking {s}: committed events differ from one push\n", .{ doc.name, @tagName(chunking) });
                return err;
            };
            var previewed = try runPreviewDocument(alloc, doc.source, chunking, .state, &tally);
            defer deinitEvents(alloc, &previewed);
            expectSameEvents(alloc, whole.items, previewed.items) catch |err| {
                std.debug.print("doc {s} chunking {s}: committed events with previews differ from one push\n", .{ doc.name, @tagName(chunking) });
                return err;
            };
        }
    }
    std.debug.print("T1 documents={d} chunkings=3 provisional_renders={d}\n", .{ preview_docs.len, tally.renders });
}

test "provisional text shows no raw marks" {
    const alloc = std.testing.allocator;
    var tally = PreviewTally{};
    for (commit_documents) |doc| {
        for ([_]Chunking{ .byte1, .byte3, .word }) |chunking| {
            var events = try runPreviewDocument(alloc, doc.source, chunking, .marks, &tally);
            deinitEvents(alloc, &events);
        }
    }
    std.debug.print("T2 documents={d} renders={d} marks_checked={d}\n", .{ commit_documents.len, tally.renders, tally.marks_checked });
}

test "provisional text shows every received word" {
    const alloc = std.testing.allocator;
    var tally = PreviewTally{};
    for (commit_documents) |doc| {
        var events = try runPreviewDocument(alloc, doc.source, .word, .words, &tally);
        deinitEvents(alloc, &events);
    }
    std.debug.print("T3 documents={d} renders={d} held_words_checked={d}\n", .{ commit_documents.len, tally.renders, tally.words_checked });
}

fn printEventKinds(label: []const u8, events: []const Event) void {
    std.debug.print("{s}:", .{label});
    for (events) |event| switch (event) {
        .text => |text| std.debug.print(" text({d})", .{text.len}),
        .table => |table| std.debug.print(" table(rows={d},cols={d})", .{ table.rows.len, table.column_count }),
        .code_block => |block| std.debug.print(" code({d})", .{block.code.len}),
        .thematic_rule => std.debug.print(" rule", .{}),
        .assistant_tail => std.debug.print(" tail", .{}),
        else => std.debug.print(" other", .{}),
    };
    std.debug.print("\n", .{});
}

/// Counts what the cut-point check compared and skipped.
const CutTally = struct {
    cuts: usize = 0,
    compared: usize = 0,
    compared_with_table: usize = 0,
    compared_with_code: usize = 0,
    compared_table_header: usize = 0,
    skipped_open_end: usize = 0,
};

/// Adds the delimiter row the preview shows under a held header, and returns the bytes to commit.
fn withDelimiterRow(alloc: Allocator, held: *const MarkdownProcessor, prefix: []const u8, out: *std.ArrayList(u8)) ![]const u8 {
    if (held.in_pipe_block) {
        const header_line = held.pipe_buf.items[0..std.mem.findScalar(u8, held.pipe_buf.items, '\n').?];
        const header_end = prefix.len - held.line_buf.items.len;
        try out.appendSlice(alloc, prefix[0..header_end]);
        try appendLiteralDelimiter(alloc, out, tableColumnCount(header_line));
        try out.appendSlice(alloc, prefix[header_end..]);
    } else {
        try out.appendSlice(alloc, prefix);
        try out.append(alloc, '\n');
        try appendLiteralDelimiter(alloc, out, tableColumnCount(held.line_buf.items));
    }
    return out.items;
}

fn appendLiteralDelimiter(alloc: Allocator, out: *std.ArrayList(u8), columns: usize) !void {
    try out.append(alloc, '|');
    for (0..columns) |_| try out.appendSlice(alloc, "---|");
    try out.append(alloc, '\n');
}

/// Checks one cut point: the provisional tail of the first `cut` bytes equals the
/// events the processor commits for those bytes, unless an open-end rule changed the open line.
fn expectTailMatchesCommit(alloc: Allocator, source: []const u8, cut: usize, tally: *CutTally) !void {
    tally.cuts += 1;
    link_id_counter = 1;
    var held = MarkdownProcessor{};
    defer held.deinit(alloc);
    var pushed: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &pushed);
    try commitCollect(alloc, &held, source[0..cut], &pushed);
    var tail: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &tail);
    const result = try held.renderProvisional(alloc, &tail);
    if (result.open_end_applied) {
        tally.skipped_open_end += 1;
        return;
    }
    var completed: std.ArrayList(u8) = .empty;
    defer completed.deinit(alloc);
    const input = if (result.table_header_completed) try withDelimiterRow(alloc, &held, source[0..cut], &completed) else source[0..cut];
    link_id_counter = 1;
    var fresh = MarkdownProcessor{};
    defer fresh.deinit(alloc);
    var committed: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &committed);
    try commitCollect(alloc, &fresh, input, &committed);
    try commitCollect(alloc, &fresh, null, &committed);
    // What the reader sees: what was committed before the cut, then the tail.
    var shown: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &shown);
    try appendCopies(alloc, &shown, pushed.items);
    try appendCopies(alloc, &shown, tail.items);
    expectSameEvents(alloc, committed.items, shown.items) catch |err| {
        std.debug.print("cut {d}: header_completed={any} open_end={any}\n", .{ cut, result.table_header_completed, result.open_end_applied });
        printEventKinds("shown", shown.items);
        printEventKinds("commit", committed.items);
        return err;
    };
    tally.compared += 1;
    tally.compared_with_table += @intFromBool(countTag(tail.items, .table) > 0);
    tally.compared_with_code += @intFromBool(countTag(tail.items, .code_block) > 0);
    tally.compared_table_header += @intFromBool(result.table_header_completed);
}

fn appendCopies(alloc: Allocator, dest: *std.ArrayList(Event), src: []const Event) !void {
    for (src) |event| {
        var copy = try event.clone(alloc);
        errdefer copy.deinit(alloc);
        try dest.append(alloc, copy);
    }
}

test "preview equals commit at every cut point" {
    const alloc = std.testing.allocator;
    var tally = CutTally{};
    for (commit_documents) |doc| {
        for (1..doc.source.len + 1) |cut| {
            expectTailMatchesCommit(alloc, doc.source, cut, &tally) catch |err| {
                std.debug.print("doc {s} cut {d}: preview differs from commit\n", .{ doc.name, cut });
                return err;
            };
        }
    }
    std.debug.print("T5 documents={d} cut_points={d} compared={d} compared_with_table={d} compared_with_code={d} compared_with_header_completion={d} skipped_open_end={d}\n", .{ commit_documents.len, tally.cuts, tally.compared, tally.compared_with_table, tally.compared_with_code, tally.compared_table_header, tally.skipped_open_end });
}

test "provisional preview of a one megabyte line completes" {
    const alloc = std.testing.allocator;
    const io_mod = @import("../shared/io.zig");
    var collected: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &collected);
    var collector = EventCollector{ .alloc = alloc, .events = &collected };
    const completions = collector.completions();
    const megabyte = 1024 * 1024;
    const unit = "word **b** ";
    const source = try alloc.alloc(u8, megabyte);
    defer alloc.free(source);
    for (source, 0..) |*byte, index| byte.* = unit[index % unit.len];

    link_id_counter = 1;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var committed: std.ArrayList(u8) = .empty;
    defer committed.deinit(alloc);
    const chunk = 64 * 1024;
    var pos: usize = 0;
    while (pos < source.len) : (pos += chunk) {
        try processor.pushWithCompletions(alloc, source[pos..@min(pos + chunk, source.len)], &committed, completions);
    }
    try std.testing.expectEqual(@as(usize, 0), committed.items.len);

    var preview: std.ArrayList(u8) = .empty;
    defer preview.deinit(alloc);
    const started = io_mod.nanoTimestamp();
    try renderPreviewDisplay(alloc, &processor, &preview);
    const elapsed = io_mod.nanoTimestamp() - started;
    const plain = try stripEscapes(alloc, preview.items);
    defer alloc.free(plain);
    try expectNoRawMarks(plain);
    try std.testing.expect(std.mem.find(u8, plain, "word") != null);
    std.debug.print("one megabyte preview ns={d} provisional_bytes={d}\n", .{ elapsed, preview.items.len });
}

test "UTF-8 split across chunks never shows partial bytes" {
    const alloc = std.testing.allocator;
    var tally = PreviewTally{};
    const source = "Caf\u{e9} \u{2615} **bold** end\n";
    var whole_events = try runPreviewDocument(alloc, source, .whole, .none, &tally);
    defer deinitEvents(alloc, &whole_events);
    const whole = try displayOf(alloc, whole_events.items);
    defer alloc.free(whole);
    var split_events = try runPreviewDocument(alloc, source, .byte1, .marks, &tally);
    defer deinitEvents(alloc, &split_events);
    const split = try displayOf(alloc, split_events.items);
    defer alloc.free(split);
    try std.testing.expectEqualStrings(whole, split);
}

test "unclosed bold stays literal at the end and never shows in a preview" {
    const alloc = std.testing.allocator;
    var tally = PreviewTally{};
    const source = "Start **bold never closed";
    var whole_events = try runPreviewDocument(alloc, source, .whole, .none, &tally);
    defer deinitEvents(alloc, &whole_events);
    const whole = try displayOf(alloc, whole_events.items);
    defer alloc.free(whole);
    try std.testing.expect(std.mem.find(u8, whole, "**bold never closed") != null);
    var split_events = try runPreviewDocument(alloc, source, .byte1, .marks, &tally);
    defer deinitEvents(alloc, &split_events);
    const split = try displayOf(alloc, split_events.items);
    defer alloc.free(split);
    try std.testing.expectEqualStrings(whole, split);
}

test "footnote definitions stay held and preview with their body" {
    const alloc = std.testing.allocator;
    var collected: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &collected);
    var collector = EventCollector{ .alloc = alloc, .events = &collected };
    const completions = collector.completions();
    var tally = PreviewTally{};
    const source = "Cache[^c] is short.\n[^c]: Scoped to the **request** lifetime.\n";
    var whole_events = try runPreviewDocument(alloc, source, .whole, .none, &tally);
    defer deinitEvents(alloc, &whole_events);
    const whole = try displayOf(alloc, whole_events.items);
    defer alloc.free(whole);
    var split_events = try runPreviewDocument(alloc, source, .byte1, .marks, &tally);
    defer deinitEvents(alloc, &split_events);
    const split = try displayOf(alloc, split_events.items);
    defer alloc.free(split);
    try std.testing.expectEqualStrings(whole, split);

    link_id_counter = 1;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var committed: std.ArrayList(u8) = .empty;
    defer committed.deinit(alloc);
    try processor.pushWithCompletions(alloc, source, &committed, completions);
    var preview: std.ArrayList(u8) = .empty;
    defer preview.deinit(alloc);
    try renderPreviewDisplay(alloc, &processor, &preview);
    const plain = try stripEscapes(alloc, preview.items);
    defer alloc.free(plain);
    try std.testing.expect(std.mem.find(u8, plain, "lifetime") != null);
    try expectNoRawMarks(plain);
}

const fuzz_preview_pieces = [_][]const u8{
    "**",        "*",     "~~",   "`",      "[",   "](", ")",       "|",
    "| --- |\n", "\n",    " ",    "- ",     "1. ", "> ", "# ",      "[^a]: ",
    "[^a]",      "```\n", "word", "\u{e9}", "\\",  "_",  "| a |\n",
};

fn fuzzProvisionalPreviews(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    for (0..smith.valueRangeAtMost(u8, 0, 48)) |_| {
        try source.appendSlice(alloc, fuzz_preview_pieces[smith.index(fuzz_preview_pieces.len)]);
    }
    var tally = PreviewTally{};
    var whole = try runPreviewDocument(alloc, source.items, .whole, .none, &tally);
    defer deinitEvents(alloc, &whole);

    link_id_counter = 1;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var committed: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &committed);
    var preview: std.ArrayList(u8) = .empty;
    defer preview.deinit(alloc);
    var start: usize = 0;
    while (start < source.items.len) {
        const len: usize = smith.valueRangeAtMost(u16, 1, @intCast(source.items.len - start));
        try commitCollect(alloc, &processor, source.items[start..][0..len], &committed);
        preview.clearRetainingCapacity();
        try renderPreviewDisplay(alloc, &processor, &preview);
        start += len;
    }
    try commitCollect(alloc, &processor, null, &committed);
    try expectSameEvents(alloc, whole.items, committed.items);
    var cuts = CutTally{};
    const cut: usize = smith.valueRangeAtMost(u32, 0, @intCast(source.items.len));
    try expectTailMatchesCommit(alloc, source.items, cut, &cuts);
}

test "an empty fuzz document previews as nothing and matches its commit" {
    var smith: std.testing.Smith = .{ .in = "" };
    try fuzzProvisionalPreviews({}, &smith);
}

test "provisional previews keep committed output for fuzzed splits" {
    try std.testing.fuzz({}, fuzzProvisionalPreviews, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "**bold\n| a | b |\n",
            "```sh\nls\n",
            "Cafe\xcc\x81 [^a]",
        })),
    });
}

const OpenCase = struct {
    input: []const u8,
    visible: []const u8,
    /// A styled run that must appear in the preview, such as `ansi.bold_open ++ "bold"`.
    styled: []const u8 = "",
    /// A word that must sit inside inline code.
    code: []const u8 = "",
    source: []const u8,
};

const open_cases = [_]OpenCase{
    .{ .input = "Text with **bold", .visible = "Text with bold", .styled = ansi.bold_open ++ "bold", .source = "remend bold L6" },
    .{ .input = "**incomplete", .visible = "incomplete", .styled = ansi.bold_open ++ "incomplete", .source = "remend bold L7" },
    .{ .input = "Text with **bold text**", .visible = "Text with bold text", .styled = ansi.bold_open ++ "bold text", .source = "remend bold L12" },
    .{ .input = "**bold1** and **bold2**", .visible = "bold1 and bold2", .styled = ansi.bold_open ++ "bold1", .source = "remend bold L17" },
    .{ .input = "**first** and **second", .visible = "first and second", .styled = ansi.bold_open ++ "second", .source = "remend bold L21" },
    .{ .input = "Here is some **bold tex", .visible = "Here is some bold tex", .styled = ansi.bold_open ++ "bold tex", .source = "remend bold L25" },
    .{ .input = "**xxx*", .visible = "xxx", .styled = ansi.italic_open ++ "xxx", .source = "remend bold L31: the single closer is italic" },
    .{ .input = "**bold text*", .visible = "bold text", .styled = ansi.italic_open ++ "bold text", .source = "remend bold L32" },
    .{ .input = "Text with **bold*", .visible = "Text with bold", .styled = ansi.italic_open ++ "bold", .source = "remend bold L33" },
    .{ .input = "This is **bold text*", .visible = "This is bold text", .styled = ansi.italic_open ++ "bold text", .source = "remend bold L34" },
    .{ .input = "Text with `code", .visible = "Text with code", .code = "code", .source = "remend inline-code L6" },
    .{ .input = "`incomplete", .visible = "incomplete", .code = "incomplete", .source = "remend inline-code L7" },
    .{ .input = "Text with `inline code`", .visible = "Text with inline code", .code = "inline code", .source = "remend inline-code L12" },
    .{ .input = "`code1` and `code2`", .visible = "code1 and code2", .code = "code2", .source = "remend inline-code L17" },
    .{ .input = "```code```", .visible = "", .source = "remend inline-code L42: a fence line is structure" },
    .{ .input = "Text with __italic", .visible = "Text with italic", .styled = ansi.bold_open ++ "italic", .source = "remend italic L6: a double underscore is strong" },
    .{ .input = "__incomplete", .visible = "incomplete", .styled = ansi.bold_open ++ "incomplete", .source = "remend italic L7" },
    .{ .input = "__first__ and __second", .visible = "first and second", .styled = ansi.bold_open ++ "second", .source = "remend italic L16" },
    .{ .input = "__xxx_", .visible = "xxx", .styled = ansi.italic_open ++ "xxx", .source = "remend italic L22" },
    .{ .input = "__bold text_", .visible = "bold text", .styled = ansi.italic_open ++ "bold text", .source = "remend italic L23" },
    .{ .input = "Text with *italic", .visible = "Text with italic", .styled = ansi.italic_open ++ "italic", .source = "remend italic L31" },
    .{ .input = "*incomplete", .visible = "incomplete", .styled = ansi.italic_open ++ "incomplete", .source = "remend italic L32" },
    .{ .input = "~~strikethrough~~", .visible = "strikethrough", .styled = ansi.strike_open ++ "strikethrough", .source = "remend single-tilde L18" },
    .{ .input = "~hello", .visible = "~hello", .source = "remend single-tilde L22: one tilde is text" },
    .{ .input = "hello ~ world", .visible = "hello ~ world", .source = "remend single-tilde L27" },
    .{ .input = "Text with ~~strike", .visible = "Text with strike", .styled = ansi.strike_open ++ "strike", .source = "remend strikethrough L6" },
    .{ .input = "~~incomplete", .visible = "incomplete", .styled = ansi.strike_open ++ "incomplete", .source = "remend strikethrough L7" },
    .{ .input = "~~first~~ and ~~second", .visible = "first and second", .styled = ansi.strike_open ++ "second", .source = "remend strikethrough L21" },
    .{ .input = "~~xxx~", .visible = "xxx", .styled = ansi.strike_open ++ "xxx", .source = "remend strikethrough L27" },
    .{ .input = "~~strike text~", .visible = "strike text", .styled = ansi.strike_open ++ "strike text", .source = "remend strikethrough L28" },
    .{ .input = "***first*** and ***second", .visible = "first and second", .styled = ansi.bold_open ++ "first", .source = "remend bold-italic L23" },
    .{ .input = "***incomplete", .visible = "incomplete", .styled = ansi.bold_open ++ "incomplete", .source = "remend bold-italic L9" },
    .{ .input = "*italic* **bold** ***both", .visible = "italic bold both", .styled = ansi.bold_open ++ "both", .source = "remend bold-italic L29" },
    .{ .input = "Check out [this lin", .visible = "Check out this lin", .source = "remend links L45: link text only" },
    .{ .input = "Text [partial", .visible = "Text partial", .source = "remend links L9: link text only" },
    .{ .input = "[link with [brackets] inside](https://example.com)", .visible = "[link with [brackets] inside](https://example.com)", .source = "remend links L41: complete, unchanged" },
    .{ .input = "[link1](url1) and [link2](url2)", .visible = "link1 and link2", .source = "remend links L21: complete links" },
    .{ .input = "[w](https://en.wikipedia.org/wiki/Foo_(bar", .visible = "w", .source = "the destination stays open until its parenthesis closes" },
    .{ .input = "[w](https://en.wikipedia.org/wiki/Foo_(bar))", .visible = "w", .source = "complete link is unchanged" },
    .{ .input = "snake_case_name", .visible = "snake_case_name", .source = "remend emphasis-delimiters: intraword underscore" },
    .{ .input = "* Single item", .visible = "• Single item", .source = "remend lists L12" },
    .{ .input = "* Item with *italic* text", .visible = "• Item with italic text", .styled = ansi.italic_open ++ "italic", .source = "remend lists L22" },
    .{ .input = "-", .visible = "", .source = "block markers only show nothing" },
    .{ .input = "1.", .visible = "", .source = "a number and a dot show nothing" },
    .{ .input = "|", .visible = "", .source = "block markers only show nothing" },
    .{ .input = "``````", .visible = "", .source = "backticks only show nothing" },
    .{ .input = "hello~", .visible = "hello", .source = "a lone end mark is hidden" },
    .{ .input = "trailing mark *", .visible = "trailing mark ", .source = "a lone end mark is hidden" },
    .{ .input = "Price is 5 _", .visible = "Price is 5 ", .source = "a lone end mark is hidden" },
    .{ .input = "Text with **", .visible = "Text with ", .source = "an open mark with no content is hidden" },
    .{ .input = "```sh", .visible = "", .source = "a fence line is structure" },
    .{ .input = "`a``", .visible = "a``", .code = "a``", .source = "fuzz: a closer must not merge with a backtick in the content" },
    .{ .input = "**bold\t", .visible = "bold\t", .styled = ansi.bold_open ++ "bold", .source = "fuzz: a closer must follow a non-space byte" },
    .{ .input = "a](`b) c", .visible = "a](b) c", .code = "b) c", .source = "fuzz: a backtick inside a destination is an unpartnered run" },
    .{ .input = "e_case *snake_case *a* _", .visible = "e_case snake_case a ", .styled = ansi.italic_open ++ "a", .source = "fuzz: two closers of one mark must not join" },
    .{ .input = "*one *two*", .visible = "one two", .styled = ansi.italic_open ++ "two", .source = "fuzz: adjacent single-star closers" },
    .{ .input = "_one _two_", .visible = "one two", .styled = ansi.italic_open ++ "two", .source = "fuzz: adjacent single-underscore closers" },
    .{ .input = "~~one ~~two~~", .visible = "one two", .styled = ansi.strike_open ++ "two", .source = "fuzz: adjacent double-tilde closers" },
    .{ .input = "word** end", .visible = "word** end", .source = "fuzz: a closer with no opener stays literal, as in committed text" },
    .{ .input = "**bold \\", .visible = "bold ", .styled = ansi.bold_open ++ "bold", .source = "fuzz: a lone trailing backslash shows nothing" },
};

fn expectPreviewHas(bytes: []const u8, needle: []const u8, source: []const u8) !void {
    if (std.mem.find(u8, bytes, needle) != null) return;
    std.debug.print("open case ({s}): expected {d} bytes of styled text in the preview\n", .{ source, needle.len });
    return error.OpenStyleMissing;
}

// Each named open line previews as its visible text, and as styled text where
// the case names a style. The preview of an open line never commits anything.
test "named open lines preview as open text" {
    const alloc = std.testing.allocator;
    for (open_cases) |case| {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var committed: std.ArrayList(u8) = .empty;
        defer committed.deinit(alloc);
        try processor.push(alloc, case.input, &committed);
        try std.testing.expectEqualStrings("", committed.items);

        var preview: std.ArrayList(u8) = .empty;
        defer preview.deinit(alloc);
        try renderPreviewDisplay(alloc, &processor, &preview);
        const plain = try stripEscapes(alloc, preview.items);
        defer alloc.free(plain);
        std.testing.expectEqualStrings(case.visible, plain) catch |err| {
            std.debug.print("open case ({s}) input=[{s}] shown=[{s}]\n", .{ case.source, case.input, plain });
            return err;
        };
        if (case.styled.len > 0) try expectPreviewHas(preview.items, case.styled, case.source);
        if (case.code.len > 0) {
            const needle = try std.fmt.allocPrint(alloc, "{s}{s}", .{ ansi.inline_code_open, case.code });
            defer alloc.free(needle);
            try expectPreviewHas(preview.items, needle, case.source);
        }
    }
}

// Cells of a held table row that the stream has not finished show open text,
// and only that row: the finished rows above it stay committed.
test "an open marker-only line never previews as a rule" {
    const alloc = std.testing.allocator;
    const open_lines = [_][]const u8{
        "** **",
        "---",
        "***",
        "___",
        "```",
        "- ",
        "1. ",
        "> ",
        "# ",
    };
    for (open_lines) |open_line| {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var committed: std.ArrayList(Event) = .empty;
        defer deinitEvents(alloc, &committed);
        const held = try alloc.print("w1\n{s}", .{open_line});
        defer alloc.free(held);
        try commitCollect(alloc, &processor, held, &committed);
        var tail: std.ArrayList(Event) = .empty;
        defer deinitEvents(alloc, &tail);
        _ = try processor.renderProvisional(alloc, &tail);
        for (tail.items) |event| {
            if (std.meta.activeTag(event) == .thematic_rule) {
                std.debug.print("rule preview for open line: {s}\n", .{open_line});
                return error.RulePreviewed;
            }
        }
        const shown = try displayOf(alloc, tail.items);
        defer alloc.free(shown);
        try std.testing.expectEqualStrings("w1\n", shown);
    }
}

test "an open line with control bytes previews escaped, as committed text shows them" {
    const alloc = std.testing.allocator;
    const open_line = "Streaming \x1b[31mred\x1b[0m \x1b]0;title\x07 done";
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var committed: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &committed);
    try commitCollect(alloc, &processor, open_line, &committed);
    var tail: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &tail);
    _ = try processor.renderProvisional(alloc, &tail);
    const shown = try displayOf(alloc, tail.items);
    defer alloc.free(shown);

    var reference_processor = MarkdownProcessor{};
    defer reference_processor.deinit(alloc);
    var reference_events: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &reference_events);
    try commitCollect(alloc, &reference_processor, open_line ++ "\n", &reference_events);
    try commitCollect(alloc, &reference_processor, null, &reference_events);
    const reference = try displayOf(alloc, reference_events.items);
    defer alloc.free(reference);

    try std.testing.expect(std.mem.find(u8, shown, "\x1b]0;") == null);
    try std.testing.expect(std.mem.find(u8, shown, "\x1b[31m") == null);
    try std.testing.expect(std.mem.find(u8, shown, "\x07") == null);
    const trimmed = std.mem.trimEnd(u8, reference, "\n");
    try std.testing.expect(std.mem.find(u8, trimmed, shown) != null);
}

test "an open marker line that gains text previews as text, not as a rule" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var committed: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &committed);
    try commitCollect(alloc, &processor, "w1\n** ****w5", &committed);
    var tail: std.ArrayList(Event) = .empty;
    defer deinitEvents(alloc, &tail);
    _ = try processor.renderProvisional(alloc, &tail);
    for (tail.items) |event| {
        try std.testing.expect(std.meta.activeTag(event) != .thematic_rule);
    }
    const shown = try displayOf(alloc, tail.items);
    defer alloc.free(shown);
    try std.testing.expect(std.mem.find(u8, shown, "w5") != null);
}

test "open table row shows its open marks as styled text" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var committed: std.ArrayList(u8) = .empty;
    defer committed.deinit(alloc);
    try processor.push(alloc, "| a | b |\n|---|---|\n| c | **d", &committed);
    var preview: std.ArrayList(u8) = .empty;
    defer preview.deinit(alloc);
    try renderPreviewDisplay(alloc, &processor, &preview);
    try std.testing.expect(std.mem.find(u8, preview.items, "**") == null);
    try expectPreviewHas(preview.items, ansi.bold_open ++ "d", "open table row");
}
