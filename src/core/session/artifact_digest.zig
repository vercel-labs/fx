const std = @import("std");
const text_utils = @import("../shared/text_utils.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
/// A v1 handle keeps the first 8 bytes of the digest.
const digest_hex_bytes = 16;
/// A v2 handle keeps all of it: the name of the body's blob (D44).
pub const blob_hex_bytes = 2 * Sha256.digest_length;

pub fn contentAddressedHandle(
    alloc: Allocator,
    source_handle: []const u8,
    suffix: []const u8,
    digest: [Sha256.digest_length]u8,
) ![]u8 {
    if (suffix.len == 0 or !std.mem.endsWith(u8, source_handle, suffix)) {
        return error.InvalidArtifactHandle;
    }
    const digest_hex = std.fmt.bytesToHex(digest[0..8].*, .lower);
    return alloc.print(
        "{s}-{s}{s}",
        .{
            source_handle[0 .. source_handle.len - suffix.len],
            &digest_hex,
            suffix,
        },
    );
}

/// A v2 session's handle for a body: `prefix`, the whole digest, which is
/// the name of the body's blob, then `suffix` (D44). `prefix` ends in `-`.
/// Caller owns the result.
pub fn blobHandle(
    alloc: Allocator,
    prefix: []const u8,
    digest: [Sha256.digest_length]u8,
    suffix: []const u8,
) ![]u8 {
    std.debug.assert(std.mem.endsWith(u8, prefix, "-"));
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    return std.mem.concat(alloc, u8, &.{ prefix, &digest_hex, suffix });
}

/// The blob a v2 handle names (`blobHandle`), or null for any other handle,
/// such as a v1 one. Borrows from `handle`.
pub fn blobHash(handle: []const u8) ?[]const u8 {
    const separator = std.mem.findScalarLast(u8, handle, '-') orelse return null;
    const rest = handle[separator + 1 ..];
    const encoded = rest[0 .. std.mem.findScalar(u8, rest, '.') orelse rest.len];
    if (encoded.len != blob_hex_bytes or !isLowerHex(encoded)) return null;
    return encoded;
}

pub fn hasContentDigest(
    handle: []const u8,
    suffix: []const u8,
) bool {
    return encodedDigest(handle, suffix) != null;
}

pub fn handleMatchesContentDigest(
    handle: []const u8,
    suffix: []const u8,
    digest: [Sha256.digest_length]u8,
) bool {
    const encoded = encodedDigest(handle, suffix) orelse return false;
    const expected = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, encoded, expected[0..encoded.len]);
}

/// The digest a handle ends in before `suffix`: 16 hex digits for v1,
/// all 64 for v2.
fn encodedDigest(handle: []const u8, suffix: []const u8) ?[]const u8 {
    if (suffix.len == 0 or !std.mem.endsWith(u8, handle, suffix)) return null;
    const stem = handle[0 .. handle.len - suffix.len];
    const separator = std.mem.findScalarLast(u8, stem, '-') orelse return null;
    const encoded = stem[separator + 1 ..];
    if (encoded.len != digest_hex_bytes and encoded.len != blob_hex_bytes) return null;
    if (!isLowerHex(encoded)) return null;
    return encoded;
}

fn isLowerHex(text: []const u8) bool {
    for (text) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    return true;
}

test "content addressed artifact handles authenticate exact bytes" {
    const alloc = std.testing.allocator;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("saved output", &digest, .{});
    const handle = try contentAddressedHandle(
        alloc,
        "fx-command-123.log",
        ".log",
        digest,
    );
    defer alloc.free(handle);
    try std.testing.expectEqualStrings(
        "fx-command-123-1b2a9cb5a0298dcb.log",
        handle,
    );
    try std.testing.expect(handleMatchesContentDigest(
        handle,
        ".log",
        digest,
    ));
    try std.testing.expectEqual(@as(?[]const u8, null), blobHash(handle));
    Sha256.hash("xaved output", &digest, .{});
    try std.testing.expect(!handleMatchesContentDigest(
        handle,
        ".log",
        digest,
    ));
}

test "a v2 handle names its blob by the whole digest and authenticates it" {
    const alloc = std.testing.allocator;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("saved output", &digest, .{});
    const handle = try blobHandle(alloc, "fx-command-replay-", digest, ".bin");
    defer alloc.free(handle);
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(&hex, blobHash(handle).?);
    try std.testing.expect(hasContentDigest(handle, ".bin"));
    try std.testing.expect(handleMatchesContentDigest(handle, ".bin", digest));
    // No extension, and a kind prefix with its own dashes.
    const image = try blobHandle(alloc, "image-result-", digest, "");
    defer alloc.free(image);
    try std.testing.expectEqualStrings(&hex, blobHash(image).?);
    Sha256.hash("xaved output", &digest, .{});
    try std.testing.expect(!handleMatchesContentDigest(handle, ".bin", digest));
    // Anything else names no blob.
    for ([_][]const u8{ "result-x.txt", "nodash", "result-" ++ text_utils.repeat("A", 64) ++ ".txt", "result-" ++ text_utils.repeat("a", 63) ++ ".txt" }) |other| {
        try std.testing.expectEqual(@as(?[]const u8, null), blobHash(other));
    }
}
