const std = @import("std");

const Allocator = std.mem.Allocator;

/// Returns the caller-owned text projection used for an ACP prompt.
/// Unsupported image blocks fail before any prompt is admitted.
pub fn project_text_alloc(alloc: Allocator, prompt: std.json.Value) ![]u8 {
    if (prompt != .array) return alloc.dupe(u8, "");

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    for (prompt.array.items) |block| {
        if (block != .object) continue;
        const block_type = block.object.get("type") orelse continue;
        if (block_type != .string) continue;

        if (std.mem.eql(u8, block_type.string, "text")) {
            const value = block.object.get("text") orelse continue;
            if (value != .string) continue;
            try appendPart(alloc, &text, value.string);
        } else if (std.mem.eql(u8, block_type.string, "image")) {
            return error.UnsupportedPromptImage;
        } else if (std.mem.eql(u8, block_type.string, "resource")) {
            const resource = block.object.get("resource") orelse continue;
            if (resource != .object) continue;
            const value = resource.object.get("text") orelse continue;
            if (value != .string) continue;
            if (text.items.len > 0) try text.append(alloc, '\n');
            const uri = if (resource.object.get("uri")) |uri_value|
                if (uri_value == .string) uri_value.string else ""
            else
                "";
            if (uri.len > 0) {
                try text.appendSlice(alloc, "File: ");
                try text.appendSlice(alloc, uri);
                try text.append(alloc, '\n');
            }
            try text.appendSlice(alloc, value.string);
        }
    }
    return text.toOwnedSlice(alloc);
}

fn appendPart(alloc: Allocator, text: *std.ArrayList(u8), part: []const u8) !void {
    if (text.items.len > 0) try text.append(alloc, '\n');
    try text.appendSlice(alloc, part);
}

test "prompt text projection composes resource-first and multiple text blocks" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"prompt\":[{\"type\":\"resource\",\"resource\":{\"uri\":\"https://example.com/context.md\",\"text\":\"context\"}},{\"type\":\"text\",\"text\":\"first\"},{\"type\":\"text\",\"text\":\"second\"}]}",
        .{},
    );
    defer parsed.deinit();
    const text = try project_text_alloc(alloc, parsed.value.object.get("prompt").?);
    defer alloc.free(text);
    try std.testing.expectEqualStrings(
        "File: https://example.com/context.md\ncontext\nfirst\nsecond",
        text,
    );
}

test "prompt text projection preserves image rejection" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "[{\"type\":\"text\",\"text\":\"first\"},{\"type\":\"image\",\"data\":\"aGVsbG8=\",\"mimeType\":\"image/png\"}]",
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectError(error.UnsupportedPromptImage, project_text_alloc(alloc, parsed.value));
}
