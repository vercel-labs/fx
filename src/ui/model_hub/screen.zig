//! Paints the model hub (D221) on the catalog-menu alternate screen: a title
//! row, the sidebar of scopes beside the scope's list, and a hint row that
//! becomes a chip strip while one is open. Below 64 columns only one pane
//! shows at a time, as in proto's compact hub.

const std = @import("std");
const hub = @import("../../core/model_hub/hub.zig");
const display_width = @import("../../core/shared/display_width.zig");
const ui_render = @import("../render.zig");
const Line = @import("line.zig").Line;
const body = @import("body.zig");
const chrome = @import("chrome.zig");

const Allocator = std.mem.Allocator;

pub const Paint = struct {
    bytes: []u8,
    /// The list's first visible row and how many rows showed, for the
    /// hub's scrolling and page keys.
    window_start: usize = 0,
    visible_rows: usize = 0,

    pub fn deinit(self: *Paint, alloc: Allocator) void {
        alloc.free(self.bytes);
    }
};

/// Below this width the sidebar and the list take turns.
pub const compact_width: u16 = 64;
const min_rows: u16 = 6;

pub fn paint(alloc: Allocator, state: *const hub.State, rows: u16, cols: u16, clear: bool) !Paint {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("\x1b[?25l\x1b[H");
    if (clear) try w.writeAll("\x1b[2J");
    var result: Paint = .{ .bytes = &.{} };
    if (rows < min_rows or cols < 20 or state.snapshot == null) {
        var line: Line = .init(alloc, cols);
        defer line.deinit();
        try line.put(ui_render.dim_style, "Window too small · esc closes");
        try writeRow(w, 0, line.bytes.items);
        for (1..rows) |row| try writeRow(w, @intCast(row), "");
        result.bytes = try alloc.dupe(u8, out.written());
        return result;
    }

    const compact = cols < compact_width;
    const content_rows: u16 = rows - 4;
    const show_sidebar = !compact or state.focus == .scope;
    const show_body = !compact or state.focus == .list;
    const sidebar_width: u16 = if (compact) cols else chrome.sidebarWidth(state);
    const body_col: u16 = if (compact) 0 else sidebar_width + 3;
    const body_width: u16 = if (compact) cols else cols - body_col;

    var title: Line = .init(alloc, cols);
    defer title.deinit();
    try chrome.title(&title, state, compact);
    try writeRow(w, 0, title.bytes.items);
    var rule: Line = .init(alloc, cols);
    defer rule.deinit();
    try chrome.rule(&rule, cols, if (compact) null else sidebar_width + 1);
    try writeRow(w, 1, rule.bytes.items);

    var sidebar_lines: std.ArrayList(Line) = .empty;
    defer {
        for (sidebar_lines.items) |*line| line.deinit();
        sidebar_lines.deinit(alloc);
    }
    if (show_sidebar) try chrome.sidebar(alloc, state, sidebar_width, content_rows, &sidebar_lines);

    var body_lines: std.ArrayList(Line) = .empty;
    defer {
        for (body_lines.items) |*line| line.deinit();
        body_lines.deinit(alloc);
    }
    if (show_body) {
        const placed = try body.compose(alloc, state, body_width, content_rows, &body_lines);
        result.window_start = placed.window_start;
        result.visible_rows = placed.visible_rows;
    }

    for (0..content_rows) |index| {
        var row: Line = .init(alloc, cols);
        defer row.deinit();
        if (show_sidebar and index < sidebar_lines.items.len) {
            try row.bytes.appendSlice(alloc, sidebar_lines.items[index].bytes.items);
            row.used = sidebar_lines.items[index].used;
        }
        if (show_body) {
            if (!compact) {
                try row.padTo(sidebar_width + 1);
                try row.put(ui_render.divider_style, "│");
                try row.spaces(1);
            }
            if (index < body_lines.items.len) {
                try row.bytes.appendSlice(alloc, body_lines.items[index].bytes.items);
                row.used += body_lines.items[index].used;
            }
        }
        try writeRow(w, @intCast(index + 2), row.bytes.items);
    }

    var bottom_rule: Line = .init(alloc, cols);
    defer bottom_rule.deinit();
    try chrome.rule(&bottom_rule, cols, if (compact) null else sidebar_width + 1);
    try writeRow(w, rows - 2, bottom_rule.bytes.items);
    var hint: Line = .init(alloc, cols);
    defer hint.deinit();
    try chrome.hints(&hint, state, compact);
    try writeRow(w, rows - 1, hint.bytes.items);

    result.bytes = try alloc.dupe(u8, out.written());
    return result;
}

/// Erases the row before writing it: erasing after a full-width row would
/// remove its last cell, where the cursor waits to wrap.
fn writeRow(w: *std.Io.Writer, row: u16, bytes: []const u8) !void {
    try w.print("\x1b[{d};1H\x1b[2K", .{row + 1});
    try w.writeAll(bytes);
    try w.writeAll(ui_render.reset_style);
}

test {
    _ = @import("line.zig");
    _ = @import("screen_tests.zig");
}
