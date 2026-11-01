//! Keeps the images re-sent with every request under the provider's request
//! size limit. Each request carries every earlier image, so its body grows
//! with every screenshot while its token estimate barely moves. The oldest
//! images leave the request first, each with a note for loading it again.
//! History is never changed.
const std = @import("std");
const types = @import("../../shared/types.zig");
const image_attachments = @import("../../images/image_attachments.zig");
const image_data = @import("../../images/image_data.zig");
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

/// The size a request must fit: the limit learned from the provider, else
/// the default, and never more than the transport can carry.
pub fn maxRequestBytes(learned: ?usize, transport: ?usize) usize {
    const limit = learned orelse default_max_request_bytes;
    return if (transport) |cap| @min(limit, cap) else limit;
}

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
    const sizes = try imageSizes(arena, messages);
    return withhold(arena, messages, oldestImagesToWithhold(sizes, request_bytes, limits), tool_text_limit);
}

/// The number of oldest images to leave out when the fewest that fit is
/// `minimal`, rounded up to the end of a block. Leaving out one more image
/// for each new one would change the cached prompt at its oldest image on
/// every request. Blocks count from the oldest image: each holds a quarter of
/// `limits.max_images` images, or ends sooner at the image that brings it to
/// a quarter of `limits.max_request_bytes`. A new image never moves an
/// earlier block, so as a session grows the cut moves only forward, about
/// once per block. The newest block is never left out to round, and a
/// request that needs nothing left out leaves nothing out. `sizes` holds
/// every image's serialized size, oldest first.
pub fn blockCut(sizes: []const usize, minimal: usize, limits: Limits) usize {
    if (minimal == 0 or minimal >= sizes.len) return minimal;
    const block_images = @max(1, limits.max_images / 4);
    const block_bytes = @max(1, limits.max_request_bytes / 4);
    var count: usize = 0;
    var bytes: usize = 0;
    for (sizes, 0..) |size, index| {
        count += 1;
        bytes +|= size;
        if (count < block_images and bytes < block_bytes) continue;
        const end = index + 1;
        if (end >= sizes.len) return minimal;
        if (end >= minimal) return end;
        count = 0;
        bytes = 0;
    }
    return minimal;
}

/// A size no request is fit below: the default, or a larger limit learned
/// from a provider's rejection. A transport may lower either, never raise it.
pub fn largestRequestBytes(learned: ?usize) usize {
    return @max(default_max_request_bytes, learned orelse 0);
}

/// Leaves out the oldest images a request of at most `max_request_bytes`
/// can't carry by their serialized size alone, before the request is built.
/// A request re-sends every image the session keeps, so building it whole
/// would hold all of them, encoded, at once. A body is never smaller than
/// its images, so this withholds no image `withholdOldestImages` would keep
/// for a limit of at most `max_request_bytes`.
pub fn withholdImagesPastLimit(
    arena: Allocator,
    messages: []const ChatMessage,
    max_request_bytes: usize,
    tool_text_limit: usize,
) Allocator.Error!Projection {
    const sizes = try imageSizes(arena, messages);
    var images_bytes: usize = 0;
    for (sizes) |size| images_bytes +|= size;
    const withheld = oldestImagesToWithhold(sizes, images_bytes, .{ .max_request_bytes = max_request_bytes });
    return withhold(arena, messages, withheld, tool_text_limit);
}

/// Each image's serialized size, oldest first, allocated in `arena`.
pub fn imageSizes(arena: Allocator, messages: []const ChatMessage) Allocator.Error![]const usize {
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
    return sizes.items;
}

/// `messages` with its `withheld` oldest images replaced by notes.
pub fn withhold(arena: Allocator, messages: []const ChatMessage, withheld: usize, tool_text_limit: usize) Allocator.Error!Projection {
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
    if (image_attachments.savedImagePath(image)) |path| try writer.print(" The original is saved at {s}; read_file it to see it again.", .{path});
    try writer.writeAll("]\n");
}

fn toolImagesNotice(arena: Allocator, count: usize, handle: ?[]const u8) Allocator.Error![]u8 {
    const subject = if (count == 1) "1 image" else try arena.print("{d} images", .{count});
    if (handle) |value| {
        const object = if (count == 1) "it" else "them";
        return arena.print("[{s} from this result not sent to keep the request under the provider's size limit. Use read_tool_result with handle {s} to load {s} again.]\n", .{ subject, value, object });
    }
    return arena.print("[{s} from this result not sent to keep the request under the provider's size limit.]\n", .{subject});
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

test "a request fits the transport's limit as well as the provider's" {
    try std.testing.expectEqual(default_max_request_bytes, maxRequestBytes(null, null));
    try std.testing.expectEqual(@as(usize, 4000), maxRequestBytes(4000, null));
    // A host transport that carries less lowers either limit.
    try std.testing.expectEqual(@as(usize, 8000), maxRequestBytes(null, 8000));
    try std.testing.expectEqual(@as(usize, 4000), maxRequestBytes(4000, 8000));
    try std.testing.expectEqual(@as(usize, 3000), maxRequestBytes(4000, 3000));
}

test "oldest images leave when a request carries too many" {
    const limits = Limits{ .max_request_bytes = 1_000_000, .max_images = 2 };
    const sizes = [_]usize{ 10, 10, 10, 10 };
    try std.testing.expectEqual(@as(usize, 2), oldestImagesToWithhold(&sizes, 100, limits));
    try std.testing.expectEqual(@as(usize, 0), oldestImagesToWithhold(sizes[0..2], 100, limits));
}

test "a session past the image limit leaves images out a block at a time" {
    const limits = Limits{ .max_request_bytes = 1_000_000, .max_images = 100 };
    const sizes: [130]usize = @splat(10);
    // The fewest that fit is one per image past 100; blocks hold 25.
    try std.testing.expectEqual(@as(usize, 0), blockCut(sizes[0..100], 0, limits));
    try std.testing.expectEqual(@as(usize, 25), blockCut(sizes[0..101], 1, limits));
    try std.testing.expectEqual(@as(usize, 25), blockCut(sizes[0..125], 25, limits));
    try std.testing.expectEqual(@as(usize, 50), blockCut(sizes[0..126], 26, limits));
    // Rounding never leaves out the newest block.
    try std.testing.expectEqual(@as(usize, 26), blockCut(sizes[0..30], 26, limits));
    // Large images end a block sooner: a quarter of the byte limit each.
    const large = [_]usize{ 300_000, 300_000, 300_000, 300_000 };
    try std.testing.expectEqual(@as(usize, 1), blockCut(&large, 1, limits));
    try std.testing.expectEqual(@as(usize, 3), blockCut(&large, 3, limits));
}

fn blockEnds(sizes: []const usize, limits: Limits, ends: *std.bit_set.Static(16)) void {
    const block_images = @max(1, limits.max_images / 4);
    const block_bytes = @max(1, limits.max_request_bytes / 4);
    var count: usize = 0;
    var bytes: usize = 0;
    for (sizes, 0..) |size, index| {
        count += 1;
        bytes += size;
        if (count < block_images and bytes < block_bytes) continue;
        ends.set(index + 1);
        count = 0;
        bytes = 0;
    }
}

test "a block cut covers the fewest that fit, keeps the newest block, and only grows" {
    const limits = Limits{ .max_request_bytes = 40, .max_images = 8 };
    const alphabet = [_]usize{ 1, 4, 9 };
    var sizes: [8]usize = undefined;
    var len: usize = 0;
    while (len <= 7) : (len += 1) {
        var combos: usize = 1;
        for (0..len) |_| combos *= alphabet.len;
        for (0..combos) |combo| {
            var rest = combo;
            for (sizes[0..len]) |*size| {
                size.* = alphabet[rest % alphabet.len];
                rest /= alphabet.len;
            }
            const seq = sizes[0..len];
            var ends: std.bit_set.Static(16) = .empty;
            blockEnds(seq, limits, &ends);
            var previous: usize = 0;
            for (0..len + 1) |minimal| {
                const cut = blockCut(seq, minimal, limits);
                try std.testing.expect(cut >= minimal and cut <= len);
                if (minimal == 0) try std.testing.expectEqual(@as(usize, 0), cut);
                if (minimal < len) try std.testing.expect(cut < len);
                if (cut != minimal) try std.testing.expect(ends.isSet(cut));
                try std.testing.expect(cut >= previous);
                previous = cut;
                // A new image never pulls the cut back.
                for (alphabet) |next| {
                    sizes[len] = next;
                    try std.testing.expect(blockCut(sizes[0 .. len + 1], minimal, limits) >= cut);
                }
            }
        }
    }
}

test "a growing session moves its cut forward and rarely" {
    const limits = Limits{ .max_request_bytes = 100_000, .max_images = 20 };
    var sizes: [80]usize = undefined;
    var previous: usize = 0;
    var minimal_changes: usize = 0;
    var cut_changes: usize = 0;
    var previous_minimal: usize = 0;
    for (0..sizes.len) |index| {
        sizes[index] = 2_000 + (index * 7_919) % 3_000;
        const seq = sizes[0 .. index + 1];
        var image_bytes: usize = 0;
        for (seq) |size| image_bytes += size;
        const text_bytes = 10_000 + index * 400;
        const minimal = oldestImagesToWithhold(seq, text_bytes + image_bytes, limits);
        const cut = blockCut(seq, minimal, limits);
        try std.testing.expect(cut >= previous);
        if (minimal != previous_minimal) minimal_changes += 1;
        if (cut != previous) cut_changes += 1;
        previous = cut;
        previous_minimal = minimal;
    }
    try std.testing.expect(minimal_changes > 40);
    try std.testing.expect(cut_changes * 3 <= minimal_changes);
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

test "images no request can carry leave before it is built, and none it can" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tool_images: [6]types.ToolImage = undefined;
    for (&tool_images) |*image| image.* = try testToolImage(arena, 4000);
    const messages = [_]ChatMessage{
        .{ .role = .tool, .content = "<path>a.png</path>", .tool_result_memory = .{ .tool_images = tool_images[0..3], .tool_image_handle = "image-result-a" } },
        .{ .role = .tool, .content = "<path>b.png</path>", .tool_result_memory = .{ .tool_images = tool_images[3..], .tool_image_handle = "image-result-b" } },
    };

    // 24,000 bytes of images against 10,000: the oldest four leave, whatever
    // the text adds, and the newest two stay for the exact fit.
    const before = try withholdImagesPastLimit(arena, &messages, 10_000, 4096);
    try std.testing.expectEqual(@as(usize, 4), before.withheld);
    try std.testing.expectEqual(@as(usize, 0), before.messages[0].tool_result_memory.?.tool_images.len);
    try std.testing.expectEqual(@as(usize, 2), before.messages[1].tool_result_memory.?.tool_images.len);
    // Fitting the whole body withholds at least as many.
    const sizes = [_]usize{ 4000, 4000, 4000, 4000, 4000, 4000 };
    for ([_]usize{ 24_000, 24_100, 30_000 }) |body_bytes| {
        try std.testing.expect(oldestImagesToWithhold(&sizes, body_bytes, .{ .max_request_bytes = 10_000 }) >= before.withheld);
    }

    // Images that fit by size stay for the exact fit to decide.
    const fits = try withholdImagesPastLimit(arena, &messages, 30_000, 4096);
    try std.testing.expectEqual(@as(usize, 0), fits.withheld);
    try std.testing.expectEqual(@as([*]const ChatMessage, &messages), fits.messages.ptr);

    // The image count limit applies too.
    const many: [default_max_request_images + 5]usize = @splat(1);
    try std.testing.expectEqual(@as(usize, 5), oldestImagesToWithhold(&many, many.len, .{ .max_request_bytes = largestRequestBytes(null) }));
}

test "no learned limit lowers the bound a request is fit below" {
    try std.testing.expectEqual(default_max_request_bytes, largestRequestBytes(null));
    try std.testing.expectEqual(default_max_request_bytes, largestRequestBytes(1000));
    // A rejected request that was mostly text can teach a larger limit.
    try std.testing.expectEqual(default_max_request_bytes + 1, largestRequestBytes(default_max_request_bytes + 1));
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

test "a prompt image left out for size names its session's blob (D89)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var image = try image_attachments.captureInlineImageBytesInMemory(arena, 1, "image/png", &image_data.testPngHeader(10, 10));
    image.snapshot_path = try arena.dupe(u8, "/tmp/fx-image-snapshots-0123456789abcdef/image-1.bin");
    image.blob_path = try arena.dupe(u8, "/Users/example/.fx/sessions/v2/s/blobs/0123abcd");
    const in_blob = [_]ChatMessage{.{ .role = .user, .content = "look", .images = &.{image} }};
    const named = try withholdImagesPastLimit(arena, &in_blob, 1, 4096);
    try std.testing.expectEqual(@as(usize, 1), named.withheld);
    try std.testing.expect(std.mem.find(u8, named.messages[0].content.?, "The original is saved at /Users/example/.fx/sessions/v2/s/blobs/0123abcd;") != null);
    // Inline bytes without a blob have no saved file to name.
    var unsaved = image;
    unsaved.blob_path = null;
    const inline_only = [_]ChatMessage{.{ .role = .user, .content = "look", .images = &.{unsaved} }};
    const unnamed = try withholdImagesPastLimit(arena, &inline_only, 1, 4096);
    try std.testing.expect(std.mem.find(u8, unnamed.messages[0].content.?, "saved at") == null);
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
