const builtin = @import("builtin");
const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const types = @import("../../core/shared/types.zig");

/// Bounded re-poll delay when `EIO` surfaces before `POLLHUP`/`POLLNVAL`.
pub const hangup_sign_wait_ms: i32 = 5;

extern "c" fn tcgetpgrp(fd: std.posix.fd_t) std.posix.pid_t;
extern "c" fn getpgrp() std.posix.pid_t;

var null_device_mutex: std.Io.Mutex = .init;
var null_device_read = false;
var null_device: ?u64 = null;

/// The device number of /dev/null, read once and kept. Null when it cannot be read.
fn nullDevice() ?u64 {
    const zio = io_mod.getIo();
    null_device_mutex.lockUncancelable(zio);
    defer null_device_mutex.unlock(zio);
    if (!null_device_read) {
        null_device_read = true;
        null_device = pathDeviceNumber("/dev/null");
    }
    return null_device;
}

/// /dev/null is an open character device that macOS poll reports as POLLNVAL,
/// and it never hangs up. Its device number tells it apart from a terminal: an
/// inode number repeats across file systems, so a pty can share /dev/null's.
fn isNullDevice(fd: std.posix.fd_t) bool {
    const null_number = nullDevice() orelse return false;
    const fd_number = fdDeviceNumber(fd) orelse return false;
    return fd_number == null_number;
}

/// The device number of an open descriptor. Zig's std has no libc stat
/// structure on Linux, so Linux asks statx for the device numbers.
fn fdDeviceNumber(fd: std.posix.fd_t) ?u64 {
    if (comptime builtin.target.os.tag == .linux) {
        var buf = std.mem.zeroes(std.os.linux.Statx);
        const flags = std.os.linux.AT.EMPTY_PATH;
        if (std.os.linux.errno(std.os.linux.statx(fd, "", flags, std.os.linux.STATX.BASIC_STATS, &buf)) != .SUCCESS) return null;
        return linuxDeviceNumber(buf.rdev_major, buf.rdev_minor);
    }
    var st = std.mem.zeroes(std.c.Stat);
    if (std.c.fstat(fd, &st) != 0) return null;
    return @as(u32, @bitCast(st.rdev));
}

/// The device number of a path, followed through symbolic links.
fn pathDeviceNumber(path: [*:0]const u8) ?u64 {
    if (comptime builtin.target.os.tag == .linux) {
        var buf = std.mem.zeroes(std.os.linux.Statx);
        if (std.os.linux.errno(std.os.linux.statx(std.os.linux.AT.FDCWD, path, 0, std.os.linux.STATX.BASIC_STATS, &buf)) != .SUCCESS) return null;
        return linuxDeviceNumber(buf.rdev_major, buf.rdev_minor);
    }
    var st = std.mem.zeroes(std.c.Stat);
    if (std.c.stat(path, &st) != 0) return null;
    return @as(u32, @bitCast(st.rdev));
}

fn linuxDeviceNumber(major: u32, minor: u32) u64 {
    return (@as(u64, major) << 32) | minor;
}

/// Whether `err` on terminal `fd` happened because the terminal hung up, was
/// revoked, or no longer has fx's process group in the foreground
/// (`tests/tla/terminal_hangup/TerminalHangup.tla` `GoneIsQuiet`).
pub fn terminalGone(fd: std.posix.fd_t, err: anyerror) bool {
    if (comptime builtin.target.os.tag == .wasi) return false;
    if (err != error.InputOutput) return false;
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    // A descriptor that cannot be stat'ed is closed, so no terminal is left to hang up.
    const stat = file.stat(io_mod.getIo()) catch return true;
    // Only a character device hangs up like a terminal. A pipe or a file never does, even after its writer closed.
    if (stat.kind != .character_device) return false;
    if (isNullDevice(fd)) return false;
    // macOS XNU poll with events=0 reports no flags on a closed pty; POLL.OUT surfaces POLLHUP and POLLNVAL.
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    const gone_mask = std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;
    _ = std.posix.poll(&fds, 0) catch return false;
    if ((fds[0].revents & gone_mask) != 0) return true;
    const fg_pgid = tcgetpgrp(fd);
    if (fg_pgid > 0 and fg_pgid != getpgrp()) return true;
    // Error path only: teardown can raise EIO before POLLHUP/POLLNVAL appears (`tests/tla/terminal_hangup/TerminalHangup.tla` `GoneIsQuiet`).
    io_mod.sleep(@as(u64, @intCast(hangup_sign_wait_ms)) * std.time.ns_per_ms);
    fds[0].revents = 0;
    _ = std.posix.poll(&fds, 0) catch return false;
    return (fds[0].revents & gone_mask) != 0;
}

/// Whether terminal `fd` hung up when a read hit EOF (`0`) or `poll` reported
/// `POLLHUP`/`POLLERR`/`POLLNVAL` (`tests/tla/cli_hangup/CliHangup.tla` `GoneIsQuiet`).
pub fn terminalInputGone(fd: std.posix.fd_t) bool {
    return terminalGone(fd, error.InputOutput);
}

pub const interactive_mode_enable_sequence = "\x1b[>4;2m\x1b[>1u\x1b[?2004h\x1b[?7l";
const tmux_interactive_mode_enable_sequence = "\x1b[>4;2m\x1b[?2004h\x1b[?7l";
pub const bracketed_paste_enable_sequence = "\x1b[?2004h";
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
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };

    const req: c_int = @intCast(std.c.T.IOCGWINSZ);
    const rc = std.c.ioctl(fd, req, &ws);
    if (rc == -1 or ws.row == 0 or ws.col == 0) {
        return error.UnableToReadTerminalSize;
    }
    return layoutFromSize(ws.row, ws.col, footer_rows);
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
    return std.mem.print(buf, "\x1b[{d};{d}H", .{ row, col });
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

test "terminalGone returns true for InputOutput on a closed TestPty" {
    const shell_runtime = @import("../shell_runtime.zig");
    if (!shell_runtime.supports_test_pty) return error.SkipZigTest;

    const pty = try shell_runtime.TestPty.open();
    var master: ?std.Io.File = .{ .handle = pty.master, .flags = .{ .nonblocking = false } };
    defer if (master) |file| file.close(io_mod.getIo());
    const slave: std.Io.File = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
    defer slave.close(io_mod.getIo());

    master.?.close(io_mod.getIo());
    master = null;
    try std.testing.expect(terminalGone(slave.handle, error.InputOutput));
}

test "terminalGone returns false for InputOutput on an open TestPty" {
    const shell_runtime = @import("../shell_runtime.zig");
    if (!shell_runtime.supports_test_pty) return error.SkipZigTest;

    const pty = try shell_runtime.TestPty.open();
    const master: std.Io.File = .{ .handle = pty.master, .flags = .{ .nonblocking = false } };
    defer master.close(io_mod.getIo());
    const slave: std.Io.File = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
    defer slave.close(io_mod.getIo());

    try std.testing.expect(!terminalGone(slave.handle, error.InputOutput));
}

test "terminalGone returns false for non-InputOutput errors" {
    const shell_runtime = @import("../shell_runtime.zig");
    if (!shell_runtime.supports_test_pty) return error.SkipZigTest;

    const pty = try shell_runtime.TestPty.open();
    var master: ?std.Io.File = .{ .handle = pty.master, .flags = .{ .nonblocking = false } };
    defer if (master) |file| file.close(io_mod.getIo());
    const slave: std.Io.File = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
    defer slave.close(io_mod.getIo());

    master.?.close(io_mod.getIo());
    master = null;
    try std.testing.expect(!terminalGone(slave.handle, error.BrokenPipe));
}

test "terminalInputGone returns true on a closed TestPty and false on an open TestPty or file" {
    const shell_runtime = @import("../shell_runtime.zig");
    if (!shell_runtime.supports_test_pty) return error.SkipZigTest;

    const pty = try shell_runtime.TestPty.open();
    var master: ?std.Io.File = .{ .handle = pty.master, .flags = .{ .nonblocking = false } };
    defer if (master) |file| file.close(io_mod.getIo());
    const slave: std.Io.File = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
    defer slave.close(io_mod.getIo());

    try std.testing.expect(!terminalInputGone(slave.handle));
    master.?.close(io_mod.getIo());
    master = null;
    try std.testing.expect(terminalInputGone(slave.handle));
    try std.testing.expect(terminalGone(slave.handle, error.InputOutput));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "regular.txt", .{ .read = true });
    defer file.close(io_mod.getIo());
    try std.testing.expect(!terminalInputGone(file.handle));
}

test "terminalGone and terminalInputGone are false for a pipe whose writer closed" {
    const pipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer _ = std.c.close(pipe[0]);
    _ = std.c.close(pipe[1]);

    try std.testing.expect(!terminalGone(pipe[0], error.InputOutput));
    try std.testing.expect(!terminalInputGone(pipe[0]));
}

test "terminalGone and terminalInputGone are false for a regular file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "plain.txt", .{ .read = true });
    defer file.close(io_mod.getIo());

    try std.testing.expect(!terminalGone(file.handle, error.InputOutput));
    try std.testing.expect(!terminalInputGone(file.handle));
}

test "terminalInputGone is false for /dev/null, which macOS poll reports as POLLNVAL" {
    const null_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{});
    defer null_file.close(io_mod.getIo());

    try std.testing.expect(!terminalGone(null_file.handle, error.InputOutput));
    try std.testing.expect(!terminalInputGone(null_file.handle));
}

test "isNullDevice matches /dev/null by device number, so no pty counts as /dev/null" {
    const shell_runtime = @import("../shell_runtime.zig");
    if (!shell_runtime.supports_test_pty) return error.SkipZigTest;

    const null_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{});
    defer null_file.close(io_mod.getIo());
    try std.testing.expect(isNullDevice(null_file.handle));

    // Three ptys stay open, so one may share /dev/null's inode number on Linux: only the device number may tell them apart.
    const first = try shell_runtime.TestPty.open();
    defer {
        _ = std.c.close(first.master);
        _ = std.c.close(first.slave);
    }
    const second = try shell_runtime.TestPty.open();
    defer {
        _ = std.c.close(second.master);
        _ = std.c.close(second.slave);
    }
    const third = try shell_runtime.TestPty.open();
    defer {
        _ = std.c.close(third.master);
        _ = std.c.close(third.slave);
    }
    try std.testing.expect(!isNullDevice(first.slave));
    try std.testing.expect(!isNullDevice(second.slave));
    try std.testing.expect(!isNullDevice(third.slave));
}

test "terminalGone returns true when a foreign foreground group owns the terminal" {
    const shell_runtime = @import("../shell_runtime.zig");
    if (!shell_runtime.supports_test_pty) return error.SkipZigTest;
    if (comptime builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;

    const ioctl_sctty: c_int = switch (builtin.target.os.tag) {
        .macos => 0x20007461,
        .linux => @intCast(std.os.linux.T.IOCSCTTY),
        else => unreachable,
    };
    const pty = try shell_runtime.TestPty.open();
    const master: std.Io.File = .{ .handle = pty.master, .flags = .{ .nonblocking = false } };
    defer master.close(io_mod.getIo());
    const slave: std.Io.File = .{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
    defer slave.close(io_mod.getIo());

    const res_pipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    errdefer {
        _ = std.c.close(res_pipe[0]);
        _ = std.c.close(res_pipe[1]);
    }
    const done_pipe = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    errdefer {
        _ = std.c.close(done_pipe[0]);
        _ = std.c.close(done_pipe[1]);
    }

    const p1 = std.c.fork();
    if (p1 < 0) return error.Unexpected;
    if (p1 == 0) {
        _ = std.c.close(pty.master);
        _ = std.c.close(res_pipe[0]);
        _ = std.c.close(done_pipe[1]);
        _ = std.c.setsid();
        _ = std.c.ioctl(pty.slave, ioctl_sctty, @as(c_int, 0));

        const p2 = std.c.fork();
        if (p2 < 0) std.c._exit(2);
        if (p2 == 0) {
            _ = std.c.setpgid(0, 0);
            const msg: []const u8 = if (terminalGone(pty.slave, error.InputOutput)) "OK" else "FAIL";
            _ = std.c.write(res_pipe[1], msg.ptr, msg.len);
            std.c._exit(0);
        }
        _ = std.c.close(res_pipe[1]);
        var st: c_int = 0;
        _ = std.c.waitpid(p2, &st, 0);
        var wait_done: [1]u8 = undefined;
        while (true) {
            const r = std.c.read(done_pipe[0], &wait_done, 1);
            if (r == 0) break;
            if (r < 0 and std.posix.errno(r) == .INTR) continue;
            break;
        }
        _ = std.c.close(done_pipe[0]);
        std.c._exit(0);
    }

    _ = std.c.close(res_pipe[1]);
    _ = std.c.close(done_pipe[0]);

    var msg_buf: [16]u8 = undefined;
    var msg_len: usize = 0;
    while (msg_len < msg_buf.len) {
        const n = std.c.read(res_pipe[0], msg_buf[msg_len..].ptr, msg_buf.len - msg_len);
        if (n == 0) break;
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            break;
        }
        msg_len += @intCast(n);
    }
    _ = std.c.close(res_pipe[0]);
    _ = std.c.close(done_pipe[1]);
    var st: c_int = 0;
    _ = std.c.waitpid(p1, &st, 0);

    try std.testing.expectEqualStrings("OK", msg_buf[0..msg_len]);
}
