const std = @import("std");
const builtin = @import("builtin");
const types = @import("../../core/shared/types.zig");

pub const interactive_mode_enable_sequence = "\x1b[>4;2m\x1b[>1u\x1b[?2004h\x1b[?7l";
const tmux_interactive_mode_enable_sequence = "\x1b[>4;2m\x1b[?2004h\x1b[?7l";
pub const theme_notification_enable_sequence = "\x1b[?2031h";
pub const theme_notification_disable_sequence = "\x1b[?2031l";
pub const theme_color_scheme_query = "\x1b[?996n";
pub const theme_background_query = "\x1b]11;?\x1b\\";
pub const theme_response_fence_query = "\x1b[c";
pub const theme_background_query_with_fence = theme_background_query ++ theme_response_fence_query;
pub const alternate_screen_leave_sequence = "\x1b[?1049l";
pub const alternate_mouse_tracking_leave_sequence = "\x1b[?1000l\x1b[?1006l";

pub fn alternateScreenLeaveSequence(mouse_tracking_active: bool) []const u8 {
    return if (mouse_tracking_active)
        alternate_mouse_tracking_leave_sequence ++ alternate_screen_leave_sequence
    else
        alternate_screen_leave_sequence;
}

pub fn alternateScreenFrameRestoreSequence(mouse_tracking_active: bool) []const u8 {
    return if (mouse_tracking_active)
        alternate_mouse_tracking_leave_sequence ++ alternate_screen_leave_sequence ++ "\x1b[?25l"
    else
        alternate_screen_leave_sequence ++ "\x1b[?25l";
}

pub fn interactiveModeEnableSequence(tmux: ?[]const u8) []const u8 {
    return if (tmux == null)
        interactive_mode_enable_sequence
    else
        tmux_interactive_mode_enable_sequence;
}

pub fn queryLayout(fd: std.posix.fd_t, footer_rows: u16) !types.Layout {
    if (comptime builtin.os.tag == .windows) return queryWindowsLayout(footer_rows);
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };

    const req: c_int = @intCast(std.c.T.IOCGWINSZ);
    const rc = std.c.ioctl(fd, req, &ws);
    if (rc == -1 or ws.row == 0 or ws.col == 0) {
        return error.UnableToReadTerminalSize;
    }
    return layoutFromSize(ws.row, ws.col, footer_rows);
}

fn queryWindowsLayout(footer_rows: u16) !types.Layout {
    if (comptime builtin.os.tag == .windows) {
        const k32 = struct {
            const COORD = extern struct { X: i16, Y: i16 };
            const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
            const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
                dwSize: COORD,
                dwCursorPosition: COORD,
                wAttributes: u16,
                srWindow: SMALL_RECT,
                dwMaximumWindowSize: COORD,
            };

            extern "kernel32" fn GetConsoleScreenBufferInfo(
                hConsoleOutput: std.os.windows.HANDLE,
                lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
            ) callconv(.winapi) std.os.windows.BOOL;
        };

        var info: k32.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (!k32.GetConsoleScreenBufferInfo(std.Io.File.stdout().handle, &info).toBool()) {
            return layoutFromSize(24, 80, footer_rows);
        }
        const cols_i = @as(i32, info.srWindow.Right) - @as(i32, info.srWindow.Left) + 1;
        const rows_i = @as(i32, info.srWindow.Bottom) - @as(i32, info.srWindow.Top) + 1;
        if (cols_i <= 0 or rows_i <= 0) return layoutFromSize(24, 80, footer_rows);
        return layoutFromSize(@intCast(rows_i), @intCast(cols_i), footer_rows);
    }
    return error.UnableToReadTerminalSize;
}

pub fn layoutFromSize(rows: u16, cols: u16, footer_rows: u16) !types.Layout {
    if (rows <= footer_rows) return error.TerminalTooSmall;

    return .{
        .rows = rows,
        .cols = cols,
        .content_bottom = rows - footer_rows,
        .divider_top_row = rows - 3,
        .input_row = rows - 2,
        .divider_bottom_row = rows - 1,
        .hint_row = rows,
    };
}

pub fn isInvalidLayoutError(err: anyerror) bool {
    return err == error.UnableToReadTerminalSize or err == error.TerminalTooSmall;
}

pub fn moveCursorSequence(buf: []u8, row: u16, col: u16) ![]const u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col });
}

test "moveCursorSequence formats correctly" {
    var buf: [32]u8 = undefined;
    const seq = try moveCursorSequence(&buf, 10, 5);
    try std.testing.expectEqualStrings("\x1b[10;5H", seq);
}

test "moveCursorSequence row 1 col 1" {
    var buf: [32]u8 = undefined;
    const seq = try moveCursorSequence(&buf, 1, 1);
    try std.testing.expectEqualStrings("\x1b[1;1H", seq);
}

test "layoutFromSize derives shared native and WASM terminal geometry" {
    const layout = try layoutFromSize(24, 80, 4);
    try std.testing.expectEqual(@as(u16, 24), layout.rows);
    try std.testing.expectEqual(@as(u16, 80), layout.cols);
    try std.testing.expectEqual(@as(u16, 20), layout.content_bottom);
    try std.testing.expectEqual(@as(u16, 21), layout.divider_top_row);
    try std.testing.expectEqual(@as(u16, 22), layout.input_row);
    try std.testing.expectEqual(@as(u16, 23), layout.divider_bottom_row);
    try std.testing.expectEqual(@as(u16, 24), layout.hint_row);
    try std.testing.expectError(error.TerminalTooSmall, layoutFromSize(4, 80, 4));
}

test "alternate screen leave sequence includes active mouse modes exactly once" {
    try std.testing.expectEqualStrings(
        alternate_screen_leave_sequence,
        alternateScreenLeaveSequence(false),
    );
    try std.testing.expectEqualStrings(
        alternate_mouse_tracking_leave_sequence ++ alternate_screen_leave_sequence,
        alternateScreenLeaveSequence(true),
    );
}

test "alternate screen frame restore leaves the cursor hidden for repaint" {
    try std.testing.expectEqualStrings(
        alternate_screen_leave_sequence ++ "\x1b[?25l",
        alternateScreenFrameRestoreSequence(false),
    );
    try std.testing.expectEqualStrings(
        alternate_mouse_tracking_leave_sequence ++ alternate_screen_leave_sequence ++ "\x1b[?25l",
        alternateScreenFrameRestoreSequence(true),
    );
}

test "interactive mode preserves direct terminal keyboard protocols" {
    try std.testing.expectEqualStrings(
        interactive_mode_enable_sequence,
        interactiveModeEnableSequence(null),
    );
}

test "interactive mode leaves kitty keyboard negotiation to tmux" {
    const sequence = interactiveModeEnableSequence("");

    try std.testing.expectEqualStrings(
        "\x1b[>4;2m\x1b[?2004h\x1b[?7l",
        sequence,
    );
    try std.testing.expect(std.mem.find(u8, sequence, "\x1b[>1u") == null);
    try std.testing.expect(std.mem.find(u8, sequence, "\x1b[>4;2m") != null);
    try std.testing.expect(std.mem.find(u8, sequence, "\x1b[?2004h") != null);
    try std.testing.expect(std.mem.find(u8, sequence, "\x1b[?7l") != null);
}

test "interactive mode leaves native terminal scrollback enabled" {
    for ([_]?[]const u8{ null, "" }) |tmux| {
        const sequence = interactiveModeEnableSequence(tmux);
        try std.testing.expect(std.mem.find(u8, sequence, "\x1b[?1000h") == null);
        try std.testing.expect(std.mem.find(u8, sequence, "\x1b[?1002h") == null);
        try std.testing.expect(std.mem.find(u8, sequence, "\x1b[?1006h") == null);
    }
}
