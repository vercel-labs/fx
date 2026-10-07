//! OpenAI images consume native file parts, never paths or remotely fetched URLs.
const std = @import("std");
const wire = @import("wire.zig");
const media_types = [_][]const u8{ "image/png", "image/jpeg", "image/webp", "image/gif" };
const max_encoded_bytes = 5 * 1024 * 1024;
const chat_text_type = "text";
const responses_text_type = "input_text";
const responses_image_type = "input_image";

/// Reusing validated snapshot projection keeps Responses images under the same local-only boundary.
pub fn responses_content(alloc: wire.Allocator, text: wire.Value, parts: wire.Value) !wire.Value {
    if (text != .string and text != .null) return error.InvalidRequest;
    const projected = try content(alloc, text, parts);
    if (projected != .array) return projected;
    var output = std.json.Array.init(alloc);
    for (projected.array.items) |part| {
        var item = wire.object();
        const kind = try wire.text(try wire.field(part, "type"));
        if (std.mem.eql(u8, kind, chat_text_type)) {
            try wire.put(alloc, &item, "type", wire.string(responses_text_type));
            try wire.put(alloc, &item, "text", try wire.field(part, "text"));
        } else {
            try wire.put(alloc, &item, "type", wire.string(responses_image_type));
            try wire.put(alloc, &item, "image_url", try wire.field(try wire.field(part, "image_url"), "url"));
        }
        try output.append(item);
    }
    return .{ .array = output };
}

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
