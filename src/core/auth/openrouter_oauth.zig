//! OpenRouter browser sign-in (D147), as proto's registry/oauth/openrouter.ts
//! does it: a PKCE S256 authorization with no client registration, a loopback
//! callback on port 54549, and an exchange of the returned code for a durable
//! `sk-or-` key. OpenRouter never echoes `state`, so the verifier alone binds
//! the exchange. Pasting an existing key, or the code from the redirect,
//! completes the same flow.
const std = @import("std");
const browser_callback = @import("browser_callback.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const login_flow = @import("login_flow.zig");
const model_provider = @import("../config/model_provider.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const provider_keys = @import("provider_keys.zig");
const secret = @import("secret.zig");
const Allocator = std.mem.Allocator;

pub const provider_id = "openrouter";
const authorize_url = "https://openrouter.ai/auth";
const keys_url = "https://openrouter.ai/api/v1/auth/keys";
const e2e_authorize_url_env = "FX_E2E_OPENROUTER_AUTH_URL";
const e2e_keys_url_env = "FX_E2E_OPENROUTER_KEYS_URL";
pub const callback_port: u16 = 54549;
pub const key_prefix = "sk-or-";
const login_timeout_seconds: i64 = 5 * 60;

const Callback = struct {
    code: []u8,

    fn deinit(self: *Callback, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.code);
        self.* = undefined;
    }
};

const Context = struct {
    listener: std.Io.net.Server,
    code_verifier: []u8,
    keys_url: []u8,
    transport: oauth_transport.Provider,
    manual_mutex: std.Io.Mutex = .init,
    manual: ?[]u8 = null,
    pending_callback: ?browser_callback.Accepted(Callback) = null,

    fn deinit(self: *Context, alloc: Allocator) void {
        self.finishCallback(alloc, false);
        self.listener.deinit(io_mod.getIo());
        secret.zeroAndFree(alloc, self.code_verifier);
        alloc.free(self.keys_url);
        if (self.manual) |value| secret.zeroAndFree(alloc, value);
        self.* = undefined;
    }

    fn finishCallback(self: *Context, alloc: Allocator, saved: bool) void {
        var callback = self.pending_callback orelse return;
        self.pending_callback = null;
        defer callback.deinit();
        defer callback.callback.deinit(alloc);
        callback.respond(if (saved) .ok else .failed) catch {};
    }

    fn takeManual(self: *Context) ?[]u8 {
        self.manual_mutex.lockUncancelable(io_mod.getIo());
        defer self.manual_mutex.unlock(io_mod.getIo());
        const value = self.manual;
        self.manual = null;
        return value;
    }
};

/// Starts the browser flow on `runtime`. The completion is a provider key,
/// saved to the profile's provider key file.
pub fn startSignIn(runtime: *login_flow.SignInRuntime, alloc: Allocator, transport: oauth_transport.Provider) !bool {
    if (comptime host_target.is_wasm) return error.OpenRouterOAuthUnavailable;
    var listener = try bindCallback();
    var listener_owned = true;
    errdefer if (listener_owned) listener.deinit(io_mod.getIo());
    const redirect_uri = try alloc.print("http://localhost:{d}/callback", .{listener.socket.address.getPort()});
    defer alloc.free(redirect_uri);
    const verifier = try oauth.randomUrlSafeSecret(alloc);
    var verifier_owned = true;
    errdefer if (verifier_owned) secret.zeroAndFree(alloc, verifier);
    const challenge = try oauth.pkceChallengeAlloc(alloc, verifier);
    defer alloc.free(challenge);
    const authorize = oauth.configuredEndpoint(alloc, e2e_authorize_url_env, authorize_url) catch |err| return endpointError(err);
    defer alloc.free(authorize);
    const exchange = oauth.configuredEndpoint(alloc, e2e_keys_url_env, keys_url) catch |err| return endpointError(err);
    var exchange_owned = true;
    errdefer if (exchange_owned) alloc.free(exchange);
    const url = try authorizationUrl(alloc, authorize, redirect_uri, challenge);
    var url_owned = true;
    errdefer if (url_owned) alloc.free(url);
    const token_endpoint = try alloc.dupe(u8, exchange);
    var token_endpoint_owned = true;
    errdefer if (token_endpoint_owned) alloc.free(token_endpoint);
    var prepared = try login_flow.prepareBrowserLogin(alloc, .{
        .issuer = authorize,
        .authorization_endpoint_suffix = "",
        .token_endpoint = token_endpoint,
        .verification_uri = url,
        .client_id = "",
        .expires_in = login_timeout_seconds,
    });
    url_owned = false;
    token_endpoint_owned = false;
    errdefer prepared.deinit(alloc);
    const context = try alloc.create(Context);
    context.* = .{ .listener = listener, .code_verifier = verifier, .keys_url = exchange, .transport = transport };
    listener_owned = false;
    verifier_owned = false;
    exchange_owned = false;
    return runtime.startPrepared(alloc, prepared, .{
        .ctx = context,
        .deinit_ctx = deinitContext,
        .oauth_transport = transport,
        .poll = .{ .ctx = context, .poll_device_token = poll },
        .complete = complete,
        .save = save,
        .finish = finish,
        .submit_manual_code = submitManual,
    });
}

fn endpointError(err: anyerror) anyerror {
    return if (err == error.OutOfMemory) err else error.InvalidE2EOpenRouterEndpoint;
}

/// The fixed callback port proto registers, or any free port when it is taken.
fn bindCallback() !std.Io.net.Server {
    var fixed = try std.Io.net.IpAddress.parse("127.0.0.1", callback_port);
    return fixed.listen(io_mod.getIo(), .{ .reuse_address = true }) catch {
        var any = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        return any.listen(io_mod.getIo(), .{ .reuse_address = true });
    };
}

/// Caller owns the URL.
pub fn authorizationUrl(alloc: Allocator, base: []const u8, redirect_uri: []const u8, challenge: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{s}?", .{base});
    var form: oauth.FormBody = .{};
    try form.append(&out.writer, "callback_url", redirect_uri);
    try form.append(&out.writer, "code_challenge", challenge);
    try form.append(&out.writer, "code_challenge_method", "S256");
    return out.toOwnedSlice();
}

fn deinitContext(raw: ?*anyopaque, alloc: Allocator) void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    context.deinit(alloc);
    alloc.destroy(context);
}

fn submitManual(raw: ?*anyopaque, alloc: Allocator, input: []const u8) !void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const value = std.mem.trim(u8, input, " \t\r\n");
    if (!provider_keys.validKey(value)) return error.InvalidOpenRouterAuthorizationCode;
    const owned = try alloc.dupe(u8, value);
    context.manual_mutex.lockUncancelable(io_mod.getIo());
    defer context.manual_mutex.unlock(io_mod.getIo());
    if (context.manual) |pending| secret.zeroAndFree(alloc, pending);
    context.manual = owned;
}

fn poll(
    raw: ?*anyopaque,
    alloc: Allocator,
    transport: oauth_transport.Provider,
    _: oauth.Metadata,
    _: []const u8,
    _: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    const context: *Context = @ptrCast(@alignCast(raw.?));
    const manual = context.takeManual();
    defer if (manual) |value| secret.zeroAndFree(alloc, value);
    // A pasted key needs no exchange.
    if (manual) |value| if (std.mem.startsWith(u8, value, key_prefix)) return keyResult(alloc, value);
    var accepted: ?browser_callback.Accepted(Callback) = null;
    defer if (accepted) |*callback| {
        callback.callback.deinit(alloc);
        callback.deinit();
    };
    const code = manual orelse code: {
        accepted = (try browser_callback.await(Callback, parseCallback, alloc, &context.listener, null, cancel_flag, null)) orelse return .pending;
        break :code accepted.?.callback.code;
    };
    const key = exchangeCode(alloc, transport, context.keys_url, code, context.code_verifier, cancel_flag, deadline) catch |err| {
        if (accepted) |*callback| callback.respond(.failed) catch {};
        return err;
    };
    defer secret.zeroAndFree(alloc, key);
    const result = try keyResult(alloc, key);
    context.pending_callback = accepted;
    accepted = null;
    return result;
}

fn keyResult(alloc: Allocator, key: []const u8) !oauth.PollResult {
    const access = try alloc.dupe(u8, key);
    return .{ .success = .{ .access_token = access, .expires_in = 0, .scope = try alloc.alloc(u8, 0), .token_type = try alloc.alloc(u8, 0) } };
}

fn parseCallback(_: ?*anyopaque, alloc: Allocator, target: []const u8) browser_callback.ParseResult(Callback) {
    const prefix = "/callback?";
    if (!std.mem.startsWith(u8, target, prefix)) return .unrelated;
    const query = target[prefix.len..];
    if (oauth.queryValueNonEmptyAlloc(alloc, query, "code")) |code| {
        return .{ .accepted = .{ .code = code } };
    } else |err| {
        if (err == error.OutOfMemory) return .{ .failed = err };
        return .{ .failed = error.OpenRouterAuthorizationFailed };
    }
}

/// POSTs the code and verifier and returns the minted key. Caller owns it.
pub fn exchangeCode(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url: []const u8,
    code: []const u8,
    verifier: []const u8,
    cancel_flag: ?*std.atomic.Value(bool),
    deadline: ?std.Io.Clock.Timestamp,
) ![]u8 {
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer {
        @memset(payload.writer.buffer, 0);
        payload.deinit();
    }
    try std.json.Stringify.value(.{ .code = code, .code_verifier = verifier, .code_challenge_method = "S256" }, .{}, &payload.writer);
    var response = try transport.execute(alloc, .{ .method = .post_json, .url = url, .payload = payload.written(), .cancel_flag = cancel_flag, .deadline = deadline });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) {
        debug_trace.logf("auth", "OpenRouter key exchange rejected", .{});
        return error.OpenRouterKeyExchangeFailed;
    }
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, response.body, .{}) catch return error.OpenRouterKeyExchangeFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.OpenRouterKeyExchangeFailed;
    const key = parsed.value.object.get("key") orelse return error.OpenRouterKeyExchangeFailed;
    if (key != .string or !provider_keys.validKey(key.string)) return error.OpenRouterKeyExchangeFailed;
    return alloc.dupe(u8, key.string);
}

fn complete(_: ?*anyopaque, alloc: Allocator, _: []const u8, _: []const u8, token: *oauth.TokenSet) !login_flow.SignInCompletion {
    _ = alloc;
    const completion: login_flow.SignInCompletion = .{ .provider_key = .{
        .provider = .fromProvider(model_provider.parse(provider_id).?),
        .key = token.access_token,
    } };
    token.access_token = &.{};
    return completion;
}

fn save(_: ?*anyopaque, alloc: Allocator, completion: login_flow.SignInCompletion) !void {
    const value = switch (completion) {
        .provider_key => |value| value,
        else => return error.InvalidSignInCompletion,
    };
    try provider_keys.save(alloc, value.provider.label(), value.key);
}

fn finish(raw: ?*anyopaque, alloc: Allocator, saved: bool) void {
    const context: *Context = @ptrCast(@alignCast(raw.?));
    context.finishCallback(alloc, saved);
}

/// `fx login openrouter`: prints the URL, opens the browser, and accepts a
/// pasted key or code on standard input until the browser returns.
pub fn runLogin(alloc: Allocator, transport: oauth_transport.Provider, url_opener: host.UrlOpener) !void {
    var runtime: login_flow.SignInRuntime = .{};
    defer runtime.deinit(alloc);
    if (!try startSignIn(&runtime, alloc, transport)) return error.OpenRouterLoginBusy;
    const url = (try runtime.browserUrlAlloc(alloc)) orelse return error.OpenRouterAuthorizationUrlMissing;
    defer alloc.free(url);
    const stdout = std.Io.File.stdout();
    try stdout.writeStreamingAll(io_mod.getIo(), "Open this URL to authorize proto-fx with OpenRouter:\n");
    try stdout.writeStreamingAll(io_mod.getIo(), url);
    try stdout.writeStreamingAll(io_mod.getIo(), "\n\nWaiting for the browser. Or paste an existing sk-or- key, or the code from the redirect, and press enter.\n");
    if (io_mod.getenv("FX_NO_OPEN_BROWSER") == null) _ = url_opener.open(alloc, url) catch false;
    var line: LineReader = .{};
    defer line.clear();
    while (true) {
        if (try line.poll()) |text| {
            _ = try runtime.submitManualCode(alloc, text);
            line.clear();
        }
        switch (runtime.pollTransition(alloc)) {
            .none => try io_mod.getIo().sleep(.fromMilliseconds(50), .awake),
            .succeeded => |completion| {
                var owned = completion;
                owned.deinit(alloc);
                return;
            },
            .failed => |err| return err,
            .cancelled => return error.Cancelled,
        }
    }
}

/// One line from standard input without blocking, for the CLI flows.
pub const LineReader = struct {
    buffer: [login_flow.max_manual_code_bytes]u8 = undefined,
    len: usize = 0,
    closed: bool = false,

    pub fn poll(self: *LineReader) !?[]const u8 {
        if (self.closed) return null;
        var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, 0) == 0 or (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) == 0) return null;
        var chunk: [512]u8 = undefined;
        defer @memset(&chunk, 0);
        const read_len = try std.posix.read(std.posix.STDIN_FILENO, &chunk);
        if (read_len == 0) {
            self.closed = true;
            return if (self.len == 0) null else self.buffer[0..self.len];
        }
        const end = std.mem.findScalar(u8, chunk[0..read_len], '\n') orelse read_len;
        if (end > self.buffer.len - self.len) return error.InputTooLong;
        @memcpy(self.buffer[self.len..][0..end], chunk[0..end]);
        self.len += end;
        if (end < read_len) {
            self.closed = true;
            return self.buffer[0..self.len];
        }
        return null;
    }

    pub fn clear(self: *LineReader) void {
        @memset(self.buffer[0..self.len], 0);
        self.len = 0;
    }
};

test "OpenRouter authorization URL carries the S256 challenge and loopback callback" {
    const alloc = std.testing.allocator;
    const url = try authorizationUrl(alloc, authorize_url, "http://localhost:54549/callback", "abc-_");
    defer alloc.free(url);
    try std.testing.expectEqualStrings("https://openrouter.ai/auth?callback_url=http%3A%2F%2Flocalhost%3A54549%2Fcallback&code_challenge=abc-_&code_challenge_method=S256", url);
}

const ExchangeFixture = struct {
    body: []const u8,
    accepted: bool = true,
    seen: ?[]u8 = null,

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) anyerror!oauth_transport.Response {
        const self: *ExchangeFixture = @ptrCast(@alignCast(raw.?));
        self.seen = try std.testing.allocator.dupe(u8, request.payload.?);
        try std.testing.expectEqual(oauth_transport.Method.post_json, request.method);
        return .{ .disposition = if (self.accepted) .accepted else .rejected, .body = try alloc.dupe(u8, self.body) };
    }
};

test "OpenRouter code exchange posts the verifier and returns the minted key" {
    const alloc = std.testing.allocator;
    var fixture: ExchangeFixture = .{ .body = "{\"key\":\"sk-or-v1-minted\",\"user_id\":\"u\"}" };
    defer if (fixture.seen) |seen| std.testing.allocator.free(seen);
    const transport: oauth_transport.Provider = .{ .context = &fixture, .execute_fn = ExchangeFixture.execute };
    const key = try exchangeCode(alloc, transport, keys_url, "the-code", "the-verifier", null, null);
    defer alloc.free(key);
    try std.testing.expectEqualStrings("sk-or-v1-minted", key);
    try std.testing.expectEqualStrings("{\"code\":\"the-code\",\"code_verifier\":\"the-verifier\",\"code_challenge_method\":\"S256\"}", fixture.seen.?);
    for ([_][]const u8{ "{}", "{\"key\":\"\"}", "{\"key\":\"has space\"}", "nope" }) |body| {
        var bad: ExchangeFixture = .{ .body = body };
        defer if (bad.seen) |seen| std.testing.allocator.free(seen);
        try std.testing.expectError(error.OpenRouterKeyExchangeFailed, exchangeCode(alloc, .{ .context = &bad, .execute_fn = ExchangeFixture.execute }, keys_url, "c", "v", null, null));
    }
    var refused: ExchangeFixture = .{ .body = "{\"key\":\"sk-or-x\"}", .accepted = false };
    defer if (refused.seen) |seen| std.testing.allocator.free(seen);
    try std.testing.expectError(error.OpenRouterKeyExchangeFailed, exchangeCode(alloc, .{ .context = &refused, .execute_fn = ExchangeFixture.execute }, keys_url, "c", "v", null, null));
}

test "OpenRouter callback parsing takes the code and ignores other paths" {
    const alloc = std.testing.allocator;
    var accepted = parseCallback(null, alloc, "/callback?code=abc123");
    try std.testing.expect(accepted == .accepted);
    try std.testing.expectEqualStrings("abc123", accepted.accepted.code);
    accepted.accepted.deinit(alloc);
    try std.testing.expect(parseCallback(null, alloc, "/favicon.ico") == .unrelated);
    try std.testing.expect(parseCallback(null, alloc, "/callback?error=denied") == .failed);
}
