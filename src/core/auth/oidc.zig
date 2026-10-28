//! OpenID Connect Core 3.1.3.7 identity checks for RS256 ID tokens.
//! The caller supplies trusted issuer keys and time; this module performs no I/O.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rsa = std.crypto.Certificate.rsa;

pub const Validation = struct {
    issuer: []const u8,
    audience: []const u8,
    nonce: ?[]const u8,
    now_s: i64,
};

const Header = struct {
    alg: []const u8,
    kid: []const u8,
    crit: ?[]const []const u8 = null,
    b64: ?bool = null,
};

const Key = struct {
    kid: ?[]const u8 = null,
    kty: ?[]const u8 = null,
    alg: ?[]const u8 = null,
    use: ?[]const u8 = null,
    key_ops: ?[]const []const u8 = null,
    n: ?[]const u8 = null,
    e: ?[]const u8 = null,
};

const Claims = struct {
    iss: []const u8,
    sub: []const u8,
    aud: std.json.Value,
    exp: i64,
    iat: i64,
    nbf: ?i64 = null,
    azp: ?[]const u8 = null,
    nonce: ?[]const u8 = null,

    fn validate(self: Claims, expected: Validation) !void {
        if (!std.mem.eql(u8, self.iss, expected.issuer)) return error.WrongIssuer;
        if (expected.audience.len == 0) return error.WrongAudience;
        // This client trusts only its own audience, not other recipients.
        const audience = switch (self.aud) {
            .string => |value| value,
            .array => |values| blk: {
                if (values.items.len != 1 or values.items[0] != .string) return error.WrongAudience;
                break :blk values.items[0].string;
            },
            else => return error.WrongAudience,
        };
        if (!std.mem.eql(u8, audience, expected.audience)) return error.WrongAudience;
        if (self.azp) |party| {
            if (!std.mem.eql(u8, party, expected.audience)) return error.WrongAudience;
        }
        if (self.exp <= expected.now_s) return error.Expired;
        if (self.iat < 0 or self.iat >= self.exp or self.iat > expected.now_s +| 60) return error.InvalidTokenTime;
        if (self.nbf) |not_before| {
            if (not_before < 0 or not_before > expected.now_s) return error.InvalidTokenTime;
        }
        if (expected.nonce) |sent| {
            if (!std.mem.eql(u8, self.nonce orelse return error.NonceMismatch, sent)) return error.NonceMismatch;
        }
        if (self.sub.len == 0 or self.sub.len > 255) return error.InvalidSubject;
        for (self.sub) |byte| {
            if (byte < 0x21 or byte > 0x7e) return error.InvalidSubject;
        }
    }
};

/// Returns an allocator-owned subject only after signature and claim validation.
/// A null expected nonce is for refresh responses, not authorization-code grants.
pub fn subject(alloc: Allocator, jwt: []const u8, jwks: []const u8, expected: Validation) ![]u8 {
    if (jwt.len > 64 * 1024 or jwks.len > 256 * 1024) return error.IdentityDocumentTooLarge;
    var segments = std.mem.splitScalar(u8, jwt, '.');
    const protected = segments.next() orelse return error.InvalidIdentityDocument;
    const payload = segments.next() orelse return error.InvalidIdentityDocument;
    const signature = segments.next() orelse return error.InvalidIdentityDocument;
    if (segments.next() != null or protected.len == 0 or payload.len == 0 or signature.len == 0) return error.InvalidIdentityDocument;

    var header_bytes: [4096]u8 = undefined;
    var header = try document(Header, alloc, try decodeInto(&header_bytes, protected));
    defer header.deinit();
    if (!std.mem.eql(u8, header.value.alg, "RS256") or header.value.crit != null or header.value.b64 != null) return error.UnsupportedIdentityAlgorithm;
    if (header.value.kid.len == 0) return error.UnknownSigningKey;

    var key_set = try document(struct { keys: []const Key }, alloc, jwks);
    defer key_set.deinit();
    if (key_set.value.keys.len > 128) return error.IdentityDocumentTooLarge;
    var key_index: ?usize = null;
    for (key_set.value.keys, 0..) |key, index| {
        const id = key.kid orelse continue;
        if (!std.mem.eql(u8, id, header.value.kid)) continue;
        if (key_index != null) return error.AmbiguousSigningKey;
        key_index = index;
    }
    const key = key_set.value.keys[key_index orelse return error.UnknownSigningKey];
    try authenticate(key, jwt[0 .. protected.len + 1 + payload.len], signature);

    const payload_bytes = try alloc.alloc(u8, std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return error.InvalidIdentityDocument);
    defer {
        std.crypto.secureZero(u8, @volatileCast(payload_bytes));
        alloc.free(payload_bytes);
    }
    var claims = try document(Claims, alloc, try decodeInto(payload_bytes, payload));
    defer claims.deinit();
    try claims.value.validate(expected);
    return alloc.dupe(u8, claims.value.sub);
}

fn document(comptime T: type, alloc: Allocator, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, alloc, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidIdentityDocument,
    };
}

fn decodeInto(destination: []u8, encoded: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return error.InvalidIdentityDocument;
    if (size > destination.len) return error.IdentityDocumentTooLarge;
    decoder.decode(destination[0..size], encoded) catch return error.InvalidIdentityDocument;
    return destination[0..size];
}

fn authenticate(key: Key, message: []const u8, encoded_signature: []const u8) !void {
    if (!std.mem.eql(u8, key.kty orelse "", "RSA")) return error.UnknownSigningKey;
    if (key.alg) |alg| {
        if (!std.mem.eql(u8, alg, "RS256")) return error.UnknownSigningKey;
    }
    if (key.use) |use| {
        if (!std.mem.eql(u8, use, "sig")) return error.UnknownSigningKey;
    }
    if (key.key_ops) |operations| {
        if (operations.len != 1 or !std.mem.eql(u8, operations[0], "verify")) return error.UnknownSigningKey;
    }
    var modulus_storage: [512]u8 = undefined;
    var exponent_storage: [8]u8 = undefined;
    var signature_storage: [512]u8 = undefined;
    const modulus = try decodeInto(&modulus_storage, key.n orelse return error.UnknownSigningKey);
    const exponent = try decodeInto(&exponent_storage, key.e orelse return error.UnknownSigningKey);
    const signature = try decodeInto(&signature_storage, encoded_signature);
    // RFC 7518 Base64urlUInt omits leading zero octets. RS256 requires 2048 bits.
    if (modulus.len == 0 or modulus[0] < 0x80 or exponent.len == 0 or exponent[0] == 0) return error.UnknownSigningKey;
    const public_key = rsa.PublicKey.fromBytes(exponent, modulus) catch return error.UnknownSigningKey;
    inline for (.{ 256, 384, 512 }) |width| {
        if (modulus.len == width) {
            if (signature.len != width) return error.BadSignature;
            rsa.PKCS1v1_5Signature.verify(width, signature[0..width], message, public_key, std.crypto.hash.sha2.Sha256) catch return error.BadSignature;
            return;
        }
    }
    return error.UnknownSigningKey;
}

const test_validation: Validation = .{
    .issuer = "https://issuer.example",
    .audience = "fx-desktop",
    .nonce = "authorization-attempt",
    .now_s = 1_800_000_000,
};
const TestVectors = struct {
    jwks: []const u8,
    cases: []const struct { name: []const u8, token: []const u8, failure: ?[]const u8 = null },
};

test "ChatGPT OIDC verifies freshly generated signatures and claim failures" {
    const alloc = std.testing.allocator;
    var vectors = try document(TestVectors, alloc, @embedFile("testdata/oidc.json"));
    defer vectors.deinit();
    for (vectors.value.cases) |case| {
        const result = subject(alloc, case.token, vectors.value.jwks, test_validation) catch |err| {
            try std.testing.expectEqualStrings(case.failure orelse return err, @errorName(err));
            continue;
        };
        defer alloc.free(result);
        try std.testing.expect(case.failure == null);
        try std.testing.expectEqualStrings("fixture-member", result);
    }
}

test "ChatGPT OIDC rejects ambiguous keys and inappropriate key operations" {
    const alloc = std.testing.allocator;
    var vectors = try document(TestVectors, alloc, @embedFile("testdata/oidc.json"));
    defer vectors.deinit();
    var keys = try document(struct { keys: []const Key }, alloc, vectors.value.jwks);
    defer keys.deinit();
    const key = keys.value.keys[0];
    const duplicate = try std.json.Stringify.valueAlloc(alloc, .{ .keys = .{ key, key } }, .{});
    defer alloc.free(duplicate);
    try std.testing.expectError(error.AmbiguousSigningKey, subject(alloc, vectors.value.cases[0].token, duplicate, test_validation));
    var unusable = key;
    unusable.key_ops = &.{"encrypt"};
    const wrong_ops = try std.json.Stringify.valueAlloc(alloc, .{ .keys = .{unusable} }, .{});
    defer alloc.free(wrong_ops);
    try std.testing.expectError(error.UnknownSigningKey, subject(alloc, vectors.value.cases[0].token, wrong_ops, test_validation));
    try std.testing.expectError(error.InvalidIdentityDocument, subject(alloc, "invalid.jwt", vectors.value.jwks, test_validation));
}

test "ChatGPT OIDC subject ownership survives allocation failures" {
    const Check = struct {
        fn run(alloc: Allocator, token: []const u8, keys: []const u8) !void {
            const identity = try subject(alloc, token, keys, test_validation);
            defer alloc.free(identity);
            try std.testing.expectEqualStrings("fixture-member", identity);
        }
    };
    var vectors = try document(TestVectors, std.testing.allocator, @embedFile("testdata/oidc.json"));
    defer vectors.deinit();
    try std.testing.checkAllAllocationFailures(@import("../shared/testing_allocator.zig").no_resize, Check.run, .{ vectors.value.cases[0].token, vectors.value.jwks });
}
