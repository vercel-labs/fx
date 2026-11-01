const std = @import("std");
const types = @import("../shared/types.zig");
const model_provider = @import("model_provider.zig");
const image_route = @import("../images/image_route.zig");

/// The provider syntax for the cache markers on messages flagged with
/// `ChatMessage.cache_breakpoint`.
pub const CacheMarkers = enum { none, anthropic, openai };

pub const ResolvedProviderOptions = struct {
    reasoning: ?types.ReasoningEffort = null,
    fast: bool = false,
    ultrafast: bool = false,
    parallel_tool_calls: ?bool = null,
    prompt_caching: bool = false,
    /// Marker syntax for flagged messages; written only with
    /// `prompt_caching`. `none` writes no markers.
    cache_markers: CacheMarkers = .none,
    /// Asks OpenAI GPT-5.6 and later to write no prompt-cache entries
    /// (explicit cache mode with no breakpoints), for a request whose prefix
    /// no later request shares. Such a model otherwise writes the whole
    /// prompt at the cache-write price on every call.
    skip_cache_writes: bool = false,
    /// The model takes one system message, at the start of the conversation,
    /// so the Gateway request joins the leading system messages into one.
    single_system_message: bool = false,
    /// Borrowed gateway provider slugs in preference order. Empty leaves
    /// provider selection to the gateway. The backing memory must outlive
    /// request-body serialization.
    provider_order: []const []const u8 = &.{},
    /// Sends `provider_order` as the gateway's hard `only` restriction
    /// instead of its `order` preference.
    provider_strict: bool = false,
};

pub const ReasoningEffortOptions = struct {
    values: [types.ReasoningEffort.max_options]types.ReasoningEffort = undefined,
    len: usize = 0,

    pub fn fromSlice(source: []const types.ReasoningEffort) ReasoningEffortOptions {
        var result: ReasoningEffortOptions = .{};
        result.len = @min(source.len, result.values.len);
        for (source[0..result.len], 0..) |value, index| result.values[index] = value;
        return result;
    }

    pub fn slice(self: *const ReasoningEffortOptions) []const types.ReasoningEffort {
        return self.values[0..self.len];
    }
};

pub const ImageInputSupport = image_route.Support;

pub const GatewayMetadata = struct {
    supports_reasoning: bool = false,
    reasoning_efforts: ReasoningEffortOptions = .{},
    supports_fast_mode: bool = false,
    supports_ultrafast_mode: bool = false,
    supports_tool_use: bool = false,
    supports_vision: bool = false,
    supports_file_input: bool = false,
    supports_web_search: bool = false,
    supports_explicit_caching: bool = false,
    supports_implicit_caching: bool = false,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

pub const Capabilities = struct {
    supports_reasoning: bool = false,
    reasoning_efforts: ReasoningEffortOptions = .{},
    supports_fast_mode: bool = false,
    supports_ultrafast_mode: bool = false,
    intrinsic_fast: bool = false,
    supports_tool_use: bool = false,
    supports_vision: bool = false,
    supports_file_input: bool = false,
    image_input_support: ImageInputSupport = .unknown,
    supports_web_search: bool = false,
    supports_explicit_caching: bool = false,
    supports_implicit_caching: bool = false,
    parallel_tool_calls: ?bool = null,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

pub const ResolveError = error{Cancelled};

pub const Resolver = struct {
    ctx: *anyopaque,
    resolve_fn: *const fn (
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        model: []const u8,
    ) ResolveError!Capabilities,

    pub fn resolve(self: Resolver, arena: std.mem.Allocator, model: []const u8) ResolveError!Capabilities {
        return self.resolve_fn(self.ctx, arena, model);
    }
};

pub fn mergeCapabilities(capabilities_value: Capabilities, gateway_metadata: ?GatewayMetadata) Capabilities {
    var capabilities = capabilities_value;
    if (gateway_metadata) |metadata| {
        capabilities.supports_reasoning = metadata.supports_reasoning or metadata.reasoning_efforts.len > 0;
        capabilities.reasoning_efforts = metadata.reasoning_efforts;
        capabilities.supports_fast_mode = metadata.supports_fast_mode;
        capabilities.supports_ultrafast_mode = metadata.supports_ultrafast_mode;
        capabilities.supports_tool_use = metadata.supports_tool_use;
        capabilities.supports_vision = metadata.supports_vision;
        capabilities.supports_file_input = metadata.supports_file_input;
        capabilities.image_input_support = image_route.supportFromCatalog(.{ .listed = .{
            .vision = metadata.supports_vision,
            .file_input = metadata.supports_file_input,
        } });
        capabilities.supports_web_search = metadata.supports_web_search;
        capabilities.supports_explicit_caching = metadata.supports_explicit_caching;
        capabilities.supports_implicit_caching = metadata.supports_implicit_caching;
        if (metadata.context_window) |window| capabilities.context_window = window;
        if (metadata.max_output_tokens) |tokens| capabilities.max_output_tokens = tokens;
    }
    return capabilities;
}

pub fn resolveCapabilities(model: []const u8, gateway_metadata: ?GatewayMetadata) Capabilities {
    return mergeCapabilities(capabilitiesForModel(model), gateway_metadata);
}

pub fn capabilitiesForModel(model: []const u8) Capabilities {
    return .{ .intrinsic_fast = std.mem.endsWith(u8, model, "-fast") };
}

pub fn resolveForApp(comptime App: type, app: *App, model: []const u8) Capabilities {
    const generic = capabilitiesForModel(model);
    var capabilities = if (comptime @hasDecl(App, "resolvedModelCapabilities"))
        app.resolvedModelCapabilities(model)
    else
        generic;
    capabilities.intrinsic_fast = capabilities.intrinsic_fast or generic.intrinsic_fast;
    return capabilities;
}

// A catalog output limit that fills the whole context window cannot bound a real request, and
// omitting the limit lets some providers stop replies at a few thousand tokens.
const full_window_output_tokens: u32 = 32_768;
const full_window_output_divisor: u32 = 8;

/// The output limit for the one retry of a reply the provider cut short before
/// any text, when the first request set no limit and the provider's default ran
/// out. A known context window bounds it as it bounds a full-window limit; null
/// when that leaves no room.
pub fn emptyLengthRetryOutputTokens(capabilities: Capabilities) ?u32 {
    const window = capabilities.context_window orelse return full_window_output_tokens;
    const bounded = @min(full_window_output_tokens, window / full_window_output_divisor);
    return if (bounded == 0) null else bounded;
}

test "empty length retry limit stays inside a known context window" {
    try std.testing.expectEqual(@as(?u32, 32_768), emptyLengthRetryOutputTokens(.{}));
    try std.testing.expectEqual(@as(?u32, 32_768), emptyLengthRetryOutputTokens(.{ .context_window = 1_000_000 }));
    try std.testing.expectEqual(@as(?u32, 8_192), emptyLengthRetryOutputTokens(.{ .context_window = 65_536 }));
    try std.testing.expectEqual(@as(?u32, null), emptyLengthRetryOutputTokens(.{ .context_window = 7 }));
}

/// The effort for the one resend of a reply that spent its whole output limit
/// with nothing usable: `low` when the model offers it below the effort the
/// request used, so the resend reasons less; null resends at the same effort.
/// An effort the model does not list was never sent, so that request used the
/// model's default.
pub fn lengthResendEffort(capabilities: Capabilities, current: types.ReasoningEffort) ?types.ReasoningEffort {
    const low = types.ReasoningEffort.literal("low");
    const low_index = reasoningEffortIndex(capabilities, low);
    if (low_index == 0) return null;
    const current_index = reasoningEffortIndex(capabilities, current);
    return if (current_index == 0 or low_index < current_index) low else null;
}

test "length resend lowers effort to low only when that reasons less" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("none"),
        types.ReasoningEffort.literal("minimal"),
        types.ReasoningEffort.literal("low"),
        types.ReasoningEffort.literal("high"),
    };
    const caps = Capabilities{ .reasoning_efforts = .fromSlice(&efforts) };
    const low = types.ReasoningEffort.literal("low");
    const cases = [_]struct { current: types.ReasoningEffort, expected: ?types.ReasoningEffort }{
        .{ .current = .auto, .expected = low },
        .{ .current = types.ReasoningEffort.literal("high"), .expected = low },
        .{ .current = types.ReasoningEffort.literal("unlisted"), .expected = low },
        .{ .current = low, .expected = null },
        .{ .current = types.ReasoningEffort.literal("minimal"), .expected = null },
        .{ .current = types.ReasoningEffort.literal("none"), .expected = null },
    };
    for (cases) |case| {
        const got = lengthResendEffort(caps, case.current);
        if (case.expected) |expected| {
            try std.testing.expect(got != null and got.?.eql(expected));
        } else {
            try std.testing.expectEqual(@as(?types.ReasoningEffort, null), got);
        }
    }

    const without_low = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("medium"),
        types.ReasoningEffort.literal("high"),
    };
    try std.testing.expectEqual(@as(?types.ReasoningEffort, null), lengthResendEffort(.{ .reasoning_efforts = .fromSlice(&without_low) }, .auto));
    try std.testing.expectEqual(@as(?types.ReasoningEffort, null), lengthResendEffort(.{}, .auto));
}

/// Output tokens to request and reserve for one model call, or null to leave the limit unset.
pub fn requestOutputTokens(capabilities: Capabilities) ?u32 {
    const advertised = capabilities.max_output_tokens orelse return null;
    const window = capabilities.context_window orelse return advertised;
    if (advertised < window) return advertised;
    return @min(full_window_output_tokens, window / full_window_output_divisor);
}

test "request output limit bounds full-window catalog limits" {
    const cases = [_]struct {
        capabilities: Capabilities,
        expected: ?u32,
    }{
        .{ .capabilities = .{}, .expected = null },
        .{ .capabilities = .{ .max_output_tokens = 32_000 }, .expected = 32_000 },
        .{ .capabilities = .{ .context_window = 256_000 }, .expected = null },
        .{ .capabilities = .{ .context_window = 256_000, .max_output_tokens = 32_000 }, .expected = 32_000 },
        .{ .capabilities = .{ .context_window = 1_000_000, .max_output_tokens = 1_000_000 }, .expected = 32_768 },
        .{ .capabilities = .{ .context_window = 131_072, .max_output_tokens = 131_072 }, .expected = 16_384 },
        .{ .capabilities = .{ .context_window = 128_000, .max_output_tokens = 256_000 }, .expected = 16_000 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, requestOutputTokens(case.capabilities));
    }
}

pub fn reasoningEffortSupported(capabilities: Capabilities, effort: types.ReasoningEffort) bool {
    if (effort.isDefault()) return true;
    for (capabilities.reasoning_efforts.slice()) |option| {
        if (option.eql(effort)) return true;
    }
    return false;
}

pub fn reasoningEffortIndex(capabilities: Capabilities, effort: types.ReasoningEffort) usize {
    if (effort.isDefault()) return 0;
    for (capabilities.reasoning_efforts.slice(), 0..) |option, i| {
        if (option.eql(effort)) return i + 1;
    }
    return 0;
}

pub fn reasoningEffortAtIndex(capabilities: Capabilities, index: usize) types.ReasoningEffort {
    if (index == 0 or capabilities.reasoning_efforts.len == 0) return .auto;
    return capabilities.reasoning_efforts.values[(index - 1) % capabilities.reasoning_efforts.len];
}

pub fn reasoningEffortLabelAtIndex(capabilities: *const Capabilities, index: usize) []const u8 {
    if (index == 0 or capabilities.reasoning_efforts.len == 0) return "default";
    return capabilities.reasoning_efforts.values[(index - 1) % capabilities.reasoning_efforts.len].displayLabel();
}

pub fn reasoningEffortOptionCount(capabilities: Capabilities) usize {
    return if (capabilities.reasoning_efforts.len == 0) 0 else capabilities.reasoning_efforts.len + 1;
}

pub fn resolveProviderOptionsForCapabilities(
    capabilities: Capabilities,
    effort: types.ReasoningEffort,
    fast_mode: bool,
) ResolvedProviderOptions {
    var resolved: ResolvedProviderOptions = .{
        .parallel_tool_calls = capabilities.parallel_tool_calls,
    };
    if (!effort.isDefault() and reasoningEffortSupported(capabilities, effort)) {
        resolved.reasoning = effort;
    }
    resolved.fast = fast_mode and capabilities.supports_fast_mode;
    return resolved;
}

/// Ultrafast is an explicit, catalog-verified OpenAI Gateway opt-in. Unlike Fast,
/// unsupported or unknown capabilities must not silently downgrade before sending.
pub fn resolveUltrafastProviderOptions(
    capabilities: Capabilities,
    provider: model_provider.ProviderId,
    model: []const u8,
    effort: types.ReasoningEffort,
    fast_mode: bool,
    ultrafast_mode: bool,
) error{UltrafastUnavailable}!ResolvedProviderOptions {
    var options = resolveProviderOptionsForCapabilities(capabilities, effort, fast_mode);
    if (!ultrafast_mode) return options;
    if (provider != .gateway or !std.mem.startsWith(u8, model, "openai/") or !capabilities.supports_ultrafast_mode) {
        return error.UltrafastUnavailable;
    }
    options.fast = false;
    options.ultrafast = true;
    return options;
}

test "Ultrafast requires explicit opt-in and verified OpenAI Gateway capability" {
    const caps = Capabilities{ .supports_fast_mode = true, .supports_ultrafast_mode = true };
    const normal = try resolveUltrafastProviderOptions(caps, .gateway, "openai/gpt-6-astra", .auto, true, false);
    try std.testing.expect(normal.fast and !normal.ultrafast);
    const ultra = try resolveUltrafastProviderOptions(caps, .gateway, "openai/gpt-6-astra", .auto, true, true);
    try std.testing.expect(ultra.ultrafast and !ultra.fast);
    try std.testing.expectError(error.UltrafastUnavailable, resolveUltrafastProviderOptions(.{}, .gateway, "openai/gpt-6-astra", .auto, false, true));
    try std.testing.expectError(error.UltrafastUnavailable, resolveUltrafastProviderOptions(caps, .codex, "openai/gpt-6-astra", .auto, false, true));
    try std.testing.expectError(error.UltrafastUnavailable, resolveUltrafastProviderOptions(caps, .gateway, "anthropic/model", .auto, false, true));
}

test "capabilities infer intrinsic fast identity but not controls from model IDs" {
    const models = [_]struct { id: []const u8, intrinsic_fast: bool }{
        .{ .id = "openai/gpt-5.6-sol", .intrinsic_fast = false },
        .{ .id = "anthropic/claude-opus-4.8", .intrinsic_fast = false },
        .{ .id = "zai/glm-5.2", .intrinsic_fast = false },
        .{ .id = "zai/glm-5.2-fast", .intrinsic_fast = true },
        .{ .id = "provider/breakfast", .intrinsic_fast = false },
    };
    for (models) |model| {
        const capabilities = capabilitiesForModel(model.id);
        try std.testing.expectEqual(@as(usize, 0), capabilities.reasoning_efforts.len);
        try std.testing.expect(!capabilities.supports_fast_mode);
        try std.testing.expectEqual(model.intrinsic_fast, capabilities.intrinsic_fast);
    }
}

test "resolveForApp adds intrinsic fast identity to provider capabilities" {
    const App = struct {
        pub fn resolvedModelCapabilities(_: *@This(), _: []const u8) Capabilities {
            return .{};
        }
    };
    var app = App{};

    try std.testing.expect(resolveForApp(App, &app, "provider/model-fast").intrinsic_fast);
    try std.testing.expect(!resolveForApp(App, &app, "provider/model-default").intrinsic_fast);
}

test "mergeCapabilities preserves provider controls and supplied fallback policy" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("future-tier"),
        types.ReasoningEffort.literal("high"),
    };
    const capabilities = mergeCapabilities(.{ .intrinsic_fast = true }, .{
        .reasoning_efforts = .fromSlice(&efforts),
        .supports_fast_mode = true,
        .supports_tool_use = true,
        .supports_vision = true,
        .supports_file_input = true,
        .supports_web_search = true,
        .supports_explicit_caching = true,
        .supports_implicit_caching = true,
        .context_window = 300_000,
        .max_output_tokens = 32_000,
    });

    try std.testing.expect(capabilities.supports_reasoning);
    try std.testing.expect(capabilities.intrinsic_fast);
    try std.testing.expectEqual(@as(usize, 2), capabilities.reasoning_efforts.len);
    try std.testing.expectEqualStrings("future-tier", capabilities.reasoning_efforts.values[0].label());
    try std.testing.expect(capabilities.supports_fast_mode);
    try std.testing.expect(capabilities.supports_tool_use);
    try std.testing.expect(capabilities.supports_vision);
    try std.testing.expect(capabilities.supports_file_input);
    try std.testing.expect(capabilities.supports_web_search);
    try std.testing.expect(capabilities.supports_explicit_caching);
    try std.testing.expect(capabilities.supports_implicit_caching);
    try std.testing.expectEqual(@as(?u32, 300_000), capabilities.context_window);
    try std.testing.expectEqual(@as(?u32, 32_000), capabilities.max_output_tokens);
}

test "image input support distinguishes unknown native and non native capability" {
    try std.testing.expectEqual(
        ImageInputSupport.unknown,
        capabilitiesForModel("provider/unknown").image_input_support,
    );

    for ([_]bool{ false, true }) |file_input| {
        const native = mergeCapabilities(.{}, .{
            .supports_vision = true,
            .supports_file_input = file_input,
        });
        try std.testing.expectEqual(ImageInputSupport.native, native.image_input_support);

        const non_native = mergeCapabilities(.{}, .{
            .supports_vision = false,
            .supports_file_input = file_input,
        });
        try std.testing.expectEqual(ImageInputSupport.non_native, non_native.image_input_support);
    }
}

test "reasoning effort picker helpers prepend default and preserve Gateway order" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("future-tier"),
        types.ReasoningEffort.literal("high"),
    };
    const capabilities = Capabilities{ .reasoning_efforts = .fromSlice(&efforts) };

    try std.testing.expectEqual(@as(usize, 3), reasoningEffortOptionCount(capabilities));
    try std.testing.expect(reasoningEffortAtIndex(capabilities, 0).isDefault());
    try std.testing.expectEqualStrings("future-tier", reasoningEffortLabelAtIndex(&capabilities, 1));
    try std.testing.expectEqualStrings("high", reasoningEffortLabelAtIndex(&capabilities, 2));
    try std.testing.expectEqual(@as(usize, 1), reasoningEffortIndex(capabilities, types.ReasoningEffort.literal("future-tier")));
    try std.testing.expectEqual(@as(usize, 0), reasoningEffortIndex(capabilities, types.ReasoningEffort.literal("stale")));
}

test "request controls form a total fail-closed state machine" {
    const declared_efforts = [_]types.ReasoningEffort{types.ReasoningEffort.literal("future-tier")};
    const selected = types.ReasoningEffort.literal("future-tier");
    const stale = types.ReasoningEffort.literal("stale");
    const cases = [_]struct {
        capabilities: Capabilities,
        effort: types.ReasoningEffort,
        fast_mode: bool,
        expected_effort: ?[]const u8,
        expected_fast: bool,
    }{
        .{ .capabilities = .{}, .effort = .auto, .fast_mode = false, .expected_effort = null, .expected_fast = false },
        .{ .capabilities = .{}, .effort = selected, .fast_mode = true, .expected_effort = null, .expected_fast = false },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts) }, .effort = .auto, .fast_mode = false, .expected_effort = null, .expected_fast = false },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts) }, .effort = selected, .fast_mode = false, .expected_effort = "future-tier", .expected_fast = false },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts) }, .effort = stale, .fast_mode = false, .expected_effort = null, .expected_fast = false },
        .{ .capabilities = .{ .supports_fast_mode = true }, .effort = .auto, .fast_mode = true, .expected_effort = null, .expected_fast = true },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts), .supports_fast_mode = true }, .effort = selected, .fast_mode = true, .expected_effort = "future-tier", .expected_fast = true },
    };

    for (cases) |case| {
        const resolved = resolveProviderOptionsForCapabilities(case.capabilities, case.effort, case.fast_mode);
        try std.testing.expectEqual(case.expected_fast, resolved.fast);
        if (case.expected_effort) |expected| {
            try std.testing.expectEqualStrings(expected, resolved.reasoning.?.label());
        } else {
            try std.testing.expect(resolved.reasoning == null);
        }
    }
}

test "request controls remain safe across repeated state transitions" {
    const declared_efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("future-tier"),
        types.ReasoningEffort.literal("high"),
    };
    const states = [_]struct {
        capabilities: Capabilities,
        effort: types.ReasoningEffort,
        fast_mode: bool,
    }{
        .{ .capabilities = .{}, .effort = .auto, .fast_mode = false },
        .{ .capabilities = .{}, .effort = types.ReasoningEffort.literal("future-tier"), .fast_mode = true },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts) }, .effort = types.ReasoningEffort.literal("future-tier"), .fast_mode = true },
        .{ .capabilities = .{ .reasoning_efforts = .fromSlice(&declared_efforts), .supports_fast_mode = true }, .effort = types.ReasoningEffort.literal("high"), .fast_mode = true },
        .{ .capabilities = .{ .supports_fast_mode = true }, .effort = types.ReasoningEffort.literal("stale"), .fast_mode = false },
    };

    var transition: usize = 0;
    while (transition < 1_000) : (transition += 1) {
        const state = states[transition % states.len];
        const resolved = resolveProviderOptionsForCapabilities(state.capabilities, state.effort, state.fast_mode);
        if (resolved.reasoning) |effort| {
            try std.testing.expect(reasoningEffortSupported(state.capabilities, effort));
            try std.testing.expect(effort.eql(state.effort));
        }
        try std.testing.expect(!resolved.fast or (state.fast_mode and state.capabilities.supports_fast_mode));
    }
}

test "generic fallback capabilities contain no vendor policy" {
    const fallback = capabilitiesForModel("anthropic/claude-any");
    try std.testing.expect(fallback.context_window == null);
}
