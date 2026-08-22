const std = @import("std");
const types = @import("../../../shared/types.zig");
const session_runtime = @import("../../../session/session.zig");
const debug_trace = @import("../../../shared/debug_trace.zig");
const io_mod = @import("../../../shared/io.zig");

const test_support = @import("support.zig");

const Allocator = std.mem.Allocator;
const HistoryTurn = types.HistoryTurn;
const ToolCall = types.ToolCall;

const removed_direct_question_guidance = "Treat it as interrupting any previous tool plan.";
const removed_resume_guidance = "Continue from the latest meaningful state";
const fixture_tools_json =
    "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read a file\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}]";

const FakeCompletion = test_support.FakeCompletion;
const FakeGateway = test_support.FakeGateway;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;
const PromptFixture = test_support.PromptFixture;

const runFakePrompt = test_support.runFakePrompt;
const expectBodyContains = test_support.expectBodyContains;
const expectBodyNotContains = test_support.expectBodyNotContains;
const expectBodyContainsInOrder = test_support.expectBodyContainsInOrder;
const expectGatewayPromptFinalUserText = test_support.expectGatewayPromptFinalUserText;
const readTraceFile = test_support.readTraceFile;
const logIndex = test_support.logIndex;
const toolCall = test_support.toolCall;

const ExpectedToolTerminal = struct {
    call_id: []const u8,
    kind: types.ToolOutcomeKind,
};

fn expectToolTerminalsBeforeTurnFinished(
    hooks: *const FakeAgentRuntimeDeps,
    expected: []const ExpectedToolTerminal,
) !void {
    const turn_finished_index = logIndex(hooks, "event:turn_finished") orelse
        return error.TestMissingTurnFinalization;
    var terminal_log_count: usize = 0;
    for (hooks.log.items, 0..) |entry, entry_index| {
        if (!std.mem.startsWith(u8, entry, "status:finished:")) continue;
        terminal_log_count += 1;
        try std.testing.expect(entry_index < turn_finished_index);
    }
    try std.testing.expectEqual(expected.len, terminal_log_count);

    for (expected) |wanted| {
        var terminal_count: usize = 0;
        for (hooks.lifecycle_events.items) |event| {
            if (event != .terminal) continue;
            try std.testing.expect(!std.mem.eql(
                u8,
                event.terminal.outcome.summary,
                "Tool cancelled",
            ));
            if (!std.mem.eql(u8, event.terminal.id.call_id, wanted.call_id)) continue;
            terminal_count += 1;
            try std.testing.expectEqual(wanted.kind, event.terminal.outcome.kind);
        }
        try std.testing.expectEqual(@as(usize, 1), terminal_count);
    }
}

fn expectGatewayPromptRoleContentKinds(gateway: *const FakeGateway, index: usize) !void {
    const alloc = std.testing.allocator;
    try std.testing.expect(index < gateway.request_bodies.items.len);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, gateway.request_bodies.items[index], .{});
    defer parsed.deinit();

    const prompt = parsed.value.object.get("prompt").?.array.items;
    for (prompt) |entry| {
        try std.testing.expect(entry == .object);
        const role = entry.object.get("role") orelse return error.TestExpectedPromptRoleMissing;
        try std.testing.expect(role == .string);
        const content = entry.object.get("content") orelse return error.TestExpectedPromptMessageMissing;
        if (std.mem.eql(u8, role.string, "system")) {
            try std.testing.expect(content == .string);
        } else if (std.mem.eql(u8, role.string, "user") or
            std.mem.eql(u8, role.string, "assistant") or
            std.mem.eql(u8, role.string, "tool"))
        {
            try std.testing.expect(content == .array);
        } else {
            return error.TestUnexpectedPromptRole;
        }
    }
}

test "processQueuedPrompt sends former intent text normally with tools" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        "What are you doing right now?",
        "Continue from the last useful progress update.",
    };

    for (cases) |text| {
        const completions = [_]FakeCompletion{.{ .content = "Context-grounded answer" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        hooks.runtime_context_text = "runtime context unique";
        var fixture = PromptFixture{};
        var job = fixture.job();
        job.prompt = @constCast(text);
        var config = fixture.config();
        config.gateway_tools_json = fixture_tools_json;

        try runFakePrompt(&gateway, &hooks, config, job);

        const body = gateway.request_bodies.items[0];
        const runtime_idx = std.mem.indexOf(u8, body, "runtime context unique") orelse return error.TestExpectedEqual;
        const current_idx = std.mem.indexOf(u8, body, text) orelse return error.TestExpectedEqual;
        try std.testing.expect(runtime_idx < current_idx);
        try expectGatewayPromptFinalUserText(&gateway, 0, text);
        try expectBodyContains(&gateway, 0, "\"name\":\"read_file\"");
        try expectBodyNotContains(&gateway, 0, removed_direct_question_guidance);
        try expectBodyNotContains(&gateway, 0, removed_resume_guidance);
    }
}

test "processQueuedPrompt persists no-output cancellation as interrupted once" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .cancel_before_output = true }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expect(fixture.cancel_flag.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expect(hooks.history_turns.items[0] == .interrupted);
    try std.testing.expect(hooks.history_turns.items[0].interrupted.assistant == null);
    try std.testing.expect(hooks.history_turns.items[0].interrupted.tool_call == null);
}

test "processQueuedPrompt persists partial-text cancellation as interrupted once" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{"Partial answer"};
    const completions = [_]FakeCompletion{.{ .chunks = &chunks, .cancel_after_chunks = true }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expect(hooks.history_turns.items[0] == .interrupted);
    try std.testing.expectEqualStrings("Partial answer", hooks.history_turns.items[0].interrupted.assistant.?);
    try std.testing.expect(hooks.history_turns.items[0].interrupted.tool_call == null);
}

test "streamed presentation preserves raw partial through cancellation" {
    const alloc = std.testing.allocator;
    const invisible_chunks = [_][]const u8{" \t\r\n"};
    const visible_chunks = [_][]const u8{ " \t\r\n", "Visible content\n" };
    const cases = [_]struct {
        chunks: []const []const u8,
        raw_assistant: []const u8,
        rendered_text: ?[]const u8,
    }{
        .{
            .chunks = &invisible_chunks,
            .raw_assistant = " \t\r\n",
            .rendered_text = null,
        },
        .{
            .chunks = &visible_chunks,
            .raw_assistant = " \t\r\nVisible content\n",
            .rendered_text = "Visible content\n",
        },
    };

    for (cases) |case| {
        const completions = [_]FakeCompletion{.{ .chunks = case.chunks, .cancel_after_chunks = true }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        var fixture = PromptFixture{};

        try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

        try std.testing.expect(fixture.cancel_flag.load(.seq_cst));
        try std.testing.expectEqual(@as(usize, 1), gateway.index);
        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
        try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
        try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
        try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
        try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
        try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
        try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
        try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_event_count);
        try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
        try std.testing.expect(hooks.history_turns.items[0] == .interrupted);
        try std.testing.expectEqualStrings(case.raw_assistant, hooks.history_turns.items[0].interrupted.assistant.?);
        try std.testing.expect(hooks.history_turns.items[0].interrupted.tool_call == null);

        if (case.rendered_text) |text| {
            try std.testing.expectEqual(@as(usize, 1), hooks.texts.items.len);
            try std.testing.expectEqualStrings(text, hooks.texts.items[0]);
        } else {
            try std.testing.expectEqual(@as(usize, 0), hooks.texts.items.len);
        }
    }
}

test "processQueuedPrompt cancellation after valid tool finish settles streamed calls" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        .{
            .id = "call_search",
            .name = "web_search",
            .arguments_json = "{\"query\":\"zig\"}",
            .provider_result = "{\"results\":[]}",
            .provenance = .provider_executed,
        },
        toolCall("call_read", "read_file", "{\"path\":\"README.md\"}"),
    };
    const completions = [_]FakeCompletion{.{
        .tool_calls = &calls,
        .streamed_tool_starts = &calls,
        .finish_reason = .tool_calls,
        .cancel_after_chunks = true,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expect(hooks.history_turns.items[0] == .interrupted);
    try expectToolTerminalsBeforeTurnFinished(&hooks, &.{
        .{ .call_id = "call_search", .kind = .completed },
        .{ .call_id = "call_read", .kind = .cancelled },
    });
}

test "processQueuedPrompt in-stream cancellation settles every eligible provisional start" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("call_command", "terminal", "{}"),
        toolCall("call_read", "read_file", "{}"),
    };
    const completions = [_]FakeCompletion{.{
        .streamed_tool_starts = &calls,
        .cancel_during_tool_stream = true,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
    try expectToolTerminalsBeforeTurnFinished(&hooks, &.{
        .{ .call_id = "call_read", .kind = .cancelled },
    });
}

test "processQueuedPrompt persists completed tool names when cancelled during next gateway wait" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "completed-tools-interrupt.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "interrupt");

    const calls = [_]ToolCall{
        toolCall("call_list", "list_files", "{\"path\":\".\"}"),
        toolCall("call_glob", "glob_files", "{\"pattern\":\"*\"}"),
    };
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .cancel_before_output = true },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.prompt = @constCast("use all ur tools 1 by 1 - I need u to test them");

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);
    debug_trace.shutdown();

    try std.testing.expectEqual(@as(usize, 2), hooks.executed_names.items.len);
    try std.testing.expectEqualStrings("list_files", hooks.executed_names.items[0]);
    try std.testing.expectEqualStrings("glob_files", hooks.executed_names.items[1]);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expect(hooks.history_turns.items[0] == .interrupted);
    try std.testing.expect(hooks.history_turns.items[0].interrupted.tool_call == null);
    try std.testing.expectEqual(@as(usize, 2), hooks.history_turns.items[0].interrupted.completed_tool_names.len);
    try std.testing.expectEqualStrings("list_files", hooks.history_turns.items[0].interrupted.completed_tool_names[0]);
    try std.testing.expectEqualStrings("glob_files", hooks.history_turns.items[0].interrupted.completed_tool_names[1]);

    const trace = try readTraceFile(alloc, trace_path, 65536);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "active_tool=false completed_tool_count=2 completed_tool_names=list_files,glob_files") != null);

    const follow_completions = [_]FakeCompletion{.{ .content = "I ran 2 tools: list_files and glob_files." }};
    var follow_gateway = FakeGateway.init(alloc, &follow_completions);
    defer follow_gateway.deinit();
    var follow_hooks = FakeAgentRuntimeDeps.init(alloc);
    defer follow_hooks.deinit();
    var follow_fixture = PromptFixture{};
    var follow_job = follow_fixture.job();
    follow_job.prompt = @constCast("how many did u run up until now ?");
    follow_job.history = hooks.history_turns.items;

    try runFakePrompt(&follow_gateway, &follow_hooks, follow_fixture.config(), follow_job);

    const expected_order = [_][]const u8{
        "use all ur tools 1 by 1 - I need u to test them",
        "Interrupted by user after completing 2 tool calls: list_files, glob_files.",
        "<turn_aborted>",
        "how many did u run up until now ?",
    };
    try expectBodyContainsInOrder(&follow_gateway, 0, &expected_order);
    try std.testing.expectEqual(@as(usize, 0), follow_hooks.executed_names.items.len);
}

test "processQueuedPrompt projects no-output interrupted turn as closed before follow-up" {
    const alloc = std.testing.allocator;
    const interrupted_prompt = "create another file in the folder called test.md and add 200 lines in that - anything";
    var history = [_]HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast(interrupted_prompt) },
    } }};
    const completions = [_]FakeCompletion{.{ .content = "The previous request was interrupted before I completed it." }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.prompt = @constCast("what happened?");
    job.history = history[0..];

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    const expected_order = [_][]const u8{
        interrupted_prompt,
        session_runtime.interrupted_before_completion_output,
        "<turn_aborted>",
        "what happened?",
    };
    try expectBodyContainsInOrder(&gateway, 0, &expected_order);
    try expectBodyNotContains(&gateway, 0, session_runtime.aborted_tool_output);
    try expectBodyNotContains(&gateway, 0, "\"toolCallId\"");
    try expectBodyNotContains(&gateway, 0, removed_direct_question_guidance);
    try expectBodyNotContains(&gateway, 0, removed_resume_guidance);

    const body = gateway.request_bodies.items[0];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, interrupted_prompt));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, session_runtime.interrupted_before_completion_output));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "<turn_aborted>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "what happened?"));
}

test "processQueuedPrompt projects partial-text interrupted turn as closed before meta follow-up" {
    const alloc = std.testing.allocator;
    const interrupted_prompt = "tell me a slow story in 1200 words, stream it gradually if possible";
    const partial_story = "Once the keeper reached the lighthouse, she lifted the lantern";
    var history = [_]HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast(interrupted_prompt) },
        .assistant = @constCast(partial_story),
    } }};
    const completions = [_]FakeCompletion{.{ .content = "The previous story turn was interrupted by the user." }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.prompt = @constCast("what happened?");
    job.history = history[0..];

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    const expected_order = [_][]const u8{
        interrupted_prompt,
        partial_story,
        session_runtime.interrupted_before_completion_output,
        "<turn_aborted>",
        "what happened?",
    };
    try expectBodyContainsInOrder(&gateway, 0, &expected_order);
    try expectBodyNotContains(&gateway, 0, session_runtime.aborted_tool_output);
    try expectBodyNotContains(&gateway, 0, removed_direct_question_guidance);
    try expectBodyNotContains(&gateway, 0, removed_resume_guidance);
    try expectBodyNotContains(&gateway, 0, "gradually if possiblewhat happened?");
    try expectBodyNotContains(&gateway, 0, "lanternwhat happened?");

    const body = gateway.request_bodies.items[0];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, interrupted_prompt));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, partial_story));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, session_runtime.interrupted_before_completion_output));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "<turn_aborted>"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "what happened?"));
}

test "processQueuedPrompt persists interrupted turn with aborted tool output for follow-up" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_browser", "browser_snapshot", "{}")};
    const completions = [_]FakeCompletion{.{ .tool_calls = &calls }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    hooks.exec_plans = &.{.{ .err = error.Cancelled }};
    hooks.cancel_on_execute = &fixture.cancel_flag;

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expect(hooks.history_turns.items[0] == .interrupted);
    try std.testing.expectEqualStrings("browser_snapshot", hooks.interrupted_tool_name.?);
    try std.testing.expectEqualStrings("browser_snapshot", hooks.history_turns.items[0].interrupted.tool_call.?.name);

    const follow_completions = [_]FakeCompletion{.{ .content = "The previous turn was interrupted." }};
    var follow_gateway = FakeGateway.init(alloc, &follow_completions);
    defer follow_gateway.deinit();
    var follow_hooks = FakeAgentRuntimeDeps.init(alloc);
    defer follow_hooks.deinit();
    var follow_fixture = PromptFixture{};
    var follow_job = follow_fixture.job();
    follow_job.prompt = @constCast("what happened?");
    follow_job.history = hooks.history_turns.items;

    try runFakePrompt(&follow_gateway, &follow_hooks, follow_fixture.config(), follow_job);

    try expectBodyContains(&follow_gateway, 0, "<turn_aborted>");
    try expectBodyContains(&follow_gateway, 0, session_runtime.aborted_tool_output);
    try expectBodyContains(&follow_gateway, 0, "\"toolName\":\"browser_snapshot\"");
    try expectBodyContains(&follow_gateway, 0, "\"toolCallId\":\"call_browser\"");
    try expectBodyNotContains(&follow_gateway, 0, "Continue from where you left off.");
    try expectBodyNotContains(&follow_gateway, 0, removed_direct_question_guidance);
    try expectBodyNotContains(&follow_gateway, 0, removed_resume_guidance);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, follow_gateway.request_bodies.items[0], "<turn_aborted>"));
    try expectGatewayPromptRoleContentKinds(&follow_gateway, 0);
}

test "processQueuedPrompt retains cancelled command artifact for presentation only" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "cancelled-command.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "interrupt");

    const artifact_path = "/tmp/session/logs/commands/fx-command-cancelled.log";
    const artifact_handle = "fx-command-cancelled.log";
    const result_output = "RESULT-ONLY-OUTPUT-SENTINEL\nTERM-TAIL-SENTINEL\n";
    const result_json =
        "{\"kind\":\"foreground\",\"command\":\"sleep 5\",\"cwd\":\"/tmp/RESULT-JSON-ONLY-SENTINEL\",\"exit_code\":null,\"signal\":15,\"timed_out\":false,\"duration_ms\":7,\"stdout_bytes\":49,\"stderr_bytes\":0,\"truncated\":false,\"output_file\":\"" ++ artifact_path ++ "\",\"stdout_file\":null,\"stderr_file\":null}";
    const calls = [_]ToolCall{toolCall("call_cancelled_command", "terminal", "{\"action\":\"exec\",\"command\":\"sleep 5\"}")};
    const completions = [_]FakeCompletion{.{ .tool_calls = &calls }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    hooks.exec_plans = &.{.{ .result = .{
        .status = .failure,
        .cancelled = true,
        .model_output = result_output,
        .command_result_json = result_json,
    } }};
    hooks.cancel_on_execute = &fixture.cancel_flag;

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());
    debug_trace.shutdown();

    const trace = try readTraceFile(alloc, trace_path, 65_536);
    defer alloc.free(trace);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "event=cancel_observed"));

    try std.testing.expectEqual(@as(usize, 1), hooks.executed_names.items.len);
    try std.testing.expectEqualStrings("terminal", hooks.executed_names.items[0]);
    try std.testing.expectEqual(@as(usize, 3), hooks.lifecycle_events.items.len);
    const terminal = hooks.lifecycle_events.items[2].terminal;
    try std.testing.expectEqual(types.ToolOutcomeKind.cancelled, terminal.outcome.kind);
    try std.testing.expectEqualStrings("Cancelled terminal", terminal.outcome.summary);
    try std.testing.expectEqualStrings(
        artifact_handle,
        terminal.command_artifact_handle orelse return error.TestExpectedArtifactHandle,
    );
    try std.testing.expect(terminal.result == null);
    try std.testing.expect(terminal.result_memory == null);
    try std.testing.expectEqual(@as(usize, 1), hooks.command_complete_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    const interrupted = hooks.history_turns.items[0].interrupted;
    const interrupted_call = interrupted.tool_call orelse return error.TestExpectedInterruptedToolCall;
    try std.testing.expectEqualStrings("call_cancelled_command", interrupted_call.id);
    try std.testing.expectEqualStrings("terminal", interrupted_call.name);
    try std.testing.expectEqual(@as(usize, 0), interrupted.completed_tool_names.len);
    try std.testing.expect(interrupted.execution.isEmpty());
    try std.testing.expect(interrupted.cancelled_command == null);

    const complete_log = try std.fmt.allocPrint(
        alloc,
        "command_output_complete:{d}:call_cancelled_command",
        .{terminal.id.turn_id},
    );
    defer alloc.free(complete_log);
    const terminal_index = logIndex(&hooks, "status:finished:Cancelled terminal") orelse return error.TestMissingCancelledTerminal;
    const complete_index = logIndex(&hooks, complete_log) orelse return error.TestMissingCommandCompletion;
    const history_index = logIndex(&hooks, "history:interrupted") orelse return error.TestMissingInterruptedHistory;
    const finalized_index = logIndex(&hooks, "event:turn_finished") orelse return error.TestMissingTurnFinalization;
    try std.testing.expect(terminal_index < complete_index);
    try std.testing.expect(complete_index < history_index);
    try std.testing.expect(history_index < finalized_index);

    const follow_completions = [_]FakeCompletion{.{ .content = "The command was interrupted." }};
    var follow_gateway = FakeGateway.init(alloc, &follow_completions);
    defer follow_gateway.deinit();
    var follow_hooks = FakeAgentRuntimeDeps.init(alloc);
    defer follow_hooks.deinit();
    var follow_fixture = PromptFixture{};
    var follow_job = follow_fixture.job();
    follow_job.prompt = @constCast("what happened?");
    follow_job.history = hooks.history_turns.items;

    try runFakePrompt(&follow_gateway, &follow_hooks, follow_fixture.config(), follow_job);

    try expectBodyContains(&follow_gateway, 0, "<turn_aborted>");
    try expectBodyContains(&follow_gateway, 0, session_runtime.aborted_tool_output);
    try expectBodyContains(&follow_gateway, 0, "\"toolName\":\"terminal\"");
    try expectBodyContains(&follow_gateway, 0, "\"toolCallId\":\"call_cancelled_command\"");
    try expectBodyNotContains(&follow_gateway, 0, "RESULT-ONLY-OUTPUT-SENTINEL");
    try expectBodyNotContains(&follow_gateway, 0, "RESULT-JSON-ONLY-SENTINEL");
    try expectBodyNotContains(&follow_gateway, 0, "TERM-TAIL-SENTINEL");
    try expectBodyNotContains(&follow_gateway, 0, artifact_handle);
    try expectBodyNotContains(&follow_gateway, 0, artifact_path);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, follow_gateway.request_bodies.items[0], session_runtime.aborted_tool_output));
}

test "processQueuedPrompt does not interrupt for an unconfirmed cancellation result" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_unconfirmed", "terminal", "{\"action\":\"exec\",\"command\":\"sleep 5\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &calls },
        .{ .content = "Recovered after the failed command." },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.exec_plans = &.{.{ .result = .{
        .status = .failure,
        .cancelled = true,
        .model_output = "command cancelled\n",
    } }};
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 0), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.interrupted_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.command_complete_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expect(hooks.history_turns.items[0] == .assistant);
    try std.testing.expectEqual(types.ToolOutcomeKind.failed, hooks.lifecycle_events.items[2].terminal.outcome.kind);
    try expectBodyContains(&gateway, 1, "command cancelled");
}

test "processQueuedPrompt cancellation during permission persists active tool call" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_write", "write_file", "{\"path\":\"test.md\",\"content\":\"x\"}")};
    const completions = [_]FakeCompletion{.{ .tool_calls = &calls }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.permission_decisions = &.{.deny};
    defer hooks.deinit();
    var fixture = PromptFixture{};
    hooks.cancel_on_permission = &fixture.cancel_flag;

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 1), hooks.permission_names.items.len);
    try std.testing.expectEqualStrings("write_file", hooks.permission_names.items[0]);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 3), hooks.lifecycle_events.items.len);
    try std.testing.expect(hooks.lifecycle_events.items[0] == .authoritative_started);
    try std.testing.expect(hooks.lifecycle_events.items[1] == .progress);
    try std.testing.expectEqual(
        types.ToolOutcomeKind.cancelled,
        hooks.lifecycle_events.items[2].terminal.outcome.kind,
    );
    try std.testing.expectEqualStrings(
        "Cancelled write_file",
        hooks.lifecycle_events.items[2].terminal.outcome.summary,
    );
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_history_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.interrupted_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expect(hooks.history_turns.items[0] == .interrupted);
    try std.testing.expectEqualStrings("write_file", hooks.history_turns.items[0].interrupted.tool_call.?.name);
    try std.testing.expectEqualStrings("call_write", hooks.history_turns.items[0].interrupted.tool_call.?.id);

    const follow_completions = [_]FakeCompletion{.{ .content = "The file creation was interrupted before approval." }};
    var follow_gateway = FakeGateway.init(alloc, &follow_completions);
    defer follow_gateway.deinit();
    var follow_hooks = FakeAgentRuntimeDeps.init(alloc);
    defer follow_hooks.deinit();
    var follow_fixture = PromptFixture{};
    var follow_job = follow_fixture.job();
    follow_job.prompt = @constCast("are you stuck?");
    follow_job.history = hooks.history_turns.items;

    try runFakePrompt(&follow_gateway, &follow_hooks, follow_fixture.config(), follow_job);

    try expectBodyContains(&follow_gateway, 0, "<turn_aborted>");
    try expectBodyContains(&follow_gateway, 0, session_runtime.aborted_tool_output);
    try expectBodyContains(&follow_gateway, 0, "\"toolName\":\"write_file\"");
    try expectBodyContains(&follow_gateway, 0, "\"toolCallId\":\"call_write\"");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, follow_gateway.request_bodies.items[0], "<turn_aborted>"));
}

test "interrupted write follow-up defers write_file until explicit continue" {
    const alloc = std.testing.allocator;
    const write_call = toolCall("call_write", "write_file", "{\"path\":\"test.md\",\"content\":\"x\"}");
    var history = [_]HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast("create test.md") },
        .tool_call = write_call,
    } }};

    const follow_completions = [_]FakeCompletion{.{ .content = "The file creation was interrupted before approval." }};
    var follow_gateway = FakeGateway.init(alloc, &follow_completions);
    defer follow_gateway.deinit();
    var follow_hooks = FakeAgentRuntimeDeps.init(alloc);
    defer follow_hooks.deinit();
    var follow_fixture = PromptFixture{};
    var follow_job = follow_fixture.job();
    follow_job.prompt = @constCast("what happened?");
    follow_job.history = history[0..];

    try runFakePrompt(&follow_gateway, &follow_hooks, follow_fixture.config(), follow_job);

    try expectBodyContains(&follow_gateway, 0, "<turn_aborted>");
    try expectBodyContains(&follow_gateway, 0, "\"toolName\":\"write_file\"");
    try std.testing.expectEqual(@as(usize, 0), follow_hooks.executed_names.items.len);

    const continue_calls = [_]ToolCall{write_call};
    const continue_completions = [_]FakeCompletion{
        .{ .tool_calls = &continue_calls },
        .{ .content = "Created it." },
    };
    var continue_gateway = FakeGateway.init(alloc, &continue_completions);
    defer continue_gateway.deinit();
    var continue_hooks = FakeAgentRuntimeDeps.init(alloc);
    defer continue_hooks.deinit();
    var continue_fixture = PromptFixture{};
    var continue_job = continue_fixture.job();
    continue_job.prompt = @constCast("yes continue and create it");
    continue_job.history = history[0..];

    try runFakePrompt(&continue_gateway, &continue_hooks, continue_fixture.config(), continue_job);

    try expectBodyContains(&continue_gateway, 0, "<turn_aborted>");
    try std.testing.expectEqual(@as(usize, 1), continue_hooks.executed_names.items.len);
    try std.testing.expectEqualStrings("write_file", continue_hooks.executed_names.items[0]);
}

test "processQueuedPrompt projects multiple interrupted story turns before transcript question" {
    const alloc = std.testing.allocator;
    var history = [_]HistoryTurn{
        .{ .interrupted = .{
            .user = .{ .text = @constCast("tell me a story in 200 words") },
            .assistant = @constCast("Once there was a quiet signal in the woods."),
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("go on") },
            .assistant = @constCast("The signal crossed the valley and found a door."),
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("go on") },
            .assistant = @constCast("The door opened, and the story ended in daylight."),
        } },
    };
    const completions = [_]FakeCompletion{.{ .content = "There were two interrupted story attempts, then a completed continuation." }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.prompt = @constCast("give me transcript of this session what happened when");
    job.history = history[0..];

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);

    const expected_order = [_][]const u8{
        "tell me a story in 200 words",
        "Once there was a quiet signal in the woods.",
        "<turn_aborted>",
        "go on",
        "The signal crossed the valley and found a door.",
        "<turn_aborted>",
        "go on",
        "The door opened, and the story ended in daylight.",
        "give me transcript of this session what happened when",
    };
    try expectBodyContainsInOrder(&gateway, 0, &expected_order);
    try expectBodyNotContains(&gateway, 0, "storygo ongo on");
    try expectBodyNotContains(&gateway, 0, "tell me a story in 200 wordsgo on");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, gateway.request_bodies.items[0], "<turn_aborted>"));
}

test "processQueuedPrompt trace records partial interrupted projection closures" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.fs.path.join(alloc, &.{ root, "partial-interrupt-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "history,gateway");

    var history = [_]HistoryTurn{.{ .interrupted = .{
        .user = .{ .text = @constCast("tell me a story") },
        .assistant = @constCast("Once the story started"),
    } }};
    const completions = [_]FakeCompletion{.{ .content = "The previous story was interrupted." }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.prompt = @constCast("what happened?");
    job.history = history[0..];

    try runFakePrompt(&gateway, &hooks, fixture.config(), job);
    debug_trace.shutdown();

    const trace = try readTraceFile(alloc, trace_path, 131072);
    defer alloc.free(trace);

    try std.testing.expect(std.mem.find(u8, trace, "event=projection_end") != null);
    try std.testing.expect(std.mem.find(u8, trace, "projected_message_roles=user,assistant,user") != null);
    try std.testing.expect(std.mem.find(u8, trace, "partial_interrupted_closures=1") != null);
}
