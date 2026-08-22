const std = @import("std");
const claude_code_store = @import("../core/auth/claude_code_store.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const host_target = @import("../core/hosts/target.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;
const generation_origin = "claude-code";
const max_line_bytes: usize = 1024 * 1024;
const stdout_poll_ms: i32 = 50;

pub const missing_cli_message = "fx needs the Claude Code CLI on PATH. Install Claude Code and run claude auth login.";

pub fn streamCompletion(alloc: Allocator, request: stream_provider.Request) !stream_provider.Result {
    if (comptime host_target.is_wasm) return error.ClaudeOAuthUnavailable;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const cli = (try claude_code_store.findCli(alloc)) orelse {
        return .{
            .status = .unauthorized,
            .err_body = try alloc.dupe(u8, missing_cli_message),
            .ownership = .owned,
        };
    };
    defer alloc.free(cli);

    var prompt = try extractPrompt(alloc, request.payload);
    defer prompt.deinit(alloc);

    var argv_store: std.ArrayList([]const u8) = .empty;
    defer argv_store.deinit(alloc);
    const claude_tools = claude_code_store.claudeCodeToolsEnabled();
    try appendSpawnArgs(alloc, &argv_store, cli, request.model, claude_tools);

    debug_trace.logf("auth", "Claude Agent SDK spawn model={s} claude_tools={}", .{ request.model, claude_tools });
    var child = std.process.spawn(io_mod.getIo(), .{
        .argv = argv_store.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .pgid = 0,
    }) catch |err| {
        debug_trace.logf("auth", "Claude Agent SDK spawn failed err={s}", .{@errorName(err)});
        return .{
            .status = .bad_gateway,
            .err_body = try alloc.dupe(u8, "fx could not start the Claude Code CLI"),
            .ownership = .owned,
        };
    };
    var child_owned = true;
    errdefer if (child_owned) {
        killChild(&child);
        reapChild(&child);
    };

    var stdin = child.stdin orelse return error.ClaudeAgentSdkSpawnFailed;
    child.stdin = null;
    var stdout = child.stdout orelse return error.ClaudeAgentSdkSpawnFailed;
    child.stdout = null;

    const user_line = try encodeUserMessage(alloc, prompt.user);
    defer secret.zeroAndFree(alloc, user_line);

    var consumed = consumeCliStream(
        alloc,
        stdin,
        stdout,
        request.callback_ctx,
        request.on_content_chunk,
        request.on_tool_start,
        request.on_reasoning_chunk,
        request.cancel_flag,
        request.cooperative_pulse,
        request.content_capture_limit,
        claude_tools,
        prompt.tools_json,
        user_line,
        request.delivery,
    ) catch |err| {
        stdin.close(io_mod.getIo());
        stdout.close(io_mod.getIo());
        killChild(&child);
        reapChild(&child);
        child_owned = false;
        if (err == error.Cancelled or request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        return err;
    };

    stdin.close(io_mod.getIo());
    stdout.close(io_mod.getIo());
    reapChild(&child);
    child_owned = false;

    if (request.cancel_flag.load(.seq_cst)) {
        consumed.deinit(alloc);
        return error.Cancelled;
    }
    if (consumed.failed) {
        const err_body = consumed.err_body orelse try alloc.dupe(u8, "Claude Code Agent SDK turn failed");
        consumed.err_body = null;
        consumed.deinit(alloc);
        return .{
            .status = .bad_gateway,
            .err_body = err_body,
            .generation_origin = generation_origin,
            .ownership = .owned,
        };
    }
    if (consumed.err_body) |body| alloc.free(body);
    return .{
        .status = .ok,
        .completion = consumed.completion,
        .generation_origin = generation_origin,
        .ownership = .owned,
    };
}

const Prompt = struct {
    user: []u8,
    tools_json: []u8,

    fn deinit(self: *Prompt, alloc: Allocator) void {
        alloc.free(self.user);
        alloc.free(self.tools_json);
        self.* = undefined;
    }
};

const Handshake = struct {
    init_acked: bool = false,
    system_init: bool = false,
    tools_listed: bool = false,
    mcp_initialized: bool = false,

    fn ready(self: Handshake, claude_tools: bool) bool {
        if (claude_tools) return self.init_acked or self.system_init;
        return self.tools_listed or self.system_init;
    }
};

fn appendSpawnArgs(
    alloc: Allocator,
    argv: *std.ArrayList([]const u8),
    cli: []const u8,
    model: []const u8,
    claude_tools: bool,
) !void {
    try argv.appendSlice(alloc, &.{
        cli,
        "-p",
        "--output-format",
        "stream-json",
        "--input-format",
        "stream-json",
        "--include-partial-messages",
        "--verbose",
        "--permission-prompt-tool",
        "stdio",
        "--permission-mode",
        "bypassPermissions",
        "--allow-dangerously-skip-permissions",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--no-chrome",
        "--model",
        model,
    });
    if (!claude_tools) {
        try argv.appendSlice(alloc, &.{
            "--tools=",
            "--setting-sources=",
        });
    }
}

const ConsumedStream = struct {
    completion: types.GatewayCompletion = .{},
    err_body: ?[]u8 = null,
    failed: bool = false,

    fn deinit(self: *ConsumedStream, alloc: Allocator) void {
        if (self.completion.content) |content| alloc.free(@constCast(content));
        if (self.completion.generation_id) |id| alloc.free(@constCast(id));
        types.freeToolCallSlice(alloc, @constCast(self.completion.tool_calls));
        if (self.err_body) |body| alloc.free(body);
        self.* = undefined;
    }
};

fn extractPrompt(alloc: Allocator, payload: []const u8) !Prompt {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, payload, .{}) catch
        return error.InvalidAnthropicClaudeRequest;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAnthropicClaudeRequest;
    const user = try conversationText(alloc, parsed.value.object.get("messages"));
    errdefer alloc.free(user);
    const tools_json = try extractToolsJson(alloc, parsed.value.object.get("tools"));
    return .{ .user = user, .tools_json = tools_json };
}

fn extractToolsJson(alloc: Allocator, tools_value: ?std.json.Value) ![]u8 {
    const tools = tools_value orelse return alloc.dupe(u8, "[]");
    if (tools != .array) return alloc.dupe(u8, "[]");
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(tools, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn conversationText(alloc: Allocator, messages_value: ?std.json.Value) ![]u8 {
    const messages = messages_value orelse return error.InvalidAnthropicClaudeRequest;
    if (messages != .array or messages.array.items.len == 0) return error.InvalidAnthropicClaudeRequest;

    var user_count: usize = 0;
    var other_count: usize = 0;
    for (messages.array.items) |message| {
        if (message != .object) continue;
        const role = stringField(message.object, "role") orelse continue;
        if (std.mem.eql(u8, role, "user")) {
            user_count += 1;
        } else if (std.mem.eql(u8, role, "assistant") or std.mem.eql(u8, role, "tool")) {
            other_count += 1;
        }
    }
    if (user_count == 0) return error.InvalidAnthropicClaudeRequest;
    if (user_count == 1 and other_count == 0) return lastUserText(alloc, messages_value);

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var first = true;
    for (messages.array.items) |message| {
        if (message != .object) continue;
        const role = stringField(message.object, "role") orelse continue;
        const label: []const u8 = if (std.mem.eql(u8, role, "user"))
            "User"
        else if (std.mem.eql(u8, role, "assistant"))
            "Assistant"
        else if (std.mem.eql(u8, role, "tool"))
            "Tool"
        else
            continue;
        const text = try messagePlainText(alloc, message.object);
        defer alloc.free(text);
        if (text.len == 0) continue;
        if (!first) try out.writer.writeAll("\n\n");
        try out.writer.writeAll(label);
        try out.writer.writeAll(": ");
        try out.writer.writeAll(text);
        first = false;
    }
    if (out.written().len == 0) return error.InvalidAnthropicClaudeRequest;
    return out.toOwnedSlice();
}

fn lastUserText(alloc: Allocator, messages_value: ?std.json.Value) ![]u8 {
    const messages = messages_value orelse return error.InvalidAnthropicClaudeRequest;
    if (messages != .array or messages.array.items.len == 0) return error.InvalidAnthropicClaudeRequest;
    var index = messages.array.items.len;
    while (index > 0) {
        index -= 1;
        const message = messages.array.items[index];
        if (message != .object) continue;
        const role = stringField(message.object, "role") orelse continue;
        if (!std.mem.eql(u8, role, "user")) continue;
        return messagePlainText(alloc, message.object);
    }
    return error.InvalidAnthropicClaudeRequest;
}

fn messagePlainText(alloc: Allocator, message: std.json.ObjectMap) ![]u8 {
    const content = message.get("content") orelse return alloc.dupe(u8, "");
    if (content == .string) return alloc.dupe(u8, content.string);
    if (content != .array) return alloc.dupe(u8, "");
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (content.array.items) |part| {
        if (part != .object) continue;
        const part_type = stringField(part.object, "type") orelse continue;
        if (std.mem.eql(u8, part_type, "text")) {
            const text = stringField(part.object, "text") orelse continue;
            if (text.len == 0) continue;
            if (out.written().len > 0) try out.writer.writeAll("\n");
            try out.writer.writeAll(text);
        } else if (std.mem.eql(u8, part_type, "tool_result")) {
            const text = stringField(part.object, "content") orelse continue;
            if (text.len == 0) continue;
            if (out.written().len > 0) try out.writer.writeAll("\n");
            try out.writer.writeAll(text);
        } else if (std.mem.eql(u8, part_type, "tool_use")) {
            const name = stringField(part.object, "name") orelse continue;
            if (out.written().len > 0) try out.writer.writeAll("\n");
            try out.writer.writeAll("[tool ");
            try out.writer.writeAll(name);
            try out.writer.writeAll("]");
        }
    }
    return out.toOwnedSlice();
}

fn encodeUserMessage(alloc: Allocator, user: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"type\":\"user\",\"parent_tool_use_id\":null,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(user, .{}, &out.writer);
    try out.writer.writeAll("}]}}\n");
    return out.toOwnedSlice();
}

fn encodeControlAllow(alloc: Allocator, request_id: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":");
    try std.json.Stringify.value(request_id, .{}, &out.writer);
    try out.writer.writeAll(",\"response\":{\"behavior\":\"allow\"}}}\n");
    return out.toOwnedSlice();
}

fn encodeInitialize(alloc: Allocator, claude_tools: bool) ![]u8 {
    if (claude_tools) {
        return alloc.dupe(
            u8,
            "{\"type\":\"control_request\",\"request_id\":\"fx-init-1\",\"request\":{\"subtype\":\"initialize\"}}\n",
        );
    }
    return alloc.dupe(
        u8,
        "{\"type\":\"control_request\",\"request_id\":\"fx-init-1\",\"request\":{\"subtype\":\"initialize\",\"sdkMcpServers\":[\"fx\"]}}\n",
    );
}

fn encodeMcpControlResult(alloc: Allocator, request_id: []const u8, rpc_id: std.json.Value, result_json: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":");
    try std.json.Stringify.value(request_id, .{}, &out.writer);
    try out.writer.writeAll(",\"response\":{\"mcp_response\":{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(rpc_id, .{}, &out.writer);
    try out.writer.writeAll(",\"result\":");
    try out.writer.writeAll(result_json);
    try out.writer.writeAll("}}}}\n");
    return out.toOwnedSlice();
}

fn consumeCliStream(
    alloc: Allocator,
    stdin: std.Io.File,
    stdout: std.Io.File,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    cancel_flag: *std.atomic.Value(bool),
    cooperative_pulse: ?stream_provider.CooperativePulse,
    content_capture_limit: ?usize,
    claude_tools: bool,
    tools_json: []const u8,
    user_line: []const u8,
    delivery: *stream_provider.DeliveryCertainty,
) !ConsumedStream {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var host_tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer host_tool_calls.deinit(alloc);
    errdefer for (host_tool_calls.items) |call| types.freeToolCall(alloc, call);
    var saw_text_delta = false;
    var done = false;
    var is_error = false;
    var intercept_idle: u8 = 0;
    var handshake_polls: u32 = 0;
    var user_sent = false;
    var handshake = Handshake{};
    var generation_id: ?[]u8 = null;
    errdefer if (generation_id) |id| alloc.free(id);
    var err_body: ?[]u8 = null;
    errdefer if (err_body) |body| alloc.free(body);
    var read_buf: [8192]u8 = undefined;

    const init_line = try encodeInitialize(alloc, claude_tools);
    defer alloc.free(init_line);
    stdin.writeStreamingAll(io_mod.getIo(), init_line) catch |err| {
        debug_trace.logf("auth", "Claude Agent SDK initialize failed err={s}", .{@errorName(err)});
        return error.ClaudeAgentSdkWriteFailed;
    };

    const handshake_timeout_polls: u32 = if (claude_tools) 100 else 300;

    while (!done) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (!user_sent and (handshake.ready(claude_tools) or handshake_polls >= handshake_timeout_polls)) {
            if (!handshake.ready(claude_tools)) {
                debug_trace.logf(
                    "auth",
                    "Claude Agent SDK handshake timeout init_acked={} system_init={} tools_listed={}",
                    .{ handshake.init_acked, handshake.system_init, handshake.tools_listed },
                );
            }
            delivery.markPossiblySent();
            stdin.writeStreamingAll(io_mod.getIo(), user_line) catch |err| {
                debug_trace.logf("auth", "Claude Agent SDK stdin write failed err={s}", .{@errorName(err)});
                return error.ClaudeAgentSdkWriteFailed;
            };
            user_sent = true;
            debug_trace.logf(
                "auth",
                "Claude Agent SDK user sent init_acked={} system_init={} tools_listed={}",
                .{ handshake.init_acked, handshake.system_init, handshake.tools_listed },
            );
        }
        if (!try stdoutReady(stdout.handle, stdout_poll_ms)) {
            if (cooperative_pulse) |pulse| try pulse.pulse();
            if (!user_sent) handshake_polls += 1;
            if (!claude_tools and host_tool_calls.items.len > 0) {
                intercept_idle += 1;
                if (intercept_idle >= 4) break;
            }
            continue;
        }
        intercept_idle = 0;
        const n = stdout.readStreaming(io_mod.getIo(), &.{read_buf[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        for (read_buf[0..n]) |byte| {
            if (byte == '\n') {
                if (line.items.len > 0) {
                    const outcome = try applyStreamJsonLine(
                        alloc,
                        line.items,
                        stdin,
                        callback_ctx,
                        on_content_chunk,
                        on_tool_start,
                        on_reasoning_chunk,
                        &content,
                        &saw_text_delta,
                        &generation_id,
                        &err_body,
                        content_capture_limit,
                        claude_tools,
                        tools_json,
                        &host_tool_calls,
                        &handshake,
                    );
                    line.clearRetainingCapacity();
                    switch (outcome) {
                        .more => {},
                        .tools => {},
                        .done => done = true,
                        .failed => {
                            is_error = true;
                            done = true;
                        },
                    }
                }
            } else {
                if (line.items.len >= max_line_bytes) return error.ClaudeAgentSdkLineTooLarge;
                try line.append(alloc, byte);
            }
            if (done) break;
        }
    }
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (!done and host_tool_calls.items.len == 0) return error.ClaudeAgentSdkStreamIncomplete;

    const owned_tools = try host_tool_calls.toOwnedSlice(alloc);
    errdefer types.freeToolCallSlice(alloc, owned_tools);
    host_tool_calls = .empty;
    return .{
        .completion = .{
            .content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null,
            .tool_calls = owned_tools,
            .generation_id = generation_id,
            .finish_reason = if (is_error)
                .provider_error
            else if (owned_tools.len > 0)
                .tool_calls
            else
                .stop,
        },
        .err_body = err_body,
        .failed = is_error,
    };
}

const LineOutcome = enum { more, done, failed, tools };

fn applyStreamJsonLine(
    alloc: Allocator,
    line: []const u8,
    stdin: ?std.Io.File,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    content: *std.ArrayList(u8),
    saw_text_delta: *bool,
    generation_id: *?[]u8,
    err_body: *?[]u8,
    content_capture_limit: ?usize,
    claude_tools: bool,
    tools_json: []const u8,
    host_tool_calls: *std.ArrayList(types.ToolCall),
    handshake: ?*Handshake,
) !LineOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return .more;
    defer parsed.deinit();
    if (parsed.value != .object) return .more;
    const object = parsed.value.object;
    const event_type = stringField(object, "type") orelse return .more;
    if (std.mem.eql(u8, event_type, "control_response") or std.mem.eql(u8, event_type, "sdk_control_response")) {
        if (handshake) |hs| {
            if (controlResponseRequestId(object)) |id| {
                if (std.mem.eql(u8, id, "fx-init-1")) hs.init_acked = true;
            }
        }
        return .more;
    }
    if (std.mem.eql(u8, event_type, "control_request") or std.mem.eql(u8, event_type, "sdk_control_request")) {
        return handleControlRequest(
            alloc,
            stdin,
            object,
            callback_ctx,
            on_tool_start,
            claude_tools,
            tools_json,
            host_tool_calls,
            handshake,
        );
    }
    if (std.mem.eql(u8, event_type, "system")) {
        try captureSessionId(alloc, object, generation_id);
        const subtype = stringField(object, "subtype") orelse "";
        if (handshake) |hs| {
            if (std.mem.eql(u8, subtype, "init")) hs.system_init = true;
        }
        return .more;
    }
    if (std.mem.eql(u8, event_type, "result")) {
        try captureSessionId(alloc, object, generation_id);
        const subtype = stringField(object, "subtype") orelse "success";
        const failed = if (object.get("is_error")) |flag|
            flag == .bool and flag.bool
        else
            !(std.mem.eql(u8, subtype, "success") or std.mem.eql(u8, subtype, "error_max_turns"));
        if (!failed and !saw_text_delta.*) {
            if (stringField(object, "result")) |text| {
                if (text.len > 0) {
                    on_content_chunk(callback_ctx, text);
                    try appendCaptured(alloc, content, text, content_capture_limit);
                }
            }
        }
        if (failed) {
            const text = stringField(object, "result") orelse stringField(object, "error") orelse "Claude Code Agent SDK turn failed";
            if (err_body.*) |old| alloc.free(old);
            err_body.* = try alloc.dupe(u8, text);
            return .failed;
        }
        return .done;
    }
    if (std.mem.eql(u8, event_type, "stream_event")) {
        const event = object.get("event") orelse return .more;
        if (event != .object) return .more;
        try applyApiStreamEvent(
            alloc,
            event.object,
            callback_ctx,
            on_content_chunk,
            on_tool_start,
            on_reasoning_chunk,
            content,
            saw_text_delta,
            generation_id,
            content_capture_limit,
        );
        return .more;
    }
    if (std.mem.eql(u8, event_type, "assistant") and !saw_text_delta.*) {
        const message = object.get("message") orelse return .more;
        if (message != .object) return .more;
        try captureAssistantText(alloc, message.object, callback_ctx, on_content_chunk, on_tool_start, content, content_capture_limit);
        return .more;
    }
    return .more;
}

fn handleControlRequest(
    alloc: Allocator,
    stdin: ?std.Io.File,
    object: std.json.ObjectMap,
    callback_ctx: *anyopaque,
    on_tool_start: ?stream_provider.ToolStartCallback,
    claude_tools: bool,
    tools_json: []const u8,
    host_tool_calls: *std.ArrayList(types.ToolCall),
    handshake: ?*Handshake,
) !LineOutcome {
    const request = object.get("request");
    const request_object = if (request) |value| if (value == .object) value.object else null else null;
    const subtype = if (request_object) |req| stringField(req, "subtype") else stringField(object, "subtype");
    if (!claude_tools) {
        if (subtype) |kind| {
            if (std.mem.eql(u8, kind, "mcp_message")) {
                if (try interceptMcpToolCall(alloc, request_object, callback_ctx, on_tool_start, host_tool_calls))
                    return .tools;
                try answerMcpMessage(alloc, stdin, object, request_object, tools_json, handshake);
                return .more;
            }
            if (std.mem.eql(u8, kind, "can_use_tool")) {
                if (try interceptHostTool(alloc, object, request_object, callback_ctx, on_tool_start, host_tool_calls))
                    return .tools;
            }
        }
    }
    try answerControlAllow(alloc, stdin, object);
    return .more;
}

fn answerControlAllow(alloc: Allocator, stdin: ?std.Io.File, object: std.json.ObjectMap) !void {
    const dest = stdin orelse return;
    const request_id = controlRequestId(object) orelse return;
    const line = try encodeControlAllow(alloc, request_id);
    defer alloc.free(line);
    dest.writeStreamingAll(io_mod.getIo(), line) catch |err| {
        debug_trace.logf("auth", "Claude Agent SDK control reply failed err={s}", .{@errorName(err)});
        return error.ClaudeAgentSdkWriteFailed;
    };
}

fn answerMcpMessage(
    alloc: Allocator,
    stdin: ?std.Io.File,
    object: std.json.ObjectMap,
    request_object: ?std.json.ObjectMap,
    tools_json: []const u8,
    handshake: ?*Handshake,
) !void {
    const dest = stdin orelse return;
    const request_id = controlRequestId(object) orelse return;
    const req = request_object orelse return;
    const message = req.get("message") orelse return;
    if (message != .object) return;
    const method = stringField(message.object, "method") orelse return;
    const rpc_id = message.object.get("id") orelse {
        try answerControlAllow(alloc, dest, object);
        return;
    };
    const result_json = if (std.mem.eql(u8, method, "initialize"))
        "{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"fx\",\"version\":\"0.1\"}}"
    else if (std.mem.eql(u8, method, "tools/list"))
        try mcpToolsListJson(alloc, tools_json)
    else if (std.mem.eql(u8, method, "tools/call"))
        "{\"content\":[{\"type\":\"text\",\"text\":\"handed to fx\"}]}"
    else
        return;
    const owned_list = std.mem.eql(u8, method, "tools/list");
    defer if (owned_list) alloc.free(result_json);
    const line = try encodeMcpControlResult(alloc, request_id, rpc_id, result_json);
    defer alloc.free(line);
    dest.writeStreamingAll(io_mod.getIo(), line) catch |err| {
        debug_trace.logf("auth", "Claude Agent SDK MCP reply failed err={s}", .{@errorName(err)});
        return error.ClaudeAgentSdkWriteFailed;
    };
    if (handshake) |hs| {
        if (std.mem.eql(u8, method, "initialize")) hs.mcp_initialized = true;
        if (std.mem.eql(u8, method, "tools/list")) hs.tools_listed = true;
    }
}

fn interceptMcpToolCall(
    alloc: Allocator,
    request_object: ?std.json.ObjectMap,
    callback_ctx: *anyopaque,
    on_tool_start: ?stream_provider.ToolStartCallback,
    host_tool_calls: *std.ArrayList(types.ToolCall),
) !bool {
    const req = request_object orelse return false;
    const message = req.get("message") orelse return false;
    if (message != .object) return false;
    const method = stringField(message.object, "method") orelse return false;
    if (!std.mem.eql(u8, method, "tools/call")) return false;
    const params = message.object.get("params") orelse return false;
    if (params != .object) return false;
    const name = stringField(params.object, "name") orelse return false;
    const fx_name = hostToolName(name) orelse name;
    const id = stringField(message.object, "id") orelse fx_name;
    const arguments = if (params.object.get("arguments")) |value|
        try stringifyJsonValue(alloc, value)
    else
        try alloc.dupe(u8, "{}");
    errdefer alloc.free(arguments);
    try appendHostToolCall(alloc, host_tool_calls, id, fx_name, arguments, callback_ctx, on_tool_start);
    return true;
}

fn interceptHostTool(
    alloc: Allocator,
    object: std.json.ObjectMap,
    request_object: ?std.json.ObjectMap,
    callback_ctx: *anyopaque,
    on_tool_start: ?stream_provider.ToolStartCallback,
    host_tool_calls: *std.ArrayList(types.ToolCall),
) !bool {
    const req = request_object orelse object;
    const name = stringField(req, "tool_name") orelse return false;
    const fx_name = hostToolName(name) orelse return false;
    const id = stringField(req, "tool_use_id") orelse fx_name;
    const arguments = if (req.get("input")) |value|
        try stringifyJsonValue(alloc, value)
    else
        try alloc.dupe(u8, "{}");
    errdefer alloc.free(arguments);
    try appendHostToolCall(alloc, host_tool_calls, id, fx_name, arguments, callback_ctx, on_tool_start);
    return true;
}

fn appendHostToolCall(
    alloc: Allocator,
    host_tool_calls: *std.ArrayList(types.ToolCall),
    id: []const u8,
    name: []const u8,
    arguments: []u8,
    callback_ctx: *anyopaque,
    on_tool_start: ?stream_provider.ToolStartCallback,
) !void {
    for (host_tool_calls.items) |existing| {
        if (std.mem.eql(u8, existing.id, id)) {
            alloc.free(arguments);
            return;
        }
    }
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    try host_tool_calls.append(alloc, .{
        .id = owned_id,
        .name = owned_name,
        .arguments_json = arguments,
    });
    if (on_tool_start) |callback| callback(callback_ctx, owned_id, owned_name, null);
}

fn hostToolName(name: []const u8) ?[]const u8 {
    const prefix = "mcp__fx__";
    if (std.mem.startsWith(u8, name, prefix)) return name[prefix.len..];
    if (std.mem.eql(u8, name, "Read")) return "read_file";
    if (std.mem.eql(u8, name, "Write")) return "write_file";
    if (std.mem.eql(u8, name, "Edit") or std.mem.eql(u8, name, "StrReplace")) return "edit_file";
    if (std.mem.eql(u8, name, "Bash")) return "terminal";
    if (std.mem.eql(u8, name, "Grep")) return "grep_files";
    if (std.mem.eql(u8, name, "Glob")) return "glob_files";
    if (std.mem.eql(u8, name, "LS")) return "list_files";
    if (std.mem.eql(u8, name, "WebFetch")) return "web_fetch";
    if (std.mem.eql(u8, name, "WebSearch")) return "web_search";
    return name;
}

fn stringifyJsonValue(alloc: Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn mcpToolsListJson(alloc: Allocator, tools_json: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, tools_json, .{}) catch
        return alloc.dupe(u8, "{\"tools\":[]}");
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("{\"tools\":[");
    var first = true;
    if (parsed.value == .array) {
        for (parsed.value.array.items) |tool| {
            if (tool != .object) continue;
            const name = stringField(tool.object, "name") orelse continue;
            if (!first) try out.writer.writeByte(',');
            first = false;
            try out.writer.writeAll("{\"name\":");
            try std.json.Stringify.value(name, .{}, &out.writer);
            if (stringField(tool.object, "description")) |description| {
                try out.writer.writeAll(",\"description\":");
                try std.json.Stringify.value(description, .{}, &out.writer);
            }
            const schema = tool.object.get("input_schema") orelse tool.object.get("inputSchema");
            if (schema) |value| {
                try out.writer.writeAll(",\"inputSchema\":");
                try std.json.Stringify.value(value, .{}, &out.writer);
            }
            try out.writer.writeByte('}');
        }
    }
    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn controlRequestId(object: std.json.ObjectMap) ?[]const u8 {
    if (stringField(object, "request_id")) |id| return id;
    const request = object.get("request") orelse return null;
    if (request != .object) return null;
    return stringField(request.object, "request_id");
}

fn controlResponseRequestId(object: std.json.ObjectMap) ?[]const u8 {
    if (stringField(object, "request_id")) |id| return id;
    const response = object.get("response") orelse return null;
    if (response != .object) return null;
    return stringField(response.object, "request_id");
}

fn captureSessionId(alloc: Allocator, object: std.json.ObjectMap, generation_id: *?[]u8) !void {
    const id = stringField(object, "session_id") orelse return;
    if (id.len == 0) return;
    if (generation_id.*) |old| alloc.free(old);
    generation_id.* = try alloc.dupe(u8, id);
}

fn applyApiStreamEvent(
    alloc: Allocator,
    event: std.json.ObjectMap,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    on_reasoning_chunk: ?stream_provider.StreamCallback,
    content: *std.ArrayList(u8),
    saw_text_delta: *bool,
    generation_id: *?[]u8,
    content_capture_limit: ?usize,
) !void {
    const event_type = stringField(event, "type") orelse return;
    if (std.mem.eql(u8, event_type, "message_start")) {
        if (event.get("message")) |message| {
            if (message == .object) {
                if (stringField(message.object, "id")) |id| {
                    if (generation_id.* == null) generation_id.* = try alloc.dupe(u8, id);
                }
            }
        }
        return;
    }
    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const block = event.get("content_block") orelse return;
        if (block != .object) return;
        if (std.mem.eql(u8, stringField(block.object, "type") orelse "", "tool_use")) {
            const name = stringField(block.object, "name") orelse return;
            const tool_id = stringField(block.object, "id") orelse name;
            if (on_tool_start) |callback| callback(callback_ctx, tool_id, name, null);
        }
        return;
    }
    if (!std.mem.eql(u8, event_type, "content_block_delta")) return;
    const delta = event.get("delta") orelse return;
    if (delta != .object) return;
    const delta_type = stringField(delta.object, "type") orelse return;
    if (std.mem.eql(u8, delta_type, "text_delta")) {
        const text = stringField(delta.object, "text") orelse return;
        saw_text_delta.* = true;
        on_content_chunk(callback_ctx, text);
        try appendCaptured(alloc, content, text, content_capture_limit);
    } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
        const thinking = stringField(delta.object, "thinking") orelse return;
        if (on_reasoning_chunk) |callback| callback(callback_ctx, thinking);
    }
}

fn captureAssistantText(
    alloc: Allocator,
    message: std.json.ObjectMap,
    callback_ctx: *anyopaque,
    on_content_chunk: stream_provider.StreamCallback,
    on_tool_start: ?stream_provider.ToolStartCallback,
    content: *std.ArrayList(u8),
    content_capture_limit: ?usize,
) !void {
    const value = message.get("content") orelse return;
    if (value == .string) {
        if (value.string.len == 0) return;
        on_content_chunk(callback_ctx, value.string);
        try appendCaptured(alloc, content, value.string, content_capture_limit);
        return;
    }
    if (value != .array) return;
    for (value.array.items) |part| {
        if (part != .object) continue;
        const part_type = stringField(part.object, "type") orelse continue;
        if (std.mem.eql(u8, part_type, "tool_use")) {
            const name = stringField(part.object, "name") orelse continue;
            const tool_id = stringField(part.object, "id") orelse name;
            if (on_tool_start) |callback| callback(callback_ctx, tool_id, name, null);
            continue;
        }
        if (!std.mem.eql(u8, part_type, "text")) continue;
        const text = stringField(part.object, "text") orelse continue;
        if (text.len == 0) continue;
        on_content_chunk(callback_ctx, text);
        try appendCaptured(alloc, content, text, content_capture_limit);
    }
}

fn appendCaptured(alloc: Allocator, content: *std.ArrayList(u8), text: []const u8, limit: ?usize) !void {
    const remaining = if (limit) |max| std.math.sub(usize, max, content.items.len) catch 0 else text.len;
    if (remaining == 0) return;
    try content.appendSlice(alloc, text[0..@min(text.len, remaining)]);
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn stdoutReady(handle: std.posix.fd_t, timeout_ms: i32) !bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, timeout_ms);
    if (ready == 0) return false;
    if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
        return ready > 0;
    }
    return (fds[0].revents & std.posix.POLL.IN) != 0;
}

fn killChild(child: *std.process.Child) void {
    if (child.id) |pid| {
        std.posix.kill(pid, std.posix.SIG.INT) catch {};
    }
}

fn reapChild(child: *std.process.Child) void {
    _ = child.wait(io_mod.getIo()) catch {};
}

test "Claude Agent SDK flattens multi-turn conversation text" {
    const alloc = std.testing.allocator;
    var prompt = try extractPrompt(
        alloc,
        "{\"system\":\"Be brief.\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"first\"}]},{\"role\":\"assistant\",\"content\":\"ok\"},{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"second\"}]}]}",
    );
    defer prompt.deinit(alloc);
    try std.testing.expect(std.mem.find(u8, prompt.user, "first") != null);
    try std.testing.expect(std.mem.find(u8, prompt.user, "second") != null);
    try std.testing.expect(std.mem.find(u8, prompt.user, "User:") != null);
}

test "Claude Agent SDK keeps a single user prompt unprefixed" {
    const alloc = std.testing.allocator;
    var prompt = try extractPrompt(
        alloc,
        "{\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"pong\"}]}]}",
    );
    defer prompt.deinit(alloc);
    try std.testing.expectEqualStrings("pong", prompt.user);
}

test "Claude Agent SDK stream-json maps text deltas and result" {
    const alloc = std.testing.allocator;
    const Sink = struct {
        text: std.ArrayList(u8) = .empty,
        fn onChunk(raw: *anyopaque, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.text.appendSlice(std.testing.allocator, chunk) catch {};
        }
    };
    var sink = Sink{};
    defer sink.text.deinit(alloc);
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var saw = false;
    var generation_id: ?[]u8 = null;
    defer if (generation_id) |id| alloc.free(id);
    var err_body: ?[]u8 = null;
    defer if (err_body) |body| alloc.free(body);
    var host_tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer host_tool_calls.deinit(alloc);

    const delta = try applyStreamJsonLine(
        alloc,
        "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}}",
        null,
        @ptrCast(&sink),
        Sink.onChunk,
        null,
        null,
        &content,
        &saw,
        &generation_id,
        &err_body,
        null,
        true,
        "[]",
        &host_tool_calls,
        null,
    );
    try std.testing.expectEqual(LineOutcome.more, delta);
    const done = try applyStreamJsonLine(
        alloc,
        "{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"sess_1\",\"result\":\"Hello\"}",
        null,
        @ptrCast(&sink),
        Sink.onChunk,
        null,
        null,
        &content,
        &saw,
        &generation_id,
        &err_body,
        null,
        true,
        "[]",
        &host_tool_calls,
        null,
    );
    try std.testing.expectEqual(LineOutcome.done, done);
    try std.testing.expectEqualStrings("Hel", sink.text.items);
    try std.testing.expectEqualStrings("Hel", content.items);
    try std.testing.expectEqualStrings("sess_1", generation_id.?);
}

test "Claude Agent SDK control allow is stream-json" {
    const alloc = std.testing.allocator;
    const line = try encodeControlAllow(alloc, "req_1");
    defer alloc.free(line);
    try std.testing.expect(std.mem.find(u8, line, "\"type\":\"control_response\"") != null);
    try std.testing.expect(std.mem.find(u8, line, "\"request_id\":\"req_1\"") != null);
    try std.testing.expect(std.mem.find(u8, line, "\"behavior\":\"allow\"") != null);
    try std.testing.expect(line[line.len - 1] == '\n');
}

test "Claude host tools map Claude names and MCP prefixes" {
    try std.testing.expectEqualStrings("read_file", hostToolName("Read").?);
    try std.testing.expectEqualStrings("terminal", hostToolName("Bash").?);
    try std.testing.expectEqualStrings("read_file", hostToolName("mcp__fx__read_file").?);
    try std.testing.expectEqualStrings("web_search", hostToolName("web_search").?);
}

test "Claude host tools list uses fx schemas" {
    const alloc = std.testing.allocator;
    const json = try mcpToolsListJson(
        alloc,
        "[{\"name\":\"read_file\",\"description\":\"Read\",\"input_schema\":{\"type\":\"object\"}}]",
    );
    defer alloc.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"name\":\"read_file\"") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"inputSchema\"") != null);
}

test "Claude Agent SDK spawn asks for stdio permission prompts" {
    const alloc = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try appendSpawnArgs(alloc, &argv, "/bin/claude", "claude-opus-5", true);
    try std.testing.expect(containsArg(argv.items, "--permission-prompt-tool"));
    try std.testing.expect(containsArg(argv.items, "stdio"));
    try std.testing.expect(containsArg(argv.items, "--allow-dangerously-skip-permissions"));
    try std.testing.expect(containsArg(argv.items, "--strict-mcp-config"));
    try std.testing.expect(containsArg(argv.items, "--disable-slash-commands"));
    try std.testing.expect(!containsArg(argv.items, "--replay-user-messages"));
    try std.testing.expect(!containsArg(argv.items, "--tools="));
}

test "Claude Agent SDK spawn isolates host tools when Claude tools are off" {
    const alloc = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try appendSpawnArgs(alloc, &argv, "/bin/claude", "claude-opus-5", false);
    try std.testing.expect(containsArg(argv.items, "--tools="));
    try std.testing.expect(containsArg(argv.items, "--setting-sources="));
    try std.testing.expect(containsArg(argv.items, "--disable-slash-commands"));
    try std.testing.expect(containsArg(argv.items, "--permission-prompt-tool"));
}

test "Claude Agent SDK initialize includes fx MCP only when tools are off" {
    const alloc = std.testing.allocator;
    const with_fx = try encodeInitialize(alloc, false);
    defer alloc.free(with_fx);
    try std.testing.expect(std.mem.find(u8, with_fx, "sdkMcpServers") != null);
    const without_fx = try encodeInitialize(alloc, true);
    defer alloc.free(without_fx);
    try std.testing.expect(std.mem.find(u8, without_fx, "sdkMcpServers") == null);
}

test "Claude Agent SDK handshake is ready after system init when tools stay on" {
    var handshake = Handshake{ .system_init = true };
    try std.testing.expect(handshake.ready(true));
    try std.testing.expect(handshake.ready(false));
    handshake = .{ .init_acked = true, .mcp_initialized = true };
    try std.testing.expect(handshake.ready(true));
    try std.testing.expect(!handshake.ready(false));
    handshake.tools_listed = true;
    try std.testing.expect(handshake.ready(false));
}

test "Claude Agent SDK acks initialize control_response" {
    const alloc = std.testing.allocator;
    const Sink = struct {
        fn onChunk(_: *anyopaque, _: []const u8) void {}
    };
    var sink: u8 = 0;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(alloc);
    var saw = false;
    var generation_id: ?[]u8 = null;
    defer if (generation_id) |id| alloc.free(id);
    var err_body: ?[]u8 = null;
    defer if (err_body) |body| alloc.free(body);
    var host_tool_calls: std.ArrayList(types.ToolCall) = .empty;
    defer host_tool_calls.deinit(alloc);
    var handshake = Handshake{};
    const outcome = try applyStreamJsonLine(
        alloc,
        "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"fx-init-1\",\"response\":{}}}",
        null,
        @ptrCast(&sink),
        Sink.onChunk,
        null,
        null,
        &content,
        &saw,
        &generation_id,
        &err_body,
        null,
        true,
        "[]",
        &host_tool_calls,
        &handshake,
    );
    try std.testing.expectEqual(LineOutcome.more, outcome);
    try std.testing.expect(handshake.init_acked);
}

fn containsArg(argv: []const []const u8, wanted: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, wanted)) return true;
    }
    return false;
}
