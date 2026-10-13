//! fx-compactor: the one way fx compacts a conversation. Manual `/compact`,
//! automatic compaction and recovery from a provider overflow all call
//! `compact`.
//!
//! In: the raw conversation, how large it is, and the model it uses.
//! Out: the checkpoint that replaces the older turns, and the text the model
//! reads in their place.
//!
//! Inside:
//! - window.zig chooses what to compact; the newest turns stay unchanged.
//! - summarize.zig keeps user messages and final replies exact, adds the
//!   model's notes for the new turns, and gives every turn (M1, M2, ...) and
//!   tool call (T1, T2, ...) a handle.
//! - ledger.zig asks for the notes and reads what the model wrote.
//! - lint.zig checks every note and entry against the saved turns and tool
//!   calls, and marks what it cannot confirm.
//! - model.zig asks the conversation's model, at its lowest reasoning, with a
//!   fallback model.
//! - records.zig saves the M, T and L records and searches them.
//! - checkpoint.zig is the saved format; settings.zig is the threshold setting.
//!
//! Saving the checkpoint into the session and showing progress stay with the
//! caller.

const std = @import("std");
const window = @import("window.zig");
const summarize = @import("summarize.zig");
const ledger = @import("ledger.zig");
const model = @import("model.zig");
const checkpoint = @import("checkpoint.zig");
const records = @import("records.zig");
const settings = @import("settings.zig");
const trace = @import("trace.zig");
const model_provider = @import("../config/model_provider.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const Size = window.Size;

// Reaching the model; the caller hands in a `ModelCaller`.
pub const ModelCaller = model.ModelCaller;
pub const Call = model.Call;
pub const CallError = model.CallError;
pub const Reply = model.Reply;

// Compaction notes: the `context_compaction` trace scope and the bounded
// events `/trace` shows.
pub const traceEvent = trace.info;
pub const traceFailure = trace.failure;
pub const traceEventIf = trace.infoIf;
pub const traceLog = trace.log;
pub const TraceEvent = trace.Event;
pub const trace_ring_capacity = trace.ring_capacity;
pub const snapshotTrace = trace.snapshot;
pub const resetTrace = trace.reset;

// The `auto_compact_percent` setting.
pub const default_percent = settings.default_percent;
pub const isValidPercent = settings.isValidPercent;
pub const resolvePercent = settings.resolvePercent;

// Saved checkpoints, read back when a session is loaded or shown.
pub const modelText = checkpoint.modelText;
pub const replacesPriorContext = checkpoint.replacesPriorContext;

// Saved turns (M1, M2, ...), tool calls (T1, T2, ...) and earlier
// compactions (L1, L2, ...).
pub const Store = records.Store;
pub const max_search_phrases = records.max_search_phrases;
pub const RecordFileBuffer = [records.max_file_name_bytes]u8;

/// The saved file of a record ID the agent typed ("T12", "M12", "L2"), or null
/// when `text` is not one.
pub fn recordFile(buffer: *RecordFileBuffer, text: []const u8) ?[]const u8 {
    return records.fileName(buffer, records.parseId(text) orelse return null);
}

/// Searches every saved turn, tool call and earlier compaction, and older
/// conversation archives, for 1 to `max_search_phrases` phrases. Caller owns
/// the text.
pub fn search(alloc: Allocator, store: Store, phrases: []const []const u8) ![]u8 {
    return records.search(alloc, store, phrases, records.search_result_limit);
}

/// Steps reported to the caller while a compaction runs.
pub const Step = enum {
    /// The part to compact is chosen; nothing has been sent yet.
    chosen,
    /// The summary request is about to be sent.
    summarizing,
};

pub const Progress = struct {
    context: *anyopaque,
    /// An error stops the compaction.
    report_fn: *const fn (context: *anyopaque, step: Step) anyerror!void,

    fn report(self: ?Progress, step: Step) !void {
        if (self) |progress| try progress.report_fn(progress.context, step);
    }
};

/// Appends the chat messages the model saw for `history`. The session owns
/// that projection, so the caller hands it in.
const AppendMessages = *const fn (
    alloc: Allocator,
    messages: *std.ArrayList(types.ChatMessage),
    history: []const types.HistoryTurn,
) AppendMessagesError!void;

/// The errors the session's projection declares.
const AppendMessagesError = Allocator.Error || error{InvalidReplayHandle};

pub const Request = struct {
    /// The saved conversation, oldest first, including earlier checkpoints.
    history: []const types.HistoryTurn,
    /// The session's projection of saved turns into the messages the model
    /// saw.
    append_messages: AppendMessages,
    /// The turn still running when compaction happens in the middle of it.
    active: ?types.AssistantHistoryTurn = null,
    size: Size,
    /// Reaches the conversation's model, which writes the summary.
    caller: ModelCaller,
    /// Where M, T and L records are saved. Without one (a session that is
    /// not saved), everything goes into the summary and earlier compactions
    /// are never folded away.
    records: ?Store,
    cancel_flag: *std.atomic.Value(bool),
    trace_ctx: debug_trace.TraceContext,
    progress: ?Progress = null,
};

/// Owns everything it points to except the turns it shares with
/// `Request.history`. Call `deinit` when done.
pub const Result = struct {
    arena: *std.heap.ArenaAllocator,
    /// Save this in place of the compacted turns.
    checkpoint: types.CompactedSummaryHistoryTurn,
    /// What the model reads in place of the compacted turns.
    model_text: []const u8,
    /// The raw turns that stay after the checkpoint.
    retained_history: []types.HistoryTurn,
    /// Where the compacted part ends.
    cut: types.ContextHistoryCut,
    tool_count: usize,

    pub fn deinit(self: *Result) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.* = undefined;
    }
};

/// Compacts the conversation. Null when nothing needs compacting. Blocks while
/// the model writes the summary.
pub fn compact(alloc: Allocator, request: Request) !?Result {
    const caller = request.caller;
    const trace_ctx = request.trace_ctx;
    const arena = try alloc.create(std.heap.ArenaAllocator);
    errdefer alloc.destroy(arena);
    arena.* = .init(alloc);
    errdefer arena.deinit();
    const out = arena.allocator();

    const chosen = try window.choose(
        out,
        request.history,
        request.active,
        request.size,
        .{ .provider = caller.provider, .model = caller.model },
        trace_ctx,
    ) orelse {
        arena.deinit();
        alloc.destroy(arena);
        return null;
    };
    // Cancellation is checked only after `.chosen`, so a caller showing
    // progress always sees the compaction it cancelled.
    try Progress.report(request.progress, .chosen);
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (!model_provider.authorizesCredential(caller.provider, caller.credential_source)) {
        trace.failure(
            trace_ctx,
            .credential_unauthorized,
            "provider={s} credential_source={s}",
            .{ @tagName(caller.provider), if (caller.credential_source) |source| @tagName(source) else "none" },
        );
        return error.ContextCompactionUnavailable;
    }
    try Progress.report(request.progress, .summarizing);
    trace.log(false, "room after compaction after_tokens={d} fixed_tokens={any} kept_tokens={d} kept_used={d} compacted_tokens={d}", .{ request.size.afterTokens(), request.size.fixed_tokens, chosen.kept_tokens, chosen.kept_used, request.size.compactedTokens(chosen.kept_used) });

    const earlier = try earlierFrom(out, request.records, chosen.earlier);
    const turns = try turnsFrom(out, chosen.older, request.append_messages);
    if (turns.len == 0) return error.NothingToCompact;
    var summarizer: model.Summarizer = .{ .caller = caller, .cancel_flag = request.cancel_flag, .trace_ctx = trace_ctx };
    trace.info(trace_ctx, .provider_start, "model={s} turns={d} earlier={} store={}", .{ caller.model, turns.len, chosen.earlier != null, request.records != null });
    // The caller's allocator, so the summary gives its working memory back
    // when it is done instead of keeping it in this result.
    var summary = try summarize.compact(alloc, .{
        .model = caller.model,
        .earlier = earlier,
        .turns = turns,
        .last_turn_open = chosen.splitsLastTurn(),
        .kept = try turnsFrom(out, chosen.kept, request.append_messages),
        .max_prompt_tokens = request.size.summaryRequestTokens(),
        .conversation_room = if (caller.sends_after_conversation) request.size.roomAfterConversation() else null,
        .max_text_tokens = request.size.compactedTokens(chosen.kept_used),
    }, summarizer.model(), request.records);
    defer summary.deinit();
    trace.info(trace_ctx, .provider_completed, "model={s} summaries={d} shown_turns={d} turns={d} tools={d} entries={d} used={d} text_bytes={d} fallback={s}", .{ caller.model, summarizer.summaries, summary.compacted.turns.len, summary.compacted.turn_count, summary.compacted.tool_count, summary.compacted.entries.len, summary.compacted.used.len, summary.text.len, summarizer.fallback_used orelse "none" });

    return .{
        .arena = arena,
        .checkpoint = .{
            .summary = try checkpoint.encode(out, summary.compacted),
            .removed_turn_count = chosen.cut.turns,
            .compaction_count = latestCompactionCount(request.history) + 1,
        },
        .model_text = try out.dupe(u8, summary.text),
        .retained_history = chosen.retained_history,
        .cut = chosen.cut,
        .tool_count = summary.compacted.tool_count,
    };
}

fn latestCompactionCount(history: []const types.HistoryTurn) usize {
    var count: usize = 0;
    for (history) |turn| {
        if (turn == .compacted_summary) count = @max(count, turn.compacted_summary.compaction_count);
    }
    return count;
}

/// The previous compaction. A checkpoint from before this format becomes an
/// earlier summary, with its exact user messages when its state file is
/// readable.
fn earlierFrom(arena: Allocator, store: ?Store, earlier: ?[]const u8) !?summarize.Compacted {
    const saved = earlier orelse return null;
    if (try checkpoint.parse(arena, saved)) |payload| return payload;
    if (try legacyEarlier(arena, store, saved)) |legacy| return legacy;
    // An unreadable checkpoint may have saved turns, tool calls and ledgers
    // already; numbering after them keeps the new ones from replacing them.
    const highest: records.Highest = if (store) |kept| try records.highestSaved(arena, kept) else .{};
    if (highest.turns > 0 or highest.tools > 0 or highest.ledgers > 0) trace.log(false, "earlier checkpoint unreadable; new records are numbered after the saved ones turns={d} tools={d} ledgers={d}", .{ highest.turns, highest.tools, highest.ledgers });
    return .{ .earlier = saved, .turn_count = highest.turns, .tool_count = highest.tools, .ledger_count = highest.ledgers };
}

/// The first user message starts each turn; later ones are messages the user
/// added while it ran. Notes that fx itself added stay notes, so they never
/// count as user messages.
fn turnsFrom(arena: Allocator, history: []const types.HistoryTurn, append_messages: AppendMessages) ![]const summarize.Turn {
    var turns: std.ArrayList(summarize.Turn) = .empty;
    var messages: std.ArrayList(types.ChatMessage) = .empty;
    for (history, 0..) |turn, index| {
        if (turn == .compacted_summary) continue;
        messages.clearRetainingCapacity();
        try append_messages(arena, &messages, history[index .. index + 1]);
        var projected = messages.items;
        var user: []const u8 = "";
        if (projected.len > 0 and projected[0].role == .user and projected[0].context_origin == .user_turn and !projected[0].restored_steering) {
            user = projected[0].content orelse "";
            projected = projected[1..];
        }
        var items: std.ArrayList(summarize.Item) = .empty;
        for (projected) |message| try appendItems(arena, &items, message);
        try turns.append(arena, .{ .user = user, .items = items.items });
    }
    return turns.items;
}

/// A checkpoint from the previous compactor keeps its user messages word for
/// word in a state file; those carry over exactly instead of being
/// summarized again. Null when the state file is missing or does not match.
fn legacyEarlier(arena: Allocator, store: ?Store, summary: []const u8) !?summarize.Compacted {
    const ref = checkpoint.legacyStateRef(summary) orelse return null;
    const bytes = try records.readExact(arena, store orelse return null, ref.handle, ref.bytes) orelse return null;
    return checkpoint.parseLegacyState(arena, ref, bytes);
}

fn appendItems(arena: Allocator, items: *std.ArrayList(summarize.Item), message: types.ChatMessage) !void {
    const content = message.content orelse "";
    switch (message.role) {
        .system => {},
        .user => if (message.context_origin == .user_turn) {
            try items.append(arena, .{ .user = content });
        } else if (content.len > 0) {
            try items.append(arena, .{ .note = if (message.permission_feedback)
                try arena.print("Permission feedback: {s}", .{content})
            else
                content });
        },
        .assistant => {
            if (content.len > 0) try items.append(arena, .{ .assistant = content });
            for (message.tool_calls) |call| {
                try items.append(arena, .{ .tool_call = .{ .id = call.id, .name = call.name, .arguments = call.arguments_json } });
            }
        },
        .tool => try items.append(arena, .{ .tool_result = .{
            .call_id = message.tool_call_id orelse "",
            .name = message.tool_name orelse "",
            .output = content,
            .saved_output = savedOutputHandle(message.tool_result_memory, content),
            .failed = message.tool_result_status == .failure,
            .answers = if (std.mem.eql(u8, message.tool_name orelse "", question_tool)) try questionAnswers(arena, content) else &.{},
        } }),
    }
}

/// The tool that asks the user questions. Its result lists each question
/// with the user's answer.
const question_tool = "ask_user_question";

/// The user's answers in a question tool's result. None when the result does
/// not list answers, as when the question was not answered.
fn questionAnswers(arena: Allocator, output: []const u8) Allocator.Error![]const []const u8 {
    const Answered = struct { answer: []const u8 };
    const answered = std.json.parseFromSliceLeaky([]const Answered, arena, output, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    const answers = try arena.alloc([]const u8, answered.len);
    for (answers, answered) |*answer, item| answer.* = item.answer;
    return answers;
}

test "a question's result gives the user's answers, not the questions" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const answers = try questionAnswers(arena, "[{\"question\":\"Which block first?\",\"answer\":\"Block 6 before Block 5\"},{\"question\":\"Push it?\",\"answer\":\"Legitimate, push\"}]");
    try std.testing.expectEqual(@as(usize, 2), answers.len);
    try std.testing.expectEqualStrings("Block 6 before Block 5", answers[0]);
    try std.testing.expectEqualStrings("Legitimate, push", answers[1]);
    // A result that lists no answers, like an error, gives none.
    try std.testing.expectEqual(@as(usize, 0), (try questionAnswers(arena, "The user dismissed the question.")).len);
    try std.testing.expectEqual(@as(usize, 0), (try questionAnswers(arena, "[{\"question\":\"Push it?\"}]")).len);

    // Only the question tool's result carries answers into the turn.
    const result = "[{\"question\":\"Push it?\",\"answer\":\"Legitimate, push\"}]";
    var items: std.ArrayList(summarize.Item) = .empty;
    try appendItems(arena, &items, .{ .role = .tool, .tool_call_id = "q", .tool_name = question_tool, .content = result });
    try appendItems(arena, &items, .{ .role = .tool, .tool_call_id = "s", .tool_name = "shell", .content = result });
    try std.testing.expectEqual(@as(usize, 1), items.items[0].tool_result.answers.len);
    try std.testing.expectEqualStrings("Legitimate, push", items.items[0].tool_result.answers[0]);
    try std.testing.expectEqual(@as(usize, 0), items.items[1].tool_result.answers.len);
}

/// The handle of a tool's whole output that fx saved separately, when the
/// text the model saw was clipped and does not name it. A clipped
/// `read_tool_result` page, for one, keeps its whole output only there.
fn savedOutputHandle(memory: ?types.ToolResultMemory, content: []const u8) []const u8 {
    const saved = memory orelse return "";
    const handle = saved.output_handle orelse return "";
    if (!saved.truncated or std.mem.find(u8, content, handle) != null) return "";
    return handle;
}

test "a clipped result keeps the handle of its saved whole output" {
    const handle = "result-read_tool_result-2.txt";
    const clipped_page: types.ToolResultMemory = .{ .output_handle = handle, .truncated = true };
    try std.testing.expectEqualStrings(handle, savedOutputHandle(clipped_page, "first page\n... [tool result truncated]"));
    // The model saw the whole text, or the text names the handle already.
    try std.testing.expectEqualStrings("", savedOutputHandle(.{ .output_handle = handle }, "whole text"));
    try std.testing.expectEqualStrings("", savedOutputHandle(clipped_page, "preview; full result: " ++ handle));
    try std.testing.expectEqualStrings("", savedOutputHandle(null, "no memory"));
}

test "an unreadable checkpoint numbers new turns, tool calls and ledgers after the saved ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var memory = records.MemoryStore{ .alloc = std.testing.allocator };
    defer memory.deinit();
    const store = memory.store();
    try records.save(arena, store, .{ .kind = .turn, .number = 3 }, "turn three");
    try records.save(arena, store, .{ .kind = .tool, .number = 7 }, "tool seven");
    try records.save(arena, store, .{ .kind = .tool, .number = 2 }, "tool two");
    try records.save(arena, store, .{ .kind = .ledger, .number = 2 }, "ledger two");
    try store.write(arena, "result-shell-1.txt", "not a record");

    const broken = "fx-compactor-v1\n{\"turns\": [";
    const earlier = (try earlierFrom(arena, store, broken)).?;
    try std.testing.expectEqualStrings(broken, earlier.earlier);
    try std.testing.expectEqual(@as(usize, 3), earlier.turn_count);
    try std.testing.expectEqual(@as(usize, 7), earlier.tool_count);
    try std.testing.expectEqual(@as(usize, 2), earlier.ledger_count);
    // Without a store nothing was saved, so numbering starts at one.
    try std.testing.expectEqual(@as(usize, 0), (try earlierFrom(arena, null, broken)).?.turn_count);

    // A count no session reaches is damage too, as is a record numbered past
    // it; numbering on from either would overflow.
    const impossible = std.fmt.comptimePrint("fx-compactor-v1\n{{\"tool_count\":{d}}}", .{std.math.maxInt(usize)});
    try store.write(arena, std.fmt.comptimePrint("compacted-T{d}.txt", .{std.math.maxInt(usize)}), "damaged");
    const recovered = (try earlierFrom(arena, store, impossible)).?;
    try std.testing.expectEqualStrings(impossible, recovered.earlier);
    try std.testing.expectEqual(@as(usize, 7), recovered.tool_count);
}

test {
    _ = window;
    _ = summarize;
    _ = ledger;
    _ = model;
    _ = checkpoint;
    _ = records;
    _ = settings;
    _ = trace;
}
