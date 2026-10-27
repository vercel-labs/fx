//! Release updates: the latest GitHub release of a configured repository
//! (D141). The asset for this platform is `proto-fx-<platform>`; its sha256
//! comes from the release API's `digest` field or a `<asset>.sha256` asset,
//! and a download that does not match it is never installed.
const std = @import("std");
const io_mod = @import("../shared/io.zig");
const helpers = @import("upgrade_helpers.zig");
const update_target = @import("update_target.zig");
const source_update = @import("source_update.zig");

const Allocator = std.mem.Allocator;

const max_release_bytes: usize = 1 << 20;
const max_checksum_bytes: usize = 4096;

pub const Asset = struct {
    name: []const u8,
    browser_download_url: []const u8,
    digest: ?[]const u8 = null,
};

pub const Release = struct {
    tag_name: []const u8,
    assets: []const Asset = &.{},
};

/// Where releases come from. `api_base` is `https://api.github.com` except
/// in tests, which serve the same paths from a loopback server.
pub const Feed = struct {
    api_base: []const u8,
    repo: []const u8,
    token: ?[]const u8 = null,
    platform: []const u8 = helpers.platform,
};

pub const Error = error{
    NoRepository,
    ReleaseFetchFailed,
    NoAssetForPlatform,
    NoChecksum,
    DownloadFailed,
    ChecksumMismatch,
};

pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NoRepository => "no release repository is configured; set update.repo in ~/.proto-fx/settings.json",
        error.ReleaseFetchFailed => "the latest release could not be fetched",
        error.NoAssetForPlatform => "the latest release has no binary for this platform",
        error.NoChecksum => "the release binary has no sha256 checksum, so it was not installed",
        error.DownloadFailed => "the release binary could not be downloaded",
        error.ChecksumMismatch => "the downloaded binary did not match its sha256 checksum, so it was not installed",
        else => @errorName(err),
    };
}

/// The latest release. The caller deinits the result.
pub fn fetchLatest(alloc: Allocator, client: *std.http.Client, feed: Feed) !std.json.Parsed(Release) {
    if (feed.repo.len == 0) return error.NoRepository;
    const url = try alloc.print("{s}/repos/{s}/releases/latest", .{ std.mem.trimEnd(u8, feed.api_base, "/"), feed.repo });
    defer alloc.free(url);
    const body = fetchBounded(alloc, client, url, feed.token, max_release_bytes) catch return error.ReleaseFetchFailed;
    defer alloc.free(body);
    return std.json.parseFromSlice(Release, alloc, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch error.ReleaseFetchFailed;
}

/// The release's version without a leading `v`.
pub fn version(release: Release) []const u8 {
    return update_target.normalizeVersion(release.tag_name);
}

pub fn isNewer(release: Release, current_version: []const u8) bool {
    return update_target.compareVersions(version(release), current_version) == .gt;
}

pub fn findAsset(release: Release, name: []const u8) ?Asset {
    for (release.assets) |asset| if (std.mem.eql(u8, asset.name, name)) return asset;
    return null;
}

/// Downloads this platform's binary next to `target`, verifies its sha256,
/// and renames it over `target`.
pub fn install(alloc: Allocator, client: *std.http.Client, feed: Feed, release: Release, target: []const u8) !void {
    const name = try alloc.print("{s}-{s}", .{ source_update.binary_name, feed.platform });
    defer alloc.free(name);
    const asset = findAsset(release, name) orelse return error.NoAssetForPlatform;
    var expected: [64]u8 = undefined;
    try expectedDigest(alloc, client, feed, release, asset, &expected);

    const zio = io_mod.getIo();
    const dir = std.Io.Dir.path.dirname(target) orelse return error.DownloadFailed;
    const temp = try alloc.print("{s}/.{s}.download-{d}", .{ dir, std.Io.Dir.path.basename(target), io_mod.nanoTimestamp() });
    defer alloc.free(temp);
    defer std.Io.Dir.deleteFileAbsolute(zio, temp) catch {};
    helpers.downloadFileStreaming(client, asset.browser_download_url, temp, .{}) catch return error.DownloadFailed;
    const actual = try sha256File(temp);
    if (!std.ascii.eqlIgnoreCase(&actual, &expected)) return error.ChecksumMismatch;
    if (!try source_update.installAtomic(alloc, temp, target)) return error.InstallFailed;
}

fn expectedDigest(alloc: Allocator, client: *std.http.Client, feed: Feed, release: Release, asset: Asset, out: *[64]u8) !void {
    if (asset.digest) |digest| {
        if (std.mem.startsWith(u8, digest, "sha256:")) return copyHex(digest["sha256:".len..], out);
    }
    const checksum_name = try alloc.print("{s}.sha256", .{asset.name});
    defer alloc.free(checksum_name);
    const checksum = findAsset(release, checksum_name) orelse return error.NoChecksum;
    const body = fetchBounded(alloc, client, checksum.browser_download_url, feed.token, max_checksum_bytes) catch return error.NoChecksum;
    defer alloc.free(body);
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    return copyHex(trimmed[0 .. std.mem.findAny(u8, trimmed, " \t\n") orelse trimmed.len], out);
}

fn copyHex(hex: []const u8, out: *[64]u8) !void {
    if (hex.len != 64) return error.NoChecksum;
    for (hex) |byte| if (!std.ascii.isHex(byte)) return error.NoChecksum;
    @memcpy(out, hex);
}

fn sha256File(path: []const u8) ![64]u8 {
    const zio = io_mod.getIo();
    var file = std.Io.Dir.openFileAbsolute(zio, path, .{}) catch return error.DownloadFailed;
    defer file.close(zio);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var read_buf: [8192]u8 = undefined;
    var reader = file.readerStreaming(zio, &read_buf);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&chunk) catch return error.DownloadFailed;
        if (n == 0) break;
        hasher.update(chunk[0..n]);
    }
    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

fn fetchBounded(alloc: Allocator, client: *std.http.Client, url: []const u8, token: ?[]const u8, max_bytes: usize) ![]u8 {
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    var auth_buf: [512]u8 = undefined;
    var privileged: [1]std.http.Header = undefined;
    var privileged_len: usize = 0;
    if (token) |value| {
        privileged[0] = .{ .name = "authorization", .value = try std.mem.print(&auth_buf, "Bearer {s}", .{value}) };
        privileged_len = 1;
    }
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .headers = .{ .user_agent = .{ .override = "proto-fx-update" } },
        .extra_headers = &.{.{ .name = "accept", .value = "application/vnd.github+json" }},
        .privileged_headers = privileged[0..privileged_len],
    });
    if (result.status != .ok) return error.FetchFailed;
    if (body.written().len > max_bytes) return error.FetchFailed;
    return body.toOwnedSlice();
}

test "release assets resolve the platform binary and its digest" {
    const json =
        \\{"tag_name":"v0.4.0","assets":[
        \\{"name":"proto-fx-darwin-arm64","browser_download_url":"http://127.0.0.1/a","digest":"sha256:aa"},
        \\{"name":"proto-fx-darwin-arm64.sha256","browser_download_url":"http://127.0.0.1/b"}]}
    ;
    var parsed = try std.json.parseFromSlice(Release, std.testing.allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("0.4.0", version(parsed.value));
    try std.testing.expect(isNewer(parsed.value, "0.3.9"));
    try std.testing.expect(!isNewer(parsed.value, "0.4.0"));
    try std.testing.expectEqualStrings("http://127.0.0.1/a", findAsset(parsed.value, "proto-fx-darwin-arm64").?.browser_download_url);
    try std.testing.expect(findAsset(parsed.value, "proto-fx-linux-x64") == null);
    var out: [64]u8 = undefined;
    try std.testing.expectError(error.NoChecksum, copyHex("aa", &out));
}

/// Serves a release, its binary and a checksum from loopback, as GitHub would.
const FakeReleaseServer = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    release_json: []const u8 = "",
    binary: []const u8 = "",
    checksum: []const u8 = "",

    fn init(self: *FakeReleaseServer) !void {
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.server = try address.listen(self.io_backend.io(), .{ .reuse_address = true });
    }

    fn port(self: *FakeReleaseServer) u16 {
        return self.server.socket.address.getPort();
    }

    fn start(self: *FakeReleaseServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn stop(self: *FakeReleaseServer) void {
        self.stopping.store(true, .seq_cst);
        var wake_backend: std.Io.Threaded = .init_single_threaded;
        const address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
        if (address.connect(wake_backend.io(), .{ .mode = .stream })) |stream| stream.close(wake_backend.io()) else |_| {}
        if (self.thread) |thread| thread.join();
        self.server.deinit(self.io_backend.io());
    }

    fn run(self: *FakeReleaseServer) void {
        const zio = self.io_backend.io();
        while (!self.stopping.load(.seq_cst)) {
            var stream = self.server.accept(zio) catch return;
            defer stream.close(zio);
            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var reader = stream.reader(zio, &read_buf);
            var writer = stream.writer(zio, &write_buf);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            while (!self.stopping.load(.seq_cst)) {
                var request = http.receiveHead() catch break;
                const target = request.head.target;
                const body: ?[]const u8 = if (std.mem.endsWith(u8, target, "/releases/latest"))
                    self.release_json
                else if (std.mem.endsWith(u8, target, ".sha256"))
                    self.checksum
                else if (std.mem.startsWith(u8, target, "/download/"))
                    self.binary
                else
                    null;
                request.respond(body orelse "", .{ .status = if (body == null) .not_found else .ok }) catch break;
            }
        }
    }
};

test "release install verifies sha256 from a loopback release feed" {
    const alloc = std.testing.allocator;
    const zio = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(zio, .{ .sub_path = "proto-fx", .data = "old binary" });
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const target = try std.Io.Dir.path.join(alloc, &.{ root, "proto-fx" });
    defer alloc.free(target);

    var server: FakeReleaseServer = .{ .server = undefined };
    try server.init();
    const binary = "new release binary";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(binary, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const json = try alloc.print(
        \\{{"tag_name":"v9.0.0","assets":[{{"name":"proto-fx-test-os","browser_download_url":"http://127.0.0.1:{d}/download/proto-fx-test-os"}},{{"name":"proto-fx-test-os.sha256","browser_download_url":"http://127.0.0.1:{d}/download/proto-fx-test-os.sha256"}}]}}
    , .{ server.port(), server.port() });
    defer alloc.free(json);
    const checksum = try alloc.print("{s}  proto-fx-test-os\n", .{hex});
    defer alloc.free(checksum);
    server.release_json = json;
    server.binary = binary;
    server.checksum = "0000000000000000000000000000000000000000000000000000000000000000\n";
    try server.start();
    defer server.stop();

    var client: std.http.Client = .{ .allocator = alloc, .io = zio };
    defer client.deinit();
    const api_base = try alloc.print("http://127.0.0.1:{d}", .{server.port()});
    defer alloc.free(api_base);
    const feed: Feed = .{ .api_base = api_base, .repo = "example/proto-fx", .platform = "test-os" };
    var release = try fetchLatest(alloc, &client, feed);
    defer release.deinit();
    try std.testing.expect(isNewer(release.value, "0.3.0"));

    // A checksum that does not match leaves the installed binary alone.
    try std.testing.expectError(error.ChecksumMismatch, install(alloc, &client, feed, release.value, target));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("old binary", try tmp.dir.readFile(zio, "proto-fx", &buf));

    server.checksum = checksum;
    try install(alloc, &client, feed, release.value, target);
    try std.testing.expectEqualStrings(binary, try tmp.dir.readFile(zio, "proto-fx", &buf));
    try std.testing.expectError(error.NoRepository, fetchLatest(alloc, &client, .{ .api_base = api_base, .repo = "" }));
}
