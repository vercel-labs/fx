const std = @import("std");
const model_capabilities = @import("../../core/config/model_capabilities.zig");
const model_catalog = @import("../../core/gateway/model_catalog.zig");
const types = @import("../../core/shared/types.zig");

const AnthropicModel = enum {
    fable_5,
    opus_46,
    opus_47,
    opus_48,
    sonnet_5,
    sonnet_46,
    other,
};

pub const provider = model_catalog.ModelDescriptorProvider{
    .fallback_fn = fallback,
    .catalog_fn = fromCatalog,
};

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

fn providerName(model: []const u8) []const u8 {
    const slash = std.mem.findScalar(u8, model, '/') orelse return "";
    return if (slash == 0) "" else model[0..slash];
}

fn classifyAnthropicModel(model: []const u8) AnthropicModel {
    if (std.mem.eql(u8, model, "anthropic/claude-fable-5")) return .fable_5;
    if (std.mem.eql(u8, model, "anthropic/claude-opus-4.6") or
        std.mem.eql(u8, model, "anthropic/claude-opus-4-6")) return .opus_46;
    if (std.mem.eql(u8, model, "anthropic/claude-opus-4.7") or
        std.mem.eql(u8, model, "anthropic/claude-opus-4-7")) return .opus_47;
    if (std.mem.eql(u8, model, "anthropic/claude-opus-4.8") or
        std.mem.eql(u8, model, "anthropic/claude-opus-4-8")) return .opus_48;
    if (std.mem.eql(u8, model, "anthropic/claude-sonnet-5")) return .sonnet_5;
    if (std.mem.eql(u8, model, "anthropic/claude-sonnet-4.6") or
        std.mem.eql(u8, model, "anthropic/claude-sonnet-4-6")) return .sonnet_46;
    return .other;
}

fn contextWindow(model: []const u8) ?u32 {
    if (std.mem.startsWith(u8, model, "anthropic/")) {
        return switch (classifyAnthropicModel(model)) {
            .fable_5, .opus_46, .opus_47, .opus_48, .sonnet_5, .sonnet_46 => 1_000_000,
            .other => 200_000,
        };
    }
    if (std.mem.startsWith(u8, model, "openai/")) {
        if (containsIgnoreCase(model, "gpt-5")) return 256_000;
        if (containsIgnoreCase(model, "o1") or containsIgnoreCase(model, "o3") or containsIgnoreCase(model, "o4")) return 200_000;
        return 128_000;
    }
    if (std.mem.startsWith(u8, model, "xai/")) return 131_072;
    if (std.mem.startsWith(u8, model, "google/")) return 1_000_000;
    return null;
}

fn fallback(_: ?*anyopaque, selected_model: []const u8) model_capabilities.ModelDescriptor {
    var capabilities: model_capabilities.Capabilities = if (std.mem.startsWith(u8, selected_model, "anthropic/"))
        .{ .prompt_caching = true }
    else if (std.mem.startsWith(u8, selected_model, "xai/"))
        .{ .parallel_tool_calls = true }
    else
        .{};
    capabilities.context_window = contextWindow(selected_model);

    return .{
        .id = selected_model,
        .display_name = selected_model,
        .provider = providerName(selected_model),
        .capabilities = capabilities,
        .source = .@"adapter-static",
    };
}

fn fromCatalog(_: ?*anyopaque, entry: model_catalog.ModelCatalogEntry) model_capabilities.ModelDescriptor {
    var descriptor = fallback(null, entry.id);
    var capabilities = descriptor.capabilities;
    capabilities.supports_reasoning = entry.has_reasoning or entry.reasoning_efforts.items.len > 0;
    capabilities.reasoning_efforts = .fromSlice(entry.reasoning_efforts.items);
    capabilities.supports_fast_mode = entry.supports_fast_mode;
    capabilities.supports_tool_use = capabilities.supports_tool_use or entry.has_tool_use;
    capabilities.supports_vision = capabilities.supports_vision or entry.has_vision;
    capabilities.supports_file_input = capabilities.supports_file_input or entry.has_file_input;
    capabilities.supports_web_search = capabilities.supports_web_search or entry.has_web_search;
    capabilities.supports_explicit_caching = capabilities.supports_explicit_caching or entry.has_explicit_caching;
    capabilities.supports_implicit_caching = capabilities.supports_implicit_caching or entry.has_implicit_caching;
    if (entry.context_window != 0) capabilities.context_window = entry.context_window;
    if (entry.max_tokens != 0) capabilities.max_output_tokens = entry.max_tokens;
    descriptor.capabilities = capabilities;
    descriptor.source = .catalog;
    return descriptor;
}

test "Vercel static descriptors preserve exact identity and non-control policy" {
    const gpt56 = provider.fallback("openai/gpt-5.6-sol");
    try std.testing.expectEqual(model_capabilities.CapabilitySource.@"adapter-static", gpt56.source);
    try std.testing.expectEqualStrings("openai/gpt-5.6-sol", gpt56.id);
    try std.testing.expectEqual(@as(usize, 0), gpt56.capabilities.reasoning_efforts.len);
    try std.testing.expect(!gpt56.capabilities.supports_fast_mode);
    try std.testing.expectEqual(@as(?u32, 256_000), gpt56.capabilities.context_window);

    const opus = provider.fallback("anthropic/claude-opus-4.8");
    try std.testing.expect(opus.capabilities.prompt_caching);
    try std.testing.expectEqual(@as(?u32, 1_000_000), opus.capabilities.context_window);

    const glm_fast = provider.fallback("zai/glm-5.2-fast");
    try std.testing.expectEqualStrings("zai/glm-5.2-fast", glm_fast.id);
    try std.testing.expect(!glm_fast.selected_fast_mode);
}

test "Vercel catalog descriptors compose live controls over static fallback" {
    var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    defer efforts.deinit(std.testing.allocator);
    try efforts.append(std.testing.allocator, types.ReasoningEffort.literal("future-tier"));
    const entry = model_catalog.ModelCatalogEntry{
        .id = @constCast("provider/new-reasoning-model"),
        .model_type = @constCast("language"),
        .has_reasoning = true,
        .reasoning_efforts = efforts,
        .supports_fast_mode = true,
        .has_tool_use = true,
        .has_vision = true,
        .context_window = 750_000,
        .max_tokens = 64_000,
    };
    const descriptor = provider.catalog(entry);
    try std.testing.expectEqual(model_capabilities.CapabilitySource.catalog, descriptor.source);
    try std.testing.expect(descriptor.capabilities.supports_reasoning);
    try std.testing.expect(descriptor.capabilities.supports_tool_use);
    try std.testing.expect(descriptor.capabilities.supports_vision);
    try std.testing.expect(model_capabilities.reasoningEffortSupported(descriptor.capabilities, types.ReasoningEffort.literal("future-tier")));
    try std.testing.expect(!model_capabilities.reasoningEffortSupported(descriptor.capabilities, types.ReasoningEffort.literal("stale")));
    try std.testing.expect(descriptor.capabilities.supports_fast_mode);
    try std.testing.expectEqual(@as(?u32, 750_000), descriptor.capabilities.context_window);
    try std.testing.expectEqual(@as(?u32, 64_000), descriptor.capabilities.max_output_tokens);
}

test "Vercel static fallback keeps local non-control capabilities" {
    try std.testing.expectEqual(@as(?bool, true), provider.fallback("xai/grok-3").capabilities.parallel_tool_calls);
    try std.testing.expectEqual(@as(?u32, 131_072), provider.fallback("xai/grok-3").capabilities.context_window);
    try std.testing.expectEqual(@as(?u32, 1_000_000), provider.fallback("google/gemini-2.0").capabilities.context_window);
    try std.testing.expectEqual(@as(?u32, null), provider.fallback("unknown/model").capabilities.context_window);
}
