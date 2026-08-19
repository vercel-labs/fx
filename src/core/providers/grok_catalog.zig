const std = @import("std");
const collections = @import("../shared/collections.zig");

const Allocator = std.mem.Allocator;

/// Grok Build catalog ids documented by xAI. Do not invent additional ids.
pub const catalog_ids = [_][]const u8{
    "grok-4.6",
    "grok-4.5",
    "grok-4",
    "grok-build-0.1",
};

pub const default_model = "grok-4.6";

pub fn contains(id: []const u8) bool {
    for (catalog_ids) |candidate| {
        if (std.mem.eql(u8, candidate, id)) return true;
    }
    return false;
}

pub fn resolveModel(requested: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, requested, " \t\r\n");
    if (contains(trimmed)) return trimmed;
    if (std.mem.startsWith(u8, trimmed, "grok-")) return trimmed;
    return default_model;
}

pub fn ownedIds(alloc: Allocator) !std.ArrayList([]u8) {
    var ids: std.ArrayList([]u8) = .empty;
    errdefer collections.freeStringList(alloc, &ids);
    for (catalog_ids) |id| {
        try ids.append(alloc, try alloc.dupe(u8, id));
    }
    return ids;
}

test "grok catalog stays on documented Grok Build ids" {
    try std.testing.expect(contains("grok-4.6"));
    try std.testing.expect(contains("grok-4"));
    try std.testing.expect(contains("grok-build-0.1"));
    try std.testing.expect(!contains("gpt-5.6-sol"));
    try std.testing.expectEqualStrings("grok-4.6", resolveModel("not-a-model"));
    try std.testing.expectEqualStrings("grok-4.5", resolveModel(" grok-4.5 "));
    try std.testing.expectEqualStrings("grok-build-0.2", resolveModel("grok-build-0.2"));
}

test "grok catalog owner returns every documented id" {
    var ids = try ownedIds(std.testing.allocator);
    defer collections.freeStringList(std.testing.allocator, &ids);
    try std.testing.expectEqual(catalog_ids.len, ids.items.len);
    try std.testing.expectEqualStrings(catalog_ids[0], ids.items[0]);
}
