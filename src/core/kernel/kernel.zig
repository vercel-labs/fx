//! A session-owned CPython kernel. TUI attach/detach never changes its lifetime.
//! One pump drains both pipes, including between calls; command callers serialize on `gate`.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const protocol = @import("protocol.zig");
const bootstrap = @import("bootstrap.zig");
const Allocator = std.mem.Allocator;
const Buffer = protocol.Buffer;
const max_log_bytes = 5 * 1024 * 1024;
var boot_mutex: std.Io.Mutex = .init;
var boot_limit: usize = 0;
var boot_active: usize = 0;

pub const State = enum { idle, starting, running, stopping, failed, disposed };
pub const Status = enum { ok, failed, aborted };
pub const Stream = enum { stdout, stderr };
pub const StreamSink = struct {
    context: ?*anyopaque = null,
    /// Called on the pump thread. Must be short and must not reenter the manager.
    write: *const fn (?*anyopaque, Stream, []const u8) void,
};
pub const Options = struct {
    cwd: []const u8,
    artifact_dir: []const u8,
    persist: bool = true,
    python: ?[]const u8 = null,
    progress: ?bootstrap.Progress = null,
};
pub const ExecuteOptions = struct {
    cancel: ?*const std.atomic.Value(bool) = null,
    on_stream: ?StreamSink = null,
    max_output_chars: usize = 65_536,
    /// Advisory only. Completed work stays successful, avoiding duplicate side effects.
    timeout_ms: u64 = 60_000,
};
pub const Result = struct {
    status: Status,
    stdout: []u8,
    stderr: []u8,
    result: []u8,
    background_output: []u8,
    duration_ms: u64,

    pub fn deinit(self: Result, alloc: Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
        alloc.free(self.result);
        alloc.free(self.background_output);
    }

    /// Caller owns the formatted tool result.
    pub fn text(self: Result, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        const w = &out.writer;
        if (self.background_output.len > 0) try w.print("[background output]\n{s}\n", .{self.background_output});
        if (self.stdout.len > 0) try w.writeAll(self.stdout);
        if (self.stderr.len > 0) try w.print("\n[stderr]\n{s}", .{self.stderr});
        if (self.result.len > 0) try w.print("\n{s}", .{self.result});
        if (self.status == .aborted) try w.writeAll("\n[execution interrupted]");
        if (out.written().len == 0) try w.writeAll("(no output)");
        return out.toOwnedSlice();
    }
};

const Kind = enum { none, execute, snapshot, restore, shutdown };

pub const Manager = struct {
    alloc: Allocator,
    cwd: []u8,
    artifact_dir: []u8,
    persist: bool,
    python: ?[]u8,
    snapshot_path: []u8,
    manifest_path: []u8,
    progress: ?bootstrap.Progress,
    gate: std.Io.Mutex = .init,
    mutex: std.Io.Mutex = .init,
    writer: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),
    pump_stop: std.atomic.Value(bool) = .init(false),
    disposed: std.atomic.Value(bool) = .init(false),
    state: State = .idle,
    child: ?std.process.Child = null,
    pump_thread: ?std.Thread = null,
    prewarm_thread: ?std.Thread = null,
    repair_thread: ?std.Thread = null,
    repairing: std.atomic.Value(bool) = .init(false),
    warm_lock: std.Io.Mutex = .init,
    warming: std.atomic.Value(bool) = .init(false),
    generation: u64 = 0,
    sequence: u64 = 0,
    active: Kind = .none,
    active_id: u64 = 0,
    completed_id: u64 = 0,
    request_started: i64 = 0,
    request_status: Status = .ok,
    caller_waiting: bool = false,
    sink: ?StreamSink = null,
    cap: usize = 65_536,
    out: Buffer = .{},
    err: Buffer = .{},
    value: Buffer = .{},
    background: Buffer = .{},
    diagnostic: Buffer = .{},
    dirty: bool = false,
    snapshot_due: i64 = 0,
    restore_protected: bool = false,
    restore_warning: bool = false,
    skip_restore_once: bool = false,
    stderr_log: ?std.Io.File = null,
    stderr_log_bytes: usize = 0,

    /// `alloc` must be thread-safe. All options are copied; the session owns the returned manager.
    pub fn create(alloc: Allocator, options: Options) !*Manager {
        if (options.persist and !std.Io.Dir.path.isAbsolute(options.artifact_dir)) return error.KernelArtifactsMustBeAbsolute;
        const self = try alloc.create(Manager);
        errdefer alloc.destroy(self);
        const cwd = try alloc.dupe(u8, options.cwd);
        errdefer alloc.free(cwd);
        const dir = try alloc.dupe(u8, options.artifact_dir);
        errdefer alloc.free(dir);
        const python = if (options.python) |p| try alloc.dupe(u8, p) else null;
        errdefer if (python) |p| alloc.free(p);
        const snapshot = try std.Io.Dir.path.join(alloc, &.{ dir, "kernel-state.dill" });
        errdefer alloc.free(snapshot);
        const manifest = try std.Io.Dir.path.join(alloc, &.{ dir, "kernel-state.json" });
        self.* = .{ .alloc = alloc, .cwd = cwd, .artifact_dir = dir, .persist = options.persist, .python = python, .snapshot_path = snapshot, .manifest_path = manifest, .progress = options.progress };
        return self;
    }

    /// Only the owning session calls this, after tool callers have joined. Never call on TUI detach.
    pub fn destroy(self: *Manager) void {
        self.disposed.store(true, .release);
        self.stopping.store(true, .release);
        self.interrupt();
        self.warm_lock.lockUncancelable(io_mod.getIo());
        if (self.prewarm_thread) |thread| thread.join();
        self.warm_lock.unlock(io_mod.getIo());
        self.gate.lockUncancelable(io_mod.getIo());
        self.stopLocked(true);
        self.state = .disposed;
        self.gate.unlock(io_mod.getIo());
        // The stopped pump can no longer schedule repairs; a queued repair observes disposed.
        if (self.repair_thread) |thread| thread.join();
        self.out.deinit(self.alloc);
        self.err.deinit(self.alloc);
        self.value.deinit(self.alloc);
        self.background.deinit(self.alloc);
        self.diagnostic.deinit(self.alloc);
        self.alloc.free(self.cwd);
        self.alloc.free(self.artifact_dir);
        if (self.python) |p| self.alloc.free(p);
        self.alloc.free(self.snapshot_path);
        self.alloc.free(self.manifest_path);
        self.alloc.destroy(self);
    }

    /// Start in the background; concurrent callers join the same boot.
    pub fn prewarm(self: *Manager) !void {
        try self.launchWarm(false);
    }

    /// Resume hook: warm only when this session has a saved namespace. No filesystem work on the caller.
    pub fn prewarmIfSaved(self: *Manager) !void {
        if (self.persist) try self.launchWarm(true);
    }

    fn launchWarm(self: *Manager, snapshot_only: bool) !void {
        self.warm_lock.lockUncancelable(io_mod.getIo());
        defer self.warm_lock.unlock(io_mod.getIo());
        if (self.disposed.load(.acquire)) return error.KernelDisposed;
        if (self.warming.load(.acquire)) return;
        if (self.prewarm_thread) |thread| thread.join();
        self.prewarm_thread = null;
        self.warming.store(true, .release);
        errdefer self.warming.store(false, .release);
        self.prewarm_thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, warm, .{ self, snapshot_only });
    }

    fn warm(self: *Manager, snapshot_only: bool) void {
        defer self.warming.store(false, .release);
        if (snapshot_only) std.Io.Dir.cwd().access(io_mod.getIo(), self.snapshot_path, .{}) catch return;
        self.gate.lockUncancelable(io_mod.getIo());
        defer self.gate.unlock(io_mod.getIo());
        self.ensureLocked(null) catch {};
    }

    pub fn status(self: *Manager) State {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.state;
    }

    pub fn diagnostics(self: *Manager, alloc: Allocator) ![]u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.diagnostic.finish(alloc, 8192);
    }

    /// Serial calls share the same Python namespace. The result and all its strings belong to `alloc`.
    pub fn execute(self: *Manager, alloc: Allocator, code: []const u8, options: ExecuteOptions) !Result {
        const began = now();
        while (!self.gate.tryLock()) {
            if (cancelled(options.cancel) or self.disposed.load(.acquire)) return error.Cancelled;
            pause();
        }
        defer self.gate.unlock(io_mod.getIo());
        if (cancelled(options.cancel)) return error.Cancelled;
        try self.ensureLocked(options.cancel);
        if (self.stopping.load(.acquire) or self.disposed.load(.acquire)) return error.Cancelled;
        self.mutex.lockUncancelable(io_mod.getIo());
        self.caller_waiting = true;
        self.mutex.unlock(io_mod.getIo());
        defer {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.sink = null;
            self.caller_waiting = false;
            self.mutex.unlock(io_mod.getIo());
        }
        try self.waitIdle(options.cancel);
        if (cancelled(options.cancel)) return error.Cancelled;
        self.mutex.lockUncancelable(io_mod.getIo());
        self.out.clear();
        self.err.clear();
        self.value.clear();
        self.cap = @min(options.max_output_chars, 1024 * 1024);
        self.sink = options.on_stream;
        self.caller_waiting = true;
        self.request_status = .ok;
        if (self.restore_warning) {
            self.err.append(self.alloc, "[kernel] Some saved state could not be restored; the original snapshot is preserved.\n", self.cap) catch {};
            self.restore_warning = false;
        }
        self.mutex.unlock(io_mod.getIo());
        const id = try self.begin(.execute);
        const cell_began = now();
        self.send(.{ .type = "execute", .id = tryId(id), .code = code }, options.cancel, 30_000) catch |err| {
            self.fail("Kernel request could not be sent; replacing it on next use.");
            return err;
        };
        var abort_at: ?i64 = null;
        while (true) {
            self.mutex.lockUncancelable(io_mod.getIo());
            const done = self.completed_id == id;
            const failed = self.state == .failed;
            self.mutex.unlock(io_mod.getIo());
            if (done) break;
            if (failed) return error.KernelFailed;
            if (cancelled(options.cancel) or self.stopping.load(.acquire)) {
                if (abort_at == null) {
                    abort_at = now();
                    self.interrupt();
                }
                if (now() - abort_at.? >= 1000) break;
            }
            pause();
        }
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const outcome: Status = if (abort_at != null or cancelled(options.cancel)) .aborted else self.request_status;
        if (outcome == .ok and options.timeout_ms > 0 and now() - cell_began > options.timeout_ms) {
            var note: [256]u8 = undefined;
            const text = try std.mem.print(&note, "\n[watchdog] Cell exceeded its {d}ms budget (ran {d}ms). Split long Python work into smaller cells. Intentional long awaits can ignore this note.\n", .{ options.timeout_ms, now() - cell_began });
            try self.err.append(self.alloc, text, self.cap);
        }
        const out = try self.out.finish(alloc, self.cap);
        errdefer alloc.free(out);
        const err = try self.err.finish(alloc, self.cap);
        errdefer alloc.free(err);
        const value = try self.value.finish(alloc, self.cap);
        errdefer alloc.free(value);
        const background = try self.background.finish(alloc, 65_536);
        self.background.clear();
        return .{ .status = outcome, .stdout = out, .stderr = err, .result = value, .background_output = background, .duration_ms = @intCast(@max(0, now() - began)) };
    }

    /// Out-of-band and safe while execute is waiting. It never clears the active request early.
    pub fn interrupt(self: *Manager) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const id = self.active_id;
        const active = self.active != .none;
        self.mutex.unlock(io_mod.getIo());
        if (active) self.send(.{ .type = "interrupt", .id = tryId(id) }, null, 100) catch {};
    }

    /// Release the Python process while retaining the session. The next use restores saved globals.
    pub fn stop(self: *Manager, snapshot: bool) void {
        self.stopping.store(true, .release);
        self.interrupt();
        self.gate.lockUncancelable(io_mod.getIo());
        defer self.gate.unlock(io_mod.getIo());
        self.stopLocked(snapshot);
        self.stopping.store(false, .release);
    }

    /// Discard live resources without taking a final snapshot; next use restores the last valid save.
    pub fn restart(self: *Manager) void {
        self.stopping.store(true, .release);
        // An explicit restart must also break a cell that catches KeyboardInterrupt.
        // Signal the unreaped PID; only the pump/cleanup owns waiting and closing pipes.
        self.writer.lockUncancelable(io_mod.getIo());
        if (self.child) |child| if (child.id) |pid| {
            std.posix.kill(pid, .KILL) catch {};
        };
        self.writer.unlock(io_mod.getIo());
        self.gate.lockUncancelable(io_mod.getIo());
        defer self.gate.unlock(io_mod.getIo());
        self.stopLocked(false);
        self.stopping.store(false, .release);
    }

    fn ensureLocked(self: *Manager, cancel: ?*const std.atomic.Value(bool)) !void {
        if (self.disposed.load(.acquire)) return error.KernelDisposed;
        if (self.stopping.load(.acquire)) return error.Cancelled;
        if (self.status() == .running) return;
        if (self.child != null) self.stopLocked(false);
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            self.startLocked(cancel) catch |err| {
                self.stopLocked(false);
                if (attempt == 0 and err != error.Cancelled and err != error.KernelProtocolVersionMismatch and err != error.KernelPythonRequiresPython311AndDill and err != error.KernelSetupNeedsUv and err != error.KernelPythonProvisioningFailed and !self.stopping.load(.acquire) and !self.disposed.load(.acquire)) {
                    io_mod.sleep(250 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            return;
        }
    }

    fn startLocked(self: *Manager, cancel: ?*const std.atomic.Value(bool)) !void {
        if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.KernelPlatformUnsupported;
        self.mutex.lockUncancelable(io_mod.getIo());
        self.state = .starting;
        self.generation += 1;
        self.diagnostic.clear();
        self.mutex.unlock(io_mod.getIo());
        try acquireBootPermit(cancel, &self.stopping);
        var boot_permit = true;
        defer if (boot_permit) releaseBootPermit();
        const paths = bootstrap.ensure(self.alloc, self.python, self.progress, .{ .caller = cancel, .owner = &self.stopping }) catch |err| {
            self.fail(@errorName(err));
            return err;
        };
        defer paths.deinit(self.alloc);
        if (cancelled(cancel) or self.disposed.load(.acquire) or self.stopping.load(.acquire)) return error.Cancelled;
        const io = io_mod.getIo();
        // A dying interpreter must fail the write, not kill its supervisor.
        const ignore_pipe: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.PIPE, &ignore_pipe, null);
        if (self.persist) try std.Io.Dir.cwd().createDirPath(io, self.artifact_dir);
        var env = try io_mod.cloneEnvironMap(self.alloc);
        defer env.deinit();
        var owner: [32]u8 = undefined;
        try env.put("PROTO_FX_KERNEL_OWNER_PID", try std.mem.print(&owner, "{d}", .{std.c.getpid()}));
        try env.put("PYTHONUTF8", "1");
        const spawned = try std.process.spawn(io, .{
            .argv = &.{ paths.python, "-u", paths.runtime },
            .cwd = .{ .path = self.cwd },
            .environ_map = &env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = 0,
        });
        self.writer.lockUncancelable(io);
        self.child = spawned;
        self.writer.unlock(io);
        errdefer self.stopLocked(false);
        if (cancelled(cancel) or self.disposed.load(.acquire) or self.stopping.load(.acquire)) return error.Cancelled;
        for ([_]std.Io.File{ self.child.?.stdin.?, self.child.?.stdout.?, self.child.?.stderr.? }) |file| {
            const flags = std.posix.system.fcntl(file.handle, std.posix.F.GETFL);
            if (flags < 0 or std.posix.system.fcntl(file.handle, std.posix.F.SETFL, @as(usize, @intCast(flags)) | (@as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK"))) < 0) return error.KernelPipeSetupFailed;
        }
        if (self.persist) self.openLog();
        self.pump_stop.store(false, .release);
        self.pump_thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, pump, .{ self, self.child.?.stdout.?, self.child.?.stderr.? });
        const deadline = now() + 30_000;
        while (self.status() == .starting and now() < deadline) {
            if (cancelled(cancel) or self.disposed.load(.acquire) or self.stopping.load(.acquire)) return error.Cancelled;
            pause();
        }
        if (self.status() != .running) return error.KernelDidNotBecomeReady;
        // Only spawn/handshake contend globally. Slow restores must not starve other sessions.
        releaseBootPermit();
        boot_permit = false;
        if (!self.persist) return;
        if (self.skip_restore_once) {
            self.skip_restore_once = false;
            return;
        }
        // No bootstrap execute mutates the namespace: restore cannot be clobbered by a startup save.
        self.mutex.lockUncancelable(io_mod.getIo());
        self.caller_waiting = true;
        self.mutex.unlock(io_mod.getIo());
        defer {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.caller_waiting = false;
            self.mutex.unlock(io_mod.getIo());
        }
        const id = try self.begin(.restore);
        try self.send(.{ .type = "restore", .id = tryId(id), .path = self.snapshot_path, .max_bytes = @as(u64, 256 * 1024 * 1024), .max_variable_bytes = @as(u64, 16 * 1024 * 1024) }, null, 1000);
        self.waitDone(id, 30_000) catch {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.restore_protected = true;
            self.restore_warning = true;
            self.skip_restore_once = true;
            self.mutex.unlock(io_mod.getIo());
            return error.KernelRestoreFailed;
        };
    }

    fn waitIdle(self: *Manager, cancel: ?*const std.atomic.Value(bool)) !void {
        const deadline = now() + 5000;
        var last_interrupt: i64 = 0;
        while (true) {
            self.mutex.lockUncancelable(io_mod.getIo());
            const active = self.active;
            const failed = self.state == .failed;
            self.mutex.unlock(io_mod.getIo());
            if (failed) return error.KernelFailed;
            if (active == .none) return;
            if (cancelled(cancel)) return error.Cancelled;
            if (now() >= deadline) return error.KernelStillBusyAfterInterrupt;
            if (active == .execute and now() - last_interrupt >= 500) {
                self.interrupt();
                last_interrupt = now();
            }
            pause();
        }
    }

    fn waitDone(self: *Manager, id: u64, timeout: i64) !void {
        const deadline = now() + timeout;
        while (now() < deadline) {
            self.mutex.lockUncancelable(io_mod.getIo());
            const done = self.completed_id == id;
            const failed = self.state == .failed;
            self.mutex.unlock(io_mod.getIo());
            if (done) return;
            if (failed) return error.KernelFailed;
            pause();
        }
        self.interrupt();
        return error.KernelRequestTimedOut;
    }

    fn begin(self: *Manager, kind: Kind) !u64 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.active != .none) return error.KernelStillBusyAfterInterrupt;
        self.sequence += 1;
        self.active_id = self.sequence;
        self.active = kind;
        self.request_status = .ok;
        self.request_started = now();
        return self.sequence;
    }

    fn send(self: *Manager, value: anytype, cancel: ?*const std.atomic.Value(bool), timeout: i64) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var json: std.Io.Writer.Allocating = .init(arena.allocator());
        try std.json.Stringify.value(value, .{}, &json.writer);
        try json.writer.writeByte('\n');
        const bytes = json.written();
        if (bytes.len > protocol.max_frame_bytes) return error.KernelRequestTooLarge;
        const deadline = now() + timeout;
        while (!self.writer.tryLock()) {
            if (cancelled(cancel) or now() >= deadline) return error.Cancelled;
            pause();
        }
        defer self.writer.unlock(io_mod.getIo());
        const child = self.child orelse return error.KernelNotRunning;
        const stdin = child.stdin orelse return error.KernelNotRunning;
        var written: usize = 0;
        while (written < bytes.len) {
            if (cancelled(cancel) or now() >= deadline) {
                // Never continue using a stream that contains half a request.
                if (written > 0) self.fail("Kernel request interrupted during write.");
                return error.Cancelled;
            }
            const rc = std.c.write(stdin.handle, bytes[written..].ptr, bytes.len - written);
            if (rc > 0) {
                written += @intCast(rc);
                continue;
            }
            switch (std.posix.errno(rc)) {
                .INTR => continue,
                .AGAIN => {
                    var fds = [_]std.posix.pollfd{.{ .fd = stdin.handle, .events = std.posix.POLL.OUT, .revents = 0 }};
                    _ = try std.posix.poll(&fds, 20);
                },
                else => return error.KernelPipeClosed,
            }
        }
    }

    fn stopLocked(self: *Manager, snapshot: bool) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.caller_waiting = true;
        const healthy = self.state == .running;
        self.state = .stopping;
        self.mutex.unlock(io_mod.getIo());
        if (healthy and snapshot) {
            self.interrupt();
            self.waitIdle(null) catch {};
            self.mutex.lockUncancelable(io_mod.getIo());
            const can_save = self.persist and snapshot and self.active == .none and !self.restore_protected;
            self.mutex.unlock(io_mod.getIo());
            if (can_save) {
                if (self.begin(.snapshot)) |id| {
                    self.sendSnapshot(id) catch {};
                    self.waitDone(id, 5000) catch {};
                } else |_| {}
            }
            if (self.begin(.shutdown)) |id| {
                self.send(.{ .type = "shutdown", .id = tryId(id) }, null, 1000) catch {};
                self.waitDone(id, 5000) catch {};
            } else |_| {}
        }
        self.pump_stop.store(true, .release);
        // Signal before join so an EOF wakes the pump even while the child was blocked.
        self.writer.lockUncancelable(io_mod.getIo());
        if (self.child) |child| if (child.id) |pid| {
            std.posix.kill(pid, .TERM) catch {};
        };
        self.writer.unlock(io_mod.getIo());
        if (self.pump_thread) |thread| thread.join();
        self.pump_thread = null;
        self.writer.lockUncancelable(io_mod.getIo());
        if (self.child) |*child| child.kill(io_mod.getIo());
        self.child = null;
        self.writer.unlock(io_mod.getIo());
        if (self.stderr_log) |file| file.close(io_mod.getIo());
        self.stderr_log = null;
        self.mutex.lockUncancelable(io_mod.getIo());
        self.state = .idle;
        self.active = .none;
        self.caller_waiting = false;
        self.sink = null;
        self.background.clear();
        self.dirty = false;
        self.snapshot_due = 0;
        self.mutex.unlock(io_mod.getIo());
    }

    fn sendSnapshot(self: *Manager, id: u64) !void {
        try self.send(.{ .type = "snapshot", .id = tryId(id), .path = self.snapshot_path, .manifest_path = self.manifest_path, .max_bytes = @as(u64, 256 * 1024 * 1024), .max_variable_bytes = @as(u64, 16 * 1024 * 1024), .prune_oversized = false }, null, 1000);
    }

    fn pump(self: *Manager, stdout: std.Io.File, stderr: std.Io.File) void {
        var repair_after_exit = false;
        defer if (repair_after_exit) self.scheduleRepair();
        defer {
            // Reap on EOF or corruption, not only on the next tool call. The writer lock
            // makes closing pipes and signaling the unreaped PID safe against interrupts.
            self.writer.lockUncancelable(io_mod.getIo());
            if (self.child) |*child| child.kill(io_mod.getIo());
            self.writer.unlock(io_mod.getIo());
        }
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(self.alloc);
        var buffer: [64 * 1024]u8 = undefined;
        var stderr_open = true;
        while (!self.pump_stop.load(.acquire)) {
            self.mutex.lockUncancelable(io_mod.getIo());
            const wake_at = if (self.active == .snapshot and !self.caller_waiting)
                self.request_started + 5000
            else if (self.dirty and self.active == .none and !self.caller_waiting and !self.restore_protected)
                self.snapshot_due
            else
                std.math.maxInt(i64);
            self.mutex.unlock(io_mod.getIo());
            const poll_timeout: i32 = @intCast(@min(1000, @max(0, wake_at - now())));
            var fds = [_]std.posix.pollfd{
                .{ .fd = stdout.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = if (stderr_open) stderr.handle else -1, .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = std.posix.poll(&fds, poll_timeout) catch {
                self.fail("Kernel pipe polling failed.");
                return;
            };
            // Drain diagnostics first: an early interpreter exit can make stdout EOF and
            // its explanatory stderr readable in the same poll.
            for ([_]usize{ 1, 0 }) |index| {
                const fd = &fds[index];
                if (fd.revents == 0) continue;
                const rc = std.c.read(fd.fd, &buffer, buffer.len);
                if (rc == 0) {
                    if (index == 1) {
                        stderr_open = false;
                        continue;
                    }
                    if (!self.pump_stop.load(.acquire)) self.fail("Python kernel exited; the next call will start a replacement.");
                    return;
                }
                if (rc < 0) continue;
                const bytes = buffer[0..@intCast(rc)];
                if (index == 1) {
                    self.log(bytes);
                    continue;
                }
                pending.appendSlice(self.alloc, bytes) catch {
                    self.fail("Kernel output allocation failed.");
                    return;
                };
                var consumed: usize = 0;
                while (std.mem.findScalarPos(u8, pending.items, consumed, '\n')) |newline| {
                    if (newline - consumed > protocol.max_frame_bytes) {
                        repair_after_exit = self.status() == .running;
                        self.fail("Kernel protocol frame exceeded 32 MiB.");
                        return;
                    }
                    self.handleEvent(pending.items[consumed..newline]) catch {
                        repair_after_exit = self.status() == .running;
                        self.fail("Invalid kernel protocol frame; restoring a replacement in the background.");
                        return;
                    };
                    consumed = newline + 1;
                }
                if (consumed > 0) {
                    @memmove(pending.items[0 .. pending.items.len - consumed], pending.items[consumed..]);
                    pending.items.len -= consumed;
                }
                if (pending.items.len > protocol.max_frame_bytes) {
                    repair_after_exit = self.status() == .running;
                    self.fail("Kernel protocol frame exceeded 32 MiB.");
                    return;
                }
                if (pending.items.len == 0 and pending.capacity > 256 * 1024) {
                    pending.deinit(self.alloc);
                    pending = .empty;
                }
            }
            self.mutex.lockUncancelable(io_mod.getIo());
            const should_save = self.persist and self.state == .running and self.active == .none and !self.caller_waiting and self.dirty and !self.restore_protected and now() >= self.snapshot_due and !self.stopping.load(.acquire);
            const snapshot_hung = self.active == .snapshot and !self.caller_waiting and now() - self.request_started > 5000;
            // Reserve the slot while holding the state lock, so a foreground execute cannot race it.
            var save_id: u64 = 0;
            if (should_save) {
                self.sequence += 1;
                save_id = self.sequence;
                self.active_id = save_id;
                self.active = .snapshot;
                self.request_started = now();
            }
            self.mutex.unlock(io_mod.getIo());
            if (snapshot_hung) {
                self.fail("Kernel snapshot timed out; preserving the previous save.");
                return;
            }
            if (save_id != 0) self.sendSnapshot(save_id) catch {
                self.fail("Could not save the Python namespace.");
                return;
            };
        }
    }

    /// Only the pump schedules a repair, after it has reaped the damaged child. A replacement
    /// corrupting during its own startup is discarded, not put into an automatic respawn loop.
    fn scheduleRepair(self: *Manager) void {
        if (self.disposed.load(.acquire) or self.stopping.load(.acquire)) return;
        if (self.repairing.swap(true, .acq_rel)) return;
        if (self.repair_thread) |thread| thread.join();
        self.repair_thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, repair, .{ self, self.generation }) catch {
            self.repairing.store(false, .release);
            return;
        };
    }

    fn repair(self: *Manager, generation: u64) void {
        defer self.repairing.store(false, .release);
        while (!self.gate.tryLock()) {
            if (self.disposed.load(.acquire) or self.stopping.load(.acquire)) return;
            pause();
        }
        defer self.gate.unlock(io_mod.getIo());
        if (self.disposed.load(.acquire) or self.stopping.load(.acquire) or self.generation != generation or self.status() != .failed) return;
        self.stopLocked(false);
        self.startLocked(null) catch {
            self.stopLocked(false);
        };
    }

    fn handleEvent(self: *Manager, line: []const u8) !void {
        if (std.mem.trim(u8, line, " \r\t").len == 0) return;
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const event = try std.json.parseFromSliceLeaky(protocol.Event, arena.allocator(), line, .{ .ignore_unknown_fields = true });
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (std.mem.eql(u8, event.event, "ready")) {
            if (event.protocol != protocol.version) return error.KernelProtocolVersionMismatch;
            if (self.state != .starting) return error.DuplicateKernelReady;
            self.state = .running;
            return;
        }
        const id = if (event.id) |text| std.fmt.parseInt(u64, text, 10) catch 0 else 0;
        const matches = id != 0 and id == self.active_id and self.active != .none;
        if (std.mem.eql(u8, event.event, "stdout") or std.mem.eql(u8, event.event, "stderr")) {
            if (matches and self.active == .execute) {
                const stream: Stream = if (std.mem.eql(u8, event.event, "stdout")) .stdout else .stderr;
                const destination = if (stream == .stdout) &self.out else &self.err;
                try destination.append(self.alloc, event.text, self.cap);
                if (self.sink) |sink| sink.write(sink.context, stream, event.text);
            } else try self.background.append(self.alloc, event.text, 65_536);
        } else if (std.mem.eql(u8, event.event, "result")) {
            if (id == 0) return error.InvalidKernelFrame;
            if (matches and self.active == .execute) try self.value.append(self.alloc, event.text, self.cap);
        } else if (std.mem.eql(u8, event.event, "error")) {
            if (matches) {
                self.request_status = .failed;
                for (event.traceback) |entry| try self.err.append(self.alloc, entry, self.cap);
                if (event.traceback.len == 0) {
                    try self.err.append(self.alloc, event.ename, self.cap);
                    try self.err.append(self.alloc, ": ", self.cap);
                    try self.err.append(self.alloc, event.evalue, self.cap);
                }
            } else try self.diagnostic.append(self.alloc, event.evalue, 8192);
        } else if (std.mem.eql(u8, event.event, "done")) {
            if (id == 0) return error.InvalidKernelFrame;
            if (!matches) return;
            if (!std.mem.eql(u8, event.status, "ok")) self.request_status = .failed;
            if (self.active == .restore) {
                self.restore_protected = self.request_status != .ok or event.failed.len > 0;
                self.restore_warning = self.restore_protected;
            }
            if (self.active == .execute and self.request_status == .ok) {
                self.dirty = true;
                self.snapshot_due = now() + 1500;
            }
            if (self.active == .snapshot) {
                // Failed snapshots are not tight-loop retried; a later cell can schedule one.
                self.dirty = self.request_status != .ok;
                self.snapshot_due = std.math.maxInt(i64);
                if (self.request_status != .ok) try self.diagnostic.append(self.alloc, event.reason orelse "Snapshot failed", 8192);
            }
            self.completed_id = id;
            self.active = .none;
        } else if (std.mem.eql(u8, event.event, "display")) {
            // Generic displays are intentionally not a Phase 1 tool surface.
        } else return error.InvalidKernelFrame;
    }

    fn fail(self: *Manager, reason: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.state = .failed;
        self.diagnostic.append(self.alloc, reason, 8192) catch {};
        self.mutex.unlock(io_mod.getIo());
    }

    fn openLog(self: *Manager) void {
        self.openLogChecked() catch {
            self.mutex.lockUncancelable(io_mod.getIo());
            self.diagnostic.append(self.alloc, "Cannot open or rotate kernel stderr log.\n", 8192) catch {};
            self.mutex.unlock(io_mod.getIo());
        };
    }

    fn openLogChecked(self: *Manager) !void {
        const io = io_mod.getIo();
        var dir = try std.Io.Dir.openDirAbsolute(io, self.artifact_dir, .{});
        defer dir.close(io);
        try dir.setPermissions(io, .fromMode(0o700));
        var file = try dir.createFile(io, "kernel-stderr.log", .{ .truncate = false, .permissions = .fromMode(0o600) });
        errdefer file.close(io);
        try file.setPermissions(io, .fromMode(0o600));
        var size = (try file.stat(io)).size;
        if (size >= max_log_bytes) {
            // Rename atomically over the previous generation; never truncate a log on boot.
            try dir.rename("kernel-stderr.log", dir, "kernel-stderr.log.old", io);
            const replacement = try dir.createFile(io, "kernel-stderr.log", .{ .permissions = .fromMode(0o600) });
            file.close(io);
            file = replacement;
            size = 0;
        }
        self.stderr_log = file;
        self.stderr_log_bytes = @intCast(size);
    }

    fn log(self: *Manager, bytes: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.diagnostic.append(self.alloc, bytes, 8192) catch {};
        self.mutex.unlock(io_mod.getIo());
        if (self.stderr_log) |file| {
            const keep = @min(bytes.len, max_log_bytes -| self.stderr_log_bytes);
            file.writePositionalAll(io_mod.getIo(), bytes[0..keep], self.stderr_log_bytes) catch {};
            self.stderr_log_bytes += keep;
            if (keep > 0 and keep < bytes.len) {
                const marker = "\n[kernel stderr log reached its 5 MiB budget; further output is omitted]\n";
                file.writePositionalAll(io_mod.getIo(), marker, self.stderr_log_bytes) catch {};
                self.stderr_log_bytes += marker.len;
            }
        }
    }
};

fn acquireBootPermit(cancel: ?*const std.atomic.Value(bool), owner: *const std.atomic.Value(bool)) !void {
    while (true) {
        if (cancelled(cancel) or owner.load(.acquire)) return error.Cancelled;
        boot_mutex.lockUncancelable(io_mod.getIo());
        if (boot_limit == 0) {
            const cores = std.Thread.getCpuCount() catch 4;
            const default = @min(16, @max(4, cores *| 2));
            boot_limit = configuredBootLimit(io_mod.getenv("PROTO_FX_MAX_CONCURRENT_KERNEL_BOOTS"), default);
        }
        const available = boot_active < boot_limit;
        if (available) boot_active += 1;
        boot_mutex.unlock(io_mod.getIo());
        if (available) return;
        pause();
    }
}

fn releaseBootPermit() void {
    boot_mutex.lockUncancelable(io_mod.getIo());
    defer boot_mutex.unlock(io_mod.getIo());
    std.debug.assert(boot_active > 0);
    boot_active -= 1;
}

fn configuredBootLimit(raw: ?[]const u8, default: usize) usize {
    const text = raw orelse return default;
    if (text.len == 0) return default;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return default;
    const parsed = std.fmt.parseInt(usize, text, 10) catch return default;
    return if (parsed == 0) default else @min(64, parsed);
}

test "kernel boot admission rejects invalid limits and caps overrides" {
    try std.testing.expectEqual(@as(usize, 8), configuredBootLimit(null, 8));
    try std.testing.expectEqual(@as(usize, 8), configuredBootLimit("0", 8));
    try std.testing.expectEqual(@as(usize, 8), configuredBootLimit("-1", 8));
    try std.testing.expectEqual(@as(usize, 1), configuredBootLimit("1", 8));
    try std.testing.expectEqual(@as(usize, 64), configuredBootLimit("999", 8));
}

fn now() i64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io_mod.getIo(), .awake).nanoseconds, std.time.ns_per_ms));
}
fn pause() void {
    io_mod.sleep(5 * std.time.ns_per_ms);
}
fn cancelled(flag: ?*const std.atomic.Value(bool)) bool {
    return if (flag) |value| value.load(.acquire) else false;
}
// A decimal ID is serialized as a string by std.json, without request-lifetime allocations.
fn tryId(id: u64) Id {
    return .{ .value = id };
}
const Id = struct {
    value: u64,
    pub fn jsonStringify(self: Id, jw: anytype) std.Io.Writer.Error!void {
        var buf: [24]u8 = undefined;
        try jw.write(std.mem.print(&buf, "{d}", .{self.value}) catch unreachable);
    }
};

test {
    _ = protocol;
}
