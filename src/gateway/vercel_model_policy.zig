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
