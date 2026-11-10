//! Installs the proxy connector in the process Io (io_mod.setIo), the one
//! place every fx connection by host name passes through: std.http.Client and
//! HostName.connect call the Io's netLookup and then netConnectIp.
//!
//! For a host `net_proxy.route` sends through a proxy, netLookup does no DNS:
//! it hands back a tunnel handle, an address in 100::/64 (RFC 6666, discard
//! only) whose low bits index a table of tunnel targets. netConnectIp, given
//! that handle, connects to the proxy, sends CONNECT and returns the socket
//! only when the proxy answers 2xx; std then runs TLS to the real host over
//! it, with that host's name for SNI and the certificate check. Every other
//! address goes to the wrapped Io unchanged. std's own proxy fields stay
//! null, so its plain-text fallback never runs.
//!
//! A connection that fails at the proxy logs its failure for its own target.
//! The request that opened it claims that failure on its own thread
//! (`beginOpen`, `noteOpenFailure`) and shows it (`takeRequestFailure`); no
//! other request can (`tests/tla/net_proxy/NetProxy.tla`
//! DetailBelongsToFailingConnect).
const std = @import("std");
const builtin = @import("builtin");
const net_proxy = @import("net_proxy.zig");
const io_mod = @import("io.zig");
const debug_trace = @import("debug_trace.zig");
const types = @import("types.zig");

const HostName = std.Io.net.HostName;
const IpAddress = std.Io.net.IpAddress;

var wrapped_vtable: std.Io.VTable = undefined;
var original_vtable: ?*const std.Io.VTable = null;
var wrap_state: std.atomic.Value(u8) = .init(0);

/// The process Io with the proxy connector in front of name lookups and
/// connects. Wraps one Io implementation; another one is returned unchanged.
pub fn wrap(original: std.Io) std.Io {
    while (true) switch (wrap_state.load(.acquire)) {
        2 => break,
        0 => if (wrap_state.cmpxchgWeak(0, 1, .acq_rel, .acquire) == null) {
            wrapped_vtable = original.vtable.*;
            wrapped_vtable.netLookup = lookup;
            wrapped_vtable.netConnectIp = connectIp;
            original_vtable = original.vtable;
            wrap_state.store(2, .release);
            break;
        },
        else => std.atomic.spinLoopHint(),
    };
    if (original.vtable == &wrapped_vtable) return original;
    if (original.vtable != original_vtable.?) return original;
    return .{ .userdata = original.userdata, .vtable = &wrapped_vtable };
}

/// `io` without the connector, for a lookup that must reach DNS itself, as
/// web_fetch's admission check does.
pub fn direct(io: std.Io) std.Io {
    const inner_vtable = original_vtable orelse return io;
    return .{ .userdata = io.userdata, .vtable = inner_vtable };
}

fn inner(userdata: ?*anyopaque) std.Io {
    return .{ .userdata = userdata, .vtable = original_vtable.? };
}

// The snapshot is read once, at the first by-name connect, never at startup.
var snapshot: net_proxy.Snapshot = undefined;
var snapshot_ready: std.atomic.Value(bool) = .init(false);
var snapshot_lock: std.Io.Mutex = .init;

const ProcessEnv = struct {
    pub fn getenv(_: ProcessEnv, name: []const u8) ?[]const u8 {
        return io_mod.getenv(name);
    }
};

/// Reads the snapshot from `env`, and says in the trace what it dropped of the
/// person's own settings: NO_PROXY entries that are not an entry or are past
/// the limit, and an uppercase HTTP_PROXY a set REQUEST_METHOD makes it ignore.
fn parseSnapshot(env: anytype) void {
    net_proxy.parse(&snapshot, env);
    if (snapshot.no_proxy_invalid != 0 or snapshot.no_proxy_over_limit != 0) {
        debug_trace.logf("net_proxy", "no_proxy dropped invalid={d} over_limit={d}", .{ snapshot.no_proxy_invalid, snapshot.no_proxy_over_limit });
    }
    if (snapshot.http_proxy_ignored) {
        debug_trace.logf("net_proxy", "HTTP_PROXY ignored because REQUEST_METHOD is set", .{});
    }
}

fn current(io: std.Io) *const net_proxy.Snapshot {
    if (snapshot_ready.load(.acquire)) return &snapshot;
    snapshot_lock.lockUncancelable(io);
    defer snapshot_lock.unlock(io);
    if (!snapshot_ready.load(.acquire)) {
        parseSnapshot(ProcessEnv{});
        snapshot_ready.store(true, .release);
    }
    return &snapshot;
}

/// The route a connection to `host:port` takes, for a caller that dials on
/// its own, such as web_fetch.
pub fn routeFor(host: []const u8, port: u16, scheme: net_proxy.Scheme) net_proxy.Decision {
    return net_proxy.route(current(direct(io_mod.getIo())), host, port, scheme);
}

/// A connect only knows its port. Port 80 carries plain HTTP; fx speaks TLS
/// on every other port it dials by name.
fn schemeForPort(port: u16) net_proxy.Scheme {
    return if (port == 80) .http else .https;
}

// Tunnel targets: append-only, so a handle stays valid for the process.
const max_tunnels = 4096;
const Target = struct {
    hash: u64,
    host: [HostName.max_len]u8,
    host_len: u8,
    port: u16,

    fn name(t: *const Target) []const u8 {
        return t.host[0..t.host_len];
    }
};
var targets: [max_tunnels]Target = undefined;
var targets_len: std.atomic.Value(usize) = .init(0);
var targets_lock: std.Io.Mutex = .init;

fn targetHash(host: []const u8, port: u16) u64 {
    var hasher = std.hash.Wyhash.init(port);
    for (host) |byte| hasher.update(&.{std.ascii.toLower(byte)});
    return hasher.final();
}

fn intern(io: std.Io, host: []const u8, port: u16) ?u16 {
    const hash = targetHash(host, port);
    targets_lock.lockUncancelable(io);
    defer targets_lock.unlock(io);
    const len = targets_len.load(.acquire);
    for (targets[0..len], 0..) |*t, i| {
        if (t.hash == hash and t.port == port and std.ascii.eqlIgnoreCase(t.name(), host)) return @intCast(i);
    }
    if (len == max_tunnels or host.len > HostName.max_len) return null;
    targets[len] = .{ .hash = hash, .host = undefined, .host_len = @intCast(host.len), .port = port };
    @memcpy(targets[len].host[0..host.len], host);
    targets_len.store(len + 1, .release);
    return @intCast(len);
}

const handle_prefix = [8]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0 };

fn handle(index: u16, port: u16) IpAddress {
    var bytes: [16]u8 = @splat(0);
    bytes[0..8].* = handle_prefix;
    std.mem.writeInt(u16, bytes[14..16], index, .big);
    return .{ .ip6 = .{ .bytes = bytes, .port = port } };
}

fn tunnelOf(address: *const IpAddress) ?*const Target {
    const ip6 = switch (address.*) {
        .ip6 => |a| a,
        .ip4 => return null,
    };
    if (!std.mem.eql(u8, ip6.bytes[0..8], &handle_prefix)) return null;
    const index = std.mem.readInt(u16, ip6.bytes[14..16], .big);
    if (index >= targets_len.load(.acquire)) return null;
    return &targets[index];
}

// Proxy failures of recent connections, for the requests that opened them.
var failure_log: net_proxy.FailureLog = .{};
var failure_lock: std.Io.Mutex = .init;

/// The proxy failure a request on this thread claimed, until it is shown.
threadlocal var request_failure: ?net_proxy.Failure = null;

fn recordFailure(io: std.Io, failure: net_proxy.Failure) void {
    var buf: [512]u8 = undefined;
    debug_trace.logf("net_proxy", "result=failed {s}", .{failure.text(&buf)});
    failure_lock.lockUncancelable(io);
    defer failure_lock.unlock(io);
    failure_log.add(failure);
}

/// Starts a request's open: clears this thread's held failure and returns
/// the mark `noteOpenFailure` claims from.
pub fn beginOpen() u64 {
    clearRequestFailure();
    const io = direct(io_mod.getIo());
    failure_lock.lockUncancelable(io);
    defer failure_lock.unlock(io);
    return failure_log.mark();
}

/// After a request's open to `uri` failed with `err`, holds on this thread
/// the oldest unclaimed proxy failure for that target since `since`.
pub fn noteOpenFailure(uri: std.Uri, since: u64, err: anyerror) void {
    if (!net_proxy.isProxyFailureError(err)) return;
    var host_buf: [HostName.max_len]u8 = undefined;
    const host = HostName.fromUri(uri, &host_buf) catch return;
    const port = uri.port orelse if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) @as(u16, 80) else 443;
    const io = direct(io_mod.getIo());
    failure_lock.lockUncancelable(io);
    defer failure_lock.unlock(io);
    request_failure = failure_log.claim(host.bytes, port, since);
}

/// Holds a failure that a connection made on this thread for itself, as
/// web_fetch's own tunnel dial does.
pub fn holdForRequest(failure: net_proxy.Failure) void {
    var buf: [512]u8 = undefined;
    debug_trace.logf("net_proxy", "result=failed {s}", .{failure.text(&buf)});
    request_failure = failure;
}

/// Drops a failure this thread holds, when a request starts or succeeds.
pub fn clearRequestFailure() void {
    request_failure = null;
}

/// The text of the proxy failure this thread's request holds, when `err` is
/// one a proxy failure returns. Clears what it read either way.
pub fn takeRequestFailure(err: anyerror, buf: []u8) ?[]const u8 {
    if (!net_proxy.isProxyFailureError(err)) {
        request_failure = null;
        return null;
    }
    return takeHeldFailure(buf);
}

/// The short form of the proxy failure this thread's request holds, for the
/// retry notice (`net_proxy.Failure.shortText`, at most `notice_bytes`), when
/// `err` is one a proxy failure returns. The full sentence is for the final
/// error and `fx models`, which take it with `takeRequestFailure` and
/// `takeHeldFailure`. Clears what it read either way.
pub fn takeRequestFailureNotice(err: anyerror, buf: []u8) ?[]const u8 {
    if (!net_proxy.isProxyFailureError(err)) {
        request_failure = null;
        return null;
    }
    const failure = request_failure orelse return null;
    request_failure = null;
    return failure.shortText(buf);
}

/// The room `takeRequestFailureNotice` needs in its buffer.
pub const notice_bytes = net_proxy.max_notice_bytes;

/// ` proxy="<sentence>"` for the end of a trace line about a request that
/// failed with `err`, or "" when `err` is not one a proxy failure returns or
/// this thread holds none: the permission reviewers' transport errors name the
/// proxy in their trace line and nowhere else, so their outcome and the screen
/// stay as they were. Clears what it read either way.
pub fn takeTraceNote(err: anyerror, buf: *[trace_note_bytes]u8) []const u8 {
    if (!net_proxy.isProxyFailureError(err)) {
        request_failure = null;
        return "";
    }
    const failure = request_failure orelse return "";
    request_failure = null;
    return failure.traceNote(buf);
}

/// The room `takeTraceNote` needs in its buffer.
pub const trace_note_bytes = net_proxy.Failure.trace_note_bytes;

/// The text of the proxy failure this thread holds, for a caller that knows
/// its own failure was a transport failure but not which error it was, as
/// `fx models` does. Clears what it read.
pub fn takeHeldFailure(buf: []u8) ?[]const u8 {
    const failure = request_failure orelse return null;
    request_failure = null;
    return failure.text(buf);
}

/// The failure of a connection fx could not open to the proxy itself, for
/// `target_host:target_port`. `err` is what the connect returned; the failure
/// says it in plain words, as fx says every error, and keeps the raw name for
/// the trace.
pub fn unreachableProxyFailure(proxy: net_proxy.Proxy, target_host: []const u8, target_port: u16, err: anyerror) net_proxy.Failure {
    var words: [64]u8 = undefined;
    return net_proxy.Failure.init(.unreachable_proxy, proxy.host, proxy.port, target_host, target_port)
        .withDetail(types.plainErrorText(@errorName(err), &words));
}

fn lookup(
    userdata: ?*anyopaque,
    host: HostName,
    resolved: *std.Io.Queue(HostName.LookupResult),
    options: HostName.LookupOptions,
) HostName.LookupError!void {
    const io = inner(userdata);
    const snap = current(io);
    if (!snap.routes()) return original_vtable.?.netLookup(userdata, host, resolved, options);
    switch (net_proxy.route(snap, host.bytes, options.port, schemeForPort(options.port))) {
        .direct => return original_vtable.?.netLookup(userdata, host, resolved, options),
        // A refused route still gets a handle: its connect names the proxy
        // variable and ends the request, where a lookup error would read as
        // a network that is down.
        .tunnel, .refuse => {
            defer resolved.close(io);
            const index = intern(io, host.bytes, options.port) orelse {
                debug_trace.logf("net_proxy", "route=tunnel target={s}:{d} result=table_full", .{ host.bytes, options.port });
                return error.NameServerFailure;
            };
            resolved.putAll(io, &.{
                .{ .address = handle(index, options.port) },
                .{ .canonical_name = host },
            }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                error.Closed => return error.NameServerFailure,
            };
        },
    }
}

fn connectIp(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.ConnectOptions,
) IpAddress.ConnectError!std.Io.net.Socket {
    const target = tunnelOf(address) orelse return original_vtable.?.netConnectIp(userdata, address, options);
    const io = inner(userdata);
    const proxy = switch (net_proxy.route(current(io), target.name(), target.port, schemeForPort(target.port))) {
        .tunnel => |p| p,
        .refuse => |refusal| {
            const failure = net_proxy.Failure.refusal(refusal, target.name(), target.port);
            recordFailure(io, failure);
            return net_proxy.connectError(&failure);
        },
        // The snapshot never changes, so a handle's route stays a tunnel.
        .direct => return error.ConnectionRefused,
    };
    const stream = connectProxy(io, proxy, options) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        recordFailure(io, unreachableProxyFailure(proxy, target.name(), target.port, err));
        return net_proxy.proxyFailureError(err);
    };
    errdefer stream.close(io);

    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    net_proxy.writeConnect(&writer.interface, target.name(), target.port, proxy.authorization) catch return failClosed(io, proxy, target);
    writer.interface.flush() catch return failClosed(io, proxy, target);

    var read_buf: [512]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    const answer = net_proxy.readConnectAnswer(&reader.interface) catch {
        if (reader.err) |err| if (err == error.Canceled) {
            recordFailure(io, net_proxy.Failure.init(.no_answer, proxy.host, proxy.port, target.name(), target.port));
            return error.Canceled;
        };
        return failClosed(io, proxy, target);
    };
    if (net_proxy.answerFailure(answer, proxy, target.name(), target.port)) |failure| {
        recordFailure(io, failure);
        return net_proxy.connectError(&failure);
    }
    // Bytes past the answer head would belong to the tunnel, which the proxy
    // must leave silent until fx speaks.
    if (reader.interface.bufferedLen() != 0) {
        const failure = net_proxy.Failure.init(.malformed, proxy.host, proxy.port, target.name(), target.port);
        recordFailure(io, failure);
        return net_proxy.connectError(&failure);
    }
    debug_trace.logf("net_proxy", "target={s}:{d} proxy={s}:{d} result=open", .{ target.name(), target.port, proxy.host, proxy.port });
    return stream.socket;
}

/// The proxy dropped the connection before it answered.
fn failClosed(io: std.Io, proxy: net_proxy.Proxy, target: *const Target) IpAddress.ConnectError {
    const failure = net_proxy.Failure.init(.no_answer, proxy.host, proxy.port, target.name(), target.port);
    recordFailure(io, failure);
    return net_proxy.connectError(&failure);
}

/// Connects to the proxy itself on the wrapped Io, so its lookup and connect
/// never come back through the connector.
fn connectProxy(io: std.Io, proxy: net_proxy.Proxy, options: IpAddress.ConnectOptions) !std.Io.net.Stream {
    if (IpAddress.parse(proxy.host, proxy.port)) |address| {
        return address.connect(io, options);
    } else |_| {}
    // The proxy's host was checked when the snapshot read it, and HostName.init
    // would refuse the underscores that service names such as squid_proxy have.
    const host: HostName = .{ .bytes = proxy.host };
    return host.connect(io, proxy.port, options);
}

/// Replaces the snapshot with one read from `env`, for tests. Pair it with
/// `resetSnapshotForTest`, so later tests read the process environment again.
pub fn useSnapshotForTest(env: anytype) void {
    if (!builtin.is_test) @compileError("useSnapshotForTest is for tests");
    parseSnapshot(env);
    snapshot_ready.store(true, .release);
}

/// Empties the tunnel table, for a test that fills it.
fn resetTunnelsForTest() void {
    if (!builtin.is_test) @compileError("resetTunnelsForTest is for tests");
    targets_len.store(0, .release);
}

pub fn resetSnapshotForTest() void {
    if (!builtin.is_test) @compileError("resetSnapshotForTest is for tests");
    snapshot_ready.store(false, .release);
}

const TestEnv = struct {
    pairs: []const [2][]const u8,
    pub fn getenv(e: TestEnv, name: []const u8) ?[]const u8 {
        for (e.pairs) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
        return null;
    }
};

/// A loopback listener that answers each CONNECT with `answer` and then, on
/// a 200, echoes what the client sends.
const FakeProxy = struct {
    server: std.Io.net.Server,
    answer: []const u8,
    /// Accepts and reads the CONNECT, but never answers.
    silent: bool = false,
    head: [512]u8 = undefined,
    head_len: usize = 0,
    /// Set once the whole CONNECT head is in `head`.
    head_done: std.atomic.Value(bool) = .init(false),

    fn init(io: std.Io, answer: []const u8) !FakeProxy {
        const address: IpAddress = .{ .ip4 = .loopback(0) };
        return .{ .server = try address.listen(io, .{ .reuse_address = true }), .answer = answer };
    }

    fn port(p: *const FakeProxy) u16 {
        return p.server.socket.address.getPort();
    }

    fn serveOne(p: *FakeProxy, io: std.Io) void {
        const stream = p.server.accept(io) catch return;
        defer stream.close(io);
        var read_buf: [512]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        while (p.head_len < p.head.len) {
            p.head[p.head_len] = reader.interface.takeByte() catch return;
            p.head_len += 1;
            if (p.head_len >= 4 and std.mem.eql(u8, p.head[p.head_len - 4 .. p.head_len], "\r\n\r\n")) break;
        }
        p.head_done.store(true, .release);
        if (p.silent) {
            // Holds the connection until the client gives up.
            _ = reader.interface.takeByte() catch {};
            return;
        }
        var write_buf: [512]u8 = undefined;
        var writer = stream.writer(io, &write_buf);
        writer.interface.writeAll(p.answer) catch return;
        writer.interface.flush() catch return;
        if (!std.mem.startsWith(u8, p.answer, "HTTP/1.1 200")) return;
        // The tests send four bytes into the tunnel.
        const echo = reader.interface.take(4) catch return;
        writer.interface.writeAll(echo) catch return;
        writer.interface.flush() catch return;
    }

    fn deinit(p: *FakeProxy, io: std.Io) void {
        p.server.deinit(io);
    }
};

fn testConnect(io: std.Io, host: []const u8, port: u16) (HostName.ConnectError || HostName.ValidateError)!std.Io.net.Stream {
    return (try HostName.init(host)).connect(io, port, .{ .mode = .stream });
}

test "a proxy fx cannot connect to is named with the cause in plain words, never a raw error name" {
    const proxy: net_proxy.Proxy = .{ .host = "127.0.0.1", .port = 3128, .authorization = null, .variable = "HTTPS_PROXY" };
    const cases = [_]struct { anyerror, []const u8 }{
        .{ error.ConnectionRefused, "could not connect to proxy 127.0.0.1:3128 (connection refused)" },
        .{ error.AccessDenied, "could not connect to proxy 127.0.0.1:3128 (permission denied)" },
        .{ error.UnknownHostName, "could not connect to proxy 127.0.0.1:3128 (cannot resolve host)" },
        .{ error.NameServerFailure, "could not connect to proxy 127.0.0.1:3128 (DNS lookup failed)" },
        .{ error.HostUnreachable, "could not connect to proxy 127.0.0.1:3128 (host unreachable)" },
        // A name fx has no phrase for is split into words.
        .{ error.SystemResources, "could not connect to proxy 127.0.0.1:3128 (system resources)" },
    };
    var buf: [256]u8 = undefined;
    for (cases) |case| {
        const failure = unreachableProxyFailure(proxy, "x.ai", 443, case[0]);
        try std.testing.expectEqualStrings(case[1], failure.text(&buf));
    }
}

test "a version lookup that failed at the proxy shows its sentence once, and one that did not shows nothing" {
    const proxy: net_proxy.Proxy = .{ .host = "127.0.0.1", .port = 3128, .authorization = null, .variable = "HTTPS_PROXY" };
    const sentence = "could not connect to proxy 127.0.0.1:3128 (connection refused)";
    var buf: [512]u8 = undefined;
    defer clearRequestFailure();

    holdForRequest(unreachableProxyFailure(proxy, "x.ai", 443, error.ConnectionRefused));
    const shown = takeRequestFailure(error.ProviderVersionUnavailable, &buf);
    try std.testing.expect(shown != null);
    try std.testing.expectEqualStrings(sentence, shown.?);
    // Reading clears it: the next lookup that fails for another reason has none.
    try std.testing.expect(takeRequestFailure(error.ProviderVersionUnavailable, &buf) == null);

    // An error a proxy failure never returns clears what is held, and shows nothing.
    holdForRequest(unreachableProxyFailure(proxy, "x.ai", 443, error.ConnectionRefused));
    try std.testing.expect(takeRequestFailure(error.Cancelled, &buf) == null);
    try std.testing.expect(takeRequestFailure(error.ProviderVersionUnavailable, &buf) == null);
}

test "a trace note carries the held sentence once, and an error that is not a proxy's carries none" {
    const proxy: net_proxy.Proxy = .{ .host = "127.0.0.1", .port = 3128, .authorization = null, .variable = "HTTPS_PROXY" };
    var buf: [trace_note_bytes]u8 = undefined;
    defer clearRequestFailure();

    holdForRequest(unreachableProxyFailure(proxy, "x.ai", 443, error.ConnectionRefused));
    try std.testing.expectEqualStrings(
        " proxy=\"could not connect to proxy 127.0.0.1:3128 (connection refused)\"",
        takeTraceNote(error.ConnectionResetByPeer, &buf),
    );
    // Reading clears it, and a request that held none has no note.
    try std.testing.expectEqualStrings("", takeTraceNote(error.ConnectionResetByPeer, &buf));
    // An error a proxy failure never returns clears what is held, and has none.
    holdForRequest(unreachableProxyFailure(proxy, "x.ai", 443, error.ConnectionRefused));
    try std.testing.expectEqualStrings("", takeTraceNote(error.Cancelled, &buf));
    try std.testing.expectEqualStrings("", takeTraceNote(error.ConnectionResetByPeer, &buf));
}

test "threads that each fail at the proxy claim only their own sentence, thousands of times" {
    const threads = 8;
    const rounds = 2_000;
    // The threads record in step, so at most two rounds of failures are in the
    // log at once, under its capacity: a failure is lost only when more than
    // `FailureLog.capacity` others come between its record and its claim.
    const Round = struct {
        arrived: std.atomic.Value(usize) = .init(0),

        fn wait(r: *@This(), round: usize) void {
            _ = r.arrived.fetchAdd(1, .acq_rel);
            while (r.arrived.load(.acquire) < (round + 1) * threads) std.Thread.yield() catch {};
        }
    };
    const Worker = struct {
        index: usize,
        steps: *Round,
        claimed: usize = 0,
        wrong: usize = 0,

        fn run(w: *@This()) void {
            var host_buf: [32]u8 = undefined;
            var uri_buf: [64]u8 = undefined;
            var text_buf: [512]u8 = undefined;
            const host = std.mem.print(&host_buf, "t{d}.stress.test", .{w.index}) catch return;
            const uri_text = std.mem.print(&uri_buf, "https://{s}/", .{host}) catch return;
            const uri = std.Uri.parse(uri_text) catch return;
            for (0..rounds) |round| {
                const since = beginOpen();
                // Its own failure, logged beside every other thread's.
                var failure = net_proxy.Failure.init(.refused, "p.test", 3128, host, 443);
                failure.status = if (round % 2 == 0) 407 else 504;
                recordFailure(io_mod.getIo(), failure);
                w.steps.wait(round);
                noteOpenFailure(uri, since, error.AccessDenied);
                const shown = takeRequestFailure(error.AccessDenied, &text_buf) orelse {
                    w.wrong += 1;
                    continue;
                };
                // The sentence names this thread's target and this round's answer, once.
                var want_buf: [128]u8 = undefined;
                const want = std.mem.print(&want_buf, "refused CONNECT to {s}:443: {d}", .{ host, failure.status }) catch return;
                if (std.mem.find(u8, shown, want) != null) w.claimed += 1 else w.wrong += 1;
                if (takeRequestFailure(error.AccessDenied, &text_buf) != null) w.wrong += 1;
            }
        }
    };
    var steps: Round = .{};
    var workers: [threads]Worker = undefined;
    var spawned: [threads]std.Thread = undefined;
    for (&workers, 0..) |*w, i| w.* = .{ .index = i, .steps = &steps };
    for (&spawned, &workers) |*thread, *w| thread.* = try std.Thread.spawn(.{}, Worker.run, .{w});
    for (spawned) |thread| thread.join();
    for (workers) |w| {
        try std.testing.expectEqual(@as(usize, 0), w.wrong);
        try std.testing.expectEqual(@as(usize, rounds), w.claimed);
    }
}

test "a routed host is reached only through CONNECT, and the tunnel carries the bytes" {
    const base = std.testing.io;
    const io = io_mod.getIo();
    var proxy = try FakeProxy.init(base, "HTTP/1.1 200 Connection established\r\n\r\n");
    defer proxy.deinit(base);
    var url_buf: [64]u8 = undefined;
    const url = try std.mem.print(&url_buf, "http://user:p%40ss@127.0.0.1:{d}", .{proxy.port()});
    useSnapshotForTest(TestEnv{ .pairs = &.{.{ "HTTPS_PROXY", url }} });
    defer resetSnapshotForTest();
    var server = try io.concurrent(FakeProxy.serveOne, .{ &proxy, base });

    const stream = try testConnect(io, "routed.invalid", 8443);
    defer stream.close(io);
    var write_buf: [16]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    try writer.interface.writeAll("ping");
    try writer.interface.flush();
    var read_buf: [16]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    try std.testing.expectEqualStrings("ping", try reader.interface.take(4));
    server.await(base);
    try std.testing.expectEqualStrings(
        "CONNECT routed.invalid:8443 HTTP/1.1\r\nHost: routed.invalid:8443\r\nProxy-Authorization: Basic dXNlcjpwQHNz\r\n\r\n",
        proxy.head[0..proxy.head_len],
    );
}

test "a refused CONNECT fails closed and only the request that opened it can show why" {
    const base = std.testing.io;
    const io = io_mod.getIo();
    var proxy = try FakeProxy.init(base, "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n");
    defer proxy.deinit(base);
    var url_buf: [64]u8 = undefined;
    const url = try std.mem.print(&url_buf, "http://127.0.0.1:{d}", .{proxy.port()});
    useSnapshotForTest(TestEnv{ .pairs = &.{.{ "HTTPS_PROXY", url }} });
    defer resetSnapshotForTest();
    var server = try io.concurrent(FakeProxy.serveOne, .{ &proxy, base });

    const since = beginOpen();
    try std.testing.expectError(error.AccessDenied, testConnect(io, "refused.invalid", 443));
    server.await(base);
    var buf: [256]u8 = undefined;
    // Another target claims nothing; the request's own target claims it once.
    noteOpenFailure(try std.Uri.parse("https://other.invalid/"), since, error.AccessDenied);
    try std.testing.expect(takeRequestFailure(error.AccessDenied, &buf) == null);
    noteOpenFailure(try std.Uri.parse("https://refused.invalid/v1"), since, error.AccessDenied);
    var expected_buf: [128]u8 = undefined;
    const expected = try std.mem.print(&expected_buf, "proxy 127.0.0.1:{d} refused CONNECT to refused.invalid:443: 407 Proxy Authentication Required", .{proxy.port()});
    try std.testing.expectEqualStrings(expected, takeRequestFailure(error.AccessDenied, &buf).?);
    try std.testing.expect(takeRequestFailure(error.AccessDenied, &buf) == null);
    noteOpenFailure(try std.Uri.parse("https://refused.invalid/v1"), since, error.AccessDenied);
    try std.testing.expect(takeRequestFailure(error.AccessDenied, &buf) == null);
}

test "two concurrent requests, one through a failing proxy: only that one shows the proxy text" {
    const base = std.testing.io;
    const io = io_mod.getIo();
    var proxy = try FakeProxy.init(base, "HTTP/1.1 407 Proxy Authentication Required\r\n\r\n");
    defer proxy.deinit(base);
    // A closed loopback port, which NO_PROXY sends direct.
    var closed = try FakeProxy.init(base, "");
    const closed_port = closed.port();
    closed.deinit(base);
    var url_buf: [64]u8 = undefined;
    const url = try std.mem.print(&url_buf, "http://127.0.0.1:{d}", .{proxy.port()});
    useSnapshotForTest(TestEnv{ .pairs = &.{ .{ "HTTPS_PROXY", url }, .{ net_proxy.loopback_test_variable, "1" }, .{ "NO_PROXY", "localhost" } } });
    defer resetSnapshotForTest();
    var server = try io.concurrent(FakeProxy.serveOne, .{ &proxy, base });

    const Request = struct {
        uri: []const u8,
        host: []const u8,
        port: u16,
        start: *std.Io.Event,
        /// Waited on before claiming, and set after the connect fails, so
        /// the direct request claims after the proxied failure is logged:
        /// the order where a shared or misfiled failure would leak.
        claim_after: ?*std.Io.Event = null,
        failed: *std.Io.Event,
        shown: ?[]const u8 = null,
        err: ?anyerror = null,
        buf: [256]u8 = undefined,

        fn run(r: *@This(), request_io: std.Io) void {
            r.start.waitUncancelable(request_io);
            const since = beginOpen();
            const result = testConnect(request_io, r.host, r.port);
            r.failed.set(request_io);
            if (result) |stream| {
                stream.close(request_io);
                return;
            } else |err| {
                r.err = err;
                if (r.claim_after) |event| event.waitUncancelable(request_io);
                noteOpenFailure(std.Uri.parse(r.uri) catch return, since, err);
                r.shown = takeRequestFailure(err, &r.buf);
            }
        }
    };
    var start: std.Io.Event = .unset;
    var proxied_failed: std.Io.Event = .unset;
    var direct_failed: std.Io.Event = .unset;
    var direct_uri_buf: [64]u8 = undefined;
    var proxied: Request = .{ .uri = "https://proxied.invalid/", .host = "proxied.invalid", .port = 443, .start = &start, .failed = &proxied_failed };
    var direct_request: Request = .{
        .uri = try std.mem.print(&direct_uri_buf, "https://localhost:{d}/", .{closed_port}),
        .host = "localhost",
        .port = closed_port,
        .start = &start,
        .claim_after = &proxied_failed,
        .failed = &direct_failed,
    };
    var a = try io.concurrent(Request.run, .{ &proxied, io });
    var b = try io.concurrent(Request.run, .{ &direct_request, io });
    start.set(base);
    a.await(io);
    b.await(io);
    server.await(base);
    try std.testing.expectEqual(@as(?anyerror, error.AccessDenied), proxied.err);
    try std.testing.expect(std.mem.find(u8, proxied.shown.?, "refused CONNECT to proxied.invalid:443: 407") != null);
    // A connection refused is an error a proxy failure can return too, so
    // the direct request does look; it finds no failure of its own.
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionRefused), direct_request.err);
    try std.testing.expect(direct_request.shown == null);
}

test "a proxy that never answers is ended at the caller's deadline and leaves its failure" {
    const base = std.testing.io;
    const io = io_mod.getIo();
    var proxy = try FakeProxy.init(base, "");
    proxy.silent = true;
    defer proxy.deinit(base);
    var url_buf: [64]u8 = undefined;
    const url = try std.mem.print(&url_buf, "http://127.0.0.1:{d}", .{proxy.port()});
    useSnapshotForTest(TestEnv{ .pairs = &.{.{ "HTTPS_PROXY", url }} });
    defer resetSnapshotForTest();
    var server = try io.concurrent(FakeProxy.serveOne, .{ &proxy, base });
    defer server.cancel(base);

    // The handle's connect calls the connector directly. Through
    // HostName.connect, std may run the attempt inline on this thread when
    // no pool thread is free, and then reports the cancel as UnknownHostName.
    var lookup_buf: [4]HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(HostName.LookupResult) = .init(&lookup_buf);
    try HostName.lookup(try HostName.init("silent.invalid"), io, &lookup_queue, .{ .port = 443 });
    const tunnel = switch (try lookup_queue.getOne(io)) {
        .address => |address| address,
        .canonical_name => return error.TestExpectedAddress,
    };
    const since = beginOpen();
    var connect = try io.concurrent(IpAddress.connect, .{ &tunnel, io, .{ .mode = .stream } });
    // The deadline, without waiting for one: once the proxy holds the
    // CONNECT, the caller cancels, as a request's setup deadline does.
    // A connect that fails before it sends CONNECT must fail the test, not hang it.
    var waited_ms: u32 = 0;
    while (!proxy.head_done.load(.acquire)) : (waited_ms += 1) {
        if (waited_ms >= 5_000) return error.TestProxyNeverRead;
        try base.sleep(.fromMilliseconds(1), .awake);
    }
    if (connect.cancel(io)) |stream| {
        stream.close(io);
        return error.TestExpectedCancel;
    } else |err| try std.testing.expectEqual(error.Canceled, err);
    var buf: [256]u8 = undefined;
    noteOpenFailure(try std.Uri.parse("https://silent.invalid/"), since, error.ConnectionSetupTimedOut);
    try std.testing.expect(std.mem.endsWith(u8, takeRequestFailure(error.ConnectionSetupTimedOut, &buf).?, "did not answer CONNECT to silent.invalid:443"));
}

test "a proxy that cannot be reached, answers garbage, or sends bytes after its answer fails the connection" {
    const base = std.testing.io;
    const io = io_mod.getIo();
    var buf: [256]u8 = undefined;
    defer resetSnapshotForTest();

    var gone = try FakeProxy.init(base, "");
    const gone_port = gone.port();
    gone.deinit(base);
    var url_buf: [64]u8 = undefined;
    useSnapshotForTest(TestEnv{ .pairs = &.{.{ "HTTPS_PROXY", try std.mem.print(&url_buf, "http://127.0.0.1:{d}", .{gone_port}) }} });
    var since = beginOpen();
    try std.testing.expectError(error.ConnectionRefused, testConnect(io, "unreachable.invalid", 443));
    noteOpenFailure(try std.Uri.parse("https://unreachable.invalid/"), since, error.ConnectionRefused);
    try std.testing.expect(std.mem.startsWith(u8, takeRequestFailure(error.ConnectionRefused, &buf).?, "could not connect to proxy 127.0.0.1:"));

    for ([_][]const u8{ "\x16\x03\x01\x00\x05hello", "HTTP/1.1 200 OK\r\n\r\nearly" }) |answer| {
        var proxy = try FakeProxy.init(base, answer);
        defer proxy.deinit(base);
        useSnapshotForTest(TestEnv{ .pairs = &.{.{ "HTTPS_PROXY", try std.mem.print(&url_buf, "http://127.0.0.1:{d}", .{proxy.port()}) }} });
        var server = try io.concurrent(FakeProxy.serveOne, .{ &proxy, base });
        since = beginOpen();
        try std.testing.expectError(error.ProtocolUnsupportedBySystem, testConnect(io, "garbage.invalid", 443));
        server.await(base);
        noteOpenFailure(try std.Uri.parse("https://garbage.invalid/"), since, error.ProtocolUnsupportedBySystem);
        try std.testing.expect(std.mem.endsWith(u8, takeRequestFailure(error.ProtocolUnsupportedBySystem, &buf).?, "with bytes that are not HTTP"));
    }

    useSnapshotForTest(TestEnv{ .pairs = &.{.{ "ALL_PROXY", "socks5://u:secret@127.0.0.1:1080" }} });
    since = beginOpen();
    try std.testing.expectError(error.ProtocolUnsupportedBySystem, testConnect(io, "socks.invalid", 443));
    noteOpenFailure(try std.Uri.parse("https://socks.invalid/"), since, error.ProtocolUnsupportedBySystem);
    try std.testing.expectEqualStrings("fx supports only http:// proxies, but ALL_PROXY is socks5://...", takeRequestFailure(error.ProtocolUnsupportedBySystem, &buf).?);
}

test "lookups stay direct for loopback and NO_PROXY, and racing threads share one handle per target" {
    const io = io_mod.getIo();
    useSnapshotForTest(TestEnv{ .pairs = &.{ .{ "HTTPS_PROXY", "http://127.0.0.1:9" }, .{ "NO_PROXY", "skip.invalid" } } });
    defer resetSnapshotForTest();
    const Probe = struct {
        fn first(probe_io: std.Io, host: []const u8, port: u16) !IpAddress {
            var buffer: [16]HostName.LookupResult = undefined;
            var queue: std.Io.Queue(HostName.LookupResult) = .init(&buffer);
            try HostName.lookup(try HostName.init(host), probe_io, &queue, .{ .port = port });
            while (queue.getOne(probe_io)) |item| switch (item) {
                .address => |address| return address,
                .canonical_name => {},
            } else |_| return error.NoAddressReturned;
        }

        /// Looks up the 64 shared hosts, starting at a different one per thread.
        fn many(probe_io: std.Io, offset: usize, out: *[64]u16) void {
            var name_buf: [64]u8 = undefined;
            for (0..64) |i| {
                const host_index = (i + offset) % 64;
                const name = std.mem.print(&name_buf, "h{d}.shared.invalid", .{host_index}) catch unreachable;
                const address = first(probe_io, name, 443) catch unreachable;
                out[host_index] = std.mem.readInt(u16, address.ip6.bytes[14..16], .big);
            }
        }
    };
    try std.testing.expect(tunnelOf(&(try Probe.first(io, "127.0.0.1", 443))) == null);
    try std.testing.expect(tunnelOf(&(try Probe.first(io, "localhost", 443))) == null);
    const routed = try Probe.first(io, "a.invalid", 443);
    try std.testing.expectEqualStrings("a.invalid", tunnelOf(&routed).?.name());
    try std.testing.expectEqual(@as(u16, 443), routed.getPort());

    var indexes: [4][64]u16 = undefined;
    var tasks: [4]std.Io.Future(void) = undefined;
    for (&tasks, &indexes, 0..) |*task, *out, t| task.* = try io.concurrent(Probe.many, .{ io, t * 16, out });
    for (&tasks) |*task| task.await(io);
    var name_buf: [64]u8 = undefined;
    for (0..64) |host_index| {
        for (indexes[1..]) |out| try std.testing.expectEqual(indexes[0][host_index], out[host_index]);
        const expected = try std.mem.print(&name_buf, "h{d}.shared.invalid", .{host_index});
        try std.testing.expectEqualStrings(expected, targets[indexes[0][host_index]].name());
    }
}

test "the tunnel table fills to its limit and refuses the next target cleanly" {
    const io = io_mod.getIo();
    useSnapshotForTest(TestEnv{ .pairs = &.{.{ "HTTPS_PROXY", "http://127.0.0.1:9" }} });
    defer resetSnapshotForTest();
    resetTunnelsForTest();
    defer resetTunnelsForTest();
    var name_buf: [64]u8 = undefined;
    var buffer: [16]HostName.LookupResult = undefined;
    for (0..max_tunnels) |i| {
        var queue: std.Io.Queue(HostName.LookupResult) = .init(&buffer);
        const name = try std.mem.print(&name_buf, "t{d}.full.invalid", .{i});
        try HostName.lookup(try HostName.init(name), io, &queue, .{ .port = 443 });
    }
    try std.testing.expectEqual(@as(usize, max_tunnels), targets_len.load(.acquire));
    // A host already in the table still gets its handle; a new one fails.
    var queue: std.Io.Queue(HostName.LookupResult) = .init(&buffer);
    try HostName.lookup(try HostName.init("t7.full.invalid"), io, &queue, .{ .port = 443 });
    var full_queue: std.Io.Queue(HostName.LookupResult) = .init(&buffer);
    try std.testing.expectError(error.NameServerFailure, HostName.lookup(try HostName.init("one-more.full.invalid"), io, &full_queue, .{ .port = 443 }));
}

test "32 tunnels opened at once each carry their own bytes" {
    const base = std.testing.io;
    const io = io_mod.getIo();
    const connections = 32;
    const ManyProxy = struct {
        server: std.Io.net.Server,
        seen: std.atomic.Value(u32) = .init(0),

        fn serveConnection(p: *@This(), stream: std.Io.net.Stream) void {
            defer stream.close(base);
            var read_buf: [512]u8 = undefined;
            var reader = stream.reader(base, &read_buf);
            var tail: [4]u8 = @splat(0);
            while (!std.mem.eql(u8, &tail, "\r\n\r\n")) {
                const byte = reader.interface.takeByte() catch return;
                tail = .{ tail[1], tail[2], tail[3], byte };
            }
            _ = p.seen.fetchAdd(1, .acq_rel);
            var write_buf: [64]u8 = undefined;
            var writer = stream.writer(base, &write_buf);
            writer.interface.writeAll("HTTP/1.1 200 Connection established\r\n\r\n") catch return;
            writer.interface.flush() catch return;
            const echo = reader.interface.take(4) catch return;
            writer.interface.writeAll(echo) catch return;
            writer.interface.flush() catch return;
        }

        fn serve(p: *@This()) void {
            var group: std.Io.Group = .init;
            defer group.await(base) catch {};
            for (0..connections) |_| {
                const stream = p.server.accept(base) catch return;
                group.concurrent(base, serveConnection, .{ p, stream }) catch {
                    serveConnection(p, stream);
                };
            }
        }
    };
    const address: IpAddress = .{ .ip4 = .loopback(0) };
    var proxy: ManyProxy = .{ .server = try address.listen(base, .{ .reuse_address = true, .kernel_backlog = 64 }) };
    defer proxy.server.deinit(base);
    var url_buf: [64]u8 = undefined;
    useSnapshotForTest(TestEnv{ .pairs = &.{.{ "HTTPS_PROXY", try std.mem.print(&url_buf, "http://127.0.0.1:{d}", .{proxy.server.socket.address.getPort()}) }} });
    defer resetSnapshotForTest();
    var server = try io.concurrent(ManyProxy.serve, .{&proxy});

    const Client = struct {
        fn run(index: usize, ok: *std.atomic.Value(u32)) void {
            const client_io = io_mod.getIo();
            var name_buf: [64]u8 = undefined;
            const name = std.mem.print(&name_buf, "h{d}.many.invalid", .{index}) catch return;
            const stream = testConnect(client_io, name, 443) catch return;
            defer stream.close(client_io);
            var message: [4]u8 = undefined;
            std.mem.writeInt(u32, &message, @intCast(index), .little);
            var write_buf: [8]u8 = undefined;
            var writer = stream.writer(client_io, &write_buf);
            writer.interface.writeAll(&message) catch return;
            writer.interface.flush() catch return;
            var read_buf: [8]u8 = undefined;
            var reader = stream.reader(client_io, &read_buf);
            const back = reader.interface.take(4) catch return;
            if (std.mem.eql(u8, back, &message)) _ = ok.fetchAdd(1, .acq_rel);
        }
    };
    var ok: std.atomic.Value(u32) = .init(0);
    var clients: [connections]std.Io.Future(void) = undefined;
    for (&clients, 0..) |*client, i| client.* = try io.concurrent(Client.run, .{ i, &ok });
    for (&clients) |*client| client.await(io);
    server.await(io);
    try std.testing.expectEqual(@as(u32, connections), ok.load(.acquire));
    try std.testing.expectEqual(@as(u32, connections), proxy.seen.load(.acquire));
}
