const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_provider = @import("../core/config/model_provider.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");

const Route = enum {
    gateway,
    openai_codex,
};

pub const agent_stream_provider = stream_provider.Provider{
    .build_fn = build,
    .stream_fn = stream,
};

fn routeForModel(model: []const u8) Route {
    return if (model_provider.isChatGptSubscriptionModel(model)) .openai_codex else .gateway;
}

fn authorizedRoute(model: []const u8, source: ?credentials.Source) !Route {
    return switch (routeForModel(model)) {
        .openai_codex => if (source == .chatgpt_subscription)
            .openai_codex
        else
            error.ChatGptSubscriptionCredentialRequired,
        .gateway => if (source == .chatgpt_subscription)
            error.ChatGptCredentialCannotAuthorizeGateway
        else
            .gateway,
    };
}

fn build(_: ?*anyopaque, alloc: std.mem.Allocator, request: stream_provider.BuildRequest) ![]u8 {
    const provider = switch (routeForModel(request.model)) {
        .gateway => gateway.agent_stream_provider,
        .openai_codex => openai_codex.agent_stream_provider,
    };
    return provider.build(alloc, request);
}

fn stream(_: ?*anyopaque, alloc: std.mem.Allocator, request: stream_provider.Request) !stream_provider.Result {
    const provider = switch (try authorizedRoute(request.model, request.credential_source)) {
        .gateway => gateway.agent_stream_provider,
        .openai_codex => openai_codex.agent_stream_provider,
    };
    return provider.stream(alloc, request);
}

test "provider router keeps ChatGPT and Gateway credentials on their own origins" {
    try std.testing.expectEqual(Route.openai_codex, try authorizedRoute(
        "openai-codex/gpt-5.4",
        .chatgpt_subscription,
    ));
    try std.testing.expectEqual(Route.gateway, try authorizedRoute(
        "openai/gpt-5.4",
        .ai_gateway_api_key,
    ));
    try std.testing.expectError(
        error.ChatGptSubscriptionCredentialRequired,
        authorizedRoute("openai-codex/gpt-5.4", .fx_login),
    );
    try std.testing.expectError(
        error.ChatGptCredentialCannotAuthorizeGateway,
        authorizedRoute("openai/gpt-5.4", .chatgpt_subscription),
    );
}
