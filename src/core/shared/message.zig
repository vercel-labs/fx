const std = @import("std");
const types = @import("types.zig");

/// Role assigned to a request message.
pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

/// Tool call emitted by the gateway and replayed in assistant messages.
pub const ToolCall = types.ToolCall;

/// Content carried by a request message.
pub const Content = union(enum) {
    text: []const u8,

    /// Returns the borrowed text for the active content variant.
    pub fn asText(self: Content) []const u8 {
        return switch (self) {
            .text => |value| value,
        };
    }
};

/// One role-tagged request message. Explicit flags track ownership because
/// `ToolCall` byte slices do not encode it at the type level.
pub const Message = struct {
    role: Role,
    content: ?Content = null,
    images: []const types.ImageAttachment = &.{},
    tool_calls: []const ToolCall = &.{},
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_result_status: ?types.PersistedToolStatus = null,
    tool_result_memory: ?types.ToolResultMemory = null,
    permission_feedback: bool = false,
    /// Ordered assistant replay parts; present is authoritative for replay.
    assistant_parts: ?[]const types.AssistantPart = null,
    owns_content: bool = false,
    owns_tool_calls: bool = false,
    owns_assistant_parts: bool = false,

    /// Builds a borrowed system message.
    pub fn systemText(text: []const u8) Message {
        return .{
            .role = .system,
            .content = .{ .text = text },
        };
    }

    /// Builds an owned system message; caller transfers ownership of text to the Message; Message.deinit will free it.
    pub fn systemOwned(text: []u8) Message {
        return .{
            .role = .system,
            .content = .{ .text = text },
            .owns_content = true,
        };
    }

    /// Builds a borrowed user message.
    pub fn userText(text: []const u8) Message {
        return .{
            .role = .user,
            .content = .{ .text = text },
        };
    }

    /// Builds an owned user message; caller transfers ownership of text to the Message.
    pub fn userOwned(text: []u8) Message {
        return .{
            .role = .user,
            .content = .{ .text = text },
            .owns_content = true,
        };
    }

    /// Builds an assistant message that owns content and tool-call slices.
    pub fn assistantOwned(content: ?[]const u8, tool_calls: []const ToolCall) Message {
        return .{
            .role = .assistant,
            .content = if (content) |text| .{ .text = text } else null,
            .tool_calls = tool_calls,
            .owns_content = content != null,
            .owns_tool_calls = tool_calls.len > 0,
        };
    }

    /// Builds an assistant message that borrows content and tool-call slices.
    pub fn assistantBorrowed(content: ?[]const u8, tool_calls: []const ToolCall) Message {
        return .{
            .role = .assistant,
            .content = if (content) |text| .{ .text = text } else null,
            .tool_calls = tool_calls,
        };
    }

    /// Builds a tool-result message that owns the result text.
    pub fn toolOwned(
        content: []u8,
        tool_call_id: []const u8,
        tool_name: []const u8,
        status: types.PersistedToolStatus,
    ) Message {
        return .{
            .role = .tool,
            .content = .{ .text = content },
            .tool_call_id = tool_call_id,
            .tool_name = tool_name,
            .tool_result_status = status,
            .owns_content = true,
        };
    }

    /// Frees owned message fields and leaves borrowed fields untouched.
    pub fn deinit(self: *Message, alloc: std.mem.Allocator) void {
        if (self.owns_content) {
            if (self.content) |content| alloc.free(content.asText());
        }
        if (self.owns_tool_calls) freeToolCalls(alloc, self.tool_calls);
        if (self.owns_assistant_parts) {
            if (self.assistant_parts) |parts| types.freeAssistantParts(alloc, parts);
        }
        self.* = .{ .role = .user };
    }
};

/// Full message list consumed by one streamed gateway request.
pub const Request = struct {
    messages: []const Message,
    tool_choice: types.ToolChoice = .auto,

    /// Wraps a borrowed conversation slice owned by the caller.
    pub fn init(messages: []const Message) Request {
        return .{ .messages = messages };
    }

    pub fn initWithToolChoice(messages: []const Message, tool_choice: types.ToolChoice) Request {
        return .{ .messages = messages, .tool_choice = tool_choice };
    }
};

/// Frees an owned tool-call slice returned by the gateway.
pub fn freeToolCalls(alloc: std.mem.Allocator, tool_calls: []const ToolCall) void {
    for (tool_calls) |call| {
        alloc.free(call.id);
        alloc.free(call.name);
        alloc.free(call.arguments_json);
        if (call.provisional_id) |provisional_id| alloc.free(provisional_id);
        if (call.provider_result) |provider_result| alloc.free(provider_result);
        if (call.provider_options_json) |options| alloc.free(options);
    }
    if (tool_calls.len > 0) alloc.free(tool_calls);
}

test "Message constructors preserve borrowed prompts" {
    const system = Message.systemText("rules");
    const user = Message.userText("hello");

    try std.testing.expectEqual(.system, system.role);
    try std.testing.expectEqualStrings("rules", system.content.?.asText());
    try std.testing.expect(!system.owns_content);
    try std.testing.expectEqual(.user, user.role);
    try std.testing.expectEqualStrings("hello", user.content.?.asText());
}

test "Message.assistantOwned frees content and tool calls" {
    const alloc = std.testing.allocator;
    const content = try alloc.dupe(u8, "assistant");
    const calls = try alloc.alloc(ToolCall, 1);
    calls[0] = .{
        .id = try alloc.dupe(u8, "call_1"),
        .name = try alloc.dupe(u8, "read_file"),
        .arguments_json = try alloc.dupe(u8, "{}"),
        .provider_result = try alloc.dupe(u8, "provider"),
    };

    var msg = Message.assistantOwned(content, calls);
    try std.testing.expect(msg.owns_content);
    try std.testing.expect(msg.owns_tool_calls);
    try std.testing.expectEqualStrings("assistant", msg.content.?.asText());
    try std.testing.expectEqualStrings("read_file", msg.tool_calls[0].name);

    msg.deinit(alloc);
}

test "Message.systemOwned frees owned content" {
    const alloc = std.testing.allocator;
    const text = try alloc.dupe(u8, "system");
    var msg = Message.systemOwned(text);
    try std.testing.expect(msg.owns_content);
    try std.testing.expectEqualStrings("system", msg.content.?.asText());
    msg.deinit(alloc);
}

test "Message.userOwned frees owned content" {
    const alloc = std.testing.allocator;
    const text = try alloc.dupe(u8, "user");
    var msg = Message.userOwned(text);
    try std.testing.expect(msg.owns_content);
    try std.testing.expectEqualStrings("user", msg.content.?.asText());
    msg.deinit(alloc);
}

test "assistantBorrowed constructor and deinit leave borrowed content alive" {
    const borrowed = "assistant";
    var msg = Message.assistantBorrowed(borrowed, &.{});
    try std.testing.expect(!msg.owns_content);
    try std.testing.expectEqualStrings(borrowed, msg.content.?.asText());
    msg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("assistant", borrowed);
}

test "Message.toolOwned frees result text without owning borrowed call labels" {
    const alloc = std.testing.allocator;
    const body = try alloc.dupe(u8, "result");
    var msg = Message.toolOwned(body, "call_1", "read_file", .success);

    try std.testing.expectEqual(.tool, msg.role);
    try std.testing.expectEqualStrings("result", msg.content.?.asText());
    try std.testing.expectEqualStrings("call_1", msg.tool_call_id.?);
    try std.testing.expectEqualStrings("read_file", msg.tool_name.?);
    try std.testing.expectEqual(types.PersistedToolStatus.success, msg.tool_result_status.?);

    msg.deinit(alloc);
}

test "Request.init wraps borrowed message slice" {
    const messages = [_]Message{
        Message.userText("hello"),
    };
    const request = Request.init(&messages);

    try std.testing.expectEqual(@as(usize, 1), request.messages.len);
    try std.testing.expectEqualStrings("hello", request.messages[0].content.?.asText());
}

test "Content.asText returns borrowed text" {
    const content = Content{ .text = "borrowed" };

    try std.testing.expectEqualStrings("borrowed", content.asText());
}
