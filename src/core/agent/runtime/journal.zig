//! The libfx journal: one session as the ordered events a host stores.
//!
//! A host passes a `persistence` store to `createFxEngine`; fx appends an
//! event for each state change and rebuilds the session from the stored
//! events. This file
//! only encodes and folds events. Sending them is the ACP layer's job.
//!
//! Each event is one JSON object:
//!
//!   {"v":1,"seq":N,"turn":T,"type":"...","data":...}
//!
//! `seq` counts from 1 with no gaps. `turn` is the turn the event belongs to:
//! one more than the number of turns committed before it. `data` uses the
//! session codecs fx already persists, so its shape is fx's to change.
//!
//! - `turn_committed`: a finished turn, as one history entry
//! - `turn_progress`: the open turn so far, before each model request
//! - `tool_intent`: the tool calls about to run, before any of them starts
//! - `turn_progress_cleared`: the open turn ended without a history entry
//! - `history_replaced`: the whole history, after compaction
//! - `input_accepted`: a steer or follow-up the host handed in, before the
//!   model sees it
//! - `input_withdrawn`: a steer the host took back before it was placed, or
//!   a follow-up whose turn ended before its first progress
//! - `turn_yielded`: the open turn stopped before its next model request at
//!   the time the host gave it, to continue later without being told it was
//!   interrupted
//!
//! A `turn_progress` event lists the inputs its model request carries for
//! the first time in `inputs`, so placement is stored with the text it
//! places, and names the model the request goes to in `model`. A turn's
//! first progress carries the host's id for the turn in `turnId`. A steer
//! belongs to the turn it arrives in; a follow-up waits for the turn that
//! runs it.
const std = @import("std");
const types = @import("../../shared/types.zig");
const testing_allocator = @import("../../shared/testing_allocator.zig");
const session_codec = @import("../../session/session_codec.zig");
const checkpoint_codec = @import("checkpoint.zig");
const compactor = @import("../../compactor/compactor.zig");

const Allocator = std.mem.Allocator;

pub const version: u8 = 1;
/// The most event bytes one load accepts, and the most bytes one snapshot
/// holds: each travels as one host attachment, and an attachment holds at
/// most one kernel checkpoint. Longer sessions need snapshots.
pub const max_load_bytes: usize = checkpoint_codec.max_checkpoint_bytes;
pub const max_snapshot_bytes: usize = checkpoint_codec.max_checkpoint_bytes;
/// The largest `seq` or turn a host can carry: hosts in JavaScript hold them
/// as numbers.
const max_safe_position: u64 = (1 << 53) - 1;
pub const max_history_turns = checkpoint_codec.max_history_turns;

const EventType = enum {
    turn_committed,
    turn_progress,
    tool_intent,
    turn_progress_cleared,
    history_replaced,
    input_accepted,
    input_withdrawn,
    turn_yielded,
};

const InputKind = enum { steer, follow_up };

/// A steer or follow-up the host handed in.
pub const Input = struct {
    id: []const u8,
    text: []const u8,
    kind: InputKind = .steer,
};

/// The open turn so far, before a model request, the inputs that request
/// carries for the first time, and the model it goes to.
pub const Progress = struct {
    checkpoint: session_codec.RecoveryCheckpoint,
    placed: []const []const u8 = &.{},
    model: ?[]const u8 = null,
    /// The host's id for the turn, on the turn's first progress only.
    turn_id: ?[]const u8 = null,
};

/// The longest turn id a host may give.
pub const max_turn_id_bytes = 128;

/// Borrows its payload only for `Cursor.write`.
pub const Event = union(EventType) {
    turn_committed: types.HistoryTurn,
    turn_progress: Progress,
    tool_intent: []const types.ToolCall,
    turn_progress_cleared,
    history_replaced: []const types.HistoryTurn,
    input_accepted: Input,
    /// The withdrawn input's id.
    input_withdrawn: []const u8,
    turn_yielded,
};

/// An input the open turn accepted and has not placed or withdrawn.
pub const PendingInput = struct {
    id: []u8,
    text: []u8,
};

/// Where the next event goes. A copy advances only when its caller stores
/// the cursor `write` returns, so an event that fails to send leaves no gap.
pub const Cursor = struct {
    next_seq: u64 = 1,
    turn: u64 = 1,

    /// Writes `event` as one JSON object and returns the cursor after it.
    pub fn write(self: Cursor, writer: *std.Io.Writer, event: Event) !Cursor {
        try writer.print("{{\"v\":{d},\"seq\":{d},\"turn\":{d},\"type\":\"{s}\"", .{
            version,
            self.next_seq,
            self.turn,
            @tagName(event),
        });
        switch (event) {
            .turn_committed => |turn| {
                try writer.writeAll(",\"data\":");
                try session_codec.writeHistoryTurn(writer, turn);
            },
            .turn_progress => |progress| {
                try writer.writeAll(",\"data\":");
                try session_codec.writeRecoveryCheckpoint(writer, progress.checkpoint);
                if (progress.placed.len > 0) {
                    try writer.writeAll(",\"inputs\":");
                    try std.json.Stringify.value(progress.placed, .{}, writer);
                }
                if (progress.model) |model| {
                    try writer.writeAll(",\"model\":");
                    try std.json.Stringify.value(model, .{}, writer);
                }
                if (progress.turn_id) |id| {
                    try writer.writeAll(",\"turnId\":");
                    try std.json.Stringify.value(id, .{}, writer);
                }
            },
            .tool_intent => |calls| {
                try writer.writeAll(",\"data\":");
                try session_codec.writeToolCalls(writer, calls);
            },
            .turn_progress_cleared => {},
            .history_replaced => |history| {
                if (history.len > max_history_turns) return error.JournalTooLarge;
                try writer.writeAll(",\"data\":[");
                for (history, 0..) |turn, index| {
                    if (index > 0) try writer.writeByte(',');
                    try session_codec.writeHistoryTurn(writer, turn);
                }
                try writer.writeByte(']');
            },
            .input_accepted => |input| {
                try writer.writeAll(",\"data\":");
                try std.json.Stringify.value(.{ .id = input.id, .kind = @tagName(input.kind), .text = input.text }, .{}, writer);
            },
            .input_withdrawn => |id| {
                try writer.writeAll(",\"data\":");
                try std.json.Stringify.value(.{ .id = id }, .{}, writer);
            },
            .turn_yielded => {},
        }
        try writer.writeByte('}');
        return .{
            .next_seq = self.next_seq + 1,
            .turn = if (event == .turn_committed) self.turn + 1 else self.turn,
        };
    }
};

/// A snapshot of a quiet prefix: `FXSN`, a version byte, the last `seq` it
/// covers and the turn after it (each a little-endian u64), the id of the
/// last turn (a length byte, zero for none, then its bytes), then a
/// checkpoint of the history. Version 2, a snapshot taken where a turn
/// yielded, adds the open turn before the checkpoint: a little-endian u32
/// length, then the JSON `writeOpenTurn` writes. A quiet snapshot stays
/// version 1, so an fx that reads only version 1 still loads it. Hosts store
/// it as opaque bytes.
const snapshot_magic = "FXSN";
const snapshot_version_quiet: u8 = 1;
const snapshot_version: u8 = 2;
const snapshot_header_bytes = snapshot_magic.len + 1 + 8 + 8 + 1;

pub const Snapshot = struct {
    /// The last event the snapshot covers; the tail starts after it.
    seq: u64,
    turn: u64,
    /// The last turn's id. Borrowed from the snapshot bytes.
    last_turn_id: ?[]const u8,
    /// The turn that yielded, as `writeOpenTurn` wrote it, or null for a
    /// quiet prefix. Borrowed from the snapshot bytes.
    open_turn: ?[]const u8 = null,
    /// Borrowed from the snapshot bytes.
    checkpoint: []const u8,
};

/// Returns caller-owned snapshot bytes for a checkpoint taken after `seq`,
/// with `open_turn` from `writeOpenTurn` when a turn yielded there.
/// `last_turn_id` is at most `max_turn_id_bytes` long.
pub fn encodeSnapshot(
    alloc: Allocator,
    seq: u64,
    turn: u64,
    last_turn_id: ?[]const u8,
    open_turn: ?[]const u8,
    checkpoint: []const u8,
) error{ OutOfMemory, SnapshotTooLarge }![]u8 {
    const id = last_turn_id orelse "";
    std.debug.assert(id.len <= max_turn_id_bytes);
    const open_bytes: usize = if (open_turn) |open| 4 + open.len else 0;
    if (open_turn) |open| if (open.len > std.math.maxInt(u32)) return error.SnapshotTooLarge;
    const bytes = try alloc.alloc(u8, snapshot_header_bytes + id.len + open_bytes + checkpoint.len);
    @memcpy(bytes[0..snapshot_magic.len], snapshot_magic);
    bytes[snapshot_magic.len] = if (open_turn == null) snapshot_version_quiet else snapshot_version;
    std.mem.writeInt(u64, bytes[snapshot_magic.len + 1 ..][0..8], seq, .little);
    std.mem.writeInt(u64, bytes[snapshot_magic.len + 9 ..][0..8], turn, .little);
    bytes[snapshot_header_bytes - 1] = @intCast(id.len);
    @memcpy(bytes[snapshot_header_bytes..][0..id.len], id);
    var at = snapshot_header_bytes + id.len;
    if (open_turn) |open| {
        std.mem.writeInt(u32, bytes[at..][0..4], @intCast(open.len), .little);
        @memcpy(bytes[at + 4 ..][0..open.len], open);
        at += open_bytes;
    }
    @memcpy(bytes[at..], checkpoint);
    return bytes;
}

pub fn parseSnapshot(bytes: []const u8) LoadError!Snapshot {
    if (bytes.len < snapshot_header_bytes or !std.mem.eql(u8, bytes[0..snapshot_magic.len], snapshot_magic)) {
        return error.InvalidJournal;
    }
    const found_version = bytes[snapshot_magic.len];
    if (found_version > snapshot_version) return error.UnsupportedJournalVersion;
    if (found_version != snapshot_version and found_version != snapshot_version_quiet) return error.InvalidJournal;
    const seq = std.mem.readInt(u64, bytes[snapshot_magic.len + 1 ..][0..8], .little);
    const turn = std.mem.readInt(u64, bytes[snapshot_magic.len + 9 ..][0..8], .little);
    if (seq == 0 or turn == 0 or seq > max_safe_position or turn > max_safe_position) return error.InvalidJournal;
    const id_len = bytes[snapshot_header_bytes - 1];
    if (id_len > max_turn_id_bytes or bytes.len - snapshot_header_bytes < id_len) return error.InvalidJournal;
    var at: usize = snapshot_header_bytes + id_len;
    var open_turn: ?[]const u8 = null;
    if (found_version == snapshot_version) {
        if (bytes.len - at < 4) return error.InvalidJournal;
        const open_len = std.mem.readInt(u32, bytes[at..][0..4], .little);
        at += 4;
        if (open_len == 0 or bytes.len - at < open_len) return error.InvalidJournal;
        open_turn = bytes[at..][0..open_len];
        at += open_len;
    }
    return .{
        .seq = seq,
        .turn = turn,
        .last_turn_id = if (id_len == 0) null else bytes[snapshot_header_bytes..][0..id_len],
        .open_turn = open_turn,
        .checkpoint = bytes[at..],
    };
}

/// Writes the turn that yielded, for a version 2 snapshot: its id, when the
/// host gave one, and its progress as a `turn_progress` carries it.
pub fn writeOpenTurn(writer: *std.Io.Writer, turn_id: ?[]const u8, progress: session_codec.RecoveryCheckpoint) !void {
    try writer.writeByte('{');
    if (turn_id) |id| {
        std.debug.assert(id.len > 0 and id.len <= max_turn_id_bytes);
        try writer.writeAll("\"turnId\":");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.writeByte(',');
    }
    try writer.writeAll("\"progress\":");
    try session_codec.writeRecoveryCheckpoint(writer, progress);
    try writer.writeByte('}');
}

pub const LoadError = Allocator.Error || error{
    /// An event is not the shape this version writes.
    InvalidJournal,
    /// An event was written by a newer fx.
    UnsupportedJournalVersion,
    /// A `seq` or `turn` is missing, repeated, or out of order.
    OutOfOrderJournalEvent,
    /// The events are more than one load holds.
    JournalTooLarge,
    /// The history is longer than a session restores.
    JournalTooManyTurns,
};

/// A session rebuilt from its events. Owns every slice.
pub const Folded = struct {
    history: []types.HistoryTurn,
    /// The turn a crash left open: progress with no commit or clear after it.
    open_turn: ?session_codec.RecoveryCheckpoint,
    /// Calls the open turn announced that have no recorded result. Some may
    /// have started.
    running_calls: []types.ToolCall = &.{},
    /// Steers the open turn accepted and has not placed or withdrawn, in the
    /// order they arrived.
    pending_inputs: []PendingInput = &.{},
    /// Follow-ups no turn has run yet, in the order they arrived.
    pending_follow_ups: []PendingInput = &.{},
    /// The host's id for the open turn, when it gave one.
    open_turn_id: ?[]u8 = null,
    /// The host's id for the last turn that ended, when it gave one.
    last_turn_id: ?[]u8 = null,
    /// The open turn stopped at the time the host gave it, with nothing
    /// after: it continues without being told it was interrupted.
    yielded: bool = false,
    cursor: Cursor,

    pub fn deinit(self: *Folded, alloc: Allocator) void {
        types.freeHistoryTurnSlice(alloc, self.history);
        if (self.open_turn) |*checkpoint| checkpoint.deinit(alloc);
        types.freeToolCallSlice(alloc, self.running_calls);
        freePendingInputs(alloc, self.pending_inputs);
        freePendingInputs(alloc, self.pending_follow_ups);
        if (self.open_turn_id) |id| alloc.free(id);
        if (self.last_turn_id) |id| alloc.free(id);
        self.* = undefined;
    }
};

pub fn freePendingInputs(alloc: Allocator, inputs: []PendingInput) void {
    for (inputs) |input| {
        alloc.free(input.id);
        alloc.free(input.text);
    }
    alloc.free(inputs);
}

/// The current turn's inputs as the fold sees them. Borrows from the parse.
const InputState = struct {
    id: []const u8,
    text: []const u8,
    kind: InputKind,
    placed: bool = false,
    withdrawn: bool = false,

    fn pending(self: InputState, kind: InputKind) bool {
        return self.kind == kind and !self.placed and !self.withdrawn;
    }
};

/// At a turn's end its steers are gone; follow-ups still waiting stay.
fn endTurnInputs(inputs: *std.ArrayList(InputState)) void {
    var kept: usize = 0;
    for (inputs.items) |input| {
        if (!input.pending(.follow_up)) continue;
        inputs.items[kept] = input;
        kept += 1;
    }
    inputs.shrinkRetainingCapacity(kept);
}

fn findInput(inputs: []InputState, id: []const u8) ?*InputState {
    for (inputs) |*input| if (std.mem.eql(u8, input.id, id)) return input;
    return null;
}

fn stringField(value: std.json.Value, name: []const u8) LoadError![]const u8 {
    if (value != .object) return error.InvalidJournal;
    const field = value.object.get(name) orelse return error.InvalidJournal;
    if (field != .string or field.string.len == 0) return error.InvalidJournal;
    return field.string;
}

/// Where a fold starts: an empty session, or a snapshot and the cursor after
/// it. A snapshot has no follow-up waiting; it is a quiet prefix, or a turn
/// that yielded with no input waiting for it.
pub const Base = struct {
    history: []const types.HistoryTurn = &.{},
    cursor: Cursor = .{},
    /// The id of the prefix's last turn.
    last_turn_id: ?[]const u8 = null,
    /// The turn that yielded, as `writeOpenTurn` wrote it.
    open_turn: ?[]const u8 = null,
};

/// Rebuilds a session from `events_json`, a JSON array of events in order.
pub fn fold(alloc: Allocator, events_json: []const u8) LoadError!Folded {
    return foldFrom(alloc, events_json, .{});
}

/// Rebuilds a session from `base` and the events after it.
pub fn foldFrom(alloc: Allocator, events_json: []const u8, base: Base) LoadError!Folded {
    if (events_json.len > max_load_bytes) return error.JournalTooLarge;
    if (base.history.len > max_history_turns) return error.JournalTooManyTurns;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), events_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJournal,
    };
    if (parsed != .array) return error.InvalidJournal;

    var history: std.ArrayList(types.HistoryTurn) = .empty;
    defer {
        for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
        history.deinit(alloc);
    }
    try history.ensureTotalCapacity(alloc, base.history.len);
    for (base.history) |turn| history.appendAssumeCapacity(try types.dupeHistoryTurn(alloc, turn));
    var open: ?std.json.Value = null;
    // The open turn's announced calls; the ones its progress answers are
    // dropped at the end.
    var running: std.ArrayList(std.json.Value) = .empty;
    defer running.deinit(alloc);
    var inputs: std.ArrayList(InputState) = .empty;
    defer inputs.deinit(alloc);
    var open_id: ?[]const u8 = null;
    var last_id: ?[]const u8 = base.last_turn_id;
    var yielded = false;
    var cursor = base.cursor;
    if (base.open_turn) |text| {
        // The snapshot's turn stays open and yielded until the events after
        // it say otherwise.
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidJournal,
        };
        if (value != .object) return error.InvalidJournal;
        const progress = value.object.get("progress") orelse return error.InvalidJournal;
        if (progress != .object) return error.InvalidJournal;
        open = progress;
        open_id = try turnIdOf(value.object.get("turnId"));
        yielded = true;
    }
    for (parsed.array.items) |value| {
        const event = try envelope(value, cursor);
        // A yield stands only until the turn does anything more.
        if (event.kind != .turn_yielded) yielded = false;
        switch (event.kind) {
            .turn_committed => {
                const turn = try parseTurn(alloc, event.data orelse return error.InvalidJournal);
                // The same rule the session applies when it commits the turn.
                if (replacesHistory(turn)) {
                    for (history.items) |old| types.freeHistoryTurn(alloc, old);
                    history.clearRetainingCapacity();
                }
                history.append(alloc, turn) catch |err| {
                    types.freeHistoryTurn(alloc, turn);
                    return err;
                };
                open = null;
                last_id = open_id;
                open_id = null;
                running.clearRetainingCapacity();
                endTurnInputs(&inputs);
            },
            .turn_progress => {
                // A host may leave out a superseded progress's state as
                // `null`: a later progress in the turn, or its end, replaces it.
                const data = event.data orelse return error.InvalidJournal;
                if (data != .object and data != .null) return error.InvalidJournal;
                // A turn's first progress names it.
                if (open == null) open_id = try turnIdOf(event.turn_id);
                open = data;
                // Each placed input was accepted in this turn and is placed once.
                if (event.inputs) |placed| {
                    if (placed != .array) return error.InvalidJournal;
                    for (placed.array.items) |id| {
                        if (id != .string) return error.InvalidJournal;
                        const input = findInput(inputs.items, id.string) orelse return error.InvalidJournal;
                        if (input.placed or input.withdrawn) return error.InvalidJournal;
                        input.placed = true;
                    }
                }
            },
            .tool_intent => {
                const data = event.data orelse return error.InvalidJournal;
                if (data != .array or data.array.items.len == 0) return error.InvalidJournal;
                // An intent belongs to an open turn.
                if (open == null) return error.InvalidJournal;
                try running.appendSlice(alloc, data.array.items);
            },
            .turn_progress_cleared => {
                if (event.data != null) return error.InvalidJournal;
                open = null;
                last_id = open_id;
                open_id = null;
                running.clearRetainingCapacity();
                endTurnInputs(&inputs);
            },
            .input_accepted => {
                const data = event.data orelse return error.InvalidJournal;
                const id = try stringField(data, "id");
                const text = try stringField(data, "text");
                const kind: InputKind = if (data.object.get("kind")) |kind_value| parsed_kind: {
                    if (kind_value != .string) return error.InvalidJournal;
                    break :parsed_kind std.meta.stringToEnum(InputKind, kind_value.string) orelse return error.InvalidJournal;
                } else .steer;
                if (findInput(inputs.items, id) != null) return error.InvalidJournal;
                try inputs.append(alloc, .{ .id = id, .text = text, .kind = kind });
            },
            .input_withdrawn => {
                const data = event.data orelse return error.InvalidJournal;
                const input = findInput(inputs.items, try stringField(data, "id")) orelse return error.InvalidJournal;
                if (input.placed or input.withdrawn) return error.InvalidJournal;
                input.withdrawn = true;
            },
            .turn_yielded => {
                if (event.data != null) return error.InvalidJournal;
                // Only an open turn yields.
                if (open == null) return error.InvalidJournal;
                yielded = true;
            },
            .history_replaced => {
                const data = event.data orelse return error.InvalidJournal;
                if (data != .array) return error.InvalidJournal;
                if (data.array.items.len > max_history_turns) return error.JournalTooManyTurns;
                var replacement: std.ArrayList(types.HistoryTurn) = .empty;
                errdefer {
                    for (replacement.items) |turn| types.freeHistoryTurn(alloc, turn);
                    replacement.deinit(alloc);
                }
                try replacement.ensureTotalCapacity(alloc, data.array.items.len);
                for (data.array.items) |item| replacement.appendAssumeCapacity(try parseTurn(alloc, item));
                for (history.items) |turn| types.freeHistoryTurn(alloc, turn);
                history.deinit(alloc);
                history = replacement;
            },
        }
        if (history.items.len > max_history_turns) return error.JournalTooManyTurns;
        cursor = .{
            .next_seq = cursor.next_seq + 1,
            .turn = if (event.kind == .turn_committed) cursor.turn + 1 else cursor.turn,
        };
    }

    var open_turn: ?session_codec.RecoveryCheckpoint = null;
    if (open) |data| open_turn = if (data == .null) return error.InvalidJournal else session_codec.parseRecoveryCheckpoint(alloc, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJournal,
    };
    errdefer if (open_turn) |*checkpoint| checkpoint.deinit(alloc);
    const announced = session_codec.parseToolCalls(alloc, .{
        .array = std.json.Array.fromOwnedSlice(alloc, running.items),
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJournal,
    };
    const execution: types.ExecutionMemory = if (open_turn) |checkpoint| checkpoint.execution else .{};
    const unanswered = dropAnswered(alloc, announced, execution) catch |err| {
        types.freeToolCallSlice(alloc, announced);
        return err;
    };
    errdefer types.freeToolCallSlice(alloc, unanswered);
    const pending = try pendingInputsOf(alloc, if (open_turn != null) inputs.items else &.{}, .steer);
    errdefer freePendingInputs(alloc, pending);
    const follow_ups = try pendingInputsOf(alloc, inputs.items, .follow_up);
    errdefer freePendingInputs(alloc, follow_ups);
    const open_turn_id = if (open_id) |id| try alloc.dupe(u8, id) else null;
    errdefer if (open_turn_id) |id| alloc.free(id);
    const last_turn_id = if (last_id) |id| try alloc.dupe(u8, id) else null;
    errdefer if (last_turn_id) |id| alloc.free(id);
    const owned = try history.toOwnedSlice(alloc);
    return .{
        .history = owned,
        .open_turn = open_turn,
        .running_calls = unanswered,
        .pending_inputs = pending,
        .pending_follow_ups = follow_ups,
        .open_turn_id = open_turn_id,
        .last_turn_id = last_turn_id,
        .yielded = yielded and open_turn != null,
        .cursor = cursor,
    };
}

/// Owned copies of the `kind` inputs neither placed nor withdrawn.
fn pendingInputsOf(alloc: Allocator, inputs: []const InputState, kind: InputKind) Allocator.Error![]PendingInput {
    var count: usize = 0;
    for (inputs) |input| {
        if (input.pending(kind)) count += 1;
    }
    const pending = try alloc.alloc(PendingInput, count);
    var filled: usize = 0;
    errdefer {
        for (pending[0..filled]) |input| {
            alloc.free(input.id);
            alloc.free(input.text);
        }
        alloc.free(pending);
    }
    for (inputs) |input| {
        if (!input.pending(kind)) continue;
        const id = try alloc.dupe(u8, input.id);
        errdefer alloc.free(id);
        pending[filled] = .{ .id = id, .text = try alloc.dupe(u8, input.text) };
        filled += 1;
    }
    return pending;
}

/// Returns the calls in `calls` with no result in `execution`, each id once,
/// in announcement order. On success it takes `calls`, freeing the rest and
/// the slice; on failure the caller still owns `calls`.
fn dropAnswered(alloc: Allocator, calls: []types.ToolCall, execution: types.ExecutionMemory) Allocator.Error![]types.ToolCall {
    var count: usize = 0;
    for (calls, 0..) |_, index| {
        if (keepCall(calls, index, execution)) count += 1;
    }
    const kept = try alloc.alloc(types.ToolCall, count);
    var next: usize = 0;
    for (calls, 0..) |call, index| {
        if (!keepCall(calls, index, execution)) continue;
        kept[next] = call;
        next += 1;
    }
    // Each decision reads only earlier calls, so freeing from the end keeps
    // every call a later decision reads alive.
    var index = calls.len;
    while (index > 0) {
        index -= 1;
        if (!keepCall(calls, index, execution)) types.freeToolCall(alloc, calls[index]);
    }
    alloc.free(calls);
    return kept;
}

fn keepCall(calls: []const types.ToolCall, index: usize, execution: types.ExecutionMemory) bool {
    for (calls[0..index]) |prior| if (std.mem.eql(u8, prior.id, calls[index].id)) return false;
    return !hasResult(execution, calls[index].id);
}

fn hasResult(execution: types.ExecutionMemory, call_id: []const u8) bool {
    for (execution.tool_steps) |step| {
        for (step.tool_results) |result| if (std.mem.eql(u8, result.tool_call_id, call_id)) return true;
    }
    return false;
}

const Envelope = struct {
    kind: EventType,
    data: ?std.json.Value,
    /// The inputs a `turn_progress` places.
    inputs: ?std.json.Value,
    /// The host's id for the turn a first `turn_progress` starts.
    turn_id: ?std.json.Value,
};

/// Checks one event's envelope against the cursor it must continue.
fn envelope(value: std.json.Value, cursor: Cursor) LoadError!Envelope {
    if (value != .object) return error.InvalidJournal;
    const object = value.object;
    const event_version = try integerField(object, "v");
    if (event_version > version) return error.UnsupportedJournalVersion;
    if (event_version != version) return error.InvalidJournal;
    if (try integerField(object, "seq") != cursor.next_seq) return error.OutOfOrderJournalEvent;
    if (try integerField(object, "turn") != cursor.turn) return error.OutOfOrderJournalEvent;
    const kind_value = object.get("type") orelse return error.InvalidJournal;
    if (kind_value != .string) return error.InvalidJournal;
    const kind = std.meta.stringToEnum(EventType, kind_value.string) orelse return error.InvalidJournal;
    return .{ .kind = kind, .data = object.get("data"), .inputs = object.get("inputs"), .turn_id = object.get("turnId") };
}

/// A progress's `turnId`, if it has one. Borrows from the parse.
fn turnIdOf(value: ?std.json.Value) LoadError!?[]const u8 {
    const id = value orelse return null;
    if (id != .string or id.string.len == 0 or id.string.len > max_turn_id_bytes) return error.InvalidJournal;
    return id.string;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) LoadError!u64 {
    const value = object.get(name) orelse return error.InvalidJournal;
    if (value != .integer or value.integer < 0) return error.InvalidJournal;
    return @intCast(value.integer);
}

/// A current compaction summary stands for every turn before it.
fn replacesHistory(turn: types.HistoryTurn) bool {
    return switch (turn) {
        .compacted_summary => |entry| compactor.replacesPriorContext(entry.summary),
        else => false,
    };
}

fn parseTurn(alloc: Allocator, value: std.json.Value) LoadError!types.HistoryTurn {
    return session_codec.parseHistoryTurn(alloc, value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJournal,
    };
}

fn testTurn(alloc: Allocator, prompt: []const u8, answer: []const u8) !types.HistoryTurn {
    return .{ .assistant = .{
        .user = .{ .text = try alloc.dupe(u8, prompt) },
        .assistant = try alloc.dupe(u8, answer),
    } };
}

fn testProgress(alloc: Allocator, prompt: []const u8) !session_codec.RecoveryCheckpoint {
    return .{
        .turn_id = 7,
        .user = .{ .text = try alloc.dupe(u8, prompt) },
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

/// Writes `events` as a journal array, the way a host hands them back.
fn testJournal(alloc: Allocator, events: []const Event) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var cursor: Cursor = .{};
    try out.writer.writeByte('[');
    for (events, 0..) |event, index| {
        if (index > 0) try out.writer.writeByte(',');
        cursor = try cursor.write(&out.writer, event);
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}

test "a journal folds back into the history it recorded" {
    const alloc = std.testing.allocator;
    const first = try testTurn(alloc, "list files", "two files");
    defer types.freeHistoryTurn(alloc, first);
    const second = try testTurn(alloc, "read one", "it says hi");
    defer types.freeHistoryTurn(alloc, second);
    var progress = try testProgress(alloc, "read one");
    defer progress.deinit(alloc);

    const bytes = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = progress } },
        .{ .turn_committed = first },
        .{ .turn_progress = .{ .checkpoint = progress } },
        .{ .turn_committed = second },
    });
    defer alloc.free(bytes);

    var folded = try fold(alloc, bytes);
    defer folded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), folded.history.len);
    try std.testing.expectEqualStrings("list files", folded.history[0].assistant.user.text);
    try std.testing.expectEqualStrings("it says hi", folded.history[1].assistant.assistant);
    try std.testing.expect(folded.open_turn == null);
    try std.testing.expectEqual(Cursor{ .next_seq = 5, .turn = 3 }, folded.cursor);
}

test "progress after the last commit is the turn a crash left open" {
    const alloc = std.testing.allocator;
    const first = try testTurn(alloc, "hello", "hi");
    defer types.freeHistoryTurn(alloc, first);
    var progress = try testProgress(alloc, "send the email");
    defer progress.deinit(alloc);

    const open_bytes = try testJournal(alloc, &.{ .{ .turn_committed = first }, .{ .turn_progress = .{ .checkpoint = progress } } });
    defer alloc.free(open_bytes);
    var open = try fold(alloc, open_bytes);
    defer open.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), open.history.len);
    try std.testing.expectEqualStrings("send the email", open.open_turn.?.user.text);
    try std.testing.expectEqual(Cursor{ .next_seq = 3, .turn = 2 }, open.cursor);

    // A clear means the turn ended on purpose, so nothing is left to resume.
    const cleared_bytes = try testJournal(alloc, &.{ .{ .turn_committed = first }, .{ .turn_progress = .{ .checkpoint = progress } }, .turn_progress_cleared });
    defer alloc.free(cleared_bytes);
    var cleared = try fold(alloc, cleared_bytes);
    defer cleared.deinit(alloc);
    try std.testing.expect(cleared.open_turn == null);
    try std.testing.expectEqual(Cursor{ .next_seq = 4, .turn = 2 }, cleared.cursor);
}

test "compaction replaces the folded history" {
    const alloc = std.testing.allocator;
    const old = try testTurn(alloc, "old", "old answer");
    defer types.freeHistoryTurn(alloc, old);
    const kept = try testTurn(alloc, "kept", "kept answer");
    defer types.freeHistoryTurn(alloc, kept);

    const bytes = try testJournal(alloc, &.{
        .{ .turn_committed = old },
        .{ .turn_committed = kept },
        .{ .history_replaced = &.{kept} },
    });
    defer alloc.free(bytes);
    var folded = try fold(alloc, bytes);
    defer folded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), folded.history.len);
    try std.testing.expectEqualStrings("kept", folded.history[0].assistant.user.text);
    try std.testing.expectEqual(Cursor{ .next_seq = 4, .turn = 3 }, folded.cursor);
}

test "compaction during a turn leaves the turn open" {
    const alloc = std.testing.allocator;
    const kept = try testTurn(alloc, "kept", "kept answer");
    defer types.freeHistoryTurn(alloc, kept);
    var progress = try testProgress(alloc, "long task");
    defer progress.deinit(alloc);

    const open_bytes = try testJournal(alloc, &.{ .{ .turn_progress = .{ .checkpoint = progress } }, .{ .history_replaced = &.{kept} } });
    defer alloc.free(open_bytes);
    var open = try fold(alloc, open_bytes);
    defer open.deinit(alloc);
    try std.testing.expectEqualStrings("long task", open.open_turn.?.user.text);

    // Only a commit or a clear ends it.
    const cleared_bytes = try testJournal(alloc, &.{ .{ .turn_progress = .{ .checkpoint = progress } }, .{ .history_replaced = &.{kept} }, .turn_progress_cleared });
    defer alloc.free(cleared_bytes);
    var cleared = try fold(alloc, cleared_bytes);
    defer cleared.deinit(alloc);
    try std.testing.expect(cleared.open_turn == null);
}

test "a committed compaction summary replaces the turns before it" {
    const alloc = std.testing.allocator;
    const old = try testTurn(alloc, "old", "old answer");
    defer types.freeHistoryTurn(alloc, old);
    const summary: types.HistoryTurn = .{ .compacted_summary = .{
        .summary = try alloc.dupe(u8, "<context_handoff>\n## Conversation summary\n> earlier\n</context_handoff>"),
        .removed_turn_count = 1,
        .compaction_count = 1,
    } };
    defer types.freeHistoryTurn(alloc, summary);
    const next = try testTurn(alloc, "next", "next answer");
    defer types.freeHistoryTurn(alloc, next);

    const bytes = try testJournal(alloc, &.{
        .{ .turn_committed = old },
        .{ .turn_committed = summary },
        .{ .turn_committed = next },
    });
    defer alloc.free(bytes);
    var folded = try fold(alloc, bytes);
    defer folded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), folded.history.len);
    try std.testing.expect(folded.history[0] == .compacted_summary);
    try std.testing.expectEqualStrings("next", folded.history[1].assistant.user.text);
}

test "announced calls without a result are what a crash left running" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc, "send two emails");
    defer progress.deinit(alloc);
    const calls = [_]types.ToolCall{
        .{ .id = "call-a", .name = "send_email", .arguments_json = "{}" },
        .{ .id = "call-b", .name = "send_email", .arguments_json = "{}" },
    };

    const bytes = try testJournal(alloc, &.{ .{ .turn_progress = .{ .checkpoint = progress } }, .{ .tool_intent = &calls } });
    defer alloc.free(bytes);
    var folded = try fold(alloc, bytes);
    defer folded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), folded.running_calls.len);
    try std.testing.expectEqualStrings("call-a", folded.running_calls[0].id);
    try std.testing.expectEqualStrings("send_email", folded.running_calls[1].name);
}

test "a call the open turn already answered is no longer running" {
    const alloc = std.testing.allocator;
    var before = try testProgress(alloc, "read then send");
    defer before.deinit(alloc);
    var after = try testProgress(alloc, "read then send");
    defer after.deinit(alloc);
    const read_calls = [_]types.ToolCall{.{ .id = "call-read", .name = "read_file", .arguments_json = "{}" }};
    const send_calls = [_]types.ToolCall{.{ .id = "call-send", .name = "send_email", .arguments_json = "{}" }};
    // Progress before the second request holds the read's result.
    const results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-read"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("contents"),
        .output_bytes = 8,
        .stored_output_bytes = 8,
    }};
    const steps = [_]types.ToolExecutionStep{.{
        .tool_calls = try types.dupeToolCallSlice(alloc, &read_calls),
        .tool_results = try types.dupePersistedToolResults(alloc, &results),
    }};
    after.execution.tool_steps = try alloc.dupe(types.ToolExecutionStep, &steps);

    const bytes = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = before } },
        .{ .tool_intent = &read_calls },
        .{ .tool_intent = &read_calls },
        .{ .turn_progress = .{ .checkpoint = after } },
        .{ .tool_intent = &send_calls },
    });
    defer alloc.free(bytes);
    var folded = try fold(alloc, bytes);
    defer folded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), folded.running_calls.len);
    try std.testing.expectEqualStrings("call-send", folded.running_calls[0].id);
}

test "a commit ends the turn's intents, and an intent needs an open turn" {
    const alloc = std.testing.allocator;
    const turn = try testTurn(alloc, "hello", "hi");
    defer types.freeHistoryTurn(alloc, turn);
    var progress = try testProgress(alloc, "hello");
    defer progress.deinit(alloc);
    const calls = [_]types.ToolCall{.{ .id = "call-a", .name = "lookup", .arguments_json = "{}" }};

    const committed = try testJournal(alloc, &.{ .{ .turn_progress = .{ .checkpoint = progress } }, .{ .tool_intent = &calls }, .{ .turn_committed = turn } });
    defer alloc.free(committed);
    var folded = try fold(alloc, committed);
    defer folded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), folded.running_calls.len);
    try std.testing.expect(folded.open_turn == null);

    const orphan = try testJournal(alloc, &.{.{ .tool_intent = &calls }});
    defer alloc.free(orphan);
    try std.testing.expectError(error.InvalidJournal, fold(alloc, orphan));
}

test "a yield stands until the open turn does anything more, and needs an open turn" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc, "long task");
    defer progress.deinit(alloc);
    const turn = try testTurn(alloc, "long task", "done");
    defer types.freeHistoryTurn(alloc, turn);

    const yielded = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = progress } },
        .turn_yielded,
    });
    defer alloc.free(yielded);
    var open = try fold(alloc, yielded);
    defer open.deinit(alloc);
    try std.testing.expect(open.open_turn != null);
    try std.testing.expect(open.yielded);

    // The resumed turn's next progress, or its end, supersedes the yield.
    const resumed = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = progress } },
        .turn_yielded,
        .{ .turn_progress = .{ .checkpoint = progress } },
    });
    defer alloc.free(resumed);
    var continued = try fold(alloc, resumed);
    defer continued.deinit(alloc);
    try std.testing.expect(continued.open_turn != null);
    try std.testing.expect(!continued.yielded);

    const ended = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = progress } },
        .turn_yielded,
        .{ .turn_committed = turn },
    });
    defer alloc.free(ended);
    var committed = try fold(alloc, ended);
    defer committed.deinit(alloc);
    try std.testing.expect(committed.open_turn == null);
    try std.testing.expect(!committed.yielded);

    const orphan = try testJournal(alloc, &.{.turn_yielded});
    defer alloc.free(orphan);
    try std.testing.expectError(error.InvalidJournal, fold(alloc, orphan));
}

test "an empty journal is a new session" {
    var folded = try fold(std.testing.allocator, "[]");
    defer folded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), folded.history.len);
    try std.testing.expectEqual(Cursor{}, folded.cursor);
}

test "a journal with a gap, a repeat, or a wrong turn is rejected" {
    const alloc = std.testing.allocator;
    const cases = [_][]const u8{
        // seq starts at 1
        \\[{"v":1,"seq":2,"turn":1,"type":"turn_progress_cleared"}]
        ,
        // a stored event repeated by a retried append
        \\[{"v":1,"seq":1,"turn":1,"type":"turn_progress_cleared"},{"v":1,"seq":1,"turn":1,"type":"turn_progress_cleared"}]
        ,
        // the turn number must follow commits
        \\[{"v":1,"seq":1,"turn":2,"type":"turn_progress_cleared"}]
        ,
    };
    for (cases) |bytes| try std.testing.expectError(error.OutOfOrderJournalEvent, fold(alloc, bytes));
}

test "a journal from a newer fx or with a malformed event is rejected" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.UnsupportedJournalVersion,
        fold(alloc, "[{\"v\":2,\"seq\":1,\"turn\":1,\"type\":\"turn_progress_cleared\"}]"),
    );
    const malformed = [_][]const u8{
        "{}",
        "[1]",
        "[{\"v\":1,\"seq\":1,\"turn\":1,\"type\":\"unknown\"}]",
        "[{\"v\":1,\"seq\":-1,\"turn\":1,\"type\":\"turn_progress_cleared\"}]",
        "[{\"v\":1,\"seq\":1,\"turn\":1,\"type\":\"turn_committed\"}]",
        "[{\"v\":1,\"seq\":1,\"turn\":1,\"type\":\"turn_committed\",\"data\":{\"kind\":\"nope\"}}]",
        "[{\"v\":1,\"seq\":1,\"turn\":1,\"type\":\"turn_progress\",\"data\":{}}]",
        "[{\"v\":1,\"seq\":1,\"turn\":1,\"type\":\"turn_progress_cleared\",\"data\":1}]",
        "[{\"v\":0,\"seq\":1,\"turn\":1,\"type\":\"turn_progress_cleared\"}]",
        "not json",
    };
    for (malformed) |bytes| try std.testing.expectError(error.InvalidJournal, fold(alloc, bytes));
}

test "a fold that runs out of memory frees what it built" {
    const alloc = std.testing.allocator;
    const first = try testTurn(alloc, "hello", "hi");
    defer types.freeHistoryTurn(alloc, first);
    var progress = try testProgress(alloc, "next");
    defer progress.deinit(alloc);
    const calls = [_]types.ToolCall{.{ .id = "call-a", .name = "lookup", .arguments_json = "{}" }};
    const bytes = try testJournal(alloc, &.{
        .{ .turn_committed = first },
        .{ .history_replaced = &.{first} },
        .{ .turn_progress = .{ .checkpoint = progress } },
        .{ .tool_intent = &calls },
    });
    defer alloc.free(bytes);
    try std.testing.checkAllAllocationFailures(testing_allocator.no_resize, foldAndFree, .{bytes});
}

fn foldAndFree(alloc: Allocator, bytes: []const u8) !void {
    var folded = try fold(alloc, bytes);
    folded.deinit(alloc);
}

test "an accepted steer stays pending until a progress places it" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc, "write it");
    defer progress.deinit(alloc);
    const one = Input{ .id = "in_1", .text = "use tabs" };
    const two = Input{ .id = "in_2", .text = "skip tests" };
    const three = Input{ .id = "in_3", .text = "be brief" };

    const accepted = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = progress } },
        .{ .input_accepted = one },
        .{ .input_accepted = two },
        .{ .input_accepted = three },
        .{ .input_withdrawn = "in_2" },
    });
    defer alloc.free(accepted);
    var folded = try fold(alloc, accepted);
    defer folded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), folded.pending_inputs.len);
    try std.testing.expectEqualStrings("in_1", folded.pending_inputs[0].id);
    try std.testing.expectEqualStrings("use tabs", folded.pending_inputs[0].text);
    try std.testing.expectEqualStrings("in_3", folded.pending_inputs[1].id);

    const placed = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = progress } },
        .{ .input_accepted = one },
        .{ .input_accepted = two },
        .{ .input_withdrawn = "in_2" },
        .{ .turn_progress = .{ .checkpoint = progress, .placed = &.{"in_1"} } },
        .{ .input_accepted = three },
    });
    defer alloc.free(placed);
    try std.testing.expect(std.mem.find(u8, placed, "\"inputs\":[\"in_1\"]") != null);
    var after = try fold(alloc, placed);
    defer after.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), after.pending_inputs.len);
    try std.testing.expectEqualStrings("in_3", after.pending_inputs[0].id);
}

test "a turn that ends drops the inputs it never placed" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc, "write it");
    defer progress.deinit(alloc);
    const turn = try testTurn(alloc, "write it", "done");
    defer types.freeHistoryTurn(alloc, turn);
    const steer = Input{ .id = "in_1", .text = "use tabs" };
    for ([_]Event{ .{ .turn_committed = turn }, .turn_progress_cleared }) |end| {
        const bytes = try testJournal(alloc, &.{ .{ .turn_progress = .{ .checkpoint = progress } }, .{ .input_accepted = steer }, end });
        defer alloc.free(bytes);
        var folded = try fold(alloc, bytes);
        defer folded.deinit(alloc);
        try std.testing.expect(folded.open_turn == null);
        try std.testing.expectEqual(@as(usize, 0), folded.pending_inputs.len);
    }
}

test "a journal that places or withdraws an input it never accepted is refused" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc, "write it");
    defer progress.deinit(alloc);
    const steer = Input{ .id = "in_1", .text = "use tabs" };
    const cases = [_][]const Event{
        &.{.{ .turn_progress = .{ .checkpoint = progress, .placed = &.{"in_9"} } }},
        &.{ .{ .turn_progress = .{ .checkpoint = progress } }, .{ .input_withdrawn = "in_9" } },
        &.{ .{ .input_accepted = steer }, .{ .input_accepted = steer } },
        &.{ .{ .input_accepted = steer }, .{ .turn_progress = .{ .checkpoint = progress, .placed = &.{"in_1"} } }, .{ .input_withdrawn = "in_1" } },
        &.{ .{ .input_accepted = steer }, .{ .turn_progress = .{ .checkpoint = progress, .placed = &.{"in_1"} } }, .{ .turn_progress = .{ .checkpoint = progress, .placed = &.{"in_1"} } } },
        &.{ .{ .input_accepted = steer }, .{ .input_withdrawn = "in_1" }, .{ .turn_progress = .{ .checkpoint = progress, .placed = &.{"in_1"} } } },
    };
    for (cases) |events| {
        const bytes = try testJournal(alloc, events);
        defer alloc.free(bytes);
        try std.testing.expectError(error.InvalidJournal, fold(alloc, bytes));
    }
}

test "a follow-up waits across turns until the turn that runs it places it" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc, "write it");
    defer progress.deinit(alloc);
    const turn = try testTurn(alloc, "write it", "done");
    defer types.freeHistoryTurn(alloc, turn);
    const later = Input{ .id = "in_1", .text = "then add tests", .kind = .follow_up };
    const steer = Input{ .id = "in_2", .text = "be brief" };

    const queued = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = progress } },
        .{ .input_accepted = later },
        .{ .input_accepted = steer },
        .{ .turn_committed = turn },
    });
    defer alloc.free(queued);
    try std.testing.expect(std.mem.find(u8, queued, "\"kind\":\"follow_up\"") != null);
    var waiting = try fold(alloc, queued);
    defer waiting.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), waiting.pending_inputs.len);
    try std.testing.expectEqual(@as(usize, 1), waiting.pending_follow_ups.len);
    try std.testing.expectEqualStrings("then add tests", waiting.pending_follow_ups[0].text);

    const ran = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = progress } },
        .{ .input_accepted = later },
        .{ .turn_committed = turn },
        .{ .turn_progress = .{ .checkpoint = progress, .placed = &.{"in_1"} } },
    });
    defer alloc.free(ran);
    var running = try fold(alloc, ran);
    defer running.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), running.pending_follow_ups.len);
}

test "a snapshot and the events after it fold into the same session as every event" {
    const alloc = std.testing.allocator;
    const first = try testTurn(alloc, "list files", "two files");
    defer types.freeHistoryTurn(alloc, first);
    const second = try testTurn(alloc, "read one", "it says hi");
    defer types.freeHistoryTurn(alloc, second);
    var progress = try testProgress(alloc, "read the other");
    defer progress.deinit(alloc);
    const events = [_]Event{
        .{ .turn_committed = first },
        .{ .turn_committed = second },
        .{ .turn_progress = .{ .checkpoint = progress } },
    };

    const full = try testJournal(alloc, &events);
    defer alloc.free(full);
    var replayed = try fold(alloc, full);
    defer replayed.deinit(alloc);

    // A snapshot after the first commit, then the tail from seq 2.
    const snapshot = try encodeSnapshot(alloc, 1, 2, null, null, "checkpoint-bytes");
    defer alloc.free(snapshot);
    const parsed = try parseSnapshot(snapshot);
    try std.testing.expectEqual(@as(u64, 1), parsed.seq);
    try std.testing.expectEqual(@as(u64, 2), parsed.turn);
    try std.testing.expect(parsed.last_turn_id == null);
    try std.testing.expectEqualStrings("checkpoint-bytes", parsed.checkpoint);
    var tail_out: std.Io.Writer.Allocating = .init(alloc);
    defer tail_out.deinit();
    var cursor: Cursor = .{ .next_seq = parsed.seq + 1, .turn = parsed.turn };
    try tail_out.writer.writeByte('[');
    for (events[1..], 0..) |event, index| {
        if (index > 0) try tail_out.writer.writeByte(',');
        cursor = try cursor.write(&tail_out.writer, event);
    }
    try tail_out.writer.writeByte(']');
    var resumed = try foldFrom(alloc, tail_out.written(), .{
        .history = &.{first},
        .cursor = .{ .next_seq = parsed.seq + 1, .turn = parsed.turn },
    });
    defer resumed.deinit(alloc);

    try std.testing.expectEqual(replayed.history.len, resumed.history.len);
    try std.testing.expectEqualStrings(replayed.history[1].assistant.assistant, resumed.history[1].assistant.assistant);
    try std.testing.expectEqual(replayed.cursor, resumed.cursor);
    try std.testing.expect(resumed.open_turn != null);
    try std.testing.expectEqualStrings("read the other", resumed.open_turn.?.user.text);

    // The tail must continue the snapshot.
    try std.testing.expectError(error.OutOfOrderJournalEvent, foldFrom(alloc, full, .{
        .history = &.{first},
        .cursor = .{ .next_seq = parsed.seq + 1, .turn = parsed.turn },
    }));
}

test "a superseded progress may leave out its state, the open turn's last may not" {
    const alloc = std.testing.allocator;
    var first = try testProgress(alloc, "first state");
    defer first.deinit(alloc);
    var last = try testProgress(alloc, "last state");
    defer last.deinit(alloc);
    const events = [_]Event{ .{ .turn_progress = .{ .checkpoint = first } }, .{ .turn_progress = .{ .checkpoint = last } } };
    const full = try testJournal(alloc, &events);
    defer alloc.free(full);
    const marker = "\"data\":{";
    const first_data = std.mem.find(u8, full, marker).?;
    const second_event = std.mem.find(u8, full[first_data..], "},{\"v\"").? + first_data;
    const stripped = try std.mem.concat(alloc, u8, &.{ full[0..first_data], "\"data\":null}", full[second_event + 1 ..] });
    defer alloc.free(stripped);
    var folded = try fold(alloc, stripped);
    defer folded.deinit(alloc);
    try std.testing.expectEqualStrings("last state", folded.open_turn.?.user.text);

    const only_null = "[{\"v\":1,\"seq\":1,\"turn\":1,\"type\":\"turn_progress\",\"data\":null}]";
    try std.testing.expectError(error.InvalidJournal, fold(alloc, only_null));
}

test "a progress event names the model its request goes to" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc, "look at this");
    defer progress.deinit(alloc);
    const events = [_]Event{.{ .turn_progress = .{ .checkpoint = progress, .model = "provider/model-a" } }};
    const written = try testJournal(alloc, &events);
    defer alloc.free(written);
    try std.testing.expect(std.mem.find(u8, written, "\"model\":\"provider/model-a\"") != null);
    var folded = try fold(alloc, written);
    defer folded.deinit(alloc);
    try std.testing.expectEqualStrings("look at this", folded.open_turn.?.user.text);
}

test "a snapshot carries the last turn's id to the turns after it" {
    const alloc = std.testing.allocator;
    const snapshot = try encodeSnapshot(alloc, 4, 3, "turn-a", null, "checkpoint-bytes");
    defer alloc.free(snapshot);
    const parsed = try parseSnapshot(snapshot);
    try std.testing.expectEqualStrings("turn-a", parsed.last_turn_id.?);
    try std.testing.expectEqualStrings("checkpoint-bytes", parsed.checkpoint);

    // A turn opened after the snapshot leaves the snapshot's last turn as the last.
    var progress = try testProgress(alloc, "keep going");
    defer progress.deinit(alloc);
    var tail_out: std.Io.Writer.Allocating = .init(alloc);
    defer tail_out.deinit();
    const cursor: Cursor = .{ .next_seq = parsed.seq + 1, .turn = parsed.turn };
    try tail_out.writer.writeByte('[');
    _ = try cursor.write(&tail_out.writer, .{ .turn_progress = .{ .checkpoint = progress, .turn_id = "turn-b" } });
    try tail_out.writer.writeByte(']');
    var folded = try foldFrom(alloc, tail_out.written(), .{ .cursor = cursor, .last_turn_id = parsed.last_turn_id });
    defer folded.deinit(alloc);
    try std.testing.expectEqualStrings("turn-a", folded.last_turn_id.?);
    try std.testing.expectEqualStrings("turn-b", folded.open_turn_id.?);

    // An id length that runs past the bytes is refused.
    const cut = try alloc.dupe(u8, snapshot[0 .. snapshot_header_bytes + 2]);
    defer alloc.free(cut);
    cut[snapshot_header_bytes - 1] = 3;
    try std.testing.expectError(error.InvalidJournal, parseSnapshot(cut));
}

test "a snapshot where a turn yielded restores the turn, and the events after it continue it" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc, "keep going");
    defer progress.deinit(alloc);
    var open_out: std.Io.Writer.Allocating = .init(alloc);
    defer open_out.deinit();
    try writeOpenTurn(&open_out.writer, "turn-y", progress);
    const snapshot = try encodeSnapshot(alloc, 5, 2, "turn-a", open_out.written(), "checkpoint-bytes");
    defer alloc.free(snapshot);
    const parsed = try parseSnapshot(snapshot);
    try std.testing.expectEqualStrings("checkpoint-bytes", parsed.checkpoint);
    try std.testing.expectEqualStrings(open_out.written(), parsed.open_turn.?);
    const base: Base = .{
        .cursor = .{ .next_seq = parsed.seq + 1, .turn = parsed.turn },
        .last_turn_id = parsed.last_turn_id,
        .open_turn = parsed.open_turn,
    };

    // With nothing after it, the turn is open, yielded, and keeps its name.
    var alone = try foldFrom(alloc, "[]", base);
    defer alone.deinit(alloc);
    try std.testing.expect(alone.yielded);
    try std.testing.expectEqualStrings("keep going", alone.open_turn.?.user.text);
    try std.testing.expectEqualStrings("turn-y", alone.open_turn_id.?);
    try std.testing.expectEqualStrings("turn-a", alone.last_turn_id.?);

    // A steer accepted after it is placed by the next progress, and the
    // turn then commits under its name.
    const turn = try testTurn(alloc, "keep going", "done");
    defer types.freeHistoryTurn(alloc, turn);
    var tail_out: std.Io.Writer.Allocating = .init(alloc);
    defer tail_out.deinit();
    var cursor = base.cursor;
    try tail_out.writer.writeByte('[');
    cursor = try cursor.write(&tail_out.writer, .{ .input_accepted = .{ .id = "s1", .text = "also this" } });
    try tail_out.writer.writeByte(',');
    cursor = try cursor.write(&tail_out.writer, .{ .turn_progress = .{ .checkpoint = progress, .placed = &.{"s1"} } });
    const steered_end = tail_out.written().len;
    try tail_out.writer.writeByte(',');
    _ = try cursor.write(&tail_out.writer, .{ .turn_committed = turn });
    try tail_out.writer.writeByte(']');

    const steered_json = try std.mem.concat(alloc, u8, &.{ tail_out.written()[0..steered_end], "]" });
    defer alloc.free(steered_json);
    var steered = try foldFrom(alloc, steered_json, base);
    defer steered.deinit(alloc);
    try std.testing.expect(!steered.yielded);
    try std.testing.expectEqualStrings("turn-y", steered.open_turn_id.?);
    try std.testing.expectEqual(@as(usize, 0), steered.pending_inputs.len);

    var ended = try foldFrom(alloc, tail_out.written(), base);
    defer ended.deinit(alloc);
    try std.testing.expect(ended.open_turn == null);
    try std.testing.expectEqual(@as(usize, 1), ended.history.len);
    try std.testing.expectEqualStrings("turn-y", ended.last_turn_id.?);
    try std.testing.expectEqual(parsed.turn + 1, ended.cursor.turn);
}

test "a snapshot's open turn that is cut short, empty, or not a turn is refused" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc, "keep going");
    defer progress.deinit(alloc);
    var open_out: std.Io.Writer.Allocating = .init(alloc);
    defer open_out.deinit();
    try writeOpenTurn(&open_out.writer, null, progress);
    const snapshot = try encodeSnapshot(alloc, 5, 2, null, open_out.written(), "");
    defer alloc.free(snapshot);
    // A quiet snapshot stays version 1; one with an open turn is version 2.
    try std.testing.expectEqual(snapshot_version, snapshot[snapshot_magic.len]);
    const quiet = try encodeSnapshot(alloc, 5, 2, null, null, "");
    defer alloc.free(quiet);
    try std.testing.expectEqual(snapshot_version_quiet, quiet[snapshot_magic.len]);
    try std.testing.expect((try parseSnapshot(quiet)).open_turn == null);

    // The open turn's length runs past the bytes.
    try std.testing.expectError(error.InvalidJournal, parseSnapshot(snapshot[0 .. snapshot.len - 1]));
    try std.testing.expectError(error.InvalidJournal, parseSnapshot(snapshot[0 .. snapshot_header_bytes + 2]));
    // An empty open turn.
    const empty = try alloc.dupe(u8, snapshot);
    defer alloc.free(empty);
    std.mem.writeInt(u32, empty[snapshot_header_bytes..][0..4], 0, .little);
    try std.testing.expectError(error.InvalidJournal, parseSnapshot(empty));
    // An open turn with no progress, or a turn id that is not one.
    try std.testing.expectError(error.InvalidJournal, foldFrom(alloc, "[]", .{ .cursor = .{ .next_seq = 6, .turn = 2 }, .open_turn = "{}" }));
    try std.testing.expectError(error.InvalidJournal, foldFrom(alloc, "[]", .{ .cursor = .{ .next_seq = 6, .turn = 2 }, .open_turn = "{\"turnId\":7,\"progress\":{}}" }));
    try std.testing.expectError(error.InvalidJournal, foldFrom(alloc, "[]", .{ .cursor = .{ .next_seq = 6, .turn = 2 }, .open_turn = "not json" }));
}

test "a snapshot past the positions a JavaScript host can hold is refused" {
    const alloc = std.testing.allocator;
    const far = try encodeSnapshot(alloc, max_safe_position + 1, 2, null, null, "");
    defer alloc.free(far);
    try std.testing.expectError(error.InvalidJournal, parseSnapshot(far));
    const late = try encodeSnapshot(alloc, 3, max_safe_position + 1, null, null, "");
    defer alloc.free(late);
    try std.testing.expectError(error.InvalidJournal, parseSnapshot(late));
    const edge = try encodeSnapshot(alloc, max_safe_position, max_safe_position, null, null, "");
    defer alloc.free(edge);
    _ = try parseSnapshot(edge);
}

test "a snapshot that is not one, or comes from a newer fx, is refused" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidJournal, parseSnapshot("FXCP"));
    try std.testing.expectError(error.InvalidJournal, parseSnapshot("FXSN"));
    const zero = try encodeSnapshot(alloc, 0, 1, null, null, "");
    defer alloc.free(zero);
    try std.testing.expectError(error.InvalidJournal, parseSnapshot(zero));
    const newer = try encodeSnapshot(alloc, 3, 2, null, null, "");
    defer alloc.free(newer);
    newer[snapshot_magic.len] = snapshot_version + 1;
    try std.testing.expectError(error.UnsupportedJournalVersion, parseSnapshot(newer));
}

test "a turn's first progress names it, and the turn keeps that name until it ends" {
    const alloc = std.testing.allocator;
    var progress = try testProgress(alloc, "write it");
    defer progress.deinit(alloc);
    const turn = try testTurn(alloc, "list", "done");
    defer types.freeHistoryTurn(alloc, turn);
    const bytes = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = progress, .turn_id = "t1" } },
        .{ .turn_committed = turn },
        .{ .turn_progress = .{ .checkpoint = progress, .turn_id = "t2" } },
        // A later progress of the same turn does not rename it.
        .{ .turn_progress = .{ .checkpoint = progress, .turn_id = "other" } },
    });
    defer alloc.free(bytes);
    var folded = try fold(alloc, bytes);
    defer folded.deinit(alloc);
    try std.testing.expectEqualStrings("t1", folded.last_turn_id.?);
    try std.testing.expectEqualStrings("t2", folded.open_turn_id.?);

    // A turn the host gave no id leaves none, and a cleared turn ends like a commit.
    const unnamed = try testJournal(alloc, &.{
        .{ .turn_progress = .{ .checkpoint = progress, .turn_id = "t1" } },
        .turn_progress_cleared,
        .{ .turn_progress = .{ .checkpoint = progress } },
    });
    defer alloc.free(unnamed);
    var later = try fold(alloc, unnamed);
    defer later.deinit(alloc);
    try std.testing.expectEqualStrings("t1", later.last_turn_id.?);
    try std.testing.expect(later.open_turn_id == null);

    const named = try testJournal(alloc, &.{.{ .turn_progress = .{ .checkpoint = progress, .turn_id = "x" } }});
    defer alloc.free(named);
    const at = std.mem.find(u8, named, "\"turnId\":\"x\"").?;
    const wrong = try std.mem.concat(alloc, u8, &.{ named[0..at], "\"turnId\":7", named[at + "\"turnId\":\"x\"".len ..] });
    defer alloc.free(wrong);
    try std.testing.expectError(error.InvalidJournal, fold(alloc, wrong));
}
