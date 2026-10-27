//! Anthropic Messages SSE reduction: text, thinking with signatures, redacted
//! thinking, tool_use with partial JSON input, usage with cache counters,
//! stop reasons and in-stream errors. No I/O beyond the borrowed reader.
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const protocol = @import("anthropic_messages_protocol.zig");
const chat = @import("chat_completions_protocol.zig");
const sse = @import("sse.zig");

const Allocator = std.mem.Allocator;
pub const Error = protocol.Error;

pub const Limits = chat.Limits;

const Kind = enum { text, thinking, redacted, tool_use, ignored };

const Block = struct {
    kind: Kind,
    open: bool = true,
    /// Index into `thinking` or `tools` for those kinds.
    slot: usize = 0,
};

const Thinking = struct {
    redacted: bool,
    text: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
};

const Tool = struct {
    id: []u8,
    name: []u8,
    arguments: std.ArrayList(u8) = .empty,
    streamed: bool = false,
    /// Presentation progress: the start was told and how many argument
    /// bytes were already streamed out.
    announced: bool = false,
    emitted: usize = 0,
};

/// What one accepted event contributes to presentation. Slices borrow
/// reducer storage until the next accept or deinit.
pub const Deltas = struct {
    content: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
};

/// An `error` event: the provider failed mid-stream.
pub const StreamFailure = struct {
    kind: stream_provider.FailureKind,
    /// Owned JSON of the error object.
    detail: []u8,
};

const UsageCounters = struct {
    input: ?u64 = null,
    output: ?u64 = null,
    cache_write: ?u64 = null,
    cache_read: ?u64 = null,
};

/// Single-owner request-local state machine. Any accept or finish failure
/// poisons it; deinit is always required.
pub const Reducer = struct {
    alloc: Allocator,
    limits: Limits,
    request: stream_provider.RequestData,
    blocks: std.ArrayList(Block) = .empty,
    thinking: std.ArrayList(Thinking) = .empty,
    tools: std.ArrayList(Tool) = .empty,
    content: std.ArrayList(u8) = .empty,
    message_id: ?[]u8 = null,
    usage: UsageCounters = .{},
    stop_reason: ?[]u8 = null,
    failure: ?StreamFailure = null,
    phase: enum { receiving, stopped, done, failed, closed } = .receiving,
    event_count: usize = 0,
    wire_bytes: usize = 0,
    thinking_bytes: usize = 0,

    pub fn init(alloc: Allocator, request: stream_provider.RequestData, limits: Limits) Error!Reducer {
        try protocol.validate(request);
        return .{ .alloc = alloc, .limits = limits, .request = request };
    }

    pub fn deinit(self: *Reducer) void {
        self.blocks.deinit(self.alloc);
        for (self.thinking.items) |*part| {
            part.text.deinit(self.alloc);
            part.signature.deinit(self.alloc);
        }
        self.thinking.deinit(self.alloc);
        for (self.tools.items) |*tool| {
            self.alloc.free(tool.id);
            self.alloc.free(tool.name);
            tool.arguments.deinit(self.alloc);
        }
        self.tools.deinit(self.alloc);
        self.content.deinit(self.alloc);
        if (self.message_id) |id| self.alloc.free(id);
        if (self.stop_reason) |reason| self.alloc.free(reason);
        if (self.failure) |failure| self.alloc.free(failure.detail);
        self.* = undefined;
    }

    pub fn accept(self: *Reducer, data: []const u8, cancelled: bool) Error!Deltas {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        if (self.phase != .receiving and self.phase != .stopped) return error.StreamClosed;
        if (data.len > self.limits.event_bytes) return error.EventTooLarge;
        if (data.len > self.limits.total_wire_bytes - self.wire_bytes) return error.StreamTooLarge;
        self.wire_bytes += data.len;
        if (self.event_count == self.limits.events) return error.TooManyEvents;
        self.event_count += 1;
        try chat.check_json_depth(data);
        var parsed = std.json.parseFromSlice(std.json.Value, self.alloc, data, .{ .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidChunk,
        };
        defer parsed.deinit();
        const root = try object(parsed.value);
        const kind = try string(root.get("type") orelse return error.InvalidChunk);
        if (std.mem.eql(u8, kind, "ping")) return .{};
        if (std.mem.eql(u8, kind, "error")) {
            const failure = non_null(root, "error") orelse return error.ProviderError;
            const detail = try std.json.Stringify.valueAlloc(self.alloc, failure, .{});
            self.failure = .{ .kind = failure_kind(failure), .detail = detail };
            self.phase = .failed;
            return .{};
        }
        if (std.mem.eql(u8, kind, "message_start")) {
            const message = try object(root.get("message") orelse return error.InvalidChunk);
            if (non_null(message, "id")) |id| {
                const text = try string(id);
                if (text.len == 0 or text.len > self.limits.identity_bytes) return error.IdentityTooLarge;
                if (self.message_id == null) self.message_id = try self.alloc.dupe(u8, text);
            }
            if (non_null(message, "usage")) |usage| try self.accept_usage(usage);
            return .{};
        }
        if (std.mem.eql(u8, kind, "message_delta")) {
            if (non_null(root, "delta")) |delta_value| {
                const delta = try object(delta_value);
                if (non_null(delta, "stop_reason")) |reason| {
                    if (self.stop_reason != null) return error.InconsistentFinishReason;
                    self.stop_reason = try self.alloc.dupe(u8, try string(reason));
                    self.phase = .stopped;
                }
            }
            if (non_null(root, "usage")) |usage| try self.accept_usage(usage);
            return .{};
        }
        if (std.mem.eql(u8, kind, "message_stop")) {
            if (self.phase != .stopped) return error.IncompleteStream;
            for (self.blocks.items) |block| if (block.open) return error.IncompleteStream;
            self.phase = .done;
            return .{};
        }
        if (self.phase == .stopped) return error.InconsistentFinishReason;
        const index = try index_value(root.get("index") orelse return error.InvalidChunk);
        if (std.mem.eql(u8, kind, "content_block_start")) {
            if (index != self.blocks.items.len) return error.InvalidChunk;
            try self.start_block(try object(root.get("content_block") orelse return error.InvalidChunk));
            return .{};
        }
        if (index >= self.blocks.items.len or !self.blocks.items[index].open) return error.InvalidChunk;
        const block = &self.blocks.items[index];
        if (std.mem.eql(u8, kind, "content_block_stop")) {
            block.open = false;
            return .{};
        }
        if (!std.mem.eql(u8, kind, "content_block_delta")) return error.InvalidChunk;
        return self.accept_delta(block.*, try object(root.get("delta") orelse return error.InvalidChunk));
    }

    fn start_block(self: *Reducer, block: std.json.ObjectMap) Error!void {
        const kind = try string(block.get("type") orelse return error.InvalidChunk);
        if (std.mem.eql(u8, kind, "text")) {
            try self.blocks.append(self.alloc, .{ .kind = .text });
            if (non_null(block, "text")) |text| _ = try self.append_content(try string(text));
        } else if (std.mem.eql(u8, kind, "thinking") or std.mem.eql(u8, kind, "redacted_thinking")) {
            const redacted = kind[0] == 'r';
            try self.thinking.append(self.alloc, .{ .redacted = redacted });
            try self.blocks.append(self.alloc, .{ .kind = if (redacted) .redacted else .thinking, .slot = self.thinking.items.len - 1 });
            const part = &self.thinking.items[self.thinking.items.len - 1];
            if (redacted) {
                try self.append_thinking(&part.signature, try string(block.get("data") orelse return error.InvalidChunk));
            } else {
                if (non_null(block, "thinking")) |text| try self.append_thinking(&part.text, try string(text));
                if (non_null(block, "signature")) |signature| try self.append_thinking(&part.signature, try string(signature));
            }
        } else if (std.mem.eql(u8, kind, "tool_use")) {
            if (self.request.tool_choice == .none) return error.UnexpectedToolCall;
            if (self.tools.items.len == self.limits.tool_calls) return error.TooManyTools;
            const id = try string(block.get("id") orelse return error.InvalidToolCallId);
            const name = try string(block.get("name") orelse return error.InvalidToolName);
            if (id.len == 0 or id.len > self.limits.identity_bytes) return error.InvalidToolCallId;
            for (self.tools.items) |tool| if (std.mem.eql(u8, tool.id, id)) return error.ConflictingIdentity;
            if (name.len == 0 or name.len > 128) return error.InvalidToolName;
            const owned_id = try self.alloc.dupe(u8, id);
            errdefer self.alloc.free(owned_id);
            const owned_name = try self.alloc.dupe(u8, protocol.canonical_tool_name(self.request.tools, name));
            errdefer self.alloc.free(owned_name);
            var tool: Tool = .{ .id = owned_id, .name = owned_name };
            errdefer tool.arguments.deinit(self.alloc);
            // Some compatible servers send the whole input at start.
            if (non_null(block, "input")) |input| if (input == .object and input.object.count() != 0) {
                const encoded = try std.json.Stringify.valueAlloc(self.alloc, input, .{});
                defer self.alloc.free(encoded);
                if (encoded.len > self.limits.arguments_bytes) return error.ArgumentsTooLarge;
                try tool.arguments.appendSlice(self.alloc, encoded);
            };
            try self.tools.append(self.alloc, tool);
            try self.blocks.append(self.alloc, .{ .kind = .tool_use, .slot = self.tools.items.len - 1 });
        } else {
            // Server tool blocks and future kinds carry nothing fx acts on.
            try self.blocks.append(self.alloc, .{ .kind = .ignored });
        }
    }

    fn accept_delta(self: *Reducer, block: Block, delta: std.json.ObjectMap) Error!Deltas {
        const kind = try string(delta.get("type") orelse return error.InvalidChunk);
        switch (block.kind) {
            .ignored => return .{},
            .text => {
                if (std.mem.eql(u8, kind, "citations_delta")) return .{};
                if (!std.mem.eql(u8, kind, "text_delta")) return error.InvalidChunk;
                return .{ .content = try self.append_content(try string(delta.get("text") orelse return error.InvalidChunk)) };
            },
            .thinking => {
                const part = &self.thinking.items[block.slot];
                if (std.mem.eql(u8, kind, "signature_delta")) {
                    try self.append_thinking(&part.signature, try string(delta.get("signature") orelse return error.InvalidChunk));
                    return .{};
                }
                if (!std.mem.eql(u8, kind, "thinking_delta")) return error.InvalidChunk;
                const text = try string(delta.get("thinking") orelse return error.InvalidChunk);
                const start = part.text.items.len;
                try self.append_thinking(&part.text, text);
                return .{ .reasoning = if (text.len != 0) part.text.items[start..] else null };
            },
            .redacted => return error.InvalidChunk,
            .tool_use => {
                if (!std.mem.eql(u8, kind, "input_json_delta")) return error.InvalidChunk;
                const tool = &self.tools.items[block.slot];
                if (!tool.streamed) {
                    tool.arguments.clearRetainingCapacity();
                    tool.emitted = 0;
                    tool.streamed = true;
                }
                const fragment = try string(delta.get("partial_json") orelse return error.InvalidChunk);
                if (fragment.len > self.limits.arguments_bytes - tool.arguments.items.len) return error.ArgumentsTooLarge;
                try tool.arguments.appendSlice(self.alloc, fragment);
                return .{};
            },
        }
    }

    /// Tells `sink` about each tool_use block once it starts, then about the
    /// input bytes it gained since the last report. Presentation only; slices
    /// borrow reducer storage for the synchronous call.
    pub fn emit_tool_progress(self: *Reducer, sink: stream_provider.EventSink) void {
        for (self.tools.items, 0..) |*tool, index| {
            if (!tool.announced) {
                tool.announced = true;
                sink.emit(.{ .tool_started = .{ .id = tool.id, .name = tool.name } });
            }
            // Input sent whole at start streams out only if no deltas replace it.
            if (tool.arguments.items.len > tool.emitted) {
                sink.emit(.{ .tool_input_delta = .{ .id = tool.id, .index = index, .chunk = tool.arguments.items[tool.emitted..] } });
                tool.emitted = tool.arguments.items.len;
            }
        }
    }

    fn append_content(self: *Reducer, text: []const u8) Error!?[]const u8 {
        if (text.len > self.limits.content_bytes - self.content.items.len) return error.ContentTooLarge;
        const start = self.content.items.len;
        try self.content.appendSlice(self.alloc, text);
        return if (text.len != 0) self.content.items[start..] else null;
    }

    fn append_thinking(self: *Reducer, destination: *std.ArrayList(u8), text: []const u8) Error!void {
        const limit = @min(self.limits.reasoning_bytes, types.ProviderReplay.max_bytes);
        if (text.len > limit - self.thinking_bytes) return error.ReplayTooLarge;
        self.thinking_bytes += text.len;
        try destination.appendSlice(self.alloc, text);
    }

    /// Later reports replace earlier ones field by field: message_delta
    /// carries cumulative counts and may restate input once it is known.
    fn accept_usage(self: *Reducer, value: std.json.Value) Error!void {
        const fields = try object(value);
        const names = [_][]const u8{ "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens" };
        const slots = [_]*?u64{ &self.usage.input, &self.usage.output, &self.usage.cache_write, &self.usage.cache_read };
        for (names, slots) |name, slot| if (try token_count(fields, name)) |count| {
            slot.* = count;
        };
    }

    /// Input counts every prompt token, cached or not, matching the other
    /// transports; the cache split is reported beside it.
    fn final_usage(self: *const Reducer) types.Usage {
        const known = self.usage.input != null or self.usage.cache_read != null or self.usage.cache_write != null;
        return .{
            .input_tokens = if (known) (self.usage.input orelse 0) +| (self.usage.cache_read orelse 0) +| (self.usage.cache_write orelse 0) else null,
            .output_tokens = self.usage.output,
            .cache_read_tokens = self.usage.cache_read,
            .cache_write_tokens = self.usage.cache_write,
        };
    }

    /// The replay envelope: signed and redacted thinking in order, bound to
    /// this response's call IDs. Unsigned thinking cannot be replayed and is
    /// left out. Caller owns the result.
    fn replay_state(self: *const Reducer) (Error || std.Io.Writer.Error)!?[]u8 {
        var any = false;
        for (self.thinking.items) |part| any = any or part.signature.items.len != 0;
        if (!any) return null;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("{\"" ++ protocol.thinking_field ++ "\":[");
        var count: usize = 0;
        for (self.thinking.items) |part| {
            if (part.signature.items.len == 0) continue;
            if (count != 0) try w.writeByte(',');
            count += 1;
            if (part.redacted) {
                try w.writeAll("{\"type\":\"redacted_thinking\",\"data\":");
                try std.json.Stringify.value(part.signature.items, .{}, w);
            } else {
                try w.writeAll("{\"type\":\"thinking\",\"thinking\":");
                try std.json.Stringify.value(part.text.items, .{}, w);
                try w.writeAll(",\"signature\":");
                try std.json.Stringify.value(part.signature.items, .{}, w);
            }
            try w.writeByte('}');
        }
        try w.writeAll("],\"" ++ protocol.association_field ++ "\":[");
        for (self.tools.items, 0..) |tool, index| {
            if (index != 0) try w.writeByte(',');
            try std.json.Stringify.value(tool.id, .{}, w);
        }
        try w.writeAll("]}");
        if (out.written().len > @min(self.limits.reasoning_bytes, types.ProviderReplay.max_bytes)) return error.ReplayTooLarge;
        return try out.toOwnedSlice();
    }

    /// Requires message_stop after a stop reason, or an error event.
    pub fn finish(self: *Reducer, cancelled: bool) Error!stream_provider.Result {
        errdefer self.phase = .closed;
        if (cancelled) return error.Cancelled;
        if (self.phase == .failed) {
            const failure = self.failure.?;
            self.failure = null;
            self.phase = .closed;
            return .{ .failed = .{ .kind = failure.kind, .detail = failure.detail, .ownership = .owned } };
        }
        if (self.phase != .done) return error.IncompleteStream;
        const raw = self.stop_reason.?;
        const reason: types.ProviderFinishReason = if (std.mem.eql(u8, raw, "end_turn") or std.mem.eql(u8, raw, "stop_sequence"))
            .stop
        else if (std.mem.eql(u8, raw, "tool_use"))
            .tool_calls
        else if (std.mem.eql(u8, raw, "max_tokens") or std.mem.eql(u8, raw, "model_context_window_exceeded"))
            return error.OutputTruncated
        else if (std.mem.eql(u8, raw, "refusal"))
            return error.Refused
        else
            return error.InvalidFinishReason;
        if ((reason == .tool_calls) != (self.tools.items.len != 0)) return error.InconsistentFinishReason;
        if (self.request.tool_choice == .required and self.tools.items.len == 0) return error.RequiredToolMissing;
        for (self.tools.items) |*tool| {
            if (tool.arguments.items.len == 0) try tool.arguments.appendSlice(self.alloc, "{}");
            try chat.check_json_depth(tool.arguments.items);
        }
        const provider_state = self.replay_state() catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |failure| return failure,
        };
        errdefer if (provider_state) |state| self.alloc.free(state);
        const calls = try self.alloc.alloc(types.ToolCall, self.tools.items.len);
        errdefer self.alloc.free(calls);
        var moved: usize = 0;
        errdefer for (calls[0..moved]) |call| self.alloc.free(call.arguments_json);
        for (self.tools.items, calls) |*tool, *call| {
            call.* = .{ .id = tool.id, .name = tool.name, .arguments_json = try tool.arguments.toOwnedSlice(self.alloc) };
            moved += 1;
        }
        const content = if (self.content.items.len != 0) try self.content.toOwnedSlice(self.alloc) else null;
        // Ownership of ids and names moves to the result only once nothing can fail.
        for (self.tools.items) |*tool| {
            tool.id = &.{};
            tool.name = &.{};
        }
        const generation_id = self.message_id;
        self.message_id = null;
        self.phase = .closed;
        return .{ .completed = .{
            .completion = .{ .content = content, .tool_calls = calls, .generation_id = generation_id, .finish_reason = reason, .usage = self.final_usage(), .provider_state_json = provider_state },
            .ownership = .owned,
        } };
    }
};

fn failure_kind(value: std.json.Value) stream_provider.FailureKind {
    if (value != .object) return .provider_error;
    const kind = value.object.get("type") orelse return .provider_error;
    if (kind != .string) return .provider_error;
    const table = [_]struct { []const u8, stream_provider.FailureKind }{
        .{ "overloaded_error", .unavailable },        .{ "rate_limit_error", .rate_limited },
        .{ "api_error", .server_error },              .{ "invalid_request_error", .invalid_request },
        .{ "authentication_error", .unauthorized },   .{ "permission_error", .forbidden },
        .{ "request_too_large", .request_too_large }, .{ "timeout_error", .gateway_timeout },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], kind.string)) return entry[1];
    return .provider_error;
}

fn object(value: std.json.Value) Error!std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidChunk;
}

fn string(value: std.json.Value) Error![]const u8 {
    return if (value == .string) value.string else error.InvalidChunk;
}

fn non_null(fields: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const value = fields.get(key) orelse return null;
    return if (value == .null) null else value;
}

fn integer(value: std.json.Value) Error!i64 {
    return switch (value) {
        .integer => value.integer,
        .number_string => std.fmt.parseInt(i64, value.number_string, 10) catch error.InvalidChunk,
        else => error.InvalidChunk,
    };
}

fn index_value(value: std.json.Value) Error!usize {
    return std.math.cast(usize, try integer(value)) orelse error.InvalidChunk;
}

fn token_count(fields: std.json.ObjectMap, key: []const u8) Error!?u64 {
    const value = non_null(fields, key) orelse return null;
    return std.math.cast(u64, try integer(value)) orelse error.InvalidChunk;
}

/// Reads framed events until message_stop or an error event, emitting text
/// and thinking deltas to `events`. `progress` is told about each event.
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
        if (events) |sink| {
            if (deltas.reasoning) |text| {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                sink.emit(.{ .reasoning_delta = text });
            }
            if (deltas.content) |text| {
                if (cancel_flag.load(.seq_cst)) return error.Cancelled;
                sink.emit(.{ .content_delta = text });
            }
            if (cancel_flag.load(.seq_cst)) return error.Cancelled;
            reducer.emit_tool_progress(sink);
        }
        if (reducer.phase == .done or reducer.phase == .failed) return reducer.finish(cancel_flag.load(.seq_cst));
    }
}

test {
    _ = @import("anthropic_messages_stream_tests.zig");
}
