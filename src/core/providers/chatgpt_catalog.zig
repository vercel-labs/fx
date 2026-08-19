const std = @import("std");
const collections = @import("../shared/collections.zig");

const Allocator = std.mem.Allocator;

/// Official Codex catalog ids documented by OpenAI. Do not invent additional ids.
pub const catalog_ids = [_][]const u8{
    "gpt-5.6-sol",
    "gpt-5.6-terra",
    "gpt-5.6-luna",
    "gpt-5.6",
    "gpt-5.3-codex-spark",
    "gpt-5.5",
    "gpt-5.4",
    "gpt-5.4-mini",
};

pub const default_model = "gpt-5.6-sol";

pub fn contains(id: []const u8) bool {
    for (catalog_ids) |candidate| {
        if (std.mem.eql(u8, candidate, id)) return true;
    }
    return false;
}

pub fn resolveModel(requested: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, requested, " \t\r\n");
    if (contains(trimmed)) return trimmed;
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

test "chatgpt catalog is official Codex ids only" {
    try std.testing.expect(contains("gpt-5.6-sol"));
    try std.testing.expect(contains("gpt-5.3-codex-spark"));
    try std.testing.expect(!contains("gpt-4.1"));
    try std.testing.expect(!contains("o4-mini"));
    try std.testing.expectEqualStrings("gpt-5.6-sol", resolveModel("not-a-model"));
    try std.testing.expectEqualStrings("gpt-5.6-terra", resolveModel(" gpt-5.6-terra "));
}

test "chatgpt catalog owner returns every official id" {
    var ids = try ownedIds(std.testing.allocator);
    defer collections.freeStringList(std.testing.allocator, &ids);
    try std.testing.expectEqual(catalog_ids.len, ids.items.len);
    try std.testing.expectEqualStrings(catalog_ids[0], ids.items[0]);
}
