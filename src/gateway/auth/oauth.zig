const std = @import("std");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("../../core/auth/secret.zig");

const Allocator = std.mem.Allocator;

// Sign in with Vercel supports exactly openid, email, profile and offline_access,
// and silently filters anything else. fx only needs identity plus a refresh token,
// so it asks for those two and nothing more. An earlier `use:ai-gateway` entry was
// never a real scope: it was dropped on every grant and bought nothing.
pub const default_scope = "openid offline_access";

/// Returns the first requested scope the issuer did not grant. A silently reduced
/// grant is otherwise invisible until some later request fails with a 401.
pub fn missingGrantedScope(requested: []const u8, granted: []const u8) ?[]const u8 {
    var wanted = std.mem.tokenizeScalar(u8, requested, ' ');
    while (wanted.next()) |scope| {
        var have = std.mem.tokenizeScalar(u8, granted, ' ');
        const found = while (have.next()) |candidate| {
            if (std.mem.eql(u8, candidate, scope)) break true;
        } else false;
        if (!found) return scope;
    }
    return null;
}
pub const OAuthError = error{
    InvalidIssuer,
    InvalidOAuthResponse,
    AuthorizationPending,
    SlowDown,
    AccessDenied,
    ExpiredToken,
    InvalidClient,
    OAuthRequestFailed,
};

pub const Metadata = struct {
    issuer: []u8,
    device_authorization_endpoint: []u8,
    token_endpoint: []u8,
    revocation_endpoint: ?[]u8 = null,

    pub fn deinit(self: *Metadata, alloc: Allocator) void {
        alloc.free(self.issuer);
        alloc.free(self.device_authorization_endpoint);
        alloc.free(self.token_endpoint);
        if (self.revocation_endpoint) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const DeviceAuthorization = struct {
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    verification_uri_complete: ?[]u8 = null,
    expires_in: i64,
    interval: i64,

    pub fn deinit(self: *DeviceAuthorization, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.device_code);
        alloc.free(self.user_code);
        alloc.free(self.verification_uri);
        if (self.verification_uri_complete) |value| alloc.free(value);
        self.* = undefined;
    }
};

pub const TokenSet = struct {
    access_token: []u8,
    refresh_token: ?[]u8 = null,
    expires_in: i64,
    scope: []u8,
    token_type: []u8,

    pub fn deinit(self: *TokenSet, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        if (self.refresh_token) |value| secret.zeroAndFree(alloc, value);
        if (self.scope.len > 0) alloc.free(self.scope);
        if (self.token_type.len > 0) alloc.free(self.token_type);
        self.* = undefined;
    }
};

pub const PollResult = union(enum) {
    pending,
    slow_down,
    success: TokenSet,
};

pub const TokenTypeHint = enum {
    access_token,
    refresh_token,
};

pub fn expiry_timestamp_ms(now_ms: i64, expires_in_seconds: i64) OAuthError!i64 {
    if (expires_in_seconds <= 0) return OAuthError.InvalidOAuthResponse;
    const duration_ms = std.math.mul(i64, expires_in_seconds, std.time.ms_per_s) catch
        return OAuthError.InvalidOAuthResponse;
    return std.math.add(i64, now_ms, duration_ms) catch OAuthError.InvalidOAuthResponse;
}

pub fn discover(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    issuer_url: []const u8,
) !Metadata {
    const url = try std.fmt.allocPrint(alloc, "{s}/.well-known/openid-configuration", .{issuer_url});
    defer alloc.free(url);
    const bytes = try fetchJson(alloc, transport, .get, url, null, .{});
    defer alloc.free(bytes);
    var metadata = try parseMetadata(alloc, bytes);
    errdefer metadata.deinit(alloc);
    if (!std.mem.eql(u8, metadata.issuer, issuer_url)) return OAuthError.InvalidIssuer;
    return metadata;
}

pub fn requestDeviceAuthorization(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: Metadata,
    client_id: []const u8,
) !DeviceAuthorization {
    var form: FormBody = .{};
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try form.append(&writer.writer, "client_id", client_id);
    try form.append(&writer.writer, "scope", default_scope);
    const bytes = try fetchJson(
        alloc,
        transport,
        .post_form,
        metadata.device_authorization_endpoint,
        writer.written(),
        .{},
    );
    defer secret.zeroAndFree(alloc, bytes);
    return parseDeviceAuthorization(alloc, bytes);
}

pub fn pollDeviceTokenBounded(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: Metadata,
    client_id: []const u8,
    device_code: []const u8,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !PollResult {
    var form: FormBody = .{};
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try form.append(&writer.writer, "client_id", client_id);
    try form.append(&writer.writer, "grant_type", "urn:ietf:params:oauth:grant-type:device_code");
    try form.append(&writer.writer, "device_code", device_code);

    const bytes = fetchJson(
        alloc,
        transport,
        .post_form,
        metadata.token_endpoint,
        writer.written(),
        .{
            .cancel_flag = cancel_flag,
            .deadline = deadline,
        },
    ) catch |err| {
        if (err == OAuthError.AuthorizationPending) return .pending;
        if (err == OAuthError.SlowDown) return .slow_down;
        return err;
    };
    defer secret.zeroAndFree(alloc, bytes);
    return .{ .success = try parseTokenSet(alloc, bytes) };
}

pub fn refreshToken(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    metadata: Metadata,
    client_id: []const u8,
    refresh_token: []const u8,
) !TokenSet {
    var form: FormBody = .{};
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try form.append(&writer.writer, "client_id", client_id);
    try form.append(&writer.writer, "grant_type", "refresh_token");
    try form.append(&writer.writer, "refresh_token", refresh_token);
    const bytes = try fetchJson(
        alloc,
        transport,
        .post_form,
        metadata.token_endpoint,
        writer.written(),
        .{},
    );
    defer secret.zeroAndFree(alloc, bytes);
    return parseTokenSet(alloc, bytes);
}

pub fn revokeToken(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    endpoint: []const u8,
    client_id: []const u8,
    token: []const u8,
    token_type_hint: TokenTypeHint,
) !void {
    var form: FormBody = .{};
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try form.append(&writer.writer, "client_id", client_id);
    try form.append(&writer.writer, "token", token);
    try form.append(&writer.writer, "token_type_hint", @tagName(token_type_hint));
    const bytes = try fetchJson(
        alloc,
        transport,
        .post_form,
        endpoint,
        writer.written(),
        .{},
    );
    secret.zeroAndFree(alloc, bytes);
}

pub fn parseMetadata(alloc: Allocator, bytes: []const u8) !Metadata {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return OAuthError.InvalidOAuthResponse;
    const object = parsed.value.object;
    const issuer_value = try dupeRequiredString(alloc, object, "issuer");
    errdefer alloc.free(issuer_value);
    const device_authorization_endpoint = try dupeRequiredString(alloc, object, "device_authorization_endpoint");
    errdefer alloc.free(device_authorization_endpoint);
    const token_endpoint = try dupeRequiredString(alloc, object, "token_endpoint");
    errdefer alloc.free(token_endpoint);
    const revocation_endpoint = try dupeOptionalString(alloc, object, "revocation_endpoint");
    errdefer if (revocation_endpoint) |value| alloc.free(value);
    return .{
        .issuer = issuer_value,
        .device_authorization_endpoint = device_authorization_endpoint,
        .token_endpoint = token_endpoint,
        .revocation_endpoint = revocation_endpoint,
    };
}

pub fn parseDeviceAuthorization(alloc: Allocator, bytes: []const u8) !DeviceAuthorization {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return OAuthError.InvalidOAuthResponse;
    const object = parsed.value.object;
    const expires_in = try requiredInteger(object, "expires_in");
    const interval = requiredInteger(object, "interval") catch 5;
    const device_code = try dupeRequiredString(alloc, object, "device_code");
    errdefer secret.zeroAndFree(alloc, device_code);
    const user_code = try dupeRequiredString(alloc, object, "user_code");
    errdefer alloc.free(user_code);
    const verification_uri = try dupeRequiredString(alloc, object, "verification_uri");
    errdefer alloc.free(verification_uri);
    const verification_uri_complete = try dupeOptionalString(alloc, object, "verification_uri_complete");
    errdefer if (verification_uri_complete) |value| alloc.free(value);
    return .{
        .device_code = device_code,
        .user_code = user_code,
        .verification_uri = verification_uri,
        .verification_uri_complete = verification_uri_complete,
        .expires_in = expires_in,
        .interval = interval,
    };
}

pub fn parseTokenSet(alloc: Allocator, bytes: []const u8) !TokenSet {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return OAuthError.InvalidOAuthResponse;
    const object = parsed.value.object;
    const token_type = try dupeRequiredString(alloc, object, "token_type");
    errdefer alloc.free(token_type);
    if (!std.ascii.eqlIgnoreCase(token_type, "Bearer")) return OAuthError.InvalidOAuthResponse;
    const maybe_scope = try dupeOptionalString(alloc, object, "scope");
    const scope = maybe_scope orelse try alloc.dupe(u8, "");
    errdefer alloc.free(scope);
    const access_token = try dupeRequiredString(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeOptionalString(alloc, object, "refresh_token");
    errdefer if (refresh_token) |value| secret.zeroAndFree(alloc, value);
    const expires_in = try requiredInteger(object, "expires_in");
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = expires_in,
        .scope = scope,
        .token_type = token_type,
    };
}

fn fetchJson(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    method: oauth_transport.Method,
    url: []const u8,
    payload: ?[]const u8,
    bounds: struct {
        cancel_flag: ?*std.atomic.Value(bool) = null,
        deadline: ?std.Io.Clock.Timestamp = null,
    },
) ![]u8 {
    var response = try transport.execute(alloc, .{
        .method = method,
        .payload = payload,
        .url = url,
        .cancel_flag = bounds.cancel_flag,
        .deadline = bounds.deadline,
    });
    defer response.deinit(alloc);

    if (response.disposition == .accepted) return response.takeBody();
    try mapOAuthHttpError(alloc, response.body);
    return OAuthError.OAuthRequestFailed;
}

fn mapOAuthHttpError(alloc: Allocator, body: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return OAuthError.OAuthRequestFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return OAuthError.OAuthRequestFailed;
    const object = parsed.value.object;
    const value = object.get("error") orelse return OAuthError.OAuthRequestFailed;
    if (value != .string) return OAuthError.OAuthRequestFailed;
    if (std.mem.eql(u8, value.string, "authorization_pending")) return OAuthError.AuthorizationPending;
    if (std.mem.eql(u8, value.string, "slow_down")) return OAuthError.SlowDown;
    if (std.mem.eql(u8, value.string, "access_denied")) return OAuthError.AccessDenied;
    if (std.mem.eql(u8, value.string, "expired_token")) return OAuthError.ExpiredToken;
    if (std.mem.eql(u8, value.string, "invalid_client")) return OAuthError.InvalidClient;
    return OAuthError.OAuthRequestFailed;
}

const FormBody = struct {
    first: bool = true,

    fn append(self: *FormBody, writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
        if (!self.first) try writer.writeAll("&");
        self.first = false;
        try percentEncode(writer, key);
        try writer.writeAll("=");
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

fn dupeRequiredString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return OAuthError.InvalidOAuthResponse;
    if (value != .string or value.string.len == 0) return OAuthError.InvalidOAuthResponse;
    return alloc.dupe(u8, value.string);
}

fn dupeOptionalString(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len == 0) return OAuthError.InvalidOAuthResponse;
    return try alloc.dupe(u8, value.string);
}

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return OAuthError.InvalidOAuthResponse;
    if (value != .integer) return OAuthError.InvalidOAuthResponse;
    return value.integer;
}

fn check_metadata_allocation_failures(alloc: Allocator) !void {
    var metadata = try parseMetadata(
        alloc,
        "{\"issuer\":\"https://vercel.com\",\"device_authorization_endpoint\":\"https://vercel.com/device\",\"token_endpoint\":\"https://vercel.com/token\",\"revocation_endpoint\":\"https://vercel.com/revoke\"}",
    );
    defer metadata.deinit(alloc);
}

fn check_device_authorization_allocation_failures(alloc: Allocator) !void {
    var device = try parseDeviceAuthorization(
        alloc,
        "{\"device_code\":\"device\",\"user_code\":\"user\",\"verification_uri\":\"https://vercel.com/verify\",\"verification_uri_complete\":\"https://vercel.com/verify?code=user\",\"expires_in\":600,\"interval\":5}",
    );
    defer device.deinit(alloc);
}

fn check_token_set_allocation_failures(alloc: Allocator) !void {
    var token = try parseTokenSet(
        alloc,
        "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"scope\":\"openid offline_access\",\"token_type\":\"Bearer\"}",
    );
    defer token.deinit(alloc);
}

const TransportProbe = struct {
    expected_method: oauth_transport.Method,
    expected_url: []const u8,
    expected_payload: ?[]const u8 = null,
    response_disposition: oauth_transport.Disposition = .accepted,
    response_body: []const u8,
    expected_cancel_flag: ?*std.atomic.Value(bool) = null,
    expect_deadline: bool = false,
    matched: bool = false,

    fn provider(self: *TransportProbe) oauth_transport.Provider {
        return .{
            .context = self,
            .execute_fn = execute,
        };
    }

    fn execute(
        raw: ?*anyopaque,
        alloc: Allocator,
        request: oauth_transport.Request,
    ) !oauth_transport.Response {
        const self: *TransportProbe = @ptrCast(@alignCast(raw.?));
        self.matched = request.method == self.expected_method and
            std.mem.eql(u8, request.url, self.expected_url) and
            optionalBytesEqual(request.payload, self.expected_payload) and
            request.cancel_flag == self.expected_cancel_flag and
            (request.deadline != null) == self.expect_deadline;
        return .{
            .disposition = self.response_disposition,
            .body = try alloc.dupe(u8, self.response_body),
        };
    }
};

fn optionalBytesEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

test "oauth discovery maps protocol input through the injected transport" {
    const issuer = "https://vercel.test";
    var probe = TransportProbe{
        .expected_method = .get,
        .expected_url = issuer ++ "/.well-known/openid-configuration",
        .response_body = "{\"issuer\":\"https://vercel.test\",\"device_authorization_endpoint\":\"https://vercel.test/device\",\"token_endpoint\":\"https://vercel.test/token\"}",
    };

    var metadata = try discover(std.testing.allocator, probe.provider(), issuer);
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expect(probe.matched);
    try std.testing.expectEqualStrings("https://vercel.test/token", metadata.token_endpoint);
}

test "oauth device authorization owns form mapping while transport owns execution" {
    var probe = TransportProbe{
        .expected_method = .post_form,
        .expected_url = "https://vercel.test/device",
        .expected_payload = "client_id=client%20id&scope=openid%20offline_access",
        .response_body = "{\"device_code\":\"device\",\"user_code\":\"CODE\",\"verification_uri\":\"https://vercel.test/verify\",\"expires_in\":600,\"interval\":5}",
    };
    const metadata = Metadata{
        .issuer = @constCast("https://vercel.test"),
        .device_authorization_endpoint = @constCast("https://vercel.test/device"),
        .token_endpoint = @constCast("https://vercel.test/token"),
    };

    var device = try requestDeviceAuthorization(
        std.testing.allocator,
        probe.provider(),
        metadata,
        "client id",
    );
    defer device.deinit(std.testing.allocator);

    try std.testing.expect(probe.matched);
    try std.testing.expectEqualStrings("device", device.device_code);
}

test "oauth polling forwards bounds and preserves pending responses" {
    var cancel_flag = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(std.testing.io, .{
        .clock = .awake,
        .raw = .fromMilliseconds(1),
    });
    var probe = TransportProbe{
        .expected_method = .post_form,
        .expected_url = "https://vercel.test/token",
        .expected_payload = "client_id=client&grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&device_code=device",
        .response_disposition = .rejected,
        .response_body = "{\"error\":\"authorization_pending\"}",
        .expected_cancel_flag = &cancel_flag,
        .expect_deadline = true,
    };
    const metadata = Metadata{
        .issuer = @constCast("https://vercel.test"),
        .device_authorization_endpoint = @constCast("https://vercel.test/device"),
        .token_endpoint = @constCast("https://vercel.test/token"),
    };

    const result = try pollDeviceTokenBounded(
        std.testing.allocator,
        probe.provider(),
        metadata,
        "client",
        "device",
        &cancel_flag,
        deadline,
    );

    try std.testing.expect(probe.matched);
    try std.testing.expectEqual(PollResult.pending, result);
}

test "a reduced grant names the scope the issuer withheld" {
    try std.testing.expect(missingGrantedScope("openid offline_access", "openid offline_access") == null);
    try std.testing.expect(missingGrantedScope("openid", "openid email profile") == null);
    try std.testing.expectEqualStrings(
        "offline_access",
        missingGrantedScope("openid offline_access", "openid").?,
    );
    // The scope fx used to request was never advertised, so every grant dropped it.
    try std.testing.expectEqualStrings(
        "use:ai-gateway",
        missingGrantedScope("openid offline_access use:ai-gateway", "openid offline_access").?,
    );
    try std.testing.expect(missingGrantedScope("", "openid") == null);
}

test "oauth parses metadata" {
    var metadata = try parseMetadata(
        std.testing.allocator,
        "{\"issuer\":\"https://vercel.com\",\"device_authorization_endpoint\":\"https://vercel.com/device\",\"token_endpoint\":\"https://vercel.com/token\",\"revocation_endpoint\":\"https://vercel.com/revoke\"}",
    );
    defer metadata.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("https://vercel.com", metadata.issuer);
    try std.testing.expectEqualStrings("https://vercel.com/device", metadata.device_authorization_endpoint);
}

test "oauth maps provider errors" {
    try std.testing.expectError(OAuthError.AuthorizationPending, mapOAuthHttpError(std.testing.allocator, "{\"error\":\"authorization_pending\"}"));
    try std.testing.expectError(OAuthError.SlowDown, mapOAuthHttpError(std.testing.allocator, "{\"error\":\"slow_down\"}"));
    try std.testing.expectError(OAuthError.AccessDenied, mapOAuthHttpError(std.testing.allocator, "{\"error\":\"access_denied\"}"));
    try std.testing.expectError(OAuthError.ExpiredToken, mapOAuthHttpError(std.testing.allocator, "{\"error\":\"expired_token\"}"));
    try std.testing.expectError(OAuthError.OAuthRequestFailed, mapOAuthHttpError(std.testing.allocator, "{\"error\":\"invalid_request\"}"));
    try std.testing.expectError(OAuthError.OAuthRequestFailed, mapOAuthHttpError(std.testing.allocator, "{\"error\":42}"));
    try std.testing.expectError(OAuthError.InvalidClient, mapOAuthHttpError(std.testing.allocator, "{\"error\":\"invalid_client\"}"));
}

test "oauth parses token set" {
    var token = try parseTokenSet(
        std.testing.allocator,
        "{\"access_token\":\"access\",\"refresh_token\":\"refresh\",\"expires_in\":3600,\"scope\":\"openid offline_access\",\"token_type\":\"Bearer\"}",
    );
    defer token.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("access", token.access_token);
    try std.testing.expectEqualStrings("refresh", token.refresh_token.?);
    try std.testing.expectEqual(@as(i64, 3600), token.expires_in);
}

test "oauth parsers clean up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_metadata_allocation_failures, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_device_authorization_allocation_failures, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_token_set_allocation_failures, .{});
}

test "oauth expiry timestamps reject invalid durations" {
    try std.testing.expectEqual(@as(i64, 11_000), try expiry_timestamp_ms(1_000, 10));
    try std.testing.expectError(OAuthError.InvalidOAuthResponse, expiry_timestamp_ms(1_000, 0));
    try std.testing.expectError(OAuthError.InvalidOAuthResponse, expiry_timestamp_ms(1_000, -1));
    try std.testing.expectError(OAuthError.InvalidOAuthResponse, expiry_timestamp_ms(1_000, std.math.maxInt(i64)));
    try std.testing.expectError(OAuthError.InvalidOAuthResponse, expiry_timestamp_ms(std.math.maxInt(i64), 1));
}

test "oauth parsers reject non-object JSON" {
    try std.testing.expectError(OAuthError.InvalidOAuthResponse, parseMetadata(std.testing.allocator, "[]"));
    try std.testing.expectError(OAuthError.InvalidOAuthResponse, parseDeviceAuthorization(std.testing.allocator, "null"));
    try std.testing.expectError(OAuthError.InvalidOAuthResponse, parseTokenSet(std.testing.allocator, "\"token\""));
    try std.testing.expectError(OAuthError.OAuthRequestFailed, mapOAuthHttpError(std.testing.allocator, "42"));
}
