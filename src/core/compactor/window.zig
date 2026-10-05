//! Which part of the conversation fx-compactor compacts. The newest turns
//! stay unchanged within a share of the room the request aims for right
//! after compaction; everything older is compacted. The compacted part keeps
//! every user message and final reply, so a long session may need more than
//! that room.

const std = @import("std");
const settings = @import("settings.zig");
const history_range = @import("../shared/history_range.zig");
const token_estimate = @import("../shared/token_estimate.zig");
const model_capabilities = @import("../config/model_capabilities.zig");
const model_provider = @import("../config/model_provider.zig");
const trace = @import("trace.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const HistoryTurn = types.HistoryTurn;

/// Right after compaction the whole request aims for at most this share of
/// the usable input, and at most half of the compaction point.
const after_percent: usize = 20;
/// Of the room the compacted conversation gets, the newest turns kept
/// unchanged may use this share.
const kept_percent: usize = 40;
const max_kept_turns: usize = 4;

/// How large the conversation is and may be, in estimated tokens.
pub const Size = struct {
    /// Where automatic compaction starts, when the model's size is known.
    compact_at_tokens: ?usize,
    /// The model's usable input, when known.
    usable_tokens: ?usize,
    /// The request that needs the room, when there is one.
    request_tokens: ?usize = null,
    /// What compaction cannot shrink: the request's instructions and tool
    /// definitions, measured like the request. When unknown, half of the
    /// room after compaction is set aside for it.
    fixed_tokens: ?usize = null,
    /// How far fx's token estimate ran from the provider's count on a recent
    /// request. The compactor measures text with that estimate, so its room
    /// is scaled by the same ratio.
    correction: ?Correction = null,
    /// The provider rejected that request as too large, so the estimate was
    /// wrong and the room after compaction is bounded by the request instead.
    overflow: bool = false,

    /// The provider counted `measured` tokens for a request estimated at
    /// `estimated`.
    pub const Correction = struct { estimated: usize, measured: usize };

    /// `tokens` as the provider counts them, in fx's estimate.
    fn estimate(self: Size, tokens: usize) usize {
        const correction = self.correction orelse return tokens;
        if (correction.estimated == 0 or correction.measured == 0 or tokens == std.math.maxInt(usize)) return tokens;
        return std.math.cast(usize, @as(u128, tokens) * correction.estimated / correction.measured) orelse std.math.maxInt(usize);
    }

    /// The sizes for a model, compacting automatically at `percent` of its
    /// usable input.
    pub fn of(capabilities: model_capabilities.Capabilities, percent: u8) Size {
        return .{
            .compact_at_tokens = compactAtTokens(capabilities, percent),
            .usable_tokens = usableInputTokens(capabilities),
        };
    }

    /// Estimated tokens one summary request may use: the model's usable
    /// input. After the provider rejected a request as too large, estimates
    /// ran low, so a summary request stays well below the rejected one.
    pub fn summaryRequestTokens(self: Size) usize {
        var room = self.usable_tokens orelse std.math.maxInt(usize);
        if (self.overflow) if (self.request_tokens) |rejected| {
            room = @min(room, rejected / 4 * 3);
        };
        return self.estimate(room);
    }

    /// Estimated tokens a notes request may use when sent right after the
    /// conversation of `request_tokens`. Null when either size is unknown,
    /// nothing is left, or the provider rejected that conversation as too
    /// large.
    pub fn roomAfterConversation(self: Size) ?usize {
        const usable = self.usable_tokens orelse return null;
        const conversation = self.request_tokens orelse return null;
        if (self.overflow or conversation >= usable) return null;
        return self.estimate(usable - conversation);
    }

    /// Estimated tokens the whole request may use right after compaction.
    pub fn afterTokens(self: Size) usize {
        const point = self.compact_at_tokens orelse self.request_tokens orelse return std.math.maxInt(usize);
        var after = point / 2;
        if (self.usable_tokens) |usable| after = @min(after, percentOf(usable, after_percent));
        if (self.overflow) if (self.request_tokens) |rejected| {
            after = @min(after, percentOf(rejected, after_percent));
        };
        return after;
    }

    /// Estimated tokens the compacted conversation may use: the room after
    /// compaction less the fixed part. Never below a quarter of that room,
    /// so compaction still keeps something when the fixed part alone fills
    /// it.
    fn conversationTokens(self: Size) usize {
        const after = self.afterTokens();
        if (after == std.math.maxInt(usize)) return after;
        const fixed = self.fixed_tokens orelse after / 2;
        return self.estimate(@max(after -| fixed, after / 4));
    }

    /// Estimated tokens the compacted text may use so compaction still frees
    /// at least half the room: half the compaction point less the fixed part
    /// and `kept_used`, the turns kept unchanged. Past it, the conversation
    /// would compact again right away and soon not fit at all.
    pub fn compactedTokens(self: Size, kept_used: usize) usize {
        const point = self.compact_at_tokens orelse self.request_tokens orelse return std.math.maxInt(usize);
        var most = point / 2;
        if (self.overflow) if (self.request_tokens) |rejected| {
            most = @min(most, rejected / 2);
        };
        const fixed = self.fixed_tokens orelse most / 4;
        return self.estimate(@max(most -| fixed, most / 4)) -| kept_used;
    }

    /// The request has reached the automatic compaction point.
    pub fn due(self: Size) bool {
        const at = self.compact_at_tokens orelse return false;
        const request = self.request_tokens orelse return false;
        return request >= at;
    }

    /// Compaction must free room: without it the request cannot be sent.
    fn required(self: Size) bool {
        const request = self.request_tokens orelse return self.overflow;
        return self.overflow or request > (self.usable_tokens orelse std.math.maxInt(usize));
    }
};

/// Request size, in tokens, at which automatic compaction starts: `percent`
/// of the model's usable input.
fn compactAtTokens(capabilities: model_capabilities.Capabilities, percent: u8) ?usize {
    const usable = usableInputTokens(capabilities) orelse return null;
    return percentOf(usable, @min(settings.max_percent, @max(settings.min_percent, percent)));
}

fn percentOf(tokens: usize, percent: usize) usize {
    return tokens / 100 * percent + tokens % 100 * percent / 100;
}

/// The model's input room: its context window less the room it keeps for
/// output.
fn usableInputTokens(capabilities: model_capabilities.Capabilities) ?usize {
    const context_window = capabilities.context_window orelse return null;
    const context_tokens: usize = @intCast(context_window);
    // Reserve exactly what the request asks for; that limit is always below the window.
    const output_tokens: usize = model_capabilities.requestOutputTokens(capabilities) orelse return context_tokens;
    return context_tokens - output_tokens;
}

const textTokens = token_estimate.textTokens;

/// Where the kept part starts, and its estimated tokens.
const Recent = struct { cut: types.ContextHistoryCut, tokens: usize = 0 };

/// Where the kept part starts: the newest complete execution steps within
/// `target` tokens and `max_turns` turns. A newest step larger than `target`
/// is not kept. Payloads are measured, never shortened.
fn selectRecentContext(
    history: []const HistoryTurn,
    target: usize,
    input_capacity: ?usize,
    provider: ?model_provider.ProviderSelection,
    max_turns: usize,
) Recent {
    var raw_count = history_range.rawHistoryTurnCount(history);
    var selected = Recent{ .cut = .{ .turns = raw_count } };
    var total: usize = 0;
    var selected_any = false;
    var turns_used: usize = 0;
    var index = history.len;
    history_scan: while (index > 0) {
        index -= 1;
        const turn = history[index];
        if (turn == .compacted_summary) continue;
        if (selected_any and turns_used >= max_turns) break;
        raw_count -= 1;
        const user = switch (turn) {
            .assistant => |entry| entry.user.text,
            .interrupted => |entry| entry.user.text,
            .compacted_summary => unreachable,
        };
        const reply = switch (turn) {
            .assistant => |entry| entry.assistant,
            .interrupted => |entry| entry.assistant orelse "",
            .compacted_summary => unreachable,
        };
        const execution = switch (turn) {
            .assistant => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
            .compacted_summary => unreachable,
        };
        const replay = switch (turn) {
            .assistant => |entry| entry.provider_replay,
            .interrupted => null,
            .compacted_summary => unreachable,
        };
        var base = textTokens(user) +| textTokens(reply) +| replay_tokens(replay, provider) +| 8;
        var steering_index = execution.steering.len;
        var step_index = execution.tool_steps.len;
        if (step_index == 0) {
            for (execution.steering) |entry| {
                base +|= textTokens(entry.text);
                if (entry.assistant_prefix) |prefix| base +|= textTokens(prefix);
            }
            if (input_capacity) |capacity| {
                if (!selected_any and base >= capacity) break :history_scan;
            }
            if (selected_any and (raw_count == 0 or total +| base > target)) break;
            total +|= base;
            selected = .{ .cut = .{ .turns = raw_count }, .tokens = total };
            selected_any = true;
            turns_used += 1;
            continue;
        }
        var turn_counted = false;
        while (step_index > 0) {
            step_index -= 1;
            var cost = base +| executionStepTokens(execution.tool_steps[step_index], provider);
            var next_steering = steering_index;
            while (next_steering > 0 and execution.steering[next_steering - 1].after_tool_step_count >= step_index) {
                next_steering -= 1;
                cost +|= textTokens(execution.steering[next_steering].text);
                if (execution.steering[next_steering].assistant_prefix) |prefix| cost +|= textTokens(prefix);
            }
            if (!selected_any and cost > target) break :history_scan;
            if (input_capacity) |capacity| {
                if (!selected_any and cost >= capacity) break :history_scan;
            }
            if (selected_any and ((raw_count == 0 and step_index == 0) or total +| cost > target)) return selected;
            total +|= cost;
            selected = .{ .cut = .{ .turns = raw_count, .tool_steps = step_index, .steering = next_steering }, .tokens = total };
            selected_any = true;
            if (!turn_counted) turns_used += 1;
            turn_counted = true;
            steering_index = next_steering;
            base = 0;
        }
    }
    return selected;
}

fn replay_tokens(replay: ?types.ProviderReplay, provider: ?model_provider.ProviderSelection) usize {
    const value = replay orelse return 0;
    if (provider) |route| if (!value.matches(route)) return 0;
    return textTokens(value.parts_json);
}

fn executionStepTokens(step: types.ToolExecutionStep, provider: ?model_provider.ProviderSelection) usize {
    var total: usize = 8 +| replay_tokens(step.provider_replay, provider);
    if (step.assistant) |text| total +|= textTokens(text);
    for (step.tool_calls) |call| {
        total +|= textTokens(call.id) +| textTokens(call.name) +| textTokens(call.arguments_json) +| 8;
    }
    for (step.tool_results) |result| {
        total +|= textTokens(result.tool_call_id) +| textTokens(result.tool_name) +| textTokens(result.output) +| 8;
    }
    return total;
}

pub const Window = struct {
    /// The newest checkpoint before `older`.
    earlier: ?[]const u8,
    /// Raw turns to compact, oldest first.
    older: []HistoryTurn,
    /// The raw part that stays after the checkpoint.
    retained_history: []HistoryTurn,
    /// What stays in the conversation after the cut: `retained_history` and
    /// the rest of the turn in progress, which lives outside the history.
    kept: []HistoryTurn,
    cut: types.ContextHistoryCut,
    /// Token budget of the part kept unchanged.
    kept_tokens: usize,
    /// Estimated tokens of the part kept unchanged.
    kept_used: usize = 0,

    /// True when the cut falls inside a turn: that turn's user message stays
    /// with the part kept after the checkpoint.
    pub fn splitsLastTurn(self: Window) bool {
        return self.older.len > 0 and (self.cut.tool_steps > 0 or self.cut.steering > 0);
    }
};

/// Chooses what to compact. Null when nothing needs compacting. When the
/// request cannot be sent otherwise, compacts everything before giving up
/// with `ContextCapacityExceeded`. Slices are arena-owned.
pub fn choose(
    arena: Allocator,
    history: []const HistoryTurn,
    active: ?types.AssistantHistoryTurn,
    size: Size,
    route: model_provider.ProviderSelection,
    trace_ctx: debug_trace.TraceContext,
) !?Window {
    var kept = percentOf(size.conversationTokens(), kept_percent);
    while (true) {
        const window = try split(arena, history, active, kept, size.usable_tokens, route);
        if (window.older.len > 0) return window;
        if (!size.required()) return null;
        if (kept == 0) {
            trace.failure(trace_ctx, .retention_exhausted, "estimated_tokens={d}", .{size.request_tokens orelse 0});
            return error.ContextCapacityExceeded;
        }
        trace.failure(trace_ctx, .retention_forced_zero, "estimated_tokens={d} kept_tokens={d}", .{ size.request_tokens orelse 0, kept });
        kept = 0;
    }
}

/// Splits the context: the newest turns stay unchanged, at most
/// `max_kept_turns` of them within `kept_tokens`; everything older is
/// compacted. `kept_tokens == 0` keeps nothing.
fn split(
    arena: Allocator,
    history: []const HistoryTurn,
    active: ?types.AssistantHistoryTurn,
    kept_tokens: usize,
    input_capacity: ?usize,
    route: model_provider.ProviderSelection,
) !Window {
    var combined: std.ArrayList(HistoryTurn) = .empty;
    try combined.appendSlice(arena, history);
    if (active) |turn| try combined.append(arena, .{ .assistant = turn });
    const recent: Recent = if (kept_tokens == 0)
        .{ .cut = .{ .turns = history_range.rawHistoryTurnCount(combined.items) } }
    else
        selectRecentContext(combined.items, kept_tokens, input_capacity, route, max_kept_turns);
    var cut = recent.cut;
    if (active) |turn| {
        // The unfinished turn lives outside `history`; compacting all of it
        // means cutting after its last completed exchange.
        const active_index = history_range.rawHistoryTurnCount(history);
        if (cut.turns > active_index) cut = .{
            .turns = active_index,
            .tool_steps = turn.execution.tool_steps.len,
            .steering = turn.execution.steering.len,
        };
    }
    var earlier: ?[]const u8 = null;
    for (history) |turn| {
        if (turn == .compacted_summary) earlier = turn.compacted_summary.summary;
    }
    return .{
        .earlier = earlier,
        .older = try history_range.contextHistoryRange(arena, combined.items, .{}, cut),
        .retained_history = try history_range.contextHistoryRange(arena, history, cut, null),
        .kept = try history_range.contextHistoryRange(arena, combined.items, cut, null),
        .cut = cut,
        .kept_tokens = kept_tokens,
        .kept_used = recent.tokens,
    };
}

const testing = std.testing;
const selection: model_provider.ProviderSelection = .{ .provider = .gateway, .model = "fixture-model" };

test "compactor input budget follows normal model capacity" {
    try testing.expectEqual(@as(?usize, 296_816), usableInputTokens(.{ .context_window = 500_000, .max_output_tokens = 203_184 }));
    try testing.expectEqual(@as(?usize, 500_000 - 32_768), usableInputTokens(.{ .context_window = 500_000, .max_output_tokens = 500_000 }));
    try testing.expectEqual(@as(?usize, null), usableInputTokens(.{}));
}

test "retained context budgets provider replay on completed exchanges" {
    const replay = types.ProviderReplay{ .source = .{ .provider = .gateway, .model = "fixture/model" }, .parts_json = "[{\"type\":\"reasoning\",\"text\":\"\",\"providerOptions\":{\"openai\":{\"reasoningEncryptedContent\":\"" ++ ("r" ** 80_000) ++ "\"}}}]" };
    var steps = [_]types.ToolExecutionStep{
        .{ .assistant = @constCast("one"), .provider_replay = replay },
        .{ .assistant = @constCast("two"), .provider_replay = replay },
        .{ .assistant = @constCast("three"), .provider_replay = replay },
    };
    const history = [_]HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("continue") },
        .assistant = @constCast(""),
        .execution = .{ .tool_steps = &steps },
    } }};
    // Counted for the model that wrote it, the replay makes the newest step
    // larger than the kept budget, so all of it is compacted.
    const same_model: model_provider.ProviderSelection = .{ .provider = .gateway, .model = "fixture/model" };
    try testing.expectEqual(types.ContextHistoryCut{ .turns = 1 }, selectRecentContext(&history, 5_990, 119_808, same_model, max_kept_turns).cut);
    // Another model never receives it, so the steps are small and two stay.
    const other_model: model_provider.ProviderSelection = .{ .provider = .gateway, .model = "fixture/other" };
    const kept = selectRecentContext(&history, 5_990, 119_808, other_model, max_kept_turns);
    try testing.expectEqual(@as(usize, 1), kept.cut.tool_steps);
    try testing.expect(kept.tokens > 0 and kept.tokens <= 5_990);
}

test "retained context budgets replay on standalone assistant replies" {
    const turn = types.AssistantHistoryTurn{
        .user = .{ .text = @constCast("continue") },
        .assistant = @constCast("small reply"),
        .provider_replay = .{ .source = .{ .provider = .gateway, .model = "fixture/model" }, .parts_json = "[{\"type\":\"reasoning\",\"text\":\"\",\"providerOptions\":{\"openai\":{\"reasoningEncryptedContent\":\"" ++ ("r" ** 80_000) ++ "\"}}}]" },
    };
    const history = [_]HistoryTurn{ .{ .assistant = turn }, .{ .assistant = turn }, .{ .assistant = turn } };
    const same_model: model_provider.ProviderSelection = .{ .provider = .gateway, .model = "fixture/model" };
    try testing.expectEqual(@as(usize, 2), selectRecentContext(&history, 5_990, 119_808, same_model, max_kept_turns).cut.turns);
}

test "retained context keeps or compacts a parallel tool exchange whole without shortening results" {
    const body = "large output " ** 2000;
    const calls = [_]types.ToolCall{
        .{ .id = "one", .name = "read_file", .arguments_json = "{}" },
        .{ .id = "two", .name = "read_file", .arguments_json = "{}" },
    };
    const results = [_]types.PersistedToolResult{
        .{ .tool_call_id = @constCast("one"), .tool_name = @constCast("read_file"), .status = .success, .output = @constCast(body), .output_bytes = body.len, .stored_output_bytes = body.len },
        .{ .tool_call_id = @constCast("two"), .tool_name = @constCast("read_file"), .status = .success, .output = @constCast(body), .output_bytes = body.len, .stored_output_bytes = body.len },
    };
    const steps = [_]types.ToolExecutionStep{
        .{ .assistant = @constCast("earlier work") },
        .{ .tool_calls = @constCast(&calls), .tool_results = @constCast(&results) },
    };
    const history = [_]HistoryTurn{
        .{ .assistant = .{ .user = .{ .text = @constCast("old request") }, .assistant = @constCast("old answer") } },
        .{ .assistant = .{ .user = .{ .text = @constCast("current request") }, .assistant = @constCast(""), .execution = .{ .tool_steps = @constCast(&steps) } } },
    };
    // Room for both results keeps the current turn; the oldest turn is
    // always compacted.
    try testing.expectEqual(types.ContextHistoryCut{ .turns = 1 }, selectRecentContext(&history, 100_000, null, selection, max_kept_turns).cut);
    // Too little room for both compacts the exchange whole, never one result
    // of it, and so does a model that could not take it.
    try testing.expectEqual(Recent{ .cut = .{ .turns = 2 } }, selectRecentContext(&history, 5000, null, selection, max_kept_turns));
    try testing.expectEqual(Recent{ .cut = .{ .turns = 2 } }, selectRecentContext(&history, 100_000, 10_000, selection, max_kept_turns));
    try testing.expectEqualStrings(body, results[0].output);
    try testing.expectEqualStrings(body, results[1].output);
}

test "retained context keeps at most the requested number of turns" {
    var history: [6]HistoryTurn = undefined;
    for (&history) |*turn| turn.* = .{ .assistant = .{ .user = .{ .text = @constCast("question") }, .assistant = @constCast("answer") } };
    // The oldest turn is always compacted.
    try testing.expectEqual(@as(usize, 1), selectRecentContext(&history, 100_000, null, selection, 6).cut.turns);
    try testing.expectEqual(@as(usize, 2), selectRecentContext(&history, 100_000, null, selection, 4).cut.turns);
}

test "automatic compaction starts at the configured share of usable input" {
    const capabilities = model_capabilities.Capabilities{ .context_window = 1_000_000, .max_output_tokens = 128_000 };
    try testing.expectEqual(@as(?usize, 697_600), compactAtTokens(capabilities, 80));
    try testing.expectEqual(@as(?usize, 87_200), compactAtTokens(capabilities, 10));
    try testing.expectEqual(@as(?usize, 697_600), compactAtTokens(capabilities, 100));
    try testing.expectEqual(@as(?usize, 87_200), compactAtTokens(capabilities, 1));
    try testing.expectEqual(@as(?usize, null), compactAtTokens(.{}, 80));
}

test "the compacted text may use half the compaction point, less the fixed part and the kept turns" {
    const size: Size = .{ .compact_at_tokens = 100_000, .usable_tokens = 125_000, .fixed_tokens = 10_000 };
    try testing.expectEqual(@as(usize, 35_000), size.compactedTokens(5_000));
    // A fixed part that fills the half leaves a quarter of it.
    const crowded: Size = .{ .compact_at_tokens = 100_000, .usable_tokens = 125_000, .fixed_tokens = 60_000 };
    try testing.expectEqual(@as(usize, 12_500), crowded.compactedTokens(0));
    const unknown: Size = .{ .compact_at_tokens = null, .usable_tokens = null };
    try testing.expectEqual(std.math.maxInt(usize), unknown.compactedTokens(0));
}

test "the kept turns get a share of a fifth of the usable input, less the fixed part" {
    // 1,000,000 usable, compacting at 80%: the whole request may then use
    // 200,000, of which 12,000 is fixed.
    const large = Size{ .compact_at_tokens = 800_000, .usable_tokens = 1_000_000, .fixed_tokens = 12_000 };
    try testing.expectEqual(@as(usize, 200_000), large.afterTokens());
    try testing.expectEqual(@as(usize, 188_000), large.conversationTokens());
    // A low compaction point keeps the room at half of it, so compaction
    // always frees room.
    try testing.expectEqual(@as(usize, 50_000), (Size{ .compact_at_tokens = 100_000, .usable_tokens = 1_000_000 }).afterTokens());
    // An unmeasured fixed part is taken as half the room, and a fixed part
    // that fills the room still leaves a quarter of it.
    try testing.expectEqual(@as(usize, 100_000), (Size{ .compact_at_tokens = 800_000, .usable_tokens = 1_000_000 }).conversationTokens());
    try testing.expectEqual(@as(usize, 50_000), (Size{ .compact_at_tokens = 800_000, .usable_tokens = 1_000_000, .fixed_tokens = 190_000 }).conversationTokens());
    try testing.expectEqual(std.math.maxInt(usize), (Size{ .compact_at_tokens = null, .usable_tokens = null }).conversationTokens());
    // When the provider counts a third more tokens than fx estimates, the
    // compactor's estimated room shrinks to match.
    var counted_more = large;
    counted_more.correction = .{ .estimated = 30_000, .measured = 40_000 };
    try testing.expectEqual(@as(usize, 141_000), counted_more.conversationTokens());
    try testing.expectEqual(@as(usize, 750_000), counted_more.summaryRequestTokens());

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var history: [6]HistoryTurn = undefined;
    for (&history) |*turn| turn.* = .{ .assistant = .{ .user = .{ .text = @constCast("question") }, .assistant = @constCast("answer") } };
    const window = (try choose(arena_state.allocator(), &history, null, large, selection, .{})).?;
    try testing.expectEqual(@as(usize, 75_200), window.kept_tokens);
    try testing.expect(window.kept_used > 0 and window.kept_used <= window.kept_tokens);
}

test "the window keeps the newest turns and compacts the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var history: [7]HistoryTurn = undefined;
    history[0] = .{ .compacted_summary = .{ .summary = @constCast("earlier checkpoint"), .removed_turn_count = 3, .compaction_count = 1 } };
    for (history[1..]) |*turn| turn.* = .{ .assistant = .{ .user = .{ .text = @constCast("question") }, .assistant = @constCast("answer") } };
    const window = try split(arena, &history, null, 100_000, null, selection);
    try testing.expectEqual(types.ContextHistoryCut{ .turns = 2 }, window.cut);
    try testing.expectEqualStrings("earlier checkpoint", window.earlier.?);
    try testing.expectEqual(@as(usize, 4), window.retained_history.len);
    const everything = try split(arena, &history, null, 0, null, selection);
    try testing.expectEqual(types.ContextHistoryCut{ .turns = 6 }, everything.cut);
    try testing.expectEqual(@as(usize, 0), everything.retained_history.len);
}

test "the window ends an unfinished turn at its completed exchange" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const calls = [_]types.ToolCall{.{ .id = "large-write", .name = "write_file", .arguments_json = "x" ** 32_000 }};
    const results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("large-write"),
        .tool_name = @constCast("write_file"),
        .status = .success,
        .output = @constCast("written"),
        .output_bytes = 7,
        .stored_output_bytes = 7,
    }};
    const steps = [_]types.ToolExecutionStep{.{ .tool_calls = @constCast(&calls), .tool_results = @constCast(&results) }};
    const turn = types.AssistantHistoryTurn{
        .user = .{ .text = @constCast("write once") },
        .assistant = @constCast(""),
        .execution = .{ .tool_steps = @constCast(&steps) },
    };
    const active = try split(arena_state.allocator(), &.{}, turn, 800, 4_000, selection);
    try testing.expectEqual(types.ContextHistoryCut{ .tool_steps = 1 }, active.cut);
    try testing.expectEqual(@as(usize, 1), active.older.len);
    try testing.expectEqual(@as(usize, 0), active.retained_history.len);
    const saved = try split(arena_state.allocator(), &.{.{ .assistant = turn }}, null, 800, 4_000, selection);
    try testing.expectEqual(types.ContextHistoryCut{ .turns = 1 }, saved.cut);
    try testing.expectEqual(@as(usize, 0), saved.retained_history.len);
}

test "what stays after the cut includes the rest of an unfinished turn" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const calls = [_]types.ToolCall{
        .{ .id = "large-write", .name = "write_file", .arguments_json = "x" ** 32_000 },
        .{ .id = "small-read", .name = "read_file", .arguments_json = "{\"path\":\"src/a.zig\"}" },
    };
    const results = [_]types.PersistedToolResult{
        .{ .tool_call_id = @constCast("large-write"), .tool_name = @constCast("write_file"), .status = .success, .output = @constCast("written"), .output_bytes = 7, .stored_output_bytes = 7 },
        .{ .tool_call_id = @constCast("small-read"), .tool_name = @constCast("read_file"), .status = .success, .output = @constCast("const a = 1;"), .output_bytes = 12, .stored_output_bytes = 12 },
    };
    const steps = [_]types.ToolExecutionStep{
        .{ .tool_calls = @constCast(calls[0..1]), .tool_results = @constCast(results[0..1]) },
        .{ .tool_calls = @constCast(calls[1..2]), .tool_results = @constCast(results[1..2]) },
    };
    const turn = types.AssistantHistoryTurn{
        .user = .{ .text = @constCast("write, then read") },
        .assistant = @constCast(""),
        .execution = .{ .tool_steps = @constCast(&steps) },
    };
    const window = try split(arena_state.allocator(), &.{}, turn, 800, 4_000, selection);
    try testing.expectEqual(types.ContextHistoryCut{ .tool_steps = 1 }, window.cut);
    // The unfinished turn is not in the history, so nothing of it is retained
    // there, but its newest call stays in the conversation.
    try testing.expectEqual(@as(usize, 0), window.retained_history.len);
    try testing.expectEqual(@as(usize, 1), window.kept.len);
    const kept_steps = window.kept[0].assistant.execution.tool_steps;
    try testing.expectEqual(@as(usize, 1), kept_steps.len);
    try testing.expectEqualStrings("small-read", kept_steps[0].tool_calls[0].id);
}

test "nothing is compacted unless it is due or required" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const history = [_]HistoryTurn{.{ .assistant = .{ .user = .{ .text = @constCast("hi") }, .assistant = @constCast("hello") } }};
    // One small turn fits the kept budget: nothing to compact.
    try testing.expect(try choose(arena, &history, null, .{ .compact_at_tokens = 100_000, .usable_tokens = 120_000 }, selection, .{}) == null);
    // A request the model cannot take forces everything into the summary.
    const forced = (try choose(arena, &history, null, .{ .compact_at_tokens = 100_000, .usable_tokens = 120_000, .request_tokens = 130_000 }, selection, .{})).?;
    try testing.expectEqual(@as(usize, 0), forced.kept_tokens);
    try testing.expectEqual(@as(usize, 1), forced.older.len);
    // With nothing left to compact, the request cannot be sent.
    try testing.expectError(error.ContextCapacityExceeded, choose(arena, &.{}, null, .{ .compact_at_tokens = 100_000, .usable_tokens = 120_000, .overflow = true, .request_tokens = 130_000 }, selection, .{}));
}

test "a summary request may use the usable input, less after an overflow" {
    try testing.expectEqual(std.math.maxInt(usize), (Size{ .compact_at_tokens = null, .usable_tokens = null }).summaryRequestTokens());
    try testing.expectEqual(@as(usize, 120_000), (Size{ .compact_at_tokens = 96_000, .usable_tokens = 120_000, .request_tokens = 110_000 }).summaryRequestTokens());
    // The provider rejected an estimated 100,000 tokens.
    try testing.expectEqual(@as(usize, 75_000), (Size{ .compact_at_tokens = 96_000, .usable_tokens = 120_000, .request_tokens = 100_000, .overflow = true }).summaryRequestTokens());
}

test "a request after the conversation gets what the conversation leaves" {
    try testing.expectEqual(@as(?usize, 10_000), (Size{ .compact_at_tokens = 96_000, .usable_tokens = 120_000, .request_tokens = 110_000 }).roomAfterConversation());
    // In fx's estimate when the provider counts a third more.
    try testing.expectEqual(@as(?usize, 7_500), (Size{ .compact_at_tokens = 96_000, .usable_tokens = 120_000, .request_tokens = 110_000, .correction = .{ .estimated = 30_000, .measured = 40_000 } }).roomAfterConversation());
    try testing.expectEqual(@as(?usize, null), (Size{ .compact_at_tokens = 96_000, .usable_tokens = 120_000 }).roomAfterConversation());
    try testing.expectEqual(@as(?usize, null), (Size{ .compact_at_tokens = 96_000, .usable_tokens = 120_000, .request_tokens = 120_000 }).roomAfterConversation());
    try testing.expectEqual(@as(?usize, null), (Size{ .compact_at_tokens = 96_000, .usable_tokens = 120_000, .request_tokens = 100_000, .overflow = true }).roomAfterConversation());
}
