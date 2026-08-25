const std = @import("std");
const zigimg = @import("zigimg");

const webp = @cImport({
    @cInclude("webp/demux.h");
});

const Allocator = std.mem.Allocator;

const max_input_bytes: usize = 20 * 1024 * 1024;
const max_decode_pixels: usize = 24 * 1024 * 1024;
const max_decode_memory: usize = 256 * 1024 * 1024;
const max_output_dimension: u32 = 1024;
const max_png_bytes: usize = 5 * 1024 * 1024;

pub const Dimensions = struct {
    width: u32,
    height: u32,
};

pub const Bounds = struct {
    width: u32,
    height: u32,
};

pub const ConversionError = error{
    UnsupportedMediaType,
    InvalidImageDimensions,
    ImageTooLarge,
    ImageDecodeFailed,
    ImageEncodeFailed,
};

/// Decodes a supported attachment, selects its first frame, bounds the decoded
/// preview, and returns an owned PNG payload suitable for Kitty's `f=100`
/// transfer mode.
pub fn convertToPng(
    alloc: Allocator,
    encoded: []const u8,
    media_type: []const u8,
    dimensions: Dimensions,
    bounds: Bounds,
) (Allocator.Error || ConversionError)![]u8 {
    if (encoded.len == 0) return error.ImageDecodeFailed;
    if (encoded.len > max_input_bytes) return error.ImageTooLarge;
    if (!isConvertibleMediaType(media_type)) return error.UnsupportedMediaType;
    if (dimensions.width == 0 or dimensions.height == 0) {
        return error.InvalidImageDimensions;
    }

    const source_pixels = std.math.mul(
        usize,
        @as(usize, dimensions.width),
        @as(usize, dimensions.height),
    ) catch return error.ImageTooLarge;
    if (source_pixels == 0 or source_pixels > max_decode_pixels) {
        return error.ImageTooLarge;
    }

    var limiter = LimitingAllocator{
        .child = alloc,
        .limit = max_decode_memory,
    };
    const scratch = limiter.allocator();

    var decoded = if (std.mem.eql(u8, media_type, "image/webp"))
        decodeWebp(scratch, encoded, dimensions.width, dimensions.height) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ImageTooLarge => return error.ImageTooLarge,
            else => return error.ImageDecodeFailed,
        }
    else
        zigimg.Image.fromMemory(scratch, encoded) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ImageDecodeFailed,
        };
    defer decoded.deinit(scratch);

    if (decoded.width != dimensions.width or decoded.height != dimensions.height) {
        return error.InvalidImageDimensions;
    }
    decoded.convert(scratch, .rgba32) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ImageDecodeFailed,
    };

    const target = fitDimensions(dimensions.width, dimensions.height, bounds) orelse
        return error.InvalidImageDimensions;
    if (target.width == dimensions.width and target.height == dimensions.height) {
        return encodePng(alloc, scratch, decoded);
    }

    const resized_pixels = resizeRgba(
        scratch,
        decoded.rawBytes(),
        dimensions.width,
        dimensions.height,
        target.width,
        target.height,
    ) catch return error.OutOfMemory;
    var preview = zigimg.Image.fromRawPixelsOwned(
        target.width,
        target.height,
        resized_pixels,
        .rgba32,
    ) catch {
        scratch.free(resized_pixels);
        return error.ImageDecodeFailed;
    };
    defer preview.deinit(scratch);
    return encodePng(alloc, scratch, preview);
}

fn isConvertibleMediaType(media_type: []const u8) bool {
    return std.mem.eql(u8, media_type, "image/jpeg") or
        std.mem.eql(u8, media_type, "image/gif") or
        std.mem.eql(u8, media_type, "image/webp");
}

fn decodeWebp(
    alloc: Allocator,
    encoded: []const u8,
    expected_width: u32,
    expected_height: u32,
) (Allocator.Error || ConversionError)!zigimg.Image {
    const data = webp.WebPData{
        .bytes = encoded.ptr,
        .size = encoded.len,
    };
    var options: webp.WebPAnimDecoderOptions = undefined;
    if (webp.WebPAnimDecoderOptionsInit(&options) == 0) {
        return error.ImageDecodeFailed;
    }
    options.color_mode = webp.MODE_RGBA;
    options.use_threads = 1;
    const decoder = webp.WebPAnimDecoderNew(&data, &options) orelse
        return error.ImageDecodeFailed;
    defer webp.WebPAnimDecoderDelete(decoder);

    var info: webp.WebPAnimInfo = undefined;
    if (webp.WebPAnimDecoderGetInfo(decoder, &info) == 0 or
        info.canvas_width != expected_width or
        info.canvas_height != expected_height or
        info.frame_count == 0)
    {
        return error.ImageDecodeFailed;
    }

    const pixel_count = std.math.mul(
        usize,
        @as(usize, expected_width),
        @as(usize, expected_height),
    ) catch return error.ImageTooLarge;
    const output_len = std.math.mul(usize, pixel_count, 4) catch
        return error.ImageTooLarge;
    var frame: [*c]u8 = null;
    var timestamp: c_int = 0;
    if (webp.WebPAnimDecoderGetNext(decoder, &frame, &timestamp) == 0 or
        frame == null)
    {
        return error.ImageDecodeFailed;
    }
    const rgba = try alloc.dupe(u8, frame[0..output_len]);
    errdefer alloc.free(rgba);
    return zigimg.Image.fromRawPixelsOwned(
        expected_width,
        expected_height,
        rgba,
        .rgba32,
    ) catch return error.ImageDecodeFailed;
}

fn fitDimensions(
    source_width: u32,
    source_height: u32,
    bounds: Bounds,
) ?Dimensions {
    const max_width = @min(bounds.width, max_output_dimension);
    const max_height = @min(bounds.height, max_output_dimension);
    if (source_width == 0 or source_height == 0 or max_width == 0 or max_height == 0) {
        return null;
    }
    if (source_width <= max_width and source_height <= max_height) {
        return .{ .width = source_width, .height = source_height };
    }

    const width_limited = @as(u64, max_width) * source_height <=
        @as(u64, max_height) * source_width;
    if (width_limited) {
        return .{
            .width = max_width,
            .height = @max(
                1,
                @as(u32, @intCast(@as(u64, source_height) * max_width / source_width)),
            ),
        };
    }
    return .{
        .width = @max(
            1,
            @as(u32, @intCast(@as(u64, source_width) * max_height / source_height)),
        ),
        .height = max_height,
    };
}

fn resizeRgba(
    alloc: Allocator,
    source: []const u8,
    source_width: u32,
    source_height: u32,
    target_width: u32,
    target_height: u32,
) Allocator.Error![]u8 {
    const source_len = std.math.mul(
        usize,
        std.math.mul(usize, source_width, source_height) catch return error.OutOfMemory,
        4,
    ) catch return error.OutOfMemory;
    if (source.len != source_len) return error.OutOfMemory;
    const target_len = std.math.mul(
        usize,
        std.math.mul(usize, target_width, target_height) catch return error.OutOfMemory,
        4,
    ) catch return error.OutOfMemory;
    const target = try alloc.alloc(u8, target_len);

    for (0..target_height) |target_y| {
        const source_y = @as(u64, target_y) * source_height / target_height;
        for (0..target_width) |target_x| {
            const source_x = @as(u64, target_x) * source_width / target_width;
            const source_offset = (@as(usize, @intCast(source_y)) * source_width +
                @as(usize, @intCast(source_x))) * 4;
            const target_offset = (target_y * target_width + target_x) * 4;
            @memcpy(target[target_offset..][0..4], source[source_offset..][0..4]);
        }
    }
    return target;
}

fn encodePng(
    alloc: Allocator,
    scratch: Allocator,
    image: zigimg.Image,
) (Allocator.Error || ConversionError)![]u8 {
    const buffer = try alloc.alloc(u8, max_png_bytes);
    defer alloc.free(buffer);
    const encoded = image.writeToMemory(scratch, buffer, .{ .png = .{} }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ImageEncodeFailed,
    };
    if (encoded.len == 0 or encoded.len > max_png_bytes) return error.ImageEncodeFailed;
    return alloc.dupe(u8, encoded);
}

const LimitingAllocator = struct {
    child: Allocator,
    limit: usize,
    live: usize = 0,

    fn allocator(self: *LimitingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocate,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn allocate(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LimitingAllocator = @ptrCast(@alignCast(context));
        if (len > self.limit - self.live) return null;
        const result = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.live += len;
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *LimitingAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len and new_len - memory.len > self.limit - self.live) {
            return false;
        }
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        self.live = self.live - memory.len + new_len;
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *LimitingAllocator = @ptrCast(@alignCast(context));
        if (new_len > memory.len and new_len - memory.len > self.limit - self.live) {
            return null;
        }
        const result = self.child.rawRemap(memory, alignment, new_len, return_address) orelse
            return null;
        self.live = self.live - memory.len + new_len;
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *LimitingAllocator = @ptrCast(@alignCast(context));
        std.debug.assert(memory.len <= self.live);
        self.child.rawFree(memory, alignment, return_address);
        self.live -= memory.len;
    }
};

const conversion_cases = .{
    .{ "image/jpeg", @embedFile("testdata/red-2x3.jpg") },
    .{ "image/gif", @embedFile("testdata/green-2x3.gif") },
    .{ "image/webp", @embedFile("testdata/blue-2x3.webp") },
};

test "JPEG, GIF, and WebP previews convert to bounded PNG payloads" {
    inline for (conversion_cases) |case| {
        const png = try convertToPng(
            std.testing.allocator,
            case[1],
            case[0],
            .{ .width = 2, .height = 3 },
            .{ .width = 16, .height = 16 },
        );
        defer std.testing.allocator.free(png);
        try std.testing.expect(std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n"));
        var decoded = try zigimg.Image.fromMemory(std.testing.allocator, png);
        defer decoded.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), decoded.width);
        try std.testing.expectEqual(@as(usize, 3), decoded.height);
    }
}

test "animated GIF conversion selects the fully composited first frame" {
    const png = try convertToPng(
        std.testing.allocator,
        @embedFile("testdata/animated-red-blue-2x3.gif"),
        "image/gif",
        .{ .width = 2, .height = 3 },
        .{ .width = 16, .height = 16 },
    );
    defer std.testing.allocator.free(png);
    var decoded = try zigimg.Image.fromMemory(std.testing.allocator, png);
    defer decoded.deinit(std.testing.allocator);
    try decoded.convert(std.testing.allocator, .rgba32);
    const pixels = decoded.rawBytes();
    try std.testing.expect(pixels[0] > 200);
    try std.testing.expect(pixels[1] < 50);
    try std.testing.expect(pixels[2] < 50);
}

test "animated WebP conversion selects the fully composited first frame" {
    const png = try convertToPng(
        std.testing.allocator,
        @embedFile("testdata/animated-red-blue-2x3.webp"),
        "image/webp",
        .{ .width = 2, .height = 3 },
        .{ .width = 16, .height = 16 },
    );
    defer std.testing.allocator.free(png);
    var decoded = try zigimg.Image.fromMemory(std.testing.allocator, png);
    defer decoded.deinit(std.testing.allocator);
    try decoded.convert(std.testing.allocator, .rgba32);
    const pixels = decoded.rawBytes();
    try std.testing.expect(pixels[0] > 200);
    try std.testing.expect(pixels[1] < 50);
    try std.testing.expect(pixels[2] < 50);
}

test "terminal conversion downsamples without changing aspect ratio" {
    const png = try convertToPng(
        std.testing.allocator,
        @embedFile("testdata/red-2x3.jpg"),
        "image/jpeg",
        .{ .width = 2, .height = 3 },
        .{ .width = 1, .height = 1 },
    );
    defer std.testing.allocator.free(png);
    var decoded = try zigimg.Image.fromMemory(std.testing.allocator, png);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), decoded.width);
    try std.testing.expectEqual(@as(usize, 1), decoded.height);
}
