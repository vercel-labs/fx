const std = @import("std");
const credentials = @import("credentials.zig");
const model_provider = @import("../config/model_provider.zig");

pub const ProviderSwitchDecision = enum {
    no_change,
    busy,
    prepare,
};

pub const ProviderSwitchIntent = enum {
    manual,
    post_oauth,
};

pub const ProviderSwitchFacts = struct {
    current: model_provider.ProviderId,
    target: model_provider.ProviderId,
    target_credential_ready: bool,
    intent: ProviderSwitchIntent,
    stream_active: bool,
    queued_prompts: usize,
};

pub fn decideProviderSwitch(facts: ProviderSwitchFacts) ProviderSwitchDecision {
    if (facts.intent == .manual and facts.current == facts.target and facts.target_credential_ready) {
        return .no_change;
    }
    if (facts.stream_active or facts.queued_prompts > 0) return .busy;
    return .prepare;
}

pub const LogoutFacts = struct {
    requested: ?model_provider.ProviderId,
    selected: model_provider.ProviderId,
    active_source: ?credentials.Source,
    available_sources: std.EnumSet(credentials.Source),
};

pub fn decideLogoutProvider(facts: LogoutFacts) model_provider.ProviderId {
    if (facts.requested) |provider| return provider;
    if (facts.selected == .opencode or facts.active_source == .opencode_api_key) return .opencode;
    if (facts.selected == .grok or facts.active_source == .grok_subscription) return .grok;
    if (facts.selected == .codex or facts.active_source == .chatgpt_subscription) return .codex;

    const only_grok_login = facts.available_sources.contains(.grok_subscription) and
        !facts.available_sources.contains(.fx_login) and
        !facts.available_sources.contains(.chatgpt_subscription);
    if (only_grok_login) return .grok;
    const only_codex_login = facts.available_sources.contains(.chatgpt_subscription) and
        !facts.available_sources.contains(.fx_login) and
        !facts.available_sources.contains(.grok_subscription);
    if (only_codex_login) return .codex;
    return .gateway;
}

pub const SignInCompletionAction = union(enum) {
    vercel,
    switch_provider: model_provider.ProviderId,
    activate_source: credentials.Source,
};

pub fn signInCompletion(
    provider: model_provider.ProviderId,
    provider_routing_supported: bool,
) SignInCompletionAction {
    return switch (provider) {
        .gateway => .vercel,
        .codex => if (provider_routing_supported)
            .{ .switch_provider = .codex }
        else
            .{ .activate_source = .chatgpt_subscription },
        .grok => if (provider_routing_supported)
            .{ .switch_provider = .grok }
        else
            .{ .activate_source = .grok_subscription },
        .opencode => if (provider_routing_supported)
            .{ .switch_provider = .opencode }
        else
            .{ .activate_source = .opencode_api_key },
    };
}

test "provider switch and logout decisions are pure and provider keyed" {
    try std.testing.expectEqual(ProviderSwitchDecision.no_change, decideProviderSwitch(.{
        .current = .codex,
        .target = .codex,
        .target_credential_ready = true,
        .intent = .manual,
        .stream_active = false,
        .queued_prompts = 0,
    }));
    try std.testing.expectEqual(ProviderSwitchDecision.busy, decideProviderSwitch(.{
        .current = .gateway,
        .target = .grok,
        .target_credential_ready = true,
        .intent = .manual,
        .stream_active = true,
        .queued_prompts = 0,
    }));

    var inventory: std.EnumSet(credentials.Source) = .empty;
    inventory.insert(.chatgpt_subscription);
    try std.testing.expectEqual(model_provider.ProviderId.codex, decideLogoutProvider(.{
        .requested = null,
        .selected = .gateway,
        .active_source = null,
        .available_sources = inventory,
    }));
    try std.testing.expectEqual(model_provider.ProviderId.grok, decideLogoutProvider(.{
        .requested = .grok,
        .selected = .codex,
        .active_source = .chatgpt_subscription,
        .available_sources = inventory,
    }));
}

test "sign in completion selects routing or credential activation without effects" {
    try std.testing.expectEqual(
        SignInCompletionAction{ .switch_provider = .codex },
        signInCompletion(.codex, true),
    );
    try std.testing.expectEqual(
        SignInCompletionAction{ .activate_source = .grok_subscription },
        signInCompletion(.grok, false),
    );
    try std.testing.expectEqual(SignInCompletionAction.vercel, signInCompletion(.gateway, true));
}
