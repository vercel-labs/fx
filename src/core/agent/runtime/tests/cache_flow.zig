//! Prompt cache hygiene (D130-D132): every request in a session repeats the
//! bytes of the one before it, so a provider's prefix cache keeps hitting
//! while the date, branch, directory or skill selection changes.
const std = @import("std");
const types = @import("../../../shared/types.zig");
const test_support = @import("support.zig");

const FakeCompletion = test_support.FakeCompletion;
const FakeGateway = test_support.FakeGateway;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;
const PromptFixture = test_support.PromptFixture;
const runFakePrompt = test_support.runFakePrompt;
const expectBodyContains = test_support.expectBodyContains;
const expectBodyNotContains = test_support.expectBodyNotContains;
const toolCall = test_support.toolCall;

/// The body up to the end of its last prompt entry: the part a later
/// request must repeat byte for byte.
fn promptPrefix(body: []const u8) ![]const u8 {
    const marker = "\"prompt\":[";
    const start = (std.mem.find(u8, body, marker) orelse return error.TestExpectedPrompt) + marker.len;
    var depth: usize = 1;
    var quoted = false;
    var escaped = false;
    for (body[start..], start..) |byte, index| {
        if (quoted) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') quoted = false;
            continue;
        }
        switch (byte) {
            '"' => quoted = true,
            '[', '{' => depth += 1,
            ']', '}' => {
                depth -= 1;
                if (depth == 0) return body[0..index];
            },
            else => {},
        }
    }
    return error.TestExpectedPrompt;
}

fn expectRepeatsPrefix(gateway: *const FakeGateway, earlier: usize, later: usize) !void {
    const prefix = try promptPrefix(gateway.request_bodies.items[earlier]);
    const body = gateway.request_bodies.items[later];
    if (!std.mem.startsWith(u8, body, prefix)) {
        std.debug.print("request {d} does not repeat request {d}\nearlier: {s}\nlater:   {s}\n", .{ later, earlier, prefix, body });
        return error.TestExpectedEqual;
    }
}

fn instructionsOf(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (parsed.value.object.get("prompt").?.array.items) |entry| {
        const role = entry.object.get("role").?.string;
        if (!std.mem.eql(u8, role, "system")) continue;
        try std.json.Stringify.value(entry, .{}, &out.writer);
    }
    return out.toOwnedSlice();
}

test "a turn's requests repeat each other while its runtime context changes" {
    const alloc = std.testing.allocator;
    const calls = [_]types.ToolCall{toolCall("call_read", "read_file", "{\"path\":\"a\"}")};
    const completions = [_]FakeCompletion{
        .{ .content = "Checking.", .tool_calls = &calls },
        .{ .content = "Final" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    // A second capture would see the branch change; the turn makes one.
    const contexts = [_][]const u8{ "date_utc: 2026-10-27 git_branch: main", "date_utc: 2026-10-28 git_branch: next" };
    hooks.runtime_context_texts = &contexts;
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.runtime_context_index);
    try expectRepeatsPrefix(&gateway, 0, 1);
    try expectBodyNotContains(&gateway, 1, "git_branch: next");
    // The context rides before the person's text, never in the instructions.
    try test_support.expectBodyContainsInOrder(&gateway, 0, &.{ "git_branch: main", "user prompt" });
    const instructions = try instructionsOf(alloc, gateway.request_bodies.items[0]);
    defer alloc.free(instructions);
    try std.testing.expect(std.mem.find(u8, instructions, "git_branch") == null);
}

test "later turns repeat earlier ones and add context only when it changes" {
    const alloc = std.testing.allocator;
    const calls = [_]types.ToolCall{toolCall("call_read", "read_file", "{\"path\":\"a\"}")};
    const completions = [_]FakeCompletion{
        .{ .content = "Checking.", .tool_calls = &calls },
        .{ .content = "First answer" },
        .{ .content = "Second answer" },
        .{ .content = "Third answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    const contexts = [_][]const u8{
        "date_utc: 2026-10-27 git_branch: main",
        "date_utc: 2026-10-27 git_branch: main",
        "date_utc: 2026-10-28 git_branch: next",
    };
    hooks.runtime_context_texts = &contexts;
    var fixture = PromptFixture{};

    // Turn one: two steps.
    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expectEqualStrings(contexts[0], hooks.history_turns.items[0].assistant.user.turn_context.?);

    // Turn two: the same context, so nothing new rides with it.
    var second = fixture.job();
    second.prompt = @constCast("second prompt");
    second.history = hooks.history_turns.items;
    try runFakePrompt(&gateway, &hooks, fixture.config(), second);
    try std.testing.expectEqual(@as(usize, 3), gateway.request_bodies.items.len);
    try expectRepeatsPrefix(&gateway, 1, 2);
    try std.testing.expectEqual(@as(usize, 1), test_support.countNeedle(gateway.request_bodies.items[2], "git_branch: main"));
    try std.testing.expect(hooks.history_turns.items[1].assistant.user.turn_context == null);

    // Turn three: the date and branch moved, so the new context rides
    // just before the prompt and every earlier byte stays put.
    var third = fixture.job();
    third.prompt = @constCast("third prompt");
    third.history = hooks.history_turns.items;
    try runFakePrompt(&gateway, &hooks, fixture.config(), third);
    try std.testing.expectEqual(@as(usize, 4), gateway.request_bodies.items.len);
    try expectRepeatsPrefix(&gateway, 2, 3);
    try test_support.expectBodyContainsInOrder(&gateway, 3, &.{ "Second answer", "git_branch: next", "third prompt" });

    // Every request sent the same instructions.
    const head = try instructionsOf(alloc, gateway.request_bodies.items[0]);
    defer alloc.free(head);
    for (gateway.request_bodies.items[1..]) |body| {
        const later = try instructionsOf(alloc, body);
        defer alloc.free(later);
        try std.testing.expectEqualStrings(head, later);
    }
}

test "a turn's context survives the session's own save and load" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "Answer" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.runtime_context_text = "date_utc: 2026-10-27";
    var fixture = PromptFixture{};
    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    // The projection of the saved turn is what the request sent.
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    try @import("../../../session/session.zig").appendHistoryChatMessages(arena_state.allocator(), &messages, hooks.history_turns.items);
    try std.testing.expectEqual(types.ChatRole.user, messages.items[0].role);
    try std.testing.expect(messages.items[0].context_origin == .turn_context);
    try std.testing.expectEqualStrings("date_utc: 2026-10-27", messages.items[0].content.?);
    try std.testing.expectEqualStrings("user prompt", messages.items[1].content.?);
    try expectBodyContains(&gateway, 0, "date_utc: 2026-10-27");
}

fn toolsOf(alloc: std.mem.Allocator, body: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try std.json.Stringify.value(parsed.value.object.get("tools") orelse return error.TestExpectedTools, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn echoSchema(comptime name: []const u8) []const u8 {
    return "{\"type\":\"function\",\"name\":\"" ++ name ++ "\",\"description\":\"Echo\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}}}}";
}

test "a dynamic tool selected in one turn stays in the tools of later turns, appended in order" {
    const alloc = std.testing.allocator;
    const select_first = [_]types.ToolCall{toolCall("select_one", "mcp_select_tool", "{\"name\":\"mcp_fixture_echo\"}")};
    const select_second = [_]types.ToolCall{toolCall("select_two", "mcp_select_tool", "{\"name\":\"mcp_fixture_lookup\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &select_first },
        .{ .content = "First answer" },
        .{ .content = "Second answer" },
        .{ .tool_calls = &select_second },
        .{ .content = "Third answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.exec_plans = &.{
        .{ .result = .{ .model_output = "selected", .selected_dynamic_tools = &.{.{ .name = "mcp_fixture_echo", .schema_json = echoSchema("mcp_fixture_echo") }} } },
        .{ .result = .{ .model_output = "selected", .selected_dynamic_tools = &.{.{ .name = "mcp_fixture_lookup", .schema_json = echoSchema("mcp_fixture_lookup") }} } },
    };
    var set: @import("../dynamic_tool_set.zig").DynamicToolSet = .{};
    defer set.deinit(alloc);
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.session_dynamic_tools = .{ .set = &set, .alloc = alloc };

    // Turn one selects a tool; its second request advertises it.
    var first = fixture.job();
    first.permission_mode = .auto;
    try runFakePrompt(&gateway, &hooks, config, first);
    try std.testing.expectEqual(@as(usize, 1), set.count());
    try expectBodyNotContains(&gateway, 0, "mcp_fixture_echo\",\"description");
    const turn_one_tools = try toolsOf(alloc, gateway.request_bodies.items[1]);
    defer alloc.free(turn_one_tools);
    try std.testing.expect(std.mem.find(u8, turn_one_tools, "mcp_fixture_echo") != null);

    // Turn two selects nothing and still sends the same tools.
    var second = fixture.job();
    second.prompt = @constCast("second prompt");
    second.permission_mode = .auto;
    second.history = hooks.history_turns.items;
    try runFakePrompt(&gateway, &hooks, config, second);
    const turn_two_tools = try toolsOf(alloc, gateway.request_bodies.items[2]);
    defer alloc.free(turn_two_tools);
    try std.testing.expectEqualStrings(turn_one_tools, turn_two_tools);
    try expectRepeatsPrefix(&gateway, 1, 2);

    // Turn three selects another tool, which goes after the first, so
    // the earlier tool bytes stay where they were.
    var third = fixture.job();
    third.prompt = @constCast("third prompt");
    third.permission_mode = .auto;
    third.history = hooks.history_turns.items;
    try runFakePrompt(&gateway, &hooks, config, third);
    try std.testing.expectEqual(@as(usize, 5), gateway.request_bodies.items.len);
    const turn_three_tools = try toolsOf(alloc, gateway.request_bodies.items[4]);
    defer alloc.free(turn_three_tools);
    try std.testing.expect(std.mem.startsWith(u8, turn_three_tools, turn_one_tools[0 .. turn_one_tools.len - 1]));
    try std.testing.expect(std.mem.find(u8, turn_three_tools[turn_one_tools.len - 1 ..], "mcp_fixture_lookup") != null);
    try std.testing.expectEqual(@as(usize, 2), set.count());
}
