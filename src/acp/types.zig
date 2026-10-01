const std = @import("std");
const build_options = @import("build_options");
const jsonrpc = @import("jsonrpc.zig");
const core_types = @import("../core/shared/types.zig");
const session_usage = @import("../core/session/session_usage.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const writeJsonStr = jsonrpc.writeJsonStr;

pub const MessageIdBuffer = [32]u8;

pub fn generateMessageId(storage: *MessageIdBuffer) []const u8 {
    var random_bytes: [16]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    storage.* = std.fmt.bytesToHex(random_bytes, .lower);
    return storage;
}

pub const protocol_version: u32 = 1;

/// Returns the borrowed value at `_meta.fx.<key>` on an ACP params object.
/// fx reads and writes its protocol extensions under that one namespace.
pub fn fxMetaField(object: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const meta = object.get("_meta") orelse return null;
    if (meta != .object) return null;
    const fx = meta.object.get("fx") orelse return null;
    if (fx != .object) return null;
    return fx.object.get(key);
}

/// Returns `_meta.fx.<key>` when it is a JSON boolean.
pub fn fxMetaBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = fxMetaField(object, key) orelse return null;
    return if (value == .bool) value.bool else null;
}

pub fn writeModelRecoveryInfoUpdate(
    writer: *std.Io.Writer,
    status: ?core_types.RouteRecoveryStatus,
    durable: bool,
) !void {
    try writer.writeAll("{\"sessionUpdate\":\"session_info_update\",\"_meta\":{\"fx\":{\"modelResponseRecovery\":");
    const recovery = status orelse {
        try writer.writeAll("null}}}");
        return;
    };
    try writer.writeAll("{\"state\":");
    try writeJsonStr(
        if (recovery.isRecovered())
            "recovered"
        else if (recovery.kind == .terminal_provider_error)
            // Match the CLI JSON contract: a genuine lifecycle pause
            // (action == .paused) is resumable; a terminal stop is not.
            if (recovery.action == .paused) "paused" else "failed"
        else
            "active",
        writer,
    );
    try writer.writeAll(",\"kind\":");
    try writeJsonStr(@tagName(recovery.kind), writer);
    if (recovery.cause) |cause| {
        try writer.writeAll(",\"cause\":");
        try writeJsonStr(@tagName(cause), writer);
    }
    if (recovery.action) |action| {
        try writer.writeAll(",\"action\":");
        try writeJsonStr(@tagName(action), writer);
    }
    if (recovery.required_action != .none) {
        try writer.writeAll(",\"requiredAction\":");
        try writeJsonStr(@tagName(recovery.required_action), writer);
    }
    const reported_attempt = recovery.reportedAttempt();
    if (reported_attempt != 0) {
        try writer.print(",\"attempt\":{d}", .{reported_attempt});
    }
    if (recovery.attempt_limit != 0) {
        try writer.print(",\"attemptLimit\":{d}", .{recovery.attempt_limit});
    }
    if (recovery.delay_seconds != 0) {
        try writer.print(",\"delaySeconds\":{d}", .{recovery.delay_seconds});
    }
    try writer.print(",\"durable\":{s},\"message\":", .{if (durable) "true" else "false"});
    var label_buf: [core_types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try writeJsonStr(recovery.label(&label_buf), writer);
    try writer.writeAll("}}}}");
}

pub const StopReason = enum {
    end_turn,
    max_output_tokens,
    max_model_turns,
    refused,
    cancelled,

    pub fn jsonString(self: StopReason) []const u8 {
        return switch (self) {
            .end_turn => "end_turn",
            .max_output_tokens => "max_output_tokens",
            .max_model_turns => "max_model_turns",
            .refused => "refused",
            .cancelled => "cancelled",
        };
    }
};

pub const ToolCallKind = enum {
    read,
    edit,
    delete,
    move,
    search,
    execute,
    think,
    fetch,
    other,

    pub fn jsonString(self: ToolCallKind) []const u8 {
        return switch (self) {
            .read => "read",
            .edit => "edit",
            .delete => "delete",
            .move => "move",
            .search => "search",
            .execute => "execute",
            .think => "think",
            .fetch => "fetch",
            .other => "other",
        };
    }
};

pub const ToolCallStatus = enum {
    pending,
    in_progress,
    completed,
    failed,

    pub fn jsonString(self: ToolCallStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_progress => "in_progress",
            .completed => "completed",
            .failed => "failed",
        };
    }
};

pub fn writeSessionUpdate(w: *std.Io.Writer, session_id: []const u8, update_json: []const u8) !void {
    try w.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, w);
    try w.writeAll(",\"update\":");
    try w.writeAll(update_json);
    try w.writeAll("}");
}

pub fn writeAgentMessageChunk(w: *std.Io.Writer, message_id: []const u8, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"agent_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

pub fn writeAgentThoughtChunk(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

pub fn writeUserMessageChunk(w: *std.Io.Writer, message_id: []const u8, text: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("}}");
}

pub fn writeUserImageChunk(
    w: *std.Io.Writer,
    message_id: []const u8,
    media_type: []const u8,
    bytes: []const u8,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"image\",\"data\":\"");
    try std.base64.standard.Encoder.encodeWriter(w, bytes);
    try w.writeAll("\",\"mimeType\":");
    try writeJsonStr(media_type, w);
    try w.writeAll("}}");
}

/// Host-facing identity of a tool call, sent as `_meta.fx.toolCall` so
/// clients never need to match on tool names.
pub const ToolCallMeta = struct {
    /// fx's own discovery or bookkeeping step, which hosts may hide.
    internal: bool = false,
    /// The MCP server and its own tool name, for MCP tool calls.
    mcp: ?struct { server: []const u8, tool: []const u8 } = null,
};

fn writeToolCallMeta(w: *std.Io.Writer, meta: ToolCallMeta) !void {
    try w.writeAll(",\"_meta\":{\"fx\":{\"toolCall\":{\"internal\":");
    try w.writeAll(if (meta.internal) "true" else "false");
    if (meta.mcp) |mcp| {
        try w.writeAll(",\"mcp\":{\"server\":");
        try writeJsonStr(mcp.server, w);
        try w.writeAll(",\"tool\":");
        try writeJsonStr(mcp.tool, w);
        try w.writeByte('}');
    }
    try w.writeAll("}}}");
}

pub fn writeToolCall(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    name: []const u8,
    title: []const u8,
    kind: ToolCallKind,
    status: ToolCallStatus,
    raw_input: ?std.json.Value,
    meta: ToolCallMeta,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"tool_call\",\"toolCallId\":");
    try writeJsonStr(tool_call_id, w);
    try w.writeAll(",\"name\":");
    try writeJsonStr(name, w);
    try w.writeAll(",\"title\":");
    try writeJsonStr(title, w);
    try w.writeAll(",\"kind\":");
    try writeJsonStr(kind.jsonString(), w);
    try w.writeAll(",\"status\":");
    try writeJsonStr(status.jsonString(), w);
    if (raw_input) |value| {
        try w.writeAll(",\"rawInput\":");
        try std.json.Stringify.value(value, .{}, w);
    }
    try writeToolCallMeta(w, meta);
    try w.writeAll("}");
}

pub fn writeToolCallUpdate(w: *std.Io.Writer, tool_call_id: []const u8, status: ToolCallStatus, content_text: ?[]const u8) !void {
    try writeToolCallUpdateWithCommandResult(w, tool_call_id, status, content_text, null);
}

pub fn writeToolCallUpdateWithCommandResult(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    status: ToolCallStatus,
    content_text: ?[]const u8,
    command_result_json: ?[]const u8,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":");
    try writeJsonStr(tool_call_id, w);
    try w.writeAll(",\"status\":");
    try writeJsonStr(status.jsonString(), w);
    if (content_text) |text| {
        try w.writeAll(",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":");
        try writeJsonStr(text, w);
        try w.writeAll("}}]");
    }
    if (command_result_json) |json| {
        try w.writeAll(",\"command_result\":");
        try w.writeAll(json);
    }
    try w.writeAll("}");
}

pub const AgentCapabilities = struct {
    image_prompts: bool,
    /// Accepts client `mcpServers` on session setup.
    mcp_servers: bool = true,
    /// Accepts steering prompts through `session/prompt` during a turn.
    steering: bool = false,
    /// Accepts a client system prompt on `session/new` in append mode.
    system_prompt: bool = false,
    /// Serves `type: "acp"` MCP servers over this connection.
    mcp_over_acp: bool = false,
};

pub fn writeInitializeResponse(w: *std.Io.Writer, capabilities: AgentCapabilities) !void {
    const mcp_servers = if (capabilities.mcp_servers) "true" else "false";
    try w.writeAll("{\"protocolVersion\":");
    try w.print("{d}", .{protocol_version});
    try w.writeAll(",\"agentCapabilities\":{");
    try w.writeAll("\"loadSession\":true,");
    try w.print("\"promptCapabilities\":{{\"image\":{s},\"audio\":false,\"embeddedContext\":true}},", .{if (capabilities.image_prompts) "true" else "false"});
    try w.print("\"mcpCapabilities\":{{\"http\":{s},\"sse\":{s},\"acp\":{s}}},", .{
        mcp_servers,
        mcp_servers,
        if (capabilities.mcp_over_acp) "true" else "false",
    });
    try w.writeAll("\"sessionCapabilities\":{\"list\":{},\"resume\":{},\"close\":{}");
    if (capabilities.system_prompt) try w.writeAll(",\"systemPrompt\":{}");
    try w.writeByte('}');
    try w.print(",\"_meta\":{{\"fx\":{{\"steering\":{s},\"sessionUsage\":true}}}}", .{if (capabilities.steering) "true" else "false"});
    try w.writeAll("},\"agentInfo\":{\"name\":\"fx\",\"title\":\"fx\",\"version\":");
    try writeJsonStr(build_options.app_version, w);
    try w.writeAll("},");
    try w.writeAll("\"authMethods\":[]}");
}

pub fn writePromptResponse(w: *std.Io.Writer, reason: StopReason) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    try w.writeAll("}");
}

/// How a steering `session/prompt` fared in the turn that received it.
pub const SteeringDelivery = enum {
    absorbed,
    dropped,
};

/// Answers a steering prompt with its receiving turn's stop reason. Usage is
/// reported once, on the response to the prompt that started the turn.
pub fn writeSteeringPromptResponse(w: *std.Io.Writer, reason: StopReason, delivery: SteeringDelivery) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    try w.writeAll(",\"_meta\":{\"fx\":{\"steering\":");
    try writeJsonStr(@tagName(delivery), w);
    try w.writeAll("}}}");
}

/// Replays delivered steering where the agent inserted it into the turn.
pub fn writeSteeringUserMessageChunk(
    w: *std.Io.Writer,
    message_id: []const u8,
    text: []const u8,
    request_id: ?jsonrpc.RequestId,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeAll("},\"_meta\":{\"fx\":{\"steering\":{\"requestId\":");
    try jsonrpc.Writer.writeId(w, request_id);
    try w.writeAll("}}}}");
}

pub fn writePromptResponseWithUsage(
    w: *std.Io.Writer,
    reason: StopReason,
    usage: core_types.Usage,
    billing: ?session_usage.BillingSnapshot,
) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    try w.writeAll(",\"usage\":{");
    var first = true;
    inline for (.{
        .{ "inputTokens", usage.input_tokens },
        .{ "outputTokens", usage.output_tokens },
        .{ "cacheReadTokens", usage.cache_read_tokens },
        .{ "cacheWriteTokens", usage.cache_write_tokens },
        .{ "reasoningTokens", usage.reasoning_tokens },
    }) |field| {
        if (field[1]) |value| {
            if (!first) try w.writeByte(',');
            first = false;
            try writeJsonStr(field[0], w);
            try w.print(":{d}", .{value});
        }
    }
    try w.writeByte('}');
    if (billing) |snapshot| try writeUsageMetadata(w, snapshot);
    try w.writeByte('}');
}

pub fn writeAvailableCommandsUpdate(w: *std.Io.Writer, commands_json: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"available_commands_update\",\"availableCommands\":");
    try w.writeAll(commands_json);
    try w.writeAll("}");
}

pub fn writeSessionInfoUpdate(w: *std.Io.Writer, title: []const u8, updated_at: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"session_info_update\",\"title\":");
    try writeJsonStr(title, w);
    try w.writeAll(",\"updatedAt\":");
    try writeJsonStr(updated_at, w);
    try w.writeAll("}");
}

pub fn writeUsageUpdate(w: *std.Io.Writer, used: u64, size: u64, billing: session_usage.BillingSnapshot) !void {
    try w.print("{{\"sessionUpdate\":\"usage_update\",\"used\":{d},\"size\":{d}", .{ used, size });
    if (billing.billing == .complete) {
        try w.print(",\"cost\":{{\"amount\":{d},\"currency\":\"USD\"}}", .{billing.total_cost});
    }
    try writeUsageMetadata(w, billing);
    try w.writeAll("}");
}

fn writeUsageMetadata(w: *std.Io.Writer, billing: session_usage.BillingSnapshot) !void {
    try w.writeAll(",\"_meta\":{\"fx\":{\"usage\":");
    try writeSessionUsage(w, billing);
    try w.writeAll("}}");
}

/// Serializes settled totals separately from session billing completeness.
/// Input includes cache tokens; output includes reasoning tokens.
pub fn writeSessionUsage(w: *std.Io.Writer, billing: session_usage.BillingSnapshot) !void {
    try w.writeAll("{\"billing\":");
    try writeJsonStr(@tagName(billing.billing), w);
    try w.print(",\"pendingRequests\":{d},\"activeRequests\":{d},\"confirmed\":{{\"cost\":{{\"amount\":{d},\"currency\":\"USD\"}}", .{
        billing.pending_requests,
        billing.active_requests,
        billing.total_cost,
    });
    try w.print(",\"inputTokens\":{d},\"outputTokens\":{d},\"cacheReadTokens\":{d},\"cacheWriteTokens\":{d},\"billableWebSearchCalls\":{d}", .{
        billing.input_tokens,
        billing.output_tokens,
        billing.cache_read_tokens,
        billing.cache_write_tokens,
        billing.billable_web_search_calls,
    });
    if (billing.reasoning_tokens) |value| try w.print(",\"reasoningTokens\":{d}", .{value});
    if (billing.request_count) |value| try w.print(",\"requests\":{d}", .{value});
    try w.writeAll("},\"estimated\":{\"source\":\"gateway_catalog\",\"scope\":\"tokens\"");
    try w.print(",\"requests\":{d},\"unpricedRequests\":{d}", .{ billing.estimated_requests, billing.unestimated_requests });
    if (billing.estimated_token_cost) |amount| {
        try w.print(",\"cost\":{{\"amount\":{d},\"currency\":\"USD\"}}", .{amount});
    }
    try w.writeAll("}}");
}

test "writeAgentMessageChunk produces valid json" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeAgentMessageChunk(&out.writer, "message-1", "Hello world");
    const expected = "{\"sessionUpdate\":\"agent_message_chunk\",\"messageId\":\"message-1\",\"content\":{\"type\":\"text\",\"text\":\"Hello world\"}}";
    try std.testing.expectEqualStrings(expected, out.writer.buffered());
}

test "writeToolCall produces valid json" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var raw_input = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"path\":\"README.md\"}",
        .{},
    );
    defer raw_input.deinit();

    try writeToolCall(
        &out.writer,
        "call_001",
        "read_file",
        "Reading file",
        .read,
        .pending,
        raw_input.value,
        .{},
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();
    const tool_call_meta = parsed.value.object.get("_meta").?.object.get("fx").?.object.get("toolCall").?.object;
    try std.testing.expect(!tool_call_meta.get("internal").?.bool);
    try std.testing.expect(tool_call_meta.get("mcp") == null);

    try std.testing.expectEqualStrings("call_001", parsed.value.object.get("toolCallId").?.string);
    try std.testing.expectEqualStrings("read_file", parsed.value.object.get("name").?.string);
    try std.testing.expectEqualStrings("read", parsed.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings(
        "README.md",
        parsed.value.object.get("rawInput").?.object.get("path").?.string,
    );
}

test "writePromptResponse produces valid json" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writePromptResponse(&out.writer, .end_turn);
    try std.testing.expectEqualStrings("{\"stopReason\":\"end_turn\"}", out.writer.buffered());
}

test "StopReason jsonString values" {
    try std.testing.expectEqualStrings("end_turn", StopReason.end_turn.jsonString());
    try std.testing.expectEqualStrings("cancelled", StopReason.cancelled.jsonString());
    try std.testing.expectEqualStrings("max_output_tokens", StopReason.max_output_tokens.jsonString());
}

test "ToolCallKind jsonString values" {
    try std.testing.expectEqualStrings("read", ToolCallKind.read.jsonString());
    try std.testing.expectEqualStrings("edit", ToolCallKind.edit.jsonString());
    try std.testing.expectEqualStrings("execute", ToolCallKind.execute.jsonString());
    try std.testing.expectEqualStrings("search", ToolCallKind.search.jsonString());
    try std.testing.expectEqualStrings("fetch", ToolCallKind.fetch.jsonString());
    try std.testing.expectEqualStrings("other", ToolCallKind.other.jsonString());
}

test "ToolCallStatus jsonString values" {
    try std.testing.expectEqualStrings("pending", ToolCallStatus.pending.jsonString());
    try std.testing.expectEqualStrings("in_progress", ToolCallStatus.in_progress.jsonString());
    try std.testing.expectEqualStrings("completed", ToolCallStatus.completed.jsonString());
    try std.testing.expectEqualStrings("failed", ToolCallStatus.failed.jsonString());
}

test "writeToolCallUpdate with content" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallUpdate(&out.writer, "call_002", .completed, "File written successfully");
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"tool_call_update\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"completed\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "File written successfully") != null);
}

test "writeToolCallUpdate can include structured command result" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try writeToolCallUpdateWithCommandResult(
        &out.writer,
        "call_002",
        .completed,
        "exit_code=0\n<stdout>\nok\n</stdout>\n",
        "{\"kind\":\"command\",\"command\":\"printf ok\",\"cwd\":\"/tmp\",\"exit_code\":0,\"signal\":null,\"timed_out\":false,\"stdout_bytes\":2,\"stderr_bytes\":0,\"truncated\":false}",
    );
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("tool_call_update", parsed.value.object.get("sessionUpdate").?.string);
    const command_result = parsed.value.object.get("command_result").?.object;
    try std.testing.expectEqualStrings("command", command_result.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 0), command_result.get("exit_code").?.integer);
    try std.testing.expect(parsed.value.object.get("content") != null);
}

test "writeToolCallUpdate without content" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallUpdate(&out.writer, "call_003", .in_progress, null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"in_progress\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "content") == null);
}

test "writeInitializeResponse contains required fields" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeInitializeResponse(&out.writer, .{ .image_prompts = true, .steering = true, .system_prompt = true, .mcp_over_acp = true });
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();

    const agent_capabilities = parsed.value.object.get("agentCapabilities").?.object;
    const mcp_capabilities = agent_capabilities.get("mcpCapabilities").?.object;
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"protocolVersion\":1") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"loadSession\":true") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"name\":\"fx\"") != null);
    try std.testing.expectEqualStrings(
        build_options.app_version,
        parsed.value.object.get("agentInfo").?.object.get("version").?.string,
    );
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"image\":true") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"list\":{}") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"resume\":{}") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"close\":{}") != null);
    try std.testing.expect(mcp_capabilities.get("http").?.bool);
    try std.testing.expect(mcp_capabilities.get("sse").?.bool);
    try std.testing.expect(mcp_capabilities.get("acp").?.bool);
    const session_capabilities = agent_capabilities.get("sessionCapabilities").?.object;
    try std.testing.expectEqual(@as(usize, 0), session_capabilities.get("systemPrompt").?.object.count());
    const fx_meta = agent_capabilities.get("_meta").?.object.get("fx").?.object;
    try std.testing.expect(fx_meta.get("steering").?.bool);
    try std.testing.expect(fx_meta.get("sessionUsage").?.bool);
}

test "writeInitializeResponse withholds MCP transports a host rejects" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeInitializeResponse(&out.writer, .{ .image_prompts = false, .mcp_servers = false });
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();
    const mcp_capabilities = parsed.value.object.get("agentCapabilities").?.object.get("mcpCapabilities").?.object;
    try std.testing.expect(!mcp_capabilities.get("http").?.bool);
    try std.testing.expect(!mcp_capabilities.get("sse").?.bool);
}

test "writeToolCall separates MCP server and tool identity" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCall(&out.writer, "call_mcp", "mcp_mini_browser_eval", "Evaluate JavaScript", .other, .pending, null, .{
        .mcp = .{ .server = "mini", .tool = "browser_eval" },
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Evaluate JavaScript", parsed.value.object.get("title").?.string);
    const meta = parsed.value.object.get("_meta").?.object.get("fx").?.object.get("toolCall").?.object;
    try std.testing.expect(!meta.get("internal").?.bool);
    try std.testing.expectEqualStrings("mini", meta.get("mcp").?.object.get("server").?.string);
    try std.testing.expectEqualStrings("browser_eval", meta.get("mcp").?.object.get("tool").?.string);
}

test "writeUserMessageChunk produces valid json" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeUserMessageChunk(&out.writer, "message-2", "User says hello");
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"user_message_chunk\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "User says hello") != null);
}

test "writeUsageUpdate omits unproven cost" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var billing = usage.billingSnapshot();
    billing.billing = .pending;
    billing.pending_requests = 1;
    billing.total_cost = 0.0123;
    try writeUsageUpdate(&out.writer, 8, 128_000, billing);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("cost") == null);
    const meta = parsed.value.object.get("_meta").?.object.get("fx").?.object.get("usage").?.object;
    try std.testing.expectEqualStrings("pending", meta.get("billing").?.string);
    try std.testing.expectEqual(@as(i64, 1), meta.get("pendingRequests").?.integer);
    const cost = meta.get("confirmed").?.object.get("cost").?.object;
    try std.testing.expectApproxEqAbs(@as(f64, 0.0123), cost.get("amount").?.float, 1e-12);
}

test "writeSessionUsage preserves unknown reasoning and request counts" {
    const alloc = std.testing.allocator;
    var usage = session_usage.Usage.initFresh();
    defer usage.deinit(alloc);
    var billing = usage.billingSnapshot();
    billing.billing = .legacy;
    billing.reasoning_tokens = null;
    billing.request_count = null;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeSessionUsage(&out.writer, billing);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    const confirmed = parsed.value.object.get("confirmed").?.object;
    try std.testing.expect(confirmed.get("reasoningTokens") == null);
    try std.testing.expect(confirmed.get("requests") == null);
    try std.testing.expectEqualStrings("legacy", parsed.value.object.get("billing").?.string);
}

test "writeSessionUpdate wraps update with sessionId" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeSessionUpdate(&out.writer, "sess_123", "{\"sessionUpdate\":\"test\"}");
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"sessionId\":\"sess_123\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"sessionUpdate\":\"test\"") != null);
}

test "model recovery info update is structured and clearable" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeModelRecoveryInfoUpdate(&out.writer, .{
        .kind = .terminal_provider_error,
        .failed_attempt = 4,
        .attempt_limit = 10,
        .cause = .system_resumed,
        .action = .paused,
        .required_action = .continue_later,
        .delay_seconds = 4,
        .diagnostic = core_types.ModelFailureDiagnostic.init("ConnectionResetByPeer"),
    }, true);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"state\":\"paused\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"cause\":\"system_resumed\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"requiredAction\":\"continue_later\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"attempt\":4") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"delaySeconds\":4") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"durable\":true") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "ConnectionResetByPeer") != null);

    out.writer.end = 0;
    try writeModelRecoveryInfoUpdate(&out.writer, .{
        .kind = .auto_recovered,
        .succeeded_attempt = 5,
        .attempt_limit = 10,
    }, true);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"state\":\"recovered\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"attempt\":5") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "ConnectionResetByPeer") == null);

    out.writer.end = 0;
    try writeModelRecoveryInfoUpdate(&out.writer, null, false);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"modelResponseRecovery\":null") != null);
}
