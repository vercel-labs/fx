const model_provider = @import("../core/config/model_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const stream_provider = @import("../core/agent/stream_provider.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const anthropic_claude = @import("../gateway/anthropic_claude.zig");
const anthropic_claude_models = @import("../gateway/anthropic_claude_models.zig");

pub fn agentStream(provider: model_provider.ProviderId) stream_provider.Provider {
    return switch (provider) {
        .gateway => gateway.agent_stream_provider,
        .codex => openai_codex.agent_stream_provider,
        .grok => xai_grok.agent_stream_provider,
        .claude => anthropic_claude.agent_stream_provider,
    };
}

pub fn modelCatalog(provider: model_provider.ProviderId) model_catalog.Provider {
    return switch (provider) {
        .gateway => gateway.model_catalog_provider,
        .codex => openai_codex_models.model_catalog_provider,
        .grok => xai_grok_models.model_catalog_provider,
        .claude => anthropic_claude_models.model_catalog_provider,
    };
}
