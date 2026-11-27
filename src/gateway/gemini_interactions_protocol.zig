//! Google Gemini Interactions API codec: builds stateless request bodies for
//! `/v1beta/interactions:createPerUserQuota` and reduces server-sent events.
//! The transport owns the connection, headers, deadlines, and credentials;
//! nothing here does I/O beyond the reader it is handed.
const std = @import("std");
const testing_allocator = @import("../core/shared/testing_allocator.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const tool_call_ids = @import("tool_call_ids.zig");
const sse = @import("sse.zig");
const function_tools = @import("function_tools.zig");
const json_depth = @import("../core/shared/json_depth.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const model_provider = @import("../core/config/model_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const text_utils = @import("../core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const ThinkingLevel = enum { minimal, low, medium, high, xhigh };

pub const Options = struct {
    provider: model_provider.ProviderId,
    thinking_level: ?ThinkingLevel = null,
};

pub const Error = error{
    OutOfMemory,
    InvalidProviderPrompt,
    InvalidModel,
    UnsupportedProviderOption,
    UnsupportedVision,
    UnsupportedResponseFormat,
    UnsupportedReplay,
    InvalidProviderState,
    ReplayTooLarge,
    UnsupportedToolProvenance,
    InvalidOutputLimit,
    InvalidToolSelection,
    InvalidToolSchema,
    InvalidToolCallId,
    InvalidToolName,
    InvalidToolArguments,
    InvalidToolHistory,
    ImageUnavailable,
    RequiredToolMissing,
    UnexpectedToolCall,
    /// Valid JSON that is not an event this protocol sends.
    InvalidEvent,
    /// Event data that is not JSON at all, as if damaged on the way.
    MalformedInteractionsEvent,
    ConflictingIdentity,
    InvalidFinishReason,
    InconsistentFinishReason,
    IncompleteStream,
    StreamClosed,
    EventTooLarge,
    StreamTooLarge,
    TooManyEvents,
    TooManySteps,
    TooManyTools,
    IdentityTooLarge,
    ArgumentsTooLarge,
    ContentTooLarge,
    JsonTooDeep,
    Cancelled,
    ReadFailed,
};

const max_history_arguments_bytes: usize = 1024 * 1024;
const max_error_detail_bytes: usize = 64 * 1024;

fn validate_request(request: stream_provider.RequestData, has_thinking_level: bool) Error!void {
    try request.validatePrompt();
    configured_provider.validate_model_id(request.model) catch return error.InvalidModel;
    const options = request.provider_options;
    if (options.reasoning != null and !has_thinking_level) return error.UnsupportedProviderOption;
    if (options.fast or options.ultrafast or options.prompt_caching or options.cache_markers != .none) return error.UnsupportedProviderOption;
    if (options.provider_order.len != 0) return error.UnsupportedProviderOption;
    if (request.response_format) |format| if (format.schema != .object) return error.UnsupportedResponseFormat;
    if (request.verified_images) |images| if (images.len != 0) {
        if (request.response_format == null or function_tools.last_user_index(request.messages) == null) return error.UnsupportedVision;
    };
    if (request.max_output_tokens == 0) return error.InvalidOutputLimit;
    for (request.messages) |message| {
        if (message.images.len != 0 and message.role != .user) return error.InvalidProviderPrompt;
        if (message.provider_replay != null and message.role != .assistant) return error.InvalidProviderState;
        if (message.role != .assistant and message.tool_calls.len != 0) return error.InvalidToolHistory;
        if (message.role != .tool and message.tool_call_id != null) return error.InvalidToolHistory;
        if (message.role != .assistant and message.content == null) return error.InvalidProviderPrompt;
        if (message.role == .assistant and message.content == null and message.tool_calls.len == 0 and message.provider_replay == null) return error.InvalidProviderPrompt;
    }
}

fn check_json_depth(text: []const u8) Error!void {
    if (json_depth.exceeds(text)) return error.JsonTooDeep;
}

fn validate_arguments(alloc: Allocator, text: []const u8) Error!void {
    try check_json_depth(text);
    if (try types.ToolArgumentIntegrity.classifyFunctionInput(alloc, text) != .valid) return error.InvalidToolArguments;
}

fn validate_history(alloc: Allocator, messages: []const types.ChatMessage) Error!void {
    var pending: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer pending.deinit(alloc);
    for (messages) |message| {
        if (message.role == .tool) {
            const id = message.tool_call_id orelse return error.InvalidToolCallId;
            const name = pending.get(id) orelse return error.InvalidToolHistory;
            if (message.tool_name) |tool_name| if (!std.mem.eql(u8, tool_name, name)) return error.InvalidToolHistory;
            _ = pending.remove(id);
            continue;
        }
        if (pending.count() != 0) return error.InvalidToolHistory;
        if (message.tool_calls.len > function_tools.max_selected_tools) return error.TooManyTools;
        for (message.tool_calls) |call| {
            if (call.provenance != .fx_local or call.provider_result != null) return error.UnsupportedToolProvenance;
            if (call.id.len == 0 or call.final_identity != .valid) return error.InvalidToolCallId;
            try function_tools.validate_name(call.name);
            if (call.arguments_json.len > max_history_arguments_bytes) return error.ArgumentsTooLarge;
            try validate_arguments(alloc, call.arguments_json);
            const entry = try pending.getOrPut(alloc, call.id);
            if (entry.found_existing) return error.InvalidToolHistory;
            entry.value_ptr.* = call.name;
        }
    }
    if (pending.count() != 0) return error.InvalidToolHistory;
}

/// Parses one assistant message's replay: the JSON array of `thought` steps
/// `Reducer.provider_state` wrote, in the reply's order.
fn parse_replay(alloc: Allocator, raw: []const u8) Error!std.json.Parsed(std.json.Value) {
    if (raw.len > types.ProviderReplay.max_bytes) return error.ReplayTooLarge;
    try check_json_depth(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderState,
    };
    errdefer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len == 0) return error.InvalidProviderState;
    for (parsed.value.array.items) |step| try validate_replay_step(step);
    return parsed;
}

fn validate_replay_step(step: std.json.Value) Error!void {
    if (step != .object) return error.InvalidProviderState;
    const fields = step.object;
    const kind = fields.get("type") orelse return error.InvalidProviderState;
    if (kind != .string or !std.mem.eql(u8, kind.string, "thought")) return error.InvalidProviderState;
    const signature = fields.get("signature") orelse return error.InvalidProviderState;
    if (signature != .string) return error.InvalidProviderState;
    var expected_keys: usize = 2;
    if (fields.get("summary")) |summary| {
        expected_keys += 1;
        if (summary != .array) return error.InvalidProviderState;
        for (summary.array.items) |item| {
            if (item != .object) return error.InvalidProviderState;
            const item_fields = item.object;
            if (item_fields.keys().len != 2) return error.InvalidProviderState;
            const item_type = item_fields.get("type") orelse return error.InvalidProviderState;
            const item_text = item_fields.get("text") orelse return error.InvalidProviderState;
            if (item_type != .string or !std.mem.eql(u8, item_type.string, "text")) return error.InvalidProviderState;
            if (item_text != .string) return error.InvalidProviderState;
        }
    }
    if (fields.keys().len != expected_keys) return error.InvalidProviderState;
}

/// Borrows `replay` unchanged after validating it. Never drops a valid replay,
/// because Google rejects the next turn with HTTP 400 "Invalid thought
/// signature" if any kept assistant turn loses its thought steps.
pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, _: []const types.ToolCall, _: bool, _: bool) Error!?types.ProviderReplay {
    const value = replay orelse return null;
    var parsed = try parse_replay(alloc, value.parts_json);
    parsed.deinit();
    return value;
}

/// Caller owns the returned request body. Model IDs are opaque.
pub fn build_request(alloc: Allocator, input: stream_provider.RequestData, options: Options) Error![]u8 {
    try validate_request(input, options.thinking_level != null);
    const projected = try types.projectProviderReplay(alloc, input.messages, .{ .provider = options.provider, .model = input.model });
    defer if (projected) |messages| alloc.free(messages);
    var request = input;
    request.messages = projected orelse input.messages;
    try validate_history(alloc, request.messages);
    var functions = try function_tools.select_functions(alloc, request.tools, request.tool_choice, request.vision_mode);
    defer functions.deinit(alloc);
    var projection = tool_call_ids.Projection.init(alloc, request.messages) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolCallId,
    };
    defer projection.deinit(alloc);
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    write_request(&out.writer, alloc, request, options, functions.items, &projection) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.InvalidProviderState, error.ReplayTooLarge, error.JsonTooDeep, error.ImageUnavailable, error.InvalidProviderPrompt, error.InvalidToolHistory => |failure| return failure,
        else => return error.InvalidToolSchema,
    };
    return out.toOwnedSlice();
}

fn write_request(
    writer: *std.Io.Writer,
    alloc: Allocator,
    request: stream_provider.RequestData,
    options: Options,
    functions: []const function_tools.Function,
    projection: *const tool_call_ids.Projection,
) !void {
    try write_json_string(writer, "{\"model\":", request.model);
    try writer.writeAll(",\"store\":false,\"stream\":true");
    try write_system(writer, alloc, request.instructions);
    try write_input(writer, alloc, request, projection);
    if (functions.len != 0) {
        try writer.writeAll(",\"tools\":[");
        for (functions, 0..) |function, index| {
            if (index != 0) try writer.writeByte(',');
            try write_json_string(writer, "{\"type\":\"function\",\"name\":", function.name);
            try writer.writeAll(",\"description\":");
            try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, function.description);
            try writer.writeAll(",\"parameters\":");
            switch (function.schema) {
                .builtin => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
                .dynamic => |schema| try std.json.Stringify.value(schema, .{}, writer),
            }
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
    }
    if (request.response_format) |format| {
        try writer.writeAll(",\"response_format\":{\"type\":\"text\",\"mime_type\":\"application/json\",\"schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        try writer.writeByte('}');
    }
    try write_generation_config(writer, request, options, functions.len != 0);
    try writer.writeByte('}');
}

fn write_generation_config(
    writer: *std.Io.Writer,
    request: stream_provider.RequestData,
    options: Options,
    has_tools: bool,
) !void {
    try writer.writeAll(",\"generation_config\":{");
    if (options.thinking_level) |level| {
        try write_json_string(writer, "\"thinking_level\":", @tagName(level));
        try writer.writeByte(',');
    }
    try writer.writeAll("\"thinking_summaries\":\"auto\"");
    if (has_tools) {
        const choice: types.ToolChoice = if (request.vision_mode == .required) .required else request.tool_choice;
        try writer.writeAll(",\"tool_choice\":");
        try writer.writeAll(switch (choice) {
            .auto => "\"auto\"",
            .required => "\"any\"",
            .none => "\"none\"",
        });
    }
    if (request.max_output_tokens) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});
    try writer.writeByte('}');
}

fn write_system(writer: *std.Io.Writer, alloc: Allocator, instructions: []const types.ChatMessage) !void {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(alloc);
    for (instructions) |instruction| {
        const text = instruction.content orelse continue;
        if (text.len == 0) continue;
        if (joined.items.len != 0) try joined.appendSlice(alloc, "\n\n");
        try joined.appendSlice(alloc, text);
    }
    if (joined.items.len == 0) return;
    try write_json_string(writer, ",\"system_instruction\":", joined.items);
}

fn write_input(writer: *std.Io.Writer, alloc: Allocator, request: stream_provider.RequestData, projection: *const tool_call_ids.Projection) !void {
    try writer.writeAll(",\"input\":[");
    var first = true;
    const verified = request.verified_images orelse &.{};
    const verified_at = if (verified.len != 0) function_tools.last_user_index(request.messages) else null;
    for (request.messages, 0..) |message, index| switch (message.role) {
        .user => try write_user(writer, alloc, &first, message, if (verified_at == index) verified else &.{}),
        .assistant => try write_assistant(writer, alloc, &first, message, projection),
        .tool => try write_tool_result(writer, &first, request.messages, index, projection),
        .system => return error.InvalidProviderPrompt,
    };
    try writer.writeByte(']');
}

fn write_user(
    writer: *std.Io.Writer,
    alloc: Allocator,
    first: *bool,
    message: types.ChatMessage,
    verified: []const image_attachments.VerifiedSnapshot,
) !void {
    const text = message.content orelse "";
    const has_images = message.images.len != 0 or verified.len != 0;
    try write_comma(writer, first);
    try writer.writeAll("{\"type\":\"user_input\",\"content\":[");
    var first_part = true;
    if (text.len != 0 or !has_images) {
        try write_comma(writer, &first_part);
        try write_text_block(writer, text);
    }
    for (message.images) |image| {
        var snapshot = image_attachments.loadVerifiedSnapshot(alloc, image, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ImageUnavailable,
        };
        defer snapshot.deinit(alloc);
        try write_comma(writer, &first_part);
        try write_image_block(writer, snapshot.media_type, snapshot.bytes);
    }
    for (verified) |snapshot| {
        try write_comma(writer, &first_part);
        try write_image_block(writer, snapshot.media_type, snapshot.bytes);
    }
    try writer.writeAll("]}");
}

fn write_assistant(
    writer: *std.Io.Writer,
    alloc: Allocator,
    first: *bool,
    message: types.ChatMessage,
    projection: *const tool_call_ids.Projection,
) !void {
    if (message.provider_replay) |replay| {
        var parsed = try parse_replay(alloc, replay.parts_json);
        defer parsed.deinit();
        for (parsed.value.array.items) |step| {
            try write_comma(writer, first);
            try std.json.Stringify.value(step, .{}, writer);
        }
    }
    if (non_empty(message.content)) |text| {
        try write_comma(writer, first);
        try writer.writeAll("{\"type\":\"model_output\",\"content\":[");
        try write_text_block(writer, text);
        try writer.writeAll("]}");
    }
    for (message.tool_calls) |call| {
        try write_comma(writer, first);
        try write_json_string(writer, "{\"type\":\"function_call\",\"id\":", projection.resolve(call.id));
        try write_json_string(writer, ",\"name\":", call.name);
        // validate_history proved the arguments are one JSON object.
        try writer.writeAll(",\"arguments\":");
        try writer.writeAll(call.arguments_json);
        try writer.writeByte('}');
    }
}

fn write_tool_result(
    writer: *std.Io.Writer,
    first: *bool,
    messages: []const types.ChatMessage,
    message_index: usize,
    projection: *const tool_call_ids.Projection,
) !void {
    const message = messages[message_index];
    const call_id = message.tool_call_id.?;
    const name = message.tool_name orelse resolve_tool_name(messages, message_index, call_id) orelse return error.InvalidToolHistory;
    const is_error = message.tool_result_status == .failure;
    try write_comma(writer, first);
    try write_json_string(writer, "{\"type\":\"function_result\",\"call_id\":", projection.resolve(call_id));
    try write_json_string(writer, ",\"name\":", name);
    try write_json_string(writer, ",\"result\":{\"content\":", message.content.?);
    try writer.writeAll("},\"is_error\":");
    try writer.writeAll(if (is_error) "true" else "false");
    try writer.writeByte('}');
}

fn resolve_tool_name(messages: []const types.ChatMessage, tool_index: usize, call_id: []const u8) ?[]const u8 {
    var index = tool_index;
    while (index > 0) {
        index -= 1;
        const message = messages[index];
        if (message.role == .tool) continue;
        if (message.role == .assistant) {
            for (message.tool_calls) |call| {
                if (std.mem.eql(u8, call.id, call_id)) return call.name;
            }
        }
        break;
    }
    return null;
}

fn write_comma(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
}

fn write_json_string(writer: *std.Io.Writer, prefix: []const u8, value: []const u8) !void {
    try writer.writeAll(prefix);
    try std.json.Stringify.value(value, .{}, writer);
}

fn write_text_block(writer: *std.Io.Writer, text: []const u8) !void {
    try write_json_string(writer, "{\"type\":\"text\",\"text\":", text);
    try writer.writeByte('}');
}

fn write_image_block(writer: *std.Io.Writer, media_type: []const u8, bytes: []const u8) !void {
    try write_json_string(writer, "{\"type\":\"image\",\"mime_type\":", media_type);
    try writer.writeAll(",\"data\":\"");
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 3 * 1024, bytes.len);
        try std.base64.standard.Encoder.encodeWriter(writer, bytes[offset..end]);
        offset = end;
    }
    try writer.writeAll("\"}");
}

fn non_empty(text: ?[]const u8) ?[]const u8 {
    const value = text orelse return null;
    return if (value.len == 0) null else value;
}

pub const Limits = struct {
    /// One event's data, and all wire between two dispatched events.
    event_bytes: usize = 1024 * 1024,
    total_wire_bytes: usize = 32 * 1024 * 1024,
    events: usize = 100_000,
    /// Steps of every type, known or not.
    steps: usize = 1024,
    tool_calls: usize = 128,
    identity_bytes: usize = 256,
    arguments_bytes: usize = 1024 * 1024,
    /// The reply's text.
    content_bytes: usize = 8 * 1024 * 1024,
    /// Thought summaries and signatures kept for replay.
    reasoning_bytes: usize = types.ProviderReplay.max_bytes,
};

/// What one event adds for presentation. Slices borrow reducer storage until
/// the next accept, finish, or deinit.
const Deltas = struct {
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    tool_started: ?struct { id: []const u8, name: []const u8 } = null,
    tool_input: ?[]const u8 = null,
};

const Step = struct {
    kind: enum { model_output, thought, function_call, ignored },
    /// The entry in `tools` or `thoughts` this step fills.
    slot: usize = 0,
    open: bool = true,
};

const Tool = struct {
    /// The id the call keeps in fx (`tool_call_ids.ReplyIds`).
    id: ?[]u8 = null,
    /// The id the server sent, when it sent one fx could read.
    source_id: ?[]u8 = null,
    name: ?[]u8 = null,
    arguments: std.ArrayList(u8) = .empty,
    /// The step's starting `arguments` as JSON, when it was not empty.
    start_input: ?[]u8 = null,
    argument_integrity: types.ToolArgumentIntegrity = .malformed_json,

    fn deinit(self: *Tool, alloc: Allocator) void {
        if (self.id) |id| alloc.free(id);
        if (self.source_id) |id| alloc.free(id);
        if (self.name) |name| alloc.free(name);
        self.arguments.deinit(alloc);
        if (self.start_input) |input| alloc.free(input);
    }

    fn current_arguments(self: *const Tool) []const u8 {
        if (self.arguments.items.len != 0) return self.arguments.items;
        if (self.start_input) |input| return input;
        return "{}";
    }

    /// Caller owns the result: the streamed input, else the input the step
    /// started with, else `{}`.
    fn take_arguments(self: *Tool, alloc: Allocator) Allocator.Error![]u8 {
        if (self.arguments.items.len != 0) return self.arguments.toOwnedSlice(alloc);
        if (self.start_input) |input| {
            self.start_input = null;
            return input;
        }
        return alloc.dupe(u8, "{}");
    }
};

const Thought = struct {
    summary: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
};

const Stop = struct {
    reason: types.ProviderFinishReason,
    raw: types.ProviderFinishRaw,
};

const Failure = struct {
    kind: stream_provider.FailureKind,
    /// Owned: the error event or failed interaction payload as sent.
    detail: []u8,
};

const Counts = struct {
    input: ?u64 = null,
    output: ?u64 = null,
    cache_read: ?u64 = null,
    reasoning: ?u64 = null,
};

/// Single-owner, request-local state machine. No I/O, callbacks, tool
/// execution, or hidden cancellation reads. Any accept or finish failure
/// poisons the reducer; deinit remains mandatory. A successful finish transfers
/// independent owned results.
const Reducer = struct {
    alloc: Allocator,
    limits: Limits,
    choice: types.ToolChoice,
    call_ids: tool_call_ids.ReplyIds,
    steps: std.ArrayList(Step) = .empty,
    tools: std.ArrayList(Tool) = .empty,
    thoughts: std.ArrayList(Thought) = .empty,
    content: std.ArrayList(u8) = .empty,
    generation_id: ?[]u8 = null,
    counts: Counts = .{},
    stop: ?Stop = null,
    failure: ?Failure = null,
    phase: enum { initial, streaming, completed, done, failed, closed } = .initial,
    event_count: usize = 0,
    json_bytes: usize = 0,
    reasoning_bytes: usize = 0,

    fn init(alloc: Allocator, request: stream_provider.RequestData, limits: Limits) Error!Reducer {
        try validate_request(request, true);
        return .{
            .alloc = alloc,
            .limits = limits,
            .choice = request.tool_choice,
            .call_ids = try tool_call_ids.ReplyIds.init(alloc, .{
                .messages = request.messages,
                .current_turn_messages = request.current_turn_messages,
            }),
        };
    }

    fn deinit(self: *Reducer) void {
        self.call_ids.deinit();
        self.steps.deinit(self.alloc);
        for (self.tools.items) |*tool| tool.deinit(self.alloc);
        self.tools.deinit(self.alloc);
        for (self.thoughts.items) |*part| {
            part.summary.deinit(self.alloc);
            part.signature.deinit(self.alloc);
        }
        self.thoughts.deinit(self.alloc);
        self.content.deinit(self.alloc);
        if (self.generation_id) |id| self.alloc.free(id);
        if (self.failure) |failure| self.alloc.free(failure.detail);
        self.* = undefined;
    }

    fn accept(self: *Reducer, data: []const u8, cancelled: bool) Error!Deltas {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        if (self.phase != .initial and self.phase != .streaming and self.phase != .completed) return error.StreamClosed;
        if (data.len > self.limits.event_bytes) return error.EventTooLarge;
        if (data.len > self.limits.total_wire_bytes - self.json_bytes) return error.StreamTooLarge;
        self.json_bytes += data.len;
        if (self.event_count == self.limits.events) return error.TooManyEvents;
        self.event_count += 1;
        if (std.mem.eql(u8, data, "[DONE]")) {
            if (self.phase != .completed) return error.IncompleteStream;
            self.phase = .done;
            return .{};
        }
        try check_json_depth(data);
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateField => return error.InvalidEvent,
            else => return error.MalformedInteractionsEvent,
        };
        defer parsed.deinit();
        const root = try object(parsed.value);
        const kind = try string(root.get("event_type") orelse return error.InvalidEvent);
        if (std.mem.eql(u8, kind, "error")) {
            try self.accept_error(data, root);
            return .{};
        }
        if (std.mem.eql(u8, kind, "interaction.created")) {
            try self.accept_interaction_created(root);
            return .{};
        }
        const stream_events = std.StaticStringMap(enum { step_start, step_delta, step_stop, interaction_completed }).initComptime(.{
            .{ "step.start", .step_start },
            .{ "step.delta", .step_delta },
            .{ "step.stop", .step_stop },
            .{ "interaction.completed", .interaction_completed },
        });
        const stream_event = stream_events.get(kind) orelse return .{};
        if (self.phase != .streaming) return error.InvalidEvent;
        switch (stream_event) {
            .step_start => return self.accept_step_start(root),
            .step_delta => return self.accept_step_delta(root),
            .step_stop => {
                try self.accept_step_stop(root);
                return .{};
            },
            .interaction_completed => {
                try self.accept_interaction_completed(data, root);
                return .{};
            },
        }
    }

    fn accept_interaction_created(self: *Reducer, root: std.json.ObjectMap) Error!void {
        if (self.phase != .initial) return error.InvalidEvent;
        const interaction = try object(root.get("interaction") orelse return error.InvalidEvent);
        try self.record_identity(interaction);
        self.phase = .streaming;
    }

    fn record_identity(self: *Reducer, interaction: std.json.ObjectMap) Error!void {
        const value = non_null(interaction, "id") orelse return;
        const id = try string(value);
        // An interaction sent with store:false is not kept, so Google sends an empty id.
        if (id.len == 0) return;
        if (id.len > self.limits.identity_bytes) return error.IdentityTooLarge;
        if (self.generation_id) |existing| {
            if (!std.mem.eql(u8, existing, id)) return error.ConflictingIdentity;
            return;
        }
        self.generation_id = try self.alloc.dupe(u8, id);
    }

    fn accept_step_start(self: *Reducer, root: std.json.ObjectMap) Error!Deltas {
        const index = try index_value(root.get("index") orelse return error.InvalidEvent);
        if (index != self.steps.items.len) return error.InvalidEvent;
        if (index == self.limits.steps) return error.TooManySteps;
        const step = try object(root.get("step") orelse return error.InvalidEvent);
        const kind = try string(step.get("type") orelse return error.InvalidEvent);
        try self.steps.ensureUnusedCapacity(self.alloc, 1);
        if (std.mem.eql(u8, kind, "model_output")) {
            self.steps.appendAssumeCapacity(.{ .kind = .model_output });
            return .{ .content = try self.append_step_text_parts(step, "content", &self.content, false) };
        }
        if (std.mem.eql(u8, kind, "function_call")) return self.start_tool(step);
        if (!std.mem.eql(u8, kind, "thought")) {
            self.steps.appendAssumeCapacity(.{ .kind = .ignored });
            return .{};
        }
        try self.thoughts.append(self.alloc, .{});
        self.steps.appendAssumeCapacity(.{ .kind = .thought, .slot = self.thoughts.items.len - 1 });
        const part = &self.thoughts.items[self.thoughts.items.len - 1];
        if (non_null(step, "signature")) |value| _ = try self.append_reasoning(&part.signature, try string(value));
        return .{ .reasoning = try self.append_step_text_parts(step, "summary", &part.summary, true) };
    }

    fn append_step_text_parts(
        self: *Reducer,
        step: std.json.ObjectMap,
        key: []const u8,
        destination: *std.ArrayList(u8),
        reasoning: bool,
    ) Error!?[]const u8 {
        const value = non_null(step, key) orelse return null;
        if (value != .array) return error.InvalidEvent;
        const start = destination.items.len;
        for (value.array.items) |item| {
            const fields = try object(item);
            const item_type = try string(fields.get("type") orelse return error.InvalidEvent);
            if (!std.mem.eql(u8, item_type, "text")) continue;
            const text = try string(fields.get("text") orelse return error.InvalidEvent);
            _ = if (reasoning) try self.append_reasoning(destination, text) else try self.append_text(text);
        }
        return if (destination.items.len == start) null else destination.items[start..];
    }

    fn start_tool(self: *Reducer, step: std.json.ObjectMap) Error!Deltas {
        const source_id = try self.tool_source_id(non_null(step, "id"));
        const name = try string(step.get("name") orelse return error.InvalidEvent);
        if (name.len > @min(function_tools.max_name_bytes, self.limits.identity_bytes)) return error.IdentityTooLarge;
        if (self.choice == .none) return error.UnexpectedToolCall;
        if (self.tools.items.len == self.limits.tool_calls) return error.TooManyTools;
        var tool: Tool = .{};
        errdefer tool.deinit(self.alloc);
        tool.id = try self.alloc.dupe(u8, try self.call_ids.assign(source_id));
        if (source_id) |id| tool.source_id = try self.alloc.dupe(u8, id);
        tool.name = try self.alloc.dupe(u8, name);
        if (non_null(step, "arguments")) |args| {
            if (args != .object) return error.InvalidEvent;
            if (args.object.keys().len != 0) {
                const encoded = try std.json.Stringify.valueAlloc(self.alloc, args, .{});
                tool.start_input = encoded;
                if (encoded.len > self.limits.arguments_bytes) return error.ArgumentsTooLarge;
            }
        }
        try self.tools.ensureUnusedCapacity(self.alloc, 1);
        self.steps.appendAssumeCapacity(.{ .kind = .function_call, .slot = self.tools.items.len });
        self.tools.appendAssumeCapacity(tool);
        const stored = &self.tools.items[self.tools.items.len - 1];
        return .{ .tool_started = .{ .id = stored.id.?, .name = stored.name.? } };
    }

    fn tool_source_id(self: *const Reducer, value: ?std.json.Value) Error!?[]const u8 {
        const text = try string(value orelse return null);
        if (text.len == 0 or text.len > self.limits.identity_bytes) return null;
        return text;
    }

    fn restore_sent_again(self: *Reducer, tool: *Tool, arguments: []const u8) Error!?[]u8 {
        const source = tool.source_id orelse return null;
        const started = tool.id.?;
        if (std.mem.eql(u8, source, started)) return null;
        if (!try self.call_ids.sameCallAgain(source, tool.name.?, arguments)) return null;
        tool.id = source;
        tool.source_id = null;
        return started;
    }

    fn accept_step_delta(self: *Reducer, root: std.json.ObjectMap) Error!Deltas {
        const step = (try self.open_step(root)).*;
        const delta = try object(root.get("delta") orelse return error.InvalidEvent);
        const kind = try string(delta.get("type") orelse return error.InvalidEvent);
        const DeltaKind = enum { text, thought_summary, thought_signature, arguments_delta };
        const delta_kinds = std.StaticStringMap(DeltaKind).initComptime(.{
            .{ "text", .text },
            .{ "thought_summary", .thought_summary },
            .{ "thought_signature", .thought_signature },
            .{ "arguments_delta", .arguments_delta },
        });
        const delta_kind = delta_kinds.get(kind) orelse return .{};
        if (step.kind == .ignored) return .{};
        switch (delta_kind) {
            .text => {
                if (step.kind != .model_output) return error.InvalidEvent;
                return .{ .content = try self.append_text(try string(delta.get("text") orelse return error.InvalidEvent)) };
            },
            .arguments_delta => {
                if (step.kind != .function_call) return error.InvalidEvent;
                const tool = &self.tools.items[step.slot];
                const partial = try string(delta.get("arguments") orelse return error.InvalidEvent);
                const start = tool.arguments.items.len;
                try append_bounded(self.alloc, &tool.arguments, partial, self.limits.arguments_bytes, error.ArgumentsTooLarge);
                return .{ .tool_input = if (partial.len == 0) null else tool.arguments.items[start..] };
            },
            .thought_signature => {
                if (step.kind != .thought) return error.InvalidEvent;
                const part = &self.thoughts.items[step.slot];
                _ = try self.append_reasoning(&part.signature, try string(delta.get("signature") orelse return error.InvalidEvent));
                return .{};
            },
            .thought_summary => {
                if (step.kind != .thought) return error.InvalidEvent;
                const part = &self.thoughts.items[step.slot];
                const summary_content = try object(delta.get("content") orelse return error.InvalidEvent);
                const content_type = try string(summary_content.get("type") orelse return error.InvalidEvent);
                if (!std.mem.eql(u8, content_type, "text")) return .{};
                return .{ .reasoning = try self.append_reasoning(&part.summary, try string(summary_content.get("text") orelse return error.InvalidEvent)) };
            },
        }
    }

    fn accept_step_stop(self: *Reducer, root: std.json.ObjectMap) Error!void {
        const step = try self.open_step(root);
        step.open = false;
        if (step.kind == .function_call) {
            const tool = &self.tools.items[step.slot];
            const args = tool.current_arguments();
            try check_json_depth(args);
            tool.argument_integrity = try types.ToolArgumentIntegrity.classifyFunctionInput(self.alloc, args);
        }
        if (non_null(root, "usage")) |usage| try self.accept_usage(usage);
    }

    fn open_step(self: *Reducer, root: std.json.ObjectMap) Error!*Step {
        const index = try index_value(root.get("index") orelse return error.InvalidEvent);
        if (index >= self.steps.items.len or !self.steps.items[index].open) return error.InvalidEvent;
        return &self.steps.items[index];
    }

    fn append_text(self: *Reducer, text: []const u8) Error!?[]const u8 {
        const start = self.content.items.len;
        try append_bounded(self.alloc, &self.content, text, self.limits.content_bytes, error.ContentTooLarge);
        if (text.len == 0) return null;
        return self.content.items[start..];
    }

    fn append_reasoning(self: *Reducer, destination: *std.ArrayList(u8), text: []const u8) Error!?[]const u8 {
        const limit = @min(self.limits.reasoning_bytes, types.ProviderReplay.max_bytes);
        if (text.len > limit - self.reasoning_bytes) return error.ReplayTooLarge;
        self.reasoning_bytes += text.len;
        const start = destination.items.len;
        try destination.appendSlice(self.alloc, text);
        return if (text.len == 0) null else destination.items[start..];
    }

    fn accept_interaction_completed(self: *Reducer, data: []const u8, root: std.json.ObjectMap) Error!void {
        const interaction = try object(root.get("interaction") orelse return error.InvalidEvent);
        try self.record_identity(interaction);
        if (non_null(interaction, "usage")) |usage| try self.accept_usage(usage);
        const status = try string(interaction.get("status") orelse return error.InvalidEvent);
        if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "cancelled")) {
            try self.set_failure(.provider_error, data);
            return;
        }
        const finish_reasons = std.StaticStringMap(types.ProviderFinishReason).initComptime(.{
            .{ "completed", .stop },
            .{ "requires_action", .tool_calls },
            .{ "incomplete", .length },
        });
        const reason = finish_reasons.get(status) orelse return error.InvalidFinishReason;
        if (self.stop != null) return error.InconsistentFinishReason;
        self.stop = .{ .reason = reason, .raw = .init(status) };
        self.phase = .completed;
    }

    fn accept_usage(self: *Reducer, value: std.json.Value) Error!void {
        const fields = try object(value);
        if (try token_count(fields, "total_input_tokens")) |count| self.counts.input = count;
        if (try token_count(fields, "total_output_tokens")) |count| self.counts.output = count;
        if (detail_count(fields, "total_cached_tokens")) |count| self.counts.cache_read = count;
        if (detail_count(fields, "total_thought_tokens")) |count| self.counts.reasoning = count;
    }

    fn accept_error(self: *Reducer, data: []const u8, root: std.json.ObjectMap) Error!void {
        const kind = if (error_code(root)) |code| failure_kind(code) else .provider_error;
        try self.set_failure(kind, data);
    }

    fn set_failure(self: *Reducer, kind: stream_provider.FailureKind, data: []const u8) Allocator.Error!void {
        const detail = try self.alloc.dupe(u8, if (data.len > max_error_detail_bytes) "Provider error details exceeded the local limit" else data);
        self.failure = .{ .kind = kind, .detail = detail };
        self.phase = .failed;
    }

    fn final_usage(self: *const Reducer) types.Usage {
        return .{
            .input_tokens = self.counts.input,
            .output_tokens = self.counts.output,
            .cache_read_tokens = self.counts.cache_read,
            .reasoning_tokens = self.counts.reasoning,
        };
    }

    /// Caller owns the replay state: the reply's thought steps in order, as
    /// `write_assistant` sends them back.
    fn provider_state(self: *const Reducer) Error!?[]u8 {
        if (self.thoughts.items.len == 0) return null;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        write_provider_state(&out.writer, self.thoughts.items) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
        if (out.written().len > @min(self.limits.reasoning_bytes, types.ProviderReplay.max_bytes)) return error.ReplayTooLarge;
        return try out.toOwnedSlice();
    }

    fn write_provider_state(writer: *std.Io.Writer, thoughts: []const Thought) !void {
        try writer.writeByte('[');
        for (thoughts, 0..) |part, index| {
            if (index != 0) try writer.writeByte(',');
            try write_json_string(writer, "{\"type\":\"thought\",\"signature\":", part.signature.items);
            try writer.writeAll(",\"summary\":[");
            if (part.summary.items.len != 0) try write_text_block(writer, part.summary.items);
            try writer.writeAll("]}");
        }
        try writer.writeByte(']');
    }

    /// Requires `interaction.completed`, or returns the failure an `error`
    /// event or `status: "failed"` reported. Results use
    /// `stream_provider.Result.deinit` with this reducer's allocator.
    fn finish(self: *Reducer, cancelled: bool) Error!stream_provider.Result {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        switch (self.phase) {
            .closed => return error.StreamClosed,
            .failed => {
                const failure = self.failure.?;
                self.failure = null;
                self.phase = .closed;
                return .{ .failed = .{ .kind = failure.kind, .detail = failure.detail, .ownership = .owned } };
            },
            .completed, .done => {},
            .initial, .streaming => return error.IncompleteStream,
        }
        const stop = self.stop orelse return error.InvalidFinishReason;
        const reason = stop.reason;
        if (reason == .stop or reason == .tool_calls) {
            if ((reason == .tool_calls) != (self.tools.items.len != 0)) return error.InconsistentFinishReason;
            if (self.choice == .required and self.tools.items.len == 0) return error.RequiredToolMissing;
        }
        for (self.tools.items) |tool| {
            try function_tools.validate_name(tool.name.?);
            try check_json_depth(tool.current_arguments());
        }
        const state = try self.provider_state();
        errdefer if (state) |bytes| self.alloc.free(bytes);
        var content: ?[]u8 = null;
        errdefer if (content) |text| self.alloc.free(text);
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| types.freeToolCall(self.alloc, call);
            calls.deinit(self.alloc);
        }
        try calls.ensureTotalCapacityPrecise(self.alloc, self.tools.items.len);
        for (self.tools.items) |*tool| {
            const arguments = try tool.take_arguments(self.alloc);
            errdefer self.alloc.free(arguments);
            const provisional_id = try self.restore_sent_again(tool, arguments);
            calls.appendAssumeCapacity(.{
                .id = tool.id.?,
                .name = tool.name.?,
                .arguments_json = arguments,
                .argument_integrity = tool.argument_integrity,
                .provisional_id = provisional_id,
            });
            tool.id = null;
            tool.name = null;
        }
        if (self.content.items.len != 0) content = try self.content.toOwnedSlice(self.alloc);
        const owned_calls = try calls.toOwnedSlice(self.alloc);
        const generation_id = self.generation_id;
        self.generation_id = null;
        self.phase = .closed;
        return .{ .completed = .{
            .completion = .{
                .content = content,
                .tool_calls = owned_calls,
                .generation_id = generation_id,
                .finish_reason = reason,
                .finish_reason_raw = stop.raw,
                .usage = self.final_usage(),
                .provider_state_json = state,
            },
            .ownership = .owned,
        } };
    }
};

fn error_code(root: std.json.ObjectMap) ?[]const u8 {
    const value = non_null(root, "error") orelse return null;
    if (value != .object) return null;
    const code = non_null(value.object, "code") orelse return null;
    return if (code == .string) code.string else null;
}

fn failure_kind(code: []const u8) stream_provider.FailureKind {
    const kinds = std.StaticStringMap(stream_provider.FailureKind).initComptime(.{
        .{ "invalid_request", .invalid_request },
        .{ "invalid_argument", .invalid_request },
        .{ "unauthenticated", .unauthorized },
        .{ "unauthorized", .unauthorized },
        .{ "permission_denied", .forbidden },
        .{ "forbidden", .forbidden },
        .{ "request_too_large", .request_too_large },
        .{ "payload_too_large", .request_too_large },
        .{ "rate_limit_exceeded", .rate_limited },
        .{ "resource_exhausted", .rate_limited },
        .{ "too_many_requests", .rate_limited },
        .{ "internal_error", .server_error },
        .{ "internal", .server_error },
        .{ "server_error", .server_error },
        .{ "bad_gateway", .bad_gateway },
        .{ "service_unavailable", .unavailable },
        .{ "unavailable", .unavailable },
        .{ "overloaded", .unavailable },
        .{ "gateway_timeout", .gateway_timeout },
        .{ "deadline_exceeded", .gateway_timeout },
    });
    return kinds.get(code) orelse .provider_error;
}

fn object(value: std.json.Value) Error!std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidEvent;
}

fn string(value: std.json.Value) Error![]const u8 {
    return if (value == .string) value.string else error.InvalidEvent;
}

fn non_null(fields: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const value = fields.get(key) orelse return null;
    return if (value == .null) null else value;
}

fn integer(value: std.json.Value) Error!i64 {
    return switch (value) {
        .integer => value.integer,
        .number_string => std.fmt.parseInt(i64, value.number_string, 10) catch error.InvalidEvent,
        else => error.InvalidEvent,
    };
}

fn index_value(value: std.json.Value) Error!usize {
    return std.math.cast(usize, try integer(value)) orelse error.InvalidEvent;
}

fn token_count(fields: std.json.ObjectMap, key: []const u8) Error!?u64 {
    const value = non_null(fields, key) orelse return null;
    return std.math.cast(u64, try integer(value)) orelse error.InvalidEvent;
}

fn detail_count(fields: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = non_null(fields, key) orelse return null;
    return std.math.cast(u64, integer(value) catch return null);
}

fn append_bounded(alloc: Allocator, destination: *std.ArrayList(u8), text: []const u8, limit: usize, failure: Error) Error!void {
    if (text.len > limit - destination.items.len) return failure;
    try destination.appendSlice(alloc, text);
}

fn emit(sink: stream_provider.EventSink, deltas: Deltas, cancel_flag: *const std.atomic.Value(bool)) Error!void {
    if (deltas.tool_started) |tool| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        sink.emit(.{ .tool_started = .{ .id = tool.id, .name = tool.name } });
    }
    if (deltas.reasoning) |text| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        sink.emit(.{ .reasoning_delta = text });
    }
    if (deltas.content) |text| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        sink.emit(.{ .content_delta = text });
    }
    if (deltas.tool_input) |text| {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        sink.emit(.{ .tool_input_delta = text });
    }
}

/// Thin stream consumer, not a network transport. The source owns blocking-I/O
/// cancellation. EventSink receives synchronous presentation-only text. Stops
/// at `data: [DONE]` (or EOF after `interaction.completed`) or an `error` event /
/// `status: "failed"`. `event_bytes` bounds each event and all wire between two
/// dispatched events (including `event:` lines and `: keep-alive` comments);
/// `total_wire_bytes` bounds the entire consumed stream.
pub fn consume_stream(
    alloc: Allocator,
    source: *std.Io.Reader,
    request: stream_provider.RequestData,
    limits: Limits,
    events: ?stream_provider.EventSink,
    cancel_flag: *const std.atomic.Value(bool),
    progress: ?sse.Progress,
) Error!stream_provider.Result {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var reducer = try Reducer.init(alloc, request, limits);
    defer reducer.deinit();
    var framing = sse.Reader{ .max_event_bytes = limits.event_bytes, .progress = progress };
    defer framing.deinit(alloc);
    while (true) {
        const remaining = limits.total_wire_bytes - framing.total_bytes;
        const event_limited = limits.event_bytes < remaining;
        framing.max_total_bytes = framing.total_bytes + @min(limits.event_bytes, remaining);
        const data = framing.next(alloc, source, cancel_flag) catch |err| switch (err) {
            error.StreamTooLarge => return if (event_limited) error.EventTooLarge else error.StreamTooLarge,
            else => return err,
        };
        const chunk = data orelse {
            if (reducer.phase == .completed) return reducer.finish(cancel_flag.load(.seq_cst));
            return error.IncompleteStream;
        };
        const deltas = try reducer.accept(chunk, cancel_flag.load(.seq_cst));
        if (events) |sink| try emit(sink, deltas, cancel_flag);
        if (reducer.phase == .done or reducer.phase == .failed) return reducer.finish(cancel_flag.load(.seq_cst));
    }
}

// Tests.

fn sse_wire(comptime events: []const []const u8) []const u8 {
    comptime var wire: []const u8 = "";
    inline for (events) |event| wire = wire ++ "data: " ++ event ++ "\n\n";
    return wire;
}

/// Caller owns the result.
fn test_wire(alloc: Allocator, events: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (events) |event| try out.print(alloc, "data: {s}\n\n", .{event});
    return out.toOwnedSlice(alloc);
}

const test_created =
    \\{"event_type":"interaction.created","interaction":{"id":"int_1","status":"in_progress","object":"interaction","model":"gemini-4-hydrogen"}}
;
const test_text_start =
    \\{"event_type":"step.start","index":0,"step":{"type":"model_output"}}
;
const test_text_delta =
    \\{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"hello"}}
;
const test_stop_0 =
    \\{"event_type":"step.stop","index":0}
;
const test_completed =
    \\{"event_type":"interaction.completed","interaction":{"id":"int_1","status":"completed","usage":{"total_input_tokens":11,"total_cached_tokens":4,"total_output_tokens":7,"total_thought_tokens":20,"total_tokens":38}}}
;
const test_done = "[DONE]";

const test_functions = [_]model_tool_schema.FunctionSchema{
    .{ .name = "read_file", .description = "Read a file.", .input_schema = .{
        .properties = &.{.{ .name = "path", .json_type = .string }},
        .required = &.{"path"},
        .additional_properties = false,
    } },
    .{ .name = "shell", .description = "Run a command.", .input_schema = .{
        .properties = &.{.{ .name = "request", .json_type = .object, .shape = &.{ .object = &.{
            .properties = &.{.{ .name = "command", .json_type = .string }},
            .required = &.{"command"},
        } } }},
    } },
};

fn test_request() stream_provider.RequestData {
    return .{
        .model = "gemini-4-hydrogen",
        .instructions = &.{},
        .messages = &.{.{ .role = .user, .content = "hi" }},
        .tool_choice = .auto,
        .provider_options = .{},
    };
}

fn test_tool_request() stream_provider.RequestData {
    var request = test_request();
    request.tools = .{ .advertised_names = &.{ "read_file", "shell" }, .advertised_functions = &test_functions };
    return request;
}

fn test_consume(alloc: Allocator, wire: []const u8, request: stream_provider.RequestData, events: ?stream_provider.EventSink) Error!stream_provider.Result {
    var source = std.Io.Reader.fixed(wire);
    const cancelled = std.atomic.Value(bool).init(false);
    return consume_stream(alloc, &source, request, .{}, events, &cancelled, null);
}

fn test_accept(reducer: *Reducer, data: []const u8) Error!void {
    _ = try reducer.accept(data, false);
}

const Recorder = struct {
    alloc: Allocator,
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_input: std.ArrayList(u8) = .empty,
    started: std.ArrayList(u8) = .empty,
    failed: bool = false,

    fn sink(self: *Recorder) stream_provider.EventSink {
        return .{ .context = self, .emit_fn = emit_event };
    }

    fn emit_event(context: *anyopaque, event: stream_provider.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(context));
        self.record(event) catch {
            self.failed = true;
        };
    }

    fn record(self: *Recorder, event: stream_provider.Event) !void {
        switch (event) {
            .content_delta => |text| try self.content.appendSlice(self.alloc, text),
            .reasoning_delta => |text| try self.reasoning.appendSlice(self.alloc, text),
            .tool_input_delta => |text| try self.tool_input.appendSlice(self.alloc, text),
            .tool_started => |tool| try self.started.print(self.alloc, "{s}:{s};", .{ tool.id, tool.name }),
            .tool_input_progress => {},
        }
    }

    fn deinit(self: *Recorder) void {
        self.content.deinit(self.alloc);
        self.reasoning.deinit(self.alloc);
        self.tool_input.deinit(self.alloc);
        self.started.deinit(self.alloc);
    }
};

fn expect_keys(fields: std.json.ObjectMap, expected: []const []const u8) !void {
    const keys = fields.keys();
    try std.testing.expectEqual(expected.len, keys.len);
    for (expected, keys) |key, actual| try std.testing.expectEqualStrings(key, actual);
}

const ParsedBody = struct {
    alloc: Allocator,
    bytes: []u8,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *ParsedBody) void {
        self.parsed.deinit();
        self.alloc.free(self.bytes);
    }
};

fn build_parsed(alloc: Allocator, request: stream_provider.RequestData, options: Options) !ParsedBody {
    const bytes = try build_request(alloc, request, options);
    errdefer alloc.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{ .duplicate_field_behavior = .@"error" });
    return .{ .alloc = alloc, .bytes = bytes, .parsed = parsed };
}

test "gemini interactions exact body for a plain user message" {
    const alloc = std.testing.allocator;
    const body = try build_request(alloc, test_request(), .{ .provider = .google });
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        \\{"model":"gemini-4-hydrogen","store":false,"stream":true,"input":[{"type":"user_input","content":[{"type":"text","text":"hi"}]}],"generation_config":{"thinking_summaries":"auto"}}
    , body);
}

test "gemini interactions joins system instructions and omits when empty" {
    const alloc = std.testing.allocator;
    var request = test_request();
    request.instructions = &.{
        .{ .role = .system, .content = "first" },
        .{ .role = .system, .content = "" },
        .{ .role = .system, .content = "second" },
    };
    var body = try build_parsed(alloc, request, .{ .provider = .google });
    defer body.deinit();
    try std.testing.expectEqualStrings("first\n\nsecond", body.parsed.value.object.get("system_instruction").?.string);

    request.instructions = &.{.{ .role = .system, .content = "" }};
    const empty_body = try build_request(alloc, request, .{ .provider = .google });
    defer alloc.free(empty_body);
    try std.testing.expect(std.mem.find(u8, empty_body, "system_instruction") == null);
}

test "gemini interactions writes tools and tool_choice inside generation_config" {
    const alloc = std.testing.allocator;
    for ([_]struct { choice: types.ToolChoice, expected_tools: bool, expected_wire: ?[]const u8 }{
        .{ .choice = .auto, .expected_tools = true, .expected_wire = "auto" },
        .{ .choice = .required, .expected_tools = true, .expected_wire = "any" },
        .{ .choice = .none, .expected_tools = false, .expected_wire = null },
    }) |case| {
        var request = test_tool_request();
        request.tool_choice = case.choice;
        var body = try build_parsed(alloc, request, .{ .provider = .google });
        defer body.deinit();
        const root = body.parsed.value.object;
        try std.testing.expect(root.get("tool_choice") == null);
        if (case.expected_tools) {
            const tools = root.get("tools").?.array.items;
            try std.testing.expectEqual(@as(usize, 2), tools.len);
            try expect_keys(tools[0].object, &.{ "type", "name", "description", "parameters" });
            try std.testing.expectEqualStrings("function", tools[0].object.get("type").?.string);
            try std.testing.expectEqualStrings("read_file", tools[0].object.get("name").?.string);
            try std.testing.expectEqualStrings("object", tools[0].object.get("parameters").?.object.get("type").?.string);
            const cfg = root.get("generation_config").?.object;
            try std.testing.expectEqualStrings(case.expected_wire.?, cfg.get("tool_choice").?.string);
        } else {
            try std.testing.expect(root.get("tools") == null);
            try std.testing.expect(root.get("generation_config").?.object.get("tool_choice") == null);
        }
    }
    var missing = test_request();
    missing.tool_choice = .required;
    try std.testing.expectError(error.RequiredToolMissing, build_request(alloc, missing, .{ .provider = .google }));
}

test "gemini interactions serializes replay thoughts, model_output, function_call, and function_result in order" {
    const alloc = std.testing.allocator;
    const provider: model_provider.ProviderId = .google;
    const thought_state = "[{\"type\":\"thought\",\"signature\":\"sig-1\",\"summary\":[{\"type\":\"text\",\"text\":\"Inspecting files.\"}]}]";
    var request = test_tool_request();
    request.messages = &.{
        .{ .role = .user, .content = "read a and run pwd" },
        .{
            .role = .assistant,
            .content = "Reading.",
            .provider_replay = .{ .source = .{ .provider = provider, .model = request.model }, .parts_json = thought_state },
            .tool_calls = &.{
                .{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"a\"}" },
                .{ .id = "functions/shell:0", .name = "shell", .arguments_json = "{\"request\":{\"command\":\"pwd\"}}" },
            },
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "file text", .tool_result_status = .success },
        .{ .role = .tool, .tool_call_id = "functions/shell:0", .content = "boom", .tool_result_status = .failure },
    };
    var body = try build_parsed(alloc, request, .{ .provider = provider });
    defer body.deinit();
    const steps = body.parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 7), steps.len);

    try std.testing.expectEqualStrings("user_input", steps[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("thought", steps[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("sig-1", steps[1].object.get("signature").?.string);
    try std.testing.expectEqualStrings("Inspecting files.", steps[1].object.get("summary").?.array.items[0].object.get("text").?.string);

    try std.testing.expectEqualStrings("model_output", steps[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("Reading.", steps[2].object.get("content").?.array.items[0].object.get("text").?.string);

    try std.testing.expectEqualStrings("function_call", steps[3].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", steps[3].object.get("id").?.string);
    try std.testing.expectEqualStrings("read_file", steps[3].object.get("name").?.string);
    try std.testing.expectEqualStrings("a", steps[3].object.get("arguments").?.object.get("path").?.string);

    try std.testing.expectEqualStrings("function_call", steps[4].object.get("type").?.string);
    try std.testing.expectEqualStrings("functions/shell:0", steps[4].object.get("id").?.string);
    try std.testing.expectEqualStrings("shell", steps[4].object.get("name").?.string);
    try std.testing.expectEqualStrings("pwd", steps[4].object.get("arguments").?.object.get("request").?.object.get("command").?.string);

    try std.testing.expectEqualStrings("function_result", steps[5].object.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", steps[5].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("read_file", steps[5].object.get("name").?.string);
    try std.testing.expectEqualStrings("file text", steps[5].object.get("result").?.object.get("content").?.string);
    try std.testing.expect(!steps[5].object.get("is_error").?.bool);

    try std.testing.expectEqualStrings("function_result", steps[6].object.get("type").?.string);
    try std.testing.expectEqualStrings("functions/shell:0", steps[6].object.get("call_id").?.string);
    try std.testing.expectEqualStrings("shell", steps[6].object.get("name").?.string);
    try std.testing.expectEqualStrings("boom", steps[6].object.get("result").?.object.get("content").?.string);
    try std.testing.expect(steps[6].object.get("is_error").?.bool);
}

test "gemini interactions serializes user images and verified snapshots" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
    const png = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(png_b64));
    defer alloc.free(png);
    try std.base64.standard.Decoder.decode(png, png_b64);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pixel.png", .data = png });
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const abs = try io_mod.dirRealpathAlloc(arena, tmp.dir, "pixel.png");
    var attachment: types.ImageAttachment = .{
        .id = 1,
        .path = try arena.dupe(u8, abs),
        .media_type = try arena.dupe(u8, "image/png"),
    };
    try image_attachments.captureImageSnapshot(arena, &attachment, std.Io.Dir.path.dirname(abs).?);

    var request = test_request();
    request.messages = &.{.{ .role = .user, .content = "describe", .images = &.{attachment} }};
    var body = try build_parsed(alloc, request, .{ .provider = .google });
    defer body.deinit();
    const content = body.parsed.value.object.get("input").?.array.items[0].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), content.len);
    try std.testing.expectEqualStrings("text", content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("describe", content[0].object.get("text").?.string);
    try expect_keys(content[1].object, &.{ "type", "mime_type", "data" });
    try std.testing.expectEqualStrings("image", content[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("image/png", content[1].object.get("mime_type").?.string);
    try std.testing.expectEqualStrings(png_b64, content[1].object.get("data").?.string);
}

test "gemini interactions writes thinking_level and thinking_summaries in generation_config" {
    const alloc = std.testing.allocator;
    for ([_]ThinkingLevel{ .minimal, .low, .medium, .high, .xhigh }) |level| {
        var body = try build_parsed(alloc, test_request(), .{ .provider = .google, .thinking_level = level });
        defer body.deinit();
        const cfg = body.parsed.value.object.get("generation_config").?.object;
        try std.testing.expectEqualStrings(@tagName(level), cfg.get("thinking_level").?.string);
        try std.testing.expectEqualStrings("auto", cfg.get("thinking_summaries").?.string);
    }
    var unset_body = try build_parsed(alloc, test_request(), .{ .provider = .google });
    defer unset_body.deinit();
    const cfg = unset_body.parsed.value.object.get("generation_config").?.object;
    try std.testing.expect(cfg.get("thinking_level") == null);
    try std.testing.expectEqualStrings("auto", cfg.get("thinking_summaries").?.string);
}

test "gemini interactions writes response_format as TextResponseFormat" {
    const alloc = std.testing.allocator;
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}},\"required\":[\"ok\"]}", .{});
    defer schema.deinit();
    var pixels = [_]u8{ 1, 2, 3 };
    const snapshots = [_]image_attachments.VerifiedSnapshot{.{ .bytes = &pixels, .media_type = "image/png" }};
    var request = test_request();
    request.response_format = .{ .name = "answer", .description = "Answer schema", .schema = schema.value };
    request.verified_images = &snapshots;
    var body = try build_parsed(alloc, request, .{ .provider = .google });
    defer body.deinit();
    const root = body.parsed.value.object;
    const format = root.get("response_format").?.object;
    try expect_keys(format, &.{ "type", "mime_type", "schema" });
    try std.testing.expectEqualStrings("text", format.get("type").?.string);
    try std.testing.expectEqualStrings("application/json", format.get("mime_type").?.string);
    try std.testing.expectEqualStrings("boolean", format.get("schema").?.object.get("properties").?.object.get("ok").?.object.get("type").?.string);
    const parts = root.get("input").?.array.items[0].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("AQID", parts[1].object.get("data").?.string);

    request.response_format = .{ .name = "bad", .description = "", .schema = .null };
    try std.testing.expectError(error.UnsupportedResponseFormat, build_request(alloc, request, .{ .provider = .google }));
}

test "gemini interactions always sends store false and never sends temperature or disallowed fields" {
    const alloc = std.testing.allocator;
    var body = try build_parsed(alloc, test_request(), .{ .provider = .google, .thinking_level = .high });
    defer body.deinit();
    const root = body.parsed.value.object;
    try std.testing.expect(!root.get("store").?.bool);
    try std.testing.expect(root.get("stream").?.bool);
    for ([_][]const u8{ "temperature", "top_p", "previous_interaction_id", "background" }) |forbidden| {
        try std.testing.expect(std.mem.find(u8, body.bytes, forbidden) == null);
    }
    try std.testing.expect(root.get("generation_config").?.object.get("max_output_tokens") == null);

    var capped = test_request();
    capped.max_output_tokens = 65536;
    var capped_body = try build_parsed(alloc, capped, .{ .provider = .google });
    defer capped_body.deinit();
    try std.testing.expectEqual(@as(i64, 65536), capped_body.parsed.value.object.get("generation_config").?.object.get("max_output_tokens").?.integer);

    capped.max_output_tokens = 0;
    try std.testing.expectError(error.InvalidOutputLimit, build_request(alloc, capped, .{ .provider = .google }));
}

test "gemini interactions parse_replay rejects non-array, missing signature, and unknown type" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "{}",
        "123",
        "\"text\"",
        "[]",
        "[{\"type\":\"thought\",\"summary\":[]}]",
        "[{\"type\":\"thinking\",\"signature\":\"sig\"}]",
        "[{\"type\":\"thought\",\"signature\":123}]",
        "[{\"type\":\"thought\",\"signature\":\"sig\",\"extra\":1}]",
        "[{\"type\":\"thought\",\"signature\":\"sig\",\"summary\":[{\"type\":\"image\",\"data\":\"x\"}]}]",
    }) |raw| {
        try std.testing.expectError(error.InvalidProviderState, parse_replay(alloc, raw));
    }
    const valid = "[{\"type\":\"thought\",\"signature\":\"sig-1\",\"summary\":[{\"type\":\"text\",\"text\":\"ok\"}]}]";
    const replay: types.ProviderReplay = .{ .source = .{ .provider = .google, .model = "gemini-4-hydrogen" }, .parts_json = valid };
    try std.testing.expect((try project_replay(alloc, replay, &.{}, false, false)).?.parts_json.ptr == valid.ptr);
    try std.testing.expect((try project_replay(alloc, replay, &.{}, true, true)).?.parts_json.ptr == valid.ptr);
    try std.testing.expect(try project_replay(alloc, null, &.{}, true, true) == null);
}

test "gemini interactions consume_stream streams text deltas and maps usage" {
    const alloc = std.testing.allocator;
    const wire = sse_wire(&.{
        test_created,
        test_text_start,
        \\{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"Hel"}}
        ,
        \\{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"lo!"}}
        ,
        test_stop_0,
        test_completed,
        test_done,
    });
    for ([_]usize{ 1, 3, 17, 1024 }) |size| {
        const buffer = try alloc.alloc(u8, size);
        defer alloc.free(buffer);
        var fixed = std.Io.Reader.fixed(wire);
        var source = fixed.limited(.unlimited, buffer);
        var recorder: Recorder = .{ .alloc = alloc };
        defer recorder.deinit();
        const cancelled = std.atomic.Value(bool).init(false);
        var result = try consume_stream(alloc, &source.interface, test_request(), .{}, recorder.sink(), &cancelled, null);
        defer result.deinit(alloc);
        const completion = result.completed.completion;
        try std.testing.expectEqualStrings("Hello!", completion.content.?);
        try std.testing.expectEqualStrings("Hello!", recorder.content.items);
        try std.testing.expectEqualStrings("int_1", completion.generation_id.?);
        try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
        try std.testing.expectEqualStrings("completed", completion.finish_reason_raw.slice());
        try std.testing.expect(completion.provider_state_json == null);
        try std.testing.expectEqual(@as(?u64, 11), completion.usage.input_tokens);
        try std.testing.expectEqual(@as(?u64, 7), completion.usage.output_tokens);
        try std.testing.expectEqual(@as(?u64, 4), completion.usage.cache_read_tokens);
        try std.testing.expectEqual(@as(?u64, null), completion.usage.cache_write_tokens);
        try std.testing.expectEqual(@as(?u64, 20), completion.usage.reasoning_tokens);
    }
}

test "gemini interactions consume_stream accepts the empty id of an interaction Google does not store" {
    const alloc = std.testing.allocator;
    // The first event Google sent for a store:false request on the plan route.
    const wire = sse_wire(&.{
        \\{"interaction":{"id":"","status":"in_progress","object":"interaction","model":"gemini-4-hydrogen"},"event_type":"interaction.created"}
        ,
        test_text_start,
        test_text_delta,
        test_stop_0,
        \\{"event_type":"interaction.completed","interaction":{"id":"","status":"completed"}}
        ,
        test_done,
    });
    var result = try test_consume(alloc, wire, test_request(), null);
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("hello", completion.content.?);
    try std.testing.expect(completion.generation_id == null);
}

test "gemini interactions consume_stream saves thought steps in order and round-trips replay" {
    const alloc = std.testing.allocator;
    const provider: model_provider.ProviderId = .google;
    const wire = sse_wire(&.{
        test_created,
        \\{"event_type":"step.start","index":0,"step":{"type":"thought"}}
        ,
        \\{"event_type":"step.delta","index":0,"delta":{"type":"thought_summary","content":{"type":"text","text":"Step 1 "}}}
        ,
        \\{"event_type":"step.delta","index":0,"delta":{"type":"thought_summary","content":{"type":"text","text":"done."}}}
        ,
        \\{"event_type":"step.delta","index":0,"delta":{"type":"thought_signature","signature":"sig-0"}}
        ,
        test_stop_0,
        \\{"event_type":"step.start","index":1,"step":{"type":"thought"}}
        ,
        \\{"event_type":"step.delta","index":1,"delta":{"type":"thought_signature","signature":"sig-1"}}
        ,
        \\{"event_type":"step.stop","index":1}
        ,
        \\{"event_type":"step.start","index":2,"step":{"type":"model_output"}}
        ,
        \\{"event_type":"step.delta","index":2,"delta":{"type":"text","text":"Answer."}}
        ,
        \\{"event_type":"step.stop","index":2}
        ,
        test_completed,
        test_done,
    });
    var recorder: Recorder = .{ .alloc = alloc };
    defer recorder.deinit();
    var result = try test_consume(alloc, wire, test_request(), recorder.sink());
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("Step 1 done.", recorder.reasoning.items);
    try std.testing.expectEqualStrings("Answer.", completion.content.?);
    const expected_state =
        \\[{"type":"thought","signature":"sig-0","summary":[{"type":"text","text":"Step 1 done."}]},{"type":"thought","signature":"sig-1","summary":[]}]
    ;
    try std.testing.expectEqualStrings(expected_state, completion.provider_state_json.?);

    const replay: types.ProviderReplay = .{ .source = .{ .provider = provider, .model = "gemini-4-hydrogen" }, .parts_json = completion.provider_state_json.? };
    var request = test_request();
    request.messages = &.{
        .{ .role = .user, .content = "ask" },
        .{ .role = .assistant, .content = completion.content, .provider_replay = replay },
        .{ .role = .user, .content = "follow up" },
    };
    var body = try build_parsed(alloc, request, .{ .provider = provider });
    defer body.deinit();
    const steps = body.parsed.value.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), steps.len);
    const sent_thoughts = try std.json.Stringify.valueAlloc(alloc, steps[1..3], .{});
    defer alloc.free(sent_thoughts);
    try std.testing.expectEqualStrings(expected_state, sent_thoughts);
    try std.testing.expectEqualStrings("model_output", steps[3].object.get("type").?.string);
}

test "gemini interactions consume_stream assembles function call from arguments_delta and requires_action" {
    const alloc = std.testing.allocator;
    const wire = sse_wire(&.{
        test_created,
        \\{"event_type":"step.start","index":0,"step":{"type":"function_call","id":"call_9","name":"read_file","arguments":{}}}
        ,
        \\{"event_type":"step.delta","index":0,"delta":{"type":"arguments_delta","arguments":"{\"path\":"}}
        ,
        \\{"event_type":"step.delta","index":0,"delta":{"type":"arguments_delta","arguments":"\"src/a.zig\"}"}}
        ,
        test_stop_0,
        \\{"event_type":"interaction.completed","interaction":{"id":"int_1","status":"requires_action","usage":{"total_input_tokens":5,"total_output_tokens":3}}}
        ,
        test_done,
    });
    var recorder: Recorder = .{ .alloc = alloc };
    defer recorder.deinit();
    var result = try test_consume(alloc, wire, test_tool_request(), recorder.sink());
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqualStrings("requires_action", completion.finish_reason_raw.slice());
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_9", completion.tool_calls[0].id);
    try std.testing.expectEqualStrings("read_file", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"src/a.zig\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, completion.tool_calls[0].argument_integrity);
    try std.testing.expectEqualStrings("call_9:read_file;", recorder.started.items);
    try std.testing.expectEqualStrings("{\"path\":\"src/a.zig\"}", recorder.tool_input.items);
}

test "gemini interactions consume_stream handles incomplete status" {
    const alloc = std.testing.allocator;
    const wire = sse_wire(&.{
        test_created,
        \\{"event_type":"step.start","index":0,"step":{"type":"function_call","id":"call_cut","name":"read_file","arguments":{}}}
        ,
        \\{"event_type":"step.delta","index":0,"delta":{"type":"arguments_delta","arguments":"{\"pa"}}
        ,
        \\{"event_type":"interaction.completed","interaction":{"id":"int_1","status":"incomplete"}}
        ,
        test_done,
    });
    var result = try test_consume(alloc, wire, test_tool_request(), null);
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqual(types.ProviderFinishReason.length, completion.finish_reason.?);
    try std.testing.expectEqualStrings("incomplete", completion.finish_reason_raw.slice());
    try std.testing.expectEqualStrings("{\"pa", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.malformed_json, completion.tool_calls[0].argument_integrity);
}

test "gemini interactions consume_stream fails on error event or failed status without partial output" {
    const alloc = std.testing.allocator;
    for ([_]struct { event: []const u8, kind: stream_provider.FailureKind }{
        .{ .event = "{\"event_type\":\"error\",\"error\":{\"code\":\"gateway_timeout\",\"message\":\"Timeout\"}}", .kind = .gateway_timeout },
        .{ .event = "{\"event_type\":\"error\",\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"Slow\"}}", .kind = .rate_limited },
        .{ .event = "{\"event_type\":\"error\",\"error\":{\"code\":\"not_found\",\"message\":\"Missing\"}}", .kind = .provider_error },
        .{ .event = "{\"event_type\":\"interaction.completed\",\"interaction\":{\"id\":\"int_1\",\"status\":\"failed\"}}", .kind = .provider_error },
    }) |case| {
        const wire = try test_wire(alloc, &.{ test_created, test_text_start, test_text_delta, case.event, test_done });
        defer alloc.free(wire);
        var result = try test_consume(alloc, wire, test_request(), null);
        defer result.deinit(alloc);
        try std.testing.expect(result == .failed);
        try std.testing.expectEqual(case.kind, result.failed.kind);
        try std.testing.expectEqualStrings(case.event, result.failed.detail.?);
    }
}

test "gemini interactions consume_stream rejects closed or incomplete stream and stops at DONE" {
    const alloc = std.testing.allocator;
    for ([_][]const []const u8{
        &.{},
        &.{test_created},
        &.{ test_created, test_text_start, test_text_delta, test_stop_0 },
        &.{ test_created, test_done },
    }) |events| {
        const wire = try test_wire(alloc, events);
        defer alloc.free(wire);
        try std.testing.expectError(error.IncompleteStream, test_consume(alloc, wire, test_request(), null));
    }
    const truncated = sse_wire(&.{ test_created, test_text_start, test_text_delta });
    try std.testing.expectError(error.IncompleteStream, test_consume(alloc, truncated[0 .. truncated.len - 1], test_request(), null));

    const trailing_garbage = comptime sse_wire(&.{ test_created, test_text_start, test_text_delta, test_stop_0, test_completed, test_done }) ++ "data: not json\n\n";
    var result = try test_consume(alloc, trailing_garbage, test_request(), null);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("hello", result.completed.completion.content.?);
}

test "gemini interactions consume_stream rejects delta before step.start and out-of-range index" {
    const alloc = std.testing.allocator;
    for ([_]struct { events: []const []const u8, failure: Error }{
        .{ .events = &.{"not json"}, .failure = error.MalformedInteractionsEvent },
        .{ .events = &.{"[]"}, .failure = error.InvalidEvent },
        .{ .events = &.{test_text_start}, .failure = error.InvalidEvent },
        .{ .events = &.{ test_created, test_created }, .failure = error.InvalidEvent },
        .{ .events = &.{ test_created, test_text_delta }, .failure = error.InvalidEvent },
        .{ .events = &.{ test_created, "{\"event_type\":\"step.start\",\"index\":1,\"step\":{\"type\":\"model_output\"}}" }, .failure = error.InvalidEvent },
        .{ .events = &.{ test_created, test_text_start, "{\"event_type\":\"step.delta\",\"index\":1,\"delta\":{\"type\":\"text\",\"text\":\"x\"}}" }, .failure = error.InvalidEvent },
        .{ .events = &.{ test_created, test_text_start, test_stop_0, test_text_delta }, .failure = error.InvalidEvent },
        .{ .events = &.{ test_created, "{\"event_type\":\"step.start\",\"index\":0,\"step\":{\"type\":\"function_call\",\"id\":\"c1\",\"name\":\"read_file\"}}", test_text_delta }, .failure = error.InvalidEvent },
        .{ .events = &.{ test_created, test_completed, test_completed }, .failure = error.InvalidEvent },
    }) |case| {
        const wire = try test_wire(alloc, case.events);
        defer alloc.free(wire);
        try std.testing.expectError(case.failure, test_consume(alloc, wire, test_tool_request(), null));
    }
}

test "gemini interactions consume_stream ignores keep-alive comments and unknown event types" {
    const alloc = std.testing.allocator;
    const wire =
        ": keep-alive\n\n" ++
        "event: interaction.created\n" ++
        "data: " ++ test_created ++ "\n\n" ++
        ": keep-alive\n\n" ++
        "event: interaction.status_update\n" ++
        "data: {\"event_type\":\"interaction.status_update\",\"status\":\"in_progress\"}\n\n" ++
        "event: future.event\n" ++
        "data: {\"event_type\":\"future.event\",\"x\":1}\n\n" ++
        "data: " ++ test_text_start ++ "\n\n" ++
        "data: " ++ test_text_delta ++ "\n\n" ++
        "data: " ++ test_stop_0 ++ "\n\n" ++
        ": keep-alive\n\n" ++
        "data: " ++ test_completed ++ "\n\n" ++
        "data: [DONE]\n\n";
    var result = try test_consume(alloc, wire, test_request(), null);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("hello", result.completed.completion.content.?);
}

test "gemini interactions consume_stream enforces each limit just over its bound" {
    const alloc = std.testing.allocator;
    const thought_start = "{\"event_type\":\"step.start\",\"index\":0,\"step\":{\"type\":\"thought\",\"summary\":[{\"type\":\"text\",\"text\":\"long thought\"}]}}";
    const call_start = "{\"event_type\":\"step.start\",\"index\":0,\"step\":{\"type\":\"function_call\",\"id\":\"call_1\",\"name\":\"read_file\",\"arguments\":{}}}";
    const call_delta = "{\"event_type\":\"step.delta\",\"index\":0,\"delta\":{\"type\":\"arguments_delta\",\"arguments\":\"{\\\"path\\\":\\\"x\\\"}\"}}";
    for ([_]struct { limits: Limits, events: []const []const u8, failure: Error }{
        .{ .limits = .{ .event_bytes = 8 }, .events = &.{test_created}, .failure = error.EventTooLarge },
        .{ .limits = .{ .total_wire_bytes = 8 }, .events = &.{test_created}, .failure = error.StreamTooLarge },
        .{ .limits = .{ .events = 1 }, .events = &.{ test_created, test_text_start }, .failure = error.TooManyEvents },
        .{ .limits = .{ .identity_bytes = 2 }, .events = &.{test_created}, .failure = error.IdentityTooLarge },
        .{ .limits = .{ .content_bytes = 4 }, .events = &.{ test_created, test_text_start, test_text_delta }, .failure = error.ContentTooLarge },
        .{ .limits = .{ .arguments_bytes = 4 }, .events = &.{ test_created, call_start, call_delta }, .failure = error.ArgumentsTooLarge },
        .{ .limits = .{ .tool_calls = 0 }, .events = &.{ test_created, call_start }, .failure = error.TooManyTools },
        .{ .limits = .{ .steps = 0 }, .events = &.{ test_created, test_text_start }, .failure = error.TooManySteps },
        .{ .limits = .{ .reasoning_bytes = 4 }, .events = &.{ test_created, thought_start }, .failure = error.ReplayTooLarge },
        .{ .limits = .{}, .events = &.{text_utils.repeat("[", 65) ++ text_utils.repeat("]", 65)}, .failure = error.JsonTooDeep },
    }) |case| {
        const wire = try test_wire(alloc, case.events);
        defer alloc.free(wire);
        var source = std.Io.Reader.fixed(wire);
        const cancelled = std.atomic.Value(bool).init(false);
        try std.testing.expectError(case.failure, consume_stream(alloc, &source, test_tool_request(), case.limits, null, &cancelled, null));
    }

    const ok_wire = sse_wire(&.{ test_created, test_text_start, test_text_delta, test_stop_0, test_completed, test_done });
    var source = std.Io.Reader.fixed(ok_wire);
    const cancelled = std.atomic.Value(bool).init(false);
    var result = try consume_stream(alloc, &source, test_request(), .{ .total_wire_bytes = ok_wire.len, .events = 7, .content_bytes = 5, .steps = 1 }, null, &cancelled, null);
    defer result.deinit(alloc);
}

test "gemini interactions cancellation poisons reducer and stops stream" {
    const alloc = std.testing.allocator;
    var reducer = try Reducer.init(alloc, test_tool_request(), .{});
    defer reducer.deinit();
    try test_accept(&reducer, test_created);
    try test_accept(&reducer, test_text_start);
    try std.testing.expectError(error.Cancelled, reducer.accept(test_text_delta, true));
    try std.testing.expectError(error.StreamClosed, reducer.finish(false));

    var cancelled = std.atomic.Value(bool).init(true);
    const wire = sse_wire(&.{ test_created, test_text_start, test_text_delta, test_stop_0, test_completed, test_done });
    var source = std.Io.Reader.fixed(wire);
    try std.testing.expectError(error.Cancelled, consume_stream(alloc, &source, test_request(), .{}, null, &cancelled, null));

    const Observer = struct {
        flag: *std.atomic.Value(bool),
        count: usize = 0,
        fn emit_event(context: *anyopaque, event: stream_provider.Event) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (event == .content_delta) self.count += 1;
            self.flag.store(true, .seq_cst);
        }
    };
    var observer = Observer{ .flag = &cancelled };
    cancelled.store(false, .seq_cst);
    const twice = sse_wire(&.{ test_created, test_text_start, test_text_delta, test_text_delta, test_stop_0, test_completed, test_done });
    source = std.Io.Reader.fixed(twice);
    try std.testing.expectError(error.Cancelled, consume_stream(alloc, &source, test_request(), .{}, .{ .context = &observer, .emit_fn = Observer.emit_event }, &cancelled, null));
    try std.testing.expectEqual(@as(usize, 1), observer.count);
}

fn test_build_allocations(alloc: Allocator) !void {
    const provider: model_provider.ProviderId = .google;
    const thought_state = "[{\"type\":\"thought\",\"signature\":\"sig-1\",\"summary\":[{\"type\":\"text\",\"text\":\"Inspect.\"}]}]";
    var request = test_tool_request();
    request.tool_choice = .required;
    request.instructions = &.{.{ .role = .system, .content = "be concise" }};
    request.messages = &.{
        .{ .role = .user, .content = "read it" },
        .{
            .role = .assistant,
            .content = "Reading.",
            .tool_calls = &.{.{ .id = "call_1", .name = "read_file", .arguments_json = "{\"path\":\"x\"}" }},
            .provider_replay = .{ .source = .{ .provider = provider, .model = "gemini-4-hydrogen" }, .parts_json = thought_state },
        },
        .{ .role = .tool, .tool_call_id = "call_1", .tool_name = "read_file", .content = "result", .tool_result_status = .success },
        .{ .role = .user, .content = "continue" },
    };
    const body = try build_request(alloc, request, .{ .provider = provider, .thinking_level = .high });
    defer alloc.free(body);

    var pixels = [_]u8{ 1, 2, 3 };
    const snapshots = [_]image_attachments.VerifiedSnapshot{.{ .bytes = &pixels, .media_type = "image/png" }};
    var structured = test_request();
    structured.tool_choice = .none;
    structured.response_format = .{ .name = "vision_result", .description = "Records.", .schema = .{ .object = .empty } };
    structured.verified_images = &snapshots;
    const structured_body = try build_request(alloc, structured, .{ .provider = provider });
    defer alloc.free(structured_body);
}

test "gemini interactions allocation failures release every partial request" {
    try test_build_allocations(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, test_build_allocations, .{});
}

fn test_consume_allocations(alloc: Allocator) !void {
    const wire = sse_wire(&.{
        test_created,
        \\{"event_type":"step.start","index":0,"step":{"type":"thought"}}
        ,
        \\{"event_type":"step.delta","index":0,"delta":{"type":"thought_summary","content":{"type":"text","text":"Think"}}}
        ,
        \\{"event_type":"step.delta","index":0,"delta":{"type":"thought_signature","signature":"sig-1"}}
        ,
        test_stop_0,
        \\{"event_type":"step.start","index":1,"step":{"type":"function_call","id":"call_1","name":"read_file","arguments":{}}}
        ,
        \\{"event_type":"step.delta","index":1,"delta":{"type":"arguments_delta","arguments":"{\"path\":\"x\"}"}}
        ,
        \\{"event_type":"step.stop","index":1}
        ,
        \\{"event_type":"interaction.completed","interaction":{"id":"int_1","status":"requires_action","usage":{"total_input_tokens":5,"total_output_tokens":3}}}
        ,
        test_done,
    });
    var reply = try test_consume(alloc, wire, test_tool_request(), null);
    defer reply.deinit(alloc);

    const err_wire = sse_wire(&.{
        test_created,
        test_text_start,
        test_text_delta,
        \\{"event_type":"error","error":{"code":"internal_error","message":"oops"}}
        ,
    });
    var failure = try test_consume(alloc, err_wire, test_request(), null);
    defer failure.deinit(alloc);
}

test "gemini interactions allocation failures release every partial reply" {
    try test_consume_allocations(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, test_consume_allocations, .{});
}

fn fuzzConsumeStream(_: void, smith: *std.testing.Smith) !void {
    var input_buf: [8192]u8 = undefined;
    const len = smith.slice(&input_buf);
    const bytes = input_buf[0..len];
    var read_buf: [64]u8 = undefined;
    const buf_len: usize = @intCast(smith.valueRangeAtMost(u8, 1, @intCast(read_buf.len)));
    var fixed = std.Io.Reader.fixed(bytes);
    var source = fixed.limited(.unlimited, read_buf[0..buf_len]);
    const cancelled = std.atomic.Value(bool).init(false);
    const alloc = std.testing.allocator;
    const limits: Limits = .{
        .event_bytes = 4096,
        .total_wire_bytes = 8192,
        .events = 64,
        .steps = 16,
        .tool_calls = 8,
        .identity_bytes = 256,
        .arguments_bytes = 4096,
        .content_bytes = 4096,
        .reasoning_bytes = 4096,
    };
    var result = consume_stream(alloc, &source.interface, test_tool_request(), limits, null, &cancelled, null) catch return;
    defer result.deinit(alloc);
    switch (result) {
        .completed => |completed| {
            const completion = completed.completion;
            if (completion.content) |text| try std.testing.expect(text.len <= limits.content_bytes);
            if (completion.provider_state_json) |state| {
                var parsed = try parse_replay(alloc, state);
                parsed.deinit();
            }
            for (completion.tool_calls) |call| {
                try std.testing.expect(call.id.len > 0);
                try std.testing.expect(call.name.len > 0);
            }
        },
        .failed => {},
    }
}

test "gemini interactions consume_stream parses or refuses fuzzed SSE bytes cleanly" {
    try std.testing.fuzz({}, fuzzConsumeStream, .{
        .corpus = &(@import("fuzz_seed").slices(.{ "", "data: [DONE]\n\n", "data: {\"event_type\":\"error\"}\n\n" }) ++ @import("fuzz_corpus").gemini_interactions_stream.*),
    });
}
