const std = @import("std");
const io_mod = @import("../../core/shared/io.zig");
const builtin = @import("builtin");
const background_process_provider = @import(
    "../../core/execution/background_process_provider.zig",
);
const background_launch_output = @import(
    "../../core/background/background_launch_output.zig",
);
const debug_trace = @import("../../core/shared/debug_trace.zig");
const host = @import("../../core/hosts/host.zig");
const process_supervisor = @import(
    "../../core/background/process_supervisor.zig",
);

const Allocator = std.mem.Allocator;

const background_exit_marker = background_process_provider.exit_marker;
const background_release_byte: u8 = 0x06;
const background_ready_byte: u8 = 'R';
const blocked_background_wrapper_command = std.fmt.comptimePrint(
    "printf '{c}' >&2\n" ++
        "release=\n" ++
        "IFS= read -r release || exit 125\n" ++
        "expected=$(printf '\\006')\n" ++
        "[ \"$release\" = \"$expected\" ] || exit 125\n" ++
        "script=$(command cat; command printf .)\n" ++
        "script=${{script%.}}\n" ++
        "exec 0</dev/null\n" ++
        "exec 2>&1\n" ++
        "trap '' HUP\n" ++
        "eval \"$script\"\n" ++
        "status=$?\n" ++
        "printf '\\n{s}%s\\n' \"$status\"\n" ++
        "exit \"$status\"",
    .{ background_ready_byte, background_exit_marker },
);

pub const provider = background_process_provider.Provider{
    .spawn_prepared_fn = spawnPrepared,
    .capture_token_fn = captureToken,
    .match_token_fn = matchToken,
    .signal_process_fn = signalProcess,
};

const PreparedState = struct {
    alloc: Allocator,
    handshake: SpawnedBackgroundHandshake,
};

const OwnedState = struct {
    alloc: Allocator,
    child: std.process.Child,
};

fn spawnPrepared(
    _: ?*anyopaque,
    alloc: Allocator,
    request: background_process_provider.SpawnRequest,
) background_process_provider.ProviderError!background_process_provider.PreparedProcess {
    if (!host.current().background_processes) return error.Unsupported;

    const direct_argv = [_][]const u8{
        "sh",
        "-lc",
        blocked_background_wrapper_command,
        "fx-background",
    };
    const argv: []const []const u8 = &direct_argv;
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .cwd = .{ .path = request.cwd },
        .stdin = .pipe,
        .stdout = .{ .file = background_launch_output.Output
            .childStdioFileForProvider(request.output) },
        .stderr = .pipe,
    });
    var child_owned = true;
    errdefer if (child_owned) {
        if (child.stdin) |stdin| stdin.close(io_mod.getIo());
        if (child.stderr) |stderr| stderr.close(io_mod.getIo());
        child.stdin = null;
        child.stderr = null;
        _ = child.wait(io_mod.getIo()) catch {};
    };

    const child_id = child.id orelse return error.SpawnFailed;
    const pid = try std.fmt.allocPrint(alloc, "{d}", .{@intFromPtr(child_id)});
    var pid_owned = true;
    errdefer if (pid_owned) alloc.free(pid);

    var release_write = child.stdin orelse return error.SpawnFailed;
    child.stdin = null;
    var release_owned = true;
    errdefer if (release_owned) release_write.close(io_mod.getIo());
    var ready_read = child.stderr orelse return error.SpawnFailed;
    child.stderr = null;
    var ready_owned = true;
    errdefer if (ready_owned) ready_read.close(io_mod.getIo());

    var handshake = SpawnedBackgroundHandshake{
        .child = child,
        .ready_read = ready_read,
        .release_write = release_write,
        .pid = pid,
    };
    child_owned = false;
    pid_owned = false;
    release_owned = false;
    ready_owned = false;

    var ready: [1]u8 = undefined;
    const count = handshake.ready_read.readStreaming(
        io_mod.getIo(),
        &.{&ready},
    ) catch |err| return cleanupFailedHandshake(alloc, &handshake, err);
    if (count != 1 or ready[0] != background_ready_byte) {
        return cleanupFailedHandshake(
            alloc,
            &handshake,
            error.BackgroundWrapperNotReady,
        );
    }

    const state = alloc.create(PreparedState) catch {
        return cleanupFailedHandshake(
            alloc,
            &handshake,
            error.OutOfMemory,
        );
    };
    state.* = .{ .alloc = alloc, .handshake = handshake };
    return .{
        .context = state,
        .pid = state.handshake.pid,
        .close_and_wait_fn = closeAndWaitPrepared,
        .wait_for_exit_fn = waitForPreparedExit,
        .detach_reaper_fn = detachPreparedReaper,
        .release_fn = releasePrepared,
    };
}

fn cleanupFailedHandshake(
    alloc: Allocator,
    handshake: *SpawnedBackgroundHandshake,
    cause: background_process_provider.ProviderError,
) background_process_provider.ProviderError {
    if (handshake.closeAndWaitUnreleased(
        alloc,
        null,
        2000,
    ) == .confirmed) return cause;
    _ = handshake.detachUnreleasedReaper(alloc);
    return error.BackgroundProcessIdentityIndeterminate;
}

fn closeAndWaitPrepared(
    raw: *anyopaque,
    token: ?process_supervisor.ProcessInstanceToken,
    timeout_ms: i64,
) background_process_provider.CleanupStatus {
    const state: *PreparedState = @ptrCast(@alignCast(raw));
    const status = state.handshake.closeAndWaitUnreleased(
        state.alloc,
        token,
        timeout_ms,
    );
    if (status == .confirmed) state.alloc.destroy(state);
    return switch (status) {
        .confirmed => .confirmed,
        .timed_out => .timed_out,
    };
}

fn waitForPreparedExit(
    raw: *anyopaque,
    token: ?process_supervisor.ProcessInstanceToken,
    timeout_ms: i64,
) bool {
    const state: *PreparedState = @ptrCast(@alignCast(raw));
    const exited = state.handshake.waitForUnreleasedExit(
        state.alloc,
        token,
        timeout_ms,
    );
    if (exited) state.alloc.destroy(state);
    return exited;
}

fn detachPreparedReaper(raw: *anyopaque) bool {
    const state: *PreparedState = @ptrCast(@alignCast(raw));
    if (!state.handshake.detachUnreleasedReaper(state.alloc)) return false;
    state.alloc.destroy(state);
    return true;
}

fn releasePrepared(
    raw: *anyopaque,
    original_command: []const u8,
) background_process_provider.ProviderError!background_process_provider.OwnedProcess {
    const state: *PreparedState = @ptrCast(@alignCast(raw));
    const owned = try state.alloc.create(OwnedState);
    errdefer state.alloc.destroy(owned);

    try state.handshake.release_write.writeStreamingAll(
        io_mod.getIo(),
        &.{ background_release_byte, '\n' },
    );
    try state.handshake.release_write.writeStreamingAll(
        io_mod.getIo(),
        original_command,
    );
    state.handshake.release_write.close(io_mod.getIo());
    state.handshake.ready_read.close(io_mod.getIo());
    state.handshake.child.stdin = null;
    state.handshake.child.stderr = null;

    owned.* = .{ .alloc = state.alloc, .child = state.handshake.child };
    state.alloc.free(state.handshake.pid);
    state.alloc.destroy(state);
    return .{
        .context = owned,
        .wait_fn = waitOwned,
        .forget_fn = forgetOwned,
    };
}

fn waitOwned(raw: *anyopaque) void {
    const state: *OwnedState = @ptrCast(@alignCast(raw));
    _ = state.child.wait(io_mod.getIo()) catch {};
    state.alloc.destroy(state);
}

fn forgetOwned(raw: *anyopaque) void {
    const state: *OwnedState = @ptrCast(@alignCast(raw));
    state.alloc.destroy(state);
}

fn isValidPidText(pid: []const u8) bool {
    return background_process_provider.isValidPidText(pid);
}

fn captureToken(
    _: ?*anyopaque,
    alloc: Allocator,
    pid_text: []const u8,
) background_process_provider.ProviderError!process_supervisor.ProcessInstanceToken {
    const pid = std.fmt.parseInt(std.posix.pid_t, pid_text, 10) catch
        return error.InvalidPid;
    return switch (builtin.os.tag) {
        .linux => captureLinuxToken(alloc, pid) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ProcessNotFound => error.ProcessNotFound,
            else => error.ProcessIdentityUnavailable,
        },
        .macos => captureMacOSToken(pid) catch |err| switch (err) {
            error.ProcessNotFound => error.ProcessNotFound,
            else => error.ProcessIdentityUnavailable,
        },
        else => error.ProcessIdentityUnsupported,
    };
}

fn matchToken(
    context: ?*anyopaque,
    alloc: Allocator,
    pid: []const u8,
    expected: process_supervisor.ProcessInstanceToken,
) process_supervisor.TokenMatch {
    const actual = captureToken(context, alloc, pid) catch |err| {
        return if (err == error.ProcessNotFound) .missing else .unavailable;
    };
    return if (actual.eql(expected)) .matched else .mismatched;
}

fn readLinuxProcStat(file: std.Io.File, buffer: []u8) !usize {
    if (builtin.os.tag != .linux) return error.ProcessIdentityUnsupported;
    while (true) {
        // A process can disappear after open, and procfs reports that read as
        // ESRCH. Read directly so the expected race does not reach Zig's
        // unexpected-errno reporter before classification.
        const rc = std.posix.system.read(file.handle, buffer.ptr, buffer.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const read_len: usize = @intCast(rc);
                if (read_len == 0) return error.ProcessNotFound;
                return read_len;
            },
            .INTR => continue,
            .SRCH => return error.ProcessNotFound,
            else => return error.ProcessIdentityUnavailable,
        }
    }
}

fn captureLinuxToken(
    alloc: Allocator,
    pid: std.posix.pid_t,
) !process_supervisor.ProcessInstanceToken {
    const zio = io_mod.getIo();
    var boot_id_file = std.Io.Dir.openFileAbsolute(
        zio,
        "/proc/sys/kernel/random/boot_id",
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return error.ProcessIdentityUnavailable,
        else => return err,
    };
    defer boot_id_file.close(zio);
    var boot_id_text: [128]u8 = undefined;
    var boot_id_reader = boot_id_file.readerStreaming(zio, &.{});
    const boot_id_text_len = boot_id_reader.interface.readSliceShort(
        &boot_id_text,
    ) catch return boot_id_reader.err.?;

    var boot_id: [32]u8 = undefined;
    var boot_len: usize = 0;
    for (std.mem.trim(u8, boot_id_text[0..boot_id_text_len], " \r\n\t")) |byte| {
        if (byte == '-') continue;
        if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte) or
            boot_len == boot_id.len)
        {
            return error.ProcessIdentityUnavailable;
        }
        boot_id[boot_len] = byte;
        boot_len += 1;
    }
    if (boot_len != boot_id.len) return error.ProcessIdentityUnavailable;

    const stat_path = try std.fmt.allocPrint(alloc, "/proc/{d}/stat", .{pid});
    defer alloc.free(stat_path);
    var stat_file = std.Io.Dir.openFileAbsolute(
        zio,
        stat_path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return error.ProcessNotFound,
        else => return err,
    };
    defer stat_file.close(zio);
    var stat_text: [4096]u8 = undefined;
    const stat_text_len = try readLinuxProcStat(stat_file, &stat_text);
    const stat = stat_text[0..stat_text_len];

    const close_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse
        return error.ProcessIdentityUnavailable;
    var fields = std.mem.tokenizeScalar(
        u8,
        stat[close_paren + 1 ..],
        ' ',
    );
    var field_number: usize = 3;
    var start_ticks: ?[]const u8 = null;
    while (fields.next()) |field| : (field_number += 1) {
        if (field_number == 22) {
            start_ticks = field;
            break;
        }
    }
    const ticks = start_ticks orelse return error.ProcessIdentityUnavailable;
    _ = std.fmt.parseUnsigned(u64, ticks, 10) catch
        return error.ProcessIdentityUnavailable;

    var token_buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &token_buf,
        "linux:{s}:{s}",
        .{ boot_id[0..], ticks },
    );
    return process_supervisor.ProcessInstanceToken.parse(text);
}

fn captureMacOSToken(
    pid: std.posix.pid_t,
) !process_supervisor.ProcessInstanceToken {
    if (builtin.os.tag != .macos) return error.ProcessIdentityUnsupported;
    const ProcBsdInfo = extern struct {
        pbi_flags: u32,
        pbi_status: u32,
        pbi_xstatus: u32,
        pbi_pid: u32,
        pbi_ppid: u32,
        pbi_uid: u32,
        pbi_gid: u32,
        pbi_ruid: u32,
        pbi_rgid: u32,
        pbi_svuid: u32,
        pbi_svgid: u32,
        rfu_1: u32,
        pbi_comm: [16]u8,
        pbi_name: [32]u8,
        pbi_nfiles: u32,
        pbi_pgid: u32,
        pbi_pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        pbi_nice: i32,
        pbi_start_tvsec: u64,
        pbi_start_tvusec: u64,
    };
    const Darwin = struct {
        extern "c" fn proc_pidinfo(
            pid_value: c_int,
            flavor: c_int,
            arg: u64,
            buffer: *anyopaque,
            buffersize: c_int,
        ) c_int;
        extern "c" fn sysctlbyname(
            name: [*:0]const u8,
            oldp: ?*anyopaque,
            oldlenp: *usize,
            newp: ?*const anyopaque,
            newlen: usize,
        ) c_int;
    };

    var info: ProcBsdInfo = undefined;
    const read_len = Darwin.proc_pidinfo(
        pid,
        3,
        0,
        &info,
        @sizeOf(ProcBsdInfo),
    );
    if (read_len == 0) return error.ProcessNotFound;
    if (read_len != @sizeOf(ProcBsdInfo)) {
        return error.ProcessIdentityUnavailable;
    }

    var uuid_buf: [64]u8 = undefined;
    var uuid_len: usize = uuid_buf.len;
    if (Darwin.sysctlbyname(
        "kern.bootsessionuuid",
        &uuid_buf,
        &uuid_len,
        null,
        0,
    ) != 0) return error.ProcessIdentityUnavailable;

    var uuid: [32]u8 = undefined;
    var normalized_len: usize = 0;
    for (uuid_buf[0..uuid_len]) |byte| {
        if (byte == 0) break;
        if (byte == '-') continue;
        const lower = std.ascii.toLower(byte);
        if (!std.ascii.isHex(lower) or normalized_len == uuid.len) {
            return error.ProcessIdentityUnavailable;
        }
        uuid[normalized_len] = lower;
        normalized_len += 1;
    }
    if (normalized_len != uuid.len) return error.ProcessIdentityUnavailable;

    var token_buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &token_buf,
        "macos:{s}:{d}:{d}",
        .{ uuid[0..], info.pbi_start_tvsec, info.pbi_start_tvusec },
    );
    return process_supervisor.ProcessInstanceToken.parse(text);
}

const PidPair = struct {
    pid: std.posix.pid_t,
    ppid: std.posix.pid_t,
};

fn signalProcess(
    context: ?*anyopaque,
    alloc: Allocator,
    pid_text: []const u8,
    expected: process_supervisor.ProcessInstanceToken,
) background_process_provider.ProviderError!void {
    switch (matchToken(context, alloc, pid_text, expected)) {
        .matched => {},
        .missing, .mismatched => {
            return error.BackgroundProcessIdentityMismatch;
        },
        .unavailable => {
            return error.BackgroundProcessIdentityIndeterminate;
        },
    }
    if (!host.current().background_processes) return error.Unsupported;
    const pid = std.fmt.parseInt(std.posix.pid_t, pid_text, 10) catch
        return error.InvalidPid;
    try signalPidTree(pid);
}

fn signalPidTree(root_pid: std.posix.pid_t) std.posix.KillError!void {
    if (comptime @import("builtin").os.tag == .windows) return error.ProcessNotFound;
    const descendants = collectDescendantPids(
        std.heap.page_allocator,
        root_pid,
    ) catch |err| fallback: {
        debug_trace.logf(
            "background",
            "could not inspect background process descendants pid={d} err={s}",
            .{ root_pid, @errorName(err) },
        );
        break :fallback &[_]std.posix.pid_t{};
    };
    defer if (descendants.len > 0) {
        std.heap.page_allocator.free(descendants);
    };

    var signaled = false;
    var first_error: ?std.posix.KillError = null;
    sendSignal(-root_pid, std.posix.SIG.TERM, &signaled, &first_error);
    for (descendants) |pid| {
        sendSignal(pid, std.posix.SIG.TERM, &signaled, &first_error);
    }
    sendSignal(root_pid, std.posix.SIG.TERM, &signaled, &first_error);
    if (!signaled) return first_error orelse error.ProcessNotFound;

    waitForProcessTreeExit(root_pid, descendants, 250);
    var force_killed = false;
    for (descendants) |pid| {
        if (!isPidRunningRaw(pid)) continue;
        sendSignal(pid, std.posix.SIG.KILL, &force_killed, &first_error);
    }
    if (isPidRunningRaw(root_pid)) {
        sendSignal(
            root_pid,
            std.posix.SIG.KILL,
            &force_killed,
            &first_error,
        );
    }
    if (force_killed) {
        debug_trace.logf(
            "background",
            "force-killed lingering background process tree pid={d}",
            .{root_pid},
        );
    }
}

fn sendSignal(
    pid: std.posix.pid_t,
    signal: std.posix.SIG,
    signaled: *bool,
    first_error: *?std.posix.KillError,
) void {
    std.posix.kill(pid, signal) catch |err| {
        if (err != error.ProcessNotFound and first_error.* == null) {
            first_error.* = err;
        }
        return;
    };
    signaled.* = true;
}

fn waitForProcessTreeExit(
    root_pid: std.posix.pid_t,
    descendants: []const std.posix.pid_t,
    timeout_ms: i64,
) void {
    const start = io_mod.milliTimestamp();
    while (io_mod.milliTimestamp() - start < timeout_ms) {
        if (!anyProcessTreeMemberRunning(root_pid, descendants)) return;
        io_mod.sleep(25 * std.time.ns_per_ms);
    }
}

fn anyProcessTreeMemberRunning(
    root_pid: std.posix.pid_t,
    descendants: []const std.posix.pid_t,
) bool {
    if (isPidRunningRaw(root_pid)) return true;
    for (descendants) |pid| {
        if (isPidRunningRaw(pid)) return true;
    }
    return false;
}

fn isPidRunningRaw(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

fn collectDescendantPids(
    alloc: Allocator,
    root_pid: std.posix.pid_t,
) ![]std.posix.pid_t {
    const result = try std.process.run(alloc, io_mod.getIo(), .{
        .argv = &.{ "ps", "-axo", "pid=,ppid=" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(16 * 1024),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ProcessListFailed,
        else => return error.ProcessListFailed,
    }

    var pairs: std.ArrayList(PidPair) = .empty;
    defer pairs.deinit(alloc);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const pid_text = fields.next() orelse continue;
        const ppid_text = fields.next() orelse continue;
        const pid = std.fmt.parseInt(
            std.posix.pid_t,
            pid_text,
            10,
        ) catch continue;
        const ppid = std.fmt.parseInt(
            std.posix.pid_t,
            ppid_text,
            10,
        ) catch continue;
        try pairs.append(alloc, .{ .pid = pid, .ppid = ppid });
    }

    var descendants: std.ArrayList(std.posix.pid_t) = .empty;
    errdefer descendants.deinit(alloc);
    try appendDescendants(
        alloc,
        pairs.items,
        root_pid,
        &descendants,
    );
    return descendants.toOwnedSlice(alloc);
}

fn appendDescendants(
    alloc: Allocator,
    pairs: []const PidPair,
    parent_pid: std.posix.pid_t,
    descendants: *std.ArrayList(std.posix.pid_t),
) !void {
    for (pairs) |pair| {
        if (pair.ppid != parent_pid) continue;
        try appendDescendants(alloc, pairs, pair.pid, descendants);
        try descendants.append(alloc, pair.pid);
    }
}

test "native process adapter orders descendants deepest first" {
    const alloc = std.testing.allocator;
    const pairs = [_]PidPair{
        .{ .pid = 10, .ppid = 1 },
        .{ .pid = 11, .ppid = 10 },
        .{ .pid = 12, .ppid = 11 },
        .{ .pid = 13, .ppid = 10 },
        .{ .pid = 14, .ppid = 99 },
    };
    var descendants: std.ArrayList(std.posix.pid_t) = .empty;
    defer descendants.deinit(alloc);

    try appendDescendants(alloc, &pairs, 10, &descendants);

    try std.testing.expectEqualSlices(
        std.posix.pid_t,
        &.{ 12, 11, 13 },
        descendants.items,
    );
}

const SpawnedBackgroundHandshake = struct {
    child: std.process.Child,
    ready_read: std.Io.File,
    release_write: std.Io.File,
    pid: []u8,
    controls_closed: bool = false,

    fn closeAndWaitUnreleased(
        self: *SpawnedBackgroundHandshake,
        alloc: std.mem.Allocator,
        process_token: ?process_supervisor.ProcessInstanceToken,
        timeout_ms: i64,
    ) UnreleasedCleanupStatus {
        self.closeControls();
        if (!self.waitForOwnedChildExit(
            alloc,
            process_token,
            timeout_ms,
        )) return .timed_out;
        return .confirmed;
    }

    fn waitForUnreleasedExit(
        self: *SpawnedBackgroundHandshake,
        alloc: std.mem.Allocator,
        process_token: ?process_supervisor.ProcessInstanceToken,
        timeout_ms: i64,
    ) bool {
        return self.waitForOwnedChildExit(
            alloc,
            process_token,
            timeout_ms,
        );
    }

    fn detachUnreleasedReaper(
        self: *SpawnedBackgroundHandshake,
        alloc: std.mem.Allocator,
    ) bool {
        self.closeControls();
        const thread = std.Thread.spawn(
            .{},
            reapDetachedChild,
            .{self.child},
        ) catch return false;
        alloc.free(self.pid);
        self.* = undefined;
        thread.detach();
        return true;
    }

    fn closeControls(self: *SpawnedBackgroundHandshake) void {
        if (self.controls_closed) return;
        self.release_write.close(io_mod.getIo());
        self.ready_read.close(io_mod.getIo());
        self.child.stdin = null;
        self.child.stderr = null;
        self.controls_closed = true;
    }

    fn waitForOwnedChildExit(
        self: *SpawnedBackgroundHandshake,
        alloc: std.mem.Allocator,
        process_token: ?process_supervisor.ProcessInstanceToken,
        timeout_ms: i64,
    ) bool {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
            return waitForProcessExit(
                alloc,
                self.pid,
                process_token,
                timeout_ms,
            );
        }
        const started_ms = io_mod.milliTimestamp();
        while (true) {
            if (self.tryReapExitedChild(alloc)) return true;
            if (io_mod.milliTimestamp() - started_ms >= timeout_ms) {
                return false;
            }
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
    }

    fn tryReapExitedChild(
        self: *SpawnedBackgroundHandshake,
        alloc: std.mem.Allocator,
    ) bool {
        switch (builtin.os.tag) {
            .windows, .wasi => return false,
            else => {},
        }
        const pid = self.child.id orelse return true;
        // PID liveness includes zombies, so reap the child we directly own.
        if (std.c.waitpid(pid, null, std.c.W.NOHANG) != pid) return false;
        self.child.id = null;
        alloc.free(self.pid);
        self.* = undefined;
        return true;
    }
};

const UnreleasedCleanupStatus = enum {
    confirmed,
    timed_out,
};

fn reapDetachedChild(child: std.process.Child) void {
    var owned_child = child;
    _ = owned_child.wait(io_mod.getIo()) catch {};
}

fn waitForProcessExit(
    alloc: std.mem.Allocator,
    pid_text: []const u8,
    process_token: ?process_supervisor.ProcessInstanceToken,
    timeout_ms: i64,
) bool {
    const started_ms = io_mod.milliTimestamp();
    while (true) {
        const running = if (process_token) |token|
            switch (matchToken(null, alloc, pid_text, token)) {
                .matched, .unavailable => true,
                .missing, .mismatched => false,
            }
        else
            processExists(pid_text);
        if (!running) return true;
        if (io_mod.milliTimestamp() - started_ms >= timeout_ms) {
            return false;
        }
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}

fn processExists(pid_text: []const u8) bool {
    switch (builtin.os.tag) {
        .windows, .wasi => return true,
        else => {},
    }
    const pid = std.fmt.parseInt(
        std.posix.pid_t,
        pid_text,
        10,
    ) catch return false;
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

fn expectBlockedWrapperDoesNotExecute(
    alloc: std.mem.Allocator,
    cwd: []const u8,
    marker_path: []const u8,
    log_path: []const u8,
    release: ?u8,
) !void {
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), marker_path) catch {};
    var log_file = try std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        log_path,
        .{ .read = true, .truncate = true },
    );
    defer log_file.close(io_mod.getIo());
    const command = try std.fmt.allocPrint(
        alloc,
        "printf executed > '{s}'",
        .{marker_path},
    );
    defer alloc.free(command);
    const argv = [_][]const u8{
        "sh",
        "-lc",
        blocked_background_wrapper_command,
        "fx-background",
    };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .{ .file = log_file },
        .stderr = .pipe,
    });
    defer child.kill(io_mod.getIo());

    var ready: [1]u8 = undefined;
    const ready_count = try child.stderr.?.readStreaming(
        io_mod.getIo(),
        &.{&ready},
    );
    try std.testing.expectEqual(@as(usize, 1), ready_count);
    try std.testing.expectEqual(background_ready_byte, ready[0]);
    child.stderr.?.close(io_mod.getIo());
    child.stderr = null;

    if (release) |byte| {
        try child.stdin.?.writeStreamingAll(
            io_mod.getIo(),
            &.{ byte, '\n' },
        );
        try child.stdin.?.writeStreamingAll(io_mod.getIo(), command);
    }
    child.stdin.?.close(io_mod.getIo());
    child.stdin = null;
    _ = try child.wait(io_mod.getIo());

    if (std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        marker_path,
        .{},
    )) |file| {
        var unexpected = file;
        unexpected.close(io_mod.getIo());
        return error.BackgroundCommandExecutedBeforeRelease;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
}

test "blocked background wrapper rejects eof and invalid release without executing command" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const marker = try std.fs.path.join(alloc, &.{ root, "executed" });
    defer alloc.free(marker);
    const log_path = try std.fs.path.join(alloc, &.{ root, "background.log" });
    defer alloc.free(log_path);

    try expectBlockedWrapperDoesNotExecute(
        alloc,
        root,
        marker,
        log_path,
        null,
    );
    try expectBlockedWrapperDoesNotExecute(
        alloc,
        root,
        marker,
        log_path,
        0x7f,
    );
}

test "blocked background wrapper executes only after valid release" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const marker = try std.fs.path.join(
        alloc,
        &.{ root, "executed-after-release" },
    );
    defer alloc.free(marker);
    const log_path = try std.fs.path.join(
        alloc,
        &.{ root, "released.log" },
    );
    defer alloc.free(log_path);
    var log_file = try std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        log_path,
        .{ .read = true, .truncate = true },
    );
    defer log_file.close(io_mod.getIo());
    const command = try std.fmt.allocPrint(
        alloc,
        "printf executed > '{s}'",
        .{marker},
    );
    defer alloc.free(command);
    const argv = [_][]const u8{
        "sh",
        "-lc",
        blocked_background_wrapper_command,
        "fx-background",
    };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .cwd = .{ .path = root },
        .stdin = .pipe,
        .stdout = .{ .file = log_file },
        .stderr = .pipe,
    });
    defer child.kill(io_mod.getIo());

    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try child.stderr.?.readStreaming(
            io_mod.getIo(),
            &.{&ready},
        ),
    );
    try std.testing.expectEqual(background_ready_byte, ready[0]);
    child.stderr.?.close(io_mod.getIo());
    child.stderr = null;

    io_mod.sleep(25 * std.time.ns_per_ms);
    try std.testing.expect(!absoluteFileExistsForTest(marker));

    try child.stdin.?.writeStreamingAll(
        io_mod.getIo(),
        &.{ background_release_byte, '\n' },
    );
    try child.stdin.?.writeStreamingAll(io_mod.getIo(), command);
    child.stdin.?.close(io_mod.getIo());
    child.stdin = null;
    _ = try child.wait(io_mod.getIo());

    try std.testing.expect(absoluteFileExistsForTest(marker));
}

test "native provider transfers a prepared process to its owned handle" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const log_path = try std.fs.path.join(alloc, &.{ root, "provider.log" });
    defer alloc.free(log_path);
    var output_target = background_launch_output.Output{
        .external = .{
            .file = try std.Io.Dir.createFileAbsolute(
                io_mod.getIo(),
                log_path,
                .{ .read = true, .truncate = true },
            ),
            .path = try alloc.dupe(u8, log_path),
        },
    };
    defer output_target.deinit(alloc, true);

    var prepared = try provider.spawnPrepared(
        alloc,
        .{
            .cwd = root,
            .output = output_target.providerCapability(),
            .isolation = .none,
        },
    );
    var prepared_active = true;
    defer if (prepared_active) {
        _ = prepared.closeAndWaitUnreleased(null, 2000);
    };
    var owned = try prepared.release("printf provider-owned");
    prepared_active = false;
    owned.wait();

    const output = try readLogSnapshot(alloc, log_path);
    defer alloc.free(output);
    try std.testing.expect(
        std.mem.find(u8, output, "provider-owned") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, output, background_exit_marker ++ "0") != null,
    );
}

test "native provider captures the current process identity" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) {
        return error.SkipZigTest;
    }

    const alloc = std.testing.allocator;
    const pid = try std.fmt.allocPrint(alloc, "{d}", .{std.c.getpid()});
    defer alloc.free(pid);

    const token = try provider.captureToken(alloc, pid);
    const platform = if (builtin.os.tag == .linux) "linux:" else "macos:";
    try std.testing.expect(std.mem.startsWith(u8, token.view(), platform));
}

test "native provider writes through the verified borrowed output handle" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const log_path = try std.fs.path.join(
        alloc,
        &.{ root, "verified-output.log" },
    );
    defer alloc.free(log_path);
    var output = background_launch_output.Output{
        .external = .{
            .file = try std.Io.Dir.createFileAbsolute(
                io_mod.getIo(),
                log_path,
                .{ .read = true, .truncate = true },
            ),
            .path = try alloc.dupe(u8, log_path),
        },
    };
    defer output.deinit(alloc, true);

    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), log_path);
    try std.testing.expect(!absoluteFileExistsForTest(log_path));

    var prepared = try provider.spawnPrepared(
        alloc,
        .{
            .cwd = root,
            .output = output.providerCapability(),
            .isolation = .none,
        },
    );
    var prepared_active = true;
    defer if (prepared_active) {
        _ = prepared.closeAndWaitUnreleased(null, 2000);
    };
    var owned = try prepared.release("printf verified-handle");
    prepared_active = false;
    owned.wait();

    const output_file = output.childStdioFile();
    var bytes: [256]u8 = undefined;
    const count = try output_file.readPositionalAll(
        io_mod.getIo(),
        &bytes,
        0,
    );
    try std.testing.expect(
        std.mem.find(u8, bytes[0..count], "verified-handle") != null,
    );
    try std.testing.expect(!absoluteFileExistsForTest(log_path));
}

test "released background command does not inherit release pipe as stdin" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const log_path = try std.fs.path.join(
        alloc,
        &.{ root, "released-stdin.log" },
    );
    defer alloc.free(log_path);
    var log_file = try std.Io.Dir.createFileAbsolute(
        io_mod.getIo(),
        log_path,
        .{ .read = true, .truncate = true },
    );
    defer log_file.close(io_mod.getIo());
    const command =
        "if IFS= read -r inherited; then " ++
        "printf 'stdin=pipe:%s\\n' \"$inherited\"; " ++
        "else printf 'stdin=closed\\n'; fi";
    const argv = [_][]const u8{
        "sh",
        "-lc",
        blocked_background_wrapper_command,
        "fx-background",
    };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .cwd = .{ .path = root },
        .stdin = .pipe,
        .stdout = .{ .file = log_file },
        .stderr = .pipe,
    });
    defer child.kill(io_mod.getIo());

    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try child.stderr.?.readStreaming(
            io_mod.getIo(),
            &.{&ready},
        ),
    );
    try std.testing.expectEqual(background_ready_byte, ready[0]);
    child.stderr.?.close(io_mod.getIo());
    child.stderr = null;

    var release_write = child.stdin.?;
    child.stdin = null;
    try release_write.writeStreamingAll(
        io_mod.getIo(),
        &.{
            background_release_byte,
            '\n',
        },
    );
    try release_write.writeStreamingAll(io_mod.getIo(), command);
    release_write.close(io_mod.getIo());
    _ = try child.wait(io_mod.getIo());

    const output = try readLogSnapshot(alloc, log_path);
    defer alloc.free(output);
    try std.testing.expect(
        std.mem.find(u8, output, "stdin=closed\n") != null,
    );
    try std.testing.expect(
        std.mem.find(u8, output, "stdin=pipe:") == null,
    );
}

test "unreleased background cleanup reaps an exited child before token liveness" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return;

    const alloc = std.testing.allocator;
    const argv = [_][]const u8{
        "sh",
        "-lc",
        "printf R >&2; IFS= read -r release || exit 125",
    };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    var child_owned = true;
    errdefer if (child_owned) child.kill(io_mod.getIo());

    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try child.stderr.?.readStreaming(io_mod.getIo(), &.{&ready}),
    );
    try std.testing.expectEqual(background_ready_byte, ready[0]);

    const Stub = struct {
        fn match(
            _: []const u8,
            _: process_supervisor.ProcessInstanceToken,
        ) process_supervisor.TokenMatch {
            return .matched;
        }
    };
    process_supervisor.process_token_match_for_test = Stub.match;
    defer process_supervisor.process_token_match_for_test = null;
    const pid = try std.fmt.allocPrint(alloc, "{d}", .{@intFromPtr(child.id.?)});
    const token = try process_supervisor.ProcessInstanceToken.parse(
        "linux:00112233445566778899aabbccddeeff:12345",
    );
    var spawned = SpawnedBackgroundHandshake{
        .child = child,
        .ready_read = child.stderr.?,
        .release_write = child.stdin.?,
        .pid = pid,
    };
    child.stdin = null;
    child.stderr = null;
    child_owned = false;
    var spawned_active = true;
    defer if (spawned_active) {
        spawned.closeControls();
        _ = spawned.child.wait(io_mod.getIo()) catch {};
        alloc.free(spawned.pid);
    };

    try std.testing.expectEqual(
        UnreleasedCleanupStatus.confirmed,
        spawned.closeAndWaitUnreleased(alloc, token, 100),
    );
    spawned_active = false;
}

test "unreleased background wrapper cleanup is bounded" {
    const alloc = std.testing.allocator;
    const argv = [_][]const u8{
        "sh",
        "-lc",
        "printf R >&2; sleep 2",
    };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    errdefer child.kill(io_mod.getIo());

    var ready: [1]u8 = undefined;
    try std.testing.expectEqual(
        @as(usize, 1),
        try child.stderr.?.readStreaming(io_mod.getIo(), &.{&ready}),
    );
    try std.testing.expectEqual(background_ready_byte, ready[0]);

    const Stub = struct {
        fn match(
            _: []const u8,
            _: process_supervisor.ProcessInstanceToken,
        ) process_supervisor.TokenMatch {
            return .matched;
        }
    };
    process_supervisor.process_token_match_for_test = Stub.match;
    defer process_supervisor.process_token_match_for_test = null;
    const pid = try std.fmt.allocPrint(alloc, "{d}", .{@intFromPtr(child.id.?)});
    const token = try process_supervisor.ProcessInstanceToken.parse(
        "linux:00112233445566778899aabbccddeeff:12345",
    );
    var spawned = SpawnedBackgroundHandshake{
        .child = child,
        .ready_read = child.stderr.?,
        .release_write = child.stdin.?,
        .pid = pid,
    };
    child.stdin = null;
    child.stderr = null;

    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectEqual(
        UnreleasedCleanupStatus.timed_out,
        spawned.closeAndWaitUnreleased(alloc, token, 25),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1000);
    try std.testing.expectEqual(
        process_supervisor.TokenMatch.matched,
        process_supervisor.matchProcessInstanceToken(
            alloc,
            spawned.pid,
            token,
        ),
    );
    spawned.child.kill(io_mod.getIo());
    alloc.free(spawned.pid);
    spawned = undefined;
}

fn absoluteFileExistsForTest(path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        path,
        .{},
    ) catch return false;
    file.close(io_mod.getIo());
    return true;
}

fn readLogSnapshot(alloc: std.mem.Allocator, external_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(
        io_mod.getIo(),
        external_path,
        .{},
    );
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 64 * 1024);
}
