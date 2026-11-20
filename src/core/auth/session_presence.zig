const std = @import("std");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const debug_trace = @import("../shared/debug_trace.zig");

pub fn profileFile(
    file_name: []const u8,
    max_bytes: usize,
) host.SecretStorePresence {
    if (comptime host_target.is_wasm) return .missing;
    return profileFileFromHome(io_mod.homeDir(), file_name, max_bytes);
}

/// Returns whether the credential file exists after checking both write targets.
pub fn requireWritableProfileFile(file_name: []const u8, lock_name: []const u8) error{CredentialStorageUnavailable}!bool {
    if (comptime host_target.is_wasm) return false;
    const home = io_mod.homeDir() orelse return error.CredentialStorageUnavailable;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true }) catch return error.CredentialStorageUnavailable;
    defer home_dir.close(io_mod.getIo());
    var profile_dir = home_dir.openDir(io_mod.getIo(), profile_paths.rootName(), .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        if (err != error.FileNotFound) return error.CredentialStorageUnavailable;
        const stat = home_dir.stat(io_mod.getIo()) catch return error.CredentialStorageUnavailable;
        if (stat.permissions.toMode() & 0o200 == 0) return error.CredentialStorageUnavailable;
        return false;
    };
    defer profile_dir.close(io_mod.getIo());
    const exists = try requireWritableInDir(profile_dir, file_name);
    _ = try requireWritableInDir(profile_dir, lock_name);
    return exists;
}

/// Storage-origin errors must not be interpreted as OAuth AccessDenied.
pub fn storageError(file_name: []const u8, err: anyerror) error{ OutOfMemory, Cancelled, LockBusy, CredentialStorageUnavailable } {
    debug_trace.logf("auth", "credential storage operation failed file={s} err={s}", .{ file_name, @errorName(err) });
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.LockBusy => error.LockBusy,
        else => error.CredentialStorageUnavailable,
    };
}

/// Borrows the verified store directory; checks metadata without changing it.
pub fn requireWritableInDir(dir: std.Io.Dir, file_name: []const u8) error{CredentialStorageUnavailable}!bool {
    const dir_stat = dir.stat(io_mod.getIo()) catch return error.CredentialStorageUnavailable;
    if (dir_stat.permissions.toMode() & 0o200 == 0) return error.CredentialStorageUnavailable;
    const stat = dir.statFile(io_mod.getIo(), file_name, .{ .follow_symlinks = false }) catch |err| {
        if (err == error.FileNotFound) return false;
        return error.CredentialStorageUnavailable;
    };
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o777 != 0o600) {
        return error.CredentialStorageUnavailable;
    }
    return true;
}

/// A login file as it is at its name now, with its metadata.
pub const CurrentFile = struct {
    file: std.Io.File,
    stat: std.Io.File.Stat,
};

const max_opens = 3;

/// Opens login file `name` in `dir` for reading, without following a link or
/// waiting for a writer when it's a fifo. Null when there's none. Another fx
/// that saves the login replaces the file, and one that signs out deletes it,
/// so a file opened just before has no links left; the name then holds the
/// new file, or none, and is opened again. The caller closes the file.
pub fn openCurrent(dir: std.Io.Dir, name: []const u8) !?CurrentFile {
    return openCurrentWith(dir, name, null);
}

/// `openCurrent`, with `between` run after each open and before its check,
/// as another fx's save or logout can.
fn openCurrentWith(dir: std.Io.Dir, name: []const u8, between: ?*const fn (std.Io.Dir, []const u8) void) !?CurrentFile {
    for (0..max_opens) |_| {
        var file = io_mod.openExistingReadOnlyRegularFile(dir, name, .no_follow) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (between) |run| run(dir, name);
        const stat = file.stat(io_mod.getIo()) catch |err| {
            file.close(io_mod.getIo());
            return err;
        };
        if (stat.nlink != 0) return .{ .file = file, .stat = stat };
        file.close(io_mod.getIo());
        debug_trace.logf("auth", "login file replaced or deleted after it was opened name={s}; opening it again", .{name});
    }
    return error.LoginFileKeptChanging;
}

fn profileFileFromHome(
    home_value: ?[]const u8,
    file_name: []const u8,
    max_bytes: usize,
) host.SecretStorePresence {
    const home = home_value orelse return .unavailable;
    var home_dir = std.Io.Dir.openDirAbsolute(
        io_mod.getIo(),
        profile_paths.rootParent(home),
        .{ .iterate = true },
    ) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer home_dir.close(io_mod.getIo());

    var profile_dir = home_dir.openDir(
        io_mod.getIo(),
        profile_paths.rootName(),
        .{ .iterate = true, .follow_symlinks = false },
    ) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer profile_dir.close(io_mod.getIo());

    var current = (openCurrent(profile_dir, file_name) catch return .unavailable) orelse return .missing;
    defer current.file.close(io_mod.getIo());

    const stat = current.stat;
    if (stat.kind != .file or
        stat.nlink != 1 or
        stat.permissions.toMode() & 0o077 != 0 or
        stat.size == 0 or
        stat.size > max_bytes)
    {
        return .unavailable;
    }
    return .present;
}

test "a login file another fx replaces after this one opened it is opened again" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "auth.json", .data = "old", .flags = .{ .permissions = .fromMode(0o600) } });
    // Another fx saves a new login over it, by rename, once.
    const Save = struct {
        var done = false;
        var failed: ?anyerror = null;
        fn run(dir: std.Io.Dir, name: []const u8) void {
            if (done) return;
            done = true;
            dir.writeFile(std.testing.io, .{ .sub_path = "auth.json.new", .data = "new", .flags = .{ .permissions = .fromMode(0o600) } }) catch |err| {
                failed = err;
                return;
            };
            dir.rename("auth.json.new", dir, name, std.testing.io) catch |err| {
                failed = err;
            };
        }
    };

    var current = (try openCurrentWith(tmp.dir, "auth.json", Save.run)).?;
    defer current.file.close(std.testing.io);
    try std.testing.expectEqual(@as(?anyerror, null), Save.failed);
    try std.testing.expect(Save.done);
    const bytes = try io_mod.readFileToEnd(std.testing.allocator, &current.file, 64);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("new", bytes);
}

test "a login file another fx deletes after this one opened it is none" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "auth.json", .data = "old", .flags = .{ .permissions = .fromMode(0o600) } });
    // Another fx signs out.
    const Logout = struct {
        var failed: ?anyerror = null;
        fn run(dir: std.Io.Dir, name: []const u8) void {
            dir.deleteFile(std.testing.io, name) catch |err| {
                failed = err;
            };
        }
    };

    try std.testing.expectEqual(@as(?CurrentFile, null), try openCurrentWith(tmp.dir, "auth.json", Logout.run));
    try std.testing.expectEqual(@as(?anyerror, null), Logout.failed);
}

test "a login file another fx replaces after every open is given up after the last open" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "auth.json", .data = "old", .flags = .{ .permissions = .fromMode(0o600) } });
    // Another fx saves a new login over it after each open.
    const Saves = struct {
        var count: usize = 0;
        var failed: ?anyerror = null;
        fn run(dir: std.Io.Dir, name: []const u8) void {
            count += 1;
            dir.writeFile(std.testing.io, .{ .sub_path = "auth.json.new", .data = "new", .flags = .{ .permissions = .fromMode(0o600) } }) catch |err| {
                failed = err;
                return;
            };
            dir.rename("auth.json.new", dir, name, std.testing.io) catch |err| {
                failed = err;
            };
        }
    };

    try std.testing.expectError(error.LoginFileKeptChanging, openCurrentWith(tmp.dir, "auth.json", Saves.run));
    try std.testing.expectEqual(@as(?anyerror, null), Saves.failed);
    try std.testing.expectEqual(@as(usize, max_opens), Saves.count);
}

test "missing native profile root is unavailable" {
    try std.testing.expectEqual(
        host.SecretStorePresence.unavailable,
        profileFileFromHome(null, "auth.json", 1024),
    );
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "a private sign-in file is present, and a fifo in its place is unavailable without blocking" {
    if (comptime @import("builtin").target.os.tag == .windows or @import("builtin").target.os.tag == .wasi) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".fx");
    {
        var file = try tmp.dir.createFile(std.testing.io, ".fx/auth.json", .{
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "{}");
    }
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);
    try std.testing.expectEqual(host.SecretStorePresence.present, profileFileFromHome(home, "auth.json", 1024));

    // Opening a fifo for reading waits for a writer that never comes.
    try tmp.dir.deleteFile(std.testing.io, ".fx/auth.json");
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fifo = try std.mem.printSentinel(&path_buf, "{s}/.fx/auth.json", .{home}, 0);
    if (mkfifo(fifo, 0o600) != 0) return error.SkipZigTest;
    try std.testing.expectEqual(host.SecretStorePresence.unavailable, profileFileFromHome(home, "auth.json", 1024));
}

test "credential write admission accepts missing files and rejects read-only targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect(!try requireWritableInDir(tmp.dir, "auth.json"));
    var file = try tmp.dir.createFile(std.testing.io, "auth.json", .{
        .read = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer file.close(std.testing.io);
    try std.testing.expect(try requireWritableInDir(tmp.dir, "auth.json"));
    defer file.setPermissions(std.testing.io, std.Io.File.Permissions.fromMode(0o600)) catch {};
    for ([_]std.posix.mode_t{ 0o400, 0o200, 0o700 }) |mode| {
        try file.setPermissions(std.testing.io, std.Io.File.Permissions.fromMode(mode));
        try std.testing.expectError(error.CredentialStorageUnavailable, requireWritableInDir(tmp.dir, "auth.json"));
    }
}
