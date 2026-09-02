const std = @import("std");
const model_capabilities = @import("../../config/model_capabilities.zig");
const types = @import("../../shared/types.zig");
const session_runtime = @import("../../session/session.zig");

const runtime_config = @import("config.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;

pub fn historyContextBudgetTokensForCapabilities(capabilities: model_capabilities.Capabilities) usize {
    const context_window = capabilities.context_window orelse
        return runtime_config.default_history_context_budget_tokens;
    const context_tokens: usize = @intCast(context_window);
    const available_input_tokens = if (capabilities.max_output_tokens) |max_output_tokens|
        context_tokens -| @as(usize, @intCast(max_output_tokens))
    else
        context_tokens;
    return @max(
        @as(usize, 1),
        available_input_tokens / runtime_config.history_context_budget_window_divisor,
    );
}

pub fn buildGatewayMessages(
    alloc: Allocator,
    stable_prefix: []const ChatMessage,
    ephemeral_overlay: []const ChatMessage,
    durable_history: []const ChatMessage,
    current_user_message: ChatMessage,
    within_turn_suffix: []const ChatMessage,
) !std.ArrayList(ChatMessage) {
    var messages: std.ArrayList(ChatMessage) = .empty;
    errdefer messages.deinit(alloc);

    // 1. All system messages must be strictly leading for provider compatibility.
    for (stable_prefix) |msg| {
        if (msg.role == .system) try messages.append(alloc, msg);
    }
    for (ephemeral_overlay) |msg| {
        if (msg.role == .system) {
            var copy = msg;
            copy.cache_policy = .no_cache;
            try messages.append(alloc, copy);
        }
    }
    for (durable_history) |msg| {
        if (msg.role == .system) try messages.append(alloc, msg);
    }

    // 2. Non-system messages follow in logical execution order.
    for (stable_prefix) |msg| {
        if (msg.role != .system) try messages.append(alloc, msg);
    }
    for (ephemeral_overlay) |msg| {
        if (msg.role != .system) {
            var copy = msg;
            copy.cache_policy = .no_cache;
            try messages.append(alloc, copy);
        }
    }
    for (durable_history) |msg| {
        if (msg.role != .system) try messages.append(alloc, msg);
    }

    // 3. Current turn user message and within-turn suffix.
    try messages.append(alloc, current_user_message);
    try messages.appendSlice(alloc, within_turn_suffix);
    return messages;
}

test "history context budget reserves known output capacity from one capability snapshot" {
    const cases = [_]struct {
        capabilities: model_capabilities.Capabilities,
        expected: usize,
    }{
        .{ .capabilities = .{ .context_window = 128_000, .max_output_tokens = 32_000 }, .expected = 24_000 },
        .{ .capabilities = .{ .context_window = 256_000, .max_output_tokens = 64_000 }, .expected = 48_000 },
        .{ .capabilities = .{ .context_window = 1_000_000, .max_output_tokens = 128_000 }, .expected = 218_000 },
        .{ .capabilities = .{ .context_window = 512_000 }, .expected = 128_000 },
        .{ .capabilities = .{ .max_output_tokens = 32_000 }, .expected = runtime_config.default_history_context_budget_tokens },
        .{ .capabilities = .{ .context_window = 32_000, .max_output_tokens = 32_000 }, .expected = 1 },
        .{ .capabilities = .{ .context_window = 32_000, .max_output_tokens = 64_000 }, .expected = 1 },
        .{ .capabilities = .{}, .expected = runtime_config.default_history_context_budget_tokens },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            historyContextBudgetTokensForCapabilities(case.capabilities),
        );
    }
}

test "budgeted history projection uses a million-token capability while remaining bounded" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const large_user = try arena.alloc(u8, 120_000);
    @memset(large_user, 'u');
    const large_assistant = try arena.alloc(u8, 120_000);
    @memset(large_assistant, 'a');

    var history: [5]HistoryTurn = undefined;
    for (&history) |*turn| {
        turn.* = try session_runtime.makeAssistantTurn(arena, large_user, large_assistant);
    }

    const exact_budget = historyContextBudgetTokensForCapabilities(
        .{ .context_window = 1_000_000 },
    );
    try std.testing.expectEqual(@as(usize, 250_000), exact_budget);

    var below_new_budget: std.ArrayList(ChatMessage) = .empty;
    try session_runtime.appendHistoryChatMessagesBudgeted(
        arena,
        &below_new_budget,
        history[0..4],
        .{ .max_tokens = exact_budget },
    );
    try std.testing.expectEqual(@as(usize, 8), below_new_budget.items.len);
    try std.testing.expectEqualStrings(large_assistant, below_new_budget.items[below_new_budget.items.len - 1].content.?);

    var above_new_budget: std.ArrayList(ChatMessage) = .empty;
    try session_runtime.appendHistoryChatMessagesBudgeted(
        arena,
        &above_new_budget,
        &history,
        .{ .max_tokens = exact_budget },
    );
    try std.testing.expectEqual(types.ChatRole.system, above_new_budget.items[0].role);
    try std.testing.expectEqual(@as(usize, 9), above_new_budget.items.len);
    try std.testing.expectEqualStrings(large_assistant, above_new_budget.items[above_new_budget.items.len - 1].content.?);

    var older_model_projection: std.ArrayList(ChatMessage) = .empty;
    try session_runtime.appendHistoryChatMessagesBudgeted(
        arena,
        &older_model_projection,
        history[0..4],
        .{ .max_tokens = historyContextBudgetTokensForCapabilities(.{ .context_window = 200_000 }) },
    );
    try std.testing.expectEqual(types.ChatRole.system, older_model_projection.items[0].role);
    try std.testing.expectEqual(@as(usize, 3), older_model_projection.items.len);
    try std.testing.expectEqualStrings(large_assistant, older_model_projection.items[older_model_projection.items.len - 1].content.?);
}

test "buildGatewayMessages orders transient overlay before history and current prompt" {
    const alloc = std.testing.allocator;
    const stable_prefix = [_]ChatMessage{
        .{ .role = .system, .content = "stable system prompt" },
        .{ .role = .system, .content = "stable project context" },
    };
    const overlay = [_]ChatMessage{
        .{ .role = .system, .content = "volatile runtime overlay" },
    };
    const history = [_]ChatMessage{
        .{ .role = .user, .content = "history user prompt" },
        .{ .role = .assistant, .content = "history assistant answer" },
    };
    const current = ChatMessage{ .role = .user, .content = "current user prompt" };
    const suffix = [_]ChatMessage{
        .{ .role = .assistant, .content = "within turn assistant" },
    };

    var messages = try buildGatewayMessages(alloc, &stable_prefix, &overlay, &history, current, &suffix);
    defer messages.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 7), messages.items.len);
    try std.testing.expectEqualStrings("stable system prompt", messages.items[0].content.?);
    try std.testing.expectEqualStrings("stable project context", messages.items[1].content.?);
    try std.testing.expectEqualStrings("volatile runtime overlay", messages.items[2].content.?);
    try std.testing.expectEqualStrings("history user prompt", messages.items[3].content.?);
    try std.testing.expectEqualStrings("history assistant answer", messages.items[4].content.?);
    try std.testing.expectEqualStrings("current user prompt", messages.items[5].content.?);
    try std.testing.expectEqualStrings("within turn assistant", messages.items[6].content.?);
    try std.testing.expectEqual(types.ChatCachePolicy.no_cache, messages.items[2].cache_policy);
}

test "buildGatewayMessages preserves one system prefix for projected session history" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var calls = [_]types.ToolCall{.{
        .id = "call_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/portable.zig\"}",
    }};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("portable contents"),
        .output_bytes = 17,
        .stored_output_bytes = 17,
    }};
    var steps = [_]types.ToolExecutionStep{.{
        .assistant = @constCast("Reading the file."),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    var files = [_]types.FileEvidence{.{
        .path = @constCast("src/portable.zig"),
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .action = .read,
        .status = .success,
        .model_view_covers_full_file = true,
    }};
    const history = [_]HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast("LEADING_SUMMARY_ONLY"),
            .removed_turn_count = 2,
            .compaction_count = 1,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("inspect portable history") },
            .assistant = @constCast("inspection complete"),
            .execution = .{ .tool_steps = steps[0..], .files = files[0..] },
        } },
        .{ .compacted_summary = .{
            .summary = @constCast("LATE_SUMMARY_ONLY"),
            .removed_turn_count = 1,
            .compaction_count = 2,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("run portable server") },
            .assistant = @constCast("server history is inert"),
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("stop portable work") },
            .assistant = @constCast("partial portable work"),
        } },
    };

    var projected_history: std.ArrayList(ChatMessage) = .empty;
    defer projected_history.deinit(arena);
    try session_runtime.appendHistoryChatMessages(arena, &projected_history, &history);

    const stable_prefix = [_]ChatMessage{
        .{ .role = .system, .content = "stable system prompt" },
        .{ .role = .system, .content = "stable project context" },
    };
    const overlay = [_]ChatMessage{.{ .role = .system, .content = "ephemeral overlay" }};
    const current = ChatMessage{ .role = .user, .content = "current portable prompt" };
    const suffix = [_]ChatMessage{.{ .role = .assistant, .content = "within-turn suffix" }};
    var messages = try buildGatewayMessages(
        arena,
        &stable_prefix,
        &overlay,
        projected_history.items,
        current,
        &suffix,
    );
    defer messages.deinit(arena);

    var saw_non_system = false;
    var leading_summary_count: usize = 0;
    var late_summary_count: usize = 0;
    var file_evidence_count: usize = 0;
    var interruption_count: usize = 0;
    for (messages.items) |entry| {
        if (entry.role == .system) {
            try std.testing.expect(!saw_non_system);
        } else {
            saw_non_system = true;
        }
        const content = entry.content orelse continue;
        if (std.mem.find(u8, content, "LEADING_SUMMARY_ONLY") != null) {
            try std.testing.expectEqual(types.ChatRole.system, entry.role);
            leading_summary_count += 1;
        }
        if (std.mem.find(u8, content, "LATE_SUMMARY_ONLY") != null) {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            late_summary_count += 1;
        }
        if (std.mem.find(u8, content, "src/portable.zig") != null and
            std.mem.find(u8, content, "Session file evidence") != null)
        {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            file_evidence_count += 1;
        }
        if (std.mem.find(u8, content, "<turn_aborted>") != null) {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            interruption_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), leading_summary_count);
    try std.testing.expectEqual(@as(usize, 1), late_summary_count);
    try std.testing.expectEqual(@as(usize, 1), file_evidence_count);
    try std.testing.expectEqual(@as(usize, 1), interruption_count);
    try std.testing.expectEqualStrings("current portable prompt", messages.items[messages.items.len - 2].content.?);
    try std.testing.expectEqualStrings("within-turn suffix", messages.items[messages.items.len - 1].content.?);
}

test "buildGatewayMessages guarantees all system messages are contiguous and strictly leading even with mixed overlays and history" {
    const alloc = std.testing.allocator;
    const stable_prefix = [_]ChatMessage{
        .{ .role = .system, .content = "stable system prompt" },
    };
    const overlay = [_]ChatMessage{
        .{ .role = .user, .content = "ephemeral user context notice" },
        .{ .role = .system, .content = "ephemeral system skill warning" },
    };
    const history = [_]ChatMessage{
        .{ .role = .system, .content = "earlier history was summarized" },
        .{ .role = .user, .content = "turn 1 user" },
        .{ .role = .assistant, .content = "turn 1 assistant" },
    };
    const current = ChatMessage{ .role = .user, .content = "turn 2 user" };
    const suffix = [_]ChatMessage{
        .{ .role = .assistant, .content = "turn 2 assistant prefill" },
    };

    var messages = try buildGatewayMessages(alloc, &stable_prefix, &overlay, &history, current, &suffix);
    defer messages.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 8), messages.items.len);

    // Assert strictly leading system messages:
    var saw_non_system = false;
    for (messages.items) |msg| {
        if (msg.role == .system) {
            try std.testing.expect(!saw_non_system);
        } else {
            saw_non_system = true;
        }
    }

    // First 3 are system messages:
    try std.testing.expectEqual(types.ChatRole.system, messages.items[0].role);
    try std.testing.expectEqualStrings("stable system prompt", messages.items[0].content.?);

    try std.testing.expectEqual(types.ChatRole.system, messages.items[1].role);
    try std.testing.expectEqualStrings("ephemeral system skill warning", messages.items[1].content.?);
    try std.testing.expectEqual(types.ChatCachePolicy.no_cache, messages.items[1].cache_policy);

    try std.testing.expectEqual(types.ChatRole.system, messages.items[2].role);
    try std.testing.expectEqualStrings("earlier history was summarized", messages.items[2].content.?);

    // Remaining 5 are non-system messages:
    try std.testing.expectEqual(types.ChatRole.user, messages.items[3].role);
    try std.testing.expectEqualStrings("ephemeral user context notice", messages.items[3].content.?);
    try std.testing.expectEqual(types.ChatCachePolicy.no_cache, messages.items[3].cache_policy);

    try std.testing.expectEqual(types.ChatRole.user, messages.items[4].role);
    try std.testing.expectEqualStrings("turn 1 user", messages.items[4].content.?);

    try std.testing.expectEqual(types.ChatRole.assistant, messages.items[5].role);
    try std.testing.expectEqualStrings("turn 1 assistant", messages.items[5].content.?);

    try std.testing.expectEqual(types.ChatRole.user, messages.items[6].role);
    try std.testing.expectEqualStrings("turn 2 user", messages.items[6].content.?);

    try std.testing.expectEqual(types.ChatRole.assistant, messages.items[7].role);
    try std.testing.expectEqualStrings("turn 2 assistant prefill", messages.items[7].content.?);
}
