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

/// Whether a subscription provider's authenticated catalog can plausibly serve
/// `model`. Codex only serves OpenAI ids and Grok only serves xAI ids, so a
/// third-party id persisted under one of those providers (for example a
/// failover to a DeepSeek model) must be routed through an API-key provider.
pub fn subscriptionCanServe(provider: ProviderId, model: []const u8) bool {
    const id = if (std.mem.lastIndexOfScalar(u8, model, '/')) |slash| model[slash + 1 ..] else model;
    const vendor = if (std.mem.lastIndexOfScalar(u8, model, '/')) |slash| model[0..slash] else "";
    return switch (provider) {
        .openpaths, .gateway => true,
        .codex => (vendor.len == 0 or std.mem.eql(u8, vendor, "openai")) and
            (std.mem.startsWith(u8, id, "gpt") or std.mem.startsWith(u8, id, "o1") or
                std.mem.startsWith(u8, id, "o3") or std.mem.startsWith(u8, id, "o4") or
                std.mem.startsWith(u8, id, "codex") or std.mem.startsWith(u8, id, "chatgpt")),
        .grok => (vendor.len == 0 or std.mem.eql(u8, vendor, "xai") or std.mem.eql(u8, vendor, "x-ai")) and
            std.mem.startsWith(u8, id, "grok"),
    };
}

/// Reroutes a persisted subscription selection whose model that subscription
/// cannot serve onto OpenPaths when an OpenPaths/OpenRouter key is available.
/// Keeps the user's model choice; only the credential and transport change.
pub fn rerouteUnservableSelection(selection: ProviderSelection) ProviderSelection {
    if (subscriptionCanServe(selection.provider, selection.model)) return selection;
    if (!(hasNonEmptyEnv("OPENPATHS_API_KEY") or hasNonEmptyEnv("OPENROUTER_API_KEY"))) return selection;
    return .{ .provider = .openpaths, .model = selection.model };
}

test "subscription providers only claim their own vendor ids" {
    try std.testing.expect(subscriptionCanServe(.codex, "gpt-5.6"));
    try std.testing.expect(subscriptionCanServe(.codex, "openai/gpt-5-codex"));
    try std.testing.expect(subscriptionCanServe(.codex, "o4-mini"));
    try std.testing.expect(!subscriptionCanServe(.codex, "deepseek-v4-flash-vision-exp"));
    try std.testing.expect(!subscriptionCanServe(.codex, "deepseek/deepseek-v4-flash-vision-exp"));
    try std.testing.expect(!subscriptionCanServe(.codex, "muse-spark-1.3"));
    try std.testing.expect(subscriptionCanServe(.grok, "grok-4"));
    try std.testing.expect(subscriptionCanServe(.grok, "xai/grok-4-fast"));
    try std.testing.expect(!subscriptionCanServe(.grok, "gpt-5.6"));
    try std.testing.expect(subscriptionCanServe(.openpaths, "anything/at-all"));
    try std.testing.expect(subscriptionCanServe(.gateway, "anything/at-all"));
}

pub fn usesGatewayAuxiliaries(provider: ProviderId) bool {
    return provider == .gateway;
}

/// Compiled-default provider. OpenPaths wins automatically whenever one of its
/// API keys is present in the environment so a fresh install works with zero
/// setup commands.
pub fn defaultId() ProviderId {
    if (hasNonEmptyEnv("OPENPATHS_API_KEY") or hasNonEmptyEnv("OPENROUTER_API_KEY")) {
        return .openpaths;
    }
    return .gateway;
}

fn hasNonEmptyEnv(name: []const u8) bool {
    const value = io_mod.getenv(name) orelse return false;
    return std.mem.trim(u8, value, " \t\r\n").len != 0;
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
