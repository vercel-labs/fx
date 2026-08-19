const std = @import("std");
const grok_oauth_session = @import("grok_oauth_session.zig");
const config_runtime = @import("../config/config_runtime.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const model_catalog = @import("../gateway/model_catalog.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const grok_cli_auth_relpath = ".grok/auth.json";
const poll_wait_slice_ms: u64 = 100;
const default_import_lifetime_ms: i64 = 30 * std.time.ms_per_day;

pub const LoginError = error{
    ClientIdMissing,
    LoginTimedOut,
    NoRefreshToken,
    GrokCliAuthMissing,
    InvalidGrokCliAuth,
    GrokOAuthUnavailableOnHost,
};

pub fn runLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !void {
    _ = url_opener;
    var prepared = try prepareLogin(alloc, transport);
    defer prepared.deinit(alloc);

    const display_url = prepared.device.verification_uri_complete orelse prepared.device.verification_uri;
    try writeStdout("Open ");
    try writeStdout(display_url);
    try writeStdout("\nCode: ");
    try writeStdout(prepared.device.user_code);
    try writeStdout("\n\nWaiting for Grok authentication...\n");

    var token = try pollForToken(
        alloc,
        transport,
        prepared.metadata,
        prepared.client_id,
        prepared.device,
    );
    defer token.deinit(alloc);

    const now_ms = io_mod.milliTimestamp();
    var session = try takeLoginSession(
        alloc,
        prepared.metadata.issuer,
        prepared.client_id,
        &token,
        now_ms,
    );
    defer session.deinit(alloc);

    try grok_oauth_session.saveNewSession(alloc, session);
    persistGrokCredentialPreference(alloc);
    try writeStdout("Signed in with Grok OAuth.\n");
    try writeStdout("SuperGrok or X Premium+ must be active on the signed-in account.\n");
}

pub fn runImport(alloc: Allocator) !void {
    const home = io_mod.getenv("HOME") orelse return LoginError.GrokCliAuthMissing;
    const path = try std.fs.path.join(alloc, &.{ home, grok_cli_auth_relpath });
    defer alloc.free(path);

    const bytes = readGrokCliAuthFile(alloc, path) catch |err| switch (err) {
        error.FileNotFound => return LoginError.GrokCliAuthMissing,
        else => return err,
    };
    defer secret.zeroAndFree(alloc, bytes);

    var session = try parseGrokCliAuth(alloc, bytes, io_mod.milliTimestamp());
    defer session.deinit(alloc);
    try grok_oauth_session.saveNewSession(alloc, session);
    persistGrokCredentialPreference(alloc);
    try writeStdout("Imported Grok CLI credentials into fx. ~/.grok/auth.json was not modified.\n");
}

pub fn logout(
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !LogoutResult {
    var session: ?grok_oauth_session.Session = null;
    var session_load_failed = false;
    defer if (session) |*loaded| loaded.deinit(alloc);
    const delete_outcome = blk: {
        var mutation = (grok_oauth_session.beginExistingMutation() catch {
            return error.SessionDeleteFailed;
        }) orelse return .{};
        defer mutation.deinit();
        session = mutation.load(alloc) catch load: {
            session_load_failed = true;
            break :load null;
        };
        break :blk mutation.delete() catch return error.SessionDeleteFailed;
    };

    const local_durability_failed = delete_outcome == .deleted_not_durable;
    var remote_revocation_failed = session_load_failed or local_durability_failed;
    if (!local_durability_failed and session != null) {
        const loaded = session.?;
        revokeLogoutSession(alloc, transport, loaded) catch {
            remote_revocation_failed = true;
        };
    }

    return .{
        .session_deleted = delete_outcome != .missing,
        .local_durability_failed = local_durability_failed,
        .remote_revocation_failed = remote_revocation_failed,
    };
}

pub const LogoutResult = struct {
    session_deleted: bool = false,
    local_durability_failed: bool = false,
    remote_revocation_failed: bool = false,
};

const PreparedLogin = struct {
    metadata: oauth.Metadata,
    device: oauth.DeviceAuthorization,
    client_id: []u8,

    fn deinit(self: *PreparedLogin, alloc: Allocator) void {
        self.metadata.deinit(alloc);
        self.device.deinit(alloc);
        alloc.free(self.client_id);
        self.* = undefined;
    }
};

fn prepareLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !PreparedLogin {
    const client_id = grok_oauth_session.configuredClientId() orelse return LoginError.ClientIdMissing;
    const issuer_url = try grok_oauth_session.configuredIssuerUrl();

    var metadata = try oauth.discover(alloc, transport, issuer_url);
    errdefer metadata.deinit(alloc);
    try grok_oauth_session.validateE2EEndpoint(issuer_url, metadata.device_authorization_endpoint);
    try grok_oauth_session.validateE2EEndpoint(issuer_url, metadata.token_endpoint);

    var device = try oauth.requestDeviceAuthorizationWithScope(
        alloc,
        transport,
        metadata,
        client_id,
        grok_oauth_session.default_scope,
    );
    errdefer device.deinit(alloc);
    const owned_client_id = try alloc.dupe(u8, client_id);
    return .{
        .metadata = metadata,
        .device = device,
        .client_id = owned_client_id,
    };
}

fn pollForToken(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    client_id: []const u8,
    device: oauth.DeviceAuthorization,
) !oauth.TokenSet {
    var cancel_flag = std.atomic.Value(bool).init(false);
    const started_ms = io_mod.milliTimestamp();
    const expires_at_ms = std.math.add(
        i64,
        started_ms,
        std.math.mul(i64, device.expires_in, std.time.ms_per_s) catch return LoginError.LoginTimedOut,
    ) catch return LoginError.LoginTimedOut;
    var interval_ms: u64 = @intCast(@max(device.interval, 1) * std.time.ms_per_s);

    while (io_mod.milliTimestamp() < expires_at_ms) {
        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(15_000),
        });
        const result = try oauth.pollDeviceTokenBounded(
            alloc,
            transport,
            metadata,
            client_id,
            device.device_code,
            &cancel_flag,
            deadline,
        );
        switch (result) {
            .pending => {},
            .slow_down => interval_ms = std.math.mul(u64, interval_ms, 2) catch interval_ms,
            .success => |token| return token,
        }
        io_mod.sleep(interval_ms *| std.time.ns_per_ms);
        _ = poll_wait_slice_ms;
    }
    return LoginError.LoginTimedOut;
}

fn takeLoginSession(
    alloc: Allocator,
    issuer_url: []const u8,
    client_id: []const u8,
    token: *oauth.TokenSet,
    now_ms: i64,
) !grok_oauth_session.Session {
    const refresh_token = token.refresh_token orelse return LoginError.NoRefreshToken;
    const expires_at_ms = try oauth.expiry_timestamp_ms(now_ms, token.expires_in);
    const owned_issuer = try alloc.dupe(u8, issuer_url);
    errdefer alloc.free(owned_issuer);
    const owned_client_id = try alloc.dupe(u8, client_id);
    errdefer alloc.free(owned_client_id);

    const session = grok_oauth_session.Session{
        .issuer = owned_issuer,
        .client_id = owned_client_id,
        .access_token = token.access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .scope = token.scope,
        .token_type = token.token_type,
    };
    token.access_token = &.{};
    token.refresh_token = null;
    token.scope = &.{};
    token.token_type = &.{};
    return session;
}

fn revokeLogoutSession(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    session: grok_oauth_session.Session,
) !void {
    var metadata = try oauth.discover(alloc, transport, session.issuer);
    defer metadata.deinit(alloc);
    const endpoint = metadata.revocation_endpoint orelse return;
    try grok_oauth_session.validateE2EEndpoint(session.issuer, endpoint);
    oauth.revokeToken(
        alloc,
        transport,
        endpoint,
        session.client_id,
        session.refresh_token,
        .refresh_token,
    ) catch {};
    oauth.revokeToken(
        alloc,
        transport,
        endpoint,
        session.client_id,
        session.access_token,
        .access_token,
    ) catch {};
}

fn readGrokCliAuthFile(alloc: Allocator, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 64 * 1024);
}

pub fn parseGrokCliAuth(alloc: Allocator, bytes: []const u8, now_ms: i64) !grok_oauth_session.Session {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return LoginError.InvalidGrokCliAuth;
    defer parsed.deinit();
    if (parsed.value != .object) return LoginError.InvalidGrokCliAuth;
    const root = parsed.value.object;
    const object = if (root.get("oauth")) |nested|
        if (nested == .object) nested.object else return LoginError.InvalidGrokCliAuth
    else
        root;

    const access_token = requiredObjectString(object, "access_token") orelse
        return LoginError.InvalidGrokCliAuth;
    const refresh_token = requiredObjectString(object, "refresh_token") orelse
        return LoginError.InvalidGrokCliAuth;
    const client_id = requiredObjectString(object, "client_id") orelse grok_oauth_session.default_client_id;
    const issuer_value = requiredObjectString(object, "issuer") orelse grok_oauth_session.issuer;
    if (!grok_oauth_session.isFirstPartyIssuer(issuer_value) and
        !grok_oauth_session.isLoopbackE2EIssuer(issuer_value))
    {
        return LoginError.InvalidGrokCliAuth;
    }
    const scope = requiredObjectString(object, "scope") orelse grok_oauth_session.default_scope;
    const token_type = requiredObjectString(object, "token_type") orelse "Bearer";
    const expires_at_ms = expiresAtMs(object, now_ms);

    const owned_issuer = try alloc.dupe(u8, issuer_value);
    errdefer alloc.free(owned_issuer);
    const owned_client_id = try alloc.dupe(u8, client_id);
    errdefer alloc.free(owned_client_id);
    const owned_access = try alloc.dupe(u8, access_token);
    errdefer secret.zeroAndFree(alloc, owned_access);
    const owned_refresh = try alloc.dupe(u8, refresh_token);
    errdefer secret.zeroAndFree(alloc, owned_refresh);
    const owned_scope = try alloc.dupe(u8, scope);
    errdefer alloc.free(owned_scope);
    const owned_token_type = try alloc.dupe(u8, token_type);
    errdefer alloc.free(owned_token_type);

    return .{
        .issuer = owned_issuer,
        .client_id = owned_client_id,
        .access_token = owned_access,
        .refresh_token = owned_refresh,
        .expires_at_ms = expires_at_ms,
        .scope = owned_scope,
        .token_type = owned_token_type,
    };
}

fn expiresAtMs(object: std.json.ObjectMap, now_ms: i64) i64 {
    if (object.get("expires_at_ms")) |value| {
        if (value == .integer) return value.integer;
    }
    if (object.get("expires_at")) |value| {
        if (value == .integer) {
            if (value.integer > 1_000_000_000_000) return value.integer;
            return value.integer * std.time.ms_per_s;
        }
    }
    if (object.get("expires_in")) |value| {
        if (value == .integer) {
            return now_ms + (value.integer * std.time.ms_per_s);
        }
    }
    return now_ms + default_import_lifetime_ms;
}

fn requiredObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn persistGrokCredentialPreference(alloc: Allocator) void {
    var attempt = config_runtime.attemptUserPreferences(alloc, .{
        .credential_source = .grok_oauth,
        .model = model_catalog.grok_build_model_id,
    });
    defer attempt.deinit(alloc);
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

test "parse grok cli auth copies tokens without requiring fx fields" {
    const json =
        \\{"access_token":"cli-access","refresh_token":"cli-refresh","expires_at":2000,"client_id":"cli-client"}
    ;
    var session = try parseGrokCliAuth(std.testing.allocator, json, 0);
    defer session.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("cli-access", session.access_token);
    try std.testing.expectEqualStrings("cli-refresh", session.refresh_token);
    try std.testing.expectEqualStrings("cli-client", session.client_id);
    try std.testing.expectEqualStrings(grok_oauth_session.issuer, session.issuer);
    try std.testing.expectEqual(@as(i64, 2000 * std.time.ms_per_s), session.expires_at_ms);
}

test "parse grok cli auth rejects a missing refresh token" {
    try std.testing.expectError(
        LoginError.InvalidGrokCliAuth,
        parseGrokCliAuth(
            std.testing.allocator,
            "{\"access_token\":\"cli-access\"}",
            0,
        ),
    );
}

test "parse grok cli auth rejects a vercel issuer" {
    try std.testing.expectError(
        LoginError.InvalidGrokCliAuth,
        parseGrokCliAuth(
            std.testing.allocator,
            "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"issuer\":\"https://vercel.com\"}",
            0,
        ),
    );
}

var stable_grok_login_test_environ: ?*std.process.Environ.Map = null;

fn stableGrokLoginTestEnviron() !*const std.process.Environ.Map {
    if (stable_grok_login_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_grok_login_test_environ = map;
    return map;
}

test "grok login preference persists grok oauth and grok build model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io_mod.getIo(), "home");
    const home = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home);

    _ = try stableGrokLoginTestEnviron();
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("HOME", home);
    const previous = io_mod.environMap();
    io_mod.setEnvironMap(&map);
    defer io_mod.setEnvironMap(previous orelse stable_grok_login_test_environ.?);

    persistGrokCredentialPreference(std.testing.allocator);

    const settings_path = try std.fs.path.join(std.testing.allocator, &.{ home, ".fx", "settings.json" });
    defer std.testing.allocator.free(settings_path);
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), settings_path, .{});
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(std.testing.allocator, &file, 64 * 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.find(u8, bytes, "\"credential_source\":\"grok_oauth\"") != null);
    try std.testing.expect(std.mem.find(u8, bytes, "\"model\":\"xai/grok-4.6\"") != null);
}

test "grok login session requires a refresh token" {
    var token = oauth.TokenSet{
        .access_token = try std.testing.allocator.dupe(u8, "access"),
        .refresh_token = null,
        .expires_in = 60,
        .scope = try std.testing.allocator.dupe(u8, "openid"),
        .token_type = try std.testing.allocator.dupe(u8, "Bearer"),
    };
    defer token.deinit(std.testing.allocator);
    try std.testing.expectError(
        LoginError.NoRefreshToken,
        takeLoginSession(std.testing.allocator, grok_oauth_session.issuer, "client", &token, 0),
    );
}
