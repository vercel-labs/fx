//! Acceptance witnesses against the real shared orchestrator and journal.
//! A cut copies only bytes acknowledged before the boundary; letting the first
//! run finish afterwards merely cleans up its allocator. No later checkpoint,
//! finalization, cancellation, or exception is imported into the crashed owner.
//! The SDK/native process tests separately exercise actual process death.
const std = @import("std");
const support = @import("support.zig");
const codec = @import("../../../session/session_codec.zig");
const types = @import("../../../shared/types.zig");
const contracts = @import("../tool_contracts.zig");
const agent_mod = @import("../agent.zig");
const orchestrator = @import("../orchestrator.zig");
const hooks_mod = @import("../../../hooks/hooks.zig");
const journal = @import("../../../session/execution_journal.zig");
const entry_codec = @import("../../../session/execution_journal_codec.zig");
const journal_runtime = @import("../journal_runtime.zig");
const builtin_tools = @import("../../../../builtins/tools.zig");
const tool_dispatch = @import("../../../tooling/tool_dispatch.zig");

const calls = [_]types.ToolCall{
    support.toolCall("journal-call-a", "shell", "{\"action\":\"run\",\"command\":\"effect-a\"}"),
    support.toolCall("journal-call-b", "shell", "{\"action\":\"run\",\"command\":\"effect-b\"}"),
};

// This descriptor belongs only to the atomic receipt fixture below. Ordinary
// shell tools retain their default blocked policy in production and controls.
const safe_tools = [_]tool_dispatch.Tool{blk: {
    var tool = builtin_tools.shell;
    tool.journal_replay = .safe;
    break :blk tool;
}};

const Witness = struct {
    hooks: support.FakeAgentRuntimeDeps,
    state: journal.State = .{},
    durable: std.ArrayList(entry_codec.OwnedEntry) = .empty,
    before_tools: [2]?journal.State = .{ null, null },
    after_effect: [2]?journal.State = .{ null, null },
    before_end: ?journal.State = null,
    fail_history: bool = false,
    call_ids: [2]?[]u8 = .{ null, null },
    recovering_calls: [2]?bool = .{ null, null },
    entries: usize = 0,
    effects: usize = 0,
    receipts: [2]bool = .{ false, false },
    fail_entry: ?journal.Kind = null,
    fail_model_request: bool = false,
    legacy: bool = false,
    expected_calls: []const types.ToolCall = &calls,
    cancel_after_effect: ?*std.atomic.Value(bool) = null,
    abandon_cancelled: bool = false,
    configured_result_limit: ?usize = null,
    admitted_result_limit: usize = 0,
    work_id: ?[]const u8 = null,

    fn init() Witness {
        return .{ .hooks = support.FakeAgentRuntimeDeps.init(std.testing.allocator) };
    }

    fn deinit(self: *Witness) void {
        const alloc = std.testing.allocator;
        for (&self.before_tools) |*cut| if (cut.*) |*state| state.deinit(alloc);
        for (&self.after_effect) |*cut| if (cut.*) |*state| state.deinit(alloc);
        if (self.before_end) |*state| state.deinit(alloc);
        for (self.call_ids) |id| if (id) |owned| alloc.free(owned);
        for (self.durable.items) |*entry| entry.deinit(alloc);
        self.durable.deinit(alloc);
        self.state.deinit(alloc);
        self.hooks.deinit();
    }

    fn append(raw: *anyopaque, entry: journal.Entry) !void {
        const self: *Witness = @ptrCast(@alignCast(raw));
        const alloc = std.testing.allocator;
        if (entry.kind == .turn_end and self.before_end == null) self.before_end = try self.capture();
        const previous = if (self.durable.items.len == 0) 0 else self.durable.getLast().entry.seq;
        if (entry.seq != previous + 1) return error.UnexpectedJournalSequence;
        var copy = try entry_codec.decode(alloc, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash);
        self.durable.append(alloc, copy) catch |err| {
            copy.deinit(alloc);
            return err;
        };
        // A failed acknowledgement retains the stored entry, exactly as a host
        // that committed its write before losing the return path would do.
        const request = entry.kind == .model_step and try journal.isRequest(self.durable.getLast().payload.value);
        if ((request and self.fail_model_request) or (!request and self.fail_entry == entry.kind)) return error.TestLostAck;
    }

    fn capture(self: *Witness) !?journal.State {
        if (self.durable.items.len == 0) return null;
        var captured: journal.State = .{};
        errdefer captured.deinit(std.testing.allocator);
        for (self.durable.items) |saved| {
            const entry = saved.entry;
            try captured.restore(std.testing.allocator, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash);
        }
        return captured;
    }

    fn restoreCut(self: *Witness, cut: *const journal.State) !void {
        for (cut.records.items) |saved| {
            const entry = saved.entry;
            try self.state.restore(std.testing.allocator, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash);
            try append(self, entry);
        }
        try journal_runtime.validateRestoredState(std.testing.allocator, &self.state);
    }

    fn execute(raw: *anyopaque, request: contracts.ToolExecutionRequest) !contracts.ToolExecutionResult {
        const self: *Witness = @ptrCast(@alignCast(raw));
        const index: usize = for (self.expected_calls, 0..) |expected, index| {
            if (std.mem.eql(u8, request.call.id, expected.id)) break index;
        } else return error.RegeneratedCallIdentity;
        if (!std.mem.eql(u8, request.call.name, self.expected_calls[index].name) or
            !std.mem.eql(u8, request.call.arguments_json, self.expected_calls[index].arguments_json)) return error.ReceiptInputConflict;
        if (!self.legacy) {
            const context = request.journal_context orelse return error.MissingDurableCallIdentity;
            if (!std.mem.eql(u8, context.requestId, "core-request")) return error.RegeneratedRequestIdentity;
            self.recovering_calls[index] = context.recovering;
            if (self.call_ids[index]) |original| {
                if (!std.mem.eql(u8, original, context.callId)) return error.RegeneratedCallIdentity;
            } else self.call_ids[index] = try std.testing.allocator.dupe(u8, context.callId);
        }
        self.entries += 1;
        self.admitted_result_limit = request.max_tool_result_bytes;
        if (self.before_tools[index] == null) self.before_tools[index] = try self.capture();
        // Simulated atomic external effect + receipt, checked against the
        // original durable identity, tool name, and exact input on every call.
        if (!self.receipts[index]) {
            self.effects += 1;
            self.receipts[index] = true;
        }
        if (self.after_effect[index] == null) self.after_effect[index] = try self.capture();
        if (self.cancel_after_effect) |flag| {
            flag.store(true, .seq_cst);
            return error.Cancelled;
        }
        return .{ .model_output = try request.result_allocator.dupe(u8, if (index == 0) "receipt:journal-call-a" else "receipt:journal-call-b") };
    }

    fn history(raw: *anyopaque, turn: types.HistoryTurn) !void {
        const hooks: *support.FakeAgentRuntimeDeps = @ptrCast(@alignCast(raw));
        const self: *Witness = @fieldParentPtr("hooks", hooks);
        try std.testing.expectEqual(journal.Kind.turn_end, self.durable.getLast().entry.kind);
        try std.testing.expect(self.state.pending() == .idle);
        if (self.fail_history) return error.TestHistoryProjectionFailed;
        try self.hooks.deps().propagate_history_turn(raw, turn);
    }

    fn run(self: *Witness, gateway: *support.FakeGateway, fixture: *support.PromptFixture, cut: ?*const journal.State) !void {
        if (cut) |captured| try self.restoreCut(captured);
        self.hooks.tool_execution_override = .{ .context = self, .execute_fn = execute };
        self.hooks.tool_registry = .{ .tools = &safe_tools };
        var deps = self.hooks.deps();
        deps.agent_stream_provider = gateway.provider();
        deps.propagate_history_turn = history;
        var runtime: journal_runtime.Runtime = .{
            .state = &self.state,
            .sink = .{ .context = self, .append_fn = append },
            .alloc = std.testing.allocator,
            .namespace = "core-session",
            .creation_id = if (cut == null) "first-runtime" else "recreated-runtime",
            .request_id = "core-request",
            .work_id = self.work_id,
            .resuming = cut != null,
        };
        deps.journal = &runtime;
        var agent: agent_mod.Agent = .{};
        defer agent.deinit(std.testing.allocator);
        var config = fixture.config();
        if (self.configured_result_limit) |limit| config.max_tool_result_bytes = limit;
        config.journal_cancel_policy = if (self.abandon_cancelled) .abandon else .preserve;
        try orchestrator.processAgentPrompt(
            &agent,
            &deps,
            null,
            support.testLifecycleContext(hooks_mod.RuntimeView.empty(), std.testing.allocator, fixture.config().workspace_root),
            config,
            fixture.job(),
        );
    }

    // The existing legacy checkpoint guards remain independent controls. They
    // never install the new journal or reinterpret old checkpoint bytes.
    fn runLegacy(self: *Witness, gateway: *support.FakeGateway, fixture: *support.PromptFixture, checkpoint: ?codec.RecoveryCheckpoint) !void {
        self.legacy = true;
        self.hooks.enable_recovery_checkpoint = true;
        self.hooks.tool_execution_override = .{ .context = self, .execute_fn = execute };
        var deps = self.hooks.deps();
        deps.agent_stream_provider = gateway.provider();
        var agent: agent_mod.Agent = .{};
        defer agent.deinit(std.testing.allocator);
        var job = fixture.job();
        job.recovery_checkpoint = checkpoint;
        try orchestrator.processAgentPrompt(
            &agent,
            &deps,
            null,
            support.testLifecycleContext(hooks_mod.RuntimeView.empty(), std.testing.allocator, fixture.config().workspace_root),
            fixture.config(),
            job,
        );
    }
};

fn has_call(state: *const journal.State, expected: types.ToolCall) bool {
    for (state.turns.items, 0..) |_, turn| {
        for (0..state.stepCount(turn)) |step| {
            for (journal.array(state.modelStep(turn, step), "calls") catch return false) |call| {
                if (std.mem.eql(u8, journal.string(call, "providerId") catch return false, expected.id) and
                    std.mem.eql(u8, journal.string(call, "name") catch return false, expected.name) and
                    std.mem.eql(u8, journal.string(call, "argumentsJson") catch return false, expected.arguments_json)) return true;
            }
        }
    }
    return false;
}

fn has_result(state: *const journal.State, id: []const u8) bool {
    for (state.turns.items, 0..) |_, turn| {
        for (0..state.stepCount(turn)) |step| {
            for (journal.array(state.modelStep(turn, step), "calls") catch return false, 0..) |call, index| {
                if (std.mem.eql(u8, journal.string(call, "providerId") catch return false, id) and state.toolResult(turn, step, index) != null) return true;
            }
        }
    }
    return false;
}

test "journal witness control actual orchestrator executes the selected calls" {
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{ .{ .tool_calls = &calls }, .{ .content = "finished" } });
    defer gateway.deinit();
    try witness.run(&gateway, &fixture, null);
    try std.testing.expectEqual(@as(usize, 2), witness.effects);
    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, witness.hooks.finalized_outcome.?);
}

test "journal witness permission feedback is durable before the next tool and survives recovery" {
    const alloc = std.testing.allocator;
    var fixture = support.PromptFixture{};
    var original = Witness.init();
    defer original.deinit();
    const feedback = "Preserve the first command's approved change";
    original.hooks.permission_feedback = &.{feedback};
    var gateway = support.FakeGateway.init(alloc, &.{ .{ .tool_calls = &calls }, .{ .content = "finished" } });
    defer gateway.deinit();
    try original.run(&gateway, &fixture, null);
    const cut = original.before_tools[1] orelse return error.NoDurableBoundaryBeforeSecondEffect;
    const result = cut.toolResult(0, 0, 0) orelse return error.MissingDurableResult;
    const saved_feedback = try journal.array(try journal.object(result, "persisted"), "permission_feedback");
    try std.testing.expectEqual(@as(usize, 1), saved_feedback.len);
    try std.testing.expectEqualStrings(feedback, saved_feedback[0].string);
    var recovered = Witness.init();
    defer recovered.deinit();
    var next_gateway = support.FakeGateway.init(alloc, &.{.{ .content = "recovered" }});
    defer next_gateway.deinit();
    try recovered.run(&next_gateway, &fixture, &cut);
    try std.testing.expectEqual(@as(usize, 1), recovered.entries);
    try std.testing.expectEqual(@as(usize, 1), next_gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, next_gateway.request_bodies.items[0], feedback));
}

test "journal witness redacted tool arguments never become replayable inputs" {
    const alloc = std.testing.allocator;
    const sensitive_calls = [_]types.ToolCall{support.toolCall("secret-call", "shell", "{\"action\":\"run\",\"command\":\"effect-a\",\"password\":\"private-fixture-value\"}")};
    var fixture = support.PromptFixture{};
    var original = Witness.init();
    defer original.deinit();
    original.expected_calls = &sensitive_calls;
    var gateway = support.FakeGateway.init(alloc, &.{ .{ .tool_calls = &sensitive_calls }, .{ .content = "finished" } });
    defer gateway.deinit();
    try original.run(&gateway, &fixture, null);
    try std.testing.expectEqual(@as(usize, 1), original.effects);
    for (original.durable.items) |record| try std.testing.expect(std.mem.find(u8, record.entry.bytes, "private-fixture-value") == null);
    const cut = original.before_tools[0] orelse return error.NoDurableBoundaryBeforeEffect;
    const saved = (try journal.array(cut.modelStep(0, 0), "calls"))[0];
    try std.testing.expectEqualStrings("blocked", try journal.string(saved, "replay"));
    var recovered = Witness.init();
    defer recovered.deinit();
    recovered.expected_calls = &sensitive_calls;
    var next_gateway = support.FakeGateway.init(alloc, &.{});
    defer next_gateway.deinit();
    try std.testing.expectError(error.RecoveryRequired, recovered.run(&next_gateway, &fixture, &cut));
    try std.testing.expectEqual(@as(usize, 0), recovered.entries);
    try std.testing.expectEqual(@as(usize, 0), next_gateway.request_bodies.items.len);
}

test "journal witness command permission cancellation closes before executing the tool" {
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    witness.hooks.cancel_on_permission = &fixture.cancel_flag;
    witness.hooks.permission_errors = &.{error.Cancelled};
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{.{ .tool_calls = calls[0..1] }});
    defer gateway.deinit();
    try witness.run(&gateway, &fixture, null);
    try std.testing.expectEqual(@as(usize, 0), witness.entries);
    try std.testing.expect(witness.state.pending() == .idle);
    try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, witness.hooks.finalized_outcome.?);
    const history = try @import("../../../session/session_codec.zig").parseHistoryTurn(std.testing.allocator, try journal.object(witness.state.outcome(0).?, "history"));
    defer types.freeHistoryTurn(std.testing.allocator, history);
    try std.testing.expect(history.interrupted.cancelled_command != null);
    try std.testing.expect(history.interrupted.cancelled_command.?.output_replay == null);
    try std.testing.expect(history.interrupted.cancelled_command.?.command_artifact_handle == null);
}

test "journal witness native cancellation abandons an unknown effect without inventing a result" {
    for ([_]struct { abandon: bool, fail_end: bool = false }{
        .{ .abandon = false }, .{ .abandon = true }, .{ .abandon = true, .fail_end = true },
    }) |case| {
        var fixture = support.PromptFixture{};
        var witness = Witness.init();
        defer witness.deinit();
        witness.cancel_after_effect = &fixture.cancel_flag;
        witness.abandon_cancelled = case.abandon;
        if (case.fail_end) witness.fail_entry = .turn_end;
        var gateway = support.FakeGateway.init(std.testing.allocator, &.{.{ .tool_calls = calls[0..1] }});
        defer gateway.deinit();
        if (case.fail_end) {
            try std.testing.expectError(error.PersistenceUncertain, witness.run(&gateway, &fixture, null));
            try std.testing.expect(witness.state.blocked);
            try std.testing.expect(witness.state.outcome(0) == null);
            var recovered = (try witness.capture()).?;
            defer recovered.deinit(std.testing.allocator);
            try std.testing.expect(recovered.pending() == .idle);
            try std.testing.expect((try journal.object(recovered.outcome(0).?, "result")).object.contains("pendingTool"));
        } else if (case.abandon) {
            try witness.run(&gateway, &fixture, null);
            try std.testing.expect(witness.state.pending() == .idle);
            const result = try journal.object(witness.state.outcome(0).?, "result");
            try std.testing.expectEqualStrings("cancelled", try journal.string(result, "reason"));
            const pending = try journal.object(result, "pendingTool");
            try std.testing.expectEqualStrings(witness.call_ids[0].?, try journal.string(pending, "callId"));
            try std.testing.expectEqual(types.TurnPresentationOutcome.interrupted, witness.hooks.finalized_outcome.?);
            try std.testing.expectError(error.RequestAlreadyCompleted, witness.run(&gateway, &fixture, null));
        } else {
            try std.testing.expectError(error.RecoveryRequired, witness.run(&gateway, &fixture, null));
            try std.testing.expect(witness.state.pending() == .tool);
            try std.testing.expect(witness.state.outcome(0) == null);
        }
        try std.testing.expect(witness.state.toolResult(0, 0, 0) == null);
        try std.testing.expectEqual(@as(usize, 1), witness.entries);
        try std.testing.expectEqual(@as(usize, 1), witness.effects);
        try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    }
}

test "journal witness high result ceilings admit a bounded executor without changing small results" {
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    witness.configured_result_limit = 2 * 1024 * 1024;
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{ .{ .tool_calls = calls[0..1] }, .{ .content = "finished" } });
    defer gateway.deinit();
    try witness.run(&gateway, &fixture, null);
    try std.testing.expect(witness.admitted_result_limit >= 1024);
    try std.testing.expect(witness.admitted_result_limit < witness.configured_result_limit.?);
    try std.testing.expectEqual(@as(usize, 1), witness.entries);
    try std.testing.expectEqual(@as(usize, 1), witness.effects);
    try std.testing.expectEqual(@as(usize, 2), gateway.request_bodies.items.len);
    try std.testing.expect(std.mem.find(u8, gateway.request_bodies.items[1], "receipt:journal-call-a") != null);
}

test "journal witness managed work identity is bound before input and terminal acknowledgement" {
    const alloc = std.testing.allocator;
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    witness.work_id = "managed-work-1";
    var gateway = support.FakeGateway.init(alloc, &.{.{ .content = "managed result" }});
    defer gateway.deinit();
    try witness.run(&gateway, &fixture, null);
    const input = try journal_runtime.readUser(alloc, &witness.state, 0);
    defer types.freeUserTurn(alloc, input);
    try std.testing.expectEqualStrings("managed-work-1", input.work_id.?);
    const history = try journal_runtime.restoreHistory(alloc, &witness.state);
    defer types.freeHistoryTurnSlice(alloc, history);
    try std.testing.expectEqualStrings("managed-work-1", history[0].assistant.user.work_id.?);
    try std.testing.expectEqualStrings("managed result", history[0].assistant.assistant);
    try journal_runtime.validateRestoredState(alloc, &witness.state);
}

test "journal witness capacity rejects admission before model and tool effects" {
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    witness.state.limits.bytes = 12 * 1024 * 1024;
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{.{ .tool_calls = calls[0..1] }});
    defer gateway.deinit();
    try std.testing.expectError(error.JournalCapacityExceeded, witness.run(&gateway, &fixture, null));
    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 0), witness.effects);
    try std.testing.expectEqual(@as(usize, 0), witness.durable.items.len);
    try std.testing.expect(!witness.state.blocked);
}

test "journal witness capacity stops before tool entry and preserves abandonment and checkpoint" {
    const alloc = std.testing.allocator;
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    witness.state.limits.bytes = 16 * 1024 * 1024 + 192 * 1024;
    var gateway = support.FakeGateway.init(alloc, &.{.{ .tool_calls = calls[0..1] }});
    defer gateway.deinit();
    try std.testing.expectError(error.JournalCapacityExceeded, witness.run(&gateway, &fixture, null));
    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 0), witness.entries);
    try std.testing.expectEqual(@as(usize, 0), witness.effects);
    try std.testing.expect(witness.state.pending() == .tool);
    try std.testing.expect(!witness.state.blocked);
    var runtime: journal_runtime.Runtime = .{
        .state = &witness.state,
        .sink = .{ .context = &witness, .append_fn = Witness.append },
        .alloc = alloc,
        .namespace = "core-session",
        .creation_id = "capacity-close",
        .request_id = "core-request",
        .turn = 0,
    };
    const reserve = try runtime.terminalBytes();
    const history = (try runtime.abandon()).?;
    defer types.freeHistoryTurn(alloc, history);
    try std.testing.expect(witness.durable.getLast().entry.bytes.len <= reserve);
    var checkpoint = try witness.state.checkpoint(alloc, runtime.sink);
    defer checkpoint.deinit(alloc);
    var restored: journal.State = .{ .limits = witness.state.limits };
    defer restored.deinit(alloc);
    const entry = checkpoint.entry;
    try restored.restore(alloc, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash);
    try journal_runtime.validateRestoredState(alloc, &restored);
    try std.testing.expect(restored.pending() == .idle);
    try std.testing.expect(restored.outcome(restored.request("core-request").?) != null);
    try std.testing.expectEqual(@as(usize, 0), witness.effects);
}

test "journal witness J02 selected call identity and input are durable before effect" {
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{ .{ .tool_calls = calls[0..1] }, .{ .content = "finished" } });
    defer gateway.deinit();
    try witness.run(&gateway, &fixture, null);
    const cut = witness.before_tools[0] orelse return error.NoDurableBoundaryBeforeEffect;
    try std.testing.expect(has_call(&cut, calls[0]));
    try std.testing.expect(!has_result(&cut, calls[0].id));
}

test "journal witness J02 unacknowledged selected decision cannot enter its effect" {
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    witness.fail_entry = .model_step;
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{ .{ .tool_calls = calls[0..1] }, .{ .content = "must not run" } });
    defer gateway.deinit();
    try std.testing.expectError(error.PersistenceUncertain, witness.run(&gateway, &fixture, null));
    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 0), witness.entries);
    try std.testing.expectEqual(@as(usize, 0), witness.effects);
    try std.testing.expectEqual(journal.Kind.model_step, witness.durable.getLast().entry.kind);
    try std.testing.expect(!try journal.isRequest(witness.durable.getLast().payload.value));
    try std.testing.expect(witness.state.blocked);
}

test "journal witness J01 unacknowledged model request blocks provider admission and restores budget" {
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    witness.fail_model_request = true;
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{.{ .content = "must not run" }});
    defer gateway.deinit();
    try std.testing.expectError(error.PersistenceUncertain, witness.run(&gateway, &fixture, null));
    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 0), witness.entries);
    try std.testing.expectEqual(@as(usize, 0), witness.effects);
    try std.testing.expect(try journal.isRequest(witness.durable.getLast().payload.value));
    try std.testing.expectEqual(@as(usize, 0), witness.state.stepCount(0));
    var cut = (try witness.capture()) orelse return error.NoDurableModelReservation;
    defer cut.deinit(std.testing.allocator);
    try journal_runtime.validateRestoredState(std.testing.allocator, &cut);
    var view: journal_runtime.Runtime = .{
        .state = &cut,
        .sink = .{ .context = &witness, .append_fn = Witness.append },
        .alloc = std.testing.allocator,
        .namespace = "core-session",
        .creation_id = "inspection-only",
        .request_id = "core-request",
        .turn = 0,
    };
    const context = (try view.latestContext()) orelse return error.MissingReservationContext;
    var checkpoint = try journal_runtime.parseRecoveryMetadata(std.testing.allocator, context);
    const original = try view.user(std.testing.allocator);
    defer types.freeUserTurn(std.testing.allocator, original);
    try std.testing.expectEqualStrings(fixture.job().prompt, original.text);
    defer checkpoint.deinit(std.testing.allocator);
    try std.testing.expect(checkpoint.outstanding_reservation);
    try std.testing.expectEqual(@as(usize, 0), checkpoint.consumed_provider_attempts);
    try std.testing.expect(checkpoint.max_provider_attempts > 0);
    try std.testing.expectEqual(fixture.job().provider, checkpoint.authority.provider);
    try std.testing.expectEqualStrings(fixture.job().model, checkpoint.authority.model);
    try std.testing.expectEqual(@as(usize, 0), cut.stepCount(0));
    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
}

test "journal witness J06 result A is durable before selected effect B enters" {
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{ .{ .tool_calls = &calls }, .{ .content = "finished" } });
    defer gateway.deinit();
    try witness.run(&gateway, &fixture, null);
    const cut = witness.before_tools[1] orelse return error.NoDurableBoundaryBeforeSecondEffect;
    try std.testing.expect(has_call(&cut, calls[0]) and has_call(&cut, calls[1]));
    try std.testing.expect(has_result(&cut, calls[0].id));
    try std.testing.expect(!has_result(&cut, calls[1].id));
}

fn recover_safe_cut(effect_committed: bool) !void {
    var fixture = support.PromptFixture{};
    var original = Witness.init();
    defer original.deinit();
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{ .{ .tool_calls = calls[0..1] }, .{ .content = "finished" } });
    defer gateway.deinit();
    try original.run(&gateway, &fixture, null);
    const cut = (if (effect_committed) original.after_effect[0] else original.before_tools[0]) orelse return error.NoDurableBoundaryBeforeEffect;
    // Both sides of the external transaction have the SAME kernel persistence.
    // Only the tool's atomic receipt distinguishes them after the owner dies.
    // The descriptor opts only this atomic receipt fixture into safe replay.
    // Its original kernel identity is copied with the independent receipt.
    var recovered = Witness.init();
    defer recovered.deinit();
    recovered.call_ids[0] = try std.testing.allocator.dupe(u8, original.call_ids[0] orelse return error.MissingDurableCallIdentity);
    recovered.receipts[0] = effect_committed;
    recovered.effects = @intFromBool(effect_committed);
    var next_gateway = support.FakeGateway.init(std.testing.allocator, &.{.{ .content = "finished from original receipt" }});
    defer next_gateway.deinit();
    try recovered.run(&next_gateway, &fixture, &cut);
    try std.testing.expectEqual(@as(usize, 1), recovered.entries);
    try std.testing.expectEqual(@as(usize, 1), recovered.effects);
    try std.testing.expectEqual(@as(?bool, false), original.recovering_calls[0]);
    try std.testing.expectEqual(@as(?bool, true), recovered.recovering_calls[0]);
    try std.testing.expectEqualStrings(original.call_ids[0].?, recovered.call_ids[0].?);
    try std.testing.expectEqual(@as(usize, 1), next_gateway.request_bodies.items.len);
    try support.expectBodyContains(&next_gateway, 0, "receipt:journal-call-a");
}

test "journal witness J03 effect committed before result save is recoverable by original receipt" {
    try recover_safe_cut(true);
}

test "journal witness J05 death before effect transaction can execute the recorded safe call" {
    try recover_safe_cut(false);
}

test "journal witness J07 final model output survives death before turn end acknowledgement" {
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{.{ .content = "DURABLE_FINAL_MODEL_ANSWER" }});
    defer gateway.deinit();
    try witness.run(&gateway, &fixture, null);
    const cut = witness.before_end orelse return error.NoDurableFinalModelBoundary;
    try std.testing.expect(cut.pending() == .ending);
    const completion = try journal.object(cut.modelStep(0, cut.stepCount(0) - 1), "completion");
    try std.testing.expectEqualStrings("DURABLE_FINAL_MODEL_ANSWER", (try journal.field(completion, "content", .string)).string);
    var restored = Witness.init();
    defer restored.deinit();
    var no_provider = support.FakeGateway.init(std.testing.allocator, &.{});
    defer no_provider.deinit();
    try restored.run(&no_provider, &fixture, &cut);
    try std.testing.expectEqual(@as(usize, 0), no_provider.request_bodies.items.len);
    try std.testing.expectEqual(types.TurnPresentationOutcome.completed, restored.hooks.finalized_outcome.?);
    try std.testing.expectEqualStrings("DURABLE_FINAL_MODEL_ANSWER", restored.hooks.history_assistant_text orelse return error.MissingRestoredFinalHistory);
    try std.testing.expectEqual(journal.Kind.turn_end, restored.durable.getLast().entry.kind);
}

test "journal witness failed terminal projection preserves the acknowledged result and fences the owner" {
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    witness.fail_history = true;
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{.{ .content = "acknowledged result" }});
    defer gateway.deinit();
    try std.testing.expectError(error.TestHistoryProjectionFailed, witness.run(&gateway, &fixture, null));
    try std.testing.expect(witness.state.blocked);
    try std.testing.expectEqual(journal.Kind.turn_end, witness.durable.getLast().entry.kind);
    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    try std.testing.expectError(error.PersistenceUncertain, witness.run(&gateway, &fixture, null));
    try std.testing.expectEqual(@as(usize, 1), gateway.request_bodies.items.len);
    var committed = (try witness.capture()).?;
    defer committed.deinit(std.testing.allocator);
    var reopened = Witness.init();
    defer reopened.deinit();
    var no_provider = support.FakeGateway.init(std.testing.allocator, &.{});
    defer no_provider.deinit();
    try std.testing.expectError(error.RequestAlreadyCompleted, reopened.run(&no_provider, &fixture, &committed));
    try std.testing.expect(reopened.state.pending() == .idle);
    const result = try journal.object(reopened.state.outcome(0).?, "result");
    try std.testing.expect(try journal.boolean(result, "ok"));
    try std.testing.expectEqual(@as(usize, 0), no_provider.request_bodies.items.len);
}

test "journal witness control unknown tool effects cannot resume by removing the guard" {
    var fixture = support.PromptFixture{};
    const checkpoint: codec.RecoveryCheckpoint = .{
        .turn_id = 1,
        .user = .{ .text = fixture.job().prompt },
        .assistant_source = @constCast(""),
        .cause = .tool_state_uncertain,
        .action = .paused,
        .tool_state = .uncertain,
        .authority = .{
            .provider = fixture.job().provider,
            .model = fixture.job().model,
            .credential_source = fixture.job().credential_source,
            .credential_identity = @import("../../../auth/credential_authority.zig").derive(fixture.job().credential_source.?, fixture.job().account_id),
        },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 10,
        .consumed_provider_attempts = 1,
    };
    var restored = Witness.init();
    defer restored.deinit();
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{});
    defer gateway.deinit();
    try std.testing.expectError(error.RecoveryEffectsUncertain, restored.runLegacy(&gateway, &fixture, checkpoint));
    try std.testing.expectEqual(@as(usize, 0), restored.entries);
    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
}

test "journal witness control checkpoint write failure stops provider admission" {
    var fixture = support.PromptFixture{};
    var witness = Witness.init();
    defer witness.deinit();
    witness.hooks.recovery_checkpoint_error = error.TestLostAck;
    var gateway = support.FakeGateway.init(std.testing.allocator, &.{.{ .content = "must not run" }});
    defer gateway.deinit();
    if (witness.runLegacy(&gateway, &fixture, null)) |_| {} else |_| {}
    try std.testing.expectEqual(@as(usize, 0), gateway.request_bodies.items.len);
    try std.testing.expectEqual(@as(usize, 0), witness.effects);
}
