//! Test fixtures that encode decodable PNG images from raw scanlines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const png_signature = "\x89PNG\r\n\x1a\n";

const ColorType = enum(u8) {
    gray = 0,
    rgb = 2,
    palette = 3,
    gray_alpha = 4,
    rgba = 6,
};

fn writeChunk(writer: *std.Io.Writer, kind: *const [4]u8, data: []const u8) std.Io.Writer.Error!void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try writer.writeAll(&length);
    try writer.writeAll(kind);
    try writer.writeAll(data);
    try writer.writeAll(&checksum);
}

/// Encodes raw scanlines (each already prefixed with its filter byte).
fn testEncode(alloc: Allocator, width: u32, height: u32, color_type: ColorType, bit_depth: u8, scanlines: []const u8, extra_chunks: []const [2][]const u8) ![]u8 {
    var idat = try std.Io.Writer.Allocating.initCapacity(alloc, 1024);
    defer idat.deinit();
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    const compress = try alloc.create(flate.Compress);
    defer alloc.destroy(compress);
    compress.* = try flate.Compress.init(&idat.writer, window, .zlib, .fastest);
    try compress.writer.writeAll(scanlines);
    try compress.finish();

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = bit_depth;
    ihdr[9] = @backingInt(color_type);
    @memset(ihdr[10..13], 0);
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(png_signature);
    try writeChunk(&out.writer, "IHDR", &ihdr);
    for (extra_chunks) |chunk| try writeChunk(&out.writer, chunk[0][0..4], chunk[1]);
    try writeChunk(&out.writer, "IDAT", idat.written());
    try writeChunk(&out.writer, "IEND", "");
    return out.toOwnedSlice();
}

/// Test fixture: `png` with a zero-filled ancillary chunk of `padding_len`
/// bytes after IHDR, which adds bytes without changing its pixels.
pub fn testPaddedPng(alloc: Allocator, png: []const u8, padding_len: u32) ![]u8 {
    const ihdr_end = png_signature.len + 25;
    const padded = try alloc.alloc(u8, png.len + 12 + padding_len);
    @memcpy(padded[0..ihdr_end], png[0..ihdr_end]);
    std.mem.writeInt(u32, padded[ihdr_end..][0..4], padding_len, .big);
    @memcpy(padded[ihdr_end + 4 ..][0..4], "zzPd");
    @memset(padded[ihdr_end + 8 ..][0 .. padding_len + 4], 0);
    @memcpy(padded[ihdr_end + 12 + padding_len ..], png[ihdr_end..]);
    return padded;
}

/// Test fixture: a decodable solid 8-bit gray PNG.
pub fn testSolidGrayPng(alloc: Allocator, width: u32, height: u32, value: u8) ![]u8 {
    const scanlines = try testSolidScanlines(alloc, width, height, &.{value});
    defer alloc.free(scanlines);
    return testEncode(alloc, width, height, .gray, 8, scanlines, &.{});
}

/// Test fixture: an 8-bit palette PNG of random pixels. A copy converted to
/// RGB stores three bytes per pixel instead of one palette index, so it is
/// larger than the source.
pub fn testRandomPalettePng(alloc: Allocator, width: u32, height: u32) ![]u8 {
    var prng = std.Random.DefaultPrng.init(0x2000);
    const random = prng.random();
    var palette: [256 * 3]u8 = undefined;
    random.bytes(&palette);
    const row_len = 1 + @as(usize, width);
    const scanlines = try alloc.alloc(u8, row_len * height);
    defer alloc.free(scanlines);
    for (0..height) |y| {
        const row = scanlines[y * row_len ..][0..row_len];
        row[0] = 0;
        random.bytes(row[1..]);
    }
    return testEncode(alloc, width, height, .palette, 8, scanlines, &.{.{ "PLTE", &palette }});
}

/// Builds unfiltered scanlines of a solid 8-bit image.
fn testSolidScanlines(alloc: Allocator, width: u32, height: u32, pixel: []const u8) ![]u8 {
    const row_len = 1 + @as(usize, width) * pixel.len;
    const scanlines = try alloc.alloc(u8, row_len * height);
    for (0..height) |y| {
        const row = scanlines[y * row_len ..][0..row_len];
        row[0] = 0;
        for (0..width) |x| @memcpy(row[1 + x * pixel.len ..][0..pixel.len], pixel);
    }
    return scanlines;
}
