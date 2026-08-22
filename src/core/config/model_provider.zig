const std = @import("std");
const types = @import("../shared/types.zig");

pub const ProviderId = enum {
    gateway,
    codex,
    grok,
    opencode,
};

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

pub fn parse(value: []const u8) ?ProviderId {
    if (std.ascii.eqlIgnoreCase(value, "gateway")) return .gateway;
    if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(value, "grok")) return .grok;
    if (std.ascii.eqlIgnoreCase(value, "opencode")) return .opencode;
    return null;
}

pub fn label(provider: ProviderId) []const u8 {
    return switch (provider) {
        .gateway => "Vercel AI Gateway",
        .codex => "Codex subscription",
        .grok => "Grok subscription",
        .opencode => "OpenCode Go",
    };
}

pub fn authorizesCredential(provider: ProviderId, source: ?types.CredentialSource) bool {
    const selected = source orelse return false;
    return switch (provider) {
        .gateway => switch (selected) {
            .vercel_oidc_token, .ai_gateway_api_key, .fx_login, .stored_key => true,
            .chatgpt_subscription, .grok_subscription, .opencode_api_key => false,
        },
        .codex => selected == .chatgpt_subscription,
        .grok => selected == .grok_subscription,
        .opencode => selected == .opencode_api_key,
    };
}

pub fn usesGatewayAuxiliaries(provider: ProviderId) bool {
    return provider == .gateway;
}

test "explicit providers authorize only their own credential origins" {
    try std.testing.expect(authorizesCredential(.gateway, .ai_gateway_api_key));
    try std.testing.expect(authorizesCredential(.gateway, .fx_login));
    try std.testing.expect(authorizesCredential(.gateway, .stored_key));
    try std.testing.expect(authorizesCredential(.gateway, .vercel_oidc_token));
    try std.testing.expect(!authorizesCredential(.gateway, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.gateway, .grok_subscription));
    try std.testing.expect(!authorizesCredential(.gateway, .opencode_api_key));
    try std.testing.expect(authorizesCredential(.codex, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.codex, .ai_gateway_api_key));
    try std.testing.expect(!authorizesCredential(.codex, .opencode_api_key));
    try std.testing.expect(!authorizesCredential(.codex, null));
    try std.testing.expect(authorizesCredential(.grok, .grok_subscription));
    try std.testing.expect(!authorizesCredential(.grok, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.grok, .opencode_api_key));
    try std.testing.expect(authorizesCredential(.opencode, .opencode_api_key));
    try std.testing.expect(!authorizesCredential(.opencode, .ai_gateway_api_key));
    try std.testing.expect(!authorizesCredential(.opencode, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.opencode, .grok_subscription));
    try std.testing.expect(!authorizesCredential(.opencode, null));
}

test "provider parsing exposes gateway codex grok and opencode" {
    try std.testing.expectEqual(ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(ProviderId.codex, parse("CODEX").?);
    try std.testing.expectEqual(ProviderId.grok, parse("GROK").?);
    try std.testing.expectEqual(ProviderId.opencode, parse("OpenCode").?);
    try std.testing.expectEqualStrings("OpenCode Go", label(.opencode));
    try std.testing.expect(!usesGatewayAuxiliaries(.opencode));
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("opencode-go") == null);
    try std.testing.expect(parse("") == null);
}
