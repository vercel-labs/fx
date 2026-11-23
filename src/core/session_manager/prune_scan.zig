//! Reads a whole log and decides which lines the cleanup replaces. The
//! decision is plain: a legacy usage line that a newer usage line follows,
//! and every snapshot but the newest one that decodes.

const std = @import("std");
const format = @import("prune_format.zig");
const schema = @import("schema.zig");
const log_mod = @import("log.zig");
const fold = @import("fold.zig");
const storage = @import("storage.zig");
const fixture = @import("prune_fixture.zig");

pub const Usage = enum { none, legacy, current };

pub const Line = struct {
    offset: u64,
    bytes: u64,
    seq: u64,
    ts: u64,
    /// Null for a kind this build does not know.
    kind: ?schema.Kind,
    usage: Usage,
    valid_snapshot: bool,
    superseded: bool,
};

pub const Plan = struct {
    /// Every line of the log, in order. Owned by the arena given to `run`.
    lines: []Line,
    /// Byte end of the last whole line.
    end: u64,
    /// Index into `lines` of the snapshot that stays, if any.
    kept_snapshot: ?usize,
    usage_superseded: u64,
    snapshots_superseded: u64,
    bytes_removed: u64,
    placeholder_bytes: u64,

    pub fn any(plan: *const Plan) bool {
        return plan.usage_superseded + plan.snapshots_superseded > 0;
    }
};

/// Reads every line of the log up to `end` and plans the cleanup. `arena`
/// owns the plan's lines.
pub fn run(gpa: std.mem.Allocator, arena: std.mem.Allocator, s: storage.Storage, file: storage.File, end: u64) format.Error!Plan {
    var lines: std.ArrayList(Line) = .empty;
    var reader = log_mod.ForwardReader.init(gpa, s, file, 0, end, 1);
    defer reader.deinit();
    var parsing = std.heap.ArenaAllocator.init(gpa);
    defer parsing.deinit();
    while (true) {
        const line = (reader.next() catch |err| return format.readError(err)) orelse break;
        _ = parsing.reset(.retain_capacity);
        try lines.append(arena, try describe(gpa, parsing.allocator(), line));
    }
    var plan: Plan = .{
        .lines = try lines.toOwnedSlice(arena),
        .end = end,
        .kept_snapshot = null,
        .usage_superseded = 0,
        .snapshots_superseded = 0,
        .bytes_removed = 0,
        .placeholder_bytes = 0,
    };
    try decide(gpa, &plan);
    return plan;
}

fn describe(gpa: std.mem.Allocator, arena: std.mem.Allocator, line: log_mod.Line) format.Error!Line {
    const header = line.header;
    var info: Line = .{
        .offset = line.offset,
        .bytes = line.bytes.len,
        .seq = header.seq,
        .ts = header.ts_ms,
        .kind = header.kind,
        .usage = .none,
        .valid_snapshot = false,
        .superseded = false,
    };
    const kind = header.kind orelse return info;
    const body = schema.parseBody(arena, kind, line.body()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadBody => {
            if (kind == .snapshot) return info;
            return error.Damaged;
        },
    };
    switch (body) {
        .set => |setting| {
            if (setting.key == .usage) {
                info.usage = if (format.isLegacyUsage(setting.value)) .legacy else .current;
            }
        },
        .snapshot => |snapshot| info.valid_snapshot = try decodes(gpa, arena, snapshot.state),
        else => {},
    }
    return info;
}

fn decodes(gpa: std.mem.Allocator, arena: std.mem.Allocator, state: []const u8) format.Error!bool {
    var decoded = fold.decodeState(gpa, arena, state) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadBody => return false,
    };
    decoded.deinit(gpa);
    return true;
}

/// Marks every superseded line and sizes what the rewrite will write in place
/// of each one.
fn decide(gpa: std.mem.Allocator, plan: *Plan) format.Error!void {
    var newest_usage: ?usize = null;
    var kept: ?usize = null;
    for (plan.lines, 0..) |line, i| {
        if (line.usage != .none) newest_usage = i;
        if (line.kind == .snapshot and line.valid_snapshot) kept = i;
    }
    plan.kept_snapshot = kept;

    var placeholder: std.ArrayList(u8) = .empty;
    defer placeholder.deinit(gpa);
    for (plan.lines, 0..) |*line, i| {
        const legacy_before_newest = line.usage == .legacy and newest_usage != null and i < newest_usage.?;
        const superseded_snapshot = line.kind == .snapshot and kept != i;
        if (!legacy_before_newest and !superseded_snapshot) continue;
        line.superseded = true;
        if (legacy_before_newest) plan.usage_superseded += 1 else plan.snapshots_superseded += 1;
        placeholder.clearRetainingCapacity();
        try format.appendPlaceholder(gpa, &placeholder, line.seq, line.ts);
        plan.bytes_removed += line.bytes;
        plan.placeholder_bytes += placeholder.items.len;
    }
}

pub fn hasPlaceholder(gpa: std.mem.Allocator, s: storage.Storage, file: storage.File, end: u64) format.Error!bool {
    var reader = log_mod.ForwardReader.init(gpa, s, file, 0, end, 1);
    defer reader.deinit();
    while (true) {
        const line = (reader.next() catch |err| return format.readError(err)) orelse return false;
        if (format.isPlaceholder(line.header)) return true;
    }
}

test "a legacy usage line is superseded when a newer usage line follows it" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.turn(1);
    try b.legacyUsage();
    try b.turn(2);
    try b.legacyUsage();
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);
    try std.testing.expectEqual(@as(u64, 1), plan.usage_superseded);
    try std.testing.expect(plan.lines[4].superseded);
    try std.testing.expect(!plan.lines[8].superseded);
}

test "a per-reply usage line is never superseded" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.usage(1);
    try b.usage(2);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);
    try std.testing.expectEqual(@as(u64, 0), plan.usage_superseded);
    try std.testing.expect(!plan.any());
}

test "the newest legacy usage line is kept when nothing newer follows" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.legacyUsage();
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);
    try std.testing.expectEqual(@as(u64, 0), plan.usage_superseded);
    try std.testing.expect(!plan.any());
}

test "every snapshot but the newest one that decodes is superseded" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.turn(1);
    try b.snapshot();
    try b.turn(2);
    try b.snapshot();
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);
    try std.testing.expectEqual(@as(u64, 1), plan.snapshots_superseded);
    try std.testing.expect(plan.lines[4].superseded);
    try std.testing.expectEqual(@as(?usize, 8), plan.kept_snapshot);
    try std.testing.expect(!plan.lines[8].superseded);
}

test "a newest snapshot that does not decode is superseded and an older valid one stays" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.turn(1);
    try b.snapshot();
    try b.turn(2);
    try b.brokenSnapshot();
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);
    try std.testing.expect(plan.lines[8].superseded);
    try std.testing.expectEqual(@as(?usize, 4), plan.kept_snapshot);
}

test "other set keys and every other kind of line are never superseded" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.setting(.prefs, "{}");
    try b.setting(.prefs, "{\"theme\":\"dark\"}");
    try b.setting(.title, "\"first\"");
    try b.setting(.title, "\"second\"");
    try b.legacyUsage();
    try b.turn(1);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);
    try std.testing.expect(!plan.any());
    for (plan.lines) |line| try std.testing.expect(!line.superseded);
}

test "a log with nothing superseded plans nothing" {
    const gpa = std.testing.allocator;
    var scratch = fixture.Scratch.init(gpa);
    defer scratch.deinit();
    var b = fixture.Builder.init(gpa);
    defer b.deinit();
    try b.created("s");
    try b.turn(1);
    try b.usage(3);
    const dir = try fixture.sessionDir(scratch.s, scratch.root, "s");
    defer scratch.s.closeDir(dir);
    const log = try scratch.logOf(dir, &b);
    defer scratch.s.closeFile(log.file);
    const plan = try run(gpa, scratch.arena.allocator(), scratch.s, log.file, log.end);
    try std.testing.expect(!plan.any());
    try std.testing.expectEqual(@as(u64, 0), plan.bytes_removed);
}
