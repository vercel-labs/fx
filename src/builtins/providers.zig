const provider_set = @import("../core/gateway/provider_set.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_codex_permission_reviewer = @import("../gateway/openai_codex_permission_reviewer.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const xai_grok_permission_reviewer = @import("../gateway/xai_grok_permission_reviewer.zig");
const anthropic = @import("../gateway/anthropic.zig");
const anthropic_models = @import("../gateway/anthropic_models.zig");
const openai_compatible = @import("../gateway/openai_compatible.zig");
const openai_compatible_models = @import("../gateway/openai_compatible_models.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");

pub const native = provider_set.Set{
    .gateway = gateway.provider_bundle,
    .codex = .{
        .presentation = provider_catalog.find(.codex),
        .auth_strategy = .chatgpt,
        .agent_stream = openai_codex.agent_stream_provider,
        .cli_model_catalog = openai_codex_models.cli_model_catalog_provider,
        .model_catalog = openai_codex_models.model_catalog_provider,
        .permission_reviewer = openai_codex_permission_reviewer.provider,
    },
    .grok = .{
        .presentation = provider_catalog.find(.grok),
        .auth_strategy = .grok,
        .agent_stream = xai_grok.agent_stream_provider,
        .cli_model_catalog = xai_grok_models.cli_model_catalog_provider,
        .model_catalog = xai_grok_models.model_catalog_provider,
        .permission_reviewer = xai_grok_permission_reviewer.provider,
    },
    .anthropic = .{
        .presentation = provider_catalog.find(.anthropic),
        .agent_stream = anthropic.agent_stream_provider,
        .cli_model_catalog = anthropic_models.cli_model_catalog_provider,
        .model_catalog = anthropic_models.model_catalog_provider,
    },
    .openai_compatible = .{
        .presentation = provider_catalog.find(.openai_compatible),
        .agent_stream = openai_compatible.agent_stream_provider,
        .cli_model_catalog = openai_compatible_models.cli_model_catalog_provider,
        .model_catalog = openai_compatible_models.model_catalog_provider,
    },
};
