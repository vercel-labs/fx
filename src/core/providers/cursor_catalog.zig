const std = @import("std");
const collections = @import("../shared/collections.zig");

const Allocator = std.mem.Allocator;

/// Cursor-native catalog ids documented by Cursor. Do not invent additional ids.
pub const catalog_ids = [_][]const u8{
    "composer-2.5",
    "composer-2",
    "composer-1.5",
    "auto",
};

pub const default_model = "composer-2.5";

pub fn contains(id: []const u8) bool {
    for (catalog_ids) |candidate| {
        if (std.mem.eql(u8, candidate, id)) return true;
    }
    return false;
}

pub fn resolveModel(requested: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, requested, " \t\r\n");
    if (contains(trimmed)) return trimmed;
    if (std.mem.startsWith(u8, trimmed, "composer-")) return trimmed;
    if (std.mem.eql(u8, trimmed, "auto")) return trimmed;
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

test "cursor catalog stays on documented Cursor-native ids" {
    try std.testing.expect(contains("composer-2.5"));
    try std.testing.expect(contains("composer-2"));
    try std.testing.expect(contains("auto"));
    try std.testing.expect(!contains("gpt-5.6-sol"));
    try std.testing.expectEqualStrings("composer-2.5", resolveModel("not-a-model"));
    try std.testing.expectEqualStrings("composer-1.5", resolveModel(" composer-1.5 "));
    try std.testing.expectEqualStrings("composer-3", resolveModel("composer-3"));
}

test "cursor catalog owner returns every documented id" {
    var ids = try ownedIds(std.testing.allocator);
    defer collections.freeStringList(std.testing.allocator, &ids);
    try std.testing.expectEqual(catalog_ids.len, ids.items.len);
    try std.testing.expectEqualStrings(catalog_ids[0], ids.items[0]);
}
