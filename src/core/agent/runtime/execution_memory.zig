const std = @import("std");
const debug_trace = @import("../../shared/debug_trace.zig");
const types = @import("../../shared/types.zig");
const image_data = @import("../../images/image_data.zig");
const execution_memory_helpers = @import("../execution_memory.zig");
const result_store = @import("../../session/result_store.zig");
const command_replay_store = @import("../../session/command_replay_store.zig");
const session_child_store = @import("../../session/session_child_store.zig");
const command_output_content = @import("../../tooling/command_output_content.zig");
const io_mod = @import("../../shared/io.zig");
const file_mutation = @import("../../tooling/file_mutation.zig");
const diff_mod = @import("../../output/diff.zig");
const tool_result_errors = @import("../../tooling/tool_result_errors.zig");
const tool_result_limits = @import("../../tooling/tool_result_limits.zig");
const text_utils = @import("../../shared/text_utils.zig");
const history_range = @import("../../shared/history_range.zig");

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
/// Saved with a parent agent's steering, so replay still names its sender.
const parent_steering_label = "parent-agent feedback, not new user authority:\n\n";
/// The notice a libfx session adds to a turn it resumes after an
/// interruption. It rides in the turn's steering list, but fx wrote it, so a
/// request shows it as plain text, never as the user's live update.
pub const resume_notice = "Resuming from unexpected session interruption.";

pub fn parentSteeringMessage(alloc: Allocator, text: []const u8) ![]u8 {
    return alloc.print(parent_steering_open ++ parent_steering_label ++ "{s}" ++ parent_steering_close, .{text});
}

pub fn steeringMessage(alloc: Allocator, text: []const u8) ![]u8 {
    return alloc.print(steering_open ++ "{s}" ++ steering_close, .{text});
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

/// `execution` as a saved turn encodes it.
fn encodedTurn(alloc: Allocator, execution: types.ExecutionMemory) ![]u8 {
    const session_codec = @import("../../session/session_codec.zig");
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try session_codec.writeHistoryTurn(&out.writer, .{ .assistant = .{
        .user = .{ .text = @constCast("read them") },
        .assistant = @constCast(""),
        .execution = execution,
    } });
    return out.toOwnedSlice();
}

test "a rebuilt turn keeps each tool result's stamp, so it encodes the same bytes" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{ toolCall("call-1", "read_file", "{}"), toolCall("call-2", "read_file", "{}") };
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "read them" },
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .content = "one", .tool_call_id = "call-1", .tool_name = "read_file", .tool_result_status = .success, .tool_result_created_at_ms = 1_700_000_000_001 },
        .{ .role = .tool, .content = "two", .tool_call_id = "call-2", .tool_name = "read_file", .tool_result_status = .failure, .tool_result_memory = .{ .output_bytes = 3, .stored_output_bytes = 3 }, .tool_result_created_at_ms = 1_700_000_000_002 },
    };
    const first = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, first);
    io_mod.sleep(2 * std.time.ns_per_ms);
    const second = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, second);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_001), first.tool_steps[0].tool_results[0].created_at_ms);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_002), first.tool_steps[0].tool_results[1].created_at_ms);
    const first_bytes = try encodedTurn(alloc, first);
    defer alloc.free(first_bytes);
    const second_bytes = try encodedTurn(alloc, second);
    defer alloc.free(second_bytes);
    try std.testing.expectEqualStrings(first_bytes, second_bytes);
}

test "a tool result without a usable stamp is stamped when rebuilt, as before" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{ toolCall("none", "read_file", "{}"), toolCall("zero", "read_file", "{}"), toolCall("negative", "read_file", "{}") };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &calls },
        .{ .role = .tool, .content = "a", .tool_call_id = "none", .tool_name = "read_file", .tool_result_status = .success },
        .{ .role = .tool, .content = "b", .tool_call_id = "zero", .tool_name = "read_file", .tool_result_status = .success, .tool_result_created_at_ms = 0 },
        .{ .role = .tool, .content = "c", .tool_call_id = "negative", .tool_name = "read_file", .tool_result_status = .success, .tool_result_created_at_ms = -5 },
    };
    const before = io_mod.milliTimestamp();
    const rebuilt = try buildExecutionMemory(alloc, &messages);
    defer types.freeExecutionMemory(alloc, rebuilt);
    for (rebuilt.tool_steps[0].tool_results) |result| try std.testing.expect(result.created_at_ms >= before);
}

test "a turn resumed from its checkpoint keeps each result's stamp" {
    const alloc = std.testing.allocator;
    const session = @import("../../session/session.zig");
    var calls = [_]ToolCall{ toolCall("kept", "read_file", "{}"), toolCall("unstamped", "read_file", "{}") };
    var results = [_]types.PersistedToolResult{
        .{ .tool_call_id = @constCast("kept"), .tool_name = @constCast("read_file"), .status = .success, .output = @constCast("ok"), .output_bytes = 2, .stored_output_bytes = 2, .created_at_ms = 1_700_000_000_123 },
        .{ .tool_call_id = @constCast("unstamped"), .tool_name = @constCast("read_file"), .status = .success, .output = @constCast("ok"), .output_bytes = 2, .stored_output_bytes = 2 },
    };
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(alloc);
    try session.appendExecutionMemoryChatMessages(alloc, &messages, .{ .tool_steps = &steps });
    const tool_messages = messages.items[messages.items.len - 2 ..];
    try std.testing.expectEqual(@as(?i64, 1_700_000_000_123), tool_messages[0].tool_result_created_at_ms);
    // A result saved without a time gets one when the turn is rebuilt.
    try std.testing.expectEqual(@as(?i64, null), tool_messages[1].tool_result_created_at_ms);
    const rebuilt = try buildExecutionMemory(alloc, messages.items);
    defer types.freeExecutionMemory(alloc, rebuilt);
    try std.testing.expectEqual(@as(i64, 1_700_000_000_123), rebuilt.tool_steps[0].tool_results[0].created_at_ms);
    try std.testing.expect(rebuilt.tool_steps[0].tool_results[1].created_at_ms > 0);
}

test "rebuilt tool results keep the times their messages carry" {
    try std.testing.fuzz({}, fuzzStableStamps, .{
        .corpus = &(@import("fuzz_seed").slices(.{
            "",
            // Two steps of three and two calls, each result with a time.
            "\x02\x02\x05\x00\x00\x00\x00\x00\x00\x10\x01\x01\x05\x05\x00\x00\x00\x00\x00\x00\x20\x02\x02\x09\x01\x01\x04\x00\x00\x00\x00\x00\x00\x30\x03\x03\x05",
            // One call each with no stamp, a zero, and a negative one.
            "\x01\x02\x00\x01\x01\x02\x01\x02\x02\x02\x00\x00\x00\x00\x00\x00\x07\x00\x03\x03",
            "contents",
            "{\"created_at_ms\":1,\"nested\":{\"created_at_ms\":2}}",
            "quotes \" and \\ and \x01 and \xff\xfe and caf\xc3\xa9 \xe4\xb8\xad",
        }) ++ @import("fuzz_corpus").stable_tool_result_stamps.*),
    });
}

/// The fuzz input read as a plan, a byte at a time, and as zeros once it
/// ends, so every seed of `fuzz_seed.slices` describes a whole turn.
const FuzzPlan = struct {
    bytes: []const u8,
    at: usize = 0,

    fn byte(self: *FuzzPlan) u8 {
        if (self.at >= self.bytes.len) return 0;
        defer self.at += 1;
        return self.bytes[self.at];
    }

    fn below(self: *FuzzPlan, n: u8) u8 {
        return self.byte() % n;
    }

    /// A positive time from the next eight bytes.
    fn time(self: *FuzzPlan) i64 {
        var value: u64 = 0;
        for (0..8) |_| value = (value << 8) | self.byte();
        return @intCast(@max(1, value >> 1));
    }

    /// A piece of the input itself, as a result's text.
    fn text(self: *FuzzPlan) []const u8 {
        const start = self.byte() % (self.bytes.len + 1);
        const end = start + self.byte() % (self.bytes.len - start + 1);
        return self.bytes[start..end];
    }
};

/// Builds a turn of fuzzed tool steps whose results carry fuzzed stamps,
/// some missing or not a time, and requires each of two rebuilds, and the
/// rebuild of the turn resumed from its own execution as a checkpoint
/// resumes it, to give every result the stamp its message carries. A turn
/// whose every result carries one encodes the same bytes each time.
fn fuzzStableStamps(_: void, smith: *std.testing.Smith) !void {
    const session = @import("../../session/session.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var input: [512]u8 = undefined;
    var plan: FuzzPlan = .{ .bytes = input[0..smith.slice(&input)] };

    var messages: std.ArrayList(ChatMessage) = .empty;
    try messages.append(a, .{ .role = .user, .content = "read them" });
    var expected: std.ArrayList(?i64) = .empty;
    var all_stamped = true;
    for (0..plan.below(6)) |step| {
        const calls = try a.alloc(ToolCall, 1 + plan.below(3));
        for (calls, 0..) |*call, index| call.* = toolCall(try a.print("call-{d}-{d}", .{ step, index }), "read_file", "{}");
        try messages.append(a, .{ .role = .assistant, .tool_calls = calls });
        for (calls) |call| {
            const stamp: ?i64 = switch (plan.below(6)) {
                0 => null,
                1 => 0,
                2 => -plan.time(),
                else => plan.time(),
            };
            const usable: ?i64 = if (stamp) |value| (if (value > 0) value else null) else null;
            all_stamped = all_stamped and usable != null;
            try expected.append(a, usable);
            const flags = plan.byte();
            const content = plan.text();
            try messages.append(a, .{
                .role = .tool,
                .content = content,
                .tool_call_id = call.id,
                .tool_name = call.name,
                .tool_result_status = if (flags & 1 == 0) .success else .failure,
                .tool_result_memory = if (flags & 2 == 0) null else .{ .output_bytes = content.len, .stored_output_bytes = content.len },
                .tool_result_created_at_ms = stamp,
            });
        }
    }

    const first = try buildExecutionMemory(a, messages.items);
    const second = try buildExecutionMemory(a, messages.items);
    var index: usize = 0;
    for (first.tool_steps, second.tool_steps) |one, two| {
        for (one.tool_results, two.tool_results) |x, y| {
            if (expected.items[index]) |stamp| {
                try std.testing.expectEqual(stamp, x.created_at_ms);
                try std.testing.expectEqual(stamp, y.created_at_ms);
            }
            index += 1;
        }
    }
    try std.testing.expectEqual(expected.items.len, index);
    if (all_stamped) try std.testing.expectEqualStrings(try encodedTurn(a, first), try encodedTurn(a, second));

    var resumed: std.ArrayList(ChatMessage) = .empty;
    try resumed.append(a, .{ .role = .user, .content = "read them" });
    try session.appendExecutionMemoryChatMessages(a, &resumed, first);
    const third = try buildExecutionMemory(a, resumed.items);
    try std.testing.expectEqual(first.tool_steps.len, third.tool_steps.len);
    for (first.tool_steps, third.tool_steps) |one, three| {
        try std.testing.expectEqual(one.tool_results.len, three.tool_results.len);
        for (one.tool_results, three.tool_results) |x, z| try std.testing.expectEqual(x.created_at_ms, z.created_at_ms);
    }
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

    /// Borrows execution payloads; only the rebased steering and context note
    /// slices use arena.
    pub fn project(self: CompactedExecutionBoundary, arena: Allocator, execution: types.ExecutionMemory) !types.ExecutionMemory {
        std.debug.assert(self.tool_steps <= execution.tool_steps.len);
        std.debug.assert(self.steering <= execution.steering.len);
        var projected = execution;
        projected.tool_steps = execution.tool_steps[self.tool_steps..];
        projected.steering = execution.steering[self.steering..];
        const covered_notes = history_range.coveredContextNotes(execution, self.tool_steps, self.steering);
        projected.context_notes = try history_range.rebasedContextNotes(arena, execution.context_notes[covered_notes..], self.tool_steps);
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
    var context_notes: std.ArrayList(types.PersistedContextNote) = .empty;
    errdefer {
        for (context_notes.items) |item| types.freePersistedContextNote(alloc, item);
        context_notes.deinit(alloc);
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
        if (isContextNote(message)) {
            // fx places a note only at a step boundary, so the steps before
            // it are complete (D93). A note may save a shorter text than it
            // sends (D95).
            const copy = try alloc.dupe(u8, message.context_note_saved_text orelse message.content orelse "");
            errdefer alloc.free(copy);
            const sources = try types.dupeNoteSources(alloc, message.context_note_sources);
            context_notes.append(alloc, .{ .text = copy, .after_tool_step_count = tool_step_count, .sources = sources }) catch |err| {
                types.freeNoteSources(alloc, sources);
                return err;
            };
            continue;
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
    execution.context_notes = try context_notes.toOwnedSlice(alloc);
    return execution;
}

fn isContextNote(message: ChatMessage) bool {
    return message.role == .system and message.context_note;
}

fn startsPersistedToolStep(messages: []const ChatMessage, assistant_index: usize) bool {
    const assistant = messages[assistant_index];
    if (assistant.role != .assistant) return false;
    if (assistant.tool_calls.len == 0) return assistant.provider_replay != null or assistant.standalone_response;
    var result_index = assistant_index + 1;
    // A note never ends a step's results (D93).
    while (result_index < messages.len and (messages[result_index].role == .tool or isContextNote(messages[result_index]))) : (result_index += 1) {
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
    // The notes that end the messages sit at the cut's own boundary with no
    // steering after them, so the cut keeps them, as
    // `history_range.coveredContextNotes` counts for the saved turn (D93).
    var kept_notes_start = messages.len;
    while (kept_notes_start > 0 and isContextNote(messages[kept_notes_start - 1])) kept_notes_start -= 1;
    return kept_notes_start;
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

/// The request copy of `messages`, with each steering message a saved turn
/// restored back in the envelope the model saw when the turn took it. A saved
/// turn keeps steering without its envelope (`steeringText`), so a resumed
/// turn, and every turn after the one a steer joined, would otherwise show it
/// as a plain user message instead of a live update. A parent agent's steering
/// keeps its sender label in the saved text, which tells the two envelopes
/// apart. Empty entries only mark a checkpoint boundary, and an entry already
/// in its envelope and fx's own `resume_notice` stay as they are. Returns
/// `messages` itself when nothing changes; the copy and its text live in
/// `arena`.
pub fn rewrapRestoredSteering(arena: Allocator, messages: []const ChatMessage) Allocator.Error![]const ChatMessage {
    var result: ?[]ChatMessage = null;
    for (messages, 0..) |message, index| {
        if (!message.restored_steering) continue;
        const text = message.content orelse continue;
        if (text.len == 0 or steeringText(text) != null or std.mem.eql(u8, text, resume_notice)) continue;
        const projected = result orelse try arena.dupe(ChatMessage, messages);
        result = projected;
        projected[index].content = if (std.mem.startsWith(u8, text, parent_steering_label))
            try std.mem.concat(arena, u8, &.{ parent_steering_open, text, parent_steering_close })
        else
            try steeringMessage(arena, text);
    }
    return result orelse messages;
}

test "restored steering reaches the request in the envelope the model saw" {
    const alloc = std.testing.allocator;
    const session = @import("../../session/session.zig");
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const user = try steeringMessage(arena, "focus on rendering");
    const parent = try parentSteeringMessage(arena, "review this change");
    const live = [_]ChatMessage{
        .{ .role = .user, .content = user },
        .{ .role = .user, .content = parent },
    };
    const memory = try buildExecutionMemory(alloc, &live);
    defer types.freeExecutionMemory(alloc, memory);
    // A saved turn comes back as steering's bare text, flagged as steering.
    var restored: std.ArrayList(ChatMessage) = .empty;
    try session.appendExecutionMemoryChatMessages(arena, &restored, memory);
    try std.testing.expectEqual(@as(usize, 2), restored.items.len);
    try std.testing.expect(restored.items[0].restored_steering and steeringText(restored.items[0].content.?) == null);

    const projected = try rewrapRestoredSteering(arena, restored.items);
    try std.testing.expectEqualStrings(user, projected[0].content.?);
    try std.testing.expectEqualStrings(parent, projected[1].content.?);
    // The session's own messages keep the bare text a saved turn holds.
    try std.testing.expectEqualStrings("focus on rendering", restored.items[0].content.?);

    // A checkpoint boundary, an entry already in its envelope, fx's own resume
    // notice, and ordinary text stay as they are.
    const unchanged = [_]ChatMessage{
        .{ .role = .user, .content = "", .restored_steering = true },
        .{ .role = .user, .content = user, .restored_steering = true },
        .{ .role = .user, .content = resume_notice, .restored_steering = true },
        .{ .role = .user, .content = "plain prompt" },
    };
    try std.testing.expect((try rewrapRestoredSteering(arena, &unchanged)).ptr == (&unchanged).ptr);
}

/// Steering the user typed during the turn, which a cancelled turn keeps.
fn isSteering(message: ChatMessage) bool {
    if (message.restored_steering) return true;
    const content = message.content orelse return false;
    return steeringText(content) != null;
}

fn steeringText(content: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, content, parent_steering_open) and std.mem.endsWith(u8, content, parent_steering_close)) {
        // Keep the sender label in persisted text and ordinary history replay.
        return content[parent_steering_open.len .. content.len - parent_steering_close.len];
    }
    if (!std.mem.startsWith(u8, content, steering_open) or !std.mem.endsWith(u8, content, steering_close)) return null;
    return content[steering_open.len .. content.len - steering_close.len];
}

/// Which steering and feedback a cancelled turn keeps is modeled in
/// `tests/tla/session_manager/rollout/pr-1092/PR1092Steering.tla`.
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
        // A note at the step's boundary does not end the feedback after it.
        while (user_tail_end < current_turn_messages.len and
            (current_turn_messages[user_tail_end].role == .user or isContextNote(current_turn_messages[user_tail_end]))) : (user_tail_end += 1)
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
                if (isContextNote(entry)) {
                    filtered.appendAssumeCapacity(entry);
                    continue;
                }
                if (!entry.permission_feedback and !isSteering(entry)) continue;
                if (entry.tool_call_id) |source_tool_call_id| {
                    if (execution_memory_helpers.findToolCallById(calls, source_tool_call_id) == null) {
                        continue;
                    }
                }
                filtered.appendAssumeCapacity(entry);
            }
        } else for (user_tail) |entry| {
            // The step leaves without a result; a note after it stays, at
            // the boundary before that step.
            if (isContextNote(entry)) filtered.appendAssumeCapacity(entry);
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

test "interrupted execution memory keeps steering typed right after a tool result" {
    const alloc = std.testing.allocator;
    var calls = [_]ToolCall{
        .{ .id = "call_done", .name = "subagent", .arguments_json = "{\"request\":{\"action\":\"run\",\"task\":\"work\"}}" },
        .{ .id = "call_active", .name = "read_file", .arguments_json = "{\"path\":\"a.txt\"}" },
    };
    const steering = try steeringMessage(alloc, "check the tests too");
    defer alloc.free(steering);
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..1] },
        .{ .role = .tool, .content = "child is still running", .tool_call_id = calls[0].id, .tool_name = calls[0].name, .tool_result_status = .success },
        .{ .role = .user, .content = steering },
        .{ .role = .user, .content = "custom hint", .permission_feedback = false },
        .{ .role = .assistant, .content = "on it" },
        .{ .role = .assistant, .tool_calls = calls[1..2] },
    };

    const memory = try buildInterruptedExecutionMemory(alloc, &messages, calls[1]);
    defer types.freeExecutionMemory(alloc, memory);

    // The cancelled turn keeps what the user typed, after the step it
    // followed; an unmarked plain message still stays out.
    try std.testing.expectEqual(@as(usize, 1), memory.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 1), memory.steering.len);
    try std.testing.expectEqualStrings("check the tests too", memory.steering[0].text);
    try std.testing.expectEqual(@as(usize, 1), memory.steering[0].after_tool_step_count);
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

/// Retains the original tool images so later requests can project a safe view.
pub fn retainToolImages(arena: Allocator, config: Config, call: ToolCall, prepared: *result_store.PreparedResult) !void {
    const memory = &prepared.memory;
    if (memory.tool_images.len == 0 or memory.tool_image_handle != null) return;
    const capability = config.session_child_capability orelse return;
    const handle = result_store.storeToolImages(arena, capability, call.id, call.name, memory.tool_images) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        debug_trace.logf("session", "tool images remain inline because artifact storage failed call_id={s} err={s}", .{ call.id, @errorName(err) });
        return;
    };
    memory.tool_image_handle = handle;
    const notice = try arena.print("Saved images: {s}. Use read_tool_result with this handle to load them again.\n", .{handle});
    const limit = config.max_tool_result_bytes -| notice.len;
    const keep = @import("../../config/context_limits.zig").utf8PrefixLength(prepared.model_output, limit);
    if (keep < prepared.model_output.len) memory.truncated = true;
    prepared.model_output = try std.mem.concat(arena, u8, &.{ notice, prepared.model_output[0..keep] });
}

fn needsImageMaterialization(messages: []const ChatMessage) bool {
    for (messages) |message| {
        const memory = message.tool_result_memory orelse continue;
        if (memory.tool_images.len == 0 and memory.tool_image_handle != null) return true;
    }
    return false;
}

/// Loads stored tool images for a request without changing session history.
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
                    const notice = try arena.print("[Stored tool image unavailable: {s}]\n", .{@errorName(err)});
                    message.content = try prependImageNotice(arena, notice, message.content orelse "", config.max_tool_result_bytes);
                    continue;
                };
            }
        }
    }
    return materialized;
}

fn requestToolImageFits(image: types.ToolImage, max_dimension: u32) bool {
    const dimensions = image_data.encodedImageDimensions(image.data) orelse return false;
    return !dimensions.exceeds(max_dimension) and
        image.data.len <= image_data.max_encoded_image_bytes and
        image_data.supportedMediaType(image.mime_type);
}

/// Builds a safe request view without changing the tool images saved in history.
pub fn withholdRequestToolImages(arena: Allocator, messages: []const ChatMessage, max_dimension: u32, text_limit: usize) ![]const ChatMessage {
    var projected: ?[]ChatMessage = null;
    for (messages, 0..) |message, index| {
        const memory = message.tool_result_memory orelse continue;
        const has_unsafe = for (memory.tool_images) |image| {
            if (!requestToolImageFits(image, max_dimension)) break true;
        } else false;
        if (!has_unsafe) continue;
        var kept: std.ArrayList(types.ToolImage) = try .initCapacity(arena, memory.tool_images.len);
        var notice: std.Io.Writer.Allocating = .init(arena);
        for (memory.tool_images) |image| {
            if (requestToolImageFits(image, max_dimension)) {
                kept.appendAssumeCapacity(image);
                continue;
            }
            const dimensions = image_data.encodedImageDimensions(image.data);
            if (dimensions) |size| {
                try notice.writer.print("[Image not sent: {s} is {d}x{d} pixels; this request permits at most {d} per side and 5 MiB encoded per image. ", .{ image.mime_type, size.width, size.height, max_dimension });
            } else if (image.source_ref != null and image.data.len == 0) {
                try notice.writer.print("[Image not sent: only a host source reference was supplied; this request permits at most {d} per side and 5 MiB encoded per image. ", .{max_dimension});
            } else {
                try notice.writer.writeAll("[Image not sent: its dimensions could not be verified. ");
            }
            if (image.source_ref) |source_ref| {
                try image_data.writeHostImageRecoveryNotice(&notice.writer, source_ref, max_dimension);
            } else {
                try notice.writer.writeAll("If this tool result names a local file, use an available image tool to save a smaller copy, then read_file the copy. If no tool or path is available, ask the user; ask before installing software.]\n");
            }
        }
        if (kept.items.len == memory.tool_images.len) continue;
        const output = projected orelse try arena.dupe(ChatMessage, messages);
        projected = output;
        output[index].tool_result_memory.?.tool_images = kept.items;
        output[index].content = try prependImageNotice(arena, notice.written(), message.content orelse "", text_limit);
    }
    return projected orelse messages;
}

fn prependImageNotice(alloc: Allocator, notice: []const u8, content: []const u8, limit: usize) Allocator.Error![]u8 {
    const utf8_prefix_length = @import("../../config/context_limits.zig").utf8PrefixLength;
    const notice_keep = utf8_prefix_length(notice, limit);
    const keep = utf8_prefix_length(content, limit -| notice.len);
    return std.mem.concat(alloc, u8, &.{ notice[0..notice_keep], content[0..keep] });
}

fn testEncodedToolImage(arena: Allocator, bytes: []const u8, mime_type: []const u8) !types.ToolImage {
    const encoded = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return .{ .data = encoded, .mime_type = try arena.dupe(u8, mime_type) };
}

fn testPngHeaderToolImage(arena: Allocator, width: u32, height: u32) !types.ToolImage {
    return testEncodedToolImage(arena, &image_data.testPngHeader(width, height), "image/png");
}

fn testJpegHeaderToolImage(arena: Allocator, width: u16, height: u16) !types.ToolImage {
    return testEncodedToolImage(arena, &image_data.testJpeg(width, height), "image/jpeg");
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

test "request projection withholds unsafe tool images without changing history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const images = [_]types.ToolImage{
        try testPngHeaderToolImage(arena, 3420, 2224),
        try testJpegHeaderToolImage(arena, 8001, 1),
        try testPngHeaderToolImage(arena, 1, 1),
    };
    const messages = [_]ChatMessage{.{ .role = .tool, .content = "<path>frame.png</path>", .tool_result_memory = .{ .tool_images = &images } }};
    const normal = try withholdRequestToolImages(arena, &messages, 8000, 4096);
    try std.testing.expectEqual(@as(usize, 2), normal[0].tool_result_memory.?.tool_images.len);
    const strict = try withholdRequestToolImages(arena, &messages, 2000, 4096);
    try std.testing.expectEqual(@as(usize, 1), strict[0].tool_result_memory.?.tool_images.len);
    try std.testing.expect(std.mem.find(u8, strict[0].content.?, "<path>frame.png</path>") != null);
    try std.testing.expectEqual(@as(usize, 3), messages[0].tool_result_memory.?.tool_images.len);
}

test "retaining tool results leaves original images in history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var cancel = std.atomic.Value(bool).init(false);
    const images = [_]types.ToolImage{try testPngHeaderToolImage(arena, 3420, 2224)};
    var prepared = result_store.PreparedResult{ .model_output = "source <path>frame.png</path>", .memory = .{ .tool_images = &images } };
    try retainToolImages(arena, testImageConfig(&cancel), toolCall("call_frame", "read_file", "{}"), &prepared);
    try std.testing.expectEqual(@as(usize, 1), prepared.memory.tool_images.len);
    try std.testing.expectEqualStrings(images[0].data, prepared.memory.tool_images[0].data);
    try std.testing.expectEqualStrings("source <path>frame.png</path>", prepared.model_output);
}

test "request image notices remain bounded without mutating retained text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const images = [_]types.ToolImage{try testJpegHeaderToolImage(arena, 8001, 1)};
    const content = try arena.alloc(u8, 2048);
    @memset(content, 'x');
    const messages = [_]ChatMessage{.{ .role = .tool, .content = content, .tool_result_memory = .{ .tool_images = &images } }};
    const projected = try withholdRequestToolImages(arena, &messages, 8000, 512);
    try std.testing.expect(projected[0].content.?.len <= 512);
    try std.testing.expect(std.mem.startsWith(u8, projected[0].content.?, "[Image not sent:"));
    try std.testing.expectEqual(@as(usize, 0), projected[0].tool_result_memory.?.tool_images.len);
    try std.testing.expectEqual(@as(usize, 2048), messages[0].content.?.len);
}

test "request image notices preserve UTF-8 at every byte limit" {
    const alloc = std.testing.allocator;
    const content = "é界𐐀 tail";
    for ([_][]const u8{ "", "ASCII ", "é", "界", "𐐀" }) |notice| {
        const full = try std.mem.concat(alloc, u8, &.{ notice, content });
        defer alloc.free(full);
        for (0..full.len + 1) |limit| {
            const output = try prependImageNotice(alloc, notice, content, limit);
            defer alloc.free(output);
            try std.testing.expect(output.len <= limit);
            try std.testing.expect(std.unicode.utf8ValidateSlice(output));
            if (limit == full.len) try std.testing.expectEqualStrings(full, output);
        }
    }
}

test "request image notices keep clipped source references as JSON text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source_ref = text_utils.repeat("é", 256);
    var image = try testPngHeaderToolImage(arena, 8001, 1);
    image.source_ref = try arena.dupe(u8, source_ref);
    const images = [_]types.ToolImage{ image, image };
    const content = "original tool output";
    const messages = [_]ChatMessage{.{ .role = .tool, .content = content, .tool_result_memory = .{ .tool_images = &images } }};
    const projected = try withholdRequestToolImages(arena, &messages, 8000, 1079);
    const output = projected[0].content.?;
    try std.testing.expect(output.len <= 1079);
    try std.testing.expect(std.unicode.utf8ValidateSlice(output));
    try std.testing.expect(std.mem.find(u8, output, source_ref) != null);
    try std.testing.expectEqual(@as(usize, 0), projected[0].tool_result_memory.?.tool_images.len);
    try std.testing.expectEqual(@as(usize, 2), messages[0].tool_result_memory.?.tool_images.len);
    try std.testing.expectEqualStrings(content, messages[0].content.?);
    for (messages[0].tool_result_memory.?.tool_images) |retained| {
        try std.testing.expectEqualStrings(source_ref, retained.source_ref.?);
        try std.testing.expectEqualStrings(image.data, retained.data);
    }

    var writer: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(output, .{}, &writer.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, writer.written(), .{});
    try std.testing.expect(parsed.value == .string);
    try std.testing.expectEqualStrings(output, parsed.value.string);
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

/// Text budget for the full-diff rows a committed file presentation keeps for
/// a resumed session. Every history copy, recovery checkpoint, and saved turn
/// carries these rows, and they grow with the change, not the file. The
/// budget only bounds diffs as large as a whole rewritten file: 4 MiB keeps
/// every row of any write the former 4 MiB file limit allowed.
const max_captured_review_bytes: usize = 4 * 1024 * 1024;

/// The full-diff rows a resumed session shows for `handoff`, or null when
/// the handoff has no full view or the review cannot be indexed. Caller owns
/// the rows.
fn captureReviewLines(
    alloc: Allocator,
    handoff: file_mutation.CommittedFileHandoff,
) Allocator.Error!?[]types.CommittedFilePresentationLine {
    const full_view = handoff.full_view orelse return null;
    const captured = diff_mod.captureReviewLines(
        alloc,
        handoff.tracker.previous_content,
        full_view.after_content,
        max_captured_review_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ArithmeticOverflow => {
            debug_trace.logf(
                "session",
                "committed file review rows unavailable call_id={s} err={s}; resumed view keeps the preview",
                .{ full_view.lifecycle_id.call_id, @errorName(err) },
            );
            return null;
        },
    };
    if (captured.omitted_rows > 0) {
        debug_trace.logf(
            "session",
            "committed file review rows truncated call_id={s} kept_rows={d} omitted_rows={d} budget_bytes={d}",
            .{ full_view.lifecycle_id.call_id, captured.rows.len - 1, captured.omitted_rows, max_captured_review_bytes },
        );
    }
    return captured.rows;
}

/// Projects a committed file change for history and resume. The full diff is
/// kept as its rendered rows, never as the file snapshots behind them.
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
            .kind = diff_mod.presentationLineKind(line.op),
            .old_line = line.old_line,
            .new_line = line.new_line,
            // Saved text must be valid UTF-8; see `text_utils.dupeValidUtf8`.
            .text = try text_utils.dupeValidUtf8(alloc, line.text),
        };
        copied_lines += 1;
    }
    const review_lines = try captureReviewLines(alloc, handoff);
    errdefer if (review_lines) |rows| types.freeCommittedFilePresentationLines(alloc, rows);
    // The lifecycle id names the full diff, so it exists only with the rows.
    const lifecycle_id: ?types.ToolLifecycleId = if (review_lines != null) .{
        .turn_id = handoff.full_view.?.lifecycle_id.turn_id,
        .call_id = try alloc.dupe(u8, handoff.full_view.?.lifecycle_id.call_id),
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
        .lifecycle_id = lifecycle_id,
        .review_lines = review_lines,
    };
}

fn testCommittedEditHandoff(
    previous_content: []const u8,
    after_content: []const u8,
) file_mutation.CommittedFileHandoff {
    return .{
        .preview = .{
            .path = "pnpm-lock.yaml",
            .lines = &.{
                .{ .op = .deletion, .old_line = 1, .text = "before" },
                .{ .op = .addition, .new_line = 1, .text = "after" },
            },
            .additions = 1,
            .deletions = 1,
            .truncated = false,
        },
        .tracker = .{
            .kind = .edit,
            .raw_path = "pnpm-lock.yaml",
            .previous_content = previous_content,
            .committed_at_ms = 1,
        },
        .full_view = .{
            .after_content = after_content,
            .lifecycle_id = .{ .turn_id = 7, .call_id = "edit_1" },
        },
    };
}

fn testLockfile(alloc: Allocator, line_count: usize, changed: ?usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (0..line_count) |index| {
        if (changed == index) {
            try out.print(alloc, "  resolution: {{integrity: sha512-{d}}}\n", .{index});
        } else {
            try out.print(alloc, "  resolution: {{tarball: https://example.com/{d}.tgz}}\n", .{index});
        }
    }
    return out.toOwnedSlice(alloc);
}

test "committed file presentation keeps the full diff as rows, never file snapshots" {
    const alloc = std.testing.allocator;
    const previous = try testLockfile(alloc, 50_000, null);
    defer alloc.free(previous);
    const after = try testLockfile(alloc, 50_000, 25_000);
    defer alloc.free(after);

    const presentation = try captureCommittedFilePresentation(
        alloc,
        testCommittedEditHandoff(previous, after),
    );
    defer types.freeCommittedFilePresentation(alloc, presentation);

    try std.testing.expect(presentation.previous_content == null);
    try std.testing.expect(presentation.after_content == null);
    try std.testing.expect(presentation.content_handle == null);
    try std.testing.expect(types.committedFilePresentationContentSourceValid(presentation));
    try std.testing.expectEqual(@as(u64, 7), presentation.lifecycle_id.?.turn_id);
    try std.testing.expectEqualStrings("edit_1", presentation.lifecycle_id.?.call_id);

    // One changed line keeps an elision, five context lines on each side, the
    // replacement pair, and a closing elision, whatever the file's size.
    const rows = presentation.review_lines.?;
    try std.testing.expectEqual(@as(usize, 14), rows.len);
    var row_bytes: usize = 0;
    for (rows) |row| row_bytes += row.text.len;
    try std.testing.expect(row_bytes < 1024);
    try std.testing.expectEqualStrings("24995 unchanged lines ⋯", rows[0].text);
    try std.testing.expectEqual(types.CommittedFilePresentationLineKind.deletion, rows[6].kind);
    try std.testing.expectEqual(@as(?u32, 25_001), rows[6].old_line);
    try std.testing.expectEqualStrings("  resolution: {integrity: sha512-25000}", rows[7].text);
    try std.testing.expectEqualStrings("24994 unchanged lines ⋯", rows[13].text);
}

test "committed file presentation without a full view keeps only its preview" {
    const alloc = std.testing.allocator;
    var handoff = testCommittedEditHandoff("before\n", "after\n");
    handoff.full_view = null;

    const presentation = try captureCommittedFilePresentation(alloc, handoff);
    defer types.freeCommittedFilePresentation(alloc, presentation);

    try std.testing.expect(presentation.review_lines == null);
    try std.testing.expect(presentation.lifecycle_id == null);
    try std.testing.expectEqual(types.CommittedFilePresentationKind.edited, presentation.kind);
    try std.testing.expectEqual(@as(usize, 2), presentation.lines.len);
    try std.testing.expectEqualStrings("before", presentation.lines[0].text);
    try std.testing.expect(types.committedFilePresentationContentSourceValid(presentation));
}

test "committed file presentation saves a file's invalid UTF-8 as visible escapes" {
    const alloc = std.testing.allocator;
    var handoff = testCommittedEditHandoff("keep\n\xff\xfe\tx\nold\n", "keep\n\xff\xfe\tx\nnew\n");
    const preview_lines = [_]diff_mod.PreviewLine{
        .{ .op = .context, .old_line = 2, .new_line = 2, .text = "\xff\xfe\tx" },
        .{ .op = .addition, .new_line = 3, .text = "new" },
    };
    handoff.preview.lines = &preview_lines;

    const presentation = try captureCommittedFilePresentation(alloc, handoff);
    defer types.freeCommittedFilePresentation(alloc, presentation);

    // The session store accepts only valid UTF-8; the tab stays for the
    // renderer, which also handles control bytes.
    try std.testing.expectEqualStrings("\\xff\\xfe\tx", presentation.lines[0].text);
    var escaped_row = false;
    for (presentation.review_lines.?) |row| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(row.text));
        if (std.mem.eql(u8, row.text, "\\xff\\xfe\tx")) escaped_row = true;
    }
    try std.testing.expect(escaped_row);
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
    const stored_source = try arena.print(
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
        const projected_source = try arena.print(
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
    const raw_output = try arena.print(
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
    const raw = text_utils.repeat("MY_UNIT_TOKEN=abcdefgh", 47);
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
    const raw = text_utils.repeat("MY_UNIT_TOKEN=abcdefgh", 47);

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
        if (case.bytes > case.cap and storage != .unavailable) {
            const handle = prepared.memory.output_handle orelse return error.TestExpectedStoredRetrieval;
            try std.testing.expectEqual(case.bytes, prepared.memory.stored_output_bytes);
            const stored = try result_store.readForReplayManaged(arena, &capability, handle, case.bytes);
            try std.testing.expectEqualStrings(raw, stored);
        } else {
            try std.testing.expect(prepared.memory.output_handle == null);
            if (case.bytes <= case.cap) try std.testing.expectEqualStrings(raw, prepared.model_output);
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
    }, toolCall("retrieval-store-error", "read_tool_result", "{}"), text_utils.repeat("x", 1025)));
}

test "saved tool output preparation keeps builtins and dynamic tools compactable" {
    const builtins = @import("../../../builtins/tools.zig");
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
        const raw = "COMPLETE_TOOL_BODY\n" ++ text_utils.repeat("x", 8192);
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

fn contextNote(text: []const u8) ChatMessage {
    return .{ .role = .system, .content = text, .context_note = true };
}

test "execution memory records each context note boundary, before that boundary's steering (D93)" {
    const alloc = std.testing.allocator;
    const session = @import("../../session/session.zig");
    const gateway = @import("../../../builtins/gateway.zig");
    const agent_stream_provider = @import("../stream_provider.zig");
    const steering = try steeringMessage(alloc, "after first");
    defer alloc.free(steering);
    var first_calls = [_]ToolCall{toolCall("call_first", "shell", "{\"command\":\"ls\"}")};
    var second_calls = [_]ToolCall{toolCall("call_second", "shell", "{\"command\":\"pwd\"}")};
    const live = [_]ChatMessage{
        contextNote("rules at start"),
        .{ .role = .assistant, .tool_calls = &first_calls },
        .{ .role = .tool, .content = "first result", .tool_call_id = "call_first", .tool_name = "shell", .tool_result_status = .success },
        contextNote("rules after first"),
        .{ .role = .user, .content = steering },
        .{ .role = .assistant, .tool_calls = &second_calls },
        .{ .role = .tool, .content = "second result", .tool_call_id = "call_second", .tool_name = "shell", .tool_result_status = .success },
        contextNote("rules after second"),
    };

    const execution = try buildExecutionMemory(alloc, &live);
    defer types.freeExecutionMemory(alloc, execution);
    try std.testing.expectEqual(@as(usize, 2), execution.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 1), execution.steering.len);
    try std.testing.expectEqual(@as(usize, 1), execution.steering[0].after_tool_step_count);
    const want = [_]struct { []const u8, usize }{ .{ "rules at start", 0 }, .{ "rules after first", 1 }, .{ "rules after second", 2 } };
    try std.testing.expectEqual(want.len, execution.context_notes.len);
    for (want, execution.context_notes) |expected, note| {
        try std.testing.expectEqualStrings(expected[0], note.text);
        try std.testing.expectEqual(expected[1], note.after_tool_step_count);
    }

    // The resumed turn sends exactly the request the live turn sent.
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prompt = [_]ChatMessage{.{ .role = .user, .content = "run both" }};
    var rebuilt: std.ArrayList(ChatMessage) = .empty;
    try rebuilt.appendSlice(arena, &prompt);
    try session.appendExecutionMemoryChatMessages(arena, &rebuilt, execution);
    const resumed = try rewrapRestoredSteering(arena, rebuilt.items);
    const sent = try std.mem.concat(arena, ChatMessage, &.{ &prompt, &live });
    try std.testing.expectEqual(sent.len, resumed.len);
    for (sent, resumed) |a, b| try std.testing.expectEqual(a.context_note, b.context_note);
    for ([_][]const u8{ "anthropic/claude-sonnet-5.5", "openai/gpt-6.1-sol" }) |model| {
        const request = struct {
            fn body(a: Allocator, name: []const u8, messages: []const ChatMessage) ![]u8 {
                return gateway.buildAgentRequest(a, .{
                    .model = name,
                    .instructions = &.{.{ .role = .system, .content = "stable", .cache_breakpoint = true }},
                    .messages = messages,
                    .tool_choice = .auto,
                    .provider_options = .{ .prompt_caching = true },
                });
            }
        };
        // Every request carries its notes on their tool results first (D93).
        const carried_sent = try agent_stream_provider.carryContextNotes(arena, sent);
        const carried_resumed = try agent_stream_provider.carryContextNotes(arena, resumed);
        try std.testing.expectEqualStrings(try request.body(arena, model, carried_sent), try request.body(arena, model, carried_resumed));
    }

    // A cut at the first boundary keeps that boundary's notes unless it
    // covers the steering that follows them there.
    const kept = try (CompactedExecutionBoundary{ .tool_steps = 1 }).project(arena, execution);
    try std.testing.expectEqual(@as(usize, 2), kept.context_notes.len);
    try std.testing.expectEqualStrings("rules after first", kept.context_notes[0].text);
    try std.testing.expectEqual(@as(usize, 0), kept.context_notes[0].after_tool_step_count);
    try std.testing.expectEqual(@as(usize, 1), kept.context_notes[1].after_tool_step_count);
    const past_steering = try (CompactedExecutionBoundary{ .tool_steps = 1, .steering = 1 }).project(arena, execution);
    try std.testing.expectEqual(@as(usize, 1), past_steering.context_notes.len);
    try std.testing.expectEqualStrings("rules after second", past_steering.context_notes[0].text);
    // The live messages the same cuts keep start where the saved turn does.
    try std.testing.expectEqual(@as(usize, 3), try retainedMessageOffset(&live, .{ .tool_steps = 1 }));
    try std.testing.expectEqual(@as(usize, 5), try retainedMessageOffset(&live, .{ .tool_steps = 1, .steering = 1 }));
    // Compacting the whole turn so far keeps the notes that end it.
    try std.testing.expectEqual(@as(usize, 7), try retainedMessageOffset(&live, .{ .tool_steps = 2, .steering = 1 }));
    try std.testing.expectEqual(@as(usize, 1), (try (CompactedExecutionBoundary{ .tool_steps = 2, .steering = 1 }).project(arena, execution)).context_notes.len);
}

test "restored context notes survive execution memory round trips (D93)" {
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
    var steps = [_]types.ToolExecutionStep{.{ .tool_calls = &calls, .tool_results = &results }};
    var steering = [_]types.PersistedSteering{
        .{ .text = @constCast("root update"), .after_tool_step_count = 0 },
        .{ .text = @constCast("later update"), .after_tool_step_count = 1 },
    };
    var notes = [_]types.PersistedContextNote{
        .{ .text = @constCast("start note"), .after_tool_step_count = 0 },
        .{ .text = @constCast("end note"), .after_tool_step_count = 1 },
    };
    var messages: std.ArrayList(ChatMessage) = .empty;
    defer messages.deinit(alloc);
    try session.appendExecutionMemoryChatMessages(alloc, &messages, .{
        .tool_steps = &steps,
        .steering = &steering,
        .context_notes = &notes,
    });
    // Each note comes back as a flagged system message, before the steering
    // at its boundary.
    try std.testing.expectEqual(@as(usize, 6), messages.items.len);
    try std.testing.expect(messages.items[0].role == .system and messages.items[0].context_note);
    try std.testing.expect(messages.items[1].restored_steering);
    try std.testing.expect(messages.items[4].role == .system and messages.items[4].context_note);
    try std.testing.expect(messages.items[5].restored_steering);

    const rebuilt = try buildExecutionMemory(alloc, messages.items);
    defer types.freeExecutionMemory(alloc, rebuilt);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.tool_steps.len);
    try std.testing.expectEqual(@as(usize, 2), rebuilt.steering.len);
    try std.testing.expectEqual(notes.len, rebuilt.context_notes.len);
    for (notes, rebuilt.context_notes) |want, got| {
        try std.testing.expectEqualStrings(want.text, got.text);
        try std.testing.expectEqual(want.after_tool_step_count, got.after_tool_step_count);
    }

    const offset = try retainedMessageOffset(messages.items, .{ .tool_steps = 1, .steering = 1 });
    const retained = try buildExecutionMemory(alloc, messages.items[offset..]);
    defer types.freeExecutionMemory(alloc, retained);
    try std.testing.expectEqual(@as(usize, 1), retained.context_notes.len);
    try std.testing.expectEqualStrings("end note", retained.context_notes[0].text);
    try std.testing.expectEqual(@as(usize, 0), retained.context_notes[0].after_tool_step_count);
}

test "a context note between steps keeps every tool result and its feedback (D93)" {
    const alloc = std.testing.allocator;
    var first_calls = [_]ToolCall{
        toolCall("call_a", "read_file", "{\"path\":\"a\"}"),
        toolCall("call_b", "read_file", "{\"path\":\"b\"}"),
    };
    var second_calls = [_]ToolCall{toolCall("call_c", "read_file", "{\"path\":\"c\"}")};
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &first_calls },
        .{ .role = .tool, .content = "a", .tool_call_id = "call_a", .tool_name = "read_file", .tool_result_status = .success },
        .{ .role = .tool, .content = "b", .tool_call_id = "call_b", .tool_name = "read_file", .tool_result_status = .success },
        contextNote("between steps"),
        .{ .role = .user, .content = "allowed once", .tool_call_id = "call_b", .permission_feedback = true },
        .{ .role = .assistant, .tool_calls = &second_calls },
        .{ .role = .tool, .content = "c", .tool_call_id = "call_c", .tool_name = "read_file", .tool_result_status = .success },
    };
    for ([_]bool{ false, true }) |interrupted| {
        const execution = if (interrupted)
            try buildInterruptedExecutionMemory(alloc, &messages, null)
        else
            try buildExecutionMemory(alloc, &messages);
        defer types.freeExecutionMemory(alloc, execution);
        try std.testing.expectEqual(@as(usize, 2), execution.tool_steps.len);
        try std.testing.expectEqual(@as(usize, 2), execution.tool_steps[0].tool_results.len);
        try std.testing.expectEqualStrings("call_b", execution.tool_steps[0].tool_results[1].tool_call_id);
        try std.testing.expectEqual(@as(usize, 1), execution.tool_steps[0].tool_results[1].permission_feedback.len);
        try std.testing.expectEqual(@as(usize, 1), execution.tool_steps[1].tool_results.len);
        try std.testing.expectEqual(@as(usize, 1), execution.context_notes.len);
        try std.testing.expectEqualStrings("between steps", execution.context_notes[0].text);
        try std.testing.expectEqual(@as(usize, 1), execution.context_notes[0].after_tool_step_count);
        try std.testing.expectEqual(@as(usize, 0), execution.steering.len);
    }
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
