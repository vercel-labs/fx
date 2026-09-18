//! Session encoding shared by snapshot and conversation-log codecs.
const std = @import("std");
const presentation_contract = @import("../shared/user_turn_presentation.zig");
const Presentation = presentation_contract.Presentation;

/// Caller owns the result. Missing metadata denotes ordinary text.
pub fn parse(alloc: std.mem.Allocator, text: []const u8, value: ?std.json.Value) !Presentation {
    const raw = value orelse return .{};
    var parsed = std.json.parseFromValue(Presentation, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidSessionFormat,
    };
    defer parsed.deinit();
    if (!presentation_contract.valid(text, parsed.value.collapsed_ranges)) return error.InvalidSessionFormat;
    return parsed.value.dupe(alloc);
}

pub fn write(writer: *std.Io.Writer, presentation: Presentation) !void {
    if (presentation.collapsed_ranges.len == 0) return;
    try writer.writeAll(",\"presentation\":");
    try std.json.Stringify.value(presentation, .{}, writer);
}

test "paste presentation accepts absent metadata and rejects malformed ranges" {
    const alloc = std.testing.allocator;
    const absent = try parse(alloc, "plain", null);
    defer absent.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), absent.collapsed_ranges.len);
    for ([_][]const u8{
        "{\"collapsed_ranges\":[{\"id\":1,\"start\":0,\"end\":9}]}",
        "{\"collapsed_ranges\":\"invalid\"}",
    }) |json| {
        var value = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer value.deinit();
        try std.testing.expectError(error.InvalidSessionFormat, parse(alloc, "plain", value.value));
    }
}
