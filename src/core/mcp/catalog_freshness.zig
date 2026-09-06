const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Digest = [Sha256.digest_length]u8;

pub const CacheScope = enum {
    private,
    public,
};

pub const AuthPartition = struct {
    private_auth_identity: ?Digest,

    pub fn eql(left: AuthPartition, right: AuthPartition) bool {
        return optionalDigestEql(left.private_auth_identity, right.private_auth_identity);
    }
};

pub fn authPartition(scope: CacheScope, identity: Digest) AuthPartition {
    return .{ .private_auth_identity = if (scope == .private) identity else null };
}

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Produces an opaque partition identity without retaining header names or
/// credential values. Header order is significant because it is part of the
/// effective request identity.
pub fn authIdentity(headers: []const Header) Digest {
    var hasher = Sha256.init(.{});
    for (headers) |header| {
        hashLengthPrefixed(&hasher, header.name);
        hashLengthPrefixed(&hasher, header.value);
    }
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

pub const Freshness = enum {
    fresh,
    stale,
    refreshing,
    failed_refresh,
};

pub const SubscriptionIdentity = struct {
    request_id: u64,
    generation: u64,
};

pub const SnapshotMetadata = struct {
    key: AuthPartition,
    connection_generation: u64,
    catalog_generation: u64,
    fetched_at_ms: u64,
    expires_at_ms: u64,
    scope: CacheScope,
    freshness: Freshness = .fresh,
    refresh_attempt: u8 = 0,
    retry_at_ms: u64 = 0,
    content_digest: Digest,
    subscription: ?SubscriptionIdentity = null,
};

fn expiryFromTtl(fetched_at_ms: u64, ttl_ms: u64) u64 {
    return fetched_at_ms +| ttl_ms;
}

pub fn pageExpiry(
    protocol: Protocol,
    received_at_ms: u64,
    ttl_present: bool,
    ttl_ms: u64,
) u64 {
    return expiryFromTtl(
        received_at_ms,
        snapshotTtl(protocol, ttl_present, ttl_ms),
    );
}

pub fn earliestExpiry(current: ?u64, page_expiry_ms: u64) u64 {
    return if (current) |expiry_ms|
        @min(expiry_ms, page_expiry_ms)
    else
        page_expiry_ms;
}

const RefreshDecision = struct {
    action: enum {
        hit,
        refresh,
        retry_later,
        already_refreshing,
    },
    may_serve_snapshot: bool,
};

pub fn decideRefresh(
    metadata: SnapshotMetadata,
    requested_key: AuthPartition,
    now_ms: u64,
    invalidated: bool,
) RefreshDecision {
    const same_partition = metadata.key.eql(requested_key);
    if (!same_partition) return .{
        .action = .refresh,
        .may_serve_snapshot = false,
    };
    if (metadata.freshness == .refreshing) return .{
        .action = .already_refreshing,
        .may_serve_snapshot = true,
    };
    if (metadata.freshness == .failed_refresh and now_ms < metadata.retry_at_ms) {
        return .{
            .action = .retry_later,
            .may_serve_snapshot = true,
        };
    }
    if (invalidated) return .{
        .action = .refresh,
        .may_serve_snapshot = true,
    };
    if (metadata.freshness == .fresh and now_ms < metadata.expires_at_ms) {
        return .{
            .action = .hit,
            .may_serve_snapshot = true,
        };
    }
    return .{
        .action = .refresh,
        .may_serve_snapshot = true,
    };
}

pub fn effectiveFreshness(
    metadata: SnapshotMetadata,
    now_ms: u64,
    invalidated: bool,
) Freshness {
    return switch (metadata.freshness) {
        .refreshing, .failed_refresh => metadata.freshness,
        .fresh, .stale => if (invalidated or now_ms >= metadata.expires_at_ms)
            .stale
        else
            .fresh,
    };
}

pub fn beginRefresh(metadata: SnapshotMetadata) SnapshotMetadata {
    var next = metadata;
    next.freshness = .refreshing;
    return next;
}

pub fn requestRefresh(metadata: SnapshotMetadata) SnapshotMetadata {
    var next = metadata;
    next.expires_at_ms = 0;
    next.retry_at_ms = 0;
    if (next.freshness != .refreshing) next.freshness = .stale;
    return next;
}

const retry_initial_ms: u64 = 100;
const retry_max_ms: u64 = 5_000;
const retry_max_attempt: u8 = 8;

pub fn retryDelayMs(attempt: u8) u64 {
    var delay = retry_initial_ms;
    var remaining = @min(attempt, retry_max_attempt);
    while (remaining > 0) : (remaining -= 1) {
        delay = @min(delay *| 2, retry_max_ms);
    }
    return delay;
}

pub fn failedRefresh(metadata: SnapshotMetadata, now_ms: u64) SnapshotMetadata {
    var next = metadata;
    next.freshness = .failed_refresh;
    next.refresh_attempt = @min(metadata.refresh_attempt +| 1, retry_max_attempt);
    next.retry_at_ms = now_ms +| retryDelayMs(metadata.refresh_attempt);
    return next;
}

const ReplacementDecision = enum {
    reject_stale_generation,
    reject_auth_partition,
    metadata_only,
    replace_snapshot,
};

pub fn authorizeReplacement(
    current: SnapshotMetadata,
    source_connection_generation: u64,
    source_catalog_generation: u64,
    active_key: AuthPartition,
    replacement_key: AuthPartition,
    replacement_content_digest: Digest,
) ReplacementDecision {
    if (current.connection_generation != source_connection_generation or
        current.catalog_generation != source_catalog_generation)
    {
        return .reject_stale_generation;
    }
    if (!active_key.eql(replacement_key)) return .reject_auth_partition;
    if (std.mem.eql(u8, &current.content_digest, &replacement_content_digest)) {
        return .metadata_only;
    }
    return .replace_snapshot;
}

pub const Protocol = enum {
    legacy,
    modern,
};

fn snapshotTtl(protocol: Protocol, ttl_present: bool, ttl_ms: u64) u64 {
    if (ttl_present) return ttl_ms;
    return switch (protocol) {
        .modern => 0,
        .legacy => std.math.maxInt(u64),
    };
}

pub fn digest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    Sha256.hash(bytes, &result, .{});
    return result;
}

fn optionalDigestEql(left: ?Digest, right: ?Digest) bool {
    if ((left == null) != (right == null)) return false;
    if (left) |value| return std.mem.eql(u8, &value, &right.?);
    return true;
}

fn hashLengthPrefixed(hasher: *Sha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .big);
    hasher.update(&length);
    hasher.update(bytes);
}

fn testMetadata(key: AuthPartition, generation: u64, content: []const u8) SnapshotMetadata {
    return .{
        .key = key,
        .connection_generation = 4,
        .catalog_generation = generation,
        .fetched_at_ms = 100,
        .expires_at_ms = 200,
        .scope = if (key.private_auth_identity == null) .public else .private,
        .content_digest = digest(content),
    };
}

test "failed refresh preserves the last valid snapshot" {
    const identity = authIdentity(&.{});
    const key = authPartition(.private, identity);
    const current = testMetadata(key, 9, "valid snapshot");
    const failed = failedRefresh(current, 250);
    try std.testing.expectEqual(Freshness.failed_refresh, failed.freshness);
    try std.testing.expectEqual(current.catalog_generation, failed.catalog_generation);
    try std.testing.expectEqualSlices(u8, &current.content_digest, &failed.content_digest);
    try std.testing.expect(failed.retry_at_ms > 250);
}

test "a stale generation cannot replace newer state" {
    const key = authPartition(.public, authIdentity(&.{}));
    const current = testMetadata(key, 12, "newer");
    try std.testing.expectEqual(
        ReplacementDecision.reject_stale_generation,
        authorizeReplacement(current, 4, 11, key, key, digest("older")),
    );
}

test "private cache state cannot cross authentication identities" {
    const first_identity = authIdentity(&.{.{ .name = "Authorization", .value = "first" }});
    const second_identity = authIdentity(&.{.{ .name = "Authorization", .value = "second" }});
    const first = authPartition(.private, first_identity);
    const second = authPartition(.private, second_identity);
    const decision = decideRefresh(testMetadata(first, 1, "private"), second, 101, false);
    try std.testing.expectEqual(.refresh, decision.action);
    try std.testing.expect(!decision.may_serve_snapshot);

    const public_first = authPartition(.public, first_identity);
    const public_second = authPartition(.public, second_identity);
    try std.testing.expect(public_first.eql(public_second));
    try std.testing.expectEqual(
        ReplacementDecision.reject_auth_partition,
        authorizeReplacement(
            testMetadata(first, 1, "private"),
            4,
            1,
            second,
            first,
            digest("replacement"),
        ),
    );
}

test "equivalent validated refreshes do not replace snapshot content" {
    const key = authPartition(.public, authIdentity(&.{}));
    const current = testMetadata(key, 2, "same schema");
    try std.testing.expectEqual(
        ReplacementDecision.metadata_only,
        authorizeReplacement(current, 4, 2, key, key, digest("same schema")),
    );
}

test "valid changed refresh authorizes one whole snapshot replacement" {
    const key = authPartition(.public, authIdentity(&.{}));
    const current = testMetadata(key, 2, "old complete snapshot");
    try std.testing.expectEqual(
        ReplacementDecision.replace_snapshot,
        authorizeReplacement(current, 4, 2, key, key, digest("new complete snapshot")),
    );
}

test "expiry and retry arithmetic saturate" {
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        expiryFromTtl(std.math.maxInt(u64) - 1, 10),
    );
    var metadata = testMetadata(authPartition(.public, authIdentity(&.{})), 1, "snapshot");
    metadata.refresh_attempt = retry_max_attempt;
    const failed = failedRefresh(metadata, std.math.maxInt(u64) - 1);
    try std.testing.expectEqual(std.math.maxInt(u64), failed.retry_at_ms);
    try std.testing.expectEqual(retry_max_attempt, failed.refresh_attempt);
}

test "TTL defaults are version scoped and preserve clock boundaries" {
    try std.testing.expectEqual(@as(u64, 0), snapshotTtl(.modern, true, 0));
    try std.testing.expectEqual(@as(u64, 0), snapshotTtl(.modern, false, 99));
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        snapshotTtl(.modern, true, std.math.maxInt(u64)),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        snapshotTtl(.legacy, false, 0),
    );

    const key = authPartition(.public, authIdentity(&.{}));
    var metadata = testMetadata(key, 1, "boundary");
    metadata.expires_at_ms = 500;
    try std.testing.expectEqual(.hit, decideRefresh(metadata, key, 499, false).action);
    try std.testing.expectEqual(.refresh, decideRefresh(metadata, key, 500, false).action);
}

test "paginated cache expiry uses each page receive time" {
    const first_expiry = pageExpiry(.modern, 1_000, true, 100);
    try std.testing.expectEqual(@as(u64, 1_100), first_expiry);

    const later_expiry = pageExpiry(.modern, 1_050, true, 500);
    try std.testing.expectEqual(
        first_expiry,
        earliestExpiry(first_expiry, later_expiry),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        pageExpiry(.modern, std.math.maxInt(u64) - 1, true, 100),
    );
    try std.testing.expectEqual(
        @as(u64, 2_000),
        pageExpiry(.modern, 2_000, true, 0),
    );
    try std.testing.expectEqual(
        @as(u64, 3_000),
        pageExpiry(.modern, 3_000, false, 99),
    );
    try std.testing.expectEqual(
        std.math.maxInt(u64),
        pageExpiry(.legacy, 4_000, false, 0),
    );
}
