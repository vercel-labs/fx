//! Drives the proxy connector's core (`src/core/shared/net_proxy.zig`) for the
//! TLA+ driver in this folder. It reads one JSON operation per line from the
//! file named by its first argument and writes one JSON result per operation
//! to the file named by its second.
//!
//! The lab plays two connections the way `net_proxy_io.zig`, web_fetch, and
//! the gateway use the core, and knows nothing about the model. A lookup asks
//! the real `route` (web_fetch first asks the real `url_policy.isPublicAddress`
//! about its local answer) and marks the failure log, as a request does before
//! it opens. A CONNECT is the bytes the real `writeConnect` writes, and the
//! proxy's canned answer goes through the real `readConnectAnswer`; anything
//! but `.ok` fails the connection with the real `connectError` and adds the
//! real failure to the real `FailureLog`. A report claims from that log only
//! when the real `isProxyFailureError` says the failure came from the proxy. A
//! failure fx retries claims the same way for its retry notice. The real
//! `Failure.shortText` and `statusWithProxy` put the proxy's name into each
//! status line the retry can show, the longest ones included, with a proxy host
//! of 253 bytes: the notice is "proxy" when every line keeps its cause, its wait
//! part and the whole note within 95 bytes, and "proxy_cut" when one does not.
//! After every operation it reports what each connection holds, what went on
//! the wire, and the log's records and claims.
const std = @import("std");
const net_proxy = @import("net_proxy");
const url_policy = @import("url_policy");

const Op = struct {
    op: []const u8,
    c: ?[]const u8 = null,
    a: ?[]const u8 = null,
    targets: ?struct { a: []const u8, b: []const u8 } = null,
};

const ConnOut = struct {
    target: []const u8,
    phase: []const u8,
    route: []const u8,
    answer: []const u8,
    shown: []const u8,
    got: []const u8,
    notice: []const u8,
    ngot: []const u8,
};
const Wire = struct { c: []const u8, hop: []const u8, kind: []const u8, dest: []const u8 };

const Result = struct {
    conns: struct { a: ConnOut, b: ConnOut },
    wire: []const Wire,
    records: []const []const u8,
    claimed: usize,
    @"error": ?[]const u8 = null,
};

/// The proxy's host: 253 bytes, as long as a host name can be, in labels of at
/// most 63 bytes, so any sentence or uncut host fills a status text and the real
/// parser still accepts it.
const proxy_host = blk: {
    var bytes: [253]u8 = @splat('p');
    bytes[63] = '.';
    bytes[127] = '.';
    bytes[191] = '.';
    break :blk bytes;
};

const proxy_url = blk: {
    const head = "http://user:pass@";
    const tail = ":3128";
    var bytes: [head.len + proxy_host.len + tail.len]u8 = undefined;
    @memcpy(bytes[0..head.len], head);
    @memcpy(bytes[head.len..][0..proxy_host.len], &proxy_host);
    @memcpy(bytes[head.len + proxy_host.len ..], tail);
    break :blk bytes;
};

const Env = struct {
    pub fn getenv(_: Env, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "https_proxy")) return &proxy_url;
        if (std.mem.eql(u8, name, "no_proxy")) return "bypass.example";
        return null;
    }
};

const Conn = struct {
    target: []const u8 = "routed",
    phase: []const u8 = "idle",
    route: []const u8 = "none",
    answer: []const u8 = "none",
    shown: []const u8 = "unread",
    got: []const u8 = "none",
    notice: []const u8 = "unread",
    ngot: []const u8 = "none",
    canned: []const u8 = "",
    since: u64 = 0,
    err: ?anyerror = null,

    fn out(c: Conn) ConnOut {
        return .{
            .target = c.target,
            .phase = c.phase,
            .route = c.route,
            .answer = c.answer,
            .shown = c.shown,
            .got = c.got,
            .notice = c.notice,
            .ngot = c.ngot,
        };
    }
};

const Lab = struct {
    snapshot: net_proxy.Snapshot = undefined,
    log: net_proxy.FailureLog = .{},
    a: Conn = .{},
    b: Conn = .{},
    wire: [16]Wire = undefined,
    wire_len: usize = 0,
    records: [2][]const u8 = undefined,
    records_len: usize = 0,
    claimed: usize = 0,

    fn conn(lab: *Lab, name: []const u8) ?*Conn {
        if (std.mem.eql(u8, name, "a")) return &lab.a;
        if (std.mem.eql(u8, name, "b")) return &lab.b;
        return null;
    }

    fn record(lab: *Lab, w: Wire) void {
        for (lab.wire[0..lab.wire_len]) |have| {
            if (std.mem.eql(u8, have.c, w.c) and std.mem.eql(u8, have.hop, w.hop) and
                std.mem.eql(u8, have.kind, w.kind) and std.mem.eql(u8, have.dest, w.dest)) return;
        }
        lab.wire[lab.wire_len] = w;
        lab.wire_len += 1;
    }
};

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The URL host each target uses.
fn hostOf(target: []const u8) []const u8 {
    if (is(target, "routed")) return "routed.example";
    if (is(target, "bypass")) return "bypass.example";
    if (is(target, "fetch_public")) return "public.example";
    return "private.example";
}

/// web_fetch's local DNS answer for a target, or null when it is not a
/// web_fetch URL.
fn localAnswer(target: []const u8) ?std.Io.net.IpAddress {
    if (is(target, "fetch_public")) return .{ .ip4 = .{ .bytes = .{ 93, 184, 216, 34 }, .port = 443 } };
    if (is(target, "fetch_private")) return .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 5 }, .port = 443 } };
    return null;
}

/// The host a CONNECT for this target names: web_fetch tunnels to the address
/// it admitted, never the name.
fn connectHost(target: []const u8, buf: []u8) ![]const u8 {
    const admitted = localAnswer(target) orelse return hostOf(target);
    const text = try std.mem.print(buf, "{f}", .{admitted.ip4});
    return text[0 .. std.mem.findScalarLast(u8, text, ':') orelse text.len];
}

/// The model's target name for the host a failure names.
fn targetOfHost(host: []const u8) []const u8 {
    if (is(host, "routed.example")) return "routed";
    if (is(host, "bypass.example")) return "bypass";
    if (is(host, "93.184.216.34") or is(host, "public.example")) return "fetch_public";
    return "fetch_private";
}

fn cannedAnswer(a: []const u8) []const u8 {
    if (is(a, "ok")) return "HTTP/1.1 200 Connection established\r\n\r\n";
    if (is(a, "auth")) return "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"p\"\r\n\r\n";
    if (is(a, "refused")) return "HTTP/1.1 503 Service Unavailable\r\n\r\n";
    if (is(a, "garbage")) return "\x16\x03\x01\x00\x05hello";
    if (is(a, "interim")) return "HTTP/1.1 102 Processing\r\n\r\nHTTP/1.1 200 Connection established\r\n\r\n";
    if (is(a, "switching")) return "HTTP/1.1 101 Switching Protocols\r\n\r\nHTTP/1.1 200 OK\r\n\r\n";
    return ""; // silent, or dead: nothing is read
}

/// The longest status lines a retry can show beside a proxy note: the cause,
/// the wait or the retry, then the clock and the attempt, which give way first.
const worst_statuses = [_][]const u8{
    "Offline \u{b7} next try in 59m 59s",
    "Connection lost \u{b7} next try in 59m 59s \u{b7} attempt 65535",
    "Unreadable reply \u{b7} next try in 59m 59s \u{b7} attempt 65535",
    "Gateway error \u{b7} next try in 59m 59s \u{b7} attempt 65535",
    "Rate limited \u{b7} next try in 59m 59s \u{b7} attempt 65535",
    "Offline \u{b7} retrying \u{b7} attempt 65535",
    "Connection lost \u{b7} retrying \u{b7} attempt 65535",
    "Gateway error \u{b7} retrying without Fast \u{b7} attempt 65535",
};

/// The status up to its second separator: the cause and the wait or retry part.
fn firstTwoParts(status: []const u8) []const u8 {
    const separator = " \u{b7} ";
    const first = std.mem.find(u8, status, separator) orelse return status;
    const rest = status[first + separator.len ..];
    const second = std.mem.find(u8, rest, separator) orelse return status;
    return status[0 .. first + separator.len + second];
}

/// What the retry notice for `failure` says, in the model's words: "proxy"
/// when it names the proxy within the note's budget and every status keeps its
/// cause, its wait part and the whole note in 95 bytes; "proxy_cut" when one
/// status loses any of them.
fn noticeOf(failure: *const net_proxy.Failure) []const u8 {
    // A note longer than its budget shows in full, so a short form that does
    // not cut its host cannot hide behind the buffer.
    var note_buf: [1024]u8 = undefined;
    const note = failure.shortText(&note_buf);
    if (note.len > net_proxy.max_notice_bytes) return "proxy_cut";
    var line: [95]u8 = undefined;
    for (worst_statuses) |status| {
        const text = net_proxy.statusWithProxy(&line, status, note);
        if (!std.mem.startsWith(u8, text, firstTwoParts(status))) return "proxy_cut";
        if (!std.mem.endsWith(u8, text, note)) return "proxy_cut";
    }
    return "proxy";
}

fn run(lab: *Lab, op: Op) !void {
    if (is(op.op, "walk")) {
        const targets = op.targets orelse return error.WalkWithoutTargets;
        const snapshot = lab.snapshot;
        lab.* = .{ .snapshot = snapshot };
        lab.a.target = targets.a;
        lab.b.target = targets.b;
        return;
    }
    const name = op.c orelse return error.OpWithoutConnection;
    const c = lab.conn(name) orelse return error.UnknownConnection;
    var host_buf: [64]u8 = undefined;
    if (is(op.op, "lookup")) {
        if (!is(c.phase, "idle")) return error.LookupTwice;
        // A request marks the log before it opens, so it claims only
        // failures from its own time.
        c.since = lab.log.mark();
        if (localAnswer(c.target)) |admitted| {
            if (!url_policy.isPublicAddress(admitted)) {
                c.phase = "failed";
                c.err = error.NonPublicDnsAnswer;
                return;
            }
        }
        switch (net_proxy.route(&lab.snapshot, hostOf(c.target), 443, .https)) {
            .direct => c.route = "direct",
            .tunnel => c.route = "tunnel",
            .refuse => return error.RouteRefused,
        }
        c.phase = "routed";
    } else if (is(op.op, "send_connect")) {
        if (!is(c.route, "tunnel") or !is(c.phase, "routed")) return error.ConnectWithoutTunnel;
        const proxy = net_proxy.route(&lab.snapshot, hostOf(c.target), 443, .https).tunnel;
        const host = try connectHost(c.target, &host_buf);
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try net_proxy.writeConnect(&w, host, 443, proxy.authorization);
        const sent = w.buffered();
        var expect_line: [256]u8 = undefined;
        const line = try std.mem.print(&expect_line, "CONNECT {s}:443 HTTP/1.1\r\n", .{host});
        if (!std.mem.startsWith(u8, sent, line)) return error.UnexpectedConnectLine;
        if (std.mem.find(u8, sent, "\r\nProxy-Authorization: Basic dXNlcjpwYXNz\r\n") == null) return error.NoProxyAuthorizationOnConnect;
        const private = if (std.Io.net.IpAddress.parse(host, 0)) |ip| !url_policy.isPublicAddress(ip) else |_| is(host, "private.example");
        lab.record(.{ .c = name, .hop = "proxy", .kind = "connect", .dest = if (private) "private" else "target" });
        c.phase = "connect_sent";
    } else if (is(op.op, "answer")) {
        if (!is(c.phase, "connect_sent")) return error.AnswerWithoutConnect;
        c.answer = op.a orelse return error.AnswerWithoutValue;
        c.canned = cannedAnswer(c.answer);
        c.phase = "answered";
    } else if (is(op.op, "finish_connect")) {
        if (!is(c.phase, "answered")) return error.FinishWithoutAnswer;
        const proxy = net_proxy.route(&lab.snapshot, hostOf(c.target), 443, .https).tunnel;
        const host = try connectHost(c.target, &host_buf);
        // A proxy that is down never answers: the connection to it fails, as
        // net_proxy_io.connectIp records it.
        var r = std.Io.Reader.fixed(c.canned);
        const failure_or_open: ?net_proxy.Failure = if (is(c.answer, "dead"))
            net_proxy.Failure.init(.unreachable_proxy, proxy.host, proxy.port, host, 443).withDetail("connection refused")
        else
            net_proxy.answerFailure(try net_proxy.readConnectAnswer(&r), proxy, host, 443);
        if (failure_or_open) |failure| {
            c.phase = "failed";
            c.err = net_proxy.connectError(&failure);
            lab.log.add(failure);
            lab.records[lab.records_len] = name;
            lab.records_len += 1;
        } else {
            c.phase = "open";
        }
    } else if (is(op.op, "send")) {
        const dest = if (is(c.target, "fetch_private")) "private" else "target";
        if (is(c.phase, "routed") and is(c.route, "direct")) {
            lab.record(.{ .c = name, .hop = "direct", .kind = "tls", .dest = dest });
        } else if (is(c.phase, "open")) {
            lab.record(.{ .c = name, .hop = "proxy", .kind = "tls", .dest = dest });
        } else return error.SendWithoutConnection;
        c.phase = "sent";
    } else if (is(op.op, "notify")) {
        if (!is(c.phase, "failed") or !is(c.notice, "unread")) return error.NotifyWithoutFailure;
        const err = c.err orelse return error.FailureWithoutError;
        c.notice = "generic";
        if (net_proxy.isProxyFailureError(err)) {
            const host = try connectHost(c.target, &host_buf);
            if (lab.log.claim(host, 443, c.since)) |failure| {
                c.notice = noticeOf(&failure);
                c.ngot = targetOfHost(failure.target());
                lab.claimed += 1;
            }
        }
    } else if (is(op.op, "report")) {
        if (!is(c.phase, "failed") or !is(c.shown, "unread")) return error.ReportWithoutFailure;
        const err = c.err orelse return error.FailureWithoutError;
        c.shown = "none";
        if (net_proxy.isProxyFailureError(err)) {
            const host = try connectHost(c.target, &host_buf);
            if (lab.log.claim(host, 443, c.since)) |failure| {
                c.shown = "proxy";
                c.got = targetOfHost(failure.target());
                lab.claimed += 1;
            }
        }
    } else return error.UnknownOperation;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    // driver.ts always passes the operations file and the results file.
    if (args.len != 3) return error.ExpectedOpsAndResultsPaths;
    const input = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 30));
    var file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer file.close(io);
    var buffer: [1 << 16]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const out = &file_writer.interface;

    var lab: Lab = .{};
    net_proxy.parse(&lab.snapshot, Env{});
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        _ = scratch.reset(.retain_capacity);
        const op = try std.json.parseFromSliceLeaky(Op, scratch.allocator(), line, .{ .ignore_unknown_fields = true });
        const failure: ?[]const u8 = if (run(&lab, op)) |_| null else |err| @errorName(err);
        const result: Result = .{
            .conns = .{ .a = lab.a.out(), .b = lab.b.out() },
            .wire = lab.wire[0..lab.wire_len],
            .records = lab.records[0..lab.records_len],
            .claimed = lab.claimed,
            .@"error" = failure,
        };
        try std.json.Stringify.value(result, .{}, out);
        try out.writeByte('\n');
    }
    try out.flush();
}
