//! The publication core, checked against a formal model: one session moving
//! its staged facts into the profile ledger in this order, across crashes:
//!
//!   marker → persist (staged) → append → settle → persist → clear marker
//!
//! The I/O layer (src/usage/io/worker.zig) asks `checkpoint` before every
//! session persist and reports what it did as events. Each event is checked
//! against the order the model allows, so the worker can't, for instance,
//! publish a fact whose staging checkpoint isn't durable, and each one writes
//! the model actions it took to the trace (machine `publication`).
//!
//! Pure: no I/O, no clock, no allocation, no globals. A fact is named by its
//! call sequence. Volatile state (the backlog in memory, the totals) lives in
//! the ledger core; this machine keeps the durable side: whether the marker
//! exists, and which staged facts the last durable checkpoint holds.
//!
//! The ledger owes the profile more than staged facts (waiting entries,
//! incidents, an unsettled sequence gap), and every owed checkpoint needs the
//! marker first. That is stricter than the model's `Owes(backlog)`, so every
//! marker write and clear the Zig does is one the model allows.

const std = @import("std");
const trace = @import("../trace.zig");

pub const Sequence = u64;

/// At most this many staged facts are in one checkpoint (the ledger core's
/// `Limits.ceiling`).
pub const max_staged = 64;

/// What a checkpoint about to be persisted holds, as this machine sees it.
pub const Projection = struct {
    /// Its staged facts. At most `max_staged`, each once.
    staged: []const Sequence,
    /// Whether it owes the profile ledger anything: staged facts, waiting
    /// entries, incidents, or calls not yet settled through.
    owes: bool,
};

pub const Event = union(enum) {
    /// The session opened from its saved checkpoint, after a crash or a
    /// clean exit. `marker` is whether the marker file exists now.
    restart: struct { saved: Projection, marker: bool },
    /// The marker is durable (written, or a valid one kept).
    marker_written,
    /// `checkpoint` is durable in the session store.
    persisted: Projection,
    /// The marker is unlinked and its directory fsynced.
    marker_cleared,
    /// The profile ledger answered appended or duplicate for a staged fact.
    appended: Sequence,
    /// The ledger core settled an appended fact (`publish`).
    settled: Sequence,
    /// The profile ledger answered conflict, and the ledger core dropped the
    /// fact (`publish_conflict`).
    conflict: Sequence,
};

pub const StepError = error{
    /// The fact isn't in the last durable checkpoint.
    NotDurable,
    /// `settled` for a fact the profile hasn't accepted in this run.
    NotAppended,
    /// A checkpoint that owes the ledger, persisted without the marker.
    MarkerMissing,
    /// `marker_cleared` while the durable checkpoint still owes the ledger.
    StillOwed,
    TooManyStaged,
};

/// What the I/O layer must do before persisting a checkpoint, and after.
pub const Plan = struct {
    /// Make the marker durable first (markers.prepareCheckpoint).
    write_marker: bool,
    /// After the persist succeeds, clear the marker (markers.finishCheckpoint).
    clear_marker: bool,
};

const Set = struct {
    items: [max_staged]Sequence = undefined,
    len: usize = 0,

    fn slice(set: *const Set) []const Sequence {
        return set.items[0..set.len];
    }

    fn contains(set: *const Set, sequence: Sequence) bool {
        return std.mem.indexOfScalar(Sequence, set.slice(), sequence) != null;
    }

    fn add(set: *Set, sequence: Sequence) error{TooManyStaged}!void {
        if (set.contains(sequence)) return;
        if (set.len == max_staged) return error.TooManyStaged;
        set.items[set.len] = sequence;
        set.len += 1;
    }

    fn remove(set: *Set, sequence: Sequence) void {
        const index = std.mem.indexOfScalar(Sequence, set.slice(), sequence) orelse return;
        set.items[index] = set.items[set.len - 1];
        set.len -= 1;
    }

    fn fill(set: *Set, sequences: []const Sequence) error{TooManyStaged}!void {
        set.len = 0;
        for (sequences) |sequence| try set.add(sequence);
    }

    fn eql(set: *const Set, sequences: []const Sequence) bool {
        if (set.len != sequences.len) return false;
        for (sequences) |sequence| if (!set.contains(sequence)) return false;
        return true;
    }
};

pub const Machine = struct {
    /// Whether the marker is durable.
    marker: bool = false,
    /// The staged facts in the last durable checkpoint (the model's dBacklog).
    saved: Set = .{},
    saved_owes: bool = false,
    /// Facts the profile accepted in this run, not yet settled.
    appended: Set = .{},
    /// A fact settled or dropped since the last durable checkpoint, so the
    /// next one differs from it even where the staged sets agree.
    changed: bool = false,

    /// What to do around persisting `next`.
    pub fn checkpoint(machine: *const Machine, next: Projection) Plan {
        return .{
            // Every owed checkpoint needs the marker first. A marker that
            // exists is kept (or rewritten if it vanished) by the I/O layer.
            .write_marker = next.owes,
            .clear_marker = !next.owes and machine.marker,
        };
    }

    /// Applies one event and writes its model actions when given a writer.
    /// Errors leave the machine unchanged. A failed trace write is returned
    /// after the step took effect.
    pub fn step(machine: *Machine, event: Event, tracer: ?*trace.Writer) (StepError || std.Io.Writer.Error)!void {
        const writer = trace.on(tracer);
        switch (event) {
            .restart => |e| {
                var saved: Set = .{};
                try saved.fill(e.saved.staged);
                machine.* = .{ .marker = e.marker, .saved = saved, .saved_owes = e.saved.owes };
                if (writer) |w| try machine.record(w, "restart", 0, machine.saved.len);
            },
            .marker_written => {
                const was = machine.marker;
                machine.marker = true;
                if (!was) if (writer) |w| try machine.record(w, "write_marker", 0, machine.saved.len);
            },
            .persisted => |next| {
                if (next.owes and !machine.marker) return error.MarkerMissing;
                var staged: Set = .{};
                try staged.fill(next.staged);
                // Facts the last durable checkpoint already held. If any it held
                // are gone, or one settled since, the rest of memory changed.
                var kept: usize = 0;
                for (staged.slice()) |sequence| kept += @intFromBool(machine.saved.contains(sequence));
                const differs = machine.changed or kept != machine.saved.len;
                const was = machine.saved;
                machine.saved = staged;
                machine.saved_owes = next.owes;
                machine.changed = false;
                const w = writer orelse return;
                // The model's Persist makes memory durable without the fresh
                // facts, then Stage(f) stages and persists each of them.
                if (differs) try machine.record(w, "persist", 0, kept);
                var count = kept;
                for (staged.slice()) |sequence| {
                    if (was.contains(sequence)) continue;
                    count += 1;
                    try machine.record(w, "stage", sequence, count);
                }
            },
            .marker_cleared => {
                if (machine.saved.len != 0 or machine.saved_owes) return error.StillOwed;
                const was = machine.marker;
                machine.marker = false;
                if (was) if (writer) |w| try machine.record(w, "clear_marker", 0, machine.saved.len);
            },
            .appended => |sequence| {
                if (!machine.saved.contains(sequence)) return error.NotDurable;
                try machine.appended.add(sequence);
                if (writer) |w| try machine.record(w, "append", sequence, machine.saved.len);
            },
            .settled => |sequence| {
                if (!machine.appended.contains(sequence)) return error.NotAppended;
                machine.appended.remove(sequence);
                machine.changed = true;
                if (writer) |w| try machine.record(w, "settle", sequence, machine.saved.len);
            },
            .conflict => |sequence| {
                if (!machine.saved.contains(sequence)) return error.NotDurable;
                machine.changed = true;
                if (writer) |w| try machine.record(w, "conflict", sequence, machine.saved.len);
            },
        }
    }

    /// `saved` is the durable staged count after this model action.
    fn record(machine: *const Machine, writer: *trace.Writer, event: []const u8, fact: Sequence, saved: usize) std.Io.Writer.Error!void {
        try writer.write(.{
            .machine = "publication",
            .instance = "session",
            .event = event,
            .from = "-",
            .to = "-",
            .data = &.{
                .{ .name = "fact", .value = .{ .int = std.math.cast(i64, fact) orelse return error.WriteFailed } },
                .{ .name = "marker", .value = .{ .boolean = machine.marker } },
                .{ .name = "saved", .value = .{ .int = @intCast(saved) } },
            },
        });
    }
};

// Tests ---------------------------------------------------------------------

const testing = std.testing;

fn run(machine: *Machine, events: []const Event, writer: ?*trace.Writer) !void {
    for (events) |event| try machine.step(event, writer);
}

test "the design's order: marker, persist, append, settle, persist, clear" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var writer: trace.Writer = .init(&buffer.writer);
    var m: Machine = .{};

    const staged: Projection = .{ .staged = &.{3}, .owes = true };
    try testing.expectEqual(Plan{ .write_marker = true, .clear_marker = false }, m.checkpoint(staged));
    try run(&m, &.{ .marker_written, .{ .persisted = staged }, .{ .appended = 3 }, .{ .settled = 3 } }, &writer);
    const done: Projection = .{ .staged = &.{}, .owes = false };
    try testing.expectEqual(Plan{ .write_marker = false, .clear_marker = true }, m.checkpoint(done));
    try run(&m, &.{ .{ .persisted = done }, .marker_cleared }, &writer);
    try testing.expectEqual(Plan{ .write_marker = false, .clear_marker = false }, m.checkpoint(done));

    try testing.expectEqualStrings(
        \\{"v":1,"seq":1,"machine":"publication","inst":"session","event":"write_marker","from":"-","to":"-","effects":[],"data":{"fact":0,"marker":true,"saved":0}}
        \\{"v":1,"seq":2,"machine":"publication","inst":"session","event":"stage","from":"-","to":"-","effects":[],"data":{"fact":3,"marker":true,"saved":1}}
        \\{"v":1,"seq":3,"machine":"publication","inst":"session","event":"append","from":"-","to":"-","effects":[],"data":{"fact":3,"marker":true,"saved":1}}
        \\{"v":1,"seq":4,"machine":"publication","inst":"session","event":"settle","from":"-","to":"-","effects":[],"data":{"fact":3,"marker":true,"saved":1}}
        \\{"v":1,"seq":5,"machine":"publication","inst":"session","event":"persist","from":"-","to":"-","effects":[],"data":{"fact":0,"marker":true,"saved":0}}
        \\{"v":1,"seq":6,"machine":"publication","inst":"session","event":"clear_marker","from":"-","to":"-","effects":[],"data":{"fact":0,"marker":false,"saved":0}}
        \\
    , buffer.written());
}

test "nothing publishes before its staging checkpoint is durable" {
    var m: Machine = .{};
    try testing.expectError(error.NotDurable, m.step(.{ .appended = 3 }, null));
    try testing.expectError(error.NotDurable, m.step(.{ .conflict = 3 }, null));
    try testing.expectError(error.NotAppended, m.step(.{ .settled = 3 }, null));
    try m.step(.marker_written, null);
    try m.step(.{ .persisted = .{ .staged = &.{3}, .owes = true } }, null);
    try m.step(.{ .appended = 3 }, null);
    try testing.expectError(error.NotAppended, m.step(.{ .settled = 4 }, null));
}

test "an owed checkpoint needs the marker, and the marker stays while owed" {
    var m: Machine = .{};
    try testing.expectError(error.MarkerMissing, m.step(.{ .persisted = .{ .staged = &.{3}, .owes = true } }, null));
    // Owed for other reasons (a waiting lookup) with nothing staged.
    try testing.expectError(error.MarkerMissing, m.step(.{ .persisted = .{ .staged = &.{}, .owes = true } }, null));
    try m.step(.marker_written, null);
    try m.step(.{ .persisted = .{ .staged = &.{}, .owes = true } }, null);
    try testing.expectError(error.StillOwed, m.step(.marker_cleared, null));
    try m.step(.{ .persisted = .{ .staged = &.{}, .owes = false } }, null);
    try m.step(.marker_cleared, null);
    try testing.expect(!m.marker);
}

test "a restart picks up the durable side: saved facts publish without staging again" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var writer: trace.Writer = .init(&buffer.writer);
    var m: Machine = .{ .marker = true };
    try m.step(.{ .restart = .{ .saved = .{ .staged = &.{ 4, 5 }, .owes = true }, .marker = true } }, &writer);
    try testing.expect(m.marker and m.saved.len == 2);
    try m.step(.{ .appended = 5 }, &writer);
    try m.step(.{ .settled = 5 }, &writer);
    try m.step(.{ .conflict = 4 }, &writer);
    // The next checkpoint drops both without staging anything.
    try m.step(.{ .persisted = .{ .staged = &.{}, .owes = false } }, &writer);
    const written = buffer.written();
    try testing.expect(std.mem.indexOf(u8, written, "\"event\":\"stage\"") == null);
    try testing.expect(std.mem.indexOf(u8, written, "\"event\":\"restart\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"event\":\"conflict\",\"from\":\"-\",\"to\":\"-\",\"effects\":[],\"data\":{\"fact\":4") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\"event\":\"persist\""));
}

test "a persist with nothing new for the publication writes nothing" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var writer: trace.Writer = .init(&buffer.writer);
    var m: Machine = .{};
    try m.step(.{ .persisted = .{ .staged = &.{}, .owes = false } }, &writer);
    try m.step(.marker_written, &writer);
    try m.step(.{ .persisted = .{ .staged = &.{2}, .owes = true } }, &writer);
    try m.step(.{ .persisted = .{ .staged = &.{2}, .owes = true } }, &writer);
    // A marker kept, not written: no record.
    try m.step(.marker_written, &writer);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, buffer.written(), "\n"));
}

test "staging and settling in one checkpoint: persist first, then the stage" {
    var buffer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buffer.deinit();
    var writer: trace.Writer = .init(&buffer.writer);
    var m: Machine = .{};
    try run(&m, &.{ .marker_written, .{ .persisted = .{ .staged = &.{1}, .owes = true } }, .{ .appended = 1 }, .{ .settled = 1 } }, null);
    // Fact 1 settled in memory and fact 2 staged; one checkpoint holds both.
    try m.step(.{ .persisted = .{ .staged = &.{2}, .owes = true } }, &writer);
    const written = buffer.written();
    const persist = std.mem.indexOf(u8, written, "\"event\":\"persist\"").?;
    const stage = std.mem.indexOf(u8, written, "\"event\":\"stage\"").?;
    try testing.expect(persist < stage);
    try testing.expect(std.mem.indexOf(u8, written, "\"event\":\"persist\",\"from\":\"-\",\"to\":\"-\",\"effects\":[],\"data\":{\"fact\":0,\"marker\":true,\"saved\":0}") != null);
    try testing.expect(std.mem.indexOf(u8, written, "\"event\":\"stage\",\"from\":\"-\",\"to\":\"-\",\"effects\":[],\"data\":{\"fact\":2,\"marker\":true,\"saved\":1}") != null);
}

test "errors leave the machine unchanged" {
    var m: Machine = .{};
    try run(&m, &.{ .marker_written, .{ .persisted = .{ .staged = &.{1}, .owes = true } } }, null);
    const before = m;
    try testing.expectError(error.StillOwed, m.step(.marker_cleared, null));
    try testing.expectError(error.NotAppended, m.step(.{ .settled = 1 }, null));
    var many: [max_staged + 1]Sequence = undefined;
    for (&many, 0..) |*sequence, index| sequence.* = index + 1;
    try testing.expectError(error.TooManyStaged, m.step(.{ .persisted = .{ .staged = &many, .owes = true } }, null));
    try testing.expectEqual(before.marker, m.marker);
    try testing.expectEqualSlices(Sequence, before.saved.slice(), m.saved.slice());
}
