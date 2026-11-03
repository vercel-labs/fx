//! Anthropic Messages request serialization: the provider-neutral request
//! becomes system blocks, tools and alternating messages, with thinking
//! replay and prompt-cache breakpoints. Pure: no I/O besides loading
//! verified image snapshots. The stream reducer lives in
//! `anthropic_messages_stream.zig` and the HTTP transport in
//! `anthropic_messages.zig`.
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

const Allocator = std.mem.Allocator;

pub const Error = chat.Error;

pub const ThinkingMode = enum { budget, adaptive };
pub const CacheMode = enum { off, ephemeral, ephemeral_1h };

/// Input contract for prompt caching: the builder places breakpoints on what
/// it receives and never reorders or rewrites content.
/// - Tools are stable in the order given; the last one gets a breakpoint.
/// - The first `stable_instructions` instruction messages are the stable
///   system head. When null, the head ends at the first instruction that
///   starts with a volatile marker (`volatile_instruction_markers`); the
///   system breakpoint sits on the last block before it.
/// - Messages are frozen history: every message is byte-stable once sent.
///   The tail gets a rolling breakpoint and every 15th conversational user
///   message an anchor, within Anthropic's limit of four.
pub const Options = struct {
    /// Borrowed during serialization; replay recorded for another provider
    /// authority or model is dropped. Null rejects replay.
    provider: ?*const model_provider.ProviderId = null,
    cache: CacheMode = .ephemeral,
    stable_instructions: ?usize = null,
    thinking_mode: ThinkingMode = .budget,
    /// Sent when the request names no output limit; Messages requires one.
    default_max_tokens: u32 = 32_000,
    /// Replays no thinking at all, for the retry after a signature rejection.
    drop_thinking: bool = false,
    /// Compatibility metadata gates newer Anthropic wire controls.
    supports_context_management: bool = true,
    supports_eager_tool_input_streaming: bool = true,
    requires_tool_result_id: bool = false,
    /// Models that do not implement `tool_choice: any` receive `auto`.
    supports_forced_tool_choice: bool = true,
    /// Some Anthropic-compatible models reject requests that omit thinking,
    /// even when the caller did not select an effort.
    requires_thinking_presence: bool = false,
    /// OAuth requests to non-official endpoints may override selected SDK headers.
    allow_anthropic_header_overrides: bool = false,
    /// Signing proxies may accept replayed thinking with an empty signature.
    replay_unsigned_thinking: bool = false,
};

pub const volatile_instruction_markers = [_][]const u8{ "<fx-turn-context", "<memories>" };
pub const max_breakpoints = 4;
pub const decimation_interval = 15;

/// Replay envelope key for ordered thinking and redacted thinking blocks.
pub const thinking_field = "anthropic_thinking";
pub const compaction_field = "anthropic_compaction";
pub const association_field = "_tool_call_ids";
const max_name_bytes = 128;
const max_selected_tools = 256;

/// One wire content block, serialized without its closing brace so a
/// breakpoint can be appended without reparsing.
const Block = struct {
    json: []const u8,
    cacheable: bool = true,
    cache: bool = false,
};

const Message = struct {
    role: enum { user, assistant },
    blocks: std.ArrayList(Block) = .empty,
    conversational: bool = false,
    tool_results: bool = false,
};

const Wire = struct {
    system: std.ArrayList(Block) = .empty,
    tools: std.ArrayList(Block) = .empty,
    messages: std.ArrayList(Message) = .empty,
};

/// Anthropic tool names allow only `[A-Za-z0-9_-]{1,128}`. Others map bytewise
/// to `_`; the reducer maps a returned name back through the request.
pub fn wire_tool_name(alloc: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var valid = name.len <= max_name_bytes;
    for (name) |byte| valid = valid and (std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-');
    if (valid) return name;
    const out = try alloc.dupe(u8, name[0..@min(name.len, max_name_bytes)]);
    for (out) |*byte| if (!std.ascii.isAlphanumeric(byte.*) and byte.* != '-') {
        byte.* = '_';
    };
    return out;
}

fn wire_name_equals(name: []const u8, wire: []const u8) bool {
    if (@min(name.len, max_name_bytes) != wire.len) return false;
    for (name[0..wire.len], wire) |source, mapped| {
        const expected: u8 = if (std.ascii.isAlphanumeric(source) or source == '-') source else '_';
        if (expected != mapped) return false;
    }
    return true;
}

/// The advertised name a returned wire name stands for, or the wire name
/// itself when nothing maps to it. Borrowed from `tools` or `wire`.
pub fn canonical_tool_name(tools: stream_provider.ToolSelection, wire: []const u8) []const u8 {
    const lists = .{ tools.advertised_names, tools.additional_functions, tools.selected_dynamic };
    inline for (lists) |list| for (list) |entry| {
        const name: []const u8 = if (@TypeOf(entry) == []const u8) entry else entry.name;
        if (wire_name_equals(name, wire)) return name;
    };
    return wire;
}

fn validate_request(request: stream_provider.RequestData) Error!void {
    try request.validatePrompt();
    configured_provider.validate_model_id(request.model) catch return error.InvalidModel;
    const options = request.provider_options;
    // Anthropic Messages supports Fast mode directly. Ultrafast and gateway
    // routing are unrelated controls and must not leak into this endpoint.
    if (options.ultrafast or options.provider_order.len != 0) return error.UnsupportedProviderOption;
    if (request.vision_mode != .unavailable) return error.UnsupportedVision;
    if (request.verified_images != null and request.verified_images.?.len != 0) return error.UnsupportedVision;
    if (request.max_output_tokens == 0) return error.InvalidOutputLimit;
    for (request.messages) |message| {
        if (message.images.len != 0 and message.role != .user) return error.InvalidProviderPrompt;
        if (message.provider_replay != null and message.role != .assistant) return error.InvalidProviderState;
        if (message.role != .assistant and message.tool_calls.len != 0) return error.InvalidToolHistory;
        if (message.role != .tool and message.tool_call_id != null) return error.InvalidToolHistory;
        if (message.role != .assistant and message.content == null) return error.InvalidProviderPrompt;
    }
}

pub fn validate(request: stream_provider.RequestData) Error!void {
    return validate_request(request);
}

/// Parses a replay envelope: exactly the ordered thinking blocks and the
/// call IDs they were produced with. Caller deinits the result.
fn parse_replay(alloc: Allocator, raw: []const u8) Error!std.json.Parsed(std.json.Value) {
    if (raw.len > types.ProviderReplay.max_bytes) return error.ReplayTooLarge;
    try chat.check_json_depth(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{ .duplicate_field_behavior = .@"error", .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderState,
    };
    errdefer parsed.deinit();
    if (parsed.value != .object or parsed.value.object.count() < 2 or parsed.value.object.count() > 3) return error.InvalidProviderState;
    const fields = parsed.value.object;
    const blocks = fields.get(thinking_field) orelse return error.InvalidProviderState;
    if (blocks != .array) return error.InvalidProviderState;
    for (blocks.array.items) |item| {
        if (item != .object) return error.InvalidProviderState;
        const kind = item.object.get("type") orelse return error.InvalidProviderState;
        if (kind != .string) return error.InvalidProviderState;
        if (std.mem.eql(u8, kind.string, "thinking")) {
            const signature = item.object.get("signature") orelse return error.InvalidProviderState;
            const text = item.object.get("thinking") orelse return error.InvalidProviderState;
            if (signature != .string or text != .string or item.object.count() != 3) return error.InvalidProviderState;
        } else if (std.mem.eql(u8, kind.string, "redacted_thinking")) {
            const data = item.object.get("data") orelse return error.InvalidProviderState;
            if (data != .string or data.string.len == 0 or item.object.count() != 2) return error.InvalidProviderState;
        } else return error.InvalidProviderState;
    }
    if (fields.get(compaction_field)) |compaction| {
        if (compaction != .object) return error.InvalidProviderState;
        const content = compaction.object.get("content") orelse return error.InvalidProviderState;
        if (content != .string or content.string.len == 0) return error.InvalidProviderState;
        if (compaction.object.count() > 2) return error.InvalidProviderState;
        if (compaction.object.get("encrypted_content")) |encrypted| {
            if (encrypted != .string or encrypted.string.len == 0) return error.InvalidProviderState;
        }
    }
    const ids = fields.get(association_field) orelse return error.InvalidProviderState;
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

/// Signed thinking is indivisible from the calls it preceded: the whole
/// envelope is kept only with every associated call, or dropped.
/// Extracts the server-generated compaction summary from a reducer replay
/// envelope. The returned bytes belong to `alloc`; null means the envelope
/// contains no compaction block.
pub fn compaction_summary(alloc: Allocator, raw: []const u8) Error!?[]u8 {
    var parsed = try parse_replay(alloc, raw);
    defer parsed.deinit();
    const value = parsed.value.object.get(compaction_field) orelse return null;
    const content = value.object.get("content").?.string;
    return try alloc.dupe(u8, content);
}

pub fn project_replay(alloc: Allocator, replay: ?types.ProviderReplay, calls: []const types.ToolCall, _: bool, reasoning: bool) Error!?types.ProviderReplay {
    const value = replay orelse return null;
    var parsed = try parse_replay(alloc, value.parts_json);
    defer parsed.deinit();
    // Compaction summaries are provider context, not reasoning. Keep them on
    // a text-only turn even when the caller asks to drop signed thinking.
    const has_compaction = parsed.value.object.get(compaction_field) != null;
    if (!reasoning and !has_compaction) return null;
    return if (replay_calls_match(parsed.value.object, calls)) value else null;
}

fn finish_block(out: *std.Io.Writer.Allocating, cacheable: bool) !Block {
    return .{ .json = try out.toOwnedSlice(), .cacheable = cacheable };
}

fn text_block(arena: Allocator, text: []const u8) !Block {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, &out.writer);
    return finish_block(&out, true);
}

fn write_image_source(writer: *std.Io.Writer, media_type: []const u8) !void {
    try writer.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
    try std.json.Stringify.value(media_type, .{}, writer);
    try writer.writeAll(",\"data\":\"");
}

fn image_block_raw(arena: Allocator, media_type: []const u8, bytes: []const u8) !Block {
    var out: std.Io.Writer.Allocating = .init(arena);
    try write_image_source(&out.writer, media_type);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 3 * 1024, bytes.len);
        try std.base64.standard.Encoder.encodeWriter(&out.writer, bytes[offset..end]);
        offset = end;
    }
    try out.writer.writeAll("\"}");
    return finish_block(&out, true);
}

fn tool_result_denied(message: types.ChatMessage) bool {
    const failed = if (message.tool_result_status) |status| status == .failure else false;
    return failed and tool_result_errors.toolPermissionDenialReason(message.content orelse "") != null;
}

fn tool_result_block(arena: Allocator, message: types.ChatMessage, id: []const u8, requires_id: bool) !Block {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
    try std.json.Stringify.value(id, .{}, w);
    const text = message.content orelse "";
    const images = if (message.tool_result_memory) |memory| memory.tool_images else &.{};
    var image_count: usize = 0;
    if (!tool_result_denied(message)) for (images) |image| {
        if (image.data.len != 0) image_count += 1;
    };
    if (image_count == 0) {
        if (text.len != 0) {
            try w.writeAll(",\"content\":");
            try std.json.Stringify.value(text, .{}, w);
        }
    } else {
        try w.writeAll(",\"content\":[");
        var wrote = false;
        if (text.len != 0) {
            try w.writeAll("{\"type\":\"text\",\"text\":");
            try std.json.Stringify.value(text, .{}, w);
            try w.writeByte('}');
            wrote = true;
        }
        for (images) |image| {
            if (image.data.len == 0) continue;
            if (wrote) try w.writeByte(',');
            wrote = true;
            try write_image_source(w, image.mime_type);
            try w.writeAll(image.data);
            try w.writeAll("\"}}");
        }
        try w.writeByte(']');
    }
    if (message.tool_result_status == .failure) try w.writeAll(",\"is_error\":true");
    if (requires_id) {
        try w.writeAll(",\"id\":");
        try std.json.Stringify.value(id, .{}, w);
    }
    return finish_block(&out, true);
}

fn tool_use_block(arena: Allocator, call: types.ToolCall, id: []const u8) !Block {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("{\"type\":\"tool_use\",\"id\":");
    try std.json.Stringify.value(id, .{}, w);
    try w.writeAll(",\"name\":");
    try std.json.Stringify.value(try wire_tool_name(arena, call.name), .{}, w);
    try w.writeAll(",\"input\":");
    const arguments = std.mem.trim(u8, call.arguments_json, " \t\r\n");
    try w.writeAll(if (arguments.len == 0) "{}" else arguments);
    return finish_block(&out, true);
}

/// Appends the replayed thinking blocks of `message` in their original order.
fn replay_blocks(arena: Allocator, blocks: *std.ArrayList(Block), message: types.ChatMessage, replay_unsigned_thinking: bool) !void {
    const replay = message.provider_replay orelse return;
    var parsed = try parse_replay(arena, replay.parts_json);
    defer parsed.deinit();
    if (!replay_calls_match(parsed.value.object, message.tool_calls)) return error.InvalidProviderState;
    if (parsed.value.object.get(compaction_field)) |value| {
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("{\"type\":\"compaction\",\"content\":");
        try std.json.Stringify.value(value.object.get("content").?.string, .{}, &out.writer);
        if (value.object.get("encrypted_content")) |encrypted| {
            try out.writer.writeAll(",\"encrypted_content\":");
            try std.json.Stringify.value(encrypted.string, .{}, &out.writer);
        }
        try out.writer.writeByte('}');
        const json = try out.toOwnedSlice();
        try blocks.append(arena, .{ .json = json[0 .. json.len - 1], .cacheable = false });
    }
    for (parsed.value.object.get(thinking_field).?.array.items) |item| {
        const kind = item.object.get("type").?.string;
        if (!replay_unsigned_thinking and std.mem.eql(u8, kind, "thinking") and item.object.get("signature").?.string.len == 0) continue;
        var out: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(item, .{}, &out.writer);
        const json = try out.toOwnedSlice();
        try blocks.append(arena, .{ .json = json[0 .. json.len - 1], .cacheable = false });
    }
}

fn user_message(arena: Allocator, wire: *Wire) !*Message {
    if (wire.messages.items.len != 0) {
        const last = &wire.messages.items[wire.messages.items.len - 1];
        if (last.role == .user) return last;
    }
    try wire.messages.append(arena, .{ .role = .user });
    return &wire.messages.items[wire.messages.items.len - 1];
}

fn build_messages(arena: Allocator, wire: *Wire, messages: []const types.ChatMessage, options: Options, projection: *const tool_call_ids.Projection) !void {
    for (messages) |message| switch (message.role) {
        .system => return error.InvalidProviderPrompt,
        .user => {
            // A user message right after tool results joins them: tool_result
            // blocks must open the user turn that answers the tool_use turn.
            const target = try user_message(arena, wire);
            target.conversational = target.conversational or (!message.permission_feedback and message.context_origin != .handoff);
            const text = message.content orelse "";
            if (text.len != 0) try target.blocks.append(arena, try text_block(arena, text));
            for (message.images) |image| {
                var snapshot = image_attachments.loadVerifiedSnapshot(arena, image, .{}) catch return error.ImageUnavailable;
                try target.blocks.append(arena, try image_block_raw(arena, snapshot.media_type, snapshot.bytes));
                snapshot.deinit(arena);
            }
            if (target.blocks.items.len == 0) try target.blocks.append(arena, try text_block(arena, "(empty)"));
        },
        .tool => {
            const target = try user_message(arena, wire);
            target.tool_results = true;
            try target.blocks.append(arena, try tool_result_block(arena, message, projection.resolve(message.tool_call_id.?), options.requires_tool_result_id));
        },
        .assistant => {
            var blocks: std.ArrayList(Block) = .empty;
            if (!options.drop_thinking) try replay_blocks(arena, &blocks, message, options.replay_unsigned_thinking);
            const text = message.content orelse "";
            if (std.mem.trim(u8, text, " \t\r\n").len != 0) try blocks.append(arena, try text_block(arena, text));
            for (message.tool_calls) |call| try blocks.append(arena, try tool_use_block(arena, call, projection.resolve(call.id)));
            if (blocks.items.len == 0) continue;
            try wire.messages.append(arena, .{ .role = .assistant, .blocks = blocks });
        },
    };
}

fn build_system(arena: Allocator, wire: *Wire, instructions: []const types.ChatMessage) !void {
    for (instructions) |instruction| {
        const text = instruction.content.?;
        if (text.len == 0) continue;
        try wire.system.append(arena, try text_block(arena, text));
    }
}

fn build_tools(arena: Allocator, wire: *Wire, functions: []const chat.Function, eager_input_streaming: bool) !void {
    for (functions, 0..) |function, index| {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        const name = try wire_tool_name(arena, function.name);
        for (functions[0..index]) |prior| if (std.mem.eql(u8, try wire_tool_name(arena, prior.name), name)) return error.InvalidToolSelection;
        try w.writeAll("{\"name\":");
        try std.json.Stringify.value(name, .{}, w);
        try w.writeAll(",\"description\":");
        try model_tool_schema.writeCappedDescriptionJsonString(arena, w, function.description);
        try w.writeAll(",\"input_schema\":");
        switch (function.schema) {
            .builtin => |schema| try model_tool_schema.writeObjectSchema(arena, w, schema),
            .dynamic => |schema| try std.json.Stringify.value(schema, .{}, w),
        }
        // Fine-grained input streaming is the native Messages behavior; the
        // transport adds the beta header when it sees this marker.
        if (eager_input_streaming) try w.writeAll(",\"eager_input_streaming\":true");
        try wire.tools.append(arena, try finish_block(&out, true));
    }
}

/// Index one past the stable system head, counted in wire system blocks.
fn stable_system_end(instructions: []const types.ChatMessage, options: Options) usize {
    if (options.stable_instructions) |count| {
        var blocks: usize = 0;
        for (instructions[0..@min(count, instructions.len)]) |instruction| {
            if (instruction.content.?.len != 0) blocks += 1;
        }
        return blocks;
    }
    var blocks: usize = 0;
    for (instructions) |instruction| {
        const text = instruction.content.?;
        if (text.len == 0) continue;
        for (volatile_instruction_markers) |marker| if (std.mem.startsWith(u8, text, marker)) return blocks;
        blocks += 1;
    }
    return blocks;
}

fn mark_last(blocks: []Block) bool {
    var index = blocks.len;
    while (index > 0) : (index -= 1) {
        const block = &blocks[index - 1];
        if (!block.cacheable) continue;
        if (block.cache) return false;
        block.cache = true;
        return true;
    }
    return false;
}

/// Proto's applyHeadCaching then applyPromptCaching: the last tool, the last
/// stable system block, then the message tail and decimation anchors, never
/// more than `max_breakpoints` in all.
fn apply_caching(arena: Allocator, wire: *Wire, stable_end: usize) !void {
    var used: usize = 0;
    if (wire.tools.items.len != 0) {
        wire.tools.items[wire.tools.items.len - 1].cache = true;
        used += 1;
    }
    const system = wire.system.items;
    if (system.len != 0) {
        const anchor = if (stable_end == 0 or stable_end > system.len) system.len - 1 else stable_end - 1;
        system[anchor].cache = true;
        used += 1;
    }
    const messages = wire.messages.items;
    if (messages.len == 0 or used >= max_breakpoints) return;
    var users: std.ArrayList(usize) = .empty;
    for (messages, 0..) |message, index| if (message.role == .user and message.conversational and !message.tool_results) {
        try users.append(arena, index);
    };
    var candidates: std.ArrayList(usize) = .empty;
    try candidates.append(arena, messages.len - 1);
    var ordinal = users.items.len;
    while (ordinal > 0) : (ordinal -= 1) {
        if (ordinal % decimation_interval != 0) continue;
        const index = users.items[ordinal - 1];
        if (std.mem.findScalar(usize, candidates.items, index) == null) try candidates.append(arena, index);
    }
    if (messages.len >= 2 and std.mem.findScalar(usize, candidates.items, messages.len - 2) == null) try candidates.append(arena, messages.len - 2);
    for (candidates.items) |index| {
        if (used >= max_breakpoints) break;
        if (mark_last(messages[index].blocks.items)) used += 1;
    }
}

/// The Messages rule: with thinking on, an assistant turn continuing a tool
/// loop must open with its signed thinking. Without replay for it, thinking
/// has to stay off for this request.
fn tool_loop_has_thinking(wire: *const Wire) bool {
    var index = wire.messages.items.len;
    while (index > 0) : (index -= 1) {
        const message = wire.messages.items[index - 1];
        if (message.role == .user) {
            if (!message.tool_results) return true;
            continue;
        }
        const first = message.blocks.items[0];
        if (first.cacheable) return false;
    }
    return true;
}

const Thinking = union(enum) { off, budget: u32, adaptive: ?[]const u8 };

fn budget_for(effort: types.ReasoningEffort) u32 {
    const label = effort.label();
    const table = [_]struct { []const u8, u32 }{
        .{ "minimal", 1024 }, .{ "low", 2048 },    .{ "medium", 8192 },
        .{ "high", 16384 },   .{ "xhigh", 32000 }, .{ "max", 32000 },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], label)) return entry[1];
    return 8192;
}

fn adaptive_effort(effort: types.ReasoningEffort) ?[]const u8 {
    const label = effort.label();
    if (std.mem.eql(u8, label, "minimal")) return "low";
    for ([_][]const u8{ "low", "medium", "high", "xhigh", "max" }) |name| if (std.mem.eql(u8, name, label)) return name;
    return null;
}

fn resolve_thinking(request: stream_provider.RequestData, options: Options, wire: *const Wire, max_tokens: u32) Thinking {
    const effort = request.provider_options.reasoning orelse if (options.requires_thinking_presence) types.ReasoningEffort.auto else return .off;
    // Anthropic rejects thinking alongside a genuinely forced tool choice.
    // Unsupported forced choice is downgraded to `auto` below.
    if (request.tool_choice == .required and options.supports_forced_tool_choice) return .off;
    if (!tool_loop_has_thinking(wire)) return .off;
    return switch (options.thinking_mode) {
        .adaptive => .{ .adaptive = if (effort == .auto) null else adaptive_effort(effort) },
        .budget => budget: {
            if (max_tokens <= 2048 and !options.requires_thinking_presence) break :budget .off;
            if (options.requires_thinking_presence and request.provider_options.reasoning == null) break :budget .{ .budget = 1024 };
            break :budget .{ .budget = @max(1024, @min(budget_for(effort), max_tokens - 1024)) };
        },
    };
}

fn write_structured_format(writer: *std.Io.Writer, format: stream_provider.StructuredResponseFormat) !void {
    // Anthropic's structured-output beta accepts JSON Schema objects only.
    if (format.schema != .object) return error.UnsupportedResponseFormat;
    try writer.writeAll("{\"type\":\"json_schema\",\"name\":");
    try std.json.Stringify.value(format.name, .{}, writer);
    try writer.writeAll(",\"description\":");
    try std.json.Stringify.value(format.description, .{}, writer);
    try writer.writeAll(",\"schema\":");
    try std.json.Stringify.value(format.schema, .{}, writer);
    try writer.writeAll(",\"strict\":true}");
}

fn write_blocks(writer: *std.Io.Writer, blocks: []const Block, cache: CacheMode) !void {
    for (blocks, 0..) |block, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeAll(block.json);
        if (block.cache) try writer.writeAll(switch (cache) {
            .ephemeral_1h => ",\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"1h\"}",
            else => ",\"cache_control\":{\"type\":\"ephemeral\"}",
        });
        try writer.writeByte('}');
    }
}

/// Whether a built body turns thinking on with a token budget, which needs
/// the interleaved-thinking beta header for thinking between tool calls.
pub fn uses_budget_thinking(body: []const u8) bool {
    return std.mem.find(u8, body, "\"thinking\":{\"type\":\"enabled\"") != null;
}

/// Pure Messages serialization. Caller owns the returned bytes.
pub fn build_request(alloc: Allocator, input: stream_provider.RequestData, options: Options) Error![]u8 {
    try validate_request(input);
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var request = input;
    if (options.provider) |provider| {
        if (try types.projectProviderReplay(arena, input.messages, .{ .provider = provider.*, .model = input.model })) |projected| request.messages = projected;
    } else {
        for (input.messages) |message| if (message.provider_replay != null) return error.UnsupportedReplay;
    }
    try chat.validate_history(arena, request.messages);
    // History with tool_use blocks needs the tool definitions even when this
    // request forbids calls, so selection ignores `none` here.
    const selection_choice: types.ToolChoice = if (request.tool_choice == .none) .auto else request.tool_choice;
    const functions = try chat.select_functions(arena, request.tools, selection_choice);
    var projection = tool_call_ids.Projection.init(arena, request.messages) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidToolCallId,
    };
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    write_request(arena, &out.writer, request, options, functions.items, &projection) catch |err| switch (err) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
        error.InvalidProviderState, error.ReplayTooLarge, error.JsonTooDeep, error.ImageUnavailable, error.InvalidProviderPrompt, error.InvalidToolSelection, error.UnsupportedResponseFormat => |failure| return failure,
        else => return error.InvalidToolSchema,
    };
    return out.toOwnedSlice();
}

fn write_request(arena: Allocator, w: *std.Io.Writer, request: stream_provider.RequestData, options: Options, functions: []const chat.Function, projection: *const tool_call_ids.Projection) !void {
    var wire: Wire = .{};
    // Messages needs at least one turn. A prompt made only of instructions,
    // such as a capacity probe, sends its last instruction as the user turn.
    var instructions = request.instructions;
    if (request.messages.len == 0 and instructions.len != 0) {
        const last = instructions[instructions.len - 1].content.?;
        instructions = instructions[0 .. instructions.len - 1];
        try wire.messages.append(arena, .{ .role = .user, .conversational = true });
        try wire.messages.items[0].blocks.append(arena, try text_block(arena, if (last.len == 0) "(empty)" else last));
    }
    try build_system(arena, &wire, instructions);
    try build_tools(arena, &wire, functions, options.supports_eager_tool_input_streaming);
    try build_messages(arena, &wire, request.messages, options, projection);
    if (wire.messages.items.len == 0) return error.InvalidProviderPrompt;
    const caching = options.cache != .off;
    if (caching) try apply_caching(arena, &wire, stable_system_end(instructions, options));
    const max_tokens = request.max_output_tokens orelse options.default_max_tokens;
    const thinking = resolve_thinking(request, options, &wire, max_tokens);

    try w.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model, .{}, w);
    try w.print(",\"max_tokens\":{d},\"stream\":true", .{max_tokens});
    if (wire.system.items.len != 0) {
        try w.writeAll(",\"system\":[");
        try write_blocks(w, wire.system.items, options.cache);
        try w.writeByte(']');
    }
    try w.writeAll(",\"messages\":[");
    for (wire.messages.items, 0..) |message, index| {
        if (index != 0) try w.writeByte(',');
        try w.writeAll(if (message.role == .user) "{\"role\":\"user\",\"content\":[" else "{\"role\":\"assistant\",\"content\":[");
        try write_blocks(w, message.blocks.items, options.cache);
        try w.writeAll("]}");
    }
    try w.writeByte(']');
    if (wire.tools.items.len != 0) {
        try w.writeAll(",\"tools\":[");
        try write_blocks(w, wire.tools.items, options.cache);
        try w.writeAll("],\"tool_choice\":{\"type\":");
        const choice = if (request.tool_choice == .required and !options.supports_forced_tool_choice)
            "\"auto\""
        else switch (request.tool_choice) {
            .auto => "\"auto\"",
            .required => "\"any\"",
            .none => "\"none\"",
        };
        try w.writeAll(choice);
        if (request.provider_options.parallel_tool_calls == false and request.tool_choice != .none) try w.writeAll(",\"disable_parallel_tool_use\":true");
        try w.writeByte('}');
    }
    switch (thinking) {
        .off => {},
        .budget => |tokens| try w.print(",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{tokens}),
        .adaptive => |effort| {
            try w.writeAll(",\"thinking\":{\"type\":\"adaptive\"}");
            _ = effort;
        },
    }

    // Structured output, adaptive effort and task budgets share one output
    // configuration object. Keeping it in one place avoids emitting duplicate
    // `output_config` keys when reasoning and JSON output are both requested.
    const effort = switch (thinking) {
        .adaptive => |value| value,
        else => null,
    };
    const task_budget = request.provider_options.task_budget;
    if (effort != null or task_budget != null or request.response_format != null) {
        try w.writeAll(",\"output_config\":{");
        var field: usize = 0;
        if (effort) |name| {
            try w.writeAll("\"effort\":");
            try std.json.Stringify.value(name, .{}, w);
            field += 1;
        }
        if (task_budget) |budget| {
            if (field != 0) try w.writeByte(',');
            try w.writeAll("\"task_budget\":{\"type\":\"tokens\",\"total\":");
            try w.print("{d}", .{budget.total});
            if (budget.remaining) |remaining| try w.print(",\"remaining\":{d}", .{remaining});
            try w.writeByte('}');
            field += 1;
        }
        if (request.response_format) |format| {
            if (field != 0) try w.writeByte(',');
            try w.writeAll("\"format\":");
            try write_structured_format(w, format);
        }
        try w.writeByte('}');
    }
    if (request.provider_options.fallback_model) |fallback| if (fallback.len != 0) {
        try w.writeAll(",\"fallbacks\":[{\"model\":");
        try std.json.Stringify.value(fallback, .{}, w);
        try w.writeAll("}]");
    };
    if (request.provider_options.fast) try w.writeAll(",\"speed\":\"fast\"");
    if (options.supports_context_management) {
        if (request.provider_options.anthropic_compaction) |compaction| {
            try w.writeAll(",\"context_management\":{\"edits\":[{\"type\":\"compact_20260112\"");
            if (compaction.trigger_input_tokens) |trigger| {
                try w.print(",\"trigger\":{{\"type\":\"input_tokens\",\"value\":{d}}}", .{@max(trigger, 50_000)});
            }
            if (compaction.pause_after_compaction) try w.writeAll(",\"pause_after_compaction\":true");
            if (compaction.instructions) |text| {
                if (text.len != 0) {
                    try w.writeAll(",\"instructions\":");
                    try std.json.Stringify.value(text, .{}, w);
                }
            }
            try w.writeAll("}]}");
        }
    }
    try w.writeByte('}');
}

test {
    _ = @import("anthropic_messages_protocol_tests.zig");
}
