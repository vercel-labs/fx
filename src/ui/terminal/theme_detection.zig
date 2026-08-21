const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../../core/shared/io.zig");
const shell_runtime = @import("../shell_runtime.zig");
const terminal_sequences = @import("terminal.zig");
const theme_protocol = @import("theme_protocol.zig");

pub const Detection = struct {
    light: bool,
    rgb: ?theme_protocol.Rgb,
};

pub const TerminalBackground = theme_protocol.Background;

pub fn explicitThemeOverride() ?bool {
    const override = io_mod.getenv("FX_THEME") orelse return null;
    if (std.ascii.eqlIgnoreCase(override, "light")) return true;
    if (std.ascii.eqlIgnoreCase(override, "dark")) return false;
    return null;
}

pub fn detectTheme(_: std.mem.Allocator, terminal_state: *const shell_runtime.TerminalState) Detection {
    if (explicitThemeOverride()) |light| return .{ .light = light, .rgb = null };
    if (comptime builtin.os.tag == .wasi or builtin.os.tag == .windows) return .{ .light = false, .rgb = null };

    // One probe derives both light/dark and the RGB used for bar shading.
    if (queryTerminalBackground(terminal_state)) |info| {
        return .{ .light = info.light, .rgb = info.rgb };
    }

    const colorfgbg = io_mod.getenv("COLORFGBG");
    if (colorfgbg) |value| {
        if (theme_protocol.parseColorFgBgLight(value)) return .{ .light = true, .rgb = null };
    }

    return .{ .light = false, .rgb = null };
}

fn queryTerminalBackground(terminal_state: *const shell_runtime.TerminalState) ?TerminalBackground {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io_mod.getIo(), terminal_sequences.theme_background_query) catch return null;

    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const deadline_ms = io_mod.milliTimestamp() + 200;

    while (len < buf.len) {
        const now_ms = io_mod.milliTimestamp();
        if (now_ms >= deadline_ms) break;

        const remaining_ms: i32 = @intCast(deadline_ms - now_ms);
        const poll = terminal_state.pollInput(remaining_ms) catch return null;
        if (poll.closed() or !poll.readable) break;

        const n = terminal_state.read(buf[len .. len + 1]) catch return null;
        if (n == 0) break;
        len += n;
        if (buf[len - 1] == '\\' or buf[len - 1] == 0x07) break;
    }

    return theme_protocol.parseOsc11Response(buf[0..len]);
}
