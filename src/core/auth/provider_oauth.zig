const std = @import("std");
const builtin = @import("builtin");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const oauth = @import("oauth.zig");
const oauth_session = @import("oauth_session.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;
const callback_timeout_ms: i32 = 5 * 60 * 1000;
const callback_poll_ms: i32 = 50;
const refresh_skew_ms: i64 = 5 * std.time.ms_per_min;
const max_poll_interval_seconds: i64 = 5 * 60;

pub const Provider = enum {
    anthropic,
    openai_codex,
    xai,

    pub fn parse(value: []const u8) ?Provider {
        if (std.ascii.eqlIgnoreCase(value, "anthropic") or std.ascii.eqlIgnoreCase(value, "anthropic-max")) return .anthropic;
        if (std.ascii.eqlIgnoreCase(value, "openai-codex") or std.ascii.eqlIgnoreCase(value, "codex")) return .openai_codex;
        if (std.ascii.eqlIgnoreCase(value, "xai") or std.ascii.eqlIgnoreCase(value, "xai-direct")) return .xai;
        return null;
    }

    pub fn label(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "Anthropic Claude Pro/Max",
            .openai_codex => "OpenAI Codex/ChatGPT",
            .xai => "xAI Grok/X",
        };
    }

    pub fn fileName(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "auth-anthropic.json",
            .openai_codex => "auth-openai-codex.json",
            .xai => "auth-xai.json",
        };
    }

    pub fn credentialSource(self: Provider) types.CredentialSource {
        return switch (self) {
            .anthropic => .anthropic_fx_login,
            .openai_codex => .codex_fx_login,
            .xai => .xai_oauth_token,
        };
    }

    pub fn fromCredentialSource(source: types.CredentialSource) ?Provider {
        return switch (source) {
            .anthropic_fx_login => .anthropic,
            .codex_fx_login => .openai_codex,
            .xai_oauth_token => .xai,
            else => null,
        };
    }

    fn validateAccessToken(self: Provider, alloc: Allocator, token: []const u8) !void {
        switch (self) {
            .anthropic => if (!std.mem.startsWith(u8, token, "sk-ant-oat")) return error.InvalidOAuthResponse,
            .openai_codex => if (!try codexTokenHasAccountId(alloc, token)) return error.InvalidOAuthResponse,
            .xai => {},
        }
    }

    fn clientId(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            .openai_codex => "app_EMoamEEZ73f0CkXaXp7hrann",
            .xai => "b1a00492-073a-47ea-816f-4c329264a828",
        };
    }

    fn tokenUrl(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "https://platform.claude.com/v1/oauth/token",
            .openai_codex => "https://auth.openai.com/oauth/token",
            .xai => "https://auth.x.ai/oauth2/token",
        };
    }

    fn scope(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload",
            .openai_codex => "openid profile email offline_access",
            .xai => "openid profile email offline_access grok-cli:access api:access",
        };
    }
};

pub const LoginMethod = enum { browser, device_code, manual_code };

pub fn runLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
    provider: Provider,
    method: LoginMethod,
) !void {
    var session = switch (provider) {
        .anthropic => if (method != .device_code)
            try loginBrowser(alloc, transport, url_opener, provider, method)
        else
            return error.ProviderLoginMethodUnsupported,
        .openai_codex => if (method == .device_code)
            try loginCodexDevice(alloc, transport, url_opener)
        else
            try loginBrowser(alloc, transport, url_opener, provider, method),
        .xai => if (method != .manual_code)
            try loginXaiDevice(alloc, transport, url_opener)
        else
            return error.ProviderLoginMethodUnsupported,
    };
    defer session.deinit(alloc);
    try oauth_session.saveNamed(alloc, provider.fileName(), @tagName(provider), session);
    try writeStdoutFmt("Signed in to {s}.\n", .{provider.label()});
}

fn loginCodexDevice(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !oauth_session.Session {
    const provider = Provider.openai_codex;
    var request_body = std.Io.Writer.Allocating.init(alloc);
    defer deinitSecretWriter(&request_body);
    try request_body.writer.writeAll("{\"client_id\":");
    try std.json.Stringify.value(provider.clientId(), .{}, &request_body.writer);
    try request_body.writer.writeByte('}');
    const bytes = try fetchAccepted(
        alloc,
        transport,
        .post_json,
        "https://auth.openai.com/api/accounts/deviceauth/usercode",
        request_body.writer.buffered(),
    );
    defer secret.zeroAndFree(alloc, bytes);
    var device = try parseCodexDeviceAuthorization(alloc, bytes);
    defer device.deinit(alloc);
    const verification_uri = "https://auth.openai.com/codex/device";
    try writeStdoutFmt("Open {s}\nCode: {s}\n\n", .{ verification_uri, device.user_code });
    _ = try url_opener.open(alloc, verification_uri);

    var interval = device.interval;
    const deadline = io_mod.milliTimestamp() +| 15 * std.time.ms_per_min;
    while (io_mod.milliTimestamp() < deadline) {
        try sleepPollInterval(interval);
        var poll_body = std.Io.Writer.Allocating.init(alloc);
        defer deinitSecretWriter(&poll_body);
        try poll_body.writer.writeAll("{\"device_auth_id\":");
        try std.json.Stringify.value(device.device_auth_id, .{}, &poll_body.writer);
        try poll_body.writer.writeAll(",\"user_code\":");
        try std.json.Stringify.value(device.user_code, .{}, &poll_body.writer);
        try poll_body.writer.writeByte('}');
        var response = try transport.execute(alloc, .{
            .method = .post_json,
            .url = "https://auth.openai.com/api/accounts/deviceauth/token",
            .payload = poll_body.writer.buffered(),
        });
        defer response.deinit(alloc);
        if (response.disposition == .accepted) {
            var code = try parseCodexDeviceToken(alloc, response.body);
            defer code.deinit(alloc);
            return exchangeCodexAuthorizationCode(
                alloc,
                transport,
                code.authorization_code,
                code.code_verifier,
                "https://auth.openai.com/deviceauth/callback",
            );
        }
        if (response.status == 403 or response.status == 404) continue;
        const oauth_error = parseError(alloc, response.body) orelse return error.OAuthRequestFailed;
        if (oauth_error == .authorization_pending) continue;
        if (oauth_error == .slow_down) {
            interval +|= 5;
            continue;
        }
        if (oauth_error == .access_denied) return error.AccessDenied;
        if (oauth_error == .expired_token) return error.ExpiredToken;
    }
    return error.LoginTimedOut;
}

pub fn logout(provider: Provider) !oauth_session.DeleteOutcome {
    return oauth_session.deleteNamed(provider.fileName(), @tagName(provider));
}

pub fn loadManagedSession(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    provider: Provider,
    refresh_if_needed: bool,
) !?oauth_session.Session {
    var session = (try oauth_session.loadNamed(alloc, provider.fileName(), @tagName(provider))) orelse return null;
    if (refresh_if_needed and session.expired(io_mod.milliTimestamp())) {
        session.deinit(alloc);
        return refreshManagedSession(alloc, transport, provider, false);
    }
    errdefer session.deinit(alloc);
    return session;
}

pub fn refreshManagedSession(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    provider: Provider,
    force: bool,
) !?oauth_session.Session {
    var mutation = (try oauth_session.beginNamedMutation(provider.fileName(), @tagName(provider))) orelse return null;
    defer mutation.deinit();
    var session = (try mutation.load(alloc)) orelse return null;
    errdefer session.deinit(alloc);
    if (!force and !session.expired(io_mod.milliTimestamp())) return session;

    var body = std.Io.Writer.Allocating.init(alloc);
    defer deinitSecretWriter(&body);
    if (provider == .anthropic) {
        try body.writer.writeAll("{\"grant_type\":\"refresh_token\",\"client_id\":");
        try std.json.Stringify.value(provider.clientId(), .{}, &body.writer);
        try body.writer.writeAll(",\"refresh_token\":");
        try std.json.Stringify.value(session.refresh_token, .{}, &body.writer);
        try body.writer.writeByte('}');
    } else {
        var form: FormBody = .{};
        try form.append(&body.writer, "grant_type", "refresh_token");
        try form.append(&body.writer, "client_id", provider.clientId());
        try form.append(&body.writer, "refresh_token", session.refresh_token);
    }
    const bytes = try fetchAccepted(
        alloc,
        transport,
        if (provider == .anthropic) .post_json else .post_form,
        provider.tokenUrl(),
        body.writer.buffered(),
    );
    defer secret.zeroAndFree(alloc, bytes);
    var token = try parseToken(
        alloc,
        bytes,
        if (provider == .xai) session.refresh_token else null,
        true,
        provider == .xai,
    );
    defer token.deinit(alloc);
    try provider.validateAccessToken(alloc, token.access_token);
    try replaceSessionTokens(alloc, &session, &token);
    try mutation.save(alloc, session);
    return session;
}

fn loginBrowser(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
    provider: Provider,
    method: LoginMethod,
) !oauth_session.Session {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.ProviderOAuthUnsupported;
    const port: u16 = if (provider == .anthropic) 53692 else 1455;
    const callback_path = if (provider == .anthropic) "/callback" else "/auth/callback";
    const redirect_uri = if (provider == .anthropic)
        "http://localhost:53692/callback"
    else
        "http://localhost:1455/auth/callback";
    const authorize_url = if (provider == .anthropic)
        "https://claude.ai/oauth/authorize"
    else
        "https://auth.openai.com/oauth/authorize";

    var listener: ?std.Io.net.Server = null;
    if (method == .browser) {
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        listener = try address.listen(io_mod.getIo(), .{ .reuse_address = true });
    }
    defer if (listener) |*server| server.deinit(io_mod.getIo());

    var verifier_entropy: [32]u8 = undefined;
    try io_mod.getIo().randomSecure(&verifier_entropy);
    var verifier_buf: [43]u8 = undefined;
    const verifier = std.base64.url_safe_no_pad.Encoder.encode(&verifier_buf, &verifier_entropy);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var challenge_buf: [43]u8 = undefined;
    const challenge = std.base64.url_safe_no_pad.Encoder.encode(&challenge_buf, &digest);
    var state_entropy: [16]u8 = undefined;
    try io_mod.getIo().randomSecure(&state_entropy);
    var state_buf: [22]u8 = undefined;
    const generated_state = std.base64.url_safe_no_pad.Encoder.encode(&state_buf, &state_entropy);
    const stable_state = if (provider == .anthropic) verifier else generated_state;

    var url = std.Io.Writer.Allocating.init(alloc);
    defer deinitSecretWriter(&url);
    try url.writer.print("{s}?", .{authorize_url});
    var query: FormBody = .{};
    if (provider == .anthropic) try query.append(&url.writer, "code", "true");
    try query.append(&url.writer, "response_type", "code");
    try query.append(&url.writer, "client_id", provider.clientId());
    try query.append(&url.writer, "redirect_uri", redirect_uri);
    try query.append(&url.writer, "scope", provider.scope());
    try query.append(&url.writer, "code_challenge", challenge);
    try query.append(&url.writer, "code_challenge_method", "S256");
    try query.append(&url.writer, "state", stable_state);
    if (provider == .openai_codex) {
        try query.append(&url.writer, "id_token_add_organizations", "true");
        try query.append(&url.writer, "codex_cli_simplified_flow", "true");
        try query.append(&url.writer, "originator", "fx");
    }
    const authorization_url = url.writer.buffered();
    try writeStdoutFmt("Open this URL to sign in to {s}:\n{s}\n\n", .{ provider.label(), authorization_url });
    _ = try url_opener.open(alloc, authorization_url);

    var callback = if (listener) |*server|
        try waitForCallback(alloc, server, callback_path, stable_state)
    else
        try readManualCallback(alloc, stable_state);
    defer callback.deinit(alloc);
    if (!std.mem.eql(u8, callback.state, stable_state)) return error.OAuthStateMismatch;

    var body = std.Io.Writer.Allocating.init(alloc);
    defer deinitSecretWriter(&body);
    const token_method: oauth_transport.Method = if (provider == .anthropic) .post_json else .post_form;
    if (provider == .anthropic) {
        try body.writer.writeAll("{\"grant_type\":\"authorization_code\",\"client_id\":");
        try std.json.Stringify.value(provider.clientId(), .{}, &body.writer);
        try body.writer.writeAll(",\"code\":");
        try std.json.Stringify.value(callback.code, .{}, &body.writer);
        try body.writer.writeAll(",\"state\":");
        try std.json.Stringify.value(stable_state, .{}, &body.writer);
        try body.writer.writeAll(",\"redirect_uri\":");
        try std.json.Stringify.value(redirect_uri, .{}, &body.writer);
        try body.writer.writeAll(",\"code_verifier\":");
        try std.json.Stringify.value(verifier, .{}, &body.writer);
        try body.writer.writeByte('}');
    } else {
        var form: FormBody = .{};
        try form.append(&body.writer, "grant_type", "authorization_code");
        try form.append(&body.writer, "client_id", provider.clientId());
        try form.append(&body.writer, "code", callback.code);
        try form.append(&body.writer, "code_verifier", verifier);
        try form.append(&body.writer, "redirect_uri", redirect_uri);
    }
    const bytes = try fetchAccepted(alloc, transport, token_method, provider.tokenUrl(), body.writer.buffered());
    defer secret.zeroAndFree(alloc, bytes);
    var token = try parseToken(alloc, bytes, null, true, false);
    defer token.deinit(alloc);
    return takeSession(alloc, provider, &token);
}

fn readManualCallback(alloc: Allocator, expected_state: []const u8) !Callback {
    try writeStdoutFmt("Paste the authorization code or final redirect URL, then press Enter:\n", .{});
    var read_buffer: [16 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io_mod.getIo(), &read_buffer);
    const line = try reader.interface.takeDelimiter('\n') orelse return error.EndOfStream;
    const input = std.mem.trim(u8, line, " \t\r\n");
    return parseManualCallback(alloc, input, expected_state);
}

fn parseManualCallback(alloc: Allocator, input: []const u8, expected_state: []const u8) !Callback {
    if (input.len == 0) return error.InvalidAuthorizationCallback;

    var code_raw: []const u8 = input;
    var state_raw: ?[]const u8 = null;
    if (std.mem.findScalar(u8, input, '?')) |query_start| {
        const fragment_start = std.mem.findScalarPos(u8, input, query_start + 1, '#') orelse input.len;
        const query = input[query_start + 1 .. fragment_start];
        code_raw = queryValue(query, "code") orelse return error.InvalidAuthorizationCallback;
        state_raw = queryValue(query, "state");
    } else if (std.mem.findScalar(u8, input, '#')) |separator| {
        code_raw = input[0..separator];
        state_raw = input[separator + 1 ..];
    } else if (std.mem.startsWith(u8, input, "code=")) {
        code_raw = queryValue(input, "code") orelse return error.InvalidAuthorizationCallback;
        state_raw = queryValue(input, "state");
    }
    const state = if (state_raw) |value| try percentDecode(alloc, value) else try alloc.dupe(u8, expected_state);
    errdefer secret.zeroAndFree(alloc, state);
    if (!std.mem.eql(u8, state, expected_state)) return error.OAuthStateMismatch;
    return .{ .code = try percentDecode(alloc, code_raw), .state = state };
}

const CodexDeviceAuthorization = struct {
    device_auth_id: []u8,
    user_code: []u8,
    interval: i64,

    fn deinit(self: *CodexDeviceAuthorization, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.device_auth_id);
        alloc.free(self.user_code);
        self.* = undefined;
    }
};

fn parseCodexDeviceAuthorization(alloc: Allocator, bytes: []const u8) !CodexDeviceAuthorization {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOAuthResponse;
    const object = parsed.value.object;
    const device_auth_id = try requiredStringDupe(alloc, object, "device_auth_id");
    errdefer secret.zeroAndFree(alloc, device_auth_id);
    const user_code = try requiredStringDupe(alloc, object, "user_code");
    errdefer alloc.free(user_code);
    const interval = if (object.get("interval")) |value| switch (value) {
        .integer => |number| number,
        .string => |text| std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch return error.InvalidOAuthResponse,
        else => return error.InvalidOAuthResponse,
    } else return error.InvalidOAuthResponse;
    if (interval < 0 or interval > max_poll_interval_seconds) return error.InvalidOAuthResponse;
    return .{ .device_auth_id = device_auth_id, .user_code = user_code, .interval = @max(interval, 1) };
}

const CodexDeviceToken = struct {
    authorization_code: []u8,
    code_verifier: []u8,

    fn deinit(self: *CodexDeviceToken, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.authorization_code);
        secret.zeroAndFree(alloc, self.code_verifier);
        self.* = undefined;
    }
};

fn parseCodexDeviceToken(alloc: Allocator, bytes: []const u8) !CodexDeviceToken {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOAuthResponse;
    const authorization_code = try requiredStringDupe(alloc, parsed.value.object, "authorization_code");
    errdefer secret.zeroAndFree(alloc, authorization_code);
    return .{
        .authorization_code = authorization_code,
        .code_verifier = try requiredStringDupe(alloc, parsed.value.object, "code_verifier"),
    };
}

fn exchangeCodexAuthorizationCode(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    code: []const u8,
    verifier: []const u8,
    redirect_uri: []const u8,
) !oauth_session.Session {
    var body = std.Io.Writer.Allocating.init(alloc);
    defer deinitSecretWriter(&body);
    var form: FormBody = .{};
    try form.append(&body.writer, "grant_type", "authorization_code");
    try form.append(&body.writer, "client_id", Provider.openai_codex.clientId());
    try form.append(&body.writer, "code", code);
    try form.append(&body.writer, "code_verifier", verifier);
    try form.append(&body.writer, "redirect_uri", redirect_uri);
    const bytes = try fetchAccepted(
        alloc,
        transport,
        .post_form,
        Provider.openai_codex.tokenUrl(),
        body.writer.buffered(),
    );
    defer secret.zeroAndFree(alloc, bytes);
    var token = try parseToken(alloc, bytes, null, true, false);
    defer token.deinit(alloc);
    return takeSession(alloc, .openai_codex, &token);
}

fn loginXaiDevice(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !oauth_session.Session {
    const provider = Provider.xai;
    var request_body = std.Io.Writer.Allocating.init(alloc);
    defer deinitSecretWriter(&request_body);
    var form: FormBody = .{};
    try form.append(&request_body.writer, "client_id", provider.clientId());
    try form.append(&request_body.writer, "scope", provider.scope());
    try form.append(&request_body.writer, "referrer", "pi");
    const bytes = try fetchAccepted(
        alloc,
        transport,
        .post_form,
        "https://auth.x.ai/oauth2/device/code",
        request_body.writer.buffered(),
    );
    defer secret.zeroAndFree(alloc, bytes);
    var device = try parseXaiDeviceAuthorization(alloc, bytes);
    defer device.deinit(alloc);
    const display_url = device.verification_uri_complete orelse device.verification_uri;
    try writeStdoutFmt("Open {s}\nCode: {s}\n\n", .{ display_url, device.user_code });
    _ = try url_opener.open(alloc, display_url);

    var interval: i64 = @max(device.interval, 1);
    const deadline = io_mod.milliTimestamp() +| device.expires_in *| std.time.ms_per_s;
    while (io_mod.milliTimestamp() < deadline) {
        try sleepPollInterval(interval);
        var poll_body = std.Io.Writer.Allocating.init(alloc);
        defer deinitSecretWriter(&poll_body);
        var poll_form: FormBody = .{};
        try poll_form.append(&poll_body.writer, "grant_type", "urn:ietf:params:oauth:grant-type:device_code");
        try poll_form.append(&poll_body.writer, "client_id", provider.clientId());
        try poll_form.append(&poll_body.writer, "device_code", device.device_code);
        var response = try transport.execute(alloc, .{
            .method = .post_form,
            .url = provider.tokenUrl(),
            .payload = poll_body.writer.buffered(),
        });
        defer response.deinit(alloc);
        if (response.disposition == .accepted) {
            var token = try parseToken(alloc, response.body, null, true, true);
            defer token.deinit(alloc);
            return takeSession(alloc, provider, &token);
        }
        const oauth_error = parseError(alloc, response.body) orelse return error.OAuthRequestFailed;
        if (oauth_error == .authorization_pending) continue;
        if (oauth_error == .slow_down) {
            interval = parsePollInterval(alloc, response.body) orelse @min(interval +| 5, max_poll_interval_seconds);
            continue;
        }
        if (oauth_error == .access_denied) return error.AccessDenied;
        if (oauth_error == .expired_token) return error.ExpiredToken;
        return error.OAuthRequestFailed;
    }
    return error.LoginTimedOut;
}

const Callback = struct {
    code: []u8,
    state: []u8,

    fn deinit(self: *Callback, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.code);
        secret.zeroAndFree(alloc, self.state);
        self.* = undefined;
    }
};

fn waitForCallback(
    alloc: Allocator,
    listener: *std.Io.net.Server,
    callback_path: []const u8,
    expected_state: []const u8,
) !Callback {
    var remaining = callback_timeout_ms;
    while (remaining > 0) {
        var fds = [_]std.posix.pollfd{.{
            .fd = listener.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const wait_ms = @min(remaining, callback_poll_ms);
        const ready = try std.posix.poll(&fds, wait_ms);
        remaining -= wait_ms;
        if (ready == 0) continue;

        var stream = try listener.accept(io_mod.getIo());
        defer stream.close(io_mod.getIo());
        setSocketTimeouts(stream.socket.handle, 5);
        var socket_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io_mod.getIo(), &socket_buffer);
        var request_bytes: [16 * 1024]u8 = undefined;
        var request_len: usize = 0;
        while (request_len < request_bytes.len) {
            request_bytes[request_len] = reader.interface.takeByte() catch break;
            request_len += 1;
            if (std.mem.endsWith(u8, request_bytes[0..request_len], "\r\n\r\n")) break;
        }
        var callback = parseCallbackRequest(alloc, request_bytes[0..request_len], callback_path) catch |err| {
            writeCallbackResponse(&stream, .bad_request) catch {};
            if (err == error.AccessDenied) return err;
            continue;
        };
        if (!std.mem.eql(u8, callback.state, expected_state)) {
            callback.deinit(alloc);
            writeCallbackResponse(&stream, .bad_request) catch {};
            continue;
        }
        try writeCallbackResponse(&stream, .ok);
        return callback;
    }
    return error.LoginTimedOut;
}

fn parseCallbackRequest(alloc: Allocator, request_bytes: []const u8, callback_path: []const u8) !Callback {
    if (request_bytes.len == 16 * 1024) return error.AuthorizationCallbackTooLarge;
    const line_end = std.mem.find(u8, request_bytes, "\r\n") orelse return error.InvalidAuthorizationCallback;
    const line = request_bytes[0..line_end];
    if (!std.mem.startsWith(u8, line, "GET ")) return error.InvalidAuthorizationCallback;
    const target_end = std.mem.findScalarPos(u8, line, 4, ' ') orelse return error.InvalidAuthorizationCallback;
    const target = line[4..target_end];
    if (!std.mem.startsWith(u8, target, callback_path) or target.len <= callback_path.len or target[callback_path.len] != '?') {
        return error.InvalidAuthorizationCallback;
    }
    const query = target[callback_path.len + 1 ..];
    if (queryValue(query, "error") != null) return error.AccessDenied;
    const code_raw = queryValue(query, "code") orelse return error.InvalidAuthorizationCallback;
    const state_raw = queryValue(query, "state") orelse return error.InvalidAuthorizationCallback;
    const code = try percentDecode(alloc, code_raw);
    errdefer secret.zeroAndFree(alloc, code);
    return .{ .code = code, .state = try percentDecode(alloc, state_raw) };
}

const CallbackResponse = enum { ok, bad_request };

fn writeCallbackResponse(stream: *std.Io.net.Stream, response: CallbackResponse) !void {
    const body = switch (response) {
        .ok => "Authorization received. You can return to fx now.",
        .bad_request => "Invalid authorization callback. Return to fx and try again.",
    };
    var writer_buffer: [512]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &writer_buffer);
    try writer.interface.print(
        "HTTP/1.1 {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ if (response == .ok) "200 OK" else "400 Bad Request", body.len, body },
    );
    try writer.interface.flush();
}

fn queryValue(query: []const u8, key: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, query, '&');
    while (fields.next()) |field| {
        const separator = std.mem.findScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..separator], key)) return field[separator + 1 ..];
    }
    return null;
}

fn percentDecode(alloc: Allocator, value: []const u8) ![]u8 {
    const result = try alloc.alloc(u8, value.len);
    errdefer alloc.free(result);
    var input: usize = 0;
    var output: usize = 0;
    while (input < value.len) {
        if (value[input] == '%' and input + 2 < value.len) {
            const high = std.fmt.charToDigit(value[input + 1], 16) catch return error.InvalidAuthorizationCallback;
            const low = std.fmt.charToDigit(value[input + 2], 16) catch return error.InvalidAuthorizationCallback;
            result[output] = (high << 4) | low;
            input += 3;
        } else {
            result[output] = if (value[input] == '+') ' ' else value[input];
            input += 1;
        }
        output += 1;
    }
    return alloc.realloc(result, output);
}

fn parseXaiDeviceAuthorization(alloc: Allocator, bytes: []const u8) !oauth.DeviceAuthorization {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOAuthResponse;
    const object = parsed.value.object;
    const device_code = try requiredStringDupe(alloc, object, "device_code");
    errdefer secret.zeroAndFree(alloc, device_code);
    const user_code = try requiredStringDupe(alloc, object, "user_code");
    errdefer alloc.free(user_code);
    const verification_uri = try requiredHttpsUrlDupe(alloc, object, "verification_uri");
    errdefer alloc.free(verification_uri);
    const verification_uri_complete = if (object.get("verification_uri_complete")) |value| blk: {
        if (value == .null) break :blk null;
        if (value != .string or value.string.len == 0) return error.InvalidOAuthResponse;
        break :blk try httpsUrlDupe(alloc, value.string);
    } else null;
    errdefer if (verification_uri_complete) |value| alloc.free(value);
    const expires_in = try requiredPositiveInteger(object, "expires_in");
    const interval = if (object.get("interval")) |value|
        if (value == .integer and value.integer > 0 and value.integer <= max_poll_interval_seconds) value.integer else 5
    else
        5;
    return .{
        .device_code = device_code,
        .user_code = user_code,
        .verification_uri = verification_uri,
        .verification_uri_complete = verification_uri_complete,
        .expires_in = expires_in,
        .interval = interval,
    };
}

fn requiredHttpsUrlDupe(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidOAuthResponse;
    if (value != .string or value.string.len == 0) return error.InvalidOAuthResponse;
    return httpsUrlDupe(alloc, value.string);
}

fn httpsUrlDupe(alloc: Allocator, value: []const u8) ![]u8 {
    const uri = std.Uri.parse(value) catch return error.UntrustedVerificationUri;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.host == null or uri.user != null or uri.password != null) {
        return error.UntrustedVerificationUri;
    }
    return alloc.dupe(u8, value);
}

fn requiredPositiveInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidOAuthResponse;
    if (value != .integer or value.integer <= 0) return error.InvalidOAuthResponse;
    return value.integer;
}

fn takeSession(alloc: Allocator, provider: Provider, token: *oauth.TokenSet) !oauth_session.Session {
    const refresh_token = token.refresh_token orelse return error.NoRefreshToken;
    try provider.validateAccessToken(alloc, token.access_token);
    const expires_at_ms = try oauth.expiry_timestamp_ms(io_mod.milliTimestamp(), token.expires_in);
    const issuer = try alloc.dupe(u8, @tagName(provider));
    errdefer alloc.free(issuer);
    const client_id = try alloc.dupe(u8, provider.clientId());
    errdefer alloc.free(client_id);
    const session_scope = if (token.scope.len > 0) token.scope else try alloc.dupe(u8, provider.scope());
    errdefer if (token.scope.len == 0) alloc.free(session_scope);
    const session = oauth_session.Session{
        .issuer = issuer,
        .client_id = client_id,
        .access_token = token.access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms -| (refresh_skew_ms - std.time.ms_per_min),
        .scope = session_scope,
        .token_type = token.token_type,
    };
    token.access_token = &.{};
    token.refresh_token = null;
    if (token.scope.len > 0) token.scope = &.{};
    token.token_type = &.{};
    return session;
}

fn codexTokenHasAccountId(alloc: Allocator, token: []const u8) !bool {
    const first_dot = std.mem.findScalar(u8, token, '.') orelse return false;
    const payload_start = first_dot + 1;
    const second_relative = std.mem.findScalar(u8, token[payload_start..], '.') orelse return false;
    const payload = token[payload_start .. payload_start + second_relative];
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return false;
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch return false;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, decoded, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const auth = parsed.value.object.get("https://api.openai.com/auth") orelse return false;
    if (auth != .object) return false;
    const account = auth.object.get("chatgpt_account_id") orelse return false;
    return account == .string and account.string.len > 0;
}

fn replaceSessionTokens(alloc: Allocator, session: *oauth_session.Session, token: *oauth.TokenSet) !void {
    secret.zeroAndFree(alloc, session.access_token);
    session.access_token = token.access_token;
    token.access_token = &.{};
    if (token.refresh_token) |refresh| {
        secret.zeroAndFree(alloc, session.refresh_token);
        session.refresh_token = refresh;
        token.refresh_token = null;
    }
    if (token.scope.len > 0) {
        alloc.free(session.scope);
        session.scope = token.scope;
        token.scope = &.{};
    }
    alloc.free(session.token_type);
    session.token_type = token.token_type;
    token.token_type = &.{};
    session.expires_at_ms = (try oauth.expiry_timestamp_ms(io_mod.milliTimestamp(), token.expires_in)) -| (refresh_skew_ms - std.time.ms_per_min);
}

fn parseToken(
    alloc: Allocator,
    bytes: []const u8,
    previous_refresh: ?[]const u8,
    require_refresh: bool,
    allow_missing_expiry: bool,
) !oauth.TokenSet {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOAuthResponse;
    const object = parsed.value.object;
    const access = try requiredStringDupe(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access);
    const refresh = if (object.get("refresh_token")) |value|
        if (value == .string and value.string.len > 0) try alloc.dupe(u8, value.string) else null
    else if (previous_refresh) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (refresh) |value| secret.zeroAndFree(alloc, value);
    if (require_refresh and refresh == null) return error.NoRefreshToken;
    const expires_in = if (object.get("expires_in")) |value|
        if (value == .integer and value.integer > 0) value.integer else return error.InvalidOAuthResponse
    else if (allow_missing_expiry)
        3600
    else
        return error.InvalidOAuthResponse;
    const scope = if (object.get("scope")) |value|
        if (value == .string) try alloc.dupe(u8, value.string) else try alloc.dupe(u8, "")
    else
        try alloc.dupe(u8, "");
    errdefer alloc.free(scope);
    const token_type = if (object.get("token_type")) |value|
        if (value == .string and std.ascii.eqlIgnoreCase(value.string, "Bearer")) try alloc.dupe(u8, "Bearer") else return error.InvalidOAuthResponse
    else
        try alloc.dupe(u8, "Bearer");
    return .{
        .access_token = access,
        .refresh_token = refresh,
        .expires_in = expires_in,
        .scope = scope,
        .token_type = token_type,
    };
}

fn requiredStringDupe(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidOAuthResponse;
    if (value != .string or value.string.len == 0) return error.InvalidOAuthResponse;
    return alloc.dupe(u8, value.string);
}

fn fetchAccepted(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    method: oauth_transport.Method,
    url: []const u8,
    payload: []const u8,
) ![]u8 {
    var response = try transport.execute(alloc, .{ .method = method, .url = url, .payload = payload });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) {
        if (parseError(alloc, response.body)) |value| {
            if (value == .access_denied) return error.AccessDenied;
            if (value == .expired_token) return error.ExpiredToken;
        }
        return error.OAuthRequestFailed;
    }
    return response.takeBody();
}

const ProviderError = enum { authorization_pending, slow_down, access_denied, expired_token };

fn parseError(alloc: Allocator, bytes: []const u8) ?ProviderError {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("error") orelse return null;
    const code = switch (value) {
        .string => |text| text,
        .object => |object| blk: {
            const nested = object.get("code") orelse return null;
            if (nested != .string) return null;
            break :blk nested.string;
        },
        else => return null,
    };
    if (std.mem.eql(u8, code, "authorization_pending") or std.mem.eql(u8, code, "deviceauth_authorization_pending")) return .authorization_pending;
    if (std.mem.eql(u8, code, "slow_down")) return .slow_down;
    if (std.mem.eql(u8, code, "access_denied") or std.mem.eql(u8, code, "authorization_denied")) return .access_denied;
    if (std.mem.eql(u8, code, "expired_token")) return .expired_token;
    return null;
}

fn parsePollInterval(alloc: Allocator, bytes: []const u8) ?i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("interval") orelse return null;
    if (value != .integer or value.integer <= 0 or value.integer > max_poll_interval_seconds) return null;
    return value.integer;
}

fn sleepPollInterval(interval_seconds: i64) !void {
    if (interval_seconds <= 0 or interval_seconds > max_poll_interval_seconds) return error.InvalidOAuthResponse;
    const nanoseconds = std.math.mul(
        u64,
        @intCast(interval_seconds),
        std.time.ns_per_s,
    ) catch return error.InvalidOAuthResponse;
    io_mod.sleep(nanoseconds);
}

fn deinitSecretWriter(writer: *std.Io.Writer.Allocating) void {
    @memset(@constCast(writer.writer.buffered()), 0);
    writer.deinit();
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
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn setSocketTimeouts(socket: std.posix.socket_t, seconds: i64) void {
    const timeout = std.posix.timeval{ .sec = seconds, .usec = 0 };
    const bytes = std.mem.asBytes(&timeout);
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, bytes) catch {};
    std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, bytes) catch {};
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn writeStdoutFmt(comptime format: []const u8, args: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io_mod.getIo(), &buffer);
    try writer.interface.print(format, args);
    try writer.interface.flush();
}

test "provider aliases parse to stable login identities" {
    try std.testing.expectEqual(Provider.anthropic, Provider.parse("anthropic-max").?);
    try std.testing.expectEqual(Provider.openai_codex, Provider.parse("codex").?);
    try std.testing.expectEqual(Provider.xai, Provider.parse("xai-direct").?);
    try std.testing.expect(Provider.parse("vercel") == null);
}

test "OAuth form encoding escapes provider scopes and callback URLs" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var form: FormBody = .{};
    try form.append(&out.writer, "scope", "openid offline_access");
    try form.append(&out.writer, "redirect_uri", "http://localhost:1455/auth/callback");
    try std.testing.expectEqualStrings(
        "scope=openid%20offline_access&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
        out.writer.buffered(),
    );
}

test "callback query decoding rejects malformed escapes" {
    const decoded = try percentDecode(std.testing.allocator, "code%2Bvalue");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("code+value", decoded);
    try std.testing.expectError(error.InvalidAuthorizationCallback, percentDecode(std.testing.allocator, "%ZZ"));
}

test "manual callback accepts redirect URLs and code-state pairs" {
    var redirect = try parseManualCallback(
        std.testing.allocator,
        "http://localhost:53692/callback?code=code%2Bvalue&state=expected",
        "expected",
    );
    defer redirect.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("code+value", redirect.code);

    var pair = try parseManualCallback(std.testing.allocator, "raw-code#expected", "expected");
    defer pair.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("raw-code", pair.code);
    try std.testing.expectError(
        error.OAuthStateMismatch,
        parseManualCallback(std.testing.allocator, "raw-code#wrong", "expected"),
    );
}

test "provider token responses preserve refresh rotation and xAI fallback" {
    var rotated = try parseToken(
        std.testing.allocator,
        "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"expires_in\":3600,\"token_type\":\"Bearer\"}",
        "old-refresh",
        true,
        false,
    );
    defer rotated.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new-refresh", rotated.refresh_token.?);

    var retained = try parseToken(
        std.testing.allocator,
        "{\"access_token\":\"new-access\",\"expires_in\":3600}",
        "old-refresh",
        false,
        true,
    );
    defer retained.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("old-refresh", retained.refresh_token.?);
    try std.testing.expectError(
        error.InvalidOAuthResponse,
        parseToken(
            std.testing.allocator,
            "{\"access_token\":\"access\",\"refresh_token\":\"refresh\"}",
            null,
            true,
            false,
        ),
    );
}

test "xAI device authorization accepts only positive HTTPS responses" {
    var valid = try parseXaiDeviceAuthorization(
        std.testing.allocator,
        "{\"device_code\":\"device\",\"user_code\":\"CODE\",\"verification_uri\":\"https://auth.x.ai/device\",\"expires_in\":600}",
    );
    defer valid.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://auth.x.ai/device", valid.verification_uri);
    try std.testing.expectEqual(@as(i64, 5), valid.interval);

    try std.testing.expectError(
        error.UntrustedVerificationUri,
        parseXaiDeviceAuthorization(
            std.testing.allocator,
            "{\"device_code\":\"device\",\"user_code\":\"CODE\",\"verification_uri\":\"file:///tmp/token\",\"expires_in\":600}",
        ),
    );
    try std.testing.expectError(
        error.InvalidOAuthResponse,
        parseXaiDeviceAuthorization(
            std.testing.allocator,
            "{\"device_code\":\"device\",\"user_code\":\"CODE\",\"verification_uri\":\"https://auth.x.ai/device\",\"expires_in\":0}",
        ),
    );
}

test "Codex device responses accept string intervals and nested pending errors" {
    var device = try parseCodexDeviceAuthorization(
        std.testing.allocator,
        "{\"device_auth_id\":\"device\",\"user_code\":\"CODE\",\"interval\":\"3\"}",
    );
    defer device.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 3), device.interval);
    try std.testing.expectEqual(
        ProviderError.authorization_pending,
        parseError(std.testing.allocator, "{\"error\":{\"code\":\"deviceauth_authorization_pending\"}}").?,
    );
    try std.testing.expectEqual(
        @as(i64, 17),
        parsePollInterval(std.testing.allocator, "{\"error\":\"slow_down\",\"interval\":17}").?,
    );
}

test "managed access token validation rejects provider mismatches" {
    try std.testing.expectError(
        error.InvalidOAuthResponse,
        Provider.anthropic.validateAccessToken(std.testing.allocator, "not-an-anthropic-oauth-token"),
    );
    try Provider.openai_codex.validateAccessToken(
        std.testing.allocator,
        "header.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC0xMjMifX0.signature",
    );
    try std.testing.expectError(
        error.InvalidOAuthResponse,
        Provider.openai_codex.validateAccessToken(std.testing.allocator, "header.e30.signature"),
    );
}

var stable_provider_oauth_test_environ: ?*std.process.Environ.Map = null;

fn stableProviderOauthTestEnviron() !*const std.process.Environ.Map {
    if (stable_provider_oauth_test_environ) |map| return map;
    const alloc = std.heap.page_allocator;
    const map = try alloc.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(alloc);
    stable_provider_oauth_test_environ = map;
    return map;
}

const ProviderOauthTestEnv = struct {
    map: std.process.Environ.Map,

    fn install(home: []const u8) !ProviderOauthTestEnv {
        _ = try stableProviderOauthTestEnviron();
        var self = ProviderOauthTestEnv{ .map = std.process.Environ.Map.init(std.testing.allocator) };
        errdefer self.map.deinit();
        try self.map.put("HOME", home);
        return self;
    }

    fn deinit(self: *ProviderOauthTestEnv) void {
        if (stable_provider_oauth_test_environ) |map| io_mod.setEnvironMap(map);
        self.map.deinit();
        self.* = undefined;
    }
};

const RefreshTransportFixture = struct {
    response: []const u8,
    calls: usize = 0,

    fn provider(self: *RefreshTransportFixture) oauth_transport.Provider {
        return .{ .context = self, .execute_fn = execute };
    }

    fn execute(raw: ?*anyopaque, alloc: Allocator, request: oauth_transport.Request) !oauth_transport.Response {
        const self: *RefreshTransportFixture = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        try std.testing.expectEqual(oauth_transport.Method.post_json, request.method);
        try std.testing.expectEqualStrings(Provider.anthropic.tokenUrl(), request.url);
        return .{
            .disposition = .accepted,
            .status = 200,
            .body = try alloc.dupe(u8, self.response),
        };
    }
};

test "managed provider sessions persist and refresh under the isolated profile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "home", std.Io.File.Permissions.fromMode(0o700));
    const home = try io_mod.dirRealpathAlloc(std.testing.allocator, tmp.dir, "home");
    defer std.testing.allocator.free(home);
    var env = try ProviderOauthTestEnv.install(home);
    defer env.deinit();
    io_mod.setEnvironMap(&env.map);

    var original = oauth_session.Session{
        .issuer = try std.testing.allocator.dupe(u8, @tagName(Provider.anthropic)),
        .client_id = try std.testing.allocator.dupe(u8, Provider.anthropic.clientId()),
        .access_token = try std.testing.allocator.dupe(u8, "sk-ant-oat-old"),
        .refresh_token = try std.testing.allocator.dupe(u8, "old-refresh"),
        .expires_at_ms = 1,
        .scope = try std.testing.allocator.dupe(u8, Provider.anthropic.scope()),
        .token_type = try std.testing.allocator.dupe(u8, "Bearer"),
    };
    defer original.deinit(std.testing.allocator);
    try oauth_session.saveNamed(
        std.testing.allocator,
        Provider.anthropic.fileName(),
        @tagName(Provider.anthropic),
        original,
    );
    var saved = (try oauth_session.loadNamed(
        std.testing.allocator,
        Provider.anthropic.fileName(),
        @tagName(Provider.anthropic),
    )).?;
    saved.deinit(std.testing.allocator);

    var transport = RefreshTransportFixture{
        .response = "{\"access_token\":\"sk-ant-oat-new\",\"refresh_token\":\"new-refresh\",\"expires_in\":3600}",
    };
    var refreshed = (try loadManagedSession(
        std.testing.allocator,
        transport.provider(),
        .anthropic,
        true,
    )).?;
    defer refreshed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), transport.calls);
    try std.testing.expectEqualStrings("sk-ant-oat-new", refreshed.access_token);

    var persisted = (try oauth_session.loadNamed(
        std.testing.allocator,
        Provider.anthropic.fileName(),
        @tagName(Provider.anthropic),
    )).?;
    defer persisted.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new-refresh", persisted.refresh_token);
    persisted.expires_at_ms = 1;
    try oauth_session.saveNamed(
        std.testing.allocator,
        Provider.anthropic.fileName(),
        @tagName(Provider.anthropic),
        persisted,
    );
    try std.testing.expectError(
        error.OAuthTransportUnavailable,
        loadManagedSession(
            std.testing.allocator,
            oauth_transport.unavailable_provider,
            .anthropic,
            true,
        ),
    );
}
