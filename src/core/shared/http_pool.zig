const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("debug_trace.zig");
const io_mod = @import("io.zig");

/// Long-lived HTTP client wrapper that keeps std's ConnectionPool alive
/// across requests to one product origin. std already implements acquire,
/// release, and thread safety; this wrapper owns the product concerns std
/// does not: client lifetime, launch warming, idle staleness, and a current
/// certificate-validity clock.
///
/// Ownership: created once per process by the provider runtime, borrowed by
/// request paths. All methods are safe to call from concurrent request
/// threads (the underlying std pool is internally mutex-guarded).
const default_ttl_ms: i64 = 30_000;

pub const HttpPool = struct {
    client: std.http.Client,
    /// std checks server certificates against `client.now` and reads it
    /// without a lock during TLS setup. Every connection setup on `client`
    /// holds this shared; advancing the clock holds it exclusively.
    setup_lock: std.Io.RwLock = .init,
    /// Pooled connections idle longer than this are closed instead of reused.
    /// std's pool has no liveness tracking; a gracefully-idle-closed
    /// connection fails only when the next request writes to it or reads its
    /// head. `openRequest` reports reuse so the gateway client can resend that
    /// request once on a fresh connection. Bounding idle age keeps that
    /// rare. One conservative timestamp is enough: the pool only gains free
    /// connections at noteActivity-stamped completions, so when
    /// now - last_activity > ttl every free connection is provably stale.
    ttl_ms: i64 = default_ttl_ms,
    last_activity_ms: std.atomic.Value(i64) = .init(0),
    warm_started: std.atomic.Value(bool) = .init(false),
    warm_done: std.atomic.Value(bool) = .init(false),
    deinitialized: bool = false,

    pub const DestroyDisposition = enum {
        /// Pool resources released; caller may free the HttpPool itself.
        destroyed,
        /// A warm flight is still inside connect and owns the client. The
        /// pool is intentionally leaked; only reachable while a process is
        /// exiting or abandoning state, so the memory dies with the process.
        abandoned_warm_flight,
    };

    pub fn init(alloc: std.mem.Allocator) HttpPool {
        return .{ .client = .{ .allocator = alloc, .io = io_mod.getIo() } };
    }

    /// Tears the pool down. When a warm flight is still inside connect, waits
    /// briefly for it, then abandons rather than freeing memory the thread is
    /// using (only reachable on process-abandon paths).
    pub fn deinit(self: *HttpPool) DestroyDisposition {
        if (self.deinitialized) return .destroyed;
        self.deinitialized = true;
        if (self.warm_started.load(.acquire) and !self.warm_done.load(.acquire)) {
            var waited_ms: u64 = 0;
            while (!self.warm_done.load(.acquire) and waited_ms < 500) : (waited_ms += 10) {
                io_mod.sleep(10 * std.time.ns_per_ms);
            }
            if (!self.warm_done.load(.acquire)) {
                debug_trace.logf("gateway", "pool_deinit result=abandoned_warm_flight", .{});
                return .abandoned_warm_flight;
            }
        }
        self.client.deinit();
        return .destroyed;
    }

    pub fn noteActivity(self: *HttpPool) void {
        self.last_activity_ms.store(io_mod.milliTimestamp(), .release);
    }

    /// Free-connection count for observability; owns the std-pool locking so
    /// callers never touch connection_pool internals.
    pub fn freeConnectionCount(self: *HttpPool) usize {
        const io = io_mod.getIo();
        self.client.connection_pool.mutex.lockUncancelable(io);
        defer self.client.connection_pool.mutex.unlock(io);
        return self.client.connection_pool.free_len;
    }

    /// Establishes one connection to the URL's origin and parks it in the
    /// pool. Best-effort: failures are traced, never propagated.
    fn warm(self: *HttpPool, url: []const u8) void {
        const io = io_mod.getIo();
        const uri = std.Uri.parse(url) catch return;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return;
        if (protocol == .tls) {
            // Client.connect skips the TLS preamble that Client.request
            // performs; Tls.create requires ca_bundle loaded and now set.
            self.ensureTlsReady() catch |err| {
                debug_trace.logf("gateway", "pool_warm result=error stage=tls_init err={s}", .{@errorName(err)});
                return;
            };
        }
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(uri, &host_buf) catch return;
        const port: u16 = uri.port orelse defaultPort(protocol);
        const started = io_mod.milliTimestamp();
        const conn = conn: {
            self.setup_lock.lockSharedUncancelable(io);
            defer self.setup_lock.unlockShared(io);
            break :conn self.client.connect(host, port, protocol) catch |err| {
                debug_trace.logf("gateway", "pool_warm result=error err={s}", .{@errorName(err)});
                return;
            };
        };
        self.client.connection_pool.release(conn, io);
        self.noteActivity();
        debug_trace.logf("gateway", "pool_warm result=ok elapsed_ms={d}", .{io_mod.milliTimestamp() - started});
    }

    /// Mirrors the cert-bundle preamble of std.http.Client.request so direct
    /// Client.connect calls are safe. Concurrent with real requests by lock.
    fn ensureTlsReady(self: *HttpPool) !void {
        const client = &self.client;
        const io = client.io;
        {
            try client.ca_bundle_lock.lockShared(io);
            defer client.ca_bundle_lock.unlockShared(io);
            if (client.now != null) return;
        }
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(client.allocator);
        const now = std.Io.Clock.real.now(io);
        bundle.rescan(client.allocator, io, now) catch return error.CertificateBundleLoadFailure;
        try client.ca_bundle_lock.lock(io);
        defer client.ca_bundle_lock.unlock(io);
        if (client.now != null) return; // a concurrent request loaded it first
        client.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    }

    /// Spawns the warmer on a detached thread, at most once per pool.
    /// `url` must remain valid for the process lifetime (string literals and
    /// environment-variable storage both qualify). Test builds never spawn;
    /// call warm() synchronously to exercise the logic.
    pub fn warmAsync(self: *HttpPool, url: []const u8) void {
        if (comptime builtin.is_test) return;
        if (self.warm_started.swap(true, .acq_rel)) return;
        const thread = std.Thread.spawn(.{}, warmThreadMain, .{ self, url }) catch {
            self.warm_started.store(false, .release);
            return;
        };
        thread.detach();
    }

    fn warmThreadMain(self: *HttpPool, url: []const u8) void {
        defer self.warm_done.store(true, .release);
        self.warm(url);
    }

    /// Returns the shared client after applying the idle-staleness policy for
    /// this origin. Call once per request, before opening.
    pub fn clientFor(self: *HttpPool, url: []const u8) *std.http.Client {
        self.drainIfStale(url);
        return &self.client;
    }

    /// Opens a request on the shared client with a current certificate
    /// clock, and reports whether it reuses an idle pooled connection, which
    /// the server may have closed while it sat idle. When none is idle, std
    /// may still reuse one that another request released in between; that
    /// counts as fresh, so its failures are reported. The setup lock is held
    /// shared through connection setup; the exclusive holder only stores a
    /// timestamp, so the wait is bounded.
    pub fn openRequest(
        self: *HttpPool,
        method: std.http.Method,
        uri: std.Uri,
        options: std.http.Client.RequestOptions,
    ) std.http.Client.RequestError!PooledRequest {
        self.refreshTlsClock();
        const io = self.client.io;
        self.setup_lock.lockSharedUncancelable(io);
        defer self.setup_lock.unlockShared(io);
        var pooled_options = options;
        const idle = if (options.connection == null) self.takeIdleConnection(uri) else null;
        if (idle) |connection| pooled_options.connection = connection;
        const request = self.client.request(method, uri, pooled_options) catch |err| {
            if (idle) |connection| self.client.connection_pool.release(connection, io);
            return err;
        };
        return .{ .request = request, .reused = idle != null };
    }

    /// Takes an idle pooled connection to the URI's origin. Returns null when
    /// none is free or a proxy carries the request, in which case std connects
    /// as usual.
    fn takeIdleConnection(self: *HttpPool, uri: std.Uri) ?*std.http.Client.Connection {
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const criteria = originCriteria(uri, &host_buf) orelse return null;
        const proxy = switch (criteria.protocol) {
            .plain => self.client.http_proxy,
            .tls => self.client.https_proxy,
        };
        if (proxy != null) return null;
        const io = self.client.io;
        return self.client.connection_pool.findConnection(io, criteria) catch |err| switch (err) {
            error.Canceled => {
                io.recancel();
                return null;
            },
        };
    }

    /// std sets `client.now` once, when the CA bundle first loads, so a
    /// long-lived process would reject every certificate issued after that
    /// moment as not yet valid. Skips while another connection setup is
    /// reading the clock; the next open advances it instead.
    fn refreshTlsClock(self: *HttpPool) void {
        const client = &self.client;
        const io = client.io;
        if (!self.setup_lock.tryLock(io)) return;
        defer self.setup_lock.unlock(io);
        client.ca_bundle_lock.lockUncancelable(io);
        defer client.ca_bundle_lock.unlock(io);
        // Unloaded: std's request preamble sets the clock with the bundle.
        if (client.now == null) return;
        client.now = std.Io.Clock.real.now(io);
    }

    fn drainIfStale(self: *HttpPool, url: []const u8) void {
        const last = self.last_activity_ms.load(.acquire);
        if (last == 0) return;
        const now = io_mod.milliTimestamp();
        const idle_ms = now - last;
        if (idle_ms <= self.ttl_ms) return;
        const drained = self.closeIdleConnections(url);
        // Refresh the stamp so a run of misses does not re-drain every call.
        self.last_activity_ms.store(now, .release);
        if (drained > 0) {
            debug_trace.logf("gateway", "pool_drain_stale count={d} idle_ms={d} ttl_ms={d}", .{ drained, idle_ms, self.ttl_ms });
        }
    }

    /// Closes every idle pooled connection to the URL's origin and returns
    /// how many it closed.
    pub fn closeIdleConnections(self: *HttpPool, url: []const u8) usize {
        const io = io_mod.getIo();
        const uri = std.Uri.parse(url) catch return 0;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const criteria = originCriteria(uri, &host_buf) orelse return 0;
        var closed: usize = 0;
        while (true) {
            // A cancelled drain stops early and leaves the cancellation pending.
            const conn = (self.client.connection_pool.findConnection(io, criteria) catch |err| switch (err) {
                error.Canceled => {
                    io.recancel();
                    break;
                },
            }) orelse break;
            // findConnection moves the connection to the used list; unlink it
            // there before destroying, since destroy does not touch the lists.
            self.client.connection_pool.mutex.lockUncancelable(io);
            self.client.connection_pool.used.remove(&conn.pool_node);
            self.client.connection_pool.mutex.unlock(io);
            conn.destroy(io);
            closed += 1;
        }
        return closed;
    }

    fn originCriteria(
        uri: std.Uri,
        host_buf: *[std.Io.net.HostName.max_len]u8,
    ) ?std.http.Client.ConnectionPool.Criteria {
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return null;
        const host = std.Io.net.HostName.fromUri(uri, host_buf) catch return null;
        return .{
            .host = host,
            .port = uri.port orelse defaultPort(protocol),
            .protocol = protocol,
        };
    }

    fn defaultPort(protocol: std.http.Client.Protocol) u16 {
        return switch (protocol) {
            .plain => 80,
            .tls => 443,
        };
    }
};

/// A request opened on the pool, and whether it reuses an idle connection.
const PooledRequest = struct {
    request: std.http.Client.Request,
    reused: bool,
};

test "warm and drain tolerate malformed urls without touching the pool" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.warm("not a url");
    pool.warm("ftp://unsupported.example");
    _ = pool.clientFor("not a url");
    try std.testing.expectEqual(@as(i64, 0), pool.last_activity_ms.load(.acquire));
}

test "drainIfStale skips within-ttl and never-active pools" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.noteActivity();
    _ = pool.clientFor("https://ai-gateway.vercel.sh/v4/ai/language-model");
    const stamp = pool.last_activity_ms.load(.acquire);
    try std.testing.expect(stamp > 0);
    pool.ttl_ms = 0; // force stale on next call; empty pool drains zero
    _ = pool.clientFor("https://ai-gateway.vercel.sh/v4/ai/language-model");
    try std.testing.expect(pool.last_activity_ms.load(.acquire) >= stamp);
}

test "warmAsync is a no-op in test builds" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.warmAsync("https://127.0.0.1:1/unreachable");
    try std.testing.expect(!pool.warm_started.load(.acquire));
}

test "TLS clock refresh leaves an unloaded clock for std to load" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.refreshTlsClock();
    try std.testing.expect(pool.client.now == null);
}

test "TLS clock refresh skips while a connection setup reads the clock" {
    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    const io = pool.client.io;
    // As though the bundle loaded when the process started, long ago.
    const stale = std.Io.Timestamp.fromNanoseconds(1);
    pool.client.now = stale;

    pool.setup_lock.lockSharedUncancelable(io);
    pool.refreshTlsClock();
    try std.testing.expectEqual(stale.nanoseconds, pool.client.now.?.nanoseconds);
    pool.setup_lock.unlockShared(io);

    const before = std.Io.Clock.real.now(io);
    pool.refreshTlsClock();
    try std.testing.expect(pool.client.now.?.nanoseconds >= before.nanoseconds);
}

test "openRequest advances a stale clock before connection setup" {
    const zio = io_mod.getIo();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(zio, .{ .reuse_address = true });
    defer server.deinit(zio);
    const url = try std.testing.allocator.print("http://127.0.0.1:{d}/chat", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();
    pool.client.now = std.Io.Timestamp.fromNanoseconds(1);
    const before = std.Io.Clock.real.now(zio);

    // The listen backlog completes the connect without any server accept.
    var opened = try pool.openRequest(.POST, try std.Uri.parse(url), .{});
    defer opened.request.deinit();
    try std.testing.expect(pool.client.now.?.nanoseconds >= before.nanoseconds);
    try std.testing.expect(!opened.reused);
}

test "openRequest reports a reused idle connection and returns it to the pool" {
    const zio = io_mod.getIo();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(zio, .{ .reuse_address = true });
    defer server.deinit(zio);
    const url = try std.testing.allocator.print("http://127.0.0.1:{d}/chat", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);
    const uri = try std.Uri.parse(url);

    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();

    // The listen backlog completes the connect without any server accept.
    pool.warm(url);
    try std.testing.expectEqual(@as(usize, 1), pool.freeConnectionCount());

    var opened = try pool.openRequest(.POST, uri, .{});
    try std.testing.expect(opened.reused);
    try std.testing.expectEqual(@as(usize, 0), pool.freeConnectionCount());
    opened.request.deinit();
    try std.testing.expectEqual(@as(usize, 1), pool.freeConnectionCount());

    try std.testing.expectEqual(@as(usize, 1), pool.closeIdleConnections(url));
    try std.testing.expectEqual(@as(usize, 0), pool.freeConnectionCount());
    try std.testing.expectEqual(@as(usize, 0), pool.closeIdleConnections("not a url"));
}

test "drain evicts a real parked connection past the TTL" {
    const zio = io_mod.getIo();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(zio, .{ .reuse_address = true });
    defer server.deinit(zio);
    const url = try std.testing.allocator.print("http://127.0.0.1:{d}/chat", .{server.socket.address.getPort()});
    defer std.testing.allocator.free(url);

    var pool = HttpPool.init(std.testing.allocator);
    defer _ = pool.deinit();

    // The listen backlog completes the connect without any server accept.
    pool.warm(url);
    try std.testing.expectEqual(@as(usize, 1), pool.freeConnectionCount());

    pool.ttl_ms = 0; // every parked connection is stale immediately
    pool.last_activity_ms.store(io_mod.milliTimestamp() - 1000, .release);
    _ = pool.clientFor(url);
    try std.testing.expectEqual(@as(usize, 0), pool.freeConnectionCount());
}
