//! The native/Wasm adapter for the shared semantic observer. This deliberately
//! projects safe fields instead of serializing requests, history, or replay state.
const std = @import("std");
const observation = @import("../core/agent/runtime/observation.zig");
const types = @import("../core/shared/types.zig");
const limits = @import("../core/config/context_limits.zig");
const schemas = @import("../core/tooling/model_tool_schema.zig");
const io_mod = @import("../core/shared/io.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const jsonrpc = @import("jsonrpc.zig");
const acp_types = @import("types.zig");
const journal = @import("../core/agent/runtime/journal.zig");

pub const Config = struct { capture_content: bool = false };

pub fn parseConfig(alloc: std.mem.Allocator, raw: ?[]const u8) !?Config {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw orelse "{}", .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHooks;
    const hooks = parsed.value.object.get("hooks") orelse acp_types.fxMetaField(parsed.value.object, "hooks") orelse return null;
    if (hooks != .object) return error.InvalidHooks;
    const capture = hooks.object.get("captureContent") orelse return Config{};
    if (capture != .bool) return error.InvalidHooks;
    return .{ .capture_content = capture.bool };
}

pub const Bridge = struct {
    enabled: bool = false,
    alloc: std.mem.Allocator,
    writer: *jsonrpc.Writer,
    session_id: []const u8,
    root_session_id: []const u8,
    parent_session_id: ?[]const u8 = null,
    source_session_id: ?[]const u8 = null,
    work_id: ?[]const u8 = null,
    turn_id: []const u8,
    turn_id_storage: [@max(journal.max_turn_id_bytes, 32)]u8,
    session_id_storage: [255]u8,
    execution_id: acp_types.MessageIdBuffer,
    config: Config,
    observer: observation.Observer,

    pub fn init(self: *Bridge, alloc: std.mem.Allocator, writer: *jsonrpc.Writer, session_id: []const u8, turn_id: ?[]const u8, config: Config) void {
        self.* = .{
            .alloc = alloc,
            .writer = writer,
            .session_id = "",
            .root_session_id = "",
            .turn_id = "",
            .turn_id_storage = undefined,
            .session_id_storage = undefined,
            .execution_id = undefined,
            .config = config,
            .observer = .{ .sink = .{ .context = self, .emit_fn = emit } },
        };
        const turn_len = if (turn_id) |id| id.len else self.execution_id.len;
        if (session_id.len > self.session_id_storage.len or turn_len > self.turn_id_storage.len) {
            debug_trace.logf("hooks", "observation disabled: identity length exceeds capacity session_bytes={d} turn_bytes={d}", .{ session_id.len, turn_len });
            return;
        }
        _ = acp_types.generateMessageId(&self.execution_id);
        @memcpy(self.session_id_storage[0..session_id.len], session_id);
        self.session_id = self.session_id_storage[0..session_id.len];
        self.root_session_id = self.session_id;
        const id = turn_id orelse &self.execution_id;
        @memcpy(self.turn_id_storage[0..id.len], id);
        self.turn_id = self.turn_id_storage[0..id.len];
        self.enabled = true;
    }

    fn emit(raw: *anyopaque, step: usize, event: observation.Event) void {
        const self: *Bridge = @ptrCast(@alignCast(raw));
        if (!self.enabled) return;
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        std.json.Stringify.value(WireEvent{ .bridge = self, .step = step, .event = event }, .{}, &out.writer) catch |err| {
            debug_trace.logf("hooks", "event encoding failed err={s}", .{@errorName(err)});
            return;
        };
        self.writer.writeNotification(self.alloc, "libfx/hook", out.written()) catch |err| {
            debug_trace.logf("hooks", "event delivery failed err={s}", .{@errorName(err)});
        };
    }
};

const max_content_bytes = 64 * 1024;
const max_entries = 128;

const MessageAllotment = struct { content: usize, arguments: []const usize };
const ModelAllotment = struct {
    messages: []const MessageAllotment,
    instructions: []const MessageAllotment,
    descriptions: []const usize,
    schemas: []const ?[]const u8,
    tools_json: ?[]const u8,
};

const Content = struct {
    alloc: std.mem.Allocator,
    enabled: bool,
    remaining: usize = max_content_bytes,
    truncated: bool = false,

    fn allot(self: *Content, value: ?[]const u8) usize {
        if (!self.enabled) return 0;
        const text_value = value orelse return 0;
        const count = limits.utf8PrefixLength(text_value, self.remaining);
        self.remaining -= count;
        self.truncated = self.truncated or count < text_value.len;
        return count;
    }

    fn text(self: *Content, value: ?[]const u8, max: usize) ?[]const u8 {
        if (!self.enabled) return null;
        const text_value = value orelse return null;
        const count = limits.utf8PrefixLength(text_value, max);
        self.truncated = self.truncated or count < text_value.len;
        return text_value[0..count];
    }

    fn writeText(self: *Content, writer: *std.json.Stringify, name: []const u8, value: ?[]const u8) !void {
        return self.writeAllottedText(writer, name, value, self.allot(value));
    }

    fn writeAllottedText(self: *Content, writer: *std.json.Stringify, name: []const u8, value: ?[]const u8, max: usize) !void {
        if (!self.enabled) return;
        try field(writer, name, self.text(value, max));
    }

    fn calls(self: *Content, writer: *std.json.Stringify, calls_value: []const types.ToolCall) !void {
        try writer.beginArray();
        for (calls_value[0..@min(calls_value.len, max_entries)]) |value| try self.call(writer, value);
        self.truncated = self.truncated or calls_value.len > max_entries;
        try writer.endArray();
    }

    fn call(self: *Content, writer: *std.json.Stringify, value: types.ToolCall) !void {
        return self.allottedCall(writer, value, self.allot(value.arguments_json));
    }

    fn allottedCall(self: *Content, writer: *std.json.Stringify, value: types.ToolCall, max: usize) !void {
        try writer.beginObject();
        try field(writer, "callId", value.id);
        try field(writer, "name", value.name);
        try field(writer, "provenance", @tagName(value.provenance));
        try self.writeAllottedText(writer, "argumentsJson", value.arguments_json, max);
        try writer.endObject();
    }

    fn messages(self: *Content, writer: *std.json.Stringify, name: []const u8, values: []const types.ChatMessage, allotments: []const MessageAllotment) !void {
        if (!self.enabled) return;
        try writer.objectField(name);
        try writer.beginArray();
        for (values[values.len -| max_entries..], allotments) |message, allotted| {
            try writer.beginObject();
            try field(writer, "role", @tagName(message.role));
            try self.writeAllottedText(writer, "content", message.content, allotted.content);
            try field(writer, "toolCallId", message.tool_call_id);
            try field(writer, "toolName", message.tool_name);
            try field(writer, "toolResultStatus", message.tool_result_status);
            try field(writer, "imageCount", message.images.len);
            try writer.objectField("toolCalls");
            try writer.beginArray();
            for (message.tool_calls[0..allotted.arguments.len], allotted.arguments) |tool_call, max| try self.allottedCall(writer, tool_call, max);
            self.truncated = self.truncated or message.tool_calls.len > allotted.arguments.len;
            try writer.endArray();
            try writer.endObject();
        }
        self.truncated = self.truncated or values.len > max_entries;
        try writer.endArray();
    }

    fn schema(self: *Content, alloc: std.mem.Allocator, value: anytype) !?[]const u8 {
        // A schema is either complete JSON or null, never a JSON prefix posing
        // as a usable schema. Bound its serialization before allocating a copy.
        var storage: [8192]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        const success = if (@TypeOf(value) == schemas.ObjectSchema) blk: {
            schemas.writeObjectSchema(self.alloc, &out, value) catch break :blk false;
            break :blk true;
        } else blk: {
            std.json.Stringify.value(value, .{}, &out) catch break :blk false;
            break :blk true;
        };
        if (!success or out.buffered().len > self.remaining) {
            self.truncated = true;
            return null;
        }
        self.remaining -= out.buffered().len;
        return try alloc.dupe(u8, out.buffered());
    }

    fn planMessages(self: *Content, alloc: std.mem.Allocator, values: []const types.ChatMessage, newest_first: bool) ![]const MessageAllotment {
        const tail = values[values.len -| max_entries..];
        self.truncated = self.truncated or values.len > tail.len;
        const planned = try alloc.alloc(MessageAllotment, tail.len);
        for (0..tail.len) |offset| {
            const index = if (newest_first) tail.len - 1 - offset else offset;
            const message = tail[index];
            const arguments = try alloc.alloc(usize, @min(message.tool_calls.len, max_entries));
            planned[index] = .{ .content = self.allot(message.content), .arguments = arguments };
            for (message.tool_calls[0..arguments.len], arguments) |tool_call, *max| max.* = self.allot(tool_call.arguments_json);
        }
        return planned;
    }

    fn planModel(self: *Content, alloc: std.mem.Allocator, value: anytype) !ModelAllotment {
        // Reserve by relevance, then serialize in the original wire order.
        const messages_plan = try self.planMessages(alloc, value.request.messages, true);
        const instructions_plan = try self.planMessages(alloc, value.request.instructions, false);
        const tool_count = @min(max_entries, value.request.tools.advertised_functions.len + value.request.tools.additional_functions.len + value.request.tools.selected_dynamic.len);
        const descriptions = try alloc.alloc(usize, tool_count);
        const schema_values = try alloc.alloc(?[]const u8, tool_count);
        var index: usize = 0;
        inline for (.{ value.request.tools.advertised_functions, value.request.tools.additional_functions, value.request.tools.selected_dynamic }) |tools| {
            for (tools) |tool| {
                if (index == tool_count) break;
                descriptions[index] = self.allot(tool.description);
                index += 1;
            }
        }
        index = 0;
        inline for (.{ value.request.tools.advertised_functions, value.request.tools.additional_functions, value.request.tools.selected_dynamic }) |tools| {
            for (tools) |tool| {
                if (index == tool_count) break;
                schema_values[index] = try self.schema(alloc, tool.input_schema);
                index += 1;
            }
        }
        var tools_json: ?[]const u8 = null;
        if (value.tools_json) |json| {
            if (json.len <= self.remaining) {
                self.remaining -= json.len;
                tools_json = json;
            } else self.truncated = true;
        }
        return .{ .messages = messages_plan, .instructions = instructions_plan, .descriptions = descriptions, .schemas = schema_values, .tools_json = tools_json };
    }
};

fn field(writer: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try writer.objectField(name);
    try writer.write(value);
}

const WireEvent = struct {
    bridge: *const Bridge,
    step: usize,
    event: observation.Event,

    pub fn jsonStringify(self: WireEvent, writer: *std.json.Stringify) !void {
        const names = .{
            .turn_start = "turn.start",
            .turn_end = "turn.end",
            .step_start = "step.start",
            .step_end = "step.end",
            .model_start = "model.start",
            .model_admitted = "model.admitted",
            .model_output_start = "model.output_start",
            .model_end = "model.end",
            .tool_start = "tool.start",
            .tool_end = "tool.end",
            .tool_result = "tool.result",
            .permission_start = "permission.start",
            .permission_end = "permission.end",
            .wait_start = "wait.start",
            .wait_end = "wait.end",
            .mcp_start = "mcp.start",
            .mcp_request = "mcp.request",
            .mcp_end = "mcp.end",
            .delegation = "delegation",
        };
        try writer.beginObject();
        try field(writer, "version", @as(u8, 1));
        try field(writer, "sessionId", self.bridge.session_id);
        try field(writer, "rootSessionId", self.bridge.root_session_id);
        try field(writer, "parentSessionId", self.bridge.parent_session_id);
        try field(writer, "sourceSessionId", self.bridge.source_session_id);
        try field(writer, "workId", self.bridge.work_id);
        try field(writer, "turnId", self.bridge.turn_id);
        try field(writer, "executionId", &self.bridge.execution_id);
        try field(writer, "stepIndex", self.step);
        try field(writer, "timestamp", io_mod.milliTimestamp());
        inline for (@typeInfo(observation.Event).@"union".field_names) |name| {
            if (self.event == @field(std.meta.Tag(observation.Event), name)) try field(writer, "type", @field(names, name));
        }
        var content = Content{ .alloc = self.bridge.alloc, .enabled = self.bridge.config.capture_content };
        try writer.objectField("data");
        try writer.beginObject();
        switch (self.event) {
            .turn_start => |value| {
                try field(writer, "resumed", value.resumed);
                try content.writeText(writer, "input", value.input);
            },
            .turn_end => |value| {
                try field(writer, "outcome", @tagName(value.outcome));
                try field(writer, "error", value.error_name);
            },
            .step_start, .step_end => {},
            .model_start => |value| {
                var scratch = std.heap.ArenaAllocator.init(self.bridge.alloc);
                defer scratch.deinit();
                const plan: ModelAllotment = if (content.enabled) content.planModel(scratch.allocator(), value) catch return error.WriteFailed else .{ .messages = &.{}, .instructions = &.{}, .descriptions = &.{}, .schemas = &.{}, .tools_json = null };
                try field(writer, "modelCallId", value.id);
                try field(writer, "parentCallId", value.parent_call_id);
                try field(writer, "purpose", @tagName(value.purpose));
                if (content.enabled and value.tools_json != null) try field(writer, "toolsJson", plan.tools_json);
                try field(writer, "model", value.request.model);
                try field(writer, "toolChoice", @tagName(value.request.tool_choice));
                try field(writer, "maxOutputTokens", value.request.max_output_tokens);
                try field(writer, "messageCount", value.request.messages.len);
                try content.messages(writer, "instructions", value.request.instructions, plan.instructions);
                try content.messages(writer, "messages", value.request.messages, plan.messages);
                try writer.objectField("tools");
                try writer.beginArray();
                var count: usize = 0;
                inline for (.{ value.request.tools.advertised_functions, value.request.tools.additional_functions, value.request.tools.selected_dynamic }) |tools| {
                    for (tools) |tool| {
                        if (count == max_entries) {
                            content.truncated = true;
                            break;
                        }
                        try writer.beginObject();
                        try field(writer, "name", tool.name);
                        if (content.enabled) {
                            try content.writeAllottedText(writer, "description", tool.description, plan.descriptions[count]);
                            try field(writer, "inputSchemaJson", plan.schemas[count]);
                        }
                        count += 1;
                        try writer.endObject();
                    }
                }
                try writer.endArray();
            },
            .model_admitted, .model_output_start => |id| try field(writer, "modelCallId", id),
            .model_end => |value| {
                try field(writer, "modelCallId", value.id);
                try field(writer, "error", value.error_name);
                try field(writer, "cancelled", value.cancelled);
                if (value.completion) |completion| {
                    try content.writeText(writer, "output", completion.content);
                    try field(writer, "finishReason", if (completion.finish_reason) |reason| reason.label() else @as(?[]const u8, null));
                    try field(writer, "generationId", completion.generation_id);
                    try field(writer, "provider", completion.resolved_provider);
                    try field(writer, "usage", .{
                        .inputTokens = completion.usage.input_tokens,
                        .outputTokens = completion.usage.output_tokens,
                        .cacheReadTokens = completion.usage.cache_read_tokens,
                        .cacheWriteTokens = completion.usage.cache_write_tokens,
                        .reasoningTokens = completion.usage.reasoning_tokens,
                    });
                    try writer.objectField("toolCalls");
                    try content.calls(writer, completion.tool_calls);
                }
            },
            .tool_start => |value| {
                try writer.objectField("call");
                try content.call(writer, value.call);
                try field(writer, "rerun", value.rerun);
            },
            .permission_start => |call| {
                try writer.objectField("call");
                try content.call(writer, call);
            },
            .tool_end => |value| {
                try writer.objectField("call");
                try content.call(writer, value.call);
                try content.writeText(writer, "output", value.output);
                try field(writer, "status", value.status);
                try field(writer, "error", value.error_name);
                if (value.usage) |usage| try field(writer, "usage", .{ .inputTokens = usage.input_tokens, .outputTokens = usage.output_tokens, .webSearchRequests = usage.web_search_requests });
            },
            .tool_result => |value| {
                try writer.objectField("call");
                try content.call(writer, value.call);
                try content.writeText(writer, "output", value.output);
                try field(writer, "status", @tagName(value.status));
            },
            .permission_end => |value| {
                try writer.objectField("call");
                try content.call(writer, value.call);
                try field(writer, "decision", value.decision);
                try field(writer, "error", value.error_name);
            },
            .wait_start => |value| {
                try field(writer, "requestId", value.id);
                try field(writer, "kind", value.request.kind);
                try field(writer, "callId", value.request.call_id);
                try field(writer, "externalId", value.request.external_id);
                try field(writer, "server", value.request.server_name);
                try content.writeText(writer, "prompt", value.request.prompt);
                try content.writeText(writer, "schemaJson", value.request.schema_json);
                try field(writer, "questionCount", value.request.questions.len);
                if (content.enabled) {
                    try writer.objectField("questions");
                    try writer.beginArray();
                    for (value.request.questions[0..@min(value.request.questions.len, max_entries)]) |question| {
                        try writer.beginObject();
                        try content.writeText(writer, "question", question.question);
                        try field(writer, "submission", question.submission);
                        try writer.objectField("options");
                        try writer.beginArray();
                        for (question.options[0..@min(question.options.len, max_entries)]) |option| {
                            try writer.beginObject();
                            try content.writeText(writer, "label", option.label);
                            try content.writeText(writer, "description", option.description);
                            try writer.endObject();
                        }
                        content.truncated = content.truncated or question.options.len > max_entries;
                        try writer.endArray();
                        try writer.endObject();
                    }
                    content.truncated = content.truncated or value.request.questions.len > max_entries;
                    try writer.endArray();
                }
            },
            .wait_end => |value| {
                try field(writer, "requestId", value.id);
                try field(writer, "outcome", value.outcome);
                try field(writer, "error", value.error_name);
                if (content.enabled) {
                    try writer.objectField("answers");
                    try writer.beginArray();
                    for (value.answers[0..@min(value.answers.len, max_entries)]) |answer| try writer.write(content.text(answer, content.allot(answer)));
                    content.truncated = content.truncated or value.answers.len > max_entries;
                    try writer.endArray();
                }
            },
            .mcp_start => |value| {
                try field(writer, "operationId", value.id);
                try field(writer, "callId", value.identity.call_id);
                try field(writer, "server", value.identity.server);
                try field(writer, "tool", value.identity.tool);
                try field(writer, "transport", value.identity.transport);
            },
            .mcp_request => |value| {
                try field(writer, "operationId", value.id);
                try field(writer, "requestId", value.request_id);
                try field(writer, "requestIdKind", value.kind);
            },
            .mcp_end => |value| {
                try field(writer, "operationId", value.id);
                try field(writer, "status", value.status);
                try field(writer, "error", value.error_name);
            },
            .delegation => |value| {
                try field(writer, "callId", value.call_id);
                try field(writer, "childSessionId", value.child_id);
                try field(writer, "workId", value.work_id);
                try field(writer, "operationId", value.operation_id);
                try field(writer, "phase", value.phase);
            },
        }
        try writer.endObject();
        try field(writer, "contentCaptured", content.enabled);
        try field(writer, "contentTruncated", content.truncated);
        try writer.endObject();
    }
};

test "libfx hook content is opt in bounded and excludes opaque provider state" {
    const alloc = std.testing.allocator;
    const secret_message = types.ChatMessage{ .role = .assistant, .content = "visible", .provider_replay = .{ .source = .{ .provider = .gateway, .model = "fixture" }, .parts_json = "opaque-secret" } };
    var bridge: Bridge = undefined;
    // Only the serialization fields are used by this test.
    bridge.session_id = "fixture-session";
    bridge.root_session_id = "fixture-session";
    bridge.parent_session_id = null;
    bridge.source_session_id = null;
    bridge.work_id = null;
    bridge.alloc = alloc;
    bridge.turn_id = "fixture-turn";
    @memset(&bridge.execution_id, 'a');
    for ([_]bool{ false, true }) |capture| {
        bridge.config = .{ .capture_content = capture };
        const wire = WireEvent{ .bridge = &bridge, .step = 1, .event = .{ .model_start = .{ .id = 1, .purpose = .agent, .request = .{
            .model = "fixture",
            .messages = &.{secret_message},
            .tool_choice = .none,
            .provider_options = .{},
        } } } };
        const encoded = try std.json.Stringify.valueAlloc(alloc, wire, .{});
        defer alloc.free(encoded);
        try std.testing.expect(std.mem.find(u8, encoded, "opaque-secret") == null);
        try std.testing.expect((std.mem.find(u8, encoded, "visible") != null) == capture);
    }
    const long = try alloc.alloc(u8, max_content_bytes + 4);
    defer alloc.free(long);
    @memset(long, 'x');
    var budget = Content{ .alloc = alloc, .enabled = true };
    try std.testing.expectEqual(@as(usize, max_content_bytes), budget.text(long, budget.allot(long)).?.len);
    try std.testing.expect(budget.truncated);
    try std.testing.expectEqual(@as(usize, 0), budget.text("extra", budget.allot("extra")).?.len);
}

test "libfx model capture reserves the newest messages before instructions" {
    const alloc = std.testing.allocator;
    const Capture = struct {
        fn write(_: ?*anyopaque, _: []const u8) !void {}
    };
    var writer = jsonrpc.Writer.initCallback(null, Capture.write);
    var bridge: Bridge = undefined;
    bridge.init(alloc, &writer, "fixture-session", "fixture-turn", .{ .capture_content = true });
    const instructions = try alloc.alloc(u8, max_content_bytes);
    defer alloc.free(instructions);
    @memset(instructions, 'x');
    const messages = try alloc.alloc(types.ChatMessage, max_entries + 1);
    defer alloc.free(messages);
    for (messages) |*message| message.* = .{ .role = .user, .content = "history" };
    messages[0].content = "obsolete";
    messages[max_entries].content = "needle";
    const wire = WireEvent{ .bridge = &bridge, .step = 1, .event = .{ .model_start = .{ .id = 1, .purpose = .agent, .request = .{
        .model = "fixture",
        .instructions = &.{.{ .role = .system, .content = instructions }},
        .messages = messages,
        .tool_choice = .none,
        .provider_options = .{},
    } } } };
    const encoded = try std.json.Stringify.valueAlloc(alloc, wire, .{});
    defer alloc.free(encoded);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded, .{});
    defer parsed.deinit();
    const captured = parsed.value.object.get("data").?.object.get("messages").?.array.items;
    try std.testing.expectEqual(max_entries, captured.len);
    try std.testing.expectEqualStrings("needle", captured[captured.len - 1].object.get("content").?.string);
    try std.testing.expect(std.mem.find(u8, encoded, "obsolete") == null);
    var total: usize = 0;
    for (captured) |message| total += message.object.get("content").?.string.len;
    for (parsed.value.object.get("data").?.object.get("instructions").?.array.items) |message| total += message.object.get("content").?.string.len;
    try std.testing.expectEqual(max_content_bytes, total);
    try std.testing.expect(parsed.value.object.get("contentTruncated").?.bool);
}

test "libfx hook bridge owns session and turn identities" {
    const Capture = struct {
        fn write(_: ?*anyopaque, _: []const u8) !void {}
    };
    var writer = jsonrpc.Writer.initCallback(null, Capture.write);
    var session = [_]u8{ 'c', 'h', 'i', 'l', 'd' };
    var turn = [_]u8{ 't', 'u', 'r', 'n' };
    var bridge: Bridge = undefined;
    bridge.init(std.testing.allocator, &writer, &session, &turn, .{});
    @memset(&session, 0xaa);
    @memset(&turn, 0xaa);
    try std.testing.expectEqualStrings("child", bridge.session_id);
    try std.testing.expectEqualStrings("child", bridge.root_session_id);
    try std.testing.expectEqualStrings("turn", bridge.turn_id);
}

test "libfx hook bridge disables observation for overlong identities in every build mode" {
    const Capture = struct {
        writes: usize = 0,
        fn write(raw: ?*anyopaque, _: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.writes += 1;
        }
    };
    var capture: Capture = .{};
    var writer = jsonrpc.Writer.initCallback(&capture, Capture.write);
    var session: [256]u8 = @splat('s');
    var turn: [journal.max_turn_id_bytes + 1]u8 = @splat('t');
    var bridge: Bridge = undefined;
    bridge.init(std.testing.allocator, &writer, &session, "turn", .{});
    try std.testing.expect(!bridge.enabled);
    bridge.observer.beginTurn("input", false);
    bridge.observer.endTurn(.completed, null);
    bridge.init(std.testing.allocator, &writer, "session", &turn, .{});
    try std.testing.expect(!bridge.enabled);
    bridge.observer.beginTurn("input", false);
    bridge.observer.endTurn(.completed, null);
    try std.testing.expectEqual(@as(usize, 0), capture.writes);
    bridge.init(std.testing.allocator, &writer, session[0..255], turn[0..journal.max_turn_id_bytes], .{});
    try std.testing.expect(bridge.enabled);
}

test "libfx hooks are disabled by default and reject invalid capture configuration" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try parseConfig(alloc, null) == null);
    try std.testing.expect(try parseConfig(alloc, "{}") == null);
    try std.testing.expect(!(try parseConfig(alloc, "{\"hooks\":{}}")).?.capture_content);
    try std.testing.expect((try parseConfig(alloc, "{\"hooks\":{\"captureContent\":true}}")).?.capture_content);
    try std.testing.expectError(error.InvalidHooks, parseConfig(alloc, "{\"hooks\":true}"));
    try std.testing.expectError(error.InvalidHooks, parseConfig(alloc, "{\"hooks\":{\"captureContent\":\"true\"}}"));
}

test "libfx hook encoding failure cannot fail the execution callback" {
    const Capture = struct {
        fn write(_: ?*anyopaque, _: []const u8) !void {
            return error.UnexpectedWrite;
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var writer = jsonrpc.Writer.initCallback(null, Capture.write);
    var bridge: Bridge = undefined;
    bridge.init(failing.allocator(), &writer, "fixture-session", "fixture-turn", .{});
    bridge.observer.beginTurn("input", false);
    bridge.observer.endTurn(.completed, null);
    try std.testing.expect(bridge.observer.turn_ended);
}
