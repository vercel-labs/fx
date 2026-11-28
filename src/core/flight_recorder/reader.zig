//! Pure reader for one flight recorder segment: bytes in, frames and gap
//! counts out. It takes no file, clock, or random source, and it trusts no
//! offset or length in the file until it has checked it against the bytes.

const std = @import("std");
const testing = std.testing;
const format = @import("format.zig");

const hole_scan_step_bytes: usize = 8;

pub const VersionStatus = enum { current, newer };

pub const Frame = struct {
    offset: u64,
    kind: u16,
    flags: u16,
    thread: u32,
    reservation_index: u32,
    seq: u64,
    mono_ns: u64,
    wall_ms: u64,
    /// Borrowed from the bytes given to `read`, which the caller keeps alive.
    payload: []const u8,
};

pub const TornFrame = struct {
    offset: u64,
    reservation_index: u32,
    seq: u64,
};

pub const Hole = struct {
    offset: u64,
    len: u64,
};

/// Owned by the caller, who frees it with `deinit`. Frame payloads borrow
/// from the bytes given to `read`.
pub const Result = struct {
    version_status: VersionStatus,
    frames: std.ArrayList(Frame),
    torn: std.ArrayList(TornFrame),
    holes: std.ArrayList(Hole),
    missing: u64,
    overflowed: u64,
    dropped: u64,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        self.frames.deinit(gpa);
        self.torn.deinit(gpa);
        self.holes.deinit(gpa);
        self.* = undefined;
    }
};

pub const ReadError = format.SegmentHeaderError || error{ UnsupportedVersion, BadHeaderBytes } || std.mem.Allocator.Error;

/// A newer format version gives no frames and no counts, and is never rewritten.
pub fn read(gpa: std.mem.Allocator, bytes: []const u8) ReadError!Result {
    const header = try format.decodeSegmentHeader(bytes);
    if (header.format_version > format.format_version) return newerResult();
    if (header.format_version != format.format_version) return error.UnsupportedVersion;
    if (header.header_bytes != format.segment_header_bytes) return error.BadHeaderBytes;
    return readCurrent(gpa, bytes, header);
}

fn newerResult() Result {
    return .{
        .version_status = .newer,
        .frames = .empty,
        .torn = .empty,
        .holes = .empty,
        .missing = 0,
        .overflowed = 0,
        .dropped = 0,
    };
}

fn readCurrent(gpa: std.mem.Allocator, bytes: []const u8, header: format.SegmentHeader) std.mem.Allocator.Error!Result {
    var result: Result = .{
        .version_status = .current,
        .frames = .empty,
        .torn = .empty,
        .holes = .empty,
        .missing = 0,
        .overflowed = header.overflowed,
        .dropped = header.dropped,
    };
    errdefer result.deinit(gpa);

    const end = walkEnd(bytes.len, header);
    var offset: usize = format.segment_header_bytes;
    while (offset < end) {
        offset = try step(gpa, &result, bytes, offset, end);
    }
    result.missing = missingFrames(header, result.frames.items.len + result.torn.items.len);
    return result;
}

/// The walk stops at the cursor, at the capacity, or at the bytes present.
fn walkEnd(byte_count: usize, header: format.SegmentHeader) usize {
    const limit = @min(header.cursor.offset, header.capacity, @as(u64, byte_count));
    return @intCast(limit);
}

/// Reads the frame or the hole at `offset`, and returns where the walk goes next.
fn step(gpa: std.mem.Allocator, result: *Result, bytes: []const u8, offset: usize, end: usize) std.mem.Allocator.Error!usize {
    if (validHeaderAt(bytes, offset, end)) |frame_header| {
        try recordFrame(gpa, result, bytes, offset, frame_header);
        return offset + format.frameBytes(frame_header.payload_len);
    }
    const next = nextValidHeader(bytes, offset + hole_scan_step_bytes, end);
    try result.holes.append(gpa, .{ .offset = @intCast(offset), .len = @intCast(next - offset) });
    return next;
}

/// A header is valid when its magic and CRC check and its whole frame fits before `end`.
fn validHeaderAt(bytes: []const u8, offset: usize, end: usize) ?format.FrameHeader {
    const header = format.decodeFrameHeader(bytes[offset..end]) catch return null;
    if (offset + format.frameBytes(header.payload_len) > end) return null;
    return header;
}

fn nextValidHeader(bytes: []const u8, start: usize, end: usize) usize {
    var position = start;
    while (position < end) : (position += hole_scan_step_bytes) {
        if (validHeaderAt(bytes, position, end) != null) return position;
    }
    return end;
}

fn recordFrame(gpa: std.mem.Allocator, result: *Result, bytes: []const u8, offset: usize, header: format.FrameHeader) std.mem.Allocator.Error!void {
    const payload_start = offset + format.frame_header_bytes;
    const payload = bytes[payload_start .. payload_start + header.payload_len];
    const trailer_at = offset + format.frameBytes(header.payload_len) - format.frame_trailer_bytes;
    const trailer = std.mem.readInt(u64, bytes[trailer_at..][0..8], .little);
    if (!format.trailerCommits(trailer, payload)) {
        try result.torn.append(gpa, .{
            .offset = @intCast(offset),
            .reservation_index = header.reservation_index,
            .seq = header.seq,
        });
        return;
    }
    try result.frames.append(gpa, .{
        .offset = @intCast(offset),
        .kind = header.kind,
        .flags = header.flags,
        .thread = header.thread,
        .reservation_index = header.reservation_index,
        .seq = header.seq,
        .mono_ns = header.mono_ns,
        .wall_ms = header.wall_ms,
        .payload = payload,
    });
}

/// Reservations that never fit are counted by the cursor and by `overflowed`,
/// so subtracting both leaves the frames that were lost. Saturating math keeps
/// a crash between the two counter updates from going negative.
fn missingFrames(header: format.SegmentHeader, counted: usize) u64 {
    const accounted = header.overflowed +| @as(u64, counted);
    return @as(u64, header.cursor.count) -| accounted;
}

test "a committed segment reads every frame with its header fields" {
    var buffer: [512]u8 = @splat(0);
    var end: usize = format.segment_header_bytes;
    end = try putFrame(&buffer, end, 1, 0, "first");
    end = try putFrame(&buffer, end, 2, 1, "second payload");
    putHeader(&buffer, .{ .offset = end, .count = 2 }, 0, 0);

    var result = try read(testing.allocator, &buffer);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(VersionStatus.current, result.version_status);
    try testing.expectEqual(@as(usize, 2), result.frames.items.len);
    try testing.expectEqual(@as(usize, 0), result.torn.items.len);
    try testing.expectEqual(@as(usize, 0), result.holes.items.len);
    try testing.expectEqual(@as(u64, 0), result.missing);

    const first = result.frames.items[0];
    try testing.expectEqual(@as(u64, 64), first.offset);
    try testing.expectEqual(@as(u16, 3), first.kind);
    try testing.expectEqual(@as(u32, 1), first.thread);
    try testing.expectEqual(@as(u32, 0), first.reservation_index);
    try testing.expectEqual(@as(u64, 1), first.seq);
    try testing.expectEqual(@as(u64, 10), first.mono_ns);
    try testing.expectEqual(@as(u64, 1001), first.wall_ms);
    try testing.expectEqualStrings("first", first.payload);
    try testing.expectEqual(@intFromPtr(&buffer[64 + format.frame_header_bytes]), @intFromPtr(first.payload.ptr));

    const second = result.frames.items[1];
    try testing.expectEqual(@as(u64, 2), second.seq);
    try testing.expectEqual(@as(u32, 1), second.reservation_index);
    try testing.expectEqualStrings("second payload", second.payload);
}

test "a frame whose trailer is missing is torn and keeps its seq" {
    var buffer: [512]u8 = @splat(0);
    var end: usize = format.segment_header_bytes;
    end = try putFrame(&buffer, end, 1, 0, "ok");
    const torn_at = end;
    end = try putFrame(&buffer, end, 2, 1, "cut");
    @memset(buffer[end - format.frame_trailer_bytes .. end], 0);
    putHeader(&buffer, .{ .offset = end, .count = 2 }, 0, 0);

    var result = try read(testing.allocator, &buffer);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), result.frames.items.len);
    try testing.expectEqual(@as(usize, 1), result.torn.items.len);
    try testing.expectEqual(@as(u64, torn_at), result.torn.items[0].offset);
    try testing.expectEqual(@as(u64, 2), result.torn.items[0].seq);
    try testing.expectEqual(@as(u32, 1), result.torn.items[0].reservation_index);
    try testing.expectEqual(@as(u64, 0), result.missing);
}

test "a payload whose CRC fails its trailer is torn" {
    var buffer: [512]u8 = @splat(0);
    var end: usize = format.segment_header_bytes;
    end = try putFrame(&buffer, end, 5, 0, "payload");
    buffer[format.segment_header_bytes + format.frame_header_bytes] ^= 0x20;
    putHeader(&buffer, .{ .offset = end, .count = 1 }, 0, 0);

    var result = try read(testing.allocator, &buffer);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), result.frames.items.len);
    try testing.expectEqual(@as(usize, 1), result.torn.items.len);
    try testing.expectEqual(@as(u64, 5), result.torn.items[0].seq);
    try testing.expectEqual(@as(u64, 0), result.missing);
}

test "a hole in the middle is skipped, reported as a range, and counted missing" {
    var buffer: [512]u8 = @splat(0);
    var end: usize = format.segment_header_bytes;
    end = try putFrame(&buffer, end, 1, 0, "aaa");
    const hole_at = end;
    end += format.frameBytes(4);
    end = try putFrame(&buffer, end, 3, 2, "ccc");
    putHeader(&buffer, .{ .offset = end, .count = 3 }, 0, 0);

    var result = try read(testing.allocator, &buffer);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), result.frames.items.len);
    try testing.expectEqual(@as(u64, 3), result.frames.items[1].seq);
    try testing.expectEqual(@as(usize, 1), result.holes.items.len);
    try testing.expectEqual(@as(u64, hole_at), result.holes.items[0].offset);
    try testing.expectEqual(@as(u64, format.frameBytes(4)), result.holes.items[0].len);
    try testing.expectEqual(@as(u64, 1), result.missing);
}

test "two touching holes are counted as missing 2" {
    var buffer: [512]u8 = @splat(0);
    var end: usize = format.segment_header_bytes;
    end = try putFrame(&buffer, end, 1, 0, "aaa");
    const holes_at = end;
    end += format.frameBytes(4) + format.frameBytes(10);
    end = try putFrame(&buffer, end, 4, 3, "dddd");
    putHeader(&buffer, .{ .offset = end, .count = 4 }, 0, 0);

    var result = try read(testing.allocator, &buffer);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), result.frames.items.len);
    try testing.expectEqual(@as(usize, 1), result.holes.items.len);
    try testing.expectEqual(@as(u64, holes_at), result.holes.items[0].offset);
    try testing.expectEqual(@as(u64, format.frameBytes(4) + format.frameBytes(10)), result.holes.items[0].len);
    try testing.expectEqual(@as(u64, 2), result.missing);
}

test "a hole at the end is counted missing" {
    var buffer: [512]u8 = @splat(0);
    var end: usize = format.segment_header_bytes;
    end = try putFrame(&buffer, end, 1, 0, "aaa");
    const hole_at = end;
    end += format.frameBytes(3);
    putHeader(&buffer, .{ .offset = end, .count = 2 }, 0, 0);

    var result = try read(testing.allocator, &buffer);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), result.frames.items.len);
    try testing.expectEqual(@as(usize, 1), result.holes.items.len);
    try testing.expectEqual(@as(u64, hole_at), result.holes.items[0].offset);
    try testing.expectEqual(@as(u64, format.frameBytes(3)), result.holes.items[0].len);
    try testing.expectEqual(@as(u64, 1), result.missing);
}

test "a newer format version reports no frames and no counts" {
    var buffer: [512]u8 = @splat(0);
    _ = try putFrame(&buffer, format.segment_header_bytes, 1, 0, "hidden");
    buffer[0..format.segment_header_bytes].* = format.encodeSegmentHeader(.{
        .format_version = format.format_version + 1,
        .header_bytes = format.segment_header_bytes,
        .instance = 7,
        .index = 0,
        .created_wall_ms = 0,
        .capacity = buffer.len,
        .cursor = .{ .offset = 200, .count = 5 },
        .overflowed = 1,
        .dropped = 2,
    });

    var result = try read(testing.allocator, &buffer);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(VersionStatus.newer, result.version_status);
    try testing.expectEqual(@as(usize, 0), result.frames.items.len);
    try testing.expectEqual(@as(usize, 0), result.torn.items.len);
    try testing.expectEqual(@as(usize, 0), result.holes.items.len);
    try testing.expectEqual(@as(u64, 0), result.missing);
}

test "a cursor past capacity walks only to capacity" {
    var buffer: [256]u8 = @splat(0);
    var end: usize = format.segment_header_bytes;
    end = try putFrame(&buffer, end, 1, 0, "fits");
    putHeader(&buffer, .{ .offset = 1000, .count = 3 }, 2, 0);

    var result = try read(testing.allocator, &buffer);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), result.frames.items.len);
    try testing.expectEqual(@as(u64, 0), result.missing);
    try testing.expectEqual(@as(usize, 1), result.holes.items.len);
    const hole = result.holes.items[0];
    try testing.expectEqual(@as(u64, buffer.len), hole.offset + hole.len);
}

test "overflowed reservations are not counted as missing" {
    var buffer: [512]u8 = @splat(0);
    var end: usize = format.segment_header_bytes;
    end = try putFrame(&buffer, end, 1, 0, "kept");
    putHeader(&buffer, .{ .offset = end + 4096, .count = 3 }, 2, 0);

    var result = try read(testing.allocator, &buffer);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), result.frames.items.len);
    try testing.expectEqual(@as(u64, 2), result.overflowed);
    try testing.expectEqual(@as(u64, 0), result.missing);
}

test "missing clamps at zero when the counts disagree" {
    var buffer: [512]u8 = @splat(0);
    var end: usize = format.segment_header_bytes;
    end = try putFrame(&buffer, end, 1, 0, "one");
    end = try putFrame(&buffer, end, 2, 1, "two");
    putHeader(&buffer, .{ .offset = end, .count = 1 }, 5, 0);

    var result = try read(testing.allocator, &buffer);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), result.missing);
}

test "garbage bytes are refused with a clean error" {
    try testing.expectError(error.TooShort, read(testing.allocator, ""));
    try testing.expectError(error.TooShort, read(testing.allocator, "FXFR"));

    var zeros: [128]u8 = @splat(0);
    try testing.expectError(error.BadMagic, read(testing.allocator, &zeros));

    var version_zero: [128]u8 = @splat(0);
    version_zero[0..format.segment_header_bytes].* = format.encodeSegmentHeader(.{
        .format_version = 0,
        .header_bytes = format.segment_header_bytes,
        .instance = 1,
        .index = 0,
        .created_wall_ms = 0,
        .capacity = version_zero.len,
        .cursor = .{ .offset = format.segment_header_bytes, .count = 0 },
        .overflowed = 0,
        .dropped = 0,
    });
    try testing.expectError(error.UnsupportedVersion, read(testing.allocator, &version_zero));
}

test "a valid header over random bytes reads without a crash and stays inside its input" {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const random = prng.random();
    var buffer: [1024]u8 = undefined;
    for (0..200) |_| {
        random.bytes(&buffer);
        putHeader(&buffer, .{
            .offset = random.int(u40),
            .count = random.int(u24),
        }, random.int(u64) % 4, random.int(u64));
        var result = try read(testing.allocator, &buffer);
        defer result.deinit(testing.allocator);
        try expectResultInside(&buffer, result);
    }
}

fn expectResultInside(bytes: []const u8, result: Result) !void {
    const start = @intFromPtr(bytes.ptr);
    const stop = start + bytes.len;
    for (result.frames.items) |frame| {
        try testing.expect(frame.offset % 8 == 0);
        try testing.expect(frame.offset >= format.segment_header_bytes);
        const payload_start = @intFromPtr(frame.payload.ptr);
        try testing.expect(payload_start >= start);
        try testing.expect(payload_start + frame.payload.len <= stop);
    }
    for (result.holes.items) |hole| {
        try testing.expect(hole.offset + hole.len <= bytes.len);
    }
}

fn putHeader(buffer: []u8, cursor: format.Cursor, overflowed: u64, dropped: u64) void {
    buffer[0..format.segment_header_bytes].* = format.encodeSegmentHeader(.{
        .format_version = format.format_version,
        .header_bytes = format.segment_header_bytes,
        .instance = 7,
        .index = 0,
        .created_wall_ms = 1_700_000_000_000,
        .capacity = buffer.len,
        .cursor = cursor,
        .overflowed = overflowed,
        .dropped = dropped,
    });
}

fn putFrame(buffer: []u8, at: usize, seq: u64, reservation: u32, payload: []const u8) !usize {
    const written = try format.encodeFrame(buffer[at..], .{
        .payload_len = @intCast(payload.len),
        .kind = 3,
        .flags = 0,
        .thread = 1,
        .reservation_index = reservation,
        .seq = seq,
        .mono_ns = seq * 10,
        .wall_ms = 1000 + seq,
    }, payload);
    return at + written;
}
