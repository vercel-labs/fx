const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("host.zig");
const io_mod = @import("../shared/io.zig");
const keychain = @import("native_keychain.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;

/// Names the backend that answers on this platform so operators can tell where a
/// stored key lives without knowing how the backend is selected.
const backend_label = if (build_options.native_auth_e2e)
    "profile file"
else if (builtin.os.tag == .macos)
    "macOS Keychain"
else
    "profile file";

const max_key_file_bytes: usize = 8 * 1024;

const LoadError = host.SecretStoreLoadError;
const StoreError = host.SecretStoreWriteError;

pub const provider: host.SecretStore = .{
    .backend_label = backend_label,
    .is_disabled_fn = isDisabledCallback,
    .load_fn = loadCallback,
    .store_fn = storeCallback,
    .store_interactive_fn = storeInteractiveCallback,
    .store_with_disposition_fn = storeWithDispositionCallback,
};

/// The disable switch is named for the macOS backend, so its reader stays there.
fn isDisabled() bool {
    if (comptime build_options.native_auth_e2e) return false;
    return keychain.isDisabled();
}

/// Returns the stored key, or null when no key is stored. An error means the store
/// could not be read, which callers must keep distinct from absence.
fn load(alloc: Allocator) LoadError!?[]u8 {
    if (comptime build_options.native_auth_e2e) return loadFromProfile(alloc);
    if (comptime builtin.os.tag == .macos) return loadFromKeychain(alloc);
    return loadFromProfile(alloc);
}

fn store(alloc: Allocator, value: []const u8) StoreError!void {
    if (value.len == 0) return error.StoredKeyWriteFailed;
    if (comptime build_options.native_auth_e2e) return storeInProfile(alloc, value);
    if (comptime builtin.os.tag == .macos) {
        keychain.storeValue(value) catch |err| return writeFailed("keychain", err);
        return;
    }
    return storeInProfile(alloc, value);
}

/// Let the platform credential store own terminal input when it supports a
/// secure prompt, keeping plaintext out of the fx process.
fn storeInteractive() StoreError!bool {
    if (comptime build_options.native_auth_e2e) return false;
    if (comptime builtin.os.tag == .macos) {
        keychain.storeInteractive() catch |err| return writeFailed("keychain_interactive", err);
        return true;
    }
    return false;
}

fn isDisabledCallback(_: ?*anyopaque) bool {
    return isDisabled();
}

fn loadCallback(_: ?*anyopaque, alloc: Allocator) LoadError!?[]u8 {
    return load(alloc);
}

fn storeCallback(
    _: ?*anyopaque,
    alloc: Allocator,
    value: []const u8,
) StoreError!void {
    return store(alloc, value);
}

fn storeInteractiveCallback(_: ?*anyopaque) StoreError!bool {
    return storeInteractive();
}

fn storeWithDispositionCallback(
    _: ?*anyopaque,
    alloc: Allocator,
    value: []const u8,
) host.SecretStoreWriteReport {
    if (value.len == 0) {
        return .{ .durable_write = .unchanged, .failure = error.StoredKeyWriteFailed };
    }
    if (comptime build_options.native_auth_e2e) {
        return nativeAuthE2eStoreWithDisposition(alloc, value);
    }
    if (comptime builtin.os.tag == .macos) {
        return keychainStoreWriteReport(keychain.storeValueWithDisposition(value));
    }
    return storeInProfileWithDisposition(alloc, value);
}

const NativeAuthE2eMode = enum {
    replaced,
    unchanged,
    indeterminate,
    cancel_before,
    cancel_after,
};

fn nativeAuthE2eControlPath(alloc: Allocator, name: []const u8) ![]u8 {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(alloc, &.{ home, profile_paths.root_dir_name, name });
}

fn nativeAuthE2eMode(alloc: Allocator) NativeAuthE2eMode {
    const path = nativeAuthE2eControlPath(alloc, "native-auth-store-mode") catch return .replaced;
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch return .replaced;
    defer file.close(io_mod.getIo());
    const value = io_mod.readFileToEnd(alloc, &file, 64) catch return .replaced;
    defer alloc.free(value);
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.meta.stringToEnum(NativeAuthE2eMode, trimmed) orelse .unchanged;
}

fn nativeAuthE2eWriteFact(alloc: Allocator, name: []const u8, value: []const u8) void {
    const path = nativeAuthE2eControlPath(alloc, name) catch return;
    defer alloc.free(path);
    var file = std.Io.Dir.createFileAbsolute(io_mod.getIo(), path, .{ .truncate = true }) catch return;
    defer file.close(io_mod.getIo());
    file.writeStreamingAll(io_mod.getIo(), value) catch {};
}

fn nativeAuthE2eWriteMarker(alloc: Allocator, name: []const u8) void {
    nativeAuthE2eWriteFact(alloc, name, "1");
}

fn nativeAuthE2eWaitForRelease(alloc: Allocator) bool {
    const path = nativeAuthE2eControlPath(alloc, "native-auth-store-release") catch return false;
    defer alloc.free(path);
    for (0..400) |_| {
        var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch {
            std.Io.Timeout.sleep(.{
                .duration = .{ .raw = .{ .nanoseconds = 25 * std.time.ns_per_ms }, .clock = .awake },
            }, io_mod.getIo()) catch return false;
            continue;
        };
        file.close(io_mod.getIo());
        return true;
    }
    return false;
}

fn nativeAuthE2eStoreWithDisposition(
    alloc: Allocator,
    value: []const u8,
) host.SecretStoreWriteReport {
    const mode = nativeAuthE2eMode(alloc);
    nativeAuthE2eWriteFact(alloc, "native-auth-store-observed", @tagName(mode));
    return switch (mode) {
        .replaced => storeInProfileWithDisposition(alloc, value),
        .unchanged => .{
            .durable_write = .unchanged,
            .failure = error.StoredKeyWriteFailed,
        },
        .indeterminate => indeterminate: {
            storeInProfile(alloc, value) catch |err| {
                nativeAuthE2eWriteFact(alloc, "native-auth-store-error", @errorName(err));
                break :indeterminate .{
                    .durable_write = .unchanged,
                    .failure = error.StoredKeyWriteFailed,
                };
            };
            break :indeterminate .{
                .durable_write = .indeterminate,
                .failure = error.StoredKeyWriteFailed,
            };
        },
        .cancel_before => cancel_before: {
            nativeAuthE2eWriteMarker(alloc, "native-auth-store-entered");
            if (!nativeAuthE2eWaitForRelease(alloc)) break :cancel_before .{
                .durable_write = .unchanged,
                .failure = error.StoredKeyWriteFailed,
            };
            break :cancel_before .{
                .durable_write = .unchanged,
                .failure = error.StoredKeyWriteFailed,
            };
        },
        .cancel_after => cancel_after: {
            storeInProfile(alloc, value) catch break :cancel_after .{
                .durable_write = .unchanged,
                .failure = error.StoredKeyWriteFailed,
            };
            nativeAuthE2eWriteMarker(alloc, "native-auth-store-published");
            _ = nativeAuthE2eWaitForRelease(alloc);
            break :cancel_after .{ .durable_write = .replaced };
        },
    };
}

fn keychainStoreWriteReport(report: keychain.StoreReport) host.SecretStoreWriteReport {
    return .{
        .durable_write = switch (report.disposition) {
            .unchanged => .unchanged,
            .replaced => .replaced,
            .indeterminate => .indeterminate,
        },
        .failure = if (report.failure != null) error.StoredKeyWriteFailed else null,
    };
}

fn loadFromKeychain(alloc: Allocator) LoadError!?[]u8 {
    return keychain.load(alloc) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.KeychainItemNotFound => null,
        else => error.StoredKeyUnreadable,
    };
}

fn loadFromProfile(alloc: Allocator) LoadError!?[]u8 {
    const home = io_mod.getenv("HOME") orelse {
        debug_trace.logf("stored_key", "load failed step=home err=HomeNotSet", .{});
        return error.StoredKeyUnreadable;
    };
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("stored_key", "load failed step=open_home err={s}", .{@errorName(err)});
        return error.StoredKeyUnreadable;
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("stored_key", "load failed step=open_profile err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    defer fx_dir.close(io_mod.getIo());

    return loadFromDir(alloc, &fx_dir);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir) LoadError!?[]u8 {
    var file = fx_dir.openFile(io_mod.getIo(), profile_paths.api_key_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("stored_key", "load failed step=open_file err={s}", .{@errorName(err)});
            return error.StoredKeyUnreadable;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch |err| {
        debug_trace.logf("stored_key", "load failed step=stat err={s}", .{@errorName(err)});
        return error.StoredKeyUnreadable;
    };
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("stored_key", "load failed step=permissions err=StoredKeyInsecure", .{});
        return error.StoredKeyInsecure;
    }

    const bytes = io_mod.readFileToEnd(alloc, &file, max_key_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("stored_key", "load failed step=read err={s}", .{@errorName(err)});
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

fn storeInProfile(alloc: Allocator, value: []const u8) StoreError!void {
    const home = io_mod.getenv("HOME") orelse return writeFailed("home", error.HomeNotSet);
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
            return writeFailed("open_home", err);
        },
    };
    defer home_dir.close();

    var fx_dir = io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name) catch |err| {
        return writeFailed("open_profile", err);
    };
    defer fx_dir.close();

    return storeInDir(alloc, &fx_dir, value);
}

fn storeInProfileWithDisposition(alloc: Allocator, value: []const u8) host.SecretStoreWriteReport {
    const home = io_mod.getenv("HOME") orelse {
        logWriteFailed("home", error.HomeNotSet);
        return .{ .durable_write = .unchanged, .failure = error.StoredKeyWriteFailed };
    };
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
            logWriteFailed("open_home", err);
            return .{ .durable_write = .unchanged, .failure = error.StoredKeyWriteFailed };
        },
    };
    defer home_dir.close();

    var fx_dir = io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name) catch |err| {
        logWriteFailed("open_profile", err);
        return .{ .durable_write = .unchanged, .failure = error.StoredKeyWriteFailed };
    };
    defer fx_dir.close();

    io_mod.durableReplaceVerified(alloc, &fx_dir, profile_paths.api_key_file_name, value) catch |err| {
        const durable_write: host.DurableWriteState = switch (err) {
            error.DurableReplacePostRenameFailed => .replaced,
            else => .unchanged,
        };
        logWriteFailed("replace", err);
        return .{ .durable_write = durable_write, .failure = error.StoredKeyWriteFailed };
    };
    return .{ .durable_write = .replaced };
}

/// `durableReplaceVerified` creates the file at 0600 and re-stats it after the rename,
/// so the mode this store depends on is enforced rather than assumed.
fn storeInDir(alloc: Allocator, fx_dir: *io_mod.VerifiedDir, value: []const u8) StoreError!void {
    io_mod.durableReplaceVerified(alloc, fx_dir, profile_paths.api_key_file_name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return writeFailed("replace", err),
    };
}

fn writeFailed(step: []const u8, err: anyerror) StoreError {
    logWriteFailed(step, err);
    return error.StoredKeyWriteFailed;
}

fn logWriteFailed(step: []const u8, err: anyerror) void {
    debug_trace.logf("stored_key", "store failed step={s} err={s}", .{ step, @errorName(err) });
}

test "stored key backend label names the platform store" {
    if (comptime builtin.os.tag == .macos) {
        try std.testing.expectEqualStrings("macOS Keychain", backend_label);
    } else {
        try std.testing.expectEqualStrings("profile file", backend_label);
    }
    try std.testing.expectEqualStrings(backend_label, provider.backend_label);
}

test "native secret store preserves Keychain publication certainty" {
    const unchanged = keychainStoreWriteReport(.{
        .disposition = .unchanged,
        .failure = error.KeychainWriteFailed,
    });
    try std.testing.expectEqual(host.DurableWriteState.unchanged, unchanged.durable_write);
    try std.testing.expectEqual(error.StoredKeyWriteFailed, unchanged.failure.?);

    const indeterminate = keychainStoreWriteReport(.{
        .disposition = .indeterminate,
        .failure = error.KeychainWriteFailed,
    });
    try std.testing.expectEqual(host.DurableWriteState.indeterminate, indeterminate.durable_write);
    try std.testing.expectEqual(error.StoredKeyWriteFailed, indeterminate.failure.?);

    const replaced = keychainStoreWriteReport(.{ .disposition = .replaced });
    try std.testing.expectEqual(host.DurableWriteState.replaced, replaced.durable_write);
    try std.testing.expect(replaced.failure == null);
}

test "stored key file round-trips byte-identically at mode 0600" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fx_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer fx_dir.close();

    const written = "vt1-file-round-trip-value";
    try storeInDir(std.testing.allocator, &fx_dir, written);

    const stat = try tmp.dir.statFile(std.testing.io, profile_paths.api_key_file_name, .{});
    try std.testing.expect(stat.permissions.toMode() & 0o777 == 0o600);

    const read_back = (try loadFromDir(std.testing.allocator, &fx_dir.dir)) orelse
        return error.TestUnexpectedMissingStoredKey;
    defer secret.zeroAndFree(std.testing.allocator, read_back);
    try std.testing.expectEqualStrings(written, read_back);
}

test "stored key file refusal stays distinguishable from absence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fx_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer fx_dir.close();

    try std.testing.expect((try loadFromDir(std.testing.allocator, &fx_dir.dir)) == null);

    try storeInDir(std.testing.allocator, &fx_dir, "vt2-secret-value");
    for ([_]std.posix.mode_t{ 0o640, 0o604, 0o644 }) |mode| {
        var file = try tmp.dir.openFile(std.testing.io, profile_paths.api_key_file_name, .{ .mode = .read_write });
        try file.setPermissions(std.testing.io, std.Io.File.Permissions.fromMode(mode));
        file.close(std.testing.io);

        try std.testing.expectError(
            error.StoredKeyInsecure,
            loadFromDir(std.testing.allocator, &fx_dir.dir),
        );
    }

    try tmp.dir.deleteFile(std.testing.io, profile_paths.api_key_file_name);
    try std.testing.expect((try loadFromDir(std.testing.allocator, &fx_dir.dir)) == null);
}

test "stored key file tolerates a trailing newline and rejects an empty value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fx_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer fx_dir.close();

    try storeInDir(std.testing.allocator, &fx_dir, "hand-edited-value\n");
    const read_back = (try loadFromDir(std.testing.allocator, &fx_dir.dir)) orelse
        return error.TestUnexpectedMissingStoredKey;
    defer secret.zeroAndFree(std.testing.allocator, read_back);
    try std.testing.expectEqualStrings("hand-edited-value", read_back);

    try storeInDir(std.testing.allocator, &fx_dir, "\n\n");
    try std.testing.expect((try loadFromDir(std.testing.allocator, &fx_dir.dir)) == null);

    try std.testing.expectError(error.StoredKeyWriteFailed, store(std.testing.allocator, ""));
}
