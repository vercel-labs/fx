const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const session_child_store = @import("../session/session_child_store.zig");

pub const BackgroundLaunchPolicy = enum {
    process_local_long_lived,
    durable_long_lived,
    saved_headless,
};

pub const StableBackgroundRecordId = types.StableBackgroundRecordId;

pub const ProcessInstanceToken = struct {
    bytes: [128]u8 = undefined,
    len: u8 = 0,

    pub fn parse(text: []const u8) !ProcessInstanceToken {
        if (text.len == 0 or text.len > 128) {
            return error.InvalidProcessInstanceToken;
        }
        for (text) |byte| {
            if (!std.ascii.isAscii(byte) or std.ascii.isUpper(byte) or
                std.ascii.isWhitespace(byte) or
                std.ascii.isControl(byte))
            {
                return error.InvalidProcessInstanceToken;
            }
        }
        var parts = std.mem.splitScalar(u8, text, ':');
        const platform = parts.next() orelse
            return error.InvalidProcessInstanceToken;
        const boot_id = parts.next() orelse
            return error.InvalidProcessInstanceToken;
        if (!isLowerHex(boot_id, 32)) {
            return error.InvalidProcessInstanceToken;
        }
        if (std.mem.eql(u8, platform, "linux")) {
            const start_ticks = parts.next() orelse
                return error.InvalidProcessInstanceToken;
            if (parts.next() != null or
                !isCanonicalDecimal(start_ticks))
            {
                return error.InvalidProcessInstanceToken;
            }
        } else if (std.mem.eql(u8, platform, "macos")) {
            const start_sec = parts.next() orelse
                return error.InvalidProcessInstanceToken;
            const start_usec = parts.next() orelse
                return error.InvalidProcessInstanceToken;
            if (parts.next() != null or
                !isCanonicalDecimal(start_sec) or
                !isCanonicalDecimal(start_usec))
            {
                return error.InvalidProcessInstanceToken;
            }
        } else {
            return error.InvalidProcessInstanceToken;
        }
        var token = ProcessInstanceToken{};
        @memcpy(token.bytes[0..text.len], text);
        token.len = @intCast(text.len);
        return token;
    }

    pub fn view(self: *const ProcessInstanceToken) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: ProcessInstanceToken, other: ProcessInstanceToken) bool {
        return std.mem.eql(u8, self.view(), other.view());
    }
};

fn isLowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and
            (byte < 'a' or byte > 'f'))
        {
            return false;
        }
    }
    return true;
}

fn isCanonicalDecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value.len > 1 and value[0] == '0') return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    _ = std.fmt.parseInt(u64, value, 10) catch return false;
    return true;
}

pub const TokenMatch = enum {
    matched,
    missing,
    mismatched,
    unavailable,
};

pub var process_token_match_for_test: ?*const fn ([]const u8, ProcessInstanceToken) TokenMatch = null;
pub var process_token_capture_for_test: ?*const fn (
    std.mem.Allocator,
    []const u8,
) anyerror!ProcessInstanceToken = null;

pub const RecordAuthority = union(enum) {
    none,
    read_only: *session_child_store.SessionChildCapability,
    writable: *session_child_store.SessionChildCapability,
};

pub fn captureProcessInstanceToken(
    alloc: std.mem.Allocator,
    pid_text: []const u8,
) !ProcessInstanceToken {
    if (process_token_capture_for_test) |callback| {
        return callback(alloc, pid_text);
    }
    return error.ProcessIdentityUnsupported;
}

pub fn matchProcessInstanceToken(
    alloc: std.mem.Allocator,
    pid_text: []const u8,
    expected: ProcessInstanceToken,
) TokenMatch {
    if (process_token_match_for_test) |callback| {
        return callback(pid_text, expected);
    }
    const actual = captureProcessInstanceToken(alloc, pid_text) catch |err| {
        return switch (err) {
            error.ProcessNotFound => .missing,
            else => .unavailable,
        };
    };
    return if (actual.eql(expected)) .matched else .mismatched;
}

pub const BackgroundRegistration = struct {
    display_id: ?u64 = null,
    pid: []const u8,
    process_token: ?ProcessInstanceToken = null,
    policy: BackgroundLaunchPolicy = .process_local_long_lived,
    source_session_id: ?[]const u8 = null,
    background_record_id: ?StableBackgroundRecordId = null,
    durable_record_id: ?u64 = null,
    record_authority: RecordAuthority = .none,
    managed_log_name: ?[]const u8 = null,
    command: []const u8,
    cwd: []const u8,
    log_path: []const u8,
    expect_url: bool,
    url: ?[]const u8 = null,
};

pub const TaskState = enum {
    running,
    exited,
    failed,
    stopped,
    dead,
    stale,
};

pub const RecordPersistenceState = enum {
    not_applicable,
    confirmed,
    initial_record_degraded,
    record_update_degraded,
};

pub const TaskCompletion = struct {
    id: u64,
    state: TaskState,
    exit_code: ?i32,
};

pub const TaskRecord = struct {
    id: u64,
    pid: []u8,
    process_token: ?ProcessInstanceToken = null,
    policy: BackgroundLaunchPolicy = .process_local_long_lived,
    source_session_id: ?[]u8 = null,
    background_record_id: ?StableBackgroundRecordId = null,
    durable_record_id: ?u64 = null,
    record_authority: RecordAuthority = .none,
    record_persistence: RecordPersistenceState = .not_applicable,
    record_warning_emitted: bool = false,
    managed_log_name: ?[]u8 = null,
    command: []u8,
    cwd: []u8,
    log_path: []u8,
    expect_url: bool,
    server_url: ?[]u8 = null,
    started_at_ms: i64,
    exit_code: ?i32 = null,
    state: TaskState = .running,

    pub fn deinit(self: *TaskRecord, alloc: std.mem.Allocator) void {
        alloc.free(self.pid);
        if (self.source_session_id) |source_session_id| {
            alloc.free(source_session_id);
        }
        if (self.managed_log_name) |managed_log_name| {
            alloc.free(managed_log_name);
        }
        alloc.free(self.command);
        alloc.free(self.cwd);
        alloc.free(self.log_path);
        if (self.server_url) |url| alloc.free(url);
    }
};

pub const RuntimeContextSnapshot = struct {
    process_id: ?u64 = null,
    background_log_path: ?[]u8 = null,
    background_expect_url: bool = false,
    server_url: ?[]u8 = null,
    tasks: []TaskSnapshot = &.{},

    pub fn deinit(self: RuntimeContextSnapshot, alloc: std.mem.Allocator) void {
        if (self.background_log_path) |log_path| alloc.free(log_path);
        if (self.server_url) |url| alloc.free(url);
        for (self.tasks) |task| task.deinit(alloc);
        if (self.tasks.len > 0) alloc.free(self.tasks);
    }
};

pub const PublishServerUrlResult = enum {
    updated,
    stale,
    duplicate,
};

pub const TaskSnapshot = struct {
    id: u64,
    pid: []u8,
    process_token: ?ProcessInstanceToken = null,
    policy: BackgroundLaunchPolicy = .process_local_long_lived,
    source_session_id: ?[]u8 = null,
    background_record_id: ?StableBackgroundRecordId = null,
    durable_record_id: ?u64 = null,
    record_authority: RecordAuthority = .none,
    record_persistence: RecordPersistenceState = .not_applicable,
    managed_log_name: ?[]u8 = null,
    command: []u8,
    cwd: []u8,
    log_path: []u8,
    expect_url: bool,
    server_url: ?[]u8 = null,
    started_at_ms: i64,
    exit_code: ?i32 = null,
    state: TaskState,

    pub fn deinit(self: TaskSnapshot, alloc: std.mem.Allocator) void {
        alloc.free(self.pid);
        if (self.source_session_id) |source_session_id| {
            alloc.free(source_session_id);
        }
        if (self.managed_log_name) |managed_log_name| {
            alloc.free(managed_log_name);
        }
        alloc.free(self.command);
        alloc.free(self.cwd);
        alloc.free(self.log_path);
        if (self.server_url) |url| alloc.free(url);
    }
};

pub const TaskListSnapshot = struct {
    items: []TaskSnapshot,

    pub fn deinit(self: TaskListSnapshot, alloc: std.mem.Allocator) void {
        for (self.items) |item| item.deinit(alloc);
        alloc.free(self.items);
    }
};

pub const TaskSelection = union(enum) {
    last,
    id: u64,
};

pub const StopSelection = TaskSelection;

pub const StopCandidate = struct {
    id: u64,
    pid: []u8,
    process_token: ?ProcessInstanceToken,
};

pub const ProcessSupervisor = struct {
    next_background_process_id: u64 = 1,
    display_id_exhausted: bool = false,
    reserved_display_ids: std.ArrayList(u64) = .empty,
    tasks: std.ArrayList(TaskRecord) = .empty,

    pub fn deinit(self: *ProcessSupervisor, alloc: std.mem.Allocator) void {
        for (self.tasks.items) |*task| task.deinit(alloc);
        self.tasks.deinit(alloc);
        self.reserved_display_ids.deinit(std.heap.c_allocator);
        self.* = .{};
    }

    pub fn reserveDisplayId(self: *ProcessSupervisor) !u64 {
        if (self.display_id_exhausted) return error.BackgroundIdentityUnavailable;
        var candidate = self.next_background_process_id;
        while (self.displayIdReserved(candidate)) {
            if (candidate == std.math.maxInt(u64)) {
                self.display_id_exhausted = true;
                return error.BackgroundIdentityUnavailable;
            }
            candidate += 1;
        }
        try self.reserved_display_ids.append(std.heap.c_allocator, candidate);
        if (candidate == std.math.maxInt(u64)) {
            self.display_id_exhausted = true;
        } else {
            self.next_background_process_id = candidate + 1;
        }
        return candidate;
    }

    pub fn reservePreferredDisplayId(
        self: *ProcessSupervisor,
        preferred: u64,
    ) !u64 {
        if (!self.displayIdReserved(preferred)) {
            try self.reserved_display_ids.append(std.heap.c_allocator, preferred);
            if (!self.display_id_exhausted and
                preferred >= self.next_background_process_id)
            {
                if (preferred == std.math.maxInt(u64)) {
                    self.display_id_exhausted = true;
                } else {
                    self.next_background_process_id = preferred + 1;
                }
            }
            return preferred;
        }
        return self.reserveDisplayId();
    }

    pub fn releaseDisplayId(self: *ProcessSupervisor, display_id: u64) void {
        for (self.reserved_display_ids.items, 0..) |reserved, index| {
            if (reserved != display_id) continue;
            _ = self.reserved_display_ids.orderedRemove(index);
            return;
        }
    }

    pub fn retainDisplayIdReservation(
        self: *ProcessSupervisor,
        display_id: u64,
    ) void {
        if (self.displayIdReserved(display_id)) return;
        self.reserved_display_ids.appendAssumeCapacity(display_id);
    }

    fn displayIdReserved(self: *const ProcessSupervisor, display_id: u64) bool {
        for (self.reserved_display_ids.items) |reserved| {
            if (reserved == display_id) return true;
        }
        for (self.tasks.items) |task| {
            if (task.id == display_id) return true;
        }
        return false;
    }

    pub fn registerBackground(self: *ProcessSupervisor, alloc: std.mem.Allocator, registration: BackgroundRegistration) !u64 {
        const process_id = if (registration.display_id) |reserved| blk: {
            var found = false;
            for (self.reserved_display_ids.items) |id| {
                if (id == reserved) found = true;
            }
            if (!found) return error.BackgroundIdentityUnavailable;
            break :blk reserved;
        } else try self.reserveDisplayId();
        errdefer self.releaseDisplayId(process_id);

        const pid = try alloc.dupe(u8, registration.pid);
        errdefer alloc.free(pid);
        const command = try alloc.dupe(u8, registration.command);
        errdefer alloc.free(command);
        const cwd = try alloc.dupe(u8, registration.cwd);
        errdefer alloc.free(cwd);
        const log_path = try alloc.dupe(u8, registration.log_path);
        errdefer alloc.free(log_path);

        var server_url: ?[]u8 = null;
        errdefer if (server_url) |url| alloc.free(url);
        if (registration.url) |url| {
            server_url = try alloc.dupe(u8, url);
        }

        var source_session_id: ?[]u8 = null;
        errdefer if (source_session_id) |value| alloc.free(value);
        if (registration.source_session_id) |value| {
            source_session_id = try alloc.dupe(u8, value);
        }
        var managed_log_name: ?[]u8 = null;
        errdefer if (managed_log_name) |value| alloc.free(value);
        if (registration.managed_log_name) |value| {
            managed_log_name = try alloc.dupe(u8, value);
        }

        try self.tasks.append(alloc, .{
            .id = process_id,
            .pid = pid,
            .process_token = registration.process_token,
            .policy = registration.policy,
            .source_session_id = source_session_id,
            .background_record_id = registration.background_record_id,
            .durable_record_id = registration.durable_record_id orelse
                if (registration.background_record_id != null)
                    process_id
                else
                    null,
            .record_authority = registration.record_authority,
            .record_persistence = if (registration.background_record_id != null)
                .confirmed
            else
                .not_applicable,
            .managed_log_name = managed_log_name,
            .command = command,
            .cwd = cwd,
            .log_path = log_path,
            .expect_url = registration.expect_url,
            .server_url = server_url,
            .started_at_ms = io_mod.milliTimestamp(),
        });
        self.releaseDisplayId(process_id);

        return process_id;
    }

    pub fn restoreBackground(
        self: *ProcessSupervisor,
        alloc: std.mem.Allocator,
        task_snapshot: TaskSnapshot,
    ) !u64 {
        const process_id = try self.reservePreferredDisplayId(
            task_snapshot.id,
        );
        errdefer self.releaseDisplayId(process_id);

        const pid = try alloc.dupe(u8, task_snapshot.pid);
        errdefer alloc.free(pid);
        const command = try alloc.dupe(u8, task_snapshot.command);
        errdefer alloc.free(command);
        const cwd = try alloc.dupe(u8, task_snapshot.cwd);
        errdefer alloc.free(cwd);
        const log_path = try alloc.dupe(u8, task_snapshot.log_path);
        errdefer alloc.free(log_path);

        var server_url: ?[]u8 = null;
        errdefer if (server_url) |url| alloc.free(url);
        if (task_snapshot.server_url) |url| {
            server_url = try alloc.dupe(u8, url);
        }
        var source_session_id: ?[]u8 = null;
        errdefer if (source_session_id) |value| alloc.free(value);
        if (task_snapshot.source_session_id) |value| {
            source_session_id = try alloc.dupe(u8, value);
        }
        var managed_log_name: ?[]u8 = null;
        errdefer if (managed_log_name) |value| alloc.free(value);
        if (task_snapshot.managed_log_name) |value| {
            managed_log_name = try alloc.dupe(u8, value);
        }

        try self.tasks.append(alloc, .{
            .id = process_id,
            .pid = pid,
            .process_token = task_snapshot.process_token,
            .policy = task_snapshot.policy,
            .source_session_id = source_session_id,
            .background_record_id = task_snapshot.background_record_id,
            .durable_record_id = task_snapshot.durable_record_id,
            .record_authority = task_snapshot.record_authority,
            .record_persistence = task_snapshot.record_persistence,
            .managed_log_name = managed_log_name,
            .command = command,
            .cwd = cwd,
            .log_path = log_path,
            .expect_url = task_snapshot.expect_url,
            .server_url = server_url,
            .started_at_ms = task_snapshot.started_at_ms,
            .exit_code = task_snapshot.exit_code,
            .state = task_snapshot.state,
        });
        self.releaseDisplayId(process_id);
        return process_id;
    }

    pub fn restoreBackgroundAsNew(self: *ProcessSupervisor, alloc: std.mem.Allocator, task_snapshot: TaskSnapshot) !u64 {
        const process_id = try self.reserveDisplayId();
        errdefer self.releaseDisplayId(process_id);

        const pid = try alloc.dupe(u8, task_snapshot.pid);
        errdefer alloc.free(pid);
        const command = try alloc.dupe(u8, task_snapshot.command);
        errdefer alloc.free(command);
        const cwd = try alloc.dupe(u8, task_snapshot.cwd);
        errdefer alloc.free(cwd);
        const log_path = try alloc.dupe(u8, task_snapshot.log_path);
        errdefer alloc.free(log_path);

        var server_url: ?[]u8 = null;
        errdefer if (server_url) |url| alloc.free(url);
        if (task_snapshot.server_url) |url| {
            server_url = try alloc.dupe(u8, url);
        }
        var source_session_id: ?[]u8 = null;
        errdefer if (source_session_id) |value| alloc.free(value);
        if (task_snapshot.source_session_id) |value| {
            source_session_id = try alloc.dupe(u8, value);
        }
        var managed_log_name: ?[]u8 = null;
        errdefer if (managed_log_name) |value| alloc.free(value);
        if (task_snapshot.managed_log_name) |value| {
            managed_log_name = try alloc.dupe(u8, value);
        }

        try self.tasks.append(alloc, .{
            .id = process_id,
            .pid = pid,
            .process_token = task_snapshot.process_token,
            .policy = task_snapshot.policy,
            .source_session_id = source_session_id,
            .background_record_id = task_snapshot.background_record_id,
            .durable_record_id = task_snapshot.durable_record_id,
            .record_authority = task_snapshot.record_authority,
            .record_persistence = task_snapshot.record_persistence,
            .managed_log_name = managed_log_name,
            .command = command,
            .cwd = cwd,
            .log_path = log_path,
            .expect_url = task_snapshot.expect_url,
            .server_url = server_url,
            .started_at_ms = task_snapshot.started_at_ms,
            .exit_code = task_snapshot.exit_code,
            .state = task_snapshot.state,
        });
        self.releaseDisplayId(process_id);

        return process_id;
    }

    pub fn snapshot(self: *const ProcessSupervisor, alloc: std.mem.Allocator) !RuntimeContextSnapshot {
        var running_count: usize = 0;
        for (self.tasks.items) |task| {
            if (task.state == .running) running_count += 1;
        }
        if (running_count == 0) return .{};

        const items = try alloc.alloc(TaskSnapshot, running_count);
        errdefer alloc.free(items);

        var copied: usize = 0;
        errdefer {
            var j: usize = 0;
            while (j < copied) : (j += 1) items[j].deinit(alloc);
        }

        for (self.tasks.items) |task| {
            if (task.state != .running) continue;
            items[copied] = try copyTaskSnapshot(alloc, task);
            copied += 1;
        }

        var i = self.tasks.items.len;
        while (i > 0) {
            i -= 1;
            const task = self.tasks.items[i];
            if (task.state != .running) continue;

            const log_path = try alloc.dupe(u8, task.log_path);
            errdefer alloc.free(log_path);
            var server_url: ?[]u8 = null;
            errdefer if (server_url) |url| alloc.free(url);
            if (task.server_url) |url| {
                server_url = try alloc.dupe(u8, url);
            }

            return .{
                .process_id = task.id,
                .background_log_path = log_path,
                .background_expect_url = task.expect_url,
                .server_url = server_url,
                .tasks = items,
            };
        }

        unreachable;
    }

    pub fn snapshotServerUrl(self: *const ProcessSupervisor, alloc: std.mem.Allocator, process_id: u64) !?[]u8 {
        const task = self.findTask(process_id) orelse return null;
        if (task.state != .running) return null;
        const url = task.server_url orelse return null;
        return try alloc.dupe(u8, url);
    }

    pub fn publishServerUrl(self: *ProcessSupervisor, alloc: std.mem.Allocator, process_id: u64, url: []u8) PublishServerUrlResult {
        const task = self.findTaskMutable(process_id) orelse {
            alloc.free(url);
            return .stale;
        };

        if (task.state != .running) {
            alloc.free(url);
            return .stale;
        }

        if (task.server_url) |existing| {
            if (std.mem.eql(u8, existing, url)) {
                alloc.free(url);
                return .duplicate;
            }
            alloc.free(existing);
        }

        task.server_url = url;
        task.expect_url = false;
        return .updated;
    }

    pub fn snapshotTasks(self: *const ProcessSupervisor, alloc: std.mem.Allocator) !TaskListSnapshot {
        const items = try alloc.alloc(TaskSnapshot, self.tasks.items.len);
        errdefer alloc.free(items);

        var copied: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < copied) : (i += 1) items[i].deinit(alloc);
        }

        for (self.tasks.items, 0..) |task, i| {
            items[i] = try copyTaskSnapshot(alloc, task);
            copied += 1;
        }

        return .{ .items = items };
    }

    pub fn stopCandidate(self: *const ProcessSupervisor, alloc: std.mem.Allocator, selection: StopSelection) !?StopCandidate {
        const task = self.findSelectedRunningTask(selection) orelse return null;

        return .{
            .id = task.id,
            .pid = try alloc.dupe(u8, task.pid),
            .process_token = task.process_token,
        };
    }

    pub fn snapshotTask(self: *const ProcessSupervisor, alloc: std.mem.Allocator, selection: TaskSelection) !?TaskSnapshot {
        const task = switch (selection) {
            .last => self.findLastTask() orelse return null,
            .id => |id| self.findTask(id) orelse return null,
        };

        return try copyTaskSnapshot(alloc, task);
    }

    pub fn markStopped(self: *ProcessSupervisor, process_id: u64) bool {
        const task = self.findTaskMutable(process_id) orelse return false;
        task.state = .stopped;
        task.expect_url = false;
        task.exit_code = null;
        return true;
    }

    pub fn markCompleted(self: *ProcessSupervisor, process_id: u64, exit_code: ?i32) ?TaskCompletion {
        const task = self.findTaskMutable(process_id) orelse return null;
        if (task.state != .running) return null;

        task.expect_url = false;
        task.exit_code = exit_code;
        task.state = if (exit_code) |code|
            if (code == 0) .exited else .failed
        else
            .dead;

        return .{ .id = task.id, .state = task.state, .exit_code = task.exit_code };
    }

    pub fn markDead(self: *ProcessSupervisor, process_id: u64) ?TaskCompletion {
        const task = self.findTaskMutable(process_id) orelse return null;
        if (task.state != .running) return null;

        task.expect_url = false;
        task.exit_code = null;
        task.state = .dead;
        return .{ .id = task.id, .state = task.state, .exit_code = task.exit_code };
    }

    pub fn markStale(self: *ProcessSupervisor, process_id: u64) ?TaskCompletion {
        const task = self.findTaskMutable(process_id) orelse return null;
        if (task.state != .running) return null;

        task.expect_url = false;
        task.exit_code = null;
        task.state = .stale;
        return .{ .id = task.id, .state = task.state, .exit_code = task.exit_code };
    }

    pub fn setRecordPersistence(
        self: *ProcessSupervisor,
        process_id: u64,
        state: RecordPersistenceState,
        warning_emitted: bool,
    ) bool {
        const task = self.findTaskMutable(process_id) orelse return false;
        task.record_persistence = state;
        task.record_warning_emitted = warning_emitted;
        return true;
    }

    pub fn markRecordDegraded(
        self: *ProcessSupervisor,
        process_id: u64,
        state: RecordPersistenceState,
    ) bool {
        const task = self.findTaskMutable(process_id) orelse return false;
        if (task.background_record_id == null) return false;
        const should_warn = !task.record_warning_emitted;
        task.record_persistence = state;
        task.record_warning_emitted = true;
        return should_warn;
    }

    pub fn markRecordProjectionDegraded(
        self: *ProcessSupervisor,
        process_id: u64,
    ) bool {
        const task = self.findTaskMutable(process_id) orelse return false;
        if (task.background_record_id == null) return false;
        task.record_persistence = .record_update_degraded;
        return true;
    }

    pub fn findReusableRunningTask(self: *const ProcessSupervisor, alloc: std.mem.Allocator, cwd: []const u8, command: []const u8, expect_url: bool) !?TaskSnapshot {
        _ = expect_url;
        var i = self.tasks.items.len;
        while (i > 0) {
            i -= 1;
            const task = self.tasks.items[i];
            if (task.state != .running) continue;
            if (!std.mem.eql(u8, task.cwd, cwd)) continue;
            if (!commandsEquivalent(task.command, command)) continue;
            return try copyTaskSnapshot(alloc, task);
        }
        return null;
    }

    pub fn snapshotTaskByLogPath(self: *const ProcessSupervisor, alloc: std.mem.Allocator, log_path: []const u8) !?TaskSnapshot {
        var i = self.tasks.items.len;
        while (i > 0) {
            i -= 1;
            const task = self.tasks.items[i];
            if (!std.mem.eql(u8, task.log_path, log_path)) continue;
            return try copyTaskSnapshot(alloc, task);
        }
        return null;
    }

    pub fn removeWorkspaceTasks(self: *ProcessSupervisor, alloc: std.mem.Allocator, workspace_root: []const u8) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            if (taskBelongsToWorkspace(self.tasks.items[i], workspace_root)) {
                var task = self.tasks.orderedRemove(i);
                task.deinit(alloc);
                removed += 1;
                continue;
            }
            i += 1;
        }
        return removed;
    }

    pub fn removeTask(
        self: *ProcessSupervisor,
        alloc: std.mem.Allocator,
        process_id: u64,
    ) bool {
        for (self.tasks.items, 0..) |task, index| {
            if (task.id != process_id) continue;
            var removed = self.tasks.orderedRemove(index);
            removed.deinit(alloc);
            return true;
        }
        return false;
    }

    fn findTask(self: *const ProcessSupervisor, process_id: u64) ?TaskRecord {
        for (self.tasks.items) |task| {
            if (task.id == process_id) return task;
        }
        return null;
    }

    fn findTaskMutable(self: *ProcessSupervisor, process_id: u64) ?*TaskRecord {
        for (self.tasks.items) |*task| {
            if (task.id == process_id) return task;
        }
        return null;
    }

    fn findLastRunningTask(self: *const ProcessSupervisor) ?TaskRecord {
        var i = self.tasks.items.len;
        while (i > 0) {
            i -= 1;
            const task = self.tasks.items[i];
            if (task.state == .running) return task;
        }
        return null;
    }

    fn findLastTask(self: *const ProcessSupervisor) ?TaskRecord {
        if (self.tasks.items.len == 0) return null;
        return self.tasks.items[self.tasks.items.len - 1];
    }

    fn findSelectedRunningTask(self: *const ProcessSupervisor, selection: TaskSelection) ?TaskRecord {
        return switch (selection) {
            .last => self.findLastRunningTask(),
            .id => |id| blk: {
                const found = self.findTask(id) orelse return null;
                if (found.state != .running) return null;
                break :blk found;
            },
        };
    }
};

fn commandsEquivalent(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, normalizeCommand(a), normalizeCommand(b));
}

fn normalizeCommand(command: []const u8) []const u8 {
    return std.mem.trim(u8, command, " \t\r\n");
}

fn taskBelongsToWorkspace(task: TaskRecord, workspace_root: []const u8) bool {
    return pathBelongsToWorkspace(task.cwd, workspace_root);
}

pub fn pathBelongsToWorkspace(path: []const u8, workspace_root: []const u8) bool {
    if (std.mem.eql(u8, path, workspace_root)) return true;
    if (!std.mem.startsWith(u8, path, workspace_root)) return false;
    if (path.len <= workspace_root.len) return false;
    return path[workspace_root.len] == std.fs.path.sep;
}

fn copyTaskSnapshot(alloc: std.mem.Allocator, task: TaskRecord) !TaskSnapshot {
    const pid = try alloc.dupe(u8, task.pid);
    errdefer alloc.free(pid);
    const command = try alloc.dupe(u8, task.command);
    errdefer alloc.free(command);
    const cwd = try alloc.dupe(u8, task.cwd);
    errdefer alloc.free(cwd);
    const log_path = try alloc.dupe(u8, task.log_path);
    errdefer alloc.free(log_path);

    var server_url: ?[]u8 = null;
    errdefer if (server_url) |url| alloc.free(url);
    if (task.server_url) |url| {
        server_url = try alloc.dupe(u8, url);
    }

    return .{
        .id = task.id,
        .pid = pid,
        .process_token = task.process_token,
        .policy = task.policy,
        .source_session_id = if (task.source_session_id) |value|
            try alloc.dupe(u8, value)
        else
            null,
        .background_record_id = task.background_record_id,
        .durable_record_id = task.durable_record_id,
        .record_authority = task.record_authority,
        .record_persistence = task.record_persistence,
        .managed_log_name = if (task.managed_log_name) |value|
            try alloc.dupe(u8, value)
        else
            null,
        .command = command,
        .cwd = cwd,
        .log_path = log_path,
        .expect_url = task.expect_url,
        .server_url = server_url,
        .started_at_ms = task.started_at_ms,
        .exit_code = task.exit_code,
        .state = task.state,
    };
}

test "registerBackground allocates sequential ids and deep-copies registration fields" {
    const alloc = std.testing.allocator;
    var supervisor = ProcessSupervisor{};
    defer supervisor.deinit(alloc);

    var pid = [_]u8{ '1', '0', '0' };
    var command = [_]u8{ 'v', 'i', 't', 'e' };
    var cwd = [_]u8{ '/', 't', 'm', 'p', '/', 'a' };
    var log_path = [_]u8{ '/', 't', 'm', 'p', '/', 'a', '.', 'l', 'o', 'g' };
    var url = [_]u8{ 'h', 't', 't', 'p', ':', '/', '/', 'a' };

    const first_id = try supervisor.registerBackground(alloc, .{
        .pid = pid[0..],
        .command = command[0..],
        .cwd = cwd[0..],
        .log_path = log_path[0..],
        .expect_url = true,
        .url = url[0..],
    });
    const second_id = try supervisor.registerBackground(alloc, .{
        .pid = "101",
        .command = "npm run dev",
        .cwd = "/tmp/b",
        .log_path = "/tmp/b.log",
        .expect_url = false,
    });

    pid[0] = '9';
    command[0] = 'X';
    cwd[1] = 'X';
    log_path[1] = 'X';
    url[7] = 'z';

    try std.testing.expectEqual(@as(u64, 1), first_id);
    try std.testing.expectEqual(@as(u64, 2), second_id);
    try std.testing.expectEqual(@as(u64, 3), supervisor.next_background_process_id);
    try std.testing.expectEqualStrings("100", supervisor.tasks.items[0].pid);
    try std.testing.expectEqualStrings("vite", supervisor.tasks.items[0].command);
    try std.testing.expectEqualStrings("/tmp/a", supervisor.tasks.items[0].cwd);
    try std.testing.expectEqualStrings("/tmp/a.log", supervisor.tasks.items[0].log_path);
    try std.testing.expectEqualStrings("http://a", supervisor.tasks.items[0].server_url.?);
    try std.testing.expectEqual(TaskState.running, supervisor.tasks.items[0].state);
}

test "display id reservations do not wrap or reuse active ids" {
    var supervisor = ProcessSupervisor{};
    supervisor.next_background_process_id = std.math.maxInt(u64);

    const reserved = try supervisor.reserveDisplayId();
    try std.testing.expectEqual(std.math.maxInt(u64), reserved);
    try std.testing.expectError(
        error.BackgroundIdentityUnavailable,
        supervisor.reserveDisplayId(),
    );

    supervisor.releaseDisplayId(reserved);
    try std.testing.expectError(
        error.BackgroundIdentityUnavailable,
        supervisor.reserveDisplayId(),
    );
}

test "restore remaps display collision without changing durable numeric id" {
    const alloc = std.testing.allocator;
    var supervisor = ProcessSupervisor{};
    defer supervisor.deinit(alloc);
    _ = try supervisor.registerBackground(alloc, .{
        .pid = "100",
        .command = "first",
        .cwd = "/tmp",
        .log_path = "/tmp/first.log",
        .expect_url = false,
    });
    const stable_id = StableBackgroundRecordId{
        0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
        0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
    };
    var restored = TaskSnapshot{
        .id = 1,
        .pid = try alloc.dupe(u8, "101"),
        .background_record_id = stable_id,
        .durable_record_id = 1,
        .command = try alloc.dupe(u8, "second"),
        .cwd = try alloc.dupe(u8, "/tmp"),
        .log_path = try alloc.dupe(u8, "/tmp/second.log"),
        .expect_url = false,
        .started_at_ms = 1,
        .state = .running,
    };
    defer restored.deinit(alloc);

    const display_id = try supervisor.restoreBackground(
        alloc,
        restored,
    );
    try std.testing.expectEqual(@as(u64, 2), display_id);
    try std.testing.expectEqual(
        @as(?u64, 1),
        supervisor.tasks.items[1].durable_record_id,
    );
}

test "process instance tokens are canonical and require exact match" {
    const token = try ProcessInstanceToken.parse(
        "linux:00112233445566778899aabbccddeeff:12345",
    );
    try std.testing.expectEqualStrings(
        "linux:00112233445566778899aabbccddeeff:12345",
        token.view(),
    );
    try std.testing.expect(token.eql(token));
    try std.testing.expectError(
        error.InvalidProcessInstanceToken,
        ProcessInstanceToken.parse(
            "linux:00112233445566778899AABBCCDDEEFF:12345",
        ),
    );
}

test "snapshot reports the newest running task" {
    const alloc = std.testing.allocator;
    var supervisor = ProcessSupervisor{};
    defer supervisor.deinit(alloc);

    _ = try supervisor.registerBackground(alloc, .{
        .pid = "100",
        .command = "npm run dev",
        .cwd = "/tmp/a",
        .log_path = "/tmp/a.log",
        .expect_url = true,
        .url = "http://localhost:3000",
    });
    const second_id = try supervisor.registerBackground(alloc, .{
        .pid = "101",
        .command = "vite",
        .cwd = "/tmp/b",
        .log_path = "/tmp/b.log",
        .expect_url = false,
        .url = "http://localhost:4000",
    });

    var snapshot = try supervisor.snapshot(alloc);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(second_id, snapshot.process_id.?);
    try std.testing.expectEqualStrings("/tmp/b.log", snapshot.background_log_path.?);
    try std.testing.expect(!snapshot.background_expect_url);
    try std.testing.expectEqualStrings("http://localhost:4000", snapshot.server_url.?);
    try std.testing.expectEqual(@as(usize, 2), snapshot.tasks.len);
    try std.testing.expectEqualStrings("/tmp/a.log", snapshot.tasks[0].log_path);
    try std.testing.expectEqualStrings("/tmp/b.log", snapshot.tasks[1].log_path);
}

test "findReusableRunningTask matches trimmed command and cwd only for live servers" {
    const alloc = std.testing.allocator;
    var supervisor = ProcessSupervisor{};
    defer supervisor.deinit(alloc);

    const reusable_id = try supervisor.registerBackground(alloc, .{
        .pid = "100",
        .command = " npm run dev ",
        .cwd = "/tmp/app",
        .log_path = "/tmp/app.log",
        .expect_url = true,
        .url = "http://localhost:3000",
    });
    const stopped_id = try supervisor.registerBackground(alloc, .{
        .pid = "101",
        .command = "npm run dev",
        .cwd = "/tmp/other",
        .log_path = "/tmp/other.log",
        .expect_url = true,
    });
    try std.testing.expect(supervisor.markStopped(stopped_id));

    var reusable = (try supervisor.findReusableRunningTask(alloc, "/tmp/app", "npm run dev", true)) orelse return error.TestExpectedEqual;
    defer reusable.deinit(alloc);
    try std.testing.expectEqual(reusable_id, reusable.id);
    try std.testing.expectEqualStrings("http://localhost:3000", reusable.server_url.?);

    try std.testing.expect((try supervisor.findReusableRunningTask(alloc, "/tmp/other", "npm run dev", true)) == null);
    try std.testing.expect((try supervisor.findReusableRunningTask(alloc, "/tmp/app", "pnpm dev", true)) == null);
    try std.testing.expect((try supervisor.findReusableRunningTask(alloc, "/tmp/app", "env WRAPPED=1 sh -lc 'npm run dev'", true)) == null);
}

test "snapshotServerUrl selects the requested id without falling back" {
    const alloc = std.testing.allocator;
    var supervisor = ProcessSupervisor{};
    defer supervisor.deinit(alloc);

    const older_id = try supervisor.registerBackground(alloc, .{
        .pid = "100",
        .command = "npm run dev",
        .cwd = "/tmp/a",
        .log_path = "/tmp/a.log",
        .expect_url = true,
        .url = "http://localhost:3000",
    });
    const newer_id = try supervisor.registerBackground(alloc, .{
        .pid = "101",
        .command = "vite",
        .cwd = "/tmp/b",
        .log_path = "/tmp/b.log",
        .expect_url = true,
    });

    const older_url = (try supervisor.snapshotServerUrl(alloc, older_id)) orelse return error.TestExpectedEqual;
    defer alloc.free(older_url);
    try std.testing.expectEqualStrings("http://localhost:3000", older_url);
    try std.testing.expect((try supervisor.snapshotServerUrl(alloc, newer_id)) == null);
    try std.testing.expect(supervisor.markStopped(older_id));
    try std.testing.expect((try supervisor.snapshotServerUrl(alloc, older_id)) == null);
}

test "snapshotTask distinguishes last task from explicit id selection" {
    const alloc = std.testing.allocator;
    var supervisor = ProcessSupervisor{};
    defer supervisor.deinit(alloc);

    const first_id = try supervisor.registerBackground(alloc, .{
        .pid = "100",
        .command = "npm run dev",
        .cwd = "/tmp/a",
        .log_path = "/tmp/a.log",
        .expect_url = true,
    });
    const second_id = try supervisor.registerBackground(alloc, .{
        .pid = "101",
        .command = "vite",
        .cwd = "/tmp/b",
        .log_path = "/tmp/b.log",
        .expect_url = false,
    });
    try std.testing.expect(supervisor.markStopped(second_id));

    var last = (try supervisor.snapshotTask(alloc, .last)) orelse return error.TestExpectedEqual;
    defer last.deinit(alloc);
    var selected = (try supervisor.snapshotTask(alloc, .{ .id = first_id })) orelse return error.TestExpectedEqual;
    defer selected.deinit(alloc);

    try std.testing.expectEqual(second_id, last.id);
    try std.testing.expectEqual(TaskState.stopped, last.state);
    try std.testing.expectEqual(first_id, selected.id);
    try std.testing.expectEqual(TaskState.running, selected.state);
}

test "publishServerUrl updates duplicates and stale tasks with caller-owned urls" {
    const alloc = std.testing.allocator;
    var supervisor = ProcessSupervisor{};
    defer supervisor.deinit(alloc);

    const id = try supervisor.registerBackground(alloc, .{
        .pid = "100",
        .command = "npm run dev",
        .cwd = "/tmp/a",
        .log_path = "/tmp/a.log",
        .expect_url = true,
    });

    try std.testing.expectEqual(.updated, supervisor.publishServerUrl(alloc, id, try alloc.dupe(u8, "http://localhost:3000")));
    try std.testing.expectEqualStrings("http://localhost:3000", supervisor.tasks.items[0].server_url.?);
    try std.testing.expect(!supervisor.tasks.items[0].expect_url);
    try std.testing.expectEqual(.duplicate, supervisor.publishServerUrl(alloc, id, try alloc.dupe(u8, "http://localhost:3000")));
    try std.testing.expectEqual(.updated, supervisor.publishServerUrl(alloc, id, try alloc.dupe(u8, "http://localhost:4000")));
    try std.testing.expectEqualStrings("http://localhost:4000", supervisor.tasks.items[0].server_url.?);
    try std.testing.expectEqual(.stale, supervisor.publishServerUrl(alloc, 999, try alloc.dupe(u8, "http://stale")));

    try std.testing.expect(supervisor.markStopped(id));
    try std.testing.expectEqual(.stale, supervisor.publishServerUrl(alloc, id, try alloc.dupe(u8, "http://stopped")));
}

test "snapshotTasks deep-copies tasks in stored order" {
    const alloc = std.testing.allocator;
    var supervisor = ProcessSupervisor{};
    defer supervisor.deinit(alloc);

    const first_id = try supervisor.registerBackground(alloc, .{
        .pid = "100",
        .command = "npm run dev",
        .cwd = "/tmp/a",
        .log_path = "/tmp/a.log",
        .expect_url = true,
        .url = "http://localhost:3000",
    });
    const second_id = try supervisor.registerBackground(alloc, .{
        .pid = "101",
        .command = "vite",
        .cwd = "/tmp/b",
        .log_path = "/tmp/b.log",
        .expect_url = false,
    });
    _ = supervisor.markCompleted(second_id, 0);

    const tasks = try supervisor.snapshotTasks(alloc);
    defer tasks.deinit(alloc);
    supervisor.tasks.items[0].pid[0] = '9';
    supervisor.tasks.items[0].server_url.?[7] = 'x';

    try std.testing.expectEqual(@as(usize, 2), tasks.items.len);
    try std.testing.expectEqual(first_id, tasks.items[0].id);
    try std.testing.expectEqual(second_id, tasks.items[1].id);
    try std.testing.expectEqualStrings("100", tasks.items[0].pid);
    try std.testing.expectEqualStrings("http://localhost:3000", tasks.items[0].server_url.?);
    try std.testing.expectEqual(TaskState.exited, tasks.items[1].state);
    try std.testing.expectEqual(@as(?i32, 0), tasks.items[1].exit_code);
}

test "stopCandidate only selects running tasks" {
    const alloc = std.testing.allocator;
    var supervisor = ProcessSupervisor{};
    defer supervisor.deinit(alloc);

    const first_id = try supervisor.registerBackground(alloc, .{
        .pid = "100",
        .command = "npm run dev",
        .cwd = "/tmp/a",
        .log_path = "/tmp/a.log",
        .expect_url = true,
    });
    const second_id = try supervisor.registerBackground(alloc, .{
        .pid = "101",
        .command = "vite",
        .cwd = "/tmp/b",
        .log_path = "/tmp/b.log",
        .expect_url = false,
    });
    _ = supervisor.markCompleted(second_id, 0);

    const latest_running = (try supervisor.stopCandidate(alloc, .last)) orelse return error.TestExpectedEqual;
    defer alloc.free(latest_running.pid);
    try std.testing.expectEqual(first_id, latest_running.id);
    try std.testing.expectEqualStrings("100", latest_running.pid);
    try std.testing.expect((try supervisor.stopCandidate(alloc, .{ .id = second_id })) == null);
    try std.testing.expect((try supervisor.stopCandidate(alloc, .{ .id = 999 })) == null);
}

test "markStopped and markCompleted apply state transitions" {
    const alloc = std.testing.allocator;
    var supervisor = ProcessSupervisor{};
    defer supervisor.deinit(alloc);

    const exited_id = try supervisor.registerBackground(alloc, .{
        .pid = "100",
        .command = "true",
        .cwd = "/tmp/a",
        .log_path = "/tmp/a.log",
        .expect_url = true,
    });
    const failed_id = try supervisor.registerBackground(alloc, .{
        .pid = "101",
        .command = "false",
        .cwd = "/tmp/b",
        .log_path = "/tmp/b.log",
        .expect_url = true,
    });
    const null_failed_id = try supervisor.registerBackground(alloc, .{
        .pid = "102",
        .command = "killed",
        .cwd = "/tmp/c",
        .log_path = "/tmp/c.log",
        .expect_url = true,
    });
    const stopped_id = try supervisor.registerBackground(alloc, .{
        .pid = "103",
        .command = "sleep",
        .cwd = "/tmp/d",
        .log_path = "/tmp/d.log",
        .expect_url = true,
    });

    const exited = supervisor.markCompleted(exited_id, 0) orelse return error.TestExpectedEqual;
    const failed = supervisor.markCompleted(failed_id, 2) orelse return error.TestExpectedEqual;
    const null_failed = supervisor.markCompleted(null_failed_id, null) orelse return error.TestExpectedEqual;

    try std.testing.expectEqual(TaskState.exited, exited.state);
    try std.testing.expectEqual(@as(?i32, 0), exited.exit_code);
    try std.testing.expectEqual(TaskState.failed, failed.state);
    try std.testing.expectEqual(@as(?i32, 2), failed.exit_code);
    try std.testing.expectEqual(TaskState.dead, null_failed.state);
    try std.testing.expectEqual(@as(?i32, null), null_failed.exit_code);
    try std.testing.expect(!supervisor.tasks.items[0].expect_url);
    try std.testing.expect(!supervisor.tasks.items[1].expect_url);
    try std.testing.expect(!supervisor.tasks.items[2].expect_url);
    try std.testing.expect(supervisor.markCompleted(exited_id, 0) == null);
    try std.testing.expect(supervisor.markCompleted(999, 0) == null);

    try std.testing.expect(supervisor.markStopped(stopped_id));
    try std.testing.expectEqual(TaskState.stopped, supervisor.tasks.items[3].state);
    try std.testing.expect(!supervisor.tasks.items[3].expect_url);
    try std.testing.expectEqual(@as(?i32, null), supervisor.tasks.items[3].exit_code);
    try std.testing.expect(supervisor.markCompleted(stopped_id, 0) == null);
    try std.testing.expect(!supervisor.markStopped(999));

    try std.testing.expect(supervisor.markStopped(failed_id));
    try std.testing.expectEqual(TaskState.stopped, supervisor.tasks.items[1].state);
    try std.testing.expectEqual(@as(?i32, null), supervisor.tasks.items[1].exit_code);
}

test "owned snapshot and record deinit paths release optional fields" {
    const alloc = std.testing.allocator;

    var record = TaskRecord{
        .id = 1,
        .pid = try alloc.dupe(u8, "100"),
        .command = try alloc.dupe(u8, "npm run dev"),
        .cwd = try alloc.dupe(u8, "/tmp/a"),
        .log_path = try alloc.dupe(u8, "/tmp/a.log"),
        .expect_url = true,
        .server_url = try alloc.dupe(u8, "http://localhost:3000"),
        .started_at_ms = 0,
    };
    record.deinit(alloc);

    const context = RuntimeContextSnapshot{
        .process_id = 1,
        .background_log_path = try alloc.dupe(u8, "/tmp/a.log"),
        .background_expect_url = false,
        .server_url = try alloc.dupe(u8, "http://localhost:3000"),
    };
    context.deinit(alloc);

    const snapshot = TaskSnapshot{
        .id = 1,
        .pid = try alloc.dupe(u8, "100"),
        .command = try alloc.dupe(u8, "npm run dev"),
        .cwd = try alloc.dupe(u8, "/tmp/a"),
        .log_path = try alloc.dupe(u8, "/tmp/a.log"),
        .expect_url = true,
        .server_url = try alloc.dupe(u8, "http://localhost:3000"),
        .started_at_ms = 0,
        .state = .running,
    };
    snapshot.deinit(alloc);

    const items = try alloc.alloc(TaskSnapshot, 2);
    items[0] = .{
        .id = 1,
        .pid = try alloc.dupe(u8, "100"),
        .command = try alloc.dupe(u8, "npm run dev"),
        .cwd = try alloc.dupe(u8, "/tmp/a"),
        .log_path = try alloc.dupe(u8, "/tmp/a.log"),
        .expect_url = true,
        .server_url = try alloc.dupe(u8, "http://localhost:3000"),
        .started_at_ms = 0,
        .state = .running,
    };
    items[1] = .{
        .id = 2,
        .pid = try alloc.dupe(u8, "101"),
        .command = try alloc.dupe(u8, "vite"),
        .cwd = try alloc.dupe(u8, "/tmp/b"),
        .log_path = try alloc.dupe(u8, "/tmp/b.log"),
        .expect_url = false,
        .started_at_ms = 1,
        .state = .stopped,
    };
    const list = TaskListSnapshot{ .items = items };
    list.deinit(alloc);
}
