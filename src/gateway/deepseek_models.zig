const std = @import("std");
const credentials = @import("../core/auth/credentials.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_provider = @import("../core/config/model_provider.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;

/// The reviewer model for unresolved automatic-permission actions. It must
/// support function calling with tool_choice "required".
pub const reviewer_model = "deepseek-v4-flash";

const model_specs = [_]ModelSpec{
    .{
        .id = "deepseek-v4-flash",
        .context_window = 1_048_576,
        .max_tokens = 384_000,
        .vision = false,
    },
    .{
        .id = "deepseek-v4-pro",
        .context_window = 1_048_576,
        .max_tokens = 384_000,
        .vision = false,
    },
    .{
        .id = "deepseek-v4-flash-vision-exp",
        .context_window = 1_048_576,
        .max_tokens = 384_000,
        .vision = true,
    },
};

const ModelSpec = struct {
    id: []const u8,
    context_window: u32,
    max_tokens: u32,
    vision: bool,
};

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
    .provider_id = .deepseek,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    return switch (model_catalog.fetchWithPublicFallback(model_catalog_provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    })) {
        .loaded => |loaded| blk: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = false,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

/// The DeepSeek platform model set is small and its server enforces an exact
/// allow list (verified live: an unknown model name returns 400 listing the
/// three supported ids), so the catalog is served from a curated static table
/// mirroring the documented Responses API models rather than a network fetch.
fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    const access = input.access;
    const authenticated = switch (access) {
        .host_managed => true,
        .authenticated => |state| state.source == .deepseek_api_key and state.credential.len > 0,
        .public_only => false,
    };
    if (!authenticated) {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    if (input.cancel_flag) |cancel_flag| if (cancel_flag.load(.seq_cst)) {
        return .{ .failure = .{ .category = .cancellation } };
    };

    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (model_specs) |spec| {
        try appendEntry(alloc, &entries, spec);
    }
    return .{ .catalog = entries };
}

fn appendEntry(alloc: Allocator, entries: *std.ArrayList(model_catalog.ModelCatalogEntry), spec: ModelSpec) !void {
    const id = try alloc.dupe(u8, spec.id);
    errdefer alloc.free(id);
    const model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(model_type);
    var reasoning_efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    errdefer reasoning_efforts.deinit(alloc);
    try reasoning_efforts.append(alloc, types.ReasoningEffort.literal("low"));
    try reasoning_efforts.append(alloc, types.ReasoningEffort.literal("high"));
    try reasoning_efforts.append(alloc, types.ReasoningEffort.literal("max"));
    try entries.append(alloc, .{
        .id = id,
        .model_type = model_type,
        .has_tool_use = true,
        .has_reasoning = true,
        .reasoning_efforts = reasoning_efforts,
        .supports_fast_mode = false,
        .has_vision = spec.vision,
        .has_file_input = false,
        .context_window = spec.context_window,
        .max_tokens = spec.max_tokens,
    });
}

pub fn fallbackCapabilities(model: []const u8) @import("../core/config/model_capabilities.zig").Capabilities {
    var capabilities: @import("../core/config/model_capabilities.zig").Capabilities = .{};
    for (model_specs) |spec| {
        if (std.mem.eql(u8, model, spec.id)) {
            capabilities.supports_tool_use = true;
            capabilities.supports_vision = spec.vision;
            capabilities.context_window = spec.context_window;
            capabilities.max_output_tokens = spec.max_tokens;
            return capabilities;
        }
    }
    return capabilities;
}

test "DeepSeek catalog lists the three documented Responses models" {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    defer model_catalog.freeModelCatalog(std.testing.allocator, &entries);
    for (model_specs) |spec| try appendEntry(std.testing.allocator, &entries, spec);

    try std.testing.expectEqual(@as(usize, 3), entries.items.len);
    try std.testing.expectEqualStrings("deepseek-v4-flash", entries.items[0].id);
    try std.testing.expectEqualStrings("deepseek-v4-pro", entries.items[1].id);
    try std.testing.expectEqualStrings("deepseek-v4-flash-vision-exp", entries.items[2].id);
    try std.testing.expect(entries.items[0].has_tool_use);
    try std.testing.expect(entries.items[0].has_reasoning);
    try std.testing.expectEqual(@as(usize, 3), entries.items[0].reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("low", entries.items[0].reasoning_efforts.items[0].label());
    try std.testing.expectEqualStrings("high", entries.items[0].reasoning_efforts.items[1].label());
    try std.testing.expectEqualStrings("max", entries.items[0].reasoning_efforts.items[2].label());
    try std.testing.expect(!entries.items[0].supports_fast_mode);
    try std.testing.expect(!entries.items[0].has_vision);
    try std.testing.expect(entries.items[2].has_vision);
    try std.testing.expect(!entries.items[2].has_file_input);
    try std.testing.expectEqual(@as(u32, 1_048_576), entries.items[0].context_window);
    try std.testing.expectEqual(@as(u32, 384_000), entries.items[0].max_tokens);
}

test "DeepSeek catalog fetch requires an authenticated DeepSeek credential" {
    const fetch = model_catalog.Provider{
        .context = null,
        .fetch_fn = fetchCatalogForProvider,
        .provider_id = .deepseek,
    };
    var missing = try fetch.fetch(std.testing.allocator, .{
        .access = .{ .public_only = .no_credential },
        .endpoint = "",
    });
    switch (missing) {
        .catalog => |*catalog| {
            model_catalog.freeModelCatalog(std.testing.allocator, catalog);
            return error.TestExpectedDeepSeekCatalogFailure;
        },
        .failure => |failure| try std.testing.expectEqual(model_catalog.FailureCategory.authentication, failure.category),
    }

    var loaded = try fetch.fetch(std.testing.allocator, .{
        .access = credentials.catalogAccessForCredential(.deepseek_api_key, "sk-test", null),
        .endpoint = "",
    });
    switch (loaded) {
        .failure => return error.DeepSeekCatalogFetchFailedUnexpectedly,
        .catalog => |*catalog| {
            defer model_catalog.freeModelCatalog(std.testing.allocator, catalog);
            try std.testing.expectEqual(@as(usize, 3), catalog.items.len);
        },
    }
}

test "DeepSeek fallback capabilities cover the documented models" {
    const flash = fallbackCapabilities("deepseek-v4-flash");
    try std.testing.expect(flash.supports_tool_use);
    try std.testing.expect(!flash.supports_vision);
    try std.testing.expectEqual(@as(?u32, 1_048_576), flash.context_window);
    const vision = fallbackCapabilities("deepseek-v4-flash-vision-exp");
    try std.testing.expect(vision.supports_vision);
    const unknown = fallbackCapabilities("deepseek-other");
    try std.testing.expect(!unknown.supports_tool_use);
    _ = model_provider.ProviderId;
}
