const std = @import("std");
const types = @import("../shared/types.zig");

pub const ProviderId = enum {
    gateway,
    codex,
    grok,
    zen,
    go,
};

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

pub fn parse(value: []const u8) ?ProviderId {
    if (std.ascii.eqlIgnoreCase(value, "gateway")) return .gateway;
    if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(value, "grok")) return .grok;
    if (std.ascii.eqlIgnoreCase(value, "zen") or std.ascii.eqlIgnoreCase(value, "opencode")) return .zen;
    if (std.ascii.eqlIgnoreCase(value, "go") or std.ascii.eqlIgnoreCase(value, "opencode-go")) return .go;
    return null;
}

pub fn label(provider: ProviderId) []const u8 {
    return switch (provider) {
        .gateway => "Vercel AI Gateway",
        .codex => "Codex subscription",
        .grok => "Grok subscription",
        .zen => "OpenCode Zen",
        .go => "OpenCode Go",
    };
}

pub fn authorizesCredential(provider: ProviderId, source: ?types.CredentialSource) bool {
    const selected = source orelse return false;
    return switch (provider) {
        .gateway => selected != .chatgpt_subscription and selected != .grok_subscription and selected != .zen_api_key and selected != .go_api_key,
        .codex => selected == .chatgpt_subscription,
        .grok => selected == .grok_subscription,
        .zen => selected == .zen_api_key,
        .go => selected == .go_api_key,
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
    try std.testing.expect(authorizesCredential(.grok, .grok_subscription));
    try std.testing.expect(!authorizesCredential(.grok, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.gateway, .grok_subscription));
    try std.testing.expect(authorizesCredential(.zen, .zen_api_key));
    try std.testing.expect(authorizesCredential(.go, .go_api_key));
    try std.testing.expect(!authorizesCredential(.gateway, .zen_api_key));
    try std.testing.expect(!authorizesCredential(.gateway, .go_api_key));
}

test "provider parsing exposes gateway codex grok zen and go" {
    try std.testing.expectEqual(ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(ProviderId.codex, parse("CODEX").?);
    try std.testing.expectEqual(ProviderId.grok, parse("GROK").?);
    try std.testing.expectEqual(ProviderId.zen, parse("zen").?);
    try std.testing.expectEqual(ProviderId.go, parse("go").?);
    try std.testing.expectEqual(ProviderId.zen, parse("opencode").?);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("local") == null);
    try std.testing.expect(parse("") == null);
}

test "zen and go labels stay distinct from gateway" {
    try std.testing.expectEqualStrings("OpenCode Zen", label(.zen));
    try std.testing.expectEqualStrings("OpenCode Go", label(.go));
    try std.testing.expect(!std.mem.eql(u8, label(.zen), label(.gateway)));
    try std.testing.expect(!std.mem.eql(u8, label(.go), label(.gateway)));
    try std.testing.expectEqual(ProviderId.zen, parse("ZEN").?);
    try std.testing.expectEqual(ProviderId.go, parse("opencode-go").?);
}
