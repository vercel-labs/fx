const std = @import("std");
const builtin = @import("builtin");
const background_process_provider = @import("../execution/background_process_provider.zig");
const process_supervisor = @import("../background/process_supervisor.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

pub const protocol_version: u32 = 1;
pub const internal_mode = "--fx-internal-daemon";
pub const max_frame_bytes: usize = 512 * 1024;
pub const max_log_bytes: usize = 4 * 1024 * 1024;
pub const max_prompt_bytes: usize = 64 * 1024;
pub const max_retained_jobs: usize = 64;
pub const shutdown_timeout_ms: i64 = 30_000;
const request_timeout_seconds: i64 = 5;
const socket_mode = 0o600;
const directory_mode = 0o700;
const supervisor_name = "supervisor.json";
const jobs_name = "jobs";

pub fn isInternalModeRaw(raw_args: []const [*:0]const u8) bool {
    return raw_args.len == 2 and
        std.mem.eql(u8, std.mem.sliceTo(raw_args[1], 0), internal_mode);
}

pub const JobState = enum { queued, running, exited, failed, stopped, unknown };

pub const Paths = struct {
    root: []u8,
    jobs: []u8,
    socket: []u8,
    identity: []u8,

    pub fn init(alloc: Allocator, home: []const u8) !Paths {
        if (!std.fs.path.isAbsolute(home)) return error.InvalidStatePath;
        const root = try std.fs.path.join(alloc, &.{ home, profile_paths.root_dir_name, "daemon" });
        errdefer alloc.free(root);
        const jobs = try std.fs.path.join(alloc, &.{ root, jobs_name });
        errdefer alloc.free(jobs);
        const socket = try std.fs.path.join(alloc, &.{ root, "supervisor.sock" });
        errdefer alloc.free(socket);
        const identity = try std.fs.path.join(alloc, &.{ root, supervisor_name });
        return .{ .root = root, .jobs = jobs, .socket = socket, .identity = identity };
    }

    pub fn deinit(self: *Paths, alloc: Allocator) void {
        alloc.free(self.root);
        alloc.free(self.jobs);
        alloc.free(self.socket);
        alloc.free(self.identity);
        self.* = undefined;
    }

    fn clone(self: *const Paths, alloc: Allocator) !Paths {
        const root = try alloc.dupe(u8, self.root);
        errdefer alloc.free(root);
        const jobs = try alloc.dupe(u8, self.jobs);
        errdefer alloc.free(jobs);
        const socket = try alloc.dupe(u8, self.socket);
        errdefer alloc.free(socket);
        const identity = try alloc.dupe(u8, self.identity);
        return .{ .root = root, .jobs = jobs, .socket = socket, .identity = identity };
    }
};

pub const JobSnapshot = struct {
    id: []u8,
    state: JobState,
    pid: ?i64,
    cwd: []u8,
    prompt: []u8,
    log_path: []u8,
    process_token: ?process_supervisor.ProcessInstanceToken,
    exit_code: ?i32,

    pub fn deinit(self: *JobSnapshot, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.cwd);
        alloc.free(self.prompt);
        alloc.free(self.log_path);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    running: bool,
    pid: ?i64,
    jobs: []JobSnapshot,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        for (self.jobs) |*job| job.deinit(alloc);
        alloc.free(self.jobs);
        self.* = undefined;
    }
};

pub const Request = union(enum) {
    status,
    jobs,
    show: []const u8,
    submit: struct { cwd: []const u8, prompt: []const u8 },
    stop: []const u8,
    shutdown,
};

pub const Response = struct {
    ok: bool,
    message: ?[]const u8 = null,
    message_owned: bool = false,
    job_id: ?[]const u8 = null,
    snapshot: ?Snapshot = null,

    pub fn deinit(self: *Response, alloc: Allocator) void {
        if (self.message_owned) if (self.message) |message| alloc.free(message);
        if (self.job_id) |id| alloc.free(id);
        if (self.snapshot) |*value| value.deinit(alloc);
        self.* = undefined;
    }
};

fn ensurePrivateDir(path: []const u8) !void {
    const io = io_mod.getIo();
    std.Io.Dir.createDirAbsolute(io, path, std.Io.File.Permissions.fromMode(directory_mode)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try std.Io.Dir.cwd().setFilePermissions(io, path, std.Io.File.Permissions.fromMode(directory_mode), .{ .follow_symlinks = false });
}

pub fn prepare(paths: *const Paths) !void {
    try ensurePrivateDir(std.fs.path.dirname(paths.root) orelse return error.InvalidStatePath);
    try ensurePrivateDir(paths.root);
    try ensurePrivateDir(paths.jobs);
}

fn openJobsDir(paths: *const Paths) !io_mod.VerifiedDir {
    const profile_path = std.fs.path.dirname(paths.root) orelse return error.InvalidStatePath;
    var profile = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) };
    defer profile.close();
    var daemon = try io_mod.openOrCreateVerifiedPrivateDir(&profile, "daemon");
    defer daemon.close();
    return io_mod.openOrCreateVerifiedPrivateDir(&daemon, jobs_name);
}

fn openDaemonDir(paths: *const Paths) !io_mod.VerifiedDir {
    const profile_path = std.fs.path.dirname(paths.root) orelse return error.InvalidStatePath;
    var profile = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_path, .{
        .iterate = true,
        .follow_symlinks = false,
    }) };
    defer profile.close();
    return io_mod.openOrCreateVerifiedPrivateDir(&profile, "daemon");
}

fn recordName(alloc: Allocator, id: []const u8) ![]u8 {
    if (!validJobId(id)) return error.InvalidJobId;
    const name = try std.fmt.allocPrint(alloc, "{s}.json", .{id});
    return name;
}

fn validJobId(id: []const u8) bool {
    if (!std.mem.startsWith(u8, id, "job-") or id.len < 8) return false;
    for (id[4..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    }
    return true;
}

fn setSocketTimeouts(stream: std.Io.net.Stream) void {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return;
    const timeout = std.posix.timeval{ .sec = request_timeout_seconds, .usec = 0 };
    const bytes = std.mem.asBytes(&timeout);
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        bytes,
    ) catch {};
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        bytes,
    ) catch {};
}

fn logPath(alloc: Allocator, paths: *const Paths, id: []const u8) ![]u8 {
    const name = try std.fmt.allocPrint(alloc, "{s}.log", .{id});
    defer alloc.free(name);
    return std.fs.path.join(alloc, &.{ paths.jobs, name });
}

fn writeJsonLine(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

fn writeJob(alloc: Allocator, paths: *const Paths, job: *const JobSnapshot) !void {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try writeJsonLine(&output.writer, .{
        .version = protocol_version,
        .id = job.id,
        .state = @tagName(job.state),
        .pid = job.pid,
        .cwd = job.cwd,
        .prompt = job.prompt,
        .log_path = job.log_path,
        .process_token = if (job.process_token) |*token| token.view() else null,
        .exit_code = job.exit_code,
    });
    const bytes = try output.toOwnedSlice();
    defer alloc.free(bytes);
    var jobs_dir = try openJobsDir(paths);
    defer jobs_dir.close();
    const name = try recordName(alloc, job.id);
    defer alloc.free(name);
    try io_mod.durableReplaceVerified(alloc, &jobs_dir, name, bytes);
}

fn valueString(value: ?std.json.Value) ?[]const u8 {
    return if (value) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;
}

fn readJob(alloc: Allocator, paths: *const Paths, id: []const u8) !JobSnapshot {
    var jobs_dir = try openJobsDir(paths);
    defer jobs_dir.close();
    const name = try recordName(alloc, id);
    defer alloc.free(name);
    var file = try jobs_dir.dir.openFile(io_mod.getIo(), name, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, 128 * 1024);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidJobRecord,
    };
    const version = object.get("version") orelse return error.InvalidJobRecord;
    switch (version) {
        .integer => |number| if (number != protocol_version) return error.InvalidJobRecord,
        else => return error.InvalidJobRecord,
    }
    const state_name = valueString(object.get("state")) orelse return error.InvalidJobRecord;
    const state = std.meta.stringToEnum(JobState, state_name) orelse .unknown;
    const stored_id = valueString(object.get("id")) orelse return error.InvalidJobRecord;
    if (!validJobId(stored_id) or !std.mem.eql(u8, stored_id, id)) return error.InvalidJobRecord;
    const cwd = valueString(object.get("cwd")) orelse return error.InvalidJobRecord;
    const prompt = valueString(object.get("prompt")) orelse return error.InvalidJobRecord;
    const log_path = valueString(object.get("log_path")) orelse return error.InvalidJobRecord;
    const process_token_text = if (object.get("process_token")) |value| valueString(value) else null;
    const process_token = if (process_token_text) |token|
        process_supervisor.ProcessInstanceToken.parse(token) catch return error.InvalidJobRecord
    else
        null;
    const pid = if (object.get("pid")) |value| switch (value) {
        .integer => |n| n,
        .null => null,
        else => return error.InvalidJobRecord,
    } else null;
    const exit_code = if (object.get("exit_code")) |value| switch (value) {
        .integer => |n| std.math.cast(i32, n) orelse return error.InvalidJobRecord,
        .null => null,
        else => return error.InvalidJobRecord,
    } else null;
    var owned_id: ?[]u8 = null;
    var owned_cwd: ?[]u8 = null;
    var owned_prompt: ?[]u8 = null;
    var owned_log_path: ?[]u8 = null;
    errdefer {
        if (owned_id) |value| alloc.free(value);
        if (owned_cwd) |value| alloc.free(value);
        if (owned_prompt) |value| alloc.free(value);
        if (owned_log_path) |value| alloc.free(value);
    }
    owned_id = try alloc.dupe(u8, stored_id);
    owned_cwd = try alloc.dupe(u8, cwd);
    owned_prompt = try alloc.dupe(u8, prompt);
    owned_log_path = try alloc.dupe(u8, log_path);
    return .{
        .id = owned_id.?,
        .state = state,
        .pid = pid,
        .cwd = owned_cwd.?,
        .prompt = owned_prompt.?,
        .log_path = owned_log_path.?,
        .process_token = process_token,
        .exit_code = exit_code,
    };
}

pub fn snapshot(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
) !Snapshot {
    try prepare(paths);
    var jobs_dir = try openJobsDir(paths);
    defer jobs_dir.close();
    var jobs: std.ArrayList(JobSnapshot) = .empty;
    errdefer {
        for (jobs.items) |*job| job.deinit(alloc);
        jobs.deinit(alloc);
    }
    var iterator = jobs_dir.dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const id = entry.name[0 .. entry.name.len - 5];
        var job = readJob(alloc, paths, id) catch continue;
        reconcileJob(alloc, paths, process_provider, &job);
        try retainNewestJob(alloc, &jobs, job);
    }
    const identity = readSupervisorIdentity(alloc, paths) catch null;
    const running = if (identity) |value|
        supervisorIdentityAlive(alloc, process_provider, value)
    else
        false;
    const owned_jobs = try jobs.toOwnedSlice(alloc);
    std.mem.sort(JobSnapshot, owned_jobs, {}, lessJob);
    return .{
        .running = running,
        .pid = if (running) identity.?.pid else null,
        .jobs = owned_jobs,
    };
}

pub fn snapshotJob(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
    id: []const u8,
) !Snapshot {
    try prepare(paths);
    var job = try readJob(alloc, paths, id);
    errdefer job.deinit(alloc);
    reconcileJob(alloc, paths, process_provider, &job);
    const jobs = try alloc.alloc(JobSnapshot, 1);
    errdefer alloc.free(jobs);
    jobs[0] = job;
    const identity = readSupervisorIdentity(alloc, paths) catch null;
    const running = if (identity) |value|
        supervisorIdentityAlive(alloc, process_provider, value)
    else
        false;
    return .{
        .running = running,
        .pid = if (running) identity.?.pid else null,
        .jobs = jobs,
    };
}

fn retainNewestJob(
    alloc: Allocator,
    jobs: *std.ArrayList(JobSnapshot),
    value: JobSnapshot,
) !void {
    var job = value;
    if (jobs.items.len < max_retained_jobs) {
        jobs.append(alloc, job) catch |err| {
            job.deinit(alloc);
            return err;
        };
        return;
    }
    var oldest_index: usize = 0;
    for (jobs.items[1..], 1..) |candidate, index| {
        if (lessJob({}, candidate, jobs.items[oldest_index])) oldest_index = index;
    }
    if (lessJob({}, jobs.items[oldest_index], job)) {
        jobs.items[oldest_index].deinit(alloc);
        jobs.items[oldest_index] = job;
    } else {
        job.deinit(alloc);
    }
}

fn reconcileJob(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
    job: *JobSnapshot,
) void {
    if (job.state != .running) return;
    switch (jobIdentityMatch(alloc, process_provider, job)) {
        .missing, .mismatched => {
            job.state = .failed;
            job.exit_code = null;
            writeJob(alloc, paths, job) catch {};
        },
        .matched, .unavailable => {},
    }
}

fn lessJob(_: void, left: JobSnapshot, right: JobSnapshot) bool {
    const left_created_at = jobCreatedAt(left.id);
    const right_created_at = jobCreatedAt(right.id);
    if (left_created_at != null and right_created_at != null and left_created_at.? != right_created_at.?) {
        return left_created_at.? < right_created_at.?;
    }
    return std.mem.order(u8, left.id, right.id) == .lt;
}

fn jobCreatedAt(id: []const u8) ?i128 {
    if (!std.mem.startsWith(u8, id, "job-")) return null;
    const suffix = id[4..];
    const separator = std.mem.findScalar(u8, suffix, '-') orelse return null;
    if (separator == 0) return null;
    return std.fmt.parseInt(i128, suffix[0..separator], 10) catch null;
}

const ProcessIdentity = struct {
    pid: i64,
    token: process_supervisor.ProcessInstanceToken,
};

fn readSupervisorIdentity(alloc: Allocator, paths: *const Paths) !?ProcessIdentity {
    var daemon_dir = openDaemonDir(paths) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer daemon_dir.close();
    var file = daemon_dir.dir.openFile(io_mod.getIo(), supervisor_name, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, 4096);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const pid_value = object.get("pid") orelse return null;
    const pid = switch (pid_value) {
        .integer => |n| n,
        else => return null,
    };
    const token_text = valueString(object.get("token")) orelse return null;
    return .{
        .pid = pid,
        .token = process_supervisor.ProcessInstanceToken.parse(token_text) catch return null,
    };
}

fn supervisorAlive(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
) bool {
    const identity = (readSupervisorIdentity(alloc, paths) catch return false) orelse return false;
    return supervisorIdentityAlive(alloc, process_provider, identity);
}

fn supervisorIdentityAlive(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
    identity: ProcessIdentity,
) bool {
    var pid_buffer: [32]u8 = undefined;
    const pid = std.fmt.bufPrint(&pid_buffer, "{d}", .{identity.pid}) catch return false;
    return process_provider.matchToken(alloc, pid, identity.token) == .matched;
}

fn jobIdentityMatch(
    alloc: Allocator,
    process_provider: background_process_provider.Provider,
    job: *const JobSnapshot,
) process_supervisor.TokenMatch {
    const pid = job.pid orelse return .unavailable;
    const expected = job.process_token orelse return .unavailable;
    var pid_buffer: [32]u8 = undefined;
    const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{pid}) catch return .unavailable;
    return process_provider.matchToken(alloc, pid_text, expected);
}

fn stopJobs(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
) void {
    var current = snapshot(alloc, paths, process_provider) catch return;
    defer current.deinit(alloc);
    for (current.jobs) |*job| {
        if (job.state != .running) continue;
        if (job.pid) |pid| {
            if (job.process_token) |token| {
                var pid_buffer: [32]u8 = undefined;
                const pid_text = std.fmt.bufPrint(&pid_buffer, "{d}", .{pid}) catch continue;
                process_provider.signalProcess(alloc, pid_text, token) catch continue;
            }
        }
        job.state = .stopped;
        writeJob(alloc, paths, job) catch {};
    }
}

fn stopJob(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
    id: []const u8,
) !void {
    var job = try readJob(alloc, paths, id);
    defer job.deinit(alloc);
    if (job.state != .running) return;
    switch (jobIdentityMatch(alloc, process_provider, &job)) {
        .matched => {},
        .missing, .mismatched => {
            job.state = .failed;
            job.exit_code = null;
            return writeJob(alloc, paths, &job);
        },
        .unavailable => return error.BackgroundProcessIdentityIndeterminate,
    }
    const pid = job.pid orelse return error.InvalidJobRecord;
    const token = job.process_token orelse return error.InvalidJobRecord;
    var pid_buffer: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid});
    try process_provider.signalProcess(alloc, pid_text, token);
    job.state = .stopped;
    try writeJob(alloc, paths, &job);
}

fn writeSupervisorIdentity(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
) !void {
    var daemon_dir = try openDaemonDir(paths);
    defer daemon_dir.close();
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    const pid: i64 = @intCast(std.c.getpid());
    var pid_buffer: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid});
    const token = try process_provider.captureToken(alloc, pid_text);
    try writeJsonLine(&output.writer, .{ .version = protocol_version, .pid = pid, .token = token.view() });
    const bytes = try output.toOwnedSlice();
    defer alloc.free(bytes);
    try io_mod.durableReplaceVerified(alloc, &daemon_dir, supervisor_name, bytes);
}

const WorkerThreads = struct {
    items: std.ArrayList(std.Thread) = .empty,

    fn ensureUnusedCapacity(self: *WorkerThreads, alloc: Allocator) !void {
        try self.items.ensureUnusedCapacity(alloc, 1);
    }

    fn appendAssumeCapacity(self: *WorkerThreads, thread: std.Thread) void {
        self.items.appendAssumeCapacity(thread);
    }

    fn joinAll(self: *WorkerThreads, alloc: Allocator) void {
        for (self.items.items) |thread| thread.join();
        self.items.deinit(alloc);
        self.* = .{};
    }
};

fn appendBoundedTail(tail: *std.ArrayList(u8), alloc: Allocator, bytes: []const u8) !void {
    if (bytes.len >= max_log_bytes) {
        tail.clearRetainingCapacity();
        try tail.appendSlice(alloc, bytes[bytes.len - max_log_bytes ..]);
        return;
    }
    if (tail.items.len + bytes.len > max_log_bytes) {
        const remove_count = tail.items.len + bytes.len - max_log_bytes;
        const retained_count = tail.items.len - remove_count;
        std.mem.copyForwards(u8, tail.items[0..retained_count], tail.items[remove_count..]);
        tail.shrinkRetainingCapacity(retained_count);
    }
    try tail.appendSlice(alloc, bytes);
}

const LogDrain = struct {
    file: std.Io.File,
    paths: Paths,
    name: []u8,

    fn run(value: LogDrain) void {
        var self = value;
        defer self.file.close(io_mod.getIo());
        defer self.paths.deinit(std.heap.page_allocator);
        defer std.heap.page_allocator.free(self.name);
        var tail: std.ArrayList(u8) = .empty;
        defer tail.deinit(std.heap.page_allocator);
        var capture = true;
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const count = self.file.readStreaming(io_mod.getIo(), &.{&buffer}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => break,
            };
            if (count == 0) break;
            if (capture) {
                appendBoundedTail(&tail, std.heap.page_allocator, buffer[0..count]) catch {
                    capture = false;
                };
            }
        }
        var jobs_dir = openJobsDir(&self.paths) catch return;
        defer jobs_dir.close();
        io_mod.durableReplaceVerified(
            std.heap.page_allocator,
            &jobs_dir,
            self.name,
            tail.items,
        ) catch {};
    }
};

fn startLogDrain(file: std.Io.File, paths: *const Paths, name: []const u8) !std.Thread {
    var owned_file = file;
    errdefer owned_file.close(io_mod.getIo());
    const owned_paths = try paths.clone(std.heap.page_allocator);
    errdefer {
        var mutable_paths = owned_paths;
        mutable_paths.deinit(std.heap.page_allocator);
    }
    const owned_name = try std.heap.page_allocator.dupe(u8, name);
    errdefer std.heap.page_allocator.free(owned_name);
    return std.Thread.spawn(.{}, LogDrain.run, .{LogDrain{
        .file = owned_file,
        .paths = owned_paths,
        .name = owned_name,
    }});
}

fn makeJobId(alloc: Allocator) ![]u8 {
    var random: [8]u8 = undefined;
    try std.Io.randomSecure(io_mod.getIo(), &random);
    return std.fmt.allocPrint(alloc, "job-{d}-{x}", .{ io_mod.nanoTimestamp(), std.mem.readInt(u64, &random, .little) });
}

fn deleteJobArtifacts(alloc: Allocator, paths: *const Paths, id: []const u8) !void {
    var jobs_dir = try openJobsDir(paths);
    defer jobs_dir.close();
    const record_name = try recordName(alloc, id);
    defer alloc.free(record_name);
    const log_name = try std.fmt.allocPrint(alloc, "{s}.log", .{id});
    defer alloc.free(log_name);
    const stderr_name = try std.fmt.allocPrint(alloc, "{s}.stderr.log", .{id});
    defer alloc.free(stderr_name);
    const names = [_][]const u8{ record_name, log_name, stderr_name };
    for (names) |name| {
        jobs_dir.dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

const JobSlotState = enum { available, pruned, saturated };

fn inspectJobSlot(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
) !JobSlotState {
    var jobs_dir = try openJobsDir(paths);
    defer jobs_dir.close();
    var count: usize = 0;
    var oldest_settled: ?JobSnapshot = null;
    defer if (oldest_settled) |*job| job.deinit(alloc);
    var iterator = jobs_dir.dir.iterate();
    while (try iterator.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const id = entry.name[0 .. entry.name.len - 5];
        var job = readJob(alloc, paths, id) catch continue;
        reconcileJob(alloc, paths, process_provider, &job);
        count += 1;
        if (job.state == .running or job.state == .queued) {
            job.deinit(alloc);
            continue;
        }
        if (oldest_settled == null or lessJob({}, job, oldest_settled.?)) {
            if (oldest_settled) |*oldest| oldest.deinit(alloc);
            oldest_settled = job;
        } else {
            job.deinit(alloc);
        }
    }
    if (count < max_retained_jobs) return .available;
    const oldest = oldest_settled orelse return .saturated;
    try deleteJobArtifacts(alloc, paths, oldest.id);
    return .pruned;
}

fn reserveJobSlot(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
) !void {
    while (true) switch (try inspectJobSlot(alloc, paths, process_provider)) {
        .available => return,
        .pruned => continue,
        .saturated => return error.TooManyDaemonJobs,
    };
}

fn spawnWorker(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
    worker_threads: *WorkerThreads,
    cwd: []const u8,
    prompt: []const u8,
) !JobSnapshot {
    try reserveJobSlot(alloc, paths, process_provider);
    try worker_threads.ensureUnusedCapacity(alloc);
    const id = try makeJobId(alloc);
    errdefer alloc.free(id);
    errdefer deleteJobArtifacts(alloc, paths, id) catch {};
    const log_path = try logPath(alloc, paths, id);
    errdefer alloc.free(log_path);
    var jobs_dir = try openJobsDir(paths);
    defer jobs_dir.close();
    const log_name = try std.fmt.allocPrint(alloc, "{s}.log", .{id});
    defer alloc.free(log_name);
    const stderr_name = try std.fmt.allocPrint(alloc, "{s}.stderr.log", .{id});
    defer alloc.free(stderr_name);
    const stdout_log = try jobs_dir.dir.createFile(io_mod.getIo(), log_name, .{
        .read = false,
        .truncate = false,
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
        .resolve_beneath = true,
    });
    stdout_log.close(io_mod.getIo());
    const stderr_log = jobs_dir.dir.createFile(io_mod.getIo(), stderr_name, .{
        .read = false,
        .truncate = false,
        .exclusive = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
        .resolve_beneath = true,
    }) catch |err| return err;
    stderr_log.close(io_mod.getIo());
    const executable = try std.process.executablePathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(executable);
    const argv = [_][]const u8{ executable, "ask", "--quiet", "--json", "--", prompt };
    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (builtin.os.tag == .macos or builtin.os.tag == .linux) 0 else null,
    }) catch |err| return err;
    var child_owned = true;
    errdefer if (child_owned) child.kill(io_mod.getIo());
    const pid: i64 = @intCast(child.id orelse return error.WorkerPidUnavailable);
    var pid_buffer: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buffer, "{d}", .{pid});
    const token = try process_provider.captureToken(alloc, pid_text);
    const owned_cwd = try alloc.dupe(u8, cwd);
    errdefer alloc.free(owned_cwd);
    const owned_prompt = try alloc.dupe(u8, prompt);
    errdefer alloc.free(owned_prompt);
    const job = JobSnapshot{
        .id = id,
        .state = .running,
        .pid = pid,
        .cwd = owned_cwd,
        .prompt = owned_prompt,
        .log_path = log_path,
        .process_token = token,
        .exit_code = null,
    };
    try writeJob(alloc, paths, &job);
    const stdout_pipe = child.stdout orelse return error.WorkerPipeUnavailable;
    child.stdout = null;
    const stderr_pipe = child.stderr orelse {
        stdout_pipe.close(io_mod.getIo());
        return error.WorkerPipeUnavailable;
    };
    child.stderr = null;

    const stdout_thread = startLogDrain(stdout_pipe, paths, log_name) catch |err| {
        stderr_pipe.close(io_mod.getIo());
        return err;
    };
    const stderr_thread = startLogDrain(stderr_pipe, paths, stderr_name) catch |err| {
        child.kill(io_mod.getIo());
        child_owned = false;
        stdout_thread.join();
        return err;
    };
    const Watch = struct {
        fn run(
            value: std.process.Child,
            job_id: []const u8,
            paths_copy: Paths,
            stdout_drain: std.Thread,
            stderr_drain: std.Thread,
        ) void {
            defer std.heap.page_allocator.free(@constCast(job_id));
            var owned_paths = paths_copy;
            defer owned_paths.deinit(std.heap.page_allocator);
            var owned = value;
            const term = owned.wait(io_mod.getIo()) catch {
                stdout_drain.join();
                stderr_drain.join();
                return;
            };
            stdout_drain.join();
            stderr_drain.join();
            const exit_code: ?i32 = switch (term) {
                .exited => |code| @intCast(code),
                else => null,
            };
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var record = readJob(a, &owned_paths, job_id) catch return;
            defer record.deinit(a);
            if (record.state != .stopped) {
                record.state = if (exit_code != null and exit_code.? == 0) .exited else .failed;
            }
            record.exit_code = exit_code;
            writeJob(a, &owned_paths, &record) catch {};
        }
    };
    const watcher_paths = paths.clone(std.heap.page_allocator) catch |err| {
        child.kill(io_mod.getIo());
        child_owned = false;
        stdout_thread.join();
        stderr_thread.join();
        return err;
    };
    const watcher_id = std.heap.page_allocator.dupe(u8, id) catch |err| {
        var owned_paths = watcher_paths;
        owned_paths.deinit(std.heap.page_allocator);
        child.kill(io_mod.getIo());
        child_owned = false;
        stdout_thread.join();
        stderr_thread.join();
        return err;
    };
    const thread = std.Thread.spawn(.{}, Watch.run, .{
        child,
        watcher_id,
        watcher_paths,
        stdout_thread,
        stderr_thread,
    }) catch |err| {
        std.heap.page_allocator.free(watcher_id);
        var owned_paths = watcher_paths;
        owned_paths.deinit(std.heap.page_allocator);
        child.kill(io_mod.getIo());
        child_owned = false;
        stdout_thread.join();
        stderr_thread.join();
        return err;
    };
    worker_threads.appendAssumeCapacity(thread);
    child_owned = false;
    return job;
}

fn requestJson(alloc: Allocator, request_value: Request) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    switch (request_value) {
        .status => try writeJsonLine(&output.writer, .{ .version = protocol_version, .op = "status" }),
        .jobs => try writeJsonLine(&output.writer, .{ .version = protocol_version, .op = "jobs" }),
        .show => |id| try writeJsonLine(&output.writer, .{ .version = protocol_version, .op = "show", .id = id }),
        .stop => |id| try writeJsonLine(&output.writer, .{ .version = protocol_version, .op = "stop", .id = id }),
        .shutdown => try writeJsonLine(&output.writer, .{ .version = protocol_version, .op = "shutdown" }),
        .submit => |value| try writeJsonLine(&output.writer, .{ .version = protocol_version, .op = "submit", .cwd = value.cwd, .prompt = value.prompt }),
    }
    const bytes = try output.toOwnedSlice();
    if (bytes.len > max_frame_bytes) {
        alloc.free(bytes);
        return error.FrameTooLarge;
    }
    return bytes;
}

fn readLine(stream: std.Io.net.Stream, alloc: Allocator) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &buffer);
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    while (result.items.len < max_frame_bytes) {
        const byte = reader.interface.takeByte() catch |err| return err;
        if (byte == '\n') return result.toOwnedSlice(alloc);
        try result.append(alloc, byte);
    }
    return error.FrameTooLarge;
}

fn requestRaw(alloc: Allocator, paths: *const Paths, value: Request) ![]u8 {
    const address = try std.Io.net.UnixAddress.init(paths.socket);
    var stream = try address.connect(io_mod.getIo());
    defer stream.close(io_mod.getIo());
    setSocketTimeouts(stream);
    const line = try requestJson(alloc, value);
    defer alloc.free(line);
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.writeAll(line);
    try writer.interface.flush();
    return readLine(stream, alloc);
}

pub fn request(alloc: Allocator, paths: *const Paths, value: Request) !Response {
    const bytes = try requestRaw(alloc, paths, value);
    defer alloc.free(bytes);
    return decodeResponse(alloc, bytes);
}

fn valueBool(value: ?std.json.Value) ?bool {
    return if (value) |item| switch (item) {
        .bool => |flag| flag,
        else => null,
    } else null;
}

fn valueInt(value: ?std.json.Value) ?i64 {
    return if (value) |item| switch (item) {
        .integer => |number| number,
        else => null,
    } else null;
}

fn decodeJob(alloc: Allocator, object: anytype) !JobSnapshot {
    const id = valueString(object.get("id")) orelse return error.InvalidResponse;
    if (!validJobId(id)) return error.InvalidResponse;
    const state_text = valueString(object.get("state")) orelse return error.InvalidResponse;
    const state = std.meta.stringToEnum(JobState, state_text) orelse return error.InvalidResponse;
    const cwd = valueString(object.get("cwd")) orelse return error.InvalidResponse;
    const prompt = valueString(object.get("prompt")) orelse return error.InvalidResponse;
    const log_path = valueString(object.get("log_path")) orelse return error.InvalidResponse;
    const job_pid = if (object.get("pid")) |item| switch (item) {
        .integer => |number| number,
        .null => null,
        else => return error.InvalidResponse,
    } else null;
    const exit_code = if (object.get("exit_code")) |item| switch (item) {
        .integer => |number| std.math.cast(i32, number) orelse return error.InvalidResponse,
        .null => null,
        else => return error.InvalidResponse,
    } else null;

    var owned_id: ?[]u8 = null;
    var owned_cwd: ?[]u8 = null;
    var owned_prompt: ?[]u8 = null;
    var owned_log_path: ?[]u8 = null;
    errdefer {
        if (owned_id) |value| alloc.free(value);
        if (owned_cwd) |value| alloc.free(value);
        if (owned_prompt) |value| alloc.free(value);
        if (owned_log_path) |value| alloc.free(value);
    }
    owned_id = try alloc.dupe(u8, id);
    owned_cwd = try alloc.dupe(u8, cwd);
    owned_prompt = try alloc.dupe(u8, prompt);
    owned_log_path = try alloc.dupe(u8, log_path);
    return .{
        .id = owned_id.?,
        .state = state,
        .pid = job_pid,
        .cwd = owned_cwd.?,
        .prompt = owned_prompt.?,
        .log_path = owned_log_path.?,
        .process_token = null,
        .exit_code = exit_code,
    };
}

fn snapshotFromValue(alloc: Allocator, value: std.json.Value) !Snapshot {
    const object = switch (value) {
        .object => |item| item,
        else => return error.InvalidResponse,
    };
    const running = valueBool(object.get("running")) orelse return error.InvalidResponse;
    const pid = if (object.get("pid")) |item| switch (item) {
        .integer => |number| number,
        .null => null,
        else => return error.InvalidResponse,
    } else null;
    const jobs_value = object.get("jobs") orelse return error.InvalidResponse;
    const jobs_array = switch (jobs_value) {
        .array => |items| items,
        else => return error.InvalidResponse,
    };
    const jobs = try alloc.alloc(JobSnapshot, jobs_array.items.len);
    errdefer alloc.free(jobs);
    var initialized: usize = 0;
    errdefer for (jobs[0..initialized]) |*job| job.deinit(alloc);
    for (jobs_array.items, 0..) |job_value, index| {
        const job_object = switch (job_value) {
            .object => |item| item,
            else => return error.InvalidResponse,
        };
        const decoded = try decodeJob(alloc, job_object);
        jobs[index] = decoded;
        initialized += 1;
    }
    return .{ .running = running, .pid = pid, .jobs = jobs };
}

fn decodeResponse(alloc: Allocator, bytes: []const u8) !Response {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |item| item,
        else => return error.InvalidResponse,
    };
    const version = valueInt(object.get("version")) orelse return error.InvalidResponse;
    if (version != protocol_version) return error.ProtocolMismatch;
    const ok = valueBool(object.get("ok")) orelse return error.InvalidResponse;
    const message = if (object.get("message")) |item| valueString(item) else null;
    const job_id = if (object.get("job_id")) |item| valueString(item) else null;
    const snapshot_value = object.get("snapshot");
    const owned_message = if (message) |text| try alloc.dupe(u8, text) else null;
    errdefer if (owned_message) |text| alloc.free(text);
    const owned_job_id = if (job_id) |id| try alloc.dupe(u8, id) else null;
    errdefer if (owned_job_id) |id| alloc.free(id);
    return .{
        .ok = ok,
        .message = owned_message,
        .message_owned = owned_message != null,
        .job_id = owned_job_id,
        .snapshot = if (snapshot_value) |item| switch (item) {
            .null => null,
            else => try snapshotFromValue(alloc, item),
        } else null,
    };
}

fn processRequest(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
    worker_threads: *WorkerThreads,
    line: []const u8,
    stopping: *bool,
) !Response {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidRequest,
    };
    const version = object.get("version") orelse return error.InvalidRequest;
    switch (version) {
        .integer => |number| if (number != protocol_version) return error.ProtocolMismatch,
        else => return error.ProtocolMismatch,
    }
    const op = valueString(object.get("op")) orelse return error.InvalidRequest;
    if (std.mem.eql(u8, op, "status") or std.mem.eql(u8, op, "jobs")) {
        return .{ .ok = true, .snapshot = try snapshot(alloc, paths, process_provider) };
    }
    if (std.mem.eql(u8, op, "show")) {
        const id = valueString(object.get("id")) orelse return error.InvalidRequest;
        return .{ .ok = true, .snapshot = try snapshotJob(alloc, paths, process_provider, id) };
    }
    if (std.mem.eql(u8, op, "submit")) {
        const cwd = valueString(object.get("cwd")) orelse return error.InvalidRequest;
        const prompt = valueString(object.get("prompt")) orelse return error.InvalidRequest;
        if (prompt.len == 0 or prompt.len > max_prompt_bytes) return error.InvalidPrompt;
        const resolved_cwd = try io_mod.realpathAlloc(alloc, cwd);
        defer alloc.free(resolved_cwd);
        var job = try spawnWorker(
            alloc,
            paths,
            process_provider,
            worker_threads,
            resolved_cwd,
            prompt,
        );
        const id = try alloc.dupe(u8, job.id);
        job.deinit(alloc);
        return .{ .ok = true, .job_id = id };
    }
    if (std.mem.eql(u8, op, "stop")) {
        const id = valueString(object.get("id")) orelse return error.InvalidRequest;
        try stopJob(alloc, paths, process_provider, id);
        return .{ .ok = true, .message = "stopped" };
    }
    if (std.mem.eql(u8, op, "shutdown")) {
        stopping.* = true;
        return .{ .ok = true, .message = "stopping" };
    }
    return error.UnknownOperation;
}

fn writeResponse(writer: *std.Io.Writer, alloc: Allocator, response: Response) !void {
    _ = alloc;
    try writer.print("{{\"version\":{d},\"ok\":{},\"message\":", .{ protocol_version, response.ok });
    if (response.message) |message| try std.json.Stringify.value(message, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"job_id\":");
    if (response.job_id) |job_id| try std.json.Stringify.value(job_id, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll(",\"snapshot\":");
    if (response.snapshot) |value| {
        try writer.print("{{\"running\":{},\"pid\":", .{value.running});
        if (value.pid) |pid| try writer.print("{d}", .{pid}) else try writer.writeAll("null");
        try writer.writeAll(",\"jobs\":[");
        for (value.jobs, 0..) |job, index| {
            if (index > 0) try writer.writeByte(',');
            try std.json.Stringify.value(.{
                .id = job.id,
                .state = @tagName(job.state),
                .pid = job.pid,
                .cwd = job.cwd,
                .prompt = job.prompt,
                .log_path = job.log_path,
                .exit_code = job.exit_code,
            }, .{}, writer);
        }
        try writer.writeAll("]}");
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
    try writer.writeByte('\n');
}

fn writeBoundedResponse(
    writer: *std.Io.Writer,
    alloc: Allocator,
    response: Response,
) !void {
    const frame = try alloc.alloc(u8, max_frame_bytes);
    defer alloc.free(frame);
    var bounded: std.Io.Writer = .fixed(frame);
    writeResponse(&bounded, alloc, response) catch {
        bounded = .fixed(frame);
        try writeResponse(
            &bounded,
            alloc,
            .{ .ok = false, .message = "ResponseTooLarge" },
        );
    };
    try writer.writeAll(bounded.buffered());
}

pub fn runSupervisor(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
) !void {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) return error.DaemonUnsupported;
    try prepare(paths);
    var daemon_dir = try openDaemonDir(paths);
    defer daemon_dir.close();
    var ownership = io_mod.acquireTimedAdvisoryLock(&daemon_dir, "supervisor.lock", 0) catch |err| switch (err) {
        error.LockBusy => return error.DaemonAlreadyRunning,
        else => return err,
    };
    defer ownership.release();
    if (supervisorAlive(alloc, paths, process_provider)) return error.DaemonAlreadyRunning;
    if (std.Io.Dir.cwd().statFile(io_mod.getIo(), paths.socket, .{ .follow_symlinks = false })) |stat| {
        if (stat.kind != .unix_domain_socket) return error.DaemonEndpointUnsafe;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), paths.socket) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), paths.identity) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const address = try std.Io.net.UnixAddress.init(paths.socket);
    var server = try address.listen(io_mod.getIo(), .{});
    defer server.deinit(io_mod.getIo());
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), paths.socket) catch {};
    try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), paths.socket, std.Io.File.Permissions.fromMode(socket_mode), .{ .follow_symlinks = false });
    try writeSupervisorIdentity(alloc, paths, process_provider);
    defer std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), paths.identity) catch {};
    var worker_threads = WorkerThreads{};
    defer worker_threads.joinAll(alloc);
    defer stopJobs(alloc, paths, process_provider);
    var stopping = false;
    while (!stopping) {
        var stream = try server.accept(io_mod.getIo());
        defer stream.close(io_mod.getIo());
        setSocketTimeouts(stream);
        const line = readLine(stream, alloc) catch continue;
        defer alloc.free(line);
        var response = processRequest(
            alloc,
            paths,
            process_provider,
            &worker_threads,
            line,
            &stopping,
        ) catch |err| Response{ .ok = false, .message = @errorName(err) };
        defer response.deinit(alloc);
        var buffer: [8192]u8 = undefined;
        var writer = stream.writer(io_mod.getIo(), &buffer);
        writeBoundedResponse(&writer.interface, alloc, response) catch {};
        writer.interface.flush() catch {};
    }
}

pub fn ensureStarted(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
) !void {
    if (supervisorAlive(alloc, paths, process_provider)) return;
    try prepare(paths);
    const executable = try std.process.executablePathAlloc(io_mod.getIo(), alloc);
    defer alloc.free(executable);
    const argv = [_][]const u8{ executable, internal_mode };
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag == .macos or builtin.os.tag == .linux) 0 else null,
    });
    var child_owned = true;
    errdefer if (child_owned) child.kill(io_mod.getIo());
    if (child.id == null) return error.DaemonPidUnavailable;
    const deadline = io_mod.milliTimestamp() + 2_000;
    while (io_mod.milliTimestamp() < deadline) {
        if (supervisorAlive(alloc, paths, process_provider)) {
            const reaper = try std.Thread.spawn(.{}, reapSupervisorProcess, .{child.id.?});
            reaper.detach();
            child_owned = false;
            return;
        }
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return error.DaemonStartTimeout;
}

fn reapSupervisorProcess(pid: std.process.Child.Id) void {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos) {
        return;
    }
    while (true) {
        const waited = std.c.waitpid(pid, null, 0);
        switch (std.c.errno(waited)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return,
        }
    }
}

pub fn waitUntilStopped(
    alloc: Allocator,
    paths: *const Paths,
    process_provider: background_process_provider.Provider,
    timeout_ms: i64,
) bool {
    const deadline = io_mod.milliTimestamp() + timeout_ms;
    while (io_mod.milliTimestamp() < deadline) {
        if (!supervisorAlive(alloc, paths, process_provider)) return true;
        io_mod.sleep(10 * std.time.ns_per_ms);
    }
    return !supervisorAlive(alloc, paths, process_provider);
}

test "daemon paths stay below private profile state" {
    var paths = try Paths.init(std.testing.allocator, "/tmp/fx-home");
    defer paths.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/fx-home/.fx/daemon", paths.root);
    try std.testing.expectEqualStrings("/tmp/fx-home/.fx/daemon/supervisor.sock", paths.socket);
    try std.testing.expectEqualStrings("/tmp/fx-home/.fx/daemon/jobs", paths.jobs);
    try std.testing.expectError(
        error.InvalidStatePath,
        Paths.init(std.testing.allocator, "relative-home"),
    );
}

test "daemon request frames are versioned JSONL" {
    const line = try requestJson(std.testing.allocator, .{ .submit = .{ .cwd = "/tmp", .prompt = "hello" } });
    defer std.testing.allocator.free(line);
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
    try std.testing.expect(std.mem.find(u8, line, "\"version\":1") != null);
    try std.testing.expect(std.mem.find(u8, line, "\"op\":\"submit\"") != null);
}

test "daemon job IDs reject traversal and accept generated shape" {
    try std.testing.expect(validJobId("job-1234-abcd"));
    try std.testing.expect(!validJobId("job-../secret"));
    try std.testing.expect(!validJobId("job-1234/secret"));
    try std.testing.expect(!validJobId("../job-1234-abcd"));
}

test "daemon snapshots sort jobs by creation timestamp" {
    const empty = @as([]u8, @constCast(""));
    var jobs = [_]JobSnapshot{
        .{ .id = @constCast("job-2-b"), .state = .queued, .pid = null, .cwd = empty, .prompt = empty, .log_path = empty, .process_token = null, .exit_code = null },
        .{ .id = @constCast("job-10-c"), .state = .queued, .pid = null, .cwd = empty, .prompt = empty, .log_path = empty, .process_token = null, .exit_code = null },
        .{ .id = @constCast("job-1-a"), .state = .queued, .pid = null, .cwd = empty, .prompt = empty, .log_path = empty, .process_token = null, .exit_code = null },
    };
    std.mem.sort(JobSnapshot, &jobs, {}, lessJob);
    try std.testing.expectEqualStrings("job-1-a", jobs[0].id);
    try std.testing.expectEqualStrings("job-2-b", jobs[1].id);
    try std.testing.expectEqualStrings("job-10-c", jobs[2].id);
}

test "daemon log tails and protocol responses remain bounded" {
    const alloc = std.testing.allocator;
    const oversized = try alloc.alloc(u8, max_log_bytes + 8);
    defer alloc.free(oversized);
    @memset(oversized, 'x');
    @memcpy(oversized[oversized.len - 4 ..], "tail");
    var tail: std.ArrayList(u8) = .empty;
    defer tail.deinit(alloc);
    try appendBoundedTail(&tail, alloc, oversized);
    try std.testing.expectEqual(max_log_bytes, tail.items.len);
    try std.testing.expectEqualStrings("tail", tail.items[tail.items.len - 4 ..]);

    const prompt = try alloc.alloc(u8, max_frame_bytes);
    defer alloc.free(prompt);
    @memset(prompt, 'p');
    var jobs = [_]JobSnapshot{.{
        .id = @constCast("job-1234-abcd"),
        .state = .running,
        .pid = 42,
        .cwd = @constCast("/tmp"),
        .prompt = prompt,
        .log_path = @constCast("/tmp/job.log"),
        .process_token = null,
        .exit_code = null,
    }};
    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();
    try writeBoundedResponse(&output.writer, alloc, .{ .ok = true, .snapshot = .{
        .running = true,
        .pid = 7,
        .jobs = &jobs,
    } });
    try std.testing.expect(output.written().len < max_frame_bytes);
    try std.testing.expect(std.mem.find(u8, output.written(), "ResponseTooLarge") != null);
}
