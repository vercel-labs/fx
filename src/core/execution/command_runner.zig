const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const command_contract = @import("command_contract.zig");
const command_environment = @import("command_environment.zig");
const process_tree = @import("process_tree.zig");
const background_process_provider = @import(
    "background_process_provider.zig",
);
const io_mod = @import("../shared/io.zig");
const self_exe = @import("../shared/self_exe.zig");
const background_launch_output = @import("../background/background_launch_output.zig");
const config_runtime = @import("../config/config_runtime.zig");
const session_child_store = @import("../session/session_child_store.zig");
const artifact_digest = @import("../session/artifact_digest.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");
const shell_resolver = @import("../terminal/shell_resolver.zig");

const Allocator = std.mem.Allocator;
pub const CommandOutputStream = command_contract.CommandOutputStream;
pub const CommandOutputCallback = command_contract.CommandOutputCallback;
pub const CommandExecutionResult = command_contract.RunCommandResult;

/// Foreground command execution configuration. Borrowed slices and callbacks
/// must remain valid for the duration of executeCommand.
pub const Config = struct {
    max_command_output_bytes: usize,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    output_chunk_lifecycle_id: ?types.ToolLifecycleId = null,
    output_chunk_ctx: ?*anyopaque = null,
    on_output_chunk: ?CommandOutputCallback = null,
    accepted_output_chunk_ctx: ?*anyopaque = null,
    on_accepted_output_chunk: ?CommandOutputCallback = null,
    callback_projection: CallbackProjection = .model_safe,
    timeout_ms: ?usize = null,
    timeout_started_ms: ?i64 = null,
    command_artifact_capability: ?*session_child_store.SessionChildCapability = null,
    command_artifact_dir: ?[]const u8 = null,
    background_process_provider: background_process_provider.Provider =
        background_process_provider.unavailable_provider,
};

pub const CallbackProjection = enum {
    model_safe,
    raw,
};

const command_artifact_file_prefix = "fx-command-";
const command_artifact_fallback_dir_name = "fx-command-output";
const command_artifact_log_suffix = ".log";
const command_artifact_stdout_suffix = ".stdout.log";
const command_artifact_stderr_suffix = ".stderr.log";
const pending_output_flush_bytes: usize = 4096;
const supports_foreground_session = builtin.link_libc and
    std.process.can_spawn and
    std.process.can_replace and
    builtin.os.tag != .windows and
    builtin.os.tag != .wasi;
const foreground_session_token = "__fx_foreground_session__";
const foreground_session_ready_byte: u8 = 0x1e;
const foreground_session_release_byte: u8 = 0x06;
const foreground_session_setup_timeout_ms: i64 = 5000;
const foreground_target_termination_grace_ms: i64 = 700;
const foreground_target_cleanup_wait_ms: i64 = 250;
const foreground_session_replace_failure_exit_code: u8 = 125;
const foreground_session_failure_nonce_bytes: usize = 16;
const foreground_session_failure_nonce_hex_bytes: usize = foreground_session_failure_nonce_bytes * 2;
const foreground_session_replace_failure_prefix = "\x00FX_FOREGROUND_EXEC_FAILED:";
const foreground_session_replace_failure_marker_bytes =
    foreground_session_replace_failure_prefix.len +
    foreground_session_failure_nonce_hex_bytes + 1;
var foreground_session_termination_requested: std.c.sig_atomic_t = 0;
const foreground_session_replace_error_name_bytes = blk: {
    var max_len: usize = 0;
    for (std.meta.fields(std.process.ReplaceError)) |field| {
        max_len = @max(max_len, field.name.len);
    }
    break :blk max_len;
};
const script_from_stdin_launcher =
    "script=$(command cat; command printf .)\n" ++
    "script=${script%.}\n" ++
    "eval \"$script\" </dev/null";

pub fn isForegroundSessionInvocation(args: []const [:0]const u8) bool {
    if (comptime !supports_foreground_session) return false;
    return args.len > 0 and std.mem.eql(u8, args[0], foreground_session_token);
}

pub fn runForegroundSessionBootstrap(args: []const [:0]const u8) !void {
    if (comptime !supports_foreground_session) {
        return error.OperationUnsupported;
    }
    if (!isForegroundSessionInvocation(args) or args.len < 3) {
        return error.InvalidForegroundSessionInvocation;
    }
    if (std.c.setsid() == -1) return error.ForegroundSessionSetupFailed;

    const zio = io_mod.getIo();
    try std.Io.File.stderr().writeStreamingAll(
        zio,
        &.{foreground_session_ready_byte},
    );

    var release: [1]u8 = undefined;
    const release_len = std.Io.File.stdin().readStreaming(
        zio,
        &.{&release},
    ) catch |err| switch (err) {
        error.EndOfStream => return error.InvalidForegroundSessionRelease,
        else => |read_err| return read_err,
    };
    if (release_len != 1 or release[0] != foreground_session_release_byte) {
        return error.InvalidForegroundSessionRelease;
    }

    // The group receives TERM together. Keep the supervisor alive while the
    // target uses the cooperative shutdown window.
    @as(*volatile std.c.sig_atomic_t, &foreground_session_termination_requested).* = 0;
    const supervisor_action: std.posix.Sigaction = .{
        .handler = .{ .handler = recordForegroundSessionTermination },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &supervisor_action, null);
    if (comptime builtin.os.tag == .linux) {
        _ = try std.posix.prctl(.SET_CHILD_SUBREAPER, .{@as(usize, 1)});
    }
    var target = std.process.spawn(zio, .{
        .argv = args[2..],
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .start_suspended = builtin.os.tag == .macos,
    }) catch |err| {
        writeForegroundSessionReplaceFailure(args[1], err);
        std.process.exit(foreground_session_replace_failure_exit_code);
    };
    const term = waitForForegroundTarget(&target) catch |err| {
        target.kill(zio);
        writeForegroundSessionReplaceFailure(args[1], err);
        std.process.exit(foreground_session_replace_failure_exit_code);
    };
    exitForegroundSessionSupervisor(term);
}

fn recordForegroundSessionTermination(_: std.posix.SIG) callconv(.c) void {
    @as(*volatile std.c.sig_atomic_t, &foreground_session_termination_requested).* = 1;
}

fn foregroundSessionTerminationRequested() bool {
    return @as(*volatile std.c.sig_atomic_t, &foreground_session_termination_requested).* != 0;
}

fn waitForForegroundTarget(
    target: *std.process.Child,
) !std.process.Child.Term {
    const target_pid = target.id orelse return error.ForegroundTargetMissing;
    var descendants = try process_tree.Tracker.init(std.heap.page_allocator);
    defer descendants.deinit();
    if (comptime builtin.os.tag == .macos) {
        try descendants.refresh(target_pid);
        try std.posix.kill(target_pid, std.posix.SIG.CONT);
    }
    var termination_started_ms: ?i64 = null;
    var forced = false;

    while (true) {
        try refreshForegroundTargetTree(&descendants, target_pid);
        const now_ms = io_mod.milliTimestamp();
        if (foregroundSessionTerminationRequested()) {
            if (termination_started_ms == null) {
                beginForegroundTargetTermination(
                    &descendants,
                    now_ms,
                    &termination_started_ms,
                );
            } else if (!forced and
                now_ms - termination_started_ms.? >= foreground_target_termination_grace_ms)
            {
                forced = true;
                forceKillForegroundTargetDescendants(&descendants);
            }
        }

        if (try pollProcessLeader(target)) |term| {
            try refreshForegroundTargetTree(&descendants, target_pid);
            if (termination_started_ms == null and
                foregroundSessionTerminationRequested())
            {
                beginForegroundTargetTermination(
                    &descendants,
                    io_mod.milliTimestamp(),
                    &termination_started_ms,
                );
            }
            if (termination_started_ms) |started_ms| {
                try waitForForegroundTargetDescendants(
                    &descendants,
                    target_pid,
                    started_ms,
                    &forced,
                );
                return term;
            }
            const count = try cleanupCompletedForegroundTarget(
                &descendants,
                target_pid,
            );
            if (count > 0) {
                debug_trace.logf(
                    "core",
                    "captured command target completed; tracked descendants terminated count={d}",
                    .{count},
                );
            }
            return term;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
}

fn cleanupCompletedForegroundTarget(
    descendants: *process_tree.Tracker,
    target_pid: std.posix.pid_t,
) !usize {
    const started_ms = io_mod.milliTimestamp();
    var signaled: usize = 0;
    var empty_scans: u8 = 0;
    while (io_mod.milliTimestamp() - started_ms <
        foreground_target_cleanup_wait_ms)
    {
        try refreshForegroundTargetTree(descendants, target_pid);
        signaled += descendants.signalAll(std.posix.SIG.KILL);
        if (descendants.anyAlive()) {
            empty_scans = 0;
        } else {
            empty_scans += 1;
            if (empty_scans >= 2) return signaled;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
    try refreshForegroundTargetTree(descendants, target_pid);
    signaled += descendants.signalAll(std.posix.SIG.KILL);
    return signaled;
}

fn refreshForegroundTargetTree(
    descendants: *process_tree.Tracker,
    target_pid: std.posix.pid_t,
) !void {
    try descendants.refresh(target_pid);
    if (comptime builtin.os.tag == .linux) {
        try descendants.refreshAdditionalRoot(std.c.getpid());
    }
    if (comptime builtin.os.tag == .macos) {
        if (foregroundSessionTerminationRequested()) {
            try descendants.refreshLineageProcesses();
        }
    }
}

fn beginForegroundTargetTermination(
    descendants: *process_tree.Tracker,
    now_ms: i64,
    termination_started_ms: *?i64,
) void {
    termination_started_ms.* = now_ms;
    const count = descendants.signalOutsideProcessGroup(
        std.posix.SIG.TERM,
        std.c.getpid(),
    );
    debug_trace.logf(
        "core",
        "captured command termination reached tracked descendants count={d}",
        .{count},
    );
}

fn waitForForegroundTargetDescendants(
    descendants: *process_tree.Tracker,
    target_pid: std.posix.pid_t,
    termination_started_ms: i64,
    forced: *bool,
) !void {
    var empty_scans: u8 = 0;
    while (true) {
        try refreshForegroundTargetTree(descendants, target_pid);
        const now_ms = io_mod.milliTimestamp();
        if (!forced.* and
            now_ms - termination_started_ms >= foreground_target_termination_grace_ms)
        {
            forced.* = true;
            forceKillForegroundTargetDescendants(descendants);
        }
        if (forced.*) {
            _ = descendants.signalAll(std.posix.SIG.KILL);
        }
        if (descendants.anyAlive()) {
            empty_scans = 0;
        } else {
            empty_scans += 1;
            if (empty_scans >= 2) return;
        }
        if (forced.* and
            now_ms - termination_started_ms >=
                foreground_target_termination_grace_ms + foreground_target_cleanup_wait_ms)
        {
            return;
        }
        io_mod.sleep(std.time.ns_per_ms);
    }
}

fn forceKillForegroundTargetDescendants(
    descendants: *process_tree.Tracker,
) void {
    const count = descendants.signalAll(std.posix.SIG.KILL);
    debug_trace.logf(
        "core",
        "captured command force-killed tracked descendants count={d}",
        .{count},
    );
}

fn writeForegroundSessionReplaceFailure(
    nonce: []const u8,
    err: anyerror,
) void {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        foreground_session_replace_failure_prefix ++ "{s}:{s}\n",
        .{ nonce, @errorName(err) },
    ) catch foreground_session_replace_failure_prefix ++ "unknown\n";
    std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), message) catch {};
}

fn exitForegroundSessionSupervisor(term: std.process.Child.Term) noreturn {
    switch (term) {
        .exited => |code| std.process.exit(code),
        .signal => |signal| {
            if (signal != std.posix.SIG.KILL and signal != std.posix.SIG.STOP) {
                const default_action: std.posix.Sigaction = .{
                    .handler = .{ .handler = std.posix.SIG.DFL },
                    .mask = std.posix.sigemptyset(),
                    .flags = 0,
                };
                std.posix.sigaction(signal, &default_action, null);
            }
            var signal_mask = std.posix.sigemptyset();
            std.posix.sigaddset(&signal_mask, signal);
            std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &signal_mask, null);
            std.posix.raise(signal) catch {};
            std.process.exit(128 + @as(u8, @truncate(@intFromEnum(signal))));
        },
        .stopped, .unknown => std.process.exit(127),
    }
}

/// Executes one command and returns an owned formatted result.
pub fn executeCommand(
    cfg: Config,
    arena: Allocator,
    command: []const u8,
    cwd: []const u8,
) !command_contract.RunCommandResult {
    var scratch_state = std.heap.ArenaAllocator.init(arena);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var effective_cfg = cfg;
    if (effective_cfg.timeout_started_ms == null) effective_cfg.timeout_started_ms = io_mod.milliTimestamp();
    try ExecutionControl.init(effective_cfg).check();
    return executeRawBash(arena, scratch, effective_cfg, command, cwd);
}

pub fn executeCommandInEnvironment(
    cfg: Config,
    arena: Allocator,
    command: []const u8,
    cwd: []const u8,
    environment: command_environment.Environment,
) !command_contract.RunCommandResult {
    switch (environment) {
        .legacy => return executeCommand(cfg, arena, command, cwd),
        .workspace_clean => return error.InvalidCommandEnvironment,
        .clean, .user => {},
    }

    var scratch_state = std.heap.ArenaAllocator.init(arena);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var effective_cfg = cfg;
    if (effective_cfg.timeout_started_ms == null) effective_cfg.timeout_started_ms = io_mod.milliTimestamp();
    try ExecutionControl.init(effective_cfg).check();
    const invocation = try shell_resolver.capturedInvocation(environment, command);
    debug_trace.logf(
        "core",
        "command runner explicit environment={s} shell={s}",
        .{ @tagName(std.meta.activeTag(environment)), invocation.path },
    );
    return executeRawInvocation(
        arena,
        scratch,
        effective_cfg,
        command,
        cwd,
        &invocation,
    );
}

pub fn spawnPreparedBackground(
    cfg: Config,
    arena: Allocator,
    cwd: []const u8,
    output: *const background_launch_output.Output,
) !background_process_provider.PreparedProcess {
    var effective_cfg = cfg;
    if (effective_cfg.timeout_started_ms == null) {
        effective_cfg.timeout_started_ms = io_mod.milliTimestamp();
    }
    try ExecutionControl.init(effective_cfg).check();
    return effective_cfg.background_process_provider.spawnPrepared(
        arena,
        .{
            .cwd = cwd,
            .output = output.providerCapability(),
            .isolation = .none,
        },
    );
}
const ExecutionControl = struct {
    cancel_flag: ?*std.atomic.Value(bool),
    timeout_ms: ?usize,
    started_ms: i64,

    fn init(cfg: Config) ExecutionControl {
        return .{
            .cancel_flag = cfg.cancel_flag,
            .timeout_ms = cfg.timeout_ms,
            .started_ms = cfg.timeout_started_ms orelse io_mod.milliTimestamp(),
        };
    }

    fn check(self: ExecutionControl) !void {
        if (cancelRequested(self.cancel_flag)) return error.CancelledBeforeExecution;
        if (self.timeout_ms) |timeout_ms| {
            const now_ms = io_mod.milliTimestamp();
            const elapsed_ms: u64 = if (now_ms > self.started_ms) @intCast(now_ms - self.started_ms) else 0;
            if (elapsed_ms >= timeout_ms) return error.TimeoutExpired;
        }
    }
};

fn cancelRequested(cancel_flag: ?*std.atomic.Value(bool)) bool {
    return if (cancel_flag) |flag| flag.load(.seq_cst) else false;
}

fn emitAcceptedOutputChunk(
    cfg: Config,
    stream: CommandOutputStream,
    bytes: []const u8,
) !void {
    if (bytes.len == 0) return;
    const ctx = cfg.accepted_output_chunk_ctx orelse return;
    const callback = cfg.on_accepted_output_chunk orelse return;
    try callback(ctx, cfg.output_chunk_lifecycle_id, stream, bytes);
}

const CollectedProcess = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
    stdout_bytes: usize,
    stderr_bytes: usize,
    duration_ms: ?u64 = null,
    truncated: bool = false,
    output_file: ?[]const u8 = null,
    stdout_file: ?[]const u8 = null,
    stderr_file: ?[]const u8 = null,
    stdout_preview: StreamPreviewSnapshot = .{},
    stderr_preview: StreamPreviewSnapshot = .{},
    cancelled: bool = false,
    timed_out: bool = false,
};

const StreamPreviewSnapshot = struct {
    head: []const u8 = "",
    tail: []const u8 = "",
    total_bytes: usize = 0,
    max_bytes: usize = 0,
};

const StreamPreview = struct {
    max_bytes: usize,
    head_limit: usize,
    tail_limit: usize,
    total_bytes: usize = 0,
    head: std.ArrayList(u8) = .empty,
    tail: std.ArrayList(u8) = .empty,

    fn init(max_bytes: usize) StreamPreview {
        const head_limit = if (max_bytes == 0) 0 else (max_bytes + 1) / 2;
        return .{
            .max_bytes = max_bytes,
            .head_limit = head_limit,
            .tail_limit = if (max_bytes > head_limit) max_bytes - head_limit else 0,
        };
    }

    fn deinit(self: *StreamPreview, alloc: Allocator) void {
        self.head.deinit(alloc);
        self.tail.deinit(alloc);
        self.* = undefined;
    }

    fn append(self: *StreamPreview, alloc: Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        self.total_bytes += bytes.len;

        if (self.head.items.len < self.head_limit) {
            const take = @min(self.head_limit - self.head.items.len, bytes.len);
            try self.head.appendSlice(alloc, bytes[0..take]);
        }

        if (self.tail_limit == 0) return;
        try self.appendTail(alloc, bytes);
    }

    fn appendTail(self: *StreamPreview, alloc: Allocator, bytes: []const u8) !void {
        if (bytes.len >= self.tail_limit) {
            self.tail.clearRetainingCapacity();
            try self.tail.appendSlice(alloc, bytes[bytes.len - self.tail_limit ..]);
            return;
        }

        if (self.tail.items.len + bytes.len > self.tail_limit) {
            const drop = self.tail.items.len + bytes.len - self.tail_limit;
            const keep = self.tail.items.len - drop;
            std.mem.copyForwards(u8, self.tail.items[0..keep], self.tail.items[drop..]);
            self.tail.items.len = keep;
        }
        try self.tail.appendSlice(alloc, bytes);
    }

    fn snapshot(self: *StreamPreview, alloc: Allocator) !StreamPreviewSnapshot {
        return .{
            .head = try self.head.toOwnedSlice(alloc),
            .tail = try self.tail.toOwnedSlice(alloc),
            .total_bytes = self.total_bytes,
            .max_bytes = self.max_bytes,
        };
    }
};

const ArtifactFile = union(enum) {
    external: std.Io.File,
    managed: session_child_store.ManagedFile,

    fn writeAll(self: *ArtifactFile, bytes: []const u8) !void {
        switch (self.*) {
            .external => |file| try file.writeStreamingAll(io_mod.getIo(), bytes),
            .managed => |*file| try file.writeAll(bytes),
        }
    }

    fn sync(self: *ArtifactFile) !void {
        switch (self.*) {
            .external => |file| try file.sync(io_mod.getIo()),
            .managed => |*file| try file.sync(),
        }
    }

    fn close(self: *ArtifactFile) void {
        switch (self.*) {
            .external => |file| file.close(io_mod.getIo()),
            .managed => |*file| file.deinit(),
        }
    }
};

const CommandArtifact = struct {
    output_file: []const u8,
    stdout_file: []const u8,
    stderr_file: []const u8,
    output: ArtifactFile,
    stdout: ArtifactFile,
    stderr: ArtifactFile,
    managed_capability: ?*session_child_store.SessionChildCapability = null,
    output_hasher: std.crypto.hash.sha2.Sha256 =
        std.crypto.hash.sha2.Sha256.init(.{}),

    fn append(self: *CommandArtifact, stream: CommandOutputStream, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try self.output.writeAll(bytes);
        switch (stream) {
            .stdout => try self.stdout.writeAll(bytes),
            .stderr => try self.stderr.writeAll(bytes),
        }
        self.output_hasher.update(bytes);
    }

    fn close(self: *CommandArtifact) void {
        self.output.close();
        self.stdout.close();
        self.stderr.close();
    }

    fn sync(self: *CommandArtifact) !void {
        try self.output.sync();
        try self.stdout.sync();
        try self.stderr.sync();
    }

    fn contentAddressManagedOutput(
        self: *CommandArtifact,
        alloc: Allocator,
    ) !void {
        const capability = self.managed_capability orelse return;
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        var hasher = self.output_hasher;
        hasher.final(&digest);
        const source_handle = std.fs.path.basename(self.output_file);
        const target_handle = try artifact_digest.contentAddressedHandle(
            alloc,
            source_handle,
            command_artifact_log_suffix,
            digest,
        );
        defer alloc.free(target_handle);
        const parent = std.fs.path.dirname(self.output_file) orelse
            return error.InvalidCommandArtifactPath;
        const target_path = try std.fs.path.join(
            alloc,
            &.{ parent, target_handle },
        );
        errdefer alloc.free(target_path);
        capability.rename(
            .command_artifacts,
            source_handle,
            target_handle,
        ) catch |err| {
            if (err == error.SessionChildCommitIndeterminate and
                try capability.confirmIndeterminateEntry(
                    .command_artifacts,
                    target_handle,
                ))
            {
                self.output_file = target_path;
                debug_trace.logf(
                    "core",
                    "command artifact rename durability confirmed handle={s}",
                    .{target_handle},
                );
                return;
            }
            return err;
        };
        self.output_file = target_path;
    }
};

const OutputCollector = struct {
    alloc: Allocator,
    cfg: Config,
    stdout: std.ArrayList(u8) = .empty,
    stderr: std.ArrayList(u8) = .empty,
    stdout_preview: StreamPreview,
    stderr_preview: StreamPreview,
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    artifact: ?CommandArtifact = null,

    fn init(alloc: Allocator, cfg: Config) OutputCollector {
        const preview_limit = streamPreviewLimit(cfg.max_command_output_bytes);
        return .{
            .alloc = alloc,
            .cfg = cfg,
            .stdout_preview = StreamPreview.init(preview_limit),
            .stderr_preview = StreamPreview.init(preview_limit),
        };
    }

    fn deinit(self: *OutputCollector) void {
        if (self.artifact) |*artifact| artifact.close();
        self.stdout.deinit(self.alloc);
        self.stderr.deinit(self.alloc);
        self.stdout_preview.deinit(self.alloc);
        self.stderr_preview.deinit(self.alloc);
        self.* = undefined;
    }

    fn append(self: *OutputCollector, stream: CommandOutputStream, bytes: []const u8) !void {
        if (bytes.len == 0) return;

        switch (stream) {
            .stdout => {
                self.stdout_bytes += bytes.len;
                try self.stdout_preview.append(self.alloc, bytes);
            },
            .stderr => {
                self.stderr_bytes += bytes.len;
                try self.stderr_preview.append(self.alloc, bytes);
            },
        }

        if (self.artifact) |*artifact| {
            try artifact.append(stream, bytes);
            return;
        }

        switch (stream) {
            .stdout => try self.stdout.appendSlice(self.alloc, bytes),
            .stderr => try self.stderr.appendSlice(self.alloc, bytes),
        }

        if (self.totalBytes() > self.cfg.max_command_output_bytes) {
            try self.startArtifact();
        }
    }

    fn finish(self: *OutputCollector, term: std.process.Child.Term) !CollectedProcess {
        if (self.artifact) |*artifact| {
            try artifact.sync();
            try artifact.contentAddressManagedOutput(self.alloc);
            const truncated = self.totalBytes() > self.cfg.max_command_output_bytes;
            return .{
                .term = term,
                .stdout = "",
                .stderr = "",
                .stdout_bytes = self.stdout_bytes,
                .stderr_bytes = self.stderr_bytes,
                .truncated = truncated,
                .output_file = artifact.output_file,
                .stdout_file = artifact.stdout_file,
                .stderr_file = artifact.stderr_file,
                .stdout_preview = if (truncated) try self.stdout_preview.snapshot(self.alloc) else .{},
                .stderr_preview = if (truncated) try self.stderr_preview.snapshot(self.alloc) else .{},
            };
        }

        return .{
            .term = term,
            .stdout = try self.stdout.toOwnedSlice(self.alloc),
            .stderr = try self.stderr.toOwnedSlice(self.alloc),
            .stdout_bytes = self.stdout_bytes,
            .stderr_bytes = self.stderr_bytes,
        };
    }

    fn totalBytes(self: OutputCollector) usize {
        return self.stdout_bytes + self.stderr_bytes;
    }

    fn startArtifact(self: *OutputCollector) !void {
        if (self.artifact != null) return;
        var artifact = try createCommandArtifact(
            self.alloc,
            self.cfg.command_artifact_capability,
            self.cfg.command_artifact_dir,
        );
        errdefer artifact.close();
        try artifact.append(.stdout, self.stdout.items);
        try artifact.append(.stderr, self.stderr.items);
        debug_trace.logf(
            "core",
            "command output artifact created output_file={s} stdout_file={s} stderr_file={s} stdout_bytes={d} stderr_bytes={d}",
            .{ artifact.output_file, artifact.stdout_file, artifact.stderr_file, self.stdout_bytes, self.stderr_bytes },
        );
        self.stdout.clearRetainingCapacity();
        self.stderr.clearRetainingCapacity();
        self.artifact = artifact;
    }
};

fn finishCollectedProcess(
    output: *OutputCollector,
    term: std.process.Child.Term,
    duration_ms: u64,
    source: TerminationSource,
) !CollectedProcess {
    switch (source) {
        .natural, .timed_out => {},
        .cancelled => {
            if (output.totalBytes() == 0) return error.Cancelled;
            if (output.artifact == null) {
                output.startArtifact() catch |err| {
                    debug_trace.logf("core", "cancelled command artifact promotion failed err={s}", .{@errorName(err)});
                    return error.Cancelled;
                };
            }
        },
    }

    var result = output.finish(term) catch |err| switch (source) {
        .natural => return err,
        .cancelled => {
            debug_trace.logf("core", "cancelled command artifact finalization failed err={s}", .{@errorName(err)});
            return error.Cancelled;
        },
        .timed_out => {
            debug_trace.logf("core", "timed out command artifact finalization failed err={s}", .{@errorName(err)});
            return error.TimeoutExpired;
        },
    };
    result.duration_ms = duration_ms;
    result.cancelled = source == .cancelled;
    result.timed_out = source == .timed_out;
    return result;
}

fn executeProcess(scratch: Allocator, cfg: Config, argv: []const []const u8, cwd: []const u8) !CollectedProcess {
    return executeProcessWithInput(scratch, cfg, argv, cwd, false, true);
}

fn executeProcessWithClosedInput(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
) !CollectedProcess {
    if (comptime supports_foreground_session) {
        return executeProcessWithDetachedSession(
            scratch,
            cfg,
            argv,
            cwd,
            "",
        );
    }
    return executeProcessWithInput(scratch, cfg, argv, cwd, true, true);
}

fn executeProcessWithInput(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    closed_input: bool,
    isolate_process_group: bool,
) !CollectedProcess {
    const started_ms = io_mod.milliTimestamp();
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = if (closed_input) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
        .pgid = if (isolate_process_group and builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    });
    if (child.stdin) |input| {
        input.close(io_mod.getIo());
        child.stdin = null;
    }

    var output = OutputCollector.init(scratch, cfg);
    defer output.deinit();

    var child_needs_cleanup = true;
    errdefer if (child_needs_cleanup) cleanupChild(&child);

    const process_group_id = if (isolate_process_group and
        builtin.os.tag != .windows and builtin.os.tag != .wasi)
        child.id
    else
        null;
    var leader_term: ?std.process.Child.Term = null;
    const source = try collectOutputForProcess(
        scratch,
        &child,
        &output,
        cfg,
        null,
        process_group_id,
        &leader_term,
    );
    const term = try waitForCollectedProcess(
        &child,
        source,
        process_group_id,
        leader_term,
    );
    const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());
    child_needs_cleanup = false;

    return finishCollectedProcess(&output, term, duration_ms, source);
}

fn executeProcessWithScript(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    script: []const u8,
) !CollectedProcess {
    if (comptime supports_foreground_session) {
        return executeProcessWithDetachedSession(
            scratch,
            cfg,
            argv,
            cwd,
            script,
        );
    }
    return executeProcessWithScriptUnisolated(
        scratch,
        cfg,
        argv,
        cwd,
        script,
    );
}

const ForegroundSessionPhase = enum {
    pre_ready,
    group_ready,
};

fn executeProcessWithDetachedSession(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    script: []const u8,
) !CollectedProcess {
    const executable = try foregroundSessionExecutable(scratch);
    var nonce_bytes: [foreground_session_failure_nonce_bytes]u8 = undefined;
    io_mod.getIo().random(&nonce_bytes);
    const nonce = std.fmt.bytesToHex(nonce_bytes, .lower);
    var failure_marker: [foreground_session_replace_failure_marker_bytes]u8 = undefined;
    @memcpy(
        failure_marker[0..foreground_session_replace_failure_prefix.len],
        foreground_session_replace_failure_prefix,
    );
    @memcpy(
        failure_marker[foreground_session_replace_failure_prefix.len..][0..nonce.len],
        &nonce,
    );
    failure_marker[failure_marker.len - 1] = ':';

    var helper_argv: std.ArrayList([]const u8) = .empty;
    try helper_argv.append(scratch, executable);
    try helper_argv.append(scratch, foreground_session_token);
    try helper_argv.append(scratch, &nonce);
    try helper_argv.appendSlice(scratch, argv);

    const started_ms = io_mod.milliTimestamp();
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = helper_argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
    });

    var output = OutputCollector.init(scratch, cfg);
    defer output.deinit();

    var phase: ForegroundSessionPhase = .pre_ready;
    var child_needs_cleanup = true;
    errdefer if (child_needs_cleanup) {
        cleanupForegroundSessionChild(&child, phase);
    };

    try waitForForegroundSessionReady(&child, cfg);
    phase = .group_ready;
    try ExecutionControl.init(cfg).check();

    var script_write = child.stdin orelse return error.SpawnFailed;
    child.stdin = null;
    var script_write_open = true;
    defer if (script_write_open) script_write.close(io_mod.getIo());

    var script_write_error: ?std.Io.File.Writer.Error = null;
    script_write.writeStreamingAll(
        io_mod.getIo(),
        &.{foreground_session_release_byte},
    ) catch |err| {
        script_write_error = err;
    };
    if (script_write_error == null) {
        script_write.writeStreamingAll(io_mod.getIo(), script) catch |err| {
            script_write_error = err;
        };
    }
    script_write.close(io_mod.getIo());
    script_write_open = false;

    var launch_failure_probe = ForegroundLaunchFailureProbe.init(&failure_marker);
    const process_group_id = child.id;
    var leader_term: ?std.process.Child.Term = null;
    const source = try collectOutputForProcess(
        scratch,
        &child,
        &output,
        cfg,
        &launch_failure_probe,
        process_group_id,
        &leader_term,
    );
    const term = try waitForCollectedProcess(
        &child,
        source,
        process_group_id,
        leader_term,
    );
    const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());
    child_needs_cleanup = false;

    if (foregroundSessionReplacementError(term, launch_failure_probe)) |launch_err| return launch_err;
    if (script_write_error) |write_err| return write_err;
    return finishCollectedProcess(&output, term, duration_ms, source);
}

fn foregroundSessionExecutable(scratch: Allocator) ![]const u8 {
    if (comptime builtin.is_test) {
        const path_z = std.c.getenv("FX_TEST_PRODUCT_EXE") orelse
            return error.TestProductExecutableMissing;
        return std.mem.sliceTo(path_z, 0);
    }
    return self_exe.pathForReexec(scratch);
}

fn waitForForegroundSessionReady(
    child: *std.process.Child,
    cfg: Config,
) !void {
    const ready_read = child.stderr orelse return error.SpawnFailed;
    const setup_started_ms = io_mod.milliTimestamp();
    const control = ExecutionControl.init(cfg);

    while (true) {
        try control.check();
        const now_ms = io_mod.milliTimestamp();
        const setup_elapsed_ms = if (now_ms > setup_started_ms)
            now_ms - setup_started_ms
        else
            0;
        if (setup_elapsed_ms >= foreground_session_setup_timeout_ms) {
            return error.ForegroundSessionSetupTimedOut;
        }

        const remaining_ms = foreground_session_setup_timeout_ms - setup_elapsed_ms;
        const poll_timeout_ms: i32 = @intCast(@min(@as(i64, 50), remaining_ms));
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = ready_read.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&poll_fds, poll_timeout_ms) == 0) continue;

        const revents = poll_fds[0].revents;
        if ((revents & std.posix.POLL.IN) != 0) {
            var marker: [1]u8 = undefined;
            const marker_len = try std.posix.read(ready_read.handle, &marker);
            if (marker_len == 0) return error.ForegroundSessionSetupFailed;
            if (marker[0] != foreground_session_ready_byte) {
                return error.InvalidForegroundSessionReady;
            }
            return;
        }
        if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            return error.ForegroundSessionSetupFailed;
        }
    }
}

fn cleanupForegroundSessionChild(
    child: *std.process.Child,
    phase: ForegroundSessionPhase,
) void {
    if (comptime !supports_foreground_session) {
        cleanupChild(child);
        return;
    }
    const pid = child.id orelse return;
    const target_pid = switch (phase) {
        .pre_ready => pid,
        .group_ready => -pid,
    };
    std.posix.kill(target_pid, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => debug_trace.logf(
            "core",
            "foreground session cleanup kill failed phase={s} err={s}",
            .{ @tagName(phase), @errorName(err) },
        ),
    };
    _ = child.wait(io_mod.getIo()) catch |err| {
        debug_trace.logf(
            "core",
            "foreground session cleanup wait failed phase={s} err={s}",
            .{ @tagName(phase), @errorName(err) },
        );
    };
}

fn foregroundSessionReplacementError(
    term: std.process.Child.Term,
    probe: ForegroundLaunchFailureProbe,
) ?(std.process.ReplaceError || error{CommandLaunchFailed}) {
    switch (term) {
        .exited => |code| if (code != foreground_session_replace_failure_exit_code) return null,
        else => return null,
    }
    if (probe.status != .failed) return null;
    return probe.replacement_error orelse error.CommandLaunchFailed;
}

fn executeProcessWithScriptUnisolated(
    scratch: Allocator,
    cfg: Config,
    argv: []const []const u8,
    cwd: []const u8,
    script: []const u8,
) !CollectedProcess {
    const started_ms = io_mod.milliTimestamp();
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = cwd },
        .pgid = if (builtin.os.tag != .windows and builtin.os.tag != .wasi) 0 else null,
    });

    var output = OutputCollector.init(scratch, cfg);
    defer output.deinit();

    var child_needs_cleanup = true;
    errdefer if (child_needs_cleanup) cleanupChild(&child);

    var script_write = child.stdin orelse return error.SpawnFailed;
    child.stdin = null;
    var script_write_open = true;
    errdefer if (script_write_open) script_write.close(io_mod.getIo());
    try script_write.writeStreamingAll(io_mod.getIo(), script);
    script_write.close(io_mod.getIo());
    script_write_open = false;

    const process_group_id = child.id;
    var leader_term: ?std.process.Child.Term = null;
    const source = try collectOutputForProcess(
        scratch,
        &child,
        &output,
        cfg,
        null,
        process_group_id,
        &leader_term,
    );
    const term = try waitForCollectedProcess(
        &child,
        source,
        process_group_id,
        leader_term,
    );
    const duration_ms = elapsedMs(started_ms, io_mod.milliTimestamp());
    child_needs_cleanup = false;

    return finishCollectedProcess(&output, term, duration_ms, source);
}

fn streamPreviewLimit(max_command_output_bytes: usize) usize {
    if (max_command_output_bytes == 0) return 0;
    return @max(@as(usize, 1), max_command_output_bytes / 2);
}

fn createCommandArtifact(
    alloc: Allocator,
    capability: ?*session_child_store.SessionChildCapability,
    preferred_dir: ?[]const u8,
) !CommandArtifact {
    if (capability) |managed| {
        return createManagedCommandArtifact(alloc, managed);
    }
    if (preferred_dir) |dir| {
        if (createCommandArtifactInDir(alloc, dir)) |artifact| {
            return artifact;
        } else |err| {
            debug_trace.logf("core", "command artifact preferred dir failed dir={s} err={s}", .{ dir, @errorName(err) });
        }
    }

    const fallback_dir = try fallbackCommandArtifactDir(alloc);
    defer alloc.free(fallback_dir);
    return createCommandArtifactInDir(alloc, fallback_dir);
}

fn createManagedCommandArtifact(
    alloc: Allocator,
    capability: *session_child_store.SessionChildCapability,
) !CommandArtifact {
    const stem = try std.fmt.allocPrint(
        alloc,
        "{s}{d}-{d}",
        .{
            command_artifact_file_prefix,
            io_mod.milliTimestamp(),
            io_mod.nanoTimestamp(),
        },
    );
    defer alloc.free(stem);
    const output_name = try artifactName(
        alloc,
        stem,
        command_artifact_log_suffix,
    );
    defer alloc.free(output_name);
    const stdout_name = try artifactName(
        alloc,
        stem,
        command_artifact_stdout_suffix,
    );
    defer alloc.free(stdout_name);
    const stderr_name = try artifactName(
        alloc,
        stem,
        command_artifact_stderr_suffix,
    );
    defer alloc.free(stderr_name);

    var output = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        output_name,
    );
    errdefer {
        output.deinit();
        capability.delete(.command_artifacts, output_name) catch {};
    }
    var stdout = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        stdout_name,
    );
    errdefer {
        stdout.deinit();
        capability.delete(.command_artifacts, stdout_name) catch {};
    }
    var stderr = try capability.createExclusiveFile(
        alloc,
        .command_artifacts,
        stderr_name,
    );
    errdefer {
        stderr.deinit();
        capability.delete(.command_artifacts, stderr_name) catch {};
    }
    const output_file = try alloc.dupe(u8, output.displayPath().?);
    errdefer alloc.free(output_file);
    const stdout_file = try alloc.dupe(u8, stdout.displayPath().?);
    errdefer alloc.free(stdout_file);
    const stderr_file = try alloc.dupe(u8, stderr.displayPath().?);
    errdefer alloc.free(stderr_file);

    return .{
        .output_file = output_file,
        .stdout_file = stdout_file,
        .stderr_file = stderr_file,
        .output = .{ .managed = output },
        .stdout = .{ .managed = stdout },
        .stderr = .{ .managed = stderr },
        .managed_capability = capability,
    };
}

fn createCommandArtifactInDir(alloc: Allocator, dir: []const u8) !CommandArtifact {
    try config_runtime.makeAbsolutePath(dir);

    const stem = try std.fmt.allocPrint(
        alloc,
        "{s}{d}-{d}",
        .{ command_artifact_file_prefix, io_mod.milliTimestamp(), io_mod.nanoTimestamp() },
    );
    defer alloc.free(stem);

    const output_file = try artifactPath(alloc, dir, stem, command_artifact_log_suffix);
    errdefer alloc.free(output_file);
    const stdout_file = try artifactPath(alloc, dir, stem, command_artifact_stdout_suffix);
    errdefer alloc.free(stdout_file);
    const stderr_file = try artifactPath(alloc, dir, stem, command_artifact_stderr_suffix);
    errdefer alloc.free(stderr_file);

    const zio = io_mod.getIo();
    var output = try std.Io.Dir.createFileAbsolute(zio, output_file, .{ .truncate = true });
    errdefer output.close(zio);
    var stdout = try std.Io.Dir.createFileAbsolute(zio, stdout_file, .{ .truncate = true });
    errdefer stdout.close(zio);
    var stderr = try std.Io.Dir.createFileAbsolute(zio, stderr_file, .{ .truncate = true });
    errdefer stderr.close(zio);

    return .{
        .output_file = output_file,
        .stdout_file = stdout_file,
        .stderr_file = stderr_file,
        .output = .{ .external = output },
        .stdout = .{ .external = stdout },
        .stderr = .{ .external = stderr },
    };
}

fn artifactName(
    alloc: Allocator,
    stem: []const u8,
    suffix: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ stem, suffix });
}

fn artifactPath(alloc: Allocator, dir: []const u8, stem: []const u8, suffix: []const u8) ![]u8 {
    const name = try std.fmt.allocPrint(alloc, "{s}{s}", .{ stem, suffix });
    defer alloc.free(name);
    return std.fs.path.join(alloc, &.{ dir, name });
}

fn fallbackCommandArtifactDir(alloc: Allocator) ![]u8 {
    const temp_root = io_mod.getenv("TMPDIR") orelse "/tmp";
    const pid_text = try std.fmt.allocPrint(alloc, "{d}", .{currentProcessId()});
    defer alloc.free(pid_text);
    return std.fs.path.join(alloc, &.{ temp_root, command_artifact_fallback_dir_name, pid_text });
}

fn currentProcessId() u64 {
    return @intCast(std.c.getpid());
}

fn elapsedMs(started_ms: i64, finished_ms: i64) u64 {
    return if (finished_ms > started_ms) @intCast(finished_ms - started_ms) else 0;
}

fn executeRawBash(
    alloc: Allocator,
    scratch: Allocator,
    cfg: Config,
    command: []const u8,
    cwd: []const u8,
) !command_contract.RunCommandResult {
    return executeRawBashWithResultCommand(
        alloc,
        scratch,
        cfg,
        command,
        command,
        cwd,
    );
}

fn executeRawBashWithResultCommand(
    alloc: Allocator,
    scratch: Allocator,
    cfg: Config,
    execution_command: []const u8,
    result_command: []const u8,
    cwd: []const u8,
) !command_contract.RunCommandResult {
    if (builtin.os.tag == .windows) {
        const argv = [_][]const u8{ "cmd", "/C", execution_command };
        const result = try executeProcess(scratch, cfg, &argv, cwd);
        return formatCollectedOutput(alloc, result_command, cwd, result);
    }

    const argv = [_][]const u8{
        "sh",
        "-lc",
        script_from_stdin_launcher,
    };
    const result = try executeProcessWithScript(
        scratch,
        cfg,
        &argv,
        cwd,
        execution_command,
    );
    return formatCollectedOutput(alloc, result_command, cwd, result);
}

fn executeRawInvocation(
    alloc: Allocator,
    scratch: Allocator,
    cfg: Config,
    command: []const u8,
    cwd: []const u8,
    invocation: *const shell_resolver.Invocation,
) !command_contract.RunCommandResult {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.InvalidCommandEnvironment;
    }
    const result = try executeProcessWithScript(
        scratch,
        cfg,
        invocation.argv(),
        cwd,
        "",
    );
    return formatCollectedOutput(alloc, command, cwd, result);
}

test "explicit captured profiles execute exact shells without synthetic stderr" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;
    std.Io.Dir.accessAbsolute(io_mod.getIo(), "/bin/bash", .{}) catch
        return error.SkipZigTest;
    const shell_path = "/bin/bash";

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg = Config{
        .max_command_output_bytes = 16 * 1024,
    };
    const command = "printf 'profile-stdout'; printf 'profile-stderr' >&2";

    const clean = try executeCommandInEnvironment(
        cfg,
        arena,
        command,
        "/tmp",
        .{ .clean = shell_path },
    );
    try std.testing.expect(std.mem.find(u8, clean.output, "profile-stdout") != null);
    try std.testing.expect(std.mem.find(u8, clean.output, "profile-stderr") != null);

    const user = try executeCommandInEnvironment(
        cfg,
        arena,
        command,
        "/tmp",
        .{ .user = shell_path },
    );
    try std.testing.expectEqualStrings(
        "exit_code=0\n<stdout>\nprofile-stdout\n</stdout>\n<stderr>\nprofile-stderr\n</stderr>\n",
        user.output,
    );
    if (std.Io.Dir.accessAbsolute(io_mod.getIo(), "/bin/zsh", .{})) {
        const zsh_user = try executeCommandInEnvironment(
            cfg,
            arena,
            command,
            "/tmp",
            .{ .user = "/bin/zsh" },
        );
        try std.testing.expectEqualStrings(
            "exit_code=0\n<stdout>\nprofile-stdout\n</stdout>\n<stderr>\nprofile-stderr\n</stderr>\n",
            zsh_user.output,
        );
    } else |_| {}
}

fn formatExitOutput(alloc: Allocator, command: []const u8, cwd: []const u8, exit_code: i64, stdout_raw: []const u8, stderr_raw: []const u8, duration_ms: ?u64) !command_contract.RunCommandResult {
    return command_contract.formatForegroundCommandResult(alloc, .{
        .command = command,
        .cwd = cwd,
        .status = .{ .exit_code = exit_code },
        .stdout_display = stdout_raw,
        .stderr_display = stderr_raw,
        .stdout_bytes = stdout_raw.len,
        .stderr_bytes = stderr_raw.len,
        .duration_ms = duration_ms,
    });
}

fn formatOutput(alloc: Allocator, command: []const u8, cwd: []const u8, term: std.process.Child.Term, stdout_raw: []const u8, stderr_raw: []const u8, duration_ms: ?u64) !command_contract.RunCommandResult {
    return command_contract.formatForegroundCommandResult(alloc, .{
        .command = command,
        .cwd = cwd,
        .status = foregroundCommandStatusFromTerm(term),
        .stdout_display = stdout_raw,
        .stderr_display = stderr_raw,
        .stdout_bytes = stdout_raw.len,
        .stderr_bytes = stderr_raw.len,
        .duration_ms = duration_ms,
    });
}

fn foregroundCommandStatusFromTerm(term: std.process.Child.Term) command_contract.ForegroundCommandStatus {
    return switch (term) {
        .exited => |code| .{ .exit_code = @intCast(code) },
        .signal => |sig| .{ .signal = @intFromEnum(sig) },
        else => .finished,
    };
}

fn formatCollectedOutput(alloc: Allocator, command: []const u8, cwd: []const u8, result: CollectedProcess) !command_contract.RunCommandResult {
    return formatCollectedOutputValue(alloc, command, cwd, result) catch |err| {
        if (!result.cancelled) return err;
        debug_trace.logf("core", "cancelled command result formatting failed err={s}", .{@errorName(err)});
        return error.Cancelled;
    };
}

fn formatCollectedOutputValue(alloc: Allocator, command: []const u8, cwd: []const u8, result: CollectedProcess) !command_contract.RunCommandResult {
    if (result.output_file == null) return command_contract.formatForegroundCommandResult(alloc, .{
        .command = command,
        .cwd = cwd,
        .status = foregroundCommandStatusFromTerm(result.term),
        .timed_out = result.timed_out,
        .stdout_display = result.stdout,
        .stderr_display = result.stderr,
        .stdout_bytes = result.stdout_bytes,
        .stderr_bytes = result.stderr_bytes,
        .duration_ms = result.duration_ms,
    });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (result.timed_out) {
        try out.writer.writeAll("timed_out=true\n");
    } else {
        try writeTermLine(&out.writer, result.term);
    }
    try out.writer.print("truncated={s}\n", .{if (result.truncated) "true" else "false"});
    try out.writer.print("stdout_bytes={d}\n", .{result.stdout_bytes});
    try out.writer.print("stderr_bytes={d}\n", .{result.stderr_bytes});
    if (result.output_file) |path| try out.writer.print("output_file={s}\n", .{path});
    if (result.stdout_file) |path| try out.writer.print("stdout_file={s}\n", .{path});
    if (result.stderr_file) |path| try out.writer.print("stderr_file={s}\n", .{path});
    if (result.truncated) {
        try writePreviewEnvelope(alloc, &out.writer, "stdout", result.stdout_preview);
        try writePreviewEnvelope(alloc, &out.writer, "stderr", result.stderr_preview);
    }
    const output = try out.toOwnedSlice();
    return .{
        .output = output,
        .cancelled = result.cancelled,
        .command_result = .{ .foreground = .{
            .command = command,
            .cwd = cwd,
            .exit_code = if (result.timed_out) null else termExitCode(result.term),
            .signal = if (result.timed_out) null else termSignal(result.term),
            .timed_out = result.timed_out,
            .duration_ms = result.duration_ms,
            .stdout_bytes = result.stdout_bytes,
            .stderr_bytes = result.stderr_bytes,
            .truncated = result.truncated,
            .output_file = metadataField(output, "output_file="),
            .stdout_file = metadataField(output, "stdout_file="),
            .stderr_file = metadataField(output, "stderr_file="),
        } },
    };
}

fn writeTermLine(writer: *std.Io.Writer, term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| try writer.print("exit_code={d}\n", .{code}),
        .signal => |sig| try writer.print("signal={d}\n", .{sig}),
        else => try writer.writeAll("process finished\n"),
    }
}

fn termExitCode(term: std.process.Child.Term) ?i64 {
    return switch (term) {
        .exited => |code| @intCast(code),
        else => null,
    };
}

fn termSignal(term: std.process.Child.Term) ?u32 {
    return switch (term) {
        .signal => |sig| @intFromEnum(sig),
        else => null,
    };
}

fn writePreviewEnvelope(alloc: Allocator, writer: *std.Io.Writer, label: []const u8, preview: StreamPreviewSnapshot) !void {
    if (preview.total_bytes == 0) return;

    try writer.print("<{s}>\n", .{label});
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    if (preview.total_bytes <= preview.max_bytes) {
        var full: std.Io.Writer.Allocating = .init(scratch);
        defer full.deinit();
        try full.writer.writeAll(preview.head);
        const overlap = if (preview.head.len + preview.tail.len > preview.total_bytes)
            preview.head.len + preview.tail.len - preview.total_bytes
        else
            0;
        if (preview.tail.len > overlap) try full.writer.writeAll(preview.tail[overlap..]);
        const safe = try text_utils.sanitizeModelText(scratch, full.writer.buffered());
        try writer.writeAll(safe);
        if (!std.mem.endsWith(u8, safe, "\n")) try writer.writeByte('\n');
        try writer.print("</{s}>\n", .{label});
        return;
    }

    const safe_head = try text_utils.sanitizeModelText(scratch, preview.head);
    const safe_tail = try text_utils.sanitizeModelText(scratch, preview.tail);
    const omitted = preview.total_bytes - preview.max_bytes;
    if (safe_head.len > 0) {
        try writer.writeAll(safe_head);
        if (!std.mem.endsWith(u8, safe_head, "\n")) try writer.writeByte('\n');
    }
    try writer.print("[... {d} bytes truncated ...]\n", .{omitted});
    if (safe_tail.len > 0) {
        try writer.writeAll(safe_tail);
        if (!std.mem.endsWith(u8, safe_tail, "\n")) try writer.writeByte('\n');
    }
    try writer.print("</{s}>\n", .{label});
}

const TerminationSource = enum {
    // Cancellation and timeout share a signal path, so retain the initiating
    // source until after the child is reaped.
    natural,
    cancelled,
    timed_out,
};

const OutputChunkEmitter = struct {
    stdout_pending: std.ArrayList(u8) = .empty,
    stderr_pending: std.ArrayList(u8) = .empty,

    fn deinit(self: *@This(), arena: Allocator) void {
        self.stdout_pending.deinit(arena);
        self.stderr_pending.deinit(arena);
    }

    fn append(
        self: *@This(),
        arena: Allocator,
        output: *OutputCollector,
        stream: CommandOutputStream,
        bytes: []const u8,
        cfg: Config,
    ) !void {
        try output.append(stream, bytes);
        try emitAcceptedOutputChunk(cfg, stream, bytes);
        try emitPending(arena, self.pendingFor(stream), stream, bytes, cfg, false);
    }

    fn flush(self: *@This(), arena: Allocator, cfg: Config) !void {
        try emitPending(arena, &self.stdout_pending, .stdout, "", cfg, true);
        try emitPending(arena, &self.stderr_pending, .stderr, "", cfg, true);
    }

    fn pendingFor(self: *@This(), stream: CommandOutputStream) *std.ArrayList(u8) {
        return switch (stream) {
            .stdout => &self.stdout_pending,
            .stderr => &self.stderr_pending,
        };
    }

    fn emitPending(
        arena: Allocator,
        pending: *std.ArrayList(u8),
        stream: CommandOutputStream,
        new_bytes: []const u8,
        cfg: Config,
        flush_remainder: bool,
    ) !void {
        const ctx = cfg.output_chunk_ctx orelse return;
        const callback = cfg.on_output_chunk orelse return;
        if (new_bytes.len > 0) try pending.appendSlice(arena, new_bytes);

        while (std.mem.findScalar(u8, pending.items, '\n')) |newline_index| {
            const line = pending.items[0 .. newline_index + 1];
            try emitOutputChunk(ctx, callback, cfg.output_chunk_lifecycle_id, stream, line, cfg.callback_projection);

            const remaining = pending.items.len - (newline_index + 1);
            std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[newline_index + 1 ..]);
            pending.items.len = remaining;
        }

        if (!flush_remainder and pending.items.len >= pending_output_flush_bytes) {
            try emitOutputChunk(ctx, callback, cfg.output_chunk_lifecycle_id, stream, pending.items, cfg.callback_projection);
            pending.clearRetainingCapacity();
        }

        if (flush_remainder and pending.items.len > 0) {
            try emitOutputChunk(ctx, callback, cfg.output_chunk_lifecycle_id, stream, pending.items, cfg.callback_projection);
            pending.clearRetainingCapacity();
        }
    }
};

const ForegroundLaunchFailureProbe = struct {
    const Status = enum {
        matching,
        passthrough,
        failed,
    };

    expected: []const u8,
    status: Status = .matching,
    pending: [foreground_session_replace_failure_marker_bytes]u8 = undefined,
    pending_len: usize = 0,
    error_name: [foreground_session_replace_error_name_bytes]u8 = undefined,
    error_name_len: usize = 0,
    error_name_done: bool = false,
    error_name_invalid: bool = false,
    replacement_error: ?std.process.ReplaceError = null,

    fn init(expected: []const u8) @This() {
        std.debug.assert(expected.len <= foreground_session_replace_failure_marker_bytes);
        return .{ .expected = expected };
    }

    fn append(
        self: *@This(),
        arena: Allocator,
        emitter: *OutputChunkEmitter,
        output: *OutputCollector,
        bytes: []const u8,
        cfg: Config,
    ) !void {
        switch (self.status) {
            .passthrough => return emitter.append(
                arena,
                output,
                .stderr,
                bytes,
                cfg,
            ),
            .failed => return self.appendErrorName(bytes),
            .matching => {},
        }

        var index: usize = 0;
        while (index < bytes.len) : (index += 1) {
            self.pending[self.pending_len] = bytes[index];
            self.pending_len += 1;

            if (!std.mem.eql(
                u8,
                self.pending[0..self.pending_len],
                self.expected[0..self.pending_len],
            )) {
                self.status = .passthrough;
                try emitter.append(
                    arena,
                    output,
                    .stderr,
                    self.pending[0..self.pending_len],
                    cfg,
                );
                if (index + 1 < bytes.len) {
                    try emitter.append(
                        arena,
                        output,
                        .stderr,
                        bytes[index + 1 ..],
                        cfg,
                    );
                }
                return;
            }
            if (self.pending_len == self.expected.len) {
                self.status = .failed;
                if (index + 1 < bytes.len) {
                    self.appendErrorName(bytes[index + 1 ..]);
                }
                return;
            }
        }
    }

    fn appendErrorName(self: *@This(), bytes: []const u8) void {
        if (self.error_name_done) return;
        for (bytes) |byte| {
            if (byte == '\n') {
                self.error_name_done = true;
                if (!self.error_name_invalid) {
                    self.replacement_error = parseReplaceError(self.error_name[0..self.error_name_len]);
                }
                return;
            }
            if (self.error_name_len == self.error_name.len) {
                self.error_name_invalid = true;
                continue;
            }
            self.error_name[self.error_name_len] = byte;
            self.error_name_len += 1;
        }
    }

    fn flush(
        self: *@This(),
        arena: Allocator,
        emitter: *OutputChunkEmitter,
        output: *OutputCollector,
        cfg: Config,
    ) !void {
        if (self.status != .matching or self.pending_len == 0) return;
        self.status = .passthrough;
        try emitter.append(
            arena,
            output,
            .stderr,
            self.pending[0..self.pending_len],
            cfg,
        );
    }
};

fn parseReplaceError(name: []const u8) ?std.process.ReplaceError {
    inline for (std.meta.fields(std.process.ReplaceError)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @field(std.process.ReplaceError, field.name);
        }
    }
    return null;
}

fn collectOutput(
    arena: Allocator,
    child: *std.process.Child,
    output: *OutputCollector,
    cfg: Config,
    source: *TerminationSource,
    launch_failure_probe: ?*ForegroundLaunchFailureProbe,
    process_group_id: ?std.posix.pid_t,
    leader_term: *?std.process.Child.Term,
) !TerminationSource {
    const zio = io_mod.getIo();
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(arena, zio, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_r = multi_reader.reader(0);
    const stderr_r = multi_reader.reader(1);

    var emitter: OutputChunkEmitter = .{};
    defer emitter.deinit(arena);

    const started_ms = ExecutionControl.init(cfg).started_ms;
    var signal_started_ms: ?i64 = null;
    var force_kill_sent = false;
    var streams_finished = false;

    while (true) {
        try updateTerminationSignal(
            child,
            process_group_id,
            cfg,
            started_ms,
            source,
            &signal_started_ms,
            &force_kill_sent,
        );
        if (leader_term.* == null) {
            if (try pollProcessLeader(child)) |term| {
                leader_term.* = term;
                if (process_group_id) |pid| {
                    if (source.* == .natural) {
                        terminateRemainingProcessGroup(pid);
                        debug_trace.logf(
                            "core",
                            "captured command leader completed; remaining process group terminated",
                            .{},
                        );
                    } else {
                        debug_trace.logf(
                            "core",
                            "captured command leader completed during {s}; remaining process group retains termination grace",
                            .{@tagName(source.*)},
                        );
                    }
                }
            }
        }

        if (streams_finished) {
            if (source.* == .natural or
                signal_started_ms == null or
                force_kill_sent or
                !remainingProcessGroupAlive(process_group_id))
            {
                break;
            }
            io_mod.sleep(10 * std.time.ns_per_ms);
            continue;
        }

        const keep_reading = if (multi_reader.fill(4096, .{ .duration = .{ .raw = .{ .nanoseconds = 100_000_000 }, .clock = .awake } }))
            true
        else |err| switch (err) {
            error.EndOfStream => false,
            error.Timeout => true,
            else => |e| return e,
        };

        const stdout_buf = stdout_r.buffered();
        const stderr_buf = stderr_r.buffered();
        if (stdout_buf.len > 0) {
            try emitter.append(arena, output, .stdout, stdout_buf, cfg);
            stdout_r.tossBuffered();
        }
        if (stderr_buf.len > 0) {
            if (launch_failure_probe) |probe| {
                try probe.append(arena, &emitter, output, stderr_buf, cfg);
            } else {
                try emitter.append(arena, output, .stderr, stderr_buf, cfg);
            }
            stderr_r.tossBuffered();
        }

        if (!keep_reading) {
            streams_finished = true;
            if (source.* == .natural or
                signal_started_ms == null or
                force_kill_sent or
                !remainingProcessGroupAlive(process_group_id))
            {
                break;
            }
        }
    }

    if (launch_failure_probe) |probe| {
        try probe.flush(arena, &emitter, output, cfg);
    }
    try emitter.flush(arena, cfg);
    return source.*;
}

fn collectOutputForProcess(
    arena: Allocator,
    child: *std.process.Child,
    output: *OutputCollector,
    cfg: Config,
    launch_failure_probe: ?*ForegroundLaunchFailureProbe,
    process_group_id: ?std.posix.pid_t,
    leader_term: *?std.process.Child.Term,
) !TerminationSource {
    var source: TerminationSource = .natural;
    return collectOutput(
        arena,
        child,
        output,
        cfg,
        &source,
        launch_failure_probe,
        process_group_id,
        leader_term,
    ) catch |err|
        return mapTerminationError(source, cfg.cancel_flag, "output collection", err);
}

fn waitForCollectedProcess(
    child: *std.process.Child,
    source: TerminationSource,
    process_group_id: ?std.posix.pid_t,
    leader_term: ?std.process.Child.Term,
) !std.process.Child.Term {
    if (leader_term) |term| {
        closeChildPipes(child);
        return term;
    }
    const term = child.wait(io_mod.getIo()) catch |err|
        return mapTerminationError(source, null, "process wait", err);
    if (process_group_id) |pid| {
        terminateRemainingProcessGroup(pid);
    }
    return term;
}

fn pollProcessLeader(child: *std.process.Child) !?std.process.Child.Term {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    const pid = child.id orelse return null;
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const result = std.posix.system.waitpid(pid, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return null;
                if (result != pid) return error.Unexpected;
                child.id = null;
                return childTermFromStatus(@bitCast(status));
            },
            .INTR => continue,
            .CHILD => return error.Unexpected,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

fn childTermFromStatus(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .unknown = status };
}

fn mapTerminationError(
    source: TerminationSource,
    cancel_flag: ?*std.atomic.Value(bool),
    phase: []const u8,
    err: anyerror,
) anyerror {
    const effective_source: TerminationSource = if (source == .natural and cancelRequested(cancel_flag))
        .cancelled
    else
        source;
    return switch (effective_source) {
        .natural => err,
        .cancelled => blk: {
            debug_trace.logf("core", "cancelled command {s} failed err={s}", .{ phase, @errorName(err) });
            break :blk error.Cancelled;
        },
        .timed_out => blk: {
            debug_trace.logf("core", "timed out command {s} failed err={s}", .{ phase, @errorName(err) });
            break :blk error.TimeoutExpired;
        },
    };
}

fn updateTerminationSignal(
    child: *std.process.Child,
    process_group_id: ?std.posix.pid_t,
    cfg: Config,
    started_ms: i64,
    source: *TerminationSource,
    signal_started_ms: *?i64,
    force_kill_sent: *bool,
) !void {
    const now_ms = io_mod.milliTimestamp();
    if (signal_started_ms.* == null) {
        if (cancelRequested(cfg.cancel_flag)) {
            source.* = .cancelled;
            try signalChild(child, process_group_id, false);
            debug_trace.logf("core", "command termination requested source=cancelled", .{});
            signal_started_ms.* = now_ms;
        }
        if (signal_started_ms.* == null) {
            if (cfg.timeout_ms) |timeout_ms| {
                if (now_ms - started_ms >= @as(i64, @intCast(timeout_ms))) {
                    // Timeout uses the same signal path as cancellation but
                    // records a distinct source for the post-wait mapping.
                    source.* = .timed_out;
                    try signalChild(child, process_group_id, false);
                    debug_trace.logf("core", "command termination requested source=timeout", .{});
                    signal_started_ms.* = now_ms;
                }
            }
        }
    }

    if (signal_started_ms.*) |sent_ms| {
        if (!force_kill_sent.* and now_ms - sent_ms >= 800) {
            try signalChild(child, process_group_id, true);
            debug_trace.logf("core", "command force-killed after termination grace expired", .{});
            force_kill_sent.* = true;
        }
    }
}

fn emitOutputChunk(
    ctx: *anyopaque,
    callback: CommandOutputCallback,
    lifecycle_id: ?types.ToolLifecycleId,
    stream: CommandOutputStream,
    chunk: []const u8,
    projection: CallbackProjection,
) !void {
    if (chunk.len == 0) return;
    if (projection == .model_safe and !text_utils.isModelSafeText(chunk)) return;
    try callback(ctx, lifecycle_id, stream, chunk);
}

fn signalChild(
    child: *std.process.Child,
    process_group_id: ?std.posix.pid_t,
    force: bool,
) !void {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        child.kill(io_mod.getIo());
        return;
    }

    if (process_group_id) |pid| return signalProcessGroup(pid, force);
    const pid = child.id orelse return;
    return signalProcessGroup(pid, force);
}

fn signalProcessGroup(pid: std.posix.pid_t, force: bool) !void {
    std.posix.kill(-pid, if (force) std.posix.SIG.KILL else std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => return err,
    };
}

fn terminateRemainingProcessGroup(pid: std.posix.pid_t) void {
    signalProcessGroup(pid, true) catch |err| {
        debug_trace.logf(
            "core",
            "remaining captured process group cleanup failed err={s}",
            .{@errorName(err)},
        );
    };
}

fn remainingProcessGroupAlive(process_group_id: ?std.posix.pid_t) bool {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return false;
    const pid = process_group_id orelse return false;
    std.posix.kill(-pid, @enumFromInt(0)) catch |err| return switch (err) {
        error.ProcessNotFound => false,
        else => true,
    };
    return true;
}

fn cleanupChild(child: *std.process.Child) void {
    if (child.id == null) {
        closeChildPipes(child);
        return;
    }
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        child.kill(io_mod.getIo());
        return;
    }
    const pid = child.id orelse return;
    std.posix.kill(-pid, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => debug_trace.logf("core", "command cleanup kill failed err={s}", .{@errorName(err)}),
    };
    _ = child.wait(io_mod.getIo()) catch |err| {
        debug_trace.logf("core", "command cleanup wait failed err={s}", .{@errorName(err)});
    };
}

fn closeChildPipes(child: *std.process.Child) void {
    if (child.stdin) |input| {
        input.close(io_mod.getIo());
        child.stdin = null;
    }
    if (child.stdout) |output| {
        output.close(io_mod.getIo());
        child.stdout = null;
    }
    if (child.stderr) |output| {
        output.close(io_mod.getIo());
        child.stderr = null;
    }
}

fn shellQuote(arena: Allocator, input: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try out.writer.writeByte('\'');
    for (input) |ch| {
        if (ch == '\'') {
            try out.writer.writeAll("'\\''");
        } else {
            try out.writer.writeByte(ch);
        }
    }
    try out.writer.writeByte('\'');
    return try out.toOwnedSlice();
}

test "format output covers stdout stderr empty signal and unknown statuses" {
    const result = try formatOutput(std.testing.allocator, "printf hello", "/tmp", .{ .exited = 0 }, " hello\n", "", 3);
    defer std.testing.allocator.free(result.output);
    try std.testing.expectEqualStrings("exit_code=0\n<stdout>\nhello\n</stdout>\n", result.output);

    const both = try formatOutput(std.testing.allocator, "cmd", "/tmp", .{ .exited = 7 }, "out", "err", null);
    defer std.testing.allocator.free(both.output);
    try std.testing.expect(std.mem.find(u8, both.output, "exit_code=7\n") != null);
    try std.testing.expect(std.mem.find(u8, both.output, "<stdout>\nout\n</stdout>\n") != null);
    try std.testing.expect(std.mem.find(u8, both.output, "<stderr>\nerr\n</stderr>\n") != null);

    const none = try formatOutput(std.testing.allocator, "cmd", "/tmp", .{ .unknown = 9 }, "", "", null);
    defer std.testing.allocator.free(none.output);
    try std.testing.expectEqualStrings("process finished\n(no output)\n", none.output);

    const signaled = try formatOutput(std.testing.allocator, "cmd", "/tmp", .{ .signal = .TERM }, "", "", null);
    defer std.testing.allocator.free(signaled.output);
    try std.testing.expectEqualStrings("signal=15\n(no output)\n", signaled.output);
}

test "raw process execution returns foreground output" {
    const result = try executeCommand(.{
        .max_command_output_bytes = 4096,
    }, std.testing.allocator, "printf 'hello'", "/tmp");
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(std.mem.find(u8, result.output, "exit_code=0\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "<stdout>\nhello\n</stdout>\n") != null);
    const command_result = result.command_result.?.foreground;
    try std.testing.expectEqualStrings("printf 'hello'", command_result.command);
    try std.testing.expectEqualStrings("/tmp", command_result.cwd);
    try std.testing.expectEqual(@as(?i64, 0), command_result.exit_code);
    try std.testing.expectEqual(@as(?u32, null), command_result.signal);
    try std.testing.expect(!command_result.timed_out);
    try std.testing.expectEqual(@as(usize, 5), command_result.stdout_bytes);
    try std.testing.expectEqual(@as(usize, 0), command_result.stderr_bytes);
    try std.testing.expect(!command_result.truncated);
}

test "authorized command executes exactly once" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(cwd);
    const marker = try std.fs.path.join(alloc, &.{ cwd, "attempts" });
    defer alloc.free(marker);
    const quoted_marker = try shellQuote(alloc, marker);
    defer alloc.free(quoted_marker);
    const command = try std.fmt.allocPrint(alloc, "printf x >> {s}", .{quoted_marker});
    defer alloc.free(command);

    const result = try executeCommand(.{
        .max_command_output_bytes = 4096,
    }, alloc, command, cwd);
    defer alloc.free(result.output);

    const attempts = try readAbsoluteFile(alloc, marker, 16);
    defer alloc.free(attempts);
    try std.testing.expectEqualStrings("x", attempts);
}

fn spawnForegroundSessionBootstrapForTest(
    workspace: []const u8,
    target_script: []const u8,
) !std.process.Child {
    const product_path = try foregroundSessionExecutable(std.testing.allocator);
    const argv = [_][]const u8{
        product_path,
        foreground_session_token,
        "test-nonce",
        "/bin/sh",
        "-c",
        target_script,
    };
    return std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = workspace },
    });
}

fn expectForegroundSessionReadyForTest(child: *std.process.Child) !void {
    const ready_read = child.stderr orelse return error.TestUnexpectedResult;
    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try std.posix.read(ready_read.handle, &ready));
    try std.testing.expectEqual(foreground_session_ready_byte, ready[0]);
}

fn expectChildExitCodeForTest(child: *std.process.Child, expected: u8) !void {
    switch (try child.wait(io_mod.getIo())) {
        .exited => |code| try std.testing.expectEqual(expected, code),
        else => return error.TestUnexpectedResult,
    }
}

fn expectRejectedForegroundSessionReleaseForTest(release: ?u8) !void {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const marker_path = try std.fs.path.join(alloc, &.{ workspace, "rejected-release-target.txt" });
    defer alloc.free(marker_path);
    const quoted_marker = try shellQuote(alloc, marker_path);
    defer alloc.free(quoted_marker);
    const target_script = try std.fmt.allocPrint(alloc, "printf unexpected > {s}", .{quoted_marker});
    defer alloc.free(target_script);

    var child = try spawnForegroundSessionBootstrapForTest(workspace, target_script);
    defer child.kill(io_mod.getIo());
    try expectForegroundSessionReadyForTest(&child);

    var release_write = child.stdin orelse return error.TestUnexpectedResult;
    child.stdin = null;
    if (release) |byte| try release_write.writeStreamingAll(io_mod.getIo(), &.{byte});
    release_write.close(io_mod.getIo());

    try expectChildExitCodeForTest(&child, 1);
    try std.testing.expect(!absoluteFileExists(marker_path));
}

fn spawnUnreadyForegroundSessionChildForTest(argv: []const []const u8) !std.process.Child {
    return std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
}

fn expectReapedChildForTest(child: *std.process.Child, pid: std.posix.pid_t) !void {
    try std.testing.expect(child.id == null);
    try std.testing.expectError(error.ProcessNotFound, std.posix.kill(pid, @enumFromInt(0)));
}

test "captured foreground command runs beneath a detached session supervisor" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const command =
        "exec python3 -c 'import os,sys; " ++
        "pid=os.getpid(); pgid=os.getpgid(0); sid=os.getsid(0); " ++
        "print(f\"pid={pid} pgid={pgid} sid={sid}\"); " ++
        "sys.exit(0 if pid != pgid and pgid == sid else 1)'";
    const result = try executeCommand(.{
        .max_command_output_bytes = 4096,
    }, std.testing.allocator, command, "/tmp");
    defer std.testing.allocator.free(result.output);

    try std.testing.expectEqual(@as(?i64, 0), result.command_result.?.foreground.exit_code);
}

test "foreground session bootstrap waits for release before executing target" {
    if (comptime !supports_foreground_session) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const marker_path = try std.fs.path.join(alloc, &.{ workspace, "released-target.txt" });
    defer alloc.free(marker_path);
    const quoted_marker = try shellQuote(alloc, marker_path);
    defer alloc.free(quoted_marker);
    const target_script = try std.fmt.allocPrint(alloc, "printf released > {s}", .{quoted_marker});
    defer alloc.free(target_script);
    var child = try spawnForegroundSessionBootstrapForTest(workspace, target_script);
    defer child.kill(io_mod.getIo());

    try expectForegroundSessionReadyForTest(&child);
    try std.testing.expect(!absoluteFileExists(marker_path));

    var release_write = child.stdin orelse return error.TestUnexpectedResult;
    child.stdin = null;
    try release_write.writeStreamingAll(
        io_mod.getIo(),
        &.{foreground_session_release_byte},
    );
    release_write.close(io_mod.getIo());

    try expectChildExitCodeForTest(&child, 0);
    const marker = try readAbsoluteFile(alloc, marker_path, 32);
    defer alloc.free(marker);
    try std.testing.expectEqualStrings("released", marker);
}

test "foreground session bootstrap EOF executes no target" {
    if (comptime !supports_foreground_session) return;
    try expectRejectedForegroundSessionReleaseForTest(null);
}

test "foreground session bootstrap invalid release executes no target" {
    if (comptime !supports_foreground_session) return;
    try expectRejectedForegroundSessionReleaseForTest(0xff);
}

test "foreground session protocol bytes do not enter captured output" {
    if (comptime !supports_foreground_session) return;

    const stdout_text = "stdout-bytes";
    const stderr_text = "stderr-bytes";
    const result = try executeCommand(.{
        .max_command_output_bytes = 4096,
    }, std.testing.allocator, "printf 'stdout-bytes'; printf 'stderr-bytes' >&2", "/tmp");
    defer std.testing.allocator.free(result.output);

    const foreground = result.command_result.?.foreground;
    try std.testing.expectEqual(stdout_text.len, foreground.stdout_bytes);
    try std.testing.expectEqual(stderr_text.len, foreground.stderr_bytes);
    try std.testing.expect(std.mem.findScalar(u8, result.output, foreground_session_ready_byte) == null);
    try std.testing.expect(std.mem.findScalar(u8, result.output, foreground_session_release_byte) == null);
    try std.testing.expect(std.mem.find(u8, result.output, foreground_session_replace_failure_prefix) == null);
    try std.testing.expect(std.mem.find(u8, result.output, stdout_text) != null);
    try std.testing.expect(std.mem.find(u8, result.output, stderr_text) != null);
}

test "target replacement marker prefix remains ordinary stderr" {
    if (comptime !supports_foreground_session) return;

    const stderr_text = foreground_session_replace_failure_prefix ++ "target-data\n";
    const result = try executeCommand(.{
        .max_command_output_bytes = 4096,
    }, std.testing.allocator, "printf '\\000FX_FOREGROUND_EXEC_FAILED:target-data\\n' >&2; exit 125", "/tmp");
    defer std.testing.allocator.free(result.output);

    const foreground = result.command_result.?.foreground;
    try std.testing.expectEqual(@as(?i64, 125), foreground.exit_code);
    try std.testing.expectEqual(@as(usize, 0), foreground.stdout_bytes);
    try std.testing.expectEqual(stderr_text.len, foreground.stderr_bytes);
    try std.testing.expect(std.mem.find(u8, result.output, stderr_text) != null);
}

test "invalid readiness directly kills and reaps helper pid" {
    if (comptime !supports_foreground_session) return;

    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "printf X >&2; exec /bin/sleep 2",
    };
    var child = try spawnUnreadyForegroundSessionChildForTest(&argv);
    defer child.kill(io_mod.getIo());
    const pid = child.id orelse return error.TestUnexpectedResult;
    const cfg = Config{
        .max_command_output_bytes = 1024,
    };

    try std.testing.expectError(
        error.InvalidForegroundSessionReady,
        waitForForegroundSessionReady(&child, cfg),
    );
    cleanupForegroundSessionChild(&child, .pre_ready);

    try expectReapedChildForTest(&child, pid);
}

test "readiness EOF directly kills and reaps helper pid" {
    if (comptime !supports_foreground_session) return;

    const argv = [_][]const u8{
        "/bin/sh",
        "-c",
        "exec 2>&-; exec /bin/sleep 2",
    };
    var child = try spawnUnreadyForegroundSessionChildForTest(&argv);
    defer child.kill(io_mod.getIo());
    const pid = child.id orelse return error.TestUnexpectedResult;
    const cfg = Config{
        .max_command_output_bytes = 1024,
    };

    try std.testing.expectError(
        error.ForegroundSessionSetupFailed,
        waitForForegroundSessionReady(&child, cfg),
    );
    cleanupForegroundSessionChild(&child, .pre_ready);

    try expectReapedChildForTest(&child, pid);
}

test "pre-ready cancellation directly kills and reaps helper pid" {
    if (comptime !supports_foreground_session) return;

    const argv = [_][]const u8{ "/bin/sleep", "2" };
    var child = try spawnUnreadyForegroundSessionChildForTest(&argv);
    defer child.kill(io_mod.getIo());
    const pid = child.id orelse return error.TestUnexpectedResult;
    var cancel = std.atomic.Value(bool).init(true);
    const cfg = Config{
        .max_command_output_bytes = 1024,
        .cancel_flag = &cancel,
    };

    try std.testing.expectError(error.CancelledBeforeExecution, waitForForegroundSessionReady(&child, cfg));
    const cleanup_started_ms = io_mod.milliTimestamp();
    cleanupForegroundSessionChild(&child, .pre_ready);
    const cleanup_elapsed_ms = io_mod.milliTimestamp() - cleanup_started_ms;

    try std.testing.expect(cleanup_elapsed_ms < 1000);
    try expectReapedChildForTest(&child, pid);
}

test "pre-ready configured timeout directly kills and reaps helper pid" {
    if (comptime !supports_foreground_session) return;

    const argv = [_][]const u8{ "/bin/sleep", "2" };
    var child = try spawnUnreadyForegroundSessionChildForTest(&argv);
    defer child.kill(io_mod.getIo());
    const pid = child.id orelse return error.TestUnexpectedResult;
    const cfg = Config{
        .max_command_output_bytes = 1024,
        .timeout_ms = 1,
        .timeout_started_ms = io_mod.milliTimestamp() - 10,
    };

    try std.testing.expectError(error.TimeoutExpired, waitForForegroundSessionReady(&child, cfg));
    const cleanup_started_ms = io_mod.milliTimestamp();
    cleanupForegroundSessionChild(&child, .pre_ready);
    const cleanup_elapsed_ms = io_mod.milliTimestamp() - cleanup_started_ms;

    try std.testing.expect(cleanup_elapsed_ms < 1000);
    try expectReapedChildForTest(&child, pid);
}

test "foreground session setup has a bounded internal ceiling" {
    if (comptime !supports_foreground_session) return;

    const argv = [_][]const u8{ "/bin/sleep", "7" };
    var child = try spawnUnreadyForegroundSessionChildForTest(&argv);
    defer child.kill(io_mod.getIo());
    const cfg = Config{
        .max_command_output_bytes = 1024,
    };

    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.ForegroundSessionSetupTimedOut,
        waitForForegroundSessionReady(&child, cfg),
    );
    const elapsed_ms = io_mod.milliTimestamp() - started_ms;
    cleanupForegroundSessionChild(&child, .pre_ready);

    try std.testing.expect(child.id == null);
    try std.testing.expect(elapsed_ms >= foreground_session_setup_timeout_ms);
    try std.testing.expect(elapsed_ms < foreground_session_setup_timeout_ms + 1500);
}

test "detached session preserves replacement failure with a zero output budget" {
    if (comptime !supports_foreground_session) return;

    var scratch_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_state.deinit();
    const argv = [_][]const u8{"/definitely/missing/fx-command-target"};

    try std.testing.expectError(
        error.FileNotFound,
        executeProcessWithDetachedSession(
            scratch_state.allocator(),
            .{
                .max_command_output_bytes = 0,
            },
            &argv,
            "/tmp",
            "",
        ),
    );
}

test "raw process execution transports long scripts without exposing stdin" {
    if (builtin.os.tag == .windows) return;

    const alloc = std.testing.allocator;
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(alloc);
    for (0..160) |_| {
        try script.appendSlice(
            alloc,
            "# long script transport filler ............................................................................................................................\n",
        );
    }
    try script.appendSlice(
        alloc,
        "if IFS= read -r value; then printf 'stdin=pipe:%s\\n' \"$value\"; else printf 'stdin=eof\\n'; fi\nprintf 'long-script-ok\\n'\n",
    );
    try std.testing.expect(script.items.len > 20 * 1024);

    const result = try executeCommand(.{
        .max_command_output_bytes = 4096,
    }, alloc, script.items, "/tmp");
    defer alloc.free(result.output);

    try std.testing.expect(std.mem.find(u8, result.output, "exit_code=0\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "stdin=eof\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "long-script-ok\n") != null);
}

test "large stdout writes command artifact and returns bounded preview" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "session/logs/commands");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const artifact_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session/logs/commands");
    defer alloc.free(artifact_dir);

    const output_text = "HEAD-1234567890-TAIL";
    const result = try executeCommand(.{
        .max_command_output_bytes = 16,
        .command_artifact_dir = artifact_dir,
    }, alloc, "printf 'HEAD-1234567890-TAIL'", workspace);
    defer alloc.free(result.output);

    try std.testing.expect(std.mem.find(u8, result.output, "exit_code=0\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "truncated=true\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "stdout_bytes=20\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "stderr_bytes=0\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "<stdout>\nHEAD\n[... 12 bytes truncated ...]\nTAIL\n</stdout>\n") != null);

    const output_path = metadataField(result.output, "output_file=").?;
    try std.testing.expect(std.mem.startsWith(u8, output_path, artifact_dir));
    const artifact = try readAbsoluteFile(alloc, output_path, 128);
    defer alloc.free(artifact);
    try std.testing.expectEqualStrings(output_text, artifact);
}

test "large stderr writes command artifact and returns bounded preview" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "session/logs/commands");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const artifact_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session/logs/commands");
    defer alloc.free(artifact_dir);

    const output_text = "ERR-1234567890-END";
    const result = try executeCommand(.{
        .max_command_output_bytes = 16,
        .command_artifact_dir = artifact_dir,
    }, alloc, "printf 'ERR-1234567890-END' >&2", workspace);
    defer alloc.free(result.output);

    try std.testing.expect(std.mem.find(u8, result.output, "exit_code=0\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "truncated=true\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "stdout_bytes=0\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "stderr_bytes=18\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "<stderr>\nERR-\n[... 10 bytes truncated ...]\n-END\n</stderr>\n") != null);

    const stderr_path = metadataField(result.output, "stderr_file=").?;
    try std.testing.expect(std.mem.startsWith(u8, stderr_path, artifact_dir));
    const artifact = try readAbsoluteFile(alloc, stderr_path, 128);
    defer alloc.free(artifact);
    try std.testing.expectEqualStrings(output_text, artifact);
}

const FailFirstCommandArtifactSync = struct {
    calls: usize = 0,

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *FailFirstCommandArtifactSync =
            @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == 1) return error.InjectedParentSyncFailure;
    }
};

const FailCommandArtifactSync = struct {
    calls: usize = 0,

    fn syncDir(raw: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *FailCommandArtifactSync =
            @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        return error.InjectedParentSyncFailure;
    }
};

test "managed command artifact confirms an indeterminate rename target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);
    const session_path = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "session",
    );
    defer alloc.free(session_path);
    const commands = try std.fs.path.join(
        alloc,
        &.{ session_path, "logs", "commands" },
    );
    defer alloc.free(commands);
    var session_dir = try tmp.dir.openDir(
        io_mod.getIo(),
        "session",
        .{
            .iterate = true,
            .follow_symlinks = false,
        },
    );
    defer session_dir.close(io_mod.getIo());
    var sync_state = FailFirstCommandArtifactSync{};
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{
            .replace_ops = .{
                .ctx = &sync_state,
                .sync_dir = FailFirstCommandArtifactSync.syncDir,
            },
        },
    );
    defer capability.deinit();

    const result = try executeCommand(.{
        .max_command_output_bytes = 8,
        .command_artifact_capability = &capability,
    }, alloc, "printf 'managed-command-output'", workspace);
    defer alloc.free(result.output);

    var entries = try capability.iterate(alloc, .command_artifacts);
    defer entries.deinit();
    try std.testing.expectEqual(@as(usize, 3), entries.names.len);
    const output_path = metadataField(result.output, "output_file=").?;
    try std.testing.expect(std.mem.startsWith(u8, output_path, commands));
    const output_handle = std.fs.path.basename(output_path);
    try std.testing.expect(!capability.hasIndeterminateEntry(
        .command_artifacts,
        output_handle,
    ));
    const output = try readAbsoluteFile(alloc, output_path, 128);
    defer alloc.free(output);
    var output_digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 =
        undefined;
    std.crypto.hash.sha2.Sha256.hash(output, &output_digest, .{});
    try std.testing.expect(artifact_digest.handleMatchesContentDigest(
        output_handle,
        command_artifact_log_suffix,
        output_digest,
    ));
    try std.testing.expectEqual(@as(usize, 2), sync_state.calls);
}

test "managed command artifact rejects an unconfirmed rename target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);
    const session_path = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "session",
    );
    defer alloc.free(session_path);
    var session_dir = try tmp.dir.openDir(
        io_mod.getIo(),
        "session",
        .{
            .iterate = true,
            .follow_symlinks = false,
        },
    );
    defer session_dir.close(io_mod.getIo());
    var sync_state = FailCommandArtifactSync{};
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{
            .replace_ops = .{
                .ctx = &sync_state,
                .sync_dir = FailCommandArtifactSync.syncDir,
            },
        },
    );
    defer capability.deinit();

    try std.testing.expectError(
        error.SessionChildCommitIndeterminate,
        executeCommand(.{
            .max_command_output_bytes = 8,
            .command_artifact_capability = &capability,
        }, alloc, "printf 'managed-command-output'", workspace),
    );
    try std.testing.expectEqual(@as(usize, 2), sync_state.calls);
    const pending = capability.indeterminateEntryName(
        .command_artifacts,
    ) orelse return error.TestExpectedEqual;
    _ = try capability.stat(.command_artifacts, pending);
}

fn metadataField(output: []const u8, prefix: []const u8) ?[]const u8 {
    var remaining = output;
    while (remaining.len > 0) {
        const line_end = std.mem.findScalar(u8, remaining, '\n') orelse remaining.len;
        const line = remaining[0..line_end];
        if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
        if (line_end == remaining.len) break;
        remaining = remaining[line_end + 1 ..];
    }
    return null;
}

fn readAbsoluteFile(alloc: Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_bytes);
}

fn absoluteFileExists(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return false;
    file.close(io_mod.getIo());
    return true;
}

const StreamCapture = struct {
    alloc: Allocator,
    chunks: std.ArrayList([]u8) = .empty,
    streams: std.ArrayList(CommandOutputStream) = .empty,

    fn onChunk(ctx: *anyopaque, _: ?types.ToolLifecycleId, stream: CommandOutputStream, chunk: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const owned = try self.alloc.dupe(u8, chunk);
        errdefer self.alloc.free(owned);
        try self.chunks.append(self.alloc, owned);
        errdefer self.chunks.items.len -= 1;
        try self.streams.append(self.alloc, stream);
    }

    fn deinit(self: *@This()) void {
        for (self.chunks.items) |chunk| self.alloc.free(chunk);
        self.chunks.deinit(self.alloc);
        self.streams.deinit(self.alloc);
    }

    fn contains(self: *const @This(), stream: CommandOutputStream, text: []const u8) bool {
        for (self.streams.items, self.chunks.items) |seen_stream, chunk| {
            if (seen_stream == stream and std.mem.eql(u8, chunk, text)) return true;
        }
        return false;
    }
};

const CancelAfterOutput = struct {
    flag: *std.atomic.Value(bool),
    needle: []const u8,
    seen: bool = false,

    fn onChunk(ctx: *anyopaque, _: ?types.ToolLifecycleId, _: CommandOutputStream, chunk: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (std.mem.find(u8, chunk, self.needle) == null) return;
        self.seen = true;
        self.flag.store(true, .seq_cst);
    }
};

const FailOutput = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    needle: ?[]const u8 = null,
    seen: bool = false,

    fn onChunk(ctx: *anyopaque, _: ?types.ToolLifecycleId, _: CommandOutputStream, chunk: []const u8) !void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.needle) |needle| {
            if (std.mem.find(u8, chunk, needle) == null) return;
        }
        self.seen = true;
        if (self.cancel_flag) |flag| flag.store(true, .seq_cst);
        return error.TestOutputCallbackFailure;
    }
};

test "line buffered streaming emits lines and tail" {
    var capture = StreamCapture{ .alloc = std.testing.allocator };
    defer capture.deinit();

    const result = try executeCommand(.{
        .max_command_output_bytes = 4096,
        .output_chunk_ctx = @ptrCast(&capture),
        .on_output_chunk = StreamCapture.onChunk,
    }, std.testing.allocator, "printf 'one\\ntwo'", "/tmp");
    defer std.testing.allocator.free(result.output);

    try std.testing.expectEqual(@as(usize, 2), capture.chunks.items.len);
    try std.testing.expectEqual(.stdout, capture.streams.items[0]);
    try std.testing.expectEqualStrings("one\n", capture.chunks.items[0]);
    try std.testing.expectEqualStrings("two", capture.chunks.items[1]);
}

test "line buffered streaming preserves stderr stream and tail" {
    var capture = StreamCapture{ .alloc = std.testing.allocator };
    defer capture.deinit();

    const result = try executeCommand(.{
        .max_command_output_bytes = 4096,
        .output_chunk_ctx = @ptrCast(&capture),
        .on_output_chunk = StreamCapture.onChunk,
    }, std.testing.allocator, "printf 'out\\n'; printf 'err\\ntail' >&2", "/tmp");
    defer std.testing.allocator.free(result.output);

    try std.testing.expectEqual(@as(usize, 3), capture.chunks.items.len);
    try std.testing.expect(capture.contains(.stdout, "out\n"));
    try std.testing.expect(capture.contains(.stderr, "err\n"));
    try std.testing.expect(capture.contains(.stderr, "tail"));
}

test "raw callback projection preserves bytes without changing command result" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var safe_capture = StreamCapture{ .alloc = std.testing.allocator };
    defer safe_capture.deinit();
    const safe_result = try executeCommand(.{
        .max_command_output_bytes = 4096,
        .output_chunk_ctx = @ptrCast(&safe_capture),
        .on_output_chunk = StreamCapture.onChunk,
    }, std.testing.allocator, "printf '\\000\\377'", "/tmp");
    defer std.testing.allocator.free(safe_result.output);
    try std.testing.expectEqual(@as(usize, 0), safe_capture.chunks.items.len);

    var raw_capture = StreamCapture{ .alloc = std.testing.allocator };
    defer raw_capture.deinit();
    const raw_result = try executeCommand(.{
        .max_command_output_bytes = 4096,
        .output_chunk_ctx = @ptrCast(&raw_capture),
        .on_output_chunk = StreamCapture.onChunk,
        .callback_projection = .raw,
    }, std.testing.allocator, "printf '\\000\\377'", "/tmp");
    defer std.testing.allocator.free(raw_result.output);

    try std.testing.expectEqual(@as(usize, 1), raw_capture.chunks.items.len);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0xff },
        raw_capture.chunks.items[0],
    );
    try std.testing.expectEqualSlices(u8, safe_result.output, raw_result.output);
}

test "accepted callbacks preserve repeated newline-free stream order" {
    var capture = StreamCapture{ .alloc = std.testing.allocator };
    defer capture.deinit();
    const cfg = Config{
        .max_command_output_bytes = 4096,
        .accepted_output_chunk_ctx = @ptrCast(&capture),
        .on_accepted_output_chunk = StreamCapture.onChunk,
    };
    var output = OutputCollector.init(std.testing.allocator, cfg);
    defer output.deinit();
    var emitter: OutputChunkEmitter = .{};
    defer emitter.deinit(std.testing.allocator);

    try emitter.append(std.testing.allocator, &output, .stderr, "E1", cfg);
    try emitter.append(std.testing.allocator, &output, .stdout, "O1", cfg);
    try emitter.append(std.testing.allocator, &output, .stderr, "E2", cfg);
    try emitter.append(std.testing.allocator, &output, .stdout, "O2", cfg);
    try emitter.flush(std.testing.allocator, cfg);

    try std.testing.expectEqual(@as(usize, 4), capture.chunks.items.len);
    try std.testing.expectEqual(.stderr, capture.streams.items[0]);
    try std.testing.expectEqualStrings("E1", capture.chunks.items[0]);
    try std.testing.expectEqual(.stdout, capture.streams.items[1]);
    try std.testing.expectEqualStrings("O1", capture.chunks.items[1]);
    try std.testing.expectEqual(.stderr, capture.streams.items[2]);
    try std.testing.expectEqualStrings("E2", capture.chunks.items[2]);
    try std.testing.expectEqual(.stdout, capture.streams.items[3]);
    try std.testing.expectEqualStrings("O2", capture.chunks.items[3]);
}

test "cancellation requested by a failing output callback dominates its error" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var cancel = std.atomic.Value(bool).init(false);
    var trigger = FailOutput{ .cancel_flag = &cancel };

    try std.testing.expectError(error.Cancelled, executeCommand(.{
        .max_command_output_bytes = 4096,
        .cancel_flag = &cancel,
        .output_chunk_ctx = @ptrCast(&trigger),
        .on_output_chunk = FailOutput.onChunk,
    }, std.testing.allocator, "printf 'CANCEL-AND-FAIL\\n'; sleep 5", "/tmp"));
    try std.testing.expect(trigger.seen);
}

test "cancellation preserves the termination grace beneath the session supervisor" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var cancel = std.atomic.Value(bool).init(false);
    var trigger = CancelAfterOutput{
        .flag = &cancel,
        .needle = "GRACE-READY",
    };
    const started_ms = io_mod.milliTimestamp();
    const result = try executeCommand(.{
        .max_command_output_bytes = 4096,
        .cancel_flag = &cancel,
        .output_chunk_ctx = @ptrCast(&trigger),
        .on_output_chunk = CancelAfterOutput.onChunk,
    }, std.testing.allocator, "trap 'sleep 3; exit 130' TERM; printf 'GRACE-READY\\n'; while :; do sleep 1; done", "/tmp");
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(trigger.seen);
    try std.testing.expect(result.cancelled);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms >= 500);
}

test "cancellation preserves the termination grace in an invoked script" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    {
        var script = try tmp.dir.createFile(
            io_mod.getIo(),
            "workspace/grace-script.sh",
            .{ .truncate = true },
        );
        defer script.close(io_mod.getIo());
        try script.writeStreamingAll(
            io_mod.getIo(),
            "#!/bin/sh\n" ++
                "trap 'sleep 3; exit 130' TERM\n" ++
                "printf 'GRACE-READY\\n'\n" ++
                "while :; do sleep 1; done\n",
        );
        try script.setPermissions(
            io_mod.getIo(),
            std.Io.File.Permissions.fromMode(0o700),
        );
    }

    var cancel = std.atomic.Value(bool).init(false);
    var trigger = CancelAfterOutput{
        .flag = &cancel,
        .needle = "GRACE-READY",
    };
    const started_ms = io_mod.milliTimestamp();
    const result = try executeCommand(.{
        .max_command_output_bytes = 4096,
        .cancel_flag = &cancel,
        .output_chunk_ctx = @ptrCast(&trigger),
        .on_output_chunk = CancelAfterOutput.onChunk,
    }, alloc, "./grace-script.sh", workspace);
    defer alloc.free(result.output);

    try std.testing.expect(trigger.seen);
    try std.testing.expect(result.cancelled);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms >= 500);
}

test "cap-crossing cancellation returns a synchronized bounded result" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "artifacts");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const artifact_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "artifacts");
    defer alloc.free(artifact_dir);

    var cancel = std.atomic.Value(bool).init(false);
    var trigger = CancelAfterOutput{
        .flag = &cancel,
        .needle = "CANCEL-READY",
    };
    const expected = "HEAD-1234567890-TAIL\nCANCEL-READY\n";
    const result = try executeCommand(.{
        .max_command_output_bytes = 16,
        .cancel_flag = &cancel,
        .output_chunk_ctx = @ptrCast(&trigger),
        .on_output_chunk = CancelAfterOutput.onChunk,
        .command_artifact_dir = artifact_dir,
    }, alloc, "trap 'exit 0' TERM; printf 'HEAD-1234567890-TAIL\\nCANCEL-READY\\n'; while :; do :; done", workspace);
    defer alloc.free(result.output);

    try std.testing.expect(trigger.seen);
    try std.testing.expect(result.cancelled);
    const foreground = result.command_result.?.foreground;
    try std.testing.expect(foreground.truncated);
    try std.testing.expectEqual(expected.len, foreground.stdout_bytes);
    try std.testing.expectEqual(@as(usize, 0), foreground.stderr_bytes);
    try std.testing.expect(std.mem.find(u8, result.output, "truncated=true\n") != null);
    try std.testing.expect(std.mem.find(u8, result.output, "bytes truncated") != null);

    const output_path = foreground.output_file orelse return error.TestExpectedEqual;
    const artifact = try readAbsoluteFile(alloc, output_path, 256);
    defer alloc.free(artifact);
    try std.testing.expectEqualStrings(expected, artifact);
}

test "cancelled managed command confirms an indeterminate artifact target" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    const workspace = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "workspace",
    );
    defer alloc.free(workspace);
    const session_path = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "session",
    );
    defer alloc.free(session_path);
    var session_dir = try tmp.dir.openDir(
        io_mod.getIo(),
        "session",
        .{
            .iterate = true,
            .follow_symlinks = false,
        },
    );
    defer session_dir.close(io_mod.getIo());
    var sync_state = FailFirstCommandArtifactSync{};
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        session_path,
        .writable,
        .{
            .replace_ops = .{
                .ctx = &sync_state,
                .sync_dir = FailFirstCommandArtifactSync.syncDir,
            },
        },
    );
    defer capability.deinit();

    var cancel = std.atomic.Value(bool).init(false);
    var trigger = CancelAfterOutput{
        .flag = &cancel,
        .needle = "CANCEL-READY",
    };
    const result = try executeCommand(.{
        .max_command_output_bytes = 8,
        .cancel_flag = &cancel,
        .output_chunk_ctx = @ptrCast(&trigger),
        .on_output_chunk = CancelAfterOutput.onChunk,
        .command_artifact_capability = &capability,
    }, alloc, "trap 'printf \"TERM-TAIL\\n\"; exit 0' TERM; printf 'CANCEL-READY\\n'; while :; do :; done", workspace);
    defer alloc.free(result.output);

    try std.testing.expect(trigger.seen);
    try std.testing.expect(result.cancelled);
    const foreground = result.command_result.?.foreground;
    const output_path = foreground.output_file orelse
        return error.TestExpectedEqual;
    const output_handle = std.fs.path.basename(output_path);
    try std.testing.expect(!capability.hasIndeterminateEntry(
        .command_artifacts,
        output_handle,
    ));
    const output = try readAbsoluteFile(alloc, output_path, 128);
    defer alloc.free(output);
    try std.testing.expect(std.mem.startsWith(
        u8,
        output,
        "CANCEL-READY\n",
    ));
    try std.testing.expect(std.mem.find(
        u8,
        output,
        "TERM-TAIL\n",
    ) != null);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
    try std.testing.expect(artifact_digest.handleMatchesContentDigest(
        output_handle,
        command_artifact_log_suffix,
        digest,
    ));
    var entries = try capability.iterate(alloc, .command_artifacts);
    defer entries.deinit();
    try std.testing.expectEqual(@as(usize, 3), entries.names.len);
    try std.testing.expectEqual(@as(usize, 2), sync_state.calls);
}

test "below-cap cancellation retains complete artifact and non-truncated metadata" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "artifacts");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const artifact_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "artifacts");
    defer alloc.free(artifact_dir);

    var cancel = std.atomic.Value(bool).init(false);
    var trigger = CancelAfterOutput{
        .flag = &cancel,
        .needle = "BELOW-CAP-READY",
    };
    const ready = "BELOW-CAP-READY-12345678901234567890123456789012345678901234567890\n";
    const term_tail = "TERM-TAIL-ONLY\n";
    const expected = ready ++ term_tail;
    const cap = 128;
    try std.testing.expect(expected.len > streamPreviewLimit(cap));
    try std.testing.expect(expected.len <= cap);

    const result = try executeCommand(.{
        .max_command_output_bytes = cap,
        .cancel_flag = &cancel,
        .output_chunk_ctx = @ptrCast(&trigger),
        .on_output_chunk = CancelAfterOutput.onChunk,
        .command_artifact_dir = artifact_dir,
    }, alloc, "trap 'printf \"TERM-TAIL-ONLY\\n\"; exit 0' TERM; printf 'BELOW-CAP-READY-12345678901234567890123456789012345678901234567890\\n'; while :; do :; done", workspace);
    defer alloc.free(result.output);

    try std.testing.expect(trigger.seen);
    try std.testing.expect(result.cancelled);
    try std.testing.expect(std.mem.find(u8, result.output, "bytes truncated") == null);
    try std.testing.expect(std.mem.find(u8, result.output, "truncated=false\n") != null);

    const foreground = result.command_result.?.foreground;
    try std.testing.expect(!foreground.truncated);
    try std.testing.expectEqual(expected.len, foreground.stdout_bytes);
    try std.testing.expectEqual(@as(usize, 0), foreground.stderr_bytes);
    const output_path = foreground.output_file orelse return error.TestExpectedEqual;
    const artifact = try readAbsoluteFile(alloc, output_path, 256);
    defer alloc.free(artifact);
    try std.testing.expectEqualStrings(expected, artifact);
}

test "zero-output cancellation remains a bare error" {
    var cancel = std.atomic.Value(bool).init(false);
    const Flip = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(120 * std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    };
    const thread = try std.Thread.spawn(.{}, Flip.run, .{&cancel});
    defer thread.join();

    try std.testing.expectError(error.Cancelled, executeCommand(.{
        .max_command_output_bytes = 1024,
        .cancel_flag = &cancel,
        .timeout_ms = 1000,
    }, std.testing.allocator, "exec sleep 5", "/tmp"));
}

test "artifact write failure after cancellation remains a bare error" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const ready_path = try std.fs.path.join(alloc, &.{ workspace, "cancel-ready" });
    defer alloc.free(ready_path);
    const quoted_ready = try shellQuote(alloc, ready_path);
    defer alloc.free(quoted_ready);
    const script = try std.fmt.allocPrint(
        alloc,
        "trap 'printf \"CANCEL-TAIL\\n\"; exit 0' TERM; : > {s}; while :; do :; done",
        .{quoted_ready},
    );
    defer alloc.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .cwd = .{ .path = workspace },
        .pgid = 0,
    });
    defer cleanupChild(&child);

    var cancel = std.atomic.Value(bool).init(false);
    const cfg = Config{
        .max_command_output_bytes = 1024,
        .cancel_flag = &cancel,
    };
    var output = OutputCollector.init(alloc, cfg);
    defer output.deinit();
    output.artifact = .{
        .output_file = "/dev/null",
        .stdout_file = "/dev/null",
        .stderr_file = "/dev/null",
        .output = .{ .external = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{}) },
        .stdout = .{ .external = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{}) },
        .stderr = .{ .external = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), "/dev/null", .{}) },
    };

    const Watcher = struct {
        fn run(path: []const u8, flag: *std.atomic.Value(bool), seen: *std.atomic.Value(bool)) void {
            const started_ms = io_mod.milliTimestamp();
            while (io_mod.milliTimestamp() - started_ms < 2000) {
                if (absoluteFileExists(path)) {
                    seen.store(true, .seq_cst);
                    break;
                }
                io_mod.sleep(10 * std.time.ns_per_ms);
            }
            flag.store(true, .seq_cst);
        }
    };
    var ready_seen = std.atomic.Value(bool).init(false);
    const watcher = try std.Thread.spawn(.{}, Watcher.run, .{ ready_path, &cancel, &ready_seen });
    defer watcher.join();

    const process_group_id = child.id;
    var leader_term: ?std.process.Child.Term = null;
    try std.testing.expectError(error.Cancelled, collectOutputForProcess(
        alloc,
        &child,
        &output,
        cfg,
        null,
        process_group_id,
        &leader_term,
    ));
    try std.testing.expect(ready_seen.load(.seq_cst));
}

test "timeout source is distinct from cancellation" {
    const result = try executeCommand(.{
        .max_command_output_bytes = 1024,
        .timeout_ms = 120,
    }, std.testing.allocator, "sleep 5", "/tmp");
    defer std.testing.allocator.free(result.output);

    const foreground = result.command_result.?.foreground;
    try std.testing.expect(foreground.timed_out);
    try std.testing.expectEqual(@as(?i64, null), foreground.exit_code);
    try std.testing.expectEqual(@as(?u32, null), foreground.signal);
    // Some shells report the signal they delivered to the foreground child on
    // stderr. That diagnostic is legitimate captured timeout output, so only
    // require the stable timeout marker here.
    try std.testing.expect(std.mem.startsWith(u8, result.output, "timed_out=true\n"));
}

test "timed out command keeps spilled partial output" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    try tmp.dir.createDirPath(io_mod.getIo(), "session/logs/commands");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const artifact_dir = try io_mod.dirRealpathAlloc(
        alloc,
        tmp.dir,
        "session/logs/commands",
    );
    defer alloc.free(artifact_dir);

    const output_text = "HEAD-1234567890-TAIL";
    const result = try executeCommand(.{
        .max_command_output_bytes = 16,
        .timeout_ms = 250,
        .command_artifact_dir = artifact_dir,
    }, alloc, "printf 'HEAD-1234567890-TAIL'; sleep 5", workspace);
    defer alloc.free(result.output);

    const foreground = result.command_result.?.foreground;
    try std.testing.expect(foreground.timed_out);
    try std.testing.expectEqual(output_text.len, foreground.stdout_bytes);
    try std.testing.expect(foreground.truncated);
    const stdout_path = foreground.stdout_file orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.startsWith(u8, stdout_path, artifact_dir));
    const artifact = try readAbsoluteFile(alloc, stdout_path, 128);
    defer alloc.free(artifact);
    try std.testing.expectEqualStrings(output_text, artifact);
}

test "timeout remains dominant when its output callback fails" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    var trigger = FailOutput{};
    try std.testing.expectError(error.TimeoutExpired, executeCommand(.{
        .max_command_output_bytes = 1024,
        .output_chunk_ctx = @ptrCast(&trigger),
        .on_output_chunk = FailOutput.onChunk,
        .timeout_ms = 120,
    }, std.testing.allocator, "trap 'echo TIMEOUT-FAIL; exit 0' TERM; while :; do :; done", "/tmp"));
    try std.testing.expect(trigger.seen);
}

test "timeout terminates foreground process group descendants" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
    defer alloc.free(workspace);
    const ready_path = try std.fs.path.join(alloc, &.{ workspace, "timeout-ready.txt" });
    defer alloc.free(ready_path);
    const quoted_ready = try shellQuote(alloc, ready_path);
    defer alloc.free(quoted_ready);
    const command = try std.fmt.allocPrint(
        alloc,
        "(while :; do :; done) & child=$!; printf '%s' \"$child\" > {s}; wait",
        .{quoted_ready},
    );
    defer alloc.free(command);

    const result = try executeCommand(.{
        .max_command_output_bytes = 1024,
        .timeout_ms = 500,
    }, alloc, command, workspace);
    defer alloc.free(result.output);
    try std.testing.expect(result.command_result.?.foreground.timed_out);

    const pid_text = try readAbsoluteFile(alloc, ready_path, 64);
    defer alloc.free(pid_text);
    const pid = try std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trim(u8, pid_text, " \t\r\n"),
        10,
    );

    const started_ms = io_mod.milliTimestamp();
    while (true) {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => break,
            else => return err,
        };
        if (io_mod.milliTimestamp() - started_ms > 1000) {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            return error.TestUnexpectedResult;
        }
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}

fn expectProcessGone(pid: std.posix.pid_t) !void {
    const started_ms = io_mod.milliTimestamp();
    while (true) {
        std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        if (io_mod.milliTimestamp() - started_ms > 1000) {
            std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            return error.TestUnexpectedResult;
        }
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}

test "natural command completion terminates background child inheriting pipes" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const pid_path = try std.fs.path.join(alloc, &.{ workspace, "inherited-child.pid" });
    defer alloc.free(pid_path);
    const quoted_pid_path = try shellQuote(alloc, pid_path);
    defer alloc.free(quoted_pid_path);
    const command = try std.fmt.allocPrint(
        alloc,
        "sleep 30 & child=$!; printf '%s' \"$child\" > {s}",
        .{quoted_pid_path},
    );
    defer alloc.free(command);

    const result = try executeCommand(.{
        .max_command_output_bytes = 1024,
        .timeout_ms = 2000,
    }, alloc, command, workspace);
    defer alloc.free(result.output);
    try std.testing.expectEqual(@as(?i64, 0), result.command_result.?.foreground.exit_code);

    const pid_text = try readAbsoluteFile(alloc, pid_path, 64);
    defer alloc.free(pid_text);
    const pid = try std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trim(u8, pid_text, " \t\r\n"),
        10,
    );
    try expectProcessGone(pid);
}

test "natural command completion terminates background child with redirected streams" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const pid_path = try std.fs.path.join(alloc, &.{ workspace, "redirected-child.pid" });
    defer alloc.free(pid_path);
    const quoted_pid_path = try shellQuote(alloc, pid_path);
    defer alloc.free(quoted_pid_path);
    const command = try std.fmt.allocPrint(
        alloc,
        "sleep 30 >/dev/null 2>&1 & child=$!; printf '%s' \"$child\" > {s}",
        .{quoted_pid_path},
    );
    defer alloc.free(command);

    const result = try executeCommand(.{
        .max_command_output_bytes = 1024,
        .timeout_ms = 2000,
    }, alloc, command, workspace);
    defer alloc.free(result.output);
    try std.testing.expectEqual(@as(?i64, 0), result.command_result.?.foreground.exit_code);

    const pid_text = try readAbsoluteFile(alloc, pid_path, 64);
    defer alloc.free(pid_text);
    const pid = try std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trim(u8, pid_text, " \t\r\n"),
        10,
    );
    try expectProcessGone(pid);
}

test "natural command completion terminates redirected descendant after setsid" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const pid_path = try std.fs.path.join(alloc, &.{ workspace, "escaped-child.pid" });
    defer alloc.free(pid_path);
    const command = try std.fmt.allocPrint(
        alloc,
        "python3 -c 'import os,time\n" ++
            "pid=os.fork()\n" ++
            "if pid == 0:\n" ++
            " os.setsid()\n" ++
            " null=os.open(\"/dev/null\",os.O_RDWR)\n" ++
            " os.dup2(null,0); os.dup2(null,1); os.dup2(null,2)\n" ++
            " open(\"{s}\",\"w\").write(str(os.getpid()))\n" ++
            " time.sleep(30)\n" ++
            "else:\n" ++
            " pass'",
        .{pid_path},
    );
    defer alloc.free(command);

    const result = try executeCommand(.{
        .max_command_output_bytes = 1024,
        .timeout_ms = 2000,
    }, alloc, command, workspace);
    defer alloc.free(result.output);
    try std.testing.expectEqual(@as(?i64, 0), result.command_result.?.foreground.exit_code);

    const pid_text = try readAbsoluteFile(alloc, pid_path, 64);
    defer alloc.free(pid_text);
    const pid = try std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trim(u8, pid_text, " \t\r\n"),
        10,
    );
    try expectProcessGone(pid);
}

test "cancellation preserves grace and removes an escaped descendant" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    const pid_path = try std.fs.path.join(alloc, &.{ workspace, "escaped-cancel.pid" });
    defer alloc.free(pid_path);
    const term_path = try std.fs.path.join(alloc, &.{ workspace, "escaped-cancel.term" });
    defer alloc.free(term_path);
    const command = try std.fmt.allocPrint(
        alloc,
        "python3 -c 'import os,signal,time\n" ++
            "pid=os.fork()\n" ++
            "if pid == 0:\n" ++
            " os.setsid()\n" ++
            " open(\"{s}\",\"w\").write(str(os.getpid()))\n" ++
            " def stop(signum,frame):\n" ++
            "  open(\"{s}\",\"w\").write(\"TERM\")\n" ++
            "  time.sleep(3)\n" ++
            "  raise SystemExit(130)\n" ++
            " signal.signal(signal.SIGTERM,stop)\n" ++
            " time.sleep(0.2)\n" ++
            " print(\"ESCAPED-GRACE-READY\",flush=True)\n" ++
            " while True: time.sleep(1)\n" ++
            "else:\n" ++
            " while True: time.sleep(1)'",
        .{ pid_path, term_path },
    );
    defer alloc.free(command);

    var cancel = std.atomic.Value(bool).init(false);
    var trigger = CancelAfterOutput{
        .flag = &cancel,
        .needle = "ESCAPED-GRACE-READY",
    };
    const started_ms = io_mod.milliTimestamp();
    const result = try executeCommand(.{
        .max_command_output_bytes = 4096,
        .cancel_flag = &cancel,
        .output_chunk_ctx = @ptrCast(&trigger),
        .on_output_chunk = CancelAfterOutput.onChunk,
    }, alloc, command, workspace);
    defer alloc.free(result.output);

    try std.testing.expect(trigger.seen);
    try std.testing.expect(result.cancelled);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms >= 500);
    const term_text = try readAbsoluteFile(alloc, term_path, 64);
    defer alloc.free(term_text);
    try std.testing.expectEqualStrings("TERM", term_text);
    const pid_text = try readAbsoluteFile(alloc, pid_path, 64);
    defer alloc.free(pid_text);
    const pid = try std.fmt.parseInt(
        std.posix.pid_t,
        std.mem.trim(u8, pid_text, " \t\r\n"),
        10,
    );
    try expectProcessGone(pid);
}

test "execution control reuses configured timeout start time" {
    const started_ms = io_mod.milliTimestamp() - 50;
    const control = ExecutionControl.init(.{
        .max_command_output_bytes = 1024,
        .timeout_ms = 1000,
        .timeout_started_ms = started_ms,
    });
    try std.testing.expectEqual(started_ms, control.started_ms);
}

test "cancel and timeout tie chooses cancellation" {
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.CancelledBeforeExecution, executeCommand(.{
        .max_command_output_bytes = 1024,
        .cancel_flag = &cancel,
        .timeout_ms = 1,
    }, std.testing.allocator, "sleep 5", "/tmp"));
}
