const std = @import("std");

const Allocator = std.mem.Allocator;
const IpAddress = std.Io.net.IpAddress;

pub const Error = error{
    UrlTooLong,
    EmptyUrl,
    UnsupportedScheme,
    MissingHost,
    CredentialedUrl,
    SingleLabelHost,
    MalformedHost,
    MalformedLocation,
    MalformedPercentEncoding,
    PercentEncodedHost,
    UnicodeHost,
    ControlByte,
    RequestTargetWhitespace,
    InvalidPort,
    InvalidIpv4,
    ScopeIdRejected,
    NonPublicAddress,
    PortChanged,
    ProtocolChanged,
    WriteFailed,
    OutOfMemory,
};

pub const max_url_bytes: usize = 2000;

pub const Scheme = enum {
    http,
    https,

    pub fn defaultPort(self: Scheme) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
        };
    }

    pub fn text(self: Scheme) []const u8 {
        return switch (self) {
            .http => "http",
            .https => "https",
        };
    }
};

pub const ValidatedUrl = struct {
    scheme: Scheme,
    canonical_host: []u8,
    port: u16,
    explicit_port: ?u16,
    path_query: []u8,
    retrieval_url: []u8,
    literal_address: ?IpAddress = null,

    pub fn deinit(self: *ValidatedUrl, alloc: Allocator) void {
        alloc.free(self.canonical_host);
        alloc.free(self.path_query);
        alloc.free(self.retrieval_url);
        self.* = .{
            .scheme = .https,
            .canonical_host = &.{},
            .port = 443,
            .explicit_port = null,
            .path_query = &.{},
            .retrieval_url = &.{},
            .literal_address = null,
        };
    }
};

pub const RedirectKind = enum {
    follow,
    cross_host,
};

pub const RedirectDecision = struct {
    kind: RedirectKind,
    target: ?ValidatedUrl = null,
    cross_host_url: ?[]u8 = null,

    pub fn deinit(self: *RedirectDecision, alloc: Allocator) void {
        if (self.target) |*target| target.deinit(alloc);
        if (self.cross_host_url) |url| alloc.free(url);
        self.* = .{ .kind = .follow, .target = null, .cross_host_url = null };
    }
};

const ParsedAuthority = struct {
    host: []const u8,
    port: ?u16,
    is_ipv6_literal: bool = false,
};

pub fn normalize(alloc: Allocator, raw_url: []const u8) Error!ValidatedUrl {
    if (raw_url.len == 0) return error.EmptyUrl;
    if (raw_url.len > max_url_bytes) return error.UrlTooLong;
    try rejectControlBytes(raw_url);
    try validatePercentEncoding(raw_url);

    const scheme_end = std.mem.find(u8, raw_url, "://") orelse return error.UnsupportedScheme;
    const raw_scheme = raw_url[0..scheme_end];
    const input_scheme: Scheme = if (std.ascii.eqlIgnoreCase(raw_scheme, "http"))
        .http
    else if (std.ascii.eqlIgnoreCase(raw_scheme, "https"))
        .https
    else
        return error.UnsupportedScheme;

    const authority_start = scheme_end + "://".len;
    const authority_end = authorityEnd(raw_url, authority_start);
    if (authority_end == authority_start) return error.MissingHost;

    const authority = raw_url[authority_start..authority_end];
    if (std.mem.findScalar(u8, authority, '@') != null) return error.CredentialedUrl;

    const parsed_authority = try parseAuthority(authority);
    const host_policy = try canonicalizeHost(alloc, parsed_authority.host, parsed_authority.is_ipv6_literal);
    defer alloc.free(host_policy.host);

    const scheme: Scheme = .https;
    const port = normalizedPort(input_scheme, parsed_authority.port);
    const explicit_port = normalizedExplicitPort(scheme, port, parsed_authority.port);
    const raw_path_query = stripFragment(raw_url[authority_end..]);
    const path_query = try normalizePathQuery(alloc, raw_path_query);
    errdefer alloc.free(path_query);

    const retrieval_url = try formatRetrievalUrl(alloc, scheme, host_policy.host, explicit_port, path_query);
    errdefer alloc.free(retrieval_url);

    return .{
        .scheme = scheme,
        .canonical_host = try alloc.dupe(u8, host_policy.host),
        .port = port,
        .explicit_port = explicit_port,
        .path_query = path_query,
        .retrieval_url = retrieval_url,
        .literal_address = host_policy.literal_address,
    };
}

pub fn isPublicAddress(address: IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| isPublicIpv4(ip4.bytes),
        .ip6 => |ip6| isPublicIpv6(ip6.bytes),
    };
}

pub fn redirectTarget(alloc: Allocator, current: ValidatedUrl, location: []const u8) Error!RedirectDecision {
    if (location.len == 0) return error.MalformedLocation;
    try rejectControlBytes(location);

    const absolute = try absoluteRedirectUrl(alloc, current, location);
    defer alloc.free(absolute);

    var target = normalize(alloc, absolute) catch |err| switch (err) {
        error.UnsupportedScheme,
        error.CredentialedUrl,
        error.ScopeIdRejected,
        error.ControlByte,
        error.RequestTargetWhitespace,
        error.UrlTooLong,
        error.NonPublicAddress,
        => |e| return e,
        else => return error.MalformedLocation,
    };
    errdefer target.deinit(alloc);

    if (target.scheme != current.scheme) return error.ProtocolChanged;
    if (target.port != current.port) return error.PortChanged;

    if (sameHostOrOptionalWww(current.canonical_host, target.canonical_host)) {
        return .{ .kind = .follow, .target = target };
    }

    const cross_host_url = try alloc.dupe(u8, target.retrieval_url);
    target.deinit(alloc);
    return .{ .kind = .cross_host, .cross_host_url = cross_host_url };
}

fn normalizedPort(input_scheme: Scheme, explicit_port: ?u16) u16 {
    if (explicit_port) |port| {
        if (input_scheme == .http and port == 80) return Scheme.https.defaultPort();
        return port;
    }
    return Scheme.https.defaultPort();
}

fn normalizedExplicitPort(scheme: Scheme, port: u16, raw_explicit: ?u16) ?u16 {
    if (raw_explicit == null) return null;
    if (port == scheme.defaultPort()) return null;
    return port;
}

fn authorityEnd(url: []const u8, start: usize) usize {
    var index = start;
    while (index < url.len) : (index += 1) {
        switch (url[index]) {
            '/', '?', '#' => return index,
            else => {},
        }
    }
    return url.len;
}

fn parseAuthority(authority: []const u8) Error!ParsedAuthority {
    if (authority.len == 0) return error.MissingHost;
    if (authority[0] == '[') {
        const end = std.mem.findScalar(u8, authority, ']') orelse return error.MalformedHost;
        if (end == 1) return error.MissingHost;
        const host = authority[1..end];
        if (std.mem.findScalar(u8, host, '%') != null) return error.ScopeIdRejected;
        if (end + 1 == authority.len) return .{ .host = host, .port = null, .is_ipv6_literal = true };
        if (authority[end + 1] != ':') return error.MalformedHost;
        return .{
            .host = host,
            .port = try parsePort(authority[end + 2 ..]),
            .is_ipv6_literal = true,
        };
    }

    const colon = std.mem.findScalarLast(u8, authority, ':') orelse authority.len;
    if (colon == 0) return error.MissingHost;
    const host = authority[0..colon];
    const port = if (colon == authority.len) null else try parsePort(authority[colon + 1 ..]);
    return .{ .host = host, .port = port };
}

fn parsePort(raw: []const u8) Error!u16 {
    if (raw.len == 0) return error.InvalidPort;
    for (raw) |char| {
        if (!std.ascii.isDigit(char)) return error.InvalidPort;
    }
    return std.fmt.parseInt(u16, raw, 10) catch return error.InvalidPort;
}

const CanonicalHost = struct {
    host: []u8,
    literal_address: ?IpAddress = null,
};

fn canonicalizeHost(alloc: Allocator, raw_host: []const u8, is_ipv6_literal: bool) Error!CanonicalHost {
    if (raw_host.len == 0) return error.MissingHost;
    if (std.mem.findScalar(u8, raw_host, '%') != null) return error.PercentEncodedHost;

    for (raw_host) |char| {
        if (char < 0x20 or char == 0x7f) return error.ControlByte;
        if (char >= 0x80) return error.UnicodeHost;
        if (char == ' ' or char == '\\' or char == '/') return error.MalformedHost;
    }

    if (is_ipv6_literal) {
        const ip6 = std.Io.net.Ip6Address.parse(raw_host, 0) catch return error.MalformedHost;
        const address: IpAddress = .{ .ip6 = ip6 };
        if (!isPublicAddress(address)) return error.NonPublicAddress;
        const lower = try lowerAscii(alloc, raw_host);
        return .{ .host = lower, .literal_address = address };
    }

    const without_root = stripOneRootDot(raw_host);
    if (without_root.len == 0) return error.MalformedHost;

    if (parseStrictIpv4(without_root)) |ip4| {
        const address: IpAddress = .{ .ip4 = .{ .bytes = ip4, .port = 0 } };
        if (!isPublicAddress(address)) return error.NonPublicAddress;
        return .{ .host = try lowerAscii(alloc, without_root), .literal_address = address };
    } else |err| switch (err) {
        error.InvalidIpv4 => return error.InvalidIpv4,
        error.NotIpv4 => {},
    }

    if (looksLikeAmbiguousIpv4(without_root)) return error.InvalidIpv4;
    if (isSingleLabel(without_root)) return error.SingleLabelHost;

    try validateHostnameGrammar(without_root);
    const lower = try lowerAscii(alloc, without_root);
    if (isBlockedHostname(lower)) {
        alloc.free(lower);
        return error.NonPublicAddress;
    }
    return .{ .host = lower };
}

fn lowerAscii(alloc: Allocator, value: []const u8) ![]u8 {
    const out = try alloc.alloc(u8, value.len);
    for (value, 0..) |char, index| out[index] = std.ascii.toLower(char);
    return out;
}

fn stripOneRootDot(host: []const u8) []const u8 {
    if (host.len > 1 and host[host.len - 1] == '.') return host[0 .. host.len - 1];
    return host;
}

fn validateHostnameGrammar(host: []const u8) Error!void {
    var label_len: usize = 0;
    var previous: u8 = 0;
    for (host) |char| {
        if (char == '.') {
            if (label_len == 0 or label_len > 63) return error.MalformedHost;
            if (!std.ascii.isAlphanumeric(previous)) return error.MalformedHost;
            label_len = 0;
            previous = char;
            continue;
        }
        if (!std.ascii.isAlphanumeric(char) and char != '-') return error.MalformedHost;
        if (label_len == 0 and char == '-') return error.MalformedHost;
        label_len += 1;
        previous = char;
    }
    if (label_len == 0 or label_len > 63) return error.MalformedHost;
    if (!std.ascii.isAlphanumeric(previous)) return error.MalformedHost;
}

fn isSingleLabel(host: []const u8) bool {
    return std.mem.findScalar(u8, host, '.') == null;
}

fn isBlockedHostname(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost")) return true;
    if (std.mem.eql(u8, host, "localhost.localdomain")) return true;
    if (std.mem.eql(u8, host, "metadata.google.internal")) return true;
    if (std.mem.eql(u8, host, "metadata.goog")) return true;
    return endsOnLabelBoundary(host, ".localhost") or
        endsOnLabelBoundary(host, ".local") or
        endsOnLabelBoundary(host, ".localdomain") or
        endsOnLabelBoundary(host, ".internal");
}

fn endsOnLabelBoundary(host: []const u8, suffix: []const u8) bool {
    return host.len > suffix.len and std.mem.endsWith(u8, host, suffix);
}

const Ipv4ParseError = error{ NotIpv4, InvalidIpv4 };

fn parseStrictIpv4(host: []const u8) Ipv4ParseError![4]u8 {
    var out: [4]u8 = undefined;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |part| {
        if (count == 4) return error.InvalidIpv4;
        if (part.len == 0) return error.NotIpv4;
        if (part.len > 1 and part[0] == '0') return error.InvalidIpv4;
        for (part) |char| {
            if (!std.ascii.isDigit(char)) return error.NotIpv4;
        }
        out[count] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIpv4;
        count += 1;
    }
    if (count == 4) return out;
    if (count > 1) return error.InvalidIpv4;
    return error.NotIpv4;
}

fn looksLikeAmbiguousIpv4(host: []const u8) bool {
    if (std.mem.find(u8, host, "0x") != null or std.mem.find(u8, host, "0X") != null) return true;

    var labels: usize = 0;
    var numeric_labels: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |label| {
        labels += 1;
        if (label.len == 0) return true;
        var numeric = true;
        for (label) |char| {
            if (!std.ascii.isDigit(char)) {
                numeric = false;
                break;
            }
        }
        if (numeric) numeric_labels += 1;
    }
    if (numeric_labels == labels and labels > 1) return true;
    if (labels == 4 and numeric_labels > 0) return true;
    return false;
}

fn rejectControlBytes(value: []const u8) Error!void {
    for (value) |char| {
        if (char < 0x20 or char == 0x7f) return error.ControlByte;
    }
}

fn validatePercentEncoding(value: []const u8) Error!void {
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] != '%') continue;
        if (index + 2 >= value.len) return error.MalformedPercentEncoding;
        if (!std.ascii.isHex(value[index + 1]) or !std.ascii.isHex(value[index + 2])) return error.MalformedPercentEncoding;
        index += 2;
    }
}

fn stripFragment(path_query_fragment: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, path_query_fragment, '#') orelse path_query_fragment.len;
    return path_query_fragment[0..end];
}

fn normalizePathQuery(alloc: Allocator, path_query: []const u8) ![]u8 {
    for (path_query) |char| {
        if (std.ascii.isWhitespace(char)) return error.RequestTargetWhitespace;
    }
    if (path_query.len == 0) return alloc.dupe(u8, "/");
    if (path_query[0] == '?') return alloc.print("/{s}", .{path_query});
    return alloc.dupe(u8, path_query);
}

fn formatRetrievalUrl(alloc: Allocator, scheme: Scheme, host: []const u8, explicit_port: ?u16, path_query: []const u8) ![]u8 {
    const host_text = try hostForUrl(alloc, host);
    defer alloc.free(host_text);
    if (explicit_port) |port| {
        return alloc.print("{s}://{s}:{d}{s}", .{ scheme.text(), host_text, port, path_query });
    }
    return alloc.print("{s}://{s}{s}", .{ scheme.text(), host_text, path_query });
}

fn hostForUrl(alloc: Allocator, canonical_host: []const u8) ![]u8 {
    if (std.mem.findScalar(u8, canonical_host, ':') == null) return alloc.dupe(u8, canonical_host);
    return alloc.print("[{s}]", .{canonical_host});
}

fn absoluteRedirectUrl(alloc: Allocator, current: ValidatedUrl, location: []const u8) Error![]u8 {
    const without_fragment = stripFragment(location);
    if (without_fragment.len == 0) return alloc.dupe(u8, current.retrieval_url);

    if (std.mem.startsWith(u8, without_fragment, "http://") or std.mem.startsWith(u8, without_fragment, "https://")) {
        return alloc.dupe(u8, without_fragment);
    }
    if (std.mem.startsWith(u8, without_fragment, "//")) {
        return alloc.print("{s}:{s}", .{ current.scheme.text(), without_fragment });
    }
    if (hasUnsupportedAbsoluteScheme(without_fragment)) return error.UnsupportedScheme;

    if (without_fragment[0] == '/') {
        return formatRetrievalUrl(alloc, current.scheme, current.canonical_host, current.explicit_port, without_fragment);
    }

    const merged = try mergeRelativePath(alloc, current.path_query, without_fragment);
    defer alloc.free(merged);
    return formatRetrievalUrl(alloc, current.scheme, current.canonical_host, current.explicit_port, merged);
}

fn hasUnsupportedAbsoluteScheme(value: []const u8) bool {
    const colon = std.mem.findScalar(u8, value, ':') orelse return false;
    const slash = std.mem.findScalar(u8, value, '/') orelse value.len;
    const question = std.mem.findScalar(u8, value, '?') orelse value.len;
    return colon < slash and colon < question;
}

fn mergeRelativePath(alloc: Allocator, current_path_query: []const u8, relative: []const u8) ![]u8 {
    const current_path_end = std.mem.findScalar(u8, current_path_query, '?') orelse current_path_query.len;
    const current_path = current_path_query[0..current_path_end];
    const base_end = if (std.mem.findScalarLast(u8, current_path, '/')) |slash| slash + 1 else 0;
    const query_start = std.mem.findScalar(u8, relative, '?') orelse relative.len;
    const relative_path = relative[0..query_start];
    const relative_query = relative[query_start..];

    const joined = try alloc.print("{s}{s}", .{ current_path[0..base_end], relative_path });
    defer alloc.free(joined);

    const normalized_path = try removeDotSegments(alloc, joined);
    defer alloc.free(normalized_path);
    return alloc.print("{s}{s}", .{ normalized_path, relative_query });
}

fn removeDotSegments(alloc: Allocator, path: []const u8) ![]u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(alloc);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        try segments.append(alloc, segment);
    }

    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();
    try writer.writer.writeByte('/');
    for (segments.items, 0..) |segment, index| {
        if (index > 0) try writer.writer.writeByte('/');
        try writer.writer.writeAll(segment);
    }
    if (std.mem.endsWith(u8, path, "/") and segments.items.len > 0) try writer.writer.writeByte('/');
    return writer.toOwnedSlice();
}

fn sameHostOrOptionalWww(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    return std.mem.eql(u8, stripOneWww(a), stripOneWww(b));
}

fn stripOneWww(host: []const u8) []const u8 {
    if (std.mem.startsWith(u8, host, "www.") and host.len > "www.".len) return host["www.".len..];
    return host;
}

fn isPublicIpv4(bytes: [4]u8) bool {
    const ranges = [_]struct {
        prefix: [4]u8,
        bits: u6,
    }{
        .{ .prefix = .{ 0, 0, 0, 0 }, .bits = 8 },
        .{ .prefix = .{ 10, 0, 0, 0 }, .bits = 8 },
        .{ .prefix = .{ 100, 64, 0, 0 }, .bits = 10 },
        .{ .prefix = .{ 127, 0, 0, 0 }, .bits = 8 },
        .{ .prefix = .{ 169, 254, 0, 0 }, .bits = 16 },
        .{ .prefix = .{ 172, 16, 0, 0 }, .bits = 12 },
        .{ .prefix = .{ 192, 0, 0, 0 }, .bits = 24 },
        .{ .prefix = .{ 192, 0, 2, 0 }, .bits = 24 },
        .{ .prefix = .{ 192, 88, 99, 0 }, .bits = 24 },
        .{ .prefix = .{ 192, 168, 0, 0 }, .bits = 16 },
        .{ .prefix = .{ 198, 18, 0, 0 }, .bits = 15 },
        .{ .prefix = .{ 198, 51, 100, 0 }, .bits = 24 },
        .{ .prefix = .{ 203, 0, 113, 0 }, .bits = 24 },
        .{ .prefix = .{ 224, 0, 0, 0 }, .bits = 4 },
        .{ .prefix = .{ 240, 0, 0, 0 }, .bits = 4 },
    };
    for (ranges) |range| {
        if (ipv4InCidr(bytes, range.prefix, range.bits)) return false;
    }
    return true;
}

fn ipv4InCidr(bytes: [4]u8, prefix: [4]u8, bits: u6) bool {
    const value = std.mem.readInt(u32, &bytes, .big);
    const prefix_value = std.mem.readInt(u32, &prefix, .big);
    const mask: u32 = if (bits == 0) 0 else blk: {
        const shift: u8 = @intCast(32 - bits);
        break :blk std.math.shl(u32, std.math.maxInt(u32), shift);
    };
    return (value & mask) == (prefix_value & mask);
}

fn isPublicIpv6(bytes: [16]u8) bool {
    const in_ipv6_global_unicast = (bytes[0] & 0xe0) == 0x20;
    if (std.Io.net.Ip4Address.fromIp6(.{ .bytes = bytes, .port = 0 })) |ip4| {
        return isPublicIpv4(ip4.bytes) and in_ipv6_global_unicast;
    }

    if (!in_ipv6_global_unicast) return false;
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and (bytes[2] & 0xfe) == 0x00) return false;
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and bytes[2] == 0x0d and bytes[3] == 0xb8) return false;
    if (bytes[0] == 0x20 and bytes[1] == 0x02) return false;
    if (bytes[0] == 0x3f and (bytes[1] & 0xf0) == 0xf0) return false;
    return true;
}

test "web_fetch rejects non http schemes credentials single label hosts and overlong urls before services" {
    const alloc = std.testing.allocator;

    try std.testing.expectError(error.UnsupportedScheme, normalize(alloc, "ftp://example.com/file"));
    try std.testing.expectError(error.CredentialedUrl, normalize(alloc, "https://token@example.com/private"));
    try std.testing.expectError(error.SingleLabelHost, normalize(alloc, "https://intranet/path"));

    const overlong = try alloc.alloc(u8, 2001);
    defer alloc.free(overlong);
    @memset(overlong, 'a');
    try std.testing.expectError(error.UrlTooLong, normalize(alloc, overlong));
}

test "web_fetch canonicalizes ascii hostname root dot and rejects malformed percent encoded and unicode host bytes" {
    const alloc = std.testing.allocator;

    var normalized = try normalize(alloc, "http://Example.COM./docs?q=1#frag");
    defer normalized.deinit(alloc);

    try std.testing.expectEqual(.https, normalized.scheme);
    try std.testing.expectEqualStrings("example.com", normalized.canonical_host);
    try std.testing.expectEqual(@as(u16, 443), normalized.port);
    try std.testing.expectEqualStrings("/docs?q=1", normalized.path_query);
    try std.testing.expectEqualStrings("https://example.com/docs?q=1", normalized.retrieval_url);

    try std.testing.expectError(error.MalformedPercentEncoding, normalize(alloc, "https://example.com/%zz"));
    try std.testing.expectError(error.PercentEncodedHost, normalize(alloc, "https://exa%6dple.com/"));
    try std.testing.expectError(error.UnicodeHost, normalize(alloc, "https://éxample.com/"));
}

test "web_fetch rejects raw spaces in request targets and redirects" {
    const alloc = std.testing.allocator;

    try std.testing.expectError(error.RequestTargetWhitespace, normalize(alloc, "https://example.com/a b"));
    try std.testing.expectError(error.RequestTargetWhitespace, normalize(alloc, "https://example.com/search?q=a b"));

    var current = try normalize(alloc, "https://example.com/docs");
    defer current.deinit(alloc);
    try std.testing.expectError(error.RequestTargetWhitespace, redirectTarget(alloc, current, "/a b"));
}

test "web_fetch fixtures every blocked ipv4 range ipv6 envelope exclusion and embedded ipv4 range" {
    const blocked_ipv4 = [_][]const u8{
        "0.1.2.3",
        "10.0.0.1",
        "100.64.0.1",
        "127.0.0.1",
        "169.254.169.254",
        "172.16.0.1",
        "192.0.0.1",
        "192.0.2.1",
        "192.88.99.1",
        "192.168.0.1",
        "198.18.0.1",
        "198.51.100.1",
        "203.0.113.1",
        "224.0.0.1",
        "240.0.0.1",
    };
    for (blocked_ipv4) |text| {
        const addr = try std.Io.net.IpAddress.parse(text, 443);
        try std.testing.expect(!isPublicAddress(addr));
    }

    const public_ipv4 = try std.Io.net.IpAddress.parse("93.184.216.34", 443);
    try std.testing.expect(isPublicAddress(public_ipv4));

    const blocked_ipv6 = [_][]const u8{
        "::1",
        "fc00::1",
        "fe80::1",
        "ff00::1",
        "2001::1",
        "2001:db8::1",
        "2002::1",
        "3fff::1",
        "::ffff:127.0.0.1",
        "::ffff:192.168.0.1",
    };
    for (blocked_ipv6) |text| {
        const addr = try std.Io.net.IpAddress.parse(text, 443);
        try std.testing.expect(!isPublicAddress(addr));
    }

    const public_ipv6 = try std.Io.net.IpAddress.parse("2606:4700:4700::1111", 443);
    try std.testing.expect(isPublicAddress(public_ipv6));
}

test "web_fetch rejects public and private ipv4 mapped ipv6 literals" {
    const alloc = std.testing.allocator;
    const mapped = [_][]const u8{
        "93.184.216.34",
        "127.0.0.1",
        "192.168.0.1",
    };

    for (mapped) |embedded| {
        const literal = try alloc.print("::ffff:{s}", .{embedded});
        defer alloc.free(literal);
        const address = try std.Io.net.IpAddress.parse(literal, 443);
        try std.testing.expect(!isPublicAddress(address));

        const url = try alloc.print("https://[{s}]/", .{literal});
        defer alloc.free(url);
        try std.testing.expectError(error.NonPublicAddress, normalize(alloc, url));
    }
}

test "web_fetch relative redirect resolves before admission and malformed location fails closed" {
    const alloc = std.testing.allocator;

    var current = try normalize(alloc, "https://example.com/a/b/page");
    defer current.deinit(alloc);

    var redirected = try redirectTarget(alloc, current, "../next?q=1");
    defer redirected.deinit(alloc);
    try std.testing.expectEqual(.follow, redirected.kind);
    try std.testing.expectEqualStrings("https://example.com/a/next?q=1", redirected.target.?.retrieval_url);

    try std.testing.expectError(error.UnsupportedScheme, redirectTarget(alloc, current, "javascript:alert(1)"));
    try std.testing.expectError(error.MalformedLocation, redirectTarget(alloc, current, "https://exa mple.com/"));
}

test "web_fetch redirect normalization rejects credentials scope ids control bytes and port changes" {
    const alloc = std.testing.allocator;

    var current = try normalize(alloc, "https://example.com/docs");
    defer current.deinit(alloc);

    try std.testing.expectError(error.CredentialedUrl, redirectTarget(alloc, current, "https://token@example.com/"));
    try std.testing.expectError(error.ScopeIdRejected, redirectTarget(alloc, current, "https://[2606:4700:4700::1111%25en0]/"));
    try std.testing.expectError(error.ControlByte, redirectTarget(alloc, current, "https://example.com/a\nb"));
    try std.testing.expectError(error.PortChanged, redirectTarget(alloc, current, "https://example.com:8443/docs"));
}

test "web_fetch scheme relative and fragment redirect behavior is deterministic" {
    const alloc = std.testing.allocator;

    var current = try normalize(alloc, "https://example.com/docs/index.html?x=1");
    defer current.deinit(alloc);

    var scheme_relative = try redirectTarget(alloc, current, "//example.com/next#frag");
    defer scheme_relative.deinit(alloc);
    try std.testing.expectEqual(.follow, scheme_relative.kind);
    try std.testing.expectEqualStrings("https://example.com/next", scheme_relative.target.?.retrieval_url);

    var fragment = try redirectTarget(alloc, current, "#section");
    defer fragment.deinit(alloc);
    try std.testing.expectEqual(.follow, fragment.kind);
    try std.testing.expectEqualStrings("https://example.com/docs/index.html?x=1", fragment.target.?.retrieval_url);
}

test "web_fetch cross host redirect returns reinvocation result without following" {
    const alloc = std.testing.allocator;

    var current = try normalize(alloc, "https://example.com/docs");
    defer current.deinit(alloc);

    var cross = try redirectTarget(alloc, current, "https://example.org/docs");
    defer cross.deinit(alloc);
    try std.testing.expectEqual(.cross_host, cross.kind);
    try std.testing.expectEqualStrings("https://example.org/docs", cross.cross_host_url.?);

    var www = try redirectTarget(alloc, current, "https://www.example.com/docs");
    defer www.deinit(alloc);
    try std.testing.expectEqual(.follow, www.kind);
    try std.testing.expectEqualStrings("www.example.com", www.target.?.canonical_host);
}
