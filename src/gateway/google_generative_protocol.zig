//! Native Google GenerateContent request/stream encoding used by the
//! OpenCode Zen Gemini models. The endpoint is intentionally small: Zen's
//! Gemini subset needs text, inline images, function calls, thought levels and
//! signed tool-call replay, not a second Google authentication stack.
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const model_provider = @import("../core/config/model_provider.zig");
const tool_call_ids = @import("tool_call_ids.zig");
const chat = @import("chat_completions_protocol.zig");
const sse = @import("sse.zig");

const Allocator = std.mem.Allocator;
pub const Error = chat.Error;

pub const association_field = "_tool_call_ids";
pub const parts_field = "parts";
pub const skip_thought_signature = "skip_thought_signature_validator";
const max_selected_tools = 256;
const max_name_bytes = 128;

pub const Options = struct {
    /// Replay is accepted only from this provider authority and model.
    provider: ?*const model_provider.ProviderId = null,
};

fn validate_request(request: stream_provider.RequestData) Error!void {
    try request.validatePrompt();
    configured_provider.validate_model_id(request.model) catch return error.InvalidModel;
    const options = request.provider_options;
    if (options.fast or options.ultrafast or options.provider_order.len != 0 or options.prompt_caching or options.skip_cache_writes) return error.UnsupportedProviderOption;
    if (request.response_format) |format| if (format.schema != .object) return error.UnsupportedResponseFormat;
    if (request.verified_images != null and request.verified_images.?.len != 0) return error.UnsupportedVision;
    for (request.instructions) |message| {
        if (message.role != .system or message.content == null or message.images.len != 0) return error.InvalidProviderPrompt;
    }
    for (request.messages) |message| {
        if (message.images.len != 0 and message.role != .user) return error.InvalidProviderPrompt;
        if (message.provider_replay != null and message.role != .assistant) return error.InvalidProviderState;
        if (message.role != .assistant and message.tool_calls.len != 0) return error.InvalidToolHistory;
        if (message.role != .tool and message.tool_call_id != null) return error.InvalidToolHistory;
        if (message.role != .assistant and message.content == null) return error.InvalidProviderPrompt;
        if (message.role == .assistant and message.content == null and message.tool_calls.len == 0 and message.provider_replay == null) return error.InvalidProviderPrompt;
    }
}

fn validate_name(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidToolName;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return error.InvalidToolName;
}

fn parse_replay(alloc: Allocator, raw: []const u8) Error!std.json.Parsed(std.json.Value) {
    if (raw.len > types.ProviderReplay.max_bytes) return error.ReplayTooLarge;
    try chat.check_json_depth(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderState,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() != 2) return error.InvalidProviderState;
    const parts = parsed.value.object.get(parts_field) orelse return error.InvalidProviderState;
    if (parts != .array or parts.array.items.len > max_selected_tools * 8) return error.InvalidProviderState;
    for (parts.array.items) |part| if (part != .object) return error.InvalidProviderState;
    const ids = parsed.value.object.get(association_field) orelse return error.InvalidProviderState;
    if (ids != .array or ids.array.items.len > max_selected_tools) return error.InvalidProviderState;
    for (ids.array.items, 0..) |id, index| {
        if (id != .string or id.string.len == 0 or id.string.len > 256) return error.InvalidProviderState;
        for (ids.array.items[0..index]) |prior| if (std.mem.eql(u8, id.string, prior.string)) return error.InvalidProviderState;
    }
    return parsed;
}

fn replay_calls_match(fields: std.json.ObjectMap, calls: []const types.ToolCall) bool {
    const ids = fields.get(association_field).?.array.items;
    if (ids.len != calls.len) return false;
    for (ids, calls) |id, call| if (!std.mem.eql(u8, id.string, call.id)) return false;
    return true;
}

/// Gemini thought signatures are provider state. Keep the whole state only
/// while the complete set of calls it preceded is still present.
pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, _: bool, reasoning: bool) Error!?types.ProviderReplay {
    const value = replay orelse return null;
    if (!reasoning) return null;
    var parsed = try parse_replay(alloc, value.parts_json);
    defer parsed.deinit();
    return if (replay_calls_match(parsed.value.object, calls)) value else null;
}

fn write_base64(writer: *std.Io.Writer, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 3 * 1024, bytes.len);
        try std.base64.standard.Encoder.encodeWriter(writer, bytes[offset..end]);
        offset = end;
    }
}

fn write_inline_data(writer: *std.Io.Writer, media_type: []const u8, bytes: []const u8) !void {
    try writer.writeAll("{\"inlineData\":{\"mimeType\":");
    try std.json.Stringify.value(media_type, .{}, writer);
    try writer.writeAll(",\"data\":\"");
    try write_base64(writer, bytes);
    try writer.writeAll("\"}}");
}

fn write_tool_image(writer: *std.Io.Writer, image: types.ToolImage) !void {
    try writer.writeAll("{\"inlineData\":{\"mimeType\":");
    try std.json.Stringify.value(image.mime_type, .{}, writer);
    try writer.writeAll(",\"data\":");
    try std.json.Stringify.value(image.data, .{}, writer);
    try writer.writeAll("}}");
}

fn write_user_parts(arena: Allocator, writer: *std.Io.Writer, message: types.ChatMessage) !void {
    try writer.writeByte('[');
    var wrote = false;
    if (message.content) |content| if (content.len != 0) {
        try writer.writeAll("{\"text\":");
        try std.json.Stringify.value(content, .{}, writer);
        try writer.writeByte('}');
        wrote = true;
    };
    for (message.images) |image| {
        var snapshot = image_attachments.loadVerifiedSnapshot(arena, image, .{}) catch return error.ImageUnavailable;
        defer snapshot.deinit(arena);
        if (wrote) try writer.writeByte(',');
        try write_inline_data(writer, snapshot.media_type, snapshot.bytes);
        wrote = true;
    }
    if (!wrote) try writer.writeAll("{\"text\":\"\"}");
    try writer.writeByte(']');
}

fn denied_tool_result(message: types.ChatMessage) bool {
    const failed = if (message.tool_result_status) |status| status == .failure else false;
    return failed and tool_result_errors.toolPermissionDenialReason(message.content orelse "") != null;
}

fn write_tool_result_parts(writer: *std.Io.Writer, projection: *const tool_call_ids.Projection, message: types.ChatMessage) !void {
    const name = message.tool_name orelse "tool";
    try writer.writeAll("{\"functionResponse\":{\"name\":");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(",\"response\":{");
    if (message.tool_result_status == .failure) {
        try writer.writeAll("\"error\":");
    } else {
        try writer.writeAll("\"output\":");
    }
    try std.json.Stringify.value(message.content orelse "", .{}, writer);
    try writer.writeAll("},\"id\":");
    try std.json.Stringify.value(projection.resolve(message.tool_call_id.?), .{}, writer);
    const images = if (message.tool_result_memory) |memory| memory.tool_images else &.{};
    var image_count: usize = 0;
    if (!denied_tool_result(message)) {
        for (images) |image| {
            if (image.data.len != 0) image_count += 1;
        }
    }
    if (image_count != 0) {
        try writer.writeAll(",\"parts\":[");
        var wrote = false;
        for (images) |image| {
            if (image.data.len == 0) continue;
            if (wrote) try writer.writeByte(',');
            try write_tool_image(writer, image);
            wrote = true;
        }
        try writer.writeByte(']');
    }
    try writer.writeAll("}}");
}

fn write_call_part(writer: *std.Io.Writer, projection: *const tool_call_ids.Projection, call: types.ToolCall) !void {
    try writer.writeAll("{\"functionCall\":{\"name\":");
    try std.json.Stringify.value(call.name, .{}, writer);
    try writer.writeAll(",\"args\":");
    const args = std.mem.trim(u8, call.arguments_json, " \t\r\n");
    try writer.writeAll(if (args.len == 0) "{}" else args);
    try writer.writeAll(",\"id\":");
    try std.json.Stringify.value(projection.resolve(call.id), .{}, writer);
    try writer.writeAll("},\"thoughtSignature\":");
    try std.json.Stringify.value(skip_thought_signature, .{}, writer);
    try writer.writeByte('}');
}

fn write_replay_parts(writer: *std.Io.Writer, alloc: Allocator, replay: types.ProviderReplay, calls: []const types.ToolCall, projection: *const tool_call_ids.Projection) (Error || std.Io.Writer.Error)!void {
    var parsed = try parse_replay(alloc, replay.parts_json);
    defer parsed.deinit();
    if (!replay_calls_match(parsed.value.object, calls)) return error.InvalidProviderState;
    const parts = parsed.value.object.get(parts_field).?.array.items;
    _ = projection; // Gemini ids are portable; keep opaque replay untouched.
    try writer.writeByte('[');
    for (parts, 0..) |part, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.Stringify.value(part, .{}, writer);
    }
    try writer.writeByte(']');
}

fn write_system_instruction(writer: *std.Io.Writer, instructions: []const types.ChatMessage) !bool {
    var count: usize = 0;
    for (instructions) |message| {
        if (message.content.?.len != 0) count += 1;
    }
    if (count == 0) return false;
    try writer.writeAll(",\"systemInstruction\":{\"parts\":[");
    var wrote = false;
    for (instructions) |message| {
        const text = message.content.?;
        if (text.len == 0) continue;
        if (wrote) try writer.writeByte(',');
        try writer.writeAll("{\"text\":");
        try std.json.Stringify.value(text, .{}, writer);
        try writer.writeByte('}');
        wrote = true;
    }
    try writer.writeAll("]}");
    return true;
}

fn write_tools(writer: *std.Io.Writer, alloc: Allocator, functions: []const chat.Function) !void {
    try writer.writeAll(",\"tools\":[{\"functionDeclarations\":[");
    for (functions, 0..) |function, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try std.json.Stringify.value(function.name, .{}, writer);
        try writer.writeAll(",\"description\":");
        try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, function.description);
        try writer.writeAll(",\"parametersJsonSchema\":");
        switch (function.schema) {
            .builtin => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
            .dynamic => |schema| try std.json.Stringify.value(schema, .{}, writer),
        }
        try writer.writeByte('}');
    }
    try writer.writeAll("]}]");
}

fn thinking_level(effort: types.ReasoningEffort) ?[]const u8 {
    const label = effort.label();
    if (std.mem.eql(u8, label, "minimal")) return "MINIMAL";
    if (std.mem.eql(u8, label, "low")) return "LOW";
    if (std.mem.eql(u8, label, "medium")) return "MEDIUM";
    if (std.mem.eql(u8, label, "high") or std.mem.eql(u8, label, "xhigh") or std.mem.eql(u8, label, "max")) return "HIGH";
    return null;
}

fn write_generation_config(writer: *std.Io.Writer, request: stream_provider.RequestData) !void {
    var wrote = false;
    if (request.max_output_tokens) |limit| {
        try writer.print("\"maxOutputTokens\":{d}", .{limit});
        wrote = true;
    }
    if (request.provider_options.reasoning) |effort| if (!effort.eql(types.ReasoningEffort.literal("none"))) {
        if (wrote) try writer.writeByte(',');
        try writer.writeAll("\"thinkingConfig\":{\"includeThoughts\":true");
        if (thinking_level(effort)) |level| {
            try writer.writeAll(",\"thinkingLevel\":");
            try std.json.Stringify.value(level, .{}, writer);
        }
        try writer.writeByte('}');
        wrote = true;
    };
    if (request.response_format) |format| {
        if (wrote) try writer.writeByte(',');
        try writer.writeAll("\"responseMimeType\":\"application/json\",\"responseSchema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        wrote = true;
    }
    try writer.writeByte('}');
}

fn write_contents(arena: Allocator, writer: *std.Io.Writer, request: stream_provider.RequestData, functions: []const chat.Function, projection: *const tool_call_ids.Projection) (Error || std.Io.Writer.Error)!void {
    _ = functions;
    try writer.writeAll("\"contents\":[");
    var count: usize = 0;
    var index: usize = 0;
    while (index < request.messages.len) : (index += 1) {
        const message = request.messages[index];
        if (message.role == .tool) {
            if (count != 0) try writer.writeByte(',');
            try writer.writeAll("{\"role\":\"user\",\"parts\":[");
            var tool_count: usize = 0;
            while (index < request.messages.len and request.messages[index].role == .tool) : (index += 1) {
                if (tool_count != 0) try writer.writeByte(',');
                try write_tool_result_parts(writer, projection, request.messages[index]);
                tool_count += 1;
            }
            try writer.writeAll("]}");
            count += 1;
            if (index > 0) index -= 1;
            continue;
        }
        if (message.role == .assistant and message.content == null and message.tool_calls.len == 0 and message.provider_replay == null) continue;
        if (count != 0) try writer.writeByte(',');
        try writer.writeAll("{\"role\":");
        try writer.writeAll(if (message.role == .assistant) "\"model\",\"parts\":" else "\"user\",\"parts\":");
        if (message.role == .assistant) {
            if (message.provider_replay) |replay| {
                try write_replay_parts(writer, arena, replay, message.tool_calls, projection);
            } else {
                try writer.writeByte('[');
                var wrote = false;
                if (message.content) |content| if (content.len != 0) {
                    try writer.writeAll("{\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                    wrote = true;
                };
                for (message.tool_calls) |call| {
                    if (wrote) try writer.writeByte(',');
                    try write_call_part(writer, projection, call);
                    wrote = true;
                }
                if (!wrote) try writer.writeAll("{\"text\":\"\"}");
                try writer.writeByte(']');
            }
        } else {
            try write_user_parts(arena, writer, message);
        }
        try writer.writeByte('}');
        count += 1;
    }
    if (count == 0 and request.messages.len == 0 and request.instructions.len != 0) {
        const fallback = request.instructions[request.instructions.len - 1].content.?;
        try writer.writeAll("{\"role\":\"user\",\"parts\":[{\"text\":");
        try std.json.Stringify.value(fallback, .{}, writer);
        try writer.writeAll("}]}");
    }
    try writer.writeByte(']');
}

/// Pure native GenerateContent serialization. Caller owns the result.
pub fn build_request(alloc: Allocator, input: stream_provider.RequestData, options: Options) Error![]u8 {
    try validate_request(input);
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var request = input;
    if (options.provider) |provider| {
        if (try types.projectProviderReplay(arena, input.messages, .{ .provider = provider.*, .model = input.model })) |projected| request.messages = projected;
    } else for (input.messages) |message| if (message.provider_replay != null) return error.UnsupportedReplay;
    try chat.validate_history(arena, request.messages);
    var functions = try chat.select_functions(arena, request.tools, request.tool_choice);
    defer functions.deinit(arena);
    var projection = tool_call_ids.Projection.init(arena, request.messages) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolCallId,
    };
    defer projection.deinit(arena);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    out.writer.writeByte('{') catch return error.OutOfMemory;
    write_contents(arena, &out.writer, request, functions.items, &projection) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.InvalidProviderState, error.ReplayTooLarge, error.JsonTooDeep, error.ImageUnavailable, error.InvalidProviderPrompt => |failure| return failure,
        else => return error.InvalidToolSchema,
    };
    _ = write_system_instruction(&out.writer, request.instructions) catch return error.OutOfMemory;
    if (functions.items.len != 0) write_tools(&out.writer, arena, functions.items) catch return error.OutOfMemory;
    if (functions.items.len != 0) {
        out.writer.writeAll(",\"toolConfig\":{\"functionCallingConfig\":{\"mode\":") catch return error.OutOfMemory;
        out.writer.writeAll(switch (request.tool_choice) {
            .auto => "\"AUTO\"",
            .none => "\"NONE\"",
            .required => "\"ANY\"",
        }) catch return error.OutOfMemory;
        out.writer.writeAll("}}") catch return error.OutOfMemory;
    }
    if (request.max_output_tokens != null or request.provider_options.reasoning != null or request.response_format != null) {
        out.writer.writeAll(",\"generationConfig\":{") catch return error.OutOfMemory;
        write_generation_config(&out.writer, request) catch return error.OutOfMemory;
    }
    out.writer.writeByte('}') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

pub const Limits = struct {
    event_bytes: usize = 1024 * 1024,
    total_wire_bytes: usize = 32 * 1024 * 1024,
    events: usize = 100_000,
    tool_calls: usize = 128,
    identity_bytes: usize = 256,
    arguments_bytes: usize = 1024 * 1024,
    content_bytes: usize = 8 * 1024 * 1024,
    reasoning_bytes: usize = types.ProviderReplay.max_bytes,
};

const ReplayPart = struct {
    json: ?[]u8 = null,
    tool_index: ?usize = null,

    fn deinit(self: *ReplayPart, alloc: Allocator) void {
        if (self.json) |json| alloc.free(json);
    }
};

const Tool = struct {
    id: ?[]u8 = null,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,
    signature: ?[]u8 = null,
    replay_index: usize = 0,
    announced: bool = false,
    emitted: usize = 0,

    fn deinit(self: *Tool, alloc: Allocator) void {
        if (self.id) |id| alloc.free(id);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        if (self.signature) |signature| alloc.free(signature);
    }
};

pub const Reducer = struct {
    alloc: Allocator,
    limits: Limits,
    choice: types.ToolChoice,
    tools: std.ArrayList(Tool) = .empty,
    replay_parts: std.ArrayList(ReplayPart) = .empty,
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    content_emitted: usize = 0,
    reasoning_emitted: usize = 0,
    generation_id: ?[]u8 = null,
    usage: types.Usage = .{},
    finish_reason: ?types.ProviderFinishReason = null,
    prompt_blocked: bool = false,
    phase: enum { receiving, finished, done, closed } = .receiving,
    event_count: usize = 0,
    json_bytes: usize = 0,

    pub fn init(alloc: Allocator, request: stream_provider.RequestData, limits: Limits) Error!Reducer {
        try validate_request(request);
        return .{ .alloc = alloc, .limits = limits, .choice = request.tool_choice };
    }

    pub fn deinit(self: *Reducer) void {
        for (self.tools.items) |*tool| tool.deinit(self.alloc);
        self.tools.deinit(self.alloc);
        for (self.replay_parts.items) |*part| part.deinit(self.alloc);
        self.replay_parts.deinit(self.alloc);
        self.content.deinit(self.alloc);
        self.reasoning.deinit(self.alloc);
        if (self.generation_id) |id| self.alloc.free(id);
        self.* = undefined;
    }

    fn append_bounded(self: *Reducer, destination: *std.ArrayList(u8), text: []const u8, limit: usize, failure: Error) Error!void {
        if (text.len > limit - destination.items.len) return failure;
        try destination.appendSlice(self.alloc, text);
    }

    fn identity(self: *Reducer, destination: *?[]u8, value: ?std.json.Value) Error!void {
        const item = value orelse return;
        if (item != .string or item.string.len == 0) return error.InvalidChunk;
        if (item.string.len > self.limits.identity_bytes) return error.IdentityTooLarge;
        if (destination.*) |prior| {
            if (!std.mem.eql(u8, prior, item.string)) return error.ConflictingIdentity;
        } else destination.* = try self.alloc.dupe(u8, item.string);
    }

    pub fn accept(self: *Reducer, data: []const u8, cancelled: bool) Error!void {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        if (self.phase == .closed or self.phase == .done) return error.StreamClosed;
        if (data.len > self.limits.event_bytes) return error.EventTooLarge;
        if (data.len > self.limits.total_wire_bytes - self.json_bytes) return error.StreamTooLarge;
        self.json_bytes += data.len;
        if (self.event_count == self.limits.events) return error.TooManyEvents;
        self.event_count += 1;
        if (std.mem.eql(u8, data, "[DONE]")) {
            if (self.phase != .finished) return error.IncompleteStream;
            self.phase = .done;
            return;
        }
        try chat.check_json_depth(data);
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidChunk,
        };
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidChunk;
        const root = parsed.value.object;
        if (root.get("error")) |error_value| if (error_value != .null) return error.ProviderError;
        try self.identity(&self.generation_id, root.get("responseId"));
        if (root.get("promptFeedback")) |feedback| {
            if (feedback == .object) if (feedback.object.get("blockReason")) |reason| {
                if (reason != .string or reason.string.len == 0) return error.InvalidChunk;
                self.prompt_blocked = true;
                self.phase = .finished;
            };
        }
        if (root.get("usageMetadata")) |usage| try self.accept_usage(usage);
        if (root.get("candidates")) |candidates_value| {
            if (candidates_value != .array or candidates_value.array.items.len > 1) return error.InvalidChunk;
            if (candidates_value.array.items.len == 1) try self.accept_candidate(candidates_value.array.items[0]);
        }
    }

    fn accept_usage(self: *Reducer, value: std.json.Value) Error!void {
        if (value != .object) return error.InvalidChunk;
        const fields = value.object;
        const input = (try optional_count(fields, "promptTokenCount")) orelse self.usage.input_tokens;
        const output = (try optional_count(fields, "candidatesTokenCount")) orelse self.usage.output_tokens;
        const cache = (try optional_count(fields, "cachedContentTokenCount")) orelse self.usage.cache_read_tokens;
        const reasoning = (try optional_count(fields, "thoughtsTokenCount")) orelse self.usage.reasoning_tokens;
        if (self.usage.input_tokens) |prior| if (input) |current| if (current < prior) return error.ConflictingIdentity;
        if (self.usage.output_tokens) |prior| if (output) |current| if (current < prior) return error.ConflictingIdentity;
        if (self.usage.cache_read_tokens) |prior| if (cache) |current| if (current < prior) return error.ConflictingIdentity;
        if (self.usage.reasoning_tokens) |prior| if (reasoning) |current| if (current < prior) return error.ConflictingIdentity;
        self.usage = .{ .input_tokens = input, .output_tokens = output, .cache_read_tokens = cache, .cache_write_tokens = self.usage.cache_write_tokens, .reasoning_tokens = reasoning };
    }

    fn accept_candidate(self: *Reducer, value: std.json.Value) Error!void {
        if (value != .object) return error.InvalidChunk;
        const candidate = value.object;
        if (candidate.get("index")) |index| if (index != .integer or index.integer != 0) return error.InvalidChunk;
        if (candidate.get("content")) |content| {
            if (content != .object) return error.InvalidChunk;
            const fields = content.object;
            if (fields.get("role")) |role| if (role != .string or !std.mem.eql(u8, role.string, "model")) return error.InvalidChunk;
            if (fields.get("parts")) |parts| {
                if (parts != .array) return error.InvalidChunk;
                for (parts.array.items) |part| try self.accept_part(part);
            }
        }
        if (candidate.get("finishReason")) |reason| {
            if (reason == .null) return;
            if (reason != .string) return error.InvalidChunk;
            const mapped = map_finish_reason(reason.string, self.tools.items.len != 0) orelse return error.InvalidFinishReason;
            if (self.finish_reason) |prior| {
                if (prior != mapped) return error.InconsistentFinishReason;
            } else self.finish_reason = mapped;
            self.phase = .finished;
        }
    }

    fn accept_part(self: *Reducer, value: std.json.Value) Error!void {
        if (value != .object) return error.InvalidChunk;
        const fields = value.object;
        var captured = false;
        if (fields.get("text")) |text| {
            if (text != .string) return error.InvalidChunk;
            const thought = if (fields.get("thought")) |flag| if (flag == .bool) flag.bool else return error.InvalidChunk else false;
            if (thought) try self.append_bounded(&self.reasoning, text.string, self.limits.reasoning_bytes, error.ReplayTooLarge) else try self.append_bounded(&self.content, text.string, self.limits.content_bytes, error.ContentTooLarge);
            const encoded = try std.json.Stringify.valueAlloc(self.alloc, value, .{});
            errdefer self.alloc.free(encoded);
            try self.replay_parts.append(self.alloc, .{ .json = encoded });
            captured = true;
        }
        if (fields.get("functionCall")) |function_value| {
            try self.accept_function(function_value, fields.get("thoughtSignature"));
            captured = true;
        }
        if (fields.get("thoughtSignature")) |signature| {
            if (signature != .string) return error.InvalidChunk;
            if (!captured) {
                const encoded = try std.json.Stringify.valueAlloc(self.alloc, value, .{});
                errdefer self.alloc.free(encoded);
                try self.replay_parts.append(self.alloc, .{ .json = encoded });
            }
        }
    }

    fn accept_function(self: *Reducer, value: std.json.Value, signature: ?std.json.Value) Error!void {
        if (self.choice == .none) return error.UnexpectedToolCall;
        if (value != .object) return error.InvalidChunk;
        const fields = value.object;
        const name_value = fields.get("name") orelse return error.InvalidToolName;
        if (name_value != .string) return error.InvalidToolName;
        try validate_name(name_value.string);
        var index: usize = self.tools.items.len;
        if (fields.get("id")) |id| {
            if (id != .string or id.string.len == 0 or id.string.len > self.limits.identity_bytes) return error.InvalidToolCallId;
            for (self.tools.items, 0..) |tool, prior| if (tool.id) |existing| if (std.mem.eql(u8, existing, id.string)) {
                index = prior;
                break;
            };
        }
        if (index >= self.limits.tool_calls) return error.TooManyTools;
        while (self.tools.items.len <= index) {
            const replay_index = self.replay_parts.items.len;
            try self.tools.append(self.alloc, .{ .replay_index = replay_index });
            try self.replay_parts.append(self.alloc, .{ .tool_index = self.tools.items.len - 1 });
        }
        const tool = &self.tools.items[index];
        if (tool.id == null) {
            if (fields.get("id")) |id| {
                tool.id = try self.alloc.dupe(u8, id.string);
            } else {
                tool.id = try self.alloc.print("tool_{d}", .{index});
            }
        } else if (fields.get("id")) |id| if (!std.mem.eql(u8, tool.id.?, id.string)) return error.ConflictingIdentity;
        if (tool.name.items.len == 0) try tool.name.appendSlice(self.alloc, name_value.string) else if (!std.mem.eql(u8, tool.name.items, name_value.string)) return error.ConflictingIdentity;
        if (fields.get("args")) |args| {
            if (args != .object) return error.InvalidToolArguments;
            const encoded = try std.json.Stringify.valueAlloc(self.alloc, args, .{});
            defer self.alloc.free(encoded);
            if (tool.arguments.items.len == 0 or std.mem.eql(u8, tool.arguments.items, "{}")) {
                tool.arguments.clearRetainingCapacity();
                try self.append_bounded(&tool.arguments, encoded, self.limits.arguments_bytes, error.ArgumentsTooLarge);
            } else if (!std.mem.eql(u8, tool.arguments.items, encoded)) {
                // Google normally delivers one complete args object. A second
                // object is accepted only when it carries no new fields.
                var prior = std.json.parseFromSlice(std.json.Value, self.alloc, tool.arguments.items, .{}) catch return error.InvalidToolArguments;
                defer prior.deinit();
                if (prior.value != .object or args.object.count() != 0) return error.InvalidToolArguments;
            }
        }
        if (signature) |raw| {
            if (raw != .string) return error.InvalidChunk;
            if (raw.string.len != 0 and tool.signature == null) tool.signature = try self.alloc.dupe(u8, raw.string);
        }
    }

    pub fn emit_tool_progress(self: *Reducer, sink: stream_provider.EventSink) void {
        for (self.tools.items, 0..) |*tool, index| {
            const id = tool.id orelse continue;
            if (!tool.announced) {
                if (tool.name.items.len == 0) continue;
                tool.announced = true;
                sink.emit(.{ .tool_started = .{ .id = id, .name = tool.name.items } });
            }
            if (tool.arguments.items.len > tool.emitted) {
                sink.emit(.{ .tool_input_delta = .{ .id = id, .index = index, .chunk = tool.arguments.items[tool.emitted..] } });
                tool.emitted = tool.arguments.items.len;
            }
        }
    }

    fn replay_state(self: *Reducer) Error!?[]u8 {
        if (self.replay_parts.items.len == 0) return null;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        out.writer.writeAll("{\"parts\":[") catch return error.OutOfMemory;
        for (self.replay_parts.items, 0..) |part, index| {
            if (index != 0) out.writer.writeByte(',') catch return error.OutOfMemory;
            if (part.tool_index) |tool_index| {
                try self.write_tool_replay(&out.writer, &self.tools.items[tool_index]);
            } else {
                out.writer.writeAll(part.json.?) catch return error.OutOfMemory;
            }
        }
        out.writer.writeAll("],\"_tool_call_ids\":[") catch return error.OutOfMemory;
        for (self.tools.items, 0..) |tool, index| {
            if (index != 0) out.writer.writeByte(',') catch return error.OutOfMemory;
            std.json.Stringify.value(tool.id orelse return error.InvalidToolCallId, .{}, &out.writer) catch return error.OutOfMemory;
        }
        out.writer.writeByte(']') catch return error.OutOfMemory;
        out.writer.writeByte('}') catch return error.OutOfMemory;
        if (out.written().len > types.ProviderReplay.max_bytes) return error.ReplayTooLarge;
        return try out.toOwnedSlice();
    }

    fn write_tool_replay(self: *Reducer, writer: *std.Io.Writer, tool: *const Tool) Error!void {
        _ = self;
        writer.writeAll("{\"functionCall\":{\"name\":") catch return error.OutOfMemory;
        std.json.Stringify.value(tool.name.items, .{}, writer) catch return error.OutOfMemory;
        writer.writeAll(",\"args\":") catch return error.OutOfMemory;
        writer.writeAll(if (tool.arguments.items.len == 0) "{}" else tool.arguments.items) catch return error.OutOfMemory;
        writer.writeAll(",\"id\":") catch return error.OutOfMemory;
        std.json.Stringify.value(tool.id.?, .{}, writer) catch return error.OutOfMemory;
        writer.writeAll("},\"thoughtSignature\":") catch return error.OutOfMemory;
        std.json.Stringify.value(tool.signature orelse skip_thought_signature, .{}, writer) catch return error.OutOfMemory;
        writer.writeByte('}') catch return error.OutOfMemory;
    }

    pub fn finish(self: *Reducer, cancelled: bool) Error!stream_provider.Result {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        if (self.phase == .closed) return error.StreamClosed;
        if (self.phase != .done) return error.IncompleteStream;
        if (self.prompt_blocked) return error.ContentFiltered;
        const reason = self.finish_reason orelse return error.IncompleteStream;
        if (reason == .content_filter) return error.ContentFiltered;
        if (reason != .stop and reason != .length and reason != .tool_calls) return error.ProviderError;
        if (reason != .length) {
            if ((reason == .tool_calls) != (self.tools.items.len != 0)) return error.InconsistentFinishReason;
            if (self.choice == .required and self.tools.items.len == 0) return error.RequiredToolMissing;
        }
        const state = try self.replay_state();
        errdefer if (state) |value| self.alloc.free(value);
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| {
                self.alloc.free(call.id);
                self.alloc.free(call.name);
                self.alloc.free(call.arguments_json);
            }
            calls.deinit(self.alloc);
        }
        for (self.tools.items) |*tool| {
            const id = tool.id orelse return error.InvalidToolCallId;
            tool.id = null;
            errdefer self.alloc.free(id);
            const name = try tool.name.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(name);
            const args = if (tool.arguments.items.len == 0) try self.alloc.dupe(u8, "{}") else try tool.arguments.toOwnedSlice(self.alloc);
            errdefer self.alloc.free(args);
            try calls.append(self.alloc, .{ .id = id, .name = name, .arguments_json = args });
        }
        const content = if (self.content.items.len != 0) try self.content.toOwnedSlice(self.alloc) else null;
        errdefer if (content) |value| self.alloc.free(value);
        const generation = self.generation_id;
        self.generation_id = null;
        errdefer if (generation) |value| self.alloc.free(value);
        const owned_calls = try calls.toOwnedSlice(self.alloc);
        self.phase = .closed;
        return .{ .completed = .{ .completion = .{
            .content = content,
            .tool_calls = owned_calls,
            .generation_id = generation,
            .finish_reason = if (self.tools.items.len != 0 and reason == .stop) .tool_calls else reason,
            .usage = self.usage,
            .provider_state_json = state,
        }, .ownership = .owned } };
    }
};

fn map_finish_reason(raw: []const u8, has_tools: bool) ?types.ProviderFinishReason {
    if (std.mem.eql(u8, raw, "STOP")) return if (has_tools) .tool_calls else .stop;
    if (std.mem.eql(u8, raw, "MAX_TOKENS")) return .length;
    if (std.mem.eql(u8, raw, "SAFETY") or std.mem.eql(u8, raw, "BLOCKLIST") or std.mem.eql(u8, raw, "PROHIBITED_CONTENT") or std.mem.eql(u8, raw, "SPII") or std.mem.eql(u8, raw, "IMAGE_SAFETY") or std.mem.eql(u8, raw, "IMAGE_PROHIBITED_CONTENT") or std.mem.eql(u8, raw, "IMAGE_RECITATION") or std.mem.eql(u8, raw, "NO_IMAGE")) return .content_filter;
    if (std.mem.eql(u8, raw, "FINISH_REASON_UNSPECIFIED") or std.mem.eql(u8, raw, "OTHER") or std.mem.eql(u8, raw, "RECITATION") or std.mem.eql(u8, raw, "LANGUAGE") or std.mem.eql(u8, raw, "MALFORMED_FUNCTION_CALL") or std.mem.eql(u8, raw, "UNEXPECTED_TOOL_CALL")) return .provider_error;
    return null;
}

fn optional_count(fields: std.json.ObjectMap, key: []const u8) Error!?u64 {
    const value = fields.get(key) orelse return null;
    if (value == .null) return null;
    const integer = switch (value) {
        .integer => value.integer,
        .number_string => std.fmt.parseInt(i64, value.number_string, 10) catch return error.InvalidChunk,
        else => return error.InvalidChunk,
    };
    return std.math.cast(u64, integer) orelse return error.InvalidChunk;
}

/// Consumes Google SSE until EOF (Google has no OpenAI `[DONE]` requirement).
pub fn consume_stream(alloc: Allocator, source: *std.Io.Reader, request: stream_provider.RequestData, limits: Limits, events: ?stream_provider.EventSink, cancel_flag: *const std.atomic.Value(bool), progress: ?sse.Progress) Error!stream_provider.Result {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var reducer = try Reducer.init(alloc, request, limits);
    defer reducer.deinit();
    var framing = sse.Reader{ .max_event_bytes = limits.event_bytes, .progress = progress };
    defer framing.deinit(alloc);
    while (true) {
        const remaining = limits.total_wire_bytes - framing.total_bytes;
        framing.max_total_bytes = framing.total_bytes + @min(limits.event_bytes, remaining);
        const data = framing.next(alloc, source, cancel_flag) catch |err| switch (err) {
            error.StreamTooLarge => return error.StreamTooLarge,
            else => return err,
        };
        if (data == null) {
            if (reducer.phase == .finished) {
                reducer.phase = .done;
                return reducer.finish(cancel_flag.load(.seq_cst));
            }
            return error.IncompleteStream;
        }
        try reducer.accept(data.?, cancel_flag.load(.seq_cst));
        if (events) |sink| {
            if (reducer.reasoning.items.len > reducer.reasoning_emitted) {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                sink.emit(.{ .reasoning_delta = reducer.reasoning.items[reducer.reasoning_emitted..] });
                reducer.reasoning_emitted = reducer.reasoning.items.len;
            }
            if (reducer.content.items.len > reducer.content_emitted) {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                sink.emit(.{ .content_delta = reducer.content.items[reducer.content_emitted..] });
                reducer.content_emitted = reducer.content.items.len;
            }
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            reducer.emit_tool_progress(sink);
        }
        if (reducer.phase == .finished) {
            // Keep reading usage trailers and the final delimiter; EOF is the
            // terminal proof used by the native Google API.
        }
    }
}

test "native Google stream preserves thought text tools and usage" {
    const alloc = std.testing.allocator;
    const request = stream_provider.RequestData{
        .model = "gemini-3-flash",
        .messages = &.{.{ .role = .user, .content = "hello" }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const wire =
        "data: {\"responseId\":\"r1\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"think\",\"thought\":true}]}}]}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"answer\"}]}}],\"usageMetadata\":{\"promptTokenCount\":2,\"candidatesTokenCount\":3,\"thoughtsTokenCount\":1}}\n\n" ++
        "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"lookup\",\"args\":{\"q\":\"zig\"},\"id\":\"call-1\"},\"thoughtSignature\":\"sig\"}]},\"finishReason\":\"STOP\"}]}\n\n";
    var source = std.Io.Reader.fixed(wire);
    var cancelled = std.atomic.Value(bool).init(false);
    var result = try consume_stream(alloc, &source, request, .{}, null, &cancelled, null);
    defer result.deinit(alloc);
    switch (result) {
        .completed => |completed| {
            try std.testing.expectEqualStrings("answer", completed.completion.content.?);
            try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completed.completion.finish_reason);
            try std.testing.expectEqual(@as(usize, 1), completed.completion.tool_calls.len);
            try std.testing.expectEqualStrings("lookup", completed.completion.tool_calls[0].name);
            try std.testing.expectEqual(@as(u64, 2), completed.completion.usage.input_tokens.?);
            try std.testing.expectEqual(@as(u64, 1), completed.completion.usage.reasoning_tokens.?);
            try std.testing.expect(completed.completion.provider_state_json != null);
        },
        .failed => return error.TestUnexpectedResult,
    }
}
