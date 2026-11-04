//! Sign-in credentials the engine hands fx to keep (AUTH-21): one opaque blob per
//! server name and URL, so a changed URL never gets an old token. They live in
//! the macOS Keychain, or in a private file under `~/.fx/mcp-credentials/`.
//! Either way the directory's advisory lock is held while the store is read
//! and rewritten, so two fx processes don't overwrite each other's entries.
//! A store this fx can't read, damaged or saved by a newer fx, is never
//! written over. One fx refreshes a login at a time, under that login's
//! refresh lock.
//!
//! Older stores are never read or taken over: v1's `credentials.json`, and
//! `credentials-v2.json` (Keychain item `FX_MCP_OAUTH_CREDENTIALS_V2`). Builds
//! from before version 2 of the document read a version-2 store as empty and
//! write it back, erasing every login in it, and fx processes still running
//! those builds keep refreshing the logins they hold in memory. A login
//! shared with them would be refreshed apart and signed out, so this store
//! starts empty, in files and a Keychain item no older fx opens, and each
//! server signs in once.
//!
//! TLA+ models: `tests/tla/mcp_host/Credentials.tla`; for logins shared between
//! processes, `tests/tla/mcp_host/SharedLogins.tla`; and for processes running
//! older builds beside this one, `tests/tla/mcp_host/MixedBuilds.tla`.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const native_keychain = @import("../hosts/native_keychain.zig");
const secret = @import("../auth/secret.zig");
const json_decode = @import("../shared/json_decode.zig");

const Allocator = std.mem.Allocator;

const file_name = "credentials-v3.json";
/// Not `credentials.lock`, which older builds hold while they read and
/// rewrite their own stores: nothing here waits on them.
const lock_file_name = "credentials-v3.lock";
const lock_deadline_ms: u64 = 2_000;
const max_store_bytes: usize = 1024 * 1024;

pub const Backend = enum { keychain, file };

/// What a credential is saved under. A server from a workspace's `.mcp.json`
/// has its own, kept apart from the profile's and from other workspaces'
///: `workspace` is that workspace's root, null for every other server.
pub const Key = struct {
    name: []const u8,
    url: []const u8,
    workspace: ?[]const u8 = null,

    fn matches(k: Key, e: Entry) bool {
        const same_workspace = if (k.workspace) |w| (if (e.workspace) |ew| std.mem.eql(u8, w, ew) else false) else e.workspace == null;
        return same_workspace and std.mem.eql(u8, e.name, k.name) and std.mem.eql(u8, e.url, k.url);
    }
};

pub const Store = struct {
    /// The user's home directory, borrowed for the store's lifetime.
    home: []const u8,
    backend: Backend,

    /// The Keychain on macOS unless it is turned off or unusable, else the file.
    pub fn detect(alloc: Allocator, home: []const u8) Store {
        const keychain = builtin.target.os.tag == .macos and !native_keychain.isDisabled() and
            (native_keychain.userDefaultKeychainAvailable(alloc) catch false);
        return .{ .home = home, .backend = if (keychain) .keychain else .file };
    }

    /// Where the store is, for a message about one that can't be read.
    pub fn place(s: Store) []const u8 {
        return switch (s.backend) {
            .file => "~/" ++ profile_paths.root_dir_name ++ "/" ++ profile_paths.mcp_credentials_dir_name ++ "/" ++ file_name,
            .keychain => "the Keychain item " ++ native_keychain.mcp_host_credentials_service_name,
        };
    }

    /// The credential saved under `key`, or null, also when the store can't be
    /// read. The caller owns it and frees it with `secret.zeroAndFree`.
    pub fn get(s: Store, alloc: Allocator, key: Key) !?[]u8 {
        return s.lookup(alloc, key) catch |err| switch (err) {
            error.CredentialStoreUnreadable => null,
            else => err,
        };
    }

    /// `get`, except that a store it can't read fails with
    /// `error.CredentialStoreUnreadable`, so null means none is saved.
    pub fn lookup(s: Store, alloc: Allocator, key: Key) !?[]u8 {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked.dir);
        defer doc.deinit(alloc);
        const i = doc.find(key) orelse return null;
        return try alloc.dupe(u8, doc.entries.items[i].credential);
    }

    /// Every saved credential from one read of the store, so a host with
    /// many servers reads the Keychain once, not once per server. The
    /// caller frees it with `Snapshot.deinit`.
    pub fn snapshot(s: Store, alloc: Allocator) !Snapshot {
        var locked = try s.lock();
        defer locked.release();
        return .{ .doc = try s.read(alloc, &locked.dir) };
    }

    /// Fails with `error.CredentialStoreUnreadable` when the store can't be
    /// read, so a sign-in can stop before it starts.
    pub fn check(s: Store, alloc: Allocator) !void {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked.dir);
        doc.deinit(alloc);
    }

    /// Saves `credential` under `key`, replacing any earlier one; an
    /// unreadable store fails with `error.CredentialStoreUnreadable`.
    pub fn put(s: Store, alloc: Allocator, key: Key, credential: []const u8) !void {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked.dir);
        defer doc.deinit(alloc);
        if (doc.find(key)) |i| {
            const entry = &doc.entries.items[i];
            const copy = try alloc.dupe(u8, credential);
            secret.zeroAndFree(alloc, entry.credential);
            entry.credential = copy;
        } else {
            try doc.entries.ensureUnusedCapacity(alloc, 1);
            doc.entries.appendAssumeCapacity(try Entry.of(alloc, key, credential));
        }
        try s.write(alloc, &locked.dir, doc);
    }

    /// Deletes the credential saved under `key`; false when there was none.
    /// An unreadable store fails with `error.CredentialStoreUnreadable`.
    pub fn remove(s: Store, alloc: Allocator, key: Key) !bool {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked.dir);
        defer doc.deinit(alloc);
        const i = doc.find(key) orelse return false;
        var entry = doc.entries.orderedRemove(i);
        entry.deinit(alloc);
        try s.write(alloc, &locked.dir, doc);
        return true;
    }

    /// Deletes the credential saved under `key` only if it is `own`, the
    /// digest of the one this process had, so one another fx saved since
    /// stays. False when none was deleted.
    pub fn removeIfSame(s: Store, alloc: Allocator, key: Key, own: [32]u8) !bool {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked.dir);
        defer doc.deinit(alloc);
        const i = doc.find(key) orelse return false;
        if (!std.mem.eql(u8, &digest(doc.entries.items[i].credential), &own)) return false;
        var entry = doc.entries.orderedRemove(i);
        entry.deinit(alloc);
        try s.write(alloc, &locked.dir, doc);
        return true;
    }

    /// The refresh lock of the login saved under `key`, or null while another
    /// fx holds it: one fx refreshes a login at a time, and the others take
    /// what it saved. The lock goes with `release`, or with the process.
    pub fn tryRefreshLock(s: Store, key: Key) !?Locked {
        var dir = try s.openDir();
        errdefer dir.close();
        const name = refreshLockName(key);
        const advisory = io_mod.acquireTimedAdvisoryLock(&dir, &name, 0) catch |err| switch (err) {
            error.LockBusy => {
                dir.close();
                return null;
            },
            else => return err,
        };
        return .{ .dir = dir, .lock = advisory };
    }

    pub const Locked = struct {
        dir: io_mod.VerifiedDir,
        lock: io_mod.TimedAdvisoryLock,

        pub fn release(l: *Locked) void {
            l.lock.release();
            l.dir.close();
        }
    };

    fn openDir(s: Store) !io_mod.VerifiedDir {
        var home = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), profile_paths.rootParent(s.home), .{ .iterate = true }) };
        defer home.close();
        var root = try io_mod.openOrCreateVerifiedPrivateDir(&home, profile_paths.rootName());
        defer root.close();
        return io_mod.openOrCreateVerifiedPrivateDir(&root, profile_paths.mcp_credentials_dir_name);
    }

    fn lock(s: Store) !Locked {
        var dir = try s.openDir();
        errdefer dir.close();
        const advisory = try io_mod.acquireTimedAdvisoryLock(&dir, lock_file_name, lock_deadline_ms);
        return .{ .dir = dir, .lock = advisory };
    }

    /// The store as saved, empty when there is none. One that doesn't parse or
    /// has another version fails with `error.CredentialStoreUnreadable`.
    fn read(s: Store, alloc: Allocator, dir: *io_mod.VerifiedDir) !Doc {
        const bytes = (switch (s.backend) {
            .keychain => native_keychain.loadMcpHostCredentials(alloc) catch |err| switch (err) {
                error.KeychainItemNotFound => null,
                else => return err,
            },
            .file => try readFile(alloc, dir),
        }) orelse return .{};
        defer secret.zeroAndFree(alloc, bytes);
        return Doc.parse(alloc, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                debug_trace.logf("mcp", "MCP credential store unreadable, left as it is err={s}", .{@errorName(err)});
                return error.CredentialStoreUnreadable;
            },
        };
    }

    fn write(s: Store, alloc: Allocator, dir: *io_mod.VerifiedDir, doc: Doc) !void {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer {
            std.crypto.secureZero(u8, out.writer.buffer);
            out.deinit();
        }
        try doc.encode(&out.writer);
        switch (s.backend) {
            .keychain => try native_keychain.storeMcpHostCredentials(out.written()),
            .file => try io_mod.durableReplaceVerified(alloc, dir, file_name, out.written()),
        }
    }
};

/// What tells two saved credentials apart, without keeping either.
pub fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

/// Older builds lock `refresh-<digest>.lock` for the same login in their own
/// store, and its tokens are not this store's.
const refresh_lock_prefix = "refresh-v3-";
const refresh_lock_suffix = ".lock";
const RefreshLockName = [refresh_lock_prefix.len + 16 + refresh_lock_suffix.len]u8;

/// The prefix and 16 hex digits of the key's digest: one file per login.
fn refreshLockName(key: Key) RefreshLockName {
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    for ([_][]const u8{ key.name, key.url, key.workspace orelse "" }) |part| {
        h.update(part);
        h.update(&.{0});
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    var name: RefreshLockName = undefined;
    @memcpy(name[0..refresh_lock_prefix.len], refresh_lock_prefix);
    @memcpy(name[refresh_lock_prefix.len..][0..16], &std.fmt.bytesToHex(d[0..8].*, .lower));
    @memcpy(name[refresh_lock_prefix.len + 16 ..], refresh_lock_suffix);
    return name;
}

/// The saved credentials as one read of the store found them.
pub const Snapshot = struct {
    doc: Doc,

    /// The credential saved under `key`, or null. Borrowed from the
    /// snapshot until `deinit`.
    pub fn get(s: *const Snapshot, key: Key) ?[]const u8 {
        const i = s.doc.find(key) orelse return null;
        return s.doc.entries.items[i].credential;
    }

    /// Zeroes the credentials and frees them.
    pub fn deinit(s: *Snapshot, alloc: Allocator) void {
        s.doc.deinit(alloc);
        s.* = undefined;
    }
};

fn readFile(alloc: Allocator, dir: *io_mod.VerifiedDir) !?[]u8 {
    var file = dir.dir.openFile(io_mod.getIo(), file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    return try io_mod.readFileToEnd(alloc, &file, max_store_bytes);
}

const Entry = struct {
    name: []u8,
    url: []u8,
    /// The workspace a `.mcp.json` server's credential belongs to; null for others.
    workspace: ?[]u8 = null,
    credential: []u8,

    /// Copies of `key` and `credential`, owned by `alloc`.
    fn of(alloc: Allocator, key: Key, credential: []const u8) Allocator.Error!Entry {
        const name = try alloc.dupe(u8, key.name);
        errdefer alloc.free(name);
        const url = try alloc.dupe(u8, key.url);
        errdefer alloc.free(url);
        const workspace = if (key.workspace) |w| try alloc.dupe(u8, w) else null;
        errdefer if (workspace) |w| alloc.free(w);
        return .{ .name = name, .url = url, .workspace = workspace, .credential = try alloc.dupe(u8, credential) };
    }

    fn deinit(e: *Entry, alloc: Allocator) void {
        alloc.free(e.name);
        alloc.free(e.url);
        if (e.workspace) |w| alloc.free(w);
        secret.zeroAndFree(alloc, e.credential);
    }
};

const Doc = struct {
    entries: std.ArrayList(Entry) = .empty,

    fn deinit(d: *Doc, alloc: Allocator) void {
        for (d.entries.items) |*e| e.deinit(alloc);
        d.entries.deinit(alloc);
    }

    /// The document as `Store.write` saves it. Version 2, the format
    /// `credentials-v2.json` holds. No build that reads only version 1 opens
    /// this store: those read a version-2 document as empty and write over
    /// it. A profile server's entry has no workspace field.
    fn encode(d: *const Doc, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try std.json.Stringify.value(.{ .version = 2, .servers = d.entries.items }, .{ .emit_null_optional_fields = false }, w);
    }

    fn find(d: *const Doc, key: Key) ?usize {
        for (d.entries.items, 0..) |e, i| if (key.matches(e)) return i;
        return null;
    }

    fn parse(alloc: Allocator, bytes: []const u8) !Doc {
        // An older fx's `imported_v1` flag is ignored.
        const Saved = struct {
            version: u32,
            servers: []const struct { name: []const u8, url: []const u8, workspace: ?[]const u8 = null, credential: []const u8 },
        };
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const saved = try json_decode.parseFromSliceLeaky(Saved, arena.allocator(), bytes, .{ .ignore_unknown_fields = true });
        if (saved.version != 1 and saved.version != 2) return error.UnsupportedVersion;
        var doc: Doc = .{};
        errdefer doc.deinit(alloc);
        try doc.entries.ensureTotalCapacity(alloc, saved.servers.len);
        for (saved.servers) |entry| {
            doc.entries.appendAssumeCapacity(try Entry.of(alloc, .{ .name = entry.name, .url = entry.url, .workspace = entry.workspace }, entry.credential));
            std.crypto.secureZero(u8, @constCast(entry.credential));
        }
        return doc;
    }
};

const testing = std.testing;

fn testHome(tmp: *testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, ".");
}

test "one snapshot holds every server's credential" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    const store: Store = .{ .home = home, .backend = .file };
    const repo: Key = .{ .name = "linear", .url = "https://mcp.linear.app/mcp", .workspace = "/Users/example/repo" };
    try store.put(testing.allocator, .{ .name = "linear", .url = "https://mcp.linear.app/mcp" }, "{\"access\":\"l1\"}");
    try store.put(testing.allocator, .{ .name = "plain", .url = "https://mcp.plain.com/mcp" }, "{\"access\":\"p1\"}");
    try store.put(testing.allocator, repo, "{\"access\":\"r1\"}");

    var saved = try store.snapshot(testing.allocator);
    defer saved.deinit(testing.allocator);
    try testing.expectEqualStrings("{\"access\":\"l1\"}", saved.get(.{ .name = "linear", .url = "https://mcp.linear.app/mcp" }).?);
    try testing.expectEqualStrings("{\"access\":\"p1\"}", saved.get(.{ .name = "plain", .url = "https://mcp.plain.com/mcp" }).?);
    // A workspace's server has its own, apart from the profile's.
    try testing.expectEqualStrings("{\"access\":\"r1\"}", saved.get(repo).?);
    // A credential is kept per name and URL.
    try testing.expectEqual(@as(?[]const u8, null), saved.get(.{ .name = "plain", .url = "https://mcp.linear.app/mcp" }));
    try testing.expectEqual(@as(?[]const u8, null), saved.get(.{ .name = "slack", .url = "https://mcp.slack.com/mcp" }));
}

test "a credential is kept per server name and URL, replaced, and removed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    const store: Store = .{ .home = home, .backend = .file };

    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, .{ .name = "linear", .url = "https://mcp.linear.app/mcp" }));
    try store.put(testing.allocator, .{ .name = "linear", .url = "https://mcp.linear.app/mcp" }, "{\"access\":\"a1\"}");
    try store.put(testing.allocator, .{ .name = "linear", .url = "https://other.example/mcp" }, "{\"access\":\"b1\"}");
    try store.put(testing.allocator, .{ .name = "linear", .url = "https://mcp.linear.app/mcp" }, "{\"access\":\"a2\"}");

    const first = (try store.get(testing.allocator, .{ .name = "linear", .url = "https://mcp.linear.app/mcp" })).?;
    defer secret.zeroAndFree(testing.allocator, first);
    try testing.expectEqualStrings("{\"access\":\"a2\"}", first);
    const other = (try store.get(testing.allocator, .{ .name = "linear", .url = "https://other.example/mcp" })).?;
    defer secret.zeroAndFree(testing.allocator, other);
    try testing.expectEqualStrings("{\"access\":\"b1\"}", other);

    try testing.expect(try store.remove(testing.allocator, .{ .name = "linear", .url = "https://mcp.linear.app/mcp" }));
    try testing.expect(!try store.remove(testing.allocator, .{ .name = "linear", .url = "https://mcp.linear.app/mcp" }));
    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, .{ .name = "linear", .url = "https://mcp.linear.app/mcp" }));
}

test "a workspace server's credential is its workspace's own, apart from the profile's and other workspaces'" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    const store: Store = .{ .home = home, .backend = .file };
    const url = "https://mcp.example.com/mcp";
    const profile: Key = .{ .name = "github", .url = url };
    const repo_a: Key = .{ .name = "github", .url = url, .workspace = "/Users/example/a" };
    const repo_b: Key = .{ .name = "github", .url = url, .workspace = "/Users/example/b" };

    try store.put(testing.allocator, profile, "{\"access\":\"mine\"}");
    // The profile's login never reaches a workspace's server, nor one
    // workspace's another's.
    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, repo_a));
    try store.put(testing.allocator, repo_a, "{\"access\":\"a\"}");
    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, repo_b));
    const a = (try store.get(testing.allocator, repo_a)).?;
    defer secret.zeroAndFree(testing.allocator, a);
    try testing.expectEqualStrings("{\"access\":\"a\"}", a);
    const mine = (try store.get(testing.allocator, profile)).?;
    defer secret.zeroAndFree(testing.allocator, mine);
    try testing.expectEqualStrings("{\"access\":\"mine\"}", mine);

    // Only the workspace's entry names one; the profile's is saved as before.
    const bytes = try tmp.dir.readFileAlloc(testing.io, test_path, testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\"workspace\""));
    try testing.expect(std.mem.find(u8, bytes, "\"workspace\":\"/Users/example/a\"") != null);

    // Removing under one key leaves the others.
    try testing.expect(!try store.remove(testing.allocator, repo_b));
    try testing.expect(!try store.removeIfSame(testing.allocator, repo_b, digest("{\"access\":\"a\"}")));
    try testing.expect(try store.remove(testing.allocator, repo_a));
    const still = (try store.get(testing.allocator, profile)).?;
    defer secret.zeroAndFree(testing.allocator, still);
    try testing.expectEqualStrings("{\"access\":\"mine\"}", still);
}

/// v1's store with a login for linear, and one the engine can't use.
fn writeV1(home: []const u8) !void {
    var home_dir = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) };
    defer home_dir.close();
    var root = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    defer root.close();
    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&root, profile_paths.mcp_credentials_dir_name);
    defer dir.close();
    const entry =
        \\"endpoint":"https://mcp.linear.app/mcp","resource":"https://mcp.linear.app/mcp","issuer":"https://linear.app",
        \\"client_id":"c1","client_secret":null,"access_token":"v1-access","refresh_token":"v1-refresh","scope":"read",
        \\"token_endpoint_auth_method":"none","authorization_endpoint":"https://linear.app/oauth/authorize",
        \\"token_endpoint":"https://linear.app/oauth/token","revocation_endpoint":null,"expires_at_ms":null
    ;
    try io_mod.durableReplaceVerified(testing.allocator, &dir, profile_paths.mcp_credentials_file_name, "{\"version\":1,\"credentials\":[" ++
        "{\"server_identity\":\"linear\",\"token_type\":\"Bearer\"," ++ entry ++ "}," ++
        "{\"server_identity\":\"bound\",\"token_type\":\"DPoP\"," ++ entry ++ "}]}");
}

test "v1's logins aren't taken over, and an older fx's store with its flag is read as before" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    try writeV1(home);
    const store: Store = .{ .home = home, .backend = .file };
    const linear: Key = .{ .name = "linear", .url = "https://mcp.linear.app/mcp" };
    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, linear));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, test_path, .{}));
    // An older fx wrote its flag; the login is found, and the flag goes.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = test_path, .data = "{\"version\":1,\"imported_v1\":true,\"servers\":[{\"name\":\"linear\",\"url\":\"https://mcp.linear.app/mcp\",\"credential\":\"{}\"}]}" });
    const got = (try store.get(testing.allocator, linear)) orelse return error.TestUnexpectedResult;
    defer secret.zeroAndFree(testing.allocator, got);
    try testing.expectEqualStrings("{}", got);
    try store.put(testing.allocator, .{ .name = "plain", .url = "https://mcp.plain.com/mcp" }, "{}");
    const bytes = try tmp.dir.readFileAlloc(testing.io, test_path, testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.find(u8, bytes, "imported_v1") == null);
}

test "credentials-v2.json's logins aren't taken over, and an older fx rewriting it never reaches this store" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    const store: Store = .{ .home = home, .backend = .file };
    const plain: Key = .{ .name = "plain", .url = "https://mcp.plain.com/mcp" };
    const v2_path = ".fx/" ++ profile_paths.mcp_credentials_dir_name ++ "/credentials-v2.json";
    try tmp.dir.createDirPath(testing.io, ".fx/" ++ profile_paths.mcp_credentials_dir_name);
    const v2 = "{\"version\":2,\"servers\":[{\"name\":\"plain\",\"url\":\"https://mcp.plain.com/mcp\",\"credential\":\"{\\\"access\\\":\\\"v2\\\"}\"}]}";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = v2_path, .data = v2 });

    // The V2 login is never read, so the server signs in again here.
    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, plain));
    try store.put(testing.allocator, plain, "{\"access\":\"v3\"}");

    // An older fx reads version 2 as empty and writes its own store back.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = v2_path, .data = "{\"version\":1,\"imported_v1\":true,\"servers\":[]}" });
    const kept = (try store.get(testing.allocator, plain)) orelse return error.TestUnexpectedResult;
    defer secret.zeroAndFree(testing.allocator, kept);
    try testing.expectEqualStrings("{\"access\":\"v3\"}", kept);
    const old = try tmp.dir.readFileAlloc(testing.io, v2_path, testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(old);
    try testing.expectEqualStrings("{\"version\":1,\"imported_v1\":true,\"servers\":[]}", old);

    // Its refresh lock is apart from the one an older fx takes for its own copy.
    const lock_name = refreshLockName(plain);
    try testing.expect(std.mem.startsWith(u8, &lock_name, "refresh-v3-"));
    try testing.expect(std.mem.endsWith(u8, &lock_name, ".lock"));
}

test "the store is the one no older fx opens" {
    try testing.expectEqualStrings("credentials-v3.json", file_name);
    try testing.expectEqualStrings("credentials-v3.lock", lock_file_name);
    try testing.expectEqualStrings("FX_MCP_OAUTH_CREDENTIALS_V3", native_keychain.mcp_host_credentials_service_name);
    try testing.expectEqualStrings("the Keychain item FX_MCP_OAUTH_CREDENTIALS_V3", (Store{ .home = "/Users/example", .backend = .keychain }).place());
    try testing.expectEqualStrings("~/.fx/mcp-credentials/credentials-v3.json", (Store{ .home = "/Users/example", .backend = .file }).place());
}

/// A document that parses is saved as version 2 and reads back the same, so
/// a write never leaves a store this fx can't read.
fn fuzzStoreDocument(_: void, smith: *std.testing.Smith) !void {
    var buffer: [2048]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buffer, &.{
        .rangeAtMost(u8, 0x20, 0x7e, 8),
        .rangeAtMost(u8, 0x00, 0xff, 1),
        .value(u8, '{', 4),
        .value(u8, '}', 4),
        .value(u8, '[', 3),
        .value(u8, ']', 3),
        .value(u8, '"', 4),
        .value(u8, '\\', 2),
        .value(u8, ':', 3),
        .value(u8, ',', 3),
    });
    var doc = Doc.parse(testing.allocator, buffer[0..len]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer doc.deinit(testing.allocator);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try doc.encode(&out.writer);
    var again = try Doc.parse(testing.allocator, out.written());
    defer again.deinit(testing.allocator);
    try testing.expectEqual(doc.entries.items.len, again.entries.items.len);
    for (doc.entries.items, again.entries.items) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqualStrings(a.url, b.url);
        try testing.expectEqualStrings(a.credential, b.credential);
        try testing.expectEqualStrings(a.workspace orelse "", b.workspace orelse "");
        try testing.expectEqual(a.workspace == null, b.workspace == null);
    }
}

test "a store document that parses always saves back readable" {
    try std.testing.fuzz({}, fuzzStoreDocument, .{
        .corpus = &.{
            "{\"version\":2,\"servers\":[]}",
            "{\"version\":1,\"imported_v1\":true,\"servers\":[{\"name\":\"linear\",\"url\":\"https://mcp.linear.app/mcp\",\"credential\":\"{}\"}]}",
            "{\"version\":2,\"servers\":[{\"name\":\"github\",\"url\":\"https://mcp.example.com/mcp\",\"workspace\":\"/Users/example/a\",\"credential\":\"{\\\"access\\\":\\\"a\\\"}\"}]}",
            "{\"version\":2,\"servers\":[{\"name\":\"\\u00e9\",\"url\":\"\",\"credential\":\"\\n\\t\\\"\"}]}",
            "{\"version\":3,\"servers\":[]}",
            "not json",
        },
    });
}

test "one fx holds a login's refresh lock at a time, and each login has its own" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    const store: Store = .{ .home = home, .backend = .file };
    const plain: Key = .{ .name = "plain", .url = "https://mcp.plain.com/mcp" };
    var held = (try store.tryRefreshLock(plain)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(?Store.Locked, null), try store.tryRefreshLock(plain));
    // Another login's, and the store itself, aren't held by it.
    var other = (try store.tryRefreshLock(.{ .name = "plain", .url = "https://mcp.plain.com/mcp", .workspace = "/Users/example/a" })) orelse return error.TestUnexpectedResult;
    other.release();
    try store.put(testing.allocator, plain, "{}");
    held.release();
    var again = (try store.tryRefreshLock(plain)) orelse return error.TestUnexpectedResult;
    again.release();
}

const test_path = ".fx/" ++ profile_paths.mcp_credentials_dir_name ++ "/" ++ file_name;

test "the credential file is private, and one this fx can't read is never written over" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    const store: Store = .{ .home = home, .backend = .file };
    const url = "https://mcp.plain.com/mcp";

    try store.put(testing.allocator, .{ .name = "plain", .url = url }, "{\"access\":\"p1\"}");
    const stat = try tmp.dir.statFile(testing.io, test_path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    const found = (try store.lookup(testing.allocator, .{ .name = "plain", .url = url })).?;
    defer testing.allocator.free(found);
    try testing.expectEqualStrings("{\"access\":\"p1\"}", found);
    try testing.expectEqual(@as(?[]u8, null), try store.lookup(testing.allocator, .{ .name = "linear", .url = url }));

    // A damaged file, then one a newer fx saved: no login is found, though
    // `lookup` says it can't tell, a sign-in or sign-out fails, and the
    // file stays as it was.
    for ([_][]const u8{
        "not json",
        "{\"version\":3,\"imported_v1\":true,\"servers\":[{\"name\":\"plain\",\"url\":\"https://mcp.plain.com/mcp\",\"credential\":\"{}\"}]}",
    }) |bytes| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = test_path, .data = bytes });
        try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, .{ .name = "plain", .url = url }));
        try testing.expectError(error.CredentialStoreUnreadable, store.lookup(testing.allocator, .{ .name = "plain", .url = url }));
        try testing.expectError(error.CredentialStoreUnreadable, store.check(testing.allocator));
        try testing.expectError(error.CredentialStoreUnreadable, store.put(testing.allocator, .{ .name = "plain", .url = url }, "{\"access\":\"p2\"}"));
        try testing.expectError(error.CredentialStoreUnreadable, store.remove(testing.allocator, .{ .name = "plain", .url = url }));
        const after = try tmp.dir.readFileAlloc(testing.io, test_path, testing.allocator, .limited(1 << 16));
        defer testing.allocator.free(after);
        try testing.expectEqualStrings(bytes, after);
    }
}

test "a refused login removes only its own: one another fx saved since stays" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    const store: Store = .{ .home = home, .backend = .file };
    const url = "https://mcp.linear.app/mcp";

    try store.put(testing.allocator, .{ .name = "linear", .url = url }, "{\"access\":\"mine\"}");
    const mine = digest("{\"access\":\"mine\"}");
    // Another fx signs in and saves its own.
    try store.put(testing.allocator, .{ .name = "linear", .url = url }, "{\"access\":\"theirs\"}");
    try testing.expect(!try store.removeIfSame(testing.allocator, .{ .name = "linear", .url = url }, mine));
    const kept = (try store.get(testing.allocator, .{ .name = "linear", .url = url })).?;
    defer secret.zeroAndFree(testing.allocator, kept);
    try testing.expectEqualStrings("{\"access\":\"theirs\"}", kept);
    try testing.expect(try store.removeIfSame(testing.allocator, .{ .name = "linear", .url = url }, digest("{\"access\":\"theirs\"}")));
    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, .{ .name = "linear", .url = url }));
}
