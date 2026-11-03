const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_string_bytes = 256;
pub const max_routing_items = 64;
pub const max_extra_body_bytes = 1024 * 1024;

pub const ParseError = Allocator.Error || error{ InvalidCompatibility, UnknownField, InvalidRouting, InvalidExtraBody };
pub const MaxTokensField = enum { max_completion_tokens, max_tokens };
pub const ReasoningContentField = enum { reasoning_content, reasoning, reasoning_text };
pub const ThinkingFormat = enum { openai, openrouter, zai, qwen, qwen_chat_template };
pub const ToolStrictMode = enum { all_strict, none };
pub const StreamMarkupHealingPattern = enum { kimi, dsml, qwen, thinking };
pub const CacheControlFormat = enum { anthropic };

pub const Routing = struct {
    only: []const []const u8 = &.{},
    order: []const []const u8 = &.{},

    fn deinit(self: *Routing, alloc: Allocator) void {
        for (self.only) |value| alloc.free(value);
        for (self.order) |value| alloc.free(value);
        alloc.free(self.only);
        alloc.free(self.order);
    }
};

pub const Compatibility = struct {
    supports_store: ?bool = null,
    supports_developer_role: ?bool = null,
    supports_multiple_system_messages: ?bool = null,
    supports_reasoning_effort: ?bool = null,
    reasoning_effort_map: ?ReasoningEffortMap = null,
    max_tokens_field: ?MaxTokensField = null,
    supports_usage_in_streaming: ?bool = null,
    requires_tool_result_name: ?bool = null,
    requires_mistral_tool_ids: ?bool = null,
    requires_assistant_after_tool_result: ?bool = null,
    requires_thinking_as_text: ?bool = null,
    reasoning_content_field: ?ReasoningContentField = null,
    requires_reasoning_content_for_tool_calls: ?bool = null,
    allows_synthetic_reasoning_content_for_tool_calls: ?bool = null,
    requires_assistant_content_for_tool_calls: ?bool = null,
    supports_tool_choice: ?bool = null,
    supports_forced_tool_choice: ?bool = null,
    disable_reasoning_on_forced_tool_choice: ?bool = null,
    disable_reasoning_on_tool_choice: ?bool = null,
    disable_reasoning_with_tools: ?bool = null,
    thinking_format: ?ThinkingFormat = null,
    qwen_template_reasoning_effort: ?bool = null,
    openrouter_routing: ?Routing = null,
    vercel_gateway_routing: ?Routing = null,
    extra_body: ?std.json.Value = null,
    cache_control_format: ?CacheControlFormat = null,
    supports_strict_mode: ?bool = null,
    tool_strict_mode: ?ToolStrictMode = null,
    stream_idle_timeout_ms: ?u64 = null,
    stream_markup_healing_pattern: ?StreamMarkupHealingPattern = null,
    supports_long_prompt_cache_retention: ?bool = null,
    supports_reasoning_params: ?bool = null,
    supports_reasoning_summary: ?bool = null,
    stateful_responses: ?bool = null,
    always_send_max_tokens: ?bool = null,
    strict_responses_pairing: ?bool = null,
    supports_image_detail_original: ?bool = null,
    supports_configuration_update: ?bool = null,
    supports_steering: ?bool = null,
    requires_thinking_presence: ?bool = null,
    strip_image_input: ?bool = null,
    supports_context_management: ?bool = null,
    supports_eager_tool_input_streaming: ?bool = null,
    allow_anthropic_header_overrides: ?bool = null,
    requires_tool_result_id: ?bool = null,
    replay_unsigned_thinking: ?bool = null,
    when_thinking: ?*const Compatibility = null,

    pub fn jsonParse(alloc: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source))!Compatibility {
        const value = try std.json.innerParse(std.json.Value, alloc, source, options);
        return parse(alloc, value) catch |err| return normalizeParseError(err);
    }

    pub fn jsonParseFromValue(alloc: Allocator, value: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!Compatibility {
        return parse(alloc, value) catch |err| return normalizeParseError(err);
    }

    pub fn parse(alloc: Allocator, value: std.json.Value) ParseError!Compatibility {
        return parseFields(alloc, value, true);
    }

    fn normalizeParseError(err: anyerror) std.json.ParseFromValueError {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnknownField => error.UnknownField,
            else => error.UnexpectedToken,
        };
    }

    pub fn deinit(self: *Compatibility, alloc: Allocator) void {
        if (self.reasoning_effort_map) |*map| map.deinit(alloc);
        if (self.openrouter_routing) |*routing| routing.deinit(alloc);
        if (self.vercel_gateway_routing) |*routing| routing.deinit(alloc);
        if (self.extra_body) |*body| freeValue(alloc, body);
        if (self.when_thinking) |ptr| {
            var nested = @constCast(ptr);
            nested.deinit(alloc);
            alloc.destroy(nested);
        }
        self.* = .{};
    }

    pub fn forThinking(self: *const Compatibility) Compatibility {
        if (self.when_thinking) |nested| return nested.*;
        return self.*;
    }
};

pub const ReasoningEffortMap = struct {
    minimal: ?[]const u8 = null,
    low: ?[]const u8 = null,
    medium: ?[]const u8 = null,
    high: ?[]const u8 = null,
    xhigh: ?[]const u8 = null,
    max: ?[]const u8 = null,

    fn deinit(self: *ReasoningEffortMap, alloc: Allocator) void {
        if (self.minimal) |value| alloc.free(value);
        if (self.low) |value| alloc.free(value);
        if (self.medium) |value| alloc.free(value);
        if (self.high) |value| alloc.free(value);
        if (self.xhigh) |value| alloc.free(value);
        if (self.max) |value| alloc.free(value);
    }

    pub fn get(self: ReasoningEffortMap, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "minimal")) return self.minimal;
        if (std.mem.eql(u8, name, "low")) return self.low;
        if (std.mem.eql(u8, name, "medium")) return self.medium;
        if (std.mem.eql(u8, name, "high")) return self.high;
        if (std.mem.eql(u8, name, "xhigh")) return self.xhigh;
        if (std.mem.eql(u8, name, "max")) return self.max;
        return null;
    }
};

fn parseFields(alloc: Allocator, value: std.json.Value, allow_when_thinking: bool) ParseError!Compatibility {
    if (value != .object) return error.InvalidCompatibility;
    try validateKeys(value.object, allow_when_thinking);
    var result: Compatibility = .{};
    errdefer result.deinit(alloc);

    result.supports_store = try optionalBool(value.object.get("supportsStore"));
    result.supports_developer_role = try optionalBool(value.object.get("supportsDeveloperRole"));
    result.supports_multiple_system_messages = try optionalBool(value.object.get("supportsMultipleSystemMessages"));
    result.supports_reasoning_effort = try optionalBool(value.object.get("supportsReasoningEffort"));
    if (value.object.get("reasoningEffortMap")) |map| result.reasoning_effort_map = try parseEffortMap(alloc, map);
    result.max_tokens_field = try optionalEnum(MaxTokensField, value.object.get("maxTokensField"));
    result.supports_usage_in_streaming = try optionalBool(value.object.get("supportsUsageInStreaming"));
    result.requires_tool_result_name = try optionalBool(value.object.get("requiresToolResultName"));
    result.requires_mistral_tool_ids = try optionalBool(value.object.get("requiresMistralToolIds"));
    result.requires_assistant_after_tool_result = try optionalBool(value.object.get("requiresAssistantAfterToolResult"));
    result.requires_thinking_as_text = try optionalBool(value.object.get("requiresThinkingAsText"));
    result.reasoning_content_field = try optionalEnum(ReasoningContentField, value.object.get("reasoningContentField"));
    result.requires_reasoning_content_for_tool_calls = try optionalBool(value.object.get("requiresReasoningContentForToolCalls"));
    result.allows_synthetic_reasoning_content_for_tool_calls = try optionalBool(value.object.get("allowsSyntheticReasoningContentForToolCalls"));
    result.requires_assistant_content_for_tool_calls = try optionalBool(value.object.get("requiresAssistantContentForToolCalls"));
    result.supports_tool_choice = try optionalBool(value.object.get("supportsToolChoice"));
    result.supports_forced_tool_choice = try optionalBool(value.object.get("supportsForcedToolChoice"));
    result.disable_reasoning_on_forced_tool_choice = try optionalBool(value.object.get("disableReasoningOnForcedToolChoice"));
    result.disable_reasoning_on_tool_choice = try optionalBool(value.object.get("disableReasoningOnToolChoice"));
    result.disable_reasoning_with_tools = try optionalBool(value.object.get("disableReasoningWithTools"));
    result.thinking_format = try parseThinkingFormat(value.object.get("thinkingFormat"));
    result.qwen_template_reasoning_effort = try optionalBool(value.object.get("qwenTemplateReasoningEffort"));
    if (value.object.get("openRouterRouting")) |routing| result.openrouter_routing = try parseRouting(alloc, routing);
    if (value.object.get("vercelGatewayRouting")) |routing| result.vercel_gateway_routing = try parseRouting(alloc, routing);
    if (value.object.get("extraBody")) |body| result.extra_body = try parseExtraBody(alloc, body);
    result.cache_control_format = try optionalEnum(CacheControlFormat, value.object.get("cacheControlFormat"));
    result.supports_strict_mode = try optionalBool(value.object.get("supportsStrictMode"));
    result.tool_strict_mode = try optionalEnum(ToolStrictMode, value.object.get("toolStrictMode"));
    result.stream_idle_timeout_ms = try optionalNonNegative(value.object.get("streamIdleTimeoutMs"));
    result.stream_markup_healing_pattern = try optionalEnum(StreamMarkupHealingPattern, value.object.get("streamMarkupHealingPattern"));
    result.supports_long_prompt_cache_retention = try optionalBool(value.object.get("supportsLongPromptCacheRetention"));
    result.supports_reasoning_params = try optionalBool(value.object.get("supportsReasoningParams"));
    result.supports_reasoning_summary = try optionalBool(value.object.get("supportsReasoningSummary"));
    result.stateful_responses = try optionalBool(value.object.get("statefulResponses"));
    result.always_send_max_tokens = try optionalBool(value.object.get("alwaysSendMaxTokens"));
    result.strict_responses_pairing = try optionalBool(value.object.get("strictResponsesPairing"));
    result.supports_image_detail_original = try optionalBool(value.object.get("supportsImageDetailOriginal"));
    result.supports_configuration_update = try optionalBool(value.object.get("supportsConfigurationUpdate"));
    result.supports_steering = try optionalBool(value.object.get("supportsSteering"));
    result.requires_thinking_presence = try optionalBool(value.object.get("requiresThinkingPresence"));
    result.strip_image_input = try optionalBool(value.object.get("stripImageInput"));
    result.supports_context_management = try optionalBool(value.object.get("supportsContextManagement"));
    result.supports_eager_tool_input_streaming = try optionalBool(value.object.get("supportsEagerToolInputStreaming"));
    result.allow_anthropic_header_overrides = try optionalBool(value.object.get("allowAnthropicHeaderOverrides"));
    result.requires_tool_result_id = try optionalBool(value.object.get("requiresToolResultId"));
    result.replay_unsigned_thinking = try optionalBool(value.object.get("replayUnsignedThinking"));

    if (value.object.get("whenThinking")) |nested_value| {
        const nested = try alloc.create(Compatibility);
        nested.* = .{};
        errdefer {
            nested.deinit(alloc);
            alloc.destroy(nested);
        }
        nested.* = try parseFields(alloc, nested_value, false);
        try inheritMissingPolicies(alloc, &result, nested);
        result.when_thinking = nested;
    }
    return result;
}

/// `whenThinking` is a partial alternate policy in the upstream schema. Build
/// the full alternate view once so transports can safely pointer-swap to it
/// without losing base endpoint policies such as routing, strictness, or
/// output-token selection. Inherited owning values are cloned; scalar options
/// are copied directly.
fn inheritMissingPolicies(alloc: Allocator, base: *const Compatibility, nested: *Compatibility) ParseError!void {
    if (nested.reasoning_effort_map == null) {
        if (base.reasoning_effort_map) |map| nested.reasoning_effort_map = try cloneEffortMap(alloc, map);
    }
    if (nested.openrouter_routing == null) {
        if (base.openrouter_routing) |routing| nested.openrouter_routing = try cloneRouting(alloc, routing);
    }
    if (nested.vercel_gateway_routing == null) {
        if (base.vercel_gateway_routing) |routing| nested.vercel_gateway_routing = try cloneRouting(alloc, routing);
    }
    if (nested.extra_body == null) {
        if (base.extra_body) |body| nested.extra_body = try parseExtraBody(alloc, body);
    }

    const info = @typeInfo(Compatibility).@"struct";
    inline for (info.field_names, info.field_types) |name, field_type| {
        if (comptime std.mem.eql(u8, name, "when_thinking")) continue;
        if (comptime @typeInfo(field_type) == .optional) {
            if (@field(nested, name) == null) @field(nested, name) = @field(base, name);
        }
    }
}

fn cloneEffortMap(alloc: Allocator, source: ReasoningEffortMap) ParseError!ReasoningEffortMap {
    var result: ReasoningEffortMap = .{};
    errdefer result.deinit(alloc);
    if (source.minimal) |value| result.minimal = try alloc.dupe(u8, value);
    if (source.low) |value| result.low = try alloc.dupe(u8, value);
    if (source.medium) |value| result.medium = try alloc.dupe(u8, value);
    if (source.high) |value| result.high = try alloc.dupe(u8, value);
    if (source.xhigh) |value| result.xhigh = try alloc.dupe(u8, value);
    if (source.max) |value| result.max = try alloc.dupe(u8, value);
    return result;
}

fn cloneRouting(alloc: Allocator, source: Routing) ParseError!Routing {
    const only = try cloneRoutingItems(alloc, source.only);
    const order = cloneRoutingItems(alloc, source.order) catch |err| {
        for (only) |value| alloc.free(value);
        alloc.free(only);
        return err;
    };
    return .{ .only = only, .order = order };
}

fn cloneRoutingItems(alloc: Allocator, source: []const []const u8) ParseError![]const []const u8 {
    const result = try alloc.alloc([]const u8, source.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| alloc.free(value);
        alloc.free(result);
    }
    for (source, result) |value, *slot| {
        slot.* = try alloc.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn validateKeys(object: std.json.ObjectMap, allow_when_thinking: bool) ParseError!void {
    const allowed = [_][]const u8{
        "supportsStore",                        "supportsDeveloperRole",                       "supportsMultipleSystemMessages",       "supportsReasoningEffort",
        "reasoningEffortMap",                   "maxTokensField",                              "supportsUsageInStreaming",             "requiresToolResultName",
        "requiresMistralToolIds",               "requiresAssistantAfterToolResult",            "requiresThinkingAsText",               "reasoningContentField",
        "requiresReasoningContentForToolCalls", "allowsSyntheticReasoningContentForToolCalls", "requiresAssistantContentForToolCalls", "supportsToolChoice",
        "supportsForcedToolChoice",             "disableReasoningOnForcedToolChoice",          "disableReasoningOnToolChoice",         "disableReasoningWithTools",
        "thinkingFormat",                       "qwenTemplateReasoningEffort",                 "openRouterRouting",                    "vercelGatewayRouting",
        "extraBody",                            "cacheControlFormat",                          "supportsStrictMode",                   "toolStrictMode",
        "streamIdleTimeoutMs",                  "streamMarkupHealingPattern",                  "supportsLongPromptCacheRetention",     "supportsReasoningParams",
        "supportsReasoningSummary",             "statefulResponses",                           "alwaysSendMaxTokens",                  "strictResponsesPairing",
        "supportsImageDetailOriginal",          "supportsConfigurationUpdate",                 "supportsSteering",                     "requiresThinkingPresence",
        "stripImageInput",                      "supportsContextManagement",                   "supportsEagerToolInputStreaming",      "allowAnthropicHeaderOverrides",
        "requiresToolResultId",                 "replayUnsignedThinking",
    };
    for (object.keys()) |key| {
        if (std.mem.eql(u8, key, "whenThinking")) {
            if (!allow_when_thinking) return error.UnknownField;
            continue;
        }
        var known = false;
        for (allowed) |name| if (std.mem.eql(u8, key, name)) {
            known = true;
            break;
        };
        if (!known) return error.UnknownField;
    }
}

fn optionalBool(value: ?std.json.Value) ParseError!?bool {
    const present = value orelse return null;
    if (present != .bool) return error.InvalidCompatibility;
    return present.bool;
}

fn optionalEnum(comptime T: type, value: ?std.json.Value) ParseError!?T {
    const present = value orelse return null;
    if (present != .string) return error.InvalidCompatibility;
    return std.meta.stringToEnum(T, present.string) orelse error.InvalidCompatibility;
}

fn parseThinkingFormat(value: ?std.json.Value) ParseError!?ThinkingFormat {
    const present = value orelse return null;
    if (present != .string) return error.InvalidCompatibility;
    if (std.mem.eql(u8, present.string, "qwen-chat-template")) return .qwen_chat_template;
    return std.meta.stringToEnum(ThinkingFormat, present.string) orelse error.InvalidCompatibility;
}

fn optionalNonNegative(value: ?std.json.Value) ParseError!?u64 {
    const present = value orelse return null;
    if (present != .integer or present.integer < 0) return error.InvalidCompatibility;
    return std.math.cast(u64, present.integer) orelse error.InvalidCompatibility;
}

fn parseEffortMap(alloc: Allocator, value: std.json.Value) ParseError!ReasoningEffortMap {
    if (value != .object or value.object.count() > 6) return error.InvalidCompatibility;
    var result: ReasoningEffortMap = .{};
    errdefer result.deinit(alloc);
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const text = entry.value_ptr.*;
        if (text != .string or text.string.len == 0 or text.string.len > max_string_bytes) return error.InvalidCompatibility;
        const copy = try alloc.dupe(u8, text.string);
        if (std.mem.eql(u8, entry.key_ptr.*, "minimal")) result.minimal = copy else if (std.mem.eql(u8, entry.key_ptr.*, "low")) result.low = copy else if (std.mem.eql(u8, entry.key_ptr.*, "medium")) result.medium = copy else if (std.mem.eql(u8, entry.key_ptr.*, "high")) result.high = copy else if (std.mem.eql(u8, entry.key_ptr.*, "xhigh")) result.xhigh = copy else if (std.mem.eql(u8, entry.key_ptr.*, "max")) result.max = copy else {
            alloc.free(copy);
            return error.UnknownField;
        }
    }
    return result;
}

fn parseRouting(alloc: Allocator, value: std.json.Value) ParseError!Routing {
    if (value != .object) return error.InvalidRouting;
    for (value.object.keys()) |key| if (!std.mem.eql(u8, key, "only") and !std.mem.eql(u8, key, "order")) return error.UnknownField;
    var result: Routing = .{};
    errdefer result.deinit(alloc);
    if (value.object.get("only")) |items| result.only = try parseRoutingItems(alloc, items);
    if (value.object.get("order")) |items| result.order = try parseRoutingItems(alloc, items);
    return result;
}

fn parseRoutingItems(alloc: Allocator, value: std.json.Value) ParseError![]const []const u8 {
    if (value != .array or value.array.items.len > max_routing_items) return error.InvalidRouting;
    const result = try alloc.alloc([]const u8, value.array.items.len);
    var count: usize = 0;
    errdefer {
        for (result[0..count]) |item| alloc.free(item);
        alloc.free(result);
    }
    for (value.array.items, result) |item, *out| {
        if (item != .string or item.string.len == 0 or item.string.len > max_string_bytes) return error.InvalidRouting;
        out.* = try alloc.dupe(u8, item.string);
        count += 1;
    }
    return result;
}

fn parseExtraBody(alloc: Allocator, value: std.json.Value) ParseError!std.json.Value {
    if (value != .object) return error.InvalidExtraBody;
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    std.json.Stringify.value(value, .{}, &encoded.writer) catch return error.OutOfMemory;
    if (encoded.written().len > max_extra_body_bytes) return error.InvalidExtraBody;
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, encoded.written(), .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidExtraBody,
    };
}

fn freeValue(alloc: Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string, .number_string => |text| alloc.free(text),
        .array => |*array| {
            for (array.items) |*item| freeValue(alloc, item);
            array.deinit();
        },
        .object => |*object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                alloc.free(entry.key_ptr.*);
                freeValue(alloc, entry.value_ptr);
            }
            object.deinit(alloc);
        },
        .null, .bool, .integer, .float => {},
    }
    value.* = .null;
}

test "compatibility parser covers OpenAI fields and whenThinking" {
    const alloc = std.testing.allocator;
    const json = "{\"supportsStore\":false,\"supportsDeveloperRole\":true,\"reasoningEffortMap\":{\"minimal\":\"low\",\"max\":\"high\"},\"maxTokensField\":\"max_completion_tokens\",\"thinkingFormat\":\"qwen-chat-template\",\"streamIdleTimeoutMs\":0,\"openRouterRouting\":{\"order\":[\"a\"]},\"extraBody\":{\"thinking\":{\"type\":\"enabled\"}},\"whenThinking\":{\"requiresReasoningContentForToolCalls\":true,\"reasoningContentField\":\"reasoning_text\"}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    var compat = try Compatibility.parse(alloc, parsed.value);
    defer compat.deinit(alloc);
    try std.testing.expectEqual(false, compat.supports_store.?);
    try std.testing.expectEqual(ThinkingFormat.qwen_chat_template, compat.thinking_format.?);
    try std.testing.expectEqual(@as(u64, 0), compat.stream_idle_timeout_ms.?);
    try std.testing.expectEqualStrings("low", compat.reasoning_effort_map.?.minimal.?);
    try std.testing.expectEqualStrings("a", compat.openrouter_routing.?.order[0]);
    try std.testing.expect(compat.extra_body.? == .object);
    try std.testing.expect(compat.when_thinking != null);
    const thinking = compat.when_thinking.?;
    try std.testing.expect(thinking.requires_reasoning_content_for_tool_calls.?);
    try std.testing.expectEqual(false, thinking.supports_store.?);
    try std.testing.expectEqual(MaxTokensField.max_completion_tokens, thinking.max_tokens_field.?);
    try std.testing.expectEqualStrings("a", thinking.openrouter_routing.?.order[0]);
    try std.testing.expect(thinking.extra_body.? == .object);
}

test "compatibility parser rejects unknown, malformed and recursive whenThinking fields" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { json: []const u8, err: anyerror }{
        .{ .json = "{\"notAField\":true}", .err = error.UnknownField },
        .{ .json = "{\"supportsStore\":1}", .err = error.InvalidCompatibility },
        .{ .json = "{\"reasoningEffortMap\":{\"unexpected\":\"low\"}}", .err = error.UnknownField },
        .{ .json = "{\"streamIdleTimeoutMs\":-1}", .err = error.InvalidCompatibility },
        .{ .json = "{\"openRouterRouting\":{\"only\":[1]}}", .err = error.InvalidRouting },
        .{ .json = "{\"extraBody\":[]}", .err = error.InvalidExtraBody },
        .{ .json = "{\"whenThinking\":{\"whenThinking\":{}}}", .err = error.UnknownField },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectError(case.err, Compatibility.parse(alloc, parsed.value));
    }
}
