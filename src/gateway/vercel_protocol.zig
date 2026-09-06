const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const io_mod = @import("../core/shared/io.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const types = @import("../core/shared/types.zig");
const tool_call_ids = @import("tool_call_ids.zig");

pub const ChatRole = types.ChatRole;
pub const ChatMessage = types.ChatMessage;
pub const GatewayCompletion = types.ModelCompletion;
pub const ToolCall = types.ToolCall;

pub const StructuredResponseFormat = struct {
    name: []const u8,
    description: []const u8,
    schema: std.json.Value,
};

const pending_tool_review_result_text = "Tool call has not executed; it is pending permission review.";

pub fn roleName(role: ChatRole) []const u8 {
    return switch (role) {
        .system => "system",
        .user => "user",
        .assistant => "assistant",
        .tool => "tool",
    };
}

fn writeChatMessageJson(
    scratch_alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ChatMessage,
) !void {
    writeChatMessageJsonInner(scratch_alloc, writer, message, null, null, &.{}) catch |err| return err;
}

pub fn buildGatewayRequestBody(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
) ![]u8 {
    return buildGatewayRequestBodyWithOptions(alloc, tools_json, messages, .{}, .auto);
}

pub fn buildGatewayRequestBodyWithOptions(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
) ![]u8 {
    return buildGatewayRequestBodyWithOptionsAndOutputLimit(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice,
        null,
    );
}

pub fn buildGatewayRequestBodyWithOptionsAndOutputLimit(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
    max_output_tokens: ?u32,
) ![]u8 {
    return buildGatewayRequestBodyWithSettings(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice.label(),
        max_output_tokens,
    );
}

pub fn buildGatewayRequestBodyWithOptionsAndBudget(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
    max_output_tokens: ?u32,
    budget: BuildBudget,
) ![]u8 {
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice.label(),
        max_output_tokens,
        budget,
        null,
        null,
    );
}

pub fn buildGatewayRequestBodyWithVerifiedImagesAndBudget(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    verified_images: []const image_attachments.VerifiedSnapshot,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: types.ToolChoice,
    response_format: StructuredResponseFormat,
    budget: BuildBudget,
) ![]u8 {
    if (messages.len == 0 or messages[messages.len - 1].role != .user) {
        return error.InvalidGatewayHistory;
    }
    if (messages[messages.len - 1].images.len != 0) {
        return error.InvalidGatewayHistory;
    }
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice.label(),
        null,
        budget,
        response_format,
        .{
            .message_index = messages.len - 1,
            .images = verified_images,
        },
    );
}

pub fn buildGatewayRequiredToolRequestBodyWithOptions(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
) ![]u8 {
    return buildGatewayRequiredToolRequestBodyWithOptionsAndOutputLimit(
        alloc,
        tools_json,
        messages,
        options,
        null,
    );
}

pub fn buildGatewayRequiredToolRequestBodyWithOptionsAndOutputLimit(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32,
) ![]u8 {
    return buildGatewayRequestBodyWithSettings(
        alloc,
        tools_json,
        messages,
        options,
        "required",
        max_output_tokens,
    );
}

pub fn buildGatewayRequiredToolRequestBodyWithOptionsAndBudget(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: ?u32,
    budget: BuildBudget,
) ![]u8 {
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        "required",
        max_output_tokens,
        budget,
        null,
        null,
    );
}

pub fn buildGatewayRequiredToolRequestBodyWithMaxOutputTokens(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    max_output_tokens: u32,
) ![]u8 {
    return buildGatewayRequestBodyWithSettings(alloc, tools_json, messages, .{}, "required", max_output_tokens);
}

pub fn buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    instructions: []const ChatMessage,
    messages: []const ChatMessage,
    target_call_id: []const u8,
    options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: u32,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]u8 {
    const budget = BuildBudget{ .deadline = deadline, .cancel_flag = cancel_flag };
    stream_provider.validate_prompt_lanes(instructions, messages) catch
        return error.InvalidGatewayHistory;
    const expanded = try expandPendingToolReviewMessages(
        alloc,
        messages,
        target_call_id,
        deadline,
        cancel_flag,
    );
    defer alloc.free(expanded);

    const prompt_len = try std.math.add(usize, instructions.len, expanded.len);
    const prompt = try alloc.alloc(ChatMessage, prompt_len);
    defer alloc.free(prompt);
    @memcpy(prompt[0..instructions.len], instructions);
    @memcpy(prompt[instructions.len..], expanded);

    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        prompt,
        options,
        "required",
        max_output_tokens,
        budget,
        null,
        null,
    );
}

/// Returns an owned message slice that closes the pending tool call. Message
/// contents remain borrowed from `messages`.
pub fn expandPendingToolReviewMessages(
    alloc: std.mem.Allocator,
    messages: []const ChatMessage,
    target_call_id: []const u8,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]ChatMessage {
    const budget = BuildBudget{ .deadline = deadline, .cancel_flag = cancel_flag };
    try budget.check();
    try validatePendingToolReviewMessages(alloc, messages, target_call_id, budget);
    try budget.check();

    const pending_index = messages.len - 1;
    const pending = messages[pending_index];
    const expanded_len = try std.math.add(usize, messages.len, pending.tool_calls.len);
    const expanded = try alloc.alloc(ChatMessage, expanded_len);
    errdefer alloc.free(expanded);

    @memcpy(expanded[0..messages.len], messages);
    for (pending.tool_calls, 0..) |call, i| {
        try budget.check();
        expanded[messages.len + i] = .{
            .role = .tool,
            .content = pending_tool_review_result_text,
            .tool_call_id = call.id,
            .tool_name = call.name,
        };
    }
    try budget.check();
    try validateToolMessageHistory(alloc, expanded);
    try budget.check();
    return expanded;
}

fn buildGatewayRequestBodyWithSettings(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: []const u8,
    max_output_tokens: ?u32,
) ![]u8 {
    try validateToolMessageHistory(alloc, messages);
    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        messages,
        options,
        tool_choice,
        max_output_tokens,
        null,
        null,
        null,
    );
}

pub const BuildBudget = struct {
    deadline: ?std.Io.Clock.Timestamp = null,
    cancel_flag: ?*std.atomic.Value(bool) = null,

    pub fn check(self: BuildBudget) error{ Cancelled, TimedOut }!void {
        if (self.cancel_flag) |flag| {
            if (flag.load(.seq_cst)) return error.Cancelled;
        }
        if (self.deadline) |deadline| {
            const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
            if (now.raw.nanoseconds >= deadline.raw.nanoseconds) return error.TimedOut;
        }
    }
};

fn buildGatewayRequestBodyValidated(
    alloc: std.mem.Allocator,
    tools_json: []const u8,
    messages: []const ChatMessage,
    options: model_capabilities.ResolvedProviderOptions,
    tool_choice: []const u8,
    max_output_tokens: ?u32,
    budget: ?BuildBudget,
    response_format: ?StructuredResponseFormat,
    verified_image_override: ?VerifiedImageOverride,
) ![]u8 {
    if (budget) |active| try active.check();
    var saw_conversation = false;
    for (messages) |message| {
        if (message.role == .system) {
            if (saw_conversation) return error.InvalidGatewayHistory;
        } else {
            saw_conversation = true;
        }
    }

    var ids = try tool_call_ids.Projection.init(alloc, messages);
    defer ids.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("{\"prompt\":[");
    var i: usize = 0;
    while (i < messages.len) {
        const message = messages[i];
        if (budget) |active| try active.check();
        if (i > 0) try out.writer.writeByte(',');
        if (message.role == .tool) {
            const results = tool_result_prefix(messages[i..]);
            try write_tool_result_group(alloc, &out.writer, results, budget, &ids);
            i += results.len;
            if (budget) |active| try active.check();
            continue;
        }
        const verified_images = if (verified_image_override) |override|
            if (override.message_index == i) override.images else null
        else
            null;
        try writeChatMessageJsonInner(
            std.heap.c_allocator,
            &out.writer,
            message,
            budget,
            verified_images,
            &ids,
        );
        if (budget) |active| try active.check();
        i += 1;
    }
    try out.writer.writeAll("],\"tools\":");
    try out.writer.writeAll(tools_json);
    try out.writer.writeAll(",\"toolChoice\":{\"type\":");
    try std.json.Stringify.value(tool_choice, .{}, &out.writer);
    try out.writer.writeByte('}');

    if (response_format) |format| {
        try writeStructuredResponseFormat(alloc, &out.writer, format);
    }

    if (max_output_tokens) |value| {
        try out.writer.print(",\"maxOutputTokens\":{d}", .{value});
    }

    if (options.reasoning) |*reasoning| {
        try out.writer.writeAll(",\"reasoning\":");
        try std.json.Stringify.value(reasoning.label(), .{}, &out.writer);
    }
    try writeProviderOptions(&out.writer, options);

    try out.writer.writeByte('}');
    if (budget) |active| try active.check();
    return try out.toOwnedSlice();
}

/// Returns a new request body with the provider-visible user agent added.
/// The caller retains ownership of `body` and owns the returned slice.
pub fn withRequestUserAgent(
    alloc: std.mem.Allocator,
    body: []const u8,
    user_agent: []const u8,
) ![]u8 {
    if (body.len == 0 or body[body.len - 1] != '}') return error.InvalidGatewayRequestBody;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(body[0 .. body.len - 1]);
    try out.writer.writeAll(",\"headers\":{\"user-agent\":");
    try std.json.Stringify.value(user_agent, .{}, &out.writer);
    try out.writer.writeAll("}}");
    return try out.toOwnedSlice();
}

fn writeStructuredResponseFormat(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    format: StructuredResponseFormat,
) !void {
    _ = alloc;
    if (format.schema != .object) return error.InvalidStructuredResponseSchema;

    try writer.writeAll(",\"responseFormat\":{\"type\":\"json\",\"name\":");
    try std.json.Stringify.value(format.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(format.description, .{}, writer);
    try writer.writeAll(",\"schema\":");
    try std.json.Stringify.value(format.schema, .{}, writer);
    try writer.writeByte('}');
}

const VerifiedImageOverride = struct {
    message_index: usize,
    images: []const image_attachments.VerifiedSnapshot,
};

fn validatePendingToolReviewMessages(
    alloc: std.mem.Allocator,
    messages: []const ChatMessage,
    target_call_id: []const u8,
    budget: BuildBudget,
) !void {
    try budget.check();
    if (messages.len < 1 or target_call_id.len == 0) return error.InvalidGatewayHistory;
    const pending = messages[messages.len - 1];
    if (pending.role != .assistant or pending.tool_calls.len == 0) return error.InvalidGatewayHistory;
    try validateToolMessageHistory(alloc, messages[0 .. messages.len - 1]);
    try budget.check();
    try validateAssistantToolCalls(alloc, pending.tool_calls);
    try budget.check();

    var target_matches: usize = 0;
    for (pending.tool_calls) |call| {
        try budget.check();
        if (std.mem.eql(u8, call.id, target_call_id)) target_matches += 1;
    }
    if (target_matches != 1) return error.InvalidGatewayHistory;
}

pub fn writeProviderOptions(writer: *std.Io.Writer, options: model_capabilities.ResolvedProviderOptions) !void {
    const gateway_options = options.fast or options.prompt_caching;
    if (!gateway_options and options.parallel_tool_calls == null) return;

    try writer.writeAll(",\"providerOptions\":{");
    if (gateway_options) {
        try writer.writeAll("\"gateway\":{");
        if (options.fast) try writer.writeAll("\"speed\":\"fast\"");
        if (options.prompt_caching) {
            if (options.fast) try writer.writeByte(',');
            try writer.writeAll("\"caching\":\"auto\"");
        }
        try writer.writeByte('}');
    }
    if (options.parallel_tool_calls) |parallel_tool_calls| {
        if (gateway_options) try writer.writeByte(',');
        try writer.writeAll("\"xai\":{\"parallelToolCalls\":");
        try writer.writeAll(if (parallel_tool_calls) "true" else "false");
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
}

pub fn validateToolMessageHistory(alloc: std.mem.Allocator, messages: []const ChatMessage) !void {
    var i: usize = 0;
    while (i < messages.len) {
        const msg = messages[i];
        if (msg.role == .tool) return error.InvalidGatewayHistory;
        if (msg.role != .assistant or msg.tool_calls.len == 0) {
            i += 1;
            continue;
        }

        try validateAssistantToolCalls(alloc, msg.tool_calls);
        const seen = try alloc.alloc(bool, msg.tool_calls.len);
        defer alloc.free(seen);

        i = try validateAssistantToolResultBlock(messages, i + 1, msg.tool_calls, seen);
    }
}

fn validateAssistantToolResultBlock(
    messages: []const ChatMessage,
    start_index: usize,
    calls: []const ToolCall,
    seen: []bool,
) !usize {
    @memset(seen, false);

    var result_count: usize = 0;
    var j = start_index;
    while (result_count < calls.len) : (j += 1) {
        if (j >= messages.len) return error.InvalidGatewayHistory;
        const result = messages[j];
        if (result.role != .tool) return error.InvalidGatewayHistory;
        const tool_call_id = result.tool_call_id orelse return error.InvalidGatewayHistory;
        const tool_name = result.tool_name orelse return error.InvalidGatewayHistory;
        if (result.content == null) return error.InvalidGatewayHistory;

        const matched_index = findToolCallIndex(calls, tool_call_id) orelse return error.InvalidGatewayHistory;
        if (seen[matched_index]) return error.InvalidGatewayHistory;
        if (!std.mem.eql(u8, calls[matched_index].name, tool_name)) return error.InvalidGatewayHistory;
        seen[matched_index] = true;
        result_count += 1;
    }
    return j;
}

fn validateAssistantToolCalls(alloc: std.mem.Allocator, calls: []const ToolCall) !void {
    for (calls, 0..) |call, i| {
        if (call.id.len == 0 or call.name.len == 0 or call.arguments_json.len == 0) return error.InvalidGatewayHistory;
        const integrity = if (call.provenance == .provider_executed)
            try types.ToolArgumentIntegrity.classifySerialized(alloc, call.arguments_json)
        else
            try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, call.arguments_json);
        if (integrity != .valid) {
            return error.InvalidGatewayHistory;
        }
        var j = i + 1;
        while (j < calls.len) : (j += 1) {
            if (std.mem.eql(u8, call.id, calls[j].id)) return error.InvalidGatewayHistory;
        }
    }
}

test "Gateway request projects nonportable call ids without changing source history" {
    const source_id = "functions.read_file:0";
    const second_id = "functions/read_file:0";
    const calls = [_]ToolCall{
        .{ .id = source_id, .name = "read_file", .arguments_json = "{}" },
        .{ .id = second_id, .name = "read_file", .arguments_json = "{}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = second_id, .tool_name = "read_file", .content = "second" },
        .{ .role = .tool, .tool_call_id = source_id, .tool_name = "read_file", .content = "result" },
    };
    const body = try buildGatewayRequestBody(std.testing.allocator, "[]", &messages);
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const prompt = parsed.value.object.get("prompt").?.array.items;
    const call_id = prompt[0].object.get("content").?.array.items[0].object.get("toolCallId").?.string;
    const results = prompt[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    const result_id = results[1].object.get("toolCallId").?.string;
    try std.testing.expect(!std.mem.eql(u8, source_id, call_id));
    try std.testing.expect(call_id.len <= 64);
    for (call_id) |byte| try std.testing.expect(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-');
    try std.testing.expectEqualStrings(call_id, result_id);
    const second_call_id = prompt[0].object.get("content").?.array.items[1].object.get("toolCallId").?.string;
    try std.testing.expect(!std.mem.eql(u8, call_id, second_call_id));
    try std.testing.expectEqualStrings(second_call_id, results[0].object.get("toolCallId").?.string);
    try std.testing.expectEqualStrings(source_id, calls[0].id);
    try std.testing.expectEqualStrings(source_id, messages[2].tool_call_id.?);
}

test "Gateway request preserves provider-owned call ids" {
    const calls = [_]ToolCall{.{ .id = "native:0", .name = "native", .arguments_json = "{}", .provenance = .provider_executed, .provider_result = "result" }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "native:0", .tool_name = "native", .content = "result" },
    };
    const body = try buildGatewayRequestBody(std.testing.allocator, "[]", &messages);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"toolCallId\":\"native:0\"") != null);
}

test "non-object provider-owned arguments retain their Gateway representation" {
    const calls = [_]ToolCall{.{ .id = "native", .name = "native_tool", .arguments_json = "[]", .provenance = .provider_executed, .provider_result = "native result" }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "native", .tool_name = "native_tool", .content = "native result" },
    };
    const body = try buildGatewayRequestBody(std.testing.allocator, "[]", &messages);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"input\":[]") != null);
}

test "non-object function arguments cannot enter a Gateway request" {
    for ([_][]const u8{ "[]", "42", "null", "true", "\"text\"" }) |arguments| {
        const calls = [_]ToolCall{.{ .id = "call", .name = "read_file", .arguments_json = arguments }};
        const messages = [_]ChatMessage{
            .{ .role = .user, .content = "read" },
            .{ .role = .assistant, .tool_calls = &calls },
            .{ .role = .tool, .tool_call_id = "call", .tool_name = "read_file", .content = "not executed", .tool_result_status = .failure },
        };
        const body = buildGatewayRequestBody(std.testing.allocator, "[]", &messages) catch |err| {
            try std.testing.expectEqual(error.InvalidGatewayHistory, err);
            continue;
        };
        defer std.testing.allocator.free(body);
        return error.TestExpectedError;
    }
}

fn findToolCallIndex(calls: []const ToolCall, id: []const u8) ?usize {
    for (calls, 0..) |call, i| {
        if (std.mem.eql(u8, call.id, id)) return i;
    }
    return null;
}

const max_prompt_shape_entries: usize = 12;

fn tool_result_prefix(messages: []const ChatMessage) []const ChatMessage {
    var end: usize = 0;
    while (end < messages.len and messages[end].role == .tool) : (end += 1) {}
    return messages[0..end];
}

fn write_tool_result_group(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    results: []const ChatMessage,
    budget: ?BuildBudget,
    ids: *const tool_call_ids.Projection,
) !void {
    try writer.writeAll("{\"role\":\"tool\",\"content\":[");
    for (results, 0..) |result, index| {
        if (budget) |active| try active.check();
        if (index > 0) try writer.writeByte(',');
        try write_tool_result_part(alloc, writer, result, ids);
    }
    try writer.writeAll("]}");
}

fn write_tool_result_part(scratch_alloc: std.mem.Allocator, writer: *std.Io.Writer, message: ChatMessage, ids: *const tool_call_ids.Projection) !void {
    try writer.writeAll("{\"type\":\"tool-result\",\"toolCallId\":");
    try std.json.Stringify.value(ids.resolve(message.tool_call_id orelse ""), .{}, writer);
    try writer.writeAll(",\"toolName\":");
    try std.json.Stringify.value(message.tool_name orelse "unknown", .{}, writer);
    const content = message.content orelse "";
    const failed = if (message.tool_result_status) |status|
        status == .failure
    else
        false;
    const denied = failed and tool_result_errors.toolPermissionDenialReason(content) != null;
    const tool_images = if (message.tool_result_memory) |memory| memory.tool_images else &.{};
    if (tool_images.len > 0 and !denied) {
        try writer.writeAll(",\"output\":{\"type\":\"content\",\"value\":[");
        const text = if (failed) try std.fmt.allocPrint(scratch_alloc, "Tool error: {s}", .{content}) else content;
        defer if (failed) scratch_alloc.free(text);
        if (text.len > 0) {
            try writer.writeAll("{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(text, .{}, writer);
            try writer.writeByte('}');
        }
        for (tool_images, 0..) |image, index| {
            if (index > 0 or text.len > 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"image-data\",\"data\":");
            try std.json.Stringify.value(image.data, .{}, writer);
            try writer.writeAll(",\"mediaType\":");
            try std.json.Stringify.value(image.mime_type, .{}, writer);
            try writer.writeByte('}');
        }
        try writer.writeAll("]}}");
        return;
    }
    if (denied) {
        try writer.writeAll(",\"output\":{\"type\":\"execution-denied\",\"reason\":");
    } else if (failed) {
        try writer.writeAll(",\"output\":{\"type\":\"error-text\",\"value\":");
    } else {
        try writer.writeAll(",\"output\":{\"type\":\"text\",\"value\":");
    }
    try std.json.Stringify.value(content, .{}, writer);
    try writer.writeAll("}}");
}

fn writeChatMessageJsonInner(
    scratch_alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ChatMessage,
    budget: ?BuildBudget,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    ids: *const tool_call_ids.Projection,
) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(roleName(message.role), .{}, writer);

    if (message.role == .assistant) if (message.provider_replay) |replay| {
        try writeReplayContent(scratch_alloc, writer, message, replay, ids, budget);
        try writer.writeByte('}');
        return;
    };

    switch (message.role) {
        .system => {
            try writer.writeAll(",\"content\":");
            if (message.content) |content| {
                try std.json.Stringify.value(content, .{}, writer);
            } else {
                try writer.writeAll("\"\"");
            }
        },
        .user => {
            try writer.writeAll(",\"content\":[");
            var wrote_part = false;
            if (message.content) |content| {
                if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    wrote_part = true;
                }
            }
            if (verified_images) |snapshots| {
                for (snapshots) |snapshot| {
                    if (wrote_part) try writer.writeByte(',');
                    try image_attachments.writeVerifiedImageFilePartJsonWithBudget(
                        writer,
                        snapshot,
                        .{
                            .deadline = if (budget) |active| active.deadline else null,
                            .cancel_flag = if (budget) |active| active.cancel_flag else null,
                        },
                    );
                    wrote_part = true;
                }
            } else {
                for (message.images) |image| {
                    if (wrote_part) try writer.writeByte(',');
                    if (budget) |active| {
                        try image_attachments.writeImageFilePartJsonWithBudget(
                            scratch_alloc,
                            writer,
                            image,
                            .{
                                .deadline = active.deadline,
                                .cancel_flag = active.cancel_flag,
                            },
                        );
                    } else {
                        try image_attachments.writeImageFilePartJson(scratch_alloc, writer, image);
                    }
                    wrote_part = true;
                }
            }
            try writer.writeByte(']');
        },
        .assistant => {
            try writer.writeAll(",\"content\":[");
            var wrote_part = false;
            if (message.content) |content| {
                if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    wrote_part = true;
                }
            }
            for (message.tool_calls) |tool_call| {
                if (wrote_part) try writer.writeByte(',');
                try writeToolCallPart(writer, tool_call, null, ids);
                wrote_part = true;
            }
            try writer.writeByte(']');
        },
        .tool => {
            try writer.writeAll(",\"content\":[");
            try write_tool_result_part(scratch_alloc, writer, message, ids);
            try writer.writeByte(']');
        },
    }

    try writer.writeAll("}");
}

fn writeToolCallPart(writer: *std.Io.Writer, call: ToolCall, metadata: ?std.json.Value, ids: *const tool_call_ids.Projection) !void {
    try writer.writeAll("{\"type\":\"tool-call\",\"toolCallId\":");
    try std.json.Stringify.value(ids.resolve(call.id), .{}, writer);
    try writer.writeAll(",\"toolName\":");
    try std.json.Stringify.value(call.name, .{}, writer);
    try writer.writeAll(",\"input\":");
    try writer.writeAll(call.arguments_json);
    try writeReplayMetadata(writer, metadata);
    try writer.writeByte('}');
}

fn writeReplayMetadata(writer: *std.Io.Writer, metadata: ?std.json.Value) !void {
    const value = metadata orelse return;
    if (value != .object) return error.InvalidProviderState;
    for (value.object.values()) |options| if (options != .object) return error.InvalidProviderState;
    try writer.writeAll(",\"providerOptions\":");
    try std.json.Stringify.value(value, .{}, writer);
}

/// Borrows unchanged replay, otherwise uses the caller's request arena. Selects
/// metadata for the assistant unit after core splits a provider-executed reply.
pub fn selectReplayParts(
    arena: std.mem.Allocator,
    replay: ?types.ProviderReplay,
    calls: []const ToolCall,
    include_text: bool,
    include_reasoning: bool,
) !?types.ProviderReplay {
    const source = replay orelse return null;
    if (source.source.provider != .gateway) return error.InvalidProviderState;
    if (source.parts_json.len > types.ProviderReplay.max_bytes) return error.ProviderStateTooLarge;
    const parsed = std.json.parseFromSlice(std.json.Value, arena, source.parts_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidProviderState,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidProviderState;
    var selected: std.ArrayList(std.json.Value) = .empty;
    defer selected.deinit(arena);
    for (parsed.value.array.items) |part| {
        if (part != .object) return error.InvalidProviderState;
        const kind = part.object.get("type") orelse return error.InvalidProviderState;
        if (kind != .string) return error.InvalidProviderState;
        const keep = if (std.mem.eql(u8, kind.string, "text")) include_text else if (std.mem.eql(u8, kind.string, "reasoning")) include_reasoning else if (std.mem.eql(u8, kind.string, "tool-call")) blk: {
            const id = part.object.get("toolCallId") orelse return error.InvalidProviderState;
            if (id != .string) return error.InvalidProviderState;
            break :blk findToolCallIndex(calls, id.string) != null;
        } else return error.InvalidProviderState;
        if (keep) try selected.append(arena, part);
    }
    if (selected.items.len == 0) return null;
    if (selected.items.len == parsed.value.array.items.len) return source;
    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();
    try std.json.Stringify.value(selected.items, .{}, &out.writer);
    return .{ .source = source.source, .parts_json = try out.toOwnedSlice() };
}

test "split provider completion retains metadata with each canonical assistant unit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const replay = types.ProviderReplay{ .source = .{ .provider = .gateway, .model = "test" }, .parts_json = "[{\"type\":\"reasoning\",\"text\":\"reason\"},{\"type\":\"tool-call\",\"toolCallId\":\"call\",\"providerOptions\":{\"vertex\":{\"thoughtSignature\":\"signed\"}}},{\"type\":\"text\",\"offset\":0,\"length\":4,\"providerOptions\":{\"openai\":{\"itemId\":\"text\"}}}]" };
    const calls = [_]ToolCall{.{ .id = "call", .name = "search", .arguments_json = "{}", .provenance = .provider_executed }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls, .provider_replay = try selectReplayParts(alloc, replay, &calls, false, true) },
        .{ .role = .tool, .tool_call_id = "call", .tool_name = "search", .content = "result" },
        .{ .role = .assistant, .content = "done", .provider_replay = try selectReplayParts(alloc, replay, &.{}, true, false) },
    };
    const body = try buildGatewayRequestBody(alloc, "[]", &messages);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    const prompt = parsed.value.object.get("prompt").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), prompt[0].object.get("content").?.array.items.len);
    try std.testing.expectEqualStrings("signed", prompt[0].object.get("content").?.array.items[1].object.get("providerOptions").?.object.get("vertex").?.object.get("thoughtSignature").?.string);
    try std.testing.expectEqual(@as(usize, 1), prompt[2].object.get("content").?.array.items.len);
    try std.testing.expectEqualStrings("text", prompt[2].object.get("content").?.array.items[0].object.get("providerOptions").?.object.get("openai").?.object.get("itemId").?.string);
}

fn writeReplayContent(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ChatMessage,
    replay: types.ProviderReplay,
    ids: *const tool_call_ids.Projection,
    budget: ?BuildBudget,
) !void {
    if (replay.source.provider != .gateway) return error.InvalidProviderState;
    if (replay.parts_json.len > types.ProviderReplay.max_bytes) return error.ProviderStateTooLarge;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, replay.parts_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidProviderState,
    };
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidProviderState;
    const seen_calls = try alloc.alloc(bool, message.tool_calls.len);
    defer alloc.free(seen_calls);
    @memset(seen_calls, false);
    const content = message.content orelse "";
    var text_end: usize = 0;
    var wrote_part = false;
    try writer.writeAll(",\"content\":[");
    for (parsed.value.array.items) |part| {
        if (budget) |active| try active.check();
        if (part != .object) return error.InvalidProviderState;
        const kind = part.object.get("type") orelse return error.InvalidProviderState;
        if (kind != .string) return error.InvalidProviderState;
        if (wrote_part) try writer.writeByte(',');
        const metadata = part.object.get("providerOptions");
        if (std.mem.eql(u8, kind.string, "reasoning")) {
            const text_value = part.object.get("text") orelse return error.InvalidProviderState;
            if (text_value != .string) return error.InvalidProviderState;
            try writer.writeAll("{\"type\":\"reasoning\",\"text\":");
            try std.json.Stringify.value(text_value.string, .{}, writer);
            try writeReplayMetadata(writer, metadata);
            try writer.writeByte('}');
        } else if (std.mem.eql(u8, kind.string, "text")) {
            const offset_value = part.object.get("offset") orelse return error.InvalidProviderState;
            const length_value = part.object.get("length") orelse return error.InvalidProviderState;
            if (offset_value != .integer or length_value != .integer) return error.InvalidProviderState;
            const offset = std.math.cast(usize, offset_value.integer) orelse return error.InvalidProviderState;
            const length = std.math.cast(usize, length_value.integer) orelse return error.InvalidProviderState;
            if (offset != text_end or offset > content.len or length > content.len - offset) return error.InvalidProviderState;
            text_end = offset + length;
            try writer.writeAll("{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(content[offset..text_end], .{}, writer);
            try writeReplayMetadata(writer, metadata);
            try writer.writeByte('}');
        } else if (std.mem.eql(u8, kind.string, "tool-call")) {
            const call_id = part.object.get("toolCallId") orelse return error.InvalidProviderState;
            if (call_id != .string) return error.InvalidProviderState;
            const index = findToolCallIndex(message.tool_calls, call_id.string) orelse return error.InvalidProviderState;
            if (seen_calls[index]) return error.InvalidProviderState;
            seen_calls[index] = true;
            try writeToolCallPart(writer, message.tool_calls[index], metadata, ids);
        } else return error.InvalidProviderState;
        wrote_part = true;
    }
    if (text_end < content.len) {
        if (wrote_part) try writer.writeByte(',');
        try writer.writeAll("{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(content[text_end..], .{}, writer);
        try writer.writeByte('}');
        wrote_part = true;
    }
    for (message.tool_calls, seen_calls) |call, seen| {
        if (seen) continue;
        if (wrote_part) try writer.writeByte(',');
        try writeToolCallPart(writer, call, null, ids);
        wrote_part = true;
    }
    try writer.writeByte(']');
}

pub fn formatGatewayRequestShapeSummary(alloc: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();

    try out.writer.print("bytes={d}", .{payload.len});

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| {
        try out.writer.print(" parse_error={s}", .{@errorName(err)});
        return try out.toOwnedSlice();
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try out.writer.print(" root={s}", .{jsonKindName(parsed.value)});
        return try out.toOwnedSlice();
    }

    if (parsed.value.object.get("prompt")) |prompt| {
        if (prompt == .array) {
            try out.writer.print(" prompt_count={d}", .{prompt.array.items.len});
            const limit = @min(prompt.array.items.len, max_prompt_shape_entries);
            for (prompt.array.items[0..limit], 0..) |entry, i| {
                try out.writer.print(" prompt.{d}", .{i});
                if (entry == .object) {
                    if (entry.object.get("role")) |role_value| {
                        try out.writer.writeAll(" role=");
                        if (role_value == .string) {
                            try appendSafeShapeToken(&out.writer, role_value.string);
                        } else {
                            try out.writer.writeAll(jsonKindName(role_value));
                        }
                    } else {
                        try out.writer.writeAll(" role=missing");
                    }
                    if (entry.object.get("content")) |content_value| {
                        try out.writer.print(" content={s}", .{jsonKindName(content_value)});
                        if (content_value == .array) try out.writer.print(" parts={d}", .{content_value.array.items.len});
                    } else {
                        try out.writer.writeAll(" content=missing");
                    }
                } else {
                    try out.writer.print(" entry={s}", .{jsonKindName(entry)});
                }
            }
            if (prompt.array.items.len > limit) {
                try out.writer.print(" prompt_omitted={d}", .{prompt.array.items.len - limit});
            }
        } else {
            try out.writer.print(" prompt={s}", .{jsonKindName(prompt)});
        }
    } else {
        try out.writer.writeAll(" prompt=missing");
    }

    if (parsed.value.object.get("tools")) |tools| {
        try out.writer.print(" tools={s}", .{jsonKindName(tools)});
        if (tools == .array) try out.writer.print(" tools_count={d}", .{tools.array.items.len});
    }

    if (parsed.value.object.get("toolChoice")) |tool_choice| {
        if (tool_choice == .object) {
            if (tool_choice.object.get("type")) |type_value| {
                try out.writer.writeAll(" toolChoice=");
                if (type_value == .string) {
                    try appendSafeShapeToken(&out.writer, type_value.string);
                } else {
                    try out.writer.writeAll(jsonKindName(type_value));
                }
            } else {
                try out.writer.writeAll(" toolChoice=object");
            }
        } else {
            try out.writer.print(" toolChoice={s}", .{jsonKindName(tool_choice)});
        }
    }

    if (parsed.value.object.get("providerOptions")) |provider_options| {
        try out.writer.print(" providerOptions={s}", .{jsonKindName(provider_options)});
        if (provider_options == .object) try out.writer.print(" providerOptions_count={d}", .{provider_options.object.count()});
    }

    return try out.toOwnedSlice();
}

fn appendSafeShapeToken(writer: *std.Io.Writer, raw: []const u8) !void {
    var wrote = false;
    var last_was_underscore = false;
    for (raw) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', '[', ']' => {
                try writer.writeByte(c);
                wrote = true;
                last_was_underscore = c == '_';
            },
            else => {
                if (!last_was_underscore) {
                    try writer.writeByte('_');
                    wrote = true;
                    last_was_underscore = true;
                }
            },
        }
    }
    if (!wrote) try writer.writeAll("unknown");
}

fn jsonKindName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "bool",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

pub fn parseGatewayCompletion(alloc: std.mem.Allocator, body: []const u8) !GatewayCompletion {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidGatewayResponse;

    const choices = root.object.get("choices") orelse return error.InvalidGatewayResponse;
    if (choices != .array or choices.array.items.len == 0) return error.InvalidGatewayResponse;

    const choice = choices.array.items[0];
    if (choice != .object) return error.InvalidGatewayResponse;

    const message_value = choice.object.get("message") orelse return error.InvalidGatewayResponse;
    if (message_value != .object) return error.InvalidGatewayResponse;

    var output: GatewayCompletion = .{};
    if (message_value.object.get("content")) |content| {
        if (content == .string) output.content = try alloc.dupe(u8, content.string);
    }
    errdefer freeGatewayCompletion(alloc, output);

    if (choice.object.get("finish_reason")) |finish_reason| {
        if (finish_reason == .string and finish_reason.string.len > 0) {
            output.finish_reason = types.ProviderFinishReason.parse_legacy(finish_reason.string) orelse
                return error.InvalidGatewayResponse;
        }
    }

    if (message_value.object.get("tool_calls")) |tool_calls| {
        if (tool_calls == .array and tool_calls.array.items.len > 0) {
            const buffer = try alloc.alloc(ToolCall, tool_calls.array.items.len);
            var count: usize = 0;
            errdefer {
                for (buffer[0..count]) |tool_call| {
                    alloc.free(tool_call.id);
                    alloc.free(tool_call.name);
                    alloc.free(tool_call.arguments_json);
                }
                alloc.free(buffer);
            }

            for (tool_calls.array.items) |item| {
                if (item != .object) continue;
                const id = item.object.get("id") orelse continue;
                if (id != .string) continue;
                const fn_value = item.object.get("function") orelse continue;
                if (fn_value != .object) continue;
                const name = fn_value.object.get("name") orelse continue;
                const args = fn_value.object.get("arguments") orelse continue;
                if (name != .string or args != .string) continue;
                if (try types.ToolArgumentIntegrity.classifySerialized(alloc, args.string) == .malformed_json) {
                    return error.InvalidGatewayResponse;
                }
                const id_copy = try alloc.dupe(u8, id.string);
                errdefer alloc.free(id_copy);
                const name_copy = try alloc.dupe(u8, name.string);
                errdefer alloc.free(name_copy);
                const arguments_copy = try alloc.dupe(u8, args.string);
                errdefer alloc.free(arguments_copy);

                buffer[count] = .{
                    .id = id_copy,
                    .name = name_copy,
                    .arguments_json = arguments_copy,
                };
                count += 1;
            }
            if (count == 0) {
                alloc.free(buffer);
            } else if (count < buffer.len) {
                output.tool_calls = try alloc.dupe(ToolCall, buffer[0..count]);
                alloc.free(buffer);
            } else {
                output.tool_calls = buffer;
            }
        }
    }

    return output;
}

pub fn freeGatewayCompletion(alloc: std.mem.Allocator, completion: GatewayCompletion) void {
    if (completion.content) |content| alloc.free(content);
    for (completion.tool_calls) |tool_call| {
        alloc.free(tool_call.id);
        alloc.free(tool_call.name);
        alloc.free(tool_call.arguments_json);
    }
    if (completion.tool_calls.len > 0) alloc.free(completion.tool_calls);
    if (completion.provider_state_json) |state| alloc.free(state);
}

fn checkParseGatewayCompletionAllocFailures(alloc: std.mem.Allocator) !void {
    const body = "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"content\":\"hello\",\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"write_file\",\"arguments\":\"{}\"}},{\"id\":\"call_2\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"src/main.zig\\\"}\"}}]}}]}";

    const completion = try parseGatewayCompletion(alloc, body);
    defer freeGatewayCompletion(alloc, completion);

    try std.testing.expectEqualStrings("hello", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 2), completion.tool_calls.len);
}

test "roleName returns exact gateway role strings" {
    try std.testing.expectEqualStrings("system", roleName(.system));
    try std.testing.expectEqualStrings("user", roleName(.user));
    try std.testing.expectEqualStrings("assistant", roleName(.assistant));
    try std.testing.expectEqualStrings("tool", roleName(.tool));
}

test "gateway request serializes an optional structured response format" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{.{ .role = .user, .content = "inspect" }};
    var schema = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"object\",\"additionalProperties\":false}",
        .{},
    );
    defer schema.deinit();
    const body = try buildGatewayRequestBodyValidated(
        alloc,
        "[]",
        &messages,
        .{},
        "none",
        null,
        null,
        .{
            .name = "fx_vision_evidence",
            .description = "Evidence \"only\"",
            .schema = schema.value,
        },
        null,
    );
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const format = parsed.value.object.get("responseFormat").?;
    try std.testing.expectEqualStrings("json", format.object.get("type").?.string);
    try std.testing.expectEqualStrings("fx_vision_evidence", format.object.get("name").?.string);
    try std.testing.expectEqualStrings("Evidence \"only\"", format.object.get("description").?.string);
    try std.testing.expectEqualStrings("object", format.object.get("schema").?.object.get("type").?.string);

    const plain = try buildGatewayRequestBody(alloc, "[]", &messages);
    defer alloc.free(plain);
    var plain_parsed = try std.json.parseFromSlice(std.json.Value, alloc, plain, .{});
    defer plain_parsed.deinit();
    try std.testing.expect(plain_parsed.value.object.get("responseFormat") == null);

    try std.testing.expectError(
        error.InvalidStructuredResponseSchema,
        buildGatewayRequestBodyValidated(
            alloc,
            "[]",
            &messages,
            .{},
            "none",
            null,
            null,
            .{
                .name = "invalid",
                .description = "invalid",
                .schema = .{ .string = "not json" },
            },
            null,
        ),
    );
}

test "writeChatMessageJson serializes user text plus image file parts through core image writer" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var file = try tmp.dir.createFile(std.testing.io, "image.png", .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, "\x89PNG\r\n\x1a\nabc");
    }

    const image_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "image.png");
    defer alloc.free(image_path);

    const source = [_]types.ImageAttachment{.{
        .id = 1,
        .path = @constCast(image_path),
        .media_type = @constCast("image/png"),
    }};
    const images = try types.dupeImageAttachmentSlice(alloc, &source);
    defer types.freeImageAttachmentSlice(alloc, images);
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const snapshot_dir = try std.fs.path.join(alloc, &.{ root, "snapshots" });
    defer alloc.free(snapshot_dir);
    try image_attachments.captureImageSnapshot(alloc, &images[0], snapshot_dir);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeChatMessageJson(alloc, &out.writer, .{
        .role = .user,
        .content = "look",
        .images = images,
    });
    const json = out.written();

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"text\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"text\":\"look\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"file\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"mediaType\":\"image/png\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"data\":\"iVBORw0KGgphYmM=\"") != null);
}

test "writeChatMessageJson serializes assistant tool call input as raw json" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/main.zig\"}",
    }};

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeChatMessageJson(alloc, &out.writer, .{
        .role = .assistant,
        .content = "I will read it",
        .tool_calls = &calls,
    });
    const json = out.written();

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"tool-call\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"toolCallId\":\"call_1\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"toolName\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"input\":{\"path\":\"src/main.zig\"}") != null);
}

test "writeChatMessageJson serializes tool-result fallbacks and escaped output" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeChatMessageJson(alloc, &out.writer, .{
        .role = .tool,
        .content = "line\n\ttext",
    });
    const json = out.written();

    try std.testing.expect(std.mem.find(u8, json, "\"type\":\"tool-result\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"toolCallId\":\"\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"toolName\":\"unknown\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"value\":\"line\\n\\ttext\"") != null);
}

test "writeChatMessageJson maps tool result status to the Vercel output variant" {
    const denial = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"policy_denied\"}}";
    const review_hold = "{\"error\":{\"type\":\"tool_review_held\",\"reason\":\"review_caution\"}}";
    const malformed_denial = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"review_caution\"}}";
    const cases = [_]struct {
        status: ?types.PersistedToolStatus,
        content: []const u8,
        output_type: []const u8,
        content_field: []const u8,
    }{
        .{ .status = null, .content = "untyped result", .output_type = "text", .content_field = "value" },
        .{ .status = .success, .content = "successful result", .output_type = "text", .content_field = "value" },
        .{ .status = .failure, .content = "ordinary failure", .output_type = "error-text", .content_field = "value" },
        .{ .status = .failure, .content = denial, .output_type = "execution-denied", .content_field = "reason" },
        .{ .status = .failure, .content = review_hold, .output_type = "execution-denied", .content_field = "reason" },
        .{ .status = .success, .content = denial, .output_type = "text", .content_field = "value" },
        .{ .status = .failure, .content = malformed_denial, .output_type = "error-text", .content_field = "value" },
    };

    for (cases) |case| {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();

        try writeChatMessageJson(std.testing.allocator, &out.writer, .{
            .role = .tool,
            .content = case.content,
            .tool_call_id = "call_1",
            .tool_name = "terminal",
            .tool_result_status = case.status,
        });

        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            out.written(),
            .{},
        );
        defer parsed.deinit();
        const result = parsed.value.object.get("content").?.array.items[0].object;
        const output = result.get("output").?.object;

        try std.testing.expectEqualStrings("call_1", result.get("toolCallId").?.string);
        try std.testing.expectEqualStrings("terminal", result.get("toolName").?.string);
        try std.testing.expectEqualStrings(case.output_type, output.get("type").?.string);
        try std.testing.expectEqualStrings(case.content, output.get(case.content_field).?.string);
        const absent_field = if (std.mem.eql(u8, case.content_field, "value")) "reason" else "value";
        try std.testing.expect(output.get(absent_field) == null);
    }
}

test "Gateway request replays reasoning and call metadata without changing canonical input" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{.{ .id = "call-1", .name = "read_file", .arguments_json = "{\"path\":\"file\"}" }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .content = "visible", .tool_calls = &calls, .provider_replay = .{
            .source = .{ .provider = .gateway, .model = "test" },
            .parts_json = "[{\"type\":\"reasoning\",\"text\":\"\",\"providerOptions\":{\"openai\":{\"reasoningEncryptedContent\":\"opaque\"}}},{\"type\":\"text\",\"offset\":0,\"length\":7},{\"type\":\"tool-call\",\"toolCallId\":\"call-1\",\"providerOptions\":{\"vertex\":{\"thoughtSignature\":\"signature\"}}}]",
        } },
        .{ .role = .tool, .tool_call_id = "call-1", .tool_name = "read_file", .content = "result" },
    };
    const body = try buildGatewayRequestBody(alloc, "[]", &messages);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const parts = parsed.value.object.get("prompt").?.array.items[0].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("reasoning", parts[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("opaque", parts[0].object.get("providerOptions").?.object.get("openai").?.object.get("reasoningEncryptedContent").?.string);
    try std.testing.expectEqualStrings("visible", parts[1].object.get("text").?.string);
    try std.testing.expectEqualStrings("read_file", parts[2].object.get("toolName").?.string);
    try std.testing.expectEqualStrings("file", parts[2].object.get("input").?.object.get("path").?.string);
    try std.testing.expectEqualStrings("signature", parts[2].object.get("providerOptions").?.object.get("vertex").?.object.get("thoughtSignature").?.string);
}

test "Gateway automatic caching preserves transient context and grouped tool results" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        .{ .id = "first", .name = "read_file", .arguments_json = "{}" },
        .{ .id = "second", .name = "read_file", .arguments_json = "{}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "stable instructions" },
        .{ .role = .system, .content = "runtime context" },
        .{ .role = .user, .content = "read both" },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "first", .tool_name = "read_file", .content = "A" },
        .{ .role = .tool, .tool_call_id = "second", .tool_name = "read_file", .content = "B" },
    };
    const body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{
        .prompt_caching = true,
        .fast = true,
        .parallel_tool_calls = false,
    }, .auto);
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const options = parsed.value.object.get("providerOptions").?.object;
    const gateway = options.get("gateway").?.object;
    const caching = gateway.get("caching") orelse return error.TestExpectedAutomaticCaching;
    try std.testing.expectEqualStrings("auto", caching.string);
    try std.testing.expectEqualStrings("fast", gateway.get("speed").?.string);
    try std.testing.expect(!options.get("xai").?.object.get("parallelToolCalls").?.bool);
    try std.testing.expect(std.mem.find(u8, body, "cacheControl") == null);
    const prompt = parsed.value.object.get("prompt").?.array.items;
    try std.testing.expectEqualStrings("runtime context", prompt[1].object.get("content").?.string);
    const results = prompt[4].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("A", results[0].object.get("output").?.object.get("value").?.string);
    try std.testing.expectEqualStrings("B", results[1].object.get("output").?.object.get("value").?.string);

    const default_body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{
        .fast = true,
        .parallel_tool_calls = false,
    }, .auto);
    defer alloc.free(default_body);
    const without_cache_option = try std.mem.replaceOwned(u8, alloc, body, ",\"caching\":\"auto\"", "");
    defer alloc.free(without_cache_option);
    try std.testing.expectEqualStrings(default_body, without_cache_option);
}

test "buildGatewayRequestBodyWithOptions keeps Anthropic default silent and named effort provider neutral" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "question" },
    };

    const default_body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto);
    defer alloc.free(default_body);
    var default_parsed = try std.json.parseFromSlice(std.json.Value, alloc, default_body, .{});
    defer default_parsed.deinit();
    try std.testing.expect(default_parsed.value.object.get("reasoning") == null);
    try std.testing.expect(default_parsed.value.object.get("providerOptions") == null);

    const named_body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{
        .reasoning = types.ReasoningEffort.literal("future-tier"),
    }, .auto);
    defer alloc.free(named_body);
    var named_parsed = try std.json.parseFromSlice(std.json.Value, alloc, named_body, .{});
    defer named_parsed.deinit();
    try std.testing.expectEqualStrings("future-tier", named_parsed.value.object.get("reasoning").?.string);
    try std.testing.expect(named_parsed.value.object.get("providerOptions") == null);
}

test "required gateway request serializes required tool choice and max output" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "question" },
    };

    const body = try buildGatewayRequiredToolRequestBodyWithMaxOutputTokens(alloc, "[]", &messages, 4096);
    defer alloc.free(body);

    try std.testing.expectEqualStrings(
        "{\"prompt\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"question\"}]}],\"tools\":[],\"toolChoice\":{\"type\":\"required\"},\"maxOutputTokens\":4096}",
        body,
    );
}

test "required gateway request validates history" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "question" },
        .{ .role = .tool, .content = "orphan", .tool_call_id = "call_1", .tool_name = "read_file" },
    };

    try std.testing.expectError(
        error.InvalidGatewayHistory,
        buildGatewayRequiredToolRequestBodyWithMaxOutputTokens(alloc, "[]", &messages, 4096),
    );
}

test "gateway request rejects system messages after conversation" {
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "question" },
        .{ .role = .system, .content = "late instruction" },
    };

    try std.testing.expectError(
        error.InvalidGatewayHistory,
        buildGatewayRequestBody(std.testing.allocator, "[]", &messages),
    );
}

test "pending tool review closes the exact assistant step with synthetic pending results" {
    var cancel = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(1000),
    });
    const instructions = [_]ChatMessage{.{ .role = .system, .content = "Review only install." }};
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "Install dependencies." },
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "install", .name = "run_command", .arguments_json = "{\"command\":\"pnpm install\"}" },
            .{ .id = "read", .name = "read_file", .arguments_json = "{\"path\":\"package.json\"}" },
        } },
    };

    const body = try buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
        std.testing.allocator,
        "[]",
        &instructions,
        &messages,
        "install",
        .{ .reasoning = types.ReasoningEffort.literal("minimal") },
        2048,
        deadline,
        &cancel,
    );
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"toolCallId\":\"install\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"toolCallId\":\"read\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "\"role\":\"tool\""));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"type\":\"tool-result\""));
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, body, "Tool call has not executed; it is pending permission review."),
    );
    const system_index = std.mem.find(u8, body, "\"role\":\"system\"").?;
    const user_index = std.mem.find(u8, body, "\"role\":\"user\"").?;
    try std.testing.expect(system_index < user_index);
    try std.testing.expect(std.mem.find(u8, body, "\"maxOutputTokens\":2048") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\":\"minimal\"") != null);
    try std.testing.expectError(
        error.InvalidGatewayHistory,
        buildGatewayRequestBody(std.testing.allocator, "[]", &messages),
    );
}

test "pending review and model requests enforce the same prompt lanes" {
    var cancel = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(1000),
    });
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "Read this." },
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "read", .name = "read_file", .arguments_json = "{}" },
        } },
    };
    const invalid = [_]ChatMessage{
        .{ .role = .user, .content = "not instructions" },
        .{ .role = .system },
        .{ .role = .system, .content = "rules", .provider_replay = .{ .source = .{ .provider = .gateway, .model = "test" }, .parts_json = "{}" } },
        .{ .role = .system, .content = "rules", .permission_feedback = true },
    };
    for (invalid) |instruction| {
        const request = stream_provider.RequestData{
            .model = "review-model",
            .instructions = &.{instruction},
            .messages = &messages,
            .tool_choice = .auto,
            .provider_options = .{},
        };
        try std.testing.expectError(error.InvalidProviderPrompt, request.validatePrompt());
        try std.testing.expectError(
            error.InvalidGatewayHistory,
            buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
                std.testing.allocator,
                "[]",
                &.{instruction},
                &messages,
                "read",
                .{},
                2048,
                deadline,
                &cancel,
            ),
        );
    }
}

test "pending tool review rejects missing or duplicate target ids" {
    var cancel = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(1000),
    });
    const instructions = [_]ChatMessage{.{ .role = .system, .content = "Review it." }};
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "Run this." },
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "duplicate", .name = "run_command", .arguments_json = "{}" },
            .{ .id = "duplicate", .name = "read_file", .arguments_json = "{}" },
        } },
    };

    try std.testing.expectError(
        error.InvalidGatewayHistory,
        buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
            std.testing.allocator,
            "[]",
            &instructions,
            &messages,
            "duplicate",
            .{},
            2048,
            deadline,
            &cancel,
        ),
    );
    try std.testing.expectError(
        error.InvalidGatewayHistory,
        buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
            std.testing.allocator,
            "[]",
            &instructions,
            &messages,
            "missing",
            .{},
            2048,
            deadline,
            &cancel,
        ),
    );
}

test "buildGatewayRequestBodyWithOptions serializes Gateway Fast provider options" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "question" },
    };

    const body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{
        .reasoning = types.ReasoningEffort.literal("future-tier"),
        .fast = true,
    }, .auto);
    defer alloc.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("future-tier", parsed.value.object.get("reasoning").?.string);
    try std.testing.expect(parsed.value.object.get("fast") == null);
    const provider_options = parsed.value.object.get("providerOptions").?;
    const gateway = provider_options.object.get("gateway").?;
    try std.testing.expectEqualStrings("fast", gateway.object.get("speed").?.string);

    const automatic = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto);
    defer alloc.free(automatic);
    var parsed_automatic = try std.json.parseFromSlice(std.json.Value, alloc, automatic, .{});
    defer parsed_automatic.deinit();
    try std.testing.expect(parsed_automatic.value.object.get("reasoning") == null);
    try std.testing.expect(parsed_automatic.value.object.get("fast") == null);
    try std.testing.expect(parsed_automatic.value.object.get("providerOptions") == null);
}

test "buildGatewayRequestBodyWithOptions combines Gateway Fast and xai options" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "question" },
    };

    const body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{
        .fast = true,
        .parallel_tool_calls = true,
    }, .auto);
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"providerOptions\":{\"gateway\":{\"speed\":\"fast\"},\"xai\":{\"parallelToolCalls\":true}}") != null);
}

test "formatGatewayRequestShapeSummary reports content kinds without request content" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"SECRET_TOOL_ARGUMENT_PATH\"}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "SECRET_SYSTEM_PROMPT" },
        .{ .role = .user, .content = "SECRET_USER_PROMPT" },
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "SECRET_TOOL_OUTPUT", .tool_call_id = "call_1", .tool_name = "read_file" },
    };

    const body = try buildGatewayRequestBodyWithOptions(
        alloc,
        "[{\"name\":\"SECRET_TOOL_SCHEMA\"}]",
        &messages,
        .{},
        .auto,
    );
    defer alloc.free(body);

    const valid_summary = try formatGatewayRequestShapeSummary(alloc, body);
    defer alloc.free(valid_summary);

    try std.testing.expect(std.mem.find(u8, valid_summary, "prompt_count=4") != null);
    try std.testing.expect(std.mem.find(u8, valid_summary, "prompt.0 role=system content=string") != null);
    try std.testing.expect(std.mem.find(u8, valid_summary, "prompt.1 role=user content=array") != null);
    try std.testing.expect(std.mem.find(u8, valid_summary, "prompt.2 role=assistant content=array") != null);
    try std.testing.expect(std.mem.find(u8, valid_summary, "prompt.3 role=tool content=array") != null);
    try std.testing.expect(std.mem.find(u8, valid_summary, "tools_count=1") != null);
    try std.testing.expect(std.mem.find(u8, valid_summary, "toolChoice=auto") != null);
    try std.testing.expect(std.mem.find(u8, valid_summary, "SECRET_SYSTEM_PROMPT") == null);
    try std.testing.expect(std.mem.find(u8, valid_summary, "SECRET_USER_PROMPT") == null);
    try std.testing.expect(std.mem.find(u8, valid_summary, "SECRET_TOOL_ARGUMENT_PATH") == null);
    try std.testing.expect(std.mem.find(u8, valid_summary, "SECRET_TOOL_OUTPUT") == null);
    try std.testing.expect(std.mem.find(u8, valid_summary, "SECRET_TOOL_SCHEMA") == null);

    const mutated =
        \\{"prompt":[{"role":"system","content":[{"type":"text","text":"SECRET_MUTATED_SYSTEM"}]}],"tools":[],"toolChoice":{"type":"auto"}}
    ;
    const mutated_summary = try formatGatewayRequestShapeSummary(alloc, mutated);
    defer alloc.free(mutated_summary);

    try std.testing.expect(std.mem.find(u8, mutated_summary, "prompt.0 role=system content=array") != null);
    try std.testing.expect(std.mem.find(u8, mutated_summary, "SECRET_MUTATED_SYSTEM") == null);
}

test "buildGatewayRequestBodyWithOptions leaves one-shot caching to the provider" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "system prompt" },
        .{ .role = .user, .content = "question" },
    };
    const body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto);
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "cacheControl") == null);
    try std.testing.expect(std.mem.find(u8, body, "providerOptions") == null);
}

test "tool result grouping borrows only the leading contiguous results" {
    const messages = [_]ChatMessage{
        .{ .role = .tool, .content = "first" },
        .{ .role = .tool, .content = "second" },
        .{ .role = .user, .content = "boundary" },
        .{ .role = .tool, .content = "later" },
    };
    const group = tool_result_prefix(&messages);
    try std.testing.expectEqual(@as(usize, 2), group.len);
    try std.testing.expect(group.ptr == messages[0..].ptr);
    try std.testing.expectEqual(@as(usize, 0), tool_result_prefix(messages[2..]).len);
    try std.testing.expectEqual(@as(usize, 1), tool_result_prefix(messages[3..]).len);
    try std.testing.expectEqual(@as(usize, 0), tool_result_prefix(&.{}).len);
    try std.testing.expectEqualStrings("boundary", messages[2].content.?);
}

test "gateway request serialization keeps each tool result group together" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        .{ .id = "call_a", .name = "read_a", .arguments_json = "{}" },
        .{ .id = "call_b", .name = "read_b", .arguments_json = "{}" },
        .{ .id = "call_c", .name = "read_c", .arguments_json = "{}" },
    };
    const denial = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"policy_denied\"}}";
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "read all three" },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "call_a", .tool_name = "read_a", .content = "A\n\"quoted\"", .tool_result_status = .success },
        .{ .role = .tool, .tool_call_id = "call_b", .tool_name = "read_b", .content = "failed", .tool_result_status = .failure },
        .{ .role = .tool, .tool_call_id = "call_c", .tool_name = "read_c", .content = denial, .tool_result_status = .failure },
        .{ .role = .user, .content = "try again" },
        .{ .role = .assistant, .tool_calls = calls[0..1] },
        .{ .role = .tool, .tool_call_id = "call_a", .tool_name = "read_a", .content = "", .tool_result_status = .success },
        .{ .role = .assistant, .content = "done" },
    };
    const body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto);
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const prompt = parsed.value.object.get("prompt").?.array.items;
    try std.testing.expectEqual(@as(usize, 7), prompt.len);
    const roles = [_][]const u8{ "user", "assistant", "tool", "user", "assistant", "tool", "assistant" };
    for (prompt, roles) |message, role| {
        try std.testing.expectEqualStrings(role, message.object.get("role").?.string);
    }
    const results = prompt[2].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), results.len);
    const output_types = [_][]const u8{ "text", "error-text", "execution-denied" };
    const output_values = [_][]const u8{ "A\n\"quoted\"", "failed", denial };
    for (results, calls, output_types, output_values) |result, call, output_type, output_value| {
        try std.testing.expectEqualStrings("tool-result", result.object.get("type").?.string);
        try std.testing.expectEqualStrings(call.id, result.object.get("toolCallId").?.string);
        try std.testing.expectEqualStrings(call.name, result.object.get("toolName").?.string);
        const output = result.object.get("output").?.object;
        try std.testing.expectEqualStrings(output_type, output.get("type").?.string);
        const value = output.get("value") orelse output.get("reason").?;
        try std.testing.expectEqualStrings(output_value, value.string);
    }
    const later = prompt[5].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), later.len);
    try std.testing.expectEqualStrings("", later[0].object.get("output").?.object.get("value").?.string);
    const repeated = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto);
    defer alloc.free(repeated);
    try std.testing.expectEqualStrings(body, repeated);
    try std.testing.expectEqualStrings("A\n\"quoted\"", messages[2].content.?);
    try std.testing.expectEqualStrings(denial, messages[4].content.?);
}

test "grouped tool results retain images and individual error status" {
    const alloc = std.testing.allocator;
    const images = [_]types.ToolImage{.{ .data = @constCast("cG5n"), .mime_type = @constCast("image/png") }};
    const source_id = "functions.capture:0";
    const calls = [_]ToolCall{
        .{ .id = source_id, .name = "capture", .arguments_json = "{}" },
        .{ .id = "labels", .name = "read_labels", .arguments_json = "{}" },
    };
    for ([_]types.PersistedToolStatus{ .success, .failure }) |status| {
        const messages = [_]ChatMessage{
            .{ .role = .assistant, .tool_calls = &calls },
            .{ .role = .tool, .tool_call_id = source_id, .tool_name = "capture", .content = "capture", .tool_result_status = status, .tool_result_memory = .{ .tool_images = &images } },
            .{ .role = .tool, .tool_call_id = "labels", .tool_name = "read_labels", .content = "labels", .tool_result_status = .success },
        };
        const body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{ .prompt_caching = true }, .auto);
        defer alloc.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer parsed.deinit();
        const prompt = parsed.value.object.get("prompt").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), prompt.len);
        const results = prompt[1].object.get("content").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), results.len);
        const projected_id = prompt[0].object.get("content").?.array.items[0].object.get("toolCallId").?.string;
        try std.testing.expectEqualStrings("auto", parsed.value.object.get("providerOptions").?.object.get("gateway").?.object.get("caching").?.string);
        try std.testing.expect(std.mem.find(u8, body, "cacheControl") == null);
        try std.testing.expect(!std.mem.eql(u8, source_id, projected_id));
        try std.testing.expectEqualStrings(projected_id, results[0].object.get("toolCallId").?.string);
        try std.testing.expectEqualStrings(source_id, messages[1].tool_call_id.?);
        const media = results[0].object.get("output").?.object;
        try std.testing.expectEqualStrings("content", media.get("type").?.string);
        const parts = media.get("value").?.array.items;
        try std.testing.expectEqual(@as(usize, 2), parts.len);
        try std.testing.expectEqualStrings(if (status == .failure) "Tool error: capture" else "capture", parts[0].object.get("text").?.string);
        try std.testing.expectEqualStrings("image-data", parts[1].object.get("type").?.string);
        try std.testing.expectEqualStrings(images[0].data, parts[1].object.get("data").?.string);
        try std.testing.expectEqualStrings("image/png", parts[1].object.get("mediaType").?.string);
        try std.testing.expectEqualStrings("labels", results[1].object.get("toolCallId").?.string);
        const plain = results[1].object.get("output").?.object;
        try std.testing.expectEqualStrings("text", plain.get("type").?.string);
        try std.testing.expectEqualStrings("labels", plain.get("value").?.string);
    }
}

test "grouped tool results preserve request budgets with automatic caching" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        .{ .id = "a", .name = "read_file", .arguments_json = "{}" },
        .{ .id = "b", .name = "read_file", .arguments_json = "{}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "rules" },
        .{ .role = .user, .content = "read" },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "a", .tool_name = "read_file", .content = "A" },
        .{ .role = .tool, .tool_call_id = "b", .tool_name = "read_file", .content = "B" },
        .{ .role = .assistant, .content = "summary" },
        .{ .role = .user, .content = "continue" },
    };
    const body = try buildGatewayRequestBodyWithOptionsAndBudget(alloc, "[]", &messages, .{ .prompt_caching = true }, .auto, null, .{});
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const prompt = parsed.value.object.get("prompt").?.array.items;
    try std.testing.expectEqual(@as(usize, 6), prompt.len);
    try std.testing.expectEqual(@as(usize, 2), prompt[3].object.get("content").?.array.items.len);
    try std.testing.expectEqualStrings("auto", parsed.value.object.get("providerOptions").?.object.get("gateway").?.object.get("caching").?.string);
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, buildGatewayRequestBodyWithOptionsAndBudget(alloc, "[]", &messages, .{ .prompt_caching = true }, .auto, null, .{ .cancel_flag = &cancel }));
    const expired = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{ .clock = .awake, .raw = .fromMilliseconds(-1) });
    try std.testing.expectError(error.TimedOut, buildGatewayRequestBodyWithOptionsAndBudget(alloc, "[]", &messages, .{ .prompt_caching = true }, .auto, null, .{ .deadline = expired }));
}

fn check_grouped_request_allocations(alloc: std.mem.Allocator) !void {
    const calls = [_]ToolCall{
        .{ .id = "a", .name = "read_file", .arguments_json = "{}" },
        .{ .id = "b", .name = "read_file", .arguments_json = "{}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "a", .tool_name = "read_file", .content = "first" },
        .{ .role = .tool, .tool_call_id = "b", .tool_name = "read_file", .content = "second" },
    };
    const body = buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{ .prompt_caching = true }, .auto) catch |err| switch (err) {
        // The allocation checker expects OOM; this writer has no other failure source.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    defer alloc.free(body);
}

test "grouped tool result serialization releases failed allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_grouped_request_allocations, .{});
}

test "gateway request validation accepts paired assistant tool calls and results" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/main.zig\"}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "read it" },
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "contents", .tool_call_id = "call_1", .tool_name = "read_file" },
        .{ .role = .assistant, .content = "done" },
    };

    const body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto);
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"toolCallId\":\"call_1\"") != null);
}

test "gateway request validation rejects unpaired tool result" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "hello" },
        .{ .role = .tool, .content = "orphan", .tool_call_id = "call_1", .tool_name = "read_file" },
    };

    try std.testing.expectError(error.InvalidGatewayHistory, buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto));
}

test "gateway request validation rejects malformed tool call arguments" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{not json",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "contents", .tool_call_id = "call_1", .tool_name = "read_file" },
    };

    try std.testing.expectError(error.InvalidGatewayHistory, buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto));
}

test "gateway request validation rejects duplicate-key tool call arguments" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{\"depth\":1,\"depth\":2}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "contents", .tool_call_id = "call_1", .tool_name = "read_file" },
    };

    try std.testing.expectError(error.InvalidGatewayHistory, buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto));
}

test "gateway request validation preserves argument parser allocation failure" {
    var calls = [_]ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/main.zig\"}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "contents", .tool_call_id = "call_1", .tool_name = "read_file" },
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(error.OutOfMemory, validateToolMessageHistory(failing.allocator(), &messages));
}

test "gateway request validation rejects assistant tool call without result" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .assistant, .content = "next" },
    };

    try std.testing.expectError(error.InvalidGatewayHistory, buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto));
}

test "gateway request validation accepts out-of-order tool results by id" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{
        .{
            .id = "call_1",
            .name = "read_file",
            .arguments_json = "{\"path\":\"a.txt\"}",
        },
        .{
            .id = "call_2",
            .name = "glob_files",
            .arguments_json = "{\"pattern\":\"*\"}",
        },
    };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "second", .tool_call_id = "call_2", .tool_name = "glob_files" },
        .{ .role = .tool, .content = "first", .tool_call_id = "call_1", .tool_name = "read_file" },
    };

    const body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto);
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"toolCallId\":\"call_2\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"toolCallId\":\"call_1\"") != null);
}

test "gateway request validation rejects duplicate tool result ids" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{
        .{
            .id = "call_1",
            .name = "read_file",
            .arguments_json = "{\"path\":\"a.txt\"}",
        },
        .{
            .id = "call_2",
            .name = "glob_files",
            .arguments_json = "{\"pattern\":\"*\"}",
        },
    };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "first", .tool_call_id = "call_1", .tool_name = "read_file" },
        .{ .role = .tool, .content = "duplicate", .tool_call_id = "call_1", .tool_name = "read_file" },
    };

    try std.testing.expectError(error.InvalidGatewayHistory, buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto));
}

test "gateway request validation rejects mismatched tool result names" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/main.zig\"}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "contents", .tool_call_id = "call_1", .tool_name = "write_file" },
    };

    try std.testing.expectError(error.InvalidGatewayHistory, buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto));
}

test "parseGatewayCompletion duplicates returned strings" {
    const alloc = std.testing.allocator;
    const body = try alloc.dupe(
        u8,
        "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"hello\",\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{}\"}}]}}]}",
    );
    defer alloc.free(body);

    const completion = try parseGatewayCompletion(alloc, body);
    defer freeGatewayCompletion(alloc, completion);

    @memset(body, 'x');

    try std.testing.expectEqualStrings("hello", completion.content.?);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{}", completion.tool_calls[0].arguments_json);
}

test "parseGatewayCompletion skips malformed tool call entries" {
    const alloc = std.testing.allocator;
    const body =
        "{\"choices\":[{\"message\":{\"content\":\"ok\",\"tool_calls\":[" ++
        "42," ++
        "{\"id\":7,\"function\":{\"name\":\"bad\",\"arguments\":\"{}\"}}," ++
        "{\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a\\\"}\"}}" ++
        "]}}]}";

    const completion = try parseGatewayCompletion(alloc, body);
    defer freeGatewayCompletion(alloc, completion);

    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", completion.tool_calls[0].arguments_json);
}

test "parseGatewayCompletion rejects malformed legacy tool arguments" {
    const body =
        "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"tool_calls\":[" ++
        "{\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{]\"}}" ++
        "]}}]}";

    try std.testing.expectError(
        error.InvalidGatewayResponse,
        parseGatewayCompletion(std.testing.allocator, body),
    );
}

test "parseGatewayCompletion rejects duplicate-key legacy tool arguments" {
    const body =
        "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"tool_calls\":[" ++
        "{\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"depth\\\":1,\\\"depth\\\":2}\"}}" ++
        "]}}]}";

    try std.testing.expectError(
        error.InvalidGatewayResponse,
        parseGatewayCompletion(std.testing.allocator, body),
    );
}

test "parseGatewayCompletion cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkParseGatewayCompletionAllocFailures, .{});
}

test "freeGatewayCompletion frees parsed completions under testing allocator" {
    const alloc = std.testing.allocator;
    const body = "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"content\":\"hello\",\"tool_calls\":[{\"id\":\"call_1\",\"function\":{\"name\":\"write_file\",\"arguments\":\"{}\"}}]}}]}";

    const completion = try parseGatewayCompletion(alloc, body);
    freeGatewayCompletion(alloc, completion);
}
