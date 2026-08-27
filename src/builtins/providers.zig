const provider_set = @import("../core/gateway/provider_set.zig");
const gateway = @import("gateway.zig");
const openai_codex = @import("../gateway/openai_codex.zig");
const openai_codex_models = @import("../gateway/openai_codex_models.zig");
const openai_codex_permission_reviewer = @import("../gateway/openai_codex_permission_reviewer.zig");
const xai_grok = @import("../gateway/xai_grok.zig");
const xai_grok_models = @import("../gateway/xai_grok_models.zig");
const xai_grok_permission_reviewer = @import("../gateway/xai_grok_permission_reviewer.zig");
const openai_compatible = @import("../gateway/openai_compatible.zig");
const fireworks_models = @import("../gateway/fireworks_models.zig");
const modal_models = @import("../gateway/modal_models.zig");
const provider_catalog = @import("../core/auth/provider_catalog.zig");

const fireworks_context = openai_compatible.Context{
    .provider = .fireworks,
    .credential_source = .fireworks_api_key,
    .auth = .bearer,
    .endpoint = "https://api.fireworks.ai/inference/v1/chat/completions",
};

const modal_routes = [_]openai_compatible.Route{
    .{ .id = modal_models.definitions[0].id, .wire_model = modal_models.definitions[0].wire_model, .endpoint = modal_models.definitions[0].endpoint },
    .{ .id = modal_models.definitions[1].id, .wire_model = modal_models.definitions[1].wire_model, .endpoint = modal_models.definitions[1].endpoint },
    .{ .id = modal_models.definitions[2].id, .wire_model = modal_models.definitions[2].wire_model, .endpoint = modal_models.definitions[2].endpoint },
    .{ .id = modal_models.definitions[3].id, .wire_model = modal_models.definitions[3].wire_model, .endpoint = modal_models.definitions[3].endpoint },
};

const modal_context = openai_compatible.Context{
    .provider = .modal,
    .credential_source = .modal_proxy_token,
    .auth = .modal_proxy,
    .routes = &modal_routes,
};

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
    .fireworks = .{
        .presentation = provider_catalog.find(.fireworks),
        .agent_stream = openai_compatible.provider(&fireworks_context),
        .cli_model_catalog = fireworks_models.cli_model_catalog_provider,
        .model_catalog = fireworks_models.model_catalog_provider,
    },
    .modal = .{
        .presentation = provider_catalog.find(.modal),
        .agent_stream = openai_compatible.provider(&modal_context),
        .cli_model_catalog = modal_models.cli_model_catalog_provider,
        .model_catalog = modal_models.model_catalog_provider,
    },
};
