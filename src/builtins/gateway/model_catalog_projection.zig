const std = @import("std");
const model_catalog = @import("../../core/gateway/model_catalog.zig");
const sort_utils = @import("../../core/shared/sort_utils.zig");
const text_utils = @import("../../core/shared/text_utils.zig");

const ModelCatalogEntry = model_catalog.ModelCatalogEntry;

pub fn compare(_: void, a: ModelCatalogEntry, b: ModelCatalogEntry) bool {
    if (a.has_tool_use != b.has_tool_use) return a.has_tool_use;

    const a_tier = modelTierRank(a.id);
    const b_tier = modelTierRank(b.id);
    if (a_tier != b_tier) return a_tier < b_tier;

    const a_provider = modelProviderRank(a.id);
    const b_provider = modelProviderRank(b.id);
    if (a_provider != b_provider) return a_provider < b_provider;

    if (a.released != b.released) return a.released > b.released;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn modelProviderRank(id: []const u8) u8 {
    if (std.mem.startsWith(u8, id, "anthropic/")) return 0;
    if (std.mem.startsWith(u8, id, "openai/")) return 1;
    if (std.mem.startsWith(u8, id, "google/")) return 2;
    if (std.mem.startsWith(u8, id, "xai/")) return 3;
    if (std.mem.startsWith(u8, id, "deepseek/")) return 4;
    if (std.mem.startsWith(u8, id, "meta/")) return 5;
    if (std.mem.startsWith(u8, id, "mistral/")) return 6;
    if (std.mem.startsWith(u8, id, "alibaba/")) return 7;
    return 8;
}

fn modelTierRank(id: []const u8) u8 {
    if (text_utils.containsIgnoreCase(id, "preview") or text_utils.containsIgnoreCase(id, "beta")) return 4;
    if (text_utils.containsIgnoreCase(id, "haiku") or text_utils.containsIgnoreCase(id, "mini") or text_utils.containsIgnoreCase(id, "lite")) return 3;
    if (text_utils.containsIgnoreCase(id, "flash")) return 2;
    if (text_utils.containsIgnoreCase(id, "opus") or
        text_utils.containsIgnoreCase(id, "sonnet") or
        text_utils.containsIgnoreCase(id, "gpt-5") or
        text_utils.containsIgnoreCase(id, "o1") or
        text_utils.containsIgnoreCase(id, "o3") or
        text_utils.containsIgnoreCase(id, "o4") or
        text_utils.containsIgnoreCase(id, "pro") or
        text_utils.containsIgnoreCase(id, "grok-4")) return 0;
    return 1;
}

const picker_provider_limit: usize = 2;
const extended_picker_provider_limit: usize = 3;

const FeaturedPickerFamily = struct {
    family: []const u8,
    count: usize,
};

// Product families select their current versions from the live catalog.
const featured_picker_families = [_]FeaturedPickerFamily{
    .{ .family = "anthropic/claude-fable", .count = 1 },
    .{ .family = "openai/gpt", .count = 1 },
    .{ .family = "xai/grok-build", .count = 1 },
    .{ .family = "anthropic/claude-opus", .count = 1 },
    .{ .family = "zai/glm", .count = 1 },
    .{ .family = "deepseek/deepseek", .count = 1 },
    .{ .family = "minimax/minimax", .count = 1 },
};

pub fn projectPickerCatalog(alloc: std.mem.Allocator, candidates: []const ModelCatalogEntry) !std.ArrayList(ModelCatalogEntry) {
    var selected: std.ArrayList(ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &selected);
    try selected.ensureTotalCapacity(alloc, candidates.len);

    for (featured_picker_families) |featured| {
        var remaining = featured.count;
        while (remaining > 0) : (remaining -= 1) {
            const candidate = newestUnselectedPickerCandidate(candidates, featured.family, selected.items) orelse break;
            try model_catalog.appendClonedModelCatalogEntry(alloc, &selected, candidate.*);
        }
    }

    var providers: std.ArrayList([]const u8) = .empty;
    defer providers.deinit(alloc);
    for (candidates) |candidate| {
        if (!isPickerCandidate(candidate)) continue;
        const provider_name = modelPickerProvider(candidate.id);
        if (pickerIdsContain(providers.items, provider_name)) continue;
        try providers.append(alloc, provider_name);
    }
    sort_utils.sort([]const u8, providers.items, {}, lessThanStrings);

    // Provider-local selection avoids inheriting the catalog's global ranking.
    for (providers.items) |provider_name| {
        while (pickerProviderSelectionCount(selected.items, provider_name) < pickerProviderLimit(provider_name)) {
            const candidate = newestUnselectedPickerProviderCandidate(candidates, provider_name, selected.items) orelse break;
            try model_catalog.appendClonedModelCatalogEntry(alloc, &selected, candidate.*);
        }
    }

    // Highlighting must not make any catalog model unselectable.
    for (candidates) |candidate| {
        if (pickerCatalogContains(selected.items, candidate.id)) continue;
        try model_catalog.appendClonedModelCatalogEntry(alloc, &selected, candidate);
    }
    return selected;
}

fn newestUnselectedPickerCandidate(candidates: []const ModelCatalogEntry, family: []const u8, selected: []const ModelCatalogEntry) ?*const ModelCatalogEntry {
    var newest: ?*const ModelCatalogEntry = null;
    for (candidates) |*candidate| {
        if (!isPickerCandidate(candidate.*)) continue;
        if (!std.mem.eql(u8, modelPickerFamily(candidate.id), family)) continue;
        if (pickerCatalogContains(selected, candidate.id)) continue;
        if (newest == null or featuredPickerModelIsNewer(family, candidate.*, newest.?.*)) newest = candidate;
    }
    return newest;
}

fn newestUnselectedPickerProviderCandidate(candidates: []const ModelCatalogEntry, provider_name: []const u8, selected: []const ModelCatalogEntry) ?*const ModelCatalogEntry {
    var newest: ?*const ModelCatalogEntry = null;
    for (candidates) |*candidate| {
        if (!isPickerCandidate(candidate.*)) continue;
        if (!std.mem.eql(u8, modelPickerProvider(candidate.id), provider_name)) continue;
        if (!isPickerProviderCandidate(provider_name, candidate.*, candidates)) continue;
        if (pickerCatalogContains(selected, candidate.id)) continue;
        if (newest == null or pickerModelIsNewer(candidate.*, newest.?.*)) newest = candidate;
    }
    return newest;
}

fn isPickerCandidate(candidate: ModelCatalogEntry) bool {
    if (text_utils.containsIgnoreCase(candidate.id, "claude-sonnet")) return false;
    if (std.mem.startsWith(u8, candidate.id, "zai/glm-") and std.mem.endsWith(u8, candidate.id, "-fast")) return false;

    inline for ([_][]const u8{ "-mini", "-nano", "-oss", "-safeguard" }) |variant| {
        if (text_utils.containsIgnoreCase(candidate.id, variant)) return false;
    }
    return true;
}

fn isWithinPickerFamilyLimit(candidate: ModelCatalogEntry, candidates: []const ModelCatalogEntry) bool {
    if (!isPickerCandidate(candidate)) return false;
    const family = modelPickerFamily(candidate.id);
    var newer_count: usize = 0;
    for (candidates) |other| {
        if (!isPickerCandidate(other)) continue;
        if (!std.mem.eql(u8, modelPickerFamily(other.id), family)) continue;
        if (!pickerModelIsNewer(other, candidate)) continue;
        newer_count += 1;
        if (newer_count >= pickerFamilyLimit(family)) return false;
    }
    return true;
}

fn modelPickerFamily(id: []const u8) []const u8 {
    if (std.mem.startsWith(u8, id, "openai/gpt-") and text_utils.containsIgnoreCase(id, "-codex")) return "openai/gpt-codex";
    if (std.mem.startsWith(u8, id, "deepseek/deepseek-")) return "deepseek/deepseek";
    if (std.mem.startsWith(u8, id, "minimax/minimax-")) return "minimax/minimax";

    const slash = std.mem.findScalar(u8, id, '/') orelse return id;
    var index = slash + 1;
    while (index + 1 < id.len) : (index += 1) {
        if (id[index] == '-' and std.ascii.isDigit(id[index + 1])) return id[0..index];
    }
    return id;
}

fn modelPickerProvider(id: []const u8) []const u8 {
    const slash = std.mem.findScalar(u8, id, '/') orelse return id;
    return id[0..slash];
}

fn pickerProviderLimit(provider_name: []const u8) usize {
    if (std.mem.eql(u8, provider_name, "anthropic") or std.mem.eql(u8, provider_name, "openai")) return extended_picker_provider_limit;
    return picker_provider_limit;
}

fn pickerProviderSelectionCount(entries: []const ModelCatalogEntry, provider_name: []const u8) usize {
    var count: usize = 0;
    for (entries) |entry| {
        if (std.mem.eql(u8, modelPickerProvider(entry.id), provider_name)) count += 1;
    }
    return count;
}

fn isPickerProviderCandidate(provider_name: []const u8, candidate: ModelCatalogEntry, candidates: []const ModelCatalogEntry) bool {
    const family = modelPickerFamily(candidate.id);
    if (std.mem.eql(u8, provider_name, "anthropic")) {
        return std.mem.eql(u8, family, "anthropic/claude-opus") and isWithinPickerFamilyLimit(candidate, candidates);
    }
    if (std.mem.eql(u8, provider_name, "openai")) {
        return (std.mem.eql(u8, family, "openai/gpt") or std.mem.eql(u8, family, "openai/gpt-codex")) and
            isWithinPickerFamilyLimit(candidate, candidates);
    }
    return true;
}

fn pickerFamilyLimit(family: []const u8) usize {
    if (std.mem.eql(u8, family, "openai/gpt")) return 2;
    if (std.mem.eql(u8, family, "openai/gpt-codex")) return 1;
    return extended_picker_provider_limit;
}

fn pickerModelIsNewer(a: ModelCatalogEntry, b: ModelCatalogEntry) bool {
    if (a.released != b.released) return a.released > b.released;
    if (a.id.len != b.id.len) return a.id.len < b.id.len;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn featuredPickerModelIsNewer(family: []const u8, a: ModelCatalogEntry, b: ModelCatalogEntry) bool {
    if (a.released != b.released) return a.released > b.released;
    if (std.mem.eql(u8, family, "deepseek/deepseek")) {
        const a_quality = deepseekFeaturedQualityRank(a.id);
        const b_quality = deepseekFeaturedQualityRank(b.id);
        if (a_quality != b_quality) return a_quality < b_quality;
    }
    return pickerModelIsNewer(a, b);
}

fn deepseekFeaturedQualityRank(id: []const u8) u8 {
    if (std.mem.endsWith(u8, id, "-pro")) return 0;
    if (text_utils.containsIgnoreCase(id, "-thinking") or text_utils.containsIgnoreCase(id, "-reasoning")) return 1;
    if (text_utils.containsIgnoreCase(id, "-flash")) return 3;
    return 2;
}

fn lessThanStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn pickerIdsContain(ids: []const []const u8, needle: []const u8) bool {
    for (ids) |id| if (std.mem.eql(u8, id, needle)) return true;
    return false;
}

fn pickerCatalogContains(entries: []const ModelCatalogEntry, needle: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.id, needle)) return true;
    return false;
}

test "picker curation skips fast variants in provider scan but keeps them selectable" {
    const candidates = [_]ModelCatalogEntry{
        .{ .id = @constCast("zai/glm-5.2"), .model_type = @constCast("language"), .released = 100, .has_tool_use = true },
        .{ .id = @constCast("zai/glm-5.2-fast"), .model_type = @constCast("language"), .released = 100, .has_tool_use = true },
        .{ .id = @constCast("zai/glm-5.1"), .model_type = @constCast("language"), .released = 90, .has_tool_use = true },
    };
    var curated = try projectPickerCatalog(std.testing.allocator, &candidates);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &curated);
    try std.testing.expectEqualStrings("zai/glm-5.2", curated.items[0].id);
    try std.testing.expectEqualStrings("zai/glm-5.1", curated.items[1].id);
    try std.testing.expectEqualStrings("zai/glm-5.2-fast", curated.items[2].id);
}

test "catalog order and deepseek highlight preserve Vercel picker policy" {
    var entries = [_]ModelCatalogEntry{
        .{ .id = @constCast("mistral/large-x"), .model_type = @constCast("language"), .released = 100 },
        .{ .id = @constCast("openai/gpt-5"), .model_type = @constCast("language"), .released = 10, .has_tool_use = true },
        .{ .id = @constCast("anthropic/claude-opus-4.6"), .model_type = @constCast("language"), .released = 5, .has_tool_use = true },
    };
    std.mem.sort(ModelCatalogEntry, &entries, {}, compare);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4.6", entries[0].id);
    try std.testing.expectEqualStrings("openai/gpt-5", entries[1].id);

    const candidates = [_]ModelCatalogEntry{
        .{ .id = @constCast("deepseek/deepseek-v4"), .model_type = @constCast("language"), .released = 110, .has_tool_use = true },
        .{ .id = @constCast("deepseek/deepseek-v4-flash"), .model_type = @constCast("language"), .released = 110, .has_tool_use = true },
        .{ .id = @constCast("deepseek/deepseek-v4-pro"), .model_type = @constCast("language"), .released = 110, .has_tool_use = true },
    };
    var curated = try projectPickerCatalog(std.testing.allocator, &candidates);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &curated);
    try std.testing.expectEqualStrings("deepseek/deepseek-v4-pro", curated.items[0].id);
}
