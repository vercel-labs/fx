const std = @import("std");
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
        else => return .{ .failure = try std.fmt.allocPrint(alloc, "Host tool image could not be used: {s}", .{@errorName(err)}) },
    };
    errdefer types.freeToolImages(alloc, images);
    const omitted = images.len != values.array.items.len;
    const source = if (omitted) try std.fmt.allocPrint(alloc, "[Unsupported tool images were omitted.]\n{s}", .{text.string}) else text.string;
    defer if (omitted) alloc.free(source);
    const body = @constCast(try tool_result_limits.prepareModelOutput(alloc, "host_tool", source, text_limit));
    return .{ .rich = .{ .text = body, .images = images, .is_error = is_error } };
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
