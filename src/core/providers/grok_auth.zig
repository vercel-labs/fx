const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("../hosts/host.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const oauth = @import("../auth/oauth.zig");
const oauth_transport = @import("../auth/oauth_transport.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");
const session_store = @import("session_store.zig");

const Allocator = std.mem.Allocator;

/// OIDC issuer for Grok Build / SuperGrok device-code. Login pages live on
/// accounts.x.ai; discovery and the device-code endpoints are on auth.x.ai.
pub const issuer = "https://auth.x.ai";
pub const client_id = "b1a00492-073a-47ea-816f-4c329264a828";
pub const default_scope = "openid profile email offline_access grok-cli:access api:access";
pub const default_api_base_url = "https://api.x.ai/v1";
pub const default_chat_url = "https://api.x.ai/v1/chat/completions";
pub const default_models_url = "https://api.x.ai/v1/models";
pub const e2e_issuer_url_env = "FX_E2E_GROK_ISSUER_URL";
pub const e2e_chat_url_env = "FX_E2E_GROK_CHAT_URL";
pub const e2e_models_url_env = "FX_E2E_GROK_MODELS_URL";
pub const no_open_browser_env = "FX_NO_OPEN_BROWSER";
pub const missing_session_message =
    "Fx needs a Grok subscription login. Run fx login grok.";
pub const missing_interactive_session_message =
    "Fx needs a Grok subscription login. Run /login grok.";

const poll_request_timeout_ms: i64 = 15_000;
const poll_wait_slice_ms: u64 = 100;
const max_document_bytes: usize = 256 * 1024;
const max_poll_interval_ms = std.math.maxInt(u64) / std.time.ns_per_ms;

pub const Session = session_store.Session;

pub fn configuredIssuerUrl() ![]const u8 {
    return selectIssuerUrl(io_mod.getenv(e2e_issuer_url_env));
}

pub fn configuredChatUrl() []const u8 {
    if (trimmedEnv(e2e_chat_url_env)) |value| {
        if (isLoopbackHttpUrl(value, false)) return value;
    }
    return default_chat_url;
}

pub fn configuredModelsUrl() []const u8 {
    if (trimmedEnv(e2e_models_url_env)) |value| {
        if (isLoopbackHttpUrl(value, false)) return value;
    }
    return default_models_url;
}

pub fn isLoopbackE2EIssuer(url: []const u8) bool {
    return !std.mem.eql(u8, url, issuer) and isLoopbackHttpUrl(url, true);
}

pub fn load(alloc: Allocator) !?Session {
    return session_store.load(alloc, profile_paths.grok_dir_name);
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
            debug_trace.logf("grok", "session refresh failed err={s}", .{@errorName(err)});
            session.deinit(alloc);
            return null;
        },
    };
    return session;
}

pub fn refreshSession(alloc: Allocator, session: *Session) !void {
    const issuer_url = session.issuer;
    var metadata = try oauth.discover(alloc, http_transport, issuer_url);
    defer metadata.deinit(alloc);
    try validateE2EEndpoint(issuer_url, metadata.token_endpoint);

    var token = try oauth.refreshToken(
        alloc,
        http_transport,
        metadata,
        session.client_id,
        session.refresh_token,
    );
    defer token.deinit(alloc);
    const expires_at_ms = try oauth.expiry_timestamp_ms(io_mod.milliTimestamp(), token.expires_in);

    secret.zeroAndFree(alloc, session.access_token);
    session.access_token = token.access_token;
    token.access_token = &.{};
    if (token.refresh_token) |value| {
        secret.zeroAndFree(alloc, session.refresh_token);
        session.refresh_token = value;
        token.refresh_token = null;
    }
    session.expires_at_ms = expires_at_ms;
    alloc.free(session.scope);
    session.scope = token.scope;
    token.scope = &.{};
    alloc.free(session.token_type);
    session.token_type = token.token_type;
    token.token_type = &.{};

    try session_store.saveNewSession(alloc, profile_paths.grok_dir_name, session.*);
}

pub const LogoutResult = struct {
    session_deleted: bool = false,
    local_durability_failed: bool = false,
};

pub fn logout(alloc: Allocator) !LogoutResult {
    _ = alloc;
    var mutation = (session_store.beginExistingMutation(profile_paths.grok_dir_name) catch {
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
    transport: oauth_transport.Provider = http_transport,
    url_opener: host.UrlOpener,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    write_stdout: *const fn ([]const u8) anyerror!void = writeStdout,
};

pub fn runLogin(alloc: Allocator, options: LoginOptions) !void {
    if (comptime host_target.is_wasm or builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.InteractiveAuthorizationUnsupported;
    }
    var prepared = try prepareLogin(alloc, options.transport);
    defer prepared.deinit(alloc);

    const display_url = prepared.device.verification_uri_complete orelse prepared.device.verification_uri;
    try options.write_stdout("Open ");
    try options.write_stdout(display_url);
    try options.write_stdout("\nCode: ");
    try options.write_stdout(prepared.device.user_code);
    try options.write_stdout("\nWaiting for Grok authorization...\n");

    if (io_mod.getenv(no_open_browser_env) == null) {
        _ = options.url_opener.open(alloc, display_url) catch false;
    }

    var token = try pollForToken(
        alloc,
        options.transport,
        prepared.metadata,
        prepared.client_id,
        prepared.device,
        options.cancel_flag,
    );
    defer token.deinit(alloc);
    const refresh_token = token.refresh_token orelse return error.NoRefreshToken;
    token.refresh_token = null;
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const expires_at_ms = try oauth.expiry_timestamp_ms(io_mod.milliTimestamp(), token.expires_in);

    var session = Session{
        .issuer = try alloc.dupe(u8, prepared.issuer),
        .client_id = try alloc.dupe(u8, prepared.client_id),
        .access_token = token.access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .scope = token.scope,
        .token_type = token.token_type,
    };
    token.access_token = &.{};
    token.scope = &.{};
    token.token_type = &.{};
    defer session.deinit(alloc);
    try session_store.saveNewSession(alloc, profile_paths.grok_dir_name, session);
    try options.write_stdout("Signed in to Grok.\n");
}

const PreparedLogin = struct {
    metadata: oauth.Metadata,
    device: oauth.DeviceAuthorization,
    issuer: []const u8,
    client_id: []u8,

    fn deinit(self: *PreparedLogin, alloc: Allocator) void {
        self.metadata.deinit(alloc);
        self.device.deinit(alloc);
        alloc.free(self.client_id);
        self.* = undefined;
    }
};

fn prepareLogin(alloc: Allocator, transport: oauth_transport.Provider) !PreparedLogin {
    const issuer_url = try configuredIssuerUrl();
    var metadata = try oauth.discover(alloc, transport, issuer_url);
    errdefer metadata.deinit(alloc);
    try validateE2EEndpoint(issuer_url, metadata.device_authorization_endpoint);
    try validateE2EEndpoint(issuer_url, metadata.token_endpoint);

    var device = try oauth.requestDeviceAuthorizationWithScope(
        alloc,
        transport,
        metadata,
        client_id,
        default_scope,
    );
    errdefer device.deinit(alloc);
    return .{
        .metadata = metadata,
        .device = device,
        .issuer = issuer_url,
        .client_id = try alloc.dupe(u8, client_id),
    };
}

fn pollForToken(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: oauth.Metadata,
    owned_client_id: []const u8,
    device: oauth.DeviceAuthorization,
    cancel_flag: ?*std.atomic.Value(bool),
) !oauth.TokenSet {
    var interval_ms = try pollIntervalMs(device.interval);
    const expires_at_ms = try oauth.expiry_timestamp_ms(io_mod.milliTimestamp(), device.expires_in);
    var local_cancel = std.atomic.Value(bool).init(false);
    const cancel = cancel_flag orelse &local_cancel;

    while (true) {
        if (cancel.load(.seq_cst)) return error.Cancelled;
        if (io_mod.milliTimestamp() >= expires_at_ms) return error.LoginTimedOut;

        const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(poll_request_timeout_ms),
        });
        switch (try oauth.pollDeviceTokenBounded(
            alloc,
            transport,
            metadata,
            owned_client_id,
            device.device_code,
            cancel,
            deadline,
        )) {
            .success => |token| {
                if (cancel.load(.seq_cst)) {
                    var owned = token;
                    owned.deinit(alloc);
                    return error.Cancelled;
                }
                return token;
            },
            .pending => {},
            .slow_down => {
                interval_ms = std.math.add(u64, interval_ms, 5 * std.time.ms_per_s) catch
                    return oauth.OAuthError.InvalidOAuthResponse;
                if (interval_ms > max_poll_interval_ms) return oauth.OAuthError.InvalidOAuthResponse;
            },
        }
        try sleepCancellable(interval_ms, cancel);
    }
}

fn sleepCancellable(interval_ms: u64, cancel: *std.atomic.Value(bool)) !void {
    var remaining_ms = interval_ms;
    while (remaining_ms > 0) {
        if (cancel.load(.seq_cst)) return error.Cancelled;
        const slice_ms: u64 = @min(remaining_ms, poll_wait_slice_ms);
        io_mod.sleep(slice_ms *| @as(u64, 1_000_000));
        remaining_ms -= slice_ms;
    }
    if (cancel.load(.seq_cst)) return error.Cancelled;
}

fn pollIntervalMs(interval_seconds: i64) oauth.OAuthError!u64 {
    const seconds = @max(interval_seconds, 1);
    const signed_interval_ms = std.math.mul(i64, seconds, std.time.ms_per_s) catch
        return oauth.OAuthError.InvalidOAuthResponse;
    const interval_ms = std.math.cast(u64, signed_interval_ms) orelse
        return oauth.OAuthError.InvalidOAuthResponse;
    if (interval_ms > max_poll_interval_ms) return oauth.OAuthError.InvalidOAuthResponse;
    return interval_ms;
}

fn validateE2EEndpoint(issuer_url: []const u8, endpoint: []const u8) !void {
    if (isLoopbackE2EIssuer(issuer_url) and !isLoopbackHttpUrl(endpoint, false)) {
        return error.InvalidE2EOAuthEndpoint;
    }
}

fn executeHttp(
    _: ?*anyopaque,
    alloc: Allocator,
    request: oauth_transport.Request,
) !oauth_transport.Response {
    const uri = std.Uri.parse(request.url) catch return error.InvalidGrokAuthEndpoint;
    if (!isSecureOrLoopback(uri) or uri.user != null or uri.password != null or uri.fragment != null) {
        return error.InsecureGrokAuthEndpoint;
    }
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    const response_buffer = try alloc.alloc(u8, max_document_bytes + 1);
    defer secret.zeroAndFree(alloc, response_buffer);
    var response_writer = std.Io.Writer.fixed(response_buffer);

    const result = client.fetch(.{
        .location = .{ .url = request.url },
        .method = switch (request.method) {
            .get => .GET,
            .post_form => .POST,
        },
        .payload = request.payload,
        .headers = .{
            .content_type = if (request.method == .post_form)
                .{ .override = "application/x-www-form-urlencoded" }
            else
                .default,
            .accept_encoding = .omit,
        },
        .response_writer = &response_writer,
        .redirect_behavior = .unhandled,
    }) catch |err| switch (err) {
        error.WriteFailed => return error.GrokAuthDocumentTooLarge,
        else => return err,
    };
    const body = response_writer.buffered();
    if (body.len > max_document_bytes) return error.GrokAuthDocumentTooLarge;
    return .{
        .disposition = if (result.status == .ok) .accepted else .rejected,
        .body = try alloc.dupe(u8, body),
    };
}

const http_transport = oauth_transport.Provider{
    .execute_fn = executeHttp,
};

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

test "grok issuer override accepts loopback only" {
    try std.testing.expectEqualStrings(issuer, try selectIssuerUrl(null));
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:43123",
        try selectIssuerUrl("http://127.0.0.1:43123/"),
    );
    try std.testing.expectError(error.InvalidE2EOAuthIssuer, selectIssuerUrl("https://auth.x.ai"));
    try std.testing.expectError(error.InvalidE2EOAuthIssuer, selectIssuerUrl("http://example.test"));
    try std.testing.expectError(error.InvalidE2EOAuthIssuer, selectIssuerUrl("https://accounts.x.ai"));
}

test "grok e2e endpoint validation stays on the loopback issuer" {
    try validateE2EEndpoint("https://auth.x.ai", "https://auth.x.ai/oauth2/token");
    try validateE2EEndpoint("http://127.0.0.1:9", "http://127.0.0.1:9/oauth2/token");
    try std.testing.expectError(
        error.InvalidE2EOAuthEndpoint,
        validateE2EEndpoint("http://127.0.0.1:9", "https://auth.x.ai/oauth2/token"),
    );
}
