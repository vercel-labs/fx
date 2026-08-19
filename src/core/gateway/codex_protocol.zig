const std = @import("std");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const responses_url = "https://chatgpt.com/backend-api/codex/responses";
pub const default_model = "openai/gpt-5.6-sol";
pub const account_header = "ChatGPT-Account-ID";

const openai_prefix = "openai/";

pub fn isCodexChatUrl(url: []const u8) bool {
    return std.mem.find(u8, url, "/backend-api/codex") != null or
        std.mem.find(u8, url, "/codex/responses") != null;
}

pub fn isLoopbackHttpUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or
        uri.user != null or
        uri.password != null or
        uri.port == null)
    {
        return false;
    }
    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

pub fn effectiveChatUrl(source: ?types.CredentialSource, fallback: []const u8) []const u8 {
    if (source != .codex_oauth) return fallback;
    if (isLoopbackHttpUrl(fallback)) return fallback;
    return responses_url;
}

pub fn wireModelId(model: []const u8) []const u8 {
    const trimmed = if (std.mem.startsWith(u8, model, openai_prefix))
        model[openai_prefix.len..]
    else
        model;
    if (std.mem.startsWith(u8, trimmed, "gpt-")) return trimmed;
    return "gpt-5.6-sol";
}

pub fn resolvedModel(source: ?types.CredentialSource, model: []const u8) []const u8 {
    if (source != .codex_oauth) return model;
    if (std.mem.startsWith(u8, model, openai_prefix) or std.mem.startsWith(u8, model, "gpt-")) {
        return model;
    }
    return default_model;
}

pub const CatalogModel = struct {
    id: []const u8,
    context_window: u32,
    max_tokens: u32,
};

pub const catalog_models = [_]CatalogModel{
    .{ .id = "openai/gpt-5.6-sol", .context_window = 272_000, .max_tokens = 128_000 },
    .{ .id = "openai/gpt-5.6-terra", .context_window = 272_000, .max_tokens = 128_000 },
    .{ .id = "openai/gpt-5.6-luna", .context_window = 272_000, .max_tokens = 128_000 },
    .{ .id = "openai/gpt-5.3-codex", .context_window = 272_000, .max_tokens = 128_000 },
    .{ .id = "openai/gpt-5.2-codex", .context_window = 272_000, .max_tokens = 128_000 },
};

pub const TranslateState = struct {
    saw_tool_call: bool = false,
    calls: std.ArrayList(OpenCall) = .empty,

    const OpenCall = struct {
        item_id: []u8,
        call_id: []u8,
        name: []u8,

        fn deinit(self: *@This(), alloc: Allocator) void {
            alloc.free(self.item_id);
            alloc.free(self.call_id);
            alloc.free(self.name);
        }
    };

    pub fn deinit(self: *TranslateState, alloc: Allocator) void {
        for (self.calls.items) |*call| call.deinit(alloc);
        self.calls.deinit(alloc);
        self.* = undefined;
    }

    fn upsert(self: *TranslateState, alloc: Allocator, item_id: []const u8, call_id: []const u8, name: []const u8) !void {
        if (self.find(item_id) != null) return;
        try self.calls.append(alloc, .{
            .item_id = try alloc.dupe(u8, item_id),
            .call_id = try alloc.dupe(u8, call_id),
            .name = try alloc.dupe(u8, name),
        });
    }

    fn find(self: TranslateState, item_id: []const u8) ?*OpenCall {
        for (self.calls.items) |*call| {
            if (std.mem.eql(u8, call.item_id, item_id)) return call;
        }
        return null;
    }

    fn findByCallId(self: TranslateState, call_id: []const u8) ?*OpenCall {
        for (self.calls.items) |*call| {
            if (std.mem.eql(u8, call.call_id, call_id)) return call;
        }
        return null;
    }
};

pub fn translateGatewayPayload(
    alloc: Allocator,
    model: []const u8,
    payload: []const u8,
    session_id: ?[]const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidGatewayRequestBody,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidGatewayRequestBody;

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(wireModelId(model), .{}, &out.writer);
    try out.writer.writeAll(",\"store\":false,\"stream\":true,\"parallel_tool_calls\":false");
    try out.writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]");

    if (session_id) |id| {
        if (id.len > 0) {
            try out.writer.writeAll(",\"prompt_cache_key\":");
            try std.json.Stringify.value(id, .{}, &out.writer);
        }
    }

    var instructions: std.Io.Writer.Allocating = .init(alloc);
    defer instructions.deinit();
    try out.writer.writeAll(",\"input\":[");
    var wrote_input = false;
    if (parsed.value.object.get("prompt")) |prompt| {
        if (prompt == .array) {
            for (prompt.array.items) |message| {
                if (message != .object) continue;
                const role = objectString(message.object, "role") orelse continue;
                if (std.mem.eql(u8, role, "system")) {
                    if (messageText(message.object)) |text| {
                        if (instructions.written().len > 0) try instructions.writer.writeAll("\n\n");
                        try instructions.writer.writeAll(text);
                    }
                    continue;
                }
                if (wrote_input) try out.writer.writeByte(',');
                try writeResponsesInputMessage(alloc, &out.writer, role, message.object);
                wrote_input = true;
            }
        }
    }
    try out.writer.writeByte(']');

    if (instructions.written().len > 0) {
        try out.writer.writeAll(",\"instructions\":");
        try std.json.Stringify.value(instructions.written(), .{}, &out.writer);
    }

    if (parsed.value.object.get("tools")) |tools| {
        if (tools == .array) {
            try out.writer.writeAll(",\"tools\":[");
            var wrote_tool = false;
            for (tools.array.items) |tool| {
                if (tool != .object) continue;
                const tool_type = objectString(tool.object, "type") orelse continue;
                if (!std.mem.eql(u8, tool_type, "function")) continue;
                const name = objectString(tool.object, "name") orelse continue;
                if (wrote_tool) try out.writer.writeByte(',');
                try out.writer.writeAll("{\"type\":\"function\",\"strict\":false,\"name\":");
                try std.json.Stringify.value(name, .{}, &out.writer);
                if (objectString(tool.object, "description")) |description| {
                    try out.writer.writeAll(",\"description\":");
                    try std.json.Stringify.value(description, .{}, &out.writer);
                }
                try out.writer.writeAll(",\"parameters\":");
                if (tool.object.get("inputSchema")) |schema| {
                    try std.json.Stringify.value(schema, .{}, &out.writer);
                } else {
                    try out.writer.writeAll("{\"type\":\"object\",\"properties\":{}}");
                }
                try out.writer.writeByte('}');
                wrote_tool = true;
            }
            try out.writer.writeByte(']');
        }
    }

    var tool_choice: []const u8 = "auto";
    if (parsed.value.object.get("toolChoice")) |choice| {
        if (choice == .object) {
            if (objectString(choice.object, "type")) |kind| {
                if (std.mem.eql(u8, kind, "none")) tool_choice = "none";
                if (std.mem.eql(u8, kind, "required")) tool_choice = "required";
            }
        }
    }
    try out.writer.writeAll(",\"tool_choice\":");
    try std.json.Stringify.value(tool_choice, .{}, &out.writer);

    try out.writer.writeAll(",\"reasoning\":{\"summary\":\"auto\",\"context\":\"all_turns\"");
    if (objectString(parsed.value.object, "reasoning")) |effort| {
        if (!std.mem.eql(u8, effort, "auto")) {
            try out.writer.writeAll(",\"effort\":");
            try std.json.Stringify.value(effort, .{}, &out.writer);
        }
    }
    try out.writer.writeByte('}');

    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn translateResponsesSseData(
    alloc: Allocator,
    json_text: []const u8,
    state: *TranslateState,
) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const event_type = objectString(parsed.value.object, "type") orelse return null;

    if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
        const delta = objectString(parsed.value.object, "delta") orelse return null;
        return try writeObject(alloc, &.{
            .{ "type", .{ .string = "text-delta" } },
            .{ "delta", .{ .string = delta } },
        });
    }
    if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
        std.mem.eql(u8, event_type, "response.reasoning_text.delta") or
        std.mem.eql(u8, event_type, "response.reasoning_summary.delta"))
    {
        const delta = objectString(parsed.value.object, "delta") orelse return null;
        return try writeObject(alloc, &.{
            .{ "type", .{ .string = "reasoning-delta" } },
            .{ "delta", .{ .string = delta } },
        });
    }
    if (std.mem.eql(u8, event_type, "response.output_item.added")) {
        const item = parsed.value.object.get("item") orelse return null;
        if (item != .object) return null;
        const item_type = objectString(item.object, "type") orelse return null;
        if (!std.mem.eql(u8, item_type, "function_call")) return null;
        const call_id = objectString(item.object, "call_id") orelse return null;
        const name = objectString(item.object, "name") orelse "";
        const item_id = objectString(item.object, "id") orelse call_id;
        try state.upsert(alloc, item_id, call_id, name);
        state.saw_tool_call = true;
        return try writeToolInputStart(alloc, call_id, name);
    }
    if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
        const delta = objectString(parsed.value.object, "delta") orelse return null;
        const call_id = try resolveCallId(parsed.value.object, state) orelse return null;
        return try writeObject(alloc, &.{
            .{ "type", .{ .string = "tool-input-delta" } },
            .{ "toolCallId", .{ .string = call_id } },
            .{ "delta", .{ .string = delta } },
        });
    }
    if (std.mem.eql(u8, event_type, "response.function_call_arguments.done")) {
        const call_id = try resolveCallId(parsed.value.object, state) orelse return null;
        return try writeObject(alloc, &.{
            .{ "type", .{ .string = "tool-input-end" } },
            .{ "toolCallId", .{ .string = call_id } },
        });
    }
    if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        const item = parsed.value.object.get("item") orelse return null;
        if (item != .object) return null;
        const item_type = objectString(item.object, "type") orelse return null;
        if (!std.mem.eql(u8, item_type, "function_call")) return null;
        const call_id = objectString(item.object, "call_id") orelse return null;
        const name = objectString(item.object, "name") orelse "";
        const arguments = objectString(item.object, "arguments") orelse "{}";
        state.saw_tool_call = true;
        return try writeToolCall(alloc, call_id, name, arguments);
    }
    if (std.mem.eql(u8, event_type, "response.completed")) {
        const finish: []const u8 = if (state.saw_tool_call) "tool-calls" else "stop";
        return try writeFinish(alloc, parsed.value.object.get("response"), finish);
    }
    if (std.mem.eql(u8, event_type, "response.incomplete")) {
        return try writeFinish(alloc, parsed.value.object.get("response"), "length");
    }
    if (std.mem.eql(u8, event_type, "response.failed") or std.mem.eql(u8, event_type, "error")) {
        return try alloc.dupe(u8, "{\"type\":\"finish\",\"finishReason\":{\"unified\":\"error\"}}");
    }
    return null;
}

fn writeResponsesInputMessage(alloc: Allocator, writer: *std.Io.Writer, role: []const u8, object: std.json.ObjectMap) !void {
    if (std.mem.eql(u8, role, "tool")) {
        const call_id = objectString(object, "toolCallId") orelse
            firstToolResultId(object) orelse
            "";
        const output = toolResultText(object) orelse "";
        try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
        try std.json.Stringify.value(call_id, .{}, writer);
        try writer.writeAll(",\"output\":");
        try std.json.Stringify.value(output, .{}, writer);
        try writer.writeByte('}');
        return;
    }

    if (std.mem.eql(u8, role, "assistant")) {
        if (object.get("content")) |content| {
            if (content == .array) {
                var wrote = false;
                for (content.array.items) |part| {
                    if (part != .object) continue;
                    const part_type = objectString(part.object, "type") orelse continue;
                    if (std.mem.eql(u8, part_type, "tool-call")) {
                        if (wrote) try writer.writeByte(',');
                        try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                        try std.json.Stringify.value(objectString(part.object, "toolCallId") orelse "", .{}, writer);
                        try writer.writeAll(",\"name\":");
                        try std.json.Stringify.value(objectString(part.object, "toolName") orelse "", .{}, writer);
                        try writer.writeAll(",\"arguments\":");
                        if (part.object.get("input")) |input| {
                            if (input == .string) {
                                try std.json.Stringify.value(input.string, .{}, writer);
                            } else {
                                var args: std.Io.Writer.Allocating = .init(alloc);
                                defer args.deinit();
                                try std.json.Stringify.value(input, .{}, &args.writer);
                                try std.json.Stringify.value(args.written(), .{}, writer);
                            }
                        } else {
                            try writer.writeAll("\"{}\"");
                        }
                        try writer.writeByte('}');
                        wrote = true;
                        continue;
                    }
                    if (std.mem.eql(u8, part_type, "text")) {
                        if (wrote) try writer.writeByte(',');
                        try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":");
                        try std.json.Stringify.value(objectString(part.object, "text") orelse "", .{}, writer);
                        try writer.writeAll("}]}");
                        wrote = true;
                    }
                }
                if (wrote) return;
            }
        }
    }

    const text = messageText(object) orelse "";
    const content_type: []const u8 = if (std.mem.eql(u8, role, "assistant")) "output_text" else "input_text";
    const responses_role: []const u8 = if (std.mem.eql(u8, role, "assistant")) "assistant" else "user";
    try writer.writeAll("{\"type\":\"message\",\"role\":");
    try std.json.Stringify.value(responses_role, .{}, writer);
    try writer.writeAll(",\"content\":[{\"type\":");
    try std.json.Stringify.value(content_type, .{}, writer);
    try writer.writeAll(",\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeAll("}]}");
}

fn messageText(object: std.json.ObjectMap) ?[]const u8 {
    if (object.get("content")) |content| {
        switch (content) {
            .string => |text| return text,
            .array => |parts| {
                for (parts.items) |part| {
                    if (part != .object) continue;
                    const part_type = objectString(part.object, "type") orelse continue;
                    if (std.mem.eql(u8, part_type, "text")) {
                        return objectString(part.object, "text");
                    }
                    if (std.mem.eql(u8, part_type, "tool-result")) {
                        if (part.object.get("output")) |output| {
                            if (output == .object) return objectString(output.object, "value");
                            if (output == .string) return output.string;
                        }
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

fn firstToolResultId(object: std.json.ObjectMap) ?[]const u8 {
    const content = object.get("content") orelse return null;
    if (content != .array) return null;
    for (content.array.items) |part| {
        if (part != .object) continue;
        if (objectString(part.object, "toolCallId")) |id| return id;
    }
    return null;
}

fn toolResultText(object: std.json.ObjectMap) ?[]const u8 {
    if (messageText(object)) |text| return text;
    return objectString(object, "content");
}

fn resolveCallId(object: std.json.ObjectMap, state: *TranslateState) !?[]const u8 {
    if (objectString(object, "call_id")) |call_id| return call_id;
    if (objectString(object, "item_id")) |item_id| {
        if (state.find(item_id)) |call| return call.call_id;
        return item_id;
    }
    return null;
}

const JsonField = struct {
    []const u8,
    union(enum) { string: []const u8 },
};

fn writeObject(alloc: Allocator, fields: []const JsonField) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    for (fields, 0..) |field, i| {
        if (i > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(field[0], .{}, &out.writer);
        try out.writer.writeByte(':');
        try std.json.Stringify.value(field[1].string, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeToolInputStart(alloc: Allocator, call_id: []const u8, name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"type\":\"tool-input-start\",\"toolCallId\":");
    try std.json.Stringify.value(call_id, .{}, &out.writer);
    try out.writer.writeAll(",\"toolName\":");
    try std.json.Stringify.value(name, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeToolCall(alloc: Allocator, call_id: []const u8, name: []const u8, arguments: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"type\":\"tool-call\",\"toolCallId\":");
    try std.json.Stringify.value(call_id, .{}, &out.writer);
    try out.writer.writeAll(",\"toolName\":");
    try std.json.Stringify.value(name, .{}, &out.writer);
    try out.writer.writeAll(",\"input\":");
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, arguments, .{}) catch {
        try std.json.Stringify.value(arguments, .{}, &out.writer);
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    };
    defer parsed.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeFinish(alloc: Allocator, response: ?std.json.Value, reason: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"type\":\"finish\",\"finishReason\":{\"unified\":");
    try std.json.Stringify.value(reason, .{}, &out.writer);
    try out.writer.writeByte('}');
    if (response) |value| {
        if (value == .object) {
            if (value.object.get("usage")) |usage| {
                if (usage == .object) {
                    try out.writer.writeAll(",\"usage\":{\"inputTokens\":{\"total\":");
                    try writeTokenTotal(&out.writer, usage.object.get("input_tokens"));
                    try out.writer.writeAll("},\"outputTokens\":{\"total\":");
                    try writeTokenTotal(&out.writer, usage.object.get("output_tokens"));
                    try out.writer.writeAll("}}");
                }
            }
        }
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeTokenTotal(writer: *std.Io.Writer, value: ?std.json.Value) !void {
    const total: i64 = if (value) |actual|
        switch (actual) {
            .integer => |integer| integer,
            else => 0,
        }
    else
        0;
    try writer.print("{d}", .{if (total < 0) 0 else total});
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

test "Codex chat URLs and model ids" {
    try std.testing.expect(isCodexChatUrl(responses_url));
    try std.testing.expect(isCodexChatUrl("http://127.0.0.1:9/codex/responses"));
    try std.testing.expect(!isCodexChatUrl("https://ai-gateway.vercel.sh/v3/ai/language-model"));
    try std.testing.expectEqualStrings(responses_url, effectiveChatUrl(.codex_oauth, "https://ai-gateway.vercel.sh/v3/ai/language-model"));
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:9/codex/responses",
        effectiveChatUrl(.codex_oauth, "http://127.0.0.1:9/codex/responses"),
    );
    try std.testing.expectEqualStrings("gpt-5.6-sol", wireModelId("openai/gpt-5.6-sol"));
    try std.testing.expectEqualStrings("gpt-5.3-codex", wireModelId("gpt-5.3-codex"));
    try std.testing.expectEqualStrings("gpt-5.6-sol", wireModelId("zai/glm-5.2"));
    try std.testing.expectEqualStrings(default_model, resolvedModel(.codex_oauth, "zai/glm-5.2"));
    try std.testing.expectEqualStrings("openai/gpt-5.3-codex", resolvedModel(.codex_oauth, "openai/gpt-5.3-codex"));
    try std.testing.expectEqualStrings("zai/glm-5.2", resolvedModel(.ai_gateway_api_key, "zai/glm-5.2"));
}

test "gateway payload translates into a Responses request" {
    const alloc = std.testing.allocator;
    const payload =
        \\{"prompt":[{"role":"system","content":"Be brief."},{"role":"user","content":[{"type":"text","text":"Hi"}]}],"tools":[{"type":"function","name":"read_file","description":"Read","inputSchema":{"type":"object","properties":{"path":{"type":"string"}}}}],"toolChoice":{"type":"auto"},"maxOutputTokens":32,"reasoning":"medium"}
    ;
    const body = try translateGatewayPayload(alloc, "openai/gpt-5.6-sol", payload, "session-1");
    defer alloc.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gpt-5.6-sol\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"Be brief.\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"input_text\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"prompt_cache_key\":\"session-1\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"effort\":\"medium\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"context\":\"all_turns\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "max_output_tokens") == null);
}

test "Responses SSE events project onto the Gateway stream contract" {
    const alloc = std.testing.allocator;
    var state: TranslateState = .{};
    defer state.deinit(alloc);

    const text = (try translateResponsesSseData(
        alloc,
        "{\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}",
        &state,
    )).?;
    defer alloc.free(text);
    try std.testing.expectEqualStrings("{\"type\":\"text-delta\",\"delta\":\"Hello\"}", text);

    const start = (try translateResponsesSseData(
        alloc,
        "{\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"item_1\",\"call_id\":\"call_1\",\"name\":\"read_file\"}}",
        &state,
    )).?;
    defer alloc.free(start);
    try std.testing.expect(std.mem.find(u8, start, "\"type\":\"tool-input-start\"") != null);
    try std.testing.expect(std.mem.find(u8, start, "\"toolCallId\":\"call_1\"") != null);

    const done = (try translateResponsesSseData(
        alloc,
        "{\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}",
        &state,
    )).?;
    defer alloc.free(done);
    try std.testing.expect(std.mem.find(u8, done, "\"type\":\"tool-call\"") != null);
    try std.testing.expect(std.mem.find(u8, done, "\"path\":\"a.txt\"") != null);

    const finish = (try translateResponsesSseData(
        alloc,
        "{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":9,\"output_tokens\":4}}}",
        &state,
    )).?;
    defer alloc.free(finish);
    try std.testing.expect(std.mem.find(u8, finish, "\"unified\":\"tool-calls\"") != null);
    try std.testing.expect(std.mem.find(u8, finish, "\"total\":9") != null);
}
