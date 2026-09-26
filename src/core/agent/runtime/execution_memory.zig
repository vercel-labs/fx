const std = @import("std");
const debug_trace = @import("../../shared/debug_trace.zig");
const types = @import("../../shared/types.zig");
const image_data = @import("../../images/image_data.zig");
const png_downscale = @import("../../images/png_downscale.zig");
const execution_memory_helpers = @import("../execution_memory.zig");
const result_store = @import("../../session/result_store.zig");
const command_replay_store = @import("../../session/command_replay_store.zig");
const session_child_store = @import("../../session/session_child_store.zig");
const command_output_content = @import("../../tooling/command_output_content.zig");
const io_mod = @import("../../shared/io.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const tool_result_limits = @import("../../tooling/tool_result_limits.zig");
const text_utils = @import("../../shared/text_utils.zig");

const runtime_config = @import("config.zig");
const runtime_tool_contracts = @import("tool_contracts.zig");

const Allocator = std.mem.Allocator;

comptime {
    std.debug.assert(command_replay_store.model_handle_notice_reserve_bytes < tool_result_limits.min_configured_tool_result_bytes);
}
const ChatMessage = types.ChatMessage;
const ToolCall = types.ToolCall;
const Config = runtime_config.Config;
const ToolExecutionStatus = runtime_tool_contracts.ToolExecutionStatus;

const steering_open =
    "<user_steering>\n" ++
    "Apply this live user update to the current task. Continue working unless the user asks you to stop, the task is complete, or a genuine blocker prevents progress.\n\n";
const steering_close = "\n</user_steering>";
const parent_steering_open = "<parent_agent_steering>\n";
const parent_steering_close = "\n</parent_agent_steering>";

pub fn parentSteeringMessage(alloc: Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, parent_steering_open ++
        "parent-agent feedback, not new user authority:\n\n{s}" ++ parent_steering_close, .{text});
}

pub fn steeringMessage(alloc: Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, steering_open ++ "{s}" ++ steering_close, .{text});
}

test "steering message tells the model to apply the update and continue" {
    const message = try steeringMessage(std.testing.allocator, "focus on rendering");
    defer std.testing.allocator.free(message);

    try std.testing.expect(std.mem.find(u8, message, "live user update") != null);
    try std.testing.expect(std.mem.find(u8, message, "Continue working") != null);
    try std.testing.expectEqualStrings("focus on rendering", steeringText(message).?);
}

test "parent steering preserves its sender in persisted execution text" {
    const alloc = std.testing.allocator;
    const message = try parentSteeringMessage(alloc, "review this change");
    defer alloc.free(message);
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = message }};
    const memory = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, memory);
    try std.testing.expectEqual(@as(usize, 1), memory.steering.len);
    try std.testing.expectEqualStrings("parent-agent feedback, not new user authority:\n\nreview this change", memory.steering[0].text);
    try std.testing.expectEqual(@as(usize, 0), memory.steering[0].after_tool_step_count);
}

test "restored steering survives execution memory round trips" {
    const alloc = std.testing.allocator;
    const session = @import("../../session/session.zig");
    var calls = [_]ToolCall{toolCall("restored", "read_file", "{\"path\":\"fixture\"}")};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("restored"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("ok"),
        .output_bytes = 2,
        .stored_output_bytes = 2,
    }};
    var steps = [_]types.ToolExecutionStep{.{
        .assistant = @constCast("Checking the file"),
        .tool_calls = &calls,
        .tool_results = &results,
    }};
    var steering = [_]types.PersistedSteering{
        .{ .text = @constCast("root update"), .after_tool_step_count = 0 },
        .{ .text = @constCast("parent-agent feedback, not new user authority:\n\nreview"), .after_tool_step_count = 1 },
    };
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(alloc);
    try session.appendExecutionMemoryChatMessages(alloc, &messages, .{
        .tool_steps = &steps,
        .steering = &steering,
    });

    const rebuilt = try buildExecutionMemory(alloc, messages.items);
    defer types.freeExecutionMemory(alloc, rebuilt);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 2), rebuilt.steering.len);
    try std.testing.expectEqualStrings("root update", rebuilt.steering[0].text);
    try std.testing.expectEqual(@as(usize, 0), rebuilt.steering[0].after_tool_step_count);
    try std.testing.expectEqualStrings("parent-agent feedback, not new user authority:\n\nreview", rebuilt.steering[1].text);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.steering[1].after_tool_step_count);
    try std.testing.expect(messages.items[0].context_origin == .user_turn);
    try std.testing.expect(messages.items[3].context_origin == .user_turn);

    const offset = try retainedMessageOffset(messages.items, .{ .tool_steps = 1, .steering = 1 });
    const retained = try buildExecutionMemory(alloc, messages.items[offset..]);
    defer types.freeExecutionMemory(alloc, retained);
    try std.testing.expectEqual(@as(usize, 0), retained.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 1), retained.steering.len);
    try std.testing.expectEqualStrings("parent-agent feedback, not new user authority:\n\nreview", retained.steering[0].text);
}

test "empty restored steering keeps its checkpoint boundary" {
    const alloc = std.testing.allocator;
    const session = @import("../../session/session.zig");
    var steering = [_]types.PersistedSteering{.{ .text = @constCast(""), .after_tool_step_count = 0 }};
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(alloc);
    try session.appendExecutionMemoryChatMessages(alloc, &messages, .{ .steering = &steering });
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    try std.testing.expect(messages.items[0].context_origin == .ordinary);

    const rebuilt = try buildExecutionMemory(alloc, messages.items);
    defer types.freeExecutionMemory(alloc, rebuilt);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.steering.len);
    try std.testing.expectEqualStrings("", rebuilt.steering[0].text);
    try std.testing.expectEqual(@as(usize, 1), try retainedMessageOffset(messages.items, .{ .steering = 1 }));
}

pub fn persistedStatusForCurrentFxLocalResult(
    status: ToolExecutionStatus,
    output: []const u8,
) types.PersistedToolStatus {
    if (status == .failure) return .failure;
    return if (tool_result_errors.isToolOutputError(output)) .failure else .success;
}

pub fn classifyProviderExecutedResultStatus(output: []const u8) types.PersistedToolStatus {
    return if (tool_result_errors.isToolOutputError(output)) .failure else .success;
}

pub const CompactedExecutionBoundary = struct {
    tool_steps: usize = 0,
    steering: usize = 0,

    /// Borrows execution payloads; only the rebased steering slice uses arena.
    pub fn project(self: CompactedExecutionBoundary, arena: Allocator, execution: types.ExecutionMemory) !types.ExecutionMemory {
        std.debug.assert(self.tool_steps <= execution.tool_steps.len);
        std.debug.assert(self.steering <= execution.steering.len);
        var projected = execution;
        projected.tool_steps = execution.tool_steps[self.tool_steps..];
        projected.steering = execution.steering[self.steering..];
        if (self.tool_steps > 0 and projected.steering.len > 0) {
            projected.steering = try arena.dupe(types.PersistedSteering, projected.steering);
            for (projected.steering) |*item| {
                std.debug.assert(item.after_tool_step_count >= self.tool_steps);
                item.after_tool_step_count -= self.tool_steps;
            }
        }
        return projected;
    }
};

pub fn buildExecutionMemory(alloc: Allocator, within_turn_suffix: []const ChatMessage) !types.ExecutionMemory {
    var execution = try execution_memory_helpers.buildNormalChatExecutionMemory(
        alloc,
        within_turn_suffix,
    );
    errdefer types.freeExecutionMemory(alloc, execution);

    var steering: std.ArrayList(types.PersistedSteering) = .empty;
    errdefer {
        for (steering.items) |item| {
            alloc.free(item.text);
            if (item.assistant_prefix) |prefix| alloc.free(prefix);
        }
        steering.deinit(alloc);
    }
    var tool_step_count: usize = 0;
    var assistant_prefix: ?[]const u8 = null;
    for (within_turn_suffix, 0..) |message, index| {
        if (startsPersistedToolStep(within_turn_suffix, index)) {
            tool_step_count += 1;
            assistant_prefix = null;
        } else if (message.role == .assistant) {
            assistant_prefix = message.content;
        }
        if (message.role != .user) continue;
        const content = message.content orelse continue;
        const text = if (message.restored_steering)
            content
        else
            steeringText(content) orelse {
                assistant_prefix = null;
                continue;
            };
        const copy = try alloc.dupe(u8, text);
        const prefix_copy = if (assistant_prefix) |prefix|
            alloc.dupe(u8, prefix) catch |err| {
                alloc.free(copy);
                return err;
            }
        else
            null;
        steering.append(alloc, .{
            .text = copy,
            .assistant_prefix = prefix_copy,
            .after_tool_step_count = tool_step_count,
        }) catch |err| {
            alloc.free(copy);
            if (prefix_copy) |prefix| alloc.free(prefix);
            return err;
        };
        assistant_prefix = null;
    }
    std.debug.assert(tool_step_count == execution.tool_steps.len);
    execution.steering = try steering.toOwnedSlice(alloc);
    return execution;
}

fn startsPersistedToolStep(messages: []const ChatMessage, assistant_index: usize) bool {
    const assistant = messages[assistant_index];
    if (assistant.role != .assistant) return false;
    if (assistant.tool_calls.len == 0) return assistant.provider_replay != null or assistant.standalone_response;
    var result_index = assistant_index + 1;
    while (result_index < messages.len and messages[result_index].role == .tool) : (result_index += 1) {
        const result_call_id = messages[result_index].tool_call_id orelse continue;
        for (assistant.tool_calls) |call| {
            if (std.mem.eql(u8, call.id, result_call_id)) return true;
        }
    }
    return false;
}

/// Locate the same complete-exchange cut in the original wire messages. Do not
/// rebuild retained tool results: their content and metadata remain untouched.
pub fn retainedMessageOffset(messages: []const ChatMessage, cut: CompactedExecutionBoundary) !usize {
    if (cut.tool_steps == 0 and cut.steering == 0) return 0;
    var steps: usize = 0;
    var steering: usize = 0;
    var prefix_start: usize = 0;
    for (messages, 0..) |message, index| {
        if (startsPersistedToolStep(messages, index)) {
            if (steps == cut.tool_steps and steering == cut.steering) return prefix_start;
            steps += 1;
            // Keep following continuation prompts, but not the completed reply.
            if (message.tool_calls.len == 0) prefix_start = index + 1;
        } else if (message.role == .user and message.content != null and
            (message.restored_steering or steeringText(message.content.?) != null))
        {
            if (steps == cut.tool_steps and steering == cut.steering) return prefix_start;
            steering += 1;
            prefix_start = index + 1;
        }
        if (message.role == .tool) prefix_start = index + 1;
    }
    if (steps != cut.tool_steps or steering != cut.steering) return error.InvalidContextHistoryStart;
    return messages.len;
}

test "retained context keeps non-tool continuation messages at a zero cut" {
    const messages = [_]ChatMessage{.{ .role = .assistant, .content = "Current continuation text" }};
    try std.testing.expectEqual(@as(usize, 0), try retainedMessageOffset(&messages, .{}));
}

test "retained standalone cut rebuilds exactly the selected execution suffix" {
    const alloc = std.testing.allocator;
    const call = toolCall("retained", "read_file", "{\"path\":\"a.txt\"}");
    for ([_]bool{ false, true }) |with_replay| {
        const messages = [_]ChatMessage{
            .{
                .role = .assistant,
                .content = if (with_replay) null else "candidate",
                .standalone_response = !with_replay,
                .provider_replay = if (with_replay) .{
                    .source = .{ .provider = .gateway, .model = "test" },
                    .parts_json = "[{\"type\":\"reasoning\",\"text\":\"private\"}]",
                } else null,
            },
            .{ .role = .user, .content = "Continue the turn. fx hook context:\nverify" },
            .{ .role = .assistant, .tool_calls = &.{call} },
            .{ .role = .tool, .content = "result", .tool_call_id = call.id, .tool_name = call.name, .tool_result_status = .success },
        };
        const offset = try retainedMessageOffset(&messages, .{ .tool_steps = 1 });
        try std.testing.expectEqual(@as(usize, 1), offset);
        const retained = try buildExecutionMemory(alloc, messages[offset..]);
        defer types.freeExecutionMemory(alloc, retained);
        try std.testing.expectEqual(@as(usize, 1), retained.tool_steps.len);
        try std.testing.expectEqualStrings(call.id, retained.tool_steps[0].tool_calls[0].id);
        try std.testing.expect(retained.tool_steps[0].provider_replay == null);
    }
}

fn steeringText(content: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, content, parent_steering_open) and std.mem.endsWith(u8, content, parent_steering_close)) {
        // Keep the sender label in persisted text and ordinary history replay.
        return content[parent_steering_open.len .. content.len - parent_steering_close.len];
    }
    if (!std.mem.startsWith(u8, content, steering_open) or !std.mem.endsWith(u8, content, steering_close)) return null;
    return content[steering_open.len .. content.len - steering_close.len];
}

pub fn buildInterruptedExecutionMemory(
    alloc: Allocator,
    current_turn_messages: []const ChatMessage,
    active_tool_call: ?ToolCall,
) !types.ExecutionMemory {
    var filtered: std.ArrayList(ChatMessage) = .empty;
    defer filtered.deinit(alloc);
    try filtered.ensureTotalCapacity(alloc, current_turn_messages.len);
    var allocated_call_slices: std.ArrayList([]ToolCall) = .empty;
    defer {
        for (allocated_call_slices.items) |calls| alloc.free(calls);
        allocated_call_slices.deinit(alloc);
    }

    var active_group_index: ?usize = null;
    if (active_tool_call) |active| {
        for (current_turn_messages, 0..) |message, index| {
            for (message.tool_calls) |call| {
                if (std.mem.eql(u8, call.id, active.id)) active_group_index = index;
            }
        }
    }
    var i: usize = 0;
    while (i < current_turn_messages.len) {
        const item = current_turn_messages[i];
        if (item.role != .assistant or item.tool_calls.len == 0) {
            try filtered.append(alloc, item);
            i += 1;
            continue;
        }

        var result_end = i + 1;
        while (result_end < current_turn_messages.len and
            current_turn_messages[result_end].role == .tool) : (result_end += 1)
        {}
        const result_messages = current_turn_messages[i + 1 .. result_end];
        var user_tail_end = result_end;
        while (user_tail_end < current_turn_messages.len and
            current_turn_messages[user_tail_end].role == .user) : (user_tail_end += 1)
        {}
        const user_tail = current_turn_messages[result_end..user_tail_end];

        var completed_count: usize = 0;
        for (item.tool_calls) |call| {
            if (active_tool_call) |active| {
                if (active_group_index == i and std.mem.eql(u8, call.id, active.id)) continue;
            }
            if (hasToolResultForCall(result_messages, call.id)) {
                completed_count += 1;
            }
        }

        if (item.provider_replay != null and completed_count != item.tool_calls.len) {
            debug_trace.logf("session", "provider replay omitted reason=interrupted_incomplete_association source_calls={d} completed_calls={d}", .{ item.tool_calls.len, completed_count });
        }
        if (completed_count > 0) {
            const calls = try alloc.alloc(ToolCall, completed_count);
            errdefer alloc.free(calls);
            try allocated_call_slices.append(alloc, calls);

            var completed_index: usize = 0;
            for (item.tool_calls) |call| {
                if (active_tool_call) |active| {
                    if (active_group_index == i and std.mem.eql(u8, call.id, active.id)) continue;
                }
                if (!hasToolResultForCall(result_messages, call.id)) continue;
                calls[completed_index] = call;
                completed_index += 1;
            }

            var projected = item;
            projected.tool_calls = calls;
            if (completed_count != item.tool_calls.len) projected.provider_replay = null;
            filtered.appendAssumeCapacity(projected);
            for (result_messages) |result| {
                const result_call_id = result.tool_call_id orelse continue;
                if (execution_memory_helpers.findToolCallById(
                    calls,
                    result_call_id,
                ) != null) {
                    filtered.appendAssumeCapacity(result);
                }
            }
            for (user_tail) |entry| {
                if (!entry.permission_feedback) continue;
                if (entry.tool_call_id) |source_tool_call_id| {
                    if (execution_memory_helpers.findToolCallById(calls, source_tool_call_id) == null) {
                        continue;
                    }
                }
                filtered.appendAssumeCapacity(entry);
            }
        }
        i = user_tail_end;
    }

    return buildExecutionMemory(alloc, filtered.items);
}

pub fn retainCancelledCommandReplay(
    arena: Allocator,
    result_memory: ?types.ToolResultMemory,
    capture: ?*command_replay_store.Capture,
) ?types.CancelledCommandPresentation {
    if (capture) |candidate| {
        const replay: ?types.CommandOutputReplay = switch (candidate.policy()) {
            .required => blk: {
                const descriptor = candidate.retainRequired(arena) catch |err| {
                    debug_trace.logf(
                        "session",
                        "cancelled command replay retention unavailable err={s}",
                        .{@errorName(err)},
                    );
                    break :blk .unavailable;
                } orelse break :blk null;
                break :blk .{ .available = descriptor };
            },
            .best_effort => candidate.retain(arena),
        };
        if (replay) |retained| return .{ .output_replay = retained };
    }
    const replay = if (result_memory) |memory|
        memory.command_output_replay
    else
        null;
    return if (replay) |value| .{ .output_replay = value } else null;
}

test "interrupted execution keeps replay only for an unchanged completed batch" {
    const alloc = std.testing.allocator;
    const call = toolCall("completed", "read_file", "{\"path\":\"a.txt\"}");
    const replay: types.ProviderReplay = .{
        .source = .{ .provider = .gateway, .model = "test" },
        .parts_json = "[{\"type\":\"reasoning\",\"text\":\"kept\"},{\"type\":\"tool-call\",\"toolCallId\":\"completed\"}]",
    };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{call}, .provider_replay = replay },
        .{ .role = .tool, .content = "result", .tool_call_id = call.id, .tool_name = call.name, .tool_result_status = .success },
    };
    const completed = try buildInterruptedExecutionMemory(alloc, &messages, null);
    defer types.freeExecutionMemory(alloc, completed);
    try std.testing.expectEqual(@as(usize, 1), completed.tool_steps.len);
    try std.testing.expectEqualStrings(replay.parts_json, completed.tool_steps[0].provider_replay.?.parts_json);
    const cancelled = try buildInterruptedExecutionMemory(alloc, &messages, call);
    defer types.freeExecutionMemory(alloc, cancelled);
    try std.testing.expectEqual(@as(usize, 0), cancelled.tool_steps.len);
    try std.testing.expectEqualStrings(replay.parts_json, messages[0].provider_replay.?.parts_json);
}

test "interrupted execution preserves a compacted prefix when later calls reuse an id" {
    const alloc = std.testing.allocator;
    const guidance = try steeringMessage(alloc, "Keep the original constraint.");
    defer alloc.free(guidance);
    const call = toolCall("reused", "read_file", "{\"path\":\"first.txt\"}");
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = guidance },
        .{ .role = .assistant, .tool_calls = &.{call} },
        .{ .role = .tool, .content = "completed", .tool_call_id = call.id, .tool_name = call.name, .tool_result_status = .success },
        .{ .role = .assistant, .tool_calls = &.{call} },
    };
    const interrupted = try buildInterruptedExecutionMemory(alloc, &messages, call);
    defer types.freeExecutionMemory(alloc, interrupted);
    try std.testing.expectEqual(@as(usize, 1), interrupted.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 1), interrupted.steering.len);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const boundary = CompactedExecutionBoundary{ .tool_steps = 1, .steering = 1 };
    const suffix = try boundary.project(arena.allocator(), interrupted);
    try std.testing.expectEqual(@as(usize, 0), suffix.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 0), suffix.steering.len);
}

test "interrupted execution memory retains marked feedback through mixed user tail" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{
        .{ .id = "call_first", .name = "run_command", .arguments_json = "{\"command\":\"printf first\"}" },
        .{ .id = "call_second", .name = "run_command", .arguments_json = "{\"command\":\"printf second\"}" },
        .{ .id = "call_active", .name = "run_command", .arguments_json = "{\"command\":\"printf active\"}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "first command completed", .tool_call_id = calls[0].id, .tool_name = calls[0].name, .tool_result_status = .success },
        .{ .role = .tool, .content = "second command completed", .tool_call_id = calls[1].id, .tool_name = calls[1].name, .tool_result_status = .success },
        .{ .role = .user, .content = "first command feedback marker", .tool_call_id = calls[0].id, .permission_feedback = true },
        .{ .role = .user, .content = "custom hint", .permission_feedback = false },
        .{ .role = .user, .content = "second command feedback marker", .tool_call_id = calls[1].id, .permission_feedback = true },
    };

    const memory = try buildInterruptedExecutionMemory(alloc, &messages, calls[2]);
    defer types.freeExecutionMemory(alloc, memory);

    const results = memory.tool_steps[0].tool_results;
    try std.testing.expectEqual(@as(usize, 1), results[0].permission_feedback.len);
    try std.testing.expectEqualStrings("first command feedback marker", results[0].permission_feedback[0]);
    try std.testing.expectEqual(@as(usize, 1), results[1].permission_feedback.len);
    try std.testing.expectEqualStrings("second command feedback marker", results[1].permission_feedback[0]);
}

fn hasToolResultForCall(
    result_messages: []const ChatMessage,
    call_id: []const u8,
) bool {
    for (result_messages) |result| {
        if (result.tool_call_id) |result_call_id| {
            if (std.mem.eql(u8, result_call_id, call_id)) return true;
        }
    }
    return false;
}

pub fn prepareToolExecutionOutput(
    arena: Allocator,
    config: Config,
    tool_call: ToolCall,
    execution: runtime_tool_contracts.ToolExecutionResult,
    capture: ?*command_replay_store.Capture,
) !result_store.PreparedResult {
    if (execution.model_content_kind != .complete_skill or execution.status != .success) {
        return prepareCapturedToolModelOutput(arena, config, tool_call, execution.model_output, capture);
    }
    if (capture != null) return error.InvalidSkillContentResult;
    const full = try tool_result_limits.prepareSanitizedOutput(arena, execution.model_output);
    errdefer arena.free(full);
    if (full.len > config.max_tool_result_bytes) return error.SkillContentLimitExceeded;
    var prepared = try prepareCapturedToolModelOutput(arena, config, tool_call, full, null);
    arena.free(prepared.model_output);
    prepared.model_output = full;
    prepared.memory.truncated = false;
    return prepared;
}

pub fn prepareToolModelOutput(
    arena: Allocator,
    config: Config,
    tool_call: ToolCall,
    raw_output: []const u8,
) !result_store.PreparedResult {
    return prepareCapturedToolModelOutput(
        arena,
        config,
        tool_call,
        raw_output,
        null,
    );
}

pub fn prepareCapturedToolModelOutput(
    arena: Allocator,
    config: Config,
    tool_call: ToolCall,
    raw_output: []const u8,
    capture: ?*command_replay_store.Capture,
) !result_store.PreparedResult {
    if (std.mem.eql(u8, tool_call.name, "read_tool_result")) {
        const prepared = try tool_result_limits.prepareModelOutputWithTruncation(
            arena,
            tool_call.name,
            raw_output,
            config.max_tool_result_bytes,
        );
        errdefer arena.free(prepared.model_output);
        var memory: types.ToolResultMemory = .{
            .output_bytes = raw_output.len,
            .stored_output_bytes = prepared.model_output.len,
            .truncated = prepared.truncated,
        };
        if (prepared.truncated and
            (config.session_child_capability != null or config.tool_result_dir != null))
        {
            const complete_output = try text_utils.sanitizeModelText(arena, raw_output);
            defer if (complete_output.ptr != raw_output.ptr) arena.free(complete_output);
            memory.output_handle = if (config.session_child_capability) |capability|
                try result_store.storeLargeResultManaged(arena, capability, tool_call.id, tool_call.name, complete_output)
            else
                try result_store.storeLargeResult(arena, config.tool_result_dir.?, tool_call.id, tool_call.name, complete_output);
            memory.stored_output_bytes = complete_output.len;
        }
        return .{
            .model_output = prepared.model_output,
            .memory = memory,
        };
    }
    const required_command_replay = if (capture) |candidate|
        candidate.policy() == .required
    else
        false;
    if (!required_command_replay and
        (config.session_child_capability != null or config.tool_result_dir != null))
    {
        const sanitized_output = try tool_result_limits.prepareSanitizedOutput(
            arena,
            raw_output,
        );
        if (config.session_child_capability != null) {
            return result_store.prepareManaged(
                arena,
                config.session_child_capability,
                tool_call.id,
                tool_call.name,
                raw_output.len,
                sanitized_output,
                config.max_tool_result_bytes,
            );
        }
        return result_store.prepare(
            arena,
            config.tool_result_dir,
            tool_call.id,
            tool_call.name,
            raw_output.len,
            sanitized_output,
            config.max_tool_result_bytes,
        );
    }
    const model_output_budget = if (required_command_replay)
        config.max_tool_result_bytes -| command_replay_store.model_handle_notice_reserve_bytes
    else
        config.max_tool_result_bytes;
    const prepared = try tool_result_limits.prepareModelOutputWithTruncation(
        arena,
        tool_call.name,
        raw_output,
        model_output_budget,
    );
    return .{
        .model_output = prepared.model_output,
        .memory = .{
            .output_bytes = raw_output.len,
            .stored_output_bytes = prepared.model_output.len,
            .truncated = prepared.truncated,
        },
    };
}

/// Fits tool images to the model pixel limit, then saves them so later
/// requests can load them again. `scratch` holds temporary resize buffers.
pub fn retainToolImages(arena: Allocator, scratch: Allocator, config: Config, call: ToolCall, prepared: *result_store.PreparedResult) !void {
    try fitToolImagesForHistory(arena, scratch, config, call, prepared);
    const memory = &prepared.memory;
    if (memory.tool_images.len == 0 or memory.tool_image_handle != null) return;
    const capability = config.session_child_capability orelse return;
    const handle = result_store.storeToolImages(arena, capability, call.id, call.name, memory.tool_images) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("session", "tool images remain inline because artifact storage failed call_id={s} err={s}", .{ call.id, @errorName(err) });
        return;
    };
    memory.tool_image_handle = handle;
    const notice = try std.fmt.allocPrint(arena, "Saved images: {s}. Use read_tool_result with this handle to load them again.\n", .{handle});
    const limit = config.max_tool_result_bytes -| notice.len;
    const keep = @import("../../config/context_limits.zig").utf8PrefixLength(prepared.model_output, limit);
    if (keep < prepared.model_output.len) memory.truncated = true;
    prepared.model_output = try std.mem.concat(arena, u8, &.{ notice, prepared.model_output[0..keep] });
}

/// Tool images after fitting them to `image_data.max_image_dimension`.
const FittedToolImages = struct {
    /// Images within the pixel limit, in their original order. Borrows the
    /// input slice when nothing changed.
    images: []const types.ToolImage,
    /// One line per downscaled or withheld image; empty when nothing changed.
    notice: []const u8 = "",
    downscaled: usize = 0,
    withheld: usize = 0,
};

fn exceedsModelImageLimit(image: types.ToolImage) bool {
    const dimensions = image_data.encodedImageDimensions(image.data) orelse return false;
    return dimensions.exceedsModelLimit();
}

fn countOversizedImages(images: []const types.ToolImage) usize {
    var count: usize = 0;
    for (images) |image| {
        if (exceedsModelImageLimit(image)) count += 1;
    }
    return count;
}

const DownscaledToolImage = struct {
    image: types.ToolImage,
    dimensions: image_data.Dimensions,
};

/// Shrinks a PNG tool image to the model pixel limit. Returns null for other
/// formats, undecodable PNGs, and copies that would exceed the encoded size
/// limit. Temporary buffers use `scratch`; the returned image is owned by `arena`.
fn downscaleToolImage(arena: Allocator, scratch: Allocator, image: types.ToolImage) Allocator.Error!?DownscaledToolImage {
    if (!std.mem.eql(u8, image.mime_type, "image/png")) return null;
    const decoder = std.base64.standard.Decoder;
    const png_len = decoder.calcSizeForSlice(image.data) catch return null;
    const png = try scratch.alloc(u8, png_len);
    defer scratch.free(png);
    decoder.decode(png, image.data) catch return null;
    const smaller = png_downscale.downscale(scratch, png, image_data.max_image_dimension) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPng, error.UnsupportedPng => return null,
    };
    defer scratch.free(smaller.png);
    const encoded_len = std.base64.standard.Encoder.calcSize(smaller.png.len);
    if (encoded_len > image_data.max_encoded_image_bytes) return null;
    const encoded = try arena.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, smaller.png);
    return .{
        .image = .{ .data = encoded, .mime_type = try arena.dupe(u8, "image/png") },
        .dimensions = .{ .width = smaller.width, .height = smaller.height },
    };
}

/// Ratio from downscaled to original pixels along the longer side.
fn coordinateScale(original: image_data.Dimensions, smaller: image_data.Dimensions) f64 {
    if (original.width >= original.height) {
        return @as(f64, @floatFromInt(original.width)) / @as(f64, @floatFromInt(smaller.width));
    }
    return @as(f64, @floatFromInt(original.height)) / @as(f64, @floatFromInt(smaller.height));
}

/// Shrinks PNG tool images over the model pixel limit and withholds other
/// oversized images, so every image kept in history fits every request.
fn fitToolImagesToModelLimit(arena: Allocator, scratch: Allocator, images: []const types.ToolImage) !FittedToolImages {
    if (countOversizedImages(images) == 0) return .{ .images = images };

    var fitted: FittedToolImages = .{ .images = &.{} };
    var kept: std.ArrayList(types.ToolImage) = try .initCapacity(arena, images.len);
    var notice: std.Io.Writer.Allocating = .init(arena);
    for (images) |image| {
        const original = image_data.encodedImageDimensions(image.data) orelse {
            kept.appendAssumeCapacity(image);
            continue;
        };
        if (!original.exceedsModelLimit()) {
            kept.appendAssumeCapacity(image);
            continue;
        }
        if (try downscaleToolImage(arena, scratch, image)) |smaller| {
            kept.appendAssumeCapacity(smaller.image);
            fitted.downscaled += 1;
            try notice.writer.print(
                "[Image downscaled from {d}x{d} to {d}x{d} pixels to fit the {d}-pixel limit per side. Multiply coordinates in this image by {d:.2} to get original pixels.]\n",
                .{ original.width, original.height, smaller.dimensions.width, smaller.dimensions.height, image_data.max_image_dimension, coordinateScale(original, smaller.dimensions) },
            );
        } else {
            fitted.withheld += 1;
            try notice.writer.print(
                "[Image not sent: {s} is {d}x{d} pixels, over the {d}-pixel limit per side, and fx could not downscale it, so it is not visible in this conversation. Downscale or crop it, then load the smaller image.]\n",
                .{ image.mime_type, original.width, original.height, image_data.max_image_dimension },
            );
        }
    }
    fitted.images = kept.items;
    fitted.notice = notice.written();
    return fitted;
}

/// Fits tool images to the model pixel limit before the result enters
/// history, where one oversized image would fail every later request. The
/// notice stays in the model-visible output. `scratch` holds temporary
/// decode buffers and is fully released before returning.
fn fitToolImagesForHistory(arena: Allocator, scratch: Allocator, config: Config, call: ToolCall, prepared: *result_store.PreparedResult) !void {
    const fitted = try fitToolImagesToModelLimit(arena, scratch, prepared.memory.tool_images);
    if (fitted.downscaled == 0 and fitted.withheld == 0) return;
    debug_trace.logf("images", "event=tool_images_fitted call_id={s} tool={s} downscaled={d} withheld={d} max_dimension={d}", .{ call.id, call.name, fitted.downscaled, fitted.withheld, image_data.max_image_dimension });
    prepared.memory.tool_images = fitted.images;
    const limit = config.max_tool_result_bytes -| fitted.notice.len;
    const keep = @import("../../config/context_limits.zig").utf8PrefixLength(prepared.model_output, limit);
    if (keep < prepared.model_output.len) prepared.memory.truncated = true;
    prepared.model_output = try std.mem.concat(arena, u8, &.{ fitted.notice, prepared.model_output[0..keep] });
}

/// Leaves out stored images over the model pixel limit. They were saved
/// before images were fitted on entry; loading the source again yields a
/// downscaled copy.
fn withholdOversizedStoredImages(arena: Allocator, images: []const types.ToolImage) !FittedToolImages {
    if (countOversizedImages(images) == 0) return .{ .images = images };

    var fitted: FittedToolImages = .{ .images = &.{} };
    var kept: std.ArrayList(types.ToolImage) = try .initCapacity(arena, images.len);
    var notice: std.Io.Writer.Allocating = .init(arena);
    for (images) |image| {
        if (image_data.encodedImageDimensions(image.data)) |dimensions| {
            if (dimensions.exceedsModelLimit()) {
                fitted.withheld += 1;
                try notice.writer.print(
                    "[Image not sent: {d}x{d} pixels is over the {d}-pixel limit per side, so it is not visible in this conversation. Load it again to get a downscaled copy.]\n",
                    .{ dimensions.width, dimensions.height, image_data.max_image_dimension },
                );
                continue;
            }
        }
        kept.appendAssumeCapacity(image);
    }
    fitted.images = kept.items;
    fitted.notice = notice.written();
    return fitted;
}

fn needsImageMaterialization(messages: []const ChatMessage) bool {
    for (messages) |message| {
        const memory = message.tool_result_memory orelse continue;
        if (memory.tool_images.len == 0 and memory.tool_image_handle != null) return true;
        for (memory.tool_images) |image| {
            if (exceedsModelImageLimit(image)) return true;
        }
    }
    return false;
}

/// Loads stored tool images for a request and withholds any over the model
/// pixel limit, so sessions saved before that limit existed stay usable.
pub fn materializeToolImages(arena: Allocator, config: Config, messages: []const ChatMessage) ![]const ChatMessage {
    if (!needsImageMaterialization(messages)) return messages;
    const materialized = try arena.dupe(ChatMessage, messages);
    for (materialized) |*message| {
        if (message.tool_result_memory) |*memory| {
            if (memory.tool_images.len == 0) {
                const handle = memory.tool_image_handle orelse continue;
                const capability = config.session_child_capability orelse {
                    message.content = try prependImageNotice(arena, "[Stored tool image is unavailable in this session.]\n", message.content orelse "", config.max_tool_result_bytes);
                    continue;
                };
                memory.tool_images = result_store.loadToolImages(arena, capability, handle) catch |err| {
                    if (err == error.OutOfMemory) return error.OutOfMemory;
                    const notice = try std.fmt.allocPrint(arena, "[Stored tool image unavailable: {s}]\n", .{@errorName(err)});
                    message.content = try prependImageNotice(arena, notice, message.content orelse "", config.max_tool_result_bytes);
                    continue;
                };
            }
            const fitted = try withholdOversizedStoredImages(arena, memory.tool_images);
            if (fitted.withheld == 0) continue;
            debug_trace.logf("images", "event=stored_tool_images_withheld call_id={s} withheld={d} kept={d} max_dimension={d}", .{ message.tool_call_id orelse "", fitted.withheld, fitted.images.len, image_data.max_image_dimension });
            memory.tool_images = fitted.images;
            message.content = try prependImageNotice(arena, fitted.notice, message.content orelse "", config.max_tool_result_bytes);
        }
    }
    return materialized;
}

fn prependImageNotice(alloc: Allocator, notice: []const u8, content: []const u8, limit: usize) Allocator.Error![]u8 {
    const keep = @import("../../config/context_limits.zig").utf8PrefixLength(content, limit -| notice.len);
    return std.mem.concat(alloc, u8, &.{ notice[0..@min(notice.len, limit)], content[0..keep] });
}

fn testEncodedToolImage(arena: Allocator, bytes: []const u8, mime_type: []const u8) !types.ToolImage {
    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return .{ .data = encoded, .mime_type = try arena.dupe(u8, mime_type) };
}

/// PNG signature and IHDR only: enough for pixel checks, not for decoding.
fn testPngHeaderToolImage(arena: Allocator, width: u32, height: u32) !types.ToolImage {
    var header: [24]u8 = undefined;
    @memcpy(header[0..16], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR");
    std.mem.writeInt(u32, header[16..20], width, .big);
    std.mem.writeInt(u32, header[20..24], height, .big);
    return testEncodedToolImage(arena, &header, "image/png");
}

fn testJpegHeaderToolImage(arena: Allocator, width: u16, height: u16) !types.ToolImage {
    var header = "\xff\xd8\xff\xc0\x00\x11\x08\x00\x00\x00\x00\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01".*;
    std.mem.writeInt(u16, header[7..9], height, .big);
    std.mem.writeInt(u16, header[9..11], width, .big);
    return testEncodedToolImage(arena, &header, "image/jpeg");
}

fn testImageConfig(cancel: *std.atomic.Value(bool)) Config {
    return .{
        .system_prompt = "",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .agent_step_limit = 1,
        .max_tool_result_bytes = tool_result_limits.min_configured_tool_result_bytes,
        .cancel_flag = cancel,
    };
}

test "oversized tool images are downscaled or withheld before the result enters history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    const wide_png = try png_downscale.testSolidGrayPng(std.testing.allocator, 2400, 2, 90);
    defer std.testing.allocator.free(wide_png);
    const images = [_]types.ToolImage{
        try testEncodedToolImage(arena, wide_png, "image/png"),
        try testJpegHeaderToolImage(arena, 3420, 2224),
        try testPngHeaderToolImage(arena, 640, 480),
    };
    var prepared = result_store.PreparedResult{
        .model_output = "captured three frames",
        .memory = .{ .tool_images = &images },
    };

    try fitToolImagesForHistory(arena, std.testing.allocator, testImageConfig(&cancel), toolCall("call_frames", "capture", "{}"), &prepared);

    try std.testing.expectEqual(@as(usize, 2), prepared.memory.tool_images.len);
    try std.testing.expectEqual(
        @as(?image_data.Dimensions, .{ .width = 2000, .height = 2 }),
        image_data.encodedImageDimensions(prepared.memory.tool_images[0].data),
    );
    try std.testing.expectEqualStrings("image/png", prepared.memory.tool_images[0].mime_type);
    try std.testing.expectEqualStrings(images[2].data, prepared.memory.tool_images[1].data);
    try std.testing.expectEqualStrings(
        "[Image downscaled from 2400x2 to 2000x2 pixels to fit the 2000-pixel limit per side. Multiply coordinates in this image by 1.20 to get original pixels.]\n" ++
            "[Image not sent: image/jpeg is 3420x2224 pixels, over the 2000-pixel limit per side, and fx could not downscale it, so it is not visible in this conversation. Downscale or crop it, then load the smaller image.]\n" ++
            "captured three frames",
        prepared.model_output,
    );
    try std.testing.expect(!prepared.memory.truncated);
}

test "tool images within the pixel limit pass through unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    const images = [_]types.ToolImage{
        try testPngHeaderToolImage(arena, image_data.max_image_dimension, image_data.max_image_dimension),
        .{ .data = try arena.dupe(u8, "bm90IGFuIGltYWdl"), .mime_type = try arena.dupe(u8, "image/png") },
    };
    var prepared = result_store.PreparedResult{
        .model_output = "image attached",
        .memory = .{ .tool_images = &images },
    };

    try fitToolImagesForHistory(arena, std.testing.allocator, testImageConfig(&cancel), toolCall("call_edge", "read_file", "{}"), &prepared);

    try std.testing.expectEqual(@as([*]const types.ToolImage, &images), prepared.memory.tool_images.ptr);
    try std.testing.expectEqual(@as(usize, 2), prepared.memory.tool_images.len);
    try std.testing.expectEqualStrings("image attached", prepared.model_output);
}

test "request materialization withholds oversized images saved before fitting" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    const images = [_]types.ToolImage{
        try testPngHeaderToolImage(arena, 3420, 2224),
        try testPngHeaderToolImage(arena, 10, 10),
    };
    const messages = [_]ChatMessage{
        .{ .role = .tool, .tool_call_id = "call_old", .tool_name = "read_file", .content = "image attached", .tool_result_memory = .{ .tool_images = &images } },
        .{ .role = .user, .content = "wtf" },
    };

    const materialized = try materializeToolImages(arena, testImageConfig(&cancel), &messages);

    try std.testing.expectEqual(@as(usize, 1), materialized[0].tool_result_memory.?.tool_images.len);
    try std.testing.expectEqualStrings(images[1].data, materialized[0].tool_result_memory.?.tool_images[0].data);
    try std.testing.expectEqualStrings(
        "[Image not sent: 3420x2224 pixels is over the 2000-pixel limit per side, so it is not visible in this conversation. Load it again to get a downscaled copy.]\nimage attached",
        materialized[0].content.?,
    );
    try std.testing.expectEqual(@as(usize, 2), messages[0].tool_result_memory.?.tool_images.len);
    try std.testing.expectEqualStrings("wtf", materialized[1].content.?);
}

pub fn applyToolResultMemory(
    prepared: *types.ToolResultMemory,
    source: ?types.ToolResultMemory,
) void {
    const source_memory = source orelse return;
    prepared.review_feedback = source_memory.review_feedback;
    prepared.tool_images = source_memory.tool_images;
    prepared.tool_image_handle = source_memory.tool_image_handle;
    prepared.command_output_replay = source_memory.command_output_replay;
    prepared.command_process_presentation = source_memory.command_process_presentation;
    prepared.terminal_action_presentation = source_memory.terminal_action_presentation;
    const source_covers_full_file =
        source_memory.model_view_covers_full_file orelse return;
    prepared.model_view_covers_full_file =
        source_covers_full_file and
        !source_memory.truncated and
        source_memory.output_handle == null and
        !prepared.truncated;
}

/// Finalizes tentative command capture after bounded model output is prepared.
/// Required native exec always retains one authoritative replay and publishes
/// its handle; legacy exact round trips keep the existing discard optimization.
pub fn finalizeCommandReplay(
    arena: Allocator,
    tool_call: ToolCall,
    prepared: *result_store.PreparedResult,
    session_child_capability: ?*session_child_store.SessionChildCapability,
    capture: ?*command_replay_store.Capture,
) !void {
    const candidate = capture orelse return;
    if (!candidate.hasOutput()) {
        candidate.discard(arena);
        return;
    }
    if (candidate.policy() == .required) {
        const descriptor = (try candidate.retainRequired(arena)) orelse return;
        prepared.memory.command_output_replay = .{ .available = descriptor };
        prepared.model_output = try command_replay_store.appendModelHandleNotice(
            arena,
            prepared.model_output,
            descriptor.handle,
        );
        prepared.memory.stored_output_bytes = prepared.model_output.len;
        return;
    }
    var captured = candidate.canonicalizeForComparison(arena) catch |err| {
        debug_trace.logf(
            "session",
            "command replay comparison unavailable call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    } orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer captured.deinit(arena);

    const source = selectedCommandSource(
        arena,
        prepared.*,
        session_child_capability,
        candidate.comparisonLimit(),
    ) catch |err| {
        debug_trace.logf(
            "session",
            "command replay source comparison failed call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    } orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer arena.free(source);
    var ordinary = (command_output_content.canonicalizeForegroundResult(
        arena,
        source,
    ) catch |err| {
        debug_trace.logf(
            "session",
            "command replay envelope comparison failed call_id_bytes={d} err={s}",
            .{ tool_call.id.len, @errorName(err) },
        );
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    }) orelse {
        retainCommandReplay(arena, candidate, &prepared.memory);
        return;
    };
    defer ordinary.deinit(arena);

    if (command_output_content.eql(captured, ordinary)) {
        candidate.discard(arena);
        return;
    }
    retainCommandReplay(arena, candidate, &prepared.memory);
}

fn selectedCommandSource(
    arena: Allocator,
    prepared: result_store.PreparedResult,
    session_child_capability: ?*session_child_store.SessionChildCapability,
    comparison_limit: usize,
) !?[]u8 {
    const source_limit = std.math.add(
        usize,
        comparison_limit,
        command_output_content.max_foreground_result_envelope_bytes,
    ) catch return null;
    if (prepared.memory.output_handle) |handle| {
        const capability = session_child_capability orelse return null;
        var reader = try result_store.openReaderManaged(arena, capability, handle);
        defer reader.deinit();
        if (reader.size != prepared.memory.stored_output_bytes or
            reader.size > source_limit) return null;

        const source = try arena.alloc(u8, reader.size);
        errdefer arena.free(source);
        var offset: usize = 0;
        while (offset < source.len) {
            const page_len = @min(source.len - offset, 4 * 1024);
            const page = try reader.readPage(arena, offset, page_len);
            defer arena.free(page);
            if (page.len != page_len) return error.UnexpectedEndOfResult;
            @memcpy(source[offset..][0..page.len], page);
            offset += page.len;
        }
        return source;
    }
    if (prepared.model_output.len > source_limit) return null;
    const source = try arena.dupe(u8, prepared.model_output);
    if (source.len > source_limit) {
        arena.free(source);
        return null;
    }
    return source;
}

fn retainCommandReplay(
    arena: Allocator,
    candidate: *command_replay_store.Capture,
    memory: *types.ToolResultMemory,
) void {
    memory.command_output_replay = candidate.retain(arena);
}

pub fn captureCommittedFilePresentation(
    alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) !types.CommittedFilePresentation {
    const path = try alloc.dupe(u8, handoff.preview.path);
    errdefer alloc.free(path);
    const lines = try alloc.alloc(types.CommittedFilePresentationLine, handoff.preview.lines.len);
    errdefer alloc.free(lines);
    var copied_lines: usize = 0;
    errdefer {
        for (lines[0..copied_lines]) |line| alloc.free(@constCast(line.text));
    }
    for (handoff.preview.lines, 0..) |line, index| {
        lines[index] = .{
            .kind = switch (line.op) {
                .context => .context,
                .addition => .addition,
                .deletion => .deletion,
                .elision => .elision,
                .notice => .notice,
            },
            .old_line = line.old_line,
            .new_line = line.new_line,
            .text = try alloc.dupe(u8, line.text),
        };
        copied_lines += 1;
    }
    const full_view = handoff.full_view;
    const previous_content = if (full_view != null) if (handoff.tracker.previous_content) |content|
        try alloc.dupe(u8, content)
    else
        null else null;
    errdefer if (previous_content) |content| alloc.free(content);
    const after_content = if (full_view) |full|
        try alloc.dupe(u8, full.after_content)
    else
        null;
    errdefer if (after_content) |content| alloc.free(content);
    const lifecycle_id: ?types.ToolLifecycleId = if (full_view) |full| .{
        .turn_id = full.lifecycle_id.turn_id,
        .call_id = try alloc.dupe(u8, full.lifecycle_id.call_id),
    } else null;
    errdefer if (lifecycle_id) |id| alloc.free(@constCast(id.call_id));
    return .{
        .path = path,
        .kind = switch (handoff.tracker.kind) {
            .write => .added,
            .edit => .edited,
        },
        .lines = lines,
        .additions = handoff.preview.additions,
        .deletions = handoff.preview.deletions,
        .truncated = handoff.preview.truncated,
        .previous_content = previous_content,
        .after_content = after_content,
        .lifecycle_id = lifecycle_id,
    };
}

fn toolCall(id: []const u8, name: []const u8, args: []const u8) ToolCall {
    return .{ .id = id, .name = name, .arguments_json = args };
}

test "command sidebands merge without file-view metadata" {
    var prepared: types.ToolResultMemory = .{};
    applyToolResultMemory(&prepared, .{
        .command_output_replay = .unavailable,
        .command_process_presentation = .{ .signal = 9 },
        .terminal_action_presentation = .{ .returned = .safety_ceiling },
    });
    switch (prepared.command_output_replay.?) {
        .unavailable => {},
        .available => return error.TestExpectedUnavailableReplay,
    }
    try std.testing.expectEqual(
        types.CommandProcessPresentation{ .signal = 9 },
        prepared.command_process_presentation.?,
    );
    try std.testing.expectEqual(
        types.TerminalActionPresentation{ .returned = .safety_ceiling },
        prepared.terminal_action_presentation.?,
    );
    try std.testing.expect(prepared.model_view_covers_full_file == null);
}

test "exact command sources delete replay and missing handles retain it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const display_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(display_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        display_path,
        .writable,
        .{},
    );
    defer capability.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const capture = try command_replay_store.Capture.create(arena, 46, &capability);
    capture.appendAccepted(arena, .stdout, "o");
    capture.appendAccepted(arena, .stdout, "n");
    capture.appendAccepted(arena, .stdout, "e");
    capture.appendAccepted(arena, .stdout, "\n");
    capture.seal(arena);
    var before = try capability.iterate(alloc, .command_artifacts);
    defer before.deinit();
    try std.testing.expectEqual(@as(usize, 1), before.names.len);

    var cancel_flag = std.atomic.Value(bool).init(false);
    var prepared = result_store.PreparedResult{
        .model_output = "exit_code=0\n<stdout>\none\n</stdout>\n",
        .memory = .{
            .output_bytes = 42,
            .stored_output_bytes = 42,
        },
    };
    try finalizeCommandReplay(
        arena,
        toolCall("command_exact", "run_command", "{}"),
        &prepared,
        &capability,
        capture,
    );

    try std.testing.expect(prepared.memory.command_output_replay == null);
    var after = try capability.iterate(alloc, .command_artifacts);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 0), after.names.len);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(arena);
    try body.appendNTimes(arena, 'x', 80 * 1024);
    const stored_source = try std.fmt.allocPrint(
        arena,
        "exit_code=0\n<stdout>\n{s}\n</stdout>\n",
        .{body.items},
    );
    const stored_capture = try command_replay_store.Capture.create(
        arena,
        1024,
        &capability,
    );
    stored_capture.setComparisonLimit(body.items.len);
    stored_capture.appendAccepted(arena, .stdout, body.items);
    stored_capture.seal(arena);
    var stored_prepared = try prepareCapturedToolModelOutput(
        arena,
        .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .agent_step_limit = 1,
            .cancel_flag = &cancel_flag,
            .session_child_capability = &capability,
        },
        toolCall("command_stored_exact", "run_command", "{}"),
        stored_source,
        stored_capture,
    );
    try std.testing.expect(stored_prepared.memory.output_handle != null);
    try finalizeCommandReplay(
        arena,
        toolCall("command_stored_exact", "run_command", "{}"),
        &stored_prepared,
        &capability,
        stored_capture,
    );
    try std.testing.expect(stored_prepared.memory.command_output_replay == null);
    var after_stored = try capability.iterate(alloc, .command_artifacts);
    defer after_stored.deinit();
    try std.testing.expectEqual(@as(usize, 0), after_stored.names.len);

    const TransformCase = struct {
        raw: []const u8,
        projected: []const u8,
    };
    const transform_cases = [_]TransformCase{
        .{ .raw = "\x00\n", .projected = "\\x00" },
        .{ .raw = "\xff\n", .projected = "\\xff" },
        .{ .raw = "\xc2\x80\n", .projected = "\\u{0080}" },
        .{ .raw = "\x1b[31mred\x1b[0m\n", .projected = "red" },
        .{ .raw = "old\rnew\n", .projected = "new" },
    };
    for (transform_cases) |case| {
        const transformed_capture = try command_replay_store.Capture.create(
            arena,
            256,
            &capability,
        );
        transformed_capture.appendAccepted(arena, .stdout, case.raw);
        transformed_capture.seal(arena);
        const projected_source = try std.fmt.allocPrint(
            arena,
            "exit_code=0\n<stdout>\n{s}\n</stdout>\n",
            .{case.projected},
        );
        var transformed_prepared = result_store.PreparedResult{
            .model_output = projected_source,
            .memory = .{
                .output_bytes = projected_source.len,
                .stored_output_bytes = projected_source.len,
            },
        };
        try finalizeCommandReplay(
            arena,
            toolCall("command_transformed", "run_command", "{}"),
            &transformed_prepared,
            &capability,
            transformed_capture,
        );
        const transformed_replay = transformed_prepared.memory.command_output_replay orelse
            return error.TestExpectedReplay;
        switch (transformed_replay) {
            .available => {},
            .unavailable => return error.TestExpectedReplay,
        }
    }

    var before_literal = try capability.iterate(alloc, .command_artifacts);
    defer before_literal.deinit();
    const literal_capture = try command_replay_store.Capture.create(
        arena,
        1,
        &capability,
    );
    literal_capture.setComparisonLimit(256);
    literal_capture.appendAccepted(arena, .stdout, "\\x00\n");
    literal_capture.seal(arena);
    var literal_prepared = result_store.PreparedResult{
        .model_output = "exit_code=0\n<stdout>\n\\x00\n</stdout>\n",
        .memory = .{
            .output_bytes = 40,
            .stored_output_bytes = 40,
        },
    };
    try finalizeCommandReplay(
        arena,
        toolCall("command_literal", "run_command", "{}"),
        &literal_prepared,
        &capability,
        literal_capture,
    );
    try std.testing.expect(literal_prepared.memory.command_output_replay == null);
    var after_literal = try capability.iterate(alloc, .command_artifacts);
    defer after_literal.deinit();
    try std.testing.expectEqual(before_literal.names.len, after_literal.names.len);

    const missing_capture = try command_replay_store.Capture.create(
        arena,
        64 * 1024,
        &capability,
    );
    missing_capture.appendAccepted(arena, .stdout, "one\n");
    missing_capture.seal(arena);
    var missing_prepared = result_store.PreparedResult{
        .model_output = "stored result preview",
        .memory = .{
            .output_handle = "result-run-command-missing.txt",
            .output_bytes = 42,
            .stored_output_bytes = 42,
            .truncated = true,
        },
    };
    try finalizeCommandReplay(
        arena,
        toolCall("command_missing", "run_command", "{}"),
        &missing_prepared,
        &capability,
        missing_capture,
    );
    const retained = missing_prepared.memory.command_output_replay orelse
        return error.TestExpectedReplay;
    switch (retained) {
        .available => {},
        .unavailable => return error.TestExpectedReplay,
    }
    var after_missing = try capability.iterate(alloc, .command_artifacts);
    defer after_missing.deinit();
    try std.testing.expectEqual(transform_cases.len + 1, after_missing.names.len);
}

test "required terminal exec retains exact replay and publishes its handle" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const display_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(display_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        display_path,
        .writable,
        .{},
    );
    defer capability.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const capture = try command_replay_store.Capture.create(arena, 64 * 1024, &capability);
    capture.setPolicyBeforeCapture(.required);
    capture.appendAccepted(arena, .stdout, "one\n");
    capture.seal(arena);
    var prepared = result_store.PreparedResult{
        .model_output = "exit_code=0\n<stdout>\none\n</stdout>\n",
        .memory = .{
            .output_bytes = 42,
            .stored_output_bytes = 42,
        },
    };

    try finalizeCommandReplay(
        arena,
        toolCall(
            "terminal_exact",
            "terminal",
            "{\"action\":\"exec\",\"command\":\"printf one\",\"timeout_ms\":600000}",
        ),
        &prepared,
        &capability,
        capture,
    );

    const replay = prepared.memory.command_output_replay orelse
        return error.TestExpectedReplay;
    const descriptor = switch (replay) {
        .available => |value| value,
        .unavailable => return error.TestExpectedReplay,
    };
    try std.testing.expect(std.mem.find(u8, prepared.model_output, descriptor.handle) != null);
    capture.releaseRetained(arena);
}

test "required terminal exec stores large output only as replay" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(
        io_mod.getIo(),
        "session",
        std.Io.File.Permissions.fromMode(0o700),
    );
    var session_dir = try tmp.dir.openDir(io_mod.getIo(), "session", .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer session_dir.close(io_mod.getIo());
    const display_path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "session");
    defer alloc.free(display_path);
    var capability = try session_child_store.SessionChildCapability.initForTesting(
        alloc,
        session_dir,
        display_path,
        .writable,
        .{},
    );
    defer capability.deinit();
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    const body = try arena.alloc(u8, result_store.large_result_threshold_bytes + 1024);
    @memset(body, 'x');
    const raw_output = try std.fmt.allocPrint(
        arena,
        "exit_code=0\n<stdout>\n{s}\n</stdout>\n",
        .{body},
    );
    const tool_call = toolCall(
        "terminal_large",
        "terminal",
        "{}",
    );
    const capture = try command_replay_store.Capture.create(arena, 1024, &capability);
    capture.setPolicyBeforeCapture(.required);
    try capture.appendAcceptedRequired(arena, .stdout, body);
    var prepared = try prepareCapturedToolModelOutput(arena, .{
        .system_prompt = "",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .agent_step_limit = 1,
        .max_tool_result_bytes = tool_result_limits.min_configured_tool_result_bytes,
        .cancel_flag = &cancel,
        .session_child_capability = &capability,
    }, tool_call, raw_output, capture);
    try std.testing.expect(prepared.memory.output_handle == null);
    try finalizeCommandReplay(
        arena,
        tool_call,
        &prepared,
        &capability,
        capture,
    );
    defer capture.releaseRetained(arena);
    try std.testing.expect(
        prepared.model_output.len <= tool_result_limits.min_configured_tool_result_bytes,
    );
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "<command_output_handle>") != null);

    var command_artifacts = try capability.iterate(alloc, .command_artifacts);
    defer command_artifacts.deinit();
    try std.testing.expectEqual(@as(usize, 1), command_artifacts.names.len);
    var tool_results = try capability.iterate(alloc, .tool_results);
    defer tool_results.deinit();
    try std.testing.expectEqual(@as(usize, 0), tool_results.names.len);
}

test "saved preparation stores complete output verbatim on cap loss" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(result_dir);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    const raw = "MY_UNIT_TOKEN=abcdefgh" ** 47;
    try std.testing.expect(raw.len > tool_result_limits.min_configured_tool_result_bytes);

    const prepared = try prepareToolModelOutput(
        arena,
        .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .agent_step_limit = 1,
            .max_tool_result_bytes = tool_result_limits.min_configured_tool_result_bytes,
            .cancel_flag = &cancel,
            .tool_result_dir = result_dir,
        },
        toolCall("call_expanded_output", "read_file", "{}"),
        raw,
    );

    const handle = prepared.memory.output_handle orelse
        return error.TestExpectedStoredResult;
    try std.testing.expect(prepared.memory.truncated);
    const stored = try result_store.readByRange(
        alloc,
        result_dir,
        handle,
        1,
        result_store.read_max_bytes,
    );
    defer alloc.free(stored);
    try std.testing.expect(std.mem.find(u8, stored, "MY_UNIT_TOKEN=abcdefgh") != null);
    try std.testing.expect(std.mem.find(u8, stored, "[redacted]") == null);
}

test "no-save preparation preserves capped output verbatim without a result handle" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    const raw = "MY_UNIT_TOKEN=abcdefgh" ** 47;

    const prepared = try prepareToolModelOutput(
        arena,
        .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .agent_step_limit = 1,
            .max_tool_result_bytes = tool_result_limits.min_configured_tool_result_bytes,
            .cancel_flag = &cancel,
        },
        toolCall("call_no_save_output", "read_file", "{}"),
        raw,
    );

    try std.testing.expect(prepared.memory.output_handle == null);
    try std.testing.expect(prepared.memory.truncated);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "tool result truncated") != null);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "MY_UNIT_TOKEN=abcdefgh") != null);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "[redacted]") == null);
}

test "saved read_tool_result preparation preserves exact secret-like output" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(result_dir);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    const raw =
        "<command_output_query handle=\"fixture.bin\">\n" ++
        "query: \"TOOL_DATA_TOKEN=\"\n" ++
        "[stdout]\nTOOL_DATA_TOKEN=0123456789abcdef01234567\n[/stdout]\n" ++
        "</command_output_query>";

    const prepared = try prepareToolModelOutput(
        arena,
        .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .agent_step_limit = 1,
            .max_tool_result_bytes = tool_result_limits.default_max_tool_result_bytes,
            .cancel_flag = &cancel,
            .tool_result_dir = result_dir,
        },
        toolCall("read_exact_output", "read_tool_result", "{}"),
        raw,
    );

    try std.testing.expectEqualStrings(raw, prepared.model_output);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "[redacted]") == null);
    try std.testing.expect(!prepared.memory.truncated);
    try std.testing.expect(prepared.memory.output_handle == null);
}

test "retrieved output remains backed across the inline cap" {
    const compaction = @import("context_compaction.zig");
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    var capability = try session_child_store.SessionChildCapability.initLegacyRoute(alloc, dir, .tool_results, .writable);
    defer capability.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    const stores = [_]enum { legacy, managed, unavailable }{ .legacy, .managed, .unavailable };
    const cases = [_]struct { cap: usize, bytes: usize }{
        .{ .cap = 65536, .bytes = 65536 },
        .{ .cap = 65536, .bytes = 65537 },
        .{ .cap = 65536, .bytes = 65689 },
        .{ .cap = 1024, .bytes = 1025 },
    };
    for (stores) |storage| for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const raw = try arena.alloc(u8, case.bytes);
        @memset(raw, 'x');
        const head = "PROBE_TOKEN=0123456789abcdef\n";
        const tail = "\nRETRIEVAL_COMPLETE_TAIL";
        @memcpy(raw[0..head.len], head);
        @memcpy(raw[raw.len - tail.len ..], tail);
        const prepared = try prepareToolModelOutput(arena, .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .agent_step_limit = 1,
            .cancel_flag = &cancel,
            .max_tool_result_bytes = case.cap,
            .tool_result_dir = if (storage == .legacy) dir else null,
            .session_child_capability = if (storage == .managed) &capability else null,
        }, toolCall("retrieval-cap", "read_tool_result", "{}"), raw);
        try std.testing.expectEqual(case.bytes > case.cap, prepared.memory.truncated);
        try std.testing.expectEqual(@min(case.bytes, case.cap), prepared.model_output.len);
        try std.testing.expect(std.mem.startsWith(u8, prepared.model_output, head));
        try std.testing.expect(std.mem.find(u8, prepared.model_output, "[redacted]") == null);
        var messages = [_]ChatMessage{.{ .role = .tool, .tool_call_id = "retrieval-cap", .tool_name = "read_tool_result", .content = prepared.model_output, .tool_result_memory = prepared.memory }};
        if (case.bytes > case.cap and storage != .unavailable) {
            const handle = prepared.memory.output_handle orelse return error.TestExpectedStoredRetrieval;
            try std.testing.expectEqual(case.bytes, prepared.memory.stored_output_bytes);
            const stored = try result_store.readForReplayManaged(arena, &capability, handle, case.bytes);
            try std.testing.expectEqualStrings(raw, stored);
            try compaction.promoteMessageResults(arena, &messages, .{ .managed = &capability }, 0);
            try std.testing.expectEqualStrings(handle, messages[0].tool_result_memory.?.output_handle.?);
        } else {
            try std.testing.expect(prepared.memory.output_handle == null);
            if (case.bytes > case.cap) {
                try std.testing.expectError(error.IncompleteCompactionResult, compaction.promoteMessageResults(arena, &messages, .unavailable, 0));
            } else {
                try std.testing.expectEqualStrings(raw, prepared.model_output);
            }
        }
    };
}

test "retrieved output storage failure does not publish an unbacked result" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    var writable = try session_child_store.SessionChildCapability.initLegacyRoute(alloc, dir, .tool_results, .writable);
    defer writable.deinit();
    var readonly = try session_child_store.SessionChildCapability.initLegacyRoute(alloc, dir, .tool_results, .read_only);
    defer readonly.deinit();
    var cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(error.SessionChildReadOnly, prepareToolModelOutput(alloc, .{
        .system_prompt = "",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .agent_step_limit = 1,
        .cancel_flag = &cancel,
        .max_tool_result_bytes = 1024,
        .session_child_capability = &readonly,
    }, toolCall("retrieval-store-error", "read_tool_result", "{}"), "x" ** 1025));
}

test "saved tool output preparation keeps builtins and dynamic tools compactable" {
    const builtins = @import("../../../builtins/tools.zig");
    const compaction = @import("context_compaction.zig");
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);
    var cancel = std.atomic.Value(bool).init(false);
    for (0..builtins.all.len + 1) |index| {
        const name = if (index < builtins.all.len) builtins.all[index].name else "mcp_fixture_lookup";
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const raw = "COMPLETE_TOOL_BODY\n" ++ "x" ** 8192;
        const prepared = try prepareToolModelOutput(arena, .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .agent_step_limit = 1,
            .cancel_flag = &cancel,
            .max_tool_result_bytes = 1024,
            .tool_result_dir = dir,
        }, toolCall("tool-preparation", name, "{}"), raw);
        const handle = prepared.memory.output_handle orelse return error.TestExpectedStoredOutput;
        try std.testing.expectEqual(raw.len, prepared.memory.stored_output_bytes);
        var messages = [_]ChatMessage{.{ .role = .tool, .tool_call_id = "tool-preparation", .tool_name = name, .content = prepared.model_output, .tool_result_memory = prepared.memory }};
        try compaction.promoteMessageResults(arena, &messages, .{ .legacy_dir = dir }, 0);
        try std.testing.expectEqualStrings(handle, messages[0].tool_result_memory.?.output_handle.?);
        const stored = try result_store.readByRange(arena, dir, handle, 1, 16384);
        try std.testing.expect(std.mem.find(u8, stored, raw) != null);
    }
}

test "saved preparation externalizes complete output verbatim without cap loss" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(result_dir);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    const raw = "AI_GATEWAY_API_KEY=abcdefghijklmnop";

    const prepared = try prepareToolModelOutput(
        arena,
        .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .agent_step_limit = 1,
            .max_tool_result_bytes = tool_result_limits.default_max_tool_result_bytes,
            .cancel_flag = &cancel,
            .tool_result_dir = result_dir,
        },
        toolCall("call_external_output", "read_file", "{}"),
        raw,
    );

    try std.testing.expect(prepared.memory.output_handle != null);
    try std.testing.expectEqualStrings(raw, prepared.memory.preview.?);
    try std.testing.expect(!prepared.memory.truncated);
    try std.testing.expectEqualStrings(raw, prepared.model_output);
}

test "saved inline read retains full file evidence with its external copy" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(result_dir);
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    const call = toolCall("complete-read", "read_file", "{\"path\":\"small.txt\"}");
    var prepared = try prepareToolModelOutput(arena, .{
        .system_prompt = "",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .agent_step_limit = 1,
        .cancel_flag = &cancel,
        .tool_result_dir = result_dir,
    }, call, "all file contents");
    applyToolResultMemory(&prepared.memory, .{ .model_view_covers_full_file = true });
    try std.testing.expect(prepared.memory.output_handle != null);
    try std.testing.expectEqualStrings("all file contents", prepared.model_output);
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{call} },
        .{
            .role = .tool,
            .content = prepared.model_output,
            .tool_call_id = call.id,
            .tool_name = call.name,
            .tool_result_status = .success,
            .tool_result_memory = prepared.memory,
        },
    };
    const execution = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, execution);
    try std.testing.expectEqual(@as(usize, 1), execution.files.len);
    try std.testing.expect(execution.files[0].model_view_covers_full_file);
}

test "common execution memory does not mark stored read previews as full" {
    const session_runtime = @import("../../session/session.zig");
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(result_dir);
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    try raw.appendNTimes(
        alloc,
        'x',
        result_store.large_result_threshold_bytes + 128,
    );
    var cancel_flag = std.atomic.Value(bool).init(false);
    const prepared = try prepareToolModelOutput(
        arena,
        .{
            .system_prompt = "",
            .gateway_retry_count = 0,
            .gateway_chat_url = "",
            .agent_step_limit = 1,
            .cancel_flag = &cancel_flag,
            .tool_result_dir = result_dir,
        },
        toolCall(
            "call_large_read",
            "read_file",
            "{\"path\":\"large.txt\"}",
        ),
        raw.items,
    );
    try std.testing.expect(prepared.memory.output_handle != null);
    try std.testing.expect(prepared.memory.truncated);

    var calls = [_]ToolCall{.{
        .id = "call_large_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"large.txt\"}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{
            .role = .tool,
            .content = prepared.model_output,
            .tool_call_id = "call_large_read",
            .tool_name = "read_file",
            .tool_result_status = .success,
            .tool_result_memory = prepared.memory,
        },
    };

    const execution = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, execution);

    try std.testing.expectEqual(@as(usize, 1), execution.tool_steps.len);
    try std.testing.expect(execution.tool_steps[0].tool_results[0].truncated);
    try std.testing.expectEqual(@as(usize, 1), execution.files.len);
    try std.testing.expect(!execution.files[0].model_view_covers_full_file);

    const replay = try session_runtime.formatExecutionFileContext(alloc, execution.files);
    defer alloc.free(replay);
    try std.testing.expect(std.mem.find(u8, replay, "model_view=full") == null);
}

test "execution memory persists secret argument values verbatim" {
    const alloc = std.testing.allocator;
    const arguments_json = "{\"command\":\"echo ok\",\"api_key\":\"secret-value-123456\"}";
    var calls = [_]ToolCall{.{
        .id = "call_secret",
        .name = "run_command",
        .arguments_json = arguments_json,
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "ok", .tool_call_id = "call_secret", .tool_name = "run_command", .tool_result_status = .success },
    };

    const memory = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, memory);
    try std.testing.expectEqual(@as(usize, 1), memory.tool_steps.len);
    const args = memory.tool_steps[0].tool_calls[0].arguments_json;
    try std.testing.expectEqualStrings(arguments_json, args);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, args, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("secret-value-123456", parsed.value.object.get("api_key").?.string);
    try std.testing.expectEqualStrings("echo ok", parsed.value.object.get("command").?.string);
}

test "execution memory persists credentialed web_fetch url arguments verbatim" {
    const alloc = std.testing.allocator;
    const url = "https://user:pass@example.com/docs?token=querytoken123";
    const arguments_json = "{\"url\":\"https://user:pass@example.com/docs?token=querytoken123\"}";
    var calls = [_]ToolCall{.{
        .id = "call_fetch",
        .name = "web_fetch",
        .arguments_json = arguments_json,
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..] },
        .{ .role = .tool, .content = "Web fetch result.", .tool_call_id = "call_fetch", .tool_name = "web_fetch", .tool_result_status = .success },
    };

    const memory = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, memory);
    const args = memory.tool_steps[0].tool_calls[0].arguments_json;
    try std.testing.expectEqualStrings(arguments_json, args);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, args, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("prompt") == null);
    try std.testing.expectEqualStrings(url, parsed.value.object.get("url").?.string);
}

test "large result storage persists secret-bearing output verbatim in preview and on disk" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(dir);

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    try raw.appendSlice(alloc, "api_key=super-secret-value" ++ "\n");
    try raw.appendNTimes(alloc, 'x', result_store.large_result_threshold_bytes + 64);

    var cancel_flag = std.atomic.Value(bool).init(false);
    const prepared = try prepareToolModelOutput(arena, .{
        .system_prompt = "",
        .gateway_retry_count = 0,
        .gateway_chat_url = "",
        .agent_step_limit = 1,
        .max_tool_result_bytes = tool_result_limits.default_max_tool_result_bytes,
        .cancel_flag = &cancel_flag,
        .tool_result_dir = dir,
    }, toolCall("call_secret_large", "run_command", "{}"), raw.items);

    try std.testing.expect(prepared.memory.output_handle != null);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "api_key=super-secret-value") != null);
    try std.testing.expect(std.mem.find(u8, prepared.model_output, "[redacted]") == null);

    const stored = try result_store.readByRange(alloc, dir, prepared.memory.output_handle.?, 1, 512);
    defer alloc.free(stored);
    try std.testing.expect(std.mem.find(u8, stored, "api_key=super-secret-value") != null);
    try std.testing.expect(std.mem.find(u8, stored, "[redacted]") == null);
}

test "execution memory persists consumed steering without protocol wrappers" {
    const alloc = std.testing.allocator;
    const first = try steeringMessage(alloc, "focus on rendering");
    defer alloc.free(first);
    const second = try steeringMessage(alloc, "run the focused test");
    defer alloc.free(second);
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "ordinary user context" },
        .{ .role = .user, .content = first },
        .{ .role = .assistant, .content = "continuing" },
        .{ .role = .user, .content = second },
    };

    const execution = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, execution);

    try std.testing.expectEqual(@as(usize, 2), execution.steering.len);
    try std.testing.expectEqualStrings("focus on rendering", execution.steering[0].text);
    try std.testing.expectEqualStrings("run the focused test", execution.steering[1].text);
    try std.testing.expectEqual(@as(usize, 0), execution.steering[0].after_tool_step_count);
    try std.testing.expectEqual(@as(usize, 0), execution.steering[1].after_tool_step_count);
}

test "execution memory records each steering tool boundary" {
    const alloc = std.testing.allocator;
    const first_steering = try steeringMessage(alloc, "after first");
    defer alloc.free(first_steering);
    const second_steering = try steeringMessage(alloc, "after second");
    defer alloc.free(second_steering);
    var first_calls = [_]ToolCall{.{
        .id = "call_first",
        .name = "read_file",
        .arguments_json = "{\"path\":\"first\"}",
    }};
    var second_calls = [_]ToolCall{.{
        .id = "call_second",
        .name = "read_file",
        .arguments_json = "{\"path\":\"second\"}",
    }};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &first_calls },
        .{ .role = .tool, .content = "first result", .tool_call_id = "call_first", .tool_name = "read_file", .tool_result_status = .success },
        .{ .role = .user, .content = first_steering },
        .{ .role = .assistant, .tool_calls = &second_calls },
        .{ .role = .tool, .content = "second result", .tool_call_id = "call_second", .tool_name = "read_file", .tool_result_status = .success },
        .{ .role = .user, .content = second_steering },
    };

    const execution = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, execution);

    try std.testing.expectEqual(@as(usize, 2), execution.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 2), execution.steering.len);
    try std.testing.expectEqualStrings("after first", execution.steering[0].text);
    try std.testing.expectEqual(@as(usize, 1), execution.steering[0].after_tool_step_count);
    try std.testing.expectEqualStrings("after second", execution.steering[1].text);
    try std.testing.expectEqual(@as(usize, 2), execution.steering[1].after_tool_step_count);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const boundary = CompactedExecutionBoundary{ .tool_steps = 1, .steering = 1 };
    const remaining = try boundary.project(arena.allocator(), execution);
    try std.testing.expectEqual(@as(usize, 1), remaining.tool_steps.len);
    try std.testing.expectEqualStrings("call_second", remaining.tool_steps[0].tool_calls[0].id);
    try std.testing.expectEqual(@as(usize, 1), remaining.steering.len);
    try std.testing.expectEqualStrings("after second", remaining.steering[0].text);
    try std.testing.expectEqual(@as(usize, 1), remaining.steering[0].after_tool_step_count);
    try std.testing.expectEqual(@as(usize, 2), remaining.files.len);
    try std.testing.expect(remaining.files.ptr == execution.files.ptr);
    try std.testing.expectEqual(@as(usize, 2), execution.steering[1].after_tool_step_count);
}

test "transcript does not mark native web_search as provider resource placeholder" {
    const alloc = std.testing.allocator;
    const record = try execution_memory_helpers.makePersistedToolResult(
        alloc,
        "call_search",
        "web_search",
        .success,
        "bounded search output",
        null,
    );
    const records = try alloc.alloc(types.PersistedToolResult, 1);
    records[0] = record;
    defer types.freePersistedToolResults(alloc, records);

    try std.testing.expect(!records[0].provider_native);
    try std.testing.expectEqualStrings("bounded search output", records[0].output);
}
