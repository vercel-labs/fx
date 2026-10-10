//! Pure Anthropic Messages protocol: request serialization, SSE reduction, and
//! provider-replay projection. Transport, admission, deadlines, and usage
//! accounting live in `anthropic_messages.zig`; this file owns wire shape only.
//!
//! Structural differences from Chat Completions that this codec owns:
//! - System instructions travel as a top-level `system` string.
//! - Assistant turns carry `thinking`/`redacted_thinking` blocks that must be
//!   replayed verbatim (with signatures) while tool use continues.
//! - Tool calls arrive as `tool_use` content blocks; results are `tool_result`
//!   blocks inside a user message, with images allowed inline.
//! - Usage arrives split across `message_start` and `message_delta` events.
//! - Anthropic tool names forbid dots, so dotted fx identities project onto
//!   `[A-Za-z0-9_-]` wire names and restore inbound.

const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const tool_result_errors = @import("../core/tooling/tool_result_errors.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const tool_call_ids = @import("tool_call_ids.zig");
const sse = @import("sse.zig");
const configured_provider = @import("../core/config/configured_provider.zig");
const model_provider = @import("../core/config/model_provider.zig");

const Allocator = std.mem.Allocator;

pub const ToolChoiceMode = configured_provider.ToolChoiceMode;

pub const Options = struct {
    tool_choice_mode: ToolChoiceMode = .omit,
    /// Borrowed only during serialization; includes the configured authority binding.
    provider: ?*const model_provider.ProviderId = null,
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
    InvalidChunk,
    InvalidFinishReason,
    IncompleteStream,
    ProviderError,
    EventTooLarge,
    StreamTooLarge,
    TooManyEvents,
    TooManyTools,
    IdentityTooLarge,
    ArgumentsTooLarge,
    ContentTooLarge,
    JsonTooDeep,
    Cancelled,
    ReadFailed,
};

pub const Limits = struct {
    event_bytes: usize = 1024 * 1024,
    total_wire_bytes: usize = 64 * 1024 * 1024,
    events: usize = 100_000,
    tool_calls: usize = 128,
    identity_bytes: usize = 1024,
    arguments_bytes: usize = 4 * 1024 * 1024,
    content_bytes: usize = 8 * 1024 * 1024,
    thinking_bytes: usize = types.ProviderReplay.max_bytes,
};

const default_max_tokens: u32 = 8192;
const thinking_budget_tokens: u32 = 32 * 1024;
const min_thinking_budget_tokens: u32 = 1024;
const max_selected_tools = 256;
const max_name_bytes = 64;
const max_history_arguments_bytes = 1024 * 1024;
const max_json_depth = 64;
const association_field = "_tool_call_ids";

const Function = struct {
    name: []const u8,
    description: []const u8,
    schema: union(enum) {
        builtin: model_tool_schema.ObjectSchema,
        dynamic: std.json.Value,
    },
};

fn contains_name(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

/// Anthropic tool names match `[A-Za-z0-9_-]{1,64}`. fx advertises dotted
/// built-in and MCP names, so dots project to underscores on the wire.
fn validate_name(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidToolName;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return error.InvalidToolName;
    }
}

/// Returns a borrow of `name`, or owned storage the caller must free.
fn wire_name(alloc: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '.') == null) return name;
    const owned = try alloc.dupe(u8, name);
    for (owned) |*byte| {
        if (byte.* == '.') byte.* = '_';
    }
    return owned;
}

/// Validates that two distinct source names never collide on the wire.
fn check_wire_names(alloc: Allocator, functions: []const Function) Error!void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var iterator = seen.keyIterator();
        while (iterator.next()) |key| alloc.free(@constCast(key.*));
        seen.deinit(alloc);
    }
    for (functions) |function| {
        const wire = try wire_name(alloc, function.name);
        // Wire names own their storage so the borrowed source name is never
        // captured by the collision map.
        const key = if (wire.ptr == function.name.ptr) try alloc.dupe(u8, wire) else wire;
        errdefer alloc.free(@constCast(key));
        const entry = try seen.getOrPut(alloc, key);
        if (entry.found_existing) return error.InvalidToolSelection;
    }
}

fn append_function(alloc: Allocator, functions: *std.ArrayList(Function), function: Function) Error!void {
    try validate_name(function.name);
    if (functions.items.len == max_selected_tools) return error.TooManyTools;
    for (functions.items) |prior| if (std.mem.eql(u8, prior.name, function.name)) return error.InvalidToolSelection;
    try functions.append(alloc, function);
}

// Provider-native advertisements are not Messages tools. Omit only registered
// provider-executed tools; missing ordinary schemas fail.
fn select_functions(alloc: Allocator, tools: stream_provider.ToolSelection, choice: types.ToolChoice) Error!std.ArrayList(Function) {
    var functions: std.ArrayList(Function) = .empty;
    errdefer functions.deinit(alloc);
    if (choice == .none) return functions;
    if (tools.advertised_names.len > max_selected_tools or tools.advertised_functions.len > max_selected_tools or tools.additional_functions.len > max_selected_tools or tools.selected_dynamic.len > max_selected_tools) return error.TooManyTools;
    for (tools.advertised_names) |name| {
        const function = tools.advertisedFunction(name) orelse {
            const registered = tools.registry.lookup(name) orelse return error.InvalidToolSelection;
            if (registered.provider_executed) continue;
            return error.InvalidToolSelection;
        };
        // A repeated definition must not be selected by accidental first match.
        var matches: usize = 0;
        for (tools.advertised_functions) |candidate| if (std.mem.eql(u8, candidate.name, name)) {
            matches += 1;
        };
        if (matches != 1) return error.InvalidToolSelection;
        try append_function(alloc, &functions, .{ .name = name, .description = function.description, .schema = .{ .builtin = function.input_schema } });
    }
    for (tools.additional_functions) |function| {
        if (contains_name(tools.advertised_names, function.name)) continue;
        try append_function(alloc, &functions, .{ .name = function.name, .description = function.description, .schema = .{ .builtin = function.input_schema } });
    }
    var schema_budget: SchemaBudget = .{};
    for (tools.selected_dynamic) |function| {
        if (contains_name(tools.advertised_names, function.name)) continue;
        if (function.input_schema != .object) return error.InvalidToolSchema;
        try validate_dynamic_schema(function.input_schema, 0, &schema_budget);
        try append_function(alloc, &functions, .{ .name = function.name, .description = function.description, .schema = .{ .dynamic = function.input_schema } });
    }
    if (choice == .required and functions.items.len == 0) return error.RequiredToolMissing;
    return functions;
}

const SchemaBudget = struct {
    nodes: usize = 16 * 1024,
    string_bytes: usize = 1024 * 1024,

    fn consume_string(self: *SchemaBudget, text: []const u8) Error!void {
        if (text.len > self.string_bytes or !std.unicode.utf8ValidateSlice(text)) return error.InvalidToolSchema;
        self.string_bytes -= text.len;
    }
};

fn validate_dynamic_schema(value: std.json.Value, depth: usize, budget: *SchemaBudget) Error!void {
    if (depth > max_json_depth) return error.JsonTooDeep;
    if (budget.nodes == 0) return error.InvalidToolSchema;
    budget.nodes -= 1;
    switch (value) {
        .object => |fields| {
            var iterator = fields.iterator();
            while (iterator.next()) |entry| {
                try budget.consume_string(entry.key_ptr.*);
                try validate_dynamic_schema(entry.value_ptr.*, depth + 1, budget);
            }
        },
        .array => |items| for (items.items) |item| try validate_dynamic_schema(item, depth + 1, budget),
        .string => |text| try budget.consume_string(text),
        .number_string => return error.InvalidToolSchema,
        .float => |number| if (!std.math.isFinite(number)) return error.InvalidToolSchema,
        .integer, .bool, .null => {},
    }
}

fn validate_request(request: stream_provider.RequestData) Error!void {
    try request.validatePrompt();
    configured_provider.validate_model_id(request.model) catch return error.InvalidModel;
    const options = request.provider_options;
    if (options.fast or options.prompt_caching) return error.UnsupportedProviderOption;
    if (options.provider_order.len != 0) return error.UnsupportedProviderOption;
    if (request.response_format != null) return error.UnsupportedResponseFormat;
    // The vision tool runs through a separate provider request; inline image
    // content on user messages and tool results serializes natively below.
    if (request.vision_mode != .unavailable) return error.UnsupportedVision;
    // Verified snapshots only flow through the vision executor's structured
    // request, which this protocol rejects above via response_format.
    if (request.verified_images != null and request.verified_images.?.len != 0) return error.UnsupportedVision;
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
    var depth: usize = 0;
    var quoted = false;
    var escaped = false;
    for (text) |byte| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') quoted = false;
        } else switch (byte) {
            '"' => quoted = true,
            '{', '[' => {
                if (depth == max_json_depth) return error.JsonTooDeep;
                depth += 1;
            },
            '}', ']' => if (depth > 0) {
                depth -= 1;
            },
            else => {},
        }
    }
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
            try validate_name(call.name);
            if (call.argument_integrity != .valid) return error.InvalidToolArguments;
            if (call.arguments_json.len > max_history_arguments_bytes) return error.ArgumentsTooLarge;
            try validate_arguments(alloc, call.arguments_json);
            const entry = try pending.getOrPut(alloc, call.id);
            if (entry.found_existing) return error.InvalidToolHistory;
            entry.value_ptr.* = call.name;
        }
    }
    if (pending.count() != 0) return error.InvalidToolHistory;
}

/// `thinking`/`redacted_thinking` blocks replay verbatim from provider state;
/// `_tool_call_ids` binds that state to the exact calls it was minted beside.
fn parse_replay(alloc: Allocator, raw: []const u8) Error!std.json.Parsed(std.json.Value) {
    if (raw.len > types.ProviderReplay.max_bytes) return error.ReplayTooLarge;
    try check_json_depth(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderState,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidProviderState;
    const fields = parsed.value.object;
    var iterator = fields.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "thinking")) {
            if (value != .array) return error.InvalidProviderState;
            for (value.array.items) |item| {
                if (item != .object) return error.InvalidProviderState;
                const block = item.object.get("type") orelse return error.InvalidProviderState;
                if (block != .string) return error.InvalidProviderState;
                if (!std.mem.eql(u8, block.string, "thinking") and !std.mem.eql(u8, block.string, "redacted_thinking")) return error.InvalidProviderState;
            }
        } else if (std.mem.eql(u8, key, association_field)) {
            if (value != .array or value.array.items.len > max_selected_tools) return error.InvalidProviderState;
            for (value.array.items, 0..) |id, index| {
                if (id != .string or id.string.len == 0 or id.string.len > 256) return error.InvalidProviderState;
                for (value.array.items[0..index]) |prior| if (std.mem.eql(u8, id.string, prior.string)) return error.InvalidProviderState;
            }
        } else return error.InvalidProviderState;
    }
    if (!fields.contains(association_field)) return error.InvalidProviderState;
    return parsed;
}

fn replay_calls_match(fields: std.json.ObjectMap, calls: []const types.ToolCall) bool {
    const ids = fields.get(association_field).?.array.items;
    if (ids.len != calls.len) return false;
    for (ids, calls) |id, call| if (!std.mem.eql(u8, id.string, call.id)) return false;
    return true;
}

/// Borrows the whole validated sequence or drops it; never edits opaque blocks.
/// Thinking state is structural for Anthropic tool continuations, so it is
/// preserved whenever the calls still match, independent of `reasoning`.
pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, _: bool, reasoning: bool) Error!?types.ProviderReplay {
    _ = reasoning;
    const value = replay orelse return null;
    var parsed = try parse_replay(alloc, value.parts_json);
    defer parsed.deinit();
    return if (replay_calls_match(parsed.value.object, calls)) value else null;
}

/// Writes replayed thinking blocks into the assistant content array and reports
/// how many were emitted so the caller can place separators.
fn write_replay(writer: *std.Io.Writer, alloc: Allocator, message: types.ChatMessage) (Error || std.Io.Writer.Error)!usize {
    const replay = message.provider_replay orelse return 0;
    var parsed = try parse_replay(alloc, replay.parts_json);
    defer parsed.deinit();
    if (!replay_calls_match(parsed.value.object, message.tool_calls)) return error.InvalidProviderState;
    const thinking = parsed.value.object.get("thinking") orelse return 0;
    for (thinking.array.items, 0..) |item, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.Stringify.value(item, .{}, writer);
    }
    return thinking.array.items.len;
}

/// `base64_data` is already encoded (tool-result images ship encoded).
fn write_image_block_encoded(writer: *std.Io.Writer, media_type: []const u8, base64_data: []const u8) !void {
    try writer.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
    try std.json.Stringify.value(media_type, .{}, writer);
    try writer.writeAll(",\"data\":");
    try std.json.Stringify.value(base64_data, .{}, writer);
    try writer.writeAll("}}");
}

/// Raw bytes are base64-encoded in bounded chunks directly into the request.
fn write_image_block_raw(writer: *std.Io.Writer, media_type: []const u8, bytes: []const u8) !void {
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

fn write_text_part(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeByte('}');
}

/// User messages carry image attachments as `image` content blocks.
fn write_user_content_parts(
    writer: *std.Io.Writer,
    alloc: Allocator,
    message: types.ChatMessage,
) !void {
    try writer.writeByte('[');
    var wrote_part = false;
    if (message.content) |content| {
        if (content.len > 0) {
            try write_text_part(writer, content);
            wrote_part = true;
        }
    }
    for (message.images) |image| {
        if (wrote_part) try writer.writeByte(',');
        var snapshot = image_attachments.loadVerifiedSnapshot(alloc, image, .{}) catch return error.ImageUnavailable;
        defer snapshot.deinit(alloc);
        try write_image_block_raw(writer, snapshot.media_type, snapshot.bytes);
        wrote_part = true;
    }
    try writer.writeByte(']');
}

/// Tool results become `tool_result` blocks inside a user-role message; images
/// ride inside the same block natively. Denied results keep their text only.
fn write_tool_result_content(writer: *std.Io.Writer, message: types.ChatMessage, projection: *const tool_call_ids.Projection) !void {
    try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
    try std.json.Stringify.value(projection.resolve(message.tool_call_id.?), .{}, writer);
    try writer.writeAll(",\"content\":[");
    var wrote_part = false;
    if (message.content) |content| {
        if (content.len > 0) {
            try write_text_part(writer, content);
            wrote_part = true;
        }
    }
    const denied = if (message.tool_result_status) |status|
        status == .failure and tool_result_errors.toolPermissionDenialReason(message.content orelse "") != null
    else
        false;
    const images = if (!denied and message.tool_result_memory != null) message.tool_result_memory.?.tool_images else &.{};
    for (images) |image| {
        if (wrote_part) try writer.writeByte(',');
        try write_image_block_encoded(writer, image.mime_type, image.data);
        wrote_part = true;
    }
    try writer.writeByte(']');
    if (message.tool_result_status) |status| {
        if (status == .failure) try writer.writeAll(",\"is_error\":true");
    }
    try writer.writeByte('}');
}

fn write_request(writer: *std.Io.Writer, alloc: Allocator, request: stream_provider.RequestData, options: Options, functions: []const Function, projection: *const tool_call_ids.Projection) !void {
    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, writer);
    const max_tokens = request.max_output_tokens orelse default_max_tokens;
    try writer.writeAll(",\"max_tokens\":");
    try std.json.Stringify.value(max_tokens, .{}, writer);
    try writer.writeAll(",\"stream\":true");
    if (request.instructions.len != 0) {
        var system: std.Io.Writer.Allocating = .init(alloc);
        defer system.deinit();
        var parts: usize = 0;
        for (request.instructions) |message| {
            const text = message.content orelse continue;
            if (parts != 0) try system.writer.writeAll("\n\n");
            try system.writer.writeAll(text);
            parts += 1;
        }
        if (parts != 0) {
            try writer.writeAll(",\"system\":");
            try std.json.Stringify.value(system.written(), .{}, writer);
        }
    }
    try writer.writeAll(",\"messages\":[");
    var count: usize = 0;
    for (request.messages) |message| {
        // Source validation rejects empty assistants; only stripped replay can leave one here.
        if (message.role == .assistant and message.content == null and message.tool_calls.len == 0 and message.provider_replay == null) continue;
        if (count != 0) try writer.writeByte(',');
        count += 1;
        switch (message.role) {
            .user => {
                try writer.writeAll("{\"role\":\"user\",\"content\":");
                try write_user_content_parts(writer, alloc, message);
                try writer.writeByte('}');
            },
            .assistant => {
                try writer.writeAll("{\"role\":\"assistant\",\"content\":[");
                const replay_blocks = try write_replay(writer, alloc, message);
                var wrote_block = replay_blocks != 0;
                if (message.content) |content| {
                    if (content.len > 0) {
                        if (wrote_block) try writer.writeByte(',');
                        try write_text_part(writer, content);
                        wrote_block = true;
                    }
                }
                for (message.tool_calls) |call| {
                    if (wrote_block) try writer.writeByte(',');
                    const wire = try wire_name(alloc, call.name);
                    defer if (wire.ptr != call.name.ptr) alloc.free(@constCast(wire));
                    try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
                    try std.json.Stringify.value(projection.resolve(call.id), .{}, writer);
                    try writer.writeAll(",\"name\":");
                    try std.json.Stringify.value(wire, .{}, writer);
                    try writer.writeAll(",\"input\":");
                    try writer.writeAll(if (call.arguments_json.len != 0) call.arguments_json else "{}");
                    try writer.writeByte('}');
                    wrote_block = true;
                }
                try writer.writeAll("]}");
            },
            .tool => {
                try writer.writeAll("{\"role\":\"user\",\"content\":[");
                try write_tool_result_content(writer, message, projection);
                try writer.writeAll("]}");
            },
            else => {},
        }
    }
    try writer.writeByte(']');
    if (functions.len != 0) {
        try writer.writeAll(",\"tools\":[");
        for (functions, 0..) |function, index| {
            if (index != 0) try writer.writeByte(',');
            const wire = try wire_name(alloc, function.name);
            defer if (wire.ptr != function.name.ptr) alloc.free(@constCast(wire));
            try writer.writeAll("{\"name\":");
            try std.json.Stringify.value(wire, .{}, writer);
            if (function.description.len != 0) {
                try writer.writeAll(",\"description\":");
                try model_tool_schema.writeCappedDescriptionJsonString(alloc, writer, function.description);
            }
            try writer.writeAll(",\"input_schema\":");
            switch (function.schema) {
                .builtin => |schema| try model_tool_schema.writeObjectSchema(alloc, writer, schema),
                .dynamic => |schema| try std.json.Stringify.value(schema, .{}, writer),
            }
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
        // Anthropic defaults tool_choice to auto. `none` is expressed by omitting
        // tools entirely; `any` must always be sent for required calls.
        const parallel_disabled = request.provider_options.parallel_tool_calls == false;
        if (options.tool_choice_mode == .send or request.tool_choice == .required or parallel_disabled) {
            const kind: []const u8 = switch (request.tool_choice) {
                .auto => "auto",
                .none => unreachable,
                .required => "any",
            };
            try writer.writeAll(",\"tool_choice\":{\"type\":");
            try std.json.Stringify.value(kind, .{}, writer);
            if (parallel_disabled) try writer.writeAll(",\"disable_parallel_tool_use\":true");
            try writer.writeByte('}');
        }
    }
    // Forced tool use (`tool_choice:any`) is rejected alongside thinking, so
    // required calls keep their contract and skip the budget instead. The API
    // also requires budget_tokens < max_tokens with a floor of
    // min_thinking_budget_tokens, which small output limits cannot satisfy.
    const wants_thinking = if (request.provider_options.reasoning) |effort| !effort.isDefault() else false;
    if (wants_thinking and request.tool_choice != .required and max_tokens > min_thinking_budget_tokens) {
        const budget = @min(thinking_budget_tokens, @max(min_thinking_budget_tokens, max_tokens / 2));
        try writer.writeAll(",\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":");
        try std.json.Stringify.value(budget, .{}, writer);
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
}

/// Pure Messages serialization. Caller owns the returned bytes. Model IDs are
/// opaque: no catalog lookup, prefix inference, or provider defaults. The API
/// requires `max_tokens`, so the codec falls back to `default_max_tokens`.
/// Deadline enforcement and prepared-body reuse belong to the transport owner.
pub fn build_request(alloc: Allocator, input: stream_provider.RequestData, options: Options) Error![]u8 {
    try validate_request(input);
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
    var functions = try select_functions(alloc, request.tools, request.tool_choice);
    defer functions.deinit(alloc);
    try check_wire_names(alloc, functions.items);
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

const ThinkingAccumulator = struct {
    text: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,

    fn deinit(self: *ThinkingAccumulator, alloc: Allocator) void {
        self.text.deinit(alloc);
        self.signature.deinit(alloc);
        self.* = undefined;
    }
};

const ToolAccumulator = struct {
    id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *ToolAccumulator, alloc: Allocator) void {
        self.id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
        self.* = undefined;
    }
};

/// Consumes an Anthropic Messages SSE stream into one `stream_provider.Result`.
/// Framing comes from the shared `sse.Reader`; this reducer owns event typing,
/// block accumulation, and replay-state minting. Caller frees the result.
pub fn consume_stream(
    alloc: Allocator,
    source: *std.Io.Reader,
    request: stream_provider.RequestData,
    limits: Limits,
    events: ?stream_provider.EventSink,
    cancel_flag: *std.atomic.Value(bool),
) Error!stream_provider.Result {
    var reducer = try Reducer.init(alloc, request, limits, events);
    defer reducer.deinit(alloc);
    var framing = sse.Reader{
        .max_event_bytes = limits.event_bytes,
        .max_total_bytes = limits.total_wire_bytes,
    };
    defer framing.deinit(alloc);
    var processed: usize = 0;
    while (try framing.next(alloc, source, cancel_flag)) |event| {
        if (processed == limits.events) return error.TooManyEvents;
        processed += 1;
        try reducer.reduce(alloc, event);
    }
    return reducer.finish(alloc);
}

const Reducer = struct {
    alloc: Allocator,
    limits: Limits,
    events: ?stream_provider.EventSink,
    choice: types.ToolChoice,
    /// Wire name -> fx source name, so inbound tool_use restores fx identity.
    source_names: std.StringHashMapUnmanaged([]const u8) = .empty,
    owned_names: std.ArrayList([]u8) = .empty,
    generation_id: ?[]u8 = null,
    completion_text: std.ArrayList(u8) = .empty,
    thinking: std.AutoHashMapUnmanaged(usize, ThinkingAccumulator) = .empty,
    sealed_thinking: std.ArrayList([]u8) = .empty,
    tools: std.AutoHashMapUnmanaged(usize, ToolAccumulator) = .empty,
    order: std.ArrayList(usize) = .empty,
    stop_reason: ?[]u8 = null,
    usage: types.Usage = .{},
    saw_stop: bool = false,

    fn init(alloc: Allocator, request: stream_provider.RequestData, limits: Limits, events: ?stream_provider.EventSink) Error!Reducer {
        var functions = try select_functions(alloc, request.tools, request.tool_choice);
        defer functions.deinit(alloc);
        try check_wire_names(alloc, functions.items);
        var self = Reducer{ .alloc = alloc, .limits = limits, .events = events, .choice = request.tool_choice };
        errdefer self.deinit(alloc);
        for (functions.items) |function| {
            const wire = try wire_name(alloc, function.name);
            if (wire.ptr != function.name.ptr) try self.owned_names.append(alloc, @constCast(wire));
            const entry = try self.source_names.getOrPut(alloc, wire);
            if (!entry.found_existing) entry.value_ptr.* = function.name;
        }
        return self;
    }

    fn deinit(self: *Reducer, alloc: Allocator) void {
        self.source_names.deinit(alloc);
        for (self.owned_names.items) |name| alloc.free(name);
        self.owned_names.deinit(alloc);
        if (self.generation_id) |id| alloc.free(id);
        self.completion_text.deinit(alloc);
        var thinking = self.thinking.iterator();
        while (thinking.next()) |entry| entry.value_ptr.deinit(alloc);
        self.thinking.deinit(alloc);
        for (self.sealed_thinking.items) |block| alloc.free(block);
        self.sealed_thinking.deinit(alloc);
        var tools = self.tools.iterator();
        while (tools.next()) |entry| entry.value_ptr.deinit(alloc);
        self.tools.deinit(alloc);
        self.order.deinit(alloc);
        if (self.stop_reason) |reason| alloc.free(reason);
    }

    fn reduce(self: *Reducer, alloc: Allocator, event: []const u8) Error!void {
        if (event.len == 0) return;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, event, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch return error.InvalidChunk;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidChunk;
        const fields = parsed.value.object;
        const kind_field = fields.get("type") orelse return error.InvalidChunk;
        if (kind_field != .string) return error.InvalidChunk;
        const kind = kind_field.string;
        if (std.mem.eql(u8, kind, "message_start")) {
            try self.message_start(alloc, fields);
        } else if (std.mem.eql(u8, kind, "content_block_start")) {
            try self.block_start(alloc, fields);
        } else if (std.mem.eql(u8, kind, "content_block_delta")) {
            try self.block_delta(alloc, fields);
        } else if (std.mem.eql(u8, kind, "content_block_stop")) {
            try self.block_stop(alloc, fields);
        } else if (std.mem.eql(u8, kind, "message_delta")) {
            try self.message_delta(alloc, fields);
        } else if (std.mem.eql(u8, kind, "message_stop")) {
            self.saw_stop = true;
        } else if (std.mem.eql(u8, kind, "error")) {
            return error.ProviderError;
        }
        // `ping` and forward-compatible event types are ignored.
    }

    fn message_start(self: *Reducer, alloc: Allocator, fields: std.json.ObjectMap) Error!void {
        const message = fields.get("message") orelse return error.InvalidChunk;
        if (message != .object) return error.InvalidChunk;
        if (message.object.get("id")) |id| {
            if (id != .string) return error.InvalidChunk;
            if (id.string.len > self.limits.identity_bytes) return error.IdentityTooLarge;
            if (self.generation_id != null) return error.InvalidChunk;
            self.generation_id = try alloc.dupe(u8, id.string);
        }
        if (message.object.get("usage")) |usage| {
            if (usage != .object) return error.InvalidChunk;
            self.usage.input_tokens = token_field(usage.object.get("input_tokens"));
            self.usage.output_tokens = token_field(usage.object.get("output_tokens"));
            self.usage.cache_read_tokens = token_field(usage.object.get("cache_read_input_tokens"));
            self.usage.cache_write_tokens = token_field(usage.object.get("cache_creation_input_tokens"));
        }
    }

    fn block_start(self: *Reducer, alloc: Allocator, fields: std.json.ObjectMap) Error!void {
        const index = try block_index(fields);
        const block = fields.get("content_block") orelse return error.InvalidChunk;
        if (block != .object) return error.InvalidChunk;
        const kind_field = block.object.get("type") orelse return error.InvalidChunk;
        if (kind_field != .string) return error.InvalidChunk;
        const kind = kind_field.string;
        if (std.mem.eql(u8, kind, "thinking")) {
            const entry = try self.thinking.getOrPut(alloc, index);
            if (entry.found_existing) return error.InvalidChunk;
            entry.value_ptr.* = .{};
        } else if (std.mem.eql(u8, kind, "redacted_thinking")) {
            // Opaque to fx; replayed verbatim through provider state.
            const data = block.object.get("data") orelse return error.InvalidChunk;
            if (data != .string) return error.InvalidChunk;
            const encoded = try std.json.Stringify.valueAlloc(alloc, data.string, .{});
            defer alloc.free(encoded);
            const sealed = try std.fmt.allocPrint(alloc, "{{\"type\":\"redacted_thinking\",\"data\":{s}}}", .{encoded});
            errdefer alloc.free(sealed);
            try self.sealed_thinking.append(alloc, sealed);
        } else if (std.mem.eql(u8, kind, "tool_use")) {
            if (self.tools.count() == self.limits.tool_calls) return error.TooManyTools;
            const entry = try self.tools.getOrPut(alloc, index);
            if (entry.found_existing) return error.InvalidChunk;
            entry.value_ptr.* = .{};
            try self.order.append(alloc, index);
            const id_field = block.object.get("id") orelse return error.InvalidChunk;
            const name_field = block.object.get("name") orelse return error.InvalidChunk;
            if (id_field != .string or name_field != .string) return error.InvalidChunk;
            if (id_field.string.len + name_field.string.len > self.limits.identity_bytes) return error.IdentityTooLarge;
            try entry.value_ptr.id.appendSlice(alloc, id_field.string);
            const source = self.source_names.get(name_field.string) orelse name_field.string;
            try entry.value_ptr.name.appendSlice(alloc, source);
            if (self.events) |sink| sink.emit(.{ .tool_started = .{ .id = entry.value_ptr.id.items, .name = source } });
        }
        // `text` starts are implicit; other block kinds are forward-compatible.
    }

    fn block_delta(self: *Reducer, alloc: Allocator, fields: std.json.ObjectMap) Error!void {
        const index = try block_index(fields);
        const delta = fields.get("delta") orelse return error.InvalidChunk;
        if (delta != .object) return error.InvalidChunk;
        const kind_field = delta.object.get("type") orelse return error.InvalidChunk;
        if (kind_field != .string) return error.InvalidChunk;
        const kind = kind_field.string;
        if (std.mem.eql(u8, kind, "text_delta")) {
            const text_field = delta.object.get("text") orelse return error.InvalidChunk;
            if (text_field != .string) return error.InvalidChunk;
            const text = text_field.string;
            if (text.len == 0) return;
            if (self.completion_text.items.len + text.len > self.limits.content_bytes) return error.ContentTooLarge;
            try self.completion_text.appendSlice(alloc, text);
            if (self.events) |sink| sink.emit(.{ .content_delta = text });
        } else if (std.mem.eql(u8, kind, "thinking_delta")) {
            const text_field = delta.object.get("thinking") orelse return error.InvalidChunk;
            if (text_field != .string) return error.InvalidChunk;
            const entry = self.thinking.getPtr(index) orelse return error.InvalidChunk;
            if (entry.text.items.len + text_field.string.len > self.limits.thinking_bytes) return error.StreamTooLarge;
            try entry.text.appendSlice(alloc, text_field.string);
            if (self.events) |sink| sink.emit(.{ .reasoning_delta = text_field.string });
        } else if (std.mem.eql(u8, kind, "signature_delta")) {
            const signature_field = delta.object.get("signature") orelse return error.InvalidChunk;
            if (signature_field != .string) return error.InvalidChunk;
            const entry = self.thinking.getPtr(index) orelse return error.InvalidChunk;
            if (entry.signature.items.len + signature_field.string.len > self.limits.thinking_bytes) return error.StreamTooLarge;
            try entry.signature.appendSlice(alloc, signature_field.string);
        } else if (std.mem.eql(u8, kind, "input_json_delta")) {
            const json_field = delta.object.get("partial_json") orelse return error.InvalidChunk;
            if (json_field != .string) return error.InvalidChunk;
            const entry = self.tools.getPtr(index) orelse return error.InvalidChunk;
            if (entry.arguments.items.len + json_field.string.len > self.limits.arguments_bytes) return error.ArgumentsTooLarge;
            try entry.arguments.appendSlice(alloc, json_field.string);
            if (self.events) |sink| sink.emit(.{ .tool_input_delta = json_field.string });
        }
    }

    fn block_stop(self: *Reducer, alloc: Allocator, fields: std.json.ObjectMap) Error!void {
        const index = try block_index(fields);
        if (self.thinking.getPtr(index)) |block| {
            // Seal the completed thinking block for verbatim replay. Anthropic
            // requires the signature when tool use continues.
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            out.writer.writeAll("{\"type\":\"thinking\",\"thinking\":") catch return error.OutOfMemory;
            std.json.Stringify.value(block.text.items, .{}, &out.writer) catch return error.OutOfMemory;
            if (block.signature.items.len != 0) {
                out.writer.writeAll(",\"signature\":") catch return error.OutOfMemory;
                std.json.Stringify.value(block.signature.items, .{}, &out.writer) catch return error.OutOfMemory;
            }
            out.writer.writeByte('}') catch return error.OutOfMemory;
            const sealed = try alloc.dupe(u8, out.written());
            errdefer alloc.free(sealed);
            try self.sealed_thinking.append(alloc, sealed);
            block.deinit(alloc);
            _ = self.thinking.remove(index);
        }
    }

    fn message_delta(self: *Reducer, alloc: Allocator, fields: std.json.ObjectMap) Error!void {
        const delta = fields.get("delta") orelse return error.InvalidChunk;
        if (delta != .object) return error.InvalidChunk;
        if (delta.object.get("stop_reason")) |reason| {
            if (reason != .string and reason != .null) return error.InvalidChunk;
            if (reason == .string) {
                if (reason.string.len > self.limits.identity_bytes) return error.IdentityTooLarge;
                const owned = try alloc.dupe(u8, reason.string);
                errdefer alloc.free(owned);
                if (self.stop_reason) |prior| alloc.free(prior);
                self.stop_reason = owned;
            }
        }
        if (fields.get("usage")) |usage| {
            if (usage != .object) return error.InvalidChunk;
            if (token_field(usage.object.get("output_tokens"))) |value| self.usage.output_tokens = value;
            if (token_field(usage.object.get("cache_read_input_tokens"))) |value| self.usage.cache_read_tokens = value;
            if (token_field(usage.object.get("cache_creation_input_tokens"))) |value| self.usage.cache_write_tokens = value;
        }
    }

    fn finish(self: *Reducer, alloc: Allocator) Error!stream_provider.Result {
        if (!self.saw_stop) return error.IncompleteStream;
        if (self.thinking.count() != 0) return error.IncompleteStream;
        var calls: std.ArrayList(types.ToolCall) = .empty;
        errdefer {
            for (calls.items) |call| {
                alloc.free(call.id);
                alloc.free(call.name);
                alloc.free(call.arguments_json);
            }
            calls.deinit(alloc);
        }
        for (self.order.items) |index| {
            const accumulator = self.tools.get(index).?;
            if (accumulator.id.items.len == 0) return error.InvalidChunk;
            const arguments = if (accumulator.arguments.items.len == 0) "{}" else accumulator.arguments.items;
            try validate_arguments(alloc, arguments);
            const id = try alloc.dupe(u8, accumulator.id.items);
            errdefer alloc.free(id);
            const name = try alloc.dupe(u8, accumulator.name.items);
            errdefer alloc.free(name);
            const owned_arguments = try alloc.dupe(u8, arguments);
            errdefer alloc.free(owned_arguments);
            try calls.append(alloc, .{ .id = id, .name = name, .arguments_json = owned_arguments });
        }
        const provider_state = try self.mint_state(alloc);
        errdefer if (provider_state) |state| alloc.free(state);
        const owned_calls = try calls.toOwnedSlice(alloc);
        errdefer {
            for (owned_calls) |call| {
                alloc.free(call.id);
                alloc.free(call.name);
                alloc.free(call.arguments_json);
            }
            alloc.free(owned_calls);
        }
        const content = if (self.completion_text.items.len != 0) try self.completion_text.toOwnedSlice(alloc) else null;
        errdefer if (content) |text| alloc.free(text);
        const generation_id = self.generation_id;
        self.generation_id = null;
        errdefer if (generation_id) |id| alloc.free(id);
        return .{
            .completed = .{
                .completion = .{
                    .content = content,
                    .tool_calls = owned_calls,
                    .generation_id = generation_id,
                    .finish_reason = finish_reason_for(self.stop_reason, owned_calls.len != 0),
                    .provider_state_json = provider_state,
                    .usage = self.usage,
                },
                .ownership = .owned,
                // A configured provider is billed outside fx; no gateway reference exists.
                .usage = .{ .unavailable = .possibly_billed },
            },
        };
    }

    fn mint_state(self: *Reducer, alloc: Allocator) Error!?[]u8 {
        if (self.sealed_thinking.items.len == 0 and self.order.items.len == 0) return null;
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        out.writer.writeAll("{\"thinking\":[") catch return error.OutOfMemory;
        for (self.sealed_thinking.items, 0..) |block, index| {
            if (index != 0) out.writer.writeByte(',') catch return error.OutOfMemory;
            out.writer.writeAll(block) catch return error.OutOfMemory;
        }
        out.writer.writeAll("],\"_tool_call_ids\":[") catch return error.OutOfMemory;
        for (self.order.items, 0..) |tool_index, index| {
            if (index != 0) out.writer.writeByte(',') catch return error.OutOfMemory;
            const id = self.tools.get(tool_index).?.id.items;
            std.json.Stringify.value(id, .{}, &out.writer) catch return error.OutOfMemory;
        }
        out.writer.writeAll("]}") catch return error.OutOfMemory;
        return out.toOwnedSlice() catch return error.OutOfMemory;
    }
};

fn block_index(fields: std.json.ObjectMap) Error!usize {
    const field = fields.get("index") orelse return error.InvalidChunk;
    return switch (field) {
        .integer => |value| if (value >= 0) @intCast(value) else error.InvalidChunk,
        .number_string => |text| std.fmt.parseInt(usize, text, 10) catch error.InvalidChunk,
        else => error.InvalidChunk,
    };
}

fn token_field(value: ?std.json.Value) ?u64 {
    const field = value orelse return null;
    return switch (field) {
        .integer => |number| if (number >= 0) @intCast(number) else null,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch null,
        else => null,
    };
}

fn finish_reason_for(raw: ?[]const u8, has_tools: bool) types.ProviderFinishReason {
    const reason = raw orelse return if (has_tools) .tool_calls else .stop;
    if (std.mem.eql(u8, reason, "end_turn")) return if (has_tools) .tool_calls else .stop;
    if (std.mem.eql(u8, reason, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, reason, "max_tokens") or std.mem.eql(u8, reason, "model_context_window_exceeded")) return .length;
    if (std.mem.eql(u8, reason, "refusal")) return .content_filter;
    if (std.mem.eql(u8, reason, "pause_turn")) return .other;
    return if (has_tools) .tool_calls else .stop;
}

/// Caller owns the bounded diagnostic. Normalize JSON before masking so later
/// diagnostic decoding cannot restore an escaped credential.
pub fn redact_error_detail(alloc: Allocator, raw: []const u8, credential: []const u8) Allocator.Error![]u8 {
    if (raw.len > 64 * 1024 or credential.len > 16 * 1024) return alloc.dupe(u8, "Provider error details exceeded the local limit");
    check_json_depth(raw) catch return alloc.dupe(u8, "Provider error details exceeded the nesting limit");
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const json_shaped = trimmed.len != 0 and (trimmed[0] == '{' or trimmed[0] == '[' or trimmed[0] == '"');
    var parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => if (json_shaped) return alloc.dupe(u8, "Provider error details could not be decoded") else null,
    };
    defer if (parsed) |*value| value.deinit();
    const detail = if (parsed) |value| try std.json.Stringify.valueAlloc(alloc, value.value, .{}) else try alloc.dupe(u8, raw);
    if (detail.len > 64 * 1024) {
        defer alloc.free(detail);
        return alloc.dupe(u8, "Provider error details exceeded the local limit");
    }
    errdefer alloc.free(detail);
    const encoded = try std.json.Stringify.valueAlloc(alloc, credential, .{});
    defer alloc.free(encoded);
    mask_error_bytes(detail, encoded[1 .. encoded.len - 1]);
    mask_error_bytes(detail, credential);
    return detail;
}

fn mask_error_bytes(detail: []u8, value: []const u8) void {
    if (value.len == 0) return;
    var remaining = detail;
    while (std.mem.find(u8, remaining, value)) |index| {
        @memset(remaining[index..][0..value.len], '*');
        remaining = remaining[index + value.len ..];
    }
}

const test_alloc = std.testing.allocator;

fn test_options() Options {
    return .{};
}

fn user_message(content: []const u8) types.ChatMessage {
    return .{ .role = .user, .content = content };
}

test "request shape hoists instructions into a system string" {
    const instructions = [_]types.ChatMessage{.{ .role = .system, .content = "be terse" }};
    const messages = [_]types.ChatMessage{user_message("hi")};
    const request = stream_provider.RequestData{
        .model = "claude-sonnet-4-5",
        .instructions = &instructions,
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    };
    const body = try build_request(test_alloc, request, test_options());
    defer test_alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, test_alloc, body, .{});
    defer parsed.deinit();
    const fields = parsed.value.object;
    try std.testing.expectEqualStrings("claude-sonnet-4-5", fields.get("model").?.string);
    try std.testing.expectEqualStrings("be terse", fields.get("system").?.string);
    try std.testing.expect(fields.get("stream").?.bool);
    try std.testing.expectEqual(@as(i64, @intCast(default_max_tokens)), fields.get("max_tokens").?.integer);
    const wire_messages = fields.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), wire_messages.len);
    try std.testing.expectEqualStrings("user", wire_messages[0].object.get("role").?.string);
    const parts = wire_messages[0].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("text", parts[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("hi", parts[0].object.get("text").?.string);
}

test "tool calls serialize as tool_use blocks with input as a raw object" {
    const calls = [_]types.ToolCall{.{ .id = "call_1", .name = "read", .arguments_json = "{\"path\":\"/tmp/x\"}" }};
    const messages = [_]types.ChatMessage{
        user_message("read it"),
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .content = "file bytes", .tool_call_id = "call_1", .tool_name = "read" },
    };
    const request = stream_provider.RequestData{ .model = "claude-sonnet-4-5", .messages = &messages, .tool_choice = .auto, .provider_options = .{} };
    const body = try build_request(test_alloc, request, test_options());
    defer test_alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, test_alloc, body, .{});
    defer parsed.deinit();
    const wire_messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), wire_messages.len);
    const assistant_parts = wire_messages[1].object.get("content").?.array.items;
    const tool_use = assistant_parts[0].object;
    try std.testing.expectEqualStrings("tool_use", tool_use.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", tool_use.get("id").?.string);
    try std.testing.expectEqualStrings("read", tool_use.get("name").?.string);
    try std.testing.expectEqualStrings("/tmp/x", tool_use.get("input").?.object.get("path").?.string);
    const result_parts = wire_messages[2].object.get("content").?.array.items;
    const tool_result = result_parts[0].object;
    try std.testing.expectEqualStrings("tool_result", tool_result.get("type").?.string);
    try std.testing.expectEqualStrings("call_1", tool_result.get("tool_use_id").?.string);
    try std.testing.expect(tool_result.get("is_error") == null);
}

test "dotted tool names project onto wire-safe names" {
    const calls = [_]types.ToolCall{.{ .id = "call_1", .name = "functions.read", .arguments_json = "{}" }};
    const messages = [_]types.ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .content = "ok", .tool_call_id = "call_1", .tool_name = "functions.read" },
    };
    const request = stream_provider.RequestData{ .model = "claude-sonnet-4-5", .messages = &messages, .tool_choice = .auto, .provider_options = .{} };
    const body = try build_request(test_alloc, request, test_options());
    defer test_alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "functions_read") != null);
    try std.testing.expect(std.mem.find(u8, body, "functions.read") == null);
}

test "reasoning effort writes a bounded thinking budget" {
    const messages = [_]types.ChatMessage{user_message("hi")};
    const request = stream_provider.RequestData{
        .model = "claude-sonnet-4-5",
        .messages = &messages,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high") },
        .tool_choice = .auto,
        .max_output_tokens = 16 * 1024,
    };
    const body = try build_request(test_alloc, request, test_options());
    defer test_alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, test_alloc, body, .{});
    defer parsed.deinit();
    const thinking = parsed.value.object.get("thinking").?.object;
    try std.testing.expectEqualStrings("enabled", thinking.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 8192), thinking.get("budget_tokens").?.integer);
}

test "default effort omits the thinking block" {
    const messages = [_]types.ChatMessage{user_message("hi")};
    const request = stream_provider.RequestData{ .model = "claude-sonnet-4-5", .messages = &messages, .tool_choice = .auto, .provider_options = .{} };
    const body = try build_request(test_alloc, request, test_options());
    defer test_alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "thinking") == null);
}

test "required tool choice keeps tool_choice:any and skips thinking" {
    const functions = [_]model_tool_schema.FunctionSchema{.{ .name = "read_file", .description = "Read a file" }};
    const messages = [_]types.ChatMessage{user_message("hi")};
    const request = stream_provider.RequestData{
        .model = "claude-sonnet-4-5",
        .messages = &messages,
        .tool_choice = .required,
        .tools = .{ .additional_functions = &functions },
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high") },
        .max_output_tokens = 16 * 1024,
    };
    const body = try build_request(test_alloc, request, test_options());
    defer test_alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":{\"type\":\"any\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "thinking") == null);
}

test "parallel tool call opt-out forces an explicit tool_choice" {
    const functions = [_]model_tool_schema.FunctionSchema{.{ .name = "read_file", .description = "Read a file" }};
    const messages = [_]types.ChatMessage{user_message("hi")};
    const request = stream_provider.RequestData{
        .model = "claude-sonnet-4-5",
        .messages = &messages,
        .tool_choice = .auto,
        .tools = .{ .additional_functions = &functions },
        .provider_options = .{ .parallel_tool_calls = false },
    };
    const body = try build_request(test_alloc, request, test_options());
    defer test_alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":{\"type\":\"auto\",\"disable_parallel_tool_use\":true}") != null);
}

test "thinking is omitted when max_tokens cannot exceed the budget floor" {
    const messages = [_]types.ChatMessage{user_message("hi")};
    const request = stream_provider.RequestData{
        .model = "claude-sonnet-4-5",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high") },
        .max_output_tokens = 512,
    };
    const body = try build_request(test_alloc, request, test_options());
    defer test_alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "thinking") == null);
}

test "sse reduction produces a completed result with usage and replay state" {
    const wire =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":9,\"output_tokens\":1,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":3}}}\n\n" ++
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"ponder\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig1\"}}\n\n" ++
        "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n" ++
        "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"/tmp\\\"}\"}}\n\n" ++
        "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":2}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":7}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";
    var source = std.Io.Reader.fixed(wire);
    var cancelled = std.atomic.Value(bool).init(false);
    const request = stream_provider.RequestData{ .model = "claude-sonnet-4-5", .messages = &.{}, .tool_choice = .auto, .provider_options = .{} };
    var result = try consume_stream(test_alloc, &source, request, .{}, null, &cancelled);
    defer result.deinit(test_alloc);
    try std.testing.expect(result == .completed);
    const completed = result.completed;
    try std.testing.expectEqualStrings("hello", completed.completion.content.?);
    try std.testing.expectEqualStrings("msg_1", completed.completion.generation_id.?);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completed.completion.finish_reason.?);
    try std.testing.expectEqual(@as(?u64, 9), completed.completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 7), completed.completion.usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 2), completed.completion.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, 3), completed.completion.usage.cache_write_tokens);
    const calls = completed.completion.tool_calls;
    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("toolu_1", calls[0].id);
    try std.testing.expectEqualStrings("read", calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"/tmp\"}", calls[0].arguments_json);
    const state = completed.completion.provider_state_json.?;
    try std.testing.expect(std.mem.find(u8, state, "\"signature\":\"sig1\"") != null);
    try std.testing.expect(std.mem.find(u8, state, "\"_tool_call_ids\":[\"toolu_1\"]") != null);
}

test "sse reduction fails on a stream missing message_stop" {
    const wire = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\"}}\n\n";
    var source = std.Io.Reader.fixed(wire);
    var cancelled = std.atomic.Value(bool).init(false);
    const request = stream_provider.RequestData{ .model = "claude-sonnet-4-5", .messages = &.{}, .tool_choice = .auto, .provider_options = .{} };
    try std.testing.expectError(error.IncompleteStream, consume_stream(test_alloc, &source, request, .{}, null, &cancelled));
}

test "replayed thinking blocks emit verbatim ahead of tool_use" {
    var provider = model_provider.parse("local").?;
    provider.configured.binding = @splat(1);
    const calls = [_]types.ToolCall{.{ .id = "toolu_1", .name = "read", .arguments_json = "{}" }};
    const replay_json = "{\"thinking\":[{\"type\":\"thinking\",\"thinking\":\"ponder\",\"signature\":\"sig1\"}],\"_tool_call_ids\":[\"toolu_1\"]}";
    const messages = [_]types.ChatMessage{
        user_message("hi"),
        .{
            .role = .assistant,
            .tool_calls = &calls,
            .provider_replay = .{ .source = .{ .provider = provider, .model = "claude-sonnet-4-5" }, .parts_json = replay_json },
        },
        .{ .role = .tool, .content = "bytes", .tool_call_id = "toolu_1", .tool_name = "read" },
    };
    const request = stream_provider.RequestData{ .model = "claude-sonnet-4-5", .messages = &messages, .tool_choice = .auto, .provider_options = .{} };
    const body = try build_request(test_alloc, request, .{ .provider = &provider });
    defer test_alloc.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, test_alloc, body, .{});
    defer parsed.deinit();
    const parts = parsed.value.object.get("messages").?.array.items[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("thinking", parts[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("sig1", parts[0].object.get("signature").?.string);
    try std.testing.expectEqualStrings("tool_use", parts[1].object.get("type").?.string);
}
