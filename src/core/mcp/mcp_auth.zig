const std = @import("std");
const host_target = @import("../hosts/target.zig");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const operation_control = @import("operation_control.zig");
const browser_callback = @import("../auth/browser_callback.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;

pub const max_document_bytes: usize = 256 * 1024;
pub const expiry_skew_ms: i64 = 60 * 1000;
pub const max_scope_reauthorizations: u8 = 2;
const request_timeout_seconds: i64 = 30;
const callback_io_timeout_seconds: i64 = 30;
const max_scope_tokens: usize = 64;
const max_scope_token_bytes: usize = 256;

pub const RefreshControl = struct {
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: ?*std.atomic.Value(bool) = null,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool) = null,

    pub fn cancellation(self: RefreshControl) operation_control.CancellationSources {
        return .{
            .caller = self.cancel_flag,
            .runtime = self.lifecycle_cancel_flag,
        };
    }
};

pub const Challenge = struct {
    resource_metadata: ?[]u8 = null,
    scope: ?[]u8 = null,
    insufficient_scope: bool = false,

    pub fn deinit(self: *Challenge, alloc: Allocator) void {
        if (self.resource_metadata) |value| alloc.free(value);
        if (self.scope) |value| alloc.free(value);
        self.* = .{};
    }

    pub fn clone(self: Challenge, alloc: Allocator) !Challenge {
        const resource_metadata = if (self.resource_metadata) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (resource_metadata) |value| alloc.free(value);
        return .{
            .resource_metadata = resource_metadata,
            .scope = if (self.scope) |value| try alloc.dupe(u8, value) else null,
            .insufficient_scope = self.insufficient_scope,
        };
    }
};

pub const ClientConfig = struct {
    resource: ?[]const u8 = null,
    issuer: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    client_secret: ?[]const u8 = null,
    client_metadata_url: ?[]const u8 = null,
    scopes: []const []const u8 = &.{},
};

pub const Credentials = struct {
    endpoint: []u8,
    resource: []u8,
    issuer: []u8,
    client_id: []u8,
    client_secret: ?[]u8 = null,
    access_token: []u8,
    refresh_token: ?[]u8 = null,
    scope: []u8,
    token_type: []u8,
    token_endpoint_auth_method: []u8,
    expires_at_ms: i64,
    authorization_endpoint: []u8,
    token_endpoint: []u8,
    revocation_endpoint: ?[]u8 = null,

    pub fn deinit(self: *Credentials, alloc: Allocator) void {
        alloc.free(self.endpoint);
        alloc.free(self.resource);
        alloc.free(self.issuer);
        alloc.free(self.client_id);
        if (self.client_secret) |value| secret.zeroAndFree(alloc, value);
        secret.zeroAndFree(alloc, self.access_token);
        if (self.refresh_token) |value| secret.zeroAndFree(alloc, value);
        alloc.free(self.scope);
        alloc.free(self.token_type);
        alloc.free(self.token_endpoint_auth_method);
        alloc.free(self.authorization_endpoint);
        alloc.free(self.token_endpoint);
        if (self.revocation_endpoint) |value| alloc.free(value);
        self.* = undefined;
    }

    pub fn needsRefresh(self: Credentials, now_ms: i64) bool {
        return self.expires_at_ms -| expiry_skew_ms <= now_ms;
    }

    pub fn clone(self: Credentials, alloc: Allocator) !Credentials {
        const endpoint = try alloc.dupe(u8, self.endpoint);
        errdefer alloc.free(endpoint);
        const resource = try alloc.dupe(u8, self.resource);
        errdefer alloc.free(resource);
        const issuer = try alloc.dupe(u8, self.issuer);
        errdefer alloc.free(issuer);
        const client_id = try alloc.dupe(u8, self.client_id);
        errdefer alloc.free(client_id);
        const client_secret = if (self.client_secret) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (client_secret) |value| secret.zeroAndFree(alloc, value);
        const access_token = try alloc.dupe(u8, self.access_token);
        errdefer secret.zeroAndFree(alloc, access_token);
        const refresh_token = if (self.refresh_token) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (refresh_token) |value| secret.zeroAndFree(alloc, value);
        const scope = try alloc.dupe(u8, self.scope);
        errdefer alloc.free(scope);
        const token_type = try alloc.dupe(u8, self.token_type);
        errdefer alloc.free(token_type);
        const auth_method = try alloc.dupe(u8, self.token_endpoint_auth_method);
        errdefer alloc.free(auth_method);
        const authorization_endpoint = try alloc.dupe(u8, self.authorization_endpoint);
        errdefer alloc.free(authorization_endpoint);
        const token_endpoint = try alloc.dupe(u8, self.token_endpoint);
        errdefer alloc.free(token_endpoint);
        const revocation_endpoint = if (self.revocation_endpoint) |value|
            try alloc.dupe(u8, value)
        else
            null;
        return .{
            .endpoint = endpoint,
            .resource = resource,
            .issuer = issuer,
            .client_id = client_id,
            .client_secret = client_secret,
            .access_token = access_token,
            .refresh_token = refresh_token,
            .scope = scope,
            .token_type = token_type,
            .token_endpoint_auth_method = auth_method,
            .expires_at_ms = self.expires_at_ms,
            .authorization_endpoint = authorization_endpoint,
            .token_endpoint = token_endpoint,
            .revocation_endpoint = revocation_endpoint,
        };
    }
};

pub const IssuerMismatchSource = enum {
    authorization_metadata,
    authorization_response,
};

pub const IssuerMismatch = struct {
    owner_alloc: Allocator,
    source: IssuerMismatchSource,
    expected: []u8,
    returned: []u8,

    pub fn init(
        alloc: Allocator,
        source: IssuerMismatchSource,
        expected: []const u8,
        returned: []const u8,
    ) !IssuerMismatch {
        const owned_expected = try alloc.dupe(u8, expected);
        errdefer alloc.free(owned_expected);
        return .{
            .owner_alloc = alloc,
            .source = source,
            .expected = owned_expected,
            .returned = try alloc.dupe(u8, returned),
        };
    }

    pub fn deinit(self: *IssuerMismatch) void {
        self.owner_alloc.free(self.expected);
        self.owner_alloc.free(self.returned);
        self.* = undefined;
    }
};

pub const AuthorizationResult = union(enum) {
    credentials: Credentials,
    issuer_mismatch: IssuerMismatch,
};

pub const AuthenticationResult = union(enum) {
    authenticated: struct {
        repaired_entries: usize = 0,
    },
    issuer_mismatch: IssuerMismatch,

    pub fn deinit(self: *AuthenticationResult) void {
        switch (self.*) {
            .authenticated => {},
            .issuer_mismatch => |*mismatch| mismatch.deinit(),
        }
        self.* = undefined;
    }
};

pub const AutomatedAuthorizationOptions = struct {
    endpoint: []const u8,
    challenge: Challenge,
    config: ClientConfig = .{},
    previous_scope: ?[]const u8 = null,
    cancel_flag: ?*const std.atomic.Value(bool) = null,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool) = null,

    fn cancellation(self: AutomatedAuthorizationOptions) operation_control.CancellationSources {
        return .{
            .caller = self.cancel_flag,
            .runtime = self.lifecycle_cancel_flag,
        };
    }
};

pub const OpenUrlFn = *const fn (
    ctx: ?*anyopaque,
    alloc: Allocator,
    url: []const u8,
) anyerror!bool;

pub const InteractiveAuthorizationOptions = struct {
    endpoint: []const u8,
    challenge: Challenge,
    config: ClientConfig = .{},
    previous_scope: ?[]const u8 = null,
    open_ctx: ?*anyopaque = null,
    open_url: OpenUrlFn,
    cancel_flag: ?*const std.atomic.Value(bool) = null,
    lifecycle_cancel_flag: ?*const std.atomic.Value(bool) = null,
};

pub const ResourceMetadata = struct {
    resource: []u8,
    authorization_servers: [][]u8,
    scopes_supported: [][]u8,

    pub fn deinit(self: *ResourceMetadata, alloc: Allocator) void {
        alloc.free(self.resource);
        freeStrings(alloc, self.authorization_servers);
        freeStrings(alloc, self.scopes_supported);
        self.* = undefined;
    }
};

pub const AuthorizationMetadata = struct {
    issuer: []u8,
    authorization_endpoint: []u8,
    token_endpoint: []u8,
    registration_endpoint: ?[]u8,
    revocation_endpoint: ?[]u8,
    scopes_supported: [][]u8,
    grant_types_supported: [][]u8,
    token_endpoint_auth_methods_supported: [][]u8,
    code_challenge_methods_supported: [][]u8,
    client_id_metadata_document_supported: bool,
    authorization_response_iss_parameter_supported: bool,

    pub fn deinit(self: *AuthorizationMetadata, alloc: Allocator) void {
        alloc.free(self.issuer);
        alloc.free(self.authorization_endpoint);
        alloc.free(self.token_endpoint);
        if (self.registration_endpoint) |value| alloc.free(value);
        if (self.revocation_endpoint) |value| alloc.free(value);
        freeStrings(alloc, self.scopes_supported);
        freeStrings(alloc, self.grant_types_supported);
        freeStrings(alloc, self.token_endpoint_auth_methods_supported);
        freeStrings(alloc, self.code_challenge_methods_supported);
        self.* = undefined;
    }

    pub fn supports(self: AuthorizationMetadata, field: enum {
        s256,
        refresh_token,
        client_secret_basic,
        client_secret_post,
        none,
    }) bool {
        return switch (field) {
            .s256 => contains(self.code_challenge_methods_supported, "S256"),
            .refresh_token => contains(self.grant_types_supported, "refresh_token"),
            .client_secret_basic => contains(self.token_endpoint_auth_methods_supported, "client_secret_basic"),
            .client_secret_post => contains(self.token_endpoint_auth_methods_supported, "client_secret_post"),
            .none => contains(self.token_endpoint_auth_methods_supported, "none"),
        };
    }
};

pub const AuthorizationResponse = struct {
    code: []u8,
    state: []u8,
    issuer: ?[]u8,

    pub fn deinit(self: *AuthorizationResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.code);
        secret.zeroAndFree(alloc, self.state);
        if (self.issuer) |value| alloc.free(value);
        self.* = undefined;
    }
};

/// Returns all WWW-Authenticate field values as one owned challenge list.
pub fn collectAuthenticateHeader(
    alloc: Allocator,
    head: std.http.Client.Response.Head,
) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var found = false;
    var iterator = head.iterateHeaders();
    while (iterator.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "www-authenticate")) continue;
        const value = std.mem.trim(u8, header.value, " \t\r\n");
        if (found) try out.writer.writeAll(", ");
        try out.writer.writeAll(value);
        found = true;
    }
    return if (found) try out.toOwnedSlice() else null;
}

pub fn parseChallenge(alloc: Allocator, value: []const u8) !Challenge {
    var result: Challenge = .{};
    errdefer result.deinit(alloc);

    var cursor = findBearerParameters(value) orelse return result;
    while (cursor < value.len) {
        while (cursor < value.len and
            (value[cursor] == ' ' or value[cursor] == '\t' or value[cursor] == ','))
        {
            cursor += 1;
        }
        const key_start = cursor;
        while (cursor < value.len and (std.ascii.isAlphanumeric(value[cursor]) or
            value[cursor] == '_' or value[cursor] == '-'))
        {
            cursor += 1;
        }
        if (cursor == key_start) break;
        const key = value[key_start..cursor];
        while (cursor < value.len and (value[cursor] == ' ' or value[cursor] == '\t')) cursor += 1;
        if (cursor >= value.len or value[cursor] != '=') break;
        cursor += 1;
        while (cursor < value.len and (value[cursor] == ' ' or value[cursor] == '\t')) cursor += 1;
        const parsed = try parseChallengeValue(alloc, value, &cursor);
        if (std.ascii.eqlIgnoreCase(key, "resource_metadata")) {
            if (result.resource_metadata) |old| alloc.free(old);
            result.resource_metadata = parsed;
        } else if (std.ascii.eqlIgnoreCase(key, "scope")) {
            if (result.scope) |old| alloc.free(old);
            result.scope = parsed;
        } else {
            if (std.ascii.eqlIgnoreCase(key, "error") and
                std.mem.eql(u8, parsed, "insufficient_scope"))
            {
                result.insufficient_scope = true;
            }
            alloc.free(parsed);
        }
    }
    return result;
}

fn findBearerParameters(value: []const u8) ?usize {
    const scheme = "bearer";
    if (value.len < scheme.len) return null;
    for (0..value.len - scheme.len + 1) |index| {
        if (!std.ascii.eqlIgnoreCase(value[index..][0..scheme.len], scheme)) {
            continue;
        }
        if (index > 0 and value[index - 1] != ',' and
            value[index - 1] != ' ' and value[index - 1] != '\t')
        {
            continue;
        }
        const after = index + scheme.len;
        if (after < value.len and value[after] != ' ' and value[after] != '\t') {
            continue;
        }
        return after;
    }
    return null;
}

fn parseChallengeValue(alloc: Allocator, input: []const u8, cursor: *usize) ![]u8 {
    if (cursor.* >= input.len) return error.InvalidAuthenticateChallenge;
    if (input[cursor.*] != '"') {
        const start = cursor.*;
        while (cursor.* < input.len and input[cursor.*] != ',' and input[cursor.*] != ' ') cursor.* += 1;
        return alloc.dupe(u8, input[start..cursor.*]);
    }

    cursor.* += 1;
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    while (cursor.* < input.len) {
        const byte = input[cursor.*];
        cursor.* += 1;
        if (byte == '"') return out.toOwnedSlice();
        if (byte == '\\') {
            if (cursor.* >= input.len) return error.InvalidAuthenticateChallenge;
            try out.writer.writeByte(input[cursor.*]);
            cursor.* += 1;
        } else {
            try out.writer.writeByte(byte);
        }
    }
    return error.InvalidAuthenticateChallenge;
}

pub fn canonicalResource(alloc: Allocator, endpoint: []const u8) ![]u8 {
    const uri = std.Uri.parse(endpoint) catch return error.InvalidMcpAuthEndpoint;
    if (uri.user != null or uri.password != null or uri.fragment != null) {
        return error.InvalidMcpAuthEndpoint;
    }
    if (!isSecureOrLoopback(uri)) return error.InsecureMcpAuthEndpoint;
    const origin = try originAlloc(alloc, uri);
    defer alloc.free(origin);
    const path = rawPathAlloc(alloc, uri) catch return error.InvalidMcpAuthEndpoint;
    defer alloc.free(path);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ origin, path });
}

pub fn isLoopbackEndpoint(endpoint: []const u8) bool {
    const uri = std.Uri.parse(endpoint) catch return false;
    return isLoopbackUri(uri);
}

fn isLoopbackUri(uri: std.Uri) bool {
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.port == null) return false;
    return isLoopbackHost(uri);
}

fn isLoopbackHost(uri: std.Uri) bool {
    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

pub fn protectedResourceMetadataUrls(
    alloc: Allocator,
    resource: []const u8,
) ![][]u8 {
    const uri = std.Uri.parse(resource) catch return error.InvalidMcpAuthEndpoint;
    const origin = try originAlloc(alloc, uri);
    defer alloc.free(origin);
    const path = rawPathAlloc(alloc, uri) catch return error.InvalidMcpAuthEndpoint;
    defer alloc.free(path);

    var urls: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(alloc, &urls);
    if (!std.mem.eql(u8, path, "/")) {
        const suffix = if (path[0] == '/') path else try std.fmt.allocPrint(alloc, "/{s}", .{path});
        defer if (suffix.ptr != path.ptr) alloc.free(suffix);
        try urls.append(alloc, try std.fmt.allocPrint(
            alloc,
            "{s}/.well-known/oauth-protected-resource{s}",
            .{ origin, suffix },
        ));
    }
    try urls.append(alloc, try std.fmt.allocPrint(
        alloc,
        "{s}/.well-known/oauth-protected-resource",
        .{origin},
    ));
    return urls.toOwnedSlice(alloc);
}

pub fn authorizationMetadataUrls(
    alloc: Allocator,
    issuer: []const u8,
) ![][]u8 {
    const uri = std.Uri.parse(issuer) catch return error.InvalidAuthorizationIssuer;
    if (!isSecureOrLoopback(uri) or uri.query != null or uri.fragment != null) {
        return error.InvalidAuthorizationIssuer;
    }
    const origin = try originAlloc(alloc, uri);
    defer alloc.free(origin);
    const path = try rawPathAlloc(alloc, uri);
    defer alloc.free(path);
    const trimmed_path = std.mem.trim(u8, path, "/");

    var urls: std.ArrayList([]u8) = .empty;
    errdefer freeStringList(alloc, &urls);
    if (trimmed_path.len == 0) {
        try urls.append(alloc, try std.fmt.allocPrint(
            alloc,
            "{s}/.well-known/oauth-authorization-server",
            .{origin},
        ));
        try urls.append(alloc, try std.fmt.allocPrint(
            alloc,
            "{s}/.well-known/openid-configuration",
            .{origin},
        ));
    } else {
        try urls.append(alloc, try std.fmt.allocPrint(
            alloc,
            "{s}/.well-known/oauth-authorization-server/{s}",
            .{ origin, trimmed_path },
        ));
        try urls.append(alloc, try std.fmt.allocPrint(
            alloc,
            "{s}/.well-known/openid-configuration/{s}",
            .{ origin, trimmed_path },
        ));
        try urls.append(alloc, try std.fmt.allocPrint(
            alloc,
            "{s}/.well-known/openid-configuration",
            .{issuer},
        ));
    }
    return urls.toOwnedSlice(alloc);
}

pub fn parseResourceMetadata(
    alloc: Allocator,
    bytes: []const u8,
    expected_resource: []const u8,
) !ResourceMetadata {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProtectedResourceMetadata;
    const object = parsed.value.object;
    const resource = try requiredString(object, "resource");
    const canonical_resource = try canonicalResource(alloc, resource);
    errdefer alloc.free(canonical_resource);
    if (!resourceCoversEndpoint(canonical_resource, expected_resource)) {
        return error.McpAuthResourceMismatch;
    }
    const authorization_servers = try dupeRequiredStringArray(
        alloc,
        object,
        "authorization_servers",
    );
    errdefer freeStrings(alloc, authorization_servers);
    if (authorization_servers.len == 0) return error.InvalidProtectedResourceMetadata;
    const scopes_supported = try dupeOptionalStringArray(alloc, object, "scopes_supported");
    errdefer freeStrings(alloc, scopes_supported);
    return .{
        .resource = canonical_resource,
        .authorization_servers = authorization_servers,
        .scopes_supported = scopes_supported,
    };
}

pub fn parseAuthorizationMetadata(
    alloc: Allocator,
    bytes: []const u8,
    expected_issuer: []const u8,
) !AuthorizationMetadata {
    return switch (try parseAuthorizationMetadataOutcome(
        alloc,
        bytes,
        expected_issuer,
    )) {
        .metadata => |metadata| metadata,
        .issuer_mismatch => |owned_mismatch| {
            var mismatch = owned_mismatch;
            mismatch.deinit();
            return error.AuthorizationMetadataIssuerMismatch;
        },
    };
}

const AuthorizationMetadataOutcome = union(enum) {
    metadata: AuthorizationMetadata,
    issuer_mismatch: IssuerMismatch,
};

fn parseAuthorizationMetadataOutcome(
    alloc: Allocator,
    bytes: []const u8,
    expected_issuer: []const u8,
) !AuthorizationMetadataOutcome {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthorizationMetadata;
    const object = parsed.value.object;
    const issuer = try requiredString(object, "issuer");
    if (!std.mem.eql(u8, issuer, expected_issuer)) {
        return .{ .issuer_mismatch = try IssuerMismatch.init(
            alloc,
            .authorization_metadata,
            expected_issuer,
            issuer,
        ) };
    }
    const authorization_endpoint = try dupeRequiredUrl(alloc, object, "authorization_endpoint");
    errdefer alloc.free(authorization_endpoint);
    const token_endpoint = try dupeRequiredUrl(alloc, object, "token_endpoint");
    errdefer alloc.free(token_endpoint);
    const registration_endpoint = try dupeOptionalUrl(alloc, object, "registration_endpoint");
    errdefer if (registration_endpoint) |value| alloc.free(value);
    const revocation_endpoint = try dupeOptionalUrl(alloc, object, "revocation_endpoint");
    errdefer if (revocation_endpoint) |value| alloc.free(value);
    const scopes_supported = try dupeOptionalStringArray(alloc, object, "scopes_supported");
    errdefer freeStrings(alloc, scopes_supported);
    const grant_types_supported = try dupeOptionalStringArray(alloc, object, "grant_types_supported");
    errdefer freeStrings(alloc, grant_types_supported);
    const token_endpoint_auth_methods_supported = try dupeOptionalStringArrayDefault(
        alloc,
        object,
        "token_endpoint_auth_methods_supported",
        "client_secret_basic",
    );
    errdefer freeStrings(alloc, token_endpoint_auth_methods_supported);
    const code_challenge_methods_supported = try dupeOptionalStringArray(
        alloc,
        object,
        "code_challenge_methods_supported",
    );
    errdefer freeStrings(alloc, code_challenge_methods_supported);
    return .{ .metadata = .{
        .issuer = try alloc.dupe(u8, issuer),
        .authorization_endpoint = authorization_endpoint,
        .token_endpoint = token_endpoint,
        .registration_endpoint = registration_endpoint,
        .revocation_endpoint = revocation_endpoint,
        .scopes_supported = scopes_supported,
        .grant_types_supported = grant_types_supported,
        .token_endpoint_auth_methods_supported = token_endpoint_auth_methods_supported,
        .code_challenge_methods_supported = code_challenge_methods_supported,
        .client_id_metadata_document_supported = optionalBool(
            object,
            "client_id_metadata_document_supported",
        ) orelse false,
        .authorization_response_iss_parameter_supported = optionalBool(
            object,
            "authorization_response_iss_parameter_supported",
        ) orelse false,
    } };
}

pub fn requestedScope(
    alloc: Allocator,
    configured: []const []const u8,
    challenge_scope: ?[]const u8,
    metadata_scopes: []const []const u8,
    previous_scope: ?[]const u8,
    request_offline_access: bool,
) !?[]u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(alloc);
    try appendScopeTokens(alloc, &tokens, previous_scope);
    if (challenge_scope) |scope| {
        try appendScopeTokens(alloc, &tokens, scope);
    } else if (configured.len > 0) {
        for (configured) |scope| try appendScopeTokens(alloc, &tokens, scope);
    } else {
        for (metadata_scopes) |scope| try appendScopeTokens(alloc, &tokens, scope);
    }
    if (request_offline_access) try appendUnique(&tokens, alloc, "offline_access");
    if (tokens.items.len == 0) return null;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (tokens.items, 0..) |token, index| {
        if (index > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(token);
    }
    return try out.toOwnedSlice();
}

pub fn validateAuthorizationResponse(
    expected_state: []const u8,
    expected_issuer: []const u8,
    issuer_parameter_required: bool,
    response: AuthorizationResponse,
) !void {
    if (!std.mem.eql(u8, expected_state, response.state)) return error.OAuthStateMismatch;
    if (issuer_parameter_required and response.issuer == null) {
        return error.AuthorizationResponseIssuerMissing;
    }
    if (response.issuer) |issuer| {
        if (!std.mem.eql(u8, expected_issuer, issuer)) {
            return error.AuthorizationResponseIssuerMismatch;
        }
    }
}

pub fn parseAuthorizationRedirect(
    alloc: Allocator,
    location: []const u8,
) !AuthorizationResponse {
    const question = std.mem.indexOfScalar(u8, location, '?') orelse
        return error.InvalidAuthorizationRedirect;
    const fragment = std.mem.indexOfScalarPos(u8, location, question + 1, '#') orelse location.len;
    const query = location[question + 1 .. fragment];
    const code = try queryValueAlloc(alloc, query, "code");
    errdefer secret.zeroAndFree(alloc, code);
    const state = try queryValueAlloc(alloc, query, "state");
    errdefer secret.zeroAndFree(alloc, state);
    const issuer = queryValueAlloc(alloc, query, "iss") catch |err| switch (err) {
        error.MissingQueryParameter => null,
        else => return err,
    };
    return .{ .code = code, .state = state, .issuer = issuer };
}

fn encodeBase64UrlNoPad(output: []u8, input: []const u8) []const u8 {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const complete_groups = input.len / 3;
    const remainder = input.len % 3;
    const tail_len: usize = switch (remainder) {
        0 => 0,
        1 => 2,
        2 => 3,
        else => unreachable,
    };
    const encoded_len = complete_groups * 4 + tail_len;
    std.debug.assert(output.len >= encoded_len);

    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index + 3 <= input.len) : (input_index += 3) {
        const value = (@as(u24, input[input_index]) << 16) |
            (@as(u24, input[input_index + 1]) << 8) |
            input[input_index + 2];
        output[output_index] = alphabet[(value >> 18) & 0x3f];
        output[output_index + 1] = alphabet[(value >> 12) & 0x3f];
        output[output_index + 2] = alphabet[(value >> 6) & 0x3f];
        output[output_index + 3] = alphabet[value & 0x3f];
        output_index += 4;
    }
    if (remainder != 0) {
        const value = @as(u24, input[input_index]) << 16 |
            (if (remainder == 2) @as(u24, input[input_index + 1]) << 8 else 0);
        output[output_index] = alphabet[(value >> 18) & 0x3f];
        output[output_index + 1] = alphabet[(value >> 12) & 0x3f];
        if (remainder == 2) {
            output[output_index + 2] = alphabet[(value >> 6) & 0x3f];
        }
    }
    return output[0..encoded_len];
}

pub fn generatePkce(
    verifier_buf: *[64]u8,
    challenge_buf: *[43]u8,
    random: std.Random,
) struct { verifier: []const u8, challenge: []const u8 } {
    var entropy: [48]u8 = undefined;
    random.bytes(&entropy);
    const verifier = encodeBase64UrlNoPad(verifier_buf, &entropy);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const challenge = encodeBase64UrlNoPad(challenge_buf, &digest);
    return .{ .verifier = verifier, .challenge = challenge };
}

test "PKCE base64url encoding covers complete and partial groups" {
    const cases = .{
        .{ "", "" },
        .{ "f", "Zg" },
        .{ "fo", "Zm8" },
        .{ "foo", "Zm9v" },
        .{ &[_]u8{ 0xfb, 0xef, 0xff }, "--__" },
    };
    inline for (cases) |case| {
        var output: [64]u8 = undefined;
        try std.testing.expectEqualStrings(
            case[1],
            encodeBase64UrlNoPad(&output, case[0]),
        );
    }
}

pub fn bearerHeaderAlloc(alloc: Allocator, access_token: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "Bearer {s}", .{access_token});
}

pub fn validateClientMetadataUrl(url: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidClientMetadataUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.host == null or
        uri.user != null or uri.password != null or uri.fragment != null)
    {
        return error.InvalidClientMetadataUrl;
    }
    var path_buffer: [4096]u8 = undefined;
    const path = uri.path.toRaw(&path_buffer) catch
        return error.InvalidClientMetadataUrl;
    if (std.mem.trim(u8, path, "/").len == 0) {
        return error.InvalidClientMetadataUrl;
    }
}

pub fn refreshCredentials(
    alloc: Allocator,
    credentials: Credentials,
    control: RefreshControl,
) !Credentials {
    const cancellation = control.cancellation();
    if (cancellation.cancelled()) return error.Cancelled;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    if (!std.Io.Clock.Timestamp.compare(now, .lt, control.deadline)) {
        return error.McpRequestTimedOut;
    }

    const Operation = struct {
        alloc: Allocator,
        credentials: Credentials,

        fn run(self: @This()) anyerror!Credentials {
            return refreshCredentialsCore(self.alloc, self.credentials);
        }
    };
    const Event = union(enum) {
        refresh: anyerror!Credentials,
        cancelled: anyerror!void,
        deadline: anyerror!void,
    };
    const Cleanup = struct {
        fn drain(result_alloc: Allocator, select: *std.Io.Select(Event)) void {
            while (select.cancel()) |item| switch (item) {
                .refresh => |result| {
                    var refreshed = result catch continue;
                    refreshed.deinit(result_alloc);
                },
                .cancelled, .deadline => {},
            };
        }
    };

    var select_buffer: [3]Event = undefined;
    var select: std.Io.Select(Event) = .init(io_mod.getIo(), &select_buffer);
    select.concurrent(.cancelled, waitForRefreshCancellation, .{cancellation}) catch |err|
        return err;
    select.concurrent(.deadline, waitForRefreshDeadline, .{control.deadline}) catch |err| {
        select.cancelDiscard();
        return err;
    };
    select.concurrent(.refresh, Operation.run, .{Operation{
        .alloc = alloc,
        .credentials = credentials,
    }}) catch |err| {
        select.cancelDiscard();
        return err;
    };

    const event = select.await() catch |err| {
        Cleanup.drain(alloc, &select);
        return err;
    };
    switch (event) {
        .refresh => |result| {
            Cleanup.drain(alloc, &select);
            if (cancellation.cancelled()) {
                var refreshed = result catch return error.Cancelled;
                refreshed.deinit(alloc);
                return error.Cancelled;
            }
            return result;
        },
        .cancelled => |result| {
            result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            return error.Cancelled;
        },
        .deadline => |result| {
            result catch |err| {
                Cleanup.drain(alloc, &select);
                return err;
            };
            Cleanup.drain(alloc, &select);
            if (cancellation.cancelled()) return error.Cancelled;
            return error.McpRequestTimedOut;
        },
    }
}

fn refreshCredentialsCore(
    alloc: Allocator,
    credentials: Credentials,
) !Credentials {
    const refresh_token = credentials.refresh_token orelse
        return error.McpRefreshTokenMissing;
    var form_writer: std.Io.Writer.Allocating = .init(alloc);
    defer {
        @memset(form_writer.written(), 0);
        form_writer.deinit();
    }
    var form: Form = .{};
    try form.append(&form_writer.writer, "grant_type", "refresh_token");
    try form.append(&form_writer.writer, "refresh_token", refresh_token);
    try form.append(&form_writer.writer, "resource", credentials.resource);

    var auth = try tokenEndpointAuthentication(
        alloc,
        &form,
        &form_writer.writer,
        credentials.token_endpoint_auth_method,
        credentials.client_id,
        credentials.client_secret,
    );
    defer auth.deinit(alloc);
    var response = try request(
        alloc,
        .POST,
        credentials.token_endpoint,
        form_writer.written(),
        "application/x-www-form-urlencoded",
        auth.headers(),
    );
    defer response.deinit(alloc);
    if (response.status != .ok) return error.McpRefreshRejected;
    try validateJsonContentType(response.content_type);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTokenResponse;
    const object = parsed.value.object;
    const access_token = try dupeRequiredSecret(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_replacement = try dupeOptionalSecret(alloc, object, "refresh_token");
    errdefer if (refresh_replacement) |value| secret.zeroAndFree(alloc, value);
    const scope_replacement = try dupeOptionalString(alloc, object, "scope");
    errdefer if (scope_replacement) |value| alloc.free(value);
    const token_type_replacement = try dupeOptionalString(alloc, object, "token_type");
    errdefer if (token_type_replacement) |value| alloc.free(value);
    if (token_type_replacement) |value| {
        if (!std.ascii.eqlIgnoreCase(value, "Bearer")) {
            return error.InvalidTokenResponse;
        }
    }
    const expires_at_ms = try tokenExpiresAt(object, io_mod.milliTimestamp());

    var next = try credentials.clone(alloc);
    errdefer next.deinit(alloc);
    secret.zeroAndFree(alloc, next.access_token);
    next.access_token = access_token;
    if (refresh_replacement) |value| {
        if (next.refresh_token) |old| secret.zeroAndFree(alloc, old);
        next.refresh_token = value;
    }
    if (scope_replacement) |value| {
        alloc.free(next.scope);
        next.scope = value;
    }
    if (token_type_replacement) |value| {
        alloc.free(next.token_type);
        next.token_type = value;
    }
    next.expires_at_ms = expires_at_ms;
    return next;
}

fn waitForRefreshCancellation(
    cancellation: operation_control.CancellationSources,
) anyerror!void {
    while (!cancellation.cancelled()) {
        try io_mod.getIo().sleep(.fromMilliseconds(5), .awake);
    }
}

fn waitForRefreshDeadline(deadline: std.Io.Clock.Timestamp) anyerror!void {
    try deadline.wait(io_mod.getIo());
}

pub fn revokeCredentials(alloc: Allocator, credentials: Credentials) !void {
    const endpoint = credentials.revocation_endpoint orelse
        return error.RevocationEndpointMissing;
    var first_error: ?anyerror = null;
    if (credentials.refresh_token) |token| {
        revokeToken(
            alloc,
            credentials,
            endpoint,
            token,
            "refresh_token",
        ) catch |err| {
            first_error = err;
        };
    }
    revokeToken(
        alloc,
        credentials,
        endpoint,
        credentials.access_token,
        "access_token",
    ) catch |err| if (first_error == null) {
        first_error = err;
    };
    if (first_error) |err| return err;
}

pub fn authorizeAutomated(
    alloc: Allocator,
    options: AutomatedAuthorizationOptions,
) !AuthorizationResult {
    return authorizeWithRedirect(
        alloc,
        options,
        "http://localhost:3000/callback",
        null,
        requestAutomatedAuthorization,
    );
}

pub fn authorizeInteractive(
    alloc: Allocator,
    options: InteractiveAuthorizationOptions,
) !AuthorizationResult {
    if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.InteractiveMcpAuthorizationUnsupported;
    }
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io_mod.getIo(), .{ .reuse_address = true });
    defer listener.deinit(io_mod.getIo());
    const redirect_uri = try std.fmt.allocPrint(
        alloc,
        "http://127.0.0.1:{d}/callback",
        .{listener.socket.address.getPort()},
    );
    defer alloc.free(redirect_uri);
    var context = InteractiveAuthorizationContext{
        .listener = &listener,
        .open_ctx = options.open_ctx,
        .open_url = options.open_url,
        .cancellation = .{
            .caller = options.cancel_flag,
            .runtime = options.lifecycle_cancel_flag,
        },
    };
    return authorizeWithRedirect(
        alloc,
        .{
            .endpoint = options.endpoint,
            .challenge = options.challenge,
            .config = options.config,
            .previous_scope = options.previous_scope,
            .cancel_flag = options.cancel_flag,
            .lifecycle_cancel_flag = options.lifecycle_cancel_flag,
        },
        redirect_uri,
        &context,
        requestInteractiveAuthorization,
    );
}

const AuthorizationRequestFn = *const fn (
    ctx: ?*anyopaque,
    alloc: Allocator,
    authorization_url: []const u8,
    redirect_uri: []const u8,
) anyerror!AuthorizationResponse;

fn authorizeWithRedirect(
    alloc: Allocator,
    options: AutomatedAuthorizationOptions,
    redirect_uri: []const u8,
    authorization_ctx: ?*anyopaque,
    request_authorization: AuthorizationRequestFn,
) !AuthorizationResult {
    try checkAuthorizationCancellation(options.cancellation());
    const endpoint = try canonicalResource(alloc, options.endpoint);
    errdefer alloc.free(endpoint);
    var resource = if (options.config.resource) |configured|
        try canonicalResource(alloc, configured)
    else
        try alloc.dupe(u8, endpoint);
    errdefer alloc.free(resource);

    var prm = try discoverResourceMetadata(
        alloc,
        resource,
        options.challenge.resource_metadata,
    );
    defer prm.deinit(alloc);
    try checkAuthorizationCancellation(options.cancellation());
    if (!std.mem.eql(u8, resource, prm.resource)) {
        alloc.free(resource);
        resource = try alloc.dupe(u8, prm.resource);
    }
    const issuer = options.config.issuer orelse prm.authorization_servers[0];
    try validateOAuthUrlForResource(issuer, resource);
    var metadata = switch (try discoverAuthorizationMetadata(alloc, issuer)) {
        .metadata => |value| value,
        .issuer_mismatch => |mismatch| return .{ .issuer_mismatch = mismatch },
    };
    defer metadata.deinit(alloc);
    try checkAuthorizationCancellation(options.cancellation());
    try validateAuthorizationMetadataUrls(metadata, resource);
    if (!metadata.supports(.s256)) return error.PkceS256NotSupported;

    var registration = try resolveClientRegistration(
        alloc,
        metadata,
        resource,
        options.config,
        redirect_uri,
    );
    defer registration.deinit(alloc);
    try checkAuthorizationCancellation(options.cancellation());

    const scope = try requestedScope(
        alloc,
        options.config.scopes,
        options.challenge.scope,
        prm.scopes_supported,
        options.previous_scope,
        contains(metadata.scopes_supported, "offline_access"),
    );
    defer if (scope) |value| alloc.free(value);

    var verifier_entropy: [48]u8 = undefined;
    try io_mod.getIo().randomSecure(&verifier_entropy);
    var verifier_buf: [64]u8 = undefined;
    const verifier = encodeBase64UrlNoPad(
        &verifier_buf,
        &verifier_entropy,
    );
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var challenge_buf: [43]u8 = undefined;
    const code_challenge = encodeBase64UrlNoPad(
        &challenge_buf,
        &digest,
    );
    var state_entropy: [32]u8 = undefined;
    try io_mod.getIo().randomSecure(&state_entropy);
    var state_buf: [43]u8 = undefined;
    const state = encodeBase64UrlNoPad(
        &state_buf,
        &state_entropy,
    );

    const authorization_url = try buildAuthorizationUrl(
        alloc,
        metadata.authorization_endpoint,
        registration.client_id,
        redirect_uri,
        resource,
        state,
        code_challenge,
        scope,
    );
    defer secret.zeroAndFree(alloc, authorization_url);
    try checkAuthorizationCancellation(options.cancellation());
    var callback = try request_authorization(
        authorization_ctx,
        alloc,
        authorization_url,
        redirect_uri,
    );
    defer callback.deinit(alloc);
    try checkAuthorizationCancellation(options.cancellation());
    validateAuthorizationResponse(
        state,
        metadata.issuer,
        metadata.authorization_response_iss_parameter_supported,
        callback,
    ) catch |err| switch (err) {
        error.AuthorizationResponseIssuerMismatch => return .{
            .issuer_mismatch = try IssuerMismatch.init(
                alloc,
                .authorization_response,
                metadata.issuer,
                callback.issuer.?,
            ),
        },
        else => return err,
    };

    var grant = try exchangeAuthorizationCode(
        alloc,
        metadata,
        registration,
        callback.code,
        verifier,
        redirect_uri,
        resource,
        scope,
    );
    errdefer grant.deinit(alloc);
    try checkAuthorizationCancellation(options.cancellation());
    const owned_issuer = try alloc.dupe(u8, metadata.issuer);
    errdefer alloc.free(owned_issuer);
    const authorization_endpoint = try alloc.dupe(u8, metadata.authorization_endpoint);
    errdefer alloc.free(authorization_endpoint);
    const token_endpoint = try alloc.dupe(u8, metadata.token_endpoint);
    errdefer alloc.free(token_endpoint);
    const revocation_endpoint = if (metadata.revocation_endpoint) |value|
        try alloc.dupe(u8, value)
    else
        null;
    const credentials = Credentials{
        .endpoint = endpoint,
        .resource = resource,
        .issuer = owned_issuer,
        .client_id = grant.client_id,
        .client_secret = grant.client_secret,
        .access_token = grant.access_token,
        .refresh_token = grant.refresh_token,
        .scope = grant.scope,
        .token_type = grant.token_type,
        .token_endpoint_auth_method = grant.token_endpoint_auth_method,
        .expires_at_ms = grant.expires_at_ms,
        .authorization_endpoint = authorization_endpoint,
        .token_endpoint = token_endpoint,
        .revocation_endpoint = revocation_endpoint,
    };
    grant = undefined;
    return .{ .credentials = credentials };
}

fn requestAutomatedAuthorization(
    _: ?*anyopaque,
    alloc: Allocator,
    authorization_url: []const u8,
    redirect_uri: []const u8,
) !AuthorizationResponse {
    var response = try request(
        alloc,
        .GET,
        authorization_url,
        null,
        null,
        &.{},
    );
    defer response.deinit(alloc);
    if (response.status.class() != .redirect) {
        return error.AuthorizationRedirectMissing;
    }
    const location = response.location orelse
        return error.AuthorizationRedirectMissing;
    try validateRedirectTarget(location, redirect_uri);
    return parseAuthorizationRedirect(alloc, location);
}

const InteractiveAuthorizationContext = struct {
    listener: *std.Io.net.Server,
    open_ctx: ?*anyopaque,
    open_url: OpenUrlFn,
    cancellation: operation_control.CancellationSources,
};

const interactive_callback_timeout_ms: i32 = 5 * 60 * 1000;
const interactive_callback_poll_ms: i32 = 50;

fn checkAuthorizationCancellation(
    cancellation: operation_control.CancellationSources,
) !void {
    if (cancellation.cancelled()) return error.Cancelled;
}

fn waitForInteractiveCallback(
    listener: *std.Io.net.Server,
    cancellation: operation_control.CancellationSources,
) !void {
    var fds = [_]std.posix.pollfd{.{
        .fd = listener.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    var remaining_ms = interactive_callback_timeout_ms;
    while (remaining_ms > 0) {
        try checkAuthorizationCancellation(cancellation);
        fds[0].revents = 0;
        const wait_ms = @min(remaining_ms, interactive_callback_poll_ms);
        const ready = try std.posix.poll(&fds, wait_ms);
        if (ready > 0) {
            if ((fds[0].revents & std.posix.POLL.IN) == 0) {
                return error.McpAuthorizationCallbackTimedOut;
            }
            try checkAuthorizationCancellation(cancellation);
            return;
        }
        remaining_ms -= wait_ms;
    }
    return error.McpAuthorizationCallbackTimedOut;
}

fn requestInteractiveAuthorization(
    raw_ctx: ?*anyopaque,
    alloc: Allocator,
    authorization_url: []const u8,
    _: []const u8,
) !AuthorizationResponse {
    const ctx: *InteractiveAuthorizationContext = @ptrCast(@alignCast(raw_ctx.?));
    try checkAuthorizationCancellation(ctx.cancellation);
    if (!try ctx.open_url(ctx.open_ctx, alloc, authorization_url)) {
        return error.McpAuthorizationBrowserOpenFailed;
    }
    try waitForInteractiveCallback(ctx.listener, ctx.cancellation);

    var stream = try ctx.listener.accept(io_mod.getIo());
    defer stream.close(io_mod.getIo());
    setSocketTimeouts(stream.socket.handle, callback_io_timeout_seconds);
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &socket_buffer);
    var request_bytes: [16 * 1024]u8 = undefined;
    var request_len: usize = 0;
    while (request_len < request_bytes.len) {
        request_bytes[request_len] = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return error.InvalidAuthorizationCallback,
            else => return err,
        };
        request_len += 1;
        if (std.mem.endsWith(u8, request_bytes[0..request_len], "\r\n\r\n")) break;
    }
    if (request_len == request_bytes.len) return error.AuthorizationCallbackTooLarge;
    const line_end = std.mem.indexOf(u8, request_bytes[0..request_len], "\r\n") orelse
        return error.InvalidAuthorizationCallback;
    const request_line = request_bytes[0..line_end];
    if (!std.mem.startsWith(u8, request_line, "GET ")) {
        return error.InvalidAuthorizationCallback;
    }
    const target_end = std.mem.indexOfScalarPos(u8, request_line, 4, ' ') orelse
        return error.InvalidAuthorizationCallback;
    const target = request_line[4..target_end];
    if (!std.mem.startsWith(u8, target, "/callback?")) {
        return error.InvalidAuthorizationCallback;
    }
    var response = parseAuthorizationRedirect(alloc, target) catch |err| {
        browser_callback.writeResponse(stream, .failed, null) catch {};
        return err;
    };
    errdefer response.deinit(alloc);
    try browser_callback.writeResponse(stream, .ok, null);
    return response;
}

fn validateRedirectTarget(location: []const u8, redirect_uri: []const u8) !void {
    const query = std.mem.indexOfScalar(u8, location, '?') orelse
        std.mem.indexOfScalar(u8, location, '#') orelse location.len;
    if (!std.mem.eql(u8, location[0..query], redirect_uri)) {
        return error.InvalidAuthorizationCallback;
    }
}

const ClientRegistration = struct {
    client_id: []u8,
    client_secret: ?[]u8,
    token_endpoint_auth_method: []u8,

    fn deinit(self: *ClientRegistration, alloc: Allocator) void {
        alloc.free(self.client_id);
        if (self.client_secret) |value| secret.zeroAndFree(alloc, value);
        alloc.free(self.token_endpoint_auth_method);
        self.* = undefined;
    }
};

const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,
    location: ?[]u8 = null,
    content_type: ?[]u8 = null,

    fn deinit(self: *HttpResponse, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.body);
        if (self.location) |value| secret.zeroAndFree(alloc, value);
        if (self.content_type) |value| alloc.free(value);
        self.* = undefined;
    }
};

fn discoverResourceMetadata(
    alloc: Allocator,
    resource: []const u8,
    challenged_url: ?[]const u8,
) !ResourceMetadata {
    if (challenged_url) |url| {
        try validateOAuthUrlForResource(url, resource);
        var response = try request(alloc, .GET, url, null, null, &.{});
        defer response.deinit(alloc);
        if (response.status != .ok) return error.ProtectedResourceMetadataUnavailable;
        try validateJsonContentType(response.content_type);
        return parseResourceMetadata(alloc, response.body, resource);
    }

    const urls = try protectedResourceMetadataUrls(alloc, resource);
    defer freeStrings(alloc, urls);
    for (urls) |url| {
        var response = request(alloc, .GET, url, null, null, &.{}) catch continue;
        defer response.deinit(alloc);
        if (response.status != .ok) continue;
        try validateJsonContentType(response.content_type);
        return parseResourceMetadata(alloc, response.body, resource);
    }
    return error.ProtectedResourceMetadataUnavailable;
}

fn discoverAuthorizationMetadata(
    alloc: Allocator,
    issuer: []const u8,
) !AuthorizationMetadataOutcome {
    const urls = try authorizationMetadataUrls(alloc, issuer);
    defer freeStrings(alloc, urls);
    for (urls) |url| {
        var response = request(alloc, .GET, url, null, null, &.{}) catch continue;
        defer response.deinit(alloc);
        if (response.status != .ok) continue;
        try validateJsonContentType(response.content_type);
        return parseAuthorizationMetadataOutcome(alloc, response.body, issuer);
    }
    return error.AuthorizationMetadataUnavailable;
}

fn resolveClientRegistration(
    alloc: Allocator,
    metadata: AuthorizationMetadata,
    resource: []const u8,
    config: ClientConfig,
    redirect_uri: []const u8,
) !ClientRegistration {
    if (config.client_id) |client_id| {
        const owned_client_id = try alloc.dupe(u8, client_id);
        errdefer alloc.free(owned_client_id);
        const client_secret = if (config.client_secret) |value|
            try alloc.dupe(u8, value)
        else
            null;
        errdefer if (client_secret) |value| secret.zeroAndFree(alloc, value);
        const auth_method = try alloc.dupe(
            u8,
            try chooseTokenEndpointAuthMethod(
                metadata,
                config.client_secret != null,
            ),
        );
        return .{
            .client_id = owned_client_id,
            .client_secret = client_secret,
            .token_endpoint_auth_method = auth_method,
        };
    }
    if (metadata.client_id_metadata_document_supported) {
        if (config.client_metadata_url) |url| {
            try validateOAuthUrlForResource(url, resource);
            const client_id = try alloc.dupe(u8, url);
            errdefer alloc.free(client_id);
            return .{
                .client_id = client_id,
                .client_secret = null,
                .token_endpoint_auth_method = try alloc.dupe(
                    u8,
                    try chooseTokenEndpointAuthMethod(metadata, false),
                ),
            };
        }
    }
    const registration_endpoint = metadata.registration_endpoint orelse
        return error.ClientRegistrationUnavailable;
    const auth_method = try chooseTokenEndpointAuthMethod(metadata, false);
    var payload: std.Io.Writer.Allocating = .init(alloc);
    defer payload.deinit();
    try payload.writer.writeAll(
        "{\"client_name\":\"fx\",\"application_type\":\"native\",\"redirect_uris\":[",
    );
    try std.json.Stringify.value(redirect_uri, .{}, &payload.writer);
    try payload.writer.writeAll("],\"response_types\":[\"code\"],\"grant_types\":[\"authorization_code\"");
    if (metadata.supports(.refresh_token)) {
        try payload.writer.writeAll(",\"refresh_token\"");
    }
    try payload.writer.writeAll("],\"token_endpoint_auth_method\":");
    try std.json.Stringify.value(auth_method, .{}, &payload.writer);
    try payload.writer.writeByte('}');

    var response = try request(
        alloc,
        .POST,
        registration_endpoint,
        payload.written(),
        "application/json",
        &.{},
    );
    defer response.deinit(alloc);
    if (response.status != .created and response.status != .ok) {
        return error.ClientRegistrationFailed;
    }
    try validateJsonContentType(response.content_type);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.ClientRegistrationFailed;
    const object = parsed.value.object;
    const client_id = try dupeRequiredSecret(alloc, object, "client_id");
    errdefer alloc.free(client_id);
    const client_secret = try dupeOptionalSecret(alloc, object, "client_secret");
    errdefer if (client_secret) |value| secret.zeroAndFree(alloc, value);
    const returned_method = if (object.get("token_endpoint_auth_method")) |value|
        if (value == .string and value.string.len > 0)
            value.string
        else
            auth_method
    else
        auth_method;
    const owned_method = try alloc.dupe(u8, returned_method);
    return .{
        .client_id = client_id,
        .client_secret = client_secret,
        .token_endpoint_auth_method = owned_method,
    };
}

fn chooseTokenEndpointAuthMethod(
    metadata: AuthorizationMetadata,
    has_secret: bool,
) ![]const u8 {
    if (has_secret and metadata.supports(.client_secret_basic)) return "client_secret_basic";
    if (has_secret and metadata.supports(.client_secret_post)) return "client_secret_post";
    if (metadata.supports(.none)) return "none";
    if (metadata.supports(.client_secret_basic)) return "client_secret_basic";
    if (metadata.supports(.client_secret_post)) return "client_secret_post";
    return error.UnsupportedTokenEndpointAuthenticationMethod;
}

fn buildAuthorizationUrl(
    alloc: Allocator,
    endpoint: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    resource: []const u8,
    state: []const u8,
    code_challenge: []const u8,
    scope: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(endpoint);
    try out.writer.writeByte(if (std.mem.indexOfScalar(u8, endpoint, '?') == null) '?' else '&');
    var form: Form = .{};
    try form.append(&out.writer, "response_type", "code");
    try form.append(&out.writer, "client_id", client_id);
    try form.append(&out.writer, "redirect_uri", redirect_uri);
    try form.append(&out.writer, "resource", resource);
    try form.append(&out.writer, "state", state);
    try form.append(&out.writer, "code_challenge", code_challenge);
    try form.append(&out.writer, "code_challenge_method", "S256");
    if (scope) |value| try form.append(&out.writer, "scope", value);
    return out.toOwnedSlice();
}

const TokenGrant = struct {
    client_id: []u8,
    client_secret: ?[]u8,
    access_token: []u8,
    refresh_token: ?[]u8,
    scope: []u8,
    token_type: []u8,
    token_endpoint_auth_method: []u8,
    expires_at_ms: i64,

    fn deinit(self: *TokenGrant, alloc: Allocator) void {
        alloc.free(self.client_id);
        if (self.client_secret) |value| secret.zeroAndFree(alloc, value);
        secret.zeroAndFree(alloc, self.access_token);
        if (self.refresh_token) |value| secret.zeroAndFree(alloc, value);
        alloc.free(self.scope);
        alloc.free(self.token_type);
        alloc.free(self.token_endpoint_auth_method);
        self.* = undefined;
    }
};

const TokenEndpointAuthentication = struct {
    authorization: ?[]u8 = null,
    header: [1]std.http.Header = undefined,

    fn deinit(self: *TokenEndpointAuthentication, alloc: Allocator) void {
        if (self.authorization) |value| secret.zeroAndFree(alloc, value);
        self.* = .{};
    }

    fn headers(self: *TokenEndpointAuthentication) []const std.http.Header {
        if (self.authorization != null) return self.header[0..1];
        return &.{};
    }
};

fn tokenEndpointAuthentication(
    alloc: Allocator,
    form: *Form,
    writer: *std.Io.Writer,
    method: []const u8,
    client_id: []const u8,
    client_secret: ?[]const u8,
) !TokenEndpointAuthentication {
    if (std.mem.eql(u8, method, "none")) {
        try form.append(writer, "client_id", client_id);
        return .{};
    }
    if (std.mem.eql(u8, method, "client_secret_post")) {
        try form.append(writer, "client_id", client_id);
        try form.append(
            writer,
            "client_secret",
            client_secret orelse return error.ClientSecretMissing,
        );
        return .{};
    }
    if (!std.mem.eql(u8, method, "client_secret_basic")) {
        return error.UnsupportedTokenEndpointAuthenticationMethod;
    }
    const value = client_secret orelse return error.ClientSecretMissing;
    var pair: std.Io.Writer.Allocating = .init(alloc);
    defer {
        @memset(pair.written(), 0);
        pair.deinit();
    }
    try percentEncode(&pair.writer, client_id);
    try pair.writer.writeByte(':');
    try percentEncode(&pair.writer, value);
    const encoded = try alloc.alloc(
        u8,
        std.base64.standard.Encoder.calcSize(pair.written().len),
    );
    defer secret.zeroAndFree(alloc, encoded);
    _ = std.base64.standard.Encoder.encode(encoded, pair.written());
    const authorization = try std.fmt.allocPrint(alloc, "Basic {s}", .{encoded});
    return .{
        .authorization = authorization,
        .header = .{.{
            .name = "Authorization",
            .value = authorization,
        }},
    };
}

fn exchangeAuthorizationCode(
    alloc: Allocator,
    metadata: AuthorizationMetadata,
    registration: ClientRegistration,
    code: []const u8,
    verifier: []const u8,
    redirect_uri: []const u8,
    resource: []const u8,
    requested_scope: ?[]const u8,
) !TokenGrant {
    var form_writer: std.Io.Writer.Allocating = .init(alloc);
    defer {
        @memset(form_writer.written(), 0);
        form_writer.deinit();
    }
    var form: Form = .{};
    try form.append(&form_writer.writer, "grant_type", "authorization_code");
    try form.append(&form_writer.writer, "code", code);
    try form.append(&form_writer.writer, "redirect_uri", redirect_uri);
    try form.append(&form_writer.writer, "code_verifier", verifier);
    try form.append(&form_writer.writer, "resource", resource);
    var auth = try tokenEndpointAuthentication(
        alloc,
        &form,
        &form_writer.writer,
        registration.token_endpoint_auth_method,
        registration.client_id,
        registration.client_secret,
    );
    defer auth.deinit(alloc);

    var response = try request(
        alloc,
        .POST,
        metadata.token_endpoint,
        form_writer.written(),
        "application/x-www-form-urlencoded",
        auth.headers(),
    );
    defer response.deinit(alloc);
    if (response.status != .ok) return error.TokenExchangeFailed;
    try validateJsonContentType(response.content_type);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTokenResponse;
    const object = parsed.value.object;
    const access_token = try dupeRequiredSecret(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeOptionalSecret(alloc, object, "refresh_token");
    errdefer if (refresh_token) |value| secret.zeroAndFree(alloc, value);
    const token_type = try dupeOptionalStringDefault(alloc, object, "token_type", "Bearer");
    errdefer alloc.free(token_type);
    if (!std.ascii.eqlIgnoreCase(token_type, "Bearer")) return error.InvalidTokenResponse;
    const scope = try dupeOptionalStringDefault(
        alloc,
        object,
        "scope",
        requested_scope orelse "",
    );
    errdefer alloc.free(scope);
    const expires_at_ms = try tokenExpiresAt(object, io_mod.milliTimestamp());

    const client_id = try alloc.dupe(u8, registration.client_id);
    errdefer alloc.free(client_id);
    const client_secret = if (registration.client_secret) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (client_secret) |value| secret.zeroAndFree(alloc, value);
    const auth_method = try alloc.dupe(
        u8,
        registration.token_endpoint_auth_method,
    );
    errdefer alloc.free(auth_method);
    return .{
        .client_id = client_id,
        .client_secret = client_secret,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .scope = scope,
        .token_type = token_type,
        .token_endpoint_auth_method = auth_method,
        .expires_at_ms = expires_at_ms,
    };
}

fn revokeToken(
    alloc: Allocator,
    credentials: Credentials,
    endpoint: []const u8,
    token: []const u8,
    hint: []const u8,
) !void {
    var form_writer: std.Io.Writer.Allocating = .init(alloc);
    defer {
        @memset(form_writer.written(), 0);
        form_writer.deinit();
    }
    var form: Form = .{};
    try form.append(&form_writer.writer, "token", token);
    try form.append(&form_writer.writer, "token_type_hint", hint);
    var auth = try tokenEndpointAuthentication(
        alloc,
        &form,
        &form_writer.writer,
        credentials.token_endpoint_auth_method,
        credentials.client_id,
        credentials.client_secret,
    );
    defer auth.deinit(alloc);
    var response = try request(
        alloc,
        .POST,
        endpoint,
        form_writer.written(),
        "application/x-www-form-urlencoded",
        auth.headers(),
    );
    defer response.deinit(alloc);
    if (response.status != .ok) return error.TokenRevocationFailed;
}

const Form = struct {
    first: bool = true,

    fn append(
        self: *Form,
        writer: *std.Io.Writer,
        key: []const u8,
        value: []const u8,
    ) !void {
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
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or
            byte == '.' or byte == '~')
        {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        }
    }
}

fn request(
    alloc: Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    content_type: ?[]const u8,
    extra_headers: []const std.http.Header,
) !HttpResponse {
    const uri = std.Uri.parse(url) catch return error.InvalidMcpAuthEndpoint;
    if (!isSecureOrLoopback(uri) or uri.user != null or
        uri.password != null or uri.fragment != null)
    {
        return error.InsecureMcpAuthEndpoint;
    }
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var http_request = try client.request(method, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = if (content_type) |value|
                .{ .override = value }
            else
                .default,
            .accept_encoding = .omit,
        },
        .extra_headers = extra_headers,
    });
    defer http_request.deinit();
    if (http_request.connection) |connection| {
        setSocketTimeouts(
            connection.stream_writer.stream.socket.handle,
            request_timeout_seconds,
        );
    }
    if (payload) |body| {
        try http_request.sendBodyComplete(@constCast(body));
    } else {
        try http_request.sendBodiless();
    }
    var response = try http_request.receiveHead(&.{});
    const location = if (response.head.location) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (location) |value| secret.zeroAndFree(alloc, value);
    const response_content_type = if (response.head.content_type) |value|
        try alloc.dupe(u8, value)
    else
        null;
    errdefer if (response_content_type) |value| alloc.free(value);
    var transfer_buffer: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    const body = reader.allocRemaining(
        alloc,
        .limited(max_document_bytes),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.McpAuthDocumentTooLarge,
        else => return err,
    };
    return .{
        .status = response.head.status,
        .body = body,
        .location = location,
        .content_type = response_content_type,
    };
}

fn validateJsonContentType(content_type: ?[]const u8) !void {
    const value = content_type orelse
        return error.InvalidOAuthResponseContentType;
    const separator = std.mem.findScalar(u8, value, ';') orelse value.len;
    const media_type = std.mem.trim(u8, value[0..separator], " \t");
    if (!std.ascii.eqlIgnoreCase(media_type, "application/json")) {
        return error.InvalidOAuthResponseContentType;
    }
}

fn setSocketTimeouts(socket: std.posix.socket_t, seconds: i64) void {
    if (comptime host_target.is_wasm) return;
    const timeout = std.posix.timeval{ .sec = seconds, .usec = 0 };
    const bytes = std.mem.asBytes(&timeout);
    std.posix.setsockopt(
        socket,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        bytes,
    ) catch |err| debug_trace.logf(
        "mcp",
        "OAuth receive timeout setup failed err={s}",
        .{@errorName(err)},
    );
    std.posix.setsockopt(
        socket,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDTIMEO,
        bytes,
    ) catch |err| debug_trace.logf(
        "mcp",
        "OAuth send timeout setup failed err={s}",
        .{@errorName(err)},
    );
}

fn dupeRequiredSecret(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]u8 {
    const value = object.get(key) orelse return error.InvalidOAuthResponse;
    if (value != .string or value.string.len == 0) return error.InvalidOAuthResponse;
    return alloc.dupe(u8, value.string);
}

fn dupeOptionalSecret(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len == 0) return error.InvalidOAuthResponse;
    return try alloc.dupe(u8, value.string);
}

fn dupeOptionalString(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidOAuthResponse;
    return try alloc.dupe(u8, value.string);
}

fn dupeOptionalStringDefault(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    default: []const u8,
) ![]u8 {
    const value = object.get(key) orelse return alloc.dupe(u8, default);
    if (value == .null) return alloc.dupe(u8, default);
    if (value != .string) return error.InvalidOAuthResponse;
    return alloc.dupe(u8, value.string);
}

fn tokenExpiresAt(object: std.json.ObjectMap, now_ms: i64) !i64 {
    const value = object.get("expires_in") orelse return std.math.maxInt(i64);
    if (value != .integer or value.integer < 0) return error.InvalidTokenResponse;
    return std.math.add(
        i64,
        now_ms,
        std.math.mul(i64, value.integer, 1000) catch std.math.maxInt(i64),
    ) catch std.math.maxInt(i64);
}

fn isSecureOrLoopback(uri: std.Uri) bool {
    return std.ascii.eqlIgnoreCase(uri.scheme, "https") or isLoopbackUri(uri);
}

fn validateAuthorizationMetadataUrls(
    metadata: AuthorizationMetadata,
    resource: []const u8,
) !void {
    try validateOAuthUrlForResource(metadata.authorization_endpoint, resource);
    try validateOAuthUrlForResource(metadata.token_endpoint, resource);
    if (metadata.registration_endpoint) |url| {
        try validateOAuthUrlForResource(url, resource);
    }
    if (metadata.revocation_endpoint) |url| {
        try validateOAuthUrlForResource(url, resource);
    }
}

fn validateOAuthUrlForResource(
    candidate: []const u8,
    resource: []const u8,
) !void {
    const candidate_uri = std.Uri.parse(candidate) catch
        return error.InvalidMcpAuthEndpoint;
    if (candidate_uri.user != null or candidate_uri.password != null or
        candidate_uri.fragment != null)
    {
        return error.InsecureMcpAuthEndpoint;
    }
    if (std.ascii.eqlIgnoreCase(candidate_uri.scheme, "https")) return;
    const resource_uri = std.Uri.parse(resource) catch
        return error.InvalidMcpAuthEndpoint;
    if (isLoopbackUri(candidate_uri) and isLoopbackHost(resource_uri)) return;
    return error.InsecureMcpAuthEndpoint;
}

fn originAlloc(alloc: Allocator, uri: std.Uri) ![]u8 {
    const host_component = uri.host orelse return error.InvalidMcpAuthEndpoint;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try host_component.toRaw(&host_buf);
    const scheme = try std.ascii.allocLowerString(alloc, uri.scheme);
    defer alloc.free(scheme);
    const canonical_host = try std.ascii.allocLowerString(alloc, host);
    defer alloc.free(canonical_host);
    const default_port = (std.ascii.eqlIgnoreCase(uri.scheme, "https") and uri.port == 443) or
        (std.ascii.eqlIgnoreCase(uri.scheme, "http") and uri.port == 80);
    if (uri.port) |port| {
        if (!default_port) return std.fmt.allocPrint(
            alloc,
            "{s}://{s}:{d}",
            .{ scheme, canonical_host, port },
        );
    }
    return std.fmt.allocPrint(alloc, "{s}://{s}", .{ scheme, canonical_host });
}

fn rawPathAlloc(alloc: Allocator, uri: std.Uri) ![]u8 {
    var buffer: [4096]u8 = undefined;
    const path = try uri.path.toRaw(&buffer);
    return alloc.dupe(u8, if (path.len == 0) "/" else path);
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MissingMetadataField;
    if (value != .string or value.string.len == 0) return error.InvalidMetadataField;
    return value.string;
}

fn dupeRequiredUrl(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = try requiredString(object, key);
    const uri = std.Uri.parse(value) catch return error.InvalidMetadataUrl;
    if (!isSecureOrLoopback(uri) or uri.fragment != null) return error.InvalidMetadataUrl;
    return alloc.dupe(u8, value);
}

fn dupeOptionalUrl(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len == 0) return error.InvalidMetadataUrl;
    const uri = std.Uri.parse(value.string) catch return error.InvalidMetadataUrl;
    if (!isSecureOrLoopback(uri) or uri.fragment != null) return error.InvalidMetadataUrl;
    return try alloc.dupe(u8, value.string);
}

fn optionalBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn dupeRequiredStringArray(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![][]u8 {
    const value = object.get(key) orelse return error.MissingMetadataField;
    return dupeStringArray(alloc, value);
}

fn dupeOptionalStringArray(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![][]u8 {
    const value = object.get(key) orelse return &.{};
    return dupeStringArray(alloc, value);
}

fn dupeOptionalStringArrayDefault(
    alloc: Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    default_value: []const u8,
) ![][]u8 {
    const value = object.get(key) orelse {
        const result = try alloc.alloc([]u8, 1);
        errdefer alloc.free(result);
        result[0] = try alloc.dupe(u8, default_value);
        return result;
    };
    return dupeStringArray(alloc, value);
}

fn dupeStringArray(alloc: Allocator, value: std.json.Value) ![][]u8 {
    if (value != .array) return error.InvalidMetadataField;
    if (value.array.items.len == 0) return &.{};
    const result = try alloc.alloc([]u8, value.array.items.len);
    errdefer alloc.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |item| alloc.free(item);
    for (value.array.items, 0..) |item, index| {
        if (item != .string or item.string.len == 0) return error.InvalidMetadataField;
        result[index] = try alloc.dupe(u8, item.string);
        initialized += 1;
    }
    return result;
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn resourceCoversEndpoint(resource: []const u8, endpoint: []const u8) bool {
    if (std.mem.eql(u8, resource, endpoint)) return true;
    if (!std.mem.startsWith(u8, endpoint, resource)) return false;
    if (resource.len == 0 or resource[resource.len - 1] == '/') return true;
    return endpoint.len > resource.len and endpoint[resource.len] == '/';
}

fn appendScopeTokens(
    alloc: Allocator,
    tokens: *std.ArrayList([]const u8),
    maybe_scope: ?[]const u8,
) !void {
    const scope = maybe_scope orelse return;
    var it = std.mem.tokenizeAny(u8, scope, " \t\r\n");
    while (it.next()) |token| try appendUnique(tokens, alloc, token);
}

fn appendUnique(
    tokens: *std.ArrayList([]const u8),
    alloc: Allocator,
    value: []const u8,
) !void {
    if (value.len == 0) return;
    if (value.len > max_scope_token_bytes) return error.InvalidOAuthScope;
    for (value) |byte| {
        if (byte == 0x21 or
            (byte >= 0x23 and byte <= 0x5b) or
            (byte >= 0x5d and byte <= 0x7e))
        {
            continue;
        }
        return error.InvalidOAuthScope;
    }
    for (tokens.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    if (tokens.items.len >= max_scope_tokens) return error.TooManyOAuthScopes;
    try tokens.append(alloc, value);
}

fn queryValueAlloc(alloc: Allocator, query: []const u8, key: []const u8) ![]u8 {
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], key)) continue;
        return percentDecodeAlloc(alloc, pair[equals + 1 ..]);
    }
    return error.MissingQueryParameter;
}

fn percentDecodeAlloc(alloc: Allocator, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '%') {
            if (index + 2 >= value.len) return error.InvalidPercentEncoding;
            const high = std.fmt.charToDigit(value[index + 1], 16) catch return error.InvalidPercentEncoding;
            const low = std.fmt.charToDigit(value[index + 2], 16) catch return error.InvalidPercentEncoding;
            try out.writer.writeByte((high << 4) | low);
            index += 3;
        } else {
            try out.writer.writeByte(if (value[index] == '+') ' ' else value[index]);
            index += 1;
        }
    }
    return out.toOwnedSlice();
}

fn freeStrings(alloc: Allocator, values: []const []u8) void {
    if (values.len == 0) return;
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

fn freeStringList(alloc: Allocator, values: *std.ArrayList([]u8)) void {
    for (values.items) |value| alloc.free(value);
    values.deinit(alloc);
}

fn fuzzAuthorizationParsers(_: void, smith: *std.testing.Smith) !void {
    const alloc = std.testing.allocator;
    var input_buffer: [2048]u8 = undefined;
    const input_len: usize = @intCast(smith.slice(&input_buffer));
    const input = input_buffer[0..input_len];

    if (parseChallenge(alloc, input)) |challenge_value| {
        var challenge = challenge_value;
        challenge.deinit(alloc);
    } else |_| {}
    if (parseAuthorizationRedirect(alloc, input)) |response_value| {
        var response = response_value;
        response.deinit(alloc);
    } else |_| {}
    if (parseResourceMetadata(
        alloc,
        input,
        "https://api.example.com/mcp",
    )) |metadata_value| {
        var metadata = metadata_value;
        metadata.deinit(alloc);
    } else |_| {}
    if (parseAuthorizationMetadata(
        alloc,
        input,
        "https://login.example.com",
    )) |metadata_value| {
        var metadata = metadata_value;
        metadata.deinit(alloc);
    } else |_| {}
}

test "authorization parsers handle fuzzed untrusted bytes" {
    try std.testing.fuzz({}, fuzzAuthorizationParsers, .{
        .corpus = &.{
            "",
            "Bearer scope=\"tools.read\"",
            "http://localhost:3000/callback?code=one&state=two",
            "{\"resource\":\"https://api.example.com/mcp\",\"authorization_servers\":[\"https://login.example.com\"]}",
            "{\"issuer\":\"https://login.example.com\",\"authorization_endpoint\":\"https://login.example.com/authorize\",\"token_endpoint\":\"https://login.example.com/token\"}",
            "\xff\x00{}",
        },
    });
}

test "challenge parser retains only non-secret authorization directions" {
    const alloc = std.testing.allocator;
    var challenge = try parseChallenge(
        alloc,
        "BEARER realm=\"mcp\", error=\"insufficient_scope\", scope=\"tools.read tools.call\", resource_metadata=\"https://api.example/.well-known/oauth-protected-resource/mcp\"",
    );
    defer challenge.deinit(alloc);
    try std.testing.expect(challenge.insufficient_scope);
    try std.testing.expectEqualStrings("tools.read tools.call", challenge.scope.?);
    try std.testing.expectEqualStrings(
        "https://api.example/.well-known/oauth-protected-resource/mcp",
        challenge.resource_metadata.?,
    );
}

test "authentication header collection preserves multiple challenges" {
    const alloc = std.testing.allocator;
    const head = try std.http.Client.Response.Head.parse(
        "HTTP/1.1 401 Unauthorized\r\n" ++
            "WWW-Authenticate: Basic realm=\"legacy\"\r\n" ++
            "WWW-Authenticate: Bearer scope=\"tools.call\"\r\n\r\n",
    );
    const value = (try collectAuthenticateHeader(alloc, head)).?;
    defer alloc.free(value);
    try std.testing.expectEqualStrings(
        "Basic realm=\"legacy\", Bearer scope=\"tools.call\"",
        value,
    );
    var challenge = try parseChallenge(alloc, value);
    defer challenge.deinit(alloc);
    try std.testing.expectEqualStrings("tools.call", challenge.scope.?);
}

test "canonical resource normalizes origin identity and removes query" {
    const alloc = std.testing.allocator;
    const canonical = try canonicalResource(
        alloc,
        "HTTPS://API.Example.COM:443?tenant=one",
    );
    defer alloc.free(canonical);
    try std.testing.expectEqualStrings("https://api.example.com/", canonical);
}

test "OAuth URL policy confines loopback HTTP to local MCP resources" {
    try validateOAuthUrlForResource(
        "https://login.example.com/oauth",
        "https://api.example.com/mcp",
    );
    try validateOAuthUrlForResource(
        "http://127.0.0.1:4321/oauth",
        "http://localhost:9876/mcp",
    );
    try std.testing.expectError(
        error.InsecureMcpAuthEndpoint,
        validateOAuthUrlForResource(
            "http://127.0.0.1:4321/oauth",
            "https://api.example.com/mcp",
        ),
    );
    try std.testing.expectError(
        error.InsecureMcpAuthEndpoint,
        validateOAuthUrlForResource(
            "https://user@login.example.com/oauth",
            "https://api.example.com/mcp",
        ),
    );
}

test "metadata discovery paths preserve issuer and resource paths" {
    const alloc = std.testing.allocator;
    const resource_urls = try protectedResourceMetadataUrls(
        alloc,
        "https://api.example.com/tenant/mcp",
    );
    defer freeStrings(alloc, resource_urls);
    try std.testing.expectEqualStrings(
        "https://api.example.com/.well-known/oauth-protected-resource/tenant/mcp",
        resource_urls[0],
    );
    try std.testing.expectEqualStrings(
        "https://api.example.com/.well-known/oauth-protected-resource",
        resource_urls[1],
    );

    const issuer_urls = try authorizationMetadataUrls(
        alloc,
        "https://login.example.com/tenant",
    );
    defer freeStrings(alloc, issuer_urls);
    try std.testing.expectEqualStrings(
        "https://login.example.com/.well-known/oauth-authorization-server/tenant",
        issuer_urls[0],
    );
    try std.testing.expectEqualStrings(
        "https://login.example.com/.well-known/openid-configuration/tenant",
        issuer_urls[1],
    );
    try std.testing.expectEqualStrings(
        "https://login.example.com/tenant/.well-known/openid-configuration",
        issuer_urls[2],
    );
}

test "authorization metadata defaults omitted token endpoint authentication to client_secret_basic" {
    const alloc = std.testing.allocator;
    var metadata = try parseAuthorizationMetadata(
        alloc,
        "{\"issuer\":\"https://login.example.com\",\"authorization_endpoint\":\"https://login.example.com/authorize\",\"token_endpoint\":\"https://login.example.com/token\"}",
        "https://login.example.com",
    );
    defer metadata.deinit(alloc);

    try std.testing.expectEqualStrings(
        "client_secret_basic",
        try chooseTokenEndpointAuthMethod(metadata, false),
    );
}

test "authorization metadata mismatch retains exact issuer values and fails closed" {
    const alloc = std.testing.allocator;
    const bytes =
        "{\"issuer\":\"https://login.example.com\",\"authorization_endpoint\":\"https://login.example.com/authorize\",\"token_endpoint\":\"https://login.example.com/token\"}";

    var outcome = try parseAuthorizationMetadataOutcome(
        alloc,
        bytes,
        "https://login.example.com/",
    );
    defer switch (outcome) {
        .metadata => |*metadata| metadata.deinit(alloc),
        .issuer_mismatch => |*mismatch| mismatch.deinit(),
    };
    switch (outcome) {
        .metadata => return error.TestUnexpectedResult,
        .issuer_mismatch => |mismatch| {
            try std.testing.expectEqual(
                IssuerMismatchSource.authorization_metadata,
                mismatch.source,
            );
            try std.testing.expectEqualStrings(
                "https://login.example.com/",
                mismatch.expected,
            );
            try std.testing.expectEqualStrings(
                "https://login.example.com",
                mismatch.returned,
            );
        },
    }
    try std.testing.expectError(
        error.AuthorizationMetadataIssuerMismatch,
        parseAuthorizationMetadata(
            alloc,
            bytes,
            "https://login.example.com/",
        ),
    );
}

test "client registration rejects unsupported-only token endpoint authentication metadata" {
    const alloc = std.testing.allocator;
    var metadata = try parseAuthorizationMetadata(
        alloc,
        "{\"issuer\":\"https://login.example.com\",\"authorization_endpoint\":\"https://login.example.com/authorize\",\"token_endpoint\":\"https://login.example.com/token\",\"token_endpoint_auth_methods_supported\":[\"private_key_jwt\"]}",
        "https://login.example.com",
    );
    defer metadata.deinit(alloc);

    var registration = resolveClientRegistration(
        alloc,
        metadata,
        "https://api.example.com/mcp",
        .{ .client_id = "configured-client" },
        "http://127.0.0.1:4321/callback",
    ) catch |err| {
        try std.testing.expectEqual(
            error.UnsupportedTokenEndpointAuthenticationMethod,
            err,
        );
        return;
    };
    defer registration.deinit(alloc);
    return error.TestExpectedError;
}

test "OAuth JSON content type accepts parameters and rejects other media" {
    try validateJsonContentType("application/json");
    try validateJsonContentType("Application/JSON; charset=utf-8");
    try std.testing.expectError(
        error.InvalidOAuthResponseContentType,
        validateJsonContentType(null),
    );
    try std.testing.expectError(
        error.InvalidOAuthResponseContentType,
        validateJsonContentType("text/plain"),
    );
}

test "scope policy unions prior and challenged scopes without duplicates" {
    const alloc = std.testing.allocator;
    const scope = (try requestedScope(
        alloc,
        &.{},
        "tools.call tools.admin",
        &.{},
        "tools.read tools.call",
        true,
    )).?;
    defer alloc.free(scope);
    try std.testing.expectEqualStrings(
        "tools.read tools.call tools.admin offline_access",
        scope,
    );
}

test "authorization response uses exact state and issuer comparison" {
    const alloc = std.testing.allocator;
    var response = try parseAuthorizationRedirect(
        alloc,
        "http://127.0.0.1:3000/callback?code=abc&state=state-1&iss=https%3A%2F%2Flogin.example.com",
    );
    defer response.deinit(alloc);
    try validateAuthorizationResponse(
        "state-1",
        "https://login.example.com",
        true,
        response,
    );
    try std.testing.expectError(
        error.AuthorizationResponseIssuerMismatch,
        validateAuthorizationResponse(
            "state-1",
            "https://login.example.com/",
            true,
            response,
        ),
    );
}

test "authorization redirect target must match the registered callback" {
    try validateRedirectTarget(
        "http://localhost:3000/callback?code=one&state=two",
        "http://localhost:3000/callback",
    );
    try std.testing.expectError(
        error.InvalidAuthorizationCallback,
        validateRedirectTarget(
            "https://attacker.example/callback?code=one&state=two",
            "http://localhost:3000/callback",
        ),
    );
}

test "interactive callback wait observes caller and lifecycle cancellation" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return error.SkipZigTest;
    }
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(std.testing.io, .{ .reuse_address = true });
    defer listener.deinit(std.testing.io);

    const Flip = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(20 * std.time.ns_per_ms);
            flag.store(true, .release);
        }
    };
    inline for (.{ "caller", "runtime" }) |source| {
        var caller = std.atomic.Value(bool).init(false);
        var runtime = std.atomic.Value(bool).init(false);
        const flag = if (std.mem.eql(u8, source, "caller")) &caller else &runtime;
        const thread = try std.Thread.spawn(.{}, Flip.run, .{flag});
        defer thread.join();

        const started_ms = io_mod.milliTimestamp();
        try std.testing.expectError(
            error.Cancelled,
            waitForInteractiveCallback(&listener, .{
                .caller = &caller,
                .runtime = &runtime,
            }),
        );
        try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1_000);
    }
}
