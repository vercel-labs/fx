//! Sign-outs that a provider did not confirm, kept so that fx can revoke
//! their tokens later.
//!
//! A logout keeps the tokens here before it sends the revocation and forgets
//! them once the provider confirms it, so a refused, unanswered, or
//! interrupted revocation leaves them kept. The next `fx login` or
//! `fx logout` for the same provider sends them again (`retry`), and so does
//! every TUI start, on a worker. A sign-out kept longer than `max_age_ms` is
//! dropped without a request.
//!
//! Codex and Grok keep theirs in a private file in the profile folder, next to
//! their logins. The fx login keeps its in the macOS Keychain when its login is
//! there, with a marker file that holds no token, so that a start with nothing
//! kept reads no Keychain item; otherwise in a private profile file. Each
//! source's record changes only under its own lock file, which is held for one
//! read and one write but never across a request to the provider.
//!
//! The fx that sends a sign-out leases it for as long as that can take, so
//! another fx's retry at the same time does not send it again. A lease whose
//! process is gone, killed during the request, no longer holds it back.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const native_keychain = @import("../hosts/native_keychain.zig");
const io_mod = @import("../shared/io.zig");
const leased_lock = @import("../shared/leased_lock.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const oauth = @import("oauth.zig");
const oauth_session = @import("oauth_session.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const session_presence = @import("session_presence.zig");
const subscription_session = @import("subscription_session.zig");

const Allocator = std.mem.Allocator;

pub const Source = enum {
    codex,
    grok,
    fx_login,

    fn files(self: Source) Files {
        return switch (self) {
            .codex => .{ .record = "chatgpt-revocations.json", .lock = "chatgpt-revocations.lock", .label = "Codex kept sign-outs" },
            .grok => .{ .record = "grok-revocations.json", .lock = "grok-revocations.lock", .label = "Grok kept sign-outs" },
            .fx_login => .{ .record = "auth-revocations.json", .lock = "auth-revocations.lock", .label = "fx login kept sign-outs" },
        };
    }
};

const Files = struct {
    record: []const u8,
    lock: []const u8,
    /// Names the lock in debug trace lines.
    label: []const u8,
};

/// The fx login's marker file while its record is in the Keychain.
const keychain_marker = "auth-revocations.keychain";

/// How long a sign-out stays kept. Its tokens have most likely expired at the
/// provider by then.
pub const max_age_ms: i64 = 30 * std.time.ms_per_day;
/// The most sign-outs kept for one source. Keeping one more drops the oldest.
pub const max_entries: usize = 8;
/// One sign-out always fits: its four fields, each escaped six bytes for one
/// at most, take under 100 KiB.
pub const max_record_bytes: usize = 128 * 1024;
const max_field_bytes: usize = 4 * 1024;
const schema_version: i64 = 1;
/// The lock is held for one read and one write, a Keychain call at most each,
/// and its holder stamps it before each (`leased_lock`).
const lock_wait_ms: i64 = native_keychain.keychain_call_ms + leased_lock.slack_ms;

/// The tokens of one sign-out. Borrowed.
pub const Tokens = struct {
    /// Identifies the sign-out.
    refresh_token: []const u8,
    /// The fx login's access token, issuer, and client id. Empty for Codex
    /// and Grok.
    access_token: []const u8 = "",
    issuer: []const u8 = "",
    client_id: []const u8 = "",

    fn valid(self: Tokens) bool {
        if (self.refresh_token.len == 0) return false;
        inline for (.{ "refresh_token", "access_token", "issuer", "client_id" }) |name| {
            if (@field(self, name).len > max_field_bytes) return false;
        }
        return true;
    }
};

/// The fx that is sending a sign-out now, until `until_ms` on the wall clock.
const Lease = struct {
    pid: i64,
    until_ms: i64,

    /// A lease for this process, for as long as sending one sign-out of
    /// `source` can take.
    fn mine(source: Source, now_ms: i64) Lease {
        return .{ .pid = processId(), .until_ms = now_ms +| sendBudgetMs(source) };
    }
};

/// How long sending one sign-out can take: each of its requests within the
/// transport's limit, plus the lock's slack. The fx login asks for its
/// issuer's endpoints, then revokes two tokens (`login_flow.revokeTokens`).
fn sendBudgetMs(source: Source) i64 {
    const requests: i64 = if (source == .fx_login) 3 else 1;
    return requests * oauth_transport.default_request_timeout_ms + leased_lock.slack_ms;
}

fn processId() i64 {
    if (comptime host_target.is_wasm or builtin.target.os.tag == .windows) return 0;
    return std.c.getpid();
}

fn processAlive(pid: i64) bool {
    if (comptime host_target.is_wasm or builtin.target.os.tag == .windows) return false;
    if (pid <= 0 or pid > std.math.maxInt(std.posix.pid_t)) return false;
    std.posix.kill(@intCast(pid), @fromBackingInt(@intCast(0))) catch |err| return switch (err) {
        error.ProcessNotFound => false,
        else => true,
    };
    return true;
}

/// One kept sign-out. Every field is owned; release it with `deinit`.
const Entry = struct {
    saved_at_ms: i64,
    refresh_token: []u8,
    access_token: []u8,
    issuer: []u8,
    client_id: []u8,
    /// Who is sending it now, when anyone is.
    lease: ?Lease = null,

    fn clone(self: Entry, alloc: Allocator) !Entry {
        var copy = try init(alloc, self.saved_at_ms, self.asTokens());
        copy.lease = self.lease;
        return copy;
    }

    /// Whether a live fx, this one included, is sending it now.
    fn beingSent(self: Entry, now_ms: i64) bool {
        const lease = self.lease orelse return false;
        return lease.until_ms > now_ms and processAlive(lease.pid);
    }

    fn init(alloc: Allocator, saved_at_ms: i64, tokens: Tokens) !Entry {
        const refresh_token = try alloc.dupe(u8, tokens.refresh_token);
        errdefer secret.zeroAndFree(alloc, refresh_token);
        const access_token = try alloc.dupe(u8, tokens.access_token);
        errdefer secret.zeroAndFree(alloc, access_token);
        const issuer = try alloc.dupe(u8, tokens.issuer);
        errdefer alloc.free(issuer);
        const client_id = try alloc.dupe(u8, tokens.client_id);
        return .{
            .saved_at_ms = saved_at_ms,
            .refresh_token = refresh_token,
            .access_token = access_token,
            .issuer = issuer,
            .client_id = client_id,
        };
    }

    fn deinit(self: *Entry, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.refresh_token);
        secret.zeroAndFree(alloc, self.access_token);
        alloc.free(self.issuer);
        alloc.free(self.client_id);
        self.* = undefined;
    }

    fn asTokens(self: Entry) Tokens {
        return .{
            .refresh_token = self.refresh_token,
            .access_token = self.access_token,
            .issuer = self.issuer,
            .client_id = self.client_id,
        };
    }
};

/// The kept sign-outs of one source, oldest first.
const List = struct {
    entries: std.ArrayList(Entry) = .empty,

    fn deinit(self: *List, alloc: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(alloc);
        self.entries.deinit(alloc);
        self.* = undefined;
    }

    fn find(self: List, refresh_token: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.refresh_token, refresh_token)) return index;
        }
        return null;
    }

    fn removeAt(self: *List, alloc: Allocator, index: usize) void {
        var removed = self.entries.orderedRemove(index);
        removed.deinit(alloc);
    }

    /// Drops every sign-out kept longer than `max_age_ms` and returns whether
    /// the list changed. A saved time after `now_ms`, from a clock that was
    /// set back, becomes `now_ms`, so that sign-out still expires.
    fn expire(self: *List, alloc: Allocator, source: Source, now_ms: i64) bool {
        var changed = false;
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = &self.entries.items[index];
            if (entry.saved_at_ms > now_ms) {
                entry.saved_at_ms = now_ms;
                changed = true;
            }
            const age_ms = now_ms -| entry.saved_at_ms;
            if (age_ms > max_age_ms) {
                debug_trace.logf("auth", "kept sign-out dropped reason=expired source={t} age_ms={d}", .{ source, age_ms });
                self.removeAt(alloc, index);
                changed = true;
                continue;
            }
            index += 1;
        }
        return changed;
    }

    /// Adds a sign-out unless its refresh token is already kept, with
    /// `lease` when its sender is about to send it. Past `max_entries`,
    /// drops the oldest.
    fn add(self: *List, alloc: Allocator, source: Source, tokens: Tokens, now_ms: i64, lease: ?Lease) !void {
        if (self.find(tokens.refresh_token)) |index| {
            if (lease != null) self.entries.items[index].lease = lease;
            return;
        }
        var entry = try Entry.init(alloc, now_ms, tokens);
        errdefer entry.deinit(alloc);
        entry.lease = lease;
        try self.entries.append(alloc, entry);
        while (self.entries.items.len > max_entries) {
            debug_trace.logf("auth", "kept sign-out dropped reason=limit source={t} limit={d}", .{ source, max_entries });
            self.removeAt(alloc, 0);
        }
    }

    fn remove(self: *List, alloc: Allocator, refresh_token: []const u8) bool {
        const index = self.find(refresh_token) orelse return false;
        self.removeAt(alloc, index);
        return true;
    }
};

/// Reads a record that `stringify` wrote. A sign-out whose refresh token came
/// earlier is skipped, and past `max_entries` the oldest are dropped.
fn parse(alloc: Allocator, bytes: []const u8) !List {
    if (bytes.len > max_record_bytes) return error.InvalidKeptSignOuts;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidKeptSignOuts,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidKeptSignOuts;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidKeptSignOuts;
    if (version != .integer or version.integer != schema_version) return error.InvalidKeptSignOuts;
    const entries = object.get("entries") orelse return error.InvalidKeptSignOuts;
    if (entries != .array) return error.InvalidKeptSignOuts;

    var list: List = .{};
    errdefer list.deinit(alloc);
    for (entries.array.items) |item| {
        if (item != .object) return error.InvalidKeptSignOuts;
        const saved_at = item.object.get("saved_at_ms") orelse return error.InvalidKeptSignOuts;
        if (saved_at != .integer) return error.InvalidKeptSignOuts;
        const tokens: Tokens = .{
            .refresh_token = try field(item.object, "refresh_token", .required),
            .access_token = try field(item.object, "access_token", .optional),
            .issuer = try field(item.object, "issuer", .optional),
            .client_id = try field(item.object, "client_id", .optional),
        };
        if (!tokens.valid()) return error.InvalidKeptSignOuts;
        const pid = try integerField(item.object, "sender_pid");
        const until_ms = try integerField(item.object, "sending_until_ms");
        if (list.find(tokens.refresh_token) != null) continue;
        var entry = try Entry.init(alloc, saved_at.integer, tokens);
        errdefer entry.deinit(alloc);
        if (pid != 0) entry.lease = .{ .pid = pid, .until_ms = until_ms };
        try list.entries.append(alloc, entry);
    }
    while (list.entries.items.len > max_entries) list.removeAt(alloc, 0);
    return list;
}

/// An optional integer field, 0 when it is absent.
fn integerField(object: std.json.ObjectMap, name: []const u8) !i64 {
    const value = object.get(name) orelse return 0;
    if (value != .integer) return error.InvalidKeptSignOuts;
    return value.integer;
}

fn field(object: std.json.ObjectMap, name: []const u8, presence: enum { required, optional }) ![]const u8 {
    const value = object.get(name) orelse return if (presence == .required) error.InvalidKeptSignOuts else "";
    if (value != .string) return error.InvalidKeptSignOuts;
    return value.string;
}

/// The record's text. The caller owns it and releases it with
/// `secret.zeroAndFree`.
fn stringify(alloc: Allocator, list: List) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{{\"version\":{d},\"entries\":[", .{schema_version});
    for (list.entries.items, 0..) |entry, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.print("{{\"saved_at_ms\":{d},\"refresh_token\":", .{entry.saved_at_ms});
        try std.json.Stringify.value(entry.refresh_token, .{}, &out.writer);
        inline for (.{ "access_token", "issuer", "client_id" }) |name| {
            const value = @field(entry, name);
            if (value.len != 0) {
                try out.writer.writeAll(",\"" ++ name ++ "\":");
                try std.json.Stringify.value(value, .{}, &out.writer);
            }
        }
        if (entry.lease) |lease| {
            try out.writer.print(",\"sender_pid\":{d},\"sending_until_ms\":{d}", .{ lease.pid, lease.until_ms });
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeAll("]}\n");
    return out.toOwnedSlice();
}

/// The record's text, after dropping the oldest sign-outs until it fits
/// `max_record_bytes`. One sign-out always fits (`Tokens.valid`).
fn fittedText(alloc: Allocator, source: Source, list: *List) ![]u8 {
    while (true) {
        const text = try stringify(alloc, list.*);
        if (text.len <= max_record_bytes or list.entries.items.len <= 1) return text;
        secret.zeroAndFree(alloc, text);
        debug_trace.logf("auth", "kept sign-out dropped reason=size source={t} limit={d}", .{ source, max_record_bytes });
        list.removeAt(alloc, 0);
    }
}

/// Holds the fx login's record in the Keychain.
const KeychainBackend = struct {
    context: ?*anyopaque = null,
    /// Null when there is no item.
    load_fn: *const fn (?*anyopaque, Allocator) anyerror!?[]u8,
    store_fn: *const fn (?*anyopaque, []const u8) anyerror!void,
    delete_fn: *const fn (?*anyopaque, Allocator) anyerror!void,
};

const native_keychain_backend: KeychainBackend = .{
    .load_fn = nativeKeychainLoad,
    .store_fn = nativeKeychainStore,
    .delete_fn = nativeKeychainDelete,
};

fn nativeKeychainLoad(_: ?*anyopaque, alloc: Allocator) anyerror!?[]u8 {
    return native_keychain.loadOAuthPendingRevocations(alloc) catch |err| switch (err) {
        error.KeychainItemNotFound => null,
        else => err,
    };
}

fn nativeKeychainStore(_: ?*anyopaque, value: []const u8) anyerror!void {
    return native_keychain.storeOAuthPendingRevocations(value);
}

fn nativeKeychainDelete(_: ?*anyopaque, alloc: Allocator) anyerror!void {
    _ = try native_keychain.deleteOAuthPendingRevocations(alloc);
}

/// Where a source's record is.
const Place = struct {
    source: Source,
    /// Set for the fx login when its login is in the Keychain.
    keychain: ?KeychainBackend = null,
    /// The folder that holds the profile folder: the home folder, unless a
    /// test sets it.
    parent: ?std.Io.Dir = null,

    fn of(source: Source) Place {
        const in_keychain = source == .fx_login and oauth_session.storesInKeychain();
        return .{ .source = source, .keychain = if (in_keychain) native_keychain_backend else null };
    }

    /// The profile folder, or null when there is none and `create` is false.
    fn openProfile(self: Place, create: bool) !?io_mod.VerifiedDir {
        if (comptime host_target.is_wasm) return null;
        var opened: ?std.Io.Dir = null;
        defer if (opened) |dir| dir.close(io_mod.getIo());
        const parent = self.parent orelse blk: {
            const home = io_mod.homeDir() orelse return null;
            opened = std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(home), .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => return err,
            };
            break :blk opened.?;
        };
        if (create) return try io_mod.openOrCreateVerifiedPrivateDirFromDir(parent, profile_paths.rootName());
        var verified_parent: io_mod.VerifiedDir = .{ .dir = parent };
        return subscription_session.openExistingPrivateFxDir(&verified_parent) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    /// Whether a record seems to exist, checked without the lock: a record
    /// that another fx writes at the same time waits for the next retry.
    fn recordExists(self: Place) !bool {
        var fx_dir = (try self.openProfile(false)) orelse return false;
        defer fx_dir.close();
        const name = if (self.keychain != null) keychain_marker else self.source.files().record;
        var current = (try session_presence.openCurrent(fx_dir.dir, name)) orelse return false;
        current.file.close(io_mod.getIo());
        return true;
    }
};

/// A source's record, read and written under its lock.
const Mutation = struct {
    place: Place,
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,
    /// The lease's last stamp, on the awake clock.
    stamp_ms: i64,
    /// Set by `load` when it dropped a record it could not read.
    dropped_unreadable: bool = false,

    fn begin(place: Place, create: bool) !?Mutation {
        var fx_dir = (try place.openProfile(create)) orelse return null;
        errdefer fx_dir.close();
        const files = place.source.files();
        const taken = try leased_lock.acquire(&fx_dir, files.lock, io_mod.awakeMilliTimestamp(), lock_wait_ms, .{}, "auth", files.label);
        return .{ .place = place, .fx_dir = fx_dir, .lock = taken.lock, .stamp_ms = taken.stamp_ms };
    }

    fn deinit(self: *Mutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    /// Stamps the lease again before a Keychain call.
    fn restamp(self: *Mutation) void {
        self.stamp_ms = leased_lock.restamp(self.lock.file, "auth", self.place.source.files().label);
    }

    /// The kept sign-outs. A record that is unsafe or does not parse can never
    /// be revoked from, so it is dropped with a trace line; a record that
    /// cannot be read now returns the error, so nothing overwrites it.
    fn load(self: *Mutation, alloc: Allocator) !List {
        const bytes = (self.readRecord(alloc) catch |err| switch (err) {
            error.InsecureKeptSignOuts, error.StreamTooLong => return self.dropUnreadable(err),
            else => return err,
        }) orelse return .{};
        defer secret.zeroAndFree(alloc, bytes);
        return parse(alloc, bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return self.dropUnreadable(err),
        };
    }

    fn dropUnreadable(self: *Mutation, err: anyerror) List {
        debug_trace.logf("auth", "kept sign-outs dropped reason=unreadable source={t} err={s}", .{ self.place.source, @errorName(err) });
        self.dropped_unreadable = true;
        return .{};
    }

    fn readRecord(self: *Mutation, alloc: Allocator) !?[]u8 {
        if (self.place.keychain) |keychain| {
            self.restamp();
            return keychain.load_fn(keychain.context, alloc);
        }
        var current = (try session_presence.openCurrent(self.fx_dir.dir, self.place.source.files().record)) orelse return null;
        defer current.file.close(io_mod.getIo());
        const stat = current.stat;
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) return error.InsecureKeptSignOuts;
        return try io_mod.readFileToEnd(alloc, &current.file, max_record_bytes + 1);
    }

    /// Writes `list`, or removes the record when it is empty.
    fn save(self: *Mutation, alloc: Allocator, list: *List) !void {
        if (list.entries.items.len == 0) return self.clear(alloc);
        const text = try fittedText(alloc, self.place.source, list);
        defer secret.zeroAndFree(alloc, text);
        if (self.place.keychain) |keychain| {
            self.restamp();
            try keychain.store_fn(keychain.context, text);
            try io_mod.durableReplaceVerified(alloc, &self.fx_dir, keychain_marker, "1\n");
            return;
        }
        try io_mod.durableReplaceVerified(alloc, &self.fx_dir, self.place.source.files().record, text);
    }

    fn clear(self: *Mutation, alloc: Allocator) !void {
        if (self.place.keychain) |keychain| {
            self.restamp();
            try keychain.delete_fn(keychain.context, alloc);
            return self.deleteFile(keychain_marker);
        }
        try self.deleteFile(self.place.source.files().record);
    }

    fn deleteFile(self: *Mutation, name: []const u8) !void {
        self.fx_dir.dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        const durable: io_mod.DurableOps = .{};
        durable.sync_dir(durable.ctx, self.fx_dir.dir) catch |err| {
            debug_trace.logf("auth", "kept sign-outs removal not durable source={t} err={s}", .{ self.place.source, @errorName(err) });
        };
    }
};

/// Keeps a sign-out's tokens before its revocation is sent, leased to this
/// process while it sends them. Returns whether they were kept; when they
/// were not, the debug trace says why.
pub fn keep(alloc: Allocator, source: Source, tokens: Tokens) bool {
    const now_ms = io_mod.milliTimestamp();
    keepAt(alloc, .of(source), tokens, now_ms, .mine(source, now_ms)) catch |err| {
        debug_trace.logf("auth", "sign-out not kept source={t} err={s}", .{ source, @errorName(err) });
        return false;
    };
    return true;
}

fn keepAt(alloc: Allocator, place: Place, tokens: Tokens, now_ms: i64, lease: ?Lease) !void {
    if (!tokens.valid()) return error.InvalidKeptSignOut;
    var mutation = (try Mutation.begin(place, true)) orelse return error.KeptSignOutsUnavailable;
    defer mutation.deinit();
    var list = try mutation.load(alloc);
    defer list.deinit(alloc);
    _ = list.expire(alloc, place.source, now_ms);
    try list.add(alloc, place.source, tokens, now_ms, lease);
    try mutation.save(alloc, &list);
}

/// Forgets a kept sign-out once its provider confirmed the revocation, or
/// when its login turned out not to be removed. A sign-out that cannot be
/// forgotten stays kept, and a later retry revokes it again, which is
/// harmless.
pub fn forget(alloc: Allocator, source: Source, refresh_token: []const u8) void {
    forgetAt(alloc, .of(source), refresh_token) catch |err| {
        debug_trace.logf("auth", "kept sign-out not forgotten source={t} err={s}", .{ source, @errorName(err) });
    };
}

fn forgetAt(alloc: Allocator, place: Place, refresh_token: []const u8) !void {
    var mutation = (try Mutation.begin(place, false)) orelse return;
    defer mutation.deinit();
    var list = try mutation.load(alloc);
    defer list.deinit(alloc);
    if (!list.remove(alloc, refresh_token) and !mutation.dropped_unreadable) return;
    try mutation.save(alloc, &list);
}

/// Whether a failed revocation could succeed later. One that never can, such
/// as an issuer without a revocation endpoint, is not kept: a retry would only
/// repeat the request.
pub fn retryable(err: anyerror) bool {
    return switch (err) {
        error.RevocationEndpointMissing,
        error.InvalidE2EOAuthEndpoint,
        error.InvalidE2EOAuthIssuer,
        error.KeptSignOutUnusable,
        => false,
        else => true,
    };
}

/// Revokes one kept sign-out at its provider. An error that is not
/// `retryable`, such as `error.KeptSignOutUnusable`, means it can never be
/// revoked, and `retry` drops it.
pub const Revoker = struct {
    context: *const anyopaque,
    run: *const fn (context: *const anyopaque, alloc: Allocator, tokens: Tokens) anyerror!void,
};

pub const RetryOutcome = struct {
    /// Sign-outs the provider confirmed.
    revoked: usize = 0,
    /// A revocation failed; it and the ones after it stay kept.
    failed: bool = false,
};

/// Revokes every sign-out kept for `source`, oldest first, and forgets each
/// one that its provider confirms. It leaves alone the ones another live fx
/// is sending, and leases the rest while it sends them. It stops at the first
/// failure, since the provider is likely down, and the rest wait for the next
/// retry. Runs `before` once, before the first request.
pub fn retry(alloc: Allocator, source: Source, revoker: Revoker, before: ?oauth.BeforeRevocation) RetryOutcome {
    return retryAt(alloc, .of(source), io_mod.milliTimestamp(), revoker, before) catch |err| {
        debug_trace.logf("auth", "kept sign-outs not retried source={t} err={s}", .{ source, @errorName(err) });
        return .{ .failed = true };
    };
}

fn retryAt(alloc: Allocator, place: Place, now_ms: i64, revoker: Revoker, before: ?oauth.BeforeRevocation) !RetryOutcome {
    if (!try place.recordExists()) return .{};
    var kept = blk: {
        var mutation = (try Mutation.begin(place, false)) orelse return .{};
        defer mutation.deinit();
        var list = try mutation.load(alloc);
        defer list.deinit(alloc);
        var changed = list.expire(alloc, place.source, now_ms) or mutation.dropped_unreadable;
        var claimed: List = .{};
        errdefer claimed.deinit(alloc);
        const lease: Lease = .mine(place.source, now_ms);
        for (list.entries.items) |*entry| {
            if (entry.beingSent(now_ms)) continue;
            entry.lease = lease;
            try claimed.entries.append(alloc, try entry.clone(alloc));
            changed = true;
        }
        if (changed) try mutation.save(alloc, &list);
        break :blk claimed;
    };
    defer kept.deinit(alloc);

    var outcome: RetryOutcome = .{};
    if (kept.entries.items.len == 0) return outcome;
    if (before) |notice| notice.run(notice.context);
    for (kept.entries.items) |entry| {
        revoker.run(revoker.context, alloc, entry.asTokens()) catch |err| switch (retryable(err)) {
            false => {
                debug_trace.logf("auth", "kept sign-out dropped reason=unusable source={t} err={s}", .{ place.source, @errorName(err) });
                forgetAt(alloc, place, entry.refresh_token) catch |forget_err| {
                    debug_trace.logf("auth", "kept sign-out not forgotten source={t} err={s}", .{ place.source, @errorName(forget_err) });
                };
                continue;
            },
            true => {
                debug_trace.logf("auth", "kept sign-out retry failed source={t} err={s}; it stays kept", .{ place.source, @errorName(err) });
                outcome.failed = true;
                break;
            },
        };
        outcome.revoked += 1;
        forgetAt(alloc, place, entry.refresh_token) catch |err| {
            debug_trace.logf("auth", "kept sign-out not forgotten source={t} err={s}", .{ place.source, @errorName(err) });
        };
    }
    return outcome;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const day_ms = std.time.ms_per_day;

fn testPlace(tmp: *testing.TmpDir, source: Source) Place {
    return .{ .source = source, .parent = tmp.dir };
}

/// The refresh tokens kept at `place`, oldest first. The caller frees the
/// outer slice and each token.
fn keptTokens(alloc: Allocator, place: Place) ![][]u8 {
    var mutation = (try Mutation.begin(place, false)) orelse return &.{};
    defer mutation.deinit();
    var list = try mutation.load(alloc);
    defer list.deinit(alloc);
    const out = try alloc.alloc([]u8, list.entries.items.len);
    for (list.entries.items, 0..) |entry, index| out[index] = try alloc.dupe(u8, entry.refresh_token);
    return out;
}

fn freeTokens(alloc: Allocator, tokens: [][]u8) void {
    for (tokens) |token| alloc.free(token);
    alloc.free(tokens);
}

fn expectKept(place: Place, expected: []const []const u8) !void {
    const alloc = testing.allocator;
    const kept = try keptTokens(alloc, place);
    defer freeTokens(alloc, kept);
    try testing.expectEqual(expected.len, kept.len);
    for (expected, kept) |want, got| try testing.expectEqualStrings(want, got);
}

/// A revoker that refuses the tokens in `refuse`, records the ones it was
/// sent, and runs `during` once, before its first answer, as another fx can.
const FakeRevoker = struct {
    refuse: []const []const u8 = &.{},
    unusable: []const []const u8 = &.{},
    sent: std.ArrayList([]u8) = .empty,
    during: ?*const fn (*FakeRevoker) anyerror!void = null,
    place: ?Place = null,

    fn revoker(self: *FakeRevoker) Revoker {
        return .{ .context = self, .run = run };
    }

    fn deinit(self: *FakeRevoker) void {
        for (self.sent.items) |token| testing.allocator.free(token);
        self.sent.deinit(testing.allocator);
    }

    fn run(context: *const anyopaque, alloc: Allocator, tokens: Tokens) anyerror!void {
        _ = alloc;
        const self: *FakeRevoker = @ptrCast(@alignCast(@constCast(context)));
        try self.sent.append(testing.allocator, try testing.allocator.dupe(u8, tokens.refresh_token));
        if (self.during) |during| {
            self.during = null;
            try during(self);
        }
        for (self.unusable) |token| if (std.mem.eql(u8, token, tokens.refresh_token)) return error.KeptSignOutUnusable;
        for (self.refuse) |token| if (std.mem.eql(u8, token, tokens.refresh_token)) return error.RevocationRefused;
    }
};

fn writeRecord(tmp: *testing.TmpDir, name: []const u8, bytes: []const u8, mode: u32) !void {
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, profile_paths.rootName());
    defer fx_dir.close();
    try io_mod.durableReplaceVerified(testing.allocator, &fx_dir, name, bytes);
    if (mode != 0o600) {
        var file = try fx_dir.dir.openFile(io_mod.getIo(), name, .{ .mode = .read_only });
        defer file.close(io_mod.getIo());
        try file.setPermissions(io_mod.getIo(), std.Io.File.Permissions.fromMode(@intCast(mode)));
    }
}

/// How many times `needle` occurs in the record file itself, before the
/// parser drops duplicates or old sign-outs.
fn countInRecord(tmp: *testing.TmpDir, name: []const u8, needle: []const u8) !usize {
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, profile_paths.rootName());
    defer fx_dir.close();
    var file = try fx_dir.dir.openFile(io_mod.getIo(), name, .{ .mode = .read_only });
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(testing.allocator, &file, max_record_bytes + 1);
    defer testing.allocator.free(bytes);
    return std.mem.count(u8, bytes, needle);
}

fn recordMode(tmp: *testing.TmpDir, name: []const u8) !?u32 {
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, profile_paths.rootName());
    defer fx_dir.close();
    var file = fx_dir.dir.openFile(io_mod.getIo(), name, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    return @intCast(stat.permissions.toMode() & 0o777);
}

test "a kept sign-out is a private record that a confirmed retry removes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .codex);
    try keepAt(testing.allocator, place, .{ .refresh_token = "refresh-1" }, 10 * day_ms, null);
    try testing.expectEqual(@as(?u32, 0o600), try recordMode(&tmp, "chatgpt-revocations.json"));
    try expectKept(place, &.{"refresh-1"});

    var fake: FakeRevoker = .{};
    defer fake.deinit();
    const outcome = try retryAt(testing.allocator, place, 10 * day_ms, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 1), outcome.revoked);
    try testing.expect(!outcome.failed);
    try testing.expectEqual(@as(usize, 1), fake.sent.items.len);
    try testing.expectEqualStrings("refresh-1", fake.sent.items[0]);
    try testing.expectEqual(@as(?u32, null), try recordMode(&tmp, "chatgpt-revocations.json"));
}

test "a refused retry keeps the sign-out and the ones after it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .grok);
    try keepAt(testing.allocator, place, .{ .refresh_token = "a" }, 1, null);
    try keepAt(testing.allocator, place, .{ .refresh_token = "b" }, 2, null);
    try keepAt(testing.allocator, place, .{ .refresh_token = "c" }, 3, null);

    var fake: FakeRevoker = .{ .refuse = &.{"b"} };
    defer fake.deinit();
    const outcome = try retryAt(testing.allocator, place, 4, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 1), outcome.revoked);
    try testing.expect(outcome.failed);
    // It stopped at the refusal: "c" was never sent.
    try testing.expectEqual(@as(usize, 2), fake.sent.items.len);
    try expectKept(place, &.{ "b", "c" });
}

test "a sign-out kept exactly 30 days is retried and one kept longer is dropped unsent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .codex);
    const now = 100 * day_ms;
    try keepAt(testing.allocator, place, .{ .refresh_token = "old" }, now - max_age_ms - 1, null);
    try keepAt(testing.allocator, place, .{ .refresh_token = "edge" }, now - max_age_ms, null);

    var fake: FakeRevoker = .{ .refuse = &.{"edge"} };
    defer fake.deinit();
    _ = try retryAt(testing.allocator, place, now, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 1), fake.sent.items.len);
    try testing.expectEqualStrings("edge", fake.sent.items[0]);
    try expectKept(place, &.{"edge"});
}

test "a saved time after now, from a clock set back, still expires 30 days later" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .codex);
    try keepAt(testing.allocator, place, .{ .refresh_token = "future" }, 500 * day_ms, null);

    var fake: FakeRevoker = .{ .refuse = &.{"future"} };
    defer fake.deinit();
    // The clock reads 400 days now: the sign-out counts from here.
    _ = try retryAt(testing.allocator, place, 400 * day_ms, fake.revoker(), null);
    try expectKept(place, &.{"future"});
    _ = try retryAt(testing.allocator, place, 430 * day_ms + 1, fake.revoker(), null);
    try expectKept(place, &.{});
    try testing.expectEqual(@as(usize, 1), fake.sent.items.len);
}

test "the same refresh token is kept once" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .codex);
    try keepAt(testing.allocator, place, .{ .refresh_token = "same" }, 1, null);
    try keepAt(testing.allocator, place, .{ .refresh_token = "same" }, 2, null);
    try expectKept(place, &.{"same"});
    try testing.expectEqual(@as(usize, 1), try countInRecord(&tmp, "chatgpt-revocations.json", "\"same\""));
}

test "keeping more sign-outs than the limit drops the oldest" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .grok);
    var names: [max_entries + 2][8]u8 = undefined;
    for (&names, 0..) |*name, index| {
        const text = try std.mem.print(name, "t{d:0>7}", .{index});
        try keepAt(testing.allocator, place, .{ .refresh_token = text }, @intCast(index), null);
    }
    const kept = try keptTokens(testing.allocator, place);
    defer freeTokens(testing.allocator, kept);
    try testing.expectEqual(max_entries, kept.len);
    try testing.expectEqualStrings("t0000002", kept[0]);
    try testing.expectEqualStrings("t0000009", kept[max_entries - 1]);
    try testing.expectEqual(max_entries, try countInRecord(&tmp, "grok-revocations.json", "\"refresh_token\""));
}

test "an empty, cut off, other-version, oversized, or shared record is dropped and replaced" {
    const cases = [_]struct { bytes: []const u8, mode: u32 }{
        .{ .bytes = "", .mode = 0o600 },
        .{ .bytes = "{\"version\":1,\"entries\":[{\"saved_at_ms\":1,\"refr", .mode = 0o600 },
        .{ .bytes = "{\"version\":2,\"entries\":[]}", .mode = 0o600 },
        .{ .bytes = "{\"version\":1,\"entries\":[{\"saved_at_ms\":1,\"refresh_token\":\"\"}]}", .mode = 0o600 },
        .{ .bytes = "{\"version\":1,\"entries\":[{\"saved_at_ms\":1,\"refresh_token\":\"x\"}]}", .mode = 0o644 },
    };
    for (cases) |case| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const place = testPlace(&tmp, .codex);
        try writeRecord(&tmp, "chatgpt-revocations.json", case.bytes, case.mode);
        try keepAt(testing.allocator, place, .{ .refresh_token = "new" }, 1, null);
        try expectKept(place, &.{"new"});
        try testing.expectEqual(@as(?u32, 0o600), try recordMode(&tmp, "chatgpt-revocations.json"));
    }

    // A record past the limit is too long to read.
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const big = try testing.allocator.alloc(u8, max_record_bytes + 2);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try writeRecord(&tmp, "chatgpt-revocations.json", big, 0o600);
    var fake: FakeRevoker = .{};
    defer fake.deinit();
    _ = try retryAt(testing.allocator, testPlace(&tmp, .codex), 1, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 0), fake.sent.items.len);
    try testing.expectEqual(@as(?u32, null), try recordMode(&tmp, "chatgpt-revocations.json"));
}

test "tokens that are empty or too long are not kept" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .fx_login);
    try testing.expectError(error.InvalidKeptSignOut, keepAt(testing.allocator, place, .{ .refresh_token = "" }, 1, null));
    const long = try testing.allocator.alloc(u8, max_field_bytes + 1);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    try testing.expectError(error.InvalidKeptSignOut, keepAt(testing.allocator, place, .{ .refresh_token = "r", .access_token = long }, 1, null));
    try testing.expectEqual(@as(?u32, null), try recordMode(&tmp, "auth-revocations.json"));
}

test "a sign-out its revoker calls unusable is dropped and the retry goes on" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .fx_login);
    try keepAt(testing.allocator, place, .{ .refresh_token = "broken" }, 1, null);
    try keepAt(testing.allocator, place, .{ .refresh_token = "fine", .access_token = "access", .issuer = "https://vercel.com", .client_id = "cl" }, 2, null);
    var fake: FakeRevoker = .{ .unusable = &.{"broken"} };
    defer fake.deinit();
    const outcome = try retryAt(testing.allocator, place, 3, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 1), outcome.revoked);
    try testing.expect(!outcome.failed);
    try expectKept(place, &.{});
}

test "the fx login's sign-out keeps its issuer, client id, and both tokens" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .fx_login);
    try keepAt(testing.allocator, place, .{ .refresh_token = "refresh", .access_token = "access", .issuer = "https://vercel.com", .client_id = "cl_1" }, 1, null);
    var mutation = (try Mutation.begin(place, false)).?;
    defer mutation.deinit();
    var list = try mutation.load(testing.allocator);
    defer list.deinit(testing.allocator);
    const kept = list.entries.items[0].asTokens();
    try testing.expectEqualStrings("refresh", kept.refresh_token);
    try testing.expectEqualStrings("access", kept.access_token);
    try testing.expectEqualStrings("https://vercel.com", kept.issuer);
    try testing.expectEqualStrings("cl_1", kept.client_id);
}

test "a sign-out a live fx is sending is left to it until its lease ends" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .codex);
    // This test's own process is the live sender.
    try keepAt(testing.allocator, place, .{ .refresh_token = "in-flight" }, 1_000, .{ .pid = processId(), .until_ms = 2_000 });
    var fake: FakeRevoker = .{};
    defer fake.deinit();
    _ = try retryAt(testing.allocator, place, 1_500, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 0), fake.sent.items.len);
    try expectKept(place, &.{"in-flight"});
    _ = try retryAt(testing.allocator, place, 2_001, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 1), fake.sent.items.len);
    try expectKept(place, &.{});
}

test "a sign-out whose sender is gone is sent at once" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .grok);
    // No process has this ID: its fx was killed while it sent the sign-out.
    const gone: i64 = std.math.maxInt(i32);
    try keepAt(testing.allocator, place, .{ .refresh_token = "orphan" }, 1_000, .{ .pid = gone, .until_ms = 50_000 });
    var fake: FakeRevoker = .{};
    defer fake.deinit();
    const outcome = try retryAt(testing.allocator, place, 1_500, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 1), outcome.revoked);
    try expectKept(place, &.{});
}

test "a retry leases what it sends, so a retry at the same time skips it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .codex);
    try keepAt(testing.allocator, place, .{ .refresh_token = "once" }, 1, null);
    // The provider refuses, so the sign-out stays kept with this retry's lease.
    var first: FakeRevoker = .{ .refuse = &.{"once"} };
    defer first.deinit();
    _ = try retryAt(testing.allocator, place, 10, first.revoker(), null);
    var second: FakeRevoker = .{};
    defer second.deinit();
    _ = try retryAt(testing.allocator, place, 11, second.revoker(), null);
    try testing.expectEqual(@as(usize, 0), second.sent.items.len);
    _ = try retryAt(testing.allocator, place, 11 + sendBudgetMs(.codex), second.revoker(), null);
    try testing.expectEqual(@as(usize, 1), second.sent.items.len);
}

test "a retry with nothing kept sends nothing and creates no file" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_]Source{ .codex, .grok, .fx_login }) |source| {
        var fake: FakeRevoker = .{};
        defer fake.deinit();
        const outcome = try retryAt(testing.allocator, testPlace(&tmp, source), 1, fake.revoker(), null);
        try testing.expectEqual(@as(usize, 0), outcome.revoked);
        try testing.expectEqual(@as(usize, 0), fake.sent.items.len);
    }
    // There was no profile folder, and the retries made none.
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io_mod.getIo(), profile_paths.rootName(), .{}));
}

fn keepAnother(fake: *FakeRevoker) anyerror!void {
    try keepAt(testing.allocator, fake.place.?, .{ .refresh_token = "added-meanwhile" }, 5, null);
}

test "a sign-out another fx keeps during a retry survives the retry's removal" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .codex);
    try keepAt(testing.allocator, place, .{ .refresh_token = "first" }, 1, null);
    // While the retry waits for the provider, another fx's logout keeps a
    // new sign-out. The retry then forgets only the one it revoked.
    var fake: FakeRevoker = .{ .during = keepAnother, .place = place };
    defer fake.deinit();
    const outcome = try retryAt(testing.allocator, place, 6, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 1), outcome.revoked);
    try expectKept(place, &.{"added-meanwhile"});
}

/// An in-memory Keychain item for the fx login's record.
const MemoryKeychain = struct {
    value: ?[]u8 = null,
    loads: usize = 0,
    fail_store: bool = false,

    fn backend(self: *MemoryKeychain) KeychainBackend {
        return .{ .context = self, .load_fn = load, .store_fn = store, .delete_fn = delete };
    }

    fn deinit(self: *MemoryKeychain) void {
        if (self.value) |value| testing.allocator.free(value);
    }

    fn load(context: ?*anyopaque, alloc: Allocator) anyerror!?[]u8 {
        const self: *MemoryKeychain = @ptrCast(@alignCast(context.?));
        self.loads += 1;
        const value = self.value orelse return null;
        return try alloc.dupe(u8, value);
    }

    fn store(context: ?*anyopaque, value: []const u8) anyerror!void {
        const self: *MemoryKeychain = @ptrCast(@alignCast(context.?));
        if (self.fail_store) return error.KeychainWriteFailed;
        if (self.value) |old| testing.allocator.free(old);
        self.value = try testing.allocator.dupe(u8, value);
    }

    fn delete(context: ?*anyopaque, alloc: Allocator) anyerror!void {
        _ = alloc;
        const self: *MemoryKeychain = @ptrCast(@alignCast(context.?));
        if (self.value) |old| testing.allocator.free(old);
        self.value = null;
    }
};

test "the fx login's Keychain record has a token-free marker, and a start with none reads no item" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var keychain: MemoryKeychain = .{};
    defer keychain.deinit();
    const place: Place = .{ .source = .fx_login, .keychain = keychain.backend(), .parent = tmp.dir };

    var fake: FakeRevoker = .{};
    defer fake.deinit();
    _ = try retryAt(testing.allocator, place, 1, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 0), keychain.loads);

    try keepAt(testing.allocator, place, .{ .refresh_token = "refresh", .access_token = "access", .issuer = "https://vercel.com", .client_id = "cl" }, 1, null);
    try testing.expect(keychain.value != null);
    try testing.expectEqual(@as(?u32, 0o600), try recordMode(&tmp, keychain_marker));
    try testing.expectEqual(@as(?u32, null), try recordMode(&tmp, "auth-revocations.json"));

    const outcome = try retryAt(testing.allocator, place, 2, fake.revoker(), null);
    try testing.expectEqual(@as(usize, 1), outcome.revoked);
    try testing.expect(keychain.value == null);
    try testing.expectEqual(@as(?u32, null), try recordMode(&tmp, keychain_marker));
}

test "a Keychain that refuses the write keeps nothing and leaves no marker" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var keychain: MemoryKeychain = .{ .fail_store = true };
    defer keychain.deinit();
    const place: Place = .{ .source = .fx_login, .keychain = keychain.backend(), .parent = tmp.dir };
    try testing.expectError(error.KeychainWriteFailed, keepAt(testing.allocator, place, .{ .refresh_token = "r" }, 1, null));
    try testing.expectEqual(@as(?u32, null), try recordMode(&tmp, keychain_marker));
}

test "a record that cannot be written keeps nothing and leaves what is there" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, profile_paths.rootName());
    defer fx_dir.close();
    // A folder where the record belongs can be neither read nor replaced.
    try fx_dir.dir.createDir(io_mod.getIo(), "chatgpt-revocations.json", .default_dir);
    if (keepAt(testing.allocator, testPlace(&tmp, .codex), .{ .refresh_token = "r" }, 1, null)) |_| return error.TestExpectedError else |_| {}
    const stat = try fx_dir.dir.statFile(io_mod.getIo(), "chatgpt-revocations.json", .{ .follow_symlinks = false });
    try testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
}

test "kept sign-outs match a plain list model over random keep, forget, and expire steps" {
    var prng: std.Random.DefaultPrng = .init(0x5157_2026);
    const random = prng.random();
    for (0..40) |_| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const place = testPlace(&tmp, .grok);
        // The model: refresh token and saved time, oldest first.
        var model: std.ArrayList(struct { token: u8, saved: i64 }) = .empty;
        defer model.deinit(testing.allocator);
        var now: i64 = 1000 * day_ms;
        for (0..30) |_| {
            now += random.intRangeAtMost(i64, 0, 12 * day_ms);
            const token = random.intRangeAtMost(u8, 0, 11);
            const text = [_]u8{ 'k', 'a' + token };
            switch (random.intRangeAtMost(u8, 0, 2)) {
                0 => {
                    try keepAt(testing.allocator, place, .{ .refresh_token = &text }, now, null);
                    var index: usize = 0;
                    while (index < model.items.len) {
                        if (now - model.items[index].saved > max_age_ms) _ = model.orderedRemove(index) else index += 1;
                    }
                    var known = false;
                    for (model.items) |item| known = known or item.token == token;
                    if (!known) try model.append(testing.allocator, .{ .token = token, .saved = now });
                    while (model.items.len > max_entries) _ = model.orderedRemove(0);
                },
                1 => {
                    try forgetAt(testing.allocator, place, &text);
                    for (model.items, 0..) |item, index| {
                        if (item.token == token) {
                            _ = model.orderedRemove(index);
                            break;
                        }
                    }
                },
                else => {
                    // A retry the provider refuses at once only expires.
                    var fake: FakeRevoker = .{ .refuse = &.{ "ka", "kb", "kc", "kd", "ke", "kf", "kg", "kh", "ki", "kj", "kk", "kl" } };
                    defer fake.deinit();
                    _ = try retryAt(testing.allocator, place, now, fake.revoker(), null);
                    var index: usize = 0;
                    while (index < model.items.len) {
                        if (now - model.items[index].saved > max_age_ms) _ = model.orderedRemove(index) else index += 1;
                    }
                },
            }
            const kept = try keptTokens(testing.allocator, place);
            defer freeTokens(testing.allocator, kept);
            try testing.expectEqual(model.items.len, kept.len);
            for (model.items, kept) |want, got| {
                const want_text = [_]u8{ 'k', 'a' + want.token };
                try testing.expectEqualSlices(u8, &want_text, got);
            }
        }
    }
}

test "many keep and retry rounds on one record end with nothing kept" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .codex);
    var name: [16]u8 = undefined;
    for (0..300) |round| {
        const token = try std.mem.print(&name, "round-{d}", .{round});
        try keepAt(testing.allocator, place, .{ .refresh_token = token }, @intCast(round), null);
        if (round % 3 == 2) {
            var fake: FakeRevoker = .{};
            defer fake.deinit();
            const outcome = try retryAt(testing.allocator, place, @intCast(round), fake.revoker(), null);
            try testing.expectEqual(@as(usize, 3), outcome.revoked);
        }
    }
    try expectKept(place, &.{});
}

test "the retry notice runs once and only when something is kept" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const place = testPlace(&tmp, .codex);
    const Counter = struct {
        var runs: usize = 0;
        fn run(_: *const anyopaque) void {
            runs += 1;
        }
    };
    const notice: oauth.BeforeRevocation = .{ .context = &Counter.runs, .run = Counter.run };
    var fake: FakeRevoker = .{};
    defer fake.deinit();
    _ = try retryAt(testing.allocator, place, 1, fake.revoker(), notice);
    try testing.expectEqual(@as(usize, 0), Counter.runs);
    try keepAt(testing.allocator, place, .{ .refresh_token = "a" }, 1, null);
    try keepAt(testing.allocator, place, .{ .refresh_token = "b" }, 1, null);
    _ = try retryAt(testing.allocator, place, 1, fake.revoker(), notice);
    try testing.expectEqual(@as(usize, 1), Counter.runs);
}

fn fuzzRecord(_: void, smith: *testing.Smith) !void {
    var buffer: [4096]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const alloc = testing.allocator;
    var list = parse(alloc, buffer[0..len]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.InvalidKeptSignOuts => return,
    };
    defer list.deinit(alloc);
    try testing.expect(list.entries.items.len <= max_entries);

    // What parses writes back the same.
    const text = try stringify(alloc, list);
    defer secret.zeroAndFree(alloc, text);
    var again = try parse(alloc, text);
    defer again.deinit(alloc);
    try testing.expectEqual(list.entries.items.len, again.entries.items.len);
    for (list.entries.items, again.entries.items) |want, got| {
        try testing.expectEqual(want.saved_at_ms, got.saved_at_ms);
        try testing.expectEqualStrings(want.refresh_token, got.refresh_token);
        try testing.expectEqualStrings(want.access_token, got.access_token);
    }

    // Any saved time expires without overflow, at any clock reading.
    for ([_]i64{ std.math.minInt(i64), 0, std.math.maxInt(i64) }) |now| {
        _ = again.expire(alloc, .codex, now);
    }
}

test "a kept sign-out record parses or is refused on fuzzed bytes, and what parses writes back the same" {
    try testing.fuzz({}, fuzzRecord, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            "{\"version\":1,\"entries\":[]}",
            "{\"version\":1,\"entries\":[{\"saved_at_ms\":1,\"refresh_token\":\"r\"}]}",
            "{\"version\":1,\"entries\":[{\"saved_at_ms\":-9223372036854775808,\"refresh_token\":\"r\",\"access_token\":\"a\",\"issuer\":\"https://vercel.com\",\"client_id\":\"c\"}]}",
            "{\"version\":1,\"entries\":[{\"saved_at_ms\":1,\"refresh_token\":\"r\"},{\"saved_at_ms\":2,\"refresh_token\":\"r\"}]}",
            "{\"version\":1,\"entries\":[{\"saved_at_ms\":1.5,\"refresh_token\":\"r\"}]}",
            "{\"version\":1,\"entries\":[{\"saved_at_ms\":1,\"refresh_token\":\"\\u0000\\ud800\"}]}",
            "[1,2,3]",
        }) ++ @import("fuzz_corpus").kept_sign_outs.*),
    });
}
