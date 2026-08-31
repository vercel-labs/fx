const std = @import("std");
const image_attachments = @import("../core/images/image_attachments.zig");
const io_mod = @import("../core/shared/io.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const types = @import("../core/shared/types.zig");

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

pub fn writeChatMessageJson(
    scratch_alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ChatMessage,
) !void {
    writeChatMessageJsonInner(scratch_alloc, writer, message, false, null, null) catch |err| return err;
}

pub fn writeChatMessageJsonCached(
    scratch_alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ChatMessage,
) !void {
    writeChatMessageJsonInner(scratch_alloc, writer, message, true, null, null) catch |err| return err;
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
    messages: []const ChatMessage,
    target_call_id: []const u8,
    options: model_capabilities.ResolvedProviderOptions,
    max_output_tokens: u32,
    deadline: std.Io.Clock.Timestamp,
    cancel_flag: *std.atomic.Value(bool),
) ![]u8 {
    const budget = BuildBudget{ .deadline = deadline, .cancel_flag = cancel_flag };
    const expanded = try expandPendingToolReviewMessages(
        alloc,
        messages,
        target_call_id,
        deadline,
        cancel_flag,
    );
    defer alloc.free(expanded);

    return buildGatewayRequestBodyValidated(
        alloc,
        tools_json,
        expanded,
        options,
        "required",
        max_output_tokens,
        budget,
        null,
        null,
    );
}

/// Returns an owned message slice that closes the pending tool call before the
/// reviewer instruction. Message contents remain borrowed from `messages`.
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

    const pending_index = messages.len - 2;
    const pending = messages[pending_index];
    const expanded_len = try std.math.add(usize, messages.len, pending.tool_calls.len);
    const expanded = try alloc.alloc(ChatMessage, expanded_len);
    errdefer alloc.free(expanded);

    @memcpy(expanded[0 .. pending_index + 1], messages[0 .. pending_index + 1]);
    for (pending.tool_calls, 0..) |call, i| {
        try budget.check();
        expanded[pending_index + 1 + i] = .{
            .role = .tool,
            .content = pending_tool_review_result_text,
            .tool_call_id = call.id,
            .tool_name = call.name,
        };
    }
    expanded[expanded.len - 1] = messages[messages.len - 1];
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

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    const cache_breakpoint_idx = if (options.prompt_caching) findCacheBreakpoint(messages) else null;
    var prefix_cacheable = true;

    try out.writer.writeAll("{\"prompt\":[");
    for (messages, 0..) |message, i| {
        if (budget) |active| try active.check();
        if (i > 0) try out.writer.writeByte(',');
        const use_cache = prefix_cacheable and shouldCacheMessage(message, i, cache_breakpoint_idx, options.prompt_caching);
        const verified_images = if (verified_image_override) |override|
            if (override.message_index == i) override.images else null
        else
            null;
        if (budget) |active| {
            try writeChatMessageJsonInner(
                std.heap.c_allocator,
                &out.writer,
                message,
                use_cache,
                active,
                verified_images,
            );
        } else if (use_cache) {
            try writeChatMessageJsonCached(std.heap.c_allocator, &out.writer, message);
        } else {
            try writeChatMessageJson(std.heap.c_allocator, &out.writer, message);
        }
        if (message.cache_policy == .no_cache) prefix_cacheable = false;
        if (budget) |active| try active.check();
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
    if (messages.len < 2 or target_call_id.len == 0) return error.InvalidGatewayHistory;
    const pending = messages[messages.len - 2];
    const instruction = messages[messages.len - 1];
    if (pending.role != .assistant or pending.tool_calls.len == 0) return error.InvalidGatewayHistory;
    if (instruction.role != .system or instruction.content == null) return error.InvalidGatewayHistory;
    try validateToolMessageHistory(alloc, messages[0 .. messages.len - 2]);
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
    if (!options.fast and options.parallel_tool_calls == null) return;

    try writer.writeAll(",\"providerOptions\":{");
    if (options.fast) try writer.writeAll("\"gateway\":{\"speed\":\"fast\"}");
    if (options.parallel_tool_calls) |parallel_tool_calls| {
        if (options.fast) try writer.writeByte(',');
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
        if (try types.ToolArgumentIntegrity.classifySerialized(alloc, call.arguments_json) == .malformed_json) {
            return error.InvalidGatewayHistory;
        }
        var j = i + 1;
        while (j < calls.len) : (j += 1) {
            if (std.mem.eql(u8, call.id, calls[j].id)) return error.InvalidGatewayHistory;
        }
    }
}

fn findToolCallIndex(calls: []const ToolCall, id: []const u8) ?usize {
    for (calls, 0..) |call, i| {
        if (std.mem.eql(u8, call.id, id)) return i;
    }
    return null;
}

pub fn shouldCacheMessage(message: ChatMessage, index: usize, cache_breakpoint_idx: ?usize, prompt_caching: bool) bool {
    if (!prompt_caching) return false;
    if (message.cache_policy == .no_cache) return false;
    return message.role == .system or (cache_breakpoint_idx != null and index == cache_breakpoint_idx.?);
}

const anthropic_cache_meta = ",\"providerOptions\":{\"anthropic\":{\"cacheControl\":{\"type\":\"ephemeral\"}}}";
const max_prompt_shape_entries: usize = 12;

fn writeChatMessageJsonInner(
    scratch_alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: ChatMessage,
    cached: bool,
    budget: ?BuildBudget,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
) !void {
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(roleName(message.role), .{}, writer);

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
                try writer.writeAll("{\"type\":\"tool-call\",\"toolCallId\":");
                try std.json.Stringify.value(tool_call.id, .{}, writer);
                try writer.writeAll(",\"toolName\":");
                try std.json.Stringify.value(tool_call.name, .{}, writer);
                try writer.writeAll(",\"input\":");
                try writer.writeAll(tool_call.arguments_json);
                try writer.writeByte('}');
                wrote_part = true;
            }
            try writer.writeByte(']');
        },
        .tool => {
            try writer.writeAll(",\"content\":[{\"type\":\"tool-result\",\"toolCallId\":");
            if (message.tool_call_id) |tool_call_id| {
                try std.json.Stringify.value(tool_call_id, .{}, writer);
            } else {
                try writer.writeAll("\"\"");
            }
            try writer.writeAll(",\"toolName\":");
            if (message.tool_name) |tool_name| {
                try std.json.Stringify.value(tool_name, .{}, writer);
            } else {
                try writer.writeAll("\"unknown\"");
            }
            const content = message.content orelse "";
            const failed = if (message.tool_result_status) |status|
                status == .failure
            else
                false;
            const denied = failed and tool_result_errors.toolPermissionDenialReason(content) != null;
            if (denied) {
                try writer.writeAll(",\"output\":{\"type\":\"execution-denied\",\"reason\":");
            } else if (failed) {
                try writer.writeAll(",\"output\":{\"type\":\"error-text\",\"value\":");
            } else {
                try writer.writeAll(",\"output\":{\"type\":\"text\",\"value\":");
            }
            try std.json.Stringify.value(content, .{}, writer);
            try writer.writeAll("}}]");
        },
    }

    if (cached) try writer.writeAll(anthropic_cache_meta);
    try writer.writeAll("}");
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

fn findCacheBreakpoint(messages: []const ChatMessage) ?usize {
    if (messages.len < 3) return null;
    var i = messages.len - 2;
    while (i > 0) : (i -= 1) {
        const role = messages[i].role;
        if (role == .user or role == .assistant) return i;
    }
    return null;
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

test "writeChatMessageJsonCached adds provider options and non-cached omits them" {
    const alloc = std.testing.allocator;
    var cached_out: std.Io.Writer.Allocating = .init(alloc);
    defer cached_out.deinit();
    var uncached_out: std.Io.Writer.Allocating = .init(alloc);
    defer uncached_out.deinit();

    const message: ChatMessage = .{ .role = .system, .content = "rules" };
    try writeChatMessageJsonCached(alloc, &cached_out.writer, message);
    try writeChatMessageJson(alloc, &uncached_out.writer, message);

    try std.testing.expect(std.mem.find(u8, cached_out.written(), "\"providerOptions\"") != null);
    try std.testing.expect(std.mem.find(u8, cached_out.written(), "\"cacheControl\":{\"type\":\"ephemeral\"}") != null);
    try std.testing.expect(std.mem.find(u8, uncached_out.written(), "providerOptions") == null);
}

fn promptStringEntryHasCacheControl(body: []const u8, needle: []const u8) !bool {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt") orelse return error.TestExpectedPromptMissing;
    if (prompt != .array) return error.TestExpectedPromptMissing;
    for (prompt.array.items) |entry| {
        if (entry != .object) continue;
        const content = entry.object.get("content") orelse continue;
        if (content != .string) continue;
        if (std.mem.find(u8, content.string, needle) == null) continue;
        return entry.object.get("providerOptions") != null;
    }
    return error.TestExpectedPromptMessageMissing;
}

test "buildGatewayRequestBodyWithOptions leaves transient system messages uncached" {
    const alloc = std.testing.allocator;
    const msgs = [_]ChatMessage{
        .{ .role = .system, .content = "stable system prompt" },
        .{ .role = .system, .content = "static project context" },
        .{ .role = .system, .content = "volatile runtime overlay", .cache_policy = .no_cache },
        .{ .role = .user, .content = "first question" },
        .{ .role = .assistant, .content = "answer" },
        .{ .role = .user, .content = "follow up" },
    };
    const body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &msgs, .{ .prompt_caching = true }, .auto);
    defer alloc.free(body);

    const cache_marker = "\"cacheControl\":{\"type\":\"ephemeral\"}";
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, cache_marker));
    try std.testing.expect(try promptStringEntryHasCacheControl(body, "stable system prompt"));
    try std.testing.expect(try promptStringEntryHasCacheControl(body, "static project context"));
    try std.testing.expect(!try promptStringEntryHasCacheControl(body, "volatile runtime overlay"));

    const overlay_idx = std.mem.indexOf(u8, body, "volatile runtime overlay") orelse return error.TestExpectedPromptMessageMissing;
    try std.testing.expect(std.mem.find(u8, body[overlay_idx..], "cacheControl") == null);
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

test "pending tool review closes the exact assistant step with synthetic pending results" {
    var cancel = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(1000),
    });
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "Install dependencies." },
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "install", .name = "run_command", .arguments_json = "{\"command\":\"pnpm install\"}" },
            .{ .id = "read", .name = "read_file", .arguments_json = "{\"path\":\"package.json\"}" },
        } },
        .{ .role = .system, .content = "Review only install." },
    };

    const body = try buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
        std.testing.allocator,
        "[]",
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
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\"role\":\"tool\""));
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, body, "Tool call has not executed; it is pending permission review."),
    );
    try std.testing.expect(std.mem.find(u8, body, "\"maxOutputTokens\":2048") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"reasoning\":\"minimal\"") != null);
    try std.testing.expectError(
        error.InvalidGatewayHistory,
        buildGatewayRequestBody(std.testing.allocator, "[]", &messages),
    );
}

test "pending tool review rejects missing or duplicate target ids" {
    var cancel = std.atomic.Value(bool).init(false);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(1000),
    });
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "Run this." },
        .{ .role = .assistant, .tool_calls = &.{
            .{ .id = "duplicate", .name = "run_command", .arguments_json = "{}" },
            .{ .id = "duplicate", .name = "read_file", .arguments_json = "{}" },
        } },
        .{ .role = .system, .content = "Review it." },
    };

    try std.testing.expectError(
        error.InvalidGatewayHistory,
        buildGatewayPendingToolReviewRequestBodyWithMaxOutputTokens(
            std.testing.allocator,
            "[]",
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

test "findCacheBreakpoint returns null for short conversations" {
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "hi" },
    };
    try std.testing.expect(findCacheBreakpoint(&messages) == null);
}

test "findCacheBreakpoint returns last user/assistant before final message" {
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "first" },
        .{ .role = .assistant, .content = "reply" },
        .{ .role = .user, .content = "second" },
    };
    try std.testing.expectEqual(@as(?usize, 2), findCacheBreakpoint(&messages));
}

test "findCacheBreakpoint skips tool messages" {
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "do it" },
        .{ .role = .assistant, .content = "ok" },
        .{ .role = .tool, .content = "result", .tool_call_id = "t1", .tool_name = "read_file" },
        .{ .role = .user, .content = "next" },
    };
    try std.testing.expectEqual(@as(?usize, 2), findCacheBreakpoint(&messages));
}

test "buildGatewayRequestBodyWithOptions includes cache markers for anthropic" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "system prompt" },
        .{ .role = .user, .content = "first question" },
        .{ .role = .assistant, .content = "answer" },
        .{ .role = .user, .content = "follow up" },
    };
    const body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{ .prompt_caching = true }, .auto);
    defer alloc.free(body);

    const cache_marker = "\"providerOptions\":{\"anthropic\":{\"cacheControl\":{\"type\":\"ephemeral\"}}}";

    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.find(u8, body[pos..], cache_marker)) |idx| {
        count += 1;
        pos += idx + cache_marker.len;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "buildGatewayRequestBodyWithOptions omits cache markers when disabled" {
    const alloc = std.testing.allocator;
    const messages = [_]ChatMessage{
        .{ .role = .system, .content = "system prompt" },
        .{ .role = .user, .content = "question" },
    };
    const body = try buildGatewayRequestBodyWithOptions(alloc, "[]", &messages, .{}, .auto);
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "cacheControl") == null);
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
