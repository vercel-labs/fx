//! Reads the claims of a JSON Web Token without checking its signature. fx
//! reads claims only from a token it already holds, to schedule its renewal
//! or to name what it belongs to; the issuer checks the signature when fx
//! sends the token.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidJwt, OutOfMemory };

/// The claims of `token`, a JWT of exactly three dot-separated parts, as a
/// JSON object. Caller owns the result and calls `deinit`.
pub fn parse(alloc: Allocator, token: []const u8) Error!std.json.Parsed(std.json.Value) {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidJwt;
    const payload = parts.next() orelse return error.InvalidJwt;
    _ = parts.next() orelse return error.InvalidJwt;
    if (parts.next() != null) return error.InvalidJwt;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload) catch return error.InvalidJwt;
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    decoder.decode(decoded, payload) catch return error.InvalidJwt;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, decoded, .{ .allocate = .alloc_always }) catch
        return error.InvalidJwt;
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJwt;
    return parsed;
}

fn testToken(buf: []u8, claims: []const u8) []const u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header = "eyJhbGciOiJSUzI1NiJ9.";
    @memcpy(buf[0..header.len], header);
    const payload = encoder.encode(buf[header.len..][0..encoder.calcSize(claims.len)], claims);
    const signature = ".c2lnbmF0dXJl";
    @memcpy(buf[header.len + payload.len ..][0..signature.len], signature);
    return buf[0 .. header.len + payload.len + signature.len];
}

test "jwt claims: a three-part token yields its claims, and anything else is refused" {
    const alloc = std.testing.allocator;
    var buf: [256]u8 = undefined;
    var claims = try parse(alloc, testToken(&buf, "{\"sub\":\"account_example\",\"exp\":1700000000}"));
    defer claims.deinit();
    try std.testing.expectEqualStrings("account_example", claims.value.object.get("sub").?.string);
    try std.testing.expectEqual(@as(i64, 1700000000), claims.value.object.get("exp").?.integer);

    var array_buf: [256]u8 = undefined;
    for ([_][]const u8{
        "",
        "only-one-part",
        "two.parts",
        "four.parts.in.all",
        "header.%%%.signature",
        testToken(&array_buf, "[\"not\",\"an\",\"object\"]"),
    }) |token| {
        try std.testing.expectError(error.InvalidJwt, parse(alloc, token));
    }
}
