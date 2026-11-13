const std = @import("std");
const credentials = @import("credentials.zig");
const browser_callback = @import("browser_callback.zig");
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
const pkceChallengeAlloc = oauth.pkceChallengeAlloc;
const randomUrlSafeSecret = oauth.randomUrlSafeSecret;

const client_id = "b1a00492-073a-47ea-816f-4c329264a828";
const token_url = "https://auth.x.ai/oauth2/token";
const issuer_url = "https://auth.x.ai";
const userinfo_url = "https://auth.x.ai/oauth2/userinfo";
const revoke_url = "https://auth.x.ai/oauth2/revoke";
const e2e_token_url_env = "FX_TEST_GROK_TOKEN_URL";
const e2e_issuer_url_env = "FX_TEST_GROK_ISSUER_URL";
const e2e_userinfo_url_env = "FX_TEST_GROK_USERINFO_URL";
const e2e_revoke_url_env = "FX_TEST_GROK_REVOKE_URL";
const browser_scope = "openid profile email offline_access grok-cli:access api:access";
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

const TokenSet = oauth.BrowserTokenSet;

const BrowserLoginContext = struct {
    listener: std.Io.net.Server,
    redirect_uri: []u8,
    code_verifier: []u8,
    state: []u8,
    transport: oauth_transport.Provider,
    manual_code_mutex: std.Io.Mutex = .init,
    manual_code: ?[]u8 = null,
    pending_callback: ?browser_callback.Accepted(BrowserCallback) = null,

    fn deinit(self: *BrowserLoginContext, alloc: Allocator) void {
        self.finishCallback(alloc, false);
        self.listener.deinit(io_mod.getIo());
        alloc.free(self.redirect_uri);
        secret.zeroAndFree(alloc, self.code_verifier);
        secret.zeroAndFree(alloc, self.state);
        if (self.manual_code) |code| secret.zeroAndFree(alloc, code);
        self.* = undefined;
    }

    fn finishCallback(self: *BrowserLoginContext, alloc: Allocator, saved: bool) void {
        var callback = self.pending_callback orelse return;
        self.pending_callback = null;
        defer callback.deinit();
        defer callback.callback.deinit(alloc);
        callback.respond(if (saved) .ok else .failed) catch |err| {
            debug_trace.logf("auth", "Grok completion response failed err={s}", .{@errorName(err)});
        };
    }

    fn submitManualCode(self: *BrowserLoginContext, alloc: Allocator, input: []const u8) !void {
        const code = std.mem.trim(u8, input, " \t\r\n");
        if (code.len == 0 or code.len > login_flow.max_manual_code_bytes) {
            return error.InvalidGrokAuthorizationCode;
        }
        for (code) |byte| {
            if (byte < 0x21 or byte > 0x7e) return error.InvalidGrokAuthorizationCode;
        }
        const owned = try alloc.dupe(u8, code);
        errdefer secret.zeroAndFree(alloc, owned);

        self.manual_code_mutex.lockUncancelable(io_mod.getIo());
        defer self.manual_code_mutex.unlock(io_mod.getIo());
        if (self.manual_code) |pending| secret.zeroAndFree(alloc, pending);
        self.manual_code = owned;
    }

    fn takeManualCode(self: *BrowserLoginContext) ?[]u8 {
        self.manual_code_mutex.lockUncancelable(io_mod.getIo());
        defer self.manual_code_mutex.unlock(io_mod.getIo());
        const code = self.manual_code;
        self.manual_code = null;
        return code;
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
    try credentials.requireSignInStorage(.grok_subscription);
    const browser = try prepareBrowserSignIn(alloc, transport);
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
            .submit_manual_code = submitBrowserManualCode,
        },
    );
}

fn submitBrowserManualCode(raw: ?*anyopaque, alloc: Allocator, code: []const u8) !void {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    try context.submitManualCode(alloc, code);
}

fn prepareBrowserSignIn(alloc: Allocator, transport: oauth_transport.Provider) !PreparedBrowserLogin {
    const configured_issuer = try configuredEndpoint(alloc, e2e_issuer_url_env, issuer_url);
    defer alloc.free(configured_issuer);
    const configured_token_endpoint = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
    var token_endpoint_owned = true;
    errdefer if (token_endpoint_owned) alloc.free(configured_token_endpoint);

    var listener = try bindBrowserCallback();
    var listener_owned = true;
    errdefer if (listener_owned) listener.deinit(io_mod.getIo());
    const callback_port = listener.socket.address.getPort();
    const redirect_uri = try alloc.print(
        "http://127.0.0.1:{d}/callback",
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
    var authorization_url_owned = true;
    errdefer if (authorization_url_owned) alloc.free(authorization_url);

    var prepared = try login_flow.prepareBrowserLogin(alloc, .{
        .issuer = configured_issuer,
        .authorization_endpoint_suffix = "/oauth2/authorize",
        .token_endpoint = configured_token_endpoint,
        .verification_uri = authorization_url,
        .client_id = client_id,
        .expires_in = browser_login_timeout_seconds,
    });
    token_endpoint_owned = false;
    authorization_url_owned = false;
    errdefer prepared.deinit(alloc);

    const context = try alloc.create(BrowserLoginContext);
    errdefer alloc.destroy(context);
    context.* = .{
        .listener = listener,
        .redirect_uri = redirect_uri,
        .code_verifier = code_verifier,
        .state = state,
        .transport = transport,
    };
    listener_owned = false;

    return .{
        .prepared = prepared,
        .context = context,
    };
}

fn deinitBrowserLoginContext(raw: ?*anyopaque, alloc: Allocator) void {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    context.deinit(alloc);
    alloc.destroy(context);
}

fn bindBrowserCallback() !std.Io.net.Server {
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    return address.listen(io_mod.getIo(), .{ .reuse_address = true });
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
    if (comptime host_target.is_wasm) return error.GrokOAuthUnavailable;
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    const manual_code = context.takeManualCode();
    defer if (manual_code) |code| secret.zeroAndFree(alloc, code);
    var accepted: ?browser_callback.Accepted(BrowserCallback) = null;
    defer if (accepted) |*callback| {
        callback.callback.deinit(alloc);
        callback.deinit();
    };
    const code = manual_code orelse code: {
        accepted = (try awaitBrowserCallback(
            alloc,
            &context.listener,
            context.state,
            cancel_flag,
        )) orelse return .pending;
        break :code accepted.?.callback.code;
    };

    var token = exchangeAuthorizationCodeForRedirectWithBounds(
        alloc,
        transport,
        metadata.token_endpoint,
        code,
        context.code_verifier,
        context.redirect_uri,
        cancel_flag,
        deadline,
    ) catch |err| {
        if (accepted) |*callback| callback.respond(.failed) catch {};
        return err;
    };
    errdefer token.deinit(alloc);

    const result = try oauth.takeBrowserPollResult(alloc, &token);
    context.pending_callback = accepted;
    accepted = null;
    return result;
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
        "https://accounts.x.ai",
    ) catch |err| switch (err) {
        error.OAuthCallbackListenerFailed => error.GrokOAuthCallbackListenerFailed,
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
        error.InvalidGrokOAuthCallback => return .unrelated,
        else => return .{ .failed = err },
    };
    return .{ .accepted = callback };
}

fn completeSignIn(
    raw: ?*anyopaque,
    alloc: Allocator,
    _: oauth_transport.Provider,
    _: []const u8,
    _: []const u8,
    token: *oauth.TokenSet,
) !login_flow.SignInCompletion {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
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
        .vercel, .chatgpt => return error.InvalidSignInCompletion,
    };
    try grok_session.saveNewSession(alloc, session);
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
    if (!try startSignIn(&runtime, alloc, transport)) return error.GrokLoginBusy;

    const authorization_url = (try runtime.browserUrlAlloc(alloc)) orelse
        return error.GrokAuthorizationUrlMissing;
    defer alloc.free(authorization_url);
    try writeStdout("Open this URL to sign in with Grok:\n");
    try writeStdout(authorization_url);
    try writeStdout("\n\nWaiting for browser authorization...\n");
    try writeStdout("Paste the code shown by xAI and press enter if the browser doesn't return.\n");
    if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) {
        _ = url_opener.open(alloc, authorization_url) catch false;
    }

    var stdin_code: StdinManualCodeReader = .{};
    defer stdin_code.deinit();
    while (true) {
        if (try stdin_code.poll()) |code| {
            _ = try runtime.submitManualCode(alloc, code);
            stdin_code.clear();
        }
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

const StdinManualCodeReader = struct {
    buffer: [login_flow.max_manual_code_bytes]u8 = undefined,
    len: usize = 0,
    closed: bool = false,

    fn poll(self: *StdinManualCodeReader) !?[]const u8 {
        if (self.closed) return null;
        var fds = [_]std.posix.pollfd{.{
            .fd = std.posix.STDIN_FILENO,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, 0);
        if (ready == 0 or
            (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) == 0) return null;

        var chunk: [512]u8 = undefined;
        defer @memset(&chunk, 0);
        const read_len = try std.posix.read(std.posix.STDIN_FILENO, &chunk);
        if (read_len == 0) {
            self.closed = true;
            return if (self.len == 0) null else self.buffer[0..self.len];
        }
        const line_end = std.mem.findScalar(u8, chunk[0..read_len], '\n') orelse read_len;
        if (line_end > self.buffer.len - self.len) return error.GrokAuthorizationCodeTooLong;
        @memcpy(self.buffer[self.len..][0..line_end], chunk[0..line_end]);
        self.len += line_end;
        if (line_end < read_len) {
            self.closed = true;
            return self.buffer[0..self.len];
        }
        return null;
    }

    fn clear(self: *StdinManualCodeReader) void {
        @memset(self.buffer[0..self.len], 0);
        self.len = 0;
    }

    fn deinit(self: *StdinManualCodeReader) void {
        @memset(&self.buffer, 0);
        self.* = undefined;
    }
};

pub const LogoutResult = struct {
    deletion: grok_session.DeleteOutcome,
    revocation_failed: bool,
};

pub fn logout(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    before_revocation: ?oauth.BeforeRevocation,
) !LogoutResult {
    const local = try logoutLocally(alloc);
    defer if (local.refresh_token) |token| secret.zeroAndFree(alloc, token);
    var result = local.result;
    if (local.refresh_token) |token| {
        if (before_revocation) |notice| notice.run(notice.context);
        revokeToken(alloc, transport, token) catch {
            result.revocation_failed = true;
        };
    }
    return result;
}

/// The outcome of deleting the saved Grok session, with its refresh token kept
/// so it can still be revoked.
pub const LocalLogout = struct {
    result: LogoutResult,
    /// Owned by the caller when set; release it with `secret.zeroAndFree`
    /// using the allocator passed to `logoutLocally`.
    refresh_token: ?[]u8 = null,
};

/// Deletes the saved Grok session without contacting xAI. Revoke the returned
/// refresh token with `revokeToken`, then release it. The session is deleted
/// first, so a failed deletion never leaves a revoked token on disk.
pub fn logoutLocally(alloc: Allocator) !LocalLogout {
    var mutation = (try grok_session.beginExistingMutation()) orelse return .{ .result = .{
        .deletion = .missing,
        .revocation_failed = false,
    } };
    defer mutation.deinit();
    var revocation_failed = false;
    var refresh_token: ?[]u8 = null;
    errdefer if (refresh_token) |token| secret.zeroAndFree(alloc, token);
    const loaded_session = mutation.load(alloc) catch |err| blk: {
        debug_trace.logf("auth", "Grok logout could not load the saved credential err={s}", .{@errorName(err)});
        revocation_failed = true;
        break :blk null;
    };
    if (loaded_session) |loaded| {
        var session = loaded;
        defer session.deinit(alloc);
        refresh_token = try alloc.dupe(u8, session.refresh_token);
    }
    return .{
        .result = .{
            .deletion = try mutation.delete(),
            .revocation_failed = revocation_failed,
        },
        .refresh_token = refresh_token,
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
    appendTeamPrincipal(alloc, &form, &body.writer, session.access_token) catch |err| switch (err) {
        error.InvalidGrokAccessToken => {
            debug_trace.logf("auth", "retiring Grok session whose saved token names no usable Team", .{});
            try retireRefreshSession(mutation);
            return error.CredentialRefreshRejected;
        },
        else => return err,
    };
    // Each request has its whole budget from a fresh stamp, so another fx
    // waits for this one however slowly xAI answers.
    mutation.restamp();
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

    // The replacement asks xAI for the account the new token belongs to.
    mutation.restamp();
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
    const endpoint_url = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
    defer alloc.free(endpoint_url);
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
    return oauth.parseBrowserTokenSet(alloc, bytes) catch |err| switch (err) {
        error.InvalidOAuthResponse => return error.InvalidGrokOAuthResponse,
        else => return err,
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

/// The account `access_token` belongs to. Caller owns the returned id.
fn fetchAccountId(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    access_token: []const u8,
) ![]u8 {
    // userinfo has no personal identity for a Team token (#461).
    if (try teamPrincipalId(alloc, access_token)) |team_id| return team_id;

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

const team_principal_type = "Team";

/// The Grok Team `access_token` was issued for, from its `principal_type`
/// and `principal_id` claims, or null for a personal account or a token
/// without them. A Team token with no usable id is
/// `error.InvalidGrokAccessToken`. The token comes straight from xAI's token
/// endpoint over TLS, so its signature is not checked here. Caller owns the
/// returned id. (`tests/tla/grok_oauth/GrokIdentity.tla` UsableSignInCompletes)
fn teamPrincipalId(alloc: Allocator, access_token: []const u8) !?[]u8 {
    var parts = std.mem.splitScalar(u8, access_token, '.');
    _ = parts.next(); // the header
    const encoded = parts.next() orelse return null;
    _ = parts.next() orelse return null; // the signature
    if (parts.next() != null) return null;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const payload = try alloc.alloc(u8, decoder.calcSizeForSlice(encoded) catch return null);
    defer secret.zeroAndFree(alloc, payload);
    decoder.decode(payload, encoded) catch return null;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const claims = parsed.value.object;

    const principal_type = claims.get("principal_type") orelse claims.get("principalType") orelse return null;
    if (principal_type != .string or !std.mem.eql(u8, principal_type.string, team_principal_type)) return null;
    const principal_id = claims.get("principal_id") orelse claims.get("principalId") orelse
        return error.InvalidGrokAccessToken;
    if (principal_id != .string or !grok_session.validAccountId(principal_id.string)) {
        return error.InvalidGrokAccessToken;
    }
    return try alloc.dupe(u8, principal_id.string);
}

/// Names the Team `access_token` was issued for in a refresh form. Without
/// it xAI refreshes into the person's own account, which fx then rejects as
/// another account. A personal token adds nothing.
/// (`tests/tla/grok_oauth/GrokIdentity.tla` RefreshKeepsAccount)
fn appendTeamPrincipal(
    alloc: Allocator,
    form: *FormBody,
    writer: *std.Io.Writer,
    access_token: []const u8,
) !void {
    const team_id = (try teamPrincipalId(alloc, access_token)) orelse return;
    defer alloc.free(team_id);
    try form.append(writer, "principal_type", team_principal_type);
    try form.append(writer, "principal_id", team_id);
}

pub fn revokeToken(
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
    try out.writer.print("{s}/oauth2/authorize?", .{std.mem.trimEnd(u8, issuer, "/")});
    var form: FormBody = .{};
    try form.append(&out.writer, "response_type", "code");
    try form.append(&out.writer, "client_id", client_id);
    try form.append(&out.writer, "redirect_uri", redirect_uri);
    try form.append(&out.writer, "scope", browser_scope);
    try form.append(&out.writer, "code_challenge", code_challenge);
    try form.append(&out.writer, "code_challenge_method", "S256");
    try form.append(&out.writer, "state", state);
    try form.append(&out.writer, "referrer", "fx");
    return out.toOwnedSlice();
}

fn parseBrowserCallbackTarget(
    alloc: Allocator,
    target: []const u8,
    expected_state: []const u8,
) !BrowserCallback {
    const prefix = "/callback?";
    if (!std.mem.startsWith(u8, target, prefix) or std.mem.findScalar(u8, target, '#') != null) {
        return error.InvalidGrokOAuthCallback;
    }
    const query = target[prefix.len..];
    if (queryValueAlloc(alloc, query, "error")) |denial| {
        alloc.free(denial);
        const denial_state = queryValueAlloc(alloc, query, "state") catch
            return error.InvalidGrokOAuthCallback;
        defer secret.zeroAndFree(alloc, denial_state);
        if (!std.mem.eql(u8, denial_state, expected_state)) return error.GrokOAuthStateMismatch;
        return error.GrokAuthorizationFailed;
    } else |_| {}
    const code = try queryValueAlloc(alloc, query, "code");
    errdefer secret.zeroAndFree(alloc, code);
    const state = try queryValueAlloc(alloc, query, "state");
    defer secret.zeroAndFree(alloc, state);
    if (!std.mem.eql(u8, state, expected_state)) return error.GrokOAuthStateMismatch;
    return .{ .code = code };
}

fn queryValueAlloc(alloc: Allocator, query: []const u8, key: []const u8) ![]u8 {
    return oauth.queryValueNonEmptyAlloc(alloc, query, key) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGrokOAuthCallback,
    };
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

/// Writes an access token whose payload is `payload`, between a header and a
/// signature that fx never checks.
fn writeTestAccessToken(writer: *std.Io.Writer, payload: []const u8) !void {
    try writer.writeAll("eyJhbGciOiJSUzI1NiJ9.");
    try std.base64.url_safe_no_pad.Encoder.encodeWriter(writer, payload);
    try writer.writeAll(".signature");
}

fn testAccessToken(alloc: Allocator, payload: []const u8) ![]u8 {
    var token: std.Io.Writer.Allocating = .init(alloc);
    errdefer token.deinit();
    try writeTestAccessToken(&token.writer, payload);
    return token.toOwnedSlice();
}

/// A userinfo endpoint that counts its requests. With `refuse_all` it answers
/// 403, as the reporters of #461 say xAI's does for a Team token.
const TestUserInfo = struct {
    refuse_all: bool,
    requests: usize = 0,

    fn execute(raw: ?*anyopaque, alloc: Allocator, _: oauth_transport.Request) !oauth_transport.Response {
        const self: *TestUserInfo = @ptrCast(@alignCast(raw.?));
        self.requests += 1;
        if (self.refuse_all) {
            return .{ .disposition = .rejected, .body = try alloc.dupe(u8, "{\"error\":\"insufficient_scope\"}") };
        }
        return .{ .disposition = .accepted, .body = try alloc.dupe(u8, "{\"sub\":\"user_from_userinfo\"}") };
    }

    fn transport(self: *TestUserInfo) oauth_transport.Provider {
        return .{ .context = self, .execute_fn = execute };
    }
};

test "a Grok Team account is named by the principal in its access token, not userinfo" {
    const alloc = std.testing.allocator;
    const text_utils = @import("../shared/text_utils.zig");
    const longest_id = text_utils.repeat("t", 1024);
    const payloads = [_][]const u8{
        "{\"principal_type\":\"Team\",\"principal_id\":\"team_test\"}",
        "{\"principalType\":\"Team\",\"principalId\":\"team_test\"}",
        "{\"sub\":\"user\",\"principal_type\":\"Team\",\"principal_id\":\"team_test\",\"exp\":1}",
        "{\"principal_type\":\"Team\",\"principal_id\":\"" ++ longest_id ++ "\"}",
    };
    const ids = [_][]const u8{ "team_test", "team_test", "team_test", longest_id };
    for (payloads, ids) |payload, id| {
        const token = try testAccessToken(alloc, payload);
        defer alloc.free(token);
        var userinfo: TestUserInfo = .{ .refuse_all = true };
        const account_id = try fetchAccountId(alloc, userinfo.transport(), token);
        defer alloc.free(account_id);
        try std.testing.expectEqualStrings(id, account_id);
        try std.testing.expectEqual(@as(usize, 0), userinfo.requests);
    }
}

test "a Grok Team token without a usable principal_id is refused" {
    const alloc = std.testing.allocator;
    const text_utils = @import("../shared/text_utils.zig");
    const payloads = [_][]const u8{
        "{\"principal_type\":\"Team\"}",
        "{\"principal_type\":\"Team\",\"principal_id\":\"\"}",
        "{\"principal_type\":\"Team\",\"principal_id\":\"team test\"}",
        "{\"principal_type\":\"Team\",\"principal_id\":\"team\\ninjected\"}",
        "{\"principal_type\":\"Team\",\"principal_id\":42}",
        "{\"principal_type\":\"Team\",\"principal_id\":\"" ++ text_utils.repeat("t", 1025) ++ "\"}",
    };
    for (payloads) |payload| {
        const token = try testAccessToken(alloc, payload);
        defer alloc.free(token);
        var userinfo: TestUserInfo = .{ .refuse_all = true };
        try std.testing.expectError(error.InvalidGrokAccessToken, fetchAccountId(alloc, userinfo.transport(), token));
        try std.testing.expectEqual(@as(usize, 0), userinfo.requests);
    }
}

test "Grok personal and claimless tokens keep the userinfo path" {
    const alloc = std.testing.allocator;
    const payloads = [_][]const u8{
        "{\"principal_type\":\"User\",\"principal_id\":\"user_from_claim\"}",
        "{\"principal_type\":\"team\",\"principal_id\":\"user_from_claim\"}",
        "{\"sub\":\"user_from_claim\"}",
        "[\"principal_type\",\"Team\"]",
        "not json",
    };
    for (payloads) |payload| {
        const token = try testAccessToken(alloc, payload);
        defer alloc.free(token);
        var userinfo: TestUserInfo = .{ .refuse_all = false };
        const account_id = try fetchAccountId(alloc, userinfo.transport(), token);
        defer alloc.free(account_id);
        try std.testing.expectEqualStrings("user_from_userinfo", account_id);
        try std.testing.expectEqual(@as(usize, 1), userinfo.requests);
    }
    // Tokens that are not a three-part JWT, or whose payload is not base64url.
    for ([_][]const u8{ "access-token", "header.payload", "a.b.c.d", "header.!!!.signature", "header..signature" }) |token| {
        var userinfo: TestUserInfo = .{ .refuse_all = false };
        const account_id = try fetchAccountId(alloc, userinfo.transport(), token);
        defer alloc.free(account_id);
        try std.testing.expectEqualStrings("user_from_userinfo", account_id);
        try std.testing.expectEqual(@as(usize, 1), userinfo.requests);
    }
}

test "a Grok Team refresh names its Team, and a personal one names no principal" {
    const alloc = std.testing.allocator;
    const team_form = "refresh_token=r&principal_type=Team&principal_id=team-test";
    const cases = [_]struct { payload: []const u8, form: []const u8 }{
        .{ .payload = "{\"principal_type\":\"Team\",\"principal_id\":\"team-test\"}", .form = team_form },
        .{ .payload = "{\"principalType\":\"Team\",\"principalId\":\"team-test\"}", .form = team_form },
        .{ .payload = "{\"principal_type\":\"User\",\"principal_id\":\"user_test\"}", .form = "refresh_token=r" },
        .{ .payload = "{\"sub\":\"user_test\"}", .form = "refresh_token=r" },
    };
    for (cases) |case| {
        const token = try testAccessToken(alloc, case.payload);
        defer alloc.free(token);
        var body: std.Io.Writer.Allocating = .init(alloc);
        defer body.deinit();
        var form: FormBody = .{};
        try form.append(&body.writer, "refresh_token", "r");
        try appendTeamPrincipal(alloc, &form, &body.writer, token);
        try std.testing.expectEqualStrings(case.form, body.written());
    }

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    var form: FormBody = .{};
    try appendTeamPrincipal(alloc, &form, &body.writer, "access-token");
    try std.testing.expectEqualStrings("", body.written());

    const unusable = try testAccessToken(alloc, "{\"principal_type\":\"Team\",\"principal_id\":\"team test\"}");
    defer alloc.free(unusable);
    try std.testing.expectError(error.InvalidGrokAccessToken, appendTeamPrincipal(alloc, &form, &body.writer, unusable));
}

fn fuzzTeamPrincipal(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    var raw: [256]u8 = undefined;
    const bytes = raw[0..smith.slice(&raw)];
    var token: std.Io.Writer.Allocating = .init(alloc);
    defer token.deinit();
    // What a token built from chosen claims must give.
    var want: ?enum { none, team, refused } = null;
    switch (smith.valueRangeAtMost(u8, 0, 2)) {
        // Arbitrary bytes as the whole token.
        0 => try token.writer.writeAll(bytes),
        // Arbitrary bytes as the payload of a three-part token.
        1 => try writeTestAccessToken(&token.writer, bytes),
        // Claims with a chosen principal_type, spelled either way, and an
        // ASCII principal_id, so it survives JSON unchanged.
        else => {
            for (bytes) |*byte| byte.* &= 0x7f;
            const types = [_][]const u8{ team_principal_type, "User", "team", "" };
            const principal_type = types[smith.valueRangeAtMost(u8, 0, types.len - 1)];
            var claims: std.Io.Writer.Allocating = .init(alloc);
            defer claims.deinit();
            if (smith.valueRangeAtMost(u8, 0, 1) == 0) {
                try std.json.Stringify.value(.{ .principal_type = principal_type, .principal_id = bytes }, .{}, &claims.writer);
            } else {
                try std.json.Stringify.value(.{ .principalType = principal_type, .principalId = bytes }, .{}, &claims.writer);
            }
            try writeTestAccessToken(&token.writer, claims.written());
            want = if (!std.mem.eql(u8, principal_type, team_principal_type))
                .none
            else if (grok_session.validAccountId(bytes)) .team else .refused;
        },
    }

    const team_id = teamPrincipalId(alloc, token.written()) catch |err| {
        try std.testing.expect(err == error.InvalidGrokAccessToken);
        if (want) |expected| try std.testing.expect(expected == .refused);
        return;
    } orelse {
        if (want) |expected| try std.testing.expect(expected == .none);
        return;
    };
    defer alloc.free(team_id);
    try std.testing.expect(grok_session.validAccountId(team_id));
    if (want) |expected| {
        try std.testing.expect(expected == .team);
        try std.testing.expectEqualStrings(bytes, team_id);
    }
}

test "a Grok access token gives its Team, none, or a refusal on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzTeamPrincipal, .{
        .corpus = &(@import("fuzz_seed").slices(.{""}) ++ @import("fuzz_corpus").grok_access_token.*),
    });
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
            return .{
                .disposition = .accepted,
                .body = try alloc.dupe(u8, "{\"access_token\":\"new-access\",\"expires_in\":3600}"),
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

test "Grok browser authorization URL uses PKCE without device authentication" {
    const url = try buildBrowserAuthorizationUrl(
        std.testing.allocator,
        "https://auth.x.ai",
        "http://127.0.0.1:1455/callback",
        "challenge-value",
        "state-value",
    );
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.startsWith(u8, url, "https://auth.x.ai/oauth2/authorize?"));
    try std.testing.expect(std.mem.find(u8, url, "response_type=code") != null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge=challenge-value") != null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.find(u8, url, "state=state-value") != null);
    try std.testing.expect(std.mem.find(u8, url, "referrer=fx") != null);
    try std.testing.expect(std.mem.find(u8, url, "nonce") == null);
    try std.testing.expect(std.mem.find(u8, url, "device") == null);
}

test "Grok browser callback uses an ephemeral port" {
    var listener = try bindBrowserCallback();
    defer listener.deinit(io_mod.getIo());

    const port = listener.socket.address.getPort();
    try std.testing.expect(port != 8976 and port != 8977);
}

test "Grok browser callback classifier rejects mismatched state" {
    var context = BrowserCallbackParserContext{ .expected_state = "expected" };

    const stale_success = classifyBrowserCallback(
        &context,
        std.testing.allocator,
        "/callback?code=stale&state=other",
    );
    switch (stale_success) {
        .failed => |err| try std.testing.expectEqual(error.GrokOAuthStateMismatch, err),
        else => return error.ExpectedFailedCallback,
    }

    const stale_denial = classifyBrowserCallback(
        &context,
        std.testing.allocator,
        "/callback?error=access_denied&state=other",
    );
    switch (stale_denial) {
        .failed => |err| try std.testing.expectEqual(error.GrokOAuthStateMismatch, err),
        else => return error.ExpectedFailedCallback,
    }
}

test "Grok browser callback classifier reports a current denial" {
    var context = BrowserCallbackParserContext{ .expected_state = "expected" };
    const denied = classifyBrowserCallback(
        &context,
        std.testing.allocator,
        "/callback?error=access_denied&state=expected",
    );
    switch (denied) {
        .failed => |err| try std.testing.expectEqual(error.GrokAuthorizationFailed, err),
        else => return error.ExpectedFailedCallback,
    }
}

test "Grok browser callback requires the exact path and state" {
    var callback = try parseBrowserCallbackTarget(
        std.testing.allocator,
        "/callback?code=auth%20code&state=expected",
        "expected",
    );
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("auth code", callback.code);

    try std.testing.expectError(
        error.GrokOAuthStateMismatch,
        parseBrowserCallbackTarget(
            std.testing.allocator,
            "/callback?code=auth&state=other",
            "expected",
        ),
    );
    try std.testing.expectError(
        error.InvalidGrokOAuthCallback,
        parseBrowserCallbackTarget(
            std.testing.allocator,
            "/other?code=auth&state=expected",
            "expected",
        ),
    );
}
