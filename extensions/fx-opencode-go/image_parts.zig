//! OpenAI images consume native file parts, never paths or remotely fetched URLs.
const std = @import("std");
const wire = @import("wire.zig");
const media_types = [_][]const u8{ "image/png", "image/jpeg", "image/webp", "image/gif" };
const max_encoded_bytes = 5 * 1024 * 1024;

/// All returned values belong to the prepared request arena supplied by the caller.
pub fn content(alloc: wire.Allocator, text: wire.Value, parts: wire.Value) !wire.Value {
    if (parts != .array) return error.InvalidRequest;
    if (parts.array.items.len == 0) return text;
    var output = std.json.Array.init(alloc);
    if (text == .string and text.string.len > 0) {
        var item = wire.object();
        try wire.put(alloc, &item, "type", wire.string("text"));
        try wire.put(alloc, &item, "text", text);
        try output.append(item);
    } else if (text != .null and text != .string) return error.InvalidRequest;
    for (parts.array.items) |part| {
        if (!std.mem.eql(u8, try wire.text(try wire.field(part, "type")), "file")) return error.InvalidImage;
        const media = try wire.text(try wire.field(part, "mediaType"));
        var allowed = false;
        for (media_types) |candidate| if (std.mem.eql(u8, media, candidate)) {
            allowed = true;
            break;
        };
        if (!allowed) return error.InvalidImage;
        const data = try wire.text(try wire.field(part, "data"));
        if (data.len == 0 or data.len > max_encoded_bytes) return error.InvalidImage;
        _ = std.base64.standard.Decoder.calcSizeForSlice(data) catch return error.InvalidImage;
        var url = wire.object();
        try wire.put(alloc, &url, "url", wire.string(try std.fmt.allocPrint(alloc, "data:{s};base64,{s}", .{ media, data })));
        var item = wire.object();
        try wire.put(alloc, &item, "type", wire.string("image_url"));
        try wire.put(alloc, &item, "image_url", url);
        try output.append(item);
    }
    return .{ .array = output };
}
