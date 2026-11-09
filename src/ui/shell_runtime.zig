const std = @import("std");
const activity_runtime = @import("../core/output/activity_runtime.zig");
const builtin = @import("builtin");
const debug_trace = @import("../core/shared/debug_trace.zig");
const io_mod = @import("../core/shared/io.zig");
const terminal_env = @import("../core/shared/terminal_env.zig");
const testing_pty = @import("../core/shared/testing_pty.zig");
const types = @import("../core/shared/types.zig");
const transcript_runtime = @import("transcript/runtime.zig");
const frame_layout = @import("render_engine/frame_layout.zig");
const cursor_probe = @import("terminal/cursor_probe.zig");
const resize_runtime = @import("resize_runtime.zig");
const ui_terminal = @import("terminal/terminal.zig");
const wasm_terminal = if (builtin.target.os.tag == .wasi) @import("terminal/wasm_terminal.zig") else struct {};

const Allocator = std.mem.Allocator;
const Layout = types.Layout;
const Metrics = types.Metrics;
const TranscriptRuntime = transcript_runtime.TranscriptRuntime;

const TmuxHistoryClearRunner = *const fn (Allocator, []const []const u8) anyerror!void;
var tmux_history_clear_test_runner: if (builtin.is_test) ?TmuxHistoryClearRunner else void = if (builtin.is_test) null else {};

pub const supports_resize_signal = resize_runtime.supports_resize_signal;
pub const ResizeHandler = if (builtin.target.os.tag == .wasi)
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

    pub fn ensureInteractive(self: TerminalState) !void {
        if (comptime builtin.target.os.tag == .wasi) return;
        if (std.c.isatty(self.stdin_fd) == 0 or std.c.isatty(std.posix.STDOUT_FILENO) == 0) {
            return error.NotATerminal;
        }
        // The session draws with cursor movement, which TERM=dumb lacks.
        if (terminal_env.dumbTerminal()) return error.DumbTerminal;
    }

    pub fn captureOriginalTermios(self: *TerminalState) !void {
        if (comptime builtin.target.os.tag == .wasi) return;
        self.original_termios = try io_mod.tcgetattr(self.stdin_fd);
    }

    pub fn enableRawMode(self: *TerminalState) !void {
        if (comptime builtin.target.os.tag == .wasi) {
            self.raw_enabled = true;
            return;
        }
        var raw = self.original_termios;

        raw.iflag.BRKINT = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INLCR = false;
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

        try io_mod.tcsetattr(self.stdin_fd, .NOW, raw);
        self.raw_enabled = true;
    }

    pub fn disableRawMode(self: *TerminalState) void {
        if (!self.raw_enabled) return;
        if (comptime builtin.target.os.tag != .wasi) {
            // The terminal may be gone by now: revoked, hung up, or closed
            // (`tests/tla/shell_runtime/TerminalRevoke.tla` CleanupNeverCrashes).
            io_mod.tcsetattrBestEffort(self.stdin_fd, .FLUSH, self.original_termios) catch |err| {
                debug_trace.logf("terminal", "raw_mode_restore_failed err={s}", .{@errorName(err)});
            };
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
        return if (comptime builtin.target.os.tag == .wasi)
            wasm_terminal.queryLayout(footer_rows)
        else
            ui_terminal.queryLayout(self.stdin_fd, footer_rows);
    }

    pub fn queryCursorPosition(self: TerminalState) !CursorPosition {
        if (comptime builtin.target.os.tag == .wasi) {
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
        if (comptime builtin.target.os.tag == .wasi) {
            return std.Io.File.stdin().readStreaming(io_mod.getIo(), &.{out});
        }
        return std.posix.read(self.stdin_fd, out);
    }

    /// Whether the terminal behind stdin is gone, asked after a read on it
    /// failed with EIO: `io_mod.terminalGone` on stdin.
    pub fn inputGone(self: TerminalState) bool {
        if (comptime builtin.target.os.tag == .wasi) return false;
        return io_mod.terminalGone(self.stdin_fd);
    }

    pub fn pollInput(self: TerminalState, timeout_ms: i32) !PollResult {
        if (comptime builtin.target.os.tag == .wasi) {
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
        return pollResultFromRevents(fds[0].revents);
    }
};

/// Maps the revents of a poll on stdin to a `PollResult`. POLLNVAL counts as
/// an error: a terminal that macOS revoked, or a descriptor that is no longer
/// open, reports it alone and at once on every poll, so the event loop must
/// take it as closed input rather than poll again
/// (`tests/tla/shell_runtime/TerminalRevoke.tla` NoBusyLoop).
pub fn pollResultFromRevents(revents: i16) PollResult {
    return .{
        .readable = (revents & std.posix.POLL.IN) != 0,
        .hung_up = (revents & std.posix.POLL.HUP) != 0,
        .has_error = (revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0,
    };
}

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
    // clear-history also dismisses tmux pane modes. In particular, choose-tree
    // zooms a split pane and triggers our resize reset while the chooser is open.
    // Decide inside tmux, not with a separate client-side mode query. -C runs
    // tmux commands, not a shell; only tmux's own pane_id enters command text.
    // Keep the explicit target: nested commands need not inherit run-shell's -t.
    const argv = [_][]const u8{
        "tmux",                                          "run-shell", "-C", "-t", pane,
        "#{?pane_in_mode,,clear-history -t #{pane_id}}",
    };
    if (comptime builtin.is_test) {
        if (tmux_history_clear_test_runner) |runner| return runner(alloc, &argv);
    }
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &argv,
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.TmuxClearHistoryFailed;
}

var tmux_history_clear_test_calls: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

fn failTmuxHistoryClearForTest(_: Allocator, _: []const []const u8) !void {
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

fn expectModeSafeTmuxHistoryClearForTest(_: Allocator, argv: []const []const u8) !void {
    tmux_history_clear_test_calls += 1;
    const expected = [_][]const u8{
        "tmux",                                          "run-shell", "-C", "-t", "%42",
        "#{?pane_in_mode,,clear-history -t #{pane_id}}",
    };
    try std.testing.expectEqual(expected.len, argv.len);
    for (expected, argv) |want, actual| {
        try std.testing.expectEqualStrings(want, actual);
    }
}

test "tmux history clear preserves pane modes with a server-owned target" {
    tmux_history_clear_test_calls = 0;
    tmux_history_clear_test_runner = expectModeSafeTmuxHistoryClearForTest;
    defer tmux_history_clear_test_runner = null;

    try runTmuxHistoryClear(std.testing.allocator, "%42");

    try std.testing.expectEqual(@as(usize, 1), tmux_history_clear_test_calls);
}

pub fn detectSyncUpdatesEnabled(_: Allocator) bool {
    return syncUpdatesEnabledForValues(io_mod.getenv("FX_SYNC_UPDATES"), io_mod.getenv("TERM"));
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

pub fn presentActiveToolCancellation(
    alloc: Allocator,
    shell: anytype,
) !bool {
    const Shell = @TypeOf(shell.*);
    if (comptime !@hasDecl(Shell, "presentActiveToolCancellation")) {
        return false;
    }
    return shell.presentActiveToolCancellation(alloc);
}

pub fn writeTurnCancellation(
    alloc: Allocator,
    shell: anytype,
    metrics: *Metrics,
    record: bool,
) !void {
    const Shell = @TypeOf(shell.*);
    if (comptime !@hasDecl(Shell, "writeTurnCancellation")) return;
    try shell.writeTurnCancellation(alloc, metrics, record);
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
    return switch (builtin.target.os.tag) {
        .linux => 6,
        .macos, .ios, .tvos, .watchos, .visionos => 16,
        .freebsd, .netbsd, .dragonfly, .openbsd => 16,
        else => 16,
    };
}

fn vtimeIndex() usize {
    return switch (builtin.target.os.tag) {
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

test "enableRawMode preserves already queued input" {
    if (!testing_pty.supported) return error.SkipZigTest;

    const pty = try testing_pty.TestPty.open();
    defer pty.close();

    var original = try io_mod.tcgetattr(pty.slave);
    original.lflag.ECHO = false;
    original.lflag.ICANON = false;
    original.lflag.ISIG = false;
    const vmin_idx = vminIndex();
    const vtime_idx = vtimeIndex();
    if (vmin_idx < original.cc.len and vtime_idx < original.cc.len) {
        original.cc[vmin_idx] = 1;
        original.cc[vtime_idx] = 0;
    }
    try io_mod.tcsetattr(pty.slave, .NOW, original);

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

test "enableRawMode preserves carriage return input" {
    if (!testing_pty.supported) return error.SkipZigTest;

    const pty = try testing_pty.TestPty.open();
    defer pty.close();

    var original = try io_mod.tcgetattr(pty.slave);
    original.iflag.IGNCR = true;
    original.iflag.ICRNL = true;
    original.iflag.INLCR = true;
    try io_mod.tcsetattr(pty.slave, .NOW, original);

    var terminal = TerminalState{ .stdin_fd = pty.slave };
    try terminal.captureOriginalTermios();
    try terminal.enableRawMode();
    defer terminal.disableRawMode();

    const raw = try io_mod.tcgetattr(pty.slave);
    try std.testing.expect(!raw.iflag.IGNCR);
    try std.testing.expect(!raw.iflag.ICRNL);
    try std.testing.expect(!raw.iflag.INLCR);

    const enter = [_]u8{'\r'};
    try (std.Io.File{
        .handle = pty.master,
        .flags = .{ .nonblocking = false },
    }).writeStreamingAll(io_mod.getIo(), &enter);

    var fds = [_]std.posix.pollfd{.{
        .fd = pty.slave,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 100));
    try std.testing.expect((fds[0].revents & std.posix.POLL.IN) != 0);

    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.read(pty.slave, &buf));
    try std.testing.expectEqual(@as(u8, '\r'), buf[0]);
}

test "terminal poll reports a descriptor that is not open as closed" {
    if (!testing_pty.supported) return error.SkipZigTest;

    const terminal = TerminalState{ .stdin_fd = testing_pty.closed_fd };
    const result = try terminal.pollInput(0);
    try std.testing.expect(!result.readable);
    try std.testing.expect(result.closed());
}

test "raw-mode cleanup returns for a descriptor that is not open" {
    if (!testing_pty.supported) return error.SkipZigTest;

    var terminal = TerminalState{
        .stdin_fd = testing_pty.closed_fd,
        .original_termios = std.mem.zeroes(std.posix.termios),
        .raw_enabled = true,
    };
    terminal.disableRawMode();
    try std.testing.expect(!terminal.raw_enabled);
    terminal.disableRawMode();
}

test "raw-mode cleanup restores the original termios" {
    if (!testing_pty.supported) return error.SkipZigTest;

    const pty = try testing_pty.TestPty.open();
    defer pty.close();
    var terminal = TerminalState{ .stdin_fd = pty.slave };
    try terminal.captureOriginalTermios();
    try terminal.enableRawMode();
    terminal.disableRawMode();

    const restored = try io_mod.tcgetattr(pty.slave);
    try std.testing.expectEqual(terminal.original_termios.lflag, restored.lflag);
    try std.testing.expectEqual(terminal.original_termios.iflag, restored.iflag);
    try std.testing.expectEqualSlices(u8, &terminal.original_termios.cc, &restored.cc);
    try std.testing.expect(!terminal.raw_enabled);
}

fn ignoreTestSignal(_: std.posix.SIG) callconv(.c) void {}

/// Interrupts `target` with SIGUSR2 every 10 ms for 100 ms, then reads
/// everything the PTY's slave has written, so a restore waiting for that
/// output to drain is interrupted several times before it can finish.
fn interruptThenDrain(target: std.c.pthread_t, master: std.posix.fd_t) void {
    for (0..10) |_| {
        io_mod.sleep(10 * std.time.ns_per_ms);
        _ = std.c.pthread_kill(target, .USR2);
    }
    var buf: [4096]u8 = undefined;
    var idle_polls: usize = 0;
    while (idle_polls < 5) {
        var fds = [_]std.posix.pollfd{.{ .fd = master, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 20) catch return;
        if (ready == 0) {
            idle_polls += 1;
            continue;
        }
        idle_polls = 0;
        if (std.c.read(master, &buf, buf.len) <= 0) return;
    }
}

test "raw-mode cleanup retries a restore that a signal interrupts" {
    if (!testing_pty.supported or !supports_resize_signal) return error.SkipZigTest;

    const pty = try testing_pty.TestPty.open();
    defer pty.close();
    var terminal = TerminalState{ .stdin_fd = pty.slave };
    try terminal.captureOriginalTermios();
    try terminal.enableRawMode();

    // Fill the slave's output queue, so the TCSAFLUSH restore waits for the
    // master to read it, where a signal interrupts the wait with EINTR.
    const flags = std.c.fcntl(pty.slave, std.c.F.GETFL);
    try std.testing.expect(flags >= 0);
    const nonblocking: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    try std.testing.expect(std.c.fcntl(pty.slave, std.c.F.SETFL, flags | nonblocking) >= 0);
    const fill: [1024]u8 = @splat('x');
    var queued: usize = 0;
    while (queued < 1024 * 1024) {
        const n = std.c.write(pty.slave, &fill, fill.len);
        if (n <= 0) break;
        queued += @intCast(n);
    }
    try std.testing.expect(std.c.fcntl(pty.slave, std.c.F.SETFL, flags) >= 0);

    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = ignoreTestSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old: std.posix.Sigaction = undefined;
    std.posix.sigaction(.USR2, &act, &old);
    defer std.posix.sigaction(.USR2, &old, null);

    const interrupter = try std.Thread.spawn(.{}, interruptThenDrain, .{ std.c.pthread_self(), pty.master });
    terminal.disableRawMode();
    interrupter.join();

    const restored = try io_mod.tcgetattr(pty.slave);
    try std.testing.expectEqual(terminal.original_termios.lflag, restored.lflag);
    try std.testing.expectEqual(terminal.original_termios.iflag, restored.iflag);
}

test "a revoked terminal polls as closed and its cleanup returns" {
    if (comptime !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const pty = try testing_pty.TestPty.open();
    defer pty.close();
    var terminal = TerminalState{ .stdin_fd = pty.slave };
    try terminal.captureOriginalTermios();
    try terminal.enableRawMode();
    try pty.revokeSlave();

    // macOS reports a revoked terminal as POLLNVAL alone, at once.
    const result = try terminal.pollInput(0);
    try std.testing.expect(!result.readable);
    try std.testing.expect(result.closed());
    terminal.disableRawMode();
    try std.testing.expect(!terminal.raw_enabled);
}

test "the best-effort restore returns for a revoked terminal" {
    if (comptime !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const pty = try testing_pty.TestPty.open();
    defer pty.close();
    const original = try io_mod.tcgetattr(pty.slave);
    try pty.revokeSlave();

    // macOS answers ENOENT for a terminal it revoked.
    try io_mod.tcsetattrBestEffort(pty.slave, .FLUSH, original);
}

test "a terminal that is still there is not gone" {
    if (!testing_pty.supported) return error.SkipZigTest;

    // A background read that SIGTTIN does not stop fails with EIO on a
    // terminal like this one, which still polls quietly and answers tcgetattr.
    const pty = try testing_pty.TestPty.open();
    defer pty.close();
    try std.testing.expect(!(TerminalState{ .stdin_fd = pty.slave }).inputGone());
}

test "a revoked terminal is gone" {
    if (comptime !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

    const pty = try testing_pty.TestPty.open();
    defer pty.close();
    try pty.revokeSlave();
    try std.testing.expect((TerminalState{ .stdin_fd = pty.slave }).inputGone());
}

test "a terminal whose other side closed is gone" {
    if (!testing_pty.supported) return error.SkipZigTest;

    const pty = try testing_pty.TestPty.open();
    testing_pty.closeFd(pty.master);
    defer testing_pty.closeFd(pty.slave);
    try std.testing.expect((TerminalState{ .stdin_fd = pty.slave }).inputGone());
}

test "a descriptor that is not open is gone" {
    if (!testing_pty.supported) return error.SkipZigTest;

    try std.testing.expect((TerminalState{ .stdin_fd = testing_pty.closed_fd }).inputGone());
}

test "stdin that answers no tcgetattr is gone even when its poll is quiet" {
    if (!testing_pty.supported) return error.SkipZigTest;

    // macOS 15 can report a revoked controlling terminal as readable, with
    // no POLLHUP or POLLNVAL; only tcgetattr then shows it is gone. An empty
    // pipe whose writer is open polls quietly and is no terminal at all.
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer testing_pty.closeFd(fds[0]);
    defer testing_pty.closeFd(fds[1]);
    try std.testing.expect((TerminalState{ .stdin_fd = fds[0] }).inputGone());
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
