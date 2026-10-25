//! A kernel's Python process and its three pipes, whichever way it started.
//! A direct spawn is this process's child and is reaped with waitpid. A kernel
//! forked by the zygote is the zygote's child, which reaps it, so this side
//! signals it only while its pid still names the process it started (checked by
//! start time) and treats it as stopped once that process is gone. Either way
//! exit is detected by stdout EOF in the reader, interrupts travel as protocol
//! frames on stdin, and the runtime's owner watchdog ends the kernel if this
//! process dies.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const memory = @import("memory.zig");
const zygote = @import("zygote.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const Allocator = std.mem.Allocator;
const now = io_mod.monotonicMilliTimestamp;

pub const Process = struct {
    pid: std.posix.pid_t,
    stdin: std.Io.File,
    stdout: std.Io.File,
    stderr: std.Io.File,
    origin: Origin,
    /// Set by `kill`: the pipes are closed and the pid is no longer ours.
    gone: bool = false,

    pub const Origin = union(enum) {
        direct: std.process.Child,
        /// The start token from `memory.startToken`, or null when the process
        /// had already exited by the time it was read.
        forked: ?u64,
    };

    /// Whether the zygote forked it, for diagnostics and the benchmark.
    pub fn isForked(self: *const Process) bool {
        return self.origin == .forked;
    }

    /// Sends `sig` to a process that is still the one this kernel started.
    pub fn signal(self: *const Process, sig: std.posix.SIG) void {
        if (self.gone or !self.owns()) return;
        std.posix.kill(self.pid, sig) catch {};
    }

    fn owns(self: *const Process) bool {
        return switch (self.origin) {
            // Unreaped, so the pid cannot have been reused.
            .direct => true,
            .forked => self.ownsForked(),
        };
    }

    /// Stops the process, waits for it to exit, and closes the pipes. Safe to
    /// call again. A forked kernel gets TERM, then KILL if it is still there
    /// after two seconds; its reaping is the zygote's (or init's) job.
    pub fn kill(self: *Process) void {
        if (self.gone) return;
        self.gone = true;
        switch (self.origin) {
            .direct => |*child| {
                child.kill(io_mod.getIo());
                return;
            },
            .forked => {
                if (self.ownsForked()) {
                    std.posix.kill(self.pid, .TERM) catch {};
                    if (!self.awaitGone(2000)) {
                        std.posix.kill(self.pid, .KILL) catch {};
                        if (!self.awaitGone(1000)) debug_trace.logf("kernel", "forked kernel pid={d} outlived KILL", .{self.pid});
                    }
                }
                const io = io_mod.getIo();
                self.stdin.close(io);
                self.stdout.close(io);
                self.stderr.close(io);
            },
        }
    }

    fn ownsForked(self: *const Process) bool {
        const token = self.origin.forked orelse return false;
        return memory.startToken(self.pid) == token;
    }

    fn awaitGone(self: *const Process, timeout_ms: i64) bool {
        const deadline = now() + timeout_ms;
        while (self.ownsForked()) {
            if (now() >= deadline) return false;
            io_mod.sleep(2 * std.time.ns_per_ms);
        }
        return true;
    }
};

pub const SpawnOptions = struct {
    python: []const u8,
    runtime: []const u8,
    cwd: []const u8,
    env: *const std.process.Environ.Map,
};

/// Forks the kernel from the zygote when one can serve it, else spawns it
/// directly. The process belongs to the caller until `kill`.
pub fn spawn(alloc: Allocator, options: SpawnOptions) !Process {
    if (zygote.fork(alloc, options.python, options.runtime, options.cwd, options.env)) |forked| {
        return .{
            .pid = forked.pid,
            .stdin = forked.stdin,
            .stdout = forked.stdout,
            .stderr = forked.stderr,
            .origin = .{ .forked = memory.startToken(forked.pid) },
        };
    } else |err| if (err != error.ZygoteDisabled) {
        debug_trace.logf("kernel", "spawning directly: {s}", .{@errorName(err)});
    }
    const child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &.{ options.python, "-u", options.runtime },
        .cwd = .{ .path = options.cwd },
        .environ_map = options.env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    return .{
        .pid = child.id.?,
        .stdin = child.stdin.?,
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
        .origin = .{ .direct = child },
    };
}

// Runs only when PROTO_FX_KERNEL_TEST_PYTHON names a Python 3.11+ with dill.
test "a forked kernel interrupts, restarts and outlives a killed zygote, which is replaced" {
    const kernel = @import("kernel.zig");
    const alloc = std.testing.allocator;
    var runner_env = try std.process.Environ.createMap(std.testing.environ, alloc);
    defer runner_env.deinit();
    const python = runner_env.get("PROTO_FX_KERNEL_TEST_PYTHON") orelse return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const kernel_home = try std.Io.Dir.path.join(alloc, &.{ root, "kernel-home" });
    defer alloc.free(kernel_home);
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("HOME", root);
    try env.put("PROTO_FX_KERNEL_HOME", kernel_home);
    io_mod.setEnvironMap(&env);
    defer io_mod.resetEnvironForTest();
    const dir_a = try std.Io.Dir.path.join(alloc, &.{ root, "a" });
    defer alloc.free(dir_a);
    const dir_b = try std.Io.Dir.path.join(alloc, &.{ root, "b" });
    defer alloc.free(dir_b);
    const blobs = try std.Io.Dir.path.join(alloc, &.{ root, "blobs" });
    defer alloc.free(blobs);
    try std.Io.Dir.cwd().createDirPath(io_mod.getIo(), blobs);
    const a = try kernel.Manager.create(alloc, .{ .cwd = root, .artifact_dir = dir_a, .python = python, .blob_dir = blobs });
    defer a.destroy();
    const b = try kernel.Manager.create(alloc, .{ .cwd = root, .artifact_dir = dir_b, .python = python, .blob_dir = blobs });
    defer b.destroy();

    const Cell = struct {
        fn expect(target: *kernel.Manager, code: []const u8, expected: []const u8) !void {
            const result = try target.execute(std.testing.allocator, code, .{});
            defer result.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(expected, result.result);
        }
        /// The pid of the zygote that forked the kernel.
        fn parent(target: *kernel.Manager) !std.posix.pid_t {
            const result = try target.execute(std.testing.allocator, "import os\nos.getppid()", .{});
            defer result.deinit(std.testing.allocator);
            return std.fmt.parseInt(std.posix.pid_t, result.result, 10);
        }
    };
    try Cell.expect(a, "x = 41\nx", "41");
    try std.testing.expect(a.child.?.isForked());
    const old_zygote = try Cell.parent(a);
    try std.testing.expect(old_zygote != std.c.getpid());
    const first_pid = a.child.?.pid;

    // An interrupt reaches the cell through the protocol, not a signal.
    var cancel = std.atomic.Value(bool).init(false);
    const canceller = try std.Thread.spawn(.{}, struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(300 * std.time.ns_per_ms);
            flag.store(true, .release);
        }
    }.run, .{&cancel});
    const interrupted = try a.execute(alloc, "import time\ntime.sleep(30)", .{ .cancel = &cancel });
    canceller.join();
    defer interrupted.deinit(alloc);
    try std.testing.expectEqual(kernel.Status.aborted, interrupted.status);

    // kill -9 on the zygote leaves its kernel running, and the next start
    // replaces the zygote.
    try std.posix.kill(old_zygote, .KILL);
    io_mod.sleep(100 * std.time.ns_per_ms);
    try Cell.expect(a, "x + 1", "42");
    try Cell.expect(b, "y = 'b'\ny", "'b'");
    try std.testing.expect(b.child.?.isForked());
    try std.testing.expect(try Cell.parent(b) != old_zygote);

    // Stop and restart end the orphaned kernel by its verified pid; both
    // restore the saved globals on the next cell.
    a.stop(true);
    try std.testing.expectEqual(@as(?u64, null), memory.startToken(first_pid));
    try Cell.expect(a, "x", "41");
    const second_pid = a.child.?.pid;
    a.restart();
    try std.testing.expect(memory.startToken(second_pid) == null);
    try Cell.expect(a, "x", "41");
    b.stop(true);
    try Cell.expect(b, "y", "'b'");
}
