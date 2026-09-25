//! MCP 2026-07-28 Tasks extension wire contract. Values borrow the parsed JSON.
const std = @import("std");
const mcp_contract = @import("mcp_contract.zig");
const protocol_messages = @import("protocol_messages.zig");
const elicitation = @import("elicitation.zig");
const mcp_json = @import("mcp_json.zig");

pub const Status = enum { working, input_required, completed, cancelled, failed };

pub const Task = struct {
    id: []const u8,
    status: Status,
    poll_interval_ms: u64,
    payload: std.json.Value,
};

/// Returns null for ordinary responses, whose validation belongs to tool_result.
pub fn creation(value: std.json.Value) !?Task {
    if (value != .object) return null;
    const result = value.object.get("result") orelse return null;
    if (result != .object) return null;
    const kind = result.object.get("resultType") orelse return null;
    if (kind != .string or !std.mem.eql(u8, kind.string, "task")) return null;
    try mcp_contract.validateJsonRpcResponseEnvelope(value);
    return try parse(result, false);
}

pub fn get(value: std.json.Value, task_id: []const u8) !Task {
    try acknowledgement(value);
    const task = try parse(value.object.get("result").?, true);
    if (!std.mem.eql(u8, task.id, task_id)) return error.McpInvalidTask;
    return task;
}

pub fn acknowledgement(value: std.json.Value) !void {
    try mcp_contract.validateJsonRpcResponseEnvelope(value);
    const result = value.object.get("result") orelse return error.McpTaskProtocolError;
    if (result != .object) return error.McpInvalidTask;
    const kind = result.object.get("resultType") orelse return error.McpInvalidTask;
    if (kind != .string or !std.mem.eql(u8, kind.string, "complete")) return error.McpInvalidTask;
}

fn parse(value: std.json.Value, detailed: bool) !Task {
    const id = try string(value, "taskId", 4096);
    const status = std.meta.stringToEnum(Status, try string(value, "status", 32)) orelse
        return error.McpInvalidTask;
    _ = try string(value, "createdAt", 128);
    _ = try string(value, "lastUpdatedAt", 128);
    if (value.object.get("statusMessage")) |message| {
        if (message != .string or message.string.len > 64 * 1024) return error.McpInvalidTask;
    }
    const ttl = value.object.get("ttlMs") orelse return error.McpInvalidTask;
    if (ttl != .null) _ = try milliseconds(ttl);
    const interval = if (value.object.get("pollIntervalMs")) |field| try milliseconds(field) else 1000;
    if (detailed) switch (status) {
        .completed => {
            const result = value.object.get("result") orelse return error.McpInvalidTask;
            if (result != .object) return error.McpInvalidTask;
            if (result.object.get("resultType")) |kind| {
                if (kind != .string or !std.mem.eql(u8, kind.string, "complete")) return error.McpInvalidTask;
            }
        },
        .failed => {
            const failure = value.object.get("error") orelse return error.McpInvalidTask;
            if (failure != .object) return error.McpInvalidTask;
            const code = failure.object.get("code") orelse return error.McpInvalidTask;
            const message = failure.object.get("message") orelse return error.McpInvalidTask;
            _ = try integer(code);
            if (message != .string) return error.McpInvalidTask;
        },
        .input_required => {
            const requests = value.object.get("inputRequests") orelse return error.McpInvalidTask;
            if (requests != .object or requests.object.count() == 0) return error.McpInvalidTask;
        },
        .working, .cancelled => {},
    };
    return .{ .id = id, .status = status, .poll_interval_ms = interval, .payload = value };
}

fn string(value: std.json.Value, key: []const u8, max_bytes: usize) ![]const u8 {
    const field = value.object.get(key) orelse return error.McpInvalidTask;
    if (field != .string or field.string.len == 0 or field.string.len > max_bytes) return error.McpInvalidTask;
    return field.string;
}

fn milliseconds(value: std.json.Value) !u64 {
    const number = try integer(value);
    if (number < 0 or number > 9007199254740991) return error.McpInvalidTask;
    return @intCast(number);
}

fn integer(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |number| number,
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch error.McpInvalidTask,
        else => error.McpInvalidTask,
    };
}

pub const Method = enum {
    get,
    update,
    cancel,

    fn wire(self: Method) []const u8 {
        return switch (self) {
            .get => "tasks/get",
            .update => "tasks/update",
            .cancel => "tasks/cancel",
        };
    }
};

/// Caller owns the returned NDJSON-safe request.
pub fn request(
    alloc: std.mem.Allocator,
    request_id: u64,
    method: Method,
    task_id: []const u8,
    responses: ?[]const u8,
    capabilities: elicitation.Capabilities,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{\"taskId\":", .{ request_id, method.wire() });
    try std.json.Stringify.value(task_id, .{}, &out.writer);
    try out.writer.writeAll(",\"_meta\":");
    try protocol_messages.writeModernTaskMetadata(&out.writer, null, capabilities);
    if (responses) |json| {
        try out.writer.writeAll(",\"inputResponses\":");
        try mcp_json.write_compact(&out.writer, json);
    }
    try out.writer.writeAll("}}");
    return out.toOwnedSlice();
}

test "MCP tasks validate seed and detailed states and bind polling to one task" {
    const alloc = std.testing.allocator;
    const metadata = "\"taskId\":\"job\",\"createdAt\":\"2026-07-28T00:00:00Z\",\"lastUpdatedAt\":\"2026-07-28T00:00:00Z\",\"ttlMs\":null";
    const cases = .{
        .{ "task", "\"status\":\"completed\"", true },
        .{ "complete", "\"status\":\"completed\",\"result\":{\"content\":[]}", true },
        .{ "complete", "\"status\":\"failed\",\"error\":{\"code\":-32000,\"message\":\"failed\"}", true },
        .{ "complete", "\"status\":\"cancelled\"", true },
        .{ "complete", "\"status\":\"input_required\",\"inputRequests\":{\"a\":{}}", true },
        .{ "complete", "\"status\":\"completed\"", false },
        .{ "complete", "\"status\":\"failed\",\"error\":{}", false },
        .{ "complete", "\"status\":\"input_required\",\"inputRequests\":{}", false },
        .{ "complete", "\"status\":\"working\",\"pollIntervalMs\":-1", false },
        .{ "complete", "\"status\":\"unknown\"", false },
        .{ "complete", "\"status\":\"completed\",\"result\":{\"resultType\":\"task\"}", false },
    };
    inline for (cases) |case| {
        const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"" ++ case[0] ++ "\"," ++ metadata ++ "," ++ case[1] ++ "}}";
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        if (comptime std.mem.eql(u8, case[0], "task")) {
            try std.testing.expect((try creation(parsed.value)) != null);
        } else if (case[2]) {
            const task = try get(parsed.value, "job");
            try std.testing.expectEqualStrings("job", task.id);
            try std.testing.expectError(error.McpInvalidTask, get(parsed.value, "other"));
        } else try std.testing.expectError(error.McpInvalidTask, get(parsed.value, "job"));
    }
}
