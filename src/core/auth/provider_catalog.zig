const std = @import("std");
const model_provider = @import("../config/model_provider.zig");
const types = @import("../shared/types.zig");
const provider_registry = @import("../config/provider_registry.zig");

pub const Entry = struct {
    id: model_provider.ProviderId,
    slug: []const u8,
    aliases: []const []const u8 = &.{},
    name: []const u8,
    route_name: []const u8,
    description: []const u8,
    subscription: bool,
    login_source: types.CredentialSource,
};

pub const entries = [_]Entry{
    .{
        .id = .gateway,
        .slug = "vercel",
        .aliases = &.{ "gateway", "ai-gateway" },
        .name = "Vercel AI Gateway",
        .route_name = "Vercel AI Gateway",
        .description = "Vercel account or AI Gateway billing",
        .subscription = false,
        .login_source = .fx_login,
    },
    .{
        .id = .codex,
        .slug = "codex",
        .name = "Codex",
        .route_name = "Codex subscription",
        .description = "ChatGPT Plus, Pro, Business, Enterprise, or Edu subscription",
        .subscription = true,
        .login_source = .chatgpt_subscription,
    },
    .{
        .id = .grok,
        .slug = "grok",
        .name = "Grok",
        .route_name = "Grok subscription",
        .description = "SuperGrok or X Premium subscription",
        .subscription = true,
        .login_source = .grok_subscription,
    },
};

/// Built-in configured providers that `/login` signs in to (D145).
pub const preset_entries = blk: {
    @setEvalBranchQuota(20_000);
    var list: [provider_registry.presets.len]Entry = undefined;
    for (provider_registry.presets, &list) |preset, *entry| entry.* = .{
        .id = model_provider.parse(preset.id).?,
        .slug = preset.id,
        .name = preset.name,
        .route_name = preset.name,
        .description = preset.description,
        .subscription = false,
        .login_source = .configured,
    };
    break :blk list;
};

pub fn parse(value: []const u8) ?model_provider.ProviderId {
    for (&entries) |*entry| {
        if (std.ascii.eqlIgnoreCase(value, entry.slug)) return entry.id;
        for (entry.aliases) |alias| if (std.ascii.eqlIgnoreCase(value, alias)) return entry.id;
    }
    for (&preset_entries) |*entry| if (std.ascii.eqlIgnoreCase(value, entry.slug)) return entry.id;
    return null;
}

const configured_entry = Entry{
    .id = model_provider.parse("configured").?,
    .slug = "configured",
    .name = "Configured provider",
    .route_name = "Configured provider",
    .description = "Endpoint and authentication from profile settings",
    .subscription = false,
    .login_source = .configured,
};

pub fn find(id: model_provider.ProviderId) *const Entry {
    if (id == .configured) {
        for (&preset_entries) |*entry| if (std.mem.eql(u8, entry.slug, id.label())) return entry;
        return &configured_entry;
    }
    for (&entries) |*entry| if (entry.id.eql(id)) return entry;
    unreachable;
}

pub fn label(id: model_provider.ProviderId) []const u8 {
    return find(id).route_name;
}

test "auth provider catalog uses the model provider identity and explicit aliases" {
    try std.testing.expectEqual(model_provider.ProviderId.gateway, parse("vercel").?);
    try std.testing.expectEqual(model_provider.ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(model_provider.ProviderId.codex, parse("codex").?);
    try std.testing.expectEqual(model_provider.ProviderId.grok, parse("grok").?);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("chatgpt") == null);
    try std.testing.expect(parse("unknown") == null);
    try std.testing.expect(find(.codex).subscription);
    const router = parse("OpenRouter").?;
    try std.testing.expectEqualStrings("openrouter", router.label());
    try std.testing.expectEqualStrings("OpenRouter", find(router).name);
    try std.testing.expectEqualStrings("OpenCode Zen", label(parse("opencode-zen").?));
    try std.testing.expectEqualStrings("Configured provider", label(model_provider.parse("local").?));
    try std.testing.expect(find(.grok).subscription);
}
