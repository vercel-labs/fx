const std = @import("std");
const types = @import("../shared/types.zig");

const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;

pub fn validate(alloc: std.mem.Allocator, messages: []const ChatMessage) !void {
    var index: usize = 0;
    while (index < messages.len) {
        const message = messages[index];
        if (message.role == .tool) return error.InvalidModelHistory;
        if (message.role != .assistant or message.tool_calls.len == 0) {
            index += 1;
            continue;
        }

        try validateAssistantToolCalls(alloc, message.tool_calls);
        const seen = try alloc.alloc(bool, message.tool_calls.len);
        defer alloc.free(seen);
        index = try validateToolResults(messages, index + 1, message.tool_calls, seen);
    }
}

fn validateToolResults(
    messages: []const ChatMessage,
    start_index: usize,
    calls: []const ToolCall,
    seen: []bool,
) !usize {
    @memset(seen, false);
    var result_count: usize = 0;
    var index = start_index;
    while (result_count < calls.len) : (index += 1) {
        if (index >= messages.len) return error.InvalidModelHistory;
        const result = messages[index];
        if (result.role != .tool) return error.InvalidModelHistory;
        const call_id = result.tool_call_id orelse return error.InvalidModelHistory;
        const tool_name = result.tool_name orelse return error.InvalidModelHistory;
        if (result.content == null) return error.InvalidModelHistory;

        const call_index = findToolCall(calls, call_id) orelse return error.InvalidModelHistory;
        if (seen[call_index] or !std.mem.eql(u8, calls[call_index].name, tool_name)) {
            return error.InvalidModelHistory;
        }
        seen[call_index] = true;
        result_count += 1;
    }
    return index;
}

pub fn validateAssistantToolCalls(alloc: std.mem.Allocator, calls: []const ToolCall) !void {
    for (calls, 0..) |call, index| {
        if (call.id.len == 0 or call.name.len == 0 or call.arguments_json.len == 0) {
            return error.InvalidModelHistory;
        }
        if (try types.ToolArgumentIntegrity.classifySerialized(alloc, call.arguments_json) == .malformed_json) {
            return error.InvalidModelHistory;
        }
        for (calls[index + 1 ..]) |later| {
            if (std.mem.eql(u8, call.id, later.id)) return error.InvalidModelHistory;
        }
    }
}

fn findToolCall(calls: []const ToolCall, id: []const u8) ?usize {
    for (calls, 0..) |call, index| {
        if (std.mem.eql(u8, call.id, id)) return index;
    }
    return null;
}

test "model history accepts one complete ordered tool-result block" {
    const calls = [_]ToolCall{
        .{ .id = "a", .name = "read_file", .arguments_json = "{}" },
        .{ .id = "b", .name = "file_info", .arguments_json = "{}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .tool_call_id = "b", .tool_name = "file_info", .content = "b" },
        .{ .role = .tool, .tool_call_id = "a", .tool_name = "read_file", .content = "a" },
    };
    try validate(std.testing.allocator, &messages);
}

test "model history rejects incomplete duplicate and malformed tool transitions" {
    const malformed = [_]ToolCall{.{ .id = "a", .name = "read_file", .arguments_json = "{" }};
    const incomplete = [_]ChatMessage{.{ .role = .assistant, .tool_calls = &malformed }};
    try std.testing.expectError(error.InvalidModelHistory, validate(std.testing.allocator, &incomplete));

    const duplicate = [_]ToolCall{
        .{ .id = "a", .name = "read_file", .arguments_json = "{}" },
        .{ .id = "a", .name = "file_info", .arguments_json = "{}" },
    };
    const duplicate_messages = [_]ChatMessage{.{ .role = .assistant, .tool_calls = &duplicate }};
    try std.testing.expectError(error.InvalidModelHistory, validate(std.testing.allocator, &duplicate_messages));
}
