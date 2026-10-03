//! Paints the live view on the alternate screen: the Ctrl+T picker of
//! children, and one child's screen with a status line under it. Pure: the
//! caller owns the state and writes the bytes.
const std = @import("std");
const engine = @import("../core/terminal/engine.zig");

const sync_begin = "\x1b[?2026h\x1b[?25l";
const sync_end = "\x1b[?2026l";

pub const PickerRow = struct {
    name: []const u8,
    state: []const u8,
};

/// The picker, painted whole. Rows past the screen scroll with `selected`.
/// `notice`, when set, shows beside the title.
pub fn paintPicker(out: *std.Io.Writer, cols: u16, rows: u16, entries: []const PickerRow, selected: usize, notice: ?[]const u8) !void {
    try out.writeAll(sync_begin ++ "\x1b[0m\x1b[H\x1b[2J");
    var title_buf: [128]u8 = undefined;
    const title = if (notice) |text|
        std.fmt.bufPrint(&title_buf, " Subagents \u{00b7} {s}", .{text}) catch " Subagents"
    else
        " Subagents";
    try writeRow(out, 1, cols, "\x1b[1m", title);
    if (entries.len == 0) {
        try writeRow(out, 3, cols, "", "   No subagents are running.");
    } else {
        var name_width: usize = 0;
        for (entries) |entry| name_width = @max(name_width, entry.name.len);
        const visible: usize = if (rows > 4) rows - 4 else 1;
        const first = if (selected >= visible) selected - visible + 1 else 0;
        for (entries[first..@min(entries.len, first + visible)], first..) |entry, index| {
            var buf: [256]u8 = undefined;
            const marker = if (index == selected) " \u{203a} " else "   ";
            const line = std.fmt.bufPrint(&buf, "{s}{s}{s}  {s}", .{
                marker,
                entry.name,
                spaces[0..@min(spaces.len, name_width - entry.name.len)],
                entry.state,
            }) catch &buf;
            const row: u16 = @intCast(3 + index - first);
            try writeRow(out, row, cols, if (index == selected) "\x1b[1m" else "", line);
        }
    }
    if (rows > 2) try writeRow(out, rows, cols, "\x1b[2m", " \u{2191}\u{2193} choose \u{00b7} Enter view \u{00b7} Esc back");
    try out.writeAll(sync_end);
}

/// One child's screen, written as its change from `painted`, or whole when
/// `painted` is null or another size. `status` fills the row under it.
pub fn paintChild(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    painted: ?*const engine.Grid,
    next: *const engine.Grid,
    status: []const u8,
) !void {
    try out.writeAll(sync_begin);
    if (painted) |prev| {
        if (prev.cols == next.cols and prev.rows == next.rows) {
            try prev.diffTo(next.*, out);
        } else {
            try paintWhole(gpa, out, next);
        }
    } else {
        try paintWhole(gpa, out, next);
    }
    try writeRow(out, next.rows + 1, next.cols, "\x1b[7m", status);
    try out.print("\x1b[{d};{d}H", .{ next.cursor_row, next.cursor_col });
    if (next.cursor_visible) try out.writeAll("\x1b[?25h");
    try out.writeAll(sync_end);
}

fn paintWhole(gpa: std.mem.Allocator, out: *std.Io.Writer, next: *const engine.Grid) !void {
    try out.writeAll("\x1b[0m\x1b[H\x1b[2J");
    var blank = try engine.Grid.init(gpa, next.cols, next.rows);
    defer blank.deinit();
    try blank.diffTo(next.*, out);
}

const spaces = " " ** 64;

/// Writes `text` on `row`, cut to `cols` and padded to fill it, in `style`.
fn writeRow(out: *std.Io.Writer, row: u16, cols: u16, style: []const u8, text: []const u8) !void {
    try out.print("\x1b[{d};1H\x1b[0m{s}", .{ row, style });
    var width: usize = 0;
    var view = std.unicode.Utf8View.init(text) catch std.unicode.Utf8View.initUnchecked("");
    var it = view.iterator();
    while (it.nextCodepointSlice()) |glyph| {
        if (width == cols) break;
        try out.writeAll(glyph);
        width += 1;
    }
    while (width < cols) : (width += 1) try out.writeByte(' ');
    try out.writeAll("\x1b[0m");
}

const testing = std.testing;

fn rowOf(grid: *const engine.Grid, row: u16) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(testing.allocator);
    try grid.rowTextTrimmed(row, &text);
    return text.toOwnedSlice(testing.allocator);
}

test "the picker lists children and marks the chosen one" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try paintPicker(&out.writer, 40, 10, &.{
        .{ .name = "a1", .state = "working" },
        .{ .name = "long-name", .state = "blocked: permission" },
    }, 1, null);
    var grid = try engine.Grid.init(testing.allocator, 40, 10);
    defer grid.deinit();
    var fed = try grid.feedMode(out.written(), .journal_replay);
    defer fed.deinit(testing.allocator);
    const row3 = try rowOf(&grid, 3);
    defer testing.allocator.free(row3);
    const row4 = try rowOf(&grid, 4);
    defer testing.allocator.free(row4);
    try testing.expectEqualStrings("   a1         working", row3);
    try testing.expectEqualStrings(" \u{203a} long-name  blocked: permission", row4);
}

test "a child's screen lands on the real terminal as it is" {
    var child = try engine.Grid.init(testing.allocator, 20, 4);
    defer child.deinit();
    var fed = try child.feedMode("\x1b[1mhello\x1b[0m\r\n\x1b[31mred\x1b[0m world\x1b[3;5H", .native_live);
    defer fed.deinit(testing.allocator);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try paintChild(testing.allocator, &out.writer, null, &child, " a1 \u{00b7} working");
    var screen = try engine.Grid.init(testing.allocator, 20, 5);
    defer screen.deinit();
    var shown = try screen.feedMode(out.written(), .journal_replay);
    defer shown.deinit(testing.allocator);

    var row: u16 = 1;
    while (row <= 4) : (row += 1) {
        var col: u16 = 1;
        while (col <= 20) : (col += 1) {
            try testing.expectEqual(child.cellAt(row, col).?.codepoint, screen.cellAt(row, col).?.codepoint);
            try testing.expect(std.meta.eql(child.cellAt(row, col).?.style, screen.cellAt(row, col).?.style));
        }
    }
    const status = try rowOf(&screen, 5);
    defer testing.allocator.free(status);
    try testing.expectEqualStrings(" a1 \u{00b7} working", status);
    try testing.expectEqual(@as(u16, 3), screen.cursor_row);
    try testing.expectEqual(@as(u16, 5), screen.cursor_col);

    // A later paint writes only what changed.
    var painted = try child.clone(testing.allocator);
    defer painted.deinit();
    var more = try child.feedMode("!", .native_live);
    defer more.deinit(testing.allocator);
    out.clearRetainingCapacity();
    try paintChild(testing.allocator, &out.writer, &painted, &child, " a1 \u{00b7} working");
    try testing.expect(std.mem.indexOf(u8, out.written(), "hello") == null);
    var again = try screen.feedMode(out.written(), .journal_replay);
    defer again.deinit(testing.allocator);
    try testing.expectEqual(@as(u21, '!'), screen.cellAt(3, 5).?.codepoint);
}
