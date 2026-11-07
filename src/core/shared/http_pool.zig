const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("debug_trace.zig");
const io_mod = @import("io.zig");
const local_address = @import("local_address.zig");
const tls_roots = @import("tls_roots.zig");

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
    /// Connection opens running on their own threads (src/gateway/client.zig
    /// OpenJob). One a request walked away from may still be inside a
    /// DNS lookup that never returns.
    open_jobs: std.atomic.Value(u32) = .init(0),
    deinitialized: bool = false,

    pub const DestroyDisposition = enum {
        /// Pool resources released; caller may free the HttpPool itself.
        destroyed,
        /// A warm flight is still inside connect and owns the client. The
        /// pool is intentionally leaked; only reachable while a process is
        /// exiting or abandoning state, so the memory dies with the process.
        abandoned_warm_flight,
        /// A connection open a request walked away from still owns the
        /// client; the pool is leaked the same way.
        abandoned_open_job,
    };

    pub fn init(alloc: std.mem.Allocator) HttpPool {
        return .{ .client = .{ .allocator = alloc, .io = io_mod.getIo() } };
    }

    /// Tears the pool down. When a warm flight is still inside connect, or a
    /// connection open a request walked away from is still running, waits
    /// briefly for it, then abandons rather than freeing memory the thread is
    /// using (only reachable on process-abandon paths).
    pub fn deinit(self: *HttpPool) DestroyDisposition {
        if (self.deinitialized) return .destroyed;
        self.deinitialized = true;
        if (self.warm_started.load(.acquire) and !waitBriefly(self, warmFlightDone)) {
            debug_trace.logf("gateway", "pool_deinit result=abandoned_warm_flight", .{});
            return .abandoned_warm_flight;
        }
        if (!waitBriefly(self, openJobsDone)) {
            debug_trace.logf("gateway", "pool_deinit result=abandoned_open_job jobs={d}", .{self.open_jobs.load(.acquire)});
            return .abandoned_open_job;
        }
        self.client.deinit();
        return .destroyed;
    }

    /// Waits up to 500 ms for `done`; true when it came.
    fn waitBriefly(self: *const HttpPool, comptime done: fn (*const HttpPool) bool) bool {
        var waited_ms: u64 = 0;
        while (!done(self) and waited_ms < 500) : (waited_ms += 10) {
            io_mod.sleep(10 * std.time.ns_per_ms);
        }
        return done(self);
    }

    fn warmFlightDone(self: *const HttpPool) bool {
        return self.warm_done.load(.acquire);
    }

    fn openJobsDone(self: *const HttpPool) bool {
        return self.open_jobs.load(.acquire) == 0;
    }

    pub fn beginOpenJob(self: *HttpPool) void {
        _ = self.open_jobs.fetchAdd(1, .acq_rel);
    }

    /// A job's last touch of the pool.
    pub fn endOpenJob(self: *HttpPool) void {
        _ = self.open_jobs.fetchSub(1, .acq_rel);
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
        // Client.connect skips the TLS preamble that Client.request
        // performs; Tls.create requires ca_bundle loaded and now set.
        tls_roots.prepare(&self.client, uri) catch |err| {
            debug_trace.logf("gateway", "pool_warm result=error stage=tls_init err={s}", .{@errorName(err)});
            return;
        };
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
        try tls_roots.prepare(&self.client, uri);
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
    /// as usual. A connection whose local address left the machine, after a
    /// network change, can never answer again, so it is closed instead.
    fn takeIdleConnection(self: *HttpPool, uri: std.Uri) ?*std.http.Client.Connection {
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const criteria = originCriteria(uri, &host_buf) orelse return null;
        const proxy = switch (criteria.protocol) {
            .plain => self.client.http_proxy,
            .tls => self.client.https_proxy,
        };
        if (proxy != null) return null;
        const io = self.client.io;
        while (true) {
            const connection = (self.client.connection_pool.findConnection(io, criteria) catch |err| switch (err) {
                error.Canceled => {
                    io.recancel();
                    return null;
                },
            }) orelse return null;
            if (!addressGone(connection)) return connection;
            self.destroyTaken(io, connection);
            debug_trace.logf("gateway", "event=pool_drop_address_gone dropped=idle connection reason=its local address left the machine", .{});
        }
    }

    fn addressGone(connection: *std.http.Client.Connection) bool {
        const address = local_address.of(connection.stream_writer.stream.socket.handle) orelse return false;
        return local_address.missing(address);
    }

    /// Destroys a connection `findConnection` returned, which sits on the
    /// used list; destroy does not touch the lists.
    fn destroyTaken(self: *HttpPool, io: std.Io, connection: *std.http.Client.Connection) void {
        self.client.connection_pool.mutex.lockUncancelable(io);
        self.client.connection_pool.used.remove(&connection.pool_node);
        self.client.connection_pool.mutex.unlock(io);
        connection.destroy(io);
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
            self.destroyTaken(io, conn);
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

/// A test Io that refuses to open either keychain file std's macOS scan
/// reads, as a sandbox that denies them does, so no test reads them.
const KeychainDeniedIo = struct {
    var vtable: std.Io.VTable = undefined;

    fn io() std.Io {
        vtable = std.testing.io.vtable.*;
        vtable.dirOpenFile = open;
        return .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    }

    fn open(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
        if (std.mem.eql(u8, path, "/System/Library/Keychains/SystemRootCertificates.keychain") or
            std.mem.eql(u8, path, "/Library/Keychains/System.keychain")) return error.PermissionDenied;
        return std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
    }
};

test "the pool loads trusted roots when a sandbox denies the keychain files" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // Nothing listens on port 1, so each attempt ends at the connect, after
    // the roots load.
    var warmed = HttpPool.init(std.testing.allocator);
    defer _ = warmed.deinit();
    warmed.client.io = KeychainDeniedIo.io();
    warmed.warm("https://127.0.0.1:1/");
    try std.testing.expect(warmed.client.now != null);
    try std.testing.expect(warmed.client.ca_bundle.map.count() > 0);

    var opened = HttpPool.init(std.testing.allocator);
    defer _ = opened.deinit();
    opened.client.io = KeychainDeniedIo.io();
    const uri = try std.Uri.parse("https://127.0.0.1:1/v1/chat/completions");
    if (opened.openRequest(.POST, uri, .{})) |pooled| {
        var request = pooled.request;
        request.deinit();
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expect(err != error.CertificateBundleLoadFailure);
    try std.testing.expect(opened.client.now != null);
    try std.testing.expect(opened.client.ca_bundle.map.count() > 0);
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

test "openRequest closes an idle connection whose local address left the machine" {
    if (comptime !local_address.supported) return error.SkipZigTest;
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

    local_address.test_missing = true;
    var opened = pool.openRequest(.POST, uri, .{}) catch |err| {
        local_address.test_missing = false;
        return err;
    };
    local_address.test_missing = false;
    // The idle connection was closed, and the request dialed a fresh one.
    try std.testing.expect(!opened.reused);
    try std.testing.expectEqual(@as(usize, 0), pool.freeConnectionCount());
    opened.request.deinit();
    try std.testing.expectEqual(@as(usize, 1), pool.freeConnectionCount());
}
