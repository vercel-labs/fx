//! Stands in for src/core/hosts/native_keychain.zig in the lab that driver.ts
//! builds from a copy of src/. The fx login's Keychain item is a file named by
//! FX_TLA_KEYCHAIN_FILE, which every lab process of a run shares, so the real
//! src/core/auth/oauth_session.zig takes its Keychain branch with no Keychain
//! at all. It declares only what the lab reaches: a lab that reached more
//! would fail to build, never call a Keychain.
//!
//! Faults: FX_TLA_KEYCHAIN_FAIL_STORE=1 fails every write, as a Keychain that
//! refuses one does.
const std = @import("std");
const host = @import("host.zig");
const io_mod = @import("../shared/io.zig");

pub const oauth_session_service_name = "FX_OAUTH_SESSION_V1";
/// The real bound on one Keychain call, which the fx login's leased lock uses.
pub const keychain_call_ms: i64 = 10_000;

pub const Error = error{
    Cancelled,
    UnsupportedPlatform,
    UserNotSet,
    KeychainItemNotFound,
    KeychainReadFailed,
    KeychainWriteFailed,
    KeychainDeleteFailed,
};

/// There is no Keychain here to turn off. The lab sets FX_DISABLE_KEYCHAIN=1
/// like every fx process a driver starts, so this reads FX_TLA_PROFILE_FILE
/// instead: set to 1, oauth_session.zig keeps the login in the profile file.
pub fn isDisabled() bool {
    const value = io_mod.getenv("FX_TLA_PROFILE_FILE") orelse return false;
    return std.mem.eql(u8, value, "1");
}

pub fn isAvailable() bool {
    return true;
}

fn itemPath() Error![]const u8 {
    return io_mod.getenv("FX_TLA_KEYCHAIN_FILE") orelse error.KeychainReadFailed;
}

pub fn oauthSessionPresence() Error!host.SecretStorePresence {
    const path = try itemPath();
    std.Io.Dir.cwd().access(io_mod.getIo(), path, .{}) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        else => error.KeychainReadFailed,
    };
    return .present;
}

/// The saved login, or `error.KeychainItemNotFound`, as the real call.
pub fn loadOAuthSession(alloc: std.mem.Allocator) !?[]u8 {
    const path = try itemPath();
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch |err| return switch (err) {
        error.FileNotFound => error.KeychainItemNotFound,
        else => error.KeychainReadFailed,
    };
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 64 * 1024) catch error.KeychainReadFailed;
}

/// Replaces the saved login whole: written beside it, then renamed over it,
/// so another process reads the old login or the new one, as from the Keychain.
pub fn storeOAuthSession(value: []const u8) Error!void {
    const path = try itemPath();
    if (io_mod.getenv("FX_TLA_KEYCHAIN_FAIL_STORE")) |fail| {
        if (std.mem.eql(u8, fail, "1")) return error.KeychainWriteFailed;
    }
    const io = io_mod.getIo();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = std.mem.print(&buf, "{s}.{d}.tmp", .{ path, std.c.getpid() }) catch return error.KeychainWriteFailed;
    var file = std.Io.Dir.cwd().createFile(io, tmp, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    }) catch return error.KeychainWriteFailed;
    file.writeStreamingAll(io, value) catch {
        file.close(io);
        return error.KeychainWriteFailed;
    };
    file.close(io);
    std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, io) catch return error.KeychainWriteFailed;
}

pub fn deleteOAuthSession(_: std.mem.Allocator) Error!bool {
    const path = try itemPath();
    std.Io.Dir.cwd().deleteFile(io_mod.getIo(), path) catch |err| return switch (err) {
        error.FileNotFound => false,
        else => error.KeychainDeleteFailed,
    };
    return true;
}
