const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const browser_callback = @import("browser_callback.zig");
const credentials = @import("credentials.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const dpop = @import("dpop.zig");
const google_refresh = @import("google_refresh.zig");
const google_session = @import("google_session.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const jwt_claims = @import("jwt_claims.zig");
const login_flow = @import("login_flow.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const pending_revocation = @import("pending_revocation.zig");
const secret = @import("secret.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const FormBody = oauth.FormBody;
const isLoopbackHttpUrl = oauth.isLoopbackHttpUrl;
const pkceChallengeAlloc = oauth.pkceChallengeAlloc;
const randomUrlSafeSecret = oauth.randomUrlSafeSecret;

pub const authorize_url = "https://accounts.google.com/o/oauth2/v2/auth";
pub const token_url = "https://oauth2.googleapis.com/token";
pub const revoke_url = "https://oauth2.googleapis.com/revoke";
pub const connections_url = "https://myaccount.google.com/connections";

pub const required_scope = "https://www.googleapis.com/auth/generative-language.peruserquota";
pub const browser_scope = "openid email profile " ++ required_scope;
pub const redirect_path = "/oauth2callback";
pub const browser_login_timeout_seconds: i64 = 10 * 60;
pub const accepted_issuer_https = "https://accounts.google.com";
pub const accepted_issuer_host = "accounts.google.com";
pub const id_token_clock_skew_s: i64 = 60;

const default_access_token_ttl_s: i64 = 3599;
const default_refresh_token_ttl_s: i64 = 7 * std.time.s_per_day;
const max_granted_scopes: usize = 32;
pub const http_date_len: usize = 29;

const placeholder_client_id = "GOOGLE_DESKTOP_CLIENT_ID_PLACEHOLDER";
const placeholder_client_secret = "GOOGLE_DESKTOP_CLIENT_SECRET_PLACEHOLDER";
// fx's Desktop app client in the `fx-cli` Google Cloud project. Forks must
// register their own client. The secret comes from the build (build.zig
// `readGoogleOAuthClientSecret`) and is empty in builds without it.
const fx_desktop_client_id = "4117256784-doof8aerdr54fofhim6jcsajalvrp9gf.apps.googleusercontent.com";
const fx_desktop_client_secret = build_options.google_oauth_client_secret;
// Unit tests keep the placeholder so that no test can reach Google with fx's client.
pub const client_id = if (builtin.is_test) placeholder_client_id else fx_desktop_client_id;
pub const client_secret = if (builtin.is_test) placeholder_client_secret else fx_desktop_client_secret;

const e2e_auth_url_env = "FX_TEST_GOOGLE_AUTH_URL";
const e2e_token_url_env = "FX_TEST_GOOGLE_TOKEN_URL";
const e2e_revoke_url_env = "FX_TEST_GOOGLE_REVOKE_URL";
const e2e_client_id_env = "FX_TEST_GOOGLE_CLIENT_ID";
const e2e_client_secret_env = "FX_TEST_GOOGLE_CLIENT_SECRET";

pub const SignInOptions = struct {
    force_consent: bool = false,
    login_hint: ?[]const u8 = null,
};

pub const RefreshMode = union(enum) {
    if_needed,
    force,
    stored,
    replace_rejected: []const u8,
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

pub const DisconnectResult = struct {
    local_deleted: bool,
    remote_revoked: bool,
    refresh_token_found: bool,
    retry_kept: bool = false,
};

pub const LocalDisconnect = struct {
    local_deleted: bool,
    /// Owned by caller; release with `secret.zeroAndFree`.
    refresh_token: ?[]u8 = null,
    kept: bool = false,
};

const ClientCredentials = struct {
    client_id: []const u8,
    client_secret: []const u8,
};

const PendingExchange = struct {
    subject: []u8,
    email: []u8,
    client_id: []u8,
    refresh_token_expires_at_s: i64,
    dpop_private_key: []u8,
    dpop_nonce: ?[]u8,
    granted_scopes: [][]u8,

    fn deinit(self: *PendingExchange, alloc: Allocator) void {
        alloc.free(self.subject);
        alloc.free(self.email);
        alloc.free(self.client_id);
        secret.zeroAndFree(alloc, self.dpop_private_key);
        if (self.dpop_nonce) |nonce| secret.zeroAndFree(alloc, nonce);
        for (self.granted_scopes) |scope| alloc.free(scope);
        alloc.free(self.granted_scopes);
        self.* = undefined;
    }
};

const BrowserCallback = struct {
    code: []u8,

    fn deinit(self: *BrowserCallback, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.code);
        self.* = undefined;
    }
};

const BrowserLoginContext = struct {
    listener: ?std.Io.net.Server,
    redirect_uri: []u8,
    code_verifier: []u8,
    state: []u8,
    nonce: []u8,
    client_secret: []u8,
    manual_url_mutex: std.Io.Mutex = .init,
    manual_url: ?[]u8 = null,
    pending_callback: ?browser_callback.Accepted(BrowserCallback) = null,
    pending_exchange: ?PendingExchange = null,

    fn deinit(self: *BrowserLoginContext, alloc: Allocator) void {
        self.finishCallback(alloc, false);
        self.closeListener();
        alloc.free(self.redirect_uri);
        secret.zeroAndFree(alloc, self.code_verifier);
        secret.zeroAndFree(alloc, self.state);
        secret.zeroAndFree(alloc, self.nonce);
        secret.zeroAndFree(alloc, self.client_secret);
        if (self.manual_url) |url| secret.zeroAndFree(alloc, url);
        if (self.pending_exchange) |*exchange| exchange.deinit(alloc);
        self.* = undefined;
    }

    fn closeListener(self: *BrowserLoginContext) void {
        if (self.listener) |*listener| {
            listener.deinit(io_mod.getIo());
            self.listener = null;
        }
    }

    fn finishCallback(self: *BrowserLoginContext, alloc: Allocator, saved: bool) void {
        var callback = self.pending_callback orelse return;
        self.pending_callback = null;
        defer callback.deinit();
        defer callback.callback.deinit(alloc);
        callback.respond(if (saved) .ok else .failed) catch |err| {
            debug_trace.logf("auth", "Google completion response failed err={s}", .{@errorName(err)});
        };
    }

    fn submitManualUrl(self: *BrowserLoginContext, alloc: Allocator, input: []const u8) !void {
        const target = try parseManualCallbackTargetAlloc(alloc, input, self.redirect_uri);
        errdefer secret.zeroAndFree(alloc, target);

        self.manual_url_mutex.lockUncancelable(io_mod.getIo());
        defer self.manual_url_mutex.unlock(io_mod.getIo());
        if (self.manual_url) |pending| secret.zeroAndFree(alloc, pending);
        self.manual_url = target;
    }

    fn takeManualUrl(self: *BrowserLoginContext) ?[]u8 {
        self.manual_url_mutex.lockUncancelable(io_mod.getIo());
        defer self.manual_url_mutex.unlock(io_mod.getIo());
        const target = self.manual_url;
        self.manual_url = null;
        return target;
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
    return startSignInWithOptions(runtime, alloc, transport, .{});
}

pub fn startSignInWithOptions(
    runtime: *login_flow.SignInRuntime,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    options: SignInOptions,
) !bool {
    const client_creds = try configuredClientCredentials();
    try credentials.requireSignInStorage(.google_subscription);
    const browser = try prepareBrowserSignIn(alloc, client_creds, options);
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
            .submit_manual_code = submitBrowserManualUrl,
        },
    );
}

fn submitBrowserManualUrl(raw: ?*anyopaque, alloc: Allocator, input: []const u8) !void {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    try context.submitManualUrl(alloc, input);
}

fn prepareBrowserSignIn(
    alloc: Allocator,
    client_creds: ClientCredentials,
    options: SignInOptions,
) !PreparedBrowserLogin {
    const configured_auth = try configuredEndpoint(alloc, e2e_auth_url_env, authorize_url);
    defer alloc.free(configured_auth);
    const configured_token = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
    var token_owned = true;
    errdefer if (token_owned) alloc.free(configured_token);

    var listener = try bindBrowserCallback();
    errdefer listener.deinit(io_mod.getIo());
    const callback_port = listener.socket.address.getPort();
    const redirect_uri = try alloc.print("http://127.0.0.1:{d}" ++ redirect_path, .{callback_port});
    errdefer alloc.free(redirect_uri);

    const code_verifier = try randomUrlSafeSecret(alloc);
    errdefer secret.zeroAndFree(alloc, code_verifier);
    const state = try randomUrlSafeSecret(alloc);
    errdefer secret.zeroAndFree(alloc, state);
    const nonce = try randomUrlSafeSecret(alloc);
    errdefer secret.zeroAndFree(alloc, nonce);
    const owned_secret = try alloc.dupe(u8, client_creds.client_secret);
    errdefer secret.zeroAndFree(alloc, owned_secret);

    const code_challenge = try pkceChallengeAlloc(alloc, code_verifier);
    defer alloc.free(code_challenge);
    const authorization_url = try buildBrowserAuthorizationUrl(
        alloc,
        configured_auth,
        client_creds.client_id,
        redirect_uri,
        code_challenge,
        state,
        nonce,
        options,
    );
    var authorization_url_owned = true;
    errdefer if (authorization_url_owned) alloc.free(authorization_url);

    var prepared = try login_flow.prepareBrowserLogin(alloc, .{
        .issuer = accepted_issuer_https,
        .authorization_endpoint_suffix = "/o/oauth2/v2/auth",
        .token_endpoint = configured_token,
        .verification_uri = authorization_url,
        .client_id = client_creds.client_id,
        .expires_in = browser_login_timeout_seconds,
    });
    token_owned = false;
    authorization_url_owned = false;
    errdefer prepared.deinit(alloc);

    const context = try alloc.create(BrowserLoginContext);
    context.* = .{
        .listener = listener,
        .redirect_uri = redirect_uri,
        .code_verifier = code_verifier,
        .state = state,
        .nonce = nonce,
        .client_secret = owned_secret,
    };

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
    client_id_arg: []const u8,
    _: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    if (comptime host_target.is_wasm) return error.GoogleOAuthUnavailable;
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));

    const manual_target = context.takeManualUrl();
    defer if (manual_target) |target| secret.zeroAndFree(alloc, target);

    var accepted: ?browser_callback.Accepted(BrowserCallback) = null;
    defer if (accepted) |*callback| {
        callback.callback.deinit(alloc);
        callback.deinit();
    };
    var manual_callback: ?BrowserCallback = null;
    defer if (manual_callback) |*callback| callback.deinit(alloc);

    const code = if (manual_target) |target| blk: {
        context.closeListener();
        manual_callback = try parseBrowserCallbackTarget(alloc, target, context.state);
        break :blk manual_callback.?.code;
    } else blk: {
        const listener = &(context.listener orelse return error.GoogleOAuthCallbackListenerFailed);
        accepted = (awaitBrowserCallback(
            alloc,
            listener,
            context.state,
            cancel_flag,
        ) catch |err| {
            context.closeListener();
            return err;
        }) orelse return .pending;
        context.closeListener();
        break :blk accepted.?.callback.code;
    };

    var exchanged = exchangeAuthorizationCode(
        alloc,
        transport,
        metadata.token_endpoint,
        code,
        context.code_verifier,
        context.redirect_uri,
        client_id_arg,
        context.client_secret,
        context.nonce,
        cancel_flag,
        deadline,
    ) catch |err| {
        if (accepted) |*callback| callback.respond(.failed) catch {};
        return err;
    };
    errdefer exchanged.deinit(alloc);

    const result = try oauth.takeBrowserPollResult(alloc, &exchanged.tokens);

    if (context.pending_exchange) |*old| old.deinit(alloc);
    context.pending_exchange = exchanged.extra;
    exchanged.extra = undefined;
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
        null,
    ) catch |err| switch (err) {
        error.OAuthCallbackListenerFailed => error.GoogleOAuthCallbackListenerFailed,
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
        error.InvalidGoogleOAuthCallback => return .unrelated,
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
    const refresh_token = token.refresh_token orelse return error.GoogleRefreshTokenMissing;
    var extra = context.pending_exchange orelse return error.InvalidGoogleOAuthResponse;
    context.pending_exchange = null;
    errdefer extra.deinit(alloc);

    const access_token_expires_at_s = std.math.add(i64, nowSeconds(), token.expires_in) catch
        return error.InvalidGoogleOAuthResponse;

    const completion: login_flow.SignInCompletion = .{ .google = .{
        .subject = extra.subject,
        .email = extra.email,
        .client_id = extra.client_id,
        .refresh_token = refresh_token,
        .refresh_token_expires_at_s = extra.refresh_token_expires_at_s,
        .access_token = token.access_token,
        .access_token_expires_at_s = access_token_expires_at_s,
        .dpop_private_key = extra.dpop_private_key,
        .dpop_nonce = extra.dpop_nonce,
        .granted_scopes = extra.granted_scopes,
    } };
    token.access_token = &.{};
    token.refresh_token = null;
    return completion;
}

fn saveSignIn(_: ?*anyopaque, alloc: Allocator, completion: login_flow.SignInCompletion) !void {
    const account = switch (completion) {
        .google => |account| account,
        .vercel, .chatgpt, .grok => return error.InvalidSignInCompletion,
    };
    var mutation = try google_session.beginMutation(alloc);
    defer mutation.deinit(alloc);

    var record = if (mutation.record) |*existing|
        try existing.clone(alloc)
    else
        google_session.Record{};
    defer record.deinit(alloc);

    try record.upsertAccount(alloc, .{
        .subject = account.subject,
        .email = account.email,
        .client_id = account.client_id,
        .refresh_token = account.refresh_token,
        .refresh_token_expires_at_s = account.refresh_token_expires_at_s,
        .access_token = account.access_token,
        .access_token_expires_at_s = account.access_token_expires_at_s,
        .dpop_private_key = account.dpop_private_key,
        .dpop_nonce = account.dpop_nonce,
        .granted_scopes = account.granted_scopes,
    }, true);
    try mutation.save(alloc, record);
}

fn finishSignIn(raw: ?*anyopaque, alloc: Allocator, saved: bool) void {
    const context: *BrowserLoginContext = @ptrCast(@alignCast(raw.?));
    context.finishCallback(alloc, saved);
}

const supports_cli_interrupt = !builtin.is_test and switch (builtin.target.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => true,
};

const LoginInterrupt = if (supports_cli_interrupt) struct {
    var interrupted = std.atomic.Value(bool).init(false);

    fn handle(_: std.posix.SIG) callconv(.c) void {
        interrupted.store(true, .seq_cst);
    }

    const Scope = struct {
        old_sigint: std.posix.Sigaction = undefined,
        installed: bool = false,

        fn install() Scope {
            interrupted.store(false, .seq_cst);
            const action: std.posix.Sigaction = .{
                .handler = .{ .handler = handle },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            var scope = Scope{};
            std.posix.sigaction(std.posix.SIG.INT, &action, &scope.old_sigint);
            scope.installed = true;
            return scope;
        }

        fn deinit(self: *Scope) void {
            if (!self.installed) return;
            std.posix.sigaction(std.posix.SIG.INT, &self.old_sigint, null);
            self.installed = false;
        }

        fn requested(self: *const Scope) bool {
            return self.installed and interrupted.load(.seq_cst);
        }
    };
} else struct {
    const Scope = struct {
        fn install() Scope {
            return .{};
        }
        fn deinit(_: *Scope) void {}
        fn requested(_: *const Scope) bool {
            return false;
        }
    };
};

/// Runs the CLI plan sign-in with `options` and returns the connected email (owned by caller).
pub fn runLoginWithOptions(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
    options: SignInOptions,
) ![]u8 {
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    if (!try startSignInWithOptions(&runtime, alloc, transport, options)) return error.GoogleLoginBusy;

    const authorization_url = (try runtime.browserUrlAlloc(alloc)) orelse
        return error.GoogleAuthorizationUrlMissing;
    defer alloc.free(authorization_url);
    try writeStdout("Open this URL to sign in with Google:\n");
    try writeStdout(authorization_url);
    try writeStdout("\n\nWaiting for browser authorization...\n");
    try writeStdout("Paste the full callback URL and press enter if the browser cannot reach 127.0.0.1.\n");
    if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) {
        _ = url_opener.open(alloc, authorization_url) catch false;
    }

    var sigint = LoginInterrupt.Scope.install();
    defer sigint.deinit();
    var stdin_url: StdinManualUrlReader = .{};
    defer stdin_url.deinit();
    while (true) {
        if (sigint.requested()) {
            _ = runtime.cancel(alloc);
            return error.Interrupted;
        }
        if (try stdin_url.poll()) |pasted| {
            _ = try runtime.submitManualCode(alloc, pasted);
            stdin_url.clear();
        }
        switch (runtime.pollTransition(alloc)) {
            .none => try io_mod.getIo().sleep(.fromMilliseconds(50), .awake),
            .succeeded => |completion| {
                var owned = completion;
                defer owned.deinit(alloc);
                return switch (owned) {
                    .google => |account| try alloc.dupe(u8, account.email),
                    else => return error.InvalidGoogleOAuthResponse,
                };
            },
            .failed => |err| return err,
            .cancelled => return if (sigint.requested()) error.Interrupted else error.GoogleAccessDenied,
        }
    }
}

const StdinManualUrlReader = struct {
    buffer: [login_flow.max_manual_code_bytes]u8 = undefined,
    len: usize = 0,
    closed: bool = false,

    fn poll(self: *StdinManualUrlReader) !?[]const u8 {
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
        if (line_end > self.buffer.len - self.len) return error.GoogleCallbackUrlTooLong;
        @memcpy(self.buffer[self.len..][0..line_end], chunk[0..line_end]);
        self.len += line_end;
        if (line_end < read_len) {
            self.closed = true;
            return self.buffer[0..self.len];
        }
        return null;
    }

    fn clear(self: *StdinManualUrlReader) void {
        @memset(self.buffer[0..self.len], 0);
        self.len = 0;
    }

    fn deinit(self: *StdinManualUrlReader) void {
        @memset(&self.buffer, 0);
        self.* = undefined;
    }
};

const CodeExchangeResult = struct {
    tokens: oauth.BrowserTokenSet,
    extra: PendingExchange,

    fn deinit(self: *CodeExchangeResult, alloc: Allocator) void {
        self.tokens.deinit(alloc);
        self.extra.deinit(alloc);
    }
};

fn signedDpopProofAlloc(
    alloc: Allocator,
    key_pair: dpop.KeyPair,
    htu: []const u8,
    iat_s: i64,
    jti: []const u8,
    nonce: ?[]const u8,
) ![]u8 {
    var noise: [dpop.Scheme.noise_length]u8 = undefined;
    try io_mod.getIo().randomSecure(&noise);
    return dpop.proofAlloc(alloc, key_pair, .{
        .htu = htu,
        .iat_s = iat_s,
        .jti = jti,
        .nonce = nonce,
    }, noise);
}

fn defaultRequestDeadline() std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(oauth_transport.default_request_timeout_ms),
    });
}

fn appendFormFields(writer: *std.Io.Writer, fields: []const [2][]const u8) !void {
    var form: FormBody = .{};
    for (fields) |field| {
        try form.append(writer, field[0], field[1]);
    }
}

const SecretFormBody = struct {
    body: std.Io.Writer.Allocating,

    fn init(alloc: Allocator, fields: []const [2][]const u8) !SecretFormBody {
        var self: SecretFormBody = .{ .body = .init(alloc) };
        errdefer self.deinit();
        try appendFormFields(&self.body.writer, fields);
        return self;
    }

    fn written(self: *SecretFormBody) []const u8 {
        return self.body.written();
    }

    fn deinit(self: *SecretFormBody) void {
        std.crypto.secureZero(u8, self.body.writer.buffer);
        self.body.deinit();
    }
};

fn exchangeAuthorizationCode(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint_url: []const u8,
    authorization_code: []const u8,
    code_verifier: []const u8,
    redirect_uri: []const u8,
    client_id_arg: []const u8,
    client_secret_arg: []const u8,
    expected_nonce: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) !CodeExchangeResult {
    if (cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;

    var dpop_seed: [dpop.seed_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &dpop_seed);
    try io_mod.getIo().randomSecure(&dpop_seed);
    const dpop_key_pair = try dpop.keyPairFromSeed(dpop_seed);
    const dpop_private_key = try dpop.encodeSecretKeyAlloc(alloc, dpop_key_pair);
    errdefer secret.zeroAndFree(alloc, dpop_private_key);

    const jti = try dpop.codeExchangeJtiAlloc(alloc, authorization_code);
    defer alloc.free(jti);

    const now_s = nowSeconds();
    const proof = try signedDpopProofAlloc(alloc, dpop_key_pair, endpoint_url, now_s, jti, null);
    defer secret.zeroAndFree(alloc, proof);

    var body = try SecretFormBody.init(alloc, &.{
        .{ "grant_type", "authorization_code" },
        .{ "code", authorization_code },
        .{ "code_verifier", code_verifier },
        .{ "redirect_uri", redirect_uri },
        .{ "client_id", client_id_arg },
        .{ "client_secret", client_secret_arg },
    });
    defer body.deinit();

    // Never retry a single-use authorization code.
    var response = try transport.execute(alloc, .{
        .method = .post_form,
        .url = endpoint_url,
        .payload = body.written(),
        .dpop = proof,
        .cancel_flag = cancel_flag,
        .deadline = deadline,
    });
    defer response.deinit(alloc);

    if (response.disposition != .accepted) {
        debug_trace.logf("auth", "Google code exchange rejected status={d}", .{response.status});
        return error.GoogleOAuthRequestFailed;
    }

    const dpop_nonce = if (response.dpop_nonce) |nonce|
        if (nonce.len > 0) try alloc.dupe(u8, nonce) else null
    else
        null;
    errdefer if (dpop_nonce) |nonce| secret.zeroAndFree(alloc, nonce);

    const response_bytes = response.takeBody();
    defer secret.zeroAndFree(alloc, response_bytes);

    return parseCodeExchangeResponse(
        alloc,
        response_bytes,
        client_id_arg,
        expected_nonce,
        dpop_private_key,
        dpop_nonce,
        now_s,
    );
}

fn parseCodeExchangeResponse(
    alloc: Allocator,
    bytes: []const u8,
    expected_client_id: []const u8,
    expected_nonce: []const u8,
    dpop_private_key: []u8,
    dpop_nonce: ?[]u8,
    now_s: i64,
) !CodeExchangeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return error.InvalidGoogleOAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGoogleOAuthResponse;
    const obj = parsed.value.object;

    try validateBearerTokenType(obj, true);

    const scope_str = obj.get("scope") orelse return error.GoogleScopeMissing;
    if (scope_str != .string or scope_str.string.len == 0) return error.GoogleScopeMissing;
    if (!hasRequiredScope(scope_str.string, required_scope)) return error.GoogleScopeMissing;
    const granted_scopes = try splitScopesAlloc(alloc, scope_str.string);
    errdefer {
        for (granted_scopes) |scope| alloc.free(scope);
        alloc.free(granted_scopes);
    }

    const id_token = obj.get("id_token") orelse return error.InvalidGoogleIdToken;
    if (id_token != .string or id_token.string.len == 0) return error.InvalidGoogleIdToken;
    var claims = try validateIdTokenClaims(alloc, id_token.string, expected_client_id, expected_nonce, now_s);
    errdefer claims.deinit(alloc);

    const access_token = try dupeRequiredString(alloc, obj, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = dupeRequiredString(alloc, obj, "refresh_token") catch
        return error.GoogleRefreshTokenMissing;
    errdefer secret.zeroAndFree(alloc, refresh_token);

    const expires_in = (try optionalPositiveInt(obj, "expires_in")) orelse
        return error.InvalidGoogleOAuthResponse;
    const refresh_ttl_s = (try optionalPositiveInt(obj, "refresh_token_expires_in")) orelse
        default_refresh_token_ttl_s;
    const refresh_expires_at_s = std.math.add(i64, now_s, refresh_ttl_s) catch
        return error.InvalidGoogleOAuthResponse;

    const owned_client_id = try alloc.dupe(u8, expected_client_id);
    errdefer alloc.free(owned_client_id);

    return .{
        .tokens = .{
            .access_token = access_token,
            .refresh_token = refresh_token,
            .expires_in = expires_in,
        },
        .extra = .{
            .subject = claims.subject,
            .email = claims.email,
            .client_id = owned_client_id,
            .refresh_token_expires_at_s = refresh_expires_at_s,
            .dpop_private_key = dpop_private_key,
            .dpop_nonce = dpop_nonce,
            .granted_scopes = granted_scopes,
        },
    };
}

const IdTokenClaims = struct {
    subject: []u8,
    email: []u8,

    fn deinit(self: *IdTokenClaims, alloc: Allocator) void {
        alloc.free(self.subject);
        alloc.free(self.email);
        self.* = undefined;
    }
};

fn validateIdTokenClaims(
    alloc: Allocator,
    id_token: []const u8,
    expected_client_id: []const u8,
    expected_nonce: []const u8,
    now_s: i64,
) !IdTokenClaims {
    var parsed = jwt_claims.parse(alloc, id_token) catch return error.InvalidGoogleIdToken;
    defer parsed.deinit();
    const obj = parsed.value.object;

    const iss_val = obj.get("iss") orelse return error.GoogleIdTokenInvalidIssuer;
    if (iss_val != .string) return error.GoogleIdTokenInvalidIssuer;
    if (!std.mem.eql(u8, iss_val.string, accepted_issuer_https) and
        !std.mem.eql(u8, iss_val.string, accepted_issuer_host))
    {
        return error.GoogleIdTokenInvalidIssuer;
    }

    const aud_val = obj.get("aud") orelse return error.GoogleIdTokenInvalidAudience;
    if (aud_val != .string or !std.mem.eql(u8, aud_val.string, expected_client_id)) {
        return error.GoogleIdTokenInvalidAudience;
    }

    const exp_val = obj.get("exp") orelse return error.GoogleIdTokenExpired;
    if (exp_val != .integer) return error.InvalidGoogleIdToken;
    if (@as(i128, exp_val.integer) + id_token_clock_skew_s <= now_s) {
        return error.GoogleIdTokenExpired;
    }

    const nonce_val = obj.get("nonce") orelse return error.GoogleIdTokenInvalidNonce;
    if (nonce_val != .string or !constantTimeEql(nonce_val.string, expected_nonce)) {
        return error.GoogleIdTokenInvalidNonce;
    }

    const sub_val = obj.get("sub") orelse return error.InvalidGoogleIdToken;
    if (sub_val != .string or !types.validCredentialAccountId(sub_val.string)) {
        return error.InvalidGoogleIdToken;
    }

    const email_val = obj.get("email") orelse return error.InvalidGoogleIdToken;
    if (email_val != .string or email_val.string.len == 0) return error.InvalidGoogleIdToken;

    const subject = try alloc.dupe(u8, sub_val.string);
    errdefer alloc.free(subject);
    const email = try alloc.dupe(u8, email_val.string);
    return .{
        .subject = subject,
        .email = email,
    };
}

pub fn sourceExists(alloc: Allocator) !bool {
    var account = (try google_session.loadActiveAccount(alloc)) orelse return false;
    defer account.deinit(alloc);
    return true;
}

/// Writes the active account's terminal-safe email into `out` and returns the
/// slice, or null when no account is saved or its email is empty.
pub fn activeEmailInto(alloc: Allocator, out: []u8) ?[]const u8 {
    var account = (google_session.loadActiveAccount(alloc) catch return null) orelse return null;
    defer account.deinit(alloc);
    if (account.email.len == 0) return null;
    var safe = text_utils.encodeTerminalSafe(alloc, account.email, out.len) catch return null;
    defer safe.deinit(alloc);
    if (safe.bytes.len == 0 or safe.bytes.len > out.len) return null;
    @memcpy(out[0..safe.bytes.len], safe.bytes);
    return out[0..safe.bytes.len];
}

pub fn loadAccess(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mode: RefreshMode,
) !?Access {
    if (mode == .stored) {
        var account = (try google_session.loadActiveAccount(alloc)) orelse return null;
        defer account.deinit(alloc);
        return takeAccess(&account);
    }

    var mutation = (try google_session.beginExistingMutation(alloc)) orelse return null;
    defer mutation.deinit(alloc);
    const record = &(mutation.record orelse return null);
    const active = record.activeAccount() orelse return null;

    const now_s = nowSeconds();
    const rejected: ?[]const u8 = switch (mode) {
        .if_needed, .stored => null,
        .force => active.access_token,
        .replace_rejected => |token| token,
    };

    switch (google_refresh.decide(active.asSavedAccess(), rejected, now_s)) {
        .sign_in_required => return error.GoogleSignInRequired,
        .adopt => return try cloneAccess(alloc, active.*),
        .refresh => {},
    }

    return try refreshActiveAccount(alloc, transport, &mutation, record, active.subject);
}

fn refreshActiveAccount(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    mutation: *google_session.Mutation,
    record: *google_session.Record,
    active_sub: []const u8,
) !Access {
    const target_sub = try alloc.dupe(u8, active_sub);
    defer alloc.free(target_sub);

    const client_creds = try configuredClientCredentials();
    const endpoint_url = try configuredEndpoint(alloc, e2e_token_url_env, token_url);
    defer alloc.free(endpoint_url);

    const active = record.findAccount(target_sub) orelse return error.GoogleSignInRequired;
    const dpop_key = dpop.decodeSecretKey(active.dpop_private_key) catch return error.InvalidGoogleSession;

    var current_nonce: ?[]u8 = if (active.dpop_nonce) |n| try alloc.dupe(u8, n) else null;
    defer if (current_nonce) |n| secret.zeroAndFree(alloc, n);
    var iat_s = nowSeconds();
    var attempt: google_refresh.Attempt = .{};

    var body = try SecretFormBody.init(alloc, &.{
        .{ "grant_type", "refresh_token" },
        .{ "refresh_token", active.refresh_token },
        .{ "client_id", active.client_id },
        .{ "client_secret", client_creds.client_secret },
    });
    defer body.deinit();

    while (true) {
        mutation.restamp();

        var jti_entropy: [dpop.jti_entropy_bytes]u8 = undefined;
        try io_mod.getIo().randomSecure(&jti_entropy);
        const jti = try dpop.randomJtiAlloc(alloc, jti_entropy);
        defer alloc.free(jti);

        const proof = try signedDpopProofAlloc(alloc, dpop_key, endpoint_url, iat_s, jti, current_nonce);
        defer secret.zeroAndFree(alloc, proof);

        const deadline = defaultRequestDeadline();

        var maybe_response: ?oauth_transport.Response = null;
        defer if (maybe_response) |*resp| resp.deinit(alloc);

        var error_code_buf: ?[]u8 = null;
        defer if (error_code_buf) |code| alloc.free(code);

        const token_response: google_refresh.TokenResponse = if (transport.execute(alloc, .{
            .method = .post_form,
            .url = endpoint_url,
            .payload = body.written(),
            .dpop = proof,
            .deadline = deadline,
            .outlives_cancel = true,
        })) |resp| blk: {
            maybe_response = resp;
            const status = effectiveHttpStatus(resp);
            error_code_buf = if (status == 400) parseErrorCodeAlloc(alloc, resp.body) else null;
            const date_s = if (resp.date_header) |raw_date| parseHttpDate(raw_date) else null;
            break :blk .{ .http = .{
                .status = status,
                .error_code = error_code_buf,
                .dpop_nonce = resp.dpop_nonce,
                .date_header_s = date_s,
            } };
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Cancelled => return error.Cancelled,
            error.Timeout => .timeout,
            else => .offline,
        };

        switch (google_refresh.onTokenResponse(attempt, token_response)) {
            .retry_with_nonce => |retry| {
                const next_nonce = try alloc.dupe(u8, retry.dpop_nonce);
                if (current_nonce) |old| secret.zeroAndFree(alloc, old);
                current_nonce = next_nonce;
                attempt = attempt.afterNonceRetry();
            },
            .retry_with_clock => |retry| {
                iat_s = retry.server_time_s;
                attempt = attempt.afterClockRetry();
            },
            .save => |save_plan| {
                const resp = &(maybe_response orelse return error.GoogleOAuthRequestFailed);
                const resp_bytes = resp.takeBody();
                defer secret.zeroAndFree(alloc, resp_bytes);

                const parsed = try parseRefreshResponse(alloc, resp_bytes);
                defer {
                    secret.zeroAndFree(alloc, parsed.access_token);
                    if (parsed.refresh_token) |rt| secret.zeroAndFree(alloc, rt);
                }

                const newest_nonce = save_plan.dpop_nonce orelse current_nonce;
                const save_now_s = nowSeconds();
                const access_expires_at_s = std.math.add(i64, save_now_s, parsed.expires_in) catch
                    return error.InvalidGoogleOAuthResponse;
                const refresh_expires_at_s = if (parsed.refresh_token_expires_in) |ttl|
                    std.math.add(i64, save_now_s, ttl) catch return error.InvalidGoogleOAuthResponse
                else
                    active.refresh_token_expires_at_s;

                try record.upsertAccount(alloc, .{
                    .subject = active.subject,
                    .email = active.email,
                    .client_id = active.client_id,
                    .refresh_token = parsed.refresh_token orelse active.refresh_token,
                    .refresh_token_expires_at_s = refresh_expires_at_s,
                    .access_token = parsed.access_token,
                    .access_token_expires_at_s = access_expires_at_s,
                    .dpop_private_key = active.dpop_private_key,
                    .dpop_nonce = newest_nonce,
                    .granted_scopes = active.granted_scopes,
                }, true);
                try mutation.save(alloc, record.*);

                const saved = record.findAccount(target_sub) orelse return error.GoogleSignInRequired;
                return cloneAccess(alloc, saved.*);
            },
            .clear_login => {
                _ = try removeAccountAndPersist(alloc, mutation, record, target_sub);
                return error.GoogleSignInRequired;
            },
            .keep_and_fail => {
                debug_trace.logf("auth", "Google token refresh failed; keeping saved account", .{});
                return error.GoogleOAuthRequestFailed;
            },
        }
    }
}

const RefreshResponseData = struct {
    access_token: []u8,
    refresh_token: ?[]u8,
    expires_in: i64,
    refresh_token_expires_in: ?i64,
};

fn validateBearerTokenType(obj: std.json.ObjectMap, required: bool) !void {
    const tt = obj.get("token_type") orelse {
        if (required) return error.InvalidGoogleOAuthResponse;
        return;
    };
    if (tt != .string or !std.ascii.eqlIgnoreCase(tt.string, "Bearer")) {
        return error.InvalidGoogleOAuthResponse;
    }
}

fn optionalPositiveInt(obj: std.json.ObjectMap, key: []const u8) !?i64 {
    const val = obj.get(key) orelse return null;
    if (val != .integer or val.integer <= 0) return error.InvalidGoogleOAuthResponse;
    return val.integer;
}

fn parseRefreshResponse(alloc: Allocator, bytes: []const u8) !RefreshResponseData {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return error.InvalidGoogleOAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGoogleOAuthResponse;
    const obj = parsed.value.object;

    try validateBearerTokenType(obj, false);

    const access_token = try dupeRequiredString(alloc, obj, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);

    const refresh_token = if (obj.get("refresh_token")) |val| blk: {
        if (val != .string or val.string.len == 0) return error.InvalidGoogleOAuthResponse;
        break :blk try alloc.dupe(u8, val.string);
    } else null;
    errdefer if (refresh_token) |rt| secret.zeroAndFree(alloc, rt);

    const expires_in = (try optionalPositiveInt(obj, "expires_in")) orelse default_access_token_ttl_s;
    const refresh_ttl = try optionalPositiveInt(obj, "refresh_token_expires_in");

    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = expires_in,
        .refresh_token_expires_in = refresh_ttl,
    };
}

pub fn revokeToken(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    token: []const u8,
) !void {
    const endpoint_url = try configuredEndpoint(alloc, e2e_revoke_url_env, revoke_url);
    defer alloc.free(endpoint_url);

    var body = try SecretFormBody.init(alloc, &.{.{ "token", token }});
    defer body.deinit();

    var response = try transport.execute(alloc, .{
        .method = .post_form,
        .url = endpoint_url,
        .payload = body.written(),
        .dpop = null,
        .deadline = defaultRequestDeadline(),
    });
    defer response.deinit(alloc);

    const status = effectiveHttpStatus(response);
    if (status < 200 or status >= 300) {
        debug_trace.logf("auth", "Google token revoke rejected status={d}", .{status});
        return error.GoogleRevokeFailed;
    }
}

/// Removes the target Google account (active when `subject` is null) from this
/// device without revoking tokens remotely.
pub fn signOutOnDevice(alloc: Allocator, subject: ?[]const u8) !bool {
    const local = try removeLocalAccount(alloc, subject, false);
    return local.local_deleted;
}

/// Removes the local account first, keeping its refresh token in
/// `pending_revocation` so an interrupted or failed remote revoke retries later.
pub fn disconnectLocally(alloc: Allocator, subject: ?[]const u8) !LocalDisconnect {
    return removeLocalAccount(alloc, subject, true);
}

fn findTargetAccount(record: *const google_session.Record, subject: ?[]const u8) ?*const google_session.Account {
    return if (subject) |sub| record.findAccount(sub) else record.activeAccount();
}

fn removeAccountAndPersist(
    alloc: Allocator,
    mutation: *google_session.Mutation,
    record: *google_session.Record,
    subject: []const u8,
) !bool {
    const target_sub = try alloc.dupe(u8, subject);
    defer alloc.free(target_sub);
    if (!(try record.removeAccount(alloc, target_sub))) return false;
    if (record.accounts.items.len == 0) {
        _ = try mutation.delete(alloc);
    } else {
        try mutation.save(alloc, record.*);
    }
    return true;
}

fn removeLocalAccount(alloc: Allocator, subject: ?[]const u8, keep_refresh_token: bool) !LocalDisconnect {
    var mutation = (try google_session.beginExistingMutation(alloc)) orelse return .{
        .local_deleted = false,
    };
    defer mutation.deinit(alloc);

    const record = &(mutation.record orelse return .{
        .local_deleted = false,
    });
    const account = findTargetAccount(record, subject) orelse return .{
        .local_deleted = false,
    };

    var refresh_token: ?[]u8 = null;
    errdefer if (refresh_token) |rt| secret.zeroAndFree(alloc, rt);
    var kept = false;
    if (keep_refresh_token) {
        refresh_token = try alloc.dupe(u8, account.refresh_token);
        kept = pending_revocation.keep(alloc, .google, .{ .refresh_token = refresh_token.? });
    }
    errdefer if (kept) pending_revocation.forget(alloc, .google, refresh_token.?);

    _ = try removeAccountAndPersist(alloc, &mutation, record, account.subject);

    return .{
        .local_deleted = true,
        .refresh_token = refresh_token,
        .kept = kept,
    };
}

pub fn disconnectAccount(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    subject: ?[]const u8,
) !DisconnectResult {
    const local = try disconnectLocally(alloc, subject);
    defer if (local.refresh_token) |rt| secret.zeroAndFree(alloc, rt);
    if (!local.local_deleted) return .{
        .local_deleted = false,
        .remote_revoked = false,
        .refresh_token_found = false,
    };

    const token = local.refresh_token orelse return .{
        .local_deleted = true,
        .remote_revoked = false,
        .refresh_token_found = false,
    };

    var retry_kept = false;
    const remote_revoked = if (revokeToken(alloc, transport, token)) |_| blk: {
        if (local.kept) pending_revocation.forget(alloc, .google, token);
        break :blk true;
    } else |err| blk: {
        debug_trace.logf("auth", "Google remote revoke failed err={s}", .{@errorName(err)});
        retry_kept = local.kept and pending_revocation.retryable(err);
        if (local.kept and !retry_kept) pending_revocation.forget(alloc, .google, token);
        break :blk false;
    };

    return .{
        .local_deleted = true,
        .remote_revoked = remote_revoked,
        .refresh_token_found = true,
        .retry_kept = retry_kept,
    };
}

/// Revokes kept Google sign-outs queued in `pending_revocation`.
pub fn retryKeptSignOuts(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    before_revocation: ?oauth.BeforeRevocation,
) pending_revocation.RetryOutcome {
    return pending_revocation.retry(alloc, .google, .{ .context = &transport, .run = revokeKept }, before_revocation);
}

fn revokeKept(context: *const anyopaque, alloc: Allocator, tokens: pending_revocation.Tokens) anyerror!void {
    const transport: *const oauth_transport.Provider = @ptrCast(@alignCast(context));
    return revokeToken(alloc, transport.*, tokens.refresh_token);
}

fn takeAccess(account: *google_session.Account) Access {
    const access_token = account.access_token;
    account.access_token = &.{};
    const account_id = account.subject;
    account.subject = &.{};
    return .{
        .access_token = access_token,
        .account_id = account_id,
        .refresh_after_ms = refreshDeadlineMs(account.access_token_expires_at_s),
    };
}

fn cloneAccess(alloc: Allocator, account: google_session.Account) !Access {
    const access_token = try alloc.dupe(u8, account.access_token);
    errdefer secret.zeroAndFree(alloc, access_token);
    const account_id = try alloc.dupe(u8, account.subject);
    return .{
        .access_token = access_token,
        .account_id = account_id,
        .refresh_after_ms = refreshDeadlineMs(account.access_token_expires_at_s),
    };
}

fn refreshDeadlineMs(access_token_expires_at_s: i64) i64 {
    const deadline_s = @max(access_token_expires_at_s -| google_refresh.refresh_margin_s, 0);
    return deadline_s *| std.time.ms_per_s;
}

fn nowSeconds() i64 {
    return @divFloor(io_mod.milliTimestamp(), std.time.ms_per_s);
}

fn effectiveHttpStatus(resp: oauth_transport.Response) u16 {
    if (resp.status != 0) return resp.status;
    return if (resp.disposition == .accepted) 200 else 500;
}

fn parseErrorCodeAlloc(alloc: Allocator, body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const err_val = parsed.value.object.get("error") orelse return null;
    if (err_val != .string or err_val.string.len == 0) return null;
    return alloc.dupe(u8, err_val.string) catch null;
}

fn configuredClientCredentials() !ClientCredentials {
    const token_override = io_mod.getenv(e2e_token_url_env);
    const has_loopback_token_override = if (token_override) |url| blk: {
        if (!isLoopbackHttpUrl(url)) return error.InvalidE2EGoogleEndpoint;
        break :blk true;
    } else false;

    const resolved_id = if (has_loopback_token_override)
        nonEmptyEnv(e2e_client_id_env) orelse client_id
    else
        client_id;
    const resolved_secret = if (has_loopback_token_override)
        nonEmptyEnv(e2e_client_secret_env) orelse client_secret
    else
        client_secret;

    if (resolved_id.len == 0 or
        resolved_secret.len == 0 or
        std.mem.eql(u8, resolved_id, placeholder_client_id) or
        std.mem.eql(u8, resolved_secret, placeholder_client_secret))
    {
        return error.GoogleClientNotConfigured;
    }
    return .{
        .client_id = resolved_id,
        .client_secret = resolved_secret,
    };
}

fn nonEmptyEnv(name: []const u8) ?[]const u8 {
    const raw = io_mod.getenv(name) orelse return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn configuredEndpoint(alloc: Allocator, env_name: []const u8, default_url: []const u8) ![]u8 {
    return oauth.configuredEndpoint(alloc, env_name, default_url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidE2EGoogleEndpoint,
    };
}

fn buildBrowserAuthorizationUrl(
    alloc: Allocator,
    auth_base_url: []const u8,
    client_id_arg: []const u8,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: []const u8,
    nonce: []const u8,
    options: SignInOptions,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const sep: []const u8 = if (std.mem.findScalar(u8, auth_base_url, '?') != null) "&" else "?";
    try out.writer.print("{s}{s}", .{ auth_base_url, sep });
    try appendFormFields(&out.writer, &.{
        .{ "client_id", client_id_arg },
        .{ "redirect_uri", redirect_uri },
        .{ "response_type", "code" },
        .{ "scope", browser_scope },
        .{ "code_challenge", code_challenge },
        .{ "code_challenge_method", "S256" },
        .{ "state", state },
        .{ "nonce", nonce },
    });
    if (options.force_consent) {
        try appendFormFields(&out.writer, &.{.{ "prompt", "consent" }});
        if (options.login_hint) |hint| {
            try appendFormFields(&out.writer, &.{.{ "login_hint", hint }});
        }
    }
    return out.toOwnedSlice();
}

pub fn parseManualCallbackTargetAlloc(
    alloc: Allocator,
    input: []const u8,
    expected_redirect_uri: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > login_flow.max_manual_code_bytes) {
        return error.InvalidGoogleCallbackUrl;
    }
    for (trimmed) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidGoogleCallbackUrl;
    }
    if (std.mem.findScalar(u8, trimmed, '#') != null) {
        return error.InvalidGoogleCallbackUrl;
    }

    const expected_uri = std.Uri.parse(expected_redirect_uri) catch return error.InvalidGoogleCallbackUrl;
    const expected_port = expected_uri.port orelse return error.InvalidGoogleCallbackUrl;

    const uri = std.Uri.parse(trimmed) catch return error.InvalidGoogleCallbackUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port != expected_port)
    {
        return error.InvalidGoogleCallbackUrl;
    }

    const host_component = uri.host orelse return error.InvalidGoogleCallbackUrl;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = host_component.toRaw(&host_buf) catch return error.InvalidGoogleCallbackUrl;
    if (!std.mem.eql(u8, host_name, "127.0.0.1")) return error.InvalidGoogleCallbackUrl;

    const path = switch (uri.path) {
        .raw => |p| p,
        .percent_encoded => |p| p,
    };
    if (!std.mem.eql(u8, path, redirect_path)) return error.InvalidGoogleCallbackUrl;

    const raw_query = switch (uri.query orelse return error.InvalidGoogleCallbackUrl) {
        .raw => |q| q,
        .percent_encoded => |q| q,
    };
    if (raw_query.len == 0) return error.InvalidGoogleCallbackUrl;

    return alloc.print(redirect_path ++ "?{s}", .{raw_query});
}

fn parseBrowserCallbackTarget(
    alloc: Allocator,
    target: []const u8,
    expected_state: []const u8,
) !BrowserCallback {
    const prefix = redirect_path ++ "?";
    if (!std.mem.startsWith(u8, target, prefix) or std.mem.findScalar(u8, target, '#') != null) {
        return error.InvalidGoogleOAuthCallback;
    }
    const query = target[prefix.len..];

    const state = oauth.queryValueAlloc(alloc, query, "state") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GoogleOAuthStateMismatch,
    };
    defer secret.zeroAndFree(alloc, state);
    if (!constantTimeEql(state, expected_state)) {
        return error.GoogleOAuthStateMismatch;
    }

    if (oauth.queryValueAlloc(alloc, query, "error")) |err_value| {
        defer alloc.free(err_value);
        if (std.mem.eql(u8, err_value, "access_denied")) {
            return error.Cancelled;
        }
        return error.GoogleAuthorizationFailed;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MissingQueryParameter => {},
        else => return error.InvalidGoogleOAuthCallback,
    }

    const code = oauth.queryValueNonEmptyAlloc(alloc, query, "code") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGoogleOAuthCallback,
    };
    return .{ .code = code };
}

fn constantTimeEql(actual: []const u8, expected: []const u8) bool {
    if (expected.len == 0 or actual.len != expected.len) return false;
    var diff: u8 = 0;
    for (actual, expected) |a, b| {
        diff |= a ^ b;
    }
    return diff == 0;
}

fn hasRequiredScope(granted: []const u8, wanted: []const u8) bool {
    var tokens = std.mem.tokenizeScalar(u8, granted, ' ');
    while (tokens.next()) |scope| {
        if (std.mem.eql(u8, scope, wanted)) return true;
    }
    return false;
}

fn splitScopesAlloc(alloc: Allocator, granted: []const u8) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| alloc.free(item);
        list.deinit(alloc);
    }
    var tokens = std.mem.tokenizeScalar(u8, granted, ' ');
    while (tokens.next()) |scope| {
        if (list.items.len >= max_granted_scopes) break;
        try list.append(alloc, try alloc.dupe(u8, scope));
    }
    return list.toOwnedSlice(alloc);
}

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidGoogleOAuthResponse;
    if (value != .string or value.string.len == 0) return error.InvalidGoogleOAuthResponse;
    return alloc.dupe(u8, value.string);
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Parses an RFC 9110 IMF-fixdate (`Sun, 06 Nov 1994 08:49:37 GMT`) into Unix
/// seconds, or null if malformed or before 1970-01-01.
pub fn parseHttpDate(raw: []const u8) ?i64 {
    const s = std.mem.trim(u8, raw, " \t");
    if (s.len != http_date_len) return null;
    if (s[3] != ',' or s[4] != ' ' or s[7] != ' ' or s[11] != ' ' or s[16] != ' ' or
        s[19] != ':' or s[22] != ':' or s[25] != ' ')
    {
        return null;
    }
    if (!validWeekday(s[0..3])) return null;
    if (!std.mem.eql(u8, s[26..29], "GMT")) return null;

    const day = parseDigits(u8, s[5..7]) orelse return null;
    const month = parseMonth(s[8..11]) orelse return null;
    const year = parseDigits(u16, s[12..16]) orelse return null;
    const hour = parseDigits(u8, s[17..19]) orelse return null;
    const minute = parseDigits(u8, s[20..22]) orelse return null;
    const second = parseDigits(u8, s[23..25]) orelse return null;

    if (year < 1970) return null;
    if (day < 1 or day > std.time.epoch.getDaysInMonth(year, month)) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    const days = daysFromCivil(year, month.numeric(), day);
    return days * std.time.s_per_day +
        @as(i64, hour) * std.time.s_per_hour +
        @as(i64, minute) * std.time.s_per_min +
        @as(i64, second);
}

pub fn formatHttpDate(buf: *[http_date_len]u8, epoch_s: i64) []const u8 {
    const clamped = @max(epoch_s, 0);
    const days = @divFloor(clamped, std.time.s_per_day);
    const rem = @mod(clamped, std.time.s_per_day);
    const hour: u8 = @intCast(@divFloor(rem, std.time.s_per_hour));
    const minute: u8 = @intCast(@divFloor(@mod(rem, std.time.s_per_hour), std.time.s_per_min));
    const second: u8 = @intCast(@mod(rem, std.time.s_per_min));
    const civil = civilFromDays(days);
    const weekday_idx: usize = @intCast(@mod(days + 4, 7));
    return std.mem.print(
        buf,
        "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT",
        .{
            weekday_names[weekday_idx],
            civil.day,
            month_names[civil.month - 1],
            civil.year,
            hour,
            minute,
            second,
        },
    ) catch unreachable;
}

fn validWeekday(day: []const u8) bool {
    for (weekday_names) |name| {
        if (std.mem.eql(u8, day, name)) return true;
    }
    return false;
}

fn parseMonth(mon: []const u8) ?std.time.epoch.Month {
    for (month_names, 1..) |name, idx| {
        if (std.mem.eql(u8, mon, name)) return @fromBackingInt(@intCast(idx));
    }
    return null;
}

fn parseDigits(comptime T: type, s: []const u8) ?T {
    var val: T = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        val = val * 10 + (c - '0');
    }
    return val;
}

fn daysFromCivil(year: u16, month: u8, day: u8) i64 {
    var y: i64 = year;
    const m: i64 = month;
    const d: i64 = day;
    if (m <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (m + (if (m > 2) @as(i64, -3) else @as(i64, 9))) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const CivilDate = struct {
    year: u16,
    month: u8,
    day: u8,
};

fn civilFromDays(days_since_epoch: i64) CivilDate {
    const z = days_since_epoch + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9));
    const year: u16 = @intCast(y + (if (m <= 2) @as(i64, 1) else @as(i64, 0)));
    return .{
        .year = year,
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const TestEnv = struct {
    alloc: Allocator,
    map: std.process.Environ.Map,

    fn install(alloc: Allocator, entries: []const [2][]const u8) !*TestEnv {
        const self = try alloc.create(TestEnv);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .map = std.process.Environ.Map.init(alloc),
        };
        errdefer self.map.deinit();
        try self.map.put("FX_DISABLE_KEYCHAIN", "1");
        for (entries) |entry| {
            try self.map.put(entry[0], entry[1]);
        }
        io_mod.setEnvironMap(&self.map);
        return self;
    }

    fn deinit(self: *TestEnv) void {
        io_mod.resetEnvironForTest();
        self.map.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }
};

const TestHome = struct {
    alloc: Allocator,
    tmp: testing.TmpDir,
    path: []u8,
    env: ?*TestEnv = null,

    fn init(alloc: Allocator, extra_entries: []const [2][]const u8) !TestHome {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "");
        errdefer alloc.free(path);
        var self = TestHome{
            .alloc = alloc,
            .tmp = tmp,
            .path = path,
        };
        try self.installEnv(extra_entries);
        return self;
    }

    fn initDefaultClient(alloc: Allocator) !TestHome {
        return init(alloc, &.{
            .{ e2e_token_url_env, "http://127.0.0.1:1/token" },
            .{ e2e_client_id_env, "test-client-id" },
            .{ e2e_client_secret_env, "test-client-secret" },
        });
    }

    fn installEnv(self: *TestHome, extra_entries: []const [2][]const u8) !void {
        if (self.env) |old| old.deinit();
        self.env = null;
        const entries = try self.alloc.alloc([2][]const u8, extra_entries.len + 1);
        defer self.alloc.free(entries);
        entries[0] = .{ "HOME", self.path };
        @memcpy(entries[1..], extra_entries);
        self.env = try TestEnv.install(self.alloc, entries);
    }

    fn deinit(self: *TestHome) void {
        if (self.env) |env| env.deinit();
        self.alloc.free(self.path);
        self.tmp.cleanup();
    }
};

fn ErrorTransport(comptime err: anyerror) type {
    return struct {
        calls: usize = 0,

        fn provider(self: *@This()) oauth_transport.Provider {
            return .{ .context = self, .execute_fn = execute };
        }

        fn execute(raw: ?*anyopaque, _: Allocator, _: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return err;
        }
    };
}

fn FixedResponseTransport(comptime status: u16, comptime body: []const u8) type {
    return struct {
        fn provider() oauth_transport.Provider {
            return .{ .execute_fn = execute };
        }

        fn execute(_: ?*anyopaque, a: Allocator, _: oauth_transport.Request) !oauth_transport.Response {
            return .{
                .disposition = if (status == 200) .accepted else .rejected,
                .status = status,
                .body = try a.dupe(u8, body),
            };
        }
    };
}

const AuthQueryParams = struct {
    redirect_uri: []u8,
    state: []u8,
    nonce: []u8,

    fn fromRuntime(alloc: Allocator, runtime: *login_flow.SignInRuntime) !AuthQueryParams {
        const auth_url = (try runtime.browserUrlAlloc(alloc)).?;
        defer alloc.free(auth_url);
        const query = auth_url[std.mem.findScalar(u8, auth_url, '?').? + 1 ..];
        const redirect_uri = try oauth.queryValueAlloc(alloc, query, "redirect_uri");
        errdefer alloc.free(redirect_uri);
        const state = try oauth.queryValueAlloc(alloc, query, "state");
        errdefer alloc.free(state);
        const nonce = try oauth.queryValueAlloc(alloc, query, "nonce");
        return .{ .redirect_uri = redirect_uri, .state = state, .nonce = nonce };
    }

    fn deinit(self: *AuthQueryParams, alloc: Allocator) void {
        alloc.free(self.redirect_uri);
        alloc.free(self.state);
        alloc.free(self.nonce);
    }
};

fn waitSignInTransition(alloc: Allocator, runtime: *login_flow.SignInRuntime) login_flow.SignInTransition {
    while (true) {
        const next = runtime.pollTransition(alloc);
        if (next != .none) return next;
        io_mod.sleep(5 * std.time.ns_per_ms);
    }
}

fn buildTestIdToken(
    alloc: Allocator,
    iss: []const u8,
    aud: []const u8,
    exp: i64,
    nonce: []const u8,
    sub: []const u8,
    email: []const u8,
) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header = "eyJhbGciOiJSUzI1NiJ9";
    const claims_json = try alloc.print(
        "{{\"iss\":\"{s}\",\"aud\":\"{s}\",\"exp\":{d},\"nonce\":\"{s}\",\"sub\":\"{s}\",\"email\":\"{s}\"}}",
        .{ iss, aud, exp, nonce, sub, email },
    );
    defer alloc.free(claims_json);
    const payload = try alloc.alloc(u8, encoder.calcSize(claims_json.len));
    defer alloc.free(payload);
    _ = encoder.encode(payload, claims_json);
    return alloc.print("{s}.{s}.c2lnbmF0dXJl", .{ header, payload });
}

fn saveTestAccount(alloc: Allocator, sub: []const u8, access_token: []const u8, access_exp_s: i64, refresh_exp_s: i64, nonce: ?[]const u8) !void {
    const seed: [dpop.seed_bytes]u8 = @splat(0x42);
    const kp = try dpop.keyPairFromSeed(seed);
    const encoded_key = try dpop.encodeSecretKeyAlloc(alloc, kp);
    defer secret.zeroAndFree(alloc, encoded_key);

    var mutation = try google_session.beginMutation(alloc);
    defer mutation.deinit(alloc);
    var record = if (mutation.record) |*existing| try existing.clone(alloc) else google_session.Record{};
    defer record.deinit(alloc);
    try record.upsertAccount(alloc, .{
        .subject = sub,
        .email = "user@example.com",
        .client_id = "test-client-id",
        .refresh_token = "1//saved-refresh",
        .refresh_token_expires_at_s = refresh_exp_s,
        .access_token = access_token,
        .access_token_expires_at_s = access_exp_s,
        .dpop_private_key = encoded_key,
        .dpop_nonce = nonce,
        .granted_scopes = &.{ "openid", required_scope },
    }, true);
    try mutation.save(alloc, record);
}

test "Google release client is fx's Desktop client in the fx-cli project" {
    try testing.expect(std.mem.startsWith(u8, fx_desktop_client_id, "4117256784-"));
    try testing.expect(std.mem.endsWith(u8, fx_desktop_client_id, ".apps.googleusercontent.com"));
}

test "Google placeholder client fails with GoogleClientNotConfigured and sends nothing" {
    const alloc = testing.allocator;
    var home = try TestHome.init(alloc, &.{});
    defer home.deinit();

    const CountingTransport = ErrorTransport(error.UnexpectedTransportCall);

    const cases = [_]struct {
        entries: []const [2][]const u8,
        expected_err: anyerror,
    }{
        .{
            .entries = &.{},
            .expected_err = error.GoogleClientNotConfigured,
        },
        .{
            .entries = &.{
                .{ e2e_client_id_env, "test-client-id" },
                .{ e2e_client_secret_env, "test-client-secret" },
            },
            .expected_err = error.GoogleClientNotConfigured,
        },
        .{
            .entries = &.{
                .{ e2e_token_url_env, "https://evil.example/token" },
                .{ e2e_client_id_env, "test-client-id" },
                .{ e2e_client_secret_env, "test-client-secret" },
            },
            .expected_err = error.InvalidE2EGoogleEndpoint,
        },
    };

    for (cases) |case| {
        try home.installEnv(case.entries);
        var transport_state = CountingTransport{};
        var runtime: login_flow.SignInRuntime = .{};
        defer runtime.deinit(alloc);
        try testing.expectError(
            case.expected_err,
            startSignIn(&runtime, alloc, transport_state.provider()),
        );
        try testing.expectEqual(@as(usize, 0), transport_state.calls);
    }
}

test "Google authorize URL includes required PKCE, state, and nonce fields and omits prompt on first sign-in" {
    const alloc = testing.allocator;
    const first_url = try buildBrowserAuthorizationUrl(
        alloc,
        authorize_url,
        "client-123",
        "http://127.0.0.1:53682/oauth2callback",
        "challenge-abc",
        "state-xyz",
        "nonce-999",
        .{},
    );
    defer alloc.free(first_url);

    try testing.expect(std.mem.startsWith(u8, first_url, "https://accounts.google.com/o/oauth2/v2/auth?"));
    try testing.expect(std.mem.find(u8, first_url, "client_id=client-123") != null);
    try testing.expect(std.mem.find(u8, first_url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2Foauth2callback") != null);
    try testing.expect(std.mem.find(u8, first_url, "response_type=code") != null);
    try testing.expect(std.mem.find(u8, first_url, "code_challenge=challenge-abc") != null);
    try testing.expect(std.mem.find(u8, first_url, "code_challenge_method=S256") != null);
    try testing.expect(std.mem.find(u8, first_url, "state=state-xyz") != null);
    try testing.expect(std.mem.find(u8, first_url, "nonce=nonce-999") != null);
    try testing.expect(std.mem.find(u8, first_url, "prompt=") == null);
    try testing.expect(std.mem.find(u8, first_url, "login_hint=") == null);

    const retry_url = try buildBrowserAuthorizationUrl(
        alloc,
        authorize_url,
        "client-123",
        "http://127.0.0.1:53682/oauth2callback",
        "challenge-abc",
        "state-xyz",
        "nonce-999",
        .{ .force_consent = true },
    );
    defer alloc.free(retry_url);
    try testing.expect(std.mem.find(u8, retry_url, "prompt=consent") != null);
}

test "Google callback rejects state mismatch and cancels neutrally on access_denied while keeping saved accounts" {
    const alloc = testing.allocator;
    var home = try TestHome.initDefaultClient(alloc);
    defer home.deinit();

    // Pre-existing saved account must survive access_denied.
    try saveTestAccount(alloc, "existing-sub", "ya29.existing", nowSeconds() + 3600, nowSeconds() + 86400, null);

    try testing.expectError(
        error.GoogleOAuthStateMismatch,
        parseBrowserCallbackTarget(alloc, "/oauth2callback?code=c&state=wrong", "expected-state"),
    );
    try testing.expectError(
        error.GoogleOAuthStateMismatch,
        parseBrowserCallbackTarget(alloc, "/oauth2callback?error=access_denied&state=wrong", "expected-state"),
    );
    try testing.expectError(
        error.Cancelled,
        parseBrowserCallbackTarget(alloc, "/oauth2callback?error=access_denied&code=ignored&state=expected-state", "expected-state"),
    );

    const TokenProbe = ErrorTransport(error.UnexpectedTokenCall);
    var probe = TokenProbe{};
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    try testing.expect(try startSignIn(&runtime, alloc, probe.provider()));
    var params = try AuthQueryParams.fromRuntime(alloc, &runtime);
    defer params.deinit(alloc);

    const denied_url = try alloc.print("{s}?error=access_denied&state={s}", .{ params.redirect_uri, params.state });
    defer alloc.free(denied_url);
    try testing.expect(try runtime.submitManualCode(alloc, denied_url));

    try testing.expectEqual(login_flow.SignInTransition.cancelled, waitSignInTransition(alloc, &runtime));
    try testing.expectEqual(@as(usize, 0), probe.calls);

    var saved = (try google_session.loadActiveAccount(alloc)).?;
    defer saved.deinit(alloc);
    try testing.expectEqualStrings("existing-sub", saved.subject);
}

test "Google manual fallback refuses bare code and accepts full callback URL" {
    const alloc = testing.allocator;
    const redirect_uri = "http://127.0.0.1:53682/oauth2callback";

    try testing.expectError(error.InvalidGoogleCallbackUrl, parseManualCallbackTargetAlloc(alloc, "4/0AfJohBareCode", redirect_uri));
    try testing.expectError(error.InvalidGoogleCallbackUrl, parseManualCallbackTargetAlloc(alloc, "https://evil.com/oauth2callback?code=c&state=s", redirect_uri));
    try testing.expectError(error.InvalidGoogleCallbackUrl, parseManualCallbackTargetAlloc(alloc, "http://127.0.0.1:9999/oauth2callback?code=c&state=s", redirect_uri));

    const target = try parseManualCallbackTargetAlloc(alloc, "  http://127.0.0.1:53682/oauth2callback?code=4%2Fabc&state=st  ", redirect_uri);
    defer alloc.free(target);
    try testing.expectEqualStrings("/oauth2callback?code=4%2Fabc&state=st", target);

    var cb = try parseBrowserCallbackTarget(alloc, target, "st");
    defer cb.deinit(alloc);
    try testing.expectEqualStrings("4/abc", cb.code);
}

test "Google sign-in runtime saves account through pasted callback URL and refuses bare code" {
    const alloc = testing.allocator;
    var home = try TestHome.initDefaultClient(alloc);
    defer home.deinit();

    const ExchangeTransport = struct {
        nonce: []const u8 = "",
        saw_dpop_jti_match: bool = false,
        saw_client_secret: bool = false,

        fn execute(raw: ?*anyopaque, a: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const payload = request.payload orelse "";
            self.saw_client_secret = std.mem.find(u8, payload, "client_secret=test-client-secret") != null;
            if (request.dpop) |proof| {
                var claims = try jwt_claims.parse(a, proof);
                defer claims.deinit();
                const expected_jti = try dpop.codeExchangeJtiAlloc(a, "4/encoded-code");
                defer a.free(expected_jti);
                self.saw_dpop_jti_match = std.mem.eql(u8, claims.value.object.get("jti").?.string, expected_jti);
            }
            const id_tok = try buildTestIdToken(a, accepted_issuer_https, "test-client-id", nowSeconds() + 3600, self.nonce, "sub-google-1", "dev@example.com");
            defer a.free(id_tok);
            const body = try a.print(
                "{{\"access_token\":\"ya29.new-access\",\"refresh_token\":\"1//new-refresh\",\"expires_in\":3599,\"refresh_token_expires_in\":604800,\"token_type\":\"Bearer\",\"scope\":\"openid email {s}\",\"id_token\":\"{s}\"}}",
                .{ required_scope, id_tok },
            );
            return .{ .disposition = .accepted, .status = 200, .body = body };
        }
    };

    var transport = ExchangeTransport{};
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    try testing.expect(try startSignIn(&runtime, alloc, .{ .context = &transport, .execute_fn = ExchangeTransport.execute }));

    try testing.expectError(error.InvalidGoogleCallbackUrl, runtime.submitManualCode(alloc, "4/encoded-code"));

    var params = try AuthQueryParams.fromRuntime(alloc, &runtime);
    defer params.deinit(alloc);
    transport.nonce = params.nonce;

    const full_url = try alloc.print("{s}?code=4%2Fencoded-code&state={s}", .{ params.redirect_uri, params.state });
    defer alloc.free(full_url);
    try testing.expect(try runtime.submitManualCode(alloc, full_url));

    switch (waitSignInTransition(alloc, &runtime)) {
        .succeeded => |completion| {
            var owned = completion;
            defer owned.deinit(alloc);
            try testing.expect(owned == .google);
            try testing.expectEqualStrings("sub-google-1", owned.google.subject);
        },
        else => return error.TestExpectedSucceededSignIn,
    }
    try testing.expect(transport.saw_dpop_jti_match);
    try testing.expect(transport.saw_client_secret);

    var saved = (try google_session.loadActiveAccount(alloc)).?;
    defer saved.deinit(alloc);
    try testing.expectEqualStrings("sub-google-1", saved.subject);
    try testing.expectEqualStrings("dev@example.com", saved.email);
    try testing.expectEqualStrings("ya29.new-access", saved.access_token);
    try testing.expectEqualStrings("1//new-refresh", saved.refresh_token);
}

test "Google code exchange uses SHA-256 of decoded code as jti and never retries on failure" {
    const alloc = testing.allocator;
    const ExchangeProbe = struct {
        calls: usize = 0,
        dpop_jti_ok: bool = false,
        fail_status: ?u16 = null,

        fn execute(raw: ?*anyopaque, a: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (request.dpop) |proof| {
                var claims = try jwt_claims.parse(a, proof);
                defer claims.deinit();
                const expected_jti = try dpop.codeExchangeJtiAlloc(a, "4/decoded_code");
                defer a.free(expected_jti);
                const got_jti = claims.value.object.get("jti").?.string;
                self.dpop_jti_ok = std.mem.eql(u8, expected_jti, got_jti);
            }
            if (self.fail_status) |status| {
                return .{
                    .disposition = .rejected,
                    .status = status,
                    .body = try a.dupe(u8, "{\"error\":\"use_dpop_nonce\"}"),
                    .dpop_nonce = try a.dupe(u8, "server-nonce"),
                };
            }
            return .{ .disposition = .rejected, .status = 500, .body = try a.dupe(u8, "{}") };
        }
    };

    var probe = ExchangeProbe{ .fail_status = 400 };
    try testing.expectError(
        error.GoogleOAuthRequestFailed,
        exchangeAuthorizationCode(
            alloc,
            .{ .context = &probe, .execute_fn = ExchangeProbe.execute },
            "http://127.0.0.1:1/token",
            "4/decoded_code",
            "verifier",
            "http://127.0.0.1:53682/oauth2callback",
            "test-client-id",
            "test-client-secret",
            "nonce-1",
            null,
            null,
        ),
    );
    try testing.expect(probe.dpop_jti_ok);
    try testing.expectEqual(@as(usize, 1), probe.calls);
}

test "Google token response checks required scope and id_token claims" {
    const alloc = testing.allocator;
    const now_s: i64 = 1_700_000_000;
    const seed: [dpop.seed_bytes]u8 = @splat(0x11);
    const kp = try dpop.keyPairFromSeed(seed);

    // Missing required scope -> GoogleScopeMissing.
    {
        const key_text = try dpop.encodeSecretKeyAlloc(alloc, kp);
        defer secret.zeroAndFree(alloc, key_text);
        const id_tok = try buildTestIdToken(alloc, accepted_issuer_https, "cid", now_s + 3600, "n1", "sub1", "a@b.com");
        defer alloc.free(id_tok);
        const body = try alloc.print(
            "{{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_in\":3599,\"token_type\":\"Bearer\",\"scope\":\"openid email\",\"id_token\":\"{s}\"}}",
            .{id_tok},
        );
        defer alloc.free(body);
        try testing.expectError(
            error.GoogleScopeMissing,
            parseCodeExchangeResponse(alloc, body, "cid", "n1", key_text, null, now_s),
        );
    }

    // Bad issuer, audience, expiry (beyond 60s skew), and nonce are each refused.
    const bad_iss = try buildTestIdToken(alloc, "https://evil.example", "cid", now_s + 3600, "n1", "sub1", "a@b.com");
    defer alloc.free(bad_iss);
    try testing.expectError(error.GoogleIdTokenInvalidIssuer, validateIdTokenClaims(alloc, bad_iss, "cid", "n1", now_s));

    const bad_aud = try buildTestIdToken(alloc, accepted_issuer_host, "other-cid", now_s + 3600, "n1", "sub1", "a@b.com");
    defer alloc.free(bad_aud);
    try testing.expectError(error.GoogleIdTokenInvalidAudience, validateIdTokenClaims(alloc, bad_aud, "cid", "n1", now_s));

    const expired = try buildTestIdToken(alloc, accepted_issuer_https, "cid", now_s - id_token_clock_skew_s, "n1", "sub1", "a@b.com");
    defer alloc.free(expired);
    try testing.expectError(error.GoogleIdTokenExpired, validateIdTokenClaims(alloc, expired, "cid", "n1", now_s));

    const within_skew = try buildTestIdToken(alloc, accepted_issuer_https, "cid", now_s - id_token_clock_skew_s + 1, "n1", "sub1", "a@b.com");
    defer alloc.free(within_skew);
    var ok_claims = try validateIdTokenClaims(alloc, within_skew, "cid", "n1", now_s);
    ok_claims.deinit(alloc);

    const bad_nonce = try buildTestIdToken(alloc, accepted_issuer_https, "cid", now_s + 3600, "wrong-nonce", "sub1", "a@b.com");
    defer alloc.free(bad_nonce);
    try testing.expectError(error.GoogleIdTokenInvalidNonce, validateIdTokenClaims(alloc, bad_nonce, "cid", "n1", now_s));
}

test "Google refresh retries once on use_dpop_nonce, saves rotated nonce, clears on invalid_grant, and keeps on 503" {
    const alloc = testing.allocator;
    var home = try TestHome.initDefaultClient(alloc);
    defer home.deinit();

    // 1. use_dpop_nonce -> retry once with new nonce -> 200 saves rotated nonce.
    try saveTestAccount(alloc, "sub-1", "ya29.old", nowSeconds() - 10, nowSeconds() + 86400, null);
    const NonceProbe = struct {
        calls: usize = 0,
        saw_nonce_on_second: bool = false,
        fn execute(raw: ?*anyopaque, a: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (self.calls == 1) {
                return .{
                    .disposition = .rejected,
                    .status = 400,
                    .body = try a.dupe(u8, "{\"error\":\"use_dpop_nonce\"}"),
                    .dpop_nonce = try a.dupe(u8, "nonce-step-1"),
                };
            }
            var claims = try jwt_claims.parse(a, request.dpop.?);
            defer claims.deinit();
            self.saw_nonce_on_second = std.mem.eql(u8, claims.value.object.get("nonce").?.string, "nonce-step-1");
            return .{
                .disposition = .accepted,
                .status = 200,
                .body = try a.dupe(u8, "{\"access_token\":\"ya29.fresh\",\"expires_in\":3599}"),
                .dpop_nonce = try a.dupe(u8, "nonce-step-2"),
            };
        }
    };
    var nonce_probe = NonceProbe{};
    var access = (try loadAccess(alloc, .{ .context = &nonce_probe, .execute_fn = NonceProbe.execute }, .if_needed)).?;
    defer access.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), nonce_probe.calls);
    try testing.expect(nonce_probe.saw_nonce_on_second);
    try testing.expectEqualStrings("ya29.fresh", access.access_token);
    var saved_after_200 = (try google_session.loadActiveAccount(alloc)).?;
    defer saved_after_200.deinit(alloc);
    try testing.expectEqualStrings("nonce-step-2", saved_after_200.dpop_nonce.?);

    // 2. 503 keeps the saved account.
    try testing.expectError(
        error.GoogleOAuthRequestFailed,
        loadAccess(alloc, FixedResponseTransport(503, "{}").provider(), .force),
    );
    var kept = (try google_session.loadActiveAccount(alloc)) orelse return error.TestExpectedKeptGoogleAccount;
    kept.deinit(alloc);

    // 3. invalid_grant removes the account and returns GoogleSignInRequired.
    try testing.expectError(
        error.GoogleSignInRequired,
        loadAccess(alloc, FixedResponseTransport(400, "{\"error\":\"invalid_grant\"}").provider(), .force),
    );
    try testing.expect((try google_session.loadActiveAccount(alloc)) == null);

    // Damaged google-auth.json during refresh returns InvalidGoogleSession cleanly.
    {
        var tmp_fx = try home.tmp.dir.openDir(testing.io, ".fx", .{});
        defer tmp_fx.close(testing.io);
        try tmp_fx.writeFile(testing.io, .{
            .sub_path = google_session.auth_file_name,
            .data = "{\"schema_version\":1}\n",
            .flags = .{ .permissions = .fromMode(0o600) },
        });
        try testing.expectError(
            error.InvalidGoogleSession,
            loadAccess(alloc, oauth_transport.unavailable_provider, .if_needed),
        );
        try tmp_fx.deleteFile(testing.io, google_session.auth_file_name);
    }

    // 4. invalid_dpop_proof retries once with server time parsed from Date header.
    try saveTestAccount(alloc, "sub-clock", "ya29.old", nowSeconds() - 10, nowSeconds() + 86400, "nonce-1");
    const ClockProbe = struct {
        calls: usize = 0,
        saw_server_iat: bool = false,
        fn execute(raw: ?*anyopaque, a: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (self.calls == 1) {
                return .{
                    .disposition = .rejected,
                    .status = 400,
                    .body = try a.dupe(u8, "{\"error\":\"invalid_dpop_proof\"}"),
                    .date_header = try a.dupe(u8, "Tue, 29 Feb 2000 12:34:56 GMT"),
                };
            }
            var claims = try jwt_claims.parse(a, request.dpop.?);
            defer claims.deinit();
            self.saw_server_iat = claims.value.object.get("iat").?.integer == 951827696;
            return .{
                .disposition = .accepted,
                .status = 200,
                .body = try a.dupe(u8, "{\"access_token\":\"ya29.clock-ok\",\"expires_in\":3599}"),
            };
        }
    };
    var clock_probe = ClockProbe{};
    var clock_access = (try loadAccess(alloc, .{ .context = &clock_probe, .execute_fn = ClockProbe.execute }, .if_needed)).?;
    defer clock_access.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), clock_probe.calls);
    try testing.expect(clock_probe.saw_server_iat);
    try testing.expectEqualStrings("ya29.clock-ok", clock_access.access_token);
}

test "Google concurrent loadAccess calls refresh only once" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const alloc = testing.allocator;
    var home = try TestHome.initDefaultClient(alloc);
    defer home.deinit();

    try saveTestAccount(alloc, "sub-conc", "ya29.stale", nowSeconds() - 10, nowSeconds() + 86400, null);

    const ConcurrentProbe = struct {
        calls: std.atomic.Value(usize) = .init(0),
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),

        fn execute(raw: ?*anyopaque, a: Allocator, _: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.calls.fetchAdd(1, .seq_cst);
            self.entered.store(true, .seq_cst);
            while (!self.release.load(.seq_cst)) {
                std.Thread.yield() catch {};
            }
            return .{
                .disposition = .accepted,
                .status = 200,
                .body = try a.dupe(u8, "{\"access_token\":\"ya29.shared-new\",\"expires_in\":3599}"),
            };
        }
    };

    const Worker = struct {
        transport: oauth_transport.Provider,
        token: ?[]u8 = null,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            if (loadAccess(std.testing.allocator, self.transport, .if_needed)) |maybe_access| {
                if (maybe_access) |access_val| {
                    var owned = access_val;
                    self.token = std.testing.allocator.dupe(u8, owned.access_token) catch null;
                    owned.deinit(std.testing.allocator);
                }
            } else |err| {
                self.err = err;
            }
        }
    };

    var probe = ConcurrentProbe{};
    const transport: oauth_transport.Provider = .{ .context = &probe, .execute_fn = ConcurrentProbe.execute };
    var w1 = Worker{ .transport = transport };
    var w2 = Worker{ .transport = transport };

    const t1 = try std.Thread.spawn(.{}, Worker.run, .{&w1});
    while (!probe.entered.load(.seq_cst)) std.Thread.yield() catch {};
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{&w2});
    io_mod.sleep(10 * std.time.ns_per_ms);
    probe.release.store(true, .seq_cst);

    t1.join();
    t2.join();
    defer if (w1.token) |t| secret.zeroAndFree(alloc, t);
    defer if (w2.token) |t| secret.zeroAndFree(alloc, t);

    try testing.expect(w1.err == null);
    try testing.expect(w2.err == null);
    try testing.expectEqual(@as(usize, 1), probe.calls.load(.seq_cst));
    try testing.expectEqualStrings("ya29.shared-new", w1.token.?);
    try testing.expectEqualStrings("ya29.shared-new", w2.token.?);
}

test "Google revoke posts token without DPoP and deletes local tokens even when offline" {
    const alloc = testing.allocator;
    var home = try TestHome.init(alloc, &.{.{ e2e_revoke_url_env, "http://127.0.0.1:1/revoke" }});
    defer home.deinit();

    try saveTestAccount(alloc, "sub-rev-1", "ya29.a", nowSeconds() + 3600, nowSeconds() + 86400, null);
    const OnlineRevoke = struct {
        saw_dpop: bool = false,
        saw_token: bool = false,
        fn execute(raw: ?*anyopaque, a: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.saw_dpop = request.dpop != null;
            self.saw_token = std.mem.eql(u8, request.payload orelse "", "token=1%2F%2Fsaved-refresh");
            return .{ .disposition = .accepted, .status = 200, .body = try a.dupe(u8, "") };
        }
    };
    var online = OnlineRevoke{};
    const res_ok = try disconnectAccount(alloc, .{ .context = &online, .execute_fn = OnlineRevoke.execute }, null);
    try testing.expect(res_ok.local_deleted);
    try testing.expect(res_ok.remote_revoked);
    try testing.expect(!online.saw_dpop);
    try testing.expect(online.saw_token);
    try testing.expect((try google_session.loadActiveAccount(alloc)) == null);

    try saveTestAccount(alloc, "sub-rev-2", "ya29.b", nowSeconds() + 3600, nowSeconds() + 86400, null);
    var offline = ErrorTransport(error.ConnectionRefused){};
    const res_offline = try disconnectAccount(alloc, offline.provider(), null);
    try testing.expect(res_offline.local_deleted);
    try testing.expect(!res_offline.remote_revoked);
    try testing.expect((try google_session.loadActiveAccount(alloc)) == null);
}

test "Google OAuth errors and traces never leak secrets" {
    const alloc = testing.allocator;
    const canary_secret = "canary_client_secret_987";
    const canary_code = "canary_auth_code_654";
    const canary_verifier = "canary_pkce_verifier_321";

    var home = try TestHome.init(alloc, &.{
        .{ e2e_token_url_env, "http://127.0.0.1:1/token" },
        .{ e2e_client_id_env, "test-client-id" },
        .{ e2e_client_secret_env, canary_secret },
    });
    defer home.deinit();

    const trace_path = try std.Io.Dir.path.join(alloc, &.{ home.path, "trace.log" });
    defer alloc.free(trace_path);
    try debug_trace.configure(.{ .file_path = trace_path });
    defer debug_trace.shutdown();

    const err_res = exchangeAuthorizationCode(
        alloc,
        FixedResponseTransport(400, "{\"error\":\"invalid_grant\"}").provider(),
        "http://127.0.0.1:1/token",
        canary_code,
        canary_verifier,
        "http://127.0.0.1:53682/oauth2callback",
        "test-client-id",
        canary_secret,
        "canary_nonce",
        null,
        null,
    );
    try testing.expectError(error.GoogleOAuthRequestFailed, err_res);

    var trace_file = try home.tmp.dir.openFile(testing.io, "trace.log", .{ .mode = .read_only });
    defer trace_file.close(testing.io);
    const trace_bytes = try io_mod.readFileToEnd(alloc, &trace_file, 64 * 1024);
    defer alloc.free(trace_bytes);
    try testing.expect(std.mem.find(u8, trace_bytes, canary_secret) == null);
    try testing.expect(std.mem.find(u8, trace_bytes, canary_code) == null);
    try testing.expect(std.mem.find(u8, trace_bytes, canary_verifier) == null);
}

test "HTTP-date parser handles valid IMF-fixdates and rejects invalid dates" {
    try testing.expectEqual(@as(?i64, 0), parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT"));
    try testing.expectEqual(@as(?i64, 784111777), parseHttpDate("Sun, 06 Nov 1994 08:49:37 GMT"));
    try testing.expectEqual(@as(?i64, 951827696), parseHttpDate("  Tue, 29 Feb 2000 12:34:56 GMT  "));
    try testing.expect(parseHttpDate("Thu, 29 Feb 2023 00:00:00 GMT") == null);
    try testing.expect(parseHttpDate("Wed, 31 Dec 1969 23:59:59 GMT") == null);
    try testing.expect(parseHttpDate("Thu, 01 Jan 1970 24:00:00 GMT") == null);
    try testing.expect(parseHttpDate("Thu, 01 Jan 1970 00:00:00 UTC") == null);
    try testing.expect(parseHttpDate("") == null);
}

fn fuzzHttpDate(_: void, smith: *testing.Smith) !void {
    var buffer: [128]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const parsed = parseHttpDate(buffer[0..len]) orelse return;
    var formatted_buf: [http_date_len]u8 = undefined;
    const formatted = formatHttpDate(&formatted_buf, parsed);
    try testing.expectEqual(parsed, parseHttpDate(formatted).?);
}

test "HTTP-date parser handles fuzzed bytes and round-trips formatted dates" {
    try testing.fuzz({}, fuzzHttpDate, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "Thu, 01 Jan 1970 00:00:00 GMT",
            "Sun, 06 Nov 1994 08:49:37 GMT",
            "Tue, 29 Feb 2000 12:34:56 GMT",
            "Thu, 29 Feb 2023 00:00:00 GMT",
            "",
            "not a date",
        }) ++ @import("fuzz_corpus").google_http_date.*),
    });
}

fn fuzzCallback(_: void, smith: *testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const len: usize = @intCast(smith.slice(&buffer));
    const input = buffer[0..len];
    const alloc = testing.allocator;

    if (parseManualCallbackTargetAlloc(alloc, input, "http://127.0.0.1:53682/oauth2callback")) |target| {
        defer secret.zeroAndFree(alloc, target);
        if (parseBrowserCallbackTarget(alloc, target, "expected-state")) |cb| {
            var owned = cb;
            owned.deinit(alloc);
        } else |_| {}
    } else |_| {}

    if (parseBrowserCallbackTarget(alloc, input, "expected-state")) |cb| {
        var owned = cb;
        owned.deinit(alloc);
    } else |_| {}
}

test "Google OAuth callback parsers handle fuzzed URLs and targets cleanly" {
    try testing.fuzz({}, fuzzCallback, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "http://127.0.0.1:53682/oauth2callback?code=4%2Fabc&state=expected-state",
            "/oauth2callback?code=c&state=expected-state",
            "/oauth2callback?error=access_denied&state=expected-state",
            "4/bare-code",
            "",
        }) ++ @import("fuzz_corpus").google_oauth_callback.*),
    });
}

test "Google signOutOnDevice removes local login without revoking, and failed disconnect queues retry" {
    const alloc = testing.allocator;
    var home = try TestHome.init(alloc, &.{.{ e2e_revoke_url_env, "http://127.0.0.1:1/revoke" }});
    defer home.deinit();

    // Local sign-out sends nothing and deletes the saved account.
    try saveTestAccount(alloc, "sub-local", "ya29.local", nowSeconds() + 3600, nowSeconds() + 86400, null);
    try testing.expect(try signOutOnDevice(alloc, null));
    try testing.expect((try google_session.loadActiveAccount(alloc)) == null);
    try testing.expect(!try signOutOnDevice(alloc, null));

    // Failed disconnect queues the token in pending_revocation, and retryKeptSignOuts clears it when /revoke succeeds.
    try saveTestAccount(alloc, "sub-retry", "ya29.retry", nowSeconds() + 3600, nowSeconds() + 86400, null);
    var fail = ErrorTransport(error.ConnectionRefused){};
    const res = try disconnectAccount(alloc, fail.provider(), null);
    try testing.expect(res.local_deleted);
    try testing.expect(!res.remote_revoked);
    try testing.expect(res.retry_kept);
    try pending_revocation.expectKept(pending_revocation.Place.of(.google), &.{"1//saved-refresh"});

    // A kept entry without a live lease (such as from an earlier exited process)
    // is retried by retryKeptSignOuts and cleared once /revoke succeeds.
    var fx_dir = try home.tmp.dir.openDir(io_mod.getIo(), ".fx", .{});
    defer fx_dir.close(io_mod.getIo());
    const record_json = try alloc.print(
        "{{\"version\":1,\"entries\":[{{\"saved_at_ms\":{d},\"refresh_token\":\"1//retry-refresh\"}}]}}\n",
        .{io_mod.milliTimestamp()},
    );
    defer alloc.free(record_json);
    var rec_file = try fx_dir.createFile(io_mod.getIo(), "google-revocations.json", .{
        .truncate = true,
        .permissions = .fromMode(0o600),
    });
    defer rec_file.close(io_mod.getIo());
    try rec_file.writeStreamingAll(io_mod.getIo(), record_json);

    const OkTransport = struct {
        calls: usize = 0,
        saw_dpop: bool = false,
        fn execute(raw: ?*anyopaque, a: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.saw_dpop = request.dpop != null;
            return .{ .disposition = .accepted, .status = 200, .body = try a.dupe(u8, "") };
        }
    };
    var ok = OkTransport{};
    const retry_res = retryKeptSignOuts(alloc, .{ .context = &ok, .execute_fn = OkTransport.execute }, null);
    try testing.expectEqual(@as(usize, 1), retry_res.revoked);
    try testing.expect(!retry_res.failed);
    try testing.expectEqual(@as(usize, 1), ok.calls);
    try testing.expect(!ok.saw_dpop);
    try pending_revocation.expectKept(pending_revocation.Place.of(.google), &.{});
}
