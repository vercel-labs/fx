//! SHA-256 digests as lowercase hex. The runner checks the login token against
//! the digest the host sent (V1), and later keys its state folders with the same
//! digests (`repo_key`, `host_key`). Callers keep the digest, never the input.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// The length of a lowercase hex digest.
pub const hex_len: usize = Sha256.digest_length * 2;

/// The lowercase hex SHA-256 of `bytes`.
pub fn hexDigest(bytes: []const u8) [hex_len]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Whether `text` is exactly 64 lowercase hex digits.
pub fn isHexDigest(text: []const u8) bool {
    if (text.len != hex_len) return false;
    for (text) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Whether `expected` is the lowercase hex SHA-256 of `bytes`. The comparison
/// does not stop at the first different byte.
pub fn matches(expected: []const u8, bytes: []const u8) bool {
    if (!isHexDigest(expected)) return false;
    const actual = hexDigest(bytes);
    return std.crypto.timing_safe.eql([hex_len]u8, actual, expected[0..hex_len].*);
}

test "hexDigest of abc is the standard SHA-256 vector" {
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hexDigest("abc"),
    );
}

test "isHexDigest takes exactly 64 lowercase hex digits" {
    try std.testing.expect(isHexDigest(&hexDigest("abc")));
    try std.testing.expect(!isHexDigest("ba7816bf"));
    try std.testing.expect(!isHexDigest("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"));
    try std.testing.expect(!isHexDigest("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ag"));
    try std.testing.expect(!isHexDigest(""));
}

test "matches accepts the digest of the same bytes and nothing else" {
    const digest = hexDigest("token-one");
    try std.testing.expect(matches(&digest, "token-one"));
    try std.testing.expect(!matches(&digest, "token-two"));
    try std.testing.expect(!matches("not-a-digest", "token-one"));
    var upper = digest;
    upper[0] = 'F';
    try std.testing.expect(!matches(&upper, "token-one"));
}
