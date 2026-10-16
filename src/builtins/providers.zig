const provider_set = @import("../core/gateway/provider_set.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_codex_permission_reviewer = @import("../gateway/openai_codex_permission_reviewer.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const xai_grok_permission_reviewer = @import("../gateway/xai_grok_permission_reviewer.zig");
const claude_cli = @import("../gateway/claude_cli.zig");
const claude_cli_models = @import("../gateway/claude_cli_models.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");
const chat_completions = @import("../gateway/chat_completions.zig");
const configured_provider = @import("../core/config/configured_provider.zig");

fn configuredBundle(_: ?*anyopaque, definition: *const configured_provider.Definition) provider_set.Bundle {
    return chat_completions.bundle(definition);
}

pub const native = provider_set.Set{
    .configured_fn = configuredBundle,
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
    .claude = .{
        .presentation = provider_catalog.find(.claude),
        .auth_strategy = .claude_cli,
        .title_model = claude_cli_models.title_model,
        .fallback_model_capabilities_fn = claude_cli_models.capabilities,
        .agent_stream = claude_cli.agent_stream_provider,
        .cli_model_catalog = claude_cli_models.cli_model_catalog_provider,
        .model_catalog = claude_cli_models.model_catalog_provider,
    },
};
