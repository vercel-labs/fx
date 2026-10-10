//! One terminal: a child process on its own PTY.
//!
//! `open` starts the child in a new session, with the PTY as its controlling
//! terminal. The owner reads the child's output, writes to it, resizes it
//! and closes it. The terminal does not interpret what runs inside: the
//! owner feeds the output to its own emulator and writes the emulator's
//! query replies back with `write`.
//!
//! The child also inherits one end of a report channel, a socket pair named
//! in its environment (see `report_env`). A program that knows about it
//! writes lines there for the owner, apart from what it draws on the screen,
//! and reads the owner's replies from it.
//!
//! Not thread-safe. One owner calls every method.

const std = @import("std");
const builtin = @import("builtin");
const core_mod = @import("terminal_core.zig");
const fd_ops = @import("fd.zig");
const report_env = @import("report_env.zig");

const Allocator = std.mem.Allocator;
const fd_t = std.posix.fd_t;

pub const Exit = core_mod.Exit;

/// The longest line `Terminal.reply` sends, without its newline.
pub const max_reply_line = core_mod.max_reply_line;

/// How long `close` waits for the child to exit after the hangup before it
/// kills the child's process group.
pub const close_grace_ms: u32 = 1000;
const close_poll_ms: u32 = 10;
/// How long `open` waits for the child to report its exec. Exec closes the
/// launch pipe within milliseconds; the bound matters when another process
/// inherited the pipe's write end and keeps the pipe open.
const launch_timeout_ms: u32 = 5000;

pub const Options = struct {
    /// The program and its arguments. A program without a '/' is looked up
    /// in the PATH entry of `env`.
    argv: []const []const u8,
    /// The child's whole environment, as "NAME=value" entries. The terminal
    /// replaces any `SUB_ENGINE_REPORT` entry with its own.
    env: []const []const u8,
    /// The child's working directory. Null keeps the caller's.
    cwd: ?[]const u8 = null,
    cols: u16,
    rows: u16,
};

pub const OpenError = error{
    /// Empty argv, or a zero size.
    InvalidOptions,
    ProgramNotFound,
    AccessDenied,
    CwdUnavailable,
    ExecFailed,
    /// The child could not make the PTY its controlling terminal.
    SetupFailed,
    /// The PTY, or a pipe the child needs, could not be created.
    PtyUnavailable,
    ForkFailed,
    /// The child did not report its exec within `launch_timeout_ms`, so
    /// open killed it.
    LaunchTimedOut,
    OutOfMemory,
};

pub const ReadResult = union(enum) {
    /// Output from the child, a slice of the caller's buffer.
    data: []u8,
    /// Nothing to read right now.
    empty,
    /// The child's side of the PTY is gone. Nothing more will arrive.
    ended,
};

pub const CloseReport = struct {
    exit: Exit,
    /// Unsent bytes, PTY input and replies, that close dropped.
    dropped_bytes: usize,
    /// Report lines the pool dropped over the terminal's life (see
    /// `Sink.report`). Always zero from `Terminal.close`, whose owner frames
    /// report lines itself.
    dropped_report_lines: usize,
};

pub const Terminal = struct {
    gpa: Allocator,
    core: core_mod.Core,
    master: fd_t,
    /// The owner's end of the child's report channel.
    report: fd_t,
    pid: std.c.pid_t,
    /// Unsent bytes that `hangUp` dropped, for the close report.
    dropped: usize = 0,

    /// Starts `options.argv` on a new PTY. On success the child is running
    /// and the caller must eventually call `close`.
    pub fn open(gpa: Allocator, options: Options) OpenError!Terminal {
        if (options.argv.len == 0 or options.cols == 0 or options.rows == 0) {
            return error.InvalidOptions;
        }
        // Everything the child needs is prepared before fork, because the
        // child may only make async-signal-safe calls until exec.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const program = try resolveProgram(arena, options.argv[0], envValue(options.env, "PATH"));
        const argv = try nullTerminated(arena, options.argv);
        const cwd: ?[*:0]const u8 = if (options.cwd) |dir| (try arena.dupeZ(u8, dir)).ptr else null;

        const pty = try openPty(options.cols, options.rows);
        errdefer fd_ops.close(pty.master);
        defer fd_ops.close(pty.slave);
        const report = fd_ops.socketPair() catch return error.PtyUnavailable;
        errdefer fd_ops.close(report.parent);
        // Only the child keeps its end, so the owner sees the end of the
        // channel once every process holding it is gone.
        defer fd_ops.close(report.child);
        const report_entry = try report_env.entry(arena, report.child) orelse return error.PtyUnavailable;
        const envp = try childEnv(arena, options.env, report_entry);
        const launch = fd_ops.pipe(.{}) catch return error.PtyUnavailable;
        defer fd_ops.close(launch.read);

        const pid = std.c.fork();
        if (pid < 0) {
            fd_ops.close(launch.write);
            return error.ForkFailed;
        }
        if (pid == 0) execChild(pty, report.child, launch.write, program, argv, envp, cwd);
        fd_ops.close(launch.write);

        awaitLaunch(launch.read, launch_timeout_ms) catch |err| {
            if (err == error.LaunchTimedOut) {
                // The child may be anywhere from before its setsid to
                // running the program, so both it and its group are killed.
                _ = std.c.kill(-pid, std.c.SIG.KILL);
                _ = std.c.kill(pid, std.c.SIG.KILL);
            }
            waitBlocking(pid);
            return err;
        };
        return .{ .gpa = gpa, .core = .{}, .master = pty.master, .report = report.parent, .pid = pid };
    }

    /// The PTY master, for the owner's poll(2). Readable when `read` has
    /// output; writable when `flush` can make progress.
    pub fn fd(self: Terminal) fd_t {
        return self.master;
    }

    /// Reads the child's output into `buf` without blocking.
    pub fn read(self: *Terminal, buf: []u8) error{ Closed, ReadFailed }!ReadResult {
        try self.core.checkOpen();
        while (true) {
            const rc = std.c.read(self.master, buf.ptr, buf.len);
            if (rc > 0) return .{ .data = buf[0..@intCast(rc)] };
            if (rc == 0) return .ended;
            switch (std.c.errno(rc)) {
                .INTR => continue,
                .AGAIN => return .empty,
                // Linux reports a PTY whose child side is closed as EIO.
                .IO => return .ended,
                else => return error.ReadFailed,
            }
        }
    }

    /// The owner's end of the child's report channel, for the owner's
    /// poll(2). Readable when `readReport` has lines; writable when
    /// `flushReplies` can make progress.
    pub fn reportFd(self: Terminal) fd_t {
        return self.report;
    }

    /// Reads what the child wrote to its report channel into `buf` without
    /// blocking. `.ended` means every process holding the child's end closed
    /// it.
    pub fn readReport(self: *Terminal, buf: []u8) error{ Closed, ReadFailed }!ReadResult {
        try self.core.checkOpen();
        while (true) {
            const rc = std.c.read(self.report, buf.ptr, buf.len);
            if (rc > 0) return .{ .data = buf[0..@intCast(rc)] };
            if (rc == 0) return .ended;
            switch (std.c.errno(rc)) {
                .INTR => continue,
                .AGAIN => return .empty,
                // Linux reports this, after every byte the child wrote,
                // when the child closed its end with replies left unread.
                .CONNRESET => return .ended,
                else => return error.ReadFailed,
            }
        }
    }

    pub const ReplyError = error{ Closed, InvalidLine, Busy, Ended, OutOfMemory };

    /// Queues `line` and a newline after any unsent replies, then sends as
    /// much as the report channel takes now; `flushReplies` sends the rest
    /// once `reportFd` is writable. So the child reads every accepted reply
    /// whole and in order. `line` holds no newline and at most
    /// `max_reply_line` bytes. `Busy` means nothing was queued because the
    /// child has not read enough of the earlier replies. `Ended` means the
    /// child's end is closed; the unsent replies, this one included, are
    /// dropped.
    pub fn reply(self: *Terminal, line: []const u8) ReplyError!void {
        try self.core.checkOpen();
        if (line.len > max_reply_line or std.mem.findScalar(u8, line, '\n') != null) return error.InvalidLine;
        self.core.queueReply(self.gpa, line) catch |err| return switch (err) {
            error.QueueFull => error.Busy,
            else => |e| e,
        };
        try self.flushReplies();
    }

    /// Sends unsent replies until the report channel would block. `Ended`
    /// means the child's end is closed, and the unsent replies are dropped.
    pub fn flushReplies(self: *Terminal) error{ Closed, Ended }!void {
        try self.core.checkOpen();
        while (true) {
            const bytes = self.core.pendingReply();
            if (bytes.len == 0) return;
            const rc = fd_ops.send(self.report, bytes);
            if (rc > 0) {
                self.core.flushedReply(@intCast(rc));
                continue;
            }
            if (rc == 0) return;
            switch (std.c.errno(rc)) {
                .INTR => continue,
                .PIPE, .CONNRESET => {
                    self.core.dropReplies(self.gpa);
                    return error.Ended;
                },
                // The child has not read enough yet, or the kernel is short
                // of buffers. The rest waits for the next call.
                else => return,
            }
        }
    }

    /// Reply bytes queued but not yet sent.
    pub fn pendingReplyBytes(self: Terminal) usize {
        return self.core.pendingReply().len;
    }

    /// Queues `bytes` after any unsent bytes, then writes as much as the
    /// PTY takes now. Bytes reach the child in the order they were queued.
    pub fn write(
        self: *Terminal,
        bytes: []const u8,
    ) error{ Closed, QueueFull, OutOfMemory, WriteFailed }!void {
        try self.core.queue(self.gpa, bytes);
        try self.flush();
    }

    /// Writes unsent bytes until the PTY would block.
    pub fn flush(self: *Terminal) error{ Closed, WriteFailed }!void {
        try self.core.checkOpen();
        while (true) {
            const bytes = self.core.pending();
            if (bytes.len == 0) return;
            const rc = std.c.write(self.master, bytes.ptr, bytes.len);
            if (rc > 0) {
                self.core.flushed(@intCast(rc));
                continue;
            }
            if (rc == 0) return;
            switch (std.c.errno(rc)) {
                .INTR => continue,
                .AGAIN => return,
                else => return error.WriteFailed,
            }
        }
    }

    /// Bytes queued but not yet written.
    pub fn pendingBytes(self: Terminal) usize {
        return self.core.pending().len;
    }

    /// Sets the PTY's size. The child receives SIGWINCH.
    pub fn resize(
        self: *Terminal,
        cols: u16,
        rows: u16,
    ) error{ Closed, InvalidOptions, ResizeFailed }!void {
        if (cols == 0 or rows == 0) return error.InvalidOptions;
        try self.core.checkOpen();
        setWindowSize(self.master, cols, rows) catch return error.ResizeFailed;
    }

    /// Checks without blocking whether the child has exited. Once it has,
    /// returns its exit status on this and every later call.
    pub fn checkExit(self: *Terminal) error{WaitFailed}!?Exit {
        if (self.core.exit) |exit| return exit;
        return self.wait(std.c.W.NOHANG);
    }

    /// Hangs up the child, waits up to `close_grace_ms` for it to exit, then
    /// kills its process group, reaps it and frees the terminal. Call once;
    /// later calls return `error.Closed`. `error.WaitFailed` means something
    /// else in the process reaped the child; the fd and queue are freed.
    pub fn close(self: *Terminal) error{ Closed, WaitFailed }!CloseReport {
        return self.closeWithin(close_grace_ms);
    }

    /// Hangs up the child without waiting for it: drops the unsent bytes and
    /// closes the PTY and the report channel. `close` or `closeWithin`
    /// finishes. Lets an owner hang up many children before waiting on any.
    pub fn hangUp(self: *Terminal) error{Closed}!void {
        self.dropped = try self.core.closeStart(self.gpa);
        fd_ops.close(self.master);
        fd_ops.close(self.report);
    }

    /// `close` with `grace_ms` for the child to exit, which may follow
    /// `hangUp`.
    pub fn closeWithin(self: *Terminal, grace_ms: u32) error{ Closed, WaitFailed }!CloseReport {
        if (self.core.phase != .closing) try self.hangUp();

        var waited: u32 = 0;
        while (self.core.exit == null and waited < grace_ms) : (waited += close_poll_ms) {
            if (try self.wait(std.c.W.NOHANG) != null) break;
            sleepMs(close_poll_ms);
        }
        if (self.core.kill()) {
            // ESRCH only means the group is already gone.
            _ = std.c.kill(-self.pid, std.c.SIG.KILL);
            _ = try self.wait(0);
        } else |_| {}

        // Either the grace loop reaped the child or the blocking wait did.
        self.core.closeFinish() catch unreachable;
        const exit = self.core.exit.?;
        self.core.deinit(self.gpa);
        self.core = .{ .phase = .closed, .exit = exit };
        return .{ .exit = exit, .dropped_bytes = self.dropped, .dropped_report_lines = 0 };
    }

    /// One waitpid with `flags`. Returns null when the child is still
    /// running (only possible with NOHANG).
    fn wait(self: *Terminal, flags: c_int) error{WaitFailed}!?Exit {
        std.debug.assert(self.core.mayWait());
        while (true) {
            var status: c_int = 0;
            const rc = std.c.waitpid(self.pid, &status, flags);
            switch (std.c.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.WaitFailed,
            }
            if (rc == 0) return null;
            const exit = exitFromStatus(@bitCast(status)) orelse return error.WaitFailed;
            self.core.reap(exit);
            return exit;
        }
    }
};

/// Decodes a waitpid status. Null for stop and continue reports, which
/// waitpid only returns when asked for them.
fn exitFromStatus(status: u32) ?Exit {
    if (std.c.W.IFEXITED(status)) return .{ .code = std.c.W.EXITSTATUS(status) };
    if (std.c.W.IFSIGNALED(status)) return .{ .signal = @intCast(@intFromEnum(std.c.W.TERMSIG(status))) };
    return null;
}

fn envValue(env: []const []const u8, name: []const u8) ?[]const u8 {
    for (env) |entry| {
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.startsWith(u8, entry, name)) {
            return entry[name.len + 1 ..];
        }
    }
    return null;
}

/// The path to exec for `program`: itself when it contains a '/', otherwise
/// the first executable match in `path`. An empty PATH entry means the
/// working directory, as in execvp.
fn resolveProgram(arena: Allocator, program: []const u8, path: ?[]const u8) error{ ProgramNotFound, OutOfMemory }![:0]const u8 {
    if (program.len == 0) return error.ProgramNotFound;
    if (std.mem.findScalar(u8, program, '/') != null) return arena.dupeZ(u8, program);
    var dirs = std.mem.splitScalar(u8, path orelse return error.ProgramNotFound, ':');
    while (dirs.next()) |dir| {
        const candidate = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ if (dir.len == 0) "." else dir, program }, 0);
        if (std.c.access(candidate, std.c.X_OK) == 0) return candidate;
    }
    return error.ProgramNotFound;
}

/// The child's environment: `env` without any report entry, then `report`.
fn childEnv(arena: Allocator, env: []const []const u8, report: []const u8) error{OutOfMemory}![*:null]const ?[*:0]const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    for (env) |item| {
        if (std.mem.startsWith(u8, item, report_env.name ++ "=")) continue;
        try entries.append(arena, item);
    }
    try entries.append(arena, report);
    return nullTerminated(arena, entries.items);
}

fn nullTerminated(arena: Allocator, items: []const []const u8) error{OutOfMemory}![*:null]const ?[*:0]const u8 {
    const out = try arena.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, out) |item, *slot| slot.* = try arena.dupeZ(u8, item);
    return out;
}

const Pty = struct { master: fd_t, slave: fd_t };

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;

// std has no macOS values for these two requests; they come from macOS's
// <sys/ttycom.h>. The window-size request does not fit in a signed 32-bit
// value, so its bits are reinterpreted as the C int ioctl takes.
const ioctl_set_controlling_terminal: c_int = switch (builtin.os.tag) {
    .macos => 0x20007461,
    .linux => @intCast(std.os.linux.T.IOCSCTTY),
    else => @compileError("sub-engine terminals need Linux or macOS"),
};
const ioctl_set_window_size: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(u32, 0x80087467)),
    .linux => @intCast(std.os.linux.T.IOCSWINSZ),
    else => @compileError("sub-engine terminals need Linux or macOS"),
};

fn openPty(cols: u16, rows: u16) error{PtyUnavailable}!Pty {
    const master_flags = std.posix.O{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true, .NONBLOCK = true };
    const master = posix_openpt(@bitCast(master_flags));
    if (master < 0) return error.PtyUnavailable;
    errdefer fd_ops.close(master);
    if (grantpt(master) != 0 or unlockpt(master) != 0) return error.PtyUnavailable;
    // ptsname(3) returns one buffer shared by the whole process, and
    // terminals open on any thread.
    var name_buf: [128]u8 = undefined;
    if (ptsname_r(master, &name_buf, name_buf.len) != 0) return error.PtyUnavailable;
    // On success the name ends with a NUL inside the buffer.
    const slave_name: [*:0]const u8 = @ptrCast(&name_buf);
    const slave = std.posix.openatZ(std.posix.AT.FDCWD, slave_name, .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0) catch return error.PtyUnavailable;
    errdefer fd_ops.close(slave);
    setWindowSize(master, cols, rows) catch return error.PtyUnavailable;
    return .{ .master = master, .slave = slave };
}

fn setWindowSize(fd: fd_t, cols: u16, rows: u16) error{ResizeFailed}!void {
    var size = std.posix.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(fd, ioctl_set_window_size, &size) < 0) return error.ResizeFailed;
}

/// The child reports a failure before exec as two i32s on a close-on-exec
/// launch pipe: the stage and errno. Exec closes the pipe, so EOF means the
/// child started.
const LaunchStage = enum(i32) { setup = 1, cwd = 2, exec = 3 };

/// Runs in the forked child. Only async-signal-safe calls until exec.
fn execChild(
    pty: Pty,
    report: fd_t,
    launch: fd_t,
    program: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8,
) noreturn {
    _ = std.c.close(pty.master);
    resetSignals();
    if (std.c.setsid() < 0) failLaunch(launch, .setup);
    if (std.c.ioctl(pty.slave, ioctl_set_controlling_terminal, @as(c_int, 0)) < 0) failLaunch(launch, .setup);
    for ([_]fd_t{ 0, 1, 2 }) |target| {
        if (std.c.dup2(pty.slave, target) < 0) failLaunch(launch, .setup);
    }
    if (pty.slave > 2) _ = std.c.close(pty.slave);
    // The program keeps the report channel across exec.
    if (std.c.fcntl(report, std.c.F.SETFD, @as(c_int, 0)) < 0) failLaunch(launch, .setup);
    if (cwd) |dir| {
        if (std.c.chdir(dir) != 0) failLaunch(launch, .cwd);
    }
    _ = std.c.execve(program, argv, envp);
    failLaunch(launch, .exec);
}

/// Signal dispositions set to ignore survive exec, and so does the signal
/// mask. The child starts with defaults for both, like a fresh login.
fn resetSignals() void {
    const empty = std.posix.sigemptyset();
    std.posix.sigprocmask(std.posix.SIG.SETMASK, &empty, null);
    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var number: u8 = 1;
    while (number < 32) : (number += 1) {
        const signal: std.posix.SIG = @enumFromInt(number);
        if (signal == .KILL or signal == .STOP) continue;
        std.posix.sigaction(signal, &default_action, null);
    }
}

fn failLaunch(launch: fd_t, stage: LaunchStage) noreturn {
    const errno_value: i32 = @intFromEnum(std.c.errno(@as(c_int, -1)));
    const message = [2]i32{ @intFromEnum(stage), errno_value };
    const bytes = std.mem.asBytes(&message);
    _ = std.c.write(launch, bytes.ptr, bytes.len);
    std.c._exit(127);
}

/// Waits for the child's verdict on the launch pipe: returns when exec
/// succeeded, the child's failure otherwise. Each wait for the pipe lasts at
/// most `timeout_ms`.
fn awaitLaunch(launch: fd_t, timeout_ms: u32) OpenError!void {
    var message: [2]i32 = undefined;
    const bytes = std.mem.asBytes(&message);
    var got: usize = 0;
    while (got < bytes.len) {
        var fds = [_]std.c.pollfd{.{ .fd = launch, .events = std.c.POLL.IN, .revents = 0 }};
        const ready = std.c.poll(&fds, 1, @intCast(timeout_ms));
        if (ready == 0) return error.LaunchTimedOut;
        if (ready < 0) {
            if (std.c.errno(ready) == .INTR) continue;
            break;
        }
        const rc = std.c.read(launch, bytes[got..].ptr, bytes.len - got);
        if (rc > 0) {
            got += @intCast(rc);
            continue;
        }
        if (rc < 0 and std.c.errno(rc) == .INTR) continue;
        break;
    }
    if (got == 0) return;
    if (got < bytes.len) return error.ExecFailed;
    const errno_value: std.c.E = @enumFromInt(message[1]);
    return switch (std.enums.fromInt(LaunchStage, message[0]) orelse return error.ExecFailed) {
        .setup => error.SetupFailed,
        .cwd => error.CwdUnavailable,
        .exec => switch (errno_value) {
            .NOENT, .NOTDIR => error.ProgramNotFound,
            .ACCES, .PERM => error.AccessDenied,
            else => error.ExecFailed,
        },
    };
}

/// Reaps a child whose launch failed.
fn waitBlocking(pid: std.c.pid_t) void {
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 0) < 0 and std.c.errno(@as(c_int, -1)) == .INTR) {}
}

fn sleepMs(ms: u32) void {
    var none: [0]std.c.pollfd = .{};
    _ = std.c.poll(&none, 0, @intCast(ms));
}

// Tests run real children on real PTYs with /bin/sh.

const testing = std.testing;
const test_env = [_][]const u8{ "PATH=/usr/bin:/bin", "TERM=xterm-256color", "LANG=C" };

/// bash, because scripts use the report fd with `>&` and `<&`, and dash takes
/// only single-digit fds there.
fn openShell(script: []const u8) !Terminal {
    return Terminal.open(testing.allocator, .{
        .argv = &.{ "/bin/bash", "-c", script },
        .env = &test_env,
        .cols = 80,
        .rows = 24,
    });
}

/// Collects output until `needle` appears or the child's side ends.
/// Fails after `timeout_ms`.
fn readUntil(terminal: *Terminal, out: *std.ArrayList(u8), needle: []const u8, timeout_ms: u32) !void {
    var buf: [4096]u8 = undefined;
    var waited: u32 = 0;
    while (std.mem.find(u8, out.items, needle) == null) {
        switch (try terminal.read(&buf)) {
            .data => |bytes| try out.appendSlice(testing.allocator, bytes),
            .ended => return error.EndedBeforeMatch,
            .empty => {
                if (waited >= timeout_ms) return error.Timeout;
                var fds = [_]std.c.pollfd{.{ .fd = terminal.fd(), .events = std.c.POLL.IN, .revents = 0 }};
                _ = std.c.poll(&fds, 1, 20);
                waited += 20;
            },
        }
    }
}

fn waitForExit(terminal: *Terminal, timeout_ms: u32) !Exit {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 10) {
        if (try terminal.checkExit()) |exit| return exit;
        sleepMs(10);
    }
    return error.Timeout;
}

test "a child's output and exit code come back" {
    var terminal = try openShell("printf 'hello from child'; exit 7");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, "hello from child", 5000);
    try testing.expectEqual(Exit{ .code = 7 }, try waitForExit(&terminal, 5000));
    try testing.expectEqual(Exit{ .code = 7 }, try terminal.checkExit());
    const closed = try terminal.close();
    try testing.expectEqual(Exit{ .code = 7 }, closed.exit);
}

test "a child killed by a signal reports it" {
    var terminal = try openShell("kill -TERM $$");
    try testing.expectEqual(Exit{ .signal = @intFromEnum(std.c.SIG.TERM) }, try waitForExit(&terminal, 5000));
    _ = try terminal.close();
}

test "the PTY is the child's controlling terminal" {
    // Opening /dev/tty succeeds only with a controlling terminal.
    var terminal = try openShell("echo ctty-ok > /dev/tty && test -t 0 && echo stdin-is-tty");
    defer _ = terminal.close() catch {};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, "stdin-is-tty", 5000);
    try testing.expect(std.mem.find(u8, out.items, "ctty-ok") != null);
}

test "writes reach the child" {
    var terminal = try openShell("read line; echo \"got:$line\"");
    defer _ = terminal.close() catch {};
    try terminal.write("abc\n");
    try testing.expectEqual(@as(usize, 0), terminal.pendingBytes());
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, "got:abc", 5000);
}

test "resize reaches the child" {
    var terminal = try openShell("echo ready; read x; stty size");
    defer _ = terminal.close() catch {};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, "ready", 5000);
    try terminal.resize(100, 30);
    try terminal.write("\n");
    try readUntil(&terminal, &out, "30 100", 5000);
    try testing.expectError(error.InvalidOptions, terminal.resize(0, 30));
}

test "the child gets exactly the given environment and directory" {
    var terminal = try Terminal.open(testing.allocator, .{
        .argv = &.{ "sh", "-c", "echo \"foo=$FOO home=${HOME:-unset}\"; pwd" },
        .env = &(test_env ++ [_][]const u8{"FOO=bar"}),
        .cwd = "/",
        .cols = 80,
        .rows = 24,
    });
    defer _ = terminal.close() catch {};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, "foo=bar home=unset", 5000);
    try readUntil(&terminal, &out, "\n/\r\n", 5000);
}

test "the owner's replies reach the child on its report channel" {
    var terminal = try openShell("read -r line <&${SUB_ENGINE_REPORT%%:*}; echo \"got=$line\"");
    defer _ = terminal.close() catch {};
    try terminal.reply("hello there");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, "got=hello there", 5000);
    try testing.expectError(error.InvalidLine, terminal.reply("two\nlines"));
    const long = [_]u8{'x'} ** (max_reply_line + 1);
    try testing.expectError(error.InvalidLine, terminal.reply(&long));
}

/// Shrinks the send buffer of the owner's end of a report channel, so a
/// long reply cannot leave in one send.
fn shrinkSendBuffer(report: fd_t) !void {
    const size: c_int = 4096;
    try testing.expectEqual(@as(c_int, 0), std.c.setsockopt(report, std.c.SOL.SOCKET, std.c.SO.SNDBUF, &size, @sizeOf(c_int)));
}

test "a reply larger than the socket buffer reaches the child whole" {
    // The child reads its replies only after the test says go, then stays
    // alive so the channel is still open for the last reply.
    var terminal = try openShell("read -r go; r=${SUB_ENGINE_REPORT%%:*}; read -r a <&$r; read -r b <&$r; echo \"a=${#a} b=$b\"; sleep 5");
    defer _ = terminal.close() catch {};
    try shrinkSendBuffer(terminal.reportFd());
    const long = [_]u8{'x'} ** max_reply_line;
    try terminal.reply(&long);
    try testing.expect(terminal.pendingReplyBytes() > 0);
    // Queued behind the unsent rest of the long reply.
    try terminal.reply("after");
    try terminal.write("go\n");

    var waited: u32 = 0;
    while (terminal.pendingReplyBytes() > 0) : (waited += 20) {
        if (waited >= 5000) return error.Timeout;
        var fds = [_]std.c.pollfd{.{ .fd = terminal.reportFd(), .events = std.c.POLL.OUT, .revents = 0 }};
        _ = std.c.poll(&fds, 1, 20);
        try terminal.flushReplies();
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, std.fmt.comptimePrint("a={d} b=after", .{max_reply_line}), 5000);
    try terminal.reply("still open");
}

test "a reply after the child closed its end fails without SIGPIPE" {
    var terminal = try openShell("eval \"exec ${SUB_ENGINE_REPORT%%:*}>&-\"; echo closed; sleep 5");
    defer _ = terminal.close() catch {};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, "closed", 5000);
    // SIGPIPE would end this test process here.
    try testing.expectError(error.Ended, terminal.reply("anyone there?"));
}

test "the child writes to its report channel, which only it holds" {
    var terminal = try openShell("printf 'first\\nsecond\\n' >&${SUB_ENGINE_REPORT%%:*}; echo wrote");
    defer _ = terminal.close() catch {};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, "wrote", 5000);
    _ = try waitForExit(&terminal, 5000);

    // With the child gone, nothing holds the child's end, so the channel ends.
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    var buf: [256]u8 = undefined;
    var waited: u32 = 0;
    while (true) {
        switch (try terminal.readReport(&buf)) {
            .data => |bytes| try got.appendSlice(testing.allocator, bytes),
            .ended => break,
            .empty => {
                if (waited >= 5000) return error.Timeout;
                sleepMs(10);
                waited += 10;
            },
        }
    }
    try testing.expectEqualStrings("first\nsecond\n", got.items);
}

test "an inherited report entry is replaced by the terminal's own" {
    const inherited = report_env.name ++ "=3:1:2";
    var terminal = try Terminal.open(testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "echo \"count=$(env | grep -c '^" ++ report_env.name ++ "=')\"; echo \"value=$" ++ report_env.name ++ ";\"" },
        .env = &(test_env ++ [_][]const u8{inherited}),
        .cols = 80,
        .rows = 24,
    });
    defer _ = terminal.close() catch {};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, ";", 5000);
    try testing.expect(std.mem.find(u8, out.items, "count=1") != null);
    const start = (std.mem.find(u8, out.items, "value=") orelse return error.TestUnexpectedResult) + "value=".len;
    const value = out.items[start..][0..std.mem.findScalar(u8, out.items[start..], ';').?];
    try testing.expect(!std.mem.eql(u8, value, inherited[report_env.name.len + 1 ..]));
    var fields = std.mem.splitScalar(u8, value, ':');
    var count: usize = 0;
    while (fields.next()) |field| : (count += 1) _ = try std.fmt.parseInt(u64, field, 10);
    try testing.expectEqual(@as(usize, 3), count);
}

test "a query reply written back reaches the child" {
    // The child sends a position query (CSI 6n) as a program would; the
    // test answers as an emulator would.
    var terminal = try openShell(
        "stty raw -echo; printf '\\033[6n'; r=$(dd bs=1 count=8 2>/dev/null); stty sane; echo; echo \"reply=$r\"",
    );
    defer _ = terminal.close() catch {};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, "\x1b[6n", 5000);
    try terminal.write("\x1b[12;34R");
    try readUntil(&terminal, &out, "12;34R", 5000);
}

test "open reports a missing program or directory" {
    const gpa = testing.allocator;
    try testing.expectError(error.ProgramNotFound, Terminal.open(gpa, .{
        .argv = &.{"sub-engine-no-such-program"},
        .env = &test_env,
        .cols = 80,
        .rows = 24,
    }));
    try testing.expectError(error.ProgramNotFound, Terminal.open(gpa, .{
        .argv = &.{"/sub-engine/no/such/program"},
        .env = &test_env,
        .cols = 80,
        .rows = 24,
    }));
    try testing.expectError(error.CwdUnavailable, Terminal.open(gpa, .{
        .argv = &.{"/bin/sh"},
        .env = &test_env,
        .cwd = "/sub-engine/no/such/dir",
        .cols = 80,
        .rows = 24,
    }));
    try testing.expectError(error.InvalidOptions, Terminal.open(gpa, .{
        .argv = &.{},
        .env = &test_env,
        .cols = 80,
        .rows = 24,
    }));
}

test "the launch verdict is read, and waited for only so long" {
    const held = try fd_ops.pipe(.{});
    defer fd_ops.close(held.read);
    defer fd_ops.close(held.write);
    // A write end another process inherited keeps the pipe open.
    try testing.expectError(error.LaunchTimedOut, awaitLaunch(held.read, 50));
    const message = [2]i32{ @intFromEnum(LaunchStage.exec), @intFromEnum(std.c.E.NOENT) };
    const bytes = std.mem.asBytes(&message);
    try testing.expectEqual(@as(isize, bytes.len), std.c.write(held.write, bytes.ptr, bytes.len));
    try testing.expectError(error.ProgramNotFound, awaitLaunch(held.read, 50));

    // Exec closed the last write end.
    const done = try fd_ops.pipe(.{});
    defer fd_ops.close(done.read);
    fd_ops.close(done.write);
    try awaitLaunch(done.read, 50);
}

test "close hangs up the child" {
    var terminal = try openShell("echo ready; sleep 30");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, "ready", 5000);
    const closed = try terminal.close();
    try testing.expectEqual(Exit{ .signal = @intFromEnum(std.c.SIG.HUP) }, closed.exit);

    var buf: [16]u8 = undefined;
    try testing.expectError(error.Closed, terminal.read(&buf));
    try testing.expectError(error.Closed, terminal.write("x"));
    try testing.expectError(error.Closed, terminal.resize(80, 24));
    try testing.expectError(error.Closed, terminal.close());
}

test "close kills a child that ignores the hangup" {
    var terminal = try openShell("trap '' HUP; echo ready; while :; do sleep 1; done");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try readUntil(&terminal, &out, "ready", 5000);
    const closed = try terminal.close();
    try testing.expectEqual(Exit{ .signal = @intFromEnum(std.c.SIG.KILL) }, closed.exit);
}

test "exit statuses decode like waitpid's" {
    try testing.expectEqual(Exit{ .code = 23 }, exitFromStatus(23 << 8).?);
    try testing.expectEqual(Exit{ .signal = 15 }, exitFromStatus(15).?);
    try testing.expectEqual(Exit{ .signal = 11 }, exitFromStatus(11 | 0x80).?);
    try testing.expectEqual(@as(?Exit, null), exitFromStatus((19 << 8) | 0x7f));
}

test "programs resolve through PATH" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("/bin/sh", try resolveProgram(arena, "sh", "/sub-engine-missing:/bin"));
    try testing.expectEqualStrings("./x", try resolveProgram(arena, "./x", null));
    try testing.expectError(error.ProgramNotFound, resolveProgram(arena, "sh", null));
    try testing.expectEqualStrings("/bin", envValue(&.{ "PATHX=no", "PATH=/bin" }, "PATH").?);
}
