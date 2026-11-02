const std = @import("std");
const model_capabilities = @import("../core/config/model_capabilities.zig");

pub fn capabilitiesForModel(model: []const u8) model_capabilities.Capabilities {
    var capabilities = model_capabilities.capabilitiesForModel(model);
    if (std.mem.startsWith(u8, model, "xai/")) {
        capabilities.parallel_tool_calls = true;
    }
    capabilities.context_window = contextWindowSize(model);
    return capabilities;
}

/// The cache markers fx sends for `model`. AI Gateway's automatic caching
/// covers every family; fx adds markers only where the provider honors them:
/// Anthropic models, and OpenAI GPT-5.6 and later through explicit
/// breakpoints.
pub fn cacheMarkers(model: []const u8) model_capabilities.CacheMarkers {
    if (std.mem.startsWith(u8, model, "anthropic/")) return .anthropic;
    if (takesPromptCacheOptions(model)) return .openai;
    return .none;
}

/// Whether `model` takes only one system message, at the start. Qwen's chat
/// template rejects a second one once a tool call is in the history ("System
/// message must be at the beginning").
pub fn singleSystemMessage(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "alibaba/");
}

/// Whether `model` takes OpenAI's `promptCacheOptions`: GPT-5.6 and later.
pub fn takesPromptCacheOptions(model: []const u8) bool {
    const prefix = "openai/gpt-";
    if (!std.mem.startsWith(u8, model, prefix)) return false;
    const version = model[prefix.len..];
    var end: usize = 0;
    while (end < version.len and std.ascii.isDigit(version[end])) end += 1;
    const major = std.fmt.parseUnsigned(u32, version[0..end], 10) catch return false;
    if (major != 5) return major > 5;
    if (end >= version.len or version[end] != '.') return false;
    var minor_end = end + 1;
    while (minor_end < version.len and std.ascii.isDigit(version[minor_end])) minor_end += 1;
    const minor = std.fmt.parseUnsigned(u32, version[end + 1 .. minor_end], 10) catch return false;
    return minor >= 6;
}

test "only GPT-5.6 and later take OpenAI prompt cache options" {
    for ([_][]const u8{ "openai/gpt-5.6-luna", "openai/gpt-5.6-sol", "openai/gpt-6-sol", "openai/gpt-6.1-sol", "openai/gpt-5.10" }) |model| {
        try std.testing.expect(takesPromptCacheOptions(model));
    }
    for ([_][]const u8{ "openai/gpt-5", "openai/gpt-5.5-pro", "openai/gpt-4o", "openai/gpt-oss-120b", "anthropic/claude-sonnet-5.5", "openai/gpt-", "openai/gpt-5." }) |model| {
        try std.testing.expect(!takesPromptCacheOptions(model));
    }
}

test "only Qwen models take their instructions as one system message" {
    try std.testing.expect(singleSystemMessage("alibaba/qwen3.8-max"));
    try std.testing.expect(singleSystemMessage("alibaba/qwen3.7-plus"));
    for ([_][]const u8{ "anthropic/claude-sonnet-5.5", "openai/gpt-6.1-sol", "spacexai/grok-4.7", "zai/glm-5.3", "moonshotai/kimi-k3", "google/gemini-4-argon", "deepseek/deepseek-v4.1-flash", "minimax/minimax-m3" }) |model| {
        try std.testing.expect(!singleSystemMessage(model));
    }
}

test "cache markers follow the model family" {
    try std.testing.expectEqual(.anthropic, cacheMarkers("anthropic/claude-sonnet-5.5"));
    try std.testing.expectEqual(.openai, cacheMarkers("openai/gpt-6.1-sol"));
    try std.testing.expectEqual(.openai, cacheMarkers("openai/gpt-5.6-luna"));
    for ([_][]const u8{ "openai/gpt-5", "openai/gpt-5.5-pro", "bedrock/anthropic.claude", "anthropic", "google/gemini-3-flash" }) |model| {
        try std.testing.expectEqual(.none, cacheMarkers(model));
    }
}

pub fn contextWindowSize(model: []const u8) ?u32 {
    if (std.mem.startsWith(u8, model, "anthropic/")) {
        const million_context_models = [_][]const u8{
            "anthropic/claude-fable-5",
            "anthropic/claude-opus-4.6",
            "anthropic/claude-opus-4-6",
            "anthropic/claude-opus-4.7",
            "anthropic/claude-opus-4-7",
            "anthropic/claude-opus-4.8",
            "anthropic/claude-opus-4-8",
            "anthropic/claude-sonnet-5",
            "anthropic/claude-sonnet-4.6",
            "anthropic/claude-sonnet-4-6",
        };
        for (million_context_models) |candidate| {
            if (std.mem.eql(u8, model, candidate)) return 1_000_000;
        }
        return 200_000;
    }
    if (std.mem.startsWith(u8, model, "openai/")) {
        if (containsIgnoreCase(model, "gpt-5")) return 256_000;
        if (containsIgnoreCase(model, "o3") or
            containsIgnoreCase(model, "o4") or
            containsIgnoreCase(model, "o1")) return 200_000;
        return 128_000;
    }
    if (std.mem.startsWith(u8, model, "xai/")) return 131_072;
    if (std.mem.startsWith(u8, model, "google/")) return 1_000_000;
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const last_start = haystack.len - needle.len;
    var index: usize = 0;
    while (index <= last_start) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

test "Vercel fallback policy owns vendor model heuristics" {
    try std.testing.expect(!capabilitiesForModel("moonshotai/kimi-k3").intrinsic_fast);
    try std.testing.expect(capabilitiesForModel("moonshotai/kimi-k3-fast").intrinsic_fast);
    try std.testing.expect(capabilitiesForModel("anthropic/claude-opus-4.8-fast").intrinsic_fast);
    try std.testing.expect(!capabilitiesForModel("moonshotai/kimi-k3-fast").supports_fast_mode);
    try std.testing.expectEqual(@as(?u32, 1_000_000), contextWindowSize("anthropic/claude-opus-4.8"));
    try std.testing.expectEqual(@as(?bool, true), capabilitiesForModel("xai/grok-4").parallel_tool_calls);
}
