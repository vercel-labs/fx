const std = @import("std");
const shared_theme = @import("../../shared/theme.zig");
const Allocator = std.mem.Allocator;

pub const bold_open = "\x1b[1m";
pub const bold_close = "\x1b[22m";
pub const italic_open = "\x1b[3m";
pub const italic_close = "\x1b[23m";
pub const dim_open = "\x1b[2m";
pub const dim_close = "\x1b[22m";
pub const underline_open = "\x1b[4m";
pub const underline_close = "\x1b[24m";
pub var task_completed_open: []const u8 = shared_theme.fx_dark.task_completed_open;
pub var task_completed_close: []const u8 = "\x1b[39m";
pub const strike_open = "\x1b[9m";
pub const strike_close = "\x1b[29m";
pub var inline_code_open: []const u8 = shared_theme.fx_dark.inline_code_open;
pub var inline_code_close: []const u8 = "\x1b[39m";

pub fn setInlineCodeTheme(light: bool) void {
    applyTheme(shared_theme.builtin(light));
}

pub fn applyTheme(theme: shared_theme.Theme) void {
    inline_code_open = theme.inline_code_open;
    task_completed_open = theme.task_completed_open;
    // Themed slots may carry bold/italic/background; the close must reset
    // everything the open sets or attributes bleed into following text.
    inline_code_close = shared_theme.closingFor(theme.inline_code_open);
    task_completed_close = shared_theme.closingFor(theme.task_completed_open);
}

/// How a markdown structure part looks when the theme leaves its color
/// (`heading`, `quote`, `list_marker`, `rule`) empty, as the builtins do.
pub const Unthemed = enum { dim, plain };

pub const Mark = struct { open: []const u8, close: []const u8 };

/// The open and close for a markdown structure color from the active theme,
/// or the historical look when the theme leaves it empty.
pub fn mark(open: []const u8, unthemed: Unthemed) Mark {
    if (open.len != 0) return .{ .open = open, .close = shared_theme.closingFor(open) };
    return switch (unthemed) {
        .dim => .{ .open = dim_open, .close = dim_close },
        .plain => .{ .open = "", .close = "" },
    };
}

pub fn writeMarked(alloc: Allocator, out: *std.ArrayList(u8), open: []const u8, bytes: []const u8, unthemed: Unthemed) !void {
    const m = mark(open, unthemed);
    try out.appendSlice(alloc, m.open);
    try out.appendSlice(alloc, bytes);
    try out.appendSlice(alloc, m.close);
}

// Keeps table intersections aligned with row separators.
pub const table_column_sep = " \xe2\x94\x82 ";
pub const table_horiz = "\xe2\x94\x80";
pub const table_junction = "\xe2\x94\x80\xe2\x94\xbc\xe2\x94\x80";
pub const vertical_rule_prefix = "\xe2\x94\x82 ";
pub const bullet_marker = "\xe2\x80\xa2 ";
pub const task_pending_marker = "\xe2\x98\x90";
pub const task_completed_marker = "\xe2\x9c\x93";

pub const max_pipe_buffer_bytes: usize = 32 * 1024;
pub const horizontal_rule_width: usize = 60;
/// OSC 8 links longer than this fall back to literal rendering.
pub const max_link_url_bytes: usize = 2083;

pub fn writeDim(alloc: Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    try out.appendSlice(alloc, dim_open);
    try out.appendSlice(alloc, bytes);
    try out.appendSlice(alloc, dim_close);
}

pub fn writeHorizontalRule(alloc: Allocator, out: *std.ArrayList(u8)) !void {
    const m = mark(shared_theme.current().rule_open, .dim);
    try out.appendSlice(alloc, m.open);
    var i: usize = 0;
    while (i < horizontal_rule_width) : (i += 1) try out.appendSlice(alloc, table_horiz);
    try out.appendSlice(alloc, m.close);
}
