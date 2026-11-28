//! Pure layouts of a flight recorder segment: the 64-byte segment header, the
//! frame header, the commit trailer, and the packed cursor word. No I/O, no
//! clock, no allocation. Integers are little-endian and every offset is
//! 8-byte aligned. The spec `docs/flight-recorder/slice2-spec.md` defines
//! each value here.

const std = @import("std");
const testing = std.testing;

/// CRC32C. Zig 0.17.1 names it `CRC-32/ISCSI`; the spec's `Crc32Iscsi` does not exist there.
const crc32c = std.hash.crc.@"CRC-32/ISCSI";

pub const segment_bytes: usize = 4 * 1024 * 1024;
pub const format_version: u16 = 1;
pub const segment_header_bytes: usize = 64;
pub const segment_magic = "FXFR";

pub const segment_format_version_at: usize = 4;
pub const segment_header_size_at: usize = 6;
pub const segment_instance_at: usize = 8;
pub const segment_index_at: usize = 16;
pub const segment_created_wall_at: usize = 24;
pub const segment_capacity_at: usize = 32;
pub const segment_cursor_at: usize = 40;
pub const segment_overflowed_at: usize = 48;
pub const segment_dropped_at: usize = 56;

pub const frame_header_bytes: usize = 48;
pub const frame_trailer_bytes: usize = 8;
/// The bytes "FRM1", read as a little-endian u32.
pub const frame_magic: u32 = 0x314D_5246;
/// The bytes "COMT", read as a little-endian u32.
pub const commit_magic: u32 = 0x544D_4F43;
pub const max_payload_bytes: usize = 64 * 1024;
pub const flag_continues: u16 = 1 << 0;

pub const frame_magic_at: usize = 0;
pub const frame_crc_at: usize = 4;
pub const frame_payload_len_at: usize = 8;
pub const frame_kind_at: usize = 12;
pub const frame_flags_at: usize = 14;
pub const frame_thread_at: usize = 16;
pub const frame_reservation_at: usize = 20;
pub const frame_seq_at: usize = 24;
pub const frame_mono_at: usize = 32;
pub const frame_wall_at: usize = 40;

const frame_crc_covers_from: usize = 8;

pub const cursor_offset_bits: u6 = 40;
pub const cursor_offset_mask: u64 = (1 << cursor_offset_bits) - 1;
pub const cursor_count_one: u64 = 1 << cursor_offset_bits;
pub const max_cursor_count: u32 = (1 << 24) - 1;

pub const Cursor = struct {
    offset: u64,
    count: u32,
};

pub fn packCursor(cursor: Cursor) u64 {
    std.debug.assert(cursor.offset <= cursor_offset_mask);
    std.debug.assert(cursor.count <= max_cursor_count);
    return cursor.offset | (@as(u64, cursor.count) << cursor_offset_bits);
}

pub fn unpackCursor(word: u64) Cursor {
    return .{
        .offset = word & cursor_offset_mask,
        .count = @intCast(word >> cursor_offset_bits),
    };
}

pub fn align8(len: usize) usize {
    return (len + 7) & ~@as(usize, 7);
}

pub fn frameBytes(payload_len: usize) usize {
    return frame_header_bytes + align8(payload_len) + frame_trailer_bytes;
}

pub const SegmentHeader = struct {
    format_version: u16,
    header_bytes: u16,
    instance: u64,
    index: u64,
    created_wall_ms: u64,
    capacity: u64,
    cursor: Cursor,
    overflowed: u64,
    dropped: u64,
};

pub const SegmentHeaderError = error{ TooShort, BadMagic };

pub fn encodeSegmentHeader(header: SegmentHeader) [segment_header_bytes]u8 {
    var bytes: [segment_header_bytes]u8 = @splat(0);
    @memcpy(bytes[0..segment_magic.len], segment_magic);
    writeU16(&bytes, segment_format_version_at, header.format_version);
    writeU16(&bytes, segment_header_size_at, header.header_bytes);
    writeU64(&bytes, segment_instance_at, header.instance);
    writeU64(&bytes, segment_index_at, header.index);
    writeU64(&bytes, segment_created_wall_at, header.created_wall_ms);
    writeU64(&bytes, segment_capacity_at, header.capacity);
    writeU64(&bytes, segment_cursor_at, packCursor(header.cursor));
    writeU64(&bytes, segment_overflowed_at, header.overflowed);
    writeU64(&bytes, segment_dropped_at, header.dropped);
    return bytes;
}

/// Checks only the length and the magic. The version and header size are the
/// reader's decision, so a newer version can still be told apart.
pub fn decodeSegmentHeader(bytes: []const u8) SegmentHeaderError!SegmentHeader {
    if (bytes.len < segment_header_bytes) return error.TooShort;
    if (!std.mem.eql(u8, bytes[0..segment_magic.len], segment_magic)) return error.BadMagic;
    return .{
        .format_version = readU16(bytes, segment_format_version_at),
        .header_bytes = readU16(bytes, segment_header_size_at),
        .instance = readU64(bytes, segment_instance_at),
        .index = readU64(bytes, segment_index_at),
        .created_wall_ms = readU64(bytes, segment_created_wall_at),
        .capacity = readU64(bytes, segment_capacity_at),
        .cursor = unpackCursor(readU64(bytes, segment_cursor_at)),
        .overflowed = readU64(bytes, segment_overflowed_at),
        .dropped = readU64(bytes, segment_dropped_at),
    };
}

pub const FrameHeader = struct {
    payload_len: u32,
    kind: u16,
    flags: u16,
    thread: u32,
    reservation_index: u32,
    seq: u64,
    mono_ns: u64,
    wall_ms: u64,
};

pub const FrameHeaderError = error{ TooShort, BadMagic, BadHeaderCrc, PayloadTooLong };

pub fn encodeFrameHeader(header: FrameHeader) [frame_header_bytes]u8 {
    var bytes: [frame_header_bytes]u8 = @splat(0);
    writeU32(&bytes, frame_magic_at, frame_magic);
    writeU32(&bytes, frame_payload_len_at, header.payload_len);
    writeU16(&bytes, frame_kind_at, header.kind);
    writeU16(&bytes, frame_flags_at, header.flags);
    writeU32(&bytes, frame_thread_at, header.thread);
    writeU32(&bytes, frame_reservation_at, header.reservation_index);
    writeU64(&bytes, frame_seq_at, header.seq);
    writeU64(&bytes, frame_mono_at, header.mono_ns);
    writeU64(&bytes, frame_wall_at, header.wall_ms);
    writeU32(&bytes, frame_crc_at, headerCrc(&bytes));
    return bytes;
}

pub fn decodeFrameHeader(bytes: []const u8) FrameHeaderError!FrameHeader {
    if (bytes.len < frame_header_bytes) return error.TooShort;
    if (readU32(bytes, frame_magic_at) != frame_magic) return error.BadMagic;
    if (readU32(bytes, frame_crc_at) != headerCrc(bytes)) return error.BadHeaderCrc;
    const payload_len = readU32(bytes, frame_payload_len_at);
    if (payload_len > max_payload_bytes) return error.PayloadTooLong;
    return .{
        .payload_len = payload_len,
        .kind = readU16(bytes, frame_kind_at),
        .flags = readU16(bytes, frame_flags_at),
        .thread = readU32(bytes, frame_thread_at),
        .reservation_index = readU32(bytes, frame_reservation_at),
        .seq = readU64(bytes, frame_seq_at),
        .mono_ns = readU64(bytes, frame_mono_at),
        .wall_ms = readU64(bytes, frame_wall_at),
    };
}

fn headerCrc(bytes: []const u8) u32 {
    return crc32c.hash(bytes[frame_crc_covers_from..frame_header_bytes]);
}

fn payloadCrc(payload: []const u8) u32 {
    return crc32c.hash(payload);
}

pub fn encodeTrailer(payload: []const u8) u64 {
    return @as(u64, commit_magic) | (@as(u64, payloadCrc(payload)) << 32);
}

pub fn trailerCommits(word: u64, payload: []const u8) bool {
    return @as(u32, @truncate(word)) == commit_magic and
        @as(u32, @truncate(word >> 32)) == payloadCrc(payload);
}

pub const EncodeError = error{ NoSpace, LengthMismatch, PayloadTooLong };

/// Writes one whole frame at the start of `out`: header, payload, zero padding
/// to 8 bytes, then the trailer last. Returns the frame's size in bytes.
pub fn encodeFrame(out: []u8, header: FrameHeader, payload: []const u8) EncodeError!usize {
    if (payload.len > max_payload_bytes) return error.PayloadTooLong;
    if (header.payload_len != payload.len) return error.LengthMismatch;
    const total = frameBytes(payload.len);
    if (out.len < total) return error.NoSpace;
    const encoded_header = encodeFrameHeader(header);
    @memcpy(out[0..frame_header_bytes], &encoded_header);
    const payload_end = frame_header_bytes + payload.len;
    @memcpy(out[frame_header_bytes..payload_end], payload);
    const padded_end = frame_header_bytes + align8(payload.len);
    @memset(out[payload_end..padded_end], 0);
    writeU64(out, padded_end, encodeTrailer(payload));
    return total;
}

pub const Piece = struct {
    start: usize,
    end: usize,
    flags: u16,
};

/// Yields the payload ranges of a payload split into frames of at most
/// `max_payload_bytes`. Every piece but the last has `flag_continues`.
pub const Splitter = struct {
    payload_len: usize,
    start: usize = 0,
    finished: bool = false,

    pub fn next(self: *Splitter) ?Piece {
        if (self.finished) return null;
        const end = @min(self.payload_len, self.start + max_payload_bytes);
        const piece: Piece = .{
            .start = self.start,
            .end = end,
            .flags = if (end < self.payload_len) flag_continues else 0,
        };
        self.start = end;
        self.finished = end == self.payload_len;
        return piece;
    }
};

pub fn splitPayload(payload_len: usize) Splitter {
    return .{ .payload_len = payload_len };
}

fn readU16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn readU64(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

fn writeU16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}

fn writeU32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn writeU64(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}

const sample_frame_header: FrameHeader = .{
    .payload_len = 300,
    .kind = 9,
    .flags = flag_continues,
    .thread = 7,
    .reservation_index = 12,
    .seq = 1 << 40,
    .mono_ns = 987_654_321,
    .wall_ms = 1_700_000_000_000,
};

test "segment header round trips every field" {
    const header: SegmentHeader = .{
        .format_version = format_version,
        .header_bytes = segment_header_bytes,
        .instance = 0x0123_4567_89AB_CDEF,
        .index = 42,
        .created_wall_ms = 1_700_000_000_123,
        .capacity = segment_bytes,
        .cursor = .{ .offset = 4096, .count = 17 },
        .overflowed = 3,
        .dropped = 5,
    };
    const bytes = encodeSegmentHeader(header);
    try testing.expectEqualDeep(header, try decodeSegmentHeader(&bytes));
}

test "segment header fields sit at the spec offsets" {
    const bytes = encodeSegmentHeader(.{
        .format_version = format_version,
        .header_bytes = segment_header_bytes,
        .instance = 0x1122_3344_5566_7788,
        .index = 9,
        .created_wall_ms = 10,
        .capacity = 11,
        .cursor = .{ .offset = 12, .count = 13 },
        .overflowed = 14,
        .dropped = 15,
    });
    try testing.expectEqualStrings("FXFR", bytes[0..4]);
    try testing.expectEqual(@as(u16, 1), readU16(&bytes, 4));
    try testing.expectEqual(@as(u16, 64), readU16(&bytes, 6));
    try testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), readU64(&bytes, 8));
    try testing.expectEqual(@as(u64, 9), readU64(&bytes, 16));
    try testing.expectEqual(@as(u64, 10), readU64(&bytes, 24));
    try testing.expectEqual(@as(u64, 11), readU64(&bytes, 32));
    try testing.expectEqual(packCursor(.{ .offset = 12, .count = 13 }), readU64(&bytes, 40));
    try testing.expectEqual(@as(u64, 14), readU64(&bytes, 48));
    try testing.expectEqual(@as(u64, 15), readU64(&bytes, 56));
}

test "segment header refuses short input and a wrong magic" {
    var bytes = encodeSegmentHeader(.{
        .format_version = format_version,
        .header_bytes = segment_header_bytes,
        .instance = 1,
        .index = 0,
        .created_wall_ms = 0,
        .capacity = segment_bytes,
        .cursor = .{ .offset = segment_header_bytes, .count = 0 },
        .overflowed = 0,
        .dropped = 0,
    });
    try testing.expectError(error.TooShort, decodeSegmentHeader(bytes[0..63]));
    bytes[0] = 'X';
    try testing.expectError(error.BadMagic, decodeSegmentHeader(&bytes));
}

test "frame header round trips every field" {
    const bytes = encodeFrameHeader(sample_frame_header);
    try testing.expectEqualDeep(sample_frame_header, try decodeFrameHeader(&bytes));
}

test "frame header CRC covers bytes 8 to 48 and is stored at byte 4" {
    const bytes = encodeFrameHeader(sample_frame_header);
    try testing.expectEqual(frame_magic, readU32(&bytes, 0));
    try testing.expectEqual(crc32c.hash(bytes[8..48]), readU32(&bytes, 4));
}

test "frame header refuses a flipped byte, a wrong magic, and a payload over the maximum" {
    var bytes = encodeFrameHeader(sample_frame_header);
    bytes[20] ^= 0x01;
    try testing.expectError(error.BadHeaderCrc, decodeFrameHeader(&bytes));

    bytes = encodeFrameHeader(sample_frame_header);
    bytes[0] = 'X';
    try testing.expectError(error.BadMagic, decodeFrameHeader(&bytes));

    var too_long = sample_frame_header;
    too_long.payload_len = max_payload_bytes + 1;
    const too_long_bytes = encodeFrameHeader(too_long);
    try testing.expectError(error.PayloadTooLong, decodeFrameHeader(&too_long_bytes));

    try testing.expectError(error.TooShort, decodeFrameHeader(bytes[0..47]));
}

test "trailer holds the commit magic in its low half and the payload CRC in its high half" {
    const word = encodeTrailer("payload");
    try testing.expectEqual(commit_magic, @as(u32, @truncate(word)));
    try testing.expectEqual(crc32c.hash("payload"), @as(u32, @truncate(word >> 32)));
}

test "a trailer commits only the payload it was written for" {
    const word = encodeTrailer("payload");
    try testing.expect(trailerCommits(word, "payload"));
    try testing.expect(!trailerCommits(word, "payloaD"));
    try testing.expect(!trailerCommits(word & 0xFFFF_FFFF_0000_0000, "payload"));
}

test "frame_bytes and align8 keep every frame 8-byte aligned" {
    try testing.expectEqual(@as(usize, 0), align8(0));
    try testing.expectEqual(@as(usize, 8), align8(1));
    try testing.expectEqual(@as(usize, 8), align8(8));
    try testing.expectEqual(@as(usize, 16), align8(9));
    try testing.expectEqual(@as(usize, 56), frameBytes(0));
    try testing.expectEqual(@as(usize, 64), frameBytes(1));
    try testing.expectEqual(@as(usize, 64), frameBytes(8));
    try testing.expectEqual(@as(usize, 72), frameBytes(9));
    try testing.expectEqual(@as(usize, 48 + max_payload_bytes + 8), frameBytes(max_payload_bytes));
    for (0..100) |payload_len| {
        try testing.expectEqual(@as(usize, 0), frameBytes(payload_len) % 8);
    }
}

fn expectSplit(payload_len: usize, want: []const Piece) !void {
    var splitter = splitPayload(payload_len);
    for (want) |piece| try testing.expectEqualDeep(piece, splitter.next().?);
    try testing.expect(splitter.next() == null);
}

test "a payload splits into continuation frames at 0, 1, max, max+1, and 3x max" {
    const cap = max_payload_bytes;
    try expectSplit(0, &.{.{ .start = 0, .end = 0, .flags = 0 }});
    try expectSplit(1, &.{.{ .start = 0, .end = 1, .flags = 0 }});
    try expectSplit(cap, &.{.{ .start = 0, .end = cap, .flags = 0 }});
    try expectSplit(cap + 1, &.{
        .{ .start = 0, .end = cap, .flags = flag_continues },
        .{ .start = cap, .end = cap + 1, .flags = 0 },
    });
    try expectSplit(3 * cap, &.{
        .{ .start = 0, .end = cap, .flags = flag_continues },
        .{ .start = cap, .end = 2 * cap, .flags = flag_continues },
        .{ .start = 2 * cap, .end = 3 * cap, .flags = 0 },
    });
}

test "cursor packs the offset into the low 40 bits and the count into the high 24 bits" {
    const cursor: Cursor = .{ .offset = 0x12_3456_7890, .count = 0xAB_CDEF };
    const word = packCursor(cursor);
    try testing.expectEqual(@as(u64, 0x12_3456_7890), word & cursor_offset_mask);
    try testing.expectEqual(@as(u64, 0xAB_CDEF), word >> cursor_offset_bits);
    try testing.expectEqualDeep(cursor, unpackCursor(word));

    const largest: Cursor = .{ .offset = cursor_offset_mask, .count = max_cursor_count };
    try testing.expectEqualDeep(largest, unpackCursor(packCursor(largest)));
}

test "a reservation adds frame_bytes to the offset and one to the count" {
    const before = packCursor(.{ .offset = segment_header_bytes, .count = 0 });
    const after = before + @as(u64, frameBytes(5)) + cursor_count_one;
    try testing.expectEqualDeep(
        Cursor{ .offset = segment_header_bytes + 64, .count = 1 },
        unpackCursor(after),
    );
}

test "encodeFrame writes header, payload, zero padding, then the trailer" {
    var buffer: [128]u8 = @splat(0xEE);
    const header: FrameHeader = .{
        .payload_len = 5,
        .kind = 9,
        .flags = 0,
        .thread = 7,
        .reservation_index = 12,
        .seq = 1 << 40,
        .mono_ns = 987_654_321,
        .wall_ms = 1_700_000_000_000,
    };
    const written = try encodeFrame(&buffer, header, "hello");
    try testing.expectEqual(frameBytes(5), written);
    try testing.expectEqualStrings("hello", buffer[48..53]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, buffer[53..56]);
    try testing.expectEqual(encodeTrailer("hello"), readU64(&buffer, 56));
    try testing.expectEqual(@as(u8, 0xEE), buffer[64]);
}

test "encodeFrame refuses a short buffer, a length mismatch, and an oversized payload" {
    var small: [63]u8 = undefined;
    const header: FrameHeader = .{
        .payload_len = 5,
        .kind = 0,
        .flags = 0,
        .thread = 0,
        .reservation_index = 0,
        .seq = 0,
        .mono_ns = 0,
        .wall_ms = 0,
    };
    try testing.expectError(error.NoSpace, encodeFrame(&small, header, "hello"));

    var buffer: [128]u8 = undefined;
    var wrong_length = header;
    wrong_length.payload_len = 4;
    try testing.expectError(error.LengthMismatch, encodeFrame(&buffer, wrong_length, "hello"));

    const oversized: [max_payload_bytes + 1]u8 = @splat(0);
    var big_header = header;
    big_header.payload_len = max_payload_bytes + 1;
    var big_buffer: [frameBytes(max_payload_bytes + 1)]u8 = undefined;
    try testing.expectError(error.PayloadTooLong, encodeFrame(&big_buffer, big_header, &oversized));
}
