//! The transcript runtime's side of the transcript window core
//! (`transcript_window.zig`): it reports the runtime's entries to the core as
//! blocks and hands back the entries the core drops.
//!
//! One entry is one block, keyed by its entry id. Rather than hooking every
//! append, the shell walks the entries it has not reported yet at a few sync
//! points (a turn's end, a compaction, cleared lifecycle pins), in list order:
//! a user prompt starts a turn, a pinned tool line opens a live block, a turn
//! summary or cancellation line ends the turn, and any other entry arrives
//! final. A live block finishes once its pin is gone, and every live block
//! finishes when its turn ends. Entry ids only grow, so the entries not
//! reported yet are the ones above `seen_through`, wherever they sit in the
//! list.
//!
//! In a saved session a turn summary also confirms the save: the app commits
//! the finished turn to the session log before it appends the summary
//! (`app_callbacks.finishPromptPresentation`), so every block numbered before
//! the summary's is in the log. Notices are not saved (DESIGN D11).
//!
//! The runtime runs only the core's drops: the main screen keeps its painter, a
//! resize clears and replays the held entries, and Ctrl+O pages through the log
//! (`tests/tla/transcript_window/design/DESIGN.md`, "In fx"). Every applied step
//! is traced under the `transcript_window` scope for the binary driver.

const std = @import("std");
const core = @import("transcript_window.zig");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");
const debug_trace = @import("../../core/shared/debug_trace.zig");

const Allocator = std.mem.Allocator;
const TranscriptEntry = transcript_blocks.TranscriptEntry;

/// Ctrl+O and reprint sizes, in blocks. The runtime does not run those
/// effects yet; the core still needs them.
const config_window = 256;
const config_read_step = 64;
const config_slice = 64;

pub const Shell = struct {
    state: core.State,
    /// Entry ids of the held finished blocks in finish order: the block
    /// numbered `base + i` is `finished.items[i]`.
    finished: std.ArrayList(u32) = .empty,
    base: core.Seq = 0,
    /// The highest entry id reported to the core.
    seen_through: u32 = 0,
    /// Entries the core dropped that the runtime has not removed yet,
    /// because a row of theirs is still on screen.
    pending_drops: std.ArrayList(u32) = .empty,

    pub fn init(is_saved: bool) Shell {
        return .{ .state = core.State.init(.{
            .window = config_window,
            .read_step = config_read_step,
            .slice = config_slice,
            .saved = is_saved,
        }) };
    }

    pub fn deinit(self: *Shell, alloc: Allocator) void {
        self.finished.deinit(alloc);
        self.pending_drops.deinit(alloc);
    }

    pub fn saved(self: *const Shell) bool {
        return self.state.config.saved;
    }

    /// Starts over, for a transcript that was cleared or replaced.
    pub fn reset(self: *Shell, alloc: Allocator) void {
        _ = alloc;
        var finished = self.finished;
        finished.clearRetainingCapacity();
        var pending_drops = self.pending_drops;
        pending_drops.clearRetainingCapacity();
        self.* = init(self.saved());
        self.finished = finished;
        self.pending_drops = pending_drops;
    }

    /// Starts from a transcript rebuilt from the session log: every entry is
    /// a finished block the log holds, and the current cycle starts at the
    /// first of them.
    pub fn resumed(self: *Shell, alloc: Allocator, entries: []const TranscriptEntry) !void {
        self.reset(alloc);
        try self.finished.ensureTotalCapacity(alloc, entries.len);
        for (entries) |entry| {
            self.finished.appendAssumeCapacity(entry.id());
            self.seen_through = @max(self.seen_through, entry.id());
        }
        var ignored: std.ArrayList(u32) = .empty;
        defer ignored.deinit(alloc);
        try self.apply(alloc, .{ .resumed = .{
            .cycle = 0,
            .cycle_first = 0,
            .next_seq = @intCast(entries.len),
        } }, &ignored);
        // The resume path painted the held entries already.
        while (self.state.reprinting) try self.apply(alloc, .reprint_tick, &ignored);
    }

    /// Reports the live blocks that finished and the entries not reported
    /// yet, and appends the ids of the entries the core drops to `drops`.
    pub fn sync(
        self: *Shell,
        alloc: Allocator,
        entries: []const TranscriptEntry,
        drops: *std.ArrayList(u32),
    ) !void {
        try self.finishUnpinned(alloc, entries, drops);
        var highest = self.seen_through;
        for (entries) |entry| {
            const id = entry.id();
            if (id <= self.seen_through) continue;
            highest = @max(highest, id);
            try self.report(alloc, entry, drops);
        }
        self.seen_through = highest;
    }

    /// The session compacted its context: the entries so far belong to the
    /// cycle that just closed.
    pub fn compacted(
        self: *Shell,
        alloc: Allocator,
        entries: []const TranscriptEntry,
        drops: *std.ArrayList(u32),
    ) !void {
        try self.sync(alloc, entries, drops);
        try self.apply(alloc, .compacted, drops);
    }

    /// Finishes the live blocks whose entry is gone or no longer pinned.
    fn finishUnpinned(
        self: *Shell,
        alloc: Allocator,
        entries: []const TranscriptEntry,
        drops: *std.ArrayList(u32),
    ) !void {
        if (self.state.live.len == 0) return;
        var still_live: [core.max_live]bool = @splat(false);
        const live = self.state.live.items();
        for (entries) |entry| {
            if (!isLive(entry)) continue;
            for (live, 0..) |id, index| {
                if (id == entry.id()) still_live[index] = true;
            }
        }
        var done: [core.max_live]core.BlockId = undefined;
        var count: usize = 0;
        for (live, 0..) |id, index| {
            if (still_live[index]) continue;
            done[count] = id;
            count += 1;
        }
        for (done[0..count]) |id| try self.apply(alloc, .{ .block_finished = id }, drops);
    }

    fn report(self: *Shell, alloc: Allocator, entry: TranscriptEntry, drops: *std.ArrayList(u32)) !void {
        const id = entry.id();
        if (entry == .user_turn and !self.state.turn_open) try self.apply(alloc, .turn_started, drops);
        if (turnEnd(entry)) |end| {
            while (self.state.live.len > 0) {
                try self.apply(alloc, .{ .block_finished = self.state.live.ids[0] }, drops);
            }
            try self.apply(alloc, .{ .block_finished = id }, drops);
            if (self.state.turn_open) try self.apply(alloc, .turn_ended, drops);
            if (end == .summary and self.saved()) {
                try self.apply(alloc, .{ .saved_through = self.state.next_seq }, drops);
            }
            return;
        }
        if (isLive(entry) and self.state.turn_open) {
            const out = core.step(self.state, .{ .block_opened = id });
            if (out.rejected == null) {
                self.state = out.state;
                trace(.{ .block_opened = id }, null);
                return;
            }
            // A full live set: the block counts as arrived final.
            traceRejected(.{ .block_opened = id }, out.rejected.?);
        }
        try self.apply(alloc, .{ .block_finished = id }, drops);
    }

    fn apply(self: *Shell, alloc: Allocator, event: core.Event, drops: *std.ArrayList(u32)) !void {
        const out = core.step(self.state, event);
        if (out.rejected) |why| {
            traceRejected(event, why);
            return;
        }
        if (event == .block_finished) try self.finished.append(alloc, @intCast(event.block_finished));
        self.state = out.state;
        trace(event, out.effect);
        if (out.effect) |effect| switch (effect) {
            .drop => |range| try self.drop(alloc, range, drops),
            .paint_final, .repaint_block, .reprint_begin, .reprint_slice, .repaint_live, .ctrlo_show, .read_log => {},
        };
        // Block `base + i` is `finished.items[i]`, through the core's last block.
        std.debug.assert(self.state.next_seq == self.base + self.finished.items.len);
    }

    fn drop(self: *Shell, alloc: Allocator, range: core.Range, drops: *std.ArrayList(u32)) !void {
        // The core drops from the oldest held block, which is `base`.
        std.debug.assert(range.from == self.base and range.to <= self.base + self.finished.items.len);
        const count = range.to - range.from;
        try drops.appendSlice(alloc, self.finished.items[0..count]);
        const rest = self.finished.items[count..];
        std.mem.copyForwards(u32, self.finished.items[0..rest.len], rest);
        self.finished.shrinkRetainingCapacity(rest.len);
        self.base = range.to;
    }
};

/// A lifecycle-pinned tool line changes in place until its pin is released,
/// and a notice marked for replacement until it is replaced.
fn isLive(entry: TranscriptEntry) bool {
    return switch (entry) {
        .raw_bytes => |raw| raw.lifecycle_pinned,
        .semantic_notice => |value| value.pending_replacement,
        else => false,
    };
}

const TurnEnd = enum { summary, cancellation };

fn turnEnd(entry: TranscriptEntry) ?TurnEnd {
    return switch (entry) {
        .raw_bytes => |raw| switch (raw.class) {
            .turn_summary => .summary,
            .turn_cancellation => .cancellation,
            else => null,
        },
        else => null,
    };
}

fn trace(event: core.Event, effect: ?core.Effect) void {
    var event_buf: [96]u8 = undefined;
    var effect_buf: [96]u8 = undefined;
    debug_trace.logf("transcript_window", "step event={s} effect={s}", .{
        describeEvent(&event_buf, event),
        if (effect) |value| describeEffect(&effect_buf, value) else "none",
    });
}

fn traceRejected(event: core.Event, why: core.Rejection) void {
    var event_buf: [96]u8 = undefined;
    debug_trace.logf("transcript_window", "rejected event={s} why={s}", .{ describeEvent(&event_buf, event), @tagName(why) });
}

fn describeEvent(buf: []u8, event: core.Event) []const u8 {
    return switch (event) {
        .block_opened, .block_changed, .block_finished => |id| std.fmt.bufPrint(buf, "{s}:{d}", .{ @tagName(event), id }) catch @tagName(event),
        .saved_through => |seq| std.fmt.bufPrint(buf, "saved_through:{d}", .{seq}) catch "saved_through",
        .resumed => |from| std.fmt.bufPrint(buf, "resumed:{d}:{d}:{d}", .{ from.cycle, from.cycle_first, from.next_seq }) catch "resumed",
        else => @tagName(event),
    };
}

fn describeEffect(buf: []u8, effect: core.Effect) []const u8 {
    return switch (effect) {
        .drop, .reprint_slice, .ctrlo_show => |range| std.fmt.bufPrint(buf, "{s}:{d}:{d}", .{ @tagName(effect), range.from, range.to }) catch @tagName(effect),
        .paint_final => |seq| std.fmt.bufPrint(buf, "paint_final:{d}", .{seq}) catch "paint_final",
        else => @tagName(effect),
    };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn rawEntry(id: u32, class: transcript_blocks.RawEntryClass, pinned: bool) TranscriptEntry {
    return .{ .raw_bytes = .{ .id = id, .bytes = "line\n", .class = class, .lifecycle_pinned = pinned } };
}

fn user(id: u32) TranscriptEntry {
    return .{ .user_turn = .{ .id = id, .turn = .{ .text = @constCast("prompt") } } };
}

fn notice(id: u32) TranscriptEntry {
    return .{ .semantic_notice = .{ .id = id, .topic = "context", .tone = .neutral, .body = "Compacted", .visibility = .full_only } };
}

test "the transcript window shell reports a turn's entries in list order and ends the turn at its summary" {
    const alloc = testing.allocator;
    var shell = Shell.init(true);
    defer shell.deinit(alloc);
    var drops: std.ArrayList(u32) = .empty;
    defer drops.deinit(alloc);
    const entries = [_]TranscriptEntry{ rawEntry(1, .welcome, false), user(2), rawEntry(3, .tool_status, true), rawEntry(4, .turn_summary, false) };
    try shell.sync(alloc, entries[0..3], &drops);
    try testing.expect(shell.state.turn_open);
    try testing.expectEqualSlices(core.BlockId, &.{3}, shell.state.live.items());
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, shell.finished.items);
    // The pin is released and the summary lands: the turn ends, saved.
    const done = [_]TranscriptEntry{ rawEntry(1, .welcome, false), user(2), rawEntry(3, .tool_status, false), rawEntry(4, .turn_summary, false) };
    try shell.sync(alloc, &done, &drops);
    try testing.expect(!shell.state.turn_open);
    try testing.expectEqual(@as(usize, 0), shell.state.live.len);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, shell.finished.items);
    try testing.expectEqual(@as(core.Seq, 4), shell.state.saved_through);
    try testing.expectEqual(@as(usize, 0), drops.items.len);
}

test "the transcript window shell drops a compaction's closed cycle at the next saved turn end, not before" {
    const alloc = testing.allocator;
    var shell = Shell.init(true);
    defer shell.deinit(alloc);
    var drops: std.ArrayList(u32) = .empty;
    defer drops.deinit(alloc);
    var entries: std.ArrayList(TranscriptEntry) = .empty;
    defer entries.deinit(alloc);
    try entries.appendSlice(alloc, &.{ user(1), rawEntry(2, .tool_status, false), rawEntry(3, .turn_summary, false) });
    try shell.sync(alloc, entries.items, &drops);
    // The next turn compacts mid-turn while a tool line is still pinned.
    try entries.appendSlice(alloc, &.{ user(4), rawEntry(5, .tool_status, true) });
    try shell.compacted(alloc, entries.items, &drops);
    try testing.expectEqual(@as(usize, 0), drops.items.len);
    try entries.append(alloc, notice(6));
    entries.items[4] = rawEntry(5, .tool_status, false);
    try entries.append(alloc, rawEntry(7, .turn_summary, false));
    try shell.sync(alloc, entries.items, &drops);
    // Blocks finished before the compaction go: the first turn and the
    // second turn's prompt. The tool line finished after it, so it stays.
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, drops.items);
    try testing.expectEqualSlices(u32, &.{ 5, 6, 7 }, shell.finished.items);
    try testing.expectEqual(@as(core.Seq, 4), shell.base);
}

test "the transcript window shell drops at the turn end of an unsaved session without a save" {
    const alloc = testing.allocator;
    var shell = Shell.init(false);
    defer shell.deinit(alloc);
    var drops: std.ArrayList(u32) = .empty;
    defer drops.deinit(alloc);
    const first = [_]TranscriptEntry{ user(1), rawEntry(2, .turn_summary, false) };
    try shell.sync(alloc, &first, &drops);
    try shell.compacted(alloc, &first, &drops);
    const second = first ++ [_]TranscriptEntry{ user(3), rawEntry(4, .turn_summary, false) };
    try shell.sync(alloc, &second, &drops);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, drops.items);
}

test "the transcript window shell ends a cancelled turn without confirming a save" {
    const alloc = testing.allocator;
    var shell = Shell.init(true);
    defer shell.deinit(alloc);
    var drops: std.ArrayList(u32) = .empty;
    defer drops.deinit(alloc);
    const first = [_]TranscriptEntry{ user(1), rawEntry(2, .turn_summary, false) };
    try shell.sync(alloc, &first, &drops);
    try shell.compacted(alloc, &first, &drops);
    const cancelled = first ++ [_]TranscriptEntry{ user(3), rawEntry(4, .turn_cancellation, false) };
    try shell.sync(alloc, &cancelled, &drops);
    // The closed cycle is saved (the first summary), so it drops at the
    // cancellation's turn end; the cancelled turn itself stays held.
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, drops.items);
    try testing.expectEqualSlices(u32, &.{ 3, 4 }, shell.finished.items);
    try testing.expectEqual(@as(core.Seq, 2), shell.state.saved_through);
}

test "the transcript window shell reports entries inserted mid-list by id and starts over on resume" {
    const alloc = testing.allocator;
    var shell = Shell.init(true);
    defer shell.deinit(alloc);
    var drops: std.ArrayList(u32) = .empty;
    defer drops.deinit(alloc);
    try shell.sync(alloc, &.{ user(1), rawEntry(2, .tool_status, false) }, &drops);
    try shell.sync(alloc, &.{ user(1), notice(3), rawEntry(2, .tool_status, false) }, &drops);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, shell.finished.items);
    try shell.resumed(alloc, &.{ user(10), rawEntry(11, .turn_summary, false) });
    try testing.expectEqualSlices(u32, &.{ 10, 11 }, shell.finished.items);
    try testing.expectEqual(@as(core.Seq, 2), shell.state.saved_through);
    try testing.expect(!shell.state.reprinting and !shell.state.turn_open);
    try testing.expectEqual(@as(u32, 11), shell.seen_through);
}

test "the transcript window shell never drops an unsaved or live entry on seeded random sessions" {
    const alloc = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(20261030);
    const random = prng.random();
    for (0..400) |_| {
        var shell = Shell.init(random.boolean());
        defer shell.deinit(alloc);
        var entries: std.ArrayList(TranscriptEntry) = .empty;
        defer entries.deinit(alloc);
        var drops: std.ArrayList(u32) = .empty;
        defer drops.deinit(alloc);
        var next_id: u32 = 1;
        var turn_open = false;
        // The highest entry id the log holds: set by each turn summary.
        var saved_through_id: u32 = 0;
        for (0..60) |_| {
            // Sessions as the app produces them: tool lines are pinned only
            // inside a turn, and a turn's pins are released before it ends.
            switch (random.uintLessThan(u8, 8)) {
                0 => {
                    try entries.append(alloc, user(next_id));
                    turn_open = true;
                },
                1, 2 => try entries.append(alloc, rawEntry(next_id, .tool_status, turn_open and random.boolean())),
                3 => try entries.append(alloc, notice(next_id)),
                4, 5 => {
                    if (!turn_open) continue;
                    for (entries.items) |*entry| if (entry.* == .raw_bytes) {
                        entry.raw_bytes.lifecycle_pinned = false;
                    };
                    const summary = random.uintLessThan(u8, 4) != 0;
                    try entries.append(alloc, rawEntry(next_id, if (summary) .turn_summary else .turn_cancellation, false));
                    if (summary) saved_through_id = next_id;
                    turn_open = false;
                },
                6 => {
                    const before = drops.items.len;
                    try shell.compacted(alloc, entries.items, &drops);
                    try expectDropsSafe(&shell, entries.items, drops.items[before..], saved_through_id);
                    removeDropped(&entries, drops.items[before..]);
                    continue;
                },
                else => {
                    // A pin released mid-turn.
                    for (entries.items) |*entry| if (entry.* == .raw_bytes and random.boolean()) {
                        entry.raw_bytes.lifecycle_pinned = false;
                    };
                },
            }
            next_id += 1;
            const before = drops.items.len;
            try shell.sync(alloc, entries.items, &drops);
            try expectDropsSafe(&shell, entries.items, drops.items[before..], saved_through_id);
            removeDropped(&entries, drops.items[before..]);
        }
        // Every id is dropped at most once.
        for (drops.items, 0..) |id, index| {
            try testing.expect(std.mem.findScalar(u32, drops.items[index + 1 ..], id) == null);
        }
    }
}

fn expectDropsSafe(shell: *const Shell, entries: []const TranscriptEntry, dropped: []const u32, saved_through_id: u32) !void {
    for (dropped) |id| {
        // A saved session drops only what a turn summary saved.
        if (shell.saved()) try testing.expect(id <= saved_through_id);
        for (entries) |entry| {
            if (entry.id() == id) try testing.expect(!isLive(entry));
        }
    }
}

/// What the runtime does with the drops: it removes those entries.
fn removeDropped(entries: *std.ArrayList(TranscriptEntry), dropped: []const u32) void {
    var kept: usize = 0;
    for (entries.items) |entry| {
        if (std.mem.findScalar(u32, dropped, entry.id()) != null) continue;
        entries.items[kept] = entry;
        kept += 1;
    }
    entries.shrinkRetainingCapacity(kept);
}
