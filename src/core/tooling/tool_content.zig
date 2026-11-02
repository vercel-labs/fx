const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const image_data = @import("../images/image_data.zig");
const types = @import("../shared/types.zig");
const tool_dispatch = @import("tool_dispatch.zig");
const tool_result_limits = @import("tool_result_limits.zig");
const Allocator = std.mem.Allocator;

pub fn parseRichResult(alloc: Allocator, bytes: []const u8, text_limit: usize, is_error: bool) Allocator.Error!tool_dispatch.ToolResult {
    if (bytes.len > image_data.max_result_frame_bytes) return .{ .failure = try alloc.dupe(u8, "Host image result exceeded its bounded frame limit") };
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try alloc.dupe(u8, "Host tool returned invalid image content") },
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .failure = try alloc.dupe(u8, "Host tool returned invalid image content") };
    const text = parsed.value.object.get("text") orelse return .{ .failure = try alloc.dupe(u8, "Host image result requires text") };
    const values = parsed.value.object.get("images") orelse return .{ .failure = try alloc.dupe(u8, "Host image result requires images") };
    if (text != .string or values != .array) return .{ .failure = try alloc.dupe(u8, "Host tool returned invalid image content") };
    const images = image_data.parseToolImages(alloc, values.array.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try alloc.print("Host tool image could not be used: {s}", .{@errorName(err)}) },
    };
    errdefer types.freeToolImages(alloc, images);
    try nameStoredImages(alloc, images, values.array.items);
    const omitted = images.len != values.array.items.len;
    const source = if (omitted) try alloc.print("[Unsupported tool images were omitted.]\n{s}", .{text.string}) else text.string;
    defer if (omitted) alloc.free(source);
    const body = @constCast(try tool_result_limits.prepareModelOutput(alloc, "host_tool", source, text_limit));
    return .{ .rich = .{ .text = body, .images = images, .is_error = is_error } };
}

/// Names each image a libfx host stored before it sent the result: one whose
/// decoded bytes hash to a `stored` mark the result carries. A mark that
/// matches no image leaves the images inline.
fn nameStoredImages(alloc: Allocator, images: []types.ToolImage, values: []const std.json.Value) Allocator.Error!void {
    var marks: usize = 0;
    for (values) |item| {
        if (item == .object and item.object.get("stored") != null) marks += 1;
    }
    if (marks == 0) return;
    var named: usize = 0;
    for (images) |*image| {
        if (image.data.len == 0) continue;
        const size = std.base64.standard.Decoder.calcSizeForSlice(image.data) catch continue;
        const bytes = try alloc.alloc(u8, size);
        defer alloc.free(bytes);
        std.base64.standard.Decoder.decode(bytes, image.data) catch continue;
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const name = std.fmt.bytesToHex(digest, .lower);
        for (values) |item| {
            if (item != .object) continue;
            const mark = item.object.get("stored") orelse continue;
            if (mark == .string and std.mem.eql(u8, mark.string, &name)) {
                image.name = name;
                named += 1;
                break;
            }
        }
    }
    if (named < marks) debug_trace.logf("tools", "event=host_tool_images_not_stored marks={d} named={d} reason=name_mismatch", .{ marks, named });
}

/// Replaces binary fields in a caller-owned parsed MCP block with delivery notes.
/// Images themselves travel through the typed result, never JSON text.
pub fn projectMediaForText(alloc: std.mem.Allocator, content: *std.json.Value) std.mem.Allocator.Error!void {
    if (content.* == .array) {
        for (content.array.items) |*item| try projectMediaBlock(alloc, item);
    } else try projectMediaBlock(alloc, content);
}

fn projectMediaBlock(alloc: std.mem.Allocator, item: *std.json.Value) std.mem.Allocator.Error!void {
    if (item.* != .object) return;
    const kind = item.object.get("type") orelse return;
    if (kind != .string) return;
    if (std.mem.eql(u8, kind.string, "image") or std.mem.eql(u8, kind.string, "audio")) {
        _ = item.object.swapRemove("data");
        const mime = item.object.get("mimeType");
        const supported = std.mem.eql(u8, kind.string, "image") and mime != null and mime.? == .string and image_data.supportedMediaType(mime.?.string);
        try item.object.put(alloc, "delivery", .{ .string = if (supported) "image content" else "unsupported media; content was not sent to the model" });
    } else if (std.mem.eql(u8, kind.string, "resource")) {
        if (item.object.getPtr("resource")) |resource| {
            if (resource.* == .object and resource.object.swapRemove("blob")) {
                const mime = resource.object.get("mimeType");
                const supported = mime != null and mime.? == .string and image_data.supportedMediaType(mime.?.string);
                try resource.object.put(alloc, "delivery", .{ .string = if (supported) "image content" else "binary resource content was not sent to the model" });
            }
        }
    }
}

test "a host tool image is named only when its stored mark is the digest of its bytes" {
    const alloc = std.testing.allocator;
    const png = "\x89PNG\r\n\x1a\nhost-tool-shot";
    var encoded: [64]u8 = undefined;
    const data = std.base64.standard.Encoder.encode(&encoded, png);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(png, &digest, .{});
    const name = std.fmt.bytesToHex(digest, .lower);
    for ([_]struct { mark: []const u8, named: bool }{
        .{ .mark = &name, .named = true },
        .{ .mark = "0000000000000000000000000000000000000000000000000000000000000000", .named = false },
    }) |case| {
        const json = try alloc.print("{{\"text\":\"shot\",\"images\":[{{\"type\":\"image\",\"data\":\"{s}\",\"mimeType\":\"image/png\",\"stored\":\"{s}\"}}]}}", .{ data, case.mark });
        defer alloc.free(json);
        const result = try parseRichResult(alloc, json, 1024, false);
        const rich = result.rich;
        defer {
            alloc.free(rich.text);
            types.freeToolImages(alloc, rich.images);
        }
        try std.testing.expectEqual(@as(usize, 1), rich.images.len);
        // A mark that does not match leaves the image inline, never lost.
        try std.testing.expectEqualStrings(data, rich.images[0].data);
        try std.testing.expectEqual(case.named, rich.images[0].name != null);
        if (case.named) try std.testing.expectEqualStrings(&name, &rich.images[0].name.?);
    }
}
