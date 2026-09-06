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
        if (comptime builtin.os.tag == .macos) {
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
        if (comptime builtin.os.tag != .macos) return;
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
        var index = self.processes.items.len;
        while (index > 0) {
            index -= 1;
            self.signalTrackedProcessWith(
                self.processes.items[index],
                signal,
                preserved_group,
                &summary,
                Effects,
            );
        }
        if (self.root) |root| {
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
        var task_dir = (try openLinuxProcDir(task_path)) orelse return;
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
        if (comptime builtin.os.tag != .macos) return error.ProcessTreeUnsupported;
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
        if (comptime builtin.os.tag != .macos) return false;
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
    if (comptime builtin.os.tag != .macos) return error.ProcessTreeUnsupported;
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

fn captureMacOSSnapshot(pid: std.posix.pid_t) !ProcessSnapshot {
    if (comptime builtin.os.tag != .macos) return error.ProcessTreeUnsupported;
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

const Darwin = struct {
    // Stable libproc process-identity flavor; the SDK omits this constant from
    // its public header, but XNU defines the record as API with a fixed size.
    const proc_pid_unique_identifier_info: c_int = 17;
    const proc_pid_fd_pipe_info: c_int = 6;
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
