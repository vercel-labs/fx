const std = @import("std");
const chatgpt_session = @import("chatgpt_session.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const login_flow = @import("login_flow.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const token_url = "https://auth.openai.com/oauth/token";
pub const device_user_code_url = "https://auth.openai.com/api/accounts/deviceauth/usercode";
pub const device_token_url = "https://auth.openai.com/api/accounts/deviceauth/token";
pub const device_verification_uri = "https://auth.openai.com/codex/device";
pub const device_redirect_uri = "https://auth.openai.com/deviceauth/callback";
pub const device_code_timeout_seconds: i64 = 15 * 60;
const e2e_device_user_code_url_env = "FX_E2E_CHATGPT_DEVICE_USER_CODE_URL";
const e2e_device_token_url_env = "FX_E2E_CHATGPT_DEVICE_TOKEN_URL";
const e2e_token_url_env = "FX_E2E_CHATGPT_TOKEN_URL";
const jwt_auth_claim = "https://api.openai.com/auth";

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

const DeviceAuthorization = struct {
    device_auth_id: []u8,
    user_code: []u8,
    interval_seconds: i64,

    fn deinit(self: *DeviceAuthorization, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.device_auth_id);
        alloc.free(self.user_code);
        self.* = undefined;
    }
};

const DeviceToken = struct {
    authorization_code: []u8,
    code_verifier: []u8,

    fn deinit(self: *DeviceToken, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.authorization_code);
        secret.zeroAndFree(alloc, self.code_verifier);
        self.* = undefined;
    }
};

const TokenSet = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires_in: i64,

    fn deinit(self: *TokenSet, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        self.* = undefined;
    }
};

pub fn startSignIn(
    runtime: *login_flow.SignInRuntime,
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !bool {
    return runtime.startPrepared(
        alloc,
        try prepareSignIn(alloc, transport),
        .{
            .oauth_transport = transport,
            .poll = .{ .poll_device_token = pollSignInDeviceToken },
            .complete = completeSignIn,
            .save = saveSignIn,
        },
    );
}

fn prepareSignIn(
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !login_flow.PreparedLogin {
    const user_code_endpoint = try configuredEndpoint(alloc, e2e_device_user_code_url_env, device_user_code_url);
    defer alloc.free(user_code_endpoint);
    const device_token_endpoint = try configuredEndpoint(alloc, e2e_device_token_url_env, device_token_url);
    errdefer alloc.free(device_token_endpoint);
    const configured_token_endpoint = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
    errdefer alloc.free(configured_token_endpoint);
    var device = try requestDeviceAuthorizationAt(alloc, transport, user_code_endpoint);
    defer device.deinit(alloc);

    var poll_payload: std.Io.Writer.Allocating = .init(alloc);
    defer poll_payload.deinit();
    try poll_payload.writer.writeAll("{\"device_auth_id\":");
    try std.json.Stringify.value(device.device_auth_id, .{}, &poll_payload.writer);
    try poll_payload.writer.writeAll(",\"user_code\":");
    try std.json.Stringify.value(device.user_code, .{}, &poll_payload.writer);
    try poll_payload.writer.writeByte('}');

    const issuer = try alloc.dupe(u8, "https://auth.openai.com");
    errdefer alloc.free(issuer);
    const device_endpoint = device_token_endpoint;
    const owned_token_url = configured_token_endpoint;
    const device_code = try poll_payload.toOwnedSlice();
    errdefer secret.zeroAndFree(alloc, device_code);
    const user_code = device.user_code;
    device.user_code = &.{};
    errdefer alloc.free(user_code);
    const verification_uri = try alloc.dupe(u8, device_verification_uri);
    errdefer alloc.free(verification_uri);
    const owned_client_id = try alloc.dupe(u8, client_id);
    errdefer alloc.free(owned_client_id);

    return .{
        .metadata = .{
            .issuer = issuer,
            .device_authorization_endpoint = device_endpoint,
            .token_endpoint = owned_token_url,
        },
        .device = .{
            .device_code = device_code,
            .user_code = user_code,
            .verification_uri = verification_uri,
            .expires_in = device_code_timeout_seconds,
            .interval = device.interval_seconds,
        },
        .client_id = owned_client_id,
    };
}

fn pollSignInDeviceToken(
    _: ?*anyopaque,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    _: []const u8,
    poll_payload: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = metadata.device_authorization_endpoint,
        .payload = poll_payload,
        .cancel_flag = cancel_flag,
        .deadline = deadline,
    });
    defer response.deinit(alloc);
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (response.disposition != .accepted) {
        return switch (devicePollDisposition(alloc, response.body)) {
            .pending => .pending,
            .slow_down => .slow_down,
            .failed => error.ChatGptAuthorizationFailed,
        };
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidChatGptOAuthResponse;
    const authorization_code = try dupeRequiredString(alloc, parsed.value.object, "authorization_code");
    defer secret.zeroAndFree(alloc, authorization_code);
    const code_verifier = try dupeRequiredString(alloc, parsed.value.object, "code_verifier");
    defer secret.zeroAndFree(alloc, code_verifier);
    var token = try exchangeAuthorizationCodeBounded(
        alloc,
        transport,
        metadata.token_endpoint,
        authorization_code,
        code_verifier,
        cancel_flag,
        deadline,
    );
    errdefer token.deinit(alloc);
    const scope = try alloc.dupe(u8, "");
    errdefer alloc.free(scope);
    const token_type = try alloc.dupe(u8, "Bearer");
    errdefer alloc.free(token_type);
    const access_token = token.access_token;
    token.access_token = &.{};
    const refresh_token = token.refresh_token;
    token.refresh_token = &.{};
    return .{ .success = .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = token.expires_in,
        .scope = scope,
        .token_type = token_type,
    } };
}

fn completeSignIn(
    _: ?*anyopaque,
    alloc: Allocator,
    _: []const u8,
    _: []const u8,
    token: *oauth.TokenSet,
) !login_flow.SignInCompletion {
    const refresh_token = token.refresh_token orelse return error.ChatGptRefreshTokenMissing;
    const account_id = try extractAccountId(alloc, token.access_token);
    errdefer alloc.free(account_id);
    const duration_ms = std.math.mul(i64, token.expires_in, std.time.ms_per_s) catch
        return error.InvalidChatGptOAuthResponse;
    const expires_at_ms = std.math.add(i64, io_mod.milliTimestamp(), duration_ms) catch
        return error.InvalidChatGptOAuthResponse;
    const completion: login_flow.SignInCompletion = .{ .chatgpt = .{
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
        .chatgpt => |session| session,
        .vercel => return error.InvalidSignInCompletion,
    };
    try chatgpt_session.saveNewSession(alloc, session);
}

pub fn runLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !void {
    const user_code_endpoint = try configuredEndpoint(alloc, e2e_device_user_code_url_env, device_user_code_url);
    defer alloc.free(user_code_endpoint);
    const configured_device_token_endpoint = try configuredEndpoint(alloc, e2e_device_token_url_env, device_token_url);
    defer alloc.free(configured_device_token_endpoint);
    const configured_token_endpoint = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
    defer alloc.free(configured_token_endpoint);
    var device = try requestDeviceAuthorizationAt(alloc, transport, user_code_endpoint);
    defer device.deinit(alloc);

    try writeStdout("Open ");
    try writeStdout(device_verification_uri);
    try writeStdout("\nCode: ");
    try writeStdout(device.user_code);
    try writeStdout("\n\nWaiting for ChatGPT authorization...\n");
    if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) {
        _ = url_opener.open(alloc, device_verification_uri) catch false;
    }

    var device_token = try pollDeviceAuthorizationAt(
        alloc,
        transport,
        configured_device_token_endpoint,
        device,
    );
    defer device_token.deinit(alloc);
    var token = try exchangeAuthorizationCodeAt(
        alloc,
        transport,
        configured_token_endpoint,
        device_token.authorization_code,
        device_token.code_verifier,
    );
    defer token.deinit(alloc);

    var session = try sessionFromToken(alloc, &token, io_mod.milliTimestamp());
    defer session.deinit(alloc);
    try chatgpt_session.saveNewSession(alloc, session);
    try writeStdout("Signed in with ChatGPT.\n");
}

pub fn logout() !chatgpt_session.DeleteOutcome {
    var mutation = (try chatgpt_session.beginExistingMutation()) orelse return .missing;
    defer mutation.deinit();
    return mutation.delete();
}

pub fn sourceExists(alloc: Allocator) !bool {
    var session = (try chatgpt_session.load(alloc)) orelse return false;
    defer session.deinit(alloc);
    return true;
}

pub fn loadAccess(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mode: RefreshMode,
) !?Access {
    if (mode == .stored) {
        var session = (try chatgpt_session.load(alloc)) orelse return null;
        defer session.deinit(alloc);
        return takeAccess(&session);
    }

    var mutation = (try chatgpt_session.beginExistingMutation()) orelse return null;
    defer mutation.deinit();
    var session = (try mutation.load(alloc)) orelse return null;
    defer session.deinit(alloc);

    if (mode == .force or session.expired(io_mod.milliTimestamp())) {
        try refreshSession(alloc, transport, &mutation, &session);
    }
    return takeAccess(&session);
}

fn takeAccess(session: *chatgpt_session.Session) Access {
    const access_token = session.access_token;
    session.access_token = &.{};
    const account_id = session.account_id;
    session.account_id = &.{};
    return .{
        .access_token = access_token,
        .account_id = account_id,
        .refresh_after_ms = chatgpt_session.refreshDeadlineMs(session.expires_at_ms),
    };
}

fn refreshSession(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mutation: *chatgpt_session.Mutation,
    session: *chatgpt_session.Session,
) !void {
    var form: FormBody = .{};
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    try form.append(&body.writer, "grant_type", "refresh_token");
    try form.append(&body.writer, "refresh_token", session.refresh_token);
    try form.append(&body.writer, "client_id", client_id);
    var token = try requestToken(alloc, transport, body.written());
    defer token.deinit(alloc);

    var replacement = try sessionFromToken(alloc, &token, io_mod.milliTimestamp());
    errdefer replacement.deinit(alloc);
    try mutation.save(alloc, replacement);

    session.deinit(alloc);
    session.* = replacement;
    replacement.access_token = &.{};
    replacement.refresh_token = &.{};
    replacement.account_id = &.{};
}

fn requestDeviceAuthorization(alloc: Allocator, transport: oauth_transport.Provider) !DeviceAuthorization {
    return requestDeviceAuthorizationAt(alloc, transport, device_user_code_url);
}

fn requestDeviceAuthorizationAt(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint_url: []const u8,
) !DeviceAuthorization {
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll("{\"client_id\":");
    try std.json.Stringify.value(client_id, .{}, &payload.writer);
    try payload.writer.writeByte('}');

    const bytes = try requestAccepted(alloc, transport, .post_json, endpoint_url, payload.written());
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidChatGptOAuthResponse;
    const object = parsed.value.object;
    const device_auth_id = try dupeRequiredString(alloc, object, "device_auth_id");
    errdefer secret.zeroAndFree(alloc, device_auth_id);
    const user_code = try dupeRequiredString(alloc, object, "user_code");
    errdefer alloc.free(user_code);
    return .{
        .device_auth_id = device_auth_id,
        .user_code = user_code,
        .interval_seconds = try flexiblePositiveInteger(object, "interval"),
    };
}

fn pollDeviceAuthorization(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    device: DeviceAuthorization,
) !DeviceToken {
    return pollDeviceAuthorizationAt(alloc, transport, device_token_url, device);
}

fn pollDeviceAuthorizationAt(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint_url: []const u8,
    device: DeviceAuthorization,
) !DeviceToken {
    const started_ms = io_mod.milliTimestamp();
    const timeout_ms = device_code_timeout_seconds * std.time.ms_per_s;
    var interval_seconds = @max(device.interval_seconds, 1);
    while (io_mod.milliTimestamp() - started_ms < timeout_ms) {
        var payload: std.Io.Writer.Allocating = .init(alloc);
        defer payload.deinit();
        try payload.writer.writeAll("{\"device_auth_id\":");
        try std.json.Stringify.value(device.device_auth_id, .{}, &payload.writer);
        try payload.writer.writeAll(",\"user_code\":");
        try std.json.Stringify.value(device.user_code, .{}, &payload.writer);
        try payload.writer.writeByte('}');

        var response = try transport.execute(alloc, .{
            .method = .post_json,
            .url = endpoint_url,
            .payload = payload.written(),
        });
        defer response.deinit(alloc);
        if (response.disposition == .accepted) {
            var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response.body, .{});
            defer parsed.deinit();
            if (parsed.value != .object) return error.InvalidChatGptOAuthResponse;
            const authorization_code = try dupeRequiredString(alloc, parsed.value.object, "authorization_code");
            errdefer secret.zeroAndFree(alloc, authorization_code);
            return .{
                .authorization_code = authorization_code,
                .code_verifier = try dupeRequiredString(alloc, parsed.value.object, "code_verifier"),
            };
        }
        switch (devicePollDisposition(alloc, response.body)) {
            .pending => {},
            .slow_down => interval_seconds += 5,
            .failed => return error.ChatGptAuthorizationFailed,
        }
        io_mod.sleep(@as(u64, @intCast(interval_seconds)) * std.time.ns_per_s);
    }
    return error.ChatGptLoginTimedOut;
}

const PollDisposition = enum { pending, slow_down, failed };

fn devicePollDisposition(alloc: Allocator, bytes: []const u8) PollDisposition {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return .pending;
    defer parsed.deinit();
    if (parsed.value != .object) return .pending;
    const value = parsed.value.object.get("error") orelse return .pending;
    const code = switch (value) {
        .string => value.string,
        .object => object: {
            const nested = value.object.get("code") orelse return .failed;
            if (nested != .string) return .failed;
            break :object nested.string;
        },
        else => return .failed,
    };
    if (std.mem.eql(u8, code, "deviceauth_authorization_pending") or
        std.mem.eql(u8, code, "authorization_pending")) return .pending;
    if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
    return .failed;
}

fn exchangeAuthorizationCode(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    authorization_code: []const u8,
    code_verifier: []const u8,
) !TokenSet {
    return exchangeAuthorizationCodeAt(
        alloc,
        transport,
        token_url,
        authorization_code,
        code_verifier,
    );
}

fn exchangeAuthorizationCodeAt(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint_url: []const u8,
    authorization_code: []const u8,
    code_verifier: []const u8,
) !TokenSet {
    return exchangeAuthorizationCodeWithBounds(
        alloc,
        transport,
        endpoint_url,
        authorization_code,
        code_verifier,
        null,
        null,
    );
}

fn exchangeAuthorizationCodeBounded(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint_url: []const u8,
    authorization_code: []const u8,
    code_verifier: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !TokenSet {
    return exchangeAuthorizationCodeWithBounds(
        alloc,
        transport,
        endpoint_url,
        authorization_code,
        code_verifier,
        cancel_flag,
        deadline,
    );
}

fn exchangeAuthorizationCodeWithBounds(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint_url: []const u8,
    authorization_code: []const u8,
    code_verifier: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) !TokenSet {
    var form: FormBody = .{};
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    try form.append(&body.writer, "grant_type", "authorization_code");
    try form.append(&body.writer, "client_id", client_id);
    try form.append(&body.writer, "code", authorization_code);
    try form.append(&body.writer, "code_verifier", code_verifier);
    try form.append(&body.writer, "redirect_uri", device_redirect_uri);
    return requestTokenAtWithBounds(alloc, transport, endpoint_url, body.written(), cancel_flag, deadline);
}

fn requestToken(alloc: Allocator, transport: oauth_transport.Provider, payload: []const u8) !TokenSet {
    const endpoint_url = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
    defer alloc.free(endpoint_url);
    return requestTokenAtWithBounds(alloc, transport, endpoint_url, payload, null, null);
}

fn requestTokenAtWithBounds(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint_url: []const u8,
    payload: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) !TokenSet {
    const bytes = try requestAcceptedWithBounds(
        alloc,
        transport,
        .post_form,
        endpoint_url,
        payload,
        cancel_flag,
        deadline,
    );
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidChatGptOAuthResponse;
    const object = parsed.value.object;
    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequiredString(alloc, object, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = try requiredPositiveInteger(object, "expires_in"),
    };
}

fn configuredEndpoint(alloc: Allocator, env_name: []const u8, default_url: []const u8) ![]u8 {
    const candidate = io_mod.getenv(env_name) orelse default_url;
    if (io_mod.getenv(env_name) != null and !isLoopbackHttpUrl(candidate)) {
        return error.InvalidE2EChatGptEndpoint;
    }
    return alloc.dupe(u8, candidate);
}

fn isLoopbackHttpUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port == null)
    {
        return false;
    }
    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host_name, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host_name, "localhost") or
        std.mem.eql(u8, host_name, "[::1]");
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
        debug_trace.logf("auth", "ChatGPT OAuth request rejected url={s}", .{url});
        return error.ChatGptOAuthRequestFailed;
    }
    return response.takeBody();
}

fn sessionFromToken(alloc: Allocator, token: *TokenSet, now_ms: i64) !chatgpt_session.Session {
    const account_id = try extractAccountId(alloc, token.access_token);
    errdefer alloc.free(account_id);
    const duration_ms = std.math.mul(i64, token.expires_in, std.time.ms_per_s) catch
        return error.InvalidChatGptOAuthResponse;
    const expires_at_ms = std.math.add(i64, now_ms, duration_ms) catch
        return error.InvalidChatGptOAuthResponse;
    const session = chatgpt_session.Session{
        .access_token = token.access_token,
        .refresh_token = token.refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
    };
    token.access_token = &.{};
    token.refresh_token = &.{};
    return session;
}

pub fn extractAccountId(alloc: Allocator, token: []const u8) ![]u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidChatGptAccessToken;
    const payload = parts.next() orelse return error.InvalidChatGptAccessToken;
    _ = parts.next() orelse return error.InvalidChatGptAccessToken;
    if (parts.next() != null) return error.InvalidChatGptAccessToken;

    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch
        return error.InvalidChatGptAccessToken;
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch
        return error.InvalidChatGptAccessToken;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, decoded, .{}) catch
        return error.InvalidChatGptAccessToken;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidChatGptAccessToken;
    const claim = parsed.value.object.get(jwt_auth_claim) orelse return error.InvalidChatGptAccessToken;
    if (claim != .object) return error.InvalidChatGptAccessToken;
    return dupeRequiredString(alloc, claim.object, "chatgpt_account_id") catch
        return error.InvalidChatGptAccessToken;
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidChatGptOAuthResponse;
    if (value != .string or value.string.len == 0) return error.InvalidChatGptOAuthResponse;
    return alloc.dupe(u8, value.string);
}

fn requiredPositiveInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidChatGptOAuthResponse;
    if (value != .integer or value.integer <= 0) return error.InvalidChatGptOAuthResponse;
    return value.integer;
}

fn flexiblePositiveInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidChatGptOAuthResponse;
    const result = switch (value) {
        .integer => value.integer,
        .string => std.fmt.parseInt(i64, std.mem.trim(u8, value.string, " \t\r\n"), 10) catch
            return error.InvalidChatGptOAuthResponse,
        else => return error.InvalidChatGptOAuthResponse,
    };
    if (result < 0) return error.InvalidChatGptOAuthResponse;
    return result;
}

const FormBody = struct {
    first: bool = true,

    fn append(self: *FormBody, writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
        if (!self.first) try writer.writeByte('&');
        self.first = false;
        try percentEncode(writer, key);
        try writer.writeByte('=');
        try percentEncode(writer, value);
    }
};

fn percentEncode(writer: *std.Io.Writer, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        const safe = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (safe) {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn writeStdout(text: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io_mod.getIo(), &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

test "ChatGPT E2E OAuth endpoint overrides accept only loopback HTTP" {
    try std.testing.expect(isLoopbackHttpUrl("http://127.0.0.1:1234/token"));
    try std.testing.expect(isLoopbackHttpUrl("http://localhost:1234/token"));
    try std.testing.expect(!isLoopbackHttpUrl("https://127.0.0.1:1234/token"));
    try std.testing.expect(!isLoopbackHttpUrl("http://example.com:1234/token"));
}

test "ChatGPT account id is extracted from the namespaced JWT claim" {
    const alloc = std.testing.allocator;
    const payload =
        \\{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_test"}}
    ;
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(payload.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    const token = try std.fmt.allocPrint(alloc, "header.{s}.signature", .{encoded});
    defer alloc.free(token);

    const account_id = try extractAccountId(alloc, token);
    defer alloc.free(account_id);
    try std.testing.expectEqualStrings("acct_test", account_id);
}

test "ChatGPT device polling recognizes pending and slow down errors" {
    try std.testing.expectEqual(PollDisposition.pending, devicePollDisposition(
        std.testing.allocator,
        "{\"error\":{\"code\":\"deviceauth_authorization_pending\"}}",
    ));
    try std.testing.expectEqual(PollDisposition.slow_down, devicePollDisposition(
        std.testing.allocator,
        "{\"error\":\"slow_down\"}",
    ));
    try std.testing.expectEqual(PollDisposition.failed, devicePollDisposition(
        std.testing.allocator,
        "{\"error\":\"access_denied\"}",
    ));
}

const SignInTestMode = enum { success, block_until_cancel };

const SignInTestState = struct {
    mode: SignInTestMode,
    poll_started: std.atomic.Value(bool) = .init(false),
    save_count: std.atomic.Value(usize) = .init(0),

    fn provider(self: *@This()) oauth_transport.Provider {
        return .{ .context = self, .execute_fn = execute };
    }

    fn execute(
        raw: ?*anyopaque,
        alloc: Allocator,
        request: oauth_transport.Request,
    ) !oauth_transport.Response {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (std.mem.eql(u8, request.url, device_user_code_url)) {
            return .{
                .disposition = .accepted,
                .body = try alloc.dupe(u8, "{\"device_auth_id\":\"device-id\",\"user_code\":\"CHAT-CODE\",\"interval\":0}"),
            };
        }
        if (std.mem.eql(u8, request.url, device_token_url)) {
            self.poll_started.store(true, .seq_cst);
            if (self.mode == .block_until_cancel) {
                const cancel = request.cancel_flag orelse return error.TestExpectedCancelFlag;
                while (!cancel.load(.seq_cst)) io_mod.sleep(std.time.ns_per_ms);
                return error.Cancelled;
            }
            return .{
                .disposition = .accepted,
                .body = try alloc.dupe(u8, "{\"authorization_code\":\"code\",\"code_verifier\":\"verifier\"}"),
            };
        }
        if (std.mem.eql(u8, request.url, token_url)) {
            const token = try testAccessToken(alloc, "acct_runtime");
            defer alloc.free(token);
            return .{
                .disposition = .accepted,
                .body = try std.fmt.allocPrint(
                    alloc,
                    "{{\"access_token\":\"{s}\",\"refresh_token\":\"refresh\",\"expires_in\":3600}}",
                    .{token},
                ),
            };
        }
        return error.TestUnexpectedEndpoint;
    }

    fn save(raw: ?*anyopaque, _: Allocator, completion: login_flow.SignInCompletion) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        switch (completion) {
            .chatgpt => {},
            .vercel => return error.TestUnexpectedCompletion,
        }
        _ = self.save_count.fetchAdd(1, .seq_cst);
    }
};

fn testAccessToken(alloc: Allocator, account_id: []const u8) ![]u8 {
    const payload = try std.fmt.allocPrint(
        alloc,
        "{{\"https://api.openai.com/auth\":{{\"chatgpt_account_id\":\"{s}\"}}}}",
        .{account_id},
    );
    defer alloc.free(payload);
    const encoded = try alloc.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(payload.len));
    defer alloc.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    return std.fmt.allocPrint(alloc, "header.{s}.signature", .{encoded});
}

fn waitForSignIn(
    runtime: *login_flow.SignInRuntime,
    alloc: Allocator,
    timeout_ms: usize,
) login_flow.SignInTransition {
    for (0..timeout_ms) |_| {
        const transition = runtime.pollTransition(alloc);
        if (transition != .none) return transition;
        io_mod.sleep(std.time.ns_per_ms);
    }
    return .none;
}

test "ChatGPT sign-in uses the shared rendered runtime and publishes a saved completion" {
    const alloc = std.testing.allocator;
    var state = SignInTestState{ .mode = .success };
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    const transport = state.provider();
    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try prepareSignIn(alloc, transport),
        .{
            .ctx = &state,
            .oauth_transport = transport,
            .poll = .{ .poll_device_token = pollSignInDeviceToken },
            .complete = completeSignIn,
            .save = SignInTestState.save,
        },
    ));

    const snapshot = runtime.snapshot();
    try std.testing.expectEqualStrings(device_verification_uri, snapshot.verification_uri);
    try std.testing.expectEqualStrings("CHAT-CODE", snapshot.user_code);
    var transition = waitForSignIn(&runtime, alloc, 1000);
    switch (transition) {
        .succeeded => |*completion| {
            switch (completion.*) {
                .chatgpt => |session| try std.testing.expectEqualStrings("acct_runtime", session.account_id),
                .vercel => return error.TestUnexpectedCompletion,
            }
            completion.deinit(alloc);
        },
        else => return error.TestExpectedSuccessfulSignIn,
    }
    try std.testing.expectEqual(@as(usize, 1), state.save_count.load(.seq_cst));
}

test "ChatGPT shared sign-in cancellation saves no session" {
    const alloc = std.testing.allocator;
    var state = SignInTestState{ .mode = .block_until_cancel };
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    const transport = state.provider();
    try std.testing.expect(try runtime.startPrepared(
        alloc,
        try prepareSignIn(alloc, transport),
        .{
            .ctx = &state,
            .oauth_transport = transport,
            .poll = .{ .poll_device_token = pollSignInDeviceToken },
            .complete = completeSignIn,
            .save = SignInTestState.save,
        },
    ));
    for (0..500) |_| {
        if (state.poll_started.load(.seq_cst)) break;
        io_mod.sleep(std.time.ns_per_ms);
    }
    try std.testing.expect(state.poll_started.load(.seq_cst));
    try std.testing.expect(runtime.cancel(alloc));
    try std.testing.expectEqual(login_flow.SignInTransition.cancelled, runtime.pollTransition(alloc));
    try std.testing.expectEqual(@as(usize, 0), state.save_count.load(.seq_cst));
}
