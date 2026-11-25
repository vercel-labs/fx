//! The bring-back journal (V9). A bring-back appends one JSON line per file it writes, and fsyncs
//! it before it writes the next file. Once per bring-back, the manifest is rewritten from those
//! records, and the journal is removed. A journal that a crash left is folded into the manifest
//! at the next run's start, under the lock (sandbox.foldJournal).
const std = @import("std");
const io_mod = @import("../../shared/io.zig");

const Allocator = std.mem.Allocator;

/// The journal's file name in the sandbox state folder.
pub const file_name = "manifest.journal";
/// The most journal bytes one fold reads. A run writes at most 2,000 files, and each run folds
/// the journal before it appends, so a valid journal never reaches this bound.
pub const max_bytes: usize = 16 * 1024 * 1024;
const max_repo_path_bytes: usize = 1024;
const sha256_hex_len: usize = 64;

pub const Error = error{ BadJournal, OutOfMemory };

pub const Kind = enum { files, brought };

pub const Record = struct {
    kind: Kind,
    rel: []const u8,
    size: u64,
    mtime_ns: i64,
    sha256: []const u8,
};

pub const Parsed = struct {
    records: []const Record,
    /// True when the journal ends without a newline. A crash cut that record short. It is ignored,
    /// and its file counts as changed on this machine (N9).
    torn: bool,
};

const Wire = struct {
    k: []const u8,
    p: []const u8,
    s: u64,
    m: i64,
    h: []const u8,
};

/// One journal line, with its newline.
pub fn encodeLine(alloc: Allocator, record: Record) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const wire: Wire = .{
        .k = switch (record.kind) {
            .files => "f",
            .brought => "b",
        },
        .p = record.rel,
        .s = record.size,
        .m = record.mtime_ns,
        .h = record.sha256,
    };
    std.json.Stringify.value(wire, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.written();
}

/// Reads every complete line. A last line with no newline is torn and is not parsed.
pub fn parse(arena: Allocator, bytes: []const u8) Error!Parsed {
    var records: std.ArrayList(Record) = .empty;
    var rest = bytes;
    while (rest.len > 0) {
        const end = std.mem.findScalar(u8, rest, '\n') orelse return .{ .records = records.items, .torn = true };
        try records.append(arena, try parseLine(arena, rest[0..end]));
        rest = rest[end + 1 ..];
    }
    return .{ .records = records.items, .torn = false };
}

fn parseLine(arena: Allocator, line: []const u8) Error!Record {
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadJournal,
    };
    if (value != .object) return error.BadJournal;
    const object = value.object;

    const kind_text = stringField(object, "k") orelse return error.BadJournal;
    const kind: Kind = if (std.mem.eql(u8, kind_text, "f"))
        .files
    else if (std.mem.eql(u8, kind_text, "b"))
        .brought
    else
        return error.BadJournal;
    const rel = stringField(object, "p") orelse return error.BadJournal;
    if (!validRel(rel)) return error.BadJournal;
    const size = integerField(object, "s") orelse return error.BadJournal;
    if (size < 0) return error.BadJournal;
    const mtime_ns = integerField(object, "m") orelse return error.BadJournal;
    const sha256 = stringField(object, "h") orelse return error.BadJournal;
    if (!validSha256(sha256)) return error.BadJournal;

    return .{
        .kind = kind,
        .rel = rel,
        .size = @intCast(size),
        .mtime_ns = mtime_ns,
        .sha256 = sha256,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

/// A relative path from the archive: no empty part, no `.` or `..`, no `.git`, and no byte that a
/// line or a path cannot carry.
fn validRel(rel: []const u8) bool {
    if (rel.len == 0 or rel.len > max_repo_path_bytes) return false;
    if (rel[0] == '/') return false;
    for (rel) |byte| {
        if (byte == 0 or byte == '\n') return false;
    }
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (std.ascii.eqlIgnoreCase(part, ".git")) return false;
    }
    return true;
}

fn validSha256(text: []const u8) bool {
    if (text.len != sha256_hex_len) return false;
    for (text) |byte| {
        const hex = (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
        if (!hex) return false;
    }
    return true;
}

/// Appends one record and fsyncs it. A journal created here also has its folder fsynced, so the
/// new name is durable before the next file is written.
pub fn append(alloc: Allocator, dir: *io_mod.VerifiedDir, record: Record) !void {
    const io = io_mod.getIo();
    const line = try encodeLine(alloc, record);
    const existed = try exists(dir.dir, file_name);
    var file = try dir.dir.createFile(io, file_name, .{
        .truncate = false,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    defer file.close(io);
    _ = std.c.lseek(file.handle, 0, std.posix.SEEK.END);
    try file.writeStreamingAll(io, line);
    try file.sync(io);
    if (!existed) try io_mod.syncVerifiedDir(dir.dir);
}

/// True when a journal is there. A symbolic link or other non-file is refused, not followed.
fn exists(dir: std.Io.Dir, name: []const u8) !bool {
    const stat = dir.statFile(io_mod.getIo(), name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .file) return error.BadJournal;
    return true;
}

/// Removes the journal after its records are in the manifest. A missing journal is not an error.
pub fn remove(dir: *io_mod.VerifiedDir) !void {
    dir.dir.deleteFile(io_mod.getIo(), file_name) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

test "a journal line encodes one record, and parse reads it back (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const record: Record = .{ .kind = .brought, .rel = "zig-out/bin/fx", .size = 42, .mtime_ns = -7, .sha256 = sha };
    const line = try encodeLine(arena, record);
    try std.testing.expect(line[line.len - 1] == '\n');
    const parsed = try parse(arena, line);
    try std.testing.expectEqual(false, parsed.torn);
    try std.testing.expectEqual(@as(usize, 1), parsed.records.len);
    try std.testing.expectEqual(Kind.brought, parsed.records[0].kind);
    try std.testing.expectEqualStrings("zig-out/bin/fx", parsed.records[0].rel);
    try std.testing.expectEqual(@as(u64, 42), parsed.records[0].size);
    try std.testing.expectEqual(@as(i64, -7), parsed.records[0].mtime_ns);
    try std.testing.expectEqualStrings(sha, parsed.records[0].sha256);
}

test "a journal that ends in a torn record parses the complete lines and marks the tail torn (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const complete = "{\"k\":\"f\",\"p\":\"a.txt\",\"s\":1,\"m\":2,\"h\":\"" ++ sha ++ "\"}\n";
    const torn = "{\"k\":\"b\",\"p\":\"b.txt\",\"s\"";
    const parsed = try parse(arena, complete ++ complete ++ torn);
    try std.testing.expectEqual(true, parsed.torn);
    try std.testing.expectEqual(@as(usize, 2), parsed.records.len);
}

test "a complete journal line that is not a valid record is refused, not skipped (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const cases = [_][]const u8{
        "{\"k\":\"x\",\"p\":\"a.txt\",\"s\":1,\"m\":2,\"h\":\"" ++ sha ++ "\"}\n",
        "{\"k\":\"f\",\"p\":\"../escape\",\"s\":1,\"m\":2,\"h\":\"" ++ sha ++ "\"}\n",
        "{\"k\":\"f\",\"p\":\".git/config\",\"s\":1,\"m\":2,\"h\":\"" ++ sha ++ "\"}\n",
        "{\"k\":\"f\",\"p\":\"/etc/passwd\",\"s\":1,\"m\":2,\"h\":\"" ++ sha ++ "\"}\n",
        "{\"k\":\"f\",\"p\":\"a.txt\",\"s\":-1,\"m\":2,\"h\":\"" ++ sha ++ "\"}\n",
        "{\"k\":\"f\",\"p\":\"a.txt\",\"s\":1,\"m\":2,\"h\":\"NOT-HEX\"}\n",
        "not json\n",
    };
    for (cases) |bytes| {
        try std.testing.expectError(error.BadJournal, parse(arena, bytes));
    }
}

test "append writes one fsynced line per record, and remove deletes the journal (V9)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var state = try io_mod.openOrCreateVerifiedPrivateDirFromDir(tmp.dir, "state");
    defer state.close();
    const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    try append(arena, &state, .{ .kind = .files, .rel = "a.txt", .size = 1, .mtime_ns = 2, .sha256 = sha });
    try append(arena, &state, .{ .kind = .brought, .rel = "b.txt", .size = 3, .mtime_ns = 4, .sha256 = sha });
    var journal_file = try io_mod.openExistingReadOnlyRegularFile(state.dir, file_name, .no_follow);
    defer journal_file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(arena, &journal_file, max_bytes);
    const parsed = try parse(arena, bytes);
    try std.testing.expectEqual(false, parsed.torn);
    try std.testing.expectEqual(@as(usize, 2), parsed.records.len);
    try std.testing.expectEqualStrings("b.txt", parsed.records[1].rel);

    try remove(&state);
    try remove(&state);
    try std.testing.expectError(error.FileNotFound, state.dir.statFile(io_mod.getIo(), file_name, .{}));
}
