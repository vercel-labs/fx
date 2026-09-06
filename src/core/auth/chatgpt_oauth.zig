const std = @import("std");
const credentials = @import("credentials.zig");
const browser_callback = @import("browser_callback.zig");
const chatgpt_session = @import("chatgpt_session.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const login_flow = @import("login_flow.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const token_url = "https://auth.openai.com/oauth/token";
pub const issuer_url = "https://auth.openai.com";
const e2e_token_url_env = "FX_E2E_CHATGPT_TOKEN_URL";
const e2e_issuer_url_env = "FX_E2E_CHATGPT_ISSUER_URL";
const jwt_auth_claim = "https://api.openai.com/auth";
const browser_scope = "openid profile email offline_access api.connectors.read api.connectors.invoke";
const browser_callback_ports = [_]u16{ 1455, 1457 };
const browser_login_timeout_seconds: i64 = 5 * 60;

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

const BrowserLoginContext = struct {
    listener: std.Io.net.Server,
    redirect_uri: []u8,
    code_verifier: []u8,
    state: []u8,
    pending_callback: ?browser_callback.Accepted(BrowserCallback) = null,

    fn deinit(self: *BrowserLoginContext, alloc: Allocator) void {
        self.finishCallback(alloc, false);
        self.listener.deinit(io_mod.getIo());
        alloc.free(self.redirect_uri);
        secret.zeroAndFree(alloc, self.code_verifier);
        secret.zeroAndFree(alloc, self.state);
        self.* = undefined;
    }

    fn finishCallback(self: *BrowserLoginContext, alloc: Allocator, saved: bool) void {
        var callback = self.pending_callback orelse return;
        self.pending_callback = null;
        defer callback.deinit();
        defer callback.callback.deinit(alloc);
        callback.respond(if (saved) .ok else .failed) catch |err| {
            debug_trace.logf("auth", "Codex completion response failed err={s}", .{@errorName(err)});
        };
    }
};

const PreparedBrowserLogin = struct {
    prepared: login_flow.PreparedLogin,
    context: *BrowserLoginContext,
};

pub fn startSignIn(
    runtime: *login_flow.SignInRuntime,
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !bool {
    try credentials.requireSignInStorage(.chatgpt_subscription);
    const browser = try prepareBrowserSignIn(alloc);
    return runtime.startPrepared(
        alloc,
        browser.prepared,
        .{
            .ctx = browser.context,
            .deinit_ctx = deinitBrowserLoginContext,
            .oauth_transport = transport,
            .poll = .{
                .ctx = browser.context,
                .poll_device_token = pollBrowserToken,
            },
            .complete = completeSignIn,
            .save = saveSignIn,
            .finish = finishSignIn,
        },
    );
}

fn prepareBrowserSignIn(alloc: Allocator) !PreparedBrowserLogin {
    const configured_issuer = try configuredEndpoint(alloc, e2e_issuer_url_env, issuer_url);
    defer alloc.free(configured_issuer);
    const configured_token_endpoint = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
    errdefer alloc.free(configured_token_endpoint);

    var listener = try bindBrowserCallback(io_mod.getenv(e2e_issuer_url_env) != null);
    var listener_owned = true;
    errdefer if (listener_owned) listener.deinit(io_mod.getIo());
    const callback_port = listener.socket.address.getPort();
    const redirect_uri = try std.fmt.allocPrint(
        alloc,
        "http://localhost:{d}/auth/callback",
        .{callback_port},
    );
    errdefer alloc.free(redirect_uri);
    const code_verifier = try randomUrlSafeSecret(alloc);
    errdefer secret.zeroAndFree(alloc, code_verifier);
    const state = try randomUrlSafeSecret(alloc);
    errdefer secret.zeroAndFree(alloc, state);
    const code_challenge = try pkceChallengeAlloc(alloc, code_verifier);
    defer alloc.free(code_challenge);
    const authorization_url = try buildBrowserAuthorizationUrl(
        alloc,
        configured_issuer,
        redirect_uri,
        code_challenge,
        state,
    );
    errdefer alloc.free(authorization_url);

    const context = try alloc.create(BrowserLoginContext);
    errdefer alloc.destroy(context);
    context.* = .{
        .listener = listener,
        .redirect_uri = redirect_uri,
        .code_verifier = code_verifier,
        .state = state,
    };
    listener_owned = false;

    const owned_issuer = try alloc.dupe(u8, configured_issuer);
    errdefer alloc.free(owned_issuer);
    const authorization_endpoint = try std.fmt.allocPrint(
        alloc,
        "{s}/oauth/authorize",
        .{std.mem.trimEnd(u8, configured_issuer, "/")},
    );
    errdefer alloc.free(authorization_endpoint);
    const device_code = try alloc.dupe(u8, "");
    errdefer secret.zeroAndFree(alloc, device_code);
    const user_code = try alloc.dupe(u8, "");
    errdefer alloc.free(user_code);
    const owned_client_id = try alloc.dupe(u8, client_id);
    errdefer alloc.free(owned_client_id);

    return .{
        .prepared = .{
            .metadata = .{
                .issuer = owned_issuer,
                .device_authorization_endpoint = authorization_endpoint,
                .token_endpoint = configured_token_endpoint,
            },
            .device = .{
                .device_code = device_code,
                .user_code = user_code,
                .verification_uri = authorization_url,
                .expires_in = browser_login_timeout_seconds,
                .interval = 1,
            },
            .client_id = owned_client_id,
        },
        .context = context,
    };
}

fn deinitBrowserLoginContext(raw: ?*anyopaque, alloc: Allocator) void {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    context.deinit(alloc);
    alloc.destroy(context);
}

fn bindBrowserCallback(e2e: bool) !std.Io.net.Server {
    if (e2e) {
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        return address.listen(io_mod.getIo(), .{ .reuse_address = true });
    }
    for (browser_callback_ports) |port| {
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        return address.listen(io_mod.getIo(), .{ .reuse_address = true }) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => return err,
        };
    }
    return error.ChatGptOAuthCallbackPortUnavailable;
}

fn randomUrlSafeSecret(alloc: Allocator) ![]u8 {
    var entropy: [32]u8 = undefined;
    try io_mod.getIo().randomSecure(&entropy);
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(entropy.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &entropy);
    return encoded;
}

fn pkceChallengeAlloc(alloc: Allocator, verifier: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(digest.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &digest);
    return encoded;
}

fn pollBrowserToken(
    raw: ?*anyopaque,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    _: []const u8,
    _: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    if (comptime host_target.is_wasm) return error.ChatGptOAuthUnavailable;
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    var accepted = (try awaitBrowserCallback(
        alloc,
        &context.listener,
        context.state,
        cancel_flag,
    )) orelse return .pending;
    var callback_owned = true;
    defer if (callback_owned) {
        accepted.callback.deinit(alloc);
        accepted.deinit();
    };

    var token = exchangeAuthorizationCodeForRedirectWithBounds(
        alloc,
        transport,
        metadata.token_endpoint,
        accepted.callback.code,
        context.code_verifier,
        context.redirect_uri,
        cancel_flag,
        deadline,
    ) catch |err| {
        accepted.respond(.failed) catch {};
        return err;
    };
    errdefer token.deinit(alloc);

    const scope = try alloc.dupe(u8, "");
    errdefer if (scope.len > 0) alloc.free(scope);
    const token_type = try alloc.dupe(u8, "Bearer");
    errdefer alloc.free(token_type);
    const access_token = token.access_token;
    token.access_token = &.{};
    const refresh_token = token.refresh_token;
    token.refresh_token = &.{};
    context.pending_callback = accepted;
    callback_owned = false;
    return .{ .success = .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = token.expires_in,
        .scope = scope,
        .token_type = token_type,
    } };
}

const BrowserCallbackParserContext = struct {
    expected_state: []const u8,
};

fn awaitBrowserCallback(
    alloc: Allocator,
    listener: *std.Io.net.Server,
    expected_state: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !?browser_callback.Accepted(BrowserCallback) {
    var parser_context = BrowserCallbackParserContext{ .expected_state = expected_state };
    return browser_callback.await(
        BrowserCallback,
        classifyBrowserCallback,
        alloc,
        listener,
        &parser_context,
        cancel_flag,
        null,
    ) catch |err| switch (err) {
        error.OAuthCallbackListenerFailed => error.ChatGptOAuthCallbackListenerFailed,
        else => err,
    };
}

fn classifyBrowserCallback(
    raw: ?*anyopaque,
    alloc: Allocator,
    target: []const u8,
) browser_callback.ParseResult(BrowserCallback) {
    const context: *BrowserCallbackParserContext = @ptrCast(@alignCast(raw.?));
    const callback = parseBrowserCallbackTarget(alloc, target, context.expected_state) catch |err| switch (err) {
        error.InvalidChatGptOAuthCallback, error.ChatGptOAuthStateMismatch => {
            if (err == error.ChatGptOAuthStateMismatch) {
                debug_trace.logf("auth", "ChatGPT callback ignored: state belongs to another attempt", .{});
            }
            return .unrelated;
        },
        else => return .{ .failed = err },
    };
    return .{ .accepted = callback };
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
        .vercel, .grok => return error.InvalidSignInCompletion,
    };
    try chatgpt_session.saveNewSession(alloc, session);
}

fn finishSignIn(raw: ?*anyopaque, alloc: Allocator, saved: bool) void {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    context.finishCallback(alloc, saved);
}

pub fn runLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !void {
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    if (!try startSignIn(&runtime, alloc, transport)) return error.ChatGptLoginBusy;

    const authorization_url = (try runtime.browserUrlAlloc(alloc)) orelse
        return error.ChatGptAuthorizationUrlMissing;
    defer alloc.free(authorization_url);
    try writeStdout("Open this URL to sign in with Codex:\n");
    try writeStdout(authorization_url);
    try writeStdout("\n\nWaiting for browser authorization...\n");
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
    try mutation.requireWritable();
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    try body.writer.writeAll("{\"client_id\":");
    try std.json.Stringify.value(client_id, .{}, &body.writer);
    try body.writer.writeAll(",\"grant_type\":\"refresh_token\",\"refresh_token\":");
    try std.json.Stringify.value(session.refresh_token, .{}, &body.writer);
    try body.writer.writeByte('}');
    var token = requestRefreshToken(alloc, transport, body.written()) catch |err| switch (err) {
        error.CredentialRefreshRejected,
        error.InvalidChatGptOAuthResponse,
        => {
            debug_trace.logf("auth", "retiring terminal Codex session reason={s}", .{@errorName(err)});
            try retire_refresh_session(mutation);
            return error.CredentialRefreshRejected;
        },
        else => return err,
    };
    defer token.deinit(alloc);

    var replacement = refresh_replacement(alloc, &token, session.*) catch |err| {
        if (err == error.OutOfMemory) return err;
        debug_trace.logf("auth", "retiring unusable Codex refresh reason={s}", .{@errorName(err)});
        try retire_refresh_session(mutation);
        if (err == error.ChatGptAccountChanged) return err;
        return error.CredentialRefreshRejected;
    };
    errdefer replacement.deinit(alloc);
    mutation.save(alloc, replacement) catch |err| {
        debug_trace.logf("auth", "retiring Codex session after refresh save failed err={s}", .{@errorName(err)});
        retire_refresh_session(mutation) catch |cleanup_err| {
            debug_trace.logf("auth", "Codex session retirement failed err={s}", .{@errorName(cleanup_err)});
        };
        return error.CredentialRefreshPersistenceUncertain;
    };

    session.deinit(alloc);
    session.* = replacement;
    replacement.access_token = &.{};
    replacement.refresh_token = &.{};
    replacement.account_id = &.{};
}

fn refresh_replacement(
    alloc: Allocator,
    token: *RefreshTokenResponse,
    current: chatgpt_session.Session,
) !chatgpt_session.Session {
    const account_id = try extractAccountId(alloc, token.access_token);
    errdefer alloc.free(account_id);
    if (!std.mem.eql(u8, account_id, current.account_id)) {
        return error.ChatGptAccountChanged;
    }
    const refresh_token = if (token.refresh_token) |rotated|
        rotated
    else
        try alloc.dupe(u8, current.refresh_token);
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const expires_at_ms = if (token.expires_in) |expires_in| blk: {
        const duration_ms = std.math.mul(i64, expires_in, std.time.ms_per_s) catch
            return error.InvalidChatGptOAuthResponse;
        break :blk std.math.add(i64, io_mod.milliTimestamp(), duration_ms) catch
            return error.InvalidChatGptOAuthResponse;
    } else try accessTokenExpiresAtMs(alloc, token.access_token);
    const replacement = chatgpt_session.Session{
        .access_token = token.access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
    };
    token.access_token = &.{};
    if (token.refresh_token != null) token.refresh_token = null;
    return replacement;
}

fn retire_refresh_session(mutation: *chatgpt_session.Mutation) !void {
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
    const endpoint_url = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
    defer alloc.free(endpoint_url);
    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = endpoint_url,
        .payload = payload,
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) {
        debug_trace.logf("auth", "Codex refresh request rejected", .{});
        if (chat_gpt_refresh_requires_sign_in(response.body)) {
            return error.CredentialRefreshRejected;
        }
        return error.ChatGptOAuthRequestFailed;
    }
    const bytes = response.takeBody();
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidChatGptOAuthResponse;
    const object = parsed.value.object;
    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = if (object.get("refresh_token")) |value| blk: {
        if (value != .string or value.string.len == 0) return error.InvalidChatGptOAuthResponse;
        break :blk try alloc.dupe(u8, value.string);
    } else null;
    errdefer if (refresh_token) |token| secret.zeroAndFree(alloc, token);
    const expires_in = if (object.get("expires_in")) |value| blk: {
        if (value != .integer or value.integer <= 0) return error.InvalidChatGptOAuthResponse;
        break :blk value.integer;
    } else null;
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = expires_in,
    };
}

fn chat_gpt_refresh_requires_sign_in(body: []const u8) bool {
    const terminal_codes = [_][]const u8{
        "\"refresh_token_expired\"",
        "\"refresh_token_reused\"",
        "\"refresh_token_invalidated\"",
        "\"invalid_grant\"",
    };
    for (terminal_codes) |code| {
        if (std.mem.find(u8, body, code) != null) return true;
    }
    return false;
}

fn accessTokenExpiresAtMs(alloc: Allocator, token: []const u8) !i64 {
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
    const exp = parsed.value.object.get("exp") orelse return error.InvalidChatGptOAuthResponse;
    if (exp != .integer or exp.integer <= 0) return error.InvalidChatGptOAuthResponse;
    return std.math.mul(i64, exp.integer, std.time.ms_per_s) catch
        return error.InvalidChatGptOAuthResponse;
}

fn exchangeAuthorizationCodeForRedirectWithBounds(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint_url: []const u8,
    authorization_code: []const u8,
    code_verifier: []const u8,
    redirect_uri: []const u8,
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
    try form.append(&body.writer, "redirect_uri", redirect_uri);
    return requestTokenAtWithBounds(alloc, transport, endpoint_url, body.written(), cancel_flag, deadline);
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

const BrowserCallback = struct {
    code: []u8,

    fn deinit(self: *BrowserCallback, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.code);
        self.* = undefined;
    }
};

fn buildBrowserAuthorizationUrl(
    alloc: Allocator,
    issuer: []const u8,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{s}/oauth/authorize?", .{std.mem.trimEnd(u8, issuer, "/")});
    var form: FormBody = .{};
    try form.append(&out.writer, "response_type", "code");
    try form.append(&out.writer, "client_id", client_id);
    try form.append(&out.writer, "redirect_uri", redirect_uri);
    try form.append(&out.writer, "scope", browser_scope);
    try form.append(&out.writer, "code_challenge", code_challenge);
    try form.append(&out.writer, "code_challenge_method", "S256");
    try form.append(&out.writer, "id_token_add_organizations", "true");
    try form.append(&out.writer, "codex_cli_simplified_flow", "true");
    try form.append(&out.writer, "state", state);
    try form.append(&out.writer, "originator", "fx");
    return out.toOwnedSlice();
}

fn parseBrowserCallbackTarget(
    alloc: Allocator,
    target: []const u8,
    expected_state: []const u8,
) !BrowserCallback {
    const prefix = "/auth/callback?";
    if (!std.mem.startsWith(u8, target, prefix) or std.mem.findScalar(u8, target, '#') != null) {
        return error.InvalidChatGptOAuthCallback;
    }
    const query = target[prefix.len..];
    if (queryValueAlloc(alloc, query, "error")) |denial| {
        alloc.free(denial);
        const denial_state = queryValueAlloc(alloc, query, "state") catch
            return error.InvalidChatGptOAuthCallback;
        defer secret.zeroAndFree(alloc, denial_state);
        if (!std.mem.eql(u8, denial_state, expected_state)) return error.InvalidChatGptOAuthCallback;
        return error.ChatGptAuthorizationFailed;
    } else |_| {}
    const code = try queryValueAlloc(alloc, query, "code");
    errdefer secret.zeroAndFree(alloc, code);
    const state = try queryValueAlloc(alloc, query, "state");
    defer secret.zeroAndFree(alloc, state);
    if (!std.mem.eql(u8, state, expected_state)) return error.ChatGptOAuthStateMismatch;
    return .{ .code = code };
}

fn queryValueAlloc(alloc: Allocator, query: []const u8, key: []const u8) ![]u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], key)) continue;
        return percentDecodeAlloc(alloc, pair[equals + 1 ..]);
    }
    return error.InvalidChatGptOAuthCallback;
}

fn percentDecodeAlloc(alloc: Allocator, value: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, value.len);
    errdefer alloc.free(out);
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < value.len) {
        if (value[read_index] == '%') {
            if (read_index + 2 >= value.len) return error.InvalidChatGptOAuthCallback;
            const high = std.fmt.charToDigit(value[read_index + 1], 16) catch
                return error.InvalidChatGptOAuthCallback;
            const low = std.fmt.charToDigit(value[read_index + 2], 16) catch
                return error.InvalidChatGptOAuthCallback;
            out[write_index] = @as(u8, @intCast(high * 16 + low));
            read_index += 3;
        } else {
            out[write_index] = if (value[read_index] == '+') ' ' else value[read_index];
            read_index += 1;
        }
        write_index += 1;
    }
    if (write_index == 0) return error.InvalidChatGptOAuthCallback;
    return alloc.realloc(out, write_index);
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
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
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

test "Codex refresh uses JSON and accepts omitted token rotation and lifetime" {
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
            return .{
                .disposition = .accepted,
                .body = try alloc.dupe(u8, "{\"access_token\":\"header.payload.signature\"}"),
            };
        }
    };
    var state = State{};
    var response = try requestRefreshToken(
        std.testing.allocator,
        .{ .context = &state, .execute_fn = State.execute },
        "{\"client_id\":\"client\",\"grant_type\":\"refresh_token\",\"refresh_token\":\"refresh\"}",
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(oauth_transport.Method.post_json, state.method.?);
    try std.testing.expect(std.mem.find(u8, state.payload[0..state.payload_len], "\"grant_type\":\"refresh_token\"") != null);
    try std.testing.expect(response.refresh_token == null);
    try std.testing.expect(response.expires_in == null);
}

test "ChatGPT browser authorization URL uses PKCE without device authentication" {
    const url = try buildBrowserAuthorizationUrl(
        std.testing.allocator,
        "https://auth.openai.com",
        "http://localhost:1455/auth/callback",
        "challenge-value",
        "state-value",
    );
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.startsWith(u8, url, "https://auth.openai.com/oauth/authorize?"));
    try std.testing.expect(std.mem.find(u8, url, "response_type=code") != null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge=challenge-value") != null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.find(u8, url, "state=state-value") != null);
    try std.testing.expect(std.mem.find(u8, url, "originator=fx") != null);
    try std.testing.expect(std.mem.find(u8, url, "device") == null);
}

test "ChatGPT browser callback classifier keeps stale callbacks unrelated" {
    var context = BrowserCallbackParserContext{ .expected_state = "expected" };

    const stale_success = classifyBrowserCallback(
        &context,
        std.testing.allocator,
        "/auth/callback?code=stale&state=other",
    );
    switch (stale_success) {
        .unrelated => {},
        else => return error.ExpectedUnrelatedCallback,
    }

    const stale_denial = classifyBrowserCallback(
        &context,
        std.testing.allocator,
        "/auth/callback?error=access_denied&state=other",
    );
    switch (stale_denial) {
        .unrelated => {},
        else => return error.ExpectedUnrelatedCallback,
    }
}

test "ChatGPT browser callback classifier reports a current denial" {
    var context = BrowserCallbackParserContext{ .expected_state = "expected" };
    const denied = classifyBrowserCallback(
        &context,
        std.testing.allocator,
        "/auth/callback?error=access_denied&state=expected",
    );
    switch (denied) {
        .failed => |err| try std.testing.expectEqual(error.ChatGptAuthorizationFailed, err),
        else => return error.ExpectedFailedCallback,
    }
}

test "ChatGPT browser callback requires the exact path and state" {
    var callback = try parseBrowserCallbackTarget(
        std.testing.allocator,
        "/auth/callback?code=auth%20code&state=expected",
        "expected",
    );
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("auth code", callback.code);

    try std.testing.expectError(
        error.ChatGptOAuthStateMismatch,
        parseBrowserCallbackTarget(
            std.testing.allocator,
            "/auth/callback?code=auth&state=other",
            "expected",
        ),
    );
    try std.testing.expectError(
        error.InvalidChatGptOAuthCallback,
        parseBrowserCallbackTarget(
            std.testing.allocator,
            "/other?code=auth&state=expected",
            "expected",
        ),
    );
}
