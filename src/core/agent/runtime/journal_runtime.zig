//! Encodes the existing agent loop's acknowledged boundaries. This module never
//! calls a provider, dispatches a tool, or decides whether a tool may be replayed.
const std = @import("std");
const journal = @import("../../session/execution_journal.zig");
const session_codec = @import("../../session/session_codec.zig");
const types = @import("../../shared/types.zig");
const text_utils = @import("../../shared/text_utils.zig");
const session = @import("../../session/session.zig");
const execution_memory = @import("execution_memory.zig");
const entry_codec = @import("../../session/execution_journal_codec.zig");
const genesis = @import("../../session/execution_journal_genesis.zig");
const tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Context = types.JournalToolContext;
pub const max_model_record_bytes: usize = 4 * 1024 * 1024;
// A maximum-size file argument still needs its call identity and context envelope.
const max_decision_record_bytes: usize = max_model_record_bytes + 64 * 1024;
pub const Selection = enum { new_turn, pending, completed };

pub const GenerationKey = struct {
    turnId: []const u8,
    messageId: []const u8,
    generationId: []const u8,

    pub fn deinit(self: *GenerationKey, alloc: Allocator) void {
        alloc.free(self.turnId);
        alloc.free(self.messageId);
        alloc.free(self.generationId);
        self.* = undefined;
    }
};

// The decision codec must not serialize resolved_skill, reconstruct malformed
// arguments, or drop the provider's identity and validation evidence.
const Call = struct {
    callId: []const u8,
    providerId: []const u8,
    name: []const u8,
    argumentsJson: []const u8,
    replay: journal.Replay,
    argument_integrity: types.ToolArgumentIntegrity,
    provisional_id: ?[]const u8,
    provider_result: ?[]const u8,
    final_identity: types.FinalToolIdentity,
    provenance: types.ToolExecutionProvenance,

    fn restore(self: Call) types.ToolCall {
        return .{
            .id = self.providerId,
            .name = self.name,
            .arguments_json = self.argumentsJson,
            .argument_integrity = self.argument_integrity,
            .provisional_id = self.provisional_id,
            .provider_result = self.provider_result,
            .final_identity = self.final_identity,
            .provenance = self.provenance,
            .resolved_skill = null,
        };
    }
};

const Completion = struct {
    content: ?[]const u8,
    generation_id: ?[]const u8,
    billing: ?types.ProviderBilling,
    generation_metadata_invalid: bool,
    delivery_ambiguous: bool,
    provider_result_identity_failure: ?types.ProviderResultIdentityFailure,
    provider_failure_cause: ?types.ProviderFailureCause,
    provider_failure_detail: ?[]const u8,
    provider_state_json: ?[]const u8,
    finish_reason: ?types.ProviderFinishReason,
    usage: types.Usage,

    fn capture(value: types.ModelCompletion) Completion {
        return .{
            .content = value.content,
            .generation_id = value.generation_id,
            .billing = value.billing,
            .generation_metadata_invalid = value.generation_metadata_invalid,
            .delivery_ambiguous = value.delivery_ambiguous,
            .provider_result_identity_failure = value.provider_result_identity_failure,
            .provider_failure_cause = value.provider_failure_cause,
            .provider_failure_detail = value.provider_failure_detail,
            .provider_state_json = value.provider_state_json,
            .finish_reason = value.finish_reason,
            .usage = value.usage,
        };
    }

    fn restore(self: Completion, calls: []const types.ToolCall) types.ModelCompletion {
        return .{
            .content = self.content,
            .tool_calls = calls,
            .generation_id = self.generation_id,
            .billing = self.billing,
            .generation_metadata_invalid = self.generation_metadata_invalid,
            .delivery_ambiguous = self.delivery_ambiguous,
            .provider_result_identity_failure = self.provider_result_identity_failure,
            .provider_failure_cause = self.provider_failure_cause,
            .provider_failure_detail = self.provider_failure_detail,
            .provider_state_json = self.provider_state_json,
            .finish_reason = self.finish_reason,
            .usage = self.usage,
        };
    }
};

/// Durable pre-tool hook disposition. Capture and execution remain in the
/// orchestrator; all readers validate this one wire interpretation.
pub const Preparation = struct {
    state: enum { ready, provider_executed, blocked },
    blockKind: ?tool_contracts.PreparedToolBlockKind = null,
    modelOutput: ?[]const u8 = null,

    pub fn validate(self: Preparation, call: types.ToolCall) !void {
        switch (self.state) {
            .ready => if (self.blockKind != null or self.modelOutput != null or call.provenance == .provider_executed) return error.InvalidJournalRecord,
            .provider_executed => if (self.blockKind != null or self.modelOutput != null or call.provenance != .provider_executed) return error.InvalidJournalRecord,
            .blocked => if (self.blockKind == null or self.modelOutput == null) return error.InvalidJournalRecord,
        }
    }
};

/// Owns all reconstructed values, including strings. Deinit after the existing
/// loop has finished borrowing them; do not individually free completion fields.
pub const OwnedDecision = struct {
    arena: std.heap.ArenaAllocator,
    completion: types.ModelCompletion,
    calls: []const types.ToolCall,
    replay: []const journal.Replay,
    execution_context_json: ?[]const u8,
    provider_replay: ?types.ProviderReplay,
    key: GenerationKey,
    final: bool,

    pub fn deinit(self: *OwnedDecision) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const OwnedResult = struct {
    arena: std.heap.ArenaAllocator,
    result: types.PersistedToolResult,

    pub fn deinit(self: *OwnedResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const OwnedExecution = struct {
    arena: std.heap.ArenaAllocator,
    execution: types.ExecutionMemory,

    /// Active-turn replay retains steering markers; historical transcript
    /// projection intentionally renders those same inputs as plain user text.
    pub fn appendPromptMessages(self: *OwnedExecution, alloc: Allocator, messages: *std.ArrayList(types.ChatMessage)) !void {
        const start = messages.items.len;
        var view = self.execution;
        if (view.steering.len != 0) {
            const a = self.arena.allocator();
            view.steering = try a.dupe(types.PersistedSteering, view.steering);
            for (view.steering) |*item| item.text = try execution_memory.steeringMessage(a, item.text);
        }
        try session.appendExecutionMemoryChatMessages(alloc, messages, view);
        // These are live model decisions, not already-materialized history
        // steps. Preserve the flags used by the original agent loop.
        for (messages.items[start..]) |*message| {
            if (message.role == .assistant and message.tool_calls.len == 0) message.standalone_response = false;
        }
    }

    pub fn deinit(self: *OwnedExecution) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const PendingTool = struct {
    callId: []const u8,
    name: []const u8,
    input: Value,
    replay: journal.Replay,
};

pub const OwnedPendingTool = struct {
    arena: std.heap.ArenaAllocator,
    tool: PendingTool,

    pub fn deinit(self: *OwnedPendingTool) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Borrows all configuration. alloc is the journal owner's allocator, not a
/// short-lived prompt arena. creation_id must be unique for this execution
/// instance so repeated model attempts never reuse a draft generation identity.
pub const Runtime = struct {
    state: *journal.State,
    sink: journal.Sink,
    alloc: Allocator,
    namespace: []const u8,
    creation_id: []const u8,
    request_id: []const u8,
    work_id: ?[]const u8 = null,
    turn: ?usize = null,
    resuming: bool = false,
    generation_counter: u64 = 0,

    /// New admission writes before returning. Known input is checked before
    /// pending/completed dispatch; resume cannot turn a new ID into fresh work.
    pub fn begin(self: *Runtime, input: types.UserTurn, selected_model: []const u8, runtime_turn_id: u64, resume_pending: bool) !Selection {
        try self.state.ensureAvailable();
        if (self.turn != null and !resume_pending) return error.InvalidJournalTransition;
        if (self.request_id.len == 0 or self.namespace.len == 0 or self.creation_id.len == 0 or selected_model.len == 0 or runtime_turn_id == 0)
            return error.InvalidJournalRecord;
        var input_writer: std.Io.Writer.Allocating = .init(self.alloc);
        defer input_writer.deinit();
        var bound_input = input;
        if (self.work_id) |id| {
            try session.validateWorkId(id);
            if (input.work_id) |current| if (!std.mem.eql(u8, current, id)) return error.RequestConflict;
            bound_input.work_id = @constCast(id);
        }
        try session_codec.writeUserTurn(&input_writer.writer, bound_input);
        const input_json = input_writer.written();
        const input_hash = journal.inputHash(input_json);
        if (self.state.request(self.request_id)) |index| {
            if (self.turn) |selected| if (selected != index) return error.InvalidJournalTransition;
            if (!std.mem.eql(u8, &input_hash, try journal.string(self.state.start(index), "inputHash")))
                return error.RequestConflict;
            if (self.state.outcome(index) != null) {
                self.turn = index;
                return .completed;
            }
            if (!resume_pending) return error.PendingTurnError;
            self.turn = index;
            return .pending;
        }
        if (resume_pending) return error.InvalidJournalTransition;
        if (self.state.pending() != .idle) return error.PendingTurnError;
        const namespace = if (self.state.turns.items.len == 0)
            if (self.state.nativeBase()) |base| try journal.string(base, "id") else self.namespace
        else
            try journal.string(self.state.start(0), "namespace");
        const turn_id = try std.fmt.allocPrint(self.alloc, "{s}:turn:{d}", .{ namespace, self.state.turns.items.len + 1 });
        defer self.alloc.free(turn_id);
        const user_id = try std.fmt.allocPrint(self.alloc, "{s}:user", .{turn_id});
        defer self.alloc.free(user_id);
        var number_buffer: [20]u8 = undefined;
        const number = try std.fmt.bufPrint(&number_buffer, "{d}", .{runtime_turn_id});
        var writer: std.Io.Writer.Allocating = .init(self.alloc);
        defer writer.deinit();
        try std.json.Stringify.value(.{
            .v = 1,
            .kind = "turn_start",
            .namespace = namespace,
            .turnId = turn_id,
            .userMessageId = user_id,
            .requestId = self.request_id,
            .inputHash = &input_hash,
            .model = selected_model,
            .runtimeTurnId = number,
            .inputJson = input_json,
        }, .{}, &writer.writer);
        const index = self.state.turns.items.len;
        const initial_bytes = std.math.add(usize, writer.written().len, max_decision_record_bytes + 64 * 1024) catch return error.JournalCapacityExceeded;
        const initial_terminal = std.math.add(usize, input_json.len, 2 * max_model_record_bytes + 64 * 1024) catch return error.JournalCapacityExceeded;
        try self.state.preflight(.{ .append_bytes = initial_bytes, .append_records = 3, .terminal_bytes = initial_terminal });
        try self.state.append(self.alloc, self.sink, .turn_start, writer.written());
        self.turn = index;
        return .new_turn;
    }

    /// The caller owns the returned user turn, freed with types.freeUserTurn.
    pub fn user(self: *const Runtime, alloc: Allocator) !types.UserTurn {
        return decodeUser(alloc, try self.startBody());
    }

    /// Records accepted guidance before the next provider request. Message IDs
    /// belong to the turn and survive checkpoints and owner recreation.
    pub fn recordSteering(self: *Runtime, guidance: []const []const u8, prefix: ?[]const u8) !void {
        if (guidance.len == 0) return;
        try self.state.ensureAvailable();
        const turn = self.turn orelse return error.InvalidJournalTransition;
        const turn_id = try journal.string(try self.startBody(), "turnId");
        const offset = try steeringCount(self.state, turn_id);
        const first_id = try steeringId(self.alloc, turn_id, offset + 1);
        defer self.alloc.free(first_id);
        const prefix_id = try std.fmt.allocPrint(self.alloc, "{s}:assistant", .{first_id});
        defer self.alloc.free(prefix_id);
        var writer: std.Io.Writer.Allocating = .init(self.alloc);
        defer writer.deinit();
        try writer.writer.writeAll("{\"v\":1,\"kind\":\"model_step\",\"phase\":\"context\",\"change\":\"steering\",\"turnId\":");
        try json(&writer.writer, turn_id);
        try writer.writer.print(",\"afterTurnCount\":{d},\"afterStepCount\":{d},\"prefix\":", .{ self.state.turns.items.len, self.state.stepCount(turn) });
        if (prefix) |text| {
            try json(&writer.writer, .{ .id = prefix_id, .text = text });
        } else try writer.writer.writeAll("null");
        try writer.writer.writeAll(",\"retiredDraft\":");
        if (self.state.requestForCurrentStep(turn)) |request| {
            try json(&writer.writer, .{
                .turnId = turn_id,
                .messageId = try journal.string(request, "messageId"),
                .generationId = try journal.string(request, "generationId"),
            });
        } else try writer.writer.writeAll("null");
        try writer.writer.writeAll(",\"guidance\":[");
        for (guidance, 0..) |text, index| {
            if (index > 0) try writer.writer.writeByte(',');
            const id = try steeringId(self.alloc, turn_id, offset + index + 1);
            defer self.alloc.free(id);
            try json(&writer.writer, .{ .id = id, .text = text });
        }
        try writer.writer.writeAll("]}");
        if (writer.written().len > max_model_record_bytes) return error.JournalCapacityExceeded;
        try self.preflightOperation(writer.written().len, 1, writer.written().len * 2);
        try self.state.append(self.alloc, self.sink, .model_step, writer.written());
    }

    pub fn model(self: *const Runtime) ![]const u8 {
        return journal.string(try self.startBody(), "model");
    }

    pub fn runtimeTurnId(self: *const Runtime) !u64 {
        return decodeRuntimeTurnId(try self.startBody());
    }

    /// Measure an upper bound for closing the currently acknowledged turn. It
    /// includes every selected call, even though abandonment drops later calls,
    /// and counts the real history codec rather than multiplying image payloads.
    pub fn terminalBytes(self: *const Runtime) !usize {
        const turn = self.turn orelse return 64 * 1024;
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const original_user = try self.user(a);
        var full = try self.executionThrough(self.alloc, self.state.stepCount(turn), true);
        defer full.deinit();
        var messages: std.ArrayList(types.ChatMessage) = .empty;
        try full.appendPromptMessages(a, &messages);
        const projected = try execution_memory.buildExecutionMemory(a, messages.items);
        full.execution.files = projected.files;
        var assistant: ?[]u8 = null;
        if (full.execution.tool_steps.len > 0) assistant = full.execution.tool_steps[full.execution.tool_steps.len - 1].assistant;
        var pending_bytes: usize = 0;
        if (self.state.pending() == .tool) {
            const position = self.state.pending().tool;
            const selected = full.execution.tool_steps[position.step].tool_calls;
            for (selected[position.call..]) |call| {
                var scratch: [256]u8 = undefined;
                var counter: std.Io.Writer.Discarding = .init(&scratch);
                try json(&counter.writer, call.arguments_json);
                const size = std.math.cast(usize, counter.fullCount()) orelse return error.JournalCapacityExceeded;
                if (size >= pending_bytes) {
                    pending_bytes = size;
                }
            }
        }
        var buffer: [1024]u8 = undefined;
        var counted: std.Io.Writer.Discarding = .init(&buffer);
        try session_codec.writeHistoryTurn(&counted.writer, .{ .interrupted = .{
            .user = original_user,
            .assistant = assistant,
            .tool_call = null,
            .execution = full.execution,
            .terminal_reason = .cancelled,
        } });
        var size = std.math.cast(usize, counted.fullCount()) orelse return error.JournalCapacityExceeded;
        size = std.math.add(usize, size, pending_bytes) catch return error.JournalCapacityExceeded;
        // Full execution already includes the active call. Abandonment moves
        // that call out of execution, so only pendingTool's input is additional.
        // Result envelope, labels, summaries and the pending-tool identity.
        return std.math.add(usize, size, 64 * 1024) catch error.JournalCapacityExceeded;
    }

    pub fn preflightOperation(self: *const Runtime, append_bytes: usize, append_records: usize, terminal_extra: usize) !void {
        const terminal = std.math.add(usize, try self.terminalBytes(), terminal_extra) catch return error.JournalCapacityExceeded;
        try self.state.preflight(.{ .append_bytes = append_bytes, .append_records = append_records, .terminal_bytes = terminal });
    }

    /// Keep the configured limit as a ceiling while reserving both the result
    /// record and a terminal record before entering the executor.
    pub fn admitToolResultLimit(self: *const Runtime, configured: usize) !usize {
        const overhead = @import("../../images/image_data.zig").max_result_frame_bytes + 128 * 1024;
        const terminal = try self.terminalBytes();
        const available = try self.state.appendCapacity(1, terminal);
        const half = available / 2;
        if (half <= overhead) return error.JournalCapacityExceeded;
        const limit = @min(configured, (half - overhead) / 24);
        if (limit < @min(configured, @import("../../tooling/tool_result_limits.zig").min_configured_tool_result_bytes)) return error.JournalCapacityExceeded;
        const result = overhead + limit * 24;
        try self.state.preflight(.{ .append_bytes = result, .append_records = 1, .terminal_bytes = terminal + result });
        return limit;
    }

    pub fn generation(self: *Runtime) !GenerationKey {
        try self.state.ensureAvailable();
        const turn = self.turn orelse return error.InvalidJournalTransition;
        const pending = self.state.pending();
        if (pending != .model or pending.model != turn) return error.InvalidJournalTransition;
        const next = std.math.add(u64, self.generation_counter, 1) catch return error.JournalCapacityExceeded;
        const turn_id = try self.alloc.dupe(u8, try journal.string(self.state.start(turn), "turnId"));
        errdefer self.alloc.free(turn_id);
        const message_id = try std.fmt.allocPrint(self.alloc, "{s}:message:{d}", .{ turn_id, self.state.stepCount(turn) + 1 });
        errdefer self.alloc.free(message_id);
        const generation_id = try std.fmt.allocPrint(self.alloc, "{s}:generation:{s}:{d}", .{ message_id, self.creation_id, next });
        self.generation_counter = next;
        return .{ .turnId = turn_id, .messageId = message_id, .generationId = generation_id };
    }

    /// Acknowledges the existing provider budget/authority reservation before
    /// provider I/O. This record contains no selected output or tool decision.
    pub fn reserveRequest(self: *Runtime, key: GenerationKey, execution_context_json: []const u8) !void {
        try self.state.ensureAvailable();
        try self.validateGeneration(key);
        try entry_codec.validateJsonBounds(execution_context_json);
        const parsed = try std.json.parseFromSlice(Value, self.alloc, execution_context_json, .{});
        defer parsed.deinit();
        try validateExecutionContext(self.alloc, parsed.value, true, &.{});
        const prior = self.state.requestForCurrentStep(self.turn.?);
        const supersedes = if (prior) |record| try journal.string(record, "generationId") else null;
        var writer: std.Io.Writer.Allocating = .init(self.alloc);
        defer writer.deinit();
        try json(&writer.writer, .{
            .v = 1,
            .kind = "model_step",
            .phase = "request",
            .turnId = key.turnId,
            .messageId = key.messageId,
            .generationId = key.generationId,
            .supersedesGenerationId = supersedes,
            .executionContext = parsed.value,
        });
        if (writer.written().len > max_model_record_bytes) return error.JournalCapacityExceeded;
        try self.state.append(self.alloc, self.sink, .model_step, writer.written());
    }

    /// Borrows the most recent request/decision context. The existing execution
    /// owner interprets its original counters and authority through its guards.
    pub fn latestContext(self: *const Runtime) !?Value {
        _ = try self.startBody();
        const record = self.state.latestContextRecord(self.turn.?) orelse return null;
        const value = record.object.get("executionContext") orelse return error.InvalidJournalRecord;
        if (value == .null) return null;
        if (value != .object) return error.InvalidJournalRecord;
        return value;
    }

    /// Stores the filtered, canonical selected decision before any selected
    /// effect. execution_context_json carries the existing recovery checkpoint
    /// representation for context/budget restoration, never new authority.
    pub fn recordDecision(
        self: *Runtime,
        completion: types.ModelCompletion,
        selected: []const types.ToolCall,
        replay: []const journal.Replay,
        key: GenerationKey,
        final: bool,
        execution_context_json: ?[]const u8,
        provider_replay: ?types.ProviderReplay,
    ) !usize {
        try self.state.ensureAvailable();
        const turn = self.turn orelse return error.InvalidJournalTransition;
        if (selected.len != replay.len or selected.len > 256) return error.InvalidJournalRecord;
        const step = self.state.stepCount(turn);
        try self.validateGeneration(key);
        if (self.state.requestForCurrentStep(turn)) |request| {
            if (!std.mem.eql(u8, key.messageId, try journal.string(request, "messageId")) or
                !std.mem.eql(u8, key.generationId, try journal.string(request, "generationId"))) return error.JournalConflict;
        }
        var parsed_context: ?std.json.Parsed(Value) = null;
        defer if (parsed_context) |value| value.deinit();
        if (execution_context_json) |bytes| {
            try entry_codec.validateJsonBounds(bytes);
            parsed_context = try std.json.parseFromSlice(Value, self.alloc, bytes, .{});
            try validateExecutionContext(self.alloc, parsed_context.?.value, false, selected);
        }
        var writer: std.Io.Writer.Allocating = .init(self.alloc);
        defer writer.deinit();
        try writer.writer.writeAll("{\"v\":1,\"kind\":\"model_step\",\"turnId\":");
        try json(&writer.writer, key.turnId);
        try writer.writer.writeAll(",\"messageId\":");
        try json(&writer.writer, key.messageId);
        try writer.writer.writeAll(",\"generationId\":");
        try json(&writer.writer, key.generationId);
        try writer.writer.writeAll(",\"final\":");
        try json(&writer.writer, final);
        try writer.writer.writeAll(",\"completion\":");
        try json(&writer.writer, Completion.capture(completion));
        try writer.writer.writeAll(",\"calls\":[");
        for (selected, replay, 0..) |call, policy, index| {
            try entry_codec.validateJsonBounds(call.arguments_json);
            if (index != 0) try writer.writer.writeByte(',');
            const id = try std.fmt.allocPrint(self.alloc, "{s}:call:{d}", .{ key.messageId, index + 1 });
            defer self.alloc.free(id);
            try json(&writer.writer, Call{
                .callId = id,
                .providerId = call.id,
                .name = call.name,
                .argumentsJson = call.arguments_json,
                .replay = policy,
                .argument_integrity = call.argument_integrity,
                .provisional_id = call.provisional_id,
                .provider_result = call.provider_result,
                .final_identity = call.final_identity,
                .provenance = call.provenance,
            });
        }
        try writer.writer.writeAll("],\"executionContext\":");
        try json(&writer.writer, if (parsed_context) |value| value.value else .null);
        try writer.writer.writeAll(",\"providerReplay\":");
        try json(&writer.writer, provider_replay);
        try writer.writer.writeByte('}');
        if (writer.written().len > max_decision_record_bytes) return error.JournalCapacityExceeded;
        try self.preflightOperation(writer.written().len, 1, writer.written().len * 2);
        try self.state.append(self.alloc, self.sink, .model_step, writer.written());
        return step;
    }

    /// Reconstructs a recorded decision without model I/O. The orchestrator
    /// retains ownership of permissions, recovery policy and loop progression.
    pub fn recordedDecision(self: *const Runtime, alloc: Allocator, step: usize) !OwnedDecision {
        return decodeDecision(alloc, try self.stepBody(step));
    }

    /// Borrows identities from the durable journal, never from a provider retry.
    pub fn context(self: *const Runtime, step_index: usize, call_index: usize, recovering: bool) !Context {
        const call = try self.callBody(step_index, call_index);
        return .{
            .turnId = try journal.string(try self.startBody(), "turnId"),
            .callId = try journal.string(call, "callId"),
            .requestId = try journal.string(try self.startBody(), "requestId"),
            .recovering = recovering,
        };
    }

    pub fn recordResult(self: *Runtime, step_index: usize, call_index: usize, result: types.PersistedToolResult) !void {
        const call = try self.callBody(step_index, call_index);
        if (!std.mem.eql(u8, result.tool_call_id, try journal.string(call, "providerId")) or
            !std.mem.eql(u8, result.tool_name, try journal.string(call, "name"))) return error.JournalConflict;
        const display = try text_utils.sanitizeModelText(self.alloc, result.output);
        defer if (display.ptr != result.output.ptr) self.alloc.free(display);
        var writer: std.Io.Writer.Allocating = .init(self.alloc);
        defer writer.deinit();
        try writer.writer.writeAll("{\"v\":1,\"kind\":\"tool_result\",\"turnId\":");
        try json(&writer.writer, try journal.string(try self.startBody(), "turnId"));
        try writer.writer.writeAll(",\"callId\":");
        try json(&writer.writer, try journal.string(call, "callId"));
        try writer.writer.writeAll(",\"content\":");
        try json(&writer.writer, display);
        try writer.writer.writeAll(",\"isError\":");
        try json(&writer.writer, result.status != .success);
        try writer.writer.writeAll(",\"persisted\":");
        try session_codec.writePersistedToolResult(&writer.writer, result);
        try writer.writer.writeByte('}');
        try self.state.append(self.alloc, self.sink, .tool_result, writer.written());
    }

    pub fn recordedResult(self: *const Runtime, alloc: Allocator, step_index: usize, call_index: usize) !?OwnedResult {
        const call = try self.callBody(step_index, call_index);
        const body = self.state.toolResult(self.turn.?, step_index, call_index) orelse return null;
        return try decodeResult(alloc, body, call);
    }

    /// A pending selected decision is fed back through the existing loop. An
    /// acknowledged final response is also returned so no model request is made.
    pub fn recoveryStep(self: *const Runtime) ?usize {
        const turn = self.turn orelse return null;
        const selected = switch (self.state.pending()) {
            .tool => |position| if (position.turn == turn) position.step else return null,
            .ending => |index| if (index == turn) self.state.stepCount(turn) - 1 else return null,
            .model => |index| if (index == turn and self.state.canFinishProviderResponse(turn)) self.state.stepCount(turn) - 1 else return null,
            else => return null,
        };
        return selected;
    }

    /// Rebuilds only settled earlier steps. Files, steering, usage and admission
    /// budgets are restored by the execution owner from its recorded context.
    pub fn prefixExecution(self: *const Runtime, alloc: Allocator) !OwnedExecution {
        const turn = self.turn orelse return error.InvalidJournalTransition;
        if (turn >= self.state.turns.items.len) return error.InvalidJournalTransition;
        const count = self.recoveryStep() orelse self.state.stepCount(turn);
        return self.executionThrough(alloc, count, false);
    }

    pub fn compactionBoundary(self: *const Runtime) !execution_memory.CompactedExecutionBoundary {
        return activeBoundary(self.state, self.turn orelse return error.InvalidJournalTransition);
    }

    fn executionThrough(self: *const Runtime, alloc: Allocator, count: usize, allow_partial: bool) !OwnedExecution {
        return readExecutionThrough(alloc, self.state, self.turn orelse return error.InvalidJournalTransition, count, allow_partial);
    }

    /// Ends pending work without model/tool I/O. The returned turn is allocated
    /// with runtime.alloc before acknowledgement; success transfers ownership to
    /// the caller for allocation-free live-cache adoption. Idle returns null.
    pub fn abandon(self: *Runtime) !?types.HistoryTurn {
        try self.state.ensureAvailable();
        const pending = self.state.pending();
        const turn = switch (pending) {
            .idle => return null,
            .model, .ending => |index| index,
            .tool => |position| position.turn,
        };
        if (self.turn) |selected| if (selected != turn) return error.InvalidJournalTransition;
        self.turn = turn;
        var arena: std.heap.ArenaAllocator = .init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();
        var owned_history = (try pendingHistory(self.alloc, self.state)).?;
        errdefer types.freeHistoryTurn(self.alloc, owned_history);
        const boundary = try self.compactionBoundary();
        if (boundary.tool_steps != 0 or boundary.steering != 0) {
            var projected = owned_history;
            projected.interrupted.execution = try boundary.project(alloc, owned_history.interrupted.execution);
            const replacement = try types.dupeHistoryTurn(self.alloc, projected);
            types.freeHistoryTurn(self.alloc, owned_history);
            owned_history = replacement;
        }
        var pending_tool = try pendingTool(self.alloc, self.state);
        defer if (pending_tool) |*owned| owned.deinit();
        var writer: std.Io.Writer.Allocating = .init(alloc);
        try writer.writer.writeAll("{\"ok\":false,\"reason\":\"interrupted\",\"retryable\":true,\"message\":\"Turn abandoned\"");
        if (pending_tool) |owned| {
            try writer.writer.writeAll(",\"pendingTool\":");
            try json(&writer.writer, .{
                .callId = owned.tool.callId,
                .name = owned.tool.name,
                .input = owned.tool.input,
            });
        }
        try writer.writer.writeByte('}');
        const result = try std.json.parseFromSliceLeaky(Value, alloc, writer.written(), .{});
        try self.finish(result, owned_history);
        return owned_history;
    }

    /// The core supplies its canonical terminal history and result. Missing
    /// history remains explicit for terminal failures that produced no history.
    pub fn finish(self: *Runtime, result: Value, history: ?types.HistoryTurn) !void {
        if (result != .object) return error.InvalidJournalRecord;
        var writer: std.Io.Writer.Allocating = .init(self.alloc);
        defer writer.deinit();
        try writer.writer.writeAll("{\"v\":1,\"kind\":\"turn_end\",\"turnId\":");
        try json(&writer.writer, try journal.string(try self.startBody(), "turnId"));
        try writer.writer.writeAll(",\"result\":");
        try json(&writer.writer, result);
        try writer.writer.writeAll(",\"history\":");
        if (history) |turn| {
            try session_codec.writeHistoryTurn(&writer.writer, turn);
        } else {
            try writer.writer.writeAll("null");
        }
        try writer.writer.writeByte('}');
        try self.state.append(self.alloc, self.sink, .turn_end, writer.written());
    }

    fn startBody(self: *const Runtime) !Value {
        const turn = self.turn orelse return error.InvalidJournalTransition;
        if (turn >= self.state.turns.items.len) return error.InvalidJournalTransition;
        return self.state.start(turn);
    }

    fn validateGeneration(self: *const Runtime, key: GenerationKey) !void {
        const turn = self.turn orelse return error.InvalidJournalTransition;
        const turn_id = try journal.string(try self.startBody(), "turnId");
        const expected_message = try std.fmt.allocPrint(self.alloc, "{s}:message:{d}", .{ turn_id, self.state.stepCount(turn) + 1 });
        defer self.alloc.free(expected_message);
        if (!std.mem.eql(u8, key.turnId, turn_id) or
            !std.mem.eql(u8, key.messageId, expected_message) or key.generationId.len == 0) return error.JournalConflict;
    }

    fn stepBody(self: *const Runtime, index: usize) !Value {
        const turn = self.turn orelse return error.InvalidJournalTransition;
        if (turn >= self.state.turns.items.len or index >= self.state.stepCount(turn)) return error.InvalidJournalTransition;
        return self.state.modelStep(turn, index);
    }

    fn callBody(self: *const Runtime, step_index: usize, call_index: usize) !Value {
        const calls = try journal.array(try self.stepBody(step_index), "calls");
        if (call_index >= calls.len) return error.InvalidJournalTransition;
        return calls[call_index];
    }
};

fn readExecutionThrough(alloc: Allocator, state: *const journal.State, turn: usize, count: usize, allow_partial: bool) !OwnedExecution {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const steps = try a.alloc(types.ToolExecutionStep, count);
    for (steps, 0..) |*destination, index| {
        var decision = try decodeDecision(alloc, state.modelStep(turn, index));
        defer decision.deinit();
        var result_count: usize = 0;
        while (result_count < decision.calls.len and state.toolResult(turn, index, result_count) != null) : (result_count += 1) {}
        if (result_count != decision.calls.len and (!allow_partial or index + 1 != count)) return error.InvalidJournalTransition;
        const results = try a.alloc(types.PersistedToolResult, result_count);
        for (results, 0..) |*result, call_index| {
            const calls = try journal.array(state.modelStep(turn, index), "calls");
            var recorded = try decodeResult(alloc, state.toolResult(turn, index, call_index).?, calls[call_index]);
            defer recorded.deinit();
            const copy = try types.dupePersistedToolResults(a, &.{recorded.result});
            result.* = copy[0];
        }
        destination.* = .{
            .assistant = if (decision.completion.content) |text| try a.dupe(u8, text) else null,
            .tool_calls = try types.dupeToolCallSlice(a, decision.calls),
            .tool_results = results,
            .provider_replay = if (decision.provider_replay) |replay| try types.dupeProviderReplay(a, replay) else null,
        };
    }
    var steering: std.ArrayList(types.PersistedSteering) = .empty;
    const turn_id = try journal.string(state.start(turn), "turnId");
    for (state.records.items) |record| {
        const body = record.payload.value;
        if (record.entry.kind != .model_step or !journal.isContext(body) or !try journal.isSteering(body)) continue;
        if (!std.mem.eql(u8, turn_id, try journal.string(body, "turnId"))) continue;
        const after = std.math.cast(usize, (try journal.field(body, "afterStepCount", .integer)).integer) orelse return error.InvalidJournalRecord;
        if (after > count) continue;
        const prefix = body.object.get("prefix") orelse return error.InvalidJournalRecord;
        for (try journal.array(body, "guidance"), 0..) |item, index| {
            try steering.append(a, .{
                .text = try a.dupe(u8, (try journal.field(item, "text", .string)).string),
                .assistant_prefix = if (index == 0 and prefix != .null) try a.dupe(u8, (try journal.field(prefix, "text", .string)).string) else null,
                .after_tool_step_count = after,
            });
        }
    }
    return .{ .arena = arena, .execution = .{ .tool_steps = steps, .steering = try steering.toOwnedSlice(a) } };
}

fn steeringCount(state: *const journal.State, turn_id: []const u8) !usize {
    var count: usize = 0;
    for (state.records.items) |record| {
        const body = record.payload.value;
        if (record.entry.kind == .model_step and journal.isContext(body) and try journal.isSteering(body) and
            std.mem.eql(u8, turn_id, try journal.string(body, "turnId")))
            count = try std.math.add(usize, count, (try journal.array(body, "guidance")).len);
    }
    return count;
}

fn steeringId(alloc: Allocator, turn_id: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}:steering:{d}", .{ turn_id, index });
}

fn validateSteering(alloc: Allocator, state: *const journal.State, body: Value) !void {
    if (state.turns.items.len == 0) return error.InvalidJournalTransition;
    const turn_id = try journal.string(body, "turnId");
    const offset = try steeringCount(state, turn_id);
    const guidance = try journal.array(body, "guidance");
    if (guidance.len == 0) return error.InvalidJournalRecord;
    for (guidance, 0..) |item, index| {
        if (item != .object or item.object.count() != 2) return error.InvalidJournalRecord;
        const expected = try steeringId(alloc, turn_id, offset + index + 1);
        defer alloc.free(expected);
        if (!std.mem.eql(u8, expected, try journal.string(item, "id"))) return error.JournalConflict;
        _ = try journal.field(item, "text", .string);
    }
    const prefix = body.object.get("prefix") orelse return error.InvalidJournalRecord;
    if (prefix != .null) {
        if (prefix != .object or prefix.object.count() != 2) return error.InvalidJournalRecord;
        const expected = try std.fmt.allocPrint(alloc, "{s}:assistant", .{try journal.string(guidance[0], "id")});
        defer alloc.free(expected);
        if (!std.mem.eql(u8, expected, try journal.string(prefix, "id"))) return error.JournalConflict;
        _ = try journal.field(prefix, "text", .string);
    }
    const retired = body.object.get("retiredDraft") orelse return error.InvalidJournalRecord;
    const turn = state.turns.items.len - 1;
    if (state.requestForCurrentStep(turn)) |request| {
        if (retired != .object or retired.object.count() != 3 or
            !std.mem.eql(u8, turn_id, try journal.string(retired, "turnId")) or
            !std.mem.eql(u8, try journal.string(request, "messageId"), try journal.string(retired, "messageId")) or
            !std.mem.eql(u8, try journal.string(request, "generationId"), try journal.string(retired, "generationId"))) return error.JournalConflict;
    } else if (retired != .null) return error.JournalConflict;
}

pub fn writeStatus(writer: *std.Io.Writer, alloc: Allocator, state: *const journal.State) !void {
    try state.ensureAvailable();
    const pending = state.pending();
    try writer.print("{{\"idle\":{s},\"lastSeq\":{d}", .{ if (pending == .idle) "true" else "false", state.last_seq });
    const turn = switch (pending) {
        .idle => {
            try writer.writeByte('}');
            return;
        },
        .model, .ending => |index| index,
        .tool => |position| position.turn,
    };
    const start = state.start(turn);
    try writer.writeAll(",\"pendingTurn\":{\"turnId\":");
    try std.json.Stringify.value(try journal.string(start, "turnId"), .{}, writer);
    try writer.writeAll(",\"requestId\":");
    try std.json.Stringify.value(try journal.string(start, "requestId"), .{}, writer);
    try writer.print(",\"lastSeq\":{d},\"awaiting\":", .{state.last_seq});
    if (pending == .tool) {
        var selected = (try pendingTool(alloc, state)).?;
        defer selected.deinit();
        try std.json.Stringify.value(.{ .tool = selected.tool }, .{}, writer);
    } else try writer.writeAll("\"model\"");
    try writer.writeAll("}}");
}

/// Builds a read-only unfinished-turn view. No entry is appended and no tool
/// or provider is called. The caller owns the returned history representation.
pub fn pendingHistory(outer_alloc: Allocator, state: *const journal.State) !?types.HistoryTurn {
    try state.ensureAvailable();
    const pending = state.pending();
    const turn = switch (pending) {
        .idle => return null,
        .model, .ending => |index| index,
        .tool => |position| position.turn,
    };
    var arena: std.heap.ArenaAllocator = .init(outer_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();
    const original_user = try decodeUser(alloc, state.start(turn));
    var full = try readExecutionThrough(outer_alloc, state, turn, state.stepCount(turn), true);
    defer full.deinit();
    var active: ?types.ToolCall = null;
    var assistant: ?[]u8 = null;
    if (pending == .tool) {
        const position = pending.tool;
        const latest = full.execution.tool_steps[position.step];
        active = latest.tool_calls[position.call];
        // The normal interrupted projection keeps a group's assistant with
        // its settled results. With no results, keep that text on the turn.
        if (latest.tool_results.len == 0) assistant = latest.assistant;
    }
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    try full.appendPromptMessages(alloc, &messages);
    if (pending != .tool and messages.items.len != 0) {
        const last = messages.items[messages.items.len - 1];
        if (last.role == .assistant and last.tool_calls.len == 0) assistant = if (last.content) |text| @constCast(text) else null;
    }
    const settled = try execution_memory.buildInterruptedExecutionMemory(alloc, messages.items, active);
    const history: types.HistoryTurn = .{ .interrupted = .{
        .user = original_user,
        .assistant = assistant,
        .tool_call = active,
        .execution = settled,
        .terminal_reason = .cancelled,
    } };
    return try types.dupeHistoryTurn(outer_alloc, history);
}

pub fn nextImageId(alloc: Allocator, records: *const journal.State, initial: usize) !usize {
    var next = initial;
    if (records.nativeBase()) |base| {
        var original = try genesis.decodeBase(alloc, base);
        defer original.deinit(alloc);
        const catalog = try session.collect_image_catalog(alloc, original.history, &.{});
        defer types.freeImageAttachmentSlice(alloc, catalog);
        next = @max(next, (try @import("../../images/image_attachments.zig").calculate_next_image_id(catalog)).next_id);
    }
    // Admitted inputs retain their identities even when a failed turn has no
    // model-history entry or the active input was paused before a response.
    for (0..records.turns.items.len) |index| {
        const user = try readUser(alloc, records, index);
        defer types.freeUserTurn(alloc, user);
        next = @max(next, (try @import("../../images/image_attachments.zig").calculate_next_image_id(user.images)).next_id);
    }
    return next;
}

/// Returns the owned original input for an acknowledged turn.
pub fn readUser(alloc: Allocator, state: *const journal.State, turn: usize) !types.UserTurn {
    if (turn >= state.turns.items.len) return error.InvalidJournalTransition;
    return decodeUser(alloc, state.start(turn));
}

fn decodeUser(alloc: Allocator, start: Value) !types.UserTurn {
    const bytes = try journal.string(start, "inputJson");
    try entry_codec.validateJsonBounds(bytes);
    const parsed = try std.json.parseFromSlice(Value, alloc, bytes, .{});
    defer parsed.deinit();
    return session_codec.parseUserTurn(alloc, parsed.value);
}

pub fn decodeRuntimeTurnId(start: Value) !u64 {
    const value = try journal.string(start, "runtimeTurnId");
    const id = std.fmt.parseInt(u64, value, 10) catch return error.InvalidJournalRecord;
    if (id == 0) return error.InvalidJournalRecord;
    return id;
}

fn decodeDecision(alloc: Allocator, body: Value) !OwnedDecision {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const wire = try std.json.parseFromValueLeaky(Completion, a, try journal.object(body, "completion"), .{ .allocate = .alloc_always });
    const values = try journal.array(body, "calls");
    const calls = try a.alloc(types.ToolCall, values.len);
    const replay = try a.alloc(journal.Replay, values.len);
    for (values, 0..) |value, index| {
        const call = try std.json.parseFromValueLeaky(Call, a, value, .{ .allocate = .alloc_always });
        try entry_codec.validateJsonBounds(call.argumentsJson);
        calls[index] = call.restore();
        replay[index] = call.replay;
    }
    const context_value = body.object.get("executionContext") orelse return error.InvalidJournalRecord;
    const context_json = switch (context_value) {
        .null => null,
        .object => blk: {
            try validateExecutionContext(a, context_value, false, calls);
            break :blk try std.json.Stringify.valueAlloc(a, context_value, .{});
        },
        else => return error.InvalidJournalRecord,
    };
    const provider_replay = try std.json.parseFromValueLeaky(?types.ProviderReplay, a, body.object.get("providerReplay") orelse return error.InvalidJournalRecord, .{ .allocate = .alloc_always });
    const key: GenerationKey = .{
        .turnId = try a.dupe(u8, try journal.string(body, "turnId")),
        .messageId = try a.dupe(u8, try journal.string(body, "messageId")),
        .generationId = try a.dupe(u8, try journal.string(body, "generationId")),
    };
    return .{
        .arena = arena,
        .completion = wire.restore(calls),
        .calls = calls,
        .replay = replay,
        .execution_context_json = context_json,
        .provider_replay = provider_replay,
        .key = key,
        .final = try journal.boolean(body, "final"),
    };
}

fn decodeResult(alloc: Allocator, body: Value, call: Value) !OwnedResult {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const result = try session_codec.parseToolResult(arena.allocator(), try journal.object(body, "persisted"), 9);
    const content = (try journal.field(body, "content", .string)).string;
    const display = try text_utils.sanitizeModelText(arena.allocator(), result.output);
    if (!std.mem.eql(u8, result.tool_call_id, try journal.string(call, "providerId")) or
        !std.mem.eql(u8, result.tool_name, try journal.string(call, "name")) or
        !std.mem.eql(u8, display, content) or
        (result.status != .success) != try journal.boolean(body, "isError")) return error.JournalConflict;
    return .{ .arena = arena, .result = result };
}

/// Purely rebuilds the core's canonical terminal history. Caller owns the slice
/// and every turn, freed with types.freeHistoryTurnSlice.
pub fn restoreHistory(alloc: Allocator, state: *const journal.State) ![]types.HistoryTurn {
    return restoreHistoryView(alloc, state, .model);
}

/// Restores the full native transcript, including history excluded from the
/// active model window. It shares the same acknowledged terminal records.
pub fn restoreArchiveHistory(alloc: Allocator, state: *const journal.State) ![]types.HistoryTurn {
    return restoreHistoryView(alloc, state, .archive);
}

/// A context replacement is an incremental model-state record. It does not
/// create a conversation turn or discard the acknowledged transcript.
pub fn recordCompaction(
    alloc: Allocator,
    state: *journal.State,
    sink: journal.Sink,
    summary: types.CompactedSummaryHistoryTurn,
    retained_from: types.ContextHistoryCut,
) !void {
    return recordCompactionImpl(alloc, state, sink, summary, retained_from, null);
}

pub fn recordActiveCompaction(
    alloc: Allocator,
    state: *journal.State,
    sink: journal.Sink,
    summary: types.CompactedSummaryHistoryTurn,
    retained_from: types.ContextHistoryCut,
    active: types.AssistantHistoryTurn,
) !void {
    return recordCompactionImpl(alloc, state, sink, summary, retained_from, active);
}

fn recordCompactionImpl(
    alloc: Allocator,
    state: *journal.State,
    sink: journal.Sink,
    summary: types.CompactedSummaryHistoryTurn,
    retained_from: types.ContextHistoryCut,
    active: ?types.AssistantHistoryTurn,
) !void {
    try state.ensureAvailable();
    const turn_id = switch (state.pending()) {
        .idle => null,
        .model => |index| try journal.string(state.start(index), "turnId"),
        else => return error.InvalidJournalTransition,
    };
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try writer.writer.writeAll("{\"v\":1,\"kind\":\"model_step\",\"phase\":\"context\",\"turnId\":");
    try json(&writer.writer, turn_id);
    try writer.writer.print(",\"afterTurnCount\":{d},\"summary\":", .{state.turns.items.len});
    try session_codec.writeHistoryTurn(&writer.writer, .{ .compacted_summary = summary });
    try writer.writer.writeAll(",\"retainedFrom\":");
    try json(&writer.writer, retained_from);
    if (active) |prefix| {
        if (state.pending() != .model) return error.InvalidJournalTransition;
        const turn = state.pending().model;
        var input: std.Io.Writer.Allocating = .init(alloc);
        defer input.deinit();
        try session_codec.writeUserTurn(&input.writer, prefix.user);
        if (!std.mem.eql(u8, try journal.string(state.start(turn), "inputJson"), input.written())) return error.JournalConflict;
        const history = try restoreHistory(alloc, state);
        defer types.freeHistoryTurnSlice(alloc, history);
        var boundary = try activeBoundary(state, turn);
        if (retained_from.turns == session.rawHistoryTurnCount(history)) {
            if (retained_from.tool_steps > prefix.execution.tool_steps.len or retained_from.steering > prefix.execution.steering.len) return error.InvalidJournalRecord;
            boundary.tool_steps = try std.math.add(usize, boundary.tool_steps, retained_from.tool_steps);
            boundary.steering = try std.math.add(usize, boundary.steering, retained_from.steering);
        }
        try writer.writer.print(",\"afterStepCount\":{d},\"activeThrough\":", .{state.stepCount(turn)});
        try json(&writer.writer, boundary);
    }
    try writer.writer.writeByte('}');
    const parsed = try std.json.parseFromSlice(Value, alloc, writer.written(), .{});
    defer parsed.deinit();
    try validateIncoming(alloc, state, parsed.value);
    const terminal_bytes = if (state.pending() == .model) reserve: {
        const runtime: Runtime = .{
            .state = state,
            .sink = sink,
            .alloc = alloc,
            .namespace = "",
            .creation_id = "",
            .request_id = "",
            .turn = state.pending().model,
        };
        break :reserve @max(max_model_record_bytes, try runtime.terminalBytes());
    } else max_model_record_bytes;
    try state.preflight(.{ .append_bytes = writer.written().len, .append_records = 1, .terminal_bytes = terminal_bytes });
    try state.append(alloc, sink, .model_step, writer.written());
}

fn activeBoundary(state: *const journal.State, turn: usize) !execution_memory.CompactedExecutionBoundary {
    return if (state.activeCompaction(turn)) |body| try parseActiveBoundary(body) else .{};
}

fn parseActiveBoundary(body: Value) !execution_memory.CompactedExecutionBoundary {
    const value = try journal.object(body, "activeThrough");
    if (value.object.count() != 2) return error.InvalidJournalRecord;
    var boundary: execution_memory.CompactedExecutionBoundary = .{};
    inline for (.{ "tool_steps", "steering" }) |name| {
        const number = (try journal.field(value, name, .integer)).integer;
        @field(boundary, name) = std.math.cast(usize, number) orelse return error.InvalidJournalRecord;
    }
    return boundary;
}

fn normalizedExecution(alloc: Allocator, state: *const journal.State, turn: usize) !OwnedExecution {
    var full = try readExecutionThrough(alloc, state, turn, state.stepCount(turn), true);
    errdefer full.deinit();
    const a = full.arena.allocator();
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    try full.appendPromptMessages(a, &messages);
    full.execution = try execution_memory.buildExecutionMemory(a, messages.items);
    return full;
}

fn restoreCompactedArchivePrefix(alloc: Allocator, state: *const journal.State, index: usize, turn: *types.HistoryTurn) !void {
    const boundary = try activeBoundary(state, index);
    if (boundary.tool_steps == 0 and boundary.steering == 0) return;
    const target = switch (turn.*) {
        .assistant => |*value| &value.execution,
        .interrupted => |*value| &value.execution,
        .compacted_summary => return error.InvalidJournalRecord,
    };
    var full = try normalizedExecution(alloc, state, index);
    defer full.deinit();
    if (boundary.tool_steps > full.execution.tool_steps.len or boundary.steering > full.execution.steering.len) return error.InvalidJournalRecord;
    const a = full.arena.allocator();
    var combined = target.*;
    combined.tool_steps = try a.alloc(types.ToolExecutionStep, boundary.tool_steps + target.tool_steps.len);
    @memcpy(combined.tool_steps[0..boundary.tool_steps], full.execution.tool_steps[0..boundary.tool_steps]);
    @memcpy(combined.tool_steps[boundary.tool_steps..], target.tool_steps);
    combined.steering = try a.alloc(types.PersistedSteering, boundary.steering + target.steering.len);
    @memcpy(combined.steering[0..boundary.steering], full.execution.steering[0..boundary.steering]);
    for (target.steering, combined.steering[boundary.steering..]) |source, *dest| {
        dest.* = source;
        dest.after_tool_step_count = std.math.add(usize, source.after_tool_step_count, boundary.tool_steps) catch return error.InvalidJournalRecord;
    }
    const replacement = try types.dupeExecutionMemory(alloc, combined);
    types.freeExecutionMemory(alloc, target.*);
    target.* = replacement;
}

fn contextCut(body: Value) !types.ContextHistoryCut {
    const value = try journal.object(body, "retainedFrom");
    if (value.object.count() != 3) return error.InvalidJournalRecord;
    var cut: types.ContextHistoryCut = .{};
    inline for (.{ "turns", "tool_steps", "steering" }) |name| {
        const number = (try journal.field(value, name, .integer)).integer;
        @field(cut, name) = std.math.cast(usize, number) orelse return error.InvalidJournalRecord;
    }
    return cut;
}

fn restoreHistoryView(alloc: Allocator, state: *const journal.State, view: enum { model, archive }) ![]types.HistoryTurn {
    var history: std.ArrayList(types.HistoryTurn) = .empty;
    errdefer {
        for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
        history.deinit(alloc);
    }
    if (state.nativeBase()) |base| {
        var decoded = switch (view) {
            .model => try genesis.decodeContext(alloc, base),
            .archive => try genesis.decodeBase(alloc, base),
        };
        defer decoded.deinit(alloc);
        try history.appendSlice(alloc, decoded.history);
        alloc.free(decoded.history);
        decoded.history = &.{};
    }
    var turn_index: usize = 0;
    for (state.records.items) |record| {
        const body = record.payload.value;
        if (record.entry.kind == .model_step and journal.isContext(body)) {
            if (try journal.isSteering(body)) continue;
            const summary = try session_codec.parseHistoryTurn(alloc, try journal.object(body, "summary"));
            var summary_owned = true;
            defer if (summary_owned) types.freeHistoryTurn(alloc, summary);
            if (summary != .compacted_summary) return error.InvalidJournalRecord;
            var cut = try contextCut(body);
            if (body.object.contains("activeThrough") and cut.turns == session.rawHistoryTurnCount(history.items)) {
                cut.tool_steps = 0;
                cut.steering = 0;
            }
            if (view == .model) {
                const next = try session.prepareCompactedHistory(alloc, history.items, summary.compacted_summary, cut);
                for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
                history.deinit(alloc);
                history = .fromOwnedSlice(next);
            } else {
                try history.append(alloc, summary);
                summary_owned = false;
            }
            continue;
        }
        if (record.entry.kind != .turn_end) continue;
        const index = turn_index;
        turn_index += 1;
        const outcome = body;
        const value = outcome.object.get("history") orelse return error.InvalidJournalRecord;
        if (value == .null) continue;
        var turn = try session_codec.parseHistoryTurn(alloc, value);
        errdefer types.freeHistoryTurn(alloc, turn);
        try bindOriginalPendingCall(alloc, state, index, &turn);
        if (view == .archive) try restoreCompactedArchivePrefix(alloc, state, index, &turn);
        try history.append(alloc, turn);
    }
    return history.toOwnedSlice(alloc);
}

/// Caller owns the parsed value. Malformed arguments remain an exact string for
/// inspection; execution continues to validate the recorded raw call separately.
pub fn callInput(alloc: Allocator, arguments_json: []const u8) !std.json.Parsed(Value) {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena);
    arena.* = .init(alloc);
    errdefer arena.deinit();
    const value = try inputValue(arena.allocator(), arguments_json);
    return .{ .arena = arena, .value = value };
}

pub fn pendingTool(alloc: Allocator, state: *const journal.State) !?OwnedPendingTool {
    const pending = state.pending();
    if (pending != .tool) return null;
    const position = pending.tool;
    const call = (try journal.array(state.modelStep(position.turn, position.step), "calls"))[position.call];
    var arena: std.heap.ArenaAllocator = .init(alloc);
    errdefer arena.deinit();
    const a = arena.allocator();
    const tool: PendingTool = .{
        .callId = try a.dupe(u8, try journal.string(call, "callId")),
        .name = try a.dupe(u8, try journal.string(call, "name")),
        .input = try inputValue(a, try journal.string(call, "argumentsJson")),
        .replay = std.meta.stringToEnum(journal.Replay, try journal.string(call, "replay")) orelse return error.InvalidJournalRecord,
    };
    return .{ .arena = arena, .tool = tool };
}

fn inputValue(arena: Allocator, arguments_json: []const u8) !Value {
    try entry_codec.validateJsonBounds(arguments_json);
    return std.json.parseFromSliceLeaky(Value, arena, arguments_json, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => .{ .string = try arena.dupe(u8, arguments_json) },
    };
}

// Legacy history readers intentionally repair malformed tool arguments. Journal
// recovery has the exact selected call, so use it for the pending evidence.
fn bindOriginalPendingCall(alloc: Allocator, state: *const journal.State, index: usize, history: *types.HistoryTurn) !void {
    const outcome = state.outcome(index) orelse return;
    const result = try journal.object(outcome, "result");
    const pending = result.object.get("pendingTool") orelse return;
    if (history.* != .interrupted) return error.JournalConflict;
    const id = try journal.string(pending, "callId");
    for (0..state.stepCount(index)) |step| {
        for (try journal.array(state.modelStep(index, step), "calls")) |value| {
            if (!std.mem.eql(u8, id, try journal.string(value, "callId"))) continue;
            var arena: std.heap.ArenaAllocator = .init(alloc);
            defer arena.deinit();
            const call = try std.json.parseFromValueLeaky(Call, arena.allocator(), value, .{});
            const original = try types.dupeToolCall(alloc, call.restore());
            if (history.interrupted.tool_call) |prior| types.freeToolCall(alloc, prior);
            history.interrupted.tool_call = original;
            return;
        }
    }
    return error.JournalConflict;
}

/// Parses provider authority and budgets. Version two references the owning
/// turn_start instead of duplicating its input. Execution must bind the original
/// user validated by begin(); the empty user here is only the parser's carrier.
pub fn parseRecoveryMetadata(alloc: Allocator, context: Value) !session_codec.RecoveryCheckpoint {
    const recovery = try journal.object(context, "recovery");
    const version = context.object.get("v") orelse {
        if (context.object.count() != 2) return error.InvalidJournalRecord;
        return session_codec.parseRecoveryCheckpoint(alloc, recovery);
    };
    if (version != .integer or version.integer != 2 or context.object.count() != 3 or
        recovery.object.contains("user") or recovery.object.contains("route_identity")) return error.InvalidJournalRecord;
    if ((try journal.field(recovery, "version", .integer)).integer != 2) return error.InvalidJournalRecord;
    var fields = try recovery.object.clone(alloc);
    defer fields.deinit(alloc);
    var user: std.json.ObjectMap = .empty;
    defer user.deinit(alloc);
    try user.put(alloc, "text", .{ .string = "" });
    try user.put(alloc, "images", .{ .array = std.json.Array.init(alloc) });
    try fields.put(alloc, "user", .{ .object = user });
    return session_codec.parseRecoveryCheckpoint(alloc, .{ .object = fields });
}

fn validateExecutionContext(alloc: Allocator, context: Value, outstanding: bool, calls: []const types.ToolCall) !void {
    if (context != .object) return error.InvalidJournalRecord;
    var checkpoint = try parseRecoveryMetadata(alloc, context);
    defer checkpoint.deinit(alloc);
    if (checkpoint.outstanding_reservation != outstanding) return error.InvalidJournalRecord;
    const preparations = try journal.array(context, "preparations");
    if (preparations.len != calls.len) return error.InvalidJournalRecord;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    for (preparations, calls) |value, call| {
        const preparation = try std.json.parseFromValueLeaky(Preparation, arena.allocator(), value, .{});
        try preparation.validate(call);
    }
}

/// Checks one decoded payload against the acknowledged prefix before adoption.
/// The State owner validates sequence and transitions; this layer validates the
/// core DTOs. It retains no borrowed body, changes no state, and executes no I/O.
pub fn validateIncoming(alloc: Allocator, state: *const journal.State, body: Value) !void {
    const kind = std.meta.stringToEnum(journal.Kind, try journal.string(body, "kind")) orelse return error.InvalidJournalRecord;
    switch (kind) {
        .turn_start => {
            const user = try decodeUser(alloc, body);
            defer types.freeUserTurn(alloc, user);
            _ = try decodeRuntimeTurnId(body);
            try session_codec.validateModelPreference(try journal.string(body, "model"));
            const bytes = try journal.string(body, "inputJson");
            const hash = journal.inputHash(bytes);
            if (!std.mem.eql(u8, &hash, try journal.string(body, "inputHash"))) return error.JournalConflict;
        },
        .model_step => {
            if (journal.isContext(body)) {
                if (try journal.isSteering(body)) return validateSteering(alloc, state, body);
                const summary = try session_codec.parseHistoryTurn(alloc, try journal.object(body, "summary"));
                defer types.freeHistoryTurn(alloc, summary);
                if (summary != .compacted_summary) return error.InvalidJournalRecord;
                var cut = try contextCut(body);
                if (body.object.contains("activeThrough")) {
                    if (state.pending() != .model) return error.InvalidJournalTransition;
                    const turn = state.pending().model;
                    const after = (try journal.field(body, "afterStepCount", .integer)).integer;
                    if (after < 0 or @as(u64, @intCast(after)) != state.stepCount(turn)) return error.JournalConflict;
                    const boundary = try parseActiveBoundary(body);
                    const prior = try activeBoundary(state, turn);
                    var full = try normalizedExecution(alloc, state, turn);
                    defer full.deinit();
                    if (boundary.tool_steps < prior.tool_steps or boundary.steering < prior.steering or
                        boundary.tool_steps > full.execution.tool_steps.len or boundary.steering > full.execution.steering.len) return error.InvalidJournalRecord;
                } else if (body.object.contains("afterStepCount")) return error.InvalidJournalRecord;
                const current = try restoreHistory(alloc, state);
                defer types.freeHistoryTurnSlice(alloc, current);
                if (body.object.contains("activeThrough")) {
                    const prior = try activeBoundary(state, state.pending().model);
                    const boundary = try parseActiveBoundary(body);
                    const touches_active = cut.turns == session.rawHistoryTurnCount(current);
                    const steps = std.math.add(usize, prior.tool_steps, if (touches_active) cut.tool_steps else 0) catch return error.InvalidJournalRecord;
                    const steering = std.math.add(usize, prior.steering, if (touches_active) cut.steering else 0) catch return error.InvalidJournalRecord;
                    if (boundary.tool_steps != steps or boundary.steering != steering) return error.JournalConflict;
                    if (touches_active) {
                        cut.tool_steps = 0;
                        cut.steering = 0;
                    }
                }
                const prepared = try session.prepareCompactedHistory(alloc, current, summary.compacted_summary, cut);
                types.freeHistoryTurnSlice(alloc, prepared);
            } else if (try journal.isRequest(body)) {
                try validateExecutionContext(alloc, try journal.object(body, "executionContext"), true, &.{});
            } else {
                var decision = try decodeDecision(alloc, body);
                decision.deinit();
            }
        },
        .tool_result => {
            const pending = state.pending();
            if (pending != .tool) return error.InvalidJournalTransition;
            const position = pending.tool;
            const call = (try journal.array(state.modelStep(position.turn, position.step), "calls"))[position.call];
            if (!std.mem.eql(u8, try journal.string(body, "callId"), try journal.string(call, "callId"))) return error.JournalConflict;
            var result = try decodeResult(alloc, body, call);
            result.deinit();
        },
        .turn_end => try validateIncomingEnd(alloc, state, body),
        .checkpoint => {
            // State has already validated each record against its candidate
            // prefix before replacing the retained checkpoint.
            _ = try journal.array(body, "records");
            _ = try journal.field(body, "lastIncludedSeq", .integer);
            if (body.object.get("nativeBase")) |base| {
                var decoded = try genesis.decodeBase(alloc, base);
                decoded.deinit(alloc);
            }
        },
    }
}

fn validateIncomingEnd(alloc: Allocator, state: *const journal.State, body: Value) !void {
    const result = try journal.object(body, "result");
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    if (result.object.get("usage")) |usage| {
        _ = try std.json.parseFromValueLeaky(?types.Usage, arena.allocator(), usage, .{});
    }
    const raw_history = body.object.get("history") orelse return error.InvalidJournalRecord;
    const history: ?types.HistoryTurn = if (raw_history == .null)
        null
    else
        try session_codec.parseHistoryTurn(alloc, raw_history);
    defer if (history) |turn| types.freeHistoryTurn(alloc, turn);

    const pending_tool = result.object.get("pendingTool") orelse return;
    const pending = state.pending();
    if (pending != .tool) return error.JournalConflict;
    const position = pending.tool;
    const call = (try journal.array(state.modelStep(position.turn, position.step), "calls"))[position.call];
    if (!std.mem.eql(u8, try journal.string(pending_tool, "callId"), try journal.string(call, "callId")) or
        !std.mem.eql(u8, try journal.string(pending_tool, "name"), try journal.string(call, "name"))) return error.JournalConflict;
    const input = pending_tool.object.get("input") orelse return error.InvalidJournalRecord;
    const original = try inputValue(arena.allocator(), try journal.string(call, "argumentsJson"));
    if (!jsonValueEqual(input, original)) return error.JournalConflict;
    if (history) |turn| {
        if (turn != .interrupted or turn.interrupted.tool_call == null) return error.JournalConflict;
        // The legacy decoder may repair malformed arguments. Validate the raw
        // history evidence against the selected call instead of accepting that
        // repair as a different executable input.
        const historical_call = try journal.object(raw_history, "tool_call");
        if (!std.mem.eql(u8, try journal.string(historical_call, "id"), try journal.string(call, "providerId")) or
            !std.mem.eql(u8, try journal.string(historical_call, "name"), try journal.string(call, "name")) or
            !std.mem.eql(u8, (try journal.field(historical_call, "arguments_json", .string)).string, try journal.string(call, "argumentsJson"))) return error.JournalConflict;
        if (!jsonValueEqual(historical_call.object.get("provider_result") orelse return error.InvalidJournalRecord, call.object.get("provider_result") orelse return error.InvalidJournalRecord)) return error.JournalConflict;
    }
}

// Inputs are already bounded to the codec's JSON depth before this comparison.
// Object ordering is irrelevant; numeric comparisons never round an integer.
fn jsonValueEqual(left: Value, right: Value) bool {
    if (left == .integer and right == .float) return integerMatchesFloat(left.integer, right.float);
    if (left == .float and right == .integer) return integerMatchesFloat(right.integer, left.float);
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |value| value == right.bool,
        .integer => |value| value == right.integer,
        .float => |value| value == right.float,
        .number_string => |value| std.mem.eql(u8, value, right.number_string),
        .string => |value| std.mem.eql(u8, value, right.string),
        .array => |value| blk: {
            if (value.items.len != right.array.items.len) break :blk false;
            for (value.items, right.array.items) |a, b| if (!jsonValueEqual(a, b)) break :blk false;
            break :blk true;
        },
        .object => |value| blk: {
            if (value.count() != right.object.count()) break :blk false;
            var iterator = value.iterator();
            while (iterator.next()) |entry| {
                const other = right.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValueEqual(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn integerMatchesFloat(integer: i64, float: f64) bool {
    if (!std.math.isFinite(float) or @trunc(float) != float) return false;
    // maxInt(i64) rounds upward to 2^63 as f64, so the upper bound is strict.
    if (float < @as(f64, @floatFromInt(std.math.minInt(i64))) or
        float >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return false;
    return @as(i64, @intFromFloat(float)) == integer;
}

/// Validates the retained core payloads once after envelope replay, before the
/// restored instance accepts writes or execution. No persistence callbacks run.
pub fn validateRestoredState(alloc: Allocator, state: *journal.State) !void {
    try state.ensureAvailable();
    // Request reservations deliberately are not decision steps. Validate their
    // typed context without turning them into transcript or execution entries.
    for (state.records.items) |record| {
        if (record.entry.kind == .model_step and try journal.isRequest(record.payload.value)) {
            try validateExecutionContext(alloc, try journal.object(record.payload.value, "executionContext"), true, &.{});
        }
    }
    for (state.turns.items, 0..) |_, index| {
        const start = state.start(index);
        var view: Runtime = .{
            .state = state,
            .sink = .{ .context = state, .append_fn = forbidAppend },
            .alloc = alloc,
            .namespace = try journal.string(start, "namespace"),
            .creation_id = "validation",
            .request_id = try journal.string(start, "requestId"),
            .turn = index,
        };
        const restored_user = try view.user(alloc);
        defer types.freeUserTurn(alloc, restored_user);
        _ = try view.runtimeTurnId();
        for (0..state.stepCount(index)) |step_index| {
            var decision = try view.recordedDecision(alloc, step_index);
            defer decision.deinit();
            for (0..decision.calls.len) |call_index| {
                if (try view.recordedResult(alloc, step_index, call_index)) |owned| {
                    var result = owned;
                    result.deinit();
                }
            }
        }
        if (state.outcome(index)) |outcome| {
            const history = outcome.object.get("history") orelse return error.InvalidJournalRecord;
            if (history != .null) {
                var turn = try session_codec.parseHistoryTurn(alloc, history);
                defer types.freeHistoryTurn(alloc, turn);
                try bindOriginalPendingCall(alloc, state, index, &turn);
            }
        }
    }
}

fn forbidAppend(_: *anyopaque, _: journal.Entry) !void {
    return error.InvalidJournalTransition;
}

fn json(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

const TestSink = struct {
    count: usize = 0,
    fail: bool = false,

    fn append(raw: *anyopaque, entry: journal.Entry) !void {
        const self: *TestSink = @ptrCast(@alignCast(raw));
        try std.testing.expectEqual(self.count + 1, entry.seq);
        self.count += 1;
        if (self.fail) return error.LostAcknowledgement;
    }

    fn runtime(self: *TestSink, state: *journal.State, request_id: []const u8) Runtime {
        return .{
            .state = state,
            .sink = .{ .context = self, .append_fn = append },
            .alloc = std.testing.allocator,
            .namespace = "durable-session",
            .creation_id = "runtime-creation",
            .request_id = request_id,
        };
    }
};

const test_input: types.UserTurn = .{ .text = @constCast("Make a durable change") };

test "journal witness native guard encloses mutation and failed acknowledgement" {
    const Guarded = struct {
        state: *journal.State,
        store: TestSink = .{},
        held: bool = false,
        invalid: bool = false,

        fn enter(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.invalid = self.invalid or self.held or self.state.isBlocked();
            self.held = true;
        }
        fn leave(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.invalid = self.invalid or !self.held or self.state.isBlocked() != self.store.fail;
            self.held = false;
        }
        fn append(raw: *anyopaque, entry: journal.Entry) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.invalid = self.invalid or !self.held or !self.state.isBlocked();
            try TestSink.append(&self.store, entry);
        }
    };
    for ([_]bool{ false, true }) |fail| {
        var state: journal.State = .{};
        defer state.deinit(std.testing.allocator);
        var owner: Guarded = .{ .state = &state, .store = .{ .fail = fail } };
        var runtime = owner.store.runtime(&state, "guarded-request");
        runtime.sink = .{ .context = &owner, .append_fn = Guarded.append, .guard = .{ .enter = Guarded.enter, .leave = Guarded.leave } };
        if (fail) {
            try std.testing.expectError(error.PersistenceUncertain, runtime.begin(test_input, "model", 1, false));
        } else _ = try runtime.begin(test_input, "model", 1, false);
        try std.testing.expect(!owner.invalid);
        try std.testing.expect(!owner.held);
        try std.testing.expectEqual(@as(u64, if (fail) 0 else 1), state.last_seq);
    }
}

test "journal witness repeated active compaction preserves archive and restores its model boundary" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "compacted-request");
    _ = try runtime.begin(test_input, "model", 1, false);
    for ([_][]const u8{ "first", "second" }) |id| {
        var key = try runtime.generation();
        defer key.deinit(alloc);
        const step = try runtime.recordDecision(.{}, &.{.{ .id = id, .name = "read", .arguments_json = "{}" }}, &.{.safe}, key, false, null, null);
        try runtime.recordResult(step, 0, .{
            .tool_call_id = @constCast(id),
            .tool_name = @constCast("read"),
            .status = .success,
            .output = @constCast(id),
            .output_bytes = id.len,
            .stored_output_bytes = id.len,
        });
    }
    var full = try normalizedExecution(alloc, &state, 0);
    defer full.deinit();
    for (0..2) |round| {
        const prior = try runtime.compactionBoundary();
        const remaining = try prior.project(full.arena.allocator(), full.execution);
        try recordActiveCompaction(alloc, &state, runtime.sink, .{
            .summary = @constCast("<context_handoff>saved results</context_handoff>"),
            .removed_turn_count = 0,
            .compaction_count = round + 1,
        }, .{ .tool_steps = 1 }, .{ .user = test_input, .assistant = @constCast(""), .execution = remaining });
        try std.testing.expectEqual(round + 1, (try runtime.compactionBoundary()).tool_steps);
    }
    var restored: journal.State = .{};
    defer restored.deinit(alloc);
    var validator: TestValidator = .{ .alloc = alloc };
    for (state.records.items) |record| try restoreTestEntry(&restored, &validator, record.entry);
    var resumed = sink.runtime(&restored, "compacted-request");
    _ = try resumed.begin(test_input, "model", 1, true);
    var prefix = try resumed.prefixExecution(alloc);
    defer prefix.deinit();
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    try prefix.appendPromptMessages(prefix.arena.allocator(), &messages);
    const boundary = try resumed.compactionBoundary();
    try std.testing.expectEqual(messages.items.len, try execution_memory.retainedMessageOffset(messages.items, boundary));
    const model_before = try restoreHistory(alloc, &restored);
    defer types.freeHistoryTurnSlice(alloc, model_before);
    try std.testing.expectEqual(@as(usize, 1), model_before.len);
    try std.testing.expect(model_before[0] == .compacted_summary);
    var key = try resumed.generation();
    defer key.deinit(alloc);
    _ = try resumed.recordDecision(.{ .content = "done" }, &.{}, &.{}, key, true, null, null);
    const result = try std.json.parseFromSlice(Value, alloc, "{\"ok\":true,\"stopReason\":\"stop\"}", .{});
    defer result.deinit();
    try resumed.finish(result.value, .{ .assistant = .{ .user = test_input, .assistant = @constCast("done") } });
    const model = try restoreHistory(alloc, &restored);
    defer types.freeHistoryTurnSlice(alloc, model);
    try std.testing.expectEqual(@as(usize, 0), model[model.len - 1].assistant.execution.tool_steps.len);
    const archive = try restoreArchiveHistory(alloc, &restored);
    defer types.freeHistoryTurnSlice(alloc, archive);
    const steps = archive[archive.len - 1].assistant.execution.tool_steps;
    try std.testing.expectEqual(@as(usize, 2), steps.len);
    try std.testing.expectEqualStrings("first", steps[0].tool_results[0].output);
    try std.testing.expectEqualStrings("second", steps[1].tool_results[0].output);
    try validateRestoredState(alloc, &restored);
    var checkpoint = try restored.checkpoint(alloc, resumed.sink);
    defer checkpoint.deinit(alloc);
    var reopened: journal.State = .{};
    defer reopened.deinit(alloc);
    try restoreTestEntry(&reopened, &validator, checkpoint.entry);
    const checkpoint_archive = try restoreArchiveHistory(alloc, &reopened);
    defer types.freeHistoryTurnSlice(alloc, checkpoint_archive);
    try std.testing.expectEqual(@as(usize, 2), checkpoint_archive[checkpoint_archive.len - 1].assistant.execution.tool_steps.len);
}

test "journal witness failed active compaction acknowledgement preserves the original model prefix" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "compacted-request");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    _ = try runtime.recordDecision(.{ .content = "before guidance" }, &.{}, &.{}, key, false, null, null);
    try runtime.recordSteering(&.{"keep this guidance"}, null);
    var full = try normalizedExecution(alloc, &state, 0);
    defer full.deinit();
    sink.fail = true;
    try std.testing.expectError(error.PersistenceUncertain, recordActiveCompaction(alloc, &state, runtime.sink, .{
        .summary = @constCast("<context_handoff>new summary</context_handoff>"),
        .removed_turn_count = 0,
        .compaction_count = 1,
    }, .{ .steering = 1 }, .{ .user = test_input, .assistant = @constCast(""), .execution = full.execution }));
    try std.testing.expect(state.blocked);
    var restored: journal.State = .{};
    defer restored.deinit(alloc);
    var validator: TestValidator = .{ .alloc = alloc };
    for (state.records.items) |record| try restoreTestEntry(&restored, &validator, record.entry);
    try std.testing.expectEqual(@as(usize, 0), (try activeBoundary(&restored, 0)).steering);
    var retained = try normalizedExecution(alloc, &restored, 0);
    defer retained.deinit();
    try std.testing.expectEqualStrings("keep this guidance", retained.execution.steering[0].text);
    try std.testing.expectEqualStrings("before guidance", retained.execution.steering[0].assistant_prefix.?);
    var next_sink: TestSink = .{ .count = @intCast(restored.last_seq) };
    var next = next_sink.runtime(&restored, "compacted-request");
    _ = try next.begin(test_input, "model", 1, true);
    try recordActiveCompaction(alloc, &restored, next.sink, .{
        .summary = @constCast("<context_handoff>saved guidance</context_handoff>"),
        .removed_turn_count = 0,
        .compaction_count = 1,
    }, .{ .steering = 1 }, .{ .user = test_input, .assistant = @constCast(""), .execution = retained.execution });
    const abandoned = (try next.abandon()).?;
    defer types.freeHistoryTurn(alloc, abandoned);
    try std.testing.expectEqual(@as(usize, 0), abandoned.interrupted.execution.steering.len);
    const archive = try restoreArchiveHistory(alloc, &restored);
    defer types.freeHistoryTurnSlice(alloc, archive);
    const guidance = archive[archive.len - 1].interrupted.execution.steering;
    try std.testing.expectEqual(@as(usize, 1), guidance.len);
    try std.testing.expectEqualStrings("keep this guidance", guidance[0].text);
    try validateRestoredState(alloc, &restored);
}

test "journal witness steering reopens a final response and preserves its position through recreation" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "guided-request");
    _ = try runtime.begin(test_input, "model", 1, false);
    var first = try runtime.generation();
    defer first.deinit(alloc);
    _ = try runtime.recordDecision(.{ .content = "Before guidance" }, &.{}, &.{}, first, true, null, null);
    try std.testing.expect(state.pending() == .ending);
    try runtime.recordSteering(&.{"Use the new requirement"}, null);
    try std.testing.expect(state.pending() == .model);
    try std.testing.expect(runtime.recoveryStep() == null);
    var second = try runtime.generation();
    defer second.deinit(alloc);
    const context = try testExecutionContext(&runtime, 1, true, &.{});
    defer alloc.free(context);
    try runtime.reserveRequest(second, context);
    try runtime.recordSteering(&.{"Keep the interrupted thought"}, "Partial response");

    var restored: journal.State = .{};
    defer restored.deinit(alloc);
    var validator: TestValidator = .{ .alloc = alloc };
    for (state.records.items) |record| try restoreTestEntry(&restored, &validator, record.entry);
    var next = sink.runtime(&restored, "guided-request");
    try std.testing.expectEqual(Selection.pending, try next.begin(test_input, "model", 1, true));
    var prefix = try next.prefixExecution(alloc);
    defer prefix.deinit();
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    try prefix.appendPromptMessages(a, &messages);
    try std.testing.expectEqual(@as(usize, 4), messages.items.len);
    try std.testing.expectEqualStrings("Before guidance", messages.items[0].content.?);
    try std.testing.expect(messages.items[1].role == .user);
    try std.testing.expect(std.mem.indexOf(u8, messages.items[1].content.?, "Use the new requirement") != null);
    try std.testing.expectEqualStrings("Partial response", messages.items[2].content.?);
    try std.testing.expect(messages.items[3].role == .user);
    try std.testing.expect(std.mem.indexOf(u8, messages.items[3].content.?, "Keep the interrupted thought") != null);
    const canonical = try execution_memory.buildExecutionMemory(a, messages.items);
    try std.testing.expectEqual(@as(usize, 2), canonical.steering.len);
    try std.testing.expectEqualStrings("Use the new requirement", canonical.steering[0].text);
    try std.testing.expectEqualStrings("Keep the interrupted thought", canonical.steering[1].text);
    try std.testing.expectEqual(@as(usize, 0), canonical.tool_steps.len);
    try std.testing.expectEqualStrings("Before guidance", canonical.steering[0].assistant_prefix orelse "missing response");
    try std.testing.expectEqual(@as(usize, 0), canonical.steering[0].after_tool_step_count);
    try std.testing.expectEqualStrings("Partial response", canonical.steering[1].assistant_prefix orelse "missing prefix");
    const pending = (try pendingHistory(alloc, &restored)).?;
    defer types.freeHistoryTurn(alloc, pending);
    try std.testing.expectEqual(@as(usize, 2), pending.interrupted.execution.steering.len);
}

test "journal witness failed steering admission leaves an acknowledged final response recoverable" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "guided-request");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    _ = try runtime.recordDecision(.{ .content = "Saved final answer" }, &.{}, &.{}, key, true, null, null);
    sink.fail = true;
    try std.testing.expectError(error.PersistenceUncertain, runtime.recordSteering(&.{"Unacknowledged guidance"}, null));
    try std.testing.expect(state.blocked);
    var restored: journal.State = .{};
    defer restored.deinit(alloc);
    var validator: TestValidator = .{ .alloc = alloc };
    for (state.records.items) |record| try restoreTestEntry(&restored, &validator, record.entry);
    try std.testing.expect(restored.pending() == .ending);
}

test "journal witness provider terminal response closes after its saved result and respects later reservations" {
    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |reserve_next| {
        var state: journal.State = .{};
        defer state.deinit(alloc);
        var sink: TestSink = .{};
        var runtime = sink.runtime(&state, "provider-terminal");
        _ = try runtime.begin(test_input, "model", 1, false);
        var key = try runtime.generation();
        defer key.deinit(alloc);
        const call: types.ToolCall = .{
            .id = "provider-call",
            .name = "lookup",
            .arguments_json = "{}",
            .provider_result = "{\"content\":\"stored\"}",
            .provenance = .provider_executed,
        };
        _ = try runtime.recordDecision(.{ .content = "provider answer", .finish_reason = .stop, .tool_calls = &.{call} }, &.{call}, &.{.blocked}, key, false, null, null);
        const result = try std.json.parseFromSlice(Value, alloc, "{\"ok\":true,\"stopReason\":\"stop\"}", .{});
        defer result.deinit();
        const history: types.HistoryTurn = .{ .assistant = .{ .user = test_input, .assistant = @constCast("provider answer") } };
        try std.testing.expectError(error.InvalidJournalTransition, runtime.finish(result.value, history));
        try runtime.recordResult(0, 0, .{
            .tool_call_id = @constCast("provider-call"),
            .tool_name = @constCast("lookup"),
            .status = .success,
            .output = @constCast("stored"),
            .output_bytes = 6,
            .stored_output_bytes = 6,
            .provider_native = true,
        });
        try std.testing.expectEqual(@as(?usize, 0), runtime.recoveryStep());
        if (reserve_next) {
            var next = try runtime.generation();
            defer next.deinit(alloc);
            const context = try testExecutionContext(&runtime, 1, true, &.{});
            defer alloc.free(context);
            try runtime.reserveRequest(next, context);
            try std.testing.expect(runtime.recoveryStep() == null);
            try std.testing.expectError(error.InvalidJournalTransition, runtime.finish(result.value, history));
        } else {
            try runtime.finish(result.value, history);
            try std.testing.expect(state.pending() == .idle);
        }
    }
}

test "journal witness context compaction preserves transcript and request mappings through checkpoint" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    const result = try std.json.parseFromSlice(Value, alloc, "{\"ok\":true,\"stopReason\":\"stop\"}", .{});
    defer result.deinit();
    for ([_][]const u8{ "first", "second" }, 0..) |id, index| {
        var runtime = sink.runtime(&state, id);
        const user: types.UserTurn = .{ .text = @constCast(id) };
        _ = try runtime.begin(user, "model", index + 1, false);
        var key = try runtime.generation();
        defer key.deinit(alloc);
        _ = try runtime.recordDecision(.{ .content = id }, &.{}, &.{}, key, true, null, null);
        try runtime.finish(result.value, .{ .assistant = .{ .user = user, .assistant = @constCast(id) } });
    }
    const callback: journal.Sink = .{ .context = &sink, .append_fn = TestSink.append };
    try recordCompaction(alloc, &state, callback, .{
        .summary = @constCast("older context summary"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    }, .{ .turns = 1 });
    const model_history = try restoreHistory(alloc, &state);
    defer types.freeHistoryTurnSlice(alloc, model_history);
    try std.testing.expectEqual(@as(usize, 2), model_history.len);
    try std.testing.expectEqualStrings("older context summary", model_history[0].compacted_summary.summary);
    try std.testing.expectEqualStrings("second", model_history[1].assistant.assistant);
    const archive = try restoreArchiveHistory(alloc, &state);
    defer types.freeHistoryTurnSlice(alloc, archive);
    try std.testing.expectEqual(@as(usize, 3), archive.len);
    try std.testing.expectEqualStrings("first", archive[0].assistant.assistant);
    try std.testing.expectEqualStrings("second", archive[1].assistant.assistant);
    var checkpoint = try state.checkpoint(alloc, callback);
    defer checkpoint.deinit(alloc);
    var restored: journal.State = .{};
    defer restored.deinit(alloc);
    var validator: TestValidator = .{ .alloc = alloc };
    try restoreTestEntry(&restored, &validator, checkpoint.entry);
    try std.testing.expectEqual(@as(usize, 2), restored.requests.count());
    const replay = try restoreHistory(alloc, &restored);
    defer types.freeHistoryTurnSlice(alloc, replay);
    try std.testing.expectEqualStrings("older context summary", replay[0].compacted_summary.summary);
    try std.testing.expectEqualStrings("second", replay[1].assistant.assistant);
    sink.fail = true;
    try std.testing.expectError(error.PersistenceUncertain, recordCompaction(alloc, &state, callback, .{
        .summary = @constCast("uncertain replacement"),
        .removed_turn_count = 1,
        .compaction_count = 2,
    }, .{ .turns = 1 }));
    try std.testing.expect(state.blocked);
    try std.testing.expectEqual(checkpoint.entry.seq, state.last_seq);
}

const TestValidator = struct {
    alloc: Allocator,
    calls: usize = 0,

    fn interface(self: *TestValidator) journal.Validator {
        return .{ .context = self, .validate_fn = validate };
    }

    fn validate(raw: *anyopaque, state: *const journal.State, body: Value) !void {
        const self: *TestValidator = @ptrCast(@alignCast(raw));
        self.calls += 1;
        try validateIncoming(self.alloc, state, body);
    }
};

fn restoreTestEntry(state: *journal.State, validator: *TestValidator, entry: journal.Entry) !void {
    try state.restoreValidated(validator.alloc, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash, validator.interface());
}

fn testExecutionContext(runtime: *const Runtime, consumed: usize, outstanding: bool, preparations: []const Preparation) ![]u8 {
    return testExecutionContextVersion(runtime, consumed, outstanding, preparations, false);
}

fn testExecutionContextVersion(runtime: *const Runtime, consumed: usize, outstanding: bool, preparations: []const Preparation, reference_input: bool) ![]u8 {
    const alloc = runtime.alloc;
    const input = try runtime.user(alloc);
    defer types.freeUserTurn(alloc, input);
    var writer: std.Io.Writer.Allocating = .init(alloc);
    errdefer writer.deinit();
    try writer.writer.writeAll(if (reference_input) "{\"v\":2,\"recovery\":" else "{\"recovery\":");
    const write: *const @TypeOf(session_codec.writeRecoveryCheckpoint) = if (reference_input) session_codec.writeRecoveryContext else session_codec.writeRecoveryCheckpoint;
    try write(&writer.writer, .{
        .turn_id = try runtime.runtimeTurnId(),
        .user = input,
        .assistant_source = @constCast(""),
        .cause = .suspended,
        .action = .paused,
        .authority = .{ .provider = .gateway, .model = @constCast(try runtime.model()) },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 10,
        .consumed_provider_attempts = consumed,
        .outstanding_reservation = outstanding,
    });
    try writer.writer.writeAll(",\"preparations\":");
    try json(&writer.writer, preparations);
    try writer.writer.writeByte('}');
    return writer.toOwnedSlice();
}

test "journal witness provider metadata references an eight MiB input through checkpoint restore" {
    const alloc = std.testing.allocator;
    const text = try alloc.alloc(u8, 8 * 1024 * 1024);
    defer alloc.free(text);
    @memset(text, 'x');
    const input: types.UserTurn = .{ .text = text };
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "large-input");
    _ = try runtime.begin(input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    const request = try testExecutionContextVersion(&runtime, 0, true, &.{}, true);
    defer alloc.free(request);
    const decision = try testExecutionContextVersion(&runtime, 1, false, &.{}, true);
    defer alloc.free(decision);
    try std.testing.expect(request.len < 64 * 1024);
    try std.testing.expect(decision.len < 64 * 1024);
    try runtime.reserveRequest(key, request);
    _ = try runtime.recordDecision(.{ .content = "saved" }, &.{}, &.{}, key, true, decision, null);
    var result = try std.json.parseFromSlice(Value, alloc, "{\"ok\":true,\"stopReason\":\"stop\"}", .{});
    defer result.deinit();
    try runtime.finish(result.value, .{ .assistant = .{ .user = input, .assistant = @constCast("saved") } });
    var checkpoint = try state.checkpoint(alloc, runtime.sink);
    defer checkpoint.deinit(alloc);
    var restored: journal.State = .{};
    defer restored.deinit(alloc);
    var validator: TestValidator = .{ .alloc = alloc };
    try restoreTestEntry(&restored, &validator, checkpoint.entry);
    var next = sink.runtime(&restored, "large-input");
    try std.testing.expectEqual(Selection.completed, try next.begin(input, "model", 1, false));
    const history = try restoreHistory(alloc, &restored);
    defer types.freeHistoryTurnSlice(alloc, history);
    try std.testing.expectEqualStrings(text, history[0].assistant.user.text);
    try std.testing.expectEqualStrings("saved", history[0].assistant.assistant);
    try std.testing.expectEqual(@as(usize, 5), sink.count);
}

test "journal witness context metadata rejects mixed inputs and owns parser allocations" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "context-version");
    _ = try runtime.begin(test_input, "model", 1, false);
    const bytes = try testExecutionContextVersion(&runtime, 0, true, &.{}, true);
    defer alloc.free(bytes);
    var context = try std.json.parseFromSlice(Value, alloc, bytes, .{});
    defer context.deinit();
    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn run(a: Allocator, value: Value) !void {
            var metadata = try parseRecoveryMetadata(a, value);
            defer metadata.deinit(a);
            try std.testing.expectEqual(@as(usize, 0), metadata.user.text.len);
            try std.testing.expectEqual(@as(usize, 10), metadata.max_provider_attempts);
        }
    }.run, .{context.value});
    context.value.object.getPtr("v").?.* = .{ .integer = 3 };
    try std.testing.expectError(error.InvalidJournalRecord, parseRecoveryMetadata(alloc, context.value));
    context.value.object.getPtr("v").?.* = .{ .integer = 2 };
    context.value.object.getPtr("recovery").?.object.getPtr("version").?.* = .{ .integer = 1 };
    try std.testing.expectError(error.InvalidJournalRecord, parseRecoveryMetadata(alloc, context.value));
    context.value.object.getPtr("recovery").?.object.getPtr("version").?.* = .{ .integer = 2 };
    try context.value.object.getPtr("recovery").?.object.put(context.arena.allocator(), "user", .null);
    try std.testing.expectError(error.InvalidJournalRecord, parseRecoveryMetadata(alloc, context.value));
}

test "journal runtime records stable identities and exactly reconstructs selected decisions" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    try std.testing.expectEqual(Selection.new_turn, try runtime.begin(test_input, "provider/model", 912, false));
    var key = try runtime.generation();
    defer key.deinit(alloc);
    const calls = [_]types.ToolCall{
        .{ .id = "provider-first", .name = "write", .arguments_json = "{", .argument_integrity = .malformed_json, .provisional_id = "draft-call" },
        .{ .id = "provider-second", .name = "write", .arguments_json = "{\"path\":\"b\"}", .provider_result = "provider receipt", .provenance = .provider_executed },
    };
    const execution_context = try testExecutionContext(&runtime, 2, false, &.{ .{ .state = .ready }, .{ .state = .provider_executed } });
    defer alloc.free(execution_context);
    const step = try runtime.recordDecision(.{
        .content = "I will write both files",
        .generation_id = "provider-generation",
        .delivery_ambiguous = true,
        .usage = .{ .input_tokens = 78, .output_tokens = 25 },
        .provider_state_json = "[{\"type\":\"reasoning\"}]",
        .finish_reason = .tool_calls,
    }, &calls, &.{ .safe, .blocked }, key, false, execution_context, .{ .source = .{ .provider = .gateway, .model = "provider/model" }, .parts_json = "[]" });
    try std.testing.expectEqual(@as(usize, 0), step);
    var decision = try runtime.recordedDecision(alloc, step);
    defer decision.deinit();
    try std.testing.expectEqualStrings("provider-first", decision.calls[0].id);
    try std.testing.expectEqualStrings("{", decision.calls[0].arguments_json);
    try std.testing.expectEqual(types.ToolArgumentIntegrity.malformed_json, decision.calls[0].argument_integrity);
    try std.testing.expectEqualStrings("draft-call", decision.calls[0].provisional_id.?);
    try std.testing.expectEqual(types.ToolExecutionProvenance.provider_executed, decision.calls[1].provenance);
    try std.testing.expectEqualStrings("provider receipt", decision.calls[1].provider_result.?);
    try std.testing.expect(decision.calls[0].resolved_skill == null);
    try std.testing.expect(decision.completion.delivery_ambiguous);
    try std.testing.expectEqual(@as(?u64, 78), decision.completion.usage.input_tokens);
    try std.testing.expectEqualStrings("provider-generation", decision.completion.generation_id.?);
    try std.testing.expectEqualStrings(execution_context, decision.execution_context_json.?);
    const context = try runtime.context(step, 0, true);
    try std.testing.expectEqualStrings("durable-session:turn:1:message:1:call:1", context.callId);
    try std.testing.expectEqualStrings("request-a", context.requestId);
    try std.testing.expect(context.recovering);
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try std.testing.expectEqual(@as(u64, 912), try runtime.runtimeTurnId());
    const restored_user = try runtime.user(alloc);
    defer types.freeUserTurn(alloc, restored_user);
    try std.testing.expectEqualStrings(test_input.text, restored_user.text);
    try std.testing.expectEqualStrings("provider/model", try runtime.model());
    state.deinit(alloc);
    try std.testing.expectEqualStrings("provider-first", decision.calls[0].id);
    try std.testing.expectEqualStrings("provider receipt", decision.calls[1].provider_result.?);
    try std.testing.expectEqualStrings("I will write both files", decision.completion.content.?);
    try std.testing.expectEqualStrings("provider/model", decision.provider_replay.?.source.model);
}

test "journal runtime lost decision acknowledgement fences later boundaries" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    sink.fail = true;
    try std.testing.expectError(error.PersistenceUncertain, runtime.recordDecision(.{ .content = "done" }, &.{}, &.{}, key, true, null, null));
    try std.testing.expectEqual(@as(usize, 0), state.stepCount(0));
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try std.testing.expectError(error.PersistenceUncertain, runtime.generation());
    try std.testing.expectError(error.PersistenceUncertain, runtime.recordDecision(.{ .content = "done" }, &.{}, &.{}, key, true, null, null));
    try std.testing.expectEqual(@as(usize, 2), sink.count);
}

test "journal runtime restores original result before final decision and pure history" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    _ = try runtime.recordDecision(.{ .content = "write it" }, &.{.{ .id = "provider-call", .name = "write", .arguments_json = "{}" }}, &.{.safe}, key, false, null, null);
    const result: types.PersistedToolResult = .{
        .tool_call_id = @constCast("provider-call"),
        .tool_name = @constCast("write"),
        .status = .failure,
        .output = @constCast("known tool failure"),
        .output_bytes = 18,
        .stored_output_bytes = 18,
        .created_at_ms = 97,
    };
    try std.testing.expect(try runtime.recordedResult(alloc, 0, 0) == null);
    try runtime.recordResult(0, 0, result);
    var restored = (try runtime.recordedResult(alloc, 0, 0)).?;
    defer restored.deinit();
    try std.testing.expectEqual(types.PersistedToolStatus.failure, restored.result.status);
    try std.testing.expectEqualStrings("known tool failure", restored.result.output);
    try std.testing.expectEqual(@as(i64, 97), restored.result.created_at_ms);
    var final_key = try runtime.generation();
    defer final_key.deinit(alloc);
    _ = try runtime.recordDecision(.{ .content = "Could not write the file" }, &.{}, &.{}, final_key, true, null, null);
    const outcome = try std.json.parseFromSlice(Value, alloc, "{\"ok\":true,\"stopReason\":\"stop\"}", .{});
    defer outcome.deinit();
    try runtime.finish(outcome.value, .{ .assistant = .{ .user = test_input, .assistant = @constCast("Could not write the file") } });
    try std.testing.expectEqual(@as(usize, 5), sink.count);
    const history = try restoreHistory(alloc, &state);
    defer types.freeHistoryTurnSlice(alloc, history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expectEqualStrings("Could not write the file", history[0].assistant.assistant);
    var retry = sink.runtime(&state, "request-a");
    try std.testing.expectEqual(Selection.completed, try retry.begin(test_input, "other-model", 2, false));
    try std.testing.expectEqual(@as(usize, 5), sink.count);
    var changed = sink.runtime(&state, "request-a");
    try std.testing.expectError(error.RequestConflict, changed.begin(.{ .text = @constCast("different") }, "model", 2, false));
}

test "journal runtime pending request requires resume and changes only generation identity" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "original-model", 87, false);
    var first = try runtime.generation();
    defer first.deinit(alloc);
    var retry = sink.runtime(&state, "request-a");
    try std.testing.expectError(error.PendingTurnError, retry.begin(test_input, "model", 2, false));
    retry.creation_id = "second-runtime";
    try std.testing.expectEqual(Selection.pending, try retry.begin(test_input, "model", 2, true));
    var resumed = try retry.generation();
    defer resumed.deinit(alloc);
    try std.testing.expectEqualStrings(first.turnId, resumed.turnId);
    try std.testing.expectEqualStrings(first.messageId, resumed.messageId);
    try std.testing.expect(!std.mem.eql(u8, first.generationId, resumed.generationId));
    try std.testing.expectEqual(@as(u64, 87), try retry.runtimeTurnId());
    try std.testing.expectEqualStrings("original-model", try retry.model());
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    var unknown = sink.runtime(&state, "request-b");
    try std.testing.expectError(error.InvalidJournalTransition, unknown.begin(test_input, "model", 3, true));
}

test "journal runtime rebuilds settled prefix and preserves pending decision separately" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "original-model", 7, false);
    var first = try runtime.generation();
    defer first.deinit(alloc);
    _ = try runtime.recordDecision(.{ .content = "first step" }, &.{.{ .id = "call-1", .name = "write", .arguments_json = "{}" }}, &.{.safe}, first, false, null, .{
        .source = .{ .provider = .gateway, .model = "original-model" },
        .parts_json = "[]",
    });
    try std.testing.expectEqual(@as(?usize, 0), runtime.recoveryStep());
    var empty_prefix = try runtime.prefixExecution(alloc);
    defer empty_prefix.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_prefix.execution.tool_steps.len);
    try runtime.recordResult(0, 0, .{
        .tool_call_id = @constCast("call-1"),
        .tool_name = @constCast("write"),
        .status = .success,
        .output = @constCast("receipt"),
        .output_bytes = 7,
        .stored_output_bytes = 7,
    });
    try std.testing.expectEqual(@as(?usize, null), runtime.recoveryStep());
    var second = try runtime.generation();
    defer second.deinit(alloc);
    _ = try runtime.recordDecision(.{ .content = "continue after steering" }, &.{}, &.{}, second, false, null, null);
    try std.testing.expectEqual(journal.Pending.model, std.meta.activeTag(state.pending()));
    var third = try runtime.generation();
    defer third.deinit(alloc);
    _ = try runtime.recordDecision(.{ .content = "final answer" }, &.{}, &.{}, third, true, null, null);
    try std.testing.expectEqual(@as(?usize, 2), runtime.recoveryStep());
    var prefix = try runtime.prefixExecution(alloc);
    defer prefix.deinit();
    try std.testing.expectEqual(@as(usize, 2), prefix.execution.tool_steps.len);
    try std.testing.expectEqualStrings("first step", prefix.execution.tool_steps[0].assistant.?);
    try std.testing.expectEqualStrings("receipt", prefix.execution.tool_steps[0].tool_results[0].output);
    try std.testing.expectEqualStrings("call-1", prefix.execution.tool_steps[0].tool_calls[0].id);
    try std.testing.expectEqualStrings("original-model", prefix.execution.tool_steps[0].provider_replay.?.source.model);
    try std.testing.expectEqualStrings("continue after steering", prefix.execution.tool_steps[1].assistant.?);
    const count = sink.count;
    try validateRestoredState(alloc, &state);
    try std.testing.expectEqual(count, sink.count);
}

test "journal runtime preserves binary result bytes while exposing model-safe display text" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    _ = try runtime.recordDecision(.{}, &.{.{ .id = "call", .name = "read", .arguments_json = "{}" }}, &.{.safe}, key, false, null, null);
    try runtime.recordResult(0, 0, .{
        .tool_call_id = @constCast("call"),
        .tool_name = @constCast("read"),
        .status = .success,
        .output = @constCast("raw\xffbytes"),
        .output_bytes = 9,
        .stored_output_bytes = 9,
    });
    var result = (try runtime.recordedResult(alloc, 0, 0)).?;
    defer result.deinit();
    try std.testing.expectEqualStrings("raw\xffbytes", result.result.output);
    try std.testing.expectEqualStrings("binary or non-utf8 tool output omitted (9 bytes)", (try journal.field(state.toolResult(0, 0, 0).?, "content", .string)).string);
    try validateRestoredState(alloc, &state);
}

test "journal runtime reconstruction cleans up every allocation failure" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    const execution_context = try testExecutionContext(&runtime, 2, false, &.{});
    defer alloc.free(execution_context);
    _ = try runtime.recordDecision(.{ .content = "final response" }, &.{}, &.{}, key, true, execution_context, .{
        .source = .{ .provider = .gateway, .model = "model" },
        .parts_json = "[]",
    });
    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn check(a: Allocator, value: *Runtime) !void {
            const restored_user = try value.user(a);
            defer types.freeUserTurn(a, restored_user);
            var decision = try value.recordedDecision(a, 0);
            defer decision.deinit();
            var prefix = try value.prefixExecution(a);
            defer prefix.deinit();
            try validateRestoredState(a, value.state);
        }
    }.check, .{&runtime});
    try std.testing.expectEqual(@as(usize, 2), sink.count);
}

test "journal runtime rejects incomplete core payload after valid envelope replay" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    _ = try runtime.recordDecision(.{ .content = "done" }, &.{}, &.{}, key, true, null, null);
    var body = try std.json.parseFromSlice(Value, alloc, state.records.items[1].entry.bytes, .{});
    defer body.deinit();
    try std.testing.expect(body.value.object.swapRemove("providerReplay"));
    const bytes = try std.json.Stringify.valueAlloc(alloc, body.value, .{});
    defer alloc.free(bytes);
    const hash = @import("../../session/execution_journal_codec.zig").digest(2, .model_step, bytes);
    var restored: journal.State = .{};
    defer restored.deinit(alloc);
    const first = state.records.items[0].entry;
    try restored.restore(alloc, first.seq, @tagName(first.kind), first.bytes, &first.hash);
    try restored.restore(alloc, 2, "model_step", bytes, &hash);
    try std.testing.expectError(error.InvalidJournalRecord, validateRestoredState(alloc, &restored));
    try std.testing.expectEqual(@as(usize, 2), sink.count);
}

test "journal runtime abandonment before the first model preserves the user and terminal request" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 1, false);
    if (try runtime.abandon()) |abandoned| types.freeHistoryTurn(alloc, abandoned);
    try std.testing.expect(state.pending() == .idle);
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    if (try runtime.abandon()) |abandoned| types.freeHistoryTurn(alloc, abandoned);
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    const history = try restoreHistory(alloc, &state);
    defer types.freeHistoryTurnSlice(alloc, history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expect(history[0] == .interrupted);
    try std.testing.expectEqualStrings(test_input.text, history[0].interrupted.user.text);
    try std.testing.expect(history[0].interrupted.tool_call == null);
    var retry = sink.runtime(&state, "request-a");
    try std.testing.expectEqual(Selection.completed, try retry.begin(test_input, "model", 2, false));
    try std.testing.expectEqual(@as(usize, 2), sink.count);
}

test "journal witness maximum file arguments reserve an exact pending abandonment" {
    const alloc = std.testing.allocator;
    const content = try alloc.alloc(u8, 4 * 1024 * 1024);
    defer alloc.free(content);
    @memset(content, 'x');
    const arguments = try std.fmt.allocPrint(alloc, "{{\"path\":\"maximum.txt\",\"content\":\"{s}\"}}", .{content});
    defer alloc.free(arguments);
    for ([_]bool{ false, true }) |first_settled| {
        var state: journal.State = .{};
        defer state.deinit(alloc);
        var sink: TestSink = .{};
        var runtime = sink.runtime(&state, "large-file-request");
        _ = try runtime.begin(test_input, "model", 1, false);
        var key = try runtime.generation();
        defer key.deinit(alloc);
        _ = try runtime.recordDecision(.{}, &.{
            .{ .id = "small", .name = "write_file", .arguments_json = "{}" },
            .{ .id = "large", .name = "write_file", .arguments_json = arguments },
        }, &.{ .blocked, .blocked }, key, false, null, null);
        if (first_settled) try runtime.recordResult(0, 0, .{
            .tool_call_id = @constCast("small"),
            .tool_name = @constCast("write_file"),
            .status = .success,
            .output = @constCast("saved"),
            .output_bytes = 5,
            .stored_output_bytes = 5,
        });
        const reserved = try runtime.terminalBytes();
        try std.testing.expect(try runtime.admitToolResultLimit(2 * 1024 * 1024) >= 1024);
        const abandoned = (try runtime.abandon()).?;
        defer types.freeHistoryTurn(alloc, abandoned);
        const actual = state.records.items[state.records.items.len - 1].entry.bytes.len;
        try std.testing.expect(actual <= reserved);
        if (first_settled) {
            try std.testing.expect(actual > content.len);
            try std.testing.expectEqualStrings(arguments, abandoned.interrupted.tool_call.?.arguments_json);
        }
        try validateRestoredState(alloc, &state);
    }
}

test "journal runtime abandonment projects known results and uncertain call without skipped effects" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    _ = try runtime.recordDecision(.{ .content = "Selected three operations" }, &.{
        .{ .id = "provider-a", .name = "write", .arguments_json = "{\"path\":\"a\"}" },
        .{ .id = "provider-b", .name = "write", .arguments_json = "{\"path\":\"b\"}" },
        .{ .id = "provider-c", .name = "write", .arguments_json = "{\"path\":\"c\"}" },
    }, &.{ .safe, .blocked, .blocked }, key, false, null, .{
        .source = .{ .provider = .gateway, .model = "model" },
        .parts_json = "[{\"unsettled\":true}]",
    });
    try runtime.recordResult(0, 0, .{
        .tool_call_id = @constCast("provider-a"),
        .tool_name = @constCast("write"),
        .status = .success,
        .output = @constCast("original durable receipt"),
        .output_bytes = 24,
        .stored_output_bytes = 24,
    });
    var pending = (try pendingTool(alloc, &state)).?;
    defer pending.deinit();
    try std.testing.expectEqualStrings("durable-session:turn:1:message:1:call:2", pending.tool.callId);
    if (try runtime.abandon()) |abandoned| types.freeHistoryTurn(alloc, abandoned);
    try std.testing.expectEqual(@as(usize, 4), sink.count);
    const history = try restoreHistory(alloc, &state);
    defer types.freeHistoryTurnSlice(alloc, history);
    const turn = history[0].interrupted;
    try std.testing.expectEqualStrings("provider-b", turn.tool_call.?.id);
    try std.testing.expectEqualStrings("{\"path\":\"b\"}", turn.tool_call.?.arguments_json);
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 1), turn.execution.tool_steps[0].tool_calls.len);
    try std.testing.expectEqualStrings("original durable receipt", turn.execution.tool_steps[0].tool_results[0].output);
    try std.testing.expect(turn.execution.tool_steps[0].provider_replay == null);
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    try session.appendActiveContextHistoryChatMessages(arena.allocator(), &messages, history, 0);
    var receipt_seen = false;
    var original_user_seen = false;
    var pending_seen = false;
    for (messages.items) |message| {
        if (message.content) |content| {
            receipt_seen = receipt_seen or std.mem.eql(u8, content, "original durable receipt");
            original_user_seen = original_user_seen or std.mem.eql(u8, content, test_input.text);
        }
        for (message.tool_calls) |call| {
            pending_seen = pending_seen or std.mem.eql(u8, call.id, "provider-b");
            try std.testing.expect(!std.mem.eql(u8, call.id, "provider-c"));
        }
    }
    try std.testing.expect(receipt_seen and original_user_seen and pending_seen);
    try validateRestoredState(alloc, &state);
}

test "journal runtime malformed pending input remains exact through abandonment and checkpoint restore" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "{", "{\"duplicate\":1,\"duplicate\":2}" }) |arguments| {
        var state: journal.State = .{};
        defer state.deinit(alloc);
        var sink: TestSink = .{};
        var runtime = sink.runtime(&state, "request-a");
        _ = try runtime.begin(test_input, "model", 1, false);
        var key = try runtime.generation();
        defer key.deinit(alloc);
        _ = try runtime.recordDecision(.{ .content = "Original assistant prefix" }, &.{.{
            .id = "provider-malformed",
            .name = "effect",
            .arguments_json = arguments,
            .argument_integrity = .malformed_json,
        }}, &.{.blocked}, key, false, null, null);
        var pending = (try pendingTool(alloc, &state)).?;
        defer pending.deinit();
        try std.testing.expectEqualStrings(arguments, pending.tool.input.string);
        const encoded = try std.json.Stringify.valueAlloc(alloc, pending.tool, .{});
        defer alloc.free(encoded);
        const check = try std.json.parseFromSlice(Value, alloc, encoded, .{});
        defer check.deinit();
        try std.testing.expectEqualStrings(arguments, check.value.object.get("input").?.string);
        if (try runtime.abandon()) |abandoned| types.freeHistoryTurn(alloc, abandoned);
        var checkpoint = try state.checkpoint(alloc, runtime.sink);
        defer checkpoint.deinit(alloc);
        var restored: journal.State = .{};
        defer restored.deinit(alloc);
        try restored.restore(alloc, checkpoint.entry.seq, "checkpoint", checkpoint.entry.bytes, &checkpoint.entry.hash);
        const history = try restoreHistory(alloc, &restored);
        defer types.freeHistoryTurnSlice(alloc, history);
        const turn = history[0].interrupted;
        try std.testing.expectEqualStrings("Original assistant prefix", turn.assistant.?);
        try std.testing.expectEqualStrings(arguments, turn.tool_call.?.arguments_json);
        try std.testing.expectEqual(types.ToolArgumentIntegrity.malformed_json, turn.tool_call.?.argument_integrity);
        try std.testing.expectEqualStrings("provider-malformed", turn.tool_call.?.id);
        try validateRestoredState(alloc, &restored);
    }
}

test "journal runtime failed abandonment acknowledgement fences the owner and keeps pending state" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 1, false);
    sink.fail = true;
    try std.testing.expectError(error.PersistenceUncertain, runtime.abandon());
    try std.testing.expect(state.pending() == .model);
    try std.testing.expect(state.outcome(0) == null);
    try std.testing.expectError(error.PersistenceUncertain, runtime.abandon());
    try std.testing.expectEqual(@as(usize, 2), sink.count);
}

test "journal runtime pending input conversion owns values and cleans up allocation failures" {
    const alloc = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn check(a: Allocator) !void {
            const valid = try callInput(a, "{\"operation\":\"read\"}");
            defer valid.deinit();
            try std.testing.expectEqualStrings("read", valid.value.object.get("operation").?.string);
            const malformed = try callInput(a, "{\"unfinished\":");
            defer malformed.deinit();
            try std.testing.expectEqualStrings("{\"unfinished\":", malformed.value.string);
        }
    }.check, .{});
}

test "journal runtime bounds JSON hidden inside input strings before parsing" {
    const alloc = std.testing.allocator;
    const depth64 = "[" ** 64 ++ "0" ++ "]" ** 64;
    const depth65 = "[" ** 65 ++ "0" ++ "]" ** 65;
    const accepted = try callInput(alloc, depth64);
    defer accepted.deinit();
    try std.testing.expect(accepted.value == .array);
    try std.testing.expectError(error.InvalidJson, callInput(alloc, depth65));
    try std.testing.expectError(error.InvalidUtf8, callInput(alloc, "\xff"));
    const oversized = try alloc.alloc(u8, entry_codec.max_entry_bytes + 1);
    defer alloc.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.EntryTooLarge, callInput(alloc, oversized));

    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    try std.testing.expectError(error.InvalidJson, runtime.recordDecision(.{}, &.{.{ .id = "call", .name = "effect", .arguments_json = depth65 }}, &.{.blocked}, key, false, null, null));
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    _ = try runtime.recordDecision(.{}, &.{.{ .id = "call", .name = "effect", .arguments_json = "{}" }}, &.{.blocked}, key, false, null, null);
    var deep_record = try std.json.parseFromSlice(Value, alloc, state.records.items[1].entry.bytes, .{});
    defer deep_record.deinit();
    deep_record.value.object.getPtr("calls").?.array.items[0].object.getPtr("argumentsJson").?.* = .{ .string = depth65 };
    const deep_bytes = try std.json.Stringify.valueAlloc(alloc, deep_record.value, .{});
    defer alloc.free(deep_bytes);
    var deep_state: journal.State = .{};
    defer deep_state.deinit(alloc);
    const start_entry = state.records.items[0].entry;
    try deep_state.restore(alloc, 1, "turn_start", start_entry.bytes, &start_entry.hash);
    const deep_hash = entry_codec.digest(2, .model_step, deep_bytes);
    try deep_state.restore(alloc, 2, "model_step", deep_bytes, &deep_hash);
    try std.testing.expectError(error.InvalidJson, pendingTool(alloc, &deep_state));
    try std.testing.expectError(error.InvalidJson, validateRestoredState(alloc, &deep_state));

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    const input_hash = journal.inputHash(depth65);
    try json(&encoded.writer, .{
        .v = 1,
        .kind = "turn_start",
        .namespace = "session",
        .turnId = "turn",
        .userMessageId = "user",
        .requestId = "request",
        .inputHash = &input_hash,
        .model = "model",
        .runtimeTurnId = "1",
        .inputJson = depth65,
    });
    var malformed: journal.State = .{};
    defer malformed.deinit(alloc);
    const bytes = encoded.written();
    const hash = entry_codec.digest(1, .turn_start, bytes);
    try malformed.restore(alloc, 1, "turn_start", bytes, &hash);
    try std.testing.expectError(error.InvalidJson, validateRestoredState(alloc, &malformed));
}

test "journal runtime request reservations preserve context without creating decisions" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 23, false);
    try std.testing.expect(try runtime.latestContext() == null);
    var first = try runtime.generation();
    defer first.deinit(alloc);
    const first_context = try testExecutionContext(&runtime, 0, true, &.{});
    defer alloc.free(first_context);
    try runtime.reserveRequest(first, first_context);
    try std.testing.expectEqual(@as(usize, 0), state.stepCount(0));
    const request = state.requestForCurrentStep(0).?;
    try std.testing.expect(try journal.isRequest(request));
    try std.testing.expect(request.object.get("supersedesGenerationId").? == .null);
    try std.testing.expect(!request.object.contains("completion"));
    try std.testing.expect(!request.object.contains("calls"));
    try std.testing.expect(!request.object.contains("final"));
    var prefix = try runtime.prefixExecution(alloc);
    defer prefix.deinit();
    try std.testing.expectEqual(@as(usize, 0), prefix.execution.tool_steps.len);

    var restored: journal.State = .{};
    defer restored.deinit(alloc);
    for (state.records.items) |record| {
        const entry = record.entry;
        try restored.restore(alloc, entry.seq, @tagName(entry.kind), entry.bytes, &entry.hash);
    }
    try validateRestoredState(alloc, &restored);
    var resumed_sink: TestSink = .{ .count = @intCast(restored.last_seq) };
    var resumed = resumed_sink.runtime(&restored, "request-a");
    resumed.creation_id = "new-owner";
    try std.testing.expectEqual(Selection.pending, try resumed.begin(test_input, "model", 99, true));
    const prior = try journal.object((try resumed.latestContext()).?, "recovery");
    try std.testing.expectEqual(@as(i64, 0), (try journal.field(prior, "consumed_provider_attempts", .integer)).integer);
    try std.testing.expect(try journal.boolean(prior, "outstanding_reservation"));
    try std.testing.expectEqualStrings("model", try journal.string(try journal.object(prior, "authority"), "model"));

    var second = try resumed.generation();
    defer second.deinit(alloc);
    const second_context = try testExecutionContext(&resumed, 1, true, &.{});
    defer alloc.free(second_context);
    try resumed.reserveRequest(second, second_context);
    const retry = restored.requestForCurrentStep(0).?;
    try std.testing.expectEqualStrings(first.messageId, second.messageId);
    try std.testing.expect(!std.mem.eql(u8, first.generationId, second.generationId));
    try std.testing.expectEqualStrings(first.generationId, try journal.string(retry, "supersedesGenerationId"));
    try std.testing.expectEqual(@as(usize, 0), restored.stepCount(0));
    const decision_context = try testExecutionContext(&resumed, 2, false, &.{});
    defer alloc.free(decision_context);
    try std.testing.expectError(error.JournalConflict, resumed.recordDecision(.{ .content = "wrong attempt" }, &.{}, &.{}, first, false, decision_context, null));
    _ = try resumed.recordDecision(.{ .content = "accepted model output" }, &.{}, &.{}, second, false, decision_context, null);
    try std.testing.expectEqual(@as(usize, 1), restored.stepCount(0));
    try std.testing.expect(restored.requestForCurrentStep(0) == null);
    const latest = try journal.object((try resumed.latestContext()).?, "recovery");
    try std.testing.expectEqual(@as(i64, 2), (try journal.field(latest, "consumed_provider_attempts", .integer)).integer);
    try std.testing.expect(!try journal.boolean(latest, "outstanding_reservation"));
    var selected = try resumed.recordedDecision(alloc, 0);
    defer selected.deinit();
    try std.testing.expectEqualStrings("accepted model output", selected.completion.content.?);
    try validateRestoredState(alloc, &restored);
}

test "journal runtime lost request acknowledgement fences admission before any decision" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    const context = try testExecutionContext(&runtime, 0, true, &.{});
    defer alloc.free(context);
    sink.fail = true;
    try std.testing.expectError(error.PersistenceUncertain, runtime.reserveRequest(key, context));
    try std.testing.expectEqual(@as(usize, 2), sink.count);
    try std.testing.expectEqual(@as(usize, 0), state.stepCount(0));
    try std.testing.expect(state.requestForCurrentStep(0) == null);
    try std.testing.expectError(error.PersistenceUncertain, runtime.reserveRequest(key, context));
    try std.testing.expectError(error.PersistenceUncertain, runtime.generation());
    try std.testing.expectEqual(@as(usize, 2), sink.count);
}

test "journal runtime validates request and settled decision checkpoint shapes" {
    const alloc = std.testing.allocator;
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "request-a");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    const request_context = try testExecutionContext(&runtime, 0, true, &.{});
    defer alloc.free(request_context);
    const decision_context = try testExecutionContext(&runtime, 1, false, &.{});
    defer alloc.free(decision_context);
    try std.testing.expectError(error.InvalidJournalRecord, runtime.reserveRequest(key, decision_context));
    try std.testing.expectError(error.InvalidJournalRecord, runtime.reserveRequest(key, "{\"attempts\":1}"));
    try std.testing.expectError(error.InvalidJournalRecord, runtime.recordDecision(.{}, &.{}, &.{}, key, true, request_context, null));
    try std.testing.expectEqual(@as(usize, 1), sink.count);
    try runtime.reserveRequest(key, request_context);
    const bytes = state.records.items[1].entry.bytes;
    var body = try std.json.parseFromSlice(Value, alloc, bytes, .{});
    defer body.deinit();
    body.value.object.getPtr("executionContext").?.object.getPtr("recovery").?.object.getPtr("outstanding_reservation").?.* = .{ .bool = false };
    const malformed = try std.json.Stringify.valueAlloc(alloc, body.value, .{});
    defer alloc.free(malformed);
    var restored: journal.State = .{};
    defer restored.deinit(alloc);
    const start = state.records.items[0].entry;
    try restored.restore(alloc, start.seq, "turn_start", start.bytes, &start.hash);
    const hash = entry_codec.digest(2, .model_step, malformed);
    try restored.restore(alloc, 2, "model_step", malformed, &hash);
    try std.testing.expectError(error.InvalidJournalRecord, validateRestoredState(alloc, &restored));
}

test "journal runtime abandonment allocates returned cache entry before durable acknowledgement" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    const Barrier = struct {
        allocator: *std.testing.FailingAllocator,
        fn append(raw: *anyopaque, entry: journal.Entry) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (entry.kind == .turn_end) {
                self.allocator.fail_index = self.allocator.alloc_index;
                self.allocator.resize_fail_index = self.allocator.resize_index;
            }
        }
    };
    var barrier: Barrier = .{ .allocator = &failing };
    var state: journal.State = .{};
    defer state.deinit(alloc);
    var runtime: Runtime = .{
        .state = &state,
        .sink = .{ .context = &barrier, .append_fn = Barrier.append },
        .alloc = alloc,
        .namespace = "cache-session",
        .creation_id = "cache-owner",
        .request_id = "request-a",
    };
    _ = try runtime.begin(test_input, "model", 1, false);
    var cache: std.ArrayList(types.HistoryTurn) = .empty;
    defer {
        for (cache.items) |turn| types.freeHistoryTurn(alloc, turn);
        cache.deinit(alloc);
    }
    try cache.ensureUnusedCapacity(alloc, 1);
    const history = (try runtime.abandon()).?;
    cache.appendAssumeCapacity(history);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(state.pending() == .idle);
    try std.testing.expectEqualStrings(test_input.text, cache.items[0].interrupted.user.text);
    try std.testing.expectError(error.OutOfMemory, alloc.alloc(u8, 1));
}

fn completedTestJournal(alloc: Allocator) !journal.State {
    var state: journal.State = .{};
    errdefer state.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&state, "pre-adoption");
    runtime.alloc = alloc;
    _ = try runtime.begin(test_input, "model", 7, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    const request_context = try testExecutionContext(&runtime, 0, true, &.{});
    defer alloc.free(request_context);
    try runtime.reserveRequest(key, request_context);
    const decision_context = try testExecutionContext(&runtime, 1, false, &.{.{ .state = .ready }});
    defer alloc.free(decision_context);
    _ = try runtime.recordDecision(.{ .content = "Selected effect" }, &.{.{ .id = "provider-call", .name = "effect", .arguments_json = "{\"value\":1}" }}, &.{.safe}, key, false, decision_context, null);
    try runtime.recordResult(0, 0, .{
        .tool_call_id = @constCast("provider-call"),
        .tool_name = @constCast("effect"),
        .status = .success,
        .output = @constCast("original receipt"),
        .output_bytes = 16,
        .stored_output_bytes = 16,
        .created_at_ms = 91,
    });
    var final_key = try runtime.generation();
    defer final_key.deinit(alloc);
    const next_context = try testExecutionContext(&runtime, 1, true, &.{});
    defer alloc.free(next_context);
    try runtime.reserveRequest(final_key, next_context);
    const final_context = try testExecutionContext(&runtime, 2, false, &.{});
    defer alloc.free(final_context);
    _ = try runtime.recordDecision(.{ .content = "Final answer" }, &.{}, &.{}, final_key, true, final_context, null);
    const result = try std.json.parseFromSlice(Value, alloc, "{\"ok\":true,\"stopReason\":\"stop\",\"usage\":{\"input_tokens\":17}}", .{});
    defer result.deinit();
    var prefix = try runtime.prefixExecution(alloc);
    defer prefix.deinit();
    try runtime.finish(result.value, .{ .assistant = .{
        .user = test_input,
        .assistant = @constCast("Final answer"),
        .execution = prefix.execution,
    } });
    return state;
}

test "journal runtime pre-adoption validation rejects late DTO fields without advancing state" {
    const alloc = std.testing.allocator;
    var source = try completedTestJournal(alloc);
    defer source.deinit(alloc);
    for ([_]usize{ 0, 1, 2, 3, 6 }) |index| {
        const candidate = source.records.items[index].entry;
        var body = try std.json.parseFromSlice(Value, alloc, candidate.bytes, .{});
        defer body.deinit();
        switch (index) {
            0 => body.value.object.getPtr("model").?.* = .{ .string = " invalid model " },
            1 => body.value.object.getPtr("executionContext").?.object.getPtr("recovery").?.object.getPtr("outstanding_reservation").?.* = .{ .string = "invalid" },
            2 => body.value.object.getPtr("providerReplay").?.* = .{ .integer = 17 },
            3 => body.value.object.getPtr("persisted").?.object.getPtr("created_at_ms").?.* = .{ .bool = true },
            6 => body.value.object.getPtr("history").?.object.getPtr("provider_replay").?.* = .{ .bool = true },
            else => unreachable,
        }
        const bytes = try std.json.Stringify.valueAlloc(alloc, body.value, .{});
        defer alloc.free(bytes);
        const hash = entry_codec.digest(candidate.seq, candidate.kind, bytes);
        var state: journal.State = .{};
        defer state.deinit(alloc);
        var validator: TestValidator = .{ .alloc = alloc };
        for (source.records.items[0..index]) |entry| try restoreTestEntry(&state, &validator, entry.entry);
        const before_seq = state.last_seq;
        const before_hash = state.last_hash;
        const before_calls = validator.calls;
        if (state.restoreValidated(alloc, candidate.seq, @tagName(candidate.kind), bytes, &hash, validator.interface())) |_| {
            return error.AcceptedMalformedJournalPayload;
        } else |err| {
            try std.testing.expect(err != error.OutOfMemory);
        }
        try std.testing.expectEqual(before_calls + 1, validator.calls);
        try std.testing.expectEqual(before_seq, state.last_seq);
        try std.testing.expectEqualSlices(u8, &before_hash, &state.last_hash);
        try std.testing.expectEqual(index, state.records.items.len);
        try std.testing.expect(!state.blocked);
        for (source.records.items[0..index], state.records.items) |expected, actual| try std.testing.expectEqualSlices(u8, expected.entry.bytes, actual.entry.bytes);
        try restoreTestEntry(&state, &validator, candidate);
        try std.testing.expectEqual(candidate.seq, state.last_seq);
    }
}

test "journal runtime validated restore preserves acknowledged content across every allocation failure" {
    const alloc = std.testing.allocator;
    var source = try completedTestJournal(alloc);
    defer source.deinit(alloc);
    try std.testing.checkAllAllocationFailures(alloc, struct {
        fn check(a: Allocator, source_state: *const journal.State) !void {
            var state: journal.State = .{};
            defer state.deinit(a);
            var validator: TestValidator = .{ .alloc = a };
            for (source_state.records.items, 0..) |record, index| {
                const before_seq = state.last_seq;
                const before_hash = state.last_hash;
                const before_turns = state.turns.items.len;
                const before_requests = state.requests.count();
                restoreTestEntry(&state, &validator, record.entry) catch |err| {
                    try std.testing.expectEqual(before_seq, state.last_seq);
                    try std.testing.expectEqualSlices(u8, &before_hash, &state.last_hash);
                    try std.testing.expectEqual(before_turns, state.turns.items.len);
                    try std.testing.expectEqual(before_requests, state.requests.count());
                    try std.testing.expectEqual(index, state.records.items.len);
                    try std.testing.expect(!state.blocked);
                    for (source_state.records.items[0..index], state.records.items) |expected, actual| try std.testing.expectEqualSlices(u8, expected.entry.bytes, actual.entry.bytes);
                    return err;
                };
            }
            try std.testing.expect(state.pending() == .idle);
            try std.testing.expect(state.outcome(0) != null);
        }
    }.check, .{&source});
}

test "journal runtime end validation keeps original malformed pending evidence" {
    const alloc = std.testing.allocator;
    var source: journal.State = .{};
    defer source.deinit(alloc);
    var sink: TestSink = .{};
    var runtime = sink.runtime(&source, "pending-evidence");
    _ = try runtime.begin(test_input, "model", 1, false);
    var key = try runtime.generation();
    defer key.deinit(alloc);
    _ = try runtime.recordDecision(.{ .content = "Original decision" }, &.{.{
        .id = "provider-call",
        .name = "effect",
        .arguments_json = "{",
        .argument_integrity = .malformed_json,
    }}, &.{.blocked}, key, false, null, null);
    const abandoned = (try runtime.abandon()).?;
    defer types.freeHistoryTurn(alloc, abandoned);
    const candidate = source.records.getLast().entry;
    for ([_]bool{ false, true }) |alter_history| {
        var body = try std.json.parseFromSlice(Value, alloc, candidate.bytes, .{});
        defer body.deinit();
        if (alter_history) {
            body.value.object.getPtr("history").?.object.getPtr("tool_call").?.object.getPtr("arguments_json").?.* = .{ .string = "{}" };
        } else {
            body.value.object.getPtr("result").?.object.getPtr("pendingTool").?.object.getPtr("input").?.* = .{ .string = "{}" };
        }
        const bytes = try std.json.Stringify.valueAlloc(alloc, body.value, .{});
        defer alloc.free(bytes);
        const hash = entry_codec.digest(candidate.seq, candidate.kind, bytes);
        var state: journal.State = .{};
        defer state.deinit(alloc);
        var validator: TestValidator = .{ .alloc = alloc };
        for (source.records.items[0..2]) |entry| try restoreTestEntry(&state, &validator, entry.entry);
        const before_hash = state.last_hash;
        try std.testing.expectError(error.JournalConflict, state.restoreValidated(alloc, candidate.seq, "turn_end", bytes, &hash, validator.interface()));
        try std.testing.expectEqual(@as(u64, 2), state.last_seq);
        try std.testing.expectEqualSlices(u8, &before_hash, &state.last_hash);
        try std.testing.expect(state.pending() == .tool);
        try restoreTestEntry(&state, &validator, candidate);
        const history = try restoreHistory(alloc, &state);
        defer types.freeHistoryTurnSlice(alloc, history);
        try std.testing.expectEqualStrings("{", history[0].interrupted.tool_call.?.arguments_json);
        try std.testing.expectEqual(types.ToolArgumentIntegrity.malformed_json, history[0].interrupted.tool_call.?.argument_integrity);
    }
}

test "journal runtime pending input comparison accepts exact numeric values without rounding" {
    try std.testing.expect(jsonValueEqual(.{ .integer = 1 }, .{ .float = 1.0 }));
    try std.testing.expect(jsonValueEqual(.{ .float = -0.0 }, .{ .integer = 0 }));
    try std.testing.expect(!jsonValueEqual(.{ .integer = 9_007_199_254_740_993 }, .{ .float = 9_007_199_254_740_992.0 }));
    try std.testing.expect(!jsonValueEqual(.{ .integer = std.math.maxInt(i64) }, .{ .float = @floatFromInt(std.math.maxInt(i64)) }));
    try std.testing.expect(!jsonValueEqual(.{ .integer = 1 }, .{ .float = 1.25 }));
}

test "journal runtime preparation metadata is validated before decision adoption" {
    const alloc = std.testing.allocator;
    var source = try completedTestJournal(alloc);
    defer source.deinit(alloc);
    const candidate = source.records.items[2].entry;
    for (0..4) |mutation| {
        var body = try std.json.parseFromSlice(Value, alloc, candidate.bytes, .{});
        defer body.deinit();
        const preparations = body.value.object.getPtr("executionContext").?.object.getPtr("preparations").?;
        switch (mutation) {
            0 => preparations.array.items[0].object.getPtr("state").?.* = .{ .string = "blocked" },
            1 => preparations.array.items[0].object.getPtr("state").?.* = .{ .string = "provider_executed" },
            2 => preparations.array.items[0].object.getPtr("modelOutput").?.* = .{ .string = "unexpected stored output" },
            3 => preparations.array.items = preparations.array.items[0..0],
            else => unreachable,
        }
        const bytes = try std.json.Stringify.valueAlloc(alloc, body.value, .{});
        defer alloc.free(bytes);
        const hash = entry_codec.digest(candidate.seq, candidate.kind, bytes);
        var state: journal.State = .{};
        defer state.deinit(alloc);
        var validator: TestValidator = .{ .alloc = alloc };
        for (source.records.items[0..2]) |entry| try restoreTestEntry(&state, &validator, entry.entry);
        const before_hash = state.last_hash;
        try std.testing.expectError(error.InvalidJournalRecord, state.restoreValidated(alloc, candidate.seq, "model_step", bytes, &hash, validator.interface()));
        try std.testing.expectEqual(@as(usize, 3), validator.calls);
        try std.testing.expectEqual(@as(u64, 2), state.last_seq);
        try std.testing.expectEqualSlices(u8, &before_hash, &state.last_hash);
        try std.testing.expectEqual(@as(usize, 0), state.stepCount(0));
        try restoreTestEntry(&state, &validator, candidate);
        try std.testing.expectEqual(@as(usize, 1), state.stepCount(0));
    }
}
