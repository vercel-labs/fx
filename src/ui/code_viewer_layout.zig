const std = @import("std");
const display_width = @import("../core/shared/display_width.zig");
const diff_mod = @import("../core/output/diff.zig");

const Allocator = std.mem.Allocator;

pub const reserved_chrome_rows: u16 = 3;

pub const Regions = struct {
    header_row: u16,
    body_start: u16,
    body_rows: u16,
    status_row: u16,
    hint_row: u16,
};

pub const VisibleWindow = struct {
    first: usize,
    count: usize,
};

pub const Hunk = struct {
    start: usize,
    end: usize,
    first_change: usize,
};

pub const Pair = struct {
    left: ?diff_mod.DiffLine = null,
    right: ?diff_mod.DiffLine = null,
};

pub const SideBySideGeometry = struct {
    old_gutter: u16,
    new_gutter: u16,
    col_width: u16,
    usable: bool,
};

pub fn regions(rows: u16) Regions {
    if (rows == 0) {
        return .{
            .header_row = 0,
            .body_start = 0,
            .body_rows = 0,
            .status_row = 0,
            .hint_row = 0,
        };
    }
    if (rows == 1) {
        return .{
            .header_row = 1,
            .body_start = 0,
            .body_rows = 0,
            .status_row = 0,
            .hint_row = 0,
        };
    }
    if (rows == 2) {
        return .{
            .header_row = 1,
            .body_start = 0,
            .body_rows = 0,
            .status_row = 0,
            .hint_row = 2,
        };
    }
    const body_rows = rows -| reserved_chrome_rows;
    return .{
        .header_row = 1,
        .body_start = if (body_rows > 0) 2 else 0,
        .body_rows = body_rows,
        .status_row = rows - 1,
        .hint_row = rows,
    };
}

pub fn gutterWidth(line_count: usize) u16 {
    const digits = decimalDigits(@max(line_count, 1));
    return @intCast(@min(digits + 1, std.math.maxInt(u16)));
}

pub fn decimalDigits(value: usize) usize {
    var remaining = @max(value, 1);
    var digits: usize = 1;
    while (remaining >= 10) : (digits += 1) remaining /= 10;
    return digits;
}

pub fn clampScroll(scroll: usize, cursor: usize, body_rows: usize, line_count: usize) usize {
    if (body_rows == 0 or line_count == 0) return 0;
    const max_scroll = line_count -| body_rows;
    var next = @min(scroll, max_scroll);
    if (cursor < next) next = cursor;
    if (cursor >= next + body_rows) next = cursor + 1 - body_rows;
    return next;
}

pub fn visibleWindow(scroll: usize, cursor: usize, body_rows: usize, line_count: usize) VisibleWindow {
    if (body_rows == 0 or line_count == 0) return .{ .first = 0, .count = 0 };
    const first = clampScroll(scroll, cursor, body_rows, line_count);
    return .{
        .first = first,
        .count = @min(body_rows, line_count - first),
    };
}

pub fn splitLines(source: []const u8, out: *std.ArrayList([]const u8), alloc: Allocator) !void {
    if (source.len == 0) {
        try out.append(alloc, "");
        return;
    }
    var start: usize = 0;
    while (start <= source.len) {
        const end = std.mem.findScalarPos(u8, source, start, '\n') orelse source.len;
        try out.append(alloc, source[start..end]);
        if (end == source.len) break;
        start = end + 1;
        if (start == source.len) {
            try out.append(alloc, "");
            break;
        }
    }
}

pub fn lineMatches(line: []const u8, query: []const u8) bool {
    if (query.len == 0 or query.len > line.len) return false;
    var index: usize = 0;
    while (index + query.len <= line.len) : (index += 1) {
        if (asciiEqlIgnoreCase(line[index .. index + query.len], query)) return true;
    }
    return false;
}

pub fn collectMatches(lines: []const []const u8, query: []const u8, out: *std.ArrayList(usize), alloc: Allocator) !void {
    out.clearRetainingCapacity();
    if (query.len == 0) return;
    for (lines, 0..) |line, index| {
        if (lineMatches(line, query)) try out.append(alloc, index);
    }
}

pub fn collectHunks(lines: []const diff_mod.DiffLine, out: *std.ArrayList(Hunk), alloc: Allocator) !void {
    out.clearRetainingCapacity();
    var index: usize = 0;
    while (index < lines.len) {
        if (lines[index].op == .equal) {
            index += 1;
            continue;
        }
        const first = index;
        while (index < lines.len and lines[index].op != .equal) : (index += 1) {}
        try out.append(alloc, .{
            .start = first,
            .end = index,
            .first_change = first,
        });
    }
}

pub fn pairDiffLines(lines: []const diff_mod.DiffLine, out: *std.ArrayList(Pair), alloc: Allocator) !void {
    out.clearRetainingCapacity();
    var index: usize = 0;
    while (index < lines.len) {
        const line = lines[index];
        switch (line.op) {
            .equal => {
                try out.append(alloc, .{ .left = line, .right = line });
                index += 1;
            },
            .remove => {
                if (index + 1 < lines.len and lines[index + 1].op == .add) {
                    try out.append(alloc, .{ .left = line, .right = lines[index + 1] });
                    index += 2;
                } else {
                    try out.append(alloc, .{ .left = line, .right = null });
                    index += 1;
                }
            },
            .add => {
                try out.append(alloc, .{ .left = null, .right = line });
                index += 1;
            },
        }
    }
}

pub fn pairIndexForDiffIndex(pairs: []const Pair, diff_index: usize) usize {
    var walked: usize = 0;
    for (pairs, 0..) |pair, pair_index| {
        const span: usize = blk: {
            if (pair.left != null and pair.right != null and
                pair.left.?.op == .remove and pair.right.?.op == .add)
            {
                break :blk 2;
            }
            break :blk 1;
        };
        if (diff_index < walked + span) return pair_index;
        walked += span;
    }
    return pairs.len -| 1;
}

pub fn sideBySideGeometry(cols: u16, old_max: u32, new_max: u32) SideBySideGeometry {
    const old_gutter: u16 = @intCast(@min(decimalDigits(@max(old_max, 1)) + 1, std.math.maxInt(u16)));
    const new_gutter: u16 = @intCast(@min(decimalDigits(@max(new_max, 1)) + 1, std.math.maxInt(u16)));
    const reserved = @as(u16, old_gutter) +| new_gutter +| 3;
    if (cols <= reserved + 2) {
        return .{
            .old_gutter = old_gutter,
            .new_gutter = new_gutter,
            .col_width = 0,
            .usable = false,
        };
    }
    const remaining = cols - reserved;
    const col_width = remaining / 2;
    return .{
        .old_gutter = old_gutter,
        .new_gutter = new_gutter,
        .col_width = col_width,
        .usable = col_width >= 2,
    };
}

pub fn clipWidth(text: []const u8, width: usize) []const u8 {
    if (width == 0) return "";
    var visible: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == 0x1b) {
            index = display_width.ansiSequenceEnd(text, index);
            continue;
        }
        const unit = display_width.displayUnitAt(text, index);
        if (unit.byte_len == 0) break;
        if (visible + unit.cell_width > width) break;
        visible += unit.cell_width;
        index += unit.byte_len;
    }
    return text[0..index];
}

pub fn profileLabelForPath(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    if (std.ascii.eqlIgnoreCase(basename, "dockerfile")) return "dockerfile";
    if (std.ascii.eqlIgnoreCase(basename, "makefile")) return "make";
    const ext = std.fs.path.extension(basename);
    if (ext.len > 1) return ext[1..];
    return "";
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

test "regions reserve header status and hint rows" {
    const placed = regions(14);
    try std.testing.expectEqual(@as(u16, 1), placed.header_row);
    try std.testing.expectEqual(@as(u16, 2), placed.body_start);
    try std.testing.expectEqual(@as(u16, 11), placed.body_rows);
    try std.testing.expectEqual(@as(u16, 13), placed.status_row);
    try std.testing.expectEqual(@as(u16, 14), placed.hint_row);
    try std.testing.expectEqual(@as(u16, 0), regions(0).body_rows);
    try std.testing.expectEqual(@as(u16, 0), regions(2).body_rows);
}

test "visible window keeps the cursor in view" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(0, 3, 10, 20));
    try std.testing.expectEqual(@as(usize, 6), clampScroll(0, 15, 10, 20));
    try std.testing.expectEqual(@as(usize, 4), clampScroll(8, 4, 10, 20));
    const window = visibleWindow(0, 15, 10, 20);
    try std.testing.expectEqual(@as(usize, 6), window.first);
    try std.testing.expectEqual(@as(usize, 10), window.count);
}

test "splitLines keeps a trailing empty line and an empty file" {
    const alloc = std.testing.allocator;
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(alloc);
    try splitLines("a\nb\n", &lines, alloc);
    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expectEqualStrings("a", lines.items[0]);
    try std.testing.expectEqualStrings("b", lines.items[1]);
    try std.testing.expectEqualStrings("", lines.items[2]);

    lines.clearRetainingCapacity();
    try splitLines("", &lines, alloc);
    try std.testing.expectEqual(@as(usize, 1), lines.items.len);
    try std.testing.expectEqualStrings("", lines.items[0]);
}

test "search matches are case insensitive" {
    const alloc = std.testing.allocator;
    const lines = [_][]const u8{ "Alpha", "beta", "ALPHABET" };
    var matches: std.ArrayList(usize) = .empty;
    defer matches.deinit(alloc);
    try collectMatches(&lines, "alp", &matches, alloc);
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), matches.items[0]);
    try std.testing.expectEqual(@as(usize, 2), matches.items[1]);
    try std.testing.expect(lineMatches("const Foo", "foo"));
    try std.testing.expect(!lineMatches("const Foo", "bar"));
}

test "hunks group consecutive changed lines" {
    const alloc = std.testing.allocator;
    const lines = [_]diff_mod.DiffLine{
        .{ .op = .equal, .text = "a" },
        .{ .op = .remove, .text = "old" },
        .{ .op = .add, .text = "new" },
        .{ .op = .equal, .text = "c" },
        .{ .op = .add, .text = "tail" },
    };
    var hunks: std.ArrayList(Hunk) = .empty;
    defer hunks.deinit(alloc);
    try collectHunks(&lines, &hunks, alloc);
    try std.testing.expectEqual(@as(usize, 2), hunks.items.len);
    try std.testing.expectEqual(@as(usize, 1), hunks.items[0].first_change);
    try std.testing.expectEqual(@as(usize, 3), hunks.items[0].end);
    try std.testing.expectEqual(@as(usize, 4), hunks.items[1].first_change);
}

test "side-by-side pairs a replace on one row" {
    const alloc = std.testing.allocator;
    const lines = [_]diff_mod.DiffLine{
        .{ .op = .equal, .old_num = 1, .new_num = 1, .text = "keep" },
        .{ .op = .remove, .old_num = 2, .text = "old" },
        .{ .op = .add, .new_num = 2, .text = "new" },
        .{ .op = .add, .new_num = 3, .text = "extra" },
    };
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(alloc);
    try pairDiffLines(&lines, &pairs, alloc);
    try std.testing.expectEqual(@as(usize, 3), pairs.items.len);
    try std.testing.expectEqual(diff_mod.LineOp.equal, pairs.items[0].left.?.op);
    try std.testing.expectEqual(diff_mod.LineOp.remove, pairs.items[1].left.?.op);
    try std.testing.expectEqual(diff_mod.LineOp.add, pairs.items[1].right.?.op);
    try std.testing.expect(pairs.items[2].left == null);
    try std.testing.expectEqual(diff_mod.LineOp.add, pairs.items[2].right.?.op);
    try std.testing.expectEqual(@as(usize, 1), pairIndexForDiffIndex(pairs.items, 1));
    try std.testing.expectEqual(@as(usize, 1), pairIndexForDiffIndex(pairs.items, 2));
    try std.testing.expectEqual(@as(usize, 2), pairIndexForDiffIndex(pairs.items, 3));
}

test "side-by-side geometry falls back when the terminal is narrow" {
    const wide = sideBySideGeometry(80, 99, 120);
    try std.testing.expect(wide.usable);
    try std.testing.expect(wide.col_width >= 2);
    const narrow = sideBySideGeometry(12, 1000, 1000);
    try std.testing.expect(!narrow.usable);
}

test "gutter width grows with the line count" {
    try std.testing.expectEqual(@as(u16, 2), gutterWidth(9));
    try std.testing.expectEqual(@as(u16, 3), gutterWidth(10));
    try std.testing.expectEqual(@as(u16, 4), gutterWidth(100));
}

test "profile label uses the file extension" {
    try std.testing.expectEqualStrings("zig", profileLabelForPath("src/main.zig"));
    try std.testing.expectEqualStrings("ts", profileLabelForPath("app.ts"));
    try std.testing.expectEqualStrings("dockerfile", profileLabelForPath("Dockerfile"));
    try std.testing.expectEqualStrings("", profileLabelForPath("README"));
}
