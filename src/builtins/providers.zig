const std = @import("std");

const stream_provider = @import("../core/agent/stream_provider.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const inference_provider = @import("../core/gateway/inference_provider.zig");
const builtin_gateway = @import("gateway.zig");
const direct_providers = @import("direct_providers.zig");

pub const agent_stream_provider = stream_provider.Provider{
    .build_fn = build,
    .stream_fn = stream,
};

pub const provider: gateway_provider.Provider = blk: {
    var value = builtin_gateway.provider;
    value.agent_stream = agent_stream_provider;
    break :blk value;
};

fn build(_: ?*anyopaque, alloc: std.mem.Allocator, request: stream_provider.BuildRequest) anyerror![]u8 {
    return switch (inference_provider.routeForModel(request.model).provider) {
        .vercel_ai_gateway => builtin_gateway.agent_stream_provider.build(alloc, request),
        .anthropic_max, .openai_codex, .xai_direct => direct_providers.agent_stream_provider.build(alloc, request),
    };
}

fn stream(_: ?*anyopaque, alloc: std.mem.Allocator, request: stream_provider.Request) anyerror!stream_provider.Result {
    return switch (inference_provider.routeForModel(request.model).provider) {
        .vercel_ai_gateway => builtin_gateway.agent_stream_provider.stream(alloc, request),
        .anthropic_max, .openai_codex, .xai_direct => direct_providers.agent_stream_provider.stream(alloc, request),
    };
}

test "router preserves Gateway routes and selects direct adapters" {
    const types = @import("../core/shared/types.zig");
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "hello" }};
    const common = stream_provider.BuildRequest{
        .model = "anthropic-max/claude-opus-4-1",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const direct = try agent_stream_provider.build(std.testing.allocator, common);
    defer std.testing.allocator.free(direct);
    try std.testing.expect(std.mem.find(u8, direct, "\"model\":\"claude-opus-4-1\"") != null);

    var gateway_request = common;
    gateway_request.model = "anthropic/claude-opus-4-1";
    const gateway = try agent_stream_provider.build(std.testing.allocator, gateway_request);
    defer std.testing.allocator.free(gateway);
    try std.testing.expect(std.mem.find(u8, gateway, "\"prompt\"") != null);
}
