//! The ACP side of the libfx journal. A journaled session sends each event
//! to the host as a `libfx/journal_append` notification, in `seq` order, and
//! opens from the events the host stored through `libfx/journal_open`.
//! The events themselves are `core/agent/runtime/journal.zig`'s.
const std = @import("std");
const observation = @import("../core/agent/runtime/observation.zig");
const jsonrpc = @import("jsonrpc.zig");
const journal = @import("../core/agent/runtime/journal.zig");
const session_runtime = @import("../core/session/session.zig");
const session_codec = @import("../core/session/session_codec.zig");
const types = @import("../core/shared/types.zig");
const debug_trace = @import("../core/shared/debug_trace.zig");
const session_adapter = @import("../core/session/session_adapter.zig");
const checkpoint_codec = @import("../core/agent/runtime/checkpoint.zig");
const execution_memory = @import("../core/agent/execution_memory.zig");
const tool_dispatch = @import("../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;

pub const Event = journal.Event;
pub const max_load_bytes = journal.max_load_bytes;

/// A host's id for a turn, kept in place so copying a journal copies it.
pub const TurnId = struct {
    bytes: [journal.max_turn_id_bytes]u8 = undefined,
    len: u8 = 0,

    /// `id` is at most `journal.max_turn_id_bytes` long.
    pub fn of(id: ?[]const u8) TurnId {
        const value = id orelse return .{};
        std.debug.assert(value.len <= journal.max_turn_id_bytes);
        var turn_id: TurnId = .{ .len = @intCast(value.len) };
        @memcpy(turn_id.bytes[0..value.len], value);
        return turn_id;
    }

    pub fn slice(self: *const TurnId) ?[]const u8 {
        return if (self.len == 0) null else self.bytes[0..self.len];
    }
};

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
    /// running, when it left any. The host may have the resume run them again.
    pending_resume_answered: ?usize = null,
    /// Set when a turn starts: its first progress carries the prompt, or the
    /// resolution of a resumed turn, and must be stored before the model
    /// sees it. Also set when the next progress places inputs.
    barrier_next_progress: bool = false,
    /// Inputs taken for the next model request; its progress places them.
    /// Owned by the session's allocator.
    placed_next: std.ArrayList([]const u8) = .empty,
    /// Inputs the pending resume accepted and never placed, in order. Owned
    /// by the session's allocator.
    pending_inputs: []journal.PendingInput = &.{},
    /// Follow-ups the journal holds that no turn ran, until the host takes
    /// them. Owned by the session's allocator.
    pending_follow_ups: []journal.PendingInput = &.{},
    /// Accepted follow-ups no turn has placed yet. A snapshot waits for none.
    follow_ups_waiting: usize = 0,
    /// Steers the open turn accepted and has not placed. A snapshot where a
    /// turn yielded waits for none, since it carries no inputs. A withdrawn
    /// input leaves the count as it is, which only skips such a snapshot.
    steers_waiting: usize = 0,
    /// The follow-up the running turn runs, until a progress places it.
    /// Owned by the session's allocator.
    placing_follow_up: ?[]u8 = null,
    /// The progress whose barrier a cancel interrupted: the turn commits
    /// from it as interrupted. Owned by the session's allocator.
    cancelled_progress: ?session_codec.RecoveryCheckpoint = null,
    /// The host's id for the starting turn, until its first progress names
    /// it; then the open turn's, until it ends; then the last turn's.
    next_turn_id: TurnId = .{},
    open_turn_id: TurnId = .{},
    last_turn_id: TurnId = .{},
    /// When the running turn stops, in milliseconds since the epoch, if the
    /// host gave a time: its first progress at or after it yields.
    yield_at_ms: ?i64 = null,
    /// Set once the running turn has sent a model request in this prompt. A
    /// turn yields only after one, so every prompt makes progress.
    yield_armed: bool = false,
    /// The host stores every input before it hands it in, so a progress that
    /// places one, or a turn's first, need not wait for the host.
    inputs_durable: bool = false,
    /// The pending resume is a turn that yielded: it continues without being
    /// told it was interrupted.
    pending_resume_yielded: bool = false,
    /// The host keeps an image store: events and snapshots name the images
    /// in `stored_images` instead of holding their bytes.
    image_store: bool = false,
    /// The newest images the session keeps when the host keeps a store;
    /// older ones keep only their names (`dropOutsideWindow`).
    image_window: session_codec.ImageWindow = .{},
    /// The images the host's store holds: those it said it stored before it
    /// sent their prompt, and those an open resolved from it. Owned by the
    /// session's allocator.
    stored_images: session_codec.StoredImages = .{},
    /// The calls of the pending resume's answering step that no result was
    /// recorded for: the ones answered as possibly run. Owned by the
    /// session's allocator.
    pending_resume_ambiguous: []types.ToolCall = &.{},
    /// The last progress this journal sent in the open turn, so the next can
    /// carry only what is new. Its hashes are owned by the session's
    /// allocator; `stale` once its turn ended or a snapshot took the turn in.
    last_progress: ?LastProgress = null,

    const LastProgress = struct {
        seq: u64,
        hashes: session_codec.ExecutionHashes,
        stale: bool = false,
    };

    pub fn deinit(self: *Journal, alloc: Allocator) void {
        self.stored_images.deinit(alloc);
        if (self.last_progress) |*last| last.hashes.deinit(alloc);
        self.last_progress = null;
        self.dropPendingResume(alloc);
        self.clearPlaced(alloc);
        self.placed_next.deinit(alloc);
        if (self.placing_follow_up) |id| alloc.free(id);
        if (self.cancelled_progress) |*checkpoint| checkpoint.deinit(alloc);
        self.cancelled_progress = null;
        journal.freePendingInputs(alloc, self.takeFollowUps());
    }

    /// Names the turn that is starting; its first progress records the name.
    pub fn nameNextTurn(self: *Journal, id: ?[]const u8) void {
        self.next_turn_id = TurnId.of(id);
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
        self.pending_resume_yielded = false;
        types.freeToolCallSlice(alloc, self.pending_resume_ambiguous);
        self.pending_resume_ambiguous = &.{};
        if (self.pending_inputs.len > 0) {
            debug_trace.logf("session", "event=libfx_journal_inputs_dropped count={d} reason=resume_replaced", .{self.pending_inputs.len});
        }
        self.dropPendingInputs(alloc);
    }

    /// The calls the crash left running in the pending resume that recorded
    /// no result, answered as possibly run unless the host has the resume
    /// run them again. Borrowed from the journal.
    pub fn ambiguousCalls(self: *const Journal) []const types.ToolCall {
        if (self.pending_resume == null) return &.{};
        return self.pending_resume_ambiguous;
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
        if (!self.inputs_durable) self.barrier_next_progress = true;
    }

    /// Starts a turn's time limit: `yield_at_ms` is when it stops, or null.
    pub fn startYieldClock(self: *Journal, yield_at_ms: ?i64) void {
        self.yield_at_ms = yield_at_ms;
        self.yield_armed = false;
    }

    /// Whether the progress just sent, before a model request at `now_ms`,
    /// is where the turn yields. The first request of a prompt always goes
    /// out, so each prompt makes progress however late it starts.
    pub fn yieldsAt(self: *Journal, now_ms: i64) bool {
        const deadline = self.yield_at_ms orelse return false;
        if (!self.yield_armed) {
            self.yield_armed = true;
            return false;
        }
        return now_ms >= deadline;
    }

    /// Keeps `checkpoint`, the progress a yield stopped at, as the pending
    /// resume, so this session can continue it as a later process would.
    /// `session_alloc` owns the copy.
    pub fn keepYielded(self: *Journal, session_alloc: Allocator, checkpoint: session_codec.RecoveryCheckpoint) Allocator.Error!void {
        const owned = try checkpoint.dupe(session_alloc);
        self.dropPendingResume(session_alloc);
        self.pending_resume = owned;
        self.pending_resume_yielded = true;
        self.yield_at_ms = null;
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
            self.follow_ups_waiting -|= 1;
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
    /// placing the inputs taken since the last progress. After the turn's
    /// first, a progress carries only what is new since the one before it,
    /// unless anything earlier changed. `session_alloc` owns the placed ids.
    pub fn appendProgress(
        self: *Journal,
        alloc: Allocator,
        session_alloc: Allocator,
        session_id: []const u8,
        checkpoint: session_codec.RecoveryCheckpoint,
        model: []const u8,
    ) !void {
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const hashes = try session_codec.executionHashes(scratch.allocator(), checkpoint);
        const delta: ?journal.Delta = if (self.last_progress) |last|
            if (self.progress_open and !last.stale and hashes.extends(last.hashes))
                .{ .base_seq = last.seq, .from = last.hashes.counts() }
            else
                null
        else
            null;
        const seq = self.cursor.next_seq;
        try self.appendMarked(alloc, session_id, .{ .turn_progress = .{
            .checkpoint = checkpoint,
            .placed = self.placed_next.items,
            .model = model,
            .turn_id = self.next_turn_id.slice(),
            .delta = delta,
        } }, self.barrier_next_progress);
        // The next progress extends this one. Without a copy of its hashes it
        // carries everything, which is always correct.
        if (self.last_progress) |*last| last.hashes.deinit(session_alloc);
        self.last_progress = null;
        if (hashes.dupe(session_alloc)) |owned| {
            self.last_progress = .{ .seq = seq, .hashes = owned };
        } else |_| {
            debug_trace.logf("session", "event=libfx_journal_progress_base_dropped seq={d} reason=out_of_memory next=full", .{seq});
        }
        const follow_up_placed: usize = @intFromBool(self.placing_follow_up != null);
        self.steers_waiting -|= self.placed_next.items.len -| follow_up_placed;
        if (self.next_turn_id.len > 0) {
            self.open_turn_id = self.next_turn_id;
            self.next_turn_id = .{};
        }
        if (self.placing_follow_up) |id| {
            self.follow_ups_waiting -|= 1;
            session_alloc.free(id);
            self.placing_follow_up = null;
        }
        self.clearPlaced(session_alloc);
    }

    /// Sends `event` as the session's next entry. On failure the cursor
    /// stays put, so the next event takes the same `seq`.
    pub fn append(self: *Journal, alloc: Allocator, session_id: []const u8, event: Event) !void {
        return self.appendMarked(alloc, session_id, event, false);
    }

    /// `append`, telling the host with `barrier` that fx waits for the event
    /// to be stored before it goes on, so the host can store the events
    /// nobody waits for more lazily.
    pub fn appendMarked(self: *Journal, alloc: Allocator, session_id: []const u8, event: Event, barrier: bool) !void {
        return self.appendWith(alloc, session_id, event, barrier, null);
    }

    /// Sends a turn's end, `turn_committed` or `turn_progress_cleared`, with
    /// `stop_reason`, how its prompt answers: the record that ends the turn
    /// says how it ended, so recovery never has to guess.
    pub fn appendEnd(self: *Journal, alloc: Allocator, session_id: []const u8, event: Event, stop_reason: []const u8) !void {
        return self.appendWith(alloc, session_id, event, false, stop_reason);
    }

    fn appendWith(self: *Journal, alloc: Allocator, session_id: []const u8, event: Event, barrier: bool, stop_reason: ?[]const u8) !void {
        var params: std.Io.Writer.Allocating = .init(alloc);
        defer params.deinit();
        try params.writer.writeAll("{\"sessionId\":");
        try jsonrpc.writeJsonStr(session_id, &params.writer);
        try params.writer.writeAll(",\"events\":[");
        const next = if (stop_reason) |reason|
            try self.cursor.writeEnd(&params.writer, event, self.storedImages(), reason)
        else if (self.storedImages()) |stored|
            try self.cursor.writeNamingImages(&params.writer, event, stored)
        else
            try self.cursor.write(&params.writer, event);
        try params.writer.writeByte(']');
        if (barrier) try params.writer.writeAll(",\"barrier\":true");
        try params.writer.writeByte('}');
        try self.writer.writeNotification(alloc, "libfx/journal_append", params.written());
        self.cursor = next;
        // Matches the fold: intents and compaction leave the open turn
        // standing.
        switch (event) {
            .turn_progress => self.progress_open = true,
            .turn_committed, .turn_progress_cleared => {
                self.progress_open = false;
                self.last_turn_id = self.open_turn_id;
                self.open_turn_id = .{};
                // A turn's steers end with it.
                self.steers_waiting = 0;
                // The next turn's first progress carries all of it.
                if (self.last_progress) |*last| last.stale = true;
            },
            .input_accepted => |input| switch (input.kind) {
                .follow_up => self.follow_ups_waiting += 1,
                .steer => self.steers_waiting += 1,
            },
            .tool_intent, .history_replaced, .input_withdrawn, .turn_yielded, .tool_result => {},
        }
    }

    /// The images events and snapshots name, when the host keeps a store.
    pub fn storedImages(self: *const Journal) ?*const session_codec.StoredImages {
        return if (self.image_store) &self.stored_images else null;
    }

    /// Records a prompt image the host stored before it sent it, under
    /// `name`, which counts only when it is the image's digest. A name that
    /// does not match leaves the image inline.
    pub fn noteStoredImage(
        self: *Journal,
        alloc: Allocator,
        image: types.ImageAttachment,
        name: session_codec.ImageName,
    ) Allocator.Error!void {
        if (!self.image_store) return;
        const digest = image.snapshot_sha256 orelse return;
        if (image.inline_data == null or !std.mem.eql(u8, digest, &name)) {
            debug_trace.logf("session", "event=libfx_image_not_stored id={d} reason=name_mismatch", .{image.id});
            return;
        }
        try self.stored_images.add(alloc, name);
    }

    /// Keeps the session within its image window when the host keeps a
    /// store: each image of `history` (owned by `history_alloc`) older than
    /// the window loses its bytes and keeps its name. A turn's images join the
    /// window once the turn enters the history; until then they stay outside
    /// it, as an open keeps the open turn's (`keepNeededImages`), so a session
    /// opened at any point holds the images the running one held.
    pub fn dropOutsideWindow(
        self: *Journal,
        alloc: Allocator,
        history_alloc: Allocator,
        history: []types.HistoryTurn,
    ) Allocator.Error!void {
        if (!self.image_store) return;
        var held: std.ArrayList(HeldImage) = .empty;
        defer held.deinit(alloc);
        var sizes: std.ArrayList(?usize) = .empty;
        defer sizes.deinit(alloc);
        for (history) |*turn| {
            if (userOf(turn)) |user| for (user.images) |*image| {
                if (try countSize(alloc, &sizes, windowSize(image.*))) try held.append(alloc, .{ .prompt = image });
            };
            if (executionOf(turn)) |execution| for (execution.tool_steps) |step| for (step.tool_results) |result| for (result.tool_images) |*image| {
                if (try countSize(alloc, &sizes, toolWindowSize(image.*))) try held.append(alloc, .{ .tool = image });
            };
        }
        const outside = self.image_window.oldestOutside(sizes.items);
        var dropped: usize = 0;
        for (held.items[0..outside]) |image| switch (image) {
            .prompt => |prompt| {
                const bytes = prompt.inline_data orelse continue;
                history_alloc.free(bytes);
                prompt.inline_data = null;
                dropped += 1;
            },
            .tool => |tool| {
                if (tool.droppedFromSession()) continue;
                if (tool.name == null) {
                    tool.name = try inlineToolImageName(alloc, tool.data) orelse {
                        debug_trace.logf("session", "event=libfx_image_kept reason=inline_tool_image_not_base64 bytes={d}", .{tool.data.len});
                        continue;
                    };
                }
                const empty = try history_alloc.alloc(u8, 0);
                history_alloc.free(tool.data);
                tool.data = empty;
                dropped += 1;
            },
        };
        if (dropped > 0) debug_trace.logf("session", "event=libfx_images_dropped count={d} reason=image_window max_images={d} max_bytes={d}", .{ dropped, self.image_window.max_images, self.image_window.max_bytes });
    }

    /// Records that a call of the running batch finished, with what the
    /// model sees of it. Nothing waits for it to be stored: a crash before
    /// the next progress answers the call with it instead of with "may have
    /// partly run".
    pub fn recordToolResult(self: *Journal, alloc: Allocator, session_id: []const u8, result: journal.ToolResult) !void {
        if (!self.progress_open) return;
        try self.append(alloc, session_id, .{ .tool_result = result });
    }

    /// The follow-up a starting turn runs: its first progress places it.
    pub fn placeFollowUp(self: *Journal, alloc: Allocator, id: []const u8) Allocator.Error!void {
        const owned = try alloc.dupe(u8, id);
        errdefer alloc.free(owned);
        try self.notePlaced(alloc, &.{id});
        if (self.placing_follow_up) |old| alloc.free(old);
        self.placing_follow_up = owned;
    }

    /// Whether the session is at a point a snapshot can stand for: no turn
    /// open or waiting to resume, and no follow-up waiting for its turn.
    pub fn quiet(self: *const Journal) bool {
        return !self.progress_open and self.pending_resume == null and
            self.follow_ups_waiting == 0 and self.cursor.next_seq > 1;
    }

    /// Whether the session is at a turn that yielded and nothing else waits:
    /// no call a crash left running, no input for the turn, no follow-up. A
    /// snapshot can stand for it with the open turn in it.
    pub fn yieldedQuiet(self: *const Journal) bool {
        return self.progress_open and self.pending_resume != null and self.pending_resume_yielded and
            self.pending_resume_answered == null and self.pending_inputs.len == 0 and
            self.steers_waiting == 0 and self.follow_ups_waiting == 0;
    }

    /// Records that a snapshot holding the open turn went to the host. A load
    /// from it starts the turn from the snapshot, without the progress record
    /// the snapshot folded, so the turn's next progress carries all of it
    /// instead of extending that record.
    pub fn noteOpenTurnSnapshot(self: *Journal) void {
        if (self.last_progress) |*last| last.stale = true;
    }

    /// Records that the open turn ended without a history entry, and how,
    /// in `stop_reason`. A turn with no progress on record needs no event.
    pub fn clearProgress(self: *Journal, alloc: Allocator, session_id: []const u8, stop_reason: []const u8) !void {
        if (!self.progress_open) return;
        try self.appendEnd(alloc, session_id, .turn_progress_cleared, stop_reason);
    }
};

pub const Opened = struct {
    turns: usize,
    /// A crash left a turn open; `resume` continues it.
    resumable: bool,
    /// The host's ids for the open turn and the last turn that ended.
    open_turn_id: TurnId = .{},
    last_turn_id: TurnId = .{},
    /// The open turn yielded; the resume continues it without the notice.
    yielded: bool = false,
    /// What the snapshot recorded about the agent that saved it, owned by the
    /// `alloc` passed to `open` (`Meta.free`); empty without one.
    checkpoint_meta: checkpoint_codec.Meta = .{},
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

fn userOf(turn: *types.HistoryTurn) ?*types.UserTurn {
    return switch (turn.*) {
        .assistant => |*entry| &entry.user,
        .interrupted => |*entry| &entry.user,
        .compacted_summary => null,
    };
}

fn executionOf(turn: *types.HistoryTurn) ?*types.ExecutionMemory {
    return switch (turn.*) {
        .assistant => |*entry| &entry.execution,
        .interrupted => |*entry| &entry.execution,
        .compacted_summary => null,
    };
}

/// An image the window counts: a prompt's, or one a tool returned, counted
/// together in the order they entered the session.
const HeldImage = union(enum) {
    prompt: *types.ImageAttachment,
    tool: *types.ToolImage,
};

const MissingImages = std.array_hash_map.Auto(session_codec.ImageName, usize);

/// What the image window counts for one image.
const WindowSize = union(enum) {
    /// Its bytes: those it holds, or for an image an open has yet to stage,
    /// the size its record gives (`unstaged`).
    bytes: usize,
    /// One the session dropped, which keeps every older image out.
    dropped,
    /// One with neither bytes nor a name, which only a host reference
    /// describes, and so holds nothing.
    none,
};

/// What the window counts for `image`, as the session holds it.
fn windowSize(image: types.ImageAttachment) WindowSize {
    if (image.inline_data) |bytes| return .{ .bytes = bytes.len };
    return if (image.droppedFromSession()) .dropped else .none;
}

/// What the window counts for a tool image: its decoded bytes, whether the
/// host stored it or the session holds it inline, as one the store refused
/// or an older libfx saved. One with only a host reference holds nothing.
fn toolWindowSize(image: types.ToolImage) WindowSize {
    if (image.droppedFromSession()) return .dropped;
    if (image.data.len == 0) return .none;
    return .{ .bytes = std.base64.standard.Decoder.calcSizeForSlice(image.data) catch image.data.len };
}

/// The name of a tool image's bytes, which one held inline takes when it
/// leaves the window, so it is saved dropped like a stored one; null for
/// bytes that are not base64.
fn inlineToolImageName(alloc: Allocator, data: []const u8) Allocator.Error!?session_codec.ImageName {
    const size = std.base64.standard.Decoder.calcSizeForSlice(data) catch return null;
    const bytes = try alloc.alloc(u8, size);
    defer alloc.free(bytes);
    std.base64.standard.Decoder.decode(bytes, data) catch return null;
    return session_codec.imageNameOf(bytes);
}

/// An image an open has yet to stage, with the size its record gives.
const Unstaged = struct { name: session_codec.ImageName, size: usize };

/// The name and size of `image` when it is one an open has yet to stage: it
/// reads such an image as one without bytes, which `missing` names.
fn unstaged(image: types.ImageAttachment, missing: *const MissingImages) ?Unstaged {
    if (!image.droppedFromSession()) return null;
    const name = session_codec.imageName(image.snapshot_sha256.?) orelse return null;
    return .{ .name = name, .size = missing.get(name) orelse return null };
}

/// `unstaged` for a tool image, which an open reads by name without bytes.
fn unstagedTool(image: types.ToolImage, missing: *const MissingImages) ?Unstaged {
    if (!image.droppedFromSession()) return null;
    const name = image.name.?;
    return .{ .name = name, .size = missing.get(name) orelse return null };
}

/// Appends what the window counts for one image to `sizes`, oldest first,
/// and returns whether it counted.
fn countSize(alloc: Allocator, sizes: *std.ArrayList(?usize), size: WindowSize) Allocator.Error!bool {
    switch (size) {
        .bytes => |bytes| try sizes.append(alloc, bytes),
        .dropped => try sizes.append(alloc, null),
        .none => return false,
    }
    return true;
}

/// Leaves in `images.missing` only the names of images the window keeps, so
/// the host stages none the session would drop. The window counts the
/// history alone, as it did when the last turn entered it
/// (`Journal.dropOutsideWindow`); the open turn's images, its prompt's and
/// its tools', are always needed.
fn keepNeededImages(
    alloc: Allocator,
    images: *session_codec.ImageResolver,
    history: []const types.HistoryTurn,
    open_user: ?types.UserTurn,
    open_execution: ?types.ExecutionMemory,
    open_finished: []const journal.Finished,
    window: session_codec.ImageWindow,
) Allocator.Error!void {
    var sizes: std.ArrayList(?usize) = .empty;
    defer sizes.deinit(alloc);
    var names: std.ArrayList(?session_codec.ImageName) = .empty;
    defer names.deinit(alloc);
    for (history) |turn| {
        const user, const execution = switch (turn) {
            .assistant => |entry| .{ entry.user, entry.execution },
            .interrupted => |entry| .{ entry.user, entry.execution },
            .compacted_summary => continue,
        };
        try countOpenedImages(alloc, &sizes, &names, user.images, &images.missing);
        try countOpenedToolImages(alloc, &sizes, &names, execution, &images.missing);
    }
    const outside = window.oldestOutside(sizes.items);
    var needed: MissingImages = .empty;
    errdefer needed.deinit(images.alloc);
    for (names.items[outside..], sizes.items[outside..]) |name, size| {
        if (name) |value| try needed.put(images.alloc, value, size.?);
    }
    if (open_user) |user| for (user.images) |image| {
        if (unstaged(image, &images.missing)) |found| try needed.put(images.alloc, found.name, found.size);
    };
    if (open_execution) |execution| for (execution.tool_steps) |step| for (step.tool_results) |result| for (result.tool_images) |image| {
        if (unstagedTool(image, &images.missing)) |found| try needed.put(images.alloc, found.name, found.size);
    };
    // A result the open turn recorded before a crash answers its call again.
    for (open_finished) |finished| for (finished.images) |image| {
        if (unstagedTool(image, &images.missing)) |found| try needed.put(images.alloc, found.name, found.size);
    };
    if (outside > 0) debug_trace.logf("session", "event=libfx_image_window_open outside={d} needed={d}", .{ outside, needed.count() });
    images.missing.deinit(images.alloc);
    images.missing = needed;
}

/// Counts the images of `user_images` an open read, each with its name when
/// it is one the host has yet to stage.
fn countOpenedImages(
    alloc: Allocator,
    sizes: *std.ArrayList(?usize),
    names: *std.ArrayList(?session_codec.ImageName),
    user_images: []const types.ImageAttachment,
    missing: *const MissingImages,
) Allocator.Error!void {
    for (user_images) |image| {
        const pending = unstaged(image, missing);
        if (!try countSize(alloc, sizes, if (pending) |found| .{ .bytes = found.size } else windowSize(image))) continue;
        try names.append(alloc, if (pending) |found| found.name else null);
    }
}

/// Counts the tool images of `execution` an open read, as `countOpenedImages`
/// counts a prompt's.
fn countOpenedToolImages(
    alloc: Allocator,
    sizes: *std.ArrayList(?usize),
    names: *std.ArrayList(?session_codec.ImageName),
    execution: types.ExecutionMemory,
    missing: *const MissingImages,
) Allocator.Error!void {
    for (execution.tool_steps) |step| for (step.tool_results) |result| for (result.tool_images) |image| {
        const pending = unstagedTool(image, missing);
        if (!try countSize(alloc, sizes, if (pending) |found| .{ .bytes = found.size } else toolWindowSize(image))) continue;
        try names.append(alloc, if (pending) |found| found.name else null);
    };
}

/// Rebuilds a fresh session from the host's events, after `snapshot` when
/// the host stored one, and starts its journal after them. A turn a crash
/// left open becomes the pending resume, with every call it left running
/// answered as possibly run, for the model to decide about unless the host
/// has the resume run it again (`rerunCalls`); `session_alloc` owns it.
/// With `inputs_durable`, the host stores every input before handing it in.
/// Named images resolve through `images`, which holds what the host staged;
/// when one is missing the session stays unopened and `error.ImagesMissing`
/// leaves every missing name in `images.missing`. With `image_store` the
/// journal names stored images from then on, and the session keeps only the
/// newest images `window` holds: an older one is neither needed nor kept.
pub fn open(
    alloc: Allocator,
    session_alloc: Allocator,
    writer: *jsonrpc.Writer,
    runtime: *session_runtime.SessionRuntime,
    events_json: []const u8,
    snapshot: ?[]const u8,
    inputs_durable: bool,
    images: *session_codec.ImageResolver,
    image_store: bool,
    window: session_codec.ImageWindow,
) !struct { Journal, Opened } {
    if (!runtime.agent.fresh or runtime.agent.history.items.len != 0) return error.AgentNotFresh;
    var base: journal.Base = .{ .images = images };
    var decoded: ?checkpoint_codec.Decoded = null;
    defer if (decoded) |*value| value.deinit(alloc);
    var saved_meta: checkpoint_codec.Meta = .{};
    errdefer saved_meta.free(alloc);
    if (snapshot) |bytes| {
        const parsed = try journal.parseSnapshot(bytes);
        decoded = checkpoint_codec.decodeWithImages(alloc, parsed.checkpoint, images) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsupportedCheckpointVersion => return error.UnsupportedJournalVersion,
            else => return error.InvalidJournal,
        };
        saved_meta = try decoded.?.meta.dupe(alloc);
        base = .{
            .history = decoded.?.history,
            .cursor = .{ .next_seq = parsed.seq + 1, .turn = parsed.turn },
            .last_turn_id = parsed.last_turn_id,
            .open_turn = parsed.open_turn,
            .images = images,
        };
    }
    var folded = try journal.foldFrom(alloc, events_json, base);
    defer folded.deinit(alloc);
    if (image_store and images.missing.count() > 0) {
        try keepNeededImages(alloc, images, folded.history, if (folded.open_turn) |turn| turn.user else null, if (folded.open_turn) |turn| turn.execution else null, folded.finished, window);
    }
    // A history missing an image it keeps is not the one saved: open none.
    if (images.missing.count() > 0) {
        debug_trace.logf("session", "event=libfx_journal_images_missing count={d}", .{images.missing.count()});
        return error.ImagesMissing;
    }
    if (folded.history.len > 0) try runtime.agent.restoreHistory(alloc, folded.history);
    if (decoded) |value| runtime.agent.turn_usage = value.usage;
    var state: Journal = .{
        .writer = writer,
        .cursor = folded.cursor,
        .progress_open = folded.open_turn != null,
        .pending_follow_ups = try dupePendingInputs(session_alloc, folded.pending_follow_ups),
        .follow_ups_waiting = folded.pending_follow_ups.len,
        .open_turn_id = TurnId.of(folded.open_turn_id),
        .last_turn_id = TurnId.of(folded.last_turn_id),
        .inputs_durable = inputs_durable,
        .steers_waiting = folded.pending_inputs.len,
        .image_store = image_store,
        .image_window = window,
    };
    errdefer state.deinit(session_alloc);
    // An image the open resolved is in the store; one it read inline is not.
    if (image_store) for (images.resolved.keys()) |name| try state.stored_images.add(session_alloc, name);
    try state.dropOutsideWindow(alloc, alloc, runtime.agent.history.items);
    const checkpoint = folded.open_turn orelse {
        return .{ state, .{ .turns = folded.history.len, .resumable = false, .last_turn_id = state.last_turn_id, .checkpoint_meta = saved_meta } };
    };

    debug_trace.logf("session", "event=libfx_journal_open_turn turn={d} running_calls={d} finished_calls={d} resolved=pending_resume", .{ folded.cursor.turn, folded.running_calls.len, folded.finished.len });
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var answered = checkpoint;
    forgetUnrecordedCalls(&answered, folded.running_calls.len);
    const answered_step = answered.execution.tool_steps.len;
    try answerRunning(scratch.allocator(), &answered, folded.running_calls, folded.finished);
    state.pending_resume = try answered.dupe(session_alloc);
    if (folded.running_calls.len > 0) state.pending_resume_answered = answered_step;
    state.pending_resume_ambiguous = try unfinishedCalls(session_alloc, folded.running_calls, folded.finished);
    state.pending_resume_yielded = folded.yielded;
    state.pending_inputs = try dupePendingInputs(session_alloc, folded.pending_inputs);
    return .{ state, .{
        .turns = folded.history.len,
        .resumable = true,
        .open_turn_id = state.open_turn_id,
        .last_turn_id = state.last_turn_id,
        .yielded = folded.yielded,
        .checkpoint_meta = saved_meta,
    } };
}

/// An owned copy of `pending` ready to continue: unless the turn yielded,
/// the model is told the session was interrupted, as the CLI tells it after
/// a crash (`RecoveryCheckpoint.resumed`); then it sees the inputs the turn
/// accepted and never placed, and the attempt budget starts over, so
/// repeated crashes never turn into a refusal to resume.
pub fn resumeCheckpoint(
    alloc: Allocator,
    pending: session_codec.RecoveryCheckpoint,
    inputs: []const journal.PendingInput,
    yielded: bool,
) !session_codec.RecoveryCheckpoint {
    const texts = try alloc.alloc([]const u8, inputs.len);
    defer alloc.free(texts);
    for (inputs, texts) |input, *text| text.* = input.text;
    var resumed = try pending.resumed(alloc, !yielded, texts);
    resumed.consumed_provider_attempts = 0;
    resumed.outstanding_reservation = false;
    return resumed;
}

/// Forgets a response whose calls never reached the journal. After a
/// response with calls, the progress saved marks their outcome uncertain, but
/// only the calls' intent records them, and only a call that is safe to run
/// twice starts before its intent is stored. With no intent after it, none of
/// the response's calls with effects ran, so the model is asked again instead
/// of being made to reconcile calls it cannot see. `running` is how many
/// calls the journal recorded and did not answer.
fn forgetUnrecordedCalls(turn: *session_codec.RecoveryCheckpoint, running: usize) void {
    if (running > 0 or turn.tool_state != .uncertain) return;
    debug_trace.logf("session", "event=libfx_journal_response_dropped reason=calls_never_recorded assistant_bytes={d}", .{turn.assistant_source.len});
    turn.tool_state = .none;
    turn.assistant_source = @constCast("");
}

/// Owned copies of the calls in `calls` that `finished` has no result for.
fn unfinishedCalls(alloc: Allocator, calls: []const types.ToolCall, finished: []const journal.Finished) Allocator.Error![]types.ToolCall {
    var kept: std.ArrayList(types.ToolCall) = .empty;
    errdefer {
        for (kept.items) |call| types.freeToolCall(alloc, call);
        kept.deinit(alloc);
    }
    for (calls) |call| {
        if (finishedResult(finished, call.id) != null) continue;
        const copy = try types.dupeToolCall(alloc, call);
        kept.append(alloc, copy) catch |err| {
            types.freeToolCall(alloc, copy);
            return err;
        };
    }
    return kept.toOwnedSlice(alloc);
}

fn finishedResult(finished: []const journal.Finished, id: []const u8) ?journal.Finished {
    for (finished) |entry| if (std.mem.eql(u8, entry.id, id)) return entry;
    return null;
}

/// Answers each call the crash left running, as one more step of the open
/// turn, so the model sees every call it made answered: a call whose result
/// was recorded as it finished gets that result; any other, a result saying
/// it may have partly run, so the model decides whether to run it again. The
/// response that made the calls, with any text the model wrote before them,
/// is now that step, so the turn continues after its tools. Borrows `calls`,
/// `finished` and the turn's text; allocates in `scratch`.
fn answerRunning(scratch: Allocator, turn: *session_codec.RecoveryCheckpoint, calls: []types.ToolCall, finished: []const journal.Finished) Allocator.Error!void {
    if (calls.len == 0) return;
    const unfinished = session_adapter.unfinished_tool_output;
    const results = try scratch.alloc(types.PersistedToolResult, calls.len);
    for (calls, results) |call, *result| {
        const recorded = finishedResult(finished, call.id);
        const output: []const u8 = if (recorded) |entry| entry.output else unfinished;
        result.* = .{
            .tool_call_id = @constCast(call.id),
            .tool_name = @constCast(call.name),
            .status = if (recorded) |entry| (if (entry.failed) .failure else .success) else .failure,
            .output = @constCast(output),
            .tool_images = if (recorded) |entry| entry.images else &.{},
            .output_bytes = output.len,
            .stored_output_bytes = output.len,
        };
    }
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
/// answers the calls a crash left running, that `runner.rerun` says the host
/// asked to run again, under the id the model gave it, and puts what
/// `runner.run` returns in place of the answer that it may have partly run.
/// Every other call keeps that answer, for the model to decide about. Stops
/// at the first call `runner.run` returns null for (the turn is being
/// cancelled or handed off), so that call and every later one keep it too.
/// `alloc` owns `checkpoint` and the results put in it. Returns how many
/// calls ran again.
pub fn rerunCalls(
    alloc: Allocator,
    checkpoint: *session_codec.RecoveryCheckpoint,
    step_index: usize,
    runner: anytype,
    observer: ?*observation.Observer,
) !usize {
    const steps = checkpoint.execution.tool_steps;
    if (step_index >= steps.len) return 0;
    const step = &steps[step_index];
    var reran: usize = 0;
    for (step.tool_calls, step.tool_results) |call, *result| {
        if (!runner.rerun(call)) continue;
        const outcome = (try runner.run(alloc, call)) orelse {
            debug_trace.logf("session", "event=libfx_resume_rerun_stopped call={s} reran={d} kept=may_have_partly_run", .{ call.id, reran });
            break;
        };
        defer outcome.deinit(alloc);
        const replacement = try persistedResult(alloc, call, outcome);
        types.freePersistedToolResult(alloc, result.*);
        result.* = replacement;
        if (observer) |sink| sink.emit(.{ .tool_result = .{ .call = call, .output = replacement.output, .status = replacement.status } });
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
    var session: Journal = .{ .writer = &writer, .follow_ups_waiting = 1, .cursor = .{ .next_seq = 3, .turn = 2 } };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    try session.placeFollowUp(alloc, "follow-1");
    try std.testing.expectEqual(@as(usize, 1), session.follow_ups_waiting);
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expectEqual(@as(usize, 0), session.follow_ups_waiting);
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
    var session: Journal = .{ .writer = &writer, .follow_ups_waiting = 1, .cursor = .{ .next_seq = 3, .turn = 2 } };
    defer session.deinit(alloc);

    try session.placeFollowUp(alloc, "follow-1");
    try std.testing.expect(!session.quiet());
    try session.endUnplaced(alloc, alloc, "session");
    try std.testing.expectEqual(@as(usize, 0), session.follow_ups_waiting);
    try std.testing.expect(session.quiet());
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"type\":\"input_withdrawn\",\"data\":{\"id\":\"follow-1\"}") != null);
}

test "a turn's id reaches its first progress only, and is the last turn's once the turn ends" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    session.nameNextTurn("turn-1");
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, capture.frames.items, "\"turnId\":\"turn-1\""));
    try std.testing.expectEqualStrings("turn-1", session.open_turn_id.slice().?);

    try session.clearProgress(alloc, "session", "error");
    try std.testing.expect(session.open_turn_id.slice() == null);
    try std.testing.expectEqualStrings("turn-1", session.last_turn_id.slice().?);
    // The end says how the turn ended.
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"type\":\"turn_progress_cleared\",\"stopReason\":\"error\"}") != null);

    // A turn the host did not name ends with no last id.
    session.nameNextTurn(null);
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try session.clearProgress(alloc, "session", "cancelled");
    try std.testing.expect(session.last_turn_id.slice() == null);
}

test "a response whose calls never reached the journal is asked for again" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    var lost = progress;
    lost.tool_state = .uncertain;
    lost.assistant_source = @constCast("Let me look that up.");
    forgetUnrecordedCalls(&lost, 0);
    try std.testing.expectEqual(session_codec.RecoveryToolState.none, lost.tool_state);
    try std.testing.expectEqualStrings("", lost.assistant_source);

    // Calls the journal recorded are answered instead.
    var recorded = progress;
    recorded.tool_state = .uncertain;
    recorded.assistant_source = @constCast("Let me look that up.");
    forgetUnrecordedCalls(&recorded, 1);
    try std.testing.expectEqual(session_codec.RecoveryToolState.uncertain, recorded.tool_state);
    try std.testing.expectEqualStrings("Let me look that up.", recorded.assistant_source);

    // A response cut off before any call keeps its text to continue from.
    var partial = progress;
    partial.assistant_source = @constCast("The answer is");
    forgetUnrecordedCalls(&partial, 0);
    try std.testing.expectEqual(session_codec.RecoveryToolState.none, partial.tool_state);
    try std.testing.expectEqualStrings("The answer is", partial.assistant_source);
}

/// Runs again the calls in `ids`, except `stop_at`, which it reports as cancelled.
const TestRerunner = struct {
    ids: []const []const u8,
    stop_at: ?[]const u8 = null,
    ran: *std.ArrayList([]const u8),

    pub fn rerun(self: TestRerunner, call: types.ToolCall) bool {
        for (self.ids) |id| if (std.mem.eql(u8, id, call.id)) return true;
        return false;
    }

    pub fn run(self: TestRerunner, alloc: Allocator, call: types.ToolCall) !?tool_dispatch.ToolResult {
        if (self.stop_at) |id| if (std.mem.eql(u8, call.id, id)) return null;
        try self.ran.append(std.testing.allocator, call.id);
        return .{ .success = try alloc.print("ran again as {s}", .{call.id}) };
    }
};

fn testAnswered(alloc: Allocator, calls: []types.ToolCall) !session_codec.RecoveryCheckpoint {
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    var answered = progress;
    try answerRunning(scratch.allocator(), &answered, calls, &.{});
    return answered.dupe(alloc);
}

test "a progress after its turn's first carries only what is new, and the next turn's first carries all" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    // A turn's first progress is one fx waits for; the host hears so.
    session.barrier_next_progress = true;
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    session.barrier_next_progress = false;
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"barrier\":true") != null);
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"user\"") != null);
    const first = capture.frames.items.len;
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    const second = capture.frames.items[first..];
    try std.testing.expect(std.mem.find(u8, second, "\"v\":2") != null);
    try std.testing.expect(std.mem.find(u8, second, "\"base\":1,\"steps\":0") != null);
    try std.testing.expect(std.mem.find(u8, second, "\"user\"") == null);
    try std.testing.expect(std.mem.find(u8, second, "\"barrier\"") == null);

    // A call's result goes out as it finishes, with nothing waiting for it.
    try session.recordToolResult(alloc, "session", .{ .id = "call-1", .name = "lookup", .failed = false, .output = "done" });
    try std.testing.expect(std.mem.find(u8, capture.frames.items, "\"type\":\"tool_result\"") != null);

    try session.clearProgress(alloc, "session", "error");
    const next = capture.frames.items.len;
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expect(std.mem.find(u8, capture.frames.items[next..], "\"base\"") == null);
    try std.testing.expect(std.mem.find(u8, capture.frames.items[next..], "\"user\"") != null);
}

test "a progress after a snapshot that holds its turn carries all of it" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer };
    defer session.deinit(alloc);
    var progress = try testProgress(alloc);
    defer progress.deinit(alloc);

    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    // A load from the snapshot has no record for the next progress to extend.
    session.noteOpenTurnSnapshot();
    const next = capture.frames.items.len;
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expect(std.mem.find(u8, capture.frames.items[next..], "\"base\"") == null);
    try std.testing.expect(std.mem.find(u8, capture.frames.items[next..], "\"user\"") != null);
    // The progress after that one extends it again.
    const after = capture.frames.items.len;
    try session.appendProgress(alloc, alloc, "session", progress, "fake/model");
    try std.testing.expect(std.mem.find(u8, capture.frames.items[after..], "\"base\":2,") != null);
}

test "a resumed turn runs again the calls the host asks for and leaves the rest to the model" {
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

    const ids = [_][]const u8{ "call-1", "call-3" };
    const reran = try rerunCalls(alloc, &answered, 0, TestRerunner{ .ids = &ids, .ran = &ran }, null);
    try std.testing.expectEqual(@as(usize, 2), reran);
    try std.testing.expectEqual(@as(usize, 2), ran.items.len);
    const results = answered.execution.tool_steps[0].tool_results;
    // Every call keeps its place, so results reach the model in its order.
    try std.testing.expectEqualStrings("call-1", results[0].tool_call_id);
    try std.testing.expectEqualStrings("ran again as call-1", results[0].output);
    try std.testing.expectEqual(types.PersistedToolStatus.success, results[0].status);
    try std.testing.expectEqualStrings(session_adapter.unfinished_tool_output, results[1].output);
    try std.testing.expectEqual(types.PersistedToolStatus.failure, results[1].status);
    try std.testing.expectEqualStrings("ran again as call-3", results[2].output);
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

    const ids = [_][]const u8{ "call-1", "call-2", "call-3" };
    const reran = try rerunCalls(alloc, &answered, 0, TestRerunner{ .ids = &ids, .stop_at = "call-2", .ran = &ran }, null);
    try std.testing.expectEqual(@as(usize, 1), reran);
    const results = answered.execution.tool_steps[0].tool_results;
    try std.testing.expectEqualStrings("ran again as call-1", results[0].output);
    try std.testing.expectEqualStrings(session_adapter.unfinished_tool_output, results[1].output);
    try std.testing.expectEqualStrings(session_adapter.unfinished_tool_output, results[2].output);
    // A step index past the turn's steps runs nothing.
    try std.testing.expectEqual(@as(usize, 0), try rerunCalls(alloc, &answered, 5, TestRerunner{ .ids = &ids, .ran = &ran }, null));
}

/// An inline image of `size` bytes for the window tests, every field owned by
/// `alloc`; `types.freeImageAttachment` frees it.
fn windowTestImage(alloc: Allocator, id: usize, size: usize) !types.ImageAttachment {
    const bytes = try alloc.alloc(u8, size);
    errdefer alloc.free(bytes);
    @memset(bytes, 'x');
    const path = try alloc.dupe(u8, "inline://image");
    errdefer alloc.free(path);
    const media_type = try alloc.dupe(u8, "image/png");
    errdefer alloc.free(media_type);
    const digest = session_codec.imageNameOf(bytes);
    return .{ .id = id, .path = path, .media_type = media_type, .snapshot_sha256 = try alloc.dupe(u8, &digest), .inline_data = bytes };
}

test "the image window drops the oldest history images, and not for an open turn's" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer, .image_store = true, .image_window = .{ .max_images = 2 } };
    defer session.deinit(alloc);
    var images: [3]types.ImageAttachment = undefined;
    for (&images, 0..) |*image, index| image.* = try windowTestImage(alloc, index + 1, 10);
    defer for (images) |image| types.freeImageAttachment(alloc, image);
    var history: [3]types.HistoryTurn = undefined;
    for (&history, &images) |*turn, *image| {
        turn.* = .{ .assistant = .{ .user = .{ .text = @constCast("look"), .images = image[0..1] }, .assistant = @constCast("ok") } };
    }

    // Two images at most: the two newest of history.
    try session.dropOutsideWindow(alloc, alloc, &history);
    try std.testing.expect(images[0].droppedFromSession());
    try std.testing.expect(images[1].inline_data != null and images[2].inline_data != null);

    // An open turn has not entered the history, so its image moves nothing.
    var pending = try testProgress(alloc);
    pending.user.images = try alloc.alloc(types.ImageAttachment, 1);
    pending.user.images[0] = try windowTestImage(alloc, 4, 10);
    session.pending_resume = pending;
    try session.dropOutsideWindow(alloc, alloc, &history);
    try std.testing.expect(images[1].inline_data != null and images[2].inline_data != null);
    try std.testing.expect(session.pending_resume.?.user.images[0].inline_data != null);
}

/// A one-image slice a tool returned, `size` bytes as base64, named as the
/// host stored it unless `named` is false; `types.freeToolImages` frees it.
fn windowTestToolImages(alloc: Allocator, size: usize, named: bool) ![]types.ToolImage {
    const bytes = try alloc.alloc(u8, size);
    defer alloc.free(bytes);
    @memset(bytes, 't');
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(size));
    errdefer alloc.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    const mime_type = try alloc.dupe(u8, "image/png");
    errdefer alloc.free(mime_type);
    const images = try alloc.alloc(types.ToolImage, 1);
    images[0] = .{ .data = encoded, .mime_type = mime_type, .name = if (named) session_codec.imageNameOf(bytes) else null };
    return images;
}

fn windowTestToolStep(results: *[1]types.PersistedToolResult, steps: *[1]types.ToolExecutionStep, images: []types.ToolImage) types.ExecutionMemory {
    results.* = .{.{
        .tool_images = images,
        .tool_call_id = @constCast("call"),
        .tool_name = @constCast("screenshot"),
        .status = .success,
        .output = @constCast("took it"),
        .output_bytes = 7,
        .stored_output_bytes = 7,
    }};
    steps.* = .{.{ .tool_results = results }};
    return .{ .tool_steps = steps };
}

test "the image window counts a turn's tool images after its prompt's, inline ones too, and drops them by name" {
    const alloc = std.testing.allocator;
    var capture: TestCapture = .{};
    defer capture.frames.deinit(alloc);
    var writer = jsonrpc.Writer.initCallback(&capture, TestCapture.write);
    var session: Journal = .{ .writer = &writer, .image_store = true, .image_window = .{ .max_images = 2 } };
    defer session.deinit(alloc);
    var prompts: [2]types.ImageAttachment = undefined;
    for (&prompts, 0..) |*image, index| image.* = try windowTestImage(alloc, index + 1, 10);
    defer for (prompts) |image| types.freeImageAttachment(alloc, image);
    var tools: [2][]types.ToolImage = undefined;
    for (&tools) |*images| images.* = try windowTestToolImages(alloc, 10, true);
    defer for (tools) |images| types.freeToolImages(alloc, images);
    // A tool image the session holds inline, as one the store refused, the
    // oldest tool image here.
    const unstored = try windowTestToolImages(alloc, 12, false);
    defer types.freeToolImages(alloc, unstored);
    var unstored_bytes: [12]u8 = undefined;
    try std.base64.standard.Decoder.decode(&unstored_bytes, unstored[0].data);
    var results: [3][1]types.PersistedToolResult = undefined;
    var steps: [3][1]types.ToolExecutionStep = undefined;
    var history: [3]types.HistoryTurn = undefined;
    history[0] = .{ .assistant = .{ .user = .{ .text = @constCast("one"), .images = prompts[0..1] }, .assistant = @constCast("ok"), .execution = windowTestToolStep(&results[0], &steps[0], unstored) } };
    history[1] = .{ .assistant = .{ .user = .{ .text = @constCast("two"), .images = prompts[1..2] }, .assistant = @constCast("ok"), .execution = windowTestToolStep(&results[1], &steps[1], tools[0]) } };
    history[2] = .{ .assistant = .{ .user = .{ .text = @constCast("three") }, .assistant = @constCast("ok"), .execution = windowTestToolStep(&results[2], &steps[2], tools[1]) } };

    // Two images at most: the newest two tool images, in the order they
    // entered; every older one leaves, keeping its name. The inline one
    // counts as any image does, and takes the name of its bytes.
    try session.dropOutsideWindow(alloc, alloc, &history);
    try std.testing.expect(prompts[0].droppedFromSession());
    try std.testing.expect(unstored[0].droppedFromSession());
    try std.testing.expectEqualSlices(u8, &session_codec.imageNameOf(&unstored_bytes), &unstored[0].name.?);
    try std.testing.expect(prompts[1].droppedFromSession());
    try std.testing.expect(!tools[0][0].droppedFromSession() and tools[0][0].data.len > 0);
    try std.testing.expect(!tools[1][0].droppedFromSession() and tools[1][0].data.len > 0);
}

test "an open needs the newest tool images its window keeps, and every one of the open turn" {
    const alloc = std.testing.allocator;
    var staged: session_codec.StagedImages = .{};
    defer staged.deinit(alloc);
    var resolver: session_codec.ImageResolver = .{ .alloc = alloc, .staged = &staged };
    defer resolver.deinit();
    // Three tool images the host has not staged yet, read as names alone.
    var names: [3]session_codec.ImageName = undefined;
    var images: [3][1]types.ToolImage = undefined;
    for (&names, &images, 0..) |*name, *image, index| {
        name.* = session_codec.imageNameOf(&.{@as(u8, @intCast(index))});
        image.* = .{.{ .data = @constCast(&[_]u8{}), .mime_type = @constCast("image/png"), .name = name.* }};
        try resolver.missing.put(alloc, name.*, 10);
    }
    var results: [3][1]types.PersistedToolResult = undefined;
    var steps: [3][1]types.ToolExecutionStep = undefined;
    var history: [2]types.HistoryTurn = undefined;
    for (&history, 0..) |*turn, index| {
        turn.* = .{ .assistant = .{ .user = .{ .text = @constCast("look") }, .assistant = @constCast("ok"), .execution = windowTestToolStep(&results[index], &steps[index], &images[index]) } };
    }
    const open_execution = windowTestToolStep(&results[2], &steps[2], &images[2]);

    try keepNeededImages(alloc, &resolver, &history, null, open_execution, &.{}, .{ .max_images = 1 });
    try std.testing.expectEqual(@as(usize, 2), resolver.missing.count());
    try std.testing.expect(!resolver.missing.contains(names[0]));
    try std.testing.expect(resolver.missing.contains(names[1]) and resolver.missing.contains(names[2]));
}

test "an open needs the images of a result its open turn recorded before a crash" {
    const alloc = std.testing.allocator;
    var staged: session_codec.StagedImages = .{};
    defer staged.deinit(alloc);
    var resolver: session_codec.ImageResolver = .{ .alloc = alloc, .staged = &staged };
    defer resolver.deinit();
    const name = session_codec.imageNameOf("recorded shot");
    try resolver.missing.put(alloc, name, 13);
    var images = [_]types.ToolImage{.{ .data = @constCast(&[_]u8{}), .mime_type = @constCast("image/png"), .name = name }};
    const finished = [_]journal.Finished{.{ .id = @constCast("call-1"), .failed = false, .output = @constCast("took it"), .images = &images }};

    try keepNeededImages(alloc, &resolver, &.{}, null, null, &finished, .{ .max_images = 1 });
    try std.testing.expectEqual(@as(usize, 1), resolver.missing.count());
    try std.testing.expectEqual(@as(?usize, 13), resolver.missing.get(name));
}

test "an open needs only the named images its window keeps, and every image of the open turn" {
    const alloc = std.testing.allocator;
    var staged: session_codec.StagedImages = .{};
    defer staged.deinit(alloc);
    var resolver: session_codec.ImageResolver = .{ .alloc = alloc, .staged = &staged };
    defer resolver.deinit();
    // Four named images the host has not staged yet, oldest first.
    var names: [4]session_codec.ImageName = undefined;
    var images: [4]types.ImageAttachment = undefined;
    for (&names, &images, 0..) |*name, *image, index| {
        name.* = session_codec.imageNameOf(&.{@as(u8, @intCast(index))});
        image.* = .{ .id = index + 1, .path = @constCast("inline://image"), .media_type = @constCast("image/png"), .snapshot_sha256 = name };
    }
    const reset = struct {
        fn run(target: *session_codec.ImageResolver, all: []const session_codec.ImageName) !void {
            target.missing.clearRetainingCapacity();
            for (all) |name| try target.missing.put(target.alloc, name, 10);
        }
    }.run;
    var history: [3]types.HistoryTurn = undefined;
    for (&history, images[0..3]) |*turn, *image| {
        turn.* = .{ .assistant = .{ .user = .{ .text = @constCast("look"), .images = image[0..1] }, .assistant = @constCast("ok") } };
    }

    // The window counts the history alone: its two newest, and the open
    // turn's image as well.
    try reset(&resolver, &names);
    try keepNeededImages(alloc, &resolver, &history, .{ .text = @constCast("now"), .images = images[3..4] }, null, &.{}, .{ .max_images = 2 });
    try std.testing.expectEqual(@as(usize, 3), resolver.missing.count());
    try std.testing.expect(!resolver.missing.contains(names[0]));

    // An open turn larger than the window keeps all of its images.
    try reset(&resolver, &names);
    try keepNeededImages(alloc, &resolver, history[0..2], .{ .text = @constCast("now"), .images = images[2..4] }, null, &.{}, .{ .max_images = 1 });
    try std.testing.expectEqual(@as(usize, 3), resolver.missing.count());
    try std.testing.expect(!resolver.missing.contains(names[0]));
}
