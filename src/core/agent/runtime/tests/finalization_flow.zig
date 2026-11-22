const std = @import("std");
const testing_allocator = @import("../../../shared/testing_allocator.zig");
const types = @import("../../../shared/types.zig");
const debug_trace = @import("../../../shared/debug_trace.zig");
const io_mod = @import("../../../shared/io.zig");
const tool_result_errors = @import("../../../tooling/tool_result_errors.zig");
const lifecycle_hooks = @import("../../../hooks/hooks.zig");
const session_runtime = @import("../../../session/session.zig");
const worker_runtime = @import("../../worker_runtime.zig");

const test_support = @import("support.zig");
const runtime_finalization = @import("../finalization.zig");
const runtime_orchestrator = @import("../orchestrator.zig");
const runtime_telemetry = @import("../telemetry.zig");
const runtime_lifecycle = @import("../lifecycle.zig");
const profile_paths = @import("../../../shared/profile_paths.zig");
const runtime_user_hooks = @import("../user_hooks.zig");
const hooks_host = @import("../../../hooks_host/hooks_host.zig");
const hooks_engine = @import("../../../../hooks/hooks.zig");

const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;
const TurnFinalizationGuard = runtime_finalization.TurnFinalizationGuard;
const PromptFinishTrace = runtime_finalization.PromptFinishTrace;
const TurnSummaryAccumulator = runtime_telemetry.TurnSummaryAccumulator;
const CommonStopState = runtime_orchestrator.CommonStopState;
const copyLatestStopPartial = runtime_orchestrator.copyLatestStopPartial;

const FakeCompletion = test_support.FakeCompletion;
const FakeGateway = test_support.FakeGateway;
const FakeAgentRuntimeDeps = test_support.FakeAgentRuntimeDeps;
const FakeExecPlan = test_support.FakeExecPlan;
const PromptFixture = test_support.PromptFixture;
const StopTestHandler = test_support.StopTestHandler;

const runFakePrompt = test_support.runFakePrompt;
const runFakePromptWithLifecycle = test_support.runFakePromptWithLifecycle;
const registerStopTestHandler = test_support.registerStopTestHandler;
const testLifecycleContext = test_support.testLifecycleContext;
const finishCommonAssistantTerminal = runtime_orchestrator.finishCommonAssistantTerminal;
const expectBodyContains = test_support.expectBodyContains;
const expectBodyContainsInOrder = test_support.expectBodyContainsInOrder;
const expectBodyNotContains = test_support.expectBodyNotContains;
const countText = test_support.countText;
const countNeedle = test_support.countNeedle;
const readTraceFile = test_support.readTraceFile;
const textContains = test_support.textContains;
const logIndex = test_support.logIndex;
const toolCall = test_support.toolCall;

const PostTurnEndFinalizationCapture = struct {
    calls: usize = 0,
    turn_ids: [8]u64 = undefined,
    scope_kinds: [8]lifecycle_hooks.ScopeKind = undefined,
    workspace_matches: [8]bool = undefined,
    outcomes: [8]types.TurnPresentationOutcome = undefined,
    dispositions: [8]?types.ProviderCompletionDisposition = undefined,
    finish_event_attempts: [8]usize = undefined,
    deps: ?*FakeAgentRuntimeDeps = null,

    fn run(raw: *anyopaque, input: lifecycle_hooks.PostTurnEndInput) lifecycle_hooks.HandlerError!void {
        const self: *PostTurnEndFinalizationCapture = @ptrCast(@alignCast(raw));
        const index = self.calls;
        self.calls += 1;
        self.turn_ids[index] = input.invocation.turn_id orelse 0;
        self.scope_kinds[index] = input.invocation.scope.kind;
        self.workspace_matches[index] = std.mem.eql(
            u8,
            input.invocation.scope.workspace_root,
            "/tmp/workspace",
        );
        self.outcomes[index] = input.outcome;
        self.dispositions[index] = input.provider_disposition;
        self.finish_event_attempts[index] = if (self.deps) |deps|
            deps.finish_event_attempt_count
        else
            0;
    }
};

test "processQueuedPrompt preserves original final history before finish event" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{" **Hello** "};
    const completions = [_]FakeCompletion{.{
        .chunks = &chunks,
        .content = " **Hello** ",
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqualStrings(" **Hello** ", hooks.history_assistant_text.?);
    try std.testing.expectEqualStrings(" **Hello** ", hooks.finish_assistant_text.?);
    try std.testing.expectEqual(@as(?types.TurnPresentationOutcome, .completed), hooks.finish_terminal_outcome);
    const newline_idx = logIndex(&hooks, "text:newline").?;
    const finish_idx = logIndex(&hooks, "event:finish_prompt").?;
    try std.testing.expect(newline_idx < finish_idx);
    try expectBodyNotContains(&gateway, 0, "<turn_aborted>");
}

test "processQueuedPrompt propagates completed summary with durable history" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{
        .content = "complete",
        .usage = .{ .input_tokens = 12, .output_tokens = 34 },
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    const propagated_summary = types.historyTurnSummary(
        hooks.history_turns.items[0],
    ) orelse return error.TestExpectedTurnSummary;
    try std.testing.expectEqual(
        hooks.finish_summary.?,
        propagated_summary,
    );
}

test "processQueuedPrompt Esc after a missing finish ends the turn without synthesizing output" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .omit_finish = true }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    const config = fixture.config();
    // Esc while the request waits to retry ends the turn.
    hooks.cancel_on_auto_retry_status = config.cancel_flag;
    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    // Esc keeps the existing cancel branch: the turn is saved as interrupted.
    try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expect(hooks.history_turns.items[0] == .interrupted);
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expect(!textContains(&hooks, "Done."));
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
}

test "processQueuedPrompt Esc after partial text without finish proof keeps it interrupted" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{"Partial answer"};
    const completions = [_]FakeCompletion{.{
        .chunks = &chunks,
        .omit_finish = true,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    const config = fixture.config();
    // Esc while the request waits to retry ends the turn.
    hooks.cancel_on_auto_retry_status = config.cancel_flag;
    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expect(textContains(&hooks, "Partial answer"));
    try std.testing.expect(!textContains(&hooks, "Done."));
    try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expect(hooks.history_turns.items[0] == .interrupted);
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
}

test "processQueuedPrompt Esc after tool calls without finish proof runs none of them" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_write", "write_file", "{\"path\":\"a.txt\",\"content\":\"x\"}")};
    const completions = [_]FakeCompletion{.{
        .tool_calls = &calls,
        .omit_finish = true,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.agent_step_limit = 1;
    // Esc while the request waits to retry ends the turn.
    hooks.cancel_on_auto_retry_status = config.cancel_flag;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items[0].interrupted.execution.tool_steps.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
}

test "processQueuedPrompt preserves finish precedence over malformed argument recovery" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{.{
        .id = "call_bad",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    }};
    const Expected = enum {
        interrupted,
        model_error,
        length_limited,
    };
    const Case = struct {
        finish_reason: ?types.ProviderFinishReason = null,
        omit_finish: bool = false,
        expected: Expected,
    };
    // The retryable cases wait to resend; Esc during the wait ends the turn.
    const cases = [_]Case{
        .{ .omit_finish = true, .expected = .interrupted },
        .{ .finish_reason = .provider_error, .expected = .interrupted },
        .{ .finish_reason = .stop, .expected = .model_error },
        .{ .finish_reason = .length, .expected = .length_limited },
    };

    for (cases) |case| {
        const reply: FakeCompletion = .{
            .tool_calls = &calls,
            .finish_reason = case.finish_reason,
            .omit_finish = case.omit_finish,
        };
        // A cut-off reply with nothing usable is resent once with fx's limit;
        // the resend's own cut-off reply ends the turn.
        const completions = [_]FakeCompletion{ reply, reply };
        const requests: usize = if (case.expected == .length_limited) 2 else 1;
        var gateway = FakeGateway.init(alloc, completions[0..requests]);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        var fixture = PromptFixture{};

        const config = fixture.config();
        // Esc while the request waits to retry ends the turn.
        hooks.cancel_on_auto_retry_status = config.cancel_flag;
        switch (case.expected) {
            .interrupted => try runFakePrompt(&gateway, &hooks, config, fixture.job()),
            .model_error => try std.testing.expectError(
                error.ModelError,
                runFakePrompt(&gateway, &hooks, config, fixture.job()),
            ),
            .length_limited => try runFakePrompt(
                &gateway,
                &hooks,
                config,
                fixture.job(),
            ),
        }

        try std.testing.expectEqual(requests, gateway.request_bodies.items.len);
        try std.testing.expectEqual(@as(usize, 0), hooks.validated_names.items.len);
        try std.testing.expectEqual(@as(usize, 0), hooks.availability_checked_names.items.len);
        try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
        try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
        try std.testing.expectEqual(@as(usize, 0), hooks.rejected_names.items.len);

        if (case.expected == .length_limited) {
            try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
            try std.testing.expectEqual(
                @as(usize, 0),
                hooks.history_turns.items[0].assistant.execution.tool_steps.len,
            );
            const propagated_summary = types.historyTurnSummary(
                hooks.history_turns.items[0],
            ) orelse return error.TestExpectedTurnSummary;
            try std.testing.expectEqual(hooks.finish_summary.?, propagated_summary);
        } else if (case.expected == .interrupted) {
            try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
            try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items[0].interrupted.execution.tool_steps.len);
            try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
        } else {
            try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
        }
    }
}

test "processQueuedPrompt returns a final response after repeated tool failures" {
    const alloc = std.testing.allocator;
    const call_one = [_]ToolCall{toolCall("call_1", "read_file", "{\"path\":\"a\"}")};
    const call_two = [_]ToolCall{toolCall("call_2", "read_file", "{\"path\":\"b\"}")};
    const call_three = [_]ToolCall{toolCall("call_3", "read_file", "{\"path\":\"c\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &call_one },
        .{ .tool_calls = &call_two },
        .{ .tool_calls = &call_three },
        .{ .content = "Recovered after errors." },
    };
    const error_result = FakeExecPlan{ .result = .{ .model_output = "Tool read_file failed: bad" } };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.permission_decisions = &.{ .once, .once, .once };
    hooks.exec_plans = &.{ error_result, error_result, error_result };
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expect(!textContains(&hooks, "Agent stopped: 3 consecutive steps with all-error tool calls."));
    try std.testing.expectEqualStrings("Recovered after errors.", hooks.history_assistant_text.?);
    try std.testing.expectEqual(@as(usize, 3), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 3), hooks.executed_names.items.len);
}

test "processQueuedPrompt stops repeated malformed calls before another provider request" {
    const alloc = std.testing.allocator;
    const call_one = [_]ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    }};
    const call_two = [_]ToolCall{.{
        .id = "call_2",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    }};
    const call_three = [_]ToolCall{.{
        .id = "call_3",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    }};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &call_one },
        .{ .tool_calls = &call_two },
        .{ .tool_calls = &call_three },
        .{ .content = "must not be requested" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.agent_step_limit = 0;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    const notice = "Repeated malformed tool arguments stopped the agent loop. The invalid calls were not executed. Continue with a follow-up prompt if needed.";
    try std.testing.expectEqual(@as(usize, 3), gateway.request_bodies.items.len);
    try std.testing.expect(textContains(&hooks, notice));
    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
    try std.testing.expectEqual(types.TurnPresentationOutcome.failed, hooks.finalized_outcome.?);
    try std.testing.expectEqualStrings(notice, hooks.history_assistant_text.?);
    try std.testing.expectEqualStrings(notice, hooks.finish_assistant_text.?);
    try std.testing.expect(
        logIndex(&hooks, "event:turn_finished").? <
            logIndex(&hooks, "event:finish_prompt").?,
    );

    const execution = hooks.history_turns.items[0].assistant.execution;
    try std.testing.expectEqual(@as(usize, 3), execution.tool_steps.len);
    for (execution.tool_steps) |step| {
        try std.testing.expectEqual(@as(usize, 1), step.tool_calls.len);
        try std.testing.expectEqualStrings("{}", step.tool_calls[0].arguments_json);
        try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, step.tool_calls[0].argument_integrity);
        try std.testing.expectEqual(@as(usize, 1), step.tool_results.len);
        try std.testing.expectEqual(types.PersistedToolStatus.failure, step.tool_results[0].status);
        try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(step.tool_results[0].output));
        try std.testing.expectEqualStrings(step.tool_calls[0].id, step.tool_results[0].tool_call_id);
    }
    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
}

test "processQueuedPrompt continues with steering queued before a repeated-malformed terminal" {
    const alloc = std.testing.allocator;
    const call_one = [_]ToolCall{.{
        .id = "call_1",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    }};
    const call_two = [_]ToolCall{.{
        .id = "call_2",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    }};
    const call_three = [_]ToolCall{.{
        .id = "call_3",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    }};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &call_one },
        .{ .tool_calls = &call_two },
        .{ .tool_calls = &call_three },
        .{ .content = "Steered recovery answer" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const steering = [_][]const u8{"stop repeating the broken call"};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    // Step-top boundaries are takes 1-3; the terminal-exit boundary is take 4.
    hooks.steering_messages = &steering;
    hooks.steering_take_at = 4;
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    // The turn continued instead of ending: the fourth request carries the
    // queued steering, and the malformed-stop notice never rendered.
    try std.testing.expectEqual(@as(usize, 4), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 3, "user_steering");
    try expectBodyContains(&gateway, 3, "stop repeating the broken call");
    try std.testing.expect(!textContains(&hooks, "Repeated malformed tool arguments"));
    try std.testing.expectEqualStrings("Steered recovery answer", hooks.finish_assistant_text.?);
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, hooks.finalized_outcome.?);
    const execution = hooks.history_turns.items[0].assistant.execution;
    try std.testing.expectEqual(@as(usize, 1), execution.steering.len);
    try std.testing.expectEqualStrings("stop repeating the broken call", execution.steering[0].text);
}

test "processQueuedPrompt continues with steering queued before a length-limited tool completion" {
    const alloc = std.testing.allocator;
    const truncated_calls = [_]ToolCall{toolCall("len_call_1", "read_file", "{\"path\":\"a.txt\"}")};
    const completions = [_]FakeCompletion{
        .{ .content = "partial draft", .tool_calls = &truncated_calls, .finish_reason = .length },
        .{ .content = "Steered length recovery" },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    const steering = [_][]const u8{"narrow the scope"};
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    // Step-top boundary is take 1; the length-limited terminal boundary is take 2.
    hooks.steering_messages = &steering;
    hooks.steering_take_at = 2;
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try expectBodyContainsInOrder(&gateway, 1, &.{
        "partial draft",
        "user_steering",
        "narrow the scope",
    });
    try std.testing.expectEqualStrings("Steered length recovery", hooks.finish_assistant_text.?);
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, hooks.finalized_outcome.?);
}

test "processQueuedPrompt returns a final response after a repeated tool-name cycle" {
    const alloc = std.testing.allocator;
    const c1 = [_]ToolCall{toolCall("call_1", "read_file", "{\"path\":\"a\"}")};
    const c2 = [_]ToolCall{toolCall("call_2", "edit_file", "{\"path\":\"a\",\"old_string\":\"old\",\"new_string\":\"new\"}")};
    const c3 = [_]ToolCall{toolCall("call_3", "read_file", "{\"path\":\"b\"}")};
    const c4 = [_]ToolCall{toolCall("call_4", "edit_file", "{\"path\":\"b\",\"old_string\":\"old\",\"new_string\":\"new\"}")};
    const c5 = [_]ToolCall{toolCall("call_5", "read_file", "{\"path\":\"c\"}")};
    const c6 = [_]ToolCall{toolCall("call_6", "edit_file", "{\"path\":\"c\",\"old_string\":\"old\",\"new_string\":\"new\"}")};
    const completions = [_]FakeCompletion{
        .{ .tool_calls = &c1 },
        .{ .tool_calls = &c2 },
        .{ .tool_calls = &c3 },
        .{ .tool_calls = &c4 },
        .{ .tool_calls = &c5 },
        .{ .tool_calls = &c6 },
        .{ .content = "Recovered after cycle." },
    };
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.permission_decisions = &.{ .once, .once, .once, .once, .once, .once };
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

    try std.testing.expect(!textContains(&hooks, "Agent stopped: detected repeating tool call cycle."));
    try std.testing.expectEqualStrings("Recovered after cycle.", hooks.history_assistant_text.?);
    try std.testing.expectEqual(@as(usize, 6), hooks.permission_names.items.len);
}

test "processQueuedPrompt step limit pushes configured notice and finish event" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_1", "read_file", "{\"path\":\"a\"}")};
    const completions = [_]FakeCompletion{.{ .tool_calls = &calls }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.agent_step_limit = 1;
    config.step_limit_notice = "custom limit";

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expect(textContains(&hooks, "custom limit"));
    try std.testing.expectEqualStrings("custom limit", hooks.history_assistant_text.?);
    try std.testing.expectEqualStrings("custom limit", hooks.finish_assistant_text.?);
    const propagated_summary = types.historyTurnSummary(
        hooks.history_turns.items[0],
    ) orelse return error.TestExpectedTurnSummary;
    try std.testing.expectEqual(hooks.finish_summary.?, propagated_summary);
    try std.testing.expect(hooks.finalized_disposition == null);
}

test "processQueuedPrompt step limit persists malformed argument failure execution" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{.{
        .id = "call_bad",
        .name = "read_file",
        .arguments_json = "{}",
        .argument_integrity = .malformed_json,
    }};
    const completions = [_]FakeCompletion{.{ .tool_calls = &calls }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.agent_step_limit = 1;
    config.step_limit_notice = "custom limit";

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    const execution = hooks.history_turns.items[0].assistant.execution;
    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
    try std.testing.expectEqualStrings("{}", execution.tool_steps[0].tool_calls[0].arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.valid, execution.tool_steps[0].tool_calls[0].argument_integrity);
    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps[0].tool_results.len);
    try std.testing.expectEqual(types.PersistedToolStatus.failure, execution.tool_steps[0].tool_results[0].status);
    try std.testing.expect(tool_result_errors.isToolExecutionFailedOutput(execution.tool_steps[0].tool_results[0].output));
    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
}

test "finalization sink failure makes guard fatal and suppresses finish payload" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "Final" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    hooks.finalization_error = error.TurnFinalizationDeliveryFailed;
    defer hooks.deinit();
    var fixture = PromptFixture{};

    try std.testing.expectError(
        error.TurnFinalizationDeliveryFailed,
        runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job()),
    );

    try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
}

test "processQueuedPrompt terminal outcomes finalize exactly once before optional finish" {
    const alloc = std.testing.allocator;
    const cases = [_]struct {
        completion: FakeCompletion,
        outcome: types.TurnPresentationOutcome,
        finish_count: usize,
        propagates_error: bool = false,
    }{
        .{ .completion = .{ .content = "Final" }, .outcome = .completed, .finish_count = 1 },
        .{ .completion = .{ .cancel_before_output = true }, .outcome = .interrupted, .finish_count = 1 },
        .{ .completion = .{ .status = .bad_request, .err_body = "bad" }, .outcome = .failed, .finish_count = 0 },
        .{ .completion = .{ .stream_error = error.TestProviderFailure }, .outcome = .failed, .finish_count = 0, .propagates_error = true },
    };
    for (cases) |case| {
        const completions = [_]FakeCompletion{case.completion};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        var fixture = PromptFixture{};
        if (case.propagates_error) {
            try std.testing.expectError(
                error.TestProviderFailure,
                runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job()),
            );
        } else {
            try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());
        }
        try std.testing.expectEqual(@as(usize, 1), hooks.finalization_count);
        try std.testing.expectEqual(case.outcome, hooks.finalized_outcome.?);
        try std.testing.expectEqual(case.finish_count, hooks.finish_event_count);
        if (case.finish_count > 0) {
            try std.testing.expect(
                logIndex(&hooks, "event:turn_finished").? <
                    logIndex(&hooks, "event:finish_prompt").?,
            );
        }
    }
}

test "a cancelled turn is reported before the commands steering detached are stopped" {
    const alloc = std.testing.allocator;
    for ([_]bool{ true, false }) |explicit_cancel| {
        const completions = [_]FakeCompletion{.{ .cancel_before_output = true }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        hooks.steering_detached_explicit_cancel = explicit_cancel;
        var fixture = PromptFixture{};
        try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());

        try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, hooks.finalized_outcome.?);
        // Asked before the report: a prompt typed once the turn is reported
        // can join its ending as steering.
        const asked = logIndex(&hooks, "hook:explicit_cancel").?;
        const reported = logIndex(&hooks, "event:turn_finished").?;
        const finished = logIndex(&hooks, "event:finish_prompt").?;
        try std.testing.expect(asked < reported);
        // A stop that waits seconds on a stubborn command never holds the
        // turn's end, and a turn steering ended stops nothing.
        if (logIndex(&hooks, "hook:stop_steering_detached")) |stopped| {
            try std.testing.expect(explicit_cancel);
            try std.testing.expect(finished < stopped);
        } else try std.testing.expect(!explicit_cancel);
    }
}

test "an Interrupt hook runs once when the user stops the turn" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    // Each run appends a line, so the file shows how many times the hook ran.
    const marker_path = try std.Io.Dir.path.join(arena, &.{ user_fixture.workspace, "interrupt_marker.txt" });
    const hooks_json = try arena.print(
        "{{\"hooks\":{{\"Interrupt\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"echo ran >> '{s}'\"}}]}}]}}}}",
        .{marker_path},
    );
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();

    const completions = [_]FakeCompletion{.{ .cancel_before_output = true }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    // The host says the cancel came from the user, not from steering.
    deps.steering_detached_explicit_cancel = true;
    var fixture = PromptFixture{};
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);

    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, deps.finalized_outcome.?);
    const marker = try readTraceFile(alloc, marker_path, 4096);
    defer alloc.free(marker);
    try std.testing.expectEqualStrings("ran\n", marker);
}

test "an Interrupt hook does not run for a steering interruption" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const marker_path = try std.Io.Dir.path.join(arena, &.{ user_fixture.workspace, "interrupt_marker.txt" });
    const hooks_json = try arena.print(
        "{{\"hooks\":{{\"Interrupt\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"echo ran >> '{s}'\"}}]}}]}}}}",
        .{marker_path},
    );
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();

    const completions = [_]FakeCompletion{.{ .cancel_before_output = true }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    // The host says steering ended the turn, so the cancel is not the user's.
    deps.steering_detached_explicit_cancel = false;
    var fixture = PromptFixture{};
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);

    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, deps.finalized_outcome.?);
    const ran = if (readTraceFile(alloc, marker_path, 4096)) |marker| blk: {
        alloc.free(marker);
        break :blk true;
    } else |_| false;
    try std.testing.expect(!ran);
}

test "a turn that completes never asks to stop steering-detached commands" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .content = "Final" }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.steering_detached_explicit_cancel = true;
    var fixture = PromptFixture{};
    try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, hooks.finalized_outcome.?);
    try std.testing.expect(logIndex(&hooks, "hook:explicit_cancel") == null);
    try std.testing.expect(logIndex(&hooks, "hook:stop_steering_detached") == null);
}

test "partial stream failure persists failed terminal reason" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{
        .chunks = &.{"partial response"},
        .stream_error_after_chunks = error.TestProviderFailure,
    }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.gateway_retry_count = 0;

    try std.testing.expectError(
        error.TestProviderFailure,
        runFakePrompt(&gateway, &hooks, config, fixture.job()),
    );

    try std.testing.expectEqual(@as(usize, 1), hooks.history_turns.items.len);
    try std.testing.expect(hooks.history_turns.items[0] == .interrupted);
    try std.testing.expectEqual(
        types.InterruptedTerminalReason.failed,
        hooks.history_turns.items[0].interrupted.terminal_reason,
    );
    try std.testing.expectEqual(types.TurnPresentationOutcome.failed, hooks.finalized_outcome.?);
}

test "processQueuedPrompt emits exactly one structured prompt finish per terminal outcome" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "finish-trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTestWithScopes(alloc, trace_path, "agent");

    {
        const completions = [_]FakeCompletion{.{ .content = "Final" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        var fixture = PromptFixture{};
        try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());
    }

    {
        const completions = [_]FakeCompletion{.{ .cancel_before_output = true }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        var fixture = PromptFixture{};
        try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());
    }

    {
        const completions = [_]FakeCompletion{.{ .status = .bad_request, .err_body = "bad" }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        var fixture = PromptFixture{};
        try runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());
    }

    {
        const completions = [_]FakeCompletion{.{ .stream_error = error.TestProviderFailure }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        var fixture = PromptFixture{};
        try std.testing.expectError(error.TestProviderFailure, runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job()));
    }

    debug_trace.shutdown();
    const trace = try readTraceFile(alloc, trace_path, 65536);
    defer alloc.free(trace);

    try std.testing.expectEqual(@as(usize, 4), countNeedle(trace, " event=prompt_finish "));
    try std.testing.expectEqual(@as(usize, 1), countNeedle(trace, "outcome_kind=assistant"));
    try std.testing.expectEqual(@as(usize, 1), countNeedle(trace, "outcome_kind=interrupted"));
    try std.testing.expectEqual(@as(usize, 2), countNeedle(trace, "outcome_kind=http_error"));
    try std.testing.expectEqual(@as(usize, 0), countNeedle(trace, "event=prompt_finish_duplicate"));
}

test "processQueuedPrompt step limit writes active debug trace" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ root, "trace.log" });
    defer alloc.free(trace_path);

    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);

    const calls = [_]ToolCall{toolCall("call_1", "read_file", "{\"path\":\"a\"}")};
    const completions = [_]FakeCompletion{.{ .tool_calls = &calls }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.agent_step_limit = 1;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());
    debug_trace.shutdown();

    var trace_file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), trace_path, .{});
    defer trace_file.close(io_mod.getIo());
    const trace = try io_mod.readFileToEnd(alloc, &trace_file, 8192);
    defer alloc.free(trace);

    try std.testing.expect(std.mem.find(u8, trace, "[agent] step start step=1 limit=1") != null);
    try std.testing.expect(std.mem.find(u8, trace, "[agent] step completion step=1") != null);
    try std.testing.expect(std.mem.find(u8, trace, "[agent] step limit reached turn_id=1 step_id=1 step_index=1 step_limit=1 gateway_messages=3 completed_tool_count=1 completed_tool_names=read_file last_tool_call_name=read_file last_tool_call_id=call_1 outcome_kind=step_limit") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=step_limit_reached turn_id=1 step_id=1 step_index=1 step_limit=1 gateway_messages=3 completed_tool_count=1 completed_tool_names=read_file last_tool_call_name=read_file last_tool_call_id=call_1 outcome_kind=step_limit") != null);
    try std.testing.expect(std.mem.find(u8, trace, "{\"path\":\"a\"}") == null);
}

test "common Stop natural completion allows and preserves disposition" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{
            .content = "candidate",
            .finish_reason = .length,
        },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .allow,
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        fixture.config(),
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expectEqualStrings("candidate", handler.seen_text.?);
    try std.testing.expectEqual(@as(usize, 1), handler.seen_step_index);
    try std.testing.expect(handler.seen_can_continue);
    try std.testing.expectEqual(
        types.ProviderCompletionDisposition.length_limited,
        handler.seen_disposition.?,
    );
    try std.testing.expectEqualStrings(
        "candidate",
        deps.history_turns.items[0].assistant.execution.tool_steps[0].assistant.?,
    );
    try std.testing.expectEqual(
        types.ProviderCompletionDisposition.length_limited,
        deps.finalized_disposition.?,
    );
}

test "common Stop cancellation and failure preserve original replay" {
    const alloc = std.testing.allocator;
    var failures: usize = 0;
    for (0..6) |iteration| {
        const cancel = iteration % 2 == 0;
        const first_replay = iteration % 4 < 2;
        const partial = if (iteration < 4) "PARTIAL_963" else "";
        var gateway = FakeGateway.init(alloc, &.{
            .{ .content = "CANDIDATE_741", .provider_state_json = if (first_replay) "[{\"type\":\"reasoning\",\"text\":\"FIRST_PRIVATE_STATE\"}]" else null },
            .{ .chunks = &.{partial}, .cancel_after_chunks = cancel, .stream_error_after_chunks = if (cancel) null else error.TestProviderFailure },
        });
        defer gateway.deinit();
        var deps = FakeAgentRuntimeDeps.init(alloc);
        defer deps.deinit();
        var fixture = PromptFixture{};
        var runtime = lifecycle_hooks.Runtime.init(alloc);
        defer runtime.deinit();
        var handler = StopTestHandler{ .alloc = alloc, .action = .{ .continue_once = "verify" } };
        defer handler.deinit();
        const view = try registerStopTestHandler(&runtime, &handler);
        const config = fixture.config();
        runFakePromptWithLifecycle(&gateway, &deps, config, fixture.job(), testLifecycleContext(view, alloc, fixture.workspace_root)) catch |err| {
            if (err != error.TestProviderFailure) return err;
        };
        var candidates: usize = 0;
        var replay_count: usize = 0;
        for (deps.history_turns.items) |history| {
            const execution = switch (history) {
                .assistant => |entry| entry.execution,
                .interrupted => |entry| entry.execution,
                else => types.ExecutionMemory{},
            };
            for (execution.tool_steps) |step| if (step.provider_replay) |replay| {
                if (std.mem.find(u8, replay.parts_json, "FIRST_PRIVATE_STATE") != null) replay_count += 1;
            };
            switch (history) {
                .assistant => |entry| {
                    candidates += std.mem.count(u8, entry.assistant, "CANDIDATE_741");
                    for (entry.execution.tool_steps) |step| candidates += std.mem.count(u8, step.assistant orelse "", "CANDIDATE_741");
                },
                .interrupted => |entry| {
                    candidates += std.mem.count(u8, entry.assistant orelse "", "CANDIDATE_741");
                    for (entry.execution.tool_steps) |step| candidates += std.mem.count(u8, step.assistant orelse "", "CANDIDATE_741");
                },
                else => {},
            }
        }
        const pass = candidates == 1 and replay_count == @intFromBool(first_replay) and deps.finalized_outcome != .completed;
        if (!pass) failures += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "common Stop preserves both original replies with optional replay" {
    const alloc = std.testing.allocator;
    var successes: usize = 0;
    for (0..5) |iteration| {
        const first_replay = (iteration % 4) < 2;
        const last_replay = (iteration % 2) == 0;
        const final_text = if (iteration == 4) "CANDIDATE_741" else "FINAL_852";
        const first_state = "[{\"type\":\"reasoning\",\"text\":\"FIRST_REPLAY_PRIVATE\"}]";
        const last_state = "[{\"type\":\"reasoning\",\"text\":\"FINAL_REPLAY_PRIVATE\"}]";
        var gateway = FakeGateway.init(alloc, &.{
            .{ .chunks = &.{"CANDIDATE_741"}, .content = "CANDIDATE_741", .provider_state_json = if (first_replay) first_state else null },
            .{ .content = final_text, .provider_state_json = if (last_replay) last_state else null },
        });
        defer gateway.deinit();
        var deps = FakeAgentRuntimeDeps.init(alloc);
        defer deps.deinit();
        var fixture = PromptFixture{};
        var hooks_runtime = lifecycle_hooks.Runtime.init(alloc);
        defer hooks_runtime.deinit();
        var handler = StopTestHandler{ .alloc = alloc, .action = .{ .continue_once = "verify the answer" } };
        defer handler.deinit();
        const view = try registerStopTestHandler(&hooks_runtime, &handler);
        try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), testLifecycleContext(view, alloc, fixture.workspace_root));
        const turn = deps.history_turns.items[0].assistant;
        var pass = gateway.request_bodies.items.len == 2 and handler.calls == 1 and
            std.mem.eql(u8, turn.assistant, final_text) and
            (turn.provider_replay != null) == last_replay and
            turn.execution.tool_steps.len == 1;
        if (turn.provider_replay) |replay| pass = pass and std.mem.eql(u8, replay.parts_json, last_state);
        if (turn.execution.tool_steps.len == 1) {
            const first = turn.execution.tool_steps[0];
            pass = pass and std.mem.eql(u8, first.assistant orelse "", "CANDIDATE_741") and
                (first.provider_replay != null) == first_replay and first.tool_calls.len == 0 and first.tool_results.len == 0;
            if (first.provider_replay) |replay| pass = pass and std.mem.eql(u8, replay.parts_json, first_state);
        }
        if (pass) successes += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), successes);
}

test "common Stop continues once with original history and joined presentation" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{ .chunks = &.{"candidate"}, .content = "candidate" },
        .{ .content = "final" },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify the answer" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        fixture.config(),
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 1, "candidate");
    try expectBodyContains(
        &gateway,
        1,
        "Continue the turn. fx hook context:\\nverify the answer",
    );
    try std.testing.expectEqualStrings(
        "candidate\nfinal",
        deps.finish_presentation_text.?,
    );
    const original = deps.history_turns.items[0].assistant;
    try std.testing.expectEqualStrings("final", original.assistant);
    try std.testing.expectEqual(@as(usize, 1), original.execution.tool_steps.len);
    try std.testing.expectEqualStrings("candidate", original.execution.tool_steps[0].assistant.?);

    var follow_gateway = FakeGateway.init(alloc, &.{
        .{ .content = "follow-up" },
    });
    defer follow_gateway.deinit();
    var follow_deps = FakeAgentRuntimeDeps.init(alloc);
    defer follow_deps.deinit();
    var follow_fixture = PromptFixture{};
    var follow_job = follow_fixture.job();
    follow_job.history = deps.history_turns.items;
    try runFakePrompt(
        &follow_gateway,
        &follow_deps,
        follow_fixture.config(),
        follow_job,
    );
    try expectBodyContains(&follow_gateway, 0, "candidate");
    try expectBodyContains(&follow_gateway, 0, "final");
    // The hook's message was in the last request of the turn, so the saved
    // turn keeps it where it was sent and the provider's prompt cache still
    // covers that request.
    try expectBodyContainsInOrder(&follow_gateway, 0, &.{
        "candidate",
        "Continue the turn. fx hook context:\\nverify the answer",
        "final",
    });
    try test_support.expectPromptExtends(
        gateway.request_bodies.items[1],
        follow_gateway.request_bodies.items[0],
    );
}

/// A temp profile and workspace for a user hooks runtime, set up as the user-hook tests set them up.
const UserStopFixture = struct {
    tmp: std.testing.TmpDir,
    home: []u8,
    workspace: []u8,
    env: std.process.Environ.Map,

    fn init(alloc: std.mem.Allocator) !UserStopFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
        try tmp.dir.createDirPath(io_mod.getIo(), "workspace");
        const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "home");
        errdefer alloc.free(home);
        const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "workspace");
        errdefer alloc.free(workspace);
        var env = std.process.Environ.Map.init(alloc);
        errdefer env.deinit();
        try env.put("PATH", "/usr/bin:/bin");
        return .{ .tmp = tmp, .home = home, .workspace = workspace, .env = env };
    }

    fn deinit(self: *UserStopFixture, alloc: std.mem.Allocator) void {
        alloc.free(self.home);
        alloc.free(self.workspace);
        self.env.deinit();
        self.tmp.cleanup();
        self.* = undefined;
    }

    /// Writes the profile's hooks file, then starts a user hooks runtime that reads it.
    fn startRuntime(self: *UserStopFixture, alloc: std.mem.Allocator, hooks_json: []const u8) !runtime_lifecycle.UserHooksRuntime {
        const file_path = try profile_paths.rootPath(alloc, self.home, &.{"hooks.json"});
        defer alloc.free(file_path);
        try io_mod.writeFileAtomic(alloc, file_path, hooks_json);
        try std.Io.Dir.cwd().setFilePermissions(io_mod.getIo(), file_path, std.Io.File.Permissions.fromMode(0o600), .{});
        try self.trustHooks(alloc, hooks_json);
        var runtime = try runtime_lifecycle.UserHooksRuntime.init(alloc, .{
            .enabled = true,
            .home = self.home,
            .workspace_root = self.workspace,
        });
        runtime.native.base_env = &self.env;
        runtime.refresh();
        return runtime;
    }

    /// Trusts every hook in `hooks_json`, as `fx hook trust --all` does, so the runtime runs them. The digests
    /// come from the trust API, and the file keeps the trust it already has.
    fn trustHooks(self: *const UserStopFixture, alloc: std.mem.Allocator, hooks_json: []const u8) !void {
        var parsed = try hooks_engine.config.parse(alloc, hooks_json, .{ .layer = .profile, .workspace_root = self.workspace });
        defer parsed.deinit(alloc);
        const trust_file = try hooks_host.trust.path(alloc, self.home);
        defer alloc.free(trust_file);
        var store = try hooks_host.trust.load(alloc, trust_file);
        defer store.deinit(alloc);
        for (parsed.hooks) |*hook| {
            var named = try hooks_host.trust.namedFiles(alloc, hook.command, self.workspace, self.home);
            defer named.deinit(alloc);
            const value = try hooks_host.trust.digest(alloc, hook, self.workspace, named.files);
            try store.add(alloc, value, hook.id);
        }
        try hooks_host.trust.save(alloc, trust_file, &store);
    }
};

const overflow_model = "provider/context-overflow-recovery";
const overflow_capabilities = [_]test_support.ModelCapabilityOverride{.{
    .model = overflow_model,
    .capabilities = .{ .context_window = 128_000, .max_output_tokens = 16_384 },
}};
const overflow_error_body = "{\"error\":{\"message\":\"AI_APICallError: Your input exceeds the context window of this model.\"}}";
const overflow_completions = [_]FakeCompletion{
    .{ .status = .bad_request, .err_body = overflow_error_body },
    .{ .content = "Retain the completed prior turn and continue from it." },
    .{ .content = "CONTEXT_OVERFLOW_RECOVERED" },
};

/// Runs a turn with one prior tool turn whose first request overflows the context window.
/// The turn compacts once and retries, unless a PreCompact hook blocks the compaction.
fn runOverflowTurn(gateway: *FakeGateway, deps: *FakeAgentRuntimeDeps, lifecycle: runtime_lifecycle.LifecycleContext) !void {
    deps.available_capability_overrides = &overflow_capabilities;
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.model = @constCast(overflow_model);
    var prior_calls = [_]ToolCall{toolCall("prior-read", "read_file", "{\"path\":\"notes.md\"}")};
    var prior_results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("prior-read"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("HOOK_PRIOR_TOOL_OUTPUT"),
        .output_bytes = 22,
        .stored_output_bytes = 22,
    }};
    var prior_steps = [_]types.ToolExecutionStep{.{ .tool_calls = &prior_calls, .tool_results = &prior_results }};
    var history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("HOOK_PRIOR_USER") },
        .assistant = @constCast("HOOK_PRIOR_ASSISTANT"),
        .execution = .{ .tool_steps = &prior_steps },
    } }};
    job.history = &history;
    try runFakePromptWithLifecycle(gateway, deps, fixture.config(), job, lifecycle);
}

test "a PreCompact hook blocks an automatic compaction" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const marker = try std.Io.Dir.path.join(alloc, &.{ user_fixture.workspace, "block.txt" });
    defer alloc.free(marker);
    const command = try std.mem.concat(alloc, u8, &.{ "echo ran >> '", marker, "'; echo 'no compaction now' >&2; exit 2" });
    defer alloc.free(command);
    const hooks_json = try startEventHooksJson(alloc, "PreCompact", command);
    defer alloc.free(hooks_json);
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &overflow_completions);
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;
    lifecycle.scope.session_id = "session-1";

    // With the compaction blocked, the overflow stays unresolved and the turn fails before any retry.
    runOverflowTurn(&gateway, &deps, lifecycle) catch |err| try std.testing.expect(err == error.ContextCapacityExceeded);
    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    const written = try readHookOutput(alloc, &user_fixture, "workspace/block.txt");
    defer alloc.free(written);
    try std.testing.expectEqualStrings("ran\n", written);
    var noticed = false;
    for (deps.system_notices.items) |notice| {
        if (std.mem.find(u8, notice, "A hook blocked this compaction") != null) noticed = true;
    }
    try std.testing.expect(noticed);
    for (deps.history_turns.items) |turn| try std.testing.expect(turn != .compacted_summary);
}

test "PreCompact context reaches the summary request" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const hooks_json = try startEventHooksJson(alloc, "PreCompact", "printf '%s' 'keep the file names'");
    defer alloc.free(hooks_json);
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &overflow_completions);
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;
    lifecycle.scope.session_id = "session-1";

    try runOverflowTurn(&gateway, &deps, lifecycle);
    // Request 1 is the summary request; the hook's context is its instructions.
    try expectBodyContains(&gateway, 1, "Additional instructions for this summary:\\nkeep the file names");
}

test "a PostCompact hook runs once after a compaction" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const marker = try std.Io.Dir.path.join(alloc, &.{ user_fixture.workspace, "post.txt" });
    defer alloc.free(marker);
    const command = try std.mem.concat(alloc, u8, &.{ "printf '%s\\n' \"$(cat)\" >> '", marker, "'" });
    defer alloc.free(command);
    const hooks_json = try startEventHooksJson(alloc, "PostCompact", command);
    defer alloc.free(hooks_json);
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &overflow_completions);
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;
    lifecycle.scope.session_id = "session-1";

    try runOverflowTurn(&gateway, &deps, lifecycle);
    // The overflow, the summary and the retry: three requests.
    try std.testing.expectEqual(@as(usize, 3), gateway.request_bodies.items.len);
    // Fails by name when the hook left no marker: the hook file did not load, or PostCompact did not run.
    var marker_file = user_fixture.tmp.dir.openFile(io_mod.getIo(), "workspace/post.txt", .{}) catch |err| {
        std.debug.print("PostCompact left no marker ({s}): its hook did not run after the committed compaction\n", .{@errorName(err)});
        return error.PostCompactMarkerMissing;
    };
    defer marker_file.close(io_mod.getIo());
    const written = try io_mod.readFileToEnd(alloc, &marker_file, 65536);
    defer alloc.free(written);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\n"));
    try std.testing.expect(std.mem.find(u8, written, "\"trigger\":\"auto\"") != null);
}

test "a PostModelSwitch note reaches the next turn once" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const hooks_json = try startEventHooksJson(alloc, "PostModelSwitch", "printf '%s' 'the new model is faster'");
    defer alloc.free(hooks_json);
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;
    lifecycle.scope.session_id = "session-1";

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    _ = runtime_user_hooks.postModelSwitch(lifecycle, arena_state.allocator(), "provider/a", "provider/b");

    var gateway = FakeGateway.init(alloc, &.{ .{ .content = "first" }, .{ .content = "second" } });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);
    try expectBodyContains(&gateway, 0, "the new model is faster");
    // Turn two starts from turn one's saved turn, as a resumed session does.
    var follow_job = fixture.job();
    follow_job.history = deps.history_turns.items;
    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), follow_job, lifecycle);
    // The note is saved with turn one as steering, so turn two's request carries it from history, once.
    // Its context is not queued again.
    try expectBodyContains(&gateway, 1, "the new model is faster");
    try std.testing.expectEqual(@as(usize, 1), countNeedle(gateway.request_bodies.items[1], "the new model is faster"));
}

/// Asks for one more turn only while the check is not already a continuation.
const stop_continue_once_script =
    \\input=$(cat)
    \\case "$input" in
    \\  *'"stop_hook_active":true'*) printf '%s' '{}' ;;
    \\  *) printf '%s' '{"decision":"block","reason":"check the tests"}' ;;
    \\esac
    \\
;

/// A Stop hook that always asks for another turn.
const stop_always_continue_file =
    \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"printf '%s' '{\"decision\":\"block\",\"reason\":\"again\"}'"}]}]}}
;

/// How many times `needle` appears in a saved assistant turn: its reply and the text of each tool step.
fn countInSavedAssistant(turn: types.AssistantHistoryTurn, needle: []const u8) usize {
    var total = countNeedle(turn.assistant, needle);
    for (turn.execution.tool_steps) |step| {
        if (step.assistant) |text| total += countNeedle(text, needle);
    }
    return total;
}

test "a user Stop hook makes the turn continue once" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const script_path = try std.Io.Dir.path.join(arena, &.{ user_fixture.workspace, "stop.sh" });
    try io_mod.writeFileAtomic(alloc, script_path, stop_continue_once_script);
    const hooks_json = try arena.print(
        "{{\"hooks\":{{\"Stop\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"sh '{s}'\"}}]}}]}}}}",
        .{script_path},
    );
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();

    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "first reply" },
        .{ .content = "second reply" },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 1, "check the tests");
    try std.testing.expectEqualStrings("second reply", deps.history_turns.items[0].assistant.assistant);
    // The first reply is saved once, in the turn's tool steps, not again as the final reply.
    try std.testing.expectEqual(@as(usize, 1), countInSavedAssistant(deps.history_turns.items[0].assistant, "first reply"));
}

test "a user Stop hook continues at most three times per turn" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    var runtime = try user_fixture.startRuntime(alloc, stop_always_continue_file);
    defer runtime.deinit();

    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "reply 1" },
        .{ .content = "reply 2" },
        .{ .content = "reply 3" },
        .{ .content = "reply 4" },
        .{ .content = "reply 5" },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);

    // One model call for the first reply and one for each of the three continuations.
    try std.testing.expectEqual(@as(usize, 4), gateway.request_bodies.items.len);
    try std.testing.expectEqualStrings("reply 4", deps.history_turns.items[0].assistant.assistant);
}

test "a user Stop hook makes a terminal completion continue once" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const script_path = try std.Io.Dir.path.join(arena, &.{ user_fixture.workspace, "stop.sh" });
    try io_mod.writeFileAtomic(alloc, script_path, stop_continue_once_script);
    const hooks_json = try arena.print(
        "{{\"hooks\":{{\"Stop\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"sh '{s}'\"}}]}}]}}}}",
        .{script_path},
    );
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();

    // The first reply ran a provider tool and stops, so it is a terminal provider completion.
    const provider_calls = [_]ToolCall{.{
        .id = "call_search",
        .name = "perplexity_search",
        .arguments_json = "{}",
        .provider_result = "search result",
        .provenance = .provider_executed,
    }};
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate", .tool_calls = &provider_calls, .finish_reason = .stop },
        .{ .content = "final" },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);

    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 1, "check the tests");
    try std.testing.expectEqualStrings("final", deps.history_turns.items[0].assistant.assistant);
    // The first reply is saved once, in the turn's tool steps, not again as the final reply.
    try std.testing.expectEqual(@as(usize, 1), countInSavedAssistant(deps.history_turns.items[0].assistant, "candidate"));
}

test "a UserPromptSubmit hook blocks a prompt before the model" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    var runtime = try user_fixture.startRuntime(alloc,
        \\{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"printf '%s' 'no secrets' >&2; exit 2"}]}]}}
    );
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &.{.{ .content = "unused" }});
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);

    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 1), deps.system_notices.items.len);
    try std.testing.expectEqualStrings("A hook blocked this prompt: no secrets", deps.system_notices.items[0]);
    try std.testing.expectEqual(@as(usize, 0), deps.history_turns.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.failed, deps.finalized_outcome.?);
}

test "a UserPromptSubmit hook rewrites the prompt the model sees" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    var runtime = try user_fixture.startRuntime(alloc,
        \\{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"updatedPrompt\":\"say hi\"}}'"}]}]}}
    );
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &.{.{ .content = "answer" }});
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.prompt = @constCast("ORIGINAL_PROMPT_42");
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), job, lifecycle);

    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    try std.testing.expect(std.mem.find(u8, gateway.request_bodies.items[0], "say hi") != null);
    try std.testing.expect(std.mem.find(u8, gateway.request_bodies.items[0], "ORIGINAL_PROMPT_42") == null);
}

test "a UserPromptSubmit hook adds context only to the model's message" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    var runtime = try user_fixture.startRuntime(alloc,
        \\{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"printf '%s' 'use British spelling'"}]}]}}
    );
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &.{.{ .content = "answer" }});
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.prompt = @constCast("my prompt");
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), job, lifecycle);

    try expectBodyContains(&gateway, 0, "use British spelling");
    try expectBodyContains(&gateway, 0, "UserPromptSubmit");
    try std.testing.expectEqualStrings("my prompt", deps.history_turns.items[0].assistant.user.text);
}

test "UserPromptSubmit does not run for a subagent turn" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    var runtime = try user_fixture.startRuntime(alloc,
        \\{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"printf '%s' 'no secrets' >&2; exit 2"}]}]}}
    );
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &.{.{ .content = "answer" }});
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.origin = .subagent;
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, config, fixture.job(), lifecycle);

    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 0), deps.system_notices.items.len);
}

test "a UserPromptSubmit hook blocks a prompt with its reason" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    var runtime = try user_fixture.startRuntime(alloc,
        \\{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"printf '%s' 'no secrets' >&2; exit 2"}]}]}}
    );
    defer runtime.deinit();
    var fake = FakeAgentRuntimeDeps.init(alloc);
    defer fake.deinit();
    var runtime_deps = fake.deps();
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;
    var hooks = runtime_user_hooks.TurnHooks.init(lifecycle, &runtime_deps, 1, null);

    const applied = hooks.userPromptSubmit(arena, "my prompt");
    try std.testing.expectEqualStrings("A hook blocked this prompt: no secrets", applied.blocked_notice.?);
    try std.testing.expect(applied.prompt == null);
    try std.testing.expect(applied.context == null);
}

test "a UserPromptSubmit hook rewrites a prompt" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    var runtime = try user_fixture.startRuntime(alloc,
        \\{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"updatedPrompt\":\"say hi\"}}'"}]}]}}
    );
    defer runtime.deinit();
    var fake = FakeAgentRuntimeDeps.init(alloc);
    defer fake.deinit();
    var runtime_deps = fake.deps();
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;
    var hooks = runtime_user_hooks.TurnHooks.init(lifecycle, &runtime_deps, 1, null);

    const applied = hooks.userPromptSubmit(arena, "my prompt");
    try std.testing.expectEqualStrings("say hi", applied.prompt.?);
    try std.testing.expect(applied.blocked_notice == null);
    try std.testing.expect(applied.context == null);
}

test "a UserPromptSubmit hook adds framed context to the prompt" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    var runtime = try user_fixture.startRuntime(alloc,
        \\{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"printf '%s' 'use British spelling'"}]}]}}
    );
    defer runtime.deinit();
    var fake = FakeAgentRuntimeDeps.init(alloc);
    defer fake.deinit();
    var runtime_deps = fake.deps();
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;
    var hooks = runtime_user_hooks.TurnHooks.init(lifecycle, &runtime_deps, 1, null);

    const applied = hooks.userPromptSubmit(arena, "my prompt");
    try std.testing.expectEqualStrings(
        "<hook-context event=\"UserPromptSubmit\">\nuse British spelling\n</hook-context>",
        applied.context.?,
    );
    try std.testing.expect(applied.prompt == null);
    try std.testing.expect(applied.blocked_notice == null);
}

test "a StopFailure hook sees a failed model request" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    // The hook appends its input, so a second run would show up as a second copy.
    const seen_path = try std.Io.Dir.path.join(arena, &.{ user_fixture.workspace, "stop_failure_input.json" });
    const hooks_json = try arena.print(
        "{{\"hooks\":{{\"StopFailure\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"cat >> '{s}'\"}}]}}]}}}}",
        .{seen_path},
    );
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();

    var gateway = FakeGateway.init(alloc, &.{.{ .status = .bad_request, .err_body = "bad" }});
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);

    const seen = try readTraceFile(alloc, seen_path, 65536);
    defer alloc.free(seen);
    try std.testing.expectEqual(@as(usize, 1), countNeedle(seen, "\"hook_event_name\":\"StopFailure\""));
    try std.testing.expect(std.mem.find(u8, seen, "\"status\":400") != null);
}

test "the next turn extends the request that carried a Stop hook's message" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{toolCall("call_1", "read_file", "{\"path\":\"a\"}")};
    const provider_calls = [_]ToolCall{.{
        .id = "call_search",
        .name = "perplexity_search",
        .arguments_json = "{}",
        .provider_result = "search result",
        .provenance = .provider_executed,
    }};
    const Case = struct {
        name: []const u8,
        completions: []const test_support.FakeCompletion,
        /// The request that carries the hook's message, which ends the turn.
        last_request: usize,
    };
    const cases = [_]Case{
        .{
            .name = "after a tool step",
            .completions = &.{
                .{ .tool_calls = &calls },
                .{ .chunks = &.{"candidate"}, .content = "candidate" },
                .{ .content = "final" },
            },
            .last_request = 2,
        },
        .{
            .name = "after a reply that ran a provider tool",
            .completions = &.{
                .{ .content = "candidate", .tool_calls = &provider_calls, .finish_reason = .stop },
                .{ .content = "final" },
            },
            .last_request = 1,
        },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        var gateway = FakeGateway.init(alloc, case.completions);
        defer gateway.deinit();
        var deps = FakeAgentRuntimeDeps.init(alloc);
        defer deps.deinit();
        var fixture = PromptFixture{};
        var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
        defer lifecycle_runtime.deinit();
        var handler = StopTestHandler{
            .alloc = alloc,
            .action = .{ .continue_once = "verify the answer" },
        };
        defer handler.deinit();
        const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

        try runFakePromptWithLifecycle(
            &gateway,
            &deps,
            fixture.config(),
            fixture.job(),
            testLifecycleContext(view, alloc, fixture.workspace_root),
        );

        try std.testing.expectEqual(case.last_request + 1, gateway.request_bodies.items.len);
        try expectBodyContains(&gateway, case.last_request, "Continue the turn. fx hook context:\\nverify the answer");

        var follow_gateway = FakeGateway.init(alloc, &.{.{ .content = "follow-up" }});
        defer follow_gateway.deinit();
        var follow_deps = FakeAgentRuntimeDeps.init(alloc);
        defer follow_deps.deinit();
        var follow_fixture = PromptFixture{};
        var follow_job = follow_fixture.job();
        follow_job.history = deps.history_turns.items;
        try runFakePrompt(&follow_gateway, &follow_deps, follow_fixture.config(), follow_job);
        try test_support.expectPromptExtends(
            gateway.request_bodies.items[case.last_request],
            follow_gateway.request_bodies.items[0],
        );
    }
}

test "common Stop continuation normalizes to allow without remaining budget" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.agent_step_limit = 1;
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        config,
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expect(!handler.seen_can_continue);
    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    try std.testing.expectEqualStrings(
        "candidate",
        deps.history_turns.items[0].assistant.execution.tool_steps[0].assistant.?,
    );
}

test "common Stop cancellation during dispatch persists interrupted candidate" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate", .provider_state_json = "[{\"type\":\"reasoning\",\"text\":\"original replay\"}]" },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .cancel_continue = "ignored" },
        .cancel_flag = &fixture.cancel_flag,
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        fixture.config(),
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expect(deps.history_turns.items[0].interrupted.execution.tool_steps[0].provider_replay != null);
    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items.len);
    try std.testing.expect(deps.history_turns.items[0] == .interrupted);
    try std.testing.expectEqualStrings(
        "candidate",
        deps.history_turns.items[0].interrupted.execution.tool_steps[0].assistant.?,
    );
    try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items[0].interrupted.execution.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 0), deps.history_turns.items[0].interrupted.execution.tool_steps[0].tool_calls.len);
    try std.testing.expectEqualStrings("", deps.history_turns.items[0].interrupted.assistant orelse "");
    try std.testing.expectEqual(
        types.FinishedPromptProjection.assistant_text,
        deps.finish_projection.?,
    );
    try std.testing.expectEqual(
        types.TurnPresentationOutcome.interrupted,
        deps.finalized_outcome.?,
    );
}

test "common Stop pre-dispatch cancellation retains candidate without calling handler" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    deps.cancel_on_text = &fixture.cancel_flag;
    deps.cancel_on_text_match = "\n";
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .allow,
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        fixture.config(),
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 0), handler.calls);
    try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items.len);
    try std.testing.expectEqualStrings(
        "candidate",
        deps.history_turns.items[0].interrupted.execution.tool_steps[0].assistant.?,
    );
    try std.testing.expectEqual(
        types.FinishedPromptProjection.assistant_text,
        deps.finish_projection.?,
    );
    try std.testing.expectEqual(
        types.TurnPresentationOutcome.interrupted,
        deps.finalized_outcome.?,
    );
}

test "common Stop later provider failure ends on Esc with candidate still visible" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{ .chunks = &.{"candidate"}, .content = "candidate" },
        .{ .finish_reason = .provider_error },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.enable_recovery_checkpoint = true;
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    const config = fixture.config();
    // Esc while the request waits to retry ends the turn.
    deps.cancel_on_auto_retry_status = config.cancel_flag;
    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        config,
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expect(textContains(&deps, "candidate"));
    try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items.len);
    try std.testing.expect(deps.history_turns.items[0] == .interrupted);
    try std.testing.expectEqual(
        types.TurnPresentationOutcome.interrupted,
        deps.finalized_outcome.?,
    );
    try std.testing.expectEqual(@as(usize, 1), deps.finish_event_count);
    // The last checkpoint written before Esc still carries the candidate.
    const checkpoint = deps.recovery_checkpoints.items[deps.recovery_checkpoints.items.len - 1];
    try std.testing.expectEqualStrings("", checkpoint.assistant_source);
    try std.testing.expectEqual(@as(usize, 1), checkpoint.execution.tool_steps.len);
    try std.testing.expectEqualStrings("candidate", checkpoint.execution.tool_steps[0].assistant.?);
}

test "common Stop later stream failure persists copied partial text" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{
            .chunks = &.{"partial"},
            .stream_error_after_chunks = error.TestProviderFailure,
        },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try std.testing.expectError(
        error.TestProviderFailure,
        runFakePromptWithLifecycle(
            &gateway,
            &deps,
            fixture.config(),
            fixture.job(),
            testLifecycleContext(view, alloc, fixture.workspace_root),
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expectEqualStrings(
        "candidate\npartial",
        deps.finish_presentation_text.?,
    );
    try std.testing.expectEqualStrings("partial", deps.history_turns.items[0].assistant.assistant);
    try std.testing.expectEqualStrings("candidate", deps.history_turns.items[0].assistant.execution.tool_steps[0].assistant.?);
    try std.testing.expectEqual(
        types.TurnPresentationOutcome.failed,
        deps.finalized_outcome.?,
    );
}

test "common Stop retained partial does not borrow the stream buffer" {
    const alloc = std.testing.allocator;
    var source = [_]u8{ 'p', 'a', 'r', 't', 'i', 'a', 'l' };
    var stop_state = CommonStopState{};

    try copyLatestStopPartial(alloc, &stop_state, &source);
    defer alloc.free(@constCast(stop_state.latest_partial.?));
    source[0] = 'X';

    try std.testing.expectEqualStrings("partial", stop_state.latest_partial.?);
}

test "common Stop step limit retains candidate and current-turn execution" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("call_read", "read_file", "{\"path\":\"README.md\"}"),
    };
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{ .tool_calls = &calls },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.agent_step_limit = 2;
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        config,
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    const turn = deps.history_turns.items[0].assistant;
    try std.testing.expectEqualStrings(
        "candidate\nAgent step limit reached; continue with a follow-up prompt if needed.",
        deps.finish_presentation_text.?,
    );
    try std.testing.expectEqualStrings("Agent step limit reached; continue with a follow-up prompt if needed.", turn.assistant);
    try std.testing.expectEqual(@as(usize, 2), turn.execution.tool_steps.len);
    try std.testing.expectEqualStrings("candidate", turn.execution.tool_steps[0].assistant.?);
    try std.testing.expectEqualStrings(
        "read_file",
        turn.execution.tool_steps[1].tool_calls[0].name,
    );
    try std.testing.expectEqual(
        types.PersistedToolStatus.success,
        turn.execution.tool_steps[1].tool_results[0].status,
    );
}

test "common Stop length-limited tool failure retains candidate" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("call_read", "read_file", "{\"path\":\"README.md\"}"),
    };
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{
            .content = "partial",
            .tool_calls = &calls,
            .finish_reason = .length,
        },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        fixture.config(),
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    const assistant = deps.finish_presentation_text.?;
    try std.testing.expect(std.mem.startsWith(u8, assistant, "candidate\npartial"));
    try std.testing.expect(std.mem.find(u8, assistant, "did not run them") != null);
    try std.testing.expect(std.mem.startsWith(u8, deps.history_turns.items[0].assistant.assistant, "partial\n"));
    try std.testing.expectEqualStrings("candidate", deps.history_turns.items[0].assistant.execution.tool_steps[0].assistant.?);
    try std.testing.expectEqual(
        types.TurnPresentationOutcome.failed,
        deps.finalized_outcome.?,
    );
}

test "common Stop handler errors fail open" {
    const actions = [_]StopTestHandler.Action{
        .fail,
        .cancel_error,
    };

    for (actions) |action| {
        const alloc = std.testing.allocator;
        var gateway = FakeGateway.init(alloc, &.{
            .{ .content = "candidate" },
        });
        defer gateway.deinit();
        var deps = FakeAgentRuntimeDeps.init(alloc);
        defer deps.deinit();
        var fixture = PromptFixture{};
        var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
        defer lifecycle_runtime.deinit();
        var handler = StopTestHandler{
            .alloc = alloc,
            .action = action,
        };
        defer handler.deinit();
        const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

        try runFakePromptWithLifecycle(
            &gateway,
            &deps,
            fixture.config(),
            fixture.job(),
            testLifecycleContext(view, alloc, fixture.workspace_root),
        );

        try std.testing.expectEqual(@as(usize, 1), handler.calls);
        try std.testing.expectEqualStrings(
            "candidate",
            deps.history_turns.items[0].assistant.execution.tool_steps[0].assistant.?,
        );
        try std.testing.expectEqual(
            types.TurnPresentationOutcome.completed,
            deps.finalized_outcome.?,
        );
    }
}

/// A prompt the worker owns, allocated the way its queue frees it.
fn ownedWorkerPrompt(alloc: std.mem.Allocator, text: []const u8) !worker_runtime.QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, text),
        .images = &.{},
        .model = try alloc.dupe(u8, "provider/model"),
        .api_key = try alloc.dupe(u8, "key"),
        .permission_mode = .auto,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    };
}

/// A Stop hook during whose first run the user submits a steer, admitted the
/// way the terminal admits a prompt typed while a turn runs.
const SteerDuringStop = struct {
    alloc: std.mem.Allocator,
    worker: *worker_runtime.WorkerRuntime,
    calls: usize = 0,

    fn run(
        raw: *anyopaque,
        _: lifecycle_hooks.StopInput,
    ) lifecycle_hooks.HandlerError!lifecycle_hooks.StopAction {
        const self: *SteerDuringStop = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.calls == 1) {
            const steer = ownedWorkerPrompt(self.alloc, "also check the docs") catch return error.Failed;
            self.worker.admitInteractivePrompt(self.alloc, steer) catch {
                worker_runtime.freeQueuedPrompt(self.alloc, steer);
                return error.Failed;
            };
        }
        return .allow;
    }
};

test "common Stop steer submitted during the hook joins the turn for every final reply" {
    const alloc = std.testing.allocator;
    const provider_calls = [_]ToolCall{.{
        .id = "call_search",
        .name = "perplexity_search",
        .arguments_json = "{}",
        .provider_result = "search result",
        .provenance = .provider_executed,
    }};
    const Case = struct { name: []const u8, first: FakeCompletion };
    const cases = [_]Case{
        .{ .name = "plain reply", .first = .{ .content = "First answer" } },
        .{ .name = "provider tool reply", .first = .{
            .content = "First answer",
            .tool_calls = &provider_calls,
            .finish_reason = .stop,
        } },
        .{ .name = "provider tool reply with a streamed start", .first = .{
            .content = "First answer",
            .tool_calls = &provider_calls,
            .streamed_tool_starts = &provider_calls,
            .finish_reason = .stop,
        } },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.name});
        // The turn starts the way the worker loop starts one, and the agent
        // takes its steering, cancel flag, and events from that worker.
        var worker = worker_runtime.WorkerRuntime{};
        defer worker.deinit(alloc);
        try worker.admitInteractivePrompt(alloc, try ownedWorkerPrompt(alloc, "user prompt"));
        const work = (try worker.tryTakeNextWork(alloc)) orelse return error.TestExpectedQueuedWork;
        defer worker_runtime.freeWorkItem(alloc, work);

        var gateway = FakeGateway.init(alloc, &.{ case.first, .{ .content = "Updated answer" } });
        defer gateway.deinit();
        var deps = FakeAgentRuntimeDeps.init(alloc);
        defer deps.deinit();
        deps.steering_worker = &worker;
        var fixture = PromptFixture{};
        var config = fixture.config();
        config.cancel_flag = &worker.worker_cancel_requested;
        var job = fixture.job();
        job.turn_id = work.prompt.turn_id;
        var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
        defer lifecycle_runtime.deinit();
        var handler = SteerDuringStop{ .alloc = alloc, .worker = &worker };
        try lifecycle_runtime.registerStop(.{ .name = "steer-during-stop", .ctx = &handler, .run = SteerDuringStop.run });

        try runFakePromptWithLifecycle(
            &gateway,
            &deps,
            config,
            job,
            testLifecycleContext(lifecycle_runtime.freeze(), alloc, fixture.workspace_root),
        );
        worker.finishProcessing();

        // The steer reaches the turn's next request, and the turn ends once,
        // with the updated reply.
        try std.testing.expectEqual(@as(usize, 2), handler.calls);
        try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
        try expectBodyContainsInOrder(&gateway, 1, &.{ "First answer", "user_steering", "also check the docs" });
        try std.testing.expectEqual(@as(usize, 0), deps.interrupted_history_count);
        try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items.len);
        try std.testing.expect(deps.history_turns.items[0] == .assistant);
        try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items[0].assistant.execution.steering.len);
        // Nothing is left over to run as a later turn.
        try std.testing.expectEqual(@as(usize, 0), worker.queuedPromptCount());
    }
}

test "common Stop does not run for silent-tool auto-continuation" {
    const alloc = std.testing.allocator;
    const first_calls = [_]ToolCall{
        toolCall("call_a", "read_file", "{\"path\":\"a.txt\"}"),
    };
    const second_calls = [_]ToolCall{
        toolCall("call_b", "read_file", "{\"path\":\"b.txt\"}"),
    };
    var gateway = FakeGateway.init(alloc, &.{
        .{ .tool_calls = &first_calls },
        .{ .tool_calls = &second_calls },
        .{},
        .{ .content = "summary" },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .allow,
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        fixture.config(),
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expectEqualStrings("summary", handler.seen_text.?);
    try std.testing.expectEqual(@as(usize, 4), gateway.request_bodies.items.len);
    try expectBodyContains(&gateway, 3, "Summarize what you just did.");
}

test "common Stop HTTP failure ends on Esc with candidate still visible" {
    const alloc = std.testing.allocator;
    const chunks = [_][]const u8{"later partial"};
    var gateway = FakeGateway.init(alloc, &.{
        .{ .chunks = &.{"candidate"}, .content = "candidate" },
        .{
            .status = .bad_gateway,
            .err_body = "gateway unavailable",
            .chunks = &chunks,
        },
        .{
            .status = .bad_gateway,
            .err_body = "gateway unavailable",
        },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    const config = fixture.config();
    // Esc while the request waits to retry ends the turn.
    deps.cancel_on_auto_retry_status = config.cancel_flag;
    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        config,
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    // Esc during the HTTP wait takes the existing cancel branch, which saves
    // the turn as interrupted without flushing the failed attempt's text.
    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expect(textContains(&deps, "candidate"));
    try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items.len);
    try std.testing.expect(deps.history_turns.items[0] == .interrupted);
    try std.testing.expectEqual(@as(?std.http.Status, null), deps.http_status);
    try std.testing.expectEqual(
        types.TurnPresentationOutcome.interrupted,
        deps.finalized_outcome.?,
    );
}

test "common Stop finish_turn retains candidate and execution memory" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("call_finish", "read_file", "{\"path\":\"README.md\"}"),
    };
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{
            .content = "working",
            .tool_calls = &calls,
        },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.exec_plans = &.{.{ .result = .{
        .model_output = "finished",
        .finish_turn = true,
    } }};
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        fixture.config(),
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items.len);
    const turn = deps.history_turns.items[0].assistant;
    try std.testing.expectEqualStrings("candidate\nworking", deps.finish_presentation_text.?);
    try std.testing.expectEqualStrings("", turn.assistant);
    try std.testing.expectEqual(@as(usize, 2), turn.execution.tool_steps.len);
    try std.testing.expectEqualStrings("candidate", turn.execution.tool_steps[0].assistant.?);
    try std.testing.expectEqualStrings("working", turn.execution.tool_steps[1].assistant.?);
    try std.testing.expectEqualStrings(
        "call_finish",
        turn.execution.tool_steps[1].tool_calls[0].id,
    );
    try std.testing.expectEqual(
        types.PersistedToolStatus.success,
        turn.execution.tool_steps[1].tool_results[0].status,
    );
}

test "common Stop cancellation excludes active call and keeps typed failed peer" {
    const alloc = std.testing.allocator;
    const peer_calls = [_]ToolCall{
        toolCall("call_peer", "web_search", "{\"query\":\"current news\"}"),
    };
    const active_calls = [_]ToolCall{
        toolCall("call_active", "read_file", "{\"path\":\"README.md\"}"),
    };
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{ .tool_calls = &peer_calls },
        .{ .tool_calls = &active_calls },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.exec_plans = &.{.{ .result = .{
        .model_output = "plain peer result",
        .status = .failure,
    } }};
    deps.permission_decisions = &.{ .once, .deny };
    defer deps.deinit();
    var fixture = PromptFixture{};
    deps.cancel_on_permission = &fixture.cancel_flag;
    deps.cancel_on_permission_name = "read_file";
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        fixture.config(),
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items.len);
    const turn = deps.history_turns.items[0].interrupted;
    try std.testing.expectEqualStrings("candidate", deps.finish_presentation_text.?);
    try std.testing.expectEqualStrings("", turn.assistant orelse "");
    try std.testing.expectEqualStrings("call_active", turn.tool_call.?.id);
    try std.testing.expectEqual(@as(usize, 2), turn.execution.tool_steps.len);
    try std.testing.expectEqualStrings("candidate", turn.execution.tool_steps[0].assistant.?);
    try std.testing.expectEqual(@as(usize, 0), turn.execution.tool_steps[0].tool_calls.len);
    try std.testing.expectEqualStrings(
        "call_peer",
        turn.execution.tool_steps[1].tool_calls[0].id,
    );
    try std.testing.expectEqual(
        types.PersistedToolStatus.failure,
        turn.execution.tool_steps[1].tool_results[0].status,
    );
    try std.testing.expectEqualStrings(
        "plain peer result",
        turn.execution.tool_steps[1].tool_results[0].output,
    );
    try std.testing.expectEqual(
        types.FinishedPromptProjection.assistant_text,
        deps.finish_projection.?,
    );
}

test "common Stop interruption keeps only completed calls from a partially attempted step" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(result_dir);
    const trace_path = try std.Io.Dir.path.join(alloc, &.{ result_dir, "trace.log" });
    defer alloc.free(trace_path);
    debug_trace.resetForTest();
    defer debug_trace.resetForTest();
    try debug_trace.configureForTest(alloc, trace_path);
    const calls = [_]ToolCall{
        toolCall("call_completed", "read_file", "{\"path\":\"README.md\"}"),
        toolCall("call_cancelled", "browser_snapshot", "{}"),
        toolCall("call_unattempted", "grep_files", "{\"pattern\":\"Hooks\"}"),
    };
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{
            .tool_calls = &calls,
            .provider_state_json =
            \\[{"type":"reasoning","text":"PARTIAL_BATCH_REPLAY"},{"type":"tool-call","toolCallId":"call_completed"},{"type":"tool-call","toolCallId":"call_cancelled"},{"type":"tool-call","toolCallId":"call_unattempted"}]
            ,
        },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.exec_plans = &.{
        .{ .result = .{ .model_output = "completed result" } },
        .{ .err = error.Cancelled },
    };
    defer deps.deinit();
    var fixture = PromptFixture{};
    deps.cancel_on_execute = &fixture.cancel_flag;
    deps.cancel_on_execute_name = "browser_snapshot";
    var config = fixture.config();
    config.tool_result_dir = result_dir;
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        config,
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 2), deps.executed_names.items.len);
    const turn = deps.history_turns.items[0].interrupted;
    try std.testing.expectEqualStrings("call_cancelled", turn.tool_call.?.id);
    try std.testing.expectEqual(@as(usize, 2), turn.execution.tool_steps.len);
    try std.testing.expectEqualStrings("candidate", turn.execution.tool_steps[0].assistant.?);
    try std.testing.expectEqual(@as(usize, 0), turn.execution.tool_steps[0].tool_calls.len);
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps[1].tool_calls.len);
    try std.testing.expectEqualStrings(
        "call_completed",
        turn.execution.tool_steps[1].tool_calls[0].id,
    );
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps[1].tool_results.len);
    try std.testing.expectEqualStrings(
        "completed result",
        turn.execution.tool_steps[1].tool_results[0].output,
    );

    // The interrupted turn is saved and read back the way a resume reads it.
    const session_adapter = @import("../../../session/session_adapter.zig");
    var store = try session_adapter.Store.open(alloc, result_dir);
    defer store.deinit(alloc);
    var model = "test-model".*;
    const saved = try session_adapter.Session.create(alloc, &store, fixture.workspace_root, .ask, .{
        .preferences = .{ .model = &model, .effort = .auto, .fast_mode = false },
        .language = types.ConversationLanguage.default(),
        .permission_state = .{},
    });
    try saved.commitTurn(deps.history_turns.items[0], types.ConversationLanguage.default());
    const id = try alloc.dupe(u8, saved.id());
    defer alloc.free(id);
    saved.close();
    const resumed = try session_adapter.Session.resumeSession(alloc, &store, .{ .id = id }, fixture.workspace_root, .ask);
    defer resumed.close();
    var restored = try resumed.restore(alloc);
    defer restored.deinit(alloc);
    const history = restored.history;
    try std.testing.expectEqual(@as(usize, 1), history.len);
    var follow_gateway = FakeGateway.init(alloc, &.{.{ .content = "resumed" }});
    defer follow_gateway.deinit();
    var follow_deps = FakeAgentRuntimeDeps.init(alloc);
    defer follow_deps.deinit();
    var follow_fixture = PromptFixture{};
    var follow_job = follow_fixture.job();
    follow_job.history = history;
    try runFakePrompt(&follow_gateway, &follow_deps, follow_fixture.config(), follow_job);
    try expectBodyContains(&follow_gateway, 0, "completed result");
    try expectBodyContains(&follow_gateway, 0, "call_cancelled");
    try expectBodyNotContains(&follow_gateway, 0, "call_unattempted");
    try expectBodyNotContains(&follow_gateway, 0, "PARTIAL_BATCH_REPLAY");
    try std.testing.expect(history[0].interrupted.execution.tool_steps[1].provider_replay == null);
    debug_trace.shutdown();
    const trace = try readTraceFile(alloc, trace_path, 256 * 1024);
    defer alloc.free(trace);
    try std.testing.expect(std.mem.find(u8, trace, "provider replay omitted reason=interrupted_incomplete_association source_calls=3 completed_calls=1") != null);
}

test "two standalone compaction cuts retain matching request and finalization history" {
    const execution_memory = @import("../execution_memory.zig");
    const alloc = std.testing.allocator;
    const first_call = toolCall("first_tool", "read_file", "{\"path\":\"a.txt\"}");
    const last_call = toolCall("last_tool", "read_file", "{\"path\":\"b.txt\"}");
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .content = "first candidate", .standalone_response = true },
        .{ .role = .user, .content = "Continue the turn. fx hook context:\nverify" },
        .{ .role = .assistant, .tool_calls = &.{first_call} },
        .{ .role = .tool, .content = "first result", .tool_call_id = first_call.id, .tool_name = first_call.name, .tool_result_status = .success },
        .{
            .role = .assistant,
            .provider_replay = .{
                .source = .{ .provider = .gateway, .model = "anthropic/claude-opus-4.6" },
                .parts_json = "[{\"type\":\"reasoning\",\"text\":\"COMPACTED_PRIVATE_REPLAY\"}]",
            },
        },
        .{ .role = .user, .content = "Summarize what you just did." },
        .{ .role = .assistant, .tool_calls = &.{last_call} },
        .{ .role = .tool, .content = "last result", .tool_call_id = last_call.id, .tool_name = last_call.name, .tool_result_status = .success },
    };
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var offset: usize = 0;
    var boundary: execution_memory.CompactedExecutionBoundary = .{};
    const cuts = [_]struct { end: usize, steps: usize }{
        .{ .end = 4, .steps = 1 },
        .{ .end = messages.len, .steps = 2 },
    };
    for (cuts) |cut| {
        const before = try execution_memory.buildExecutionMemory(arena.allocator(), messages[offset..cut.end]);
        offset += try execution_memory.retainedMessageOffset(messages[offset..cut.end], .{ .tool_steps = cut.steps });
        boundary.tool_steps += cut.steps;
        const retained = try execution_memory.buildExecutionMemory(arena.allocator(), messages[offset..cut.end]);
        try std.testing.expectEqual(before.tool_steps.len - cut.steps, retained.tool_steps.len);
        try std.testing.expectEqual(@as(usize, 1), retained.tool_steps.len);
        try std.testing.expectEqualStrings(before.tool_steps[cut.steps].tool_calls[0].id, retained.tool_steps[0].tool_calls[0].id);
    }
    try std.testing.expectEqual(@as(usize, 5), offset);
    const builtin_gateway = @import("../../../../builtins/gateway.zig");
    const body = try builtin_gateway.buildAgentRequest(alloc, .{
        .model = "anthropic/claude-opus-4.6",
        .messages = messages[offset..],
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer alloc.free(body);
    try std.testing.expect(std.mem.find(u8, body, "last_tool") != null);
    try std.testing.expect(std.mem.find(u8, body, "first candidate") == null);
    try std.testing.expect(std.mem.find(u8, body, "first_tool") == null);
    try std.testing.expect(std.mem.find(u8, body, "COMPACTED_PRIVATE_REPLAY") == null);

    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    const runtime_deps = deps.deps();
    var finalization = TurnFinalizationGuard.init(&runtime_deps, 1, testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, "/tmp/workspace"));
    defer finalization.deinit();
    finalization.compacted_execution = boundary;
    var fixture = PromptFixture{};
    var summary = TurnSummaryAccumulator{ .turn_started_at_ms = io_mod.milliTimestamp() };
    var finish_trace = PromptFinishTrace{ .ctx = .{ .turn_id = 1 } };
    try finishCommonAssistantTerminal(&runtime_deps, &finalization, arena.allocator(), fixture.job(), &messages, &summary, .{ .history = "final answer" }, .completed, .completed, &finish_trace, "completed", null);
    const turn = deps.history_turns.items[0].assistant;
    try std.testing.expectEqualStrings("final answer", turn.assistant);
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps.len);
    try std.testing.expectEqualStrings(last_call.id, turn.execution.tool_steps[0].tool_calls[0].id);
    try std.testing.expectEqualStrings("last result", turn.execution.tool_steps[0].tool_results[0].output);
    var follow_gateway = FakeGateway.init(alloc, &.{.{ .content = "follow-up" }});
    defer follow_gateway.deinit();
    var follow_deps = FakeAgentRuntimeDeps.init(alloc);
    defer follow_deps.deinit();
    var follow_job = fixture.job();
    follow_job.history = deps.history_turns.items;
    try runFakePrompt(&follow_gateway, &follow_deps, fixture.config(), follow_job);
    try expectBodyContains(&follow_gateway, 0, "last result");
    try expectBodyNotContains(&follow_gateway, 0, "first candidate");
    try expectBodyNotContains(&follow_gateway, 0, "first_tool");
    try expectBodyNotContains(&follow_gateway, 0, "COMPACTED_PRIVATE_REPLAY");
}

test "common Stop parallel cancellation preserves ordinary cancelled peer as completed failure" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("call_ordinary_cancel", "read_file", "{\"path\":\"README.md\"}"),
        toolCall("call_owner_signal", "grep_files", "{\"pattern\":\"Hooks\"}"),
        toolCall("call_completed_peer", "glob_files", "{\"pattern\":\"src/main.zig\"}"),
    };
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{ .tool_calls = &calls },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    deps.ordinary_cancel_on_execute_name = "read_file";
    deps.cancel_on_execute = &fixture.cancel_flag;
    deps.cancel_on_execute_name = "grep_files";
    deps.cancel_on_execute_delay_ms = 50;
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);
    var job = fixture.job();
    job.permission_mode = .auto;

    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        fixture.config(),
        job,
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 3), deps.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items.len);
    const turn = deps.history_turns.items[0].interrupted;
    try std.testing.expectEqualStrings("candidate", deps.finish_presentation_text.?);
    try std.testing.expectEqualStrings("", turn.assistant orelse "");
    try std.testing.expect(turn.tool_call == null);
    try std.testing.expectEqual(@as(usize, 2), turn.execution.tool_steps.len);
    try std.testing.expectEqualStrings("candidate", turn.execution.tool_steps[0].assistant.?);
    try std.testing.expectEqual(@as(usize, 0), turn.execution.tool_steps[0].tool_calls.len);
    const step = turn.execution.tool_steps[1];
    try std.testing.expectEqual(@as(usize, 3), step.tool_calls.len);
    try std.testing.expectEqual(@as(usize, 3), step.tool_results.len);
    try std.testing.expectEqualStrings("call_ordinary_cancel", step.tool_calls[0].id);
    try std.testing.expectEqualStrings("call_owner_signal", step.tool_calls[1].id);
    try std.testing.expectEqualStrings("call_completed_peer", step.tool_calls[2].id);
    try std.testing.expectEqual(
        types.PersistedToolStatus.failure,
        step.tool_results[0].status,
    );
    try std.testing.expect(std.mem.find(
        u8,
        step.tool_results[0].output,
        "Cancelled",
    ) != null);
    try std.testing.expectEqual(
        types.PersistedToolStatus.success,
        step.tool_results[1].status,
    );
    try std.testing.expectEqual(
        types.PersistedToolStatus.success,
        step.tool_results[2].status,
    );
}

test "common Stop failure excludes a later call without a result" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        .{
            .id = "call_completed",
            .name = "perplexity_search",
            .arguments_json = "{}",
            .provider_result = "completed provider result",
            .provenance = .provider_executed,
        },
        toolCall("call_resultless", "read_file", "{\"path\":\"README.md\"}"),
    };
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{ .tool_calls = &calls },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.exec_plans = &.{.{ .result = .{ .model_output = "never persisted" } }};
    deps.fail_status_finished = true;
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try std.testing.expectError(
        error.TestStatusPublicationFailure,
        runFakePromptWithLifecycle(
            &gateway,
            &deps,
            fixture.config(),
            fixture.job(),
            testLifecycleContext(view, alloc, fixture.workspace_root),
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items.len);
    const execution = deps.history_turns.items[0].assistant.execution;
    try std.testing.expectEqual(@as(usize, 2), execution.tool_steps.len);
    try std.testing.expectEqualStrings("candidate", execution.tool_steps[0].assistant.?);
    const step = execution.tool_steps[1];
    try std.testing.expectEqual(@as(usize, 1), step.tool_calls.len);
    try std.testing.expectEqualStrings("call_completed", step.tool_calls[0].id);
    try std.testing.expectEqual(@as(usize, 1), step.tool_results.len);

    var replay: std.ArrayList(ChatMessage) = .empty;
    defer replay.deinit(alloc);
    try session_runtime.appendHistoryChatMessages(
        alloc,
        &replay,
        deps.history_turns.items,
    );
    // The hook's message sat between the candidate and the next step in the
    // request, so the saved turn keeps it there, as fx's own message.
    try std.testing.expectEqual(@as(usize, 5), replay.items.len);
    try std.testing.expectEqualStrings("candidate", replay.items[1].content.?);
    try std.testing.expectEqualStrings("Continue the turn. fx hook context:\nverify", replay.items[2].content.?);
    try std.testing.expect(replay.items[2].recovery_prompt);
    try std.testing.expectEqual(@as(usize, 1), replay.items[3].tool_calls.len);
    try std.testing.expectEqualStrings(
        "call_completed",
        replay.items[3].tool_calls[0].id,
    );
    try std.testing.expectEqualStrings(
        "call_completed",
        replay.items[4].tool_call_id.?,
    );
}

test "common Stop history propagation failure preserves recovery checkpoint" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{ .finish_reason = .provider_error },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.history_propagation_error = error.TestHistoryPropagationFailed;
    deps.enable_recovery_checkpoint = true;
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try std.testing.expectError(
        error.TestHistoryPropagationFailed,
        runFakePromptWithLifecycle(
            &gateway,
            &deps,
            fixture.config(),
            fixture.job(),
            testLifecycleContext(view, alloc, fixture.workspace_root),
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), deps.history_propagation_count);
    try std.testing.expectEqual(@as(usize, 1), deps.finalization_count);
    try std.testing.expectEqual(@as(usize, 1), deps.finish_event_attempt_count);
    try std.testing.expectEqual(@as(usize, 1), deps.finish_event_count);
    try std.testing.expect(deps.recovery_checkpoints.items.len > 0);
}

test "common Stop finalization failure wins and is not retried" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{ .finish_reason = .provider_error },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.history_propagation_error = error.TestHistoryPropagationFailed;
    deps.finalization_error = error.TestFinalizationFailed;
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try std.testing.expectError(
        error.TestFinalizationFailed,
        runFakePromptWithLifecycle(
            &gateway,
            &deps,
            fixture.config(),
            fixture.job(),
            testLifecycleContext(view, alloc, fixture.workspace_root),
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), deps.history_propagation_count);
    try std.testing.expectEqual(@as(usize, 1), deps.finalization_count);
    try std.testing.expectEqual(@as(usize, 0), deps.finish_event_attempt_count);
}

test "common Stop finish event failure wins and is not retried" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{ .finish_reason = .provider_error },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.history_propagation_error = error.TestHistoryPropagationFailed;
    deps.finish_event_error = error.TestFinishEventFailed;
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer lifecycle_runtime.deinit();
    var handler = StopTestHandler{
        .alloc = alloc,
        .action = .{ .continue_once = "verify" },
    };
    defer handler.deinit();
    const view = try registerStopTestHandler(&lifecycle_runtime, &handler);

    try std.testing.expectError(
        error.TestFinishEventFailed,
        runFakePromptWithLifecycle(
            &gateway,
            &deps,
            fixture.config(),
            fixture.job(),
            testLifecycleContext(view, alloc, fixture.workspace_root),
        ),
    );

    try std.testing.expectEqual(@as(usize, 1), deps.history_propagation_count);
    try std.testing.expectEqual(@as(usize, 1), deps.finalization_count);
    try std.testing.expectEqual(@as(usize, 1), deps.finish_event_attempt_count);
    try std.testing.expectEqual(@as(usize, 0), deps.finish_event_count);
}

test "common Stop terminal payload construction failure leaves guard open for one fallback" {
    const alloc = testing_allocator.no_resize;
    const calls = [_]ToolCall{
        toolCall("call_read", "read_file", "{\"path\":\"README.md\"}"),
    };
    const messages = [_]ChatMessage{
        .{
            .role = .assistant,
            .tool_calls = &calls,
        },
        .{
            .role = .tool,
            .content = "result",
            .tool_call_id = "call_read",
            .tool_name = "read_file",
            .tool_result_status = .success,
        },
    };
    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    const runtime_deps = deps.deps();
    var finalization = TurnFinalizationGuard.init(
        &runtime_deps,
        1,
        testLifecycleContext(
            lifecycle_hooks.RuntimeView.empty(),
            alloc,
            "/tmp/workspace",
        ),
    );
    var fixture = PromptFixture{};
    var job = fixture.job();
    job.turn_id = 1;
    var summary = TurnSummaryAccumulator{
        .turn_started_at_ms = io_mod.milliTimestamp(),
    };
    var finish_trace = PromptFinishTrace{
        .ctx = .{ .turn_id = 1 },
    };

    try std.testing.expectError(
        error.OutOfMemory,
        finishCommonAssistantTerminal(
            &runtime_deps,
            &finalization,
            failing.allocator(),
            job,
            &messages,
            &summary,
            .{ .history = "candidate" },
            .failed,
            null,
            &finish_trace,
            "error",
            null,
        ),
    );

    try std.testing.expectEqual(TurnFinalizationGuard.State.open, finalization.state);
    try std.testing.expectEqual(@as(usize, 0), deps.history_propagation_count);
    try std.testing.expectEqual(@as(usize, 0), deps.finalization_count);

    try finalization.finish(.failed, null, null);
    try std.testing.expectEqual(TurnFinalizationGuard.State.emitted, finalization.state);
    try std.testing.expectEqual(@as(usize, 1), deps.finalization_count);
    try std.testing.expectEqual(@as(usize, 0), deps.finish_event_attempt_count);
}

test "TurnFinalizationGuard runs PostTurnEnd once for every terminal outcome and scope" {
    const alloc = std.testing.allocator;
    var hook_capture = PostTurnEndFinalizationCapture{};
    var hook_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer hook_runtime.deinit();
    try hook_runtime.registerPostTurnEnd(.{
        .name = "capture",
        .ctx = &hook_capture,
        .run = PostTurnEndFinalizationCapture.run,
    });

    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    const runtime_deps = deps.deps();
    const view = hook_runtime.freeze();
    const cases = [_]struct {
        scope_kind: lifecycle_hooks.ScopeKind,
        outcome: types.TurnPresentationOutcome,
        disposition: ?types.ProviderCompletionDisposition,
    }{
        .{ .scope_kind = .interactive, .outcome = .completed, .disposition = .completed },
        .{ .scope_kind = .ask, .outcome = .interrupted, .disposition = null },
        .{ .scope_kind = .ask, .outcome = .paused, .disposition = null },
        .{ .scope_kind = .acp, .outcome = .failed, .disposition = .length_limited },
        .{ .scope_kind = .subagent, .outcome = .completed, .disposition = null },
    };

    for (cases, 0..) |case, index| {
        const turn_id: u64 = @intCast(index + 1);
        var lifecycle = testLifecycleContext(view, alloc, "/tmp/workspace");
        lifecycle.scope.kind = case.scope_kind;
        if (case.scope_kind == .subagent) lifecycle.scope.subagent_id = 17;
        var finalization = TurnFinalizationGuard.init(
            &runtime_deps,
            turn_id,
            lifecycle,
        );
        defer finalization.deinit();
        try finalization.track_agent_terminal_lease("terminal-owned");
        try finalization.track_agent_terminal_lease("terminal-owned");
        try finalization.finish(case.outcome, case.disposition, null);
        try finalization.finish(.failed, null, null);
    }

    try std.testing.expectEqual(cases.len, deps.finalization_count);
    try std.testing.expectEqual(cases.len, deps.terminal_lease_cleanup_ids.items.len);
    try std.testing.expectEqual(cases.len, hook_capture.calls);
    for (cases, 0..) |case, index| {
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), hook_capture.turn_ids[index]);
        try std.testing.expectEqual(case.scope_kind, hook_capture.scope_kinds[index]);
        try std.testing.expect(hook_capture.workspace_matches[index]);
        try std.testing.expectEqual(case.outcome, hook_capture.outcomes[index]);
        try std.testing.expectEqual(case.disposition, hook_capture.dispositions[index]);
    }
}

test "TurnFinalizationGuard attempts every tracked lease without replacing accepted completion" {
    const alloc = std.testing.allocator;
    const cleanup_errors = [_]?anyerror{
        error.TestFirstCleanupFailed,
        null,
    };
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.terminal_lease_cleanup_errors = &cleanup_errors;
    defer deps.deinit();
    const runtime_deps = deps.deps();
    var finalization = TurnFinalizationGuard.init(
        &runtime_deps,
        41,
        testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, "/tmp/workspace"),
    );
    defer finalization.deinit();

    try finalization.track_agent_terminal_lease("terminal-one");
    try finalization.track_agent_terminal_lease("terminal-two");
    finalization.remove_agent_terminal_lease("terminal-missing");
    const finished = try types.dupeFinishedPrompt(std.heap.c_allocator, .{
        .turn = .{ .assistant = .{
            .user = .{ .text = @constCast("prompt") },
            .assistant = @constCast("accepted answer"),
        } },
    });

    try finalization.finish(.completed, .completed, finished);
    try finalization.finish(.failed, null, null);
    try std.testing.expectEqual(TurnFinalizationGuard.State.emitted, finalization.state);
    try std.testing.expectEqual(@as(usize, 2), deps.terminal_lease_cleanup_ids.items.len);
    try std.testing.expectEqualStrings("terminal-one", deps.terminal_lease_cleanup_ids.items[0]);
    try std.testing.expectEqualStrings("terminal-two", deps.terminal_lease_cleanup_ids.items[1]);
    try std.testing.expectEqual(@as(usize, 1), deps.finalization_count);
    try std.testing.expectEqual(@as(usize, 1), deps.finish_event_count);
    try std.testing.expectEqual(@as(usize, 1), deps.finish_event_attempt_count);
    try std.testing.expectEqualStrings("accepted answer", deps.finish_assistant_text.?);
}

test "TurnFinalizationGuard removes explicit release without cleanup" {
    const alloc = std.testing.allocator;
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    const runtime_deps = deps.deps();
    var finalization = TurnFinalizationGuard.init(
        &runtime_deps,
        42,
        testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, "/tmp/workspace"),
    );
    defer finalization.deinit();

    try finalization.track_agent_terminal_lease("terminal-released");
    finalization.remove_agent_terminal_lease("terminal-released");
    try finalization.finish(.completed, null, null);

    try std.testing.expectEqual(@as(usize, 0), deps.terminal_lease_cleanup_ids.items.len);
    try std.testing.expectEqual(@as(usize, 1), deps.finalization_count);
}

test "TurnFinalizationGuard skips PostTurnEnd when terminal finalization fails" {
    const alloc = std.testing.allocator;
    var hook_capture = PostTurnEndFinalizationCapture{};
    var hook_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer hook_runtime.deinit();
    try hook_runtime.registerPostTurnEnd(.{
        .name = "capture",
        .ctx = &hook_capture,
        .run = PostTurnEndFinalizationCapture.run,
    });

    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.finalization_error = error.TestFinalizationFailed;
    defer deps.deinit();
    const runtime_deps = deps.deps();
    var finalization = TurnFinalizationGuard.init(
        &runtime_deps,
        7,
        testLifecycleContext(hook_runtime.freeze(), alloc, "/tmp/workspace"),
    );

    try std.testing.expectError(
        error.TestFinalizationFailed,
        finalization.finish(.failed, null, null),
    );

    try std.testing.expectEqual(TurnFinalizationGuard.State.fatal, finalization.state);
    try std.testing.expectEqual(@as(usize, 1), deps.finalization_count);
    try std.testing.expectEqual(@as(usize, 0), hook_capture.calls);
}

test "TurnFinalizationGuard runs PostTurnEnd after failed finish prompt publication" {
    const alloc = std.testing.allocator;
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.finish_event_error = error.TestFinishEventFailed;
    defer deps.deinit();

    var hook_capture = PostTurnEndFinalizationCapture{ .deps = &deps };
    var hook_runtime = lifecycle_hooks.Runtime.init(alloc);
    defer hook_runtime.deinit();
    try hook_runtime.registerPostTurnEnd(.{
        .name = "capture",
        .ctx = &hook_capture,
        .run = PostTurnEndFinalizationCapture.run,
    });

    const runtime_deps = deps.deps();
    var finalization = TurnFinalizationGuard.init(
        &runtime_deps,
        9,
        testLifecycleContext(hook_runtime.freeze(), alloc, "/tmp/workspace"),
    );
    const finished = try types.dupeFinishedPrompt(std.heap.c_allocator, .{
        .turn = .{ .assistant = .{
            .user = .{ .text = @constCast("prompt") },
            .assistant = @constCast("answer"),
        } },
    });

    try std.testing.expectError(
        error.TestFinishEventFailed,
        finalization.finish(.completed, .completed, finished),
    );
    try finalization.finish(.failed, null, null);

    try std.testing.expectEqual(TurnFinalizationGuard.State.emitted, finalization.state);
    try std.testing.expectEqual(@as(usize, 1), deps.finalization_count);
    try std.testing.expectEqual(@as(usize, 1), deps.finish_event_attempt_count);
    try std.testing.expectEqual(@as(usize, 1), hook_capture.calls);
    try std.testing.expectEqual(@as(usize, 1), hook_capture.finish_event_attempts[0]);
    try std.testing.expectEqual(@as(u64, 9), hook_capture.turn_ids[0]);
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, hook_capture.outcomes[0]);
    try std.testing.expectEqual(@as(?types.ProviderCompletionDisposition, .completed), hook_capture.dispositions[0]);
}

/// A hooks file whose one hook for `event` runs `command`.
/// The hook file that runs `command` for `event`. The command is escaped as a JSON string, so a
/// command with quotes or backslashes still makes a file the loader can read.
fn startEventHooksJson(alloc: std.mem.Allocator, event: []const u8, command: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(alloc);
    for (command) |byte| {
        if (byte == '"' or byte == '\\') try escaped.append(alloc, '\\');
        try escaped.append(alloc, byte);
    }
    return std.mem.concat(alloc, u8, &.{ "{\"hooks\":{\"", event, "\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"", escaped.items, "\"}]}]}}" });
}

/// Reads what a test hook wrote, from under the fixture's tmp dir.
fn readHookOutput(alloc: std.mem.Allocator, fixture: *UserStopFixture, name: []const u8) ![]u8 {
    var file = try fixture.tmp.dir.openFile(io_mod.getIo(), name, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, 65536);
}

test "a SessionStart hook adds context to every request of the session" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const marker = try std.Io.Dir.path.join(alloc, &.{ user_fixture.workspace, "start.txt" });
    defer alloc.free(marker);
    const command = try std.mem.concat(alloc, u8, &.{ "echo ran >> '", marker, "'; printf '%s' 'repo uses zig'" });
    defer alloc.free(command);
    const hooks_json = try startEventHooksJson(alloc, "SessionStart", command);
    defer alloc.free(hooks_json);
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &.{ .{ .content = "first" }, .{ .content = "second" } });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;
    lifecycle.scope.session_id = "session-1";

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);
    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);

    try expectBodyContains(&gateway, 0, "repo uses zig");
    try expectBodyContains(&gateway, 1, "repo uses zig");
    const written = try readHookOutput(alloc, &user_fixture, "workspace/start.txt");
    defer alloc.free(written);
    try std.testing.expectEqualStrings("ran\n", written);
}

test "SessionStart reports resume for a session that has history" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const copy = try std.Io.Dir.path.join(alloc, &.{ user_fixture.workspace, "start-input.json" });
    defer alloc.free(copy);
    const command = try std.mem.concat(alloc, u8, &.{ "cat > '", copy, "'" });
    defer alloc.free(command);
    const hooks_json = try startEventHooksJson(alloc, "SessionStart", command);
    defer alloc.free(hooks_json);
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &.{ .{ .content = "first" }, .{ .content = "second" } });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    // The first turn of session-1 saves one history turn. Session-2 then starts with that history.
    lifecycle.scope.session_id = "session-1";
    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);
    try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items.len);
    var history = [_]types.HistoryTurn{deps.history_turns.items[0]};
    var job = fixture.job();
    job.history = &history;
    lifecycle.scope.session_id = "session-2";
    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), job, lifecycle);

    const input = try readHookOutput(alloc, &user_fixture, "workspace/start-input.json");
    defer alloc.free(input);
    try std.testing.expect(std.mem.find(u8, input, "\"source\":\"resume\"") != null);
}

test "a SubagentStart hook runs for a subagent turn" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const marker = try std.Io.Dir.path.join(alloc, &.{ user_fixture.workspace, "subagent-start.txt" });
    defer alloc.free(marker);
    const command = try std.mem.concat(alloc, u8, &.{ "echo ran >> '", marker, "'" });
    defer alloc.free(command);
    const hooks_json = try startEventHooksJson(alloc, "SubagentStart", command);
    defer alloc.free(hooks_json);
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &.{.{ .content = "answer" }});
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var config = fixture.config();
    config.origin = .subagent;
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;
    lifecycle.scope.kind = .subagent;
    lifecycle.scope.session_id = "child-1";

    try runFakePromptWithLifecycle(&gateway, &deps, config, fixture.job(), lifecycle);

    const written = try readHookOutput(alloc, &user_fixture, "workspace/subagent-start.txt");
    defer alloc.free(written);
    try std.testing.expectEqualStrings("ran\n", written);
}

/// The hook output is exactly one line: the hook's input, then the newline its `echo` adds.
fn expectSingleLine(text: []const u8) !void {
    try std.testing.expect(text.len > 0 and text[text.len - 1] == '\n');
    try std.testing.expect(std.mem.find(u8, text[0 .. text.len - 1], "\n") == null);
}

test "model request hooks run around each model request" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const pre_path = try std.Io.Dir.path.join(alloc, &.{ user_fixture.workspace, "pre_model.txt" });
    defer alloc.free(pre_path);
    const post_path = try std.Io.Dir.path.join(alloc, &.{ user_fixture.workspace, "post_model.txt" });
    defer alloc.free(post_path);
    const pre_command = try std.mem.concat(alloc, u8, &.{ "cat >> '", pre_path, "'; echo >> '", pre_path, "'" });
    defer alloc.free(pre_command);
    const post_command = try std.mem.concat(alloc, u8, &.{ "cat >> '", post_path, "'; echo >> '", post_path, "'" });
    defer alloc.free(post_command);
    const hooks_json = try std.mem.concat(alloc, u8, &.{
        "{\"hooks\":{\"PreModelRequest\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"",
        pre_command,
        "\"}]}],\"PostModelRequest\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"",
        post_command,
        "\"}]}]}}",
    });
    defer alloc.free(hooks_json);
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &.{.{ .content = "answer" }});
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);

    const pre = try readHookOutput(alloc, &user_fixture, "workspace/pre_model.txt");
    defer alloc.free(pre);
    try expectSingleLine(pre);
    try std.testing.expect(std.mem.find(u8, pre, "claude-opus-4.6") != null);
    try std.testing.expect(std.mem.find(u8, pre, "\"message_count\":") != null);
    const post = try readHookOutput(alloc, &user_fixture, "workspace/post_model.txt");
    defer alloc.free(post);
    try expectSingleLine(post);
    try std.testing.expect(std.mem.find(u8, post, "\"outcome\":\"completed\"") != null);
}

test "a PostModelRequest hook sees a failed model request" {
    const alloc = std.testing.allocator;
    var user_fixture = try UserStopFixture.init(alloc);
    defer user_fixture.deinit(alloc);
    const post_path = try std.Io.Dir.path.join(alloc, &.{ user_fixture.workspace, "post_model.txt" });
    defer alloc.free(post_path);
    const post_command = try std.mem.concat(alloc, u8, &.{ "cat >> '", post_path, "'; echo >> '", post_path, "'" });
    defer alloc.free(post_command);
    const hooks_json = try startEventHooksJson(alloc, "PostModelRequest", post_command);
    defer alloc.free(hooks_json);
    var runtime = try user_fixture.startRuntime(alloc, hooks_json);
    defer runtime.deinit();
    var gateway = FakeGateway.init(alloc, &.{.{ .status = .bad_request, .err_body = "bad" }});
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    defer deps.deinit();
    var fixture = PromptFixture{};
    var lifecycle = testLifecycleContext(lifecycle_hooks.RuntimeView.empty(), alloc, user_fixture.workspace);
    lifecycle.user_hooks = &runtime;

    try runFakePromptWithLifecycle(&gateway, &deps, fixture.config(), fixture.job(), lifecycle);

    const post = try readHookOutput(alloc, &user_fixture, "workspace/post_model.txt");
    defer alloc.free(post);
    try std.testing.expect(std.mem.find(u8, post, "\"outcome\":\"") != null);
    try std.testing.expect(std.mem.find(u8, post, "\"outcome\":\"completed\"") == null);
}
