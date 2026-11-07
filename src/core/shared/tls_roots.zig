//! The trusted roots for fx's HTTPS clients. Every `std.http.Client` fx makes
//! loads its roots through `prepare` before its first TLS request, and
//! web_fetch's own TLS client through `load`, in place of std's own scan,
//! which fails the request on any error.
//!
//! On macOS std reads the system keychain files. A sandbox that denies one of
//! them, as Agent Safehouse does for /Library/Keychains/System.keychain,
//! stops that scan with a permission error. The roots then come from the
//! public CA bundle at /etc/ssl/cert.pem instead, and what the scan read is
//! dropped, so a bundle holds one whole source. Authorities trusted only in
//! the keychain are not in that file. Verification stays on: a public bundle
//! that can't be read or holds no roots fails, and so does every other scan
//! error and every error on other systems (`tests/tla/tls_roots/TlsRoots.tla`).

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("debug_trace.zig");

const Allocator = std.mem.Allocator;
const Bundle = std.crypto.Certificate.Bundle;

/// The public CA bundle macOS ships, read when a sandbox denies the keychain.
const public_bundle_path = "/etc/ssl/cert.pem";

/// `CertificateBundleLoadFailure` is the error std's own scan returns, so
/// callers and the message people see stay the same.
const Error = error{ CertificateBundleLoadFailure, Canceled };

const AfterScanError = enum { fallback, fail, cancel };

/// What to do after the system scan failed with `err` on `os`: only a
/// permission error on macOS falls back to the public bundle
/// (`tests/tla/tls_roots/TlsRoots.tla` FallbackOnlyOnDenial).
fn afterScanError(os: std.Target.Os.Tag, err: Bundle.RescanError) AfterScanError {
    return switch (err) {
        error.Canceled => .cancel,
        error.AccessDenied, error.PermissionDenied => if (os == .macos) .fallback else .fail,
        else => .fail,
    };
}

/// Where a load reads from: the system scan, and the file it falls back to.
const Sources = struct {
    os: std.Target.Os.Tag,
    scan: *const fn (*Bundle, Allocator, std.Io, std.Io.Timestamp) Bundle.RescanError!void,
    fallback_path: []const u8,
};

const system_sources: Sources = .{
    .os = builtin.os.tag,
    .scan = &Bundle.rescan,
    .fallback_path = public_bundle_path,
};

/// Fills `bundle`, which must be empty, with the roots fx trusts, checked
/// against `now`. On error `bundle` is left empty. The caller owns `bundle`.
pub fn load(bundle: *Bundle, gpa: Allocator, io: std.Io, now: std.Io.Timestamp) Error!void {
    return loadFrom(bundle, gpa, io, now, system_sources);
}

fn loadFrom(bundle: *Bundle, gpa: Allocator, io: std.Io, now: std.Io.Timestamp, sources: Sources) Error!void {
    sources.scan(bundle, gpa, io, now) catch |scan_err| {
        // Drop what the scan read before it stopped (`TlsRoots.tla` OneSource).
        clear(bundle, gpa);
        switch (afterScanError(sources.os, scan_err)) {
            .cancel => return error.Canceled,
            .fail => {
                debug_trace.logf("tls", "event=roots_failed stage=scan err={s}", .{@errorName(scan_err)});
                return error.CertificateBundleLoadFailure;
            },
            .fallback => {},
        }
        loadPublicBundle(bundle, gpa, io, now, sources.fallback_path) catch |err| {
            clear(bundle, gpa);
            if (err == error.Canceled) return error.Canceled;
            debug_trace.logf("tls", "event=roots_failed stage=public_bundle scan_err={s} err={s}", .{ @errorName(scan_err), @errorName(err) });
            return error.CertificateBundleLoadFailure;
        };
        debug_trace.logf("tls", "event=roots_loaded source=public_bundle roots={d} scan_err={s}", .{ bundle.map.count(), @errorName(scan_err) });
        return;
    };
    debug_trace.logf("tls", "event=roots_loaded source=system roots={d}", .{bundle.map.count()});
}

/// Reads the public bundle at `path`. One with no roots fails closed
/// (`TlsRoots.tla` InstalledNotEmpty).
fn loadPublicBundle(bundle: *Bundle, gpa: Allocator, io: std.Io, now: std.Io.Timestamp, path: []const u8) (Bundle.AddCertsFromFilePathError || error{NoRoots})!void {
    try bundle.addCertsFromFilePathAbsolute(gpa, io, now, path);
    if (bundle.map.count() == 0) return error.NoRoots;
    bundle.bytes.shrinkAndFree(gpa, bundle.bytes.items.len);
}

fn clear(bundle: *Bundle, gpa: Allocator) void {
    bundle.deinit(gpa);
    bundle.* = .empty;
}

/// Loads `client`'s roots and sets its clock before a request to `uri`, so
/// std's request does not scan on its own. Does nothing for plain HTTP or
/// once the client has its roots. Safe for concurrent requests on one client.
pub fn prepare(client: *std.http.Client, uri: std.Uri) Error!void {
    return prepareFrom(client, uri, system_sources);
}

/// `prepare` for a URL. One that doesn't parse is left for std to report.
fn prepareUrl(client: *std.http.Client, url: []const u8) Error!void {
    const uri = std.Uri.parse(url) catch return;
    return prepare(client, uri);
}

/// `client.request` with its roots loaded first. A failed load returns the
/// same error std's own scan did.
pub fn request(
    client: *std.http.Client,
    method: std.http.Method,
    uri: std.Uri,
    options: std.http.Client.RequestOptions,
) std.http.Client.RequestError!std.http.Client.Request {
    try prepare(client, uri);
    return client.request(method, uri, options);
}

/// `client.fetch` with its roots loaded first. A failed load returns the
/// same error std's own scan did.
pub fn fetch(client: *std.http.Client, options: std.http.Client.FetchOptions) std.http.Client.FetchError!std.http.Client.FetchResult {
    switch (options.location) {
        .url => |url| try prepareUrl(client, url),
        .uri => |uri| try prepare(client, uri),
    }
    return client.fetch(options);
}

fn prepareFrom(client: *std.http.Client, uri: std.Uri, sources: Sources) Error!void {
    if (std.http.Client.Protocol.fromUri(uri) != .tls) return;
    const io = client.io;
    {
        try client.ca_bundle_lock.lockShared(io);
        defer client.ca_bundle_lock.unlockShared(io);
        if (client.now != null) return;
    }
    var bundle: Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = std.Io.Clock.real.now(io);
    try loadFrom(&bundle, client.allocator, io, now, sources);
    try client.ca_bundle_lock.lock(io);
    defer client.ca_bundle_lock.unlock(io);
    // Another request loaded them first.
    if (client.now != null) return;
    // The clock and the roots go in together, so no TLS setup sees a clock
    // without roots (`TlsRoots.tla` HandshakeHasRoots).
    client.now = now;
    std.mem.swap(Bundle, &client.ca_bundle, &bundle);
}

const testing = std.testing;
const io_mod = @import("io.zig");

// Two public test roots, valid until 2046, with no keys kept.
const test_root_a =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBiDCCAS2gAwIBAgIUVcAgC6ip6Sly1UqimAVijJd9zIIwCgYIKoZIzj0EAwIw
    \\GTEXMBUGA1UEAwwOZnggdGVzdCByb290IGEwHhcNMjYxMTA3MDUzMDI5WhcNNDYx
    \\MTAyMDUzMDI5WjAZMRcwFQYDVQQDDA5meCB0ZXN0IHJvb3QgYTBZMBMGByqGSM49
    \\AgEGCCqGSM49AwEHA0IABHKvFnNrSTHDR/3+Tdk1tUMPd43eG7CyrDtpocPY1bA1
    \\qM8w6wB1qa3AuwEQiEuf6RMk+hjoSbC8k3XPiH8QYj6jUzBRMB0GA1UdDgQWBBTA
    \\71/p75oaAMux2FI1Jv61lzpTrTAfBgNVHSMEGDAWgBTA71/p75oaAMux2FI1Jv61
    \\lzpTrTAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQDuGsow2pRt
    \\/PLax4UXu8vfom/oEF1XByKRKaEeOJbt8AIhAOoqZEzjAoll/7KlT0qlx4QTayFL
    \\cAPDwExldF6KlYhN
    \\-----END CERTIFICATE-----
    \\
;
const test_root_b =
    \\-----BEGIN CERTIFICATE-----
    \\MIIBiDCCAS2gAwIBAgIUYmtecNZor+H0ETDm5VmpaAB+tsUwCgYIKoZIzj0EAwIw
    \\GTEXMBUGA1UEAwwOZnggdGVzdCByb290IGIwHhcNMjYxMTA3MDUzMDI5WhcNNDYx
    \\MTAyMDUzMDI5WjAZMRcwFQYDVQQDDA5meCB0ZXN0IHJvb3QgYjBZMBMGByqGSM49
    \\AgEGCCqGSM49AwEHA0IABBmm1dqMoWMdbUK/fASnwBXZ8UcbDvfKhltKfP7VX4cS
    \\79WcNu7WJXWaHXIQ6UNWJN8xfYfMPCHNxM8zkT+q8dCjUzBRMB0GA1UdDgQWBBTr
    \\LQE8ppqj4KbSZ0aW5Dz+sSNKjzAfBgNVHSMEGDAWgBTrLQE8ppqj4KbSZ0aW5Dz+
    \\sSNKjzAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQChEJAFirmA
    \\BPLbadNIp79o9hKtX0fpSKjvxNvDGNLPSgIhAL4ob0dmXXEjTle+V+FssPXeiEmr
    \\z6dD6whdV8GctGVw
    \\-----END CERTIFICATE-----
    \\
;

/// Test scans. A scan that reads part of the system roots adds both test
/// roots from `scanned_path` before it stops.
const FakeScan = struct {
    var scanned_path: []const u8 = "";
    var calls: std.atomic.Value(u32) = .init(0);

    fn reads(bundle: *Bundle, gpa: Allocator, io: std.Io, now: std.Io.Timestamp) Bundle.RescanError!void {
        _ = calls.fetchAdd(1, .acq_rel);
        bundle.addCertsFromFilePathAbsolute(gpa, io, now, scanned_path) catch return error.EndOfStream;
    }

    fn deniedAfterPart(bundle: *Bundle, gpa: Allocator, io: std.Io, now: std.Io.Timestamp) Bundle.RescanError!void {
        try reads(bundle, gpa, io, now);
        return error.PermissionDenied;
    }

    fn accessDenied(_: *Bundle, _: Allocator, _: std.Io, _: std.Io.Timestamp) Bundle.RescanError!void {
        _ = calls.fetchAdd(1, .acq_rel);
        return error.AccessDenied;
    }

    fn brokenAfterPart(bundle: *Bundle, gpa: Allocator, io: std.Io, now: std.Io.Timestamp) Bundle.RescanError!void {
        try reads(bundle, gpa, io, now);
        return error.EndOfStream;
    }

    fn canceled(_: *Bundle, _: Allocator, _: std.Io, _: std.Io.Timestamp) Bundle.RescanError!void {
        return error.Canceled;
    }

    /// Takes a while, so concurrent requests race the install.
    fn slowReads(bundle: *Bundle, gpa: Allocator, io: std.Io, now: std.Io.Timestamp) Bundle.RescanError!void {
        io.sleep(.fromMilliseconds(2), .awake) catch {};
        try reads(bundle, gpa, io, now);
    }
};

/// A folder with the test bundles, by absolute path.
const Files = struct {
    tmp: testing.TmpDir,
    both: []u8,
    only_a: []u8,

    fn init() !Files {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const io = testing.io;
        try tmp.dir.writeFile(io, .{ .sub_path = "both.pem", .data = test_root_a ++ test_root_b });
        try tmp.dir.writeFile(io, .{ .sub_path = "only-a.pem", .data = test_root_a });
        const both = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, "both.pem");
        errdefer testing.allocator.free(both);
        const only_a = try io_mod.dirRealpathAlloc(testing.allocator, tmp.dir, "only-a.pem");
        FakeScan.scanned_path = both;
        FakeScan.calls.store(0, .release);
        return .{ .tmp = tmp, .both = both, .only_a = only_a };
    }

    /// Writes `data` as `name` and returns its absolute path.
    fn add(self: *Files, name: []const u8, data: []const u8) ![]u8 {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = data });
        return io_mod.dirRealpathAlloc(testing.allocator, self.tmp.dir, name);
    }

    fn deinit(self: *Files) void {
        testing.allocator.free(self.both);
        testing.allocator.free(self.only_a);
        self.tmp.cleanup();
    }
};

fn testLoad(bundle: *Bundle, sources: Sources) Error!void {
    return loadFrom(bundle, testing.allocator, testing.io, std.Io.Clock.real.now(testing.io), sources);
}

test "only a permission error on macOS falls back to the public bundle" {
    try testing.expectEqual(AfterScanError.fallback, afterScanError(.macos, error.PermissionDenied));
    try testing.expectEqual(AfterScanError.fallback, afterScanError(.macos, error.AccessDenied));
    for ([_]Bundle.RescanError{ error.FileNotFound, error.EndOfStream, error.FileTooBig, error.OutOfMemory, error.IsDir, error.CertificateFieldHasInvalidLength }) |err| {
        try testing.expectEqual(AfterScanError.fail, afterScanError(.macos, err));
    }
    for ([_]std.Target.Os.Tag{ .linux, .freebsd, .windows }) |os| {
        try testing.expectEqual(AfterScanError.fail, afterScanError(os, error.PermissionDenied));
        try testing.expectEqual(AfterScanError.fail, afterScanError(os, error.AccessDenied));
        try testing.expectEqual(AfterScanError.cancel, afterScanError(os, error.Canceled));
    }
    try testing.expectEqual(AfterScanError.cancel, afterScanError(.macos, error.Canceled));
}

test "a denied scan drops what it read and loads only the public bundle" {
    var files = try Files.init();
    defer files.deinit();
    var bundle: Bundle = .empty;
    defer bundle.deinit(testing.allocator);
    try testLoad(&bundle, .{ .os = .macos, .scan = &FakeScan.deniedAfterPart, .fallback_path = files.only_a });
    // The scan read both roots; the public bundle holds one.
    try testing.expectEqual(@as(u32, 1), bundle.map.count());

    var denied: Bundle = .empty;
    defer denied.deinit(testing.allocator);
    try testLoad(&denied, .{ .os = .macos, .scan = &FakeScan.accessDenied, .fallback_path = files.both });
    try testing.expectEqual(@as(u32, 2), denied.map.count());
}

test "a scan that reads loads the system roots and never the public bundle" {
    var files = try Files.init();
    defer files.deinit();
    var bundle: Bundle = .empty;
    defer bundle.deinit(testing.allocator);
    try testLoad(&bundle, .{ .os = .macos, .scan = &FakeScan.reads, .fallback_path = "/nonexistent/fx-test/cert.pem" });
    try testing.expectEqual(@as(u32, 2), bundle.map.count());
}

test "the fallback fails closed on a public bundle it can't use" {
    var files = try Files.init();
    defer files.deinit();
    const cases = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "empty.pem", .data = "" },
        .{ .name = "text.pem", .data = "no certificates here\n" },
        .{ .name = "unterminated.pem", .data = "-----BEGIN CERTIFICATE-----\nMIIB\n" },
        .{ .name = "garbage.pem", .data = "-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n" },
    };
    for (cases) |case| {
        const path = try files.add(case.name, case.data);
        defer testing.allocator.free(path);
        var bundle: Bundle = .empty;
        defer bundle.deinit(testing.allocator);
        try testing.expectError(error.CertificateBundleLoadFailure, testLoad(&bundle, .{ .os = .macos, .scan = &FakeScan.deniedAfterPart, .fallback_path = path }));
        try testing.expectEqual(@as(u32, 0), bundle.map.count());
        try testing.expectEqual(@as(usize, 0), bundle.bytes.items.len);
    }
    var missing: Bundle = .empty;
    defer missing.deinit(testing.allocator);
    try testing.expectError(error.CertificateBundleLoadFailure, testLoad(&missing, .{ .os = .macos, .scan = &FakeScan.accessDenied, .fallback_path = "/nonexistent/fx-test/cert.pem" }));
    try testing.expectEqual(@as(u32, 0), missing.map.count());
}

test "other scan errors, other systems, and cancellation never fall back" {
    var files = try Files.init();
    defer files.deinit();
    var broken: Bundle = .empty;
    defer broken.deinit(testing.allocator);
    try testing.expectError(error.CertificateBundleLoadFailure, testLoad(&broken, .{ .os = .macos, .scan = &FakeScan.brokenAfterPart, .fallback_path = files.both }));
    try testing.expectEqual(@as(u32, 0), broken.map.count());

    var linux: Bundle = .empty;
    defer linux.deinit(testing.allocator);
    try testing.expectError(error.CertificateBundleLoadFailure, testLoad(&linux, .{ .os = .linux, .scan = &FakeScan.deniedAfterPart, .fallback_path = files.both }));
    try testing.expectEqual(@as(u32, 0), linux.map.count());

    var canceled: Bundle = .empty;
    defer canceled.deinit(testing.allocator);
    try testing.expectError(error.Canceled, testLoad(&canceled, .{ .os = .macos, .scan = &FakeScan.canceled, .fallback_path = files.both }));
    try testing.expectEqual(@as(u32, 0), canceled.map.count());
}

/// A test Io that fails every file open, and counts the opens.
const NoFilesIo = struct {
    var vtable: std.Io.VTable = undefined;
    var opens: std.atomic.Value(u32) = .init(0);

    fn io() std.Io {
        vtable = testing.io.vtable.*;
        vtable.dirOpenFile = open;
        opens.store(0, .release);
        return .{ .userdata = testing.io.userdata, .vtable = &vtable };
    }

    fn open(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
        _ = opens.fetchAdd(1, .acq_rel);
        return error.AccessDenied;
    }
};

test "plain HTTP reads no roots" {
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = NoFilesIo.io() };
    defer client.deinit();
    try prepare(&client, try std.Uri.parse("http://127.0.0.1:1/v1"));
    try prepareUrl(&client, "http://127.0.0.1:1/v1");
    try prepareUrl(&client, "not a url");
    try testing.expectEqual(@as(?std.Io.Timestamp, null), client.now);
    try testing.expectEqual(@as(u32, 0), client.ca_bundle.map.count());
    try testing.expectEqual(@as(u32, 0), NoFilesIo.opens.load(.acquire));
}

test "a client loads its roots once and keeps them" {
    var files = try Files.init();
    defer files.deinit();
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    const uri = try std.Uri.parse("https://127.0.0.1:1/v1");
    const sources: Sources = .{ .os = .macos, .scan = &FakeScan.accessDenied, .fallback_path = files.both };
    try prepareFrom(&client, uri, sources);
    const clock = client.now orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 2), client.ca_bundle.map.count());
    try prepareFrom(&client, uri, sources);
    try testing.expectEqual(clock, client.now.?);
    try testing.expectEqual(@as(u32, 1), FakeScan.calls.load(.acquire));
}

test "a failed load leaves the client unloaded for the next request" {
    var files = try Files.init();
    defer files.deinit();
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    const uri = try std.Uri.parse("https://127.0.0.1:1/v1");
    try testing.expectError(error.CertificateBundleLoadFailure, prepareFrom(&client, uri, .{ .os = .macos, .scan = &FakeScan.accessDenied, .fallback_path = "/nonexistent/fx-test/cert.pem" }));
    try testing.expectEqual(@as(?std.Io.Timestamp, null), client.now);
    try testing.expectEqual(@as(u32, 0), client.ca_bundle.map.count());
    try prepareFrom(&client, uri, .{ .os = .macos, .scan = &FakeScan.accessDenied, .fallback_path = files.both });
    try testing.expect(client.now != null);
}

test "requests racing on one client install one bundle with its clock" {
    var files = try Files.init();
    defer files.deinit();
    const rounds = 20;
    const threads = 16;
    for (0..rounds) |_| {
        var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
        defer client.deinit();
        const Racer = struct {
            fn run(c: *std.http.Client, failures: *std.atomic.Value(u32)) void {
                const uri = std.Uri.parse("https://127.0.0.1:1/v1") catch unreachable;
                prepareFrom(c, uri, .{ .os = .macos, .scan = &FakeScan.slowReads, .fallback_path = "/nonexistent/fx-test/cert.pem" }) catch {
                    _ = failures.fetchAdd(1, .acq_rel);
                    return;
                };
                // Whoever returns sees the clock and the roots together.
                c.ca_bundle_lock.lockSharedUncancelable(c.io);
                defer c.ca_bundle_lock.unlockShared(c.io);
                if (c.now == null or c.ca_bundle.map.count() != 2) _ = failures.fetchAdd(1, .acq_rel);
            }
        };
        var failures: std.atomic.Value(u32) = .init(0);
        var pool: [threads]std.Thread = undefined;
        for (&pool) |*thread| thread.* = try std.Thread.spawn(.{}, Racer.run, .{ &client, &failures });
        for (pool) |thread| thread.join();
        try testing.expectEqual(@as(u32, 0), failures.load(.acquire));
        try testing.expectEqual(@as(u32, 2), client.ca_bundle.map.count());
    }
}

const FuzzBundle = struct {
    files: *Files,
};

/// What a fuzzed public bundle is built from. A block holds a whole test root
/// or starts with bytes base64 rejects, and is never empty: std's DER parser
/// reads past the end of an empty or cut certificate (std/crypto/Certificate.zig
/// `der.Element.parse`), so arbitrary base64 would test std, not this loader.
const fuzz_pieces = [_][]const u8{
    test_root_a,
    test_root_b,
    // Opens a block whose content base64 rejects.
    "-----BEGIN CERTIFICATE-----\n!!",
    "-----END CERTIFICATE-----\n",
    "-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n",
    "# not a certificate\n",
    "\n",
    "\x00\xff\xfe",
};

fn fuzzPublicBundle(context: FuzzBundle, smith: *testing.Smith) anyerror!void {
    var picks: [32]u8 = undefined;
    const count: usize = @intCast(smith.slice(&picks));
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    var has: [fuzz_pieces.len]bool = @splat(false);
    for (picks[0..count]) |pick| {
        const piece = pick % fuzz_pieces.len;
        has[piece] = true;
        try text.appendSlice(testing.allocator, fuzz_pieces[piece]);
    }
    const path = try context.files.add("fuzzed.pem", text.items);
    defer testing.allocator.free(path);
    var bundle: Bundle = .empty;
    defer bundle.deinit(testing.allocator);
    const result = testLoad(&bundle, .{ .os = .macos, .scan = &FakeScan.deniedAfterPart, .fallback_path = path });
    // A broken block fails the whole file; otherwise the roots it holds load,
    // and a file with none fails closed.
    const roots = @as(u32, @intFromBool(has[0])) + @intFromBool(has[1]);
    if (has[2] or has[4] or roots == 0) {
        try testing.expectError(error.CertificateBundleLoadFailure, result);
        try testing.expectEqual(@as(u32, 0), bundle.map.count());
    } else {
        try result;
        try testing.expectEqual(roots, bundle.map.count());
    }
}

test "the trust loader fails closed or loads roots on fuzzed public bundle bytes" {
    var files = try Files.init();
    defer files.deinit();
    try testing.fuzz(FuzzBundle{ .files = &files }, fuzzPublicBundle, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "\x00",
            "\x00\x01\x00",
            "",
            "\x02",
            "\x02\x03\x00",
            "\x04\x01",
            "\x05\x06\x07\x01\x03",
        }) ++ @import("fuzz_corpus").tls_roots_public_bundle.*),
    });
}
