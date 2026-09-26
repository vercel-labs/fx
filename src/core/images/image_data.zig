const std = @import("std");
const types = @import("../shared/types.zig");
const Allocator = std.mem.Allocator;

pub const max_encoded_image_bytes: usize = 5 * 1024 * 1024;
pub const max_result_frame_bytes: usize = 8 * 1024 * 1024;
pub const max_tool_images: usize = 8;
pub const Error = Allocator.Error || error{ InvalidImage, ImageLimitExceeded, UnsupportedImageType };

/// Owns validated images until take transfers them to the result owner.
pub const ImageList = struct {
    alloc: Allocator,
    items: std.ArrayList(types.ToolImage) = .empty,
    encoded_bytes: usize = 0,

    pub fn deinit(self: *ImageList) void {
        for (self.items.items) |item| {
            self.alloc.free(item.data);
            self.alloc.free(item.mime_type);
        }
        self.items.deinit(self.alloc);
    }

    pub fn append(self: *ImageList, data: []const u8, mime_type: []const u8) Error!void {
        if (self.items.items.len >= max_tool_images or data.len > max_result_frame_bytes -| self.encoded_bytes) return error.ImageLimitExceeded;
        try validateImage(self.alloc, data, mime_type);
        const owned_data = try self.alloc.dupe(u8, data);
        errdefer self.alloc.free(owned_data);
        const owned_type = try self.alloc.dupe(u8, mime_type);
        errdefer self.alloc.free(owned_type);
        try self.items.append(self.alloc, .{ .data = owned_data, .mime_type = owned_type });
        self.encoded_bytes += data.len;
    }

    pub fn take(self: *ImageList) Allocator.Error![]types.ToolImage {
        const images = try self.items.toOwnedSlice(self.alloc);
        self.encoded_bytes = 0;
        return images;
    }
};

pub fn parseToolImages(alloc: Allocator, content: []const std.json.Value) Error![]types.ToolImage {
    var images = ImageList{ .alloc = alloc };
    defer images.deinit();
    for (content) |item| {
        if (item != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string) continue;
        const embedded = std.mem.eql(u8, kind.string, "resource");
        if (!embedded and !std.mem.eql(u8, kind.string, "image")) continue;
        const block = if (embedded) item.object.get("resource") orelse continue else item;
        if (block != .object) continue;
        const data = block.object.get(if (embedded) "blob" else "data") orelse {
            if (embedded) continue;
            return error.InvalidImage;
        };
        const mime_type = block.object.get("mimeType") orelse {
            if (embedded) continue;
            return error.InvalidImage;
        };
        if (data != .string or mime_type != .string) return error.InvalidImage;
        if (!supportedMediaType(mime_type.string)) continue;
        try images.append(data.string, mime_type.string);
    }
    return images.take();
}

pub fn supportedMediaType(mime_type: []const u8) bool {
    for ([_][]const u8{ "image/png", "image/jpeg", "image/gif", "image/webp" }) |supported| {
        if (std.mem.eql(u8, mime_type, supported)) return true;
    }
    return false;
}

pub fn validateImage(alloc: Allocator, encoded: []const u8, mime_type: []const u8) Error!void {
    if (encoded.len == 0 or encoded.len > max_encoded_image_bytes) return error.ImageLimitExceeded;
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return error.InvalidImage;
    const bytes = try alloc.alloc(u8, size);
    defer alloc.free(bytes);
    decoder.decode(bytes, encoded) catch return error.InvalidImage;
    const detected = detectMediaTypeFromBytes(bytes) orelse return error.UnsupportedImageType;
    if (!std.mem.eql(u8, detected, mime_type)) return error.InvalidImage;
}

pub fn detectMediaTypeFromBytes(bytes: []const u8) ?[]const u8 {
    return switch (detectFormat(bytes) orelse return null) {
        .png => "image/png",
        .jpeg => "image/jpeg",
        .gif => "image/gif",
        .webp => "image/webp",
    };
}

const ImageFormat = enum { png, jpeg, gif, webp };

fn detectFormat(bytes: []const u8) ?ImageFormat {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return .jpeg;
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return .gif;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    return null;
}

/// Longest side, in pixels, of any image fx sends to a model. Gateway provider
/// routes reject larger images once a request carries many images (2000 on the
/// strictest routes, 2576 on others). Images stay in conversation history, so
/// one conservative bound keeps every later request valid.
pub const max_image_dimension: u32 = 2000;

pub const Dimensions = struct {
    width: u32,
    height: u32,

    pub fn exceedsModelLimit(self: Dimensions) bool {
        return self.width > max_image_dimension or self.height > max_image_dimension;
    }
};

/// Reads pixel dimensions from a PNG, JPEG, GIF, or WebP header without
/// decoding pixels. Returns null for unsupported, truncated, or malformed
/// headers, including a JPEG whose frame header lies beyond `bytes`.
pub fn imageDimensions(bytes: []const u8) ?Dimensions {
    return dimensionsFrom(.{ .raw = bytes });
}

/// `imageDimensions` for standard base64 image data. Decodes only the header
/// bytes it inspects, so it never allocates or decodes the whole image.
pub fn encodedImageDimensions(encoded: []const u8) ?Dimensions {
    return dimensionsFrom(.{ .base64 = encoded });
}

const ImageBytes = union(enum) {
    raw: []const u8,
    base64: []const u8,

    /// Copies decoded bytes starting at `offset` into `buffer` and returns the
    /// copied prefix. The prefix is shorter than `buffer` at the end of the
    /// data or where base64 text is malformed.
    fn read(self: ImageBytes, offset: usize, buffer: []u8) []const u8 {
        switch (self) {
            .raw => |bytes| {
                if (offset >= bytes.len) return buffer[0..0];
                const count = @min(buffer.len, bytes.len - offset);
                @memcpy(buffer[0..count], bytes[offset..][0..count]);
                return buffer[0..count];
            },
            .base64 => |encoded| return readBase64(encoded, offset, buffer),
        }
    }
};

fn readBase64(encoded: []const u8, offset: usize, buffer: []u8) []const u8 {
    const decoder = std.base64.standard.Decoder;
    var written: usize = 0;
    var group = offset / 3;
    var skip = offset % 3;
    while (written < buffer.len) : (group += 1) {
        const start = std.math.mul(usize, group, 4) catch break;
        if (start >= encoded.len or encoded.len - start < 4) break;
        const quad = encoded[start..][0..4];
        var decoded: [3]u8 = undefined;
        const decoded_len = decoder.calcSizeForSlice(quad) catch break;
        decoder.decode(decoded[0..decoded_len], quad) catch break;
        if (skip < decoded_len) {
            const count = @min(decoded_len - skip, buffer.len - written);
            @memcpy(buffer[written..][0..count], decoded[skip..][0..count]);
            written += count;
        }
        skip = 0;
        if (decoded_len < 3) break;
    }
    return buffer[0..written];
}

/// Longest fixed-offset header any supported format needs (WebP VP8/VP8X).
const header_probe_bytes = 30;
/// Bounds the JPEG marker walk; real files reach their frame header within a
/// few dozen segments.
const max_jpeg_segments = 4096;

fn dimensionsFrom(source: ImageBytes) ?Dimensions {
    var header_buffer: [header_probe_bytes]u8 = undefined;
    const header = source.read(0, &header_buffer);
    return switch (detectFormat(header) orelse return null) {
        .png => pngDimensions(header),
        .jpeg => jpegDimensions(source),
        .gif => gifDimensions(header),
        .webp => webpDimensions(header),
    };
}

fn nonZero(width: u32, height: u32) ?Dimensions {
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

fn pngDimensions(header: []const u8) ?Dimensions {
    if (header.len < 24 or !std.mem.eql(u8, header[12..16], "IHDR")) return null;
    return nonZero(
        std.mem.readInt(u32, header[16..20], .big),
        std.mem.readInt(u32, header[20..24], .big),
    );
}

fn gifDimensions(header: []const u8) ?Dimensions {
    if (header.len < 10) return null;
    return nonZero(
        std.mem.readInt(u16, header[6..8], .little),
        std.mem.readInt(u16, header[8..10], .little),
    );
}

fn webpDimensions(header: []const u8) ?Dimensions {
    if (header.len < 16) return null;
    const chunk = header[12..16];
    if (std.mem.eql(u8, chunk, "VP8 ")) {
        if (header.len < 30 or !std.mem.eql(u8, header[23..26], "\x9d\x01\x2a")) return null;
        return nonZero(
            std.mem.readInt(u16, header[26..28], .little) & 0x3fff,
            std.mem.readInt(u16, header[28..30], .little) & 0x3fff,
        );
    }
    if (std.mem.eql(u8, chunk, "VP8L")) {
        if (header.len < 25 or header[20] != 0x2f) return null;
        const bits = std.mem.readInt(u32, header[21..25], .little);
        return nonZero((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
    }
    if (std.mem.eql(u8, chunk, "VP8X")) {
        if (header.len < 30) return null;
        return nonZero(
            @as(u32, std.mem.readInt(u24, header[24..27], .little)) + 1,
            @as(u32, std.mem.readInt(u24, header[27..30], .little)) + 1,
        );
    }
    return null;
}

fn isJpegStartOfFrame(marker: u8) bool {
    return switch (marker) {
        0xc0...0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => true,
        else => false,
    };
}

/// Walks JPEG marker segments to the first frame header. Each step advances
/// the offset, and the walk stops after `max_jpeg_segments` markers.
fn jpegDimensions(source: ImageBytes) ?Dimensions {
    var offset: usize = 2;
    for (0..max_jpeg_segments) |_| {
        var segment_buffer: [9]u8 = undefined;
        const segment = source.read(offset, &segment_buffer);
        if (segment.len < 2 or segment[0] != 0xff) return null;
        const marker = segment[1];
        switch (marker) {
            // Fill byte before a marker.
            0xff => offset += 1,
            // Standalone markers carry no length.
            0x01, 0xd0...0xd8 => offset += 2,
            // End of image or scan data before any frame header.
            0xd9, 0xda => return null,
            else => {
                if (segment.len < 4) return null;
                const length = std.mem.readInt(u16, segment[2..4], .big);
                if (length < 2) return null;
                if (isJpegStartOfFrame(marker)) {
                    if (segment.len < 9) return null;
                    return nonZero(
                        std.mem.readInt(u16, segment[7..9], .big),
                        std.mem.readInt(u16, segment[5..7], .big),
                    );
                }
                offset = std.math.add(usize, offset, 2 + @as(usize, length)) catch return null;
            },
        }
    }
    return null;
}

fn testPngHeader(width: u32, height: u32) [24]u8 {
    var bytes: [24]u8 = undefined;
    @memcpy(bytes[0..16], "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR");
    std.mem.writeInt(u32, bytes[16..20], width, .big);
    std.mem.writeInt(u32, bytes[20..24], height, .big);
    return bytes;
}

// SOI, APP0, DHT, one fill byte, then a progressive frame header and EOI, so
// the marker walk crosses variable-length, standalone, and fill markers.
const test_jpeg_template = "\xff\xd8" ++
    "\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00" ++
    "\xff\xc4\x00\x04\x00\x00" ++
    "\xff" ++
    "\xff\xc2\x00\x11\x08\x00\x00\x00\x00\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01" ++
    "\xff\xd9";
const test_jpeg_frame_offset = 27;

fn testJpeg(width: u16, height: u16) [test_jpeg_template.len]u8 {
    var bytes = test_jpeg_template.*;
    std.mem.writeInt(u16, bytes[test_jpeg_frame_offset + 5 ..][0..2], height, .big);
    std.mem.writeInt(u16, bytes[test_jpeg_frame_offset + 7 ..][0..2], width, .big);
    return bytes;
}

fn testGif(width: u16, height: u16) [10]u8 {
    var bytes: [10]u8 = undefined;
    @memcpy(bytes[0..6], "GIF89a");
    std.mem.writeInt(u16, bytes[6..8], width, .little);
    std.mem.writeInt(u16, bytes[8..10], height, .little);
    return bytes;
}

fn testWebpHeader(chunk: *const [4]u8) [30]u8 {
    var bytes = [_]u8{0} ** 30;
    @memcpy(bytes[0..4], "RIFF");
    @memcpy(bytes[8..12], "WEBP");
    @memcpy(bytes[12..16], chunk);
    return bytes;
}

fn testWebpLossy(width: u16, height: u16) [30]u8 {
    var bytes = testWebpHeader("VP8 ");
    @memcpy(bytes[23..26], "\x9d\x01\x2a");
    std.mem.writeInt(u16, bytes[26..28], width, .little);
    std.mem.writeInt(u16, bytes[28..30], height, .little);
    return bytes;
}

fn testWebpLossless(width: u32, height: u32) [25]u8 {
    const full = testWebpHeader("VP8L");
    var bytes: [25]u8 = full[0..25].*;
    bytes[20] = 0x2f;
    std.mem.writeInt(u32, bytes[21..25], (width - 1) | ((height - 1) << 14), .little);
    return bytes;
}

fn testWebpExtended(width: u32, height: u32) [30]u8 {
    var bytes = testWebpHeader("VP8X");
    std.mem.writeInt(u24, bytes[24..27], @intCast(width - 1), .little);
    std.mem.writeInt(u24, bytes[27..30], @intCast(height - 1), .little);
    return bytes;
}

fn expectDimensions(expected: Dimensions, bytes: []const u8) !void {
    try std.testing.expectEqual(@as(?Dimensions, expected), imageDimensions(bytes));
}

test "image dimensions read every supported header" {
    try expectDimensions(.{ .width = 3420, .height = 2224 }, &testPngHeader(3420, 2224));
    try expectDimensions(.{ .width = 3420, .height = 2224 }, &testJpeg(3420, 2224));
    try expectDimensions(.{ .width = 640, .height = 480 }, &testGif(640, 480));
    try expectDimensions(.{ .width = 2001, .height = 17 }, &testWebpLossy(2001, 17));
    try expectDimensions(.{ .width = 16384, .height = 3 }, &testWebpLossless(16384, 3));
    try expectDimensions(.{ .width = 5000, .height = 2 }, &testWebpExtended(5000, 2));
}

test "model image limit allows exactly the maximum side" {
    try std.testing.expect(!(Dimensions{ .width = max_image_dimension, .height = max_image_dimension }).exceedsModelLimit());
    try std.testing.expect((Dimensions{ .width = max_image_dimension + 1, .height = 1 }).exceedsModelLimit());
    try std.testing.expect((Dimensions{ .width = 1, .height = max_image_dimension + 1 }).exceedsModelLimit());
}

test "image dimensions reject malformed and truncated headers" {
    const png = testPngHeader(10, 10);
    try std.testing.expectEqual(@as(?Dimensions, null), imageDimensions(png[0..23]));
    try std.testing.expectEqual(@as(?Dimensions, null), imageDimensions(&testPngHeader(0, 10)));
    var not_ihdr = png;
    @memcpy(not_ihdr[12..16], "IDAT");
    try std.testing.expectEqual(@as(?Dimensions, null), imageDimensions(&not_ihdr));

    const jpeg = testJpeg(10, 10);
    try std.testing.expectEqual(@as(?Dimensions, null), imageDimensions(jpeg[0 .. test_jpeg_frame_offset + 8]));
    var scan_first = jpeg;
    scan_first[3] = 0xda;
    try std.testing.expectEqual(@as(?Dimensions, null), imageDimensions(&scan_first));
    var short_length = jpeg;
    std.mem.writeInt(u16, short_length[4..6], 1, .big);
    try std.testing.expectEqual(@as(?Dimensions, null), imageDimensions(&short_length));

    try std.testing.expectEqual(@as(?Dimensions, null), imageDimensions(&testGif(0, 3)));
    try std.testing.expectEqual(@as(?Dimensions, null), imageDimensions(&testWebpHeader("ALPH")));
    try std.testing.expectEqual(@as(?Dimensions, null), imageDimensions("not an image at all, just text"));
    try std.testing.expectEqual(@as(?Dimensions, null), imageDimensions(""));
}

fn expectEncodedAgreesWithRaw(bytes: []const u8) !void {
    var encoded_buffer: [std.base64.standard.Encoder.calcSize(1024)]u8 = undefined;
    std.debug.assert(bytes.len <= 1024);
    const encoded = std.base64.standard.Encoder.encode(&encoded_buffer, bytes);
    try std.testing.expectEqual(imageDimensions(bytes), encodedImageDimensions(encoded));
}

test "encoded image dimensions agree with raw headers at every truncation" {
    const fixtures = [_][]const u8{
        &testPngHeader(3420, 2224),
        &testJpeg(3420, 2224),
        &testGif(640, 480),
        &testWebpLossy(2001, 17),
        &testWebpLossless(16384, 3),
        &testWebpExtended(5000, 2),
    };
    for (fixtures) |fixture| {
        for (0..fixture.len + 1) |len| try expectEncodedAgreesWithRaw(fixture[0..len]);
    }
    try std.testing.expectEqual(@as(?Dimensions, null), encodedImageDimensions("not base64 at all"));
}

test "image dimension parsing stays bounded on arbitrary bytes" {
    try std.testing.fuzz({}, fuzzImageDimensions, .{
        .corpus = &.{
            &testPngHeader(3420, 2224),
            &testJpeg(2001, 1),
            &testGif(1, 1),
            &testWebpExtended(2, 2),
            "\xff\xd8\xff\xff\xff\xff",
        },
    });
}

fn fuzzImageDimensions(_: void, smith: *std.testing.Smith) !void {
    var bytes: [1024]u8 = undefined;
    const len: usize = @intCast(smith.slice(&bytes));
    try expectEncodedAgreesWithRaw(bytes[0..len]);
}

test "tool images validate data and declared media type" {
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
    try validateImage(std.testing.allocator, png, "image/png");
    try std.testing.expectError(error.InvalidImage, validateImage(std.testing.allocator, png, "image/jpeg"));
    try std.testing.expectError(error.InvalidImage, validateImage(std.testing.allocator, "not base64", "image/png"));
}
