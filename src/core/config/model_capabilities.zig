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
    supports_tool_use: bool = false,
    supports_vision: bool = false,
    supports_file_input: bool = false,
    supports_web_search: bool = false,
    supports_explicit_caching: bool = false,
    supports_implicit_caching: bool = false,
    prompt_caching: bool = false,
    parallel_tool_calls: ?bool = null,
    context_window: ?u32 = null,
    max_output_tokens: ?u32 = null,
};

pub const CapabilitySource = enum {
    catalog,
    @"adapter-static",
    configured,
};

pub const FastRoute = union(enum) {
    same_model,
    suffix: []const u8,
};

pub const ModelDescriptor = struct {
    id: []const u8,
    display_name: []const u8,
    provider: []const u8 = "",
    capabilities: Capabilities = .{},
    source: CapabilitySource,
    selected_fast_mode: bool = false,
    fast_route: FastRoute = .same_model,

    pub fn routeModel(self: ModelDescriptor, alloc: std.mem.Allocator, fast_mode: bool) ![]const u8 {
        if (!fast_mode) return self.id;
        return switch (self.fast_route) {
            .same_model => self.id,
            .suffix => |suffix| try std.fmt.allocPrint(alloc, "{s}{s}", .{ self.id, suffix }),
        };
    }
};

pub fn configuredDescriptor(model: []const u8, capabilities: Capabilities) ModelDescriptor {
    return .{
        .id = model,
        .display_name = model,
        .capabilities = capabilities,
        .source = .configured,
    };
}

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

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    const last_start = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= last_start) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn localCapabilitiesForModel(model: []const u8) Capabilities {
    var capabilities: Capabilities = .{};
    if (std.mem.startsWith(u8, model, "anthropic/")) {
        capabilities.prompt_caching = true;
    } else if (std.mem.startsWith(u8, model, "xai/")) {
        capabilities.parallel_tool_calls = true;
    }
    capabilities.context_window = localContextWindowSize(model);
    return capabilities;
}

pub fn resolveCapabilities(model: []const u8, gateway_metadata: ?GatewayMetadata) Capabilities {
    var capabilities = localCapabilitiesForModel(model);
    if (gateway_metadata) |metadata| {
        capabilities.supports_reasoning = metadata.supports_reasoning or metadata.reasoning_efforts.len > 0;
        capabilities.reasoning_efforts = metadata.reasoning_efforts;
        capabilities.supports_fast_mode = metadata.supports_fast_mode;
        capabilities.supports_tool_use = metadata.supports_tool_use;
        capabilities.supports_vision = metadata.supports_vision;
        capabilities.supports_file_input = metadata.supports_file_input;
        capabilities.supports_web_search = metadata.supports_web_search;
        capabilities.supports_explicit_caching = metadata.supports_explicit_caching;
        capabilities.supports_implicit_caching = metadata.supports_implicit_caching;
        if (metadata.context_window) |window| capabilities.context_window = window;
        if (metadata.max_output_tokens) |tokens| capabilities.max_output_tokens = tokens;
    }
    return capabilities;
}

pub fn capabilitiesForModel(model: []const u8) Capabilities {
    return resolveCapabilities(model, null);
}

pub fn resolveForApp(comptime App: type, app: *App, model: []const u8) Capabilities {
    if (comptime @hasDecl(App, "resolvedModelCapabilities")) {
        return app.resolvedModelCapabilities(model);
    }
    return capabilitiesForModel(model);
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

fn localContextWindowSize(model: []const u8) ?u32 {
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
        if (containsIgnoreCase(model, "o3") or containsIgnoreCase(model, "o4") or containsIgnoreCase(model, "o1"))
            return 200_000;
        return 128_000;
    }
    if (std.mem.startsWith(u8, model, "xai/")) return 131_072;
    if (std.mem.startsWith(u8, model, "google/")) return 1_000_000;
    return null;
}

pub fn contextWindowSize(model: []const u8) ?u32 {
    return capabilitiesForModel(model).context_window;
}

pub fn resolveProviderOptions(model: []const u8, effort: types.ReasoningEffort, fast_mode: bool) ResolvedProviderOptions {
    return resolveProviderOptionsForCapabilities(capabilitiesForModel(model), effort, fast_mode);
}

pub fn resolveProviderOptionsForCapabilities(
    capabilities: Capabilities,
    effort: types.ReasoningEffort,
    fast_mode: bool,
) ResolvedProviderOptions {
    var resolved: ResolvedProviderOptions = .{
        .parallel_tool_calls = capabilities.parallel_tool_calls,
        .prompt_caching = capabilities.prompt_caching,
    };
    if (!effort.isDefault() and reasoningEffortSupported(capabilities, effort)) {
        resolved.reasoning = effort;
    }
    resolved.fast = fast_mode and capabilities.supports_fast_mode;
    return resolved;
}

test "capabilities never infer reasoning or Fast controls from model IDs" {
    const models = [_][]const u8{
        "openai/gpt-5.6-sol",
        "anthropic/claude-opus-4.8",
        "zai/glm-5.2",
        "zai/glm-5.2-fast",
    };
    for (models) |model| {
        const capabilities = capabilitiesForModel(model);
        try std.testing.expectEqual(@as(usize, 0), capabilities.reasoning_efforts.len);
        try std.testing.expect(!capabilities.supports_fast_mode);
    }
}

test "resolveCapabilities preserves Gateway controls and unrelated local policy" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("future-tier"),
        types.ReasoningEffort.literal("high"),
    };
    const capabilities = resolveCapabilities("anthropic/claude-future", .{
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
    try std.testing.expectEqual(@as(usize, 2), capabilities.reasoning_efforts.len);
    try std.testing.expectEqualStrings("future-tier", capabilities.reasoning_efforts.values[0].label());
    try std.testing.expect(capabilities.supports_fast_mode);
    try std.testing.expect(capabilities.supports_tool_use);
    try std.testing.expect(capabilities.supports_vision);
    try std.testing.expect(capabilities.supports_file_input);
    try std.testing.expect(capabilities.supports_web_search);
    try std.testing.expect(capabilities.supports_explicit_caching);
    try std.testing.expect(capabilities.supports_implicit_caching);
    try std.testing.expect(capabilities.prompt_caching);
    try std.testing.expectEqual(@as(?u32, 300_000), capabilities.context_window);
    try std.testing.expectEqual(@as(?u32, 32_000), capabilities.max_output_tokens);
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

test "local non-control capabilities remain available" {
    const anthropic = capabilitiesForModel("anthropic/claude-any");
    try std.testing.expect(anthropic.prompt_caching);
    try std.testing.expectEqual(@as(?u32, 200_000), anthropic.context_window);

    const xai = capabilitiesForModel("xai/grok-any");
    try std.testing.expectEqual(@as(?bool, true), xai.parallel_tool_calls);
    try std.testing.expectEqual(@as(?u32, 131_072), xai.context_window);
}
