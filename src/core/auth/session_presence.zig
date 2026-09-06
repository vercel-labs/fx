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
    return profileFileFromHome(io_mod.getenv("HOME"), file_name, max_bytes);
}

/// Returns whether the credential file exists after checking both write targets.
pub fn requireWritableProfileFile(file_name: []const u8, lock_name: []const u8) error{CredentialStorageUnavailable}!bool {
    if (comptime host_target.is_wasm) return false;
    const home = io_mod.getenv("HOME") orelse return error.CredentialStorageUnavailable;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch return error.CredentialStorageUnavailable;
    defer home_dir.close(io_mod.getIo());
    var profile_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
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

fn profileFileFromHome(
    home_value: ?[]const u8,
    file_name: []const u8,
    max_bytes: usize,
) host.SecretStorePresence {
    const home = home_value orelse return .unavailable;
    var home_dir = std.Io.Dir.openDirAbsolute(
        io_mod.getIo(),
        home,
        .{ .iterate = true },
    ) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer home_dir.close(io_mod.getIo());

    var profile_dir = home_dir.openDir(
        io_mod.getIo(),
        profile_paths.root_dir_name,
        .{ .iterate = true, .follow_symlinks = false },
    ) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer profile_dir.close(io_mod.getIo());

    var file = profile_dir.openFile(io_mod.getIo(), file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch return .unavailable;
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

test "missing native profile root is unavailable" {
    try std.testing.expectEqual(
        host.SecretStorePresence.unavailable,
        profileFileFromHome(null, "auth.json", 1024),
    );
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
