const std = @import("std");
const builtin = @import("builtin");
const darwin_process_spawn = @import("../shared/darwin_process_spawn.zig");
const io_mod = @import("../shared/io.zig");
const process_identity = @import("process_identity.zig");

const Allocator = std.mem.Allocator;

const DarwinPipeIdentity = struct {
    handle: u64,
    peer_handle: u64,

    fn eql(self: DarwinPipeIdentity, other: DarwinPipeIdentity) bool {
        return self.handle == other.handle and self.peer_handle == other.peer_handle;
    }
};

/// Kernel-owned command membership that survives environment replacement,
/// exec, process-group changes, and forks. The caller owns `deinit`.
pub const DarwinProcessWitness = struct {
    supervisor_fd: ?std.posix.fd_t,
    child_fd: ?std.posix.fd_t,
    descendant_fd: std.posix.fd_t,
    identity: DarwinPipeIdentity,

    pub fn init() !DarwinProcessWitness {
        if (comptime builtin.target.os.tag != .macos) return error.ProcessTreeUnsupported;
        var pipe: [2]std.posix.fd_t = undefined;
        switch (std.posix.errno(std.posix.system.pipe(&pipe))) {
            .SUCCESS => {},
            else => |err| return std.posix.unexpectedErrno(err),
        }
        errdefer closeFd(pipe[0]);
        errdefer closeFd(pipe[1]);
        try setCloseOnExec(pipe[0]);
        try setCloseOnExec(pipe[1]);
        return .{
            .supervisor_fd = pipe[0],
            .child_fd = pipe[1],
            .descendant_fd = darwin_process_spawn.inherited_fd_target(pipe[1]),
            .identity = try captureDarwinPipeIdentity(std.c.getpid(), pipe[1]),
        };
    }

    pub fn childFd(self: DarwinProcessWitness) std.posix.fd_t {
        return self.child_fd orelse unreachable;
    }

    pub fn closeChildCopy(self: *DarwinProcessWitness) void {
        const fd = self.child_fd orelse return;
        closeFd(fd);
        self.child_fd = null;
    }

    pub fn deinit(self: *DarwinProcessWitness) void {
        if (self.child_fd) |fd| closeFd(fd);
        if (self.supervisor_fd) |fd| closeFd(fd);
        self.* = undefined;
    }
};

const Identity = union(enum) {
    linux_start_ticks: u64,
    macos_unique_id: u64,

    fn eql(self: Identity, other: Identity) bool {
        return switch (self) {
            .linux_start_ticks => |ticks| switch (other) {
                .linux_start_ticks => |other_ticks| ticks == other_ticks,
                else => false,
            },
            .macos_unique_id => |unique_id| switch (other) {
                .macos_unique_id => |other_unique_id| unique_id == other_unique_id,
                else => false,
            },
        };
    }
};

const TrackedProcess = struct {
    pid: std.posix.pid_t,
    identity: Identity,
    /// A stop pass stopped this process, and this tracker has not killed or
    /// resumed it since.
    stopped: bool = false,
};

const ProcessSnapshot = struct {
    identity: Identity,
    parent_pid: std.posix.pid_t,
    parent_unique_id: ?u64 = null,
    started_at_us: ?u64 = null,
    zombie: bool = false,
};

pub const DeliverySummary = struct {
    delivered: usize = 0,
    incomplete: bool = false,
};

/// Signal delivery after a command completed naturally. `kept_detached`
/// counts the daemons the latest pass left running.
pub const CompletionDelivery = struct {
    delivery: DeliverySummary = .{},
    kept_detached: usize = 0,
};

const ProcessGroupState = union(enum) {
    found: std.posix.pid_t,
    vanished,
    unavailable,
};

const SessionState = union(enum) {
    found: std.posix.pid_t,
    vanished,
    unavailable,
};

/// How natural completion treats one live tracked process.
const CompletionStanding = enum {
    /// Still in the command's session, so natural completion stops it.
    attached,
    /// Moved to its own session, the POSIX way a program becomes a daemon, so
    /// natural completion leaves it running.
    detached,
    /// Exited or replaced, so nothing remains to stop.
    gone,
};

/// A process whose session cannot be read stays attached, preserving
/// containment when evidence is missing.
fn completionStanding(
    command_session: std.posix.pid_t,
    session: SessionState,
) CompletionStanding {
    return switch (session) {
        .found => |value| if (value == command_session) .attached else .detached,
        .vanished => .gone,
        .unavailable => .attached,
    };
}

const SystemSignalEffects = struct {
    fn capture(alloc: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
        return captureSnapshot(alloc, pid);
    }

    fn processGroup(pid: std.posix.pid_t) ProcessGroupState {
        return inspectProcessGroup(pid);
    }

    fn session(pid: std.posix.pid_t) SessionState {
        return inspectSession(pid);
    }

    fn send(pid: std.posix.pid_t, signal: std.posix.SIG) std.posix.KillError!void {
        return std.posix.kill(pid, signal);
    }

    fn ownPid() std.posix.pid_t {
        return std.c.getpid();
    }

    fn list(alloc: Allocator, out: *std.ArrayList(std.posix.pid_t)) !void {
        return listProcessIds(alloc, out);
    }
};

/// Tracks a command root and descendants across new sessions or process
/// groups. Identity checks guard both traversal and signaling against PID
/// reuse.
pub const Tracker = struct {
    alloc: Allocator,
    root: ?TrackedProcess = null,
    processes: std.ArrayList(TrackedProcess) = .empty,
    macos_child_buffer: []std.posix.pid_t = &.{},
    macos_pid_buffer: []std.posix.pid_t = &.{},
    darwin_process_witness: ?DarwinPipeIdentity = null,
    darwin_process_witness_fd: ?std.posix.fd_t = null,
    macos_root_started_at_us: ?u64 = null,

    pub fn init(alloc: Allocator) !Tracker {
        var tracker = Tracker{ .alloc = alloc };
        errdefer tracker.deinit();
        if (comptime builtin.target.os.tag == .macos) {
            const reported = Darwin.proc_listchildpids(0, null, 0);
            const capacity: usize = if (reported > 0)
                @max(@as(usize, @intCast(reported)) + 256, 1024)
            else
                1024;
            tracker.macos_child_buffer = try alloc.alloc(
                std.posix.pid_t,
                capacity,
            );
            const process_count = Darwin.proc_listallpids(null, 0);
            const process_capacity: usize = if (process_count > 0)
                @max(@as(usize, @intCast(process_count)) + 256, 1024)
            else
                1024;
            tracker.macos_pid_buffer = try alloc.alloc(
                std.posix.pid_t,
                process_capacity,
            );
        }
        return tracker;
    }

    pub fn deinit(self: *Tracker) void {
        self.processes.deinit(self.alloc);
        if (self.macos_child_buffer.len > 0) {
            self.alloc.free(self.macos_child_buffer);
        }
        if (self.macos_pid_buffer.len > 0) {
            self.alloc.free(self.macos_pid_buffer);
        }
        self.* = undefined;
    }

    pub fn bindProcessWitness(
        self: *Tracker,
        witness: *const DarwinProcessWitness,
    ) void {
        if (comptime builtin.target.os.tag != .macos) return;
        self.darwin_process_witness = witness.identity;
        self.darwin_process_witness_fd = witness.descendant_fd;
    }

    pub fn refresh(self: *Tracker, root_pid: std.posix.pid_t) !void {
        const root_snapshot: ?ProcessSnapshot = captureSnapshot(self.alloc, root_pid) catch |err| switch (err) {
            error.ProcessNotFound => null,
            else => return err,
        };
        var traverse_root = false;
        if (root_snapshot) |snapshot| {
            if (self.root) |root| {
                traverse_root = root.pid == root_pid and
                    root.identity.eql(snapshot.identity);
            } else {
                self.root = .{
                    .pid = root_pid,
                    .identity = snapshot.identity,
                };
                self.macos_root_started_at_us = snapshot.started_at_us;
                traverse_root = true;
            }
        }
        if (traverse_root) try self.appendDirectChildren(self.root.?);
        if (comptime builtin.target.os.tag == .macos) {
            if (root_snapshot == null) try self.refreshLineageProcesses();
        }

        var parent_index: usize = 0;
        while (parent_index < self.processes.items.len) : (parent_index += 1) {
            const parent = self.processes.items[parent_index];
            const actual = captureSnapshot(self.alloc, parent.pid) catch continue;
            if (!shouldTraverseParent(parent.identity, actual.identity)) continue;
            try self.appendDirectChildren(parent);
        }
    }

    pub fn refreshAdditionalRoot(
        self: *Tracker,
        root_pid: std.posix.pid_t,
    ) !void {
        const snapshot = captureSnapshot(self.alloc, root_pid) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        try self.appendDirectChildren(.{
            .pid = root_pid,
            .identity = snapshot.identity,
        });
    }

    pub fn refreshLineageProcesses(self: *Tracker) !void {
        if (comptime builtin.target.os.tag != .macos) return;
        const reported = Darwin.proc_listallpids(null, 0);
        if (reported <= 0) return;
        const required = @as(usize, @intCast(reported)) + 256;
        if (required > self.macos_pid_buffer.len) {
            self.macos_pid_buffer = try self.alloc.realloc(
                self.macos_pid_buffer,
                required,
            );
        }
        const count = Darwin.proc_listallpids(
            self.macos_pid_buffer.ptr,
            @intCast(self.macos_pid_buffer.len * @sizeOf(std.posix.pid_t)),
        );
        if (count <= 0) return;
        const process_count = @min(
            @as(usize, @intCast(count)),
            self.macos_pid_buffer.len,
        );
        var changed = true;
        while (changed) {
            changed = false;
            for (self.macos_pid_buffer[0..process_count]) |pid| {
                if (pid <= 0 or pid == std.c.getpid()) continue;
                if (try self.trackLineageProcess(pid)) changed = true;
            }
        }
    }

    pub fn signalAll(self: *Tracker, signal: std.posix.SIG) usize {
        return self.signalProcessesChecked(signal, null).delivered;
    }

    /// Stops every tracked process, parents first, for a caller that kills
    /// some of them another way, such as by process group, before this
    /// tracker kills the rest. That kill resumes any stopped process that
    /// neither kill reached.
    pub fn stopAll(self: *Tracker) void {
        self.stopProcessesWith(null, SystemSignalEffects);
    }

    pub fn signalOutsideProcessGroup(
        self: *Tracker,
        signal: std.posix.SIG,
        preserved_group: std.posix.pid_t,
    ) usize {
        return self.signalProcessesChecked(signal, preserved_group).delivered;
    }

    pub fn signalOutsideProcessGroupChecked(
        self: *Tracker,
        signal: std.posix.SIG,
        preserved_group: std.posix.pid_t,
    ) DeliverySummary {
        return self.signalProcessesChecked(signal, preserved_group);
    }

    fn signalProcessesChecked(
        self: *Tracker,
        signal: std.posix.SIG,
        preserved_group: ?std.posix.pid_t,
    ) DeliverySummary {
        return self.signalProcessesWith(
            signal,
            preserved_group,
            SystemSignalEffects,
        );
    }

    fn signalProcessesWith(
        self: *Tracker,
        signal: std.posix.SIG,
        preserved_group: ?std.posix.pid_t,
        comptime Effects: type,
    ) DeliverySummary {
        if (signal != std.posix.SIG.KILL) {
            return self.signalProcessesOnceWith(signal, preserved_group, Effects);
        }
        self.stopProcessesWith(preserved_group, Effects);
        const summary = self.signalProcessesOnceWith(signal, preserved_group, Effects);
        self.resumeStoppedWith(Effects);
        return summary;
    }

    /// Stops every tracked process before a SIGKILL. A parent whose child
    /// dies before its own kill arrives would otherwise run its next command,
    /// as `sleep 30; rm -rf out` does once `sleep` is gone. Parents stop
    /// before their children, because a shell with job control also moves on
    /// when its foreground job stops.
    fn stopProcessesWith(
        self: *Tracker,
        preserved_group: ?std.posix.pid_t,
        comptime Effects: type,
    ) void {
        var summary: DeliverySummary = .{};
        if (self.root) |*root| {
            self.signalTrackedProcessWith(root, std.posix.SIG.STOP, preserved_group, &summary, Effects);
        }
        for (self.processes.items) |*process| {
            self.signalTrackedProcessWith(process, std.posix.SIG.STOP, preserved_group, &summary, Effects);
        }
    }

    /// Sends `signal` to each tracked process, children before parents.
    fn signalProcessesOnceWith(
        self: *Tracker,
        signal: std.posix.SIG,
        preserved_group: ?std.posix.pid_t,
        comptime Effects: type,
    ) DeliverySummary {
        var summary: DeliverySummary = .{};
        var index = self.processes.items.len;
        while (index > 0) {
            index -= 1;
            self.signalTrackedProcessWith(
                &self.processes.items[index],
                signal,
                preserved_group,
                &summary,
                Effects,
            );
        }
        if (self.root) |*root| {
            self.signalTrackedProcessWith(
                root,
                signal,
                preserved_group,
                &summary,
                Effects,
            );
        }
        return summary;
    }

    /// Resumes each process a stop pass stopped that the kill after it
    /// skipped, so a stop never outlasts its kill. A process can leave the
    /// command's session or process group after the stop pass reads it but
    /// before its SIGSTOP lands, and the kill then leaves it alone.
    fn resumeStoppedWith(self: *Tracker, comptime Effects: type) void {
        var summary: DeliverySummary = .{};
        if (self.root) |*root| self.resumeIfStoppedWith(root, &summary, Effects);
        for (self.processes.items) |*process| {
            self.resumeIfStoppedWith(process, &summary, Effects);
        }
    }

    fn resumeIfStoppedWith(
        self: *Tracker,
        process: *TrackedProcess,
        summary: *DeliverySummary,
        comptime Effects: type,
    ) void {
        if (!process.stopped) return;
        process.stopped = false;
        self.signalTrackedProcessWith(process, std.posix.SIG.CONT, null, summary, Effects);
    }

    fn signalTrackedProcessWith(
        self: *Tracker,
        process: *TrackedProcess,
        signal: std.posix.SIG,
        preserved_group: ?std.posix.pid_t,
        summary: *DeliverySummary,
        comptime Effects: type,
    ) void {
        const actual = Effects.capture(self.alloc, process.pid) catch |err| {
            if (err != error.ProcessNotFound) summary.incomplete = true;
            return;
        };
        if (!process.identity.eql(actual.identity)) return;
        if (actual.zombie) return;
        const process_group = switch (Effects.processGroup(process.pid)) {
            .found => |value| value,
            .vanished => return,
            .unavailable => {
                summary.incomplete = true;
                return;
            },
        };
        if (!shouldSignalProcess(process_group, preserved_group)) return;
        Effects.send(process.pid, signal) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => {
                summary.incomplete = true;
                return;
            },
        };
        summary.delivered += 1;
        if (signal == std.posix.SIG.STOP) process.stopped = true;
        if (signal == std.posix.SIG.KILL) process.stopped = false;
    }

    pub fn anyAlive(self: *Tracker) bool {
        if (self.root) |root| {
            const actual: ?ProcessSnapshot = captureSnapshot(self.alloc, root.pid) catch null;
            if (actual) |snapshot| {
                if (root.identity.eql(snapshot.identity) and snapshotIsAlive(snapshot)) return true;
            }
        }
        for (self.processes.items) |process| {
            const actual = captureSnapshot(self.alloc, process.pid) catch continue;
            if (process.identity.eql(actual.identity) and snapshotIsAlive(actual)) return true;
        }
        return false;
    }

    /// Signals the tracked processes still in `command_session` and leaves
    /// processes that moved to their own session running.
    pub fn signalAttached(
        self: *Tracker,
        signal: std.posix.SIG,
        command_session: std.posix.pid_t,
    ) CompletionDelivery {
        return self.signalAttachedWith(signal, command_session, SystemSignalEffects);
    }

    /// Reports whether any tracked process still in `command_session` is alive.
    pub fn anyAttachedAlive(
        self: *Tracker,
        command_session: std.posix.pid_t,
    ) bool {
        return self.anyAttachedAliveWith(command_session, SystemSignalEffects);
    }

    fn signalAttachedWith(
        self: *Tracker,
        signal: std.posix.SIG,
        command_session: std.posix.pid_t,
        comptime Effects: type,
    ) CompletionDelivery {
        if (signal != std.posix.SIG.KILL) {
            return self.signalAttachedOnceWith(signal, command_session, Effects);
        }
        self.stopAttachedWith(command_session, Effects);
        const result = self.signalAttachedOnceWith(signal, command_session, Effects);
        self.resumeStoppedWith(Effects);
        return result;
    }

    /// Stops the attached processes, parents first, for the reasons
    /// `stopProcessesWith` gives.
    fn stopAttachedWith(
        self: *Tracker,
        command_session: std.posix.pid_t,
        comptime Effects: type,
    ) void {
        var result: CompletionDelivery = .{};
        if (self.root) |*root| {
            self.signalIfAttachedWith(root, std.posix.SIG.STOP, command_session, &result, Effects);
        }
        for (self.processes.items) |*process| {
            self.signalIfAttachedWith(process, std.posix.SIG.STOP, command_session, &result, Effects);
        }
    }

    fn signalAttachedOnceWith(
        self: *Tracker,
        signal: std.posix.SIG,
        command_session: std.posix.pid_t,
        comptime Effects: type,
    ) CompletionDelivery {
        var result: CompletionDelivery = .{};
        var index = self.processes.items.len;
        while (index > 0) {
            index -= 1;
            self.signalIfAttachedWith(
                &self.processes.items[index],
                signal,
                command_session,
                &result,
                Effects,
            );
        }
        if (self.root) |*root| {
            self.signalIfAttachedWith(root, signal, command_session, &result, Effects);
        }
        return result;
    }

    fn signalIfAttachedWith(
        self: *Tracker,
        process: *TrackedProcess,
        signal: std.posix.SIG,
        command_session: std.posix.pid_t,
        result: *CompletionDelivery,
        comptime Effects: type,
    ) void {
        switch (self.completionStandingWith(process.*, command_session, Effects)) {
            .attached => self.signalTrackedProcessWith(
                process,
                signal,
                null,
                &result.delivery,
                Effects,
            ),
            .detached => result.kept_detached += 1,
            .gone => {},
        }
    }

    fn anyAttachedAliveWith(
        self: *Tracker,
        command_session: std.posix.pid_t,
        comptime Effects: type,
    ) bool {
        if (self.root) |root| {
            if (self.completionStandingWith(root, command_session, Effects) == .attached) return true;
        }
        for (self.processes.items) |process| {
            if (self.completionStandingWith(process, command_session, Effects) == .attached) return true;
        }
        return false;
    }

    fn completionStandingWith(
        self: *Tracker,
        process: TrackedProcess,
        command_session: std.posix.pid_t,
        comptime Effects: type,
    ) CompletionStanding {
        const actual = Effects.capture(self.alloc, process.pid) catch |err| switch (err) {
            error.ProcessNotFound => return .gone,
            // An unreadable process stays attached, so cleanup still tries
            // to stop it and reports the failed attempt.
            else => return .attached,
        };
        if (!process.identity.eql(actual.identity) or !snapshotIsAlive(actual)) {
            return .gone;
        }
        return completionStanding(command_session, Effects.session(process.pid));
    }

    fn appendDirectChildren(
        self: *Tracker,
        parent: TrackedProcess,
    ) !void {
        switch (builtin.target.os.tag) {
            .linux => try self.appendLinuxChildren(parent),
            .macos => try self.appendMacOSChildren(parent),
            else => return error.ProcessTreeUnsupported,
        }
    }

    fn appendLinuxChildren(
        self: *Tracker,
        parent: TrackedProcess,
    ) !void {
        if (comptime builtin.target.os.tag != .linux) return error.ProcessTreeUnsupported;
        if (!try self.parentIdentityMatches(parent)) return;
        const task_path = try self.alloc.print(
            "/proc/{d}/task",
            .{parent.pid},
        );
        defer self.alloc.free(task_path);
        var task_dir = (try openLinuxProcDir(task_path)) orelse return;
        defer task_dir.close(io_mod.getIo());
        // The directory was just opened, so skip the rewind that `iterate`
        // does first. gVisor fails that lseek with ENOENT once the process
        // has exited, which would abort the whole scan.
        var tasks = task_dir.iterateAssumeFirstIteration();
        while (try tasks.next(io_mod.getIo())) |entry| {
            const tid = std.fmt.parseInt(
                std.posix.pid_t,
                entry.name,
                10,
            ) catch continue;
            if (tid <= 0) continue;
            try self.appendLinuxTaskChildren(parent, tid);
        }
    }

    fn appendLinuxTaskChildren(
        self: *Tracker,
        parent: TrackedProcess,
        tid: std.posix.pid_t,
    ) !void {
        const path = try self.alloc.print(
            "/proc/{d}/task/{d}/children",
            .{ parent.pid, tid },
        );
        defer self.alloc.free(path);
        var file = (try openLinuxProcFile(path)) orelse return;
        defer file.close(io_mod.getIo());
        var buffer: [64 * 1024]u8 = undefined;
        const read_len = readLinuxChildrenFile(file, &buffer) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        if (!try self.parentIdentityMatches(parent)) return;
        var children = std.mem.tokenizeAny(u8, buffer[0..read_len], " \t\r\n");
        while (children.next()) |pid_text| {
            const pid = std.fmt.parseInt(std.posix.pid_t, pid_text, 10) catch continue;
            try self.trackChild(pid, parent.pid);
        }
    }

    fn appendMacOSChildren(
        self: *Tracker,
        parent: TrackedProcess,
    ) !void {
        if (comptime builtin.target.os.tag != .macos) return error.ProcessTreeUnsupported;
        if (!try self.parentIdentityMatches(parent)) return;
        const count = Darwin.proc_listchildpids(
            parent.pid,
            self.macos_child_buffer.ptr,
            @intCast(self.macos_child_buffer.len * @sizeOf(std.posix.pid_t)),
        );
        if (count <= 0) return;
        const child_count = @min(
            @as(usize, @intCast(count)),
            self.macos_child_buffer.len,
        );
        if (!try self.parentIdentityMatches(parent)) return;
        for (self.macos_child_buffer[0..child_count]) |pid| {
            if (pid > 0) try self.trackChild(pid, parent.pid);
        }
    }

    fn parentIdentityMatches(self: *Tracker, parent: TrackedProcess) !bool {
        const snapshot = captureSnapshot(self.alloc, parent.pid) catch |err| switch (err) {
            error.ProcessNotFound => return false,
            else => return err,
        };
        return parent.identity.eql(snapshot.identity);
    }

    fn trackChild(
        self: *Tracker,
        pid: std.posix.pid_t,
        expected_parent_pid: std.posix.pid_t,
    ) !void {
        const snapshot = captureSnapshot(self.alloc, pid) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        if (!snapshotBelongsToParent(snapshot, expected_parent_pid)) return;
        if (self.root) |root| {
            if (root.pid == pid and root.identity.eql(snapshot.identity)) return;
        }
        for (self.processes.items) |*process| {
            if (process.pid != pid) continue;
            process.identity = snapshot.identity;
            return;
        }
        try self.processes.append(self.alloc, .{
            .pid = pid,
            .identity = snapshot.identity,
        });
    }

    /// Tracks each live process of `session` that this tracker does not track
    /// yet, except the session's leader and this process. Returns how many it
    /// added.
    fn trackSessionWith(
        self: *Tracker,
        session: std.posix.pid_t,
        comptime Effects: type,
    ) !usize {
        var pids: std.ArrayList(std.posix.pid_t) = .empty;
        defer pids.deinit(self.alloc);
        try Effects.list(self.alloc, &pids);
        const own = Effects.ownPid();
        var added: usize = 0;
        next: for (pids.items) |pid| {
            if (pid <= 1 or pid == own or pid == session) continue;
            if (!inSessionWith(pid, session, Effects)) continue;
            const snapshot = Effects.capture(self.alloc, pid) catch |err| {
                if (err == error.OutOfMemory) return err;
                continue;
            };
            // Read after the identity: a process that is alive from this read
            // until its signal is the one this read described, never a later
            // owner of the pid.
            if (!inSessionWith(pid, session, Effects)) continue;
            for (self.processes.items) |*process| {
                if (process.pid != pid) continue;
                if (process.identity.eql(snapshot.identity)) continue :next;
                process.identity = snapshot.identity;
                added += 1;
                continue :next;
            }
            try self.processes.append(self.alloc, .{
                .pid = pid,
                .identity = snapshot.identity,
            });
            added += 1;
        }
        return added;
    }

    fn trackLineageProcess(self: *Tracker, pid: std.posix.pid_t) !bool {
        const snapshot = captureSnapshot(self.alloc, pid) catch return false;
        if (!couldBelongByStart(
            self.macos_root_started_at_us,
            snapshot.started_at_us,
        )) return false;
        const parent_unique_id = snapshot.parent_unique_id orelse return false;
        if (!self.containsMacOSUniqueId(parent_unique_id) and
            !try self.processHasBoundWitness(pid))
        {
            return false;
        }
        if (self.root) |root| {
            if (root.pid == pid and root.identity.eql(snapshot.identity)) return false;
        }
        for (self.processes.items) |*process| {
            if (process.pid != pid) continue;
            if (process.identity.eql(snapshot.identity)) return false;
            process.identity = snapshot.identity;
            return true;
        }
        try self.processes.append(self.alloc, .{
            .pid = pid,
            .identity = snapshot.identity,
        });
        return true;
    }

    fn processHasBoundWitness(self: *Tracker, pid: std.posix.pid_t) !bool {
        if (comptime builtin.target.os.tag != .macos) return false;
        const expected = self.darwin_process_witness orelse return false;
        const fd = self.darwin_process_witness_fd orelse return false;
        const actual = captureDarwinPipeIdentity(pid, fd) catch return false;
        return expected.eql(actual);
    }

    fn containsMacOSUniqueId(self: *Tracker, unique_id: u64) bool {
        if (self.root) |root| {
            if (identityHasMacOSUniqueId(root.identity, unique_id)) return true;
        }
        for (self.processes.items) |process| {
            if (identityHasMacOSUniqueId(process.identity, unique_id)) return true;
        }
        return false;
    }
};

/// How many times `endSession` looks for members after a kill: a member can
/// start another process while the kill runs.
const session_end_passes: usize = 16;

/// Kills every live process whose session is `session`, except the session's
/// leader (the process with that pid, which the caller ends or keeps) and
/// this process. A process that left the session with `setsid` is not in it
/// and is not touched. Members are stopped before any is killed, as
/// `Tracker.signalAll` does, and the session is read again after each kill.
///
/// The caller must own `session`: this process leads it, or holds its
/// leader's identity, since the session id only names the session while a
/// member lives, and a leader that is gone leaves nothing to check it by.
/// A session this process belongs to without leading is refused.
pub fn endSession(alloc: Allocator, session: std.posix.pid_t) !DeliverySummary {
    return endSessionWith(alloc, session, SystemSignalEffects);
}

fn endSessionWith(
    alloc: Allocator,
    session: std.posix.pid_t,
    comptime Effects: type,
) !DeliverySummary {
    var summary: DeliverySummary = .{};
    if (session <= 1) return summary;
    const own = Effects.ownPid();
    if (session != own) switch (Effects.session(own)) {
        .found => |own_session| if (own_session == session) return summary,
        .vanished, .unavailable => {
            summary.incomplete = true;
            return summary;
        },
    };
    var tracker = try Tracker.init(alloc);
    defer tracker.deinit();
    for (0..session_end_passes) |_| {
        if (try tracker.trackSessionWith(session, Effects) == 0) return summary;
        const pass_summary = tracker.signalProcessesWith(std.posix.SIG.KILL, null, Effects);
        summary.delivered += pass_summary.delivered;
        summary.incomplete = summary.incomplete or pass_summary.incomplete;
    }
    // Every pass found a member, so the last kill may have left new ones.
    summary.incomplete = true;
    return summary;
}

/// Whether no live process but the session's leader and this process belongs
/// to `session`. Once that is true, nothing can join the session: a process
/// enters a session only by being started by a member. A zombie member counts
/// as gone, and a member whose session cannot be read counts as alive. A
/// process list is not a snapshot: a member can start a process that a list
/// already read past and then exit before the list reaches it. So the list is
/// read twice, and both reads must find no member.
pub fn sessionIsEmpty(alloc: Allocator, session: std.posix.pid_t) !bool {
    return sessionIsEmptyWith(alloc, session, SystemSignalEffects);
}

fn sessionIsEmptyWith(
    alloc: Allocator,
    session: std.posix.pid_t,
    comptime Effects: type,
) !bool {
    if (session <= 1) return false;
    for (0..2) |_| {
        if (try sessionHasLiveMemberWith(alloc, session, Effects)) return false;
    }
    return true;
}

fn sessionHasLiveMemberWith(
    alloc: Allocator,
    session: std.posix.pid_t,
    comptime Effects: type,
) !bool {
    var pids: std.ArrayList(std.posix.pid_t) = .empty;
    defer pids.deinit(alloc);
    try Effects.list(alloc, &pids);
    const own = Effects.ownPid();
    for (pids.items) |pid| {
        if (pid <= 1 or pid == own or pid == session) continue;
        switch (Effects.session(pid)) {
            .found => |value| if (value != session) continue,
            .vanished => continue,
            .unavailable => return true,
        }
        const snapshot = Effects.capture(alloc, pid) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (err == error.ProcessNotFound) continue;
            return true;
        };
        if (!snapshot.zombie) return true;
    }
    return false;
}

fn inSessionWith(
    pid: std.posix.pid_t,
    session: std.posix.pid_t,
    comptime Effects: type,
) bool {
    return switch (Effects.session(pid)) {
        .found => |value| value == session,
        .vanished, .unavailable => false,
    };
}

fn identityHasMacOSUniqueId(identity: Identity, unique_id: u64) bool {
    return switch (identity) {
        .macos_unique_id => |actual| actual == unique_id,
        else => false,
    };
}

fn setCloseOnExec(fd: std.posix.fd_t) !void {
    while (true) switch (std.posix.errno(std.posix.system.fcntl(
        fd,
        std.posix.F.SETFD,
        @as(usize, std.posix.FD_CLOEXEC),
    ))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.FileControlFailed,
    };
}

fn closeFd(fd: std.posix.fd_t) void {
    switch (std.posix.errno(std.posix.system.close(fd))) {
        .SUCCESS, .INTR => {},
        else => {},
    }
}

fn captureDarwinPipeIdentity(
    pid: std.posix.pid_t,
    fd: std.posix.fd_t,
) !DarwinPipeIdentity {
    if (comptime builtin.target.os.tag != .macos) return error.ProcessTreeUnsupported;
    var info: Darwin.PipeFdInfo = undefined;
    const read_len = Darwin.proc_pidfdinfo(
        pid,
        fd,
        Darwin.proc_pid_fd_pipe_info,
        &info,
        @sizeOf(Darwin.PipeFdInfo),
    );
    if (read_len == 0) return error.ProcessNotFound;
    if (read_len != @sizeOf(Darwin.PipeFdInfo)) {
        return error.ProcessIdentityUnavailable;
    }
    return .{
        .handle = info.pipeinfo.pipe_handle,
        .peer_handle = info.pipeinfo.pipe_peerhandle,
    };
}

fn couldBelongByStart(root_started_at_us: ?u64, candidate_started_at_us: ?u64) bool {
    const root = root_started_at_us orelse return true;
    const candidate = candidate_started_at_us orelse return false;
    return candidate >= root;
}

fn darwinStartTimeUs(seconds: u64, microseconds: u64) u64 {
    const scaled = @mulWithOverflow(seconds, @as(u64, std.time.us_per_s));
    if (scaled[1] != 0) return std.math.maxInt(u64);
    const total = @addWithOverflow(scaled[0], microseconds);
    return if (total[1] == 0) total[0] else std.math.maxInt(u64);
}

fn shouldTraverseParent(expected: Identity, actual: Identity) bool {
    return expected.eql(actual);
}

fn snapshotBelongsToParent(
    snapshot: ProcessSnapshot,
    expected_parent_pid: std.posix.pid_t,
) bool {
    return snapshot.parent_pid == expected_parent_pid;
}

fn shouldSignalProcess(
    process_group: ?std.posix.pid_t,
    preserved_group: ?std.posix.pid_t,
) bool {
    const preserved = preserved_group orelse return true;
    const actual = process_group orelse return false;
    return actual != preserved;
}

fn inspectProcessGroup(pid: std.posix.pid_t) ProcessGroupState {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return .unavailable;
    }
    const process_group = getpgid(pid);
    if (process_group >= 0) return .{ .found = process_group };
    return switch (std.c.errno(process_group)) {
        .SRCH => .vanished,
        else => .unavailable,
    };
}

extern "c" fn getpgid(pid: std.posix.pid_t) std.posix.pid_t;

fn inspectSession(pid: std.posix.pid_t) SessionState {
    if (comptime builtin.target.os.tag == .windows or builtin.target.os.tag == .wasi) {
        return .unavailable;
    }
    const session = getsid(pid);
    if (session >= 0) return .{ .found = session };
    return switch (std.c.errno(session)) {
        .SRCH => .vanished,
        else => .unavailable,
    };
}

extern "c" fn getsid(pid: std.posix.pid_t) std.posix.pid_t;

fn readLinuxChildrenFile(file: std.Io.File, buffer: []u8) !usize {
    if (comptime builtin.target.os.tag != .linux) return error.ProcessTreeUnsupported;
    while (true) {
        const result = std.posix.system.read(file.handle, buffer.ptr, buffer.len);
        switch (std.posix.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .SRCH, .NOENT => return error.ProcessNotFound,
            else => return error.ProcessTreeInspectionFailed,
        }
    }
}

fn openLinuxProcDir(path: []const u8) !?std.Io.Dir {
    if (comptime builtin.target.os.tag != .linux) return error.ProcessTreeUnsupported;
    // A process can disappear between identity validation and opening its
    // procfs entry. The POSIX wrapper maps Linux's ESRCH to FileNotFound;
    // std.Io currently treats ESRCH from directory opens as unexpected.
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return .{ .handle = fd };
}

fn openLinuxProcFile(path: []const u8) !?std.Io.File {
    if (comptime builtin.target.os.tag != .linux) return error.ProcessTreeUnsupported;
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return .{
        .handle = fd,
        .flags = .{ .nonblocking = false },
    };
}

/// Appends the pid of every process the OS lists, in no particular order.
/// A process can start or end while the list is read.
fn listProcessIds(alloc: Allocator, out: *std.ArrayList(std.posix.pid_t)) !void {
    switch (builtin.target.os.tag) {
        .linux => try listLinuxProcessIds(alloc, out),
        .macos => try listMacOSProcessIds(alloc, out),
        else => return error.ProcessTreeUnsupported,
    }
}

fn listLinuxProcessIds(alloc: Allocator, out: *std.ArrayList(std.posix.pid_t)) !void {
    if (comptime builtin.target.os.tag != .linux) return error.ProcessTreeUnsupported;
    var proc_dir = (try openLinuxProcDir("/proc")) orelse
        return error.ProcessTreeInspectionFailed;
    defer proc_dir.close(io_mod.getIo());
    var entries = proc_dir.iterateAssumeFirstIteration();
    while (try entries.next(io_mod.getIo())) |entry| {
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        if (pid > 0) try out.append(alloc, pid);
    }
}

fn listMacOSProcessIds(alloc: Allocator, out: *std.ArrayList(std.posix.pid_t)) !void {
    if (comptime builtin.target.os.tag != .macos) return error.ProcessTreeUnsupported;
    const reported = Darwin.proc_listallpids(null, 0);
    if (reported <= 0) return error.ProcessTreeInspectionFailed;
    const buffer = try alloc.alloc(std.posix.pid_t, @as(usize, @intCast(reported)) + 256);
    defer alloc.free(buffer);
    const count = Darwin.proc_listallpids(
        buffer.ptr,
        @intCast(buffer.len * @sizeOf(std.posix.pid_t)),
    );
    if (count <= 0) return error.ProcessTreeInspectionFailed;
    for (buffer[0..@min(@as(usize, @intCast(count)), buffer.len)]) |pid| {
        if (pid > 0) try out.append(alloc, pid);
    }
}

/// True when `pid` has exited, its parent has not collected it yet, and it
/// started at the time the macOS identity token `token` names. The lookup that
/// makes those tokens does not see an exited process that is still waiting to
/// be collected, so its owner would take it for gone; this one does. It is
/// false everywhere else, where the identity check sees such a process.
pub fn exitedUncollectedSince(pid: std.posix.pid_t, token: process_identity.ProcessInstanceToken) bool {
    if (comptime builtin.target.os.tag != .macos) return false;
    const start = token.macos_start orelse return false;
    var info: Darwin.ProcBsdInfo = undefined;
    // The last argument asks for exited processes as well.
    const read_len = Darwin.proc_pidinfo(pid, 3, 1, &info, @sizeOf(Darwin.ProcBsdInfo));
    if (read_len != @sizeOf(Darwin.ProcBsdInfo)) return false;
    return info.pbi_status == Darwin.process_status_zombie and
        info.pbi_start_tvsec == start.seconds and
        info.pbi_start_tvusec == start.microseconds;
}

test "an exited child that is not collected yet is found by its start time" {
    if (builtin.target.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // `cat` ends when its input does.
    var child = try std.process.spawn(io, .{
        .argv = &.{"cat"},
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);
    const pid = child.id.?;
    const started_us = (try captureSnapshot(alloc, pid)).started_at_us orelse return error.TestNoStartTime;
    const token = try testMacOSToken(started_us);
    const other_start = try testMacOSToken(started_us + 1);
    try std.testing.expect(!exitedUncollectedSince(pid, token));

    child.stdin.?.close(io);
    child.stdin = null;
    _ = try waitUntilExitedUncollected(pid);
    try std.testing.expect(exitedUncollectedSince(pid, token));
    try std.testing.expect(!exitedUncollectedSince(pid, other_start));

    _ = try child.wait(io);
    try std.testing.expect(!exitedUncollectedSince(pid, token));
}

/// A macOS token for a process that started `started_us` microseconds after the epoch.
fn testMacOSToken(started_us: u64) !process_identity.ProcessInstanceToken {
    var buffer: [128]u8 = undefined;
    return process_identity.ProcessInstanceToken.parse(try std.mem.print(
        &buffer,
        "macos:00112233445566778899aabbccddeeff:{d}:{d}",
        .{ started_us / std.time.us_per_s, started_us % std.time.us_per_s },
    ));
}

/// How a child of this process ended.
pub const ChildEnd = union(enum) {
    exited: u8,
    /// Killed by a signal, whether or not it dumped core: the signal's number.
    signaled: u32,
};

extern "c" fn waitid(id_type: c_uint, id: c_uint, info: *std.c.siginfo_t, options: c_int) c_int;

const wait_for_pid: c_uint = 1; // P_PID
const wait_no_hang: c_int = 0x1; // WNOHANG
const wait_exited: c_int = 0x4; // WEXITED
/// WNOWAIT: report the child and leave it uncollected.
const wait_leave_waitable: c_int = if (builtin.target.os.tag == .linux) 0x1000000 else 0x20;
const child_exited_code: i32 = 1; // CLD_EXITED

/// Blocks until `pid`, a child of this process, has ended, and tells how. The
/// child stays uncollected: it remains a process table entry, so its pid, its
/// process group id and its session id stay reserved for it until the owner
/// collects it with `std.process.Child.wait`. Only that call may collect it.
pub fn waitUntilExitedUncollected(pid: std.posix.pid_t) !ChildEnd {
    if (comptime builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) {
        return error.ProcessTreeUnsupported;
    }
    var info: std.c.siginfo_t = undefined;
    @memset(std.mem.asBytes(&info), 0);
    while (true) {
        const result = waitid(wait_for_pid, @intCast(pid), &info, wait_exited | wait_leave_waitable);
        switch (std.c.errno(result)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.WaitForChildFailed,
        }
    }
    const status: u32 = @bitCast(switch (builtin.target.os.tag) {
        .linux => info.fields.common.second.sigchld.status,
        else => info.status,
    });
    if (info.code == child_exited_code) return .{ .exited = @truncate(status) };
    return .{ .signaled = status };
}

/// Whether `pid` is a child of this process that has ended and is not
/// collected yet. It collects nothing.
pub fn exitedChildIsUncollected(pid: std.posix.pid_t) bool {
    if (comptime builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return false;
    var info: std.c.siginfo_t = undefined;
    @memset(std.mem.asBytes(&info), 0);
    const result = waitid(
        wait_for_pid,
        @intCast(pid),
        &info,
        wait_exited | wait_leave_waitable | wait_no_hang,
    );
    if (result != 0) return false;
    const reported = switch (builtin.target.os.tag) {
        .linux => info.fields.common.first.piduid.pid,
        else => info.pid,
    };
    return reported == pid;
}

test "Linux proc helpers treat missing process data as vanished" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expect(
        (try openLinuxProcDir("/proc/self/fx-process-tree-missing")) == null,
    );
    try std.testing.expect(
        (try openLinuxProcFile("/proc/self/fx-process-tree-missing")) == null,
    );
}

test "process-group exclusion preserves the captured command grace" {
    try std.testing.expect(shouldSignalProcess(41, null));
    try std.testing.expect(!shouldSignalProcess(41, 41));
    try std.testing.expect(shouldSignalProcess(42, 41));
    try std.testing.expect(!shouldSignalProcess(null, 41));
}

test "stale process identities cannot become traversal roots" {
    try std.testing.expect(shouldTraverseParent(
        .{ .linux_start_ticks = 41 },
        .{ .linux_start_ticks = 41 },
    ));
    try std.testing.expect(!shouldTraverseParent(
        .{ .linux_start_ticks = 41 },
        .{ .linux_start_ticks = 42 },
    ));
    try std.testing.expect(!shouldTraverseParent(
        .{ .linux_start_ticks = 41 },
        .{ .macos_unique_id = 41 },
    ));
}

test "child admission binds the observed process to its expected parent" {
    const snapshot = ProcessSnapshot{
        .identity = .{ .linux_start_ticks = 42 },
        .parent_pid = 17,
    };
    try std.testing.expect(snapshotBelongsToParent(snapshot, 17));
    try std.testing.expect(!snapshotBelongsToParent(snapshot, 18));
}

test "macOS lineage identity matches only the same unique process" {
    try std.testing.expect(identityHasMacOSUniqueId(
        .{ .macos_unique_id = 42 },
        42,
    ));
    try std.testing.expect(!identityHasMacOSUniqueId(
        .{ .macos_unique_id = 42 },
        43,
    ));
    try std.testing.expect(!identityHasMacOSUniqueId(
        .{ .linux_start_ticks = 42 },
        42,
    ));
}

test "checked signal delivery distinguishes vanished stale and failed targets" {
    const FakeEffects = struct {
        fn capture(_: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
            return switch (pid) {
                11 => error.ProcessNotFound,
                12 => error.ProcessIdentityUnavailable,
                13 => .{
                    .identity = .{ .linux_start_ticks = 113 },
                    .parent_pid = 1,
                },
                else => .{
                    .identity = .{ .linux_start_ticks = @intCast(pid) },
                    .parent_pid = 1,
                },
            };
        }

        fn processGroup(pid: std.posix.pid_t) ProcessGroupState {
            return switch (pid) {
                14 => .vanished,
                15 => .unavailable,
                16 => .{ .found = 41 },
                else => .{ .found = pid + 100 },
            };
        }

        fn send(pid: std.posix.pid_t, _: std.posix.SIG) std.posix.KillError!void {
            return switch (pid) {
                17 => error.PermissionDenied,
                18 => error.ProcessNotFound,
                else => {},
            };
        }
    };

    var tracker = Tracker{ .alloc = std.testing.allocator };
    defer tracker.deinit();
    for (10..19) |pid| {
        try tracker.processes.append(std.testing.allocator, .{
            .pid = @intCast(pid),
            .identity = .{ .linux_start_ticks = pid },
        });
    }

    const summary = tracker.signalProcessesWith(
        std.posix.SIG.TERM,
        41,
        FakeEffects,
    );
    try std.testing.expectEqual(@as(usize, 1), summary.delivered);
    try std.testing.expect(summary.incomplete);
}

test "checked signal delivery keeps vanished stale and excluded targets complete" {
    const FakeEffects = struct {
        fn capture(_: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
            if (pid == 21) return error.ProcessNotFound;
            return .{
                .identity = .{ .linux_start_ticks = if (pid == 22) 122 else @as(u64, @intCast(pid)) },
                .parent_pid = 1,
            };
        }

        fn processGroup(pid: std.posix.pid_t) ProcessGroupState {
            return switch (pid) {
                23 => .vanished,
                else => .{ .found = 41 },
            };
        }

        fn send(_: std.posix.pid_t, _: std.posix.SIG) std.posix.KillError!void {
            return;
        }
    };

    var tracker = Tracker{ .alloc = std.testing.allocator };
    defer tracker.deinit();
    for (21..25) |pid| {
        try tracker.processes.append(std.testing.allocator, .{
            .pid = @intCast(pid),
            .identity = .{ .linux_start_ticks = pid },
        });
    }

    const summary = tracker.signalProcessesWith(
        std.posix.SIG.TERM,
        41,
        FakeEffects,
    );
    try std.testing.expectEqual(@as(usize, 0), summary.delivered);
    try std.testing.expect(!summary.incomplete);
}

test "natural completion detaches only processes that left the command session" {
    const command_session: std.posix.pid_t = 500;
    try std.testing.expectEqual(
        CompletionStanding.attached,
        completionStanding(command_session, .{ .found = command_session }),
    );
    try std.testing.expectEqual(
        CompletionStanding.detached,
        completionStanding(command_session, .{ .found = 700 }),
    );
    try std.testing.expectEqual(
        CompletionStanding.attached,
        completionStanding(command_session, .unavailable),
    );
    try std.testing.expectEqual(
        CompletionStanding.gone,
        completionStanding(command_session, .vanished),
    );
}

test "natural completion stops attached processes and keeps detached daemons" {
    const FakeEffects = struct {
        var pids: [16]std.posix.pid_t = undefined;
        var signals: [16]std.posix.SIG = undefined;
        var sent_count: usize = 0;

        fn capture(_: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
            return switch (pid) {
                35 => .{ .identity = .{ .linux_start_ticks = 999 }, .parent_pid = 1 },
                36 => .{
                    .identity = .{ .linux_start_ticks = 36 },
                    .parent_pid = 1,
                    .zombie = true,
                },
                else => .{
                    .identity = .{ .linux_start_ticks = @intCast(pid) },
                    .parent_pid = 1,
                },
            };
        }

        fn processGroup(pid: std.posix.pid_t) ProcessGroupState {
            return .{ .found = pid };
        }

        fn session(pid: std.posix.pid_t) SessionState {
            return switch (pid) {
                30, 32 => .{ .found = 500 },
                34 => .vanished,
                37 => .unavailable,
                else => .{ .found = pid },
            };
        }

        fn send(pid: std.posix.pid_t, signal: std.posix.SIG) std.posix.KillError!void {
            pids[sent_count] = pid;
            signals[sent_count] = signal;
            sent_count += 1;
        }
    };

    var tracker = Tracker{ .alloc = std.testing.allocator };
    defer tracker.deinit();
    for (30..38) |pid| {
        try tracker.processes.append(std.testing.allocator, .{
            .pid = @intCast(pid),
            .identity = .{ .linux_start_ticks = pid },
        });
    }

    FakeEffects.sent_count = 0;
    const completed = tracker.signalAttachedWith(std.posix.SIG.KILL, 500, FakeEffects);
    // The attached processes stop and then die. The daemons 31 and 33 get
    // no signal at all, not even the stop.
    const stop = std.posix.SIG.STOP;
    const kill = std.posix.SIG.KILL;
    try std.testing.expectEqualSlices(
        std.posix.pid_t,
        &.{ 30, 32, 37, 37, 32, 30 },
        FakeEffects.pids[0..FakeEffects.sent_count],
    );
    try std.testing.expectEqualSlices(
        std.posix.SIG,
        &.{ stop, stop, stop, kill, kill, kill },
        FakeEffects.signals[0..FakeEffects.sent_count],
    );
    try std.testing.expectEqual(@as(usize, 3), completed.delivery.delivered);
    try std.testing.expectEqual(@as(usize, 2), completed.kept_detached);
    try std.testing.expect(tracker.anyAttachedAliveWith(500, FakeEffects));

    var daemons_only = Tracker{ .alloc = std.testing.allocator };
    defer daemons_only.deinit();
    for ([_]std.posix.pid_t{ 31, 33 }) |pid| {
        try daemons_only.processes.append(std.testing.allocator, .{
            .pid = pid,
            .identity = .{ .linux_start_ticks = @intCast(pid) },
        });
    }
    try std.testing.expect(!daemons_only.anyAttachedAliveWith(500, FakeEffects));
}

test "a kill stops every tracked process before killing any" {
    const FakeEffects = struct {
        var pids: [16]std.posix.pid_t = undefined;
        var signals: [16]std.posix.SIG = undefined;
        var sent_count: usize = 0;

        fn capture(_: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
            return .{ .identity = .{ .linux_start_ticks = @intCast(pid) }, .parent_pid = 1 };
        }

        fn processGroup(pid: std.posix.pid_t) ProcessGroupState {
            return .{ .found = pid };
        }

        fn session(_: std.posix.pid_t) SessionState {
            return .{ .found = 500 };
        }

        fn send(pid: std.posix.pid_t, signal: std.posix.SIG) std.posix.KillError!void {
            pids[sent_count] = pid;
            signals[sent_count] = signal;
            sent_count += 1;
        }

        fn expectSent(expected_pids: []const std.posix.pid_t, expected_signals: []const std.posix.SIG) !void {
            try std.testing.expectEqualSlices(std.posix.pid_t, expected_pids, pids[0..sent_count]);
            for (expected_signals, signals[0..sent_count]) |expected, actual| {
                try std.testing.expectEqual(expected, actual);
            }
        }
    };

    // The root 60 runs 61, which runs 62, as a shell runs `sleep 30; rm -rf out`.
    var tracker = Tracker{
        .alloc = std.testing.allocator,
        .root = .{ .pid = 60, .identity = .{ .linux_start_ticks = 60 } },
    };
    defer tracker.deinit();
    for ([_]std.posix.pid_t{ 61, 62 }) |pid| {
        try tracker.processes.append(std.testing.allocator, .{
            .pid = pid,
            .identity = .{ .linux_start_ticks = @intCast(pid) },
        });
    }
    const stop = std.posix.SIG.STOP;
    const kill = std.posix.SIG.KILL;
    // Parents stop first, so none is running to see a child stop or die.
    const pids = [_]std.posix.pid_t{ 60, 61, 62, 62, 61, 60 };
    const signals = [_]std.posix.SIG{ stop, stop, stop, kill, kill, kill };

    FakeEffects.sent_count = 0;
    const summary = tracker.signalProcessesWith(kill, null, FakeEffects);
    try FakeEffects.expectSent(&pids, &signals);
    try std.testing.expectEqual(@as(usize, 3), summary.delivered);

    FakeEffects.sent_count = 0;
    const completed = tracker.signalAttachedWith(kill, 500, FakeEffects);
    try FakeEffects.expectSent(&pids, &signals);
    try std.testing.expectEqual(@as(usize, 3), completed.delivery.delivered);

    // Other signals go out once.
    FakeEffects.sent_count = 0;
    _ = tracker.signalProcessesWith(std.posix.SIG.TERM, null, FakeEffects);
    try std.testing.expectEqual(@as(usize, 3), FakeEffects.sent_count);
}

test "a stopped child, an exited child, and a gone pid count as stopped, and a running one does not" {
    if (comptime builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var running = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "30" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    const pid = running.id.?;
    try std.testing.expect(!try processIsStopped(alloc, pid));
    try std.posix.kill(pid, .STOP);
    // The stop lands a moment after kill(2) returns.
    const stopped = for (0..1_000) |_| {
        if (try processIsStopped(alloc, pid)) break true;
        io_mod.sleep(std.time.ns_per_ms);
    } else false;
    try std.testing.expect(stopped);
    try std.posix.kill(pid, .KILL);
    // Killed and not yet reaped, it has exited.
    const exited = for (0..1_000) |_| {
        if (!try processIsAlive(alloc, pid)) break true;
        io_mod.sleep(std.time.ns_per_ms);
    } else false;
    try std.testing.expect(exited);
    try std.testing.expect(try processIsStopped(alloc, pid));
    _ = try running.wait(io);
    try std.testing.expect(try processIsStopped(alloc, pid));
}

test "a kill resumes the processes it stopped but did not kill" {
    const FakeEffects = struct {
        var session_reads: usize = 0;
        var group_reads: usize = 0;
        var pids: [8]std.posix.pid_t = undefined;
        var signals: [8]std.posix.SIG = undefined;
        var sent_count: usize = 0;

        fn capture(_: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
            return .{ .identity = .{ .linux_start_ticks = @intCast(pid) }, .parent_pid = 1 };
        }

        // 71 joins process group 700 just after the stop pass reads its
        // group. 72 is always in it.
        fn processGroup(pid: std.posix.pid_t) ProcessGroupState {
            switch (pid) {
                71 => {
                    group_reads += 1;
                    return .{ .found = if (group_reads == 1) 71 else 700 };
                },
                72 => return .{ .found = 700 },
                else => return .{ .found = pid },
            }
        }

        // 71 calls setsid() just after the stop pass reads its session.
        fn session(pid: std.posix.pid_t) SessionState {
            if (pid != 71) return .{ .found = 500 };
            session_reads += 1;
            return .{ .found = if (session_reads == 1) 500 else 71 };
        }

        fn send(pid: std.posix.pid_t, signal: std.posix.SIG) std.posix.KillError!void {
            pids[sent_count] = pid;
            signals[sent_count] = signal;
            sent_count += 1;
        }

        fn reset() void {
            session_reads = 0;
            group_reads = 0;
            sent_count = 0;
        }

        fn expectSent(expected_pids: []const std.posix.pid_t, expected_signals: []const std.posix.SIG) !void {
            try std.testing.expectEqualSlices(std.posix.pid_t, expected_pids, pids[0..sent_count]);
            try std.testing.expectEqualSlices(std.posix.SIG, expected_signals, signals[0..sent_count]);
        }
    };

    // The root 70 runs 71.
    var tracker = Tracker{
        .alloc = std.testing.allocator,
        .root = .{ .pid = 70, .identity = .{ .linux_start_ticks = 70 } },
    };
    defer tracker.deinit();
    try tracker.processes.append(std.testing.allocator, .{
        .pid = 71,
        .identity = .{ .linux_start_ticks = 71 },
    });
    const stop = std.posix.SIG.STOP;
    const kill = std.posix.SIG.KILL;
    const cont = std.posix.SIG.CONT;
    // 71 stops, then the kill skips it, so it is resumed instead of being
    // left stopped.
    const pids = [_]std.posix.pid_t{ 70, 71, 70, 71 };
    const signals = [_]std.posix.SIG{ stop, stop, kill, cont };

    // A forced kill that spares process group 700.
    FakeEffects.reset();
    const summary = tracker.signalProcessesWith(kill, 700, FakeEffects);
    try FakeEffects.expectSent(&pids, &signals);
    try std.testing.expectEqual(@as(usize, 1), summary.delivered);

    // Natural-completion cleanup, which keeps 71 running as a daemon once
    // it has left the command's session.
    FakeEffects.reset();
    const completed = tracker.signalAttachedWith(kill, 500, FakeEffects);
    try FakeEffects.expectSent(&pids, &signals);
    try std.testing.expectEqual(@as(usize, 1), completed.delivery.delivered);
    try std.testing.expectEqual(@as(usize, 1), completed.kept_detached);

    // `stopAll` stops 72, the caller's own kill of group 700 misses it, and
    // the kill of everything outside that group resumes it.
    var grouped = Tracker{ .alloc = std.testing.allocator };
    defer grouped.deinit();
    try grouped.processes.append(std.testing.allocator, .{
        .pid = 72,
        .identity = .{ .linux_start_ticks = 72 },
    });
    FakeEffects.reset();
    grouped.stopProcessesWith(null, FakeEffects);
    _ = grouped.signalProcessesWith(kill, 700, FakeEffects);
    try FakeEffects.expectSent(&.{ 72, 72 }, &.{ stop, cont });
}

test "natural completion keeps an unreadable process attached and reports it" {
    const FakeEffects = struct {
        var sent_count: usize = 0;

        fn capture(
            _: Allocator,
            _: std.posix.pid_t,
        ) error{ ProcessNotFound, ProcessIdentityUnavailable }!ProcessSnapshot {
            return error.ProcessIdentityUnavailable;
        }

        fn processGroup(pid: std.posix.pid_t) ProcessGroupState {
            return .{ .found = pid };
        }

        fn session(pid: std.posix.pid_t) SessionState {
            return .{ .found = pid };
        }

        fn send(_: std.posix.pid_t, _: std.posix.SIG) std.posix.KillError!void {
            sent_count += 1;
        }
    };

    var tracker = Tracker{ .alloc = std.testing.allocator };
    defer tracker.deinit();
    try tracker.processes.append(std.testing.allocator, .{
        .pid = 40,
        .identity = .{ .linux_start_ticks = 40 },
    });

    FakeEffects.sent_count = 0;
    const completed = tracker.signalAttachedWith(std.posix.SIG.KILL, 500, FakeEffects);
    // Without a snapshot the process cannot be signaled safely, but it is
    // neither kept as a daemon nor treated as gone.
    try std.testing.expectEqual(@as(usize, 0), FakeEffects.sent_count);
    try std.testing.expectEqual(@as(usize, 0), completed.delivery.delivered);
    try std.testing.expectEqual(@as(usize, 0), completed.kept_detached);
    try std.testing.expect(completed.delivery.incomplete);
    try std.testing.expect(tracker.anyAttachedAliveWith(500, FakeEffects));
}

test "session inspection separates the caller's session from a new one" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;

    const io = std.testing.io;
    const own_session = switch (inspectSession(0)) {
        .found => |session| session,
        .vanished, .unavailable => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        SessionState{ .found = own_session },
        inspectSession(std.c.getpid()),
    );

    var detached = try std.process.spawn(io, .{
        .argv = &.{ "python3", "-c", "import os,sys,time; os.setsid(); sys.stdout.write('R'); sys.stdout.flush(); time.sleep(5)" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer detached.kill(io);
    var ready: [1]u8 = undefined;
    const ready_len = try detached.stdout.?.readStreaming(io, &.{&ready});
    try std.testing.expectEqual(@as(usize, 1), ready_len);

    const pid = detached.id.?;
    try std.testing.expectEqual(SessionState{ .found = pid }, inspectSession(pid));
    try std.testing.expectEqual(
        CompletionStanding.detached,
        completionStanding(own_session, inspectSession(pid)),
    );
}

/// A fake process table for `endSessionWith`. A kill removes the process.
const FakeSessionTable = struct {
    const Entry = struct {
        pid: std.posix.pid_t,
        session: std.posix.pid_t,
        zombie: bool = false,
    };

    var entries: [64]Entry = undefined;
    var count: usize = 0;
    var own_pid: std.posix.pid_t = 100;
    var own_session: SessionState = .{ .found = 90 };
    var killed: [64]std.posix.pid_t = undefined;
    var killed_count: usize = 0;
    var stopped_count: usize = 0;
    var list_calls: usize = 0;
    /// The next `forks_left` kills each start a process in `fork_into`, as a
    /// member that forks while it dies.
    var fork_into: std.posix.pid_t = 0;
    var forks_left: usize = 0;
    var next_pid: std.posix.pid_t = 400;
    /// The pid is taken over by a process of another session after its identity is read once.
    var reused_pid: ?std.posix.pid_t = null;
    var reused_reads: usize = 0;
    /// The pid is taken over right after its session is read once, so the identity read next is already the new process's.
    var swapped_pid: ?std.posix.pid_t = null;
    var swapped_reads: usize = 0;
    /// The session of this pid cannot be read.
    var unreadable_pid: ?std.posix.pid_t = null;
    /// A process of `late_member_session` that exists only once the
    /// `late_member_after_list`th list has been returned, as one that starts
    /// while the list is read.
    var late_member_pid: std.posix.pid_t = 0;
    var late_member_session: std.posix.pid_t = 0;
    var late_member_after_list: usize = 0;

    fn reset() void {
        count = 0;
        own_pid = 100;
        own_session = .{ .found = 90 };
        killed_count = 0;
        stopped_count = 0;
        list_calls = 0;
        forks_left = 0;
        next_pid = 400;
        reused_pid = null;
        reused_reads = 0;
        swapped_pid = null;
        swapped_reads = 0;
        unreadable_pid = null;
        late_member_after_list = 0;
    }

    fn add(pid: std.posix.pid_t, session_id: std.posix.pid_t, zombie: bool) void {
        entries[count] = .{ .pid = pid, .session = session_id, .zombie = zombie };
        count += 1;
    }

    fn find(pid: std.posix.pid_t) ?usize {
        for (entries[0..count], 0..) |entry, index| {
            if (entry.pid == pid) return index;
        }
        return null;
    }

    fn expectKilled(expected: []const std.posix.pid_t) !void {
        var sorted: [64]std.posix.pid_t = undefined;
        @memcpy(sorted[0..killed_count], killed[0..killed_count]);
        std.mem.sort(std.posix.pid_t, sorted[0..killed_count], {}, std.sort.asc(std.posix.pid_t));
        try std.testing.expectEqualSlices(std.posix.pid_t, expected, sorted[0..killed_count]);
    }

    fn ownPid() std.posix.pid_t {
        return own_pid;
    }

    fn list(alloc: Allocator, out: *std.ArrayList(std.posix.pid_t)) !void {
        list_calls += 1;
        for (entries[0..count]) |entry| try out.append(alloc, entry.pid);
        if (list_calls == late_member_after_list) add(late_member_pid, late_member_session, false);
    }

    fn session(pid: std.posix.pid_t) SessionState {
        if (pid == own_pid) return own_session;
        const index = find(pid) orelse return .vanished;
        if (unreadable_pid == pid) return .unavailable;
        if (reused_pid == pid and reused_reads > 1) return .{ .found = 999 };
        if (swapped_pid == pid) {
            swapped_reads += 1;
            if (swapped_reads > 1) return .{ .found = 999 };
        }
        return .{ .found = entries[index].session };
    }

    fn capture(_: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
        const index = find(pid) orelse return error.ProcessNotFound;
        var ticks: u64 = @intCast(pid);
        if (reused_pid == pid) {
            reused_reads += 1;
            if (reused_reads > 1) ticks += 1000;
        }
        if (swapped_pid == pid and swapped_reads > 0) ticks += 1000;
        return .{
            .identity = .{ .linux_start_ticks = ticks },
            .parent_pid = 1,
            .zombie = entries[index].zombie,
        };
    }

    fn processGroup(pid: std.posix.pid_t) ProcessGroupState {
        return .{ .found = pid };
    }

    fn send(pid: std.posix.pid_t, signal: std.posix.SIG) std.posix.KillError!void {
        const index = find(pid) orelse return error.ProcessNotFound;
        if (signal == std.posix.SIG.STOP) stopped_count += 1;
        if (signal != std.posix.SIG.KILL) return;
        killed[killed_count] = pid;
        killed_count += 1;
        entries[index] = entries[count - 1];
        count -= 1;
        if (forks_left > 0) {
            forks_left -= 1;
            add(next_pid, fork_into, false);
            next_pid += 1;
        }
    }
};

test "ending a session kills its members and nothing else" {
    const table = FakeSessionTable;
    table.reset();
    // The leader 200 and its members 201 and 202 share a session. Another
    // session, a member that is already a zombie, init, and this process
    // (100, in the session of pid 90) do not count.
    table.add(1, 200, false);
    table.add(100, 200, false);
    table.add(200, 200, false);
    table.add(201, 200, false);
    table.add(202, 200, false);
    table.add(203, 200, true);
    table.add(300, 300, false);
    table.add(301, 90, false);

    const summary = try endSessionWith(std.testing.allocator, 200, table);
    try table.expectKilled(&.{ 201, 202 });
    try std.testing.expectEqual(@as(usize, 2), summary.delivered);
    try std.testing.expect(!summary.incomplete);
    // Both were stopped before either was killed.
    try std.testing.expectEqual(@as(usize, 2), table.stopped_count);
}

test "ending a session looks again for a member that starts while the kill runs" {
    const table = FakeSessionTable;
    table.reset();
    table.add(200, 200, false);
    table.add(201, 200, false);
    table.add(300, 300, false);
    // The kill of 201 starts 400, which the next pass finds.
    table.fork_into = 200;
    table.forks_left = 1;

    const summary = try endSessionWith(std.testing.allocator, 200, table);
    try std.testing.expectEqualSlices(std.posix.pid_t, &.{ 201, 400 }, table.killed[0..table.killed_count]);
    try std.testing.expectEqual(@as(usize, 2), summary.delivered);
    // Two passes that killed, and a third that found the session empty.
    try std.testing.expectEqual(@as(usize, 3), table.list_calls);
    try std.testing.expect(!summary.incomplete);
}

test "ending a session stops looking after a bounded number of passes" {
    const table = FakeSessionTable;
    table.reset();
    table.add(200, 200, false);
    table.add(201, 200, false);
    table.fork_into = 200;
    table.forks_left = 1000;

    const summary = try endSessionWith(std.testing.allocator, 200, table);
    // Every kill started another member, and the loop still ended.
    try std.testing.expectEqual(session_end_passes, table.list_calls);
    try std.testing.expectEqual(session_end_passes, table.killed_count);
    // No pass found the session empty, so the result says it may not be.
    try std.testing.expect(summary.incomplete);
}

test "ending a session refuses the session this process belongs to unless it leads it" {
    const table = FakeSessionTable;
    table.reset();
    table.own_session = .{ .found = 200 };
    table.add(200, 200, false);
    table.add(201, 200, false);
    table.add(202, 200, false);

    const refused = try endSessionWith(std.testing.allocator, 200, table);
    try std.testing.expectEqual(@as(usize, 0), table.killed_count);
    try std.testing.expectEqual(@as(usize, 0), refused.delivered);

    // An unreadable own session refuses as well, and says it is incomplete.
    table.own_session = .unavailable;
    const unknown = try endSessionWith(std.testing.allocator, 200, table);
    try std.testing.expectEqual(@as(usize, 0), table.killed_count);
    try std.testing.expect(unknown.incomplete);

    // A process that leads the session may end it: the launcher ends its own.
    table.own_pid = 200;
    table.own_session = .{ .found = 200 };
    _ = try endSessionWith(std.testing.allocator, 200, table);
    try table.expectKilled(&.{ 201, 202 });

    // Init's session and a negative id are never a session to end.
    table.reset();
    table.add(2, 1, false);
    _ = try endSessionWith(std.testing.allocator, 1, table);
    _ = try endSessionWith(std.testing.allocator, 0, table);
    _ = try endSessionWith(std.testing.allocator, -1, table);
    try std.testing.expectEqual(@as(usize, 0), table.killed_count);
}

test "ending a session never signals a pid that another process took over after it was read" {
    const table = FakeSessionTable;
    table.reset();
    table.add(200, 200, false);
    table.add(201, 200, false);
    table.add(202, 200, false);
    table.add(203, 200, false);
    // 201 changes owner after its identity was read, and 203 before it: the
    // second read of the session and the identity at the signal catch each.
    table.reused_pid = 201;
    table.swapped_pid = 203;

    const summary = try endSessionWith(std.testing.allocator, 200, table);
    try table.expectKilled(&.{202});
    try std.testing.expectEqual(@as(usize, 1), summary.delivered);
}

test "a session is empty only when no live member is left" {
    const table = FakeSessionTable;
    table.reset();
    // The leader, this process, init, a process of another session and a
    // member that is a zombie do not count.
    table.add(1, 200, false);
    table.add(100, 200, false);
    table.add(200, 200, false);
    table.add(203, 200, true);
    table.add(300, 300, false);
    try std.testing.expect(try sessionIsEmptyWith(std.testing.allocator, 200, table));

    table.add(201, 200, false);
    try std.testing.expect(!try sessionIsEmptyWith(std.testing.allocator, 200, table));

    // Init's session and a negative id are never empty, and nothing is signalled.
    try std.testing.expect(!try sessionIsEmptyWith(std.testing.allocator, 1, table));
    try std.testing.expect(!try sessionIsEmptyWith(std.testing.allocator, 0, table));
    try std.testing.expect(!try sessionIsEmptyWith(std.testing.allocator, -1, table));
    try std.testing.expectEqual(@as(usize, 0), table.killed_count);
}

test "a session with a member whose session cannot be read is not empty" {
    const table = FakeSessionTable;
    table.reset();
    table.add(200, 200, false);
    table.add(201, 200, false);
    table.unreadable_pid = 201;
    try std.testing.expect(!try sessionIsEmptyWith(std.testing.allocator, 200, table));
    // Without the unreadable member the same table is empty.
    table.unreadable_pid = null;
    table.entries[1].session = 300;
    try std.testing.expect(try sessionIsEmptyWith(std.testing.allocator, 200, table));
}

test "a session is read twice before it counts as empty" {
    const table = FakeSessionTable;
    table.reset();
    table.add(200, 200, false);
    // A member that starts while the first list is read is not in that list.
    table.late_member_pid = 401;
    table.late_member_session = 200;
    table.late_member_after_list = 1;
    try std.testing.expect(!try sessionIsEmptyWith(std.testing.allocator, 200, table));
    try std.testing.expectEqual(@as(usize, 2), table.list_calls);
}

test "the process list holds this process and a child it starts" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);

    var pids: std.ArrayList(std.posix.pid_t) = .empty;
    defer pids.deinit(alloc);
    try listProcessIds(alloc, &pids);
    try std.testing.expect(std.mem.findScalar(std.posix.pid_t, pids.items, std.c.getpid()) != null);
    try std.testing.expect(std.mem.findScalar(std.posix.pid_t, pids.items, child.id.?) != null);
}

test "ending a real session leaves the leader and a setsid daemon alone" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // The leader starts a session and two children. `member` stays in it and
    // is the only holder of the pipe the test reads, so the pipe's end says
    // when it is gone. `daemon` leaves with setsid and tells the leader when
    // it has, before the leader reports.
    const script =
        \\import os, signal, sys
        \\os.setsid()
        \\ready_r, ready_w = os.pipe()
        \\member = os.fork()
        \\if member == 0:
        \\    os.close(ready_r); os.close(ready_w)
        \\    signal.alarm(30); signal.pause()
        \\    os._exit(0)
        \\daemon = os.fork()
        \\if daemon == 0:
        \\    os.setsid()
        \\    os.dup2(os.open(os.devnull, os.O_RDWR), 1)
        \\    os.write(ready_w, b"x")
        \\    signal.alarm(30); signal.pause()
        \\    os._exit(0)
        \\os.read(ready_r, 1)
        \\sys.stdout.write("%d %d\n" % (member, daemon)); sys.stdout.flush()
        \\os.close(1)
        \\signal.alarm(30); signal.pause()
    ;
    var leader = try std.process.spawn(io, .{
        .argv = &.{ "python3", "-c", script },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer leader.kill(io);
    const leader_pid = leader.id.?;
    const reports = leader.stdout.?.handle;

    var line: [64]u8 = undefined;
    try waitReadable(reports, 15_000);
    const line_len = try std.posix.read(reports, &line);
    var pids = std.mem.tokenizeScalar(u8, std.mem.trim(u8, line[0..line_len], "\n"), ' ');
    const member_pid = try std.fmt.parseInt(std.posix.pid_t, pids.next().?, 10);
    const daemon_pid = try std.fmt.parseInt(std.posix.pid_t, pids.next().?, 10);
    const daemon_identity = (try captureSnapshot(alloc, daemon_pid)).identity;
    defer if (captureSnapshot(alloc, daemon_pid)) |now| {
        // Cleanup: the daemon may have ended already.
        if (now.identity.eql(daemon_identity)) std.posix.kill(daemon_pid, std.posix.SIG.KILL) catch {};
    } else |_| {};
    try std.testing.expectEqual(SessionState{ .found = leader_pid }, inspectSession(member_pid));
    try std.testing.expectEqual(SessionState{ .found = daemon_pid }, inspectSession(daemon_pid));

    const summary = try endSession(alloc, leader_pid);
    try std.testing.expectEqual(@as(usize, 1), summary.delivered);
    // The member held the last copy of the pipe: its end arrives with its death.
    try waitReadable(reports, 15_000);
    try std.testing.expectEqual(@as(usize, 0), try std.posix.read(reports, &line));
    try std.testing.expect(try processIsAlive(alloc, leader_pid));
    try std.testing.expect(try processIsAlive(alloc, daemon_pid));
}

test "a child that ended stays uncollected until its owner collects it" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "exit 7" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer if (child.id != null) child.kill(io);
    const pid = child.id.?;

    try std.testing.expectEqual(ChildEnd{ .exited = 7 }, try waitUntilExitedUncollected(pid));
    // Reporting the end collected nothing: the entry is still there, and asking again says the same.
    try std.testing.expect(exitedChildIsUncollected(pid));
    try std.testing.expectEqual(ChildEnd{ .exited = 7 }, try waitUntilExitedUncollected(pid));

    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, term);
    try std.testing.expect(!exitedChildIsUncollected(pid));
    try std.testing.expectError(error.WaitForChildFailed, waitUntilExitedUncollected(pid));
}

test "a child killed by a signal is reported as signaled and stays uncollected" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sleep", "30" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer if (child.id != null) child.kill(io);
    const pid = child.id.?;
    // A child that is still running is not an ended one.
    try std.testing.expect(!exitedChildIsUncollected(pid));

    try std.posix.kill(pid, std.posix.SIG.KILL);
    try std.testing.expectEqual(
        ChildEnd{ .signaled = @backingInt(std.posix.SIG.KILL) },
        try waitUntilExitedUncollected(pid),
    );
    try std.testing.expect(exitedChildIsUncollected(pid));
    _ = try child.wait(io);
    try std.testing.expect(!exitedChildIsUncollected(pid));
}

test "a real session is empty once its last member is gone" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // The leader starts a session and one member, and reports the member's pid.
    const script =
        \\import os, signal, sys
        \\os.setsid()
        \\member = os.fork()
        \\if member == 0:
        \\    os.close(1)
        \\    signal.alarm(30); signal.pause()
        \\    os._exit(0)
        \\sys.stdout.write("%d\n" % member); sys.stdout.flush()
        \\os.close(1)
        \\signal.alarm(30); signal.pause()
    ;
    var leader = try std.process.spawn(io, .{
        .argv = &.{ "python3", "-c", script },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer leader.kill(io);
    const leader_pid = leader.id.?;
    const reports = leader.stdout.?.handle;
    var line: [32]u8 = undefined;
    try waitReadable(reports, 15_000);
    const line_len = try std.posix.read(reports, &line);
    const member_pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, line[0..line_len], "\n"), 10);

    try std.testing.expect(!try sessionIsEmpty(alloc, leader_pid));
    // The member is a child of the leader, which does not collect it, so it
    // stays as a zombie, and a zombie does not count.
    try std.posix.kill(member_pid, std.posix.SIG.KILL);
    const deadline = io_mod.milliTimestamp() + 15_000;
    while (!try sessionIsEmpty(alloc, leader_pid)) {
        if (io_mod.milliTimestamp() > deadline) return error.TestTimedOut;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
}

fn waitReadable(fd: std.posix.fd_t, timeout_ms: i32) !void {
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    if ((try std.posix.poll(&fds, timeout_ms)) == 0) return error.TestTimedOut;
}

fn captureSnapshot(alloc: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
    return switch (builtin.target.os.tag) {
        .linux => try captureLinuxSnapshot(alloc, pid),
        .macos => try captureMacOSSnapshot(pid),
        else => error.ProcessTreeUnsupported,
    };
}

fn captureLinuxSnapshot(alloc: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
    if (comptime builtin.target.os.tag != .linux) return error.ProcessTreeUnsupported;
    const path = try alloc.print("/proc/{d}/stat", .{pid});
    defer alloc.free(path);
    var file = (try openLinuxProcFile(path)) orelse return error.ProcessNotFound;
    defer file.close(io_mod.getIo());
    var buffer: [4096]u8 = undefined;
    const read_len = try readLinuxProcFile(file, &buffer);
    const stat = buffer[0..read_len];
    const close_paren = std.mem.findScalarLast(u8, stat, ')') orelse
        return error.ProcessIdentityUnavailable;
    var fields = std.mem.tokenizeScalar(u8, stat[close_paren + 1 ..], ' ');
    var field_number: usize = 3;
    var parent_pid: ?std.posix.pid_t = null;
    var zombie = false;
    while (fields.next()) |field| : (field_number += 1) {
        if (field_number == 3) zombie = field.len == 1 and field[0] == 'Z';
        if (field_number == 4) {
            parent_pid = std.fmt.parseInt(std.posix.pid_t, field, 10) catch
                return error.ProcessIdentityUnavailable;
        }
        if (field_number == 22) {
            const start_ticks = std.fmt.parseUnsigned(u64, field, 10) catch
                return error.ProcessIdentityUnavailable;
            return .{
                .identity = .{ .linux_start_ticks = start_ticks },
                .parent_pid = parent_pid orelse
                    return error.ProcessIdentityUnavailable,
                .zombie = zombie,
            };
        }
    }
    return error.ProcessIdentityUnavailable;
}

fn readLinuxProcFile(file: std.Io.File, buffer: []u8) !usize {
    if (comptime builtin.target.os.tag != .linux) return error.ProcessTreeUnsupported;
    while (true) {
        const result = std.posix.system.read(file.handle, buffer.ptr, buffer.len);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                const read_len: usize = @intCast(result);
                if (read_len == 0) return error.ProcessNotFound;
                return read_len;
            },
            .INTR => continue,
            .SRCH => return error.ProcessNotFound,
            else => return error.ProcessIdentityUnavailable,
        }
    }
}

fn captureMacOSSnapshot(pid: std.posix.pid_t) !ProcessSnapshot {
    if (comptime builtin.target.os.tag != .macos) return error.ProcessTreeUnsupported;
    var unique: Darwin.ProcUniqueIdentifierInfo = undefined;
    const unique_len = Darwin.proc_pidinfo(
        pid,
        Darwin.proc_pid_unique_identifier_info,
        0,
        &unique,
        @sizeOf(Darwin.ProcUniqueIdentifierInfo),
    );
    if (unique_len == 0) return error.ProcessNotFound;
    if (unique_len != @sizeOf(Darwin.ProcUniqueIdentifierInfo)) {
        return error.ProcessIdentityUnavailable;
    }
    var info: Darwin.ProcBsdInfo = undefined;
    const read_len = Darwin.proc_pidinfo(
        pid,
        3,
        0,
        &info,
        @sizeOf(Darwin.ProcBsdInfo),
    );
    if (read_len == 0) return error.ProcessNotFound;
    if (read_len != @sizeOf(Darwin.ProcBsdInfo)) {
        return error.ProcessIdentityUnavailable;
    }
    return .{
        .identity = .{ .macos_unique_id = unique.p_uniqueid },
        .parent_pid = @intCast(info.pbi_ppid),
        .parent_unique_id = unique.p_puniqueid,
        .started_at_us = darwinStartTimeUs(
            info.pbi_start_tvsec,
            info.pbi_start_tvusec,
        ),
        .zombie = info.pbi_status == Darwin.process_status_zombie,
    };
}

pub fn processIsAlive(alloc: Allocator, pid: std.posix.pid_t) !bool {
    const snapshot = captureSnapshot(alloc, pid) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        else => return err,
    };
    return snapshotIsAlive(snapshot);
}

fn snapshotIsAlive(snapshot: ProcessSnapshot) bool {
    return !snapshot.zombie;
}

/// Whether `pid` can run no more: every thread of it is stopped by a signal,
/// it has exited, or it is gone. kill(2) only queues a SIGSTOP, so a caller
/// that must know the stop has landed, before it looks at what the process
/// started, asks this.
pub fn processIsStopped(alloc: Allocator, pid: std.posix.pid_t) !bool {
    return switch (builtin.target.os.tag) {
        .linux => linuxProcessIsStopped(alloc, pid),
        .macos => macOSProcessIsStopped(pid),
        else => error.ProcessTreeUnsupported,
    };
}

fn linuxProcessIsStopped(alloc: Allocator, pid: std.posix.pid_t) !bool {
    if (comptime builtin.target.os.tag != .linux) return error.ProcessTreeUnsupported;
    const task_path = try alloc.print("/proc/{d}/task", .{pid});
    defer alloc.free(task_path);
    var task_dir = (try openLinuxProcDir(task_path)) orelse return true;
    defer task_dir.close(io_mod.getIo());
    var tasks = task_dir.iterateAssumeFirstIteration();
    while (try tasks.next(io_mod.getIo())) |entry| {
        const tid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        const path = try alloc.print("/proc/{d}/task/{d}/stat", .{ pid, tid });
        defer alloc.free(path);
        var file = (try openLinuxProcFile(path)) orelse continue;
        defer file.close(io_mod.getIo());
        var buffer: [4096]u8 = undefined;
        const read_len = readLinuxProcFile(file, &buffer) catch |err| switch (err) {
            error.ProcessNotFound => continue,
            else => return err,
        };
        const stat = buffer[0..read_len];
        const close_paren = std.mem.findScalarLast(u8, stat, ')') orelse return error.ProcessIdentityUnavailable;
        if (close_paren + 2 >= stat.len) return error.ProcessIdentityUnavailable;
        // T: stopped by a signal; t: stopped by a tracer; Z and X: exited.
        if (std.mem.findScalar(u8, "TtZX", stat[close_paren + 2]) == null) return false;
    }
    return true;
}

fn macOSProcessIsStopped(pid: std.posix.pid_t) !bool {
    if (comptime builtin.target.os.tag != .macos) return error.ProcessTreeUnsupported;
    var info: Darwin.ProcBsdInfo = undefined;
    const read_len = Darwin.proc_pidinfo(pid, 3, 0, &info, @sizeOf(Darwin.ProcBsdInfo));
    if (read_len == 0) return true;
    if (read_len != @sizeOf(Darwin.ProcBsdInfo)) return error.ProcessIdentityUnavailable;
    return info.pbi_status == Darwin.process_status_stopped or info.pbi_status == Darwin.process_status_zombie;
}

const Darwin = struct {
    // Stable libproc process-identity flavor; the SDK omits this constant from
    // its public header, but XNU defines the record as API with a fixed size.
    const proc_pid_unique_identifier_info: c_int = 17;
    const proc_pid_fd_pipe_info: c_int = 6;
    const process_status_stopped: u32 = 4;
    const process_status_zombie: u32 = 5;

    const ProcFileInfo = extern struct {
        fi_openflags: u32,
        fi_status: u32,
        fi_offset: i64,
        fi_type: i32,
        fi_guardflags: u32,
    };

    const VinfoStat = extern struct {
        vst_dev: u32,
        vst_mode: u16,
        vst_nlink: u16,
        vst_ino: u64,
        vst_uid: u32,
        vst_gid: u32,
        vst_atime: i64,
        vst_atimensec: i64,
        vst_mtime: i64,
        vst_mtimensec: i64,
        vst_ctime: i64,
        vst_ctimensec: i64,
        vst_birthtime: i64,
        vst_birthtimensec: i64,
        vst_size: i64,
        vst_blocks: i64,
        vst_blksize: i32,
        vst_flags: u32,
        vst_gen: u32,
        vst_rdev: u32,
        vst_qspare: [2]i64,
    };

    const PipeInfo = extern struct {
        pipe_stat: VinfoStat,
        pipe_handle: u64,
        pipe_peerhandle: u64,
        pipe_status: i32,
        rfu_1: i32,
    };

    const PipeFdInfo = extern struct {
        pfi: ProcFileInfo,
        pipeinfo: PipeInfo,
    };

    const ProcUniqueIdentifierInfo = extern struct {
        p_uuid: [16]u8,
        p_uniqueid: u64,
        p_puniqueid: u64,
        p_idversion: i32,
        p_orig_ppidversion: i32,
        p_reserve2: u64,
        p_reserve3: u64,
    };

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

    extern "c" fn proc_listchildpids(
        ppid: c_int,
        buffer: ?*anyopaque,
        buffersize: c_int,
    ) c_int;

    extern "c" fn proc_listallpids(
        buffer: ?*anyopaque,
        buffersize: c_int,
    ) c_int;

    extern "c" fn proc_pidinfo(
        pid: c_int,
        flavor: c_int,
        arg: u64,
        buffer: *anyopaque,
        buffersize: c_int,
    ) c_int;

    extern "c" fn proc_pidfdinfo(
        pid: c_int,
        fd: c_int,
        flavor: c_int,
        buffer: *anyopaque,
        buffersize: c_int,
    ) c_int;
};

test "tracked identity distinguishes process instances" {
    const linux = Identity{ .linux_start_ticks = 42 };
    try std.testing.expect(linux.eql(.{ .linux_start_ticks = 42 }));
    try std.testing.expect(!linux.eql(.{ .linux_start_ticks = 43 }));
    try std.testing.expect(!linux.eql(.{ .macos_unique_id = 42 }));
}

test "zombie snapshots are terminal process state" {
    const live = ProcessSnapshot{
        .identity = .{ .linux_start_ticks = 1 },
        .parent_pid = 1,
    };
    var zombie = live;
    zombie.zombie = true;
    try std.testing.expect(snapshotIsAlive(live));
    try std.testing.expect(!snapshotIsAlive(zombie));
}

test "Darwin witness scan excludes processes older than command root" {
    try std.testing.expect(couldBelongByStart(null, null));
    try std.testing.expect(!couldBelongByStart(100, null));
    try std.testing.expect(!couldBelongByStart(100, 99));
    try std.testing.expect(couldBelongByStart(100, 100));
    try std.testing.expect(couldBelongByStart(100, 101));
    try std.testing.expectEqual(@as(u64, 2_000_003), darwinStartTimeUs(2, 3));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        darwinStartTimeUs(std.math.maxInt(u64), 1),
    );
}
