const provider_set = @import("../core/gateway/provider_set.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_codex_permission_reviewer = @import("../gateway/openai_codex_permission_reviewer.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const xai_grok_permission_reviewer = @import("../gateway/xai_grok_permission_reviewer.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");

pub const native = provider_set.Set{
    .gemini = .{
        .presentation = provider_catalog.find(.gemini),
        .auth_strategy = .gemini,
        .agent_stream = @import("../gateway/gemini.zig").agent_stream_provider,
        .model_catalog = @import("../gateway/gemini_models.zig").model_catalog_provider,
        .cli_model_catalog = @import("../gateway/gemini_models.zig").cli_model_catalog_provider,
        .fallback_model_capabilities_fn = @import("../gateway/gemini_models.zig").fallbackCapabilities,
        .permission_reviewer = @import("../gateway/gemini_permission_reviewer.zig").provider,
    },
    .gateway = gateway.provider_bundle,
    .codex = .{
        .presentation = provider_catalog.find(.codex),
        .auth_strategy = .chatgpt,
        .title_model = openai_codex_models.title_model,
        .agent_stream = openai_codex.agent_stream_provider,
        .cli_model_catalog = openai_codex_models.cli_model_catalog_provider,
        .model_catalog = openai_codex_models.model_catalog_provider,
        .permission_reviewer = openai_codex_permission_reviewer.provider,
    },
    .grok = .{
        .presentation = provider_catalog.find(.grok),
        .auth_strategy = .grok,
        .title_model = xai_grok_models.title_model,
        .agent_stream = xai_grok.agent_stream_provider,
        .cli_model_catalog = xai_grok_models.cli_model_catalog_provider,
        .model_catalog = xai_grok_models.model_catalog_provider,
        .permission_reviewer = xai_grok_permission_reviewer.provider,
    },
};
