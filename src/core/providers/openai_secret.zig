const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");
const keychain = @import("../hosts/native_keychain.zig");

const Allocator = std.mem.Allocator;
const max_key_file_bytes: usize = 8 * 1024;

pub const service_name = "FX_OPENAI_API_KEY";

pub fn load(alloc: Allocator) !?[]u8 {
    if (comptime builtin.os.tag == .macos) {
        if (keychain.loadNamed(alloc, service_name)) |loaded| {
            return loaded;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.KeychainItemNotFound => {},
            else => debug_trace.logf("openai_secret", "keychain load failed err={s}", .{@errorName(err)}),
        }
    }
    return loadFromProfile(alloc);
}

pub fn store(alloc: Allocator, value: []const u8) !void {
    if (value.len == 0) return error.StoredKeyWriteFailed;
    if (comptime builtin.os.tag == .macos) {
        keychain.storeNamed(service_name, value) catch |err| {
            debug_trace.logf("openai_secret", "keychain store failed err={s}", .{@errorName(err)});
            return error.StoredKeyWriteFailed;
        };
        return;
    }
    return storeInProfile(alloc, value);
}

fn loadFromProfile(alloc: Allocator) !?[]u8 {
    const home = io_mod.getenv("HOME") orelse return error.StoredKeyUnreadable;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("openai_secret", "load failed step=open_home err={s}", .{@errorName(err)});
        return error.StoredKeyUnreadable;
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("openai_secret", "load failed step=open_profile err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    defer fx_dir.close(io_mod.getIo());

    var providers_dir = fx_dir.openDir(io_mod.getIo(), profile_paths.providers_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("openai_secret", "load failed step=open_providers err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    defer providers_dir.close(io_mod.getIo());

    var backend_dir = providers_dir.openDir(io_mod.getIo(), profile_paths.openai_compatible_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("openai_secret", "load failed step=open_backend err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    defer backend_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &backend_dir);
}

fn loadFromDir(alloc: Allocator, backend_dir: *std.Io.Dir) !?[]u8 {
    var file = backend_dir.openFile(io_mod.getIo(), profile_paths.api_key_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("openai_secret", "load failed step=open_file err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch |err| {
        debug_trace.logf("openai_secret", "load failed step=stat err={s}", .{@errorName(err)});
        return error.StoredKeyUnreadable;
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        return error.StoredKeyInsecure;
    }

    const bytes = io_mod.readFileToEnd(alloc, &file, max_key_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("openai_secret", "load failed step=read err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    var borrowed = false;
    defer if (!borrowed) secret.zeroAndFree(alloc, bytes);

    const trimmed = std.mem.trim(u8, bytes, "\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.len == bytes.len) {
        borrowed = true;
        return bytes;
    }
    return try alloc.dupe(u8, trimmed);
}

fn storeInProfile(alloc: Allocator, value: []const u8) !void {
    const home = io_mod.getenv("HOME") orelse return error.StoredKeyWriteFailed;
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch {
            return error.StoredKeyWriteFailed;
        },
    };
    defer home_dir.close();

    var fx_dir = io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name) catch {
        return error.StoredKeyWriteFailed;
    };
    defer fx_dir.close();

    var providers_dir = io_mod.openOrCreateVerifiedPrivateDir(&fx_dir, profile_paths.providers_dir_name) catch {
        return error.StoredKeyWriteFailed;
    };
    defer providers_dir.close();

    var backend_dir = io_mod.openOrCreateVerifiedPrivateDir(&providers_dir, profile_paths.openai_compatible_dir_name) catch {
        return error.StoredKeyWriteFailed;
    };
    defer backend_dir.close();
    return storeInDir(alloc, &backend_dir, value);
}

fn storeInDir(alloc: Allocator, backend_dir: *io_mod.VerifiedDir, value: []const u8) !void {
    io_mod.durableReplaceVerified(alloc, backend_dir, profile_paths.api_key_file_name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.StoredKeyWriteFailed,
    };
}

test "openai secret file round-trips at mode 0600" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer backend_dir.close();

    try storeInDir(std.testing.allocator, &backend_dir, "sk-test-openai");
    const stat = try tmp.dir.statFile(std.testing.io, profile_paths.api_key_file_name, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);

    const loaded = (try loadFromDir(std.testing.allocator, &backend_dir.dir)) orelse
        return error.TestUnexpectedMissingStoredKey;
    defer secret.zeroAndFree(std.testing.allocator, loaded);
    try std.testing.expectEqualStrings("sk-test-openai", loaded);
}

test "openai secret file refusal stays distinguishable from absence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer backend_dir.close();

    try std.testing.expect((try loadFromDir(std.testing.allocator, &backend_dir.dir)) == null);
    try storeInDir(std.testing.allocator, &backend_dir, "sk-secret");
    var file = try tmp.dir.openFile(std.testing.io, profile_paths.api_key_file_name, .{ .mode = .read_write });
    try file.setPermissions(std.testing.io, std.Io.File.Permissions.fromMode(0o644));
    file.close(std.testing.io);
    try std.testing.expectError(error.StoredKeyInsecure, loadFromDir(std.testing.allocator, &backend_dir.dir));
}
