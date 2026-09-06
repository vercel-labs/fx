const std = @import("std");
const builtin = @import("builtin");
const contracts = @import("contracts.zig");
const host_capabilities = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const process_identity = @import("../execution/process_identity.zig");
const process_provider_mod = @import(
    "../execution/process_provider.zig",
);

const Allocator = std.mem.Allocator;

pub const launcher_mode = "--fx-internal-terminal-tmux-launcher";
pub const capture_mode = "--fx-internal-terminal-tmux-capture";

const namespace_option = "@fx_terminal_namespace";
const namespace_value = "1";
const minimum_tmux_major: u16 = 3;
const minimum_tmux_minor: u16 = 2;
const max_command_output_bytes: usize = 64 * 1024;
const max_launcher_config_bytes: usize = contracts.max_command_bytes * 6 +
    contracts.max_authority_text_bytes * 3 +
    contracts.max_shell_path_bytes * 2 +
    8192;
const max_lifecycle_bytes: usize = 8 * 5;
const control_nonce_len: usize = 32;
const marker_frame_len: usize = control_nonce_len + 1;
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const poll_ns: u64 = 5 * std.time.ns_per_ms;
const cleanup_settle_deadline_ms: i64 = 500;
const capture_accept_deadline_ms: i64 = 2_000;
pub const marker_acknowledgement_timeout_ms: i64 = 15_000;
const marker_acknowledgement_delivery_margin_ms: i64 = 1_000;
const marker_shell_start_deadline_ms: i64 = 60_000;
const marker_command_arrival_deadline_ms: i64 =
    marker_acknowledgement_timeout_ms - marker_acknowledgement_delivery_margin_ms;
const marker_connected_frame_deadline_ms: i64 =
    marker_acknowledgement_timeout_ms - marker_acknowledgement_delivery_margin_ms;
const command_release_deadline_ms: i64 =
    marker_acknowledgement_timeout_ms - marker_acknowledgement_delivery_margin_ms;
const deadline_poll_ms: i64 = 50;

const PeerDeadline = struct {
    expires_ms: i64,

    fn init(default_ms: i64) PeerDeadline {
        const duration_ms = if (io_mod.getenv(
            "FX_TERMINAL_TEST_TMUX_DEADLINE_MS",
        )) |text|
            @min(
                std.fmt.parseInt(i64, text, 10) catch default_ms,
                default_ms,
            )
        else
            default_ms;
        return .{ .expires_ms = monotonicMillis() + @max(duration_ms, 1) };
    }

    fn remaining(self: PeerDeadline) error{TmuxPeerTimeout}!i64 {
        const remaining_ms = self.expires_ms - monotonicMillis();
        if (remaining_ms <= 0) return error.TmuxPeerTimeout;
        return remaining_ms;
    }
};

const ControlPhase = enum {
    awaiting_shell,
    shell_ready,
    command_started,
};

const MarkerReceptionDeadlines = struct {
    phase_arrival: PeerDeadline,

    fn init() MarkerReceptionDeadlines {
        return .{
            .phase_arrival = PeerDeadline.init(marker_shell_start_deadline_ms),
        };
    }

    fn connectedFrame(_: MarkerReceptionDeadlines) PeerDeadline {
        return PeerDeadline.init(marker_connected_frame_deadline_ms);
    }

    fn updateAfterMarker(
        self: *MarkerReceptionDeadlines,
        previous_phase: ControlPhase,
        current_phase: ControlPhase,
    ) void {
        if (previous_phase == current_phase) return;
        std.debug.assert(previous_phase == .awaiting_shell);
        std.debug.assert(current_phase == .shell_ready);
        self.phase_arrival = PeerDeadline.init(marker_command_arrival_deadline_ms);
    }
};

pub const LifecycleKind = enum(u8) {
    prepared = 1,
    shell_ready = 2,
    command_started = 3,
    command_exited = 4,
    command_signal = 5,
    startup_failed = 6,
    invalid_term = 7,
};

pub const LifecycleFrame = struct {
    kind: LifecycleKind,
    value: u32,
};

const MarkerKind = enum(u8) {
    shell_ready = 1,
    command_started = 2,
};

pub const LauncherConfig = struct {
    argv: []const []const u8,
    cwd: []const u8,
    control_path: []const u8,
    control_nonce: []const u8,
    bootstrap_path: []const u8,
    bootstrap: []const u8,
    command_path: ?[]const u8,
    command: ?[]const u8,
    interactive_source: ?[]const u8,
    tmux_socket: []const u8,
    tmux_target: []const u8,
    lifecycle_path: []const u8,
    shell_identity_path: []const u8,
    manifest_ready_path: []const u8,
    release_path: []const u8,
    command_release_path: []const u8,
};

pub const Paths = struct {
    socket: []u8,
    config: []u8,
    lifecycle: []u8,
    shell_identity: []u8,
    manifest: []u8,
    manifest_ready: []u8,
    release: []u8,
    command_release: []u8,
    bootstrap: []u8,
    command: []u8,
    marker_socket: []u8,
    capture_socket: []u8,
    session_name: []u8,
    target: []u8,

    pub fn init(
        alloc: Allocator,
        durable_root: []const u8,
        transport_root: []const u8,
        backend_identity: []const u8,
    ) !Paths {
        if (!validBackendIdentity(backend_identity)) {
            return error.InvalidTmuxBackendIdentity;
        }
        const session_name = try std.fmt.allocPrint(
            alloc,
            "fx-{s}",
            .{backend_identity},
        );
        errdefer alloc.free(session_name);
        const target = try std.fmt.allocPrint(
            alloc,
            "{s}:terminal.0",
            .{session_name},
        );
        errdefer alloc.free(target);
        const socket = try std.fs.path.join(alloc, &.{ transport_root, "tmux.sock" });
        errdefer alloc.free(socket);
        const config = try artifactPath(alloc, durable_root, backend_identity, "config.json");
        errdefer alloc.free(config);
        const lifecycle = try artifactPath(alloc, durable_root, backend_identity, "lifecycle.bin");
        errdefer alloc.free(lifecycle);
        const shell_identity = try artifactPath(
            alloc,
            durable_root,
            backend_identity,
            "shell-identity.json",
        );
        errdefer alloc.free(shell_identity);
        const manifest = try artifactPath(alloc, durable_root, backend_identity, "manifest.json");
        errdefer alloc.free(manifest);
        const manifest_ready = try artifactPath(
            alloc,
            durable_root,
            backend_identity,
            "manifest-ready",
        );
        errdefer alloc.free(manifest_ready);
        const release = try artifactPath(alloc, durable_root, backend_identity, "release");
        errdefer alloc.free(release);
        const command_release = try artifactPath(alloc, durable_root, backend_identity, "command-release");
        errdefer alloc.free(command_release);
        const bootstrap = try artifactPath(alloc, durable_root, backend_identity, "bootstrap");
        errdefer alloc.free(bootstrap);
        const command = try artifactPath(alloc, durable_root, backend_identity, "command");
        errdefer alloc.free(command);
        const marker_socket = try std.fmt.allocPrint(
            alloc,
            "/tmp/fx-tmux-marker-{s}.sock",
            .{backend_identity},
        );
        errdefer alloc.free(marker_socket);
        const capture_socket = try std.fmt.allocPrint(
            alloc,
            "/tmp/fx-tmux-capture-{s}.sock",
            .{backend_identity},
        );
        errdefer alloc.free(capture_socket);
        return .{
            .socket = socket,
            .config = config,
            .lifecycle = lifecycle,
            .shell_identity = shell_identity,
            .manifest = manifest,
            .manifest_ready = manifest_ready,
            .release = release,
            .command_release = command_release,
            .bootstrap = bootstrap,
            .command = command,
            .marker_socket = marker_socket,
            .capture_socket = capture_socket,
            .session_name = session_name,
            .target = target,
        };
    }

    pub fn deinit(self: *Paths, alloc: Allocator) void {
        alloc.free(self.target);
        alloc.free(self.session_name);
        alloc.free(self.capture_socket);
        alloc.free(self.marker_socket);
        alloc.free(self.command);
        alloc.free(self.bootstrap);
        alloc.free(self.command_release);
        alloc.free(self.release);
        alloc.free(self.manifest_ready);
        alloc.free(self.manifest);
        alloc.free(self.shell_identity);
        alloc.free(self.lifecycle);
        alloc.free(self.config);
        alloc.free(self.socket);
        self.* = undefined;
    }
};

const ManifestWire = struct {
    schema_version: u16 = 1,
    backend_identity: []const u8,
    session_name: []const u8,
    pane_id: []const u8,
    pane_pid: []const u8,
    pane_process_token: []const u8,
};

pub const AuthenticatedProcessIdentity = struct {
    pid: []const u8,
    process_token: []const u8,
};

const OwnerEvidence = union(enum) {
    manifest: ManifestWire,
    process_identity: AuthenticatedProcessIdentity,

    fn processIdentity(self: OwnerEvidence) AuthenticatedProcessIdentity {
        return switch (self) {
            .manifest => |manifest| .{
                .pid = manifest.pane_pid,
                .process_token = manifest.pane_process_token,
            },
            .process_identity => |identity| identity,
        };
    }
};

const ShellIdentityWire = struct {
    pid: u32,
    process_token: []const u8,
};

pub const ShellIdentity = struct {
    pid: std.posix.pid_t,
    process_token: process_identity.ProcessInstanceToken,
};

const Pane = struct {
    alloc: Allocator,
    pane_id: []u8,
    pane_pid: []u8,
    dead: bool,
    dead_status: ?u32,
    dimensions: contracts.Dimensions,
    cursor_row: u16,
    cursor_column: u16,
    cursor_visible: bool,
    cursor_shape: contracts.CursorShape,
    cursor_blinking: bool,
    alternate_screen: bool,
    origin: bool,
    autowrap: bool,
    insert: bool,
    mouse_tracking: bool,
    application_cursor_keys: bool,
    application_keypad: bool,

    fn deinit(self: *Pane) void {
        self.alloc.free(self.pane_pid);
        self.alloc.free(self.pane_id);
        self.* = undefined;
    }
};

pub const ScreenCapture = struct {
    alloc: Allocator,
    bytes: []u8,
    dimensions: contracts.Dimensions,
    cursor_row: u16,
    cursor_column: u16,
    cursor_visible: bool,
    cursor_shape: contracts.CursorShape,
    cursor_blinking: bool,
    alternate_screen: bool,
    origin: bool,
    autowrap: bool,
    insert: bool,
    mouse_tracking: bool,
    application_cursor_keys: bool,
    application_keypad: bool,
    exact_modes_available: bool,

    pub fn deinit(self: *ScreenCapture) void {
        self.alloc.free(self.bytes);
        self.* = undefined;
    }
};

pub const Backend = struct {
    alloc: Allocator,
    backend_identity: []u8,
    executable: []u8,
    paths: Paths,
    manifest: ManifestWire,
    capture_server: ?std.Io.net.Server = null,
    pane_dead: bool = false,

    pub fn start(
        alloc: Allocator,
        process_provider: process_provider_mod.Provider,
        durable_root: []const u8,
        transport_root: []const u8,
        backend_identity: []const u8,
        executable: []const u8,
        dimensions: contracts.Dimensions,
        config: LauncherConfig,
    ) !Backend {
        try probe(alloc);
        var paths = try Paths.init(
            alloc,
            durable_root,
            transport_root,
            backend_identity,
        );
        errdefer paths.deinit(alloc);
        cleanupFiles(&paths);
        try writeLauncherConfig(alloc, paths.config, config);
        errdefer cleanupFiles(&paths);

        const quoted_executable = try quoteShellWord(alloc, executable);
        defer alloc.free(quoted_executable);
        const quoted_config = try quoteShellWord(alloc, paths.config);
        defer alloc.free(quoted_config);
        const launcher_command = try std.fmt.allocPrint(
            alloc,
            "exec {s} {s} {s}",
            .{ quoted_executable, launcher_mode, quoted_config },
        );
        defer alloc.free(launcher_command);

        _ = try privateSocketExists(paths.socket);
        try ensureNamespace(alloc, &paths);
        const columns = try formatU16(alloc, dimensions.columns);
        defer alloc.free(columns);
        const rows = try formatU16(alloc, dimensions.rows);
        defer alloc.free(rows);
        try runTmuxNoOutput(alloc, paths.socket, &.{
            "new-session",
            "-d",
            "-s",
            paths.session_name,
            "-n",
            "terminal",
            "-x",
            columns,
            "-y",
            rows,
            launcher_command,
        });
        errdefer {
            killSessionAt(alloc, paths.socket, paths.session_name);
            cleanupSocketIfUnused(alloc, paths.socket);
        }
        try std.Io.Dir.cwd().setFilePermissions(
            io_mod.getIo(),
            paths.socket,
            private_file_permissions,
            .{ .follow_symlinks = false },
        );
        if (!try privateSocketExists(paths.socket)) {
            return error.TmuxSocketMissing;
        }
        try runTmuxNoOutput(alloc, paths.socket, &.{
            "set-option",
            "-g",
            namespace_option,
            namespace_value,
        });
        try runTmuxNoOutput(alloc, paths.socket, &.{
            "set-option",
            "-w",
            "-t",
            paths.session_name,
            "remain-on-exit",
            "on",
        });
        try runTmuxNoOutput(alloc, paths.socket, &.{
            "set-option",
            "-t",
            paths.session_name,
            namespace_option,
            backend_identity,
        });

        var pane = try inspectPane(alloc, &paths);
        defer pane.deinit();
        const token = try process_provider.captureToken(
            alloc,
            pane.pane_pid,
        );
        var manifest = ManifestWire{
            .backend_identity = backend_identity,
            .session_name = paths.session_name,
            .pane_id = pane.pane_id,
            .pane_pid = pane.pane_pid,
            .pane_process_token = token.view(),
        };
        try writeManifest(alloc, paths.manifest, manifest);
        try createPrivateSignal(paths.manifest_ready);
        const backend_identity_owned = try alloc.dupe(u8, backend_identity);
        errdefer alloc.free(backend_identity_owned);
        const executable_owned = try alloc.dupe(u8, executable);
        errdefer alloc.free(executable_owned);
        manifest = try ownManifest(alloc, manifest);
        errdefer deinitManifest(alloc, &manifest);
        var backend = Backend{
            .alloc = alloc,
            .backend_identity = backend_identity_owned,
            .executable = executable_owned,
            .paths = paths,
            .manifest = manifest,
            .pane_dead = pane.dead,
        };
        try backend.waitForPrepared();
        return backend;
    }

    pub fn recover(
        alloc: Allocator,
        process_provider: process_provider_mod.Provider,
        durable_root: []const u8,
        transport_root: []const u8,
        backend_identity: []const u8,
        executable: []const u8,
    ) !Backend {
        try probe(alloc);
        var paths = try Paths.init(
            alloc,
            durable_root,
            transport_root,
            backend_identity,
        );
        errdefer paths.deinit(alloc);
        var parsed = try loadOwnedManifest(
            alloc,
            &paths,
            backend_identity,
        );
        errdefer deinitManifest(alloc, &parsed);
        const backend_identity_owned = try alloc.dupe(u8, backend_identity);
        errdefer alloc.free(backend_identity_owned);
        const executable_owned = try alloc.dupe(u8, executable);
        errdefer alloc.free(executable_owned);
        if (!try ownedSessionPresent(alloc, &paths, backend_identity)) {
            return error.TmuxRecoveryMissing;
        }
        const pane_state = validateOwnedPane(
            alloc,
            process_provider,
            &paths,
            .{ .manifest = parsed },
        ) catch |err| {
            debug_trace.logf(
                "terminal_host",
                "tmux recovery ownership retained backend={s} stage=pane-validation err={s}",
                .{ backend_identity, @errorName(err) },
            );
            return err;
        };
        const pane_dead = switch (pane_state) {
            .missing => return error.TmuxRecoveryMissing,
            .present => |dead| dead,
        };
        return .{
            .alloc = alloc,
            .backend_identity = backend_identity_owned,
            .executable = executable_owned,
            .paths = paths,
            .manifest = parsed,
            .pane_dead = pane_dead,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.closeCaptureServer();
        deinitManifest(self.alloc, &self.manifest);
        self.paths.deinit(self.alloc);
        self.alloc.free(self.executable);
        self.alloc.free(self.backend_identity);
        self.* = undefined;
    }

    pub fn deinitRetainingOwnedNamespace(self: *Backend) void {
        self.stopCapture();
        const capture_socket_present = blk: {
            std.Io.Dir.accessAbsolute(
                io_mod.getIo(),
                self.paths.capture_socket,
                .{},
            ) catch |err| switch (err) {
                error.FileNotFound => break :blk false,
                else => break :blk true,
            };
            break :blk true;
        };
        debug_trace.logf(
            "terminal_host",
            "tmux recovery ownership retained backend={s} capture_socket_present={}",
            .{ self.backend_identity, capture_socket_present },
        );
        self.deinit();
    }

    pub fn beginCapture(self: *Backend) !void {
        self.closeCaptureServer();
        std.Io.Dir.deleteFileAbsolute(
            io_mod.getIo(),
            self.paths.capture_socket,
        ) catch {};
        const address = try std.Io.net.UnixAddress.init(self.paths.capture_socket);
        self.capture_server = try address.listen(io_mod.getIo(), .{});
        errdefer self.closeCaptureServer();
        try std.Io.Dir.cwd().setFilePermissions(
            io_mod.getIo(),
            self.paths.capture_socket,
            private_file_permissions,
            .{ .follow_symlinks = false },
        );
        const quoted_executable = try quoteShellWord(self.alloc, self.executable);
        defer self.alloc.free(quoted_executable);
        const quoted_socket = try quoteShellWord(self.alloc, self.paths.capture_socket);
        defer self.alloc.free(quoted_socket);
        const quoted_identity = try quoteShellWord(self.alloc, self.backend_identity);
        defer self.alloc.free(quoted_identity);
        const command = try std.fmt.allocPrint(
            self.alloc,
            "exec {s} {s} {s} {s}",
            .{ quoted_executable, capture_mode, quoted_socket, quoted_identity },
        );
        defer self.alloc.free(command);
        try runTmuxNoOutput(self.alloc, self.paths.socket, &.{
            "pipe-pane",
            "-O",
            "-t",
            self.paths.target,
            command,
        });
    }

    pub fn acceptCapture(self: *Backend) !std.Io.net.Stream {
        errdefer self.stopCapture();
        const server = &self.capture_server.?;
        const deadline = PeerDeadline.init(capture_accept_deadline_ms);
        var stream = try acceptBeforeDeadline(server, deadline, null);
        errdefer stream.close(io_mod.getIo());
        var identity: [32]u8 = undefined;
        try receiveBeforeDeadline(stream.socket, &identity, deadline, null);
        if (!std.mem.eql(u8, &identity, self.backend_identity)) {
            return error.TmuxCaptureIdentityMismatch;
        }
        return stream;
    }

    pub fn stopCapture(self: *Backend) void {
        runTmuxNoOutput(self.alloc, self.paths.socket, &.{
            "pipe-pane",
            "-t",
            self.paths.target,
        }) catch {};
        self.closeCaptureServer();
    }

    pub fn release(self: *Backend) !void {
        try createPrivateSignal(self.paths.release);
    }

    pub fn releaseCommand(self: *Backend) !void {
        try createPrivateSignal(self.paths.command_release);
    }

    pub fn lifecycle(self: *Backend) ![]LifecycleFrame {
        return readLifecycle(self.alloc, self.paths.lifecycle);
    }

    pub fn shellIdentity(self: *Backend) !ShellIdentity {
        return loadShellIdentity(self.alloc, self.paths.shell_identity) catch |err| switch (err) {
            error.FileNotFound => error.TmuxRecoveryShellIdentityMissing,
            else => err,
        };
    }

    pub fn captureScreen(self: *Backend) !ScreenCapture {
        var pane = try inspectPane(self.alloc, &self.paths);
        defer pane.deinit();
        const bytes = try runTmux(self.alloc, self.paths.socket, &.{
            "capture-pane",
            "-p",
            "-e",
            "-t",
            self.paths.target,
        });
        return .{
            .alloc = self.alloc,
            .bytes = bytes,
            .dimensions = pane.dimensions,
            .cursor_row = pane.cursor_row,
            .cursor_column = pane.cursor_column,
            .cursor_visible = pane.cursor_visible,
            .cursor_shape = pane.cursor_shape,
            .cursor_blinking = pane.cursor_blinking,
            .alternate_screen = pane.alternate_screen,
            .origin = pane.origin,
            .autowrap = pane.autowrap,
            .insert = pane.insert,
            .mouse_tracking = pane.mouse_tracking,
            .application_cursor_keys = pane.application_cursor_keys,
            .application_keypad = pane.application_keypad,
            // tmux 3.2+ does not expose bracketed paste, focus tracking,
            // keyboard protocol, or synchronized-update state.
            .exact_modes_available = false,
        };
    }

    pub fn write(self: *Backend, bytes: []const u8, paste: bool) !void {
        const buffer_name = try std.fmt.allocPrint(
            self.alloc,
            "fx-{s}",
            .{self.backend_identity},
        );
        defer self.alloc.free(buffer_name);
        try writeTmuxBuffer(
            self.alloc,
            self.paths.socket,
            self.paths.target,
            buffer_name,
            bytes,
            paste,
        );
    }

    pub fn resize(self: *Backend, dimensions: contracts.Dimensions) !void {
        const columns = try formatU16(self.alloc, dimensions.columns);
        defer self.alloc.free(columns);
        const rows = try formatU16(self.alloc, dimensions.rows);
        defer self.alloc.free(rows);
        try runTmuxNoOutput(self.alloc, self.paths.socket, &.{
            "resize-window",
            "-t",
            self.paths.session_name,
            "-x",
            columns,
            "-y",
            rows,
        });
    }

    pub fn killSession(self: *Backend) void {
        self.stopCapture();
        killSessionAt(self.alloc, self.paths.socket, self.paths.session_name);
        cleanupFiles(&self.paths);
        cleanupSocketIfUnused(self.alloc, self.paths.socket);
    }

    pub fn cleanupChecked(
        self: *Backend,
        process_provider: process_provider_mod.Provider,
    ) !void {
        try cleanupOwnedNamespaceWithEvidence(
            self.alloc,
            process_provider,
            &self.paths,
            self.backend_identity,
            .{ .manifest = self.manifest },
        );
    }

    pub fn paneIsDead(self: *const Backend) bool {
        return self.pane_dead;
    }

    fn waitForPrepared(self: *Backend) !void {
        const started = io_mod.milliTimestamp();
        while (io_mod.milliTimestamp() - started < 2_000) {
            const frames = readLifecycle(self.alloc, self.paths.lifecycle) catch |err| switch (err) {
                error.FileNotFound => {
                    io_mod.sleep(poll_ns);
                    continue;
                },
                else => return err,
            };
            defer self.alloc.free(frames);
            if (frames.len != 0 and frames[0].kind == .prepared) return;
            io_mod.sleep(poll_ns);
        }
        return error.TmuxLauncherNotPrepared;
    }

    fn closeCaptureServer(self: *Backend) void {
        if (self.capture_server) |*server| server.deinit(io_mod.getIo());
        self.capture_server = null;
        std.Io.Dir.deleteFileAbsolute(
            io_mod.getIo(),
            self.paths.capture_socket,
        ) catch |err| switch (err) {
            error.FileNotFound => {},
            else => debug_trace.logf(
                "terminal_host",
                "tmux capture socket cleanup failed path={s} err={s}",
                .{ self.paths.capture_socket, @errorName(err) },
            ),
        };
    }
};

fn writeTmuxBuffer(
    alloc: Allocator,
    socket: []const u8,
    target: []const u8,
    buffer_name: []const u8,
    bytes: []const u8,
    paste: bool,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try appendTmuxPrefix(&argv, alloc, socket);
    try argv.appendSlice(alloc, &.{ "load-buffer", "-b", buffer_name, "-" });
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    var child_owned = true;
    errdefer if (child_owned) child.kill(io_mod.getIo());
    var input = child.stdin orelse return error.TmuxInputUnavailable;
    child.stdin = null;
    var input_open = true;
    defer if (input_open) input.close(io_mod.getIo());
    try input.writeStreamingAll(io_mod.getIo(), bytes);
    input.close(io_mod.getIo());
    input_open = false;
    const term = try child.wait(io_mod.getIo());
    child_owned = false;
    if (term != .exited or term.exited != 0) return error.TmuxCommandFailed;
    errdefer runTmuxNoOutput(alloc, socket, &.{
        "delete-buffer",
        "-b",
        buffer_name,
    }) catch {};

    var paste_args: std.ArrayList([]const u8) = .empty;
    defer paste_args.deinit(alloc);
    try paste_args.appendSlice(alloc, &.{ "paste-buffer", "-d" });
    if (paste) try paste_args.append(alloc, "-p");
    try paste_args.appendSlice(alloc, &.{
        "-b",
        buffer_name,
        "-t",
        target,
    });
    try runTmuxNoOutput(
        alloc,
        socket,
        paste_args.items,
    );
}

pub fn cleanupOwnedNamespace(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    durable_root: []const u8,
    transport_root: []const u8,
    backend_identity: []const u8,
) void {
    var backend = Backend.recover(
        alloc,
        process_provider,
        durable_root,
        transport_root,
        backend_identity,
        "",
    ) catch return;
    defer backend.deinit();
    backend.killSession();
}

pub fn cleanupOwnedNamespaceChecked(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    durable_root: []const u8,
    transport_root: []const u8,
    backend_identity: []const u8,
    authenticated_process_identity: ?AuthenticatedProcessIdentity,
) !void {
    var paths = try Paths.init(
        alloc,
        durable_root,
        transport_root,
        backend_identity,
    );
    defer paths.deinit(alloc);
    var manifest: ?ManifestWire = loadOwnedManifest(
        alloc,
        &paths,
        backend_identity,
    ) catch |err| switch (err) {
        error.TmuxRecoveryManifestMissing => null,
        else => return err,
    };
    defer if (manifest) |*value| deinitManifest(alloc, value);
    const evidence: OwnerEvidence = if (manifest) |value|
        .{ .manifest = value }
    else if (authenticated_process_identity) |identity|
        .{ .process_identity = identity }
    else
        return error.TmuxRecoveryManifestMissing;
    if (try privateSocketExists(paths.socket)) try probe(alloc);
    try cleanupOwnedNamespaceWithEvidence(
        alloc,
        process_provider,
        &paths,
        backend_identity,
        evidence,
    );
}

fn cleanupOwnedNamespaceWithEvidence(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    paths: *const Paths,
    backend_identity: []const u8,
    evidence: OwnerEvidence,
) !void {
    const session_present = ownedSessionPresent(
        alloc,
        paths,
        backend_identity,
    ) catch |err| {
        logCleanupFailure(backend_identity, "ownership", err);
        return err;
    };
    if (session_present) {
        _ = validateOwnedPane(alloc, process_provider, paths, evidence) catch |err| {
            logCleanupFailure(backend_identity, "pane", err);
            return err;
        };
        if (io_mod.getenv("FX_TERMINAL_TEST_FAIL_TMUX_CLOSE_CLEANUP") != null) {
            return error.InjectedTmuxCloseCleanupFailure;
        }
        runTmuxNoOutput(alloc, paths.socket, &.{
            "kill-session",
            "-t",
            paths.session_name,
        }) catch |err| {
            waitForOwnedNamespaceAbsent(
                alloc,
                process_provider,
                paths,
                evidence,
            ) catch |absence_err| switch (absence_err) {
                error.TmuxCleanupIncomplete => {
                    logCleanupFailure(backend_identity, "kill", err);
                    return err;
                },
                else => {
                    logCleanupFailure(backend_identity, "absence", absence_err);
                    return absence_err;
                },
            };
        };
        waitForOwnedNamespaceAbsent(
            alloc,
            process_provider,
            paths,
            evidence,
        ) catch |err| {
            logCleanupFailure(backend_identity, "absence", err);
            return err;
        };
    } else {
        waitForOwnedNamespaceAbsent(
            alloc,
            process_provider,
            paths,
            evidence,
        ) catch |err| {
            logCleanupFailure(backend_identity, "absence", err);
            return err;
        };
    }
    cleanupFilesChecked(paths) catch |err| {
        logCleanupFailure(backend_identity, "artifacts", err);
        return err;
    };
    cleanupSocketIfUnusedChecked(alloc, paths.socket) catch |err| {
        logCleanupFailure(backend_identity, "socket", err);
        return err;
    };
}

fn logCleanupFailure(
    backend_identity: []const u8,
    stage: []const u8,
    err: anyerror,
) void {
    debug_trace.logf(
        "terminal_host",
        "checked tmux cleanup failed backend={s} stage={s} err={s}",
        .{ backend_identity, stage, @errorName(err) },
    );
}

pub fn isLauncherModeRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 3 and
        std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), launcher_mode);
}

pub fn isCaptureModeRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 4 and
        std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), capture_mode);
}

pub fn runLauncher(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    raw_args: []const [*:0]const u8,
) !void {
    if (comptime !supported()) return error.TerminalHostUnsupported;
    if (!isLauncherModeRaw(raw_args)) return error.InvalidTmuxLauncher;
    defer debug_trace.shutdown();
    debug_trace.configureFromEnv(alloc, ".");
    const config_path = std.mem.sliceTo(raw_args[2], 0);
    if (!std.fs.path.isAbsolute(config_path)) return error.InvalidTmuxLauncher;
    var config_file = try std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        config_path,
        .{},
    );
    defer config_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(
        alloc,
        &config_file,
        max_launcher_config_bytes,
    );
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(
        LauncherConfig,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    try validateLauncherConfig(parsed.value);
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), config_path) catch {};
    try writePrivateFile(parsed.value.bootstrap_path, parsed.value.bootstrap, true);
    defer std.Io.Dir.deleteFileAbsolute(
        io_mod.getIo(),
        parsed.value.bootstrap_path,
    ) catch {};
    if (parsed.value.command) |command| {
        try writePrivateFile(parsed.value.command_path.?, command, true);
    }
    defer if (parsed.value.command_path) |path| {
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};
    };
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
    try waitForSignal(parsed.value.manifest_ready_path);
    try writeLifecycle(parsed.value.lifecycle_path, .prepared, 0);
    try waitForSignal(parsed.value.release_path);

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
        try writeLifecycle(
            parsed.value.lifecycle_path,
            .startup_failed,
            1,
        );
        return;
    };
    var child_owned = true;
    errdefer if (child_owned) terminateAndReapChild(&child);
    const child_pid = child.id orelse return error.ChildIdentityMissing;
    if (!assignForegroundProcessGroup(std.posix.STDOUT_FILENO, child_pid)) {
        debug_trace.logf(
            "terminal_host",
            "tmux foreground handoff failed pid={d}",
            .{child_pid},
        );
        terminateAndReapChild(&child);
        child_owned = false;
        try writeLifecycle(parsed.value.lifecycle_path, .startup_failed, 3);
        return;
    }
    signalLauncherProcessGroup(child_pid, std.c.SIG.CONT) catch {
        terminateAndReapChild(&child);
        child_owned = false;
        try writeLifecycle(parsed.value.lifecycle_path, .startup_failed, 3);
        return;
    };
    if (parsed.value.interactive_source) |source| {
        writeTmuxBuffer(
            alloc,
            parsed.value.tmux_socket,
            parsed.value.tmux_target,
            parsed.value.control_nonce,
            source,
            false,
        ) catch {
            terminateAndReapChild(&child);
            child_owned = false;
            try writeLifecycle(parsed.value.lifecycle_path, .startup_failed, 3);
            while (true) io_mod.sleep(poll_ns);
        };
    }
    var control = LauncherControl{
        .alloc = alloc,
        .process_provider = process_provider,
        .server = &server,
        .config = parsed.value,
        .child_pid = child_pid,
    };
    var control_thread = std.Thread.spawn(
        .{},
        LauncherControl.run,
        .{&control},
    ) catch |err| {
        terminateAndReapChild(&child);
        child_owned = false;
        try writeLifecycle(parsed.value.lifecycle_path, .startup_failed, 3);
        return err;
    };
    const term = waitLauncherChild(&child) catch |err| {
        control.done.store(true, .release);
        control_thread.join();
        return err;
    };
    child_owned = false;
    control.done.store(true, .release);
    control_thread.join();
    if (control.failed) {
        try writeLifecycle(parsed.value.lifecycle_path, .startup_failed, 3);
        return;
    }
    const trusted_term = control.phase == .command_started or
        (control.phase == .shell_ready and parsed.value.command == null);
    if (!trusted_term) {
        try writeLifecycle(parsed.value.lifecycle_path, .startup_failed, 2);
        return;
    }
    switch (term) {
        .exited => |code| try writeLifecycle(
            parsed.value.lifecycle_path,
            .command_exited,
            code,
        ),
        .signal => |signal| try writeLifecycle(
            parsed.value.lifecycle_path,
            .command_signal,
            @intFromEnum(signal),
        ),
        .stopped, .unknown => try writeLifecycle(
            parsed.value.lifecycle_path,
            .invalid_term,
            0,
        ),
    }
    while (true) io_mod.sleep(poll_ns);
}

pub fn runCapture(raw_args: []const [*:0]const u8) !void {
    if (comptime !supported()) return error.TerminalHostUnsupported;
    if (!isCaptureModeRaw(raw_args)) return error.InvalidTmuxCapture;
    const socket_path = std.mem.sliceTo(raw_args[2], 0);
    const backend_identity = std.mem.sliceTo(raw_args[3], 0);
    if (!std.fs.path.isAbsolute(socket_path) or
        !validBackendIdentity(backend_identity))
    {
        return error.InvalidTmuxCapture;
    }
    const test_failure = io_mod.getenv("FX_TERMINAL_TEST_TMUX_CAPTURE_FAILURE");
    if (test_failure) |failure| {
        if (std.mem.eql(u8, failure, "child-exit")) return;
        if (std.mem.eql(u8, failure, "no-peer")) {
            return waitForCaptureStop();
        }
    }
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var stream = try address.connect(io_mod.getIo());
    defer stream.close(io_mod.getIo());
    if (test_failure) |failure| {
        if (std.mem.eql(u8, failure, "silent-peer")) {
            return waitForCaptureStop();
        }
        if (std.mem.eql(u8, failure, "partial-identity")) {
            try writeAll(
                stream.socket.handle,
                backend_identity[0 .. backend_identity.len / 2],
            );
            return waitForCaptureStop();
        }
        if (std.mem.eql(u8, failure, "wrong-identity")) {
            var wrong: [32]u8 = @splat('0');
            if (std.mem.eql(u8, &wrong, backend_identity)) wrong[0] = '1';
            try writeAll(stream.socket.handle, &wrong);
            return waitForCaptureStop();
        }
    }
    try writeAll(stream.socket.handle, backend_identity);
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try std.posix.read(std.posix.STDIN_FILENO, &buffer);
        if (count == 0) return;
        try writeAll(stream.socket.handle, buffer[0..count]);
    }
}

fn waitForCaptureStop() !void {
    var buffer: [256]u8 = undefined;
    while (true) {
        const count = try std.posix.read(std.posix.STDIN_FILENO, &buffer);
        if (count == 0) return;
    }
}

const LauncherControl = struct {
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    server: *std.Io.net.Server,
    config: LauncherConfig,
    child_pid: std.posix.pid_t,
    done: std.atomic.Value(bool) = .init(false),
    phase: ControlPhase = .awaiting_shell,
    failed: bool = false,

    fn run(self: *LauncherControl) void {
        self.runInner() catch |err| {
            if (err == error.TmuxPeerCancelled and self.done.load(.acquire)) {
                return;
            }
            self.failed = true;
            requestChildTermination(self.child_pid);
            debug_trace.logf(
                "terminal_host",
                "tmux launcher control failed pid={d} err={s}",
                .{ self.child_pid, @errorName(err) },
            );
        };
    }

    fn runInner(self: *LauncherControl) !void {
        var deadlines = MarkerReceptionDeadlines.init();
        while (!self.done.load(.acquire)) {
            const previous_phase = self.phase;
            const finished = receive: {
                var stream = try acceptBeforeDeadline(
                    self.server,
                    deadlines.phase_arrival,
                    &self.done,
                );
                defer stream.close(io_mod.getIo());
                break :receive try self.handleStream(
                    &stream,
                    deadlines.connectedFrame(),
                );
            };
            if (finished) return;
            deadlines.updateAfterMarker(previous_phase, self.phase);
        }
        return error.TmuxPeerCancelled;
    }

    fn handleStream(
        self: *LauncherControl,
        stream: *std.Io.net.Stream,
        deadline: PeerDeadline,
    ) !bool {
        var bytes: [marker_frame_len]u8 = undefined;
        receiveBeforeDeadline(
            stream.socket,
            &bytes,
            deadline,
            &self.done,
        ) catch |err| switch (err) {
            error.EndOfStream => return false,
            else => return err,
        };
        if (!std.mem.eql(
            u8,
            self.config.control_nonce,
            bytes[0..control_nonce_len],
        )) return false;
        const kind: MarkerKind = switch (bytes[control_nonce_len]) {
            1 => .shell_ready,
            2 => .command_started,
            else => return false,
        };
        if (!try self.accept(kind)) return false;
        try writeAll(stream.socket.handle, &.{1});
        return self.phase == .command_started or
            (self.phase == .shell_ready and self.config.command_path == null);
    }

    fn accept(
        self: *LauncherControl,
        kind: MarkerKind,
    ) !bool {
        switch (kind) {
            .shell_ready => {
                if (self.phase != .awaiting_shell) return false;
                std.Io.Dir.deleteFileAbsolute(
                    io_mod.getIo(),
                    self.config.bootstrap_path,
                ) catch {};
                try writeShellIdentity(
                    self.alloc,
                    self.process_provider,
                    self.config.shell_identity_path,
                    self.child_pid,
                );
                try writeLifecycle(
                    self.config.lifecycle_path,
                    .shell_ready,
                    @intCast(self.child_pid),
                );
                self.phase = .shell_ready;
            },
            .command_started => {
                if (self.phase != .shell_ready or
                    self.config.command_path == null) return false;
                std.Io.Dir.deleteFileAbsolute(
                    io_mod.getIo(),
                    self.config.command_path.?,
                ) catch {};
                try writeLifecycle(
                    self.config.lifecycle_path,
                    .command_started,
                    @intCast(self.child_pid),
                );
                try waitForSignalBeforeDeadline(
                    self.config.command_release_path,
                    PeerDeadline.init(command_release_deadline_ms),
                    &self.done,
                );
                self.phase = .command_started;
            },
        }
        return true;
    }
};

fn supported() bool {
    return host_capabilities.terminalSupportForOs(builtin.os.tag).isSupported();
}

test "tmux implementation guard follows canonical platform support" {
    try std.testing.expectEqual(
        host_capabilities.terminalSupportForOs(builtin.os.tag).isSupported(),
        supported(),
    );
}

fn probe(alloc: Allocator) !void {
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "tmux", "-V" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.TmuxUnavailable,
        else => return err,
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        return error.TmuxUnavailable;
    }
    const version = parseVersion(result.stdout) orelse
        return error.TmuxIncompatible;
    if (version.major < minimum_tmux_major or
        (version.major == minimum_tmux_major and version.minor < minimum_tmux_minor))
    {
        return error.TmuxIncompatible;
    }
}

const Version = struct { major: u16, minor: u16 };

fn parseVersion(output: []const u8) ?Version {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "tmux ")) return null;
    const text = trimmed[5..];
    const dot = std.mem.findScalar(u8, text, '.') orelse return null;
    var end = dot + 1;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (dot == 0 or end == dot + 1) return null;
    return .{
        .major = std.fmt.parseInt(u16, text[0..dot], 10) catch return null,
        .minor = std.fmt.parseInt(u16, text[dot + 1 .. end], 10) catch return null,
    };
}

fn ensureNamespace(alloc: Allocator, paths: *const Paths) !void {
    const existing = runTmux(alloc, paths.socket, &.{
        "show-options",
        "-gqv",
        namespace_option,
    }) catch |err| switch (err) {
        error.TmuxCommandFailed => return,
        else => return err,
    };
    defer alloc.free(existing);
    if (!std.mem.eql(
        u8,
        std.mem.trim(u8, existing, " \t\r\n"),
        namespace_value,
    )) return error.ForeignTmuxNamespace;
}

fn ownedSessionPresent(
    alloc: Allocator,
    paths: *const Paths,
    backend_identity: []const u8,
) !bool {
    if (!try privateSocketExists(paths.socket)) return false;
    validateNamespace(alloc, paths, backend_identity) catch |err| switch (err) {
        error.ForeignTmuxNamespace, error.TmuxIdentityMismatch => return error.TmuxRecoveryReplaced,
        error.TmuxCommandFailed => {
            if (!try sessionExists(alloc, paths)) return false;
            return err;
        },
        else => return err,
    };
    return true;
}

const OwnedPaneState = union(enum) {
    missing,
    present: bool,
};

fn validateOwnedPane(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    paths: *const Paths,
    evidence: OwnerEvidence,
) !OwnedPaneState {
    var pane = inspectPane(alloc, paths) catch |err| switch (err) {
        error.TmuxCommandFailed => {
            if (!try sessionExists(alloc, paths)) return .missing;
            return error.TmuxRecoveryReplaced;
        },
        else => return err,
    };
    defer pane.deinit();
    const identity = evidence.processIdentity();
    if (!std.mem.eql(u8, pane.pane_pid, identity.pid)) {
        return error.TmuxRecoveryReplaced;
    }
    switch (evidence) {
        .manifest => |manifest| if (!std.mem.eql(
            u8,
            pane.pane_id,
            manifest.pane_id,
        )) return error.TmuxRecoveryReplaced,
        .process_identity => {},
    }
    if (!pane.dead) {
        const token = process_identity.ProcessInstanceToken.parse(
            identity.process_token,
        ) catch return error.TmuxRecoveryReplaced;
        switch (process_provider.matchToken(alloc, pane.pane_pid, token)) {
            .matched => {},
            .missing, .mismatched => return error.TmuxRecoveryReplaced,
            .unavailable => return error.TmuxRecoveryIdentityUnavailable,
        }
    }
    return .{ .present = pane.dead };
}

fn validateNamespace(
    alloc: Allocator,
    paths: *const Paths,
    backend_identity: []const u8,
) !void {
    const value = try runTmux(alloc, paths.socket, &.{
        "show-options",
        "-gqv",
        namespace_option,
    });
    defer alloc.free(value);
    if (!std.mem.eql(
        u8,
        std.mem.trim(u8, value, " \t\r\n"),
        namespace_value,
    )) return error.ForeignTmuxNamespace;
    const identity = try runTmux(alloc, paths.socket, &.{
        "show-options",
        "-qv",
        "-t",
        paths.session_name,
        namespace_option,
    });
    defer alloc.free(identity);
    if (!std.mem.eql(
        u8,
        std.mem.trim(u8, identity, " \t\r\n"),
        backend_identity,
    )) {
        return error.TmuxIdentityMismatch;
    }
}

fn sessionExists(alloc: Allocator, paths: *const Paths) !bool {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try appendTmuxPrefix(&argv, alloc, paths.socket);
    try argv.appendSlice(alloc, &.{
        "has-session",
        "-t",
        paths.session_name,
    });
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv.items,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (result.term != .exited) return error.TmuxCommandFailed;
    return switch (result.term.exited) {
        0 => true,
        1 => false,
        else => error.TmuxCommandFailed,
    };
}

fn inspectPane(alloc: Allocator, paths: *const Paths) !Pane {
    const format = "#{session_name}|#{window_name}|#{pane_id}|#{pane_pid}|#{pane_dead}|#{pane_dead_status}|#{pane_width}|#{pane_height}|#{cursor_y}|#{cursor_x}|#{cursor_flag}|#{cursor_shape}|#{cursor_blinking}|#{alternate_on}|#{origin_flag}|#{wrap_flag}|#{insert_flag}|#{mouse_standard_flag}|#{mouse_button_flag}|#{mouse_any_flag}|#{keypad_cursor_flag}|#{keypad_flag}";
    const output = try runTmux(alloc, paths.socket, &.{
        "display-message",
        "-p",
        "-t",
        paths.target,
        format,
    });
    defer alloc.free(output);
    const trimmed = std.mem.trim(u8, output, "\r\n");
    var fields = std.mem.splitScalar(u8, trimmed, '|');
    const session_name = fields.next() orelse return error.MalformedTmuxPane;
    const window_name = fields.next() orelse return error.MalformedTmuxPane;
    const pane_id = fields.next() orelse return error.MalformedTmuxPane;
    const pane_pid = fields.next() orelse return error.MalformedTmuxPane;
    const dead_text = fields.next() orelse return error.MalformedTmuxPane;
    const dead_status_text = fields.next() orelse return error.MalformedTmuxPane;
    const columns_text = fields.next() orelse return error.MalformedTmuxPane;
    const rows_text = fields.next() orelse return error.MalformedTmuxPane;
    const cursor_row_text = fields.next() orelse return error.MalformedTmuxPane;
    const cursor_column_text = fields.next() orelse return error.MalformedTmuxPane;
    const cursor_visible_text = fields.next() orelse return error.MalformedTmuxPane;
    const cursor_shape_text = fields.next() orelse return error.MalformedTmuxPane;
    const cursor_blinking_text = fields.next() orelse return error.MalformedTmuxPane;
    const alternate_screen_text = fields.next() orelse return error.MalformedTmuxPane;
    const origin_text = fields.next() orelse return error.MalformedTmuxPane;
    const autowrap_text = fields.next() orelse return error.MalformedTmuxPane;
    const insert_text = fields.next() orelse return error.MalformedTmuxPane;
    const mouse_standard_text = fields.next() orelse return error.MalformedTmuxPane;
    const mouse_button_text = fields.next() orelse return error.MalformedTmuxPane;
    const mouse_any_text = fields.next() orelse return error.MalformedTmuxPane;
    const application_cursor_text = fields.next() orelse return error.MalformedTmuxPane;
    const application_keypad_text = fields.next() orelse return error.MalformedTmuxPane;
    if (fields.next() != null or
        !std.mem.eql(u8, session_name, paths.session_name) or
        !std.mem.eql(u8, window_name, "terminal") or
        pane_id.len < 2 or pane_id[0] != '%' or
        pane_pid.len == 0)
    {
        return error.MalformedTmuxPane;
    }
    const dead = if (std.mem.eql(u8, dead_text, "0"))
        false
    else if (std.mem.eql(u8, dead_text, "1"))
        true
    else
        return error.MalformedTmuxPane;
    const dead_status = if (dead_status_text.len == 0)
        null
    else
        try std.fmt.parseInt(u32, dead_status_text, 10);
    const dimensions = contracts.Dimensions{
        .rows = try std.fmt.parseInt(u16, rows_text, 10),
        .columns = try std.fmt.parseInt(u16, columns_text, 10),
    };
    try dimensions.validate();
    const pane_id_owned = try alloc.dupe(u8, pane_id);
    errdefer alloc.free(pane_id_owned);
    return .{
        .alloc = alloc,
        .pane_id = pane_id_owned,
        .pane_pid = try alloc.dupe(u8, pane_pid),
        .dead = dead,
        .dead_status = dead_status,
        .dimensions = dimensions,
        .cursor_row = try std.fmt.parseInt(u16, cursor_row_text, 10),
        .cursor_column = try std.fmt.parseInt(u16, cursor_column_text, 10),
        .cursor_visible = try parseTmuxBool(cursor_visible_text),
        .cursor_shape = try parseTmuxCursorShape(cursor_shape_text),
        .cursor_blinking = try parseTmuxCursorBlinking(cursor_blinking_text),
        .alternate_screen = try parseTmuxBool(alternate_screen_text),
        .origin = try parseTmuxBool(origin_text),
        .autowrap = try parseTmuxBool(autowrap_text),
        .insert = try parseTmuxBool(insert_text),
        .mouse_tracking = try parseTmuxBool(mouse_standard_text) or
            try parseTmuxBool(mouse_button_text) or
            try parseTmuxBool(mouse_any_text),
        .application_cursor_keys = try parseTmuxBool(application_cursor_text),
        .application_keypad = try parseTmuxBool(application_keypad_text),
    };
}

fn parseTmuxBool(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "0")) return false;
    if (std.mem.eql(u8, text, "1")) return true;
    return error.MalformedTmuxPane;
}

fn parseTmuxCursorShape(text: []const u8) !contracts.CursorShape {
    if (text.len == 0 or
        std.mem.eql(u8, text, "default") or
        std.mem.eql(u8, text, "block")) return .block;
    if (std.mem.eql(u8, text, "underline")) return .underline;
    if (std.mem.eql(u8, text, "bar")) return .bar;
    return error.MalformedTmuxPane;
}

fn parseTmuxCursorBlinking(text: []const u8) !bool {
    if (text.len == 0) return false;
    return parseTmuxBool(text);
}

test "older tmux cursor formats use compatible defaults" {
    try std.testing.expectEqual(
        contracts.CursorShape.block,
        try parseTmuxCursorShape(""),
    );
    try std.testing.expect(!try parseTmuxCursorBlinking(""));
    try std.testing.expect(try parseTmuxCursorBlinking("1"));
}

fn runTmuxNoOutput(
    alloc: Allocator,
    socket: []const u8,
    args: []const []const u8,
) !void {
    const output = try runTmux(alloc, socket, args);
    alloc.free(output);
}

/// Returns owned stdout; caller frees with `alloc`.
fn runTmux(
    alloc: Allocator,
    socket: []const u8,
    args: []const []const u8,
) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try appendTmuxPrefix(&argv, alloc, socket);
    try argv.appendSlice(alloc, args);
    const result = std.process.run(alloc, io_mod.getIo(), .{
        .argv = argv.items,
        .stdout_limit = .limited(max_command_output_bytes),
        .stderr_limit = .limited(max_command_output_bytes),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.TmuxUnavailable,
        else => return err,
    };
    defer alloc.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        alloc.free(result.stdout);
        return error.TmuxCommandFailed;
    }
    return result.stdout;
}

fn cleanupSocketIfUnused(alloc: Allocator, socket: []const u8) void {
    const remaining = runTmux(alloc, socket, &.{"list-sessions"}) catch {
        cleanupPrivateSocket(socket);
        return;
    };
    alloc.free(remaining);
}

fn cleanupSocketIfUnusedChecked(alloc: Allocator, socket: []const u8) !void {
    if (!try privateSocketExists(socket)) return;
    const remaining = runTmux(alloc, socket, &.{"list-sessions"}) catch |err| {
        if (!try privateSocketExists(socket)) return;
        if (err == error.TmuxCommandFailed and
            !try privateSocketHasListener(socket))
        {
            std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), socket) catch |delete_err| switch (delete_err) {
                error.FileNotFound => {},
                else => return delete_err,
            };
            return;
        }
        return err;
    };
    defer alloc.free(remaining);
    if (std.mem.trim(u8, remaining, " \t\r\n").len != 0) return;
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), socket) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn privateSocketHasListener(socket: []const u8) !bool {
    if (socket.len >= @sizeOf(@FieldType(std.c.sockaddr.un, "path"))) {
        return error.InvalidTmuxSocketPath;
    }
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.TmuxSocketProbeFailed;
    defer _ = std.c.close(fd);
    if (std.c.fcntl(
        fd,
        std.c.F.SETFD,
        @as(usize, std.c.FD_CLOEXEC),
    ) != 0) return error.TmuxSocketProbeFailed;
    var socket_address: std.c.sockaddr.un = .{
        .family = std.c.AF.UNIX,
        .path = @splat(0),
    };
    @memcpy(socket_address.path[0..socket.len], socket);
    const address_len: std.c.socklen_t = @intCast(
        @offsetOf(std.c.sockaddr.un, "path") + socket.len + 1,
    );
    if (@hasField(std.c.sockaddr.un, "len")) {
        socket_address.len = @intCast(address_len);
    }
    const result = std.c.connect(fd, @ptrCast(&socket_address), address_len);
    if (result == 0) return true;
    return switch (std.c.errno(result)) {
        .CONNREFUSED, .NOENT => false,
        else => error.TmuxSocketProbeFailed,
    };
}

fn privateSocketExists(socket: []const u8) !bool {
    const stat = std.Io.Dir.cwd().statFile(
        io_mod.getIo(),
        socket,
        .{ .follow_symlinks = false },
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .unix_domain_socket or
        stat.permissions.toMode() & 0o777 != 0o600)
    {
        return error.PrivateTmuxEndpointRequired;
    }
    return true;
}

fn cleanupPrivateSocket(socket: []const u8) void {
    if (!(privateSocketExists(socket) catch false)) return;
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), socket) catch {};
}

fn appendTmuxPrefix(
    argv: *std.ArrayList([]const u8),
    alloc: Allocator,
    socket: []const u8,
) !void {
    try argv.appendSlice(alloc, &.{ "tmux", "-S", socket, "-f", "/dev/null" });
}

fn killSessionAt(
    alloc: Allocator,
    socket: []const u8,
    session_name: []const u8,
) void {
    runTmuxNoOutput(alloc, socket, &.{
        "kill-session",
        "-t",
        session_name,
    }) catch {};
}

fn requireSessionAbsent(alloc: Allocator, paths: *const Paths) !void {
    if (!try privateSocketExists(paths.socket)) return;
    if (try sessionExists(alloc, paths)) return error.TmuxCleanupIncomplete;
}

fn requireSavedPaneProcessAbsent(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    evidence: OwnerEvidence,
) !void {
    const identity = evidence.processIdentity();
    const token = process_identity.ProcessInstanceToken.parse(
        identity.process_token,
    ) catch return error.TmuxRecoveryReplaced;
    switch (process_provider.matchToken(alloc, identity.pid, token)) {
        .matched => return error.TmuxCleanupIncomplete,
        .missing, .mismatched => {},
        .unavailable => return error.TmuxRecoveryIdentityUnavailable,
    }
}

fn requireOwnedNamespaceAbsent(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    paths: *const Paths,
    evidence: OwnerEvidence,
) !void {
    try requireSessionAbsent(alloc, paths);
    try requireSavedPaneProcessAbsent(alloc, process_provider, evidence);
}

fn waitForOwnedNamespaceAbsent(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    paths: *const Paths,
    evidence: OwnerEvidence,
) !void {
    const started_at = io_mod.milliTimestamp();
    while (true) {
        requireOwnedNamespaceAbsent(
            alloc,
            process_provider,
            paths,
            evidence,
        ) catch |err| switch (err) {
            error.TmuxCleanupIncomplete => {
                if (io_mod.milliTimestamp() - started_at >= cleanup_settle_deadline_ms) {
                    return err;
                }
                io_mod.sleep(poll_ns);
                continue;
            },
            else => return err,
        };
        return;
    }
}

fn writeLauncherConfig(
    alloc: Allocator,
    path: []const u8,
    config: LauncherConfig,
) !void {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try std.json.Stringify.value(config, .{}, &output.writer);
    if (output.written().len > max_launcher_config_bytes) {
        return error.TmuxLauncherConfigTooLarge;
    }
    try writePrivateFile(path, output.written(), true);
}

fn writeManifest(
    alloc: Allocator,
    path: []const u8,
    manifest: ManifestWire,
) !void {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try std.json.Stringify.value(manifest, .{}, &output.writer);
    try writePrivateFile(path, output.written(), true);
}

fn loadManifest(alloc: Allocator, path: []const u8) !ManifestWire {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, 4096);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(
        ManifestWire,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    if (parsed.value.schema_version != 1 or
        !validBackendIdentity(parsed.value.backend_identity))
    {
        return error.MalformedTmuxManifest;
    }
    return ownManifest(alloc, parsed.value);
}

fn loadOwnedManifest(
    alloc: Allocator,
    paths: *const Paths,
    backend_identity: []const u8,
) !ManifestWire {
    const manifest = loadManifest(alloc, paths.manifest) catch |err| switch (err) {
        error.FileNotFound => return error.TmuxRecoveryManifestMissing,
        else => return err,
    };
    errdefer {
        var owned = manifest;
        deinitManifest(alloc, &owned);
    }
    if (!std.mem.eql(u8, manifest.backend_identity, backend_identity) or
        !std.mem.eql(u8, manifest.session_name, paths.session_name))
    {
        return error.TmuxRecoveryReplaced;
    }
    return manifest;
}

fn ownManifest(alloc: Allocator, value: ManifestWire) !ManifestWire {
    const backend_identity = try alloc.dupe(u8, value.backend_identity);
    errdefer alloc.free(backend_identity);
    const session_name = try alloc.dupe(u8, value.session_name);
    errdefer alloc.free(session_name);
    const pane_id = try alloc.dupe(u8, value.pane_id);
    errdefer alloc.free(pane_id);
    const pane_pid = try alloc.dupe(u8, value.pane_pid);
    errdefer alloc.free(pane_pid);
    return .{
        .backend_identity = backend_identity,
        .session_name = session_name,
        .pane_id = pane_id,
        .pane_pid = pane_pid,
        .pane_process_token = try alloc.dupe(u8, value.pane_process_token),
    };
}

fn deinitManifest(alloc: Allocator, manifest: *ManifestWire) void {
    alloc.free(manifest.pane_process_token);
    alloc.free(manifest.pane_pid);
    alloc.free(manifest.pane_id);
    alloc.free(manifest.session_name);
    alloc.free(manifest.backend_identity);
    manifest.* = undefined;
}

fn validateLauncherConfig(config: LauncherConfig) !void {
    if (config.argv.len == 0 or
        !std.fs.path.isAbsolute(config.cwd) or
        !std.fs.path.isAbsolute(config.control_path) or
        !std.fs.path.isAbsolute(config.bootstrap_path) or
        !std.fs.path.isAbsolute(config.lifecycle_path) or
        !std.fs.path.isAbsolute(config.shell_identity_path) or
        !std.fs.path.isAbsolute(config.manifest_ready_path) or
        !std.fs.path.isAbsolute(config.release_path) or
        !std.fs.path.isAbsolute(config.command_release_path) or
        !std.fs.path.isAbsolute(config.tmux_socket) or
        config.tmux_target.len == 0 or
        config.control_nonce.len != control_nonce_len or
        (config.command == null) != (config.command_path == null) or
        (config.command == null) != (config.interactive_source != null))
    {
        return error.InvalidTmuxLauncherConfig;
    }
    if (config.command_path) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidTmuxLauncherConfig;
    }
}

fn writeLifecycle(path: []const u8, kind: LifecycleKind, value: u32) !void {
    var bytes: [5]u8 = undefined;
    bytes[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, bytes[1..5], value, .little);
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
        .truncate = false,
        .permissions = private_file_permissions,
        .lock = .exclusive,
    });
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.size + bytes.len > max_lifecycle_bytes) {
        return error.TmuxLifecycleTooLarge;
    }
    _ = std.c.lseek(file.handle, 0, std.posix.SEEK.END);
    try file.writeStreamingAll(io_mod.getIo(), &bytes);
    try file.sync(io_mod.getIo());
}

fn writeShellIdentity(
    alloc: Allocator,
    process_provider: process_provider_mod.Provider,
    path: []const u8,
    pid: std.posix.pid_t,
) !void {
    var pid_buffer: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid});
    const token = try process_provider.captureToken(
        alloc,
        pid_text,
    );
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try std.json.Stringify.value(ShellIdentityWire{
        .pid = @intCast(pid),
        .process_token = token.view(),
    }, .{}, &output.writer);
    try writePrivateFile(path, output.written(), true);
}

fn loadShellIdentity(alloc: Allocator, path: []const u8) !ShellIdentity {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, 4096);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(
        ShellIdentityWire,
        alloc,
        bytes,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const pid = std.math.cast(std.posix.pid_t, parsed.value.pid) orelse
        return error.MalformedTmuxShellIdentity;
    if (pid <= 0) return error.MalformedTmuxShellIdentity;
    return .{
        .pid = pid,
        .process_token = process_identity.ProcessInstanceToken.parse(
            parsed.value.process_token,
        ) catch return error.MalformedTmuxShellIdentity,
    };
}

fn readLifecycle(alloc: Allocator, path: []const u8) ![]LifecycleFrame {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_lifecycle_bytes);
    defer alloc.free(bytes);
    if (bytes.len == 0 or bytes.len % 5 != 0) return error.MalformedTmuxLifecycle;
    const frames = try alloc.alloc(LifecycleFrame, bytes.len / 5);
    errdefer alloc.free(frames);
    for (frames, 0..) |*frame, index| {
        const start = index * 5;
        var value_bytes: [4]u8 = undefined;
        @memcpy(&value_bytes, bytes[start + 1 .. start + 5]);
        frame.* = .{
            .kind = switch (bytes[start]) {
                1 => .prepared,
                2 => .shell_ready,
                3 => .command_started,
                4 => .command_exited,
                5 => .command_signal,
                6 => .startup_failed,
                7 => .invalid_term,
                else => return error.MalformedTmuxLifecycle,
            },
            .value = std.mem.readInt(u32, &value_bytes, .little),
        };
    }
    if (frames[0].kind != .prepared) return error.MalformedTmuxLifecycle;
    var phase: enum { prepared, shell_ready, command_started, terminal } = .prepared;
    for (frames[1..], 1..) |frame, index| {
        phase = switch (phase) {
            .prepared => switch (frame.kind) {
                .shell_ready => .shell_ready,
                .startup_failed, .invalid_term => .terminal,
                else => return error.MalformedTmuxLifecycle,
            },
            .shell_ready => switch (frame.kind) {
                .command_started => .command_started,
                .command_exited,
                .command_signal,
                .startup_failed,
                .invalid_term,
                => .terminal,
                else => return error.MalformedTmuxLifecycle,
            },
            .command_started => switch (frame.kind) {
                .command_exited,
                .command_signal,
                .startup_failed,
                .invalid_term,
                => .terminal,
                else => return error.MalformedTmuxLifecycle,
            },
            .terminal => return error.MalformedTmuxLifecycle,
        };
        if (phase == .terminal and index + 1 != frames.len) {
            return error.MalformedTmuxLifecycle;
        }
    }
    return frames;
}

fn writePrivateFile(path: []const u8, bytes: []const u8, truncate: bool) !void {
    var file = try std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{
        .truncate = truncate,
        .permissions = private_file_permissions,
    });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), bytes);
    try file.sync(io_mod.getIo());
}

fn createPrivateSignal(path: []const u8) !void {
    try writePrivateFile(path, "1", true);
}

fn waitForSignal(path: []const u8) !void {
    while (true) {
        std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                io_mod.sleep(poll_ns);
                continue;
            },
            else => return err,
        };
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};
        return;
    }
}

fn waitForSignalBeforeDeadline(
    path: []const u8,
    deadline: PeerDeadline,
    cancelled: *const std.atomic.Value(bool),
) !void {
    while (true) {
        if (cancelled.load(.acquire)) return error.TmuxPeerCancelled;
        const remaining_ms = try deadline.remaining();
        std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                io_mod.sleep(@as(u64, @intCast(@min(
                    remaining_ms,
                    @as(i64, @intCast(poll_ns / std.time.ns_per_ms)),
                ))) * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};
        return;
    }
}

fn cleanupFiles(paths: *const Paths) void {
    const files = [_][]const u8{
        paths.config,
        paths.lifecycle,
        paths.shell_identity,
        paths.manifest,
        paths.manifest_ready,
        paths.release,
        paths.command_release,
        paths.bootstrap,
        paths.command,
        paths.marker_socket,
        paths.capture_socket,
    };
    for (files) |path| {
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch {};
    }
}

fn cleanupFilesChecked(paths: *const Paths) !void {
    const files = [_][]const u8{
        paths.config,
        paths.lifecycle,
        paths.shell_identity,
        paths.manifest,
        paths.manifest_ready,
        paths.release,
        paths.command_release,
        paths.bootstrap,
        paths.command,
        paths.marker_socket,
        paths.capture_socket,
    };
    for (files) |path| {
        std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn artifactPath(
    alloc: Allocator,
    root: []const u8,
    identity: []const u8,
    suffix: []const u8,
) ![]u8 {
    const name = try std.fmt.allocPrint(
        alloc,
        "tmux-{s}-{s}",
        .{ identity, suffix },
    );
    defer alloc.free(name);
    return std.fs.path.join(alloc, &.{ root, name });
}

fn validBackendIdentity(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) {
            return false;
        }
    }
    return true;
}

fn quoteShellWord(alloc: Allocator, value: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(alloc);
    try result.append(alloc, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try result.appendSlice(alloc, "'\\''");
        } else {
            try result.append(alloc, byte);
        }
    }
    try result.append(alloc, '\'');
    return result.toOwnedSlice(alloc);
}

fn formatU16(alloc: Allocator, value: u16) ![]u8 {
    return std.fmt.allocPrint(alloc, "{d}", .{value});
}

fn monotonicMillis() i64 {
    const timestamp = std.Io.Clock.awake.now(io_mod.getIo());
    return @intCast(@divFloor(timestamp.nanoseconds, std.time.ns_per_ms));
}

fn acceptBeforeDeadline(
    server: *std.Io.net.Server,
    deadline: PeerDeadline,
    cancelled: ?*const std.atomic.Value(bool),
) !std.Io.net.Stream {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = server.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    while (true) {
        if (cancelled) |value| {
            if (value.load(.acquire)) return error.TmuxPeerCancelled;
        }
        const remaining_ms = try deadline.remaining();
        poll_fds[0].revents = 0;
        if (try std.posix.poll(
            &poll_fds,
            @intCast(@min(remaining_ms, deadline_poll_ms)),
        ) == 0) continue;
        if ((poll_fds[0].revents & std.posix.POLL.IN) == 0) {
            return error.TmuxPeerUnavailable;
        }
        return server.accept(io_mod.getIo()) catch |err| switch (err) {
            error.ConnectionAborted, error.WouldBlock => continue,
            else => return err,
        };
    }
}

fn receiveBeforeDeadline(
    socket: std.Io.net.Socket,
    destination: []u8,
    deadline: PeerDeadline,
    cancelled: ?*const std.atomic.Value(bool),
) !void {
    var offset: usize = 0;
    while (offset < destination.len) {
        if (cancelled) |value| {
            if (value.load(.acquire)) return error.TmuxPeerCancelled;
        }
        const remaining_ms = try deadline.remaining();
        const incoming = socket.receiveTimeout(
            io_mod.getIo(),
            destination[offset..],
            .{ .duration = .{
                .clock = .awake,
                .raw = .fromMilliseconds(@min(
                    remaining_ms,
                    deadline_poll_ms,
                )),
            } },
        ) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        if (incoming.data.len == 0) return error.EndOfStream;
        offset += incoming.data.len;
    }
}

fn assignForegroundProcessGroup(fd: c_int, pgrp: std.posix.pid_t) bool {
    if (io_mod.getenv("FX_TERMINAL_TEST_TMUX_TCSETPGRP_FAILURE") != null) {
        return false;
    }
    return tcsetpgrp(fd, pgrp) == 0;
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
                if (signal == std.c.SIG.TTIN) {
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

fn requestChildTermination(child_pid: std.posix.pid_t) void {
    const group_kill_succeeded =
        io_mod.getenv("FX_TERMINAL_TEST_TMUX_GROUP_KILL_FAILURE") == null and
        std.c.kill(-child_pid, std.c.SIG.KILL) == 0;
    if (group_kill_succeeded) return;

    const direct_kill_succeeded = std.c.kill(child_pid, std.c.SIG.KILL) == 0;
    debug_trace.logf(
        "terminal_host",
        "tmux child group termination failed pid={d} direct_kill_succeeded={any}",
        .{ child_pid, direct_kill_succeeded },
    );
}

fn terminateAndReapChild(child: *std.process.Child) void {
    const child_pid = child.id orelse return;
    requestChildTermination(child_pid);
    _ = child.wait(io_mod.getIo()) catch null;
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = std.c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (count < 0) {
            if (std.c.errno(count) == .INTR) continue;
            return error.WriteFailed;
        }
        if (count == 0) return error.WriteZero;
        offset += @intCast(count);
    }
}

extern "c" fn tcsetpgrp(fd: c_int, pgrp: std.posix.pid_t) c_int;

test "tmux launcher wait status classifies terminal results before stops" {
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
    const unknown_status: u32 = switch (builtin.os.tag) {
        .linux => 0x101,
        .macos => 0x137f,
        else => return error.SkipZigTest,
    };
    try std.testing.expectEqual(
        std.process.Child.Term{ .unknown = unknown_status },
        launcherStatusToTerm(unknown_status),
    );
}

test "tmux marker arrival deadlines follow authenticated phase transitions" {
    try std.testing.expectEqual(@as(i64, 60_000), marker_shell_start_deadline_ms);
    try std.testing.expectEqual(
        marker_acknowledgement_timeout_ms - marker_acknowledgement_delivery_margin_ms,
        marker_command_arrival_deadline_ms,
    );
    try std.testing.expectEqual(
        marker_acknowledgement_timeout_ms - marker_acknowledgement_delivery_margin_ms,
        marker_connected_frame_deadline_ms,
    );
    try std.testing.expectEqual(
        marker_acknowledgement_timeout_ms - marker_acknowledgement_delivery_margin_ms,
        command_release_deadline_ms,
    );

    var deadlines = MarkerReceptionDeadlines.init();
    const awaiting_shell_expiry = deadlines.phase_arrival.expires_ms;
    _ = deadlines.connectedFrame();
    deadlines.updateAfterMarker(.awaiting_shell, .awaiting_shell);
    try std.testing.expectEqual(
        awaiting_shell_expiry,
        deadlines.phase_arrival.expires_ms,
    );

    deadlines.phase_arrival.expires_ms -= 1;
    const aged_phase_expiry = deadlines.phase_arrival.expires_ms;
    deadlines.updateAfterMarker(.awaiting_shell, .shell_ready);
    try std.testing.expect(
        deadlines.phase_arrival.expires_ms < aged_phase_expiry,
    );

    const awaiting_command_expiry = deadlines.phase_arrival.expires_ms;
    _ = deadlines.connectedFrame();
    deadlines.updateAfterMarker(.shell_ready, .shell_ready);
    try std.testing.expectEqual(
        awaiting_command_expiry,
        deadlines.phase_arrival.expires_ms,
    );
}

test "tmux peer deadline bounds accept receive partial frames and cancellation" {
    if (!supported()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const socket_path = try std.fmt.allocPrint(
        alloc,
        "/tmp/fx-peer-deadline-{d}.sock",
        .{std.c.getpid()},
    );
    defer alloc.free(socket_path);
    std.Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};

    var cancelled = std.atomic.Value(bool).init(true);
    try std.testing.expectError(
        error.TmuxPeerCancelled,
        acceptBeforeDeadline(&server, PeerDeadline.init(100), &cancelled),
    );
    try std.testing.expectError(
        error.TmuxPeerTimeout,
        acceptBeforeDeadline(&server, PeerDeadline.init(10), null),
    );

    var handles: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &handles) != 0) {
        return error.SocketPairFailed;
    }
    var receiver = std.Io.net.Socket{
        .handle = handles[0],
        .address = undefined,
    };
    defer receiver.close(std.testing.io);
    var sender_open = true;
    defer if (sender_open) {
        _ = std.c.close(handles[1]);
    };
    var bytes: [marker_frame_len]u8 = undefined;
    try std.testing.expectError(
        error.TmuxPeerTimeout,
        receiveBeforeDeadline(
            receiver,
            &bytes,
            PeerDeadline.init(10),
            null,
        ),
    );

    try writeAll(handles[1], "partial");
    _ = std.c.close(handles[1]);
    sender_open = false;
    try std.testing.expectError(
        error.EndOfStream,
        receiveBeforeDeadline(
            receiver,
            &bytes,
            PeerDeadline.init(100),
            null,
        ),
    );

    try std.testing.expectError(
        error.TmuxPeerCancelled,
        receiveBeforeDeadline(
            receiver,
            &bytes,
            PeerDeadline.init(100),
            &cancelled,
        ),
    );
}

test "checked tmux cleanup requires saved process absence without a socket" {
    const alloc = std.testing.allocator;
    const MatchStub = struct {
        result: process_identity.TokenMatch,
        matches_before_result: usize = 0,
        match_calls: usize = 0,

        fn match(
            raw: ?*anyopaque,
            _: Allocator,
            _: []const u8,
            _: process_identity.ProcessInstanceToken,
        ) process_identity.TokenMatch {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.match_calls += 1;
            if (self.matches_before_result > 0) {
                self.matches_before_result -= 1;
                return .matched;
            }
            return self.result;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const durable_root = try std.fs.path.join(alloc, &.{ root, "durable" });
    defer alloc.free(durable_root);
    const transport_root = try std.fs.path.join(alloc, &.{ root, "transport" });
    defer alloc.free(transport_root);
    try std.Io.Dir.createDirAbsolute(std.testing.io, durable_root, .default_dir);
    try std.Io.Dir.createDirAbsolute(std.testing.io, transport_root, .default_dir);
    const identity = "0123456789abcdef0123456789abcdef";
    var paths = try Paths.init(
        alloc,
        durable_root,
        transport_root,
        identity,
    );
    defer paths.deinit(alloc);
    const manifest = ManifestWire{
        .backend_identity = identity,
        .session_name = paths.session_name,
        .pane_id = "%1",
        .pane_pid = "4242",
        .pane_process_token = "macos:0123456789abcdef0123456789abcdef:1:1",
    };
    try writeManifest(alloc, paths.manifest, manifest);
    try writePrivateFile(paths.config, "owner evidence", true);

    var stub = MatchStub{ .result = .matched };
    var provider = process_provider_mod.unavailable_provider;
    provider.context = &stub;
    provider.match_token_fn = MatchStub.match;
    try std.testing.expectError(
        error.TmuxCleanupIncomplete,
        cleanupOwnedNamespaceChecked(
            alloc,
            provider,
            durable_root,
            transport_root,
            identity,
            null,
        ),
    );
    try std.Io.Dir.accessAbsolute(std.testing.io, paths.manifest, .{});
    try std.Io.Dir.accessAbsolute(std.testing.io, paths.config, .{});

    stub.result = .unavailable;
    try std.testing.expectError(
        error.TmuxRecoveryIdentityUnavailable,
        cleanupOwnedNamespaceChecked(
            alloc,
            provider,
            durable_root,
            transport_root,
            identity,
            null,
        ),
    );
    try std.Io.Dir.accessAbsolute(std.testing.io, paths.manifest, .{});

    try std.Io.Dir.deleteFileAbsolute(std.testing.io, paths.config);
    stub.result = .missing;
    try std.Io.Dir.createDirAbsolute(std.testing.io, paths.config, .default_dir);
    var storage_error: ?anyerror = null;
    cleanupOwnedNamespaceChecked(
        alloc,
        provider,
        durable_root,
        transport_root,
        identity,
        null,
    ) catch |err| {
        storage_error = err;
    };
    try std.testing.expect(storage_error != null);
    try std.Io.Dir.accessAbsolute(std.testing.io, paths.manifest, .{});
    try std.Io.Dir.deleteDirAbsolute(std.testing.io, paths.config);

    try cleanupOwnedNamespaceChecked(
        alloc,
        provider,
        durable_root,
        transport_root,
        identity,
        null,
    );
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.accessAbsolute(std.testing.io, paths.manifest, .{}),
    );

    try writeManifest(alloc, paths.manifest, manifest);
    stub.result = .mismatched;
    try cleanupOwnedNamespaceChecked(
        alloc,
        provider,
        durable_root,
        transport_root,
        identity,
        null,
    );
    try std.testing.expectError(
        error.TmuxRecoveryManifestMissing,
        cleanupOwnedNamespaceChecked(
            alloc,
            provider,
            durable_root,
            transport_root,
            identity,
            null,
        ),
    );

    const recovered_identity = AuthenticatedProcessIdentity{
        .pid = manifest.pane_pid,
        .process_token = manifest.pane_process_token,
    };
    stub.result = .matched;
    try std.testing.expectError(
        error.TmuxCleanupIncomplete,
        cleanupOwnedNamespaceChecked(
            alloc,
            provider,
            durable_root,
            transport_root,
            identity,
            recovered_identity,
        ),
    );
    stub.result = .missing;
    stub.matches_before_result = 2;
    const settling_match_calls = stub.match_calls;
    try cleanupOwnedNamespaceChecked(
        alloc,
        provider,
        durable_root,
        transport_root,
        identity,
        recovered_identity,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        stub.match_calls - settling_match_calls,
    );
}

test "tmux version parsing is bounded and accepts release suffixes" {
    try std.testing.expectEqual(
        Version{ .major = 3, .minor = 6 },
        parseVersion("tmux 3.6a\n").?,
    );
    try std.testing.expectEqual(
        Version{ .major = 3, .minor = 2 },
        parseVersion("tmux 3.2\n").?,
    );
    try std.testing.expect(parseVersion("tmux next") == null);
    try std.testing.expect(parseVersion("3.6") == null);
}

test "tmux backend identity and shell quoting remain deterministic" {
    const alloc = std.testing.allocator;
    const identity = "0123456789abcdef0123456789abcdef";
    try std.testing.expect(validBackendIdentity(identity));
    try std.testing.expect(!validBackendIdentity("short"));
    const quoted = try quoteShellWord(alloc, "/tmp/a'b");
    defer alloc.free(quoted);
    try std.testing.expectEqualStrings("'/tmp/a'\\''b'", quoted);
}

test "tmux paths keep artifacts durable and place only the server socket in transport" {
    const alloc = std.testing.allocator;
    const durable_root = "/profiles/example/.fx/terminal-host";
    const transport_root = "/tmp/fx-terminal-501-profile";
    const identity = "0123456789abcdef0123456789abcdef";
    var paths = try Paths.init(
        alloc,
        durable_root,
        transport_root,
        identity,
    );
    defer paths.deinit(alloc);

    try std.testing.expectEqualStrings(
        "/tmp/fx-terminal-501-profile/tmux.sock",
        paths.socket,
    );
    for ([_][]const u8{
        paths.config,
        paths.lifecycle,
        paths.shell_identity,
        paths.manifest,
        paths.manifest_ready,
        paths.release,
        paths.command_release,
        paths.bootstrap,
        paths.command,
    }) |artifact| {
        try std.testing.expect(std.mem.startsWith(u8, artifact, durable_root));
        try std.testing.expect(!std.mem.startsWith(u8, artifact, transport_root));
    }
}

test "lifecycle parser rejects partial and reordered control history" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const path = try std.fs.path.join(alloc, &.{ root, "lifecycle.bin" });
    defer alloc.free(path);
    try writePrivateFile(path, &.{ @intFromEnum(LifecycleKind.prepared), 0, 0, 0 }, true);
    try std.testing.expectError(
        error.MalformedTmuxLifecycle,
        readLifecycle(alloc, path),
    );
    try std.Io.Dir.deleteFileAbsolute(std.testing.io, path);
    try writeLifecycle(path, .prepared, 0);
    try writeLifecycle(path, .shell_ready, 42);
    const frames = try readLifecycle(alloc, path);
    defer alloc.free(frames);
    try std.testing.expectEqual(@as(usize, 2), frames.len);
    try std.testing.expectEqual(LifecycleFrame{
        .kind = .shell_ready,
        .value = 42,
    }, frames[1]);

    try writePrivateFile(path, "", true);
    try writeLifecycle(path, .prepared, 0);
    try writeLifecycle(path, .command_started, 42);
    try std.testing.expectError(
        error.MalformedTmuxLifecycle,
        readLifecycle(alloc, path),
    );
}
