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

/// Loads trust roots before std.http.Client can attempt its own Keychain scan.
/// A confined macOS process can read public CA roots without permission to read
/// the System keychain, which may also contain private credentials.
pub fn prepareTls(client: *std.http.Client, uri: std.Uri) !void {
    if (std.http.Client.Protocol.fromUri(uri) != .tls) return;
    const io = client.io;
    {
        try client.ca_bundle_lock.lockShared(io);
        defer client.ca_bundle_lock.unlockShared(io);
        if (client.now != null) return;
    }
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = std.Io.Clock.real.now(io);
    bundle.rescan(client.allocator, io, now) catch |err| {
        if (builtin.os.tag != .macos or (err != error.AccessDenied and err != error.PermissionDenied))
            return error.CertificateBundleLoadFailure;
        // Discard a partial scan. The fallback contains public roots only;
        // custom Keychain trust is unavailable under this confinement.
        bundle.deinit(client.allocator);
        bundle = .empty;
        bundle.addCertsFromFilePathAbsolute(client.allocator, io, now, "/etc/ssl/cert.pem") catch
            return error.CertificateBundleLoadFailure;
        if (bundle.map.count() == 0) return error.CertificateBundleLoadFailure;
    };
    try client.ca_bundle_lock.lock(io);
    defer client.ca_bundle_lock.unlock(io);
    if (client.now != null) return;
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

pub const HttpPool = struct {
    client: std.http.Client,
    /// std checks server certificates against `client.now` and reads it
    /// without a lock during TLS setup. Every connection setup on `client`
    /// holds this shared; advancing the clock holds it exclusively.
    setup_lock: std.Io.RwLock = .init,
    /// Pooled connections idle longer than this are closed instead of reused.
    /// std's pool has no liveness tracking; a gracefully-idle-closed
    /// connection fails only when the next request reads from it, which lands
    /// in the delivery-ambiguity retry path. Bounding idle age keeps that
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
            prepareTls(&self.client, uri) catch |err| {
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
    /// clock. The setup lock is held shared through connection setup; the
    /// exclusive holder only stores a timestamp, so the wait is bounded.
    pub fn openRequest(
        self: *HttpPool,
        method: std.http.Method,
        uri: std.Uri,
        options: std.http.Client.RequestOptions,
    ) std.http.Client.RequestError!std.http.Client.Request {
        try prepareTls(&self.client, uri);
        self.refreshTlsClock();
        const io = self.client.io;
        self.setup_lock.lockSharedUncancelable(io);
        defer self.setup_lock.unlockShared(io);
        return self.client.request(method, uri, options);
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
        const io = io_mod.getIo();
        const uri = std.Uri.parse(url) catch return;
        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = std.Io.net.HostName.fromUri(uri, &host_buf) catch return;
        const port: u16 = uri.port orelse defaultPort(protocol);
        const criteria: std.http.Client.ConnectionPool.Criteria = .{
            .host = host,
            .port = port,
            .protocol = protocol,
        };
        var drained: usize = 0;
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
            drained += 1;
        }
        // Refresh the stamp so a run of misses does not re-drain every call.
        self.last_activity_ms.store(now, .release);
        if (drained > 0) {
            debug_trace.logf("gateway", "pool_drain_stale count={d} idle_ms={d} ttl_ms={d}", .{ drained, idle_ms, self.ttl_ms });
        }
    }

    fn defaultPort(protocol: std.http.Client.Protocol) u16 {
        return switch (protocol) {
            .plain => 80,
            .tls => 443,
        };
    }
};

test "TLS trust loads public roots when the System keychain is denied" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var vtable = std.testing.io.vtable.*;
    vtable.dirOpenFile = struct {
        fn open(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            if (std.mem.eql(u8, path, "/Library/Keychains/System.keychain")) return error.PermissionDenied;
            return std.testing.io.vtable.dirOpenFile(userdata, dir, path, options);
        }
    }.open;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    const uri = try std.Uri.parse("https://example.com");
    try prepareTls(&client, uri);
    try std.testing.expect(client.now != null);
    try std.testing.expect(client.ca_bundle.map.count() > 0);
    const now = client.now;
    const count = client.ca_bundle.map.count();
    try prepareTls(&client, uri);
    try std.testing.expectEqual(now, client.now);
    try std.testing.expectEqual(count, client.ca_bundle.map.count());
}

test "TLS trust fails closed when both Keychain and public roots are denied" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var vtable = std.testing.io.vtable.*;
    vtable.dirOpenFile = struct {
        fn open(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            return error.PermissionDenied;
        }
    }.open;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    try std.testing.expectError(error.CertificateBundleLoadFailure, prepareTls(&client, try std.Uri.parse("https://example.com")));
    try std.testing.expectEqual(null, client.now);
    try std.testing.expectEqual(0, client.ca_bundle.map.count());
}

test "plain HTTP does not require certificate store access" {
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    try prepareTls(&client, try std.Uri.parse("http://localhost"));
    try std.testing.expectEqual(null, client.now);
    try std.testing.expectEqual(0, client.ca_bundle.map.count());
}

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
    var req = try pool.openRequest(.POST, try std.Uri.parse(url), .{});
    defer req.deinit();
    try std.testing.expect(pool.client.now.?.nanoseconds >= before.nanoseconds);
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
