const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const types = @import("../core/shared/types.zig");
const image_attachments = @import("../core/images/image_attachments.zig");

pub const ReplayLimits = struct {
    tool_calls: usize,
    tool_identity_bytes: usize,
    tool_arguments_bytes: usize,
    provider_state_bytes: usize,
};

pub fn writeInput(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    limits: ReplayLimits,
) !void {
    var first = true;
    for (messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => continue,
            .user => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                var first_part = true;
                if (message.content) |content| if (content.len > 0) {
                    try writer.writeAll("{\"type\":\"input_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    first_part = false;
                };
                if (verified_images) |images| {
                    if (message_index == messages.len - 1) {
                        for (images) |image| {
                            if (!first_part) try writer.writeByte(',');
                            try writeInputImage(writer, alloc, image);
                            first_part = false;
                        }
                    }
                }
                try writer.writeAll("]}");
            },
            .assistant => {
                try validateReplayMessage(message, limits);
                if (message.provider_state_json) |state_json| {
                    var state = std.json.parseFromSlice(std.json.Value, alloc, state_json, .{}) catch
                        return error.InvalidProviderState;
                    defer state.deinit();
                    if (state.value != .array) return error.InvalidProviderState;
                    for (state.value.array.items) |item| {
                        if (item != .object) return error.InvalidProviderState;
                        try writeComma(writer, &first);
                        try std.json.Stringify.value(item, .{}, writer);
                    }
                }
                if (message.content) |content| if (content.len > 0) {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeAll(",\"annotations\":[]}]}");
                };
                for (message.tool_calls) |call| {
                    try writeComma(writer, &first);
                    try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                    try std.json.Stringify.value(call.id, .{}, writer);
                    try writer.writeAll(",\"name\":");
                    try std.json.Stringify.value(call.name, .{}, writer);
                    try writer.writeAll(",\"arguments\":");
                    try std.json.Stringify.value(call.arguments_json, .{}, writer);
                    try writer.writeByte('}');
                }
            },
            .tool => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"output\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn validateReplayMessage(message: types.ChatMessage, limits: ReplayLimits) !void {
    if (message.provider_state_json) |state_json| {
        if (state_json.len > limits.provider_state_bytes) return error.ProviderStateTooLarge;
    }
    if (message.tool_calls.len > limits.tool_calls) return error.ToolCallLimitExceeded;
    for (message.tool_calls) |call| {
        if (call.id.len == 0 or call.id.len > limits.tool_identity_bytes or
            call.name.len == 0 or call.name.len > limits.tool_identity_bytes)
        {
            return error.ToolCallLimitExceeded;
        }
        if (call.arguments_json.len > limits.tool_arguments_bytes) {
            return error.ToolArgumentsTooLarge;
        }
    }
}

fn writeInputImage(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    image: image_attachments.VerifiedSnapshot,
) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}");
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

/// Serializes the provider-neutral function tool selection into the Responses
/// API shape. Provider-executed tools remain owned by their concrete provider.
pub fn writeTools(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    tools: stream_provider.ToolSelection,
) !usize {
    var count: usize = 0;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(",\"tools\":[");

    for (tools.advertised_names) |name| {
        const tool = tools.advertisedFunction(name) orelse continue;
        if (count > 0) try out.writer.writeByte(',');
        try writeFunctionTool(
            &out.writer,
            alloc,
            tool.name,
            tool.description,
            .{ .static = tool.input_schema },
        );
        count += 1;
    }
    for (tools.additional_functions) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try out.writer.writeByte(',');
        try writeFunctionTool(
            &out.writer,
            alloc,
            tool.name,
            tool.description,
            .{ .static = tool.input_schema },
        );
        count += 1;
    }
    for (tools.selected_dynamic) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try out.writer.writeByte(',');
        try writeFunctionTool(
            &out.writer,
            alloc,
            tool.name,
            tool.description,
            .{ .dynamic = tool.input_schema },
        );
        count += 1;
    }
    try out.writer.writeByte(']');
    if (count > 0) try writer.writeAll(out.written());
    return count;
}

pub const StreamLimits = struct {
    aggregate_bytes: usize,
    count_json_bytes: bool = true,
    events: usize,
    tool_calls: usize,
    tool_identity_bytes: usize,
    tool_arguments_bytes: usize,
    provider_state_bytes: usize,
};

pub const StreamCallbacks = struct {
    context: *anyopaque,
    on_content: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback = null,
    on_reasoning: ?stream_provider.StreamCallback = null,
    on_tool_input: ?stream_provider.StreamCallback = null,
};

const ToolAccumulator = struct {
    output_index: i64,
    id: []u8,
    name: []u8,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolAccumulator, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

pub const Reducer = struct {
    content: std.ArrayList(u8) = .empty,
    provider_state: std.Io.Writer.Allocating,
    provider_state_count: usize = 0,
    tools: std.ArrayList(ToolAccumulator) = .empty,
    finish_reason: ?types.ProviderFinishReason = null,
    usage: types.Usage = .{},
    generation_id: ?[]u8 = null,
    terminal_seen: bool = false,
    saw_content_delta: bool = false,
    event_count: usize = 0,
    aggregate_bytes: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Reducer {
        return .{ .provider_state = .init(alloc) };
    }

    pub fn deinit(self: *Reducer, alloc: std.mem.Allocator) void {
        self.content.deinit(alloc);
        self.provider_state.deinit();
        for (self.tools.items) |*tool| tool.deinit(alloc);
        self.tools.deinit(alloc);
        if (self.generation_id) |id| alloc.free(id);
        self.* = undefined;
    }

    /// Reduces one decoded SSE data payload. Returns true after a terminal
    /// Responses event so the framing reader can stop without consuming more.
    pub fn applyJson(
        self: *Reducer,
        alloc: std.mem.Allocator,
        json_text: []const u8,
        callbacks: StreamCallbacks,
        cancel_flag: *std.atomic.Value(bool),
        content_capture_limit: ?usize,
        limits: StreamLimits,
    ) !bool {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        self.event_count = try checkedAccumulatedSize(self.event_count, 1, limits.events);
        if (limits.count_json_bytes) {
            self.aggregate_bytes = try checkedAccumulatedSize(
                self.aggregate_bytes,
                json_text.len,
                limits.aggregate_bytes,
            );
        }
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch
            return error.InvalidEvent;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const event_type = stringField(parsed.value.object, "type") orelse return false;

        if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse return false;
            const item = parsed.value.object.get("item") orelse return false;
            if (item != .object) return false;
            const item_type = stringField(item.object, "type") orelse return false;
            if (std.mem.eql(u8, item_type, "function_call")) {
                const call_id = stringField(item.object, "call_id") orelse return false;
                const name = stringField(item.object, "name") orelse return false;
                if (findTool(self.tools.items, output_index) == null) {
                    try appendTool(alloc, &self.tools, output_index, call_id, name, limits);
                    if (callbacks.on_tool_start) |callback| {
                        callback(callbacks.context, call_id, name, null);
                    }
                }
            }
        } else if (std.mem.eql(u8, event_type, "response.output_text.delta") or
            std.mem.eql(u8, event_type, "response.refusal.delta"))
        {
            const delta = stringField(parsed.value.object, "delta") orelse return false;
            self.saw_content_delta = true;
            callbacks.on_content(callbacks.context, delta);
            try appendCaptured(alloc, &self.content, delta, content_capture_limit);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
        {
            const delta = stringField(parsed.value.object, "delta") orelse return false;
            if (callbacks.on_reasoning) |callback| callback(callbacks.context, delta);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_part.done")) {
            if (callbacks.on_reasoning) |callback| callback(callbacks.context, "\n\n");
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse return false;
            const delta = stringField(parsed.value.object, "delta") orelse return false;
            const index = findTool(self.tools.items, output_index) orelse return false;
            try appendToolArguments(alloc, &self.tools.items[index].arguments, delta, limits.tool_arguments_bytes);
            if (callbacks.on_tool_input) |callback| callback(callbacks.context, delta);
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse return false;
            const arguments = stringField(parsed.value.object, "arguments") orelse return false;
            const index = findTool(self.tools.items, output_index) orelse return false;
            const previous_len = self.tools.items[index].arguments.items.len;
            if (std.mem.startsWith(u8, arguments, self.tools.items[index].arguments.items)) {
                const suffix = arguments[previous_len..];
                try appendToolArguments(alloc, &self.tools.items[index].arguments, suffix, limits.tool_arguments_bytes);
                if (suffix.len > 0) if (callbacks.on_tool_input) |callback| callback(callbacks.context, suffix);
            } else {
                self.tools.items[index].arguments.clearRetainingCapacity();
                try appendToolArguments(alloc, &self.tools.items[index].arguments, arguments, limits.tool_arguments_bytes);
            }
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse return false;
            const item = parsed.value.object.get("item") orelse return false;
            if (item != .object) return false;
            const item_type = stringField(item.object, "type") orelse return false;
            if (std.mem.eql(u8, item_type, "function_call")) {
                if (findTool(self.tools.items, output_index)) |index| {
                    if (stringField(item.object, "arguments")) |arguments| {
                        if (self.tools.items[index].arguments.items.len == 0) {
                            try appendToolArguments(alloc, &self.tools.items[index].arguments, arguments, limits.tool_arguments_bytes);
                        }
                    }
                }
            } else if (std.mem.eql(u8, item_type, "reasoning") and
                stringField(item.object, "encrypted_content") != null)
            {
                var encoded: std.Io.Writer.Allocating = .init(alloc);
                defer encoded.deinit();
                try std.json.Stringify.value(item, .{}, &encoded.writer);
                const separators: usize = if (self.provider_state_count == 0) 2 else 1;
                const encoded_size = try checkedAccumulatedSize(
                    encoded.written().len,
                    separators,
                    limits.provider_state_bytes,
                );
                _ = try checkedAccumulatedSize(
                    self.provider_state.written().len,
                    encoded_size,
                    limits.provider_state_bytes,
                );
                if (self.provider_state_count == 0) {
                    try self.provider_state.writer.writeByte('[');
                } else {
                    try self.provider_state.writer.writeByte(',');
                }
                try self.provider_state.writer.writeAll(encoded.written());
                self.provider_state_count += 1;
            } else if (std.mem.eql(u8, item_type, "message") and !self.saw_content_delta) {
                if (item.object.get("content")) |parts| if (parts == .array) {
                    for (parts.array.items) |part| {
                        if (part != .object) continue;
                        const text = stringField(part.object, "text") orelse
                            stringField(part.object, "refusal") orelse continue;
                        callbacks.on_content(callbacks.context, text);
                        try appendCaptured(alloc, &self.content, text, content_capture_limit);
                    }
                };
            }
        } else if (std.mem.eql(u8, event_type, "response.completed") or
            std.mem.eql(u8, event_type, "response.done") or
            std.mem.eql(u8, event_type, "response.incomplete"))
        {
            const response_value = parsed.value.object.get("response") orelse return false;
            if (response_value != .object) return false;
            self.terminal_seen = true;
            self.finish_reason = finishReason(
                stringField(response_value.object, "status"),
                response_value.object,
                self.tools.items.len > 0,
            );
            self.usage = parseUsage(response_value.object);
            if (stringField(response_value.object, "id")) |id| {
                if (self.generation_id) |prior| alloc.free(prior);
                self.generation_id = try alloc.dupe(u8, id);
            }
            return true;
        } else if (std.mem.eql(u8, event_type, "response.failed") or
            std.mem.eql(u8, event_type, "error"))
        {
            return error.ResponseFailed;
        }
        return false;
    }

    pub fn finish(
        self: *Reducer,
        alloc: std.mem.Allocator,
        cancel_flag: *std.atomic.Value(bool),
        limits: StreamLimits,
    ) !types.ModelCompletion {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (!self.terminal_seen) return error.StreamIncomplete;

        const owned_content = if (self.content.items.len > 0)
            try self.content.toOwnedSlice(alloc)
        else
            null;
        if (owned_content != null) self.content = .empty;
        errdefer if (owned_content) |value| alloc.free(value);
        const owned_provider_state = if (self.provider_state_count > 0) state: {
            try self.provider_state.writer.writeByte(']');
            if (self.provider_state.written().len > limits.provider_state_bytes) {
                return error.ResourceLimitExceeded;
            }
            break :state try self.provider_state.toOwnedSlice();
        } else null;
        errdefer if (owned_provider_state) |value| alloc.free(value);
        const owned_tools: []types.ToolCall = if (self.tools.items.len > 0)
            try alloc.alloc(types.ToolCall, self.tools.items.len)
        else
            &.{};
        errdefer if (owned_tools.len > 0) alloc.free(owned_tools);
        var initialized: usize = 0;
        errdefer for (owned_tools[0..initialized]) |call| {
            alloc.free(call.id);
            alloc.free(call.name);
            alloc.free(call.arguments_json);
        };
        for (self.tools.items, 0..) |*tool, index| {
            const arguments = if (tool.arguments.items.len > 0)
                try tool.arguments.toOwnedSlice(alloc)
            else
                try alloc.dupe(u8, "{}");
            tool.arguments = .empty;
            owned_tools[index] = .{
                .id = tool.id,
                .name = tool.name,
                .arguments_json = arguments,
            };
            tool.id = &.{};
            tool.name = &.{};
            initialized += 1;
        }
        const generation_id = self.generation_id;
        self.generation_id = null;
        return .{
            .content = owned_content,
            .tool_calls = owned_tools,
            .generation_id = generation_id,
            .provider_state_json = owned_provider_state,
            .finish_reason = self.finish_reason orelse if (owned_tools.len > 0) .tool_calls else .stop,
            .usage = self.usage,
        };
    }
};

fn appendTool(
    alloc: std.mem.Allocator,
    tools: *std.ArrayList(ToolAccumulator),
    output_index: i64,
    call_id: []const u8,
    name: []const u8,
    limits: StreamLimits,
) !void {
    if (tools.items.len >= limits.tool_calls or
        call_id.len == 0 or call_id.len > limits.tool_identity_bytes or
        name.len == 0 or name.len > limits.tool_identity_bytes)
    {
        return error.ToolCallLimitExceeded;
    }
    const id = try alloc.dupe(u8, call_id);
    errdefer alloc.free(id);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    try tools.append(alloc, .{
        .output_index = output_index,
        .id = id,
        .name = owned_name,
    });
}

fn appendToolArguments(
    alloc: std.mem.Allocator,
    arguments: *std.ArrayList(u8),
    delta: []const u8,
    maximum: usize,
) !void {
    _ = checkedAccumulatedSize(arguments.items.len, delta.len, maximum) catch
        return error.ToolArgumentsTooLarge;
    try arguments.appendSlice(alloc, delta);
}

pub fn checkedAccumulatedSize(current: usize, additional: usize, maximum: usize) !usize {
    const next = std.math.add(usize, current, additional) catch
        return error.ResourceLimitExceeded;
    if (next > maximum) return error.ResourceLimitExceeded;
    return next;
}

fn appendCaptured(
    alloc: std.mem.Allocator,
    content: *std.ArrayList(u8),
    delta: []const u8,
    limit: ?usize,
) !void {
    const remaining = if (limit) |maximum|
        maximum -| @min(maximum, content.items.len)
    else
        delta.len;
    try content.appendSlice(alloc, delta[0..@min(delta.len, remaining)]);
}

fn findTool(tools: []const ToolAccumulator, output_index: i64) ?usize {
    for (tools, 0..) |tool, index| if (tool.output_index == output_index) return index;
    return null;
}

fn finishReason(
    status: ?[]const u8,
    response: std.json.ObjectMap,
    has_tools: bool,
) types.ProviderFinishReason {
    const value = status orelse return if (has_tools) .tool_calls else .stop;
    if (std.mem.eql(u8, value, "completed")) return if (has_tools) .tool_calls else .stop;
    if (std.mem.eql(u8, value, "incomplete")) {
        if (response.get("incomplete_details")) |details| if (details == .object) {
            if (stringField(details.object, "reason")) |reason| {
                if (std.mem.eql(u8, reason, "max_output_tokens")) return .length;
                if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
            }
        };
        return .provider_error;
    }
    if (std.mem.eql(u8, value, "failed") or std.mem.eql(u8, value, "cancelled")) {
        return .provider_error;
    }
    return if (has_tools) .tool_calls else .other;
}

fn parseUsage(response: std.json.ObjectMap) types.Usage {
    const value = response.get("usage") orelse return .{};
    if (value != .object) return .{};
    return .{
        .input_tokens = unsignedField(value.object, "input_tokens"),
        .output_tokens = unsignedField(value.object, "output_tokens"),
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    if (value != .integer) return null;
    return value.integer;
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = integerField(object, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

const InputSchema = union(enum) {
    static: model_tool_schema.ObjectSchema,
    dynamic: std.json.Value,
};

fn writeFunctionTool(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    input_schema: InputSchema,
) !void {
    if (name.len == 0) return error.InvalidToolSchema;
    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    if (description.len > 0) {
        try writer.writeAll(",\"description\":");
        try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, description);
    }
    try writer.writeAll(",\"parameters\":");
    switch (input_schema) {
        .static => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
        .dynamic => |schema| {
            if (schema != .object) return error.InvalidToolSchema;
            try std.json.Stringify.value(schema, .{}, writer);
        },
    }
    try writer.writeAll(",\"strict\":false}");
}

fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}

test "Responses tools serialize typed static and dynamic functions once" {
    const Tool = @import("../core/tooling/tool_dispatch.zig").Tool;
    const Static = struct {
        fn decode(_: @import("../core/tooling/tool_dispatch.zig").DispatchContext, _: []const u8) @import("../core/tooling/tool_dispatch.zig").DispatchError!@import("../core/tooling/tool_dispatch.zig").DecodeResult {
            return error.InvalidToolArguments;
        }
        fn call(_: @import("../core/tooling/tool_dispatch.zig").DispatchContext, _: @import("../core/tooling/tool_dispatch.zig").ToolInput) @import("../core/tooling/tool_dispatch.zig").DispatchError!@import("../core/tooling/tool_dispatch.zig").ToolResult {
            return error.InvalidToolArguments;
        }
        fn readsOnly(_: @import("../core/tooling/tool_dispatch.zig").ToolInput) bool {
            return true;
        }
        fn irreversible(_: @import("../core/tooling/tool_dispatch.zig").ToolInput) bool {
            return false;
        }
    };
    const registered = [_]Tool{.{
        .name = "read_file",
        .description = "Read a file.",
        .model_schema = .{
            .name = "read_file",
            .description = "Read a file.",
            .input_schema = .{
                .properties = &.{.{ .name = "path", .json_type = .string }},
                .required = &.{"path"},
            },
        },
        .decode = Static.decode,
        .call = Static.call,
        .reads_only_fn = Static.readsOnly,
        .irreversible_fn = Static.irreversible,
    }};
    var dynamic_schema = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}",
        .{},
    );
    defer dynamic_schema.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 2), try writeTools(
        &out.writer,
        std.testing.allocator,
        .{
            .registry = .{ .tools = &registered },
            .advertised_names = &.{"read_file"},
            .advertised_functions = &.{registered[0].model_schema},
            .selected_dynamic = &.{.{
                .name = "mcp_search",
                .description = "Search.",
                .input_schema = dynamic_schema.value,
            }},
        },
    ));
    try std.testing.expect(std.mem.find(u8, out.written(), "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "\"name\":\"mcp_search\"") != null);
}
