const provider_set = @import("../core/gateway/provider_set.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_codex_permission_reviewer = @import("../gateway/openai_codex_permission_reviewer.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const xai_grok_permission_reviewer = @import("../gateway/xai_grok_permission_reviewer.zig");
const openrouter = @import("../gateway/openrouter.zig");
const openrouter_models = @import("../gateway/openrouter_models.zig");
const openrouter_permission_reviewer = @import("../gateway/openrouter_permission_reviewer.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");

pub const native = provider_set.Set{
    .gateway = gateway.provider_bundle,
    .codex = .{
        .compaction_model = "gpt-5.6-luna",
        .presentation = provider_catalog.find(.codex),
        .auth_strategy = .chatgpt,
        .agent_stream = openai_codex.agent_stream_provider,
        .cli_model_catalog = openai_codex_models.cli_model_catalog_provider,
        .model_catalog = openai_codex_models.model_catalog_provider,
        .permission_reviewer = openai_codex_permission_reviewer.provider,
    },
    .grok = .{
        .compaction_model = "grok-4.5",
        .presentation = provider_catalog.find(.grok),
        .auth_strategy = .grok,
        .agent_stream = xai_grok.agent_stream_provider,
        .cli_model_catalog = xai_grok_models.cli_model_catalog_provider,
        .model_catalog = xai_grok_models.model_catalog_provider,
        .permission_reviewer = xai_grok_permission_reviewer.provider,
    },
    .openrouter = .{
        .presentation = provider_catalog.find(.openrouter),
        .auth_strategy = .openrouter,
        .agent_stream = openrouter.agent_stream_provider,
        .cli_model_catalog = openrouter_models.cli_model_catalog_provider,
        .model_catalog = openrouter_models.model_catalog_provider,
        .permission_reviewer = openrouter_permission_reviewer.provider,
    },
};
