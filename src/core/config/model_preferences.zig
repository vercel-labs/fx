const std = @import("std");
const config_source = @import("config_source.zig");
const model_provider = @import("model_provider.zig");

pub const max_preferences = 35;
pub const Preferences = struct {
    pub const Entry = struct {
        provider: model_provider.NameKey,
        model: []u8,
        source: config_source.Source = .compiled_default,
    };
    entries: std.ArrayList(Entry) = .empty,

    pub fn get(self: *const Preferences, provider: model_provider.ProviderId) ?[]const u8 {
        return self.getName(provider.label());
    }

    fn getName(self: *const Preferences, name: []const u8) ?[]const u8 {
        for (self.entries.items) |*entry| if (entry.provider.eqlName(name)) return entry.model;
        return null;
    }

    pub fn source(self: *const Preferences, provider: model_provider.ProviderId) config_source.Source {
        for (self.entries.items) |*entry| if (entry.provider.eqlProvider(provider)) return entry.source;
        return .compiled_default;
    }

    pub fn set_source(self: *Preferences, source_value: config_source.Source) void {
        for (self.entries.items) |*entry| entry.source = source_value;
    }

    pub fn putCopy(self: *Preferences, alloc: std.mem.Allocator, provider: model_provider.ProviderId, model: []const u8) !void {
        const owned = try alloc.dupe(u8, model);
        errdefer alloc.free(owned);
        try self.putOwned(alloc, provider, owned);
    }

    /// Takes model only on success.
    fn putOwned(self: *Preferences, alloc: std.mem.Allocator, provider: model_provider.ProviderId, model: []u8) !void {
        for (self.entries.items) |*entry| if (entry.provider.eqlProvider(provider)) {
            alloc.free(entry.model);
            entry.model = model;
            return;
        };
        if (self.entries.items.len == max_preferences) return error.TooManyModelPreferences;
        try self.entries.append(alloc, .{ .provider = model_provider.NameKey.fromProvider(provider), .model = model });
    }

    pub fn mergeOwnedFrom(self: *Preferences, alloc: std.mem.Allocator, incoming: *Preferences) !void {
        var additional: usize = 0;
        for (incoming.entries.items) |entry| if (self.getName(entry.provider.label()) == null) {
            additional += 1;
        };
        if (additional > max_preferences - self.entries.items.len) return error.TooManyModelPreferences;
        try self.entries.ensureUnusedCapacity(alloc, additional);
        for (incoming.entries.items) |entry| {
            for (self.entries.items) |*current| {
                if (!current.provider.eqlName(entry.provider.label())) continue;
                alloc.free(current.model);
                current.* = entry;
                break;
            } else self.entries.appendAssumeCapacity(entry);
        }
        incoming.entries.clearRetainingCapacity();
    }

    pub fn count(self: *const Preferences) usize {
        return self.entries.items.len;
    }
    pub fn isEmpty(self: *const Preferences) bool {
        return self.count() == 0;
    }

    pub fn deinit(self: *Preferences, alloc: std.mem.Allocator) void {
        for (self.entries.items) |entry| alloc.free(entry.model);
        self.entries.deinit(alloc);
        self.* = .{};
    }
};

test "model preferences are bounded and provider keyed" {
    var preferences: Preferences = .{};
    defer preferences.deinit(std.testing.allocator);
    try preferences.putCopy(std.testing.allocator, .gateway, "gateway/model");
    try preferences.putCopy(std.testing.allocator, .codex, "gpt-5.4");
    try preferences.putCopy(std.testing.allocator, .codex, "gpt-5.6");
    try preferences.putCopy(std.testing.allocator, model_provider.parse("local").?, "local-model");
    try std.testing.expectEqualStrings("gateway/model", preferences.get(.gateway).?);
    try std.testing.expectEqualStrings("gpt-5.6", preferences.get(.codex).?);
    try std.testing.expectEqualStrings("local-model", preferences.get(model_provider.parse("local").?).?);
    try std.testing.expectEqual(config_source.Source.compiled_default, preferences.source(.gateway));
    try std.testing.expect(preferences.get(.grok) == null);
    try std.testing.expectEqual(@as(usize, 3), preferences.count());
}

test "model preference source follows replacement and merge ownership" {
    var preferences: Preferences = .{};
    defer preferences.deinit(std.testing.allocator);
    try preferences.putCopy(std.testing.allocator, .gateway, "global/model");
    preferences.set_source(.user_global);

    var incoming: Preferences = .{};
    defer incoming.deinit(std.testing.allocator);
    try incoming.putCopy(std.testing.allocator, .gateway, "workspace/model");
    incoming.set_source(.user_workspace);
    try preferences.mergeOwnedFrom(std.testing.allocator, &incoming);

    try std.testing.expectEqualStrings("workspace/model", preferences.get(.gateway).?);
    try std.testing.expectEqual(config_source.Source.user_workspace, preferences.source(.gateway));
    try std.testing.expectEqual(@as(usize, 0), incoming.count());
}
