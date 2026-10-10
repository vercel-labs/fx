//! Process-wide in-memory snapshot of the user's shell startup state.
//!
//! The first captured `user` profile command in a process runs the login
//! shell once and captures its exported environment plus a replay of its
//! aliases, functions, and selected options. Later commands start a clean
//! shell restored from that snapshot, so startup files run once per process
//! instead of once per command. A changed startup file or an explicit reload
//! marks the snapshot dirty: the next command recaptures it, and the approval
//! epoch advances so remembered shell approvals stop matching.
//!
//! Snapshot contents stay in memory. They reach a command only through its
//! environment and the supervisor's stdin script, and are never logged.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const shell_resolver = @import("shell_resolver.zig");
const command_runner = @import("../execution/command_runner.zig");

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

/// Longest time the login shell may take to report its state.
const capture_timeout_ms: i64 = 10_000;
/// Largest captured payload accepted; larger states fall back to full startup.
const max_capture_bytes: usize = 8 * 1024 * 1024;

const wait_poll_ns: u64 = 2 * std.time.ns_per_ms;
const read_poll_ms: i64 = 100;
pub const max_notice_bytes = 256;
const nonce_bytes = 16;

/// zsh reads its user files from up to three directories: an inherited
/// ZDOTDIR, HOME, and a ZDOTDIR the startup files set.
const max_user_dirs = 3;
const max_stamps = @max(
    zsh_system_files.len + max_user_dirs * zsh_user_files.len,
    bash_system_files.len + max_user_dirs * bash_user_files.len,
);

/// Environment entries a clean shell must set for itself instead of
/// inheriting them from the capture shell.
const shell_owned_variables = [_][]const u8{ "PWD", "OLDPWD", "SHLVL", "_" };

pub fn isSupported() bool {
    return comptime builtin.target.os.tag != .windows and builtin.target.os.tag != .wasi;
}

const Stamp = struct {
    present: bool = false,
    inode: std.Io.File.INode = 0,
    size: u64 = 0,
    mtime_ns: i96 = 0,
    ctime_ns: i96 = 0,

    fn eql(a: Stamp, b: Stamp) bool {
        return a.present == b.present and a.inode == b.inode and a.size == b.size and
            a.mtime_ns == b.mtime_ns and a.ctime_ns == b.ctime_ns;
    }
};

/// Metadata of the startup files a login shell reads. A difference means the
/// files changed since the snapshot was captured.
pub const Fingerprint = struct {
    stamps: [max_stamps]Stamp = @splat(.{}),
    len: usize = 0,

    pub fn eql(a: *const Fingerprint, b: *const Fingerprint) bool {
        if (a.len != b.len) return false;
        for (a.stamps[0..a.len], b.stamps[0..b.len]) |left, right| {
            if (!left.eql(right)) return false;
        }
        return true;
    }

    fn add(self: *Fingerprint, path: []const u8) void {
        std.debug.assert(self.len < max_stamps);
        self.stamps[self.len] = stampFile(path);
        self.len += 1;
    }
};

fn stampFile(path: []const u8) Stamp {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{}) catch return .{};
    return .{
        .present = true,
        .inode = stat.inode,
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
        .ctime_ns = stat.ctime.nanoseconds,
    };
}

const zsh_user_files = [_][]const u8{ ".zshenv", ".zprofile", ".zshrc", ".zlogin" };
const zsh_system_files = [_][]const u8{
    "/etc/zshenv",     "/etc/zprofile",     "/etc/zshrc",     "/etc/zlogin",
    "/etc/zsh/zshenv", "/etc/zsh/zprofile", "/etc/zsh/zshrc", "/etc/zsh/zlogin",
};
const bash_user_files = [_][]const u8{ ".bash_profile", ".bash_login", ".profile", ".bashrc" };
const bash_system_files = [_][]const u8{ "/etc/profile", "/etc/bash.bashrc", "/etc/bashrc" };

/// Stamps the startup files `kind` reads. User files come from each distinct
/// directory in `user_dirs` (HOME and any ZDOTDIR), in order.
fn fingerprintFor(kind: shell_resolver.ShellKind, user_dirs: []const ?[]const u8) Fingerprint {
    std.debug.assert(user_dirs.len <= max_user_dirs);
    var result: Fingerprint = .{};
    const system_files: []const []const u8 = switch (kind) {
        .zsh => &zsh_system_files,
        .bash => &bash_system_files,
    };
    const user_files: []const []const u8 = switch (kind) {
        .zsh => &zsh_user_files,
        .bash => &bash_user_files,
    };
    for (system_files) |path| result.add(path);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    for (user_dirs, 0..) |maybe_dir, index| {
        const dir = maybe_dir orelse continue;
        if (dir.len == 0) continue;
        var repeated = false;
        for (user_dirs[0..index]) |earlier| {
            const value = earlier orelse continue;
            if (std.mem.eql(u8, value, dir)) repeated = true;
        }
        if (repeated) continue;
        for (user_files) |name| {
            const path = std.mem.print(&path_buffer, "{s}/{s}", .{ dir, name }) catch continue;
            result.add(path);
        }
    }
    return result;
}

/// Adds the stamps of a ZDOTDIR the startup files set to the stamps taken
/// before the capture. The earlier stamps stay, so an edit made while the
/// capture ran still marks the snapshot dirty.
fn withMovedZdotdir(before: Fingerprint, extended: Fingerprint) Fingerprint {
    if (extended.len <= before.len) return before;
    var result = extended;
    @memcpy(result.stamps[0..before.len], before.stamps[0..before.len]);
    return result;
}

/// One immutable captured state. Its arena owns every field; the owner frees
/// it once it is replaced and its last lease ends.
pub const Generation = struct {
    arena: std.heap.ArenaAllocator,
    id: u64 = 0,
    epoch: u64 = 0,
    shell_path: []const u8 = "",
    environ: Environ.Map,
    replay: []const u8 = "",
    names: std.StringHashMapUnmanaged(void) = .empty,
    zdotdir: ?[]const u8 = null,
    fingerprint: Fingerprint = .{},
    // Guarded by the owning Owner's mutex.
    leases: usize = 0,
    retired: bool = false,
    next_retired: ?*Generation = null,

    /// Allocates an empty generation whose arena owns all later allocations.
    pub fn create() Allocator.Error!*Generation {
        const generation = try std.heap.page_allocator.create(Generation);
        generation.* = .{
            .arena = .init(std.heap.page_allocator),
            .environ = undefined,
        };
        generation.environ = .init(generation.arena.allocator());
        return generation;
    }

    pub fn destroy(self: *Generation) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }

    /// Reports whether the snapshot defines an alias or function `name`.
    pub fn defines(self: *const Generation, name: []const u8) bool {
        return self.names.contains(name);
    }
};

const CaptureFailure = enum {
    unsupported_shell,
    spawn_failed,
    timed_out,
    too_large,
    incomplete,
    out_of_memory,
    replay_failed,

    fn description(self: CaptureFailure) []const u8 {
        return switch (self) {
            .unsupported_shell => "the login shell is not bash or zsh",
            .spawn_failed => "the login shell could not start",
            .timed_out => std.fmt.comptimePrint(
                "the login shell did not finish within {d} s",
                .{capture_timeout_ms / std.time.ms_per_s},
            ),
            .too_large => std.fmt.comptimePrint(
                "the captured state exceeded {d} MiB",
                .{max_capture_bytes / (1024 * 1024)},
            ),
            .incomplete => "the login shell exited before reporting its state",
            .out_of_memory => "fx ran out of memory",
            .replay_failed => "the captured state could not be restored",
        };
    }
};

pub const CaptureRequest = struct {
    shell_path: []const u8,
    cwd: []const u8,
    /// Environment for the capture shell; null inherits fx's environment.
    environ: ?*const Environ.Map = null,
};

pub const CaptureOutcome = union(enum) {
    ready: *Generation,
    failed: CaptureFailure,
};

const CaptureFn = *const fn (request: CaptureRequest) CaptureOutcome;

const DirtyReason = enum { startup_files_changed, user_reload, agent_reload };

const WaitControl = struct {
    cancel_flag: ?*std.atomic.Value(bool) = null,
    deadline_ms: ?i64 = null,
};

const AcquireError = error{ Cancelled, TimeoutExpired };

pub const Lease = struct {
    owner: *Owner,
    generation: *Generation,

    pub fn release(self: Lease) void {
        self.owner.releaseGeneration(self.generation);
    }
};

const Acquired = union(enum) {
    snapshot: Lease,
    /// No usable snapshot: run the command with today's full startup.
    full_startup,
};

const State = enum { empty, capturing, ready, failed };

const Decision = union(enum) {
    lease: *Generation,
    full_startup,
    wait,
};

const Notice = struct {
    text: [max_notice_bytes]u8 = undefined,
    len: usize = 0,
    ui_pending: bool = false,
    result_pending: bool = false,
};

const PendingCapture = struct {
    owner: *Owner,
    shell_path: []u8,
    cwd: []u8,
    epoch: u64,
    fingerprint: Fingerprint,
};

/// Owns the snapshot state machine. One instance serves the whole process;
/// tests create their own with a fake capture function. All fields are
/// guarded by `mutex`.
pub const Owner = struct {
    mutex: std.Io.Mutex = .init,
    state: State = .empty,
    active: ?*Generation = null,
    retired: ?*Generation = null,
    dirty: bool = false,
    epoch: u64 = 0,
    next_id: u64 = 1,
    capture_thread: ?std.Thread = null,
    capture_fn: CaptureFn = captureWithShell,
    capture_environ: ?*const Environ.Map = null,
    failed_shell: [std.Io.Dir.max_path_bytes]u8 = undefined,
    failed_shell_len: usize = 0,
    failed_fingerprint: Fingerprint = .{},
    notice: Notice = .{},
    /// Epoch each remembered shell command grant was made under, keyed by
    /// the grant target. Keys are owned by `std.heap.c_allocator`.
    shell_grants: std.StringHashMapUnmanaged(u64) = .empty,

    /// Returns a lease on a ready snapshot, starts or waits for the single
    /// capture, or reports that the command must use full startup. Blocks
    /// only while a capture is running; cancellation and the deadline end the
    /// wait without cancelling the capture.
    pub fn acquire(
        self: *Owner,
        shell_path: []const u8,
        cwd: []const u8,
        control: WaitControl,
    ) AcquireError!Acquired {
        const io = io_mod.getIo();
        while (true) {
            self.mutex.lockUncancelable(io);
            const decision = self.decideLocked(shell_path, cwd);
            self.mutex.unlock(io);
            switch (decision) {
                .lease => |generation| return .{ .snapshot = .{
                    .owner = self,
                    .generation = generation,
                } },
                .full_startup => return .full_startup,
                .wait => {},
            }
            if (control.cancel_flag) |flag| {
                if (flag.load(.acquire)) return error.Cancelled;
            }
            if (control.deadline_ms) |deadline| {
                if (io_mod.milliTimestamp() >= deadline) return error.TimeoutExpired;
            }
            io_mod.sleep(wait_poll_ns);
        }
    }

    /// Requests a recapture before the next command and advances the
    /// approval epoch. A request while one is already pending is a no-op.
    pub fn markDirty(self: *Owner, reason: DirtyReason) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.markDirtyLocked(reason);
    }

    /// Fails the active generation after its replay could not be restored,
    /// so later commands use full startup until the startup files change.
    pub fn markReplayFailed(self: *Owner, generation: *Generation) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.state != .ready or self.active != generation) return;
        self.recordFailureLocked(generation.shell_path, &generation.fingerprint, .replay_failed);
    }

    /// Current approval epoch. Remembered shell approvals made under an
    /// earlier epoch no longer apply.
    pub fn approvalEpoch(self: *Owner) u64 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.epoch;
    }

    /// Starts a refresh when the startup files changed since the last
    /// capture. Admission calls this first so a remembered shell approval
    /// from before the change is asked again.
    pub fn checkStartupFiles(self: *Owner) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        switch (self.state) {
            .ready => self.noteChangesLocked(self.active.?.shell_path),
            .failed => self.noteChangesLocked(self.failed_shell[0..self.failed_shell_len]),
            .empty, .capturing => {},
        }
    }

    /// Records that a shell command grant was made under the current epoch.
    /// On allocation failure the grant stays unrecorded, which only makes it
    /// stop matching after the next refresh.
    pub fn recordShellGrant(self: *Owner, target: []const u8) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const entry = self.shell_grants.getOrPut(std.heap.c_allocator, target) catch {
            debug_trace.logf("core", "shell grant epoch not recorded err=OutOfMemory", .{});
            return;
        };
        if (!entry.found_existing) {
            entry.key_ptr.* = std.heap.c_allocator.dupe(u8, target) catch {
                self.shell_grants.removeByPtr(entry.key_ptr);
                debug_trace.logf("core", "shell grant epoch not recorded err=OutOfMemory", .{});
                return;
            };
        }
        entry.value_ptr.* = self.epoch;
    }

    /// Epoch a shell command grant was made under. Grants fx never recorded
    /// count as made before the first refresh.
    pub fn shellGrantEpoch(self: *Owner, target: []const u8) u64 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.shell_grants.get(target) orelse 0;
    }

    /// Reports whether a shell command grant was made under the current
    /// epoch. A refresh makes every earlier grant stop matching.
    pub fn shellGrantCurrent(self: *Owner, target: []const u8) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return (self.shell_grants.get(target) orelse 0) == self.epoch;
    }

    /// Reports whether fx fell back to full startup after a failed capture,
    /// so it cannot tell which names the startup files redefine.
    pub fn startupNamesUnknown(self: *Owner) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.state == .failed;
    }

    /// Reports whether any word of `command` names an alias or function in
    /// the current snapshot, so routine-command checks can defer to review.
    pub fn definesAnyWord(self: *Owner, command: []const u8) bool {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const generation = self.active orelse return false;
        var words = std.mem.tokenizeAny(u8, command, " \t\r\n;|&()<>'\"`$\\{}!");
        while (words.next()) |word| {
            if (generation.defines(word)) return true;
        }
        return false;
    }

    /// Takes the pending fallback notice for a user-facing surface. The
    /// returned slice borrows `buffer`.
    pub fn takeUiNotice(self: *Owner, buffer: []u8) ?[]const u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.notice.ui_pending) return null;
        self.notice.ui_pending = false;
        const len = @min(buffer.len, self.notice.len);
        @memcpy(buffer[0..len], self.notice.text[0..len]);
        return buffer[0..len];
    }

    /// Takes the pending fallback notice for a tool result. Caller owns the
    /// returned text.
    pub fn takeResultNotice(self: *Owner, alloc: Allocator) Allocator.Error!?[]u8 {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (!self.notice.result_pending) return null;
        const text = try alloc.dupe(u8, self.notice.text[0..self.notice.len]);
        self.notice.result_pending = false;
        return text;
    }

    /// Joins the capture thread and frees every generation. Only for owners
    /// that are no longer shared, such as test owners.
    pub fn deinit(self: *Owner) void {
        if (self.capture_thread) |thread| thread.join();
        var grant_keys = self.shell_grants.keyIterator();
        while (grant_keys.next()) |key| std.heap.c_allocator.free(key.*);
        self.shell_grants.deinit(std.heap.c_allocator);
        self.capture_thread = null;
        if (self.active) |generation| {
            std.debug.assert(generation.leases == 0);
            generation.destroy();
        }
        self.active = null;
        while (self.retired) |generation| {
            self.retired = generation.next_retired;
            generation.destroy();
        }
    }

    fn decideLocked(self: *Owner, shell_path: []const u8, cwd: []const u8) Decision {
        self.noteChangesLocked(shell_path);
        switch (self.state) {
            .capturing => return .wait,
            .ready => if (!self.dirty) {
                const generation = self.active.?;
                generation.leases += 1;
                return .{ .lease = generation };
            },
            .failed => if (!self.dirty) return .full_startup,
            .empty => {},
        }
        self.startCaptureLocked(shell_path, cwd) catch |err| {
            debug_trace.logf("core", "shell snapshot capture could not start err={s}", .{@errorName(err)});
            const fingerprint = currentFingerprint(shell_path, null);
            self.recordFailureLocked(shell_path, &fingerprint, .spawn_failed);
            return .full_startup;
        };
        return .wait;
    }

    fn noteChangesLocked(self: *Owner, shell_path: []const u8) void {
        if (self.dirty) return;
        switch (self.state) {
            .ready => {
                const generation = self.active.?;
                const fingerprint = currentFingerprint(generation.shell_path, generation.zdotdir);
                if (!std.mem.eql(u8, generation.shell_path, shell_path) or
                    !fingerprint.eql(&generation.fingerprint))
                {
                    self.markDirtyLocked(.startup_files_changed);
                }
            },
            .failed => {
                const failed_shell = self.failed_shell[0..self.failed_shell_len];
                const fingerprint = currentFingerprint(failed_shell, null);
                if (!std.mem.eql(u8, failed_shell, shell_path) or
                    !fingerprint.eql(&self.failed_fingerprint))
                {
                    self.markDirtyLocked(.startup_files_changed);
                }
            },
            .empty, .capturing => {},
        }
    }

    fn markDirtyLocked(self: *Owner, reason: DirtyReason) void {
        if (self.dirty) return;
        self.dirty = true;
        self.epoch += 1;
        debug_trace.logf("core", "shell snapshot dirty reason={s} epoch={d}", .{ @tagName(reason), self.epoch });
    }

    fn startCaptureLocked(self: *Owner, shell_path: []const u8, cwd: []const u8) !void {
        if (self.capture_thread) |thread| {
            // The previous capture already finished; only its thread remains.
            thread.join();
            self.capture_thread = null;
        }
        const pending = try std.heap.page_allocator.create(PendingCapture);
        errdefer std.heap.page_allocator.destroy(pending);
        const owned_shell = try std.heap.page_allocator.dupe(u8, shell_path);
        errdefer std.heap.page_allocator.free(owned_shell);
        const owned_cwd = try std.heap.page_allocator.dupe(u8, cwd);
        errdefer std.heap.page_allocator.free(owned_cwd);
        pending.* = .{
            .owner = self,
            .shell_path = owned_shell,
            .cwd = owned_cwd,
            .epoch = self.epoch,
            // Taken before the shell reads the files, so an edit during the
            // capture still marks the result dirty.
            .fingerprint = currentFingerprint(shell_path, null),
        };
        self.capture_thread = try std.Thread.spawn(.{}, runPendingCapture, .{pending});
        self.state = .capturing;
        self.dirty = false;
        debug_trace.logf("core", "shell snapshot capture started shell={s} epoch={d}", .{ shell_path, self.epoch });
    }

    fn finishCaptureLocked(self: *Owner, pending: *const PendingCapture, outcome: CaptureOutcome) void {
        switch (outcome) {
            .ready => |generation| {
                generation.id = self.next_id;
                self.next_id += 1;
                generation.epoch = pending.epoch;
                generation.fingerprint = pending.fingerprint;
                if (generation.zdotdir) |zdotdir| {
                    // The startup files moved ZDOTDIR; watch its files too.
                    generation.fingerprint = withMovedZdotdir(
                        pending.fingerprint,
                        currentFingerprint(pending.shell_path, zdotdir),
                    );
                }
                self.retireLocked(self.active);
                self.active = generation;
                self.state = .ready;
                self.notice.ui_pending = false;
                self.notice.result_pending = false;
                debug_trace.logf(
                    "core",
                    "shell snapshot ready generation={d} epoch={d} env_entries={d} names={d} replay_bytes={d}",
                    .{ generation.id, generation.epoch, generation.environ.count(), generation.names.count(), generation.replay.len },
                );
            },
            .failed => |reason| self.recordFailureLocked(pending.shell_path, &pending.fingerprint, reason),
        }
    }

    fn recordFailureLocked(
        self: *Owner,
        shell_path: []const u8,
        fingerprint: *const Fingerprint,
        reason: CaptureFailure,
    ) void {
        self.retireLocked(self.active);
        self.active = null;
        self.state = .failed;
        const len = @min(shell_path.len, self.failed_shell.len);
        @memcpy(self.failed_shell[0..len], shell_path[0..len]);
        self.failed_shell_len = len;
        self.failed_fingerprint = fingerprint.*;
        const text = std.mem.print(
            &self.notice.text,
            "shell snapshot unavailable ({s}); startup files run for every command",
            .{reason.description()},
        ) catch self.notice.text[0..0];
        self.notice.len = text.len;
        self.notice.ui_pending = true;
        self.notice.result_pending = true;
        debug_trace.logf("core", "shell snapshot capture failed reason={s} shell={s}", .{ @tagName(reason), shell_path });
    }

    fn retireLocked(self: *Owner, maybe_generation: ?*Generation) void {
        const generation = maybe_generation orelse return;
        if (generation.leases == 0) {
            generation.destroy();
            return;
        }
        generation.retired = true;
        generation.next_retired = self.retired;
        self.retired = generation;
    }

    fn releaseGeneration(self: *Owner, generation: *Generation) void {
        const io = io_mod.getIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(generation.leases > 0);
        generation.leases -= 1;
        if (!generation.retired or generation.leases != 0) return;
        var link = &self.retired;
        while (link.*) |candidate| : (link = &candidate.next_retired) {
            if (candidate == generation) {
                link.* = candidate.next_retired;
                break;
            }
        }
        generation.destroy();
    }
};

fn runPendingCapture(pending: *PendingCapture) void {
    const owner = pending.owner;
    const outcome = owner.capture_fn(.{
        .shell_path = pending.shell_path,
        .cwd = pending.cwd,
        .environ = owner.capture_environ,
    });
    const io = io_mod.getIo();
    owner.mutex.lockUncancelable(io);
    owner.finishCaptureLocked(pending, outcome);
    owner.mutex.unlock(io);
    std.heap.page_allocator.free(pending.shell_path);
    std.heap.page_allocator.free(pending.cwd);
    std.heap.page_allocator.destroy(pending);
}

fn currentFingerprint(shell_path: []const u8, snapshot_zdotdir: ?[]const u8) Fingerprint {
    const kind = shell_resolver.shellKind(shell_path) orelse return .{};
    const dirs = [_]?[]const u8{ io_mod.getenv("ZDOTDIR"), io_mod.getenv("HOME"), snapshot_zdotdir };
    return fingerprintFor(kind, if (kind == .zsh) &dirs else dirs[1..2]);
}

var process_owner: Owner = .{};

/// The owner shared by every host and subagent in this process.
pub fn processOwner() *Owner {
    return &process_owner;
}

/// Test-only: drops the process owner's state and installs `capture_fn`.
pub fn resetProcessOwnerForTest(capture_fn: CaptureFn) void {
    if (comptime !builtin.is_test) @compileError("resetProcessOwnerForTest is test-only");
    process_owner.deinit();
    process_owner = .{ .capture_fn = capture_fn };
}

/// Test-only: the real capture function, for restoring the process owner.
pub const real_capture_fn: CaptureFn = captureWithShell;

pub const ParseError = error{ MissingSection, InvalidEntry } || Allocator.Error;

/// Parses a capture payload into `generation`. Output before the first
/// marker, such as text printed by startup files, is ignored.
pub fn parsePayload(generation: *Generation, payload: []const u8, nonce: []const u8) ParseError!void {
    const alloc = generation.arena.allocator();
    const env_marker = try markerText(alloc, nonce, "ENV", "", "\x00");
    const names_marker = try markerText(alloc, nonce, "NAMES", "", "");
    const replay_marker = try markerText(alloc, nonce, "REPLAY", "", "");
    const end_marker = try markerText(alloc, nonce, "END", "\x00", "\x00");

    const env_start = (std.mem.find(u8, payload, env_marker) orelse return error.MissingSection) + env_marker.len;
    var cursor = env_start;
    var section: enum { env, names } = .env;
    const replay_start = while (cursor < payload.len) {
        const terminator = std.mem.findScalarPos(u8, payload, cursor, 0) orelse return error.MissingSection;
        const entry = payload[cursor..terminator];
        cursor = terminator + 1;
        switch (section) {
            .env => {
                if (std.mem.eql(u8, entry, names_marker)) {
                    section = .names;
                    continue;
                }
                const separator = std.mem.findScalar(u8, entry, '=') orelse return error.InvalidEntry;
                if (separator == 0) return error.InvalidEntry;
                const key = entry[0..separator];
                const value = entry[separator + 1 ..];
                if (isShellOwned(key)) continue;
                if (std.mem.eql(u8, key, "ZDOTDIR") and value.len != 0) {
                    generation.zdotdir = try alloc.dupe(u8, value);
                }
                try generation.environ.put(key, value);
            },
            .names => {
                if (std.mem.eql(u8, entry, replay_marker)) break cursor;
                if (entry.len == 0) continue;
                try generation.names.put(alloc, try alloc.dupe(u8, entry), {});
            },
        }
    } else return error.MissingSection;

    const replay_end = std.mem.findPos(u8, payload, replay_start, end_marker) orelse return error.MissingSection;
    generation.replay = try alloc.dupe(u8, payload[replay_start..replay_end]);
}

fn markerText(
    alloc: Allocator,
    nonce: []const u8,
    section: []const u8,
    prefix: []const u8,
    suffix: []const u8,
) Allocator.Error![]const u8 {
    return std.mem.concat(alloc, u8, &.{ prefix, shell_resolver.snapshot_marker_prefix, nonce, ":", section, suffix });
}

fn isShellOwned(key: []const u8) bool {
    for (shell_owned_variables) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

/// Runs the login shell once and captures its state. Never logs payload
/// contents.
fn captureWithShell(request: CaptureRequest) CaptureOutcome {
    const started_ms = io_mod.milliTimestamp();
    const outcome = captureWithShellChecked(request) catch |err| switch (err) {
        error.OutOfMemory => CaptureOutcome{ .failed = .out_of_memory },
        else => CaptureOutcome{ .failed = .spawn_failed },
    };
    debug_trace.logf("core", "shell snapshot capture finished outcome={s} duration_ms={d}", .{
        @tagName(std.meta.activeTag(outcome)),
        io_mod.milliTimestamp() - started_ms,
    });
    return outcome;
}

fn captureWithShellChecked(request: CaptureRequest) !CaptureOutcome {
    // Targets without detached process sessions, such as WASI, cannot run
    // the capture shell.
    if (comptime !command_runner.supports_foreground_session) return .{ .failed = .spawn_failed };
    const kind = shell_resolver.shellKind(request.shell_path) orelse
        return .{ .failed = .unsupported_shell };
    var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var nonce_raw: [nonce_bytes]u8 = undefined;
    io_mod.getIo().random(&nonce_raw);
    const nonce = std.fmt.bytesToHex(nonce_raw, .lower);
    const script = try shell_resolver.snapshotCaptureScript(scratch, kind, &nonce);
    const invocation = try shell_resolver.capturedInvocation(scratch, .{ .user = request.shell_path }, script);
    const end_marker = try markerText(scratch, &nonce, "END", "\x00", "\x00");

    const io = io_mod.getIo();
    // The capture runs an interactive login shell. Without its own session
    // it would share fx's controlling terminal, stop on job control, and its
    // startup files could write over the fx interface.
    var child = command_runner.spawnDetachedSession(
        scratch,
        invocation.argv(),
        request.cwd,
        request.environ,
    ) catch |err| {
        debug_trace.logf("core", "shell snapshot capture spawn failed err={s}", .{@errorName(err)});
        return .{ .failed = .spawn_failed };
    };
    const process_group: std.posix.pid_t = child.id orelse return .{ .failed = .spawn_failed };
    defer {
        // Ends the shell and anything its startup files left running in its
        // process group, as the command supervisor does after each command.
        std.posix.kill(-process_group, std.posix.SIG.KILL) catch {};
        if (child.stdin) |lifeline| {
            lifeline.close(io);
            child.stdin = null;
        }
        if (child.wait(io)) |_| {} else |err| {
            debug_trace.logf("core", "shell snapshot capture wait failed err={s}", .{@errorName(err)});
        }
    }

    var payload: std.ArrayList(u8) = .empty;
    const read_status = try readPayload(scratch, &payload, child.stdout.?.handle, child.stderr.?.handle, end_marker);
    switch (read_status) {
        .complete => {},
        .timed_out => return .{ .failed = .timed_out },
        .too_large => return .{ .failed = .too_large },
        .incomplete => return .{ .failed = .incomplete },
    }

    const generation = try Generation.create();
    errdefer generation.destroy();
    generation.shell_path = try generation.arena.allocator().dupe(u8, request.shell_path);
    parsePayload(generation, payload.items, &nonce) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MissingSection, error.InvalidEntry => {
            generation.destroy();
            return .{ .failed = .incomplete };
        },
    };
    return .{ .ready = generation };
}

const ReadStatus = enum { complete, timed_out, too_large, incomplete };

/// Reads the payload from `fd` until the end marker, discarding whatever the
/// startup files write to `stderr_fd` so a chatty file cannot fill its pipe.
fn readPayload(
    alloc: Allocator,
    payload: *std.ArrayList(u8),
    fd: std.posix.fd_t,
    stderr_fd: std.posix.fd_t,
    end_marker: []const u8,
) !ReadStatus {
    const deadline = io_mod.milliTimestamp() + capture_timeout_ms;
    var chunk: [64 * 1024]u8 = undefined;
    var fds = [_]std.posix.pollfd{
        .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = stderr_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    while (true) {
        const now = io_mod.milliTimestamp();
        if (now >= deadline) return .timed_out;
        const wait_ms: i32 = @intCast(@min(deadline - now, read_poll_ms));
        const ready = std.posix.poll(&fds, wait_ms) catch return .incomplete;
        if (ready == 0) continue;
        if (fds[1].revents != 0) {
            const drained = std.posix.read(stderr_fd, &chunk) catch 0;
            // Stop watching stderr once it closes.
            if (drained == 0) fds[1].fd = -1;
        }
        if (fds[0].revents == 0) continue;
        const read_len = std.posix.read(fd, &chunk) catch return .incomplete;
        if (read_len == 0) return .incomplete;
        if (payload.items.len + read_len > max_capture_bytes) return .too_large;
        const search_from = payload.items.len -| end_marker.len;
        try payload.appendSlice(alloc, chunk[0..read_len]);
        if (std.mem.findPos(u8, payload.items, search_from, end_marker) != null) return .complete;
    }
}

const testing = std.testing;

fn testPayload(alloc: Allocator, nonce: []const u8, chatter: []const u8) ![]u8 {
    return std.mem.concat(alloc, u8, &.{
        chatter,
        "FXSNAP:",
        nonce,
        ":ENV\x00",
        "PATH=/opt/fx-marker/bin:/usr/bin\x00",
        "PWD=/capture/cwd\x00",
        "SHLVL=2\x00",
        "MULTI=line one\nline two\x00",
        "ZDOTDIR=/home/user/.config/zsh\x00",
        "FXSNAP:",
        nonce,
        ":NAMES\x00",
        "ll\x00fx_function\x00\x00",
        "FXSNAP:",
        nonce,
        ":REPLAY\x00",
        "alias ll='ls -l'\nfx_function () {\n\tprint ok\n}\n",
        "\x00FXSNAP:",
        nonce,
        ":END\x00",
    });
}

test "snapshot payload parsing ignores startup output and shell-owned variables" {
    const generation = try Generation.create();
    defer generation.destroy();
    const nonce = "00112233445566778899aabbccddeeff";
    const payload = try testPayload(generation.arena.allocator(), nonce, "welcome from .zshrc\nFXSNAP:other:ENV\x00");
    try parsePayload(generation, payload, nonce);

    try testing.expectEqualStrings("/opt/fx-marker/bin:/usr/bin", generation.environ.get("PATH").?);
    try testing.expectEqualStrings("line one\nline two", generation.environ.get("MULTI").?);
    try testing.expect(generation.environ.get("PWD") == null);
    try testing.expect(generation.environ.get("SHLVL") == null);
    try testing.expectEqualStrings("/home/user/.config/zsh", generation.zdotdir.?);
    try testing.expect(generation.defines("ll"));
    try testing.expect(generation.defines("fx_function"));
    try testing.expect(!generation.defines("ls"));
    try testing.expectEqualStrings(
        "alias ll='ls -l'\nfx_function () {\n\tprint ok\n}\n",
        generation.replay,
    );
}

test "snapshot payload parsing rejects truncated or malformed payloads" {
    const nonce = "00112233445566778899aabbccddeeff";
    var scratch_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const full = try testPayload(scratch, nonce, "");

    const truncated = full[0 .. full.len - 4];
    const generation = try Generation.create();
    defer generation.destroy();
    try testing.expectError(error.MissingSection, parsePayload(generation, truncated, nonce));

    const malformed = try std.mem.concat(scratch, u8, &.{ "FXSNAP:", nonce, ":ENV\x00", "NOEQUALS\x00" });
    const second = try Generation.create();
    defer second.destroy();
    try testing.expectError(error.InvalidEntry, parsePayload(second, malformed, nonce));

    const third = try Generation.create();
    defer third.destroy();
    try testing.expectError(error.MissingSection, parsePayload(third, "no markers here", nonce));
}

const FakeCapture = struct {
    var calls: std.atomic.Value(u32) = .init(0);
    var delay_ms: u64 = 0;
    var fail: bool = false;

    fn reset(delay: u64, should_fail: bool) void {
        calls.store(0, .seq_cst);
        delay_ms = delay;
        fail = should_fail;
    }

    fn capture(request: CaptureRequest) CaptureOutcome {
        _ = calls.fetchAdd(1, .seq_cst);
        if (delay_ms != 0) io_mod.sleep(delay_ms * std.time.ns_per_ms);
        if (fail) return .{ .failed = .timed_out };
        const generation = Generation.create() catch return .{ .failed = .out_of_memory };
        generation.shell_path = generation.arena.allocator().dupe(u8, request.shell_path) catch {
            generation.destroy();
            return .{ .failed = .out_of_memory };
        };
        generation.replay = "alias ll='ls -l'\n";
        generation.names.put(generation.arena.allocator(), "ll", {}) catch {};
        return .{ .ready = generation };
    }
};

test "snapshot owner captures once for concurrent first commands" {
    FakeCapture.reset(50, false);
    var owner: Owner = .{ .capture_fn = FakeCapture.capture };
    defer owner.deinit();

    const Worker = struct {
        fn run(target: *Owner, result: *?u64) void {
            const acquired = target.acquire("/bin/zsh", "/tmp", .{}) catch return;
            switch (acquired) {
                .snapshot => |lease| {
                    result.* = lease.generation.id;
                    lease.release();
                },
                .full_startup => {},
            }
        }
    };
    var ids: [4]?u64 = @splat(null);
    var threads: [4]std.Thread = undefined;
    for (&threads, &ids) |*thread, *id| thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &owner, id });
    for (threads) |thread| thread.join();

    try testing.expectEqual(@as(u32, 1), FakeCapture.calls.load(.seq_cst));
    for (ids) |id| try testing.expectEqual(@as(?u64, 1), id);
}

test "snapshot owner keeps a leased generation alive across a refresh" {
    FakeCapture.reset(0, false);
    var owner: Owner = .{ .capture_fn = FakeCapture.capture };
    defer owner.deinit();

    const first = (try owner.acquire("/bin/zsh", "/tmp", .{})).snapshot;
    const epoch_before = owner.approvalEpoch();
    owner.markDirty(.user_reload);
    try testing.expectEqual(epoch_before + 1, owner.approvalEpoch());
    owner.markDirty(.agent_reload);
    try testing.expectEqual(epoch_before + 1, owner.approvalEpoch());

    const second = (try owner.acquire("/bin/zsh", "/tmp", .{})).snapshot;
    try testing.expectEqual(@as(u32, 2), FakeCapture.calls.load(.seq_cst));
    try testing.expect(first.generation != second.generation);
    try testing.expect(first.generation.retired);
    // The retired generation is still readable while its lease is held.
    try testing.expectEqualStrings("alias ll='ls -l'\n", first.generation.replay);
    try testing.expectEqual(epoch_before + 1, second.generation.epoch);
    first.release();
    try testing.expect(owner.retired == null);
    second.release();
}

test "snapshot owner resets remembered shell grants on refresh" {
    FakeCapture.reset(0, false);
    var owner: Owner = .{ .capture_fn = FakeCapture.capture };
    defer owner.deinit();

    // Grants fx never recorded count as made before the first refresh.
    try testing.expect(owner.shellGrantCurrent("npm test"));
    owner.recordShellGrant("npm test");
    try testing.expectEqual(@as(u64, 0), owner.shellGrantEpoch("npm test"));

    owner.markDirty(.user_reload);
    try testing.expect(!owner.shellGrantCurrent("npm test"));
    try testing.expect(!owner.shellGrantCurrent("never recorded"));
    owner.recordShellGrant("npm test");
    try testing.expect(owner.shellGrantCurrent("npm test"));
    try testing.expectEqual(@as(u64, 1), owner.shellGrantEpoch("npm test"));
}

test "snapshot owner reports aliases and functions named in a command" {
    FakeCapture.reset(0, false);
    var owner: Owner = .{ .capture_fn = FakeCapture.capture };
    defer owner.deinit();

    try testing.expect(!owner.definesAnyWord("ll -a"));
    const lease = (try owner.acquire("/bin/zsh", "/tmp", .{})).snapshot;
    defer lease.release();
    try testing.expect(owner.definesAnyWord("ll -a"));
    try testing.expect(owner.definesAnyWord("git status && ll"));
    try testing.expect(owner.definesAnyWord("echo $(ll)"));
    try testing.expect(!owner.definesAnyWord("ls -l"));
    try testing.expect(!owner.definesAnyWord("llama --help"));
}

test "snapshot owner falls back with one notice and recovers after reload" {
    FakeCapture.reset(0, true);
    var owner: Owner = .{ .capture_fn = FakeCapture.capture };
    defer owner.deinit();

    try testing.expect((try owner.acquire("/bin/zsh", "/tmp", .{})) == .full_startup);
    try testing.expect((try owner.acquire("/bin/zsh", "/tmp", .{})) == .full_startup);
    try testing.expectEqual(@as(u32, 1), FakeCapture.calls.load(.seq_cst));

    var buffer: [max_notice_bytes]u8 = undefined;
    const notice = owner.takeUiNotice(&buffer).?;
    try testing.expect(std.mem.find(u8, notice, "startup files run for every command") != null);
    try testing.expect(owner.takeUiNotice(&buffer) == null);
    const result_notice = (try owner.takeResultNotice(testing.allocator)).?;
    defer testing.allocator.free(result_notice);
    try testing.expectEqualStrings(notice, result_notice);
    try testing.expect((try owner.takeResultNotice(testing.allocator)) == null);

    FakeCapture.fail = false;
    owner.markDirty(.user_reload);
    const lease = (try owner.acquire("/bin/zsh", "/tmp", .{})).snapshot;
    lease.release();
    try testing.expect(owner.takeUiNotice(&buffer) == null);
}

test "snapshot owner waiters stop on cancellation without cancelling the capture" {
    FakeCapture.reset(150, false);
    var owner: Owner = .{ .capture_fn = FakeCapture.capture };
    defer owner.deinit();

    var cancel = std.atomic.Value(bool).init(true);
    try testing.expectError(
        error.Cancelled,
        owner.acquire("/bin/zsh", "/tmp", .{ .cancel_flag = &cancel }),
    );
    const lease = (try owner.acquire("/bin/zsh", "/tmp", .{})).snapshot;
    lease.release();
    try testing.expectEqual(@as(u32, 1), FakeCapture.calls.load(.seq_cst));
}

test "snapshot owner fails the active generation after a replay failure" {
    FakeCapture.reset(0, false);
    var owner: Owner = .{ .capture_fn = FakeCapture.capture };
    defer owner.deinit();

    const lease = (try owner.acquire("/bin/zsh", "/tmp", .{})).snapshot;
    owner.markReplayFailed(lease.generation);
    lease.release();
    try testing.expect((try owner.acquire("/bin/zsh", "/tmp", .{})) == .full_startup);
    var buffer: [max_notice_bytes]u8 = undefined;
    const notice = owner.takeUiNotice(&buffer).?;
    try testing.expect(std.mem.find(u8, notice, "could not be restored") != null);
}

test "snapshot fingerprint changes when a startup file changes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch_state.deinit();
    const home = try io_mod.dirRealpathAlloc(scratch_state.allocator(), tmp.dir, ".");
    const dirs = [_]?[]const u8{ home, home };

    const before = fingerprintFor(.zsh, &dirs);
    try testing.expect(before.eql(&fingerprintFor(.zsh, &dirs)));
    try tmp.dir.writeFile(io_mod.getIo(), .{ .sub_path = ".zshrc", .data = "alias ll='ls -l'\n" });
    const after = fingerprintFor(.zsh, &dirs);
    try testing.expect(!before.eql(&after));
    try testing.expectEqual(zsh_system_files.len + zsh_user_files.len, after.len);
}

test "snapshot fingerprint stamps every startup directory zsh can read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    for ([_][]const u8{ "inherited", "home", "moved" }) |name| try tmp.dir.createDir(io_mod.getIo(), name, .default_dir);
    const dirs = [_]?[]const u8{
        try io_mod.dirRealpathAlloc(scratch, tmp.dir, "inherited"),
        try io_mod.dirRealpathAlloc(scratch, tmp.dir, "home"),
        try io_mod.dirRealpathAlloc(scratch, tmp.dir, "moved"),
    };

    const before = fingerprintFor(.zsh, &dirs);
    try testing.expectEqual(zsh_system_files.len + max_user_dirs * zsh_user_files.len, before.len);
    // The last directory's files are watched like the first's.
    try writeTestFile(tmp.dir, "moved/.zshrc", "alias ll='ls -l'\n");
    try testing.expect(!before.eql(&fingerprintFor(.zsh, &dirs)));
}

test "a moved ZDOTDIR keeps the stamps taken before the capture" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    for ([_][]const u8{ "home", "moved" }) |name| try tmp.dir.createDir(io_mod.getIo(), name, .default_dir);
    const home = try io_mod.dirRealpathAlloc(scratch, tmp.dir, "home");
    const moved = try io_mod.dirRealpathAlloc(scratch, tmp.dir, "moved");
    const now = [_]?[]const u8{ null, home, moved };

    const before_capture = fingerprintFor(.zsh, &[_]?[]const u8{ null, home, null });
    // An edit while the capture runs, then the capture reports the move.
    try writeTestFile(tmp.dir, "home/.zshrc", "export ZDOTDIR=moved\n");
    const merged = withMovedZdotdir(before_capture, fingerprintFor(.zsh, &now));
    try testing.expectEqual(before_capture.len + zsh_user_files.len, merged.len);
    try testing.expect(!merged.eql(&fingerprintFor(.zsh, &now)));

    // Without an edit during the capture, the merged stamps match.
    const after_edit = fingerprintFor(.zsh, &[_]?[]const u8{ null, home, null });
    const clean = withMovedZdotdir(after_edit, fingerprintFor(.zsh, &now));
    try testing.expect(clean.eql(&fingerprintFor(.zsh, &now)));
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    try dir.writeFile(io_mod.getIo(), .{ .sub_path = path, .data = data });
}

fn expectRealCapture(shell_path: []const u8, file_name: []const u8, contents: []const u8) !void {
    std.Io.Dir.accessAbsolute(io_mod.getIo(), shell_path, .{}) catch return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var scratch_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const home = try io_mod.dirRealpathAlloc(scratch, tmp.dir, ".");
    try writeTestFile(tmp.dir, file_name, contents);
    if (std.mem.eql(u8, file_name, ".bashrc")) {
        try writeTestFile(tmp.dir, ".bash_profile", ". \"$HOME/.bashrc\"\n");
    }

    var environ = Environ.Map.init(scratch);
    try environ.put("HOME", home);
    try environ.put("ZDOTDIR", home);
    try environ.put("PATH", "/usr/bin:/bin");
    try environ.put("TERM", "dumb");

    const outcome = captureWithShell(.{ .shell_path = shell_path, .cwd = home, .environ = &environ });
    const generation = switch (outcome) {
        .ready => |value| value,
        .failed => |reason| {
            // Names the failure in the test output without a direct write.
            try testing.expectEqualStrings("ready", @tagName(reason));
            unreachable;
        },
    };
    defer generation.destroy();
    try testing.expectEqualStrings("captured-from-startup", generation.environ.get("FX_SNAPSHOT_MARKER").?);
    try testing.expect(std.mem.startsWith(u8, generation.environ.get("PATH").?, "/opt/fx-snapshot-marker/bin:"));
    try testing.expect(generation.environ.get("PWD") == null);
    try testing.expect(generation.defines("fxll"));
    try testing.expect(generation.defines("fx_snapshot_function"));
    try testing.expect(std.mem.find(u8, generation.replay, "fx_snapshot_function") != null);
    try testing.expect(std.mem.find(u8, generation.replay, "fxll") != null);
    try testing.expect(std.mem.find(u8, generation.replay, "startup chatter") == null);
}

test "snapshot capture reads a real zsh login shell" {
    try expectRealCapture(
        "/bin/zsh",
        ".zshrc",
        "print -r -- 'startup chatter'\n" ++
            "export FX_SNAPSHOT_MARKER=captured-from-startup\n" ++
            "export PATH=\"/opt/fx-snapshot-marker/bin:$PATH\"\n" ++
            "alias fxll='print -r -- alias-ok'\n" ++
            "fx_snapshot_function() { print -r -- function-ok; }\n" ++
            "_fx_completion_helper() { :; }\n",
    );
}

test "snapshot capture reads a real bash login shell" {
    try expectRealCapture(
        "/bin/bash",
        ".bashrc",
        "echo 'startup chatter'\n" ++
            "export FX_SNAPSHOT_MARKER=captured-from-startup\n" ++
            "export PATH=\"/opt/fx-snapshot-marker/bin:$PATH\"\n" ++
            "alias fxll='echo alias-ok'\n" ++
            "fx_snapshot_function() { echo function-ok; }\n",
    );
}
