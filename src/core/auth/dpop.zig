//! ES256 DPoP proofs (RFC 9449) for Google's OAuth token endpoint.
//!
//! Every function here is pure: the key, the clock reading, the jti entropy,
//! and the signature noise all come in as arguments.

const std = @import("std");
const testing_allocator = @import("../shared/testing_allocator.zig");

const b64 = std.base64.url_safe_no_pad;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Scheme = std.crypto.sign.ecdsa.EcdsaP256Sha256;
pub const KeyPair = Scheme.KeyPair;

pub const seed_bytes = KeyPair.seed_length;
pub const jti_entropy_bytes = 24;

pub const Error = error{ InvalidDpopKey, InvalidDpopUrl, OutOfMemory };

pub const Claims = struct {
    htu: []const u8,
    iat_s: i64,
    jti: []const u8,
    nonce: ?[]const u8 = null,
};

const http_method = "POST";
const dpop_type = "dpop+jwt";
const jws_alg = "ES256";
const jwk_kty = "EC";
const jwk_crv = "P-256";
const url_forbidden_chars = "?#";
const coordinate_bytes = 32;
const coordinate_text_len = b64.Encoder.calcSize(coordinate_bytes);
const secret_key_bytes = Scheme.SecretKey.encoded_length;
const secret_key_text_len = b64.Encoder.calcSize(secret_key_bytes);
const digest_bytes = Sha256.digest_length;

const Jwk = struct {
    kty: []const u8,
    crv: []const u8,
    x: []const u8,
    y: []const u8,
};

const Header = struct {
    typ: []const u8,
    alg: []const u8,
    jwk: Jwk,
};

const Payload = struct {
    jti: []const u8,
    htm: []const u8,
    htu: []const u8,
    iat: i64,
    nonce: ?[]const u8,
};

pub fn keyPairFromSeed(seed: [seed_bytes]u8) Error!KeyPair {
    return KeyPair.generateDeterministic(seed) catch error.InvalidDpopKey;
}

/// The caller owns the returned slice. It is a secret: zero it before freeing.
pub fn encodeSecretKeyAlloc(alloc: std.mem.Allocator, key_pair: KeyPair) Error![]u8 {
    var secret = key_pair.secret_key.toBytes();
    defer std.crypto.secureZero(u8, &secret);
    return base64UrlAlloc(alloc, &secret);
}

/// Inverse of encodeSecretKeyAlloc. Any other text is InvalidDpopKey.
pub fn decodeSecretKey(text: []const u8) Error!KeyPair {
    if (text.len != secret_key_text_len) return error.InvalidDpopKey;
    var secret: [secret_key_bytes]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    b64.Decoder.decode(&secret, text) catch return error.InvalidDpopKey;
    // The decoder ignores the unused bits of the last character; encoding again rejects them.
    var canonical: [secret_key_text_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &canonical);
    if (!std.mem.eql(u8, b64.Encoder.encode(&canonical, &secret), text)) return error.InvalidDpopKey;
    // Signing rejects a scalar at or above the group order, but building the key pair does not.
    _ = Scheme.Curve.scalar.Scalar.fromBytes(secret, .big) catch return error.InvalidDpopKey;
    const secret_key = try Scheme.SecretKey.fromBytes(secret);
    return Scheme.KeyPair.fromSecretKey(secret_key) catch error.InvalidDpopKey;
}

/// The caller owns the returned slice. Google rejects a random jti on code
/// exchange, so the jti is the hash of the URL-decoded code.
pub fn codeExchangeJtiAlloc(alloc: std.mem.Allocator, code: []const u8) Error![]u8 {
    var digest: [digest_bytes]u8 = undefined;
    Sha256.hash(code, &digest, .{});
    return base64UrlAlloc(alloc, &digest);
}

/// The caller owns the returned slice.
pub fn randomJtiAlloc(alloc: std.mem.Allocator, entropy: [jti_entropy_bytes]u8) Error![]u8 {
    return base64UrlAlloc(alloc, &entropy);
}

/// The caller owns the returned slice. A null `noise` gives deterministic
/// signatures, for tests. Pass random noise in production. A signing failure
/// is reported as InvalidDpopKey.
pub fn proofAlloc(
    alloc: std.mem.Allocator,
    key_pair: KeyPair,
    claims: Claims,
    noise: ?[Scheme.noise_length]u8,
) Error![]u8 {
    if (std.mem.findAny(u8, claims.htu, url_forbidden_chars) != null) return error.InvalidDpopUrl;

    const signing_input = try signingInputAlloc(alloc, key_pair, claims);
    defer alloc.free(signing_input);

    const signature = key_pair.sign(signing_input, noise) catch return error.InvalidDpopKey;
    const signature_bytes = signature.toBytes();
    const signature_b64 = try base64UrlAlloc(alloc, &signature_bytes);
    defer alloc.free(signature_b64);
    return std.mem.join(alloc, ".", &.{ signing_input, signature_b64 });
}

/// The caller owns the returned slice: "base64url(header).base64url(payload)".
fn signingInputAlloc(alloc: std.mem.Allocator, key_pair: KeyPair, claims: Claims) Error![]u8 {
    const header_json = try headerJsonAlloc(alloc, key_pair);
    defer alloc.free(header_json);
    const payload_json = try payloadJsonAlloc(alloc, claims);
    defer alloc.free(payload_json);

    const header_b64 = try base64UrlAlloc(alloc, header_json);
    defer alloc.free(header_b64);
    const payload_b64 = try base64UrlAlloc(alloc, payload_json);
    defer alloc.free(payload_b64);
    return std.mem.join(alloc, ".", &.{ header_b64, payload_b64 });
}

fn headerJsonAlloc(alloc: std.mem.Allocator, key_pair: KeyPair) Error![]u8 {
    const sec1 = key_pair.public_key.toUncompressedSec1();
    var x_text: [coordinate_text_len]u8 = undefined;
    var y_text: [coordinate_text_len]u8 = undefined;
    const header: Header = .{
        .typ = dpop_type,
        .alg = jws_alg,
        .jwk = .{
            .kty = jwk_kty,
            .crv = jwk_crv,
            .x = b64.Encoder.encode(&x_text, sec1[1 .. 1 + coordinate_bytes]),
            .y = b64.Encoder.encode(&y_text, sec1[1 + coordinate_bytes ..]),
        },
    };
    return jsonAlloc(alloc, header);
}

fn payloadJsonAlloc(alloc: std.mem.Allocator, claims: Claims) Error![]u8 {
    const payload: Payload = .{
        .jti = claims.jti,
        .htm = http_method,
        .htu = claims.htu,
        .iat = claims.iat_s,
        .nonce = claims.nonce,
    };
    return jsonAlloc(alloc, payload);
}

/// The caller owns the returned slice. Omits null optional fields.
fn jsonAlloc(alloc: std.mem.Allocator, value: anytype) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    // The allocating writer fails only when it cannot allocate.
    std.json.Stringify.value(value, options, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The caller owns the returned slice.
fn base64UrlAlloc(alloc: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    const text = try alloc.alloc(u8, b64.Encoder.calcSize(bytes.len));
    _ = b64.Encoder.encode(text, bytes);
    return text;
}

const test_htu = "https://oauth2.googleapis.com/token";
const test_jti = "jti-test";
const test_nonce = "nonce-test";
const test_iat_s: i64 = 1_700_000_000;
const test_seed: [seed_bytes]u8 = @splat(0x42);
const test_claims: Claims = .{ .htu = test_htu, .iat_s = test_iat_s, .jti = test_jti };
const prng_seed: u64 = 0x6470_6f70;
const seed_round_trip_count = 200;

const ProofParts = struct {
    header: []const u8,
    payload: []const u8,
    signature: []const u8,
    signing_input: []const u8,
};

fn splitProofForTest(proof: []const u8) !ProofParts {
    const first_dot = std.mem.findScalar(u8, proof, '.') orelse return error.ProofNotThreeParts;
    const rest = proof[first_dot + 1 ..];
    const second_dot = std.mem.findScalar(u8, rest, '.') orelse return error.ProofNotThreeParts;
    const signature = rest[second_dot + 1 ..];
    if (std.mem.findScalar(u8, signature, '.') != null) return error.ProofNotThreeParts;
    return .{
        .header = proof[0..first_dot],
        .payload = rest[0..second_dot],
        .signature = signature,
        .signing_input = proof[0 .. first_dot + 1 + second_dot],
    };
}

fn decodeB64ForTest(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    const bytes = try alloc.alloc(u8, try b64.Decoder.calcSizeForSlice(text));
    errdefer alloc.free(bytes);
    try b64.Decoder.decode(bytes, text);
    return bytes;
}

fn payloadTextForTest(alloc: std.mem.Allocator, proof: []const u8) ![]u8 {
    const parts = try splitProofForTest(proof);
    return decodeB64ForTest(alloc, parts.payload);
}

test "proof is three dot-separated base64url parts" {
    const alloc = std.testing.allocator;
    const proof = try proofAlloc(alloc, try keyPairFromSeed(test_seed), test_claims, null);
    defer alloc.free(proof);
    const parts = try splitProofForTest(proof);
    for ([_][]const u8{ parts.header, parts.payload, parts.signature }) |part| {
        const bytes = try decodeB64ForTest(alloc, part);
        alloc.free(bytes);
    }
}

test "proof header is the exact JSON with only kty, crv, x, y in jwk" {
    const alloc = std.testing.allocator;
    const key_pair = try keyPairFromSeed(test_seed);
    const proof = try proofAlloc(alloc, key_pair, test_claims, null);
    defer alloc.free(proof);
    const parts = try splitProofForTest(proof);
    const header_json = try decodeB64ForTest(alloc, parts.header);
    defer alloc.free(header_json);

    const sec1 = key_pair.public_key.toUncompressedSec1();
    const x_b64 = try base64UrlAlloc(alloc, sec1[1 .. 1 + coordinate_bytes]);
    defer alloc.free(x_b64);
    const y_b64 = try base64UrlAlloc(alloc, sec1[1 + coordinate_bytes ..]);
    defer alloc.free(y_b64);
    const expected = try std.mem.join(alloc, "", &.{
        "{\"typ\":\"dpop+jwt\",\"alg\":\"ES256\",\"jwk\":{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"",
        x_b64,
        "\",\"y\":\"",
        y_b64,
        "\"}}",
    });
    defer alloc.free(expected);
    try std.testing.expectEqualStrings(expected, header_json);
}

test "proof jwk x and y decode back to the signing public key" {
    const alloc = std.testing.allocator;
    const key_pair = try keyPairFromSeed(test_seed);
    const proof = try proofAlloc(alloc, key_pair, test_claims, null);
    defer alloc.free(proof);
    const parts = try splitProofForTest(proof);
    const header_json = try decodeB64ForTest(alloc, parts.header);
    defer alloc.free(header_json);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, header_json, .{});
    defer parsed.deinit();
    const jwk = parsed.value.object.get("jwk").?.object;
    const x = try decodeB64ForTest(alloc, jwk.get("x").?.string);
    defer alloc.free(x);
    const y = try decodeB64ForTest(alloc, jwk.get("y").?.string);
    defer alloc.free(y);
    try std.testing.expectEqual(@as(usize, coordinate_bytes), x.len);
    try std.testing.expectEqual(@as(usize, coordinate_bytes), y.len);

    const uncompressed_sec1_tag: u8 = 0x04;
    var sec1: [Scheme.PublicKey.uncompressed_sec1_encoded_length]u8 = undefined;
    sec1[0] = uncompressed_sec1_tag;
    @memcpy(sec1[1 .. 1 + coordinate_bytes], x);
    @memcpy(sec1[1 + coordinate_bytes ..], y);
    const decoded_key = try Scheme.PublicKey.fromSec1(&sec1);
    const expected_sec1 = key_pair.public_key.toUncompressedSec1();
    const decoded_sec1 = decoded_key.toUncompressedSec1();
    try std.testing.expectEqualSlices(u8, &expected_sec1, &decoded_sec1);
}

test "proof signature is 64 raw bytes that verify over header.payload" {
    const alloc = std.testing.allocator;
    const key_pair = try keyPairFromSeed(test_seed);
    const proof = try proofAlloc(alloc, key_pair, test_claims, null);
    defer alloc.free(proof);
    const parts = try splitProofForTest(proof);
    const signature_bytes = try decodeB64ForTest(alloc, parts.signature);
    defer alloc.free(signature_bytes);

    try std.testing.expectEqual(Scheme.Signature.encoded_length, signature_bytes.len);
    const signature = Scheme.Signature.fromBytes(signature_bytes[0..Scheme.Signature.encoded_length].*);
    try signature.verify(parts.signing_input, key_pair.public_key);
}

test "proof payload without a nonce is exact JSON with POST htm and integer iat" {
    const alloc = std.testing.allocator;
    const proof = try proofAlloc(alloc, try keyPairFromSeed(test_seed), test_claims, null);
    defer alloc.free(proof);
    const payload = try payloadTextForTest(alloc, proof);
    defer alloc.free(payload);
    try std.testing.expectEqualStrings(
        "{\"jti\":\"jti-test\",\"htm\":\"POST\",\"htu\":\"https://oauth2.googleapis.com/token\",\"iat\":1700000000}",
        payload,
    );
}

test "proof payload with a nonce carries the nonce" {
    const alloc = std.testing.allocator;
    const claims: Claims = .{ .htu = test_htu, .iat_s = test_iat_s, .jti = test_jti, .nonce = test_nonce };
    const proof = try proofAlloc(alloc, try keyPairFromSeed(test_seed), claims, null);
    defer alloc.free(proof);
    const payload = try payloadTextForTest(alloc, proof);
    defer alloc.free(payload);
    try std.testing.expectEqualStrings(
        "{\"jti\":\"jti-test\",\"htm\":\"POST\",\"htu\":\"https://oauth2.googleapis.com/token\",\"iat\":1700000000,\"nonce\":\"nonce-test\"}",
        payload,
    );
}

test "proofAlloc rejects an htu with a query" {
    const claims: Claims = .{ .htu = test_htu ++ "?alt=json", .iat_s = test_iat_s, .jti = test_jti };
    try std.testing.expectError(error.InvalidDpopUrl, proofAlloc(std.testing.allocator, try keyPairFromSeed(test_seed), claims, null));
}

test "proofAlloc rejects an htu with a fragment" {
    const claims: Claims = .{ .htu = test_htu ++ "#frag", .iat_s = test_iat_s, .jti = test_jti };
    try std.testing.expectError(error.InvalidDpopUrl, proofAlloc(std.testing.allocator, try keyPairFromSeed(test_seed), claims, null));
}

test "proofAlloc with null noise gives the same proof for the same inputs" {
    const alloc = std.testing.allocator;
    const key_pair = try keyPairFromSeed(test_seed);
    const first = try proofAlloc(alloc, key_pair, test_claims, null);
    defer alloc.free(first);
    const second = try proofAlloc(alloc, key_pair, test_claims, null);
    defer alloc.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "proof payload keeps a double quote in jti and nonce as data" {
    const alloc = std.testing.allocator;
    const quoted_jti = "jti \"one\"";
    const quoted_nonce = "nonce \"two\"";
    const claims: Claims = .{ .htu = test_htu, .iat_s = test_iat_s, .jti = quoted_jti, .nonce = quoted_nonce };
    const proof = try proofAlloc(alloc, try keyPairFromSeed(test_seed), claims, null);
    defer alloc.free(proof);
    const payload = try payloadTextForTest(alloc, proof);
    defer alloc.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(quoted_jti, parsed.value.object.get("jti").?.string);
    try std.testing.expectEqualStrings(quoted_nonce, parsed.value.object.get("nonce").?.string);
}

test "proofAlloc frees everything when any allocation fails" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, proofForAllocationSweep, .{});
}

fn proofForAllocationSweep(alloc: std.mem.Allocator) !void {
    const proof = try proofAlloc(alloc, try keyPairFromSeed(test_seed), test_claims, null);
    alloc.free(proof);
}

test "codeExchangeJtiAlloc of abc is the SHA-256 vector, base64url without padding" {
    const alloc = std.testing.allocator;
    const jti = try codeExchangeJtiAlloc(alloc, "abc");
    defer alloc.free(jti);
    try std.testing.expectEqualStrings("ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0", jti);
}

test "randomJtiAlloc encodes the entropy bytes without padding" {
    const alloc = std.testing.allocator;
    const entropy: [jti_entropy_bytes]u8 = @splat(0xab);
    const jti = try randomJtiAlloc(alloc, entropy);
    defer alloc.free(jti);
    const decoded = try decodeB64ForTest(alloc, jti);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u8, &entropy, decoded);
}

test "decodeSecretKey inverts encodeSecretKeyAlloc for 200 seeds" {
    const alloc = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(prng_seed);
    const random = prng.random();
    for (0..seed_round_trip_count) |_| {
        var seed: [seed_bytes]u8 = undefined;
        random.bytes(&seed);
        const key_pair = try keyPairFromSeed(seed);
        const text = try encodeSecretKeyAlloc(alloc, key_pair);
        defer alloc.free(text);
        const decoded = try decodeSecretKey(text);
        const expected_sec1 = key_pair.public_key.toUncompressedSec1();
        const decoded_sec1 = decoded.public_key.toUncompressedSec1();
        try std.testing.expectEqualSlices(u8, &expected_sec1, &decoded_sec1);
    }
}

test "decodeSecretKey rejects empty text" {
    try std.testing.expectError(error.InvalidDpopKey, decodeSecretKey(""));
}

test "decodeSecretKey rejects a 31-byte key" {
    const alloc = std.testing.allocator;
    const short_key: [31]u8 = @splat(0x42);
    const text = try base64UrlAlloc(alloc, &short_key);
    defer alloc.free(text);
    try std.testing.expectError(error.InvalidDpopKey, decodeSecretKey(text));
}

test "decodeSecretKey rejects padded text" {
    const alloc = std.testing.allocator;
    const text = try encodeSecretKeyAlloc(alloc, try keyPairFromSeed(test_seed));
    defer alloc.free(text);
    const padded = try std.mem.join(alloc, "", &.{ text, "=" });
    defer alloc.free(padded);
    try std.testing.expectError(error.InvalidDpopKey, decodeSecretKey(padded));
}

test "decodeSecretKey rejects the standard base64 characters plus and slash" {
    for ([_]u8{ '+', '/' }) |bad_char| {
        var text: [secret_key_text_len]u8 = @splat('A');
        text[0] = bad_char;
        try std.testing.expectError(error.InvalidDpopKey, decodeSecretKey(&text));
    }
}

test "decodeSecretKey rejects the all-zero key" {
    const alloc = std.testing.allocator;
    const zero_key: [secret_key_bytes]u8 = @splat(0);
    const text = try base64UrlAlloc(alloc, &zero_key);
    defer alloc.free(text);
    try std.testing.expectError(error.InvalidDpopKey, decodeSecretKey(text));
}

test "decodeSecretKey rejects a scalar at or above the group order" {
    const alloc = std.testing.allocator;
    const max_key: [secret_key_bytes]u8 = @splat(0xff);
    const text = try base64UrlAlloc(alloc, &max_key);
    defer alloc.free(text);
    try std.testing.expectError(error.InvalidDpopKey, decodeSecretKey(text));
}

test "decodeSecretKey rejects non-zero unused bits in the last character" {
    const alloc = std.testing.allocator;
    const text = try encodeSecretKeyAlloc(alloc, try keyPairFromSeed(test_seed));
    defer alloc.free(text);
    // The last character's two low bits are unused. Adding one sets one of them
    // and keeps the character in the alphabet, because its index is a multiple of 4.
    text[text.len - 1] += 1;
    try std.testing.expectError(error.InvalidDpopKey, decodeSecretKey(text));
}
