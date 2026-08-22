const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_model_entries: usize = 32;
pub const max_slugs_per_list: usize = 16;
pub const max_slug_bytes: usize = 128;
pub const max_model_key_bytes: usize = 512;

/// Reserved map key applying to models without an exact entry.
/// Gateway model IDs always contain a `/`, so this cannot collide.
pub const default_key = "default";

/// AI Gateway provider-routing controls for one model.
/// Slugs are owned by the enclosing `Map`.
pub const Routing = struct {
    order: []const []const u8 = &.{},
    only: []const []const u8 = &.{},
};

const ModelEntry = struct {
    model: []u8,
    routing: Routing,
};

pub const ParseError = error{
    InvalidProviderRoutingType,
    InvalidProviderRoutingEntryType,
    InvalidProviderRoutingSlugType,
    InvalidProviderRoutingSlugValue,
    InvalidProviderRoutingDuplicateField,
    InvalidProviderRoutingTooManyEntries,
    InvalidProviderRoutingTooManySlugs,
    InvalidProviderRoutingModelKey,
} || Allocator.Error;

fn dupeSlugs(
    alloc: Allocator,
    value: std.json.Value,
) ParseError![]const []const u8 {
    if (value != .array) return error.InvalidProviderRoutingSlugType;
    if (value.array.items.len > max_slugs_per_list) return error.InvalidProviderRoutingTooManySlugs;

    const slugs = try alloc.alloc([]const u8, value.array.items.len);
    errdefer alloc.free(slugs);
    for (value.array.items, 0..) |item, i| {
        if (item != .string) return error.InvalidProviderRoutingSlugType;
        const raw = item.string;
        if (raw.len == 0 or raw.len > max_slug_bytes) return error.InvalidProviderRoutingSlugValue;
        slugs[i] = try alloc.dupe(u8, raw);
    }
    return slugs;
}

fn freeSlugs(alloc: Allocator, slugs: []const []const u8) void {
    for (slugs) |slug| alloc.free(slug);
    alloc.free(slugs);
}

fn freeEntry(alloc: Allocator, entry: ModelEntry) void {
    alloc.free(entry.model);
    freeSlugs(alloc, entry.routing.order);
    freeSlugs(alloc, entry.routing.only);
}

fn dupeSlugList(alloc: Allocator, slugs: []const []const u8) Allocator.Error![]const []const u8 {
    const copy = try alloc.alloc([]const u8, slugs.len);
    errdefer alloc.free(copy);
    for (slugs, 0..) |slug, i| copy[i] = try alloc.dupe(u8, slug);
    return copy;
}

fn parseRoutingEntry(value: std.json.Value, alloc: Allocator) ParseError!Routing {
    if (value != .object) return error.InvalidProviderRoutingEntryType;

    var order: ?[]const []const u8 = null;
    var only: ?[]const []const u8 = null;
    errdefer {
        if (order) |slugs| alloc.free(slugs);
        if (only) |slugs| alloc.free(slugs);
    }
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "order")) {
            if (order != null) return error.InvalidProviderRoutingDuplicateField;
            order = try dupeSlugs(alloc, entry.value_ptr.*);
        } else if (std.mem.eql(u8, key, "only")) {
            if (only != null) return error.InvalidProviderRoutingDuplicateField;
            only = try dupeSlugs(alloc, entry.value_ptr.*);
        } else {
            return error.InvalidProviderRoutingEntryType;
        }
    }

    const resolved_order = order orelse &.{};
    const resolved_only = only orelse &.{};
    if (resolved_order.len == 0 and resolved_only.len == 0) {
        if (order) |slugs| alloc.free(slugs);
        if (only) |slugs| alloc.free(slugs);
        return .{};
    }
    return .{ .order = resolved_order, .only = resolved_only };
}

/// Per-model Gateway routing configuration parsed from the
/// `providerRouting` settings object. Owned strings live in `alloc`.
pub const Map = struct {
    default: ?Routing = null,
    models: std.ArrayList(ModelEntry) = .empty,

    pub fn isEmpty(self: *const Map) bool {
        return self.default == null and self.models.items.len == 0;
    }

    pub fn deinit(self: *Map, alloc: Allocator) void {
        if (self.default) |default| {
            freeSlugs(alloc, default.order);
            freeSlugs(alloc, default.only);
        }
        for (self.models.items) |entry| {
            freeEntry(alloc, entry);
        }
        self.models.deinit(alloc);
        self.* = .{};
    }

    /// Exact model-id match wins over `default`. Returns null when no
    /// applicable entry exists.
    pub fn lookup(self: *const Map, model: []const u8) ?Routing {
        for (self.models.items) |entry| {
            if (std.mem.eql(u8, entry.model, model)) return entry.routing;
        }
        return self.default;
    }

    /// Layers `incoming` over `self`, taking ownership of its entries.
    /// A higher layer's entry for the same model (or its `default`)
    /// replaces the lower layer's; unrelated entries are preserved.
    /// Infallible: an out-of-memory append skips that single entry.
    pub fn merge(self: *Map, incoming: *Map, alloc: Allocator) void {
        if (incoming.default) |incoming_default| {
            if (self.default) |current| {
                freeSlugs(alloc, current.order);
                freeSlugs(alloc, current.only);
            }
            self.default = incoming_default;
            incoming.default = null;
        }
        for (incoming.models.items) |entry| {
            var replaced = false;
            for (self.models.items) |*existing| {
                if (std.mem.eql(u8, existing.model, entry.model)) {
                    freeEntry(alloc, existing.*);
                    existing.* = entry;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) {
                self.models.append(alloc, entry) catch {
                    freeEntry(alloc, entry);
                };
            }
        }
        incoming.models.clearRetainingCapacity();
    }

    pub fn dupe(self: *const Map, alloc: Allocator) Allocator.Error!Map {
        var copy: Map = .{};
        errdefer copy.deinit(alloc);
        if (self.default) |default| {
            copy.default = .{
                .order = try dupeSlugList(alloc, default.order),
                .only = try dupeSlugList(alloc, default.only),
            };
        }
        try copy.models.ensureTotalCapacity(alloc, self.models.items.len);
        for (self.models.items) |entry| {
            const model_copy = try alloc.dupe(u8, entry.model);
            errdefer alloc.free(model_copy);
            const order_copy = try dupeSlugList(alloc, entry.routing.order);
            errdefer alloc.free(order_copy);
            const only_copy = try dupeSlugList(alloc, entry.routing.only);
            errdefer alloc.free(only_copy);
            copy.models.appendAssumeCapacity(.{
                .model = model_copy,
                .routing = .{ .order = order_copy, .only = only_copy },
            });
        }
        return copy;
    }
};

pub fn parseJsonObject(value: std.json.Value, alloc: Allocator) ParseError!Map {
    if (value != .object) return error.InvalidProviderRoutingType;

    var result: Map = .{};
    errdefer result.deinit(alloc);

    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len == 0 or key.len > max_model_key_bytes) return error.InvalidProviderRoutingModelKey;

        const routing = try parseRoutingEntry(entry.value_ptr.*, alloc);

        if (std.mem.eql(u8, key, default_key)) {
            if (routing.order.len > 0 or routing.only.len > 0) {
                if (result.default != null) return error.InvalidProviderRoutingDuplicateField;
                result.default = routing;
            }
            continue;
        }

        if (routing.order.len == 0 and routing.only.len == 0) continue;

        if (result.models.items.len >= max_model_entries) return error.InvalidProviderRoutingTooManyEntries;
        const model_copy = try alloc.dupe(u8, key);
        errdefer alloc.free(model_copy);
        try result.models.append(alloc, .{ .model = model_copy, .routing = routing });
    }
    return result;
}

test "parses default and per-model entries" {
    const alloc = std.testing.allocator;
    const json_text =
        \\{
        \\  "default": {"order": ["wafer"]},
        \\  "anthropic/claude-sonnet-5": {"only": ["baseten"], "order": ["baseten", "bedrock"]}
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    var map = try parseJsonObject(parsed.value, alloc);
    defer map.deinit(alloc);

    try std.testing.expect(!map.isEmpty());
    const fallback = map.lookup("openai/gpt-5").?;
    try std.testing.expectEqual(@as(usize, 1), fallback.order.len);
    try std.testing.expectEqualStrings("wafer", fallback.order[0]);
    try std.testing.expectEqual(@as(usize, 0), fallback.only.len);

    const exact = map.lookup("anthropic/claude-sonnet-5").?;
    try std.testing.expectEqualStrings("baseten", exact.only[0]);
    try std.testing.expectEqual(@as(usize, 2), exact.order.len);
    try std.testing.expectEqualStrings("bedrock", exact.order[1]);
}

test "exact match wins over default and misses fall back" {
    const alloc = std.testing.allocator;
    const json_text =
        \\{"default": {"only": ["wafer"]}, "a/b": {"only": ["c"]}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    var map = try parseJsonObject(parsed.value, alloc);
    defer map.deinit(alloc);

    try std.testing.expectEqualStrings("c", map.lookup("a/b").?.only[0]);
    try std.testing.expectEqualStrings("wafer", map.lookup("x/y").?.only[0]);
    try std.testing.expect(map.default != null);
}

test "rejects malformed shapes" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { json: []const u8, expected: anyerror }{
        .{ .json = "[]", .expected = error.InvalidProviderRoutingType },
        .{ .json = "\"x\"", .expected = error.InvalidProviderRoutingType },
        .{ .json = "{\"a/b\": \"wafer\"}", .expected = error.InvalidProviderRoutingEntryType },
        .{ .json = "{\"a/b\": {\"only\": \"wafer\"}}", .expected = error.InvalidProviderRoutingSlugType },
        .{ .json = "{\"a/b\": {\"only\": [1]}}", .expected = error.InvalidProviderRoutingSlugType },
        .{ .json = "{\"a/b\": {\"only\": [\"\"]}}", .expected = error.InvalidProviderRoutingSlugValue },
        .{ .json = "{\"a/b\": {\"unknown\": [\"wafer\"]}}", .expected = error.InvalidProviderRoutingEntryType },
        .{ .json = "{\"a/b\": {\"too\": 512}}", .expected = error.InvalidProviderRoutingEntryType },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectError(case.expected, parseJsonObject(parsed.value, alloc));
    }
}

test "empty entries are dropped" {
    const alloc = std.testing.allocator;
    const json_text =
        \\{"a/b": {}, "c/d": {"only": []}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    var map = try parseJsonObject(parsed.value, alloc);
    defer map.deinit(alloc);

    try std.testing.expect(map.isEmpty());
    try std.testing.expect(map.lookup("a/b") == null);
}

test "merge layers incoming entries and preserves unrelated ones" {
    const alloc = std.testing.allocator;
    const base_text =
        \\{"default": {"only": ["wafer"]}, "a/b": {"order": ["x"]}, "c/d": {"only": ["y"]}}
    ;
    const overlay_text =
        \\{"default": {"only": ["z"]}, "a/b": {"order": ["w"]}}
    ;
    var base_map = try parseText(base_text, alloc);
    defer base_map.deinit(alloc);
    var overlay_map = try parseText(overlay_text, alloc);
    defer overlay_map.deinit(alloc);

    base_map.merge(&overlay_map, alloc);
    try std.testing.expect(overlay_map.isEmpty());

    try std.testing.expectEqualStrings("z", base_map.lookup("q/r").?.only[0]);
    try std.testing.expectEqualStrings("w", base_map.lookup("a/b").?.order[0]);
    try std.testing.expectEqualStrings("y", base_map.lookup("c/d").?.only[0]);
}

fn parseText(text: []const u8, alloc: Allocator) ParseError!Map {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProviderRoutingType,
    };
    defer parsed.deinit();
    return parseJsonObject(parsed.value, alloc);
}

test "dupe produces an independent owned copy" {
    const alloc = std.testing.allocator;
    const json_text =
        \\{"default": {"order": ["wafer", "baseten"]}, "a/b": {"only": ["c"]}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
    defer parsed.deinit();

    var map = try parseJsonObject(parsed.value, alloc);
    defer map.deinit(alloc);

    var copy = try map.dupe(alloc);
    defer copy.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 2), copy.lookup("x/y").?.order.len);
    try std.testing.expectEqualStrings("c", copy.lookup("a/b").?.only[0]);
}
