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

pub const supports_resize_signal = resize_runtime.supports_resize_signal;
pub const ResizeHandler = if (builtin.os.tag == .wasi)
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

pub const TerminalState = struct {
    stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO,
    original_termios: std.posix.termios = undefined,
    raw_enabled: bool = false,
    alternate_screen_owner: AlternateScreenOwner = .none,
    alternate_frame_layout: frame_layout.CommittedLayoutSnapshot = .{},
    alternate_mouse_tracking_active: bool = false,
    signal_handler_installed: bool = false,
    old_winch_action: ?std.posix.Sigaction = null,

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
        if (comptime builtin.os.tag == .wasi) return;
        if (std.c.isatty(self.stdin_fd) == 0 or std.c.isatty(std.posix.STDOUT_FILENO) == 0) {
            return error.NotATerminal;
        }
    }

    pub fn captureOriginalTermios(self: *TerminalState) !void {
        if (comptime builtin.os.tag == .wasi) return;
        self.original_termios = try std.posix.tcgetattr(self.stdin_fd);
    }

    pub fn enableRawMode(self: *TerminalState) !void {
        if (comptime builtin.os.tag == .wasi) {
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
        if (comptime builtin.os.tag != .wasi) {
            std.posix.tcsetattr(self.stdin_fd, .FLUSH, self.original_termios) catch {};
        }
        self.raw_enabled = false;
    }

    pub fn installResizeSignal(self: *TerminalState, handler: ResizeHandler) void {
        if (!supports_resize_signal) return;

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
            .fd = self.stdin_fd,
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
