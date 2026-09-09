const std = @import("std");
const builtin = @import("builtin");
const darwin_process_spawn = @import("../shared/darwin_process_spawn.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const DarwinPipeIdentity = struct {
    handle: u64,
    peer_handle: u64,

    fn eql(self: DarwinPipeIdentity, other: DarwinPipeIdentity) bool {
        return self.handle == other.handle and self.peer_handle == other.peer_handle;
    }

    fn matchesAnchored(self: DarwinPipeIdentity, actual: DarwinPipeIdentity) bool {
        // Each shared scope owner pins the write endpoint. Its handle cannot be
        // recycled, but Darwin clears the peer handle when the last reader closes.
        return self.handle == actual.handle and
            (self.peer_handle == actual.peer_handle or actual.peer_handle == 0);
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
        if (comptime builtin.os.tag != .macos) return error.ProcessTreeUnsupported;
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

    /// Adopts a received write-end pipe descriptor on success only. The caller
    /// retains fd on error; only the duplicate acquired here is cleaned up.
    /// Both descriptors are CLOEXEC. The duplicate anchors the kernel object
    /// after closeChildCopy, without relying on another process remaining alive.
    pub fn fromOwnedChildFd(fd: std.posix.fd_t) !DarwinProcessWitness {
        if (comptime builtin.os.tag != .macos) return error.ProcessTreeUnsupported;
        const anchor = while (true) {
            const result = std.posix.system.fcntl(fd, std.posix.F.DUPFD_CLOEXEC, @as(usize, 0));
            switch (std.posix.errno(result)) {
                .SUCCESS => break result,
                .INTR => continue,
                else => return error.ProcessWitnessDuplicateFailed,
            }
        };
        errdefer closeFd(anchor);
        const raw_flags = std.posix.system.fcntl(anchor, std.posix.F.GETFL, @as(usize, 0));
        if (raw_flags < 0) return error.InvalidProcessWitness;
        const flags: std.posix.O = @bitCast(@as(u32, @intCast(raw_flags)));
        if (flags.ACCMODE != .WRONLY) return error.InvalidProcessWitness;
        const identity = captureDarwinPipeIdentityWith(std.c.getpid(), anchor, true) catch |err| switch (err) {
            error.ProcessNotFound => return error.InvalidProcessWitness,
            else => return err,
        };
        try setCloseOnExec(fd);
        return .{
            .supervisor_fd = anchor,
            .child_fd = fd,
            .descendant_fd = darwin_process_spawn.inherited_fd_target(fd),
            .identity = identity,
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
};

const ProcessSnapshot = struct {
    identity: Identity,
    parent_pid: std.posix.pid_t,
    parent_unique_id: ?u64 = null,
    started_at_us: ?u64 = null,
    zombie: bool = false,
};

/// Relocatable, single-writer membership. The mapping owner must keep this
/// storage alive until every borrowing Tracker is deinitialized. Only after
/// confirmed writer death may another process refresh it. Readers need no lock.
/// Records (including dead ancestry) are immutable once committed; slot zero
/// and its discovery metadata are published together as the root.
pub const SharedMembership = extern struct {
    magic: u64 = magic_value,
    version: u32 = 1,
    capacity: u32 = record_capacity,
    committed: u32 = 0,
    scanning: u32 = 0,
    failed: u32 = 0,
    reserved: u32 = 0,
    metadata: Metadata = .{},
    records: [record_capacity]Record = @splat(.{}),

    const magic_value: u64 = 0x667873636f706531;
    const record_capacity = 4096;
    const Record = extern struct {
        pid: i32 = 0,
        kind: u32 = 0,
        instance: u64 = 0,

        fn encode(process: TrackedProcess) Record {
            return .{
                .pid = process.pid,
                .kind = switch (process.identity) {
                    .linux_start_ticks => 1,
                    .macos_unique_id => 2,
                },
                .instance = switch (process.identity) {
                    inline else => |value| value,
                },
            };
        }

        fn decode(record: Record) !TrackedProcess {
            if (record.pid <= 0) return error.InvalidSharedMembership;
            return .{ .pid = record.pid, .identity = switch (record.kind) {
                1 => if (builtin.os.tag == .linux) .{ .linux_start_ticks = record.instance } else return error.InvalidSharedMembership,
                2 => if (builtin.os.tag == .macos) .{ .macos_unique_id = record.instance } else return error.InvalidSharedMembership,
                else => return error.InvalidSharedMembership,
            } };
        }
    };

    const Metadata = extern struct {
        started_at_us: u64 = 0,
        witness_handle: u64 = 0,
        witness_peer_handle: u64 = 0,
        witness_fd: i32 = -1,
        has_start: u32 = 0,
        has_witness: u32 = 0,
        reserved: u32 = 0,
    };

    fn count(self: *const SharedMembership) !usize {
        if (self.magic != magic_value or self.version != 1 or
            self.capacity != record_capacity or self.reserved != 0)
            return error.InvalidSharedMembership;
        const value = @atomicLoad(u32, &self.committed, .acquire);
        if (value > record_capacity) return error.InvalidSharedMembership;
        return value;
    }

    /// Validates only published bytes. In-progress records are never decoded.
    /// An interrupted or failed scan remains readable for best-effort cleanup.
    pub fn validate(self: *const SharedMembership) !void {
        const length = try self.count();
        if (@atomicLoad(u32, &self.scanning, .acquire) > 1 or
            @atomicLoad(u32, &self.failed, .acquire) > 1)
            return error.InvalidSharedMembership;
        if (length == 0) return;
        const meta = self.metadata;
        if (meta.has_start > 1 or meta.has_witness > 1 or meta.reserved != 0 or
            (meta.has_witness == 1 and meta.witness_fd < 0) or
            (builtin.os.tag == .macos and meta.has_start != 1))
            return error.InvalidSharedMembership;
        for (self.records[0..length]) |record| _ = try record.decode();
    }

    /// A received capability must pin the witness already published in this
    /// ledger, not merely any pipe. Unpublished metadata is never inspected.
    pub fn validateWitness(self: *const SharedMembership, witness: *const DarwinProcessWitness) !void {
        try self.validate();
        if ((try self.count()) == 0 or self.metadata.has_witness == 0) return;
        const expected: DarwinPipeIdentity = .{
            .handle = self.metadata.witness_handle,
            .peer_handle = self.metadata.witness_peer_handle,
        };
        if (!expected.matchesAnchored(witness.identity)) return error.SharedWitnessMismatch;
    }

    pub fn rootPid(self: *const SharedMembership) ?std.posix.pid_t {
        self.validate() catch return null;
        if ((self.count() catch return null) == 0) return null;
        return self.records[0].pid;
    }

    /// False means cleanup cannot be declared clean, even if all committed
    /// processes have exited. Failure is sticky across successful later scans.
    pub fn isComplete(self: *const SharedMembership) bool {
        self.validate() catch return false;
        return (self.count() catch return false) > 0 and
            @atomicLoad(u32, &self.scanning, .acquire) == 0 and
            @atomicLoad(u32, &self.failed, .acquire) == 0;
    }

    fn markIncomplete(self: *SharedMembership) void {
        @atomicStore(u32, &self.failed, 1, .release);
    }

    fn append(self: *SharedMembership, process: TrackedProcess) !void {
        const length = try self.count();
        if (length == record_capacity) {
            self.markIncomplete();
            return error.SharedMembershipFull;
        }
        const record = Record.encode(process);
        _ = try record.decode();
        self.records[length] = record;
        @atomicStore(u32, &self.committed, @intCast(length + 1), .release);
    }
};

pub const Liveness = enum { alive, empty, incomplete };

pub const DeliverySummary = struct {
    delivered: usize = 0,
    incomplete: bool = false,
};

const ProcessGroupState = union(enum) {
    found: std.posix.pid_t,
    vanished,
    unavailable,
};

const SystemSignalEffects = struct {
    fn capture(alloc: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
        return captureSnapshot(alloc, pid);
    }

    fn processGroup(pid: std.posix.pid_t) ProcessGroupState {
        return inspectProcessGroup(pid);
    }

    fn send(pid: std.posix.pid_t, signal: std.posix.SIG) std.posix.KillError!void {
        return std.posix.kill(pid, signal);
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
    shared: ?*SharedMembership = null,

    /// Borrows the mapping; alloc owns only process-local scan scratch. This
    /// does not grant writer ownership or acknowledge a previous writer's death.
    pub fn initShared(alloc: Allocator, state: *SharedMembership) !Tracker {
        try state.validate();
        var tracker = try init(alloc);
        tracker.shared = state;
        return tracker;
    }

    fn rootProcess(self: *const Tracker) ?TrackedProcess {
        if (self.shared) |state| {
            if ((state.count() catch return null) == 0) return null;
            return state.records[0].decode() catch null;
        }
        return self.root;
    }

    fn processCount(self: *const Tracker) usize {
        if (self.shared) |state| return (state.count() catch return 0) -| 1;
        return self.processes.items.len;
    }

    /// Null only for a committed shared record that no longer decodes. Callers
    /// treat that as incomplete membership, never as an absent process.
    fn processAt(self: *const Tracker, index: usize) ?TrackedProcess {
        if (self.shared) |state| return state.records[index + 1].decode() catch null;
        return self.processes.items[index];
    }

    fn rootStartedAt(self: *const Tracker) ?u64 {
        if (self.shared) |state| {
            if ((state.count() catch return null) == 0) return null;
            return if (state.metadata.has_start == 1) state.metadata.started_at_us else null;
        }
        return self.macos_root_started_at_us;
    }

    fn remember(self: *Tracker, process: TrackedProcess) !bool {
        if (self.shared) |state| {
            for (state.records[0..try state.count()]) |record| {
                const previous = try record.decode();
                if (previous.pid == process.pid and previous.identity.eql(process.identity)) return false;
            }
            try state.append(process);
            return true;
        }
        for (self.processes.items) |*previous| {
            if (previous.pid != process.pid) continue;
            if (previous.identity.eql(process.identity)) return false;
            previous.identity = process.identity;
            return true;
        }
        try self.processes.append(self.alloc, process);
        return true;
    }

    fn beginScan(self: *Tracker) !void {
        if (self.shared) |state| {
            try state.validate();
            // The caller must have confirmed the previous writer's death. A
            // surviving marker records lost discovery, not a lock to acquire.
            if (@atomicRmw(u32, &state.scanning, .Xchg, 1, .acq_rel) != 0)
                state.markIncomplete();
        }
    }

    fn endScan(self: *Tracker) void {
        if (self.shared) |state| @atomicStore(u32, &state.scanning, 0, .release);
    }

    fn failScan(self: *Tracker) void {
        if (self.shared) |state| state.markIncomplete();
    }

    fn capture(self: *Tracker, pid: std.posix.pid_t) !ProcessSnapshot {
        return if (self.shared != null) captureSnapshotChecked(self.alloc, pid) else captureSnapshot(self.alloc, pid);
    }

    pub fn init(alloc: Allocator) !Tracker {
        var tracker = Tracker{ .alloc = alloc };
        errdefer tracker.deinit();
        if (comptime builtin.os.tag == .macos) {
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
        if (comptime builtin.os.tag != .macos) return;
        if (self.shared) |state| {
            const length = state.count() catch {
                state.markIncomplete();
                return;
            };
            if (length != 0) {
                // Discovery metadata is immutable once the root is visible.
                if (state.metadata.has_witness != 1 or
                    state.metadata.witness_fd != witness.descendant_fd or
                    state.metadata.witness_handle != witness.identity.handle or
                    state.metadata.witness_peer_handle != witness.identity.peer_handle)
                    state.markIncomplete();
                return;
            }
            if (@atomicRmw(u32, &state.scanning, .Xchg, 1, .acq_rel) != 0)
                state.markIncomplete();
            state.metadata.witness_handle = witness.identity.handle;
            state.metadata.witness_peer_handle = witness.identity.peer_handle;
            state.metadata.witness_fd = witness.descendant_fd;
            state.metadata.has_witness = 1;
            @atomicStore(u32, &state.scanning, 0, .release);
            return;
        }
        self.darwin_process_witness = witness.identity;
        self.darwin_process_witness_fd = witness.descendant_fd;
    }

    pub fn refresh(self: *Tracker, root_pid: std.posix.pid_t) !void {
        try self.beginScan();
        defer self.endScan();
        errdefer self.failScan();
        try self.refreshInner(root_pid);
    }

    fn refreshInner(self: *Tracker, root_pid: std.posix.pid_t) !void {
        if (self.shared != null and root_pid <= 0) return error.SharedRootUnavailable;
        if (self.shared) |state| {
            if (state.rootPid()) |pid| {
                if (pid != root_pid) return error.SharedRootMismatch;
            }
        }
        const root_snapshot: ?ProcessSnapshot = self.capture(root_pid) catch |err| switch (err) {
            error.ProcessNotFound => null,
            else => return err,
        };
        var traverse_root = false;
        if (root_snapshot) |snapshot| {
            if (self.rootProcess()) |root| {
                traverse_root = root.pid == root_pid and
                    root.identity.eql(snapshot.identity);
            } else {
                const root: TrackedProcess = .{ .pid = root_pid, .identity = snapshot.identity };
                if (self.shared) |state| {
                    state.metadata.started_at_us = snapshot.started_at_us orelse 0;
                    state.metadata.has_start = @intFromBool(snapshot.started_at_us != null);
                    try state.append(root);
                } else {
                    self.root = root;
                    self.macos_root_started_at_us = snapshot.started_at_us;
                }
                traverse_root = true;
            }
        }
        if (self.shared != null and self.rootProcess() == null) return error.SharedRootUnavailable;
        if (traverse_root) try self.appendDirectChildren(self.rootProcess().?);
        if (comptime builtin.os.tag == .macos) {
            if (root_snapshot == null or (self.shared != null and !traverse_root)) try self.refreshLineageInner();
        }

        var parent_index: usize = 0;
        while (parent_index < self.processCount()) : (parent_index += 1) {
            const parent = self.processAt(parent_index) orelse return error.InvalidSharedMembership;
            const actual = self.capture(parent.pid) catch |err| {
                if (self.shared != null and err != error.ProcessNotFound) return err;
                continue;
            };
            if (!shouldTraverseParent(parent.identity, actual.identity)) continue;
            try self.appendDirectChildren(parent);
        }
    }

    pub fn refreshAdditionalRoot(
        self: *Tracker,
        root_pid: std.posix.pid_t,
    ) !void {
        try self.beginScan();
        defer self.endScan();
        errdefer self.failScan();
        if (self.shared != null and self.rootProcess() == null) return error.SharedRootUnavailable;
        const snapshot = self.capture(root_pid) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        try self.appendDirectChildren(.{
            .pid = root_pid,
            .identity = snapshot.identity,
        });
    }

    pub fn refreshLineageProcesses(self: *Tracker) !void {
        try self.beginScan();
        defer self.endScan();
        errdefer self.failScan();
        try self.refreshLineageInner();
    }

    fn refreshLineageInner(self: *Tracker) !void {
        if (comptime builtin.os.tag != .macos) return;
        if (self.shared != null and self.rootProcess() == null) return error.SharedRootUnavailable;
        const reported = Darwin.proc_listallpids(null, 0);
        if (reported <= 0) {
            if (self.shared != null) return error.ProcessTreeInspectionFailed;
            return;
        }
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
        if (count <= 0 or @as(usize, @intCast(count)) >= self.macos_pid_buffer.len) {
            if (self.shared != null) return error.ProcessTreeInspectionFailed;
            if (count <= 0) return;
        }
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

    /// Linux subreapers can rediscover orphans without dead ancestry. Darwin
    /// must retain unique parent identities across forks between snapshots.
    pub fn pruneExited(self: *Tracker) void {
        if (self.shared != null) return;
        if (comptime builtin.os.tag != .linux) return;
        var index: usize = 0;
        while (index < self.processes.items.len) {
            const tracked = self.processes.items[index];
            const snapshot = captureSnapshot(self.alloc, tracked.pid) catch |err| {
                if (err == error.ProcessNotFound) {
                    _ = self.processes.swapRemove(index);
                } else {
                    index += 1;
                }
                continue;
            };
            if (snapshot.zombie or !tracked.identity.eql(snapshot.identity)) {
                _ = self.processes.swapRemove(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn signalAll(self: *Tracker, signal: std.posix.SIG) usize {
        return self.signalProcessesChecked(signal, null).delivered;
    }

    pub fn signalAllChecked(self: *Tracker, signal: std.posix.SIG) DeliverySummary {
        return self.signalProcessesChecked(signal, null);
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
        var summary: DeliverySummary = .{};
        if (self.shared) |state| {
            state.validate() catch return .{ .incomplete = true };
            summary.incomplete = !state.isComplete();
        }
        var index = self.processCount();
        while (index > 0) {
            index -= 1;
            const process = self.processAt(index) orelse {
                summary.incomplete = true;
                continue;
            };
            self.signalTrackedProcessWith(process, signal, preserved_group, &summary, Effects);
        }
        if (self.rootProcess()) |root| {
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

    fn signalTrackedProcessWith(
        self: *Tracker,
        process: TrackedProcess,
        signal: std.posix.SIG,
        preserved_group: ?std.posix.pid_t,
        summary: *DeliverySummary,
        comptime Effects: type,
    ) void {
        const actual = (if (Effects == SystemSignalEffects and self.shared != null)
            captureSnapshotChecked(self.alloc, process.pid)
        else
            Effects.capture(self.alloc, process.pid)) catch |err| {
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
    }

    /// Unlike anyAlive, uncertainty is not evidence of an empty scope. Does
    /// not refresh or write membership; readers may call this while the writer
    /// lives. Cleanup must quiesce the writer and refresh before accepting empty.
    /// Incomplete takes precedence over alive so loss of attribution is visible.
    pub fn scanLiveness(self: *Tracker) Liveness {
        return self.scanLivenessWith(struct {
            fn capture(alloc: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
                return captureSnapshotChecked(alloc, pid);
            }
        });
    }

    fn scanLivenessWith(self: *Tracker, comptime Effects: type) Liveness {
        if (self.shared) |state| state.validate() catch return .incomplete;
        const initial_count = self.processCount();
        var alive = false;
        var incomplete = if (self.shared) |state| !state.isComplete() else false;
        var index: usize = 0;
        while (index < self.processCount() + 1) : (index += 1) {
            const process = if (index == 0) (self.rootProcess() orelse continue) else self.processAt(index - 1) orelse {
                incomplete = true;
                continue;
            };
            const actual = Effects.capture(self.alloc, process.pid) catch |err| {
                if (err != error.ProcessNotFound) incomplete = true;
                continue;
            };
            if (process.identity.eql(actual.identity) and snapshotIsAlive(actual)) alive = true;
        }
        if (self.shared) |state| {
            if (!state.isComplete() or initial_count != self.processCount()) incomplete = true;
        }
        return if (incomplete) .incomplete else if (alive) .alive else .empty;
    }

    pub fn anyAlive(self: *Tracker) bool {
        if (self.shared != null) return self.scanLiveness() != .empty;
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

    fn appendDirectChildren(
        self: *Tracker,
        parent: TrackedProcess,
    ) !void {
        switch (builtin.os.tag) {
            .linux => try self.appendLinuxChildren(parent),
            .macos => try self.appendMacOSChildren(parent),
            else => return error.ProcessTreeUnsupported,
        }
    }

    fn appendLinuxChildren(
        self: *Tracker,
        parent: TrackedProcess,
    ) !void {
        if (comptime builtin.os.tag != .linux) return error.ProcessTreeUnsupported;
        if (!try self.parentIdentityMatches(parent)) return;
        const task_path = try std.fmt.allocPrint(
            self.alloc,
            "/proc/{d}/task",
            .{parent.pid},
        );
        defer self.alloc.free(task_path);
        var task_dir = (try openLinuxProcDir(task_path)) orelse {
            if (self.shared != null and try self.parentIdentityMatches(parent)) return error.ProcessTreeInspectionFailed;
            return;
        };
        defer task_dir.close(io_mod.getIo());
        var tasks = task_dir.iterate();
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
        const path = try std.fmt.allocPrint(
            self.alloc,
            "/proc/{d}/task/{d}/children",
            .{ parent.pid, tid },
        );
        defer self.alloc.free(path);
        var file = (try openLinuxProcFile(path)) orelse {
            if (self.shared != null) {
                _ = self.capture(tid) catch |err| switch (err) {
                    error.ProcessNotFound => return,
                    else => return err,
                };
                if (try self.parentIdentityMatches(parent)) return error.ProcessTreeInspectionFailed;
            }
            return;
        };
        defer file.close(io_mod.getIo());
        var buffer: [64 * 1024]u8 = undefined;
        const read_len = readLinuxChildrenFile(file, &buffer) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        if (self.shared != null and read_len == buffer.len) return error.ProcessTreeInspectionFailed;
        if (!try self.parentIdentityMatches(parent)) return;
        var children = std.mem.tokenizeAny(u8, buffer[0..read_len], " \t\r\n");
        while (children.next()) |pid_text| {
            const pid = std.fmt.parseInt(std.posix.pid_t, pid_text, 10) catch {
                if (self.shared != null) return error.ProcessTreeInspectionFailed;
                continue;
            };
            if (self.shared != null and pid <= 0) return error.ProcessTreeInspectionFailed;
            try self.trackChild(pid, parent.pid);
        }
    }

    fn appendMacOSChildren(
        self: *Tracker,
        parent: TrackedProcess,
    ) !void {
        if (comptime builtin.os.tag != .macos) return error.ProcessTreeUnsupported;
        if (!try self.parentIdentityMatches(parent)) return;
        if (self.shared != null) std.c._errno().* = 0;
        const count = Darwin.proc_listchildpids(
            parent.pid,
            self.macos_child_buffer.ptr,
            @intCast(self.macos_child_buffer.len * @sizeOf(std.posix.pid_t)),
        );
        if (count < 0 or (count > 0 and @as(usize, @intCast(count)) >= self.macos_child_buffer.len)) {
            if (self.shared != null) return error.ProcessTreeInspectionFailed;
        }
        if (count <= 0) {
            if (self.shared != null and count == 0 and std.c._errno().* != 0 and std.c._errno().* != @intFromEnum(std.c.E.SRCH))
                return error.ProcessTreeInspectionFailed;
            return;
        }
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
        const snapshot = self.capture(parent.pid) catch |err| switch (err) {
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
        const snapshot = self.capture(pid) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        if (!snapshotBelongsToParent(snapshot, expected_parent_pid)) return;
        if (self.rootProcess()) |root| {
            if (root.pid == pid and root.identity.eql(snapshot.identity)) return;
        }
        _ = try self.remember(.{ .pid = pid, .identity = snapshot.identity });
    }

    fn trackLineageProcess(self: *Tracker, pid: std.posix.pid_t) !bool {
        return self.trackLineageProcessWith(pid, struct {
            fn capture(tracker: *Tracker, candidate: std.posix.pid_t) !ProcessSnapshot {
                return tracker.capture(candidate);
            }

            fn hasWitness(tracker: *Tracker, candidate: std.posix.pid_t) !bool {
                return tracker.processHasBoundWitness(candidate);
            }
        });
    }

    fn trackLineageProcessWith(self: *Tracker, pid: std.posix.pid_t, comptime Effects: type) !bool {
        const snapshot = Effects.capture(self, pid) catch |err| {
            if (self.shared != null and err != error.ProcessNotFound) {
                // Global enumeration includes protected, unrelated processes.
                // Failed candidate discovery is not failed inspection of an
                // owned member, unless the PID could still be a recorded one.
                if (err != error.ProcessIdentityUnavailable or self.hasTrackedProcess(pid, null)) return err;
            }
            return false;
        };
        const parent_unique_id = snapshot.parent_unique_id orelse return false;
        const owned_parent = self.containsMacOSUniqueId(parent_unique_id);
        // Committed ancestry proves shared ownership even when short BSD info
        // cannot supply a timestamp. Keep the prefilter for witness discovery
        // and the ordinary tracker's existing admission semantics.
        if ((self.shared == null or !owned_parent) and !couldBelongByStart(
            self.rootStartedAt(),
            snapshot.started_at_us,
        )) return false;
        if (!owned_parent) {
            const has_witness = Effects.hasWitness(self, pid) catch |err| {
                if (self.shared != null and err == error.ProcessIdentityUnavailable and
                    !self.hasTrackedProcess(pid, snapshot.identity)) return false;
                return err;
            };
            if (!has_witness) return false;
        }
        if (self.rootProcess()) |root| {
            if (root.pid == pid and root.identity.eql(snapshot.identity)) return false;
        }
        return self.remember(.{ .pid = pid, .identity = snapshot.identity });
    }

    // Match a recorded PID, narrowed to its instance when a snapshot is available.
    fn hasTrackedProcess(self: *const Tracker, pid: std.posix.pid_t, identity: ?Identity) bool {
        if (self.rootProcess()) |root| {
            if (root.pid == pid and (identity == null or root.identity.eql(identity.?))) return true;
        }
        var index: usize = 0;
        while (index < self.processCount()) : (index += 1) {
            const process = self.processAt(index) orelse continue;
            if (process.pid == pid and (identity == null or process.identity.eql(identity.?))) return true;
        }
        return false;
    }

    fn processHasBoundWitness(self: *Tracker, pid: std.posix.pid_t) !bool {
        if (comptime builtin.os.tag != .macos) return false;
        const expected: DarwinPipeIdentity = if (self.shared) |state| blk: {
            if ((try state.count()) == 0 or state.metadata.has_witness == 0) return false;
            break :blk .{ .handle = state.metadata.witness_handle, .peer_handle = state.metadata.witness_peer_handle };
        } else self.darwin_process_witness orelse return false;
        const fd = if (self.shared) |state| state.metadata.witness_fd else self.darwin_process_witness_fd orelse return false;
        const actual = captureDarwinPipeIdentityWith(pid, fd, self.shared != null) catch |err| {
            if (self.shared != null and err != error.ProcessNotFound) return err;
            return false;
        };
        return if (self.shared != null) expected.matchesAnchored(actual) else expected.eql(actual);
    }

    fn containsMacOSUniqueId(self: *Tracker, unique_id: u64) bool {
        if (self.rootProcess()) |root| {
            if (identityHasMacOSUniqueId(root.identity, unique_id)) return true;
        }
        var index: usize = 0;
        while (index < self.processCount()) : (index += 1) {
            const process = self.processAt(index) orelse continue;
            if (identityHasMacOSUniqueId(process.identity, unique_id)) return true;
        }
        return false;
    }
};

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
    return captureDarwinPipeIdentityWith(pid, fd, false);
}

fn captureDarwinPipeIdentityWith(
    pid: std.posix.pid_t,
    fd: std.posix.fd_t,
    checked: bool,
) !DarwinPipeIdentity {
    if (comptime builtin.os.tag != .macos) return error.ProcessTreeUnsupported;
    if (checked) std.c._errno().* = 0;
    var info: Darwin.PipeFdInfo = undefined;
    const read_len = Darwin.proc_pidfdinfo(
        pid,
        fd,
        Darwin.proc_pid_fd_pipe_info,
        &info,
        @sizeOf(Darwin.PipeFdInfo),
    );
    if (checked and read_len <= 0) {
        // A candidate can lack the inherited fd or use that fd for a non-pipe.
        // Access/inspection failure is not proof that it lacks the witness.
        const err: std.c.E = @enumFromInt(std.c._errno().*);
        return switch (err) {
            .SRCH, .BADF, .NOENT, .INVAL => error.ProcessNotFound,
            else => error.ProcessIdentityUnavailable,
        };
    }
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
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
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

fn readLinuxChildrenFile(file: std.Io.File, buffer: []u8) !usize {
    if (comptime builtin.os.tag != .linux) return error.ProcessTreeUnsupported;
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
    if (comptime builtin.os.tag != .linux) return error.ProcessTreeUnsupported;
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
    if (comptime builtin.os.tag != .linux) return error.ProcessTreeUnsupported;
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

test "Linux proc helpers treat missing process data as vanished" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
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

fn captureSnapshot(alloc: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
    return switch (builtin.os.tag) {
        .linux => try captureLinuxSnapshot(alloc, pid),
        .macos => try captureMacOSSnapshot(pid),
        else => error.ProcessTreeUnsupported,
    };
}

fn captureLinuxSnapshot(alloc: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
    if (comptime builtin.os.tag != .linux) return error.ProcessTreeUnsupported;
    const path = try std.fmt.allocPrint(alloc, "/proc/{d}/stat", .{pid});
    defer alloc.free(path);
    var file = (try openLinuxProcFile(path)) orelse return error.ProcessNotFound;
    defer file.close(io_mod.getIo());
    var buffer: [4096]u8 = undefined;
    const read_len = try readLinuxProcFile(file, &buffer);
    const stat = buffer[0..read_len];
    const close_paren = std.mem.lastIndexOfScalar(u8, stat, ')') orelse
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
    if (comptime builtin.os.tag != .linux) return error.ProcessTreeUnsupported;
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

fn captureSnapshotChecked(alloc: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
    if (comptime builtin.os.tag == .macos) return captureMacOSSnapshotWith(pid, true);
    return captureSnapshot(alloc, pid) catch |err| {
        if (builtin.os.tag != .linux or err != error.ProcessNotFound) return err;
        // Losing procfs is an inspection failure, not proof that every owned
        // process vanished. Our own process must remain inspectable.
        _ = captureLinuxSnapshot(alloc, std.c.getpid()) catch return error.ProcessTreeInspectionFailed;
        return error.ProcessNotFound;
    };
}

fn captureMacOSSnapshot(pid: std.posix.pid_t) !ProcessSnapshot {
    return captureMacOSSnapshotWith(pid, false);
}

fn captureMacOSSnapshotWith(pid: std.posix.pid_t, checked: bool) !ProcessSnapshot {
    if (comptime builtin.os.tag != .macos) return error.ProcessTreeUnsupported;
    if (checked) std.c._errno().* = 0;
    var unique: Darwin.ProcUniqueIdentifierInfo = undefined;
    const unique_len = Darwin.proc_pidinfo(
        pid,
        Darwin.proc_pid_unique_identifier_info,
        0,
        &unique,
        @sizeOf(Darwin.ProcUniqueIdentifierInfo),
    );
    if (unique_len == 0) {
        if (checked and std.c._errno().* != @intFromEnum(std.c.E.SRCH)) return error.ProcessIdentityUnavailable;
        return error.ProcessNotFound;
    }
    if (unique_len != @sizeOf(Darwin.ProcUniqueIdentifierInfo)) {
        return error.ProcessIdentityUnavailable;
    }
    var info: Darwin.ProcBsdInfo = undefined;
    if (checked) std.c._errno().* = 0;
    const read_len = Darwin.proc_pidinfo(
        pid,
        3,
        0,
        &info,
        @sizeOf(Darwin.ProcBsdInfo),
    );
    if (read_len == 0) {
        if (checked and std.c._errno().* == @intFromEnum(std.c.E.PERM)) {
            return captureMacOSShortSnapshot(pid, unique);
        }
        if (checked and std.c._errno().* != @intFromEnum(std.c.E.SRCH)) return error.ProcessIdentityUnavailable;
        return error.ProcessNotFound;
    }
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

fn checkedDarwinRead(read_len: c_int, expected: usize, errno: c_int) !void {
    if (read_len == expected) return;
    if (read_len == 0 and errno == @intFromEnum(std.c.E.SRCH)) return error.ProcessNotFound;
    return error.ProcessIdentityUnavailable;
}

fn captureMacOSShortSnapshot(pid: std.posix.pid_t, unique: Darwin.ProcUniqueIdentifierInfo) !ProcessSnapshot {
    // Setuid executables can deny full BSD info while permitting the public
    // short form. It proves parent/liveness, but supplies no start timestamp.
    var info: Darwin.ProcBsdShortInfo = undefined;
    std.c._errno().* = 0;
    const read_len = Darwin.proc_pidinfo(pid, Darwin.proc_pid_short_bsd_info, 0, &info, @sizeOf(Darwin.ProcBsdShortInfo));
    try checkedDarwinRead(read_len, @sizeOf(Darwin.ProcBsdShortInfo), std.c._errno().*);
    var rechecked: Darwin.ProcUniqueIdentifierInfo = undefined;
    std.c._errno().* = 0;
    const rechecked_len = Darwin.proc_pidinfo(pid, Darwin.proc_pid_unique_identifier_info, 0, &rechecked, @sizeOf(Darwin.ProcUniqueIdentifierInfo));
    try checkedDarwinRead(rechecked_len, @sizeOf(Darwin.ProcUniqueIdentifierInfo), std.c._errno().*);
    return darwinShortSnapshot(pid, unique, info, rechecked);
}

fn darwinShortSnapshot(pid: std.posix.pid_t, unique: Darwin.ProcUniqueIdentifierInfo, info: Darwin.ProcBsdShortInfo, rechecked: Darwin.ProcUniqueIdentifierInfo) !ProcessSnapshot {
    if (info.pbsi_pid != pid or unique.p_uniqueid != rechecked.p_uniqueid or
        unique.p_puniqueid != rechecked.p_puniqueid or info.pbsi_ppid > std.math.maxInt(std.posix.pid_t))
        return error.ProcessIdentityUnavailable;
    return .{
        .identity = .{ .macos_unique_id = unique.p_uniqueid },
        .parent_pid = @intCast(info.pbsi_ppid),
        .parent_unique_id = unique.p_puniqueid,
        .zombie = info.pbsi_status == Darwin.process_status_zombie,
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

const Darwin = struct {
    // Stable libproc process-identity flavor; the SDK omits this constant from
    // its public header, but XNU defines the record as API with a fixed size.
    const proc_pid_unique_identifier_info: c_int = 17;
    const proc_pid_fd_pipe_info: c_int = 6;
    const proc_pid_short_bsd_info: c_int = 13;
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

    const ProcBsdShortInfo = extern struct {
        pbsi_pid: u32,
        pbsi_ppid: u32,
        pbsi_pgid: u32,
        pbsi_status: u32,
        pbsi_comm: [16]u8,
        pbsi_flags: u32,
        pbsi_uid: u32,
        pbsi_gid: u32,
        pbsi_ruid: u32,
        pbsi_rgid: u32,
        pbsi_svuid: u32,
        pbsi_svgid: u32,
        pbsi_rfu: u32,
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

test "Darwin adopted witness anchors identity after sender and child copies close" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var adopted = blk: {
        var original = try DarwinProcessWitness.init();
        defer original.deinit();
        const fd = std.c.fcntl(original.childFd(), std.posix.F.DUPFD_CLOEXEC, @as(c_int, 64));
        if (fd < 0) return error.DescriptorDuplicateFailed;
        const result = DarwinProcessWitness.fromOwnedChildFd(fd) catch |err| {
            closeFd(fd);
            return err;
        };
        break :blk result;
    };
    defer adopted.deinit();
    try std.testing.expectEqual(darwin_process_spawn.inherited_fd_target(adopted.childFd()), adopted.descendant_fd);
    for ([_]std.posix.fd_t{ adopted.childFd(), adopted.supervisor_fd.? }) |fd| {
        try std.testing.expect(std.c.fcntl(fd, std.posix.F.GETFD) & std.posix.FD_CLOEXEC != 0);
    }
    adopted.closeChildCopy();
    const actual = try captureDarwinPipeIdentity(std.c.getpid(), adopted.supervisor_fd.?);
    try std.testing.expectEqual(adopted.identity.handle, actual.handle);
    try std.testing.expectEqual(@as(u64, 0), actual.peer_handle);
    try std.testing.expect(adopted.identity.matchesAnchored(actual));
    try std.testing.expect(!adopted.identity.eql(actual));

    var state: SharedMembership = .{};
    var tracker = try Tracker.initShared(std.testing.allocator, &state);
    defer tracker.deinit();
    var bound = adopted;
    // This process is the probe target; address its actual anchor descriptor.
    bound.descendant_fd = adopted.supervisor_fd.?;
    tracker.bindProcessWitness(&bound);
    try tracker.refresh(std.c.getpid());
    try std.testing.expect(try tracker.processHasBoundWitness(std.c.getpid()));
}

test "anchored Darwin witness matching never accepts a different primary or live peer" {
    const identity: DarwinPipeIdentity = .{ .handle = 11, .peer_handle = 12 };
    try std.testing.expect(identity.matchesAnchored(.{ .handle = 11, .peer_handle = 12 }));
    try std.testing.expect(identity.matchesAnchored(.{ .handle = 11, .peer_handle = 0 }));
    try std.testing.expect(!identity.matchesAnchored(.{ .handle = 13, .peer_handle = 0 }));
    try std.testing.expect(!identity.matchesAnchored(.{ .handle = 11, .peer_handle = 13 }));
}

test "Darwin witness constructor failure preserves caller fd and closes duplicate" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var original = try DarwinProcessWitness.init();
    defer original.deinit();
    const expected_next = std.c.fcntl(original.childFd(), std.posix.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (expected_next < 0) return error.DescriptorDuplicateFailed;
    closeFd(expected_next);
    try std.testing.expectError(error.InvalidProcessWitness, DarwinProcessWitness.fromOwnedChildFd(original.supervisor_fd.?));
    try std.testing.expect(std.c.fcntl(original.supervisor_fd.?, std.posix.F.GETFD) >= 0);
    const next = std.c.fcntl(original.childFd(), std.posix.F.DUPFD_CLOEXEC, @as(c_int, 0));
    if (next < 0) return error.DescriptorDuplicateFailed;
    defer closeFd(next);
    try std.testing.expectEqual(expected_next, next);
}

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

fn testProcess(pid: std.posix.pid_t, instance: u64) TrackedProcess {
    return .{ .pid = pid, .identity = if (builtin.os.tag == .macos)
        .{ .macos_unique_id = instance }
    else
        .{ .linux_start_ticks = instance } };
}

fn testMembership() SharedMembership {
    var state: SharedMembership = .{};
    state.metadata.has_start = 1;
    state.metadata.started_at_us = 100;
    return state;
}

test "shared membership ignores unpublished root metadata and torn records" {
    var state: SharedMembership = .{};
    state.metadata.has_witness = 99;
    state.records[0].pid = 101;
    @atomicStore(u32, &state.scanning, 1, .release);
    try state.validate();
    try std.testing.expectEqual(null, state.rootPid());
    try std.testing.expect(!state.isComplete());
    var reader = try Tracker.initShared(std.testing.allocator, &state);
    defer reader.deinit();
    try std.testing.expectEqual(Liveness.incomplete, reader.scanLiveness());

    state.metadata = .{ .has_start = 1, .started_at_us = 100 };
    try state.append(testProcess(101, 1));
    state.records[1] = .{ .pid = -1, .kind = 999 };
    try state.validate();
    try std.testing.expectEqual(@as(?std.posix.pid_t, 101), state.rootPid());
    try std.testing.expectEqual(@as(usize, 0), reader.processCount());
    // Takeover after confirmed death preserves the incomplete discovery marker.
    try reader.beginScan();
    reader.endScan();
    try std.testing.expect(!state.isComplete());
    try std.testing.expectEqual(@as(usize, 1), try state.count());
}

test "shared membership rejects invalid headers bounds metadata and published records" {
    var state = testMembership();
    try state.append(testProcess(101, 1));
    inline for (.{ "version", "capacity", "committed", "scanning", "failed" }) |field| {
        const previous = @field(state, field);
        @field(state, field) = std.math.maxInt(u32);
        try std.testing.expectError(error.InvalidSharedMembership, state.validate());
        try std.testing.expectError(error.InvalidSharedMembership, Tracker.initShared(std.testing.allocator, &state));
        try std.testing.expect(!state.isComplete());
        @field(state, field) = previous;
    }
    state.magic = 0;
    try std.testing.expectError(error.InvalidSharedMembership, state.validate());
    state.magic = SharedMembership.magic_value;
    state.metadata.has_witness = 1;
    state.metadata.witness_fd = -1;
    try std.testing.expectError(error.InvalidSharedMembership, state.validate());
    state.metadata.has_witness = 0;
    var tracker = try Tracker.initShared(std.testing.allocator, &state);
    defer tracker.deinit();
    state.records[0].kind = 99;
    try std.testing.expectError(error.InvalidSharedMembership, state.validate());
    try std.testing.expectEqual(Liveness.incomplete, tracker.scanLiveness());
    const delivery = tracker.signalAllChecked(std.posix.SIG.KILL);
    try std.testing.expect(delivery.incomplete);
    try std.testing.expectEqual(@as(usize, 0), delivery.delivered);
}

test "shared membership cap fails explicitly without clearing committed ancestry" {
    var state = testMembership();
    for (0..SharedMembership.record_capacity) |index| {
        try state.append(testProcess(@intCast(index + 1), index));
    }
    try std.testing.expect(state.isComplete());
    const first = state.records[0];
    const last = state.records[SharedMembership.record_capacity - 1];
    try std.testing.expectError(error.SharedMembershipFull, state.append(testProcess(5000, 5000)));
    try std.testing.expect(!state.isComplete());
    try std.testing.expectEqual(@as(usize, 4096), try state.count());
    try std.testing.expectEqualDeep(first, state.records[0]);
    try std.testing.expectEqualDeep(last, state.records[4095]);
    var tracker = try Tracker.initShared(std.testing.allocator, &state);
    defer tracker.deinit();
    tracker.pruneExited();
    try std.testing.expectEqual(@as(usize, 4096), try state.count());
}

test "shared storage retains process instances while ordinary storage replaces reused pids" {
    var state = testMembership();
    try state.append(testProcess(101, 1));
    var shared = try Tracker.initShared(std.testing.allocator, &state);
    defer shared.deinit();
    var local = try Tracker.init(std.testing.allocator);
    defer local.deinit();
    for ([_]*Tracker{ &shared, &local }) |tracker| {
        try std.testing.expect(try tracker.remember(testProcess(102, 2)));
        try std.testing.expect(!try tracker.remember(testProcess(102, 2)));
        try std.testing.expect(try tracker.remember(testProcess(102, 3)));
    }
    try std.testing.expectEqual(@as(usize, 2), shared.processCount());
    try std.testing.expectEqual(@as(usize, 1), local.processCount());
    try std.testing.expect(shared.processAt(0).?.identity.eql(testProcess(102, 2).identity));
    try std.testing.expect(local.processAt(0).?.identity.eql(testProcess(102, 3).identity));
    try std.testing.expectEqual(@as(usize, 0), shared.processes.capacity);
    try std.testing.expectEqual(null, shared.root);
    if (builtin.os.tag == .macos) {
        try std.testing.expect(shared.containsMacOSUniqueId(2));
        try std.testing.expect(shared.containsMacOSUniqueId(3));
    }
}

test "shared root and Darwin witness survive tracker replacement without private copies" {
    var state: SharedMembership = .{};
    var writer = try Tracker.initShared(std.testing.allocator, &state);
    defer writer.deinit();
    var witness: ?DarwinProcessWitness = if (builtin.os.tag == .macos) try DarwinProcessWitness.init() else null;
    defer if (witness) |*value| value.deinit();
    if (witness) |*value| writer.bindProcessWitness(value);
    try writer.refresh(std.c.getpid());
    const root_before = state.records[0];
    const metadata_before = state.metadata;
    var replacement = try Tracker.initShared(std.testing.allocator, &state);
    defer replacement.deinit();
    try replacement.refresh(std.c.getpid());
    try std.testing.expectEqualDeep(root_before, state.records[0]);
    try std.testing.expectEqualDeep(metadata_before, state.metadata);
    try std.testing.expectEqual(null, replacement.root);
    try std.testing.expectEqual(null, replacement.darwin_process_witness);
    try std.testing.expectEqual(Liveness.alive, replacement.scanLiveness());
    try std.testing.expect(state.isComplete());
    if (witness) |value| {
        try std.testing.expectEqual(value.identity.handle, state.metadata.witness_handle);
        try std.testing.expectEqual(value.identity.peer_handle, state.metadata.witness_peer_handle);
        try std.testing.expectEqual(value.descendant_fd, state.metadata.witness_fd);
        var changed = value;
        changed.descendant_fd += 1;
        replacement.bindProcessWitness(&changed);
        try std.testing.expect(!state.isComplete());
        try std.testing.expectEqualDeep(metadata_before, state.metadata);
    }
}

test "checked liveness distinguishes empty live stale zombie and failed inspections" {
    const Effects = struct {
        fn capture(_: Allocator, pid: std.posix.pid_t) !ProcessSnapshot {
            if (pid == 1) return error.ProcessNotFound;
            if (pid == 5) return error.ProcessIdentityUnavailable;
            return .{
                .identity = testProcess(pid, if (pid == 2) 999 else @intCast(pid)).identity,
                .parent_pid = 1,
                .zombie = pid == 3,
            };
        }
    };
    var local = try Tracker.init(std.testing.allocator);
    defer local.deinit();
    try std.testing.expectEqual(Liveness.empty, local.scanLivenessWith(Effects));
    for (1..4) |pid| _ = try local.remember(testProcess(@intCast(pid), pid));
    try std.testing.expectEqual(Liveness.empty, local.scanLivenessWith(Effects));
    _ = try local.remember(testProcess(4, 4));
    try std.testing.expectEqual(Liveness.alive, local.scanLivenessWith(Effects));
    _ = try local.remember(testProcess(5, 5));
    try std.testing.expectEqual(Liveness.incomplete, local.scanLivenessWith(Effects));
    local.processes.clearRetainingCapacity();
    local.root = testProcess(std.c.getpid(), 999);
    // Existing anyAlive semantics still reject a stale local root.
    try std.testing.expect(!local.anyAlive());

    var state = testMembership();
    try state.append(testProcess(1, 1));
    var shared = try Tracker.initShared(std.testing.allocator, &state);
    defer shared.deinit();
    try std.testing.expectEqual(Liveness.empty, shared.scanLivenessWith(Effects));
    @atomicStore(u32, &state.scanning, 1, .release);
    try std.testing.expectEqual(Liveness.incomplete, shared.scanLivenessWith(Effects));
    try shared.beginScan();
    shared.endScan();
    try std.testing.expectEqual(Liveness.incomplete, shared.scanLivenessWith(Effects));
}

test "failed shared refresh cannot become a successful empty scan" {
    var state: SharedMembership = .{};
    var tracker = try Tracker.initShared(std.testing.allocator, &state);
    defer tracker.deinit();
    try std.testing.expectError(error.SharedRootUnavailable, tracker.refresh(0));
    try tracker.refresh(std.c.getpid());
    try std.testing.expect(!state.isComplete());
    try std.testing.expectEqual(Liveness.incomplete, tracker.scanLiveness());
    try std.testing.expectError(error.SharedRootMismatch, tracker.refresh(std.c.getpid() + 1));
}

test "lineage candidate inspection errors preserve known root and member failures" {
    const Unavailable = struct {
        fn capture(_: *Tracker, pid: std.posix.pid_t) !ProcessSnapshot {
            if (pid == 105) return error.OutOfMemory;
            return error.ProcessIdentityUnavailable;
        }
        fn hasWitness(_: *Tracker, _: std.posix.pid_t) !bool {
            return error.UnexpectedWitnessInspection;
        }
    };
    const Vanished = struct {
        fn capture(_: *Tracker, _: std.posix.pid_t) !ProcessSnapshot {
            return error.ProcessNotFound;
        }
        fn hasWitness(_: *Tracker, _: std.posix.pid_t) !bool {
            return error.UnexpectedWitnessInspection;
        }
    };
    var state = testMembership();
    try state.append(testProcess(101, 1));
    try state.append(testProcess(102, 2));
    var tracker = try Tracker.initShared(std.testing.allocator, &state);
    defer tracker.deinit();
    try std.testing.expect(!try tracker.trackLineageProcessWith(103, Unavailable));
    try std.testing.expectError(error.OutOfMemory, tracker.trackLineageProcessWith(105, Unavailable));
    for ([_]std.posix.pid_t{ 101, 102 }) |pid| {
        try std.testing.expectError(error.ProcessIdentityUnavailable, tracker.trackLineageProcessWith(pid, Unavailable));
        try std.testing.expect(!try tracker.trackLineageProcessWith(pid, Vanished));
    }
    try std.testing.expectEqual(@as(usize, 2), try state.count());
}

test "shared lineage admits short snapshots by committed parent identity only" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Short = struct {
        fn capture(_: *Tracker, pid: std.posix.pid_t) !ProcessSnapshot {
            var unique = std.mem.zeroes(Darwin.ProcUniqueIdentifierInfo);
            unique.p_uniqueid = @intCast(pid);
            unique.p_puniqueid = switch (pid) {
                101 => 1,
                103 => 2,
                else => 999,
            };
            var info = std.mem.zeroes(Darwin.ProcBsdShortInfo);
            info.pbsi_pid = @intCast(pid);
            // The owned parent has exited; the PID alone proves no ancestry.
            info.pbsi_ppid = 1;
            return darwinShortSnapshot(pid, unique, info, unique);
        }
        fn hasWitness(_: *Tracker, _: std.posix.pid_t) !bool {
            return error.UnexpectedWitnessInspection;
        }
    };
    var state = testMembership();
    try state.append(testProcess(101, 1));
    try state.append(testProcess(102, 2));
    var tracker = try Tracker.initShared(std.testing.allocator, &state);
    defer tracker.deinit();
    try std.testing.expectEqual(@as(?u64, 100), tracker.rootStartedAt());
    try std.testing.expectEqual(null, (try Short.capture(&tracker, 103)).started_at_us);
    try std.testing.expect(try tracker.trackLineageProcessWith(103, Short));
    try std.testing.expect(tracker.hasTrackedProcess(103, .{ .macos_unique_id = 103 }));
    try std.testing.expect(!try tracker.trackLineageProcessWith(103, Short));
    // A reused root PID is a distinct descendant instance, not the old root.
    try std.testing.expect(try tracker.trackLineageProcessWith(101, Short));
    try std.testing.expect(tracker.hasTrackedProcess(101, .{ .macos_unique_id = 1 }));
    try std.testing.expect(tracker.hasTrackedProcess(101, .{ .macos_unique_id = 101 }));
    try std.testing.expect(!try tracker.trackLineageProcessWith(104, Short));
    try std.testing.expect(!tracker.hasTrackedProcess(104, null));
    try std.testing.expectEqual(@as(usize, 4), try state.count());
    try std.testing.expect(state.isComplete());

    var ordinary = try Tracker.init(std.testing.allocator);
    defer ordinary.deinit();
    ordinary.root = testProcess(102, 2);
    ordinary.macos_root_started_at_us = 100;
    try std.testing.expect(!try ordinary.trackLineageProcessWith(103, Short));
    try std.testing.expectEqual(@as(usize, 0), ordinary.processCount());
}

test "lineage witness discovery ignores unowned and recycled candidates only" {
    const Unavailable = struct {
        fn capture(_: *Tracker, pid: std.posix.pid_t) !ProcessSnapshot {
            return .{
                .identity = testProcess(pid, @intCast(pid)).identity,
                .parent_pid = 999,
                .parent_unique_id = 999,
                .started_at_us = 200,
            };
        }
        fn hasWitness(_: *Tracker, _: std.posix.pid_t) !bool {
            return error.ProcessIdentityUnavailable;
        }
    };
    const Discoverable = struct {
        fn capture(tracker: *Tracker, pid: std.posix.pid_t) !ProcessSnapshot {
            return Unavailable.capture(tracker, pid);
        }
        fn hasWitness(_: *Tracker, _: std.posix.pid_t) !bool {
            return true;
        }
    };
    const Filtered = struct {
        fn capture(tracker: *Tracker, pid: std.posix.pid_t) !ProcessSnapshot {
            var snapshot = try Unavailable.capture(tracker, pid);
            snapshot.started_at_us = if (pid == 106) null else 99;
            return snapshot;
        }
        fn hasWitness(_: *Tracker, _: std.posix.pid_t) !bool {
            return error.UnexpectedWitnessInspection;
        }
    };
    var state = testMembership();
    try state.append(testProcess(101, 101));
    try state.append(testProcess(102, 102));
    try state.append(testProcess(104, 1));
    var tracker = try Tracker.initShared(std.testing.allocator, &state);
    defer tracker.deinit();
    try std.testing.expect(!try tracker.trackLineageProcessWith(103, Unavailable));
    try std.testing.expect(!try tracker.trackLineageProcessWith(104, Unavailable));
    for ([_]std.posix.pid_t{ 106, 107 }) |pid| {
        try std.testing.expect(!try tracker.trackLineageProcessWith(pid, Filtered));
        try std.testing.expect(!tracker.hasTrackedProcess(pid, null));
    }
    for ([_]std.posix.pid_t{ 101, 102 }) |pid| {
        try std.testing.expectError(error.ProcessIdentityUnavailable, tracker.trackLineageProcessWith(pid, Unavailable));
    }
    try std.testing.expectEqual(@as(usize, 3), try state.count());
    try std.testing.expect(try tracker.trackLineageProcessWith(103, Discoverable));
    try std.testing.expect(!try tracker.trackLineageProcessWith(103, Discoverable));
    try std.testing.expectEqual(@as(usize, 4), try state.count());
}

test "Darwin short snapshots reject failed reads reused identities and changed parents" {
    try checkedDarwinRead(64, 64, 0);
    try std.testing.expectError(error.ProcessNotFound, checkedDarwinRead(0, 64, @intFromEnum(std.c.E.SRCH)));
    for ([_]c_int{ 0, @intFromEnum(std.c.E.PERM), @intFromEnum(std.c.E.ACCES) }) |err| {
        try std.testing.expectError(error.ProcessIdentityUnavailable, checkedDarwinRead(0, 64, err));
    }
    try std.testing.expectError(error.ProcessIdentityUnavailable, checkedDarwinRead(32, 64, 0));
    var unique = std.mem.zeroes(Darwin.ProcUniqueIdentifierInfo);
    unique.p_uniqueid = 100;
    unique.p_puniqueid = 90;
    var info = std.mem.zeroes(Darwin.ProcBsdShortInfo);
    info.pbsi_pid = 42;
    info.pbsi_ppid = 41;
    const snapshot = try darwinShortSnapshot(42, unique, info, unique);
    try std.testing.expect(snapshot.identity.eql(.{ .macos_unique_id = 100 }));
    try std.testing.expect(snapshot.started_at_us == null);
    try std.testing.expectEqual(@as(std.posix.pid_t, 41), snapshot.parent_pid);
    try std.testing.expect(!snapshot.zombie);
    try std.testing.expectError(error.ProcessIdentityUnavailable, darwinShortSnapshot(43, unique, info, unique));
    var changed = unique;
    changed.p_uniqueid += 1;
    try std.testing.expectError(error.ProcessIdentityUnavailable, darwinShortSnapshot(42, unique, info, changed));
    changed = unique;
    changed.p_puniqueid += 1;
    try std.testing.expectError(error.ProcessIdentityUnavailable, darwinShortSnapshot(42, unique, info, changed));
    info.pbsi_status = Darwin.process_status_zombie;
    try std.testing.expect((try darwinShortSnapshot(42, unique, info, unique)).zombie);
}

test "Darwin checked tracker inspects an owned setuid ps child without full BSD access" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = io_mod.getIo();
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/ps", "-p", "1", "-o", "pid=" },
        .start_suspended = true,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);
    const pid = child.id.?;
    var full: Darwin.ProcBsdInfo = undefined;
    std.c._errno().* = 0;
    const full_len = Darwin.proc_pidinfo(pid, 3, 0, &full, @sizeOf(Darwin.ProcBsdInfo));
    // Root-run hosts and SDKs without setuid ps do not exercise this boundary.
    if (full_len != 0 or std.c._errno().* != @intFromEnum(std.c.E.PERM)) return error.SkipZigTest;
    const snapshot = try captureSnapshotChecked(std.testing.allocator, pid);
    try std.testing.expectEqual(std.c.getpid(), snapshot.parent_pid);
    try std.testing.expect(!snapshot.zombie);
    var state: SharedMembership = .{};
    var tracker = try Tracker.initShared(std.testing.allocator, &state);
    defer tracker.deinit();
    try tracker.refresh(std.c.getpid());
    try std.testing.expect(tracker.hasTrackedProcess(pid, snapshot.identity));
    try std.testing.expect(state.isComplete());
    // A second refresh exercises the committed member, not just discovery.
    try tracker.refresh(std.c.getpid());
    try std.testing.expect(state.isComplete());
    try std.posix.kill(pid, std.posix.SIG.CONT);
    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
    try tracker.refresh(std.c.getpid());
    try std.testing.expect(state.isComplete());
}

test "Darwin known root and member inspection failures remain sticky during refresh" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // launchd is stable but protected for ordinary users. Root-run hosts may
    // inspect it; deterministic candidate error coverage above still applies.
    if (captureSnapshotChecked(std.testing.allocator, 1)) |_| {
        return error.SkipZigTest;
    } else |err| if (err != error.ProcessIdentityUnavailable) return err;
    var state = testMembership();
    try state.append(testProcess(1, 1));
    var tracker = try Tracker.initShared(std.testing.allocator, &state);
    defer tracker.deinit();
    try std.testing.expectError(error.ProcessIdentityUnavailable, tracker.refresh(1));
    try std.testing.expect(!state.isComplete());

    var member_state: SharedMembership = .{};
    var member_tracker = try Tracker.initShared(std.testing.allocator, &member_state);
    defer member_tracker.deinit();
    try member_tracker.refresh(std.c.getpid());
    try member_state.append(testProcess(1, 1));
    try std.testing.expectError(error.ProcessIdentityUnavailable, member_tracker.refresh(std.c.getpid()));
    try std.testing.expect(!member_state.isComplete());
    try std.testing.expectError(error.ProcessIdentityUnavailable, member_tracker.refreshLineageProcesses());
    try std.testing.expectEqual(Liveness.incomplete, member_tracker.scanLiveness());
}

test "Darwin lineage refresh after owned root exit ignores unrelated inspection failures" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const io = io_mod.getIo();
    var child = try std.process.spawn(io, .{
        .argv = &.{"/usr/bin/true"},
        .start_suspended = true,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);
    const root_pid = child.id.?;
    var state: SharedMembership = .{};
    var tracker = try Tracker.initShared(std.testing.allocator, &state);
    defer tracker.deinit();
    try tracker.refresh(root_pid);
    try std.testing.expect(state.isComplete());
    try std.posix.kill(root_pid, std.posix.SIG.CONT);
    try std.testing.expectEqualDeep(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
    try tracker.refresh(root_pid);
    try std.testing.expect(state.isComplete());
    try std.testing.expectEqual(Liveness.empty, tracker.scanLiveness());
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
