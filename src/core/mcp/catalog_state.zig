const std = @import("std");
const catalog_freshness = @import("catalog_freshness.zig");
const resources_feature = @import("features/resources.zig");
const prompts_feature = @import("features/prompts.zig");
const mcp_contract = @import("mcp_contract.zig");
const Allocator = std.mem.Allocator;
const Digest = catalog_freshness.Digest;
const freeOwnedStrings = mcp_contract.freeOwnedStrings;

pub const McpTool = struct {
    original_name: []const u8,
    prefixed_name: []u8,
    title: ?[]u8 = null,
    description: []u8,
    input_schema_json: []u8,
    output_schema_json: ?[]u8 = null,
    icons_json: ?[]u8 = null,
    annotations_json: ?[]u8 = null,
    metadata_json: ?[]u8 = null,
    tags: []const []u8,
};

pub const ToolCatalogSnapshot = struct {
    tools: std.ArrayList(McpTool) = .empty,
    metadata: ?catalog_freshness.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = true,

    pub fn deinit(self: *ToolCatalogSnapshot, alloc: Allocator) void {
        freeTools(alloc, self.tools.items);
        self.tools.deinit(alloc);
        self.* = .{};
    }
};

pub const ResourceCatalogSnapshot = struct {
    catalog: ?resources_feature.ResourceCatalog = null,
    metadata: ?catalog_freshness.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = false,

    pub fn deinit(self: *ResourceCatalogSnapshot, alloc: Allocator) void {
        if (self.catalog) |*catalog| catalog.deinit(alloc);
        self.* = .{};
    }
};

pub const ResourceTemplateCatalogSnapshot = struct {
    catalog: ?resources_feature.TemplateCatalog = null,
    metadata: ?catalog_freshness.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = false,

    pub fn deinit(self: *ResourceTemplateCatalogSnapshot, alloc: Allocator) void {
        if (self.catalog) |*catalog| catalog.deinit(alloc);
        self.* = .{};
    }
};

pub const PromptCatalogSnapshot = struct {
    catalog: ?prompts_feature.Catalog = null,
    metadata: ?catalog_freshness.SnapshotMetadata = null,
    auth_generation: u64 = 0,
    available: bool = false,

    pub fn deinit(self: *PromptCatalogSnapshot, alloc: Allocator) void {
        if (self.catalog) |*catalog| catalog.deinit(alloc);
        self.* = .{};
    }
};

pub const ResourceReadCacheEntry = struct {
    uri: []u8,
    result: resources_feature.ReadResult,
    metadata: catalog_freshness.SnapshotMetadata,
    auth_generation: u64,

    pub fn deinit(self: *ResourceReadCacheEntry, alloc: Allocator) void {
        alloc.free(self.uri);
        self.result.deinit(alloc);
        self.* = undefined;
    }
};

pub const ServerCapabilities = struct {
    resources: bool = false,
    resources_list_changed: bool = false,
    resources_subscribe: bool = false,
    prompts: bool = false,
    prompts_list_changed: bool = false,
    completion: bool = false,

    pub fn exposesFeatures(self: ServerCapabilities) bool {
        return self.resources or self.prompts or self.completion;
    }
};

pub fn freeTools(alloc: Allocator, tools: []const McpTool) void {
    for (tools) |tool| {
        alloc.free(tool.original_name);
        alloc.free(tool.prefixed_name);
        if (tool.title) |value| alloc.free(value);
        alloc.free(tool.description);
        alloc.free(tool.input_schema_json);
        if (tool.output_schema_json) |value| alloc.free(value);
        if (tool.icons_json) |value| alloc.free(value);
        if (tool.annotations_json) |value| alloc.free(value);
        if (tool.metadata_json) |value| alloc.free(value);
        freeOwnedStrings(alloc, tool.tags);
    }
}

pub fn digestTools(tools: []const McpTool) catalog_freshness.Digest {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hasher = Sha256.init(.{});
    for (tools) |tool| {
        hashField(&hasher, tool.original_name);
        hashField(&hasher, tool.prefixed_name);
        hashOptionalField(&hasher, tool.title);
        hashField(&hasher, tool.description);
        hashField(&hasher, tool.input_schema_json);
        hashOptionalField(&hasher, tool.output_schema_json);
        hashOptionalField(&hasher, tool.icons_json);
        hashOptionalField(&hasher, tool.annotations_json);
        hashOptionalField(&hasher, tool.metadata_json);
        for (tool.tags) |tag| hashField(&hasher, tag);
    }
    var result: catalog_freshness.Digest = undefined;
    hasher.final(&result);
    return result;
}

pub fn hashField(hasher: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hasher.update(&length);
    hasher.update(value);
}

pub fn hashOptionalField(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: ?[]const u8,
) void {
    const present = [_]u8{@intFromBool(value != null)};
    hasher.update(&present);
    if (value) |bytes| hashField(hasher, bytes);
}

pub fn hashOptionalU64(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: ?u64,
) void {
    hasher.update(&.{@intFromBool(value != null)});
    if (value) |number| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, number, .big);
        hasher.update(&bytes);
    }
}
