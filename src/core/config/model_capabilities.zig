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

    /// Returns borrowed descriptor storage unless fast suffix routing applies.
    /// A suffixed result is allocated by `alloc` and owned by the caller.
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
    ) ResolveError!ModelDescriptor,

    pub fn resolve(self: Resolver, arena: std.mem.Allocator, model: []const u8) ResolveError!ModelDescriptor {
        return self.resolve_fn(self.ctx, arena, model);
    }
};

pub fn resolveForApp(comptime App: type, app: *App, model: []const u8) ModelDescriptor {
    if (comptime @hasDecl(App, "resolvedModelDescriptor")) {
        return app.resolvedModelDescriptor(model);
    }
    return configuredDescriptor(model, .{});
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
        .prompt_caching = capabilities.prompt_caching,
    };
    if (!effort.isDefault() and reasoningEffortSupported(capabilities, effort)) {
        resolved.reasoning = effort;
    }
    resolved.fast = fast_mode and capabilities.supports_fast_mode;
    return resolved;
}

pub fn requiresResolvedRequestCapabilities(
    has_images: bool,
    effort: types.ReasoningEffort,
    fast_mode: bool,
    available: Capabilities,
) bool {
    return has_images or
        (!effort.isDefault() and !reasoningEffortSupported(available, effort)) or
        (fast_mode and !available.supports_fast_mode);
}

test "model descriptors preserve explicit provenance and routing" {
    const configured = configuredDescriptor("provider/model", .{ .supports_tool_use = true });
    try std.testing.expectEqual(CapabilitySource.configured, configured.source);
    try std.testing.expect(configured.capabilities.supports_tool_use);

    const catalog = ModelDescriptor{
        .id = "provider/model",
        .display_name = "Model",
        .source = .catalog,
        .selected_fast_mode = true,
        .fast_route = .{ .suffix = "-fast" },
    };
    try std.testing.expectEqualStrings("provider/model", try catalog.routeModel(std.testing.allocator, false));
    const fast = try catalog.routeModel(std.testing.allocator, true);
    defer std.testing.allocator.free(fast);
    try std.testing.expectEqualStrings("provider/model-fast", fast);
}

test "effort projections consume capabilities without model identity" {
    const efforts = [_]types.ReasoningEffort{
        types.ReasoningEffort.literal("low"),
        types.ReasoningEffort.literal("high"),
    };
    const capabilities = Capabilities{
        .supports_reasoning = true,
        .reasoning_efforts = .fromSlice(&efforts),
        .supports_fast_mode = true,
        .prompt_caching = true,
    };
    const high = types.ReasoningEffort.literal("high");
    const low = types.ReasoningEffort.literal("low");
    try std.testing.expect(reasoningEffortSupported(capabilities, high));
    try std.testing.expectEqual(@as(usize, 1), reasoningEffortIndex(capabilities, low));
    try std.testing.expect(reasoningEffortAtIndex(capabilities, 0).isDefault());

    const options = resolveProviderOptionsForCapabilities(capabilities, high, true);
    try std.testing.expectEqualStrings("high", options.reasoning.?.label());
    try std.testing.expect(options.fast);
    try std.testing.expect(options.prompt_caching);
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
