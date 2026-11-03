const std = @import("std");
const credentials = @import("credentials.zig");
const grok_session = @import("grok_session.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const login_flow = @import("login_flow.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const FormBody = oauth.FormBody;
const isLoopbackHttpUrl = oauth.isLoopbackHttpUrl;

const client_id = "b1a00492-073a-47ea-816f-4c329264a828";
const issuer_url = "https://auth.x.ai";
const discovery_path = "/.well-known/openid-configuration";
const device_code_url = "https://auth.x.ai/oauth2/device/code";
const token_url = "https://auth.x.ai/oauth2/token";
const userinfo_url = "https://auth.x.ai/oauth2/userinfo";
const revoke_url = "https://auth.x.ai/oauth2/revoke";
const e2e_device_code_url_env = "FX_E2E_GROK_DEVICE_CODE_URL";
const e2e_token_url_env = "FX_E2E_GROK_TOKEN_URL";
const e2e_issuer_url_env = "FX_E2E_GROK_ISSUER_URL";
const e2e_userinfo_url_env = "FX_E2E_GROK_USERINFO_URL";
const e2e_revoke_url_env = "FX_E2E_GROK_REVOKE_URL";
const device_scope = "openid profile email offline_access grok-cli:access api:access";

pub const RefreshMode = enum {
    if_needed,
    force,
    stored,
};

pub const Access = struct {
    access_token: []u8,
    account_id: []u8,
    refresh_after_ms: i64,

    pub fn deinit(self: *Access, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        alloc.free(self.account_id);
        self.* = undefined;
    }
};

const LoginContext = struct {
    transport: oauth_transport.Provider,
};

const PreparedDeviceLogin = struct {
    prepared: login_flow.PreparedLogin,
    context: *LoginContext,
};

/// xAI's device-code flow is the native login path. Its discovery document
/// intentionally only supplies the token endpoint; the device endpoint and
/// scope are part of xAI's CLI contract.
pub fn startSignIn(
    runtime: *login_flow.SignInRuntime,
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !bool {
    if (comptime host_target.is_wasm) return error.GrokOAuthUnavailable;
    try credentials.requireSignInStorage(.grok_subscription);
    const device = try prepareDeviceSignIn(alloc, transport);
    return runtime.startPrepared(
        alloc,
        device.prepared,
        .{
            .ctx = device.context,
            .deinit_ctx = deinitLoginContext,
            .oauth_transport = transport,
            .poll = .{ .poll_device_token = pollDeviceToken },
            .complete = completeSignIn,
            .save = saveSignIn,
        },
    );
}

fn prepareDeviceSignIn(alloc: Allocator, transport: oauth_transport.Provider) !PreparedDeviceLogin {
    const configured_issuer = try configuredEndpoint(alloc, e2e_issuer_url_env, issuer_url);
    var issuer_owned = true;
    errdefer if (issuer_owned) alloc.free(configured_issuer);
    const allow_loopback = isLoopbackHttpUrl(configured_issuer);

    const discovered_token_endpoint = try discoverTokenEndpoint(alloc, transport, configured_issuer, allow_loopback);
    defer alloc.free(discovered_token_endpoint);
    const configured_token_endpoint = try configuredEndpoint(alloc, e2e_token_url_env, discovered_token_endpoint);
    var token_owned = true;
    errdefer if (token_owned) alloc.free(configured_token_endpoint);
    const default_device_endpoint = if (allow_loopback)
        try alloc.print("{s}/oauth2/device/code", .{std.mem.trimEnd(u8, configured_issuer, "/")})
    else
        device_code_url;
    defer if (allow_loopback) alloc.free(default_device_endpoint);
    const configured_device_endpoint = try configuredEndpoint(alloc, e2e_device_code_url_env, default_device_endpoint);
    var device_endpoint_owned = true;
    errdefer if (device_endpoint_owned) alloc.free(configured_device_endpoint);
    validateAuthEndpoint(configured_token_endpoint, "token_endpoint", allow_loopback) catch
        return error.InvalidE2EGrokEndpoint;
    validateAuthEndpoint(configured_device_endpoint, "device_code_endpoint", allow_loopback) catch
        return error.InvalidE2EGrokEndpoint;

    var device = try requestDeviceAuthorization(
        alloc,
        transport,
        configured_device_endpoint,
        allow_loopback,
    );
    errdefer device.deinit(alloc);

    var metadata = oauth.Metadata{
        .issuer = configured_issuer,
        .device_authorization_endpoint = configured_device_endpoint,
        .token_endpoint = configured_token_endpoint,
    };
    issuer_owned = false;
    device_endpoint_owned = false;
    token_owned = false;
    errdefer metadata.deinit(alloc);

    const owned_client_id = try alloc.dupe(u8, client_id);
    errdefer alloc.free(owned_client_id);
    const context = try alloc.create(LoginContext);
    errdefer alloc.destroy(context);
    context.* = .{ .transport = transport };

    return .{
        .prepared = .{
            .metadata = metadata,
            .device = device,
            .client_id = owned_client_id,
        },
        .context = context,
    };
}

fn deinitLoginContext(raw: ?*anyopaque, alloc: Allocator) void {
    const context: *LoginContext = @ptrCast(@alignCast(raw.?));
    alloc.destroy(context);
}

fn pollDeviceToken(
    _: ?*anyopaque,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    client_id_value: []const u8,
    device_code: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    if (comptime host_target.is_wasm) return error.GrokOAuthUnavailable;
    return oauth.pollDeviceTokenBounded(
        alloc,
        transport,
        metadata,
        client_id_value,
        device_code,
        cancel_flag,
        deadline,
    ) catch |err| switch (err) {
        error.AuthorizationPending => .pending,
        error.SlowDown => .slow_down,
        else => err,
    };
}

fn completeSignIn(
    raw: ?*anyopaque,
    alloc: Allocator,
    _: []const u8,
    _: []const u8,
    token: *oauth.TokenSet,
) !login_flow.SignInCompletion {
    const context: *LoginContext = @ptrCast(@alignCast(raw.?));
    const refresh_token = token.refresh_token orelse return error.GrokRefreshTokenMissing;
    const account_id = try fetchAccountId(alloc, context.transport, token.access_token);
    errdefer alloc.free(account_id);
    const duration_ms = std.math.mul(i64, token.expires_in, std.time.ms_per_s) catch
        return error.InvalidGrokOAuthResponse;
    const expires_at_ms = std.math.add(i64, io_mod.milliTimestamp(), duration_ms) catch
        return error.InvalidGrokOAuthResponse;
    const completion: login_flow.SignInCompletion = .{ .grok = .{
        .access_token = token.access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
    } };
    token.access_token = &.{};
    token.refresh_token = null;
    return completion;
}

fn saveSignIn(_: ?*anyopaque, alloc: Allocator, completion: login_flow.SignInCompletion) !void {
    const session = switch (completion) {
        .grok => |session| session,
        .vercel, .chatgpt, .provider_key => return error.InvalidSignInCompletion,
    };
    try grok_session.saveNewSession(alloc, session);
}

pub fn runLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !void {
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    if (!try startSignIn(&runtime, alloc, transport)) return error.GrokLoginBusy;

    const authorization_url = (try runtime.browserUrlAlloc(alloc)) orelse
        return error.GrokAuthorizationUrlMissing;
    defer alloc.free(authorization_url);
    const snapshot = runtime.snapshot();
    try writeStdout("Open this URL to sign in with Grok:\n");
    try writeStdout(authorization_url);
    try writeStdout("\nCode: ");
    try writeStdout(snapshot.user_code);
    try writeStdout("\n\nWaiting for device authorization...\n");
    if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) {
        _ = url_opener.open(alloc, authorization_url) catch false;
    }

    while (true) {
        switch (runtime.pollTransition(alloc)) {
            .none => try io_mod.getIo().sleep(.fromMilliseconds(50), .awake),
            .succeeded => |completion| {
                var owned = completion;
                defer owned.deinit(alloc);
                return;
            },
            .failed => |err| return err,
            .cancelled => return error.Cancelled,
        }
    }
}

fn discoverTokenEndpoint(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    issuer: []const u8,
    allow_loopback: bool,
) ![]u8 {
    const url = try alloc.print("{s}{s}", .{ std.mem.trimEnd(u8, issuer, "/"), discovery_path });
    defer alloc.free(url);
    const bytes = try requestAccepted(alloc, transport, .get, url, &.{});
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return error.InvalidGrokOAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGrokOAuthResponse;
    const token_endpoint = try dupeRequiredString(alloc, parsed.value.object, "token_endpoint");
    errdefer alloc.free(token_endpoint);
    validateAuthEndpoint(token_endpoint, "token_endpoint", allow_loopback) catch
        return error.InvalidGrokOAuthResponse;
    return token_endpoint;
}

fn requestDeviceAuthorization(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint_url: []const u8,
    allow_loopback: bool,
) !oauth.DeviceAuthorization {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    var form: FormBody = .{};
    try form.append(&body.writer, "client_id", client_id);
    try form.append(&body.writer, "scope", device_scope);
    const bytes = try requestAccepted(alloc, transport, .post_form, endpoint_url, body.written());
    defer secret.zeroAndFree(alloc, bytes);
    var device = oauth.parseDeviceAuthorization(alloc, bytes) catch
        return error.InvalidGrokOAuthResponse;
    errdefer device.deinit(alloc);
    if (device.interval <= 0) return error.InvalidGrokOAuthResponse;
    validateAuthEndpoint(device.verification_uri, "verification_uri", allow_loopback) catch
        return error.InvalidGrokOAuthResponse;
    if (device.verification_uri_complete) |complete| {
        validateAuthEndpoint(complete, "verification_uri_complete", allow_loopback) catch
            return error.InvalidGrokOAuthResponse;
    }
    return device;
}

/// xAI auth endpoints must remain on the x.ai origin. Loopback HTTP is only
/// accepted for the explicit local E2E issuer override.
pub fn validateXAIEndpoint(url: []const u8, _: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidGrokEndpoint;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.user != null or uri.password != null) {
        return error.InvalidGrokEndpoint;
    }
    const host_component = uri.host orelse return error.InvalidGrokEndpoint;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const hostname = host_component.toRaw(&host_buf) catch return error.InvalidGrokEndpoint;
    if (!(std.ascii.eqlIgnoreCase(hostname, "x.ai") or
        (hostname.len > 5 and std.ascii.endsWithIgnoreCase(hostname, ".x.ai"))))
    {
        return error.InvalidGrokEndpoint;
    }
}

fn validateAuthEndpoint(url: []const u8, field: []const u8, allow_loopback: bool) !void {
    if (allow_loopback and isLoopbackHttpUrl(url)) return;
    try validateXAIEndpoint(url, field);
}

pub const LogoutResult = struct {
    deletion: grok_session.DeleteOutcome,
    revocation_failed: bool,
};

pub fn logout(alloc: Allocator, transport: oauth_transport.Provider) !LogoutResult {
    var mutation = (try grok_session.beginExistingMutation()) orelse return .{
        .deletion = .missing,
        .revocation_failed = false,
    };
    defer mutation.deinit();
    var revocation_failed = false;
    const loaded_session = mutation.load(alloc) catch |err| blk: {
        debug_trace.logf("auth", "Grok logout could not load the saved credential err={s}", .{@errorName(err)});
        revocation_failed = true;
        break :blk null;
    };
    if (loaded_session) |loaded| {
        var session = loaded;
        defer session.deinit(alloc);
        revokeToken(alloc, transport, session.refresh_token) catch {
            revocation_failed = true;
        };
    }
    return .{
        .deletion = try mutation.delete(),
        .revocation_failed = revocation_failed,
    };
}

pub fn sourceExists(alloc: Allocator) !bool {
    var session = (try grok_session.load(alloc)) orelse return false;
    defer session.deinit(alloc);
    return true;
}

pub fn loadAccess(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mode: RefreshMode,
) !?Access {
    if (mode == .stored) {
        var session = (try grok_session.load(alloc)) orelse return null;
        defer session.deinit(alloc);
        return takeAccess(&session);
    }

    var mutation = (try grok_session.beginExistingMutation()) orelse return null;
    defer mutation.deinit();
    var session = (try mutation.load(alloc)) orelse return null;
    defer session.deinit(alloc);

    if (mode == .force or session.expired(io_mod.milliTimestamp())) {
        try refreshSession(alloc, transport, &mutation, &session);
    }
    return takeAccess(&session);
}

fn takeAccess(session: *grok_session.Session) Access {
    const access_token = session.access_token;
    session.access_token = &.{};
    const account_id = session.account_id;
    session.account_id = &.{};
    return .{
        .access_token = access_token,
        .account_id = account_id,
        .refresh_after_ms = grok_session.refreshDeadlineMs(session.expires_at_ms),
    };
}

fn refreshSession(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mutation: *grok_session.Mutation,
    session: *grok_session.Session,
) !void {
    try mutation.requireWritable();
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    var form: FormBody = .{};
    try form.append(&body.writer, "grant_type", "refresh_token");
    try form.append(&body.writer, "client_id", client_id);
    try form.append(&body.writer, "refresh_token", session.refresh_token);
    var token = requestRefreshToken(alloc, transport, body.written()) catch |err| switch (err) {
        error.CredentialRefreshRejected,
        error.InvalidGrokOAuthResponse,
        => {
            debug_trace.logf("auth", "retiring terminal Grok session reason={s}", .{@errorName(err)});
            try retireRefreshSession(mutation);
            return error.CredentialRefreshRejected;
        },
        else => return err,
    };
    defer token.deinit(alloc);

    var replacement = refreshReplacement(alloc, transport, &token, session.*) catch |err| {
        if (err == error.OutOfMemory) return err;
        debug_trace.logf("auth", "retiring unusable Grok refresh reason={s}", .{@errorName(err)});
        try retireRefreshSession(mutation);
        if (err == error.GrokAccountChanged) return err;
        return error.CredentialRefreshRejected;
    };
    errdefer replacement.deinit(alloc);
    mutation.save(alloc, replacement) catch |err| {
        debug_trace.logf("auth", "retiring Grok session after refresh save failed err={s}", .{@errorName(err)});
        retireRefreshSession(mutation) catch |cleanup_err| {
            debug_trace.logf("auth", "Grok session retirement failed err={s}", .{@errorName(cleanup_err)});
        };
        return error.CredentialRefreshPersistenceUncertain;
    };

    session.deinit(alloc);
    session.* = replacement;
    replacement.access_token = &.{};
    replacement.refresh_token = &.{};
    replacement.account_id = &.{};
}

fn refreshReplacement(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    token: *RefreshTokenResponse,
    current: grok_session.Session,
) !grok_session.Session {
    const account_id = try fetchAccountId(alloc, transport, token.access_token);
    errdefer alloc.free(account_id);
    if (!std.mem.eql(u8, account_id, current.account_id)) {
        return error.GrokAccountChanged;
    }
    const refresh_token = if (token.refresh_token) |rotated|
        rotated
    else
        try alloc.dupe(u8, current.refresh_token);
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const expires_in = token.expires_in orelse return error.InvalidGrokOAuthResponse;
    const duration_ms = std.math.mul(i64, expires_in, std.time.ms_per_s) catch
        return error.InvalidGrokOAuthResponse;
    const expires_at_ms = std.math.add(i64, io_mod.milliTimestamp(), duration_ms) catch
        return error.InvalidGrokOAuthResponse;
    const replacement = grok_session.Session{
        .access_token = token.access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
    };
    token.access_token = &.{};
    if (token.refresh_token != null) token.refresh_token = null;
    return replacement;
}

fn retireRefreshSession(mutation: *grok_session.Mutation) !void {
    const outcome = mutation.delete() catch return error.CredentialRefreshPersistenceUncertain;
    if (outcome == .deleted_not_durable) return error.CredentialRefreshPersistenceUncertain;
}

const RefreshTokenResponse = struct {
    access_token: []u8,
    refresh_token: ?[]u8,
    expires_in: ?i64,

    fn deinit(self: *RefreshTokenResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        if (self.refresh_token) |token| secret.zeroAndFree(alloc, token);
        self.* = undefined;
    }
};

fn requestRefreshToken(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    payload: []const u8,
) !RefreshTokenResponse {
    const configured_issuer = try configuredEndpoint(alloc, e2e_issuer_url_env, issuer_url);
    defer alloc.free(configured_issuer);
    const allow_loopback = isLoopbackHttpUrl(configured_issuer);
    const discovered_endpoint = try discoverTokenEndpoint(alloc, transport, configured_issuer, allow_loopback);
    defer alloc.free(discovered_endpoint);
    const endpoint_url = try configuredEndpoint(alloc, e2e_token_url_env, discovered_endpoint);
    defer alloc.free(endpoint_url);
    validateAuthEndpoint(endpoint_url, "token_endpoint", allow_loopback) catch
        return error.InvalidE2EGrokEndpoint;
    var response = try transport.execute(alloc, .{
        .method = .post_form,
        .url = endpoint_url,
        .payload = payload,
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) {
        debug_trace.logf("auth", "Grok refresh request rejected", .{});
        if (std.mem.find(u8, response.body, "\"invalid_grant\"") != null) {
            return error.CredentialRefreshRejected;
        }
        return error.GrokOAuthRequestFailed;
    }
    const bytes = response.takeBody();
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGrokOAuthResponse;
    const object = parsed.value.object;
    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = if (object.get("refresh_token")) |value| blk: {
        if (value != .string or value.string.len == 0) return error.InvalidGrokOAuthResponse;
        break :blk try alloc.dupe(u8, value.string);
    } else null;
    errdefer if (refresh_token) |token| secret.zeroAndFree(alloc, token);
    const expires_in = if (object.get("expires_in")) |value| blk: {
        if (value != .integer or value.integer <= 0) return error.InvalidGrokOAuthResponse;
        break :blk value.integer;
    } else null;
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = expires_in,
    };
}

fn configuredEndpoint(alloc: Allocator, env_name: []const u8, default_url: []const u8) ![]u8 {
    return oauth.configuredEndpoint(alloc, env_name, default_url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidE2EGrokEndpoint,
    };
}

fn requestAccepted(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    method: oauth_transport.Method,
    url: []const u8,
    payload: []const u8,
) ![]u8 {
    return requestAcceptedWithBounds(alloc, transport, method, url, payload, null, null);
}

fn fetchAccountId(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    access_token: []const u8,
) ![]u8 {
    const endpoint_url = try configuredEndpoint(alloc, e2e_userinfo_url_env, userinfo_url);
    defer alloc.free(endpoint_url);
    const authorization = try alloc.print("Bearer {s}", .{access_token});
    defer secret.zeroAndFree(alloc, authorization);
    var response = try transport.execute(alloc, .{
        .method = .get,
        .url = endpoint_url,
        .authorization = authorization,
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) return error.GrokUserInfoRequestFailed;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response.body, .{}) catch
        return error.InvalidGrokUserInfoResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGrokUserInfoResponse;
    const account_id = dupeRequiredString(alloc, parsed.value.object, "sub") catch
        return error.InvalidGrokUserInfoResponse;
    errdefer alloc.free(account_id);
    if (!grok_session.validAccountId(account_id)) return error.InvalidGrokUserInfoResponse;
    return account_id;
}

fn revokeToken(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    token: []const u8,
) !void {
    const endpoint_url = try configuredEndpoint(alloc, e2e_revoke_url_env, revoke_url);
    defer alloc.free(endpoint_url);
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    var form: FormBody = .{};
    try form.append(&body.writer, "token", token);
    try form.append(&body.writer, "client_id", client_id);
    const bytes = try requestAccepted(alloc, transport, .post_form, endpoint_url, body.written());
    secret.zeroAndFree(alloc, bytes);
}

fn requestAcceptedWithBounds(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    method: oauth_transport.Method,
    url: []const u8,
    payload: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) ![]u8 {
    if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    var response = try transport.execute(alloc, .{
        .method = method,
        .url = url,
        .payload = payload,
        .cancel_flag = cancel_flag,
        .deadline = deadline,
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) {
        debug_trace.logf("auth", "Grok OAuth request rejected url={s}", .{url});
        return error.GrokOAuthRequestFailed;
    }
    return response.takeBody();
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidGrokOAuthResponse;
    if (value != .string or value.string.len == 0) return error.InvalidGrokOAuthResponse;
    return alloc.dupe(u8, value.string);
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

test "Grok E2E OAuth endpoint overrides accept only loopback HTTP" {
    try std.testing.expect(isLoopbackHttpUrl("http://127.0.0.1:1234/token"));
    try std.testing.expect(isLoopbackHttpUrl("http://localhost:1234/token"));
    try std.testing.expect(!isLoopbackHttpUrl("https://127.0.0.1:1234/token"));
    try std.testing.expect(!isLoopbackHttpUrl("http://example.com:1234/token"));
}

test "Grok account identity comes from authenticated userinfo" {
    const State = struct {
        authorization_seen: bool = false,

        fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.authorization_seen = std.mem.eql(u8, request.authorization orelse "", "Bearer access-token");
            return .{ .disposition = .accepted, .body = try alloc.dupe(u8, "{\"sub\":\"acct_test\"}") };
        }
    };
    var state = State{};
    const account_id = try fetchAccountId(
        std.testing.allocator,
        .{ .context = &state, .execute_fn = State.execute },
        "access-token",
    );
    defer std.testing.allocator.free(account_id);
    try std.testing.expect(state.authorization_seen);
    try std.testing.expectEqualStrings("acct_test", account_id);
}

test "Grok account identity rejects unsafe userinfo bytes" {
    const State = struct {
        fn execute(_: ?*anyopaque, alloc: Allocator, _: oauth_transport.Request) !oauth_transport.Response {
            return .{ .disposition = .accepted, .body = try alloc.dupe(u8, "{\"sub\":\"acct\\ninjected\"}") };
        }
    };
    try std.testing.expectError(
        error.InvalidGrokUserInfoResponse,
        fetchAccountId(
            std.testing.allocator,
            .{ .execute_fn = State.execute },
            "access-token",
        ),
    );
}

test "Grok refresh uses form encoding and accepts omitted token rotation" {
    const State = struct {
        method: ?oauth_transport.Method = null,
        payload: [512]u8 = undefined,
        payload_len: usize = 0,

        fn execute(
            raw: ?*anyopaque,
            alloc: Allocator,
            request: oauth_transport.Request,
        ) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const payload = request.payload orelse &.{};
            self.method = request.method;
            self.payload_len = @min(payload.len, self.payload.len);
            @memcpy(self.payload[0..self.payload_len], payload[0..self.payload_len]);
            const body = if (request.method == .get)
                "{\"token_endpoint\":\"https://auth.x.ai/oauth2/token\"}"
            else
                "{\"access_token\":\"new-access\",\"expires_in\":3600}";
            return .{
                .disposition = .accepted,
                .body = try alloc.dupe(u8, body),
            };
        }
    };
    var state = State{};
    var response = try requestRefreshToken(
        std.testing.allocator,
        .{ .context = &state, .execute_fn = State.execute },
        "client_id=client&grant_type=refresh_token&refresh_token=refresh",
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(oauth_transport.Method.post_form, state.method.?);
    try std.testing.expect(std.mem.find(u8, state.payload[0..state.payload_len], "grant_type=refresh_token") != null);
    try std.testing.expect(response.refresh_token == null);
    try std.testing.expectEqual(@as(?i64, 3600), response.expires_in);
}

test "Grok device authorization sends the CLI scope" {
    const State = struct {
        method: ?oauth_transport.Method = null,
        url: ?[]u8 = null,
        payload: [512]u8 = undefined,
        payload_len: usize = 0,

        fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.method = request.method;
            self.url = try alloc.dupe(u8, request.url);
            const payload = request.payload orelse &.{};
            self.payload_len = payload.len;
            @memcpy(self.payload[0..payload.len], payload);
            return .{
                .disposition = .accepted,
                .body = try alloc.dupe(u8, "{\"device_code\":\"device\",\"user_code\":\"CODE\",\"verification_uri\":\"https://x.ai/device\",\"verification_uri_complete\":\"https://x.ai/device?code=CODE\",\"expires_in\":600,\"interval\":5}"),
            };
        }
    };
    var state = State{};
    defer if (state.url) |url| std.testing.allocator.free(url);
    var device = try requestDeviceAuthorization(
        std.testing.allocator,
        .{ .context = &state, .execute_fn = State.execute },
        device_code_url,
        false,
    );
    defer device.deinit(std.testing.allocator);
    try std.testing.expectEqual(oauth_transport.Method.post_form, state.method.?);
    try std.testing.expectEqualStrings(device_code_url, state.url.?);
    try std.testing.expectEqualStrings(
        "client_id=b1a00492-073a-47ea-816f-4c329264a828&scope=openid%20profile%20email%20offline_access%20grok-cli%3Aaccess%20api%3Aaccess",
        state.payload[0..state.payload_len],
    );
    try std.testing.expectEqualStrings("CODE", device.user_code);
    try std.testing.expectEqualStrings("https://x.ai/device?code=CODE", device.verification_uri_complete.?);
}

test "Grok endpoint validation rejects non xAI origins" {
    try validateXAIEndpoint("https://auth.x.ai/oauth2/token", "token_endpoint");
    try std.testing.expectError(error.InvalidGrokEndpoint, validateXAIEndpoint("http://auth.x.ai/token", "token_endpoint"));
    try std.testing.expectError(error.InvalidGrokEndpoint, validateXAIEndpoint("https://example.com/token", "token_endpoint"));
}
