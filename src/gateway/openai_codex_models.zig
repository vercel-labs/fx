const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const types = @import("../core/shared/types.zig");

const Model = struct {
    id: []const u8,
    context_window: u32,
    vision: bool,
};

const models = [_]Model{
    .{ .id = "openai-codex/gpt-5.4", .context_window = 272_000, .vision = true },
    .{ .id = "openai-codex/gpt-5.4-mini", .context_window = 272_000, .vision = true },
    .{ .id = "openai-codex/gpt-5.3-codex-spark", .context_window = 128_000, .vision = false },
};

const reasoning_efforts = [_]types.ReasoningEffort{
    types.ReasoningEffort.literal("low"),
    types.ReasoningEffort.literal("medium"),
    types.ReasoningEffort.literal("high"),
    types.ReasoningEffort.literal("xhigh"),
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
        try efforts.appendSlice(alloc, &reasoning_efforts);
        try catalog.append(alloc, .{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
            .has_reasoning = true,
            .reasoning_efforts = efforts,
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
    try std.testing.expectEqual(@as(usize, 4), catalog.items[0].reasoning_efforts.items.len);
}
