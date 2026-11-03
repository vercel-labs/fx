//! Dependency-free Zstandard request compression for the Codex endpoint.
//!
//! Zig's standard library currently exposes Zstandard decoding but no encoder.
//! This encoder emits ordinary Zstandard frames and uses compressed blocks for
//! repeated input (RLE and a small LZ sequence with RLE sequence tables). Inputs
//! without a profitable match stay raw and callers can omit Content-Encoding.
const std = @import("std");

const Allocator = std.mem.Allocator;
const max_block_bytes: usize = 1 << 17;

const LengthCode = struct { symbol: u8, extra_bits: u5, extra: u32 };
const CodeEntry = struct { base: u32, bits: u5 };
const BitsEntry = struct { value: u32, bits: u5 };

const literal_lengths = [_]CodeEntry{
    .{ .base = 0, .bits = 0 },     .{ .base = 1, .bits = 0 },      .{ .base = 2, .bits = 0 },      .{ .base = 3, .bits = 0 },
    .{ .base = 4, .bits = 0 },     .{ .base = 5, .bits = 0 },      .{ .base = 6, .bits = 0 },      .{ .base = 7, .bits = 0 },
    .{ .base = 8, .bits = 0 },     .{ .base = 9, .bits = 0 },      .{ .base = 10, .bits = 0 },     .{ .base = 11, .bits = 0 },
    .{ .base = 12, .bits = 0 },    .{ .base = 13, .bits = 0 },     .{ .base = 14, .bits = 0 },     .{ .base = 15, .bits = 0 },
    .{ .base = 16, .bits = 1 },    .{ .base = 18, .bits = 1 },     .{ .base = 20, .bits = 1 },     .{ .base = 22, .bits = 1 },
    .{ .base = 24, .bits = 2 },    .{ .base = 28, .bits = 2 },     .{ .base = 32, .bits = 3 },     .{ .base = 40, .bits = 3 },
    .{ .base = 48, .bits = 4 },    .{ .base = 64, .bits = 6 },     .{ .base = 128, .bits = 7 },    .{ .base = 256, .bits = 8 },
    .{ .base = 512, .bits = 9 },   .{ .base = 1024, .bits = 10 },  .{ .base = 2048, .bits = 11 },  .{ .base = 4096, .bits = 12 },
    .{ .base = 8192, .bits = 13 }, .{ .base = 16384, .bits = 14 }, .{ .base = 32768, .bits = 15 }, .{ .base = 65536, .bits = 16 },
};

const match_lengths = [_]CodeEntry{
    .{ .base = 3, .bits = 0 },      .{ .base = 4, .bits = 0 },     .{ .base = 5, .bits = 0 },      .{ .base = 6, .bits = 0 },
    .{ .base = 7, .bits = 0 },      .{ .base = 8, .bits = 0 },     .{ .base = 9, .bits = 0 },      .{ .base = 10, .bits = 0 },
    .{ .base = 11, .bits = 0 },     .{ .base = 12, .bits = 0 },    .{ .base = 13, .bits = 0 },     .{ .base = 14, .bits = 0 },
    .{ .base = 15, .bits = 0 },     .{ .base = 16, .bits = 0 },    .{ .base = 17, .bits = 0 },     .{ .base = 18, .bits = 0 },
    .{ .base = 19, .bits = 0 },     .{ .base = 20, .bits = 0 },    .{ .base = 21, .bits = 0 },     .{ .base = 22, .bits = 0 },
    .{ .base = 23, .bits = 0 },     .{ .base = 24, .bits = 0 },    .{ .base = 25, .bits = 0 },     .{ .base = 26, .bits = 0 },
    .{ .base = 27, .bits = 0 },     .{ .base = 28, .bits = 0 },    .{ .base = 29, .bits = 0 },     .{ .base = 30, .bits = 0 },
    .{ .base = 31, .bits = 0 },     .{ .base = 32, .bits = 0 },    .{ .base = 33, .bits = 0 },     .{ .base = 34, .bits = 0 },
    .{ .base = 35, .bits = 1 },     .{ .base = 37, .bits = 1 },    .{ .base = 39, .bits = 1 },     .{ .base = 41, .bits = 1 },
    .{ .base = 43, .bits = 2 },     .{ .base = 47, .bits = 2 },    .{ .base = 51, .bits = 3 },     .{ .base = 59, .bits = 3 },
    .{ .base = 67, .bits = 4 },     .{ .base = 83, .bits = 4 },    .{ .base = 99, .bits = 5 },     .{ .base = 131, .bits = 7 },
    .{ .base = 259, .bits = 8 },    .{ .base = 515, .bits = 9 },   .{ .base = 1027, .bits = 10 },  .{ .base = 2051, .bits = 11 },
    .{ .base = 4099, .bits = 12 },  .{ .base = 8195, .bits = 13 }, .{ .base = 16387, .bits = 14 }, .{ .base = 32771, .bits = 15 },
    .{ .base = 65539, .bits = 16 },
};

const Match = struct {
    start: usize,
    length: usize,
    distance: usize,
    literal_code: LengthCode,
    match_code: LengthCode,
    offset_code: LengthCode,
};

fn lengthCode(table: []const CodeEntry, value: usize) ?LengthCode {
    const number = std.math.cast(u32, value) orelse return null;
    for (table, 0..) |entry, index| {
        const width: u32 = @as(u32, 1) << entry.bits;
        if (number >= entry.base and number - entry.base < width) {
            return .{
                .symbol = @intCast(index),
                .extra_bits = entry.bits,
                .extra = number - entry.base,
            };
        }
    }
    return null;
}

fn offsetCode(distance: usize) ?LengthCode {
    const value = std.math.add(usize, distance, 3) catch return null;
    if (value == 0) return null;
    const code: u5 = @intCast(std.math.log2_int(usize, value));
    const base: usize = @as(usize, 1) << code;
    return .{ .symbol = code, .extra_bits = code, .extra = @intCast(value - base) };
}

fn bitsFor(m: Match) usize {
    return @as(usize, m.offset_code.extra_bits) + m.match_code.extra_bits + m.literal_code.extra_bits;
}

fn findMatch(alloc: Allocator, input: []const u8) !?Match {
    if (input.len < 16) return null;
    var positions = std.AutoHashMap(u32, usize).init(alloc);
    defer positions.deinit();
    var best: ?Match = null;
    var index: usize = 0;
    while (index + 4 <= input.len) : (index += 1) {
        const key = std.mem.readInt(u32, input[index..][0..4], .little);
        if (positions.get(key)) |previous| {
            const distance = index - previous;
            if (distance <= 65_535) {
                var length: usize = 0;
                while (index + length < input.len and input[previous + length] == input[index + length]) : (length += 1) {}
                if (length >= 8) {
                    var candidate_length = length;
                    while (candidate_length >= 3) : (candidate_length -= 1) {
                        const literal_code = lengthCode(&literal_lengths, index) orelse continue;
                        const match_code = lengthCode(&match_lengths, candidate_length) orelse continue;
                        const offset_code = offsetCode(distance) orelse continue;
                        const candidate = Match{
                            .start = index,
                            .length = candidate_length,
                            .distance = distance,
                            .literal_code = literal_code,
                            .match_code = match_code,
                            .offset_code = offset_code,
                        };
                        if (bitsFor(candidate) % 8 == 7 and (best == null or candidate.length > best.?.length)) {
                            best = candidate;
                            break;
                        }
                    }
                }
            }
        }
        // Keeping the most recent occurrence favors a short offset and lets
        // overlapping matches represent repeated JSON/text efficiently.
        try positions.put(key, index);
    }
    return best;
}

fn writeLiteralsHeader(writer: *std.Io.Writer, length: usize) !void {
    if (length <= 31) {
        try writer.writeByte(@intCast(length << 3));
    } else if (length <= 4095) {
        try writer.writeByte(@intCast(((length & 0xf) << 4) | (1 << 2)));
        try writer.writeByte(@intCast(length >> 4));
    } else {
        try writer.writeByte(@intCast(((length & 0xf) << 4) | (3 << 2)));
        try writer.writeByte(@intCast((length >> 4) & 0xff));
        try writer.writeByte(@intCast(length >> 12));
    }
}

fn writeBits(writer: *std.Io.Writer, values: []const BitsEntry) !void {
    var count: usize = 1;
    for (values) |value| count += value.bits;
    std.debug.assert(count % 8 == 0);
    const bytes_needed = count / 8;
    var bytes: [8]u8 = undefined;
    var byte_count: usize = 0;
    var current: u8 = 0x80;
    var used: usize = 1;
    for (values) |value| {
        var bit: u5 = value.bits;
        while (bit > 0) : (bit -= 1) {
            const shift: u5 = bit - 1;
            current |= @as(u8, @intCast((value.value >> shift) & 1)) << @intCast(7 - used);
            used += 1;
            if (used == 8) {
                bytes[byte_count] = current;
                byte_count += 1;
                current = 0;
                used = 0;
            }
        }
    }
    if (used != 0) {
        bytes[byte_count] = current;
        byte_count += 1;
    }
    std.debug.assert(byte_count == bytes_needed);
    var index = byte_count;
    while (index > 0) {
        index -= 1;
        try writer.writeByte(bytes[index]);
    }
}

fn compressedPayload(alloc: Allocator, input: []const u8, match: Match) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const literal_count = input.len - match.length;
    try writeLiteralsHeader(&out.writer, literal_count);
    try out.writer.writeAll(input[0..match.start]);
    try out.writer.writeAll(input[match.start + match.length ..]);
    // One sequence, all three entropy tables in RLE mode. This is a legal
    // compressed block and avoids shipping a second FSE table implementation.
    try out.writer.writeByte(1);
    try out.writer.writeByte(0x54);
    try out.writer.writeByte(match.literal_code.symbol);
    try out.writer.writeByte(match.offset_code.symbol);
    try out.writer.writeByte(match.match_code.symbol);
    const bits = [_]BitsEntry{
        .{ .value = match.offset_code.extra, .bits = match.offset_code.extra_bits },
        .{ .value = match.match_code.extra, .bits = match.match_code.extra_bits },
        .{ .value = match.literal_code.extra, .bits = match.literal_code.extra_bits },
    };
    try writeBits(&out.writer, &bits);
    return out.toOwnedSlice();
}

fn blockHeader(writer: *std.Io.Writer, size: usize, block_type: u2, last: bool) !void {
    const header: u32 = (@as(u32, @intCast(size)) << 3) | (@as(u32, block_type) << 1) | @intFromBool(last);
    try writer.writeByte(@intCast(header & 0xff));
    try writer.writeByte(@intCast((header >> 8) & 0xff));
    try writer.writeByte(@intCast((header >> 16) & 0xff));
}

fn writeBlock(alloc: Allocator, writer: *std.Io.Writer, input: []const u8, last: bool) !void {
    if (input.len == 0) {
        try blockHeader(writer, 0, 0, last);
        return;
    }
    var repeated = true;
    for (input[1..]) |byte| if (byte != input[0]) {
        repeated = false;
        break;
    };
    if (repeated and input.len >= 5) {
        try blockHeader(writer, input.len, 1, last);
        try writer.writeByte(input[0]);
        return;
    }
    if (try findMatch(alloc, input)) |match| {
        const body = try compressedPayload(alloc, input, match);
        defer alloc.free(body);
        if (body.len + 3 < input.len + 3) {
            try blockHeader(writer, body.len, 2, last);
            try writer.writeAll(body);
            return;
        }
    }
    try blockHeader(writer, input.len, 0, last);
    try writer.writeAll(input);
}

/// Encode `input` as a Zstandard frame. The result is valid even when no
/// profitable match exists; callers should use it only when it is smaller than
/// the original body.
pub fn encode(alloc: Allocator, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var magic: [4]u8 = undefined;
    var content_size: [8]u8 = undefined;
    std.mem.writeInt(u32, &magic, 0xFD2FB528, .little);
    std.mem.writeInt(u64, &content_size, input.len, .little);
    try out.writer.writeAll(&magic);
    try out.writer.writeByte(0xE0); // single segment, 8-byte content size
    try out.writer.writeAll(&content_size);
    if (input.len == 0) {
        try writeBlock(alloc, &out.writer, &.{}, true);
    } else {
        var offset: usize = 0;
        while (offset < input.len) {
            const size = @min(max_block_bytes, input.len - offset);
            try writeBlock(alloc, &out.writer, input[offset .. offset + size], offset + size == input.len);
            offset += size;
        }
    }
    return out.toOwnedSlice();
}

test "Codex zstd frame preserves a request body" {
    const plain = "{\"model\":\"gpt-5.4\",\"stream\":true}";
    const compressed = try encode(std.testing.allocator, plain);
    defer std.testing.allocator.free(compressed);
    var input: std.Io.Reader = .fixed(compressed);
    var decoder: std.compress.zstd.Decompress = .init(&input, &.{}, .{});
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try decoder.reader.streamRemaining(&output.writer);
    try std.testing.expectEqualStrings(plain, output.written());
}

test "Codex zstd large literal section keeps high size bits" {
    var plain: [8192]u8 = undefined;
    for (0..6000) |i| plain[i] = @intCast((i * 37 + (i / 17) * 11) & 0xff);
    const pattern = "0123456789abcdef";
    @memcpy(plain[5000..5016], pattern);
    for (6000..plain.len) |i| plain[i] = pattern[(i - 6000) % pattern.len];
    const compressed = try encode(std.testing.allocator, &plain);
    defer std.testing.allocator.free(compressed);
    var input: std.Io.Reader = .fixed(compressed);
    var decoder: std.compress.zstd.Decompress = .init(&input, &.{}, .{});
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try decoder.reader.streamRemaining(&output.writer);
    try std.testing.expectEqualSlices(u8, &plain, output.written());
}

test "Codex zstd encoder compresses repeated sequence text" {
    var plain: [512]u8 = undefined;
    for (0..plain.len) |i| plain[i] = "abcde"[i % 5];
    const compressed = try encode(std.testing.allocator, &plain);
    defer std.testing.allocator.free(compressed);
    try std.testing.expect(compressed.len < plain.len);
    var input: std.Io.Reader = .fixed(compressed);
    var decoder: std.compress.zstd.Decompress = .init(&input, &.{}, .{});
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try decoder.reader.streamRemaining(&output.writer);
    try std.testing.expectEqualSlices(u8, &plain, output.written());
}

test "Codex zstd encoder compresses repeated request text" {
    var plain: [512]u8 = undefined;
    @memset(&plain, 'a');
    const compressed = try encode(std.testing.allocator, &plain);
    defer std.testing.allocator.free(compressed);
    try std.testing.expect(compressed.len < plain.len);
    var input: std.Io.Reader = .fixed(compressed);
    var decoder: std.compress.zstd.Decompress = .init(&input, &.{}, .{});
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try decoder.reader.streamRemaining(&output.writer);
    try std.testing.expectEqualSlices(u8, &plain, output.written());
}
