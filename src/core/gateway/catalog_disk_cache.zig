//! Shared disk cache for provider model catalogs.
//!
//! Each provider stores the raw catalog response body (or a provider-defined
//! combination of bodies) in one versioned JSON envelope per partition under
//! the profile cache directory. The cache is strictly best effort: every read
//! or decode failure is a miss and the provider falls back to its network
//! fetch. Providers own three things this module cannot decide for them:
//!
//! - the partition material (which identity a catalog may be shared across);
//! - validation of a loaded body, using the same rules as endpoint responses;
//! - whether caching is enabled at all (e2e endpoint overrides disable it).

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");

const cache_schema_version: u32 = 1;
const envelope_overhead_bytes: usize = 4096;

pub const default_ttl_ms: i64 = 6 * std.time.ms_per_hour;

pub const Config = struct {
    /// Cache file prefix, e.g. "codex-models".
    file_prefix: []const u8,
    /// Provider format version; a mismatch invalidates the entry. Providers
    /// with a protocol version use it, others use the fx build version.
    version: []const u8,
    ttl_ms: i64 = default_ttl_ms,
    max_body_bytes: usize,
};

const Envelope = struct {
    schema_version: u32,
    provider_version: []const u8,
    fetched_at_ms: i64,
    body: []const u8,
};

/// Builds the cache file path for one partition. The partition material is
/// hashed so identities never appear in file names and any byte sequence is
/// path safe. Fails when no usable HOME is available.
pub fn cachePath(alloc: std.mem.Allocator, config: Config, partition: []const u8) ![]u8 {
    const home = io_mod.getenv("HOME") orelse return error.CatalogCacheUnavailable;
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.CatalogCacheUnavailable;
    const cache_dir = try profile_paths.cacheDir(alloc, home);
    defer alloc.free(cache_dir);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(partition, &digest, .{});
    const partition_hash = std.fmt.bytesToHex(digest[0..8].*, .lower);
    const file_name = try std.fmt.allocPrint(
        alloc,
        "{s}-{s}.json",
        .{ config.file_prefix, partition_hash },
    );
    defer alloc.free(file_name);
    return std.fs.path.join(alloc, &.{ cache_dir, file_name });
}

/// Best-effort read of a cached body. Any failure — missing file, oversized
/// file, malformed envelope, schema or provider-version mismatch, stale or
/// future timestamp — is a miss, never an error.
pub fn loadFresh(alloc: std.mem.Allocator, config: Config, path: []const u8, now_ms: i64) ?[]u8 {
    var file = io_mod.openExistingReadOnlyRegularFile(
        std.Io.Dir.cwd(),
        path,
        .no_follow,
    ) catch return null;
    defer file.close(io_mod.getIo());
    const data = io_mod.readFileToEnd(
        alloc,
        &file,
        config.max_body_bytes + envelope_overhead_bytes,
    ) catch return null;
    defer secret.zeroAndFree(alloc, data);
    var parsed = std.json.parseFromSlice(Envelope, alloc, data, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const envelope = parsed.value;
    if (envelope.schema_version != cache_schema_version) return null;
    if (!std.mem.eql(u8, envelope.provider_version, config.version)) return null;
    if (envelope.fetched_at_ms > now_ms) return null;
    if (now_ms - envelope.fetched_at_ms >= config.ttl_ms) return null;
    if (envelope.body.len == 0 or envelope.body.len > config.max_body_bytes) return null;
    return alloc.dupe(u8, envelope.body) catch null;
}

pub fn store(
    alloc: std.mem.Allocator,
    config: Config,
    path: []const u8,
    body: []const u8,
    fetched_at_ms: i64,
) !void {
    if (body.len == 0 or body.len > config.max_body_bytes) return error.CatalogCacheBodyTooLarge;
    const parent = std.fs.path.dirname(path) orelse return error.CatalogCacheUnavailable;
    try io_mod.makeDirRecursive(parent);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(Envelope{
        .schema_version = cache_schema_version,
        .provider_version = config.version,
        .fetched_at_ms = fetched_at_ms,
        .body = body,
    }, .{}, &out.writer);
    try io_mod.writeFileAtomic(alloc, path, out.written());
}

const test_config = Config{
    .file_prefix = "test-models",
    .version = "9.9.9",
    .max_body_bytes = 1024,
};

fn testCachePath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    return std.fs.path.join(alloc, &.{ root, "cache", "test-models-entry.json" });
}

test "catalog disk cache round-trips a fresh body" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testCachePath(alloc, &tmp);
    defer alloc.free(path);

    const stored_at_ms: i64 = 1_000_000;
    try store(alloc, test_config, path, "{\"models\":[]}", stored_at_ms);
    const loaded = loadFresh(alloc, test_config, path, stored_at_ms + 1) orelse
        return error.TestExpectedCacheHit;
    defer alloc.free(loaded);
    try std.testing.expectEqualStrings("{\"models\":[]}", loaded);
}

test "catalog disk cache misses on stale, future, or rewritten entries" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testCachePath(alloc, &tmp);
    defer alloc.free(path);

    const stored_at_ms: i64 = 1_000_000;
    try store(alloc, test_config, path, "{}", stored_at_ms);

    // Exactly at the TTL boundary and beyond: stale.
    try std.testing.expectEqual(
        @as(?[]u8, null),
        loadFresh(alloc, test_config, path, stored_at_ms + test_config.ttl_ms),
    );
    // A fetch timestamp in the future is rejected, not trusted.
    try std.testing.expectEqual(
        @as(?[]u8, null),
        loadFresh(alloc, test_config, path, stored_at_ms - 1),
    );
    // A different provider version invalidates the entry.
    var other_version = test_config;
    other_version.version = "0.0.1";
    try std.testing.expectEqual(
        @as(?[]u8, null),
        loadFresh(alloc, other_version, path, stored_at_ms + 1),
    );
    // A schema-version bump invalidates the entry.
    const wrong_schema = try std.fmt.allocPrint(
        alloc,
        "{{\"schema_version\":{d},\"provider_version\":\"{s}\",\"fetched_at_ms\":{d},\"body\":\"{{}}\"}}",
        .{ cache_schema_version + 1, test_config.version, stored_at_ms },
    );
    defer alloc.free(wrong_schema);
    try io_mod.writeFileAtomic(alloc, path, wrong_schema);
    try std.testing.expectEqual(
        @as(?[]u8, null),
        loadFresh(alloc, test_config, path, stored_at_ms + 1),
    );
    // Malformed JSON is a miss, not an error.
    try io_mod.writeFileAtomic(alloc, path, "not json");
    try std.testing.expectEqual(
        @as(?[]u8, null),
        loadFresh(alloc, test_config, path, stored_at_ms + 1),
    );
    // A missing file is a miss.
    const missing = try std.fs.path.join(alloc, &.{ std.fs.path.dirname(path).?, "absent.json" });
    defer alloc.free(missing);
    try std.testing.expectEqual(
        @as(?[]u8, null),
        loadFresh(alloc, test_config, missing, stored_at_ms + 1),
    );
}

test "catalog disk cache store rejects empty and oversized bodies" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testCachePath(alloc, &tmp);
    defer alloc.free(path);

    try std.testing.expectError(
        error.CatalogCacheBodyTooLarge,
        store(alloc, test_config, path, "", 0),
    );
    const oversized = try alloc.alloc(u8, test_config.max_body_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, 'a');
    try std.testing.expectError(
        error.CatalogCacheBodyTooLarge,
        store(alloc, test_config, path, oversized, 0),
    );
}

test "catalog disk cache partitions map to distinct stable file names" {
    // cachePath needs HOME from the process environ, which unit tests do not
    // provide, so exercise the partition hashing directly.
    var digest_a: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    var digest_b: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("account-a", &digest_a, .{});
    std.crypto.hash.sha2.Sha256.hash("account-b", &digest_b, .{});
    try std.testing.expect(!std.mem.eql(u8, digest_a[0..8], digest_b[0..8]));
}
