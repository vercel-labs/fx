const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const native_keychain = @import("../hosts/native_keychain.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const max_key_file_bytes: usize = 8 * 1024;

fn usesKeychain() bool {
    if (comptime host_target.is_wasm) return false;
    if (comptime builtin.is_test) return false;
    return selectUsesKeychain(builtin.target.os.tag, native_keychain.isDisabled());
}

fn selectUsesKeychain(os_tag: std.Target.Os.Tag, keychain_disabled: bool) bool {
    return os_tag == .macos and !keychain_disabled;
}

pub const keychain_label = "macOS Keychain";
const profile_label = "profile file";

/// Names the store that `save` writes to, for the success line.
pub fn backendLabel() []const u8 {
    return selectBackendLabel(usesKeychain());
}

fn selectBackendLabel(uses_keychain: bool) []const u8 {
    return if (uses_keychain) keychain_label else profile_label;
}

/// Lets the Keychain prompt for the key in its own process, so fx never holds
/// it. Returns false, without prompting, where `save` writes the profile file;
/// the caller then reads the key itself.
pub fn storeInteractive() host.SecretStoreWriteError!bool {
    if (comptime host_target.is_wasm) return false;
    if (!usesKeychain()) return false;
    native_keychain.storeGeminiApiKeyInteractive() catch |err| return writeFailed("keychain_interactive", err);
    return true;
}

pub fn presence() host.SecretStorePresence {
    if (comptime host_target.is_wasm) return .missing;
    if (usesKeychain()) {
        return native_keychain.geminiApiKeyPresence() catch .unavailable;
    }
    return presenceInProfile();
}

/// Caller owns the returned slice and must zero and free it with `secret.zeroAndFree`.
pub fn load(alloc: Allocator) host.SecretStoreLoadError!?[]u8 {
    if (comptime host_target.is_wasm) return null;
    if (usesKeychain()) {
        return native_keychain.loadGeminiApiKey(alloc) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.KeychainItemNotFound => null,
            else => error.StoredKeyUnreadable,
        };
    }
    return loadFromProfile(alloc);
}

pub fn save(alloc: Allocator, value: []const u8) host.SecretStoreWriteError!void {
    if (comptime host_target.is_wasm) return error.StoredKeyWriteFailed;
    if (value.len == 0 or value.len > max_key_file_bytes) return error.StoredKeyWriteFailed;
    if (usesKeychain()) {
        native_keychain.storeGeminiApiKey(value) catch |err| return writeFailed("keychain", err);
        return;
    }
    return storeInProfile(alloc, value);
}

pub fn delete(alloc: Allocator) host.SecretStoreWriteError!bool {
    if (comptime host_target.is_wasm) return false;
    if (usesKeychain()) {
        return native_keychain.deleteGeminiApiKey(alloc) catch |err| return writeFailed("keychain_delete", err);
    }
    return deleteFromProfile();
}

fn presenceInProfile() host.SecretStorePresence {
    const home = io_mod.homeDir() orelse return .unavailable;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{}) catch
        return .unavailable;
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.rootName(), .{
        .follow_symlinks = false,
    }) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer fx_dir.close(io_mod.getIo());
    var file = fx_dir.openFile(io_mod.getIo(), profile_paths.gemini_api_key_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| return if (err == error.FileNotFound) .missing else .unavailable;
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch return .unavailable;
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) return .unavailable;

    var read_buf: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &read_buf);
    var r = file.reader(io_mod.getIo(), &read_buf);
    var total_bytes: usize = 0;
    var has_non_whitespace = false;
    while (true) {
        var chunk: [256]u8 = undefined;
        defer std.crypto.secureZero(u8, &chunk);
        const n = r.interface.readSliceShort(&chunk) catch return .unavailable;
        if (n == 0) break;
        total_bytes += n;
        if (total_bytes >= max_key_file_bytes) return .unavailable;
        if (!has_non_whitespace and std.mem.trim(u8, chunk[0..n], " \t\r\n").len > 0) {
            has_non_whitespace = true;
        }
    }
    return if (has_non_whitespace) .present else .missing;
}

fn loadFromProfile(alloc: Allocator) host.SecretStoreLoadError!?[]u8 {
    const home = io_mod.homeDir() orelse {
        debug_trace.logf("gemini_api_key", "load failed step=home err=HomeNotSet", .{});
        return error.StoredKeyUnreadable;
    };
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true }) catch |err| {
        debug_trace.logf("gemini_api_key", "load failed step=open_home err={s}", .{@errorName(err)});
        return error.StoredKeyUnreadable;
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.rootName(), .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("gemini_api_key", "load failed step=open_profile err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    defer fx_dir.close(io_mod.getIo());

    return loadFromDir(alloc, &fx_dir);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir) host.SecretStoreLoadError!?[]u8 {
    var file = fx_dir.openFile(io_mod.getIo(), profile_paths.gemini_api_key_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("gemini_api_key", "load failed step=open_file err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch |err| {
        debug_trace.logf("gemini_api_key", "load failed step=stat err={s}", .{@errorName(err)});
        return error.StoredKeyUnreadable;
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("gemini_api_key", "load failed step=permissions err=StoredKeyInsecure", .{});
        return error.StoredKeyInsecure;
    }

    const bytes = io_mod.readFileToEnd(alloc, &file, max_key_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("gemini_api_key", "load failed step=read err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    var borrowed = false;
    defer if (!borrowed) secret.zeroAndFree(alloc, bytes);

    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed.len == bytes.len) {
        borrowed = true;
        return bytes;
    }
    return try alloc.dupe(u8, trimmed);
}

fn storeInProfile(alloc: Allocator, value: []const u8) host.SecretStoreWriteError!void {
    const home = io_mod.homeDir() orelse return writeFailed("home", error.HomeNotSet);
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true }) catch |err| {
            return writeFailed("open_home", err);
        },
    };
    defer home_dir.close();

    var fx_dir = io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.rootName()) catch |err| {
        return writeFailed("open_profile", err);
    };
    defer fx_dir.close();

    return storeInDir(alloc, &fx_dir, value);
}

fn storeInDir(alloc: Allocator, fx_dir: *io_mod.VerifiedDir, value: []const u8) host.SecretStoreWriteError!void {
    io_mod.durableReplaceVerified(alloc, fx_dir, profile_paths.gemini_api_key_file_name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return writeFailed("replace", err),
    };
}

fn deleteFromProfile() host.SecretStoreWriteError!bool {
    const home = io_mod.homeDir() orelse return writeFailed("home", error.HomeNotSet);
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return writeFailed("open_home", err),
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.rootName(), .{
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return writeFailed("open_profile", err),
    };
    defer fx_dir.close(io_mod.getIo());

    fx_dir.deleteFile(io_mod.getIo(), profile_paths.gemini_api_key_file_name) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return writeFailed("delete", err),
    };
    const durable: io_mod.DurableOps = .{};
    durable.sync_dir(durable.ctx, fx_dir) catch |err| {
        debug_trace.logf("gemini_api_key", "delete sync_dir failed err={s}", .{@errorName(err)});
    };
    return true;
}

fn writeFailed(step: []const u8, err: anyerror) host.SecretStoreWriteError {
    debug_trace.logf("gemini_api_key", "store failed step={s} err={s}", .{ step, @errorName(err) });
    return error.StoredKeyWriteFailed;
}

const TestEnv = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, home: []const u8) !*TestEnv {
        const self = try alloc.create(TestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        try self.map.put("FX_DISABLE_KEYCHAIN", "1");
        try self.map.put("HOME", home);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestEnv) void {
        io_mod.resetEnvironForTest();
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

test "gemini key saves, loads, checks presence, and deletes with FX_DISABLE_KEYCHAIN=1" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(home);
    const env = try TestEnv.install(alloc, home);
    defer env.deinit();

    try std.testing.expectEqual(host.SecretStorePresence.missing, presence());
    try std.testing.expect((try load(alloc)) == null);
    try std.testing.expect(!(try delete(alloc)));

    const written = "AIza-gemini-test-key";
    try save(alloc, written);

    try std.testing.expectEqual(host.SecretStorePresence.present, presence());
    const stat = try tmp.dir.statFile(std.testing.io, ".fx/" ++ profile_paths.gemini_api_key_file_name, .{});
    try std.testing.expect(stat.permissions.toMode() & 0o777 == 0o600);

    const read_back = (try load(alloc)) orelse return error.TestUnexpectedMissingGeminiKey;
    defer secret.zeroAndFree(alloc, read_back);
    try std.testing.expectEqualStrings(written, read_back);

    try std.testing.expect(try delete(alloc));
    try std.testing.expectEqual(host.SecretStorePresence.missing, presence());
    try std.testing.expect((try load(alloc)) == null);
    try std.testing.expect(!(try delete(alloc)));
}

test "gemini key file refusal stays distinguishable from absence" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(home);
    const env = try TestEnv.install(alloc, home);
    defer env.deinit();

    try std.testing.expect((try load(alloc)) == null);

    try save(alloc, "AIza-gemini-secret-value");
    for ([_]std.posix.mode_t{ 0o640, 0o604, 0o644 }) |mode| {
        var file = try tmp.dir.openFile(std.testing.io, ".fx/" ++ profile_paths.gemini_api_key_file_name, .{ .mode = .read_write });
        try file.setPermissions(std.testing.io, std.Io.File.Permissions.fromMode(mode));
        file.close(std.testing.io);

        try std.testing.expectEqual(host.SecretStorePresence.unavailable, presence());
        try std.testing.expectError(error.StoredKeyInsecure, load(alloc));
    }

    try std.testing.expect(try delete(alloc));
    try std.testing.expect((try load(alloc)) == null);
}

test "gemini key file tolerates a trailing newline and rejects an empty value" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(home);
    const env = try TestEnv.install(alloc, home);
    defer env.deinit();

    try save(alloc, "hand-edited-gemini-key\n");
    const read_back = (try load(alloc)) orelse return error.TestUnexpectedMissingGeminiKey;
    defer secret.zeroAndFree(alloc, read_back);
    try std.testing.expectEqualStrings("hand-edited-gemini-key", read_back);

    try save(alloc, "\n\n");
    try std.testing.expect((try load(alloc)) == null);

    try std.testing.expectError(error.StoredKeyWriteFailed, save(alloc, ""));
}

test "gemini key backend selection uses keychain on macos only when enabled" {
    try std.testing.expect(selectUsesKeychain(.macos, false));
    try std.testing.expect(!selectUsesKeychain(.macos, true));
    try std.testing.expect(!selectUsesKeychain(.linux, false));
    try std.testing.expect(!selectUsesKeychain(.linux, true));
}

test "gemini key backend label names the store that keeps the key" {
    try std.testing.expectEqualStrings("macOS Keychain", selectBackendLabel(true));
    try std.testing.expectEqualStrings("profile file", selectBackendLabel(false));
}

test "gemini key interactive store prompts only where save uses the Keychain" {
    // Test builds never use the Keychain, so this returns before any prompt.
    try std.testing.expect(!(try storeInteractive()));
}

test "gemini key presence treats whitespace-only and newline-only files as missing" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
    defer alloc.free(home);
    const env = try TestEnv.install(alloc, home);
    defer env.deinit();

    for ([_][]const u8{ "\n\n", "  \t \r\n " }) |blank| {
        try save(alloc, blank);
        try std.testing.expectEqual(host.SecretStorePresence.missing, presence());
        try std.testing.expect((try load(alloc)) == null);
    }
}
