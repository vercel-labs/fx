//! Request-body goldens for `anthropic_messages_protocol.zig`.
const std = @import("std");
const testing_allocator = @import("../core/shared/testing_allocator.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const types = @import("../core/shared/types.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const model_provider = @import("../core/config/model_provider.zig");
const protocol = @import("anthropic_messages_protocol.zig");

const Allocator = std.mem.Allocator;
const cache_marker = ",\"cache_control\":{\"type\":\"ephemeral\"}";

const functions = [_]model_tool_schema.FunctionSchema{
    .{ .name = "read_file", .description = "Read a file.", .input_schema = .{
        .properties = &.{.{ .name = "path", .json_type = .string }},
        .required = &.{"path"},
        .additional_properties = false,
    } },
    .{ .name = "mcp.search", .description = "Search.", .input_schema = .{
        .properties = &.{.{ .name = "q", .json_type = .string }},
        .required = &.{"q"},
    } },
};

fn provider() model_provider.ProviderId {
    var value = model_provider.parse("claude").?;
    value.configured.binding = @splat(7);
    return value;
}

fn request(messages: []const types.ChatMessage) stream_provider.RequestData {
    return .{
        .model = "claude-test",
        .instructions = &.{ .{ .role = .system, .content = "You are fx." }, .{ .role = .system, .content = "Project rules." } },
        .messages = messages,
        .tools = .{ .advertised_names = &.{ "read_file", "mcp.search" }, .advertised_functions = &functions },
        .tool_choice = .auto,
        .provider_options = .{},
        .max_output_tokens = 4096,
    };
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

/// The body with every breakpoint removed, which is what the cache keys on.
fn strip(alloc: Allocator, body: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, alloc, body, cache_marker, "");
}

const replay_json = "{\"anthropic_thinking\":[{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"sig/+=\"},{\"type\":\"redacted_thinking\",\"data\":\"opaque\"}],\"_tool_call_ids\":[\"toolu_1\"]}";

test "anthropic messages golden body places tool system and tail breakpoints" {
    const alloc = std.testing.allocator;
    const id = provider();
    const call = [_]types.ToolCall{.{ .id = "toolu_1", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "read a.txt", .context_origin = .user_turn },
        .{ .role = .assistant, .content = "Reading.", .tool_calls = &call, .provider_replay = .{ .source = .{ .provider = id, .model = "claude-test" }, .parts_json = replay_json } },
        .{ .role = .tool, .content = "hello", .tool_call_id = "toolu_1", .tool_name = "read_file", .tool_result_status = .success },
    };
    var input = request(&messages);
    input.provider_options.reasoning = types.ReasoningEffort.literal("high");
    const body = try protocol.build_request(alloc, input, .{ .provider = &id });
    defer alloc.free(body);
    try std.testing.expectEqualStrings(
        "{\"model\":\"claude-test\",\"max_tokens\":4096,\"stream\":true," ++
            "\"system\":[{\"type\":\"text\",\"text\":\"You are fx.\"},{\"type\":\"text\",\"text\":\"Project rules.\"" ++ cache_marker ++ "}]," ++
            "\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"read a.txt\"}]}," ++
            "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"sig/+=\"},{\"type\":\"redacted_thinking\",\"data\":\"opaque\"}," ++
            "{\"type\":\"text\",\"text\":\"Reading.\"},{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"read_file\",\"input\":{\"path\":\"a.txt\"}" ++ cache_marker ++ "}]}," ++
            "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"hello\"" ++ cache_marker ++ "}]}]," ++
            "\"tools\":[{\"name\":\"read_file\",\"description\":\"Read a file.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"additionalProperties\":false,\"required\":[\"path\"]},\"eager_input_streaming\":true}," ++
            "{\"name\":\"mcp_search\",\"description\":\"Search.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"q\":{\"type\":\"string\"}},\"required\":[\"q\"]},\"eager_input_streaming\":true" ++ cache_marker ++ "}]," ++
            "\"tool_choice\":{\"type\":\"auto\"},\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":3072}}",
        body,
    );
    try std.testing.expectEqual(@as(usize, 4), count(body, cache_marker));
    try std.testing.expect(protocol.uses_budget_thinking(body));
}

test "anthropic messages breakpoints keep the earlier prefix byte-stable across steps" {
    const alloc = std.testing.allocator;
    const call = [_]types.ToolCall{.{ .id = "toolu_1", .name = "read_file", .arguments_json = "{\"path\":\"a\"}" }};
    const call2 = [_]types.ToolCall{.{ .id = "toolu_2", .name = "read_file", .arguments_json = "{\"path\":\"b\"}" }};
    const history = [_]types.ChatMessage{
        .{ .role = .user, .content = "go" },
        .{ .role = .assistant, .tool_calls = &call },
        .{ .role = .tool, .content = "A", .tool_call_id = "toolu_1", .tool_name = "read_file" },
        .{ .role = .assistant, .tool_calls = &call2 },
        .{ .role = .tool, .content = "B", .tool_call_id = "toolu_2", .tool_name = "read_file" },
        .{ .role = .assistant, .content = "done" },
        .{ .role = .user, .content = "next" },
    };
    var previous: ?[]u8 = null;
    defer if (previous) |body| alloc.free(body);
    for ([_]usize{ 1, 3, 5, 7 }) |len| {
        const body = try protocol.build_request(alloc, request(history[0..len]), .{});
        try std.testing.expect(count(body, cache_marker) <= protocol.max_breakpoints);
        // The step's tail breakpoint sits on its last block.
        try std.testing.expect(std.mem.endsWith(u8, body[0..std.mem.find(u8, body, "]}],\"tools\"").?], cache_marker ++ "}"));
        const stripped = try strip(alloc, body);
        defer alloc.free(stripped);
        if (previous) |prior| {
            const prior_stripped = try strip(alloc, prior);
            defer alloc.free(prior_stripped);
            const prior_messages = prior_stripped[0..std.mem.find(u8, prior_stripped, "],\"tools\"").?];
            try std.testing.expect(std.mem.startsWith(u8, stripped, prior_messages));
            alloc.free(prior);
        }
        previous = body;
    }
}

test "anthropic messages volatile instructions stay behind the system breakpoint" {
    const alloc = std.testing.allocator;
    var input = request(&.{.{ .role = .user, .content = "hi" }});
    input.instructions = &.{ .{ .role = .system, .content = "stable" }, .{ .role = .system, .content = "<fx-turn-context>\ndate: today</fx-turn-context>" }, .{ .role = .system, .content = "Runtime context: later" } };
    const body = try protocol.build_request(alloc, input, .{});
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"text\":\"stable\"" ++ cache_marker) != null);
    try std.testing.expect(std.mem.find(u8, body, "</fx-turn-context>\"" ++ cache_marker) == null);
    const explicit = try protocol.build_request(alloc, input, .{ .stable_instructions = 2 });
    try std.testing.expectEqual(@as(usize, 1), count(explicit, "\"system\":[") * count(explicit, "</fx-turn-context>\"" ++ cache_marker));
    defer alloc.free(explicit);
    try std.testing.expect(std.mem.find(u8, explicit, "</fx-turn-context>\"" ++ cache_marker) != null);
    const off = try protocol.build_request(alloc, input, .{ .cache = .off });
    defer alloc.free(off);
    try std.testing.expectEqual(@as(usize, 0), count(off, "cache_control"));
}

test "anthropic messages decimation anchors every fifteenth user turn within four breakpoints" {
    const alloc = std.testing.allocator;
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    defer messages.deinit(alloc);
    var texts: [32][8]u8 = undefined;
    for (0..32) |index| {
        const text = try std.mem.print(&texts[index], "u{d}", .{index + 1});
        try messages.append(alloc, .{ .role = .user, .content = text });
        try messages.append(alloc, .{ .role = .assistant, .content = "ok" });
    }
    try messages.append(alloc, .{ .role = .user, .content = "last" });
    var input = request(messages.items);
    input.tools = .{};
    input.instructions = &.{};
    const body = try protocol.build_request(alloc, input, .{});
    defer alloc.free(body);
    try std.testing.expectEqual(@as(usize, 4), count(body, cache_marker));
    try std.testing.expect(std.mem.find(u8, body, "\"last\"" ++ cache_marker) != null);
    try std.testing.expect(std.mem.find(u8, body, "\"u30\"" ++ cache_marker) != null);
    try std.testing.expect(std.mem.find(u8, body, "\"u15\"" ++ cache_marker) != null);
}

test "anthropic messages drops thinking replay for another model and turns thinking off" {
    const alloc = std.testing.allocator;
    const id = provider();
    const call = [_]types.ToolCall{.{ .id = "toolu_1", .name = "read_file", .arguments_json = "{}" }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "go" },
        .{ .role = .assistant, .tool_calls = &call, .provider_replay = .{ .source = .{ .provider = id, .model = "claude-test" }, .parts_json = replay_json } },
        .{ .role = .tool, .content = "x", .tool_call_id = "toolu_1", .tool_name = "read_file" },
    };
    var input = request(&messages);
    input.provider_options.reasoning = types.ReasoningEffort.literal("medium");
    input.model = "claude-other";
    const other = try protocol.build_request(alloc, input, .{ .provider = &id });
    defer alloc.free(other);
    try std.testing.expect(std.mem.find(u8, other, "signature") == null);
    // The open tool loop has no signed thinking, so thinking stays off.
    try std.testing.expect(std.mem.find(u8, other, "\"thinking\":{") == null);
    input.model = "claude-test";
    const dropped = try protocol.build_request(alloc, input, .{ .provider = &id, .drop_thinking = true });
    defer alloc.free(dropped);
    try std.testing.expect(std.mem.find(u8, dropped, "redacted_thinking") == null);
    const same = try protocol.build_request(alloc, input, .{ .provider = &id, .thinking_mode = .adaptive });
    defer alloc.free(same);
    try std.testing.expect(std.mem.find(u8, same, "\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":\"medium\"}") != null);
    try std.testing.expectError(error.UnsupportedReplay, protocol.build_request(alloc, input, .{}));
    try std.testing.expectEqual(@as(?types.ProviderReplay, null), try protocol.project_replay(alloc, messages[1].provider_replay, &.{}, false, true));
    try std.testing.expect((try protocol.project_replay(alloc, messages[1].provider_replay, &call, false, true)) != null);
}

test "anthropic messages gates unsigned thinking replay by compatibility" {
    const alloc = std.testing.allocator;
    const id = provider();
    const call = [_]types.ToolCall{.{ .id = "toolu_unsigned", .name = "read_file", .arguments_json = "{}" }};
    const unsigned_replay = "{\"anthropic_thinking\":[{\"type\":\"thinking\",\"thinking\":\"plan\",\"signature\":\"\"}],\"_tool_call_ids\":[\"toolu_unsigned\"]}";
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "go" },
        .{ .role = .assistant, .tool_calls = &call, .provider_replay = .{ .source = .{ .provider = id, .model = "claude-test" }, .parts_json = unsigned_replay } },
        .{ .role = .tool, .content = "x", .tool_call_id = "toolu_unsigned", .tool_name = "read_file" },
    };
    const input = request(&messages);
    const dropped = try protocol.build_request(alloc, input, .{ .provider = &id });
    defer alloc.free(dropped);
    try std.testing.expect(std.mem.find(u8, dropped, "\"thinking\":\"plan\"") == null);
    const replayed = try protocol.build_request(alloc, input, .{ .provider = &id, .replay_unsigned_thinking = true });
    defer alloc.free(replayed);
    try std.testing.expect(std.mem.find(u8, replayed, "\"thinking\":\"plan\"") != null);
    try std.testing.expect(std.mem.find(u8, replayed, "\"signature\":\"\"") != null);
}

test "anthropic messages emits required thinking presence without selected effort" {
    const alloc = std.testing.allocator;
    const id = provider();
    const input = request(&.{.{ .role = .user, .content = "hello" }});
    const body = try protocol.build_request(alloc, input, .{ .provider = &id, .requires_thinking_presence = true });
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":1024}") != null);
}

test "anthropic messages forced tools turn thinking off and none keeps definitions" {
    const alloc = std.testing.allocator;
    var input = request(&.{.{ .role = .user, .content = "hi" }});
    input.provider_options.reasoning = types.ReasoningEffort.literal("high");
    input.provider_options.parallel_tool_calls = false;
    input.tool_choice = .required;
    const forced = try protocol.build_request(alloc, input, .{});
    defer alloc.free(forced);
    try std.testing.expect(std.mem.find(u8, forced, "\"tool_choice\":{\"type\":\"any\",\"disable_parallel_tool_use\":true}") != null);
    try std.testing.expect(std.mem.find(u8, forced, "\"thinking\"") == null);
    input.tool_choice = .none;
    const none = try protocol.build_request(alloc, input, .{});
    defer alloc.free(none);
    try std.testing.expect(std.mem.find(u8, none, "\"tool_choice\":{\"type\":\"none\"}") != null);
    try std.testing.expectEqualStrings("mcp.search", protocol.canonical_tool_name(input.tools, "mcp_search"));
    try std.testing.expectEqualStrings("unknown", protocol.canonical_tool_name(input.tools, "unknown"));
}

test "anthropic messages downgrades unsupported forced tools before required thinking" {
    const alloc = std.testing.allocator;
    const id = provider();
    var input = request(&.{.{ .role = .user, .content = "call the tool" }});
    input.tool_choice = .required;
    const body = try protocol.build_request(alloc, input, .{ .provider = &id, .requires_thinking_presence = true, .supports_forced_tool_choice = false });
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"tool_choice\":{\"type\":\"auto\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":1024}") != null);
}

test "anthropic messages serializes advanced output controls and compaction" {
    const alloc = std.testing.allocator;
    const id = provider();
    var schema = try std.json.parseFromSlice(std.json.Value, alloc, "{\"type\":\"object\",\"properties\":{}}", .{});
    defer schema.deinit();
    var input = request(&.{.{ .role = .user, .content = "hi" }});
    input.provider_options.fast = true;
    input.provider_options.task_budget = .{ .total = 4096, .remaining = 2048 };
    input.provider_options.fallback_model = "claude-sonnet-5";
    input.provider_options.anthropic_compaction = .{
        .trigger_input_tokens = 1024,
        .pause_after_compaction = true,
        .instructions = "Summarize the history.",
    };
    input.response_format = .{ .name = "answer", .description = "A result.", .schema = schema.value };
    const body = try protocol.build_request(alloc, input, .{ .provider = &id });
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"speed\":\"fast\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"task_budget\":{\"type\":\"tokens\",\"total\":4096,\"remaining\":2048}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"fallbacks\":[{\"model\":\"claude-sonnet-5\"}]") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"format\":{\"type\":\"json_schema\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"context_management\":{\"edits\":[{\"type\":\"compact_20260112\",\"trigger\":{\"type\":\"input_tokens\",\"value\":50000}") != null);
}

test "anthropic compaction replay exposes its summary" {
    const alloc = std.testing.allocator;
    const raw = "{\"anthropic_thinking\":[],\"anthropic_compaction\":{\"content\":\"summary\",\"encrypted_content\":\"cipher\"},\"_tool_call_ids\":[]}";
    const summary = (try protocol.compaction_summary(alloc, raw)).?;
    defer alloc.free(summary);
    try std.testing.expectEqualStrings("summary", summary);
}

test "anthropic messages sends an instruction-only prompt as one user turn" {
    const alloc = std.testing.allocator;
    var input = request(&.{});
    input.tools = .{};
    const body = try protocol.build_request(alloc, input, .{ .cache = .off });
    defer alloc.free(body);
    try std.testing.expectEqualStrings("{\"model\":\"claude-test\",\"max_tokens\":4096,\"stream\":true,\"system\":[{\"type\":\"text\",\"text\":\"You are fx.\"}],\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Project rules.\"}]}]}", body);
}

fn allocation_probe(alloc: Allocator) !void {
    const id = provider();
    const call = [_]types.ToolCall{.{ .id = "toolu_1", .name = "read_file", .arguments_json = "{}" }};
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "go" },
        .{ .role = .assistant, .tool_calls = &call, .provider_replay = .{ .source = .{ .provider = id, .model = "claude-test" }, .parts_json = replay_json } },
        .{ .role = .tool, .content = "x", .tool_call_id = "toolu_1", .tool_name = "read_file", .tool_result_status = .failure },
    };
    const body = try protocol.build_request(alloc, request(&messages), .{ .provider = &id });
    alloc.free(body);
}

test "anthropic messages serialization releases memory on allocation failure" {
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, allocation_probe, .{});
}
