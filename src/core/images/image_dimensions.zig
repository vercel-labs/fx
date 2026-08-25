const std = @import("std");

pub const Dimensions = struct {
    width: u32,
    height: u32,

    pub fn valid(self: Dimensions) bool {
        return self.width > 0 and self.height > 0;
    }
};

pub fn detect(bytes: []const u8, media_type: []const u8) ?Dimensions {
    const dimensions = if (std.mem.eql(u8, media_type, "image/png"))
        detectPng(bytes)
    else if (std.mem.eql(u8, media_type, "image/jpeg"))
        detectJpeg(bytes)
    else if (std.mem.eql(u8, media_type, "image/gif"))
        detectGif(bytes)
    else if (std.mem.eql(u8, media_type, "image/webp"))
        detectWebp(bytes)
    else
        null;
    if (dimensions) |value| return if (value.valid()) value else null;
    return null;
}

fn detectPng(bytes: []const u8) ?Dimensions {
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{
        .width = readBe32(bytes[16..20]),
        .height = readBe32(bytes[20..24]),
    };
}

fn detectGif(bytes: []const u8) ?Dimensions {
    if (bytes.len < 10) return null;
    if (!std.mem.eql(u8, bytes[0..6], "GIF87a") and
        !std.mem.eql(u8, bytes[0..6], "GIF89a")) return null;
    return .{
        .width = readLe16(bytes[6..8]),
        .height = readLe16(bytes[8..10]),
    };
}

fn detectJpeg(bytes: []const u8) ?Dimensions {
    if (bytes.len < 4 or bytes[0] != 0xff or bytes[1] != 0xd8) return null;

    var offset: usize = 2;
    while (offset < bytes.len) {
        while (offset < bytes.len and bytes[offset] != 0xff) : (offset += 1) {}
        while (offset < bytes.len and bytes[offset] == 0xff) : (offset += 1) {}
        if (offset >= bytes.len) return null;

        const marker = bytes[offset];
        offset += 1;
        if (marker == 0xd9 or marker == 0xda) return null;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
        if (offset + 2 > bytes.len) return null;

        const segment_len: usize = readBe16(bytes[offset .. offset + 2]);
        if (segment_len < 2 or segment_len > bytes.len - offset) return null;
        if (isJpegStartOfFrame(marker)) {
            if (segment_len < 7) return null;
            return .{
                .height = readBe16(bytes[offset + 3 .. offset + 5]),
                .width = readBe16(bytes[offset + 5 .. offset + 7]),
            };
        }
        offset += segment_len;
    }
    return null;
}

fn isJpegStartOfFrame(marker: u8) bool {
    return switch (marker) {
        0xc0,
        0xc1,
        0xc2,
        0xc3,
        0xc5,
        0xc6,
        0xc7,
        0xc9,
        0xca,
        0xcb,
        0xcd,
        0xce,
        0xcf,
        => true,
        else => false,
    };
}

fn detectWebp(bytes: []const u8) ?Dimensions {
    if (bytes.len < 20 or
        !std.mem.eql(u8, bytes[0..4], "RIFF") or
        !std.mem.eql(u8, bytes[8..12], "WEBP")) return null;

    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const kind = bytes[offset .. offset + 4];
        const chunk_len: usize = readLe32(bytes[offset + 4 .. offset + 8]);
        const data_start = offset + 8;
        if (chunk_len > bytes.len - data_start) return null;
        const data = bytes[data_start .. data_start + chunk_len];

        if (std.mem.eql(u8, kind, "VP8X")) {
            if (data.len < 10) return null;
            return .{
                .width = 1 + readLe24(data[4..7]),
                .height = 1 + readLe24(data[7..10]),
            };
        }
        if (std.mem.eql(u8, kind, "VP8L")) {
            if (data.len < 5 or data[0] != 0x2f) return null;
            return .{
                .width = 1 + @as(u32, data[1]) + (@as(u32, data[2] & 0x3f) << 8),
                .height = 1 + (@as(u32, data[2] >> 6) |
                    (@as(u32, data[3]) << 2) |
                    (@as(u32, data[4] & 0x0f) << 10)),
            };
        }
        if (std.mem.eql(u8, kind, "VP8 ")) {
            if (data.len < 10 or !std.mem.eql(u8, data[3..6], "\x9d\x01\x2a")) return null;
            return .{
                .width = readLe16(data[6..8]) & 0x3fff,
                .height = readLe16(data[8..10]) & 0x3fff,
            };
        }

        const padded_len = chunk_len + (chunk_len & 1);
        if (padded_len > bytes.len - data_start) return null;
        offset = data_start + padded_len;
    }
    return null;
}

fn readBe16(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn readBe32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

fn readLe16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readLe24(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16);
}

fn readLe32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

test "detects PNG and GIF dimensions" {
    const png = "\x89PNG\r\n\x1a\n" ++
        "\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x02\x80\x00\x00\x01\xe0";
    try std.testing.expectEqual(Dimensions{ .width = 640, .height = 480 }, detect(png, "image/png").?);

    const gif = "GIF89a\x40\x01\xf0\x00";
    try std.testing.expectEqual(Dimensions{ .width = 320, .height = 240 }, detect(gif, "image/gif").?);
}

test "detects JPEG dimensions after metadata segments" {
    const jpeg = "\xff\xd8" ++
        "\xff\xe0\x00\x04ab" ++
        "\xff\xc2\x00\x0b\x08\x01\xe0\x02\x80\x03\x01\x11\x00" ++
        "\xff\xd9";
    try std.testing.expectEqual(Dimensions{ .width = 640, .height = 480 }, detect(jpeg, "image/jpeg").?);
}

test "detects extended WebP dimensions" {
    const webp = "RIFF\x12\x00\x00\x00WEBP" ++
        "VP8X\x0a\x00\x00\x00" ++
        "\x00\x00\x00\x00\x7f\x02\x00\xdf\x01\x00";
    try std.testing.expectEqual(Dimensions{ .width = 640, .height = 480 }, detect(webp, "image/webp").?);
}
