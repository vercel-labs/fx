const std = @import("std");
const claude_code_store = @import("claude_code_store.zig");
const claude_session = @import("claude_session.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const login_flow = @import("login_flow.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const issuer_url = "https://claude.ai";
const authorize_url = "https://claude.ai/oauth/authorize";
const token_url = "https://console.anthropic.com/v1/oauth/token";
const userinfo_url = "https://api.anthropic.com/api/oauth/profile";
pub const anthropic_api_version = "2023-06-01";
pub const oauth_beta = "oauth-2025-04-20";
pub const messages_beta = claude_code_store.messages_beta;
pub const messages_originator = claude_code_store.originator;
pub const messages_user_agent = claude_code_store.user_agent;
pub const oauth_api_headers = [_]std.http.Header{
    .{ .name = "anthropic-version", .value = anthropic_api_version },
    .{ .name = "anthropic-beta", .value = oauth_beta },
};
const e2e_issuer_url_env = "FX_E2E_CLAUDE_ISSUER_URL";
const e2e_authorize_url_env = "FX_E2E_CLAUDE_AUTHORIZE_URL";
const e2e_token_url_env = "FX_E2E_CLAUDE_TOKEN_URL";
const e2e_userinfo_url_env = "FX_E2E_CLAUDE_USERINFO_URL";
const browser_scope = "user:profile user:inference user:sessions:claude_code user:mcp_servers";
const browser_redirect_uri = "https://console.anthropic.com/oauth/code/callback";
const browser_login_timeout_seconds: i64 = 5 * 60;
const browser_callback_poll_ms: i32 = 100;
const browser_callback_io_timeout_seconds: i64 = 30;

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
    paste_mutex: std.Io.Mutex = .init,
    pasted_code: ?[]u8 = null,

    fn deinit(self: *BrowserLoginContext, alloc: Allocator) void {
        self.listener.deinit(io_mod.getIo());
        alloc.free(self.redirect_uri);
        secret.zeroAndFree(alloc, self.code_verifier);
        secret.zeroAndFree(alloc, self.state);
        if (self.pasted_code) |code| secret.zeroAndFree(alloc, code);
        self.* = undefined;
    }

    fn takePastedCode(self: *BrowserLoginContext) ?[]u8 {
        self.paste_mutex.lockUncancelable(io_mod.getIo());
        defer self.paste_mutex.unlock(io_mod.getIo());
        const code = self.pasted_code;
        self.pasted_code = null;
        return code;
    }

    fn setPastedCode(self: *BrowserLoginContext, alloc: Allocator, code: []const u8) !void {
        const owned = try alloc.dupe(u8, code);
        self.paste_mutex.lockUncancelable(io_mod.getIo());
        defer self.paste_mutex.unlock(io_mod.getIo());
        if (self.pasted_code) |previous| secret.zeroAndFree(alloc, previous);
        self.pasted_code = owned;
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
        },
    );
}

fn prepareBrowserSignIn(alloc: Allocator, transport: oauth_transport.Provider) !PreparedBrowserLogin {
    const configured_authorize = try configuredEndpoint(alloc, e2e_authorize_url_env, authorize_url);
    defer alloc.free(configured_authorize);
    const configured_token_endpoint = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
    errdefer alloc.free(configured_token_endpoint);

    var listener = try bindBrowserCallback();
    var listener_owned = true;
    errdefer if (listener_owned) listener.deinit(io_mod.getIo());
    const e2e = io_mod.getenv(e2e_authorize_url_env) != null;
    const redirect_uri = if (e2e)
        try std.fmt.allocPrint(
            alloc,
            "http://127.0.0.1:{d}/callback",
            .{listener.socket.address.getPort()},
        )
    else
        try alloc.dupe(u8, browser_redirect_uri);
    errdefer alloc.free(redirect_uri);
    const code_verifier = try randomUrlSafeSecret(alloc);
    errdefer secret.zeroAndFree(alloc, code_verifier);
    const state = try randomUrlSafeSecret(alloc);
    errdefer secret.zeroAndFree(alloc, state);
    const code_challenge = try pkceChallengeAlloc(alloc, code_verifier);
    defer alloc.free(code_challenge);
    const authorization_url = try buildBrowserAuthorizationUrl(
        alloc,
        configured_authorize,
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

    const owned_authorize = try alloc.dupe(u8, configured_authorize);
    errdefer alloc.free(owned_authorize);
    const device_code = try alloc.dupe(u8, "");
    errdefer secret.zeroAndFree(alloc, device_code);
    const user_code = try alloc.dupe(u8, "");
    errdefer alloc.free(user_code);
    const owned_client_id = try alloc.dupe(u8, client_id);
    errdefer alloc.free(owned_client_id);
    const owned_issuer = try alloc.dupe(u8, issuer_url);
    errdefer alloc.free(owned_issuer);

    return .{
        .prepared = .{
            .metadata = .{
                .issuer = owned_issuer,
                .device_authorization_endpoint = owned_authorize,
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
    if (comptime host_target.is_wasm) return error.ClaudeOAuthUnavailable;
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    if (context.takePastedCode()) |code| {
        defer secret.zeroAndFree(alloc, code);
        var token = try exchangeAuthorizationCodeForRedirectWithBounds(
            alloc,
            transport,
            metadata.token_endpoint,
            code,
            context.code_verifier,
            context.redirect_uri,
            context.state,
            cancel_flag,
            deadline,
        );
        errdefer token.deinit(alloc);
        const scope = try alloc.dupe(u8, "");
        errdefer if (scope.len > 0) alloc.free(scope);
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
    if (!try browserCallbackReady(&context.listener, cancel_flag)) return .pending;

    var stream = try context.listener.accept(io_mod.getIo());
    defer stream.close(io_mod.getIo());
    setBrowserSocketTimeouts(stream.socket.handle);
    const target = try readBrowserCallbackTarget(alloc, stream);
    defer alloc.free(target);
    var callback = parseBrowserCallbackTarget(alloc, target, context.state) catch |err| {
        writeBrowserCallbackResponse(stream, false) catch {};
        return err;
    };
    defer callback.deinit(alloc);

    var token = exchangeAuthorizationCodeForRedirectWithBounds(
        alloc,
        transport,
        metadata.token_endpoint,
        callback.code,
        context.code_verifier,
        context.redirect_uri,
        context.state,
        cancel_flag,
        deadline,
    ) catch |err| {
        writeBrowserCallbackResponse(stream, false) catch {};
        return err;
    };
    errdefer token.deinit(alloc);
    try writeBrowserCallbackResponse(stream, true);

    const scope = try alloc.dupe(u8, "");
    errdefer if (scope.len > 0) alloc.free(scope);
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

fn browserCallbackReady(
    listener: *std.Io.net.Server,
    cancel_flag: *std.atomic.Value(bool),
) !bool {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var fds = [_]std.posix.pollfd{.{
        .fd = listener.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, browser_callback_poll_ms);
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (ready == 0) return false;
    if ((fds[0].revents & std.posix.POLL.IN) == 0) {
        return error.InvalidClaudeOAuthCallback;
    }
    return true;
}

fn readBrowserCallbackTarget(alloc: Allocator, stream: std.Io.net.Stream) ![]u8 {
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &socket_buffer);
    var request_bytes: [16 * 1024]u8 = undefined;
    var request_len: usize = 0;
    while (request_len < request_bytes.len) {
        request_bytes[request_len] = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.InvalidClaudeOAuthCallback,
            else => return err,
        };
        request_len += 1;
        if (std.mem.endsWith(u8, request_bytes[0..request_len], "\r\n\r\n")) break;
    }
    if (request_len == request_bytes.len) return error.ClaudeOAuthCallbackTooLarge;
    const line_end = std.mem.find(u8, request_bytes[0..request_len], "\r\n") orelse
        return error.InvalidClaudeOAuthCallback;
    const request_line = request_bytes[0..line_end];
    if (!std.mem.startsWith(u8, request_line, "GET ")) {
        return error.InvalidClaudeOAuthCallback;
    }
    const target_end = std.mem.findScalarPos(u8, request_line, 4, ' ') orelse
        return error.InvalidClaudeOAuthCallback;
    return alloc.dupe(u8, request_line[4..target_end]);
}

fn writeBrowserCallbackResponse(stream: std.Io.net.Stream, success: bool) !void {
    const body = if (success)
        "Authorization complete. You can return to fx."
    else
        "Authorization failed. Return to fx for details.";
    var buffer: [1024]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.print(
        "HTTP/1.1 {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ if (success) "200 OK" else "400 Bad Request", body.len, body },
    );
    try writer.interface.flush();
}

fn setBrowserSocketTimeouts(socket: std.posix.socket_t) void {
    const timeout = std.posix.timeval{ .sec = browser_callback_io_timeout_seconds, .usec = 0 };
    const bytes = std.mem.asBytes(&timeout);
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch |err| {
        debug_trace.logf("auth", "Claude callback receive timeout setup failed err={s}", .{@errorName(err)});
    };
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch |err| {
        debug_trace.logf("auth", "Claude callback send timeout setup failed err={s}", .{@errorName(err)});
    };
}

fn completeSignIn(
    raw: ?*anyopaque,
    alloc: Allocator,
    _: []const u8,
    _: []const u8,
    token: *oauth.TokenSet,
) !login_flow.SignInCompletion {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    const refresh_token = token.refresh_token orelse return error.ClaudeRefreshTokenMissing;
    const account_id = try fetchAccountId(alloc, context.transport, token.access_token);
    errdefer alloc.free(account_id);
    const duration_ms = std.math.mul(i64, token.expires_in, std.time.ms_per_s) catch
        return error.InvalidClaudeOAuthResponse;
    const expires_at_ms = std.math.add(i64, io_mod.milliTimestamp(), duration_ms) catch
        return error.InvalidClaudeOAuthResponse;
    const completion: login_flow.SignInCompletion = .{ .claude = .{
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
        .claude => |session| session,
        .vercel, .chatgpt, .grok => return error.InvalidSignInCompletion,
    };
    try claude_session.saveNewSession(alloc, session);
}

pub fn runLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !void {
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    if (!try startSignIn(&runtime, alloc, transport)) return error.ClaudeLoginBusy;

    const authorization_url = (try runtime.browserUrlAlloc(alloc)) orelse
        return error.ClaudeAuthorizationUrlMissing;
    defer alloc.free(authorization_url);
    try writeStdout("Open this URL to sign in with Claude:\n");
    try writeStdout(authorization_url);
    try writeStdout("\n\nAfter you authorize, paste the code from the browser and press Enter.\n");
    if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) {
        _ = url_opener.open(alloc, authorization_url) catch false;
    }

    var paste_line: std.ArrayList(u8) = .empty;
    defer {
        if (paste_line.items.len > 0) std.crypto.secureZero(u8, @volatileCast(paste_line.items));
        paste_line.deinit(alloc);
    }
    var stdin_buf: [1024]u8 = undefined;
    while (true) {
        if (try stdinHasInput(50)) {
            const n = std.posix.read(std.posix.STDIN_FILENO, &stdin_buf) catch 0;
            if (n > 0) {
                try paste_line.appendSlice(alloc, stdin_buf[0..n]);
                if (std.mem.findScalar(u8, paste_line.items, '\n') != null) {
                    const trimmed = std.mem.trim(u8, paste_line.items, " \t\r\n");
                    if (trimmed.len > 0) {
                        submitPastedAuthorizationInput(&runtime, alloc, trimmed) catch |err| {
                            debug_trace.logf("auth", "Claude pasted authorization rejected err={s}", .{@errorName(err)});
                            return err;
                        };
                    }
                    std.crypto.secureZero(u8, @volatileCast(paste_line.items));
                    paste_line.clearRetainingCapacity();
                }
            }
        }
        switch (runtime.pollTransition(alloc)) {
            .none => {},
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

fn submitPastedAuthorizationInput(runtime: *login_flow.SignInRuntime, alloc: Allocator, input: []const u8) !void {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(runtime.deps.ctx orelse return error.InvalidClaudeOAuthCallback));
    var parsed = try parsePastedAuthorizationInput(alloc, input, context.state);
    defer parsed.deinit(alloc);
    try context.setPastedCode(alloc, parsed.code);
}

fn stdinHasInput(timeout_ms: i32) !bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = std.posix.STDIN_FILENO,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, timeout_ms);
    return ready > 0 and (fds[0].revents & std.posix.POLL.IN) != 0;
}

pub const LogoutResult = struct {
    deletion: claude_session.DeleteOutcome,
    revocation_failed: bool,
};

pub fn logout(alloc: Allocator, transport: oauth_transport.Provider) !LogoutResult {
    var mutation = (try claude_session.beginExistingMutation()) orelse return .{
        .deletion = .missing,
        .revocation_failed = false,
    };
    defer mutation.deinit();
    var revocation_failed = false;
    if (try mutation.load(alloc)) |loaded| {
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
    if (try claude_code_store.hasCredentials(alloc)) return true;
    var session = (try claude_session.load(alloc)) orelse return false;
    defer session.deinit(alloc);
    return true;
}

pub fn loadAccess(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mode: RefreshMode,
) !?Access {
    if (try loadClaudeCodeAccess(alloc, transport, mode)) |access| return access;
    if (mode == .stored) {
        var session = (try claude_session.load(alloc)) orelse return null;
        defer session.deinit(alloc);
        return takeAccess(&session);
    }

    var mutation = (try claude_session.beginExistingMutation()) orelse return null;
    defer mutation.deinit();
    var session = (try mutation.load(alloc)) orelse return null;
    defer session.deinit(alloc);

    if (mode == .force or session.expired(io_mod.milliTimestamp())) {
        try refreshSession(alloc, transport, &mutation, &session);
    }
    return takeAccess(&session);
}

fn loadClaudeCodeAccess(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mode: RefreshMode,
) !?Access {
    var stored = (try claude_code_store.load(alloc)) orelse return null;
    errdefer stored.deinit(alloc);
    if (mode != .stored and (mode == .force or stored.expired(io_mod.milliTimestamp()))) {
        refreshClaudeCodeSession(alloc, transport, &stored) catch |err| {
            debug_trace.logf("auth", "Claude Code token refresh failed err={s}", .{@errorName(err)});
            return null;
        };
        claude_code_store.save(alloc, stored) catch |err| {
            debug_trace.logf("auth", "Claude Code token persist failed err={s}", .{@errorName(err)});
        };
    }
    if (stored.account_id.len == 0 or !claude_session.validAccountId(stored.account_id)) {
        const account_id = fetchAccountId(alloc, transport, stored.access_token) catch |err| {
            debug_trace.logf("auth", "Claude Code account lookup failed err={s}", .{@errorName(err)});
            return null;
        };
        alloc.free(stored.account_id);
        stored.account_id = account_id;
    }
    if (try claude_code_store.findCli(alloc)) |cli| {
        defer alloc.free(cli);
        debug_trace.logf("auth", "Claude Code CLI detected", .{});
    }
    const access = Access{
        .access_token = stored.access_token,
        .account_id = stored.account_id,
        .refresh_after_ms = claude_code_store.refreshDeadlineMs(stored.expires_at_ms),
    };
    secret.zeroAndFree(alloc, stored.refresh_token);
    stored.access_token = &.{};
    stored.refresh_token = &.{};
    stored.account_id = &.{};
    return access;
}

fn refreshClaudeCodeSession(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    stored: *claude_code_store.Stored,
) !void {
    const payload = try jsonObjectPayload(alloc, .{
        .grant_type = "refresh_token",
        .client_id = client_id,
        .refresh_token = stored.refresh_token,
    });
    defer secret.zeroAndFree(alloc, payload);
    var token = try requestRefreshToken(alloc, transport, payload);
    defer token.deinit(alloc);
    const access_token = token.access_token;
    token.access_token = &.{};
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = if (token.refresh_token) |rotated| rotated else try alloc.dupe(u8, stored.refresh_token);
    if (token.refresh_token != null) token.refresh_token = null;
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const expires_in = token.expires_in orelse return error.InvalidClaudeOAuthResponse;
    const duration_ms = std.math.mul(i64, expires_in, std.time.ms_per_s) catch
        return error.InvalidClaudeOAuthResponse;
    const expires_at_ms = std.math.add(i64, io_mod.milliTimestamp(), duration_ms) catch
        return error.InvalidClaudeOAuthResponse;
    secret.zeroAndFree(alloc, stored.access_token);
    secret.zeroAndFree(alloc, stored.refresh_token);
    stored.access_token = access_token;
    stored.refresh_token = refresh_token;
    stored.expires_at_ms = expires_at_ms;
}

fn takeAccess(session: *claude_session.Session) Access {
    const access_token = session.access_token;
    session.access_token = &.{};
    const account_id = session.account_id;
    session.account_id = &.{};
    return .{
        .access_token = access_token,
        .account_id = account_id,
        .refresh_after_ms = claude_session.refreshDeadlineMs(session.expires_at_ms),
    };
}

fn refreshSession(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mutation: *claude_session.Mutation,
    session: *claude_session.Session,
) !void {
    const payload = try jsonObjectPayload(alloc, .{
        .grant_type = "refresh_token",
        .client_id = client_id,
        .refresh_token = session.refresh_token,
    });
    defer secret.zeroAndFree(alloc, payload);
    var token = try requestRefreshToken(alloc, transport, payload);
    defer token.deinit(alloc);

    const account_id = try fetchAccountId(alloc, transport, token.access_token);
    errdefer alloc.free(account_id);
    if (!std.mem.eql(u8, account_id, session.account_id)) {
        return error.ClaudeAccountChanged;
    }
    const refresh_token = if (token.refresh_token) |rotated| rotated else try alloc.dupe(u8, session.refresh_token);
    if (token.refresh_token != null) token.refresh_token = null;
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const expires_at_ms = if (token.expires_in) |expires_in| blk: {
        const duration_ms = std.math.mul(i64, expires_in, std.time.ms_per_s) catch
            return error.InvalidClaudeOAuthResponse;
        break :blk std.math.add(i64, io_mod.milliTimestamp(), duration_ms) catch
            return error.InvalidClaudeOAuthResponse;
    } else return error.InvalidClaudeOAuthResponse;
    var replacement = claude_session.Session{
        .access_token = token.access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
    };
    token.access_token = &.{};
    errdefer replacement.deinit(alloc);
    try mutation.save(alloc, replacement);

    session.deinit(alloc);
    session.* = replacement;
    replacement.access_token = &.{};
    replacement.refresh_token = &.{};
    replacement.account_id = &.{};
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
    const bytes = try requestAccepted(
        alloc,
        transport,
        .post_json,
        endpoint_url,
        payload,
    );
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidClaudeOAuthResponse;
    const object = parsed.value.object;
    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = if (object.get("refresh_token")) |value| blk: {
        if (value != .string or value.string.len == 0) return error.InvalidClaudeOAuthResponse;
        break :blk try alloc.dupe(u8, value.string);
    } else null;
    errdefer if (refresh_token) |token| secret.zeroAndFree(alloc, token);
    const expires_in = if (object.get("expires_in")) |value| blk: {
        if (value != .integer or value.integer <= 0) return error.InvalidClaudeOAuthResponse;
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
    state: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) !TokenSet {
    const payload = try jsonObjectPayload(alloc, .{
        .grant_type = "authorization_code",
        .code = authorization_code,
        .state = state,
        .code_verifier = code_verifier,
        .redirect_uri = redirect_uri,
        .client_id = client_id,
    });
    defer secret.zeroAndFree(alloc, payload);
    return requestTokenAtWithBounds(alloc, transport, endpoint_url, payload, cancel_flag, deadline);
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
        .post_json,
        endpoint_url,
        payload,
        cancel_flag,
        deadline,
    );
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidClaudeOAuthResponse;
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
        return error.InvalidE2EClaudeEndpoint;
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
        .extra_headers = &oauth_api_headers,
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) {
        debug_trace.logf("auth", "Claude userinfo request rejected", .{});
        return error.ClaudeUserInfoRequestFailed;
    }
    return accountIdFromProfileJson(alloc, response.body) catch |err| {
        debug_trace.logf("auth", "Claude userinfo parse failed err={s}", .{@errorName(err)});
        return err;
    };
}

fn accountIdFromProfileJson(alloc: Allocator, bytes: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return error.InvalidClaudeUserInfoResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidClaudeUserInfoResponse;
    return accountIdFromProfileObject(alloc, parsed.value.object);
}

fn accountIdFromProfileObject(alloc: Allocator, object: std.json.ObjectMap) ![]u8 {
    if (try nestedAccountId(alloc, object, "account")) |account_id| return account_id;
    if (try optionalProfileId(alloc, object, "sub")) |account_id| return account_id;
    if (try optionalProfileId(alloc, object, "uuid")) |account_id| return account_id;
    if (try nestedAccountId(alloc, object, "organization")) |account_id| return account_id;
    return error.InvalidClaudeUserInfoResponse;
}

fn nestedAccountId(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value != .object) return error.InvalidClaudeUserInfoResponse;
    if (try optionalProfileId(alloc, value.object, "uuid")) |account_id| return account_id;
    if (try optionalProfileId(alloc, value.object, "id")) |account_id| return account_id;
    return error.InvalidClaudeUserInfoResponse;
}

fn optionalProfileId(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len == 0) return error.InvalidClaudeUserInfoResponse;
    if (!claude_session.validAccountId(value.string)) return error.InvalidClaudeUserInfoResponse;
    return try alloc.dupe(u8, value.string);
}

fn revokeToken(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    token: []const u8,
) !void {
    const endpoint_url = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
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
        logRejectedOAuthBody(url, response.body);
        return error.ClaudeOAuthRequestFailed;
    }
    return response.takeBody();
}

fn jsonObjectPayload(alloc: Allocator, value: anytype) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(alloc);
    errdefer body.deinit();
    try std.json.Stringify.value(value, .{}, &body.writer);
    return body.toOwnedSlice();
}

fn logRejectedOAuthBody(url: []const u8, body: []const u8) void {
    var snippet: [160]u8 = undefined;
    const n = @min(body.len, snippet.len);
    @memcpy(snippet[0..n], body[0..n]);
    for (snippet[0..n]) |*byte| {
        if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
    }
    debug_trace.logf("auth", "Claude OAuth request rejected url={s} body={s}", .{ url, snippet[0..n] });
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidClaudeOAuthResponse;
    if (value != .string or value.string.len == 0) return error.InvalidClaudeOAuthResponse;
    return alloc.dupe(u8, value.string);
}

fn requiredPositiveInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidClaudeOAuthResponse;
    if (value != .integer or value.integer <= 0) return error.InvalidClaudeOAuthResponse;
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
    authorize: []const u8,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{s}?", .{std.mem.trimEnd(u8, authorize, "/")});
    var form: FormBody = .{};
    try form.append(&out.writer, "code", "true");
    try form.append(&out.writer, "response_type", "code");
    try form.append(&out.writer, "client_id", client_id);
    try form.append(&out.writer, "redirect_uri", redirect_uri);
    try form.append(&out.writer, "scope", browser_scope);
    try form.append(&out.writer, "code_challenge", code_challenge);
    try form.append(&out.writer, "code_challenge_method", "S256");
    try form.append(&out.writer, "state", state);
    return out.toOwnedSlice();
}

fn parsePastedAuthorizationInput(alloc: Allocator, input: []const u8, expected_state: []const u8) !BrowserCallback {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidClaudeOAuthCallback;

    if (std.mem.find(u8, trimmed, "code=") != null) {
        const query_start = if (std.mem.findScalar(u8, trimmed, '?')) |index| index + 1 else 0;
        const query = trimmed[query_start..];
        const query_only = if (std.mem.findScalar(u8, query, '#')) |index| query[0..index] else query;
        const code = try queryValueAlloc(alloc, query_only, "code");
        errdefer secret.zeroAndFree(alloc, code);
        if (queryValueAlloc(alloc, query_only, "state")) |state| {
            defer secret.zeroAndFree(alloc, state);
            if (!std.mem.eql(u8, state, expected_state)) return error.ClaudeOAuthStateMismatch;
        } else |_| {}
        return .{ .code = code };
    }

    if (std.mem.findScalar(u8, trimmed, '#')) |index| {
        const code_part = trimmed[0..index];
        const state_part = trimmed[index + 1 ..];
        if (code_part.len == 0) return error.InvalidClaudeOAuthCallback;
        if (!std.mem.eql(u8, state_part, expected_state)) return error.ClaudeOAuthStateMismatch;
        return .{ .code = try alloc.dupe(u8, code_part) };
    }

    return .{ .code = try alloc.dupe(u8, trimmed) };
}

fn parseBrowserCallbackTarget(
    alloc: Allocator,
    target: []const u8,
    expected_state: []const u8,
) !BrowserCallback {
    const prefix = "/callback?";
    if (!std.mem.startsWith(u8, target, prefix) or std.mem.findScalar(u8, target, '#') != null) {
        return error.InvalidClaudeOAuthCallback;
    }
    const query = target[prefix.len..];
    const code = try queryValueAlloc(alloc, query, "code");
    errdefer secret.zeroAndFree(alloc, code);
    const state = try queryValueAlloc(alloc, query, "state");
    defer secret.zeroAndFree(alloc, state);
    if (!std.mem.eql(u8, state, expected_state)) return error.ClaudeOAuthStateMismatch;
    return .{ .code = code };
}

fn queryValueAlloc(alloc: Allocator, query: []const u8, key: []const u8) ![]u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.findScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], key)) continue;
        return percentDecodeAlloc(alloc, pair[equals + 1 ..]);
    }
    return error.InvalidClaudeOAuthCallback;
}

fn percentDecodeAlloc(alloc: Allocator, value: []const u8) ![]u8 {
    var out = try alloc.alloc(u8, value.len);
    errdefer alloc.free(out);
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < value.len) {
        if (value[read_index] == '%') {
            if (read_index + 2 >= value.len) return error.InvalidClaudeOAuthCallback;
            const high = std.fmt.charToDigit(value[read_index + 1], 16) catch
                return error.InvalidClaudeOAuthCallback;
            const low = std.fmt.charToDigit(value[read_index + 2], 16) catch
                return error.InvalidClaudeOAuthCallback;
            out[write_index] = @as(u8, @intCast(high * 16 + low));
            read_index += 3;
        } else {
            out[write_index] = if (value[read_index] == '+') ' ' else value[read_index];
            read_index += 1;
        }
        write_index += 1;
    }
    if (write_index == 0) return error.InvalidClaudeOAuthCallback;
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

test "Claude E2E OAuth endpoint overrides accept only loopback HTTP" {
    try std.testing.expect(isLoopbackHttpUrl("http://127.0.0.1:1234/token"));
    try std.testing.expect(isLoopbackHttpUrl("http://localhost:1234/token"));
    try std.testing.expect(!isLoopbackHttpUrl("https://127.0.0.1:1234/token"));
    try std.testing.expect(!isLoopbackHttpUrl("http://example.com:1234/token"));
}

test "Claude browser authorization URL uses PKCE against the Claude authorize endpoint" {
    const url = try buildBrowserAuthorizationUrl(
        std.testing.allocator,
        "https://claude.ai/oauth/authorize",
        browser_redirect_uri,
        "challenge-value",
        "state-value",
    );
    defer std.testing.allocator.free(url);

    try std.testing.expect(std.mem.startsWith(u8, url, "https://claude.ai/oauth/authorize?"));
    try std.testing.expect(std.mem.find(u8, url, "code=true") != null);
    try std.testing.expect(std.mem.find(u8, url, "response_type=code") != null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge=challenge-value") != null);
    try std.testing.expect(std.mem.find(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.find(u8, url, "state=state-value") != null);
    try std.testing.expect(std.mem.find(u8, url, "redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback") != null);
    try std.testing.expect(std.mem.find(u8, url, "127.0.0.1") == null);
    // Claude Code scopes are user-scoped; the issuer rejects OpenID scopes.
    try std.testing.expect(std.mem.find(u8, url, "scope=user%3Aprofile") != null);
    try std.testing.expect(std.mem.find(u8, url, "user%3Ainference") != null);
    try std.testing.expect(std.mem.find(u8, url, "openid") == null);
    try std.testing.expect(std.mem.find(u8, url, "email") == null);
}

test "Claude pasted authorization input accepts code#state and callback URLs" {
    var from_pair = try parsePastedAuthorizationInput(
        std.testing.allocator,
        "  auth-code#state-value\n",
        "state-value",
    );
    defer from_pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("auth-code", from_pair.code);

    var from_url = try parsePastedAuthorizationInput(
        std.testing.allocator,
        "https://console.anthropic.com/oauth/code/callback?code=auth%20code&state=state-value",
        "state-value",
    );
    defer from_url.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("auth code", from_url.code);

    var from_raw = try parsePastedAuthorizationInput(
        std.testing.allocator,
        "raw-code",
        "state-value",
    );
    defer from_raw.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("raw-code", from_raw.code);

    try std.testing.expectError(
        error.ClaudeOAuthStateMismatch,
        parsePastedAuthorizationInput(
            std.testing.allocator,
            "auth-code#other",
            "state-value",
        ),
    );
}

test "Claude browser callback requires the exact path and state" {
    var callback = try parseBrowserCallbackTarget(
        std.testing.allocator,
        "/callback?code=auth%20code&state=expected",
        "expected",
    );
    defer callback.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("auth code", callback.code);

    try std.testing.expectError(
        error.ClaudeOAuthStateMismatch,
        parseBrowserCallbackTarget(
            std.testing.allocator,
            "/callback?code=auth&state=other",
            "expected",
        ),
    );
    try std.testing.expectError(
        error.InvalidClaudeOAuthCallback,
        parseBrowserCallbackTarget(
            std.testing.allocator,
            "/other?code=auth&state=expected",
            "expected",
        ),
    );
}

test "Claude account identity prefers nested profile uuid and sends oauth headers" {
    const State = struct {
        authorization_seen: bool = false,
        saw_version: bool = false,
        saw_beta: bool = false,

        fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.authorization_seen = std.mem.eql(u8, request.authorization orelse "", "Bearer access-token");
            for (request.extra_headers) |header| {
                if (std.mem.eql(u8, header.name, "anthropic-version") and
                    std.mem.eql(u8, header.value, anthropic_api_version))
                {
                    self.saw_version = true;
                }
                if (std.mem.eql(u8, header.name, "anthropic-beta") and
                    std.mem.eql(u8, header.value, oauth_beta))
                {
                    self.saw_beta = true;
                }
            }
            return .{
                .disposition = .accepted,
                .body = try alloc.dupe(u8, "{\"account\":{\"uuid\":\"acct_test\"},\"organization\":{\"uuid\":\"org_test\"}}"),
            };
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
    try std.testing.expect(state.saw_version);
    try std.testing.expect(state.saw_beta);
    try std.testing.expectEqualStrings("acct_test", account_id);
}

test "Claude account identity accepts OIDC sub when account uuid is absent" {
    const State = struct {
        fn execute(_: ?*anyopaque, alloc: Allocator, _: oauth_transport.Request) !oauth_transport.Response {
            return .{ .disposition = .accepted, .body = try alloc.dupe(u8, "{\"sub\":\"acct_oidc\"}") };
        }
    };
    const account_id = try fetchAccountId(
        std.testing.allocator,
        .{ .execute_fn = State.execute },
        "access-token",
    );
    defer std.testing.allocator.free(account_id);
    try std.testing.expectEqualStrings("acct_oidc", account_id);
}

test "Claude token exchange uses JSON with state and omits API headers" {
    const State = struct {
        method: ?oauth_transport.Method = null,
        payload: [1024]u8 = undefined,
        payload_len: usize = 0,
        extra_header_count: usize = 0,

        fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const payload = request.payload orelse &.{};
            self.method = request.method;
            self.payload_len = @min(payload.len, self.payload.len);
            @memcpy(self.payload[0..self.payload_len], payload[0..self.payload_len]);
            self.extra_header_count = request.extra_headers.len;
            return .{
                .disposition = .accepted,
                .body = try alloc.dupe(u8, "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":3600}"),
            };
        }
    };
    var state = State{};
    var token = try exchangeAuthorizationCodeForRedirectWithBounds(
        std.testing.allocator,
        .{ .context = &state, .execute_fn = State.execute },
        "http://127.0.0.1:1/token",
        "auth-code",
        "verifier",
        browser_redirect_uri,
        "state-value",
        null,
        null,
    );
    defer token.deinit(std.testing.allocator);

    try std.testing.expectEqual(oauth_transport.Method.post_json, state.method.?);
    try std.testing.expectEqual(@as(usize, 0), state.extra_header_count);
    const payload = state.payload[0..state.payload_len];
    try std.testing.expect(std.mem.find(u8, payload, "\"grant_type\":\"authorization_code\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"code\":\"auth-code\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"state\":\"state-value\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"client_id\":\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "\"code_verifier\":\"verifier\"") != null);
    try std.testing.expect(std.mem.find(u8, payload, "grant_type=authorization_code") == null);
    try std.testing.expectEqualStrings("access", token.access_token);
}

test "Claude refresh uses JSON" {
    const State = struct {
        method: ?oauth_transport.Method = null,
        payload: [512]u8 = undefined,
        payload_len: usize = 0,

        fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
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
        "{\"grant_type\":\"refresh_token\",\"client_id\":\"client\",\"refresh_token\":\"[redacted]\"}",
    );
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(oauth_transport.Method.post_json, state.method.?);
    try std.testing.expect(std.mem.find(u8, state.payload[0..state.payload_len], "\"grant_type\":\"refresh_token\"") != null);
    try std.testing.expect(response.refresh_token == null);
    try std.testing.expectEqual(@as(?i64, 3600), response.expires_in);
}

test "Claude account identity rejects unsafe userinfo bytes" {
    const State = struct {
        fn execute(_: ?*anyopaque, alloc: Allocator, _: oauth_transport.Request) !oauth_transport.Response {
            return .{ .disposition = .accepted, .body = try alloc.dupe(u8, "{\"account\":{\"uuid\":\"acct\\ninjected\"}}") };
        }
    };
    try std.testing.expectError(
        error.InvalidClaudeUserInfoResponse,
        fetchAccountId(
            std.testing.allocator,
            .{ .execute_fn = State.execute },
            "access-token",
        ),
    );
}
