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
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

test "tool images validate data and declared media type" {
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
    try validateImage(std.testing.allocator, png, "image/png");
    try std.testing.expectError(error.InvalidImage, validateImage(std.testing.allocator, png, "image/jpeg"));
    try std.testing.expectError(error.InvalidImage, validateImage(std.testing.allocator, "not base64", "image/png"));
}
