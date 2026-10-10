//! OAuth discovery, pure: the `WWW-Authenticate` challenge, the
//! server's canonical URI and the resource check, the
//! metadata URLs in order, which URLs may be fetched or
//! used, and reading both metadata documents with their
//! checks.

const std = @import("std");
const wire = @import("../protocol/wire.zig");

const Allocator = std.mem.Allocator;

// ---- Challenge ----

pub const Challenge = struct {
    resource_metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    /// `error="insufficient_scope"`: a step-up.
    insufficient_scope: bool = false,
};

/// Reads the Bearer challenge in a `WWW-Authenticate` value, which may hold
/// several challenges (RFC 9110 §11.6.1). Quoted values are unescaped into
/// `a`. Null when no challenge is Bearer.
pub fn parseChallenge(a: Allocator, value: []const u8) Allocator.Error!?Challenge {
    var c: Challenge = .{};
    var found = false;
    var bearer = false;
    var i: usize = 0;
    while (true) {
        while (i < value.len and (isSpace(value[i]) or value[i] == ',')) i += 1;
        if (i == value.len) break;
        const start = i;
        while (i < value.len and !isSeparator(value[i])) i += 1;
        const name = value[start..i];
        var j = i;
        while (j < value.len and isSpace(value[j])) j += 1;
        if (j < value.len and value[j] == '=' and name.len > 0) {
            j += 1;
            // token68, such as base64 ending in "=": not a parameter.
            if (j == value.len or value[j] == '=' or value[j] == ',') {
                while (j < value.len and value[j] == '=') j += 1;
                i = j;
                continue;
            }
            while (j < value.len and isSpace(value[j])) j += 1;
            var param: []const u8 = undefined;
            if (j < value.len and value[j] == '"') {
                var out: std.ArrayList(u8) = .empty;
                j += 1;
                while (j < value.len and value[j] != '"') : (j += 1) {
                    if (value[j] == '\\' and j + 1 < value.len) j += 1;
                    try out.append(a, value[j]);
                }
                if (j < value.len) j += 1;
                param = out.items;
            } else {
                const v = j;
                while (j < value.len and value[j] != ',' and !isSpace(value[j])) j += 1;
                param = value[v..j];
            }
            i = j;
            if (!bearer) continue;
            if (std.ascii.eqlIgnoreCase(name, "resource_metadata")) {
                c.resource_metadata = param;
            } else if (std.ascii.eqlIgnoreCase(name, "scope")) {
                c.scope = param;
            } else if (std.ascii.eqlIgnoreCase(name, "error")) {
                c.insufficient_scope = std.mem.eql(u8, param, "insufficient_scope");
            }
        } else {
            // A scheme name starts a challenge; only the first Bearer counts.
            bearer = !found and std.ascii.eqlIgnoreCase(name, "Bearer");
            found = found or bearer;
            if (name.len == 0) i += 1;
        }
    }
    return if (found) c else null;
}

fn isSeparator(c: u8) bool {
    return isSpace(c) or c == ',' or c == '=' or c == '"';
}

/// Folded header lines count as whitespace too.
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

// ---- URLs ----

pub const Url = struct {
    scheme: []const u8,
    /// The host as written, without brackets for IPv6.
    host: []const u8,
    /// The port, the scheme's default when none is written.
    port: u16,
    /// Everything up to the path: scheme, "://", and authority.
    origin: []const u8,
    /// The path as written, "" for none.
    path: []const u8,
    /// The path and query, without the fragment.
    rest: []const u8,
};

/// Splits an absolute http or https URL. Null for anything else.
pub fn parseUrl(url: []const u8) ?Url {
    const sep = std.mem.find(u8, url, "://") orelse return null;
    const scheme = url[0..sep];
    const default_port: u16 = if (std.ascii.eqlIgnoreCase(scheme, "https"))
        443
    else if (std.ascii.eqlIgnoreCase(scheme, "http"))
        80
    else
        return null;
    const after = url[sep + 3 ..];
    const authority_end = std.mem.findAny(u8, after, "/?#") orelse after.len;
    const authority = after[0..authority_end];
    if (authority.len == 0 or std.mem.findScalar(u8, authority, '@') != null) return null;
    var host = authority;
    var port = default_port;
    if (authority[0] == '[') {
        const close = std.mem.findScalar(u8, authority, ']') orelse return null;
        host = authority[1..close];
        const tail = authority[close + 1 ..];
        if (tail.len > 0) {
            if (tail[0] != ':') return null;
            port = std.fmt.parseInt(u16, tail[1..], 10) catch return null;
        }
    } else if (std.mem.findScalarLast(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
    }
    if (host.len == 0) return null;
    const origin = url[0 .. sep + 3 + authority_end];
    var rest = url[origin.len..];
    if (std.mem.findScalar(u8, rest, '#')) |hash| rest = rest[0..hash];
    const path = rest[0 .. std.mem.findScalar(u8, rest, '?') orelse rest.len];
    return .{ .scheme = scheme, .host = host, .port = port, .origin = origin, .path = path, .rest = rest };
}

pub fn sameOrigin(x: Url, y: Url) bool {
    return std.ascii.eqlIgnoreCase(x.scheme, y.scheme) and std.ascii.eqlIgnoreCase(x.host, y.host) and x.port == y.port;
}

/// The server's canonical URI, for `resource`: scheme and
/// host lowercased, no fragment, no trailing slash on the path.
pub fn canonicalResource(a: Allocator, url: []const u8) (Allocator.Error || error{InvalidUrl})![]const u8 {
    const u = parseUrl(url) orelse return error.InvalidUrl;
    const out = try a.alloc(u8, u.origin.len + u.rest.len);
    _ = std.ascii.lowerString(out[0..u.origin.len], u.origin);
    var rest = u.rest;
    // The trailing slash of the path, before any query.
    const q = std.mem.findScalar(u8, rest, '?') orelse rest.len;
    var n = u.origin.len;
    if (q > 0 and rest[q - 1] == '/') {
        @memcpy(out[n..][0 .. q - 1], rest[0 .. q - 1]);
        n += q - 1;
        rest = rest[q..];
    }
    @memcpy(out[n..][0..rest.len], rest);
    return out[0 .. n + rest.len];
}

/// RFC 9728 §3.3: the resource metadata's `resource` names this server:
/// the same origin, and its path the server's or a whole-segment prefix of it.
pub fn resourceAllowed(server_url: []const u8, resource: []const u8) bool {
    const s = parseUrl(server_url) orelse return false;
    const r = parseUrl(resource) orelse return false;
    if (!sameOrigin(s, r)) return false;
    const rp = std.mem.trimEnd(u8, r.path, "/");
    const sp = std.mem.trimEnd(u8, s.path, "/");
    if (!std.mem.startsWith(u8, sp, rp)) return false;
    return sp.len == rp.len or sp[rp.len] == '/';
}

/// Where to look for the resource metadata, in order: the
/// challenge's `resource_metadata`, resolved against the server URL and only
/// on its origin; then the well-known URI with the server's path,
/// unless it is at the root; then the root one.
pub fn resourceMetadataUrls(a: Allocator, server_url: []const u8, from_challenge: ?[]const u8) (Allocator.Error || error{InvalidUrl})![]const []const u8 {
    const s = parseUrl(server_url) orelse return error.InvalidUrl;
    var urls: std.ArrayList([]const u8) = .empty;
    if (from_challenge) |given| {
        const resolved = if (given.len > 0 and given[0] == '/') try std.mem.concat(a, u8, &.{ s.origin, given }) else given;
        if (parseUrl(resolved)) |u| if (sameOrigin(s, u)) try urls.append(a, resolved);
    }
    const path = std.mem.trimEnd(u8, s.path, "/");
    const root = try std.mem.concat(a, u8, &.{ s.origin, "/.well-known/oauth-protected-resource" });
    if (path.len > 0) try urls.append(a, try std.mem.concat(a, u8, &.{ root, path }));
    try urls.append(a, root);
    return urls.items;
}

/// The authorization server metadata URLs for `issuer`, in order.
pub fn serverMetadataUrls(a: Allocator, issuer: []const u8) (Allocator.Error || error{InvalidUrl})![]const []const u8 {
    const u = parseUrl(issuer) orelse return error.InvalidUrl;
    const path = std.mem.trimEnd(u8, u.path, "/");
    var urls: std.ArrayList([]const u8) = .empty;
    if (path.len == 0) {
        try urls.append(a, try std.mem.concat(a, u8, &.{ u.origin, "/.well-known/oauth-authorization-server" }));
        try urls.append(a, try std.mem.concat(a, u8, &.{ u.origin, "/.well-known/openid-configuration" }));
    } else {
        try urls.append(a, try std.mem.concat(a, u8, &.{ u.origin, "/.well-known/oauth-authorization-server", path }));
        try urls.append(a, try std.mem.concat(a, u8, &.{ u.origin, "/.well-known/openid-configuration", path }));
        try urls.append(a, try std.mem.concat(a, u8, &.{ u.origin, path, "/.well-known/openid-configuration" }));
    }
    return urls.items;
}

/// HTTPS, or HTTP to a loopback host.
pub fn secureOrLoopback(url: []const u8) bool {
    const u = parseUrl(url) orelse return false;
    return std.ascii.eqlIgnoreCase(u.scheme, "https") or isLoopback(u.host);
}

/// An authorization server's metadata may be fetched unless its host is
/// private, loopback, link-local, or a cloud metadata service; those only
/// when the MCP server itself is on loopback.
pub fn fetchable(url: []const u8, server_url: []const u8) bool {
    const u = parseUrl(url) orelse return false;
    if (!secureOrLoopback(url)) return false;
    if (!isInternal(u.host)) return true;
    const s = parseUrl(server_url) orelse return false;
    return isLoopback(s.host) and isLoopback(u.host);
}

pub fn isLoopback(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.ascii.endsWithIgnoreCase(host, ".localhost")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    const ip = ipv4(host) orelse return false;
    return ip[0] == 127;
}

fn isInternal(host: []const u8) bool {
    if (isLoopback(host)) return true;
    for ([_][]const u8{ "metadata", "metadata.google.internal", "metadata.azure.internal" }) |name| {
        if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, host, "."), name)) return true;
    }
    var v4 = ipv4(host);
    if (std.ascii.startsWithIgnoreCase(host, "::ffff:")) v4 = ipv4(host[7..]);
    if (v4) |ip| return ip[0] == 0 or ip[0] == 10 or ip[0] == 127 or (ip[0] == 100 and ip[1] >= 64 and ip[1] <= 127) or
        (ip[0] == 169 and ip[1] == 254) or (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) or
        (ip[0] == 192 and ip[1] == 168) or (ip[0] == 198 and (ip[1] == 18 or ip[1] == 19)) or ip[0] >= 224;
    if (std.mem.findScalar(u8, host, ':') == null) return false;
    // IPv6: unspecified, unique local (fc00::/7), link-local (fe80::/10).
    if (std.mem.eql(u8, host, "::")) return true;
    if (host.len >= 2 and (std.ascii.toLower(host[0]) == 'f') and (std.ascii.toLower(host[1]) == 'c' or std.ascii.toLower(host[1]) == 'd')) return true;
    return host.len >= 3 and std.ascii.startsWithIgnoreCase(host, "fe") and std.mem.findScalar(u8, "89abAB", host[2]) != null;
}

fn ipv4(host: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (n == 4 or part.len == 0 or part.len > 3) return null;
        for (part) |c| if (!std.ascii.isDigit(c)) return null;
        out[n] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (n == 4) out else null;
}

// ---- Documents ----

pub const ResourceMetadata = struct {
    resource: []const u8,
    /// The first authorization server listed.
    issuer: []const u8,
    /// `scopes_supported`, a raw JSON array, when listed.
    scopes: ?[]const u8,
};

pub const DocumentError = Allocator.Error || error{ Malformed, NoAuthorizationServer, ResourceMismatch, IssuerMismatch, NoPkce, InsecureEndpoint };

/// Reads protected resource metadata for `server_url`.
pub fn parseResourceMetadata(a: Allocator, raw: []const u8, server_url: []const u8) DocumentError!ResourceMetadata {
    var found: [3]?[]const u8 = undefined;
    wire.objectFields(raw, &.{ "resource", "authorization_servers", "scopes_supported" }, &found) catch return error.Malformed;
    const resource = (try wire.decodeString(a, found[0] orelse return error.Malformed)) orelse return error.Malformed;
    if (!resourceAllowed(server_url, resource)) return error.ResourceMismatch;
    var servers: wire.Elements = undefined;
    servers.init(found[1] orelse return error.NoAuthorizationServer) catch return error.Malformed;
    const first = (servers.next() catch return error.Malformed) orelse return error.NoAuthorizationServer;
    const issuer = (try wire.decodeString(a, first)) orelse return error.Malformed;
    if (parseUrl(issuer) == null) return error.Malformed;
    return .{ .resource = resource, .issuer = issuer, .scopes = found[2] };
}

pub const ServerMetadata = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    registration_endpoint: ?[]const u8,
    revocation_endpoint: ?[]const u8,
    /// `authorization_response_iss_parameter_supported` (RFC 9207 §2.3).
    iss_supported: bool,
    /// `client_id_metadata_document_supported`.
    cimd_supported: bool,
    /// `token_endpoint_auth_methods_supported`, a raw JSON array, when listed.
    auth_methods: ?[]const u8,
    /// `scopes_supported`, a raw JSON array, when listed.
    scopes: ?[]const u8,
};

/// Reads authorization server metadata fetched for `issuer`: its issuer must
/// be the same string, it must list S256, and its
/// endpoints must be HTTPS or loopback.
pub fn parseServerMetadata(a: Allocator, raw: []const u8, issuer: []const u8) DocumentError!ServerMetadata {
    const names = [_][]const u8{
        "issuer",                                         "authorization_endpoint",                "token_endpoint",
        "registration_endpoint",                          "revocation_endpoint",                   "code_challenge_methods_supported",
        "authorization_response_iss_parameter_supported", "client_id_metadata_document_supported", "token_endpoint_auth_methods_supported",
        "scopes_supported",
    };
    var f: [names.len]?[]const u8 = undefined;
    wire.objectFields(raw, &names, &f) catch return error.Malformed;
    const got = (try wire.decodeString(a, f[0] orelse return error.Malformed)) orelse return error.Malformed;
    if (!std.mem.eql(u8, got, issuer)) return error.IssuerMismatch;
    const pkce = f[5] orelse return error.NoPkce;
    if (!(wire.arrayHasString(pkce, "S256") catch return error.Malformed)) return error.NoPkce;
    var m: ServerMetadata = .{
        .issuer = got,
        .authorization_endpoint = try endpoint(a, f[1] orelse return error.Malformed),
        .token_endpoint = try endpoint(a, f[2] orelse return error.Malformed),
        .registration_endpoint = null,
        .revocation_endpoint = null,
        .iss_supported = if (f[6]) |v| std.mem.eql(u8, v, "true") else false,
        .cimd_supported = if (f[7]) |v| std.mem.eql(u8, v, "true") else false,
        .auth_methods = f[8],
        .scopes = f[9],
    };
    if (f[3]) |v| m.registration_endpoint = try endpoint(a, v);
    if (f[4]) |v| m.revocation_endpoint = try endpoint(a, v);
    return m;
}

fn endpoint(a: Allocator, raw: []const u8) DocumentError![]const u8 {
    const url = (try wire.decodeString(a, raw)) orelse return error.Malformed;
    if (!secureOrLoopback(url)) return error.InsecureEndpoint;
    return url;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "reads the Bearer challenge among others, quoted or not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = (try parseChallenge(a, "Basic realm=\"x\", Bearer error=\"insufficient_scope\", scope=\"files:read files:write\",\n resource_metadata=\"https://mcp.example.com/.well-known/oauth-protected-resource\"")).?;
    try testing.expect(c.insufficient_scope);
    try testing.expectEqualStrings("files:read files:write", c.scope.?);
    try testing.expectEqualStrings("https://mcp.example.com/.well-known/oauth-protected-resource", c.resource_metadata.?);
    const t = (try parseChallenge(a, "Basic dXNlcjpwYXNz==, bearer scope=read error=invalid_token, resource_metadata=\"a\\\"b\"")).?;
    try testing.expectEqualStrings("read", t.scope.?);
    try testing.expect(!t.insufficient_scope);
    try testing.expectEqualStrings("a\"b", t.resource_metadata.?);
    try testing.expectEqual(@as(?Challenge, null), try parseChallenge(a, "Basic realm=\"x\""));
    const bare = (try parseChallenge(a, "Bearer")).?;
    try testing.expectEqual(@as(?[]const u8, null), bare.scope);
    // Parameters of a later scheme aren't the Bearer challenge's.
    const later = (try parseChallenge(a, "Bearer scope=\"a\", DPoP scope=\"b\"")).?;
    try testing.expectEqualStrings("a", later.scope.?);
}

test "canonical URIs and the resource check" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("https://mcp.example.com/mcp", try canonicalResource(a, "HTTPS://MCP.Example.com/mcp/#frag"));
    try testing.expectEqualStrings("http://127.0.0.1:8080", try canonicalResource(a, "http://127.0.0.1:8080/"));
    try testing.expectEqualStrings("https://x.com/a?b=/", try canonicalResource(a, "https://x.com/a/?b=/"));
    try testing.expect(resourceAllowed("https://x.com/mcp", "https://X.com/mcp"));
    try testing.expect(resourceAllowed("https://x.com/mcp", "https://x.com"));
    try testing.expect(resourceAllowed("https://x.com:443/a/mcp", "https://x.com/a/"));
    try testing.expect(!resourceAllowed("https://x.com/mcp", "https://x.com/mc"));
    try testing.expect(!resourceAllowed("https://x.com/mcp", "https://evil.example.com/mcp"));
    try testing.expect(!resourceAllowed("https://x.com/mcp", "http://x.com/mcp"));
    try testing.expect(!resourceAllowed("https://x.com/mcp", "https://x.com:8443/mcp"));
}

test "metadata URLs in the spec's order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prm = try resourceMetadataUrls(a, "https://x.com/public/mcp", "/custom/meta.json");
    try testing.expectEqual(@as(usize, 3), prm.len);
    try testing.expectEqualStrings("https://x.com/custom/meta.json", prm[0]);
    try testing.expectEqualStrings("https://x.com/.well-known/oauth-protected-resource/public/mcp", prm[1]);
    try testing.expectEqualStrings("https://x.com/.well-known/oauth-protected-resource", prm[2]);
    // Another origin's metadata URL is ignored; a server at the root has one candidate.
    const root = try resourceMetadataUrls(a, "https://x.com/", "https://evil.example.com/meta");
    try testing.expectEqual(@as(usize, 1), root.len);
    const pathed = try serverMetadataUrls(a, "https://auth.example.com/tenant1");
    try testing.expectEqualStrings("https://auth.example.com/.well-known/oauth-authorization-server/tenant1", pathed[0]);
    try testing.expectEqualStrings("https://auth.example.com/.well-known/openid-configuration/tenant1", pathed[1]);
    try testing.expectEqualStrings("https://auth.example.com/tenant1/.well-known/openid-configuration", pathed[2]);
    const plain = try serverMetadataUrls(a, "https://auth.example.com");
    try testing.expectEqual(@as(usize, 2), plain.len);
    try testing.expectEqualStrings("https://auth.example.com/.well-known/openid-configuration", plain[1]);
}

test "which URLs may be used or fetched" {
    try testing.expect(secureOrLoopback("https://auth.example.com/token"));
    try testing.expect(secureOrLoopback("http://127.0.0.1:9000/token"));
    try testing.expect(secureOrLoopback("http://localhost/token"));
    try testing.expect(secureOrLoopback("http://[::1]:80/token"));
    try testing.expect(!secureOrLoopback("http://auth.example.com/token"));
    try testing.expect(!secureOrLoopback("ftp://auth.example.com/token"));
    try testing.expect(fetchable("https://auth.example.com/.well-known/x", "https://mcp.example.com/mcp"));
    for ([_][]const u8{ "https://10.0.0.1/x", "https://192.168.1.1/x", "https://169.254.169.254/x", "https://metadata.google.internal/x", "https://[fd00::1]/x", "https://[fe80::1]/x", "https://[::ffff:10.0.0.1]/x", "http://localhost/x" }) |url| {
        try testing.expect(!fetchable(url, "https://mcp.example.com/mcp"));
    }
    try testing.expect(fetchable("http://localhost:9000/x", "http://127.0.0.1:8000/mcp"));
    try testing.expect(!fetchable("https://10.0.0.1/x", "http://127.0.0.1:8000/mcp"));
}

test "reads and checks both metadata documents" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prm = try parseResourceMetadata(a, "{\"resource\":\"https:\\/\\/x.com\\/mcp\",\"authorization_servers\":[\"https://auth.x.com\",\"https://other\"],\"scopes_supported\":[\"a\",\"b\"]}", "https://x.com/mcp");
    try testing.expectEqualStrings("https://auth.x.com", prm.issuer);
    try testing.expectEqualStrings("[\"a\",\"b\"]", prm.scopes.?);
    try testing.expectError(error.ResourceMismatch, parseResourceMetadata(a, "{\"resource\":\"https://evil.example.com/mcp\",\"authorization_servers\":[\"https://a\"]}", "https://x.com/mcp"));
    try testing.expectError(error.NoAuthorizationServer, parseResourceMetadata(a, "{\"resource\":\"https://x.com/mcp\",\"authorization_servers\":[]}", "https://x.com/mcp"));
    try testing.expectError(error.Malformed, parseResourceMetadata(a, "{\"authorization_servers\":[\"https://a\"]}", "https://x.com/mcp"));

    const ok = "{\"issuer\":\"https://auth.x.com\",\"authorization_endpoint\":\"https://auth.x.com/authorize\",\"token_endpoint\":\"https://auth.x.com/token\",\"code_challenge_methods_supported\":[\"plain\",\"S256\"],\"authorization_response_iss_parameter_supported\":true,\"registration_endpoint\":\"https://auth.x.com/register\"}";
    const m = try parseServerMetadata(a, ok, "https://auth.x.com");
    try testing.expect(m.iss_supported and !m.cimd_supported);
    try testing.expectEqualStrings("https://auth.x.com/register", m.registration_endpoint.?);
    // The issuer is compared as a string: a trailing slash is another issuer.
    try testing.expectError(error.IssuerMismatch, parseServerMetadata(a, ok, "https://auth.x.com/"));
    try testing.expectError(error.NoPkce, parseServerMetadata(a, "{\"issuer\":\"https://a\",\"authorization_endpoint\":\"https://a/x\",\"token_endpoint\":\"https://a/t\"}", "https://a"));
    try testing.expectError(error.NoPkce, parseServerMetadata(a, "{\"issuer\":\"https://a\",\"authorization_endpoint\":\"https://a/x\",\"token_endpoint\":\"https://a/t\",\"code_challenge_methods_supported\":[\"plain\"]}", "https://a"));
    try testing.expectError(error.InsecureEndpoint, parseServerMetadata(a, "{\"issuer\":\"https://a\",\"authorization_endpoint\":\"http://a/x\",\"token_endpoint\":\"https://a/t\",\"code_challenge_methods_supported\":[\"S256\"]}", "https://a"));
}
