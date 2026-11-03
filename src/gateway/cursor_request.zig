//! Builds a Cursor `AgentRunRequest` from a proto-fx request, as proto's
//! `buildGrpcRequestForWireMode` does (D200):
//!
//! - the system prompt becomes `{"role":"system"}` JSON blobs at the head of
//!   `root_prompt_messages_json`, followed by the earlier history as JSON;
//! - each earlier user turn becomes an `AgentConversationTurnStructure`
//!   blob whose steps are assistant text and MCP tool calls with results;
//! - a trailing user message is a `UserMessageAction`, anything else (a
//!   trailing tool result) a `ResumeAction` over the whole history;
//! - every blob is stored by its SHA-256, and Cursor fetches them through
//!   KV `get_blob` messages while the run streams.
//!
//! Tools travel separately, as MCP definitions in the request context Cursor
//! asks for with a `request_context_args` exec.
const std = @import("std");
const pb = @import("cursor_protobuf.zig");
const chat = @import("chat_completions_protocol.zig");
const tool_call_ids = @import("tool_call_ids.zig");
const wire = @import("claude_agent_wire.zig");
const streams = @import("../core/agent/stream_provider.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");
const Allocator = std.mem.Allocator;

pub const provider_identifier = "proto-fx";
const default_system = "You are a helpful assistant.";
const forced_tool_instruction = "Respond only by calling one of the available tools, exactly once.";

pub const BlobId = [32]u8;

/// Blobs by SHA-256. Keys and values borrow the arena that built them.
pub const BlobStore = std.AutoHashMapUnmanaged(BlobId, []const u8);

pub const Model = struct {
    /// The id proto-fx knows the model by.
    id: []const u8,
    /// The discovered id used when Cursor's normalized request is rejected.
    wire_id: []const u8,
    name: []const u8,
    max_mode: bool = false,
    /// Cursor's normalized model id. Null keeps the discovered id on the wire.
    normalized_id: ?[]const u8 = null,
    /// The effort parameter paired with `normalized_id`.
    effort_parameter: ?[]const u8 = null,
    /// The discovered id to retry when the normalized request is not found.
    fallback_wire_id: ?[]const u8 = null,
    /// Bare composer-2.5 otherwise silently selects Cursor's fast lane.
    disable_fast: bool = false,
};

pub const Built = struct {
    /// AgentClientMessage{run_request}.
    run_message: []const u8,
    /// RequestContext, the reply to `request_context_args`.
    request_context: []const u8,
    blobs: BlobStore,
};

pub const Options = struct {
    model: Model,
    conversation_id: []const u8,
};

/// Builds the request in `arena`, which owns everything returned.
pub fn build(arena: Allocator, request: streams.RequestData, options: Options) !Built {
    if (request.response_format != null) return error.UnsupportedResponseFormat;
    for (request.messages) |message| {
        if (message.images.len != 0 and message.role != .user) return error.InvalidProviderPrompt;
    }
    var projection = try tool_call_ids.Projection.init(arena, request.messages);
    var blobs: BlobStore = .empty;

    var system: std.ArrayList([]const u8) = .empty;
    for (request.instructions) |instruction| {
        const text = instruction.content orelse continue;
        if (std.mem.trim(u8, text, " \t\r\n").len != 0) try system.append(arena, text);
    }
    if (request.tool_choice == .required) try system.append(arena, forced_tool_instruction);

    var roots: std.ArrayList(BlobId) = .empty;
    if (system.items.len == 0) {
        try roots.append(arena, try storeJson(arena, &blobs, .{ .role = "system", .content = default_system }));
    } else for (system.items) |text| try roots.append(arena, try storeJson(arena, &blobs, .{ .role = "system", .content = text }));

    const messages = request.messages;
    const active: ?usize = if (messages.len != 0 and messages[messages.len - 1].role == .user) messages.len - 1 else null;
    const history = messages[0 .. active orelse messages.len];
    try appendRootHistory(arena, &blobs, &roots, history, &projection);
    const turns = try buildTurns(arena, &blobs, history, &projection);

    var state = pb.Writer.init(arena);
    for (roots.items) |id| try state.bytesField(1, &id);
    for (turns) |id| try state.bytesField(8, &id);

    var action = pb.Writer.init(arena);
    if (active) |index| {
        const user = try userMessage(arena, messages[index], null);
        var user_action = pb.Writer.init(arena);
        try user_action.bytesField(1, user);
        try action.bytesField(1, user_action.bytes.items);
    } else try action.emptyField(2);

    const model = options.model;
    const normalized_id = model.normalized_id orelse model.wire_id;
    var details = pb.Writer.init(arena);
    try details.stringField(1, normalized_id);
    try details.stringField(3, model.id);
    try details.stringField(4, model.name);
    if (model.max_mode) try details.boolField(7, true);
    var requested = pb.Writer.init(arena);
    try requested.stringField(1, normalized_id);
    if (model.max_mode) try requested.boolField(2, true);
    if (model.effort_parameter) |effort| {
        var parameter = pb.Writer.init(arena);
        try parameter.stringField(1, "reasoning");
        try parameter.stringField(2, effort);
        try requested.bytesField(3, parameter.bytes.items);
    } else if (model.disable_fast) {
        var parameter = pb.Writer.init(arena);
        try parameter.stringField(1, "fast");
        try parameter.stringField(2, "false");
        try requested.bytesField(3, parameter.bytes.items);
    }

    var run = pb.Writer.init(arena);
    try run.bytesField(1, state.bytes.items);
    try run.bytesField(2, action.bytes.items);
    try run.bytesField(3, details.bytes.items);
    try run.bytesField(5, options.conversation_id);
    try run.bytesField(9, requested.bytes.items);
    var client = pb.Writer.init(arena);
    try client.bytesField(1, run.bytes.items);

    return .{
        .run_message = client.bytes.items,
        .request_context = try requestContext(arena, system.items, request),
        .blobs = blobs,
    };
}

/// Rewrites the model and/or conversation fields in an encoded
/// AgentClientMessage. Fallback retries use the discovered model id and omit
/// normalized effort parameters; rotated conversations keep every blob and
/// action from the original prepared request.
pub fn rewriteRun(
    arena: Allocator,
    client_message: []const u8,
    model_id: ?[]const u8,
    conversation_id: ?[]const u8,
    drop_parameters: bool,
) ![]const u8 {
    var outer = pb.Reader.init(client_message);
    var output = pb.Writer.init(arena);
    while (try outer.next()) |field| {
        if (field.number == 1 and field.wire == .bytes) {
            var run = pb.Reader.init(field.data);
            var rewritten = pb.Writer.init(arena);
            while (try run.next()) |run_field| {
                if (run_field.number == 3 and run_field.wire == .bytes and model_id != null) {
                    try rewritten.bytesField(3, try rewriteModelDetails(arena, run_field.data, model_id.?));
                } else if (run_field.number == 5 and run_field.wire == .bytes and conversation_id != null) {
                    try rewritten.bytesField(5, conversation_id.?);
                } else if (run_field.number == 9 and run_field.wire == .bytes and model_id != null) {
                    try rewritten.bytesField(9, try rewriteRequestedModel(arena, run_field.data, model_id.?, drop_parameters));
                } else try copyField(&rewritten, run_field);
            }
            try output.bytesField(1, rewritten.bytes.items);
        } else try copyField(&output, field);
    }
    return output.bytes.items;
}

fn rewriteModelDetails(arena: Allocator, encoded: []const u8, model_id: []const u8) ![]const u8 {
    var reader = pb.Reader.init(encoded);
    var output = pb.Writer.init(arena);
    var replaced = false;
    while (try reader.next()) |field| {
        if (field.number == 1 and field.wire == .bytes) {
            try output.stringField(1, model_id);
            replaced = true;
        } else try copyField(&output, field);
    }
    if (!replaced) try output.stringField(1, model_id);
    return output.bytes.items;
}

fn rewriteRequestedModel(arena: Allocator, encoded: []const u8, model_id: []const u8, drop_parameters: bool) ![]const u8 {
    var reader = pb.Reader.init(encoded);
    var output = pb.Writer.init(arena);
    var replaced = false;
    while (try reader.next()) |field| {
        if (field.number == 1 and field.wire == .bytes) {
            try output.stringField(1, model_id);
            replaced = true;
        } else if (field.number == 3 and drop_parameters) {
            continue;
        } else try copyField(&output, field);
    }
    if (!replaced) try output.stringField(1, model_id);
    return output.bytes.items;
}

fn copyField(writer: *pb.Writer, field: pb.Field) !void {
    switch (field.wire) {
        .bytes => try writer.bytesField(field.number, field.data),
        .varint => try writer.uintField(field.number, field.int),
        .fixed64 => try writer.doubleField(field.number, @bitCast(field.int)),
        .fixed32 => {
            try writer.tag(field.number, .fixed32);
            try writer.bytes.appendSlice(writer.alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, @truncate(field.int))));
        },
        else => return error.UnsupportedWireType,
    }
}

fn store(arena: Allocator, blobs: *BlobStore, data: []const u8) !BlobId {
    var id: BlobId = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &id, .{});
    try blobs.put(arena, id, data);
    return id;
}

fn storeJson(arena: Allocator, blobs: *BlobStore, value: anytype) !BlobId {
    return store(arena, blobs, try std.json.Stringify.valueAlloc(arena, value, .{}));
}

/// UserMessage{text, message_id, selected_context}. A null seed draws a fresh id.
fn userMessage(arena: Allocator, message: types.ChatMessage, seed: ?[]const u8) ![]const u8 {
    var id: [36]u8 = undefined;
    if (seed) |value| {
        id = wire.derivedUuid(value, 0);
    } else {
        var random: [16]u8 = undefined;
        io_mod.getIo().random(&random);
        id = wire.derivedUuid(&random, 1);
    }
    var w = pb.Writer.init(arena);
    try w.stringField(1, std.mem.trim(u8, message.content orelse "", " \t\r\n"));
    try w.bytesField(2, try arena.dupe(u8, &id));
    if (message.images.len != 0) {
        var selected = pb.Writer.init(arena);
        for (message.images) |image| try selected.bytesField(1, try selectedImage(arena, image));
        try w.bytesField(3, selected.bytes.items);
    }
    return w.bytes.items;
}

/// SelectedImage{uuid, mime_type, data}. Cursor's selected-context wire uses
/// field 8 for inline bytes; the source path is intentionally not sent.
fn selectedImage(arena: Allocator, attachment: types.ImageAttachment) ![]const u8 {
    var verified = image_attachments.loadVerifiedSnapshot(arena, attachment, .{}) catch return error.ImageUnavailable;
    defer verified.deinit(arena);
    var random: [16]u8 = undefined;
    io_mod.getIo().random(&random);
    const uuid = wire.derivedUuid(&random, attachment.id);
    var selected = pb.Writer.init(arena);
    try selected.stringField(2, &uuid);
    try selected.stringField(7, verified.media_type);
    try selected.bytesField(8, verified.bytes);
    return selected.bytes.items;
}

fn toolResults(history: []const types.ChatMessage) ToolResults {
    return .{ .history = history };
}

const ToolResults = struct {
    history: []const types.ChatMessage,

    fn find(self: ToolResults, id: []const u8) ?types.ChatMessage {
        for (self.history) |message| {
            if (message.role == .tool and message.tool_call_id != null and std.mem.eql(u8, message.tool_call_id.?, id)) return message;
        }
        return null;
    }

    fn paired(self: ToolResults, id: []const u8) bool {
        for (self.history) |message| {
            if (message.role != .assistant) continue;
            for (message.tool_calls) |call| if (std.mem.eql(u8, call.id, id)) return true;
        }
        return false;
    }
};

fn orphanText(arena: Allocator, message: types.ChatMessage) ![]const u8 {
    const content = message.content orelse "";
    return arena.print("{s}\n{s}", .{ if (failed(message)) "[Tool Error]" else "[Tool Result]", if (content.len != 0) content else "(empty result)" });
}

fn failed(message: types.ChatMessage) bool {
    return message.tool_result_status == .failure;
}

/// The history as root prompt JSON, as proto's `buildRootPromptMessagesJson`.
fn appendRootHistory(arena: Allocator, blobs: *BlobStore, roots: *std.ArrayList(BlobId), history: []const types.ChatMessage, projection: *const tool_call_ids.Projection) !void {
    const results = toolResults(history);
    for (history) |message| switch (message.role) {
        .system => {},
        .user => {
            if (try rootUserBlob(arena, blobs, message)) |id| try roots.append(arena, id);
        },
        .assistant => {
            var out: std.Io.Writer.Allocating = .init(arena);
            const w = &out.writer;
            try w.writeAll("{\"role\":\"assistant\",\"content\":[");
            var parts: usize = 0;
            if (message.content) |text| if (text.len != 0) {
                try w.writeAll("{\"type\":\"text\",\"text\":");
                try std.json.Stringify.value(text, .{}, w);
                try w.writeByte('}');
                parts += 1;
            };
            for (message.tool_calls) |call| {
                if (parts != 0) try w.writeByte(',');
                parts += 1;
                try w.writeAll("{\"type\":\"tool-call\",\"toolCallId\":");
                try std.json.Stringify.value(projection.resolve(call.id), .{}, w);
                try w.writeAll(",\"toolName\":");
                try std.json.Stringify.value(call.name, .{}, w);
                try w.writeAll(",\"args\":");
                try w.writeAll(argumentsObject(call.arguments_json));
                try w.writeByte('}');
            }
            if (parts == 0) continue;
            try w.writeAll("]}");
            try roots.append(arena, try store(arena, blobs, out.written()));
        },
        .tool => {
            const id = message.tool_call_id orelse continue;
            if (!results.paired(id)) {
                try roots.append(arena, try storeJson(arena, blobs, .{ .role = "assistant", .content = &[_]TextPart{.{ .text = try orphanText(arena, message) }} }));
                continue;
            }
            const wire_id = projection.resolve(id);
            const part: ToolResultPart = .{ .toolName = message.tool_name orelse "", .toolCallId = wire_id, .result = message.content orelse "", .isError = if (failed(message)) true else null };
            try roots.append(arena, try storeJson(arena, blobs, .{ .role = "tool", .id = wire_id, .content = &[_]ToolResultPart{part} }));
        },
    };
}

/// Root prompt user content mirrors Cursor's selected image JSON: text parts
/// are trimmed, while image bytes travel as data URLs with their media type.
fn rootUserBlob(arena: Allocator, blobs: *BlobStore, message: types.ChatMessage) !?BlobId {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("{\"role\":\"user\",\"content\":[");
    var parts: usize = 0;
    const text = std.mem.trim(u8, message.content orelse "", " \t\r\n");
    if (text.len != 0) {
        try w.writeAll("{\"type\":\"text\",\"text\":");
        try std.json.Stringify.value(text, .{}, w);
        try w.writeByte('}');
        parts += 1;
    }
    for (message.images) |attachment| {
        var verified = image_attachments.loadVerifiedSnapshot(arena, attachment, .{}) catch return error.ImageUnavailable;
        defer verified.deinit(arena);
        if (parts != 0) try w.writeByte(',');
        try w.writeAll("{\"type\":\"image\",\"image\":");
        var uri: std.Io.Writer.Allocating = .init(arena);
        try uri.writer.print("data:{s};base64,", .{verified.media_type});
        try std.base64.standard.Encoder.encodeWriter(&uri.writer, verified.bytes);
        try std.json.Stringify.value(uri.written(), .{}, w);
        try w.writeAll(",\"mediaType\":");
        try std.json.Stringify.value(verified.media_type, .{}, w);
        try w.writeByte('}');
        parts += 1;
    }
    if (parts == 0) return null;
    try w.writeAll("]}");
    return try store(arena, blobs, out.written());
}

const TextPart = struct { type: []const u8 = "text", text: []const u8 };
const ToolResultPart = struct {
    type: []const u8 = "tool-result",
    toolName: []const u8,
    toolCallId: []const u8,
    result: []const u8,
    isError: ?bool = null,

    pub fn jsonStringify(self: ToolResultPart, jw: anytype) !void {
        try jw.beginObject();
        inline for (.{ "type", "toolName", "toolCallId", "result" }) |name| {
            try jw.objectField(name);
            try jw.write(@field(self, name));
        }
        if (self.isError) |value| {
            try jw.objectField("isError");
            try jw.write(value);
        }
        try jw.endObject();
    }
};

/// Tool arguments as a JSON object; anything else replays as `{}`.
fn argumentsObject(arguments: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, arguments, " \t\r\n");
    return if (trimmed.len != 0 and trimmed[0] == '{') trimmed else "{}";
}

/// One `AgentConversationTurnStructure` blob per earlier user message, as
/// proto's `buildConversationTurns`.
fn buildTurns(arena: Allocator, blobs: *BlobStore, history: []const types.ChatMessage, projection: *const tool_call_ids.Projection) ![]const BlobId {
    const results = toolResults(history);
    var turns: std.ArrayList(BlobId) = .empty;
    var index: usize = 0;
    while (index < history.len) {
        const message = history[index];
        index += 1;
        if (message.role != .user) continue;
        const text = std.mem.trim(u8, message.content orelse "", " \t\r\n");
        if (text.len == 0 and message.images.len == 0) continue;
        const seed = try arena.print("u:{d}:{s}:{d}", .{ turns.items.len, text, message.images.len });
        const user_id = try store(arena, blobs, try userMessage(arena, message, seed));
        var steps: std.ArrayList(BlobId) = .empty;
        while (index < history.len and history[index].role != .user) : (index += 1) {
            const step_message = history[index];
            switch (step_message.role) {
                .assistant => {
                    if (step_message.content) |content| if (content.len != 0) {
                        try steps.append(arena, try store(arena, blobs, try assistantStep(arena, content)));
                    };
                    for (step_message.tool_calls) |call| {
                        try steps.append(arena, try store(arena, blobs, try toolCallStep(arena, call, projection.resolve(call.id), results.find(call.id))));
                    }
                },
                .tool => if (step_message.tool_call_id) |id| if (!results.paired(id)) {
                    try steps.append(arena, try store(arena, blobs, try assistantStep(arena, try orphanText(arena, step_message))));
                },
                else => {},
            }
        }
        var turn = pb.Writer.init(arena);
        try turn.bytesField(1, &user_id);
        for (steps.items) |id| try turn.bytesField(2, &id);
        var structure = pb.Writer.init(arena);
        try structure.bytesField(1, turn.bytes.items);
        try turns.append(arena, try store(arena, blobs, structure.bytes.items));
    }
    return turns.items;
}

/// ConversationStep{assistant_message{text}}.
fn assistantStep(arena: Allocator, text: []const u8) ![]const u8 {
    var inner = pb.Writer.init(arena);
    try inner.bytesField(1, text);
    var step = pb.Writer.init(arena);
    try step.bytesField(1, inner.bytes.items);
    return step.bytes.items;
}

/// ConversationStep{tool_call{mcp_tool_call{args, result?}, tool_call_id}}.
fn toolCallStep(arena: Allocator, call: types.ToolCall, wire_id: []const u8, result: ?types.ChatMessage) ![]const u8 {
    var args = pb.Writer.init(arena);
    try args.stringField(1, call.name);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, argumentsObject(call.arguments_json), .{}) catch std.json.Value{ .object = .empty };
    if (parsed == .object) {
        var iterator = parsed.object.iterator();
        while (iterator.next()) |entry| {
            var pair = pb.Writer.init(arena);
            try pair.bytesField(1, entry.key_ptr.*);
            try pair.bytesField(2, try pb.encodeJsonValue(arena, entry.value_ptr.*));
            try args.bytesField(2, pair.bytes.items);
        }
    }
    try args.stringField(3, wire_id);
    try args.stringField(4, provider_identifier);
    try args.stringField(5, call.name);
    var mcp = pb.Writer.init(arena);
    try mcp.bytesField(1, args.bytes.items);
    if (result) |message| {
        var outcome = pb.Writer.init(arena);
        const text = message.content orelse "";
        if (failed(message)) {
            var failure = pb.Writer.init(arena);
            try failure.stringField(1, text);
            try outcome.bytesField(2, failure.bytes.items);
        } else {
            var content = pb.Writer.init(arena);
            try content.bytesField(1, text);
            var item = pb.Writer.init(arena);
            try item.bytesField(1, content.bytes.items);
            var success = pb.Writer.init(arena);
            try success.bytesField(1, item.bytes.items);
            try outcome.bytesField(1, success.bytes.items);
        }
        try mcp.bytesField(2, outcome.bytes.items);
    }
    var tool_call = pb.Writer.init(arena);
    try tool_call.bytesField(15, mcp.bytes.items);
    try tool_call.stringField(57, wire_id);
    var step = pb.Writer.init(arena);
    try step.bytesField(2, tool_call.bytes.items);
    return step.bytes.items;
}

/// RequestContext{rules, tools}: the system prompt as global user rules and
/// proto-fx's tools as MCP definitions.
fn requestContext(arena: Allocator, system: []const []const u8, request: streams.RequestData) ![]const u8 {
    var context = pb.Writer.init(arena);
    for (system, 0..) |text, index| {
        var rule_type = pb.Writer.init(arena);
        try rule_type.emptyField(1);
        var rule = pb.Writer.init(arena);
        try rule.bytesField(1, try arena.print("/proto-fx/system-prompt/{d}.mdc", .{index}));
        try rule.bytesField(2, text);
        try rule.bytesField(3, rule_type.bytes.items);
        try rule.uintField(4, 2);
        try context.bytesField(2, rule.bytes.items);
    }
    const functions = try chat.select_functions(arena, request.tools, request.tool_choice);
    for (functions.items) |function| {
        var schema_text: std.Io.Writer.Allocating = .init(arena);
        const schema: std.json.Value = switch (function.schema) {
            .builtin => |object| blk: {
                try model_tool_schema.writeObjectSchema(arena, &schema_text.writer, object);
                break :blk try std.json.parseFromSliceLeaky(std.json.Value, arena, schema_text.written(), .{});
            },
            .dynamic => |value| value,
        };
        var definition = pb.Writer.init(arena);
        try definition.bytesField(1, function.name);
        try definition.stringField(2, function.description);
        try definition.bytesField(3, try pb.encodeJsonValue(arena, schema));
        try definition.bytesField(4, provider_identifier);
        try definition.bytesField(5, function.name);
        try context.bytesField(7, definition.bytes.items);
    }
    return context.bytes.items;
}

// A prepared request travels as one byte string between `build_request_fn`
// and `stream_fn`: a magic line, the run message, the request context, then
// each blob as id and data, every part with a big-endian u32 length.
const prepared_magic = "proto-fx-cursor-run/1\n";

/// Packs `built` into one owned byte string.
pub fn pack(alloc: Allocator, built: Built) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(prepared_magic);
    for ([_][]const u8{ built.run_message, built.request_context }) |part| {
        try w.writeInt(u32, @intCast(part.len), .big);
        try w.writeAll(part);
    }
    var iterator = built.blobs.iterator();
    while (iterator.next()) |entry| {
        try w.writeAll(entry.key_ptr);
        try w.writeInt(u32, @intCast(entry.value_ptr.len), .big);
        try w.writeAll(entry.value_ptr.*);
    }
    return out.toOwnedSlice();
}

/// Reads a packed request. Slices borrow `bytes`; the store lives in `arena`.
pub fn unpack(arena: Allocator, bytes: []const u8) !Built {
    if (!std.mem.startsWith(u8, bytes, prepared_magic)) return error.InvalidPreparedRequest;
    var reader: std.Io.Reader = .fixed(bytes[prepared_magic.len..]);
    var parts: [2][]const u8 = undefined;
    for (&parts) |*part| {
        const len = reader.takeInt(u32, .big) catch return error.InvalidPreparedRequest;
        part.* = reader.take(len) catch return error.InvalidPreparedRequest;
    }
    var blobs: BlobStore = .empty;
    while (reader.seek < reader.end) {
        const id = (reader.takeArray(32) catch return error.InvalidPreparedRequest).*;
        const len = reader.takeInt(u32, .big) catch return error.InvalidPreparedRequest;
        try blobs.put(arena, id, reader.take(len) catch return error.InvalidPreparedRequest);
    }
    return .{ .run_message = parts[0], .request_context = parts[1], .blobs = blobs };
}
