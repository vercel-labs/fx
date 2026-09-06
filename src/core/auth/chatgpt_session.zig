const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const types = @import("../shared/types.zig");
const secret = @import("secret.zig");
const session_presence = @import("session_presence.zig");

const Allocator = std.mem.Allocator;
const schema_version: i64 = 1;
const max_auth_file_bytes: usize = 64 * 1024;
const expiry_skew_ms: i64 = 60 * 1000;
const mutation_lock_file_name = "chatgpt-auth.lock";
const mutation_lock_deadline_ms: u64 = 2000;

pub const issuer = "https://auth.openai.com";
pub const auth_file_name = profile_paths.chatgpt_auth_file_name;

pub fn presence() host.SecretStorePresence {
    return session_presence.profileFile(auth_file_name, max_auth_file_bytes);
}

pub fn requireSignInStorage() error{CredentialStorageUnavailable}!void {
    _ = try session_presence.requireWritableProfileFile(auth_file_name, mutation_lock_file_name);
}

pub fn refreshDeadlineMs(expires_at_ms: i64) i64 {
    return @max(expires_at_ms - expiry_skew_ms, 0);
}

pub const Session = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    account_id: []u8,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }

    pub fn expired(self: Session, now_ms: i64) bool {
        return refreshDeadlineMs(self.expires_at_ms) <= now_ms;
    }
};

pub const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

pub const Mutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn requireWritable(self: *Mutation) error{CredentialStorageUnavailable}!void {
        _ = try session_presence.requireWritableInDir(self.fx_dir.dir, auth_file_name);
    }

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        return loadFromDir(alloc, &self.fx_dir.dir);
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(alloc, &self.fx_dir, auth_file_name, text);
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        self.fx_dir.dir.deleteFile(io_mod.getIo(), auth_file_name) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        const durable: io_mod.DurableOps = .{};
        durable.sync_dir(durable.ctx, self.fx_dir.dir) catch return .deleted_not_durable;
        return .deleted;
    }
};

pub fn load(alloc: Allocator) !?Session {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("auth", "ChatGPT session load failed step=open_home err={s}", .{@errorName(err)});
        if (err == error.FileNotFound) return null;
        return session_presence.storageError(auth_file_name, err);
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        if (err != error.FileNotFound) {
            debug_trace.logf("auth", "ChatGPT session load failed step=open_profile err={s}", .{@errorName(err)});
        }
        if (err == error.FileNotFound) return null;
        return session_presence.storageError(auth_file_name, err);
    };
    defer fx_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &fx_dir);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir) !?Session {
    var file = fx_dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "ChatGPT session load failed step=open_file err={s}", .{@errorName(err)});
            return session_presence.storageError(auth_file_name, err);
        },
    };
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch |err| return session_presence.storageError(auth_file_name, err);
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "ChatGPT session load failed step=permissions err=InsecureAuthFile", .{});
        return error.InsecureAuthFile;
    }

    const bytes = io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes) catch |err| return session_presence.storageError(auth_file_name, err);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "ChatGPT session load failed step=parse err={s}", .{@errorName(err)});
            return error.InvalidChatGptAuthSession;
        },
    };
}

pub fn saveNewSession(alloc: Allocator, session: Session) !void {
    if (comptime host_target.is_wasm) return error.ChatGptOAuthUnavailable;
    var mutation = try beginMutation();
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation() !?Mutation {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| return session_presence.storageError(auth_file_name, err),
    };
    defer home_dir.close();

    const fx_dir = openExistingPrivateFxDir(&home_dir) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return session_presence.storageError(auth_file_name, err),
    };
    return try lockMutation(fx_dir);
}

fn beginMutation() !Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| return session_presence.storageError(auth_file_name, err),
    };
    defer home_dir.close();

    const fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    return lockMutation(fx_dir);
}

fn lockMutation(open_fx_dir: io_mod.VerifiedDir) !Mutation {
    var fx_dir = open_fx_dir;
    errdefer fx_dir.close();
    var lock = io_mod.acquireTimedAdvisoryLock(
        &fx_dir,
        mutation_lock_file_name,
        mutation_lock_deadline_ms,
    ) catch |err| return session_presence.storageError(auth_file_name, err);
    errdefer lock.release();
    return .{ .fx_dir = fx_dir, .lock = lock };
}

fn openExistingPrivateFxDir(home_dir: *io_mod.VerifiedDir) !io_mod.VerifiedDir {
    var dir = try home_dir.dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(io_mod.getIo());

    const initial_stat = try dir.stat(io_mod.getIo());
    if (initial_stat.kind != .directory) return error.DurablePathUnsafe;
    if (initial_stat.permissions.toMode() & 0o200 == 0) return error.PrivateStatePermissionsUnsupported;
    dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o700)) catch {
        return error.PrivateStatePermissionsUnsupported;
    };
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory or stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
    return .{ .dir = dir };
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidChatGptAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidChatGptAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidChatGptAuthSession;

    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, object, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const account_id = try dupeRequiredString(alloc, object, "account_id");
    errdefer alloc.free(account_id);
    if (!types.validCredentialAccountId(account_id)) return error.InvalidChatGptAuthSession;
    const expires_at_ms = try requiredInteger(object, "expires_at_ms");
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
    };
}

pub fn stringify(alloc: Allocator, session: Session) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"version\":1,\"access_token\":");
    try std.json.Stringify.value(session.access_token, .{}, &out.writer);
    try out.writer.writeAll(",\"refresh_token\":");
    try std.json.Stringify.value(session.refresh_token, .{}, &out.writer);
    try out.writer.print(",\"expires_at_ms\":{d},\"account_id\":", .{session.expires_at_ms});
    try std.json.Stringify.value(session.account_id, .{}, &out.writer);
    try out.writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidChatGptAuthSession;
    if (value != .string or value.string.len == 0) return error.InvalidChatGptAuthSession;
    return alloc.dupe(u8, value.string);
}

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidChatGptAuthSession;
    if (value != .integer) return error.InvalidChatGptAuthSession;
    return value.integer;
}

test "ChatGPT auth session round trips without exposing token fields to structure" {
    const alloc = std.testing.allocator;
    var session = Session{
        .access_token = try alloc.dupe(u8, "header.payload.signature"),
        .refresh_token = try alloc.dupe(u8, "refresh"),
        .expires_at_ms = 1234,
        .account_id = try alloc.dupe(u8, "acct_123"),
    };
    defer session.deinit(alloc);

    const encoded = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, encoded);
    var decoded = try parse(alloc, encoded);
    defer decoded.deinit(alloc);

    try std.testing.expectEqualStrings(session.access_token, decoded.access_token);
    try std.testing.expectEqualStrings(session.refresh_token, decoded.refresh_token);
    try std.testing.expectEqualStrings(session.account_id, decoded.account_id);
    try std.testing.expectEqual(session.expires_at_ms, decoded.expires_at_ms);
}

test "ChatGPT session refresh deadline keeps a one minute safety margin" {
    try std.testing.expectEqual(@as(i64, 40_000), refreshDeadlineMs(100_000));
    try std.testing.expectEqual(@as(i64, 0), refreshDeadlineMs(10_000));
}

test "ChatGPT auth session rejects account identifiers unsafe for HTTP headers" {
    var session = parse(
        std.testing.allocator,
        "{\"version\":1,\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_at_ms\":1000,\"account_id\":\"acct\\r\\ninjected\"}",
    ) catch |err| {
        try std.testing.expectEqual(error.InvalidChatGptAuthSession, err);
        return;
    };
    defer session.deinit(std.testing.allocator);
    return error.TestExpectedInvalidChatGptAuthSession;
}
