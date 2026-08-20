const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts.zig");
const monitor_core = @import("monitor.zig");
const terminal_engine = @import("engine.zig");
const shell_resolver = @import("shell_resolver.zig");
const terminal_store = @import("store.zig");
const tmux_session = @import("tmux_session.zig");
const host_capabilities = @import("../hosts/host.zig");
const session_layout = @import("../session/session_layout.zig");
const process_supervisor = @import("../background/process_supervisor.zig");
const background_process_provider = @import(
    "../execution/background_process_provider.zig",
);
const process_tree = @import("../execution/process_tree.zig");
const command_admission = @import("../permissions/command_admission.zig");
const command_runner = @import("../execution/command_runner.zig");
const execution_router = @import("../execution/router.zig");
const io_mod = @import("../shared/io.zig");
const self_exe = @import("../shared/self_exe.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");
const workspace_pathing = @import("../workspace/pathing.zig");

const Allocator = std.mem.Allocator;

const launcher_mode = "--fx-internal-terminal-launcher";
const control_mode = "--fx-internal-terminal-control";

const max_sessions: usize = 16;
const max_read_bytes: usize = 64 * 1024;
const launcher_config_bytes: usize = contracts.max_command_bytes * 6 +
    contracts.max_authority_text_bytes * 2 +
    contracts.max_shell_path_bytes * 2 +
    4096;
const wait_poll_ns: u64 = 5 * std.time.ns_per_ms;
const graceful_close_ms: i64 = 800;
const control_poll_ms: i32 = 50;
const marker_frame_timeout_ms: i64 = 5_000;
const marker_ack_timeout_ms: i64 = tmux_session.marker_acknowledgement_timeout_ms;
const command_release_byte: u8 = 2;
const control_nonce_len: usize = 32;
const marker_frame_len: usize = control_nonce_len + 1;
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const default_dimensions: contracts.Dimensions = .{
    .rows = 24,
    .columns = 80,
};
const ioctl_set_controlling_terminal: c_int = switch (builtin.os.tag) {
    .macos => 0x20007461,
    .linux => @intCast(std.os.linux.T.IOCSCTTY),
    else => 0,
};
const ioctl_set_window_size: c_int = switch (builtin.os.tag) {
    .macos => @bitCast(@as(u32, 0x80087467)),
    .linux => @intCast(std.os.linux.T.IOCSWINSZ),
    else => 0,
};

const control_frame_len: usize = 5;
const ControlKind = enum(u8) {
    prepared = 1,
    shell_ready = 2,
    command_started = 3,
    command_exited = 4,
    command_signal = 5,
    startup_failed = 6,
    invalid_term = 7,
};

const StartupFailure = enum(u32) {
    shell_unavailable = 1,
    profile_failed = 2,
    control_failed = 3,
};

const MarkerKind = enum(u8) {
    shell_ready = 1,
    command_started = 2,
};

const LauncherConfig = struct {
    argv: []const []const u8,
    cwd: []const u8,
    dimensions: contracts.Dimensions,
    control_path: []const u8,
    control_nonce: []const u8,
    bootstrap_path: []const u8,
    bootstrap: []const u8,
    command_path: ?[]const u8,
    command: ?[]const u8,
};

const LauncherWatchdog = struct {
    child_pid: std.posix.pid_t,
    done: std.atomic.Value(bool) = .init(false),
    command_released: std.atomic.Value(bool) = .init(false),
    host_closed: std.atomic.Value(bool) = .init(false),

    fn run(self: *LauncherWatchdog) void {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        while (!self.done.load(.acquire)) {
            poll_fds[0].revents = 0;
            _ = std.posix.poll(&poll_fds, control_poll_ms) catch {
                self.host_closed.store(true, .release);
                _ = std.c.kill(-self.child_pid, std.c.SIG.KILL);
                return;
            };
            if (poll_fds[0].revents == 0) continue;
            var byte: [1]u8 = undefined;
            const count = std.posix.read(std.posix.STDIN_FILENO, &byte) catch 0;
            if (count != 0) {
                if (byte[0] == command_release_byte) {
                    self.command_released.store(true, .release);
                }
                continue;
            }
            self.host_closed.store(true, .release);
            if (!self.done.load(.acquire)) {
                _ = std.c.kill(-self.child_pid, std.c.SIG.KILL);
            }
            return;
        }
    }
};

const ControlPhase = enum {
    awaiting_shell,
    shell_ready,
    command_started,
};

const LauncherControl = struct {
    server: *std.Io.net.Server,
    control_path: []const u8,
    bootstrap_path: []const u8,
    nonce: []const u8,
    command_path: ?[]const u8,
    child_pid: std.posix.pid_t,
    watchdog: *LauncherWatchdog,
    done: std.atomic.Value(bool) = .init(false),
    phase: ControlPhase = .awaiting_shell,
    failed: bool = false,

    fn run(self: *LauncherControl) void {
        self.runInner() catch {
            self.failed = true;
        };
    }

    fn runInner(self: *LauncherControl) !void {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = self.server.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        while (!self.done.load(.acquire)) {
            poll_fds[0].revents = 0;
            _ = try std.posix.poll(&poll_fds, control_poll_ms);
            if (poll_fds[0].revents == 0) continue;

            var stream = self.server.accept(io_mod.getIo()) catch |err| switch (err) {
                error.ConnectionAborted, error.WouldBlock => continue,
                else => return err,
            };
            defer stream.close(io_mod.getIo());
            var bytes: [marker_frame_len]u8 = undefined;
            receiveSocketExact(
                stream.socket,
                &bytes,
                marker_frame_timeout_ms,
            ) catch continue;
            if (!std.mem.eql(
                u8,
                self.nonce,
                bytes[0..control_nonce_len],
            )) continue;
            const kind: MarkerKind = switch (bytes[control_nonce_len]) {
                1 => .shell_ready,
                2 => .command_started,
                else => continue,
            };
            if (!try self.acceptMarker(kind)) continue;
            const finished = self.phase == .command_started or
                (self.phase == .shell_ready and self.command_path == null);
            if (finished) {
                std.Io.Dir.deleteFileAbsolute(
                    io_mod.getIo(),
                    self.control_path,
                ) catch {};
            }
            try writeAllFd(stream.socket.handle, &.{1}, false);
            if (finished) {
                return;
            }
        }
    }

    fn acceptMarker(
        self: *LauncherControl,
        kind: MarkerKind,
    ) !bool {
        switch (kind) {
            .shell_ready => {
                if (self.phase != .awaiting_shell) return false;
                setEcho(std.posix.STDOUT_FILENO, true) catch {};
                std.Io.Dir.deleteFileAbsolute(
                    io_mod.getIo(),
                    self.bootstrap_path,
                ) catch {};
                try writeControlFd(
                    std.posix.STDERR_FILENO,
                    .shell_ready,
                    @intCast(self.child_pid),
                );
                self.phase = .shell_ready;
            },
            .command_started => {
                if (self.phase != .shell_ready or
                    self.command_path == null) return false;
                std.Io.Dir.deleteFileAbsolute(
                    io_mod.getIo(),
                    self.command_path.?,
                ) catch {};
                try writeControlFd(
                    std.posix.STDERR_FILENO,
                    .command_started,
                    @intCast(self.child_pid),
                );
                while (!self.watchdog.command_released.load(.acquire)) {
                    if (self.watchdog.host_closed.load(.acquire)) {
                        return error.LauncherHostClosed;
                    }
                    io_mod.sleep(wait_poll_ns);
                }
                self.phase = .command_started;
            },
        }
        return true;
    }
};

pub const WorkTracker = struct {
    context: ?*anyopaque,
    update_fn: *const fn (?*anyopaque, bool) void,
    monitor_update_fn: ?*const fn (?*anyopaque, bool) void = null,

    fn update(self: WorkTracker, live: bool) void {
        self.update_fn(self.context, live);
    }

    fn updateMonitor(self: WorkTracker, required: bool) void {
        const callback = self.monitor_update_fn orelse return;
        callback(self.context, required);
    }
};

fn isSupported() bool {
    return isSupportedForOs(builtin.os.tag);
}

fn isSupportedForOs(os_tag: std.Target.Os.Tag) bool {
    return host_capabilities.terminalSupportForOs(os_tag).isSupported();
}

test "native terminal backend selection follows canonical platform support" {
    const os_tags = [_]std.Target.Os.Tag{
        .macos,
        .linux,
        .windows,
        .wasi,
        .freebsd,
        .emscripten,
    };
    for (os_tags) |os_tag| {
        try std.testing.expectEqual(
            host_capabilities.terminalSupportForOs(os_tag).isSupported(),
            isSupportedForOs(os_tag),
        );
    }
    try std.testing.expectEqual(isSupportedForOs(builtin.os.tag), isSupported());
    const ExpectedRegistry = if (comptime host_capabilities
        .terminalSupportForOs(builtin.os.tag)
        .isSupported())
        SupportedRegistry
    else
        UnsupportedRegistry;
    try std.testing.expectEqualStrings(
        @typeName(ExpectedRegistry),
        @typeName(Registry),
    );
}

pub fn isLauncherModeRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 2 and
        std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), launcher_mode);
}

pub fn isControlModeRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 5 and
        std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), control_mode);
}

pub fn runControlMarker(raw_args: []const [*:0]const u8) !void {
    if (comptime !isSupported()) return error.TerminalHostUnsupported;
    if (!isControlModeRaw(raw_args)) return error.InvalidControlMarker;
    const control_path = std.mem.sliceTo(raw_args[2], 0);
    const nonce = std.mem.sliceTo(raw_args[3], 0);
    const event = std.mem.sliceTo(raw_args[4], 0);
    if (nonce.len != control_nonce_len) return error.InvalidControlMarker;
    const kind: MarkerKind =
        if (std.mem.eql(u8, event, "shell-ready"))
            .shell_ready
        else if (std.mem.eql(u8, event, "command-started"))
            .command_started
        else
            return error.InvalidControlMarker;

    const tmux_failure = if (std.mem.startsWith(
        u8,
        control_path,
        "/tmp/fx-tmux-marker-",
    ))
        io_mod.getenv("FX_TERMINAL_TEST_TMUX_MARKER_FAILURE")
    else
        null;
    if (tmux_failure) |failure| {
        if (std.mem.eql(u8, failure, "child-exit")) {
            return error.InjectedTmuxMarkerChildExit;
        }
        if (std.mem.eql(u8, failure, "no-peer")) {
            while (true) io_mod.sleep(wait_poll_ns);
        }
    }

    var bytes: [marker_frame_len]u8 = @splat(0);
    @memcpy(bytes[0..control_nonce_len], nonce);
    bytes[control_nonce_len] = @intFromEnum(kind);
    const address = try std.Io.net.UnixAddress.init(control_path);
    var stream = try address.connect(io_mod.getIo());
    defer stream.close(io_mod.getIo());
    if (tmux_failure) |failure| {
        if (std.mem.eql(u8, failure, "silent-peer")) {
            while (true) io_mod.sleep(wait_poll_ns);
        }
        if (std.mem.eql(u8, failure, "partial-marker")) {
            try writeAllFd(
                stream.socket.handle,
                bytes[0 .. bytes.len / 2],
                false,
            );
            while (true) io_mod.sleep(wait_poll_ns);
        }
        if (std.mem.eql(u8, failure, "invalid-nonce")) {
            bytes[0] ^= 1;
            try writeAllFd(stream.socket.handle, &bytes, false);
            while (true) io_mod.sleep(wait_poll_ns);
        }
    }
    try writeAllFd(stream.socket.handle, &bytes, false);
    var ack: [1]u8 = undefined;
    try receiveSocketExact(stream.socket, &ack, marker_ack_timeout_ms);
    if (ack[0] != 1) return error.ControlMarkerRejected;
}

fn writePrivateLauncherFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        path,
        .{
            .exclusive = true,
            .permissions = private_file_permissions,
        },
    );
    errdefer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), bytes);
}

pub fn runLauncher(alloc: Allocator) !void {
    if (comptime !isSupported()) return error.TerminalHostUnsupported;

    var length_bytes: [4]u8 = undefined;
    try readExactFd(std.posix.STDIN_FILENO, &length_bytes);
    const config_len = std.mem.readInt(u32, &length_bytes, .little);
    if (config_len == 0 or config_len > launcher_config_bytes) {
        return error.InvalidLauncherConfig;
    }
    const config_bytes = try alloc.alloc(u8, config_len);
    defer alloc.free(config_bytes);
    try readExactFd(std.posix.STDIN_FILENO, config_bytes);
    var parsed = try std.json.parseFromSlice(
        LauncherConfig,
        alloc,
        config_bytes,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    if (parsed.value.argv.len == 0) return error.InvalidLauncherConfig;
    if (!std.fs.path.isAbsolute(parsed.value.cwd) or
        !std.fs.path.isAbsolute(parsed.value.control_path) or
        !std.fs.path.isAbsolute(parsed.value.bootstrap_path) or
        parsed.value.control_nonce.len != control_nonce_len or
        (parsed.value.command == null) != (parsed.value.command_path == null))
    {
        return error.InvalidLauncherConfig;
    }
    if (parsed.value.command_path) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidLauncherConfig;
    }
    try parsed.value.dimensions.validate();

    var bootstrap_created = false;
    defer if (bootstrap_created) {
        std.Io.Dir.deleteFileAbsolute(
            io_mod.getIo(),
            parsed.value.bootstrap_path,
        ) catch {};
    };
    try writePrivateLauncherFile(
        parsed.value.bootstrap_path,
        parsed.value.bootstrap,
    );
    bootstrap_created = true;
    var command_created = false;
    defer if (command_created) {
        std.Io.Dir.deleteFileAbsolute(
            io_mod.getIo(),
            parsed.value.command_path.?,
        ) catch {};
    };
    if (parsed.value.command) |command| {
        try writePrivateLauncherFile(parsed.value.command_path.?, command);
        command_created = true;
    }
    std.Io.Dir.deleteFileAbsolute(
        io_mod.getIo(),
        parsed.value.control_path,
    ) catch {};
    const address = try std.Io.net.UnixAddress.init(parsed.value.control_path);
    var server = try address.listen(io_mod.getIo(), .{});
    defer server.deinit(io_mod.getIo());
    defer std.Io.Dir.deleteFileAbsolute(
        io_mod.getIo(),
        parsed.value.control_path,
    ) catch {};
    try std.Io.Dir.cwd().setFilePermissions(
        io_mod.getIo(),
        parsed.value.control_path,
        private_file_permissions,
        .{ .follow_symlinks = false },
    );

    if (std.c.setsid() < 0) return error.SessionCreationFailed;
    if (std.c.ioctl(
        std.posix.STDOUT_FILENO,
        ioctl_set_controlling_terminal,
        @as(c_int, 0),
    ) < 0) return error.ControllingTerminalFailed;
    try resizeFd(std.posix.STDOUT_FILENO, parsed.value.dimensions);
    try writeControlFd(std.posix.STDERR_FILENO, .prepared, 0);

    var release: [1]u8 = undefined;
    try readExactFd(std.posix.STDIN_FILENO, &release);
    if (release[0] != 1) return error.InvalidLauncherRelease;

    const terminal_file = std.Io.File{
        .handle = std.posix.STDOUT_FILENO,
        .flags = .{ .nonblocking = false },
    };
    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = parsed.value.argv,
        .stdin = .{ .file = terminal_file },
        .stdout = .{ .file = terminal_file },
        .stderr = .{ .file = terminal_file },
        .cwd = .{ .path = parsed.value.cwd },
        .pgid = 0,
    }) catch {
        try writeControlFd(
            std.posix.STDERR_FILENO,
            .startup_failed,
            @intFromEnum(StartupFailure.shell_unavailable),
        );
        return;
    };
    var child_running = true;
    errdefer if (child_running) child.kill(io_mod.getIo());
    const child_pid = child.id orelse return error.ChildIdentityMissing;
    if (tcsetpgrp(std.posix.STDOUT_FILENO, child_pid) != 0) {
        return error.ForegroundProcessGroupFailed;
    }
    var watchdog = LauncherWatchdog{ .child_pid = child_pid };
    var control = LauncherControl{
        .server = &server,
        .control_path = parsed.value.control_path,
        .bootstrap_path = parsed.value.bootstrap_path,
        .nonce = parsed.value.control_nonce,
        .command_path = parsed.value.command_path,
        .child_pid = child_pid,
        .watchdog = &watchdog,
    };
    var control_thread = try std.Thread.spawn(
        .{},
        LauncherControl.run,
        .{&control},
    );
    var watchdog_thread = std.Thread.spawn(
        .{},
        LauncherWatchdog.run,
        .{&watchdog},
    ) catch |err| {
        control.done.store(true, .release);
        child.kill(io_mod.getIo());
        child_running = false;
        control_thread.join();
        return err;
    };
    const term = waitLauncherChild(&child) catch |err| {
        watchdog.done.store(true, .release);
        control.done.store(true, .release);
        child.kill(io_mod.getIo());
        child_running = false;
        watchdog_thread.join();
        control_thread.join();
        return err;
    };
    child_running = false;
    watchdog.done.store(true, .release);
    control.done.store(true, .release);
    watchdog_thread.join();
    control_thread.join();
    closeFd(std.posix.STDOUT_FILENO);
    if (control.failed) {
        try writeControlFd(
            std.posix.STDERR_FILENO,
            .startup_failed,
            @intFromEnum(StartupFailure.control_failed),
        );
        return;
    }
    const trusted_term = control.phase == .command_started or
        (control.phase == .shell_ready and parsed.value.command == null);
    if (!trusted_term) {
        try writeControlFd(
            std.posix.STDERR_FILENO,
            .startup_failed,
            @intFromEnum(StartupFailure.profile_failed),
        );
        return;
    }
    switch (term) {
        .exited => |code| try writeControlFd(
            std.posix.STDERR_FILENO,
            .command_exited,
            code,
        ),
        .signal => |signal| try writeControlFd(
            std.posix.STDERR_FILENO,
            .command_signal,
            @intFromEnum(signal),
        ),
        .stopped, .unknown => try writeControlFd(
            std.posix.STDERR_FILENO,
            .invalid_term,
            0,
        ),
    }
}

fn signalLauncherProcessGroup(pid: std.c.pid_t, signal: std.c.SIG) !void {
    while (true) switch (std.c.errno(std.c.kill(-pid, signal))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.ChildSignalFailed,
    };
}

fn launcherStatusToTerm(raw_status: u32) std.process.Child.Term {
    return if (std.c.W.IFEXITED(raw_status))
        .{ .exited = std.c.W.EXITSTATUS(raw_status) }
    else if (std.c.W.IFSIGNALED(raw_status))
        .{ .signal = std.c.W.TERMSIG(raw_status) }
    else if (std.c.W.IFSTOPPED(raw_status))
        .{ .stopped = std.c.W.STOPSIG(raw_status) }
    else
        .{ .unknown = raw_status };
}

test "launcher wait status classifies terminal results before stops" {
    try std.testing.expectEqual(
        std.process.Child.Term{ .exited = 23 },
        launcherStatusToTerm(23 << 8),
    );
    try std.testing.expectEqual(
        std.process.Child.Term{ .signal = .TERM },
        launcherStatusToTerm(@intFromEnum(std.c.SIG.TERM)),
    );
    try std.testing.expectEqual(
        std.process.Child.Term{ .signal = .SEGV },
        launcherStatusToTerm(@intFromEnum(std.c.SIG.SEGV) | 0x80),
    );
    try std.testing.expectEqual(
        std.process.Child.Term{ .stopped = .TTIN },
        launcherStatusToTerm((@as(u32, @intFromEnum(std.c.SIG.TTIN)) << 8) | 0x7f),
    );
}

fn waitLauncherChild(child: *std.process.Child) !std.process.Child.Term {
    const pid = child.id orelse return error.ChildIdentityMissing;
    var observe_stops = true;
    while (true) {
        var status: c_int = undefined;
        const flags: c_int = if (observe_stops) std.c.W.UNTRACED else 0;
        const waited = std.c.waitpid(pid, &status, flags);
        switch (std.c.errno(waited)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ChildWaitFailed,
        }
        if (waited != pid) return error.ChildWaitFailed;

        const raw_status: u32 = @bitCast(status);
        const term = launcherStatusToTerm(raw_status);
        switch (term) {
            .stopped => |signal| {
                if (signal == std.c.SIG.TTIN or signal == std.c.SIG.TTOU) {
                    try signalLauncherProcessGroup(pid, std.c.SIG.CONT);
                    debug_trace.logf(
                        "terminal_host",
                        "resumed terminal child after foreground race pid={d}",
                        .{pid},
                    );
                } else {
                    observe_stops = false;
                }
                continue;
            },
            .exited, .signal, .unknown => {},
        }

        std.debug.assert(child.stdin == null);
        std.debug.assert(child.stdout == null);
        std.debug.assert(child.stderr == null);
        child.id = null;
        return term;
    }
}

pub const Registry = if (isSupported()) SupportedRegistry else UnsupportedRegistry;

const UnsupportedRegistry = struct {
    alloc: Allocator,

    pub fn init(
        alloc: Allocator,
        _: WorkTracker,
        _: *terminal_store.ProfileStore,
        _: []const u8,
        _: []const u8,
        _: []const u8,
    ) !UnsupportedRegistry {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *UnsupportedRegistry) void {
        self.* = undefined;
    }

    pub fn executeAuthorized(
        self: *UnsupportedRegistry,
        request: contracts.ActionRequest,
        _: *const std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .failure = .{
                .action = request.action(),
                .code = .unsupported_host,
            } },
        ) catch return error.OutOfMemory;
    }

    pub fn cancelAuthorized(
        _: *UnsupportedRegistry,
        _: []const u8,
        _: contracts.AuthorityClaim,
    ) !void {}
};

const SupportedRegistry = struct {
    alloc: Allocator,
    tracker: WorkTracker,
    profile: *terminal_store.ProfileStore,
    host_identity: []const u8,
    durable_root: []const u8,
    transport_root: []const u8,
    mutex: std.Io.Mutex = .init,
    sessions: [max_sessions]?*Session = @splat(null),
    references: [max_sessions]usize = @splat(0),
    recycle_cursor: usize = 0,
    recovery: ?terminal_store.RecoveredList = null,

    pub fn init(
        alloc: Allocator,
        tracker: WorkTracker,
        profile: *terminal_store.ProfileStore,
        host_identity: []const u8,
        durable_root: []const u8,
        transport_root: []const u8,
    ) !SupportedRegistry {
        var registry = SupportedRegistry{
            .alloc = alloc,
            .tracker = tracker,
            .profile = profile,
            .host_identity = host_identity,
            .durable_root = durable_root,
            .transport_root = transport_root,
        };
        errdefer registry.deinitRecoveryAttempt();
        var recovered = try profile.recover(host_identity, io_mod.milliTimestamp());
        var recovered_owned = true;
        errdefer if (recovered_owned) recovered.deinit();
        for (recovered.sessions.items) |*durable| {
            if (!(try durable.close_cleanup_pending())) continue;
            try finalizeRecoveredCloseBackend(
                alloc,
                profile.process_provider,
                durable_root,
                transport_root,
                durable.record,
            );
            try durable.finish_close(io_mod.milliTimestamp());
        }
        while (recovered.sessions.pop()) |recovered_session| {
            var durable = recovered_session;
            var durable_owned = true;
            defer if (durable_owned) durable.deinit();
            if (durable.record.backend == .tmux and
                (durable.record.lifecycle == .starting or
                    durable.record.lifecycle == .running))
            {
                durable_owned = false;
                try registry.recoverTmux(durable);
                continue;
            }
            if (durable.record.backend == .tmux) {
                tmux_session.cleanupOwnedNamespace(
                    alloc,
                    profile.process_provider,
                    durable_root,
                    transport_root,
                    durable.record.backend_identity,
                );
            }
            finalizeRecoveredMonitors(alloc, &durable, io_mod.milliTimestamp()) catch |err| {
                debug_trace.logf(
                    "terminal_monitor",
                    "recovered monitor cleanup deferred id={s} err={s}",
                    .{ durable.record.session_id, @errorName(err) },
                );
            };
        }
        registry.recovery = recovered;
        recovered_owned = false;
        return registry;
    }

    fn recoverTmux(
        self: *SupportedRegistry,
        durable: terminal_store.DurableSession,
    ) !void {
        const session = try self.alloc.create(Session);
        var initialized = false;
        defer if (!initialized) self.alloc.destroy(session);
        session.* = Session.initRecovered(
            self.alloc,
            self.tracker,
            durable,
        ) catch |err| return err;
        initialized = true;
        var session_owned = true;
        defer if (session_owned) {
            session.deinitRecoveryAttempt();
            self.alloc.destroy(session);
        };
        try session.initMonitorOwner();
        try self.profile.register_resident(&session.durable);
        const slot = self.reserve(session) orelse return error.CapacityExceeded;
        std.debug.assert(slot.evicted == null);
        var reserved = true;
        defer if (reserved) self.removeOwned(slot.index, session);
        session.markLive();
        const remains_live = session.recoverTmux(
            self.durable_root,
            self.transport_root,
        ) catch |err| {
            debug_trace.logf(
                "terminal_host",
                "tmux recovery deferred id={s} err={s}",
                .{ session.id, @errorName(err) },
            );
            session.markNotLive();
            if (!definitiveTmuxRecoveryLoss(err)) return err;
            session.cleanupDefinitiveTmuxRecoveryAttempt() catch |cleanup_err| {
                debug_trace.logf(
                    "terminal_host",
                    "tmux definitive recovery cleanup deferred id={s} err={s}",
                    .{ session.id, @errorName(cleanup_err) },
                );
                return cleanup_err;
            };
            session.markLost();
            finalizeRecoveredMonitors(
                self.alloc,
                &session.durable,
                io_mod.milliTimestamp(),
            ) catch {};
            return;
        };
        if (!remains_live) {
            session.markNotLive();
            finalizeRecoveredMonitors(
                self.alloc,
                &session.durable,
                io_mod.milliTimestamp(),
            ) catch {};
            return;
        }
        self.releaseReference(slot.index, session);
        reserved = false;
        session_owned = false;
    }

    pub fn deinit(self: *SupportedRegistry) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        var sessions = self.sessions;
        self.sessions = @splat(null);
        self.mutex.unlock(zio);

        for (&sessions) |*entry| {
            const session = entry.* orelse continue;
            session.shutdown();
        }
        for (&sessions) |*entry| {
            const session = entry.* orelse continue;
            session.deinit();
            self.alloc.destroy(session);
        }
        if (self.recovery) |*recovered| recovered.deinit();
        self.* = undefined;
    }

    fn deinitRecoveryAttempt(self: *SupportedRegistry) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        var sessions = self.sessions;
        self.sessions = @splat(null);
        self.mutex.unlock(zio);

        for (&sessions) |*entry| {
            const session = entry.* orelse continue;
            session.deinitRecoveredRegistryAttempt();
            self.alloc.destroy(session);
        }
        if (self.recovery) |*recovered| recovered.deinit();
        self.* = undefined;
    }

    pub fn executeAuthorized(
        self: *SupportedRegistry,
        request: contracts.ActionRequest,
        cancelled: *const std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        return switch (request) {
            .start => |value| self.start(value, cancelled),
            .read => |value| self.read(value),
            .screen => |value| self.screen(value),
            .write => |value| self.withSession(
                .write,
                value.session_id,
                writeAction,
                .{ value, cancelled },
            ),
            .wait => |value| self.wait(value, cancelled),
            .monitor => |value| self.monitor(value, cancelled),
            .inspect => |value| self.inspect(value),
            .list => |value| self.list(value),
            .resize => |value| self.withSession(
                .resize,
                value.session_id,
                resizeAction,
                .{value},
            ),
            .signal => |value| self.withSession(
                .signal,
                value.session_id,
                signalAction,
                .{value},
            ),
            .close => |value| self.close(value),
        };
    }

    pub fn cancelAuthorized(
        self: *SupportedRegistry,
        session_id: []const u8,
        claim: contracts.AuthorityClaim,
    ) !void {
        if (self.find(session_id)) |reference| {
            defer self.releaseReference(reference.index, reference.session);
            try reference.session.durable.cancel_claim(
                claim,
                io_mod.milliTimestamp(),
            );
            return;
        }

        if (io_mod.getenv("FX_TERMINAL_TEST_FAIL_CANCELLATION_OPEN") != null) {
            return error.InjectedCancellationOpenFailure;
        }
        const durable = try self.profile.open_terminal(session_id);
        defer self.profile.release_terminal(durable);
        try durable.cancel_claim(claim, io_mod.milliTimestamp());
    }

    fn read(
        self: *SupportedRegistry,
        request: contracts.ReadRequest,
    ) Allocator.Error!contracts.OwnedResult {
        if (self.find(request.session_id)) |reference| {
            defer self.releaseReference(reference.index, reference.session);
            return readAction(reference.session, request) catch |err|
                self.actionError(.read, request.session_id, err);
        }
        const durable = self.profile.open_terminal(request.session_id) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.read, .session_not_found, request.session_id);
        };
        defer self.profile.release_terminal(durable);
        const authorization = durable.authorize(
            request.authority.?,
            .read,
        ) catch |err| return self.actionError(.read, request.session_id, err);
        var page = durable.read(self.alloc, request.cursor, max_read_bytes) catch |err| {
            return self.actionError(.read, request.session_id, err);
        };
        defer page.deinit(self.alloc);
        const facts = projectedFacts(durable.facts(), authorization);
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .read = .{
                .session = facts,
                .output = page.output,
                .raw_range = page.range,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn inspect(
        self: *SupportedRegistry,
        request: contracts.SessionRequest,
    ) Allocator.Error!contracts.OwnedResult {
        if (self.find(request.session_id)) |reference| {
            defer self.releaseReference(reference.index, reference.session);
            return inspectAction(reference.session, request) catch |err|
                self.actionError(.inspect, request.session_id, err);
        }
        const durable = self.profile.open_terminal(request.session_id) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.inspect, .session_not_found, request.session_id);
        };
        defer self.profile.release_terminal(durable);
        const authorization = durable.authorize(
            request.authority.?,
            .inspect,
        ) catch |err| return self.actionError(.inspect, request.session_id, err);
        const facts = projectedFacts(durable.facts(), authorization);
        var events = projectMonitorEvents(self.alloc, durable, request) catch |err| {
            return self.actionError(.inspect, request.session_id, err);
        };
        defer events.deinit();
        var monitor_set = durable.load_monitor_set(self.alloc) catch |err| {
            return self.actionError(.inspect, request.session_id, err);
        };
        defer monitor_set.deinit();
        const monitors = try self.alloc.alloc(
            contracts.MonitorSummary,
            monitor_set.parsed.value.monitors.len,
        );
        defer self.alloc.free(monitors);
        for (monitor_set.parsed.value.monitors, 0..) |entry, index| {
            monitors[index] = .{
                .monitor_id = entry.monitor_id,
                .state = entry.runtime.state,
            };
        }
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .inspect = .{
                .session = facts,
                .shell = durable.record.shell,
                .cwd = durable.record.cwd,
                .command = durable.record.command,
                .monitors = monitors,
                .events = events.items,
                .event_gap_through = events.gap_through,
                .next_event_id = events.next_event_id,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn screen(
        self: *SupportedRegistry,
        request: contracts.SessionRequest,
    ) Allocator.Error!contracts.OwnedResult {
        if (self.find(request.session_id)) |reference| {
            defer self.releaseReference(reference.index, reference.session);
            return screenAction(reference.session, request) catch |err|
                self.actionError(.screen, request.session_id, err);
        }
        const durable = self.profile.open_terminal(request.session_id) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.screen, .session_not_found, request.session_id);
        };
        defer self.profile.release_terminal(durable);
        const authorization = durable.authorize(
            request.authority.?,
            .screen,
        ) catch |err| return self.actionError(.screen, request.session_id, err);
        return screenDurable(self.alloc, durable, authorization) catch |err|
            self.actionError(.screen, request.session_id, err);
    }

    fn close(
        self: *SupportedRegistry,
        request: contracts.CloseRequest,
    ) Allocator.Error!contracts.OwnedResult {
        if (self.find(request.session_id)) |reference| {
            defer self.releaseReference(reference.index, reference.session);
            return closeAction(reference.session, request) catch |err|
                self.actionError(.close, request.session_id, err);
        }
        const durable = self.profile.open_terminal(request.session_id) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.close, .session_not_found, request.session_id);
        };
        defer self.profile.release_terminal(durable);
        const now_ms = io_mod.milliTimestamp();
        requireCloseCandidate(
            request.session_id,
            durable.begin_close(request.authority.?, now_ms),
        ) catch |err| return self.actionError(.close, request.session_id, err);
        durable.finish_close(now_ms) catch |err| {
            return self.actionError(.close, request.session_id, err);
        };
        var facts = durable.facts();
        facts.next_actions = .{};
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .close = .{
                .session = facts,
                .policy = request.policy,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn start(
        self: *SupportedRegistry,
        request: contracts.StartRequest,
        cancelled: *const std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        if (!isSupported()) {
            return self.failure(.start, .unsupported_host, null);
        }
        const persistence = request.persistence orelse
            return self.failure(.start, .authority_denied, null);

        const session_id = try session_layout.generateSessionId(self.alloc);
        var session_id_owned = true;
        defer if (session_id_owned) self.alloc.free(session_id);
        const session = try self.alloc.create(Session);
        var session_owned = true;
        defer if (session_owned) self.alloc.destroy(session);
        session.* = Session.init(
            self.alloc,
            self.tracker,
            self.profile,
            self.host_identity,
            session_id,
            request,
            persistence,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            debug_trace.logf(
                "terminal_host",
                "durable session start rejected err={s}",
                .{@errorName(err)},
            );
            return self.failure(
                .start,
                switch (err) {
                    error.CapacityExceeded => .capacity_exceeded,
                    error.MissingLoginShell => .shell_unavailable,
                    error.RelativeShellPath,
                    error.UnsupportedShell,
                    => .invalid_request,
                    else => .authority_denied,
                },
                null,
            );
        };
        session_id_owned = false;
        session.initMonitorOwner() catch |err| {
            debug_trace.logf(
                "terminal_host",
                "session monitor owner init failed id={s} err={s}",
                .{ session.id, @errorName(err) },
            );
            session.durable.rollback_unreleased_start() catch {};
            session.deinitUnlaunched();
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(
                .start,
                if (err == error.PathOutsideWorkspace)
                    .path_outside_workspace
                else
                    .invalid_request,
                null,
            );
        };
        self.profile.register_resident(&session.durable) catch {
            session.deinitUnlaunched();
            return error.OutOfMemory;
        };

        const slot = self.reserve(session) orelse {
            session.deinitUnlaunched();
            return self.failure(.start, .capacity_exceeded, null);
        };
        defer self.releaseReference(slot.index, session);
        if (slot.evicted) |evicted| {
            evicted.deinit();
            self.alloc.destroy(evicted);
        }
        session_owned = false;

        session.markLive();
        session.launch(
            request,
            self.durable_root,
            self.transport_root,
        ) catch |err| {
            debug_trace.logf(
                "terminal_host",
                "session launch failed id={s} err={s}",
                .{ session.id, @errorName(err) },
            );
            self.removeOwned(slot.index, session);
            if (!session.child_released) {
                session.durable.rollback_unreleased_start() catch |rollback_err| {
                    debug_trace.logf(
                        "terminal_monitor",
                        "unreleased start rollback failed id={s} err={s}",
                        .{ session.id, @errorName(rollback_err) },
                    );
                };
            }
            session.deinit();
            self.alloc.destroy(session);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.failure(.start, launchFailureCode(err), null);
        };

        const condition = request.return_when orelse .started;
        const ceiling = request.wait_ceiling_ms orelse 5_000;
        const outcome = session.waitFor(condition, ceiling, cancelled) catch {
            const code = session.startFailureCode();
            session.finalizeBackend();
            return self.failure(.start, code, session.id);
        };
        if (returnOutcomeIsTerminal(outcome)) session.finalizeBackend();
        return session.startResult(outcome, .{
            .actor = persistence.grant.actor,
            .controls = persistence.grant.controls,
        });
    }

    fn wait(
        self: *SupportedRegistry,
        request: contracts.WaitRequest,
        cancelled: *const std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        const reference = self.find(request.session_id) orelse
            return self.failure(.wait, .session_not_found, request.session_id);
        defer self.releaseReference(reference.index, reference.session);
        const authorization = reference.session.durable.begin_wait(
            request.authority.?,
            io_mod.milliTimestamp(),
        ) catch |err| return self.actionError(.wait, request.session_id, err);
        const outcome = reference.session.waitFor(
            request.return_when,
            request.safety_ceiling_ms,
            cancelled,
        ) catch {
            reference.session.durable.finish_wait(
                authorization.actor,
                false,
                io_mod.milliTimestamp(),
            ) catch {};
            reference.session.finalizeBackend();
            return self.failure(
                .wait,
                .session_lost,
                request.session_id,
            );
        };
        if (returnOutcomeIsTerminal(outcome)) {
            reference.session.finalizeBackend();
        }
        reference.session.durable.finish_wait(
            authorization.actor,
            outcome == .cancelled,
            io_mod.milliTimestamp(),
        ) catch |err| return self.actionError(.wait, request.session_id, err);
        return reference.session.waitResult(outcome, authorization);
    }

    fn monitor(
        self: *SupportedRegistry,
        request: contracts.MonitorRequest,
        cancelled: *const std.atomic.Value(bool),
    ) Allocator.Error!contracts.OwnedResult {
        const reference = self.find(request.session_id) orelse
            return self.failure(.monitor, .session_not_found, request.session_id);
        defer self.releaseReference(reference.index, reference.session);
        switch (request.operation) {
            .add => |definition| _ = reference.session.durable.authorize_monitor_definition(
                request.authority.?,
                definition,
            ) catch |err| return self.actionError(.monitor, request.session_id, err),
            .update => |value| _ = reference.session.durable.authorize_monitor_definition(
                request.authority.?,
                value.definition,
            ) catch |err| return self.actionError(.monitor, request.session_id, err),
            .pause, .@"resume", .remove => _ = reference.session.durable.authorize(
                request.authority.?,
                .monitor,
            ) catch |err| return self.actionError(.monitor, request.session_id, err),
        }
        const owner = reference.session.monitor_owner orelse
            return self.failure(.monitor, .monitor_unavailable, request.session_id);
        const monitor_sequence = owner.applyOperation(
            request.operation,
            io_mod.milliTimestamp(),
            cancelled,
        ) catch |err| return self.actionError(.monitor, request.session_id, err);
        var monitor_id_buffer: [64]u8 = undefined;
        const monitor_id = if (monitor_sequence) |sequence|
            monitor_core.stable_id(&monitor_id_buffer, sequence) catch
                return self.failure(.monitor, .invalid_request, request.session_id)
        else
            null;
        const facts = reference.session.durable.facts();
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .monitor = .{
                .session = facts,
                .monitor_id = monitor_id,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn withSession(
        self: *SupportedRegistry,
        comptime action: contracts.Action,
        session_id: []const u8,
        comptime operation: anytype,
        args: anytype,
    ) Allocator.Error!contracts.OwnedResult {
        const reference = self.find(session_id) orelse
            return self.failure(action, .session_not_found, session_id);
        defer self.releaseReference(reference.index, reference.session);
        return @call(.auto, operation, .{reference.session} ++ args) catch |err| {
            return self.actionError(action, session_id, err);
        };
    }

    fn actionError(
        self: *SupportedRegistry,
        action: contracts.Action,
        session_id: []const u8,
        err: anyerror,
    ) Allocator.Error!contracts.OwnedResult {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf(
            "terminal_host",
            "session action failed action={s} id={s} err={s}",
            .{ @tagName(action), session_id, @errorName(err) },
        );
        return self.failure(
            action,
            switch (err) {
                error.InvalidCursor,
                error.MissingJournalSegment,
                error.CorruptJournalSegment,
                => .cursor_gap,
                error.CapacityExceeded, error.MonitorStateTooLarge => .capacity_exceeded,
                error.ScreenMissing,
                error.ScreenCorrupt,
                error.ScreenUnsupported,
                error.ScreenRetentionEvicted,
                error.ScreenRawGap,
                error.ScreenResizeUncheckpointed,
                => .screen_unavailable,
                error.InvalidLifecycle, error.ProcessIdentityUnavailable => .invalid_lifecycle,
                error.AuthorityRevoked,
                error.ControlDenied,
                error.ActorRoleMismatch,
                error.PrincipalMismatch,
                error.StaleAuthorityGeneration,
                error.InvalidHolderProof,
                error.InvalidAuthorityClaim,
                error.OwnerCatalogAuthorityNotFound,
                error.OwnerCatalogProofNotFound,
                error.InvalidAuthorityRecord,
                error.ProbeAuthorityDenied,
                error.ProbeCwdChanged,
                => .authority_denied,
                error.TerminalAuthorityRetired => .authority_retired,
                error.LeaseConflict => .lease_conflict,
                error.Cancelled => .cancelled,
                else => .invalid_request,
            },
            session_id,
        );
    }

    fn list(
        self: *SupportedRegistry,
        filters: contracts.ListFilters,
    ) Allocator.Error!contracts.OwnedResult {
        const owner_authority = filters.owner_authority.?;
        var catalog = self.profile.ownerCatalog(owner_authority) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.actionError(
                .list,
                owner_authority.principal.durable_session_id,
                err,
            );
        };
        defer catalog.deinit();
        var facts: std.ArrayList(contracts.SessionFacts) = .empty;
        defer facts.deinit(self.alloc);
        for (catalog.entries.items) |entry| {
            if (filters.task_id) |task_id| {
                if (!std.mem.eql(
                    u8,
                    task_id,
                    owner_authority.principal.durable_session_id,
                )) continue;
            }
            if (filters.workspace_root) |root| {
                if (!std.mem.eql(u8, root, entry.workspace_root)) continue;
            }
            if (filters.lifecycle) |lifecycle| {
                if (lifecycle != entry.facts.lifecycle) continue;
            }
            if (filters.backend) |backend| {
                if (backend != entry.facts.backend) continue;
            }
            facts.append(
                self.alloc,
                projectedFacts(entry.facts, entry.authorization),
            ) catch return error.OutOfMemory;
        }
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .list = .{ .sessions = facts.items } } },
        ) catch return error.OutOfMemory;
    }

    const Reservation = struct {
        index: usize,
        evicted: ?*Session,
    };

    const SessionReference = struct {
        index: usize,
        session: *Session,
    };

    fn reserve(
        self: *SupportedRegistry,
        session: *Session,
    ) ?Reservation {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (&self.sessions, 0..) |*entry, index| {
            if (entry.* != null) continue;
            entry.* = session;
            self.references[index] = 1;
            return .{ .index = index, .evicted = null };
        }
        for (0..max_sessions) |offset| {
            const index = (self.recycle_cursor + offset) % max_sessions;
            if (self.references[index] != 0) continue;
            const candidate = self.sessions[index].?;
            if (!candidate.isRecyclable()) continue;
            self.sessions[index] = session;
            self.references[index] = 1;
            self.recycle_cursor = (index + 1) % max_sessions;
            return .{ .index = index, .evicted = candidate };
        }
        return null;
    }

    fn removeOwned(
        self: *SupportedRegistry,
        index: usize,
        session: *Session,
    ) void {
        const zio = io_mod.getIo();
        while (true) {
            self.mutex.lockUncancelable(zio);
            if (self.sessions[index] == session and
                self.references[index] == 1)
            {
                self.sessions[index] = null;
                self.references[index] = 0;
                self.mutex.unlock(zio);
                return;
            }
            self.mutex.unlock(zio);
            io_mod.sleep(wait_poll_ns);
        }
    }

    fn find(
        self: *SupportedRegistry,
        session_id: []const u8,
    ) ?SessionReference {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (self.sessions, 0..) |entry, index| {
            const session = entry orelse continue;
            if (std.mem.eql(u8, session.id, session_id)) {
                self.references[index] += 1;
                return .{ .index = index, .session = session };
            }
        }
        return null;
    }

    fn releaseReference(
        self: *SupportedRegistry,
        index: usize,
        session: *Session,
    ) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (self.sessions[index] != session) return;
        std.debug.assert(self.references[index] > 0);
        self.references[index] -= 1;
    }

    fn failure(
        self: *SupportedRegistry,
        action: contracts.Action,
        code: contracts.StructuredErrorCode,
        session_id: ?[]const u8,
    ) Allocator.Error!contracts.OwnedResult {
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .failure = .{
                .action = action,
                .code = code,
                .session_id = session_id,
            } },
        ) catch return error.OutOfMemory;
    }
};

fn finalizeRecoveredCloseBackend(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
    durable_root: []const u8,
    transport_root: []const u8,
    record: terminal_store.Record,
) !void {
    switch (record.backend) {
        .native => try finalizeRecoveredNativeClose(
            alloc,
            process_provider,
            record,
        ),
        .tmux => try tmux_session.cleanupOwnedNamespaceChecked(
            alloc,
            process_provider,
            durable_root,
            transport_root,
            record.backend_identity,
            if (record.pid) |pid|
                if (record.process_token) |process_token|
                    .{ .pid = pid, .process_token = process_token }
                else
                    null
            else
                null,
        ),
    }
}

fn finalizeRecoveredNativeClose(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
    record: terminal_store.Record,
) !void {
    const pid = record.pid orelse return;
    const token_text = record.process_token orelse return;
    const token = process_supervisor.ProcessInstanceToken.parse(token_text) catch
        return error.ProcessIdentityUnavailable;
    switch (process_provider.matchToken(alloc, pid, token)) {
        .missing, .mismatched => return,
        .unavailable => return error.ProcessIdentityUnavailable,
        .matched => {},
    }
    process_provider.signalProcess(alloc, pid, token) catch |err| switch (err) {
        error.BackgroundProcessIdentityMismatch, error.ProcessNotFound => return,
        error.BackgroundProcessIdentityIndeterminate => return error.ProcessIdentityUnavailable,
        else => return err,
    };
}

fn finalizeRecoveredMonitors(
    alloc: Allocator,
    durable: *terminal_store.DurableSession,
    now_ms: i64,
) !void {
    var set = try durable.load_monitor_set(alloc);
    defer set.deinit();
    while (set.parsed.value.monitors.len != 0) {
        var candidate = try terminal_store.MonitorSet.clone(
            alloc,
            set.parsed.value,
        );
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        const monitor = &candidate.parsed.value.monitors[0];
        const sequence = monitorSequence(monitor.monitor_id) orelse
            return error.InvalidMonitor;
        var reason: ?monitor_core.EventReason = null;
        if (monitor.definition.condition == .process_exit or
            monitor.definition.condition == .exit_code or
            monitor.definition.condition == .signal)
        {
            const condition_matches = recoveredExitMatches(
                monitor.definition.condition,
                durable.record.termination,
            );
            const decision = try monitor_core.observe(
                monitor,
                .exit,
                condition_matches,
                now_ms,
            );
            reason = decision.notify;
        }
        if (reason == null and
            monitor.definition.notify_schedule == .on_exit and
            monitor.runtime.last_event_reason != .session_exit)
        {
            const decision = try monitor_core.observe(
                monitor,
                .session_exit,
                false,
                now_ms,
            );
            reason = decision.notify;
        }
        removeMonitorFromCandidate(&candidate, 0);
        try requireMonitorCandidate(
            durable.record.session_id,
            durable.commit_monitor_transition(
                candidate.parsed.value,
                if (reason) |event_reason| .{
                    .sequence = sequence,
                    .reason = event_reason,
                } else null,
                now_ms,
            ),
        );
        set.deinit();
        set = candidate;
        candidate_owned = false;
    }
}

fn requireMonitorCandidate(
    session_id: []const u8,
    outcome: terminal_store.MonitorTransitionOutcome,
) !void {
    switch (outcome) {
        .candidate => return,
        .previous => |err| return err,
        .cancelled => return error.Cancelled,
        .indeterminate => |err| {
            debug_trace.logf(
                "terminal_monitor",
                "monitor transition indeterminate id={s} err={s}",
                .{ session_id, @errorName(err) },
            );
            return error.SessionChildCommitIndeterminate;
        },
    }
}

fn requireCloseCandidate(
    session_id: []const u8,
    outcome: terminal_store.CloseCommitOutcome,
) !void {
    switch (outcome) {
        .previous => |err| return err,
        .candidate => |deferred| if (deferred) |err| {
            debug_trace.logf(
                "terminal_store",
                "committed close reconciliation deferred id={s} err={s}",
                .{ session_id, @errorName(err) },
            );
        },
        .indeterminate => |err| {
            debug_trace.logf(
                "terminal_store",
                "close intent indeterminate id={s} err={s}",
                .{ session_id, @errorName(err) },
            );
            return err;
        },
    }
}

fn definitiveTmuxRecoveryLoss(err: anyerror) bool {
    return switch (err) {
        error.TmuxRecoveryMissing,
        error.TmuxRecoveryReplaced,
        error.TmuxCompletionUnavailable,
        error.MalformedTmuxLifecycle,
        error.MalformedTmuxShellIdentity,
        error.MalformedTmuxManifest,
        error.MalformedTmuxPane,
        error.TmuxRecoveryManifestMissing,
        error.TmuxRecoveryShellIdentityMissing,
        => true,
        else => false,
    };
}

fn recoveredExitMatches(
    condition: contracts.MonitorCondition,
    termination: ?terminal_store.PersistedTermination,
) bool {
    const term = termination orelse return false;
    return switch (condition) {
        .process_exit => true,
        .exit_code => |expected| switch (term) {
            .exited => |actual| expected == actual,
            .signal => false,
        },
        .signal => |expected| switch (term) {
            .signal => |actual| @intFromEnum(signalValue(expected)) == actual,
            .exited => false,
        },
        else => false,
    };
}

const MonitorOwner = struct {
    alloc: Allocator,
    session: *Session,
    mutex: std.Io.Mutex = .init,
    set: terminal_store.MonitorSet,
    wake: std.Io.Event = .unset,
    ready: std.Io.Event = .unset,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    monitor_counted: bool = false,
    poll_cursor: usize = 0,

    fn init(alloc: Allocator, session: *Session) !MonitorOwner {
        var set = try session.durable.load_monitor_set(alloc);
        errdefer set.deinit();
        if (set.parsed.value.monitors.len != 0 and
            monitorInstallFailure("allocation")) return error.InjectedFailure;
        if (monitorInstallFailure("validation")) return error.InjectedFailure;
        var effects_changed = false;
        for (set.parsed.value.monitors) |*monitor| {
            effects_changed = try prepareMonitorEffects(session, monitor) or
                effects_changed;
        }
        if (effects_changed) {
            try session.durable.persist_monitor_set(
                set.parsed.value,
                io_mod.milliTimestamp(),
            );
        }
        if (monitorInstallFailure("persistence")) return error.InjectedFailure;
        return .{ .alloc = alloc, .session = session, .set = set };
    }

    fn arm(self: *MonitorOwner) !void {
        if (self.set.parsed.value.monitors.len == 0) return;
        try self.ensureThread();
        self.acquireRequirement();
    }

    fn ensureThread(self: *MonitorOwner) !void {
        if (self.thread != null) return;
        if (monitorInstallFailure("timer")) return error.InjectedFailure;
        self.ready.reset();
        self.stopping.store(false, .release);
        self.thread = std.Thread.spawn(.{}, monitorMain, .{self}) catch |err| {
            return err;
        };
        self.ready.waitUncancelable(io_mod.getIo());
        if (monitorInstallFailure("installation")) {
            self.stop();
            return error.InjectedFailure;
        }
    }

    fn deinit(self: *MonitorOwner) void {
        self.stop();
        self.set.deinit();
        self.* = undefined;
    }

    fn stop(self: *MonitorOwner) void {
        self.stopping.store(true, .release);
        self.wake.set(io_mod.getIo());
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.releaseRequirement();
    }

    fn acquireRequirement(self: *MonitorOwner) void {
        if (self.monitor_counted) return;
        self.monitor_counted = true;
        self.session.tracker.updateMonitor(true);
    }

    fn releaseRequirement(self: *MonitorOwner) void {
        if (!self.monitor_counted) return;
        self.monitor_counted = false;
        self.session.tracker.updateMonitor(false);
    }

    fn syncRequirement(self: *MonitorOwner) void {
        if (self.set.parsed.value.monitors.len == 0) {
            self.releaseRequirement();
        } else {
            self.acquireRequirement();
        }
    }

    fn nextPollingSequence(self: *MonitorOwner, now_ms: i64) ?u64 {
        const monitors = self.set.parsed.value.monitors;
        if (monitors.len == 0) {
            self.poll_cursor = 0;
            return null;
        }
        self.poll_cursor %= monitors.len;
        for (0..monitors.len) |offset| {
            const index = (self.poll_cursor + offset) % monitors.len;
            if (!monitor_core.polling_due(monitors[index], now_ms)) continue;
            self.poll_cursor = (index + 1) % monitors.len;
            return monitorSequence(monitors[index].monitor_id);
        }
        return null;
    }

    fn screenEvaluationRequired(self: *MonitorOwner) bool {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        for (self.set.parsed.value.monitors) |monitor| {
            if (monitor.runtime.state != .paused and
                monitor.runtime.state != .degraded and
                monitor.definition.condition == .screen_matches)
            {
                return true;
            }
        }
        return false;
    }

    fn publishCandidate(
        self: *MonitorOwner,
        candidate: *terminal_store.MonitorSet,
        notification: ?terminal_store.MonitorNotification,
        now_ms: i64,
        control: terminal_store.MonitorReconciliationControl,
    ) !void {
        try requireMonitorCandidate(
            self.session.id,
            self.session.durable.commit_monitor_transition_controlled(
                candidate.parsed.value,
                notification,
                now_ms,
                control,
            ),
        );
        self.set.deinit();
        self.set = candidate.*;
        candidate.* = undefined;
        self.syncRequirement();
        self.wake.set(io_mod.getIo());
    }

    fn commitAutomaticCandidate(
        self: *MonitorOwner,
        candidate: *terminal_store.MonitorSet,
        index: usize,
        decision: monitor_core.Decision,
        now_ms: i64,
        control: terminal_store.MonitorReconciliationControl,
    ) !bool {
        const monitor = &candidate.parsed.value.monitors[index];
        const sequence = monitorSequence(monitor.monitor_id) orelse
            return error.InvalidMonitor;
        if (decision.remove) removeMonitorFromCandidate(candidate, index);
        try self.publishCandidate(
            candidate,
            if (decision.notify) |reason| .{
                .sequence = sequence,
                .reason = reason,
            } else null,
            now_ms,
            control,
        );
        return decision.remove;
    }

    fn degradeForRawGap(self: *MonitorOwner, now_ms: i64) !void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        var candidate = try self.session.durable.load_monitor_set(self.alloc);
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();
        var changed = false;
        for (candidate.parsed.value.monitors) |*persisted| {
            changed = try monitor_core.degrade_for_raw_gap(persisted) or changed;
        }
        if (!changed) return;
        try self.publishCandidate(&candidate, null, now_ms, .{
            .cancelled = &self.stopping,
        });
        candidate_owned = false;
    }

    fn onOutput(
        self: *MonitorOwner,
        bytes: []const u8,
        screen_text: ?[]const u8,
        now_ms: i64,
    ) void {
        if (self.stopping.load(.acquire)) return;
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        var index: usize = 0;
        while (index < self.set.parsed.value.monitors.len) {
            const current = self.set.parsed.value.monitors[index];
            if (current.runtime.state == .paused or
                current.runtime.state == .degraded)
            {
                index += 1;
                continue;
            }
            if (!monitorOutputRelevant(
                current.definition.condition,
                screen_text != null,
            )) {
                index += 1;
                continue;
            }
            var candidate = terminal_store.MonitorSet.clone(
                self.alloc,
                self.set.parsed.value,
            ) catch |err| {
                debug_trace.logf(
                    "terminal_monitor",
                    "output candidate deferred id={s} err={s}",
                    .{ self.session.id, @errorName(err) },
                );
                return;
            };
            var candidate_owned = true;
            defer if (candidate_owned) candidate.deinit();
            const monitor = &candidate.parsed.value.monitors[index];
            if (monitor.definition.condition == .output_quiet_ms) {
                monitor_core.quiet_output(monitor, now_ms) catch |err| {
                    debug_trace.logf(
                        "terminal_monitor",
                        "quiet reset failed id={s} err={s}",
                        .{ self.session.id, @errorName(err) },
                    );
                    index += 1;
                    continue;
                };
                self.publishCandidate(&candidate, null, now_ms, .{
                    .cancelled = &self.stopping,
                }) catch |err| {
                    debug_trace.logf(
                        "terminal_monitor",
                        "quiet reset persistence deferred id={s} err={s}",
                        .{ self.session.id, @errorName(err) },
                    );
                    return;
                };
                candidate_owned = false;
                index += 1;
                continue;
            }
            const matched = switch (monitor.definition.condition) {
                .output_contains => |pattern| monitor_core.pattern_feed(
                    pattern,
                    false,
                    &monitor.runtime.matcher_states,
                    bytes,
                ) catch false,
                .output_matches => |pattern| monitor_core.pattern_feed(
                    pattern,
                    true,
                    &monitor.runtime.matcher_states,
                    bytes,
                ) catch false,
                .screen_matches => |pattern| if (screen_text) |text|
                    monitor_core.pattern_matches(pattern, true, text) catch false
                else
                    false,
                .output_quiet_ms => unreachable,
                else => {
                    index += 1;
                    continue;
                },
            };
            const decision = monitor_core.observe(
                monitor,
                if (monitor.definition.condition == .screen_matches) .screen else .output,
                matched,
                now_ms,
            ) catch {
                index += 1;
                continue;
            };
            const removed = self.commitAutomaticCandidate(
                &candidate,
                index,
                decision,
                now_ms,
                .{ .cancelled = &self.stopping },
            ) catch |err| {
                debug_trace.logf(
                    "terminal_monitor",
                    "output transition deferred id={s} err={s}",
                    .{ self.session.id, @errorName(err) },
                );
                return;
            };
            candidate_owned = false;
            if (!removed) {
                index += 1;
            }
        }
    }

    fn onScreen(self: *MonitorOwner, screen_text: []const u8, now_ms: i64) void {
        if (self.stopping.load(.acquire)) return;
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        var index: usize = 0;
        while (index < self.set.parsed.value.monitors.len) {
            const current = self.set.parsed.value.monitors[index];
            if (current.runtime.state == .paused or
                current.runtime.state == .degraded or
                current.definition.condition != .screen_matches)
            {
                index += 1;
                continue;
            }
            var candidate = terminal_store.MonitorSet.clone(
                self.alloc,
                self.set.parsed.value,
            ) catch |err| {
                debug_trace.logf(
                    "terminal_monitor",
                    "screen candidate deferred id={s} err={s}",
                    .{ self.session.id, @errorName(err) },
                );
                return;
            };
            var candidate_owned = true;
            defer if (candidate_owned) candidate.deinit();
            const monitor = &candidate.parsed.value.monitors[index];
            const matched = monitor_core.pattern_matches(
                monitor.definition.condition.screen_matches,
                true,
                screen_text,
            ) catch false;
            const decision = monitor_core.observe(
                monitor,
                .screen,
                matched,
                now_ms,
            ) catch {
                index += 1;
                continue;
            };
            const removed = self.commitAutomaticCandidate(
                &candidate,
                index,
                decision,
                now_ms,
                .{ .cancelled = &self.stopping },
            ) catch |err| {
                debug_trace.logf(
                    "terminal_monitor",
                    "screen transition deferred id={s} err={s}",
                    .{ self.session.id, @errorName(err) },
                );
                return;
            };
            candidate_owned = false;
            if (!removed) {
                index += 1;
            }
        }
    }

    fn onSessionEnd(
        self: *MonitorOwner,
        term: ?std.process.Child.Term,
        now_ms: i64,
    ) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        while (self.set.parsed.value.monitors.len != 0) {
            var candidate = terminal_store.MonitorSet.clone(
                self.alloc,
                self.set.parsed.value,
            ) catch |err| {
                debug_trace.logf(
                    "terminal_monitor",
                    "exit candidate deferred id={s} err={s}",
                    .{ self.session.id, @errorName(err) },
                );
                break;
            };
            var candidate_owned = true;
            defer if (candidate_owned) candidate.deinit();
            const monitor = &candidate.parsed.value.monitors[0];
            var decision = monitor_core.Decision{};
            if (term) |trusted_term| {
                if (monitor.definition.condition == .process_exit or
                    monitor.definition.condition == .exit_code or
                    monitor.definition.condition == .signal)
                {
                    const matches = exitConditionMatches(
                        monitor.definition.condition,
                        trusted_term,
                    );
                    decision = monitor_core.observe(
                        monitor,
                        .exit,
                        matches,
                        now_ms,
                    ) catch monitor_core.Decision{};
                }
            }
            if (decision.notify == null and
                monitor.definition.notify_schedule == .on_exit and
                monitor.runtime.last_event_reason != .session_exit)
            {
                decision = monitor_core.observe(
                    monitor,
                    .session_exit,
                    false,
                    now_ms,
                ) catch monitor_core.Decision{};
            }
            decision.remove = true;
            _ = self.commitAutomaticCandidate(
                &candidate,
                0,
                decision,
                now_ms,
                .{},
            ) catch |err| {
                debug_trace.logf(
                    "terminal_monitor",
                    "exit transition deferred id={s} err={s}",
                    .{ self.session.id, @errorName(err) },
                );
                break;
            };
            candidate_owned = false;
        }
    }

    fn applyOperation(
        self: *MonitorOwner,
        operation_value: contracts.MonitorOperation,
        now_ms: i64,
        cancelled: *const std.atomic.Value(bool),
    ) !?u64 {
        const zio = io_mod.getIo();
        self.session.write_mutex.lockUncancelable(zio);
        defer self.session.write_mutex.unlock(zio);
        self.mutex.lockUncancelable(zio);
        var started_thread = false;
        const result = self.applyOperationLocked(
            operation_value,
            now_ms,
            &started_thread,
            cancelled,
        ) catch |err| {
            self.mutex.unlock(zio);
            if (started_thread) self.stop();
            return err;
        };
        self.mutex.unlock(zio);
        return result;
    }

    fn applyOperationLocked(
        self: *MonitorOwner,
        operation_value: contracts.MonitorOperation,
        now_ms: i64,
        started_thread: *bool,
        cancelled: *const std.atomic.Value(bool),
    ) !?u64 {
        const operation_name = monitorOperationName(operation_value);
        if (monitorOperationFailure(operation_name, "allocation")) {
            return error.InjectedFailure;
        }
        var candidate = try self.operationCandidate(operation_value, now_ms);
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();

        const transition = try operationTransition(
            &candidate.parsed.value,
            operation_value,
            now_ms,
        );
        switch (operation_value) {
            .add, .update => try self.session.durable.ensure_monitor_admission(
                candidate.parsed.value,
            ),
            .pause, .@"resume", .remove => {},
        }
        if (monitorOperationFailure(operation_name, "effects")) {
            return error.InjectedFailure;
        }
        if (transition.prepare_sequence) |sequence| {
            const persisted = findMonitor(
                candidate.parsed.value.monitors,
                sequence,
            ) orelse return error.MonitorNotFound;
            _ = try prepareMonitorEffects(self.session, persisted);
        }

        started_thread.* = self.thread == null and
            candidate.parsed.value.monitors.len != 0;
        if (monitorOperationFailure(operation_name, "arming")) {
            return error.InjectedFailure;
        }
        if (started_thread.*) {
            try self.ensureThread();
        }
        if (monitorOperationFailure(operation_name, "persistence")) {
            return error.InjectedFailure;
        }

        if (transition.event_reason) |reason| {
            try self.publishCandidate(&candidate, .{
                .sequence = transition.sequence,
                .reason = reason,
            }, now_ms, .{ .cancelled = cancelled });
        } else {
            try self.publishCandidate(
                &candidate,
                null,
                now_ms,
                .{ .cancelled = cancelled },
            );
        }
        candidate_owned = false;
        return transition.result_sequence;
    }

    fn operationCandidate(
        self: *MonitorOwner,
        operation_value: contracts.MonitorOperation,
        now_ms: i64,
    ) !terminal_store.MonitorSet {
        const current = self.set.parsed.value;
        return switch (operation_value) {
            .add => |definition| blk: {
                if (current.monitors.len >= contracts.max_monitor_definitions) {
                    return error.CapacityExceeded;
                }
                const sequence = current.next_monitor_id;
                var id_buffer: [64]u8 = undefined;
                const monitor_id = try monitor_core.stable_id(&id_buffer, sequence);
                const replacement = try self.alloc.alloc(
                    monitor_core.PersistedMonitor,
                    current.monitors.len + 1,
                );
                defer self.alloc.free(replacement);
                @memcpy(replacement[0..current.monitors.len], current.monitors);
                replacement[replacement.len - 1] = .{
                    .monitor_id = monitor_id,
                    .definition = definition,
                    .runtime = try monitor_core.initial_runtime(definition, now_ms),
                };
                break :blk terminal_store.MonitorSet.clone(self.alloc, .{
                    .next_monitor_id = std.math.add(u64, sequence, 1) catch
                        return error.MonitorIdExhausted,
                    .monitors = replacement,
                });
            },
            .update => |value| blk: {
                const sequence = monitorSequence(value.monitor_id) orelse
                    return error.MonitorNotFound;
                const replacement = try self.alloc.dupe(
                    monitor_core.PersistedMonitor,
                    current.monitors,
                );
                defer self.alloc.free(replacement);
                const persisted = findMonitor(replacement, sequence) orelse
                    return error.MonitorNotFound;
                const generation = std.math.add(
                    u64,
                    persisted.runtime.generation,
                    1,
                ) catch return error.CounterOverflow;
                persisted.definition = value.definition;
                persisted.runtime = try monitor_core.initial_runtime(value.definition, now_ms);
                persisted.runtime.generation = generation;
                break :blk terminal_store.MonitorSet.clone(self.alloc, .{
                    .next_monitor_id = current.next_monitor_id,
                    .monitors = replacement,
                });
            },
            .pause, .@"resume", .remove => terminal_store.MonitorSet.clone(
                self.alloc,
                current,
            ),
        };
    }
};

fn removeMonitorFromCandidate(
    candidate: *terminal_store.MonitorSet,
    index: usize,
) void {
    const monitors = candidate.parsed.value.monitors;
    std.debug.assert(index < monitors.len);
    std.mem.copyForwards(
        monitor_core.PersistedMonitor,
        monitors[index .. monitors.len - 1],
        monitors[index + 1 ..],
    );
    candidate.parsed.value.monitors = monitors[0 .. monitors.len - 1];
}

const OperationTransition = struct {
    sequence: u64,
    result_sequence: ?u64,
    prepare_sequence: ?u64 = null,
    event_reason: ?monitor_core.EventReason = null,
};

fn operationTransition(
    candidate: *monitor_core.PersistedSet,
    operation_value: contracts.MonitorOperation,
    now_ms: i64,
) !OperationTransition {
    return switch (operation_value) {
        .add => .{
            .sequence = candidate.next_monitor_id - 1,
            .result_sequence = candidate.next_monitor_id - 1,
            .prepare_sequence = candidate.next_monitor_id - 1,
        },
        .update => |value| blk: {
            const sequence = monitorSequence(value.monitor_id) orelse
                return error.MonitorNotFound;
            const persisted = findMonitor(candidate.monitors, sequence) orelse
                return error.MonitorNotFound;
            break :blk .{
                .sequence = sequence,
                .result_sequence = sequence,
                .prepare_sequence = sequence,
                .event_reason = if (persisted.definition.notify_schedule == .on_state_change)
                    .updated
                else
                    null,
            };
        },
        .pause => |monitor_id| blk: {
            const persisted = findMonitorById(candidate.monitors, monitor_id) orelse
                return error.MonitorNotFound;
            const sequence = monitorSequence(persisted.monitor_id) orelse
                return error.InvalidMonitor;
            if (!monitor_core.pause(persisted)) return error.InvalidMonitorState;
            try monitor_core.bump_generation(persisted);
            break :blk .{
                .sequence = sequence,
                .result_sequence = sequence,
                .event_reason = if (persisted.definition.notify_schedule == .on_state_change)
                    .paused
                else
                    null,
            };
        },
        .@"resume" => |monitor_id| blk: {
            const persisted = findMonitorById(candidate.monitors, monitor_id) orelse
                return error.MonitorNotFound;
            const sequence = monitorSequence(persisted.monitor_id) orelse
                return error.InvalidMonitor;
            if (!try monitor_core.resume_monitor(persisted, now_ms)) {
                return error.InvalidMonitorState;
            }
            try monitor_core.bump_generation(persisted);
            break :blk .{
                .sequence = sequence,
                .result_sequence = sequence,
                .event_reason = if (persisted.definition.notify_schedule == .on_state_change)
                    .resumed
                else
                    null,
            };
        },
        .remove => |monitor_id| blk: {
            const index = findMonitorIndex(candidate.monitors, monitor_id) orelse
                return error.MonitorNotFound;
            const persisted = candidate.monitors[index];
            const sequence = monitorSequence(persisted.monitor_id) orelse
                return error.InvalidMonitor;
            const notify = persisted.definition.notify_schedule == .on_state_change and
                persisted.runtime.last_event_reason != .removed;
            const replacement = candidate.monitors;
            std.mem.copyForwards(
                monitor_core.PersistedMonitor,
                replacement[index .. replacement.len - 1],
                replacement[index + 1 ..],
            );
            candidate.monitors = replacement[0 .. replacement.len - 1];
            break :blk .{
                .sequence = sequence,
                .result_sequence = null,
                .event_reason = if (notify) .removed else null,
            };
        },
    };
}

fn monitorOperationName(operation_value: contracts.MonitorOperation) []const u8 {
    return switch (operation_value) {
        .add => "add",
        .update => "update",
        .pause => "pause",
        .@"resume" => "resume",
        .remove => "remove",
    };
}

fn monitorOperationFailure(operation_name: []const u8, boundary: []const u8) bool {
    const requested = io_mod.getenv("FX_TERMINAL_TEST_FAIL_MONITOR_OPERATION") orelse
        return false;
    var buffer: [64]u8 = undefined;
    const expected = std.fmt.bufPrint(
        &buffer,
        "{s}:{s}",
        .{ operation_name, boundary },
    ) catch return false;
    return std.mem.eql(u8, requested, expected);
}

fn monitorScreenProjectionAllocationFailure() bool {
    const requested = io_mod.getenv(
        "FX_TERMINAL_TEST_FAIL_MONITOR_SCREEN_PROJECTION_ALLOCATION",
    ) orelse return false;
    return std.mem.eql(u8, requested, "1");
}

fn monitorOutputScreenProjectionAllocationFailure() bool {
    const requested = io_mod.getenv(
        "FX_TERMINAL_TEST_FAIL_MONITOR_OUTPUT_SCREEN_PROJECTION_ALLOCATION",
    ) orelse return false;
    return std.mem.eql(u8, requested, "1");
}

const PollingCheck = struct {
    snapshot: terminal_store.MonitorSet,
    sequence: u64,
    generation: u64,
    check_count: u64,

    fn deinit(self: *PollingCheck) void {
        self.snapshot.deinit();
        self.* = undefined;
    }

    fn monitor(self: *PollingCheck) *monitor_core.PersistedMonitor {
        return &self.snapshot.parsed.value.monitors[0];
    }
};

fn monitorOutputRelevant(
    condition: contracts.MonitorCondition,
    screen_available: bool,
) bool {
    return switch (condition) {
        .output_contains, .output_matches, .output_quiet_ms => true,
        .screen_matches => screen_available,
        else => false,
    };
}

fn monitorMain(owner: *MonitorOwner) void {
    const zio = io_mod.getIo();
    owner.ready.set(zio);
    while (!owner.stopping.load(.acquire)) {
        owner.mutex.lockUncancelable(zio);
        const now_ms = io_mod.milliTimestamp();
        var index: usize = 0;
        while (index < owner.set.parsed.value.monitors.len) {
            const current = owner.set.parsed.value.monitors[index];
            if (if (monitor_core.next_deadline(current)) |due| due <= now_ms else false) {
                var candidate = terminal_store.MonitorSet.clone(
                    owner.alloc,
                    owner.set.parsed.value,
                ) catch |err| {
                    debug_trace.logf(
                        "terminal_monitor",
                        "timer candidate deferred id={s} err={s}",
                        .{ owner.session.id, @errorName(err) },
                    );
                    index += 1;
                    continue;
                };
                var candidate_owned = true;
                defer if (candidate_owned) candidate.deinit();
                const interval = monitor_core.timer_decision(
                    &candidate.parsed.value.monitors[index],
                    now_ms,
                ) catch |err| blk: {
                    debug_trace.logf(
                        "terminal_monitor",
                        "timer decision failed id={s} err={s}",
                        .{ owner.session.id, @errorName(err) },
                    );
                    break :blk monitor_core.Decision{};
                };
                if (interval.notify != null or interval.remove) {
                    const removed = owner.commitAutomaticCandidate(
                        &candidate,
                        index,
                        interval,
                        now_ms,
                        .{ .cancelled = &owner.stopping },
                    ) catch |err| {
                        debug_trace.logf(
                            "terminal_monitor",
                            "timer transition deferred id={s} err={s}",
                            .{ owner.session.id, @errorName(err) },
                        );
                        index += 1;
                        continue;
                    };
                    candidate_owned = false;
                    if (removed) continue;
                }
            }

            if (monitor_core.quiet_due(
                owner.set.parsed.value.monitors[index],
                now_ms,
            )) {
                var candidate = terminal_store.MonitorSet.clone(
                    owner.alloc,
                    owner.set.parsed.value,
                ) catch |err| {
                    debug_trace.logf(
                        "terminal_monitor",
                        "quiet candidate deferred id={s} err={s}",
                        .{ owner.session.id, @errorName(err) },
                    );
                    index += 1;
                    continue;
                };
                var candidate_owned = true;
                defer if (candidate_owned) candidate.deinit();
                const decision = monitor_core.observe(
                    &candidate.parsed.value.monitors[index],
                    .quiet,
                    true,
                    now_ms,
                ) catch {
                    index += 1;
                    continue;
                };
                const removed = owner.commitAutomaticCandidate(
                    &candidate,
                    index,
                    decision,
                    now_ms,
                    .{ .cancelled = &owner.stopping },
                ) catch |err| {
                    debug_trace.logf(
                        "terminal_monitor",
                        "quiet transition deferred id={s} err={s}",
                        .{ owner.session.id, @errorName(err) },
                    );
                    index += 1;
                    continue;
                };
                candidate_owned = false;
                if (removed) continue;
            }
            index += 1;
        }
        var polling_check = takePollingCheck(owner, now_ms) catch |err| blk: {
            debug_trace.logf(
                "terminal_monitor",
                "poll snapshot deferred id={s} err={s}",
                .{ owner.session.id, @errorName(err) },
            );
            break :blk null;
        };
        var next_due: ?i64 = null;
        for (owner.set.parsed.value.monitors) |monitor| {
            if (monitor_core.next_deadline(monitor)) |due| {
                next_due = if (next_due) |current| @min(current, due) else due;
            }
        }
        owner.wake.reset();
        owner.mutex.unlock(zio);
        if (owner.stopping.load(.acquire)) {
            if (polling_check) |*check| check.deinit();
            break;
        }
        if (polling_check) |*check| {
            defer check.deinit();
            const matched = pollCondition(owner.session, check.monitor()) catch |err| blk: {
                debug_trace.logf(
                    "terminal_monitor",
                    "poll failed session={s} monitor={s} err={s}",
                    .{ owner.session.id, check.monitor().monitor_id, @errorName(err) },
                );
                break :blk false;
            };
            const completed_at_ms = io_mod.milliTimestamp();
            owner.mutex.lockUncancelable(zio);
            applyPollingCheck(owner, check, matched, completed_at_ms) catch |err| {
                debug_trace.logf(
                    "terminal_monitor",
                    "poll result deferred id={s} err={s}",
                    .{ owner.session.id, @errorName(err) },
                );
            };
            owner.mutex.unlock(zio);
            continue;
        }
        if (next_due) |due| {
            const current = io_mod.milliTimestamp();
            const delay_ms: i64 = if (due <= current) 1 else due - current;
            owner.wake.waitTimeout(zio, .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(delay_ms),
            } }) catch {};
        } else {
            owner.wake.waitUncancelable(zio);
        }
    }
}

fn takePollingCheck(
    owner: *MonitorOwner,
    now_ms: i64,
) !?PollingCheck {
    const sequence = owner.nextPollingSequence(now_ms) orelse return null;
    const persisted = findMonitor(
        owner.set.parsed.value.monitors,
        sequence,
    ) orelse return null;
    var one = [_]monitor_core.PersistedMonitor{persisted.*};
    const snapshot = try terminal_store.MonitorSet.clone(owner.alloc, .{
        .next_monitor_id = owner.set.parsed.value.next_monitor_id,
        .monitors = &one,
    });
    return .{
        .snapshot = snapshot,
        .sequence = sequence,
        .generation = persisted.runtime.generation,
        .check_count = persisted.runtime.check_count,
    };
}

fn applyPollingCheck(
    owner: *MonitorOwner,
    check: *PollingCheck,
    matched: bool,
    now_ms: i64,
) !void {
    const current = findMonitor(
        owner.set.parsed.value.monitors,
        check.sequence,
    ) orelse return;
    if (current.runtime.generation != check.generation or
        current.runtime.check_count != check.check_count or
        current.runtime.state == .paused)
    {
        return;
    }
    const current_index = findMonitorSequenceIndex(
        owner.set.parsed.value.monitors,
        check.sequence,
    ) orelse return;
    var candidate = try terminal_store.MonitorSet.clone(
        owner.alloc,
        owner.set.parsed.value,
    );
    var candidate_owned = true;
    defer if (candidate_owned) candidate.deinit();
    const persisted = &candidate.parsed.value.monitors[current_index];
    if (persisted.definition.condition == .path_changed) {
        persisted.runtime.path_baseline = check.monitor().runtime.path_baseline;
    }
    const decision = try monitor_core.observe(
        persisted,
        .check,
        matched,
        now_ms,
    );
    _ = try owner.commitAutomaticCandidate(
        &candidate,
        current_index,
        decision,
        now_ms,
        .{ .cancelled = &owner.stopping },
    );
    candidate_owned = false;
}

fn validateMonitorEffects(
    session: *Session,
    definition: contracts.MonitorDefinition,
) !void {
    try monitor_core.validate_definition(definition);
    switch (definition.condition) {
        .path_exists, .path_changed => |path| {
            const resolved = try resolveMonitorPath(
                session.alloc,
                session,
                path,
                .create,
            );
            session.alloc.free(resolved);
        },
        .path_size => |condition| {
            const resolved = try resolveMonitorPath(
                session.alloc,
                session,
                condition.path,
                .create,
            );
            session.alloc.free(resolved);
        },
        .custom_probe => |probe| {
            const resolved = try resolveMonitorPath(
                session.alloc,
                session,
                probe.cwd,
                .existing,
            );
            session.alloc.free(resolved);
        },
        .http_ready => |url| {
            const uri = std.Uri.parse(url) catch return error.InvalidMonitorCondition;
            if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
                uri.host == null or uri.user != null or uri.password != null)
            {
                return error.InvalidMonitorCondition;
            }
        },
        else => {},
    }
}

fn prepareMonitorEffects(
    session: *Session,
    persisted: *monitor_core.PersistedMonitor,
) !bool {
    try validateMonitorEffects(session, persisted.definition);
    switch (persisted.definition.condition) {
        .path_changed => |path| {
            const baseline = try pathBaseline(session.alloc, session, path);
            const changed = if (persisted.runtime.path_baseline) |current|
                !std.meta.eql(current, baseline)
            else
                true;
            persisted.runtime.path_baseline = baseline;
            return changed;
        },
        .custom_probe => |probe| {
            const canonical = try resolveMonitorPath(
                session.alloc,
                session,
                probe.cwd,
                .existing,
            );
            defer session.alloc.free(canonical);
            const fingerprint = contracts.checkpoint_checksum(canonical);
            const changed = if (persisted.runtime.probe_cwd_fingerprint) |current|
                !std.mem.eql(u8, &current, &fingerprint)
            else
                true;
            persisted.runtime.probe_cwd_fingerprint = fingerprint;
            return changed;
        },
        else => return false,
    }
}

fn resolveMonitorPath(
    alloc: Allocator,
    session: *Session,
    path: []const u8,
    mode: types.ResolveMode,
) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lexical = try std.fs.path.resolve(
        arena,
        if (std.fs.path.isAbsolute(path)) &.{path} else &.{ session.cwd, path },
    );
    const canonical_root = try io_mod.realpathAlloc(arena, session.workspace_root);
    const resolved = try workspace_pathing.resolveWorkspacePath(
        arena,
        canonical_root,
        lexical,
        mode,
    );
    return alloc.dupe(u8, resolved);
}

fn pollCondition(
    session: *Session,
    monitor: *monitor_core.PersistedMonitor,
) !bool {
    return switch (monitor.definition.condition) {
        .tcp_ready => |condition| tcpReady(session.alloc, condition.host, condition.port),
        .http_ready => |url| httpReady(session.alloc, url),
        .path_exists => |path| blk: {
            const baseline = try pathBaseline(session.alloc, session, path);
            break :blk baseline.exists;
        },
        .path_changed => |path| blk: {
            const current = try pathBaseline(session.alloc, session, path);
            const previous = monitor.runtime.path_baseline orelse {
                monitor.runtime.path_baseline = current;
                break :blk false;
            };
            monitor.runtime.path_baseline = current;
            break :blk !std.meta.eql(previous, current);
        },
        .path_size => |condition| blk: {
            const baseline = try pathBaseline(session.alloc, session, condition.path);
            break :blk baseline.exists and baseline.size >= condition.minimum_bytes;
        },
        .custom_probe => |probe| try runCustomProbe(
            session,
            probe,
            monitor.runtime.probe_cwd_fingerprint orelse return false,
        ),
        else => false,
    };
}

fn pathBaseline(
    alloc: Allocator,
    session: *Session,
    path: []const u8,
) !monitor_core.PathBaseline {
    const resolved = try resolveMonitorPath(alloc, session, path, .create);
    defer alloc.free(resolved);
    const stat = std.Io.Dir.cwd().statFile(
        io_mod.getIo(),
        resolved,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return .{ .exists = false },
        else => return err,
    };
    return .{
        .exists = true,
        .size = stat.size,
        .modified_ns = stat.mtime.nanoseconds,
    };
}

fn runCustomProbe(
    session: *Session,
    probe: contracts.CustomProbeCondition,
    approved_cwd: contracts.CheckpointChecksum,
) !bool {
    const canonical_cwd = try resolveMonitorPath(
        session.alloc,
        session,
        probe.cwd,
        .existing,
    );
    defer session.alloc.free(canonical_cwd);
    const current_cwd = contracts.checkpoint_checksum(canonical_cwd);
    if (!std.mem.eql(u8, &approved_cwd, &current_cwd)) return false;
    const command_ctx = command_admission.CommandContext{
        .command = probe.command,
        .resolved_cwd = canonical_cwd,
        .background = false,
        .target_os = builtin.os.tag,
    };
    const authority = command_admission.CommandExecutionAuthority{ .shell_allowed = .{
        .fingerprint = .init(command_ctx),
        .source = .session_grant,
    } };
    var arena_state = std.heap.ArenaAllocator.init(session.alloc);
    defer arena_state.deinit();
    var output_budget = ProbeOutputBudget{};
    const executed = execution_router.executePlannedCommand(.{
        .max_command_output_bytes = ProbeOutputBudget.capture_bytes,
        .timeout_ms = monitor_core.probe_timeout_ms,
        .timeout_started_ms = io_mod.milliTimestamp(),
        .accepted_output_chunk_ctx = @ptrCast(&output_budget),
        .on_accepted_output_chunk = ProbeOutputBudget.accept,
    }, arena_state.allocator(), command_ctx, authority) catch return false;
    const foreground = executed.result.command_result orelse return false;
    return output_budget.total <= monitor_core.probe_output_bytes and
        foreground.foreground.stdout_bytes +| foreground.foreground.stderr_bytes <=
            monitor_core.probe_output_bytes and
        !foreground.foreground.truncated and
        foreground.foreground.exit_code == 0;
}

const ProbeOutputBudget = struct {
    const capture_bytes = monitor_core.probe_output_bytes + 8 * 1024;
    total: usize = 0,

    fn accept(
        raw: *anyopaque,
        _: ?types.ToolLifecycleId,
        _: command_runner.CommandOutputStream,
        bytes: []const u8,
    ) !void {
        const self: *ProbeOutputBudget = @ptrCast(@alignCast(raw));
        self.total = std.math.add(usize, self.total, bytes.len) catch
            return error.ProbeOutputLimitExceeded;
        if (self.total > monitor_core.probe_output_bytes) {
            return error.ProbeOutputLimitExceeded;
        }
    }
};

fn exitConditionMatches(
    condition: contracts.MonitorCondition,
    term: std.process.Child.Term,
) bool {
    return switch (condition) {
        .process_exit => true,
        .exit_code => |expected| switch (term) {
            .exited => |actual| expected == actual,
            else => false,
        },
        .signal => |expected| switch (term) {
            .signal => |actual| signalValue(expected) == actual,
            else => false,
        },
        else => false,
    };
}

fn monitorSequence(monitor_id: []const u8) ?u64 {
    const prefix = "monitor-";
    if (!std.mem.startsWith(u8, monitor_id, prefix)) return null;
    return std.fmt.parseInt(u64, monitor_id[prefix.len..], 10) catch null;
}

fn monitorInstallFailure(point: []const u8) bool {
    const requested = io_mod.getenv("FX_TERMINAL_TEST_FAIL_MONITOR_INSTALL") orelse
        return false;
    return std.mem.eql(u8, requested, point);
}

fn findMonitor(
    monitors: []monitor_core.PersistedMonitor,
    sequence: u64,
) ?*monitor_core.PersistedMonitor {
    for (monitors) |*monitor| {
        if (monitorSequence(monitor.monitor_id) == sequence) return monitor;
    }
    return null;
}

fn findMonitorById(
    monitors: []monitor_core.PersistedMonitor,
    monitor_id: []const u8,
) ?*monitor_core.PersistedMonitor {
    for (monitors) |*monitor| {
        if (std.mem.eql(u8, monitor.monitor_id, monitor_id)) return monitor;
    }
    return null;
}

fn findMonitorIndex(
    monitors: []const monitor_core.PersistedMonitor,
    monitor_id: []const u8,
) ?usize {
    for (monitors, 0..) |monitor, index| {
        if (std.mem.eql(u8, monitor.monitor_id, monitor_id)) return index;
    }
    return null;
}

fn findMonitorSequenceIndex(
    monitors: []const monitor_core.PersistedMonitor,
    sequence: u64,
) ?usize {
    for (monitors, 0..) |monitor, index| {
        if (monitorSequence(monitor.monitor_id) == sequence) return index;
    }
    return null;
}

const LookupSelection = union(enum) {
    lookup: anyerror![]std.Io.net.IpAddress,
    timeout: anyerror!void,
};

const ConnectSelection = union(enum) {
    connect: anyerror!std.Io.net.Stream,
    timeout: anyerror!void,
};

fn tcpReady(alloc: Allocator, host_name: []const u8, port: u16) bool {
    const addresses = resolveMonitorHost(alloc, host_name, port) catch return false;
    defer alloc.free(addresses);
    for (addresses[0..@min(addresses.len, 4)]) |address| {
        const stream = connectMonitorAddress(address) catch continue;
        stream.close(io_mod.getIo());
        return true;
    }
    return false;
}

fn resolveMonitorHost(
    alloc: Allocator,
    host_name: []const u8,
    port: u16,
) ![]std.Io.net.IpAddress {
    if (std.Io.net.IpAddress.parse(host_name, port)) |address| {
        const result = try alloc.alloc(std.Io.net.IpAddress, 1);
        result[0] = address;
        return result;
    } else |_| {}
    const host = try std.Io.net.HostName.init(host_name);
    const zio = io_mod.getIo();
    var buffer: [2]LookupSelection = undefined;
    var select: std.Io.Select(LookupSelection) = .init(zio, &buffer);
    try select.concurrent(.lookup, collectMonitorLookup, .{ alloc, host, port });
    try select.concurrent(.timeout, waitMonitorNetworkDeadline, .{});
    const result = try select.await();
    return switch (result) {
        .lookup => |lookup| blk: {
            select.cancelDiscard();
            break :blk try lookup;
        },
        .timeout => |timeout| blk: {
            while (select.cancel()) |item| switch (item) {
                .lookup => |lookup| if (lookup) |addresses| alloc.free(addresses) else |_| {},
                .timeout => {},
            };
            try timeout;
            break :blk error.Timeout;
        },
    };
}

fn collectMonitorLookup(
    alloc: Allocator,
    host: std.Io.net.HostName,
    port: u16,
) ![]std.Io.net.IpAddress {
    const zio = io_mod.getIo();
    var lookup_buffer: [16]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buffer);
    try std.Io.net.HostName.lookup(host, zio, &queue, .{ .port = port });
    var addresses: std.ArrayList(std.Io.net.IpAddress) = .empty;
    errdefer addresses.deinit(alloc);
    while (queue.getOne(zio)) |item| switch (item) {
        .address => |address| if (addresses.items.len < 4) try addresses.append(alloc, address),
        .canonical_name => {},
    } else |err| switch (err) {
        error.Closed => {},
        error.Canceled => return error.Canceled,
    }
    if (addresses.items.len == 0) return error.NoAddressReturned;
    return addresses.toOwnedSlice(alloc);
}

fn connectMonitorAddress(address: std.Io.net.IpAddress) !std.Io.net.Stream {
    const zio = io_mod.getIo();
    var buffer: [2]ConnectSelection = undefined;
    var select: std.Io.Select(ConnectSelection) = .init(zio, &buffer);
    try select.concurrent(.connect, connectMonitorAddressTask, .{address});
    try select.concurrent(.timeout, waitMonitorNetworkDeadline, .{});
    const result = try select.await();
    return switch (result) {
        .connect => |connected| blk: {
            select.cancelDiscard();
            break :blk try connected;
        },
        .timeout => |timeout| blk: {
            while (select.cancel()) |item| switch (item) {
                .connect => |connected| if (connected) |stream| stream.close(zio) else |_| {},
                .timeout => {},
            };
            try timeout;
            break :blk error.Timeout;
        },
    };
}

fn connectMonitorAddressTask(address: std.Io.net.IpAddress) !std.Io.net.Stream {
    return std.Io.net.IpAddress.connect(&address, io_mod.getIo(), .{ .mode = .stream });
}

fn waitMonitorNetworkDeadline() !void {
    const zio = io_mod.getIo();
    const now = std.Io.Clock.Timestamp.now(zio, .awake);
    const due = std.Io.Clock.Timestamp{
        .clock = .awake,
        .raw = now.raw.addDuration(.fromMilliseconds(250)),
    };
    try due.wait(zio);
    return error.Timeout;
}

fn httpReady(alloc: Allocator, url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = (uri.host orelse return false).toRaw(&host_buffer) catch return false;
    const port = uri.port orelse 80;
    const addresses = resolveMonitorHost(alloc, host, port) catch return false;
    defer alloc.free(addresses);
    var stream: ?std.Io.net.Stream = null;
    for (addresses[0..@min(addresses.len, 4)]) |address| {
        stream = connectMonitorAddress(address) catch continue;
        break;
    }
    const connected = stream orelse return false;
    defer connected.close(io_mod.getIo());
    applyMonitorSocketTimeout(connected, 500);
    var write_buffer: [contracts.max_authority_text_bytes + 512]u8 = undefined;
    var writer = connected.writer(io_mod.getIo(), &write_buffer);
    writer.interface.writeAll("GET ") catch return false;
    const path: std.Uri.Component = if (uri.path.isEmpty())
        .{ .percent_encoded = "/" }
    else
        uri.path;
    path.formatPath(&writer.interface) catch return false;
    if (uri.query) |query| {
        writer.interface.writeByte('?') catch return false;
        query.formatQuery(&writer.interface) catch return false;
    }
    writer.interface.print(
        " HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n",
        .{host},
    ) catch return false;
    writer.interface.flush() catch return false;
    var response: [1024]u8 = undefined;
    const message = connected.socket.receiveTimeout(
        io_mod.getIo(),
        &response,
        .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(500) } },
    ) catch return false;
    const bytes = message.data;
    return bytes.len >= 12 and std.mem.startsWith(u8, bytes, "HTTP/");
}

fn applyMonitorSocketTimeout(stream: std.Io.net.Stream, timeout_ms: i64) void {
    const timeout = std.posix.timeval{
        .sec = @intCast(@divTrunc(timeout_ms, 1000)),
        .usec = @intCast(@mod(timeout_ms, 1000) * 1000),
    };
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeout),
    ) catch {};
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        std.mem.asBytes(&timeout),
    ) catch {};
}

const SignalTarget = struct {
    pid: std.posix.pid_t,
    token: process_supervisor.ProcessInstanceToken,
};

const Session = struct {
    alloc: Allocator,
    tracker: WorkTracker,
    id: []u8,
    shell: []u8,
    cwd: []u8,
    command: ?[]u8,
    startup_match: ?[]u8,
    startup_match_seen: bool = false,
    dimensions: contracts.Dimensions,
    mutex: std.Io.Mutex = .init,
    write_mutex: std.Io.Mutex = .init,
    lifecycle: contracts.Lifecycle = .starting,
    last_output_ms: i64,
    child_pid: ?std.posix.pid_t = null,
    child_token: ?process_supervisor.ProcessInstanceToken = null,
    recovered_start_identity: bool = false,
    term: ?std.process.Child.Term = null,
    shell_ready_seen: bool = false,
    start_failure: ?contracts.StructuredErrorCode = null,
    master_fd: ?std.posix.fd_t = null,
    tmux_backend: ?tmux_session.Backend = null,
    tmux_capture: ?std.Io.net.Stream = null,
    tmux_lifecycle_index: usize = 0,
    launcher: ?std.process.Child = null,
    control_file: ?std.Io.File = null,
    liveness_file: ?std.Io.File = null,
    output_thread: ?std.Thread = null,
    control_thread: ?std.Thread = null,
    output_done: std.Io.Event = .unset,
    output_active: std.atomic.Value(bool) = .init(false),
    command_boundary_requested: std.atomic.Value(bool) = .init(false),
    command_boundary_done: std.Io.Event = .unset,
    command_start_cursor: ?contracts.RawCursor = null,
    backend_done: std.Io.Event = .unset,
    backend_join_mutex: std.Io.Mutex = .init,
    backend_started: bool = false,
    backend_detaching: std.atomic.Value(bool) = .init(false),
    live_counted: bool = false,
    input_quiesced: bool = false,
    close_committed: bool = false,
    engine: terminal_engine.Grid,
    screen_available: bool = true,
    durable: terminal_store.DurableSession,
    workspace_root: []u8,
    monitor_owner: ?*MonitorOwner = null,
    child_released: bool = false,

    fn init(
        alloc: Allocator,
        tracker: WorkTracker,
        profile: *terminal_store.ProfileStore,
        host_identity: []const u8,
        id: []u8,
        request: contracts.StartRequest,
        persistence: contracts.StartPersistence,
    ) !Session {
        var login_shell_buffer: [4096]u8 = undefined;
        const configured = shell_resolver.configuredLoginShellInto(&login_shell_buffer);
        const invocation = try shell_resolver.resolve(configured, request.shell);
        const shell = try alloc.dupe(u8, invocation.path);
        errdefer alloc.free(shell);
        const cwd = try alloc.dupe(u8, request.cwd);
        errdefer alloc.free(cwd);
        const workspace_root = try alloc.dupe(
            u8,
            persistence.grant.principal.workspace_root,
        );
        errdefer alloc.free(workspace_root);
        const command = if (request.command) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (command) |value| alloc.free(value);
        const startup_match = if (request.return_when) |condition|
            switch (condition) {
                .match => |pattern| try alloc.dupe(u8, pattern),
                .started, .exit, .quiet => null,
            }
        else
            null;
        errdefer if (startup_match) |value| alloc.free(value);
        const dimensions = request.dimensions orelse default_dimensions;
        var engine = try terminal_engine.Grid.init(
            alloc,
            dimensions.columns,
            dimensions.rows,
        );
        errdefer engine.deinit();
        const now_ms = io_mod.milliTimestamp();
        const durable = try terminal_store.DurableSession.create(profile, .{
            .session_id = id,
            .host_identity = host_identity,
            .shell = shell,
            .cwd = cwd,
            .command = command,
            .backend = request.backend,
            .dimensions = dimensions,
            .persistence = persistence,
            .initial_monitors = request.initial_monitors,
            .now_ms = now_ms,
        });
        return .{
            .alloc = alloc,
            .tracker = tracker,
            .id = id,
            .shell = shell,
            .cwd = cwd,
            .command = command,
            .startup_match = startup_match,
            .dimensions = dimensions,
            .last_output_ms = now_ms,
            .engine = engine,
            .durable = durable,
            .workspace_root = workspace_root,
        };
    }

    fn initRecovered(
        alloc: Allocator,
        tracker: WorkTracker,
        durable_value: terminal_store.DurableSession,
    ) !Session {
        var durable = durable_value;
        errdefer durable.deinit();
        const id = try alloc.dupe(u8, durable.record.session_id);
        errdefer alloc.free(id);
        const shell = try alloc.dupe(u8, durable.record.shell);
        errdefer alloc.free(shell);
        const cwd = try alloc.dupe(u8, durable.record.cwd);
        errdefer alloc.free(cwd);
        var execution_scope = try durable.load_recovery_execution_scope(alloc);
        errdefer execution_scope.deinit(alloc);
        const command = if (durable.record.command) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (command) |value| alloc.free(value);
        var screen_available = true;
        const engine = reconstructEngine(alloc, &durable) catch |err| switch (err) {
            error.ScreenMissing,
            error.ScreenCorrupt,
            error.ScreenUnsupported,
            error.ScreenRetentionEvicted,
            error.ScreenRawGap,
            error.ScreenResizeUncheckpointed,
            => blk: {
                screen_available = false;
                break :blk try terminal_engine.Grid.init(
                    alloc,
                    durable.record.dimensions.columns,
                    durable.record.dimensions.rows,
                );
            },
            else => return err,
        };
        const child_pid = if (durable.record.pid) |value|
            std.fmt.parseInt(std.posix.pid_t, value, 10) catch null
        else
            null;
        const child_token = if (durable.record.process_token) |value|
            process_supervisor.ProcessInstanceToken.parse(value) catch null
        else
            null;
        return .{
            .alloc = alloc,
            .tracker = tracker,
            .id = id,
            .shell = shell,
            .cwd = cwd,
            .command = command,
            .startup_match = null,
            .dimensions = durable.record.dimensions,
            .lifecycle = durable.record.lifecycle,
            .last_output_ms = durable.record.updated_at_ms,
            .child_pid = child_pid,
            .child_token = child_token,
            .term = if (durable.record.termination) |termination| switch (termination) {
                .exited => |code| .{ .exited = @intCast(code) },
                .signal => |signal| if (signalFromInt(signal)) |value|
                    .{ .signal = value }
                else
                    null,
            } else null,
            .shell_ready_seen = durable.record.lifecycle == .running,
            .engine = engine,
            .screen_available = screen_available,
            .durable = durable,
            .workspace_root = execution_scope.workspace_root,
        };
    }

    fn initMonitorOwner(self: *Session) !void {
        const owner = try self.alloc.create(MonitorOwner);
        errdefer self.alloc.destroy(owner);
        owner.* = try MonitorOwner.init(self.alloc, self);
        self.monitor_owner = owner;
    }

    fn deinitUnlaunched(self: *Session) void {
        if (self.monitor_owner) |owner| {
            owner.deinit();
            self.alloc.destroy(owner);
        }
        self.engine.deinit();
        self.durable.deinit();
        if (self.startup_match) |pattern| self.alloc.free(pattern);
        if (self.command) |command| self.alloc.free(command);
        self.alloc.free(self.cwd);
        self.alloc.free(self.workspace_root);
        self.alloc.free(self.shell);
        self.alloc.free(self.id);
        self.* = undefined;
    }

    fn launch(
        self: *Session,
        request: contracts.StartRequest,
        durable_root: []const u8,
        transport_root: []const u8,
    ) !void {
        return switch (request.backend) {
            .native => self.launchNative(request),
            .tmux => self.launchTmux(request, durable_root, transport_root),
        };
    }

    fn launchTmux(
        self: *Session,
        request: contracts.StartRequest,
        durable_root: []const u8,
        transport_root: []const u8,
    ) !void {
        var invocation = try shell_resolver.resolve(
            null,
            pinnedShell(request.shell, self.shell),
        );

        const executable = try self_exe.pathForPeerReexec(self.alloc);
        defer self.alloc.free(executable);
        var paths = try tmux_session.Paths.init(
            self.alloc,
            durable_root,
            transport_root,
            self.durable.record.backend_identity,
        );
        defer paths.deinit(self.alloc);
        var nonce_bytes: [16]u8 = undefined;
        io_mod.getIo().random(&nonce_bytes);
        const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);
        const command_path = if (request.command != null) paths.command else null;
        const bootstrap = try shell_resolver.buildBootstrap(
            self.alloc,
            executable,
            paths.marker_socket,
            &nonce,
            command_path,
        );
        defer self.alloc.free(bootstrap);
        const source_command = try shell_resolver.buildSourceCommand(
            self.alloc,
            paths.bootstrap,
        );
        defer self.alloc.free(source_command);
        if (request.command != null) invocation.setCommand(source_command);

        var backend = try tmux_session.Backend.start(
            self.alloc,
            self.durable.profile.process_provider,
            durable_root,
            transport_root,
            self.durable.record.backend_identity,
            executable,
            self.dimensions,
            .{
                .argv = invocation.argv(),
                .cwd = request.cwd,
                .control_path = paths.marker_socket,
                .control_nonce = &nonce,
                .bootstrap_path = paths.bootstrap,
                .bootstrap = bootstrap,
                .command_path = command_path,
                .command = request.command,
                .interactive_source = if (request.command == null)
                    source_command
                else
                    null,
                .tmux_socket = paths.socket,
                .tmux_target = paths.target,
                .lifecycle_path = paths.lifecycle,
                .shell_identity_path = paths.shell_identity,
                .manifest_ready_path = paths.manifest_ready,
                .release_path = paths.release,
                .command_release_path = paths.command_release,
            },
        );
        var backend_owned = true;
        errdefer if (backend_owned) {
            backend.killSession();
            backend.deinit();
        };
        try backend.beginCapture();
        var capture = try backend.acceptCapture();
        var capture_owned = true;
        errdefer if (capture_owned) capture.close(io_mod.getIo());
        if (self.monitor_owner) |owner| try owner.arm();

        self.tmux_backend = backend;
        backend_owned = false;
        self.tmux_capture = capture;
        capture_owned = false;
        self.output_active.store(true, .release);
        self.output_thread = std.Thread.spawn(.{}, outputMain, .{self}) catch |err| {
            self.output_active.store(false, .release);
            self.tmux_capture.?.close(io_mod.getIo());
            self.tmux_capture = null;
            self.tmux_backend.?.killSession();
            self.tmux_backend.?.deinit();
            self.tmux_backend = null;
            return err;
        };
        self.backend_started = true;
        self.control_thread = std.Thread.spawn(.{}, tmuxControlMain, .{self}) catch |err| {
            self.backend_started = false;
            self.tmux_backend.?.stopCapture();
            self.tmux_capture.?.close(io_mod.getIo());
            self.tmux_capture = null;
            self.output_thread.?.join();
            self.output_thread = null;
            self.tmux_backend.?.killSession();
            self.tmux_backend.?.deinit();
            self.tmux_backend = null;
            return err;
        };
        maybeDelayForTest("FX_TERMINAL_TEST_TMUX_PREPARED_RELEASE_DELAY_MS");
        self.tmux_backend.?.release() catch |err| {
            self.tmux_backend.?.killSession();
            return err;
        };
        self.child_released = true;
    }

    fn recoverTmux(
        self: *Session,
        durable_root: []const u8,
        transport_root: []const u8,
    ) !bool {
        const executable = try self_exe.pathForPeerReexec(self.alloc);
        defer self.alloc.free(executable);
        const backend = tmux_session.Backend.recover(
            self.alloc,
            self.durable.profile.process_provider,
            durable_root,
            transport_root,
            self.durable.record.backend_identity,
            executable,
        ) catch |err| {
            debug_trace.logf(
                "terminal_host",
                "tmux recovery stage=backend id={s} err={s}",
                .{ self.id, @errorName(err) },
            );
            return err;
        };
        self.tmux_backend = backend;
        const recovered = &self.tmux_backend.?;
        if (tmuxRecoveryFailure(self.id, "after-backend")) return error.InjectedFailure;

        const frames = recovered.lifecycle() catch |err| {
            debug_trace.logf("terminal_host", "tmux recovery stage=lifecycle id={s} err={s}", .{ self.id, @errorName(err) });
            return err;
        };
        defer self.alloc.free(frames);
        if (tmuxRecoveryFailure(self.id, "lifecycle") or
            tmuxRecoveryFailure(self.id, "allocation") or
            tmuxRecoveryFailure(self.id, "storage")) return error.InjectedFailure;
        const terminal_present = tmuxTerminalFrame(frames) != null;
        if (recovered.paneIsDead() and !terminal_present) {
            return error.TmuxCompletionUnavailable;
        }
        if (self.lifecycle == .starting) {
            if (tmuxShellPid(frames)) |raw_pid| {
                const identity = try recovered.shellIdentity();
                if (std.math.cast(u32, identity.pid) != raw_pid) {
                    return error.TmuxRecoveryReplaced;
                }
                if (!terminal_present) {
                    var pid_buffer: [32]u8 = undefined;
                    const pid_text = try std.fmt.bufPrint(
                        &pid_buffer,
                        "{d}",
                        .{identity.pid},
                    );
                    switch (self.durable.profile.process_provider.matchToken(
                        self.alloc,
                        pid_text,
                        identity.process_token,
                    )) {
                        .matched => {},
                        .missing, .mismatched => return error.TmuxRecoveryReplaced,
                        .unavailable => return error.TmuxRecoveryIdentityUnavailable,
                    }
                }
                self.child_pid = identity.pid;
                self.child_token = identity.process_token;
                self.recovered_start_identity = true;
            }
        }
        if (tmuxRecoveryFailure(self.id, "identity")) return error.InjectedFailure;
        const process_paused = !terminal_present and self.child_pid != null;
        if (process_paused and !self.signalNative(std.c.SIG.STOP)) {
            return error.TmuxChildIdentityUnavailable;
        }
        defer if (process_paused) {
            if (!self.signalNative(std.c.SIG.CONT)) {
                debug_trace.logf(
                    "terminal_host",
                    "tmux recovery resume failed id={s}",
                    .{self.id},
                );
            }
        };

        if (tmuxRecoveryFailure(self.id, "capture")) return error.InjectedFailure;
        var capture = recovered.captureScreen() catch |err| {
            debug_trace.logf("terminal_host", "tmux recovery stage=screen-capture id={s} err={s}", .{ self.id, @errorName(err) });
            return err;
        };
        defer capture.deinit();
        if (tmuxRecoveryFailure(self.id, "screen-capture")) return error.InjectedFailure;
        self.reanchorTmuxScreen(capture) catch |err| {
            debug_trace.logf("terminal_host", "tmux recovery stage=screen-reanchor id={s} err={s}", .{ self.id, @errorName(err) });
            return err;
        };
        if (tmuxRecoveryFailure(self.id, "screen-reanchor")) return error.InjectedFailure;
        self.child_released = true;

        if (terminal_present) {
            try self.applyRecoveredTmuxFrames(frames);
            try recovered.cleanupChecked(
                self.durable.profile.process_provider,
            );
            recovered.deinit();
            self.tmux_backend = null;
            return false;
        }

        if (self.lifecycle == .running) {
            self.tmux_lifecycle_index = tmuxStartupFrameCount(frames);
        }
        if (self.monitor_owner) |owner| try owner.arm();
        if (tmuxRecoveryFailure(self.id, "monitor-arm")) return error.InjectedFailure;
        recovered.beginCapture() catch |err| {
            debug_trace.logf("terminal_host", "tmux recovery stage=begin-capture id={s} err={s}", .{ self.id, @errorName(err) });
            return err;
        };
        if (tmuxRecoveryFailure(self.id, "begin-capture")) return error.InjectedFailure;
        const stream = recovered.acceptCapture() catch |err| {
            debug_trace.logf("terminal_host", "tmux recovery stage=accept-capture id={s} err={s}", .{ self.id, @errorName(err) });
            return err;
        };
        self.tmux_capture = stream;
        if (tmuxRecoveryFailure(self.id, "accept-capture")) return error.InjectedFailure;
        self.output_active.store(true, .release);
        self.output_thread = std.Thread.spawn(.{}, outputMain, .{self}) catch |err| {
            self.output_active.store(false, .release);
            return err;
        };
        if (tmuxRecoveryFailure(self.id, "output-thread")) return error.InjectedFailure;
        if (self.lifecycle == .starting and self.child_pid == null) {
            self.tmux_backend.?.release() catch |err| {
                debug_trace.logf("terminal_host", "tmux recovery stage=release-prepared id={s} err={s}", .{ self.id, @errorName(err) });
                return err;
            };
            self.child_released = true;
            if (tmuxRecoveryFailure(self.id, "release")) return error.InjectedFailure;
        }
        if (tmuxRecoveryFailure(self.id, "control-thread")) return error.InjectedFailure;
        self.control_thread = try std.Thread.spawn(.{}, tmuxControlMain, .{self});
        self.backend_started = true;
        return true;
    }

    fn reanchorTmuxScreen(
        self: *Session,
        capture: tmux_session.ScreenCapture,
    ) !void {
        const now_ms = io_mod.milliTimestamp();
        if (self.durable.record.raw_gap == null) {
            _ = try self.durable.begin_raw_gap(now_ms);
        }
        if (self.monitor_owner) |owner| try owner.degradeForRawGap(now_ms);
        if (tmuxRecoveryFailure(self.id, "after-gap")) return error.InjectedFailure;
        if (capture.dimensions.rows != self.dimensions.rows or
            capture.dimensions.columns != self.dimensions.columns)
        {
            try self.durable.check_resize_capacity(capture.dimensions);
            try self.durable.resize(capture.dimensions, now_ms);
            try self.engine.resize(
                capture.dimensions.columns,
                capture.dimensions.rows,
            );
        }
        self.dimensions = capture.dimensions;
        self.screen_available = false;
        if (!capture.exact_modes_available) {
            debug_trace.logf(
                "terminal_host",
                "tmux screen reanchor unavailable id={s} reason=unobservable_modes",
                .{self.id},
            );
            return;
        }
        return error.TmuxScreenFactsUnavailable;
    }

    fn applyRecoveredTmuxFrames(
        self: *Session,
        frames: []const tmux_session.LifecycleFrame,
    ) !void {
        if (frames.len == 0 or frames[0].kind != .prepared) {
            return error.InvalidTmuxLifecycle;
        }
        for (frames[1..]) |frame| {
            if (self.lifecycle == .running and !tmuxLifecycleTerminal(frame.kind)) {
                continue;
            }
            switch (frame.kind) {
                .prepared => return error.InvalidTmuxLifecycle,
                .shell_ready => if (self.command == null) {
                    self.publishStarted(frame.value);
                } else {
                    self.shell_ready_seen = true;
                },
                .command_started => {
                    if (self.command == null or !self.shell_ready_seen) {
                        return error.InvalidTmuxLifecycle;
                    }
                    self.command_start_cursor = self.durable.output_cursor();
                    self.publishStarted(frame.value);
                },
                .command_exited => self.setTerm(.{ .exited = @intCast(frame.value) }),
                .command_signal => {
                    const signal = signalFromInt(frame.value) orelse
                        return error.InvalidTmuxLifecycle;
                    self.setTerm(.{ .signal = signal });
                },
                .startup_failed => self.handleControl(.{
                    .kind = .startup_failed,
                    .value = frame.value,
                }),
                .invalid_term => self.markLost(),
            }
        }
    }

    fn launchNative(self: *Session, request: contracts.StartRequest) !void {
        var invocation = try shell_resolver.resolve(
            null,
            pinnedShell(request.shell, self.shell),
        );

        var nonce_bytes: [16]u8 = undefined;
        io_mod.getIo().random(&nonce_bytes);
        const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);
        var path_bytes: [16]u8 = undefined;
        io_mod.getIo().random(&path_bytes);
        const path_suffix = std.fmt.bytesToHex(path_bytes, .lower);
        const control_path = try std.fmt.allocPrint(
            self.alloc,
            "/tmp/fx-terminal-{s}.sock",
            .{path_suffix},
        );
        defer self.alloc.free(control_path);
        const bootstrap_path = try std.fmt.allocPrint(
            self.alloc,
            "/tmp/fx-terminal-{s}.bootstrap",
            .{path_suffix},
        );
        defer self.alloc.free(bootstrap_path);
        const command_path = if (request.command != null)
            try std.fmt.allocPrint(
                self.alloc,
                "/tmp/fx-terminal-{s}.command",
                .{path_suffix},
            )
        else
            null;
        defer if (command_path) |path| self.alloc.free(path);

        const executable = try self_exe.pathForPeerReexec(self.alloc);
        defer self.alloc.free(executable);
        const bootstrap = try shell_resolver.buildBootstrap(
            self.alloc,
            executable,
            control_path,
            &nonce,
            command_path,
        );
        defer self.alloc.free(bootstrap);
        const source_command = try shell_resolver.buildSourceCommand(
            self.alloc,
            bootstrap_path,
        );
        defer self.alloc.free(source_command);
        if (request.command != null) invocation.setCommand(source_command);

        const pty = try openPty();
        var master_open = true;
        errdefer if (master_open) closeFd(pty.master);
        var slave_open = true;
        defer if (slave_open) closeFd(pty.slave);
        try resizeFd(pty.slave, self.dimensions);
        if (request.command == null) try setEcho(pty.slave, false);

        const helper_argv = [_][]const u8{ executable, launcher_mode };
        const slave_file = std.Io.File{
            .handle = pty.slave,
            .flags = .{ .nonblocking = false },
        };
        var child = try std.process.spawn(io_mod.getIo(), .{
            .argv = &helper_argv,
            .stdin = .pipe,
            .stdout = .{ .file = slave_file },
            .stderr = .pipe,
        });
        var child_owned = true;
        errdefer if (child_owned) child.kill(io_mod.getIo());
        closeFd(pty.slave);
        slave_open = false;

        var config_output: std.Io.Writer.Allocating = .init(self.alloc);
        defer config_output.deinit();
        try std.json.Stringify.value(LauncherConfig{
            .argv = invocation.argv(),
            .cwd = request.cwd,
            .dimensions = self.dimensions,
            .control_path = control_path,
            .control_nonce = &nonce,
            .bootstrap_path = bootstrap_path,
            .bootstrap = bootstrap,
            .command_path = command_path,
            .command = request.command,
        }, .{}, &config_output.writer);
        if (config_output.written().len > launcher_config_bytes) {
            return error.LauncherConfigTooLarge;
        }
        var length_bytes: [4]u8 = undefined;
        std.mem.writeInt(
            u32,
            &length_bytes,
            @intCast(config_output.written().len),
            .little,
        );

        var input = child.stdin orelse return error.LauncherInputMissing;
        child.stdin = null;
        var input_open = true;
        errdefer if (input_open) input.close(io_mod.getIo());
        try input.writeStreamingAll(io_mod.getIo(), &length_bytes);
        try input.writeStreamingAll(io_mod.getIo(), config_output.written());

        var control = child.stderr orelse return error.LauncherControlMissing;
        child.stderr = null;
        var control_open = true;
        errdefer if (control_open) control.close(io_mod.getIo());
        const prepared = readControlFile(control) catch
            return error.LauncherNotPrepared;
        if (prepared.kind != .prepared) return error.LauncherNotPrepared;

        self.master_fd = pty.master;
        master_open = false;
        self.launcher = child;
        child_owned = false;
        self.control_file = control;
        control_open = false;
        self.output_active.store(true, .release);
        self.output_thread = std.Thread.spawn(.{}, outputMain, .{self}) catch |err| {
            self.output_active.store(false, .release);
            return err;
        };
        self.backend_started = true;
        self.control_thread = std.Thread.spawn(.{}, controlMain, .{self}) catch |err| {
            self.backend_started = false;
            closeFd(self.master_fd.?);
            self.master_fd = null;
            self.output_thread.?.join();
            self.output_thread = null;
            return err;
        };
        if (request.command == null) {
            try writeAllFd(self.master_fd.?, source_command, true);
        }
        self.liveness_file = input;
        input_open = false;
        if (self.monitor_owner) |owner| try owner.arm();
        try input.writeStreamingAll(io_mod.getIo(), &.{1});
        self.child_released = true;
    }

    fn deinit(self: *Session) void {
        self.shutdown();
        if (self.backend_started) {
            self.finalizeBackend();
        } else {
            if (self.output_thread) |thread| thread.join();
            if (self.master_fd) |fd| closeFd(fd);
            if (self.tmux_capture) |stream| stream.close(io_mod.getIo());
            if (self.control_file) |file| file.close(io_mod.getIo());
            if (self.liveness_file) |file| file.close(io_mod.getIo());
            if (self.launcher) |*child| {
                if (child.id != null) child.kill(io_mod.getIo());
            }
        }
        if (self.tmux_backend) |*backend| {
            if (!self.close_committed) backend.killSession();
            backend.deinit();
            self.tmux_backend = null;
        }
        self.markNotLive();
        self.deinitUnlaunched();
    }

    fn deinitRecoveryAttempt(self: *Session) void {
        std.debug.assert(!self.backend_started);
        self.stopTmuxRecoveryHandles();
        if (self.tmux_backend) |*backend| {
            backend.deinitRetainingOwnedNamespace();
            self.tmux_backend = null;
        }
        self.markNotLive();
        self.deinitUnlaunched();
    }

    fn deinitRecoveredRegistryAttempt(self: *Session) void {
        if (!self.backend_started) {
            self.deinitRecoveryAttempt();
            return;
        }
        self.backend_detaching.store(true, .release);
        if (self.tmux_backend) |*backend| backend.stopCapture();
        if (self.tmux_capture) |stream| {
            stream.close(io_mod.getIo());
            self.tmux_capture = null;
        }
        self.backend_done.waitUncancelable(io_mod.getIo());
        if (self.control_thread) |thread| {
            thread.join();
            self.control_thread = null;
        }
        self.backend_started = false;
        if (self.tmux_backend) |*backend| {
            backend.deinitRetainingOwnedNamespace();
            self.tmux_backend = null;
        }
        self.markNotLive();
        self.deinitUnlaunched();
    }

    fn cleanupDefinitiveTmuxRecoveryAttempt(self: *Session) !void {
        std.debug.assert(!self.backend_started);
        self.stopTmuxRecoveryHandles();
        const backend = if (self.tmux_backend) |*value| value else return;
        backend.cleanupChecked(
            self.durable.profile.process_provider,
        ) catch |err| {
            backend.deinitRetainingOwnedNamespace();
            self.tmux_backend = null;
            return err;
        };
        backend.deinit();
        self.tmux_backend = null;
    }

    fn stopTmuxRecoveryHandles(self: *Session) void {
        if (self.tmux_backend) |*backend| backend.stopCapture();
        if (self.tmux_capture) |stream| {
            stream.close(io_mod.getIo());
            self.tmux_capture = null;
        }
        if (self.output_thread) |thread| {
            thread.join();
            self.output_thread = null;
        }
        self.output_active.store(false, .release);
    }

    fn shutdown(self: *Session) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        const running = self.lifecycle == .starting or self.lifecycle == .running;
        self.mutex.unlock(zio);
        if (running) _ = self.signalProcess(.kill);
        self.closeLiveness();
    }

    fn finalizeBackend(self: *Session) void {
        const zio = io_mod.getIo();
        self.backend_join_mutex.lockUncancelable(zio);
        defer self.backend_join_mutex.unlock(zio);
        if (!self.backend_started) return;
        self.backend_done.waitUncancelable(zio);
        if (self.control_thread) |thread| {
            thread.join();
            self.control_thread = null;
        }
        self.backend_started = false;
        self.durable.release_completed_handles();
    }

    fn markLive(self: *Session) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (!self.live_counted) {
            self.live_counted = true;
            self.tracker.update(true);
        }
        self.mutex.unlock(zio);
    }

    fn markNotLive(self: *Session) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (self.live_counted) {
            self.live_counted = false;
            self.tracker.update(false);
        }
        self.mutex.unlock(zio);
    }

    fn waitFor(
        self: *Session,
        condition: contracts.ReturnCondition,
        ceiling_ms: u64,
        cancelled: *const std.atomic.Value(bool),
    ) !contracts.ReturnOutcome {
        const start_ms = io_mod.milliTimestamp();
        const ceiling_i64: i64 = @intCast(@min(
            ceiling_ms,
            @as(u64, @intCast(std.math.maxInt(i64))),
        ));
        while (true) {
            if (cancelled.load(.acquire)) return .cancelled;
            const now = io_mod.milliTimestamp();
            const zio = io_mod.getIo();
            self.mutex.lockUncancelable(zio);
            const outcome = self.matchConditionLocked(condition, now);
            const lost = self.lifecycle == .lost;
            self.mutex.unlock(zio);
            if (outcome) |value| return value;
            if (lost) return error.SessionLost;
            if (now - start_ms >= ceiling_i64) return .safety_ceiling;
            io_mod.sleep(wait_poll_ns);
        }
    }

    fn startFailureCode(self: *Session) contracts.StructuredErrorCode {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return self.start_failure orelse .session_lost;
    }

    fn isRecyclable(self: *Session) bool {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return (self.lifecycle == .exited or
            self.lifecycle == .lost or
            self.lifecycle == .closed) and !self.live_counted;
    }

    fn matchConditionLocked(
        self: *Session,
        condition: contracts.ReturnCondition,
        now_ms: i64,
    ) ?contracts.ReturnOutcome {
        if (self.term) |term| return outcomeFromTerm(term);
        return switch (condition) {
            .started => if (self.lifecycle == .running) .started else null,
            .exit => null,
            .quiet => |quiet_ms| blk: {
                if (self.lifecycle != .running) break :blk null;
                const quiet_i64: i64 = @intCast(@min(
                    quiet_ms,
                    @as(u64, @intCast(std.math.maxInt(i64))),
                ));
                break :blk if (now_ms - self.last_output_ms >= quiet_i64)
                    .condition_met
                else
                    null;
            },
            .match => |pattern| blk: {
                if (self.lifecycle != .running) break :blk null;
                if (self.command != null and self.startup_match != null and
                    std.mem.eql(u8, self.startup_match.?, pattern))
                {
                    break :blk if (self.startup_match_seen)
                        .condition_met
                    else
                        null;
                }
                break :blk if (self.durable.contains(
                    pattern,
                    self.durable.available_cursor(),
                ) catch false)
                    .condition_met
                else
                    null;
            },
        };
    }

    fn startResult(
        self: *Session,
        outcome: contracts.ReturnOutcome,
        authorization: terminal_store.Authorization,
    ) Allocator.Error!contracts.OwnedResult {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .start = .{
                .session = self.factsLocked(authorization),
                .outcome = outcome,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn waitResult(
        self: *Session,
        outcome: contracts.ReturnOutcome,
        authorization: terminal_store.Authorization,
    ) Allocator.Error!contracts.OwnedResult {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        return contracts.OwnedResult.init(
            self.alloc,
            .{ .success = .{ .wait = .{
                .session = self.factsLocked(authorization),
                .outcome = outcome,
            } } },
        ) catch return error.OutOfMemory;
    }

    fn factsLocked(
        self: *const Session,
        authorization: terminal_store.Authorization,
    ) contracts.SessionFacts {
        return projectedFacts(self.durable.facts(), authorization);
    }

    fn signalProcess(self: *Session, signal: contracts.Signal) bool {
        return self.signalNative(signalValue(signal));
    }

    fn signalTarget(self: *Session) ?SignalTarget {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        if (!contracts.lifecycle_controls(self.lifecycle).signal) return null;
        return .{
            .pid = self.child_pid orelse return null,
            .token = self.child_token orelse return null,
        };
    }

    fn matchesSignalTarget(self: *Session, target: SignalTarget) bool {
        var pid_buffer: [32]u8 = undefined;
        const pid_text = std.fmt.bufPrint(
            &pid_buffer,
            "{d}",
            .{target.pid},
        ) catch return false;
        return self.durable.profile.process_provider.matchToken(
            self.alloc,
            pid_text,
            target.token,
        ) == .matched;
    }

    fn signalTerminalProcesses(
        self: *Session,
        signal: contracts.Signal,
    ) !?bool {
        const target = self.signalTarget() orelse return null;
        if (!self.matchesSignalTarget(target)) return false;
        if (failSignalStageForTest("refresh")) {
            return error.ProcessIdentityUnavailable;
        }

        var descendants = try process_tree.Tracker.init(self.alloc);
        defer descendants.deinit();
        descendants.refresh(target.pid) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ProcessIdentityUnavailable,
        };
        if (!self.matchesSignalTarget(target)) return false;

        var descendants_delivery = descendants.signalOutsideProcessGroupChecked(
            signalValue(signal),
            target.pid,
        );
        if (failSignalStageForTest("outside_group")) {
            descendants_delivery.incomplete = true;
        }
        debug_trace.logf(
            "terminal_host",
            "session signal reached outside-group descendants id={s} count={d} incomplete={any}",
            .{ self.id, descendants_delivery.delivered, descendants_delivery.incomplete },
        );
        return terminalSignalCompleted(
            descendants_delivery,
            !failSignalStageForTest("shell_group") and self.signalProcess(signal),
        );
    }

    fn signalNative(self: *Session, signal: std.c.SIG) bool {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        const pid = self.child_pid;
        const token = self.child_token;
        const running = self.lifecycle == .starting or self.lifecycle == .running;
        self.mutex.unlock(zio);
        if (!running or pid == null or token == null) return false;
        var pid_buffer: [32]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{pid.?}) catch
            return false;
        if (self.durable.profile.process_provider.matchToken(
            self.alloc,
            pid_text,
            token.?,
        ) != .matched) return false;
        return std.c.kill(-pid.?, signal) == 0;
    }

    fn appendOutput(self: *Session, bytes: []const u8) void {
        const zio = io_mod.getIo();
        self.write_mutex.lockUncancelable(zio);
        defer self.write_mutex.unlock(zio);
        const screen_evaluation_required = if (self.monitor_owner) |owner|
            owner.screenEvaluationRequired()
        else
            false;
        var feed_result: ?terminal_engine.FeedResult = null;
        var checkpoint_cursor: ?contracts.RawCursor = null;
        var screen_text: std.ArrayList(u8) = .empty;
        var screen_projection_available = false;
        defer screen_text.deinit(self.alloc);
        self.mutex.lockUncancelable(zio);
        const now_ms = io_mod.milliTimestamp();
        self.durable.append(bytes, now_ms) catch |err| {
            const cursor = self.durable.record.output_cursor;
            debug_trace.logf(
                "terminal_host",
                "journal append failed id={s} cursor={d}:{d} raw_gap={any} err={s}",
                .{
                    self.id,
                    cursor.segment,
                    cursor.offset,
                    self.durable.record.raw_gap != null,
                    @errorName(err),
                },
            );
            self.persistLostLocked(now_ms);
            self.mutex.unlock(zio);
            return;
        };
        if (self.screen_available) {
            const feed_mode: terminal_engine.FeedMode = if (self.durable.record.backend == .tmux) .tmux_live else .native_live;
            feed_result = self.engine.feedMode(bytes, feed_mode) catch |err| blk: {
                self.screen_available = false;
                debug_trace.logf(
                    "terminal_host",
                    "screen feed unavailable id={s} err={s}",
                    .{ self.id, @errorName(err) },
                );
                break :blk null;
            };
            if (feed_result != null) {
                checkpoint_cursor = self.durable.checkpoint_due_cursor();
                if (screen_evaluation_required) {
                    if (monitorOutputScreenProjectionAllocationFailure()) {
                        debug_trace.logf(
                            "terminal_monitor",
                            "screen output evaluation skipped id={s} err={s}",
                            .{ self.id, @errorName(error.InjectedFailure) },
                        );
                    } else {
                        var projection_failed = false;
                        self.appendScreenTextLocked(
                            &self.engine,
                            &screen_text,
                        ) catch |err| {
                            debug_trace.logf(
                                "terminal_monitor",
                                "screen output evaluation skipped id={s} err={s}",
                                .{ self.id, @errorName(err) },
                            );
                            screen_text.clearRetainingCapacity();
                            projection_failed = true;
                        };
                        screen_projection_available = !projection_failed;
                    }
                }
            }
        }
        self.last_output_ms = now_ms;
        if (!self.startup_match_seen and self.startup_match != null) {
            const eligible = self.command == null or
                self.command_start_cursor != null;
            if (eligible) {
                const anchor = self.command_start_cursor orelse
                    self.durable.available_cursor();
                self.startup_match_seen = self.durable.contains(
                    self.startup_match.?,
                    anchor,
                ) catch false;
            }
        }
        const master_fd = if (self.input_quiesced) null else self.master_fd;
        self.mutex.unlock(zio);

        if (self.monitor_owner) |owner| owner.onOutput(
            bytes,
            if (screen_projection_available) screen_text.items else null,
            now_ms,
        );

        if (feed_result) |*result| {
            defer result.deinit(self.alloc);
            if (self.durable.record.backend == .tmux) {
                std.debug.assert(result.replies.items.len == 0);
            } else {
                const fd = master_fd orelse return;
                for (result.replies.items) |reply| {
                    writeAllFd(fd, reply.bytes, true) catch |err| {
                        debug_trace.logf(
                            "terminal_host",
                            "terminal protocol reply failed id={s} err={s}",
                            .{ self.id, @errorName(err) },
                        );
                        return;
                    };
                }
            }
        }

        if (checkpoint_cursor) |cursor| {
            self.mutex.lockUncancelable(zio);
            defer self.mutex.unlock(zio);
            if (!self.screen_available) return;
            self.checkpointLocked(cursor, now_ms) catch |err| {
                debug_trace.logf(
                    "terminal_host",
                    "screen checkpoint failed id={s} err={s}",
                    .{ self.id, @errorName(err) },
                );
            };
        }
    }

    fn appendScreenTextLocked(
        self: *Session,
        engine: *const terminal_engine.Grid,
        screen_text: *std.ArrayList(u8),
    ) !void {
        var row: u16 = 1;
        while (row <= engine.rows) : (row += 1) {
            try engine.rowTextTrimmed(row, screen_text);
            try screen_text.append(self.alloc, '\n');
        }
    }

    fn checkpointLocked(
        self: *Session,
        applied_cursor: contracts.RawCursor,
        now_ms: i64,
    ) !void {
        if (contracts.compare_raw_cursors(
            applied_cursor,
            self.durable.output_cursor(),
        ) != .eq) return error.InvalidCheckpoint;
        const payload = try self.engine.checkpointPayload(self.alloc);
        defer self.alloc.free(payload);
        const payload_len = std.math.cast(u32, payload.len) orelse
            return error.CheckpointTooLarge;
        const envelope = contracts.CheckpointEnvelope{
            .engine_schema_revision = terminal_engine.checkpoint_schema_revision,
            .applied_cursor = applied_cursor,
            .payload_len = payload_len,
            .checksum = contracts.checkpoint_checksum(payload),
        };
        try self.durable.store_checkpoint(envelope, payload, now_ms);
    }

    fn handleControl(self: *Session, frame: ControlFrame) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        const closing = self.close_committed;
        self.mutex.unlock(zio);
        if (closing and frame.kind != .command_exited and
            frame.kind != .command_signal)
        {
            return;
        }
        switch (frame.kind) {
            .prepared => {},
            .shell_ready => {
                if (self.command == null) {
                    if (self.tmux_backend == null and
                        !self.establishStartupBoundary())
                    {
                        debug_trace.logf(
                            "terminal_host",
                            "terminal shell boundary unavailable id={s}",
                            .{self.id},
                        );
                        self.failClosed(.session_lost);
                        return;
                    }
                    self.publishStarted(frame.value);
                } else {
                    self.mutex.lockUncancelable(zio);
                    if (self.lifecycle != .starting or self.shell_ready_seen) {
                        debug_trace.logf(
                            "terminal_host",
                            "tmux shell-ready rejected id={s} lifecycle={s} seen={any}",
                            .{ self.id, @tagName(self.lifecycle), self.shell_ready_seen },
                        );
                        self.lifecycle = .lost;
                        self.start_failure = .session_lost;
                    } else {
                        self.shell_ready_seen = true;
                    }
                    self.mutex.unlock(zio);
                }
            },
            .command_started => {
                self.mutex.lockUncancelable(zio);
                const valid = self.command != null and
                    self.lifecycle == .starting and
                    self.shell_ready_seen;
                self.mutex.unlock(zio);
                if (!valid) {
                    debug_trace.logf(
                        "terminal_host",
                        "tmux recovered command boundary invalid id={s}",
                        .{self.id},
                    );
                    self.failClosed(.session_lost);
                    return;
                }
                if (!self.establishStartupBoundary()) {
                    debug_trace.logf(
                        "terminal_host",
                        "terminal command boundary unavailable id={s}",
                        .{self.id},
                    );
                    self.failClosed(.session_lost);
                    return;
                }
                self.publishStarted(frame.value);
                if (!self.releaseCommandEvaluation()) {
                    debug_trace.logf(
                        "terminal_host",
                        "tmux recovered command release unavailable id={s}",
                        .{self.id},
                    );
                    self.failClosed(.session_lost);
                }
            },
            .command_exited => self.setTerm(.{ .exited = @intCast(frame.value) }),
            .command_signal => {
                const signal = signalFromInt(frame.value) orelse {
                    self.markLost();
                    return;
                };
                self.setTerm(.{ .signal = signal });
            },
            .startup_failed => {
                debug_trace.logf(
                    "terminal_host",
                    "tmux startup failed id={s} code={d}",
                    .{ self.id, frame.value },
                );
                const failure: StartupFailure = switch (frame.value) {
                    1 => .shell_unavailable,
                    2 => .profile_failed,
                    3 => .control_failed,
                    else => {
                        self.markLost();
                        return;
                    },
                };
                self.failClosed(switch (failure) {
                    .shell_unavailable => .shell_unavailable,
                    .profile_failed, .control_failed => .startup_failed,
                });
            },
            .invalid_term => {
                debug_trace.logf(
                    "terminal_host",
                    "tmux launcher reported invalid term id={s}",
                    .{self.id},
                );
                self.markLost();
            },
        }
    }

    fn publishStarted(self: *Session, raw_pid: u32) void {
        const pid = std.math.cast(std.posix.pid_t, raw_pid) orelse {
            self.failClosed(.session_lost);
            return;
        };
        var pid_buffer: [32]u8 = undefined;
        const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{pid}) catch {
            self.failClosed(.session_lost);
            return;
        };
        const recovered_token = if (self.recovered_start_identity and
            self.child_pid == pid)
            self.child_token
        else
            null;
        const token: ?process_supervisor.ProcessInstanceToken =
            if (recovered_token) |value|
                value
            else
                self.durable.profile.process_provider.captureToken(
                    self.alloc,
                    pid_text,
                ) catch null;
        if (token == null) {
            debug_trace.logf(
                "terminal_host",
                "tmux recovered child identity unavailable id={s} pid={d}",
                .{ self.id, pid },
            );
            self.failClosed(.process_identity_unavailable);
            return;
        }
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (self.lifecycle != .starting or
            (self.child_pid != null and !self.recovered_start_identity))
        {
            debug_trace.logf(
                "terminal_host",
                "terminal child start rejected id={s} lifecycle={s} pending={any}",
                .{ self.id, @tagName(self.lifecycle), self.recovered_start_identity },
            );
            self.persistLostLocked(io_mod.milliTimestamp());
        } else {
            self.durable.mark_started(
                pid_text,
                token.?,
                io_mod.milliTimestamp(),
            ) catch |err| {
                debug_trace.logf(
                    "terminal_host",
                    "starting record update failed id={s} err={s}",
                    .{ self.id, @errorName(err) },
                );
                self.persistLostLocked(io_mod.milliTimestamp());
                self.mutex.unlock(zio);
                self.closeLiveness();
                return;
            };
            self.child_pid = pid;
            self.child_token = token;
            self.recovered_start_identity = false;
            self.lifecycle = contracts.transition_lifecycle(
                self.lifecycle,
                .child_started,
            ) catch .lost;
        }
        const failed = self.lifecycle == .lost;
        self.mutex.unlock(zio);
        if (failed) self.closeLiveness();
    }

    fn setTerm(self: *Session, term: std.process.Child.Term) void {
        const zio = io_mod.getIo();
        self.write_mutex.lockUncancelable(zio);
        self.mutex.lockUncancelable(zio);
        const final_checkpoint = self.lifecycle == .running and self.screen_available;
        if (final_checkpoint) {
            self.checkpointLocked(
                self.durable.output_cursor(),
                io_mod.milliTimestamp(),
            ) catch |err| {
                debug_trace.logf(
                    "terminal_host",
                    "final screen checkpoint failed id={s} err={s}",
                    .{ self.id, @errorName(err) },
                );
            };
        }
        self.mutex.unlock(zio);
        self.write_mutex.unlock(zio);
        self.mutex.lockUncancelable(zio);
        if (self.close_committed) {
            self.term = term;
            self.lifecycle = .closed;
            self.mutex.unlock(zio);
            self.closeLiveness();
            return;
        }
        if (self.lifecycle != .running) {
            if (self.lifecycle == .starting) {
                debug_trace.logf(
                    "terminal_host",
                    "terminal exited before start publication id={s}",
                    .{self.id},
                );
                self.persistLostLocked(io_mod.milliTimestamp());
                self.start_failure = .startup_failed;
            }
            self.mutex.unlock(zio);
            self.closeLiveness();
            return;
        }
        const persisted: terminal_store.PersistedTermination = switch (term) {
            .exited => |code| .{ .exited = code },
            .signal => |signal| .{ .signal = @intFromEnum(signal) },
            .stopped, .unknown => {
                self.persistLostLocked(io_mod.milliTimestamp());
                self.mutex.unlock(zio);
                self.closeLiveness();
                return;
            },
        };
        const now_ms = io_mod.milliTimestamp();
        self.durable.persist_termination(
            persisted,
            now_ms,
        ) catch |err| {
            debug_trace.logf(
                "terminal_host",
                "termination persistence failed id={s} err={s}",
                .{ self.id, @errorName(err) },
            );
            self.persistLostLocked(io_mod.milliTimestamp());
            self.mutex.unlock(zio);
            self.closeLiveness();
            return;
        };
        self.term = term;
        if (self.lifecycle != .closed) {
            self.lifecycle = contracts.transition_lifecycle(
                self.lifecycle,
                .child_exited,
            ) catch .lost;
        }
        self.mutex.unlock(zio);
        if (self.monitor_owner) |owner| owner.onSessionEnd(term, now_ms);
    }

    fn failClosed(
        self: *Session,
        code: contracts.StructuredErrorCode,
    ) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (self.lifecycle == .starting or self.lifecycle == .running) {
            self.persistLostLocked(io_mod.milliTimestamp());
            self.start_failure = code;
        }
        self.mutex.unlock(zio);
        self.closeLiveness();
    }

    fn closeLiveness(self: *Session) void {
        const zio = io_mod.getIo();
        self.write_mutex.lockUncancelable(zio);
        defer self.write_mutex.unlock(zio);
        self.mutex.lockUncancelable(zio);
        const file = self.liveness_file;
        self.liveness_file = null;
        self.mutex.unlock(zio);
        if (file) |value| value.close(zio);
    }

    fn markLost(self: *Session) void {
        debug_trace.logf(
            "terminal_host",
            "terminal marked lost id={s}",
            .{self.id},
        );
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (self.lifecycle == .starting or self.lifecycle == .running) {
            self.persistLostLocked(io_mod.milliTimestamp());
            if (self.start_failure == null) self.start_failure = .session_lost;
        }
        self.mutex.unlock(zio);
        self.closeLiveness();
    }

    fn persistLostLocked(self: *Session, now_ms: i64) void {
        if (self.close_committed) {
            self.lifecycle = .lost;
            if (self.start_failure == null) self.start_failure = .session_lost;
            return;
        }
        self.durable.persist_lost(now_ms) catch |err| {
            debug_trace.logf(
                "terminal_host",
                "lost record update failed id={s} err={s}",
                .{ self.id, @errorName(err) },
            );
        };
        self.lifecycle = .lost;
        if (self.start_failure == null) self.start_failure = .session_lost;
    }

    fn establishStartupBoundary(self: *Session) bool {
        self.command_boundary_done.reset();
        self.command_boundary_requested.store(true, .release);
        if (!self.output_active.load(.acquire)) {
            self.command_boundary_requested.store(false, .release);
            return false;
        }
        self.command_boundary_done.waitUncancelable(io_mod.getIo());
        return self.output_active.load(.acquire);
    }

    fn commitStartupBoundary(self: *Session) void {
        if (self.command != null) {
            maybeDelayForTest("FX_TERMINAL_TEST_COMMAND_BOUNDARY_DELAY_MS");
        }
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        if (self.command != null) {
            self.command_start_cursor = self.durable.output_cursor();
            self.startup_match_seen = false;
        }
        self.last_output_ms = io_mod.milliTimestamp();
        self.mutex.unlock(zio);
    }

    fn releaseCommandEvaluation(self: *Session) bool {
        const zio = io_mod.getIo();
        self.write_mutex.lockUncancelable(zio);
        defer self.write_mutex.unlock(zio);
        self.mutex.lockUncancelable(zio);
        const file = self.liveness_file;
        const tmux = if (self.tmux_backend) |*backend| backend else null;
        const running = self.lifecycle == .running;
        self.mutex.unlock(zio);
        if (!running) return false;
        if (tmux) |backend| {
            backend.releaseCommand() catch return false;
            return true;
        }
        if (file == null) return false;
        file.?.writeStreamingAll(
            zio,
            &.{command_release_byte},
        ) catch return false;
        return true;
    }
};

fn pinnedShell(
    requested: contracts.ShellSpec,
    resolved_path: []const u8,
) contracts.ShellSpec {
    return .{ .executable = .{
        .path = resolved_path,
        .clean_start = switch (requested) {
            .user_login => false,
            .executable => |value| value.clean_start,
        },
    } };
}

fn screenAction(
    session: *Session,
    request: contracts.SessionRequest,
) !contracts.OwnedResult {
    const authorization = try session.durable.authorize(
        request.authority.?,
        .screen,
    );
    const zio = io_mod.getIo();
    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    var recovered: ?terminal_engine.Grid = null;
    defer if (recovered) |*grid| grid.deinit();
    const grid = if (session.screen_available)
        &session.engine
    else blk: {
        recovered = try reconstructEngine(session.alloc, &session.durable);
        break :blk &recovered.?;
    };
    var snapshot = try grid.renderSnapshot(session.alloc);
    defer snapshot.deinit(session.alloc);
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .screen = .{
            .session = session.factsLocked(authorization),
            .snapshot = snapshot.view(),
        } } },
    ) catch return error.OutOfMemory;
}

fn screenDurable(
    alloc: Allocator,
    durable: *terminal_store.DurableSession,
    authorization: terminal_store.Authorization,
) !contracts.OwnedResult {
    var grid = try reconstructEngine(alloc, durable);
    defer grid.deinit();
    var snapshot = try grid.renderSnapshot(alloc);
    defer snapshot.deinit(alloc);
    const facts = projectedFacts(durable.facts(), authorization);
    return contracts.OwnedResult.init(
        alloc,
        .{ .success = .{ .screen = .{
            .session = facts,
            .snapshot = snapshot.view(),
        } } },
    ) catch return error.OutOfMemory;
}

fn reconstructEngine(
    alloc: Allocator,
    durable: *terminal_store.DurableSession,
) !terminal_engine.Grid {
    const initial = contracts.RawCursor{ .segment = 1, .offset = 0 };
    const available = durable.available_cursor();
    const output = durable.output_cursor();
    const checkpoint_reason: contracts.ScreenUnavailableReason = switch (durable.record.screen_recovery) {
        .available => .corrupt,
        .unavailable => |reason| reason,
    };

    var checkpoint = durable.load_checkpoint(alloc) catch |err| {
        const reason = terminal_store.checkpoint_load_unavailable_reason(err) orelse
            return err;
        return replayFromStart(
            alloc,
            durable,
            initial,
            available,
            output,
            reason,
        );
    } orelse return replayFromStart(
        alloc,
        durable,
        initial,
        available,
        output,
        checkpoint_reason,
    );
    defer checkpoint.deinit(alloc);
    if (checkpoint.envelope.engine_schema_revision !=
        terminal_engine.checkpoint_schema_revision)
    {
        return replayFromStart(
            alloc,
            durable,
            initial,
            available,
            output,
            .unsupported_schema,
        );
    }
    if (!terminal_store.contiguous_after_checkpoint(
        checkpoint.envelope,
        available,
        output,
    )) {
        try durable.mark_screen_unavailable(.raw_gap, io_mod.milliTimestamp());
        return error.ScreenRawGap;
    }

    var grid = terminal_engine.Grid.restoreCheckpoint(
        alloc,
        checkpoint.payload,
    ) catch |err| {
        const reason = engine_checkpoint_unavailable_reason(err) orelse
            return err;
        return replayFromStart(
            alloc,
            durable,
            initial,
            available,
            output,
            reason,
        );
    };
    errdefer grid.deinit();
    if (grid.rows != durable.record.dimensions.rows or
        grid.cols != durable.record.dimensions.columns)
    {
        return replayFromStart(
            alloc,
            durable,
            initial,
            available,
            output,
            .corrupt,
        );
    }
    replayEngine(
        alloc,
        durable,
        &grid,
        checkpoint.envelope.applied_cursor,
        output,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ScreenRawGap, error.MissingJournalSegment => {
            try durable.mark_screen_unavailable(.raw_gap, io_mod.milliTimestamp());
            return error.ScreenRawGap;
        },
        error.ScreenCorrupt, error.CorruptJournalSegment => {
            try durable.mark_screen_unavailable(.corrupt, io_mod.milliTimestamp());
            return error.ScreenCorrupt;
        },
        else => return err,
    };
    return grid;
}

fn engine_checkpoint_unavailable_reason(
    err: anyerror,
) ?contracts.ScreenUnavailableReason {
    return switch (err) {
        error.UnsupportedEngineRevision => .unsupported_schema,
        error.CheckpointTooLarge,
        error.InvalidEngineCheckpoint,
        error.InvalidGridSize,
        => .corrupt,
        else => null,
    };
}

fn replayFromStart(
    alloc: Allocator,
    durable: *terminal_store.DurableSession,
    initial: contracts.RawCursor,
    available: contracts.RawCursor,
    output: contracts.RawCursor,
    reason: contracts.ScreenUnavailableReason,
) !terminal_engine.Grid {
    const unavailable_reason: contracts.ScreenUnavailableReason = if (!durable.record.raw_replay_exact and
        reason == .missing)
        .resize_uncheckpointed
    else
        reason;
    if (!durable.record.raw_replay_exact) {
        try durable.mark_screen_unavailable(
            unavailable_reason,
            io_mod.milliTimestamp(),
        );
        return screenUnavailable(unavailable_reason);
    }
    if (contracts.compare_raw_cursors(available, initial) != .eq) {
        const gap_reason: contracts.ScreenUnavailableReason = if (reason == .retention_evicted)
            .retention_evicted
        else
            .raw_gap;
        try durable.mark_screen_unavailable(gap_reason, io_mod.milliTimestamp());
        return screenUnavailable(gap_reason);
    }
    var grid = try terminal_engine.Grid.init(
        alloc,
        durable.record.dimensions.columns,
        durable.record.dimensions.rows,
    );
    errdefer grid.deinit();
    replayEngine(alloc, durable, &grid, initial, output) catch |err| switch (err) {
        error.ScreenRawGap, error.MissingJournalSegment => {
            try durable.mark_screen_unavailable(.raw_gap, io_mod.milliTimestamp());
            return error.ScreenRawGap;
        },
        error.ScreenCorrupt, error.CorruptJournalSegment => {
            try durable.mark_screen_unavailable(.corrupt, io_mod.milliTimestamp());
            return error.ScreenCorrupt;
        },
        else => return err,
    };
    try durable.mark_screen_unavailable(
        unavailable_reason,
        io_mod.milliTimestamp(),
    );
    return grid;
}

fn replayEngine(
    alloc: Allocator,
    durable: *terminal_store.DurableSession,
    grid: *terminal_engine.Grid,
    start: contracts.RawCursor,
    output: contracts.RawCursor,
) !void {
    var cursor = start;
    while (contracts.compare_raw_cursors(cursor, output) == .lt) {
        var page = try durable.read(alloc, cursor, max_read_bytes);
        defer page.deinit(alloc);
        if (page.gap != null) return error.ScreenRawGap;
        const range = page.range orelse return error.ScreenCorrupt;
        if (contracts.compare_raw_cursors(range.start, cursor) != .eq or
            contracts.compare_raw_cursors(range.end, cursor) != .gt or
            contracts.compare_raw_cursors(range.end, output) == .gt)
        {
            return error.ScreenCorrupt;
        }
        var result = grid.feedMode(page.output, .journal_replay) catch |err| {
            if (replay_feed_error_is_corrupt(err)) return error.ScreenCorrupt;
            return err;
        };
        defer result.deinit(alloc);
        if (result.replies.items.len != 0) return error.ScreenCorrupt;
        cursor = range.end;
    }
    if (contracts.compare_raw_cursors(cursor, output) != .eq) {
        return error.ScreenRawGap;
    }
}

fn replay_feed_error_is_corrupt(err: anyerror) bool {
    return switch (err) {
        error.CombiningPoolCapacityExceeded,
        error.ControlStringTooLarge,
        error.HyperlinkPoolCapacityExceeded,
        error.InvalidFeedMode,
        error.InvalidParserState,
        error.ReplyEffectCapacityExceeded,
        error.SynchronizedUpdateTooLarge,
        error.TooManyCsiIntermediates,
        error.TooManyCsiParameters,
        => true,
        else => false,
    };
}

fn screenUnavailable(reason: contracts.ScreenUnavailableReason) anyerror {
    return switch (reason) {
        .missing => error.ScreenMissing,
        .corrupt => error.ScreenCorrupt,
        .unsupported_schema => error.ScreenUnsupported,
        .retention_evicted => error.ScreenRetentionEvicted,
        .raw_gap => error.ScreenRawGap,
        .resize_uncheckpointed => error.ScreenResizeUncheckpointed,
    };
}

fn readAction(
    session: *Session,
    request: contracts.ReadRequest,
) !contracts.OwnedResult {
    const authorization = try session.durable.authorize(
        request.authority.?,
        .read,
    );
    const zio = io_mod.getIo();
    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    defer session.durable.release_completed_handles();
    var page = try session.durable.read(
        session.alloc,
        request.cursor,
        max_read_bytes,
    );
    defer page.deinit(session.alloc);
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .read = .{
            .session = session.factsLocked(authorization),
            .output = page.output,
            .raw_range = page.range,
        } } },
    ) catch return error.OutOfMemory;
}

fn writeAction(
    session: *Session,
    request: contracts.WriteRequest,
    cancelled: *const std.atomic.Value(bool),
) !contracts.OwnedResult {
    const zio = io_mod.getIo();
    session.write_mutex.lockUncancelable(zio);
    defer session.write_mutex.unlock(zio);
    if (cancelled.load(.acquire)) return error.Cancelled;
    if (request.lease == .use) {
        signalTestBarrier("FX_TERMINAL_TEST_WRITE_BARRIER_PATH");
        maybeDelayForTest("FX_TERMINAL_TEST_WRITE_DELAY_MS");
    }

    const authorization = switch (request.lease) {
        .acquire => try session.durable.acquire_write_lease(
            request.authority.?,
            io_mod.milliTimestamp(),
        ),
        .release => try session.durable.release_write_lease(
            request.authority.?,
            io_mod.milliTimestamp(),
        ),
        .use => try session.durable.authorize_write(request.authority.?),
        .revoke => blk: {
            const claim = request.authority.?;
            const auth = try session.durable.authorize(claim, .close);
            try session.durable.revoke_claim(
                claim,
                io_mod.milliTimestamp(),
            );
            session.mutex.lockUncancelable(zio);
            session.input_quiesced = true;
            session.mutex.unlock(zio);
            break :blk auth;
        },
    };

    if (request.lease == .acquire or
        request.lease == .release or
        request.lease == .revoke)
    {
        session.mutex.lockUncancelable(zio);
        defer session.mutex.unlock(zio);
        var facts = session.durable.facts();
        facts.next_actions = if (request.lease == .revoke)
            .{}
        else
            contracts.project_next_actions(
                session.lifecycle,
                authorization.controls,
                authorization.actor,
                facts.attention,
            );
        return contracts.OwnedResult.init(
            session.alloc,
            .{ .success = .{ .write = .{
                .session = facts,
                .accepted_bytes = 0,
            } } },
        ) catch return error.OutOfMemory;
    }

    var encoded = try encodeWritePayload(session.alloc, request.payload.?);
    defer encoded.deinit(session.alloc);
    session.mutex.lockUncancelable(zio);
    const running = session.lifecycle == .running;
    const master_fd = if (session.input_quiesced) null else session.master_fd;
    const tmux_ready = !session.input_quiesced and session.tmux_backend != null;
    session.mutex.unlock(zio);
    if (!running or (master_fd == null and !tmux_ready)) {
        return error.InvalidLifecycle;
    }

    if (session.tmux_backend) |*backend| {
        const paste = switch (request.payload.?) {
            .paste => true,
            .text, .keys, .controls => false,
        };
        try backend.write(encoded.items, paste);
    } else {
        try writeAllFd(master_fd.?, encoded.items, true);
    }

    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .write = .{
            .session = session.factsLocked(authorization),
            .accepted_bytes = @intCast(encoded.items.len),
        } } },
    ) catch return error.OutOfMemory;
}

fn inspectAction(
    session: *Session,
    request: contracts.SessionRequest,
) !contracts.OwnedResult {
    const authorization = try session.durable.authorize(
        request.authority.?,
        .inspect,
    );
    var events = try projectMonitorEvents(session.alloc, &session.durable, request);
    defer events.deinit();
    const zio = io_mod.getIo();
    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    const owner = session.monitor_owner orelse return error.InvalidMonitorState;
    owner.mutex.lockUncancelable(zio);
    defer owner.mutex.unlock(zio);
    const monitors = try session.alloc.alloc(
        contracts.MonitorSummary,
        owner.set.parsed.value.monitors.len,
    );
    defer session.alloc.free(monitors);
    for (owner.set.parsed.value.monitors, 0..) |monitor, index| {
        monitors[index] = .{
            .monitor_id = monitor.monitor_id,
            .state = monitor.runtime.state,
        };
    }
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .inspect = .{
            .session = session.factsLocked(authorization),
            .shell = session.shell,
            .cwd = session.cwd,
            .command = session.command,
            .monitors = monitors,
            .events = events.items,
            .event_gap_through = events.gap_through,
            .next_event_id = events.next_event_id,
        } } },
    ) catch return error.OutOfMemory;
}

const ProjectedMonitorEvents = struct {
    alloc: Allocator,
    items: []contracts.MonitorEvent,
    gap_through: u64,
    next_event_id: u64,

    fn deinit(self: *ProjectedMonitorEvents) void {
        for (self.items) |event| self.alloc.free(event.monitor_id);
        self.alloc.free(self.items);
        self.* = undefined;
    }
};

fn projectMonitorEvents(
    alloc: Allocator,
    durable: *terminal_store.DurableSession,
    request: contracts.SessionRequest,
) !ProjectedMonitorEvents {
    if (request.acknowledge_event_id) |event_id| {
        try durable.acknowledge(event_id, io_mod.milliTimestamp());
    }
    var replay = try durable.replay_events(
        alloc,
        request.after_event_id,
        request.max_events,
    );
    defer replay.deinit(alloc);
    var projected: std.ArrayList(contracts.MonitorEvent) = .empty;
    errdefer {
        for (projected.items) |event| alloc.free(event.monitor_id);
        projected.deinit(alloc);
    }
    for (replay.events) |event| {
        const sequence = event.monitor_sequence orelse continue;
        var buffer: [64]u8 = undefined;
        const monitor_id = try monitor_core.stable_id(&buffer, sequence);
        try projected.append(alloc, .{
            .event_id = event.id,
            .monitor_id = try alloc.dupe(u8, monitor_id),
            .reason = event.monitor_reason.?,
            .lifecycle = event.lifecycle,
            .cursor = event.cursor,
            .created_at_ms = event.created_at_ms,
        });
    }
    return .{
        .alloc = alloc,
        .items = try projected.toOwnedSlice(alloc),
        .gap_through = replay.gap_through,
        .next_event_id = replay.next_event_id,
    };
}

fn resizeAction(
    session: *Session,
    request: contracts.ResizeRequest,
) !contracts.OwnedResult {
    const zio = io_mod.getIo();
    session.write_mutex.lockUncancelable(zio);
    defer session.write_mutex.unlock(zio);
    const authorization = try session.durable.authorize(
        request.authority.?,
        .resize,
    );
    const screen_evaluation_required = if (session.monitor_owner) |owner|
        owner.screenEvaluationRequired()
    else
        false;
    var screen_text: std.ArrayList(u8) = .empty;
    defer screen_text.deinit(session.alloc);
    session.mutex.lockUncancelable(zio);
    const fd = session.master_fd;
    const tmux_ready = session.tmux_backend != null;
    const valid = session.lifecycle == .starting or session.lifecycle == .running;
    if (!valid or (fd == null and !tmux_ready)) {
        session.mutex.unlock(zio);
        return error.InvalidLifecycle;
    }
    if (!session.screen_available) {
        session.mutex.unlock(zio);
        return error.ScreenCorrupt;
    }
    const previous_dimensions = session.dimensions;
    const now_ms = io_mod.milliTimestamp();
    session.durable.check_resize_capacity(request.dimensions) catch |err| {
        session.mutex.unlock(zio);
        return err;
    };
    const previous_payload = session.engine.checkpointPayload(session.alloc) catch |err| {
        session.mutex.unlock(zio);
        return err;
    };
    defer session.alloc.free(previous_payload);
    var resized_engine = terminal_engine.Grid.restoreCheckpoint(
        session.alloc,
        previous_payload,
    ) catch |err| {
        session.mutex.unlock(zio);
        return err;
    };
    var resized_engine_owned = true;
    defer if (resized_engine_owned) resized_engine.deinit();
    resized_engine.resize(
        request.dimensions.columns,
        request.dimensions.rows,
    ) catch |err| {
        session.mutex.unlock(zio);
        return err;
    };
    if (screen_evaluation_required) {
        if (monitorScreenProjectionAllocationFailure()) {
            session.mutex.unlock(zio);
            return error.InjectedFailure;
        }
        session.appendScreenTextLocked(&resized_engine, &screen_text) catch |err| {
            session.mutex.unlock(zio);
            return err;
        };
    }
    session.durable.resize(request.dimensions, now_ms) catch |err| {
        session.mutex.unlock(zio);
        return err;
    };
    session.engine.deinit();
    session.engine = resized_engine;
    resized_engine_owned = false;
    session.dimensions = request.dimensions;
    session.mutex.unlock(zio);
    if (session.tmux_backend) |*backend| {
        backend.resize(request.dimensions) catch |err| {
            rollbackTmuxResize(
                session,
                previous_dimensions,
                previous_payload,
            );
            return err;
        };
    } else {
        resizeFd(fd.?, request.dimensions) catch |err| {
            rollbackDurableResize(
                session,
                fd.?,
                previous_dimensions,
                previous_payload,
            );
            return err;
        };
        if (!session.signalNative(std.c.SIG.WINCH)) {
            rollbackDurableResize(
                session,
                fd.?,
                previous_dimensions,
                previous_payload,
            );
            return error.ProcessIdentityUnavailable;
        }
    }
    if (session.tmux_backend != null and tmuxResizeCheckpointFailure()) {
        rollbackTmuxResize(
            session,
            previous_dimensions,
            previous_payload,
        );
        return error.InjectedFailure;
    }
    session.mutex.lockUncancelable(zio);
    session.checkpointLocked(session.durable.output_cursor(), now_ms) catch |err| {
        session.mutex.unlock(zio);
        if (session.tmux_backend != null) {
            rollbackTmuxResize(
                session,
                previous_dimensions,
                previous_payload,
            );
        } else {
            rollbackDurableResize(
                session,
                fd.?,
                previous_dimensions,
                previous_payload,
            );
        }
        return err;
    };
    session.mutex.unlock(zio);
    if (screen_evaluation_required) if (session.monitor_owner) |owner| {
        owner.onScreen(screen_text.items, now_ms);
    };
    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .resize = .{
            .session = session.factsLocked(authorization),
            .dimensions = request.dimensions,
        } } },
    ) catch return error.OutOfMemory;
}

fn tmuxResizeCheckpointFailure() bool {
    const value = io_mod.getenv(
        "FX_TERMINAL_TEST_TMUX_RESIZE_CHECKPOINT_FAILURE",
    ) orelse return false;
    return std.mem.eql(u8, value, "allocation") or
        std.mem.eql(u8, value, "storage") or
        std.mem.eql(u8, value, "checkpoint");
}

fn tmuxRecoveryFailure(session_id: []const u8, point: []const u8) bool {
    const value = io_mod.getenv(
        "FX_TERMINAL_TEST_TMUX_RECOVERY_FAILURE",
    ) orelse return false;
    if (!std.mem.eql(u8, value, point)) return false;
    const selected_session = io_mod.getenv(
        "FX_TERMINAL_TEST_TMUX_RECOVERY_SESSION_ID",
    ) orelse return true;
    return std.mem.eql(u8, selected_session, session_id);
}

fn rollbackDurableResize(
    session: *Session,
    fd: std.posix.fd_t,
    dimensions: contracts.Dimensions,
    checkpoint_payload: []const u8,
) void {
    resizeFd(fd, dimensions) catch |err| {
        const zio = io_mod.getIo();
        session.mutex.lockUncancelable(zio);
        session.screen_available = false;
        session.mutex.unlock(zio);
        debug_trace.logf(
            "terminal_host",
            "terminal resize rollback failed id={s} err={s}",
            .{ session.id, @errorName(err) },
        );
        return;
    };
    if (!session.signalNative(std.c.SIG.WINCH)) {
        const zio = io_mod.getIo();
        session.mutex.lockUncancelable(zio);
        session.screen_available = false;
        session.mutex.unlock(zio);
        debug_trace.logf(
            "terminal_host",
            "terminal resize rollback signal failed id={s}",
            .{session.id},
        );
        return;
    }
    restoreDurableResize(session, dimensions, checkpoint_payload);
}

fn rollbackTmuxResize(
    session: *Session,
    dimensions: contracts.Dimensions,
    checkpoint_payload: []const u8,
) void {
    const backend = if (session.tmux_backend) |*value| value else return;
    backend.resize(dimensions) catch |err| {
        const zio = io_mod.getIo();
        session.mutex.lockUncancelable(zio);
        session.screen_available = false;
        session.mutex.unlock(zio);
        debug_trace.logf(
            "terminal_host",
            "tmux resize rollback failed id={s} err={s}",
            .{ session.id, @errorName(err) },
        );
        return;
    };
    restoreDurableResize(session, dimensions, checkpoint_payload);
}

fn restoreDurableResize(
    session: *Session,
    dimensions: contracts.Dimensions,
    checkpoint_payload: []const u8,
) void {
    var restored = terminal_engine.Grid.restoreCheckpoint(
        session.alloc,
        checkpoint_payload,
    ) catch |err| {
        const zio = io_mod.getIo();
        session.mutex.lockUncancelable(zio);
        session.screen_available = false;
        session.mutex.unlock(zio);
        debug_trace.logf(
            "terminal_host",
            "screen resize rollback failed id={s} err={s}",
            .{ session.id, @errorName(err) },
        );
        return;
    };
    var restored_owned = true;
    defer if (restored_owned) restored.deinit();
    const zio = io_mod.getIo();
    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    session.durable.resize(dimensions, io_mod.milliTimestamp()) catch |err| {
        session.screen_available = false;
        debug_trace.logf(
            "terminal_host",
            "durable resize rollback failed id={s} err={s}",
            .{ session.id, @errorName(err) },
        );
        return;
    };
    session.engine.deinit();
    session.engine = restored;
    restored_owned = false;
    session.dimensions = dimensions;
    session.screen_available = true;
    session.checkpointLocked(
        session.durable.output_cursor(),
        io_mod.milliTimestamp(),
    ) catch |err| debug_trace.logf(
        "terminal_host",
        "screen resize rollback checkpoint failed id={s} err={s}",
        .{ session.id, @errorName(err) },
    );
}

fn signalAction(
    session: *Session,
    request: contracts.SignalRequest,
) !contracts.OwnedResult {
    const zio = io_mod.getIo();
    session.write_mutex.lockUncancelable(zio);
    defer session.write_mutex.unlock(zio);
    const authorization = try session.durable.authorize(
        request.authority.?,
        .signal,
    );
    if (!(try session.signalTerminalProcesses(request.signal) orelse false)) {
        return error.ProcessIdentityUnavailable;
    }
    session.mutex.lockUncancelable(zio);
    defer session.mutex.unlock(zio);
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .signal = .{
            .session = session.factsLocked(authorization),
            .signal = request.signal,
        } } },
    ) catch return error.OutOfMemory;
}

fn terminalSignalCompleted(
    descendants: process_tree.DeliverySummary,
    shell_group_delivered: bool,
) bool {
    return !descendants.incomplete and shell_group_delivered;
}

fn failSignalStageForTest(stage: []const u8) bool {
    const requested = io_mod.getenv("FX_TERMINAL_TEST_FAIL_SIGNAL_STAGE") orelse
        return false;
    return std.mem.eql(u8, requested, stage);
}

fn forceCloseSignalIncomplete(tree_complete: ?bool) bool {
    return tree_complete == null or !tree_complete.?;
}

fn closeAction(
    session: *Session,
    request: contracts.CloseRequest,
) !contracts.OwnedResult {
    const zio = io_mod.getIo();
    session.write_mutex.lockUncancelable(zio);
    const owner = session.monitor_owner orelse {
        session.write_mutex.unlock(zio);
        return error.InvalidMonitorState;
    };
    owner.mutex.lockUncancelable(zio);
    const close_started_at = io_mod.milliTimestamp();
    requireCloseCandidate(
        session.id,
        session.durable.begin_close(request.authority.?, close_started_at),
    ) catch |err| {
        owner.mutex.unlock(zio);
        session.write_mutex.unlock(zio);
        return err;
    };
    if (session.durable.record.backend == .tmux and
        io_mod.getenv("FX_TERMINAL_TEST_INTERRUPT_CLOSE_AFTER_COMMIT") != null)
    {
        owner.mutex.unlock(zio);
        session.write_mutex.unlock(zio);
        return error.InjectedTmuxCloseInterruption;
    }
    session.mutex.lockUncancelable(zio);
    session.input_quiesced = true;
    session.close_committed = true;
    session.mutex.unlock(zio);
    owner.stopping.store(true, .release);
    owner.mutex.unlock(zio);
    session.write_mutex.unlock(zio);
    owner.stop();

    session.mutex.lockUncancelable(zio);
    var still_live = session.lifecycle == .starting or
        session.lifecycle == .running;
    session.mutex.unlock(zio);
    var force_signal_attempted = false;
    var force_tree_complete: ?bool = null;
    if (still_live) {
        const delivered = if (request.policy == .force) blk: {
            const tree_complete = session.signalTerminalProcesses(.kill) catch |err| {
                force_signal_attempted = true;
                debug_trace.logf(
                    "terminal_host",
                    "force close tree signal failed id={s} err={s}; falling back to shell group",
                    .{ session.id, @errorName(err) },
                );
                break :blk session.signalProcess(.kill);
            };
            if (tree_complete) |complete| {
                force_signal_attempted = true;
                force_tree_complete = complete;
                break :blk complete;
            }
            break :blk false;
        } else session.signalProcess(.terminate);
        if (!delivered) session.markLost();
    }
    if (request.policy == .graceful and still_live) {
        const started = io_mod.milliTimestamp();
        while (io_mod.milliTimestamp() - started < graceful_close_ms) {
            session.mutex.lockUncancelable(zio);
            const done = session.lifecycle != .starting and
                session.lifecycle != .running;
            session.mutex.unlock(zio);
            if (done) break;
            io_mod.sleep(wait_poll_ns);
        }
        session.mutex.lockUncancelable(zio);
        still_live = session.lifecycle == .starting or
            session.lifecycle == .running;
        session.mutex.unlock(zio);
        if (still_live and !session.signalProcess(.kill)) session.markLost();
    }

    if (still_live) {
        const started = io_mod.milliTimestamp();
        while (io_mod.milliTimestamp() - started < graceful_close_ms) {
            session.mutex.lockUncancelable(zio);
            still_live = session.lifecycle == .starting or
                session.lifecycle == .running;
            session.mutex.unlock(zio);
            if (!still_live) break;
            io_mod.sleep(wait_poll_ns);
        }
        if (still_live) session.markLost();
    }

    session.mutex.lockUncancelable(zio);
    session.lifecycle = .closed;
    session.mutex.unlock(zio);
    session.finalizeBackend();
    if (session.tmux_backend) |*backend| {
        try backend.cleanupChecked(session.durable.profile.process_provider);
    }
    try session.durable.finish_close(io_mod.milliTimestamp());
    if (force_signal_attempted and forceCloseSignalIncomplete(force_tree_complete)) {
        return contracts.OwnedResult.init(
            session.alloc,
            .{ .failure = .{
                .action = .close,
                .code = .session_lost,
                .session_id = session.id,
            } },
        ) catch return error.OutOfMemory;
    }
    var facts = session.durable.facts();
    facts.next_actions = .{};
    return contracts.OwnedResult.init(
        session.alloc,
        .{ .success = .{ .close = .{
            .session = facts,
            .policy = request.policy,
        } } },
    ) catch return error.OutOfMemory;
}

const Pty = struct {
    master: std.posix.fd_t,
    slave: std.posix.fd_t,
};

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]u8;
extern "c" fn tcsetpgrp(fd: c_int, pgrp: std.c.pid_t) c_int;

fn openPty() !Pty {
    if (!isSupported()) return error.TerminalHostUnsupported;
    const master_flags = std.posix.O{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
        .NONBLOCK = true,
    };
    const master = posix_openpt(@bitCast(master_flags));
    if (master < 0) return error.PtyUnavailable;
    errdefer closeFd(master);
    if (grantpt(master) != 0 or unlockpt(master) != 0) {
        return error.PtyUnavailable;
    }
    const slave_name = ptsname(master) orelse return error.PtyUnavailable;
    const slave = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        slave_name,
        .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .CLOEXEC = true,
        },
        0,
    );
    return .{ .master = master, .slave = slave };
}

test "PTY output drains use a nonblocking master" {
    if (comptime !isSupported()) return;
    const pty = try openPty();
    defer closeFd(pty.master);
    defer closeFd(pty.slave);

    const result = std.posix.system.fcntl(
        pty.master,
        std.posix.F.GETFL,
        @as(usize, 0),
    );
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(result));
    const flags: usize = @intCast(result);
    const nonblocking = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    try std.testing.expect(flags & nonblocking != 0);
}

fn resizeFd(fd: std.posix.fd_t, dimensions: contracts.Dimensions) !void {
    var size = std.posix.winsize{
        .row = dimensions.rows,
        .col = dimensions.columns,
        .xpixel = 0,
        .ypixel = 0,
    };
    if (std.c.ioctl(
        fd,
        ioctl_set_window_size,
        &size,
    ) < 0) return error.ResizeFailed;
}

fn setEcho(fd: std.posix.fd_t, enabled: bool) !void {
    var termios = try std.posix.tcgetattr(fd);
    termios.lflag.ECHO = enabled;
    try std.posix.tcsetattr(fd, .NOW, termios);
}

fn closeFd(fd: std.posix.fd_t) void {
    (std.Io.File{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    }).close(io_mod.getIo());
}

fn readExactFd(fd: std.posix.fd_t, destination: []u8) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const count = try std.posix.read(fd, destination[offset..]);
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

fn receiveSocketExact(
    socket: std.Io.net.Socket,
    destination: []u8,
    timeout_ms: i64,
) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        const incoming = try socket.receiveTimeout(
            io_mod.getIo(),
            destination[offset..],
            .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(timeout_ms),
            } },
        );
        if (incoming.data.len == 0) return error.EndOfStream;
        offset += incoming.data.len;
    }
}

fn writeAllFd(
    fd: std.posix.fd_t,
    bytes: []const u8,
    nonblocking: bool,
) !void {
    const file = std.Io.File{
        .handle = fd,
        .flags = .{ .nonblocking = nonblocking },
    };
    try file.writeStreamingAll(io_mod.getIo(), bytes);
}

const ControlFrame = struct {
    kind: ControlKind,
    value: u32,
};

fn tmuxLifecycleTerminal(kind: tmux_session.LifecycleKind) bool {
    return switch (kind) {
        .command_exited,
        .command_signal,
        .startup_failed,
        .invalid_term,
        => true,
        .prepared, .shell_ready, .command_started => false,
    };
}

fn tmuxTerminalFrame(
    frames: []const tmux_session.LifecycleFrame,
) ?tmux_session.LifecycleFrame {
    for (frames) |frame| if (tmuxLifecycleTerminal(frame.kind)) return frame;
    return null;
}

fn tmuxShellPid(
    frames: []const tmux_session.LifecycleFrame,
) ?u32 {
    for (frames) |frame| switch (frame.kind) {
        .shell_ready => return frame.value,
        .prepared,
        .command_started,
        .command_exited,
        .command_signal,
        .startup_failed,
        .invalid_term,
        => {},
    };
    return null;
}

fn tmuxStartupFrameCount(frames: []const tmux_session.LifecycleFrame) usize {
    for (frames, 0..) |frame, index| {
        if (tmuxLifecycleTerminal(frame.kind)) return index;
    }
    return frames.len;
}

fn writeControlFd(fd: std.posix.fd_t, kind: ControlKind, value: u32) !void {
    var bytes: [control_frame_len]u8 = undefined;
    bytes[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, bytes[1..5], value, .little);
    try writeAllFd(fd, &bytes, false);
}

fn readControlFile(file: std.Io.File) !ControlFrame {
    var bytes: [control_frame_len]u8 = undefined;
    try readExactFd(file.handle, &bytes);
    return .{
        .kind = switch (bytes[0]) {
            1 => .prepared,
            2 => .shell_ready,
            3 => .command_started,
            4 => .command_exited,
            5 => .command_signal,
            6 => .startup_failed,
            7 => .invalid_term,
            else => return error.InvalidControlFrame,
        },
        .value = std.mem.readInt(u32, bytes[1..5], .little),
    };
}

fn outputMain(session: *Session) void {
    defer {
        session.output_active.store(false, .release);
        if (session.command_boundary_requested.swap(false, .acq_rel)) {
            session.command_boundary_done.set(io_mod.getIo());
        }
        session.output_done.set(io_mod.getIo());
    }
    var buffer: [256 * 1024]u8 = undefined;
    const fd = session.master_fd orelse if (session.tmux_capture) |stream|
        stream.socket.handle
    else
        return;
    while (true) {
        if (session.command_boundary_requested.load(.acquire)) {
            while (readOutputChunk(session, fd, &buffer, 0) catch return) {}
            session.commitStartupBoundary();
            session.command_boundary_requested.store(false, .release);
            session.command_boundary_done.set(io_mod.getIo());
            continue;
        }
        _ = readOutputChunk(
            session,
            fd,
            &buffer,
            control_poll_ms,
        ) catch break;
    }
}

fn tmuxControlMain(session: *Session) void {
    defer {
        session.backend_done.set(io_mod.getIo());
        session.markNotLive();
    }
    var terminal_seen = false;
    while (!terminal_seen and !session.backend_detaching.load(.acquire)) {
        const backend = if (session.tmux_backend) |*value| value else {
            session.markLost();
            break;
        };
        const frames = backend.lifecycle() catch |err| {
            debug_trace.logf(
                "terminal_host",
                "tmux lifecycle read deferred id={s} err={s}",
                .{ session.id, @errorName(err) },
            );
            io_mod.sleep(wait_poll_ns);
            continue;
        };
        defer session.alloc.free(frames);
        if (session.tmux_lifecycle_index > frames.len) {
            session.markLost();
            break;
        }
        while (session.tmux_lifecycle_index < frames.len) {
            const frame = frames[session.tmux_lifecycle_index];
            session.tmux_lifecycle_index += 1;
            const control = ControlFrame{
                .kind = switch (frame.kind) {
                    .prepared => .prepared,
                    .shell_ready => .shell_ready,
                    .command_started => .command_started,
                    .command_exited => .command_exited,
                    .command_signal => .command_signal,
                    .startup_failed => .startup_failed,
                    .invalid_term => .invalid_term,
                },
                .value = frame.value,
            };
            terminal_seen = switch (control.kind) {
                .command_exited,
                .command_signal,
                .startup_failed,
                .invalid_term,
                => true,
                .prepared, .shell_ready, .command_started => false,
            };
            if (terminal_seen) {
                backend.stopCapture();
                if (session.tmux_capture) |stream| {
                    stream.close(io_mod.getIo());
                    session.tmux_capture = null;
                }
                session.output_done.waitUncancelable(io_mod.getIo());
            }
            if (control.kind == .shell_ready) {
                maybeDelayForTest(
                    "FX_TERMINAL_TEST_TMUX_SHELL_READY_HOST_DELAY_MS",
                );
            }
            session.handleControl(control);
            if (terminal_seen) break;
        }
        if (!terminal_seen) io_mod.sleep(wait_poll_ns);
    }

    if (session.tmux_backend) |*backend| backend.stopCapture();
    session.output_done.waitUncancelable(io_mod.getIo());
    if (session.output_thread) |thread| {
        thread.join();
        session.output_thread = null;
    }
    maybeDelayForTest("FX_TERMINAL_TEST_BACKEND_CLEANUP_DELAY_MS");
    const zio = io_mod.getIo();
    session.write_mutex.lockUncancelable(zio);
    if (session.tmux_capture) |stream| stream.close(zio);
    session.tmux_capture = null;
    session.mutex.lockUncancelable(zio);
    const close_committed = session.close_committed;
    session.mutex.unlock(zio);
    if (!close_committed and !session.backend_detaching.load(.acquire)) {
        if (session.tmux_backend) |*backend| backend.killSession();
    }
    session.write_mutex.unlock(zio);
}

fn controlMain(session: *Session) void {
    defer {
        session.backend_done.set(io_mod.getIo());
        session.markNotLive();
    }
    const control = session.control_file orelse return;
    while (true) {
        const frame = readControlFile(control) catch {
            const zio = io_mod.getIo();
            session.mutex.lockUncancelable(zio);
            const reported = session.term != null or
                session.start_failure != null;
            session.mutex.unlock(zio);
            if (!reported) session.markLost();
            break;
        };
        switch (frame.kind) {
            .command_exited,
            .command_signal,
            .startup_failed,
            .invalid_term,
            => {
                session.output_done.waitUncancelable(io_mod.getIo());
            },
            .prepared, .shell_ready, .command_started => {},
        }
        session.handleControl(frame);
    }
    if (session.launcher) |*child| {
        const term = child.wait(io_mod.getIo()) catch blk: {
            session.markLost();
            break :blk null;
        };
        const zio = io_mod.getIo();
        session.mutex.lockUncancelable(zio);
        const reported = session.term != null or session.lifecycle == .lost;
        session.mutex.unlock(zio);
        if (!reported and term != null) {
            switch (term.?) {
                .exited => |code| if (code != 0) session.markLost(),
                .signal, .stopped, .unknown => session.markLost(),
            }
        }
    }

    session.output_done.waitUncancelable(io_mod.getIo());
    if (session.output_thread) |thread| {
        thread.join();
        session.output_thread = null;
    }

    maybeDelayForTest("FX_TERMINAL_TEST_BACKEND_CLEANUP_DELAY_MS");

    const zio = io_mod.getIo();
    session.write_mutex.lockUncancelable(zio);
    session.mutex.lockUncancelable(zio);
    const master_fd = session.master_fd;
    const control_file = session.control_file;
    const liveness_file = session.liveness_file;
    session.master_fd = null;
    session.control_file = null;
    session.liveness_file = null;
    session.launcher = null;
    session.mutex.unlock(zio);
    if (master_fd) |fd| closeFd(fd);
    if (control_file) |file| file.close(zio);
    if (liveness_file) |file| file.close(zio);
    session.write_mutex.unlock(zio);
}

fn readOutputChunk(
    session: *Session,
    fd: std.posix.fd_t,
    buffer: []u8,
    timeout_ms: i32,
) !bool {
    var total: usize = 0;
    var poll_timeout = timeout_ms;
    while (total < buffer.len) {
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = try std.posix.poll(&poll_fds, poll_timeout);
        const revents = poll_fds[0].revents;
        if (revents == 0) break;
        if (revents & std.posix.POLL.IN == 0) {
            if (total == 0) return error.EndOfStream;
            break;
        }
        const count = std.posix.read(fd, buffer[total..]) catch |err| {
            if (err == error.WouldBlock) break;
            if (total != 0) break;
            return err;
        };
        if (count == 0) {
            if (total == 0) return error.EndOfStream;
            break;
        }
        total += count;
        poll_timeout = 1;
    }
    if (total == 0) return false;
    session.appendOutput(buffer[0..total]);
    return true;
}

fn maybeDelayForTest(name: []const u8) void {
    const value = io_mod.getenv(name) orelse return;
    const delay_ms = std.fmt.parseInt(u64, value, 10) catch return;
    const bounded_ms = @min(delay_ms, 5_000);
    const delay_ns = std.math.mul(
        u64,
        bounded_ms,
        std.time.ns_per_ms,
    ) catch return;
    io_mod.sleep(delay_ns);
}

fn signalTestBarrier(name: []const u8) void {
    const path = io_mod.getenv(name) orelse return;
    var file = std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        path,
        .{ .truncate = true },
    ) catch return;
    file.close(io_mod.getIo());
}

fn outcomeFromTerm(term: std.process.Child.Term) ?contracts.ReturnOutcome {
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |signal| .{ .signal = @intFromEnum(signal) },
        .stopped, .unknown => null,
    };
}

fn returnOutcomeIsTerminal(outcome: contracts.ReturnOutcome) bool {
    return switch (outcome) {
        .exited, .signal => true,
        .started,
        .condition_met,
        .safety_ceiling,
        .cancelled,
        => false,
    };
}

fn launchFailureCode(err: anyerror) contracts.StructuredErrorCode {
    return switch (err) {
        error.MissingLoginShell => .shell_unavailable,
        error.PtyUnavailable,
        error.ResizeFailed,
        error.TerminalHostUnsupported,
        error.LauncherNotPrepared,
        error.TmuxUnavailable,
        => .pty_unavailable,
        error.TmuxIncompatible => .protocol_incompatible,
        error.RelativeShellPath,
        error.UnsupportedShell,
        error.LauncherConfigTooLarge,
        => .invalid_request,
        else => .startup_failed,
    };
}

fn signalValue(signal: contracts.Signal) std.c.SIG {
    return switch (signal) {
        .hangup => std.c.SIG.HUP,
        .interrupt => std.c.SIG.INT,
        .quit => std.c.SIG.QUIT,
        .terminate => std.c.SIG.TERM,
        .kill => std.c.SIG.KILL,
    };
}

fn signalFromInt(value: u32) ?std.posix.SIG {
    if (value == 0 or value > 255) return null;
    return @enumFromInt(value);
}

fn projectedFacts(
    facts: contracts.SessionFacts,
    authorization: terminal_store.Authorization,
) contracts.SessionFacts {
    var projected = facts;
    projected.next_actions = contracts.project_next_actions(
        facts.lifecycle,
        authorization.controls,
        authorization.actor,
        facts.attention,
    );
    return projected;
}

fn encodeWritePayload(
    alloc: Allocator,
    payload: contracts.WritePayload,
) Allocator.Error!std.ArrayList(u8) {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    switch (payload) {
        .text, .paste => |bytes| try result.appendSlice(alloc, bytes),
        .keys => |keys| for (keys) |key| {
            try result.appendSlice(alloc, keySequence(key));
        },
        .controls => |controls| for (controls) |control| {
            const byte = if (control.character == '?')
                @as(u8, 0x7f)
            else
                std.ascii.toUpper(control.character) & 0x1f;
            try result.append(alloc, byte);
        },
    }
    return result;
}

fn keySequence(key: contracts.NamedKey) []const u8 {
    return switch (key) {
        .enter => "\r",
        .tab => "\t",
        .escape => "\x1b",
        .backspace => "\x7f",
        .delete => "\x1b[3~",
        .insert => "\x1b[2~",
        .arrow_up => "\x1b[A",
        .arrow_down => "\x1b[B",
        .arrow_left => "\x1b[D",
        .arrow_right => "\x1b[C",
        .home => "\x1b[H",
        .end => "\x1b[F",
        .page_up => "\x1b[5~",
        .page_down => "\x1b[6~",
    };
}

test "write payload encoding preserves text paste keys and controls" {
    const alloc = std.testing.allocator;
    var text = try encodeWritePayload(alloc, .{ .text = "a\x00b" });
    defer text.deinit(alloc);
    try std.testing.expectEqualSlices(u8, "a\x00b", text.items);

    var paste = try encodeWritePayload(alloc, .{ .paste = "\xff\n" });
    defer paste.deinit(alloc);
    try std.testing.expectEqualSlices(u8, "\xff\n", paste.items);

    var keys = try encodeWritePayload(
        alloc,
        .{ .keys = &.{
            .enter,
            .tab,
            .escape,
            .backspace,
            .delete,
            .insert,
            .arrow_up,
            .arrow_down,
            .arrow_left,
            .arrow_right,
            .home,
            .end,
            .page_up,
            .page_down,
        } },
    );
    defer keys.deinit(alloc);
    try std.testing.expectEqualSlices(
        u8,
        "\r\t\x1b\x7f\x1b[3~\x1b[2~\x1b[A\x1b[B\x1b[D\x1b[C\x1b[H\x1b[F\x1b[5~\x1b[6~",
        keys.items,
    );

    var controls = try encodeWritePayload(
        alloc,
        .{ .controls = &.{
            .{ .character = 'c' },
            .{ .character = '?' },
        } },
    );
    defer controls.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &.{ 3, 0x7f }, controls.items);
}

test "terminal outcomes preserve exact exit and signal status" {
    try std.testing.expectEqual(
        contracts.ReturnOutcome{ .exited = 23 },
        outcomeFromTerm(.{ .exited = 23 }).?,
    );
    try std.testing.expectEqual(
        contracts.ReturnOutcome{ .signal = @intFromEnum(std.posix.SIG.TERM) },
        outcomeFromTerm(.{ .signal = .TERM }).?,
    );
    try std.testing.expect(outcomeFromTerm(.{ .unknown = 1 }) == null);
    try std.testing.expect(outcomeFromTerm(.{ .stopped = .STOP }) == null);
    try std.testing.expectEqual(
        std.posix.SIG.SEGV,
        signalFromInt(@intFromEnum(std.posix.SIG.SEGV)).?,
    );
    try std.testing.expect(signalFromInt(0) == null);
    try std.testing.expect(signalFromInt(256) == null);
}

test "terminal signal completion requires checked descendants and shell group" {
    try std.testing.expect(terminalSignalCompleted(.{}, true));
    try std.testing.expect(!terminalSignalCompleted(.{
        .delivered = 1,
        .incomplete = true,
    }, true));
    try std.testing.expect(!terminalSignalCompleted(.{}, false));
}

test "force close fallback does not erase an incomplete tree operation" {
    try std.testing.expect(!forceCloseSignalIncomplete(true));
    try std.testing.expect(forceCloseSignalIncomplete(false));
    try std.testing.expect(forceCloseSignalIncomplete(null));
}

fn ignoreWorkUpdate(_: ?*anyopaque, _: bool) void {}

const WorkProbe = struct {
    live: isize = 0,
    updates: usize = 0,

    fn update(raw: ?*anyopaque, added: bool) void {
        const self: *WorkProbe = @ptrCast(@alignCast(raw.?));
        self.live += if (added) 1 else -1;
        self.updates += 1;
    }
};

const TestDurableFixture = struct {
    alloc: Allocator,
    tmp: std.testing.TmpDir,
    home: []u8,
    profile: terminal_store.ProfileStore,

    fn init(alloc: Allocator) !TestDurableFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
        errdefer alloc.free(home);
        var root = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(
            std.testing.io,
            ".",
            .{ .iterate = true, .follow_symlinks = false },
        ) };
        defer root.close();
        var fx = try io_mod.openOrCreateVerifiedPrivateDir(&root, ".fx");
        defer fx.close();
        var sessions = try io_mod.openOrCreateVerifiedPrivateDir(&fx, "sessions");
        defer sessions.close();
        var owner = try io_mod.openOrCreateVerifiedPrivateDir(
            &sessions,
            "terminal-test-owner",
        );
        owner.close();
        return .{
            .alloc = alloc,
            .tmp = tmp,
            .home = home,
            .profile = try terminal_store.ProfileStore.init(
                alloc,
                home,
                background_process_provider.process_supervisor_test_provider,
            ),
        };
    }

    fn deinit(self: *TestDurableFixture) void {
        self.profile.deinit();
        self.alloc.free(self.home);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn testPersistence(cwd: []const u8) contracts.StartPersistence {
    return .{
        .grant = .{
            .principal = .{
                .profile_user = "terminal-test",
                .durable_session_id = "terminal-test-owner",
                .workspace_root = cwd,
                .cwd = cwd,
                .transport_role = .interactive,
                .backend = .native,
            },
            .actor = .agent,
            .controls = .full(),
            .generation = .{ .value = 1 },
        },
        .proof = .{ .bytes = @splat(7) },
    };
}

fn outputOwnerTestDefinition(
    condition: contracts.MonitorCondition,
) contracts.MonitorDefinition {
    return .{
        .condition = condition,
        .check_schedule = if (condition.requires_polling())
            .{ .interval_ms = 25 }
        else
            null,
        .notify_schedule = .on_match,
        .lifetime = .until_session_end,
    };
}

test "monitor owner skips every output-irrelevant condition without allocating" {
    const alloc = std.testing.allocator;
    const conditions = [_]contracts.MonitorCondition{
        .process_exit,
        .{ .exit_code = 0 },
        .{ .signal = .terminate },
        .{ .tcp_ready = .{ .host = "127.0.0.1", .port = 3000 } },
        .{ .http_ready = "http://127.0.0.1/health" },
        .{ .path_exists = "/workspace/ready" },
        .{ .path_changed = "/workspace/output" },
        .{ .path_size = .{ .path = "/workspace/output", .minimum_bytes = 1 } },
        .{ .custom_probe = .{ .command = "true", .cwd = "/workspace" } },
        .{ .screen_matches = "ready" },
    };
    var id_buffers: [conditions.len][32]u8 = undefined;
    var monitors: [conditions.len]monitor_core.PersistedMonitor = undefined;
    for (conditions, 0..) |condition, index| {
        const definition = outputOwnerTestDefinition(condition);
        monitors[index] = .{
            .monitor_id = try monitor_core.stable_id(
                &id_buffers[index],
                @intCast(index + 1),
            ),
            .definition = definition,
            .runtime = try monitor_core.initial_runtime(definition, 1),
        };
    }
    var set = try terminal_store.MonitorSet.clone(alloc, .{
        .next_monitor_id = conditions.len + 1,
        .monitors = &monitors,
    });
    var session: Session = undefined;
    var counting = std.testing.FailingAllocator.init(alloc, .{});
    var owner = MonitorOwner{
        .alloc = counting.allocator(),
        .session = &session,
        .set = set,
    };
    set = undefined;
    defer owner.set.deinit();

    owner.onOutput("irrelevant", null, 10);

    try std.testing.expectEqual(@as(usize, 0), counting.alloc_index);
    try std.testing.expectEqual(@as(usize, 0), counting.allocations);
    try std.testing.expectEqual(@as(usize, 0), counting.deallocations);
    try std.testing.expect(!counting.has_induced_failure);
}

test "monitor owner relevant output is allocation and persistence atomic" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        condition: contracts.MonitorCondition,
        bytes: []const u8,
        screen_text: ?[]const u8,
    }{
        .{ .condition = .{ .output_contains = "ready" }, .bytes = "re", .screen_text = null },
        .{ .condition = .{ .output_matches = "re*dy" }, .bytes = "ready", .screen_text = null },
        .{ .condition = .{ .output_quiet_ms = 50 }, .bytes = "noise", .screen_text = null },
        .{ .condition = .{ .screen_matches = "*ready*" }, .bytes = "screen", .screen_text = "ready" },
    };

    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    for (cases, 0..) |case, index| {
        const session_id = try std.fmt.allocPrint(
            alloc,
            "terminal-output-owner-{d}",
            .{index},
        );
        defer alloc.free(session_id);
        const owned_id = try alloc.dupe(u8, session_id);
        var owned_id_owned = true;
        errdefer if (owned_id_owned) alloc.free(owned_id);
        const definition = outputOwnerTestDefinition(case.condition);
        var session = try Session.init(
            alloc,
            .{ .context = null, .update_fn = ignoreWorkUpdate },
            &fixture.profile,
            "test-host",
            owned_id,
            .{
                .cwd = "/workspace",
                .shell = .{ .executable = .{ .path = "/bin/zsh" } },
                .initial_monitors = &.{definition},
            },
            testPersistence("/workspace"),
        );
        owned_id_owned = false;
        defer session.deinitUnlaunched();
        try session.initMonitorOwner();
        const owner = session.monitor_owner.?;
        const initial_runtime = owner.set.parsed.value.monitors[0].runtime;

        var failing = std.testing.FailingAllocator.init(alloc, .{
            .fail_index = 0,
        });
        owner.alloc = failing.allocator();
        owner.onOutput(case.bytes, case.screen_text, 10);
        owner.alloc = alloc;
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expect(std.meta.eql(
            initial_runtime,
            owner.set.parsed.value.monitors[0].runtime,
        ));

        fixture.profile.options.fail_at = .after_monitor_transaction_prepare;
        owner.onOutput(case.bytes, case.screen_text, 20);
        fixture.profile.options.fail_at = null;
        try std.testing.expect(std.meta.eql(
            initial_runtime,
            owner.set.parsed.value.monitors[0].runtime,
        ));
        var durable_after_failure = try session.durable.load_monitor_set(alloc);
        defer durable_after_failure.deinit();
        try std.testing.expect(std.meta.eql(
            initial_runtime,
            durable_after_failure.parsed.value.monitors[0].runtime,
        ));

        owner.onOutput(case.bytes, case.screen_text, 30);
        try std.testing.expect(!std.meta.eql(
            initial_runtime,
            owner.set.parsed.value.monitors[0].runtime,
        ));
        var durable_after_success = try session.durable.load_monitor_set(alloc);
        defer durable_after_success.deinit();
        try std.testing.expect(std.meta.eql(
            owner.set.parsed.value.monitors[0].runtime,
            durable_after_success.parsed.value.monitors[0].runtime,
        ));
    }
}

fn checkSessionInitAllocationFailures(alloc: Allocator) !void {
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-allocation");
    var id_owned = true;
    errdefer if (id_owned) alloc.free(id);
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .command = "printf ready",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .return_when = .{ .match = "ready" },
        },
        testPersistence("/workspace"),
    );
    id_owned = false;
    defer session.deinitUnlaunched();
}

test "session initialization owns durable resources" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSessionInitAllocationFailures,
        .{},
    );
}

test "recovered session owns the saved workspace scope" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    var persistence = testPersistence("/saved-workspace/cwd");
    persistence.grant.principal.workspace_root = "/saved-workspace";
    persistence.grant.principal.backend = .tmux;
    const durable = try terminal_store.DurableSession.create(&fixture.profile, .{
        .session_id = "terminal-recovered-scope",
        .host_identity = "test-host",
        .shell = "/bin/zsh",
        .cwd = "/saved-workspace/cwd",
        .command = "printf ready",
        .backend = .tmux,
        .dimensions = .{ .rows = 24, .columns = 80 },
        .persistence = persistence,
        .initial_monitors = &.{},
        .now_ms = 1,
    });
    var session = try Session.initRecovered(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        durable,
    );
    defer session.deinitUnlaunched();

    try std.testing.expectEqualStrings("/saved-workspace", session.workspace_root);
    try std.testing.expectEqualStrings("/saved-workspace/cwd", session.cwd);
}

test "terminal state does not release live work before backend cleanup" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-live-cleanup");
    var probe: WorkProbe = .{};
    var session = try Session.init(
        alloc,
        .{ .context = &probe, .update_fn = WorkProbe.update },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
    );
    defer session.deinitUnlaunched();

    session.markLive();
    session.lifecycle = .running;
    session.setTerm(.{ .exited = 0 });
    try std.testing.expectEqual(@as(isize, 1), probe.live);
    try std.testing.expect(!session.isRecyclable());

    session.markNotLive();
    try std.testing.expectEqual(@as(isize, 0), probe.live);
    try std.testing.expect(session.isRecyclable());
    session.markNotLive();
    try std.testing.expectEqual(@as(usize, 2), probe.updates);
}

test "durable journal preserves startup matches" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-retention");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .command = "printf ready",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .return_when = .{ .match = "ready" },
        },
        testPersistence("/workspace"),
    );
    defer session.deinitUnlaunched();

    session.command_start_cursor = .{ .segment = 1, .offset = 0 };
    session.lifecycle = .running;
    session.appendOutput("ready");
    const noise: [64]u8 = @splat('x');
    session.appendOutput(&noise);
    try std.testing.expectEqual(@as(u64, 1), session.durable.record.output_cursor.segment);
    try std.testing.expect(session.startup_match_seen);
    try std.testing.expectEqual(
        contracts.ReturnOutcome.condition_met,
        session.matchConditionLocked(.{ .match = "ready" }, io_mod.milliTimestamp()).?,
    );
}

test "command start match ignores profile output before its cursor" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-command-boundary");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .command = "printf boundary-match",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .return_when = .{ .match = "boundary-match" },
        },
        testPersistence("/workspace"),
    );
    defer session.deinitUnlaunched();

    session.appendOutput("profile boundary-match\n");
    try std.testing.expect(!session.startup_match_seen);
    try std.testing.expect(session.matchConditionLocked(
        .{ .match = "boundary-match" },
        io_mod.milliTimestamp(),
    ) == null);

    session.command_start_cursor = session.durable.record.output_cursor;
    session.last_output_ms = io_mod.milliTimestamp();
    session.lifecycle = .running;
    session.appendOutput("target boundary-match\n");
    try std.testing.expect(session.startup_match_seen);
    try std.testing.expectEqual(
        contracts.ReturnOutcome.condition_met,
        session.matchConditionLocked(
            .{ .match = "boundary-match" },
            io_mod.milliTimestamp(),
        ).?,
    );
}

test "split partial bytes remain opaque and ordered" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-partial-bytes");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
    );
    defer session.deinitUnlaunched();

    session.appendOutput(&.{ 0xf0, 0x9f });
    session.appendOutput(&.{0x92});
    session.appendOutput(&.{ 0xa9, 0x00, 0xff });
    var page = try session.durable.read(
        alloc,
        .{ .segment = 1, .offset = 0 },
        16,
    );
    defer page.deinit(alloc);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xf0, 0x9f, 0x92, 0xa9, 0x00, 0xff },
        page.output,
    );
    try std.testing.expectEqual(
        contracts.RawCursor{ .segment = 1, .offset = 6 },
        session.durable.record.output_cursor,
    );
}

test "checkpoint plus contiguous observational replay equals live screen" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-screen-replay");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .dimensions = .{ .rows = 4, .columns = 12 },
        },
        testPersistence("/workspace"),
    );
    defer session.deinitUnlaunched();

    session.appendOutput("hello\x1b[2;");
    const checkpoint_cursor = session.durable.record.output_cursor;
    try session.checkpointLocked(checkpoint_cursor, io_mod.milliTimestamp());
    try session.durable.append("3H\xe7\x95\x8c\x1b[6n", io_mod.milliTimestamp());
    var live_result = try session.engine.feedMode(
        "3H\xe7\x95\x8c\x1b[6n",
        .native_live,
    );
    defer live_result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), live_result.replies.items.len);
    try std.testing.expectEqual(
        checkpoint_cursor,
        switch (session.durable.record.screen_recovery) {
            .available => |envelope| envelope.applied_cursor,
            .unavailable => return error.TestUnexpectedResult,
        },
    );

    var recovered = try reconstructEngine(alloc, &session.durable);
    defer recovered.deinit();
    const live_payload = try session.engine.checkpointPayload(alloc);
    defer alloc.free(live_payload);
    const recovered_payload = try recovered.checkpointPayload(alloc);
    defer alloc.free(recovered_payload);
    try std.testing.expectEqualSlices(u8, live_payload, recovered_payload);

    const unavailable_from = contracts.RawCursor{
        .segment = checkpoint_cursor.segment,
        .offset = checkpoint_cursor.offset + 1,
    };
    session.durable.record.available_from = unavailable_from;
    session.durable.record.raw_gap = .{
        .missing_from = checkpoint_cursor,
        .available_from = unavailable_from,
    };
    session.durable.record.journal_files[0].range.start = unavailable_from;
    session.durable.record.journal_files[0].payload_bytes =
        session.durable.record.output_cursor.offset - unavailable_from.offset;
    session.durable.record.journal_payload_bytes =
        session.durable.record.journal_files[0].payload_bytes;
    try std.testing.expectError(
        error.ScreenRawGap,
        reconstructEngine(alloc, &session.durable),
    );
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .raw_gap },
        session.durable.facts().screen_recovery,
    );
}

test "many small output chunks checkpoint only at store boundaries" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-checkpoint-boundary");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
    );
    defer session.deinitUnlaunched();
    var sink = try std.Io.Dir.openFileAbsolute(
        std.testing.io,
        "/dev/null",
        .{ .mode = .write_only },
    );
    defer sink.close(std.testing.io);
    session.master_fd = sink.handle;

    for (0..64) |_| session.appendOutput("x");
    try std.testing.expectEqual(
        @as(u64, 0),
        session.durable.record.checkpoint_generation,
    );

    const block: [256 * 1024]u8 = @splat('y');
    for (0..4) |_| session.appendOutput(&block);
    try std.testing.expectEqual(
        @as(u64, 1),
        session.durable.record.checkpoint_generation,
    );
    try std.testing.expectEqual(
        session.durable.record.output_cursor,
        switch (session.durable.record.screen_recovery) {
            .available => |checkpoint| checkpoint.applied_cursor,
            .unavailable => return error.TestUnexpectedResult,
        },
    );

    for (0..64) |_| session.appendOutput("z");
    try std.testing.expectEqual(
        @as(u64, 1),
        session.durable.record.checkpoint_generation,
    );
}

test "resize recovery never reflows raw output at final dimensions" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-resize-recovery");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .dimensions = .{ .rows = 2, .columns = 4 },
        },
        testPersistence("/workspace"),
    );
    var session_owned = true;
    defer if (session_owned) session.deinitUnlaunched();

    try session.durable.append("abcdef", 2);
    var feed = try session.engine.feedMode("abcdef", .native_live);
    feed.deinit(alloc);
    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(alloc);
    try session.engine.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("abcd", row.items);
    row.clearRetainingCapacity();
    try session.engine.rowTextTrimmed(2, &row);
    try std.testing.expectEqualStrings("ef", row.items);

    const resized = contracts.Dimensions{ .rows = 2, .columns = 6 };
    try session.engine.resize(resized.columns, resized.rows);
    try session.durable.resize(resized, 3);
    session.dimensions = resized;
    try session.checkpointLocked(session.durable.output_cursor(), 4);

    var recovered = try reconstructEngine(alloc, &session.durable);
    defer recovered.deinit();
    const live_payload = try session.engine.checkpointPayload(alloc);
    defer alloc.free(live_payload);
    const recovered_payload = try recovered.checkpointPayload(alloc);
    defer alloc.free(recovered_payload);
    try std.testing.expectEqualSlices(u8, live_payload, recovered_payload);

    var raw_at_final_size = try terminal_engine.Grid.init(
        alloc,
        resized.columns,
        resized.rows,
    );
    defer raw_at_final_size.deinit();
    var raw_feed = try raw_at_final_size.feedMode("abcdef", .journal_replay);
    raw_feed.deinit(alloc);
    row.clearRetainingCapacity();
    try raw_at_final_size.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("abcdef", row.items);
    row.clearRetainingCapacity();
    try session.engine.rowTextTrimmed(1, &row);
    try std.testing.expectEqualStrings("abcd", row.items);

    try session.durable.store_checkpoint(.{
        .engine_schema_revision = terminal_engine.checkpoint_schema_revision + 1,
        .applied_cursor = session.durable.output_cursor(),
        .payload_len = @intCast(live_payload.len),
        .checksum = contracts.checkpoint_checksum(live_payload),
    }, live_payload, 5);
    try std.testing.expect(!session.durable.record.raw_replay_exact);
    try std.testing.expectError(
        error.ScreenUnsupported,
        reconstructEngine(alloc, &session.durable),
    );
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .unsupported_schema },
        session.durable.facts().screen_recovery,
    );

    session.deinitUnlaunched();
    session_owned = false;
    const reopened = try fixture.profile.open_terminal(
        "terminal-resize-recovery",
    );
    defer fixture.profile.release_terminal(reopened);
    try std.testing.expectEqual(resized, reopened.record.dimensions);
    try std.testing.expect(!reopened.record.raw_replay_exact);
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .unsupported_schema },
        reopened.facts().screen_recovery,
    );
}

test "native protocol replies are independent of either durable write lease" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-reply-leases");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
    );
    defer session.deinitUnlaunched();

    for ([_]contracts.AttentionState{
        .{ .attention = .agent_wait, .write_lease = .agent },
        .{ .attention = .user_takeover, .write_lease = .human },
    }) |attention| {
        session.durable.record.attention = attention;
        var result = try session.engine.feedMode("\x1b[5n", .native_live);
        defer result.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 1), result.replies.items.len);
        try std.testing.expectEqualStrings("\x1b[0n", result.replies.items[0].bytes);
    }
}

test "missing corrupt and unsupported checkpoints fall back only with full raw continuity" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-screen-fallback");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
            .dimensions = .{ .rows = 3, .columns = 10 },
        },
        testPersistence("/workspace"),
    );
    defer session.deinitUnlaunched();
    session.appendOutput("fallback");

    const original_recovery = session.durable.record.screen_recovery;
    inline for (.{
        contracts.ScreenUnavailableReason.missing,
        .corrupt,
        .unsupported_schema,
    }) |reason| {
        session.durable.record.screen_recovery = .{ .unavailable = reason };
        var recovered = try reconstructEngine(alloc, &session.durable);
        defer recovered.deinit();
        try std.testing.expectEqual(@as(u21, 'f'), recovered.cellAt(1, 1).?.codepoint);
        try std.testing.expectEqual(
            contracts.ScreenRecovery{ .unavailable = reason },
            session.durable.facts().screen_recovery,
        );
    }

    session.durable.record.screen_recovery = .{ .unavailable = .corrupt };
    session.durable.record.available_from.offset = 1;
    session.durable.record.raw_gap = .{
        .missing_from = .{ .segment = 1, .offset = 0 },
        .available_from = .{ .segment = 1, .offset = 1 },
    };
    session.durable.record.journal_files[0].range.start.offset = 1;
    session.durable.record.journal_files[0].payload_bytes -= 1;
    session.durable.record.journal_payload_bytes -= 1;
    try std.testing.expectError(
        error.ScreenRawGap,
        reconstructEngine(alloc, &session.durable),
    );
    session.durable.record.available_from.offset = 0;
    session.durable.record.raw_gap = null;
    session.durable.record.journal_files[0].range.start.offset = 0;
    session.durable.record.journal_files[0].payload_bytes += 1;
    session.durable.record.journal_payload_bytes += 1;
    session.durable.record.screen_recovery = original_recovery;
}

test "recovery classifiers preserve allocation and transient failures" {
    try std.testing.expectEqual(
        contracts.ScreenUnavailableReason.unsupported_schema,
        engine_checkpoint_unavailable_reason(error.UnsupportedEngineRevision).?,
    );
    try std.testing.expectEqual(
        contracts.ScreenUnavailableReason.corrupt,
        engine_checkpoint_unavailable_reason(error.InvalidEngineCheckpoint).?,
    );
    try std.testing.expect(
        engine_checkpoint_unavailable_reason(error.OutOfMemory) == null,
    );
    try std.testing.expect(replay_feed_error_is_corrupt(
        error.TooManyCsiParameters,
    ));
    try std.testing.expect(!replay_feed_error_is_corrupt(error.OutOfMemory));
}

test "checkpoint load allocation failure preserves durable recovery facts" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-checkpoint-load-oom");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
    );
    defer session.deinitUnlaunched();

    session.appendOutput("checkpoint");
    try session.checkpointLocked(
        session.durable.output_cursor(),
        io_mod.milliTimestamp(),
    );
    const recovery = session.durable.record.screen_recovery;
    const generation = session.durable.record.checkpoint_generation;
    const checkpoint_bytes = session.durable.record.checkpoint_payload_bytes;
    const cleanup_generation = session.durable.record.checkpoint_cleanup_generation;

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        reconstructEngine(failing.allocator(), &session.durable),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(recovery, session.durable.record.screen_recovery);
    try std.testing.expectEqual(generation, session.durable.record.checkpoint_generation);
    try std.testing.expectEqual(
        checkpoint_bytes,
        session.durable.record.checkpoint_payload_bytes,
    );
    try std.testing.expectEqual(
        cleanup_generation,
        session.durable.record.checkpoint_cleanup_generation,
    );

    var retained = (try session.durable.load_checkpoint(alloc)).?;
    defer retained.deinit(alloc);
    try std.testing.expectEqual(generation, session.durable.record.checkpoint_generation);
}

test "journal engine feed allocation failure preserves durable recovery facts" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-replay-feed-oom");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
    );
    defer session.deinitUnlaunched();

    session.appendOutput("base");
    try session.checkpointLocked(
        session.durable.output_cursor(),
        io_mod.milliTimestamp(),
    );
    try session.durable.append(
        "\x1b]8;;https://example.com\x1b\\X\x1b]8;;\x1b\\",
        io_mod.milliTimestamp(),
    );
    const recovery = session.durable.record.screen_recovery;
    const generation = session.durable.record.checkpoint_generation;
    const checkpoint_bytes = session.durable.record.checkpoint_payload_bytes;
    const cleanup_generation = session.durable.record.checkpoint_cleanup_generation;

    var probe = std.testing.FailingAllocator.init(alloc, .{});
    var recovered = try reconstructEngine(probe.allocator(), &session.durable);
    recovered.deinit();
    try std.testing.expect(probe.alloc_index > 0);
    try std.testing.expectEqual(probe.allocated_bytes, probe.freed_bytes);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = probe.alloc_index - 1 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        reconstructEngine(failing.allocator(), &session.durable),
    );
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try std.testing.expectEqual(recovery, session.durable.record.screen_recovery);
    try std.testing.expectEqual(generation, session.durable.record.checkpoint_generation);
    try std.testing.expectEqual(
        checkpoint_bytes,
        session.durable.record.checkpoint_payload_bytes,
    );
    try std.testing.expectEqual(
        cleanup_generation,
        session.durable.record.checkpoint_cleanup_generation,
    );
}

test "malformed raw fallback durably replaces an invalid checkpoint with corrupt" {
    const alloc = std.testing.allocator;
    var fixture = try TestDurableFixture.init(alloc);
    defer fixture.deinit();
    const id = try alloc.dupe(u8, "terminal-malformed-raw-recovery");
    var session = try Session.init(
        alloc,
        .{ .context = null, .update_fn = ignoreWorkUpdate },
        &fixture.profile,
        "test-host",
        id,
        .{
            .cwd = "/workspace",
            .shell = .{ .executable = .{ .path = "/bin/zsh" } },
        },
        testPersistence("/workspace"),
    );
    var session_owned = true;
    defer if (session_owned) session.deinitUnlaunched();

    const malformed = "\x1b[1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1H";
    try session.durable.append(malformed, io_mod.milliTimestamp());
    const invalid_payload = "invalid-engine-checkpoint";
    try session.durable.store_checkpoint(.{
        .engine_schema_revision = terminal_engine.checkpoint_schema_revision,
        .applied_cursor = session.durable.output_cursor(),
        .payload_len = invalid_payload.len,
        .checksum = contracts.checkpoint_checksum(invalid_payload),
    }, invalid_payload, io_mod.milliTimestamp());

    try std.testing.expectError(
        error.ScreenCorrupt,
        reconstructEngine(alloc, &session.durable),
    );
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .corrupt },
        session.durable.facts().screen_recovery,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        session.durable.record.checkpoint_generation,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        session.durable.record.checkpoint_payload_bytes,
    );
    try std.testing.expect(
        session.durable.record.checkpoint_cleanup_generation == null,
    );

    session.deinitUnlaunched();
    session_owned = false;
    const reopened = try fixture.profile.open_terminal(
        "terminal-malformed-raw-recovery",
    );
    defer fixture.profile.release_terminal(reopened);
    try std.testing.expectEqual(
        contracts.ScreenRecovery{ .unavailable = .corrupt },
        reopened.facts().screen_recovery,
    );
}
