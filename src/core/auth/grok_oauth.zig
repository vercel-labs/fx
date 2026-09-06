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

const client_id = "b1a00492-073a-47ea-816f-4c329264a828";
const token_url = "https://auth.x.ai/oauth2/token";
const issuer_url = "https://auth.x.ai";
const userinfo_url = "https://auth.x.ai/oauth2/userinfo";
const revoke_url = "https://auth.x.ai/oauth2/revoke";
const e2e_token_url_env = "FX_E2E_GROK_TOKEN_URL";
const e2e_issuer_url_env = "FX_E2E_GROK_ISSUER_URL";
const e2e_userinfo_url_env = "FX_E2E_GROK_USERINFO_URL";
const e2e_revoke_url_env = "FX_E2E_GROK_REVOKE_URL";
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
    errdefer alloc.free(configured_token_endpoint);

    var listener = try bindBrowserCallback();
    var listener_owned = true;
    errdefer if (listener_owned) listener.deinit(io_mod.getIo());
    const callback_port = listener.socket.address.getPort();
    const redirect_uri = try std.fmt.allocPrint(
        alloc,
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
    errdefer alloc.free(authorization_url);

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

    const owned_issuer = try alloc.dupe(u8, configured_issuer);
    errdefer alloc.free(owned_issuer);
    const authorization_endpoint = try std.fmt.allocPrint(
        alloc,
        "{s}/oauth2/authorize",
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

fn bindBrowserCallback() !std.Io.net.Server {
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    return address.listen(io_mod.getIo(), .{ .reuse_address = true });
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

    const scope = try alloc.dupe(u8, "");
    errdefer if (scope.len > 0) alloc.free(scope);
    const token_type = try alloc.dupe(u8, "Bearer");
    errdefer alloc.free(token_type);
    const access_token = token.access_token;
    token.access_token = &.{};
    const refresh_token = token.refresh_token;
    token.refresh_token = &.{};
    context.pending_callback = accepted;
    accepted = null;
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
    try writeStdout("Paste the code shown by xAI and press Enter if the browser doesn't return.\n");
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
            try retire_refresh_session(mutation);
            return error.CredentialRefreshRejected;
        },
        else => return err,
    };
    defer token.deinit(alloc);

    var replacement = refresh_replacement(alloc, transport, &token, session.*) catch |err| {
        if (err == error.OutOfMemory) return err;
        debug_trace.logf("auth", "retiring unusable Grok refresh reason={s}", .{@errorName(err)});
        try retire_refresh_session(mutation);
        if (err == error.GrokAccountChanged) return err;
        return error.CredentialRefreshRejected;
    };
    errdefer replacement.deinit(alloc);
    mutation.save(alloc, replacement) catch |err| {
        debug_trace.logf("auth", "retiring Grok session after refresh save failed err={s}", .{@errorName(err)});
        retire_refresh_session(mutation) catch |cleanup_err| {
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

fn refresh_replacement(
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

fn retire_refresh_session(mutation: *grok_session.Mutation) !void {
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
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGrokOAuthResponse;
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
        return error.InvalidE2EGrokEndpoint;
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

fn fetchAccountId(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    access_token: []const u8,
) ![]u8 {
    const endpoint_url = try configuredEndpoint(alloc, e2e_userinfo_url_env, userinfo_url);
    defer alloc.free(endpoint_url);
    const authorization = try std.fmt.allocPrint(alloc, "Bearer {s}", .{access_token});
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

fn requiredPositiveInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidGrokOAuthResponse;
    if (value != .integer or value.integer <= 0) return error.InvalidGrokOAuthResponse;
    return value.integer;
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
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], key)) continue;
        return percentDecodeAlloc(alloc, pair[equals + 1 ..]);
    }
    return error.InvalidGrokOAuthCallback;
}

fn percentDecodeAlloc(alloc: Allocator, value: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, value.len);
    errdefer alloc.free(out);
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < value.len) {
        if (value[read_index] == '%') {
            if (read_index + 2 >= value.len) return error.InvalidGrokOAuthCallback;
            const high = std.fmt.charToDigit(value[read_index + 1], 16) catch
                return error.InvalidGrokOAuthCallback;
            const low = std.fmt.charToDigit(value[read_index + 2], 16) catch
                return error.InvalidGrokOAuthCallback;
            out[write_index] = @as(u8, @intCast(high * 16 + low));
            read_index += 3;
        } else {
            out[write_index] = if (value[read_index] == '+') ' ' else value[read_index];
            read_index += 1;
        }
        write_index += 1;
    }
    if (write_index == 0) return error.InvalidGrokOAuthCallback;
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
