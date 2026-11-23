//! Writes the cleaned log: a placeholder for each superseded line, a rebuilt
//! snapshot for the one that stays, and every other line copied byte for
//! byte. A running fold of the new lines gives the snapshot its state and
//! its compaction offset, so the offset names the line where it sits now.

const std = @import("std");
const format = @import("prune_format.zig");
const scan = @import("prune_scan.zig");
const schema = @import("schema.zig");
const log_mod = @import("log.zig");
const fold = @import("fold.zig");
const storage = @import("storage.zig");
const fixture = @import("prune_fixture.zig");

/// Writes the cleaned log into `dst` from the lines `plan` describes, in
/// chunks. The caller syncs `dst` and then checks it.
pub fn write(gpa: std.mem.Allocator, s: storage.Storage, src: storage.File, plan: *const scan.Plan, dst: storage.File) format.Error!void {
    var out: Output = .{ .gpa = gpa, .s = s, .file = dst };
    defer out.buf.deinit(gpa);
    var reader = log_mod.ForwardReader.init(gpa, s, src, 0, plan.end, 1);
    defer reader.deinit();
    var parsing = std.heap.ArenaAllocator.init(gpa);
    defer parsing.deinit();
    var state: fold.State = .{};
    defer state.deinit(gpa);
    var fork_seq: u64 = 0;
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(gpa);

    for (plan.lines, 0..) |planned, i| {
        _ = parsing.reset(.retain_capacity);
        const line = (reader.next() catch |err| return format.readError(err)) orelse return error.Damaged;
        if (line.offset != planned.offset) return error.Damaged;
        const offset = out.position();

        if (planned.superseded) {
            line_buf.clearRetainingCapacity();
            try format.appendPlaceholder(gpa, &line_buf, planned.seq, planned.ts);
            try out.append(line_buf.items);
            // What a reader does with a kind it does not know.
            state.last_seq = planned.seq;
            state.clean_exit = false;
            continue;
        }

        const kind = planned.kind orelse {
            // A kind this build does not know, such as a placeholder an earlier
            // cleanup wrote: copied as it is, and folded as readers fold it.
            try out.append(line.bytes);
            state.last_seq = planned.seq;
            state.clean_exit = false;
            continue;
        };
        const body = schema.parseBody(parsing.allocator(), kind, line.body()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadBody => return error.Damaged,
        };
        if (kind == .session_created) fork_seq = format.forkSeqOf(body);

        if (plan.kept_snapshot == i) {
            try rebuildSnapshot(gpa, &state, body, &line_buf, planned, &out);
        } else {
            try out.append(line.bytes);
        }
        try fold.apply(gpa, &state, fork_seq, .{ .seq = planned.seq, .offset = offset, .body = body });
    }
    try out.flush();
}

const Output = struct {
    gpa: std.mem.Allocator,
    s: storage.Storage,
    file: storage.File,
    /// Bytes already written to `file`.
    flushed: u64 = 0,
    buf: std.ArrayList(u8) = .empty,

    fn position(out: *const Output) u64 {
        return out.flushed + out.buf.items.len;
    }

    fn append(out: *Output, bytes: []const u8) format.Error!void {
        try out.buf.appendSlice(out.gpa, bytes);
        if (out.buf.items.len >= format.flush_bytes) try out.flush();
    }

    fn flush(out: *Output) format.Error!void {
        if (out.buf.items.len == 0) return;
        try out.s.writeAt(out.file, out.buf.items, out.flushed);
        out.flushed += out.buf.items.len;
        out.buf.clearRetainingCapacity();
    }
};

/// Writes a snapshot at `seq`, from the state of the lines before it. It covers
/// exactly the line before it, as fx's own snapshots do, so its state and its
/// compaction offset name where it now sits.
fn emitSnapshot(
    gpa: std.mem.Allocator,
    state: *const fold.State,
    seq: u64,
    ts: u64,
    line_buf: *std.ArrayList(u8),
    out: *Output,
) format.Error!void {
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    try fold.encodeState(gpa, &encoded, state);
    const body: schema.Body = .{ .snapshot = .{
        .covers_seq = state.last_seq,
        .state = encoded.items,
        .compaction_offset = state.compaction_offset,
    } };
    var fields: std.ArrayList(u8) = .empty;
    defer fields.deinit(gpa);
    try schema.appendBody(gpa, &fields, body);
    line_buf.clearRetainingCapacity();
    try log_mod.appendLine(gpa, line_buf, seq, ts, .snapshot, fields.items);
    try out.append(line_buf.items);
}

/// Writes the kept snapshot again. It must cover the line before it, or it
/// cannot be written again with the same meaning.
fn rebuildSnapshot(
    gpa: std.mem.Allocator,
    state: *const fold.State,
    body: schema.Body,
    line_buf: *std.ArrayList(u8),
    planned: scan.Line,
    out: *Output,
) format.Error!void {
    const covers = switch (body) {
        .snapshot => |snapshot| snapshot.covers_seq,
        else => return error.Damaged,
    };
    if (covers != state.last_seq) return error.SnapshotNotRebuildable;
    try emitSnapshot(gpa, state, planned.seq, planned.ts, line_buf, out);
}

/// Writes the restored log: every line of the first original, then every line
/// of the current log past the original's last seq. The original's lines are
/// the same bytes, so the seqs they name are the same lines. A snapshot past
/// the original is written again from the fold of the lines before it. A
/// placeholder past the original stood for a snapshot that a repeat cleanup
/// superseded, so it is written again the same way.
pub fn restoreWrite(
    gpa: std.mem.Allocator,
    s: storage.Storage,
    original: storage.File,
    original_end: u64,
    current: storage.File,
    current_end: u64,
    dst: storage.File,
) format.Error!void {
    var out: Output = .{ .gpa = gpa, .s = s, .file = dst };
    defer out.buf.deinit(gpa);
    var state: fold.State = .{};
    defer state.deinit(gpa);
    var parsing = std.heap.ArenaAllocator.init(gpa);
    defer parsing.deinit();
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(gpa);

    var fork_seq: u64 = 0;
    var original_last: u64 = 0;
    var first = log_mod.ForwardReader.init(gpa, s, original, 0, original_end, 1);
    defer first.deinit();
    while (true) {
        _ = parsing.reset(.retain_capacity);
        const line = (first.next() catch |err| return format.readError(err)) orelse break;
        const body = try format.bodyOf(parsing.allocator(), line);
        if (line.header.kind == .session_created) {
            if (body) |known| fork_seq = format.forkSeqOf(known);
        }
        const offset = out.position();
        try out.append(line.bytes);
        try format.foldLine(gpa, &state, fork_seq, line.header.seq, offset, body);
        original_last = line.header.seq;
    }

    var tail = log_mod.ForwardReader.init(gpa, s, current, 0, current_end, 1);
    defer tail.deinit();
    while (true) {
        _ = parsing.reset(.retain_capacity);
        const line = (tail.next() catch |err| return format.readError(err)) orelse break;
        if (line.header.seq <= original_last) continue;
        if (line.header.seq != state.last_seq + 1) return error.Damaged;
        if (try isSnapshotLine(parsing.allocator(), line)) {
            try emitSnapshot(gpa, &state, line.header.seq, line.header.ts_ms, &line_buf, &out);
            state.last_seq = line.header.seq;
            state.clean_exit = false;
            continue;
        }
        const body = try format.bodyOf(parsing.allocator(), line);
        const offset = out.position();
        try out.append(line.bytes);
        try format.foldLine(gpa, &state, fork_seq, line.header.seq, offset, body);
    }
    try out.flush();
}

/// True for a snapshot line, and for a placeholder, which stands for one a
/// repeat cleanup superseded. A snapshot must cover the line before it.
fn isSnapshotLine(arena: std.mem.Allocator, line: log_mod.Line) format.Error!bool {
    if (format.isPlaceholder(line.header)) return true;
    const body = (try format.bodyOf(arena, line)) orelse return false;
    switch (body) {
        .snapshot => |snapshot| {
            if (snapshot.covers_seq != line.header.seq - 1) return error.SnapshotNotRebuildable;
            return true;
        },
        else => return false,
    }
}

test "superseded lines become placeholders with their seq and ts, and every other line is copied byte for byte" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.turn(1);
    try b.legacyUsage();
    try b.turn(2);
    try b.usage(3);
    try b.snapshot();
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try scan.run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);

    const dst = try scratch.s.createFile(dir, "out");
    defer scratch.s.closeFile(dst);
    try write(gpa, scratch.s, log.file, &plan, dst);

    const before = try fixture.splitLines(gpa, b.bytes.items);
    defer gpa.free(before);
    const got_bytes = try fixture.readBytes(gpa, dir, "out");
    defer gpa.free(got_bytes);
    const after = try fixture.splitLines(gpa, got_bytes);
    defer gpa.free(after);

    try std.testing.expectEqual(before.len, after.len);
    const legacy_index: usize = 4;
    const legacy_header = try log_mod.checkLine(before[legacy_index]);
    const placeholder_header = try log_mod.checkLine(after[legacy_index]);
    try std.testing.expect(format.isPlaceholder(placeholder_header));
    try std.testing.expectEqual(legacy_header.seq, placeholder_header.seq);
    try std.testing.expectEqual(legacy_header.ts_ms, placeholder_header.ts_ms);
    for (before, 0..) |line, i| {
        if (i == legacy_index or i == before.len - 1) continue;
        try std.testing.expectEqualSlices(u8, line, after[i]);
    }
    const snapshot_header = try log_mod.checkLine(after[after.len - 1]);
    try std.testing.expectEqual(schema.Kind.snapshot, snapshot_header.kind.?);
}

test "the kept snapshot's compaction offset names the compacted line where it now sits" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.turn(1);
    try b.legacyUsage();
    try b.compacted(1);
    try b.turn(2);
    try b.usage(3);
    try b.snapshot();
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try scan.run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);

    const dst = try scratch.s.createFile(dir, "out");
    defer scratch.s.closeFile(dst);
    try write(gpa, scratch.s, log.file, &plan, dst);

    const before = try fixture.splitLines(gpa, b.bytes.items);
    defer gpa.free(before);
    const got_bytes = try fixture.readBytes(gpa, dir, "out");
    defer gpa.free(got_bytes);
    const after = try fixture.splitLines(gpa, got_bytes);
    defer gpa.free(after);
    const compacted_offset = fixture.offsetOfSeq(after, 6);
    try std.testing.expect(compacted_offset < fixture.offsetOfSeq(before, 6));

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snapshot_line = after[after.len - 1];
    const snapshot = try schema.parseLineBody(arena.allocator(), .snapshot, snapshot_line);
    try std.testing.expectEqual(compacted_offset, snapshot.snapshot.compaction_offset.?);
    var state = try fold.decodeState(gpa, arena.allocator(), snapshot.snapshot.state);
    defer state.deinit(gpa);
    try std.testing.expectEqual(compacted_offset, state.compaction_offset.?);
}

test "a snapshot that does not cover the line before it is refused" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.turn(1);
    try b.snapshotCovering(1);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try scan.run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);
    const dst = try scratch.s.createFile(dir, "out");
    defer scratch.s.closeFile(dst);
    try std.testing.expectError(error.SnapshotNotRebuildable, write(gpa, scratch.s, log.file, &plan, dst));
}
