const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const verifier_max_bytes: usize = 64;
pub const challenge_bytes: usize = 43;
pub const state_bytes: usize = 43;

pub const Pair = struct {
    verifier: []const u8,
    challenge: []const u8,
};

pub fn generateFromRandom(
    verifier_buf: *[verifier_max_bytes]u8,
    challenge_buf: *[challenge_bytes]u8,
    random: std.Random,
) Pair {
    var entropy: [48]u8 = undefined;
    random.bytes(&entropy);
    const verifier = std.base64.url_safe_no_pad.Encoder.encode(verifier_buf, &entropy);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const challenge = std.base64.url_safe_no_pad.Encoder.encode(challenge_buf, &digest);
    return .{ .verifier = verifier, .challenge = challenge };
}

pub fn generate(
    verifier_buf: *[verifier_max_bytes]u8,
    challenge_buf: *[challenge_bytes]u8,
) !Pair {
    var entropy: [48]u8 = undefined;
    try io_mod.getIo().randomSecure(&entropy);
    const verifier = std.base64.url_safe_no_pad.Encoder.encode(verifier_buf, &entropy);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const challenge = std.base64.url_safe_no_pad.Encoder.encode(challenge_buf, &digest);
    return .{ .verifier = verifier, .challenge = challenge };
}

pub fn generateState(state_buf: *[state_bytes]u8) ![]const u8 {
    var entropy: [32]u8 = undefined;
    try io_mod.getIo().randomSecure(&entropy);
    return std.base64.url_safe_no_pad.Encoder.encode(state_buf, &entropy);
}

test "pkce challenge is the S256 digest of the verifier" {
    var prng = std.Random.DefaultPrng.init(1);
    var verifier_buf: [verifier_max_bytes]u8 = undefined;
    var challenge_buf: [challenge_bytes]u8 = undefined;
    const pair = generateFromRandom(&verifier_buf, &challenge_buf, prng.random());
    try std.testing.expectEqual(@as(usize, 64), pair.verifier.len);
    try std.testing.expectEqual(@as(usize, 43), pair.challenge.len);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pair.verifier, &digest, .{});
    var expected_buf: [challenge_bytes]u8 = undefined;
    const expected = std.base64.url_safe_no_pad.Encoder.encode(&expected_buf, &digest);
    try std.testing.expectEqualStrings(expected, pair.challenge);
}

test "pkce generateState is a 43-byte url-safe token" {
    var state_buf: [state_bytes]u8 = undefined;
    const state = try generateState(&state_buf);
    try std.testing.expectEqual(@as(usize, 43), state.len);
    for (state) |byte| {
        try std.testing.expect(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_');
    }
}
