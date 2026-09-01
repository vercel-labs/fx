const std = @import("std");
const Allocator = std.mem.Allocator;
const presentation_palette = @import("../../shared/presentation_palette.zig");

pub const ColorPalette = presentation_palette.ColorPalette;

pub const bold_open = "\x1b[1m";
pub const bold_close = "\x1b[22m";
pub const italic_open = "\x1b[3m";
pub const italic_close = "\x1b[23m";
pub const dim_open = "\x1b[2m";
pub const dim_close = "\x1b[22m";
pub const underline_open = "\x1b[4m";
pub const underline_close = "\x1b[24m";
const task_completed_dark_open = "\x1b[38;5;252m";
const task_completed_light_open = "\x1b[38;5;238m";
pub var task_completed_open: []const u8 = task_completed_dark_open;
pub const task_completed_close = "\x1b[39m";
pub const strike_open = "\x1b[9m";
pub const strike_close = "\x1b[29m";
const inline_code_dark_open = "\x1b[38;5;245m";
const inline_code_light_open = "\x1b[38;5;247m";
pub var inline_code_open: []const u8 = inline_code_dark_open;
pub const inline_code_close = "\x1b[39m";

pub fn setInlineCodeTheme(light: bool) void {
    setInlineCodePalette(light, .fx);
}

/// Set the markdown colors for an explicit presentation palette.  The
/// one-argument `setInlineCodeTheme` wrapper above intentionally retains the
/// historical .fx bytes for callers that do not participate in palette
/// configuration yet.
pub fn setInlineCodePalette(light: bool, palette: ColorPalette) void {
    const styles = presentation_palette.styles(light, palette);
    inline_code_open = styles.inline_code;
    task_completed_open = styles.task_completed;
}

pub fn inlineCodeStyle(light: bool, palette: ColorPalette) []const u8 {
    return presentation_palette.styles(light, palette).inline_code;
}

pub fn taskCompletedStyle(light: bool, palette: ColorPalette) []const u8 {
    return presentation_palette.styles(light, palette).task_completed;
}

pub fn isInlineCodeOpen(seq: []const u8) bool {
    return std.mem.eql(u8, seq, inline_code_dark_open) or
        std.mem.eql(u8, seq, inline_code_light_open) or
        std.mem.eql(u8, seq, presentation_palette.styles(false, .terminal).inline_code);
}

pub fn isTaskCompletedOpen(seq: []const u8) bool {
    return std.mem.eql(u8, seq, task_completed_dark_open) or
        std.mem.eql(u8, seq, task_completed_light_open) or
        std.mem.eql(u8, seq, presentation_palette.styles(false, .terminal).task_completed);
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
    try out.appendSlice(alloc, dim_open);
    var i: usize = 0;
    while (i < horizontal_rule_width) : (i += 1) try out.appendSlice(alloc, table_horiz);
    try out.appendSlice(alloc, dim_close);
}

test "terminal palette selects ANSI-16 markdown styles" {
    setInlineCodePalette(false, .terminal);
    defer setInlineCodeTheme(false);

    try std.testing.expectEqualStrings("\x1b[90m", inline_code_open);
    try std.testing.expectEqualStrings("\x1b[32m", task_completed_open);
}
