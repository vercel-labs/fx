//! The ACP side of the libfx journal. A journaled session sends each event
//! to the host as a `libfx/journal_append` notification, in `seq` order, and
//! opens from the events the host stored through `libfx/journal_open`.
//! The events themselves are `core/agent/runtime/journal.zig`'s.
const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const journal = @import("../core/agent/runtime/journal.zig");
const session_runtime = @import("../core/session/session.zig");
const session_codec = @import("../core/session/session_codec.zig");
const types = @import("../core/shared/types.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const session_adapter = @import("../core/session/session_adapter.zig");
const execution_memory = @import("../core/agent/execution_memory.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Event = journal.Event;
pub const max_load_bytes = journal.max_load_bytes;
/// What the model is told when libfx continues a turn a crash left open.
const resume_notice = "Resuming from unexpected session interruption.";

/// One session's journal. Its owner serializes every call with the
/// session's write mutex, so events reach the host in `seq` order.
pub const Journal = struct {
    /// The connection's writer, which outlives every session on it.
    writer: *jsonrpc.Writer,
    cursor: journal.Cursor = .{},
    /// Whether the last progress event still stands, as the fold sees it.
    progress_open: bool = false,
    /// The turn a crash left open, its running calls answered, until the
    /// host resumes it or starts another turn. Owned by the session's
    /// allocator.
    pending_resume: ?session_codec.RecoveryCheckpoint = null,
    /// Which step of the pending resume answers the calls the crash left
    /// running, when it left any. The resume runs its safe calls again.
    pending_resume_answered: ?usize = null,
    /// Set when a turn starts: its first progress carries the prompt, or the
    /// resolution of a resumed turn, and must be stored before the model
    /// sees it. Also set when the next progress places inputs.
    barrier_next_progress: bool = false,
    /// Inputs taken for the next model request; its progress places them.
    /// Owned by the session's allocator.
    placed_next: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Inputs the pending resume accepted and never placed, in order. Owned
    /// by the session's allocator.
    pending_inputs: []journal.PendingInput = &.{},
    /// Follow-ups the journal holds that no turn ran, until the host takes
    /// them. Owned by the session's allocator.
    pending_follow_ups: []journal.PendingInput = &.{},
    /// The follow-up the running turn runs, until a progress places it.
    /// Owned by the session's allocator.
    placing_follow_up: ?[]u8 = null,
    /// The progress whose barrier a cancel interrupted: the turn commits
    /// from it as interrupted. Owned by the session's allocator.
    cancelled_progress: ?session_codec.RecoveryCheckpoint = null,
    /// The host's config hash, and the last one the journal recorded. Owned
    /// by the session's allocator.
    host_config: ?[]u8 = null,
    recorded_config: ?[]u8 = null,

    pub fn deinit(self: *Journal, alloc: Allocator) void {
        self.dropPendingResume(alloc);
        self.clearPlaced(alloc);
        self.placed_next.deinit(alloc);
        if (self.placing_follow_up) |id| alloc.free(id);
        if (self.cancelled_progress) |*checkpoint| checkpoint.deinit(alloc);
        self.cancelled_progress = null;
        journal.freePendingInputs(alloc, self.takeFollowUps());
        if (self.host_config) |hash| alloc.free(hash);
        if (self.recorded_config) |hash| alloc.free(hash);
    }

    /// Records the host's config hash when a turn starts under one the
    /// journal has not recorded, so a later resume can tell.
    pub fn noteConfig(self: *Journal, alloc: Allocator, session_alloc: Allocator, session_id: []const u8) !void {
        const hash = self.host_config orelse return;
        if (self.recorded_config) |recorded| if (std.mem.eql(u8, recorded, hash)) return;
        const recorded = try session_alloc.dupe(u8, hash);
        errdefer session_alloc.free(recorded);
        try self.append(alloc, session_id, .{ .session_config = hash });
        if (self.recorded_config) |old| session_alloc.free(old);
        self.recorded_config = recorded;
    }

    /// Hands the follow-ups the journal held to the caller, who owns them.
    pub fn takeFollowUps(self: *Journal) []journal.PendingInput {
        const follow_ups = self.pending_follow_ups;
        self.pending_follow_ups = &.{};
        return follow_ups;
    }

    pub fn dropPendingResume(self: *Journal, alloc: Allocator) void {
        if (self.pending_resume) |*checkpoint| checkpoint.deinit(alloc);
        self.pending_resume = null;
        self.pending_resume_answered = null;
        if (self.pending_inputs.len > 0) {
            debug_trace.logf("session", "event=libfx_journal_inputs_dropped count={d} reason=resume_replaced", .{self.pending_inputs.len});
        }
        self.dropPendingInputs(alloc);
    }

    /// Hands the pending resume's inputs to the caller, who owns them.
    pub fn takePendingInputs(self: *Journal) []journal.PendingInput {
        const inputs = self.pending_inputs;
        self.pending_inputs = &.{};
        return inputs;
    }

    fn dropPendingInputs(self: *Journal, alloc: Allocator) void {
        journal.freePendingInputs(alloc, self.pending_inputs);
        self.pending_inputs = &.{};
    }

    /// Records inputs taken for the next model request. Its progress places
    /// them and is a barrier, so the request never carries an input the
    /// journal could lose.
    pub fn notePlaced(self: *Journal, alloc: Allocator, ids: []const []const u8) Allocator.Error!void {
        if (ids.len == 0) return;
        try self.placed_next.ensureUnusedCapacity(alloc, ids.len);
        for (ids) |id| self.placed_next.appendAssumeCapacity(try alloc.dupe(u8, id));
        self.barrier_next_progress = true;
    }

    fn clearPlaced(self: *Journal, alloc: Allocator) void {
        for (self.placed_next.items) |id| alloc.free(id);
        self.placed_next.clearRetainingCapacity();
    }

    /// Settles inputs taken for a model request that never went out because
    /// their turn ended first. The model never saw them: the journal dropped
    /// the steers with their turn, and the follow-up the turn ran is
    /// withdrawn, since that turn ran and ended. `session_alloc` owns the
    /// placed ids.
    pub fn endUnplaced(self: *Journal, alloc: Allocator, session_alloc: Allocator, session_id: []const u8) !void {
        if (self.placing_follow_up) |id| {
            try self.append(alloc, session_id, .{ .input_withdrawn = id });
            debug_trace.logf("session", "event=libfx_journal_follow_up_withdrawn reason=turn_ended_before_request", .{});
            session_alloc.free(id);
            self.placing_follow_up = null;
        }
        if (self.placed_next.items.len == 0) return;
        debug_trace.logf("session", "event=libfx_journal_inputs_dropped count={d} reason=turn_ended_before_request", .{self.placed_next.items.len});
        self.clearPlaced(session_alloc);
    }

    /// Hands the progress a cancelled barrier interrupted to the caller, who
    /// owns it.
    pub fn takeCancelledProgress(self: *Journal) ?session_codec.RecoveryCheckpoint {
        const checkpoint = self.cancelled_progress;
        self.cancelled_progress = null;
        return checkpoint;
    }

    /// Sends the open turn so far and the model its next request goes to,
    /// placing the inputs taken since the last progress. `session_alloc`
    /// owns the placed ids.
    pub fn appendProgress(
        self: *Journal,
        alloc: Allocator,
        session_alloc: Allocator,
        session_id: []const u8,
        checkpoint: session_codec.RecoveryCheckpoint,
        model: []const u8,
    ) !void {
        try self.append(alloc, session_id, .{ .turn_progress = .{
            .checkpoint = checkpoint,
            .placed = self.placed_next.items,
            .model = model,
        } });
        if (self.placing_follow_up) |id| {
            session_alloc.free(id);
            self.placing_follow_up = null;
        }
        self.clearPlaced(session_alloc);
    }

    /// Sends `event` as the session's next entry. On failure the cursor
    /// stays put, so the next event takes the same `seq`.
    pub fn append(self: *Journal, alloc: Allocator, session_id: []const u8, event: Event) !void {
        var params: std.Io.Writer.Allocating = .init(alloc);
        defer params.deinit();
        try params.writer.writeAll("{\"sessionId\":");
        try jsonrpc.writeJsonStr(session_id, &params.writer);
        try params.writer.writeAll(",\"events\":[");
        const next = try self.cursor.write(&params.writer, event);
        try params.writer.writeAll("]}");
        try self.writer.writeNotification(alloc, "libfx/journal_append", params.written());
        self.cursor = next;
        // Matches the fold: intents and compaction leave the open turn
        // standing.
        switch (event) {
            .turn_progress => self.progress_open = true,
            .turn_committed, .turn_progress_cleared => self.progress_open = false,
            .tool_intent, .history_replaced, .input_accepted, .input_withdrawn, .session_config => {},
        }
    }

    /// The follow-up a starting turn runs: its first progress places it.
    pub fn placeFollowUp(self: *Journal, alloc: Allocator, id: []const u8) Allocator.Error!void {
        const owned = try alloc.dupe(u8, id);
        errdefer alloc.free(owned);
        try self.notePlaced(alloc, &.{id});
        if (self.placing_follow_up) |old| alloc.free(old);
        self.placing_follow_up = owned;
    }

    /// Records that the open turn ended without a history entry. A turn
    /// with no progress on record needs no event.
    pub fn clearProgress(self: *Journal, alloc: Allocator, session_id: []const u8) !void {
        if (!self.progress_open) return;
        try self.append(alloc, session_id, .turn_progress_cleared);
    }
};

pub const Opened = struct {
    turns: usize,
    /// A crash left a turn open; `resume` continues it.
    resumable: bool,
    /// False when the open turn started under another config hash, so the
    /// host's instructions, tools or model differ from the ones it ran with.
    config_matches: bool = true,
};

fn dupePendingInputs(alloc: Allocator, inputs: []const journal.PendingInput) Allocator.Error![]journal.PendingInput {
    const owned = try alloc.alloc(journal.PendingInput, inputs.len);
    var filled: usize = 0;
    errdefer {
        for (owned[0..filled]) |input| {
            alloc.free(input.id);
            alloc.free(input.text);
        }
        alloc.free(owned);
    }
    for (inputs) |input| {
        const id = try alloc.dupe(u8, input.id);
        errdefer alloc.free(id);
        owned[filled] = .{ .id = id, .text = try alloc.dupe(u8, input.text) };
        filled += 1;
    }
    return owned;
}

/// Rebuilds a fresh session from the host's events and starts its journal
/// after them. A turn a crash left open becomes the pending resume, with
/// every call it left running answered as possibly run until the resume
/// runs the safe ones again (`rerunSafeCalls`); `session_alloc` owns it.
pub fn open(
    alloc: Allocator,
    session_alloc: Allocator,
    writer: *jsonrpc.Writer,
    runtime: *session_runtime.SessionRuntime,
    events_json: []const u8,
    config_hash: ?[]const u8,
) !struct { Journal, Opened } {
    if (!runtime.agent.fresh or runtime.agent.history.items.len != 0) return error.AgentNotFresh;
    var folded = try journal.fold(alloc, events_json);
    defer folded.deinit(alloc);
    if (folded.history.len > 0) try runtime.agent.restoreHistory(alloc, folded.history);
    var state: Journal = .{
        .writer = writer,
        .cursor = folded.cursor,
        .progress_open = folded.open_turn != null,
        .pending_follow_ups = try dupePendingInputs(session_alloc, folded.pending_follow_ups),
    };
    errdefer state.deinit(session_alloc);
    if (config_hash) |hash| state.host_config = try session_alloc.dupe(u8, hash);
    if (folded.config_hash) |hash| state.recorded_config = try session_alloc.dupe(u8, hash);
    const checkpoint = folded.open_turn orelse
        return .{ state, .{ .turns = folded.history.len, .resumable = false } };
    // Committed turns continue under any config; only an open turn
    // recorded under another one is refused.
    const config_matches = if (folded.open_turn_config) |recorded|
        if (config_hash) |hash| std.mem.eql(u8, recorded, hash) else true
    else
        true;

    debug_trace.logf("session", "event=libfx_journal_open_turn turn={d} running_calls={d} resolved=pending_resume", .{ folded.cursor.turn, folded.running_calls.len });
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var answered = checkpoint;
    const answered_step = answered.execution.tool_steps.len;
    try answerRunning(scratch.allocator(), &answered, folded.running_calls);
    state.pending_resume = try answered.dupe(session_alloc);
    if (folded.running_calls.len > 0) state.pending_resume_answered = answered_step;
    state.pending_inputs = try dupePendingInputs(session_alloc, folded.pending_inputs);
    return .{ state, .{ .turns = folded.history.len, .resumable = true, .config_matches = config_matches } };
}

/// An owned copy of `pending` ready to continue: the model is told the
/// session was interrupted, then sees the inputs the turn accepted and never
/// placed, and the attempt budget starts over, so repeated crashes never turn
/// into a refusal to resume.
pub fn resumeCheckpoint(
    alloc: Allocator,
    pending: session_codec.RecoveryCheckpoint,
    inputs: []const journal.PendingInput,
) !session_codec.RecoveryCheckpoint {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var view = pending;
    const old = view.execution.steering;
    const steering = try scratch.allocator().alloc(types.PersistedSteering, old.len + 1 + inputs.len);
    @memcpy(steering[0..old.len], old);
    const after = view.execution.tool_steps.len;
    steering[old.len] = .{ .text = @constCast(resume_notice), .after_tool_step_count = after };
    for (inputs, steering[old.len + 1 ..]) |input, *entry| {
        entry.* = .{ .text = input.text, .after_tool_step_count = after };
    }
    view.execution.steering = steering;
    view.consumed_provider_attempts = 0;
    view.outstanding_reservation = false;
    return view.dupe(alloc);
}

/// Gives each call the crash left running a result saying it may have
/// partly run, as one more step of the open turn, so the model sees every
/// call it made answered and never has a `replay: "never"` call run again
/// on its own. A resume replaces the answers of safe calls with what they
/// return when they run again. The response that made the calls, with any
/// text the model wrote before them, is now that step, so the turn
/// continues after its tools. Borrows `calls` and the turn's text;
/// allocates in `scratch`.
fn answerRunning(scratch: Allocator, turn: *session_codec.RecoveryCheckpoint, calls: []types.ToolCall) Allocator.Error!void {
    if (calls.len == 0) return;
    const output = session_adapter.unfinished_tool_output;
    const results = try scratch.alloc(types.PersistedToolResult, calls.len);
    for (calls, results) |call, *result| result.* = .{
        .tool_call_id = @constCast(call.id),
        .tool_name = @constCast(call.name),
        .status = .failure,
        .output = @constCast(output),
        .output_bytes = output.len,
        .stored_output_bytes = output.len,
    };
    const old = turn.execution.tool_steps;
    const steps = try scratch.alloc(types.ToolExecutionStep, old.len + 1);
    @memcpy(steps[0..old.len], old);
    steps[old.len] = .{
        .assistant = if (turn.assistant_source.len > 0) turn.assistant_source else null,
        .tool_calls = calls,
        .tool_results = results,
    };
    turn.execution.tool_steps = steps;
    turn.assistant_source = @constCast("");
    turn.tool_state = .confirmed;
}

/// Runs again each call of `checkpoint`'s step `step_index`, the step that
/// answers the calls a crash left running, whose tool `runner.safe` says is
/// `replay: "safe"` for this agent, under the id the model gave it, and puts
/// what `runner.run` returns in place of the answer that it may have partly
/// run. A `replay: "never"` call, or one whose tool the agent no longer has,
/// keeps that answer. Stops at the first call `runner.run` returns null for
/// (the turn is being cancelled or handed off), so that call and every later
/// one keep it too. `alloc` owns `checkpoint` and the results put in it.
/// Returns how many calls ran again.
pub fn rerunSafeCalls(
    alloc: Allocator,
    checkpoint: *session_codec.RecoveryCheckpoint,
    step_index: usize,
    runner: anytype,
) !usize {
    const steps = checkpoint.execution.tool_steps;
    if (step_index >= steps.len) return 0;
    const step = &steps[step_index];
    var reran: usize = 0;
    for (step.tool_calls, step.tool_results) |call, *result| {
        if (!runner.safe(call)) continue;
        const outcome = (try runner.run(alloc, call)) orelse {
            debug_trace.logf("session", "event=libfx_resume_rerun_stopped call={s} reran={d} kept=may_have_partly_run", .{ call.id, reran });
            break;
        };
        defer outcome.deinit(alloc);
        const replacement = try persistedResult(alloc, call, outcome);
        types.freePersistedToolResult(alloc, result.*);
        result.* = replacement;
        reran += 1;
        debug_trace.logf("session", "event=libfx_resume_rerun call={s} tool={s} status={s}", .{ call.id, call.name, @tagName(replacement.status) });
    }
    return reran;
}

fn persistedResult(alloc: Allocator, call: types.ToolCall, outcome: tool_dispatch.ToolResult) !types.PersistedToolResult {
    return switch (outcome) {
        .success => |text| execution_memory.makePersistedToolResult(alloc, call.id, call.name, .success, text, null),
        .failure => |text| execution_memory.makePersistedToolResult(alloc, call.id, call.name, .failure, text, null),
        .rich => |content| execution_memory.makePersistedToolResult(
            alloc,
            call.id,
            call.name,
            if (content.is_error) .failure else .success,
            content.text,
            .{ .tool_images = content.images, .output_bytes = content.text.len, .stored_output_bytes = content.text.len },
        ),
    };
}

const TestCapture = struct {
    frames: std.ArrayList(u8) = .empty,

    fn write(raw: ?*anyopaque, frame: []const u8) !void {
        const self: *TestCapture = @ptrCast(@alignCast(raw.?));
        try self.frames.appendSlice(std.testing.allocator, frame);
    }
};

fn testProgress(alloc: Allocator) !session_codec.RecoveryCheckpoint {
    return .{
        .turn_id = 1,
        .user = .{ .text = try alloc.dupe(u8, "prompt") },
        .assistant_source = try alloc.dupe(u8, ""),
        .cause = .network_interrupted,
        .action = .retrying_request,
        .authority = .{ .provider = .gateway, .model = try alloc.dupe(u8, "fake/model") },
        .requested_fast_mode = false,
        .fast_mode = false,
        .max_provider_attempts = 3,
        .consumed_provider_attempts = 0,
    };
}

test "inputs taken for a request that never went out are not placed by the next turn" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    try session.notePlaced(alloc, &.{"steer-1"});
    // Its turn ended before the next progress; the next turn starts.
    try session.endUnplaced(alloc, alloc, "session");
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "steer-1") == null);
}

test "a progress places the follow-up its turn runs" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer, .cursor = .{ .next_seq = 3, .turn = 2 } };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    try session.placeFollowUp(alloc, "follow-1");
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"inputs\":[\"follow-1\"]") != null);
    // Nothing is left to settle when the turn ends.
    try session.endUnplaced(alloc, alloc, "session");
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "input_withdrawn") == null);
}

test "a follow-up whose turn ended before its request is withdrawn, so it never runs again" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer, .cursor = .{ .next_seq = 3, .turn = 2 } };
    defer session.deinit(alloc);

    try session.placeFollowUp(alloc, "follow-1");
    try session.endUnplaced(alloc, alloc, "session");
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"type\":\"input_withdrawn\",\"data\":{\"id\":\"follow-1\"}") != null);
}

/// Runs `read` calls again, except `stop_at`, which it reports as cancelled.
const TestRerunner = struct {
    stop_at: ?[]const u8 = null,
    ran: *std.ArrayList([]const u8),

    pub fn safe(_: TestRerunner, call: types.ToolCall) bool {
        return std.mem.eql(u8, call.name, "read");
    }

    pub fn run(self: TestRerunner, alloc: Allocator, call: types.ToolCall) !?tool_dispatch.ToolResult {
        if (self.stop_at) |id| if (std.mem.eql(u8, call.id, id)) return null;
        try self.ran.append(std.testing.allocator, call.id);
        return .{ .success = try std.fmt.allocPrint(alloc, "read again by {s}", .{call.id}) };
    }
};

fn testAnswered(alloc: Allocator, calls: []types.ToolCall) !session_codec.RecoveryCheckpoint {
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var answered = progress;
    try answerRunning(scratch.allocator(), &answered, calls);
    return answered.dupe(alloc);
}

test "a resumed turn runs its safe calls again and keeps a never call answered" {
    const alloc = std.testing.allocator;
    var calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "read", .arguments_json = "{}" },
        .{ .id = "call-2", .name = "send", .arguments_json = "{}" },
        .{ .id = "call-3", .name = "read", .arguments_json = "{}" },
    };
    var answered = try testAnswered(alloc, &calls);
    defer answered.deinit(alloc);
    var ran: std.ArrayList([]const u8) = .empty;
    defer ran.deinit(alloc);

    const reran = try rerunSafeCalls(alloc, &answered, 0, TestRerunner{ .ran = &ran });
    try std.testing.expectEqual(@as(usize, 2), reran);
    try std.testing.expectEqual(@as(usize, 2), ran.items.len);
    const results = answered.execution.tool_steps[0].tool_results;
    // Every call keeps its place, so results reach the model in its order.
    try std.testing.expectEqualStrings("call-1", results[0].tool_call_id);
    try std.testing.expectEqualStrings("read again by call-1", results[0].output);
    try std.testing.expectEqual(types.PersistedToolStatus.success, results[0].status);
    try std.testing.expectEqualStrings(session_adapter.unfinished_tool_output, results[1].output);
    try std.testing.expectEqual(types.PersistedToolStatus.failure, results[1].status);
    try std.testing.expectEqualStrings("read again by call-3", results[2].output);
}

test "a resume cancelled during a rerun keeps that call and the later ones answered" {
    const alloc = std.testing.allocator;
    var calls = [_]types.ToolCall{
        .{ .id = "call-1", .name = "read", .arguments_json = "{}" },
        .{ .id = "call-2", .name = "read", .arguments_json = "{}" },
        .{ .id = "call-3", .name = "read", .arguments_json = "{}" },
    };
    var answered = try testAnswered(alloc, &calls);
    defer answered.deinit(alloc);
    var ran: std.ArrayList([]const u8) = .empty;
    defer ran.deinit(alloc);

    const reran = try rerunSafeCalls(alloc, &answered, 0, TestRerunner{ .stop_at = "call-2", .ran = &ran });
    try std.testing.expectEqual(@as(usize, 1), reran);
    const results = answered.execution.tool_steps[0].tool_results;
    try std.testing.expectEqualStrings("read again by call-1", results[0].output);
    try std.testing.expectEqualStrings(session_adapter.unfinished_tool_output, results[1].output);
    try std.testing.expectEqualStrings(session_adapter.unfinished_tool_output, results[2].output);
    // A step index past the turn's steps runs nothing.
    try std.testing.expectEqual(@as(usize, 0), try rerunSafeCalls(alloc, &answered, 5, TestRerunner{ .ran = &ran }));
}
