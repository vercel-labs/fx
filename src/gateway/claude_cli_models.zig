const std = @import("std");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_capabilities = @import("../core/config/model_capabilities.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");

const Allocator = std.mem.Allocator;

/// The model fx selects when the user has not chosen one. The Claude CLI uses
/// the account's own default, so fx passes no `--model` for it.
pub const default_model = "default";
pub const title_model: ?[]const u8 = null;

const Entry = struct {
    id: []const u8,
    name: []const u8,
};

/// The Claude CLI resolves these aliases to the newest model of each family,
/// so the list stays correct as Anthropic ships new versions.
const entries = [_]Entry{
    .{ .id = default_model, .name = "Account default" },
    .{ .id = "opus", .name = "Claude Opus" },
    .{ .id = "sonnet", .name = "Claude Sonnet" },
    .{ .id = "haiku", .name = "Claude Haiku" },
};

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalog,
    .provider_id = .claude,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliCatalog,
};

/// What fx assumes about every Claude CLI model. Claude Code owns the tools and
/// its own context management, and fx sends no images, so only the window size
/// matters to fx's own bookkeeping.
pub fn capabilities(_: []const u8) model_capabilities.Capabilities {
    return .{ .context_window = 200_000 };
}

/// Whether `model` is a value the Claude CLI accepts for `--model`: an alias or
/// a full model name. Rejects anything that could be read as another flag.
pub fn validModel(model: []const u8) bool {
    if (model.len == 0 or model.len > 128) return false;
    if (model[0] == '-') return false;
    for (model) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '[' or byte == ']';
        if (!ok) return false;
    }
    return true;
}

fn buildEntries(alloc: Allocator) Allocator.Error!std.ArrayList(model_catalog.ModelCatalogEntry) {
    var list: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &list);
    try list.ensureTotalCapacity(alloc, entries.len);
    for (entries) |entry| {
        const id = try alloc.dupe(u8, entry.id);
        errdefer alloc.free(id);
        const name = try alloc.dupe(u8, entry.name);
        errdefer alloc.free(name);
        const model_type = try alloc.dupe(u8, "language");
        list.appendAssumeCapacity(.{
            .id = id,
            .name = name,
            .model_type = model_type,
            .has_tool_use = true,
            .has_vision = true,
            .has_file_input = true,
            .has_web_search = true,
            .has_implicit_caching = true,
        });
    }
    return list;
}

fn fetchCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    _: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    return .{ .catalog = try buildEntries(alloc) };
}

fn fetchCliCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const access = model_catalog.AccessMetadata.init(input.access);
    var built = buildEntries(alloc) catch return .{ .failure = .{
        .access = access,
        .anonymous_fallback_used = false,
        .failure = .{ .category = .resource_exhausted },
    } };
    errdefer model_catalog.freeModelCatalog(alloc, &built);
    var ids = model_catalog.projectModelIds(alloc, built.items) catch return .{ .failure = .{
        .access = access,
        .anonymous_fallback_used = false,
        .failure = .{ .category = .resource_exhausted },
    } };
    errdefer @import("../core/shared/collections.zig").freeStringList(alloc, &ids);
    return .{ .loaded = .{ .ids = ids, .entries = built, .provenance = .{ .access = access } } };
}

test "model validation accepts aliases and full names but never flag-like values" {
    try std.testing.expect(validModel("opus"));
    try std.testing.expect(validModel("claude-opus-5-5"));
    try std.testing.expect(validModel("claude-opus-5-5[1m]"));
    try std.testing.expect(!validModel(""));
    try std.testing.expect(!validModel("--dangerously-skip-permissions"));
    try std.testing.expect(!validModel("a b"));
    try std.testing.expect(!validModel("a;b"));
}

test "every model reports a window and no vision or fx tool support" {
    const caps = capabilities("opus");
    try std.testing.expectEqual(@as(?u32, 200_000), caps.context_window);
    try std.testing.expect(!caps.supports_vision);
    try std.testing.expect(!caps.supports_tool_use);
}

test "static catalog lists the default and each family alias" {
    var built = try buildEntries(std.testing.allocator);
    defer model_catalog.freeModelCatalog(std.testing.allocator, &built);
    try std.testing.expectEqual(entries.len, built.items.len);
    try std.testing.expectEqualStrings(default_model, built.items[0].id);
    try std.testing.expectEqualStrings("opus", built.items[1].id);
}

test "static catalog frees everything when an allocation fails" {
    const Check = struct {
        fn run(alloc: Allocator) !void {
            var built = try buildEntries(alloc);
            model_catalog.freeModelCatalog(alloc, &built);
        }
    };
    try std.testing.checkAllAllocationFailures(@import("../core/shared/testing_allocator.zig").no_resize, Check.run, .{});
}
