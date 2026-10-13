const std = @import("std");
const build_options = @import("build_options");
const acp_server = @import("acp/server.zig");
const js_host_stream_provider = @import("gateway/js_host_stream_provider.zig");
const host_openai_codex = @import("gateway/host_openai_codex.zig");
const host_xai_grok = @import("gateway/host_xai_grok.zig");
const host_chat_completions = @import("gateway/host_chat_completions.zig");
const model_provider = @import("core/config/model_provider.zig");
const context_contract = @import("core/workspace/context_contract.zig");
const gateway_provider = @import("core/gateway/gateway_provider.zig");
const provider_set = @import("core/gateway/provider_set.zig");
const agent_steps = @import("core/config/agent_steps.zig");
const host = @import("core/hosts/host.zig");
const js_host_attachments = @import("core/hosts/js_host_attachments.zig");
const io_mod = @import("core/shared/io.zig");
const model_catalog = @import("core/gateway/model_catalog.zig");
const js_host_model_catalog = @import("gateway/js_host_model_catalog.zig");
const oauth_transport = @import("core/auth/oauth_transport.zig");
const output_contracts = @import("core/output/output_contracts.zig");
const builtin_gateway = @import("builtins/gateway.zig");
const provider_catalog = @import("core/auth/provider_catalog.zig");
const vercel_model_policy = @import("gateway/vercel_model_policy.zig");
const builtin_modes = @import("builtins/modes.zig");

const Allocator = std.mem.Allocator;

comptime {
    if (build_options.wasm_surface != .core) {
        @compileError("fx-core requires -Dwasm-surface=core");
    }
}

pub const panic = @import("core/hosts/wasm_panic.zig").panic;

pub fn main(init: std.process.Init) !void {
    io_mod.setIo(init.io);
    io_mod.setEnvironMap(init.environ_map);
    const alloc = std.heap.c_allocator;
    // FX_CONFIGURED_PROVIDERS defines the app's own provider, if it has one.
    const configured_providers = io_mod.getenv("FX_CONFIGURED_PROVIDERS");
    var custom_context: ?host_chat_completions.Context = null;
    defer if (custom_context) |*context| context.deinit(alloc);
    var providers = js_host_provider_set;
    if (configured_providers) |json| {
        custom_context = try host_chat_completions.Context.init(alloc, js_host_stream_provider.transport, json);
        providers.configured_fn = host_chat_completions.bundle;
        providers.configured_context = &custom_context.?;
    }
    try acp_server.run(alloc, .{
        .default_model = builtin_gateway.default_model,
        .default_agent_step_limit = agent_steps.default_max_agent_steps,
        .gateway_retry_count = 0,
        .gateway_chat_url = builtin_gateway.default_chat_url,
        .gateway_models_path = builtin_gateway.models_path,
        .gateway_provider = js_host_gateway_provider,
        .provider_set = providers,
        .secret_store = host.unavailable_secret_store,
        .prompt_policy = .{ .system_prompt = "" },
        .ignored_list_entries = &.{},
        .max_list_entries = 0,
        .max_read_file_bytes = 0,
        .max_read_file_lines = 0,
        .max_read_file_line_len = 0,
        .max_command_output_bytes = 0,
        .max_tool_result_bytes = 64 * 1024,
        .max_history_turns = 100,
        .context_registry = .{ .default_provider = context_contract.empty_provider },
        .mode_registry = builtin_modes.registry,
        .credential_override = io_mod.getenv("AI_GATEWAY_API_KEY"),
        .provider_override = try providerOverrideFromEnv(io_mod.getenv("FX_PROVIDER"), if (custom_context) |*context| context else null),
        // The JS host adds provider credentials at its fetch edge.
        .provider_auth_mode = .host_managed,
        .configured_providers_json = configured_providers,
        .model_override = io_mod.getenv("FX_MODEL"),
        .effort_override = io_mod.getenv("FX_EFFORT"),
        .fast_override = fastOverrideFromEnv(io_mod.getenv("FX_FAST")),
        .ultrafast_override = fastOverrideFromEnv(io_mod.getenv("FX_ULTRAFAST")),
        .workspace_root_override = "/",
        .allow_acp_mcp = false,
        .allow_native_tools = false,
        .minimal_kernel = true,
        .host_attachments = js_host_attachments.store,
    });
}

const js_host_gateway_provider = gateway_provider.Provider{
    .oauth_transport = oauth_transport.unavailable_provider,
    .chat_url = .{ .resolve_fn = resolveChatUrl },
};

const codex_context = host_openai_codex.Context{ .transport = js_host_stream_provider.transport };
// Mutable: it remembers the Grok client version between requests.
var grok_context = host_xai_grok.Context{ .transport = js_host_stream_provider.transport };

const js_host_provider_set = set: {
    var providers = provider_set.gateway_only(.{
        .presentation = provider_catalog.find(.gateway),
        .auth_strategy = .vercel,
        .fallback_model_capabilities_fn = vercel_model_policy.capabilitiesForModel,
        .agent_stream = js_host_stream_provider.provider(),
        .cli_model_catalog = .{ .fetch_fn = fetchCliModelCatalog },
        .model_catalog = js_host_model_catalog.provider,
        .credits = .{ .fetch_fn = fetchCredits },
    });
    providers.codex = .{
        .presentation = provider_catalog.find(.codex),
        .auth_strategy = .chatgpt,
        .agent_stream = host_openai_codex.provider(@constCast(&codex_context)),
        .model_catalog = host_openai_codex.modelCatalogProvider(@constCast(&codex_context)),
    };
    providers.grok = .{
        .presentation = provider_catalog.find(.grok),
        .auth_strategy = .grok,
        .agent_stream = host_xai_grok.provider(&grok_context),
        .model_catalog = host_xai_grok.modelCatalogProvider(&grok_context),
    };
    break :set providers;
};

/// libfx engines run Gateway, Codex, Grok, or the configured provider, bound to
/// its definition so saved sessions record it. Null keeps the startup provider.
fn providerOverrideFromEnv(value: ?[]const u8, configured: ?*const host_chat_completions.Context) error{InvalidProvider}!?model_provider.ProviderId {
    const raw = value orelse return null;
    if (configured) |context| {
        const provider = model_provider.parse(raw) orelse return error.InvalidProvider;
        if (provider != .configured) return error.InvalidProvider;
        return provider.bind(context.registry) catch error.InvalidProvider;
    }
    if (std.mem.eql(u8, raw, "gateway")) return .gateway;
    if (std.mem.eql(u8, raw, "codex")) return .codex;
    if (std.mem.eql(u8, raw, "grok")) return .grok;
    return error.InvalidProvider;
}

fn resolveChatUrl(_: ?*anyopaque, fallback: []const u8) []const u8 {
    return fallback;
}

fn fetchCliModelCatalog(
    _: ?*anyopaque,
    alloc: Allocator,
    input: gateway_provider.CliModelCatalogInput,
) gateway_provider.CliModelCatalogResult {
    const result = model_catalog.fetchWithPublicFallback(js_host_model_catalog.provider, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
        .view = .full,
    });
    return switch (result) {
        .loaded => |loaded| project: {
            var catalog = loaded.catalog;
            defer model_catalog.freeModelCatalog(alloc, &catalog);
            const ids = model_catalog.projectModelIds(alloc, catalog.items) catch return .{ .failure = .{
                .access = loaded.provenance.access,
                .anonymous_fallback_used = loaded.provenance.anonymous_fallback_used,
                .failure = .{ .category = .resource_exhausted },
            } };
            break :project .{ .loaded = .{
                .ids = ids,
                .provenance = loaded.provenance,
            } };
        },
        .failed => |failed| .{ .failure = failed },
    };
}

fn fetchCredits(
    _: ?*anyopaque,
    _: Allocator,
    _: gateway_provider.CreditsLookupInput,
) output_contracts.CreditsSnapshot {
    return .{};
}

/// Parses an FX_FAST or FX_ULTRAFAST host toggle: "true"/"1" enable the
/// lane, "false"/"0" disable it, and anything else leaves the default in place.
fn fastOverrideFromEnv(value: ?[]const u8) ?bool {
    const raw = value orelse return null;
    if (std.ascii.eqlIgnoreCase(raw, "true") or std.mem.eql(u8, raw, "1")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false") or std.mem.eql(u8, raw, "0")) return false;
    return null;
}
