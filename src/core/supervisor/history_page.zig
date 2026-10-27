//! Pages of a session's saved history, read backwards from the newest turn.
//!
//! A viewer holds the saved turns from a cursor to the end of the history.
//! Each page carries the turn fragments immediately older than that cursor,
//! so a long conversation, or a single very long turn, loads in bounded
//! pieces. A fragment is one turn narrowed to a contiguous run of its tool
//! steps; flags say whether it also owns the turn's prompt and its final
//! reply. The functions here are pure: they read the saved turns and
//! allocate only from the caller's arena.
const std = @import("std");
const types = @import("../shared/types.zig");
const text_utils = @import("../shared/text_utils.zig");
const protocol = @import("protocol.zig");

const Allocator = std.mem.Allocator;

/// The page size a request gets when it names none.
pub const default_page_bytes: usize = 512 * 1024;
/// The most one page may ask for. Encoding escapes text, so the session
/// still shrinks a page whose encoded reply would exceed one frame.
pub const max_page_bytes: usize = 4 * 1024 * 1024;
/// The first page a resume asks for. The client prints it into the
/// terminal's own scrollback, which the app cannot page, so it is as large
/// as one page may be. Saved bytes are mostly tool output a collapsed row
/// shows little of; a few hundred turns replay in well under a second.
pub const resume_page_bytes: usize = max_page_bytes;
/// The smallest budget a shrinking reply retries with.
const min_page_bytes: usize = 16 * 1024;

/// Where the saved history a viewer holds begins: step `step` of turn
/// `turn`. At step 0 the viewer holds that whole turn, prompt included, and
/// the next older page ends with the turn before it.
pub const Cursor = struct {
    turn: usize = 0,
    step: usize = 0,
};

/// One turn's share of a page. `turn` keeps only the tool steps this
/// fragment owns, starting at `first_step` of the saved turn, and the
/// steering given between them. `has_user` and `has_tail` say whether the
/// fragment also shows the turn's prompt and its closing reply, summary, and
/// outcome; the turn's other fragments show them instead.
pub const Fragment = struct {
    turn: types.HistoryTurn,
    first_step: usize = 0,
    has_user: bool = true,
    has_tail: bool = true,

    /// A whole saved turn as one fragment.
    pub fn whole(turn: types.HistoryTurn) Fragment {
        return .{ .turn = turn };
    }
};

pub const Page = struct {
    /// Oldest first.
    fragments: []Fragment = &.{},
    /// The cursor after this page: where the viewer's history now begins.
    start: Cursor = .{},
    /// The estimated bytes of the fragments, used to size the viewer's
    /// retained transcript.
    bytes: usize = 0,
    has_older: bool = false,
};

/// The fragments immediately older than `before`, or the newest ones when
/// `before` is null, within about `max_bytes`. A page always makes progress:
/// a single tool step larger than the budget travels with its large fields
/// cut. Fragments borrow `turns` except for what they cut.
pub fn build(arena: Allocator, turns: []const types.HistoryTurn, before: ?Cursor, max_bytes: usize) !Page {
    const budget = std.math.clamp(max_bytes, 1, max_page_bytes);
    var cursor = clampCursor(turns, before orelse .{ .turn = turns.len });
    var used: usize = 0;
    var newest_first: std.ArrayList(Fragment) = .empty;
    while (cursor.turn > 0 or cursor.step > 0) {
        const index = if (cursor.step > 0) cursor.turn else cursor.turn - 1;
        const turn = turns[index];
        if (turn == .compacted_summary) {
            // A compaction summary shows no transcript rows.
            cursor = .{ .turn = index };
            continue;
        }
        const steps = turnSteps(turn);
        const has_tail = cursor.step == 0;
        const end = if (has_tail) steps.len else cursor.step;
        const fixed = (if (has_tail) tailBytes(turn) else 0) +| steeringBytes(turnSteering(turn));
        if (newest_first.items.len > 0 and used +| fixed > budget) break;
        var spent = used +| fixed;
        var first = end;
        while (first > 0) {
            const cost = stepBytes(steps[first - 1]);
            if (spent +| cost > budget) break;
            spent += cost;
            first -= 1;
        }
        const forced = first == end and end > 0;
        if (forced) {
            // Nothing fit. An earlier fragment ends the page; otherwise the
            // newest step travels alone, cut to the budget.
            if (newest_first.items.len > 0) break;
            first = end - 1;
        }
        const has_user = first == 0;
        if (has_user) spent +|= userBytes(turnUser(turn));
        var fragment = try narrow(arena, turn, first, end, has_user, has_tail, budget);
        if (forced) {
            const step = try boundStep(arena, steps[first], budget -| spent);
            const owned = try arena.dupe(types.ToolExecutionStep, turnSteps(fragment.turn));
            owned[0] = step;
            setTurnSteps(&fragment.turn, owned);
            spent +|= stepBytes(step);
        }
        try newest_first.append(arena, fragment);
        used = spent;
        cursor = .{ .turn = index, .step = first };
        if (first > 0 or used >= budget) break;
    }
    std.mem.reverse(Fragment, newest_first.items);
    return .{
        .fragments = newest_first.items,
        .start = cursor,
        .bytes = used,
        .has_older = cursor.turn > 0 or cursor.step > 0,
    };
}

/// The whole turns from `after_turn` to the end, which a viewer that paged
/// back appends after the window it already holds. Incomplete when they do
/// not fit `max_bytes`; the viewer then reloads the newest page instead.
pub const Newer = struct { fragments: []Fragment = &.{}, bytes: usize = 0, complete: bool = true };

pub fn newer(arena: Allocator, turns: []const types.HistoryTurn, after_turn: usize, max_bytes: usize) !Newer {
    if (after_turn > turns.len) return .{ .fragments = &.{}, .bytes = 0, .complete = false };
    const fragments = try arena.alloc(Fragment, turns.len - after_turn);
    var used: usize = 0;
    for (turns[after_turn..], fragments) |turn, *out| {
        used +|= wholeTurnBytes(turn);
        if (used > max_bytes) return .{ .fragments = &.{}, .bytes = 0, .complete = false };
        out.* = .whole(turn);
    }
    return .{ .fragments = fragments, .bytes = used, .complete = true };
}

/// The saved turns a session serves pages from, and the generation that
/// tells a viewer whether its cursor still points into the same history.
pub const Saved = struct {
    turns: []types.HistoryTurn = &.{},
    fingerprints: []u64 = &.{},
    generation: u64 = 1,
    /// The event sequence the turns were checkpointed at.
    sequence: u64 = 0,

    pub fn deinit(self: *Saved, alloc: Allocator) void {
        if (self.turns.len > 0) types.freeHistoryTurnSlice(alloc, self.turns);
        alloc.free(self.fingerprints);
        self.* = .{};
    }

    /// Takes ownership of `turns` on success. A history that does not extend
    /// the one it replaces, as after a compaction or a rewind, starts a new
    /// generation.
    pub fn replace(self: *Saved, alloc: Allocator, turns: []types.HistoryTurn, sequence: u64) !void {
        const fingerprints = try alloc.alloc(u64, turns.len);
        for (turns, fingerprints) |turn, *out| out.* = fingerprint(turn);
        const extends = fingerprints.len >= self.fingerprints.len and
            std.mem.eql(u64, self.fingerprints, fingerprints[0..self.fingerprints.len]);
        const generation = if (extends) self.generation else self.generation + 1;
        self.deinit(alloc);
        self.* = .{ .turns = turns, .fingerprints = fingerprints, .generation = generation, .sequence = sequence };
    }
};

/// Encodes the answer to `request` from `saved`, halving the page until the
/// encoded reply fits in `max_frame_bytes`.
pub fn encodeReply(
    arena: Allocator,
    saved: *const Saved,
    session_id: []const u8,
    request: protocol.HistoryPageRequest,
    max_frame_bytes: usize,
) ![]const u8 {
    var budget = std.math.clamp(request.max_bytes, min_page_bytes, max_page_bytes);
    while (true) {
        const page = try build(arena, saved.turns, request.before, budget);
        const later: Newer = if (request.after_turn) |after| try newer(arena, saved.turns, after, budget *| 2) else .{};
        const bytes = try protocol.encode(arena, protocol.HistoryPage([]const Fragment){
            .session_id = session_id,
            .generation = saved.generation,
            .history_sequence = saved.sequence,
            .turn_count = saved.turns.len,
            .start = page.start,
            .has_older = page.has_older,
            .page_bytes = page.bytes,
            .fragments = page.fragments,
            .newer = later.fragments,
            .newer_bytes = later.bytes,
            .newer_complete = later.complete,
        });
        if (bytes.len <= max_frame_bytes) return bytes;
        if (budget <= min_page_bytes) return error.HistoryPageTooLarge;
        budget /= 2;
    }
}

fn clampCursor(turns: []const types.HistoryTurn, cursor: Cursor) Cursor {
    if (cursor.turn >= turns.len) return .{ .turn = turns.len };
    if (cursor.step >= turnSteps(turns[cursor.turn]).len) return .{ .turn = cursor.turn };
    return cursor;
}

/// `turn` narrowed to steps `first..end`. The fragment owns the steering
/// given before each of its steps, and the steering after the last step when
/// it also owns the tail; boundaries shift to the fragment's own steps.
fn narrow(
    arena: Allocator,
    turn: types.HistoryTurn,
    first: usize,
    end: usize,
    has_user: bool,
    has_tail: bool,
    max_field_bytes: usize,
) !Fragment {
    var copy = turn;
    switch (copy) {
        .compacted_summary => unreachable,
        inline .assistant, .interrupted => |*entry| {
            entry.user = if (has_user) .{
                .text = try bound(arena, entry.user.text, max_field_bytes),
                .images = entry.user.images,
                .work_id = entry.user.work_id,
            } else .{ .text = &.{} };
            entry.execution.tool_steps = entry.execution.tool_steps[first..end];
            entry.execution.files = &.{};
            entry.execution.steering = try ownedSteering(arena, entry.execution.steering, first, end, has_tail);
            if (@TypeOf(entry.*) == types.AssistantHistoryTurn) {
                entry.provider_replay = null;
                entry.assistant = if (has_tail) try bound(arena, entry.assistant, max_field_bytes) else &.{};
            } else {
                entry.completed_tool_names = &.{};
                if (entry.assistant) |assistant| entry.assistant = if (has_tail) try bound(arena, assistant, max_field_bytes) else null;
                if (!has_tail) {
                    entry.tool_call = null;
                    entry.cancelled_command = null;
                }
            }
        },
    }
    return .{ .turn = copy, .first_step = first, .has_user = has_user, .has_tail = has_tail };
}

fn ownedSteering(
    arena: Allocator,
    steering: []const types.PersistedSteering,
    first: usize,
    end: usize,
    has_tail: bool,
) ![]types.PersistedSteering {
    var kept: std.ArrayList(types.PersistedSteering) = .empty;
    for (steering) |item| {
        const boundary = item.after_tool_step_count;
        const owned = boundary >= first and (boundary < end or has_tail);
        if (!owned) continue;
        var copy = item;
        copy.after_tool_step_count = boundary - first;
        try kept.append(arena, copy);
    }
    return kept.items;
}

/// `step` with each large field cut to a share of `budget` on UTF-8
/// boundaries. Images and file contents drop out; the saved result keeps
/// them, and its output handle still reads the whole output.
fn boundStep(arena: Allocator, step: types.ToolExecutionStep, budget: usize) !types.ToolExecutionStep {
    const fields = 1 + step.tool_calls.len + 2 * step.tool_results.len;
    const cap = @max(budget / fields, 256);
    var copy = step;
    copy.provider_replay = null;
    if (step.assistant) |assistant| copy.assistant = try bound(arena, assistant, cap);
    copy.tool_calls = try arena.dupe(types.ToolCall, step.tool_calls);
    for (copy.tool_calls) |*call| {
        if (call.arguments_json.len > cap) call.arguments_json = try cut(arena, call.arguments_json, cap);
        call.provider_result = null;
    }
    copy.tool_results = try arena.dupe(types.PersistedToolResult, step.tool_results);
    for (copy.tool_results) |*result| {
        if (result.output.len > cap) result.truncated = true;
        result.output = try bound(arena, result.output, cap);
        if (result.preview) |preview| result.preview = try bound(arena, preview, cap);
        result.tool_images = &.{};
        result.committed_file_presentation = null;
    }
    return copy;
}

/// `text`, or its head and tail around an omission marker when it is longer
/// than `max_bytes`. Never splits a UTF-8 sequence.
fn bound(arena: Allocator, text: []u8, max_bytes: usize) ![]u8 {
    return if (text.len <= max_bytes) text else cut(arena, text, max_bytes);
}

fn cut(arena: Allocator, text: []const u8, max_bytes: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const marker = "\n[... omitted from this history page ...]\n";
    try text_utils.writeHeadTailBounded(&out.writer, text, max_bytes, marker, .up);
    return out.toOwnedSlice();
}

fn turnSteps(turn: types.HistoryTurn) []types.ToolExecutionStep {
    return switch (turn) {
        .compacted_summary => &.{},
        inline .assistant, .interrupted => |entry| entry.execution.tool_steps,
    };
}

fn setTurnSteps(turn: *types.HistoryTurn, steps: []types.ToolExecutionStep) void {
    switch (turn.*) {
        .compacted_summary => {},
        inline .assistant, .interrupted => |*entry| entry.execution.tool_steps = steps,
    }
}

fn turnSteering(turn: types.HistoryTurn) []const types.PersistedSteering {
    return switch (turn) {
        .compacted_summary => &.{},
        inline .assistant, .interrupted => |entry| entry.execution.steering,
    };
}

fn turnUser(turn: types.HistoryTurn) types.UserTurn {
    return switch (turn) {
        .compacted_summary => .{ .text = &.{} },
        inline .assistant, .interrupted => |entry| entry.user,
    };
}

fn stepBytes(step: types.ToolExecutionStep) usize {
    var total: usize = 128;
    if (step.assistant) |assistant| total +|= assistant.len;
    for (step.tool_calls) |call| {
        total +|= 64 +| call.name.len +| call.arguments_json.len;
        if (call.provider_result) |result| total +|= result.len;
    }
    for (step.tool_results) |result| {
        total +|= 96 +| result.tool_name.len +| result.output.len;
        if (result.preview) |preview| total +|= preview.len;
        if (result.output_handle) |handle| total +|= handle.len;
        for (result.permission_feedback) |feedback| total +|= feedback.len;
        for (result.tool_images) |image| total +|= image.data.len +| image.mime_type.len;
        if (result.committed_file_presentation) |file| {
            total +|= file.path.len;
            for (file.lines) |line| total +|= 32 +| line.text.len;
            if (file.previous_content) |content| total +|= content.len;
            if (file.after_content) |content| total +|= content.len;
        }
    }
    if (step.provider_replay) |replay| total +|= replay.parts_json.len;
    return total;
}

fn userBytes(user: types.UserTurn) usize {
    var total = user.text.len +| 16;
    for (user.images) |image| total +|= image.path.len +| image.media_type.len;
    if (user.work_id) |work| total +|= work.len;
    return total;
}

fn tailBytes(turn: types.HistoryTurn) usize {
    return switch (turn) {
        .compacted_summary => 0,
        .assistant => |entry| entry.assistant.len +| 64,
        .interrupted => |entry| blk: {
            var total: usize = 64;
            if (entry.assistant) |assistant| total +|= assistant.len;
            if (entry.cancelled_command != null) total +|= 128;
            break :blk total;
        },
    };
}

fn steeringBytes(steering: []const types.PersistedSteering) usize {
    var total: usize = 0;
    for (steering) |item| {
        total +|= item.text.len +| 32;
        if (item.assistant_prefix) |prefix| total +|= prefix.len;
    }
    return total;
}

fn wholeTurnBytes(turn: types.HistoryTurn) usize {
    var total = tailBytes(turn) +| steeringBytes(turnSteering(turn)) +| userBytes(turnUser(turn));
    for (turnSteps(turn)) |step| total +|= stepBytes(step);
    return total;
}

fn fingerprint(turn: types.HistoryTurn) u64 {
    const counts = [2]usize{ turnSteps(turn).len, turnSteering(turn).len };
    var hasher = std.hash.Wyhash.init(@backingInt(std.meta.activeTag(turn)));
    hasher.update(turnUser(turn).text);
    hasher.update(std.mem.sliceAsBytes(&counts));
    return hasher.final();
}

// -- tests -----------------------------------------------------------------

fn testTurn(steps: []types.ToolExecutionStep, steering: []types.PersistedSteering) types.HistoryTurn {
    return .{ .assistant = .{
        .user = .{ .text = @constCast("question") },
        .assistant = @constCast("answer"),
        .execution = .{ .tool_steps = steps, .steering = steering, .turn_summary = .{} },
    } };
}

test "a fragment owns its prompt and reply only through its flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var steps = [_]types.ToolExecutionStep{ .{}, .{} };
    var steering = [_]types.PersistedSteering{.{ .text = @constCast("steer"), .after_tool_step_count = 1 }};
    const turn = testTurn(&steps, &steering);

    const middle = try narrow(arena, turn, 1, 2, false, false, max_page_bytes);
    try std.testing.expect(!middle.has_user and !middle.has_tail);
    try std.testing.expectEqual(@as(usize, 1), middle.first_step);
    try std.testing.expectEqual(@as(usize, 1), middle.turn.assistant.execution.tool_steps.len);
    // The newer fragment owns the steering given at its first step.
    try std.testing.expectEqual(@as(usize, 1), middle.turn.assistant.execution.steering.len);
    try std.testing.expectEqual(@as(usize, 0), middle.turn.assistant.execution.steering[0].after_tool_step_count);

    const older = try narrow(arena, turn, 0, 1, true, false, max_page_bytes);
    try std.testing.expectEqualStrings("question", older.turn.assistant.user.text);
    try std.testing.expectEqual(@as(usize, 0), older.turn.assistant.execution.steering.len);

    const whole_turn = try narrow(arena, turn, 0, 2, true, true, max_page_bytes);
    try std.testing.expectEqualStrings("answer", whole_turn.turn.assistant.assistant);
    try std.testing.expectEqual(@as(usize, 1), whole_turn.turn.assistant.execution.steering.len);
    try std.testing.expectEqual(@as(usize, 1), whole_turn.turn.assistant.execution.steering[0].after_tool_step_count);
}

test "pages split a long turn at a steering boundary and show the steering once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const output = try arena.alloc(u8, 4000);
    @memset(output, 'x');
    var results: [4][1]types.PersistedToolResult = undefined;
    var steps: [4]types.ToolExecutionStep = undefined;
    for (&results, &steps) |*result, *step| {
        result[0] = .{
            .tool_call_id = @constCast("c"),
            .tool_name = @constCast("shell"),
            .status = .success,
            .output = output,
            .output_bytes = output.len,
            .stored_output_bytes = output.len,
        };
        step.* = .{ .tool_results = result };
    }
    var steering = [_]types.PersistedSteering{
        .{ .text = @constCast("at two"), .after_tool_step_count = 2 },
        .{ .text = @constCast("after all"), .after_tool_step_count = 4 },
    };
    const turns = [_]types.HistoryTurn{testTurn(&steps, &steering)};

    // Two steps fit each page, so the split falls on the boundary at step 2.
    const budget = 2 * stepBytes(steps[0]) + tailBytes(turns[0]) + steeringBytes(&steering) + userBytes(turnUser(turns[0]));
    const newest = try build(arena, &turns, null, budget);
    try std.testing.expectEqual(@as(usize, 1), newest.fragments.len);
    try std.testing.expectEqual(Cursor{ .turn = 0, .step = 2 }, newest.start);
    try std.testing.expect(newest.has_older);
    const tail = newest.fragments[0];
    try std.testing.expect(tail.has_tail and !tail.has_user);

    const oldest = try build(arena, &turns, newest.start, budget);
    try std.testing.expectEqual(Cursor{ .turn = 0, .step = 0 }, oldest.start);
    try std.testing.expect(!oldest.has_older);
    const head = oldest.fragments[0];
    try std.testing.expect(head.has_user and !head.has_tail);

    var seen: usize = 0;
    for ([_]Fragment{ head, tail }) |fragment| {
        for (fragment.turn.assistant.execution.steering) |item| {
            if (std.mem.eql(u8, item.text, "at two")) seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
    try std.testing.expectEqual(@as(usize, 0), tail.turn.assistant.execution.steering[0].after_tool_step_count);
    try std.testing.expectEqual(@as(usize, 2), tail.turn.assistant.execution.steering[1].after_tool_step_count);
}

test "an oversized step is cut on character boundaries and the reply fits a frame" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Three-byte characters, so a byte cut would land inside one.
    const unit = "\u{4e16}";
    const output = try arena.alloc(u8, unit.len * 400_000);
    for (0..400_000) |i| @memcpy(output[i * unit.len ..][0..unit.len], unit);
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("c"),
        .tool_name = @constCast("shell"),
        .status = .success,
        .output = output,
        .output_bytes = output.len,
        .stored_output_bytes = output.len,
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_results = &results }};
    const turns = [_]types.HistoryTurn{testTurn(&steps, &.{})};

    const page = try build(arena, &turns, null, 64 * 1024);
    const shown = page.fragments[0].turn.assistant.execution.tool_steps[0].tool_results[0];
    try std.testing.expect(shown.truncated);
    try std.testing.expect(shown.output.len < 64 * 1024);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shown.output));

    var saved: Saved = .{ .turns = @constCast(&turns) };
    const bytes = try encodeReply(arena, &saved, "s", .{ .session_id = "s", .max_bytes = max_page_bytes }, 256 * 1024);
    try std.testing.expect(bytes.len <= 256 * 1024);
}

test "a rewritten history starts a new generation" {
    const alloc = std.testing.allocator;
    var saved: Saved = .{};
    defer saved.deinit(alloc);
    const one = try alloc.alloc(types.HistoryTurn, 1);
    one[0] = try types.dupeHistoryTurn(alloc, testTurn(&.{}, &.{}));
    try saved.replace(alloc, one, 3);
    const generation = saved.generation;

    const two = try alloc.alloc(types.HistoryTurn, 2);
    two[0] = try types.dupeHistoryTurn(alloc, testTurn(&.{}, &.{}));
    two[1] = try types.dupeHistoryTurn(alloc, testTurn(&.{}, &.{}));
    try saved.replace(alloc, two, 5);
    try std.testing.expectEqual(generation, saved.generation);

    const rewound = try alloc.alloc(types.HistoryTurn, 1);
    rewound[0] = try types.dupeHistoryTurn(alloc, testTurn(&.{}, &.{}));
    try saved.replace(alloc, rewound, 7);
    try std.testing.expect(saved.generation != generation);
}
