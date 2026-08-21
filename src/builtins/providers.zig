const std = @import("std");
const agent_stream = @import("../core/agent/stream_provider.zig");
const collections = @import("../core/shared/collections.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const provider_id = @import("../core/providers/provider_id.zig");
const gateway = @import("gateway.zig");
const opencode_go = @import("opencode_go.zig");

const Allocator = std.mem.Allocator;

fn buildAgentRequest(_: ?*anyopaque, alloc: Allocator, request: agent_stream.BuildRequest) anyerror![]u8 {
    return switch (provider_id.fromModel(request.model)) {
        .vercel_ai_gateway => gateway.agent_stream_provider.build(alloc, request),
        .opencode_go => opencode_go.agent_stream_provider.build(alloc, request),
    };
}

fn streamAgentCompletion(_: ?*anyopaque, alloc: Allocator, request: agent_stream.Request) anyerror!agent_stream.Result {
    return switch (provider_id.fromModel(request.model)) {
        .vercel_ai_gateway => gateway.agent_stream_provider.stream(alloc, request),
        .opencode_go => opencode_go.agent_stream_provider.stream(alloc, request),
    };
}

pub const agent_stream_provider = agent_stream.Provider{
    .build_fn = buildAgentRequest,
    .stream_fn = streamAgentCompletion,
};

fn fetchModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: model_catalog.FetchInput,
) Allocator.Error!model_catalog.ProviderResult {
    const gateway_result = try gateway.model_catalog_provider.fetch(alloc, input);
    const go_result = try opencode_go.model_catalog_provider.fetch(alloc, .{
        .endpoint = opencode_go.models_url,
        .cancel_flag = input.cancel_flag,
        .view = input.view,
    });
    return switch (gateway_result) {
        .failure => |gateway_failure| switch (go_result) {
            .failure => |go_failure| .{ .failure = if (go_failure.category == .cancellation) go_failure else gateway_failure },
            .catalog => |catalog| .{ .catalog = catalog },
        },
        .catalog => |gateway_catalog_value| switch (go_result) {
            .failure => .{ .catalog = gateway_catalog_value },
            .catalog => |go_catalog_value| blk: {
                var gateway_catalog = gateway_catalog_value;
                var go_catalog = go_catalog_value;
                errdefer model_catalog.freeModelCatalog(alloc, &gateway_catalog);
                errdefer model_catalog.freeModelCatalog(alloc, &go_catalog);
                try gateway_catalog.ensureUnusedCapacity(alloc, go_catalog.items.len);
                gateway_catalog.appendSliceAssumeCapacity(go_catalog.items);
                go_catalog.deinit(alloc);
                std.mem.sort(model_catalog.ModelCatalogEntry, gateway_catalog.items, {}, model_catalog.compareModelCatalogEntries);
                break :blk .{ .catalog = gateway_catalog };
            },
        },
    };
}

pub const model_catalog_provider = model_catalog.Provider{ .fetch_fn = fetchModelCatalog };

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const gateway_result = gateway.cli_model_catalog_provider.fetch(alloc, input);
    const go_result = opencode_go.cli_model_catalog_provider.fetch(alloc, .{
        .endpoint = opencode_go.models_url,
        .cancel_flag = input.cancel_flag,
    });
    return switch (gateway_result) {
        .failure => |gateway_failure| switch (go_result) {
            .failure => |go_failure| .{ .failure = if (go_failure.failure.category == .cancellation) go_failure else gateway_failure },
            .loaded => |loaded| .{ .loaded = loaded },
        },
        .loaded => |gateway_loaded_value| switch (go_result) {
            .failure => .{ .loaded = gateway_loaded_value },
            .loaded => |go_loaded_value| blk: {
                var gateway_loaded = gateway_loaded_value;
                var go_loaded = go_loaded_value;
                errdefer collections.freeStringList(alloc, &gateway_loaded.ids);
                errdefer collections.freeStringList(alloc, &go_loaded.ids);
                gateway_loaded.ids.ensureUnusedCapacity(alloc, go_loaded.ids.items.len) catch {
                    collections.freeStringList(alloc, &gateway_loaded.ids);
                    collections.freeStringList(alloc, &go_loaded.ids);
                    return .{ .failure = .{
                        .access = gateway_loaded.provenance.access,
                        .anonymous_fallback_used = gateway_loaded.provenance.anonymous_fallback_used,
                        .failure = .{ .category = .resource_exhausted },
                    } };
                };
                gateway_loaded.ids.appendSliceAssumeCapacity(go_loaded.ids.items);
                go_loaded.ids.deinit(alloc);
                break :blk .{ .loaded = gateway_loaded };
            },
        },
    };
}

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{ .fetch_fn = fetchCliModelCatalog };

pub const provider = gateway_provider.Provider{
    .agent_stream = agent_stream_provider,
    .oauth_transport = gateway.oauth_transport_provider,
    .chat_url = gateway.chat_url_provider,
    .cli_model_catalog = cli_model_catalog_provider,
    .credits = gateway.credits_provider,
    .generation_usage = gateway.generation_usage_provider,
    .web_search = gateway.default_web_search_provider,
    .model_catalog = model_catalog_provider,
};

test "agent stream routes the namespaced OpenCode Go models" {
    const messages = [_]@import("../core/shared/types.zig").ChatMessage{.{ .role = .user, .content = "hello" }};
    const body = try agent_stream_provider.build(std.testing.allocator, .{
        .model = "opencode-go/deepseek-v4-flash",
        .serialized_tools = "[]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{},
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"deepseek-v4-flash\"") != null);
}
