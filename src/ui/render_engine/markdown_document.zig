//! Renders one complete Markdown text the way the transcript renders an
//! assistant reply: the same inline styles, lists, tables, code panels, and
//! rules, wrapped to a width. Surfaces outside the transcript, such as the
//! question prompt, use it so Markdown looks the same wherever it shows.

const std = @import("std");
const assistant_presentation = @import("../../core/agent/assistant_presentation.zig");
const display_width = @import("../../core/shared/display_width.zig");
const assistant_wrap = @import("assistant_wrap.zig");
const transcript_blocks = @import("transcript_blocks.zig");

const Allocator = std.mem.Allocator;
const TranscriptEntry = transcript_blocks.TranscriptEntry;

/// Collects what the Markdown processor emits as the entries the transcript
/// would hold for the same reply.
const Collector = struct {
    alloc: Allocator,
    entries: std.ArrayList(TranscriptEntry) = .empty,

    fn deinit(self: *Collector) void {
        for (self.entries.items) |*entry| entry.deinit(self.alloc);
        self.entries.deinit(self.alloc);
    }

    fn nextId(self: *const Collector) u32 {
        return @intCast(self.entries.items.len + 1);
    }

    /// Moves the text rendered so far into the reply's current text entry,
    /// or starts one after a table, code block, or rule.
    fn flushText(self: *Collector, out: *std.ArrayList(u8)) !void {
        if (out.items.len == 0) return;
        if (self.entries.items.len > 0) {
            switch (self.entries.items[self.entries.items.len - 1]) {
                .assistant_turn => |*turn| {
                    try turn.segments.text.appendSlice(self.alloc, out.items);
                    out.clearRetainingCapacity();
                    return;
                },
                else => {},
            }
        }
        try self.entries.ensureUnusedCapacity(self.alloc, 1);
        var segments: transcript_blocks.AssistantTurnSegments = .{};
        errdefer segments.deinit(self.alloc);
        try segments.text.appendSlice(self.alloc, out.items);
        self.entries.appendAssumeCapacity(.{ .assistant_turn = .{ .id = self.nextId(), .segments = segments } });
        out.clearRetainingCapacity();
    }

    // Each deliver function owns its payload only when it returns without an
    // error, which is the processor's contract.
    fn deliverTable(
        raw: *anyopaque,
        table: assistant_presentation.TablePayload,
        out: *std.ArrayList(u8),
    ) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(raw));
        try self.flushText(out);
        try self.entries.append(self.alloc, .{ .assistant_table = .{ .id = self.nextId(), .table = table } });
    }

    fn deliverCodeBlock(
        raw: *anyopaque,
        block: assistant_presentation.CodeBlockPayload,
        out: *std.ArrayList(u8),
    ) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(raw));
        try self.flushText(out);
        try self.entries.append(self.alloc, .{ .assistant_code_block = .{ .id = self.nextId(), .block = block } });
    }

    fn deliverThematicRule(raw: *anyopaque, out: *std.ArrayList(u8)) anyerror!void {
        const self: *Collector = @ptrCast(@alignCast(raw));
        try self.flushText(out);
        try self.entries.append(self.alloc, .{ .assistant_thematic_rule = .{ .id = self.nextId() } });
    }
};

/// Renders `markdown` as rows no wider than `cols`, joined by line breaks,
/// with no blank row before the first or after the last. Text rows start
/// after the transcript's gutter (`gutterWidth`), and each row closes the
/// styles and links it opens, so a caller can show any subset of the rows.
/// The caller owns the returned slice.
pub fn renderRows(
    alloc: Allocator,
    markdown: []const u8,
    cols: u16,
    styles: transcript_blocks.Styles,
) ![]u8 {
    var collector = Collector{ .alloc = alloc };
    defer collector.deinit();

    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var table_completion = assistant_presentation.TableCompletion{
        .ctx = &collector,
        .deliver = Collector.deliverTable,
    };
    var code_completion = assistant_presentation.CodeBlockCompletion{
        .ctx = &collector,
        .deliver = Collector.deliverCodeBlock,
    };
    var thematic_rule_completion = assistant_presentation.ThematicRuleCompletion{
        .ctx = &collector,
        .deliver = Collector.deliverThematicRule,
    };
    const completions = assistant_presentation.MarkdownCompletions{
        .table = &table_completion,
        .code = &code_completion,
        .thematic_rule = &thematic_rule_completion,
    };
    try processor.pushWithCompletions(alloc, markdown, &out, completions);
    try processor.flushWithCompletions(alloc, &out, completions);
    try collector.flushText(&out);

    const rendered = try transcript_blocks.renderEntriesToBytes(alloc, collector.entries.items, cols, styles);
    defer alloc.free(rendered);
    return alloc.dupe(u8, trimBlankEdgeRows(rendered));
}

/// How far text rows are indented in `renderRows` output of this width.
pub fn gutterWidth(cols: u16) u16 {
    return assistant_wrap.gutterWidth(cols);
}

/// `rendered` without the blank rows at its start and end.
fn trimBlankEdgeRows(rendered: []const u8) []const u8 {
    var start: usize = 0;
    while (start < rendered.len) {
        const line_end = std.mem.findScalarPos(u8, rendered, start, '\n') orelse rendered.len;
        if (!isBlankRow(rendered[start..line_end])) break;
        start = @min(line_end + 1, rendered.len);
    }
    var end = rendered.len;
    while (end > start) {
        const line_start = if (std.mem.findScalarLast(u8, rendered[start..end], '\n')) |newline| start + newline + 1 else start;
        if (!isBlankRow(rendered[line_start..end])) break;
        end = if (line_start > start) line_start - 1 else start;
    }
    return rendered[start..end];
}

/// True when `row` draws nothing: only spaces and escape sequences.
pub fn isBlankRow(row: []const u8) bool {
    var index: usize = 0;
    while (index < row.len) {
        if (row[index] == 0x1b) {
            index = display_width.ansiSequenceEnd(row, index);
        } else if (row[index] == ' ') {
            index += 1;
        } else return false;
    }
    return true;
}

fn expectRowsFit(rows: []const u8, cols: u16) !usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, rows, '\n');
    while (lines.next()) |line| : (count += 1) {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(line) <= cols);
    }
    return count;
}

test "markdown document renders blocks as the transcript does and fits every width" {
    const alloc = std.testing.allocator;
    const source =
        "The migration can run in **two** ways:\n" ++
        "\n" ++
        "- `online`: no downtime, about two hours of slow writes for every tenant\n" ++
        "- `offline`: ten minutes of downtime\n" ++
        "\n" ++
        "```sh\n" ++
        "fx migrate --mode online\n" ++
        "```\n" ++
        "\n" ++
        "| Mode | Downtime |\n" ++
        "|---|---|\n" ++
        "| online | none |\n" ++
        "\n" ++
        "---\n" ++
        "\n" ++
        "Which one do you want?";

    for ([_]u16{ 1, 2, 3, 8, 24, 60, 120 }) |cols| {
        const rows = try renderRows(alloc, source, cols, .{});
        defer alloc.free(rows);
        _ = try expectRowsFit(rows, cols);
        try std.testing.expect(rows.len > 0);
        try std.testing.expect(rows[0] != '\n' and rows[rows.len - 1] != '\n');
    }

    const rows = try renderRows(alloc, source, 60, .{});
    defer alloc.free(rows);
    try std.testing.expect(std.mem.startsWith(u8, rows, "  The migration can run in \x1b[1mtwo\x1b[22m ways:\n\n"));
    inline for (.{ "• ", "online", "every tenant", "fx", "migrate", "Downtime", "┌", "──────" }) |shown| {
        try std.testing.expect(std.mem.find(u8, rows, shown) != null);
    }
    // No Markdown syntax is left as text.
    inline for (.{ "**", "`", "|---|", "\n- ", "\n---" }) |syntax| {
        try std.testing.expect(std.mem.find(u8, rows, syntax) == null);
    }
    try std.testing.expect(std.mem.endsWith(u8, rows, "  Which one do you want?"));
}

test "markdown document shows control bytes as text and trims blank edge rows" {
    const alloc = std.testing.allocator;
    const rows = try renderRows(alloc, "\n\nClear \x1b[2J the screen?\n\n", 60, .{});
    defer alloc.free(rows);
    try std.testing.expectEqualStrings("  Clear \\x1b[2J the screen?", rows);

    const empty = try renderRows(alloc, " \n", 60, .{});
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "markdown document rows each close the styles and links they open" {
    const alloc = std.testing.allocator;
    const rows = try renderRows(
        alloc,
        "**A long bold sentence that must wrap onto a second row** and [a link label that also wraps](https://example.com/a)",
        24,
        .{},
    );
    defer alloc.free(rows);
    try std.testing.expect(try expectRowsFit(rows, 24) > 2);

    var lines = std.mem.splitScalar(u8, rows, '\n');
    while (lines.next()) |line| {
        var bold = false;
        var link = false;
        var index: usize = 0;
        while (index < line.len) {
            if (line[index] != 0x1b) {
                index += 1;
                continue;
            }
            const end = display_width.ansiSequenceEnd(line, index);
            const sequence = line[index..end];
            if (std.mem.eql(u8, sequence, "\x1b[1m")) bold = true;
            if (std.mem.eql(u8, sequence, "\x1b[22m") or std.mem.eql(u8, sequence, "\x1b[0m")) bold = false;
            if (std.mem.startsWith(u8, sequence, "\x1b]8;")) link = !std.mem.startsWith(u8, sequence, "\x1b]8;;");
            index = end;
        }
        try std.testing.expect(!bold);
        try std.testing.expect(!link);
    }
}

test "markdown document frees its entries on allocation failure" {
    const testing_allocator = @import("../../core/shared/testing_allocator.zig");
    const Check = struct {
        fn run(alloc: Allocator) !void {
            const rows = try renderRows(
                alloc,
                "Intro\n\n```zig\nconst x = 1;\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n---\n\nEnd",
                40,
                .{},
            );
            alloc.free(rows);
        }
    };
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, Check.run, .{});
}
