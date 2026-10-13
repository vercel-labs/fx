//! Sign-in credentials MCP-v2 hands fx to keep (AUTH-21): one opaque blob per
//! server name and URL, so a changed URL never gets an old token. They live in
//! the macOS Keychain, or in a private file under `~/.fx/mcp-credentials/`.
//! Either way the directory's advisory lock is held while the store is read
//! and rewritten, so two fx processes don't overwrite each other's entries.

const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const native_keychain = @import("../hosts/native_keychain.zig");
const secret = @import("../auth/secret.zig");
const v1_auth = @import("../mcp/mcp_auth.zig");
const v1_store = @import("../mcp/mcp_auth_store.zig");

const Allocator = std.mem.Allocator;

const file_name = "credentials-v2.json";
/// The same lock as v1's store, so the directory has one owner at a time.
const lock_file_name = "credentials.lock";
const lock_deadline_ms: u64 = 2_000;
const max_store_bytes: usize = 1024 * 1024;

pub const Backend = enum { keychain, file };

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

    /// The credential saved for `name` at `url`, or null. The caller owns it
    /// and frees it with `secret.zeroAndFree`.
    pub fn get(s: Store, alloc: Allocator, name: []const u8, url: []const u8) !?[]u8 {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked.dir);
        defer doc.deinit(alloc);
        const i = doc.find(name, url) orelse return null;
        return try alloc.dupe(u8, doc.entries.items[i].credential);
    }

    /// Saves `credential` for `name` at `url`, replacing any earlier one.
    pub fn put(s: Store, alloc: Allocator, name: []const u8, url: []const u8, credential: []const u8) !void {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked.dir);
        defer doc.deinit(alloc);
        if (doc.find(name, url)) |i| {
            const entry = &doc.entries.items[i];
            const copy = try alloc.dupe(u8, credential);
            secret.zeroAndFree(alloc, entry.credential);
            entry.credential = copy;
        } else {
            try doc.entries.ensureUnusedCapacity(alloc, 1);
            const entry: Entry = .{
                .name = try alloc.dupe(u8, name),
                .url = try alloc.dupe(u8, url),
                .credential = try alloc.dupe(u8, credential),
            };
            doc.entries.appendAssumeCapacity(entry);
        }
        try s.write(alloc, &locked.dir, doc);
    }

    /// Deletes the credential for `name` at `url`; false when there was none.
    pub fn remove(s: Store, alloc: Allocator, name: []const u8, url: []const u8) !bool {
        var locked = try s.lock();
        defer locked.release();
        var doc = try s.read(alloc, &locked.dir);
        defer doc.deinit(alloc);
        const i = doc.find(name, url) orelse return false;
        var entry = doc.entries.orderedRemove(i);
        entry.deinit(alloc);
        try s.write(alloc, &locked.dir, doc);
        return true;
    }

    const Locked = struct {
        dir: io_mod.VerifiedDir,
        lock: io_mod.TimedAdvisoryLock,

        fn release(l: *Locked) void {
            l.lock.release();
            l.dir.close();
        }
    };

    fn lock(s: Store) !Locked {
        var home = io_mod.VerifiedDir{ .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), s.home, .{ .iterate = true }) };
        defer home.close();
        var root = try io_mod.openOrCreateVerifiedPrivateDir(&home, profile_paths.root_dir_name);
        defer root.close();
        var dir = try io_mod.openOrCreateVerifiedPrivateDir(&root, profile_paths.mcp_credentials_dir_name);
        errdefer dir.close();
        const advisory = try io_mod.acquireTimedAdvisoryLock(&dir, lock_file_name, lock_deadline_ms);
        return .{ .dir = dir, .lock = advisory };
    }

    /// The store, holding v1's logins too the first time it's read.
    fn read(s: Store, alloc: Allocator, dir: *io_mod.VerifiedDir) !Doc {
        var doc = try s.readSaved(alloc, dir);
        errdefer doc.deinit(alloc);
        if (!doc.imported_v1) {
            s.importV1(alloc, dir, &doc);
            try s.write(alloc, dir, doc);
        }
        return doc;
    }

    /// Takes over the logins v1 kept, once: what MCP-v2 already has stays,
    /// and a login signed out later isn't brought back. One that can't be
    /// carried over stays behind, and that server signs in again.
    fn importV1(s: Store, alloc: Allocator, dir: *io_mod.VerifiedDir, doc: *Doc) void {
        doc.imported_v1 = true;
        v1_store.eachLocked(alloc, dir, s.backend == .keychain, ImportV1{ .alloc = alloc, .doc = doc }, ImportV1.add) catch |err| {
            debug_trace.logf("mcp", "MCP v1 logins not taken over err={s}", .{@errorName(err)});
        };
    }

    /// The store as saved; an unreadable one counts as empty, and the next
    /// change replaces it.
    fn readSaved(s: Store, alloc: Allocator, dir: *io_mod.VerifiedDir) !Doc {
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
                debug_trace.logf("mcp", "MCP credential store unreadable, treated as empty err={s}", .{@errorName(err)});
                return .{};
            },
        };
    }

    fn write(s: Store, alloc: Allocator, dir: *io_mod.VerifiedDir, doc: Doc) !void {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer {
            std.crypto.secureZero(u8, out.writer.buffer);
            out.deinit();
        }
        try std.json.Stringify.value(.{ .version = 1, .imported_v1 = doc.imported_v1, .servers = doc.entries.items }, .{}, &out.writer);
        switch (s.backend) {
            .keychain => try native_keychain.storeMcpHostCredentials(out.written()),
            .file => try io_mod.durableReplaceVerified(alloc, dir, file_name, out.written()),
        }
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
    credential: []u8,

    fn deinit(e: *Entry, alloc: Allocator) void {
        alloc.free(e.name);
        alloc.free(e.url);
        secret.zeroAndFree(alloc, e.credential);
    }
};

const Doc = struct {
    entries: std.ArrayList(Entry) = .empty,
    /// v1's logins were taken over; never again after that.
    imported_v1: bool = false,

    fn deinit(d: *Doc, alloc: Allocator) void {
        for (d.entries.items) |*e| e.deinit(alloc);
        d.entries.deinit(alloc);
    }

    fn find(d: *const Doc, name: []const u8, url: []const u8) ?usize {
        for (d.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.url, url)) return i;
        }
        return null;
    }

    fn parse(alloc: Allocator, bytes: []const u8) !Doc {
        const Saved = struct {
            version: u32,
            imported_v1: bool = false,
            servers: []const struct { name: []const u8, url: []const u8, credential: []const u8 },
        };
        var arena: std.heap.ArenaAllocator = .init(alloc);
        defer arena.deinit();
        const saved = try std.json.parseFromSliceLeaky(Saved, arena.allocator(), bytes, .{ .ignore_unknown_fields = true });
        if (saved.version != 1) return error.UnsupportedVersion;
        var doc: Doc = .{ .imported_v1 = saved.imported_v1 };
        errdefer doc.deinit(alloc);
        try doc.entries.ensureTotalCapacity(alloc, saved.servers.len);
        for (saved.servers) |entry| {
            var copy: Entry = .{ .name = try alloc.dupe(u8, entry.name), .url = undefined, .credential = undefined };
            errdefer alloc.free(copy.name);
            copy.url = try alloc.dupe(u8, entry.url);
            errdefer alloc.free(copy.url);
            copy.credential = try alloc.dupe(u8, entry.credential);
            doc.entries.appendAssumeCapacity(copy);
            std.crypto.secureZero(u8, @constCast(entry.credential));
        }
        return doc;
    }
};

const ImportV1 = struct {
    alloc: Allocator,
    doc: *Doc,

    fn add(ctx: ImportV1, server: []const u8, c: *const v1_auth.Credentials) Allocator.Error!void {
        if (ctx.doc.find(server, c.endpoint) != null) return;
        const credential = try fromV1(ctx.alloc, c) orelse return;
        errdefer secret.zeroAndFree(ctx.alloc, credential);
        try ctx.doc.entries.ensureUnusedCapacity(ctx.alloc, 1);
        const name = try ctx.alloc.dupe(u8, server);
        errdefer ctx.alloc.free(name);
        const url = try ctx.alloc.dupe(u8, c.endpoint);
        ctx.doc.entries.appendAssumeCapacity(.{ .name = name, .url = url, .credential = credential });
    }
};

/// A v1 login as the credential MCP-v2 saves, or null for one it can't use:
/// a token that isn't a bearer token, or a client method it doesn't know.
fn fromV1(alloc: Allocator, c: *const v1_auth.Credentials) Allocator.Error!?[]u8 {
    if (!std.ascii.eqlIgnoreCase(c.token_type, "bearer")) return null;
    const Method = enum { none, client_secret_basic, client_secret_post };
    const method = std.meta.stringToEnum(Method, c.token_endpoint_auth_method) orelse return null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer {
        std.crypto.secureZero(u8, out.writer.buffer);
        out.deinit();
    }
    std.json.Stringify.value(.{
        .access = c.access_token,
        .refresh = c.refresh_token,
        .expires_at_ms = if (c.expires_at_ms == std.math.maxInt(i64)) null else @as(?i64, c.expires_at_ms),
        .token_endpoint = c.token_endpoint,
        .revocation_endpoint = c.revocation_endpoint,
        .resource = c.resource,
        .client_id = c.client_id,
        .client_secret = c.client_secret,
        .method = @tagName(method),
    }, .{}, &out.writer) catch return error.OutOfMemory;
    return try out.toOwnedSlice();
}

const testing = std.testing;

fn testHome(tmp: *testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, ".");
}

test "a credential is kept per server name and URL, replaced, and removed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    const store: Store = .{ .home = home, .backend = .file };

    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, "linear", "https://mcp.linear.app/mcp"));
    try store.put(testing.allocator, "linear", "https://mcp.linear.app/mcp", "{\"access\":\"a1\"}");
    try store.put(testing.allocator, "linear", "https://other.example/mcp", "{\"access\":\"b1\"}");
    try store.put(testing.allocator, "linear", "https://mcp.linear.app/mcp", "{\"access\":\"a2\"}");

    const first = (try store.get(testing.allocator, "linear", "https://mcp.linear.app/mcp")).?;
    defer secret.zeroAndFree(testing.allocator, first);
    try testing.expectEqualStrings("{\"access\":\"a2\"}", first);
    const other = (try store.get(testing.allocator, "linear", "https://other.example/mcp")).?;
    defer secret.zeroAndFree(testing.allocator, other);
    try testing.expectEqualStrings("{\"access\":\"b1\"}", other);

    try testing.expect(try store.remove(testing.allocator, "linear", "https://mcp.linear.app/mcp"));
    try testing.expect(!try store.remove(testing.allocator, "linear", "https://mcp.linear.app/mcp"));
    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, "linear", "https://mcp.linear.app/mcp"));
}

test "v1's logins are taken over once, and a sign-out isn't undone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    {
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
    const store: Store = .{ .home = home, .backend = .file };
    const got = (try store.get(testing.allocator, "linear", "https://mcp.linear.app/mcp")).?;
    defer secret.zeroAndFree(testing.allocator, got);
    try testing.expectEqualStrings(
        \\{"access":"v1-access","refresh":"v1-refresh","expires_at_ms":null,"token_endpoint":"https://linear.app/oauth/token","revocation_endpoint":null,"resource":"https://mcp.linear.app/mcp","client_id":"c1","client_secret":null,"method":"none"}
    , got);
    // A token bound to a key isn't one MCP-v2 can send.
    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, "bound", "https://mcp.linear.app/mcp"));
    // Signed out, it stays signed out: v1's copy isn't taken again.
    try testing.expect(try store.remove(testing.allocator, "linear", "https://mcp.linear.app/mcp"));
    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, "linear", "https://mcp.linear.app/mcp"));
}

test "the credential file is private, and an unreadable one is replaced on the next save" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(&tmp);
    defer testing.allocator.free(home);
    const store: Store = .{ .home = home, .backend = .file };

    try store.put(testing.allocator, "plain", "https://mcp.plain.com/mcp", "{\"access\":\"p1\"}");
    const path = ".fx/" ++ profile_paths.mcp_credentials_dir_name ++ "/" ++ file_name;
    const stat = try tmp.dir.statFile(testing.io, path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = "not json" });
    try testing.expectEqual(@as(?[]u8, null), try store.get(testing.allocator, "plain", "https://mcp.plain.com/mcp"));
    try store.put(testing.allocator, "plain", "https://mcp.plain.com/mcp", "{\"access\":\"p2\"}");
    const saved = (try store.get(testing.allocator, "plain", "https://mcp.plain.com/mcp")).?;
    defer secret.zeroAndFree(testing.allocator, saved);
    try testing.expectEqualStrings("{\"access\":\"p2\"}", saved);
}
