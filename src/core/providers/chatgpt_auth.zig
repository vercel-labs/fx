const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const pkce = @import("../auth/pkce.zig");
const pkce_loopback = @import("../auth/pkce_loopback.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");
const session_store = @import("session_store.zig");

const Allocator = std.mem.Allocator;

pub const issuer = "https://auth.openai.com";
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const default_scope = "openid profile email offline_access";
pub const callback_path = "/auth/callback";
pub const production_callback_host = "localhost";
pub const production_callback_port: u16 = 1455;
pub const default_responses_url = "https://chatgpt.com/backend-api/codex/responses";
pub const e2e_issuer_url_env = "FX_E2E_CHATGPT_ISSUER_URL";
pub const e2e_responses_url_env = "FX_E2E_CHATGPT_RESPONSES_URL";
pub const no_open_browser_env = "FX_NO_OPEN_BROWSER";
pub const missing_session_message =
    "Fx needs a ChatGPT subscription login. Run fx login chatgpt.";
pub const missing_interactive_session_message =
    "Fx needs a ChatGPT subscription login. Run /login chatgpt.";

const request_timeout_seconds: i64 = 30;
const max_document_bytes: usize = 256 * 1024;

pub const Session = session_store.Session;

pub fn configuredIssuerUrl() ![]const u8 {
    return selectIssuerUrl(io_mod.getenv(e2e_issuer_url_env));
}

pub fn configuredResponsesUrl() []const u8 {
    if (trimmedEnv(e2e_responses_url_env)) |value| {
        if (isLoopbackHttpUrl(value, false)) return value;
    }
    return default_responses_url;
}

pub fn isLoopbackE2EIssuer(url: []const u8) bool {
    return !std.mem.eql(u8, url, issuer) and isLoopbackHttpUrl(url, true);
}

pub fn load(alloc: Allocator) !?Session {
    return session_store.load(alloc, profile_paths.chatgpt_dir_name);
}

pub fn loadAccessToken(alloc: Allocator) !?[]u8 {
    var session = try loadValidSession(alloc) orelse return null;
    defer session.deinit(alloc);
    return try alloc.dupe(u8, session.access_token);
}

pub fn hasSession() bool {
    var session = load(std.heap.c_allocator) catch return false;
    if (session) |*value| {
        value.deinit(std.heap.c_allocator);
        return true;
    }
    return false;
}

pub fn loadValidSession(alloc: Allocator) !?Session {
    var session = (try load(alloc)) orelse return null;
    errdefer session.deinit(alloc);
    if (!session.expired(io_mod.milliTimestamp())) return session;
    refreshSession(alloc, &session) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("chatgpt", "session refresh failed err={s}", .{@errorName(err)});
            session.deinit(alloc);
            return null;
        },
    };
    return session;
}

pub fn refreshSession(alloc: Allocator, session: *Session) !void {
    const issuer_url = session.issuer;
    const token_endpoint = try joinEndpoint(alloc, issuer_url, "/oauth/token");
    defer alloc.free(token_endpoint);

    var form_writer: std.Io.Writer.Allocating = .init(alloc);
    defer {
        @memset(form_writer.written(), 0);
        form_writer.deinit();
    }
    var form: Form = .{};
    try form.append(&form_writer.writer, "grant_type", "refresh_token");
    try form.append(&form_writer.writer, "refresh_token", session.refresh_token);
    try form.append(&form_writer.writer, "client_id", session.client_id);

    var response = try postForm(alloc, token_endpoint, form_writer.written());
    defer response.deinit(alloc);
    if (response.status != .ok) return error.TokenRefreshFailed;
    var grant = try parseTokenGrant(alloc, response.body, default_scope, session.account_id);
    errdefer grant.deinit(alloc);

    secret.zeroAndFree(alloc, session.access_token);
    session.access_token = grant.access_token;
    grant.access_token = &.{};
    if (grant.refresh_token) |value| {
        secret.zeroAndFree(alloc, session.refresh_token);
        session.refresh_token = value;
        grant.refresh_token = null;
    }
    if (grant.account_id) |value| {
        if (session.account_id) |current| alloc.free(current);
        session.account_id = value;
        grant.account_id = null;
    }
    session.expires_at_ms = grant.expires_at_ms;
    alloc.free(session.scope);
    session.scope = grant.scope;
    grant.scope = &.{};
    alloc.free(session.token_type);
    session.token_type = grant.token_type;
    grant.token_type = &.{};

    try session_store.saveNewSession(alloc, profile_paths.chatgpt_dir_name, session.*);
}

pub const LogoutResult = struct {
    session_deleted: bool = false,
    local_durability_failed: bool = false,
};

pub fn logout(alloc: Allocator) !LogoutResult {
    _ = alloc;
    var mutation = (session_store.beginExistingMutation(profile_paths.chatgpt_dir_name) catch {
        return error.SessionDeleteFailed;
    }) orelse return .{};
    defer mutation.deinit();
    const outcome = mutation.delete() catch return error.SessionDeleteFailed;
    return .{
        .session_deleted = outcome != .missing,
        .local_durability_failed = outcome == .deleted_not_durable,
    };
}

pub const LoginOptions = struct {
    url_opener: host.UrlOpener,
    cancel_flag: ?*const std.atomic.Value(bool) = null,
    write_stdout: *const fn ([]const u8) anyerror!void = writeStdout,
};

pub fn runLogin(alloc: Allocator, options: LoginOptions) !void {
    if (comptime host_target.is_wasm or builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.InteractiveAuthorizationUnsupported;
    }
    var prepared = try prepareAuthorization(alloc);
    defer prepared.deinit(alloc);

    try options.write_stdout("Open ");
    try options.write_stdout(prepared.authorization_url);
    try options.write_stdout("\nWaiting for ChatGPT authorization...\n");

    if (io_mod.getenv(no_open_browser_env) == null) {
        _ = options.url_opener.open(alloc, prepared.authorization_url) catch false;
    }

    var callback = pkce_loopback.acceptCallback(
        alloc,
        &prepared.listener,
        callback_path,
        options.cancel_flag,
    ) catch |err| switch (err) {
        error.Cancelled => return error.Cancelled,
        else => return err,
    };
    defer callback.deinit(alloc);
    if (callback.error_code) |code| {
        if (std.mem.eql(u8, code, "access_denied")) return error.AccessDenied;
        return error.AuthorizationFailed;
    }
    if (!std.mem.eql(u8, callback.state, prepared.state())) return error.OAuthStateMismatch;

    var grant = try exchangeAuthorizationCode(
        alloc,
        prepared.issuer,
        prepared.redirect_uri,
        callback.code,
        prepared.verifier(),
    );
    defer grant.deinit(alloc);
    const refresh_token = grant.refresh_token orelse return error.NoRefreshToken;
    grant.refresh_token = null;
    errdefer secret.zeroAndFree(alloc, refresh_token);

    var session = Session{
        .issuer = try alloc.dupe(u8, prepared.issuer),
        .client_id = try alloc.dupe(u8, client_id),
        .access_token = grant.access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = grant.expires_at_ms,
        .scope = grant.scope,
        .token_type = grant.token_type,
        .account_id = grant.account_id,
    };
    grant.access_token = &.{};
    grant.scope = &.{};
    grant.token_type = &.{};
    grant.account_id = null;
    defer session.deinit(alloc);
    try session_store.saveNewSession(alloc, profile_paths.chatgpt_dir_name, session);
    try options.write_stdout("Signed in to ChatGPT.\n");
}

const PreparedAuthorization = struct {
    listener: std.Io.net.Server,
    issuer: []const u8,
    redirect_uri: []u8,
    authorization_url: []u8,
    verifier_buf: [pkce.verifier_max_bytes]u8 = undefined,
    verifier_len: usize = 0,
    state_buf: [pkce.state_bytes]u8 = undefined,
    state_len: usize = 0,

    fn deinit(self: *PreparedAuthorization, alloc: Allocator) void {
        self.listener.deinit(io_mod.getIo());
        alloc.free(self.redirect_uri);
        secret.zeroAndFree(alloc, self.authorization_url);
        @memset(self.verifier_buf[0..self.verifier_len], 0);
        self.* = undefined;
    }

    fn verifier(self: *const PreparedAuthorization) []const u8 {
        return self.verifier_buf[0..self.verifier_len];
    }

    fn state(self: *const PreparedAuthorization) []const u8 {
        return self.state_buf[0..self.state_len];
    }
};

fn prepareAuthorization(alloc: Allocator) !PreparedAuthorization {
    const issuer_url = try configuredIssuerUrl();
    const e2e = isLoopbackE2EIssuer(issuer_url);
    var listener = if (e2e)
        pkce_loopback.bindEphemeral() catch return error.LoopbackUnavailable
    else
        pkce_loopback.bind(production_callback_port) catch return error.LoopbackUnavailable;
    errdefer listener.deinit(io_mod.getIo());

    const host_name: []const u8 = if (e2e) "127.0.0.1" else production_callback_host;
    const redirect_uri = try pkce_loopback.redirectUriAlloc(
        alloc,
        &listener,
        host_name,
        callback_path,
    );
    errdefer alloc.free(redirect_uri);

    var verifier_buf: [pkce.verifier_max_bytes]u8 = undefined;
    var challenge_buf: [pkce.challenge_bytes]u8 = undefined;
    const pair = try pkce.generate(&verifier_buf, &challenge_buf);
    var state_buf: [pkce.state_bytes]u8 = undefined;
    const state = try pkce.generateState(&state_buf);

    const authorize_endpoint = try joinEndpoint(alloc, issuer_url, "/oauth/authorize");
    defer alloc.free(authorize_endpoint);
    const authorization_url = try buildAuthorizationUrl(
        alloc,
        authorize_endpoint,
        redirect_uri,
        state,
        pair.challenge,
    );
    errdefer secret.zeroAndFree(alloc, authorization_url);

    var prepared = PreparedAuthorization{
        .listener = listener,
        .issuer = issuer_url,
        .redirect_uri = redirect_uri,
        .authorization_url = authorization_url,
        .verifier_len = pair.verifier.len,
        .state_len = state.len,
    };
    @memcpy(prepared.verifier_buf[0..pair.verifier.len], pair.verifier);
    @memcpy(prepared.state_buf[0..state.len], state);
    return prepared;
}

fn buildAuthorizationUrl(
    alloc: Allocator,
    endpoint: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
    code_challenge: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(endpoint);
    try out.writer.writeByte(if (std.mem.indexOfScalar(u8, endpoint, '?') == null) '?' else '&');
    var form: Form = .{};
    try form.append(&out.writer, "response_type", "code");
    try form.append(&out.writer, "client_id", client_id);
    try form.append(&out.writer, "redirect_uri", redirect_uri);
    try form.append(&out.writer, "scope", default_scope);
    try form.append(&out.writer, "state", state);
    try form.append(&out.writer, "code_challenge", code_challenge);
    try form.append(&out.writer, "code_challenge_method", "S256");
    try form.append(&out.writer, "id_token_add_organizations", "true");
    try form.append(&out.writer, "originator", "fx");
    return out.toOwnedSlice();
}

const TokenGrant = struct {
    access_token: []u8,
    refresh_token: ?[]u8,
    scope: []u8,
    token_type: []u8,
    expires_at_ms: i64,
    account_id: ?[]u8,

    fn deinit(self: *TokenGrant, alloc: Allocator) void {
        if (self.access_token.len > 0) secret.zeroAndFree(alloc, self.access_token);
        if (self.refresh_token) |value| secret.zeroAndFree(alloc, value);
        if (self.scope.len > 0) alloc.free(self.scope);
        if (self.token_type.len > 0) alloc.free(self.token_type);
        if (self.account_id) |value| alloc.free(value);
        self.* = undefined;
    }
};

fn exchangeAuthorizationCode(
    alloc: Allocator,
    issuer_url: []const u8,
    redirect_uri: []const u8,
    code: []const u8,
    verifier: []const u8,
) !TokenGrant {
    const token_endpoint = try joinEndpoint(alloc, issuer_url, "/oauth/token");
    defer alloc.free(token_endpoint);

    var form_writer: std.Io.Writer.Allocating = .init(alloc);
    defer {
        @memset(form_writer.written(), 0);
        form_writer.deinit();
    }
    var form: Form = .{};
    try form.append(&form_writer.writer, "grant_type", "authorization_code");
    try form.append(&form_writer.writer, "code", code);
    try form.append(&form_writer.writer, "redirect_uri", redirect_uri);
    try form.append(&form_writer.writer, "client_id", client_id);
    try form.append(&form_writer.writer, "code_verifier", verifier);

    var response = try postForm(alloc, token_endpoint, form_writer.written());
    defer response.deinit(alloc);
    if (response.status != .ok) return error.TokenExchangeFailed;
    return parseTokenGrant(alloc, response.body, default_scope, null);
}

fn parseTokenGrant(
    alloc: Allocator,
    body: []const u8,
    fallback_scope: []const u8,
    fallback_account_id: ?[]const u8,
) !TokenGrant {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTokenResponse;
    const object = parsed.value.object;
    const access_token = try dupeRequiredSecret(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeOptionalSecret(alloc, object, "refresh_token");
    errdefer if (refresh_token) |value| secret.zeroAndFree(alloc, value);
    const token_type = try dupeOptionalStringDefault(alloc, object, "token_type", "Bearer");
    errdefer alloc.free(token_type);
    if (!std.ascii.eqlIgnoreCase(token_type, "Bearer")) return error.InvalidTokenResponse;
    const scope = try dupeOptionalStringDefault(alloc, object, "scope", fallback_scope);
    errdefer alloc.free(scope);
    const expires_at_ms = try tokenExpiresAt(object, io_mod.milliTimestamp());
    var account_id = try accountIdFromObject(alloc, object);
    errdefer if (account_id) |value| alloc.free(value);
    if (account_id == null) {
        if (object.get("id_token")) |value| {
            if (value == .string) account_id = try accountIdFromIdToken(alloc, value.string);
        }
    }
    if (account_id == null) {
        if (fallback_account_id) |value| account_id = try alloc.dupe(u8, value);
    }
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .scope = scope,
        .token_type = token_type,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
    };
}

pub fn accountIdFromIdToken(alloc: Allocator, id_token: []const u8) !?[]u8 {
    const first = std.mem.indexOfScalar(u8, id_token, '.') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, id_token, first + 1, '.') orelse return null;
    const payload = id_token[first + 1 .. second];
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return null;
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch return null;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, decoded, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    return accountIdFromObject(alloc, parsed.value.object);
}

fn accountIdFromObject(alloc: Allocator, object: std.json.ObjectMap) !?[]u8 {
    if (object.get("https://api.openai.com/auth")) |auth_value| {
        if (auth_value == .object) {
            if (stringField(auth_value.object, "chatgpt_account_id")) |value| {
                return try alloc.dupe(u8, value);
            }
        }
    }
    if (stringField(object, "chatgpt_account_id")) |value| {
        return try alloc.dupe(u8, value);
    }
    return null;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,

    fn deinit(self: *HttpResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        self.* = undefined;
    }
};

fn postForm(alloc: Allocator, url: []const u8, payload: []const u8) !HttpResponse {
    const uri = std.Uri.parse(url) catch return error.InvalidChatgptAuthEndpoint;
    if (!isSecureOrLoopback(uri) or uri.user != null or uri.password != null or uri.fragment != null) {
        return error.InsecureChatgptAuthEndpoint;
    }
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var request = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .accept_encoding = .omit,
        },
    });
    defer request.deinit();
    if (request.connection) |connection| {
        setSocketTimeouts(connection.stream_writer.stream.socket.handle, request_timeout_seconds);
    }
    try request.sendBodyComplete(@constCast(payload));
    var response = try request.receiveHead(&.{});
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = reader.allocRemaining(alloc, .limited(max_document_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return error.ChatgptAuthDocumentTooLarge,
        else => return err,
    };
    return .{
        .status = response.head.status,
        .body = body,
    };
}

const Form = struct {
    first: bool = true,

    fn append(self: *Form, writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
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
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or
            byte == '.' or byte == '~')
        {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn joinEndpoint(alloc: Allocator, base: []const u8, suffix: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    if (std.mem.endsWith(u8, trimmed, suffix)) return alloc.dupe(u8, trimmed);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ trimmed, suffix });
}

fn tokenExpiresAt(object: std.json.ObjectMap, now_ms: i64) !i64 {
    const value = object.get("expires_in") orelse return std.math.maxInt(i64);
    if (value != .integer or value.integer < 0) return error.InvalidTokenResponse;
    return std.math.add(
        i64,
        now_ms,
        std.math.mul(i64, value.integer, 1000) catch std.math.maxInt(i64),
    ) catch std.math.maxInt(i64);
}

fn dupeRequiredSecret(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidTokenResponse;
    if (value != .string or value.string.len == 0) return error.InvalidTokenResponse;
    return alloc.dupe(u8, value.string);
}

fn dupeOptionalSecret(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len == 0) return error.InvalidTokenResponse;
    return try alloc.dupe(u8, value.string);
}

fn dupeOptionalStringDefault(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    default: []const u8,
) ![]u8 {
    const value = object.get(key) orelse return alloc.dupe(u8, default);
    if (value == .null) return alloc.dupe(u8, default);
    if (value != .string) return error.InvalidTokenResponse;
    return alloc.dupe(u8, value.string);
}

fn selectIssuerUrl(override: ?[]const u8) ![]const u8 {
    const raw = override orelse return issuer;
    const candidate = std.mem.trimEnd(u8, raw, "/");
    if (!isLoopbackHttpUrl(candidate, true)) return error.InvalidE2EOAuthIssuer;
    return candidate;
}

fn isSecureOrLoopback(uri: std.Uri) bool {
    return std.ascii.eqlIgnoreCase(uri.scheme, "https") or isLoopbackUri(uri);
}

fn isLoopbackUri(uri: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host_name, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host_name, "localhost") or
        std.mem.eql(u8, host_name, "[::1]");
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
    return isLoopbackUri(uri);
}

fn trimmedEnv(key: []const u8) ?[]const u8 {
    const value = io_mod.getenv(key) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn setSocketTimeouts(socket: std.posix.socket_t, seconds: i64) void {
    if (comptime host_target.is_wasm) return;
    const timeout = std.posix.timeval{ .sec = seconds, .usec = 0 };
    const bytes = std.mem.asBytes(&timeout);
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch {};
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch {};
}

test "chatgpt issuer override accepts loopback only" {
    try std.testing.expectEqualStrings(issuer, try selectIssuerUrl(null));
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:1455",
        try selectIssuerUrl("http://127.0.0.1:1455/"),
    );
    try std.testing.expectError(error.InvalidE2EOAuthIssuer, selectIssuerUrl("https://auth.openai.com"));
    try std.testing.expectError(error.InvalidE2EOAuthIssuer, selectIssuerUrl("http://example.test"));
}

test "chatgpt authorization url is pkce and does not invent scopes" {
    const url = try buildAuthorizationUrl(
        std.testing.allocator,
        "http://127.0.0.1:9/oauth/authorize",
        "http://127.0.0.1:9/auth/callback",
        "state-token",
        "challenge-token",
    );
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.startsWith(u8, url, "http://127.0.0.1:9/oauth/authorize?"));
    try std.testing.expect(std.mem.find(u8, url, "response_type=code") != null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge=challenge-token") != null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.find(u8, url, "client_id=app_EMoamEEZ73f0CkXaXp7hrann") != null);
    try std.testing.expect(std.mem.find(u8, url, "scope=openid") != null);
}

test "chatgpt token grant reads refresh token and account id" {
    const body =
        \\{"access_token":"atk","refresh_token":"rtk","token_type":"Bearer","expires_in":3600,"scope":"openid offline_access","id_token":"eyJhbGciOiJub25lIn0.eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0XzEyMyJ9.e30"}
    ;
    var grant = try parseTokenGrant(std.testing.allocator, body, default_scope, null);
    defer grant.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("atk", grant.access_token);
    try std.testing.expectEqualStrings("rtk", grant.refresh_token.?);
    try std.testing.expectEqualStrings("acct_123", grant.account_id.?);
}

test "chatgpt id token account id parser reads nested auth claim" {
    const payload = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"org-user-1\"}}";
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(payload.len);
    const encoded = try std.testing.allocator.alloc(u8, encoded_len);
    defer std.testing.allocator.free(encoded);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    const token = try std.fmt.allocPrint(std.testing.allocator, "aaa.{s}.bbb", .{encoded});
    defer std.testing.allocator.free(token);
    const account_id = (try accountIdFromIdToken(std.testing.allocator, token)) orelse
        return error.TestUnexpectedMissingAccountId;
    defer std.testing.allocator.free(account_id);
    try std.testing.expectEqualStrings("org-user-1", account_id);
}
