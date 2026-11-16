//! The standard variables that describe the user's terminal: `NO_COLOR`
//! (no-color.org) and `TERM=dumb`. Every output path asks these, so help,
//! `fx ask`, and the interactive session agree.

const builtin = @import("builtin");
const std = @import("std");
const io_mod = @import("io.zig");

/// `NO_COLOR` set to anything but the empty string turns color off.
pub fn noColorValue(value: ?[]const u8) bool {
    const set = value orelse return false;
    return set.len > 0;
}

/// `TERM=dumb` names a terminal without color or cursor movement.
pub fn dumbTerminalValue(value: ?[]const u8) bool {
    const term = value orelse return false;
    return std.mem.eql(u8, term, "dumb");
}

pub fn noColor() bool {
    return noColorValue(io_mod.getenv("NO_COLOR"));
}

pub fn dumbTerminal() bool {
    return dumbTerminalValue(io_mod.getenv("TERM"));
}

/// Color is off when either variable says so.
pub fn colorDisabled() bool {
    return noColor() or dumbTerminal();
}

/// Whether stdout is a terminal, not a pipe or a file.
pub fn stdoutIsTerminal() bool {
    if (comptime builtin.target.os.tag == .windows or !builtin.link_libc) return false;
    return std.c.isatty(std.posix.STDOUT_FILENO) != 0;
}

/// The width of the terminal stdout writes to, in columns; null when stdout
/// is not a terminal or the terminal does not say.
pub fn stdoutColumns() ?usize {
    return terminalColumns(std.posix.STDOUT_FILENO);
}

/// `stdoutColumns`, for the terminal stderr writes to.
pub fn stderrColumns() ?usize {
    return terminalColumns(std.posix.STDERR_FILENO);
}

fn terminalColumns(fd: std.posix.fd_t) ?usize {
    if (comptime builtin.target.os.tag == .windows or !builtin.link_libc) return null;

    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const req: c_int = @intCast(std.c.T.IOCGWINSZ);
    const rc = std.c.ioctl(fd, req, &ws);
    if (rc == -1 or ws.col == 0) return null;
    return @intCast(ws.col);
}

test "NO_COLOR counts only when it is set to something" {
    try std.testing.expect(noColorValue("1"));
    try std.testing.expect(noColorValue("0"));
    try std.testing.expect(!noColorValue(""));
    try std.testing.expect(!noColorValue(null));
}

test "only TERM=dumb is a dumb terminal" {
    try std.testing.expect(dumbTerminalValue("dumb"));
    try std.testing.expect(!dumbTerminalValue("xterm-256color"));
    try std.testing.expect(!dumbTerminalValue("dumb-ish"));
    try std.testing.expect(!dumbTerminalValue(null));
}
