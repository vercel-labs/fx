//! The reasoning effort of a session's requests for a model that takes effort
//! changes as messages. Every request names the session's first effort: a
//! change of the request's own effort drops the whole prompt cache. A turn
//! that asks for another one sends an update right before its message, and
//! saves that decision, so every later request sends the turn the same way
//! (D103, `tests/tla/prompt_context/PromptCache.tla` "effort",
//! `tests/tla/compaction/ProviderCompaction.tla` RunsAsAsked).

const std = @import("std");
const types = @import("../../shared/types.zig");
const compactor = @import("../../compactor/compactor.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const session = @import("../../session/session.zig");

const Allocator = std.mem.Allocator;

/// The first effort a turn of `history` saved. A provider block's saved
/// anchor takes its place, since the turns before the block are gone from the
/// history. fx's own summary, or a block without an anchor, clears it: the
/// request after it starts a new prefix. Null when none applies, so the
/// current turn's effort is the anchor. Reads summaries into `arena`.
pub fn sessionAnchor(arena: Allocator, history: []const types.HistoryTurn) Allocator.Error!?types.ReasoningEffort {
    var anchor: ?types.ReasoningEffort = null;
    for (history, 0..) |turn, index| {
        if (session.isSupersededResume(history, index)) continue;
        const saved = switch (turn) {
            .compacted_summary => |entry| {
                anchor = try blockAnchor(arena, entry.summary);
                continue;
            },
            .assistant => |entry| entry.execution.turn_effort,
            .interrupted => |entry| entry.execution.turn_effort,
        };
        if (anchor == null) anchor = saved;
    }
    return anchor;
}

pub const Decision = struct {
    /// The effort every request names: the session's first.
    anchor: types.ReasoningEffort,
    /// The update right before the turn's message, or null for none.
    update: ?types.ReasoningEffort,
};

/// What a turn that asks for `asked` sends after `history`, for a model that
/// lists `listed`. The model runs at the request's own effort plus the
/// updates sent after the newest checkpoint: measured live, a provider's
/// block does not keep the effort the turns it replaced had set. Reads
/// summaries into `arena`.
pub fn decide(arena: Allocator, history: []const types.HistoryTurn, listed: []const types.ReasoningEffort, asked: types.ReasoningEffort) Allocator.Error!Decision {
    const anchor = (try sessionAnchor(arena, history)) orelse asked;
    const runs_at = lastUpdate(history, listed) orelse model_capabilities.requestEffort(listed, anchor);
    return .{ .anchor = anchor, .update = model_capabilities.effortUpdate(listed, runs_at, asked) };
}

/// The newest update a turn after the newest checkpoint saved, of those the
/// model lists: the request writer leaves out any other, and every request
/// leaves out a resume a later one replaced.
fn lastUpdate(history: []const types.HistoryTurn, listed: []const types.ReasoningEffort) ?types.ReasoningEffort {
    var update: ?types.ReasoningEffort = null;
    for (history, 0..) |turn, index| {
        if (session.isSupersededResume(history, index)) continue;
        const saved = switch (turn) {
            .compacted_summary => {
                update = null;
                continue;
            },
            .assistant => |entry| entry.execution.effort_update,
            .interrupted => |entry| entry.execution.effort_update,
        };
        if (saved) |value| if (model_capabilities.listsEffort(listed, value)) {
            update = value;
        };
    }
    return update;
}

fn blockAnchor(arena: Allocator, summary: []const u8) Allocator.Error!?types.ReasoningEffort {
    const block = (try compactor.providerBlock(arena, summary)) orelse return null;
    const label = block.reasoning_anchor orelse return null;
    return types.ReasoningEffort.parse(label);
}

fn turnAt(asked: ?types.ReasoningEffort) types.HistoryTurn {
    return turnSent(asked, null);
}

fn turnSent(asked: ?types.ReasoningEffort, update: ?types.ReasoningEffort) types.HistoryTurn {
    return .{ .assistant = .{
        .user = .{ .text = @constCast("question") },
        .assistant = @constCast("answer"),
        .execution = .{ .turn_effort = asked, .effort_update = update },
    } };
}

fn summaryTurn(text: []const u8) types.HistoryTurn {
    return .{ .compacted_summary = .{ .summary = @constCast(text), .removed_turn_count = 1, .compaction_count = 1 } };
}

fn expectAnchor(want: ?[]const u8, history: []const types.HistoryTurn) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try sessionAnchor(arena_state.allocator(), history);
    if (want) |label| {
        try std.testing.expectEqualStrings(label, got.?.label());
    } else {
        try std.testing.expect(got == null);
    }
}

const effort = types.ReasoningEffort.literal;
const block_with_anchor = "fx-compactor-v1\n{\"provider\":{\"provider\":\"gateway\",\"model\":\"openai/gpt-6.1-sol\",\"parts_json\":\"[]\",\"kept_turns\":2,\"reasoning_anchor\":\"xhigh\"}}";
const block_without_anchor = "fx-compactor-v1\n{\"provider\":{\"provider\":\"gateway\",\"model\":\"openai/gpt-6.1-sol\",\"parts_json\":\"[]\",\"kept_turns\":2}}";
const block_with_bad_anchor = "fx-compactor-v1\n{\"provider\":{\"provider\":\"gateway\",\"model\":\"openai/gpt-6.1-sol\",\"parts_json\":\"[]\",\"reasoning_anchor\":\"!!\"}}";

test "the anchor is the first effort a turn saved, not a later one" {
    try expectAnchor("high", &.{ turnAt(effort("high")), turnAt(effort("low")), turnAt(null), turnAt(effort("medium")) });
    // A turn on another model saved none; the first that saved one counts.
    try expectAnchor("low", &.{ turnAt(null), turnAt(effort("low")), turnAt(effort("high")) });
    try expectAnchor("auto", &.{ turnAt(.auto), turnAt(effort("high")) });
    try expectAnchor(null, &.{ turnAt(null), turnAt(null) });
    try expectAnchor(null, &.{});
}

test "a provider block keeps the anchor its compaction was sent with, over the efforts of the turns it kept" {
    try expectAnchor("xhigh", &.{ summaryTurn(block_with_anchor), turnAt(effort("low")), turnAt(effort("high")) });
    try expectAnchor("xhigh", &.{ turnAt(effort("high")), summaryTurn(block_with_anchor), turnAt(effort("low")) });
    try expectAnchor("xhigh", &.{summaryTurn(block_with_anchor)});
}

test "fx's own summary, or a block without a readable anchor, starts the anchor again" {
    try expectAnchor("low", &.{ turnAt(effort("high")), summaryTurn("Turn 1\nIn between: none"), turnAt(effort("low")), turnAt(effort("high")) });
    try expectAnchor(null, &.{ turnAt(effort("high")), summaryTurn("Turn 1\nIn between: none") });
    try expectAnchor("low", &.{ turnAt(effort("high")), summaryTurn(block_without_anchor), turnAt(effort("low")) });
    try expectAnchor("low", &.{ summaryTurn(block_with_bad_anchor), turnAt(effort("low")) });
}

const gpt6_levels = [_]types.ReasoningEffort{ effort("low"), effort("medium"), effort("high"), effort("xhigh") };
const block_anchor_high = "fx-compactor-v1\n{\"provider\":{\"provider\":\"gateway\",\"model\":\"openai/gpt-6.1-sol\",\"parts_json\":\"[]\",\"kept_turns\":2,\"reasoning_anchor\":\"high\"}}";

fn expectDecision(anchor: []const u8, update: ?[]const u8, history: []const types.HistoryTurn, asked: types.ReasoningEffort) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try decide(arena_state.allocator(), history, &gpt6_levels, asked);
    try std.testing.expectEqualStrings(anchor, got.anchor.label());
    if (update) |label| {
        try std.testing.expectEqualStrings(label, got.update.?.label());
    } else {
        try std.testing.expect(got.update == null);
    }
}

test "a session's first turn is its anchor and sends no update" {
    try expectDecision("high", null, &.{}, effort("high"));
    try expectDecision("high", "low", &.{turnSent(effort("high"), null)}, effort("low"));
    try expectDecision("high", null, &.{ turnSent(effort("high"), null), turnSent(effort("low"), effort("low")) }, effort("low"));
}

test "(a) after a block, a new turn decides against the anchor and the kept turns' saved updates, not the replaced turns" {
    // The replaced turns set low; the kept turns asked low and sent nothing.
    try expectDecision("high", "low", &.{ summaryTurn(block_anchor_high), turnSent(effort("low"), null), turnSent(effort("low"), null) }, effort("low"));
}

test "(b) a kept turn's own update counts, so a new turn asking for it sends none" {
    try expectDecision("high", null, &.{ summaryTurn(block_anchor_high), turnSent(effort("low"), null), turnSent(effort("low"), effort("low")) }, effort("low"));
}

test "(c) a new turn after a block that asks for the anchor sends none" {
    try expectDecision("high", null, &.{ summaryTurn(block_anchor_high), turnSent(effort("low"), null) }, effort("high"));
    // An update before the block counts no more.
    try expectDecision("high", null, &.{ turnSent(effort("high"), null), turnSent(effort("low"), effort("low")), summaryTurn(block_anchor_high) }, effort("high"));
}

test "(d) after an older block without an anchor, or fx's own summary, the anchor starts again from the turns after it" {
    try expectDecision("low", "xhigh", &.{ summaryTurn(block_without_anchor), turnSent(effort("low"), null) }, effort("xhigh"));
    try expectDecision("low", null, &.{ turnSent(effort("high"), null), turnSent(effort("low"), effort("low")), summaryTurn("Turn 1\nIn between: none"), turnSent(effort("low"), null) }, effort("low"));
    // Only updates after fx's summary count, and the turn that follows it alone is the anchor.
    try expectDecision("medium", null, &.{ turnSent(effort("high"), null), turnSent(effort("low"), effort("low")), summaryTurn("Turn 1\nIn between: none") }, effort("medium"));
}

test "a saved update the model does not list counts as not sent" {
    // xhigh is not listed by this model, so the writer left it out and the model stayed at the anchor.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const without_xhigh = [_]types.ReasoningEffort{ effort("low"), effort("medium"), effort("high") };
    const got = try decide(arena_state.allocator(), &.{ turnSent(effort("high"), null), turnSent(effort("xhigh"), effort("xhigh")) }, &without_xhigh, effort("high"));
    try std.testing.expect(got.update == null);
    const low = try decide(arena_state.allocator(), &.{ turnSent(effort("high"), null), turnSent(effort("xhigh"), effort("xhigh")) }, &without_xhigh, effort("low"));
    try std.testing.expectEqualStrings("low", low.update.?.label());
}

test "a resume a later one replaced is never sent, so its update counts as not sent" {
    const resume_text = @constCast(session.resumed_request_prompt);
    const stopped: types.HistoryTurn = .{ .interrupted = .{
        .user = .{ .text = @constCast("question") },
        .execution = .{ .turn_effort = effort("high") },
    } };
    // The first resume asked medium and sent an update, then stopped before it ran anything.
    const replaced: types.HistoryTurn = .{ .interrupted = .{
        .user = .{ .text = resume_text },
        .execution = .{ .turn_effort = effort("medium"), .effort_update = effort("medium") },
    } };
    // The next resume left it out of its request and sent no update.
    const next_resume: types.HistoryTurn = .{ .assistant = .{
        .user = .{ .text = resume_text },
        .assistant = @constCast("answer"),
        .execution = .{ .turn_effort = effort("high") },
    } };
    try expectDecision("high", "medium", &.{ stopped, replaced, next_resume }, effort("medium"));
    // Without the later resume it was sent, and it counts.
    try expectDecision("high", null, &.{ stopped, replaced }, effort("medium"));
}

test "after a block that keeps a turn with its own update, a new turn decides against that update, in the order fx compacts and sends" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Turns 1 to 4 asked high; turn 5 asked low and sent it; turn 6 asked low.
    const before = [_]types.HistoryTurn{
        turnSent(effort("high"), null),         turnSent(effort("high"), null), turnSent(effort("high"), null), turnSent(effort("high"), null),
        turnSent(effort("low"), effort("low")), turnSent(effort("low"), null),
    };
    // The history a compaction leaves, built as every host builds it: the
    // block first, then the kept turns 5 and 6.
    const history = try session.prepareCompactedHistory(arena, &before, .{
        .summary = @constCast(block_anchor_high),
        .removed_turn_count = 4,
        .compaction_count = 1,
    }, .{ .turns = 4 });
    try expectDecision("high", "high", history, effort("high"));
    try std.testing.expect(history[0] == .compacted_summary);
    // The request sends the block first and turn 5's update after it, in the
    // order `decide` read them.
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    try session.appendActiveContextHistoryChatMessages(arena, &messages, history, 0);
    var update_at: ?usize = null;
    for (messages.items, 0..) |message, index| {
        if (message.effort_update) |update| {
            try std.testing.expect(update_at == null);
            try std.testing.expectEqualStrings("low", update.label());
            update_at = index;
        }
    }
    try std.testing.expect(update_at.? > 0);
}
