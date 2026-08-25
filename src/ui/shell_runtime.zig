const std = @import("std");
const activity_runtime = @import("../core/output/activity_runtime.zig");
const builtin = @import("builtin");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");
const transcript_runtime = @import("transcript/runtime.zig");
const frame_layout = @import("render_engine/frame_layout.zig");
const cursor_probe = @import("terminal/cursor_probe.zig");
const resize_runtime = @import("resize_runtime.zig");
const ui_terminal = @import("terminal/terminal.zig");
const wasm_terminal = if (builtin.os.tag == .wasi) @import("terminal/wasm_terminal.zig") else struct {};
const windows = std.os.windows;

const Allocator = std.mem.Allocator;
const Layout = types.Layout;
const Metrics = types.Metrics;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

const TmuxHistoryClearRunner = *const fn (Allocator, []const u8) anyerror!void;
var tmux_history_clear_test_runner: if (builtin.is_test) ?TmuxHistoryClearRunner else void = if (builtin.is_test) null else {};

const supports_test_pty = switch (builtin.os.tag) {
    .linux,
    .macos,
    .freebsd,
    .netbsd,
    .openbsd,
    => true,
    else => false,
};

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;

// Win32 console APIs. std.os.windows.kernel32 only declares CreateProcessW,
// so everything else is declared here. The linkages are valid for any target
// (Zig defers resolution to link time), but every call site is guarded by
// `if (comptime builtin.os.tag == .windows)`.
extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    lpMode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    dwMode: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetConsoleCtrlHandler(
    handlerRoutine: ?*const fn (windows.DWORD) callconv(.c) windows.BOOL,
    add: windows.BOOL,
) callconv(.winapi) windows.BOOL;

/// Windows console mode DWORD bits that toggle line-mode input handling.
/// `enableRawMode` clears all three; `disableRawMode` restores the captured
/// mask, which preserves whatever combination was active at startup.
const WIN_ENABLE_PROCESSED_INPUT: u32 = 0x0001;
const WIN_ENABLE_LINE_INPUT: u32 = 0x0002;
const WIN_ENABLE_ECHO_INPUT: u32 = 0x0004;

/// Console ctrl event types we inspect inside the static C-ABI thunks.
const WIN_CTRL_C_EVENT: u32 = 0;
const WIN_CTRL_BREAK_EVENT: u32 = 1;
const WIN_CTRL_CLOSE_EVENT: u32 = 2;
const WIN_CTRL_LOGOFF_EVENT: u32 = 5;
const WIN_CTRL_SHUTDOWN_EVENT: u32 = 6;
const WIN_WINDOW_BUFFER_SIZE_EVENT: u32 = 4;

/// Routing table for the resize console ctrl handler. Set once at
/// `installResizeSignal` time and read on every ctrl event. Storing the
/// interlock pointer here lets the C-ABI thunk reach the Zig-owned state
/// without per-handler trampolines.
var g_resize_interlock: ?*ResizeApprovalInterlock = null;

/// Routing table for the abnormal-exit console ctrl handler. Stores the
/// restore-bytes slice that `WriteConsoleA` flushes before `std.process.exit`
/// inside the static C-ABI thunk. Updated atomically on install/uninstall.
const AbnormalExitRestoreSlot = struct {
    bytes: ?[]const u8,
};
var g_abnormal_exit_restore: AbnormalExitRestoreSlot = .{ .bytes = null };

/// C-ABI trampoline that the console ctrl handler list calls. Only fires the
/// resize path for `WINDOW_BUFFER_SIZE_EVENT`; everything else falls through
/// to the next handler (the abnormal-exit handler) and ultimately to the
/// default disposition.
export fn windowsResizeCtrlHandler(ctrl_type: windows.DWORD) callconv(.c) windows.BOOL {
    if (ctrl_type != WIN_WINDOW_BUFFER_SIZE_EVENT) return windows.BOOL.FALSE;
    if (g_resize_interlock) |interlock| interlock.noteResizeSignal();
    return windows.BOOL.TRUE;
}

/// C-ABI trampoline for SIGTERM/SIGINT-equivalent signals (Ctrl+C,
/// Ctrl+Break) plus console close/logoff/shutdown. Mirrors the POSIX
/// `abnormalExitHandlerWithRestore` semantics: synchronously write the
/// restore bytes once, then exit. ReadConsoleInputW may be racing, so we
/// use `WriteConsoleA` which is documented safe inside a console ctrl
/// handler.
export fn windowsAbnormalExitCtrlHandler(ctrl_type: windows.DWORD) callconv(.c) windows.BOOL {
    switch (ctrl_type) {
        WIN_CTRL_C_EVENT, WIN_CTRL_BREAK_EVENT, WIN_CTRL_CLOSE_EVENT, WIN_CTRL_LOGOFF_EVENT, WIN_CTRL_SHUTDOWN_EVENT => {},
        else => return windows.BOOL.FALSE,
    }
    if (g_abnormal_exit_restore.bytes) |bytes| {
        const handle = std.Io.File.stdout().handle;
        // Escape sequences are pure ASCII, so `WriteConsoleA`'s code-page
        // conversion is a no-op and the byte count is the byte count.
        _ = WriteConsoleA(handle, bytes.ptr, @intCast(bytes.len), null, null);
    }
    std.process.exit(1);
}

extern "kernel32" fn WriteConsoleA(
    hConsoleOutput: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfCharsToWrite: windows.DWORD,
    lpNumberOfCharsWritten: ?*windows.DWORD,
    lpReserved: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

/// Stores the interlock used by the Windows resize console ctrl handler.
/// Must be called once at startup (before `installResizeSignal`) so the
/// `windowsResizeCtrlHandler` thunk has a target to post resize events to.
/// No-op on non-Windows targets.
pub fn setWindowsResizeInterlock(interlock: *ResizeApprovalInterlock) void {
    g_resize_interlock = interlock;
}

/// Stores the restore-bytes slice the Windows abnormal-exit console ctrl
/// handler flushes via `WriteConsoleA` before calling `std.process.exit`.
/// Must be called once at startup (before `installAbnormalExitHandlers`).
/// No-op on non-Windows targets.
pub fn setWindowsAbnormalExitRestore(bytes: []const u8) void {
    g_abnormal_exit_restore.bytes = bytes;
}

/// Clears the abnormal-exit restore slot so the uninstalled thunk does not
/// emit stale bytes if a stray event arrives during shutdown. No-op on
/// non-Windows targets.
pub fn clearWindowsAbnormalExitRestore() void {
    g_abnormal_exit_restore.bytes = null;
}

/// Installs the static `windowsAbnormalExitCtrlHandler` thunk in the console
/// ctrl handler list so SIGINT/SIGTERM/SIGBREAK equivalents flush the
/// published restore bytes before exiting. Mirrors the POSIX
/// `abnormalExitHandlerWithRestore` path in `app_lifecycle`. No-op on
/// non-Windows targets.
pub fn installWindowsAbnormalExitCtrlHandler() bool {
    return SetConsoleCtrlHandler(&windowsAbnormalExitCtrlHandler, windows.BOOL.TRUE).toBool();
}

/// Removes the static `windowsAbnormalExitCtrlHandler` thunk from the
/// console ctrl handler list. Pair with `installWindowsAbnormalExitCtrlHandler`
/// during shutdown. No-op on non-Windows targets.
pub fn uninstallWindowsAbnormalExitCtrlHandler() void {
    _ = SetConsoleCtrlHandler(&windowsAbnormalExitCtrlHandler, windows.BOOL.FALSE);
}

pub const supports_resize_signal = resize_runtime.supports_resize_signal;
pub const ResizeHandler = if (builtin.os.tag == .wasi)
    *const fn () callconv(.c) void
else if (builtin.os.tag == .windows)
    *const fn () callconv(.c) void
else
    std.posix.Sigaction.handler_fn;
pub const ResizeApprovalInterlock = resize_runtime.ResizeApprovalInterlock;
pub const RedrawMode = resize_runtime.RedrawMode;

pub const PollResult = struct {
    readable: bool = false,
    hung_up: bool = false,
    has_error: bool = false,

    pub fn closed(self: PollResult) bool {
        return self.hung_up or self.has_error;
    }
};

pub const CursorPosition = cursor_probe.Position;

pub const AlternateScreenOwner = enum {
    none,
    file_approval,
    full_transcript,
    catalog_menu,
    subagent_manager,
    terminal_session,
};

/// Returns true when the supplied handle is a real Windows console (as
/// opposed to a redirected file or pipe). `GetConsoleMode` returns `FALSE`
/// on non-console handles because the input/output path is not a tty.
fn isWindowsConsoleHandle(handle: windows.HANDLE) bool {
    var mode: windows.DWORD = 0;
    return GetConsoleMode(handle, &mode).toBool();
}

pub const TerminalState = struct {
    stdin_fd: if (builtin.os.tag == .windows) *anyopaque else std.posix.fd_t = if (builtin.os.tag == .windows) undefined else std.posix.STDIN_FILENO,
    original_termios: if (builtin.os.tag == .windows) void else std.posix.termios = if (builtin.os.tag == .windows) {} else undefined,
    original_console_mode: if (builtin.os.tag == .windows) windows.DWORD else void = if (builtin.os.tag == .windows) 0 else {},
    raw_enabled: bool = false,
    alternate_screen_owner: AlternateScreenOwner = .none,
    alternate_frame_layout: frame_layout.CommittedLayoutSnapshot = .{},
    alternate_mouse_tracking_active: bool = false,
    signal_handler_installed: bool = false,
    old_winch_action: if (builtin.os.tag == .windows) void else ?std.posix.Sigaction = if (builtin.os.tag == .windows) {} else null,

    pub fn fileApprovalScreenActive(self: TerminalState) bool {
        return self.alternate_screen_owner == .file_approval;
    }

    pub fn fullTranscriptScreenActive(self: TerminalState) bool {
        return self.alternate_screen_owner == .full_transcript;
    }

    pub fn catalogMenuScreenActive(self: TerminalState) bool {
        return self.alternate_screen_owner == .catalog_menu;
    }

    pub fn subagentManagerScreenActive(self: TerminalState) bool {
        return self.alternate_screen_owner == .subagent_manager;
    }

    pub fn terminalSessionScreenActive(self: TerminalState) bool {
        return self.alternate_screen_owner == .terminal_session;
    }

    pub fn ensureInteractive(self: TerminalState) !void {
        if (comptime builtin.os.tag == .wasi) return error.NotATerminal;
        if (comptime builtin.os.tag == .windows) {
            const stdin_is_console = isWindowsConsoleHandle(std.Io.File.stdin().handle);
            const stdout_is_console = isWindowsConsoleHandle(std.Io.File.stdout().handle);
            if (!stdin_is_console or !stdout_is_console) return error.NotATerminal;
            return;
        }
        if (std.c.isatty(self.stdin_fd) == 0 or std.c.isatty(std.posix.STDOUT_FILENO) == 0) {
            return error.NotATerminal;
        }
    }

    pub fn captureOriginalTermios(self: *TerminalState) !void {
        if (comptime builtin.os.tag == .wasi) return;
        if (comptime builtin.os.tag == .windows) {
            var mode: windows.DWORD = 0;
            if (!GetConsoleMode(std.Io.File.stdin().handle, &mode).toBool()) {
                return error.NotATerminal;
            }
            self.original_console_mode = mode;
            self.stdin_fd = std.Io.File.stdin().handle;
            return;
        }
        self.original_termios = try std.posix.tcgetattr(self.stdin_fd);
    }

    pub fn enableRawMode(self: *TerminalState) !void {
        if (comptime builtin.os.tag == .wasi) return error.NotATerminal;
        if (comptime builtin.os.tag == .windows) {
            var mode: windows.DWORD = 0;
            if (!GetConsoleMode(std.Io.File.stdin().handle, &mode).toBool()) {
                return error.NotATerminal;
            }
            self.original_console_mode = mode;
            self.stdin_fd = std.Io.File.stdin().handle;
            // Clear the three cooked-mode bits; everything else (mouse,
            // quick-edit, virtual terminal processing, ...) is preserved
            // exactly as it was at startup. disableRawMode restores the
            // full mask, so the user's saved bits come back unchanged.
            const raw_mode = mode &
                ~(WIN_ENABLE_ECHO_INPUT |
                    WIN_ENABLE_LINE_INPUT |
                    WIN_ENABLE_PROCESSED_INPUT);
            if (!SetConsoleMode(std.Io.File.stdin().handle, raw_mode).toBool()) {
                return error.NotATerminal;
            }
            self.raw_enabled = true;
            return;
        }
        var raw = self.original_termios;

        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.iflag.IXOFF = false;

        raw.cflag.CSIZE = .CS8;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        const vmin_idx = vminIndex();
        const vtime_idx = vtimeIndex();
        if (vmin_idx < raw.cc.len and vtime_idx < raw.cc.len) {
            raw.cc[vmin_idx] = 1;
            raw.cc[vtime_idx] = 0;
        }

        try std.posix.tcsetattr(self.stdin_fd, .NOW, raw);
        self.raw_enabled = true;
    }

    pub fn disableRawMode(self: *TerminalState) void {
        if (!self.raw_enabled) return;
        if (comptime builtin.os.tag == .windows) {
            _ = SetConsoleMode(std.Io.File.stdin().handle, self.original_console_mode);
        } else if (comptime builtin.os.tag != .wasi) {
            std.posix.tcsetattr(self.stdin_fd, .FLUSH, self.original_termios) catch {};
        }
        self.raw_enabled = false;
    }

    pub fn installResizeSignal(self: *TerminalState, handler: ResizeHandler) void {
        if (!supports_resize_signal) return;
        if (comptime builtin.os.tag == .windows) {
            // The `handler` argument has the wrong signature for
            // `SetConsoleCtrlHandler` on Windows (no DWORD arg, no BOOL return).
            // We instead install a static C-ABI thunk that posts
            // `WINDOW_BUFFER_SIZE_EVENT` to whatever interlock the caller wired
            // via `setWindowsResizeInterlock` at startup. `handler` is unused
            // on Windows.
            _ = &handler;
            _ = SetConsoleCtrlHandler(&windowsResizeCtrlHandler, windows.BOOL.TRUE);
            self.signal_handler_installed = true;
            return;
        }

        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };

        var old: std.posix.Sigaction = undefined;
        std.posix.sigaction(std.posix.SIG.WINCH, &act, &old);
        self.old_winch_action = old;
        self.signal_handler_installed = true;
    }

    pub fn uninstallResizeSignal(self: *TerminalState) void {
        if (!supports_resize_signal or !self.signal_handler_installed) return;
        if (comptime builtin.os.tag == .windows) {
            _ = SetConsoleCtrlHandler(&windowsResizeCtrlHandler, windows.BOOL.FALSE);
            self.signal_handler_installed = false;
            return;
        }
        if (self.old_winch_action) |old| {
            std.posix.sigaction(std.posix.SIG.WINCH, &old, null);
        }
        self.signal_handler_installed = false;
    }

    pub fn queryLayout(self: TerminalState, footer_rows: u16) !Layout {
        return if (comptime builtin.os.tag == .wasi)
            wasm_terminal.queryLayout(footer_rows)
        else
            ui_terminal.queryLayout(self.stdin_fd, footer_rows);
    }

    pub fn queryCursorPosition(self: TerminalState) !CursorPosition {
        if (comptime builtin.os.tag == .wasi) {
            // JavaScript hosts provide a fresh terminal surface rather than an
            // existing shell viewport, so there are no launch rows to preserve.
            return .{ .row = 1, .col = 1 };
        }
        var stdout_file = std.Io.File.stdout();
        try stdout_file.writeStreamingAll(io_mod.getIo(), "\x1b[6n");

        var buf: [64]u8 = undefined;
        var len: usize = 0;
        const deadline_ms = io_mod.milliTimestamp() + 100;

        while (len < buf.len) {
            const now_ms = io_mod.milliTimestamp();
            if (now_ms >= deadline_ms) break;

            const remaining_ms: i32 = @intCast(deadline_ms - now_ms);
            const poll = try self.pollInput(remaining_ms);
            if (poll.closed() or !poll.readable) break;

            const n = try self.read(buf[len .. len + 1]);
            if (n == 0) break;
            len += n;
            if (cursor_probe.findPositionResponse(buf[0..len]) != null) break;
        }

        return cursor_probe.parsePositionResponse(buf[0..len]);
    }

    pub fn clearTmuxScreenAndHistory(_: *TerminalState, alloc: Allocator) void {
        if (comptime builtin.is_test) return;
        if (io_mod.getenv("TMUX") == null) return;
        const pane = io_mod.getenv("TMUX_PANE") orelse return;

        var stdout_file = std.Io.File.stdout();
        stdout_file.writeStreamingAll(io_mod.getIo(), "\x1b[0m\x1b[2J\x1b[3J\x1b[H") catch |err| {
            debug_trace.logf("resize", "tmux_clear_screen_failed pane={s} err={s}", .{ pane, @errorName(err) });
            return;
        };
        waitForTmuxScreenClear(alloc, pane);
        clearTmuxHistoryForPane(alloc, pane);
    }

    pub fn requestResizeCursorPosition(
        _: TerminalState,
        protocol: cursor_probe.Protocol,
    ) !void {
        var stdout_file = std.Io.File.stdout();
        try stdout_file.writeStreamingAll(io_mod.getIo(), cursor_probe.queryBytes(protocol));
    }

    pub fn enableThemeNotifications(_: TerminalState) !void {
        var stdout_file = std.Io.File.stdout();
        try stdout_file.writeStreamingAll(io_mod.getIo(), ui_terminal.theme_notification_enable_sequence);
    }

    pub fn requestThemeColorScheme(_: TerminalState) !void {
        var stdout_file = std.Io.File.stdout();
        try stdout_file.writeStreamingAll(io_mod.getIo(), ui_terminal.theme_color_scheme_query);
    }

    pub fn requestThemeResponseFence(_: TerminalState) !void {
        var stdout_file = std.Io.File.stdout();
        try stdout_file.writeStreamingAll(io_mod.getIo(), ui_terminal.theme_response_fence_query);
    }

    pub fn requestThemeBackground(_: TerminalState) !void {
        var stdout_file = std.Io.File.stdout();
        try stdout_file.writeStreamingAll(io_mod.getIo(), ui_terminal.theme_background_query_with_fence);
    }

    pub fn read(self: TerminalState, out: []u8) !usize {
        if (comptime builtin.os.tag == .wasi) {
            return std.Io.File.stdin().readStreaming(io_mod.getIo(), &.{out});
        }
        return std.posix.read(self.stdin_fd, out);
    }

    pub fn pollInput(self: TerminalState, timeout_ms: i32) !PollResult {
        if (comptime builtin.os.tag == .wasi) {
            return switch (wasm_terminal.pollInput(timeout_ms)) {
                1 => .{ .readable = true },
                -1 => .{ .hung_up = true },
                else => .{},
            };
        }
        var fds = [_]std.posix.pollfd{.{
            .fd = if (comptime builtin.os.tag == .windows)
                @ptrCast(self.stdin_fd)
            else
                self.stdin_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        _ = try std.posix.poll(&fds, timeout_ms);
        const revents = fds[0].revents;
        return .{
            .readable = (revents & std.posix.POLL.IN) != 0,
            .hung_up = (revents & std.posix.POLL.HUP) != 0,
            .has_error = (revents & std.posix.POLL.ERR) != 0,
        };
    }
};

fn clearTmuxHistoryForPane(alloc: Allocator, pane: []const u8) void {
    runTmuxHistoryClear(alloc, pane) catch |err| {
        debug_trace.logf(
            "resize",
            "tmux_clear_history_failed pane={s} err={s}",
            .{ pane, @errorName(err) },
        );
        return;
    };
    debug_trace.logf("resize", "tmux_clear_history_complete pane={s}", .{pane});
}

fn waitForTmuxScreenClear(alloc: Allocator, pane: []const u8) void {
    for (0..5) |attempt| {
        const clear = tmuxScreenIsClear(alloc, pane) catch |err| {
            debug_trace.logf("resize", "tmux_clear_screen_check_failed pane={s} err={s}", .{ pane, @errorName(err) });
            return;
        };
        if (clear) return;
        if (attempt + 1 < 5) io_mod.sleep(5 * std.time.ns_per_ms);
    }
    debug_trace.logf("resize", "tmux_clear_screen_timeout pane={s}", .{pane});
}

fn tmuxScreenIsClear(alloc: Allocator, pane: []const u8) !bool {
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "tmux", "capture-pane", "-p", "-t", pane },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TmuxCapturePaneFailed;
    return std.mem.trim(u8, result.stdout, " \t\r\n").len == 0;
}

fn runTmuxHistoryClear(alloc: Allocator, pane: []const u8) !void {
    if (comptime builtin.is_test) {
        if (tmux_history_clear_test_runner) |runner| return runner(alloc, pane);
    }
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "tmux", "clear-history", "-t", pane },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TmuxClearHistoryFailed;
}

var tmux_history_clear_test_calls: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

fn failTmuxHistoryClearForTest(_: Allocator, _: []const u8) !void {
    tmux_history_clear_test_calls += 1;
    return error.TestTmuxHistoryClearFailure;
}

test "tmux history clear failure does not escape the reset boundary" {
    tmux_history_clear_test_calls = 0;
    tmux_history_clear_test_runner = failTmuxHistoryClearForTest;
    defer tmux_history_clear_test_runner = null;

    clearTmuxHistoryForPane(std.testing.allocator, "%1");

    try std.testing.expectEqual(@as(usize, 1), tmux_history_clear_test_calls);
}

pub fn detectSyncUpdatesEnabled(_: Allocator) bool {
    const override = io_mod.getenv("FX_SYNC_UPDATES");

    const fallback_override = if (override == null)
        io_mod.getenv("FLASH_SYNC_UPDATES")
    else
        null;

    const term = io_mod.getenv("TERM");

    return syncUpdatesEnabledForValues(override orelse fallback_override, term);
}

pub fn detectHistoryResetUsesRis(_: Allocator) bool {
    return historyResetUsesRisForValues(
        io_mod.getenv("TERM_PROGRAM"),
        io_mod.getenv("TMUX"),
    );
}

pub fn applyToolLifecycle(
    alloc: Allocator,
    shell: anytype,
    event: types.ToolLifecycleEvent,
) !?types.ToolActivityKind {
    return shell.applyToolLifecycle(alloc, event);
}

pub fn applyToolLifecyclePreservingNormalBufferAnchor(
    alloc: Allocator,
    shell: anytype,
    event: types.ToolLifecycleEvent,
) !?types.ToolActivityKind {
    const Shell = @TypeOf(shell.*);
    if (comptime @hasDecl(Shell, "applyToolLifecyclePreservingNormalBufferAnchor")) {
        return shell.applyToolLifecyclePreservingNormalBufferAnchor(alloc, event);
    }
    return shell.applyToolLifecycle(alloc, event);
}

pub fn finishLifecycleBatch(
    alloc: Allocator,
    shell: anytype,
) !void {
    return shell.finishLifecycleBatch(alloc);
}

pub fn activityProjection(
    shell: anytype,
) activity_runtime.ActivityProjection {
    return shell.activityProjection();
}

pub fn focusedToolEntryId(shell: anytype) ?u32 {
    return shell.focusedToolEntryId();
}

pub fn focusedToolActivityKind(
    shell: anytype,
) ?types.ToolActivityKind {
    return shell.focusedToolActivityKind();
}

pub fn activeToolActivityCount(shell: anytype) usize {
    return shell.activeToolActivityCount();
}

pub fn requestRedraw(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    mode: RedrawMode,
) !void {
    return resize_runtime.requestRedraw(shell, metrics, mode);
}

pub fn collectResizeFacts(
    terminal: TerminalState,
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    probe: *cursor_probe.Parser,
    resize_interlock: *ResizeApprovalInterlock,
    footer_rows: u16,
    debounce_ms: i64,
    cursor_probe_allowed: bool,
) !void {
    return resize_runtime.collectResizeFacts(
        terminal,
        shell,
        metrics,
        probe,
        resize_interlock,
        footer_rows,
        debounce_ms,
        cursor_probe_allowed,
    );
}

pub fn admitResizeSignal(
    shell: *TranscriptRuntime,
    resize_interlock: *ResizeApprovalInterlock,
    now_ms: i64,
    debounce_ms: i64,
    source: []const u8,
) bool {
    return resize_runtime.admitResizeSignal(
        shell,
        resize_interlock,
        now_ms,
        debounce_ms,
        source,
    );
}

pub fn resizeLifecycleIdle(shell: anytype) bool {
    return resize_runtime.lifecycleIdle(shell);
}

pub fn resizeBlocksFrameCommit(shell: anytype) bool {
    return resize_runtime.blocksFrameCommit(shell);
}

pub const ResizeFrameCommit = resize_runtime.FrameCommit;

pub fn pendingResizeFrameCommit(shell: anytype, resize_reason: bool) ResizeFrameCommit {
    return resize_runtime.pendingFrameCommit(shell, resize_reason);
}

pub fn acknowledgeResizeFrameCommit(shell: anytype, commit: ResizeFrameCommit) void {
    resize_runtime.acknowledgeFrameCommit(shell, commit);
}

pub fn completeResizeCursorProbe(
    shell: *TranscriptRuntime,
    position: CursorPosition,
) void {
    resize_runtime.completeResizeCursorProbe(shell, position);
}

pub fn suspendResizeCursorProbeForPaste(probe: *cursor_probe.Parser) void {
    return resize_runtime.suspendResizeCursorProbeForPaste(probe);
}

pub fn resumeResizeCursorProbeAfterPaste(probe: *cursor_probe.Parser, now_ms: i64) void {
    return resize_runtime.resumeResizeCursorProbeAfterPaste(probe, now_ms);
}

pub fn applyResizeWithLayout(
    shell: *TranscriptRuntime,
    metrics: *Metrics,
    new_layout: Layout,
    settled: bool,
) !void {
    return resize_runtime.applyResizeWithLayout(shell, metrics, new_layout, settled);
}

fn syncUpdatesEnabledForValues(override: ?[]const u8, term: ?[]const u8) bool {
    if (override) |value| {
        if (std.ascii.eqlIgnoreCase(value, "0") or
            std.ascii.eqlIgnoreCase(value, "false") or
            std.ascii.eqlIgnoreCase(value, "off"))
        {
            return false;
        }
        if (std.ascii.eqlIgnoreCase(value, "1") or
            std.ascii.eqlIgnoreCase(value, "true") or
            std.ascii.eqlIgnoreCase(value, "on"))
        {
            return true;
        }
    }

    if (term) |value| {
        if (std.mem.eql(u8, value, "dumb")) return false;
    }

    return true;
}

fn historyResetUsesRisForValues(term_program: ?[]const u8, tmux: ?[]const u8) bool {
    return tmux == null and
        term_program != null and
        std.mem.eql(u8, term_program.?, "Apple_Terminal");
}

fn vminIndex() usize {
    return switch (builtin.os.tag) {
        .linux => 6,
        .macos, .ios, .tvos, .watchos, .visionos => 16,
        .freebsd, .netbsd, .dragonfly, .openbsd => 16,
        else => 16,
    };
}

fn vtimeIndex() usize {
    return switch (builtin.os.tag) {
        .linux => 5,
        .macos, .ios, .tvos, .watchos, .visionos => 17,
        .freebsd, .netbsd, .dragonfly, .openbsd => 17,
        else => 17,
    };
}

test "sync updates override beats dumb term" {
    try std.testing.expect(syncUpdatesEnabledForValues("on", "dumb"));
    try std.testing.expect(!syncUpdatesEnabledForValues("off", "xterm-256color"));
    try std.testing.expect(!syncUpdatesEnabledForValues(null, "dumb"));
}

test "direct Apple Terminal uses RIS for terminal history resets" {
    try std.testing.expect(historyResetUsesRisForValues("Apple_Terminal", null));
    try std.testing.expect(!historyResetUsesRisForValues("Apple_Terminal", "/tmp/tmux-1/default,1,0"));
    try std.testing.expect(!historyResetUsesRisForValues("Ghostty", null));
}

const TestPty = struct {
    master: std.posix.fd_t,
    slave: std.posix.fd_t,

    fn open() !TestPty {
        const flags = std.posix.O{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        };
        const flags_int: c_int = @bitCast(flags);
        const master_fd = posix_openpt(flags_int);
        if (master_fd < 0) return error.PtyUnavailable;
        errdefer closeTestFd(master_fd);

        if (grantpt(master_fd) != 0) return error.PtyUnavailable;
        if (unlockpt(master_fd) != 0) return error.PtyUnavailable;
        const slave_name = ptsname(master_fd) orelse return error.PtyUnavailable;
        const slave_fd = try std.posix.openatZ(std.posix.AT.FDCWD, slave_name, flags, 0);
        errdefer closeTestFd(slave_fd);

        return .{
            .master = master_fd,
            .slave = slave_fd,
        };
    }

    fn close(self: TestPty) void {
        closeTestFd(self.master);
        closeTestFd(self.slave);
    }
};

fn closeTestFd(fd: std.posix.fd_t) void {
    (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).close(io_mod.getIo());
}

test "enableRawMode preserves already queued input" {
    if (!supports_test_pty) return error.SkipZigTest;

    const pty = try TestPty.open();
    defer pty.close();

    var original = try std.posix.tcgetattr(pty.slave);
    original.lflag.ECHO = false;
    original.lflag.ICANON = false;
    original.lflag.ISIG = false;
    const vmin_idx = vminIndex();
    const vtime_idx = vtimeIndex();
    if (vmin_idx < original.cc.len and vtime_idx < original.cc.len) {
        original.cc[vmin_idx] = 1;
        original.cc[vtime_idx] = 0;
    }
    try std.posix.tcsetattr(pty.slave, .NOW, original);

    var terminal = TerminalState{ .stdin_fd = pty.slave };
    try terminal.captureOriginalTermios();

    const queued = [_]u8{3};
    try (std.Io.File{
        .handle = pty.master,
        .flags = .{ .nonblocking = false },
    }).writeStreamingAll(io_mod.getIo(), &queued);

    try terminal.enableRawMode();
    defer terminal.disableRawMode();

    var fds = [_]std.posix.pollfd{.{
        .fd = pty.slave,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 100));
    try std.testing.expect((fds[0].revents & std.posix.POLL.IN) != 0);

    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.read(pty.slave, &buf));
    try std.testing.expectEqual(@as(u8, 3), buf[0]);
}

test "reconstructive paint re-emits a full transcript in order" {
    try @import("resize_tests.zig").testReconstructiveFullTranscriptReplay();
}

test {
    // Pull adjacent UI test files into the test binary. Declaring
    // imports inside a test block keeps them out of release builds
    // (`zig build`) but still lets `zig build test` discover and run
    // their test blocks.
    _ = @import("render_engine/terminal_diff.zig");
    _ = @import("../core/terminal/engine.zig");
    _ = @import("resize_tests.zig");
    _ = @import("../core/cli/cli_replay.zig");
}
