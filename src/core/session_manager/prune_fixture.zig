//! Synthetic session logs for the cleanup's tests. Test code only: each line
//! is framed and folded with the same code the session writes, and every log
//! lives in a temporary folder.

const std = @import("std");
const schema = @import("schema.zig");
const log_mod = @import("log.zig");
const fold = @import("fold.zig");
const storage = @import("storage.zig");
const format = @import("prune_format.zig");

pub const Builder = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    state: fold.State = .{},
    next_seq: u64 = 1,
    next_ts: u64 = 1000,

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(b: *Builder) void {
        b.bytes.deinit(b.gpa);
        b.state.deinit(b.gpa);
    }

    fn line(b: *Builder, kind: schema.Kind, body: schema.Body) !void {
        var fields: std.ArrayList(u8) = .empty;
        defer fields.deinit(b.gpa);
        try schema.appendBody(b.gpa, &fields, body);
        const offset: u64 = b.bytes.items.len;
        try log_mod.appendLine(b.gpa, &b.bytes, b.next_seq, b.next_ts, kind, fields.items);
        try fold.apply(b.gpa, &b.state, 0, .{ .seq = b.next_seq, .offset = offset, .body = body });
        b.next_seq += 1;
        b.next_ts += 1;
    }

    pub fn created(b: *Builder, id: []const u8) !void {
        try b.line(.session_created, .{ .session_created = .{ .id = id, .workspace = "/w", .role = .root, .host = .app } });
    }

    /// One turn: three lines, `turn_started`, one user item, `turn_committed`.
    pub fn turn(b: *Builder, number: u64) !void {
        try b.line(.turn_started, .{ .turn_started = .{ .turn = number } });
        try b.line(.item, .{ .item = .{ .turn = number, .type = "user", .data = "{}" } });
        try b.line(.turn_committed, .{ .turn_committed = .{ .turn = number } });
    }

    /// A `set usage` value in the shape fx wrote before per-reply totals (D92).
    pub fn legacyUsage(b: *Builder) !void {
        try b.setting(.usage, "{\"at_ms\":1,\"snapshot\":{}}");
    }

    /// A `set usage` value in the per-reply shape.
    pub fn usage(b: *Builder, input_tokens: u64) !void {
        const value = try b.gpa.print("{{\"input_tokens\":{d}}}", .{input_tokens});
        defer b.gpa.free(value);
        try b.setting(.usage, value);
    }

    pub fn setting(b: *Builder, key: schema.SetKey, value: []const u8) !void {
        try b.line(.set, .{ .set = .{ .key = key, .value = value } });
    }

    pub fn compacted(b: *Builder, turn_number: u64) !void {
        try b.line(.compacted, .{ .compacted = .{ .turn = turn_number, .data = "{}" } });
    }

    /// A snapshot that covers every line before it, as fx writes one.
    pub fn snapshot(b: *Builder) !void {
        try b.snapshotCovering(b.state.last_seq);
    }

    pub fn snapshotCovering(b: *Builder, covers: u64) !void {
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(b.gpa);
        try fold.encodeState(b.gpa, &encoded, &b.state);
        try b.line(.snapshot, .{ .snapshot = .{
            .covers_seq = covers,
            .state = encoded.items,
            .compaction_offset = b.state.compaction_offset,
        } });
    }

    /// A snapshot whose state is a number, not an object, so no reader can
    /// decode it. A truncated object is not used: the body parser reads past
    /// the end of one (schema.zig, splitObject).
    pub fn brokenSnapshot(b: *Builder) !void {
        try b.line(.snapshot, .{ .snapshot = .{
            .covers_seq = b.state.last_seq,
            .state = "5",
            .compaction_offset = null,
        } });
    }

    pub fn writeTo(b: *const Builder, s: storage.Storage, dir: storage.Dir, name: []const u8) !void {
        const file = try s.createFile(dir, name);
        defer s.closeFile(file);
        try s.writeAt(file, b.bytes.items, 0);
        try s.sync(file);
    }
};

/// The folder of session `id` under `root`, with its lock file. The caller
/// closes it.
pub fn sessionDir(s: storage.Storage, root: storage.Dir, id: []const u8) !storage.Dir {
    const dir = try s.ensureDir(root, id);
    const lock = try s.createFile(dir, format.lock_name);
    s.closeFile(lock);
    return dir;
}

/// A temporary folder, an arena for plans, and the storage handle over them.
pub const Scratch = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    s: storage.Storage,
    root: storage.Dir,

    pub fn init(gpa: std.mem.Allocator) Scratch {
        const tmp = std.testing.tmpDir(.{ .iterate = true });
        return .{
            .tmp = tmp,
            .arena = .init(gpa),
            .s = .{ .io = std.testing.io },
            .root = .{ .handle = tmp.dir },
        };
    }

    pub fn deinit(scratch: *Scratch) void {
        scratch.arena.deinit();
        scratch.tmp.cleanup();
    }

    /// Writes the built log into session folder `dir` and opens it.
    pub fn logOf(scratch: *Scratch, dir: storage.Dir, b: *const Builder) !OpenedLog {
        try b.writeTo(scratch.s, dir, format.log_name);
        return openLog(scratch.s, dir, format.log_name);
    }
};

pub const OpenedLog = format.OpenedLog;
pub const openLog = format.openLog;

/// Appends raw bytes to the end of a file, creating it when absent.
pub fn appendRaw(s: storage.Storage, dir: storage.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try s.openFile(dir, name, .read_write);
    defer s.closeFile(file);
    const len = try s.length(file);
    try s.writeAt(file, bytes, len);
    try s.sync(file);
}

/// Creates or replaces `name` with exactly `bytes`.
pub fn writeRaw(s: storage.Storage, dir: storage.Dir, name: []const u8, bytes: []const u8) !void {
    const file = try s.createFile(dir, name);
    defer s.closeFile(file);
    try s.writeAt(file, bytes, 0);
    try s.sync(file);
}

pub fn readBytes(gpa: std.mem.Allocator, dir: storage.Dir, name: []const u8) ![]u8 {
    return dir.handle.readFileAlloc(std.testing.io, name, gpa, .limited(1 << 26));
}

/// Each whole line of `bytes`, newline included. The caller frees the slice
/// of slices; the lines point into `bytes`.
pub fn splitLines(gpa: std.mem.Allocator, bytes: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);
    var start: usize = 0;
    while (std.mem.findScalarPos(u8, bytes, start, '\n')) |nl| {
        try lines.append(gpa, bytes[start .. nl + 1]);
        start = nl + 1;
    }
    return lines.toOwnedSlice(gpa);
}

/// `bytes` with line `index` replaced by `replacement` (a whole line).
pub fn replaceLine(gpa: std.mem.Allocator, bytes: []const u8, index: usize, replacement: []const u8) ![]u8 {
    const lines = try splitLines(gpa, bytes);
    defer gpa.free(lines);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines, 0..) |line, i| {
        try out.appendSlice(gpa, if (i == index) replacement else line);
    }
    return out.toOwnedSlice(gpa);
}

/// A snapshot line with the given state JSON and outer offset, framed as fx
/// frames one. The caller frees the line.
pub fn snapshotLine(gpa: std.mem.Allocator, seq: u64, ts: u64, covers: u64, state: []const u8, offset: ?u64) ![]u8 {
    var fields: std.ArrayList(u8) = .empty;
    defer fields.deinit(gpa);
    try schema.appendBody(gpa, &fields, .{ .snapshot = .{ .covers_seq = covers, .state = state, .compaction_offset = offset } });
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(gpa);
    try log_mod.appendLine(gpa, &line, seq, ts, .snapshot, fields.items);
    return line.toOwnedSlice(gpa);
}

/// Byte offset of the line whose seq is `seq`, in `bytes`.
pub fn offsetOfSeq(lines: []const []const u8, seq: u64) u64 {
    var offset: u64 = 0;
    for (lines[0 .. seq - 1]) |line| offset += line.len;
    return offset;
}
