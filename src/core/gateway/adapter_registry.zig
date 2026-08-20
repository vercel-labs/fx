const std = @import("std");
const stream_provider = @import("../agent/stream_provider.zig");
const connection_registry = @import("connection_registry.zig");

const max_adapters: usize = 16;

pub const InitError = error{
    EmptyRegistry,
    TooManyAdapters,
    EmptyAdapterKind,
    DuplicateAdapterKind,
    AuthAdapterKindMismatch,
};

pub const ResolveError = error{
    MissingAdapter,
    MissingAuthCapability,
};

/// A bounded, borrowed registry assembled once by composition. It owns no
/// adapters, persistence, discovery, or mutation API.
pub const AdapterRegistry = struct {
    adapters: []const stream_provider.ProviderAdapter,

    pub fn init(adapters: []const stream_provider.ProviderAdapter) InitError!AdapterRegistry {
        if (adapters.len == 0) return error.EmptyRegistry;
        if (adapters.len > max_adapters) return error.TooManyAdapters;
        for (adapters, 0..) |adapter, index| {
            if (adapter.kind.len == 0) return error.EmptyAdapterKind;
            if (adapter.auth) |auth| {
                if (!std.mem.eql(u8, adapter.kind, auth.kind)) return error.AuthAdapterKindMismatch;
            }
            for (adapters[0..index]) |previous| {
                if (std.mem.eql(u8, adapter.kind, previous.kind)) return error.DuplicateAdapterKind;
            }
        }
        return .{ .adapters = adapters };
    }

    pub fn resolve(self: AdapterRegistry, kind: []const u8) ResolveError!stream_provider.ProviderAdapter {
        for (self.adapters) |adapter| {
            if (std.mem.eql(u8, adapter.kind, kind)) return adapter;
        }
        return error.MissingAdapter;
    }

    fn resolveProfile(self: AdapterRegistry, profile: connection_registry.Profile) ResolveError!stream_provider.ProviderAdapter {
        return self.resolve(profile.adapter_id);
    }

    pub fn resolveAuthForProfile(self: AdapterRegistry, profile: connection_registry.Profile) ResolveError!@import("adapter_auth.zig").Provider {
        const adapter = try self.resolveProfile(profile);
        return adapter.auth orelse error.MissingAuthCapability;
    }
};

fn unavailableStream(
    _: *const stream_provider.ProviderAdapter,
    _: std.mem.Allocator,
    _: stream_provider.AdapterRequest,
    _: stream_provider.EventSink,
) anyerror!void {}

test "adapter registry rejects invalid manifests and missing kinds" {
    const adapter = stream_provider.ProviderAdapter{ .kind = "one", .stream_fn = unavailableStream };
    try std.testing.expectError(error.EmptyRegistry, AdapterRegistry.init(&.{}));
    try std.testing.expectError(error.EmptyAdapterKind, AdapterRegistry.init(&.{.{ .kind = "", .stream_fn = unavailableStream }}));
    try std.testing.expectError(error.DuplicateAdapterKind, AdapterRegistry.init(&.{ adapter, adapter }));
    try std.testing.expectError(error.AuthAdapterKindMismatch, AdapterRegistry.init(&.{.{
        .kind = "one",
        .auth = .{ .kind = "two" },
        .stream_fn = unavailableStream,
    }}));

    const registry = try AdapterRegistry.init(&.{adapter});
    try std.testing.expectError(error.MissingAdapter, registry.resolve("two"));
    try std.testing.expectError(error.MissingAuthCapability, registry.resolveAuthForProfile(.{
        .id = @constCast("one"),
        .display_name = @constCast("One"),
        .adapter_id = @constCast("one"),
        .endpoint = null,
        .protocol = null,
        .credential_ref = @constCast("automatic"),
        .remembered_model = @constCast("model"),
        .internal_models = .{},
    }));
}

test "adapter registry accepts sixteen adapters and rejects seventeen" {
    const adapters = comptime blk: {
        var values: [17]stream_provider.ProviderAdapter = undefined;
        for (&values, 0..) |*adapter, index| {
            adapter.* = .{
                .kind = std.fmt.comptimePrint("adapter-{d}", .{index}),
                .stream_fn = unavailableStream,
            };
        }
        break :blk values;
    };
    try std.testing.expectEqual(@as(usize, 16), (try AdapterRegistry.init(adapters[0..16])).adapters.len);
    try std.testing.expectError(error.TooManyAdapters, AdapterRegistry.init(&adapters));
}
