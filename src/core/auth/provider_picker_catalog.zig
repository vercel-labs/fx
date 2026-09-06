//! Column contents for the `/provider` picker.
//!
//! List columns hold whitespace-free tokens that are also the labels shown to
//! the user, so what the picker writes into the composer is exactly what the
//! row displays. The one exception is the API key column, whose single row is
//! a masked entry field and never reaches the composer.

const std = @import("std");
const host_target = @import("../hosts/target.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_catalog = @import("provider_catalog.zig");
const types = @import("../shared/types.zig");

/// How a provider is authenticated. Subscription providers expose no methods;
/// choosing one acts directly instead of opening the method column.
pub const Method = enum {
    /// Browser sign-in that yields an fx login session.
    oauth,
    /// A pasted AI Gateway key held in the keychain or profile.
    api_key,
};

pub const max_provider_options = provider_catalog.entries.len;
const max_method_options = 2;
/// The team column lists at most this many teams; accounts beyond it see the
/// first 128 and can still change teams through the sign-in flow.
pub const max_team_options = 128;
pub const max_column_options = @max(max_team_options, @max(max_provider_options, max_method_options));

/// The API key column shows a cursor bar and one bullet per typed byte, or a
/// placeholder while the field is empty.
pub const key_field_prefix = "\u{2503} ";
pub const key_field_placeholder = "Paste or type a key";
const key_field_bullet = "\u{2022}";
pub const max_key_mask_glyphs: usize = 32;
pub const max_key_field_bytes =
    key_field_prefix.len + @max(key_field_placeholder.len, max_key_mask_glyphs * key_field_bullet.len);

pub fn writeKeyField(out: *[max_key_field_bytes]u8, mask_count: usize) []const u8 {
    @memcpy(out[0..key_field_prefix.len], key_field_prefix);
    var end = key_field_prefix.len;
    if (mask_count == 0) {
        @memcpy(out[end..][0..key_field_placeholder.len], key_field_placeholder);
        return out[0 .. end + key_field_placeholder.len];
    }
    for (0..@min(mask_count, max_key_mask_glyphs)) |_| {
        @memcpy(out[end..][0..key_field_bullet.len], key_field_bullet);
        end += key_field_bullet.len;
    }
    return out[0..end];
}

/// The key-source column: detected keys to switch to, or `new` to paste one.
/// The distinction is who supplies the key, not where the secret sleeps: an
/// `env` key may well live in a password manager the user's shell reads.
pub const KeySource = enum {
    /// AI_GATEWAY_API_KEY handed to fx through the environment.
    env,
    /// The key fx saved itself when one was pasted.
    saved,
    /// Paste a key fx does not have yet.
    new,
};

pub fn keySourceSlug(source: KeySource) []const u8 {
    return switch (source) {
        .env => "env",
        .saved => "saved",
        .new => "new",
    };
}

/// Row annotation: where the key comes from, with `current` appended when it
/// is the active credential.
pub fn keySourceAnnotation(source: KeySource, current: bool) []const u8 {
    return switch (source) {
        .env => if (current) "AI_GATEWAY_API_KEY · current" else "AI_GATEWAY_API_KEY",
        .saved => if (current) "saved by fx · current" else "saved by fx",
        .new => "paste a key",
    };
}

pub fn parseKeySource(value: []const u8) ?KeySource {
    inline for (@typeInfo(KeySource).@"enum".fields) |field| {
        const source = @field(KeySource, field.name);
        if (std.ascii.eqlIgnoreCase(value, keySourceSlug(source))) return source;
    }
    return null;
}

pub fn keySourceCredential(source: KeySource) ?types.CredentialSource {
    return switch (source) {
        .env => .ai_gateway_api_key,
        .saved => .stored_key,
        .new => null,
    };
}

pub fn methodSlug(method: Method) []const u8 {
    return switch (method) {
        .oauth => "oauth",
        .api_key => "api-key",
    };
}

pub fn parseMethod(value: []const u8) ?Method {
    if (std.ascii.eqlIgnoreCase(value, methodSlug(.oauth))) return .oauth;
    if (std.ascii.eqlIgnoreCase(value, methodSlug(.api_key))) return .api_key;
    return null;
}

fn providerVisible(id: model_provider.ProviderId) bool {
    if (comptime host_target.is_wasm) return id != .grok;
    return true;
}

/// Writes the visible provider slugs into `out` and returns how many landed.
pub fn providerOptions(out: *[max_provider_options][]const u8) usize {
    var count: usize = 0;
    for (&provider_catalog.entries) |*entry| {
        if (!providerVisible(entry.id)) continue;
        out[count] = entry.slug;
        count += 1;
    }
    return count;
}

pub fn providerMethods(id: model_provider.ProviderId) []const Method {
    return switch (id) {
        .gateway => &.{ .oauth, .api_key },
        .codex, .grok => &.{},
    };
}

/// True when `source` is one of the ways `method` can be satisfied. The API key
/// method covers every gateway key origin, not just the environment variable.
pub fn methodMatchesSource(method: Method, source: types.CredentialSource) bool {
    return switch (method) {
        .oauth => source == .fx_login or source == .vercel_oidc_token,
        .api_key => source == .ai_gateway_api_key or source == .stored_key,
    };
}

test "provider options expose the catalog slugs the composer accepts" {
    var buf: [max_provider_options][]const u8 = undefined;
    const count = providerOptions(&buf);

    try std.testing.expect(count >= 2);
    try std.testing.expectEqualStrings("vercel", buf[0]);
    for (buf[0..count]) |slug| {
        try std.testing.expect(provider_catalog.parse(slug) != null);
        try std.testing.expect(std.mem.indexOfScalar(u8, slug, ' ') == null);
    }
}

test "only the gateway offers a method column" {
    try std.testing.expectEqual(@as(usize, 2), providerMethods(.gateway).len);
    try std.testing.expectEqual(@as(usize, 0), providerMethods(.codex).len);
    try std.testing.expectEqual(@as(usize, 0), providerMethods(.grok).len);
}

test "method slugs round trip and stay single tokens" {
    for ([_]Method{ .oauth, .api_key }) |method| {
        const slug = methodSlug(method);
        try std.testing.expectEqual(method, parseMethod(slug).?);
        try std.testing.expect(std.mem.indexOfScalar(u8, slug, ' ') == null);
    }
    try std.testing.expect(parseMethod("nope") == null);
}

test "method ownership of credential sources is disjoint" {
    try std.testing.expect(methodMatchesSource(.oauth, .fx_login));
    try std.testing.expect(methodMatchesSource(.api_key, .stored_key));
    try std.testing.expect(!methodMatchesSource(.oauth, .stored_key));
    try std.testing.expect(!methodMatchesSource(.api_key, .fx_login));
}

test "key field shows a placeholder when empty and one bullet per byte" {
    var buf: [max_key_field_bytes]u8 = undefined;

    const empty = writeKeyField(&buf, 0);
    try std.testing.expect(std.mem.endsWith(u8, empty, key_field_placeholder));

    const typed = writeKeyField(&buf, 3);
    try std.testing.expectEqualStrings(key_field_prefix ++ "\u{2022}\u{2022}\u{2022}", typed);

    // A long key must not run past the buffer the column renders from.
    const clamped = writeKeyField(&buf, max_key_mask_glyphs * 4);
    try std.testing.expect(clamped.len <= max_key_field_bytes);
}

test "key source slugs round trip and map to their credentials" {
    inline for (@typeInfo(KeySource).@"enum".fields) |field| {
        const source = @field(KeySource, field.name);
        try std.testing.expectEqual(source, parseKeySource(keySourceSlug(source)).?);
    }
    try std.testing.expectEqual(types.CredentialSource.ai_gateway_api_key, keySourceCredential(.env).?);
    try std.testing.expectEqual(types.CredentialSource.stored_key, keySourceCredential(.saved).?);
    try std.testing.expect(keySourceCredential(.new) == null);
}
