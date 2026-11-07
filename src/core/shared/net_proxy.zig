//! Routes fx's outbound connections through the proxy the environment names.
//!
//! The pure core: parsing the proxy variables once, deciding the route for a
//! host and port, writing CONNECT, reading the proxy's answer, naming a
//! failure, and keeping the log a request claims its own failure from. It
//! does no I/O and imports only std. `net_proxy_io.zig` installs it in the
//! process Io, so every connection fx opens by host name goes through it.
//! `tests/tla/net_proxy/NetProxy.tla` models it, and
//! `tests/tla/drivers/net_proxy/driver.ts` walks this file along that model.
const std = @import("std");

const IpAddress = std.Io.net.IpAddress;
const HostName = std.Io.net.HostName;
const basic = std.http.Client.basic_authorization;

pub const max_no_proxy_entries = 1000;
pub const max_answer_head_bytes = 8192;
const max_proxy_url_bytes = 1024;
/// Routes loopback through the proxy too, for end-to-end tests whose fake
/// endpoints fx accepts only on loopback (`tests/e2e/net-proxy.test.ts`).
pub const loopback_test_variable = "FX_TEST_NET_PROXY_LOOPBACK";

/// What a connection carries, as far as the route cares: plain HTTP uses
/// http_proxy, everything else https_proxy.
pub const Scheme = enum { http, https };

pub const Reason = enum {
    /// The proxy URL names a scheme other than http://, such as socks5://.
    unsupported_scheme,
    /// The proxy URL does not parse or has no host.
    invalid_url,
};

pub const Refusal = struct {
    variable: []const u8,
    reason: Reason,
    /// The URL's scheme, for the message; never its credentials.
    scheme: []const u8 = "",
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

/// What the environment says, parsed once. Borrows the environment's values
/// and points into its own buffers, so it stays where `parse` filled it.
pub const Snapshot = struct {
    https: Slot = .none,
    http: Slot = .none,
    route_loopback: bool = false,
    no_proxy_all: bool = false,
    no_proxy: [max_no_proxy_entries]NoProxyEntry = undefined,
    no_proxy_len: usize = 0,
    host_buf: [2][HostName.max_len]u8 = undefined,
    auth_buf: [2][basic.max_value_len]u8 = undefined,
    url_buf: [2][max_proxy_url_bytes]u8 = undefined,

    /// Whether any proxy variable is set, so a route can tunnel at all.
    pub fn routes(s: *const Snapshot) bool {
        return s.https != .none or s.http != .none;
    }
};

/// Fills `s` from `env`, which has `fn get(env, name) ?[]const u8`.
/// Lowercase names win, as curl reads them, and an empty value counts as unset.
pub fn parse(s: *Snapshot, env: anytype) void {
    s.* = .{};
    s.https = parseSlot(s, 0, env, &.{ "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY" });
    s.http = parseSlot(s, 1, env, &.{ "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY" });
    if (env.get(loopback_test_variable)) |value| s.route_loopback = std.mem.eql(u8, value, "1");
    const no_proxy = first(env, &.{ "no_proxy", "NO_PROXY" }) orelse return;
    var it = std.mem.tokenizeAny(u8, no_proxy.value, ", \t");
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, "*")) {
            s.no_proxy_all = true;
            continue;
        }
        if (s.no_proxy_len == max_no_proxy_entries) break;
        s.no_proxy[s.no_proxy_len] = NoProxyEntry.parse(entry) orelse continue;
        s.no_proxy_len += 1;
    }
}

const Found = struct { name: []const u8, value: []const u8 };

fn first(env: anytype, comptime names: []const []const u8) ?Found {
    inline for (names) |name| {
        if (env.get(name)) |value| {
            if (value.len != 0) return .{ .name = name, .value = value };
        }
    }
    return null;
}

fn parseSlot(s: *Snapshot, index: usize, env: anytype, comptime names: []const []const u8) Slot {
    const found = first(env, names) orelse return .none;
    const refuse = struct {
        fn refuse(variable: []const u8, reason: Reason, scheme: []const u8) Slot {
            return .{ .refuse = .{ .variable = variable, .reason = reason, .scheme = scheme } };
        }
    }.refuse;
    // "proxy:3128" names a host and port, not a scheme, as curl reads it.
    const text = if (std.mem.find(u8, found.value, "://") != null)
        found.value
    else
        std.mem.print(&s.url_buf[index], "http://{s}", .{found.value}) catch return refuse(found.name, .invalid_url, "");
    const uri = std.Uri.parse(text) catch return refuse(found.name, .invalid_url, "");
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return refuse(found.name, .unsupported_scheme, printableScheme(uri.scheme));
    const component = uri.host orelse return refuse(found.name, .invalid_url, "");
    const raw = component.toRaw(&s.host_buf[index]) catch return refuse(found.name, .invalid_url, "");
    const host = if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']') raw[1 .. raw.len - 1] else raw;
    if (parseIp(host) == null) HostName.validate(host) catch return refuse(found.name, .invalid_url, "");
    const authorization: ?[]const u8 = if (uri.user != null or uri.password != null)
        basicAuthorization(uri, &s.auth_buf[index]) orelse return refuse(found.name, .invalid_url, "")
    else
        null;
    return .{ .proxy = .{
        .host = host,
        .port = uri.port orelse 80,
        .authorization = authorization,
        .variable = found.name,
    } };
}

/// The scheme, when it is short and plain enough to repeat in a message.
fn printableScheme(scheme: []const u8) []const u8 {
    if (scheme.len == 0 or scheme.len > 16) return "";
    for (scheme) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '-' and byte != '.') return "";
    }
    return scheme;
}

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

pub fn isLoopback(host: []const u8) bool {
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
pub const NoProxyEntry = struct {
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
        if (text.len == 0) return null;
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

/// Reads the proxy's answer head and nothing past it.
pub fn readConnectAnswer(r: *std.Io.Reader) error{ReadFailed}!Answer {
    var head: [max_answer_head_bytes]u8 = undefined;
    var len: usize = 0;
    while (true) {
        if (len == head.len) return .malformed;
        head[len] = r.takeByte() catch |err| switch (err) {
            error.EndOfStream => return if (len == 0) .closed else .malformed,
            error.ReadFailed => return error.ReadFailed,
        };
        len += 1;
        if (len >= 4 and std.mem.eql(u8, head[len - 4 .. len], "\r\n\r\n")) break;
    }
    const line_end = std.mem.find(u8, head[0..len], "\r\n").?;
    const line = head[0..line_end];
    if (line.len < 12 or !std.mem.startsWith(u8, line, "HTTP/1.") or line[8] != ' ') return .malformed;
    const status = std.fmt.parseInt(u16, line[9..12], 10) catch return .malformed;
    if (status < 100) return .malformed;
    if (line.len > 12 and line[12] != ' ') return .malformed;
    if (status >= 200 and status < 300) return .ok;
    return .{ .status = status };
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
    proxy_len: u8 = 0,
    target_len: u8 = 0,
    /// The variable name, the URL's scheme, or the connect error's name.
    detail_len: u8 = 0,
    variable_len: u8 = 0,
    proxy_buf: [HostName.max_len]u8 = undefined,
    target_buf: [HostName.max_len]u8 = undefined,
    detail_buf: [32]u8 = undefined,
    variable_buf: [16]u8 = undefined,

    pub fn init(kind: FailureKind, proxy_host: []const u8, proxy_port: u16, target_host: []const u8, target_port: u16) Failure {
        var f: Failure = .{ .kind = kind, .proxy_port = proxy_port, .target_port = target_port };
        f.proxy_len = copyInto(&f.proxy_buf, proxy_host);
        f.target_len = copyInto(&f.target_buf, target_host);
        return f;
    }

    pub fn refusal(r: Refusal, target_host: []const u8, target_port: u16) Failure {
        var f = init(switch (r.reason) {
            .unsupported_scheme => .unsupported_scheme,
            .invalid_url => .invalid_url,
        }, "", 0, target_host, target_port);
        f.variable_len = copyInto(&f.variable_buf, r.variable);
        f.detail_len = copyInto(&f.detail_buf, r.scheme);
        return f;
    }

    pub fn withDetail(f: Failure, value: []const u8) Failure {
        var copy = f;
        copy.detail_len = copyInto(&copy.detail_buf, value);
        return copy;
    }

    pub fn target(f: *const Failure) []const u8 {
        return f.target_buf[0..f.target_len];
    }

    pub fn proxyHost(f: *const Failure) []const u8 {
        return f.proxy_buf[0..f.proxy_len];
    }

    fn detail(f: *const Failure) []const u8 {
        return f.detail_buf[0..f.detail_len];
    }

    fn variable(f: *const Failure) []const u8 {
        return f.variable_buf[0..f.variable_len];
    }

    pub fn targetIs(f: *const Failure, host: []const u8, port: u16) bool {
        return f.target_port == port and std.ascii.eqlIgnoreCase(f.target(), host);
    }

    /// The sentence fx shows for the failure. It names the proxy and the
    /// reason and never the proxy's credentials.
    pub fn write(f: *const Failure, w: *std.Io.Writer) std.Io.Writer.Error!void {
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
                try w.print(" ({s})", .{plainConnectError(f.detail())});
            },
            .unsupported_scheme => if (f.detail_len == 0)
                try w.print("fx supports only http:// proxies, but {s} names another kind", .{f.variable()})
            else
                try w.print("fx supports only http:// proxies, but {s} is {s}://...", .{ f.variable(), f.detail() }),
            .invalid_url => try w.print("{s} is not a proxy URL fx can read; use http://host:port", .{f.variable()}),
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
};

fn copyInto(buf: []u8, bytes: []const u8) u8 {
    const n: u8 = @intCast(@min(bytes.len, buf.len, std.math.maxInt(u8)));
    @memcpy(buf[0..n], bytes[0..n]);
    return n;
}

fn plainConnectError(name: []const u8) []const u8 {
    const pairs = .{
        .{ "ConnectionRefused", "connection refused" },
        .{ "ConnectionResetByPeer", "connection reset" },
        .{ "Timeout", "timed out" },
        .{ "ConnectionTimedOut", "timed out" },
        .{ "HostUnreachable", "host unreachable" },
        .{ "NetworkUnreachable", "network unreachable" },
        .{ "NetworkDown", "network is down" },
        .{ "UnknownHostName", "cannot resolve its name" },
        .{ "NameServerFailure", "cannot resolve its name" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, name, pair[0])) return pair[1];
    }
    return name;
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
/// fails with it may claim its proxy failure. Others never do.
pub fn isProxyFailureError(err: anyerror) bool {
    return switch (err) {
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

/// The proxy failures of recent connections, each for its own target. A
/// request marks the log before it opens and, when it fails, claims the
/// oldest unclaimed failure for its own target logged since its mark; the
/// claim uses the record up, so no other request can show it
/// (`tests/tla/net_proxy/NetProxy.tla` DetailBelongsToFailingConnect,
/// DetailNamesOwnTarget, DetailReadOnce). Oldest first leaves the later
/// failures for the requests that started later. Not thread-safe; the caller
/// holds a lock.
pub const FailureLog = struct {
    pub const capacity = 32;

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
    pub fn get(e: TestEnv, name: []const u8) ?[]const u8 {
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
    try std.testing.expectEqual(Reason.invalid_url, invalid.reason);
    try std.testing.expectEqualStrings("HTTPS_PROXY is not a proxy URL fx can read; use http://host:port", Failure.refusal(invalid, "x.ai", 443).text(&buf));

    setTest(&s, &.{.{ "HTTPS_PROXY", "http://bad_host!:1" }});
    try std.testing.expectEqual(Reason.invalid_url, route(&s, "x.ai", 443, .https).refuse.reason);
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
    try std.testing.expect(route(&s, "skip999.example", 443, .https) == .direct);
    try std.testing.expect(route(&s, "skip1000.example", 443, .https) == .tunnel);
    try std.testing.expect(route(&s, "h1.unlisted.test", 443, .https) == .tunnel);
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
    const unreachable_proxy = Failure.init(.unreachable_proxy, "fd00::1", 3128, "x.ai", 443).withDetail("ConnectionRefused");
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
    if (answer == .status) try std.testing.expect(answer.status >= 100 and (answer.status < 200 or answer.status >= 300));
}

test "the CONNECT answer reader stays inside the head on fuzzed bytes" {
    try std.testing.fuzz({}, fuzzAnswer, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "HTTP/1.1 200 Connection established\r\n\r\n",
            "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic\r\n\r\nrest",
            "\x16\x03\x01\x00\x05hello",
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
    var s: Snapshot = undefined;
    setTest(&s, &.{ .{ "https_proxy", proxy }, .{ "no_proxy", no_proxy } });
    var text_buf: [1024]u8 = undefined;
    switch (route(&s, host, port, .https)) {
        .direct => {},
        .tunnel => |t| {
            // A tunnel always names a usable proxy, and the failure text
            // never repeats its credentials.
            try std.testing.expect(t.host.len > 0);
            const f = answerFailure(.{ .status = 407 }, t, host, port).?;
            if (t.authorization) |value| try std.testing.expect(std.mem.find(u8, f.text(&text_buf), value) == null);
        },
        .refuse => |r| {
            // A refusal names only the variable and a short plain scheme.
            const text = Failure.refusal(r, host, port).text(&text_buf);
            try std.testing.expect(std.mem.startsWith(u8, text, "fx supports only http:// proxies, but https_proxy ") or
                std.mem.eql(u8, text, "https_proxy is not a proxy URL fx can read; use http://host:port"));
            try std.testing.expect(text.len <= 80);
        },
    }
}

test "proxy variables and NO_PROXY lists route fuzzed hosts without leaking credentials" {
    try std.testing.fuzz({}, fuzzEnvironment, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "http://user:p%40ss@proxy.test:3128",
        }) ++ @import("fuzz_corpus").net_proxy_environment.*),
    });
}
