const std = @import("std");

const stream_provider = @import("../core/agent/stream_provider.zig");
const io_mod = @import("../core/shared/io.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

const anthropic_prefix = "anthropic-max/";
const codex_prefix = "openai-codex/";
const xai_prefix = "xai-direct/";

const anthropic_url = "https://api.anthropic.com/v1/messages";
const codex_url = "https://chatgpt.com/backend-api/codex/responses";
const xai_url = "https://api.x.ai/v1/responses";

const max_error_body_bytes = 1024 * 1024;
const max_sse_line_bytes = 4 * 1024 * 1024;
const claude_code_identity = "You are Claude Code, Anthropic's official CLI for Claude.";

const Family = enum { anthropic, codex, xai };

const DirectModel = struct {
    family: Family,
    wire_model: []const u8,
    endpoint: []const u8,
};

pub const agent_stream_provider = stream_provider.Provider{
    .build_fn = build,
    .stream_fn = stream,
};

fn directModel(model: []const u8) ?DirectModel {
    const cases = [_]struct { prefix: []const u8, family: Family, endpoint: []const u8 }{
        .{ .prefix = anthropic_prefix, .family = .anthropic, .endpoint = anthropic_url },
        .{ .prefix = codex_prefix, .family = .codex, .endpoint = codex_url },
        .{ .prefix = xai_prefix, .family = .xai, .endpoint = xai_url },
    };
    for (cases) |case| {
        if (std.mem.startsWith(u8, model, case.prefix) and model.len > case.prefix.len) {
            return .{
                .family = case.family,
                .wire_model = model[case.prefix.len..],
                .endpoint = case.endpoint,
            };
        }
    }
    return null;
}

fn build(_: ?*anyopaque, alloc: Allocator, request: stream_provider.BuildRequest) anyerror![]u8 {
    const direct = directModel(request.model) orelse return error.AgentStreamProviderUnavailable;
    try checkBuildBudget(request.budget);
    if (request.verified_images != null or request.response_format != null) {
        return error.DirectProviderUnsupportedRequest;
    }
    return switch (direct.family) {
        .anthropic => buildAnthropicRequest(alloc, direct.wire_model, request),
        .codex, .xai => buildResponsesRequest(alloc, direct, request),
    };
}

fn checkBuildBudget(budget: ?stream_provider.BuildBudget) !void {
    const active = budget orelse return;
    if (active.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    if (active.deadline) |deadline| {
        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (now.raw.nanoseconds >= deadline.raw.nanoseconds) return error.TimedOut;
    }
}

fn buildAnthropicRequest(alloc: Allocator, wire_model: []const u8, request: stream_provider.BuildRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try writeJson(writer, wire_model);
    try writer.print(",\"max_tokens\":{d},\"stream\":true", .{request.max_output_tokens orelse 32_000});

    try writer.writeAll(",\"system\":[{\"type\":\"text\",\"text\":");
    try writeJson(writer, claude_code_identity);
    try writer.writeByte('}');
    for (request.messages) |message| if (message.role == .system and message.content != null) {
        try writer.writeAll(", {\"type\":\"text\",\"text\":");
        try writeJson(writer, message.content.?);
        try writer.writeByte('}');
    };
    try writer.writeByte(']');

    try writer.writeAll(",\"messages\":[");
    var first = true;
    for (request.messages) |message| {
        if (message.role == .system) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writeAnthropicMessage(writer, message);
    }
    try writer.writeByte(']');
    try writeAnthropicTools(alloc, writer, request.serialized_tools, request.tool_choice);
    if (request.provider_options.reasoning) |*effort| {
        try writer.writeAll(",\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":");
        try writeJson(writer, effort.label());
        try writer.writeByte('}');
    }
    try writer.writeByte('}');
    try checkBuildBudget(request.budget);
    return out.toOwnedSlice();
}

fn writeAnthropicMessage(writer: *std.Io.Writer, message: types.ChatMessage) !void {
    if (message.role == .tool) {
        try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":");
        try writeJson(writer, message.tool_call_id orelse "");
        try writer.writeAll(",\"content\":");
        try writeJson(writer, message.content orelse "");
        if (message.tool_result_status) |status| if (status == .failure) try writer.writeAll(",\"is_error\":true");
        try writer.writeAll("}]}");
        return;
    }

    try writer.writeAll("{\"role\":");
    try writeJson(writer, if (message.role == .assistant) "assistant" else "user");
    if (message.tool_calls.len == 0) {
        try writer.writeAll(",\"content\":");
        try writeJson(writer, message.content orelse "");
        try writer.writeByte('}');
        return;
    }

    try writer.writeAll(",\"content\":[");
    var first = true;
    if (message.content) |content| if (content.len > 0) {
        try writer.writeAll("{\"type\":\"text\",\"text\":");
        try writeJson(writer, content);
        try writer.writeByte('}');
        first = false;
    };
    for (message.tool_calls) |call| {
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
        try writeJson(writer, call.id);
        try writer.writeAll(",\"name\":");
        try writeJson(writer, call.name);
        try writer.writeAll(",\"input\":");
        try writer.writeAll(if (call.arguments_json.len == 0) "{}" else call.arguments_json);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn writeAnthropicTools(alloc: Allocator, writer: *std.Io.Writer, tools_json: []const u8, choice: types.ToolChoice) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len == 0) return;

    var function_count: usize = 0;
    for (parsed.value.array.items) |tool| {
        if (!isUnsupportedDirectTool(tool)) function_count += 1;
    }
    if (function_count == 0) return;

    try writer.writeAll(",\"tools\":[");
    var first = true;
    for (parsed.value.array.items) |tool| {
        if (isUnsupportedDirectTool(tool)) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        const object = if (tool == .object) tool.object else return error.InvalidDirectToolSchema;
        try writer.writeAll("{\"name\":");
        try writeJsonValue(writer, object.get("name") orelse return error.InvalidDirectToolSchema);
        if (object.get("description")) |description| {
            try writer.writeAll(",\"description\":");
            try writeJsonValue(writer, description);
        }
        try writer.writeAll(",\"input_schema\":");
        try writeJsonValue(writer, object.get("inputSchema") orelse object.get("parameters") orelse return error.InvalidDirectToolSchema);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
    try writer.writeAll(if (choice == .none) ",\"tool_choice\":{\"type\":\"none\"}" else ",\"tool_choice\":{\"type\":\"auto\"}");
}

fn buildResponsesRequest(alloc: Allocator, direct: DirectModel, request: stream_provider.BuildRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try writeJson(writer, direct.wire_model);
    try writer.writeAll(",\"stream\":true,\"store\":false");
    if (direct.family != .codex) {
        if (request.max_output_tokens) |limit| try writer.print(",\"max_output_tokens\":{d}", .{limit});
    }

    var has_system = false;
    for (request.messages) |message| if (message.role == .system and message.content != null) {
        if (!has_system) {
            try writer.writeAll(",\"instructions\":");
            var joined: std.Io.Writer.Allocating = .init(alloc);
            defer joined.deinit();
            for (request.messages) |system_message| if (system_message.role == .system) {
                if (system_message.content) |content| {
                    if (joined.writer.buffered().len > 0) try joined.writer.writeAll("\n\n");
                    try joined.writer.writeAll(content);
                }
            };
            try writeJson(writer, joined.writer.buffered());
            has_system = true;
        }
    };

    try writer.writeAll(",\"input\":[");
    var first = true;
    for (request.messages) |message| {
        if (message.role == .system) continue;
        if (message.role == .tool) {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
            try writeJson(writer, message.tool_call_id orelse "");
            try writer.writeAll(",\"output\":");
            try writeJson(writer, message.content orelse "");
            try writer.writeByte('}');
            continue;
        }
        if (message.content) |content| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("{\"role\":");
            try writeJson(writer, if (message.role == .assistant) "assistant" else "user");
            try writer.writeAll(",\"content\":");
            try writeJson(writer, content);
            try writer.writeByte('}');
        }
        for (message.tool_calls) |call| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
            try writeJson(writer, call.id);
            try writer.writeAll(",\"name\":");
            try writeJson(writer, call.name);
            try writer.writeAll(",\"arguments\":");
            try writeJson(writer, call.arguments_json);
            try writer.writeByte('}');
        }
    }
    try writer.writeByte(']');
    const wrote_tool_choice = try writeResponsesTools(alloc, writer, request.serialized_tools, request.tool_choice);
    if (direct.family == .codex) {
        try writer.writeAll(",\"text\":{\"verbosity\":\"low\"},\"include\":[\"reasoning.encrypted_content\"]");
        if (!wrote_tool_choice) {
            try writer.writeAll(",\"tool_choice\":\"auto\"");
        }
        try writer.writeAll(",\"parallel_tool_calls\":true");
    } else if (request.provider_options.parallel_tool_calls) |enabled| {
        try writer.print(",\"parallel_tool_calls\":{}", .{enabled});
    }
    if (request.provider_options.reasoning) |*effort| {
        try writer.writeAll(",\"reasoning\":{\"effort\":");
        try writeJson(writer, effort.label());
        try writer.writeAll(",\"summary\":\"auto\"}");
        if (direct.family != .codex) try writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]");
    }
    try writer.writeByte('}');
    try checkBuildBudget(request.budget);
    return out.toOwnedSlice();
}

fn writeResponsesTools(alloc: Allocator, writer: *std.Io.Writer, tools_json: []const u8, choice: types.ToolChoice) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len == 0) return false;

    var function_count: usize = 0;
    for (parsed.value.array.items) |tool| {
        if (!isUnsupportedDirectTool(tool)) function_count += 1;
    }
    if (function_count == 0) return false;

    try writer.writeAll(",\"tools\":[");
    var first = true;
    for (parsed.value.array.items) |tool| {
        if (isUnsupportedDirectTool(tool)) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        const object = if (tool == .object) tool.object else return error.InvalidDirectToolSchema;
        try writer.writeAll("{\"type\":\"function\",\"name\":");
        try writeJsonValue(writer, object.get("name") orelse return error.InvalidDirectToolSchema);
        if (object.get("description")) |description| {
            try writer.writeAll(",\"description\":");
            try writeJsonValue(writer, description);
        }
        try writer.writeAll(",\"parameters\":");
        try writeJsonValue(writer, object.get("inputSchema") orelse object.get("parameters") orelse return error.InvalidDirectToolSchema);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"tool_choice\":");
    try writeJson(writer, choice.label());
    return true;
}

fn isUnsupportedDirectTool(tool: std.json.Value) bool {
    if (jsonString(tool, "type")) |kind| {
        if (std.mem.eql(u8, kind, "provider")) return true;
    }
    if (jsonString(tool, "name")) |name| {
        if (std.mem.eql(u8, name, "vision")) return true;
    }
    return false;
}

fn writeJson(writer: *std.Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn writeJsonValue(writer: *std.Io.Writer, value: std.json.Value) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn stream(_: ?*anyopaque, alloc: Allocator, request: stream_provider.Request) anyerror!stream_provider.Result {
    const direct = directModel(request.model) orelse return error.AgentStreamProviderUnavailable;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    const endpoint = if (direct.family == .anthropic and std.mem.startsWith(u8, request.api_key, "sk-ant-oat"))
        anthropic_url ++ "?beta=true"
    else
        direct.endpoint;
    const uri = try std.Uri.parse(endpoint);
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    const auth = try std.fmt.allocPrint(alloc, "Bearer {s}", .{request.api_key});
    defer {
        @memset(auth, 0);
        alloc.free(auth);
    }
    var extra_headers_buf: [9]std.http.Header = undefined;
    const extra_headers = try directHeaders(alloc, &extra_headers_buf, direct.family, request, auth);
    defer if (direct.family == .codex and extra_headers.len > 0) {
        const account_id = extra_headers[0].value;
        @memset(@constCast(account_id), 0);
        alloc.free(@constCast(account_id));
    };

    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .omit,
            .authorization = if (direct.family == .anthropic and !std.mem.startsWith(u8, request.api_key, "sk-ant-oat")) .omit else .{ .override = auth },
            .user_agent = .{ .override = if (direct.family == .anthropic) "claude-cli/2.1.76 (external, cli)" else "fx" },
        },
        .extra_headers = extra_headers,
        .keep_alive = false,
        .redirect_behavior = .unhandled,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = request.payload.len };
    var send_buf: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try req.sendBodyUnflushed(&send_buf);
    try body_writer.writer.writeAll(request.payload);
    try body_writer.end();
    if (req.connection) |connection| try connection.flush();
    var response = try req.receiveHead(&.{});

    if (response.head.status != .ok) {
        var transfer_buf: [4096]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = reader.allocRemaining(alloc, .limited(max_error_body_bytes)) catch null;
        return .{ .status = response.head.status, .err_body = body, .ownership = .owned };
    }

    var transfer_buf: [16 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const completion = try consumeDirectSse(
        alloc,
        reader,
        direct.family,
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.on_reasoning_chunk,
        request.on_tool_input_chunk,
        request.cancel_flag,
        request.content_capture_limit,
    );
    return .{ .status = .ok, .completion = completion, .ownership = .owned };
}

fn directHeaders(
    alloc: Allocator,
    buf: []std.http.Header,
    family: Family,
    request: stream_provider.Request,
    auth: []const u8,
) ![]const std.http.Header {
    var len: usize = 0;
    if (request.session_id) |session_id| {
        if (!validHeaderValue(session_id)) return error.InvalidDirectProviderHeader;
    }
    switch (family) {
        .anthropic => {
            buf[len] = .{ .name = "accept", .value = "text/event-stream" };
            len += 1;
            buf[len] = .{ .name = "anthropic-version", .value = "2023-06-01" };
            len += 1;
            buf[len] = .{ .name = "anthropic-dangerous-direct-browser-access", .value = "true" };
            len += 1;
            if (std.mem.startsWith(u8, request.api_key, "sk-ant-oat")) {
                buf[len] = .{ .name = "anthropic-beta", .value = "claude-code-20250219,oauth-2025-04-20" };
                len += 1;
                buf[len] = .{ .name = "x-app", .value = "cli" };
                len += 1;
                if (request.session_id) |session_id| if (session_id.len > 0) {
                    buf[len] = .{ .name = "X-Claude-Code-Session-Id", .value = session_id };
                    len += 1;
                };
            } else {
                buf[len] = .{ .name = "x-api-key", .value = request.api_key };
                len += 1;
            }
        },
        .codex => {
            const account_id = try resolveCodexAccountId(alloc, request.api_key);
            errdefer alloc.free(account_id);
            buf[len] = .{ .name = "chatgpt-account-id", .value = account_id };
            len += 1;
            buf[len] = .{ .name = "originator", .value = "codex_cli_rs" };
            len += 1;
            buf[len] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
            len += 1;
            buf[len] = .{ .name = "accept", .value = "text/event-stream" };
            len += 1;
            if (request.session_id) |session_id| if (session_id.len > 0) {
                buf[len] = .{ .name = "session-id", .value = session_id };
                len += 1;
                buf[len] = .{ .name = "x-client-request-id", .value = session_id };
                len += 1;
            };
        },
        .xai => {
            _ = auth;
            buf[len] = .{ .name = "accept", .value = "text/event-stream" };
            len += 1;
        },
    }
    return buf[0..len];
}

fn resolveCodexAccountId(alloc: Allocator, token: []const u8) ![]u8 {
    if (try codexAccountIdFromToken(alloc, token)) |account_id| return account_id;
    if (io_mod.getenv("CODEX_ACCOUNT_ID")) |value| if (value.len > 0 and validHeaderValue(value)) return alloc.dupe(u8, value);
    const home = io_mod.getenv("HOME") orelse return error.CodexAccountIdUnavailable;
    const path = try std.fs.path.join(alloc, &.{ home, ".codex", "auth.json" });
    defer alloc.free(path);
    var file = std.Io.Dir.cwd().openFile(io_mod.getIo(), path, .{}) catch return error.CodexAccountIdUnavailable;
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(alloc, &file, 1024 * 1024) catch return error.CodexAccountIdUnavailable;
    defer alloc.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return error.CodexAccountIdUnavailable;
    defer parsed.deinit();
    if (parsed.value != .object) return error.CodexAccountIdUnavailable;
    const tokens = parsed.value.object.get("tokens") orelse return error.CodexAccountIdUnavailable;
    if (tokens != .object) return error.CodexAccountIdUnavailable;
    const account = tokens.object.get("account_id") orelse return error.CodexAccountIdUnavailable;
    if (account != .string or account.string.len == 0 or !validHeaderValue(account.string)) return error.CodexAccountIdUnavailable;
    return alloc.dupe(u8, account.string);
}

fn codexAccountIdFromToken(alloc: Allocator, token: []const u8) !?[]u8 {
    const first_dot = std.mem.findScalar(u8, token, '.') orelse return null;
    const payload_start = first_dot + 1;
    const second_relative = std.mem.findScalar(u8, token[payload_start..], '.') orelse return null;
    const payload = token[payload_start .. payload_start + second_relative];
    if (payload.len == 0) return null;

    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return null;
    const decoded = try alloc.alloc(u8, decoded_len);
    defer alloc.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload) catch return null;

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, decoded, .{}) catch return null;
    defer parsed.deinit();
    const auth = jsonObject(parsed.value, "https://api.openai.com/auth") orelse return null;
    const account_id = jsonString(auth, "chatgpt_account_id") orelse return null;
    if (account_id.len == 0 or !validHeaderValue(account_id)) return null;
    return @as(?[]u8, try alloc.dupe(u8, account_id));
}

fn validHeaderValue(value: []const u8) bool {
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == ':') return false;
    }
    return true;
}

const ToolAccumulator = struct {
    id: std.ArrayList(u8) = .empty,
    item_id: std.ArrayList(u8) = .empty,
    name: std.ArrayList(u8) = .empty,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.id.deinit(alloc);
        self.item_id.deinit(alloc);
        self.name.deinit(alloc);
        self.arguments.deinit(alloc);
    }
};

fn consumeDirectSse(
    alloc: Allocator,
    reader: *std.Io.Reader,
    family: Family,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    content_capture_limit: ?usize,
) !types.GatewayCompletion {
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var tools: std.ArrayList(ToolAccumulator) = .empty;
    defer {
        for (tools.items) |*tool| tool.deinit(alloc);
        tools.deinit(alloc);
    }
    var usage: types.Usage = .{};
    var finish_reason: ?types.ProviderFinishReason = null;
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(alloc);

    while (!cancel_flag.load(.seq_cst)) {
        line_buf.clearRetainingCapacity();
        const line = try readSseLine(alloc, reader, &line_buf) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const data = std.mem.trimStart(u8, trimmed["data:".len..], " ");
        if (std.mem.eql(u8, data, "[DONE]")) break;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        switch (family) {
            .anthropic => try consumeAnthropicEvent(alloc, parsed.value, &content, &tools, &usage, &finish_reason, callback_ctx, on_content_chunk, on_tool_start, on_reasoning_chunk, on_tool_input_chunk, content_capture_limit),
            .codex, .xai => try consumeResponsesEvent(alloc, parsed.value, &content, &tools, &usage, &finish_reason, callback_ctx, on_content_chunk, on_tool_start, on_reasoning_chunk, on_tool_input_chunk, content_capture_limit),
        }
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;

    var completion: types.GatewayCompletion = .{ .usage = usage, .finish_reason = finish_reason };
    errdefer freeCompletion(alloc, &completion);
    if (content.items.len > 0) completion.content = try alloc.dupe(u8, content.items);
    const tool_calls = try alloc.alloc(types.ToolCall, tools.items.len);
    var initialized: usize = 0;
    errdefer {
        for (tool_calls[0..initialized]) |call| {
            alloc.free(@constCast(call.id));
            alloc.free(@constCast(call.name));
            alloc.free(@constCast(call.arguments_json));
        }
        alloc.free(tool_calls);
    }
    for (tools.items, 0..) |tool, index| {
        const id = try alloc.dupe(u8, tool.id.items);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, tool.name.items);
        errdefer alloc.free(name);
        const arguments = try alloc.dupe(u8, if (tool.arguments.items.len > 0) tool.arguments.items else "{}");
        errdefer alloc.free(arguments);
        tool_calls[index] = .{
            .id = id,
            .name = name,
            .arguments_json = arguments,
        };
        initialized += 1;
    }
    completion.tool_calls = tool_calls;
    if (completion.finish_reason == null and completion.tool_calls.len > 0) completion.finish_reason = .tool_calls;
    return completion;
}

fn readSseLine(alloc: Allocator, reader: *std.Io.Reader, pending: *std.ArrayList(u8)) !?[]const u8 {
    while (true) {
        const fragment = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                const buffered = reader.buffered();
                if (buffered.len == 0 or buffered.len > max_sse_line_bytes - pending.items.len) return error.DirectSseEventTooLarge;
                try pending.appendSlice(alloc, buffered);
                reader.tossBuffered();
                continue;
            },
            else => return err,
        } orelse return if (pending.items.len > 0) pending.items else null;
        if (fragment.len > max_sse_line_bytes - pending.items.len) return error.DirectSseEventTooLarge;
        if (pending.items.len == 0) return fragment;
        try pending.appendSlice(alloc, fragment);
        return pending.items;
    }
}

fn consumeAnthropicEvent(
    alloc: Allocator,
    root: std.json.Value,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAccumulator),
    usage: *types.Usage,
    finish_reason: *?types.ProviderFinishReason,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    content_capture_limit: ?usize,
) !void {
    const event_type = jsonString(root, "type") orelse return;
    if (std.mem.eql(u8, event_type, "message_start")) {
        if (jsonObject(root, "message")) |message| {
            if (jsonObject(message, "usage")) |value| {
                usage.input_tokens = jsonU64(value, "input_tokens");
            }
        }
        return;
    }
    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const block = jsonObject(root, "content_block") orelse return;
        if (!std.mem.eql(u8, jsonString(block, "type") orelse "", "tool_use")) return;
        var tool: ToolAccumulator = .{};
        errdefer tool.deinit(alloc);
        try tool.id.appendSlice(alloc, jsonString(block, "id") orelse "");
        try tool.name.appendSlice(alloc, jsonString(block, "name") orelse "");
        if (block.object.get("input")) |input| {
            if (input == .object and input.object.count() > 0) try appendJsonValue(alloc, &tool.arguments, input);
        }
        try tools.append(alloc, tool);
        if (on_tool_start) |callback| callback(callback_ctx, tool.id.items, tool.name.items, null);
        return;
    }
    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const delta = jsonObject(root, "delta") orelse return;
        const delta_type = jsonString(delta, "type") orelse return;
        if (std.mem.eql(u8, delta_type, "text_delta")) {
            if (jsonString(delta, "text")) |text| try emitContent(alloc, content, text, callback_ctx, on_content_chunk, content_capture_limit);
        } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
            if (on_reasoning_chunk) |callback| if (jsonString(delta, "thinking")) |thinking| callback(callback_ctx, thinking);
        } else if (std.mem.eql(u8, delta_type, "input_json_delta") and tools.items.len > 0) {
            if (jsonString(delta, "partial_json")) |partial| {
                try tools.items[tools.items.len - 1].arguments.appendSlice(alloc, partial);
                if (on_tool_input_chunk) |callback| callback(callback_ctx, partial);
            }
        }
        return;
    }
    if (std.mem.eql(u8, event_type, "message_delta")) {
        if (jsonObject(root, "delta")) |delta| finish_reason.* = mapAnthropicFinish(jsonString(delta, "stop_reason"));
        if (jsonObject(root, "usage")) |value| usage.output_tokens = jsonU64(value, "output_tokens");
    }
}

fn consumeResponsesEvent(
    alloc: Allocator,
    root: std.json.Value,
    content: *std.ArrayList(u8),
    tools: *std.ArrayList(ToolAccumulator),
    usage: *types.Usage,
    finish_reason: *?types.ProviderFinishReason,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    on_tool_input_chunk: ?stream_provider.StreamCallback,
    content_capture_limit: ?usize,
) !void {
    const event_type = jsonString(root, "type") orelse return;
    if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
        if (jsonString(root, "delta")) |delta| try emitContent(alloc, content, delta, callback_ctx, on_content_chunk, content_capture_limit);
        return;
    }
    if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta")) {
        if (on_reasoning_chunk) |callback| if (jsonString(root, "delta")) |delta| callback(callback_ctx, delta);
        return;
    }
    if (std.mem.eql(u8, event_type, "response.output_item.added")) {
        const item = jsonObject(root, "item") orelse return;
        if (!std.mem.eql(u8, jsonString(item, "type") orelse "", "function_call")) return;
        var tool: ToolAccumulator = .{};
        errdefer tool.deinit(alloc);
        try tool.id.appendSlice(alloc, jsonString(item, "call_id") orelse jsonString(item, "id") orelse "");
        try tool.item_id.appendSlice(alloc, jsonString(item, "id") orelse "");
        try tool.name.appendSlice(alloc, jsonString(item, "name") orelse "");
        if (jsonString(item, "arguments")) |arguments| try tool.arguments.appendSlice(alloc, arguments);
        try tools.append(alloc, tool);
        if (on_tool_start) |callback| callback(callback_ctx, tool.id.items, tool.name.items, null);
        return;
    }
    if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
        const id = jsonString(root, "item_id") orelse jsonString(root, "call_id");
        const delta = jsonString(root, "delta") orelse return;
        if (findTool(tools.items, id)) |tool| {
            try tool.arguments.appendSlice(alloc, delta);
            if (on_tool_input_chunk) |callback| callback(callback_ctx, delta);
        }
        return;
    }
    if (std.mem.eql(u8, event_type, "response.output_item.done")) {
        const item = jsonObject(root, "item") orelse return;
        if (!std.mem.eql(u8, jsonString(item, "type") orelse "", "function_call")) return;
        const id = jsonString(item, "call_id") orelse jsonString(item, "id");
        if (findTool(tools.items, id)) |tool| if (jsonString(item, "arguments")) |arguments| {
            tool.arguments.clearRetainingCapacity();
            try tool.arguments.appendSlice(alloc, arguments);
        };
        return;
    }
    if (std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.incomplete")) {
        const response = jsonObject(root, "response") orelse root;
        if (jsonObject(response, "usage")) |value| {
            usage.input_tokens = jsonU64(value, "input_tokens");
            usage.output_tokens = jsonU64(value, "output_tokens");
        }
        finish_reason.* = if (std.mem.eql(u8, event_type, "response.incomplete")) .length else if (tools.items.len > 0) .tool_calls else .stop;
        return;
    }
    if (std.mem.eql(u8, event_type, "response.failed")) finish_reason.* = .provider_error;
}

fn emitContent(alloc: Allocator, content: *std.ArrayList(u8), delta: []const u8, ctx: *anyopaque, callback: stream_provider.StreamCallback, limit: ?usize) !void {
    const retained = if (limit) |max| delta[0..@min(delta.len, max -| content.items.len)] else delta;
    try content.appendSlice(alloc, retained);
    callback(ctx, delta);
}

fn findTool(tools: []ToolAccumulator, id: ?[]const u8) ?*ToolAccumulator {
    if (id) |needle| for (tools) |*tool| {
        if (std.mem.eql(u8, tool.id.items, needle) or std.mem.eql(u8, tool.item_id.items, needle)) return tool;
    };
    return null;
}

fn appendJsonValue(alloc: Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    try out.appendSlice(alloc, writer.writer.buffered());
}

fn jsonString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const child = value.object.get(key) orelse return null;
    return if (child == .string) child.string else null;
}

fn jsonObject(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const child = value.object.get(key) orelse return null;
    return if (child == .object) child else null;
}

fn jsonU64(value: std.json.Value, key: []const u8) ?u64 {
    if (value != .object) return null;
    const child = value.object.get(key) orelse return null;
    return if (child == .integer and child.integer >= 0) @intCast(child.integer) else null;
}

fn mapAnthropicFinish(reason: ?[]const u8) ?types.ProviderFinishReason {
    const value = reason orelse return null;
    if (std.mem.eql(u8, value, "end_turn") or std.mem.eql(u8, value, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, value, "max_tokens")) return .length;
    if (std.mem.eql(u8, value, "tool_use")) return .tool_calls;
    if (std.mem.eql(u8, value, "refusal")) return .content_filter;
    return .other;
}

fn freeCompletion(alloc: Allocator, completion: *types.GatewayCompletion) void {
    if (completion.content) |content| alloc.free(@constCast(content));
    types.freeToolCallSlice(alloc, @constCast(completion.tool_calls));
    completion.* = .{};
}

const TestCapture = struct {
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    tool_input: std.ArrayList(u8) = .empty,
    tool_starts: usize = 0,

    fn deinit(self: *@This(), alloc: Allocator) void {
        self.content.deinit(alloc);
        self.reasoning.deinit(alloc);
        self.tool_input.deinit(alloc);
    }

    fn onContent(raw: *anyopaque, chunk: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.content.appendSlice(std.testing.allocator, chunk) catch unreachable;
    }

    fn onReasoning(raw: *anyopaque, chunk: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.reasoning.appendSlice(std.testing.allocator, chunk) catch unreachable;
    }

    fn onToolInput(raw: *anyopaque, chunk: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.tool_input.appendSlice(std.testing.allocator, chunk) catch unreachable;
    }

    fn onToolStart(raw: *anyopaque, _: []const u8, _: []const u8, _: ?[]const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.tool_starts += 1;
    }
};

fn testBuildRequest(model: []const u8, messages: []const types.ChatMessage, tools: []const u8) stream_provider.BuildRequest {
    return .{
        .model = model,
        .serialized_tools = tools,
        .messages = messages,
        .tool_choice = .auto,
        .provider_options = .{},
        .max_output_tokens = 4096,
    };
}

test "direct request builders project native Anthropic and Responses shapes" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "Be precise." },
        .{ .role = .user, .content = "Read it." },
    };
    const tools = "[{\"type\":\"provider\",\"id\":\"gateway.perplexity_search\",\"name\":\"perplexity_search\",\"args\":{}},{\"type\":\"function\",\"name\":\"vision\",\"description\":\"Inspect image\",\"inputSchema\":{\"type\":\"object\"}},{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}}]";

    const anthropic = try agent_stream_provider.build(std.testing.allocator, testBuildRequest("anthropic-max/claude-opus-4-1", &messages, tools));
    defer std.testing.allocator.free(anthropic);
    try std.testing.expect(std.mem.find(u8, anthropic, "\"model\":\"claude-opus-4-1\"") != null);
    try std.testing.expect(std.mem.find(u8, anthropic, "\"input_schema\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.find(u8, anthropic, "gateway.perplexity_search") == null);
    try std.testing.expect(std.mem.find(u8, anthropic, "\"name\":\"vision\"") == null);
    try std.testing.expect(std.mem.find(u8, anthropic, claude_code_identity) != null);

    const responses = try agent_stream_provider.build(std.testing.allocator, testBuildRequest("openai-codex/gpt-5.3-codex", &messages, tools));
    defer std.testing.allocator.free(responses);
    try std.testing.expect(std.mem.find(u8, responses, "\"model\":\"gpt-5.3-codex\"") != null);
    try std.testing.expect(std.mem.find(u8, responses, "\"instructions\":\"Be precise.\"") != null);
    try std.testing.expect(std.mem.find(u8, responses, "\"parameters\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.find(u8, responses, "gateway.perplexity_search") == null);
    try std.testing.expect(std.mem.find(u8, responses, "\"name\":\"vision\"") == null);
    try std.testing.expect(std.mem.find(u8, responses, "\"store\":false") != null);
    try std.testing.expect(std.mem.find(u8, responses, "max_output_tokens") == null);

    try std.testing.expectError(error.AgentStreamProviderUnavailable, agent_stream_provider.build(std.testing.allocator, testBuildRequest("anthropic/claude", &messages, tools)));
}

test "Anthropic SSE normalizes text reasoning tool calls usage and finish" {
    const payload =
        "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hmm\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"read_file\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"a\\\"}\"}}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":9}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var capture: TestCapture = .{};
    defer capture.deinit(std.testing.allocator);
    var cancelled = std.atomic.Value(bool).init(false);
    var completion = try consumeDirectSse(std.testing.allocator, &reader, .anthropic, &capture, TestCapture.onContent, TestCapture.onToolStart, TestCapture.onReasoning, TestCapture.onToolInput, &cancelled, null);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqualStrings("hello", completion.content.?);
    try std.testing.expectEqualStrings("hmm", capture.reasoning.items);
    try std.testing.expectEqual(@as(usize, 1), capture.tool_starts);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 12), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 9), completion.usage.output_tokens);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

test "Responses SSE normalizes text reasoning tool calls usage and finish" {
    const payload =
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"plan\"}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"answer\"}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"item_1\",\"call_id\":\"call_1\",\"name\":\"shell\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"item_1\",\"delta\":\"{\\\"cmd\\\":\\\"pwd\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":21,\"output_tokens\":8}}}\n\n" ++
        "data: [DONE]\n\n";
    var reader = std.Io.Reader.fixed(payload);
    var capture: TestCapture = .{};
    defer capture.deinit(std.testing.allocator);
    var cancelled = std.atomic.Value(bool).init(false);
    var completion = try consumeDirectSse(std.testing.allocator, &reader, .codex, &capture, TestCapture.onContent, TestCapture.onToolStart, TestCapture.onReasoning, TestCapture.onToolInput, &cancelled, null);
    defer freeCompletion(std.testing.allocator, &completion);

    try std.testing.expectEqualStrings("answer", completion.content.?);
    try std.testing.expectEqualStrings("plan", capture.reasoning.items);
    try std.testing.expectEqualStrings("{\"cmd\":\"pwd\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 21), completion.usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 8), completion.usage.output_tokens);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
}

test "Codex account id is decoded from an access token" {
    const token = "header.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdF90ZXN0In19.signature";
    const account_id = (try codexAccountIdFromToken(std.testing.allocator, token)).?;
    defer std.testing.allocator.free(account_id);
    try std.testing.expectEqualStrings("acct_test", account_id);
    try std.testing.expect(!validHeaderValue("acct_test\r\nInjected: yes"));
}
