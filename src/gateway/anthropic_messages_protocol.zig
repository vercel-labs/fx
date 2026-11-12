//! Anthropic Messages codec for custom model connections whose settings say
//! `"protocol": "anthropic-messages"`: the body for `POST {base_url}/messages`
//! and the reducer for its server-sent events. The transport owns the
//! connection, headers, deadlines, and credentials; nothing here does I/O
//! beyond the reader it is handed. Tool selection, history checks, and limits
//! follow the Chat Completions codec (`chat_completions_protocol.zig`).
const std = @import("std");
const testing_allocator = @import("../core/shared/testing_allocator.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const tool_call_ids = @import("tool_call_ids.zig");
const sse = @import("sse.zig");
const function_tools = @import("function_tools.zig");
const json_depth = @import("../core/shared/json_depth.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const request_fragment = @import("../core/config/request_fragment.zig");
const model_provider = @import("../core/config/model_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const text_utils = @import("../core/shared/text_utils.zig");

const Allocator = std.mem.Allocator;

pub const Options = struct {
    tool_choice_mode: configured_provider.ToolChoiceMode = .omit,
    /// Borrowed during serialization; the configured authority binding.
    provider: ?*const model_provider.ProviderId = null,
    request_fields: request_fragment.Fragment = .{},
    /// Fields of the effort level the request carries; null when the model does not declare it.
    effort_fields: ?request_fragment.Fragment = null,
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
    MalformedMessagesEvent,
    ConflictingIdentity,
    InvalidFinishReason,
    InconsistentFinishReason,
    IncompleteStream,
    StreamClosed,
    EventTooLarge,
    StreamTooLarge,
    TooManyEvents,
    TooManyBlocks,
    TooManyTools,
    IdentityTooLarge,
    ArgumentsTooLarge,
    ContentTooLarge,
    JsonTooDeep,
    Cancelled,
    ReadFailed,
};

/// This API requires an output limit, so a request without one gets this.
const default_max_tokens = 4096;
const max_selected_tools = function_tools.max_selected_tools;
const max_name_bytes = function_tools.max_name_bytes;
const max_history_arguments_bytes = 1024 * 1024;
const max_json_depth = json_depth.max_depth;
const max_error_detail_bytes = 64 * 1024;

fn validate_request(request: stream_provider.RequestData, effort_declared: bool) Error!void {
    try request.validatePrompt();
    configured_provider.validate_model_id(request.model) catch return error.InvalidModel;
    const options = request.provider_options;
    if (options.reasoning != null and !effort_declared) return error.UnsupportedProviderOption;
    if (options.fast or options.prompt_caching) return error.UnsupportedProviderOption;
    if (options.provider_order.len != 0) return error.UnsupportedProviderOption;
    // A structured reply travels as a forced tool: its schema is the tool's
    // input schema and its name the tool's name.
    if (request.response_format) |format| {
        if (format.schema != .object) return error.UnsupportedResponseFormat;
        function_tools.validate_name(format.name) catch return error.UnsupportedResponseFormat;
    }
    // Verified snapshots come from the vision executor's structured request
    // and travel on its last user message.
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
        if (message.tool_calls.len > max_selected_tools) return error.TooManyTools;
        for (message.tool_calls) |call| {
            if (call.provenance != .fx_local or call.provider_result != null) return error.UnsupportedToolProvenance;
            if (call.id.len == 0 or call.final_identity != .valid) return error.InvalidToolCallId;
            try function_tools.validate_name(call.name);
            if (call.arguments_json.len > max_history_arguments_bytes) return error.ArgumentsTooLarge;
            // `tool_use.input` is a JSON object, not text.
            try validate_arguments(alloc, call.arguments_json);
            const entry = try pending.getOrPut(alloc, call.id);
            if (entry.found_existing) return error.InvalidToolHistory;
            entry.value_ptr.* = call.name;
        }
    }
    if (pending.count() != 0) return error.InvalidToolHistory;
}

/// Parses one assistant message's replay: the JSON array of thinking blocks
/// `Reducer.provider_state` wrote, in the reply's order. Anything else is
/// refused rather than sent, because the server checks each block's signature.
fn parse_replay(alloc: Allocator, raw: []const u8) Error!std.json.Parsed(std.json.Value) {
    if (raw.len > types.ProviderReplay.max_bytes) return error.ReplayTooLarge;
    try check_json_depth(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderState,
    };
    errdefer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len == 0) return error.InvalidProviderState;
    for (parsed.value.array.items) |block| try validate_replay_block(block);
    return parsed;
}

fn validate_replay_block(block: std.json.Value) Error!void {
    if (block != .object) return error.InvalidProviderState;
    const fields = block.object;
    const kind = fields.get("type") orelse return error.InvalidProviderState;
    if (kind != .string) return error.InvalidProviderState;
    const expected: []const []const u8 = if (std.mem.eql(u8, kind.string, "thinking"))
        &.{ "thinking", "signature" }
    else if (std.mem.eql(u8, kind.string, "redacted_thinking"))
        &.{"data"}
    else
        return error.InvalidProviderState;
    if (fields.keys().len != expected.len + 1) return error.InvalidProviderState;
    for (expected) |key| {
        const value = fields.get(key) orelse return error.InvalidProviderState;
        if (value != .string) return error.InvalidProviderState;
    }
}

/// Borrows `replay` unchanged or drops it. The thinking blocks belong to the
/// whole reply, so they stay while reasoning does, whatever else is kept.
pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, _: []const types.ToolCall, _: bool, reasoning: bool) Error!?types.ProviderReplay {
    const value = replay orelse return null;
    if (value.source.provider == .gateway) return error.InvalidProviderState;
    if (!reasoning) return null;
    var parsed = try parse_replay(alloc, value.parts_json);
    parsed.deinit();
    return value;
}

/// Caller owns the body. Model IDs are opaque: no catalog lookup, prefix
/// inference, or provider defaults. Deadline enforcement and prepared-body
/// reuse belong to the transport owner.
pub fn build_request(alloc: Allocator, input: stream_provider.RequestData, options: Options) Error![]u8 {
    try validate_request(input, options.effort_fields != null);
    var projected: ?[]types.ChatMessage = null;
    if (options.provider) |provider| {
        projected = try types.projectProviderReplay(alloc, input.messages, .{ .provider = provider.*, .model = input.model });
    } else {
        for (input.messages) |message| if (message.provider_replay != null) return error.UnsupportedReplay;
    }
    defer if (projected) |messages| alloc.free(messages);
    var request = input;
    request.messages = projected orelse input.messages;
    try validate_history(alloc, request.messages);
    // A structured reply's forced tool is the only tool the request sends.
    var functions: std.ArrayList(function_tools.Function) = if (request.response_format == null)
        try function_tools.select_functions(alloc, request.tools, request.tool_choice, request.vision_mode)
    else
        .empty;
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
        error.InvalidProviderState, error.ReplayTooLarge, error.JsonTooDeep, error.ImageUnavailable, error.InvalidProviderPrompt => |failure| return failure,
        else => return error.InvalidToolSchema,
    };
    return out.toOwnedSlice();
}

fn write_request(writer: *std.Io.Writer, alloc: Allocator, request: stream_provider.RequestData, options: Options, functions: []const function_tools.Function, projection: *const tool_call_ids.Projection) !void {
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    try writer.print(",\"max_tokens\":{d},\"stream\":true", .{request.max_output_tokens orelse default_max_tokens});
    try write_system(writer, alloc, request.instructions);
    try write_messages(writer, alloc, request, projection);
    if (request.response_format) |format| {
        try writer.writeAll(",\"tools\":[{\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        if (format.description.len != 0) {
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(format.description, .{}, writer);
        }
        try writer.writeAll(",\"input_schema\":");
        try std.json.Stringify.value(format.schema, .{}, writer);
        // Forced whatever the connection's tool-choice setting: without it the
        // reply has no structure.
        try writer.writeAll("}],\"tool_choice\":{\"type\":\"tool\",\"name\":");
        try std.json.Stringify.value(format.name, .{}, writer);
        try writer.writeByte('}');
    } else if (functions.len != 0) {
        try writer.writeAll(",\"tools\":[");
        for (functions, 0..) |function, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try std.json.Stringify.value(function.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, function.description);
            try writer.writeAll(",\"input_schema\":");
            switch (function.schema) {
                .builtin => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
                .dynamic => |schema| try std.json.Stringify.value(schema, .{}, writer),
            }
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
        if (options.tool_choice_mode == .send) {
            const choice: types.ToolChoice = if (request.vision_mode == .required) .required else request.tool_choice;
            try writer.writeAll(switch (choice) {
                .auto => ",\"tool_choice\":{\"type\":\"auto\"}",
                .required => ",\"tool_choice\":{\"type\":\"any\"}",
                .none => ",\"tool_choice\":{\"type\":\"none\"}",
            });
        }
    }
    // Last, so every field above is fx's own: the settings cannot name one.
    const effort_fields = if (request.provider_options.reasoning != null) options.effort_fields orelse request_fragment.Fragment{} else request_fragment.Fragment{};
    try request_fragment.write(writer, options.request_fields, effort_fields);
    try writer.writeByte('}');
}

/// The instructions, joined, as the one `system` string this API takes.
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
    try writer.writeAll(",\"system\":");
    try std.json.Stringify.value(joined.items, .{}, writer);
}

const WireRole = enum { user, assistant };

/// Writes the `messages` array one content block at a time. A block whose
/// role matches the open message joins it, so the roles alternate on the
/// wire however fx's history repeats them, and a message with nothing to
/// send writes nothing.
const Turns = struct {
    writer: *std.Io.Writer,
    role: ?WireRole = null,
    blocks: usize = 0,

    fn begin_block(self: *Turns, role: WireRole) !void {
        if (self.role != role) {
            // The API reads a conversation that starts with a user turn.
            if (self.role == null and role != .user) return error.InvalidProviderPrompt;
            if (self.role != null) try self.writer.writeAll("]},");
            try self.writer.writeAll(switch (role) {
                .user => "{\"role\":\"user\",\"content\":[",
                .assistant => "{\"role\":\"assistant\",\"content\":[",
            });
            self.role = role;
            self.blocks = 0;
        }
        if (self.blocks != 0) try self.writer.writeByte(',');
        self.blocks += 1;
    }

    /// Closes the open message. No messages at all is a body fx builds only
    /// to measure the part of a request that compaction cannot shrink
    /// (`orchestrator.zig`, `request_fixed_tokens`), so it is written as `[]`.
    fn finish(self: *Turns) !void {
        if (self.role == null) return;
        try self.writer.writeAll("]}");
    }
};

fn write_messages(writer: *std.Io.Writer, alloc: Allocator, request: stream_provider.RequestData, projection: *const tool_call_ids.Projection) !void {
    try writer.writeAll(",\"messages\":[");
    var turns: Turns = .{ .writer = writer };
    const verified = request.verified_images orelse &.{};
    const verified_at = if (verified.len != 0) function_tools.last_user_index(request.messages) else null;
    for (request.messages, 0..) |message, index| switch (message.role) {
        .user => try write_user(&turns, alloc, message, if (verified_at == index) verified else &.{}),
        .assistant => try write_assistant(&turns, alloc, message, projection),
        .tool => try write_tool_result(&turns, message, projection),
        // validate_prompt_lanes keeps system messages in the instructions lane.
        .system => return error.InvalidProviderPrompt,
    };
    try turns.finish();
    try writer.writeByte(']');
}

/// `verified` are snapshots already read and checked, sent after the text.
fn write_user(turns: *Turns, alloc: Allocator, message: types.ChatMessage, verified: []const image_attachments.VerifiedSnapshot) !void {
    if (non_empty(message.content)) |text| {
        try turns.begin_block(.user);
        try write_text_block(turns.writer, text);
    }
    for (message.images) |image| {
        var snapshot = image_attachments.loadVerifiedSnapshot(alloc, image, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ImageUnavailable,
        };
        defer snapshot.deinit(alloc);
        try turns.begin_block(.user);
        try write_image_block(turns.writer, snapshot.media_type, snapshot.bytes);
    }
    for (verified) |snapshot| {
        try turns.begin_block(.user);
        try write_image_block(turns.writer, snapshot.media_type, snapshot.bytes);
    }
}

/// The replayed thinking blocks first, unchanged, then the text and calls.
fn write_assistant(turns: *Turns, alloc: Allocator, message: types.ChatMessage, projection: *const tool_call_ids.Projection) !void {
    if (message.provider_replay) |replay| {
        var parsed = try parse_replay(alloc, replay.parts_json);
        defer parsed.deinit();
        for (parsed.value.array.items) |block| {
            try turns.begin_block(.assistant);
            try std.json.Stringify.value(block, .{}, turns.writer);
        }
    }
    if (non_empty(message.content)) |text| {
        try turns.begin_block(.assistant);
        try write_text_block(turns.writer, text);
    }
    for (message.tool_calls) |call| {
        try turns.begin_block(.assistant);
        const writer = turns.writer;
        try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
        try std.json.Stringify.value(projection.resolve(call.id), .{}, writer);
        try writer.writeAll(",\"name\":");
        try std.json.Stringify.value(call.name, .{}, writer);
        // validate_history proved the arguments are one JSON object.
        try writer.writeAll(",\"input\":");
        try writer.writeAll(call.arguments_json);
        try writer.writeByte('}');
    }
}

/// A tool result is a block of the user turn that follows the call. Its
/// retained images ride inside it, except on a permission denial.
fn write_tool_result(turns: *Turns, message: types.ChatMessage, projection: *const tool_call_ids.Projection) !void {
    try turns.begin_block(.user);
    const writer = turns.writer;
    const content = message.content.?;
    const retained: []const types.ToolImage = if (message.tool_result_memory) |memory| memory.tool_images else &.{};
    const images = if (function_tools.toolResultDenied(message)) &.{} else retained;
    try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
    try std.json.Stringify.value(projection.resolve(message.tool_call_id.?), .{}, writer);
    try writer.writeAll(",\"content\":");
    if (images.len == 0) {
        try std.json.Stringify.value(content, .{}, writer);
    } else {
        try writer.writeByte('[');
        if (content.len != 0) {
            try write_text_block(writer, content);
            try writer.writeByte(',');
        }
        for (images, 0..) |image, index| {
            if (index != 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
            try std.json.Stringify.value(image.mime_type, .{}, writer);
            try writer.writeAll(",\"data\":");
            try std.json.Stringify.value(image.data, .{}, writer);
            try writer.writeAll("}}");
        }
        try writer.writeByte(']');
    }
    if (message.tool_result_status == .failure) try writer.writeAll(",\"is_error\":true");
    try writer.writeByte('}');
}

fn write_text_block(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeByte('}');
}

/// Writes one base64 image block from raw bytes, encoding in chunks.
fn write_image_block(writer: *std.Io.Writer, media_type: []const u8, bytes: []const u8) !void {
    try writer.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
    try std.json.Stringify.value(media_type, .{}, writer);
    try writer.writeAll(",\"data\":\"");
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 3 * 1024, bytes.len);
        try std.base64.standard.Encoder.encodeWriter(writer, bytes[offset..end]);
        offset = end;
    }
    try writer.writeAll("\"}}");
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
    /// Content blocks of every type, known or not.
    blocks: usize = 1024,
    tool_calls: usize = 128,
    identity_bytes: usize = 256,
    arguments_bytes: usize = 1024 * 1024,
    /// The reply's text, or a structured reply's JSON.
    content_bytes: usize = 8 * 1024 * 1024,
    /// Thinking text, signatures, and redacted data kept for replay.
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

const Block = struct {
    kind: enum { text, tool_use, thinking, redacted_thinking, ignored },
    /// The entry in `tools` or `thinking` this block fills.
    slot: usize = 0,
    open: bool = true,
};

const Tool = struct {
    id: ?[]u8 = null,
    name: ?[]u8 = null,
    arguments: std.ArrayList(u8) = .empty,
    /// The block's starting `input` as JSON, when it was not empty.
    start_input: ?[]u8 = null,
    /// The forced tool that carries a structured reply.
    structured: bool = false,

    fn deinit(self: *Tool, alloc: Allocator) void {
        if (self.id) |id| alloc.free(id);
        if (self.name) |name| alloc.free(name);
        self.arguments.deinit(alloc);
        if (self.start_input) |input| alloc.free(input);
    }

    /// Caller owns the result: the streamed input, else the input the block
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

const Thinking = struct {
    redacted: bool,
    /// The thinking text, or a redacted block's data.
    text: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
};

const Stop = struct {
    reason: types.ProviderFinishReason,
    raw: types.ProviderFinishRaw,
};

const Failure = struct {
    kind: stream_provider.FailureKind,
    /// Owned: the error event as the server sent it.
    detail: []u8,
};

/// The usage counts as the latest event reported each one.
const Counts = struct {
    input: ?u64 = null,
    output: ?u64 = null,
    cache_read: ?u64 = null,
    cache_write: ?u64 = null,
};

/// Single-owner, request-local state machine. No I/O, callbacks, tool
/// execution, or hidden cancellation reads. Owns all retained input until
/// deinit, and borrows the request's structured format name. Any accept or
/// finish failure poisons the reducer; deinit remains mandatory. A
/// successful finish transfers independent owned results.
const Reducer = struct {
    alloc: Allocator,
    limits: Limits,
    choice: types.ToolChoice,
    structured_name: ?[]const u8,
    blocks: std.ArrayList(Block) = .empty,
    tools: std.ArrayList(Tool) = .empty,
    thinking: std.ArrayList(Thinking) = .empty,
    content: std.ArrayList(u8) = .empty,
    generation_id: ?[]u8 = null,
    counts: Counts = .{},
    stop: ?Stop = null,
    failure: ?Failure = null,
    phase: enum { initial, streaming, done, failed, closed } = .initial,
    event_count: usize = 0,
    json_bytes: usize = 0,
    reasoning_bytes: usize = 0,

    fn init(alloc: Allocator, request: stream_provider.RequestData, limits: Limits) Error!Reducer {
        // The reply answers a request `build_request` already let through, so
        // an effort it carries was declared.
        try validate_request(request, true);
        return .{
            .alloc = alloc,
            .limits = limits,
            .choice = request.tool_choice,
            .structured_name = if (request.response_format) |format| format.name else null,
        };
    }

    fn deinit(self: *Reducer) void {
        self.blocks.deinit(self.alloc);
        for (self.tools.items) |*tool| tool.deinit(self.alloc);
        self.tools.deinit(self.alloc);
        for (self.thinking.items) |*part| {
            part.text.deinit(self.alloc);
            part.signature.deinit(self.alloc);
        }
        self.thinking.deinit(self.alloc);
        self.content.deinit(self.alloc);
        if (self.generation_id) |id| self.alloc.free(id);
        if (self.failure) |failure| self.alloc.free(failure.detail);
        self.* = undefined;
    }

    /// Accepts one already-framed data event. JSON-only callers must also
    /// bound framing wire; consume_stream includes comments.
    fn accept(self: *Reducer, data: []const u8, cancelled: bool) Error!Deltas {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        if (self.phase != .initial and self.phase != .streaming) return error.StreamClosed;
        if (data.len > self.limits.event_bytes) return error.EventTooLarge;
        if (data.len > self.limits.total_wire_bytes - self.json_bytes) return error.StreamTooLarge;
        self.json_bytes += data.len;
        if (self.event_count == self.limits.events) return error.TooManyEvents;
        self.event_count += 1;
        try check_json_depth(data);
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // Valid JSON that fx refuses ends the turn. Text that is not JSON
            // at all was damaged on the way, so the request can be resent.
            error.DuplicateField => return error.InvalidEvent,
            else => return error.MalformedMessagesEvent,
        };
        defer parsed.deinit();
        const root = try object(parsed.value);
        const kind = try string(root.get("type") orelse return error.InvalidEvent);
        if (std.mem.eql(u8, kind, "error")) {
            try self.accept_error(data, root);
            return .{};
        }
        if (std.mem.eql(u8, kind, "ping")) return .{};
        if (std.mem.eql(u8, kind, "message_start")) {
            try self.accept_message_start(root);
            return .{};
        }
        const message_events = [_][]const u8{ "content_block_start", "content_block_delta", "content_block_stop", "message_delta", "message_stop" };
        // Event types added after this codec carry nothing fx reads.
        if (!function_tools.contains_name(&message_events, kind)) return .{};
        if (self.phase != .streaming) return error.InvalidEvent;
        if (std.mem.eql(u8, kind, "content_block_start")) return self.accept_block_start(root);
        if (std.mem.eql(u8, kind, "content_block_delta")) return self.accept_block_delta(root);
        if (std.mem.eql(u8, kind, "content_block_stop")) {
            (try self.open_block(root)).open = false;
            return .{};
        }
        if (std.mem.eql(u8, kind, "message_delta")) {
            try self.accept_message_delta(root);
            return .{};
        }
        self.phase = .done;
        return .{};
    }

    fn accept_message_start(self: *Reducer, root: std.json.ObjectMap) Error!void {
        if (self.phase != .initial) return error.InvalidEvent;
        const message = try object(root.get("message") orelse return error.InvalidEvent);
        if (non_null(message, "id")) |value| {
            const id = try string(value);
            if (id.len == 0) return error.InvalidEvent;
            if (id.len > self.limits.identity_bytes) return error.IdentityTooLarge;
            self.generation_id = try self.alloc.dupe(u8, id);
        }
        if (non_null(message, "usage")) |usage| try self.accept_usage(usage);
        self.phase = .streaming;
    }

    fn accept_block_start(self: *Reducer, root: std.json.ObjectMap) Error!Deltas {
        const index = try index_value(root.get("index") orelse return error.InvalidEvent);
        // Blocks arrive in order, each with the next index.
        if (index != self.blocks.items.len) return error.InvalidEvent;
        if (index == self.limits.blocks) return error.TooManyBlocks;
        const block = try object(root.get("content_block") orelse return error.InvalidEvent);
        const kind = try string(block.get("type") orelse return error.InvalidEvent);
        try self.blocks.ensureUnusedCapacity(self.alloc, 1);
        if (std.mem.eql(u8, kind, "text")) {
            self.blocks.appendAssumeCapacity(.{ .kind = .text });
            const text = if (non_null(block, "text")) |value| try string(value) else "";
            return .{ .content = try self.append_text(text) };
        }
        if (std.mem.eql(u8, kind, "tool_use")) return self.start_tool(block);
        const redacted = std.mem.eql(u8, kind, "redacted_thinking");
        if (!redacted and !std.mem.eql(u8, kind, "thinking")) {
            // Server tools, their results, and later block types carry
            // nothing fx reads, and neither do their deltas.
            self.blocks.appendAssumeCapacity(.{ .kind = .ignored });
            return .{};
        }
        try self.thinking.append(self.alloc, .{ .redacted = redacted });
        self.blocks.appendAssumeCapacity(.{ .kind = if (redacted) .redacted_thinking else .thinking, .slot = self.thinking.items.len - 1 });
        const part = &self.thinking.items[self.thinking.items.len - 1];
        if (redacted) {
            _ = try self.append_reasoning(&part.text, try string(block.get("data") orelse return error.InvalidEvent));
            return .{};
        }
        if (non_null(block, "signature")) |value| _ = try self.append_reasoning(&part.signature, try string(value));
        const text = if (non_null(block, "thinking")) |value| try string(value) else "";
        return .{ .reasoning = try self.append_reasoning(&part.text, text) };
    }

    fn start_tool(self: *Reducer, block: std.json.ObjectMap) Error!Deltas {
        const id = try string(block.get("id") orelse return error.InvalidEvent);
        const name = try string(block.get("name") orelse return error.InvalidEvent);
        if (id.len == 0) return error.InvalidEvent;
        if (id.len > self.limits.identity_bytes or name.len > @min(max_name_bytes, self.limits.identity_bytes)) return error.IdentityTooLarge;
        const structured = if (self.structured_name) |expected| std.mem.eql(u8, expected, name) else false;
        // A structured request sends only its own tool, once; a request that
        // allows no tools sends none.
        if (self.structured_name != null and (!structured or self.tools.items.len != 0)) return error.UnexpectedToolCall;
        if (self.choice == .none and !structured) return error.UnexpectedToolCall;
        if (self.tools.items.len == self.limits.tool_calls) return error.TooManyTools;
        for (self.tools.items) |prior| if (std.mem.eql(u8, prior.id.?, id)) return error.ConflictingIdentity;
        var tool: Tool = .{ .structured = structured };
        errdefer tool.deinit(self.alloc);
        tool.id = try self.alloc.dupe(u8, id);
        tool.name = try self.alloc.dupe(u8, name);
        if (block.get("input")) |input| {
            if (input != .object) return error.InvalidEvent;
            // The input normally streams as deltas after an empty start; a
            // server may send it whole here instead.
            if (input.object.keys().len != 0) {
                const encoded = try std.json.Stringify.valueAlloc(self.alloc, input, .{});
                tool.start_input = encoded;
                if (structured and encoded.len > self.limits.content_bytes) return error.ContentTooLarge;
                if (!structured and encoded.len > self.limits.arguments_bytes) return error.ArgumentsTooLarge;
            }
        }
        try self.tools.ensureUnusedCapacity(self.alloc, 1);
        self.blocks.appendAssumeCapacity(.{ .kind = .tool_use, .slot = self.tools.items.len });
        self.tools.appendAssumeCapacity(tool);
        if (structured) return .{};
        const stored = &self.tools.items[self.tools.items.len - 1];
        return .{ .tool_started = .{ .id = stored.id.?, .name = stored.name.? } };
    }

    fn accept_block_delta(self: *Reducer, root: std.json.ObjectMap) Error!Deltas {
        const block = (try self.open_block(root)).*;
        const delta = try object(root.get("delta") orelse return error.InvalidEvent);
        const kind = try string(delta.get("type") orelse return error.InvalidEvent);
        const known = [_][]const u8{ "text_delta", "input_json_delta", "thinking_delta", "signature_delta" };
        // Citations and later delta types carry nothing fx reads, and a block
        // fx does not read takes its deltas with it.
        if (!function_tools.contains_name(&known, kind) or block.kind == .ignored) return .{};
        if (std.mem.eql(u8, kind, "text_delta")) {
            if (block.kind != .text) return error.InvalidEvent;
            return .{ .content = try self.append_text(try string(delta.get("text") orelse return error.InvalidEvent)) };
        }
        if (std.mem.eql(u8, kind, "input_json_delta")) {
            if (block.kind != .tool_use) return error.InvalidEvent;
            const tool = &self.tools.items[block.slot];
            const partial = try string(delta.get("partial_json") orelse return error.InvalidEvent);
            if (tool.structured) {
                try append_bounded(self.alloc, &tool.arguments, partial, self.limits.content_bytes, error.ContentTooLarge);
                return .{};
            }
            const start = tool.arguments.items.len;
            try append_bounded(self.alloc, &tool.arguments, partial, self.limits.arguments_bytes, error.ArgumentsTooLarge);
            return .{ .tool_input = if (partial.len == 0) null else tool.arguments.items[start..] };
        }
        if (block.kind != .thinking) return error.InvalidEvent;
        const part = &self.thinking.items[block.slot];
        if (std.mem.eql(u8, kind, "signature_delta")) {
            _ = try self.append_reasoning(&part.signature, try string(delta.get("signature") orelse return error.InvalidEvent));
            return .{};
        }
        return .{ .reasoning = try self.append_reasoning(&part.text, try string(delta.get("thinking") orelse return error.InvalidEvent)) };
    }

    fn open_block(self: *Reducer, root: std.json.ObjectMap) Error!*Block {
        const index = try index_value(root.get("index") orelse return error.InvalidEvent);
        if (index >= self.blocks.items.len or !self.blocks.items[index].open) return error.InvalidEvent;
        return &self.blocks.items[index];
    }

    /// Adds streamed text and returns the part to show. A structured reply
    /// shows none: its content is the forced tool's input, or this text when
    /// the server answered without the tool.
    fn append_text(self: *Reducer, text: []const u8) Error!?[]const u8 {
        const start = self.content.items.len;
        try append_bounded(self.alloc, &self.content, text, self.limits.content_bytes, error.ContentTooLarge);
        if (self.structured_name != null or text.len == 0) return null;
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

    fn accept_message_delta(self: *Reducer, root: std.json.ObjectMap) Error!void {
        if (non_null(root, "delta")) |value| {
            const delta = try object(value);
            if (non_null(delta, "stop_reason")) |reason| {
                const raw = try string(reason);
                const stop: Stop = .{ .reason = finish_reason_of(raw), .raw = .init(raw) };
                if (self.stop) |prior| if (!std.mem.eql(u8, prior.raw.slice(), stop.raw.slice())) return error.InconsistentFinishReason;
                self.stop = stop;
            }
        }
        if (non_null(root, "usage")) |usage| try self.accept_usage(usage);
    }

    /// `message_delta` usage is cumulative, so each count a later event
    /// reports replaces the earlier one.
    fn accept_usage(self: *Reducer, value: std.json.Value) Error!void {
        const fields = try object(value);
        if (try token_count(fields, "input_tokens")) |count| self.counts.input = count;
        if (try token_count(fields, "output_tokens")) |count| self.counts.output = count;
        // Details a server may add. One that is malformed or negative is left
        // out and the reply stands.
        if (detail_count(fields, "cache_read_input_tokens")) |count| self.counts.cache_read = count;
        if (detail_count(fields, "cache_creation_input_tokens")) |count| self.counts.cache_write = count;
    }

    fn accept_error(self: *Reducer, data: []const u8, root: std.json.ObjectMap) Error!void {
        const kind = if (error_type(root)) |name| failure_kind(name) else .provider_error;
        const detail = try self.alloc.dupe(u8, if (data.len > max_error_detail_bytes) "Provider error details exceeded the local limit" else data);
        self.failure = .{ .kind = kind, .detail = detail };
        self.phase = .failed;
    }

    /// fx counts the whole prompt; this API splits it into the part read
    /// from its cache, the part written there, and the rest.
    fn final_usage(self: *const Reducer) types.Usage {
        const counts = self.counts;
        const reported = counts.input != null or counts.cache_read != null or counts.cache_write != null;
        return .{
            .input_tokens = if (reported) (counts.input orelse 0) +| (counts.cache_read orelse 0) +| (counts.cache_write orelse 0) else null,
            .output_tokens = counts.output,
            .cache_read_tokens = counts.cache_read,
            .cache_write_tokens = counts.cache_write,
        };
    }

    /// Caller owns the replay state: the reply's thinking blocks in order, as
    /// `write_assistant` sends them back.
    fn provider_state(self: *const Reducer) (Error || std.Io.Writer.Error)!?[]u8 {
        if (self.thinking.items.len == 0) return null;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try out.writer.writeByte('[');
        for (self.thinking.items, 0..) |part, index| {
            if (index != 0) try out.writer.writeByte(',');
            if (part.redacted) {
                try out.writer.writeAll("{\"type\":\"redacted_thinking\",\"data\":");
                try std.json.Stringify.value(part.text.items, .{}, &out.writer);
            } else {
                try out.writer.writeAll("{\"type\":\"thinking\",\"thinking\":");
                try std.json.Stringify.value(part.text.items, .{}, &out.writer);
                try out.writer.writeAll(",\"signature\":");
                try std.json.Stringify.value(part.signature.items, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
        try out.writer.writeByte(']');
        if (out.written().len > @min(self.limits.reasoning_bytes, types.ProviderReplay.max_bytes)) return error.ReplayTooLarge;
        return try out.toOwnedSlice();
    }

    /// Requires `message_stop`, or returns the failure an `error` event
    /// reported. A reply the output limit cut off returns with the `length`
    /// reason so the agent loop can resend it; it never runs that reply's
    /// partial calls. Results use stream_provider.Result.deinit with this
    /// reducer's allocator.
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
            .done => {},
            .initial, .streaming => return error.IncompleteStream,
        }
        const stop = self.stop orelse return error.InvalidFinishReason;
        var reason = stop.reason;
        if (self.structured_name != null) {
            // The forced tool's input is the reply, not a call to run.
            if (self.tools.items.len != 0 and reason == .tool_calls) reason = .stop;
            if (reason == .tool_calls) return error.InconsistentFinishReason;
        } else if (reason == .stop or reason == .tool_calls) {
            // A cut-off or refused reply may stop anywhere, so only a
            // finished one has to agree with its tool calls.
            if ((reason == .tool_calls) != (self.tools.items.len != 0)) return error.InconsistentFinishReason;
            if (self.choice == .required and self.tools.items.len == 0) return error.RequiredToolMissing;
        }
        // Unadvertised names and invalid arguments are returned as sent. The
        // tool loop decides whether such a call runs and answers the rest.
        for (self.tools.items) |tool| {
            if (!tool.structured) try function_tools.validate_name(tool.name.?);
            try check_json_depth(tool.arguments.items);
        }
        const state = self.provider_state() catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |failure| return failure,
        };
        errdefer if (state) |bytes| self.alloc.free(bytes);
        var content: ?[]u8 = null;
        errdefer if (content) |text| self.alloc.free(text);
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| {
                self.alloc.free(call.id);
                self.alloc.free(call.name);
                self.alloc.free(call.arguments_json);
            }
            calls.deinit(self.alloc);
        }
        try calls.ensureTotalCapacityPrecise(self.alloc, self.tools.items.len);
        // finish() is terminal: ownership moves to the result and the
        // emptied accumulators cost nothing at reducer deinit.
        for (self.tools.items) |*tool| {
            const arguments = try tool.take_arguments(self.alloc);
            if (tool.structured) {
                content = arguments;
                continue;
            }
            calls.appendAssumeCapacity(.{ .id = tool.id.?, .name = tool.name.?, .arguments_json = arguments });
            tool.id = null;
            tool.name = null;
        }
        if (content == null and self.content.items.len != 0) content = try self.content.toOwnedSlice(self.alloc);
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

fn finish_reason_of(raw: []const u8) types.ProviderFinishReason {
    const reasons = [_]struct { []const u8, types.ProviderFinishReason }{
        .{ "end_turn", .stop },
        .{ "stop_sequence", .stop },
        .{ "tool_use", .tool_calls },
        .{ "max_tokens", .length },
        .{ "refusal", .content_filter },
    };
    for (reasons) |entry| if (std.mem.eql(u8, entry[0], raw)) return entry[1];
    return .provider_error;
}

fn error_type(root: std.json.ObjectMap) ?[]const u8 {
    const value = non_null(root, "error") orelse return null;
    if (value != .object) return null;
    const name = non_null(value.object, "type") orelse return null;
    return if (name == .string) name.string else null;
}

/// The kind each error type gets when the server sends it as an HTTP status
/// instead, so recovery treats both the same way.
fn failure_kind(name: []const u8) stream_provider.FailureKind {
    const kinds = [_]struct { []const u8, stream_provider.FailureKind }{
        .{ "invalid_request_error", .invalid_request },
        .{ "authentication_error", .unauthorized },
        .{ "permission_error", .forbidden },
        .{ "request_too_large", .request_too_large },
        .{ "rate_limit_error", .rate_limited },
        .{ "api_error", .server_error },
        .{ "overloaded_error", .server_error },
        .{ "timeout_error", .gateway_timeout },
    };
    for (kinds) |entry| if (std.mem.eql(u8, entry[0], name)) return entry[1];
    return .provider_error;
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
/// exactly at `message_stop` or an `error` event, without waiting for EOF or
/// consuming another event. event_bytes also bounds all wire between
/// dispatched data events (including `event:` lines and comments);
/// total_wire_bytes bounds the entire consumed stream. `progress`, when set,
/// is told about each data event. An `error` event returns a failed result
/// whose detail is the event as sent; the caller masks credentials in it.
pub fn consume_stream(alloc: Allocator, source: *std.Io.Reader, request: stream_provider.RequestData, limits: Limits, events: ?stream_provider.EventSink, cancel_flag: *const std.atomic.Value(bool), progress: ?sse.Progress) Error!stream_provider.Result {
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
        const chunk = data orelse return error.IncompleteStream;
        const deltas = try reducer.accept(chunk, cancel_flag.load(.seq_cst));
        if (events) |sink| try emit(sink, deltas, cancel_flag);
        if (reducer.phase == .done or reducer.phase == .failed) return reducer.finish(cancel_flag.load(.seq_cst));
    }
}

// Tests. The captures are copied byte for byte from
// `tests/e2e/fixtures/custom-endpoint-captures/`.

const capture_text =
    \\event: message_start
    \\data: {"type":"message_start","message":{"id":"msg_a4216e0d39afa02d74232fc3","type":"message","role":"assistant","model":"qwen2.5:0.5b","content":[],"usage":{"input_tokens":8,"output_tokens":0}}}
    \\
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Ok"}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"."}}
    \\
    \\event: content_block_stop
    \\data: {"type":"content_block_stop","index":0}
    \\
    \\event: message_delta
    \\data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":1,"cache_read_input_tokens":35,"output_tokens":3}}
    \\
    \\event: message_stop
    \\data: {"type":"message_stop"}
    \\
    \\
;

const capture_tool_call =
    \\event: message_start
    \\data: {"type":"message_start","message":{"id":"msg_cc33b8e610e660f53533fcfb","type":"message","role":"assistant","model":"qwen2.5:1.5b","content":[],"usage":{"input_tokens":37,"output_tokens":0}}}
    \\
    \\event: content_block_start
    \\data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call_xtq9b61r","name":"read_file","input":{}}}
    \\
    \\event: content_block_delta
    \\data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/home/user/note.txt\"}"}}
    \\
    \\event: content_block_stop
    \\data: {"type":"content_block_stop","index":0}
    \\
    \\event: message_delta
    \\data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":1,"cache_read_input_tokens":151,"output_tokens":24}}
    \\
    \\event: message_stop
    \\data: {"type":"message_stop"}
    \\
    \\
;

const capture_unknown_model =
    \\{"type":"error","error":{"type":"not_found_error","message":"model 'no-such-model' not found"},"request_id":"req_e9d719bfd8eea9534a9e8ba2"}
;

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

const test_start =
    \\{"type":"message_start","message":{"id":"msg-1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":4,"output_tokens":0}}}
;
const test_text_start =
    \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
;
const test_text_delta =
    \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}
;
const test_stop_0 =
    \\{"type":"content_block_stop","index":0}
;
const test_end_turn =
    \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}
;
const test_tool_use_stop =
    \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}
;
const test_message_stop =
    \\{"type":"message_stop"}
;
const test_tool_start =
    \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}
;
const test_tool_delta =
    \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"x\"}"}}
;
const test_text_wire = sse_wire(&.{ test_start, test_text_start, test_text_delta, test_stop_0, test_end_turn, test_message_stop });
const test_tool_wire = sse_wire(&.{ test_start, test_tool_start, test_tool_delta, test_stop_0, test_tool_use_stop, test_message_stop });

const test_thinking_wire = sse_wire(&.{
    test_start,
    \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
    ,
    \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"I should "}}
    ,
    \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"read it."}}
    ,
    \\{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-1"}}
    ,
    test_stop_0,
    \\{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"opaque"}}
    ,
    \\{"type":"content_block_stop","index":1}
    ,
    \\{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}
    ,
    \\{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Reading."}}
    ,
    \\{"type":"content_block_stop","index":2}
    ,
    \\{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}
    ,
    \\{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}
    ,
    \\{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"\"x\"}"}}
    ,
    \\{"type":"content_block_stop","index":3}
    ,
    test_tool_use_stop,
    test_message_stop,
});
const test_thinking_state =
    \\[{"type":"thinking","thinking":"I should read it.","signature":"sig-1"},{"type":"redacted_thinking","data":"opaque"}]
;

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
        .model = "claude-local",
        .instructions = &.{ .{ .role = .system, .content = "first" }, .{ .role = .system, .content = "second" } },
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

fn test_provider() model_provider.ProviderId {
    var provider = model_provider.parse("local").?;
    provider.configured.binding = @splat(1);
    return provider;
}

fn test_consume(alloc: Allocator, wire: []const u8, request: stream_provider.RequestData, events: ?stream_provider.EventSink) Error!stream_provider.Result {
    var source = std.Io.Reader.fixed(wire);
    const cancelled = std.atomic.Value(bool).init(false);
    return consume_stream(alloc, &source, request, .{}, events, &cancelled, null);
}

fn test_accept(reducer: *Reducer, data: []const u8) Error!void {
    _ = try reducer.accept(data, false);
}

/// Every event the stream presented, in order.
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

test "anthropic messages reads the recorded text stream in any read size" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 854), capture_text.len);
    for ([_]usize{ 1, 2, 7, 31, 1024 }) |size| {
        const buffer = try alloc.alloc(u8, size);
        defer alloc.free(buffer);
        var fixed = std.Io.Reader.fixed(capture_text);
        var source = fixed.limited(.unlimited, buffer);
        var recorder: Recorder = .{ .alloc = alloc };
        defer recorder.deinit();
        const cancelled = std.atomic.Value(bool).init(false);
        var result = try consume_stream(alloc, &source.interface, test_request(), .{}, recorder.sink(), &cancelled, null);
        defer result.deinit(alloc);
        const completion = result.completed.completion;
        try std.testing.expectEqualStrings("Ok.", completion.content.?);
        try std.testing.expectEqualStrings("Ok.", recorder.content.items);
        try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
        try std.testing.expectEqualStrings("end_turn", completion.finish_reason_raw.slice());
        try std.testing.expectEqualStrings("msg_a4216e0d39afa02d74232fc3", completion.generation_id.?);
        try std.testing.expectEqual(@as(usize, 0), completion.tool_calls.len);
        try std.testing.expect(completion.provider_state_json == null);
        // The final event's counts win: 1 new prompt token and 35 cached.
        try std.testing.expectEqual(@as(?u64, 36), completion.usage.input_tokens);
        try std.testing.expectEqual(@as(?u64, 35), completion.usage.cache_read_tokens);
        try std.testing.expectEqual(@as(?u64, null), completion.usage.cache_write_tokens);
        try std.testing.expectEqual(@as(?u64, 3), completion.usage.output_tokens);
    }
}

test "anthropic messages reads the recorded tool-call stream" {
    const alloc = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 832), capture_tool_call.len);
    var recorder: Recorder = .{ .alloc = alloc };
    defer recorder.deinit();
    var result = try test_consume(alloc, capture_tool_call, test_tool_request(), recorder.sink());
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expect(completion.content == null);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqual(@as(usize, 1), completion.tool_calls.len);
    const call = completion.tool_calls[0];
    try std.testing.expectEqualStrings("call_xtq9b61r", call.id);
    try std.testing.expectEqualStrings("read_file", call.name);
    try std.testing.expectEqualStrings("{\"path\":\"/home/user/note.txt\"}", call.arguments_json);
    try std.testing.expectEqualStrings("call_xtq9b61r:read_file;", recorder.started.items);
    try std.testing.expectEqualStrings(call.arguments_json, recorder.tool_input.items);
    try std.testing.expectEqual(@as(?u64, 152), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 151), completion.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, 24), completion.usage.output_tokens);
}

test "anthropic messages builds the exact body for a full conversation" {
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

    const tool_images = [_]types.ToolImage{.{ .data = @constCast("aGVsbG8"), .mime_type = @constCast("image/png") }};
    var request = test_tool_request();
    request.messages = &.{
        .{ .role = .user, .content = "what is this", .images = &.{attachment} },
        .{ .role = .assistant, .content = "Reading.", .tool_calls = &.{
            .{ .id = "call-1", .name = "read_file", .arguments_json = "{\"path\":\"a\"}" },
            .{ .id = "call-2", .name = "shell", .arguments_json = "{\"request\":{\"command\":\"pwd\"}}" },
        } },
        .{ .role = .tool, .tool_call_id = "call-1", .tool_name = "read_file", .content = "file text", .tool_result_memory = .{ .tool_images = &tool_images } },
        .{ .role = .tool, .tool_call_id = "call-2", .tool_name = "shell", .content = "command failed", .tool_result_status = .failure },
        .{ .role = .user, .content = "continue" },
    };
    const body = try build_request(alloc, request, .{ .tool_choice_mode = .send });
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{ .duplicate_field_behavior = .@"error" });
    defer parsed.deinit();
    const root = parsed.value.object;
    try expect_keys(root, &.{ "model", "max_tokens", "stream", "system", "messages", "tools", "tool_choice" });
    try std.testing.expectEqualStrings("claude-local", root.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 4096), root.get("max_tokens").?.integer);
    try std.testing.expect(root.get("stream").?.bool);
    try std.testing.expectEqualStrings("first\n\nsecond", root.get("system").?.string);

    const messages = root.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    for (messages, [_][]const u8{ "user", "assistant", "user" }) |message, role| {
        try expect_keys(message.object, &.{ "role", "content" });
        try std.testing.expectEqualStrings(role, message.object.get("role").?.string);
    }

    const asked = messages[0].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), asked.len);
    try expect_keys(asked[0].object, &.{ "type", "text" });
    try std.testing.expectEqualStrings("what is this", asked[0].object.get("text").?.string);
    try expect_keys(asked[1].object, &.{ "type", "source" });
    try std.testing.expectEqualStrings("image", asked[1].object.get("type").?.string);
    const source = asked[1].object.get("source").?.object;
    try expect_keys(source, &.{ "type", "media_type", "data" });
    try std.testing.expectEqualStrings("base64", source.get("type").?.string);
    try std.testing.expectEqualStrings("image/png", source.get("media_type").?.string);
    try std.testing.expectEqualStrings(png_b64, source.get("data").?.string);

    const answered = messages[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), answered.len);
    try std.testing.expectEqualStrings("Reading.", answered[0].object.get("text").?.string);
    for (answered[1..], [_][]const u8{ "call-1", "call-2" }, [_][]const u8{ "read_file", "shell" }) |block, id, name| {
        try expect_keys(block.object, &.{ "type", "id", "name", "input" });
        try std.testing.expectEqualStrings("tool_use", block.object.get("type").?.string);
        try std.testing.expectEqualStrings(id, block.object.get("id").?.string);
        try std.testing.expectEqualStrings(name, block.object.get("name").?.string);
    }
    try std.testing.expectEqualStrings("a", answered[1].object.get("input").?.object.get("path").?.string);
    try std.testing.expectEqualStrings("pwd", answered[2].object.get("input").?.object.get("request").?.object.get("command").?.string);

    // Both results and the follow-up share one user turn, results first.
    const results = messages[2].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try expect_keys(results[0].object, &.{ "type", "tool_use_id", "content" });
    try std.testing.expectEqualStrings("tool_result", results[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("call-1", results[0].object.get("tool_use_id").?.string);
    const parts = results[0].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("file text", parts[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("image", parts[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("aGVsbG8", parts[1].object.get("source").?.object.get("data").?.string);
    try expect_keys(results[1].object, &.{ "type", "tool_use_id", "content", "is_error" });
    try std.testing.expectEqualStrings("call-2", results[1].object.get("tool_use_id").?.string);
    try std.testing.expectEqualStrings("command failed", results[1].object.get("content").?.string);
    try std.testing.expect(results[1].object.get("is_error").?.bool);
    try std.testing.expectEqualStrings("continue", results[2].object.get("text").?.string);

    const tools = root.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    for (tools, [_][]const u8{ "read_file", "shell" }) |tool, name| {
        try expect_keys(tool.object, &.{ "name", "description", "input_schema" });
        try std.testing.expectEqualStrings(name, tool.object.get("name").?.string);
        try std.testing.expectEqualStrings("object", tool.object.get("input_schema").?.object.get("type").?.string);
    }
    try expect_keys(root.get("tool_choice").?.object, &.{"type"});
    try std.testing.expectEqualStrings("auto", root.get("tool_choice").?.object.get("type").?.string);
}

test "anthropic messages merges consecutive roles and starts with a user turn" {
    const alloc = std.testing.allocator;
    var request = test_request();
    request.instructions = &.{};
    request.messages = &.{
        .{ .role = .user, .content = "a" },
        .{ .role = .user, .content = "b" },
        .{ .role = .assistant, .content = "c" },
        // Nothing to send, so the turns around it merge.
        .{ .role = .assistant, .content = "" },
        .{ .role = .assistant, .content = "d" },
        .{ .role = .user, .content = "e" },
    };
    const body = try build_request(alloc, request, .{});
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        \\{"model":"claude-local","max_tokens":4096,"stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]},{"role":"assistant","content":[{"type":"text","text":"c"},{"type":"text","text":"d"}]},{"role":"user","content":[{"type":"text","text":"e"}]}]}
    , body);
    request.messages = &.{ .{ .role = .assistant, .content = "first" }, .{ .role = .user, .content = "then" } };
    try std.testing.expectError(error.InvalidProviderPrompt, build_request(alloc, request, .{}));
    request.messages = &.{ .{ .role = .assistant, .content = "" }, .{ .role = .user, .content = "then" } };
    const skipped = try build_request(alloc, request, .{});
    defer alloc.free(skipped);
    try std.testing.expect(std.mem.find(u8, skipped, "assistant") == null);
    // The body fx measures without the conversation.
    request.messages = &.{};
    const measured = try build_request(alloc, request, .{});
    defer alloc.free(measured);
    try std.testing.expectEqualStrings(
        \\{"model":"claude-local","max_tokens":4096,"stream":true,"messages":[]}
    , measured);
}

test "anthropic messages writes the settings' fields last and a level's fields win" {
    const alloc = std.testing.allocator;
    const fields: request_fragment.Fragment = .{ .fields = &.{
        .{ .key = "temperature", .value_json = "0.2" },
        .{ .key = "top_k", .value_json = "5" },
    } };
    const level: request_fragment.Fragment = .{ .fields = &.{
        .{ .key = "thinking", .value_json = "{\"type\":\"enabled\",\"budget_tokens\":1024}" },
        .{ .key = "temperature", .value_json = "1" },
    } };
    var request = test_tool_request();
    request.provider_options.reasoning = types.ReasoningEffort.literal("high");
    const body = try build_request(alloc, request, .{ .tool_choice_mode = .send, .request_fields = fields, .effort_fields = level });
    defer alloc.free(body);
    try std.testing.expect(std.mem.endsWith(u8, body, "\"tool_choice\":{\"type\":\"auto\"},\"top_k\":5,\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":1024},\"temperature\":1}"));
    // Without an effort the level's fields stay out.
    request.provider_options.reasoning = null;
    const plain = try build_request(alloc, request, .{ .tool_choice_mode = .send, .request_fields = fields, .effort_fields = level });
    defer alloc.free(plain);
    try std.testing.expect(std.mem.endsWith(u8, plain, "\"tool_choice\":{\"type\":\"auto\"},\"temperature\":0.2,\"top_k\":5}"));
}

test "anthropic messages refuses options, replay, and history it cannot send" {
    const alloc = std.testing.allocator;
    var request = test_request();
    // A level the model's settings do not declare is refused, not dropped.
    request.provider_options.reasoning = types.ReasoningEffort.literal("high");
    try std.testing.expectError(error.UnsupportedProviderOption, build_request(alloc, request, .{}));
    request.provider_options = .{ .fast = true };
    try std.testing.expectError(error.UnsupportedProviderOption, build_request(alloc, request, .{}));
    request.provider_options = .{ .prompt_caching = true };
    try std.testing.expectError(error.UnsupportedProviderOption, build_request(alloc, request, .{}));
    request.provider_options = .{ .provider_order = &.{"anthropic"} };
    try std.testing.expectError(error.UnsupportedProviderOption, build_request(alloc, request, .{}));
    request = test_request();
    request.max_output_tokens = 0;
    try std.testing.expectError(error.InvalidOutputLimit, build_request(alloc, request, .{}));
    request = test_request();
    request.model = "";
    try std.testing.expectError(error.InvalidModel, build_request(alloc, request, .{}));
    request = test_request();
    request.response_format = .{ .name = "answer", .description = "", .schema = .null };
    try std.testing.expectError(error.UnsupportedResponseFormat, build_request(alloc, request, .{}));
    // Replay needs the endpoint it was recorded for.
    const provider = test_provider();
    request = test_request();
    request.messages = &.{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "ok", .provider_replay = .{ .source = .{ .provider = provider, .model = "claude-local" }, .parts_json = test_thinking_state } },
        .{ .role = .user, .content = "more" },
    };
    try std.testing.expectError(error.UnsupportedReplay, build_request(alloc, request, .{}));
    for ([_][]const u8{ "{", "[]", "{}", "[{\"type\":\"thinking\",\"thinking\":\"x\"}]", "[{\"type\":\"text\",\"text\":\"x\"}]", "[{\"type\":\"redacted_thinking\",\"data\":\"x\",\"extra\":1}]" }) |raw| {
        request.messages = &.{
            .{ .role = .user, .content = "hi" },
            .{ .role = .assistant, .content = "ok", .provider_replay = .{ .source = .{ .provider = provider, .model = "claude-local" }, .parts_json = raw } },
        };
        try std.testing.expectError(error.InvalidProviderState, build_request(alloc, request, .{ .provider = &provider }));
    }
    // `tool_use.input` must be an object.
    request = test_tool_request();
    request.messages = &.{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "call-1", .name = "read_file", .arguments_json = "[]" }} },
        .{ .role = .tool, .tool_call_id = "call-1", .tool_name = "read_file", .content = "result" },
    };
    try std.testing.expectError(error.InvalidToolArguments, build_request(alloc, request, .{}));
}

test "anthropic messages tool choice controls" {
    const alloc = std.testing.allocator;
    for ([_]types.ToolChoice{ .auto, .none, .required }) |choice| for ([_]configured_provider.ToolChoiceMode{ .omit, .send }) |mode| {
        var request = test_tool_request();
        request.tool_choice = choice;
        request.max_output_tokens = 73;
        const body = try build_request(alloc, request, .{ .tool_choice_mode = mode });
        defer alloc.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
        defer parsed.deinit();
        const fields = parsed.value.object;
        try std.testing.expectEqual(choice != .none, fields.get("tools") != null);
        try std.testing.expectEqual(mode == .send and choice != .none, fields.get("tool_choice") != null);
        if (mode == .send and choice != .none) try std.testing.expectEqualStrings(if (choice == .auto) "auto" else "any", fields.get("tool_choice").?.object.get("type").?.string);
        try std.testing.expectEqual(@as(i64, 73), fields.get("max_tokens").?.integer);
    };
    var request = test_request();
    request.tool_choice = .required;
    try std.testing.expectError(error.RequiredToolMissing, build_request(alloc, request, .{}));
    request = test_tool_request();
    request.tool_choice = .none;
    try std.testing.expectError(error.UnexpectedToolCall, test_consume(alloc, test_tool_wire, request, null));
    request.tool_choice = .required;
    try std.testing.expectError(error.RequiredToolMissing, test_consume(alloc, test_text_wire, request, null));
}

test "anthropic messages thinking blocks round-trip through provider state" {
    const alloc = std.testing.allocator;
    const provider = test_provider();
    var recorder: Recorder = .{ .alloc = alloc };
    defer recorder.deinit();
    var result = try test_consume(alloc, test_thinking_wire, test_tool_request(), recorder.sink());
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings(test_thinking_state, completion.provider_state_json.?);
    try std.testing.expectEqualStrings("I should read it.", recorder.reasoning.items);
    try std.testing.expectEqualStrings("Reading.", completion.content.?);
    try std.testing.expectEqualStrings("{\"path\":\"x\"}", completion.tool_calls[0].arguments_json);

    const replay: types.ProviderReplay = .{ .source = .{ .provider = provider, .model = "claude-local" }, .parts_json = completion.provider_state_json.? };
    try std.testing.expect((try project_replay(alloc, replay, completion.tool_calls, false, true)).?.parts_json.ptr == replay.parts_json.ptr);
    try std.testing.expect(try project_replay(alloc, replay, completion.tool_calls, true, false) == null);
    try std.testing.expect(try project_replay(alloc, null, &.{}, true, true) == null);
    try std.testing.expectError(error.InvalidProviderState, project_replay(alloc, .{ .source = .{ .provider = .gateway, .model = "claude-local" }, .parts_json = replay.parts_json }, &.{}, true, true));

    var request = test_tool_request();
    request.messages = &.{
        .{ .role = .user, .content = "read it" },
        .{ .role = .assistant, .content = completion.content, .tool_calls = completion.tool_calls, .provider_replay = replay },
        .{ .role = .tool, .tool_call_id = "toolu_1", .tool_name = "read_file", .content = "contents" },
    };
    const body = try build_request(alloc, request, .{ .provider = &provider });
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const blocks = parsed.value.object.get("messages").?.array.items[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), blocks.len);
    const sent = try std.json.Stringify.valueAlloc(alloc, blocks[0..2], .{});
    defer alloc.free(sent);
    try std.testing.expectEqualStrings(test_thinking_state, sent);
    try std.testing.expectEqualStrings("text", blocks[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("tool_use", blocks[3].object.get("type").?.string);

    // Replay recorded for another model stays home.
    request.model = "another-model";
    const other = try build_request(alloc, request, .{ .provider = &provider });
    defer alloc.free(other);
    try std.testing.expect(std.mem.find(u8, other, "thinking") == null);
    try std.testing.expect(request.messages[1].provider_replay.?.parts_json.ptr == replay.parts_json.ptr);
}

test "anthropic messages structured output is a forced tool whose input is the reply" {
    const alloc = std.testing.allocator;
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"object\",\"properties\":{\"records\":{\"type\":\"array\"}}}", .{});
    defer schema.deinit();
    var pixels = [_]u8{ 1, 2, 3 };
    const snapshots = [_]image_attachments.VerifiedSnapshot{.{ .bytes = &pixels, .media_type = "image/png" }};
    var request = test_tool_request();
    request.tool_choice = .none;
    request.messages = &.{ .{ .role = .user, .content = "earlier" }, .{ .role = .assistant, .content = "ok" }, .{ .role = .user, .content = "describe image 1" } };
    request.response_format = .{ .name = "vision_result", .description = "One record per image", .schema = schema.value };
    request.verified_images = &snapshots;
    // Forced even when the connection omits tool choice.
    const body = try build_request(alloc, request, .{});
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const tools = root.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try expect_keys(tools[0].object, &.{ "name", "description", "input_schema" });
    try std.testing.expectEqualStrings("vision_result", tools[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("One record per image", tools[0].object.get("description").?.string);
    try std.testing.expectEqualStrings("array", tools[0].object.get("input_schema").?.object.get("properties").?.object.get("records").?.object.get("type").?.string);
    const choice = root.get("tool_choice").?.object;
    try expect_keys(choice, &.{ "type", "name" });
    try std.testing.expectEqualStrings("tool", choice.get("type").?.string);
    try std.testing.expectEqualStrings("vision_result", choice.get("name").?.string);
    const messages = root.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    const parts = messages[2].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("describe image 1", parts[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("AQID", parts[1].object.get("source").?.object.get("data").?.string);

    const wire = sse_wire(&.{
        test_start,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"vision_result","input":{}}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"records\":"}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"[]}"}}
        ,
        test_stop_0,
        test_tool_use_stop,
        test_message_stop,
    });
    var recorder: Recorder = .{ .alloc = alloc };
    defer recorder.deinit();
    var result = try test_consume(alloc, wire, request, recorder.sink());
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("{\"records\":[]}", completion.content.?);
    try std.testing.expectEqual(@as(usize, 0), completion.tool_calls.len);
    try std.testing.expectEqual(types.ProviderFinishReason.stop, completion.finish_reason.?);
    try std.testing.expectEqualStrings("", recorder.started.items);
    try std.testing.expectEqualStrings("", recorder.tool_input.items);
    try std.testing.expectEqualStrings("", recorder.content.items);
    // A server that answers in text instead still answers.
    var text_result = try test_consume(alloc, test_text_wire, request, null);
    defer text_result.deinit(alloc);
    try std.testing.expectEqualStrings("hello", text_result.completed.completion.content.?);
    // Only the forced tool may be called.
    try std.testing.expectError(error.UnexpectedToolCall, test_consume(alloc, test_tool_wire, request, null));
}

test "anthropic messages error events fail the reply and a stream must reach message_stop" {
    const alloc = std.testing.allocator;
    for ([_]struct { event: []const u8, kind: stream_provider.FailureKind }{
        .{ .event = "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}", .kind = .server_error },
        .{ .event = "{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Slow down\"}}", .kind = .rate_limited },
        .{ .event = capture_unknown_model, .kind = .provider_error },
        .{ .event = "{\"type\":\"error\"}", .kind = .provider_error },
    }) |case| for ([_]bool{ false, true }) |started| {
        const wire = try test_wire(alloc, if (started) &.{ test_start, test_text_start, test_text_delta, case.event, test_message_stop } else &.{case.event});
        defer alloc.free(wire);
        var result = try test_consume(alloc, wire, test_request(), null);
        defer result.deinit(alloc);
        try std.testing.expectEqual(case.kind, result.failed.kind);
        try std.testing.expectEqualStrings(case.event, result.failed.detail.?);
    };
    for ([_][]const []const u8{
        &.{},
        &.{test_start},
        &.{ test_start, test_text_start, test_text_delta, test_stop_0, test_end_turn },
    }) |events| {
        const wire = try test_wire(alloc, events);
        defer alloc.free(wire);
        try std.testing.expectError(error.IncompleteStream, test_consume(alloc, wire, test_request(), null));
    }
    // An event that is cut off before its blank line is not an event.
    try std.testing.expectError(error.IncompleteStream, test_consume(alloc, test_text_wire[0 .. test_text_wire.len - 1], test_request(), null));
    // message_stop ends the reply; nothing after it is read.
    var result = try test_consume(alloc, test_text_wire ++ "data: not json\n\n", test_request(), null);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("hello", result.completed.completion.content.?);
    // A finished reply needs a stop reason.
    try std.testing.expectError(error.InvalidFinishReason, test_consume(alloc, sse_wire(&.{ test_start, test_message_stop }), test_request(), null));
}

test "anthropic messages counts cached tokens in the prompt and leaves out a bad detail" {
    const alloc = std.testing.allocator;
    const wire = sse_wire(&.{
        \\{"type":"message_start","message":{"id":"msg-1","usage":{"input_tokens":3,"cache_creation_input_tokens":20,"cache_read_input_tokens":100,"output_tokens":1}}}
        ,
        test_text_start,
        test_text_delta,
        test_stop_0,
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}
        ,
        test_message_stop,
    });
    var result = try test_consume(alloc, wire, test_request(), null);
    defer result.deinit(alloc);
    const usage = result.completed.completion.usage;
    try std.testing.expectEqual(@as(?u64, 123), usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 100), usage.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, 20), usage.cache_write_tokens);
    try std.testing.expectEqual(@as(?u64, 9), usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, null), usage.reasoning_tokens);

    const bad = sse_wire(&.{
        \\{"type":"message_start","message":{"id":"msg-1","usage":{"input_tokens":3,"cache_creation_input_tokens":-2,"cache_read_input_tokens":"many","output_tokens":1}}}
        ,
        test_text_start,
        test_text_delta,
        test_stop_0,
        test_end_turn,
        test_message_stop,
    });
    var left_out = try test_consume(alloc, bad, test_request(), null);
    defer left_out.deinit(alloc);
    try std.testing.expectEqual(@as(?u64, 3), left_out.completed.completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, null), left_out.completed.completion.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, null), left_out.completed.completion.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(?u64, 2), left_out.completed.completion.usage.output_tokens);
    // A negative main count is not a count.
    const negative = sse_wire(&.{
        \\{"type":"message_start","message":{"id":"msg-1","usage":{"input_tokens":-3}}}
        ,
    });
    try std.testing.expectError(error.InvalidEvent, test_consume(alloc, negative, test_request(), null));
}

test "anthropic messages maps stop reasons and checks them against the calls" {
    const alloc = std.testing.allocator;
    for ([_]struct { raw: []const u8, reason: types.ProviderFinishReason }{
        .{ .raw = "end_turn", .reason = .stop },
        .{ .raw = "stop_sequence", .reason = .stop },
        .{ .raw = "max_tokens", .reason = .length },
        .{ .raw = "refusal", .reason = .content_filter },
        .{ .raw = "pause_turn", .reason = .provider_error },
    }) |case| {
        const delta = try alloc.print("{{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}}}}", .{case.raw});
        defer alloc.free(delta);
        const wire = try test_wire(alloc, &.{ test_start, test_text_start, test_text_delta, test_stop_0, delta, test_message_stop });
        defer alloc.free(wire);
        var result = try test_consume(alloc, wire, test_request(), null);
        defer result.deinit(alloc);
        try std.testing.expectEqual(case.reason, result.completed.completion.finish_reason.?);
        try std.testing.expectEqualStrings(case.raw, result.completed.completion.finish_reason_raw.slice());
    }
    // A finished reply's reason agrees with its calls.
    try std.testing.expectError(error.InconsistentFinishReason, test_consume(alloc, sse_wire(&.{ test_start, test_tool_start, test_tool_delta, test_stop_0, test_end_turn, test_message_stop }), test_tool_request(), null));
    try std.testing.expectError(error.InconsistentFinishReason, test_consume(alloc, sse_wire(&.{ test_start, test_text_start, test_text_delta, test_stop_0, test_tool_use_stop, test_message_stop }), test_tool_request(), null));
    try std.testing.expectError(error.InconsistentFinishReason, test_consume(alloc, sse_wire(&.{ test_start, test_end_turn, test_tool_use_stop, test_message_stop }), test_request(), null));
    // A cut-off reply keeps its partial call for the agent loop to discard.
    var cut = try test_consume(alloc, sse_wire(&.{
        test_start,
        test_tool_start,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"pa"}}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}
        ,
        test_message_stop,
    }), test_tool_request(), null);
    defer cut.deinit(alloc);
    try std.testing.expectEqual(types.ProviderFinishReason.length, cut.completed.completion.finish_reason.?);
    try std.testing.expectEqualStrings("{\"pa", cut.completed.completion.tool_calls[0].arguments_json);
}

test "anthropic messages returns malformed tool arguments as sent" {
    const alloc = std.testing.allocator;
    for ([_]struct { partial: []const u8, arguments: []const u8 }{
        .{ .partial = "", .arguments = "{}" },
        .{ .partial = "{", .arguments = "{" },
        .{ .partial = "[]", .arguments = "[]" },
        .{ .partial = "{}junk", .arguments = "{}junk" },
        .{ .partial = "{\"x\":1,\"x\":2}", .arguments = "{\"x\":1,\"x\":2}" },
    }) |case| {
        const partial = try std.json.Stringify.valueAlloc(alloc, case.partial, .{});
        defer alloc.free(partial);
        const delta = try alloc.print("{{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}", .{partial});
        defer alloc.free(delta);
        const wire = try test_wire(alloc, &.{ test_start, test_tool_start, delta, test_stop_0, test_tool_use_stop, test_message_stop });
        defer alloc.free(wire);
        var result = try test_consume(alloc, wire, test_tool_request(), null);
        defer result.deinit(alloc);
        try std.testing.expectEqualStrings(case.arguments, result.completed.completion.tool_calls[0].arguments_json);
    }
    // A server that sends the whole input when the block starts.
    var whole = try test_consume(alloc, sse_wire(&.{
        test_start,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file","input":{"path":"y"}}}
        ,
        test_stop_0,
        test_tool_use_stop,
        test_message_stop,
    }), test_tool_request(), null);
    defer whole.deinit(alloc);
    try std.testing.expectEqualStrings("{\"path\":\"y\"}", whole.completed.completion.tool_calls[0].arguments_json);
}

test "anthropic messages ignores unknown events blocks and deltas but not misplaced ones" {
    const alloc = std.testing.allocator;
    const wire = sse_wire(&.{
        \\{"type":"ping"}
        ,
        test_start,
        \\{"type":"future_event","detail":{"x":1}}
        ,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"query\":\"zig\"}"}}
        ,
        test_stop_0,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location"}}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"hello"}}
        ,
        \\{"type":"ping"}
        ,
        \\{"type":"content_block_stop","index":1}
        ,
        test_end_turn,
        test_message_stop,
    });
    var result = try test_consume(alloc, wire, test_request(), null);
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("hello", result.completed.completion.content.?);
    try std.testing.expectEqual(@as(usize, 0), result.completed.completion.tool_calls.len);
    for ([_]struct { events: []const []const u8, failure: Error }{
        .{ .events = &.{"not json"}, .failure = error.MalformedMessagesEvent },
        .{ .events = &.{"{\"type\":\"ping\",\"type\":\"ping\"}"}, .failure = error.InvalidEvent },
        .{ .events = &.{"[]"}, .failure = error.InvalidEvent },
        .{ .events = &.{test_text_start}, .failure = error.InvalidEvent },
        .{ .events = &.{ test_start, test_start }, .failure = error.InvalidEvent },
        .{ .events = &.{ test_start, test_text_delta }, .failure = error.InvalidEvent },
        .{ .events = &.{ test_start, test_text_start, test_stop_0, test_text_delta }, .failure = error.InvalidEvent },
        .{ .events = &.{ test_start, test_tool_start, test_text_delta }, .failure = error.InvalidEvent },
        .{ .events = &.{ test_start, "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}" }, .failure = error.InvalidEvent },
        .{ .events = &.{ test_start, test_end_turn, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}" }, .failure = error.InconsistentFinishReason },
        .{ .events = &.{ test_start, test_tool_start, "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"shell\",\"input\":{}}}" }, .failure = error.ConflictingIdentity },
    }) |case| {
        const bad = try test_wire(alloc, case.events);
        defer alloc.free(bad);
        try std.testing.expectError(case.failure, test_consume(alloc, bad, test_tool_request(), null));
    }
}

test "anthropic messages withholds images from denied tool results" {
    const alloc = std.testing.allocator;
    const tool_images = [_]types.ToolImage{.{ .data = @constCast("aGVsbG8"), .mime_type = @constCast("image/png") }};
    const denial = "{\"error\":{\"type\":\"tool_permission_denied\",\"reason\":\"user_denied\"}}";
    var request = test_tool_request();
    request.messages = &.{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "call-1", .name = "read_file", .arguments_json = "{}" }} },
        .{ .role = .tool, .tool_call_id = "call-1", .tool_name = "read_file", .content = denial, .tool_result_status = .failure, .tool_result_memory = .{ .tool_images = &tool_images } },
    };
    const body = try build_request(alloc, request, .{});
    defer alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("messages").?.array.items[2].object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings(denial, result.get("content").?.string);
    try std.testing.expect(result.get("is_error").?.bool);
    try std.testing.expect(std.mem.find(u8, body, "aGVsbG8") == null);
}

test "anthropic messages caps events content arguments tools blocks reasoning and nesting" {
    const alloc = std.testing.allocator;
    const thinking_start = "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"long thought\"}}";
    for ([_]struct { limits: Limits, events: []const []const u8, failure: Error }{
        .{ .limits = .{ .event_bytes = 8 }, .events = &.{test_start}, .failure = error.EventTooLarge },
        .{ .limits = .{ .total_wire_bytes = 8 }, .events = &.{test_start}, .failure = error.StreamTooLarge },
        .{ .limits = .{ .events = 1 }, .events = &.{ test_start, test_text_start }, .failure = error.TooManyEvents },
        .{ .limits = .{ .identity_bytes = 2 }, .events = &.{test_start}, .failure = error.IdentityTooLarge },
        .{ .limits = .{ .content_bytes = 4 }, .events = &.{ test_start, test_text_start, test_text_delta }, .failure = error.ContentTooLarge },
        .{ .limits = .{ .arguments_bytes = 4 }, .events = &.{ test_start, test_tool_start, test_tool_delta }, .failure = error.ArgumentsTooLarge },
        .{ .limits = .{ .tool_calls = 0 }, .events = &.{ test_start, test_tool_start }, .failure = error.TooManyTools },
        .{ .limits = .{ .blocks = 0 }, .events = &.{ test_start, test_text_start }, .failure = error.TooManyBlocks },
        .{ .limits = .{ .reasoning_bytes = 4 }, .events = &.{ test_start, thinking_start }, .failure = error.ReplayTooLarge },
        .{ .limits = .{}, .events = &.{text_utils.repeat("[", 65) ++ text_utils.repeat("]", 65)}, .failure = error.JsonTooDeep },
    }) |case| {
        const wire = try test_wire(alloc, case.events);
        defer alloc.free(wire);
        var source = std.Io.Reader.fixed(wire);
        const cancelled = std.atomic.Value(bool).init(false);
        try std.testing.expectError(case.failure, consume_stream(alloc, &source, test_tool_request(), case.limits, null, &cancelled, null));
    }
    // The limits are inclusive.
    var source = std.Io.Reader.fixed(test_text_wire);
    const cancelled = std.atomic.Value(bool).init(false);
    var result = try consume_stream(alloc, &source, test_request(), .{ .total_wire_bytes = test_text_wire.len, .events = 6, .content_bytes = 5, .blocks = 1 }, null, &cancelled, null);
    defer result.deinit(alloc);
}

test "anthropic messages cancellation poisons the reducer and stops presentation" {
    const alloc = std.testing.allocator;
    var reducer = try Reducer.init(alloc, test_tool_request(), .{});
    defer reducer.deinit();
    try test_accept(&reducer, test_start);
    try test_accept(&reducer, test_tool_start);
    try std.testing.expectError(error.Cancelled, reducer.accept(test_tool_delta, true));
    try std.testing.expectError(error.StreamClosed, reducer.finish(false));
    var cancelled = std.atomic.Value(bool).init(true);
    var source = std.Io.Reader.fixed(test_text_wire);
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
    const twice = sse_wire(&.{ test_start, test_text_start, test_text_delta, test_text_delta, test_stop_0, test_end_turn, test_message_stop });
    source = std.Io.Reader.fixed(twice);
    try std.testing.expectError(error.Cancelled, consume_stream(alloc, &source, test_request(), .{}, .{ .context = &observer, .emit_fn = Observer.emit_event }, &cancelled, null));
    try std.testing.expectEqual(@as(usize, 1), observer.count);
    var done = try Reducer.init(alloc, test_request(), .{});
    defer done.deinit();
    for ([_][]const u8{ test_start, test_text_start, test_text_delta, test_stop_0, test_end_turn, test_message_stop }) |event| try test_accept(&done, event);
    try std.testing.expectError(error.StreamClosed, done.accept(test_message_stop, false));
}

fn test_build_allocations(alloc: Allocator) !void {
    const provider = test_provider();
    const tool_images = [_]types.ToolImage{.{ .data = @constCast("aGVsbG8"), .mime_type = @constCast("image/png") }};
    var request = test_tool_request();
    request.tool_choice = .required;
    request.provider_options.reasoning = types.ReasoningEffort.literal("high");
    request.messages = &.{
        .{ .role = .user, .content = "read it" },
        .{ .role = .assistant, .content = "Reading.", .tool_calls = &.{.{ .id = "toolu_1", .name = "read_file", .arguments_json = "{\"path\":\"x\"}" }}, .provider_replay = .{ .source = .{ .provider = provider, .model = "claude-local" }, .parts_json = test_thinking_state } },
        .{ .role = .tool, .tool_call_id = "toolu_1", .tool_name = "read_file", .content = "result", .tool_result_memory = .{ .tool_images = &tool_images } },
        .{ .role = .user, .content = "continue" },
        // Ids this API cannot carry get request-local aliases.
        .{ .role = .assistant, .tool_calls = &.{.{ .id = "functions/read:0", .name = "read_file", .arguments_json = "{}" }} },
        .{ .role = .tool, .tool_call_id = "functions/read:0", .content = "failed", .tool_result_status = .failure },
    };
    const options: Options = .{
        .tool_choice_mode = .send,
        .provider = &provider,
        .request_fields = .{ .fields = &.{.{ .key = "temperature", .value_json = "0.2" }} },
        .effort_fields = .{ .fields = &.{.{ .key = "thinking", .value_json = "{\"type\":\"enabled\",\"budget_tokens\":1024}" }} },
    };
    const body = try build_request(alloc, request, options);
    defer alloc.free(body);

    var pixels = [_]u8{ 1, 2, 3 };
    const snapshots = [_]image_attachments.VerifiedSnapshot{.{ .bytes = &pixels, .media_type = "image/png" }};
    var structured = test_request();
    structured.tool_choice = .none;
    structured.response_format = .{ .name = "vision_result", .description = "Records.", .schema = .{ .object = .empty } };
    structured.verified_images = &snapshots;
    const structured_body = try build_request(alloc, structured, .{});
    defer alloc.free(structured_body);
}

test "anthropic messages allocation failures release every partial request" {
    try test_build_allocations(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, test_build_allocations, .{});
}

fn test_consume_allocations(alloc: Allocator) !void {
    var reply = try test_consume(alloc, test_thinking_wire, test_tool_request(), null);
    defer reply.deinit(alloc);
    var failure = try test_consume(alloc, sse_wire(&.{ test_start, test_text_start, test_text_delta, "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"x\"}}" }), test_request(), null);
    defer failure.deinit(alloc);
}

test "anthropic messages allocation failures release every partial reply" {
    try test_consume_allocations(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, test_consume_allocations, .{});
}
