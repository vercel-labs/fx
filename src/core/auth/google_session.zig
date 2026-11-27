//! Multi-account saved login store for Google AI Pro or Ultra plan OAuth + DPoP.
//!
//! Why `subscription_session.Store` is not used directly (`RULES.md` R6.5):
//! `subscription_session.Store` hardcodes a single-account profile-file JSON
//! schema and millisecond deadlines, whereas Google plan logins store a
//! multi-account map keyed by `sub` with DPoP keys and nonces, use second
//! deadlines, and live in the macOS Keychain (`FX_GOOGLE_SESSION_V1`) when
//! enabled with a private `google-auth.json` fallback. This module reuses
//! `leased_lock`, `session_presence`, `io_mod.durableReplaceVerified`, and
//! `subscription_session.openExistingPrivateFxDir`.
//!
//! Concurrency follows Design A (`tests/tla/gemini_auth/GeminiDpopRefresh.tla`):
//! `beginMutation` takes `google-auth.lock` and reads the saved record inside
//! the lock; writes write tokens, DPoP key, and nonce in one atomic write; and
//! `signOutOnDevice` takes the same lock.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const native_keychain = @import("../hosts/native_keychain.zig");
const io_mod = @import("../shared/io.zig");
const json_decode = @import("../shared/json_decode.zig");
const leased_lock = @import("../shared/leased_lock.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const testing_allocator = @import("../shared/testing_allocator.zig");
const types = @import("../shared/types.zig");
const dpop = @import("dpop.zig");
const google_refresh = @import("google_refresh.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const session_presence = @import("session_presence.zig");
const subscription_session = @import("subscription_session.zig");

const Allocator = std.mem.Allocator;

pub const auth_file_name = profile_paths.google_auth_file_name;
pub const lock_file_name = "google-auth.lock";
pub const schema_version: i64 = 1;
pub const max_record_bytes: usize = 256 * 1024;
pub const max_accounts: usize = 16;
const max_field_bytes: usize = 8 * 1024;
const max_scopes_per_account: usize = 32;

const mutation_step_ms: i64 = @max(native_keychain.keychain_call_ms, oauth_transport.default_request_timeout_ms);
const mutation_lock_wait_ms: i64 = mutation_step_ms + leased_lock.slack_ms;

pub const DeleteOutcome = subscription_session.DeleteOutcome;

pub const ParseError = error{
    InvalidGoogleSession,
    GoogleSessionTooLarge,
    GoogleSessionTooManyAccounts,
    OutOfMemory,
};

pub const AccountInput = struct {
    subject: []const u8,
    email: []const u8,
    client_id: []const u8,
    refresh_token: []const u8,
    refresh_token_expires_at_s: i64,
    access_token: []const u8,
    access_token_expires_at_s: i64,
    dpop_private_key: []const u8,
    dpop_nonce: ?[]const u8 = null,
    granted_scopes: []const []const u8,
};

pub const Account = struct {
    subject: []u8,
    email: []u8,
    client_id: []u8,
    refresh_token: []u8,
    refresh_token_expires_at_s: i64,
    access_token: []u8,
    access_token_expires_at_s: i64,
    dpop_private_key: []u8,
    dpop_nonce: ?[]u8 = null,
    granted_scopes: [][]u8,

    /// The caller owns the returned `Account` and frees it with `deinit`.
    pub fn init(alloc: Allocator, input: AccountInput) Allocator.Error!Account {
        const subject = try alloc.dupe(u8, input.subject);
        errdefer alloc.free(subject);
        const email = try alloc.dupe(u8, input.email);
        errdefer alloc.free(email);
        const client_id = try alloc.dupe(u8, input.client_id);
        errdefer alloc.free(client_id);
        const refresh_token = try alloc.dupe(u8, input.refresh_token);
        errdefer secret.zeroAndFree(alloc, refresh_token);
        const access_token = try alloc.dupe(u8, input.access_token);
        errdefer secret.zeroAndFree(alloc, access_token);
        const dpop_private_key = try alloc.dupe(u8, input.dpop_private_key);
        errdefer secret.zeroAndFree(alloc, dpop_private_key);
        const dpop_nonce = if (input.dpop_nonce) |nonce| try alloc.dupe(u8, nonce) else null;
        errdefer if (dpop_nonce) |nonce| secret.zeroAndFree(alloc, nonce);

        const scopes = try alloc.alloc([]u8, input.granted_scopes.len);
        var initialized_scopes: usize = 0;
        errdefer {
            for (scopes[0..initialized_scopes]) |scope| alloc.free(scope);
            alloc.free(scopes);
        }
        for (input.granted_scopes, 0..) |scope, i| {
            scopes[i] = try alloc.dupe(u8, scope);
            initialized_scopes += 1;
        }

        return .{
            .subject = subject,
            .email = email,
            .client_id = client_id,
            .refresh_token = refresh_token,
            .refresh_token_expires_at_s = input.refresh_token_expires_at_s,
            .access_token = access_token,
            .access_token_expires_at_s = input.access_token_expires_at_s,
            .dpop_private_key = dpop_private_key,
            .dpop_nonce = dpop_nonce,
            .granted_scopes = scopes,
        };
    }

    /// The caller owns the returned `Account` and frees it with `deinit`.
    pub fn clone(self: Account, alloc: Allocator) Allocator.Error!Account {
        return init(alloc, self.asInput());
    }

    fn asInput(self: Account) AccountInput {
        return .{
            .subject = self.subject,
            .email = self.email,
            .client_id = self.client_id,
            .refresh_token = self.refresh_token,
            .refresh_token_expires_at_s = self.refresh_token_expires_at_s,
            .access_token = self.access_token,
            .access_token_expires_at_s = self.access_token_expires_at_s,
            .dpop_private_key = self.dpop_private_key,
            .dpop_nonce = self.dpop_nonce,
            .granted_scopes = self.granted_scopes,
        };
    }

    pub fn deinit(self: *Account, alloc: Allocator) void {
        alloc.free(self.subject);
        alloc.free(self.email);
        alloc.free(self.client_id);
        secret.zeroAndFree(alloc, self.refresh_token);
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.dpop_private_key);
        if (self.dpop_nonce) |nonce| secret.zeroAndFree(alloc, nonce);
        for (self.granted_scopes) |scope| alloc.free(scope);
        alloc.free(self.granted_scopes);
        self.* = undefined;
    }

    pub fn asSavedAccess(self: Account) google_refresh.SavedAccess {
        return .{
            .access_token = self.access_token,
            .access_token_expires_at_s = self.access_token_expires_at_s,
            .refresh_token_expires_at_s = self.refresh_token_expires_at_s,
        };
    }
};

pub const Record = struct {
    schema_version: i64 = schema_version,
    active_account_sub: ?[]u8 = null,
    accounts: std.ArrayList(Account) = .empty,

    pub fn deinit(self: *Record, alloc: Allocator) void {
        if (self.active_account_sub) |sub| alloc.free(sub);
        for (self.accounts.items) |*account| account.deinit(alloc);
        self.accounts.deinit(alloc);
        self.* = undefined;
    }

    /// The caller owns the returned `Record` and frees it with `deinit`.
    pub fn clone(self: *const Record, alloc: Allocator) Allocator.Error!Record {
        var copy: Record = .{ .schema_version = self.schema_version };
        errdefer copy.deinit(alloc);
        if (self.active_account_sub) |sub| {
            copy.active_account_sub = try alloc.dupe(u8, sub);
        }
        try copy.accounts.ensureTotalCapacity(alloc, self.accounts.items.len);
        for (self.accounts.items) |account| {
            copy.accounts.appendAssumeCapacity(try account.clone(alloc));
        }
        return copy;
    }

    /// Borrowed from `self` until `self` is mutated or deinited.
    pub fn findAccount(self: *const Record, sub: []const u8) ?*const Account {
        const index = self.findIndex(sub) orelse return null;
        return &self.accounts.items[index];
    }

    /// Borrowed from `self` until `self` is mutated or deinited.
    pub fn activeAccount(self: *const Record) ?*const Account {
        const sub = self.active_account_sub orelse return null;
        return self.findAccount(sub);
    }

    /// Moves the active account out of `self`; caller owns it and calls `deinit`.
    pub fn takeActiveAccount(self: *Record, alloc: Allocator) ?Account {
        const sub = self.active_account_sub orelse return null;
        const index = self.findIndex(sub) orelse return null;
        const account = self.accounts.orderedRemove(index);
        alloc.free(sub);
        self.active_account_sub = null;
        return account;
    }

    pub fn upsertAccount(self: *Record, alloc: Allocator, input: AccountInput, set_active: bool) !void {
        try validateAccountInput(input);
        var replacement = try Account.init(alloc, input);
        errdefer replacement.deinit(alloc);

        const existing_index = self.findIndex(input.subject);
        if (existing_index == null) {
            if (self.accounts.items.len >= max_accounts) return error.GoogleSessionTooManyAccounts;
            try self.accounts.ensureUnusedCapacity(alloc, 1);
        }
        if (set_active or self.active_account_sub == null) {
            try setActiveSub(self, alloc, input.subject);
        }
        if (existing_index) |index| {
            var old = self.accounts.items[index];
            self.accounts.items[index] = replacement;
            old.deinit(alloc);
        } else {
            self.accounts.appendAssumeCapacity(replacement);
        }
    }

    pub fn removeAccount(self: *Record, alloc: Allocator, sub: []const u8) Allocator.Error!bool {
        const index = self.findIndex(sub) orelse return false;
        const was_active = if (self.active_account_sub) |active| std.mem.eql(u8, active, sub) else false;
        var removed = self.accounts.orderedRemove(index);
        removed.deinit(alloc);

        if (was_active) {
            if (self.active_account_sub) |active| alloc.free(active);
            self.active_account_sub = null;
            if (self.accounts.items.len > 0) {
                self.active_account_sub = try alloc.dupe(u8, self.accounts.items[0].subject);
            }
        }
        return true;
    }

    fn findIndex(self: *const Record, sub: []const u8) ?usize {
        for (self.accounts.items, 0..) |account, i| {
            if (std.mem.eql(u8, account.subject, sub)) return i;
        }
        return null;
    }
};

fn setActiveSub(record: *Record, alloc: Allocator, sub: []const u8) Allocator.Error!void {
    const duped = try alloc.dupe(u8, sub);
    if (record.active_account_sub) |old| alloc.free(old);
    record.active_account_sub = duped;
}

const StorageBackend = enum {
    profile_file,
    macos_keychain,
};

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
    return native_keychain.loadGoogleSession(alloc);
}

fn nativeKeychainStore(_: ?*anyopaque, value: []const u8) KeychainError!void {
    return native_keychain.storeGoogleSession(value);
}

fn nativeKeychainDelete(_: ?*anyopaque, alloc: Allocator) KeychainError!bool {
    return native_keychain.deleteGoogleSession(alloc);
}

fn selectStorageBackend(os_tag: std.Target.Os.Tag, keychain_disabled: bool) StorageBackend {
    if (os_tag == .macos and !keychain_disabled) return .macos_keychain;
    return .profile_file;
}

fn storageBackend() StorageBackend {
    // A temporary HOME does not isolate the host account's macOS Keychain.
    // Keychain-specific tests inject their backend explicitly.
    if (comptime host_target.is_wasm) return .profile_file;
    if (comptime builtin.is_test) return .profile_file;
    return selectStorageBackend(builtin.target.os.tag, native_keychain.isDisabled());
}

pub fn presence() host.SecretStorePresence {
    if (comptime host_target.is_wasm) return .missing;
    return switch (storageBackend()) {
        .macos_keychain => native_keychain.googleSessionPresence() catch .unavailable,
        .profile_file => session_presence.profileFile(auth_file_name, max_record_bytes),
    };
}

pub fn requireSignInStorage() error{CredentialStorageUnavailable}!void {
    if (comptime host_target.is_wasm) return;
    const check_file = switch (storageBackend()) {
        .macos_keychain => blk: {
            const available = native_keychain.googleSessionPresence() catch return error.CredentialStorageUnavailable;
            if (available == .unavailable) return error.CredentialStorageUnavailable;
            break :blk lock_file_name;
        },
        .profile_file => auth_file_name,
    };
    _ = try session_presence.requireWritableProfileFile(check_file, lock_file_name);
}

pub const Mutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,
    stamp_ms: i64,
    backend: StorageBackend,
    keychain: KeychainBackend,
    /// Record loaded inside `google-auth.lock` when the mutation opened, or null if absent.
    record: ?Record = null,

    pub fn restamp(self: *Mutation) void {
        self.stamp_ms = leased_lock.restamp(self.lock.file, "auth", "Google login");
    }

    pub fn deinit(self: *Mutation, alloc: Allocator) void {
        if (self.record) |*record| record.deinit(alloc);
        debug_trace.logf("auth", "Google login lock released stamp={d} at={d}", .{ self.stamp_ms, io_mod.awakeMilliTimestamp() });
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    /// Writes `record` (tokens, DPoP key, and nonce) in one atomic write.
    pub fn save(self: *Mutation, alloc: Allocator, record: Record) !void {
        const text = try stringify(alloc, record);
        defer secret.zeroAndFree(alloc, text);
        switch (self.backend) {
            .macos_keychain => try publishAndVerifyKeychain(alloc, self.stamped(), text),
            .profile_file => try io_mod.durableReplaceVerified(alloc, &self.fx_dir, auth_file_name, text),
        }
    }

    pub fn delete(self: *Mutation, alloc: Allocator) !DeleteOutcome {
        switch (self.backend) {
            .macos_keychain => {
                const deleted = try self.stamped().delete(alloc);
                return if (deleted) .deleted else .missing;
            },
            .profile_file => {
                self.fx_dir.dir.deleteFile(io_mod.getIo(), auth_file_name) catch |err| switch (err) {
                    error.FileNotFound => return .missing,
                    else => return err,
                };
                io_mod.syncVerifiedDir(self.fx_dir.dir) catch return .deleted_not_durable;
                return .deleted;
            },
        }
    }

    fn stamped(self: *Mutation) KeychainBackend {
        return .{
            .context = self,
            .load_fn = stampedLoad,
            .store_fn = stampedStore,
            .delete_fn = stampedDelete,
        };
    }

    fn stampedLoad(context: ?*anyopaque, alloc: Allocator) KeychainError!?[]u8 {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        self.restamp();
        return self.keychain.load(alloc);
    }

    fn stampedStore(context: ?*anyopaque, value: []const u8) KeychainError!void {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        self.restamp();
        return self.keychain.store(value);
    }

    fn stampedDelete(context: ?*anyopaque, alloc: Allocator) KeychainError!bool {
        const self: *Mutation = @ptrCast(@alignCast(context.?));
        self.restamp();
        return self.keychain.delete(alloc);
    }
};

/// Loads the saved multi-account record, or null when no login is stored.
/// Caller owns the returned `Record` and frees it with `deinit`.
pub fn load(alloc: Allocator) !?Record {
    if (comptime host_target.is_wasm) return null;
    return switch (storageBackend()) {
        .macos_keychain => loadKeychain(alloc, native_keychain_backend),
        .profile_file => loadProfileFile(alloc),
    };
}

fn loadProfileFile(alloc: Allocator) !?Record {
    const home = io_mod.homeDir() orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true }) catch |err| {
        debug_trace.logf("auth", "Google session load failed step=open_home err={s}", .{@errorName(err)});
        if (err == error.FileNotFound) return null;
        return session_presence.storageError(auth_file_name, err);
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.rootName(), .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        if (err != error.FileNotFound) {
            debug_trace.logf("auth", "Google session load failed step=open_profile err={s}", .{@errorName(err)});
        }
        if (err == error.FileNotFound) return null;
        return session_presence.storageError(auth_file_name, err);
    };
    defer fx_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &fx_dir);
}

/// Loads only the active account for a request, zeroing and freeing any other
/// accounts in memory. Caller owns the returned `Account` and frees it with `deinit`.
pub fn loadActiveAccount(alloc: Allocator) !?Account {
    var record = (try load(alloc)) orelse return null;
    defer record.deinit(alloc);
    return record.takeActiveAccount(alloc);
}

fn openPrivateFxDir(create: bool) !?io_mod.VerifiedDir {
    const home = io_mod.homeDir() orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true }) catch |err| {
            return session_presence.storageError(auth_file_name, err);
        },
    };
    defer home_dir.close();

    if (create) {
        return io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.rootName()) catch |err| {
            return session_presence.storageError(auth_file_name, err);
        };
    }
    return subscription_session.openExistingPrivateFxDir(&home_dir) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return session_presence.storageError(auth_file_name, err),
    };
}

/// Acquires `google-auth.lock`, reads the saved record inside the lock
/// (`tests/tla/gemini_auth/GeminiDpopRefresh.tla`), and returns a `Mutation`
/// holding both. Caller frees with `deinit`.
pub fn beginMutation(alloc: Allocator) !Mutation {
    if (comptime host_target.is_wasm) return error.CredentialStorageUnavailable;
    const fx_dir = (try openPrivateFxDir(true)).?;
    return lockAndReadMutation(alloc, fx_dir, mutation_lock_wait_ms, .{}, storageBackend(), native_keychain_backend);
}

/// Like `beginMutation`, except on profile-file storage it returns null without
/// creating `~/.fx` when the profile folder does not exist yet.
pub fn beginExistingMutation(alloc: Allocator) !?Mutation {
    if (comptime host_target.is_wasm) return null;
    const backend = storageBackend();
    const fx_dir = (try openPrivateFxDir(backend == .macos_keychain)) orelse return null;
    return try lockAndReadMutation(alloc, fx_dir, mutation_lock_wait_ms, .{}, backend, native_keychain_backend);
}

/// Removes `sub` from the saved Google accounts under `google-auth.lock`,
/// deleting the entire store item or file when no account remains.
pub fn signOutOnDevice(alloc: Allocator, sub: []const u8) !bool {
    var mutation = (try beginExistingMutation(alloc)) orelse return false;
    defer mutation.deinit(alloc);
    const record = &(mutation.record orelse return false);
    if (!(try record.removeAccount(alloc, sub))) return false;
    if (record.accounts.items.len == 0) {
        _ = try mutation.delete(alloc);
        return true;
    }
    try mutation.save(alloc, record.*);
    return true;
}

fn lockMutation(
    open_fx_dir: io_mod.VerifiedDir,
    wait_ms: i64,
    ops: io_mod.LockOps,
    backend: StorageBackend,
    keychain: KeychainBackend,
) !Mutation {
    var fx_dir = open_fx_dir;
    errdefer fx_dir.close();

    const taken = leased_lock.acquire(
        &fx_dir,
        lock_file_name,
        io_mod.awakeMilliTimestamp(),
        wait_ms,
        ops,
        "auth",
        "Google login",
    ) catch |err| return session_presence.storageError(auth_file_name, err);

    return .{
        .fx_dir = fx_dir,
        .lock = taken.lock,
        .stamp_ms = taken.stamp_ms,
        .backend = backend,
        .keychain = keychain,
        .record = null,
    };
}

fn lockAndReadMutation(
    alloc: Allocator,
    open_fx_dir: io_mod.VerifiedDir,
    wait_ms: i64,
    ops: io_mod.LockOps,
    backend: StorageBackend,
    keychain: KeychainBackend,
) !Mutation {
    var mutation = try lockMutation(open_fx_dir, wait_ms, ops, backend, keychain);
    errdefer mutation.deinit(alloc);

    mutation.record = switch (backend) {
        .profile_file => try loadFromDir(alloc, &mutation.fx_dir.dir),
        .macos_keychain => try loadFromKeychain(alloc, mutation.stamped()),
    };
    return mutation;
}

fn loadKeychain(alloc: Allocator, keychain: KeychainBackend) !?Record {
    const home = io_mod.homeDir() orelse return loadFromKeychain(alloc, keychain);
    var home_dir = io_mod.VerifiedDir{
        .dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return loadFromKeychain(alloc, keychain);
            return session_presence.storageError(auth_file_name, err);
        },
    };
    defer home_dir.close();

    const fx_dir = subscription_session.openExistingPrivateFxDir(&home_dir) catch |err| switch (err) {
        error.FileNotFound => return loadFromKeychain(alloc, keychain),
        else => return session_presence.storageError(auth_file_name, err),
    };
    var mutation = lockAndReadMutation(alloc, fx_dir, 0, .{}, .macos_keychain, keychain) catch |err| {
        if (err == error.LockBusy) {
            debug_trace.logf("auth", "Google session load read without lock reason=lock_busy", .{});
            return loadFromKeychain(alloc, keychain);
        }
        return err;
    };
    defer mutation.deinit(alloc);
    const record = mutation.record;
    mutation.record = null;
    return record;
}

fn loadFromKeychain(alloc: Allocator, keychain: KeychainBackend) !?Record {
    const maybe_bytes = keychain.load(alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.KeychainItemNotFound => return null,
        else => return err,
    };
    const bytes = maybe_bytes orelse return null;
    defer secret.zeroAndFree(alloc, bytes);
    return try parseLoaded(alloc, "keychain", bytes);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir) !?Record {
    var current = (session_presence.openCurrent(fx_dir.*, auth_file_name) catch |err| {
        debug_trace.logf("auth", "Google session load failed step=open_file err={s}", .{@errorName(err)});
        return session_presence.storageError(auth_file_name, err);
    }) orelse return null;
    defer current.file.close(io_mod.getIo());

    const stat = current.stat;
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "Google session load failed step=permissions err=InsecureAuthFile", .{});
        return error.InsecureAuthFile;
    }

    const bytes = io_mod.readFileToEnd(alloc, &current.file, max_record_bytes + 1) catch |err| switch (err) {
        error.StreamTooLong => return error.GoogleSessionTooLarge,
        else => return session_presence.storageError(auth_file_name, err),
    };
    defer secret.zeroAndFree(alloc, bytes);
    return try parseLoaded(alloc, "file", bytes);
}

fn parseLoaded(alloc: Allocator, source: []const u8, bytes: []const u8) !Record {
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            debug_trace.logf("auth", "Google session load failed source={s} step=parse err={s}", .{ source, @errorName(err) });
            return err;
        },
    };
}

fn publishAndVerifyKeychain(alloc: Allocator, keychain: KeychainBackend, bytes: []const u8) !void {
    try keychain.store(bytes);
    const persisted = keychain.load(alloc) catch |err| switch (err) {
        error.KeychainItemNotFound => return error.GoogleSessionKeychainWriteMismatch,
        else => return err,
    } orelse return error.GoogleSessionKeychainWriteMismatch;
    defer secret.zeroAndFree(alloc, persisted);
    if (!std.mem.eql(u8, bytes, persisted)) return error.GoogleSessionKeychainWriteMismatch;
}

const JsonRecord = struct {
    schema_version: i64,
    active_account_sub: []const u8,
    accounts: std.json.ArrayHashMap(AccountInput),
};

/// Parses a versioned Google session JSON record (`bytes`). Caller owns the
/// returned `Record` and frees it with `deinit`.
pub fn parse(alloc: Allocator, bytes: []const u8) ParseError!Record {
    if (bytes.len == 0) return error.InvalidGoogleSession;
    if (bytes.len > max_record_bytes) return error.GoogleSessionTooLarge;

    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();

    const parsed = json_decode.parseFromSliceLeaky(JsonRecord, arena.allocator(), bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGoogleSession,
    };
    defer zeroParsedSecrets(bytes, parsed);

    if (parsed.schema_version != schema_version) return error.InvalidGoogleSession;
    const count = parsed.accounts.map.count();
    if (count == 0) return error.InvalidGoogleSession;
    if (count > max_accounts) return error.GoogleSessionTooManyAccounts;
    if (!validSubject(parsed.active_account_sub)) return error.InvalidGoogleSession;

    var record: Record = .{
        .schema_version = schema_version,
        .active_account_sub = try alloc.dupe(u8, parsed.active_account_sub),
    };
    errdefer record.deinit(alloc);

    try record.accounts.ensureTotalCapacity(alloc, count);
    var it = parsed.accounts.map.iterator();
    while (it.next()) |entry| {
        const input = entry.value_ptr.*;
        if (!std.mem.eql(u8, entry.key_ptr.*, input.subject)) return error.InvalidGoogleSession;
        try validateAccountInput(input);
        record.accounts.appendAssumeCapacity(try Account.init(alloc, input));
    }

    if (record.findAccount(record.active_account_sub.?) == null) return error.InvalidGoogleSession;
    return record;
}

/// Serializes `record` to JSON. Caller owns the returned slice and must zero
/// and free it with `secret.zeroAndFree`.
pub fn stringify(alloc: Allocator, record: Record) ParseError![]u8 {
    if (record.schema_version != schema_version) return error.InvalidGoogleSession;
    if (record.accounts.items.len == 0) return error.InvalidGoogleSession;
    if (record.accounts.items.len > max_accounts) return error.GoogleSessionTooManyAccounts;

    const active_sub = record.active_account_sub orelse return error.InvalidGoogleSession;
    if (!validSubject(active_sub)) return error.InvalidGoogleSession;
    if (record.findAccount(active_sub) == null) return error.InvalidGoogleSession;

    for (record.accounts.items, 0..) |account, i| {
        try validateAccountInput(account.asInput());
        for (record.accounts.items[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.subject, account.subject)) return error.InvalidGoogleSession;
        }
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer {
        std.crypto.secureZero(u8, out.writer.buffer);
        out.deinit();
    }

    writeRecordJson(&out.writer, active_sub, record.accounts.items) catch return error.OutOfMemory;
    if (out.written().len > max_record_bytes) return error.GoogleSessionTooLarge;
    return out.toOwnedSlice();
}

fn writeRecordJson(writer: *std.Io.Writer, active_sub: []const u8, accounts: []const Account) std.Io.Writer.Error!void {
    try writer.writeAll("{\"schema_version\":1,\"active_account_sub\":");
    try std.json.Stringify.value(active_sub, .{}, writer);
    try writer.writeAll(",\"accounts\":{");
    for (accounts, 0..) |account, i| {
        if (i > 0) try writer.writeByte(',');
        try std.json.Stringify.value(account.subject, .{}, writer);
        try writer.writeByte(':');
        try std.json.Stringify.value(account.asInput(), .{ .emit_null_optional_fields = false }, writer);
    }
    try writer.writeAll("}}\n");
}

fn zeroParsedSecrets(source_bytes: []const u8, parsed: JsonRecord) void {
    var it = parsed.accounts.map.iterator();
    while (it.next()) |entry| {
        const value = entry.value_ptr.*;
        zeroArenaSlice(source_bytes, value.refresh_token);
        zeroArenaSlice(source_bytes, value.access_token);
        zeroArenaSlice(source_bytes, value.dpop_private_key);
        if (value.dpop_nonce) |nonce| zeroArenaSlice(source_bytes, nonce);
    }
}

fn zeroArenaSlice(source_bytes: []const u8, slice: []const u8) void {
    if (slice.len == 0) return;
    const src_start = @intFromPtr(source_bytes.ptr);
    const src_end = src_start + source_bytes.len;
    const slice_start = @intFromPtr(slice.ptr);
    if (slice_start >= src_start and slice_start < src_end) return;
    std.crypto.secureZero(u8, @constCast(slice));
}

fn validateAccountInput(input: AccountInput) ParseError!void {
    if (!validSubject(input.subject)) return error.InvalidGoogleSession;
    if (!validTextField(input.email)) return error.InvalidGoogleSession;
    if (!validTextField(input.client_id)) return error.InvalidGoogleSession;
    if (!validTextField(input.refresh_token)) return error.InvalidGoogleSession;
    if (!validTextField(input.access_token)) return error.InvalidGoogleSession;
    if (input.dpop_nonce) |nonce| {
        if (!validTextField(nonce)) return error.InvalidGoogleSession;
    }
    _ = dpop.decodeSecretKey(input.dpop_private_key) catch return error.InvalidGoogleSession;
    if (input.granted_scopes.len > max_scopes_per_account) return error.InvalidGoogleSession;
    for (input.granted_scopes) |scope| {
        if (!validScope(scope)) return error.InvalidGoogleSession;
    }
}

fn validSubject(value: []const u8) bool {
    return types.validCredentialAccountId(value);
}

fn validTextField(value: []const u8) bool {
    if (value.len == 0 or value.len > max_field_bytes) return false;
    if (!std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn validScope(value: []const u8) bool {
    if (value.len == 0 or value.len > max_field_bytes) return false;
    for (value) |byte| {
        if (byte <= 0x20 or byte >= 0x7f) return false;
    }
    return true;
}

const testing = std.testing;

const TestEnv = struct {
    alloc: Allocator,
    tmp: testing.TmpDir,
    home: []u8,
    map: std.process.Environ.Map,

    fn create(alloc: Allocator) !*TestEnv {
        const self = try alloc.create(TestEnv);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.home = try io_mod.dirRealpathAlloc(alloc, self.tmp.dir, "");
        errdefer alloc.free(self.home);
        self.map = std.process.Environ.Map.init(alloc);
        errdefer self.map.deinit();
        try self.map.put("FX_DISABLE_KEYCHAIN", "1");
        try self.map.put("HOME", self.home);
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestEnv) void {
        io_mod.resetEnvironForTest();
        self.map.deinit();
        self.alloc.free(self.home);
        self.tmp.cleanup();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const FakeGoogleKeychain = struct {
    alloc: Allocator,
    value: ?[]u8 = null,
    load_calls: usize = 0,
    store_calls: usize = 0,
    delete_calls: usize = 0,

    fn backend(self: *FakeGoogleKeychain) KeychainBackend {
        return .{
            .context = self,
            .load_fn = loadCallback,
            .store_fn = storeCallback,
            .delete_fn = deleteCallback,
        };
    }

    fn deinit(self: *FakeGoogleKeychain) void {
        if (self.value) |v| secret.zeroAndFree(self.alloc, v);
        self.* = undefined;
    }

    fn loadCallback(raw: ?*anyopaque, alloc: Allocator) KeychainError!?[]u8 {
        const self: *FakeGoogleKeychain = @ptrCast(@alignCast(raw.?));
        self.load_calls += 1;
        const stored = self.value orelse return error.KeychainItemNotFound;
        return try alloc.dupe(u8, stored);
    }

    fn storeCallback(raw: ?*anyopaque, value: []const u8) KeychainError!void {
        const self: *FakeGoogleKeychain = @ptrCast(@alignCast(raw.?));
        self.store_calls += 1;
        const copy = try self.alloc.dupe(u8, value);
        if (self.value) |old| secret.zeroAndFree(self.alloc, old);
        self.value = copy;
    }

    fn deleteCallback(raw: ?*anyopaque, _: Allocator) KeychainError!bool {
        const self: *FakeGoogleKeychain = @ptrCast(@alignCast(raw.?));
        self.delete_calls += 1;
        const old = self.value orelse return false;
        secret.zeroAndFree(self.alloc, old);
        self.value = null;
        return true;
    }
};

fn testDpopKeyAlloc(alloc: Allocator, fill: u8) ![]u8 {
    const seed: [dpop.seed_bytes]u8 = @splat(fill);
    const kp = try dpop.keyPairFromSeed(seed);
    return dpop.encodeSecretKeyAlloc(alloc, kp);
}

fn testAccountInput(sub: []const u8, email: []const u8, key: []const u8, nonce: ?[]const u8) AccountInput {
    return .{
        .subject = sub,
        .email = email,
        .client_id = "123456.apps.googleusercontent.com",
        .refresh_token = "1//refresh-token-value",
        .refresh_token_expires_at_s = 1_764_115_200,
        .access_token = "ya29.access-token-value",
        .access_token_expires_at_s = 1_763_514_000,
        .dpop_private_key = key,
        .dpop_nonce = nonce,
        .granted_scopes = &.{
            "openid",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/generative-language.peruserquota",
        },
    };
}

fn seedTestAccounts(alloc: Allocator, inputs: []const AccountInput, active_index: usize) !void {
    var mutation = try beginMutation(alloc);
    defer mutation.deinit(alloc);
    try testing.expect(mutation.record == null);

    var record: Record = .{};
    defer record.deinit(alloc);
    for (inputs, 0..) |input, i| {
        try record.upsertAccount(alloc, input, i == active_index);
    }
    try mutation.save(alloc, record);
}

test "Google session store round-trips two accounts and reads the active account" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc);
    defer env.deinit();

    try testing.expectEqual(host.SecretStorePresence.missing, presence());
    try testing.expect((try load(alloc)) == null);
    try testing.expect((try loadActiveAccount(alloc)) == null);

    const key1 = try testDpopKeyAlloc(alloc, 0x11);
    defer secret.zeroAndFree(alloc, key1);
    const key2 = try testDpopKeyAlloc(alloc, 0x22);
    defer secret.zeroAndFree(alloc, key2);

    try seedTestAccounts(alloc, &.{
        testAccountInput("sub-1", "one@example.com", key1, "nonce-1"),
        .{
            .subject = "sub-2",
            .email = "two@example.com",
            .client_id = "123456.apps.googleusercontent.com",
            .refresh_token = "1//refresh-2",
            .refresh_token_expires_at_s = 1_764_200_000,
            .access_token = "ya29.access-2",
            .access_token_expires_at_s = 1_763_600_000,
            .dpop_private_key = key2,
            .dpop_nonce = null,
            .granted_scopes = &.{"openid"},
        },
    }, 1);

    try testing.expectEqual(host.SecretStorePresence.present, presence());
    const stat = try env.tmp.dir.statFile(testing.io, ".fx/" ++ auth_file_name, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);

    var loaded = (try load(alloc)) orelse return error.TestUnexpectedMissingGoogleSession;
    defer loaded.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), loaded.accounts.items.len);
    try testing.expectEqualStrings("sub-2", loaded.active_account_sub.?);

    const first = loaded.findAccount("sub-1").?;
    try testing.expectEqualStrings("one@example.com", first.email);
    try testing.expectEqualStrings("nonce-1", first.dpop_nonce.?);
    try testing.expectEqualStrings(key1, first.dpop_private_key);
    try testing.expectEqual(@as(usize, 3), first.granted_scopes.len);

    var active = (try loadActiveAccount(alloc)) orelse return error.TestUnexpectedMissingGoogleSession;
    defer active.deinit(alloc);
    try testing.expectEqualStrings("sub-2", active.subject);
    try testing.expectEqualStrings("ya29.access-2", active.access_token);
    try testing.expect(active.dpop_nonce == null);
}

test "Google session signOutOnDevice deletes one account and keeps the other, then deletes the file when empty" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc);
    defer env.deinit();

    const key1 = try testDpopKeyAlloc(alloc, 0x31);
    defer secret.zeroAndFree(alloc, key1);
    const key2 = try testDpopKeyAlloc(alloc, 0x32);
    defer secret.zeroAndFree(alloc, key2);

    try seedTestAccounts(alloc, &.{
        testAccountInput("sub-a", "a@example.com", key1, null),
        testAccountInput("sub-b", "b@example.com", key2, "n-b"),
    }, 0);

    try testing.expect(!(try signOutOnDevice(alloc, "missing-sub")));
    try testing.expect(try signOutOnDevice(alloc, "sub-a"));

    {
        var loaded = (try load(alloc)) orelse return error.TestUnexpectedMissingGoogleSession;
        defer loaded.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), loaded.accounts.items.len);
        try testing.expectEqualStrings("sub-b", loaded.active_account_sub.?);
        try testing.expect(loaded.findAccount("sub-a") == null);
    }

    try testing.expect(try signOutOnDevice(alloc, "sub-b"));
    try testing.expect((try load(alloc)) == null);
    try testing.expectEqual(host.SecretStorePresence.missing, presence());
    try testing.expectError(error.FileNotFound, env.tmp.dir.statFile(testing.io, ".fx/" ++ auth_file_name, .{}));
}

test "Google session rejects damaged records with a clear error" {
    const alloc = testing.allocator;
    const valid_key = try testDpopKeyAlloc(alloc, 0x44);
    defer secret.zeroAndFree(alloc, valid_key);

    try testing.expectError(error.InvalidGoogleSession, parse(alloc, ""));
    try testing.expectError(error.InvalidGoogleSession, parse(alloc, "not json"));
    try testing.expectError(error.InvalidGoogleSession, parse(alloc, "{\"schema_version\":2,\"active_account_sub\":\"s\",\"accounts\":{}}"));
    try testing.expectError(error.InvalidGoogleSession, parse(alloc, "{\"schema_version\":1,\"active_account_sub\":\"s\",\"accounts\":{}}"));

    const mismatch = try alloc.print(
        "{{\"schema_version\":1,\"active_account_sub\":\"sub-1\",\"accounts\":{{\"sub-1\":{{\"subject\":\"sub-2\",\"email\":\"a@example.com\",\"client_id\":\"c\",\"refresh_token\":\"r\",\"refresh_token_expires_at_s\":10,\"access_token\":\"a\",\"access_token_expires_at_s\":5,\"dpop_private_key\":\"{s}\",\"granted_scopes\":[]}}}}}}",
        .{valid_key},
    );
    defer alloc.free(mismatch);
    try testing.expectError(error.InvalidGoogleSession, parse(alloc, mismatch));

    const bad_dpop =
        \\{"schema_version":1,"active_account_sub":"sub-1","accounts":{"sub-1":{"subject":"sub-1","email":"a@example.com","client_id":"c","refresh_token":"r","refresh_token_expires_at_s":10,"access_token":"a","access_token_expires_at_s":5,"dpop_private_key":"not-a-valid-key","granted_scopes":[]}}}
    ;
    try testing.expectError(error.InvalidGoogleSession, parse(alloc, bad_dpop));

    const missing_active = try alloc.print(
        "{{\"schema_version\":1,\"active_account_sub\":\"sub-other\",\"accounts\":{{\"sub-1\":{{\"subject\":\"sub-1\",\"email\":\"a@example.com\",\"client_id\":\"c\",\"refresh_token\":\"r\",\"refresh_token_expires_at_s\":10,\"access_token\":\"a\",\"access_token_expires_at_s\":5,\"dpop_private_key\":\"{s}\",\"granted_scopes\":[]}}}}}}",
        .{valid_key},
    );
    defer alloc.free(missing_active);
    try testing.expectError(error.InvalidGoogleSession, parse(alloc, missing_active));
}

test "Google session enforces record byte and account count caps" {
    const alloc = testing.allocator;
    const key = try testDpopKeyAlloc(alloc, 0x55);
    defer secret.zeroAndFree(alloc, key);

    const oversized = try alloc.alloc(u8, max_record_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, ' ');
    try testing.expectError(error.GoogleSessionTooLarge, parse(alloc, oversized));

    var record: Record = .{};
    defer record.deinit(alloc);
    for (0..max_accounts) |i| {
        const sub = try alloc.print("sub-{d}", .{i});
        defer alloc.free(sub);
        try record.upsertAccount(alloc, testAccountInput(sub, "u@example.com", key, null), i == 0);
    }
    try testing.expectError(
        error.GoogleSessionTooManyAccounts,
        record.upsertAccount(alloc, testAccountInput("sub-extra", "u@example.com", key, null), false),
    );
}

test "Google session lock is held during reads and writes and serializes handles" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var first = try lockAndReadMutation(
        alloc,
        .{ .dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true }) },
        0,
        .{},
        .profile_file,
        native_keychain_backend,
    );
    defer first.deinit(alloc);

    try testing.expectError(
        error.LockBusy,
        lockAndReadMutation(
            alloc,
            .{ .dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true }) },
            0,
            .{},
            .profile_file,
            native_keychain_backend,
        ),
    );

    const Probe = struct {
        fake: FakeGoogleKeychain,
        dir: std.Io.Dir,
        stamps: std.ArrayList(i64) = .empty,
        lock_held_on_calls: bool = true,

        fn backend(self: *@This()) KeychainBackend {
            return .{
                .context = self,
                .load_fn = probeLoad,
                .store_fn = probeStore,
                .delete_fn = probeDelete,
            };
        }

        fn checkLockAndRecordStamp(self: *@This()) void {
            var dir: io_mod.VerifiedDir = .{ .dir = self.dir };
            if (io_mod.acquireTimedAdvisoryLockWithOps(&dir, lock_file_name, 0, .{})) |unexpected| {
                var lock = unexpected;
                lock.release();
                self.lock_held_on_calls = false;
            } else |err| {
                if (err != error.LockBusy) self.lock_held_on_calls = false;
            }
            const stamp = leased_lock.readStamp(&dir, lock_file_name) orelse return;
            self.stamps.append(testing.allocator, stamp) catch return;
            io_mod.sleep(3 * std.time.ns_per_ms);
        }

        fn probeLoad(raw: ?*anyopaque, a: Allocator) KeychainError!?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.checkLockAndRecordStamp();
            return FakeGoogleKeychain.loadCallback(&self.fake, a);
        }

        fn probeStore(raw: ?*anyopaque, value: []const u8) KeychainError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.checkLockAndRecordStamp();
            return FakeGoogleKeychain.storeCallback(&self.fake, value);
        }

        fn probeDelete(raw: ?*anyopaque, a: Allocator) KeychainError!bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.checkLockAndRecordStamp();
            return FakeGoogleKeychain.deleteCallback(&self.fake, a);
        }
    };

    var probe_dir = try tmp.dir.openDir(testing.io, ".", .{ .iterate = true });
    defer probe_dir.close(testing.io);
    try probe_dir.createDirPath(testing.io, "kc");
    var probe: Probe = .{
        .fake = .{ .alloc = alloc },
        .dir = try probe_dir.openDir(testing.io, "kc", .{ .iterate = true }),
    };
    defer probe.dir.close(testing.io);
    defer probe.fake.deinit();
    defer probe.stamps.deinit(alloc);

    const key = try testDpopKeyAlloc(alloc, 0x66);
    defer secret.zeroAndFree(alloc, key);

    var kc_mutation = try lockAndReadMutation(
        alloc,
        .{ .dir = try probe.dir.openDir(testing.io, ".", .{ .iterate = true }) },
        0,
        .{},
        .macos_keychain,
        probe.backend(),
    );
    defer kc_mutation.deinit(alloc);
    try testing.expect(kc_mutation.record == null);

    var record: Record = .{};
    defer record.deinit(alloc);
    try record.upsertAccount(alloc, testAccountInput("sub-kc", "kc@example.com", key, "n-kc"), true);
    try kc_mutation.save(alloc, record);

    try testing.expect(probe.lock_held_on_calls);
    // 1 load during beginMutation + 1 store + 1 verify load during save = 3 stamped calls.
    try testing.expectEqual(@as(usize, 3), probe.stamps.items.len);
    try testing.expect(probe.stamps.items[1] > probe.stamps.items[0]);
    try testing.expect(probe.stamps.items[2] > probe.stamps.items[1]);
}

test "Google session damaged load errors and traces never include secrets" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc);
    defer env.deinit();

    const trace_path = try std.Io.Dir.path.join(alloc, &.{ env.home, "trace.log" });
    defer alloc.free(trace_path);
    try debug_trace.configure(.{ .file_path = trace_path });
    defer debug_trace.shutdown();

    try env.tmp.dir.createDirPath(testing.io, ".fx");
    const secrets = [_][]const u8{
        "secret_refresh_token_canary_991",
        "secret_access_token_canary_992",
        "secret_dpop_key_canary_993",
        "secret_dpop_nonce_canary_994",
    };
    const damaged = try alloc.print(
        "{{\"schema_version\":1,\"active_account_sub\":\"sub-1\",\"accounts\":{{\"sub-1\":{{\"subject\":\"sub-1\",\"email\":\"a@example.com\",\"client_id\":\"c\",\"refresh_token\":\"{s}\",\"refresh_token_expires_at_s\":10,\"access_token\":\"{s}\",\"access_token_expires_at_s\":5,\"dpop_private_key\":\"{s}\",\"dpop_nonce\":\"{s}\",\"granted_scopes\":[]}}}}}}",
        .{ secrets[0], secrets[1], secrets[2], secrets[3] },
    );
    defer alloc.free(damaged);
    try env.tmp.dir.writeFile(testing.io, .{
        .sub_path = ".fx/" ++ auth_file_name,
        .data = damaged,
        .flags = .{ .permissions = .fromMode(0o600) },
    });

    const err_result = load(alloc);
    try testing.expectError(error.InvalidGoogleSession, err_result);
    var trace_file = try env.tmp.dir.openFile(testing.io, "trace.log", .{ .mode = .read_only });
    defer trace_file.close(testing.io);
    const trace_bytes = try io_mod.readFileToEnd(alloc, &trace_file, 64 * 1024);
    defer alloc.free(trace_bytes);
    if (err_result) |_| unreachable else |err| {
        const err_name = @errorName(err);
        for (secrets) |canary| {
            try testing.expect(std.mem.find(u8, err_name, canary) == null);
            try testing.expect(std.mem.find(u8, trace_bytes, canary) == null);
        }
    }
}

test "Google session beginMutation and beginExistingMutation return InvalidGoogleSession on damaged file without double-closing" {
    const alloc = testing.allocator;
    const env = try TestEnv.create(alloc);
    defer env.deinit();

    {
        var init_mutation = try beginMutation(alloc);
        init_mutation.deinit(alloc);
    }
    try env.tmp.dir.writeFile(testing.io, .{
        .sub_path = ".fx/" ++ auth_file_name,
        .data = "{\"schema_version\":1}\n",
        .flags = .{ .permissions = .fromMode(0o600) },
    });

    try testing.expectError(error.InvalidGoogleSession, beginExistingMutation(alloc));
    try testing.expectError(error.InvalidGoogleSession, beginMutation(alloc));
}

test "Google session backend selection uses Keychain on macOS only when enabled" {
    try testing.expectEqual(StorageBackend.macos_keychain, selectStorageBackend(.macos, false));
    try testing.expectEqual(StorageBackend.profile_file, selectStorageBackend(.macos, true));
    try testing.expectEqual(StorageBackend.profile_file, selectStorageBackend(.linux, false));
    try testing.expectEqual(StorageBackend.profile_file, selectStorageBackend(.linux, true));
}

test "Google session parse cleans up allocation failures" {
    try testing.checkAllAllocationFailures(testing_allocator.no_resize, checkParseAllocationFailures, .{});
}

fn checkParseAllocationFailures(alloc: Allocator) !void {
    const sample =
        \\{"schema_version":1,"active_account_sub":"1076915035","accounts":{"1076915035":{"subject":"1076915035","email":"developer@example.com","client_id":"client-1","refresh_token":"1//r1","refresh_token_expires_at_s":1764115200,"access_token":"ya29.a1","access_token_expires_at_s":1763514000,"dpop_private_key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE","dpop_nonce":"n1","granted_scopes":["openid"]}}}
    ;
    var record = try parse(alloc, sample);
    record.deinit(alloc);
}

fn fuzzRecord(_: void, smith: *testing.Smith) !void {
    var buffer: [8192]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const alloc = testing.allocator;

    var record = parse(alloc, buffer[0..len]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidGoogleSession, error.GoogleSessionTooLarge, error.GoogleSessionTooManyAccounts => return,
    };
    defer record.deinit(alloc);

    try testing.expect(record.accounts.items.len >= 1 and record.accounts.items.len <= max_accounts);
    try testing.expect(record.activeAccount() != null);

    const text = try stringify(alloc, record);
    defer secret.zeroAndFree(alloc, text);
    try testing.expect(text.len <= max_record_bytes);

    var again = try parse(alloc, text);
    defer again.deinit(alloc);
    try testing.expectEqual(record.schema_version, again.schema_version);
    try testing.expectEqualStrings(record.active_account_sub.?, again.active_account_sub.?);
    try testing.expectEqual(record.accounts.items.len, again.accounts.items.len);
    for (record.accounts.items, again.accounts.items) |want, got| {
        try testing.expectEqualStrings(want.subject, got.subject);
        try testing.expectEqualStrings(want.email, got.email);
        try testing.expectEqualStrings(want.client_id, got.client_id);
        try testing.expectEqualStrings(want.refresh_token, got.refresh_token);
        try testing.expectEqual(want.refresh_token_expires_at_s, got.refresh_token_expires_at_s);
        try testing.expectEqualStrings(want.access_token, got.access_token);
        try testing.expectEqual(want.access_token_expires_at_s, got.access_token_expires_at_s);
        try testing.expectEqualStrings(want.dpop_private_key, got.dpop_private_key);
        try testing.expectEqual(want.dpop_nonce != null, got.dpop_nonce != null);
        if (want.dpop_nonce) |wn| try testing.expectEqualStrings(wn, got.dpop_nonce.?);
        try testing.expectEqual(want.granted_scopes.len, got.granted_scopes.len);
        for (want.granted_scopes, got.granted_scopes) |ws, gs| {
            try testing.expectEqualStrings(ws, gs);
        }
    }
}

test "a Google session record parses or is refused on fuzzed bytes, and what parses writes back the same" {
    try testing.fuzz({}, fuzzRecord, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "{}",
            "{\"schema_version\":2,\"active_account_sub\":\"1\",\"accounts\":{}}",
            "{\"schema_version\":1,\"active_account_sub\":\"1\",\"accounts\":{\"1\":{\"subject\":\"1\",\"email\":\"u@example.com\",\"client_id\":\"c\",\"refresh_token\":\"r\",\"refresh_token_expires_at_s\":10,\"access_token\":\"a\",\"access_token_expires_at_s\":5,\"dpop_private_key\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAE\",\"granted_scopes\":[]}}}",
            "{\"schema_version\":1,\"active_account_sub\":\"1\",\"accounts\":{\"1\":{\"subject\":\"1\",\"email\":\"u@example.com\",\"client_id\":\"c\",\"refresh_token\":\"r\",\"refresh_token_expires_at_s\":10,\"access_token\":\"a\",\"access_token_expires_at_s\":5,\"dpop_private_key\":\"bad\",\"granted_scopes\":[\"openid\"]}}}",
        }) ++ @import("fuzz_corpus").google_session_parse.*),
    });
}
