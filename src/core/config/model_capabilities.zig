const std = @import("std");
const types = @import("../shared/types.zig");

pub const ResolvedProviderOptions = struct {
    reasoning: ?types.ReasoningEffort = null,
    fast: bool = false,
    parallel_tool_calls: ?bool = null,
    prompt_caching: bool = false,
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

pub const ImageInputSupport = enum {
    unknown,
    non_native,
    native,
};

pub const GatewayMetadata = struct {
    supports_reasoning: bool = false,
    reasoning_efforts: ReasoningEffortOptions = .{},
    supports_fast_mode: bool = false,
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
        capabilities.supports_tool_use = metadata.supports_tool_use;
        capabilities.supports_vision = metadata.supports_vision;
        capabilities.supports_file_input = metadata.supports_file_input;
        capabilities.image_input_support = if (metadata.supports_vision and metadata.supports_file_input)
            .native
        else
            .non_native;
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

    const native = mergeCapabilities(.{}, .{
        .supports_vision = true,
        .supports_file_input = true,
    });
    try std.testing.expectEqual(ImageInputSupport.native, native.image_input_support);

    const non_native = mergeCapabilities(.{}, .{
        .supports_vision = true,
        .supports_file_input = false,
    });
    try std.testing.expectEqual(ImageInputSupport.non_native, non_native.image_input_support);
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
