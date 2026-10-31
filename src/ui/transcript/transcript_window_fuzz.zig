//! Fuzz target for the transcript window core: arbitrary event sequences,
//! crashes resumed from a simulated session log included, checked after every
//! step against the laws of `tests/tla/transcript_window/spec/TranscriptWindow.tla`.
//!
//! This file holds only tests, so the core itself keeps importing nothing but
//! `std` and its own tests run standalone.

const std = @import("std");
const tw = @import("transcript_window.zig");

const max_steps = 96;
const max_seq = max_steps + 1;

const FuzzDraws = struct {
    smith: *std.testing.Smith,

    fn below(self: FuzzDraws, n: usize, site: u32) usize {
        return self.smith.indexWithHash(n, site);
    }
};

const SeededDraws = struct {
    random: std.Random,

    fn below(self: SeededDraws, n: usize, _: u32) usize {
        return self.random.uintLessThan(usize, n);
    }
};

/// What the session log and the screen hold, kept apart from the core so the
/// oracle never trusts the core's own view of them.
const World = struct {
    /// Blocks below this number are in the log: the furthest save the shell
    /// reported, clamped to the blocks that had finished.
    log_saved: tw.Seq = 0,
    cycle_starts: [max_seq]tw.Seq = undefined,
    starts: usize = 0,
    painted: std.StaticBitSet(max_seq) = .empty,

    fn addStart(self: *World, start: tw.Seq) void {
        for (self.cycle_starts[0..self.starts]) |known| if (known == start) return;
        self.cycle_starts[self.starts] = start;
        self.starts += 1;
    }

    /// The newest compaction the log holds at or below `saved`.
    fn lastStart(self: *World, saved: tw.Seq) tw.Seq {
        var kept: usize = 0;
        var last: tw.Seq = 0;
        for (self.cycle_starts[0..self.starts]) |start| {
            if (start > saved) continue;
            self.cycle_starts[kept] = start;
            kept += 1;
            last = @max(last, start);
        }
        self.starts = kept;
        return last;
    }
};

const Draw = union(enum) {
    event: tw.Event,
    /// The process dies; a new one resumes from the log.
    crash,
    /// The same process restarts the window from the log, as a /resume does.
    resume_in_place,
};

fn drawEvent(draws: anytype, state: *const tw.State) Draw {
    const live = state.live.items();
    const id: tw.BlockId = if (live.len > 0 and draws.below(4, 11) != 0) live[draws.below(live.len, 12)] else 1 + draws.below(6, 13);
    const token: tw.Token = if (state.ctrlo.pending != 0 and draws.below(3, 14) != 0)
        state.ctrlo.pending
    else
        @intCast(draws.below(state.next_token + 2, 15));
    return .{ .event = switch (draws.below(18, 10)) {
        0 => .turn_started,
        1 => .turn_ended,
        2 => .{ .block_opened = id },
        3 => .{ .block_changed = id },
        4, 5 => .{ .block_finished = id },
        6 => .{ .saved_through = @intCast(draws.below(state.next_seq + 3, 16)) },
        7 => .compacted,
        8 => .resized,
        9, 10 => .reprint_tick,
        11 => .ctrlo_opened,
        12 => .{ .ctrlo_scrolled = if (draws.below(3, 17) == 0) .newer else .older },
        13 => .ctrlo_closed,
        14 => .{ .log_read_done = .{ .token = token, .count = @intCast(draws.below(state.config.read_step + 3, 18)) } },
        15 => .{ .log_read_failed = token },
        16 => return .crash,
        else => return .resume_in_place,
    } };
}

fn checkStep(before: tw.State, event: tw.Event, out: tw.Output, world: *World) !void {
    const after = out.state;
    const config = before.config;
    if (out.rejected != null) {
        try std.testing.expectEqual(tw.abstract(&before), tw.abstract(&after));
        try std.testing.expect(out.effect == null);
        return;
    }
    switch (event) {
        // L4: a change touches only that block.
        .block_changed => |id| {
            try std.testing.expectEqual(tw.abstract(&before), tw.abstract(&after));
            try std.testing.expectEqual(tw.Effect{ .repaint_block = id }, out.effect.?);
        },
        // L11: only the pending read's reply counts. L21: it brings at most one step.
        .log_read_done => |reply| {
            try std.testing.expectEqual(before.ctrlo.pending, reply.token);
            try std.testing.expect(before.ctrlo.lo -| after.ctrlo.lo <= config.read_step);
            try std.testing.expect(after.ctrlo.hi -| before.ctrlo.hi <= config.read_step);
        },
        // L10: Ctrl+O opens on the newest held blocks.
        .ctrlo_opened => {
            try std.testing.expectEqual(before.next_seq, after.ctrlo.hi);
            try std.testing.expect(after.ctrlo.lo >= before.heldFirst());
        },
        .log_read_failed => |token| try std.testing.expectEqual(before.ctrlo.pending, token),
        .resized, .resumed => world.painted = .empty,
        else => {},
    }
    if (out.effect) |effect| switch (effect) {
        .drop => |range| {
            try std.testing.expect(range.from < range.to);
            try std.testing.expect(range.to <= after.cycle_first); // L2
            if (config.saved) try std.testing.expect(range.to <= world.log_saved); // L3
            try std.testing.expect(!after.turn_open); // L18
        },
        .paint_final => |seq| {
            try std.testing.expectEqual(after.next_seq - 1, seq); // L5
            try std.testing.expect(!world.painted.isSet(seq)); // L20
            world.painted.set(seq);
        },
        .reprint_slice => |range| {
            try std.testing.expect(range.from < range.to and range.to - range.from <= config.slice); // L7
            for (range.from..range.to) |seq| {
                try std.testing.expect(!world.painted.isSet(seq)); // L20
                world.painted.set(seq);
            }
        },
        .read_log => {
            try std.testing.expect(config.saved); // L12
            try std.testing.expect(event != .ctrlo_opened); // L10
        },
        else => {},
    };
    // L1
    if (!after.turn_open and (!config.saved or after.saved_through >= after.cycle_first)) try std.testing.expect(after.prev_first == null);
    if (after.reprinting) {
        // L6
        try std.testing.expect(after.heldFirst() <= after.painted_through and after.painted_through <= after.next_seq);
    } else {
        // L5, L19
        try std.testing.expectEqual(after.next_seq, after.painted_through);
        for (after.heldFirst()..after.next_seq) |seq| try std.testing.expect(world.painted.isSet(seq));
    }
    const co = after.ctrlo;
    if (co.open) try std.testing.expect(co.lo <= co.hi and co.hi <= after.next_seq and co.hi - co.lo <= config.window); // L8
    if (co.pending != 0) try std.testing.expect(co.open); // L9
}

/// Drives the core through up to `max_steps` events that `draws` chooses and
/// checks every step against the model's laws.
fn driveCore(draws: anytype) !void {
    const config: tw.Config = .{
        .window = @intCast(1 + draws.below(4, 1)),
        .read_step = @intCast(1 + draws.below(3, 2)),
        .slice = @intCast(1 + draws.below(3, 3)),
        .saved = draws.below(4, 4) != 0,
    };
    var state = tw.State.init(config);
    var world: World = .{};
    world.addStart(0);
    const steps = 1 + draws.below(max_steps, 5);
    for (0..steps) |_| {
        const drawn = drawEvent(draws, &state);
        var before = state;
        const event: tw.Event = switch (drawn) {
            .event => |event| event,
            .crash, .resume_in_place => restart: {
                // An unsaved session has no log to resume from, as in the model.
                if (!config.saved) continue;
                // A crash starts a new process; a /resume keeps this one.
                if (drawn == .crash) before = tw.State.init(config);
                const saved = world.log_saved;
                break :restart .{ .resumed = .{ .cycle = state.cycle, .cycle_first = world.lastStart(saved), .next_seq = saved } };
            },
        };
        if (event == .saved_through and config.saved) world.log_saved = @max(world.log_saved, @min(event.saved_through, before.next_seq));
        const out = tw.step(before, event);
        try checkStep(before, event, out, &world);
        if (event == .resumed) {
            // L13: everything held is in the log, and nothing earlier survives.
            const after = out.state;
            try std.testing.expectEqual(world.log_saved, after.next_seq);
            try std.testing.expectEqual(world.log_saved, after.saved_through);
            try std.testing.expect(after.prev_first == null and after.live.len == 0 and !after.turn_open);
            try std.testing.expect(!after.ctrlo.open and after.ctrlo.pending == 0);
        }
        if (event == .compacted) world.addStart(before.next_seq);
        state = out.state;
    }
}

fn fuzzCore(_: void, smith: *std.testing.Smith) !void {
    try driveCore(FuzzDraws{ .smith = smith });
}

/// A fuzz corpus entry: the draws `driveCore` reads, one little-endian u64
/// each, as the fuzzer's input format holds them.
fn corpusOf(comptime values: []const u64) []const u8 {
    comptime {
        var bytes: [values.len * 8]u8 = undefined;
        for (values, 0..) |value, index| std.mem.writeInt(u64, bytes[index * 8 ..][0..8], value, .little);
        const final = bytes;
        return &final;
    }
}

test "the transcript window keeps the model's laws on arbitrary event sequences" {
    try std.testing.fuzz({}, fuzzCore, .{
        .corpus = &(.{
            // A saved session, window 2: a turn with two blocks, a save, a
            // compaction, the turn's end, then Ctrl+O scrolled older to the log.
            comptime corpusOf(&.{ 1, 0, 0, 1, 12, 0, 4, 0, 4, 1, 6, 2, 7, 1, 11, 12, 1, 14, 1, 1 }),
        } ++ @import("fuzz_corpus").transcript_window.*),
    });
}

test "the transcript window keeps the model's laws on seeded random event sequences" {
    // The fuzz target's driver with a seeded generator in place of a fuzzer,
    // so every test run walks thousands of sequences, not only the corpus.
    var prng: std.Random.DefaultPrng = .init(20261030);
    for (0..4000) |_| try driveCore(SeededDraws{ .random = prng.random() });
}

test {
    _ = tw;
}
