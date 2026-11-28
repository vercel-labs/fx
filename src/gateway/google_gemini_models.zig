const std = @import("std");
const collections = @import("../core/shared/collections.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const types = @import("../core/shared/types.zig");
const gemini_interactions_protocol = @import("gemini_interactions_protocol.zig");

const Allocator = std.mem.Allocator;
const ThinkingLevel = gemini_interactions_protocol.ThinkingLevel;

const hydrogen_id = "gemini-4-hydrogen";
const neon_id = "gemini-4-neon";
const carbon_id = "gemini-4-carbon";
const flash_lite_id = "gemini-3.5-flash-lite";
const flash_lite_alias = "gemini-flash-lite-latest";

pub const title_model = flash_lite_id;
pub const default_model = hydrogen_id;

const language_model_type = "language";
const context_window_tokens: u32 = 1_048_576;
const max_output_tokens: u32 = 65_536;

const Model = struct {
    id: []const u8,
    alias: ?[]const u8 = null,
    name: []const u8,
    levels: []const ThinkingLevel,
    default_level: ThinkingLevel,
};

const models = [_]Model{
    .{
        .id = hydrogen_id,
        .name = "Gemini 4 Hydrogen",
        .levels = &.{ .low, .medium, .high, .xhigh },
        .default_level = .high,
    },
    .{
        .id = neon_id,
        .name = "Gemini 4 Neon",
        .levels = &.{ .low, .medium, .high, .xhigh },
        .default_level = .high,
    },
    .{
        .id = carbon_id,
        .name = "Gemini 4 Carbon",
        .levels = &.{ .low, .medium, .high },
        .default_level = .medium,
    },
    .{
        .id = flash_lite_id,
        .alias = flash_lite_alias,
        .name = "Gemini 3.5 Flash-Lite",
        .levels = &.{ .minimal, .low, .medium, .high },
        .default_level = .low,
    },
};

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalogForProvider,
    .provider_id = .google,
    .shows_display_names = true,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

/// Maps fx's effort to the thinking level sent to `model_id`. `auto` asks for
/// the model's default level. A named effort maps to the level of the same
/// name, and gives null when the model does not list that level.
pub fn thinkingLevel(model_id: []const u8, effort: types.ReasoningEffort) ?ThinkingLevel {
    const model = findModel(model_id) orelse return null;
    const level = switch (effort) {
        .auto => model.default_level,
        .named => std.meta.stringToEnum(ThinkingLevel, effort.label()) orelse return null,
    };
    if (std.mem.findScalar(ThinkingLevel, model.levels, level) == null) return null;
    return level;
}

fn findModel(model_id: []const u8) ?Model {
    for (models) |model| {
        if (std.mem.eql(u8, model.id, model_id)) return model;
        if (model.alias) |alias| {
            if (std.mem.eql(u8, alias, model_id)) return model;
        }
    }
    return null;
}

fn fetchCatalogForProvider(
    _: ?*anyopaque,
    alloc: Allocator,
    _: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    return .{ .catalog = try catalogEntries(alloc) };
}

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const access = model_catalog.AccessMetadata.init(input.access);
    var entries = catalogEntries(alloc) catch return resourceExhausted(access);
    const ids = model_catalog.projectModelIds(alloc, entries.items) catch {
        model_catalog.freeModelCatalog(alloc, &entries);
        return resourceExhausted(access);
    };
    return .{ .loaded = .{
        .ids = ids,
        .entries = entries,
        .provenance = .{ .access = access },
    } };
}

fn resourceExhausted(access: model_catalog.AccessMetadata) gateway_provider.CliModelCatalogResult {
    return .{ .failure = .{
        .access = access,
        .anonymous_fallback_used = false,
        .failure = .{ .category = .resource_exhausted },
    } };
}

fn catalogEntries(alloc: Allocator) Allocator.Error!std.ArrayList(model_catalog.ModelCatalogEntry) {
    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    try entries.ensureTotalCapacity(alloc, models.len);
    for (models) |model| {
        const entry = try catalogEntry(alloc, model);
        errdefer model_catalog.freeModelCatalogEntry(alloc, entry);
        try entries.append(alloc, entry);
    }
    return entries;
}

fn catalogEntry(alloc: Allocator, model: Model) Allocator.Error!model_catalog.ModelCatalogEntry {
    const id = try alloc.dupe(u8, model.id);
    errdefer alloc.free(id);
    const name = try alloc.dupe(u8, model.name);
    errdefer alloc.free(name);
    const model_type = try alloc.dupe(u8, language_model_type);
    errdefer alloc.free(model_type);
    var efforts = try effortList(alloc, model.levels);
    errdefer efforts.deinit(alloc);
    return .{
        .id = id,
        .name = name,
        .model_type = model_type,
        .has_tool_use = true,
        .has_reasoning = true,
        .reasoning_efforts = efforts,
        .has_vision = true,
        .context_window = context_window_tokens,
        .max_tokens = max_output_tokens,
    };
}

fn effortList(alloc: Allocator, levels: []const ThinkingLevel) Allocator.Error!std.ArrayList(types.ReasoningEffort) {
    var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);
    try efforts.ensureTotalCapacity(alloc, levels.len);
    for (levels) |level| {
        efforts.appendAssumeCapacity(types.ReasoningEffort.parse(@tagName(level)) orelse unreachable);
    }
    return efforts;
}

test "cli catalog lists the four model ids in table order" {
    const alloc = std.testing.allocator;
    const result = cli_model_catalog_provider.fetch(alloc, .{ .endpoint = "" });
    var loaded = switch (result) {
        .loaded => |value| value,
        .failure => return error.CatalogFailed,
    };
    defer collections.freeStringList(alloc, &loaded.ids);
    defer model_catalog.freeModelCatalog(alloc, &loaded.entries);
    const expected = [_][]const u8{ hydrogen_id, neon_id, carbon_id, flash_lite_id };
    try std.testing.expectEqual(expected.len, loaded.ids.items.len);
    for (expected, loaded.ids.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "each catalog model lists its thinking levels" {
    const alloc = std.testing.allocator;
    const result = cli_model_catalog_provider.fetch(alloc, .{ .endpoint = "" });
    var loaded = switch (result) {
        .loaded => |value| value,
        .failure => return error.CatalogFailed,
    };
    defer collections.freeStringList(alloc, &loaded.ids);
    defer model_catalog.freeModelCatalog(alloc, &loaded.entries);
    const expected_levels = [_][]const []const u8{
        &.{ "low", "medium", "high", "xhigh" },
        &.{ "low", "medium", "high", "xhigh" },
        &.{ "low", "medium", "high" },
        &.{ "minimal", "low", "medium", "high" },
    };
    try std.testing.expectEqual(expected_levels.len, loaded.entries.items.len);
    for (expected_levels, loaded.entries.items) |want_levels, entry| {
        try std.testing.expectEqual(want_levels.len, entry.reasoning_efforts.items.len);
        for (want_levels, entry.reasoning_efforts.items) |want, effort| {
            try std.testing.expectEqualStrings(want, effort.label());
        }
    }
}

test "each model's auto effort maps to its recommended default level" {
    const auto: types.ReasoningEffort = .auto;
    try std.testing.expectEqual(@as(?ThinkingLevel, .high), thinkingLevel(hydrogen_id, auto));
    try std.testing.expectEqual(@as(?ThinkingLevel, .high), thinkingLevel(neon_id, auto));
    try std.testing.expectEqual(@as(?ThinkingLevel, .medium), thinkingLevel(carbon_id, auto));
    try std.testing.expectEqual(@as(?ThinkingLevel, .low), thinkingLevel(flash_lite_id, auto));
}

test "thinkingLevel refuses minimal on gemini-4-hydrogen" {
    const minimal = types.ReasoningEffort.literal("minimal");
    try std.testing.expect(thinkingLevel(hydrogen_id, minimal) == null);
}

test "thinkingLevel refuses xhigh on gemini-4-carbon" {
    const xhigh = types.ReasoningEffort.literal("xhigh");
    try std.testing.expect(thinkingLevel(carbon_id, xhigh) == null);
}

test "thinkingLevel refuses xhigh on gemini-3.5-flash-lite" {
    const xhigh = types.ReasoningEffort.literal("xhigh");
    try std.testing.expect(thinkingLevel(flash_lite_id, xhigh) == null);
}

test "gemini-flash-lite-latest maps like gemini-3.5-flash-lite" {
    const minimal = types.ReasoningEffort.literal("minimal");
    const auto: types.ReasoningEffort = .auto;
    try std.testing.expectEqual(@as(?ThinkingLevel, .minimal), thinkingLevel(flash_lite_alias, minimal));
    try std.testing.expectEqual(@as(?ThinkingLevel, .low), thinkingLevel(flash_lite_alias, auto));
}

test "thinkingLevel gives no level for an id outside the list" {
    const auto: types.ReasoningEffort = .auto;
    try std.testing.expect(thinkingLevel("gemini-unknown", auto) == null);
}

test "model catalog fetch returns the fixed list without a transport" {
    const alloc = std.testing.allocator;
    const result = try model_catalog_provider.fetch(alloc, .{ .endpoint = "" });
    var catalog = switch (result) {
        .catalog => |entries| entries,
        .failure => return error.CatalogFailed,
    };
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    try std.testing.expectEqual(models.len, catalog.items.len);
    try std.testing.expectEqualStrings(hydrogen_id, catalog.items[0].id);
}
