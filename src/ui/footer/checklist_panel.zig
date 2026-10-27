//! Draws the live checklist above the composer (D252) from the rows
//! `core/checklist/panel.zig` picks: one line each, task text made
//! terminal-safe and cut with an ellipsis at the terminal's width.
const std = @import("std");
const checklist = @import("../../core/checklist/checklist.zig");
const panel = @import("../../core/checklist/panel.zig");
const presentation = @import("../../core/checklist/presentation.zig");
const ui_render = @import("../render.zig");
const row_text = @import("row_text.zig");
const display_width = @import("../../core/shared/display_width.zig");

const Allocator = std.mem.Allocator;

/// The rows the panel asks for; 0 when hidden.
pub fn wantedRows(list: ?*const checklist.List) u16 {
    const value = list orelse return 0;
    return panel.wantedRows(value);
}

/// Appends the panel's rows, at most `budget`, each within `width`.
pub fn compose(alloc: Allocator, list: *const checklist.List, width: u16, budget: u16, out: *std.ArrayList(std.ArrayList(u8))) !void {
    var buf: [panel.max_rows]panel.Row = undefined;
    const picked = panel.rows(list, budget, &buf);
    var multi = false;
    for (picked) |row| multi = multi or row == .phase;
    for (picked) |row| {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(alloc);
        try composeRow(alloc, &line, row, multi, width);
        try out.append(alloc, line);
    }
}

fn composeRow(alloc: Allocator, line: *std.ArrayList(u8), row: panel.Row, multi: bool, width: u16) !void {
    const room: usize = width;
    switch (row) {
        .header => |header| {
            var buf: [96]u8 = undefined;
            const progress = if (header.dropped > 0)
                std.mem.print(&buf, " · {d} of {d} done · {d} dropped", .{ header.done, header.total, header.dropped }) catch ""
            else
                std.mem.print(&buf, " · {d} of {d} done", .{ header.done, header.total }) catch "";
            var used: usize = 0;
            if (header.settled and room >= 2) {
                try put(alloc, line, ui_render.green_style, "✓ ");
                used = 2;
            }
            const title = "Checklist";
            if (room < used + title.len) return;
            try put(alloc, line, ui_render.bold_style, title);
            used += title.len;
            try line.appendSlice(alloc, ui_render.dim_style);
            try row_text.appendSingleLineEllipsized(alloc, line, progress, room -| used);
            try line.appendSlice(alloc, ui_render.reset_style);
        },
        .phase => |phase| {
            var buf: [32]u8 = undefined;
            const progress = std.mem.print(&buf, " · {d}/{d}", .{ phase.done, phase.total }) catch "";
            const indent = 2;
            if (room <= indent) return;
            try line.appendNTimes(alloc, ' ', indent);
            const name_room = (room - indent) -| progress.len;
            try line.appendSlice(alloc, if (phase.active) ui_render.bold_style else ui_render.dim_style);
            try row_text.appendTerminalSafeSingleLine(alloc, line, phase.name, @max(name_room, @min(room - indent, 4)));
            try line.appendSlice(alloc, ui_render.reset_style);
            const used = display_width.visibleWidthIgnoringAnsi(line.items);
            if (used + progress.len <= room) try put(alloc, line, ui_render.dim_style, progress);
        },
        .task => |task| {
            const indent: usize = if (multi) 4 else 2;
            if (room <= indent + 2) return;
            try line.appendNTimes(alloc, ' ', indent);
            const style = switch (task.status) {
                .in_progress => "",
                .blocked => ui_render.warning_style,
                .completed, .abandoned, .pending => ui_render.dim_style,
            };
            try put(alloc, line, if (task.status == .completed) ui_render.green_style else style, presentation.glyph(task.status));
            try line.append(alloc, ' ');
            const text_room = room - indent - 2;
            if (task.blocker) |blocker| if (task.status == .blocked) {
                const content_room = @max(text_room / 2, @min(text_room, display_width.visibleWidth(task.content)));
                try line.appendSlice(alloc, style);
                try row_text.appendTerminalSafeSingleLine(alloc, line, task.content, content_room);
                try line.appendSlice(alloc, ui_render.reset_style);
                const used = display_width.visibleWidthIgnoringAnsi(line.items);
                if (used + 4 < room) {
                    try put(alloc, line, ui_render.dim_style, " · ");
                    try line.appendSlice(alloc, ui_render.dim_style);
                    try row_text.appendTerminalSafeSingleLine(alloc, line, blocker, room - used - 3);
                    try line.appendSlice(alloc, ui_render.reset_style);
                }
                return;
            };
            try line.appendSlice(alloc, style);
            try row_text.appendTerminalSafeSingleLine(alloc, line, task.content, text_room);
            try line.appendSlice(alloc, ui_render.reset_style);
        },
        .more_tasks => |hidden| {
            var buf: [48]u8 = undefined;
            const text = std.mem.print(&buf, "{s}… {d} more", .{ if (multi) "    " else "  ", hidden }) catch "";
            try line.appendSlice(alloc, ui_render.dim_style);
            try row_text.appendSingleLineEllipsized(alloc, line, text, room);
            try line.appendSlice(alloc, ui_render.reset_style);
        },
        .more_phases => |hidden| {
            var buf: [48]u8 = undefined;
            const text = std.mem.print(&buf, "  … {d} more phase{s}", .{ hidden, if (hidden == 1) "" else "s" }) catch "";
            try line.appendSlice(alloc, ui_render.dim_style);
            try row_text.appendSingleLineEllipsized(alloc, line, text, room);
            try line.appendSlice(alloc, ui_render.reset_style);
        },
    }
}

fn put(alloc: Allocator, line: *std.ArrayList(u8), style: []const u8, text: []const u8) !void {
    try line.appendSlice(alloc, style);
    try line.appendSlice(alloc, text);
    try line.appendSlice(alloc, ui_render.reset_style);
}

fn plainRows(alloc: Allocator, list: *const checklist.List, width: u16, budget: u16) ![]u8 {
    var rows: std.ArrayList(std.ArrayList(u8)) = .empty;
    defer {
        for (rows.items) |*row| row.deinit(alloc);
        rows.deinit(alloc);
    }
    try compose(alloc, list, width, budget, &rows);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (rows.items) |row| {
        try std.testing.expect(display_width.visibleWidthIgnoringAnsi(row.items) <= width);
        var index: usize = 0;
        while (index < row.items.len) {
            if (row.items[index] == 0x1b) {
                index = display_width.ansiSequenceEnd(row.items, index);
                continue;
            }
            try out.append(alloc, row.items[index]);
            index += 1;
        }
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

test "the panel reads as progress, phases and tasks, and fits any width" {
    const alloc = std.testing.allocator;
    var list = try checklist.testList(alloc, &.{
        .{ "Build", &.{ .{ "Write parser", .completed }, .{ "Add tests", .in_progress }, .{ "Docs", .pending } } },
        .{ "Ship", &.{ .{ "Tag release", .blocked }, .{ "Announce", .pending } } },
    });
    defer list.deinit();
    list.phases.items[1].tasks.items[0].blocker = "waiting on review";
    const wide = try plainRows(alloc, &list, 80, panel.max_rows);
    defer alloc.free(wide);
    try std.testing.expectEqualStrings(
        \\Checklist · 1 of 5 done
        \\  Build · 1/3
        \\    ✓ Write parser
        \\    → Add tests
        \\    ○ Docs
        \\  Ship · 0/2
        \\
    , wide);
    for ([_]u16{ 0, 1, 4, 9, 12, 20, 33 }) |width| {
        const narrow = try plainRows(alloc, &list, width, panel.max_rows);
        alloc.free(narrow);
    }
    // A hostile task name stays one escaped line.
    list.phases.items[0].tasks.items[1].content = "evil\x1b[2J\nname";
    const escaped = try plainRows(alloc, &list, 80, panel.max_rows);
    defer alloc.free(escaped);
    try std.testing.expect(std.mem.find(u8, escaped, "\x1b[2J") == null);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, escaped, "\n"));
}

test "a blocked task shows why and a settled list collapses to one line" {
    const alloc = std.testing.allocator;
    var blocked = try checklist.testList(alloc, &.{.{ "Ship", &.{ .{ "Tag release", .blocked }, .{ "Old idea", .abandoned } } }});
    defer blocked.deinit();
    blocked.phases.items[0].tasks.items[0].blocker = "review";
    const shown = try plainRows(alloc, &blocked, 60, panel.max_rows);
    defer alloc.free(shown);
    try std.testing.expect(std.mem.find(u8, shown, "! Tag release · review") != null);

    var done = try checklist.testList(alloc, &.{.{ "Work", &.{ .{ "a", .completed }, .{ "b", .completed } } }});
    defer done.deinit();
    const settled = try plainRows(alloc, &done, 60, panel.max_rows);
    defer alloc.free(settled);
    try std.testing.expectEqualStrings("✓ Checklist · 2 of 2 done\n", settled);
}
