//! Grid-level tests for assistant Markdown tables: a table that streams in
//! row by row, and a finished table through resize. They replay
//! `TranscriptRuntime` output through the shared terminal engine, as
//! `resize_tests.zig` does.

const std = @import("std");
const assistant_presentation = @import("../core/agent/assistant_presentation.zig");
const display_width = @import("../core/shared/display_width.zig");
const resize_tests = @import("resize_tests.zig");

const Allocator = std.mem.Allocator;
const Harness = resize_tests.Harness;

const fixture_table =
    "| Feature | Status | Owner | Notes |\n" ++
    "|:--------|:------:|------:|-------|\n" ++
    "| Tables | done | ui | Alignment and `inline code` in cells |\n" ++
    "| CJK 表格 | 進行中 | 東京 | 全角文字の幅を正しく測る |\n" ++
    "| Emoji ✅ | ok 🚀 | 🦀 | Wide glyphs must not break borders |\n" ++
    "| Long | wip | core | This cell is deliberately long so that the table is wider than a narrow terminal and has to wrap its cells onto several lines |\n";

/// Routes processor output into the harness the way the native app does:
/// rendered text streams, and every table, finished or still streaming, is
/// appended as a semantic entry.
const Sink = struct {
    h: *Harness,
    previews: usize = 0,
    finals: usize = 0,

    fn deliver(raw: *anyopaque, table: assistant_presentation.TablePayload, out: *std.ArrayList(u8)) anyerror!void {
        const self: *Sink = @ptrCast(@alignCast(raw));
        if (out.items.len > 0) {
            _ = try self.h.shell.streamAssistantChunk(self.h.alloc, &self.h.metrics, out.items);
            out.clearRetainingCapacity();
        }
        if (table.partial) self.previews += 1 else self.finals += 1;
        _ = try self.h.shell.appendAssistantTableOwned(self.h.alloc, table);
    }
};

fn streamLines(
    h: *Harness,
    sink: *Sink,
    processor: *assistant_presentation.MarkdownProcessor,
    text: []const u8,
    after_line: ?*const fn (*Harness, usize) anyerror!void,
    finish: bool,
) !void {
    const completion = assistant_presentation.TableCompletion{ .ctx = sink, .deliver = Sink.deliver };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(h.alloc);
    var start: usize = 0;
    var line_index: usize = 0;
    while (start < text.len) : (line_index += 1) {
        const end = (std.mem.findScalarPos(u8, text, start, '\n') orelse text.len - 1) + 1;
        try processor.pushWithCompletions(h.alloc, text[start..end], &out, .{ .table = &completion, .table_preview = &completion });
        if (out.items.len > 0) {
            _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, out.items);
            out.clearRetainingCapacity();
        }
        try h.renderTranscriptFrame();
        try h.flush();
        if (after_line) |callback| try callback(h, line_index);
        start = end;
    }
    if (!finish) return;
    try processor.flushWithCompletions(h.alloc, &out, .{ .table = &completion, .table_preview = &completion });
    if (out.items.len > 0) _ = try h.shell.streamAssistantChunk(h.alloc, &h.metrics, out.items);
    try h.renderTranscriptFrame();
    try h.flush();
}

fn rowText(h: *Harness, row: u16, buf: *std.ArrayList(u8)) ![]const u8 {
    buf.clearRetainingCapacity();
    try h.vt.rowTextTrimmed(row, buf);
    return buf.items;
}

fn countRowsContaining(h: *Harness, needle: []const u8) !usize {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    var count: usize = 0;
    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        if (std.mem.find(u8, try rowText(h, row, &buf), needle) != null) count += 1;
    }
    return count;
}

fn firstRowContaining(h: *Harness, needle: []const u8) !?u16 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        if (std.mem.find(u8, try rowText(h, row, &buf), needle) != null) return row;
    }
    return null;
}

/// Every grid row of the table has the top border's width, starts at the
/// gutter, and fits the terminal, so wide runes never push a border out.
fn expectAlignedTable(h: *Harness) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    const top = (try firstRowContaining(h, "┌")) orelse return error.TestExpectedTable;
    const top_width = display_width.visibleWidthIgnoringAnsi(try rowText(h, top, &buf));
    try std.testing.expect(top_width <= h.vt.cols);
    var row = top;
    while (row <= h.vt.rows) : (row += 1) {
        const text = try rowText(h, row, &buf);
        const trimmed = std.mem.trimStart(u8, text, " ");
        const is_table_row = std.mem.startsWith(u8, trimmed, "│") or std.mem.startsWith(u8, trimmed, "├") or
            std.mem.startsWith(u8, trimmed, "┌") or std.mem.startsWith(u8, trimmed, "└");
        if (!is_table_row) break;
        try std.testing.expectEqual(top_width, display_width.visibleWidthIgnoringAnsi(text));
        if (std.mem.startsWith(u8, trimmed, "└")) return;
    }
    return error.TestExpectedClosedTable;
}

var header_row: ?u16 = null;

fn checkStreamingTable(h: *Harness, line_index: usize) anyerror!void {
    // The header and delimiter alone already show an open grid.
    if (line_index < 1) {
        try std.testing.expectEqual(@as(usize, 0), try countRowsContaining(h, "┌"));
        return;
    }
    try std.testing.expectEqual(@as(usize, 1), try countRowsContaining(h, "┌"));
    try std.testing.expectEqual(@as(usize, 0), try countRowsContaining(h, "└"));
    const row = (try firstRowContaining(h, "Feature")) orelse return error.TestExpectedHeader;
    if (header_row) |previous| try std.testing.expectEqual(previous, row);
    header_row = row;
}

test "a streaming table appears row by row and closes in place" {
    var h = try Harness.init(std.testing.allocator, 60, 60, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);
    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(h.alloc);
    var sink: Sink = .{ .h = &h };

    header_row = null;
    try streamLines(&h, &sink, &processor, "Comparison:\n\n" ++ fixture_table ++ "\nAfter the table.\n", struct {
        fn check(harness: *Harness, line_index: usize) anyerror!void {
            // Lines 0 and 1 are the lead-in and the blank line before the table.
            if (line_index < 2 or line_index > 7) return;
            try checkStreamingTable(harness, line_index - 2);
        }
    }.check, true);

    try std.testing.expectEqual(@as(usize, 1), sink.finals);
    try std.testing.expectEqual(@as(usize, 5), sink.previews);
    try std.testing.expectEqual(@as(usize, 1), try countRowsContaining(&h, "┌"));
    try std.testing.expectEqual(@as(usize, 1), try countRowsContaining(&h, "└"));
    try std.testing.expectEqual(header_row.?, (try firstRowContaining(&h, "Feature")).?);
    try std.testing.expect((try firstRowContaining(&h, "After the table.")).? > (try firstRowContaining(&h, "└")).?);
    try expectAlignedTable(&h);
}

test "a finished table keeps its borders aligned through shrink and grow" {
    var h = try Harness.init(std.testing.allocator, 60, 80, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);
    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(h.alloc);
    var sink: Sink = .{ .h = &h };

    try streamLines(&h, &sink, &processor, fixture_table, null, true);
    try expectAlignedTable(&h);

    for ([_]u16{ 40, 30, 100, 120, 60 }) |cols| {
        try h.driveResize(cols, 80, 4, true);
        try std.testing.expectEqual(@as(usize, 1), try countRowsContaining(&h, "┌"));
        try std.testing.expectEqual(@as(usize, 1), try countRowsContaining(&h, "└"));
        try expectAlignedTable(&h);
    }
}

test "a table mid-stream reflows on resize and still closes once" {
    var h = try Harness.init(std.testing.allocator, 80, 60, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);
    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(h.alloc);
    var sink: Sink = .{ .h = &h };

    const split = std.mem.find(u8, fixture_table, "| Emoji").?;
    try streamLines(&h, &sink, &processor, fixture_table[0..split], null, false);
    try std.testing.expectEqual(@as(usize, 0), try countRowsContaining(&h, "└"));
    try h.driveResize(44, 60, 4, true);
    try std.testing.expectEqual(@as(usize, 1), try countRowsContaining(&h, "┌"));
    try std.testing.expectEqual(@as(usize, 0), try countRowsContaining(&h, "└"));

    try streamLines(&h, &sink, &processor, fixture_table[split..], null, true);
    try std.testing.expectEqual(@as(usize, 1), try countRowsContaining(&h, "┌"));
    try std.testing.expectEqual(@as(usize, 1), try countRowsContaining(&h, "└"));
    try expectAlignedTable(&h);
}

test "a streaming table previews only ended rows after its delimiter" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        rows: std.ArrayList(usize) = .empty,
        partial: std.ArrayList(bool) = .empty,

        fn deliver(raw: *anyopaque, table: assistant_presentation.TablePayload, _: *std.ArrayList(u8)) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            var owned = table;
            defer owned.deinit(std.testing.allocator);
            try self.rows.append(std.testing.allocator, table.rows.len);
            try self.partial.append(std.testing.allocator, table.partial);
        }
    };
    var capture: Capture = .{};
    defer capture.rows.deinit(alloc);
    defer capture.partial.deinit(alloc);
    const completion = assistant_presentation.TableCompletion{ .ctx = &capture, .deliver = Capture.deliver };
    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // A row still streaming is not shown until its line ends.
    for ([_][]const u8{ "| a | b |\n", "|---|---|\n", "| 1 | 2 |\n", "| 3 |", " 4 |\n" }) |chunk| {
        try processor.pushWithCompletions(alloc, chunk, &out, .{ .table = &completion, .table_preview = &completion });
    }
    try processor.flushWithCompletions(alloc, &out, .{ .table = &completion, .table_preview = &completion });
    try std.testing.expectEqualSlices(usize, &.{ 1, 2, 3, 3 }, capture.rows.items);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, capture.partial.items);

    // Without a preview sink the finished table is the only delivery.
    capture.rows.clearRetainingCapacity();
    capture.partial.clearRetainingCapacity();
    try processor.pushWithCompletions(alloc, "| a |\n|---|\n| 1 |\n", &out, .{ .table = &completion });
    try processor.flushWithCompletions(alloc, &out, .{ .table = &completion });
    try std.testing.expectEqualSlices(usize, &.{2}, capture.rows.items);
    try std.testing.expectEqualSlices(bool, &.{false}, capture.partial.items);
}

fn visibleTableRowWidths(h: *Harness, widths: *std.ArrayList(usize)) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(h.alloc);
    widths.clearRetainingCapacity();
    var row: u16 = 1;
    while (row <= h.vt.rows) : (row += 1) {
        const text = try rowText(h, row, &buf);
        const trimmed = std.mem.trimStart(u8, text, " ");
        if (std.mem.startsWith(u8, trimmed, "│") or std.mem.startsWith(u8, trimmed, "├") or std.mem.startsWith(u8, trimmed, "└")) {
            try widths.append(h.alloc, display_width.visibleWidthIgnoringAnsi(text));
        }
    }
}

test "a streaming table taller than the viewport keeps the widths its scrolled rows show" {
    var h = try Harness.init(std.testing.allocator, 60, 20, 4);
    defer h.deinit();
    try h.shell.initViewport(&h.metrics, 1);
    var processor = assistant_presentation.MarkdownProcessor{};
    defer processor.deinit(h.alloc);
    var sink: Sink = .{ .h = &h };

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(h.alloc);
    try source.appendSlice(h.alloc, "| # | Name |\n|--:|:-----|\n");
    for (1..31) |index| {
        const name = if (index == 28) "a much longer name that would widen the column" else "item";
        const line = try h.alloc.print("| {d} | {s} |\n", .{ index, name });
        defer h.alloc.free(line);
        try source.appendSlice(h.alloc, line);
    }
    const split = std.mem.find(u8, source.items, "| 28 |").?;
    try streamLines(&h, &sink, &processor, source.items[0..split], null, false);
    var before: std.ArrayList(usize) = .empty;
    defer before.deinit(h.alloc);
    try visibleTableRowWidths(&h, &before);
    try std.testing.expect(before.items.len > 0);

    try streamLines(&h, &sink, &processor, source.items[split..], null, true);
    var after: std.ArrayList(usize) = .empty;
    defer after.deinit(h.alloc);
    try visibleTableRowWidths(&h, &after);
    try std.testing.expect(after.items.len > 0);
    for (after.items) |width| try std.testing.expectEqual(before.items[0], width);
    // The late long name wraps inside the kept column instead of widening it.
    try std.testing.expect((try firstRowContaining(&h, "│ that │")) != null);
}

test "a table entry fits the transcript entry size retention budgets assume" {
    const tb = @import("render_engine/transcript_blocks.zig");
    const info = @typeInfo(tb.TranscriptEntry).@"union";
    var user_turn_size: usize = 0;
    var table_size: usize = 0;
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (comptime std.mem.eql(u8, name, "user_turn")) user_turn_size = @sizeOf(field_type);
        if (comptime std.mem.eql(u8, name, "assistant_table")) table_size = @sizeOf(field_type);
    }
    try std.testing.expect(table_size <= user_turn_size);
}
