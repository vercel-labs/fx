const std = @import("std");
const Allocator = std.mem.Allocator;

const display_width = @import("../shared/display_width.zig");
const ansi = @import("presentation/ansi.zig");
const tu = @import("presentation/text_util.zig");
const bp = @import("presentation/block_parse.zig");
const payload = @import("presentation/payload.zig");
const inline_render = @import("presentation/inline_render.zig");
const block_render = @import("presentation/block_render.zig");

/// Prevents OSC 8 hyperlinks from coalescing across wrapped terminal rows.
var link_id_counter: u32 = 1;

pub const setInlineCodeTheme = ansi.setInlineCodeTheme;
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

    pub fn clone(self: Event, alloc: Allocator) Allocator.Error!Event {
        return switch (self) {
            .text => |text| .{ .text = try alloc.dupe(u8, text) },
            .table => |table| .{ .table = try table.clone(alloc) },
            .code_block => |block| .{ .code_block = try block.clone(alloc) },
            .thematic_rule => .thematic_rule,
        };
    }

    pub fn requiresTextDrain(self: Event) bool {
        return switch (self) {
            .text => false,
            .table, .code_block, .thematic_rule => true,
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
            .thematic_rule => 1,
        };
    }

    pub fn deinit(self: *Event, alloc: Allocator) void {
        switch (self.*) {
            .text => |text| alloc.free(text),
            .table => |*table| table.deinit(alloc),
            .code_block => |*block| block.deinit(alloc),
            .thematic_rule => {},
        }
        self.* = undefined;
    }
};

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

pub const MarkdownProcessor = struct {
    line_buf: std.ArrayList(u8) = .empty,
    pending_top_level_line: std.ArrayList(u8) = .empty,
    pipe_buf: std.ArrayList(u8) = .empty,
    code_buf: std.ArrayList(u8) = .empty,
    code_language: std.ArrayList(u8) = .empty,
    in_code_block: bool = false,
    code_fence_marker: ?u8 = null,
    in_pipe_block: bool = false,
    pipe_last_line_has_lf: bool = false,
    active_blockquote: ?bp.BlockquotePrefix = null,
    active_definition: bool = false,
    footnotes: std.ArrayList(Footnote) = .empty,
    active_footnote: ?ActiveFootnote = null,
    next_footnote_number: usize = 0,
    previous_line_was_blank: bool = true,

    pub fn deinit(self: *MarkdownProcessor, alloc: Allocator) void {
        self.line_buf.deinit(alloc);
        self.pending_top_level_line.deinit(alloc);
        self.pipe_buf.deinit(alloc);
        self.code_buf.deinit(alloc);
        self.code_language.deinit(alloc);
        self.deinitFootnotes(alloc);
    }

    pub fn reset(self: *MarkdownProcessor, alloc: Allocator) void {
        self.line_buf.clearAndFree(alloc);
        self.pending_top_level_line.clearAndFree(alloc);
        self.pipe_buf.clearAndFree(alloc);
        self.code_buf.clearAndFree(alloc);
        self.code_language.clearAndFree(alloc);
        self.deinitFootnotes(alloc);
        self.in_code_block = false;
        self.code_fence_marker = null;
        self.in_pipe_block = false;
        self.pipe_last_line_has_lf = false;
        self.active_blockquote = null;
        self.active_definition = false;
        self.active_footnote = null;
        self.next_footnote_number = 0;
        self.previous_line_was_blank = true;
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
                try self.handleLine(alloc, self.line_buf.items[0..line_end], true, out, completions);
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
        const had_partial_line = self.line_buf.items.len > 0;
        const len_before = out.items.len;
        if (self.line_buf.items.len > 0) {
            try self.handleLine(alloc, self.line_buf.items, false, out, completions);
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
            self.code_fence_marker = null;
        }
        try self.flushFootnotes(alloc, out);
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
            if (self.code_fence_marker) |marker| {
                if (bp.codeFenceMarker(tu.leftTrim(line)) == marker) {
                    try self.finalizeCodeBlock(alloc, out, completions.code);
                    self.in_code_block = false;
                    self.code_fence_marker = null;
                    return;
                }
            } else if (!tu.isBlankMarkdownLine(line) and !bp.hasIndentedCodePrefix(line)) {
                try self.finalizeCodeBlock(alloc, out, completions.code);
                self.in_code_block = false;
                try self.handleLine(alloc, line, line_has_lf, out, completions);
                return;
            }
            const code_line = if (self.code_fence_marker == null and !tu.isBlankMarkdownLine(line))
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
                }
                return;
            }
            self.active_footnote = null;
        }

        if (bp.parseFootnoteDefinition(line)) |definition| {
            self.active_definition = false;
            try self.flushPendingTopLevelLine(alloc, out);
            try self.beginFootnoteDefinition(alloc, definition);
            return;
        }

        if (completions.thematic_rule != null and self.pending_top_level_line.items.len > 0) {
            if (bp.parseSetextUnderline(line)) |level| {
                self.active_definition = false;
                try block_render.writeHeading(alloc, level, tu.withoutTerminalHardBreakMarker(self.pending_top_level_line.items, true), out, &fs, &link_id_counter);
                try out.append(alloc, '\n');
                self.pending_top_level_line.clearRetainingCapacity();
                return;
            }
            if (bp.definitionMarkerBody(line)) |body| {
                try self.flushPendingTopLevelLine(alloc, out);
                try block_render.writeDefinitionLine(alloc, body, line_has_lf, out, &fs, &link_id_counter);
                self.active_definition = true;
                return;
            }
            self.active_definition = false;
            try self.flushPendingTopLevelLine(alloc, out);
        }

        if (self.active_blockquote) |blockquote| {
            self.active_definition = false;
            if (bp.isLazyBlockquoteContinuation(line)) {
                try block_render.writeBlockquoteLine(alloc, blockquote, line, line_has_lf, out, &fs, &link_id_counter);
                try out.append(alloc, '\n');
                return;
            }
            self.active_blockquote = null;
        }

        if (bp.hasIndentedCodePrefix(line) and (bp.parseUnorderedList(line) != null or bp.parseOrderedList(line) != null)) {
            self.active_definition = false;
            try self.processLine(alloc, line, line_has_lf, out);
            try out.append(alloc, '\n');
            return;
        }

        if (self.previous_line_was_blank and bp.hasIndentedCodePrefix(line)) {
            self.active_definition = false;
            self.in_code_block = true;
            self.code_fence_marker = null;
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

        if (bp.codeFenceMarker(tu.leftTrim(line))) |marker| {
            self.active_definition = false;
            self.in_code_block = true;
            self.code_fence_marker = marker;
            self.code_language.clearRetainingCapacity();
            try self.code_language.appendSlice(alloc, bp.codeFenceLanguage(tu.leftTrim(line)));
            return;
        }

        if (self.active_definition) {
            if (bp.definitionMarkerBody(line)) |body| {
                try block_render.writeDefinitionLine(alloc, body, line_has_lf, out, &fs, &link_id_counter);
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

        if (bp.isHorizontalRule(line)) {
            try ansi.writeHorizontalRule(alloc, out);
            return;
        }

        if (bp.parseHeader(line)) |header| {
            try block_render.writeHeading(alloc, header.level, tu.withoutTerminalHardBreakMarker(header.content, line_has_lf), out, &fs, &link_id_counter);
            return;
        }

        if (bp.parseBlockquote(line)) |parsed| {
            const blockquote = bp.BlockquotePrefix{
                .indent = parsed.indent.len,
                .depth = parsed.depth,
            };
            self.active_blockquote = if (bp.isBlockquoteParagraph(parsed.content)) blockquote else null;
            try block_render.writeBlockquoteLine(alloc, blockquote, parsed.content, line_has_lf, out, &fs, &link_id_counter);
            return;
        }

        if (bp.parseUnorderedList(line)) |parsed| {
            try out.appendSlice(alloc, parsed.indent);
            if (bp.parseTaskListItem(parsed.content)) |task| {
                try block_render.writeTaskListMarker(alloc, out, task);
                try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(task.content, line_has_lf), out, false, &fs, &link_id_counter);
                return;
            }
            try ansi.writeDim(alloc, out, ansi.bullet_marker);
            try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(parsed.content, line_has_lf), out, false, &fs, &link_id_counter);
            return;
        }

        if (bp.parseOrderedList(line)) |parsed| {
            try out.appendSlice(alloc, parsed.indent);
            try ansi.writeDim(alloc, out, parsed.marker);
            try out.append(alloc, ' ');
            if (bp.parseTaskListItem(parsed.content)) |task| {
                try block_render.writeTaskListMarker(alloc, out, task);
                try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(task.content, line_has_lf), out, false, &fs, &link_id_counter);
                return;
            }
            try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(parsed.content, line_has_lf), out, false, &fs, &link_id_counter);
            return;
        }

        try inline_render.writeInline(alloc, tu.withoutTerminalHardBreakMarker(line, line_has_lf), out, false, &fs, &link_id_counter);
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
                var table = try block_render.parseTablePayloadWithFootnotes(alloc, self.pipe_buf.items, &fs, &link_id_counter);
                var delivered = false;
                errdefer if (!delivered) table.deinit(alloc);
                try sink.deliver(sink.ctx, table, out);
                delivered = true;
                return;
            }
            try block_render.renderTable(alloc, self.pipe_buf.items, out, &fs, &link_id_counter);
            return;
        }

        var start: usize = 0;
        while (start < self.pipe_buf.items.len) {
            const end = std.mem.indexOfScalarPos(u8, self.pipe_buf.items, start, '\n') orelse self.pipe_buf.items.len;
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
            for (self.footnotes.items) |*note| {
                if (note.number != number or !note.has_definition) continue;
                try block_render.writeFootnoteDefinitionMarker(alloc, out, number);
                try block_render.writeFootnoteBody(alloc, note.body.items, out, &fs, number, &link_id_counter);
                break;
            }
        }
    }
};

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
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "see \x1b]8;id=fx-{d};https://example.com\x1b\\\x1b[4mdocs\x1b[24m\x1b]8;;\x1b\\ please\n",
        .{id_before},
    );
    try std.testing.expectEqualStrings(expected, out.items);
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
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "see \x1b]8;id=fx-{d};https://example.com/diagram.png\x1b\\\x1b[4m▧ architecture diagram\x1b[24m\x1b]8;;\x1b\\ please\n",
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
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\x1b]8;id=fx-{d};https://example.com/diagram.png\x1b\\\x1b[4m▧ image\x1b[24m\x1b]8;;\x1b\\\n",
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
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\x1b]8;id=fx-{d};https://example.com/diagram.png\x1b\\\x1b[4m▧ architecture *diagram*\x1b[24m\x1b]8;;\x1b\\\n",
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
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b]8;") == null);

    out.clearRetainingCapacity();
    try processor.push(alloc, "![alt](https://example.com/diagram.png\n", &out);
    try std.testing.expectEqualStrings("![alt](https://example.com/diagram.png\n", out.items);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b]8;") == null);

    out.clearRetainingCapacity();
    try processor.push(alloc, "![alt](https://example.com/\x1bdiagram.png)\n", &out);
    try std.testing.expectEqualStrings("![alt](https://example.com/\x1bdiagram.png)\n", out.items);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b]8;") == null);

    var oversized_url: [max_link_url_bytes + 1]u8 = undefined;
    @memset(&oversized_url, 'a');
    var input_buf: [max_link_url_bytes + 16]u8 = undefined;
    const oversized = try std.fmt.bufPrint(&input_buf, "![alt]({s})\n", .{oversized_url[0..]});
    out.clearRetainingCapacity();
    try processor.push(alloc, oversized, &out);
    try std.testing.expectEqualStrings(oversized, out.items);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b]8;") == null);
}

test "markdown images preserve code isolation, chunk buffering, and heading underline" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "`![literal](https://example.com/literal.png)`\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[38;5;245m![literal](https://example.com/literal.png)\x1b[39m\n",
        out.items,
    );
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b]8;") == null);

    out.clearRetainingCapacity();
    try processor.push(alloc, "![architecture", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try processor.push(alloc, "](https://example.com/diagram.png)\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "▧ architecture") != null);

    out.clearRetainingCapacity();
    const id_before = link_id_counter;
    try processor.push(alloc, "### before ![diagram](https://example.com/diagram.png) after\n", &out);
    var expected_buf: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\x1b[4mbefore \x1b]8;id=fx-{d};https://example.com/diagram.png\x1b\\\x1b[4m▧ diagram\x1b[24m\x1b]8;;\x1b\\\x1b[4m after\x1b[24m\n",
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
    try std.testing.expect(std.mem.indexOf(u8, cell, "▧ diagram") != null);
    try std.testing.expect(std.mem.indexOf(u8, cell, "![diagram]") == null);
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
    const first_id = try std.fmt.bufPrint(&first_id_buf, "\x1b]8;id=fx-{d};https://first.example", .{id_before});
    try std.testing.expect(std.mem.indexOf(u8, first.rows[1].cells[0], first_id) != null);

    var second_id_buf: [64]u8 = undefined;
    const second_id = try std.fmt.bufPrint(&second_id_buf, "\x1b]8;id=fx-{d};https://second.example", .{id_before +% 1});
    try std.testing.expect(std.mem.indexOf(u8, second.rows[1].cells[0], second_id) != null);
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
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "visit \x1b]8;id=fx-{d};https://example.com/docs\x1b\\\x1b[4mhttps://example.com/docs\x1b[24m\x1b]8;;\x1b\\, now\n",
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
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "visit \x1b]8;id=fx-{d};https://example.com/docs\x1b\\\x1b[4mhttps://example.com/docs\x1b[24m\x1b]8;;\x1b\\\n",
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
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "see \x1b]8;id=fx-{d};https://example.com/docs\\_literal\x1b\\\x1b[4mhttps://example.com/docs\\_literal\x1b[24m\x1b]8;;\x1b\\ and " ++
            "\x1b]8;id=fx-{d};mailto:dev@example.com\x1b\\\x1b[4mdev@example.com\x1b[24m\x1b]8;;\x1b\\ plus " ++
            "\x1b]8;id=fx-{d};git+ssh://example.com/repo\x1b\\\x1b[4mgit+ssh://example.com/repo\x1b[24m\x1b]8;;\x1b\\\n",
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
        "\x1b[38;5;245m<https://code.example>\x1b[39m\n";

    try processor.push(alloc, input, &out);
    try std.testing.expectEqualStrings(expected, out.items);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b]8;") == null);
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
    const input = try std.fmt.bufPrint(&input_buf, "<{s}{s}>\n", .{ local[0..local_len], suffix });

    try processor.push(alloc, input, &out);
    try std.testing.expectEqualStrings(input, out.items);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b]8;") == null);
}

test "bare URL remains literal in code and excluded boundaries" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(
        alloc,
        "`https://code.example` wordhttps://word.example <<https://angle.example>>\n",
        &out,
    );
    try std.testing.expectEqualStrings(
        "\x1b[38;5;245mhttps://code.example\x1b[39m wordhttps://word.example <<https://angle.example>>\n",
        out.items,
    );
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
    const input = try std.fmt.bufPrint(&input_buf, "https://{s}\n", .{oversized[0..]});

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
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\x1b[1m\x1b]8;id=fx-{d};https://bold.example\x1b\\\x1b[4mhttps://bold.example\x1b[24m\x1b]8;;\x1b\\\x1b[22m " ++
            "\x1b[3m\x1b]8;id=fx-{d};https://italic.example\x1b\\\x1b[4mhttps://italic.example\x1b[24m\x1b]8;;\x1b\\\x1b[23m " ++
            "\x1b[9m\x1b]8;id=fx-{d};https://strike.example\x1b\\\x1b[4mhttps://strike.example\x1b[24m\x1b]8;;\x1b\\\x1b[29m tail\n",
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
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\x1b[4mbefore \x1b]8;id=fx-{d};https://example.com\x1b\\\x1b[4mlink\x1b[24m\x1b]8;;\x1b\\\x1b[4m after\x1b[24m\nbody\n",
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
    const first_marker = try std.fmt.bufPrint(&seq_buf, "id=fx-", .{});
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
    const input = try std.fmt.bufPrint(&input_buf, "see [x]({s}) end\n", .{url});

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
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b") == null);
}

test "backslash escapes survive heading preprocessing and code spans" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "## \\*\\*literal bold\\*\\* and `\\*code\\*`\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[1m**literal bold** and \x1b[38;5;245m\\*code\\*\x1b[39m\x1b[22m\n",
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
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\x1b]8;id=fx-{d};https://example.com\x1b\\\x1b[4mdocs *literal*\x1b[24m\x1b]8;;\x1b\\\n",
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
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[3mrow\x1b[23m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1mcell\x1b[22m") != null);
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
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\x1b[3m\x1b]8;id=fx-{d};https://example.com/snake_case\x1b\\\x1b[4mhttps://example.com/snake_case\x1b[24m\x1b]8;;\x1b\\\x1b[23m tail " ++
            "\x1b[1m\x1b]8;id=fx-{d};https://example.com/snake_case\x1b\\\x1b[4mhttps://example.com/snake_case\x1b[24m\x1b]8;;\x1b\\\x1b[22m tail\n",
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
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b]8;") == null);
    }

    const wrong_closer_cases = [_]struct {
        input: []const u8,
        url: []const u8,
        tail: []const u8,
    }{
        .{ .input = "_https://example.com/path__ tail\n", .url = "https://example.com/path__", .tail = " tail\x1b[23m\n" },
        .{ .input = "__https://example.com/path_ tail\n", .url = "https://example.com/path_", .tail = " tail\x1b[22m\n" },
    };

    for (wrong_closer_cases) |case| {
        var processor = MarkdownProcessor{};
        defer processor.deinit(alloc);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);

        try processor.push(alloc, case.input, &out);
        try std.testing.expect(std.mem.indexOf(u8, out.items, case.url) != null);
        try std.testing.expect(std.mem.endsWith(u8, out.items, case.tail));
    }
}

test "underscore emphasis preserves code literals and closes unpaired spans" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "_unclosed\n__unclosed\n`_literal_ __literal__`\n", &out);
    try std.testing.expectEqualStrings(
        "\x1b[3munclosed\x1b[23m\n" ++
            "\x1b[1munclosed\x1b[22m\n" ++
            "\x1b[38;5;245m_literal_ __literal__\x1b[39m\n",
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
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.items,
        "\x1b[1mprefix \x1b[1mstrong\x1b[22m\x1b[1m suffix\x1b[22m",
    ) != null);
}

test "inline code backticks wrap with ANSI" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "run `zig build` now\n", &out);
    try std.testing.expectEqualStrings("run \x1b[38;5;245mzig build\x1b[39m now\n", out.items);
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
    try std.testing.expectEqualStrings("run \x1b[38;5;247mzig build\x1b[39m now\n", out.items);
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
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1;4m") == null);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2m  \x1b[22maccepted\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\n: stale\n") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2m  \x1b[22maccepted\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\n: stale\n") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "Status\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\n: stale\n") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "Status\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\n: stale\n") != null);
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
        std.testing.allocator,
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
        std.testing.allocator,
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "[^state]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2m[1] \x1b[22m") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "[1]") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "[^escaped]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "[^code]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "[^missing]:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "[^block]: literal code") != null);
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
        std.testing.allocator,
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

test "ordered list keeps number marker" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "1. step one\n", &out);
    try std.testing.expectEqualStrings("\x1b[2m1.\x1b[22m step one\n", out.items);
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
        "\x1b[2m1.\x1b[22m \x1b[2m\xe2\x98\x90 \x1b[22mfirst\n" ++
            "\x1b[2m2.\x1b[22m \x1b[38;5;252m\xe2\x9c\x93\x1b[39m done\n",
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
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\n\x1b[2m\xe2\x94\x82 \x1b[22mlazy ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b]8;id=fx-") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "https://example.com/lazy") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out.items, "    continuation") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "   three spaces") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2m\xe2\x94\x82 \x1b[22m    lazy continuation") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2m\xe2\x94\x82 \x1b[22m- list item") == null);
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
    const alloc = std.testing.allocator;
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

test "line intake buffers partial lines and preserves standalone carriage returns" {
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
    try std.testing.expectEqualStrings("run \x1b[38;5;245mzig build\x1b[39m now\n", out.items);

    out.clearRetainingCapacity();
    try processor.push(alloc, "left\rright\n", &out);
    try std.testing.expectEqualStrings("left\rright\n", out.items);
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

test "flush closes open styles" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "oops **never closed", &out);
    try processor.flush(alloc, &out);
    try std.testing.expectEqualStrings("oops \x1b[1mnever closed\x1b[22m", out.items);
}

test "flush closes an unpaired inline code span" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "run `zig build", &out);
    try processor.flush(alloc, &out);
    try std.testing.expectEqualStrings("run \x1b[38;5;245mzig build\x1b[39m", out.items);
}

test "header with inline markdown" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "## Using `fx` in CI\n", &out);
    try std.testing.expectEqualStrings("\x1b[1mUsing \x1b[38;5;245mfx\x1b[39m in CI\x1b[22m\n", out.items);
}

test "inline code ignores bold markers inside" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "use `**literal**` here\n", &out);
    try std.testing.expectEqualStrings("use \x1b[38;5;245m**literal**\x1b[39m here\n", out.items);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\xe2\x94\xbc") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out.items, expected_separator) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "1 \xe2\x94\x82 22 \xe2\x94\x82 333\n") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\xe2\x94\x82") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\xe2\x94\xbc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1mName\x1b[22m") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\xe2\x94\x82") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\xe2\x94\xbc") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\xe2\x94\x82") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Use cmd | grep foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Then review the output.") != null);
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
        "\x1b[1m\x1b[4m\x1b[3mnote\x1b[23m about \x1b[38;5;245mfx\x1b[39m\x1b[24m\x1b[22m\n",
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
    try std.testing.expect(std.mem.indexOf(u8, out.items, table_horiz) != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "*") == null);
}

test "hyphen-space line is a list, not a rule" {
    const alloc = std.testing.allocator;
    var processor = MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try processor.push(alloc, "- item\n", &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\xe2\x80\xa2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\xe2\x94\x80") == null);
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
    try std.testing.expectEqualStrings("    \x1b[2m1.\x1b[22m sub-step\n", out.items);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "    5\n") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, " ok \n") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, out.items, "| not | a |") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "| table | really |") != null);
}
