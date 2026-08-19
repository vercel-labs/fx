const std = @import("std");

pub const chatgpt_subscription_prefix = "openai-codex/";
pub const default_chatgpt_subscription_model = chatgpt_subscription_prefix ++ "gpt-5.4";

pub fn isChatGptSubscriptionModel(model: []const u8) bool {
    return std.mem.startsWith(u8, model, chatgpt_subscription_prefix) and
        model.len > chatgpt_subscription_prefix.len;
}

pub fn upstreamModel(model: []const u8) ?[]const u8 {
    if (!isChatGptSubscriptionModel(model)) return null;
    return model[chatgpt_subscription_prefix.len..];
}

pub fn sourceLabel(model: []const u8) []const u8 {
    return if (isChatGptSubscriptionModel(model))
        "ChatGPT subscription"
    else
        "Vercel AI Gateway";
}

test "ChatGPT subscription model routing requires a non-empty upstream model" {
    try std.testing.expect(isChatGptSubscriptionModel("openai-codex/gpt-5.4"));
    try std.testing.expectEqualStrings("gpt-5.4", upstreamModel("openai-codex/gpt-5.4").?);
    try std.testing.expect(!isChatGptSubscriptionModel("openai-codex/"));
    try std.testing.expect(!isChatGptSubscriptionModel("openai/gpt-5.4"));
    try std.testing.expect(upstreamModel("openai/gpt-5.4") == null);
    try std.testing.expectEqualStrings("ChatGPT subscription", sourceLabel("openai-codex/gpt-5.4"));
    try std.testing.expectEqualStrings("Vercel AI Gateway", sourceLabel("openai/gpt-5.4"));
}
