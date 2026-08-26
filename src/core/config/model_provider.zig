const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

pub const ProviderId = enum {
    openpaths,
    gateway,
    codex,
    grok,
};

/// Default model served when the OpenPaths provider is active and the user has
/// not chosen one. Verified against the OpenPaths catalog.
pub const openpaths_default_model = "openpaths/stealth/ox-alpha";

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

pub fn parse(value: []const u8) ?ProviderId {
    if (std.ascii.eqlIgnoreCase(value, "openpaths")) return .openpaths;
    if (std.ascii.eqlIgnoreCase(value, "openrouter")) return .openpaths;
    if (std.ascii.eqlIgnoreCase(value, "gateway")) return .gateway;
    if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(value, "grok")) return .grok;
    return null;
}

pub fn label(provider: ProviderId) []const u8 {
    return switch (provider) {
        .openpaths => "OpenPaths",
        .gateway => "Vercel AI Gateway",
        .codex => "Codex subscription",
        .grok => "Grok subscription",
    };
}

pub fn authorizesCredential(provider: ProviderId, source: ?types.CredentialSource) bool {
    const selected = source orelse return false;
    return switch (provider) {
        .openpaths => selected == .openpaths_api_key or selected == .openrouter_api_key,
        .gateway => selected != .chatgpt_subscription and
            selected != .grok_subscription and
            selected != .openpaths_api_key and
            selected != .openrouter_api_key,
        .codex => selected == .chatgpt_subscription,
        .grok => selected == .grok_subscription,
    };
}

pub fn usesGatewayAuxiliaries(provider: ProviderId) bool {
    return provider == .gateway;
}

/// Compiled-default provider. OpenPaths wins automatically whenever one of its
/// API keys is present in the environment so a fresh install works with zero
/// setup commands.
pub fn defaultId() ProviderId {
    if (io_mod.getenv("OPENPATHS_API_KEY") != null or io_mod.getenv("OPENROUTER_API_KEY") != null) {
        return .openpaths;
    }
    return .gateway;
}

test "explicit providers authorize only their own credential origins" {
    try std.testing.expect(authorizesCredential(.gateway, .ai_gateway_api_key));
    try std.testing.expect(authorizesCredential(.gateway, .fx_login));
    try std.testing.expect(!authorizesCredential(.gateway, .chatgpt_subscription));
    try std.testing.expect(authorizesCredential(.codex, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.codex, .ai_gateway_api_key));
    try std.testing.expect(!authorizesCredential(.codex, null));
    try std.testing.expect(authorizesCredential(.grok, .grok_subscription));
    try std.testing.expect(!authorizesCredential(.grok, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.gateway, .grok_subscription));
}

test "provider parsing exposes gateway codex and grok" {
    try std.testing.expectEqual(ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(ProviderId.codex, parse("CODEX").?);
    try std.testing.expectEqual(ProviderId.grok, parse("GROK").?);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("") == null);
}
