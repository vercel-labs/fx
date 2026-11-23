//! The names and line forms the cleanup writes and reads. Each is defined
//! here once (RULES.md R1.8): the rewrite, the replay check and the front
//! door all read them from this file.

const std = @import("std");
const log_mod = @import("log.zig");
const schema = @import("schema.zig");
const storage = @import("storage.zig");

pub const log_name = "log.jsonl";
pub const lock_name = "lock";
pub const pruning_name = "log.jsonl.pruning";
pub const kept_dir_name = "pruned";
pub const placeholder_kind = "pruned";
/// The start of a `set usage` value written before per-reply totals (D92).
/// Every reader reads it as no totals.
pub const legacy_usage_prefix = "{\"at_ms\":";
/// The rewrite writes to the temporary file in chunks of this size.
pub const flush_bytes: usize = 1 << 20;

pub const Error = storage.Error || error{
    OutOfMemory,
    TooLarge,
    Busy,
    Damaged,
    NotPruned,
    SnapshotNotRebuildable,
    ReplayMismatch,
};

pub fn isLegacyUsage(value: []const u8) bool {
    return std.mem.startsWith(u8, value, legacy_usage_prefix);
}

/// The body of a line whose kind this build knows; null for a kind it does not.
pub fn bodyOf(arena: std.mem.Allocator, line: log_mod.Line) Error!?schema.Body {
    const kind = line.header.kind orelse return null;
    return schema.parseBody(arena, kind, line.body()) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.BadBody => error.Damaged,
    };
}

pub fn isPlaceholder(header: schema.Header) bool {
    return header.kind == null and std.mem.eql(u8, header.kind_name, placeholder_kind);
}

pub const OpenedLog = struct {
    file: storage.File,
    /// Byte end of the last whole line.
    end: u64,
    /// Bytes in the file, a torn tail included.
    len: u64,
};

/// Opens a log of a session folder read-only. The caller closes `file`.
pub fn openLog(s: storage.Storage, dir: storage.Dir, name: []const u8) Error!OpenedLog {
    const file = try s.openFile(dir, name, .read_only);
    errdefer s.closeFile(file);
    const len = try s.length(file);
    const end = log_mod.lastLineEnd(s, file, len) catch |err| return readError(err);
    return .{ .file = file, .end = end, .len = len };
}

/// The seq a fork's view ends at, from line 1's `forked_from`; 0 for a root.
pub fn forkSeqOf(body: schema.Body) u64 {
    return switch (body) {
        .session_created => |created| if (created.forked_from) |origin| origin.seq else 0,
        else => 0,
    };
}

/// A reader's failure as the cleanup reports it: a line that fails its checks
/// makes the log damaged, and the cleanup never rewrites a damaged log.
pub fn readError(err: log_mod.ReadError) Error {
    return switch (err) {
        error.Corrupt => error.Damaged,
        error.OutOfMemory => error.OutOfMemory,
        else => |io_err| io_err,
    };
}

/// Appends a placeholder line: the seq and ts of the line it replaces, and a
/// kind no reader of this build or an older one knows, so every reader skips it.
pub fn appendPlaceholder(gpa: std.mem.Allocator, out: *std.ArrayList(u8), seq: u64, ts: u64) Error!void {
    const payload = try gpa.print("{{\"v\":{d},\"seq\":{d},\"ts\":{d},\"kind\":\"{s}\"", .{ schema.version, seq, ts, placeholder_kind });
    defer gpa.free(payload);
    try log_mod.appendFramed(gpa, out, payload);
}

test "a legacy usage value is told apart from the per-reply totals" {
    try std.testing.expect(isLegacyUsage("{\"at_ms\":1,\"snapshot\":{}}"));
    try std.testing.expect(!isLegacyUsage("{\"input_tokens\":5}"));
}

test "a placeholder keeps its seq and ts and reads as a kind this build does not know" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendPlaceholder(gpa, &out, 7, 1234);
    const header = try log_mod.checkLine(out.items);
    try std.testing.expectEqual(@as(u32, schema.version), header.v);
    try std.testing.expectEqual(@as(u64, 7), header.seq);
    try std.testing.expectEqual(@as(u64, 1234), header.ts_ms);
    try std.testing.expect(isPlaceholder(header));
    try std.testing.expect(out.items[out.items.len - 1] == '\n');
}
