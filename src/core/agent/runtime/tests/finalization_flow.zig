const std = @import("std");
const types = @import("../../../shared/types.zig");
const debug_trace = @import("../../../shared/debug_trace.zig");
const io_mod = @import("../../../shared/io.zig");
const tool_result_errors = @import("../../../tooling/tool_result_errors.zig");
const lifecycle_hooks = @import("../../../hooks/hooks.zig");
const session_runtime = @import("../../../session/session.zig");

const test_support = @import("support.zig");
const runtime_finalization = @import("../finalization.zig");
const runtime_orchestrator = @import("../orchestrator.zig");
const runtime_telemetry = @import("../telemetry.zig");

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

test "processQueuedPrompt normal final completion propagates normalized history before finish event" {
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

    try std.testing.expectEqualStrings("Hello", hooks.history_assistant_text.?);
    try std.testing.expectEqualStrings("Hello", hooks.finish_assistant_text.?);
    try std.testing.expectEqual(@as(?types.TurnPresentationOutcome, .completed), hooks.finish_terminal_outcome);
    const newline_idx = logIndex(&hooks, "text:newline").?;
    const finish_idx = logIndex(&hooks, "event:finish_prompt").?;
    try std.testing.expect(newline_idx < finish_idx);
    try expectBodyNotContains(&gateway, 0, "<turn_aborted>");
}

test "processQueuedPrompt pauses missing finish without synthesizing output" {
    const alloc = std.testing.allocator;
    const completions = [_]FakeCompletion{.{ .omit_finish = true }};
    var gateway = FakeGateway.init(alloc, &completions);
    defer gateway.deinit();
    var hooks = FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    var fixture = PromptFixture{};

    var config = fixture.config();
    config.max_provider_attempts = 1;
    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expect(!textContains(&hooks, "Done."));
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
}

test "processQueuedPrompt pauses partial text without finish proof" {
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

    var config = fixture.config();
    config.max_provider_attempts = 1;
    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expect(textContains(&hooks, "Partial answer"));
    try std.testing.expect(!textContains(&hooks, "Done."));
    try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.system_notices.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
}

test "processQueuedPrompt pauses tool calls without finish proof" {
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
    config.max_provider_attempts = 1;

    try runFakePrompt(&gateway, &hooks, config, fixture.job());

    try std.testing.expectEqual(@as(usize, 0), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
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
        paused,
        model_error,
        length_limited,
    };
    const Case = struct {
        finish_reason: ?types.ProviderFinishReason = null,
        omit_finish: bool = false,
        expected: Expected,
    };
    const cases = [_]Case{
        .{ .omit_finish = true, .expected = .paused },
        .{ .finish_reason = .provider_error, .expected = .paused },
        .{ .finish_reason = .stop, .expected = .model_error },
        .{ .finish_reason = .length, .expected = .length_limited },
    };

    for (cases) |case| {
        const completions = [_]FakeCompletion{.{
            .tool_calls = &calls,
            .finish_reason = case.finish_reason,
            .omit_finish = case.omit_finish,
        }};
        var gateway = FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        var hooks = FakeAgentRuntimeDeps.init(alloc);
        if (case.finish_reason == .provider_error) hooks.enable_route_recovery = false;
        defer hooks.deinit();
        var fixture = PromptFixture{};

        var config = fixture.config();
        config.max_provider_attempts = 1;
        switch (case.expected) {
            .paused => try runFakePrompt(&gateway, &hooks, config, fixture.job()),
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

        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
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
        } else {
            try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
        }
        if (case.expected == .paused) {
            try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
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
    config.max_provider_attempts = 1;

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
    const trace_path = try std.fs.path.join(alloc, &.{ root, "finish-trace.log" });
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
    const trace_path = try std.fs.path.join(alloc, &.{ root, "trace.log" });
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
    try std.testing.expect(std.mem.find(u8, trace, "[agent] step limit reached turn_id=1 step_id=1 step_index=1 step_limit=1 gateway_messages=2 completed_tool_count=1 completed_tool_names=read_file last_tool_call_name=read_file last_tool_call_id=call_1 outcome_kind=step_limit") != null);
    try std.testing.expect(std.mem.find(u8, trace, "event=step_limit_reached turn_id=1 step_id=1 step_index=1 step_limit=1 gateway_messages=2 completed_tool_count=1 completed_tool_names=read_file last_tool_call_name=read_file last_tool_call_id=call_1 outcome_kind=step_limit") != null);
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
    deps.enable_route_recovery = false;
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
        deps.history_turns.items[0].assistant.assistant,
    );
    try std.testing.expectEqual(
        types.ProviderCompletionDisposition.length_limited,
        deps.finalized_disposition.?,
    );
}

test "common Stop continues once with exact synthetic context and joined history" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{ .chunks = &.{"candidate"}, .content = "candidate" },
        .{ .content = "final" },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.enable_route_recovery = false;
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
        "Continue the turn. Fx hook context:\\nverify the answer",
    );
    try std.testing.expectEqualStrings(
        "candidate\nfinal",
        deps.history_turns.items[0].assistant.assistant,
    );

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
    try expectBodyNotContains(
        &follow_gateway,
        0,
        "Continue the turn. Fx hook context",
    );
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
        deps.history_turns.items[0].assistant.assistant,
    );
}

test "common Stop cancellation during dispatch persists interrupted candidate" {
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

    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expectEqual(@as(usize, 1), deps.history_turns.items.len);
    try std.testing.expect(deps.history_turns.items[0] == .interrupted);
    try std.testing.expectEqualStrings(
        "candidate",
        deps.history_turns.items[0].interrupted.assistant.?,
    );
    try std.testing.expect(
        deps.history_turns.items[0].interrupted.execution.isEmpty(),
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
        deps.history_turns.items[0].interrupted.assistant.?,
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

test "common Stop later provider failure pauses with candidate still visible" {
    const alloc = std.testing.allocator;
    var gateway = FakeGateway.init(alloc, &.{
        .{ .chunks = &.{"candidate"}, .content = "candidate" },
        .{ .finish_reason = .provider_error },
    });
    defer gateway.deinit();
    var deps = FakeAgentRuntimeDeps.init(alloc);
    deps.enable_route_recovery = false;
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

    var config = fixture.config();
    config.max_provider_attempts = 1;
    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        config,
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expect(textContains(&deps, "candidate"));
    try std.testing.expectEqual(@as(usize, 0), deps.history_turns.items.len);
    try std.testing.expectEqual(
        types.TurnPresentationOutcome.paused,
        deps.finalized_outcome.?,
    );
    try std.testing.expectEqual(@as(usize, 0), deps.finish_event_count);
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
        deps.history_turns.items[0].assistant.assistant,
    );
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
        turn.assistant,
    );
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps.len);
    try std.testing.expectEqualStrings(
        "read_file",
        turn.execution.tool_steps[0].tool_calls[0].name,
    );
    try std.testing.expectEqual(
        types.PersistedToolStatus.success,
        turn.execution.tool_steps[0].tool_results[0].status,
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

    const assistant = deps.history_turns.items[0].assistant.assistant;
    try std.testing.expect(std.mem.startsWith(u8, assistant, "candidate\npartial"));
    try std.testing.expect(std.mem.find(u8, assistant, "did not execute") != null);
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
            deps.history_turns.items[0].assistant.assistant,
        );
        try std.testing.expectEqual(
            types.TurnPresentationOutcome.completed,
            deps.finalized_outcome.?,
        );
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

test "common Stop HTTP failure pauses with candidate and partial still visible" {
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

    var config = fixture.config();
    config.max_provider_attempts = 2;
    try runFakePromptWithLifecycle(
        &gateway,
        &deps,
        config,
        fixture.job(),
        testLifecycleContext(view, alloc, fixture.workspace_root),
    );

    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expect(textContains(&deps, "candidate"));
    try std.testing.expect(textContains(&deps, "later partial"));
    try std.testing.expectEqual(@as(usize, 0), deps.history_turns.items.len);
    try std.testing.expectEqual(@as(?std.http.Status, null), deps.http_status);
    try std.testing.expectEqual(
        types.TurnPresentationOutcome.paused,
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
    try std.testing.expectEqualStrings("candidate\nworking", turn.assistant);
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps.len);
    try std.testing.expectEqualStrings(
        "call_finish",
        turn.execution.tool_steps[0].tool_calls[0].id,
    );
    try std.testing.expectEqual(
        types.PersistedToolStatus.success,
        turn.execution.tool_steps[0].tool_results[0].status,
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
    try std.testing.expectEqualStrings("candidate", turn.assistant.?);
    try std.testing.expectEqualStrings("call_active", turn.tool_call.?.id);
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps.len);
    try std.testing.expectEqualStrings(
        "call_peer",
        turn.execution.tool_steps[0].tool_calls[0].id,
    );
    try std.testing.expectEqual(
        types.PersistedToolStatus.failure,
        turn.execution.tool_steps[0].tool_results[0].status,
    );
    try std.testing.expectEqualStrings(
        "plain peer result",
        turn.execution.tool_steps[0].tool_results[0].output,
    );
    try std.testing.expectEqual(
        types.FinishedPromptProjection.assistant_text,
        deps.finish_projection.?,
    );
}

test "common Stop interruption keeps only completed calls from a partially attempted step" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("call_completed", "read_file", "{\"path\":\"README.md\"}"),
        toolCall("call_cancelled", "browser_snapshot", "{}"),
        toolCall("call_unattempted", "grep_files", "{\"pattern\":\"Hooks\"}"),
    };
    var gateway = FakeGateway.init(alloc, &.{
        .{ .content = "candidate" },
        .{ .tool_calls = &calls },
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

    try std.testing.expectEqual(@as(usize, 2), deps.executed_names.items.len);
    const turn = deps.history_turns.items[0].interrupted;
    try std.testing.expectEqualStrings("call_cancelled", turn.tool_call.?.id);
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps[0].tool_calls.len);
    try std.testing.expectEqualStrings(
        "call_completed",
        turn.execution.tool_steps[0].tool_calls[0].id,
    );
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps[0].tool_results.len);
    try std.testing.expectEqualStrings(
        "completed result",
        turn.execution.tool_steps[0].tool_results[0].output,
    );
}

test "common Stop parallel cancellation preserves ordinary cancelled peer as completed failure" {
    const alloc = std.testing.allocator;
    const calls = [_]ToolCall{
        toolCall("call_ordinary_cancel", "read_file", "{\"path\":\"README.md\"}"),
        toolCall("call_owner_signal", "grep_files", "{\"pattern\":\"Hooks\"}"),
        toolCall("call_completed_peer", "file_info", "{\"path\":\"src/main.zig\"}"),
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
    try std.testing.expectEqualStrings("candidate", turn.assistant.?);
    try std.testing.expect(turn.tool_call == null);
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps.len);
    const step = turn.execution.tool_steps[0];
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
    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
    const step = execution.tool_steps[0];
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
    try std.testing.expectEqual(@as(usize, 4), replay.items.len);
    try std.testing.expectEqual(@as(usize, 1), replay.items[1].tool_calls.len);
    try std.testing.expectEqualStrings(
        "call_completed",
        replay.items[1].tool_calls[0].id,
    );
    try std.testing.expectEqualStrings(
        "call_completed",
        replay.items[2].tool_call_id.?,
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
    const alloc = std.testing.allocator;
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
            "candidate",
            .failed,
            null,
            &finish_trace,
            "error",
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
        try finalization.finish(case.outcome, case.disposition, null);
        try finalization.finish(.failed, null, null);
    }

    try std.testing.expectEqual(cases.len, deps.finalization_count);
    try std.testing.expectEqual(cases.len, hook_capture.calls);
    for (cases, 0..) |case, index| {
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), hook_capture.turn_ids[index]);
        try std.testing.expectEqual(case.scope_kind, hook_capture.scope_kinds[index]);
        try std.testing.expect(hook_capture.workspace_matches[index]);
        try std.testing.expectEqual(case.outcome, hook_capture.outcomes[index]);
        try std.testing.expectEqual(case.disposition, hook_capture.dispositions[index]);
    }
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
