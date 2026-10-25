//! A session-owned CPython kernel. TUI attach/detach never changes its lifetime.
//! One reader thread (`reader.zig`) drains both pipes, including between calls; command callers serialize on the gate.
//! Waiters sleep on `Manager.changed`, which the reader and every state change broadcast.
const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const protocol = @import("protocol.zig");
const bootstrap = @import("bootstrap.zig");
const reader = @import("reader.zig");
const pool = @import("pool.zig");
const Allocator = std.mem.Allocator;
const Buffer = protocol.Buffer;
const Cancel = ?*const std.atomic.Value(bool);
const now = io_mod.monotonicMilliTimestamp;
pub const diagnostic_cap = 8192;
pub const background_cap = 65_536;
/// Longest a waiter sleeps before rechecking cancel flags, which nothing signals.
const poll_slice_ms = 50;
var boot_mutex: std.Io.Mutex = .init;
var boot_changed: std.Io.Condition = .init;
var boot_limit: usize = 0;
var boot_active: usize = 0;

pub const State = enum { idle, starting, running, stopping, failed, disposed };
pub const Status = enum { ok, failed, aborted };
pub const Stream = enum { stdout, stderr };
pub const StreamSink = struct {
    context: ?*anyopaque = null,
    /// Called on the reader thread. Must be short and must not reenter the manager.
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

/// The request occupying the kernel's single request slot.
const Request = enum { none, execute, snapshot, restore, shutdown };
/// Whether saved globals may be overwritten. A failed or partial restore protects the
/// original snapshot until a later restore succeeds; the next cell reports it once.
const SaveGuard = enum { open, protected_unreported, protected };
/// What the next start does with the saved snapshot. A restore that hung is skipped
/// once, so the replacement starts with an empty namespace instead of hanging again.
const NextRestore = enum { restore, skip };

pub const Manager = struct {
    alloc: Allocator,
    cwd: []u8,
    artifact_dir: []u8,
    persist: bool,
    python: ?[]u8,
    snapshot_path: []u8,
    progress: ?bootstrap.Progress,
    /// Guards the request and lifecycle fields below; the atomics need no lock.
    mutex: std.Io.Mutex = .init,
    /// Broadcast on every request completion, state change and gate release.
    changed: std.Io.Condition = .init,
    /// Serializes command callers (execute, start, stop, repair). Read and written under `mutex`.
    gate_held: bool = false,
    writer: std.Io.Mutex = .init,
    stopping: std.atomic.Value(bool) = .init(false),
    reader_stop: std.atomic.Value(bool) = .init(false),
    disposed: std.atomic.Value(bool) = .init(false),
    state: State = .idle,
    child: ?std.process.Child = null,
    reader_thread: ?std.Thread = null,
    prewarm_thread: ?std.Thread = null,
    repair_thread: ?std.Thread = null,
    repairing: std.atomic.Value(bool) = .init(false),
    warm_lock: std.Io.Mutex = .init,
    warming: std.atomic.Value(bool) = .init(false),
    generation: u64 = 0,
    sequence: u64 = 0,
    active: Request = .none,
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
    /// When the reader takes a debounced background snapshot; null when nothing is pending.
    save_due: ?i64 = null,
    save_guard: SaveGuard = .open,
    next_restore: NextRestore = .restore,
    stderr_log: ?std.Io.File = null,
    stderr_log_bytes: usize = 0,
    /// Owned by `pool.zig` and guarded by its mutex.
    pool: pool.Membership = .{},

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
        self.* = .{ .alloc = alloc, .cwd = cwd, .artifact_dir = dir, .persist = options.persist, .python = python, .snapshot_path = snapshot, .progress = options.progress };
        return self;
    }

    /// Only the owning session calls this, after tool callers have joined. Never call on TUI detach.
    pub fn destroy(self: *Manager) void {
        pool.forget(self);
        self.disposed.store(true, .release);
        self.stopping.store(true, .release);
        self.interrupt();
        self.warm_lock.lockUncancelable(io_mod.getIo());
        if (self.prewarm_thread) |thread| thread.join();
        self.warm_lock.unlock(io_mod.getIo());
        self.lockGateUncancelable();
        self.stopLocked(true);
        self.mutex.lockUncancelable(io_mod.getIo());
        self.state = .disposed;
        self.mutex.unlock(io_mod.getIo());
        self.unlockGate();
        // The stopped reader can no longer schedule repairs; a queued repair observes disposed.
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
        self.lockGateUncancelable();
        defer self.unlockGate();
        self.ensureLocked(null) catch {};
    }

    pub fn status(self: *Manager) State {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.state;
    }

    /// A cell is running in the kernel now.
    pub fn executing(self: *Manager) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.active == .execute;
    }

    pub fn diagnostics(self: *Manager, alloc: Allocator) ![]u8 {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.diagnostic.finish(alloc, diagnostic_cap);
    }

    /// Serial calls share the same Python namespace. The result and all its strings belong to `alloc`.
    pub fn execute(self: *Manager, alloc: Allocator, code: []const u8, options: ExecuteOptions) !Result {
        const io = io_mod.getIo();
        const began = now();
        try self.lockGate(options.cancel);
        defer self.unlockGate();
        if (cancelled(options.cancel)) return error.Cancelled;
        try self.ensureLocked(options.cancel);
        if (self.stopping.load(.acquire) or self.disposed.load(.acquire)) return error.Cancelled;
        self.mutex.lockUncancelable(io);
        self.caller_waiting = true;
        self.mutex.unlock(io);
        pool.touch(self);
        // Marks the end of the cell; a start waiting on the pool rechecks once the gate opens.
        defer pool.touch(self);
        defer {
            self.mutex.lockUncancelable(io);
            self.sink = null;
            self.caller_waiting = false;
            self.mutex.unlock(io);
        }
        try self.waitIdle(options.cancel);
        if (cancelled(options.cancel)) return error.Cancelled;
        self.mutex.lockUncancelable(io);
        self.out.clear();
        self.err.clear();
        self.value.clear();
        self.cap = @min(options.max_output_chars, 1024 * 1024);
        self.sink = options.on_stream;
        self.request_status = .ok;
        if (self.save_guard == .protected_unreported) {
            self.err.append(self.alloc, "[kernel] Some saved state could not be restored; the original snapshot is preserved.\n", self.cap) catch {};
            self.save_guard = .protected;
        }
        self.mutex.unlock(io);
        const id = try self.begin(.execute);
        const cell_began = now();
        self.send(.{ .execute = .{ .id = id, .code = code } }, options.cancel, 30_000) catch |err| {
            self.fail("Kernel request could not be sent; replacing it on next use.");
            return err;
        };
        const aborted = try self.awaitCell(id, options.cancel);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const outcome: Status = if (aborted or cancelled(options.cancel)) .aborted else self.request_status;
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
        const background = try self.background.finish(alloc, background_cap);
        self.background.clear();
        return .{ .status = outcome, .stdout = out, .stderr = err, .result = value, .background_output = background, .duration_ms = @intCast(@max(0, now() - began)) };
    }

    /// Waits for the cell's done event and reports whether it was aborted. Cancellation or
    /// stop interrupts the cell and gives Python one second to finish handling it.
    fn awaitCell(self: *Manager, id: u64, cancel: Cancel) !bool {
        const io = io_mod.getIo();
        var abort_at: ?i64 = null;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.completed_id != id) {
            if (self.state == .failed) return error.KernelFailed;
            if (abort_at) |at| {
                const left = at + 1000 - now();
                if (left <= 0) break;
                self.waitChange(left);
            } else if (cancelled(cancel) or self.stopping.load(.acquire)) {
                abort_at = now();
                self.mutex.unlock(io);
                self.interrupt();
                self.mutex.lockUncancelable(io);
            } else self.waitChange(poll_slice_ms);
        }
        return abort_at != null;
    }

    /// Out-of-band and safe while execute is waiting. It never clears the active request early.
    pub fn interrupt(self: *Manager) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        const id = self.active_id;
        const active = self.active != .none;
        self.mutex.unlock(io_mod.getIo());
        if (active) self.send(.{ .interrupt = id }, null, 100) catch {};
    }

    /// Release the Python process while retaining the session. The next use restores saved globals.
    pub fn stop(self: *Manager, snapshot: bool) void {
        self.stopping.store(true, .release);
        self.interrupt();
        self.lockGateUncancelable();
        defer self.unlockGate();
        self.stopLocked(snapshot);
        self.stopping.store(false, .release);
    }

    /// Discard live resources without taking a final snapshot; next use restores the last valid save.
    pub fn restart(self: *Manager) void {
        self.stopping.store(true, .release);
        // An explicit restart must also break a cell that catches KeyboardInterrupt.
        // Signal the unreaped PID; only the reader/cleanup owns waiting and closing pipes.
        self.writer.lockUncancelable(io_mod.getIo());
        if (self.child) |child| if (child.id) |pid| {
            std.posix.kill(pid, .KILL) catch {};
        };
        self.writer.unlock(io_mod.getIo());
        self.lockGateUncancelable();
        defer self.unlockGate();
        self.stopLocked(false);
        self.stopping.store(false, .release);
    }

    /// Whether the pool may park this kernel now: no command holds it, no request
    /// is in flight, and either a stop loses nothing a snapshot cannot restore or
    /// the process is already dead. The pool calls this under its own mutex.
    pub fn parkable(self: *Manager) bool {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.parkableLocked();
    }

    fn parkableLocked(self: *Manager) bool {
        if (self.gate_held or self.disposed.load(.acquire) or self.stopping.load(.acquire)) return false;
        if (self.state == .failed) return true;
        return self.state == .running and self.active == .none and self.persist and self.save_guard == .open;
    }

    /// Snapshots and stops an idle kernel so its process memory is released; the
    /// next cell restores it. It never waits for a running cell: when another
    /// command holds the kernel, or the snapshot fails, it leaves the kernel
    /// running and reports false.
    pub fn park(self: *Manager) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        if (!self.parkableLocked()) {
            self.mutex.unlock(io);
            return false;
        }
        self.gate_held = true;
        // Claims the snapshot, so the reader does not time it out as a background save.
        self.caller_waiting = true;
        const dead = self.state == .failed;
        self.mutex.unlock(io);
        defer self.unlockGate();
        if (!dead and !self.saveNow()) {
            self.mutex.lockUncancelable(io);
            self.caller_waiting = false;
            self.mutex.unlock(io);
            return false;
        }
        self.stopLocked(false);
        return true;
    }

    fn saveNow(self: *Manager) bool {
        const id = self.begin(.snapshot) catch return false;
        self.sendSnapshot(id) catch return false;
        self.waitDone(id, 5000) catch return false;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        return self.request_status == .ok;
    }

    fn ensureLocked(self: *Manager, cancel: Cancel) !void {
        if (self.disposed.load(.acquire)) return error.KernelDisposed;
        if (self.stopping.load(.acquire)) return error.Cancelled;
        if (self.status() == .running) return;
        if (self.child != null) self.stopLocked(false);
        self.startLocked(cancel) catch |first| {
            self.stopLocked(false);
            if (isPermanent(first) or self.stopping.load(.acquire) or self.disposed.load(.acquire)) return first;
            // A transient failure gets one retry; after a hung restore it starts empty (see `NextRestore`).
            io_mod.sleep(250 * std.time.ns_per_ms);
            self.startLocked(cancel) catch |second| {
                self.stopLocked(false);
                return second;
            };
        };
    }

    fn startLocked(self: *Manager, cancel: Cancel) !void {
        if (comptime builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.KernelPlatformUnsupported;
        self.mutex.lockUncancelable(io_mod.getIo());
        self.state = .starting;
        self.generation += 1;
        self.diagnostic.clear();
        self.mutex.unlock(io_mod.getIo());
        try pool.admit(self, cancel, &self.stopping);
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
        if (self.persist) reader.openLog(self);
        self.reader_stop.store(false, .release);
        self.reader_thread = try std.Thread.spawn(.{ .stack_size = 512 * 1024 }, reader.run, .{ self, self.child.?.stdout.?, self.child.?.stderr.? });
        const deadline = now() + 30_000;
        self.mutex.lockUncancelable(io);
        while (self.state == .starting) {
            if (cancelled(cancel) or self.disposed.load(.acquire) or self.stopping.load(.acquire)) {
                self.mutex.unlock(io);
                return error.Cancelled;
            }
            const left = deadline - now();
            if (left <= 0) break;
            self.waitChange(left);
        }
        const ready = self.state == .running;
        self.mutex.unlock(io);
        if (!ready) return error.KernelDidNotBecomeReady;
        // Only spawn/handshake contend globally. Slow restores must not starve other sessions.
        releaseBootPermit();
        boot_permit = false;
        if (!self.persist) return;
        // No bootstrap execute mutates the namespace: restore cannot be clobbered by a startup save.
        self.mutex.lockUncancelable(io);
        const skip = self.next_restore == .skip;
        self.next_restore = .restore;
        if (!skip) self.caller_waiting = true;
        self.mutex.unlock(io);
        if (skip) return;
        defer {
            self.mutex.lockUncancelable(io);
            self.caller_waiting = false;
            self.mutex.unlock(io);
        }
        const id = try self.begin(.restore);
        try self.send(.{ .restore = .{ .id = id, .path = self.snapshot_path } }, null, 1000);
        self.waitDone(id, 30_000) catch {
            self.mutex.lockUncancelable(io);
            self.save_guard = .protected_unreported;
            self.next_restore = .skip;
            self.mutex.unlock(io);
            return error.KernelRestoreFailed;
        };
    }

    /// Waits for the request slot to empty, interrupting a lingering cell every 500 ms.
    fn waitIdle(self: *Manager, cancel: Cancel) !void {
        const io = io_mod.getIo();
        const deadline = now() + 5000;
        var last_interrupt: i64 = 0;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (true) {
            if (self.state == .failed) return error.KernelFailed;
            if (self.active == .none) return;
            if (cancelled(cancel)) return error.Cancelled;
            const at = now();
            if (at >= deadline) return error.KernelStillBusyAfterInterrupt;
            if (self.active != .execute) {
                self.waitChange(deadline - at);
            } else if (at - last_interrupt >= 500) {
                self.mutex.unlock(io);
                self.interrupt();
                self.mutex.lockUncancelable(io);
                last_interrupt = now();
            } else self.waitChange(@min(deadline, last_interrupt + 500) - at);
        }
    }

    fn waitDone(self: *Manager, id: u64, timeout: i64) !void {
        const io = io_mod.getIo();
        const deadline = now() + timeout;
        self.mutex.lockUncancelable(io);
        while (self.completed_id != id) {
            if (self.state == .failed) {
                self.mutex.unlock(io);
                return error.KernelFailed;
            }
            const left = deadline - now();
            if (left <= 0) {
                self.mutex.unlock(io);
                self.interrupt();
                return error.KernelRequestTimedOut;
            }
            self.waitChange(left);
        }
        self.mutex.unlock(io);
    }

    /// Caller holds `mutex`. Returns after a broadcast or at most `max_ms`, so callers
    /// recheck their predicate and any unsignalled cancel flag.
    fn waitChange(self: *Manager, max_ms: i64) void {
        const ms = std.math.clamp(max_ms, 1, poll_slice_ms);
        self.changed.waitTimeout(io_mod.getIo(), &self.mutex, .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }) catch {};
    }

    pub fn notify(self: *Manager) void {
        self.changed.broadcast(io_mod.getIo());
    }

    /// Waits for the command gate. A set `abort` flag or disposal ends the wait with error.Cancelled.
    fn lockGate(self: *Manager, abort: Cancel) !void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.gate_held) {
            if (cancelled(abort) or self.disposed.load(.acquire)) return error.Cancelled;
            self.waitChange(poll_slice_ms);
        }
        self.gate_held = true;
    }

    fn lockGateUncancelable(self: *Manager) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.gate_held) self.changed.waitUncancelable(io, &self.mutex);
        self.gate_held = true;
    }

    fn unlockGate(self: *Manager) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        self.gate_held = false;
        self.mutex.unlock(io);
        self.notify();
    }

    fn begin(self: *Manager, kind: Request) !u64 {
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

    fn send(self: *Manager, request: protocol.Request, cancel: Cancel, timeout: i64) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var json: std.Io.Writer.Allocating = .init(arena.allocator());
        try std.json.Stringify.value(request, .{}, &json.writer);
        try json.writer.writeByte('\n');
        const bytes = json.written();
        if (bytes.len > protocol.max_frame_bytes) return error.KernelRequestTooLarge;
        const deadline = now() + timeout;
        // The writer is held only for bounded pipe writes and signal delivery, so a short poll suffices.
        while (!self.writer.tryLock()) {
            if (cancelled(cancel) or now() >= deadline) return error.Cancelled;
            io_mod.sleep(2 * std.time.ns_per_ms);
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
            const can_save = self.persist and self.active == .none and self.save_guard == .open;
            self.mutex.unlock(io_mod.getIo());
            if (can_save) {
                if (self.begin(.snapshot)) |id| {
                    self.sendSnapshot(id) catch {};
                    self.waitDone(id, 5000) catch {};
                } else |_| {}
            }
            if (self.begin(.shutdown)) |id| {
                self.send(.{ .shutdown = id }, null, 1000) catch {};
                self.waitDone(id, 5000) catch {};
            } else |_| {}
        }
        self.reader_stop.store(true, .release);
        // Signal before join so an EOF wakes the reader even while the child was blocked.
        self.writer.lockUncancelable(io_mod.getIo());
        if (self.child) |child| if (child.id) |pid| {
            std.posix.kill(pid, .TERM) catch {};
        };
        self.writer.unlock(io_mod.getIo());
        if (self.reader_thread) |thread| thread.join();
        self.reader_thread = null;
        self.writer.lockUncancelable(io_mod.getIo());
        if (self.child) |*child| child.kill(io_mod.getIo());
        self.child = null;
        self.writer.unlock(io_mod.getIo());
        if (self.stderr_log) |file| file.close(io_mod.getIo());
        self.stderr_log = null;
        pool.retire(self);
        self.mutex.lockUncancelable(io_mod.getIo());
        self.state = .idle;
        self.active = .none;
        self.caller_waiting = false;
        self.sink = null;
        self.background.clear();
        self.save_due = null;
        self.mutex.unlock(io_mod.getIo());
        self.notify();
    }

    /// The reader's debounced save uses this too.
    pub fn sendSnapshot(self: *Manager, id: u64) !void {
        try self.send(.{ .snapshot = .{ .id = id, .path = self.snapshot_path } }, null, 1000);
    }

    /// Only the reader schedules a repair, after it has reaped the damaged child. A replacement
    /// corrupting during its own startup is discarded, not put into an automatic respawn loop.
    pub fn scheduleRepair(self: *Manager) void {
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
        self.lockGate(&self.stopping) catch return;
        defer self.unlockGate();
        if (self.disposed.load(.acquire) or self.stopping.load(.acquire) or self.generation != generation or self.status() != .failed) return;
        self.stopLocked(false);
        self.startLocked(null) catch {
            self.stopLocked(false);
        };
    }

    pub fn fail(self: *Manager, reason: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.state = .failed;
        self.diagnostic.append(self.alloc, reason, diagnostic_cap) catch {};
        self.mutex.unlock(io_mod.getIo());
        self.notify();
    }
};

fn acquireBootPermit(cancel: Cancel, owner: *const std.atomic.Value(bool)) !void {
    const io = io_mod.getIo();
    boot_mutex.lockUncancelable(io);
    defer boot_mutex.unlock(io);
    if (boot_limit == 0) {
        const cores = std.Thread.getCpuCount() catch 4;
        const default = @min(16, @max(4, cores *| 2));
        boot_limit = configuredBootLimit(io_mod.getenv("PROTO_FX_MAX_CONCURRENT_KERNEL_BOOTS"), default);
    }
    while (true) {
        if (cancelled(cancel) or owner.load(.acquire)) return error.Cancelled;
        if (boot_active < boot_limit) break;
        boot_changed.waitTimeout(io, &boot_mutex, .{ .duration = .{ .raw = .fromMilliseconds(poll_slice_ms), .clock = .awake } }) catch {};
    }
    boot_active += 1;
}

fn releaseBootPermit() void {
    const io = io_mod.getIo();
    boot_mutex.lockUncancelable(io);
    std.debug.assert(boot_active > 0);
    boot_active -= 1;
    boot_mutex.unlock(io);
    boot_changed.broadcast(io);
}

/// Start errors that an immediate second attempt cannot fix.
fn isPermanent(err: anyerror) bool {
    return switch (err) {
        error.Cancelled,
        error.KernelPlatformUnsupported,
        error.KernelPythonRequiresPython311AndDill,
        error.KernelSetupNeedsUv,
        error.KernelPythonProvisioningFailed,
        error.KernelHomeMustBeAbsolute,
        error.HomeNotSet,
        error.KernelCapacityExhausted,
        => true,
        else => false,
    };
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

fn cancelled(flag: Cancel) bool {
    return if (flag) |value| value.load(.acquire) else false;
}

// Runs only when PROTO_FX_KERNEL_TEST_PYTHON names a Python 3.11+ with dill. The
// runtime installs under a temporary kernel home, never the real profile.
test "kernel live cells persist globals across stop, restart and interrupt" {
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
    const artifacts = try std.Io.Dir.path.join(alloc, &.{ root, "artifacts" });
    defer alloc.free(artifacts);
    const manager = try Manager.create(alloc, .{ .cwd = root, .artifact_dir = artifacts, .python = python });
    defer manager.destroy();

    const first = try manager.execute(alloc, "x = 41\nprint('hi')", .{});
    defer first.deinit(alloc);
    try std.testing.expectEqual(Status.ok, first.status);
    try std.testing.expectEqualStrings("hi\n", first.stdout);

    // Stop snapshots the namespace; the next cell starts a new process and restores it.
    manager.stop(true);
    try std.testing.expectEqual(State.idle, manager.status());
    const restored = try manager.execute(alloc, "x + 1", .{});
    defer restored.deinit(alloc);
    try std.testing.expectEqualStrings("42", restored.result);

    const failed = try manager.execute(alloc, "1/0", .{});
    defer failed.deinit(alloc);
    try std.testing.expectEqual(Status.failed, failed.status);
    try std.testing.expect(std.mem.find(u8, failed.stderr, "ZeroDivisionError") != null);

    // Restart discards the process without a snapshot and restores the last save.
    manager.restart();
    const after_restart = try manager.execute(alloc, "x", .{});
    defer after_restart.deinit(alloc);
    try std.testing.expectEqualStrings("41", after_restart.result);

    var cancel = std.atomic.Value(bool).init(false);
    const canceller = try std.Thread.spawn(.{}, struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(300 * std.time.ns_per_ms);
            flag.store(true, .release);
        }
    }.run, .{&cancel});
    const interrupted = try manager.execute(alloc, "import time\ntime.sleep(30)", .{ .cancel = &cancel });
    canceller.join();
    defer interrupted.deinit(alloc);
    try std.testing.expectEqual(Status.aborted, interrupted.status);
    try std.testing.expect(interrupted.duration_ms < 5000);

    const still_alive = try manager.execute(alloc, "x * 2", .{});
    defer still_alive.deinit(alloc);
    try std.testing.expectEqualStrings("82", still_alive.result);
}

test {
    _ = protocol;
    _ = reader;
    _ = pool;
}
