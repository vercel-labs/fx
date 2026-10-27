//! L2 pure core: lines in, state out.
//!
//! No I/O, no clock, no hidden allocation: every function takes its inputs
//! and returns or updates a value it owns. `plan` decides what a batch may
//! write; `apply` folds a written line into the state; `encodeState` and
//! `decodeState` turn the state into a snapshot and back. Resuming from the
//! newest snapshot must equal a full fold (`tests/tla/session_manager/ResumeSnapshot.tla`).

const std = @import("std");
const schema = @import("schema.zig");
const fold_queue = @import("fold_queue.zig");
pub const fold_mail = @import("fold_mail.zig");
const queueAt = fold_queue.queueAt;

pub const Interruption = struct { turn: u64, reason: schema.Reason };

/// Turns `turn` through `through` that a rewind dropped from the history
/// (D97). Turn numbers only grow, so ranges never reuse a number. A rewind
/// to a checkpoint (D120) drops only part of turn `turn`: its items from
/// line seq `from` up to the rewind's own line, seq `at`. The turn itself
/// stays.
pub const Dropped = struct {
    turn: u64,
    through: u64,
    from: ?u64 = null,
    at: u64 = 0,

    /// Whether this rewind drops the whole turn `turn`.
    pub fn dropsTurn(range: Dropped, turn: u64) bool {
        return range.from == null and turn >= range.turn and turn <= range.through;
    }

    /// Whether this rewind drops the item of turn `turn` at line `seq`
    /// without dropping the whole turn.
    pub fn dropsItem(range: Dropped, turn: u64, seq: u64) bool {
        const from = range.from orelse return false;
        return turn == range.turn and seq >= from and seq < range.at;
    }
};

/// The most rewinds one session keeps; a later one is refused.
pub const max_rewinds = 64;

/// One child spawned in this session (D22). Owns its slices.
pub const Child = struct {
    id: []u8,
    /// The child's newest work item.
    work_id: []u8,
    /// That work item is spawned and not finished.
    open: bool = true,
    /// How the newest finished work item ended; null before the first finish.
    outcome: ?schema.Outcome = null,
    /// fx's `data` from the newest `child_spawned` and `child_finished`.
    spawn_data: ?[]u8 = null,
    finish_data: ?[]u8 = null,
    /// Seq of the newest line about this child; fx uses it as a generation.
    seq: u64,
    /// A rewind of this session dropped the turn that first spawned it
    /// (D97): it stays listed, read-only, and takes no more work.
    abandoned: bool = false,
    /// Work waiting behind the open item, oldest first (D113).
    queue: std.ArrayList(Queued) = .empty,
    /// fx's `data` from `child_terminated`; set once the child is
    /// terminal (D113): listed, read-only, and taking no more work.
    terminated: ?[]u8 = null,

    fn deinit(child: Child, gpa: std.mem.Allocator) void {
        gpa.free(child.id);
        gpa.free(child.work_id);
        if (child.spawn_data) |data| gpa.free(data);
        if (child.finish_data) |data| gpa.free(data);
        for (child.queue.items) |item| item.deinit(gpa);
        var queue = child.queue;
        queue.deinit(gpa);
        if (child.terminated) |data| gpa.free(data);
    }

    fn clone(child: Child, gpa: std.mem.Allocator) error{OutOfMemory}!Child {
        var copy = child;
        copy.queue = .empty;
        copy.terminated = null;
        copy.id = try gpa.dupe(u8, child.id);
        errdefer gpa.free(copy.id);
        copy.work_id = try gpa.dupe(u8, child.work_id);
        errdefer gpa.free(copy.work_id);
        copy.spawn_data = try dupeOptional(gpa, child.spawn_data);
        errdefer if (copy.spawn_data) |data| gpa.free(data);
        copy.finish_data = try dupeOptional(gpa, child.finish_data);
        errdefer if (copy.finish_data) |data| gpa.free(data);
        copy.terminated = try dupeOptional(gpa, child.terminated);
        errdefer if (copy.terminated) |data| gpa.free(data);
        errdefer {
            for (copy.queue.items) |item| item.deinit(gpa);
            copy.queue.deinit(gpa);
        }
        try copy.queue.ensureTotalCapacity(gpa, child.queue.items.len);
        for (child.queue.items) |item| copy.queue.appendAssumeCapacity(try item.clone(gpa));
        return copy;
    }

    fn eql(a: Child, b: Child) bool {
        if (a.queue.items.len != b.queue.items.len) return false;
        for (a.queue.items, b.queue.items) |x, y| {
            if (!std.mem.eql(u8, x.work_id, y.work_id) or !optionalEql(x.data, y.data)) return false;
        }
        return std.mem.eql(u8, a.id, b.id) and
            std.mem.eql(u8, a.work_id, b.work_id) and
            a.open == b.open and a.outcome == b.outcome and a.seq == b.seq and
            a.abandoned == b.abandoned and
            optionalEql(a.spawn_data, b.spawn_data) and
            optionalEql(a.finish_data, b.finish_data) and
            optionalEql(a.terminated, b.terminated);
    }

    /// Whether the child may take work: not abandoned (D97) or terminal (D113).
    pub fn closed(child: Child) bool {
        return child.abandoned or child.terminated != null;
    }
};

pub const Queued = fold_queue.Queued;
pub const max_queued_work = fold_queue.max_queued_work;

/// Everything the log implies about a session except its identity, which
/// is line 1. Owns every slice; free with `deinit`.
pub const State = struct {
    /// Number of the open turn, if one is open.
    open_turn: ?u64 = null,
    /// Highest turn number started; the next turn is this plus one.
    last_turn: u64 = 0,
    committed: u64 = 0,
    interrupted: u64 = 0,
    last_interrupted: ?Interruption = null,
    /// Newest `set` value per key, as raw JSON.
    prefs: ?[]u8 = null,
    title: ?[]u8 = null,
    permissions: ?[]u8 = null,
    usage: ?[]u8 = null,
    workspace: ?[]u8 = null,
    language: ?[]u8 = null,
    client_prompt: ?[]u8 = null,
    tool_identities: ?[]u8 = null,
    moved_files: ?[]u8 = null,
    compaction_records: ?[]u8 = null,
    v1_source: ?[]u8 = null,
    /// Every child spawned in this session, in first-spawn order (D22).
    children: std.ArrayList(Child) = .empty,
    /// The turns rewinds dropped, oldest rewind first (D97).
    dropped: std.ArrayList(Dropped) = .empty,
    /// Messages other agents sent this node that wait, oldest first (D185).
    mailbox: std.ArrayList(fold_mail.Mail) = .empty,
    last_compaction_seq: ?u64 = null,
    /// Byte offset of the newest `compacted` line. fx's `data` there may
    /// keep a tail of earlier lines, which the adapter reads back to.
    compaction_offset: ?u64 = null,
    /// The last line is `closed`.
    clean_exit: bool = false,
    last_seq: u64 = 0,
    /// `ts` of line 1 and of the newest line; 0 before the first turn
    /// (D20). The session fills both in the copies it hands out, from the
    /// log it reads and writes; the fold and snapshots leave them alone.
    created_ms: u64 = 0,
    updated_ms: u64 = 0,

    pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
        inline for (setting_fields) |name| {
            if (@field(state, name)) |value| gpa.free(value);
        }
        for (state.children.items) |child| child.deinit(gpa);
        state.children.deinit(gpa);
        state.dropped.deinit(gpa);
        for (state.mailbox.items) |mail| mail.deinit(gpa);
        state.mailbox.deinit(gpa);
        state.* = undefined;
    }

    /// Whether a rewind dropped turn `turn` from the history (D97).
    pub fn droppedTurn(state: *const State, turn: u64) bool {
        return isDropped(state.dropped.items, turn);
    }

    /// Forgets every child: a fork owns none of its source's (D5).
    pub fn clearChildren(state: *State, gpa: std.mem.Allocator) void {
        for (state.children.items) |child| child.deinit(gpa);
        state.children.clearRetainingCapacity();
    }

    /// A deep copy owned through `gpa`.
    pub fn clone(state: *const State, gpa: std.mem.Allocator) error{OutOfMemory}!State {
        var copy: State = state.*;
        copy.children = .empty;
        copy.dropped = .empty;
        copy.mailbox = .empty;
        inline for (setting_fields) |name| @field(copy, name) = null;
        errdefer copy.deinit(gpa);
        inline for (setting_fields) |name| {
            if (@field(state, name)) |value| @field(copy, name) = try gpa.dupe(u8, value);
        }
        try copy.children.ensureTotalCapacity(gpa, state.children.items.len);
        for (state.children.items) |child| copy.children.appendAssumeCapacity(try child.clone(gpa));
        try copy.dropped.appendSlice(gpa, state.dropped.items);
        try copy.mailbox.ensureTotalCapacity(gpa, state.mailbox.items.len);
        for (state.mailbox.items) |mail| copy.mailbox.appendAssumeCapacity(try mail.clone(gpa));
        return copy;
    }

    pub fn setting(state: *const State, key: schema.SetKey) ?[]const u8 {
        return switch (key) {
            inline else => |k| @field(state, @tagName(k)),
        };
    }

    fn settingPtr(state: *State, key: schema.SetKey) *?[]u8 {
        return switch (key) {
            inline else => |k| &@field(state, @tagName(k)),
        };
    }

    pub fn findChild(state: *const State, id: []const u8) ?usize {
        for (state.children.items, 0..) |child, i| {
            if (std.mem.eql(u8, child.id, id)) return i;
        }
        return null;
    }

    /// The child's newest work item, if it is unfinished.
    fn openWork(state: *const State, id: []const u8) ?[]const u8 {
        const child = state.children.items[state.findChild(id) orelse return null];
        return if (child.open) child.work_id else null;
    }

    fn spawnChild(state: *State, gpa: std.mem.Allocator, seq: u64, spawned: schema.Body.WorkItem) error{OutOfMemory}!void {
        const work_id = try gpa.dupe(u8, spawned.work_id);
        errdefer gpa.free(work_id);
        const data = try dupeOptional(gpa, spawned.data);
        errdefer if (data) |d| gpa.free(d);
        if (state.findChild(spawned.child)) |i| {
            const known = &state.children.items[i];
            // A queued item starts from the front of the queue (D113).
            if (known.queue.items.len > 0 and std.mem.eql(u8, known.queue.items[0].work_id, spawned.work_id)) {
                known.queue.orderedRemove(0).deinit(gpa);
            }
            gpa.free(known.work_id);
            if (known.spawn_data) |d| gpa.free(d);
            known.work_id = work_id;
            known.spawn_data = data;
            known.open = true;
            known.seq = seq;
            return;
        }
        const id = try gpa.dupe(u8, spawned.child);
        errdefer gpa.free(id);
        try state.children.append(gpa, .{ .id = id, .work_id = work_id, .spawn_data = data, .seq = seq });
    }

    /// Closes the child's open work item. A finish for any other work is
    /// not a line the manager writes, and changes nothing.
    fn finishChild(state: *State, gpa: std.mem.Allocator, seq: u64, finished: schema.Body.Finished) error{OutOfMemory}!void {
        const known = &state.children.items[state.findChild(finished.child) orelse return];
        // A cancelled queued item leaves the queue and never ran (D113).
        for (known.queue.items, 0..) |item, index| {
            if (!std.mem.eql(u8, item.work_id, finished.work_id)) continue;
            known.queue.orderedRemove(index).deinit(gpa);
            known.seq = seq;
            return;
        }
        if (!known.open or !std.mem.eql(u8, known.work_id, finished.work_id)) return;
        const data = try dupeOptional(gpa, finished.data);
        if (known.finish_data) |d| gpa.free(d);
        known.finish_data = data;
        known.open = false;
        known.outcome = finished.outcome;
        known.seq = seq;
    }

    /// Field-by-field equality of the folded fields (not the two times),
    /// used by the fold-equivalence checks.
    pub fn eql(a: *const State, b: *const State) bool {
        if (a.open_turn != b.open_turn or a.last_turn != b.last_turn) return false;
        if (a.committed != b.committed or a.interrupted != b.interrupted) return false;
        if (!std.meta.eql(a.last_interrupted, b.last_interrupted)) return false;
        inline for (setting_fields) |name| {
            if (!optionalEql(@field(a, name), @field(b, name))) return false;
        }
        if (a.children.items.len != b.children.items.len) return false;
        for (a.children.items, b.children.items) |x, y| {
            if (!x.eql(y)) return false;
        }
        if (a.dropped.items.len != b.dropped.items.len) return false;
        for (a.dropped.items, b.dropped.items) |x, y| {
            if (!std.meta.eql(x, y)) return false;
        }
        if (!fold_mail.eql(a.mailbox.items, b.mailbox.items)) return false;
        return a.last_compaction_seq == b.last_compaction_seq and
            a.compaction_offset == b.compaction_offset and
            a.clean_exit == b.clean_exit and
            a.last_seq == b.last_seq;
    }
};

/// Whether any of `ranges` holds `turn`.
pub fn isDropped(ranges: []const Dropped, turn: u64) bool {
    for (ranges) |range| if (range.dropsTurn(turn)) return true;
    return false;
}

const setting_fields = .{ "prefs", "title", "permissions", "usage", "workspace", "language", "client_prompt", "tool_identities", "moved_files", "compaction_records", "v1_source" };

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn dupeOptional(gpa: std.mem.Allocator, value: ?[]const u8) error{OutOfMemory}!?[]u8 {
    return if (value) |v| try gpa.dupe(u8, v) else null;
}

// ---------------------------------------------------------------------------
// Folding written lines

pub const Line = struct {
    seq: u64,
    /// Byte offset of the line in the log.
    offset: u64,
    body: schema.Body,
};

/// Folds one written line into `state`. Snapshot lines change nothing but
/// `last_seq`: they are a cache. In a forked session, child lines at or
/// before `fork_seq` belong to the source and are skipped.
pub fn apply(gpa: std.mem.Allocator, state: *State, fork_seq: u64, line: Line) error{OutOfMemory}!void {
    switch (line.body) {
        // The store and kernel lines fold on demand, never into the state
        // (`python_fold.zig`, D99).
        .session_created, .item, .snapshot, .closed, .store_set, .store_del, .kernel_snapshot => {},
        .turn_started => |t| {
            state.open_turn = t.turn;
            state.last_turn = @max(state.last_turn, t.turn);
        },
        .compacted => {
            state.last_compaction_seq = line.seq;
            state.compaction_offset = line.offset;
        },
        .turn_committed => {
            state.open_turn = null;
            state.committed += 1;
        },
        .turn_interrupted => |i| {
            state.open_turn = null;
            state.interrupted += 1;
            state.last_interrupted = .{ .turn = i.turn, .reason = i.reason };
        },
        .set => |s| {
            const copy = try gpa.dupe(u8, s.value);
            const slot = state.settingPtr(s.key);
            if (slot.*) |old| gpa.free(old);
            slot.* = copy;
        },
        .child_spawned => |c| if (line.seq > fork_seq) try state.spawnChild(gpa, line.seq, c),
        .child_finished => |c| if (line.seq > fork_seq) try state.finishChild(gpa, line.seq, c),
        .child_queued => |c| if (line.seq > fork_seq) if (state.findChild(c.child)) |i| try fold_queue.enqueue(gpa, &state.children.items[i], line.seq, c),
        .child_terminated => |c| if (line.seq > fork_seq) if (state.findChild(c.child)) |i| try fold_queue.terminate(gpa, &state.children.items[i], line.seq, c),
        // A fork starts with an empty mailbox, as with children (D185).
        .mail => |m| if (line.seq > fork_seq) try fold_mail.receive(gpa, state, line.seq, m),
        .mail_done => |d| if (line.seq > fork_seq) fold_mail.finish(gpa, state, d.id),
        .rewound => |r| {
            try state.dropped.append(gpa, .{ .turn = r.turn, .through = r.through, .from = r.from, .at = if (r.from != null) line.seq else 0 });
            for (r.abandoned) |id| {
                const index = state.findChild(id) orelse continue;
                state.children.items[index].abandoned = true;
            }
        },
    }
    state.last_seq = line.seq;
    state.clean_exit = line.body == .closed;
}

// ---------------------------------------------------------------------------
// Planning a batch: the turn and child rules

/// What a caller asks the manager to append. The manager stamps turn
/// numbers; hosts never choose them.
pub const Event = union(enum) {
    turn_started,
    item: Piece,
    compacted: []const u8,
    turn_committed,
    turn_interrupted: schema.Reason,
    set: schema.Body.Setting,
    child_spawned: schema.Body.WorkItem,
    child_finished: schema.Body.Finished,
    /// Drops turns `turn` through the newest from the history and abandons
    /// the named children (D97); with `from`, only the open turn's items
    /// from that line seq (D120). The manager fills in `through`.
    rewound: Rewind,
    /// A value of the node's store, or its removal (D99). Inside a turn;
    /// the manager fills in the turn.
    store_set: StoreSet,
    store_del: []const u8,
    /// The kernel's globals at this turn's end (D99). Inside a turn.
    kernel_snapshot: KernelSnapshot,
    /// Work waiting behind a child's open item, and a child made terminal
    /// (D113).
    child_queued: schema.Body.WorkItem,
    child_terminated: schema.Body.Terminated,
    /// A message into this node's mailbox, and one leaving it (D185).
    mail: schema.Body.Mail,
    mail_done: schema.Body.MailDone,
};

pub const StoreSet = struct { key: []const u8, blob: *const [1][]const u8 };
pub const KernelSnapshot = struct {
    kernel: []const u8,
    names: []const []const u8,
    blobs: []const []const u8,
    failed: []const u8 = "[]",
};

pub const Rewind = struct { turn: u64, abandoned: []const []const u8 = &.{}, from: ?u64 = null };

/// One completed piece of a turn: fx's data, and the blobs it refers to.
pub const Piece = struct {
    /// fx's name for the piece, such as `steering` or `tool_result` (D17).
    type: []const u8,
    data: []const u8,
    blobs: []const []const u8 = &.{},
};

pub const TransitionError = error{InvalidTransition};

/// Pure: checks every event of a batch in order, as if the earlier ones
/// were already written, and fills `out` with the bodies to write. Nothing
/// changes when any event is refused, so a refused batch writes nothing.
pub fn plan(state: *const State, events: []const Event, out: []schema.Body) TransitionError!void {
    std.debug.assert(out.len == events.len);
    var open_turn = state.open_turn;
    var last_turn = state.last_turn;
    for (events, 0..) |event, i| {
        out[i] = switch (event) {
            .turn_started => blk: {
                if (open_turn != null) return error.InvalidTransition;
                last_turn += 1;
                open_turn = last_turn;
                break :blk .{ .turn_started = .{ .turn = last_turn } };
            },
            .item => |piece| .{ .item = .{
                .turn = open_turn orelse return error.InvalidTransition,
                .type = piece.type,
                .data = piece.data,
                .blobs = piece.blobs,
            } },
            .compacted => |data| .{ .compacted = .{ .turn = open_turn, .data = data } },
            .turn_committed => blk: {
                const turn = open_turn orelse return error.InvalidTransition;
                open_turn = null;
                break :blk .{ .turn_committed = .{ .turn = turn } };
            },
            .turn_interrupted => |reason| blk: {
                const turn = open_turn orelse return error.InvalidTransition;
                open_turn = null;
                break :blk .{ .turn_interrupted = .{ .turn = turn, .reason = reason } };
            },
            .set => |s| .{ .set = s },
            // One unfinished work item per child (`tests/tla/session_manager/Subagents.tla`
            // OneOpenWork); a finish names exactly that one.
            .child_spawned => |c| blk: {
                if (openWorkAt(state, events[0..i], c.child) != null) return error.InvalidTransition;
                // An abandoned or terminal child takes no more work (D97, D113).
                if (abandonedAt(state, events[0..i], c.child)) return error.InvalidTransition;
                // Queued work starts in order (`tests/tla/session_manager/Fleet.tla`
                // QueueInOrder).
                var queue = queueAt(state, events[0..i], c.child);
                if (queue.len() > 0 and !std.mem.eql(u8, queue.front().?, c.work_id)) return error.InvalidTransition;
                break :blk .{ .child_spawned = c };
            },
            .child_finished => |c| blk: {
                var queue = queueAt(state, events[0..i], c.child);
                if (queue.contains(c.work_id)) {
                    if (c.outcome != .cancelled) return error.InvalidTransition;
                    break :blk .{ .child_finished = c };
                }
                const open = openWorkAt(state, events[0..i], c.child) orelse return error.InvalidTransition;
                if (!std.mem.eql(u8, open, c.work_id)) return error.InvalidTransition;
                break :blk .{ .child_finished = c };
            },
            .child_queued => |c| blk: {
                if (!fold_queue.knownAt(state, events[0..i], c.child)) return error.InvalidTransition;
                if (abandonedAt(state, events[0..i], c.child)) return error.InvalidTransition;
                var queue = queueAt(state, events[0..i], c.child);
                if (queue.len() >= max_queued_work or queue.contains(c.work_id)) return error.InvalidTransition;
                if (openWorkAt(state, events[0..i], c.child)) |open| if (std.mem.eql(u8, open, c.work_id)) return error.InvalidTransition;
                break :blk .{ .child_queued = c };
            },
            // Terminal only between work items, so the in-flight turn is
            // finished first (`tests/tla/session_manager/Fleet.tla`
            // NoWorkAfterTerminate).
            .child_terminated => |c| blk: {
                if (!fold_queue.knownAt(state, events[0..i], c.child)) return error.InvalidTransition;
                if (abandonedAt(state, events[0..i], c.child)) return error.InvalidTransition;
                if (openWorkAt(state, events[0..i], c.child) != null) return error.InvalidTransition;
                break :blk .{ .child_terminated = c };
            },
            .mail => |m| blk: {
                try fold_mail.planMail(state, events[0..i], m);
                break :blk .{ .mail = m };
            },
            .mail_done => |d| blk: {
                try fold_mail.planDone(state, events[0..i], d);
                break :blk .{ .mail_done = d };
            },
            // Between turns, over turns that exist, and never over a child
            // whose work runs (`tests/tla/session_manager/Rewind.tla`
            // NoRewindWhileBusy).
            // A rewind to a checkpoint drops part of the open turn and only
            // that (`tests/tla/session_manager/Checkpoint.tla` DropsOnlySinceCheckpoint).
            .rewound => |r| blk: {
                if (r.from) |from| {
                    if (open_turn != r.turn or from > state.last_seq + 1) return error.InvalidTransition;
                } else if (open_turn != null) return error.InvalidTransition;
                if (r.turn == 0 or r.turn > last_turn) return error.InvalidTransition;
                if (rewindsAt(state, events[0..i]) >= max_rewinds) return error.InvalidTransition;
                for (r.abandoned) |id| {
                    if (state.findChild(id) == null) return error.InvalidTransition;
                    if (openWorkAt(state, events[0..i], id) != null) return error.InvalidTransition;
                }
                break :blk .{ .rewound = .{ .turn = r.turn, .through = last_turn, .abandoned = r.abandoned, .from = r.from } };
            },
            // Python state belongs to the turn that made it, so a rewind
            // drops it with the turn (`tests/tla/session_manager/PythonState.tla`).
            .store_set => |v| .{ .store_set = .{ .turn = open_turn orelse return error.InvalidTransition, .key = v.key, .blob = v.blob } },
            .store_del => |key| .{ .store_del = .{ .turn = open_turn orelse return error.InvalidTransition, .key = key } },
            .kernel_snapshot => |k| blk: {
                if (k.names.len != k.blobs.len) return error.InvalidTransition;
                break :blk .{ .kernel_snapshot = .{
                    .turn = open_turn orelse return error.InvalidTransition,
                    .kernel = k.kernel,
                    .names = k.names,
                    .blobs = k.blobs,
                    .failed = k.failed,
                } };
            },
        };
    }
}

/// Whether `child` is abandoned or terminal after `earlier` events of the
/// batch.
fn abandonedAt(state: *const State, earlier: []const Event, child: []const u8) bool {
    if (state.findChild(child)) |index| if (state.children.items[index].closed()) return true;
    for (earlier) |event| switch (event) {
        .rewound => |r| for (r.abandoned) |id| if (std.mem.eql(u8, id, child)) return true,
        .child_terminated => |c| if (std.mem.eql(u8, c.child, child)) return true,
        else => {},
    };
    return false;
}

fn rewindsAt(state: *const State, earlier: []const Event) usize {
    var count = state.dropped.items.len;
    for (earlier) |event| {
        if (event == .rewound) count += 1;
    }
    return count;
}

/// The child's unfinished work item after `earlier` events of the batch,
/// already checked in order, are applied to `state`.
fn openWorkAt(state: *const State, earlier: []const Event, child: []const u8) ?[]const u8 {
    var open = state.openWork(child);
    for (earlier) |event| switch (event) {
        .child_spawned => |c| if (std.mem.eql(u8, c.child, child)) {
            open = c.work_id;
        },
        .child_finished => |c| if (std.mem.eql(u8, c.child, child)) {
            open = null;
        },
        else => {},
    };
    return open;
}

// ---------------------------------------------------------------------------
// Snapshots

/// Appends the state as one JSON object (without `last_seq` and
/// `clean_exit`, which the snapshot line's own position gives).
pub fn encodeState(gpa: std.mem.Allocator, out: *std.ArrayList(u8), state: *const State) error{OutOfMemory}!void {
    try out.print(gpa, "{{\"open_turn\":", .{});
    try printOptional(gpa, out, state.open_turn);
    try out.print(gpa, ",\"last_turn\":{d},\"committed\":{d},\"interrupted\":{d},\"last_interrupted\":", .{
        state.last_turn, state.committed, state.interrupted,
    });
    if (state.last_interrupted) |i| {
        try out.print(gpa, "{{\"turn\":{d},\"reason\":\"{s}\"}}", .{ i.turn, @tagName(i.reason) });
    } else try out.appendSlice(gpa, "null");
    // Raw values are written only when present, so a value that is the
    // JSON `null` stays distinct from no value.
    inline for (setting_fields) |name| {
        if (@field(state, name)) |value| try appendRawField(gpa, out, name, value);
    }
    try out.appendSlice(gpa, ",\"children\":[");
    for (state.children.items, 0..) |child, i| {
        if (i > 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, "{\"id\":");
        try schema.appendJsonString(gpa, out, child.id);
        try out.appendSlice(gpa, ",\"work_id\":");
        try schema.appendJsonString(gpa, out, child.work_id);
        try out.print(gpa, ",\"open\":{s},\"seq\":{d}", .{ if (child.open) "true" else "false", child.seq });
        if (child.outcome) |outcome| try out.print(gpa, ",\"outcome\":\"{s}\"", .{@tagName(outcome)});
        if (child.spawn_data) |data| try appendRawField(gpa, out, "spawn_data", data);
        if (child.finish_data) |data| try appendRawField(gpa, out, "finish_data", data);
        if (child.abandoned) try out.appendSlice(gpa, ",\"abandoned\":true");
        // Written only for workers that have them, so older snapshots read
        // the same (D113).
        if (child.queue.items.len > 0) {
            try out.appendSlice(gpa, ",\"queue\":[");
            for (child.queue.items, 0..) |item, q| {
                if (q > 0) try out.append(gpa, ',');
                try out.appendSlice(gpa, "{\"work_id\":");
                try schema.appendJsonString(gpa, out, item.work_id);
                if (item.data) |data| try appendRawField(gpa, out, "data", data);
                try out.append(gpa, '}');
            }
            try out.append(gpa, ']');
        }
        if (child.terminated) |data| try appendRawField(gpa, out, "terminated", data);
        try out.append(gpa, '}');
    }
    try out.append(gpa, ']');
    // Written only after a rewind, so older snapshots read the same.
    if (state.dropped.items.len > 0) {
        try out.appendSlice(gpa, ",\"dropped\":[");
        for (state.dropped.items, 0..) |range, i| {
            if (i > 0) try out.append(gpa, ',');
            try out.print(gpa, "{{\"turn\":{d},\"through\":{d}", .{ range.turn, range.through });
            if (range.from) |from| try out.print(gpa, ",\"from\":{d},\"at\":{d}", .{ from, range.at });
            try out.append(gpa, '}');
        }
        try out.append(gpa, ']');
    }
    try fold_mail.encode(gpa, out, state.mailbox.items);
    try out.appendSlice(gpa, ",\"last_compaction_seq\":");
    try printOptional(gpa, out, state.last_compaction_seq);
    try out.appendSlice(gpa, ",\"compaction_offset\":");
    try printOptional(gpa, out, state.compaction_offset);
    try out.append(gpa, '}');
}

fn appendRawField(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime name: []const u8, value: []const u8) error{OutOfMemory}!void {
    try out.appendSlice(gpa, ",\"" ++ name ++ "\":");
    try out.appendSlice(gpa, value);
}

fn printOptional(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: ?u64) error{OutOfMemory}!void {
    if (value) |v| try out.print(gpa, "{d}", .{v}) else try out.appendSlice(gpa, "null");
}

/// Rebuilds a State from a snapshot's `state` object. `arena` holds only
/// parsing scratch; the result is owned through `gpa`.
pub fn decodeState(gpa: std.mem.Allocator, arena: std.mem.Allocator, raw: []const u8) schema.BodyError!State {
    const f = try schema.Fields.parseObject(arena, raw);
    var state: State = .{
        .open_turn = try f.opt(u64, "open_turn"),
        .last_turn = try f.req(u64, "last_turn"),
        .committed = try f.req(u64, "committed"),
        .interrupted = try f.req(u64, "interrupted"),
        .last_interrupted = try f.opt(Interruption, "last_interrupted"),
        .last_compaction_seq = try f.opt(u64, "last_compaction_seq"),
        .compaction_offset = try f.opt(u64, "compaction_offset"),
    };
    errdefer state.deinit(gpa);
    inline for (setting_fields) |name| {
        if (f.raw(name)) |value| @field(state, name) = try gpa.dupe(u8, value);
    }
    for (try schema.rawElements(arena, try f.rawReq("children"))) |raw_child| {
        const c = try schema.Fields.parseObject(arena, raw_child);
        const id = try gpa.dupe(u8, try c.req([]const u8, "id"));
        errdefer gpa.free(id);
        const work_id = try gpa.dupe(u8, try c.req([]const u8, "work_id"));
        errdefer gpa.free(work_id);
        const spawn_data = try dupeOptional(gpa, c.raw("spawn_data"));
        errdefer if (spawn_data) |data| gpa.free(data);
        const finish_data = try dupeOptional(gpa, c.raw("finish_data"));
        errdefer if (finish_data) |data| gpa.free(data);
        const terminated = try dupeOptional(gpa, c.raw("terminated"));
        errdefer if (terminated) |data| gpa.free(data);
        var queue: std.ArrayList(Queued) = .empty;
        errdefer {
            for (queue.items) |item| item.deinit(gpa);
            queue.deinit(gpa);
        }
        if (c.raw("queue")) |raw_queue| for (try schema.rawElements(arena, raw_queue)) |raw_item| {
            const q = try schema.Fields.parseObject(arena, raw_item);
            const item_id = try gpa.dupe(u8, try q.req([]const u8, "work_id"));
            errdefer gpa.free(item_id);
            const item_data = try dupeOptional(gpa, q.raw("data"));
            errdefer if (item_data) |data| gpa.free(data);
            try queue.append(gpa, .{ .work_id = item_id, .data = item_data });
        };
        try state.children.append(gpa, .{
            .id = id,
            .work_id = work_id,
            .open = try c.req(bool, "open"),
            .outcome = try c.opt(schema.Outcome, "outcome"),
            .spawn_data = spawn_data,
            .finish_data = finish_data,
            .seq = try c.req(u64, "seq"),
            .abandoned = try c.opt(bool, "abandoned") orelse false,
            .queue = queue,
            .terminated = terminated,
        });
    }
    if (f.raw("mailbox")) |raw_mailbox| try fold_mail.decode(gpa, arena, &state, raw_mailbox);
    if (f.raw("dropped")) |raw_dropped| {
        for (try schema.rawElements(arena, raw_dropped)) |raw_range| {
            const r = try schema.Fields.parseObject(arena, raw_range);
            try state.dropped.append(gpa, .{
                .turn = try r.req(u64, "turn"),
                .through = try r.req(u64, "through"),
                .from = try r.opt(u64, "from"),
                .at = try r.opt(u64, "at") orelse 0,
            });
        }
    }
    return state;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// An in-memory log: bodies with seqs, no bytes. Snapshots hold encoded state.
const MemLog = struct {
    arena: std.heap.ArenaAllocator,
    lines: std.ArrayList(Line) = .empty,

    fn init() MemLog {
        return .{ .arena = .init(testing.allocator) };
    }

    fn deinit(m: *MemLog) void {
        m.arena.deinit();
    }

    fn add(m: *MemLog, body: schema.Body) !void {
        const seq = m.lines.items.len + 1;
        try m.lines.append(m.arena.allocator(), .{ .seq = seq, .offset = seq * 100, .body = body });
    }

    fn fullFold(m: *const MemLog, skip_snapshots: bool) !State {
        var state: State = .{};
        errdefer state.deinit(testing.allocator);
        for (m.lines.items) |line| {
            if (skip_snapshots and line.body == .snapshot) continue;
            try apply(testing.allocator, &state, 0, line);
        }
        return state;
    }

    /// What resume computes: the newest snapshot, then the tail.
    fn resumeFold(m: *MemLog) !State {
        var newest: ?usize = null;
        for (m.lines.items, 0..) |line, i| {
            if (line.body == .snapshot) newest = i;
        }
        const start = newest orelse return m.fullFold(false);
        const snap = m.lines.items[start];
        var state = try decodeState(testing.allocator, m.arena.allocator(), snap.body.snapshot.state);
        errdefer state.deinit(testing.allocator);
        state.last_seq = snap.seq;
        for (m.lines.items[start + 1 ..]) |line| try apply(testing.allocator, &state, 0, line);
        return state;
    }
};

fn randomEvent(random: std.Random) Event {
    const children = [_][]const u8{ "c1", "c2" };
    const works = [_][]const u8{ "w1", "w2" };
    const values = [_][]const u8{ "\"v1\"", "{\"m\":\"v2\"}", "[1, 2]", "null" };
    const data = [_]?[]const u8{ null, "{\"name\":\"n\"}", "null" };
    const outcomes = [_]schema.Outcome{ .ok, .failed, .cancelled, .interrupted };
    return switch (random.uintLessThan(u8, 10)) {
        0 => .turn_started,
        1 => .{ .item = .{ .type = "assistant", .data = "{\"text\":\"piece\"}" } },
        2 => .{ .compacted = "{\"summary\":\"s\"}" },
        3 => .turn_committed,
        4 => .{ .turn_interrupted = if (random.boolean()) .cancel else .failed },
        5 => .{ .set = .{ .key = random.enumValue(schema.SetKey), .value = values[random.uintLessThan(usize, values.len)] } },
        6 => .{ .child_spawned = .{
            .child = children[random.uintLessThan(usize, 2)],
            .work_id = works[random.uintLessThan(usize, 2)],
            .data = data[random.uintLessThan(usize, data.len)],
        } },
        7 => .{ .child_finished = .{
            .child = children[random.uintLessThan(usize, 2)],
            .work_id = works[random.uintLessThan(usize, 2)],
            .outcome = outcomes[random.uintLessThan(usize, outcomes.len)],
            .data = data[random.uintLessThan(usize, data.len)],
        } },
        8 => .{ .rewound = .{
            .turn = 1 + random.uintLessThan(u64, 3),
            .abandoned = if (random.boolean()) &.{} else children[random.uintLessThan(usize, 2)..][0..1],
        } },
        else => .turn_started,
    };
}

/// `TurnLifecycle.tla` `Valid(l, k)` for one event, from the spec's view.
fn specValid(open: bool, event: Event) ?bool {
    return switch (event) {
        .turn_started => !open,
        .item, .turn_committed, .turn_interrupted, .store_set, .store_del, .kernel_snapshot => open,
        .compacted, .set => true,
        .child_spawned, .child_finished, .child_queued, .child_terminated, .mail, .mail_done, .rewound => null, // not in TurnLifecycle
    };
}

test "plan accepts exactly the transitions TurnLifecycle allows" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (0..200) |_| {
        var state: State = .{};
        defer state.deinit(testing.allocator);
        var kinds: std.ArrayList(schema.Kind) = .empty;
        defer kinds.deinit(testing.allocator);
        for (0..60) |step| {
            const event = randomEvent(random);
            var out: [1]schema.Body = undefined;
            const accepted = if (plan(&state, &.{event}, &out)) true else |_| false;
            if (specValid(state.open_turn != null, event)) |valid| try testing.expectEqual(valid, accepted);
            if (!accepted) continue;
            try apply(testing.allocator, &state, 0, .{ .seq = step + 1, .offset = 0, .body = out[0] });
            try kinds.append(testing.allocator, std.meta.activeTag(out[0]));
        }
        // AtMostOneOpenTurn, ItemsInsideTurns, EndsCloseATurn over the written kinds.
        var open = false;
        for (kinds.items) |kind| switch (kind) {
            .turn_started => {
                try testing.expect(!open);
                open = true;
            },
            .item => try testing.expect(open),
            .turn_committed, .turn_interrupted => {
                try testing.expect(open);
                open = false;
            },
            else => {},
        };
        try testing.expectEqual(open, state.open_turn != null);
    }
}

test "a refused event refuses the whole batch" {
    var state: State = .{};
    defer state.deinit(testing.allocator);
    var out: [3]schema.Body = undefined;
    try testing.expectError(error.InvalidTransition, plan(&state, &.{ .turn_started, .turn_committed, .{ .item = .{ .type = "assistant", .data = "{}" } } }, &out));
    try plan(&state, &.{ .turn_started, .{ .item = .{ .type = "assistant", .data = "{}" } }, .turn_committed }, &out);
    try testing.expectEqual(@as(u64, 1), out[1].item.turn);
    try testing.expectEqual(@as(u64, 1), out[2].turn_committed.turn);
}

test "child work is finished once, and only after its spawn" {
    var state: State = .{};
    defer state.deinit(testing.allocator);
    const spawn: Event = .{ .child_spawned = .{ .child = "c", .work_id = "w" } };
    const finish: Event = .{ .child_finished = .{ .child = "c", .work_id = "w", .outcome = .ok } };
    var one: [1]schema.Body = undefined;
    var two: [2]schema.Body = undefined;
    try testing.expectError(error.InvalidTransition, plan(&state, &.{finish}, &one));
    try testing.expectError(error.InvalidTransition, plan(&state, &.{ spawn, spawn }, &two));
    try plan(&state, &.{ spawn, finish }, &two);
    try plan(&state, &.{spawn}, &one);
    try apply(testing.allocator, &state, 0, .{ .seq = 1, .offset = 0, .body = one[0] });
    try testing.expectEqual(@as(usize, 1), state.children.items.len);
    try testing.expectError(error.InvalidTransition, plan(&state, &.{ finish, finish }, &two));
    try plan(&state, &.{finish}, &one);
    try apply(testing.allocator, &state, 0, .{ .seq = 2, .offset = 0, .body = one[0] });
    // The child stays listed with its outcome; its work is no longer open.
    try testing.expectEqual(@as(usize, 1), state.children.items.len);
    try testing.expect(!state.children.items[0].open);
    try testing.expectEqual(@as(?schema.Outcome, .ok), state.children.items[0].outcome);
}

test "a child has one unfinished work item, and keeps its newest work, outcome and data" {
    var state: State = .{};
    defer state.deinit(testing.allocator);
    var one: [1]schema.Body = undefined;
    var seq: u64 = 0;
    const steps = [_]Event{
        .{ .child_spawned = .{ .child = "c", .work_id = "w1", .data = "{\"name\":\"reviewer\"}" } },
        .{ .child_finished = .{ .child = "c", .work_id = "w1", .outcome = .failed, .data = "{\"error\":\"e\"}" } },
        .{ .child_spawned = .{ .child = "c", .work_id = "w2" } },
    };
    for (steps) |event| {
        try plan(&state, &.{event}, &one);
        seq += 1;
        try apply(testing.allocator, &state, 0, .{ .seq = seq, .offset = 0, .body = one[0] });
    }
    // A second spawn, or a finish of other work, is refused while w2 is open.
    try testing.expectError(error.InvalidTransition, plan(&state, &.{.{ .child_spawned = .{ .child = "c", .work_id = "w3" } }}, &one));
    try testing.expectError(error.InvalidTransition, plan(&state, &.{.{ .child_finished = .{ .child = "c", .work_id = "w1", .outcome = .ok } }}, &one));
    const child = state.children.items[0];
    try testing.expectEqual(@as(usize, 1), state.children.items.len);
    try testing.expectEqualStrings("w2", child.work_id);
    try testing.expect(child.open);
    try testing.expectEqual(@as(?schema.Outcome, .failed), child.outcome);
    try testing.expectEqual(@as(?[]u8, null), child.spawn_data);
    try testing.expectEqualStrings("{\"error\":\"e\"}", child.finish_data.?);
    try testing.expectEqual(@as(u64, 3), child.seq);
    // The parent cancels it.
    try plan(&state, &.{.{ .child_finished = .{ .child = "c", .work_id = "w2", .outcome = .cancelled } }}, &one);
    try apply(testing.allocator, &state, 0, .{ .seq = 4, .offset = 0, .body = one[0] });
    try testing.expectEqual(@as(?schema.Outcome, .cancelled), state.children.items[0].outcome);
    try testing.expectEqual(@as(?[]u8, null), state.children.items[0].finish_data);
}

test "a fork does not own child lines from before its fork point" {
    var state: State = .{};
    defer state.deinit(testing.allocator);
    const spawned: schema.Body = .{ .child_spawned = .{ .child = "c", .work_id = "w" } };
    try apply(testing.allocator, &state, 5, .{ .seq = 4, .offset = 0, .body = spawned });
    try testing.expectEqual(@as(usize, 0), state.children.items.len);
    try apply(testing.allocator, &state, 5, .{ .seq = 6, .offset = 0, .body = spawned });
    try testing.expectEqual(@as(usize, 1), state.children.items.len);
}

test "resume from the newest snapshot equals a full fold, and snapshots are ignorable" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    for (0..300) |_| {
        var m = MemLog.init();
        defer m.deinit();
        var state: State = .{};
        defer state.deinit(testing.allocator);
        const length = random.uintLessThan(usize, 50);
        for (0..length) |_| {
            if (random.uintLessThan(u8, 6) == 0) {
                // The manager writes a snapshot of the state folded so far.
                var encoded: std.ArrayList(u8) = .empty;
                try encodeState(m.arena.allocator(), &encoded, &state);
                const body: schema.Body = .{ .snapshot = .{ .covers_seq = state.last_seq, .state = encoded.items, .compaction_offset = state.compaction_offset } };
                try m.add(body);
                try apply(testing.allocator, &state, 0, m.lines.items[m.lines.items.len - 1]);
                continue;
            }
            var out: [1]schema.Body = undefined;
            plan(&state, &.{randomEvent(random)}, &out) catch continue;
            try m.add(out[0]);
            try apply(testing.allocator, &state, 0, m.lines.items[m.lines.items.len - 1]);
        }
        var full = try m.fullFold(false);
        defer full.deinit(testing.allocator);
        var resumed = try m.resumeFold();
        defer resumed.deinit(testing.allocator);
        var stripped = try m.fullFold(true);
        defer stripped.deinit(testing.allocator);
        try testing.expect(full.eql(&state));
        try testing.expect(resumed.eql(&full)); // ResumeEqualsFullReplay
        stripped.last_seq = full.last_seq; // stripping renumbers nothing but removes lines
        stripped.clean_exit = full.clean_exit;
        try testing.expect(stripped.eql(&full)); // SnapshotsAreIgnorable
    }
}

test "snapshot state round trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var state: State = .{ .open_turn = 3, .last_turn = 3, .committed = 2, .last_interrupted = .{ .turn = 1, .reason = .crash } };
    defer state.deinit(testing.allocator);
    state.title = try testing.allocator.dupe(u8, "\"a \\\"title\\\"\"");
    state.language = try testing.allocator.dupe(u8, "\"und-Latn\"");
    // The JSON `null` as a value is kept apart from no value.
    state.usage = try testing.allocator.dupe(u8, "null");
    try state.children.append(testing.allocator, .{
        .id = try testing.allocator.dupe(u8, "c\"1"),
        .work_id = try testing.allocator.dupe(u8, "w"),
        .open = false,
        .outcome = .cancelled,
        .spawn_data = try testing.allocator.dupe(u8, "{\"name\": \"a, b\", \"n\": [1, 2]}"),
        .finish_data = try testing.allocator.dupe(u8, "null"),
        .seq = 9,
    });
    try state.children.append(testing.allocator, .{
        .id = try testing.allocator.dupe(u8, "c2"),
        .work_id = try testing.allocator.dupe(u8, "w"),
        .seq = 10,
        .abandoned = true,
    });
    try state.dropped.append(testing.allocator, .{ .turn = 2, .through = 3 });
    try state.dropped.append(testing.allocator, .{ .turn = 4, .through = 4, .from = 3, .at = 40 });
    var out: std.ArrayList(u8) = .empty;
    try encodeState(arena.allocator(), &out, &state);
    var decoded = try decodeState(testing.allocator, arena.allocator(), out.items);
    defer decoded.deinit(testing.allocator);
    try testing.expect(decoded.eql(&state));
    try testing.expectEqualStrings("null", decoded.usage.?);
    try testing.expectEqual(@as(?[]u8, null), decoded.prefs);
}

test "a rewind drops turns between turns and abandons only idle children" {
    var state: State = .{};
    defer state.deinit(testing.allocator);
    var one: [1]schema.Body = undefined;
    var seq: u64 = 0;
    const steps = [_]Event{
        .turn_started,
        .{ .child_spawned = .{ .child = "early", .work_id = "w1" } },
        .{ .child_finished = .{ .child = "early", .work_id = "w1", .outcome = .ok } },
        .turn_committed,
        .turn_started,
        .{ .child_spawned = .{ .child = "late", .work_id = "w2" } },
    };
    for (steps) |event| {
        try plan(&state, &.{event}, &one);
        seq += 1;
        try apply(testing.allocator, &state, 0, .{ .seq = seq, .offset = 0, .body = one[0] });
    }
    // Not inside a turn, not past the newest turn, not over running work.
    try testing.expectError(error.InvalidTransition, plan(&state, &.{.{ .rewound = .{ .turn = 2 } }}, &one));
    try plan(&state, &.{.turn_committed}, &one);
    seq += 1;
    try apply(testing.allocator, &state, 0, .{ .seq = seq, .offset = 0, .body = one[0] });
    try testing.expectError(error.InvalidTransition, plan(&state, &.{.{ .rewound = .{ .turn = 3 } }}, &one));
    try testing.expectError(error.InvalidTransition, plan(&state, &.{.{ .rewound = .{ .turn = 2, .abandoned = &.{"late"} } }}, &one));
    try testing.expectError(error.InvalidTransition, plan(&state, &.{.{ .rewound = .{ .turn = 2, .abandoned = &.{"ghost"} } }}, &one));
    try plan(&state, &.{.{ .child_finished = .{ .child = "late", .work_id = "w2", .outcome = .ok } }}, &one);
    seq += 1;
    try apply(testing.allocator, &state, 0, .{ .seq = seq, .offset = 0, .body = one[0] });
    try plan(&state, &.{.{ .rewound = .{ .turn = 2, .abandoned = &.{"late"} } }}, &one);
    try testing.expectEqual(@as(u64, 2), one[0].rewound.through);
    seq += 1;
    try apply(testing.allocator, &state, 0, .{ .seq = seq, .offset = 0, .body = one[0] });
    try testing.expect(state.droppedTurn(2));
    try testing.expect(!state.droppedTurn(1));
    try testing.expect(!state.children.items[0].abandoned);
    try testing.expect(state.children.items[1].abandoned);
    // The next turn is numbered past the dropped ones, and an abandoned
    // child takes no more work.
    try plan(&state, &.{.turn_started}, &one);
    try testing.expectEqual(@as(u64, 3), one[0].turn_started.turn);
    try testing.expectError(error.InvalidTransition, plan(&state, &.{.{ .child_spawned = .{ .child = "late", .work_id = "w3" } }}, &one));
    try plan(&state, &.{.{ .child_spawned = .{ .child = "early", .work_id = "w3" } }}, &one);
}

test "a rewind to a checkpoint drops part of the open turn only" {
    var state: State = .{};
    defer state.deinit(testing.allocator);
    var one: [1]schema.Body = undefined;
    var seq: u64 = 0;
    const steps = [_]Event{
        .turn_started,
        .{ .item = .{ .type = "user", .data = "{}" } },
        .{ .child_spawned = .{ .child = "scout", .work_id = "w1" } },
        .{ .child_finished = .{ .child = "scout", .work_id = "w1", .outcome = .ok } },
    };
    for (steps) |event| {
        try plan(&state, &.{event}, &one);
        seq += 1;
        try apply(testing.allocator, &state, 0, .{ .seq = seq, .offset = 0, .body = one[0] });
    }
    // Only inside the turn it names, and a whole-turn rewind is still
    // refused inside a turn.
    try testing.expectError(error.InvalidTransition, plan(&state, &.{.{ .rewound = .{ .turn = 2, .from = 3 } }}, &one));
    try testing.expectError(error.InvalidTransition, plan(&state, &.{.{ .rewound = .{ .turn = 1 } }}, &one));
    try plan(&state, &.{.{ .rewound = .{ .turn = 1, .from = 3, .abandoned = &.{"scout"} } }}, &one);
    try testing.expectEqual(@as(u64, 1), one[0].rewound.through);
    seq += 1;
    try apply(testing.allocator, &state, 0, .{ .seq = seq, .offset = 0, .body = one[0] });
    // The turn stays, its later items too, and the child is abandoned.
    try testing.expect(!state.droppedTurn(1));
    const range = state.dropped.items[0];
    try testing.expect(range.dropsItem(1, 3));
    try testing.expect(!range.dropsItem(1, 2));
    try testing.expect(!range.dropsItem(2, 3));
    try testing.expect(!range.dropsItem(1, seq + 1));
    try testing.expect(state.children.items[0].abandoned);
    try plan(&state, &.{.{ .item = .{ .type = "assistant", .data = "{}" } }}, &one);
    try testing.expectEqual(@as(u64, 1), one[0].item.turn);
}
