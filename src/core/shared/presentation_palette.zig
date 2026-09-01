const std = @import("std");
const color_palette = @import("../config/color_palette.zig");

/// The configured family of colors used by fx-owned presentation.
///
/// This module deliberately contains only static escape strings.  It is used
/// by both core markdown presentation and the UI renderer, so neither side
/// needs to import the other to agree on the palette's wire format.
pub const ColorPalette = color_palette.ColorPalette;

pub const Styles = struct {
    divider: []const u8,
    hint: []const u8,
    statusline: []const u8,
    tag: []const u8,
    subtitle: []const u8,
    system_notice_label: []const u8,
    system_notice_text: []const u8,
    dim: []const u8,
    warning: []const u8,
    green: []const u8,
    red: []const u8,
    diff_added: []const u8,
    diff_removed: []const u8,
    approval_active: []const u8,
    approval_inactive: []const u8,
    selected_completion: []const u8,
    permission_auto: []const u8,
    diff_added_marker: []const u8,
    diff_removed_marker: []const u8,
    inline_code: []const u8,
    task_completed: []const u8,
    user_marker: []const u8,
    user_accent: []const u8,
    code_keyword: []const u8,
    code_string: []const u8,
    code_number: []const u8,
    code_comment: []const u8,
};

// .fx is the existing product palette. Keep these bytes in one place, but do
// not normalize or otherwise rewrite them: retained transcript fixtures and
// downstream integrations depend on their exact historical representation.
const fx_dark: Styles = .{
    .divider = "\x1b[38;5;240m",
    .hint = "\x1b[38;5;255m",
    .statusline = "\x1b[38;5;245m",
    .tag = "\x1b[1;38;5;255m",
    .subtitle = "\x1b[1;38;5;255m",
    .system_notice_label = "\x1b[1;38;5;252m",
    .system_notice_text = "\x1b[38;5;250m",
    .dim = "\x1b[38;5;245m",
    .warning = "\x1b[38;5;252m",
    .green = "\x1b[38;5;252m",
    .red = "\x1b[38;5;252m",
    .diff_added = "\x1b[38;5;252m",
    .diff_removed = "\x1b[38;5;252m",
    .approval_active = "\x1b[48;5;255m\x1b[38;5;235m\x1b[1m",
    .approval_inactive = "\x1b[48;5;239m\x1b[38;5;255m",
    .selected_completion = "\x1b[1;38;5;255m",
    .permission_auto = "\x1b[38;5;252m",
    .diff_added_marker = "\x1b[38;5;71m",
    .diff_removed_marker = "\x1b[38;5;167m",
    .inline_code = "\x1b[38;5;245m",
    .task_completed = "\x1b[38;5;252m",
    .user_marker = "\x1b[38;5;255m",
    .user_accent = "\x1b[38;5;252m",
    .code_keyword = "\x1b[38;5;252m",
    .code_string = "\x1b[38;5;250m",
    .code_number = "\x1b[38;5;250m",
    .code_comment = "\x1b[38;5;245m",
};

const fx_light: Styles = .{
    .divider = "\x1b[38;5;250m",
    .hint = "\x1b[38;5;235m",
    .statusline = "\x1b[38;5;241m",
    .tag = "\x1b[1;38;5;235m",
    .subtitle = "\x1b[1;38;5;235m",
    .system_notice_label = "\x1b[1;38;5;238m",
    .system_notice_text = "\x1b[38;5;241m",
    .dim = "\x1b[38;5;247m",
    .warning = "\x1b[38;5;238m",
    .green = "\x1b[38;5;238m",
    .red = "\x1b[38;5;238m",
    .diff_added = "\x1b[38;5;238m",
    .diff_removed = "\x1b[38;5;238m",
    .approval_active = "\x1b[48;5;236m\x1b[38;5;255m\x1b[1m",
    .approval_inactive = "\x1b[48;5;251m\x1b[38;5;237m",
    .selected_completion = "\x1b[1;38;5;235m",
    .permission_auto = "\x1b[38;5;238m",
    .diff_added_marker = "\x1b[38;5;71m",
    .diff_removed_marker = "\x1b[38;5;167m",
    .inline_code = "\x1b[38;5;247m",
    .task_completed = "\x1b[38;5;238m",
    .user_marker = "\x1b[38;5;235m",
    .user_accent = "\x1b[38;5;238m",
    .code_keyword = "\x1b[38;5;238m",
    .code_string = "\x1b[38;5;241m",
    .code_number = "\x1b[38;5;241m",
    .code_comment = "\x1b[38;5;243m",
};

// The terminal palette intentionally avoids 256-color and truecolor queries.
// SGR 39/49 return to the terminal's configured default foreground/background;
// the remaining roles use the portable ANSI-16 slots.
const terminal: Styles = .{
    .divider = "\x1b[90m",
    .hint = "\x1b[90m",
    .statusline = "\x1b[90m",
    .tag = "\x1b[1m",
    .subtitle = "\x1b[1m",
    .system_notice_label = "\x1b[1m",
    .system_notice_text = "\x1b[39m",
    .dim = "\x1b[90m",
    .warning = "\x1b[33m",
    .green = "\x1b[32m",
    .red = "\x1b[31m",
    .diff_added = "\x1b[32m",
    .diff_removed = "\x1b[31m",
    // Establish terminal defaults before reverse video so the button does
    // not inherit an arbitrary preceding indexed color.
    .approval_active = "\x1b[39m\x1b[49m\x1b[7m\x1b[1m",
    .approval_inactive = "\x1b[39m\x1b[49m\x1b[90m",
    .selected_completion = "\x1b[1m",
    .permission_auto = "\x1b[36m",
    .diff_added_marker = "\x1b[32m",
    .diff_removed_marker = "\x1b[31m",
    // Inline code and comments share the muted ANSI slot so the same raw
    // token can be retinted safely in retained assistant text.
    .inline_code = "\x1b[90m",
    .task_completed = "\x1b[32m",
    .user_marker = "\x1b[96m",
    .user_accent = "\x1b[36m",
    .code_keyword = "\x1b[34m",
    .code_string = "\x1b[32m",
    .code_number = "\x1b[36m",
    .code_comment = "\x1b[90m",
};

var active_light: bool = false;
var active_palette: ColorPalette = .fx;

pub fn styles(light: bool, palette: ColorPalette) Styles {
    return switch (palette) {
        .fx => if (light) fx_light else fx_dark,
        .terminal => terminal,
    };
}

pub fn setActive(light: bool, palette: ColorPalette) void {
    active_light = light;
    active_palette = palette;
}

pub fn currentStyles() Styles {
    return styles(active_light, active_palette);
}

pub fn currentPalette() ColorPalette {
    return active_palette;
}

pub fn isFx(palette: ColorPalette) bool {
    return palette == .fx;
}

test "terminal presentation palette uses defaults and ANSI-16 slots" {
    const palette = styles(false, .terminal);
    try std.testing.expectEqualStrings("\x1b[39m", palette.system_notice_text);
    try std.testing.expect(std.mem.startsWith(u8, palette.approval_active, "\x1b[39m\x1b[49m"));
    try std.testing.expect(std.mem.indexOf(u8, palette.green, "38;5;") == null);
    try std.testing.expect(std.mem.indexOf(u8, palette.green, "38;2;") == null);
}
