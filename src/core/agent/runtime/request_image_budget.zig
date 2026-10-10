//! Keeps the images re-sent with every request under the provider's request
//! size limit. Each request carries every earlier image, so its body grows
//! with every screenshot while its token estimate barely moves. The oldest
//! images leave the request first, each with a note for loading it again.
//! History is never changed.
const std = @import("std");
const types = @import("../../shared/types.zig");
const image_attachments = @import("../../images/image_attachments.zig");
const utf8PrefixLength = @import("../../config/context_limits.zig").utf8PrefixLength;

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

/// Claude routes reject request bodies over 32 MiB, the strictest limit
/// measured through AI Gateway. Gemini and OpenAI routes accept larger ones.
pub const default_max_request_bytes: usize = 30 * 1024 * 1024;
/// Anthropic accepts at most 100 images in one request.
pub const default_max_request_images: usize = 100;
/// Planning allowance for the note that replaces each withheld image.
const notice_reserve_bytes: usize = 320;

pub const Limits = struct {
    max_request_bytes: usize = default_max_request_bytes,
    max_images: usize = default_max_request_images,
};

/// Returns how many of the oldest images must leave a request of
/// `request_bytes` for it to fit `limits`. `image_bytes` holds each image's
/// serialized size, oldest first. Returns `image_bytes.len` when the request
/// does not fit even without images.
pub fn oldestImagesToWithhold(image_bytes: []const usize, request_bytes: usize, limits: Limits) usize {
    var withheld: usize = 0;
    var bytes = request_bytes;
    while (withheld < image_bytes.len) : (withheld += 1) {
        if (image_bytes.len - withheld <= limits.max_images and bytes <= limits.max_request_bytes) break;
        bytes = (bytes -| image_bytes[withheld]) +| notice_reserve_bytes;
    }
    return withheld;
}

pub const Projection = struct {
    messages: []const ChatMessage,
    withheld: usize = 0,
};

/// Leaves the oldest images out of a request whose serialized size is
/// `request_bytes` until it fits `limits`. Returned messages are `messages`
/// itself when nothing is withheld, otherwise a copy allocated in `arena`.
/// `tool_text_limit` bounds tool result content after the note is added.
pub fn withholdOldestImages(
    arena: Allocator,
    messages: []const ChatMessage,
    request_bytes: usize,
    limits: Limits,
    tool_text_limit: usize,
) Allocator.Error!Projection {
    var sizes: std.ArrayList(usize) = .empty;
    for (messages) |message| {
        for (message.images) |image| {
            // An unreadable attachment cannot be serialized either; it
            // still counts toward the image limit.
            try sizes.append(arena, image_attachments.attachmentEncodedBytes(image) orelse 0);
        }
        if (message.tool_result_memory) |memory| {
            for (memory.tool_images) |image| try sizes.append(arena, image.data.len);
        }
    }
    const withheld = oldestImagesToWithhold(sizes.items, request_bytes, limits);
    if (withheld == 0) return .{ .messages = messages };

    const projected = try arena.dupe(ChatMessage, messages);
    var remaining = withheld;
    for (projected) |*message| {
        if (remaining == 0) break;
        if (message.images.len > 0) {
            const count = @min(remaining, message.images.len);
            var notice: std.Io.Writer.Allocating = .init(arena);
            for (message.images[0..count]) |image| writeAttachmentNotice(&notice.writer, image) catch return error.OutOfMemory;
            message.images = message.images[count..];
            message.content = try std.mem.concat(arena, u8, &.{ notice.written(), message.content orelse "" });
            remaining -= count;
        }
        if (remaining == 0) break;
        if (message.tool_result_memory) |*memory| {
            if (memory.tool_images.len == 0) continue;
            const count = @min(remaining, memory.tool_images.len);
            const notice = try toolImagesNotice(arena, count, memory.tool_image_handle);
            memory.tool_images = memory.tool_images[count..];
            message.content = try prependNotice(arena, notice, message.content orelse "", tool_text_limit);
            remaining -= count;
        }
    }
    return .{ .messages = projected, .withheld = withheld };
}

fn writeAttachmentNotice(writer: *std.Io.Writer, image: types.ImageAttachment) std.Io.Writer.Error!void {
    try writer.print("[Image #{d} not sent to keep the request under the provider's size limit.", .{image.id});
    if (image.inline_data == null) {
        if (image.snapshot_path) |path| try writer.print(" The original is saved at {s}; read_file it to see it again.", .{path});
    }
    try writer.writeAll("]\n");
}

fn toolImagesNotice(arena: Allocator, count: usize, handle: ?[]const u8) Allocator.Error![]u8 {
    const subject = if (count == 1) "1 image" else try std.fmt.allocPrint(arena, "{d} images", .{count});
    if (handle) |value| {
        const object = if (count == 1) "it" else "them";
        return std.fmt.allocPrint(arena, "[{s} from this result not sent to keep the request under the provider's size limit. Use read_tool_result with handle {s} to load {s} again.]\n", .{ subject, value, object });
    }
    return std.fmt.allocPrint(arena, "[{s} from this result not sent to keep the request under the provider's size limit.]\n", .{subject});
}

fn prependNotice(arena: Allocator, notice: []const u8, content: []const u8, limit: usize) Allocator.Error![]u8 {
    const notice_keep = utf8PrefixLength(notice, limit);
    const keep = utf8PrefixLength(content, limit -| notice.len);
    return std.mem.concat(arena, u8, &.{ notice[0..notice_keep], content[0..keep] });
}

test "oldest images leave until the request fits" {
    const limits = Limits{ .max_request_bytes = 1000, .max_images = 10 };
    const sizes = [_]usize{ 400, 400, 400 };
    try std.testing.expectEqual(@as(usize, 0), oldestImagesToWithhold(&sizes, 1000, limits));
    try std.testing.expectEqual(@as(usize, 1), oldestImagesToWithhold(&sizes, 1001, limits));
    // 1300 - 400 + 320 = 1220, then 1220 - 400 + 320 = 1140, then 1060.
    try std.testing.expectEqual(@as(usize, 3), oldestImagesToWithhold(&sizes, 1300, limits));
    try std.testing.expectEqual(@as(usize, 3), oldestImagesToWithhold(&sizes, 50_000, limits));
    try std.testing.expectEqual(@as(usize, 0), oldestImagesToWithhold(&.{}, 50_000, limits));
}

test "oldest images leave when a request carries too many" {
    const limits = Limits{ .max_request_bytes = 1_000_000, .max_images = 2 };
    const sizes = [_]usize{ 10, 10, 10, 10 };
    try std.testing.expectEqual(@as(usize, 2), oldestImagesToWithhold(&sizes, 100, limits));
    try std.testing.expectEqual(@as(usize, 0), oldestImagesToWithhold(sizes[0..2], 100, limits));
}

fn testToolImage(arena: Allocator, encoded_len: usize) !types.ToolImage {
    const data = try arena.alloc(u8, encoded_len);
    @memset(data, 'A');
    return .{ .data = data, .mime_type = try arena.dupe(u8, "image/png") };
}

test "withholding keeps history and names how to reload each image" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inline_bytes = try arena.alloc(u8, 3000);
    @memset(inline_bytes, 0);
    const attachments = [_]types.ImageAttachment{.{
        .id = 1,
        .path = try arena.dupe(u8, "shot.png"),
        .media_type = try arena.dupe(u8, "image/png"),
        .inline_data = inline_bytes,
    }};
    const tool_images = [_]types.ToolImage{ try testToolImage(arena, 4000), try testToolImage(arena, 4000) };
    const messages = [_]ChatMessage{
        .{ .role = .user, .content = "compare these", .images = &attachments },
        .{ .role = .tool, .content = "<path>a.png</path>", .tool_result_memory = .{ .tool_images = &tool_images, .tool_image_handle = "image-result-call_a" } },
    };

    // 12,500 bytes against 9,000: the attachment (4,000 encoded) is enough.
    const first = try withholdOldestImages(arena, &messages, 12_500, .{ .max_request_bytes = 9000 }, 4096);
    try std.testing.expectEqual(@as(usize, 1), first.withheld);
    try std.testing.expectEqual(@as(usize, 0), first.messages[0].images.len);
    try std.testing.expect(std.mem.startsWith(u8, first.messages[0].content.?, "[Image #1 not sent to keep the request under the provider's size limit.]\n"));
    try std.testing.expect(std.mem.endsWith(u8, first.messages[0].content.?, "compare these"));
    try std.testing.expectEqual(@as(usize, 2), first.messages[1].tool_result_memory.?.tool_images.len);

    // Against 5,000 every image leaves, oldest first.
    const second = try withholdOldestImages(arena, &messages, 12_500, .{ .max_request_bytes = 5000 }, 4096);
    try std.testing.expectEqual(@as(usize, 3), second.withheld);
    try std.testing.expectEqual(@as(usize, 0), second.messages[1].tool_result_memory.?.tool_images.len);
    try std.testing.expectEqualStrings(
        "[2 images from this result not sent to keep the request under the provider's size limit. Use read_tool_result with handle image-result-call_a to load them again.]\n<path>a.png</path>",
        second.messages[1].content.?,
    );

    // The caller's messages are unchanged.
    try std.testing.expectEqual(@as(usize, 1), messages[0].images.len);
    try std.testing.expectEqual(@as(usize, 2), messages[1].tool_result_memory.?.tool_images.len);
    try std.testing.expectEqualStrings("compare these", messages[0].content.?);

    // A request that already fits is returned as is.
    const unchanged = try withholdOldestImages(arena, &messages, 9000, .{ .max_request_bytes = 9000 }, 4096);
    try std.testing.expectEqual(@as(usize, 0), unchanged.withheld);
    try std.testing.expectEqual(@as([*]const ChatMessage, &messages), unchanged.messages.ptr);
}

test "withheld snapshot attachments point at their saved file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var notice: std.Io.Writer.Allocating = .init(arena);
    try writeAttachmentNotice(&notice.writer, .{
        .id = 3,
        .path = try arena.dupe(u8, "screen.png"),
        .media_type = try arena.dupe(u8, "image/png"),
        .snapshot_path = try arena.dupe(u8, "/home/u/.fx/sessions/s/images/3.bin"),
    });
    try std.testing.expectEqualStrings(
        "[Image #3 not sent to keep the request under the provider's size limit. The original is saved at /home/u/.fx/sessions/s/images/3.bin; read_file it to see it again.]\n",
        notice.written(),
    );
}

test "a withheld tool image without a saved handle says so plainly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "[1 image from this result not sent to keep the request under the provider's size limit.]\n",
        try toolImagesNotice(arena, 1, null),
    );
    try std.testing.expectEqualStrings(
        "[1 image from this result not sent to keep the request under the provider's size limit. Use read_tool_result with handle image-result-a to load it again.]\n",
        try toolImagesNotice(arena, 1, "image-result-a"),
    );
}
