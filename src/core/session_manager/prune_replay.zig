//! Proves a cleaned log says what the original said. The two logs are read in
//! step, line by line: a placeholder may only replace a dead line and keeps
//! its seq and ts; every other line is byte for byte the same; the folded
//! state matches at each turn boundary and at the end, except for the
//! compaction offset, which moves, and for a legacy usage value, which every
//! reader reads as no totals.

const std = @import("std");
const format = @import("prune_format.zig");
const scan = @import("prune_scan.zig");
const schema = @import("schema.zig");
const log_mod = @import("log.zig");
const fold = @import("fold.zig");
const storage = @import("storage.zig");
const fixture = @import("prune_fixture.zig");
const rewrite = @import("prune_rewrite.zig");

pub fn check(gpa: std.mem.Allocator, s: storage.Storage, original: storage.File, original_end: u64, rewritten: storage.File, rewritten_end: u64) format.Error!void {
    var before = log_mod.ForwardReader.init(gpa, s, original, 0, original_end, 1);
    defer before.deinit();
    var after = log_mod.ForwardReader.init(gpa, s, rewritten, 0, rewritten_end, 1);
    defer after.deinit();
    var parsing = std.heap.ArenaAllocator.init(gpa);
    defer parsing.deinit();
    var old: fold.State = .{};
    defer old.deinit(gpa);
    var new: fold.State = .{};
    defer new.deinit(gpa);
    var fork_seq: u64 = 0;

    while (true) {
        _ = parsing.reset(.retain_capacity);
        const arena = parsing.allocator();
        const old_line = (try nextLine(&before)) orelse {
            if ((try nextLine(&after)) != null) return error.ReplayMismatch;
            break;
        };
        const new_line = (try nextLine(&after)) orelse return error.ReplayMismatch;
        const old_body = try parseKnown(arena, old_line);
        if (old_body) |body| {
            if (old_line.header.kind == .session_created) fork_seq = format.forkSeqOf(body);
        }

        if (format.isPlaceholder(new_line.header) and old_body != null) {
            try checkPlaceholder(old_line, old_body, new_line);
            // What a reader does with a kind it does not know.
            new.last_seq = new_line.header.seq;
            new.clean_exit = false;
        } else {
            try checkCopy(gpa, arena, old_line, new_line, &new, fork_seq);
        }
        try applyKnown(gpa, &old, fork_seq, old_line, old_body);

        if (isTurnEnd(old_line.header)) {
            if (!try sameState(gpa, &old, &new)) return error.ReplayMismatch;
        }
    }
    if (!try sameState(gpa, &old, &new)) return error.ReplayMismatch;
}

/// Proves a restored log against the current log it replaces. Both logs have
/// the same seqs in the same order. A placeholder in the current log stands
/// for a legacy usage line or a snapshot the restore keeps or writes again.
/// Every other line is byte for byte the same, except a snapshot, which is
/// checked against the fold of the restored lines before it. The folded
/// states agree at each turn boundary and at the end.
pub fn checkRestore(gpa: std.mem.Allocator, s: storage.Storage, current: storage.File, current_end: u64, restored: storage.File, restored_end: u64) format.Error!void {
    var before = log_mod.ForwardReader.init(gpa, s, current, 0, current_end, 1);
    defer before.deinit();
    var after = log_mod.ForwardReader.init(gpa, s, restored, 0, restored_end, 1);
    defer after.deinit();
    var parsing = std.heap.ArenaAllocator.init(gpa);
    defer parsing.deinit();
    var old: fold.State = .{};
    defer old.deinit(gpa);
    var new: fold.State = .{};
    defer new.deinit(gpa);
    var old_fork: u64 = 0;
    var new_fork: u64 = 0;

    while (true) {
        _ = parsing.reset(.retain_capacity);
        const arena = parsing.allocator();
        const old_line = (try nextLine(&before)) orelse {
            if ((try nextLine(&after)) != null) return error.ReplayMismatch;
            break;
        };
        const new_line = (try nextLine(&after)) orelse return error.ReplayMismatch;
        if (new_line.header.seq != old_line.header.seq or new_line.header.ts_ms != old_line.header.ts_ms) {
            return error.ReplayMismatch;
        }
        const old_body = try parseKnown(arena, old_line);
        const new_body = (try parseKnown(arena, new_line)) orelse return error.ReplayMismatch;
        if (old_line.header.kind == .session_created) {
            if (old_body) |known| old_fork = format.forkSeqOf(known);
        }
        if (new_line.header.kind == .session_created) new_fork = format.forkSeqOf(new_body);

        switch (new_body) {
            .snapshot => {
                try checkSnapshot(gpa, arena, new_body, &new);
                if (!format.isPlaceholder(old_line.header) and old_line.header.kind != .snapshot) {
                    return error.ReplayMismatch;
                }
            },
            else => {
                if (format.isPlaceholder(old_line.header)) {
                    if (!standsFor(new_body)) return error.ReplayMismatch;
                } else if (!std.mem.eql(u8, old_line.bytes, new_line.bytes)) {
                    return error.ReplayMismatch;
                }
            },
        }
        try applyKnown(gpa, &new, new_fork, new_line, new_body);
        try applyKnown(gpa, &old, old_fork, old_line, old_body);
        if (isTurnEnd(old_line.header)) {
            if (!try sameState(gpa, &old, &new)) return error.ReplayMismatch;
        }
    }
    if (!try sameState(gpa, &old, &new)) return error.ReplayMismatch;
}

/// A line a restore may write in place of a placeholder: a snapshot, or a
/// legacy usage value.
fn standsFor(body: schema.Body) bool {
    return switch (body) {
        .snapshot => true,
        .set => |setting| setting.key == .usage and format.isLegacyUsage(setting.value),
        else => false,
    };
}

fn nextLine(reader: *log_mod.ForwardReader) format.Error!?log_mod.Line {
    return reader.next() catch |err| switch (err) {
        error.Corrupt => error.ReplayMismatch,
        error.OutOfMemory => error.OutOfMemory,
        else => |io_err| io_err,
    };
}

/// The body of a line of a kind this build knows; null for a kind it does not.
fn parseKnown(arena: std.mem.Allocator, line: log_mod.Line) format.Error!?schema.Body {
    const kind = line.header.kind orelse return null;
    return schema.parseBody(arena, kind, line.body()) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadBody => error.ReplayMismatch,
    };
}

/// A placeholder may replace only a line that no reader needs: a legacy usage
/// value, or a snapshot. It keeps the seq and ts of the line it replaces.
fn checkPlaceholder(old_line: log_mod.Line, old_body: ?schema.Body, new_line: log_mod.Line) format.Error!void {
    if (new_line.header.seq != old_line.header.seq or new_line.header.ts_ms != old_line.header.ts_ms) {
        return error.ReplayMismatch;
    }
    const body = old_body orelse return error.ReplayMismatch;
    const replaceable = switch (body) {
        .set => |setting| setting.key == .usage and format.isLegacyUsage(setting.value),
        .snapshot => true,
        else => false,
    };
    if (!replaceable) return error.ReplayMismatch;
}

/// A line that is not a placeholder must be the same line, byte for byte,
/// except a snapshot, which the rewrite rebuilds and this check rebuilds too.
fn checkCopy(gpa: std.mem.Allocator, arena: std.mem.Allocator, old_line: log_mod.Line, new_line: log_mod.Line, new: *fold.State, fork_seq: u64) format.Error!void {
    if (new_line.header.seq != old_line.header.seq) return error.ReplayMismatch;
    if (new_line.header.kind != old_line.header.kind) return error.ReplayMismatch;
    const new_body = try parseKnown(arena, new_line);
    if (new_line.header.kind == .snapshot) {
        try checkSnapshot(gpa, arena, new_body orelse return error.ReplayMismatch, new);
    } else if (!std.mem.eql(u8, old_line.bytes, new_line.bytes)) {
        return error.ReplayMismatch;
    }
    try applyKnown(gpa, new, fork_seq, new_line, new_body);
}

/// The snapshot must cover the line before it, and its state and compaction
/// offset must be the fold of the lines before it, now.
fn checkSnapshot(gpa: std.mem.Allocator, arena: std.mem.Allocator, body: schema.Body, state: *const fold.State) format.Error!void {
    const snapshot = switch (body) {
        .snapshot => |value| value,
        else => return error.ReplayMismatch,
    };
    if (snapshot.covers_seq != state.last_seq) return error.ReplayMismatch;
    var decoded = fold.decodeState(gpa, arena, snapshot.state) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadBody => return error.ReplayMismatch,
    };
    defer decoded.deinit(gpa);
    // The encoded state carries no seq or clean flag: the snapshot line does.
    decoded.last_seq = state.last_seq;
    decoded.clean_exit = state.clean_exit;
    if (snapshot.compaction_offset != state.compaction_offset) return error.ReplayMismatch;
    if (decoded.compaction_offset != state.compaction_offset) return error.ReplayMismatch;
    if (!try sameState(gpa, &decoded, state)) return error.ReplayMismatch;
}

fn applyKnown(gpa: std.mem.Allocator, state: *fold.State, fork_seq: u64, line: log_mod.Line, body: ?schema.Body) format.Error!void {
    return format.foldLine(gpa, state, fork_seq, line.header.seq, line.offset, body);
}

fn isTurnEnd(header: schema.Header) bool {
    return header.kind == .turn_committed or header.kind == .turn_interrupted;
}

/// The state a reader folds from every line of the log.
pub fn foldOf(gpa: std.mem.Allocator, s: storage.Storage, file: storage.File, end: u64) format.Error!fold.State {
    var reader = log_mod.ForwardReader.init(gpa, s, file, 0, end, 1);
    defer reader.deinit();
    var parsing = std.heap.ArenaAllocator.init(gpa);
    defer parsing.deinit();
    var state: fold.State = .{};
    errdefer state.deinit(gpa);
    var fork_seq: u64 = 0;
    while (try nextLine(&reader)) |line| {
        _ = parsing.reset(.retain_capacity);
        const body = try parseKnown(parsing.allocator(), line);
        if (line.header.kind == .session_created) {
            if (body) |known| fork_seq = format.forkSeqOf(known);
        }
        try applyKnown(gpa, &state, fork_seq, line, body);
    }
    return state;
}

/// Two folded states agree. The compaction offset is a byte position, which
/// the rewrite moves, and a legacy usage value reads as no totals, so both are
/// compared as their readers see them: the offset not at all, the usage as
/// its meaning.
pub fn sameState(gpa: std.mem.Allocator, a: *const fold.State, b: *const fold.State) format.Error!bool {
    var ca = try a.clone(gpa);
    defer ca.deinit(gpa);
    var cb = try b.clone(gpa);
    defer cb.deinit(gpa);
    if (!optionalEql(meaningOfUsage(a.usage), meaningOfUsage(b.usage))) return false;
    clearUsage(gpa, &ca);
    clearUsage(gpa, &cb);
    ca.compaction_offset = null;
    cb.compaction_offset = null;
    return ca.eql(&cb);
}

fn meaningOfUsage(raw: ?[]u8) ?[]const u8 {
    const value = raw orelse return null;
    if (format.isLegacyUsage(value)) return null;
    return value;
}

fn clearUsage(gpa: std.mem.Allocator, state: *fold.State) void {
    if (state.usage) |value| gpa.free(value);
    state.usage = null;
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return std.mem.eql(u8, x, y);
}

/// A log the cleanup can work on, with its cleaned copy written by `rewrite`.
const Pair = struct {
    scratch: *fixture.Scratch,
    dir: storage.Dir,
    original: fixture.OpenedLog,
    plan: scan.Plan,

    fn cleaned(pair: *const Pair, name: []const u8) !fixture.OpenedLog {
        const dst = try pair.scratch.s.createFile(pair.dir, name);
        defer pair.scratch.s.closeFile(dst);
        try rewrite.write(std.testing.allocator, pair.scratch.s, pair.original.file, &pair.plan, dst);
        return fixture.openLog(pair.scratch.s, pair.dir, name);
    }
};

fn buildPair(scratch: *fixture.Scratch, b: *const fixture.Builder) !Pair {
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    const original = try scratch.logOf(dir, b);
    const plan = try scan.run(std.testing.allocator, scratch.arena.allocator(), scratch.s, original.file, original.end);
    return .{ .scratch = scratch, .dir = dir, .original = original, .plan = plan };
}

/// Created, a turn, a legacy usage line, a compaction, a turn, a per-reply
/// usage line and a snapshot. The legacy line is superseded.
fn sampleLog(b: *fixture.Builder) !void {
    try b.created("s");
    try b.turn(1);
    try b.legacyUsage();
    try b.compacted(1);
    try b.turn(2);
    try b.usage(3);
    try b.snapshot();
}

test "the honest rewrite passes the replay check" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try sampleLog(&b);
    const pair = try buildPair(&scratch, &b);
    defer scratch.s.closeFile(pair.original.file);
    const cleaned = try pair.cleaned("out");
    defer scratch.s.closeFile(cleaned.file);
    try check(gpa, scratch.s, pair.original.file, pair.original.end, cleaned.file, cleaned.end);
}

test "a rewrite that replaces a turn's line with a placeholder is rejected" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try sampleLog(&b);
    const pair = try buildPair(&scratch, &b);
    defer scratch.s.closeFile(pair.original.file);
    const cleaned = try pair.cleaned("out");
    defer scratch.s.closeFile(cleaned.file);
    const good = try fixture.readBytes(gpa, pair.dir, "out");
    defer gpa.free(good);
    const lines = try fixture.splitLines(gpa, good);
    defer gpa.free(lines);
    const turn_line = lines[1];
    const turn_header = try log_mod.checkLine(turn_line);
    var placeholder: std.ArrayList(u8) = .empty;
    defer placeholder.deinit(gpa);
    try format.appendPlaceholder(gpa, &placeholder, turn_header.seq, turn_header.ts_ms);
    const bad = try fixture.replaceLine(gpa, good, 1, placeholder.items);
    defer gpa.free(bad);
    try fixture.writeRaw(scratch.s, pair.dir, "bad", bad);
    const planted = try fixture.openLog(scratch.s, pair.dir, "bad");
    defer scratch.s.closeFile(planted.file);
    try std.testing.expectError(error.ReplayMismatch, check(gpa, scratch.s, pair.original.file, pair.original.end, planted.file, planted.end));
}

test "a placeholder with the wrong ts is rejected" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try sampleLog(&b);
    const pair = try buildPair(&scratch, &b);
    defer scratch.s.closeFile(pair.original.file);
    const cleaned = try pair.cleaned("out");
    defer scratch.s.closeFile(cleaned.file);
    const good = try fixture.readBytes(gpa, pair.dir, "out");
    defer gpa.free(good);
    const lines = try fixture.splitLines(gpa, good);
    defer gpa.free(lines);
    const legacy_header = try log_mod.checkLine(lines[4]);
    var placeholder: std.ArrayList(u8) = .empty;
    defer placeholder.deinit(gpa);
    try format.appendPlaceholder(gpa, &placeholder, legacy_header.seq, legacy_header.ts_ms + 1);
    const bad = try fixture.replaceLine(gpa, good, 4, placeholder.items);
    defer gpa.free(bad);
    try fixture.writeRaw(scratch.s, pair.dir, "bad", bad);
    const planted = try fixture.openLog(scratch.s, pair.dir, "bad");
    defer scratch.s.closeFile(planted.file);
    try std.testing.expectError(error.ReplayMismatch, check(gpa, scratch.s, pair.original.file, pair.original.end, planted.file, planted.end));
}

test "a placeholder for a per-reply usage line is rejected" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try sampleLog(&b);
    const pair = try buildPair(&scratch, &b);
    defer scratch.s.closeFile(pair.original.file);
    const cleaned = try pair.cleaned("out");
    defer scratch.s.closeFile(cleaned.file);
    const good = try fixture.readBytes(gpa, pair.dir, "out");
    defer gpa.free(good);
    const lines = try fixture.splitLines(gpa, good);
    defer gpa.free(lines);
    const usage_header = try log_mod.checkLine(lines[8]);
    var placeholder: std.ArrayList(u8) = .empty;
    defer placeholder.deinit(gpa);
    try format.appendPlaceholder(gpa, &placeholder, usage_header.seq, usage_header.ts_ms);
    const bad = try fixture.replaceLine(gpa, good, 8, placeholder.items);
    defer gpa.free(bad);
    try fixture.writeRaw(scratch.s, pair.dir, "bad", bad);
    const planted = try fixture.openLog(scratch.s, pair.dir, "bad");
    defer scratch.s.closeFile(planted.file);
    try std.testing.expectError(error.ReplayMismatch, check(gpa, scratch.s, pair.original.file, pair.original.end, planted.file, planted.end));
}

test "a kept snapshot whose compaction offset is stale is rejected" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try sampleLog(&b);
    const pair = try buildPair(&scratch, &b);
    defer scratch.s.closeFile(pair.original.file);
    const cleaned = try pair.cleaned("out");
    defer scratch.s.closeFile(cleaned.file);
    const good = try fixture.readBytes(gpa, pair.dir, "out");
    defer gpa.free(good);
    const lines = try fixture.splitLines(gpa, good);
    defer gpa.free(lines);
    const last = lines.len - 1;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const snapshot = try schema.parseLineBody(arena.allocator(), .snapshot, lines[last]);
    const snapshot_header = try log_mod.checkLine(lines[last]);
    var state = try fold.decodeState(gpa, arena.allocator(), snapshot.snapshot.state);
    defer state.deinit(gpa);
    state.compaction_offset = state.compaction_offset.? + 1;
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    try fold.encodeState(gpa, &encoded, &state);
    const stale = try fixture.snapshotLine(gpa, snapshot_header.seq, snapshot_header.ts_ms, snapshot.snapshot.covers_seq, encoded.items, state.compaction_offset);
    defer gpa.free(stale);
    const bad = try fixture.replaceLine(gpa, good, last, stale);
    defer gpa.free(bad);
    try fixture.writeRaw(scratch.s, pair.dir, "bad", bad);
    const planted = try fixture.openLog(scratch.s, pair.dir, "bad");
    defer scratch.s.closeFile(planted.file);
    try std.testing.expectError(error.ReplayMismatch, check(gpa, scratch.s, pair.original.file, pair.original.end, planted.file, planted.end));
}
