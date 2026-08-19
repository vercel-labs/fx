const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const types = @import("../core/shared/types.zig");

const Model = struct {
    id: []const u8,
    released: i64,
    context_window: u32,
    vision: bool,
    supports_max_effort: bool = false,
    supports_fast_mode: bool = false,
};

// OpenAI does not expose a stable unauthenticated model catalog for the Codex
// subscription route. Keep this list aligned with the verified
// openai-codex-responses catalog. Provider-qualified IDs intentionally remain
// distinct from otherwise equivalent openai/* Gateway entries.
const models = [_]Model{
    .{ .id = "openai-codex/gpt-5.6-sol", .released = 1_783_555_200, .context_window = 272_000, .vision = true, .supports_max_effort = true, .supports_fast_mode = true },
    .{ .id = "openai-codex/gpt-5.6-terra", .released = 1_783_555_200, .context_window = 272_000, .vision = true, .supports_max_effort = true, .supports_fast_mode = true },
    .{ .id = "openai-codex/gpt-5.6-luna", .released = 1_783_555_200, .context_window = 272_000, .vision = true, .supports_max_effort = true, .supports_fast_mode = true },
    .{ .id = "openai-codex/gpt-5.5", .released = 1_776_988_800, .context_window = 272_000, .vision = true, .supports_fast_mode = true },
    .{ .id = "openai-codex/gpt-5.4-mini", .released = 1_773_705_600, .context_window = 272_000, .vision = true },
    .{ .id = "openai-codex/gpt-5.4", .released = 1_772_668_800, .context_window = 272_000, .vision = true, .supports_fast_mode = true },
    .{ .id = "openai-codex/gpt-5.3-codex-spark", .released = 0, .context_window = 128_000, .vision = false },
};

const standard_reasoning_efforts = [_]types.ReasoningEffort{
    types.ReasoningEffort.literal("low"),
    types.ReasoningEffort.literal("medium"),
    types.ReasoningEffort.literal("high"),
    types.ReasoningEffort.literal("xhigh"),
};

const max_reasoning_efforts = standard_reasoning_efforts ++ [_]types.ReasoningEffort{
    types.ReasoningEffort.literal("max"),
};

pub fn append(alloc: std.mem.Allocator, catalog: *std.ArrayList(model_catalog.ModelCatalogEntry)) !void {
    for (models) |model| {
        if (contains(catalog.items, model.id)) continue;
        const id = try alloc.dupe(u8, model.id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer efforts.deinit(alloc);
        try efforts.appendSlice(alloc, if (model.supports_max_effort)
            &max_reasoning_efforts
        else
            &standard_reasoning_efforts);
        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .released = model.released,
            .has_tool_use = true,
            .has_reasoning = true,
            .reasoning_efforts = efforts,
            .supports_fast_mode = model.supports_fast_mode,
            .has_vision = model.vision,
            .has_file_input = model.vision,
            .has_implicit_caching = true,
            .context_window = model.context_window,
            .max_tokens = 128_000,
        });
    }
}

fn contains(catalog: []const model_catalog.ModelCatalogEntry, id: []const u8) bool {
    for (catalog) |entry| if (std.mem.eql(u8, entry.id, id)) return true;
    return false;
}

test "ChatGPT subscription models append once with tool and reasoning metadata" {
    const alloc = std.testing.allocator;
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    try append(alloc, &catalog);
    try append(alloc, &catalog);

    try std.testing.expectEqual(models.len, catalog.items.len);
    try std.testing.expect(catalog.items[0].has_tool_use);
    try std.testing.expect(catalog.items[0].has_reasoning);
    try std.testing.expect(catalog.items[0].supports_fast_mode);
    try std.testing.expectEqual(@as(usize, 5), catalog.items[0].reasoning_efforts.items.len);
    try std.testing.expectEqualStrings("max", catalog.items[0].reasoning_efforts.items[4].label());
    try std.testing.expectEqual(@as(usize, 4), catalog.items[3].reasoning_efforts.items.len);
    try std.testing.expect(!catalog.items[4].supports_fast_mode);
}

test "Gateway and ChatGPT versions of the same model remain distinct" {
    const alloc = std.testing.allocator;
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    defer model_catalog.freeModelCatalog(alloc, &catalog);
    const gateway_id = try alloc.dupe(u8, "openai/gpt-5.6-sol");
    const model_type = alloc.dupe(u8, "language") catch |err| {
        alloc.free(gateway_id);
        return err;
    };
    catalog.append(alloc, .{ .id = gateway_id, .model_type = model_type }) catch |err| {
        alloc.free(model_type);
        alloc.free(gateway_id);
        return err;
    };

    try append(alloc, &catalog);

    try std.testing.expect(contains(catalog.items, "openai/gpt-5.6-sol"));
    try std.testing.expect(contains(catalog.items, "openai-codex/gpt-5.6-sol"));
    try std.testing.expectEqual(models.len + 1, catalog.items.len);
}
