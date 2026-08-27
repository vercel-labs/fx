const std = @import("std");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");

pub const Definition = struct {
    id: []const u8,
    wire_model: []const u8,
    endpoint: []const u8,
};

pub const definitions = [_]Definition{
    .{
        .id = "glm-5-3-flash",
        .wire_model = "zai-org/GLM-5.3-Flash",
        .endpoint = "https://robomart-rsi--ep-glm-5-3-flash-server.us-west.modal.direct/v1/chat/completions",
    },
    .{
        .id = "qwen3-8-2-4t-a95b",
        .wire_model = "Qwen/Qwen3.8-2.4T-A95B",
        .endpoint = "https://robomart-rsi--ep-qwen3-8-2-4t-a95b-server.us-west.modal.direct/v1/chat/completions",
    },
    .{
        .id = "inkling-nvfp4",
        .wire_model = "thinkingmachines/Inkling-NVFP4",
        .endpoint = "https://robomart-rsi--ep-inkling-nvfp4-server.us-west.modal.direct/v1/chat/completions",
    },
    .{
        .id = "kimi-k3",
        .wire_model = "moonshotai/Kimi-K3",
        .endpoint = "https://robomart-rsi--ep-kimi-k3-server.us-west.modal.direct/v1/chat/completions",
    },
};

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchCatalog,
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
            break :blk .{ .loaded = .{ .ids = ids, .provenance = loaded.provenance } };
        },
        .failed => |failure| .{ .failure = failure },
    };
}

fn fetchCatalog(
    _: ?*anyopaque,
    alloc: std.mem.Allocator,
    input: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    if (input.access.credentialSource() != .modal_proxy_token or
        input.access.authorizationCredential() == null or
        input.access.accountId() == null)
    {
        return .{ .failure = .{ .category = .authentication, .http_status = .unauthorized } };
    }
    var catalog: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &catalog);
    try catalog.ensureTotalCapacity(alloc, definitions.len);
    for (definitions) |definition| {
        const id = try alloc.dupe(u8, definition.id);
        errdefer alloc.free(id);
        const model_type = try alloc.dupe(u8, "language");
        errdefer alloc.free(model_type);
        catalog.appendAssumeCapacity(.{
            .id = id,
            .model_type = model_type,
            .has_tool_use = true,
        });
    }
    return .{ .catalog = catalog };
}

test "Modal catalog exposes the four endpoint aliases" {
    const access = @import("../core/auth/credentials.zig").catalogAccessForCredentialAndAccount(
        .modal_proxy_token,
        "secret",
        null,
        "id",
    );
    const result = try fetchCatalog(null, std.testing.allocator, .{
        .access = access,
        .endpoint = "",
    });
    var catalog = result.catalog;
    defer model_catalog.freeModelCatalog(std.testing.allocator, &catalog);
    try std.testing.expectEqual(@as(usize, 4), catalog.items.len);
    try std.testing.expectEqualStrings("glm-5-3-flash", catalog.items[0].id);
    try std.testing.expectEqualStrings("kimi-k3", catalog.items[3].id);
}
