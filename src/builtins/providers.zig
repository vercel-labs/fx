const std = @import("std");
const model_provider = @import("../core/config/model_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_compat = @import("../gateway/openai_compat.zig");

pub fn agentStream(provider: model_provider.ProviderId) stream_provider.Provider {
    return switch (provider) {
        .gateway => gateway.agent_stream_provider,
        .codex => openai_codex.agent_stream_provider,
        .custom => openai_compat.agent_stream_provider,
    };
}

pub fn modelCatalog(provider: model_provider.ProviderId) model_catalog.Provider {
    return switch (provider) {
        .gateway => gateway.model_catalog_provider,
        .codex => openai_codex_models.model_catalog_provider,
        .custom => custom_model_catalog_provider,
    };
}

const custom_model_catalog_provider = model_catalog.Provider{
    .fetch_fn = unavailableCustomCatalog,
};

fn unavailableCustomCatalog(
    _: ?*anyopaque,
    _: std.mem.Allocator,
    _: model_catalog.FetchInput,
) std.mem.Allocator.Error!model_catalog.ProviderResult {
    return .{ .failure = .{ .category = .gateway_unavailable } };
}
