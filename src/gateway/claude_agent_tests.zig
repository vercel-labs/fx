//! Claude Code mode fixtures: history seeding, the continue prompt, the tool
//! stub that never runs a tool, and stream-json translation (D165-D167).
const std = @import("std");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const model_provider = @import("../core/config/model_provider.zig");
const protocol = @import("anthropic_messages_protocol.zig");
const wire = @import("claude_agent_wire.zig");
const agent = @import("claude_agent.zig");
const stub = @import("claude_tool_stub.zig");

const functions = [_]model_tool_schema.FunctionSchema{
    .{ .name = "read", .description = "Read a file.", .input_schema = .{
        .properties = &.{.{ .name = "path", .json_type = .string }},
        .required = &.{"path"},
    } },
    .{ .name = "mcp.search", .description = "Search.", .input_schema = .{
        .properties = &.{.{ .name = "q", .json_type = .string }},
    } },
};

fn provider() model_provider.ProviderId {
    var value = model_provider.parse("anthropic").?;
    value.configured.binding = @splat(5);
    return value;
}

fn request(messages: []const types.ChatMessage) stream_provider.RequestData {
    return .{
        .model = "claude-opus-5-5",
        .instructions = &.{ .{ .role = .system, .content = "You are proto-fx." }, .{ .role = .system, .content = "Project rules." } },
        .messages = messages,
        .tools = .{ .advertised_names = &.{ "read", "mcp.search" }, .advertised_functions = &functions },
        .tool_choice = .auto,
        .provider_options = .{},
    };
}

const ids: wire.Ids = .{ .session = "6f1d2c3b-0000-4000-8000-000000000001", .cwd = "/work/repo", .model = "claude-opus-5-5", .timestamp = "2026-10-28T00:00:00.000Z" };

fn prepareFrom(alloc: std.mem.Allocator, messages: []const types.ChatMessage) !wire.Prepared {
    const id = provider();
    // Built with breakpoints, as a measured or reviewer body is.
    const body = try protocol.build_request(alloc, request(messages), .{ .provider = &id });
    defer alloc.free(body);
    return wire.prepare(alloc, body, ids);
}

test "a trailing tool result seeds the whole round and prompts to continue" {
    const alloc = std.testing.allocator;
    const id = provider();
    const call = [_]types.ToolCall{.{ .id = "toolu_1", .name = "mcp.search", .arguments_json = "{\"q\":\"zig\"}" }};
    const replay = "{\"anthropic_thinking\":[{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"sig\"}],\"_tool_call_ids\":[\"toolu_1\"]}";
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "search zig", .context_origin = .user_turn },
        .{ .role = .assistant, .content = "Searching.", .tool_calls = &call, .provider_replay = .{ .source = .{ .provider = id, .model = "claude-opus-5-5" }, .parts_json = replay } },
        .{ .role = .tool, .content = "found", .tool_call_id = "toolu_1", .tool_name = "mcp.search", .tool_result_status = .success },
    };
    var prepared = try prepareFrom(alloc, &messages);
    defer prepared.deinit(alloc);
    try std.testing.expect(prepared.continues_tools);
    try std.testing.expectEqualStrings("You are proto-fx.\n\nProject rules.", prepared.system);
    try std.testing.expectEqualStrings(
        "{\"type\":\"user\",\"session_id\":\"" ++ ids.session ++ "\",\"parent_tool_use_id\":null,\"message\":{\"role\":\"user\",\"content\":\"" ++ wire.continue_prompt ++ "\"}}\n",
        prepared.prompt_line,
    );
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, prepared.transcript, "\n"), '\n');
    var entries: [3]std.json.Parsed(std.json.Value) = undefined;
    var count: usize = 0;
    defer for (entries[0..count]) |*entry| entry.deinit();
    while (lines.next()) |line| : (count += 1) entries[count] = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
    try std.testing.expectEqual(@as(usize, 3), count);
    // Entries chain by parentUuid and carry the session and working directory.
    try std.testing.expect(entries[0].value.object.get("parentUuid").? == .null);
    for (entries[1..count], entries[0 .. count - 1]) |entry, previous| {
        try std.testing.expectEqualStrings(previous.value.object.get("uuid").?.string, entry.value.object.get("parentUuid").?.string);
    }
    for (entries[0..count]) |entry| {
        try std.testing.expectEqualStrings(ids.session, entry.value.object.get("sessionId").?.string);
        try std.testing.expectEqualStrings("/work/repo", entry.value.object.get("cwd").?.string);
    }
    // The assistant entry is a whole API message: replayed thinking with its
    // signature, the call under its MCP name, and a tool_use stop.
    const assistant = entries[1].value.object.get("message").?.object;
    try std.testing.expectEqualStrings("assistant", entries[1].value.object.get("type").?.string);
    try std.testing.expectEqualStrings("tool_use", assistant.get("stop_reason").?.string);
    try std.testing.expectEqualStrings("claude-opus-5-5", assistant.get("model").?.string);
    const content = assistant.get("content").?.array.items;
    try std.testing.expectEqualStrings("sig", content[0].object.get("signature").?.string);
    try std.testing.expectEqualStrings(wire.tool_prefix ++ "mcp_search", content[2].object.get("name").?.string);
    const result = entries[2].value.object.get("message").?.object.get("content").?.array.items[0].object;
    try std.testing.expectEqualStrings("tool_result", result.get("type").?.string);
    try std.testing.expectEqualStrings("toolu_1", result.get("tool_use_id").?.string);
    // No cache breakpoints reach Claude, which places its own.
    try std.testing.expect(std.mem.find(u8, prepared.transcript, "cache_control") == null);
    try std.testing.expect(std.mem.find(u8, prepared.tools_json, "cache_control") == null);
    try std.testing.expectEqual(@as(usize, 2), prepared.tool_count);
    try std.testing.expectEqualStrings(
        "[{\"name\":\"read\",\"description\":\"Read a file.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]},\"_meta\":{\"anthropic/alwaysLoad\":true}}," ++
            "{\"name\":\"mcp_search\",\"description\":\"Search.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}}},\"_meta\":{\"anthropic/alwaysLoad\":true}}]",
        prepared.tools_json,
    );
}

test "a user turn becomes the prompt and only earlier turns are seeded" {
    const alloc = std.testing.allocator;
    var first = try prepareFrom(alloc, &.{.{ .role = .user, .content = "hello", .context_origin = .user_turn }});
    defer first.deinit(alloc);
    try std.testing.expect(!first.continues_tools);
    try std.testing.expectEqual(@as(usize, 0), first.transcript.len);
    try std.testing.expect(std.mem.find(u8, first.prompt_line, "\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]") != null);

    var later = try prepareFrom(alloc, &.{
        .{ .role = .user, .content = "hello", .context_origin = .user_turn },
        .{ .role = .assistant, .content = "Hi." },
        .{ .role = .user, .content = "again", .context_origin = .user_turn },
    });
    defer later.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, later.transcript, "\n"));
    try std.testing.expect(std.mem.find(u8, later.transcript, "\"stop_reason\":\"end_turn\"") != null);
    try std.testing.expect(std.mem.find(u8, later.transcript, "again") == null);
    try std.testing.expect(std.mem.find(u8, later.prompt_line, "again") != null);
    try std.testing.expectError(error.InvalidProviderPrompt, wire.prepare(alloc, "{\"messages\":[{\"role\":\"assistant\",\"content\":[]}]}", ids));
}

test "derived session ids are stable UUIDs" {
    const a = wire.derivedUuid("session-1", 0);
    try std.testing.expectEqualSlices(u8, &a, &wire.derivedUuid("session-1", 0));
    try std.testing.expect(!std.mem.eql(u8, &a, &wire.derivedUuid("session-1", 1)));
    try std.testing.expectEqual(@as(u8, '4'), a[14]);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, &a, "-"));
}

test "the tool stub lists tools and refuses every call" {
    const alloc = std.testing.allocator;
    const tools = "[{\"name\":\"read\",\"inputSchema\":{\"type\":\"object\"}}]";
    const Case = struct { line: []const u8, expected: ?[]const u8 };
    for ([_]Case{
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\"}}", .expected = "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"proto_fx\",\"version\":\"1\"}}}\n" },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", .expected = null },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"tools/list\"}", .expected = "{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"result\":{\"tools\":" ++ tools ++ "}}\n" },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"read\",\"arguments\":{}}}", .expected = "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32603,\"message\":\"" ++ stub.refusal ++ "\"}}\n" },
        .{ .line = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/list\"}", .expected = "{\"jsonrpc\":\"2.0\",\"id\":3,\"error\":{\"code\":-32601,\"message\":\"Method not found\"}}\n" },
        .{ .line = "not json", .expected = null },
    }) |case| {
        const reply = try stub.respond(alloc, case.line, tools);
        defer if (reply) |value| alloc.free(value);
        if (case.expected) |expected| try std.testing.expectEqualStrings(expected, reply.?) else try std.testing.expect(reply == null);
    }
}

test "stream-json lines unwrap to events and failures" {
    const alloc = std.testing.allocator;
    const tool_start = try wire.unwrap(alloc, "{\"type\":\"stream_event\",\"event\":{\"p\":\"9c\",\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"mcp__proto_fx__read\",\"input\":{}}},\"session_id\":\"s\",\"parent_tool_use_id\":null}");
    defer alloc.free(tool_start.event);
    try std.testing.expectEqualStrings("{\"p\":\"9c\",\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"read\",\"input\":{}}}", tool_start.event);
    for ([_][]const u8{
        "{\"type\":\"system\",\"subtype\":\"init\",\"tools\":[\"mcp__proto_fx__read\"]}",
        "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\"},\"parent_tool_use_id\":\"toolu_9\"}",
        "{\"type\":\"system\",\"subtype\":\"permission_denied\",\"tool_name\":\"mcp__proto_fx__read\"}",
        "{\"type\":\"system\",\"subtype\":\"api_retry\",\"error_status\":529,\"error\":\"overloaded\"}",
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Hi\"}]}}",
        "[claude-code:unrecognized_model] {\"model\":\"x\"}",
        "",
    }) |line| try std.testing.expect(try wire.unwrap(alloc, line) == .ignore);
    try std.testing.expect(try wire.unwrap(alloc, "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}") == .result);

    const Case = struct { line: []const u8, kind: stream_provider.FailureKind, detail: []const u8 };
    for ([_]Case{
        .{ .line = "{\"type\":\"assistant\",\"error\":\"authentication_failed\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Not logged in\"}]}}", .kind = .unauthorized, .detail = "Not logged in" },
        .{ .line = "{\"type\":\"assistant\",\"error\":\"rate_limit\",\"message\":{\"content\":[]}}", .kind = .rate_limited, .detail = "rate_limit" },
        .{ .line = "{\"type\":\"system\",\"subtype\":\"api_retry\",\"error_status\":401,\"error\":\"invalid x-api-key\"}", .kind = .unauthorized, .detail = "401 invalid x-api-key" },
        .{ .line = "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"errors\":[\"boom\",\"bang\"]}", .kind = .provider_error, .detail = "boom\nbang" },
    }) |case| {
        const line = try wire.unwrap(alloc, case.line);
        defer alloc.free(line.failure.detail);
        try std.testing.expectEqual(case.kind, line.failure.kind);
        try std.testing.expectEqualStrings(case.detail, line.failure.detail);
    }
}

/// Recorded from `claude -p` against a Messages-compatible server: the call
/// is streamed, Claude denies it (no approval surface) and would go on, but
/// proto-fx stops reading at message_stop.
const tool_run =
    "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s\",\"tools\":[\"mcp__proto_fx__read\"],\"mcp_servers\":[{\"name\":\"proto_fx\",\"status\":\"connected\"}]}\n" ++
    "{\"type\":\"system\",\"subtype\":\"status\",\"status\":\"requesting\",\"session_id\":\"s\"}\n" ++
    "{\"type\":\"stream_event\",\"event\":{\"p\":\"4\",\"type\":\"message_start\",\"message\":{\"id\":\"msg_9\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-opus-5-5\",\"stop_reason\":null,\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Read it.\"}},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"c2ln\"}},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\",\"index\":0},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_7e\",\"name\":\"mcp__proto_fx__read\",\"input\":{}}},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"no\"}},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"tes.txt\\\"}\"}},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"assistant\",\"message\":{\"id\":\"msg_9\",\"content\":[{\"type\":\"tool_use\",\"id\":\"call_7e\",\"name\":\"mcp__proto_fx__read\",\"input\":{\"path\":\"notes.txt\"}}]},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_stop\",\"index\":1},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"system\",\"subtype\":\"permission_denied\",\"tool_name\":\"mcp__proto_fx__read\",\"tool_use_id\":\"call_7e\"}\n" ++
    "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":31,\"cache_read_input_tokens\":1200,\"cache_creation_input_tokens\":80,\"input_tokens\":596}},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"Permission for this tool use was denied.\",\"is_error\":true,\"tool_use_id\":\"call_7e\"}]}}\n" ++
    "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"},\"parent_tool_use_id\":null}\n" ++
    "{\"type\":\"result\",\"subtype\":\"error_max_turns\",\"is_error\":true,\"errors\":[\"max turns\"]}\n";

const Collector = struct {
    alloc: std.mem.Allocator,
    log: std.ArrayList(u8) = .empty,

    fn emit(raw: *anyopaque, event: stream_provider.Event) void {
        const self: *Collector = @ptrCast(@alignCast(raw));
        switch (event) {
            .content_delta => |text| self.log.print(self.alloc, "(text {s})", .{text}) catch {},
            .reasoning_delta => |text| self.log.print(self.alloc, "(think {s})", .{text}) catch {},
            .tool_started => |tool| self.log.print(self.alloc, "(start {s} {s})", .{ tool.id, tool.name }) catch {},
            .tool_input_delta => |delta| self.log.print(self.alloc, "(input {s}#{d} {s})", .{ delta.id, delta.index, delta.chunk }) catch {},
        }
    }
};

test "a recorded Claude Code tool run translates into a proto-fx tool call" {
    const alloc = std.testing.allocator;
    var collector: Collector = .{ .alloc = alloc };
    defer collector.log.deinit(alloc);
    var reader: std.Io.Reader = .fixed(tool_run);
    var cancel: std.atomic.Value(bool) = .init(false);
    var result = (try agent.translate(alloc, &reader, request(&.{.{ .role = .user, .content = "read notes", .context_origin = .user_turn }}), .{}, .{ .context = &collector, .emit_fn = Collector.emit }, &cancel)).?;
    defer result.deinit(alloc);
    const completion = result.completed.completion;
    try std.testing.expectEqualStrings("(think Read it.)(start call_7e read)(input call_7e#0 {\"path\":\"no)(input call_7e#0 tes.txt\"})", collector.log.items);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, completion.finish_reason.?);
    try std.testing.expectEqualStrings("read", completion.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"path\":\"notes.txt\"}", completion.tool_calls[0].arguments_json);
    try std.testing.expectEqual(@as(?u64, 1200), completion.usage.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, 80), completion.usage.cache_write_tokens);
    try std.testing.expectEqual(@as(?u64, 31), completion.usage.output_tokens);
    // Thinking replays on the next request, which seeds it into the transcript.
    try std.testing.expect(std.mem.find(u8, completion.provider_state_json.?, "\"signature\":\"c2ln\"") != null);

    // A run that fails before any message reports Claude's own reason.
    var failing: std.Io.Reader = .fixed("{\"type\":\"system\",\"subtype\":\"init\"}\n{\"type\":\"assistant\",\"error\":\"authentication_failed\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Not logged in\"}]}}\n");
    var failure = (try agent.translate(alloc, &failing, request(&.{.{ .role = .user, .content = "hi", .context_origin = .user_turn }}), .{}, .{ .context = &collector, .emit_fn = Collector.emit }, &cancel)).?;
    defer failure.deinit(alloc);
    try std.testing.expectEqual(stream_provider.FailureKind.unauthorized, failure.failed.kind);
    var truncated: std.Io.Reader = .fixed(tool_run[0..400]);
    try std.testing.expect(try agent.translate(alloc, &truncated, request(&.{.{ .role = .user, .content = "hi", .context_origin = .user_turn }}), .{}, .{ .context = &collector, .emit_fn = Collector.emit }, &cancel) == null);
}

test "the saved key picks Claude Code or the Messages API" {
    const alloc = std.testing.allocator;
    var saved_token = try agent.resolveMode(alloc, .{ .saved = try alloc.dupe(u8, "sk-ant-oat01-abc"), .api_key_env = "sk-ant-api03-env" });
    defer saved_token.deinit(alloc);
    try std.testing.expectEqualStrings("sk-ant-oat01-abc", saved_token.claude_code.?);
    var saved_key = try agent.resolveMode(alloc, .{ .saved = try alloc.dupe(u8, "sk-ant-api03-abc"), .oauth_env = "sk-ant-oat01-env" });
    defer saved_key.deinit(alloc);
    try std.testing.expectEqualStrings("sk-ant-api03-abc", saved_key.api_key);
    var env_token = try agent.resolveMode(alloc, .{ .oauth_env = "sk-ant-oat01-env", .api_key_env = "sk-ant-api03-env" });
    defer env_token.deinit(alloc);
    try std.testing.expectEqualStrings("sk-ant-oat01-env", env_token.claude_code.?);
    var env_key = try agent.resolveMode(alloc, .{ .api_key_env = "sk-ant-api03-env" });
    defer env_key.deinit(alloc);
    try std.testing.expectEqualStrings("sk-ant-api03-env", env_key.api_key);
    var neither = try agent.resolveMode(alloc, .{ .oauth_env = "" });
    defer neither.deinit(alloc);
    try std.testing.expect(neither.claude_code == null);
}

test "the claude command line runs one tool-less turn with the stub and the session" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try agent.arguments(arena, .{ .exe = "/bin/claude", .self = "/bin/proto-fx", .scratch = "/tmp/s", .session = ids.session, .resume_session = true, .tools = true, .model = "claude-opus-5-5", .effort = agent.effort(types.ReasoningEffort.literal("minimal")) });
    const joined = try std.mem.join(arena, " ", argv);
    for ([_][]const u8{
        "-p --input-format stream-json --output-format stream-json --verbose --include-partial-messages --max-turns 1 --tools  --setting-sources  --strict-mcp-config --permission-prompts none",
        "--system-prompt-file /tmp/s/system.txt --system-prompt-snapshot off",
        "--mcp-config {\"mcpServers\":{\"proto_fx\":{\"type\":\"stdio\",\"command\":\"/bin/proto-fx\",\"args\":[\"__claude-tools\",\"/tmp/s/tools.json\"]}}}",
        "--resume " ++ ids.session,
        "--effort low",
        "--model claude-opus-5-5",
    }) |part| if (std.mem.find(u8, joined, part) == null) {
        std.debug.print("missing {s} in {s}\n", .{ part, joined });
        return error.TestUnexpectedResult;
    };
    const first = try agent.arguments(arena, .{ .exe = "/bin/claude", .self = "/bin/proto-fx", .scratch = "/tmp/s", .session = ids.session, .resume_session = false, .tools = false, .model = "m", .effort = null });
    const first_joined = try std.mem.join(arena, " ", first);
    try std.testing.expect(std.mem.find(u8, first_joined, "--session-id " ++ ids.session) != null);
    try std.testing.expect(std.mem.find(u8, first_joined, "--mcp-config") == null);
    try std.testing.expect(std.mem.find(u8, first_joined, "--effort") == null);
    try std.testing.expectEqualStrings("-private-tmp-a-b", try agent.projectDirName(arena, "/private/tmp/a.b"));
    try std.testing.expectError(error.PathTooLong, agent.projectDirName(arena, &@as([201]u8, @splat('a'))));
}
