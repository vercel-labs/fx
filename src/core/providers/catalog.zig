const std = @import("std");
const collections = @import("../shared/collections.zig");

const Allocator = std.mem.Allocator;

/// Parses an OpenAI `GET /v1/models` body into owned model id strings.
pub fn parseModelIds(alloc: Allocator, body: []const u8) !std.ArrayList([]u8) {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedResponse,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedResponse;
    const data = parsed.value.object.get("data") orelse return error.MalformedResponse;
    if (data != .array) return error.MalformedResponse;

    var ids: std.ArrayList([]u8) = .empty;
    errdefer collections.freeStringList(alloc, &ids);
    for (data.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        if (id_value != .string or id_value.string.len == 0) continue;
        try ids.append(alloc, try alloc.dupe(u8, id_value.string));
    }
    return ids;
}

test "openai models catalog parser reads ids and skips malformed entries" {
    const body =
        \\{"object":"list","data":[
        \\  {"id":"gpt-4.1","object":"model"},
        \\  {"object":"model"},
        \\  {"id":"","object":"model"},
        \\  {"id":"o4-mini","object":"model"}
        \\]}
    ;
    var ids = try parseModelIds(std.testing.allocator, body);
    defer collections.freeStringList(std.testing.allocator, &ids);
    try std.testing.expectEqual(@as(usize, 2), ids.items.len);
    try std.testing.expectEqualStrings("gpt-4.1", ids.items[0]);
    try std.testing.expectEqualStrings("o4-mini", ids.items[1]);
}

test "openai models catalog parser rejects a non-list body" {
    try std.testing.expectError(error.MalformedResponse, parseModelIds(std.testing.allocator, "{}"));
    try std.testing.expectError(error.MalformedResponse, parseModelIds(std.testing.allocator, "[]"));
    try std.testing.expectError(error.MalformedResponse, parseModelIds(std.testing.allocator, "not-json"));
}
