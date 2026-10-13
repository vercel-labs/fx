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

/// FX_THEME values other than light/dark name a user theme under
/// `~/.fx/themes/<name>.json`.
pub fn explicitThemeName() ?[]const u8 {
    const override = io_mod.getenv("FX_THEME") orelse return null;
    if (override.len == 0) return null;
    if (explicitThemeOverride() != null) return null;
    return override;
}

pub fn detectTheme(_: std.mem.Allocator, terminal_state: *const shell_runtime.TerminalState) Detection {
    if (explicitThemeOverride()) |light| return .{ .light = light, .rgb = null };
    if (comptime builtin.target.os.tag == .wasi) return .{ .light = false, .rgb = null };

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

/// Terminals answer queries in order, so the device attributes fence after
/// the background query arrives last. A terminal that ignores the background
/// query then costs one round trip instead of the whole timeout, which stays
/// only for terminals that answer neither.
fn queryTerminalBackground(terminal_state: *const shell_runtime.TerminalState) ?TerminalBackground {
    var stdout_file = std.Io.File.stdout();
    stdout_file.writeStreamingAll(io_mod.getIo(), terminal_sequences.theme_background_query_with_fence) catch return null;

    // Room for the longest background reply plus a full device attributes list.
    var buf: [192]u8 = undefined;
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
        switch (fencedBackgroundReply(buf[0..len])) {
            .pending => {},
            .done => |background| return background,
        }
    }

    return theme_protocol.parseOsc11Response(buf[0..len]);
}

const FencedReply = union(enum) {
    pending,
    /// The fence arrived; null when no background reply preceded it.
    done: ?TerminalBackground,
};

fn fencedBackgroundReply(bytes: []const u8) FencedReply {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 'c') return .pending;
    const fence_start = theme_protocol.trailingPrimaryDeviceAttributes(bytes) orelse return .pending;
    return .{ .done = theme_protocol.parseOsc11Response(bytes[0..fence_start]) };
}

test "the device attributes fence ends the background probe" {
    const dark = fencedBackgroundReply("\x1b]11;rgb:1c1c/1c1c/1c1c\x1b\\\x1b[?62;22c");
    try std.testing.expect(!dark.done.?.light);
    const light = fencedBackgroundReply("\x1b]11;rgb:ffff/ffff/ffff\x07\x1b[?1;2c");
    try std.testing.expect(light.done.?.light);
    // A terminal without OSC 11 answers only the fence.
    try std.testing.expectEqual(@as(?TerminalBackground, null), fencedBackgroundReply("\x1b[?62;22c").done);
}

test "the background probe keeps reading until the fence completes" {
    // Hex digits end in "c" without a fence.
    try std.testing.expect(fencedBackgroundReply("\x1b]11;rgb:cccc/cccc/cc") == .pending);
    try std.testing.expect(fencedBackgroundReply("\x1b]11;rgb:cccc/cccc/cccc\x1b\\") == .pending);
    try std.testing.expect(fencedBackgroundReply("\x1b]11;rgb:cccc/cccc/cccc\x1b\\\x1b[?62;2") == .pending);
    try std.testing.expect(fencedBackgroundReply("") == .pending);
}
