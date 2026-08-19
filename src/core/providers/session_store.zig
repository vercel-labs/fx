const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;

pub const auth_file_name = profile_paths.auth_file_name;
const schema_version: i64 = 1;
const max_auth_file_bytes: usize = 64 * 1024;
const expiry_skew_ms: i64 = 60 * 1000;
const mutation_lock_file_name = "auth.lock";
const mutation_lock_deadline_ms: u64 = 2000;
const LoadMode = enum { tolerate_open_failure, report_open_failure };

pub fn refresh_deadline_ms(expires_at_ms: i64) i64 {
    return expires_at_ms -| expiry_skew_ms;
}

pub const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

pub const Session = struct {
    issuer: []u8,
    client_id: []u8,
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    scope: []u8,
    token_type: []u8,
    account_id: ?[]u8 = null,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        alloc.free(self.issuer);
        alloc.free(self.client_id);
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.scope);
        alloc.free(self.token_type);
        if (self.account_id) |value| alloc.free(value);
        self.* = undefined;
    }

    pub fn expired(self: Session, now_ms: i64) bool {
        return refresh_deadline_ms(self.expires_at_ms) <= now_ms;
    }

    pub fn clone(self: Session, alloc: Allocator) !Session {
        const issuer = try alloc.dupe(u8, self.issuer);
        errdefer alloc.free(issuer);
        const client_id = try alloc.dupe(u8, self.client_id);
        errdefer alloc.free(client_id);
        const access_token = try alloc.dupe(u8, self.access_token);
        errdefer secret.zeroAndFree(alloc, access_token);
        const refresh_token = try alloc.dupe(u8, self.refresh_token);
        errdefer secret.zeroAndFree(alloc, refresh_token);
        const scope = try alloc.dupe(u8, self.scope);
        errdefer alloc.free(scope);
        const token_type = try alloc.dupe(u8, self.token_type);
        errdefer alloc.free(token_type);
        const account_id = if (self.account_id) |value| try alloc.dupe(u8, value) else null;
        return .{
            .issuer = issuer,
            .client_id = client_id,
            .access_token = access_token,
            .refresh_token = refresh_token,
            .expires_at_ms = self.expires_at_ms,
            .scope = scope,
            .token_type = token_type,
            .account_id = account_id,
        };
    }
};

pub const Mutation = struct {
    backend_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.backend_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        return loadFromDir(alloc, &self.backend_dir.dir, .report_open_failure);
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(alloc, &self.backend_dir, auth_file_name, text);
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        return deleteAuthFile(&self.backend_dir.dir, .{});
    }
};

pub fn load(alloc: Allocator, backend_dir_name: []const u8) !?Session {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch return null;
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return null;
    defer fx_dir.close(io_mod.getIo());

    var providers_dir = fx_dir.openDir(io_mod.getIo(), profile_paths.providers_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return null;
    defer providers_dir.close(io_mod.getIo());

    var backend_dir = providers_dir.openDir(io_mod.getIo(), backend_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return null;
    defer backend_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &backend_dir, .tolerate_open_failure);
}

pub fn saveNewSession(alloc: Allocator, backend_dir_name: []const u8, session: Session) !void {
    if (comptime host_target.is_wasm) return error.InteractiveAuthorizationUnsupported;
    var mutation = try beginMutation(backend_dir_name);
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation(backend_dir_name: []const u8) !?Mutation {
    if (comptime host_target.is_wasm) return error.InteractiveAuthorizationUnsupported;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    var fx_dir = home_dir.dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer fx_dir.close(io_mod.getIo());

    var providers_dir = fx_dir.openDir(io_mod.getIo(), profile_paths.providers_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer providers_dir.close(io_mod.getIo());

    var backend_dir = io_mod.VerifiedDir{
        .dir = providers_dir.openDir(io_mod.getIo(), backend_dir_name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        },
    };
    errdefer backend_dir.close();
    return try lockMutation(backend_dir);
}

fn beginMutation(backend_dir_name: []const u8) !Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    defer fx_dir.close();
    var providers_dir = try io_mod.openOrCreateVerifiedPrivateDir(&fx_dir, profile_paths.providers_dir_name);
    defer providers_dir.close();
    const backend_dir = try io_mod.openOrCreateVerifiedPrivateDir(&providers_dir, backend_dir_name);
    return lockMutation(backend_dir);
}

fn lockMutation(open_backend_dir: io_mod.VerifiedDir) !Mutation {
    var backend_dir = open_backend_dir;
    errdefer backend_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(
        &backend_dir,
        mutation_lock_file_name,
        mutation_lock_deadline_ms,
    );
    errdefer lock.release();
    return .{
        .backend_dir = backend_dir,
        .lock = lock,
    };
}

fn loadFromDir(alloc: Allocator, backend_dir: *std.Io.Dir, mode: LoadMode) !?Session {
    var file = backend_dir.openFile(io_mod.getIo(), auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("chatgpt", "session load failed step=open_file err={s}", .{@errorName(err)});
            if (mode == .tolerate_open_failure) return null else return err;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("chatgpt", "session load failed step=permissions err=InsecureAuthFile", .{});
        return null;
    }

    const bytes = try io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("chatgpt", "session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

fn deleteAuthFile(backend_dir: *std.Io.Dir, ops: io_mod.DurableOps) !DeleteOutcome {
    backend_dir.deleteFile(io_mod.getIo(), auth_file_name) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    ops.sync_dir(ops.ctx, backend_dir.*) catch return .deleted_not_durable;
    return .deleted;
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidAuthSession;

    const expires_at_ms = try requiredInteger(object, "expires_at_ms");
    const issuer = try dupeRequiredString(alloc, object, "issuer");
    errdefer alloc.free(issuer);
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
    const account_id = try dupeOptionalString(alloc, object, "account_id");
    return .{
        .issuer = issuer,
        .client_id = client_id,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .scope = scope,
        .token_type = token_type,
        .account_id = account_id,
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
    if (session.account_id) |value| try writeField(writer, "account_id", value);
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

test "provider session round-trips tokens and account id" {
    const alloc = std.testing.allocator;
    var session = Session{
        .issuer = try alloc.dupe(u8, "https://auth.openai.com"),
        .client_id = try alloc.dupe(u8, "app_test"),
        .access_token = try alloc.dupe(u8, "access"),
        .refresh_token = try alloc.dupe(u8, "refresh"),
        .expires_at_ms = 42,
        .scope = try alloc.dupe(u8, "openid offline_access"),
        .token_type = try alloc.dupe(u8, "Bearer"),
        .account_id = try alloc.dupe(u8, "acct_1"),
    };
    defer session.deinit(alloc);

    const text = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, text);
    try std.testing.expect(std.mem.endsWith(u8, text, "\n"));

    var parsed = try parse(alloc, text);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings(session.issuer, parsed.issuer);
    try std.testing.expectEqualStrings(session.access_token, parsed.access_token);
    try std.testing.expectEqualStrings(session.refresh_token, parsed.refresh_token);
    try std.testing.expectEqualStrings("acct_1", parsed.account_id.?);
    try std.testing.expectEqual(@as(i64, 42), parsed.expires_at_ms);
}

test "provider session file round-trips at mode 0600" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var backend_dir = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true, .follow_symlinks = false }),
    };
    defer backend_dir.close();

    var session = Session{
        .issuer = try std.testing.allocator.dupe(u8, "http://127.0.0.1:9"),
        .client_id = try std.testing.allocator.dupe(u8, "client"),
        .access_token = try std.testing.allocator.dupe(u8, "tok"),
        .refresh_token = try std.testing.allocator.dupe(u8, "ref"),
        .expires_at_ms = 1,
        .scope = try std.testing.allocator.dupe(u8, "openid"),
        .token_type = try std.testing.allocator.dupe(u8, "Bearer"),
    };
    defer session.deinit(std.testing.allocator);

    const text = try stringify(std.testing.allocator, session);
    defer secret.zeroAndFree(std.testing.allocator, text);
    try io_mod.durableReplaceVerified(std.testing.allocator, &backend_dir, auth_file_name, text);

    const stat = try tmp.dir.statFile(std.testing.io, auth_file_name, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);

    var loaded = (try loadFromDir(std.testing.allocator, &backend_dir.dir, .report_open_failure)) orelse
        return error.TestUnexpectedMissingSession;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("tok", loaded.access_token);
}
