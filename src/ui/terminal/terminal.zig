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
    var seen: Gathered = .{ .character_device = stat.kind == .character_device };
    while (true) {
        switch (goneStep(seen)) {
            .gone => return true,
            .not_gone => return false,
            .need_null_device => seen.null_device = isNullDevice(fd),
            .need_first_poll => seen.hangup_at_first_poll = pollGoneFlags(fd) catch return false,
            .need_foreground => seen.foreign_foreground = foreignForeground(fd),
            // A failed isatty proves nothing, so the descriptor counts as a terminal still.
            .need_still_terminal => seen.still_terminal = file.isTty(io_mod.getIo()) catch true,
            .check_again => {
                // Error path only: teardown can raise EIO before POLLHUP/POLLNVAL appears (`tests/tla/terminal_hangup/TerminalHangup.tla` `GoneIsQuiet`).
                io_mod.sleep(@as(u64, @intCast(hangup_sign_wait_ms)) * std.time.ns_per_ms);
                seen.hangup_at_second_poll = pollGoneFlags(fd) catch return false;
            },
        }
    }
}

/// The poll flags that mean the terminal hung up, was revoked, or was invalidated.
const gone_poll_flags = std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL;

/// Whether a `POLL.OUT` poll of `fd` shows a hang-up, an error, or an invalid descriptor.
/// macOS XNU poll with events=0 reports no flags on a closed pty; POLL.OUT surfaces POLLHUP and POLLNVAL.
fn pollGoneFlags(fd: std.posix.fd_t) !bool {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
    _ = try std.posix.poll(&fds, 0);
    return (fds[0].revents & gone_poll_flags) != 0;
}

/// Whether another process group holds the terminal's foreground.
fn foreignForeground(fd: std.posix.fd_t) bool {
    const fg_pgid = tcgetpgrp(fd);
    return fg_pgid > 0 and fg_pgid != getpgrp();
}

/// Whether terminal `fd` hung up when a read hit EOF (`0`) or `poll` reported
/// `POLLHUP`/`POLLERR`/`POLLNVAL` (`tests/tla/cli_hangup/CliHangup.tla` `GoneIsQuiet`).
pub fn terminalInputGone(fd: std.posix.fd_t) bool {
    return terminalGone(fd, error.InputOutput);
}

/// The observations `terminalGone` has gathered so far. A null field is not gathered yet.
const Gathered = struct {
    character_device: bool,
    null_device: ?bool = null,
    hangup_at_first_poll: ?bool = null,
    foreign_foreground: ?bool = null,
    still_terminal: ?bool = null,
    hangup_at_second_poll: ?bool = null,
};

/// What `terminalGone` does next: a verdict, the wait before the second poll, or one observation to gather.
const GoneStep = enum {
    gone,
    not_gone,
    check_again,
    need_null_device,
    need_first_poll,
    need_foreground,
    need_still_terminal,
};

/// Decides as far as the gathered observations allow, in the order `terminalGone` checks them.
/// A rule that decides returns before any later observation is needed.
fn goneStep(seen: Gathered) GoneStep {
    if (!seen.character_device) return .not_gone;
    const is_null_device = seen.null_device orelse return .need_null_device;
    if (is_null_device) return .not_gone;
    const hangup_first = seen.hangup_at_first_poll orelse return .need_first_poll;
    if (hangup_first) return .gone;
    const foreign = seen.foreign_foreground orelse return .need_foreground;
    if (foreign) return .gone;
    // macOS 15 polls a revoked terminal as readable only, so the poll flags miss it; a descriptor that is no longer a terminal is gone.
    const still = seen.still_terminal orelse return .need_still_terminal;
    if (!still) return .gone;
    const hangup_second = seen.hangup_at_second_poll orelse return .check_again;
    return if (hangup_second) .gone else .not_gone;
}

test "a file, pipe, or other non-device is not gone, without any poll" {
    try std.testing.expectEqual(GoneStep.not_gone, goneStep(.{ .character_device = false }));
}

test "a failed read on /dev/null is not gone, without any poll" {
    try std.testing.expectEqual(GoneStep.not_gone, goneStep(.{ .character_device = true, .null_device = true }));
}

test "a character device that is not /dev/null asks for its first poll next" {
    try std.testing.expectEqual(GoneStep.need_first_poll, goneStep(.{ .character_device = true, .null_device = false }));
}

test "a hang-up at the first poll is gone, without the foreground, terminal, or second check" {
    try std.testing.expectEqual(GoneStep.gone, goneStep(.{
        .character_device = true,
        .null_device = false,
        .hangup_at_first_poll = true,
    }));
}

test "no hang-up at the first poll asks for the foreground group next" {
    try std.testing.expectEqual(GoneStep.need_foreground, goneStep(.{
        .character_device = true,
        .null_device = false,
        .hangup_at_first_poll = false,
    }));
}

test "a foreign foreground group is gone, without the terminal or second check" {
    try std.testing.expectEqual(GoneStep.gone, goneStep(.{
        .character_device = true,
        .null_device = false,
        .hangup_at_first_poll = false,
        .foreign_foreground = true,
    }));
}

test "our own foreground group asks whether the descriptor is still a terminal" {
    try std.testing.expectEqual(GoneStep.need_still_terminal, goneStep(.{
        .character_device = true,
        .null_device = false,
        .hangup_at_first_poll = false,
        .foreign_foreground = false,
    }));
}

test "EIO, poll shows only readable, the fd is no longer a terminal: gone, without the second check" {
    try std.testing.expectEqual(GoneStep.gone, goneStep(.{
        .character_device = true,
        .null_device = false,
        .hangup_at_first_poll = false,
        .foreign_foreground = false,
        .still_terminal = false,
    }));
}

test "EIO, still a terminal, no flags: wait and poll again" {
    try std.testing.expectEqual(GoneStep.check_again, goneStep(.{
        .character_device = true,
        .null_device = false,
        .hangup_at_first_poll = false,
        .foreign_foreground = false,
        .still_terminal = true,
    }));
}

test "EIO, still a terminal, the second poll shows a hang-up: gone" {
    try std.testing.expectEqual(GoneStep.gone, goneStep(.{
        .character_device = true,
        .null_device = false,
        .hangup_at_first_poll = false,
        .foreign_foreground = false,
        .still_terminal = true,
        .hangup_at_second_poll = true,
    }));
}

test "EIO, still a terminal, the second poll shows only readable: not gone" {
    try std.testing.expectEqual(GoneStep.not_gone, goneStep(.{
        .character_device = true,
        .null_device = false,
        .hangup_at_first_poll = false,
        .foreign_foreground = false,
        .still_terminal = true,
        .hangup_at_second_poll = false,
    }));
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
