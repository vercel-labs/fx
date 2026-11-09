//! Routes fx's outbound connections through the proxy the environment names.
//!
//! The pure core: parsing the proxy variables once into a snapshot that owns
//! what it keeps, deciding the route for a host and port, writing CONNECT,
//! reading the proxy's answer (interim heads included), naming a failure,
//! fitting a failure's sentence into a status line, and keeping the log a
//! request claims its own failure from. It does no I/O and imports only std.
//! `net_proxy_io.zig` installs it in the process Io, so every connection fx
//! opens by host name goes through it. `tests/tla/net_proxy/NetProxy.tla` and
//! `NetProxyEnv.tla` model it, and `tests/tla/drivers/net_proxy/driver.ts`
//! walks this file along both models.
const std = @import("std");

const IpAddress = std.Io.net.IpAddress;
const HostName = std.Io.net.HostName;
const basic = std.http.Client.basic_authorization;

const max_no_proxy_entries = 1000;
const max_answer_head_bytes = 8192;
const max_proxy_url_bytes = 1024;
/// Room for the NO_PROXY domains the snapshot copies out of the environment.
/// An entry that does not fit counts as past the limit.
const max_domain_bytes = 64 * 1024;
/// The longest scheme or host a refusal repeats in its message.
const max_detail_bytes = 48;
/// The most bytes a retry notice gives to the proxy: "proxy HOST:PORT" and the
/// cause in a few words (`Failure.shortText`). A status text holds 95 bytes
/// (`src/core/recovery/recovery.zig` Text.capacity). The longest cause and wait
/// part, "Unreadable reply · next try in 59m 59s", take 39, and a separator 4,
/// so a note of 48 leaves the cause and the wait whole, and the clock and the
/// attempt give way first (`statusWithProxy`).
pub const max_notice_bytes = 48;
/// Routes loopback through the proxy too, for end-to-end tests whose fake
/// endpoints fx accepts only on loopback (`tests/e2e/net-proxy.test.ts`).
pub const loopback_test_variable = "FX_TEST_NET_PROXY_LOOPBACK";

/// What a connection carries, as far as the route cares: plain HTTP uses
/// http_proxy, everything else https_proxy.
pub const Scheme = enum { http, https };

pub const Reason = enum {
    /// The proxy URL names a scheme other than http://, such as socks5://.
    unsupported_scheme,
    /// The value does not parse as a URL.
    unreadable_url,
    /// The URL has no host.
    no_host,
    /// The host is not a name or an address fx can connect to.
    bad_host,
    /// The port is not 1 to 65535.
    bad_port,
    /// The user name or password is too long to send.
    bad_credentials,
    /// The value is longer than fx reads.
    too_long,
};

pub const Refusal = struct {
    variable: []const u8,
    reason: Reason,
    /// The URL's scheme, or the host when the reason is `bad_host`, when it is
    /// short and plain enough to repeat in a message; never credentials.
    /// Points into the snapshot.
    detail: []const u8 = "",
};

pub const Proxy = struct {
    /// A host name or an IP address, without brackets.
    host: []const u8,
    port: u16,
    /// "Basic <base64>" from the URL's user and password, or null.
    authorization: ?[]const u8,
    variable: []const u8,
};

pub const Slot = union(enum) {
    none,
    proxy: Proxy,
    refuse: Refusal,
};

pub const Decision = union(enum) {
    direct,
    tunnel: Proxy,
    refuse: Refusal,
};

/// What the environment says, parsed once. It copies everything it keeps out
/// of the environment into its own buffers, so a program that changes the
/// environment afterwards, as the libfx addon's host may, cannot reach it
/// (`tests/tla/net_proxy/NetProxyEnv.tla` HostStable, NoProxyStable). Its
/// slices point into those buffers, so it stays where `parse` filled it.
pub const Snapshot = struct {
    https: Slot = .none,
    http: Slot = .none,
    route_loopback: bool = false,
    no_proxy_all: bool = false,
    no_proxy: [max_no_proxy_entries]NoProxyEntry = undefined,
    no_proxy_len: usize = 0,
    /// What `parse` dropped, for the caller to log: NO_PROXY entries that are
    /// not an entry, and entries past `max_no_proxy_entries` or past the room
    /// for domains.
    no_proxy_invalid: u32 = 0,
    no_proxy_over_limit: u32 = 0,
    /// An uppercase HTTP_PROXY was set and ignored because REQUEST_METHOD is set.
    http_proxy_ignored: bool = false,
    host_buf: [2][HostName.max_len]u8 = undefined,
    detail_buf: [2][max_detail_bytes]u8 = undefined,
    auth_buf: [2][basic.max_value_len]u8 = undefined,
    url_buf: [2][max_proxy_url_bytes]u8 = undefined,
    domain_buf: [max_domain_bytes]u8 = undefined,
    domain_len: usize = 0,

    /// Whether any proxy variable is set, so a route can tunnel at all.
    pub fn routes(s: *const Snapshot) bool {
        return s.https != .none or s.http != .none;
    }
};

/// Fills `s` from `env`, which has `fn getenv(env, name) ?[]const u8`. Each
/// variable is read by a getenv call that spells its name out, so
/// `scripts/check_cli_shape.py` sees every name fx reads. Lowercase names win,
/// as curl reads them, and an empty value counts as unset.
///
/// When REQUEST_METHOD is set, an uppercase HTTP_PROXY is ignored: a CGI server
/// turns a request header `Proxy:` into HTTP_PROXY (httpoxy), so the variable
/// may hold an attacker's value. Go's httpproxy refuses it for the same
/// reason. Lowercase http_proxy, ALL_PROXY, and the HTTPS forms still apply,
/// since a CGI server does not set them.
pub fn parse(s: *Snapshot, env: anytype) void {
    s.* = .{};
    const cgi = nonEmpty(env.getenv("REQUEST_METHOD")) != null;
    const upper_http = nonEmpty(env.getenv("HTTP_PROXY"));
    s.https = parseSlot(s, 0, &.{
        .{ .name = "https_proxy", .value = env.getenv("https_proxy") },
        .{ .name = "HTTPS_PROXY", .value = env.getenv("HTTPS_PROXY") },
        .{ .name = "all_proxy", .value = env.getenv("all_proxy") },
        .{ .name = "ALL_PROXY", .value = env.getenv("ALL_PROXY") },
    });
    s.http = parseSlot(s, 1, &.{
        .{ .name = "http_proxy", .value = env.getenv("http_proxy") },
        .{ .name = "HTTP_PROXY", .value = if (cgi) null else upper_http },
        .{ .name = "all_proxy", .value = env.getenv("all_proxy") },
        .{ .name = "ALL_PROXY", .value = env.getenv("ALL_PROXY") },
    });
    s.http_proxy_ignored = cgi and upper_http != null;
    if (env.getenv(loopback_test_variable)) |value| s.route_loopback = std.mem.eql(u8, value, "1");
    const no_proxy = nonEmpty(env.getenv("no_proxy")) orelse nonEmpty(env.getenv("NO_PROXY")) orelse return;
    var it = std.mem.tokenizeAny(u8, no_proxy, ", \t");
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, "*")) {
            s.no_proxy_all = true;
            continue;
        }
        if (s.no_proxy_len == max_no_proxy_entries) {
            s.no_proxy_over_limit +|= 1;
            continue;
        }
        var parsed = NoProxyEntry.parse(entry) orelse {
            s.no_proxy_invalid +|= 1;
            continue;
        };
        if (parsed.kind == .domain) {
            // The domain is a slice of the environment's string; keep a copy.
            if (s.domain_len + parsed.domain.len > s.domain_buf.len) {
                s.no_proxy_over_limit +|= 1;
                continue;
            }
            const copy = s.domain_buf[s.domain_len..][0..parsed.domain.len];
            @memcpy(copy, parsed.domain);
            s.domain_len += copy.len;
            parsed.domain = copy;
        }
        s.no_proxy[s.no_proxy_len] = parsed;
        s.no_proxy_len += 1;
    }
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const text = value orelse return null;
    return if (text.len == 0) null else text;
}

/// A variable and what the environment holds for it.
const Candidate = struct { name: []const u8, value: ?[]const u8 };

fn parseSlot(s: *Snapshot, index: usize, candidates: []const Candidate) Slot {
    const found = for (candidates) |candidate| {
        if (nonEmpty(candidate.value)) |value| break Found{ .name = candidate.name, .value = value };
    } else return .none;
    const refuse = struct {
        fn refuse(variable: []const u8, reason: Reason, detail: []const u8) Slot {
            return .{ .refuse = .{ .variable = variable, .reason = reason, .detail = detail } };
        }
    }.refuse;
    // "proxy:3128" names a host and port, not a scheme, as curl reads it.
    const text = if (std.mem.find(u8, found.value, "://") != null)
        found.value
    else
        std.mem.print(&s.url_buf[index], "http://{s}", .{found.value}) catch return refuse(found.name, .too_long, "");
    const uri = std.Uri.parse(text) catch |err| return refuse(found.name, switch (err) {
        error.InvalidPort => .bad_port,
        // std refuses a host longer than any host name.
        error.InvalidHostName => .bad_host,
        else => .unreadable_url,
    }, "");
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return refuse(found.name, .unsupported_scheme, ownedDetail(s, index, printable(uri.scheme, 16)));
    const component = uri.host orelse return refuse(found.name, .no_host, "");
    const raw = component.toRaw(&s.host_buf[index]) catch return refuse(found.name, .bad_host, "");
    const bare = if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']') raw[1 .. raw.len - 1] else raw;
    if (parseIp(bare) == null and !validProxyHost(bare)) return refuse(found.name, .bad_host, ownedDetail(s, index, printable(bare, max_detail_bytes)));
    // toRaw gives back the URL's own text when it has no percent escape, so
    // the host is copied into the snapshot's buffer either way.
    const host = s.host_buf[index][0..bare.len];
    if (bare.ptr != host.ptr) @memmove(host, bare);
    const port = uri.port orelse 80;
    if (port == 0) return refuse(found.name, .bad_port, "");
    const authorization: ?[]const u8 = if (uri.user != null or uri.password != null)
        basicAuthorization(uri, &s.auth_buf[index]) orelse return refuse(found.name, .bad_credentials, "")
    else
        null;
    return .{ .proxy = .{
        .host = host,
        .port = port,
        .authorization = authorization,
        .variable = found.name,
    } };
}

/// A host name as the proxy URL may hold it: letters, digits, hyphens and dots
/// as HostName.validate allows, and underscores, which docker-compose service
/// names and many internal host names have. curl and Go leave the rest to DNS.
fn validProxyHost(host: []const u8) bool {
    var plain: [HostName.max_len]u8 = undefined;
    if (host.len > plain.len) return false;
    for (host, plain[0..host.len]) |byte, *out| out.* = if (byte == '_') 'x' else byte;
    HostName.validate(plain[0..host.len]) catch return false;
    return true;
}

/// `text`, when it is short and made of printable ASCII only, so a message
/// can repeat it without carrying escape bytes; else empty.
fn printable(text: []const u8, max: usize) []const u8 {
    if (text.len == 0 or text.len > max) return "";
    for (text) |byte| {
        if (byte <= ' ' or byte >= 0x7f) return "";
    }
    return text;
}

/// Copies `text` into the snapshot's detail buffer for slot `index`.
fn ownedDetail(s: *Snapshot, index: usize, text: []const u8) []const u8 {
    const copy = s.detail_buf[index][0..text.len];
    @memcpy(copy, text);
    return copy;
}

const Found = struct { name: []const u8, value: []const u8 };

/// "Basic base64(user:password)" with both percent-decoded, as curl sends it.
/// std.http.Client.basic_authorization sends them still encoded.
fn basicAuthorization(uri: std.Uri, out: []u8) ?[]const u8 {
    var user_buf: [basic.max_user_len]u8 = undefined;
    var password_buf: [basic.max_password_len]u8 = undefined;
    const user = if (uri.user) |c| c.toRaw(&user_buf) catch return null else "";
    const password = if (uri.password) |c| c.toRaw(&password_buf) catch return null else "";
    var plain: [basic.max_user_len + 1 + basic.max_password_len]u8 = undefined;
    const joined = std.mem.print(&plain, "{s}:{s}", .{ user, password }) catch return null;
    const prefix = "Basic ";
    const encoded_len = std.base64.standard.Encoder.calcSize(joined.len);
    if (prefix.len + encoded_len > out.len) return null;
    @memcpy(out[0..prefix.len], prefix);
    _ = std.base64.standard.Encoder.encode(out[prefix.len..][0..encoded_len], joined);
    return out[0 .. prefix.len + encoded_len];
}

/// The route for a connection to `host:port`. Loopback goes direct (unless
/// the loopback test variable is set), then NO_PROXY; everything else uses
/// the scheme's proxy, or is refused when that variable names one fx cannot
/// use.
pub fn route(s: *const Snapshot, host_name: []const u8, port: u16, scheme: Scheme) Decision {
    if (!s.route_loopback and isLoopback(host_name)) return .direct;
    const slot = switch (scheme) {
        .http => s.http,
        .https => s.https,
    };
    if (slot == .none) return .direct;
    if (s.no_proxy_all) return .direct;
    const host: Host = .{ .name = trimDot(host_name), .ip = parseIp(host_name) };
    for (s.no_proxy[0..s.no_proxy_len]) |entry| {
        if (noProxyMatches(entry, host, port)) return .direct;
    }
    return switch (slot) {
        .none => .direct,
        .proxy => |p| .{ .tunnel = p },
        .refuse => |r| .{ .refuse = r },
    };
}

const Host = struct { name: []const u8, ip: ?IpAddress };

fn trimDot(name: []const u8) []const u8 {
    return if (name.len > 1 and name[name.len - 1] == '.') name[0 .. name.len - 1] else name;
}

fn isLoopback(host: []const u8) bool {
    const name = trimDot(host);
    if (std.ascii.eqlIgnoreCase(name, "localhost")) return true;
    if (endsWithIgnoreCase(name, ".localhost")) return true;
    const address = parseIp(name) orelse return false;
    return switch (address) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |a| std.mem.eql(u8, &a.bytes, &(@as([15]u8, @splat(0)) ++ [1]u8{1})) or
            (std.mem.eql(u8, a.bytes[0..12], &[12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }) and a.bytes[12] == 127),
    };
}

fn parseIp(text: []const u8) ?IpAddress {
    const bare = if (text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']') text[1 .. text.len - 1] else text;
    return IpAddress.parse(bare, 0) catch null;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    return haystack.len >= suffix.len and std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

/// One NO_PROXY entry, parsed once: a domain (a leading "." or "*." is
/// dropped, and the domain matches itself and every name under it), an IP
/// address, or a CIDR block, each with an optional ":port". IPv6 addresses
/// with a port go in brackets.
const NoProxyEntry = struct {
    kind: enum { domain, ip, cidr },
    domain: []const u8 = "",
    ip: IpAddress = undefined,
    bits: u8 = 0,
    port: ?u16 = null,

    fn parse(raw: []const u8) ?NoProxyEntry {
        var text = raw;
        var port: ?u16 = null;
        if (text.len > 0 and text[0] == '[') {
            const close = std.mem.findScalar(u8, text, ']') orelse return null;
            const after = text[close + 1 ..];
            if (after.len > 0) {
                if (after[0] != ':') return null;
                port = std.fmt.parseInt(u16, after[1..], 10) catch return null;
            }
            text = text[1..close];
        } else if (std.mem.findScalar(u8, text, ':')) |colon| {
            // One colon is host:port; more is an IPv6 address without one.
            if (std.mem.findScalarLast(u8, text, ':') == colon) {
                port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
                text = text[0..colon];
            }
        }
        if (std.mem.findScalar(u8, text, '/')) |slash| {
            const network = parseIp(text[0..slash]) orelse return null;
            const bits = std.fmt.parseInt(u8, text[slash + 1 ..], 10) catch return null;
            const max_bits: u8 = switch (network) {
                .ip4 => 32,
                .ip6 => 128,
            };
            if (bits > max_bits) return null;
            return .{ .kind = .cidr, .ip = network, .bits = bits, .port = port };
        }
        if (parseIp(text)) |ip| return .{ .kind = .ip, .ip = ip, .port = port };
        if (std.mem.startsWith(u8, text, "*.")) text = text[2..] else if (std.mem.startsWith(u8, text, ".")) text = text[1..];
        text = trimDot(text);
        // No host name is longer than HostName.max_len, so such an entry could
        // never match.
        if (text.len == 0 or text.len > HostName.max_len) return null;
        return .{ .kind = .domain, .domain = text, .port = port };
    }
};

fn noProxyMatches(entry: NoProxyEntry, host: Host, port: u16) bool {
    if (entry.port) |entry_port| if (entry_port != port) return false;
    switch (entry.kind) {
        .cidr => return if (host.ip) |ip| cidrContains(entry.ip, entry.bits, ip) else false,
        .ip => return if (host.ip) |ip| entry.ip.eql(&ip) else false,
        .domain => {
            const d = entry.domain;
            const name = host.name;
            if (!endsWithIgnoreCase(name, d)) return false;
            return name.len == d.len or name[name.len - d.len - 1] == '.';
        },
    }
}

fn cidrContains(network: IpAddress, bits: u8, address: IpAddress) bool {
    const a, const b = switch (network) {
        .ip4 => |n| switch (address) {
            .ip4 => |x| .{ n.bytes[0..], x.bytes[0..] },
            .ip6 => return false,
        },
        .ip6 => |n| switch (address) {
            .ip6 => |x| .{ n.bytes[0..], x.bytes[0..] },
            .ip4 => return false,
        },
    };
    const whole = bits / 8;
    if (!std.mem.eql(u8, a[0..whole], b[0..whole])) return false;
    const rest = bits % 8;
    if (rest == 0) return true;
    const mask: u8 = @truncate(@as(u16, 0xff00) >> @intCast(rest));
    return (a[whole] & mask) == (b[whole] & mask);
}

/// Writes the CONNECT request for `host:port`. The caller flushes.
pub fn writeConnect(w: *std.Io.Writer, host: []const u8, port: u16, authorization: ?[]const u8) std.Io.Writer.Error!void {
    const bracket = std.mem.findScalar(u8, host, ':') != null;
    const open = if (bracket) "[" else "";
    const close = if (bracket) "]" else "";
    try w.print("CONNECT {s}{s}{s}:{d} HTTP/1.1\r\nHost: {s}{s}{s}:{d}\r\n", .{ open, host, close, port, open, host, close, port });
    if (authorization) |value| try w.print("Proxy-Authorization: {s}\r\n", .{value});
    try w.writeAll("\r\n");
}

pub const Answer = union(enum) {
    ok,
    /// The proxy answered with a status other than 2xx.
    status: u16,
    /// Not an HTTP answer, longer than max_answer_head_bytes, or cut off.
    malformed,
    /// The proxy closed the connection before it said anything.
    closed,
};

/// Reads the proxy's answer and nothing past it. A client must parse one or
/// more interim 1xx heads before the final one, even when it does not expect
/// them (RFC 9110 section 15.2), so a head from 100 to 199 other than 101 is
/// dropped and the next one read; 101 switches protocols and stays a refusal.
/// All the heads together stay inside `max_answer_head_bytes`
/// (`tests/tla/net_proxy/NetProxy.tla` InterimOpens, SwitchingRefused).
pub fn readConnectAnswer(r: *std.Io.Reader) error{ReadFailed}!Answer {
    var head: [max_answer_head_bytes]u8 = undefined;
    var total: usize = 0;
    while (true) {
        var len: usize = 0;
        while (true) {
            if (total == max_answer_head_bytes) return .malformed;
            head[len] = r.takeByte() catch |err| switch (err) {
                error.EndOfStream => return if (len == 0) .closed else .malformed,
                error.ReadFailed => return error.ReadFailed,
            };
            len += 1;
            total += 1;
            if (len >= 4 and std.mem.eql(u8, head[len - 4 .. len], "\r\n\r\n")) break;
        }
        const line_end = std.mem.find(u8, head[0..len], "\r\n").?;
        const line = head[0..line_end];
        if (line.len < 12 or !std.mem.startsWith(u8, line, "HTTP/1.") or line[8] != ' ') return .malformed;
        const status = std.fmt.parseInt(u16, line[9..12], 10) catch return .malformed;
        if (status < 100) return .malformed;
        if (line.len > 12 and line[12] != ' ') return .malformed;
        if (status >= 100 and status < 200 and status != 101) continue;
        if (status >= 200 and status < 300) return .ok;
        return .{ .status = status };
    }
}

pub const FailureKind = enum {
    /// fx could not open a connection to the proxy.
    unreachable_proxy,
    /// The proxy answered CONNECT with a status other than 2xx.
    refused,
    /// The proxy's answer was not HTTP.
    malformed,
    /// The proxy said nothing before the caller gave up.
    no_answer,
    /// The proxy variable names a scheme fx does not support.
    unsupported_scheme,
    /// The proxy variable is not a URL fx can read.
    invalid_url,
};

/// A proxy failure for one connection, with every name it needs copied in,
/// so it outlives the connection and never holds credentials.
pub const Failure = struct {
    kind: FailureKind,
    status: u16 = 0,
    proxy_port: u16 = 0,
    target_port: u16 = 0,
    /// Why a proxy variable was refused, for `invalid_url` and `unsupported_scheme`.
    reason: Reason = .unreadable_url,
    proxy_len: u8 = 0,
    target_len: u8 = 0,
    /// The URL's scheme or host, or the connect error in plain words.
    detail_len: u8 = 0,
    variable_len: u8 = 0,
    proxy_buf: [HostName.max_len]u8 = undefined,
    target_buf: [HostName.max_len]u8 = undefined,
    detail_buf: [64]u8 = undefined,
    variable_buf: [16]u8 = undefined,

    pub fn init(kind: FailureKind, proxy_host: []const u8, proxy_port: u16, target_host: []const u8, target_port: u16) Failure {
        var f: Failure = .{ .kind = kind, .proxy_port = proxy_port, .target_port = target_port };
        f.proxy_len = copyInto(&f.proxy_buf, proxy_host);
        f.target_len = copyInto(&f.target_buf, target_host);
        return f;
    }

    pub fn refusal(r: Refusal, target_host: []const u8, target_port: u16) Failure {
        var f = init(if (r.reason == .unsupported_scheme) .unsupported_scheme else .invalid_url, "", 0, target_host, target_port);
        f.reason = r.reason;
        f.variable_len = copyInto(&f.variable_buf, r.variable);
        f.detail_len = copyInto(&f.detail_buf, r.detail);
        return f;
    }

    /// `value` is the detail as the message shows it: the connect error in
    /// plain words (`types.plainErrorText`), never a raw error name.
    pub fn withDetail(f: Failure, value: []const u8) Failure {
        var copy = f;
        copy.detail_len = copyInto(&copy.detail_buf, value);
        return copy;
    }

    pub fn target(f: *const Failure) []const u8 {
        return f.target_buf[0..f.target_len];
    }

    fn proxyHost(f: *const Failure) []const u8 {
        return f.proxy_buf[0..f.proxy_len];
    }

    fn detail(f: *const Failure) []const u8 {
        return f.detail_buf[0..f.detail_len];
    }

    fn variable(f: *const Failure) []const u8 {
        return f.variable_buf[0..f.variable_len];
    }

    fn targetIs(f: *const Failure, host: []const u8, port: u16) bool {
        return f.target_port == port and std.ascii.eqlIgnoreCase(f.target(), host);
    }

    /// The sentence fx shows for the failure. It names the proxy and the
    /// reason and never the proxy's credentials.
    fn write(f: *const Failure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (f.kind) {
            .refused => {
                try w.writeAll("proxy ");
                try f.writeProxy(w);
                try w.print(" refused CONNECT to {s}:{d}: {d}", .{ f.target(), f.target_port, f.status });
                const status: std.http.Status = @fromBackingInt(@as(u10, @intCast(@min(f.status, 1023))));
                if (status.phrase()) |phrase| try w.print(" {s}", .{phrase});
            },
            .malformed => {
                try w.writeAll("proxy ");
                try f.writeProxy(w);
                try w.print(" answered CONNECT to {s}:{d} with bytes that are not HTTP", .{ f.target(), f.target_port });
            },
            .no_answer => {
                try w.writeAll("proxy ");
                try f.writeProxy(w);
                try w.print(" did not answer CONNECT to {s}:{d}", .{ f.target(), f.target_port });
            },
            .unreachable_proxy => {
                try w.writeAll("could not connect to proxy ");
                try f.writeProxy(w);
                try w.print(" ({s})", .{f.detail()});
            },
            .unsupported_scheme => if (f.detail_len == 0)
                try w.print("fx supports only http:// proxies, but {s} names another kind", .{f.variable()})
            else
                try w.print("fx supports only http:// proxies, but {s} is {s}://...", .{ f.variable(), f.detail() }),
            .invalid_url => switch (f.reason) {
                .unsupported_scheme, .unreadable_url => try w.print("{s} is not a proxy URL fx can read; use http://host:port", .{f.variable()}),
                .no_host => try w.print("{s} has no host name; use http://host:port", .{f.variable()}),
                .bad_host => if (f.detail_len == 0)
                    try w.print("{s} has a host name fx cannot use", .{f.variable()})
                else
                    try w.print("{s} has a host name fx cannot use: {s}", .{ f.variable(), f.detail() }),
                .bad_port => try w.print("{s} has a port fx cannot use; use a number from 1 to 65535", .{f.variable()}),
                .bad_credentials => try w.print("{s} has a user name or password that is too long", .{f.variable()}),
                .too_long => try w.print("{s} is too long for fx to read", .{f.variable()}),
            },
        }
    }

    fn writeProxy(f: *const Failure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (std.mem.findScalar(u8, f.proxyHost(), ':') != null) {
            try w.print("[{s}]:{d}", .{ f.proxyHost(), f.proxy_port });
        } else {
            try w.print("{s}:{d}", .{ f.proxyHost(), f.proxy_port });
        }
    }

    pub fn text(f: *const Failure, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        f.write(&w) catch {};
        return w.buffered();
    }

    /// ` proxy="<sentence>"`, to end a trace line about a request that failed at
    /// the proxy: the trace says what a reviewer's transport error never shows on
    /// screen. `buf` holds `trace_note_bytes` or more; a smaller one cuts the
    /// sentence short, and one under nine bytes holds no note.
    pub fn traceNote(f: *const Failure, buf: []u8) []const u8 {
        const open = " proxy=\"";
        if (buf.len <= open.len) return "";
        // The last byte is kept for the closing quote, however long the sentence is.
        var w = std.Io.Writer.fixed(buf[0 .. buf.len - 1]);
        w.writeAll(open) catch return "";
        f.write(&w) catch {};
        const used = w.buffered().len;
        buf[used] = '"';
        return buf[0 .. used + 1];
    }

    /// The room `traceNote` needs for any sentence `text` can hold in 512 bytes.
    pub const trace_note_bytes = 512 + 9;

    /// The failure in a few words for a retry notice, at most
    /// `max_notice_bytes`: "proxy 127.0.0.1:50132 answered 502", "proxy
    /// 127.0.0.1:50132 unreachable". A host too long for the room is cut with an
    /// ellipsis, inside the brackets of an IPv6 address, and the port and the
    /// cause stay whole. A refused proxy variable has no host, so the variable
    /// says it: "HTTPS_PROXY unusable". The full sentence (`write`) stays in the
    /// final error and in `fx models`. `buf` holds `max_notice_bytes` or more;
    /// a smaller one cuts the text short.
    pub fn shortText(f: *const Failure, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        f.writeShort(&w) catch {};
        return w.buffered();
    }

    fn writeShort(f: *const Failure, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var cause_buf: [24]u8 = undefined;
        const cause: []const u8 = switch (f.kind) {
            .refused => std.mem.print(&cause_buf, "answered {d}", .{f.status}) catch "answered an error",
            .unreachable_proxy => "unreachable",
            .no_answer => "did not answer",
            .malformed => "sent bad data",
            .unsupported_scheme, .invalid_url => return w.print("{s} unusable", .{f.variable()}),
        };
        var port_buf: [8]u8 = undefined;
        const port = std.mem.print(&port_buf, ":{d} ", .{f.proxy_port}) catch ": ";
        const host = f.proxyHost();
        const bracket = std.mem.findScalar(u8, host, ':') != null;
        const prefix = "proxy ";
        const ellipsis = "\u{2026}";
        const fixed = prefix.len + (if (bracket) @as(usize, 2) else 0) + port.len + cause.len;
        const room = max_notice_bytes -| fixed;
        try w.writeAll(prefix);
        if (bracket) try w.writeByte('[');
        if (host.len <= room) {
            try w.writeAll(host);
        } else {
            var keep = room -| ellipsis.len;
            while (keep > 0 and keep < host.len and (host[keep] & 0xc0) == 0x80) keep -= 1;
            try w.writeAll(host[0..keep]);
            try w.writeAll(ellipsis);
        }
        if (bracket) try w.writeByte(']');
        try w.writeAll(port);
        try w.writeAll(cause);
    }
};

fn copyInto(buf: []u8, bytes: []const u8) u8 {
    const n: u8 = @intCast(@min(bytes.len, buf.len, std.math.maxInt(u8)));
    @memcpy(buf[0..n], bytes[0..n]);
    return n;
}

/// The failure an answer means, or null when it opened the tunnel.
pub fn answerFailure(answer: Answer, proxy: Proxy, target_host: []const u8, target_port: u16) ?Failure {
    return switch (answer) {
        .ok => null,
        .status => |status| blk: {
            var f = Failure.init(.refused, proxy.host, proxy.port, target_host, target_port);
            f.status = status;
            break :blk f;
        },
        .malformed => Failure.init(.malformed, proxy.host, proxy.port, target_host, target_port),
        .closed => Failure.init(.no_answer, proxy.host, proxy.port, target_host, target_port),
    };
}

/// The error a failed connection returns, chosen so fx retries what may pass
/// on its own and stops on what will not: a 502, 503, or 504 means the proxy
/// could not reach the host, like a refused connection; another status, an
/// answer that is not HTTP, or a proxy fx cannot use ends the request.
pub fn connectError(f: *const Failure) IpAddress.ConnectError {
    return switch (f.kind) {
        .refused => switch (f.status) {
            502, 503, 504 => error.ConnectionRefused,
            else => error.AccessDenied,
        },
        .malformed, .unsupported_scheme, .invalid_url => error.ProtocolUnsupportedBySystem,
        .no_answer => error.Timeout,
        .unreachable_proxy => error.ConnectionRefused,
    };
}

/// Whether `err` can come from a failed proxy connection, so a request that
/// fails with it may claim its proxy failure. Others never do. A version lookup
/// returns one error for every failure, `ProviderVersionUnavailable`, after its
/// request claimed the proxy's sentence (`tests/tla/net_proxy/NetProxyCallers.tla`
/// VersionNamesProxy); one that failed elsewhere holds no sentence.
pub fn isProxyFailureError(err: anyerror) bool {
    return switch (err) {
        error.ProviderVersionUnavailable,
        error.AccessDenied,
        error.ProtocolUnsupportedBySystem,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.Timeout,
        error.ConnectionTimedOut,
        error.ConnectionSetupTimedOut,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
        => true,
        else => false,
    };
}

/// What a failure toward the proxy ends with: the errors `isProxyFailureError`
/// lists that a dial can return, so a name that is already a proxy failure name
/// is never changed. Three it lists are not a dial's: `ConnectionTimedOut` and
/// `ConnectionSetupTimedOut` end a model request, and `ProviderVersionUnavailable`
/// ends the Grok version lookup. `connectIp` returns `IpAddress.ConnectError`,
/// which holds none of them, and web_fetch's dial reads ETIMEDOUT as `Timeout`.
const ProxyFailureError = error{
    AccessDenied,
    ProtocolUnsupportedBySystem,
    ConnectionRefused,
    ConnectionResetByPeer,
    Timeout,
    HostUnreachable,
    NetworkUnreachable,
    NetworkDown,
};

/// The error a connection that failed at the proxy ends with, chosen by the
/// step that failed and not by the name the platform gave the failure. macOS
/// polls a refused non-blocking connect as HUP alone, which web_fetch's own
/// dialer reads as error.UnexpectedClose, and a proxy host that does not
/// resolve ends in a lookup error on every platform; neither name is one
/// `isProxyFailureError` lists, so the request would drop the sentence it holds
/// for the proxy (`tests/tla/net_proxy/NetProxyCallers.tla` FetchNamesProxy).
/// A listed name passes unchanged, such as ProtocolUnsupportedBySystem for a
/// proxy that answers with bytes that are not HTTP, and any other becomes
/// HostUnreachable. A cancellation is not a failure of the proxy: callers keep
/// it as it is.
pub fn proxyFailureError(err: anyerror) ProxyFailureError {
    return switch (err) {
        error.AccessDenied,
        error.ProtocolUnsupportedBySystem,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.Timeout,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
        => |e| e,
        else => error.HostUnreachable,
    };
}

/// Names a dial toward the proxy can return, from each platform's connect and
/// poll, the resolver, and the socket calls, for the tests and the fuzz oracle
/// that check `proxyFailureError` maps every one to a listed name.
const dial_error_names = [_]anyerror{
    error.ConnectionRefused,
    error.ConnectionResetByPeer,
    error.NetworkUnreachable,
    error.HostUnreachable,
    error.NetworkDown,
    error.Timeout,
    error.ProtocolUnsupportedBySystem,
    error.AccessDenied,
    error.UnexpectedClose,
    error.ConnectionFailed,
    error.UnknownHostName,
    error.NameServerFailure,
    error.NoAddressReturned,
    error.SystemResources,
    error.ProcessFdQuotaExceeded,
    error.SystemFdQuotaExceeded,
    error.AddressFamilyUnsupported,
    error.SocketOpenFailed,
    error.SocketOptionFailed,
    error.InvalidDescriptor,
    error.InputOutput,
    error.BrokenPipe,
    error.SocketUnconnected,
    error.WriteFailed,
    error.ReadFailed,
    error.EndOfStream,
    error.Unexpected,
};

/// What separates the parts of a status line, as src/core/recovery/recovery.zig
/// writes them.
const status_separator = " \u{b7} ";

/// `status` with a note about a proxy failure added, in at most `out.len`
/// bytes, so a retry notice names the proxy and a person who mistyped
/// HTTPS_PROXY is not told only that the network is down
/// (`tests/tla/net_proxy/NetProxy.tla` RetryNoticeNamesProxy). The note is
/// `Failure.shortText`, at most `max_notice_bytes`, so the cause and the wait
/// part of the status always stay (`NoticeKeepsWait`): the status gives way
/// first, last part first (the clock, the attempt, and only then what the wait
/// or retry is and the cause). A note longer than the room is cut at a character
/// and ends in "…". The result lives in `out`.
pub fn statusWithProxy(out: []u8, status: []const u8, sentence: []const u8) []const u8 {
    var keep = status.len;
    while (keep > 0 and keep + status_separator.len + sentence.len > out.len) {
        keep = std.mem.findLast(u8, status[0..keep], status_separator) orelse 0;
    }
    var len: usize = 0;
    if (keep > 0) {
        @memcpy(out[0..keep], status[0..keep]);
        @memcpy(out[keep..][0..status_separator.len], status_separator);
        len = keep + status_separator.len;
    }
    const room = out.len - len;
    if (sentence.len <= room) {
        @memcpy(out[len..][0..sentence.len], sentence);
        return out[0 .. len + sentence.len];
    }
    const ellipsis = "\u{2026}";
    var cut = if (room >= ellipsis.len) room - ellipsis.len else room;
    while (cut > 0 and cut < sentence.len and (sentence[cut] & 0xc0) == 0x80) cut -= 1;
    @memcpy(out[len..][0..cut], sentence[0..cut]);
    len += cut;
    if (room >= ellipsis.len) {
        @memcpy(out[len..][0..ellipsis.len], ellipsis);
        len += ellipsis.len;
    }
    return out[0..len];
}

/// The proxy failures of recent connections, each for its own target. A
/// request marks the log before it opens and, when it fails, claims the
/// oldest unclaimed failure for its own target logged since its mark; the
/// claim uses the record up, so no other request can show it
/// (`tests/tla/net_proxy/NetProxy.tla` DetailBelongsToFailingConnect,
/// DetailNamesOwnTarget, DetailReadOnce). Oldest first leaves the later
/// failures for the requests that started later. Not thread-safe; the caller
/// holds a lock.
pub const FailureLog = struct {
    const capacity = 32;

    entries: [capacity]Entry = undefined,
    filled: usize = 0,
    next_seq: u64 = 0,

    const Entry = struct {
        seq: u64,
        claimed: bool,
        failure: Failure,
    };

    pub fn mark(log: *const FailureLog) u64 {
        return log.next_seq;
    }

    /// Logs a failure, over the oldest one when the log is full.
    pub fn add(log: *FailureLog, failure: Failure) void {
        const slot = log.next_seq % capacity;
        log.entries[slot] = .{ .seq = log.next_seq, .claimed = false, .failure = failure };
        log.next_seq += 1;
        log.filled = @min(log.filled + 1, capacity);
    }

    pub fn claim(log: *FailureLog, host: []const u8, port: u16, since: u64) ?Failure {
        var best: ?*Entry = null;
        for (log.entries[0..log.filled]) |*entry| {
            if (entry.claimed or entry.seq < since) continue;
            if (!entry.failure.targetIs(host, port)) continue;
            if (best == null or entry.seq < best.?.seq) best = entry;
        }
        const found = best orelse return null;
        found.claimed = true;
        return found.failure;
    }
};

const TestEnv = struct {
    pairs: []const [2][]const u8,
    pub fn getenv(e: TestEnv, name: []const u8) ?[]const u8 {
        for (e.pairs) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
        return null;
    }
};

fn setTest(s: *Snapshot, pairs: []const [2][]const u8) void {
    parse(s, TestEnv{ .pairs = pairs });
}

test "route reads lowercase first, skips empty values, and falls back to ALL_PROXY" {
    var s: Snapshot = undefined;
    setTest(&s, &.{
        .{ "HTTPS_PROXY", "http://ignored:1" },
        .{ "https_proxy", "http://user:p%40ss@proxy.test:3128" },
    });
    const t = route(&s, "chatgpt.com", 443, .https).tunnel;
    try std.testing.expectEqualStrings("proxy.test", t.host);
    try std.testing.expectEqual(@as(u16, 3128), t.port);
    try std.testing.expectEqualStrings("Basic dXNlcjpwQHNz", t.authorization.?);
    try std.testing.expectEqualStrings("https_proxy", t.variable);
    // No http_proxy and no all_proxy: plain HTTP goes direct.
    try std.testing.expect(route(&s, "example.com", 80, .http) == .direct);

    setTest(&s, &.{ .{ "https_proxy", "" }, .{ "HTTPS_PROXY", "http://upper.test:8080" } });
    try std.testing.expectEqualStrings("upper.test", route(&s, "x.ai", 443, .https).tunnel.host);

    setTest(&s, &.{.{ "ALL_PROXY", "proxy.test:3128" }});
    try std.testing.expectEqualStrings("proxy.test", route(&s, "x.ai", 443, .https).tunnel.host);
    try std.testing.expectEqualStrings("proxy.test", route(&s, "x.ai", 80, .http).tunnel.host);
    try std.testing.expect(route(&s, "x.ai", 443, .https).tunnel.authorization == null);

    setTest(&s, &.{.{ "HTTPS_PROXY", "http://proxy.test" }});
    try std.testing.expectEqual(@as(u16, 80), route(&s, "x.ai", 443, .https).tunnel.port);

    setTest(&s, &.{.{ "HTTPS_PROXY", "http://[fd00::1]:3128" }});
    try std.testing.expectEqualStrings("fd00::1", route(&s, "x.ai", 443, .https).tunnel.host);

    setTest(&s, &.{});
    try std.testing.expect(!s.routes());
    try std.testing.expect(route(&s, "x.ai", 443, .https) == .direct);
}

test "route refuses proxies fx cannot use and keeps their credentials out" {
    var s: Snapshot = undefined;
    setTest(&s, &.{.{ "ALL_PROXY", "socks5://user:secret@127.0.0.1:1080" }});
    const r = route(&s, "x.ai", 443, .https).refuse;
    try std.testing.expectEqual(Reason.unsupported_scheme, r.reason);
    var buf: [256]u8 = undefined;
    const text = Failure.refusal(r, "x.ai", 443).text(&buf);
    try std.testing.expectEqualStrings("fx supports only http:// proxies, but ALL_PROXY is socks5://...", text);

    setTest(&s, &.{.{ "HTTPS_PROXY", "https://proxy.test:443" }});
    try std.testing.expectEqual(Reason.unsupported_scheme, route(&s, "x.ai", 443, .https).refuse.reason);

    setTest(&s, &.{.{ "HTTPS_PROXY", "http://" }});
    const invalid = route(&s, "x.ai", 443, .https).refuse;
    try std.testing.expectEqual(Reason.unreadable_url, invalid.reason);
    try std.testing.expectEqualStrings("HTTPS_PROXY is not a proxy URL fx can read; use http://host:port", Failure.refusal(invalid, "x.ai", 443).text(&buf));

    setTest(&s, &.{.{ "HTTPS_PROXY", "http://bad_host!:1" }});
    try std.testing.expectEqual(Reason.bad_host, route(&s, "x.ai", 443, .https).refuse.reason);
}

test "route keeps loopback direct unless the test variable routes it" {
    var s: Snapshot = undefined;
    setTest(&s, &.{.{ "HTTPS_PROXY", "http://proxy.test:3128" }});
    for ([_][]const u8{ "localhost", "LOCALHOST", "a.localhost", "localhost.", "127.0.0.1", "127.0.0.2", "::1", "[::1]", "::ffff:127.0.0.1" }) |host| {
        try std.testing.expect(route(&s, host, 443, .https) == .direct);
    }
    try std.testing.expect(route(&s, "128.0.0.1", 443, .https) == .tunnel);
    setTest(&s, &.{ .{ "HTTPS_PROXY", "http://proxy.test:3128" }, .{ loopback_test_variable, "1" } });
    try std.testing.expect(route(&s, "127.0.0.1", 443, .https) == .tunnel);
    setTest(&s, &.{ .{ "HTTPS_PROXY", "http://proxy.test:3128" }, .{ loopback_test_variable, "0" } });
    try std.testing.expect(route(&s, "127.0.0.1", 443, .https) == .direct);
}

test "NO_PROXY matches hosts, domains, addresses, blocks, and ports" {
    var s: Snapshot = undefined;
    setTest(&s, &.{
        .{ "HTTPS_PROXY", "http://proxy.test:3128" },
        .{ "no_proxy", "internal.example, .corp.test,*.wild.test 10.0.0.0/8,192.168.1.7,[fd00::5],[fd00::6]:8443,fe80::/10,api.test:8443,bad:port,10.0.0.0/33" },
        .{ "NO_PROXY", "ignored.test" },
    });
    const direct = [_]struct { []const u8, u16 }{
        .{ "internal.example", 443 }, .{ "INTERNAL.example", 443 },  .{ "a.internal.example", 443 },
        .{ "corp.test", 443 },        .{ "a.b.corp.test", 443 },     .{ "wild.test", 443 },
        .{ "x.wild.test", 443 },      .{ "10.1.2.3", 443 },          .{ "192.168.1.7", 443 },
        .{ "fd00::5", 443 },          .{ "fd00::6", 8443 },          .{ "fe80::1", 443 },
        .{ "api.test", 8443 },        .{ "internal.example.", 443 },
    };
    for (direct) |case| {
        if (route(&s, case[0], case[1], .https) != .direct) {
            std.debug.print("expected {s}:{d} to go direct\n", .{ case[0], case[1] });
            return error.TestExpectedDirect;
        }
    }
    const tunnel = [_]struct { []const u8, u16 }{
        .{ "xcorp.test", 443 },   .{ "notinternal.example", 443 }, .{ "11.1.2.3", 443 },
        .{ "192.168.1.8", 443 },  .{ "fd00::6", 443 },             .{ "api.test", 443 },
        .{ "ignored.test", 443 }, .{ "fec0::1", 443 },
    };
    for (tunnel) |case| {
        if (route(&s, case[0], case[1], .https) != .tunnel) {
            std.debug.print("expected {s}:{d} to tunnel\n", .{ case[0], case[1] });
            return error.TestExpectedTunnel;
        }
    }

    setTest(&s, &.{ .{ "HTTPS_PROXY", "http://proxy.test:3128" }, .{ "NO_PROXY", "*" } });
    try std.testing.expect(route(&s, "anything.example", 443, .https) == .direct);
    // A refused proxy still lets NO_PROXY hosts through.
    setTest(&s, &.{ .{ "ALL_PROXY", "socks5://p:1" }, .{ "NO_PROXY", "ok.test" } });
    try std.testing.expect(route(&s, "ok.test", 443, .https) == .direct);
    try std.testing.expect(route(&s, "other.test", 443, .https) == .refuse);
}

test "NO_PROXY keeps 1000 entries and drops the rest" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    for (0..max_no_proxy_entries + 1) |i| try list.print(std.testing.allocator, "skip{d}.example,", .{i});
    var s: Snapshot = undefined;
    setTest(&s, &.{ .{ "HTTPS_PROXY", "http://proxy.test:3128" }, .{ "NO_PROXY", list.items } });
    try std.testing.expectEqual(@as(usize, max_no_proxy_entries), s.no_proxy_len);
    try std.testing.expectEqual(@as(u32, 1), s.no_proxy_over_limit);
    try std.testing.expectEqual(@as(u32, 0), s.no_proxy_invalid);
    try std.testing.expect(route(&s, "skip999.example", 443, .https) == .direct);
    try std.testing.expect(route(&s, "skip1000.example", 443, .https) == .tunnel);
    try std.testing.expect(route(&s, "h1.unlisted.test", 443, .https) == .tunnel);
}

test "NO_PROXY counts the entries it drops, and keeps the others" {
    var s: Snapshot = undefined;
    setTest(&s, &.{
        .{ "HTTPS_PROXY", "http://proxy.test:3128" },
        .{ "NO_PROXY", "ok.example,bad:port,10.0.0.0/33,[fd00::1,.,ok2.example, ,*.wild.test" },
    });
    try std.testing.expectEqual(@as(u32, 4), s.no_proxy_invalid);
    try std.testing.expectEqual(@as(u32, 0), s.no_proxy_over_limit);
    try std.testing.expectEqual(@as(usize, 3), s.no_proxy_len);
    try std.testing.expect(route(&s, "ok.example", 443, .https) == .direct);
    try std.testing.expect(route(&s, "ok2.example", 443, .https) == .direct);
    try std.testing.expect(route(&s, "a.wild.test", 443, .https) == .direct);

    // A domain longer than any host name could never match, so it is dropped.
    var long: [HostName.max_len + 1]u8 = @splat('a');
    setTest(&s, &.{ .{ "HTTPS_PROXY", "http://proxy.test:3128" }, .{ "NO_PROXY", &long } });
    try std.testing.expectEqual(@as(u32, 1), s.no_proxy_invalid);
    try std.testing.expectEqual(@as(usize, 0), s.no_proxy_len);
}

test "30000 NO_PROXY entries and 300 KB of variable text are bounded, counted, and routed" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    for (0..30_000) |i| try list.print(std.testing.allocator, "d{d}.corp.example,", .{i});
    var s: Snapshot = undefined;
    setTest(&s, &.{ .{ "HTTPS_PROXY", "http://proxy.test:3128" }, .{ "NO_PROXY", list.items } });
    try std.testing.expectEqual(@as(usize, max_no_proxy_entries), s.no_proxy_len);
    try std.testing.expectEqual(@as(u32, 30_000 - max_no_proxy_entries), s.no_proxy_over_limit);
    try std.testing.expect(route(&s, "d999.corp.example", 443, .https) == .direct);
    try std.testing.expect(route(&s, "d1000.corp.example", 443, .https) == .tunnel);

    // Entries that fit in count but not in the domain buffer count as past the limit.
    list.clearRetainingCapacity();
    var name: [200]u8 = @splat('x');
    for (0..max_no_proxy_entries) |i| try list.print(std.testing.allocator, "{s}{d}.example,", .{ &name, i });
    setTest(&s, &.{ .{ "HTTPS_PROXY", "http://proxy.test:3128" }, .{ "NO_PROXY", list.items } });
    try std.testing.expect(s.no_proxy_over_limit > 0);
    try std.testing.expectEqual(@as(usize, max_no_proxy_entries), s.no_proxy_len + s.no_proxy_over_limit);

    // A 300 KB host, user name, and value refuse without reading past a buffer.
    const huge = try std.testing.allocator.alloc(u8, 300 * 1024);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'h');
    var buf: [256]u8 = undefined;
    setTest(&s, &.{.{ "HTTPS_PROXY", huge }});
    try std.testing.expectEqualStrings("HTTPS_PROXY is too long for fx to read", Failure.refusal(route(&s, "x.ai", 443, .https).refuse, "x.ai", 443).text(&buf));
    @memcpy(huge[0.."http://".len], "http://");
    setTest(&s, &.{.{ "HTTPS_PROXY", huge }});
    try std.testing.expectEqualStrings("HTTPS_PROXY has a host name fx cannot use", Failure.refusal(route(&s, "x.ai", 443, .https).refuse, "x.ai", 443).text(&buf));
}

test "route keeps its rules over random hosts" {
    const seed: u64 = 0x6e65745f70726f78;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var proxied: Snapshot = undefined;
    setTest(&proxied, &.{.{ "HTTPS_PROXY", "http://proxy.test:3128" }});
    var everything: Snapshot = undefined;
    setTest(&everything, &.{ .{ "HTTPS_PROXY", "http://proxy.test:3128" }, .{ "NO_PROXY", "*" } });
    var unset: Snapshot = undefined;
    setTest(&unset, &.{.{ "NO_PROXY", "a.test" }});
    var name_buf: [64]u8 = undefined;
    for (0..20_000) |_| {
        const len = random.intRangeAtMost(usize, 1, name_buf.len);
        for (name_buf[0..len]) |*byte| byte.* = "abcxyz0123456789.-:[]*"[random.uintLessThan(usize, 22)];
        const host = name_buf[0..len];
        const port = random.int(u16);
        const scheme: Scheme = if (random.boolean()) .https else .http;
        errdefer std.debug.print("seed {x} host {s} port {d}\n", .{ seed, host, port });
        // Loopback is always direct; NO_PROXY "*" is always direct; no
        // variable never tunnels; a tunnel always names the configured proxy.
        if (isLoopback(host)) try std.testing.expect(route(&proxied, host, port, scheme) == .direct);
        try std.testing.expect(route(&everything, host, port, scheme) == .direct);
        try std.testing.expect(route(&unset, host, port, scheme) == .direct);
        switch (route(&proxied, host, port, .https)) {
            .tunnel => |t| try std.testing.expectEqualStrings("proxy.test", t.host),
            .direct => try std.testing.expect(isLoopback(host)),
            .refuse => return error.TestUnexpectedRefusal,
        }
    }
}

test "CONNECT carries the target and the credentials, and the answer decides" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeConnect(&w, "proxy-target.test", 443, "Basic dXNlcjpwYXNz");
    try std.testing.expectEqualStrings("CONNECT proxy-target.test:443 HTTP/1.1\r\nHost: proxy-target.test:443\r\nProxy-Authorization: Basic dXNlcjpwYXNz\r\n\r\n", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try writeConnect(&w, "2001:db8::1", 80, null);
    try std.testing.expectEqualStrings("CONNECT [2001:db8::1]:80 HTTP/1.1\r\nHost: [2001:db8::1]:80\r\n\r\n", w.buffered());

    var long: [max_answer_head_bytes + 16]u8 = @splat('a');
    @memcpy(long[0..17], "HTTP/1.1 200 OK\r\n");
    const cases = [_]struct { []const u8, Answer }{
        .{ "HTTP/1.1 200 Connection established\r\n\r\n", .ok },
        .{ "HTTP/1.0 200\r\nVia: x\r\n\r\n", .ok },
        .{ "HTTP/1.1 204 No Content\r\n\r\n", .ok },
        .{ "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n", .{ .status = 407 } },
        .{ "HTTP/1.1 403 Forbidden\r\n\r\n", .{ .status = 403 } },
        .{ "HTTP/1.1 502 Bad Gateway\r\n\r\n", .{ .status = 502 } },
        .{ "HTTP/1.1 503 Service Unavailable\r\n\r\n", .{ .status = 503 } },
        .{ "\x16\x03\x01garbage", .malformed },
        .{ "HTTP/1.1 2000 OK\r\n\r\n", .malformed },
        .{ "HTTP/1.1 099 Low\r\n\r\n", .malformed },
        .{ "HTTP/2 200\r\n\r\n", .malformed },
        .{ "", .closed },
        .{ "HTTP/1.1 200 OK\r\n", .malformed },
        .{ &long, .malformed },
    };
    for (cases) |case| {
        var r = std.Io.Reader.fixed(case[0]);
        try std.testing.expectEqualDeep(case[1], try readConnectAnswer(&r));
    }
    // The reader stops at the head; bytes after it stay for the caller.
    var r = std.Io.Reader.fixed("HTTP/1.1 200 OK\r\n\r\nextra");
    try std.testing.expectEqual(Answer.ok, try readConnectAnswer(&r));
    try std.testing.expectEqualStrings("extra", try r.take(5));
}

test "a failure names the proxy and the reason, and maps to an error fx acts on" {
    const proxy: Proxy = .{ .host = "127.0.0.1", .port = 3128, .authorization = "Basic c2VjcmV0", .variable = "HTTPS_PROXY" };
    var buf: [256]u8 = undefined;
    const refused = answerFailure(.{ .status = 407 }, proxy, "chatgpt.com", 443).?;
    try std.testing.expectEqualStrings("proxy 127.0.0.1:3128 refused CONNECT to chatgpt.com:443: 407 Proxy Authentication Required", refused.text(&buf));
    try std.testing.expectEqual(error.AccessDenied, connectError(&refused));
    const odd = answerFailure(.{ .status = 499 }, proxy, "x.ai", 443).?;
    try std.testing.expectEqualStrings("proxy 127.0.0.1:3128 refused CONNECT to x.ai:443: 499", odd.text(&buf));
    for ([_]u16{ 502, 503, 504 }) |status| {
        try std.testing.expectEqual(error.ConnectionRefused, connectError(&answerFailure(.{ .status = status }, proxy, "x.ai", 443).?));
    }
    const malformed = answerFailure(.malformed, proxy, "x.ai", 443).?;
    try std.testing.expectEqualStrings("proxy 127.0.0.1:3128 answered CONNECT to x.ai:443 with bytes that are not HTTP", malformed.text(&buf));
    try std.testing.expectEqual(error.ProtocolUnsupportedBySystem, connectError(&malformed));
    try std.testing.expect(answerFailure(.ok, proxy, "x.ai", 443) == null);
    const unreachable_proxy = Failure.init(.unreachable_proxy, "fd00::1", 3128, "x.ai", 443).withDetail("connection refused");
    try std.testing.expectEqualStrings("could not connect to proxy [fd00::1]:3128 (connection refused)", unreachable_proxy.text(&buf));
    const silent = answerFailure(.closed, .{ .host = "proxy.test", .port = 3128, .authorization = null, .variable = "HTTPS_PROXY" }, "x.ai", 443).?;
    try std.testing.expectEqualStrings("proxy proxy.test:3128 did not answer CONNECT to x.ai:443", silent.text(&buf));
    for ([_]Failure{ refused, malformed, unreachable_proxy, silent }) |f| {
        try std.testing.expect(std.mem.find(u8, f.text(&buf), "c2VjcmV0") == null);
        try std.testing.expect(isProxyFailureError(connectError(&f)));
    }
    try std.testing.expect(isProxyFailureError(error.ConnectionSetupTimedOut));
    try std.testing.expect(!isProxyFailureError(error.TlsInitializationFailed));
    try std.testing.expect(!isProxyFailureError(error.Cancelled));
}

test "a failure toward the proxy ends with a name the claim lists, whatever name the platform gave it" {
    // The step decides, not the name: macOS polls a refused connect as
    // UnexpectedClose and an unresolvable proxy host is a lookup error.
    for (dial_error_names) |name| {
        try std.testing.expect(isProxyFailureError(proxyFailureError(name)));
    }
    // A name the claim already lists and a dial can return passes unchanged:
    // web_fetch's error for a proxy that answers with bytes that are not HTTP
    // stays ProtocolUnsupportedBySystem, as the model request's is.
    for ([_]anyerror{
        error.AccessDenied,
        error.ProtocolUnsupportedBySystem,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.Timeout,
        error.HostUnreachable,
        error.NetworkUnreachable,
        error.NetworkDown,
    }) |name| {
        try std.testing.expect(isProxyFailureError(name));
        try std.testing.expect(proxyFailureError(name) == name);
    }
    // The two lists cannot drift apart: every name `proxyFailureError` can
    // return is one the claim lists.
    inline for (@typeInfo(ProxyFailureError).error_set.error_names.?) |error_name| {
        try std.testing.expect(isProxyFailureError(@field(ProxyFailureError, error_name)));
    }
    // The names the platforms disagree on become one that retries like a refusal.
    try std.testing.expect(proxyFailureError(error.UnexpectedClose) == error.HostUnreachable);
    try std.testing.expect(proxyFailureError(error.UnknownHostName) == error.HostUnreachable);
}

test "a version lookup that failed at the proxy may claim its failure, and the lookup's other errors may not" {
    // The lookup returns this one error for every failure, after its request
    // claimed the proxy's sentence (src/gateway/provider_versions.zig).
    try std.testing.expect(isProxyFailureError(error.ProviderVersionUnavailable));
    try std.testing.expect(!isProxyFailureError(error.Cancelled));
    try std.testing.expect(!isProxyFailureError(error.InvalidProviderVersion));
    try std.testing.expect(!isProxyFailureError(error.ProviderVersionResponseTooLarge));
}

test "a request claims only its own target's failures, oldest first, once" {
    var log: FailureLog = .{};
    const before_a = log.mark();
    log.add(Failure.init(.refused, "p", 1, "a.test", 443));
    const before_b = log.mark();
    log.add(Failure.init(.refused, "p", 1, "b.test", 443));
    log.add(Failure.init(.malformed, "p", 1, "a.test", 443));
    // Another target, another port, or a failure from before the mark is
    // never claimed.
    try std.testing.expect(log.claim("c.test", 443, before_a) == null);
    try std.testing.expect(log.claim("a.test", 8443, before_a) == null);
    try std.testing.expectEqual(FailureKind.malformed, log.claim("a.test", 443, before_b).?.kind);
    try std.testing.expectEqual(FailureKind.refused, log.claim("A.TEST", 443, before_a).?.kind);
    try std.testing.expect(log.claim("a.test", 443, before_a) == null);
    try std.testing.expectEqualStrings("b.test", log.claim("b.test", 443, before_a).?.target());

    // A full log keeps the newest capacity entries.
    for (0..FailureLog.capacity + 3) |i| {
        var f = Failure.init(.refused, "p", 1, "full.test", 443);
        f.status = @intCast(400 + i);
        log.add(f);
    }
    try std.testing.expectEqual(@as(u16, 403), log.claim("full.test", 443, 0).?.status);
}

test "interim 1xx heads come before the final answer and are skipped, except 101" {
    const cases = [_]struct { []const u8, Answer }{
        .{ "HTTP/1.1 102 Processing\r\n\r\nHTTP/1.1 200 OK\r\n\r\n", .ok },
        .{ "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 102 Processing\r\nX-Note: a\r\n\r\nHTTP/1.1 200 Connection established\r\n\r\n", .ok },
        .{ "HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\nHTTP/1.1 407 Proxy Authentication Required\r\n\r\n", .{ .status = 407 } },
        .{ "HTTP/1.1 199 Odd\r\n\r\nHTTP/1.1 502 Bad Gateway\r\n\r\n", .{ .status = 502 } },
        // 101 switches protocols, so it is a refusal and not an interim head.
        .{ "HTTP/1.1 101 Switching Protocols\r\n\r\nHTTP/1.1 200 OK\r\n\r\n", .{ .status = 101 } },
        // An interim head with nothing after it is no answer.
        .{ "HTTP/1.1 102 Processing\r\n\r\n", .closed },
        .{ "HTTP/1.1 102 Processing\r\n\r\nHTTP/1.1 200 OK\r\n", .malformed },
        .{ "HTTP/1.1 102 Processing\r\n\r\n\x16\x03\x01garbage", .malformed },
    };
    for (cases) |case| {
        var r = std.Io.Reader.fixed(case[0]);
        try std.testing.expectEqualDeep(case[1], try readConnectAnswer(&r));
    }
    // The bytes after the final head stay for the caller, as they do after a
    // lone head.
    var r = std.Io.Reader.fixed("HTTP/1.1 102 Processing\r\n\r\nHTTP/1.1 200 OK\r\n\r\ntunnel");
    try std.testing.expectEqual(Answer.ok, try readConnectAnswer(&r));
    try std.testing.expectEqualStrings("tunnel", try r.take(6));
}

test "interim heads share the head bound, so a proxy cannot stream them forever" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    // 1000 interim heads of 28 bytes pass 8192 bytes.
    for (0..1000) |_| try list.appendSlice(std.testing.allocator, "HTTP/1.1 102 Processing\r\n\r\n");
    try list.appendSlice(std.testing.allocator, "HTTP/1.1 200 OK\r\n\r\n");
    var r = std.Io.Reader.fixed(list.items);
    try std.testing.expectEqual(Answer.malformed, try readConnectAnswer(&r));
    // Heads that fit under the bound still reach their final answer.
    list.clearRetainingCapacity();
    for (0..100) |_| try list.appendSlice(std.testing.allocator, "HTTP/1.1 102 Processing\r\n\r\n");
    try list.appendSlice(std.testing.allocator, "HTTP/1.1 200 OK\r\n\r\n");
    r = std.Io.Reader.fixed(list.items);
    try std.testing.expectEqual(Answer.ok, try readConnectAnswer(&r));
}

test "random interim heads before a final head never change what the final head means" {
    const seed: u64 = 0x696e7465_72696d31;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const interim = [_]u16{ 100, 102, 103, 150, 199 };
    const finals = [_]struct { u16, bool }{ .{ 101, false }, .{ 200, true }, .{ 204, true }, .{ 299, true }, .{ 301, false }, .{ 407, false }, .{ 502, false }, .{ 504, false } };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..2000) |_| {
        text.clearRetainingCapacity();
        for (0..random.uintLessThan(usize, 12)) |_| {
            try text.print(std.testing.allocator, "HTTP/1.1 {d} Interim\r\n", .{interim[random.uintLessThan(usize, interim.len)]});
            for (0..random.uintLessThan(usize, 3)) |i| try text.print(std.testing.allocator, "X-{d}: v\r\n", .{i});
            try text.appendSlice(std.testing.allocator, "\r\n");
        }
        const final = finals[random.uintLessThan(usize, finals.len)];
        try text.print(std.testing.allocator, "HTTP/1.1 {d} Final\r\n\r\nrest", .{final[0]});
        errdefer std.debug.print("seed {x} text {s}\n", .{ seed, text.items });
        var r = std.Io.Reader.fixed(text.items);
        const expected: Answer = if (final[1]) .ok else .{ .status = final[0] };
        try std.testing.expectEqualDeep(expected, try readConnectAnswer(&r));
        try std.testing.expectEqualStrings("rest", try r.take(4));
    }
}

test "the snapshot keeps its own copy of what it reads, so a changed environment cannot reach it" {
    // The host program may setenv or unsetenv after the first connection, and
    // libc then reuses or frees the old strings. Overwriting them stands in
    // for that.
    var proxy_text = "http://user:p%40ss@proxy.test:3128".*;
    var plain_proxy_text = "http://plain.test:3128".*;
    var no_proxy_text = "internal.example, .corp.test,10.0.0.0/8".*;
    var socks_text = "socks5://u:secret@127.0.0.1:1080".*;
    var s: Snapshot = undefined;
    setTest(&s, &.{ .{ "https_proxy", &proxy_text }, .{ "http_proxy", &plain_proxy_text }, .{ "no_proxy", &no_proxy_text } });
    var refused: Snapshot = undefined;
    setTest(&refused, &.{.{ "ALL_PROXY", &socks_text }});
    @memset(&proxy_text, 0);
    @memset(&plain_proxy_text, 0);
    @memset(&no_proxy_text, 'x');
    @memset(&socks_text, 'x');

    const secure = route(&s, "api.example.com", 443, .https).tunnel;
    try std.testing.expectEqualStrings("proxy.test", secure.host);
    try std.testing.expectEqualStrings("Basic dXNlcjpwQHNz", secure.authorization.?);
    // A host with no percent escape is the case that borrowed the string.
    try std.testing.expectEqualStrings("plain.test", route(&s, "api.example.com", 80, .http).tunnel.host);
    try std.testing.expect(route(&s, "internal.example", 443, .https) == .direct);
    try std.testing.expect(route(&s, "a.corp.test", 443, .https) == .direct);
    try std.testing.expect(route(&s, "10.1.2.3", 443, .https) == .direct);
    try std.testing.expect(route(&s, "other.example", 443, .https) == .tunnel);
    var buf: [256]u8 = undefined;
    const text = Failure.refusal(route(&refused, "x.ai", 443, .https).refuse, "x.ai", 443).text(&buf);
    try std.testing.expectEqualStrings("fx supports only http:// proxies, but ALL_PROXY is socks5://...", text);
}

test "a proxy host may have underscores, and every refusal names its own reason" {
    var s: Snapshot = undefined;
    setTest(&s, &.{.{ "HTTPS_PROXY", "http://squid_proxy:3128" }});
    try std.testing.expect(route(&s, "x.ai", 443, .https) == .tunnel);
    try std.testing.expectEqualStrings("squid_proxy", route(&s, "x.ai", 443, .https).tunnel.host);
    setTest(&s, &.{.{ "https_proxy", "my_squid.corp_net.test" }});
    try std.testing.expectEqualStrings("my_squid.corp_net.test", route(&s, "x.ai", 443, .https).tunnel.host);

    var long_host: [300]u8 = @splat('a');
    // The user and password are joined into one buffer, so a user past it cannot be sent.
    var long_user: [600]u8 = @splat('u');
    var long_value: [2000]u8 = @splat('b');
    var url_buf: [512]u8 = undefined;
    const long_host_url = try std.mem.print(&url_buf, "http://{s}:1", .{&long_host});
    var user_url_buf: [768]u8 = undefined;
    const long_user_url = try std.mem.print(&user_url_buf, "http://{s}:pw@proxy.test:1", .{&long_user});
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "http:///path", "HTTPS_PROXY has no host name; use http://host:port" },
        .{ "http://bad_host!:1", "HTTPS_PROXY has a host name fx cannot use: bad_host!" },
        .{ "http://-bad-.test:1", "HTTPS_PROXY has a host name fx cannot use: -bad-.test" },
        // A host with a space, a control byte, or past 48 bytes is never repeated.
        .{ "http://a b:80", "HTTPS_PROXY has a host name fx cannot use" },
        .{ "http://%00:1", "HTTPS_PROXY has a host name fx cannot use" },
        .{ long_host_url, "HTTPS_PROXY has a host name fx cannot use" },
        .{ "http://proxy.test:99999", "HTTPS_PROXY has a port fx cannot use; use a number from 1 to 65535" },
        .{ "http://proxy.test:0", "HTTPS_PROXY has a port fx cannot use; use a number from 1 to 65535" },
        .{ long_user_url, "HTTPS_PROXY has a user name or password that is too long" },
        .{ &long_value, "HTTPS_PROXY is too long for fx to read" },
        .{ "http://[::1", "HTTPS_PROXY is not a proxy URL fx can read; use http://host:port" },
    };
    for (cases) |case| {
        setTest(&s, &.{.{ "HTTPS_PROXY", case[0] }});
        const decision = route(&s, "x.ai", 443, .https);
        try std.testing.expect(decision == .refuse);
        var buf: [256]u8 = undefined;
        try std.testing.expectEqualStrings(case[1], Failure.refusal(decision.refuse, "x.ai", 443).text(&buf));
    }
}

test "uppercase HTTP_PROXY is ignored when REQUEST_METHOD is set, and nothing else is" {
    var s: Snapshot = undefined;
    // A CGI server turns a request header "Proxy:" into HTTP_PROXY (httpoxy).
    setTest(&s, &.{ .{ "REQUEST_METHOD", "GET" }, .{ "HTTP_PROXY", "http://evil.test:80" }, .{ "HTTPS_PROXY", "http://proxy.test:3128" } });
    try std.testing.expect(route(&s, "example.com", 80, .http) == .direct);
    try std.testing.expectEqualStrings("proxy.test", route(&s, "example.com", 443, .https).tunnel.host);

    // Lowercase http_proxy and ALL_PROXY still apply; so does the guard's absence.
    setTest(&s, &.{ .{ "REQUEST_METHOD", "POST" }, .{ "HTTP_PROXY", "http://evil.test:80" }, .{ "http_proxy", "http://lower.test:80" } });
    try std.testing.expectEqualStrings("lower.test", route(&s, "example.com", 80, .http).tunnel.host);
    setTest(&s, &.{ .{ "REQUEST_METHOD", "GET" }, .{ "HTTP_PROXY", "http://evil.test:80" }, .{ "ALL_PROXY", "http://all.test:80" } });
    try std.testing.expectEqualStrings("all.test", route(&s, "example.com", 80, .http).tunnel.host);
    setTest(&s, &.{.{ "HTTP_PROXY", "http://upper.test:80" }});
    try std.testing.expectEqualStrings("upper.test", route(&s, "example.com", 80, .http).tunnel.host);
    // An empty REQUEST_METHOD is not a CGI request.
    setTest(&s, &.{ .{ "REQUEST_METHOD", "" }, .{ "HTTP_PROXY", "http://upper.test:80" } });
    try std.testing.expectEqualStrings("upper.test", route(&s, "example.com", 80, .http).tunnel.host);
}

test "a retry notice carries the proxy sentence, and the status gives way first" {
    var out: [95]u8 = undefined;
    const dead = "could not connect to proxy 127.0.0.1:54321 (connection refused)";
    const silent = "proxy p.test:80 did not answer CONNECT to x.ai:443";
    // It fits whole.
    try std.testing.expectEqualStrings(
        "Offline \u{b7} next try in 1s \u{b7} " ++ dead,
        statusWithProxy(&out, "Offline \u{b7} next try in 1s", dead),
    );
    try std.testing.expectEqualStrings(
        "Offline \u{b7} retrying \u{b7} attempt 2 \u{b7} 2s \u{b7} " ++ silent,
        statusWithProxy(&out, "Offline \u{b7} retrying \u{b7} attempt 2 \u{b7} 2s", silent),
    );
    // The last parts of the status go first: the clock, then the attempt.
    try std.testing.expectEqualStrings(
        "Offline \u{b7} retrying \u{b7} attempt 2 \u{b7} " ++ dead[0..58],
        statusWithProxy(&out, "Offline \u{b7} retrying \u{b7} attempt 2 \u{b7} 2s", dead[0..58]),
    );
    try std.testing.expectEqualStrings(
        "Offline \u{b7} retrying \u{b7} " ++ dead,
        statusWithProxy(&out, "Offline \u{b7} retrying \u{b7} attempt 112 \u{b7} 1h 02m", dead),
    );
    // A long sentence keeps itself whole by dropping what the status adds.
    const refused = "proxy 127.0.0.1:54321 refused CONNECT to proxy-target.test:443: 502 Bad Gateway";
    try std.testing.expectEqualStrings(
        "Offline \u{b7} " ++ refused,
        statusWithProxy(&out, "Offline \u{b7} next try in 1s", refused),
    );
    // No status, or a status that is only the cause, still carries it.
    try std.testing.expectEqualStrings(dead, statusWithProxy(&out, "", dead));
    // Past the room the sentence is cut at a character and marked.
    var long_sentence: [200]u8 = @splat('p');
    const cut = statusWithProxy(&out, "Offline \u{b7} retrying", &long_sentence);
    try std.testing.expect(cut.len <= out.len);
    try std.testing.expect(std.mem.endsWith(u8, cut, "\u{2026}"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "a retry notice always fits, stays valid text, and names the proxy when the sentence fits" {
    const seed: u64 = 0x6e6f7469_63653031;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const parts = [_][]const u8{ "Offline", "Connection lost", "next try in 1s", "retrying", "attempt 12", "2m 05s", "Gateway error", "caf\u{e9} x" };
    const alphabet = [_][]const u8{ "a", "b", "c", " ", "1", ":", ".", "(", ")", "\u{b7}", "\u{e9}" };
    var status_buf: [160]u8 = undefined;
    var sentence_buf: [160]u8 = undefined;
    var out_buf: [160]u8 = undefined;
    for (0..20_000) |_| {
        var status_len: usize = 0;
        for (0..random.uintLessThan(usize, 5)) |i| {
            const part = parts[random.uintLessThan(usize, parts.len)];
            if (status_len + part.len + status_separator.len > status_buf.len) break;
            if (i != 0) {
                @memcpy(status_buf[status_len..][0..status_separator.len], status_separator);
                status_len += status_separator.len;
            }
            @memcpy(status_buf[status_len..][0..part.len], part);
            status_len += part.len;
        }
        var sentence_len: usize = 0;
        const want = random.uintAtMost(usize, 150);
        while (sentence_len < want) {
            const unit = alphabet[random.uintLessThan(usize, alphabet.len)];
            @memcpy(sentence_buf[sentence_len..][0..unit.len], unit);
            sentence_len += unit.len;
        }
        const sentence = sentence_buf[0..sentence_len];
        const room = random.intRangeAtMost(usize, 8, out_buf.len);
        errdefer std.debug.print("seed {x} status {s} sentence {s} room {d}\n", .{ seed, status_buf[0..status_len], sentence, room });
        const text = statusWithProxy(out_buf[0..room], status_buf[0..status_len], sentence);
        try std.testing.expect(text.len <= room);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text));
        if (sentence.len <= room) try std.testing.expect(std.mem.endsWith(u8, text, sentence));
    }
}

fn shortFailure(kind: FailureKind, host: []const u8, port: u16, status: u16) Failure {
    var f = Failure.init(kind, host, port, "x.ai", 443);
    f.status = status;
    return f;
}

test "the short form of a proxy failure names the proxy and the cause in a few words" {
    var buf: [max_notice_bytes]u8 = undefined;
    const cases = [_]struct { Failure, []const u8 }{
        .{ shortFailure(.refused, "127.0.0.1", 50132, 502), "proxy 127.0.0.1:50132 answered 502" },
        .{ shortFailure(.refused, "127.0.0.1", 50132, 503), "proxy 127.0.0.1:50132 answered 503" },
        .{ shortFailure(.refused, "127.0.0.1", 50132, 504), "proxy 127.0.0.1:50132 answered 504" },
        .{ shortFailure(.unreachable_proxy, "127.0.0.1", 50132, 0), "proxy 127.0.0.1:50132 unreachable" },
        .{ shortFailure(.no_answer, "127.0.0.1", 50132, 0), "proxy 127.0.0.1:50132 did not answer" },
        .{ shortFailure(.malformed, "127.0.0.1", 50132, 0), "proxy 127.0.0.1:50132 sent bad data" },
        .{ shortFailure(.unreachable_proxy, "fd00::1", 3128, 0), "proxy [fd00::1]:3128 unreachable" },
        .{ shortFailure(.unreachable_proxy, "squid_proxy.invalid", 3128, 0), "proxy squid_proxy.invalid:3128 unreachable" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], case[0].shortText(&buf));

    // A refused proxy variable has no host to name; the variable says it.
    const refused = Failure.refusal(.{ .variable = "HTTPS_PROXY", .reason = .bad_port }, "x.ai", 443);
    try std.testing.expectEqualStrings("HTTPS_PROXY unusable", refused.shortText(&buf));
    const socks = Failure.refusal(.{ .variable = "ALL_PROXY", .reason = .unsupported_scheme, .detail = "socks5" }, "x.ai", 443);
    try std.testing.expectEqualStrings("ALL_PROXY unusable", socks.shortText(&buf));

    // The full sentence is untouched.
    var full: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "proxy 127.0.0.1:50132 refused CONNECT to x.ai:443: 502 Bad Gateway",
        cases[0][0].text(&full),
    );
}

test "a proxy host past the budget is cut with an ellipsis, and the port and the cause stay whole" {
    var buf: [max_notice_bytes]u8 = undefined;
    var host: [253]u8 = @splat('h');

    // 25 bytes of host is the most "proxy HOST:3128 unreachable" holds in 48 bytes.
    const fits = shortFailure(.unreachable_proxy, host[0..25], 3128, 0).shortText(&buf);
    try std.testing.expectEqual(@as(usize, max_notice_bytes), fits.len);
    try std.testing.expect(std.mem.find(u8, fits, "\u{2026}") == null);
    // One byte more is cut, and the cut host plus its ellipsis take the same 25 bytes.
    const over = shortFailure(.unreachable_proxy, host[0..26], 3128, 0).shortText(&buf);
    try std.testing.expectEqualStrings("proxy hhhhhhhhhhhhhhhhhhhhhh\u{2026}:3128 unreachable", over);
    try std.testing.expectEqual(@as(usize, max_notice_bytes), over.len);
    // The longest host name.
    const longest = shortFailure(.unreachable_proxy, &host, 3128, 0).shortText(&buf);
    try std.testing.expectEqualStrings(over, longest);

    // The longest port and the longest cause leave the least room for the host.
    const tight = shortFailure(.no_answer, &host, 65535, 0).shortText(&buf);
    try std.testing.expectEqualStrings("proxy hhhhhhhhhhhhhhhhhh\u{2026}:65535 did not answer", tight);
    try std.testing.expect(tight.len <= max_notice_bytes);

    // A host is never a multi-byte name, but the cut must still end on a
    // character: the euro sign takes three bytes, and the cut at 22 falls
    // inside the eighth.
    var euros: [60]u8 = undefined;
    for (0..20) |i| @memcpy(euros[i * 3 ..][0..3], "\u{20ac}");
    const euro = shortFailure(.unreachable_proxy, &euros, 3128, 0).shortText(&buf);
    try std.testing.expect(std.unicode.utf8ValidateSlice(euro));
    try std.testing.expect(euro.len <= max_notice_bytes);
    try std.testing.expect(std.mem.find(u8, euro, "\u{2026}:3128 unreachable") != null);

    // An IPv6 address is cut inside its brackets.
    const v6 = shortFailure(.unreachable_proxy, "2001:0db8:85a3:0000:0000:8a2e:0370:7334", 3128, 0).shortText(&buf);
    try std.testing.expectEqualStrings("proxy [2001:0db8:85a3:0000:\u{2026}]:3128 unreachable", v6);
    try std.testing.expect(std.unicode.utf8ValidateSlice(v6));
}

test "a notice with the short form keeps the cause and the wait part of every status that takes it" {
    const sep = status_separator;
    const statuses = [_][]const u8{
        "Offline \u{b7} next try in 59m 59s",
        "Connection lost \u{b7} next try in 59m 59s \u{b7} attempt 65535",
        "Unreadable reply \u{b7} next try in 59m 59s \u{b7} attempt 65535",
        "Gateway error \u{b7} next try in 59m 59s \u{b7} attempt 65535",
        "Rate limited \u{b7} next try in 59m 59s \u{b7} attempt 65535",
        "Offline \u{b7} retrying \u{b7} attempt 65535",
        "Connection lost \u{b7} retrying \u{b7} attempt 65535",
        "Gateway error \u{b7} retrying without Fast \u{b7} attempt 65535",
    };
    var host: [253]u8 = @splat('h');
    const failures = [_]Failure{
        shortFailure(.refused, &host, 65535, 504),
        shortFailure(.unreachable_proxy, &host, 65535, 0),
        shortFailure(.no_answer, &host, 65535, 0),
        shortFailure(.malformed, &host, 65535, 0),
    };
    var note_buf: [max_notice_bytes]u8 = undefined;
    var line: [95]u8 = undefined;
    for (failures) |failure| {
        const note = failure.shortText(&note_buf);
        for (statuses) |status| {
            const text = statusWithProxy(&line, status, note);
            // The first two parts, the cause and the wait or the retry, stay.
            const first = std.mem.find(u8, status, sep).?;
            const second = std.mem.find(u8, status[first + sep.len ..], sep);
            const kept = status[0..if (second) |s| first + sep.len + s else status.len];
            try std.testing.expect(text.len <= line.len);
            try std.testing.expect(std.mem.startsWith(u8, text, kept));
            // The note stays whole, after a separator.
            try std.testing.expect(std.mem.endsWith(u8, text, note));
            try std.testing.expect(std.mem.endsWith(u8, text[0 .. text.len - note.len], sep));
            try std.testing.expect(std.unicode.utf8ValidateSlice(text));
        }
    }
}

test "the short form fits its budget, stays valid text, and keeps its port and cause, for random hosts" {
    const seed: u64 = 0x73686f72_74666f72;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789-._";
    var host_buf: [253]u8 = undefined;
    var note_buf: [max_notice_bytes]u8 = undefined;
    var expect_buf: [32]u8 = undefined;
    for (0..20_000) |_| {
        const kinds = [_]FailureKind{ .refused, .unreachable_proxy, .no_answer, .malformed };
        const kind = kinds[random.uintLessThan(usize, kinds.len)];
        const ipv6 = random.boolean();
        const len = random.intRangeAtMost(usize, 1, host_buf.len);
        for (host_buf[0..len]) |*byte| byte.* = if (ipv6) "0123456789abcdef:"[random.uintLessThan(usize, 17)] else alphabet[random.uintLessThan(usize, alphabet.len)];
        if (ipv6) host_buf[0] = '2';
        if (ipv6 and std.mem.findScalar(u8, host_buf[0..len], ':') == null) host_buf[len - 1] = ':';
        const host = host_buf[0..len];
        const port = random.intRangeAtMost(u16, 1, 65535);
        const status = random.intRangeAtMost(u16, 500, 599);
        const failure = shortFailure(kind, host, port, status);
        errdefer std.debug.print("seed {x} kind {t} host {s} port {d}\n", .{ seed, kind, host, port });
        const note = failure.shortText(&note_buf);
        try std.testing.expect(note.len <= max_notice_bytes);
        try std.testing.expect(std.unicode.utf8ValidateSlice(note));
        try std.testing.expect(std.mem.startsWith(u8, note, "proxy "));
        const tail = switch (kind) {
            .refused => try std.mem.print(&expect_buf, ":{d} answered {d}", .{ port, status }),
            .unreachable_proxy => try std.mem.print(&expect_buf, ":{d} unreachable", .{port}),
            .no_answer => try std.mem.print(&expect_buf, ":{d} did not answer", .{port}),
            .malformed => try std.mem.print(&expect_buf, ":{d} sent bad data", .{port}),
            .unsupported_scheme, .invalid_url => "",
        };
        const close = if (ipv6) "]" else "";
        try std.testing.expect(std.mem.endsWith(u8, note, tail));
        try std.testing.expect(std.mem.endsWith(u8, note[0 .. note.len - tail.len], close));
        // A host that fits is named whole; one that does not is cut with an ellipsis.
        const room = max_notice_bytes - "proxy ".len - close.len * 2 - tail.len;
        if (len <= room) {
            try std.testing.expect(std.mem.find(u8, note, host) != null);
            try std.testing.expect(std.mem.find(u8, note, "\u{2026}") == null);
        } else {
            try std.testing.expect(std.mem.find(u8, note, "\u{2026}") != null);
        }
    }
}

test "the trace note holds the whole sentence in quotes, and a small buffer cuts the sentence and keeps the quote" {
    const proxy: Proxy = .{ .host = "127.0.0.1", .port = 3128, .authorization = "Basic c2VjcmV0", .variable = "HTTPS_PROXY" };
    var buf: [Failure.trace_note_bytes]u8 = undefined;
    const refused = answerFailure(.{ .status = 407 }, proxy, "x.ai", 443).?;
    try std.testing.expectEqualStrings(
        " proxy=\"proxy 127.0.0.1:3128 refused CONNECT to x.ai:443: 407 Proxy Authentication Required\"",
        refused.traceNote(&buf),
    );
    const down = Failure.init(.unreachable_proxy, "127.0.0.1", 3128, "x.ai", 443).withDetail("connection refused");
    try std.testing.expectEqualStrings(" proxy=\"could not connect to proxy 127.0.0.1:3128 (connection refused)\"", down.traceNote(&buf));
    try std.testing.expect(std.mem.find(u8, refused.traceNote(&buf), "c2VjcmV0") == null);

    // The closing quote is kept however small the buffer is.
    var small: [20]u8 = undefined;
    try std.testing.expectEqualStrings(" proxy=\"proxy 127.0.0.1:3128 refused CONNECT to x.ai:443: 407 Proxy Authentication Required\""[0..19] ++ "\"", refused.traceNote(&small));
    try std.testing.expectEqualStrings(" proxy=\"\"", refused.traceNote(buf[0..9]));
    try std.testing.expectEqualStrings("", refused.traceNote(buf[0..8]));
    try std.testing.expectEqualStrings("", refused.traceNote(buf[0..0]));

    // Two hosts of 253 bytes make a sentence longer than the room: the note
    // fills the room, ends in the quote, and never runs past the buffer.
    const long_proxy: [253]u8 = @splat('a');
    const long_target: [253]u8 = @splat('b');
    var long = Failure.init(.refused, &long_proxy, 3128, &long_target, 443);
    long.status = 407;
    const note = long.traceNote(&buf);
    try std.testing.expectEqual(@as(usize, Failure.trace_note_bytes), note.len);
    try std.testing.expect(std.mem.startsWith(u8, note, " proxy=\"proxy aaaa"));
    try std.testing.expectEqual(@as(u8, '"'), note[note.len - 1]);
}

test "5000 random failures make a trace note that fits, is quoted, and repeats no credentials" {
    const seed: u64 = 0x74726163_65206e74;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789-._";
    var proxy_buf: [253]u8 = undefined;
    var target_buf: [253]u8 = undefined;
    var buf: [Failure.trace_note_bytes]u8 = undefined;
    var secret_buf: [24]u8 = undefined;
    for (0..5_000) |_| {
        const proxy_len = random.intRangeAtMost(usize, 1, proxy_buf.len);
        const target_len = random.intRangeAtMost(usize, 1, target_buf.len);
        for (proxy_buf[0..proxy_len]) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        for (target_buf[0..target_len]) |*byte| byte.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        const secret = std.mem.print(&secret_buf, "Basic s{x}", .{random.int(u64)}) catch unreachable;
        const proxy: Proxy = .{ .host = proxy_buf[0..proxy_len], .port = random.intRangeAtMost(u16, 1, 65535), .authorization = secret, .variable = "HTTPS_PROXY" };
        const target = target_buf[0..target_len];
        const failures = [_]Failure{
            answerFailure(.{ .status = random.intRangeAtMost(u16, 100, 599) }, proxy, target, 443).?,
            answerFailure(.malformed, proxy, target, 443).?,
            answerFailure(.closed, proxy, target, 443).?,
            Failure.init(.unreachable_proxy, proxy.host, proxy.port, target, 443).withDetail("connection refused"),
        };
        for (failures) |failure| {
            errdefer std.debug.print("seed {x} kind {t} proxy {s} target {s}\n", .{ seed, failure.kind, proxy.host, target });
            const note = failure.traceNote(&buf);
            try std.testing.expect(note.len >= " proxy=\"\"".len and note.len <= Failure.trace_note_bytes);
            try std.testing.expect(std.mem.startsWith(u8, note, " proxy=\""));
            try std.testing.expectEqual(@as(u8, '"'), note[note.len - 1]);
            try std.testing.expect(std.unicode.utf8ValidateSlice(note));
            try std.testing.expect(std.mem.find(u8, note, secret) == null);
        }
    }
}

fn fuzzAnswer(_: void, smith: *std.testing.Smith) !void {
    var buf: [max_answer_head_bytes + 64]u8 = undefined;
    const len = smith.slice(&buf);
    var r = std.Io.Reader.fixed(buf[0..len]);
    const answer = try readConnectAnswer(&r);
    // The reader never reads past the head it accepts.
    switch (answer) {
        .ok, .status => {
            const consumed = @as(usize, len) - r.bufferedLen();
            try std.testing.expect(consumed <= max_answer_head_bytes);
            try std.testing.expectEqualStrings("\r\n\r\n", buf[consumed - 4 .. consumed]);
        },
        .malformed, .closed => {},
    }
    // An interim head other than 101 is never the answer: the reader skips it.
    if (answer == .status) try std.testing.expect(answer.status == 101 or answer.status >= 300);
}

test "the CONNECT answer reader stays inside the head on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzAnswer, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "HTTP/1.1 200 Connection established\r\n\r\n",
            "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic\r\n\r\nrest",
            "\x16\x03\x01\x00\x05hello",
            "HTTP/1.1 102 Processing\r\n\r\nHTTP/1.1 200 OK\r\n\r\n",
            "HTTP/1.1 101 Switching Protocols\r\n\r\nHTTP/1.1 200 OK\r\n\r\n",
        }) ++ @import("fuzz_corpus").net_proxy_answer.*),
    });
}

fn fuzzEnvironment(_: void, smith: *std.testing.Smith) !void {
    var proxy_buf: [512]u8 = undefined;
    var no_proxy_buf: [2048]u8 = undefined;
    var host_buf: [300]u8 = undefined;
    const proxy = proxy_buf[0..smith.slice(&proxy_buf)];
    const no_proxy = no_proxy_buf[0..smith.slice(&no_proxy_buf)];
    const host = host_buf[0..smith.slice(&host_buf)];
    const port = smith.value(u16);
    // Read after the others, so inputs saved before it still replay.
    const cgi = smith.value(bool);
    const dial_error = dial_error_names[smith.value(u8) % dial_error_names.len];
    var s: Snapshot = undefined;
    setTest(&s, &.{ .{ "https_proxy", proxy }, .{ "no_proxy", no_proxy } });
    var text_buf: [1024]u8 = undefined;
    const first = route(&s, host, port, .https);
    var kept: [HostName.max_len]u8 = undefined;
    const kept_host: []const u8 = switch (first) {
        .tunnel => |t| blk: {
            @memcpy(kept[0..t.host.len], t.host);
            break :blk kept[0..t.host.len];
        },
        else => "",
    };
    switch (first) {
        .direct => {},
        .tunnel => |t| {
            // A tunnel always names a usable proxy, and the failure text
            // never repeats its credentials.
            try std.testing.expect(t.host.len > 0);
            const f = answerFailure(.{ .status = 407 }, t, host, port).?;
            if (t.authorization) |value| try std.testing.expect(std.mem.find(u8, f.text(&text_buf), value) == null);
            // The short form a retry notice carries fits its budget and never
            // repeats the credentials either.
            var note_buf: [max_notice_bytes]u8 = undefined;
            const note = f.shortText(&note_buf);
            try std.testing.expect(note.len <= max_notice_bytes);
            try std.testing.expect(std.unicode.utf8ValidateSlice(note));
            if (t.authorization) |value| try std.testing.expect(std.mem.find(u8, note, value) == null);
            // The trace note a reviewer's failed request carries fits its room,
            // ends in its quote, and repeats no credentials, for each way the
            // connection can fail.
            var trace_buf: [Failure.trace_note_bytes]u8 = undefined;
            const unreachable_proxy = Failure.init(.unreachable_proxy, t.host, t.port, host, port).withDetail("connection refused");
            for ([_]Failure{ f, unreachable_proxy }) |failure| {
                const trace_note = failure.traceNote(&trace_buf);
                try std.testing.expect(trace_note.len <= Failure.trace_note_bytes);
                try std.testing.expect(std.mem.startsWith(u8, trace_note, " proxy=\""));
                try std.testing.expectEqual(@as(u8, '"'), trace_note[trace_note.len - 1]);
                if (t.authorization) |value| try std.testing.expect(std.mem.find(u8, trace_note, value) == null);
            }
        },
        .refuse => |r| {
            // A refusal names only the variable and a short plain scheme.
            const text = Failure.refusal(r, host, port).text(&text_buf);
            try std.testing.expect(std.mem.startsWith(u8, text, "fx supports only http:// proxies, but https_proxy ") or
                std.mem.startsWith(u8, text, "https_proxy is not a proxy URL fx can read") or
                std.mem.startsWith(u8, text, "https_proxy has ") or
                std.mem.startsWith(u8, text, "https_proxy is too long for fx to read"));
            try std.testing.expect(text.len <= 128);
            // The message never repeats a control byte or a byte past ASCII.
            for (text) |byte| try std.testing.expect(byte >= ' ' and byte < 0x7f);
        },
    }

    // The host program changes the environment after the snapshot: the route
    // is the one the snapshot read.
    @memset(proxy, 0xff);
    @memset(no_proxy, 0xff);
    const again = route(&s, host, port, .https);
    try std.testing.expectEqual(std.meta.activeTag(first), std.meta.activeTag(again));
    if (again == .tunnel) try std.testing.expectEqualStrings(kept_host, again.tunnel.host);

    // A failure toward the proxy ends with a name the claim lists, whatever
    // name the platform gave the dial, and a name it already lists is kept.
    try std.testing.expect(isProxyFailureError(proxyFailureError(dial_error)));
    if (isProxyFailureError(dial_error)) try std.testing.expect(proxyFailureError(dial_error) == dial_error);

    // With REQUEST_METHOD set, an uppercase HTTP_PROXY alone proxies nothing.
    var cgi_env: Snapshot = undefined;
    setTest(&cgi_env, &.{ .{ "HTTP_PROXY", "http://evil.test:80" }, .{ "REQUEST_METHOD", if (cgi) "GET" else "" } });
    if (cgi) try std.testing.expect(route(&cgi_env, host, 80, .http) == .direct);
}

test "proxy variables and NO_PROXY lists route fuzzed hosts without leaking credentials" {
    try std.testing.fuzz({}, fuzzEnvironment, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "http://user:p%40ss@proxy.test:3128",
            "http://squid_proxy:3128",
            "http:///path",
            "http://proxy.test:99999",
        }) ++ @import("fuzz_corpus").net_proxy_environment.*),
    });
}
