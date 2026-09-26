//! Shrinks PNG images so neither side exceeds a limit. Decoding streams one
//! source row at a time through a box filter, so working memory stays
//! proportional to the image width; only the smaller output is materialized.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Largest accepted source side. Bounds row buffers.
const max_source_side: u32 = 16384;
/// Largest accepted source pixel count, the largest image a provider accepts.
/// Bounds decompression work for inputs that claim huge dimensions.
const max_source_pixels: u64 = 8000 * 8000;

const png_signature = "\x89PNG\r\n\x1a\n";

pub const Error = Allocator.Error || error{ InvalidPng, UnsupportedPng };

pub const Downscaled = struct {
    /// PNG bytes owned by the allocator passed to `downscale`.
    png: []u8,
    width: u32,
    height: u32,
};

/// Returns a copy of `png` scaled down, preserving aspect ratio, so neither
/// side exceeds `max_side`. Malformed input returns `error.InvalidPng`;
/// interlaced or oversized input returns `error.UnsupportedPng`.
pub fn downscale(alloc: Allocator, png: []const u8, max_side: u32) Error!Downscaled {
    std.debug.assert(max_side > 0);
    const parsed = try parse(alloc, png);
    defer alloc.free(parsed.idat);
    const header = parsed.header;
    const target = targetSize(header.width, header.height, max_side);
    const channels = outputChannels(header.color_type, parsed.transparency.len > 0);

    var encoder = try RowEncoder.init(alloc, target.width, channels);
    defer encoder.deinit(alloc);
    try encoder.start();
    try decodeInto(alloc, parsed, target, channels, &encoder);

    const encoded = try encoder.finish(alloc, target.width, target.height, channels);
    return .{ .png = encoded, .width = target.width, .height = target.height };
}

const ColorType = enum(u8) {
    gray = 0,
    rgb = 2,
    palette = 3,
    gray_alpha = 4,
    rgba = 6,
};

const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
};

const Parsed = struct {
    header: Header,
    /// Borrowed from the input PNG.
    palette: []const u8,
    /// Borrowed from the input PNG.
    transparency: []const u8,
    /// Concatenated IDAT payload, owned by the `downscale` allocator.
    idat: []u8,
};

const Size = struct { width: u32, height: u32 };

fn parse(alloc: Allocator, png: []const u8) Error!Parsed {
    if (png.len < png_signature.len or !std.mem.eql(u8, png[0..png_signature.len], png_signature)) return error.InvalidPng;
    var offset: usize = png_signature.len;
    var header: ?Header = null;
    var palette: []const u8 = &.{};
    var transparency: []const u8 = &.{};
    var idat: std.ArrayList(u8) = .empty;
    errdefer idat.deinit(alloc);
    while (true) {
        // Length, type, and CRC framing need 12 bytes around the payload.
        if (png.len - offset < 12) return error.InvalidPng;
        const length = std.mem.readInt(u32, png[offset..][0..4], .big);
        const kind = png[offset + 4 ..][0..4];
        const data_start = offset + 8;
        if (length > png.len - data_start - 4) return error.InvalidPng;
        const data = png[data_start..][0..length];
        offset = data_start + length + 4;

        if (header == null) {
            if (!std.mem.eql(u8, kind, "IHDR")) return error.InvalidPng;
            header = try parseHeader(data);
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette = data;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            transparency = data;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(alloc, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
    }
    const parsed_header = header.?;
    if (parsed_header.color_type == .palette) {
        if (palette.len == 0 or palette.len % 3 != 0) return error.InvalidPng;
    } else {
        // tRNS only carries per-entry alpha for palette images; a single
        // transparent color key for gray or RGB is rendered opaque.
        transparency = &.{};
    }
    if (idat.items.len == 0) return error.InvalidPng;
    return .{
        .header = parsed_header,
        .palette = palette,
        .transparency = transparency,
        .idat = try idat.toOwnedSlice(alloc),
    };
}

fn parseHeader(data: []const u8) Error!Header {
    if (data.len != 13) return error.InvalidPng;
    const width = std.mem.readInt(u32, data[0..4], .big);
    const height = std.mem.readInt(u32, data[4..8], .big);
    const bit_depth = data[8];
    const color_type = std.enums.fromInt(ColorType, data[9]) orelse return error.InvalidPng;
    if (width == 0 or height == 0) return error.InvalidPng;
    if (data[10] != 0 or data[11] != 0) return error.InvalidPng;
    switch (data[12]) {
        0 => {},
        1 => return error.UnsupportedPng,
        else => return error.InvalidPng,
    }
    if (width > max_source_side or height > max_source_side) return error.UnsupportedPng;
    if (@as(u64, width) * height > max_source_pixels) return error.UnsupportedPng;
    const depth_valid = switch (color_type) {
        .gray => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8 or bit_depth == 16,
        .palette => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8,
        .rgb, .gray_alpha, .rgba => bit_depth == 8 or bit_depth == 16,
    };
    if (!depth_valid) return error.InvalidPng;
    return .{ .width = width, .height = height, .bit_depth = bit_depth, .color_type = color_type };
}

fn samplesPerPixel(color_type: ColorType) u32 {
    return switch (color_type) {
        .gray, .palette => 1,
        .gray_alpha => 2,
        .rgb => 3,
        .rgba => 4,
    };
}

fn outputChannels(color_type: ColorType, has_palette_alpha: bool) u32 {
    return switch (color_type) {
        .gray => 1,
        .gray_alpha => 2,
        .rgb => 3,
        .rgba => 4,
        .palette => if (has_palette_alpha) 4 else 3,
    };
}

fn outputColorType(channels: u32) u8 {
    return switch (channels) {
        1 => @intFromEnum(ColorType.gray),
        2 => @intFromEnum(ColorType.gray_alpha),
        3 => @intFromEnum(ColorType.rgb),
        4 => @intFromEnum(ColorType.rgba),
        else => unreachable,
    };
}

/// Scales the longer side to `max_side` and rounds the shorter side, keeping
/// at least one pixel. Sizes already within the limit are unchanged.
fn targetSize(width: u32, height: u32, max_side: u32) Size {
    if (width <= max_side and height <= max_side) return .{ .width = width, .height = height };
    if (width >= height) {
        const scaled = (@as(u64, height) * max_side + width / 2) / width;
        return .{ .width = max_side, .height = @intCast(@max(1, scaled)) };
    }
    const scaled = (@as(u64, width) * max_side + height / 2) / height;
    return .{ .width = @intCast(@max(1, scaled)), .height = max_side };
}

fn decodeInto(alloc: Allocator, parsed: Parsed, target: Size, channels: u32, encoder: *RowEncoder) Error!void {
    const header = parsed.header;
    const bits_per_pixel = samplesPerPixel(header.color_type) * header.bit_depth;
    const row_bytes: usize = @intCast((@as(u64, header.width) * bits_per_pixel + 7) / 8);
    const filter_stride: usize = @max(1, bits_per_pixel / 8);

    var current = try alloc.alloc(u8, row_bytes);
    defer alloc.free(current);
    var previous = try alloc.alloc(u8, row_bytes);
    defer alloc.free(previous);
    @memset(previous, 0);
    const pixels = try alloc.alloc(u8, @as(usize, header.width) * channels);
    defer alloc.free(pixels);
    const column_map = try alloc.alloc(u32, header.width);
    defer alloc.free(column_map);
    for (column_map, 0..) |*column, x| column.* = @intCast(@as(u64, x) * target.width / header.width);
    // A box can cover the whole source, so sums need more than 32 bits.
    const sums = try alloc.alloc(u64, @as(usize, target.width) * channels);
    defer alloc.free(sums);
    @memset(sums, 0);
    const counts = try alloc.alloc(u32, target.width);
    defer alloc.free(counts);
    @memset(counts, 0);

    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var input: std.Io.Reader = .fixed(parsed.idat);
    const decompress = try alloc.create(flate.Decompress);
    defer alloc.destroy(decompress);
    decompress.* = .init(&input, .zlib, window);

    var target_row: u32 = 0;
    for (0..header.height) |y| {
        const filter = decompress.reader.takeByte() catch return error.InvalidPng;
        decompress.reader.readSliceAll(current) catch return error.InvalidPng;
        try unfilter(filter, current, previous, filter_stride);
        expandRow(parsed, current, pixels);

        const row: u32 = @intCast(@as(u64, y) * target.height / header.height);
        if (row != target_row) {
            try encoder.writeAveragedRow(sums, counts, channels);
            target_row = row;
        }
        for (column_map, 0..) |column, x| {
            counts[column] += 1;
            for (0..channels) |channel| sums[column * channels + channel] += pixels[x * channels + channel];
        }
        std.mem.swap([]u8, &current, &previous);
    }
    try encoder.writeAveragedRow(sums, counts, channels);
}

fn paeth(left: u8, above: u8, upper_left: u8) u8 {
    const estimate = @as(i16, left) + above - upper_left;
    const to_left = @abs(estimate - left);
    const to_above = @abs(estimate - above);
    const to_upper_left = @abs(estimate - upper_left);
    if (to_left <= to_above and to_left <= to_upper_left) return left;
    if (to_above <= to_upper_left) return above;
    return upper_left;
}

fn unfilter(filter: u8, row: []u8, previous: []const u8, stride: usize) Error!void {
    switch (filter) {
        0 => {},
        1 => for (stride..row.len) |i| {
            row[i] +%= row[i - stride];
        },
        2 => for (row, previous) |*byte, above| {
            byte.* +%= above;
        },
        3 => for (row, 0..) |*byte, i| {
            const left: u16 = if (i >= stride) row[i - stride] else 0;
            byte.* +%= @intCast((left + previous[i]) / 2);
        },
        4 => for (row, 0..) |*byte, i| {
            const left = if (i >= stride) row[i - stride] else 0;
            const upper_left = if (i >= stride) previous[i - stride] else 0;
            byte.* +%= paeth(left, previous[i], upper_left);
        },
        else => return error.InvalidPng,
    }
}

/// Reads sample `index` of a row packed at `bit_depth` bits per sample.
fn packedSample(row: []const u8, index: usize, bit_depth: u8) u8 {
    const bit = index * bit_depth;
    const shift: u3 = @intCast(8 - bit_depth - bit % 8);
    const mask: u8 = @intCast((@as(u16, 1) << @intCast(bit_depth)) - 1);
    return (row[bit / 8] >> shift) & mask;
}

/// Expands one unfiltered row to 8-bit output channels.
fn expandRow(parsed: Parsed, row: []const u8, pixels: []u8) void {
    const header = parsed.header;
    const width: usize = header.width;
    switch (header.color_type) {
        .palette => {
            const with_alpha = parsed.transparency.len > 0;
            const channels: usize = if (with_alpha) 4 else 3;
            for (0..width) |x| {
                const index: usize = if (header.bit_depth == 8) row[x] else packedSample(row, x, header.bit_depth);
                const out = pixels[x * channels ..][0..channels];
                if (index * 3 + 2 < parsed.palette.len) {
                    @memcpy(out[0..3], parsed.palette[index * 3 ..][0..3]);
                } else {
                    @memset(out[0..3], 0);
                }
                if (with_alpha) out[3] = if (index < parsed.transparency.len) parsed.transparency[index] else 255;
            }
        },
        .gray => if (header.bit_depth < 8) {
            const max_value: u16 = (@as(u16, 1) << @intCast(header.bit_depth)) - 1;
            for (0..width) |x| {
                pixels[x] = @intCast(@as(u16, packedSample(row, x, header.bit_depth)) * 255 / max_value);
            }
        } else {
            copyHighBytes(row, pixels, header.bit_depth);
        },
        .rgb, .gray_alpha, .rgba => copyHighBytes(row, pixels, header.bit_depth),
    }
}

/// Copies 8-bit samples, or the most significant byte of 16-bit samples.
fn copyHighBytes(row: []const u8, pixels: []u8, bit_depth: u8) void {
    if (bit_depth == 8) {
        @memcpy(pixels, row[0..pixels.len]);
        return;
    }
    for (pixels, 0..) |*sample, i| sample.* = row[i * 2];
}

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

/// Filters and compresses output rows as the box filter completes them.
const RowEncoder = struct {
    idat: std.Io.Writer.Allocating,
    window: []u8,
    compress: *flate.Compress,
    row: []u8,
    previous: []u8,
    filtered: []u8,

    fn init(alloc: Allocator, width: u32, channels: u32) Error!RowEncoder {
        const row_len = @as(usize, width) * channels;
        var idat = try std.Io.Writer.Allocating.initCapacity(alloc, 64 * 1024);
        errdefer idat.deinit();
        const window = try alloc.alloc(u8, flate.max_window_len);
        errdefer alloc.free(window);
        const compress = try alloc.create(flate.Compress);
        errdefer alloc.destroy(compress);
        const row = try alloc.alloc(u8, row_len);
        errdefer alloc.free(row);
        const previous = try alloc.alloc(u8, row_len);
        errdefer alloc.free(previous);
        @memset(previous, 0);
        const filtered = try alloc.alloc(u8, row_len);
        errdefer alloc.free(filtered);
        return .{
            .idat = idat,
            .window = window,
            .compress = compress,
            .row = row,
            .previous = previous,
            .filtered = filtered,
        };
    }

    fn deinit(self: *RowEncoder, alloc: Allocator) void {
        self.idat.deinit();
        alloc.free(self.window);
        alloc.destroy(self.compress);
        alloc.free(self.row);
        alloc.free(self.previous);
        alloc.free(self.filtered);
    }

    /// Starts the zlib stream. The compressor keeps a pointer to `idat`, so
    /// call this once the encoder is at its final address.
    fn start(self: *RowEncoder) Error!void {
        self.compress.* = flate.Compress.init(&self.idat.writer, self.window, .zlib, .default) catch return error.OutOfMemory;
    }

    /// Emits the averaged output row, then clears the accumulators.
    fn writeAveragedRow(self: *RowEncoder, sums: []u64, counts: []u32, channels: u32) Error!void {
        for (counts, 0..) |count, column| {
            for (0..channels) |channel| {
                const index = column * channels + channel;
                self.row[index] = if (count == 0) 0 else @intCast((sums[index] + count / 2) / count);
            }
        }
        @memset(sums, 0);
        @memset(counts, 0);
        const filter = chooseFilter(self.row, self.previous, channels, self.filtered);
        self.compress.writer.writeByte(filter) catch return error.OutOfMemory;
        self.compress.writer.writeAll(self.filtered) catch return error.OutOfMemory;
        std.mem.swap([]u8, &self.row, &self.previous);
    }

    fn finish(self: *RowEncoder, alloc: Allocator, width: u32, height: u32, channels: u32) Error![]u8 {
        self.compress.finish() catch return error.OutOfMemory;
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], width, .big);
        std.mem.writeInt(u32, ihdr[4..8], height, .big);
        ihdr[8] = 8;
        ihdr[9] = outputColorType(channels);
        @memset(ihdr[10..13], 0);
        const idat = self.idat.written();
        var out = try std.Io.Writer.Allocating.initCapacity(alloc, png_signature.len + idat.len + 3 * 12 + ihdr.len);
        errdefer out.deinit();
        out.writer.writeAll(png_signature) catch return error.OutOfMemory;
        writeChunk(&out.writer, "IHDR", &ihdr) catch return error.OutOfMemory;
        writeChunk(&out.writer, "IDAT", idat) catch return error.OutOfMemory;
        writeChunk(&out.writer, "IEND", "") catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
};

fn filteredByte(filter: u8, row: []const u8, previous: []const u8, stride: usize, i: usize) u8 {
    const left: u8 = if (i >= stride) row[i - stride] else 0;
    const upper_left: u8 = if (i >= stride) previous[i - stride] else 0;
    return switch (filter) {
        0 => row[i],
        1 => row[i] -% left,
        2 => row[i] -% previous[i],
        3 => row[i] -% @as(u8, @intCast((@as(u16, left) + previous[i]) / 2)),
        4 => row[i] -% paeth(left, previous[i], upper_left),
        else => unreachable,
    };
}

/// Picks the filter with the smallest sum of signed residuals, the usual PNG
/// encoder heuristic, and writes the filtered row into `out`.
fn chooseFilter(row: []const u8, previous: []const u8, stride: usize, out: []u8) u8 {
    var best_filter: u8 = 0;
    var best_cost: u64 = std.math.maxInt(u64);
    for (0..5) |candidate| {
        const filter: u8 = @intCast(candidate);
        var cost: u64 = 0;
        for (0..row.len) |i| {
            const residual: i8 = @bitCast(filteredByte(filter, row, previous, stride, i));
            cost += @abs(residual);
        }
        if (cost < best_cost) {
            best_cost = cost;
            best_filter = filter;
        }
    }
    for (out, 0..) |*byte, i| byte.* = filteredByte(best_filter, row, previous, stride, i);
    return best_filter;
}

// Tests

const TestImage = struct {
    width: u32,
    height: u32,
    channels: u32,
    pixels: []u8,

    fn deinit(self: TestImage, alloc: Allocator) void {
        alloc.free(self.pixels);
    }
};

/// Decodes a PNG produced by `downscale` back to 8-bit pixels.
fn testDecode(alloc: Allocator, png: []const u8) !TestImage {
    const parsed = try parse(alloc, png);
    defer alloc.free(parsed.idat);
    const header = parsed.header;
    try std.testing.expectEqual(@as(u8, 8), header.bit_depth);
    const channels = samplesPerPixel(header.color_type);
    const row_bytes = @as(usize, header.width) * channels;
    const pixels = try alloc.alloc(u8, row_bytes * header.height);
    errdefer alloc.free(pixels);
    const previous = try alloc.alloc(u8, row_bytes);
    defer alloc.free(previous);
    @memset(previous, 0);
    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);
    var input: std.Io.Reader = .fixed(parsed.idat);
    const decompress = try alloc.create(flate.Decompress);
    defer alloc.destroy(decompress);
    decompress.* = .init(&input, .zlib, window);
    for (0..header.height) |y| {
        const row = pixels[y * row_bytes ..][0..row_bytes];
        const filter = try decompress.reader.takeByte();
        try decompress.reader.readSliceAll(row);
        try unfilter(filter, row, previous, channels);
        @memcpy(previous, row);
    }
    return .{ .width = header.width, .height = header.height, .channels = channels, .pixels = pixels };
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
    ihdr[9] = @intFromEnum(color_type);
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

/// Test helper for callers of `downscale`: a decodable solid 8-bit gray PNG.
pub fn testSolidGrayPng(alloc: Allocator, width: u32, height: u32, value: u8) ![]u8 {
    const scanlines = try testSolidScanlines(alloc, width, height, &.{value});
    defer alloc.free(scanlines);
    return testEncode(alloc, width, height, .gray, 8, scanlines, &.{});
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

test "downscale averages source pixels into each output pixel" {
    const alloc = std.testing.allocator;
    const scanlines = [_]u8{
        0, 0,  100, 200, 250,
        0, 10, 110, 210, 240,
    };
    const png = try testEncode(alloc, 4, 2, .gray, 8, &scanlines, &.{});
    defer alloc.free(png);

    const result = try downscale(alloc, png, 2);
    defer alloc.free(result.png);
    try std.testing.expectEqual(Size{ .width = 2, .height = 1 }, Size{ .width = result.width, .height = result.height });
    const decoded = try testDecode(alloc, result.png);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &.{ 55, 225 }, decoded.pixels);
}

test "downscale keeps the aspect ratio of a full-resolution frame" {
    const alloc = std.testing.allocator;
    const scanlines = try testSolidScanlines(alloc, 3420, 2224, &.{ 30, 144, 255 });
    defer alloc.free(scanlines);
    const png = try testEncode(alloc, 3420, 2224, .rgb, 8, scanlines, &.{});
    defer alloc.free(png);

    const result = try downscale(alloc, png, 2000);
    defer alloc.free(result.png);
    try std.testing.expectEqual(@as(u32, 2000), result.width);
    try std.testing.expectEqual(@as(u32, 1301), result.height);
    const decoded = try testDecode(alloc, result.png);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 3), decoded.channels);
    try std.testing.expectEqualSlices(u8, &.{ 30, 144, 255 }, decoded.pixels[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 30, 144, 255 }, decoded.pixels[decoded.pixels.len - 3 ..]);
}

test "downscale reverses every scanline filter" {
    const alloc = std.testing.allocator;
    // Two RGBA pixels per row; each row uses a different filter over the
    // same target pixels, so every reconstructed row must be identical.
    const target = [_]u8{ 10, 20, 30, 255, 200, 100, 50, 128 };
    var scanlines: [5 * 9]u8 = undefined;
    var previous = [_]u8{0} ** 8;
    for (0..5) |filter| {
        const row = scanlines[filter * 9 ..][0..9];
        row[0] = @intCast(filter);
        for (0..8) |i| row[1 + i] = filteredByte(@intCast(filter), &target, &previous, 4, i);
        previous = target;
    }
    const png = try testEncode(alloc, 2, 5, .rgba, 8, &scanlines, &.{});
    defer alloc.free(png);

    const result = try downscale(alloc, png, 16);
    defer alloc.free(result.png);
    const decoded = try testDecode(alloc, result.png);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 5), decoded.height);
    for (0..5) |row| try std.testing.expectEqualSlices(u8, &target, decoded.pixels[row * 8 ..][0..8]);
}

test "downscale expands palette, transparency, sub-byte gray, and 16-bit samples" {
    const alloc = std.testing.allocator;
    // Palette at 2 bits: indices 0,1,2,3 in one byte; index 3 has no entry.
    const palette_png = try testEncode(alloc, 4, 1, .palette, 2, &.{ 0, 0b00_01_10_11 }, &.{
        .{ "PLTE", "\xff\x00\x00\x00\xff\x00\x00\x00\xff" },
        .{ "tRNS", "\x80" },
    });
    defer alloc.free(palette_png);
    const palette_result = try downscale(alloc, palette_png, 8);
    defer alloc.free(palette_result.png);
    const palette_pixels = try testDecode(alloc, palette_result.png);
    defer palette_pixels.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &.{
        255, 0,   0,   128,
        0,   255, 0,   255,
        0,   0,   255, 255,
        0,   0,   0,   255,
    }, palette_pixels.pixels);

    const gray_png = try testEncode(alloc, 4, 1, .gray, 2, &.{ 0, 0b00_01_10_11 }, &.{});
    defer alloc.free(gray_png);
    const gray_result = try downscale(alloc, gray_png, 8);
    defer alloc.free(gray_result.png);
    const gray_pixels = try testDecode(alloc, gray_result.png);
    defer gray_pixels.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &.{ 0, 85, 170, 255 }, gray_pixels.pixels);

    const deep_png = try testEncode(alloc, 1, 1, .rgb, 16, &.{ 0, 0x12, 0x34, 0xab, 0xcd, 0xfe, 0xdc }, &.{});
    defer alloc.free(deep_png);
    const deep_result = try downscale(alloc, deep_png, 8);
    defer alloc.free(deep_result.png);
    const deep_pixels = try testDecode(alloc, deep_result.png);
    defer deep_pixels.deinit(alloc);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0xab, 0xfe }, deep_pixels.pixels);
}

test "downscale rejects malformed and unsupported images" {
    const alloc = std.testing.allocator;
    const scanlines = [_]u8{ 0, 1, 2, 3, 4 };
    const png = try testEncode(alloc, 4, 1, .gray, 8, &scanlines, &.{});
    defer alloc.free(png);

    try std.testing.expectError(error.InvalidPng, downscale(alloc, "not a png", 2));
    try std.testing.expectError(error.InvalidPng, downscale(alloc, png[0 .. png.len - 13], 2));

    const bad_filter = try testEncode(alloc, 4, 1, .gray, 8, &.{ 9, 1, 2, 3, 4 }, &.{});
    defer alloc.free(bad_filter);
    try std.testing.expectError(error.InvalidPng, downscale(alloc, bad_filter, 2));

    const short_data = try testEncode(alloc, 4, 2, .gray, 8, &scanlines, &.{});
    defer alloc.free(short_data);
    try std.testing.expectError(error.InvalidPng, downscale(alloc, short_data, 2));

    const interlaced = try alloc.dupe(u8, png);
    defer alloc.free(interlaced);
    interlaced[png_signature.len + 8 + 12] = 1;
    try std.testing.expectError(error.UnsupportedPng, downscale(alloc, interlaced, 2));

    const huge = try alloc.dupe(u8, png);
    defer alloc.free(huge);
    std.mem.writeInt(u32, huge[png_signature.len + 8 ..][0..4], max_source_side + 1, .big);
    try std.testing.expectError(error.UnsupportedPng, downscale(alloc, huge, 2));

    const palette_without_entries = try testEncode(alloc, 4, 1, .palette, 8, &scanlines, &.{});
    defer alloc.free(palette_without_entries);
    try std.testing.expectError(error.InvalidPng, downscale(alloc, palette_without_entries, 2));
}

test "downscale stays bounded on arbitrary bytes" {
    const alloc = std.testing.allocator;
    const png = try testEncode(alloc, 4, 2, .gray, 8, &.{ 0, 0, 100, 200, 250, 0, 10, 110, 210, 240 }, &.{});
    defer alloc.free(png);
    try std.testing.fuzz(png, fuzzDownscale, .{ .corpus = &.{png} });
}

fn fuzzDownscale(_: []const u8, smith: *std.testing.Smith) !void {
    var bytes: [2048]u8 = undefined;
    const len: usize = @intCast(smith.slice(&bytes));
    const result = downscale(std.testing.allocator, bytes[0..len], 2) catch |err| switch (err) {
        error.InvalidPng, error.UnsupportedPng => return,
        error.OutOfMemory => return err,
    };
    defer std.testing.allocator.free(result.png);
    try std.testing.expect(result.width <= 2 and result.height <= 2);
    const decoded = try testDecode(std.testing.allocator, result.png);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(result.width, decoded.width);
}
