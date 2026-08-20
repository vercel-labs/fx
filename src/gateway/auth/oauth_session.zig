const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../../core/shared/debug_trace.zig");
const host_target = @import("../../core/hosts/target.zig");
const native_keychain = @import("../../core/hosts/native_keychain.zig");
const io_mod = @import("../../core/shared/io.zig");
const profile_paths = @import("../../core/shared/profile_paths.zig");
const js_host_auth = @import("js_host_auth.zig");
const secret = @import("../../core/auth/secret.zig");

const Allocator = std.mem.Allocator;

pub const issuer = "https://vercel.com";
pub const client_id_env = "FX_OAUTH_CLIENT_ID";
pub const default_client_id = "cl_zzh5hiOZbwJ9bfqEcYqPIJv3TaPaEYL0";
const e2e_issuer_url_env = "FX_E2E_OAUTH_ISSUER_URL";
pub const auth_file_name = profile_paths.auth_file_name;
const schema_version: i64 = 1;
const max_auth_file_bytes: usize = 64 * 1024;
const expiry_skew_ms: i64 = 60 * 1000;
const mutation_lock_file_name = "auth.lock";
const mutation_lock_deadline_ms: u64 = 2000;
const e2e_lock_contention_file_name = "auth-lock-contention";
const LoadMode = enum { tolerate_open_failure, report_open_failure };

const StorageBackend = enum {
    profile_file,
    macos_keychain,
};

const FileState = enum { absent, valid, unusable };
const KeychainState = enum { absent, valid, invalid, unavailable };
const Resolution = enum {
    missing,
    file_migrate,
    file_defer_migration,
    keychain,
    storage_error,
};

const Authority = enum { unresolved, missing, profile_file, keychain };

const KeychainError = Allocator.Error || native_keychain.Error;

const KeychainBackend = struct {
    context: ?*anyopaque = null,
    load_fn: *const fn (?*anyopaque, Allocator) KeychainError!?[]u8,
    store_fn: *const fn (?*anyopaque, []const u8) KeychainError!void,
    delete_fn: *const fn (?*anyopaque, Allocator) KeychainError!bool,

    fn load(self: KeychainBackend, alloc: Allocator) KeychainError!?[]u8 {
        return self.load_fn(self.context, alloc);
    }

    fn store(self: KeychainBackend, value: []const u8) KeychainError!void {
        return self.store_fn(self.context, value);
    }

    fn delete(self: KeychainBackend, alloc: Allocator) KeychainError!bool {
        return self.delete_fn(self.context, alloc);
    }
};

const native_keychain_backend: KeychainBackend = .{
    .load_fn = nativeKeychainLoad,
    .store_fn = nativeKeychainStore,
    .delete_fn = nativeKeychainDelete,
};

fn nativeKeychainLoad(_: ?*anyopaque, alloc: Allocator) KeychainError!?[]u8 {
    return native_keychain.loadOAuthSession(alloc);
}

fn nativeKeychainStore(_: ?*anyopaque, value: []const u8) KeychainError!void {
    return native_keychain.storeOAuthSession(value);
}

fn nativeKeychainDelete(_: ?*anyopaque, alloc: Allocator) KeychainError!bool {
    return native_keychain.deleteOAuthSession(alloc);
}

fn selectStorageBackend(os_tag: std.Target.Os.Tag, keychain_disabled: bool) StorageBackend {
    if (os_tag == .macos and !keychain_disabled) return .macos_keychain;
    return .profile_file;
}

fn storageBackend() StorageBackend {
    return selectStorageBackend(builtin.os.tag, native_keychain.isDisabled());
}

fn selectResolution(file: FileState, keychain: KeychainState) Resolution {
    return switch (file) {
        .valid => if (keychain == .unavailable) .file_defer_migration else .file_migrate,
        .absent, .unusable => switch (keychain) {
            .absent => .missing,
            .valid => .keychain,
            .invalid, .unavailable => .storage_error,
        },
    };
}

pub fn refresh_deadline_ms(expires_at_ms: i64) i64 {
    return expires_at_ms -| expiry_skew_ms;
}

const MutationLockProbe = struct {
    fx_dir: std.Io.Dir,
    signaled: bool = false,

    fn tryLock(raw_ctx: ?*anyopaque, file: std.Io.File) anyerror!bool {
        const locked = try file.tryLock(io_mod.getIo(), .exclusive);
        const self: *MutationLockProbe = @ptrCast(@alignCast(raw_ctx.?));
        if (!locked and !self.signaled) {
            signalE2ELockContention(self.fx_dir);
            self.signaled = true;
        }
        return locked;
    }
};

fn signalE2ELockContention(fx_dir: std.Io.Dir) void {
    const enabled = io_mod.getenv("FX_E2E_AUTH_LOCK_CONTENTION") orelse return;
    if (!std.mem.eql(u8, enabled, "1")) return;
    var file = fx_dir.createFile(io_mod.getIo(), e2e_lock_contention_file_name, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    }) catch return;
    defer file.close(io_mod.getIo());
    file.writeStreamingAll(io_mod.getIo(), "contended\n") catch {};
}

const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

pub const DeleteResult = struct {
    session_deleted: bool = false,
    local_cleanup_failed: bool = false,
};

pub const Session = struct {
    issuer: []u8,
    client_id: []u8,
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    scope: []u8,
    token_type: []u8,
    team_slug: ?[]u8 = null,
    team_id: ?[]u8 = null,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        alloc.free(self.issuer);
        alloc.free(self.client_id);
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.scope);
        alloc.free(self.token_type);
        if (self.team_slug) |value| alloc.free(value);
        if (self.team_id) |value| alloc.free(value);
        self.* = undefined;
    }

    pub fn expired(self: Session, now_ms: i64) bool {
        return refresh_deadline_ms(self.expires_at_ms) <= now_ms;
    }
};

const FileObservation = union(enum) {
    absent,
    valid: Session,
    unusable,

    fn state(self: FileObservation) FileState {
        return switch (self) {
            .absent => .absent,
            .valid => .valid,
            .unusable => .unusable,
        };
    }

    fn takeSession(self: *FileObservation) ?Session {
        return switch (self.*) {
            .valid => |session| blk: {
                self.* = .absent;
                break :blk session;
            },
            else => null,
        };
    }

    fn deinit(self: *FileObservation, alloc: Allocator) void {
        switch (self.*) {
            .valid => |*session| session.deinit(alloc),
            else => {},
        }
        self.* = .absent;
    }
};

const KeychainObservation = union(enum) {
    absent,
    valid: Session,
    invalid,
    unavailable: KeychainError,

    fn state(self: KeychainObservation) KeychainState {
        return switch (self) {
            .absent => .absent,
            .valid => .valid,
            .invalid => .invalid,
            .unavailable => .unavailable,
        };
    }

    fn takeSession(self: *KeychainObservation) ?Session {
        return switch (self.*) {
            .valid => |session| blk: {
                self.* = .absent;
                break :blk session;
            },
            else => null,
        };
    }

    fn storageError(self: KeychainObservation) (KeychainError || error{
        InvalidOAuthKeychainSession,
        InvalidOAuthStorageState,
    }) {
        return switch (self) {
            .invalid => error.InvalidOAuthKeychainSession,
            .unavailable => |err| err,
            else => error.InvalidOAuthStorageState,
        };
    }

    fn deinit(self: *KeychainObservation, alloc: Allocator) void {
        switch (self.*) {
            .valid => |*session| session.deinit(alloc),
            else => {},
        }
        self.* = .absent;
    }
};

fn observeAuthFile(alloc: Allocator, fx_dir: *std.Io.Dir) !FileObservation {
    var file = fx_dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => {
            debug_trace.logf("auth", "session load failed source=file step=open err={s}", .{@errorName(err)});
            return .unusable;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = file.stat(io_mod.getIo()) catch |err| {
        debug_trace.logf("auth", "session load failed source=file step=stat err={s}", .{@errorName(err)});
        return .unusable;
    };
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "session load failed source=file step=permissions err=InsecureAuthFile", .{});
        return .unusable;
    }

    const bytes = io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "session load failed source=file step=read err={s}", .{@errorName(err)});
            return .unusable;
        },
    };
    defer secret.zeroAndFree(alloc, bytes);
    const session = parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "session load failed source=file step=parse err={s}", .{@errorName(err)});
            return .unusable;
        },
    };
    return .{ .valid = session };
}

fn observeKeychain(alloc: Allocator, keychain: KeychainBackend) !KeychainObservation {
    const maybe_bytes = keychain.load(alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.KeychainItemNotFound => return .absent,
        else => return .{ .unavailable = err },
    };
    const bytes = maybe_bytes orelse return .absent;
    defer secret.zeroAndFree(alloc, bytes);
    if (bytes.len > max_auth_file_bytes) return .invalid;
    const session = parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .invalid,
    };
    return .{ .valid = session };
}

fn publishAndVerifyKeychain(alloc: Allocator, keychain: KeychainBackend, session: Session) !void {
    const bytes = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, bytes);
    try keychain.store(bytes);
    const persisted = keychain.load(alloc) catch |err| switch (err) {
        error.KeychainItemNotFound => return error.OAuthSessionKeychainWriteMismatch,
        else => return err,
    } orelse return error.OAuthSessionKeychainWriteMismatch;
    defer secret.zeroAndFree(alloc, persisted);
    if (!std.mem.eql(u8, bytes, persisted)) return error.OAuthSessionKeychainWriteMismatch;
}

fn authFileExists(fx_dir: *std.Io.Dir) !bool {
    _ = fx_dir.statFile(io_mod.getIo(), auth_file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub const Mutation = if (host_target.is_wasm) HostMutation else NativeMutation;

const NativeMutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,
    backend: StorageBackend,
    keychain: KeychainBackend,
    authority: Authority = .unresolved,

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        if (self.backend == .profile_file) {
            self.authority = .profile_file;
            return loadFromDir(alloc, &self.fx_dir.dir, .report_open_failure);
        }
        return self.loadKeychainResolved(alloc);
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        if (self.backend == .macos_keychain) {
            return self.saveKeychainResolved(alloc, session);
        }
        self.authority = .profile_file;
        return self.saveFile(alloc, session);
    }

    fn saveFile(self: *Mutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(alloc, &self.fx_dir, auth_file_name, text);
    }

    pub fn delete(self: *Mutation, alloc: Allocator) !DeleteResult {
        var result: DeleteResult = .{};
        if (self.backend == .macos_keychain) {
            const deleted = self.keychain.delete(alloc) catch blk: {
                result.local_cleanup_failed = true;
                break :blk false;
            };
            result.session_deleted = result.session_deleted or deleted;
        }

        const file_outcome = deleteAuthFile(&self.fx_dir.dir, .{}) catch {
            result.local_cleanup_failed = true;
            return result;
        };
        switch (file_outcome) {
            .missing => {},
            .deleted => result.session_deleted = true,
            .deleted_not_durable => {
                result.session_deleted = true;
                result.local_cleanup_failed = true;
            },
        }
        self.authority = .missing;
        return result;
    }

    fn loadKeychainResolved(self: *Mutation, alloc: Allocator) !?Session {
        var file = try observeAuthFile(alloc, &self.fx_dir.dir);
        defer file.deinit(alloc);
        var keychain = try observeKeychain(alloc, self.keychain);
        defer keychain.deinit(alloc);

        switch (selectResolution(file.state(), keychain.state())) {
            .missing => {
                self.authority = .missing;
                return null;
            },
            .keychain => {
                self.authority = .keychain;
                return keychain.takeSession().?;
            },
            .file_defer_migration => {
                self.authority = .profile_file;
                return file.takeSession().?;
            },
            .file_migrate => {
                var session = file.takeSession().?;
                errdefer session.deinit(alloc);
                const migrated = try self.publishAndCleanup(alloc, session);
                self.authority = if (migrated) .keychain else .profile_file;
                return session;
            },
            .storage_error => return keychain.storageError(),
        }
    }

    fn saveKeychainResolved(self: *Mutation, alloc: Allocator, session: Session) !void {
        if (self.authority == .unresolved) {
            self.authority = if (try authFileExists(&self.fx_dir.dir)) .profile_file else .keychain;
        }

        switch (self.authority) {
            .profile_file => {
                try self.saveFile(alloc, session);
                const migrated = try self.publishAndCleanup(alloc, session);
                if (migrated) self.authority = .keychain;
            },
            .keychain, .missing => {
                try publishAndVerifyKeychain(alloc, self.keychain, session);
                self.authority = .keychain;
            },
            .unresolved => unreachable,
        }
    }

    fn publishAndCleanup(self: *Mutation, alloc: Allocator, session: Session) !bool {
        publishAndVerifyKeychain(alloc, self.keychain, session) catch |err| {
            debug_trace.logf("auth", "session migration deferred step=publish err={s}", .{@errorName(err)});
            return false;
        };

        const outcome = deleteAuthFile(&self.fx_dir.dir, .{}) catch |err| {
            const stat = self.fx_dir.dir.statFile(io_mod.getIo(), auth_file_name, .{}) catch |stat_err| switch (stat_err) {
                error.FileNotFound => return error.OAuthSessionCleanupUncertain,
                else => return stat_err,
            };
            if (stat.kind != .file) return error.OAuthSessionCleanupUncertain;
            debug_trace.logf("auth", "session migration deferred step=delete err={s}", .{@errorName(err)});
            return false;
        };
        return switch (outcome) {
            .deleted => true,
            .missing => blk: {
                try io_mod.syncVerifiedDir(self.fx_dir.dir);
                break :blk true;
            },
            .deleted_not_durable => error.OAuthSessionCleanupUncertain,
        };
    }
};

const HostMutation = struct {
    store: js_host_auth.SessionStore = js_host_auth.oauth_session_store,
    revision: [js_host_auth.max_revision_bytes]u8 = undefined,
    revision_len: usize = 0,
    exists: bool = false,

    fn init(store: js_host_auth.SessionStore) HostMutation {
        return .{ .store = store };
    }

    pub fn deinit(self: *HostMutation) void {
        @memset(&self.revision, 0);
        self.* = undefined;
    }

    pub fn load(self: *HostMutation, alloc: Allocator) !?Session {
        var stored = (try self.store.load(alloc)) orelse {
            self.exists = false;
            self.revision_len = 0;
            return null;
        };
        defer stored.deinit(alloc);
        try self.captureStoredRevision(stored.revision);
        return @as(?Session, try parse(alloc, stored.bytes));
    }

    pub fn save(self: *HostMutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        const expected = if (self.exists) self.revision[0..self.revision_len] else null;
        const revision = try self.store.commit(alloc, text, expected);
        defer alloc.free(revision);
        try self.captureStoredRevision(revision);
    }

    pub fn delete(self: *HostMutation, _: Allocator) !DeleteResult {
        const expected = if (self.exists) self.revision[0..self.revision_len] else null;
        return switch (try self.store.remove(expected)) {
            .deleted => .{ .session_deleted = true },
            .missing => .{},
        };
    }

    fn captureRevision(self: *HostMutation, alloc: Allocator) !void {
        var stored = (try self.store.load(alloc)) orelse {
            self.exists = false;
            self.revision_len = 0;
            return;
        };
        defer stored.deinit(alloc);
        try self.captureStoredRevision(stored.revision);
    }

    fn captureStoredRevision(self: *HostMutation, revision: []const u8) !void {
        if (revision.len > self.revision.len) return error.OAuthSessionRevisionTooLarge;
        @memcpy(self.revision[0..revision.len], revision);
        self.revision_len = revision.len;
        self.exists = true;
    }
};

pub fn configuredClientId() ?[]const u8 {
    if (io_mod.getenv(client_id_env)) |value| {
        if (std.mem.trim(u8, value, " \t\r\n").len > 0) return value;
    }
    return if (default_client_id.len == 0) null else default_client_id;
}

pub fn configuredIssuerUrl() ![]const u8 {
    return selectIssuerUrl(io_mod.getenv(e2e_issuer_url_env));
}

pub fn isLoopbackE2EIssuer(url: []const u8) bool {
    return !std.mem.eql(u8, url, issuer) and isLoopbackHttpUrl(url, true);
}

pub fn validateE2EEndpoint(issuer_url: []const u8, endpoint: []const u8) !void {
    if (isLoopbackE2EIssuer(issuer_url) and !isLoopbackHttpUrl(endpoint, false)) {
        return error.InvalidE2EOAuthEndpoint;
    }
}

fn selectIssuerUrl(override: ?[]const u8) ![]const u8 {
    const raw = override orelse return issuer;
    const candidate = std.mem.trimEnd(u8, raw, "/");
    if (!isLoopbackHttpUrl(candidate, true)) return error.InvalidE2EOAuthIssuer;
    return candidate;
}

fn isLoopbackHttpUrl(url: []const u8, require_origin: bool) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port == null or
        (require_origin and (!uri.path.isEmpty() or uri.query != null or uri.fragment != null)))
    {
        return false;
    }

    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

pub fn load(alloc: Allocator) !?Session {
    if (comptime host_target.is_wasm) return loadFromHost(alloc, js_host_auth.oauth_session_store);
    const home = io_mod.getenv("HOME") orelse {
        debug_trace.logf("auth", "session load skipped step=home err=HomeNotSet", .{});
        return null;
    };
    if (storageBackend() == .macos_keychain) {
        if (try beginExistingNativeMutation()) |existing| {
            var mutation = existing;
            defer mutation.deinit();
            return mutation.load(alloc);
        }
        return loadKeychainWithoutProfile(alloc);
    }
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("auth", "session load failed step=open_home err={s}", .{@errorName(err)});
        return null;
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        debug_trace.logf("auth", "session load failed step=open_profile err={s}", .{@errorName(err)});
        return null;
    };
    defer fx_dir.close(io_mod.getIo());

    return loadFromDir(alloc, &fx_dir, .tolerate_open_failure);
}

fn loadFromHost(alloc: Allocator, store: js_host_auth.SessionStore) !?Session {
    var stored = (try store.load(alloc)) orelse return null;
    defer stored.deinit(alloc);
    return parse(alloc, stored.bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir, mode: LoadMode) !?Session {
    var file = fx_dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "session load failed step=open_file err={s}", .{@errorName(err)});
            if (mode == .tolerate_open_failure) return null else return err;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "session load failed step=permissions err=InsecureAuthFile", .{});
        return null;
    }

    const bytes = try io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

pub fn saveNewSession(alloc: Allocator, session: Session) !void {
    if (comptime host_target.is_wasm) {
        var mutation = HostMutation.init(js_host_auth.oauth_session_store);
        defer mutation.deinit();
        try mutation.captureRevision(alloc);
        return mutation.save(alloc, session);
    }
    var mutation = try beginMutation();
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation() !?Mutation {
    if (comptime host_target.is_wasm) {
        return @as(?Mutation, HostMutation.init(js_host_auth.oauth_session_store));
    }
    if (storageBackend() == .macos_keychain) {
        return @as(?Mutation, try beginMutation());
    }
    return beginExistingNativeMutation();
}

fn beginExistingNativeMutation() !?Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    const fx_dir = openExistingPrivateFxDir(&home_dir) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return @as(?Mutation, try lockMutation(fx_dir));
}

fn loadKeychainWithoutProfile(alloc: Allocator) !?Session {
    var keychain = try observeKeychain(alloc, native_keychain_backend);
    defer keychain.deinit(alloc);

    if (try beginExistingNativeMutation()) |existing| {
        var mutation = existing;
        defer mutation.deinit();
        return mutation.load(alloc);
    }

    return switch (selectResolution(.absent, keychain.state())) {
        .missing => null,
        .keychain => keychain.takeSession().?,
        .storage_error => keychain.storageError(),
        .file_migrate, .file_defer_migration => unreachable,
    };
}

fn beginMutation() !Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    const fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    return lockMutation(fx_dir);
}

fn lockMutation(open_fx_dir: io_mod.VerifiedDir) !Mutation {
    var probe = MutationLockProbe{ .fx_dir = open_fx_dir.dir };
    return lockMutationWithOps(open_fx_dir, mutation_lock_deadline_ms, .{
        .ctx = &probe,
        .try_lock = MutationLockProbe.tryLock,
    });
}

fn lockMutationWithOps(
    open_fx_dir: io_mod.VerifiedDir,
    deadline_ms: u64,
    ops: io_mod.LockOps,
) !Mutation {
    return lockMutationWithBackend(
        open_fx_dir,
        deadline_ms,
        ops,
        storageBackend(),
        native_keychain_backend,
    );
}

fn lockMutationWithBackend(
    open_fx_dir: io_mod.VerifiedDir,
    deadline_ms: u64,
    ops: io_mod.LockOps,
    backend: StorageBackend,
    keychain: KeychainBackend,
) !Mutation {
    var fx_dir = open_fx_dir;
    errdefer fx_dir.close();

    var lock = try io_mod.acquireTimedAdvisoryLockWithOps(
        &fx_dir,
        mutation_lock_file_name,
        deadline_ms,
        ops,
    );
    errdefer lock.release();

    return .{
        .fx_dir = fx_dir,
        .lock = lock,
        .backend = backend,
        .keychain = keychain,
    };
}

fn openExistingPrivateFxDir(home_dir: *io_mod.VerifiedDir) !io_mod.VerifiedDir {
    var dir = try home_dir.dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    errdefer dir.close(io_mod.getIo());

    const initial_stat = try dir.stat(io_mod.getIo());
    if (initial_stat.kind != .directory) return error.DurablePathUnsafe;
    if (initial_stat.permissions.toMode() & 0o200 == 0) {
        return error.PrivateStatePermissionsUnsupported;
    }
    dir.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(0o700)) catch {
        return error.PrivateStatePermissionsUnsupported;
    };
    const stat = try dir.stat(io_mod.getIo());
    if (stat.kind != .directory) return error.DurablePathUnsafe;
    if (stat.permissions.toMode() & 0o777 != 0o700) {
        return error.PrivateStatePermissionsUnsupported;
    }
    return .{ .dir = dir };
}

fn deleteAuthFile(fx_dir: *std.Io.Dir, ops: io_mod.DurableOps) !DeleteOutcome {
    fx_dir.deleteFile(io_mod.getIo(), auth_file_name) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    ops.sync_dir(ops.ctx, fx_dir.*) catch return .deleted_not_durable;
    return .deleted;
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidAuthSession;
    const saved_issuer = try requiredString(object, "issuer");
    if (!std.mem.eql(u8, saved_issuer, issuer) and !isLoopbackE2EIssuer(saved_issuer)) {
        return error.InvalidAuthSession;
    }

    const expires_at_ms = try requiredInteger(object, "expires_at_ms");
    const owned_issuer = try alloc.dupe(u8, saved_issuer);
    errdefer alloc.free(owned_issuer);
    const client_id = try dupeRequiredString(alloc, object, "client_id");
    errdefer alloc.free(client_id);
    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, object, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const scope = try dupeRequiredString(alloc, object, "scope");
    errdefer alloc.free(scope);
    const token_type = try dupeRequiredString(alloc, object, "token_type");
    errdefer alloc.free(token_type);
    const team_slug = try dupeOptionalString(alloc, object, "team_slug");
    errdefer if (team_slug) |value| alloc.free(value);
    const team_id = try dupeOptionalString(alloc, object, "team_id");
    errdefer if (team_id) |value| alloc.free(value);

    return .{
        .issuer = owned_issuer,
        .client_id = client_id,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .scope = scope,
        .token_type = token_type,
        .team_slug = team_slug,
        .team_id = team_id,
    };
}

pub fn stringify(alloc: Allocator, session: Session) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"version\":1");
    try writeField(writer, "issuer", session.issuer);
    try writeField(writer, "client_id", session.client_id);
    try writeField(writer, "access_token", session.access_token);
    try writeField(writer, "refresh_token", session.refresh_token);
    try writer.print(",\"expires_at_ms\":{d}", .{session.expires_at_ms});
    try writeField(writer, "scope", session.scope);
    try writeField(writer, "token_type", session.token_type);
    if (session.team_slug) |value| try writeField(writer, "team_slug", value);
    if (session.team_id) |value| try writeField(writer, "team_id", value);
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn writeField(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.writeAll(",");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(":");
    try std.json.Stringify.value(value, .{}, writer);
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    return alloc.dupe(u8, try requiredString(object, key));
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidAuthSession;
    if (value != .string or value.string.len == 0) return error.InvalidAuthSession;
    return value.string;
}

fn dupeOptionalString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len == 0) return error.InvalidAuthSession;
    return try alloc.dupe(u8, value.string);
}

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidAuthSession;
    if (value != .integer) return error.InvalidAuthSession;
    return value.integer;
}

const test_session_json = "{\"version\":1,\"issuer\":\"https://vercel.com\",\"client_id\":\"client\",\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_at_ms\":1,\"scope\":\"openid offline_access\",\"token_type\":\"Bearer\",\"team_slug\":\"team-slug\",\"team_id\":\"team-id\"}";

const HostStoreTestState = struct {
    record: ?[]const u8 = test_session_json,
    revision: []const u8 = "7",
    next_revision: []const u8 = "8",
    force_conflict: bool = false,
    commit_count: usize = 0,
    remove_count: usize = 0,
    expected_revision_matched: bool = false,
    committed_format_matched: bool = false,

    fn provider(self: *@This()) js_host_auth.SessionStore {
        return .{
            .context = self,
            .load_fn = HostStoreTestState.load,
            .commit_fn = HostStoreTestState.commit,
            .remove_fn = HostStoreTestState.remove,
        };
    }

    fn load(raw: ?*anyopaque, alloc: Allocator) !?js_host_auth.StoredSession {
        const self = state(raw);
        const record = self.record orelse return null;
        const bytes = try alloc.dupe(u8, record);
        errdefer secret.zeroAndFree(alloc, bytes);
        return .{
            .bytes = bytes,
            .revision = try alloc.dupe(u8, self.revision),
        };
    }

    fn commit(
        raw: ?*anyopaque,
        alloc: Allocator,
        bytes: []const u8,
        expected_revision: ?[]const u8,
    ) ![]u8 {
        const self = state(raw);
        self.commit_count += 1;
        self.expected_revision_matched = expected_revision != null and
            std.mem.eql(u8, expected_revision.?, self.revision);
        self.committed_format_matched = std.mem.eql(u8, bytes, test_session_json ++ "\n");
        if (self.force_conflict) return error.OAuthSessionRevisionConflict;
        self.revision = self.next_revision;
        return alloc.dupe(u8, self.revision);
    }

    fn remove(raw: ?*anyopaque, expected_revision: ?[]const u8) !js_host_auth.RemoveOutcome {
        const self = state(raw);
        self.remove_count += 1;
        self.expected_revision_matched = expected_revision != null and
            std.mem.eql(u8, expected_revision.?, self.revision);
        if (self.force_conflict) return error.OAuthSessionRevisionConflict;
        if (self.record == null) return .missing;
        self.record = null;
        return .deleted;
    }

    fn state(raw: ?*anyopaque) *@This() {
        return @ptrCast(@alignCast(raw.?));
    }
};

fn check_parse_allocation_failures(alloc: Allocator) !void {
    var session = try parse(alloc, test_session_json);
    defer session.deinit(alloc);
}

fn check_load_allocation_failures(alloc: Allocator, dir: *std.Io.Dir) !void {
    var session = (try loadFromDir(alloc, dir, .report_open_failure)) orelse return error.TestUnexpectedMissingSession;
    defer session.deinit(alloc);
}

test "oauth session stringifies and parses" {
    var session = Session{
        .issuer = try std.testing.allocator.dupe(u8, issuer),
        .client_id = try std.testing.allocator.dupe(u8, "client"),
        .access_token = try std.testing.allocator.dupe(u8, "access"),
        .refresh_token = try std.testing.allocator.dupe(u8, "refresh"),
        .expires_at_ms = 1234,
        .scope = try std.testing.allocator.dupe(u8, "openid offline_access"),
        .token_type = try std.testing.allocator.dupe(u8, "Bearer"),
        .team_slug = try std.testing.allocator.dupe(u8, "vercel-labs"),
        .team_id = try std.testing.allocator.dupe(u8, "team_123"),
    };
    defer session.deinit(std.testing.allocator);

    const text = try stringify(std.testing.allocator, session);
    defer secret.zeroAndFree(std.testing.allocator, text);
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(issuer, parsed.issuer);
    try std.testing.expectEqualStrings("client", parsed.client_id);
    try std.testing.expectEqualStrings("access", parsed.access_token);
    try std.testing.expectEqualStrings("vercel-labs", parsed.team_slug.?);
    try std.testing.expectEqualStrings("team_123", parsed.team_id.?);
}

test "OAuth storage backend selection is platform scoped and explicitly disableable" {
    try std.testing.expectEqual(StorageBackend.macos_keychain, selectStorageBackend(.macos, false));
    try std.testing.expectEqual(StorageBackend.profile_file, selectStorageBackend(.macos, true));
    try std.testing.expectEqual(StorageBackend.profile_file, selectStorageBackend(.linux, false));
    try std.testing.expectEqual(StorageBackend.profile_file, selectStorageBackend(.windows, false));
}

test "OAuth source resolution covers every file and Keychain state" {
    const cases = [_]struct {
        file: FileState,
        keychain: KeychainState,
        expected: Resolution,
    }{
        .{ .file = .absent, .keychain = .absent, .expected = .missing },
        .{ .file = .absent, .keychain = .valid, .expected = .keychain },
        .{ .file = .absent, .keychain = .invalid, .expected = .storage_error },
        .{ .file = .absent, .keychain = .unavailable, .expected = .storage_error },
        .{ .file = .valid, .keychain = .absent, .expected = .file_migrate },
        .{ .file = .valid, .keychain = .valid, .expected = .file_migrate },
        .{ .file = .valid, .keychain = .invalid, .expected = .file_migrate },
        .{ .file = .valid, .keychain = .unavailable, .expected = .file_defer_migration },
        .{ .file = .unusable, .keychain = .valid, .expected = .keychain },
        .{ .file = .unusable, .keychain = .absent, .expected = .missing },
        .{ .file = .unusable, .keychain = .invalid, .expected = .storage_error },
        .{ .file = .unusable, .keychain = .unavailable, .expected = .storage_error },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, selectResolution(case.file, case.keychain));
    }
}

const alternate_test_session_json = "{\"version\":1,\"issuer\":\"https://vercel.com\",\"client_id\":\"client\",\"access_token\":\"keychain-access\",\"refresh_token\":\"keychain-refresh\",\"expires_at_ms\":2,\"scope\":\"openid offline_access\",\"token_type\":\"Bearer\"}";

const FakeOAuthKeychain = struct {
    alloc: Allocator,
    value: ?[]u8 = null,
    store_calls: usize = 0,
    delete_calls: usize = 0,
    fail_store: bool = false,
    fail_delete: bool = false,

    fn deinit(self: *FakeOAuthKeychain) void {
        if (self.value) |value| secret.zeroAndFree(self.alloc, value);
        self.* = undefined;
    }

    fn backend(self: *FakeOAuthKeychain) KeychainBackend {
        return .{
            .context = self,
            .load_fn = loadCallback,
            .store_fn = storeCallback,
            .delete_fn = deleteCallback,
        };
    }

    fn loadCallback(raw: ?*anyopaque, alloc: Allocator) KeychainError!?[]u8 {
        const self: *FakeOAuthKeychain = @ptrCast(@alignCast(raw.?));
        const value = self.value orelse return null;
        return try alloc.dupe(u8, value);
    }

    fn storeCallback(raw: ?*anyopaque, value: []const u8) KeychainError!void {
        const self: *FakeOAuthKeychain = @ptrCast(@alignCast(raw.?));
        self.store_calls += 1;
        if (self.fail_store) return error.KeychainWriteFailed;
        const replacement = try self.alloc.dupe(u8, value);
        if (self.value) |previous| secret.zeroAndFree(self.alloc, previous);
        self.value = replacement;
    }

    fn deleteCallback(raw: ?*anyopaque, _: Allocator) KeychainError!bool {
        const self: *FakeOAuthKeychain = @ptrCast(@alignCast(raw.?));
        self.delete_calls += 1;
        if (self.fail_delete) return error.KeychainDeleteFailed;
        const previous = self.value orelse return false;
        secret.zeroAndFree(self.alloc, previous);
        self.value = null;
        return true;
    }
};

fn writeTestAuthFile(dir: std.Io.Dir, contents: []const u8) !void {
    var file = try dir.createFile(std.testing.io, auth_file_name, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, contents);
}

fn testKeychainMutation(dir: std.Io.Dir, keychain: KeychainBackend) !Mutation {
    return lockMutationWithBackend(
        .{ .dir = try dir.openDir(std.testing.io, ".", .{ .iterate = true }) },
        0,
        .{},
        .macos_keychain,
        keychain,
    );
}

test "OAuth migration keeps a valid file authoritative until verified cleanup" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestAuthFile(tmp.dir, test_session_json);

    var fake = FakeOAuthKeychain{
        .alloc = alloc,
        .value = try alloc.dupe(u8, alternate_test_session_json),
    };
    defer fake.deinit();
    var mutation = try testKeychainMutation(tmp.dir, fake.backend());
    defer mutation.deinit();

    var loaded = (try mutation.load(alloc)).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("access", loaded.access_token);
    try std.testing.expectEqual(@as(usize, 1), fake.store_calls);
    try std.testing.expectEqual(Authority.keychain, mutation.authority);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, auth_file_name, .{}),
    );

    var persisted = try parse(alloc, fake.value.?);
    defer persisted.deinit(alloc);
    try std.testing.expectEqualStrings("access", persisted.access_token);

    secret.zeroAndFree(alloc, loaded.access_token);
    loaded.access_token = try alloc.dupe(u8, "keychain-only-update");
    try mutation.save(alloc, loaded);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, auth_file_name, .{}),
    );
    var updated = try parse(alloc, fake.value.?);
    defer updated.deinit(alloc);
    try std.testing.expectEqualStrings("keychain-only-update", updated.access_token);
}

test "new OAuth login replaces an existing file before deferred migration" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestAuthFile(tmp.dir, test_session_json);

    var fake = FakeOAuthKeychain{ .alloc = alloc, .fail_store = true };
    defer fake.deinit();
    var mutation = try testKeychainMutation(tmp.dir, fake.backend());
    defer mutation.deinit();
    var replacement = try parse(alloc, alternate_test_session_json);
    defer replacement.deinit(alloc);

    try mutation.save(alloc, replacement);
    var persisted = (try loadFromDir(alloc, &tmp.dir, .report_open_failure)).?;
    defer persisted.deinit(alloc);
    try std.testing.expectEqualStrings("keychain-access", persisted.access_token);
    try std.testing.expectEqual(Authority.profile_file, mutation.authority);
}

test "OAuth migration preserves and updates the file when Keychain publication fails" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestAuthFile(tmp.dir, test_session_json);

    var fake = FakeOAuthKeychain{ .alloc = alloc, .fail_store = true };
    defer fake.deinit();
    var mutation = try testKeychainMutation(tmp.dir, fake.backend());
    defer mutation.deinit();

    var loaded = (try mutation.load(alloc)).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(Authority.profile_file, mutation.authority);
    secret.zeroAndFree(alloc, loaded.access_token);
    loaded.access_token = try alloc.dupe(u8, "updated-access");
    try mutation.save(alloc, loaded);

    var persisted = (try loadFromDir(alloc, &tmp.dir, .report_open_failure)).?;
    defer persisted.deinit(alloc);
    try std.testing.expectEqualStrings("updated-access", persisted.access_token);
    try std.testing.expectEqual(@as(usize, 2), fake.store_calls);
}

test "OAuth resolver uses valid Keychain state without deleting an unusable file" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestAuthFile(tmp.dir, "not-json");

    var fake = FakeOAuthKeychain{
        .alloc = alloc,
        .value = try alloc.dupe(u8, alternate_test_session_json),
    };
    defer fake.deinit();
    var mutation = try testKeychainMutation(tmp.dir, fake.backend());
    defer mutation.deinit();

    var loaded = (try mutation.load(alloc)).?;
    defer loaded.deinit(alloc);
    try std.testing.expectEqualStrings("keychain-access", loaded.access_token);
    _ = try tmp.dir.statFile(std.testing.io, auth_file_name, .{});
}

test "OAuth resolver reports invalid Keychain state when no valid file exists" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake = FakeOAuthKeychain{
        .alloc = alloc,
        .value = try alloc.dupe(u8, "not-json"),
    };
    defer fake.deinit();
    var mutation = try testKeychainMutation(tmp.dir, fake.backend());
    defer mutation.deinit();

    try std.testing.expectError(error.InvalidOAuthKeychainSession, mutation.load(alloc));
}

test "OAuth logout deletion attempts Keychain and file cleanup independently" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestAuthFile(tmp.dir, test_session_json);
    var fake = FakeOAuthKeychain{
        .alloc = alloc,
        .value = try alloc.dupe(u8, alternate_test_session_json),
        .fail_delete = true,
    };
    defer fake.deinit();
    var mutation = try testKeychainMutation(tmp.dir, fake.backend());
    defer mutation.deinit();

    const result = try mutation.delete(alloc);
    try std.testing.expect(result.session_deleted);
    try std.testing.expect(result.local_cleanup_failed);
    try std.testing.expectEqual(@as(usize, 1), fake.delete_calls);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, auth_file_name, .{}),
    );
}

test "JS host OAuth session load commit and remove preserve the native format and revision" {
    var state: HostStoreTestState = .{};
    var loaded = (try loadFromHost(std.testing.allocator, state.provider())).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("access", loaded.access_token);

    var mutation = HostMutation.init(state.provider());
    defer mutation.deinit();
    var current = (try mutation.load(std.testing.allocator)).?;
    defer current.deinit(std.testing.allocator);
    try mutation.save(std.testing.allocator, current);
    try std.testing.expectEqual(@as(usize, 1), state.commit_count);
    try std.testing.expect(state.expected_revision_matched);
    try std.testing.expect(state.committed_format_matched);

    const deleted = try mutation.delete(std.testing.allocator);
    try std.testing.expect(deleted.session_deleted);
    try std.testing.expect(!deleted.local_cleanup_failed);
    try std.testing.expectEqual(@as(usize, 1), state.remove_count);
    try std.testing.expect(state.expected_revision_matched);
}

test "JS host OAuth session revision conflict does not take session ownership" {
    var state = HostStoreTestState{ .force_conflict = true };
    var mutation = HostMutation.init(state.provider());
    defer mutation.deinit();
    var current = (try mutation.load(std.testing.allocator)).?;
    defer current.deinit(std.testing.allocator);
    const access_token = current.access_token.ptr;

    try std.testing.expectError(
        error.OAuthSessionRevisionConflict,
        mutation.save(std.testing.allocator, current),
    );
    try std.testing.expectEqual(access_token, current.access_token.ptr);
    try std.testing.expectEqualStrings("access", current.access_token);
    try std.testing.expectEqual(@as(usize, 1), state.commit_count);
}

test "oauth session parse cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_parse_allocation_failures, .{});
}

test "oauth session parse rejects non-object JSON" {
    try std.testing.expectError(error.InvalidAuthSession, parse(std.testing.allocator, "[]"));
}

test "oauth session loading propagates allocation failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.testing.io, auth_file_name, .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    try file.writeStreamingAll(
        std.testing.io,
        test_session_json,
    );
    file.close(std.testing.io);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_load_allocation_failures,
        .{&tmp.dir},
    );
}

test "OAuth mutation loads report auth file open failures" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(std.testing.io, "missing-auth-target", auth_file_name, .{ .is_directory = false });

    try std.testing.expect((try loadFromDir(std.testing.allocator, &tmp.dir, .tolerate_open_failure)) == null);
    try std.testing.expectError(
        error.SymLinkLoop,
        loadFromDir(std.testing.allocator, &tmp.dir, .report_open_failure),
    );
}

test "oauth session rejects invalid saved issuers" {
    try std.testing.expectError(
        error.InvalidAuthSession,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"issuer\":\"https://example.com\",\"client_id\":\"client\",\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_at_ms\":1234,\"scope\":\"openid\",\"token_type\":\"Bearer\"}",
        ),
    );
}

test "oauth session treats near-expiry as expired" {
    var session = Session{
        .issuer = try std.testing.allocator.dupe(u8, issuer),
        .client_id = try std.testing.allocator.dupe(u8, "client"),
        .access_token = try std.testing.allocator.dupe(u8, "access"),
        .refresh_token = try std.testing.allocator.dupe(u8, "refresh"),
        .expires_at_ms = 100_000,
        .scope = try std.testing.allocator.dupe(u8, "openid"),
        .token_type = try std.testing.allocator.dupe(u8, "Bearer"),
    };
    defer session.deinit(std.testing.allocator);
    try std.testing.expect(session.expired(50_000));
    try std.testing.expect(!session.expired(1));
    try std.testing.expect(session.expired(std.math.maxInt(i64)));
}

const DeleteSyncProbe = struct {
    sync_count: usize = 0,
    fail: bool = false,

    fn syncDir(raw_ctx: ?*anyopaque, _: std.Io.Dir) anyerror!void {
        const self: *DeleteSyncProbe = @ptrCast(@alignCast(raw_ctx.?));
        self.sync_count += 1;
        if (self.fail) return error.InjectedSyncFailure;
    }
};

test "OAuth session deletion reports deleted and missing files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.testing.io, auth_file_name, .{});
    file.close(std.testing.io);

    var probe: DeleteSyncProbe = .{};
    const ops = io_mod.DurableOps{
        .ctx = &probe,
        .sync_dir = DeleteSyncProbe.syncDir,
    };
    const deleted = try deleteAuthFile(&tmp.dir, ops);
    try std.testing.expectEqual(DeleteOutcome.deleted, deleted);
    try std.testing.expectEqual(@as(usize, 1), probe.sync_count);
    const missing = try deleteAuthFile(&tmp.dir, ops);
    try std.testing.expectEqual(DeleteOutcome.missing, missing);
    try std.testing.expectEqual(@as(usize, 1), probe.sync_count);
}

test "OAuth session deletion reports directory sync failure after unlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile(std.testing.io, auth_file_name, .{});
    file.close(std.testing.io);

    var probe = DeleteSyncProbe{ .fail = true };
    const ops = io_mod.DurableOps{
        .ctx = &probe,
        .sync_dir = DeleteSyncProbe.syncDir,
    };
    const outcome = try deleteAuthFile(&tmp.dir, ops);
    try std.testing.expectEqual(DeleteOutcome.deleted_not_durable, outcome);
    try std.testing.expectEqual(@as(usize, 1), probe.sync_count);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, auth_file_name, .{}),
    );

    probe.fail = false;
    const missing = try deleteAuthFile(&tmp.dir, ops);
    try std.testing.expectEqual(DeleteOutcome.missing, missing);
    try std.testing.expectEqual(@as(usize, 1), probe.sync_count);
}

test "OAuth session mutation lock serializes independent handles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try lockMutationWithOps(
        .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }) },
        0,
        .{},
    );
    defer first.deinit();

    try std.testing.expectError(
        error.LockBusy,
        lockMutationWithOps(
            .{ .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }) },
            0,
            .{},
        ),
    );
}

test "oauth E2E issuer override accepts loopback HTTP only" {
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:43123",
        try selectIssuerUrl("http://127.0.0.1:43123"),
    );
    try std.testing.expectEqualStrings(
        "http://localhost:43123",
        try selectIssuerUrl("http://localhost:43123"),
    );
    try std.testing.expectError(
        error.InvalidE2EOAuthIssuer,
        selectIssuerUrl("https://example.com"),
    );
    try std.testing.expectError(
        error.InvalidE2EOAuthIssuer,
        selectIssuerUrl("http://127.0.0.1:43123@evil.example"),
    );
    try validateE2EEndpoint(
        "http://127.0.0.1:43123",
        "http://localhost:43123/oauth/token",
    );
    try std.testing.expectError(
        error.InvalidE2EOAuthEndpoint,
        validateE2EEndpoint("http://127.0.0.1:43123", "https://example.com/oauth/token"),
    );
}
