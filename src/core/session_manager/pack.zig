//! The session pack of small bodies (design B): one file, `blobs.pack`, of
//! records. A record is a 44-byte header (magic, the body's SHA-256, its
//! length, its CRC-32C) followed by the body. A line that names a packed body
//! is written at format version 2 (RULES.md R3.5).

const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");
const log_mod = @import("log.zig");
const storage = @import("storage.zig");

const crc32c = log_mod.crc32c;

/// Whether this build packs small bodies. The one switch: a build without
/// packs (the wasm core) stores every body as a file and never reads a pack,
/// so the compiler drops this file's code from it. The wasm core has no
/// session folder: its JS host keeps sessions, and its WASI shim has no
/// preopened folder.
pub const enabled = build_options.session_packs;

pub const file_name = "blobs.pack";
pub const magic = "FXB1";
pub const header_len: usize = 44;
/// The largest body a pack holds. Larger bodies stay files.
pub const max_body_bytes: usize = 4 << 10;
/// Records a reader keeps in memory for one session (RULES.md R3.7).
pub const max_cached_sessions: usize = 8;

pub const Header = struct {
    digest: [32]u8,
    len: u32,
    crc: u32,
};

pub const Loc = struct {
    offset: u64,
    len: u32,
    crc: u32,
};

pub fn digestOf(body: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    return digest;
}

/// The raw digest a blob name (64 lowercase hex characters) stands for.
pub fn keyOf(name: []const u8) ?[32]u8 {
    var key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, name) catch return null;
    return key;
}

pub fn encodeHeader(digest: [32]u8, body: []const u8) [header_len]u8 {
    std.debug.assert(body.len <= max_body_bytes);
    var out: [header_len]u8 = undefined;
    @memcpy(out[0..4], magic);
    @memcpy(out[4..36], &digest);
    std.mem.writeInt(u32, out[36..40], @intCast(body.len), .little);
    std.mem.writeInt(u32, out[40..44], crc32c(body), .little);
    return out;
}

/// Null for an all-zero header, which a file extended but never written
/// leaves behind. The caller checks that nothing but zeros follows it.
pub fn parseHeader(bytes: []const u8) error{Corrupt}!?Header {
    std.debug.assert(bytes.len >= header_len);
    if (std.mem.allEqual(u8, bytes[0..header_len], 0)) return null;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.Corrupt;
    const len = std.mem.readInt(u32, bytes[36..40], .little);
    if (len > max_body_bytes) return error.Corrupt;
    return .{
        .digest = bytes[4..36].*,
        .len = len,
        .crc = std.mem.readInt(u32, bytes[40..44], .little),
    };
}

/// The end of the last complete record in `bytes`. A record cut short by a
/// crash is torn and is not counted. Damage followed by more data is corrupt.
fn walkBytes(bytes: []const u8) error{Corrupt}!u64 {
    var pos: usize = 0;
    while (bytes.len - pos >= header_len) {
        const header = (try parseHeader(bytes[pos..])) orelse {
            if (std.mem.allEqual(u8, bytes[pos..], 0)) return pos;
            return error.Corrupt;
        };
        const end = pos + header_len + header.len;
        if (end > bytes.len) return pos;
        pos = end;
    }
    return pos;
}

test "a record's header round-trips, with its digest, length and CRC-32C" {
    const body = "a small body";
    const digest = digestOf(body);
    const header = encodeHeader(digest, body);
    const parsed = (try parseHeader(&header)) orelse return error.TestExpectedHeader;
    try testing.expectEqualSlices(u8, &digest, &parsed.digest);
    try testing.expectEqual(@as(u32, body.len), parsed.len);
    try testing.expectEqual(crc32c(body), parsed.crc);
}

test "a header with a bad magic or an over-long body is refused as corrupt" {
    const body = "x";
    var bad_magic = encodeHeader(digestOf(body), body);
    bad_magic[0] = 'X';
    try testing.expectError(error.Corrupt, parseHeader(&bad_magic));
    var too_long = encodeHeader(digestOf(body), body);
    std.mem.writeInt(u32, too_long[36..40], max_body_bytes + 1, .little);
    try testing.expectError(error.Corrupt, parseHeader(&too_long));
}

test "an all-zero header is torn, and a walk stops before a record that runs past the end" {
    const zero: [header_len]u8 = @splat(0);
    try testing.expectEqual(@as(?Header, null), try parseHeader(&zero));

    const body = "a whole body";
    const header = encodeHeader(digestOf(body), body);
    var bytes: [header_len + body.len + 10]u8 = @splat(0);
    @memcpy(bytes[0..header_len], &header);
    @memcpy(bytes[header_len..][0..body.len], body);
    const whole = header_len + body.len;
    // A partial second header: torn, so the walk ends after the first record.
    @memcpy(bytes[whole..][0..4], "FXB1");
    try testing.expectEqual(@as(u64, whole), try walkBytes(bytes[0 .. whole + 10]));
    // A record whose body is cut one byte short: torn as well.
    try testing.expectEqual(@as(u64, 0), try walkBytes(bytes[0 .. whole - 1]));
}

test "a damaged record followed by more bytes refuses the walk as corrupt" {
    const body = "a body";
    const header = encodeHeader(digestOf(body), body);
    var bytes: [2 * (header_len + body.len)]u8 = undefined;
    @memcpy(bytes[0..header_len], &header);
    @memcpy(bytes[header_len..][0..body.len], body);
    @memcpy(bytes[header_len + body.len ..][0..header_len], &header);
    @memcpy(bytes[2 * header_len + body.len ..], body);
    bytes[0] = 'X';
    try testing.expectError(error.Corrupt, walkBytes(&bytes));
}

fn fuzzRecords(_: void, smith: *testing.Smith) anyerror!void {
    var buffer: [512]u8 = undefined;
    const len = smith.slice(&buffer);
    const bytes = buffer[0..len];
    const end = walkBytes(bytes) catch return;
    try testing.expect(end <= bytes.len);
}

test "pack records parse or are refused on arbitrary bytes, and a walk ends on a record boundary" {
    try testing.fuzz({}, fuzzRecords, .{ .corpus = &(.{""} ++ @import("build_options").fuzz_corpus_session_pack_records.*) });
}

pub const ReadError = error{ Corrupt, OutOfMemory } || storage.Error;

/// The record that starts at `pos` in a file of `file_len` bytes, or null
/// when the file ends in a record that was cut short.
const Record = struct { header: Header, body_offset: u64 };

fn recordAt(s: storage.Storage, file: storage.File, pos: u64, file_len: u64) ReadError!?Record {
    if (file_len - pos < @as(u64, header_len)) return null;
    var buf: [header_len]u8 = undefined;
    if (try readExact(s, file, &buf, pos) != header_len) return null;
    const header = (try parseHeader(&buf)) orelse {
        return if (try zeroFrom(s, file, pos, file_len)) null else error.Corrupt;
    };
    const body_offset = pos + @as(u64, header_len);
    if (body_offset + header.len > file_len) return null;
    return .{ .header = header, .body_offset = body_offset };
}

fn zeroFrom(s: storage.Storage, file: storage.File, pos: u64, file_len: u64) storage.Error!bool {
    var buf: [64 << 10]u8 = undefined;
    var at = pos;
    while (at < file_len) {
        const want: usize = @intCast(@min(buf.len, file_len - at));
        const n = try readExact(s, file, buf[0..want], at);
        if (n == 0) break;
        if (!std.mem.allEqual(u8, buf[0..n], 0)) return false;
        at += n;
    }
    return true;
}

pub fn readExact(s: storage.Storage, file: storage.File, buf: []u8, offset: u64) storage.Error!usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = try s.readAt(file, buf[got..], offset + got);
        if (n == 0) break;
        got += n;
    }
    return got;
}

/// The records of one pack, by blob key, read by their headers alone. A
/// read seeks straight to its body. Offsets past `end` are not indexed yet.
pub const Index = struct {
    entries: std.AutoHashMapUnmanaged([32]u8, Loc) = .empty,
    /// Offset just past the last record the index has read.
    end: u64 = 0,
    /// Offset of the header of the last record read.
    last: u64 = 0,
    /// Records read from the file so far, for tests that count the walk.
    walked: u64 = 0,
    /// The last walk stopped at a header it could not read (bad magic, or a
    /// length past the record limit). Records past it cannot be reached.
    damaged: bool = false,

    pub fn deinit(index: *Index, gpa: std.mem.Allocator) void {
        index.entries.deinit(gpa);
    }

    pub fn lookup(index: *const Index, key: [32]u8) ?Loc {
        return index.entries.get(key);
    }

    /// `lookup` for readers. A missing key in a damaged pack may lie past the
    /// damage, so it is reported as corrupt rather than absent.
    pub fn find(index: *const Index, key: [32]u8) error{Corrupt}!?Loc {
        if (index.entries.get(key)) |loc| return loc;
        if (index.damaged) return error.Corrupt;
        return null;
    }

    /// The first record of a body wins: a body packed twice has one copy.
    pub fn insert(index: *Index, gpa: std.mem.Allocator, key: [32]u8, loc: Loc) error{OutOfMemory}!void {
        const found = try index.entries.getOrPut(gpa, key);
        if (!found.found_existing) found.value_ptr.* = loc;
    }

    /// Reads the headers from `end` to `file_len`, seeking past each body. A
    /// body that fails its CRC is not read here: the walk steps past it by
    /// its length. A header it cannot read ends the walk and sets `damaged`.
    pub fn extend(index: *Index, gpa: std.mem.Allocator, s: storage.Storage, file: storage.File, file_len: u64) ReadError!void {
        if (index.end > file_len) return error.Corrupt;
        index.damaged = false;
        while (true) {
            const next = recordAt(s, file, index.end, file_len) catch |err| switch (err) {
                error.Corrupt => {
                    index.damaged = true;
                    return;
                },
                else => |e| return e,
            };
            const record = next orelse return;
            try index.insert(gpa, record.header.digest, .{
                .offset = record.body_offset,
                .len = record.header.len,
                .crc = record.header.crc,
            });
            index.last = record.body_offset - @as(u64, header_len);
            index.end = record.body_offset + record.header.len;
            index.walked += 1;
        }
    }
};

/// Reads one body and checks its CRC-32C. The caller checks its name.
pub fn readBody(s: storage.Storage, file: storage.File, gpa: std.mem.Allocator, loc: Loc) ReadError![]u8 {
    const body = try gpa.alloc(u8, loc.len);
    errdefer gpa.free(body);
    if (try readExact(s, file, body, loc.offset) != body.len) return error.Corrupt;
    if (crc32c(body) != loc.crc) return error.Corrupt;
    return body;
}

/// Writes one record at `offset` and returns the offset after it. The caller
/// syncs the file before a line names the body.
pub fn appendRecord(s: storage.Storage, file: storage.File, offset: u64, digest: [32]u8, body: []const u8) storage.Error!u64 {
    var record: [header_len + max_body_bytes]u8 = undefined;
    const header = encodeHeader(digest, body);
    @memcpy(record[0..header_len], &header);
    @memcpy(record[header_len..][0..body.len], body);
    try s.writeAt(file, record[0 .. header_len + body.len], offset);
    return offset + @as(u64, header_len + body.len);
}

/// Where a walk of the pack stopped. `end` is the end of the good prefix.
/// `bad_at` is the offset of the record the walk could not read, when that is
/// before EOF: a bad header, a length past EOF, a zeroed tail, or a last record
/// whose body fails its CRC-32C.
pub const Walk = struct {
    end: u64,
    bad_at: ?u64,
};

pub fn walk(s: storage.Storage, file: storage.File) ReadError!Walk {
    const file_len = try s.length(file);
    var pos: u64 = 0;
    var last: ?Record = null;
    var last_start: u64 = 0;
    while (pos < file_len) {
        const next = recordAt(s, file, pos, file_len) catch |err| switch (err) {
            error.Corrupt => return .{ .end = pos, .bad_at = pos },
            else => |e| return e,
        };
        const record = next orelse return .{ .end = pos, .bad_at = pos };
        last = record;
        last_start = pos;
        pos = record.body_offset + record.header.len;
    }
    if (last) |record| {
        if (!try bodyCrcMatches(s, file, record.header, record.body_offset)) {
            return .{ .end = last_start, .bad_at = last_start };
        }
    }
    return .{ .end = pos, .bad_at = null };
}

fn bodyCrcMatches(s: storage.Storage, file: storage.File, header: Header, body_offset: u64) ReadError!bool {
    var body: [max_body_bytes]u8 = undefined;
    const bytes = body[0..header.len];
    if (try readExact(s, file, bytes, body_offset) != bytes.len) return false;
    return crc32c(bytes) == header.crc;
}

/// Copies the good prefix of `source` into `target`, as a new file. Never a
/// hard link: an append to one session would then change the other.
pub fn copyInto(s: storage.Storage, source: storage.Dir, target: storage.Dir, gpa: std.mem.Allocator) ReadError!void {
    const from = s.openFile(source, file_name, .read_only) catch |err| switch (err) {
        error.NotFound => return,
        else => |e| return e,
    };
    defer s.closeFile(from);
    const end = (try walk(s, from)).end;
    const to = try s.createFile(target, file_name);
    defer s.closeFile(to);
    const buf = try gpa.alloc(u8, 64 << 10);
    defer gpa.free(buf);
    var at: u64 = 0;
    while (at < end) {
        const want: usize = @intCast(@min(buf.len, end - at));
        const n = try readExact(s, from, buf[0..want], at);
        if (n == 0) return error.Corrupt;
        try s.writeAt(to, buf[0..n], at);
        at += n;
    }
    try s.sync(to);
}
