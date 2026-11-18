//! The kept sandbox for one repository: its name, its record on disk, its
//! lock across fx processes, and the helper the sandbox runs to keep its copy
//! in step with this machine.
const std = @import("std");
const api = @import("api.zig");
const archive = @import("archive.zig");
const client_mod = @import("client.zig");
const config = @import("config.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const executor = @import("executor.zig");
const io_mod = @import("../shared/io.zig");
const local_git = @import("local_git.zig");
const sync_plan = @import("sync_plan.zig");

const Allocator = std.mem.Allocator;

/// The helper the sandbox runs, as shell text.
pub const remote_helper: []const u8 = @embedFile("remote_sync.sh");

const name_prefix = "fx-ws-";
const name_len = 22;
const hex_digits = "0123456789abcdef";
const object_id_len = 40;
const max_record_bytes = 64 * 1024;
const private_file_mode = 0o600;

/// `fx-ws-` and 16 hex digits of a SHA-256 of the user, the host, and the
/// repository's top folder, joined with NUL bytes. The same repository on
/// the same machine always gets the same name.
pub fn sandboxName(buf: *[name_len]u8, user: []const u8, host: []const u8, top: []const u8) []const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(user);
    hasher.update(&.{0});
    hasher.update(host);
    hasher.update(&.{0});
    hasher.update(top);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    @memcpy(buf[0..name_prefix.len], name_prefix);
    for (digest[0..8], 0..) |byte, index| {
        buf[name_prefix.len + 2 * index] = hex_digits[byte >> 4];
        buf[name_prefix.len + 2 * index + 1] = hex_digits[byte & 0x0f];
    }
    return buf;
}

/// What fx remembers about a workspace sandbox between sessions.
pub const Record = struct {
    top: []const u8,
    /// The tree the sandbox held after the last sync, or null before the first.
    synced_tree: ?[]const u8 = null,
    /// Paths the last bring-back touched. The next sync sends them again.
    forced: []const []const u8 = &.{},
    /// True once the warm script ran in this sandbox.
    warmed: bool = false,
};

/// `<sandbox_dir>/workspaces/<name>.json`.
pub fn recordPath(arena: Allocator, sandbox_dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    return arena.print("{s}/workspaces/{s}.json", .{ sandbox_dir, name });
}

/// Null when the file is missing. A record that cannot be read or does not
/// check out is logged and also returns null, so the caller starts over with
/// a full sync rather than trusting it.
pub fn loadRecord(arena: Allocator, path: []const u8) Allocator.Error!?Record {
    const zio = io_mod.getIo();
    var file = std.Io.Dir.cwd().openFile(zio, path, .{}) catch |err| {
        if (err != error.FileNotFound) logDropped(err);
        return null;
    };
    defer file.close(zio);
    const bytes = io_mod.readFileToEnd(arena, &file, max_record_bytes) catch |err| {
        if (isOutOfMemory(err)) return error.OutOfMemory;
        logDropped(err);
        return null;
    };
    return parseRecord(arena, bytes) catch |err| {
        if (isOutOfMemory(err)) return error.OutOfMemory;
        logDropped(err);
        return null;
    };
}

/// Writes the record through a temporary file and a rename, making folders as needed.
pub fn saveRecord(arena: Allocator, path: []const u8, record: Record) !void {
    var out = try std.Io.Writer.Allocating.initCapacity(arena, 256);
    try std.json.Stringify.value(record, .{ .emit_null_optional_fields = false }, &out.writer);
    try out.writer.writeAll("\n");
    if (std.Io.Dir.path.dirname(path)) |parent| try io_mod.makeDirRecursive(parent);
    try io_mod.writeFileAtomic(arena, path, out.written());
}

const RecordError = error{ InvalidRecord, OutOfMemory };

fn parseRecord(arena: Allocator, bytes: []const u8) RecordError!Record {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |err| {
        return if (isOutOfMemory(err)) error.OutOfMemory else error.InvalidRecord;
    };
    const object = switch (value) {
        .object => |map| map,
        else => return error.InvalidRecord,
    };
    const top = switch (object.get("top") orelse return error.InvalidRecord) {
        .string => |text| text,
        else => return error.InvalidRecord,
    };
    if (top.len == 0) return error.InvalidRecord;

    var synced_tree: ?[]const u8 = null;
    if (object.get("synced_tree")) |tree_value| {
        switch (tree_value) {
            .null => {},
            .string => |tree| {
                if (!isObjectId(tree)) return error.InvalidRecord;
                synced_tree = tree;
            },
            else => return error.InvalidRecord,
        }
    }

    var forced: std.ArrayList([]const u8) = .empty;
    if (object.get("forced")) |forced_value| {
        switch (forced_value) {
            .null => {},
            .array => |items| {
                for (items.items) |item| {
                    const path = switch (item) {
                        .string => |text| text,
                        else => return error.InvalidRecord,
                    };
                    if (!sync_plan.safeRelativePath(path)) return error.InvalidRecord;
                    try forced.append(arena, path);
                }
            },
            else => return error.InvalidRecord,
        }
    }

    var warmed = false;
    if (object.get("warmed")) |warmed_value| {
        switch (warmed_value) {
            .null => {},
            .bool => |flag| {
                warmed = flag;
            },
            else => return error.InvalidRecord,
        }
    }
    return .{
        .top = top,
        .synced_tree = synced_tree,
        .forced = try forced.toOwnedSlice(arena),
        .warmed = warmed,
    };
}

/// An exclusive lock on `<record path>.lock`, held across fx processes until `release`.
pub const Lock = struct {
    file: std.Io.File,

    /// Waits for another fx process that holds the lock, then takes it. The
    /// operating system frees the lock when the holding process exits, so a
    /// crash cannot leave it held.
    pub fn acquire(arena: Allocator, record_path: []const u8) !Lock {
        const zio = io_mod.getIo();
        const lock_path = try arena.print("{s}.lock", .{record_path});
        const file = try std.Io.Dir.cwd().createFile(zio, lock_path, .{
            .truncate = false,
            .permissions = std.Io.File.Permissions.fromMode(private_file_mode),
        });
        errdefer file.close(zio);
        try file.lock(zio, .exclusive);
        return .{ .file = file };
    }

    pub fn release(self: *Lock) void {
        const zio = io_mod.getIo();
        self.file.unlock(zio);
        self.file.close(zio);
        self.* = undefined;
    }
};

/// `remote_root ++ path`: the same path in the sandbox. `path` is the absolute
/// path on this machine, and `remote_root` is empty or an absolute path with no
/// trailing slash.
pub fn remotePath(arena: Allocator, remote_root: []const u8, path: []const u8) Allocator.Error![]u8 {
    return arena.print("{s}{s}", .{ remote_root, path });
}

/// A helper script and the name it runs under, such as `fx-sync` or `fx-iso`.
pub const Helper = struct {
    script: []const u8,
    name: []const u8,
};

/// The sync helper for a workspace sandbox.
pub const sync_helper: Helper = .{ .script = remote_helper, .name = "fx-sync" };

/// Shell text that runs the helper with `args`, as `shellCommand` does.
pub fn helperCommand(arena: Allocator, args: []const []const u8) Allocator.Error![]u8 {
    return shellCommand(arena, remote_helper, "fx-sync", args);
}

/// Shell text that runs `script` as `bash -c`, with `name` and then `args`.
/// Each script and argument is in single quotes, and an embedded `'` is
/// written as `'\''`. `name` must be a plain word, because it is not quoted.
pub fn shellCommand(arena: Allocator, script: []const u8, name: []const u8, args: []const []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "bash -c ");
    try appendQuoted(arena, &out, script);
    try out.append(arena, ' ');
    try out.appendSlice(arena, name);
    for (args) |arg| {
        try out.append(arena, ' ');
        try appendQuoted(arena, &out, arg);
    }
    return out.toOwnedSlice(arena);
}

fn appendQuoted(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.append(arena, '\'');
    for (text) |byte| {
        if (byte == '\'') {
            try out.appendSlice(arena, "'\\''");
        } else {
            try out.append(arena, byte);
        }
    }
    try out.append(arena, '\'');
}

fn isObjectId(text: []const u8) bool {
    if (text.len != object_id_len) return false;
    for (text) |byte| {
        const hex = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!hex) return false;
    }
    return true;
}

fn isOutOfMemory(err: anyerror) bool {
    return err == error.OutOfMemory;
}

fn logDropped(err: anyerror) void {
    debug_trace.logf("sandbox", "workspace record dropped, starting over with a full sync err={s}", .{@errorName(err)});
}

// ---- sync ----

/// Turns a profile's source into one that a create request takes. A recipe becomes its snapshot.
pub const SourceResolver = struct {
    context: *anyopaque,
    resolve: *const fn (context: *anyopaque, arena: Allocator, source: config.Source, failure: *client_mod.Failure) anyerror!config.Source,
};

/// What a workspace sandbox needs from the sandbox runtime.
pub const Env = struct {
    client: client_mod.Client,
    profile: config.WorkspaceProfile,
    remote_root: []const u8,
    /// `$FX_HOME/sandbox`.
    sandbox_dir: []const u8,
    user: []const u8,
    host: []const u8,
    resolver: SourceResolver,
    /// Most bytes of changed files fx copies back after one command.
    bring_back_max_bytes: usize = 256 * 1024 * 1024,
    /// How long one helper run may take. The default is the 10 minute limit.
    helper_timeout_ms: i64 = helper_deadline_ms,
};

/// One repository's sandbox in this fx process. `sync` holds `mutex` while it works.
pub const Lease = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    top: []const u8,
    name_buf: [name_len]u8,
    name_len: usize,
    session: ?[]u8 = null,
    prepared: bool = false,

    /// Copies `top`. The sandbox name comes from the user, the host, and `top`.
    pub fn init(alloc: Allocator, top: []const u8, user: []const u8, host: []const u8) error{OutOfMemory}!Lease {
        const owned = try alloc.dupe(u8, top);
        var lease: Lease = .{ .alloc = alloc, .top = owned, .name_buf = undefined, .name_len = 0 };
        lease.name_len = sandboxName(&lease.name_buf, user, host, owned).len;
        return lease;
    }

    pub fn deinit(self: *Lease) void {
        self.forgetSessionLocked();
        self.alloc.free(self.top);
        self.* = undefined;
    }

    pub fn name(self: *const Lease) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// Forgets the session, so the next sync reads or resumes the sandbox again.
    pub fn dropSession(self: *Lease) void {
        const zio = io_mod.getIo();
        self.mutex.lockUncancelable(zio);
        defer self.mutex.unlock(zio);
        self.forgetSessionLocked();
    }

    fn forgetSessionLocked(self: *Lease) void {
        if (self.session) |session| self.alloc.free(session);
        self.session = null;
        self.prepared = false;
    }
};

/// What a sync reports when it succeeds.
pub const SyncReport = struct {
    session: []const u8,
    /// The baseline commit in the sandbox. A bring-back compares against it.
    baseline: []const u8,
    /// Files sent by the last apply.
    sent: usize,
    /// Files removed by the last apply.
    removed: usize,
    /// True when the sync sent every file, either first or after a repair.
    full: bool,
    created: bool,
};

/// Errors of one helper run and of the API calls around it.
pub const HelperError = error{ SandboxApiFailed, OutOfMemory };

pub const SyncError = error{
    SandboxApiFailed,
    SandboxCopyMismatch,
    NotARepository,
    GitFailed,
    /// A local file, lock, or archive step failed.
    LocalFailed,
    OutOfMemory,
};

const max_batch_bytes: u64 = 24 * 1024 * 1024;
const max_batch_paths = 5000;
const max_upload_archive_bytes = 48 * 1024 * 1024;
const max_incremental_removals = 1000;
const max_helper_output_bytes = 32 * 1024 * 1024;
const max_stderr_tail_bytes = 300;
pub const helper_deadline_ms: i64 = 10 * 60 * 1000;

const Plan = struct {
    send: []const []const u8,
    remove: []const []const u8,
};

const Applied = struct {
    commit: []const u8,
    tree: []const u8,
};

const SessionInfo = struct {
    id: []const u8,
    created: bool,
};

/// Makes the sandbox copy of `lease.top` match this machine. It uploads only
/// what changed since the last sync, and it runs one full sync when the copies
/// may differ. `failure` says why on an error.
pub fn sync(lease: *Lease, env: Env, arena: Allocator, failure: *client_mod.Failure) SyncError!SyncReport {
    const zio = io_mod.getIo();
    lease.mutex.lockUncancelable(zio);
    defer lease.mutex.unlock(zio);

    var held = try lockRecord(lease, env, arena, failure);
    defer held.lock.release();
    const record_path = held.path;

    var touched = false;
    return syncLocked(lease, env, arena, failure, record_path, &touched) catch |err| return failedSync(lease, arena, record_path, touched, err);
}

/// The record file and its lock for one repository.
const RecordLock = struct {
    path: []const u8,
    lock: Lock,
};

/// Makes the record folder and takes the record lock for `lease`.
fn lockRecord(lease: *Lease, env: Env, arena: Allocator, failure: *client_mod.Failure) SyncError!RecordLock {
    const record_path = try recordPath(arena, env.sandbox_dir, lease.name());
    if (std.Io.Dir.path.dirname(record_path)) |folder| {
        io_mod.makeDirRecursive(folder) catch return localFailure(failure, "could not make the sandbox record folder");
    }
    const lock = Lock.acquire(arena, record_path) catch return localFailure(failure, "could not lock the sandbox record");
    return .{ .path = record_path, .lock = lock };
}

/// Ends a sync or bring-back that failed. A failed API call forgets the
/// session. A failure after files may have changed drops the record, so the
/// next sync starts with a full one.
fn failedSync(lease: *Lease, arena: Allocator, record_path: []const u8, touched: bool, err: SyncError) SyncError {
    if (err == error.SandboxApiFailed) lease.forgetSessionLocked();
    if (touched) invalidateRecord(arena, lease.top, record_path);
    return err;
}

fn syncLocked(
    lease: *Lease,
    env: Env,
    arena: Allocator,
    failure: *client_mod.Failure,
    record_path: []const u8,
    touched: *bool,
) SyncError!SyncReport {
    const info = try ensureSession(lease, env, arena, failure);
    const session = info.id;
    const remote_top = try remotePath(arena, env.remote_root, lease.top);

    var forced_new = false;
    if (!lease.prepared) {
        touched.* = true;
        const prepared = try runSandboxHelper(env, arena, session, &.{ "prepare", remote_top }, failure);
        forced_new = std.mem.eql(u8, lastLine(prepared), "new");
        lease.prepared = true;
    }

    const record = try trustedRecord(arena, record_path, lease.top);
    const tree = try local_git.snapshotTree(arena, lease.top);
    const gitlinks = try local_git.hasGitlinks(arena, lease.top, tree);

    var base: ?[]const u8 = null;
    if (record) |saved| base = saved.synced_tree;
    var full = forced_new or base == null or !local_git.hasTree(arena, lease.top, base.?);

    var plan: Plan = undefined;
    if (!full) {
        plan = try incrementalPlan(arena, failure, lease.top, base.?, record.?.forced, tree);
        if (plan.remove.len > max_incremental_removals) full = true;
    }
    if (full) plan = try fullPlan(arena, lease.top, tree);

    var did_full = full;
    touched.* = true;
    if (did_full) _ = try runSandboxHelper(env, arena, session, &.{ "reset", remote_top }, failure);
    var applied = try applyPlan(env, arena, session, remote_top, lease.top, plan, failure);

    // The sandbox tree must equal this machine's tree. A copy that drifted gets one full repair.
    if (!gitlinks and !std.mem.eql(u8, applied.tree, tree)) {
        if (did_full) return copyMismatch(arena, failure, lease.top);
        did_full = true;
        plan = try fullPlan(arena, lease.top, tree);
        _ = try runSandboxHelper(env, arena, session, &.{ "reset", remote_top }, failure);
        applied = try applyPlan(env, arena, session, remote_top, lease.top, plan, failure);
        if (!std.mem.eql(u8, applied.tree, tree)) return copyMismatch(arena, failure, lease.top);
    }

    try local_git.keepTree(arena, lease.top, lease.name(), tree);
    const keep_warm = if (record) |saved| saved.warmed and !forced_new else false;
    saveRecord(arena, record_path, .{
        .top = lease.top,
        .synced_tree = tree,
        .forced = &.{},
        .warmed = keep_warm,
    }) catch return localFailure(failure, "could not save the sandbox record");

    return .{
        .session = try arena.dupe(u8, session),
        .baseline = try arena.dupe(u8, applied.commit),
        .sent = plan.send.len,
        .removed = plan.remove.len,
        .full = did_full,
        .created = info.created,
    };
}

/// The session for this lease. It reads or resumes the sandbox, or creates it.
fn ensureSession(lease: *Lease, env: Env, arena: Allocator, failure: *client_mod.Failure) SyncError!SessionInfo {
    if (lease.session) |id| return .{ .id = id, .created = false };
    const name = lease.name();
    const found = env.client.getSandbox(arena, name, true, failure) catch |err| return clientFailure(err);
    if (found) |sandbox| return rememberSession(lease, sandbox.session_id, false);

    const source = env.resolver.resolve(env.resolver.context, arena, env.profile.source, failure) catch |err| return resolveFailure(err, failure);
    const tags = [_]api.Pair{.{ .name = "fx", .value = "workspace" }};
    const created = env.client.createSandbox(arena, .{
        .name = name,
        .project = env.client.project,
        .persistent = env.profile.keep,
        .timeout_ms = @as(u64, env.profile.timeout_minutes) * 60 * 1000,
        .source = source,
        .vcpus = env.profile.vcpus,
        .tags = &tags,
    }, failure) catch |err| switch (err) {
        error.SandboxExists => {
            const again = env.client.getSandbox(arena, name, true, failure) catch |again_err| return clientFailure(again_err);
            const sandbox = again orelse {
                failure.message = "the sandbox exists but could not be read";
                return error.SandboxApiFailed;
            };
            return rememberSession(lease, sandbox.session_id, false);
        },
        else => return clientFailure(err),
    };
    return rememberSession(lease, created.session_id, true);
}

fn rememberSession(lease: *Lease, id: []const u8, created: bool) SyncError!SessionInfo {
    const owned = try lease.alloc.dupe(u8, id);
    lease.session = owned;
    lease.prepared = false;
    return .{ .id = owned, .created = created };
}

/// Runs the helper in the sandbox and returns its stdout. A failure names the
/// helper and says why.
fn runSandboxHelper(
    env: Env,
    arena: Allocator,
    session: []const u8,
    args: []const []const u8,
    failure: *client_mod.Failure,
) HelperError![]const u8 {
    return runRemoteHelper(env.client, env.helper_timeout_ms, sync_helper, arena, session, args, failure);
}

/// Runs the helper with `args` in a session and returns its stdout. The
/// helper runs under a plain `bash -c`, so a login profile cannot print into
/// its output. The run stops `timeout_ms` after it starts.
pub fn runRemoteHelper(
    client: client_mod.Client,
    timeout_ms: i64,
    helper: Helper,
    arena: Allocator,
    session: []const u8,
    args: []const []const u8,
    failure: *client_mod.Failure,
) HelperError![]const u8 {
    const command = try shellCommand(arena, helper.script, helper.name, args);
    const outcome = try executor.execute(client, arena, .{
        .session = session,
        .command = command,
        .remote_cwd = "/",
        .login = false,
    }, .{
        .max_output_bytes = max_helper_output_bytes,
        .deadline_ms = io_mod.milliTimestamp() + timeout_ms,
    }, null);
    const name = args[0];
    if (outcome.stop == .timed_out) {
        failure.message = try arena.print("the sandbox helper {s} took longer than 10 minutes", .{name});
        return error.SandboxApiFailed;
    }
    if (outcome.failure) |detail| return helperFailure(arena, failure, name, detail);
    if (outcome.connection_lost) return helperFailure(arena, failure, name, "the connection ended before it finished");
    const code = outcome.exit_code orelse return helperFailure(arena, failure, name, "it did not finish");
    if (code != 0) {
        const tail = try outputTail(arena, outcome.stderr, max_stderr_tail_bytes);
        const detail = try arena.print("exit {d}: {s}", .{ code, tail });
        return helperFailure(arena, failure, name, detail);
    }
    return outcome.stdout;
}

fn helperFailure(arena: Allocator, failure: *client_mod.Failure, name: []const u8, detail: []const u8) HelperError {
    failure.message = try arena.print("the sandbox helper {s} failed: {s}", .{ name, detail });
    return error.SandboxApiFailed;
}

/// The last `limit` bytes of a command's output, trimmed, with control bytes made printable.
pub fn outputTail(arena: Allocator, bytes: []const u8, limit: usize) Allocator.Error![]const u8 {
    const tail = bytes[bytes.len - @min(bytes.len, limit) ..];
    const copy = try arena.dupe(u8, tail);
    for (copy) |*byte| {
        if ((byte.* < 0x20 and byte.* != '\n') or byte.* == 0x7f) byte.* = '?';
    }
    return std.mem.trim(u8, copy, " \t\r\n");
}

/// Deletes a sandbox. A failed delete is logged as `what` and returns false.
/// The caller carries on: the sandbox stops at its timeout, or the startup
/// sweep removes it later.
pub fn deleteSandboxLogged(client: client_mod.Client, arena: Allocator, name: []const u8, what: []const u8) bool {
    var failure: client_mod.Failure = .{};
    client.deleteSandbox(arena, name, &failure) catch |err| {
        debug_trace.logf("sandbox", "{s} {s} was not deleted err={s}", .{ what, name, @errorName(err) });
        return false;
    };
    return true;
}

/// Sends the plan's files, then applies the plan in the sandbox. Returns the
/// commit and the tree the sandbox now holds.
fn applyPlan(
    env: Env,
    arena: Allocator,
    session: []const u8,
    remote_top: []const u8,
    top: []const u8,
    plan: Plan,
    failure: *client_mod.Failure,
) SyncError!Applied {
    try uploadPaths(env, arena, session, remote_top, top, plan.send, failure);
    var args: std.ArrayList([]const u8) = .empty;
    try args.appendSlice(arena, &.{ "apply", remote_top });
    try args.appendSlice(arena, plan.remove);
    const out = try runSandboxHelper(env, arena, session, args.items, failure);
    const applied = parseApplied(out) orelse return helperFailure(arena, failure, "apply", "it printed no commit and tree");
    return applied;
}

/// The commit and tree are the last two non-empty lines. A login shell may
/// print lines before the helper does.
fn parseApplied(text: []const u8) ?Applied {
    var commit: []const u8 = "";
    var tree: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        commit = tree;
        tree = trimmed;
    }
    if (!isObjectId(commit) or !isObjectId(tree)) return null;
    return .{ .commit = commit, .tree = tree };
}

/// The last non-empty line of `text`, trimmed.
fn lastLine(text: []const u8) []const u8 {
    var last: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) last = trimmed;
    }
    return last;
}

/// Packs `paths` into archives of one batch each, and writes each into the sandbox folder.
fn uploadPaths(
    env: Env,
    arena: Allocator,
    session: []const u8,
    remote_top: []const u8,
    top: []const u8,
    paths: []const []const u8,
    failure: *client_mod.Failure,
) SyncError!void {
    var start: usize = 0;
    while (start < paths.len) {
        const end = try batchEnd(arena, top, paths, start);
        const batch = archive.build(arena, top, paths[start..end], .{
            .max_bytes = max_upload_archive_bytes,
            .links = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return localFailure(failure, "the files for the sandbox upload could not be packed"),
        };
        env.client.writeArchive(arena, session, batch, remote_top, failure) catch |err| return clientFailure(err);
        start = end;
    }
}

/// The size of the regular file at `full`. A link is left alone. Null when
/// the path is missing or is not a regular file.
pub fn regularFileSize(full: []const u8) ?u64 {
    const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), full, .{ .follow_symlinks = false }) catch return null;
    if (stat.kind != .file) return null;
    return stat.size;
}

/// The size of a regular file in the working copy. A missing path or a non-file counts as 0.
pub fn fileSize(arena: Allocator, top: []const u8, path: []const u8) Allocator.Error!u64 {
    const full = try arena.print("{s}/{s}", .{ top, path });
    return regularFileSize(full) orelse 0;
}

/// The end of the batch that starts at `start`: at most `max_batch_paths`
/// paths and `max_batch_bytes` of file sizes. A batch always holds one path.
pub fn batchEnd(arena: Allocator, top: []const u8, paths: []const []const u8, start: usize) Allocator.Error!usize {
    var end = start;
    var bytes: u64 = 0;
    while (end < paths.len and end - start < max_batch_paths) {
        const size = try fileSize(arena, top, paths[end]);
        if (end > start and bytes + size > max_batch_bytes) break;
        bytes += size;
        end += 1;
    }
    return end;
}

fn existsLocally(arena: Allocator, top: []const u8, path: []const u8) Allocator.Error!bool {
    const full = try arena.print("{s}/{s}", .{ top, path });
    _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), full, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn containsPath(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |path| {
        if (std.mem.eql(u8, path, needle)) return true;
    }
    return false;
}

pub fn uniquePaths(arena: Allocator, paths: []const []const u8) Allocator.Error![]const []const u8 {
    var unique: std.ArrayList([]const u8) = .empty;
    for (paths) |path| {
        if (!containsPath(unique.items, path)) try unique.append(arena, path);
    }
    return unique.toOwnedSlice(arena);
}

/// The plan that moves the sandbox from `base` to `tree`. A forced path, which
/// the last bring-back touched, is sent again when it is in the new tree and
/// still on disk. Otherwise it is removed.
fn incrementalPlan(
    arena: Allocator,
    failure: *client_mod.Failure,
    top: []const u8,
    base: []const u8,
    forced_raw: []const []const u8,
    tree: []const u8,
) SyncError!Plan {
    const diff = try local_git.diffTrees(arena, top, base, tree);
    const forced = try uniquePaths(arena, forced_raw);
    const present = try local_git.listTree(arena, top, tree);
    const exists = try arena.alloc(bool, forced.len);
    for (forced, exists) |path, *flag| {
        flag.* = false;
        if (containsPath(present, path)) flag.* = try existsLocally(arena, top, path);
    }
    const upload = sync_plan.planUpload(arena, diff, forced, exists) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return localFailure(failure, "the sandbox diff could not be read"),
    };
    return .{ .send = upload.send, .remove = upload.remove };
}

/// The plan that puts every file of `tree` in the sandbox, after a reset.
fn fullPlan(arena: Allocator, top: []const u8, tree: []const u8) SyncError!Plan {
    return .{ .send = try local_git.listTree(arena, top, tree), .remove = &.{} };
}

/// The record at `record_path` when it names `top`. A record for another folder is dropped with a log line.
fn trustedRecord(arena: Allocator, record_path: []const u8, top: []const u8) Allocator.Error!?Record {
    const loaded = (try loadRecord(arena, record_path)) orelse return null;
    if (!std.mem.eql(u8, loaded.top, top)) {
        debug_trace.logf("sandbox", "workspace record names another folder, so it is not trusted", .{});
        return null;
    }
    return loaded;
}

/// Drops the record after a failed sync or bring-back that may have changed
/// files, so the next sync starts with a full one. The file is removed. When
/// that fails, the record is saved without its tree.
fn invalidateRecord(arena: Allocator, top: []const u8, record_path: []const u8) void {
    debug_trace.logf("sandbox", "workspace sync or bring-back failed after files may have changed, so its record is dropped", .{});
    std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), record_path) catch |err| {
        if (err == error.FileNotFound) return;
        saveRecord(arena, record_path, .{ .top = top, .synced_tree = null }) catch |save_err| {
            debug_trace.logf("sandbox", "workspace record could not be dropped err={s}", .{@errorName(save_err)});
        };
    };
}

pub fn clientFailure(err: client_mod.Error) HelperError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.SandboxApiFailed,
    };
}

pub fn resolveFailure(err: anyerror, failure: *client_mod.Failure) HelperError {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    if (failure.message.len == 0) failure.message = "could not resolve the sandbox source";
    return error.SandboxApiFailed;
}

pub fn localFailure(failure: *client_mod.Failure, message: []const u8) error{LocalFailed} {
    failure.message = message;
    return error.LocalFailed;
}

fn copyMismatch(arena: Allocator, failure: *client_mod.Failure, top: []const u8) SyncError {
    failure.message = try arena.print("the sandbox copy of {s} does not match this machine after a full sync", .{top});
    return error.SandboxCopyMismatch;
}

/// What a bring-back did. Every path is in the caller's arena.
pub const BringBack = struct {
    /// Written or deleted here, as the command left them in the sandbox.
    taken: []const []const u8 = &.{},
    /// Changed here and in the sandbox. This machine's version stays.
    conflicts: []const []const u8 = &.{},
    /// Never brought back: links, submodules, unsafe paths.
    refused: []const []const u8 = &.{},
    /// Already the same here.
    same: usize = 0,
    /// The changed files were over the size limit, so none were copied.
    too_large: bool = false,
};

/// Brings back the files a command changed in the sandbox since `baseline`.
/// Each change follows the 3-way rule, so a file changed here since the sync
/// keeps this machine's version. Every changed path is forced, so the next
/// sync sends this machine's version of it again.
pub fn bringBack(
    lease: *Lease,
    env: Env,
    arena: Allocator,
    baseline: []const u8,
    failure: *client_mod.Failure,
) SyncError!BringBack {
    const zio = io_mod.getIo();
    lease.mutex.lockUncancelable(zio);
    defer lease.mutex.unlock(zio);

    var held = try lockRecord(lease, env, arena, failure);
    defer held.lock.release();
    const record_path = held.path;

    var touched = false;
    return bringBackLocked(lease, env, arena, failure, record_path, baseline, &touched) catch |err| return failedSync(lease, arena, record_path, touched, err);
}

/// The warm script's deadline and size limits.
const warm_deadline_ms: i64 = 60 * 60 * 1000;
const max_warm_script_bytes = 1024 * 1024;
const max_warm_output_bytes = 1024 * 1024;
const max_warm_archive_bytes = 48 * 1024 * 1024;

/// What a warm run left behind. `baseline` is the sandbox commit after the run,
/// or null when that commit could not be recorded, so bring-back must not run.
pub const WarmResult = struct {
    baseline: ?[]const u8,
    /// Why the script did not finish cleanly, when it did not.
    problem: ?[]const u8 = null,
};

/// Runs the warm script once in the workspace sandbox, then commits what it
/// left as the new baseline. A warm script should change only ignored files,
/// such as caches. If it changes tracked files, they never come back to this
/// machine: the next sync restores this machine's versions.
/// The script goes to `<remote_top>/.git/fx-warm.sh` and runs under a login
/// shell in the repository's folder, with a 60-minute deadline. `cancel_flag`
/// stops it early. A script that never started leaves the sandbox as it was,
/// and the call fails. A script that ran is recorded as warmed only when it
/// exits 0. The lease and the record stay locked for the whole run, as `sync`
/// keeps them.
pub fn runWarm(
    lease: *Lease,
    env: Env,
    arena: Allocator,
    script_path: []const u8,
    output: ?executor.Output,
    cancel_flag: ?*std.atomic.Value(bool),
    failure: *client_mod.Failure,
) SyncError!WarmResult {
    const zio = io_mod.getIo();
    lease.mutex.lockUncancelable(zio);
    defer lease.mutex.unlock(zio);

    var held = try lockRecord(lease, env, arena, failure);
    defer held.lock.release();
    const session = lease.session orelse {
        failure.message = "the workspace sandbox is not running";
        return error.SandboxApiFailed;
    };
    const remote_top = try remotePath(arena, env.remote_root, lease.top);
    try uploadWarmScript(env, arena, session, remote_top, lease.name(), script_path, failure);
    try announceWarm(arena, output, script_path, failure);
    const outcome = try executor.execute(env.client, arena, .{
        .session = session,
        .command = "bash .git/fx-warm.sh",
        .remote_cwd = remote_top,
        .login = true,
    }, .{
        .cancel_flag = cancel_flag,
        .max_output_bytes = max_warm_output_bytes,
        .deadline_ms = io_mod.milliTimestamp() + warm_deadline_ms,
    }, output);
    if (!outcome.started and !outcome.connection_lost) {
        // The start was refused or never answered, so the script did not run.
        failure.message = try arena.print("the warm script {s} did not start: {s}", .{ script_path, outcome.failure orelse "the API gave no answer" });
        return error.SandboxApiFailed;
    }
    // The script ran, or may have. Its writes become the baseline, so the next
    // bring-back does not see them as this command's changes.
    const baseline = applyBaseline(env, arena, session, remote_top, failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{
            .baseline = null,
            .problem = try arena.print("the warm script {s} ran, but its result could not be recorded: {s}", .{ script_path, messageOrName(failure, err) }),
        },
    };
    const problem = try warmProblem(arena, script_path, outcome);
    if (problem == null) {
        markWarmed(arena, held.path, lease.top, failure) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .{ .baseline = baseline, .problem = messageOrName(failure, err) },
        };
    }
    return .{ .baseline = baseline, .problem = problem };
}

/// Commits the sandbox's working copy as the new baseline and returns its commit.
fn applyBaseline(env: Env, arena: Allocator, session: []const u8, remote_top: []const u8, failure: *client_mod.Failure) SyncError![]const u8 {
    const out = try runSandboxHelper(env, arena, session, &.{ "apply", remote_top }, failure);
    const applied = parseApplied(out) orelse return helperFailure(arena, failure, "apply", "it printed no commit and tree");
    return applied.commit;
}

/// The reason a warm run did not finish cleanly, or null when it exited 0.
fn warmProblem(arena: Allocator, script_path: []const u8, outcome: executor.Outcome) Allocator.Error!?[]const u8 {
    if (outcome.stop == .timed_out) return try arena.print("the warm script {s} took longer than 60 minutes", .{script_path});
    if (outcome.stop == .cancelled) return try arena.print("the warm script {s} was stopped", .{script_path});
    if (outcome.connection_lost) return try arena.print("the connection ended before the warm script {s} finished", .{script_path});
    const code = outcome.exit_code orelse return try arena.print("the warm script {s} did not report an exit code", .{script_path});
    if (code == 0) return null;
    const combined = try arena.alloc(u8, outcome.stdout.len + outcome.stderr.len);
    @memcpy(combined[0..outcome.stdout.len], outcome.stdout);
    @memcpy(combined[outcome.stdout.len..], outcome.stderr);
    const tail = try outputTail(arena, combined, max_stderr_tail_bytes);
    return try arena.print("the warm script {s} failed with exit {d}: {s}", .{ script_path, code, tail });
}

/// The failure's message, or the error's name when no message was set.
fn messageOrName(failure: *const client_mod.Failure, err: anyerror) []const u8 {
    return if (failure.message.len > 0) failure.message else @errorName(err);
}

/// Reads the warm script and sends it into the repository's `.git` folder as
/// `fx-warm.sh`. The copy goes through fx's own staging folder, so the file
/// name in the sandbox does not depend on the script's name here.
fn uploadWarmScript(
    env: Env,
    arena: Allocator,
    session: []const u8,
    remote_top: []const u8,
    lease_name: []const u8,
    script_path: []const u8,
    failure: *client_mod.Failure,
) SyncError!void {
    const zio = io_mod.getIo();
    var source = std.Io.Dir.cwd().openFile(zio, script_path, .{}) catch {
        failure.message = try arena.print("the warm script {s} cannot be read", .{script_path});
        return error.LocalFailed;
    };
    defer source.close(zio);
    const script = io_mod.readFileToEnd(arena, &source, max_warm_script_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            failure.message = try arena.print("the warm script {s} cannot be read", .{script_path});
            return error.LocalFailed;
        },
    };
    const staging = try arena.print("{s}/warm/{s}", .{ env.sandbox_dir, lease_name });
    io_mod.makeDirRecursive(staging) catch return localFailure(failure, "the warm folder cannot be created");
    const staged = try arena.print("{s}/fx-warm.sh", .{staging});
    io_mod.writeFileAtomic(arena, staged, script) catch return localFailure(failure, "the warm script cannot be staged");
    defer std.Io.Dir.deleteFileAbsolute(zio, staged) catch {};
    const bytes = archive.build(arena, staging, &.{"fx-warm.sh"}, .{ .max_bytes = max_warm_archive_bytes }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return localFailure(failure, "the warm script cannot be packed for the sandbox"),
    };
    const git_dir = try arena.print("{s}/.git", .{remote_top});
    env.client.writeArchive(arena, session, bytes, git_dir, failure) catch |err| return clientFailure(err);
}

/// Tells the output relay, before the warm script runs, what is happening.
fn announceWarm(arena: Allocator, output: ?executor.Output, script_path: []const u8, failure: *client_mod.Failure) SyncError!void {
    const sink = output orelse return;
    const line = try arena.print("fx: warming the workspace sandbox with {s}; this runs once.\n", .{script_path});
    sink.on_line(sink.context, .stdout, line) catch return localFailure(failure, "the warm output could not be shown");
}

/// Sets `warmed` in the saved record and keeps the rest of it.
fn markWarmed(arena: Allocator, record_path: []const u8, top: []const u8, failure: *client_mod.Failure) SyncError!void {
    const saved = (try loadRecord(arena, record_path)) orelse {
        return localFailure(failure, "the sandbox record is missing after the warm script");
    };
    if (!std.mem.eql(u8, saved.top, top)) return localFailure(failure, "the sandbox record names another folder");
    saveRecord(arena, record_path, .{
        .top = saved.top,
        .synced_tree = saved.synced_tree,
        .forced = saved.forced,
        .warmed = true,
    }) catch return localFailure(failure, "could not save the sandbox record");
}

fn bringBackLocked(
    lease: *Lease,
    env: Env,
    arena: Allocator,
    failure: *client_mod.Failure,
    record_path: []const u8,
    baseline: []const u8,
    touched: *bool,
) SyncError!BringBack {
    const session = lease.session orelse {
        failure.message = "the workspace sandbox is not running";
        return error.SandboxApiFailed;
    };
    const remote_top = try remotePath(arena, env.remote_root, lease.top);
    const archive_path = try arena.print("{s}/.git/fx-changes.tgz", .{remote_top});
    const listed = try runSandboxHelper(env, arena, session, &.{ "changes", remote_top, baseline, archive_path }, failure);
    const changes = sync_plan.parseRawDiff(arena, listed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            failure.message = "the sandbox changed-files list could not be read";
            return error.SandboxApiFailed;
        },
    };
    if (changes.len == 0) return .{};

    const paths = try arena.alloc([]const u8, changes.len);
    for (changes, paths) |change, *path| path.* = change.path;
    const blobs = try local_git.localBlobs(arena, lease.top, paths);

    var writes: std.ArrayList([]const u8) = .empty;
    var deletes: std.ArrayList([]const u8) = .empty;
    var conflicts: std.ArrayList([]const u8) = .empty;
    var refused: std.ArrayList([]const u8) = .empty;
    var same: usize = 0;
    for (changes, blobs) |change, local_blob| {
        switch (sync_plan.decide(change, local_blob)) {
            .take => {
                if (change.new_blob != null) {
                    try writes.append(arena, change.path);
                } else {
                    try deletes.append(arena, change.path);
                }
            },
            .already_same => {
                same += 1;
            },
            .conflict => try conflicts.append(arena, change.path),
            .refuse => try refused.append(arena, change.path),
        }
    }

    // The size is known from the archive headers before any write, so a
    // change over the limit writes nothing and deletes nothing.
    var packed_bytes: []const u8 = &.{};
    var too_large = false;
    if (writes.items.len > 0) {
        packed_bytes = (env.client.readFile(arena, session, archive_path, failure) catch |err| return clientFailure(err)) orelse {
            failure.message = "the sandbox did not pack the changed files";
            return error.SandboxApiFailed;
        };
        const wanted_bytes = archive.regularFileBytes(arena, packed_bytes, writes.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                failure.message = "the sandbox packed changed files that cannot be read";
                return error.SandboxApiFailed;
            },
        };
        const limit: u64 = env.bring_back_max_bytes;
        too_large = wanted_bytes > limit;
    }

    var taken: std.ArrayList([]const u8) = .empty;
    if (too_large) {
        debug_trace.logf("sandbox", "bring-back left {d} changed files in the sandbox, over the size limit", .{writes.items.len + deletes.items.len});
    } else if (writes.items.len > 0 or deletes.items.len > 0) {
        touched.* = true;
        if (writes.items.len > 0) {
            const extracted = archive.extract(arena, packed_bytes, lease.top, writes.items, env.bring_back_max_bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidArchive => {
                    failure.message = "the sandbox packed changed files that cannot be read";
                    return error.SandboxApiFailed;
                },
                error.ArchiveTooLarge => return localFailure(failure, "the changed files grew past the size limit while they were copied"),
                error.WriteFailed => return localFailure(failure, "a changed file could not be written here"),
            };
            try taken.appendSlice(arena, extracted.written);
            for (extracted.refused) |path| {
                if (!containsPath(refused.items, path)) try refused.append(arena, path);
            }
        }
        for (deletes.items) |path| {
            // A link or a folder on the way to the file would move the delete outside the repository.
            if (!(try parentsAreRealFolders(arena, lease.top, path))) {
                try conflicts.append(arena, path);
                continue;
            }
            const full = try arena.print("{s}/{s}", .{ lease.top, path });
            const stat = std.Io.Dir.cwd().statFile(io_mod.getIo(), full, .{ .follow_symlinks = false }) catch |err| {
                if (err != error.FileNotFound) return localFailure(failure, "a deleted file could not be checked here");
                continue;
            };
            if (stat.kind != .file) {
                try conflicts.append(arena, path);
                continue;
            }
            debug_trace.logf("sandbox", "bring-back removes {s}: the command deleted it in the sandbox", .{path});
            std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), full) catch return localFailure(failure, "a deleted file could not be removed here");
            try taken.append(arena, path);
        }
    }

    if (try trustedRecord(arena, record_path, lease.top)) |saved| {
        var forced: std.ArrayList([]const u8) = .empty;
        try forced.appendSlice(arena, saved.forced);
        for (changes) |change| {
            // An unsafe path cannot be in a record. A full sync repairs it in the sandbox.
            if (!sync_plan.safeRelativePath(change.path)) continue;
            if (!containsPath(forced.items, change.path)) try forced.append(arena, change.path);
        }
        saveRecord(arena, record_path, .{
            .top = saved.top,
            .synced_tree = saved.synced_tree,
            .forced = try forced.toOwnedSlice(arena),
            .warmed = saved.warmed,
        }) catch return localFailure(failure, "could not save the sandbox record");
    }

    return .{
        .taken = try taken.toOwnedSlice(arena),
        .conflicts = try conflicts.toOwnedSlice(arena),
        .refused = try refused.toOwnedSlice(arena),
        .same = same,
        .too_large = too_large,
    };
}

/// True when every folder between `top` and `path` is a real folder, not a
/// link. Deleting through a folder link would remove a file outside the repository.
fn parentsAreRealFolders(arena: Allocator, top: []const u8, path: []const u8) Allocator.Error!bool {
    const zio = io_mod.getIo();
    var prefix = top;
    var rest = path;
    while (std.mem.findScalar(u8, rest, '/')) |slash| {
        prefix = try arena.print("{s}/{s}", .{ prefix, rest[0..slash] });
        const stat = std.Io.Dir.cwd().statFile(zio, prefix, .{ .follow_symlinks = false }) catch return false;
        if (stat.kind != .directory) return false;
        rest = rest[slash + 1 ..];
    }
    return true;
}

// ---- tests ----

const testing = std.testing;

const test_sandbox = @import("test_sandbox.zig");
const FakeSandbox = test_sandbox.FakeSandbox;
const Ran = test_sandbox.Ran;
const runCommand = test_sandbox.runCommand;
const helperToolsAvailable = test_sandbox.toolsAvailable;

/// Runs the helper with `args`: the command, the folder, and their arguments.
fn runHelper(arena: Allocator, args: []const []const u8) !Ran {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "bash", "-c", remote_helper, "fx-sync" });
    try argv.appendSlice(arena, args);
    return runCommand(arena, ".", argv.items);
}

fn pathExists(dir: std.Io.Dir, sub_path: []const u8) bool {
    _ = dir.statFile(io_mod.getIo(), sub_path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn readAt(arena: Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    const zio = io_mod.getIo();
    var file = try dir.openFile(zio, sub_path, .{});
    defer file.close(zio);
    return io_mod.readFileToEnd(arena, &file, 1 << 20);
}

fn listContains(names: []const []const u8, needle: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, needle)) return true;
    }
    return false;
}

fn findChange(changes: []const sync_plan.Change, path: []const u8) ?sync_plan.Change {
    for (changes) |change| {
        if (std.mem.eql(u8, change.path, path)) return change;
    }
    return null;
}

/// The files every helper test starts from, under `root` in `dir`.
fn writeFixture(arena: Allocator, dir: std.Io.Dir, root: []const u8) !void {
    const zio = io_mod.getIo();
    const folder = std.Io.File.Permissions.fromMode(0o755);
    try dir.writeFile(zio, .{ .sub_path = try arena.print("{s}/a.txt", .{root}), .data = "one\n" });
    try dir.createDir(zio, try arena.print("{s}/bin", .{root}), folder);
    var script = try dir.createFile(zio, try arena.print("{s}/bin/run.sh", .{root}), .{ .permissions = folder });
    defer script.close(zio);
    try script.writeStreamingAll(zio, "#!/bin/sh\necho hi\n");
    try dir.writeFile(zio, .{ .sub_path = try arena.print("{s}/.gitignore", .{root}), .data = "out/\n" });
    try dir.createDir(zio, try arena.print("{s}/out", .{root}), folder);
    try dir.writeFile(zio, .{ .sub_path = try arena.print("{s}/out/x", .{root}), .data = "ignored\n" });
}

test "sandbox names are stable and per repository" {
    var first: [name_len]u8 = undefined;
    var again: [name_len]u8 = undefined;
    var other: [name_len]u8 = undefined;
    const name = sandboxName(&first, "faxes", "host", "/repo");
    try testing.expectEqualStrings(name, sandboxName(&again, "faxes", "host", "/repo"));
    try testing.expect(!std.mem.eql(u8, name, sandboxName(&other, "faxes", "host", "/other")));
    try testing.expectEqual(@as(usize, 22), name.len);
    try testing.expect(std.mem.startsWith(u8, name, "fx-ws-"));
    for (name[name_prefix.len..]) |byte| {
        const allowed = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-';
        try testing.expect(allowed);
    }
}

test "records round-trip and bad records start over" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");

    const path = try recordPath(arena, dir, "fx-ws-test");
    try testing.expectEqualStrings(try arena.print("{s}/workspaces/fx-ws-test.json", .{dir}), path);
    const tree_hex = "0123456789" ++ "abcdef0123" ++ "456789abcd" ++ "ef01234567";
    const saved: Record = .{
        .top = "/repo",
        .synced_tree = tree_hex,
        .forced = &.{ "a.txt", "bin/run.sh" },
        .warmed = true,
    };
    try saveRecord(arena, path, saved);
    const loaded = (try loadRecord(arena, path)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/repo", loaded.top);
    try testing.expectEqualStrings(tree_hex, loaded.synced_tree orelse return error.TestUnexpectedResult);
    try testing.expectEqual(@as(usize, 2), loaded.forced.len);
    try testing.expectEqualStrings("bin/run.sh", loaded.forced[1]);
    try testing.expect(loaded.warmed);

    try tmp.dir.writeFile(zio, .{ .sub_path = "broken.json", .data = "{" });
    try tmp.dir.writeFile(zio, .{ .sub_path = "short.json", .data = "{\"top\":\"/repo\",\"synced_tree\":\"abc\"}" });
    try testing.expect((try loadRecord(arena, try arena.print("{s}/broken.json", .{dir}))) == null);
    try testing.expect((try loadRecord(arena, try arena.print("{s}/short.json", .{dir}))) == null);
    try testing.expect((try loadRecord(arena, try arena.print("{s}/missing.json", .{dir}))) == null);
}

test "the lock can be taken again after release" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const path = try arena.print("{s}/fx-ws-lock.json", .{dir});

    var first = try Lock.acquire(arena, path);
    first.release();
    var second = try Lock.acquire(arena, path);
    second.release();
}

test "helper commands quote every argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try helperCommand(arena, &.{ "apply", "it's" });
    try testing.expect(std.mem.startsWith(u8, text, "bash -c '"));
    try testing.expect(std.mem.endsWith(u8, text, " fx-sync 'apply' 'it'\\''s'"));
}

test "the helper prepares a folder once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const folder = try arena.print("{s}/P", .{dir});

    const first = try runHelper(arena, &.{ "prepare", folder });
    try testing.expectEqual(@as(i64, 0), first.code);
    try testing.expectEqualStrings("new\n", first.stdout);
    try testing.expect(pathExists(tmp.dir, "P/.git"));

    const applied = try runHelper(arena, &.{ "apply", folder });
    try testing.expectEqual(@as(i64, 0), applied.code);

    const again = try runHelper(arena, &.{ "prepare", folder });
    try testing.expectEqual(@as(i64, 0), again.code);
    try testing.expectEqualStrings("existing\n", again.stdout);
}

test "the helper's tree equals this machine's tree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const sandbox = try arena.print("{s}/A", .{dir});
    const machine = try arena.print("{s}/B", .{dir});

    const prepared = try runHelper(arena, &.{ "prepare", sandbox });
    try testing.expectEqualStrings("new\n", prepared.stdout);
    try writeFixture(arena, tmp.dir, "A");

    try tmp.dir.createDir(zio, "B", std.Io.File.Permissions.fromMode(0o755));
    const init = try runCommand(arena, machine, &.{ "git", "init", "-q" });
    try testing.expectEqual(@as(i64, 0), init.code);
    try writeFixture(arena, tmp.dir, "B");

    const applied = try runHelper(arena, &.{ "apply", sandbox });
    try testing.expectEqual(@as(i64, 0), applied.code);
    var lines = std.mem.splitScalar(u8, applied.stdout, '\n');
    _ = lines.next();
    const helper_tree = lines.next() orelse return error.TestUnexpectedResult;
    const machine_tree = try local_git.snapshotTree(arena, machine);
    try testing.expectEqualStrings(machine_tree, helper_tree);
}

test "the helper reports changes and packs them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const sandbox = try arena.print("{s}/A", .{dir});

    _ = try runHelper(arena, &.{ "prepare", sandbox });
    try writeFixture(arena, tmp.dir, "A");
    const applied = try runHelper(arena, &.{ "apply", sandbox });
    var lines = std.mem.splitScalar(u8, applied.stdout, '\n');
    const commit = lines.next() orelse return error.TestUnexpectedResult;

    try tmp.dir.writeFile(zio, .{ .sub_path = "A/a.txt", .data = "uno\n" });
    try tmp.dir.writeFile(zio, .{ .sub_path = "A/c.txt", .data = "c\n" });
    try tmp.dir.deleteFile(zio, "A/bin/run.sh");
    const packed_path = try arena.print("{s}/.git/fx-changes.tgz", .{sandbox});
    const ran = try runHelper(arena, &.{ "changes", sandbox, commit, packed_path });
    try testing.expectEqual(@as(i64, 0), ran.code);

    const changes = try sync_plan.parseRawDiff(arena, ran.stdout);
    try testing.expectEqual(@as(usize, 3), changes.len);
    const edited = findChange(changes, "a.txt") orelse return error.TestUnexpectedResult;
    try testing.expect(edited.old_blob != null);
    try testing.expect(edited.new_blob != null);
    const added = findChange(changes, "c.txt") orelse return error.TestUnexpectedResult;
    try testing.expect(added.old_blob == null);
    const removed = findChange(changes, "bin/run.sh") orelse return error.TestUnexpectedResult;
    try testing.expect(removed.new_blob == null);
    try testing.expectEqual(sync_plan.Mode.absent, removed.new_mode);

    // The packed archive holds the added and changed files, and nothing else.
    const packed_bytes = try readAt(arena, tmp.dir, "A/.git/fx-changes.tgz");
    try tmp.dir.createDir(zio, "D", std.Io.File.Permissions.fromMode(0o755));
    const result = try archive.extract(arena, packed_bytes, try arena.print("{s}/D", .{dir}), null, 1 << 20);
    try testing.expectEqual(@as(usize, 2), result.written.len);
    try testing.expect(listContains(result.written, "a.txt"));
    try testing.expect(listContains(result.written, "c.txt"));
    try testing.expectEqual(@as(usize, 0), result.refused.len);
    try testing.expect(!pathExists(tmp.dir, "D/bin/run.sh"));
}

test "the helper reset keeps ignored files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const sandbox = try arena.print("{s}/A", .{dir});

    _ = try runHelper(arena, &.{ "prepare", sandbox });
    try writeFixture(arena, tmp.dir, "A");
    _ = try runHelper(arena, &.{ "apply", sandbox });

    const reset = try runHelper(arena, &.{ "reset", sandbox });
    try testing.expectEqual(@as(i64, 0), reset.code);
    try testing.expect(!pathExists(tmp.dir, "A/a.txt"));
    try testing.expect(!pathExists(tmp.dir, "A/bin/run.sh"));
    try testing.expect(pathExists(tmp.dir, "A/out/x"));
}

test "the helper refuses an unknown command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");

    const ran = try runHelper(arena, &.{ "bogus", dir });
    try testing.expectEqual(@as(i64, 2), ran.code);
}

fn identityResolve(context: *anyopaque, arena: Allocator, source: config.Source, failure: *client_mod.Failure) anyerror!config.Source {
    _ = context;
    _ = arena;
    _ = failure;
    return source;
}

/// An env for one test repository. `fake` answers for the sandbox API.
fn testEnv(fake: *FakeSandbox, disk: []const u8, sandbox_dir: []const u8) Env {
    return .{
        .client = test_sandbox.fakeClient(fake),
        .profile = .{},
        .remote_root = disk,
        .sandbox_dir = sandbox_dir,
        .user = "tester",
        .host = "host.test",
        .resolver = .{ .context = fake, .resolve = identityResolve },
    };
}

/// The files a sync test starts from, under `root` in `dir`. `zig-out/` is ignored.
fn writeSyncFiles(arena: Allocator, dir: std.Io.Dir, root: []const u8) !void {
    const zio = io_mod.getIo();
    const folder = std.Io.File.Permissions.fromMode(0o755);
    try dir.writeFile(zio, .{ .sub_path = try arena.print("{s}/a.txt", .{root}), .data = "one\n" });
    try dir.writeFile(zio, .{ .sub_path = try arena.print("{s}/b.txt", .{root}), .data = "two\n" });
    try dir.createDir(zio, try arena.print("{s}/bin", .{root}), folder);
    var script = try dir.createFile(zio, try arena.print("{s}/bin/run.sh", .{root}), .{ .permissions = folder });
    defer script.close(zio);
    try script.writeStreamingAll(zio, "#!/bin/sh\necho hi\n");
    try dir.writeFile(zio, .{ .sub_path = try arena.print("{s}/.gitignore", .{root}), .data = "zig-out/\n" });
    try dir.createDir(zio, try arena.print("{s}/zig-out", .{root}), folder);
    try dir.writeFile(zio, .{ .sub_path = try arena.print("{s}/zig-out/x", .{root}), .data = "built\n" });
}

const SyncFixture = struct {
    top: []const u8,
    disk: []const u8,
    sandbox_dir: []const u8,
    /// The sandbox copy of `top` on the disk.
    remote: []const u8,
};

/// A repository with the sync test files, plus a disk and a state folder, all in `tmp`.
fn syncFixture(arena: Allocator, tmp: *std.testing.TmpDir) !SyncFixture {
    const zio = io_mod.getIo();
    const folder = std.Io.File.Permissions.fromMode(0o755);
    const base = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");
    const top = try arena.print("{s}/repo", .{base});
    try tmp.dir.createDir(zio, "repo", folder);
    try tmp.dir.createDir(zio, "disk", folder);
    const init = try runCommand(arena, top, &.{ "git", "init", "-q" });
    try testing.expectEqual(@as(i64, 0), init.code);
    try writeSyncFiles(arena, tmp.dir, "repo");
    const disk = try arena.print("{s}/disk", .{base});
    return .{
        .top = top,
        .disk = disk,
        .sandbox_dir = try arena.print("{s}/state", .{base}),
        .remote = try remotePath(arena, disk, top),
    };
}

fn readAbsoluteText(arena: Allocator, path: []const u8) ![]u8 {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.openFileAbsolute(zio, path, .{});
    defer file.close(zio);
    return io_mod.readFileToEnd(arena, &file, 1 << 20);
}

fn writeAbsoluteText(path: []const u8, data: []const u8) !void {
    const zio = io_mod.getIo();
    var file = try std.Io.Dir.createFileAbsolute(zio, path, .{});
    defer file.close(zio);
    try file.writeStreamingAll(zio, data);
}

fn absoluteExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

test "the first sync creates the sandbox and sends every file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};

    const report = try sync(&lease, testEnv(&fake, fixture.disk, fixture.sandbox_dir), arena, &failure);
    try testing.expect(report.created);
    try testing.expect(report.full);
    try testing.expectEqual(@as(usize, 4), report.sent);
    try testing.expectEqual(@as(usize, 1), fake.creates);
    try testing.expectEqualStrings("one\n", try readAbsoluteText(arena, try arena.print("{s}/a.txt", .{fixture.remote})));
    try testing.expect(!absoluteExists(try arena.print("{s}/zig-out/x", .{fixture.remote})));

    const record = (try loadRecord(arena, try recordPath(arena, fixture.sandbox_dir, lease.name()))) orelse return error.TestUnexpectedResult;
    const tree = try local_git.snapshotTree(arena, fixture.top);
    try testing.expectEqualStrings(tree, record.synced_tree orelse return error.TestUnexpectedResult);
}

test "a later sync sends only what changed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    _ = try sync(&lease, env, arena, &failure);

    try tmp.dir.writeFile(zio, .{ .sub_path = "repo/a.txt", .data = "uno\n" });
    try tmp.dir.writeFile(zio, .{ .sub_path = "repo/n.txt", .data = "new\n" });
    try tmp.dir.deleteFile(zio, "repo/b.txt");
    const second = try sync(&lease, env, arena, &failure);

    try testing.expect(!second.full);
    try testing.expect(!second.created);
    try testing.expectEqual(@as(usize, 2), second.sent);
    try testing.expectEqual(@as(usize, 1), second.removed);
    try testing.expectEqualStrings("uno\n", try readAbsoluteText(arena, try arena.print("{s}/a.txt", .{fixture.remote})));
    try testing.expectEqualStrings("new\n", try readAbsoluteText(arena, try arena.print("{s}/n.txt", .{fixture.remote})));
    try testing.expect(!absoluteExists(try arena.print("{s}/b.txt", .{fixture.remote})));
}

test "a copy changed behind fx's back is repaired with a full sync" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    _ = try sync(&lease, env, arena, &failure);

    const remote_a = try arena.print("{s}/a.txt", .{fixture.remote});
    try writeAbsoluteText(remote_a, "tampered\n");
    const second = try sync(&lease, env, arena, &failure);

    try testing.expect(second.full);
    try testing.expectEqualStrings("one\n", try readAbsoluteText(arena, remote_a));
}

test "a record for another folder is not trusted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    _ = try sync(&lease, env, arena, &failure);

    const record_path = try recordPath(arena, fixture.sandbox_dir, lease.name());
    const saved = (try loadRecord(arena, record_path)) orelse return error.TestUnexpectedResult;
    try saveRecord(arena, record_path, .{ .top = "/elsewhere", .synced_tree = saved.synced_tree });
    const second = try sync(&lease, env, arena, &failure);

    try testing.expect(second.full);
}

test "ignored files in the sandbox survive a full sync" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    _ = try sync(&lease, env, arena, &failure);

    const remote_cache = try arena.print("{s}/zig-out/cache", .{fixture.remote});
    try io_mod.makeDirRecursive(try arena.print("{s}/zig-out", .{fixture.remote}));
    try writeAbsoluteText(remote_cache, "cached\n");

    // A record without a tree forces the full sync.
    const record_path = try recordPath(arena, fixture.sandbox_dir, lease.name());
    try saveRecord(arena, record_path, .{ .top = fixture.top });
    const second = try sync(&lease, env, arena, &failure);

    try testing.expect(second.full);
    try testing.expectEqualStrings("cached\n", try readAbsoluteText(arena, remote_cache));
}

test "a second sync reuses the session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    _ = try sync(&lease, env, arena, &failure);
    _ = try sync(&lease, env, arena, &failure);

    try testing.expectEqual(@as(usize, 1), fake.creates);
    try testing.expectEqual(@as(usize, 1), fake.gets);
}

test "bring-back takes the command's changes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    const synced = try sync(&lease, env, arena, &failure);

    // The command edits a.txt, adds c.txt, and deletes b.txt in the sandbox.
    try writeAbsoluteText(try arena.print("{s}/a.txt", .{fixture.remote}), "sandbox one\n");
    try writeAbsoluteText(try arena.print("{s}/c.txt", .{fixture.remote}), "new file\n");
    try std.Io.Dir.deleteFileAbsolute(zio, try arena.print("{s}/b.txt", .{fixture.remote}));

    const back = try bringBack(&lease, env, arena, synced.baseline, &failure);
    try testing.expect(!back.too_large);
    try testing.expectEqual(@as(usize, 3), back.taken.len);
    try testing.expect(listContains(back.taken, "a.txt"));
    try testing.expect(listContains(back.taken, "b.txt"));
    try testing.expect(listContains(back.taken, "c.txt"));
    try testing.expectEqualStrings("sandbox one\n", try readAbsoluteText(arena, try arena.print("{s}/a.txt", .{fixture.top})));
    try testing.expectEqualStrings("new file\n", try readAbsoluteText(arena, try arena.print("{s}/c.txt", .{fixture.top})));
    try testing.expect(!absoluteExists(try arena.print("{s}/b.txt", .{fixture.top})));

    const record = (try loadRecord(arena, try recordPath(arena, fixture.sandbox_dir, lease.name()))) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), record.forced.len);
}

test "bring-back keeps a file changed here" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    const synced = try sync(&lease, env, arena, &failure);

    try tmp.dir.writeFile(zio, .{ .sub_path = "repo/a.txt", .data = "local edit\n" });
    try writeAbsoluteText(try arena.print("{s}/a.txt", .{fixture.remote}), "remote edit\n");

    const back = try bringBack(&lease, env, arena, synced.baseline, &failure);
    try testing.expectEqual(@as(usize, 1), back.conflicts.len);
    try testing.expectEqualStrings("a.txt", back.conflicts[0]);
    try testing.expectEqual(@as(usize, 0), back.taken.len);
    try testing.expectEqualStrings("local edit\n", try readAbsoluteText(arena, try arena.print("{s}/a.txt", .{fixture.top})));
}

test "bring-back counts files that already match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    const synced = try sync(&lease, env, arena, &failure);

    try tmp.dir.writeFile(zio, .{ .sub_path = "repo/a.txt", .data = "same\n" });
    try writeAbsoluteText(try arena.print("{s}/a.txt", .{fixture.remote}), "same\n");

    const back = try bringBack(&lease, env, arena, synced.baseline, &failure);
    try testing.expectEqual(@as(usize, 1), back.same);
    try testing.expectEqual(@as(usize, 0), back.taken.len);
    try testing.expectEqual(@as(usize, 0), back.conflicts.len);
}

test "bring-back refuses links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    const synced = try sync(&lease, env, arena, &failure);

    try std.Io.Dir.symLinkAbsolute(zio, "/etc/passwd", try arena.print("{s}/l", .{fixture.remote}), .{});

    const back = try bringBack(&lease, env, arena, synced.baseline, &failure);
    try testing.expectEqual(@as(usize, 1), back.refused.len);
    try testing.expectEqualStrings("l", back.refused[0]);
    try testing.expectEqual(@as(usize, 0), back.taken.len);
    try testing.expect(!absoluteExists(try arena.print("{s}/l", .{fixture.top})));
}

test "the next sync sends a conflicted file again" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    const synced = try sync(&lease, env, arena, &failure);

    try tmp.dir.writeFile(zio, .{ .sub_path = "repo/a.txt", .data = "local edit\n" });
    try writeAbsoluteText(try arena.print("{s}/a.txt", .{fixture.remote}), "remote edit\n");
    const back = try bringBack(&lease, env, arena, synced.baseline, &failure);
    try testing.expectEqual(@as(usize, 1), back.conflicts.len);

    // This machine goes back to the synced text. Only the forced path can
    // bring the sandbox copy back to it.
    try tmp.dir.writeFile(zio, .{ .sub_path = "repo/a.txt", .data = "one\n" });
    const second = try sync(&lease, env, arena, &failure);
    try testing.expect(!second.full);
    try testing.expectEqual(@as(usize, 1), second.sent);
    try testing.expectEqualStrings("one\n", try readAbsoluteText(arena, try arena.print("{s}/a.txt", .{fixture.remote})));
}

test "bring-back over the size limit copies nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    var env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    env.bring_back_max_bytes = 10;
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    const synced = try sync(&lease, env, arena, &failure);

    // A 1 KiB change to a.txt and a deletion of b.txt, both in the sandbox.
    const big: [1024]u8 = @splat('x');
    try writeAbsoluteText(try arena.print("{s}/a.txt", .{fixture.remote}), &big);
    try std.Io.Dir.deleteFileAbsolute(zio, try arena.print("{s}/b.txt", .{fixture.remote}));

    const back = try bringBack(&lease, env, arena, synced.baseline, &failure);
    try testing.expect(back.too_large);
    try testing.expectEqual(@as(usize, 0), back.taken.len);
    try testing.expectEqualStrings("one\n", try readAbsoluteText(arena, try arena.print("{s}/a.txt", .{fixture.top})));
    try testing.expect(absoluteExists(try arena.print("{s}/b.txt", .{fixture.top})));
}

test "a copy that keeps differing fails the sync" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    _ = try sync(&lease, env, arena, &failure);

    // From now on every upload loses a.txt, so the copy can never match.
    try tmp.dir.writeFile(zio, .{ .sub_path = "repo/a.txt", .data = "changed here\n" });
    fake.drop_upload = true;
    try testing.expectError(error.SandboxCopyMismatch, sync(&lease, env, arena, &failure));
    try testing.expect(std.mem.find(u8, failure.message, "does not match this machine") != null);

    // The record holds no tree any more, so the next sync is a full one.
    const after = try loadRecord(arena, try recordPath(arena, fixture.sandbox_dir, lease.name()));
    try testing.expect(after == null or after.?.synced_tree == null);
}

test "a failed API call forgets the session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    _ = try sync(&lease, env, arena, &failure);
    try testing.expect(lease.session != null);

    fake.fail_commands = true;
    try testing.expectError(error.SandboxApiFailed, sync(&lease, env, arena, &failure));
    try testing.expect(lease.session == null);
}

test "a helper past its deadline fails the sync" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    var fake: FakeSandbox = .{ .disk = fixture.disk, .slow_commands = true };
    var env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    env.helper_timeout_ms = 200;
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};

    // The first helper run is prepare. It takes two seconds, and the deadline is 200 ms.
    try testing.expectError(error.SandboxApiFailed, sync(&lease, env, arena, &failure));
    try testing.expect(std.mem.find(u8, failure.message, "took longer than") != null);
}

test "a delete never goes through a linked folder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!helperToolsAvailable(arena)) return error.SkipZigTest;
    const zio = io_mod.getIo();
    const folder = std.Io.File.Permissions.fromMode(0o755);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fixture = try syncFixture(arena, &tmp);
    // A tracked file under dir, and a file with the same content outside the repository.
    try tmp.dir.createDir(zio, "repo/dir", folder);
    try tmp.dir.writeFile(zio, .{ .sub_path = "repo/dir/x", .data = "kept\n" });
    try tmp.dir.createDir(zio, "outside", folder);
    try tmp.dir.writeFile(zio, .{ .sub_path = "outside/x", .data = "kept\n" });
    const outside = try io_mod.dirRealpathAlloc(arena, tmp.dir, "outside");
    var fake: FakeSandbox = .{ .disk = fixture.disk };
    const env = testEnv(&fake, fixture.disk, fixture.sandbox_dir);
    var lease = try Lease.init(arena, fixture.top, "tester", "host.test");
    defer lease.deinit();
    var failure: client_mod.Failure = .{};
    const synced = try sync(&lease, env, arena, &failure);

    // The sandbox deletes dir/x. Here, dir becomes a link to the outside folder.
    try std.Io.Dir.deleteFileAbsolute(zio, try arena.print("{s}/dir/x", .{fixture.remote}));
    try tmp.dir.deleteTree(zio, "repo/dir");
    try tmp.dir.symLink(zio, outside, "repo/dir", .{});

    const back = try bringBack(&lease, env, arena, synced.baseline, &failure);
    try testing.expectEqual(@as(usize, 1), back.conflicts.len);
    try testing.expectEqualStrings("dir/x", back.conflicts[0]);
    try testing.expectEqual(@as(usize, 0), back.taken.len);
    try testing.expectEqualStrings("kept\n", try readAbsoluteText(arena, try arena.print("{s}/x", .{outside})));
}
