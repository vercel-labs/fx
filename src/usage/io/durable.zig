//! Private-state file primitives for the profile usage files under `~/.fx`.
//!
//! Each primitive keeps the checks and the durability order of fx's private
//! state helpers, so this module and older fx binaries agree on what a
//! safe profile file is:
//!
//! - directories are real (not symlinked) and mode 0700; writers repair the
//!   mode, readers only check it
//! - files are regular, singly linked, and mode 0600
//! - `usage.lock` is an exclusive advisory `tryLock`, polled every 10 ms up
//!   to a deadline (2 s for the ledger), on the same file older fx locks
//! - a replace is: temp file (exclusive, 0600) + write + fsync + rename +
//!   fsync of the target directory
//!
//! `Probe` names every durability point. Production code passes the empty
//! probe; the store lab uses it to stop the process at a chosen point so a
//! test can SIGKILL it there.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

pub const dir_mode: u32 = 0o700;
pub const file_mode: u32 = 0o600;
const dir_permissions = File.Permissions.fromMode(dir_mode);
const file_permissions = File.Permissions.fromMode(file_mode);
const lock_poll_ms: u64 = 10;

/// Every point where a crash leaves a different file state.
pub const Point = enum {
    /// `usage.lock` is held, nothing is written yet.
    lock_acquired,
    /// Half of an append is written (the probe splits the write in two).
    append_partial,
    /// The append is written, not yet fsynced.
    append_written,
    /// The append is fsynced, the lock is still held.
    append_synced,
    /// The replace's temp file exists and is empty.
    replace_temp_created,
    /// The temp file holds every byte, not yet fsynced.
    replace_temp_written,
    /// The temp file is fsynced, not yet renamed.
    replace_temp_synced,
    /// The rename happened, the directory is not yet fsynced.
    replace_renamed,
    /// The directory is fsynced: the replace is durable.
    replace_done,
    /// A marker is unlinked, its directory is not yet fsynced.
    marker_deleted,
};

/// Hook called at each `Point` (empty in production), and where a failed
/// replace records its cause.
pub const Probe = struct {
    ctx: ?*anyopaque = null,
    hit: ?*const fn (ctx: ?*anyopaque, point: Point) void = null,
    /// Set to the I/O error behind a `DurableReplacePreRenameFailed` or
    /// `DurableReplacePostRenameFailed`, such as `error.NoSpaceLeft`, for a
    /// host that reports it. One slot per call: copy the probe to set it.
    cause: ?*?anyerror = null,

    fn failed(probe: Probe, err: anyerror, as: ReplaceError) ReplaceError {
        if (probe.cause) |slot| slot.* = err;
        return as;
    }

    pub fn at(probe: Probe, point: Point) void {
        if (probe.hit) |hit| hit(probe.ctx, point);
    }

    pub fn active(probe: Probe) bool {
        return probe.hit != null;
    }
};

pub fn modeOf(permissions: File.Permissions) u32 {
    return @as(u32, @intCast(permissions.toMode())) & 0o777;
}

/// fsyncs a directory. The handle must come from an `openDir` with
/// `.iterate = true`: Linux returns an `O_PATH` descriptor otherwise, and
/// `fsync` rejects it.
pub fn syncDir(dir: Dir) error{ OperationUnsupported, NoSpaceLeft, DiskQuota, ReadOnlyFileSystem, DirectorySyncFailed }!void {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.OperationUnsupported;
    while (true) {
        const rc = std.posix.system.fsync(dir.handle);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .INVAL, .OPNOTSUPP => return error.OperationUnsupported,
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            .ROFS => return error.ReadOnlyFileSystem,
            else => return error.DirectorySyncFailed,
        }
    }
}

pub const PrivacyError = error{ DurablePathUnsafe, PrivateStatePermissionsUnsupported };

pub fn checkPrivateDir(stat: File.Stat) PrivacyError!void {
    if (stat.kind != .directory) return error.DurablePathUnsafe;
    if (modeOf(stat.permissions) != dir_mode) return error.PrivateStatePermissionsUnsupported;
}

/// A regular, singly linked, 0600 file.
pub fn checkPrivateFile(stat: File.Stat) PrivacyError!void {
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    if (modeOf(stat.permissions) != file_mode) return error.PrivateStatePermissionsUnsupported;
}

/// fx's `verifyOpenedRegularFile`: regular, and never hard linked. A
/// writable open also needs exactly one link.
pub fn checkRegular(stat: File.Stat, mode: Dir.OpenFileOptions.Mode) error{DurablePathUnsafe}!void {
    if (stat.kind != .file or stat.nlink > 1) return error.DurablePathUnsafe;
    if (mode != .read_only and stat.nlink != 1) return error.DurablePathUnsafe;
}

/// Opens `name` in `parent` as a directory without following a final
/// symlink. Null when it doesn't exist. Checks nothing else.
pub fn openDirNoFollow(io: Io, parent: Dir, name: []const u8) !?Dir {
    return parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        error.NotDir, error.SymLinkLoop => error.DurablePathUnsafe,
        else => err,
    };
}

/// fx's `openOrCreateVerifiedPrivateChild`: opens or creates `name` as a
/// private directory, repairs its mode to 0700, and fsyncs `parent` when it
/// created it. The caller owns the returned handle.
pub fn openOrCreatePrivateDir(io: Io, parent: Dir, name: []const u8) !Dir {
    var created = false;
    const dir = (try openDirNoFollow(io, parent, name)) orelse created: {
        parent.createDir(io, name, dir_permissions) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        created = true;
        break :created (try openDirNoFollow(io, parent, name)) orelse return error.FileNotFound;
    };
    errdefer dir.close(io);
    dir.setPermissions(io, dir_permissions) catch return error.PrivateStatePermissionsUnsupported;
    try checkPrivateDir(try dir.stat(io));
    if (created) try syncDir(parent);
    return dir;
}

/// Opens an existing regular file in `dir` without following a final
/// symlink, checked before and after the open. Null when it doesn't exist.
pub fn openRegularFile(io: Io, dir: Dir, name: []const u8, mode: Dir.OpenFileOptions.Mode) !?File {
    const before = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir, error.SymLinkLoop => return error.DurablePathUnsafe,
        else => return err,
    };
    try checkRegular(before, mode);
    const file = dir.openFile(io, name, .{
        .mode = mode,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop, error.IsDir, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer file.close(io);
    const after = try file.stat(io);
    try checkRegular(after, mode);
    if (after.inode != before.inode) return error.DurablePathUnsafe;
    return file;
}

// ---------------------------------------------------------------------------
// Lock

pub const Lock = struct {
    file: File,

    pub fn release(lock: *Lock, io: Io) void {
        lock.file.unlock(io);
        lock.file.close(io);
        lock.* = undefined;
    }
};

pub const LockError = error{ LockBusy, LockUnsupported, LockAbandoned };

/// fx's `openOrCreatePrivateLockFile`: open read-write, or create it
/// exclusively at 0600 and fsync `dir`; then it must be private.
fn openOrCreateLockFile(io: Io, dir: Dir, name: []const u8) !File {
    const file = dir.openFile(io, name, .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => created: {
            const created = dir.createFile(io, name, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .permissions = file_permissions,
                .resolve_beneath = true,
            }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => break :created try dir.openFile(io, name, .{
                    .mode = .read_write,
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                }),
                else => return create_err,
            };
            created.setPermissions(io, file_permissions) catch {
                created.close(io);
                return error.PrivateStatePermissionsUnsupported;
            };
            syncDir(dir) catch {
                created.close(io);
                return error.DirectorySyncFailed;
            };
            break :created created;
        },
        error.SymLinkLoop, error.IsDir, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer file.close(io);
    try checkPrivateFile(try file.stat(io));
    return file;
}

/// fx's reader-side open: an existing private lock file, or null.
fn openExistingLockFile(io: Io, dir: Dir, name: []const u8) !?File {
    const file = dir.openFile(io, name, .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.SymLinkLoop, error.IsDir, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer file.close(io);
    try checkPrivateFile(try file.stat(io));
    return file;
}

/// Whether a private lock file exists (fx's `lockFileExists`).
pub fn lockFileExists(io: Io, dir: Dir, name: []const u8) !bool {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    try checkPrivateFile(stat);
    return true;
}

pub const LockOptions = struct {
    deadline_ms: u64,
    /// Set from another thread to end a wait (process exit).
    abandoned: ?*const std.atomic.Value(bool) = null,
    /// Writers create the lock file; readers only use an existing one.
    create: bool,
};

/// Takes the exclusive advisory lock on `name`, polling until the deadline.
/// Null only when `create` is false and the lock file doesn't exist.
pub fn acquireLock(io: Io, dir: Dir, name: []const u8, options: LockOptions) !?Lock {
    const file = if (options.create)
        try openOrCreateLockFile(io, dir, name)
    else
        (try openExistingLockFile(io, dir, name)) orelse return null;
    errdefer file.close(io);

    const started = Io.Clock.awake.now(io).toMilliseconds();
    const deadline = std.math.add(i64, started, std.math.cast(i64, options.deadline_ms) orelse std.math.maxInt(i64)) catch std.math.maxInt(i64);
    while (true) {
        if (options.abandoned) |flag| {
            if (flag.load(.acquire)) return error.LockAbandoned;
        }
        const locked = file.tryLock(io, .exclusive) catch |err| switch (err) {
            error.FileLocksUnsupported => return error.LockUnsupported,
            else => return err,
        };
        if (locked) return .{ .file = file };
        if (Io.Clock.awake.now(io).toMilliseconds() >= deadline) return error.LockBusy;
        try io.sleep(.fromMilliseconds(@intCast(@min(lock_poll_ms, options.deadline_ms))), .awake);
    }
}

// ---------------------------------------------------------------------------
// Durable replace

pub const ReplaceError = error{
    DurablePathUnsafe,
    AccessDenied,
    PrivateStatePermissionsUnsupported,
    /// Nothing changed: the old file (or its absence) is still in place.
    DurableReplacePreRenameFailed,
    /// The rename may or may not be durable.
    DurableReplacePostRenameFailed,
};

pub const ReplaceOptions = struct {
    /// Directory for the temp file, on the same file system as the target.
    /// Defaults to the target directory, as fx does.
    temp_dir: ?Dir = null,
    probe: Probe = .{},
};

/// Longest replace target name (a session id is at most 255 bytes).
pub const max_name_bytes = 255;
const temp_suffix_hex = 32;

fn validateLeaf(name: []const u8) error{DurablePathUnsafe}!void {
    if (name.len == 0 or name.len > max_name_bytes or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))
    {
        return error.DurablePathUnsafe;
    }
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return error.DurablePathUnsafe;
}

/// Whether `name` is a replace temp for `target` (`.<target>.tmp.<32 hex>`).
pub fn isReplaceTemp(name: []const u8) bool {
    const marker = ".tmp.";
    if (name.len < 1 + 1 + marker.len + temp_suffix_hex or name[0] != '.') return false;
    const suffix = name[name.len - temp_suffix_hex ..];
    for (suffix) |char| switch (char) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return std.mem.endsWith(u8, name[0 .. name.len - temp_suffix_hex], marker);
}

fn validateTarget(io: Io, dir: Dir, name: []const u8) !void {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    if (modeOf(stat.permissions) & 0o222 == 0) return error.AccessDenied;
}

fn removeTemp(io: Io, dir: Dir, name: []const u8) void {
    const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return;
    if (stat.kind != .file or stat.nlink != 1) return;
    dir.deleteFile(io, name) catch {};
}

/// fx's `durableReplaceVerified`: replaces `dir/name` with `bytes` so a
/// crash leaves either the old file or the new one, never a mix.
pub fn replace(io: Io, dir: Dir, name: []const u8, bytes: []const u8, options: ReplaceOptions) ReplaceError!void {
    try validateLeaf(name);
    validateTarget(io, dir, name) catch |err| switch (err) {
        error.DurablePathUnsafe, error.AccessDenied => |e| return e,
        else => |e| return options.probe.failed(e, error.DurableReplacePreRenameFailed),
    };
    const temp_dir = options.temp_dir orelse dir;

    var random_bytes: [temp_suffix_hex / 2]u8 = undefined;
    io.random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    var temp_buffer: [1 + max_name_bytes + ".tmp.".len + temp_suffix_hex]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&temp_buffer, ".{s}.tmp.{s}", .{ name, suffix }) catch unreachable;

    const file = temp_dir.createFile(io, temp_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = file_permissions,
        .resolve_beneath = true,
    }) catch |err| return options.probe.failed(err, error.DurableReplacePreRenameFailed);
    var temp_exists = true;
    defer if (temp_exists) removeTemp(io, temp_dir, temp_name);
    defer file.close(io);
    options.probe.at(.replace_temp_created);

    file.setPermissions(io, file_permissions) catch return error.PrivateStatePermissionsUnsupported;
    const temp_stat = file.stat(io) catch |err| return options.probe.failed(err, error.DurableReplacePreRenameFailed);
    try checkPrivateFile(temp_stat);
    file.writeStreamingAll(io, bytes) catch |err| return options.probe.failed(err, error.DurableReplacePreRenameFailed);
    options.probe.at(.replace_temp_written);
    file.sync(io) catch |err| return options.probe.failed(err, error.DurableReplacePreRenameFailed);
    options.probe.at(.replace_temp_synced);
    temp_dir.rename(temp_name, dir, name, io) catch |err| return options.probe.failed(err, error.DurableReplacePreRenameFailed);
    temp_exists = false;
    options.probe.at(.replace_renamed);

    const final = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| return options.probe.failed(err, error.DurableReplacePostRenameFailed);
    checkPrivateFile(final) catch |err| return options.probe.failed(err, error.DurableReplacePostRenameFailed);
    syncDir(dir) catch |err| return options.probe.failed(err, error.DurableReplacePostRenameFailed);
    options.probe.at(.replace_done);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn tmpHome() testing.TmpDir {
    return testing.tmpDir(.{ .iterate = true });
}

test "a failed replace records the error behind it for the host" {
    const io = testing.io;
    var tmp = tmpHome();
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "target", .fromMode(0o700));
    // A temp directory that can't take the temp file.
    try tmp.dir.createDir(io, "locked", .fromMode(0o500));
    defer tmp.dir.setFilePermissions(io, "locked", .fromMode(0o700), .{}) catch {};
    var dir = try tmp.dir.openDir(io, "target", .{});
    defer dir.close(io);
    var temp_dir = try tmp.dir.openDir(io, "locked", .{});
    defer temp_dir.close(io);
    var cause: ?anyerror = null;
    try testing.expectError(error.DurableReplacePreRenameFailed, replace(io, dir, "file", "bytes", .{
        .temp_dir = temp_dir,
        .probe = .{ .cause = &cause },
    }));
    try testing.expectEqual(@as(?anyerror, error.AccessDenied), cause);
}

test "private dir: created at 0700, repaired from 0755, symlink refused" {
    const io = testing.io;
    var tmp = tmpHome();
    defer tmp.cleanup();

    var created = try openOrCreatePrivateDir(io, tmp.dir, "fresh");
    created.close(io);
    try testing.expectEqual(dir_mode, modeOf((try tmp.dir.statFile(io, "fresh", .{})).permissions));

    try tmp.dir.createDir(io, "loose", .fromMode(0o755));
    var repaired = try openOrCreatePrivateDir(io, tmp.dir, "loose");
    repaired.close(io);
    try testing.expectEqual(dir_mode, modeOf((try tmp.dir.statFile(io, "loose", .{})).permissions));

    try tmp.dir.symLink(io, "fresh", "link", .{ .is_directory = true });
    try testing.expectError(error.DurablePathUnsafe, openOrCreatePrivateDir(io, tmp.dir, "link"));
}

test "regular file open refuses symlinks, hard links, and directories" {
    const io = testing.io;
    var tmp = tmpHome();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "plain", .data = "x", .flags = .{ .permissions = file_permissions } });
    try tmp.dir.symLink(io, "plain", "soft", .{});
    try tmp.dir.createDir(io, "sub", .fromMode(0o700));

    const plain = (try openRegularFile(io, tmp.dir, "plain", .read_write)).?;
    plain.close(io);
    try testing.expectEqual(@as(?File, null), try openRegularFile(io, tmp.dir, "absent", .read_only));
    try testing.expectError(error.DurablePathUnsafe, openRegularFile(io, tmp.dir, "soft", .read_only));
    try testing.expectError(error.DurablePathUnsafe, openRegularFile(io, tmp.dir, "sub", .read_only));

    try tmp.dir.hardLink("plain", tmp.dir, "hard", io, .{});
    try testing.expectError(error.DurablePathUnsafe, openRegularFile(io, tmp.dir, "plain", .read_only));
}

test "replace writes a private file, leaves no temp, and refuses unsafe targets" {
    const io = testing.io;
    var tmp = tmpHome();
    defer tmp.cleanup();

    try replace(io, tmp.dir, "target", "one\n", .{});
    try replace(io, tmp.dir, "target", "two\n", .{});
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("two\n", try tmp.dir.readFile(io, "target", &buffer));
    try testing.expectEqual(file_mode, modeOf((try tmp.dir.statFile(io, "target", .{})).permissions));

    var entries: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(io)) |_| entries += 1;
    try testing.expectEqual(@as(usize, 1), entries);

    try tmp.dir.symLink(io, "target", "soft", .{});
    try testing.expectError(error.DurablePathUnsafe, replace(io, tmp.dir, "soft", "x", .{}));
    try tmp.dir.writeFile(io, .{ .sub_path = "frozen", .data = "x", .flags = .{ .permissions = .fromMode(0o400) } });
    try testing.expectError(error.AccessDenied, replace(io, tmp.dir, "frozen", "x", .{}));
    try testing.expectError(error.DurablePathUnsafe, replace(io, tmp.dir, "a/b", "x", .{}));
}

test "replace can stage its temp in another directory" {
    const io = testing.io;
    var tmp = tmpHome();
    defer tmp.cleanup();
    var target = try openOrCreatePrivateDir(io, tmp.dir, "markers");
    defer target.close(io);

    const Seen = struct {
        dir: Dir,
        temp_in_target: bool = false,
        fn hit(ctx: ?*anyopaque, point: Point) void {
            const seen: *@This() = @ptrCast(@alignCast(ctx.?));
            if (point != .replace_temp_synced) return;
            var it = seen.dir.iterate();
            while (it.next(testing.io) catch null) |entry| {
                if (isReplaceTemp(entry.name)) seen.temp_in_target = true;
            }
        }
    };
    var seen: Seen = .{ .dir = target };
    try replace(io, target, "session", "v1 5\n", .{ .temp_dir = tmp.dir, .probe = .{ .ctx = &seen, .hit = Seen.hit } });
    try testing.expect(!seen.temp_in_target);
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("v1 5\n", try target.readFile(io, "session", &buffer));
}

test "replace temp names are recognized" {
    try testing.expect(isReplaceTemp(".abc.tmp.0123456789abcdef0123456789abcdef"));
    try testing.expect(isReplaceTemp(".usage.jsonl.tmp.0123456789abcdef0123456789abcdef"));
    try testing.expect(!isReplaceTemp("abc.tmp.0123456789abcdef0123456789abcdef"));
    try testing.expect(!isReplaceTemp(".abc.tmp.0123456789ABCDEF0123456789abcdef"));
    try testing.expect(!isReplaceTemp(".abc.tmp.0123"));
}

test "lock: exclusive across open file descriptions, busy after the deadline, abandonable" {
    const io = testing.io;
    var tmp = tmpHome();
    defer tmp.cleanup();

    try testing.expectEqual(@as(?Lock, null), try acquireLock(io, tmp.dir, "usage.lock", .{ .deadline_ms = 0, .create = false }));
    var held = (try acquireLock(io, tmp.dir, "usage.lock", .{ .deadline_ms = 0, .create = true })).?;
    try testing.expectEqual(file_mode, modeOf((try tmp.dir.statFile(io, "usage.lock", .{})).permissions));

    try testing.expectError(error.LockBusy, acquireLock(io, tmp.dir, "usage.lock", .{ .deadline_ms = 30, .create = false }));
    var abandoned: std.atomic.Value(bool) = .init(true);
    try testing.expectError(error.LockAbandoned, acquireLock(io, tmp.dir, "usage.lock", .{ .deadline_ms = 30, .create = true, .abandoned = &abandoned }));
    held.release(io);

    var again = (try acquireLock(io, tmp.dir, "usage.lock", .{ .deadline_ms = 0, .create = false })).?;
    again.release(io);
}

test "lock file must be private" {
    const io = testing.io;
    var tmp = tmpHome();
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "usage.lock", .data = "", .flags = .{ .permissions = .fromMode(0o644) } });
    try testing.expectError(error.PrivateStatePermissionsUnsupported, acquireLock(io, tmp.dir, "usage.lock", .{ .deadline_ms = 0, .create = true }));
    try testing.expectError(error.PrivateStatePermissionsUnsupported, lockFileExists(io, tmp.dir, "usage.lock"));
}
