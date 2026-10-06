//! Only host-verified bytes cross the extension boundary; source and snapshot paths remain native.
const std = @import("std");
const streams = @import("../agent/stream_provider.zig");
const images = @import("../images/image_attachments.zig");
const protocol = @import("protocol.zig");

/// Caller owns parsed projection; every file part borrows only its arena, never filesystem authority.
pub fn render(alloc: std.mem.Allocator, request: streams.ModelRequest) !std.json.Parsed(std.json.Value) {
    const encoded = try std.json.Stringify.valueAlloc(alloc, request.messages, .{});
    defer alloc.free(encoded);
    if (encoded.len > protocol.max_models_bytes) return error.ExtensionRequestTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, encoded, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const owned = parsed.arena.allocator();
    const snapshots = request.verified_images orelse &.{};
    var index: usize = 0;
    for (request.messages, parsed.value.array.items) |message, *projected| {
        var parts = std.json.Array.init(owned);
        for (message.images) |_| {
            if (index >= snapshots.len) return error.ExtensionVerifiedImagesRequired;
            var writer = std.Io.Writer.Allocating.init(owned);
            defer writer.deinit();
            try images.writeVerifiedImageFilePartJsonWithBudget(&writer.writer, snapshots[index], .{
                .deadline = request.deadline,
                .cancel_flag = request.cancel_flag,
            });
            if (writer.written().len > protocol.max_models_bytes) return error.ExtensionRequestTooLarge;
            const part = try std.json.parseFromSlice(std.json.Value, owned, writer.written(), .{ .allocate = .alloc_always });
            // The parent arena retains parts; nested deinit could rewind still-borrowed storage.
            try parts.append(part.value);
            index += 1;
        }
        try projected.object.put(owned, "images", .{ .array = parts });
    }
    if (index != snapshots.len) return error.ExtensionVerifiedImagesRequired;
    return parsed;
}
