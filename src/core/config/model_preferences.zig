const std = @import("std");
const model_provider = @import("model_provider.zig");

const provider_count = std.meta.fields(model_provider.ProviderId).len;

pub const Preferences = struct {
    values: [provider_count]?[]u8 = [_]?[]u8{null} ** provider_count,
    /// Installed namespaces must not share one preferred-model slot.
    named: std.StringHashMapUnmanaged([]u8) = .{},

    /// Borrowed identifiers keep configuration lookup allocation-free.
    pub fn get_named(self: *const Preferences, provider: []const u8) ?[]const u8 {
        return self.named.get(provider);
    }

    /// Copies isolate preferences from parsed configuration and registry buffers.
    pub fn put_named_copy(self: *Preferences, alloc: std.mem.Allocator, provider: []const u8, model: []const u8) std.mem.Allocator.Error!void {
        const owned_model = try alloc.dupe(u8, model);
        errdefer alloc.free(owned_model);
        if (self.named.getPtr(provider)) |current| {
            alloc.free(current.*);
            current.* = owned_model;
            return;
        }
        const owned_provider = try alloc.dupe(u8, provider);
        errdefer alloc.free(owned_provider);
        try self.named.put(alloc, owned_provider, owned_model);
    }

    pub fn get(self: *const Preferences, provider: model_provider.ProviderId) ?[]const u8 {
        return self.values[@intFromEnum(provider)];
    }

    pub fn putCopy(
        self: *Preferences,
        alloc: std.mem.Allocator,
        provider: model_provider.ProviderId,
        model: []const u8,
    ) !void {
        const owned = try alloc.dupe(u8, model);
        self.putOwned(alloc, provider, owned);
    }

    pub fn putOwned(
        self: *Preferences,
        alloc: std.mem.Allocator,
        provider: model_provider.ProviderId,
        model: []u8,
    ) void {
        const index = @intFromEnum(provider);
        if (self.values[index]) |current| alloc.free(current);
        self.values[index] = model;
    }

    pub fn take(
        self: *Preferences,
        provider: model_provider.ProviderId,
    ) ?[]u8 {
        const index = @intFromEnum(provider);
        const value = self.values[index];
        self.values[index] = null;
        return value;
    }

    pub fn mergeOwnedFrom(
        self: *Preferences,
        alloc: std.mem.Allocator,
        incoming: *Preferences,
    ) std.mem.Allocator.Error!void {
        if (self == incoming) return;
        // Reserve before ownership moves so allocation failure preserves both selections.
        try self.named.ensureUnusedCapacity(alloc, incoming.named.count());
        inline for (std.meta.tags(model_provider.ProviderId)) |provider| {
            if (incoming.take(provider)) |model| self.putOwned(alloc, provider, model);
        }
        var names = incoming.named.iterator();
        while (names.next()) |entry| {
            const target = self.named.getOrPutAssumeCapacity(entry.key_ptr.*);
            if (target.found_existing) {
                alloc.free(entry.key_ptr.*);
                alloc.free(target.value_ptr.*);
            }
            target.value_ptr.* = entry.value_ptr.*;
        }
        incoming.named.clearRetainingCapacity();
    }

    pub fn count(self: *const Preferences) usize {
        var result: usize = 0;
        for (self.values) |value| result += @intFromBool(value != null);
        return result + self.named.count();
    }

    pub fn isEmpty(self: *const Preferences) bool {
        return self.count() == 0;
    }

    pub fn deinit(self: *Preferences, alloc: std.mem.Allocator) void {
        var names = self.named.iterator();
        while (names.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.named.deinit(alloc);
        self.named = .{};
        for (&self.values) |*value| {
            if (value.*) |model| alloc.free(model);
            value.* = null;
        }
    }
};

test "model preferences are bounded and provider keyed" {
    var preferences: Preferences = .{};
    defer preferences.deinit(std.testing.allocator);

    try preferences.putCopy(std.testing.allocator, .gateway, "gateway/model");
    try preferences.putCopy(std.testing.allocator, .codex, "gpt-5.4");
    try preferences.putCopy(std.testing.allocator, .codex, "gpt-5.6");

    try std.testing.expectEqualStrings("gateway/model", preferences.get(.gateway).?);
    try std.testing.expectEqualStrings("gpt-5.6", preferences.get(.codex).?);
    try std.testing.expect(preferences.get(.grok) == null);
    try std.testing.expectEqual(@as(usize, 2), preferences.count());
    _ = model_provider.ProviderId;
}
