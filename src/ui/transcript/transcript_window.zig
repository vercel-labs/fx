//! The transcript window: which finished blocks the main screen holds, paints,
//! reprints and drops, and which blocks Ctrl+O shows and reads from the session
//! log.
//!
//! `step` is pure: it maps a state and an event to the next state and at most
//! one effect, with no I/O, clock, or allocation. The transcript runtime owns
//! the block text and runs the effects; with `FX_TLA_NEXT_TRANSCRIPT_WINDOW=1`
//! it drives this core through `transcript_window_shell.zig` and runs its
//! drops. The main screen's paint and resize and Ctrl+O keep their own paths.
//!
//! Blocks are numbered in finish order. The held blocks are
//! `[heldFirst(), next_seq)`: the current compaction cycle, plus the previous
//! one until the first turn end at which the session log holds it.
//!
//! `tests/tla/transcript_window/spec/TranscriptWindow.tla` models this file
//! action for action; `tests/tla/transcript_window/design/DESIGN.md` lists the
//! laws it keeps.

const std = @import("std");

pub const Seq = u32;
pub const BlockId = u64;
pub const Token = u32;

/// Live blocks one state tracks at once. An open beyond this is rejected; the
/// block still finishes through `block_finished` like a block that arrived final.
pub const max_live = 256;

pub const Config = struct {
    /// Blocks Ctrl+O holds at once.
    window: u32,
    /// Blocks one log read asks for.
    read_step: u32,
    /// Blocks one reprint slice writes.
    slice: u32,
    /// False for a `--no-save` session, which has no log to read or resume.
    saved: bool,
};

pub const Dir = enum { older, newer };

pub const Range = struct { from: Seq, to: Seq };

pub const CtrlO = struct {
    open: bool = false,
    lo: Seq = 0,
    hi: Seq = 0,
    at_start: bool = false,
    /// The one read in flight, or 0.
    pending: Token = 0,
    pending_dir: Dir = .older,
};

pub const LiveSet = struct {
    ids: [max_live]BlockId = undefined,
    len: u16 = 0,

    pub fn contains(self: *const LiveSet, id: BlockId) bool {
        return self.indexOf(id) != null;
    }

    pub fn items(self: *const LiveSet) []const BlockId {
        return self.ids[0..self.len];
    }

    fn indexOf(self: *const LiveSet, id: BlockId) ?usize {
        for (self.ids[0..self.len], 0..) |live_id, index| {
            if (live_id == id) return index;
        }
        return null;
    }

    fn with(self: LiveSet, id: BlockId) LiveSet {
        var next = self;
        next.ids[next.len] = id;
        next.len += 1;
        return next;
    }

    fn without(self: LiveSet, id: BlockId) LiveSet {
        var next = self;
        const index = self.indexOf(id) orelse return next;
        next.ids[index] = next.ids[next.len - 1];
        next.len -= 1;
        return next;
    }
};

pub const State = struct {
    config: Config,
    cycle: u32 = 0,
    cycle_first: Seq = 0,
    /// First block of the previous cycles still held, or null.
    prev_first: ?Seq = null,
    next_seq: Seq = 0,
    /// Blocks below this number are in the session log.
    saved_through: Seq = 0,
    live: LiveSet = .{},
    turn_open: bool = false,
    /// Blocks below this number are painted on the current screen.
    painted_through: Seq = 0,
    reprinting: bool = false,
    ctrlo: CtrlO = .{},
    next_token: Token = 1,

    pub fn init(config: Config) State {
        return .{ .config = config };
    }

    pub fn heldFirst(self: *const State) Seq {
        return self.prev_first orelse self.cycle_first;
    }

    pub fn held(self: *const State) Range {
        return .{ .from = self.heldFirst(), .to = self.next_seq };
    }
};

pub const Event = union(enum) {
    turn_started,
    turn_ended,
    block_opened: BlockId,
    block_changed: BlockId,
    block_finished: BlockId,
    saved_through: Seq,
    compacted,
    resized,
    reprint_tick,
    ctrlo_opened,
    ctrlo_scrolled: Dir,
    ctrlo_closed,
    log_read_done: struct { token: Token, count: u32 },
    log_read_failed: Token,
    /// A new process starts from the log's last cycle.
    resumed: struct { cycle: u32, cycle_first: Seq, next_seq: Seq },
};

pub const Effect = union(enum) {
    /// Paint the block that just finished below the painted ones.
    paint_final: Seq,
    /// Repaint one live block in place.
    repaint_block: BlockId,
    /// Clear the screen and scrollback; slices follow.
    reprint_begin,
    reprint_slice: Range,
    /// The reprint reached the newest block: repaint the live blocks below it.
    repaint_live,
    /// Free the text of these blocks; the log keeps them.
    drop: Range,
    ctrlo_show: Range,
    read_log: struct { token: Token, dir: Dir, from: Seq, count: u32 },
};

/// Why `step` left the state unchanged. The shell logs it with what it dropped.
pub const Rejection = enum {
    turn_already_open,
    no_turn_open,
    turn_has_live_blocks,
    block_already_live,
    live_set_full,
    block_not_live,
    save_not_ahead,
    unsaved_session,
    not_reprinting,
    ctrlo_already_open,
    ctrlo_closed,
    read_pending,
    at_edge,
    stale_reply,
};

pub const Output = struct {
    state: State,
    effect: ?Effect = null,
    rejected: ?Rejection = null,
};

fn reject(state: State, why: Rejection) Output {
    return .{ .state = state, .rejected = why };
}

fn canDrop(state: *const State, prev_first: ?Seq, cycle_first: Seq, turn_open: bool, saved_through: Seq) bool {
    if (prev_first == null) return false;
    if (turn_open) return false;
    return !state.config.saved or saved_through >= cycle_first;
}

fn dropEffect(from: Seq, to: Seq) ?Effect {
    return if (from < to) .{ .drop = .{ .from = from, .to = to } } else null;
}

/// Clears the held previous cycles once nothing in them can change and the
/// log holds them, emitting the drop. A reprint skips the dropped blocks.
fn dropIfDone(next: State) Output {
    var out = next;
    if (!canDrop(&out, out.prev_first, out.cycle_first, out.turn_open, out.saved_through)) return .{ .state = out };
    const from = out.prev_first.?;
    out.prev_first = null;
    if (out.reprinting and out.painted_through < out.cycle_first) out.painted_through = out.cycle_first;
    return .{ .state = out, .effect = dropEffect(from, out.cycle_first) };
}

fn show(state: State, lo: Seq, hi: Seq) Output {
    var out = state;
    out.ctrlo.lo = lo;
    out.ctrlo.hi = hi;
    out.ctrlo.at_start = lo == 0;
    return .{ .state = out, .effect = .{ .ctrlo_show = .{ .from = lo, .to = hi } } };
}

fn issueRead(state: State, dir: Dir, from: Seq) Output {
    var out = state;
    const token = out.next_token;
    out.ctrlo.pending = token;
    out.ctrlo.pending_dir = dir;
    out.next_token = if (token == std.math.maxInt(Token)) 1 else token + 1;
    return .{ .state = out, .effect = .{ .read_log = .{
        .token = token,
        .dir = dir,
        .from = from,
        .count = out.config.read_step,
    } } };
}

pub fn step(state: State, event: Event) Output {
    return switch (event) {
        .turn_started => {
            if (state.turn_open) return reject(state, .turn_already_open);
            var next = state;
            next.turn_open = true;
            return .{ .state = next };
        },
        .turn_ended => {
            if (!state.turn_open) return reject(state, .no_turn_open);
            if (state.live.len != 0) return reject(state, .turn_has_live_blocks);
            var next = state;
            next.turn_open = false;
            return dropIfDone(next);
        },
        .block_opened => |id| {
            if (!state.turn_open) return reject(state, .no_turn_open);
            if (state.live.contains(id)) return reject(state, .block_already_live);
            if (state.live.len == max_live) return reject(state, .live_set_full);
            var next = state;
            next.live = state.live.with(id);
            return .{ .state = next };
        },
        .block_changed => |id| {
            if (!state.live.contains(id)) return reject(state, .block_not_live);
            return .{ .state = state, .effect = .{ .repaint_block = id } };
        },
        .block_finished => |id| {
            var next = state;
            next.live = state.live.without(id);
            const seq = state.next_seq;
            next.next_seq = seq + 1;
            if (state.reprinting) return .{ .state = next };
            next.painted_through = seq + 1;
            return .{ .state = next, .effect = .{ .paint_final = seq } };
        },
        .saved_through => |through| {
            if (!state.config.saved) return reject(state, .unsaved_session);
            const clamped = @min(through, state.next_seq);
            if (clamped <= state.saved_through) return reject(state, .save_not_ahead);
            var next = state;
            next.saved_through = clamped;
            return dropIfDone(next);
        },
        .compacted => {
            var next = state;
            next.cycle = state.cycle + 1;
            next.prev_first = state.heldFirst();
            next.cycle_first = state.next_seq;
            return dropIfDone(next);
        },
        .resized => {
            var next = state;
            next.reprinting = true;
            next.painted_through = state.heldFirst();
            return .{ .state = next, .effect = .reprint_begin };
        },
        .reprint_tick => {
            if (!state.reprinting) return reject(state, .not_reprinting);
            var next = state;
            if (state.painted_through >= state.next_seq) {
                next.reprinting = false;
                return .{ .state = next, .effect = .repaint_live };
            }
            const to = @min(state.painted_through + state.config.slice, state.next_seq);
            next.painted_through = to;
            return .{ .state = next, .effect = .{ .reprint_slice = .{ .from = state.painted_through, .to = to } } };
        },
        .ctrlo_opened => {
            if (state.ctrlo.open) return reject(state, .ctrlo_already_open);
            var next = state;
            next.ctrlo.open = true;
            next.ctrlo.pending = 0;
            const lo = @max(state.heldFirst(), state.next_seq -| state.config.window);
            return show(next, lo, state.next_seq);
        },
        .ctrlo_scrolled => |dir| scrolled(state, dir),
        .ctrlo_closed => {
            if (!state.ctrlo.open) return reject(state, .ctrlo_closed);
            var next = state;
            next.ctrlo.open = false;
            next.ctrlo.pending = 0;
            return .{ .state = next };
        },
        .log_read_done => |reply| readDone(state, reply.token, reply.count),
        .log_read_failed => |token| {
            if (!state.ctrlo.open or state.ctrlo.pending == 0 or state.ctrlo.pending != token) return reject(state, .stale_reply);
            var next = state;
            next.ctrlo.pending = 0;
            return .{ .state = next };
        },
        .resumed => |from| {
            var next = State.init(state.config);
            next.cycle = from.cycle;
            next.cycle_first = from.cycle_first;
            next.next_seq = from.next_seq;
            next.saved_through = from.next_seq;
            next.reprinting = true;
            next.painted_through = from.cycle_first;
            return .{ .state = next, .effect = .reprint_begin };
        },
    };
}

fn scrolled(state: State, dir: Dir) Output {
    const co = state.ctrlo;
    if (!co.open) return reject(state, .ctrlo_closed);
    if (co.pending != 0) return reject(state, .read_pending);
    const window = state.config.window;
    const held_first = state.heldFirst();
    switch (dir) {
        .older => {
            if (co.lo == 0) return reject(state, .at_edge);
            if (co.lo > held_first) return show(state, co.lo - 1, @min(co.hi, co.lo - 1 + window));
            if (state.config.saved) return issueRead(state, .older, co.lo);
            var next = state;
            next.ctrlo.at_start = true;
            return .{ .state = next };
        },
        .newer => {
            if (co.hi >= state.next_seq) return reject(state, .at_edge);
            if (co.hi >= held_first) return show(state, @max(co.lo, (co.hi + 1) -| window), co.hi + 1);
            // No log: the dropped blocks are gone, so jump to the first held one.
            if (!state.config.saved) return show(state, held_first, @min(held_first + 1, state.next_seq));
            return issueRead(state, .newer, co.hi);
        },
    }
}

fn readDone(state: State, token: Token, count: u32) Output {
    const co = state.ctrlo;
    if (!co.open or co.pending == 0 or co.pending != token) return reject(state, .stale_reply);
    const available = switch (co.pending_dir) {
        .older => co.lo,
        .newer => state.next_seq - co.hi,
    };
    const n = @min(@min(count, state.config.read_step), available);
    var next = state;
    next.ctrlo.pending = 0;
    switch (co.pending_dir) {
        .older => {
            const lo = co.lo - n;
            var out = show(next, lo, @min(co.hi, lo + state.config.window));
            out.state.ctrlo.at_start = lo == 0 or n == 0;
            return out;
        },
        .newer => {
            const hi = co.hi + n;
            return show(next, @max(co.lo, hi -| state.config.window), hi);
        },
    }
}

/// The state as the TLA+ model's variables, for the drivers.
pub const Abstract = struct {
    cycle: u32,
    cycleFirst: Seq,
    /// The model's `None` is `-1` here; the trace spec maps it.
    prevFirst: i64,
    nextSeq: Seq,
    savedThrough: Seq,
    liveCount: u16,
    turnOpen: bool,
    paintedThrough: Seq,
    reprinting: bool,
    coOpen: bool,
    coLo: Seq,
    coHi: Seq,
    coAtStart: bool,
    pending: Token,
    pendingDir: Dir,
    nextToken: Token,
};

pub fn abstract(state: *const State) Abstract {
    return .{
        .cycle = state.cycle,
        .cycleFirst = state.cycle_first,
        .prevFirst = if (state.prev_first) |first| first else -1,
        .nextSeq = state.next_seq,
        .savedThrough = state.saved_through,
        .liveCount = state.live.len,
        .turnOpen = state.turn_open,
        .paintedThrough = state.painted_through,
        .reprinting = state.reprinting,
        .coOpen = state.ctrlo.open,
        .coLo = state.ctrlo.lo,
        .coHi = state.ctrlo.hi,
        .coAtStart = state.ctrlo.at_start,
        .pending = state.ctrlo.pending,
        .pendingDir = state.ctrlo.pending_dir,
        .nextToken = state.next_token,
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const saved_config: Config = .{ .window = 2, .read_step = 1, .slice = 1, .saved = true };

fn run(state: State, events: []const Event) State {
    var current = state;
    for (events) |event| current = step(current, event).state;
    return current;
}

fn finishBlocks(state: State, count: u32) State {
    var current = state;
    for (0..count) |index| current = step(current, .{ .block_finished = 1000 + index }).state;
    return current;
}

test "block change touches only that block" {
    const base = run(State.init(saved_config), &.{ .turn_started, .{ .block_opened = 7 }, .{ .block_finished = 1 } });
    const out = step(base, .{ .block_changed = 7 });
    try testing.expectEqual(Effect{ .repaint_block = 7 }, out.effect.?);
    try testing.expectEqual(abstract(&base), abstract(&out.state));
    try testing.expectEqual(Rejection.block_not_live, step(base, .{ .block_changed = 8 }).rejected.?);
}

test "a stale read reply changes nothing" {
    var state = finishBlocks(run(State.init(saved_config), &.{.turn_started}), 3);
    state = run(state, &.{ .turn_ended, .{ .saved_through = 3 }, .compacted, .ctrlo_opened });
    try testing.expectEqual(@as(Seq, 3), state.ctrlo.lo);
    const asked = step(state, .{ .ctrlo_scrolled = .older });
    const token = asked.effect.?.read_log.token;
    for ([_]Token{ token + 1, 0 }) |stale| {
        const out = step(asked.state, .{ .log_read_done = .{ .token = stale, .count = 1 } });
        try testing.expectEqual(Rejection.stale_reply, out.rejected.?);
        try testing.expectEqual(abstract(&asked.state), abstract(&out.state));
    }
    const answered = step(asked.state, .{ .log_read_done = .{ .token = token, .count = 1 } });
    try testing.expectEqual(Effect{ .ctrlo_show = .{ .from = 2, .to = 3 } }, answered.effect.?);
    try testing.expectEqual(Rejection.stale_reply, step(answered.state, .{ .log_read_done = .{ .token = token, .count = 1 } }).rejected.?);
}

test "previous cycle stays held through a mid-turn compaction and drops at turn end" {
    var state = finishBlocks(run(State.init(saved_config), &.{ .turn_started, .{ .block_opened = 9 } }), 2);
    state = run(state, &.{ .compacted, .{ .saved_through = 2 } });
    try testing.expectEqual(@as(?Seq, 0), state.prev_first);
    try testing.expect(state.live.contains(9));
    const finished = step(state, .{ .block_finished = 9 });
    try testing.expectEqual(Effect{ .paint_final = 2 }, finished.effect.?);
    const ended = step(finished.state, .turn_ended);
    try testing.expectEqual(Effect{ .drop = .{ .from = 0, .to = 2 } }, ended.effect.?);
    try testing.expectEqual(Range{ .from = 2, .to = 3 }, ended.state.held());
}

test "a compaction between turns drops once saved and an empty cycle emits no drop" {
    const empty = step(State.init(saved_config), .compacted);
    try testing.expect(empty.effect == null);
    try testing.expect(empty.state.prev_first == null);
    const state = step(finishBlocks(State.init(saved_config), 2), .{ .saved_through = 2 }).state;
    try testing.expectEqual(Effect{ .drop = .{ .from = 0, .to = 2 } }, step(state, .compacted).effect.?);
}

test "a drop waits for the log in a saved session" {
    var state = finishBlocks(run(State.init(saved_config), &.{.turn_started}), 2);
    state = run(state, &.{ .compacted, .{ .saved_through = 1 } });
    const early = step(state, .turn_ended);
    try testing.expect(early.effect == null);
    try testing.expectEqual(@as(?Seq, 0), early.state.prev_first);
    const saved = step(early.state, .{ .saved_through = 2 });
    try testing.expectEqual(Effect{ .drop = .{ .from = 0, .to = 2 } }, saved.effect.?);
    try testing.expectEqual(Rejection.save_not_ahead, step(saved.state, .{ .saved_through = 2 }).rejected.?);
    try testing.expectEqual(@as(Seq, 2), step(saved.state, .{ .saved_through = 99 }).state.saved_through);
}

test "resize reprints the held blocks in bounded slices, then the live ones" {
    var state = finishBlocks(run(State.init(saved_config), &.{.turn_started}), 3);
    state = step(state, .resized).state;
    var slices: [4]Range = undefined;
    var count: usize = 0;
    while (true) {
        const out = step(state, .reprint_tick);
        state = out.state;
        switch (out.effect.?) {
            .reprint_slice => |range| {
                slices[count] = range;
                count += 1;
            },
            .repaint_live => break,
            else => return error.UnexpectedEffect,
        }
    }
    try testing.expectEqualSlices(Range, &.{ .{ .from = 0, .to = 1 }, .{ .from = 1, .to = 2 }, .{ .from = 2, .to = 3 } }, slices[0..count]);
    try testing.expect(!state.reprinting);
    try testing.expectEqual(Rejection.not_reprinting, step(state, .reprint_tick).rejected.?);
}

test "a block finished during a reprint is painted by the reprint, once" {
    var state = finishBlocks(State.init(saved_config), 1);
    state = step(state, .resized).state;
    const finished = step(state, .{ .block_finished = 5 });
    try testing.expect(finished.effect == null);
    state = step(finished.state, .reprint_tick).state;
    const second = step(state, .reprint_tick);
    try testing.expectEqual(Effect{ .reprint_slice = .{ .from = 1, .to = 2 } }, second.effect.?);
    try testing.expectEqual(Effect.repaint_live, step(second.state, .reprint_tick).effect.?);
}

test "ctrl-o opens from memory and an unsaved session never reads" {
    var unsaved = saved_config;
    unsaved.saved = false;
    var state = finishBlocks(State.init(unsaved), 3);
    state = step(state, .compacted).state;
    state = finishBlocks(state, 1);
    const opened = step(state, .ctrlo_opened);
    try testing.expectEqual(Effect{ .ctrlo_show = .{ .from = 3, .to = 4 } }, opened.effect.?);
    const older = step(opened.state, .{ .ctrlo_scrolled = .older });
    try testing.expect(older.effect == null);
    try testing.expect(older.state.ctrlo.at_start);
    try testing.expectEqual(Rejection.unsaved_session, step(state, .{ .saved_through = 1 }).rejected.?);
}

test "a garbage reply count is clamped to what exists" {
    var state = finishBlocks(State.init(saved_config), 2);
    state = run(state, &.{ .{ .saved_through = 2 }, .compacted, .ctrlo_opened });
    const asked = step(state, .{ .ctrlo_scrolled = .older });
    const out = step(asked.state, .{ .log_read_done = .{ .token = asked.effect.?.read_log.token, .count = 99 } });
    try testing.expectEqual(Effect{ .ctrlo_show = .{ .from = 1, .to = 2 } }, out.effect.?);
    const a = abstract(&out.state);
    try testing.expect(a.coHi - a.coLo <= saved_config.window);
}

test "resume holds the log's last cycle and reprints it" {
    var state = finishBlocks(run(State.init(saved_config), &.{ .turn_started, .ctrlo_opened }), 2);
    const out = step(state, .{ .resumed = .{ .cycle = 1, .cycle_first = 1, .next_seq = 2 } });
    state = out.state;
    try testing.expectEqual(Effect.reprint_begin, out.effect.?);
    try testing.expectEqual(Range{ .from = 1, .to = 2 }, state.held());
    try testing.expectEqual(@as(Seq, 2), state.saved_through);
    try testing.expect(!state.ctrlo.open and !state.turn_open and state.live.len == 0);
}

test "the core imports only std" {
    const source = @embedFile("transcript_window.zig");
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "@import(\"") orelse continue;
        if (std.mem.indexOf(u8, line, "@embedFile") != null) continue;
        try testing.expect(std.mem.startsWith(u8, line[at..], "@import(\"std\")"));
    }
}
