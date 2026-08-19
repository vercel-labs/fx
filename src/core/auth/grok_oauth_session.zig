const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

/// Published xAI third-party OAuth client used by Hermes / OpenCode.
/// Override with FX_GROK_OAUTH_CLIENT_ID. Identify requests as fx, never as grok-cli.
pub const issuer = "https://auth.x.ai";
pub const accounts_issuer = "https://accounts.x.ai";
pub const client_id_env = "FX_GROK_OAUTH_CLIENT_ID";
pub const default_client_id = "b1a00492-073a-47ea-816f-4c329264a828";
pub const default_scope = "openid profile email offline_access grok-cli:access api:access";
const e2e_issuer_url_env = "FX_E2E_GROK_OAUTH_ISSUER_URL";
pub const auth_file_name = profile_paths.grok_auth_file_name;
const schema_version: i64 = 1;
const max_auth_file_bytes: usize = 64 * 1024;
const expiry_skew_ms: i64 = 60 * 1000;
const mutation_lock_file_name = "grok-auth.lock";
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

    pub fn deinit(self: *Session, alloc: Allocator) void {
        alloc.free(self.issuer);
        alloc.free(self.client_id);
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        alloc.free(self.scope);
        alloc.free(self.token_type);
        self.* = undefined;
    }

    pub fn expired(self: Session, now_ms: i64) bool {
        return refresh_deadline_ms(self.expires_at_ms) <= now_ms;
    }
};

pub const Mutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        return loadFromDir(alloc, &self.fx_dir.dir, .report_open_failure);
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(alloc, &self.fx_dir, auth_file_name, text);
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        return deleteAuthFile(&self.fx_dir.dir, .{});
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
    return !isFirstPartyIssuer(url) and isLoopbackHttpUrl(url, true);
}

pub fn validateE2EEndpoint(issuer_url: []const u8, endpoint: []const u8) !void {
    if (isLoopbackE2EIssuer(issuer_url) and !isLoopbackHttpUrl(endpoint, false)) {
        return error.InvalidE2EOAuthEndpoint;
    }
}

pub fn isFirstPartyIssuer(url: []const u8) bool {
    return std.mem.eql(u8, url, issuer) or std.mem.eql(u8, url, accounts_issuer);
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
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse {
        debug_trace.logf("auth", "grok session load skipped step=home err=HomeNotSet", .{});
        return null;
    };
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("auth", "grok session load failed step=open_home err={s}", .{@errorName(err)});
        return null;
    };
    defer home_dir.close(io_mod.getIo());

    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| {
        debug_trace.logf("auth", "grok session load failed step=open_profile err={s}", .{@errorName(err)});
        return null;
    };
    defer fx_dir.close(io_mod.getIo());

    return loadFromDir(alloc, &fx_dir, .tolerate_open_failure);
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
            debug_trace.logf("auth", "grok session load failed step=open_file err={s}", .{@errorName(err)});
            if (mode == .tolerate_open_failure) return null else return err;
        },
    };
    defer file.close(io_mod.getIo());

    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0) {
        debug_trace.logf("auth", "grok session load failed step=permissions err=InsecureAuthFile", .{});
        return null;
    }

    const bytes = try io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "grok session load failed step=parse err={s}", .{@errorName(err)});
            return null;
        },
    };
}

pub fn saveNewSession(alloc: Allocator, session: Session) !void {
    if (comptime host_target.is_wasm) return error.GrokOAuthUnavailableOnHost;
    var mutation = try beginMutation();
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation() !?Mutation {
    if (comptime host_target.is_wasm) return error.GrokOAuthUnavailableOnHost;
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
    var fx_dir = open_fx_dir;
    errdefer fx_dir.close();

    var lock = try io_mod.acquireTimedAdvisoryLock(
        &fx_dir,
        mutation_lock_file_name,
        mutation_lock_deadline_ms,
    );
    errdefer lock.release();

    return .{
        .fx_dir = fx_dir,
        .lock = lock,
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
    if (!isFirstPartyIssuer(saved_issuer) and !isLoopbackE2EIssuer(saved_issuer)) {
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

    return .{
        .issuer = owned_issuer,
        .client_id = client_id,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .scope = scope,
        .token_type = token_type,
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

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidAuthSession;
    if (value != .integer) return error.InvalidAuthSession;
    return value.integer;
}

const test_session_json = "{\"version\":1,\"issuer\":\"https://auth.x.ai\",\"client_id\":\"client\",\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_at_ms\":1,\"scope\":\"openid offline_access\",\"token_type\":\"Bearer\"}";

fn check_parse_allocation_failures(alloc: Allocator) !void {
    var session = try parse(alloc, test_session_json);
    defer session.deinit(alloc);
}

test "grok oauth session stringifies and parses" {
    var session = Session{
        .issuer = try std.testing.allocator.dupe(u8, issuer),
        .client_id = try std.testing.allocator.dupe(u8, "client"),
        .access_token = try std.testing.allocator.dupe(u8, "access"),
        .refresh_token = try std.testing.allocator.dupe(u8, "refresh"),
        .expires_at_ms = 1234,
        .scope = try std.testing.allocator.dupe(u8, default_scope),
        .token_type = try std.testing.allocator.dupe(u8, "Bearer"),
    };
    defer session.deinit(std.testing.allocator);

    const text = try stringify(std.testing.allocator, session);
    defer secret.zeroAndFree(std.testing.allocator, text);
    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(issuer, parsed.issuer);
    try std.testing.expectEqualStrings("client", parsed.client_id);
    try std.testing.expectEqualStrings("access", parsed.access_token);
    try std.testing.expectEqualStrings("refresh", parsed.refresh_token);
}

test "grok oauth session accepts accounts.x.ai issuer" {
    var parsed = try parse(
        std.testing.allocator,
        "{\"version\":1,\"issuer\":\"https://accounts.x.ai\",\"client_id\":\"client\",\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_at_ms\":1,\"scope\":\"openid\",\"token_type\":\"Bearer\"}",
    );
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(accounts_issuer, parsed.issuer);
}

test "grok oauth session rejects vercel and unknown issuers" {
    try std.testing.expectError(
        error.InvalidAuthSession,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"issuer\":\"https://vercel.com\",\"client_id\":\"client\",\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_at_ms\":1234,\"scope\":\"openid\",\"token_type\":\"Bearer\"}",
        ),
    );
    try std.testing.expectError(
        error.InvalidAuthSession,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"issuer\":\"https://example.com\",\"client_id\":\"client\",\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_at_ms\":1234,\"scope\":\"openid\",\"token_type\":\"Bearer\"}",
        ),
    );
}

test "grok oauth session parse requires a refresh token" {
    try std.testing.expectError(
        error.InvalidAuthSession,
        parse(
            std.testing.allocator,
            "{\"version\":1,\"issuer\":\"https://auth.x.ai\",\"client_id\":\"client\",\"access_token\":\"access\",\"expires_at_ms\":1,\"scope\":\"openid\",\"token_type\":\"Bearer\"}",
        ),
    );
}

test "grok oauth session parse cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_parse_allocation_failures, .{});
}

test "grok oauth session treats near-expiry as expired" {
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
}

test "grok oauth session file name is not the vercel auth file" {
    try std.testing.expect(!std.mem.eql(u8, auth_file_name, profile_paths.auth_file_name));
    try std.testing.expectEqualStrings("grok-auth.json", auth_file_name);
}
