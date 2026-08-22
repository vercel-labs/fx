const std = @import("std");
const builtin = @import("builtin");
const darwin_process_spawn = @import("darwin_process_spawn.zig");

pub const RawEnviron = [*:null]const ?[*:0]const u8;

// Process globals are installed before threads start and remain read-only.
var real_io: ?std.Io = null;

// Fallback used by non-test code only when setIo was not called. The real
// application installs `real_io` from main before spawning threads.
var fallback_threaded: std.Io.Threaded = .init_single_threaded;

var global_environ: ?*const std.process.Environ.Map = null;
var global_environ_block: ?std.process.Environ.Block = null;
var global_raw_environ: ?RawEnviron = null;

pub fn setIo(zio: std.Io) void {
    real_io = process_io_for(builtin.os.tag, zio);
}

fn process_io_for(comptime os_tag: std.Target.Os.Tag, zio: std.Io) std.Io {
    return if (os_tag == .macos) darwin_process_spawn.wrap(zio) else zio;
}

pub fn getIo() std.Io {
    if (real_io) |zio| return zio;
    if (comptime builtin.is_test) return process_io_for(builtin.os.tag, std.testing.io);
    return process_io_for(builtin.os.tag, fallback_threaded.io());
}

/// Opens an absolute directory path without following any path component.
/// The caller owns the returned directory handle.
pub fn openDirAbsoluteNoFollow(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    var components = std.fs.path.componentIterator(path);
    const root = components.root() orelse return error.InvalidPath;
    var component = components.next() orelse {
        var root_options = options;
        root_options.follow_symlinks = false;
        return std.Io.Dir.openDirAbsolute(getIo(), root, root_options);
    };

    var dir = try std.Io.Dir.openDirAbsolute(getIo(), root, .{ .follow_symlinks = false });
    errdefer dir.close(getIo());
    while (components.next()) |next_component| {
        if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
            return error.InvalidPath;
        }
        const next_dir = try dir.openDir(getIo(), component.name, .{ .follow_symlinks = false });
        dir.close(getIo());
        dir = next_dir;
        component = next_component;
    }
    if (std.mem.eql(u8, component.name, ".") or std.mem.eql(u8, component.name, "..")) {
        return error.InvalidPath;
    }
    var final_options = options;
    final_options.follow_symlinks = false;
    const result = try dir.openDir(getIo(), component.name, final_options);
    dir.close(getIo());
    return result;
}

test "Darwin process I/O replaces only processSpawn with stable storage" {
    const original = std.testing.io;
    const selected = process_io_for(.macos, original);
    const selected_again = process_io_for(.macos, original);

    try std.testing.expect(selected.userdata == original.userdata);
    try std.testing.expect(selected.vtable == selected_again.vtable);
    inline for (@typeInfo(std.Io.VTable).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "processSpawn")) {
            try std.testing.expect(@field(selected.vtable, field.name) != @field(original.vtable, field.name));
        } else {
            try std.testing.expectEqual(@field(original.vtable, field.name), @field(selected.vtable, field.name));
        }
    }
}

test "getIo applies Darwin process selection to the test fallback" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const previous = real_io;
    real_io = null;
    defer real_io = previous;

    const selected = getIo();
    try std.testing.expect(selected.userdata == std.testing.io.userdata);
    try std.testing.expect(selected.vtable.processSpawn != std.testing.io.vtable.processSpawn);
}

test "getIo Darwin test fallback runs a child through the selected backend" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const previous = real_io;
    real_io = null;
    defer real_io = previous;

    const alloc = std.testing.allocator;
    const io = getIo();
    const result = try std.process.run(alloc, io, .{
        .argv = &.{ "/usr/bin/printf", "get-io-spawn-ok" },
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTermination,
    }
    try std.testing.expectEqualStrings("get-io-spawn-ok", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "non-Darwin process I/O keeps the original vtable" {
    const original = std.testing.io;
    const selected = process_io_for(.linux, original);

    try std.testing.expect(selected.userdata == original.userdata);
    try std.testing.expect(selected.vtable == original.vtable);
}

test "openDirAbsoluteNoFollow rejects unsafe path components" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(getIo(), "real/child");
    try writeTempFile(tmp.dir, "plain-file", "not a directory");
    tmp.dir.symLink(std.testing.io, "real", "linked", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied or err == error.FileSystem) return error.SkipZigTest;
        return err;
    };

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const linked_child = try std.fs.path.join(alloc, &.{ root, "linked/child" });
    defer alloc.free(linked_child);
    const missing = try std.fs.path.join(alloc, &.{ root, "missing" });
    defer alloc.free(missing);
    const wrong_kind = try std.fs.path.join(alloc, &.{ root, "plain-file" });
    defer alloc.free(wrong_kind);

    if (openDirAbsoluteNoFollow(linked_child, .{})) |dir| {
        dir.close(getIo());
        return error.TestExpectedError;
    } else |err| switch (err) {
        error.NotDir, error.SymLinkLoop => {},
        else => return err,
    }
    try std.testing.expectError(error.FileNotFound, openDirAbsoluteNoFollow(missing, .{}));
    try std.testing.expectError(error.NotDir, openDirAbsoluteNoFollow(wrong_kind, .{}));
}

/// Opens an existing regular file without following the final symlink and
/// without waiting on a special file that races the initial metadata check.
/// The caller owns the returned file.
pub fn openExistingRegularFile(
    dir: std.Io.Dir,
    sub_path: []const u8,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !std.Io.File {
    return openExistingRegularFileWithPolicy(dir, sub_path, .{
        .mode = mode,
        .final_symlink = .no_follow,
        .hardlinks = .reject,
    });
}

/// Opens an existing read-only regular file according to `final_symlink`.
/// Hardlinks are accepted. Following a link does not authorize its target;
/// the caller owns that policy and the returned file.
pub fn openExistingReadOnlyRegularFile(
    dir: std.Io.Dir,
    sub_path: []const u8,
    final_symlink: FinalSymlinkPolicy,
) !std.Io.File {
    return openExistingRegularFileWithPolicy(dir, sub_path, .{
        .mode = .read_only,
        .final_symlink = final_symlink,
        .hardlinks = .allow,
    });
}

pub const FinalSymlinkPolicy = enum {
    no_follow,
    follow,
};

const HardlinkPolicy = enum {
    reject,
    allow,
};

const RegularFileOpenPolicy = struct {
    mode: std.Io.Dir.OpenFileOptions.Mode,
    final_symlink: FinalSymlinkPolicy,
    hardlinks: HardlinkPolicy,
};

fn openExistingRegularFileWithPolicy(
    dir: std.Io.Dir,
    sub_path: []const u8,
    policy: RegularFileOpenPolicy,
) !std.Io.File {
    const initial = try dir.statFile(getIo(), sub_path, .{
        .follow_symlinks = policy.final_symlink == .follow,
    });
    if (initial.kind != .file or (policy.hardlinks == .reject and initial.nlink != 1)) {
        return error.DurablePathUnsafe;
    }

    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        var file = try dir.openFile(getIo(), sub_path, .{
            .mode = policy.mode,
            .allow_directory = false,
            .follow_symlinks = policy.final_symlink == .follow,
        });
        errdefer file.close(getIo());
        const stat = try file.stat(getIo());
        try verifyOpenedRegularFileWithPolicy(stat, policy);
        return file;
    }

    var flags: std.posix.O = .{
        .ACCMODE = switch (policy.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
        .NOFOLLOW = policy.final_symlink == .no_follow,
        .NONBLOCK = true,
    };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;

    const fd = std.posix.openat(dir.handle, sub_path, flags, 0) catch |err| switch (err) {
        error.NoDevice, error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    var file = std.Io.File{
        .handle = fd,
        .flags = .{ .nonblocking = true },
    };
    errdefer file.close(getIo());
    const stat = try file.stat(getIo());
    try verifyOpenedRegularFileWithPolicy(stat, policy);
    try makeFileBlocking(&file);
    return file;
}

pub fn verifyOpenedRegularFile(
    stat: std.Io.File.Stat,
    mode: std.Io.Dir.OpenFileOptions.Mode,
) !void {
    return verifyOpenedRegularFileWithPolicy(stat, .{
        .mode = mode,
        .final_symlink = .no_follow,
        .hardlinks = .reject,
    });
}

fn verifyOpenedRegularFileWithPolicy(stat: std.Io.File.Stat, policy: RegularFileOpenPolicy) !void {
    if (stat.kind != .file) {
        return error.DurablePathUnsafe;
    }
    if (policy.hardlinks == .reject and stat.nlink > 1) {
        return error.DurablePathUnsafe;
    }
    if (policy.hardlinks == .reject and policy.mode != .read_only and stat.nlink != 1) {
        return error.DurablePathUnsafe;
    }
}

fn makeFileBlocking(file: *std.Io.File) !void {
    const current = while (true) {
        const rc = std.posix.system.fcntl(
            file.handle,
            std.posix.F.GETFL,
            @as(usize, 0),
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break @as(usize, @intCast(rc)),
            .INTR => continue,
            else => return error.FileControlFailed,
        }
    };
    const nonblock = @as(usize, 1) << @bitOffsetOf(std.posix.O, "NONBLOCK");
    while (true) {
        const rc = std.posix.system.fcntl(
            file.handle,
            std.posix.F.SETFL,
            current & ~nonblock,
        );
        switch (std.posix.errno(rc)) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.FileControlFailed,
        }
    }
    file.flags.nonblocking = false;
}

test "read-only regular files remain valid when atomic replacement unlinks the descriptor" {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "target", .data = "old" });

    var file = try openExistingRegularFile(tmp.dir, "target", .read_only);
    defer file.close(getIo());
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "replacement", .data = "new" });
    try tmp.dir.rename("replacement", tmp.dir, "target", getIo());

    const stat = try file.stat(getIo());
    try std.testing.expectEqual(@as(u64, 0), stat.nlink);
    try verifyOpenedRegularFile(stat, .read_only);
    try std.testing.expectError(
        error.DurablePathUnsafe,
        verifyOpenedRegularFile(stat, .read_write),
    );
    const bytes = try readFileToEnd(alloc, &file, 16);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("old", bytes);
}

test "read-only regular file policy accepts hardlinks while durable policy rejects" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "target", .data = "metadata" });
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.linkat(tmp.dir.handle, "target", tmp.dir.handle, "alias", 0),
    );

    try std.testing.expectError(
        error.DurablePathUnsafe,
        openExistingRegularFile(tmp.dir, "target", .read_only),
    );
    var file = try openExistingReadOnlyRegularFile(tmp.dir, "target", .no_follow);
    defer file.close(getIo());
    const bytes = try readFileToEnd(alloc, &file, 64);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("metadata", bytes);
}

test "opened file path evidence rejects a deleted handle" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(getIo(), .{ .sub_path = "target", .data = "metadata" });

    var file = try openExistingReadOnlyRegularFile(tmp.dir, "target", .no_follow);
    defer file.close(getIo());
    try tmp.dir.deleteFile(getIo(), "target");
    try std.testing.expectError(error.HandlePathUnavailable, openedFilePathAlloc(alloc, file));
}

pub fn setEnvironMap(m: *const std.process.Environ.Map) void {
    global_environ = m;
    global_environ_block = null;
    global_raw_environ = null;
}

pub fn setEnvironBlock(block: std.process.Environ.Block) void {
    global_environ = null;
    global_environ_block = block;
    global_raw_environ = null;
}

pub fn setRawEnviron(raw: RawEnviron) void {
    global_environ = null;
    global_environ_block = null;
    global_raw_environ = raw;
}

pub fn getenv(key: []const u8) ?[]const u8 {
    if (global_environ) |m| return m.get(key);
    if (global_environ_block) |block| return getenvFromBlock(block, key);
    if (global_raw_environ) |raw| return getenvFromLibc(key) orelse getenvFromRaw(raw, key);
    return null;
}

pub fn e2eFailIfDurableMutationAttempted() void {
    const enabled = getenv("FX_E2E_FAIL_ON_DURABLE_MUTATION") orelse return;
    if (!std.mem.eql(u8, enabled, "1")) return;
    std.process.exit(86);
}

pub fn environMap() ?*const std.process.Environ.Map {
    return global_environ;
}

/// Copies every visible environment variable into `map`, regardless of
/// whether the environment was installed as a map, a block, or raw environ.
pub fn copyEnviron(map: *std.process.Environ.Map) !void {
    if (global_environ) |m| {
        var it = m.iterator();
        while (it.next()) |entry| try map.put(entry.key_ptr.*, entry.value_ptr.*);
        return;
    }
    if (global_environ_block) |block| {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .freestanding or builtin.os.tag == .other) {
            return;
        }
        if (comptime (builtin.os.tag == .wasi or builtin.os.tag == .emscripten) and !builtin.link_libc) {
            return;
        }
        const view = block.view();
        for (view.slice) |entry_z| {
            const entry = std.mem.sliceTo(entry_z, 0);
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (eq == 0) continue;
            try map.put(entry[0..eq], entry[eq + 1 ..]);
        }
        return;
    }
    if (global_raw_environ) |raw| {
        @setRuntimeSafety(false);
        var i: usize = 0;
        while (raw[i]) |entry_z| : (i += 1) {
            const entry = std.mem.sliceTo(entry_z, 0);
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (eq == 0) continue;
            try map.put(entry[0..eq], entry[eq + 1 ..]);
        }
    }
}

fn getenvFromBlock(block: std.process.Environ.Block, key: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .freestanding or builtin.os.tag == .other) {
        return null;
    }
    if (comptime (builtin.os.tag == .wasi or builtin.os.tag == .emscripten) and !builtin.link_libc) {
        return null;
    }

    const view = block.view();
    for (view.slice) |entry_z| {
        const entry = std.mem.sliceTo(entry_z, 0);
        if (entry.len <= key.len or entry[key.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..key.len], key)) return entry[key.len + 1 ..];
    }
    return null;
}

fn getenvFromRaw(raw: RawEnviron, key: []const u8) ?[]const u8 {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (raw[i]) |entry_z| : (i += 1) {
        const entry = std.mem.sliceTo(entry_z, 0);
        if (entry.len <= key.len or entry[key.len] != '=') continue;
        if (std.mem.eql(u8, entry[0..key.len], key)) return entry[key.len + 1 ..];
    }
    return null;
}

fn getenvFromLibc(key: []const u8) ?[]const u8 {
    if (comptime !builtin.link_libc) return null;
    if (key.len >= 128) return null;

    var key_buf: [128]u8 = undefined;
    @memcpy(key_buf[0..key.len], key);
    key_buf[key.len] = 0;
    const value_z = std.c.getenv(key_buf[0..key.len :0].ptr) orelse return null;
    return std.mem.sliceTo(value_z, 0);
}

pub fn readFileToEnd(alloc: std.mem.Allocator, file: *std.Io.File, max_bytes: usize) ![]u8 {
    const zio = getIo();
    var read_buf: [8192]u8 = undefined;
    var r = file.reader(zio, &read_buf);
    return r.interface.allocRemaining(alloc, std.Io.Limit.limited(max_bytes));
}

pub fn readFileToEndZ(alloc: std.mem.Allocator, file: *std.Io.File, max_bytes: usize) ![:0]u8 {
    const data = try readFileToEnd(alloc, file, max_bytes);
    errdefer alloc.free(data);
    const result = try alloc.realloc(data, data.len + 1);
    result[data.len] = 0;
    return result[0..data.len :0];
}

pub fn milliTimestamp() i64 {
    const ts = std.Io.Timestamp.now(getIo(), .real);
    return @intCast(@divFloor(ts.nanoseconds, 1_000_000));
}

pub fn nanoTimestamp() i128 {
    const ts = std.Io.Timestamp.now(getIo(), .real);
    return @intCast(ts.nanoseconds);
}

pub fn writeFileAtomic(alloc: std.mem.Allocator, path: []const u8, text: []const u8) !void {
    e2eFailIfDurableMutationAttempted();
    const maybe_existing_permissions = existingFilePermissions(path);
    if (maybe_existing_permissions) |existing_permissions| {
        if (existing_permissions.toMode() & 0o222 == 0) return error.AccessDenied;
    }
    const permissions = maybe_existing_permissions orelse .default_file;
    const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp.{d}", .{ path, nanoTimestamp() });
    defer alloc.free(temp_path);

    var cleanup_temp = true;
    defer if (cleanup_temp) std.Io.Dir.deleteFileAbsolute(getIo(), temp_path) catch {};

    {
        var file = try std.Io.Dir.createFileAbsolute(getIo(), temp_path, .{ .truncate = true, .permissions = permissions });
        defer file.close(getIo());
        try file.writeStreamingAll(getIo(), text);
        try file.sync(getIo());
    }

    try std.Io.Dir.renameAbsolute(temp_path, path, getIo());
    cleanup_temp = false;
}

const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

pub const VerifiedDir = struct {
    dir: std.Io.Dir,

    pub fn close(self: *VerifiedDir) void {
        self.dir.close(getIo());
        self.* = undefined;
    }
};

fn defaultSyncFile(_: ?*anyopaque, file: std.Io.File) anyerror!void {
    try file.sync(getIo());
}

fn defaultSyncDir(_: ?*anyopaque, dir: std.Io.Dir) anyerror!void {
    try syncVerifiedDir(dir);
}

pub const DurableOps = struct {
    ctx: ?*anyopaque = null,
    sync_file: *const fn (?*anyopaque, std.Io.File) anyerror!void = defaultSyncFile,
    sync_dir: *const fn (?*anyopaque, std.Io.Dir) anyerror!void = defaultSyncDir,
};

fn defaultTryLock(_: ?*anyopaque, file: std.Io.File) anyerror!bool {
    return file.tryLock(getIo(), .exclusive);
}

fn defaultLockNow(_: ?*anyopaque) i64 {
    return milliTimestamp();
}

fn defaultLockSleep(_: ?*anyopaque, millis: u64) void {
    sleep(millis * std.time.ns_per_ms);
}

pub const LockOps = struct {
    ctx: ?*anyopaque = null,
    try_lock: *const fn (?*anyopaque, std.Io.File) anyerror!bool = defaultTryLock,
    now_ms: *const fn (?*anyopaque) i64 = defaultLockNow,
    sleep_ms: *const fn (?*anyopaque, u64) void = defaultLockSleep,
};

pub const TimedAdvisoryLock = struct {
    file: std.Io.File,

    pub fn release(self: *TimedAdvisoryLock) void {
        self.file.unlock(getIo());
        self.file.close(getIo());
        self.* = undefined;
    }
};

fn validateRelativeLeaf(name: []const u8) !void {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        return error.DurablePathUnsafe;
    }
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return error.DurablePathUnsafe;
}

fn verifyPrivateRegularFile(file: std.Io.File) !void {
    const stat = try file.stat(getIo());
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    if (stat.permissions.toMode() & 0o777 != 0o600) return error.PrivateStatePermissionsUnsupported;
}

fn verifyPrivateDirectory(dir: std.Io.Dir) !void {
    const stat = try dir.stat(getIo());
    if (stat.kind != .directory) return error.DurablePathUnsafe;
    if (stat.permissions.toMode() & 0o777 != 0o700) return error.PrivateStatePermissionsUnsupported;
}

/// The handle must come from an `openDir` that requested iteration. Linux returns an
/// `O_PATH` descriptor otherwise, and `fsync` rejects those with `EBADF`.
pub fn syncVerifiedDir(dir: std.Io.Dir) !void {
    if (comptime builtin.os.tag == .windows) return error.OperationUnsupported;
    while (true) {
        const rc = std.c.fsync(dir.handle);
        if (rc == 0) return;
        switch (std.c.errno(rc)) {
            .INTR => continue,
            .INVAL, .OPNOTSUPP => return error.OperationUnsupported,
            .NOSPC => return error.NoSpaceLeft,
            .DQUOT => return error.DiskQuota,
            .ROFS => return error.ReadOnlyFileSystem,
            else => return error.DirectorySyncFailed,
        }
    }
}

fn openOrCreateVerifiedPrivateChild(parent: std.Io.Dir, name: []const u8) !VerifiedDir {
    e2eFailIfDurableMutationAttempted();
    try validateRelativeLeaf(name);
    const zio = getIo();

    var created = false;
    var dir = parent.openDir(zio, name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            parent.createDir(zio, name, private_dir_permissions) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return create_err,
            };
            created = true;
            break :blk try parent.openDir(zio, name, .{
                .iterate = true,
                .follow_symlinks = false,
            });
        },
        error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer dir.close(zio);

    dir.setPermissions(zio, private_dir_permissions) catch return error.PrivateStatePermissionsUnsupported;
    try verifyPrivateDirectory(dir);
    if (created) try syncVerifiedDir(parent);
    return .{ .dir = dir };
}

pub fn openOrCreateVerifiedPrivateDir(parent: *VerifiedDir, name: []const u8) !VerifiedDir {
    return openOrCreateVerifiedPrivateChild(parent.dir, name);
}

pub fn openOrCreateVerifiedPrivateDirFromDir(parent: std.Io.Dir, name: []const u8) !VerifiedDir {
    return openOrCreateVerifiedPrivateChild(parent, name);
}

fn validateReplaceTarget(dir: std.Io.Dir, name: []const u8) !void {
    const stat = dir.statFile(getIo(), name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.SymLinkLoop, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    if (stat.kind != .file or stat.nlink != 1) return error.DurablePathUnsafe;
    if (stat.permissions.toMode() & 0o222 == 0) return error.AccessDenied;
}

fn cleanupVerifiedTemp(dir: std.Io.Dir, name: []const u8) void {
    const stat = dir.statFile(getIo(), name, .{ .follow_symlinks = false }) catch return;
    if (stat.kind != .file or stat.nlink != 1) return;
    dir.deleteFile(getIo(), name) catch {};
}

pub fn durableReplaceVerified(
    alloc: std.mem.Allocator,
    dir: *VerifiedDir,
    name: []const u8,
    bytes: []const u8,
) !void {
    return durableReplaceVerifiedWithOps(alloc, dir, name, bytes, .{});
}

pub fn durableReplaceVerifiedWithOps(
    alloc: std.mem.Allocator,
    dir: *VerifiedDir,
    name: []const u8,
    bytes: []const u8,
    ops: DurableOps,
) !void {
    e2eFailIfDurableMutationAttempted();
    try validateRelativeLeaf(name);
    validateReplaceTarget(dir.dir, name) catch |err| switch (err) {
        error.DurablePathUnsafe, error.AccessDenied => return err,
        else => return error.DurableReplacePreRenameFailed,
    };

    var random_bytes: [16]u8 = undefined;
    getIo().random(&random_bytes);
    const suffix = std.fmt.bytesToHex(random_bytes, .lower);
    const temp_name = try std.fmt.allocPrint(alloc, ".{s}.tmp.{s}", .{ name, suffix });
    defer alloc.free(temp_name);

    var temp_exists = false;
    defer if (temp_exists) cleanupVerifiedTemp(dir.dir, temp_name);

    var file = dir.dir.createFile(getIo(), temp_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = private_file_permissions,
        .resolve_beneath = true,
    }) catch return error.DurableReplacePreRenameFailed;
    temp_exists = true;
    defer file.close(getIo());

    file.setPermissions(getIo(), private_file_permissions) catch return error.PrivateStatePermissionsUnsupported;
    verifyPrivateRegularFile(file) catch |err| switch (err) {
        error.DurablePathUnsafe, error.PrivateStatePermissionsUnsupported => return err,
        else => return error.DurableReplacePreRenameFailed,
    };
    file.writeStreamingAll(getIo(), bytes) catch return error.DurableReplacePreRenameFailed;
    ops.sync_file(ops.ctx, file) catch return error.DurableReplacePreRenameFailed;
    dir.dir.rename(temp_name, dir.dir, name, getIo()) catch return error.DurableReplacePreRenameFailed;
    temp_exists = false;

    const final_stat = dir.dir.statFile(getIo(), name, .{ .follow_symlinks = false }) catch {
        return error.DurableReplacePostRenameFailed;
    };
    if (final_stat.kind != .file or final_stat.nlink != 1 or
        final_stat.permissions.toMode() & 0o777 != 0o600)
    {
        return error.DurableReplacePostRenameFailed;
    }
    ops.sync_dir(ops.ctx, dir.dir) catch return error.DurableReplacePostRenameFailed;
}

fn openOrCreatePrivateLockFile(dir: *VerifiedDir, name: []const u8) !std.Io.File {
    try validateRelativeLeaf(name);
    const zio = getIo();

    var file = dir.dir.openFile(zio, name, .{
        .mode = .read_write,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const created = dir.dir.createFile(zio, name, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .permissions = private_file_permissions,
                .resolve_beneath = true,
            }) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => break :blk try dir.dir.openFile(zio, name, .{
                    .mode = .read_write,
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                }),
                else => return create_err,
            };
            created.setPermissions(zio, private_file_permissions) catch {
                created.close(zio);
                return error.PrivateStatePermissionsUnsupported;
            };
            syncVerifiedDir(dir.dir) catch {
                created.close(zio);
                return error.DirectorySyncFailed;
            };
            break :blk created;
        },
        error.SymLinkLoop, error.IsDir, error.NotDir => return error.DurablePathUnsafe,
        else => return err,
    };
    errdefer file.close(zio);
    try verifyPrivateRegularFile(file);
    return file;
}

pub fn acquireTimedAdvisoryLock(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(dir, name, deadline_ms, null, .{});
}

pub fn acquireTimedAdvisoryLockWithOps(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    ops: LockOps,
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(dir, name, deadline_ms, null, ops);
}

pub fn acquireTimedAdvisoryLockCancellable(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    cancel_flag: *const std.atomic.Value(bool),
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(
        dir,
        name,
        deadline_ms,
        cancel_flag,
        .{},
    );
}

pub fn acquireTimedAdvisoryLockCancellableWithOps(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    cancel_flag: *const std.atomic.Value(bool),
    ops: LockOps,
) !TimedAdvisoryLock {
    return acquireTimedAdvisoryLockControlled(
        dir,
        name,
        deadline_ms,
        cancel_flag,
        ops,
    );
}

fn acquireTimedAdvisoryLockControlled(
    dir: *VerifiedDir,
    name: []const u8,
    deadline_ms: u64,
    cancel_flag: ?*const std.atomic.Value(bool),
    ops: LockOps,
) !TimedAdvisoryLock {
    const file = try openOrCreatePrivateLockFile(dir, name);
    errdefer file.close(getIo());

    const started = ops.now_ms(ops.ctx);
    const deadline: i64 = started + @as(i64, @intCast(deadline_ms));
    while (true) {
        if (cancel_flag) |flag| {
            if (flag.load(.acquire)) return error.Cancelled;
        }
        const locked = ops.try_lock(ops.ctx, file) catch |err| switch (err) {
            error.FileLocksUnsupported => return error.LockUnsupported,
            else => return err,
        };
        if (locked) return .{ .file = file };
        if (ops.now_ms(ops.ctx) >= deadline) return error.LockBusy;
        ops.sleep_ms(ops.ctx, @min(@as(u64, 10), deadline_ms));
    }
}

pub fn copyFileAtomic(alloc: std.mem.Allocator, source_path: []const u8, dest_path: []const u8) !void {
    const zio = getIo();
    var source = try std.Io.Dir.openFileAbsolute(zio, source_path, .{});
    defer source.close(zio);

    const stat = try source.stat(zio);
    if (stat.kind != .file) return error.NotRegularFile;
    if (existingFilePermissions(dest_path)) |existing_permissions| {
        if (existing_permissions.toMode() & 0o222 == 0) return error.AccessDenied;
    }

    const temp_path = try std.fmt.allocPrint(alloc, "{s}.tmp.{d}", .{ dest_path, nanoTimestamp() });
    defer alloc.free(temp_path);

    var cleanup_temp = true;
    defer if (cleanup_temp) std.Io.Dir.deleteFileAbsolute(zio, temp_path) catch {};

    {
        var dest = try std.Io.Dir.createFileAbsolute(zio, temp_path, .{ .truncate = true, .permissions = stat.permissions });
        defer dest.close(zio);

        var read_buf: [8192]u8 = undefined;
        var reader = source.readerStreaming(zio, &read_buf);
        var transfer_buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try reader.interface.readSliceShort(&transfer_buf);
            if (n == 0) break;
            try dest.writeStreamingAll(zio, transfer_buf[0..n]);
        }
        try dest.sync(zio);
    }

    try std.Io.Dir.renameAbsolute(temp_path, dest_path, zio);
    cleanup_temp = false;
}

fn existingFilePermissions(path: []const u8) ?std.Io.File.Permissions {
    const stat = std.Io.Dir.cwd().statFile(getIo(), path, .{}) catch return null;
    if (stat.kind != .file) return null;
    return stat.permissions;
}

pub fn sleep(ns: u64) void {
    getIo().sleep(.{ .nanoseconds = @intCast(ns) }, .real) catch {};
}

pub fn makeDirRecursive(path: []const u8) !void {
    const zio = getIo();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.createDirAbsolute(zio, path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                if (std.fs.path.dirname(path)) |parent| try makeDirRecursive(parent);
                try std.Io.Dir.createDirAbsolute(zio, path, .default_dir);
            },
        };
    } else {
        std.Io.Dir.cwd().createDirPath(zio, path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

pub fn realpathAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&buf, "{s}", .{path});
    var result_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ptr = std.c.realpath(path_z, &result_buf) orelse return error.FileNotFound;
    const resolved = std.mem.sliceTo(ptr, 0);
    return alloc.dupe(u8, resolved);
}

fn handlePathAlloc(alloc: std.mem.Allocator, handle: std.Io.File.Handle) ![]u8 {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
        // F_GETPATH (macOS fcntl command 50): resolve filesystem path for an fd.
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const rc = std.c.fcntl(handle, @as(c_int, 50), @intFromPtr(&path_buf));
        if (rc == -1) return error.HandlePathUnavailable;
        return alloc.dupe(u8, std.mem.sliceTo(&path_buf, 0));
    } else if (comptime builtin.os.tag == .linux) {
        var fd_path_buf: [64:0]u8 = undefined;
        _ = std.fmt.bufPrintZ(&fd_path_buf, "/proc/self/fd/{d}", .{handle}) catch return error.HandlePathUnavailable;
        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        const rc = std.c.readlink(&fd_path_buf, &link_buf, link_buf.len);
        if (rc < 0) return error.HandlePathUnavailable;
        return alloc.dupe(u8, link_buf[0..@intCast(rc)]);
    } else {
        return error.HandlePathUnavailable;
    }
}

/// Returns absolute path evidence reported by an already-open regular file
/// handle. The caller owns the returned path. Deleted or otherwise
/// unresolvable handles fail closed.
pub fn openedFilePathAlloc(alloc: std.mem.Allocator, file: std.Io.File) ![]u8 {
    const stat = try file.stat(getIo());
    if (stat.kind != .file or stat.nlink == 0) return error.HandlePathUnavailable;
    const path = try handlePathAlloc(alloc, file.handle);
    errdefer alloc.free(path);
    if (!std.fs.path.isAbsolute(path)) return error.HandlePathUnavailable;
    if (comptime builtin.os.tag == .linux) {
        if (std.mem.endsWith(u8, path, " (deleted)")) return error.HandlePathUnavailable;
    }
    return path;
}

pub fn dirRealpathAlloc(alloc: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    if (comptime builtin.os.tag == .macos or builtin.os.tag == .ios) {
        const dir_path = handlePathAlloc(alloc, dir.handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileNotFound,
        };
        if (sub_path.len == 0) return dir_path;
        defer alloc.free(dir_path);
        const joined = try std.fs.path.join(alloc, &.{ dir_path, sub_path });
        defer alloc.free(joined);
        return realpathAlloc(alloc, joined);
    } else if (comptime builtin.os.tag == .linux) {
        const dir_path = handlePathAlloc(alloc, dir.handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.FileNotFound,
        };
        if (sub_path.len == 0) return dir_path;
        defer alloc.free(dir_path);
        const joined = try std.fs.path.join(alloc, &.{ dir_path, sub_path });
        defer alloc.free(joined);
        return realpathAlloc(alloc, joined);
    } else if (comptime builtin.os.tag == .wasi) {
        if (std.fs.path.isAbsolute(sub_path)) return alloc.dupe(u8, sub_path);
        return std.fs.path.resolve(alloc, &.{sub_path});
    } else {
        @compileError("dirRealpathAlloc not implemented for this OS");
    }
}

fn writeTempFile(dir: std.Io.Dir, name: []const u8, content: []const u8) !void {
    var file = try dir.createFile(getIo(), name, .{ .truncate = true });
    defer file.close(getIo());
    try file.writeStreamingAll(getIo(), content);
}

fn readTempFile(alloc: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, max_bytes: usize) ![]u8 {
    var file = try dir.openFile(getIo(), name, .{});
    defer file.close(getIo());
    return readFileToEnd(alloc, &file, max_bytes);
}

test "getenv returns null before setEnvironMap" {
    const previous = global_environ;
    global_environ = null;
    defer global_environ = previous;

    try std.testing.expect(getenv("FX_IO_TEST") == null);
}

test "getenv returns set value after setEnvironMap" {
    const previous = global_environ;
    global_environ = null;
    defer global_environ = previous;

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("FX_IO_TEST", "present");

    setEnvironMap(&environ);
    try std.testing.expectEqualStrings("present", getenv("FX_IO_TEST").?);
    global_environ = null;
}

test "environMap returns borrowed process environment map" {
    const previous = global_environ;
    global_environ = null;
    defer global_environ = previous;

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("FX_CORE2_IO_TEST", "present");

    setEnvironMap(&environ);
    const borrowed = environMap().?;
    try std.testing.expectEqualStrings("present", borrowed.get("FX_CORE2_IO_TEST").?);
    global_environ = null;
}

test "readFileToEnd: file under cap returns full content" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "under.txt", "0123456789");

    const data = try readTempFile(alloc, tmp.dir, "under.txt", 100);
    defer alloc.free(data);
    try std.testing.expectEqual(@as(usize, 10), data.len);
    try std.testing.expectEqualStrings("0123456789", data);
}

test "readFileToEnd: file at exact cap returns error.StreamTooLong" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "exact.txt", "0123456789");

    if (readTempFile(alloc, tmp.dir, "exact.txt", 10)) |data| {
        defer alloc.free(data);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.StreamTooLong, err);
    }
}

test "readFileToEnd: file over cap returns error.StreamTooLong" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "over.txt", "0123456789");

    if (readTempFile(alloc, tmp.dir, "over.txt", 9)) |data| {
        defer alloc.free(data);
        try std.testing.expect(false);
    } else |err| {
        try std.testing.expectEqual(error.StreamTooLong, err);
    }
}

test "readFileToEndZ returns null-terminated slice" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "sentinel.txt", "hello");

    var file = try tmp.dir.openFile(getIo(), "sentinel.txt", .{});
    defer file.close(getIo());
    const data = try readFileToEndZ(alloc, &file, 100);
    defer alloc.free(data);
    try std.testing.expectEqual(@as(usize, 5), data.len);
    try std.testing.expectEqualStrings("hello", data);
    try std.testing.expectEqual(@as(u8, 0), data.ptr[data.len]);
}

test "timestamp wrappers return plausible real-clock values" {
    try std.testing.expect(milliTimestamp() > 0);
    try std.testing.expect(nanoTimestamp() > 0);
}

test "writeFileAtomic replaces file content and leaves no temp file behind" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.fs.path.join(alloc, &.{ root, "state.json" });
    defer alloc.free(file_path);

    try writeFileAtomic(alloc, file_path, "first");
    try writeFileAtomic(alloc, file_path, "second");

    var file = try std.Io.Dir.openFileAbsolute(getIo(), file_path, .{});
    defer file.close(getIo());
    const content = try readFileToEnd(alloc, &file, 128);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("second", content);

    var check_dir = try std.Io.Dir.openDirAbsolute(getIo(), root, .{ .iterate = true });
    defer check_dir.close(getIo());
    var iter = check_dir.iterate();
    var count: usize = 0;
    while (try iter.next(getIo())) |entry| {
        try std.testing.expect(std.mem.find(u8, entry.name, ".tmp.") == null);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "writeFileAtomic preserves existing file permissions" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const file_path = try std.fs.path.join(alloc, &.{ root, "script.sh" });
    defer alloc.free(file_path);

    try writeFileAtomic(alloc, file_path, "first");
    try std.Io.Dir.cwd().setFilePermissions(getIo(), file_path, std.Io.File.Permissions.fromMode(0o755), .{});
    try writeFileAtomic(alloc, file_path, "second");

    const stat = try std.Io.Dir.cwd().statFile(getIo(), file_path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o777);
}

test "copyFileAtomic copies through temp file and cleans up" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const source_path = try std.fs.path.join(alloc, &.{ root, "source.txt" });
    defer alloc.free(source_path);
    const dest_path = try std.fs.path.join(alloc, &.{ root, "dest.txt" });
    defer alloc.free(dest_path);

    try writeFileAtomic(alloc, source_path, "source");
    try copyFileAtomic(alloc, source_path, dest_path);

    var file = try std.Io.Dir.openFileAbsolute(getIo(), dest_path, .{});
    defer file.close(getIo());
    const content = try readFileToEnd(alloc, &file, 128);
    defer alloc.free(content);
    try std.testing.expectEqualStrings("source", content);

    var check_dir = try std.Io.Dir.openDirAbsolute(getIo(), root, .{ .iterate = true });
    defer check_dir.close(getIo());
    var iter = check_dir.iterate();
    while (try iter.next(getIo())) |entry| {
        try std.testing.expect(std.mem.find(u8, entry.name, ".tmp.") == null);
    }
}

test "copyFileAtomic failed replacement leaves existing destination intact" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const source_path = try std.fs.path.join(alloc, &.{ root, "source.txt" });
    defer alloc.free(source_path);
    const dest_dir = try std.fs.path.join(alloc, &.{ root, "dest" });
    defer alloc.free(dest_dir);

    try writeFileAtomic(alloc, source_path, "source");
    try std.Io.Dir.cwd().createDirPath(getIo(), dest_dir);
    if (copyFileAtomic(alloc, source_path, dest_dir)) {
        return error.TestExpectedError;
    } else |_| {}

    var check_dir = try std.Io.Dir.openDirAbsolute(getIo(), root, .{ .iterate = true });
    defer check_dir.close(getIo());
    var iter = check_dir.iterate();
    while (try iter.next(getIo())) |entry| {
        try std.testing.expect(std.mem.find(u8, entry.name, ".tmp.") == null);
    }
}

test "dirRealpathAlloc resolves tmp file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTempFile(tmp.dir, "resolved.txt", "content");

    const resolved = try dirRealpathAlloc(alloc, tmp.dir, "resolved.txt");
    defer alloc.free(resolved);
    try std.testing.expect(std.fs.path.isAbsolute(resolved));
    try std.testing.expect(std.mem.endsWith(u8, resolved, std.fs.path.sep_str ++ "resolved.txt"));
}

test "realpathAlloc on nonexistent path returns FileNotFound" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const missing = try std.fs.path.join(alloc, &.{ root, "missing-realpath-target" });
    defer alloc.free(missing);

    try std.testing.expectError(error.FileNotFound, realpathAlloc(alloc, missing));
}

const DurableFailureState = struct {
    fail_temp_sync: bool = false,
    fail_parent_sync: bool = false,
    lock_attempts: usize = 0,
    now_ms: i64 = 0,
};

fn testDurableSyncFile(ctx: ?*anyopaque, file: std.Io.File) anyerror!void {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    if (state.fail_temp_sync) return error.InjectedSyncFailure;
    try file.sync(getIo());
}

fn testDurableSyncDir(ctx: ?*anyopaque, dir: std.Io.Dir) anyerror!void {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    if (state.fail_parent_sync) return error.InjectedSyncFailure;
    try syncVerifiedDir(dir);
}

fn testLockAlwaysBusy(ctx: ?*anyopaque, _: std.Io.File) anyerror!bool {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    state.lock_attempts += 1;
    return false;
}

fn testLockUnsupported(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
    return error.FileLocksUnsupported;
}

fn testLockNow(ctx: ?*anyopaque) i64 {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    return state.now_ms;
}

fn testLockSleep(ctx: ?*anyopaque, millis: u64) void {
    const state: *DurableFailureState = @ptrCast(@alignCast(ctx.?));
    state.now_ms += @intCast(millis);
}

test "durable replace reports pre-rename failure without changing target" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try durableReplaceVerified(alloc, &dir, "settings.json", "old");

    var state = DurableFailureState{ .fail_temp_sync = true };
    const ops = DurableOps{ .ctx = &state, .sync_file = testDurableSyncFile };
    try std.testing.expectError(
        error.DurableReplacePreRenameFailed,
        durableReplaceVerifiedWithOps(alloc, &dir, "settings.json", "new", ops),
    );

    var file = try dir.dir.openFile(getIo(), "settings.json", .{ .follow_symlinks = false });
    defer file.close(getIo());
    const bytes = try readFileToEnd(alloc, &file, 16);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("old", bytes);
}

test "durable replace reports post-rename sync failure as indeterminate" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try durableReplaceVerified(alloc, &dir, "settings.json", "old");

    var state = DurableFailureState{ .fail_parent_sync = true };
    const ops = DurableOps{ .ctx = &state, .sync_dir = testDurableSyncDir };
    try std.testing.expectError(
        error.DurableReplacePostRenameFailed,
        durableReplaceVerifiedWithOps(alloc, &dir, "settings.json", "new", ops),
    );

    var file = try dir.dir.openFile(getIo(), "settings.json", .{ .follow_symlinks = false });
    defer file.close(getIo());
    const bytes = try readFileToEnd(alloc, &file, 16);
    defer alloc.free(bytes);
    try std.testing.expectEqualStrings("new", bytes);
}

test "private durable file mode is exactly 0600" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    try durableReplaceVerified(alloc, &dir, "settings.json", "{}\n");

    const stat = try dir.dir.statFile(getIo(), "settings.json", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "private durable directory mode is exactly 0700" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var parent = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer parent.close();
    var child = try openOrCreateVerifiedPrivateDir(&parent, "state");
    defer child.close();

    const stat = try child.dir.stat(getIo());
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
}

test "caller-owned directory can create a verified private child" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var parent = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false });
    defer parent.close(getIo());
    var child = try openOrCreateVerifiedPrivateDirFromDir(parent, "state");
    defer child.close();

    const stat = try child.dir.stat(getIo());
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
}

test "caller-owned directory rejects unsafe private children" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(getIo(), .{ .sub_path = "file", .data = "not a directory" });
    try std.testing.expectError(
        error.DurablePathUnsafe,
        openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "file"),
    );

    try tmp.dir.createDir(getIo(), "target", .default_dir);
    tmp.dir.symLink(getIo(), "target", "link", .{ .is_directory = true }) catch |err| {
        if (err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    try std.testing.expectError(
        error.DurablePathUnsafe,
        openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "link"),
    );
}

test "timed advisory lock returns busy after deadline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    var state = DurableFailureState{};
    const ops = LockOps{
        .ctx = &state,
        .try_lock = testLockAlwaysBusy,
        .now_ms = testLockNow,
        .sleep_ms = testLockSleep,
    };

    try std.testing.expectError(
        error.LockBusy,
        acquireTimedAdvisoryLockWithOps(&dir, "settings.lock", 25, ops),
    );
    try std.testing.expect(state.lock_attempts > 1);
}

test "cancellable timed advisory lock stops between busy attempts" {
    const CancelState = struct {
        cancel: *std.atomic.Value(bool),
        now_ms: i64 = 0,

        fn tryLock(_: ?*anyopaque, _: std.Io.File) anyerror!bool {
            return false;
        }

        fn now(raw: ?*anyopaque) i64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            return self.now_ms;
        }

        fn sleep(raw: ?*anyopaque, millis: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.now_ms += @intCast(millis);
            self.cancel.store(true, .release);
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(
        getIo(),
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer dir.close();
    var cancel = std.atomic.Value(bool).init(false);
    var state = CancelState{ .cancel = &cancel };

    try std.testing.expectError(
        error.Cancelled,
        acquireTimedAdvisoryLockCancellableWithOps(
            &dir,
            "credentials.lock",
            2_000,
            &cancel,
            .{
                .ctx = &state,
                .try_lock = CancelState.tryLock,
                .now_ms = CancelState.now,
                .sleep_ms = CancelState.sleep,
            },
        ),
    );
    try std.testing.expectEqual(@as(i64, 10), state.now_ms);
}

test "timed advisory lock reports unsupported without unlocked fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir = VerifiedDir{ .dir = try tmp.dir.openDir(getIo(), ".", .{ .iterate = true, .follow_symlinks = false }) };
    defer dir.close();
    const ops = LockOps{ .try_lock = testLockUnsupported };

    try std.testing.expectError(
        error.LockUnsupported,
        acquireTimedAdvisoryLockWithOps(&dir, "settings.lock", 25, ops),
    );
}
