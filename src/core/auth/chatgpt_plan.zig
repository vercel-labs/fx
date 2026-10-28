//! ChatGPT plan OAuth grants. Persistence and browser callbacks belong to the caller.
//! Endpoints follow the provider's OpenID discovery document. Code grants use
//! RFC 6749, PKCE (RFC 7636), and resource indicators (RFC 8707).
const std = @import("std");
const oauth = @import("oauth.zig");
const oidc = @import("oidc.zig");
const transport_mod = @import("oauth_transport.zig");
const io_mod = @import("../shared/io.zig");
const Allocator = std.mem.Allocator;

pub const issuer = "https://auth.openai.com";
pub const authorization_path = "/api/accounts/authorize";
pub const token_endpoint = issuer ++ "/api/accounts/oauth/token";
pub const bootstrap_client_id = "dynamic_agent_client";
const api_resource = "https://api.openai.com/v1";
const plan_permission = "chatgpt.tokens.use.direct";

pub const Authorization = struct {
    client_id: []const u8,
    host_id: []const u8,
    redirect_uri: []const u8,
    challenge: []const u8,
    state: []const u8,
    nonce: []const u8,
};

pub fn authorizationUrl(alloc: Allocator, base: []const u8, attempt: Authorization) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();
    try writer.writer.print("{s}{s}?", .{ std.mem.trimEnd(u8, base, "/"), authorization_path });
    var fields: oauth.FormBody = .{};
    const parameters = [_][2][]const u8{
        .{ "client_id", attempt.client_id },
        .{ "redirect_uri", attempt.redirect_uri },
        .{ "response_type", "code" },
        .{ "scope", "openid profile email offline_access resource.invoke " ++ plan_permission },
        .{ "state", attempt.state },
        .{ "nonce", attempt.nonce },
        .{ "code_challenge", attempt.challenge },
        .{ "code_challenge_method", "S256" },
        .{ "resource", api_resource },
        .{ "ext_agent_host_id", attempt.host_id },
    };
    for (parameters) |parameter| try fields.append(&writer.writer, parameter[0], parameter[1]);
    if (std.mem.eql(u8, attempt.client_id, bootstrap_client_id)) {
        try fields.append(&writer.writer, "agent_name_hint", "fx");
    }
    return writer.toOwnedSlice();
}

/// An existing registration cannot be replaced by a callback. An initial
/// authorization must return an issued registration, not the bootstrap name.
pub fn registeredClient(previous: ?[]const u8, returned: ?[]const u8) ![]const u8 {
    if (previous) |known| {
        if (returned) |candidate| {
            if (!std.mem.eql(u8, candidate, known)) return error.ChatGptRegistrationChanged;
        }
        return known;
    }
    const value = returned orelse return error.ChatGptRegistrationMissing;
    if (value.len <= 7 or value.len > 256 or !std.mem.startsWith(u8, value, "oaiapp_")) return error.ChatGptRegistrationMissing;
    for (value[7..]) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') return error.ChatGptRegistrationMissing;
    }
    return value;
}

pub const Grant = union(enum) {
    authorization_code: struct {
        code: []const u8,
        verifier: []const u8,
        redirect_uri: []const u8,
        nonce: []const u8,
    },
    refresh_token: []const u8,
};

pub const Tokens = struct {
    token_set: oauth.TokenSet,
    subject: ?[]u8,
    expires_at_ms: i64,
    earliest_refresh_at_ms: i64,

    pub fn deinit(self: *Tokens, alloc: Allocator) void {
        self.token_set.deinit(alloc);
        if (self.subject) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const Exchange = struct {
    transport: transport_mod.Provider,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    deadline: ?std.Io.Clock.Timestamp = null,

    pub fn request(
        self: Exchange,
        alloc: Allocator,
        endpoint: []const u8,
        client: []const u8,
        expected_subject: ?[]const u8,
        grant: Grant,
    ) !Tokens {
        if (self.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
        var body: std.Io.Writer.Allocating = .init(alloc);
        defer body.deinit();
        defer std.crypto.secureZero(u8, @volatileCast(body.written()));
        var fields: oauth.FormBody = .{};
        try fields.append(&body.writer, "client_id", client);
        try fields.append(&body.writer, "resource", api_resource);
        try fields.append(&body.writer, "grant_type", @tagName(grant));
        switch (grant) {
            .authorization_code => |code| {
                try fields.append(&body.writer, "code", code.code);
                try fields.append(&body.writer, "redirect_uri", code.redirect_uri);
                try fields.append(&body.writer, "code_verifier", code.verifier);
            },
            .refresh_token => |token| try fields.append(&body.writer, "refresh_token", token),
        }
        var response = try self.transport.execute(alloc, .{
            .method = .post_form,
            .url = endpoint,
            .payload = body.written(),
            .cancel_flag = self.cancel_flag,
            .deadline = self.deadline,
        });
        defer response.deinit(alloc);
        if (response.disposition != .accepted) {
            if (grant == .refresh_token and refreshRejected(alloc, response.body)) return error.CredentialRefreshRejected;
            return error.ChatGptOAuthRequestFailed;
        }
        const nonce: ?[]const u8 = switch (grant) {
            .authorization_code => |code| code.nonce,
            .refresh_token => null,
        };
        // Once accepted, a refresh may have rotated. The caller must retire the
        // stored grant if any subsequent step cannot produce a usable response.
        var result = self.decodeResponse(alloc, response.body, client, nonce) catch |err| {
            if (grant == .refresh_token) return error.CredentialRefreshRejected;
            return err;
        };
        errdefer result.deinit(alloc);
        if (expected_subject) |expected| {
            if (result.subject) |actual| {
                if (!std.mem.eql(u8, actual, expected)) return error.ChatGptAccountChanged;
            }
        }
        return result;
    }

    fn decodeResponse(self: Exchange, alloc: Allocator, bytes: []const u8, client: []const u8, nonce: ?[]const u8) !Tokens {
        var tokens = try oauth.parseTokenSet(alloc, bytes);
        errdefer tokens.deinit(alloc);
        if (nonce != null and tokens.refresh_token == null) return error.ChatGptRefreshTokenMissing;
        var permitted = false;
        var scopes = std.mem.tokenizeScalar(u8, tokens.scope, ' ');
        while (scopes.next()) |scope| {
            if (std.mem.eql(u8, scope, plan_permission)) permitted = true;
        }
        if (!permitted and (nonce != null or tokens.scope.len != 0)) return error.ChatGptPlanPermissionRequired;

        const Extra = struct { id_token: ?[]const u8 = null, earliest_refresh_at: ?i64 = null };
        var extra = std.json.parseFromSlice(Extra, alloc, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidChatGptOAuthResponse,
        };
        defer extra.deinit();
        const now = io_mod.milliTimestamp();
        const expiry = try oauth.expiry_timestamp_ms(now, tokens.expires_in);
        const not_before = std.math.mul(i64, extra.value.earliest_refresh_at orelse 0, std.time.ms_per_s) catch return error.InvalidChatGptOAuthResponse;
        if (not_before < 0 or not_before > expiry) return error.InvalidChatGptOAuthResponse;
        const verified_subject = if (extra.value.id_token) |jwt|
            try self.identity(alloc, jwt, .{ .issuer = issuer, .audience = client, .nonce = nonce, .now_s = @divFloor(now, std.time.ms_per_s) })
        else if (nonce != null)
            return error.ChatGptIdTokenMissing
        else
            null;
        return .{ .token_set = tokens, .subject = verified_subject, .expires_at_ms = expiry, .earliest_refresh_at_ms = not_before };
    }

    fn identity(self: Exchange, alloc: Allocator, jwt: []const u8, expected: oidc.Validation) ![]u8 {
        const endpoint = try oauth.configuredEndpoint(alloc, "FX_E2E_CHATGPT_JWKS_URL", issuer ++ "/.well-known/jwks.json");
        defer alloc.free(endpoint);
        var keys = try self.transport.execute(alloc, .{
            .method = .get,
            .url = endpoint,
            .cancel_flag = self.cancel_flag,
            .deadline = self.deadline,
        });
        defer keys.deinit(alloc);
        if (keys.disposition != .accepted) return error.UnknownSigningKey;
        return oidc.subject(alloc, jwt, keys.body, expected);
    }
};

fn refreshRejected(alloc: Allocator, bytes: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    var value = parsed.value.object.get("error") orelse return false;
    if (value == .object) value = value.object.get("code") orelse return false;
    if (value != .string) return false;
    for ([_][]const u8{ "invalid_grant", "refresh_token_reused", "refresh_token_expired", "refresh_token_invalidated" }) |code| {
        if (std.mem.eql(u8, code, value.string)) return true;
    }
    return false;
}

test "ChatGPT plan registrations cannot change during returning sign-in" {
    try std.testing.expectError(error.ChatGptRegistrationMissing, registeredClient(null, null));
    try std.testing.expectError(error.ChatGptRegistrationMissing, registeredClient(null, bootstrap_client_id));
    try std.testing.expectError(error.ChatGptRegistrationChanged, registeredClient("oaiapp_example", "oaiapp_another"));
    try std.testing.expectEqualStrings("oaiapp_example", try registeredClient(null, "oaiapp_example"));
    try std.testing.expectEqualStrings("oaiapp_example", try registeredClient("oaiapp_example", null));
}

test "ChatGPT plan refresh sends a bounded form and accepts no new identity" {
    const Mock = struct {
        fn execute(_: ?*anyopaque, alloc: Allocator, request: transport_mod.Request) !transport_mod.Response {
            try std.testing.expectEqual(transport_mod.Method.post_form, request.method);
            try std.testing.expect(request.authorization == null);
            try std.testing.expect(request.cancel_flag != null);
            try std.testing.expect(request.deadline != null);
            const value = try oauth.queryValueNonEmptyAlloc(alloc, request.payload.?, "refresh_token");
            defer alloc.free(value);
            try std.testing.expectEqualStrings("refresh&encoded", value);
            return .{ .disposition = .accepted, .body = try alloc.dupe(u8,
                \\{"access_token":"opaque","expires_in":3600,"token_type":"Bearer"}
            ) };
        }
    };
    var cancelled = std.atomic.Value(bool).init(false);
    const exchange: Exchange = .{
        .transport = .{ .execute_fn = Mock.execute },
        .cancel_flag = &cancelled,
        .deadline = std.Io.Clock.Timestamp.now(std.testing.io, .awake),
    };
    var tokens = try exchange.request(std.testing.allocator, token_endpoint, "oaiapp_example", "member", .{ .refresh_token = "refresh&encoded" });
    defer tokens.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("opaque", tokens.token_set.access_token);
    try std.testing.expect(tokens.subject == null);
    try std.testing.expect(tokens.token_set.refresh_token == null);
}

test "ChatGPT plan terminal refresh errors are parsed rather than substring matched" {
    try std.testing.expect(refreshRejected(std.testing.allocator, "{\"error\":\"invalid_grant\"}"));
    try std.testing.expect(refreshRejected(std.testing.allocator, "{\"error\":{\"code\":\"refresh_token_reused\"}}"));
    try std.testing.expect(!refreshRejected(std.testing.allocator, "{\"error\":\"server_error\",\"description\":\"invalid_grant\"}"));
}
