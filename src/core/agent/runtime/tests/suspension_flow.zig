const std = @import("std");
const support = @import("support.zig");
const types = @import("../../../shared/types.zig");
const codec = @import("../../../session/session_codec.zig");
const recovery = @import("../model_response_recovery.zig");

const calls = [_]types.ToolCall{
    support.toolCall("settle-one", "read_file", "{\"path\":\"one.txt\"}"),
    support.toolCall("settle-two", "read_file", "{\"path\":\"two.txt\"}"),
};

fn observe_pause_boundary(hooks: *support.FakeAgentRuntimeDeps, checkpoint: codec.RecoveryCheckpoint) !void {
    if (checkpoint.action != .paused) return;
    try std.testing.expectEqual(@as(usize, 0), hooks.finalization_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 2), hooks.executed_call_ids.items.len);
    try std.testing.expectEqual(@as(usize, 1), checkpoint.execution.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 2), checkpoint.execution.tool_steps[0].tool_results.len);
    try std.testing.expect(!checkpoint.outstanding_reservation);
}

fn round_trip_checkpoint(alloc: std.mem.Allocator, checkpoint: codec.RecoveryCheckpoint) !codec.RecoveryCheckpoint {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try codec.writeRecoveryCheckpoint(&out.writer, checkpoint);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    return codec.parseRecoveryCheckpoint(alloc, parsed.value);
}

fn expect_control_status(hooks: *const support.FakeAgentRuntimeDeps, kind: types.RouteRecoveryStatus.Kind) !void {
    const status = hooks.route_recovery_statuses.getLast();
    try std.testing.expectEqual(kind, status.kind);
    try std.testing.expectEqual(@as(usize, 0), status.reportedAttempt());
    try std.testing.expectEqual(@as(usize, 0), status.attempt_limit);
    try std.testing.expectEqual(@as(u64, 0), status.delay_seconds);
    try std.testing.expect(status.retry_deadline == null);
    try std.testing.expect(status.diagnostic == null);
    try std.testing.expect(!status.isRecovered());
    var buffer: [types.RouteRecoveryStatus.label_max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(if (kind == .suspended)
        "Suspended at a safe boundary · context preserved"
    else
        "Tool state uncertain · inspect before continuing", status.label(&buffer));
}

fn expect_paused(hooks: *const support.FakeAgentRuntimeDeps) !void {
    try std.testing.expectEqual(types.TurnPresentationOutcome.paused, hooks.finalized_outcome.?);
    try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
    try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
}

test "suspension orchestrator settles selected group while model or tool active and resumes results once" {
    for ([_]bool{ true, false }) |during_model| {
        const alloc = std.testing.allocator;
        var flag = std.atomic.Value(bool).init(false);
        var fixture = support.PromptFixture{};
        var config = fixture.config();
        config.suspend_flag = &flag;
        // A pending suspension must win over the step-limit finish-history path.
        config.agent_step_limit = 1;
        const completions = [_]support.FakeCompletion{.{
            .tool_calls = &calls,
            .suspend_before_output = during_model,
        }};
        var gateway = support.FakeGateway.init(alloc, &completions);
        defer gateway.deinit();
        gateway.suspend_flag = &flag;
        var hooks = support.FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        hooks.enable_recovery_checkpoint = true;
        hooks.observe_recovery_checkpoint = observe_pause_boundary;
        if (!during_model) hooks.suspend_on_execute = &flag;
        var lifecycle = support.testLifecycleContext(@import("../../../hooks/hooks.zig").RuntimeView.empty(), alloc, config.workspace_root);
        lifecycle.scope.kind = if (during_model) .interactive else .acp;
        try support.runFakePromptWithLifecycle(&gateway, &hooks, config, fixture.job(), lifecycle);
        try expect_paused(&hooks);
        try std.testing.expect(!fixture.cancel_flag.load(.seq_cst));
        try std.testing.expectEqual(@as(usize, 1), gateway.index);
        try std.testing.expectEqual(@as(usize, 2), hooks.executed_call_ids.items.len);
        try std.testing.expectEqual(@as(usize, 2), hooks.permission_call_ids.items.len);
        const checkpoint = hooks.recovery_checkpoints.getLast();
        try expect_control_status(&hooks, .suspended);
        try std.testing.expectEqual(types.ModelRecoveryCause.suspended, checkpoint.cause);
        try std.testing.expectEqual(codec.RecoveryToolState.confirmed, checkpoint.tool_state);
        try std.testing.expect(!checkpoint.outstanding_reservation);
        try std.testing.expectEqual(@as(usize, 1), checkpoint.execution.tool_steps.len);
        try std.testing.expectEqual(@as(usize, 2), checkpoint.execution.tool_steps[0].tool_results.len);

        flag.store(false, .seq_cst);
        var resumed_gateway = support.FakeGateway.init(alloc, &.{.{ .content = "Finished from saved results." }});
        defer resumed_gateway.deinit();
        var resumed_hooks = support.FakeAgentRuntimeDeps.init(alloc);
        defer resumed_hooks.deinit();
        resumed_hooks.enable_recovery_checkpoint = true;
        var job = fixture.job();
        var restored = try round_trip_checkpoint(alloc, checkpoint);
        defer restored.deinit(alloc);
        job.recovery_checkpoint = restored;
        try support.runFakePrompt(&resumed_gateway, &resumed_hooks, config, job);
        try std.testing.expectEqual(types.TurnPresentationOutcome.completed, resumed_hooks.finalized_outcome.?);
        try std.testing.expectEqual(@as(usize, 0), resumed_hooks.route_recovery_statuses.items.len);
        try std.testing.expectEqual(@as(usize, 1), resumed_gateway.index);
        try std.testing.expectEqual(@as(usize, 0), resumed_hooks.executed_call_ids.items.len);
        try support.expectBodyContains(&resumed_gateway, 0, "settle-one");
        try support.expectBodyContains(&resumed_gateway, 0, "settle-two");
    }
}

test "suspension continuation still recovers an actual transport failure" {
    const alloc = std.testing.allocator;
    for ([_]anyerror{ error.ReadFailed, error.SystemResumed }) |failure| {
        var fixture = support.PromptFixture{};
        var flag = std.atomic.Value(bool).init(true);
        var config = fixture.config();
        config.suspend_flag = &flag;
        var gateway = support.FakeGateway.init(alloc, &.{});
        defer gateway.deinit();
        var hooks = support.FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        hooks.enable_recovery_checkpoint = true;
        try support.runFakePrompt(&gateway, &hooks, config, fixture.job());
        var checkpoint = try round_trip_checkpoint(alloc, hooks.recovery_checkpoints.getLast());
        defer checkpoint.deinit(alloc);
        var job = fixture.job();
        job.recovery_checkpoint = checkpoint;
        flag.store(false, .seq_cst);
        var resumed_gateway = support.FakeGateway.init(alloc, &.{
            .{ .stream_error = failure },
            .{ .content = "Finished after a real retry." },
        });
        defer resumed_gateway.deinit();
        var resumed_hooks = support.FakeAgentRuntimeDeps.init(alloc);
        defer resumed_hooks.deinit();
        resumed_hooks.enable_recovery_checkpoint = true;
        try support.runFakePrompt(&resumed_gateway, &resumed_hooks, config, job);
        try std.testing.expectEqual(types.TurnPresentationOutcome.completed, resumed_hooks.finalized_outcome.?);
        try std.testing.expectEqual(@as(usize, 2), resumed_gateway.request_bodies.items.len);
        // Existing transport recovery emits a waiting status, then the due
        // request status, then success. Suspension itself emits none of these.
        try std.testing.expectEqual(@as(usize, 3), resumed_hooks.route_recovery_statuses.items.len);
        const retry = resumed_hooks.route_recovery_statuses.items[0];
        try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.auto_retry, retry.kind);
        try std.testing.expectEqual(if (failure == error.SystemResumed) types.ModelRecoveryCause.system_resumed else .network_interrupted, retry.cause.?);
        try std.testing.expectEqual(@as(usize, 1), retry.failed_attempt);
        const due = resumed_hooks.route_recovery_statuses.items[1];
        try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.auto_retry, due.kind);
        try std.testing.expectEqual(retry.cause, due.cause);
        try std.testing.expectEqual(@as(usize, 2), due.failed_attempt);
        const recovered = resumed_hooks.route_recovery_statuses.items[2];
        try std.testing.expectEqual(types.RouteRecoveryStatus.Kind.auto_recovered, recovered.kind);
        try std.testing.expectEqual(@as(usize, 2), recovered.succeeded_attempt);
    }
}

test "suspension orchestrator lets final text-only response finish normally" {
    const alloc = std.testing.allocator;
    var fixture = support.PromptFixture{};
    var flag = std.atomic.Value(bool).init(false);
    var config = fixture.config();
    config.suspend_flag = &flag;
    var gateway = support.FakeGateway.init(alloc, &.{.{ .content = "Final answer.", .suspend_before_output = true }});
    defer gateway.deinit();
    gateway.suspend_flag = &flag;
    var hooks = support.FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    try support.runFakePrompt(&gateway, &hooks, config, fixture.job());
    try std.testing.expect(!fixture.cancel_flag.load(.seq_cst));
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, hooks.finalized_outcome.?);
    try std.testing.expectEqual(@as(usize, 1), hooks.finish_event_count);
}

test "suspension orchestrator fails closed without storage or with failed or lost durable ack" {
    const Failure = enum { unavailable, before_write, lost_ack };
    for ([_]Failure{ .unavailable, .before_write, .lost_ack }) |failure| {
        const alloc = std.testing.allocator;
        var fixture = support.PromptFixture{};
        var flag = std.atomic.Value(bool).init(false);
        var config = fixture.config();
        config.suspend_flag = &flag;
        var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &calls, .suspend_before_output = true }});
        defer gateway.deinit();
        gateway.suspend_flag = &flag;
        var hooks = support.FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        hooks.enable_recovery_checkpoint = failure != .unavailable;
        hooks.recovery_checkpoint_lose_pause_ack = failure == .lost_ack;
        if (failure == .before_write) hooks.recovery_checkpoint_pause_error = error.TestWriteFailed;
        hooks.observe_recovery_checkpoint = observe_pause_boundary;
        try std.testing.expectError(
            if (failure == .unavailable) error.SuspensionCheckpointUnavailable else error.SuspensionCheckpointUncertain,
            support.runFakePrompt(&gateway, &hooks, config, fixture.job()),
        );
        try std.testing.expectEqual(@as(usize, 1), gateway.index);
        try std.testing.expectEqual(@as(usize, 2), hooks.executed_call_ids.items.len);
        try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
        try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
        try std.testing.expectEqual(types.TurnPresentationOutcome.failed, hooks.finalized_outcome.?);
        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
        if (failure == .lost_ack) try std.testing.expectEqual(types.ModelRecoveryAction.paused, hooks.recovery_checkpoints.getLast().action);
    }
}

test "suspension recovery uncertainty cannot reserve a request even if definitely unsent" {
    for ([_]recovery.Delivery{ .definitely_unsent, .possibly_sent }) |delivery| {
        const decision = recovery.decide(.{
            .cause = .tool_state_uncertain,
            .delivery = delivery,
            .attempts = .{ .consumed = 1 },
            .tool = .uncertain,
        });
        try std.testing.expectEqual(recovery.Strategy.pause, decision.strategy);
        try std.testing.expectEqual(recovery.RequiredAction.inspect_uncertain_tool, decision.required_action);
        try std.testing.expect(!decision.reserve_provider_attempt);
    }
}

test "suspension orchestrator rejects uncertain restored effects before provider admission" {
    const alloc = std.testing.allocator;
    var fixture = support.PromptFixture{};
    var job = fixture.job();
    job.recovery_checkpoint = .{
        .turn_id = 1,
        .user = .{ .text = job.prompt },
        .assistant_source = @constCast(""),
        .cause = .network_interrupted,
        .action = .paused,
        .tool_state = .uncertain,
        .authority = .{
            .provider = job.provider,
            .model = job.model,
            .credential_source = job.credential_source,
            .credential_identity = @import("../../../auth/credential_authority.zig").derive(job.credential_source.?, job.account_id),
        },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 10,
        .consumed_provider_attempts = 0,
    };
    var gateway = support.FakeGateway.init(alloc, &.{});
    defer gateway.deinit();
    var hooks = support.FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    try std.testing.expectError(error.RecoveryEffectsUncertain, support.runFakePrompt(&gateway, &hooks, fixture.config(), job));
    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.executed_call_ids.items.len);
    job.recovery_checkpoint.?.tool_state = .none;
    job.recovery_checkpoint.?.cause = .tool_state_uncertain;
    try std.testing.expectError(error.RecoveryEffectsUncertain, support.runFakePrompt(&gateway, &hooks, fixture.config(), job));
    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
    job.recovery_checkpoint.?.cause = .suspended;
    job.recovery_checkpoint.?.outstanding_reservation = true;
    try std.testing.expectError(error.RecoveryEffectsUncertain, support.runFakePrompt(&gateway, &hooks, fixture.config(), job));
    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
}

test "suspension orchestrator records post-effect uncertainty and refuses resume" {
    const alloc = std.testing.allocator;
    const Effect = struct {
        flag: *std.atomic.Value(bool),
        count: usize = 0,
        fn execute(raw: *anyopaque, _: @import("../tool_contracts.zig").ToolExecutionRequest) !@import("../tool_contracts.zig").ToolExecutionResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
            self.flag.store(true, .seq_cst);
            return error.TestEffectAckLost;
        }
    };
    var fixture = support.PromptFixture{};
    var flag = std.atomic.Value(bool).init(false);
    var effect = Effect{ .flag = &flag };
    var config = fixture.config();
    config.suspend_flag = &flag;
    var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &.{effect_call} }});
    defer gateway.deinit();
    var hooks = support.FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.enable_recovery_checkpoint = true;
    hooks.execute_delegate = .{ .ctx = &effect, .run = Effect.execute };
    try support.runFakePrompt(&gateway, &hooks, config, fixture.job());
    try expect_paused(&hooks);
    try std.testing.expectEqual(@as(usize, 1), effect.count);
    const checkpoint = hooks.recovery_checkpoints.getLast();
    try std.testing.expectEqual(codec.RecoveryToolState.uncertain, checkpoint.tool_state);
    try expect_control_status(&hooks, .tool_state_uncertain);
    try std.testing.expectEqual(types.ModelRecoveryCause.tool_state_uncertain, checkpoint.cause);
    try std.testing.expectEqual(types.ModelRecoveryRequiredAction.inspect_uncertain_tool, hooks.route_recovery_statuses.getLast().required_action);
    flag.store(false, .seq_cst);
    var job = fixture.job();
    job.recovery_checkpoint = checkpoint;
    try std.testing.expectError(error.RecoveryEffectsUncertain, support.runFakePrompt(&gateway, &hooks, config, job));
    try std.testing.expectEqual(@as(usize, 1), gateway.index);
    try std.testing.expectEqual(@as(usize, 1), effect.count);
}

const effect_call = support.toolCall("committed-effect", "shell", "{\"action\":\"run\",\"command\":\"printf effect\"}");

test "suspension orchestrator does not replay a committed local call ID on resume" {
    const alloc = std.testing.allocator;
    var fixture = support.PromptFixture{};
    var flag = std.atomic.Value(bool).init(false);
    var config = fixture.config();
    config.suspend_flag = &flag;
    var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &.{effect_call} }});
    defer gateway.deinit();
    var hooks = support.FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.suspend_on_execute = &flag;
    hooks.enable_recovery_checkpoint = true;
    try support.runFakePrompt(&gateway, &hooks, config, fixture.job());
    try expect_paused(&hooks);
    try std.testing.expectEqual(@as(usize, 1), hooks.successful_effect_count.load(.seq_cst));
    flag.store(false, .seq_cst);
    var job = fixture.job();
    job.recovery_checkpoint = hooks.recovery_checkpoints.getLast();
    var replay = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &.{effect_call} }});
    defer replay.deinit();
    var resumed = support.FakeAgentRuntimeDeps.init(alloc);
    defer resumed.deinit();
    resumed.enable_recovery_checkpoint = true;
    try std.testing.expectError(error.RecoveryCommittedToolReplay, support.runFakePrompt(&replay, &resumed, config, job));
    try std.testing.expectEqual(@as(usize, 0), resumed.executed_names.items.len);
    try std.testing.expectEqual(@as(usize, 0), resumed.permission_names.items.len);
}

test "suspension orchestrator keeps permission denial and safe calls in the same checkpoint" {
    const alloc = std.testing.allocator;
    var fixture = support.PromptFixture{};
    var flag = std.atomic.Value(bool).init(false);
    var config = fixture.config();
    config.suspend_flag = &flag;
    var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &calls, .suspend_before_output = true }});
    defer gateway.deinit();
    gateway.suspend_flag = &flag;
    var hooks = support.FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.enable_recovery_checkpoint = true;
    hooks.permission_decisions = &.{ .policy_denied, .once };
    try support.runFakePrompt(&gateway, &hooks, config, fixture.job());
    try expect_paused(&hooks);
    try std.testing.expectEqual(@as(usize, 2), hooks.permission_names.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.executed_names.items.len);
    try std.testing.expectEqualStrings("settle-two", hooks.executed_call_ids.items[0]);
    try std.testing.expectEqual(@as(usize, 0), hooks.propagated_grants.items.len);
    const results = hooks.recovery_checkpoints.getLast().execution.tool_steps[0].tool_results;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("settle-one", results[0].tool_call_id);
    try std.testing.expectEqualStrings("settle-two", results[1].tool_call_id);
}

test "suspension orchestrator preserves parallel executor uncertainty after all calls settle" {
    const alloc = std.testing.allocator;
    var fixture = support.PromptFixture{};
    var flag = std.atomic.Value(bool).init(false);
    var config = fixture.config();
    config.suspend_flag = &flag;
    var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &calls }});
    defer gateway.deinit();
    var hooks = support.FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.enable_recovery_checkpoint = true;
    hooks.suspend_on_execute = &flag;
    hooks.exec_plans = &.{ .{ .err = error.TestEffectAckLost }, .{ .result = .{ .model_output = "settled" } } };
    try support.runFakePrompt(&gateway, &hooks, config, fixture.job());
    try expect_paused(&hooks);
    try std.testing.expectEqual(@as(usize, 2), hooks.executed_call_ids.items.len);
    try std.testing.expectEqual(codec.RecoveryToolState.uncertain, hooks.recovery_checkpoints.getLast().tool_state);
    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
}

test "suspension orchestrator waits for result commit and rejects its lost acknowledgement" {
    const Commit = struct {
        fail: bool,
        commits: usize = 0,
        cancels: usize = 0,
        fn commit(raw: *anyopaque, _: u64) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.commits += 1;
            if (self.fail) return error.TestResultCommitAckLost;
        }
        fn cancel(raw: *anyopaque, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.cancels += 1;
        }
    };
    for ([_]bool{ false, true }) |fail| {
        const alloc = std.testing.allocator;
        var fixture = support.PromptFixture{};
        var flag = std.atomic.Value(bool).init(false);
        var config = fixture.config();
        config.suspend_flag = &flag;
        var commit = Commit{ .fail = fail };
        var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &.{effect_call} }});
        defer gateway.deinit();
        var hooks = support.FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        hooks.enable_recovery_checkpoint = true;
        hooks.suspend_on_execute = &flag;
        hooks.exec_plans = &.{.{ .result = .{
            .model_output = "effect result",
            .result_commit = .{ .context = &commit, .identity = 1, .commit_fn = Commit.commit, .cancel_fn = Commit.cancel },
        } }};
        const result = support.runFakePrompt(&gateway, &hooks, config, fixture.job());
        if (fail) {
            try std.testing.expectError(error.SuspensionCheckpointUncertain, result);
            try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
            try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
            var job = fixture.job();
            job.recovery_checkpoint = hooks.recovery_checkpoints.getLast();
            try std.testing.expectEqual(codec.RecoveryToolState.uncertain, job.recovery_checkpoint.?.tool_state);
            flag.store(false, .seq_cst);
            try std.testing.expectError(error.RecoveryEffectsUncertain, support.runFakePrompt(&gateway, &hooks, config, job));
        } else {
            try result;
            try expect_paused(&hooks);
            try std.testing.expectEqual(@as(usize, 0), commit.cancels);
        }
        try std.testing.expectEqual(@as(usize, 1), commit.commits);
        try std.testing.expectEqual(@as(usize, 1), hooks.successful_effect_count.load(.seq_cst));
        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    }
}

test "suspension orchestrator pauses before tool-driven finish history" {
    for ([_]bool{ false, true }) |pending| {
        const alloc = std.testing.allocator;
        var fixture = support.PromptFixture{};
        var flag = std.atomic.Value(bool).init(false);
        var config = fixture.config();
        config.suspend_flag = &flag;
        var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = if (pending) &.{ effect_call, calls[0] } else &.{effect_call} }});
        defer gateway.deinit();
        var hooks = support.FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        hooks.enable_recovery_checkpoint = true;
        hooks.suspend_on_execute = &flag;
        hooks.exec_plans = &.{.{ .result = .{ .model_output = "finished effect", .finish_turn = true } }};
        try support.runFakePrompt(&gateway, &hooks, config, fixture.job());
        try expect_paused(&hooks);
        const checkpoint = hooks.recovery_checkpoints.getLast();
        try std.testing.expectEqual(if (pending) codec.RecoveryToolState.uncertain else .confirmed, checkpoint.tool_state);
        if (pending) {
            var job = fixture.job();
            job.recovery_checkpoint = checkpoint;
            flag.store(false, .seq_cst);
            try std.testing.expectError(error.RecoveryEffectsUncertain, support.runFakePrompt(&gateway, &hooks, config, job));
        }
        try std.testing.expectEqual(@as(usize, 1), hooks.successful_effect_count.load(.seq_cst));
        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    }
}

fn expect_uncertain_reload_blocked(
    fixture: *support.PromptFixture,
    hooks: *support.FakeAgentRuntimeDeps,
) !void {
    try expect_paused(hooks);
    var checkpoint = try round_trip_checkpoint(std.testing.allocator, hooks.recovery_checkpoints.getLast());
    defer checkpoint.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.ModelRecoveryCause.tool_state_uncertain, checkpoint.cause);
    try expect_control_status(hooks, .tool_state_uncertain);
    try std.testing.expectEqual(codec.RecoveryToolState.uncertain, checkpoint.tool_state);
    fixture.cancel_flag.store(false, .seq_cst);
    var job = fixture.job();
    job.recovery_checkpoint = checkpoint;
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{});
    defer gateway.deinit();
    var reloaded = support.FakeAgentRuntimeDeps.init(std.testing.allocator);
    defer reloaded.deinit();
    try std.testing.expectError(error.RecoveryEffectsUncertain, support.runFakePrompt(&gateway, &reloaded, fixture.config(), job));
    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 0), reloaded.executed_call_ids.items.len);
    try std.testing.expectEqual(@as(usize, 0), reloaded.history_turns.items.len);
}

test "suspension uncertainty survives a later MCP input-required finish without suspend request" {
    for ([_]bool{ false, true }) |provide_flag| {
        const alloc = std.testing.allocator;
        var fixture = support.PromptFixture{};
        var flag = std.atomic.Value(bool).init(false);
        var config = fixture.config();
        if (provide_flag) config.suspend_flag = &flag;
        const selected = [_]types.ToolCall{ effect_call, support.toolCall("input-required", "read_file", "{\"path\":\"input.txt\"}") };
        var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &selected }});
        defer gateway.deinit();
        var hooks = support.FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        hooks.enable_recovery_checkpoint = true;
        hooks.exec_plans = &.{
            .{ .err = error.HostToolOutcomeUncertain },
            .{ .result = .{ .status = .failure, .model_output = "MCP input required", .finish_turn = true, .status_detail = "McpInputRequired" } },
        };
        try support.runFakePrompt(&gateway, &hooks, config, fixture.job());
        try std.testing.expectEqual(@as(usize, 2), hooks.executed_call_ids.items.len);
        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
        try std.testing.expect(!flag.load(.seq_cst));
        try expect_uncertain_reload_blocked(&fixture, &hooks);
    }
}

test "suspension uncertainty survives finish handoff failure without suspend request" {
    for ([_]bool{ false, true }) |has_store| {
        const alloc = std.testing.allocator;
        var fixture = support.PromptFixture{};
        const selected = [_]types.ToolCall{ effect_call, calls[0] };
        var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &selected }});
        defer gateway.deinit();
        var hooks = support.FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        hooks.enable_recovery_checkpoint = has_store;
        hooks.recovery_checkpoint_lose_pause_ack = has_store;
        hooks.exec_plans = &.{
            .{ .err = error.HostToolOutcomeUncertain },
            .{ .result = .{ .status = .failure, .model_output = "MCP input required", .finish_turn = true } },
        };
        try std.testing.expectError(
            if (has_store) error.SuspensionCheckpointUncertain else error.SuspensionCheckpointUnavailable,
            support.runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job()),
        );
        try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
        try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
        try std.testing.expectEqual(@as(usize, 2), hooks.executed_call_ids.items.len);
        if (has_store) try std.testing.expectEqual(codec.RecoveryToolState.uncertain, hooks.recovery_checkpoints.getLast().tool_state);
    }
}

test "suspension uncertainty survives entered host executor cancellation without durable result" {
    for ([_]anyerror{ error.Cancelled, error.HostToolOutcomeUncertain }) |failure| {
        const alloc = std.testing.allocator;
        var fixture = support.PromptFixture{};
        var flag = std.atomic.Value(bool).init(false);
        var config = fixture.config();
        config.suspend_flag = &flag;
        const selected = [_]types.ToolCall{ effect_call, calls[0] };
        var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &selected }});
        defer gateway.deinit();
        var hooks = support.FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        hooks.enable_recovery_checkpoint = true;
        hooks.cancel_on_execute = &fixture.cancel_flag;
        hooks.exec_plans = &.{.{ .err = failure }};
        try support.runFakePrompt(&gateway, &hooks, config, fixture.job());
        try std.testing.expectEqual(@as(usize, 1), hooks.executed_call_ids.items.len);
        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
        try expect_uncertain_reload_blocked(&fixture, &hooks);
    }
}

test "suspension uncertainty survives later permission cancellation or callback failure" {
    for ([_]bool{ false, true }) |cancel| {
        const alloc = std.testing.allocator;
        var fixture = support.PromptFixture{};
        const selected = [_]types.ToolCall{ effect_call, calls[0] };
        var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &selected }});
        defer gateway.deinit();
        var hooks = support.FakeAgentRuntimeDeps.init(alloc);
        defer hooks.deinit();
        hooks.enable_recovery_checkpoint = true;
        hooks.exec_plans = &.{.{ .err = error.HostToolOutcomeUncertain }};
        hooks.permission_errors = &.{ null, if (cancel) error.Cancelled else error.TestPermissionUnavailable };
        if (cancel) {
            hooks.cancel_on_permission = &fixture.cancel_flag;
            hooks.cancel_on_permission_name = "read_file";
        }
        const result = support.runFakePrompt(&gateway, &hooks, fixture.config(), fixture.job());
        if (cancel) {
            try result;
            try expect_uncertain_reload_blocked(&fixture, &hooks);
        } else {
            try std.testing.expectError(error.RecoveryEffectsUncertain, result);
            try std.testing.expectEqual(@as(usize, 0), hooks.history_turns.items.len);
            try std.testing.expectEqual(@as(usize, 0), hooks.finish_event_count);
            try std.testing.expectEqual(codec.RecoveryToolState.uncertain, hooks.recovery_checkpoints.getLast().tool_state);
        }
        try std.testing.expectEqual(@as(usize, 1), hooks.executed_call_ids.items.len);
        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    }
}

test "suspension uncertainty survives parallel entered executor cancellation" {
    const alloc = std.testing.allocator;
    var fixture = support.PromptFixture{};
    var flag = std.atomic.Value(bool).init(false);
    var config = fixture.config();
    config.suspend_flag = &flag;
    var job = fixture.job();
    job.permission_mode = .yolo;
    var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = &calls }});
    defer gateway.deinit();
    var hooks = support.FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.enable_recovery_checkpoint = true;
    hooks.cancel_on_execute = &fixture.cancel_flag;
    hooks.exec_plans = &.{ .{ .err = error.Cancelled }, .{ .err = error.Cancelled } };
    try support.runFakePrompt(&gateway, &hooks, config, job);
    try std.testing.expect(hooks.executed_call_ids.items.len > 0);
    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    try expect_uncertain_reload_blocked(&fixture, &hooks);
}

test "suspension orchestrator requested before a model call checkpoints without sending" {
    const alloc = std.testing.allocator;
    var fixture = support.PromptFixture{};
    var flag = std.atomic.Value(bool).init(true);
    var config = fixture.config();
    config.suspend_flag = &flag;
    var gateway = support.FakeGateway.init(alloc, &.{});
    defer gateway.deinit();
    var hooks = support.FakeAgentRuntimeDeps.init(alloc);
    defer hooks.deinit();
    hooks.enable_recovery_checkpoint = true;
    try support.runFakePrompt(&gateway, &hooks, config, fixture.job());
    try expect_paused(&hooks);
    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 1), hooks.recovery_checkpoints.items.len);
    try std.testing.expectEqual(@as(usize, 0), hooks.recovery_checkpoints.getLast().consumed_provider_attempts);
    try expect_control_status(&hooks, .suspended);
    var checkpoint = try round_trip_checkpoint(alloc, hooks.recovery_checkpoints.getLast());
    defer checkpoint.deinit(alloc);
    try std.testing.expectEqual(types.ModelRecoveryCause.suspended, checkpoint.cause);
    var job = fixture.job();
    job.recovery_checkpoint = checkpoint;
    flag.store(false, .seq_cst);
    var resumed_gateway = support.FakeGateway.init(alloc, &.{.{ .content = "First response after suspension." }});
    defer resumed_gateway.deinit();
    var resumed_hooks = support.FakeAgentRuntimeDeps.init(alloc);
    defer resumed_hooks.deinit();
    resumed_hooks.enable_recovery_checkpoint = true;
    try support.runFakePrompt(&resumed_gateway, &resumed_hooks, config, job);
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, resumed_hooks.finalized_outcome.?);
    try std.testing.expectEqual(@as(usize, 1), resumed_gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 0), resumed_hooks.route_recovery_statuses.items.len);
}
