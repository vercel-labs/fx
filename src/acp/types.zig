const std = @import("std");
const build_options = @import("build_options");
const jsonrpc = @import("jsonrpc.zig");
const core_types = @import("../core/shared/types.zig");
const io_mod = @import("../core/shared/io.zig");

const Allocator = std.mem.Allocator;
const writeJsonStr = jsonrpc.writeJsonStr;
const sh_fx = @import("sh_fx.zig");
const command_contract = @import("../core/execution/command_contract.zig");

pub const MessageIdBuffer = [32]u8;

pub fn generateMessageId(storage: *MessageIdBuffer) []const u8 {
    var random_bytes: [16]u8 = undefined;
    io_mod.getIo().random(&random_bytes);
    storage.* = std.fmt.bytesToHex(random_bytes, .lower);
    return storage;
}

pub const protocol_version: u32 = 1;

/// Returns the borrowed value at `_meta[key]` on an ACP object, where `key` is
/// an `sh.fx/` key from `src/protocol/spec/sh-fx.md`.
pub fn metaField(object: std.json.ObjectMap, key: []const u8) ?std.json.Value {
    const meta = object.get("_meta") orelse return null;
    if (meta != .object) return null;
    return meta.object.get(key);
}

/// Returns `_meta[key]` when it is a JSON boolean.
pub fn metaBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = metaField(object, key) orelse return null;
    return if (value == .bool) value.bool else null;
}

/// Returns `_meta[key]` when it is a JSON integer.
pub fn metaInteger(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = metaField(object, key) orelse return null;
    return if (value == .integer) value.integer else null;
}

const model_recovery_update_prefix = "{\"sessionUpdate\":\"session_info_update\",\"_meta\":{\"sh.fx/modelResponseRecovery\":";

/// What a session load reports for a request an earlier fx process was
/// running when it stopped, for a client that lists
/// `sh.fx/modelResponseRecovery`. The key holds the recovery module's shape,
/// as in `fx ask --json` (decision 38). Null clears the client's status.
pub fn writeModelRecoveryInfoUpdate(
    writer: *std.Io.Writer,
    status: ?core_types.RouteRecoveryStatus,
) !void {
    try writer.writeAll(model_recovery_update_prefix);
    const recovery = status orelse {
        try writer.writeAll("null}}");
        return;
    };
    var label_buf: [core_types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try recovery.report(&label_buf).writeJson(writer);
    try writer.writeAll("}}");
}

pub const StopReason = enum {
    end_turn,
    max_output_tokens,
    max_model_turns,
    refused,
    cancelled,
    /// The host gave the turn a time to stop at, and it stopped before its
    /// next model request with the turn kept open for a later resume.
    yielded,

    pub fn jsonString(self: StopReason) []const u8 {
        return switch (self) {
            .end_turn => "end_turn",
            .max_output_tokens => "max_output_tokens",
            .max_model_turns => "max_model_turns",
            .refused => "refused",
            .cancelled => "cancelled",
            .yielded => "yielded",
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

/// ACP v1 Session Notice: shown to the user, never part of the session's
/// history. Only for a client that advertised `session.notices`.
pub fn writeNotice(w: *std.Io.Writer, severity: []const u8, title: []const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"notice\",\"severity\":");
    try writeJsonStr(severity, w);
    try w.writeAll(",\"title\":");
    try writeJsonStr(title, w);
    try w.writeByte('}');
}

test "writeNotice writes an ACP v1 notice update" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeNotice(&out.writer, "info", "A \"quoted\" title");
    try std.testing.expectEqualStrings("{\"sessionUpdate\":\"notice\",\"severity\":\"info\",\"title\":\"A \\\"quoted\\\" title\"}", out.written());
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

/// Host-facing identity of a tool call, sent as `sh.fx/toolCall` to a client
/// that lists it, so clients never need to match on tool names.
pub const ToolCallMeta = struct {
    /// fx's own discovery or bookkeeping step, which hosts may hide.
    internal: bool = false,
    /// The MCP server and its own tool name, for MCP tool calls.
    mcp: ?struct { server: []const u8, tool: []const u8 } = null,
};

fn writeToolCallMeta(w: *std.Io.Writer, meta: ToolCallMeta) !void {
    try w.writeAll(",\"_meta\":{\"sh.fx/toolCall\":{\"internal\":");
    try w.writeAll(if (meta.internal) "true" else "false");
    if (meta.mcp) |mcp| {
        try w.writeAll(",\"mcp\":{\"server\":");
        try writeJsonStr(mcp.server, w);
        try w.writeAll(",\"tool\":");
        try writeJsonStr(mcp.tool, w);
        try w.writeByte('}');
    }
    try w.writeAll("}}");
}

pub fn writeToolCall(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    name: []const u8,
    title: []const u8,
    kind: ToolCallKind,
    status: ToolCallStatus,
    raw_input: ?std.json.Value,
    /// Null for a client that doesn't list `sh.fx/toolCall`.
    meta: ?ToolCallMeta,
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
    if (meta) |value| try writeToolCallMeta(w, value);
    try w.writeAll("}");
}

pub fn writeToolCallUpdate(w: *std.Io.Writer, tool_call_id: []const u8, status: ToolCallStatus, content_text: ?[]const u8) !void {
    try writeToolCallUpdateWithCommandResult(w, tool_call_id, status, content_text, null);
}

/// A shell call's result, as the core's command runner reports it.
pub const CommandResult = command_contract.CommandResult;

/// The core's command result from its JSON, which uses fx's own snake_case
/// names (`CommandResult.writeJson`). Strings point into `arena`.
pub fn parseCommandResult(arena: std.mem.Allocator, json: []const u8) !CommandResult {
    return std.json.parseFromSliceLeaky(CommandResult, arena, json, .{ .ignore_unknown_fields = true });
}

/// `sh.fx/commandResult` in an update's `_meta`, in camelCase. Values the
/// command runner doesn't know, such as the exit code of a command a signal
/// stopped, are left out, and so are `terminationIndeterminate` and
/// `outputIncomplete` when they are false.
fn writeCommandResultMeta(w: *std.Io.Writer, result: CommandResult) !void {
    try w.writeAll(",\"_meta\":{\"sh.fx/commandResult\":{\"command\":");
    try writeJsonStr(result.command, w);
    try w.writeAll(",\"cwd\":");
    try writeJsonStr(result.cwd, w);
    if (result.exit_code) |code| try w.print(",\"exitCode\":{d}", .{code});
    if (result.signal) |signal| try w.print(",\"signal\":{d}", .{signal});
    try w.writeAll(if (result.timed_out) ",\"timedOut\":true" else ",\"timedOut\":false");
    if (result.termination_indeterminate) try w.writeAll(",\"terminationIndeterminate\":true");
    if (result.output_incomplete) try w.writeAll(",\"outputIncomplete\":true");
    if (result.duration_ms) |ms| try w.print(",\"durationMs\":{d}", .{ms});
    try w.print(",\"stdoutBytes\":{d},\"stderrBytes\":{d}", .{ result.stdout_bytes, result.stderr_bytes });
    try w.writeAll(if (result.truncated) ",\"truncated\":true" else ",\"truncated\":false");
    inline for (.{ .{ "outputFile", "output_file" }, .{ "stdoutFile", "stdout_file" }, .{ "stderrFile", "stderr_file" } }) |field| {
        if (@field(result, field[1])) |path| {
            try w.writeAll(",\"" ++ field[0] ++ "\":");
            try writeJsonStr(path, w);
        }
    }
    try w.writeAll("}}");
}

/// A shell call's `tool_call_update`. `command_result` is null for a client
/// that doesn't list `sh.fx/commandResult`, which gets standard ACP only.
pub fn writeToolCallUpdateWithCommandResult(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    status: ToolCallStatus,
    content_text: ?[]const u8,
    command_result: ?CommandResult,
) !void {
    try writeToolCallUpdateWithDiff(w, tool_call_id, status, null, content_text, command_result);
}

/// A file a tool call changes, whole before and after, as ACP v1's `diff`
/// tool call content. Borrowed.
pub const ToolDiff = struct {
    /// Absolute.
    path: []const u8,
    /// Null when the call creates the file.
    old_text: ?[]const u8,
    new_text: []const u8,
};

/// The most bytes each side of a diff may hold. A bigger file's call keeps
/// only its text, so each message stays well under the 8 MiB frame limit.
pub const max_tool_diff_side_bytes = 1 << 20;

/// Whether `diff` can go to the client: each side within the limit, and
/// UTF-8, as JSON text must be.
pub fn toolDiffFits(diff: ToolDiff) bool {
    if (diff.new_text.len > max_tool_diff_side_bytes or !std.unicode.utf8ValidateSlice(diff.new_text)) return false;
    const old = diff.old_text orelse return true;
    return old.len <= max_tool_diff_side_bytes and std.unicode.utf8ValidateSlice(old);
}

pub fn writeDiffContent(w: *std.Io.Writer, diff: ToolDiff) !void {
    try w.writeAll("{\"type\":\"diff\",\"path\":");
    try writeJsonStr(diff.path, w);
    try w.writeAll(",\"oldText\":");
    if (diff.old_text) |text| try writeJsonStr(text, w) else try w.writeAll("null");
    try w.writeAll(",\"newText\":");
    try writeJsonStr(diff.new_text, w);
    try w.writeByte('}');
}

/// A `tool_call_update` whose content is `diff`, when given, and then the
/// text. An update's content replaces the call's, so a call's last update
/// carries its diff (`tests/tla/acp/AcpToolDiffs.tla` DiffKept).
pub fn writeToolCallUpdateWithDiff(
    w: *std.Io.Writer,
    tool_call_id: []const u8,
    status: ToolCallStatus,
    diff: ?ToolDiff,
    content_text: ?[]const u8,
    command_result: ?CommandResult,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":");
    try writeJsonStr(tool_call_id, w);
    try w.writeAll(",\"status\":");
    try writeJsonStr(status.jsonString(), w);
    if (diff != null or content_text != null) {
        try w.writeAll(",\"content\":[");
        if (diff) |value| try writeDiffContent(w, value);
        if (content_text) |text| {
            if (diff != null) try w.writeByte(',');
            try w.writeAll("{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":");
            try writeJsonStr(text, w);
            try w.writeAll("}}");
        }
        try w.writeByte(']');
    }
    if (command_result) |result| try writeCommandResultMeta(w, result);
    try w.writeAll("}");
}

pub const AgentCapabilities = struct {
    image_prompts: bool,
    /// Accepts client `mcpServers` on session setup.
    mcp_servers: bool = true,
    /// The extensions fx lists in `agentCapabilities._meta`.
    extensions: sh_fx.Set = .empty,
    /// Deletes saved sessions through ACP's `session/delete`.
    session_delete: bool = false,
    /// Accepts a client system prompt on `session/new` in append mode.
    system_prompt: bool = false,
    /// Serves `type: "acp"` MCP servers over this connection.
    mcp_over_acp: bool = false,
    /// Speaks MCP's HTTP+SSE transport (2024-11-05), which fx's MCP engine doesn't.
    mcp_sse: bool = true,
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
        if (capabilities.mcp_servers and capabilities.mcp_sse) "true" else "false",
        if (capabilities.mcp_over_acp) "true" else "false",
    });
    try w.writeAll("\"sessionCapabilities\":{\"list\":{},\"resume\":{},\"close\":{}");
    if (capabilities.system_prompt) try w.writeAll(",\"systemPrompt\":{}");
    if (capabilities.session_delete) try w.writeAll(",\"delete\":{}");
    try w.writeByte('}');
    try writeExtensionList(w, capabilities.extensions);
    try w.writeAll("},\"agentInfo\":{\"name\":\"fx\",\"title\":\"fx\",\"version\":");
    try writeJsonStr(build_options.app_version, w);
    try w.writeAll("},");
    try w.writeAll("\"authMethods\":[]}");
}

/// Writes fx's extensions as `agentCapabilities._meta`, or nothing when fx
/// lists none. `sh.fx/promptDelivery` names both deliveries fx supports.
fn writeExtensionList(w: *std.Io.Writer, extensions: sh_fx.Set) !void {
    if (extensions.count() == 0) return;
    try w.writeAll(",\"_meta\":{");
    var first = true;
    var it = extensions.iterator();
    while (it.next()) |extension| {
        if (!first) try w.writeByte(',');
        first = false;
        try writeJsonStr(extension.capabilityName(), w);
        try w.writeAll(if (extension == .prompt_delivery) ":{\"steer\":{},\"queue\":{}}" else ":{}");
    }
    try w.writeByte('}');
}

pub fn writePromptResponse(w: *std.Io.Writer, reason: StopReason) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    try w.writeAll("}");
}

/// How a steer ran, as `sh.fx/steeringDelivery`: the running turn took it,
/// or it ran in the next turn, because that turn had stopped taking input or
/// the client stopped it.
pub const SteeringDelivery = enum {
    absorbed,
    next_turn,
};

/// Answers a steering prompt with its receiving turn's stop reason. Usage is
/// reported once, on the response to the prompt that started the turn.
/// `delivery` is null for a client that doesn't list `sh.fx/promptDelivery`.
pub fn writeSteeringPromptResponse(w: *std.Io.Writer, reason: StopReason, delivery: ?SteeringDelivery) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    if (delivery) |value| {
        try w.writeAll(",\"_meta\":{\"sh.fx/steeringDelivery\":");
        try writeJsonStr(@tagName(value), w);
        try w.writeByte('}');
    }
    try w.writeAll("}");
}

/// Replays delivered steering where the agent inserted it into the turn.
/// `steer_input` adds `sh.fx/steerInput`, with the steer's request id and,
/// for a host's steer, the input id the host gave it.
pub fn writeSteeringUserMessageChunk(
    w: *std.Io.Writer,
    message_id: []const u8,
    text: []const u8,
    request_id: ?jsonrpc.RequestId,
    input_id: ?[]const u8,
    steer_input: bool,
) !void {
    try w.writeAll("{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":");
    try writeJsonStr(message_id, w);
    try w.writeAll(",\"content\":{\"type\":\"text\",\"text\":");
    try writeJsonStr(text, w);
    try w.writeByte('}');
    if (steer_input) {
        try w.writeAll(",\"_meta\":{\"sh.fx/steerInput\":{\"requestId\":");
        try jsonrpc.Writer.writeId(w, request_id);
        if (input_id) |id| {
            try w.writeAll(",\"inputId\":");
            try writeJsonStr(id, w);
        }
        try w.writeAll("}}");
    }
    try w.writeAll("}");
}

test "steering replay carries a host's input id only when it has one" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeSteeringUserMessageChunk(&out.writer, "m1", "use tabs", .{ .integer = 4 }, null, true);
    try std.testing.expectEqualStrings(
        "{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":\"m1\",\"content\":{\"type\":\"text\",\"text\":\"use tabs\"},\"_meta\":{\"sh.fx/steerInput\":{\"requestId\":4}}}",
        out.written(),
    );
    out.clearRetainingCapacity();
    try writeSteeringUserMessageChunk(&out.writer, "m2", "be brief", null, "s1", true);
    try std.testing.expectEqualStrings(
        "{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":\"m2\",\"content\":{\"type\":\"text\",\"text\":\"be brief\"},\"_meta\":{\"sh.fx/steerInput\":{\"requestId\":null,\"inputId\":\"s1\"}}}",
        out.written(),
    );
}

test "steering replay and responses carry no sh.fx key for a client that doesn't list it" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeSteeringUserMessageChunk(&out.writer, "m1", "use tabs", .{ .integer = 4 }, null, false);
    try std.testing.expectEqualStrings(
        "{\"sessionUpdate\":\"user_message_chunk\",\"messageId\":\"m1\",\"content\":{\"type\":\"text\",\"text\":\"use tabs\"}}",
        out.written(),
    );
    out.clearRetainingCapacity();
    try writeSteeringPromptResponse(&out.writer, .end_turn, null);
    try std.testing.expectEqualStrings("{\"stopReason\":\"end_turn\"}", out.written());
    out.clearRetainingCapacity();
    try writeSteeringPromptResponse(&out.writer, .end_turn, .absorbed);
    try std.testing.expectEqualStrings("{\"stopReason\":\"end_turn\",\"_meta\":{\"sh.fx/steeringDelivery\":\"absorbed\"}}", out.written());
}

/// Answers the prompt that started a turn with its stop reason and its
/// tokens in `usage`, the field ACP's unstable schema defines on the
/// response. Counts the provider reported come first; where it reported
/// none, the counts fx estimated for the turn's summary stand in. `usage` is
/// left out when the input or output count is unknown. With `timing`, for a
/// client that lists `sh.fx/usage`, the response's `_meta` adds how long the
/// turn ran and whether each count is exact (`src/protocol/spec/sh-fx.md`
/// "Turn events").
pub fn writePromptResponseWithUsage(
    w: *std.Io.Writer,
    reason: StopReason,
    usage: core_types.Usage,
    summary: ?core_types.TurnSummary,
    timing: bool,
) !void {
    try w.writeAll("{\"stopReason\":");
    try writeJsonStr(reason.jsonString(), w);
    const progress: ?core_types.TurnTokenProgress = if (summary) |value| value.token_progress else null;
    const input: ?u64 = usage.input_tokens orelse if (progress) |value| value.input_tokens else null;
    const output: ?u64 = usage.output_tokens orelse if (progress) |value| value.output_tokens else null;
    const input_exact = usage.input_tokens != null or (progress != null and progress.?.input_exact);
    const output_exact = usage.output_tokens != null or (progress != null and progress.?.output_exact);
    if (input != null and output != null) {
        try w.print(",\"usage\":{{\"inputTokens\":{d},\"outputTokens\":{d},\"totalTokens\":{d}", .{ input.?, output.?, input.? +| output.? });
        inline for (.{
            .{ "thoughtTokens", usage.reasoning_tokens },
            .{ "cachedReadTokens", usage.cache_read_tokens },
            .{ "cachedWriteTokens", usage.cache_write_tokens },
        }) |field| {
            if (field[1]) |value| try w.print(",\"{s}\":{d}", .{ field[0], value });
        }
        try w.writeByte('}');
    }
    if (timing) if (summary) |value| {
        try w.print(
            ",\"_meta\":{{\"sh.fx/usage\":{{\"durationMs\":{d},\"thinkingMs\":{d},\"inputExact\":{},\"outputExact\":{}}}}}",
            .{ value.turn_duration_ms, value.thinking_duration_ms, input != null and input_exact, output != null and output_exact },
        );
    };
    try w.writeByte('}');
}

/// A time in milliseconds since the epoch as an ISO 8601 UTC time to the
/// second, as ACP's timestamps are. Caller owns the result.
pub fn formatIso8601(alloc: Allocator, timestamp_ms: i64) ![]u8 {
    const epoch_secs: u64 = @intCast(@divTrunc(@max(timestamp_ms, 0), 1000));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return alloc.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @backingInt(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

/// A running turn's progress, which `_sh.fx/session/turn_progress` sends
/// whole each time it changes (`src/protocol/spec/sh-fx.md` "Turn events").
pub const TurnProgress = struct {
    phase: ?core_types.TurnPhase = null,
    tokens: core_types.TurnTokenProgress = .{},
    /// The provider that served the turn's latest request, when the gateway
    /// names it.
    provider: ?[]const u8 = null,
};

pub fn writeTurnProgressParams(w: *std.Io.Writer, session_id: []const u8, progress: TurnProgress) !void {
    try w.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, w);
    if (progress.phase) |phase| {
        try w.writeAll(",\"phase\":");
        try writeJsonStr(@tagName(phase), w);
    }
    try w.print(",\"inputTokens\":{d},\"outputTokens\":{d},\"inputExact\":{},\"outputExact\":{}", .{
        progress.tokens.input_tokens,
        progress.tokens.output_tokens,
        progress.tokens.input_exact,
        progress.tokens.output_exact,
    });
    if (progress.provider) |provider| {
        try w.writeAll(",\"provider\":");
        try writeJsonStr(provider, w);
    }
    try w.writeByte('}');
}

/// One model call that ended, as `_sh.fx/session/model_call` carries it.
pub fn writeModelCallParams(alloc: Allocator, w: *std.Io.Writer, session_id: []const u8, call: core_types.ModelCallRecord) !void {
    try w.writeAll("{\"sessionId\":");
    try writeJsonStr(session_id, w);
    try w.writeAll(",\"purpose\":");
    try writeJsonStr(@tagName(call.purpose), w);
    try w.writeAll(",\"outcome\":");
    try writeJsonStr(@tagName(call.outcome), w);
    try w.writeAll(",\"provider\":");
    try writeJsonStr(call.provider, w);
    try w.writeAll(",\"model\":");
    try writeJsonStr(call.model, w);
    inline for (.{
        .{ "servedBy", call.served_by },
        .{ "generationId", call.generation_id },
        .{ "finish", call.finish },
        .{ "failure", call.failure },
    }) |field| {
        if (field[1]) |value| {
            try w.print(",\"{s}\":", .{field[0]});
            try writeJsonStr(value, w);
        }
    }
    if (call.retry_after_s) |value| try w.print(",\"retryAfterSeconds\":{d}", .{value});
    if (call.input_tokens) |value| try w.print(",\"inputTokens\":{d}", .{value});
    if (call.output_tokens) |value| try w.print(",\"outputTokens\":{d}", .{value});
    const ended_at = try formatIso8601(alloc, call.at_ms);
    defer alloc.free(ended_at);
    try w.writeAll(",\"endedAt\":");
    try writeJsonStr(ended_at, w);
    try w.print(",\"durationMs\":{d}}}", .{call.elapsed_ms});
}

/// The status of a context compaction in ACP v1's `compaction_update`.
pub const CompactionStatus = enum { in_progress, completed, failed, cancelled };

/// ACP v1's `compaction_update`, only for a client that lists
/// `session.compaction`. fx sends no `summary`: the one it keeps is written
/// for the model (`src/protocol/spec/sh-fx.md` "Turn events").
pub fn writeCompactionUpdate(w: *std.Io.Writer, compaction_id: []const u8, status: CompactionStatus, error_text: ?[]const u8) !void {
    try w.writeAll("{\"sessionUpdate\":\"compaction_update\",\"compactionId\":");
    try writeJsonStr(compaction_id, w);
    try w.writeAll(",\"status\":");
    try writeJsonStr(@tagName(status), w);
    if (error_text) |text| {
        try w.writeAll(",\"error\":");
        try writeJsonStr(text, w);
    }
    try w.writeByte('}');
}

/// The id of a session's n-th saved compaction, live and in a replay.
pub fn writeCompactionId(buf: []u8, number: usize) ![]const u8 {
    return std.mem.print(buf, "compaction-{d}", .{number});
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

pub fn writeUsageUpdate(w: *std.Io.Writer, used: u64, size: u64) !void {
    try w.print("{{\"sessionUpdate\":\"usage_update\",\"used\":{d},\"size\":{d}}}", .{ used, size });
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
    const tool_call_meta = parsed.value.object.get("_meta").?.object.get("sh.fx/toolCall").?.object;
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
    try std.testing.expectEqualStrings("yielded", StopReason.yielded.jsonString());
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

test "a shell call's command result goes in _meta as sh.fx/commandResult, in camelCase, and never at the root" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const result = try parseCommandResult(
        arena_state.allocator(),
        "{\"kind\":\"command\",\"command\":\"printf ok\",\"cwd\":\"/tmp\",\"exit_code\":0,\"signal\":null,\"timed_out\":false,\"duration_ms\":null,\"stdout_bytes\":2,\"stderr_bytes\":0,\"truncated\":false,\"output_file\":null,\"stdout_file\":null,\"stderr_file\":null}",
    );
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallUpdateWithCommandResult(&out.writer, "call_002", .completed, "exit_code=0\n<stdout>\nok\n</stdout>\n", result);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("tool_call_update", parsed.value.object.get("sessionUpdate").?.string);
    try std.testing.expect(parsed.value.object.get("command_result") == null);
    try std.testing.expect(parsed.value.object.get("content") != null);
    const meta = parsed.value.object.get("_meta").?.object.get("sh.fx/commandResult").?.object;
    try std.testing.expectEqualStrings("printf ok", meta.get("command").?.string);
    try std.testing.expectEqualStrings("/tmp", meta.get("cwd").?.string);
    try std.testing.expectEqual(@as(i64, 0), meta.get("exitCode").?.integer);
    try std.testing.expect(!meta.get("timedOut").?.bool);
    try std.testing.expectEqual(@as(i64, 2), meta.get("stdoutBytes").?.integer);
    try std.testing.expectEqual(@as(i64, 0), meta.get("stderrBytes").?.integer);
    try std.testing.expect(!meta.get("truncated").?.bool);
    // Unknown values and false flags are left out, and so is the core's kind.
    for ([_][]const u8{ "kind", "signal", "durationMs", "terminationIndeterminate", "outputIncomplete", "outputFile", "stdoutFile", "stderrFile" }) |name| {
        try std.testing.expect(meta.get(name) == null);
    }
    try std.testing.expectEqual(@as(usize, 7), meta.count());
}

test "a command result keeps every field through the core's JSON and into sh.fx/commandResult" {
    const alloc = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const full: CommandResult = .{
        .command = "sleep 9",
        .cwd = "/work",
        .exit_code = null,
        .signal = 9,
        .timed_out = true,
        .termination_indeterminate = true,
        .output_incomplete = true,
        .duration_ms = 30_000,
        .stdout_bytes = 12,
        .stderr_bytes = 3,
        .truncated = true,
        .output_file = "/out/all",
        .stdout_file = "/out/stdout",
        .stderr_file = "/out/stderr",
    };
    const back = try parseCommandResult(arena, try full.toJson(arena));
    try std.testing.expectEqualDeep(full, back);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallUpdateWithCommandResult(&out.writer, "call_9", .failed, "command timed out", back);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();
    const meta = parsed.value.object.get("_meta").?.object.get("sh.fx/commandResult").?.object;
    try std.testing.expect(meta.get("exitCode") == null);
    try std.testing.expectEqual(@as(i64, 9), meta.get("signal").?.integer);
    try std.testing.expect(meta.get("timedOut").?.bool);
    try std.testing.expect(meta.get("terminationIndeterminate").?.bool);
    try std.testing.expect(meta.get("outputIncomplete").?.bool);
    try std.testing.expectEqual(@as(i64, 30_000), meta.get("durationMs").?.integer);
    try std.testing.expect(meta.get("truncated").?.bool);
    try std.testing.expectEqualStrings("/out/all", meta.get("outputFile").?.string);
    try std.testing.expectEqualStrings("/out/stdout", meta.get("stdoutFile").?.string);
    try std.testing.expectEqualStrings("/out/stderr", meta.get("stderrFile").?.string);
    var keys = meta.iterator();
    while (keys.next()) |entry| try std.testing.expect(std.mem.findScalar(u8, entry.key_ptr.*, '_') == null);
}

test "a shell call's update for a client that doesn't list sh.fx/commandResult is standard ACP only" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallUpdateWithCommandResult(&out.writer, "call_003", .completed, "ok\n", null);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("_meta") == null);
    try std.testing.expect(parsed.value.object.get("command_result") == null);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.object.count());
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
    try writeInitializeResponse(&out.writer, .{
        .image_prompts = true,
        .extensions = .initMany(&.{ .prompt_delivery, .tool_call }),
        .system_prompt = true,
        .mcp_over_acp = true,
    });
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
    try std.testing.expect(session_capabilities.get("delete") == null);
    const extensions = agent_capabilities.get("_meta").?.object;
    try std.testing.expectEqual(@as(usize, 2), extensions.count());
    try std.testing.expect(extensions.get("sh.fx/promptDelivery").?.object.get("steer") != null);
    try std.testing.expect(extensions.get("sh.fx/promptDelivery").?.object.get("queue") != null);
    try std.testing.expectEqual(@as(usize, 0), extensions.get("sh.fx/toolCall").?.object.count());
}

test "writeInitializeResponse lists no _meta when fx lists no extension" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeInitializeResponse(&out.writer, .{ .image_prompts = false, .session_delete = true });
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.writer.buffered(), .{});
    defer parsed.deinit();
    const agent_capabilities = parsed.value.object.get("agentCapabilities").?.object;
    try std.testing.expect(agent_capabilities.get("_meta") == null);
    try std.testing.expect(agent_capabilities.get("sessionCapabilities").?.object.get("delete") != null);
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
    const meta = parsed.value.object.get("_meta").?.object.get("sh.fx/toolCall").?.object;
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

test "writeUsageUpdate reports context used and size" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeUsageUpdate(&out.writer, 8, 128_000);
    try std.testing.expectEqualStrings(
        "{\"sessionUpdate\":\"usage_update\",\"used\":8,\"size\":128000}",
        out.writer.buffered(),
    );
}

test "writeSessionUpdate wraps update with sessionId" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeSessionUpdate(&out.writer, "sess_123", "{\"sessionUpdate\":\"test\"}");
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"sessionId\":\"sess_123\"") != null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "\"sessionUpdate\":\"test\"") != null);
}

test "model recovery info update wraps the shared report and is clearable" {
    // The report's shape is `types.zig` "recovery reports write the shape fx
    // ask and ACP share"; this pins the ACP envelope around it.
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeModelRecoveryInfoUpdate(&out.writer, .{
        .kind = .waiting,
        .text = core_types.testRecoveryText("Gateway error · next try in 8s · attempt 4 · 1m 12s"),
        .attempt = 4,
    });
    try std.testing.expectEqualStrings(
        "{\"sessionUpdate\":\"session_info_update\",\"_meta\":{\"sh.fx/modelResponseRecovery\":{\"state\":\"waiting\",\"attempt\":4,\"message\":\"Gateway error · next try in 8s · attempt 4 · 1m 12s\"}}}",
        out.writer.buffered(),
    );

    out.writer.end = 0;
    try writeModelRecoveryInfoUpdate(&out.writer, null);
    try std.testing.expectEqualStrings(
        "{\"sessionUpdate\":\"session_info_update\",\"_meta\":{\"sh.fx/modelResponseRecovery\":null}}",
        out.writer.buffered(),
    );
}

test "writeToolCall leaves out sh.fx/toolCall for a client that doesn't list it" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeToolCall(&out.writer, "call_1", "read_file", "Reading file", .read, .pending, null, null);
    try std.testing.expect(std.mem.find(u8, out.writer.buffered(), "_meta") == null);
}

test "writePromptResponseWithUsage uses ACP's usage names and adds sh.fx/usage only when listed" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const summary: core_types.TurnSummary = .{
        .turn_duration_ms = 4210,
        .thinking_duration_ms = 640,
        .token_progress = .{ .input_tokens = 1700, .output_tokens = 400, .input_exact = false, .output_exact = false },
    };
    try writePromptResponseWithUsage(&out.writer, .end_turn, .{ .input_tokens = 1820, .output_tokens = 412, .cache_read_tokens = 1536, .reasoning_tokens = 30 }, summary, true);
    try std.testing.expectEqualStrings(
        "{\"stopReason\":\"end_turn\",\"usage\":{\"inputTokens\":1820,\"outputTokens\":412,\"totalTokens\":2232,\"thoughtTokens\":30,\"cachedReadTokens\":1536}," ++
            "\"_meta\":{\"sh.fx/usage\":{\"durationMs\":4210,\"thinkingMs\":640,\"inputExact\":true,\"outputExact\":true}}}",
        out.written(),
    );
    out.clearRetainingCapacity();
    // A provider that reports no counts: fx's estimate stands in, flagged.
    try writePromptResponseWithUsage(&out.writer, .end_turn, .{}, summary, true);
    try std.testing.expectEqualStrings(
        "{\"stopReason\":\"end_turn\",\"usage\":{\"inputTokens\":1700,\"outputTokens\":400,\"totalTokens\":2100}," ++
            "\"_meta\":{\"sh.fx/usage\":{\"durationMs\":4210,\"thinkingMs\":640,\"inputExact\":false,\"outputExact\":false}}}",
        out.written(),
    );
    out.clearRetainingCapacity();
    // No counts and no summary: no usage, and no sh.fx/usage for a client
    // that doesn't list it.
    try writePromptResponseWithUsage(&out.writer, .cancelled, .{}, null, false);
    try std.testing.expectEqualStrings("{\"stopReason\":\"cancelled\"}", out.written());
    out.clearRetainingCapacity();
    try writePromptResponseWithUsage(&out.writer, .end_turn, .{ .input_tokens = 5, .output_tokens = 2 }, summary, false);
    try std.testing.expectEqualStrings("{\"stopReason\":\"end_turn\",\"usage\":{\"inputTokens\":5,\"outputTokens\":2,\"totalTokens\":7}}", out.written());
}

test "writeTurnProgressParams sends the whole progress, and the phase and provider once known" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeTurnProgressParams(&out.writer, "sess-1", .{});
    try std.testing.expectEqualStrings("{\"sessionId\":\"sess-1\",\"inputTokens\":0,\"outputTokens\":0,\"inputExact\":true,\"outputExact\":true}", out.written());
    out.clearRetainingCapacity();
    try writeTurnProgressParams(&out.writer, "sess-1", .{
        .phase = .waiting_for_subagent,
        .tokens = .{ .input_tokens = 1820, .output_tokens = 96, .output_exact = false },
        .provider = "xai",
    });
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"sess-1\",\"phase\":\"waiting_for_subagent\",\"inputTokens\":1820,\"outputTokens\":96,\"inputExact\":true,\"outputExact\":false,\"provider\":\"xai\"}",
        out.written(),
    );
}

test "writeModelCallParams gives the call's fields, its end as ISO 8601, and leaves out unknown ones" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeModelCallParams(alloc, &out.writer, "sess-1", .{
        .at_ms = 1_700_000_000_512,
        .elapsed_ms = 3120,
        .purpose = .compaction,
        .outcome = .failed,
        .provider = "gateway",
        .model = "xai/grok-4",
        .failure = "rate \"limited\"",
        .retry_after_s = 30,
    });
    try std.testing.expectEqualStrings(
        "{\"sessionId\":\"sess-1\",\"purpose\":\"compaction\",\"outcome\":\"failed\",\"provider\":\"gateway\",\"model\":\"xai/grok-4\"," ++
            "\"failure\":\"rate \\\"limited\\\"\",\"retryAfterSeconds\":30,\"endedAt\":\"2023-11-14T22:13:20Z\",\"durationMs\":3120}",
        out.written(),
    );
}

test "writeCompactionUpdate writes ACP v1's compaction_update with no summary" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var id: [32]u8 = undefined;
    try writeCompactionUpdate(&out.writer, try writeCompactionId(&id, 2), .in_progress, null);
    try std.testing.expectEqualStrings("{\"sessionUpdate\":\"compaction_update\",\"compactionId\":\"compaction-2\",\"status\":\"in_progress\"}", out.written());
    out.clearRetainingCapacity();
    try writeCompactionUpdate(&out.writer, try writeCompactionId(&id, 2), .failed, "Compaction failed.");
    try std.testing.expectEqualStrings("{\"sessionUpdate\":\"compaction_update\",\"compactionId\":\"compaction-2\",\"status\":\"failed\",\"error\":\"Compaction failed.\"}", out.written());
}

test "writeToolCallUpdateWithDiff puts the diff before the text, and null oldText for a new file" {
    const alloc = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try writeToolCallUpdateWithDiff(&out.writer, "call_1", .completed, .{ .path = "/work/a.txt", .old_text = "one\n", .new_text = "two\n" }, "Edited a.txt", null);
    try std.testing.expectEqualStrings(
        "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"call_1\",\"status\":\"completed\",\"content\":[" ++
            "{\"type\":\"diff\",\"path\":\"/work/a.txt\",\"oldText\":\"one\\n\",\"newText\":\"two\\n\"}," ++
            "{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"Edited a.txt\"}}]}",
        out.written(),
    );
    out.clearRetainingCapacity();
    try writeToolCallUpdateWithDiff(&out.writer, "call_2", .pending, .{ .path = "/work/new.txt", .old_text = null, .new_text = "x" }, null, null);
    try std.testing.expectEqualStrings(
        "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"call_2\",\"status\":\"pending\",\"content\":[{\"type\":\"diff\",\"path\":\"/work/new.txt\",\"oldText\":null,\"newText\":\"x\"}]}",
        out.written(),
    );
}

test "toolDiffFits takes each side up to the limit, in UTF-8 only" {
    const alloc = std.testing.allocator;
    const big = try alloc.alloc(u8, max_tool_diff_side_bytes + 1);
    defer alloc.free(big);
    @memset(big, 'a');
    try std.testing.expect(toolDiffFits(.{ .path = "/a", .old_text = null, .new_text = big[0..max_tool_diff_side_bytes] }));
    try std.testing.expect(!toolDiffFits(.{ .path = "/a", .old_text = null, .new_text = big }));
    try std.testing.expect(!toolDiffFits(.{ .path = "/a", .old_text = big, .new_text = "x" }));
    try std.testing.expect(!toolDiffFits(.{ .path = "/a", .old_text = "\xff\xfe", .new_text = "x" }));
}
