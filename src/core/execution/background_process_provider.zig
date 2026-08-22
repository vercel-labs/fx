const std = @import("std");
const builtin = @import("builtin");
const process_supervisor = @import("../background/process_supervisor.zig");

const Allocator = std.mem.Allocator;

pub const exit_marker = "__FX_EXIT_CODE__=";

pub fn isValidPidText(pid: []const u8) bool {
    if (pid.len == 0) return false;
    for (pid) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

pub const ProviderError = Allocator.Error ||
    std.process.SpawnError ||
    std.Io.File.ReadStreamingError ||
    std.Io.File.Writer.Error || error{
    Unsupported,
    SpawnFailed,
    BackgroundWrapperNotReady,
    BackgroundProcessIdentityIndeterminate,
    BackgroundProcessIdentityMismatch,
    BackgroundProcessIdentityUnavailable,
    BackgroundReleaseFailed,
    BackgroundLogUnavailable,
    ProcessIdentityUnavailable,
    ProcessIdentityUnsupported,
    ProcessNotFound,
    PermissionDenied,
    Unexpected,
    InvalidPid,
};

pub const Isolation = enum {
    none,
};

pub const OutputCapability = struct {
    /// Opaque, borrowed output authority supplied by the host composition.
    context: *const anyopaque,
};

pub const SpawnRequest = struct {
    cwd: []const u8,
    output: OutputCapability,
    isolation: Isolation,
};

pub const CleanupStatus = enum {
    confirmed,
    timed_out,
};

pub const OwnedProcess = struct {
    context: *anyopaque,
    wait_fn: *const fn (*anyopaque) void,
    forget_fn: *const fn (*anyopaque) void,

    /// Consumes the handle after the provider-owned child has exited.
    pub fn wait(self: *OwnedProcess) void {
        self.wait_fn(self.context);
        self.* = undefined;
    }

    /// Consumes the handle without changing the child process lifecycle.
    pub fn forget(self: *OwnedProcess) void {
        self.forget_fn(self.context);
        self.* = undefined;
    }
};

pub const PreparedProcess = struct {
    context: *anyopaque,
    /// Borrowed from `context` and valid until a consuming method succeeds.
    pid: []const u8,
    close_and_wait_fn: *const fn (
        *anyopaque,
        ?process_supervisor.ProcessInstanceToken,
        i64,
    ) CleanupStatus,
    wait_for_exit_fn: *const fn (
        *anyopaque,
        ?process_supervisor.ProcessInstanceToken,
        i64,
    ) bool,
    detach_reaper_fn: *const fn (*anyopaque) bool,
    release_fn: *const fn (*anyopaque, []const u8) ProviderError!OwnedProcess,

    /// Consumes the handle only when cleanup is confirmed.
    pub fn closeAndWaitUnreleased(
        self: *PreparedProcess,
        process_token: ?process_supervisor.ProcessInstanceToken,
        timeout_ms: i64,
    ) CleanupStatus {
        const status = self.close_and_wait_fn(
            self.context,
            process_token,
            timeout_ms,
        );
        if (status == .confirmed) self.* = undefined;
        return status;
    }

    /// Consumes the handle only when process exit is confirmed.
    pub fn waitForUnreleasedExit(
        self: *PreparedProcess,
        process_token: ?process_supervisor.ProcessInstanceToken,
        timeout_ms: i64,
    ) bool {
        const exited = self.wait_for_exit_fn(
            self.context,
            process_token,
            timeout_ms,
        );
        if (exited) self.* = undefined;
        return exited;
    }

    /// Consumes the handle only when the provider retains cleanup ownership.
    pub fn detachUnreleasedReaper(self: *PreparedProcess) bool {
        const detached = self.detach_reaper_fn(self.context);
        if (detached) self.* = undefined;
        return detached;
    }

    /// Releases the blocked command and consumes the prepared handle.
    pub fn release(
        self: *PreparedProcess,
        original_command: []const u8,
    ) ProviderError!OwnedProcess {
        const owned = try self.release_fn(self.context, original_command);
        self.* = undefined;
        return owned;
    }
};

pub const Provider = struct {
    /// Provider implementations own `context`; callers borrow it.
    context: ?*anyopaque = null,
    spawn_prepared_fn: *const fn (
        ?*anyopaque,
        Allocator,
        SpawnRequest,
    ) ProviderError!PreparedProcess,
    capture_token_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
    ) ProviderError!process_supervisor.ProcessInstanceToken,
    match_token_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
        process_supervisor.ProcessInstanceToken,
    ) process_supervisor.TokenMatch,
    signal_process_fn: *const fn (
        ?*anyopaque,
        Allocator,
        []const u8,
        process_supervisor.ProcessInstanceToken,
    ) ProviderError!void,

    pub fn spawnPrepared(
        self: Provider,
        alloc: Allocator,
        request: SpawnRequest,
    ) ProviderError!PreparedProcess {
        return self.spawn_prepared_fn(
            self.context,
            alloc,
            request,
        );
    }

    pub fn captureToken(
        self: Provider,
        alloc: Allocator,
        pid: []const u8,
    ) ProviderError!process_supervisor.ProcessInstanceToken {
        return self.capture_token_fn(self.context, alloc, pid);
    }

    pub fn matchToken(
        self: Provider,
        alloc: Allocator,
        pid: []const u8,
        expected: process_supervisor.ProcessInstanceToken,
    ) process_supervisor.TokenMatch {
        return self.match_token_fn(
            self.context,
            alloc,
            pid,
            expected,
        );
    }

    pub fn signalProcess(
        self: Provider,
        alloc: Allocator,
        pid: []const u8,
        expected: process_supervisor.ProcessInstanceToken,
    ) ProviderError!void {
        return self.signal_process_fn(
            self.context,
            alloc,
            pid,
            expected,
        );
    }
};

fn unsupportedSpawnPrepared(
    _: ?*anyopaque,
    _: Allocator,
    _: SpawnRequest,
) ProviderError!PreparedProcess {
    return error.Unsupported;
}

fn unsupportedCaptureToken(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
) ProviderError!process_supervisor.ProcessInstanceToken {
    return error.Unsupported;
}

fn unavailableMatchToken(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
    _: process_supervisor.ProcessInstanceToken,
) process_supervisor.TokenMatch {
    return .unavailable;
}

fn captureTokenThroughProcessSupervisor(
    _: ?*anyopaque,
    alloc: Allocator,
    pid: []const u8,
) ProviderError!process_supervisor.ProcessInstanceToken {
    return process_supervisor.captureProcessInstanceToken(
        alloc,
        pid,
    ) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPid => error.InvalidPid,
        error.ProcessNotFound => error.ProcessNotFound,
        error.ProcessIdentityUnavailable => error.ProcessIdentityUnavailable,
        else => error.ProcessIdentityUnsupported,
    };
}

fn matchTokenThroughProcessSupervisor(
    _: ?*anyopaque,
    alloc: Allocator,
    pid: []const u8,
    expected: process_supervisor.ProcessInstanceToken,
) process_supervisor.TokenMatch {
    return process_supervisor.matchProcessInstanceToken(
        alloc,
        pid,
        expected,
    );
}

fn unsupportedSignalProcess(
    _: ?*anyopaque,
    _: Allocator,
    _: []const u8,
    _: process_supervisor.ProcessInstanceToken,
) ProviderError!void {
    return error.Unsupported;
}

pub const unavailable_provider = Provider{
    .spawn_prepared_fn = unsupportedSpawnPrepared,
    .capture_token_fn = unsupportedCaptureToken,
    .match_token_fn = unavailableMatchToken,
    .signal_process_fn = unsupportedSignalProcess,
};

pub const process_supervisor_test_provider = if (builtin.is_test)
    Provider{
        .spawn_prepared_fn = unsupportedSpawnPrepared,
        .capture_token_fn = captureTokenThroughProcessSupervisor,
        .match_token_fn = matchTokenThroughProcessSupervisor,
        .signal_process_fn = unsupportedSignalProcess,
    }
else
    unavailable_provider;

test "unavailable provider does not consult process supervisor test hooks" {
    const Stub = struct {
        var calls: usize = 0;

        fn capture(
            _: Allocator,
            _: []const u8,
        ) anyerror!process_supervisor.ProcessInstanceToken {
            calls += 1;
            return error.ProcessNotFound;
        }
    };
    Stub.calls = 0;
    process_supervisor.process_token_capture_for_test = Stub.capture;
    defer process_supervisor.process_token_capture_for_test = null;

    try std.testing.expectError(
        error.Unsupported,
        unavailable_provider.captureToken(std.testing.allocator, "123"),
    );
    try std.testing.expectEqual(@as(usize, 0), Stub.calls);
}

test "provider routes lifecycle operations through one injected owner" {
    const Fake = struct {
        spawns: usize = 0,
        releases: usize = 0,
        waits: usize = 0,

        fn spawn(
            raw: ?*anyopaque,
            _: Allocator,
            request: SpawnRequest,
        ) ProviderError!PreparedProcess {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (!std.mem.eql(u8, request.cwd, "/workspace") or
                request.isolation != .none)
            {
                return error.SpawnFailed;
            }
            if (request.output.context != @as(*const anyopaque, @ptrCast(self))) {
                return error.SpawnFailed;
            }
            self.spawns += 1;
            return .{
                .context = self,
                .pid = "42",
                .close_and_wait_fn = close,
                .wait_for_exit_fn = waitForExit,
                .detach_reaper_fn = detach,
                .release_fn = release,
            };
        }

        fn release(raw: *anyopaque, command: []const u8) ProviderError!OwnedProcess {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (!std.mem.eql(u8, "npm run dev", command)) {
                return error.BackgroundReleaseFailed;
            }
            self.releases += 1;
            return .{
                .context = raw,
                .wait_fn = wait,
                .forget_fn = forget,
            };
        }

        fn wait(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.waits += 1;
        }

        fn forget(_: *anyopaque) void {}

        fn close(
            _: *anyopaque,
            _: ?process_supervisor.ProcessInstanceToken,
            _: i64,
        ) CleanupStatus {
            return .timed_out;
        }

        fn waitForExit(
            _: *anyopaque,
            _: ?process_supervisor.ProcessInstanceToken,
            _: i64,
        ) bool {
            return false;
        }

        fn detach(_: *anyopaque) bool {
            return false;
        }
    };

    var fake = Fake{};
    var provider = unavailable_provider;
    provider.context = &fake;
    provider.spawn_prepared_fn = Fake.spawn;
    var prepared = try provider.spawnPrepared(std.testing.allocator, .{
        .cwd = "/workspace",
        .output = .{ .context = &fake },
        .isolation = .none,
    });
    try std.testing.expectEqualStrings("42", prepared.pid);
    var owned = try prepared.release("npm run dev");
    owned.wait();

    try std.testing.expectEqual(@as(usize, 1), fake.spawns);
    try std.testing.expectEqual(@as(usize, 1), fake.releases);
    try std.testing.expectEqual(@as(usize, 1), fake.waits);
}
