const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const types = @import("../core/shared/types.zig");
const image_attachments = @import("../core/images/image_attachments.zig");

/// Serializer and stream reducer for the OpenAI **Chat Completions** wire
/// format (`POST /v1/chat/completions`).
///
/// This is deliberately provider-neutral: it carries no endpoint, credential,
/// or vendor identity so any OpenAI-compatible route can share it. It is a
/// sibling of `responses_protocol.zig`, which covers the newer Responses API
/// used by the Codex and Grok routes.
pub const ReplayLimits = struct {
    tool_calls: usize,
    tool_identity_bytes: usize,
    tool_arguments_bytes: usize,
};

pub const StreamLimits = struct {
    aggregate_bytes: usize,
    count_json_bytes: bool = true,
    events: usize,
    tool_calls: usize,
    tool_identity_bytes: usize,
    tool_arguments_bytes: usize,
};

pub const StreamCallbacks = struct {
    context: *anyopaque,
    on_content: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback = null,
    on_reasoning: ?stream_provider.StreamCallback = null,
    on_tool_input: ?stream_provider.StreamCallback = null,
};

/// True for SSE framing lines that carry no JSON payload. OpenRouter emits
/// `: OPENROUTER PROCESSING` keep-alive comments mid-stream; per the SSE spec a
/// leading colon marks a comment, and handing one to a JSON parser would abort
/// an otherwise healthy stream.
pub fn isCommentLine(line: []const u8) bool {
    return line.len > 0 and line[0] == ':';
}

// ---------------------------------------------------------------- serialize

pub fn writeMessages(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    messages: []const types.ChatMessage,
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    limits: ReplayLimits,
) !void {
    var first = true;
    for (messages, 0..) |message, message_index| {
        switch (message.role) {
            .system => {
                const content = message.content orelse continue;
                if (content.len == 0) continue;
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"system\",\"content\":");
                try std.json.Stringify.value(content, .{}, writer);
                try writer.writeByte('}');
            },
            .user => {
                const attached = trailingImages(verified_images, message_index, messages.len);
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"user\",\"content\":");
                if (attached.len == 0) {
                    // Plain text messages use the scalar content form, which
                    // every OpenAI-compatible provider accepts.
                    try std.json.Stringify.value(message.content orelse "", .{}, writer);
                } else {
                    try writer.writeByte('[');
                    var first_part = true;
                    if (message.content) |content| if (content.len > 0) {
                        try writer.writeAll("{\"type\":\"text\",\"text\":");
                        try std.json.Stringify.value(content, .{}, writer);
                        try writer.writeByte('}');
                        first_part = false;
                    };
                    for (attached) |image| {
                        if (!first_part) try writer.writeByte(',');
                        try writeImagePart(writer, alloc, image);
                        first_part = false;
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .assistant => {
                try validateReplayMessage(message, limits);
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"assistant\",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                if (message.tool_calls.len > 0) {
                    try writer.writeAll(",\"tool_calls\":[");
                    for (message.tool_calls, 0..) |call, index| {
                        if (index > 0) try writer.writeByte(',');
                        try writer.writeAll("{\"id\":");
                        try std.json.Stringify.value(call.id, .{}, writer);
                        try writer.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.value(call.name, .{}, writer);
                        try writer.writeAll(",\"arguments\":");
                        // Arguments travel as a JSON *string* on this wire
                        // format, not as an embedded object.
                        try std.json.Stringify.value(
                            if (call.arguments_json.len > 0) call.arguments_json else "{}",
                            .{},
                            writer,
                        );
                        try writer.writeAll("}}");
                    }
                    try writer.writeByte(']');
                }
                try writer.writeByte('}');
            },
            .tool => {
                try writeComma(writer, &first);
                try writer.writeAll("{\"role\":\"tool\",\"tool_call_id\":");
                try std.json.Stringify.value(message.tool_call_id orelse "", .{}, writer);
                try writer.writeAll(",\"content\":");
                try std.json.Stringify.value(message.content orelse "", .{}, writer);
                try writer.writeByte('}');
            },
        }
    }
}

fn trailingImages(
    verified_images: ?[]const image_attachments.VerifiedSnapshot,
    message_index: usize,
    message_count: usize,
) []const image_attachments.VerifiedSnapshot {
    const images = verified_images orelse return &.{};
    if (message_index + 1 != message_count) return &.{};
    return images;
}

fn validateReplayMessage(message: types.ChatMessage, limits: ReplayLimits) !void {
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

fn writeImagePart(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    image: image_attachments.VerifiedSnapshot,
) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(image.bytes.len);
    const encoded = try alloc.alloc(u8, encoded_len);
    defer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try writer.writeAll(image.media_type);
    try writer.writeAll(";base64,");
    try writer.writeAll(encoded);
    try writer.writeAll("\"}}");
}

fn writeComma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

const InputSchema = union(enum) {
    static: model_tool_schema.ObjectSchema,
    dynamic: std.json.Value,
};

/// Serializes the provider-neutral function tool selection into the Chat
/// Completions `tools` shape. Returns the number of tools written; when zero,
/// nothing is emitted so the caller can omit the key entirely.
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
        try writeFunctionTool(&out.writer, alloc, tool.name, tool.description, .{ .static = tool.input_schema });
        count += 1;
    }
    for (tools.additional_functions) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try out.writer.writeByte(',');
        try writeFunctionTool(&out.writer, alloc, tool.name, tool.description, .{ .static = tool.input_schema });
        count += 1;
    }
    for (tools.selected_dynamic) |tool| {
        if (containsName(tools.advertised_names, tool.name)) continue;
        if (count > 0) try out.writer.writeByte(',');
        try writeFunctionTool(&out.writer, alloc, tool.name, tool.description, .{ .dynamic = tool.input_schema });
        count += 1;
    }
    try out.writer.writeByte(']');
    if (count > 0) try writer.writeAll(out.written());
    return count;
}

fn writeFunctionTool(
    writer: *std.Io.Writer,
    alloc: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    input_schema: InputSchema,
) !void {
    if (name.len == 0) return error.InvalidToolSchema;
    try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
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
    try writer.writeAll("}}");
}

fn containsName(names: []const []const u8, expected: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, expected)) return true;
    return false;
}

// ------------------------------------------------------------------ reduce

/// One in-flight tool call. Chat Completions streams fragment tool calls across
/// chunks and correlate them by the `index` field rather than by arrival order,
/// so accumulation is keyed on that index.
const ToolAccumulator = struct {
    index: i64,
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    announced: bool = false,

    fn deinit(self: *ToolAccumulator, alloc: std.mem.Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

pub const Reducer = struct {
    content: std.ArrayList(u8) = .empty,
    tools: std.ArrayList(ToolAccumulator) = .empty,
    finish_reason: ?types.ProviderFinishReason = null,
    usage: types.Usage = .{},
    generation_id: ?[]u8 = null,
    resolved_model: ?[]u8 = null,
    total_cost: ?f64 = null,
    terminal_seen: bool = false,
    event_count: usize = 0,
    aggregate_bytes: usize = 0,

    pub fn init() Reducer {
        return .{};
    }

    pub fn deinit(self: *Reducer, alloc: std.mem.Allocator) void {
        self.content.deinit(alloc);
        for (self.tools.items) |*tool| tool.deinit(alloc);
        self.tools.deinit(alloc);
        if (self.generation_id) |id| alloc.free(id);
        if (self.resolved_model) |model| alloc.free(model);
        self.* = undefined;
    }

    /// Reduces one decoded SSE `data:` payload. Returns true once the stream is
    /// terminal so the framing reader can stop reading.
    ///
    /// Callers must filter SSE comment lines with `isCommentLine` and the
    /// `[DONE]` sentinel before calling this.
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
        const root = parsed.value.object;

        // A mid-stream failure arrives as an ordinary chunk carrying a
        // top-level `error`, because the HTTP status was already sent as 200.
        if (root.get("error")) |_| return error.ResponseFailed;

        if (stringField(root, "id")) |id| {
            if (self.generation_id == null and id.len > 0 and id.len <= limits.tool_identity_bytes) {
                self.generation_id = try alloc.dupe(u8, id);
            }
        }
        if (stringField(root, "model")) |model| {
            if (self.resolved_model == null and model.len > 0 and model.len <= limits.tool_identity_bytes) {
                self.resolved_model = try alloc.dupe(u8, model);
            }
        }
        if (root.get("usage")) |usage_value| if (usage_value == .object) {
            self.usage = parseUsage(usage_value.object);
            if (numberField(usage_value.object, "cost")) |cost| self.total_cost = cost;
            // Providers send the usage block on the final chunk, which may
            // arrive without any `choices` entry.
            self.terminal_seen = true;
        };

        const choices = root.get("choices") orelse return false;
        if (choices != .array or choices.array.items.len == 0) return false;
        const choice = choices.array.items[0];
        if (choice != .object) return false;

        if (choice.object.get("delta")) |delta| if (delta == .object) {
            try self.applyDelta(alloc, delta.object, callbacks, content_capture_limit, limits);
        };
        // Non-streaming shaped payloads (and some providers' final chunk) place
        // the full text under `message` instead of `delta`.
        if (choice.object.get("message")) |message| if (message == .object) {
            try self.applyDelta(alloc, message.object, callbacks, content_capture_limit, limits);
        };

        if (stringField(choice.object, "finish_reason")) |raw| {
            self.finish_reason = parseFinishReason(raw);
            self.terminal_seen = true;
            if (self.finish_reason == .provider_error) return error.ResponseFailed;
        }
        return false;
    }

    fn applyDelta(
        self: *Reducer,
        alloc: std.mem.Allocator,
        delta: std.json.ObjectMap,
        callbacks: StreamCallbacks,
        content_capture_limit: ?usize,
        limits: StreamLimits,
    ) !void {
        if (stringField(delta, "content")) |text| if (text.len > 0) {
            callbacks.on_content(callbacks.context, text);
            try appendCaptured(alloc, &self.content, text, content_capture_limit);
        };
        if (stringField(delta, "reasoning")) |text| if (text.len > 0) {
            if (callbacks.on_reasoning) |callback| callback(callbacks.context, text);
        };
        if (delta.get("reasoning_details")) |details| if (details == .array) {
            for (details.array.items) |detail| {
                if (detail != .object) continue;
                const text = stringField(detail.object, "text") orelse
                    stringField(detail.object, "summary") orelse continue;
                if (text.len == 0) continue;
                if (callbacks.on_reasoning) |callback| callback(callbacks.context, text);
            }
        };

        const tool_calls = delta.get("tool_calls") orelse return;
        if (tool_calls != .array) return;
        for (tool_calls.array.items) |entry| {
            if (entry != .object) continue;
            // `index` is the correlation key; fall back to positional order for
            // the rare provider that omits it.
            const index = integerField(entry.object, "index") orelse
                @as(i64, @intCast(self.tools.items.len));
            const slot = try self.toolSlot(alloc, index, limits);
            const tool = &self.tools.items[slot];

            if (stringField(entry.object, "id")) |id| if (id.len > 0) {
                try appendBounded(alloc, &tool.id, id, limits.tool_identity_bytes);
            };
            const function = entry.object.get("function") orelse {
                try self.announceTool(slot, callbacks);
                continue;
            };
            if (function != .object) continue;
            if (stringField(function.object, "name")) |name| if (name.len > 0) {
                try appendBounded(alloc, &tool.name, name, limits.tool_identity_bytes);
            };
            try self.announceTool(slot, callbacks);
            if (stringField(function.object, "arguments")) |arguments| if (arguments.len > 0) {
                try appendBounded(
                    alloc,
                    &self.tools.items[slot].arguments,
                    arguments,
                    limits.tool_arguments_bytes,
                );
                if (callbacks.on_tool_input) |callback| callback(callbacks.context, arguments);
            };
        }
    }

    /// Emits `tool_started` once per call, as soon as both an id and a name are
    /// known. Fragments can deliver them in either order.
    fn announceTool(self: *Reducer, slot: usize, callbacks: StreamCallbacks) !void {
        const tool = &self.tools.items[slot];
        if (tool.announced) return;
        if (tool.id.items.len == 0 or tool.name.items.len == 0) return;
        tool.announced = true;
        if (callbacks.on_tool_start) |callback| {
            callback(callbacks.context, tool.id.items, tool.name.items, null);
        }
    }

    fn toolSlot(self: *Reducer, alloc: std.mem.Allocator, index: i64, limits: StreamLimits) !usize {
        for (self.tools.items, 0..) |tool, slot| {
            if (tool.index == index) return slot;
        }
        if (self.tools.items.len >= limits.tool_calls) return error.ToolCallLimitExceeded;
        try self.tools.append(alloc, .{ .index = index });
        return self.tools.items.len - 1;
    }

    pub fn finish(
        self: *Reducer,
        alloc: std.mem.Allocator,
        cancel_flag: *std.atomic.Value(bool),
    ) !types.ModelCompletion {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (!self.terminal_seen) return error.StreamIncomplete;

        const owned_content = if (self.content.items.len > 0)
            try self.content.toOwnedSlice(alloc)
        else
            null;
        if (owned_content != null) self.content = .empty;
        errdefer if (owned_content) |value| alloc.free(value);

        const owned_tools: []types.ToolCall = if (self.tools.items.len > 0)
            try alloc.alloc(types.ToolCall, self.tools.items.len)
        else
            &.{};
        errdefer if (owned_tools.len > 0) alloc.free(owned_tools);
        var initialized: usize = 0;
        errdefer for (owned_tools[0..initialized]) |call| {
            alloc.free(@constCast(call.id));
            alloc.free(@constCast(call.name));
            alloc.free(@constCast(call.arguments_json));
        };
        for (self.tools.items, 0..) |*tool, index| {
            if (tool.id.items.len == 0 or tool.name.items.len == 0) return error.InvalidToolCall;
            const id = try tool.id.toOwnedSlice(alloc);
            tool.id = .empty;
            errdefer alloc.free(id);
            const name = try tool.name.toOwnedSlice(alloc);
            tool.name = .empty;
            errdefer alloc.free(name);
            const arguments = if (tool.arguments.items.len > 0)
                try tool.arguments.toOwnedSlice(alloc)
            else
                try alloc.dupe(u8, "{}");
            tool.arguments = .empty;
            owned_tools[index] = .{ .id = id, .name = name, .arguments_json = arguments };
            initialized += 1;
        }

        const generation_id = self.generation_id;
        self.generation_id = null;
        return .{
            .content = owned_content,
            .tool_calls = owned_tools,
            .generation_id = generation_id,
            .finish_reason = self.finish_reason orelse if (owned_tools.len > 0) .tool_calls else .stop,
            .usage = self.usage,
        };
    }

    /// Exact per-request billing, when the provider reported a cost alongside
    /// the usage block. The returned `model` is borrowed from the reducer and
    /// must be duplicated by the caller if the completion outlives it.
    pub fn billing(self: *const Reducer, created_at_ms: i64, requested_model: []const u8) ?types.ProviderBilling {
        const cost = self.total_cost orelse return null;
        return .{
            .created_at_ms = created_at_ms,
            .model = self.resolved_model orelse requested_model,
            .total_cost = cost,
            .input_tokens = self.usage.input_tokens orelse 0,
            .output_tokens = self.usage.output_tokens orelse 0,
            .cache_read_tokens = self.usage.cache_read_tokens orelse 0,
            // Chat Completions reports cache reads but has no cache-write
            // counter; OpenRouter bills writes inside the prompt total.
            .cache_write_tokens = 0,
            .reasoning_tokens = self.usage.reasoning_tokens,
            .billable_web_search_calls = 0,
        };
    }
};

fn parseFinishReason(raw: []const u8) types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "stop")) return .stop;
    if (std.mem.eql(u8, raw, "length")) return .length;
    if (std.mem.eql(u8, raw, "tool_calls") or std.mem.eql(u8, raw, "function_call")) return .tool_calls;
    if (std.mem.eql(u8, raw, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, raw, "error")) return .provider_error;
    return .other;
}

fn parseUsage(usage: std.json.ObjectMap) types.Usage {
    var result = types.Usage{
        .input_tokens = unsignedField(usage, "prompt_tokens"),
        .output_tokens = unsignedField(usage, "completion_tokens"),
    };
    if (usage.get("prompt_tokens_details")) |details| if (details == .object) {
        result.cache_read_tokens = unsignedField(details.object, "cached_tokens");
    };
    if (usage.get("completion_tokens_details")) |details| if (details == .object) {
        result.reasoning_tokens = unsignedField(details.object, "reasoning_tokens");
    };
    return result;
}

pub fn checkedAccumulatedSize(current: usize, additional: usize, maximum: usize) !usize {
    const total = std.math.add(usize, current, additional) catch return error.ResourceLimitExceeded;
    if (total > maximum) return error.ResourceLimitExceeded;
    return total;
}

fn appendBounded(
    alloc: std.mem.Allocator,
    target: *std.ArrayList(u8),
    text: []const u8,
    maximum: usize,
) !void {
    _ = try checkedAccumulatedSize(target.items.len, text.len, maximum);
    try target.appendSlice(alloc, text);
}

fn appendCaptured(
    alloc: std.mem.Allocator,
    target: *std.ArrayList(u8),
    text: []const u8,
    limit: ?usize,
) !void {
    const maximum = limit orelse {
        try target.appendSlice(alloc, text);
        return;
    };
    if (target.items.len >= maximum) return;
    const remaining = maximum - target.items.len;
    try target.appendSlice(alloc, text[0..@min(remaining, text.len)]);
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn unsignedField(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn numberField(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .float => |float| float,
        .integer => |integer| @floatFromInt(integer),
        else => null,
    };
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

const Capture = struct {
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_input: std.ArrayList(u8) = .empty,
    starts: std.ArrayList(u8) = .empty,

    fn deinit(self: *Capture, alloc: std.mem.Allocator) void {
        self.content.deinit(alloc);
        self.reasoning.deinit(alloc);
        self.tool_input.deinit(alloc);
        self.starts.deinit(alloc);
    }

    fn onContent(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.content.appendSlice(testing.allocator, chunk) catch {};
    }

    fn onReasoning(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.reasoning.appendSlice(testing.allocator, chunk) catch {};
    }

    fn onToolInput(ctx: *anyopaque, chunk: []const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.tool_input.appendSlice(testing.allocator, chunk) catch {};
    }

    fn onToolStart(ctx: *anyopaque, id: []const u8, name: []const u8, _: ?[]const u8) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.starts.appendSlice(testing.allocator, id) catch {};
        self.starts.append(testing.allocator, '/') catch {};
        self.starts.appendSlice(testing.allocator, name) catch {};
        self.starts.append(testing.allocator, ';') catch {};
    }

    fn callbacks(self: *Capture) StreamCallbacks {
        return .{
            .context = self,
            .on_content = onContent,
            .on_tool_start = onToolStart,
            .on_reasoning = onReasoning,
            .on_tool_input = onToolInput,
        };
    }
};

const test_limits = StreamLimits{
    .aggregate_bytes = 1 << 20,
    .events = 1000,
    .tool_calls = 8,
    .tool_identity_bytes = 256,
    .tool_arguments_bytes = 1 << 16,
};

/// Feeds raw SSE text through the same comment/`[DONE]` filtering a transport
/// applies, so the tests exercise the contract the reader depends on.
fn reduceSse(
    reducer: *Reducer,
    sse: []const u8,
    capture: *Capture,
    cancel: *std.atomic.Value(bool),
) !void {
    var lines = std.mem.splitScalar(u8, sse, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        if (isCommentLine(line)) continue;
        if (!std.mem.startsWith(u8, line, "data: ")) continue;
        const payload = line["data: ".len..];
        if (std.mem.eql(u8, payload, "[DONE]")) break;
        if (try reducer.applyJson(
            testing.allocator,
            payload,
            capture.callbacks(),
            cancel,
            null,
            test_limits,
        )) break;
    }
}

test "chat completions stream reduces text reasoning tool calls and usage" {
    const sse =
        \\: OPENROUTER PROCESSING
        \\data: {"id":"gen-1","model":"z-ai/glm-5.2:free","choices":[{"index":0,"delta":{"reasoning":"thinking"}}]}
        \\
        \\data: {"id":"gen-1","choices":[{"index":0,"delta":{"content":"Hel"}}]}
        \\
        \\: OPENROUTER PROCESSING
        \\
        \\data: {"id":"gen-1","choices":[{"index":0,"delta":{"content":"lo"}}]}
        \\
        \\data: {"id":"gen-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"read_file","arguments":"{\"pa"}}]}}]}
        \\
        \\data: {"id":"gen-1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\":\"a.txt\"}"}}]}}]}
        \\
        \\data: {"id":"gen-1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":11,"completion_tokens":7,"cost":0}}
        \\
        \\data: [DONE]
    ;

    var capture: Capture = .{};
    defer capture.deinit(testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);
    var reducer = Reducer.init();
    defer reducer.deinit(testing.allocator);

    try reduceSse(&reducer, sse, &capture, &cancel);

    const completion = try reducer.finish(testing.allocator, &cancel);
    defer {
        if (completion.content) |content| testing.allocator.free(@constCast(content));
        if (completion.generation_id) |id| testing.allocator.free(@constCast(id));
        types.freeToolCallSlice(testing.allocator, @constCast(completion.tool_calls));
    }

    try testing.expectEqualStrings("Hello", capture.content.items);
    try testing.expectEqualStrings("thinking", capture.reasoning.items);
    try testing.expectEqualStrings("call_a/read_file;", capture.starts.items);
    try testing.expectEqualStrings("Hello", completion.content.?);
    try testing.expectEqualStrings("gen-1", completion.generation_id.?);
    try testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try testing.expectEqualStrings("call_a", completion.tool_calls[0].id);
    try testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try testing.expectEqualStrings("{\"path\":\"a.txt\"}", completion.tool_calls[0].arguments_json);
    try testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try testing.expectEqual(@as(u64, 11), completion.usage.input_tokens.?);
    try testing.expectEqual(@as(u64, 7), completion.usage.output_tokens.?);
}

test "chat completions keep-alive comments never reach the JSON parser" {
    // A bare `: OPENROUTER PROCESSING` line is valid SSE framing but invalid
    // JSON; passing it to applyJson must be prevented by isCommentLine.
    try testing.expect(isCommentLine(": OPENROUTER PROCESSING"));
    try testing.expect(isCommentLine(":"));
    try testing.expect(!isCommentLine("data: {}"));
    try testing.expect(!isCommentLine(""));

    var capture: Capture = .{};
    defer capture.deinit(testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);
    var reducer = Reducer.init();
    defer reducer.deinit(testing.allocator);

    try testing.expectError(error.InvalidEvent, reducer.applyJson(
        testing.allocator,
        ": OPENROUTER PROCESSING",
        capture.callbacks(),
        &cancel,
        null,
        test_limits,
    ));
}

test "chat completions tool call fragments correlate by index not arrival order" {
    const sse =
        \\data: {"id":"g","choices":[{"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"one","arguments":"{\"x\":"}}]}}]}
        \\
        \\data: {"id":"g","choices":[{"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"two","arguments":"{\"y\":"}}]}}]}
        \\
        \\data: {"id":"g","choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"2}"}}]}}]}
        \\
        \\data: {"id":"g","choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}}]}}]}
        \\
        \\data: {"id":"g","choices":[{"delta":{},"finish_reason":"tool_calls"}]}
        \\
        \\data: [DONE]
    ;

    var capture: Capture = .{};
    defer capture.deinit(testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);
    var reducer = Reducer.init();
    defer reducer.deinit(testing.allocator);

    try reduceSse(&reducer, sse, &capture, &cancel);
    const completion = try reducer.finish(testing.allocator, &cancel);
    defer {
        if (completion.content) |content| testing.allocator.free(@constCast(content));
        if (completion.generation_id) |id| testing.allocator.free(@constCast(id));
        types.freeToolCallSlice(testing.allocator, @constCast(completion.tool_calls));
    }

    try testing.expectEqual(@as(usize, 2), completion.tool_calls.len);
    try testing.expectEqualStrings("one", completion.tool_calls[0].name);
    try testing.expectEqualStrings("{\"x\":1}", completion.tool_calls[0].arguments_json);
    try testing.expectEqualStrings("two", completion.tool_calls[1].name);
    try testing.expectEqualStrings("{\"y\":2}", completion.tool_calls[1].arguments_json);
    try testing.expectEqualStrings("a/one;b/two;", capture.starts.items);
}

test "chat completions surface a mid-stream error sent over HTTP 200" {
    var capture: Capture = .{};
    defer capture.deinit(testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);
    var reducer = Reducer.init();
    defer reducer.deinit(testing.allocator);

    try testing.expectError(error.ResponseFailed, reducer.applyJson(
        testing.allocator,
        "{\"id\":\"g\",\"error\":{\"code\":429,\"message\":\"Rate limit exceeded\"}," ++
            "\"choices\":[{\"delta\":{\"content\":\"\"},\"finish_reason\":\"error\"}]}",
        capture.callbacks(),
        &cancel,
        null,
        test_limits,
    ));
}

test "chat completions reject a stream that never reaches a terminal event" {
    const sse =
        \\data: {"id":"g","choices":[{"delta":{"content":"partial"}}]}
    ;
    var capture: Capture = .{};
    defer capture.deinit(testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);
    var reducer = Reducer.init();
    defer reducer.deinit(testing.allocator);

    try reduceSse(&reducer, sse, &capture, &cancel);
    try testing.expectError(error.StreamIncomplete, reducer.finish(testing.allocator, &cancel));
}

test "chat completions enforce declared resource ceilings" {
    var capture: Capture = .{};
    defer capture.deinit(testing.allocator);
    var cancel = std.atomic.Value(bool).init(false);
    var reducer = Reducer.init();
    defer reducer.deinit(testing.allocator);

    const tiny = StreamLimits{
        .aggregate_bytes = 16,
        .events = 1000,
        .tool_calls = 1,
        .tool_identity_bytes = 256,
        .tool_arguments_bytes = 4,
    };
    try testing.expectError(error.ResourceLimitExceeded, reducer.applyJson(
        testing.allocator,
        "{\"id\":\"generation-identifier-far-past-the-aggregate-ceiling\"}",
        capture.callbacks(),
        &cancel,
        null,
        tiny,
    ));

    var arguments = Reducer.init();
    defer arguments.deinit(testing.allocator);
    try testing.expectError(error.ResourceLimitExceeded, arguments.applyJson(
        testing.allocator,
        "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\"," ++
            "\"function\":{\"name\":\"t\",\"arguments\":\"0123456789\"}}]}}]}",
        capture.callbacks(),
        &cancel,
        null,
        .{
            .aggregate_bytes = 1 << 20,
            .events = 1000,
            .tool_calls = 4,
            .tool_identity_bytes = 256,
            .tool_arguments_bytes = 4,
        },
    ));
}

test "chat completions serialize messages tool calls and results" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const calls = [_]types.ToolCall{.{
        .id = "call_a",
        .name = "read_file",
        .arguments_json = "{\"path\":\"a.txt\"}",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be brief." },
        .{ .role = .user, .content = "Read a.txt" },
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "call_a", .content = "contents" },
    };

    try out.writer.writeByte('[');
    try writeMessages(&out.writer, testing.allocator, &messages, null, .{
        .tool_calls = 8,
        .tool_identity_bytes = 256,
        .tool_arguments_bytes = 1 << 16,
    });
    try out.writer.writeByte(']');

    try testing.expectEqualStrings(
        "[{\"role\":\"system\",\"content\":\"Be brief.\"}," ++
            "{\"role\":\"user\",\"content\":\"Read a.txt\"}," ++
            "{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"call_a\"," ++
            "\"type\":\"function\",\"function\":{\"name\":\"read_file\"," ++
            "\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}]}," ++
            "{\"role\":\"tool\",\"tool_call_id\":\"call_a\",\"content\":\"contents\"}]",
        out.written(),
    );
}

test "chat completions reject oversized replayed tool state before serializing" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const calls = [_]types.ToolCall{.{
        .id = "call_a",
        .name = "read_file",
        .arguments_json = "{\"path\":\"a.txt\"}",
    }};
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
    };
    try testing.expectError(error.ToolArgumentsTooLarge, writeMessages(
        &out.writer,
        testing.allocator,
        &messages,
        null,
        .{ .tool_calls = 8, .tool_identity_bytes = 256, .tool_arguments_bytes = 4 },
    ));
}
