const std = @import("std");
const types = @import("../shared/types.zig");

pub const ProviderId = enum {
    gateway,
    codex,
    custom,
};

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

pub fn parse(value: []const u8) ?ProviderId {
    if (std.ascii.eqlIgnoreCase(value, "gateway")) return .gateway;
    if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(value, "custom")) return .custom;
    return null;
}

pub fn label(provider: ProviderId) []const u8 {
    return switch (provider) {
        .gateway => "Vercel AI Gateway",
        .codex => "Codex subscription",
        .custom => "Custom OpenAI-compatible",
    };
}

pub fn authorizesCredential(provider: ProviderId, source: ?types.CredentialSource) bool {
    const selected = source orelse return false;
    return switch (provider) {
        .gateway => selected != .chatgpt_subscription,
        .codex => selected == .chatgpt_subscription,
        .custom => selected == .custom_api_key,
    };
}

pub fn usesGatewayAuxiliaries(provider: ProviderId) bool {
    return provider == .gateway;
}

test "explicit providers authorize only their own credential origins" {
    try std.testing.expect(authorizesCredential(.gateway, .ai_gateway_api_key));
    try std.testing.expect(authorizesCredential(.gateway, .fx_login));
    try std.testing.expect(!authorizesCredential(.gateway, .chatgpt_subscription));
    try std.testing.expect(authorizesCredential(.codex, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.codex, .ai_gateway_api_key));
    try std.testing.expect(!authorizesCredential(.codex, null));
    try std.testing.expect(authorizesCredential(.custom, .custom_api_key));
    try std.testing.expect(!authorizesCredential(.custom, .ai_gateway_api_key));
    try std.testing.expect(!authorizesCredential(.custom, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.custom, null));
}

test "provider parsing rejects unknown providers" {
    try std.testing.expectEqual(ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(ProviderId.codex, parse("CODEX").?);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("") == null);
}

test "provider parsing accepts custom case insensitively" {
    try std.testing.expectEqual(ProviderId.custom, parse("custom").?);
    try std.testing.expectEqual(ProviderId.custom, parse("Custom").?);
}
