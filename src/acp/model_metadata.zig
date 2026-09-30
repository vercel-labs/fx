const std = @import("std");
const gateway = @import("../builtins/gateway.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const metadata = @import("../core/gateway/model_catalog_metadata.zig");
const capabilities = @import("../core/config/model_capabilities.zig");

const Allocator = std.mem.Allocator;
const max_bytes = 64 * 1024;
const max_entries = 64;
const max_lease_ms = 60 * 60 * 1000;

pub const Snapshot = struct {
    model: []u8 = &.{},
    revision: []u8 = &.{},
    entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty,
    received_at_ms: i64 = 0,
    expires_at_ms: i64 = 0,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        if (self.model.len > 0) alloc.free(self.model);
        if (self.revision.len > 0) alloc.free(self.revision);
        catalog.freeModelCatalog(alloc, &self.entries);
        self.* = .{};
    }

    pub fn available(self: *const Snapshot, model: []const u8, fallback: capabilities.Capabilities, now_ms: i64) ?capabilities.Capabilities {
        if (!std.mem.eql(u8, self.model, model) or now_ms < self.received_at_ms or now_ms >= self.expires_at_ms) return null;
        if (self.entries.items.len == 0) return fallback;
        return capabilities.mergeCapabilities(fallback, metadata.fromCatalogEntry(self.entries.items[0]));
    }

    pub fn parse(alloc: Allocator, value: std.json.Value, now_ms: i64) !Snapshot {
        if (value != .object) return error.InvalidModelMetadata;
        const model = value.object.get("model") orelse return error.InvalidModelMetadata;
        const revision = value.object.get("revision") orelse return error.InvalidModelMetadata;
        const lease = value.object.get("validForMs") orelse return error.InvalidModelMetadata;
        const data = value.object.get("data") orelse return error.InvalidModelMetadata;
        if (model != .string or model.string.len == 0 or model.string.len > 1024 or
            revision != .string or revision.string.len == 0 or revision.string.len > 128 or
            lease != .integer or lease.integer < 0 or lease.integer > max_lease_ms or
            data != .array or data.array.items.len > max_entries) return error.InvalidModelMetadata;
        const json = try std.json.Stringify.valueAlloc(alloc, value, .{});
        defer alloc.free(json);
        if (json.len > max_bytes) return error.InvalidModelMetadata;

        var result = Snapshot{};
        errdefer result.deinit(alloc);
        result.model = try alloc.dupe(u8, model.string);
        result.revision = try alloc.dupe(u8, revision.string);
        result.entries = gateway.parseModelCatalogForView(alloc, json, .full) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidModelMetadata,
        };
        for (result.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.id, result.model)) return error.InvalidModelMetadata;
        }
        result.received_at_ms = now_ms;
        result.expires_at_ms = std.math.add(i64, now_ms, lease.integer) catch return error.InvalidModelMetadata;
        return result;
    }
};

pub const Update = union(enum) {
    unchanged,
    clear,
    replace: Snapshot,

    pub fn parse(alloc: Allocator, value: ?std.json.Value, now_ms: i64) !Update {
        const input = value orelse return .unchanged;
        if (input == .null) return .clear;
        return .{ .replace = try Snapshot.parse(alloc, input, now_ms) };
    }

    pub fn deinit(self: *Update, alloc: Allocator) void {
        if (self.* == .replace) self.replace.deinit(alloc);
        self.* = .unchanged;
    }
};

test "selected metadata owns one model and expires without claiming a complete catalog" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"model":"catalog/last","revision":"7","validForMs":1000,"data":[{"id":"catalog/last","type":"language","context_window":128000,"max_tokens":4096}]}
    , .{});
    defer parsed.deinit();
    var snapshot = try Snapshot.parse(alloc, parsed.value, 100);
    defer snapshot.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), snapshot.entries.items.len);
    try std.testing.expectEqual(@as(?u32, 4096), snapshot.available("catalog/last", .{}, 101).?.max_output_tokens);
    try std.testing.expect(snapshot.available("catalog/other", .{}, 101) == null);
    try std.testing.expect(snapshot.available("catalog/last", .{}, 1100) == null);
    try std.testing.expect(snapshot.available("catalog/last", .{}, 99) == null);
}

test "selected metadata rejects a different model and an unbounded lease" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        \\{"model":"one","revision":"1","validForMs":1000,"data":[{"id":"other","type":"language"}]}
        ,
        \\{"model":"one","revision":"1","validForMs":3600001,"data":[]}
        ,
    }) |json| {
        var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidModelMetadata, Snapshot.parse(alloc, parsed.value, 0));
    }
}

test "an absent model retains existing fallback and updates distinguish clear from omission" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"model":"missing","revision":"3","validForMs":1000,"data":[]}
    , .{});
    defer parsed.deinit();
    var snapshot = try Snapshot.parse(alloc, parsed.value, 0);
    defer snapshot.deinit(alloc);
    const fallback = capabilities.Capabilities{ .context_window = 4096 };
    try std.testing.expectEqualDeep(fallback, snapshot.available("missing", fallback, 1).?);
    try std.testing.expectEqual(std.meta.Tag(Update).unchanged, std.meta.activeTag(try Update.parse(alloc, null, 0)));
    try std.testing.expectEqual(std.meta.Tag(Update).clear, std.meta.activeTag(try Update.parse(alloc, .null, 0)));
}
