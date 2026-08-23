const std = @import("std");

const windows = std.os.windows;

const enable_processed_input: windows.DWORD = 0x0001;
const enable_line_input: windows.DWORD = 0x0002;
const enable_echo_input: windows.DWORD = 0x0004;
const enable_window_input: windows.DWORD = 0x0008;
const enable_quick_edit_mode: windows.DWORD = 0x0040;
const enable_extended_flags: windows.DWORD = 0x0080;
const enable_virtual_terminal_input: windows.DWORD = 0x0200;
const enable_virtual_terminal_processing: windows.DWORD = 0x0004;

const wait_object_0: windows.DWORD = 0;
const wait_timeout: windows.DWORD = 258;
const wait_failed: windows.DWORD = 0xffffffff;

const Coord = extern struct {
    x: i16,
    y: i16,
};

const SmallRect = extern struct {
    left: i16,
    top: i16,
    right: i16,
    bottom: i16,
};

const ConsoleScreenBufferInfo = extern struct {
    size: Coord,
    cursor_position: Coord,
    attributes: u16,
    window: SmallRect,
    maximum_window_size: Coord,
};

pub const Mode = struct {
    input: windows.DWORD,
    output: windows.DWORD,
};

pub const Size = struct {
    rows: u16,
    cols: u16,
};

pub const WaitResult = enum {
    ready,
    timeout,
};

const ControlHandler = ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL;
var saved_input: ?windows.HANDLE = null;
var saved_output: ?windows.HANDLE = null;
var saved_mode: ?Mode = null;
var control_handler_installed = false;

extern "kernel32" fn GetConsoleMode(
    handle: windows.HANDLE,
    mode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetConsoleMode(
    handle: windows.HANDLE,
    mode: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetConsoleScreenBufferInfo(
    handle: windows.HANDLE,
    info: *ConsoleScreenBufferInfo,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn WaitForSingleObject(
    handle: windows.HANDLE,
    milliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ControlHandler,
    add: windows.BOOL,
) callconv(.winapi) windows.BOOL;

fn restoreForControlEvent(_: windows.DWORD) callconv(.winapi) windows.BOOL {
    if (saved_mode) |mode| {
        if (saved_input) |input| _ = SetConsoleMode(input, mode.input);
        if (saved_output) |output| _ = SetConsoleMode(output, mode.output);
    }
    return .FALSE;
}

pub fn isConsole(handle: windows.HANDLE) bool {
    var mode: windows.DWORD = 0;
    return GetConsoleMode(handle, &mode).toBool();
}

pub fn captureMode(input: windows.HANDLE, output: windows.HANDLE) !Mode {
    var input_mode: windows.DWORD = 0;
    var output_mode: windows.DWORD = 0;
    if (!GetConsoleMode(input, &input_mode).toBool() or
        !GetConsoleMode(output, &output_mode).toBool())
    {
        return error.NotATerminal;
    }
    return .{ .input = input_mode, .output = output_mode };
}

pub fn rawInputMode(original: windows.DWORD) windows.DWORD {
    return (original |
        enable_window_input |
        enable_extended_flags |
        enable_virtual_terminal_input) &
        ~(enable_processed_input |
            enable_line_input |
            enable_echo_input |
            enable_quick_edit_mode);
}

pub fn enableRawMode(input: windows.HANDLE, output: windows.HANDLE, original: Mode) !void {
    const input_mode = rawInputMode(original.input);
    if (!SetConsoleMode(input, input_mode).toBool()) return error.ConsoleModeUnavailable;
    errdefer _ = SetConsoleMode(input, original.input);

    const output_mode = original.output | enable_virtual_terminal_processing;
    if (!SetConsoleMode(output, output_mode).toBool()) return error.ConsoleModeUnavailable;
    saved_input = input;
    saved_output = output;
    saved_mode = original;
    if (!SetConsoleCtrlHandler(restoreForControlEvent, .TRUE).toBool()) {
        saved_input = null;
        saved_output = null;
        saved_mode = null;
        return error.ConsoleModeUnavailable;
    }
    control_handler_installed = true;
}

pub fn restoreMode(input: windows.HANDLE, output: windows.HANDLE, original: Mode) void {
    if (control_handler_installed) {
        _ = SetConsoleCtrlHandler(restoreForControlEvent, .FALSE);
        control_handler_installed = false;
    }
    saved_input = null;
    saved_output = null;
    saved_mode = null;
    _ = SetConsoleMode(input, original.input);
    _ = SetConsoleMode(output, original.output);
}

pub fn querySize(output: windows.HANDLE) !Size {
    var info: ConsoleScreenBufferInfo = undefined;
    if (!GetConsoleScreenBufferInfo(output, &info).toBool()) {
        return error.UnableToReadTerminalSize;
    }
    const cols = @as(i32, info.window.right) - @as(i32, info.window.left) + 1;
    const rows = @as(i32, info.window.bottom) - @as(i32, info.window.top) + 1;
    if (cols <= 0 or rows <= 0 or
        cols > std.math.maxInt(u16) or rows > std.math.maxInt(u16))
    {
        return error.UnableToReadTerminalSize;
    }
    return .{ .rows = @intCast(rows), .cols = @intCast(cols) };
}

pub fn waitForInput(input: windows.HANDLE, timeout_ms: i32) !WaitResult {
    const timeout: windows.DWORD = if (timeout_ms < 0)
        std.math.maxInt(windows.DWORD)
    else
        @intCast(timeout_ms);
    return switch (WaitForSingleObject(input, timeout)) {
        wait_object_0 => .ready,
        wait_timeout => .timeout,
        wait_failed => error.ConsoleWaitFailed,
        else => error.ConsoleWaitFailed,
    };
}

test "raw input mode enables VT events and disables cooked input" {
    const original = enable_processed_input |
        enable_line_input |
        enable_echo_input |
        enable_quick_edit_mode;
    const mode = rawInputMode(original);
    try std.testing.expect(mode & enable_window_input != 0);
    try std.testing.expect(mode & enable_extended_flags != 0);
    try std.testing.expect(mode & enable_virtual_terminal_input != 0);
    try std.testing.expect(mode & enable_processed_input == 0);
    try std.testing.expect(mode & enable_line_input == 0);
    try std.testing.expect(mode & enable_echo_input == 0);
    try std.testing.expect(mode & enable_quick_edit_mode == 0);
}
