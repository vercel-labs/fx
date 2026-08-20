const std = @import("std");

pub const ProviderId = enum {
    vercel_ai_gateway,
    anthropic_max,
    openai_codex,
    xai_direct,

    pub fn metadata(self: ProviderId) Metadata {
        return switch (self) {
            .vercel_ai_gateway => .{
                .label = "Vercel AI Gateway",
                .credential_env_names = &.{ "VERCEL_OIDC_TOKEN", "AI_GATEWAY_API_KEY" },
                .preferred_credential_env_name = "VERCEL_OIDC_TOKEN",
            },
            .anthropic_max => .{
                .label = "Anthropic Max",
                .credential_env_names = &.{ "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY" },
                .preferred_credential_env_name = "CLAUDE_CODE_OAUTH_TOKEN",
            },
            .openai_codex => .{
                .label = "OpenAI Codex",
                .credential_env_names = &.{"CODEX_ACCESS_TOKEN"},
                .preferred_credential_env_name = "CODEX_ACCESS_TOKEN",
            },
            .xai_direct => .{
                .label = "xAI",
                .credential_env_names = &.{"XAI_API_KEY"},
                .preferred_credential_env_name = "XAI_API_KEY",
            },
        };
    }

    pub fn label(self: ProviderId) []const u8 {
        return self.metadata().label;
    }
};

pub const Metadata = struct {
    label: []const u8,
    /// Ordered from most preferred to least preferred.
    credential_env_names: []const []const u8,
    preferred_credential_env_name: []const u8,
};

pub const Route = struct {
    provider: ProviderId,
    /// Borrowed from the model passed to `routeForModel`.
    wire_model: []const u8,
};

pub fn routeForModel(model: []const u8) Route {
    const qualified = [_]struct {
        prefix: []const u8,
        provider: ProviderId,
    }{
        .{ .prefix = "anthropic-max/", .provider = .anthropic_max },
        .{ .prefix = "openai-codex/", .provider = .openai_codex },
        .{ .prefix = "xai-direct/", .provider = .xai_direct },
    };

    for (qualified) |candidate| {
        if (std.mem.startsWith(u8, model, candidate.prefix) and model.len > candidate.prefix.len) {
            return .{
                .provider = candidate.provider,
                .wire_model = model[candidate.prefix.len..],
            };
        }
    }

    return .{ .provider = .vercel_ai_gateway, .wire_model = model };
}

test "provider-qualified models select direct inference routes" {
    const cases = [_]struct {
        model: []const u8,
        provider: ProviderId,
        wire_model: []const u8,
    }{
        .{ .model = "anthropic-max/claude-opus-4-1", .provider = .anthropic_max, .wire_model = "claude-opus-4-1" },
        .{ .model = "openai-codex/gpt-5-codex", .provider = .openai_codex, .wire_model = "gpt-5-codex" },
        .{ .model = "xai-direct/grok-4", .provider = .xai_direct, .wire_model = "grok-4" },
    };

    for (cases) |case| {
        const route = routeForModel(case.model);
        try std.testing.expectEqual(case.provider, route.provider);
        try std.testing.expectEqualStrings(case.wire_model, route.wire_model);
    }
}

test "unqualified and legacy provider models stay on Vercel AI Gateway" {
    const models = [_][]const u8{
        "anthropic/claude-opus-4-1",
        "xai/grok-4",
        "openai/gpt-5",
        "custom-model",
        "",
        "anthropic-max/",
        "openai-codex/",
        "xai-direct/",
    };

    for (models) |model| {
        const route = routeForModel(model);
        try std.testing.expectEqual(ProviderId.vercel_ai_gateway, route.provider);
        try std.testing.expectEqualStrings(model, route.wire_model);
    }
}

test "provider metadata exposes labels and ordered credential preferences" {
    const gateway = ProviderId.vercel_ai_gateway.metadata();
    try std.testing.expectEqualStrings("Vercel AI Gateway", gateway.label);
    try std.testing.expectEqualStrings("VERCEL_OIDC_TOKEN", gateway.preferred_credential_env_name);
    try std.testing.expectEqualStrings(gateway.preferred_credential_env_name, gateway.credential_env_names[0]);

    const anthropic = ProviderId.anthropic_max.metadata();
    try std.testing.expectEqualStrings("Anthropic Max", ProviderId.anthropic_max.label());
    try std.testing.expectEqualStrings("CLAUDE_CODE_OAUTH_TOKEN", anthropic.preferred_credential_env_name);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", anthropic.credential_env_names[2]);

    const codex = ProviderId.openai_codex.metadata();
    try std.testing.expectEqualStrings("CODEX_ACCESS_TOKEN", codex.preferred_credential_env_name);
    try std.testing.expectEqual(@as(usize, 1), codex.credential_env_names.len);

    const xai = ProviderId.xai_direct.metadata();
    try std.testing.expectEqualStrings("XAI_API_KEY", xai.preferred_credential_env_name);
    try std.testing.expectEqual(@as(usize, 1), xai.credential_env_names.len);
}
