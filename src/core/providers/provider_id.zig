const std = @import("std");

pub const Id = enum {
    vercel_ai_gateway,
    opencode_go,
};

pub const opencode_go_prefix = "opencode-go/";

pub fn fromModel(model: []const u8) Id {
    return if (std.mem.startsWith(u8, model, opencode_go_prefix)) .opencode_go else .vercel_ai_gateway;
}

pub fn upstreamModel(model: []const u8) []const u8 {
    return if (fromModel(model) == .opencode_go) model[opencode_go_prefix.len..] else model;
}

test "OpenCode Go models keep a provider namespace" {
    try std.testing.expectEqual(Id.opencode_go, fromModel("opencode-go/deepseek-v4-flash"));
    try std.testing.expectEqualStrings("deepseek-v4-flash", upstreamModel("opencode-go/deepseek-v4-flash"));
    try std.testing.expectEqual(Id.vercel_ai_gateway, fromModel("openai/gpt-5.6"));
}
